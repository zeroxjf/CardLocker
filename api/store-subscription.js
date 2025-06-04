// File: api/store-subscription.js

import admin from 'firebase-admin';

// Initialize Firebase Admin if not already initalized
if (!admin.apps.length) {
  const serviceAccount = JSON.parse(process.env.FIREBASE_SERVICE_ACCOUNT);
  admin.initializeApp({
    credential: admin.credential.cert(serviceAccount),
  });
}
const db = admin.firestore();

export default async function handler(req, res) {
  if (req.method !== 'POST') {
    return res.status(405).send('Method Not Allowed');
  }
  try {
    const { subscriptionId, email } = req.body;
    if (!subscriptionId || !email) {
      return res.status(400).json({ error: 'Missing subscriptionId or email' });
    }
    // Write a doc under "pendingSubscriptions" keyed by subscriptionId
    await db
      .collection('pendingSubscriptions')
      .doc(subscriptionId)
      .set({ email });
    return res.status(200).json({ success: true });
  } catch (err) {
    console.error('Error writing pendingSubscriptions:', err);
    return res
      .status(500)
      .json({ error: 'Internal Server Error', details: err.message });
  }
}