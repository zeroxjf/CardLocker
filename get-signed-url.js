// File: api/get-signed-url.js

import { getDownloadUrl } from '@vercel/blob';

export default async function handler(req, res) {
  const { file } = req.query;
  if (!file) {
    res.status(400).json({ error: 'Missing file parameter' });
    return;
  }

  try {
    // Construct the full public URL based on your Blob hostname + path
    const fullBlobUrl =
      'https://qinhuscfvbuurprs.public.blob.vercel-storage.com/cardlocker/' + file;

    // Generate a signed URL valid for 5 minutes (300 seconds)
    const signedUrl = await getDownloadUrl(fullBlobUrl, {
      token: process.env.BLOB_READ_WRITE_TOKEN,
      expiresIn: 300,
    });

    res.status(200).json({ signedUrl });
  } catch (err) {
    console.error('Could not generate signed URL:', err);
    res.status(500).json({ error: 'Internal error generating signed URL' });
  }
}