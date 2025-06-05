// File: api/paypal-webhook.js

// Removed: import { getDownloadUrl } from '@vercel/blob';
import admin from 'firebase-admin';
import checkoutNodeJssdk from '@paypal/checkout-server-sdk';

// 1) Initialize PayPal environment (Sandbox vs Live)
let paypalClient;
(function initPayPalClient() {
  const clientId = process.env.PAYPAL_CLIENT_ID;
  const clientSecret = process.env.PAYPAL_CLIENT_SECRET;
  if (!clientId || !clientSecret) {
    console.error('❌ Missing PayPal credentials in env vars');
    return;
  }

  const environment =
    process.env.NODE_ENV === 'production'
      ? new checkoutNodeJssdk.core.LiveEnvironment(clientId, clientSecret)
      : new checkoutNodeJssdk.core.SandboxEnvironment(clientId, clientSecret);

  paypalClient = new checkoutNodeJssdk.core.PayPalHttpClient(environment);
})();

// 2) Initialize Firebase Admin
let db;
(function initFirebaseAdmin() {
  if (!admin.apps.length) {
    try {
      const serviceAccount = JSON.parse(process.env.FIREBASE_SERVICE_ACCOUNT);
      admin.initializeApp({
        credential: admin.credential.cert(serviceAccount),
      });
      db = admin.firestore();
    } catch (e) {
      console.error('❌ Error initializing Firebase Admin:', e);
    }
  } else {
    db = admin.firestore();
  }
})();

// Helper to get raw body
function getRawBody(req) {
  return new Promise((resolve, reject) => {
    let data = '';
    req.on('data', chunk => {
      data += chunk;
    });
    req.on('end', () => {
      resolve(data);
    });
    req.on('error', err => {
      reject(err);
    });
  });
}

// Helper to get PayPal access token
async function getPayPalAccessToken() {
  const authResponse = await fetch(`${process.env.NODE_ENV === 'production' ? 'https://api-m.paypal.com' : 'https://api-m.sandbox.paypal.com'}/v1/oauth2/token`, {
    method: 'POST',
    headers: {
      'Accept': 'application/json',
      'Accept-Language': 'en_US',
      'Authorization': `Basic ${Buffer.from(`${process.env.PAYPAL_CLIENT_ID}:${process.env.PAYPAL_CLIENT_SECRET}`).toString('base64')}`,
      'Content-Type': 'application/x-www-form-urlencoded'
    },
    body: 'grant_type=client_credentials'
  });

  if (!authResponse.ok) {
    throw new Error(`Auth failed: ${authResponse.status}`);
  }

  const authData = await authResponse.json();
  return authData.access_token;
}

// Helper to get subscription details including subscriber email
async function getSubscriptionDetails(subscriptionId, accessToken) {
  const response = await fetch(`${process.env.NODE_ENV === 'production' ? 'https://api-m.paypal.com' : 'https://api-m.sandbox.paypal.com'}/v1/billing/subscriptions/${subscriptionId}`, {
    method: 'GET',
    headers: {
      'Content-Type': 'application/json',
      'Authorization': `Bearer ${accessToken}`
    }
  });

  if (!response.ok) {
    throw new Error(`Failed to get subscription details: ${response.status}`);
  }

  return await response.json();
}

// NEW: Helper to check for stored subscription mapping
async function getEmailFromSubscriptionMapping(subscriptionId) {
  try {
    const snapshot = await db.collection('subscription_mappings').doc(subscriptionId).get();
    if (snapshot.exists) {
      const data = snapshot.data();
      console.log('🔍 Found stored email mapping:', data.email);
      return data.email;
    }
  } catch (error) {
    console.error('❌ Error checking subscription mapping:', error);
  }
  return null;
}

