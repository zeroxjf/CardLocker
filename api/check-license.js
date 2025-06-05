// File: api/check-license.js

const admin = require('firebase-admin');

// Initialize Admin if needed (similar to purchase.js)
if (!admin.apps.length) {
  try {
    const serviceAccount = JSON.parse(process.env.FIREBASE_SERVICE_ACCOUNT);
    admin.initializeApp({ credential: admin.credential.cert(serviceAccount) });
    console.log('✅ Firebase Admin initialized.');
  } catch (e) {
    console.error('❌ Firebase Admin failed to initialize:', e);
    // There is no res in this scope; just throw
    throw new Error('Failed to initialize Firebase Admin: ' + e.message);
  }
}
const db = admin.firestore();

module.exports = async function handler(req, res) {
  const { paypalId } = req.query;
  if (!paypalId) {
    return res.status(400).json({ error: 'Missing paypalId parameter' });
  }
  try {
    console.log('🔍 Querying licenses with paypalID:', paypalId);
    const snapshot = await db.collection('licenses')
      .where('paypalID', '==', paypalId)
      .get();

    // If not found by paypalID, try subscriptionId
    let allDocs = [...snapshot.docs];
    if (snapshot.empty) {
      const subSnap = await db.collection('licenses')
        .where('subscriptionId', '==', paypalId)
        .get();
      allDocs = [...subSnap.docs];
    }

    if (allDocs.length === 0) {
      return res.status(200).json({ found: false });
    }
    // If multiple licenses exist, pick the newest one by timestamp, with logging and guards for bad data
    let newestDoc = null;
    allDocs.forEach(doc => {
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
    return res.status(200).json({
      found: true,
      licenseKey: newestDoc.id,
      subscriptionId: subscriptionId,
      paypalID: paypalID,
    });
  } catch (err) {
    console.error('check-license.js error:', err.stack || err);
    return res.status(500).json({ error: 'Internal server error', details: err.message });
  }
}