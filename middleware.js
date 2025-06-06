export function middleware(req, ev) {
  const ip = req.headers.get('x-forwarded-for') || 'unknown';
  const now = Date.now();

  if (!global.ipRequestCounts) {
    global.ipRequestCounts = new Map();
  }

  const ipRequestCounts = global.ipRequestCounts;

  if (!ipRequestCounts.has(ip)) {
    ipRequestCounts.set(ip, { count: 1, lastRequest: now });
  } else {
    const entry = ipRequestCounts.get(ip);
    const timeSinceLast = now - entry.lastRequest;

    if (timeSinceLast > 60000) {
      ipRequestCounts.set(ip, { count: 1, lastRequest: now });
    } else {
      if (entry.count >= 5) {
        return new Response('Too many requests', { status: 429 });
      }
      entry.count++;
      entry.lastRequest = now;
    }
  }

  return new Response(null, { status: 204 });
}

export const config = {
  matcher: '/api/check-license',
};