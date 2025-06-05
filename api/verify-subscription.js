// File: api/verify-subscription.js

import admin from 'firebase-admin';
import fetch from 'node-fetch';
import checkoutNodeJssdk from '@paypal/checkout-server-sdk';

// —————— 1) Initialize Firebase Admin ——————
if (!admin.apps.length) {
  const serviceAccount = JSON.parse(process.env.FIREBASE_SERVICE_ACCOUNT);
  admin.initializeApp({ credential: admin.credential.cert(serviceAccount) });
}
const db = admin.firestore();

// —————— 2) Initialize PayPal environment ——————
let paypalClient;
(function initPayPalClient() {
  const clientId = process.env.PAYPAL_CLIENT_ID;
  const clientSecret = process.env.PAYPAL_CLIENT_SECRET;
  if (!clientId || !clientSecret) {
    console.error('❌ Missing PayPal credentials');
    return;
  }

  const environment =
    process.env.NODE_ENV === 'production'
      ? new checkoutNodeJssdk.core.LiveEnvironment(clientId, clientSecret)
      : new checkoutNodeJssdk.core.SandboxEnvironment(clientId, clientSecret);

  paypalClient = new checkoutNodeJssdk.core.PayPalHttpClient(environment);
})();

// —————— 3) Helper: fetch a fresh PayPal access token ——————
async function getPayPalAccessToken() {
  const response = await fetch(
    `${
      process.env.NODE_ENV === 'production'
        ? 'https://api-m.paypal.com'
        : 'https://api-m.sandbox.paypal.com'
    }/v1/oauth2/token`,
    {
      method: 'POST',
      headers: {
        'Accept': 'application/json',
        'Accept-Language': 'en_US',
        'Authorization': `Basic ${Buffer.from(
          `${process.env.PAYPAL_CLIENT_ID}:${process.env.PAYPAL_CLIENT_SECRET}`
        ).toString('base64')}`,
        'Content-Type': 'application/x-www-form-urlencoded'
      },
      body: 'grant_type=client_credentials'
    }
  );

  if (!response.ok) {
    throw new Error(`Failed to get PayPal access token: ${response.status}`);
  }

  const json = await response.json();
  return json.access_token;
}

// —————— 4) Main handler ——————
export default async function handler(req, res) {
  // Only allow POST (or you can switch to GET if preferred)
  if (req.method !== 'POST') {
    return res.status(405).json({ error: 'Method Not Allowed' });
  }

  // Expect a JSON body like { "subscriptionId": "I-XXXXXXXX", "licenseKey": "ABCDE-12345-…" }
  const { subscriptionId: subscriptionIdFromBody, licenseKey } = req.body;
  let subscriptionId = subscriptionIdFromBody;
  if (!subscriptionId && !licenseKey) {
    return res
      .status(400)
      .json({ error: 'Must provide either subscriptionId or licenseKey' });
  }

  try {
    // ——— 4a) Lookup the Firestore doc if only licenseKey was provided ———
    let docRef;
    if (licenseKey) {
      // Direct lookup by document ID instead of querying a field
      const licenseDoc = await db.collection('licenses').doc(licenseKey).get();
      if (!licenseDoc.exists) {
        return res.status(404).json({ error: 'License not found' });
      }
      // Pull subscriptionId (prefer) or fallback to paypalID from the document data
      const data = licenseDoc.data();
      let subId = data.subscriptionId || data.paypalID;
      if (!subId) {
        return res.status(400).json({ error: 'No subscriptionId or paypalID on this license; cannot verify subscription status.' });
      }
      subscriptionId = subId;
      docRef = licenseDoc.ref;
    } else {
      // If the client passed subscriptionId, find the doc that has that field
      const snap = await db
        .collection('licenses')
        .where('subscriptionId', '==', subscriptionId)
        .limit(1)
        .get();
      if (snap.empty) {
        return res.status(404).json({ error: 'License not found for that subscriptionId' });
      }
      docRef = snap.docs[0].ref;
    }

    // ——— 4b) Call PayPal to get the current subscription details ———
    const accessToken = await getPayPalAccessToken();
    const paypalUrl =
      (process.env.NODE_ENV === 'production'
        ? 'https://api-m.paypal.com'
        : 'https://api-m.sandbox.paypal.com') +
      `/v1/billing/subscriptions/${encodeURIComponent(subscriptionId)}`;

    const ppResponse = await fetch(paypalUrl, {
      method: 'GET',
      headers: {
        'Authorization': `Bearer ${accessToken}`,
        'Content-Type': 'application/json'
      }
    });

    if (!ppResponse.ok) {
      // If the subscription no longer exists or PayPal returns an error, mark as inactive
      console.error(
        '⚠️ PayPal responded with status',
        ppResponse.status,
        'for subscriptionId',
        subscriptionId
      );
      await docRef.update({ status: 'inactive' });
      return res.status(200).json({ 
        subscriptionId,
        status: 'inactive',
        note: 'PayPal lookup failed or returned non-200, set to inactive' 
      });
    }

    const subData = await ppResponse.json();
    // Normalize PayPal status to lowercase
    const paypalStatus = subData.status?.toLowerCase() || 'unknown';
    // Only treat "active" as active; everything else is inactive
    const newStatus = paypalStatus === 'active' ? 'active' : 'inactive';

    // ——— 4c) Write the updated status field back into Firestore ———
    await docRef.update({ status: newStatus });

    return res.status(200).json({
      subscriptionId,
      status: newStatus,
      timestamp: admin.firestore.FieldValue.serverTimestamp()
    });
  } catch (err) {
    console.error('❌ Error in verify-subscription:', err);
    return res.status(500).json({ error: err.message });
  }
}