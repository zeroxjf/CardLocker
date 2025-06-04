// File: api/purchase.js

import admin from 'firebase-admin';
import { getDownloadUrl } from '@vercel/blob';

//
// Load service account credentials from environment variable
//
const serviceAccount = JSON.parse(process.env.FIREBASE_SERVICE_ACCOUNT);
if (!admin.apps.length) {
  admin.initializeApp({
    credential: admin.credential.cert(serviceAccount)
  });
}

const db = admin.firestore();

export default async function handler(req, res) {
  console.log('purchase handler invoked, body:', req.body);
  // Only allow POST
  if (req.method !== 'POST') {
    return res.status(405).json({ error: 'Method not allowed' });
  }

  try {
    //
    // 2) Extract request fields
    //
    const { email } = req.body;
    if (!email || typeof email !== 'string') {
      return res.status(400).json({ error: 'Missing or invalid email' });
    }

    // (Optional) You could also pass other fields: purchaseType, payPalID, etc.

    //
    // 3) Check how many licenses already exist for that email
    //
    const existing = await db
      .collection('licenses')
      .where('email', '==', email)
      .get();

    if (existing.size >= 5) {
      return res
        .status(403)
        .json({ error: 'Maximum of 5 licenses per email reached.' });
    }

    //
    // 4) Generate a new licenseKey (you can use your existing logic or import a helper)
    //
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

    //
    // 5) Write to Firestore
    //
    const newDoc = await db.collection('licenses').add({
      email: email,
      licenseKey: licenseKey,
      purchaseType: 'server-simulation', // or 'subscription' / 'one-time'
      paypalID: 'SERVER-TEST-' + Date.now(),
      timestamp: admin.firestore.FieldValue.serverTimestamp()
    });

    // If we reach here, Firestore write succeeded.

    //
    // 6) Now generate a signed URL (5-minute TTL) for the DMG in Blob
    //
    //    Make sure your BLOB_READ_WRITE_TOKEN is set in Vercel’s Environment Variables.
    //
    const fullBlobUrl =
      'https://qinhuscfvbuurprs.public.blob.vercel-storage.com/cardlocker/' +
      'CardLocker-qNcAFlKgf0ku0HXcgI0DXm3utFmtoZ.dmg';

    const signedUrl = await getDownloadUrl(fullBlobUrl, {
      token: process.env.BLOB_READ_WRITE_TOKEN,
      expiresIn: 60 * 5 // 5 minutes
    });

    //
    // 7) Return both the newly created licenseKey (and/or doc ID) plus the signed URL
    //
    return res.status(200).json({
      licenseKey: licenseKey,
      signedUrl: signedUrl
    });
  } catch (err) {
    console.error('purchase.js error:', err);
    return res.status(500).json({ error: 'Internal server error', details: err.message });
  }
}