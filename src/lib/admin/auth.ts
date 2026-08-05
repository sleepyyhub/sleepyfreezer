import { createHmac, timingSafeEqual } from 'node:crypto';
import type { NextRequest } from 'next/server';
import { getConfig } from '../config';
import { getRateLimiter } from '../security/rate-limit';

/**
 * Operator console authentication.
 *
 * Three properties matter here, in this order:
 *
 * 1. **Absent by default.** With no ADMIN_TOKEN configured the console does not
 *    exist: every route answers 404. Nothing about the deployment hints that an
 *    operator console was ever built.
 * 2. **Indistinguishable failure.** A wrong credential produces the same 404 as
 *    an unimplemented path, so probing cannot confirm the console exists, let
 *    alone that a guess was close.
 * 3. **Stateless, expiring sessions.** Sign-in mints an HMAC-signed cookie tied
 *    to an expiry. Nothing is stored server-side, so a restart simply ends every
 *    operator session.
 *
 * Obscurity is a convenience, not the control. The control is a 24+ character
 * secret compared in constant time and rate-limited per address.
 */

export const ADMIN_COOKIE = 'clovyre_operator';

/** Signed value: "<expiresAt>.<hmac>". */
function sign(expiresAt: number): string {
  const config = getConfig();
  const mac = createHmac('sha256', config.sessionSecret)
    .update(`operator:${expiresAt}:${config.adminToken ?? ''}`)
    .digest('hex');
  return `${expiresAt}.${mac}`;
}

export function issueAdminCookieValue(): { value: string; maxAgeSeconds: number } {
  const config = getConfig();
  const expiresAt = Date.now() + config.adminSessionMs;
  return { value: sign(expiresAt), maxAgeSeconds: Math.floor(config.adminSessionMs / 1000) };
}

function constantTimeEquals(a: string, b: string): boolean {
  const left = Buffer.from(a, 'utf8');
  const right = Buffer.from(b, 'utf8');
  if (left.length !== right.length) return false;
  return timingSafeEqual(left, right);
}

/** True when the presented value is a live, untampered operator cookie. */
export function verifyAdminCookie(value: string | null | undefined): boolean {
  if (!getConfig().adminEnabled) return false;
  if (typeof value !== 'string') return false;

  const separator = value.lastIndexOf('.');
  if (separator <= 0) return false;

  const expiresAt = Number(value.slice(0, separator));
  if (!Number.isFinite(expiresAt) || expiresAt <= Date.now()) return false;

  return constantTimeEquals(value, sign(expiresAt));
}

/** True when the presented secret matches the configured operator credential. */
export function verifyAdminToken(presented: string | null | undefined): boolean {
  const config = getConfig();
  if (!config.adminEnabled || !config.adminToken) return false;
  if (typeof presented !== 'string' || presented.length === 0) return false;
  return constantTimeEquals(presented, config.adminToken);
}

export type AdminAuth =
  /** `issueCookie` is set when the caller authenticated with the secret itself. */
  | { ok: true; issueCookie?: boolean }
  | { ok: false; reason: 'disabled' | 'unauthenticated' | 'rate_limited' };

/**
 * Authenticates an operator request from either an existing cookie or a `k`
 * query parameter carrying the secret.
 *
 * Callers must render the same 404 for every failure reason. The distinction is
 * returned only so the server can decide whether to set a cookie, and to record
 * rate limiting.
 */
export function authenticateAdmin(request: NextRequest, address: string): AdminAuth {
  if (!getConfig().adminEnabled) return { ok: false, reason: 'disabled' };

  if (verifyAdminCookie(request.cookies.get(ADMIN_COOKIE)?.value)) {
    return { ok: true };
  }

  const presented =
    request.nextUrl.searchParams.get('k') ?? request.headers.get('x-clovyre-operator');
  if (!presented) return { ok: false, reason: 'unauthenticated' };

  // Only guesses are rate limited, so a valid cookie never consumes budget.
  const limit = getRateLimiter().check('admin_login', address);
  if (!limit.allowed) return { ok: false, reason: 'rate_limited' };

  if (verifyAdminToken(presented)) return { ok: true, issueCookie: true };
  return { ok: false, reason: 'unauthenticated' };
}
