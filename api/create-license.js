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
    const { email, purchaseType, paypalID, resourceId } = req.body;

    // 1) Basic field validation
    if (!email || !purchaseType || (purchaseType === 'subscription' && !resourceId) || (purchaseType !== 'subscription' && !paypalID)) {
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


    // 6) Construct the Firestore document data exactly as email trigger expects
const docData = {
  email: email,
  purchaseType: purchaseType,
  timestamp: admin.firestore.FieldValue.serverTimestamp(),
  status: 'active',
};

if (purchaseType === 'subscription') {
  docData.subscriptionId = resourceId; // I-... format used by PayPal
  docData.paypalID = resourceId;
} else {
  docData.paypalID = paypalID;
}

    await db.collection('licenses').doc(licenseKey).set(docData);
    console.log('✅ Firestore write succeeded, doc ID =', licenseKey);

    // 7) Generate a signed URL for the DMG
    const fullBlobUrl = process.env.BLOB_FILE_URL;
    const signedUrl = await getDownloadUrl(fullBlobUrl, {
      token: process.env.BLOB_READ_WRITE_TOKEN,
      expiresIn: 60 * 5 // 5 minutes
    });

    // 8) Return payload (no manageSubscriptionUrl)
    return res.status(200).json({ licenseKey, signedUrl });

  } catch (err) {
    console.error('❌ Error in /api/create-license:', err);
    return res.status(500).json({ error: 'Internal Server Error', details: err.message });
  }
}