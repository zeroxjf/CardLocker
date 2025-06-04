// File: api/paypal-webhook.js

import { getDownloadUrl } from '@vercel/blob';
import admin from 'firebase-admin';
import CheckoutNodeJssdk from '@paypal/checkout-server-sdk';

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
      ? new CheckoutNodeJssdk.core.LiveEnvironment(clientId, clientSecret)
      : new CheckoutNodeJssdk.core.SandboxEnvironment(clientId, clientSecret);

  paypalClient = new CheckoutNodeJssdk.core.PayPalHttpClient(environment);
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

  // 3b) Build verification request
  const verifyRequest = {
    auth_algo: authAlgo,
    cert_url: certUrl,
    transmission_id: transmissionId,
    transmission_sig: actualSignature,
    transmission_time: transmissionTime,
    webhook_id: webhookId,
    webhook_event: webhookEvent,
  };

  // 3c) Verify signature
  try {
    const request = new CheckoutNodeJssdk.notification.VerifyWebhookSignatureRequest();
    request.requestBody(verifyRequest);
    const response = await paypalClient.execute(request);
    const verificationStatus = response.result.verification_status;
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
}