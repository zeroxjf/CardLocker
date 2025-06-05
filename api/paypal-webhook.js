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

// Import the signature verification function
import { verifyWebhookSignature } from './paypal';

// 3) Main webhook handler
export default async function handler(req, res) {
  if (req.method !== 'POST') {
    return res.status(405).send('Method not allowed');
  }

  // If the request is a manual trigger from the frontend, handle email + subscriptionId directly
  if (
    req.body &&
    typeof req.body === 'object' &&
    req.body.subscriptionId &&
    req.body.email
  ) {
    // This is a manual POST from the frontend after PayPal approval, not a PayPal webhook
    const { subscriptionId, email } = req.body;
    if (!isValidEmail(email)) {
      console.warn('⚠️ Invalid email format:', email);
      return res.status(400).json({ error: 'Invalid email address' });
    }
    const licenseKey = generateLicenseKey();
    await db.collection('licenses').doc(licenseKey).set({
      subscriptionId,
      email,
      licenseKey,
      timestamp: admin.firestore.FieldValue.serverTimestamp(),
      purchaseType: 'subscription'
    });
    return res.status(200).json({ licenseKey });
  }

  // Otherwise, handle as PayPal webhook (original logic below)
  // Get raw body for verification (critical for PayPal verification)
  let rawBody;
  let webhookEvent;
  try {
    if (req.body && typeof req.body === 'object') {
      rawBody = JSON.stringify(req.body);
      webhookEvent = req.body;
    } else {
      rawBody = await getRawBody(req);
      webhookEvent = JSON.parse(rawBody);
    }
  } catch (err) {
    console.error('❌ Error parsing webhook body:', err);
    return res.status(400).json({ error: 'Invalid JSON body' });
  }

  // Signature verification: must happen before any business logic or Firestore writes
  const isValid = await verifyWebhookSignature(req.headers, req.body);
  if (!isValid) {
    console.warn('❌ Invalid PayPal webhook signature');
    return res.status(400).send('Invalid signature');
  }
  console.log('✅ Webhook signature verified');

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

import { randomBytes } from 'crypto';

// Helper to generate a unique license key in Firestore
async function generateUniqueLicenseKey() {
  const db = admin.firestore();
  let licenseKey;
  let exists = true;

  while (exists) {
    licenseKey = randomBytes(6).toString('hex'); // e.g. "a3f1e2b4c5d6"
    const doc = await db.collection('licenses').doc(licenseKey).get();
    exists = doc.exists;
  }

  return licenseKey;
}

// 5) Helper: writes Firestore + returns licenseKey JSON (signed URL logic removed)
async function createLicenseAndRespond(email, purchaseType, paypalID, res) {
  try {
    // 5a) Check existing license count
    let emailToCheck = email && typeof email === "string" ? email : null;
    if (!emailToCheck && res && res.req && res.req.body && res.req.body.email) {
      emailToCheck = res.req.body.email;
    }
    // If email is present, enforce license count limit
    if (emailToCheck && emailToCheck.includes('@')) {
      if (!isValidEmail(emailToCheck)) {
        console.warn('⚠️ Invalid email format');
        return res.status(400).json({ error: 'Invalid email address' });
      }
      const snapshot = await db.collection('licenses').where('email', '==', emailToCheck).get();
      if (snapshot.size >= 5) {
        console.warn('⚠️ License limit reached for this email');
        return res.status(403).json({ error: 'Maximum of 5 licenses per email reached.' });
      }
    }

    // 5b) Generate a unique license key
    const licenseKey = await generateUniqueLicenseKey();
    console.log('🔑 License issued (ID redacted for security)');

    // Compose docData, ensuring email is included if available
    let docData = {
      licenseKey: licenseKey,
      purchaseType,
      paypalID,
      timestamp: admin.firestore.FieldValue.serverTimestamp(),
      status: 'active'
    };
    // For subscriptions, store subscriptionId as well
    if (purchaseType === 'subscription') {
      docData.subscriptionId = paypalID;
    }

    // Try to get email from all possible sources: argument or req.body (for manual trigger)
    let userEmailFromForm = null;
    if (email && email.includes('@')) {
      userEmailFromForm = email;
    } else if (res && res.req && res.req.body && res.req.body.email && res.req.body.email.includes('@')) {
      userEmailFromForm = res.req.body.email;
    }
    if (userEmailFromForm) {
      if (!isValidEmail(userEmailFromForm)) {
        console.warn('⚠️ Invalid email format');
        return res.status(400).json({ error: 'Invalid email address' });
      }
      docData.email = userEmailFromForm;
    } else {
      docData.status = 'pending_email';
      docData.notes = 'Email missing from webhook and request body.';
    }

    await db.collection('licenses').doc(licenseKey).set(docData);
    console.log('📄 Firestore document created');

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
    // Generate a unique license key
    const licenseKey = await generateUniqueLicenseKey();
    console.log('🔑 License issued (ID redacted for security)');

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
    console.log('📄 Firestore document created');

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
    // Generate a unique license key
    const licenseKey = await generateUniqueLicenseKey();
    console.log('🔑 License issued (ID redacted for security)');

    // Write new license document with payer_id instead of email
    await db.collection('licenses').doc(licenseKey).set({
      payerId: payerId,
      purchaseType: purchaseType,
      paypalID: paypalID,
      timestamp: admin.firestore.FieldValue.serverTimestamp(),
      status: 'pending_email_resolution'
    });
    console.log('📄 Firestore document created');

    // (Removed signed URL logic)

    // Return JSON { licenseKey }
    return res.status(200).json({ licenseKey });
  } catch (error) {
    console.error('❌ Error in createLicenseWithPayerId:', error);
    throw error;
  }
}
// Helper to validate email format
function isValidEmail(email) {
  if (typeof email !== "string") return false;
  return /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email);
}