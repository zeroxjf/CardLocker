import { NextResponse } from 'next/server';

const RATE_LIMIT_WINDOW = 60 * 1000; // 60 seconds
const MAX_REQUESTS_PER_WINDOW = 5;

const ipRequestCounts = new Map();

export function middleware(request) {
  const ip = request.headers.get('x-forwarded-for') || 'unknown';
  const now = Date.now();

  if (!ipRequestCounts.has(ip)) {
    ipRequestCounts.set(ip, { count: 1, lastRequest: now });
  } else {
    const entry = ipRequestCounts.get(ip);
    const timeSinceLast = now - entry.lastRequest;

    if (timeSinceLast > RATE_LIMIT_WINDOW) {
      ipRequestCounts.set(ip, { count: 1, lastRequest: now });
    } else {
      if (entry.count >= MAX_REQUESTS_PER_WINDOW) {
        return new NextResponse('Too many requests', { status: 429 });
      }
      entry.count++;
      entry.lastRequest = now;
    }
  }

  return NextResponse.next();
}

export const config = {
  matcher: '/api/check-license',
};