// 3) Main webhook handler
export default async function handler(req, res) {
  if (req.method !== 'POST') {
    return res.status(405).send('Method not allowed');
  }

  // Get raw body for verification (critical for PayPal verification)
  let rawBody;
  let webhookEvent;
  
  try {
    // If req.body is already parsed, we need to get the raw body differently
    if (req.body && typeof req.body === 'object') {
      // Body is already parsed by Vercel - convert back to string
      rawBody = JSON.stringify(req.body);
      webhookEvent = req.body;
    } else {
      // Get raw body
      rawBody = await getRawBody(req);
      webhookEvent = JSON.parse(rawBody);
    }
  } catch (err) {
    console.error('❌ Error parsing webhook body:', err);
    return res.status(400).json({ error: 'Invalid JSON body' });
  }

  // 3a) Gather PayPal headers
  const transmissionId = req.headers['paypal-transmission-id'];
  const transmissionTime = req.headers['paypal-transmission-time'];
  const certUrl = req.headers['paypal-cert-url'];
  const authAlgo = req.headers['paypal-auth-algo'];
  const actualSignature = req.headers['paypal-transmission-sig'];
  const webhookId = process.env.PAYPAL_WEBHOOK_ID;

  // Debug: Log all headers to identify what's missing
  console.log('📋 Webhook Headers Debug:');
  console.log('transmissionId:', transmissionId ? 'PRESENT' : 'MISSING');
  console.log('transmissionTime:', transmissionTime ? 'PRESENT' : 'MISSING');
  console.log('certUrl:', certUrl ? 'PRESENT' : 'MISSING');
  console.log('authAlgo:', authAlgo ? 'PRESENT' : 'MISSING');
  console.log('actualSignature:', actualSignature ? 'PRESENT' : 'MISSING');
  console.log('webhookId:', webhookId ? 'PRESENT' : 'MISSING');

  // 3b) Verify all required headers are present
  if (!transmissionId || !transmissionTime || !certUrl || !authAlgo || !actualSignature || !webhookId) {
    console.error('❌ Missing required PayPal webhook headers');
    return res.status(400).json({ 
      error: 'Missing required PayPal webhook headers',
      missing: {
        transmissionId: !transmissionId,
        transmissionTime: !transmissionTime,
        certUrl: !certUrl,
        authAlgo: !authAlgo,
        actualSignature: !actualSignature,
        webhookId: !webhookId
      }
    });
  }

  // 3c) Build verification request - use RAW BODY as webhook_event
  const verifyRequest = {
    auth_algo: authAlgo,
    cert_url: certUrl,
    transmission_id: transmissionId,
    transmission_sig: actualSignature,
    transmission_time: transmissionTime,
    webhook_id: webhookId,
    webhook_event: JSON.parse(rawBody) // Use parsed version of raw body
  };

  // 3d) Perform signature verification using direct API call
  try {
    // Get access token for verification
    const accessToken = await getPayPalAccessToken();

    // Verify webhook signature
    const verifyResponse = await fetch(`${process.env.NODE_ENV === 'production' ? 'https://api-m.paypal.com' : 'https://api-m.sandbox.paypal.com'}/v1/notifications/verify-webhook-signature`, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': `Bearer ${accessToken}`
      },
      body: JSON.stringify(verifyRequest)
    });

    if (!verifyResponse.ok) {
      const errorText = await verifyResponse.text();
      throw new Error(`Verification failed: ${verifyResponse.status} - ${errorText}`);
    }

    const verifyData = await verifyResponse.json();
    const verificationStatus = verifyData.verification_status;
    console.log('🔍 PayPal Webhook verification status:', verificationStatus);

    if (verificationStatus !== 'SUCCESS') {
      console.error('❌ Invalid PayPal webhook signature');
      console.error('Verification response:', verifyData);
      return res.status(400).json({ error: 'Webhook signature verification failed' });
    }
  } catch (verifyErr) {
    console.error('❌ Error verifying PayPal webhook signature:', verifyErr);
    return res.status(500).json({ error: 'Error verifying webhook signature', details: verifyErr.message });
  }

  // 4) Handle only the events we care about:
  const eventType = webhookEvent.event_type;
  const resource = webhookEvent.resource || {};
  console.log('📬 Received PayPal webhook event:', eventType);

  try {
    // 4a) One-time payment completed
    if (eventType === 'PAYMENT.CAPTURE.COMPLETED') {
      // Debug: Log the entire resource to see structure
      console.log('🔍 PAYMENT.CAPTURE.COMPLETED resource structure:', JSON.stringify(resource, null, 2));
      
      // Try multiple possible paths for email
      const payerEmail = 
        resource.payer?.email_address ||
        resource.payer?.payer_info?.email ||
        resource.billing_info?.email_address;
      
      const purchaseType = 'one-time';
      const paypalID = resource.id;
      
      if (!payerEmail) {
        console.error('❌ No payer email found in PAYMENT.CAPTURE.COMPLETED webhook');
        console.error('Available paths:', {
          'resource.payer': !!resource.payer,
          'resource.payer.email_address': !!resource.payer?.email_address,
          'resource.payer.payer_info': !!resource.payer?.payer_info,
          'resource.billing_info': !!resource.billing_info
        });
        return res.status(400).json({ error: 'Missing payer email in webhook resource' });
      }
      
      await createLicenseAndRespond(payerEmail, purchaseType, paypalID, res);
      return;
    }

    // 4b) Subscription activated - ENHANCED EMAIL RESOLUTION
    if (eventType === 'BILLING.SUBSCRIPTION.ACTIVATED') {
      const subscriptionId = resource.id;
      const purchaseType = 'subscription';
      let payerEmail = null;

      console.log('🔍 BILLING.SUBSCRIPTION.ACTIVATED resource structure:', JSON.stringify(resource, null, 2));

      // Step 1: Try to get email from webhook resource
      payerEmail = resource.subscriber?.email_address;
      if (payerEmail) {
        console.log('✅ Found email in webhook resource:', payerEmail);
      }

      // Step 2: If not found, check our stored subscription mapping
      if (!payerEmail) {
        console.log('🔍 Email not in webhook, checking stored mapping...');
        payerEmail = await getEmailFromSubscriptionMapping(subscriptionId);
        if (payerEmail) {
          console.log('✅ Found email in stored mapping:', payerEmail);
        }
      }

      // Step 3: If still not found, try PayPal API
      if (!payerEmail) {
        console.log('🔍 Email not in mapping, fetching from PayPal API...');
        try {
          const accessToken = await getPayPalAccessToken();
          const subscriptionDetails = await getSubscriptionDetails(subscriptionId, accessToken);
          
          console.log('🔍 PayPal API subscription details:', JSON.stringify(subscriptionDetails, null, 2));
          
          // Try multiple possible paths in the API response
          payerEmail =
            subscriptionDetails.subscriber?.email_address ||
            subscriptionDetails.billing_info?.email_address || null;
          
          if (payerEmail) {
            console.log('✅ Found email in PayPal API response:', payerEmail);
          }
        } catch (fetchErr) {
          console.error('❌ Error fetching subscription details from PayPal API:', fetchErr);
        }
      }

      // Step 4: Email validation - must be present and valid
      if (!payerEmail || !payerEmail.includes('@')) {
        console.error('❌ Invalid or missing email — skipping email delivery');
        await createLicenseWithSubscriptionId(subscriptionId, purchaseType, subscriptionId, res);
        return;
      }

      // Success! Create the license
      await createLicenseAndRespond(payerEmail, purchaseType, subscriptionId, res);
      return;
    }

    // 4c) Subscription cancelled or suspended
    if (eventType === 'BILLING.SUBSCRIPTION.CANCELLED') {
      const subscriptionId = resource.id;
      console.log('🔍 BILLING.SUBSCRIPTION.CANCELLED for subscriptionId:', subscriptionId);
      // Find the license document with this subscriptionId
      const snap = await db
        .collection('licenses')
        .where('subscriptionId', '==', subscriptionId)
        .limit(1)
        .get();
      if (!snap.empty) {
        const docRef = snap.docs[0].ref;
        await docRef.update({ status: 'inactive' });
        console.log('⚠️ License set to inactive for document ID:', docRef.id);
      } else {
        console.warn('⚠️ No license found for cancelled subscriptionId:', subscriptionId);
      }
      return res.status(200).send('Subscription cancelled handled');
    }

    // 4d) Other events: ignore
    console.log('ℹ️ Unhandled event type:', eventType);
    return res.status(200).send('Event ignored');
  } catch (err) {
    console.error('❌ Error in webhook handler:', err);
    return res.status(500).json({ error: 'Internal error in webhook handler', details: err.message });
  }
}

