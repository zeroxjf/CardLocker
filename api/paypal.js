async function verifyWebhookSignature(headers, body) {
  const accessToken = await getPayPalAccessToken(); // you already have this
  const response = await fetch('https://api.paypal.com/v1/notifications/verify-webhook-signature', {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'Authorization': `Bearer ${accessToken}`
    },
    body: JSON.stringify({
      auth_algo: headers['paypal-auth-algo'],
      cert_url: headers['paypal-cert-url'],
      transmission_id: headers['paypal-transmission-id'],
      transmission_sig: headers['paypal-transmission-sig'],
      transmission_time: headers['paypal-transmission-time'],
      webhook_id: process.env.PAYPAL_WEBHOOK_ID, // set this in Vercel
      webhook_event: body
    })
  });

  const result = await response.json();
  return result.verification_status === 'SUCCESS';
}