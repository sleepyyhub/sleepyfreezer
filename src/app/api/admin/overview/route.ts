import { NextResponse, type NextRequest } from 'next/server';
import { ADMIN_COOKIE, authenticateAdmin, issueAdminCookieValue } from '@/lib/admin/auth';
import { buildAdminOverview } from '@/lib/admin/overview';
import { clientAddress } from '@/lib/api/http';
import { getConfig } from '@/lib/config';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

/**
 * GET /api/admin/overview
 *
 * Operator console data. Every failure — feature disabled, no credential, wrong
 * credential, rate limited — returns an identical 404 so the route is
 * indistinguishable from one that does not exist.
 */
export function GET(request: NextRequest): Response {
  const auth = authenticateAdmin(request, clientAddress(request));

  if (!auth.ok) {
    return new Response('Not Found', {
      status: 404,
      headers: { 'content-type': 'text/plain; charset=utf-8', 'cache-control': 'no-store' },
    });
  }

  const response = NextResponse.json(buildAdminOverview());
  response.headers.set('cache-control', 'no-store, no-cache, must-revalidate');
  // Never let an operator view be indexed or referred outward.
  response.headers.set('x-robots-tag', 'noindex, nofollow, noarchive');
  response.headers.set('referrer-policy', 'no-referrer');

  if (auth.issueCookie) {
    const cookie = issueAdminCookieValue();
    response.cookies.set({
      name: ADMIN_COOKIE,
      value: cookie.value,
      httpOnly: true,
      secure: getConfig().isProduction,
      sameSite: 'strict',
      path: '/',
      maxAge: cookie.maxAgeSeconds,
    });
  }

  return response;
}
