// File: api/merchant-cancel-subscription.js

import admin from 'firebase-admin';
import fetch from 'node-fetch';

// Initialize Firebase Admin if necessary
if (!admin.apps.length) {
  const serviceAccount = JSON.parse(process.env.FIREBASE_SERVICE_ACCOUNT);
  admin.initializeApp({ credential: admin.credential.cert(serviceAccount) });
}
const db = admin.firestore();

// Helper to get a PayPal access token
async function getPayPalAccessToken() {
  const clientId = process.env.PAYPAL_CLIENT_ID;
  const clientSecret = process.env.PAYPAL_CLIENT_SECRET;
  const auth = Buffer.from(`${clientId}:${clientSecret}`).toString('base64');
  
  const response = await fetch('https://api-m.paypal.com/v1/oauth2/token', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/x-www-form-urlencoded',
      'Authorization': `Basic ${auth}`
    },
    body: 'grant_type=client_credentials'
  });
  const data = await response.json();
  return data.access_token; // e.g. "A21AAK…"
}

export default async function handler(req, res) {
  if (req.method !== 'POST') {
    return res.status(405).json({ error: 'Method Not Allowed' });
  }

  const { licenseKey } = req.body;
  if (!licenseKey) {
    return res.status(400).json({ error: 'Missing licenseKey' });
  }

  // 1) Look up the Firestore document to find paypalID
  const docRef = db.collection('licenses').doc(licenseKey);
  const docSnap = await docRef.get();
  if (!docSnap.exists) {
    return res.status(404).json({ error: 'License not found' });
  }
  const { paypalID, purchaseType, status } = docSnap.data();
  if (purchaseType !== 'subscription' || status !== 'active') {
    return res.status(400).json({ error: 'Not an active subscription' });
  }

  try {
    // 2) Cancel via PayPal API
    const accessToken = await getPayPalAccessToken();
    const cancelResponse = await fetch(
      `https://api-m.paypal.com/v1/billing/subscriptions/${paypalID}/cancel`,
      {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          'Authorization': `Bearer ${accessToken}`
        },
        body: JSON.stringify({ reason: 'Customer requested cancellation' })
      }
    );

    if (!cancelResponse.ok) {
      const errData = await cancelResponse.json();
      console.error('❌ PayPal cancel failed:', errData);
      return res.status(500).json({ error: 'PayPal cancel failed', details: errData });
    }

    // 3) Now your webhook (paypal-webhook.js) will mark status: 'inactive' in Firestore.
    // Return success so your frontend can show a “Cancelled” confirmation.
    return res.status(200).json({ success: true, message: 'Subscription cancelled. Check your email for confirmation.' });
  } catch (err) {
    console.error('❌ Error cancelling subscription:', err);
    return res.status(500).json({ error: 'Internal server error' });
  }
}