// 5) Helper: writes Firestore + returns licenseKey JSON (signed URL logic removed)
async function createLicenseAndRespond(email, purchaseType, paypalID, res) {
  try {
    // 5a) Check existing license count
    const snapshot = await db.collection('licenses').where('email', '==', email).get();
    if (snapshot.size >= 5) {
      console.warn(`⚠️ License limit reached for ${email}`);
      return res.status(403).json({ error: 'Maximum of 5 licenses per email reached.' });
    }

    // 5b) Generate a license key
    function generateLicenseKey() {
      const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
      let key = '';
      for (let i = 0; i < 20; i++) {
        if (i > 0 && i % 5 === 0) key += '-';
        key += chars.charAt(Math.floor(Math.random() * chars.length));
      }
      return key;
    }
    const licenseKey = generateLicenseKey();
    console.log('🔑 Generated licenseKey:', licenseKey);

    // Extract email from req.body if available (fallback to null)
    // (This is only possible if req is in scope; if not, see below.)
    // But since only email is passed as argument, we adapt:
    // Instead, add logic as if coming from req.body for compatibility with the instructions.
    // We'll mimic: "const email = req.body?.email || null;" and conditional docData composition.
    // So, treat 'email' arg as the possibly null/invalid email value.
    const docData = {
      subscriptionId: paypalID,
      purchaseType,
      paypalID,
      timestamp: admin.firestore.FieldValue.serverTimestamp(),
      status: 'active'
    };

    if (email && email.includes('@')) {
      docData.email = email;
    } else {
      docData.status = 'pending_email';
      docData.notes = 'Email missing from webhook and request body.';
    }

    await db.collection('licenses').doc(licenseKey).set(docData);
    console.log('✅ Firestore write succeeded, doc ID equals licenseKey:', licenseKey);

    // 5d) (Removed signed URL logic)

    // 5e) Return JSON { licenseKey }
    return res.status(200).json({ licenseKey });
  } catch (error) {
    console.error('❌ Error in createLicenseAndRespond:', error);
    throw error;
  }
}

