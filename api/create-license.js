// File: api/create-license.js

import admin from 'firebase-admin';
import { getDownloadUrl } from '@vercel/blob';

// Initialize Firebase Admin (if not already initialized)
if (!admin.apps.length) {
  const serviceAccount = JSON.parse(process.env.FIREBASE_SERVICE_ACCOUNT);
  admin.initializeApp({ credential: admin.credential.cert(serviceAccount) });
}
const db = admin.firestore();

export default async function handler(req, res) {
  if (req.method !== 'POST') {
    return res.status(405).json({ error: 'Method Not Allowed' });
  }

  try {
    const { email, purchaseType, paypalID } = req.body;

    // 1) Basic field validation
    if (!email || !purchaseType || !paypalID) {
      return res.status(400).json({ error: 'Missing fields' });
    }

    // 2) Optional: Basic email format check
    const emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
    if (!emailRegex.test(email)) {
      return res.status(400).json({ error: 'Invalid email format' });
    }

    // 3) Check “max 5 licenses per email” rule
    const snapshot = await db.collection('licenses').where('email', '==', email).get();
    if (snapshot.size >= 5) {
      return res.status(403).json({ error: 'Maximum of 5 licenses per email reached.' });
    }

    // 4) Generate a 20-character licenseKey (groups of 5, separated by “-”)
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

    // 5) Build “manageSubscriptionUrl” if this is a subscription purchase
    let manageSubscriptionUrl = null;
    if (purchaseType === 'subscription') {
      const baseUrl =
        process.env.NODE_ENV === 'production'
          ? 'https://www.paypal.com/webapps/billing/subscription/manage?ba_id='
          : 'https://www.sandbox.paypal.com/webapps/billing/subscription/manage?ba_id=';
      manageSubscriptionUrl = `${baseUrl}${paypalID}`;
    }

    // 6) Construct the Firestore document data exactly as email trigger expects
    const docData = {
      email: email,                                  // (A): must match sendPurchaseConfirmation
      purchaseType: purchaseType,                    // (C): “subscription” or “one-time”
      paypalID: paypalID,                            // merchant’s PayPal subscription or ID
      timestamp: admin.firestore.FieldValue.serverTimestamp(),
      status: 'active',
    };
    if (manageSubscriptionUrl) {
      docData.manageSubscriptionUrl = manageSubscriptionUrl; // (D): optional for subscription
    }

    await db.collection('licenses').doc(licenseKey).set(docData);
    console.log('✅ Firestore write succeeded, doc ID =', licenseKey);

    // 7) Generate a signed URL for the DMG
    const fullBlobUrl = process.env.BLOB_FILE_URL;
    const signedUrl = await getDownloadUrl(fullBlobUrl, {
      token: process.env.BLOB_READ_WRITE_TOKEN,
      expiresIn: 60 * 5 // 5 minutes
    });

    // 8) Return payload (include manageSubscriptionUrl if subscription)
    const responsePayload = { licenseKey, signedUrl };
    if (manageSubscriptionUrl) {
      responsePayload.manageSubscriptionUrl = manageSubscriptionUrl;
    }
    return res.status(200).json(responsePayload);

  } catch (err) {
    console.error('❌ Error in /api/create-license:', err);
    return res.status(500).json({ error: 'Internal Server Error', details: err.message });
  }
}