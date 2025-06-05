// File: api/check-license.js

import admin from 'firebase-admin';

// Initialize Admin if needed (similar to purchase.js)
if (!admin.apps.length) {
  try {
    const serviceAccount = JSON.parse(process.env.FIREBASE_SERVICE_ACCOUNT);
    admin.initializeApp({ credential: admin.credential.cert(serviceAccount) });
    console.log('✅ Firebase Admin initialized.');
  } catch (e) {
    console.error('❌ Firebase Admin failed to initialize:', e);
    return res.status(500).json({ error: 'Failed to initialize Firebase Admin', details: e.message });
  }
}
const db = admin.firestore();

export default async function handler(req, res) {
  const { paypalId } = req.query;
  if (!paypalId) {
    return res.status(400).json({ error: 'Missing paypalId parameter' });
  }
  try {
    console.log('🔍 Querying licenses with paypalID:', paypalId);
    const snapshot = await db.collection('licenses').where('paypalID', '==', paypalId).get();
    if (snapshot.empty) {
      return res.status(200).json({ found: false });
    }
    // If multiple licenses exist, pick the newest one by timestamp, with logging and guards for bad data
    let newestDoc = null;
    snapshot.forEach(doc => {
      const data = doc.data();
      if (!data.timestamp || typeof data.timestamp.toMillis !== 'function') {
        console.warn('⚠️ Skipping document with invalid or missing timestamp:', doc.id);
        return;
      }
      try {
        if (
          !newestDoc ||
          (newestDoc.data().timestamp &&
           typeof newestDoc.data().timestamp.toMillis === 'function' &&
           data.timestamp.toMillis() > newestDoc.data().timestamp.toMillis())
        ) {
          newestDoc = doc;
        }
      } catch (e) {
        console.warn('⚠️ Failed to compare timestamps for doc:', doc.id, e);
      }
    });
    // Read Firestore data from the newest document
    const data = newestDoc.data();
    // Extract subscriptionId and paypalID, defaulting to null if not present
    const subscriptionId = data && data.subscriptionId ? data.subscriptionId : null;
    const paypalID = data && data.paypalID ? data.paypalID : null;
    // Construct fullBlobUrl (matching purchase.js) and generate a fresh signed URL
    const fullBlobUrl =
      'https://qinhuscfvbuurprs.public.blob.vercel-storage.com/cardlocker/' +
      'CardLocker-qNcAFlKgf0ku0HXcgI0DXm3utFmtoZ.dmg';
    // We need @vercel/blob here too:
    const { getDownloadUrl } = await import('@vercel/blob');
    const signedUrl = await getDownloadUrl(fullBlobUrl, {
      token: process.env.BLOB_READ_WRITE_TOKEN,
      expiresIn: 60 * 5,
    });
    return res.status(200).json({
      found: true,
      licenseKey: newestDoc.id,
      signedUrl: signedUrl,
      subscriptionId: subscriptionId,
      paypalID: paypalID,
    });
  } catch (err) {
    console.error('check-license.js error:', err.stack || err);
    return res.status(500).json({ error: 'Internal server error', details: err.message });
  }
}