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

// 3) Main webhook handler
export default async function handler(req, res) {
  if (req.method !== 'POST') {
    return res.status(405).send('Method not allowed');
  }

  // 3a) Gather PayPal headers
  const transmissionId = req.headers['paypal-transmission-id'];
  const transmissionTime = req.headers['paypal-transmission-time'];
  const certUrl = req.headers['paypal-cert-url'];
  const authAlgo = req.headers['paypal-auth-algo'];
  const actualSignature = req.headers['paypal-transmission-sig'];
  const webhookId = process.env.PAYPAL_WEBHOOK_ID;
  const webhookEvent = req.body;

  // Debug: Log all headers to identify what's missing
  console.log('📋 Webhook Headers Debug:');
  console.log('transmissionId:', transmissionId ? 'PRESENT' : 'MISSING');
  console.log('transmissionTime:', transmissionTime ? 'PRESENT' : 'MISSING');
  console.log('certUrl:', certUrl ? 'PRESENT' : 'MISSING');
  console.log('authAlgo:', authAlgo ? 'PRESENT' : 'MISSING');
  console.log('actualSignature:', actualSignature ? 'PRESENT' : 'MISSING');
  console.log('webhookId:', webhookId ? 'PRESENT' : 'MISSING');
  console.log('All headers:', Object.keys(req.headers).filter(h => h.startsWith('paypal')));

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

  // 3c) Build verification request
  const verifyRequest = {
    auth_algo: authAlgo,
    cert_url: certUrl,
    transmission_id: transmissionId,
    transmission_sig: actualSignature,
    transmission_time: transmissionTime,
    webhook_id: webhookId,
    webhook_event: webhookEvent,
  };

  // 3d) Perform signature verification using direct API call
  try {
    // Get access token for verification
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
    const accessToken = authData.access_token;

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
      throw new Error(`Verification failed: ${verifyResponse.status}`);
    }

    const verifyData = await verifyResponse.json();
    const verificationStatus = verifyData.verification_status;
    console.log('🔍 PayPal Webhook verification status:', verificationStatus);

    if (verificationStatus !== 'SUCCESS') {
      console.error('❌ Invalid PayPal webhook signature');
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
      const payerEmail = resource.payer?.email_address;
      const purchaseType = 'one-time';
      const paypalID = resource.id;
      if (!payerEmail) {
        console.error('❌ No payer email in PAYMENT.CAPTURE.COMPLETED webhook');
        return res.status(400).json({ error: 'Missing payer email in webhook resource' });
      }
      await createLicenseAndRespond(payerEmail, purchaseType, paypalID, res);
      return;
    }

    // 4b) Subscription activated
    if (eventType === 'BILLING.SUBSCRIPTION.ACTIVATED') {
      const payerEmail = resource.subscriber?.email_address;
      const purchaseType = 'subscription';
      const paypalID = resource.id;
      if (!payerEmail) {
        console.error('❌ No subscriber email in BILLING.SUBSCRIPTION.ACTIVATED webhook');
        return res.status(400).json({ error: 'Missing subscriber email in webhook resource' });
      }
      await createLicenseAndRespond(payerEmail, purchaseType, paypalID, res);
      return;
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