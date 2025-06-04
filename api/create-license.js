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
    if (!email || !purchaseType || !paypalID) {
      return res.status(400).json({ error: 'Missing fields' });
    }

    // Optional: Basic email format validation
    const emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
    if (!emailRegex.test(email)) {
      return res.status(400).json({ error: 'Invalid email format' });
    }

    // 1) Check if they already have 5+ licenses (same as existing logic)
    const snapshot = await db.collection('licenses').where('email', '==', email).get();
    if (snapshot.size >= 5) {
      return res.status(403).json({ error: 'Maximum of 5 licenses per email reached.' });
    }

    // 2) Generate a new 20‐character key
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

    // 3) Write the new license to Firestore
    const newDoc = await db.collection('licenses').add({
      email: email,
      licenseKey: licenseKey,
      purchaseType: purchaseType,
      paypalID: paypalID,
      timestamp: admin.firestore.FieldValue.serverTimestamp()
    });
    console.log('✅ Firestore write succeeded, doc ID:', newDoc.id);

    // 4) Generate a signed URL for the DMG
    const fullBlobUrl = process.env.BLOB_FILE_URL;
    const signedUrl = await getDownloadUrl(fullBlobUrl, {
      token: process.env.BLOB_READ_WRITE_TOKEN,
      expiresIn: 60 * 5    // 5 minutes
    });

    // 5) Return to the client
    return res.status(200).json({ licenseKey, signedUrl });
  } catch (err) {
    console.error('❌ Error in /api/create-license:', err);
    return res.status(500).json({ error: 'Internal Server Error', details: err.message });
  }
}