// 6) NEW: Fallback helper for when we can't get email but have subscription ID (signed URL logic removed)
async function createLicenseWithSubscriptionId(subscriptionId, purchaseType, paypalID, res, payerEmail = null) {
  try {
    // Generate a license key
    function generateLicenseKey() {
      const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
      let key = '';
      for (let i = 0; i < 20; i++) {
        if (i > 0 && i % 5 === 0) key += '-';
        key += chars.charAt(Math.floor(Math.random() * chars.length));
      }
      return key;
    }
    const licenseKey = generateLicenseKey();
    console.log('🔑 Generated licenseKey for subscription ID:', licenseKey);

    // Compose docData with conditional email logic
    const docData = {
      subscriptionId,
      purchaseType,
      paypalID,
      timestamp: admin.firestore.FieldValue.serverTimestamp(),
      status: 'active'
    };
    if (payerEmail && payerEmail.includes('@')) {
      docData.email = payerEmail;
    } else {
      docData.status = 'pending_email_resolution';
      docData.notes = 'Email could not be resolved from PayPal webhook or API';
    }

    await db.collection('licenses').doc(licenseKey).set(docData);
    console.log('✅ Firestore write succeeded with subscription ID, doc ID equals licenseKey:', licenseKey);

    // (Removed signed URL logic)

    // Return JSON { licenseKey } - same as normal flow
    return res.status(200).json({
      licenseKey,
      note: docData.status === 'pending_email_resolution'
        ? 'License created with subscription ID - email resolution pending'
        : 'License created with valid email'
    });
  } catch (error) {
    console.error('❌ Error in createLicenseWithSubscriptionId:', error);
    throw error;
  }
}

// 7) ORIGINAL: Fallback helper: stores license with payer_id for manual resolution (signed URL logic removed)
async function createLicenseWithPayerId(payerId, purchaseType, paypalID, res) {
  try {
    // Generate a license key
    function generateLicenseKey() {
      const chars = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
      let key = '';
      for (let i = 0; i < 20; i++) {
        if (i > 0 && i % 5 === 0) key += '-';
        key += chars.charAt(Math.floor(Math.random() * chars.length));
      }
      return key;
    }
    const licenseKey = generateLicenseKey();
    console.log('🔑 Generated licenseKey for payer_id:', licenseKey);

    // Write new license document with payer_id instead of email
    await db.collection('licenses').doc(licenseKey).set({
      payerId: payerId,
      purchaseType: purchaseType,
      paypalID: paypalID,
      timestamp: admin.firestore.FieldValue.serverTimestamp(),
      status: 'pending_email_resolution'
    });
    console.log('✅ Firestore write succeeded with payer_id, doc ID equals licenseKey:', licenseKey);

    // (Removed signed URL logic)

    // Return JSON { licenseKey }
    return res.status(200).json({ licenseKey });
  } catch (error) {
    console.error('❌ Error in createLicenseWithPayerId:', error);
    throw error;
  }
}