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
  // Confirmation check for GET requests with licenseKey but not confirm=true
  if (req.method === 'GET' && req.query.licenseKey && req.query.confirm !== 'true') {
    return res.send(`
      <html>
        <body style="font-family: sans-serif; max-width: 600px; margin: auto; padding: 2rem;">
          <h2>Cancel Your Subscription</h2>
          <p>This action will permanently cancel your subscription and deactivate your license.</p>
          <p>If you're sure, click the button below:</p>
          <p>
            <a href="/api/merchant-cancel-subscription?licenseKey=${req.query.licenseKey}&confirm=true"
               style="background: #d00; color: #fff; padding: 0.75rem 1.5rem; text-decoration: none; border-radius: 4px;">
              Yes, Cancel My Subscription
            </a>
          </p>
        </body>
      </html>
    `);
  }

  // Support both POST (API) and GET (with confirm=true) for cancellation
  let licenseKey;
  if (req.method === 'POST') {
    licenseKey = req.body.licenseKey;
  } else if (req.method === 'GET' && req.query.licenseKey && req.query.confirm === 'true') {
    licenseKey = req.query.licenseKey;
  } else {
    return res.status(405).json({ error: 'Method Not Allowed' });
  }

  if (!licenseKey) {
    return res.status(400).json({ error: 'Missing licenseKey' });
  }

  // 1) Look up the Firestore document to find paypalID
  const docRef = db.collection('licenses').doc(licenseKey);
  const docSnap = await docRef.get();
  if (!docSnap.exists) {
    return res.status(404).json({ error: 'License not found' });
  }
  const { subscriptionId, purchaseType, status } = docSnap.data();
  if (!subscriptionId) {
    return res.status(500).json({ error: 'No subscriptionId stored for this license' });
  }
  if (purchaseType !== 'subscription' || status !== 'active') {
    return res.status(400).json({ error: 'Not an active subscription' });
  }

  try {
    // 2) Cancel via PayPal API
    const accessToken = await getPayPalAccessToken();
    const cancelResponse = await fetch(
      `https://api-m.paypal.com/v1/billing/subscriptions/${subscriptionId}/cancel`,
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
    // For GET requests, show a simple HTML confirmation
    if (req.method === 'GET') {
      return res.send(`
        <html>
          <body style="font-family: sans-serif; max-width: 600px; margin: auto; padding: 2rem;">
            <h2>Subscription Cancelled</h2>
            <p>Your subscription has been cancelled. Check your email for confirmation.</p>
          </body>
        </html>
      `);
    }
    return res.status(200).json({ success: true, message: 'Subscription cancelled. Check your email for confirmation.' });
  } catch (err) {
    console.error('❌ Error cancelling subscription:', err);
    return res.status(500).json({ error: 'Internal server error' });
  }
}