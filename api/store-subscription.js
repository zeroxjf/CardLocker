// File: api/store-subscription.js

import admin from 'firebase-admin';

// Initialize Firebase Admin
if (!admin.apps.length) {
  try {
    const serviceAccount = JSON.parse(process.env.FIREBASE_SERVICE_ACCOUNT);
    admin.initializeApp({
      credential: admin.credential.cert(serviceAccount),
    });
  } catch (e) {
    console.error('❌ Error initializing Firebase Admin:', e);
  }
}

const db = admin.firestore();

export default async function handler(req, res) {
  // Only allow POST requests
  if (req.method !== 'POST') {
    return res.status(405).json({ error: 'Method not allowed' });
  }

  try {
    const { subscriptionId, email } = req.body;

    // Validate required fields
    if (!subscriptionId || !email) {
      return res.status(400).json({ 
        error: 'Missing required fields',
        required: ['subscriptionId', 'email']
      });
    }

    // Validate email format
    const emailRegex = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
    if (!emailRegex.test(email)) {
      return res.status(400).json({ error: 'Invalid email format' });
    }

    console.log('📝 Storing subscription mapping:', { subscriptionId, email });

    // Store the mapping in Firestore
    await db.collection('subscription_mappings').doc(subscriptionId).set({
      email: email,
      subscriptionId: subscriptionId,
      timestamp: admin.firestore.FieldValue.serverTimestamp(),
      status: 'pending_activation'
    });

    console.log('✅ Successfully stored subscription mapping');

    return res.status(200).json({ 
      success: true,
      message: 'Subscription mapping stored successfully'
    });

  } catch (error) {
    console.error('❌ Error storing subscription mapping:', error);
    return res.status(500).json({ 
      error: 'Internal server error',
      details: error.message 
    });
  }
}