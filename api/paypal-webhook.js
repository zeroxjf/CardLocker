// File: api/paypal-webhook.js

import { getDownloadUrl } from '@vercel/blob';
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

    // 4b) Subscription activated
    if (eventType === 'BILLING.SUBSCRIPTION.ACTIVATED') {
      // Debug: Log the entire resource to see structure
      console.log('🔍 BILLING.SUBSCRIPTION.ACTIVATED resource structure:', JSON.stringify(resource, null, 2));
      
      const subscriptionId = resource.id;
      const purchaseType = 'subscription';
      
      if (!subscriptionId) {
        console.error('❌ No subscription ID found in BILLING.SUBSCRIPTION.ACTIVATED webhook');
        return res.status(400).json({ error: 'Missing subscription ID in webhook resource' });
      }
      
      try {
        // Get access token and fetch full subscription details
        const accessToken = await getPayPalAccessToken();
        const subscriptionDetails = await getSubscriptionDetails(subscriptionId, accessToken);
        
        console.log('🔍 Full subscription details:', JSON.stringify(subscriptionDetails, null, 2));
        
        // Try to extract email from full subscription details
        const payerEmail = 
          subscriptionDetails.subscriber?.email_address ||
          subscriptionDetails.subscriber?.payer_info?.email ||
          subscriptionDetails.application_context?.customer?.email_address ||
          subscriptionDetails.payer?.email_address;
        
        if (!payerEmail) {
          console.error('❌ No subscriber email found in full subscription details');
          console.error('Available paths in full details:', {
            'subscriber': !!subscriptionDetails.subscriber,
            'subscriber.email_address': !!subscriptionDetails.subscriber?.email_address,
            'subscriber.payer_info': !!subscriptionDetails.subscriber?.payer_info,
            'application_context': !!subscriptionDetails.application_context,
            'payer': !!subscriptionDetails.payer
          });
          
          // Fallback: Store with payer_id and manual resolution needed
          const payerId = resource.subscriber?.payer_id;
          if (payerId) {
            console.warn('⚠️ Storing subscription with payer_id for manual resolution:', payerId);
            await createLicenseWithPayerId(payerId, purchaseType, subscriptionId, res);
            return;
          } else {
            return res.status(400).json({ error: 'Unable to identify subscriber - no email or payer_id found' });
          }
        }
        
        await createLicenseAndRespond(payerEmail, purchaseType, subscriptionId, res);
        return;
        
      } catch (apiErr) {
        console.error('❌ Error fetching subscription details:', apiErr);
        
        // Fallback: Store with payer_id for manual resolution
        const payerId = resource.subscriber?.payer_id;
        if (payerId) {
          console.warn('⚠️ API call failed, storing subscription with payer_id for manual resolution:', payerId);
          await createLicenseWithPayerId(payerId, purchaseType, subscriptionId, res);
          return;
        } else {
          return res.status(500).json({ error: 'Failed to get subscription details and no payer_id available' });
        }
      }
    }

    // 4c) Other events: ignore
    console.log('ℹ️ Unhandled event type:', eventType);
    return res.status(200).send('Event ignored');
  } catch (err) {
    console.error('❌ Error in webhook handler:', err);
    return res.status(500).json({ error: 'Internal error in webhook handler', details: err.message });
  }
}

// 5) Helper: writes Firestore + returns signed URL JSON
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

    // 5c) Write new license document
    const newDoc = await db.collection('licenses').add({
      email: email,
      licenseKey: licenseKey,
      purchaseType: purchaseType,
      paypalID: paypalID,
      timestamp: admin.firestore.FieldValue.serverTimestamp(),
    });
    console.log('✅ Firestore write succeeded, doc ID:', newDoc.id);

    // 5d) Generate a signed URL for the DMG
    const fullBlobUrl =
      'https://qinhuscfvbuurprs.public.blob.vercel-storage.com/cardlocker/' +
      'CardLocker-qNcAFlKgf0ku0HXcgI0DXm3utFmtoZ.dmg';
    console.log('🔗 Generating signed URL for:', fullBlobUrl);

    const signedUrl = await getDownloadUrl(fullBlobUrl, {
      token: process.env.BLOB_READ_WRITE_TOKEN,
      expiresIn: 60 * 5, // 5 minutes
    });
    console.log('🔒 Signed URL generated:', signedUrl);

    // 5e) Return JSON { licenseKey, signedUrl }
    return res.status(200).json({ licenseKey, signedUrl });
  } catch (error) {
    console.error('❌ Error in createLicenseAndRespond:', error);
    throw error;
  }
}

// 6) Fallback helper: stores license with payer_id for manual resolution
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
    const newDoc = await db.collection('licenses').add({
      payerId: payerId, // Store payer_id instead of email
      licenseKey: licenseKey,
      purchaseType: purchaseType,
      paypalID: paypalID,
      timestamp: admin.firestore.FieldValue.serverTimestamp(),
      status: 'pending_email_resolution', // Flag for manual resolution
    });
    console.log('✅ Firestore write succeeded with payer_id, doc ID:', newDoc.id);

    // Generate a signed URL for the DMG
    const fullBlobUrl =
      'https://qinhuscfvbuurprs.public.blob.vercel-storage.com/cardlocker/' +
      'CardLocker-qNcAFlKgf0ku0HXcgI0DXm3utFmtoZ.dmg';
    console.log('🔗 Generating signed URL for:', fullBlobUrl);

    const signedUrl = await getDownloadUrl(fullBlobUrl, {
      token: process.env.BLOB_READ_WRITE_TOKEN,
      expiresIn: 60 * 5, // 5 minutes
    });
    console.log('🔒 Signed URL generated:', signedUrl);

    // Return JSON { licenseKey, signedUrl } - same as normal flow
    return res.status(200).json({ licenseKey, signedUrl });
  } catch (error) {
    console.error('❌ Error in createLicenseWithPayerId:', error);
    throw error;
  }
}