import { NextResponse, type NextRequest } from 'next/server';
import { getConfig, resolvePublicBaseUrl } from '../config';
import { getRateLimiter } from '../security/rate-limit';
import { safeEqual } from '../security/tokens';
import { getSessionStore } from '../sessions/store';
import type { SessionRecord } from '../sessions/types';

/**
 * Shared HTTP concerns for the Clovyre API routes: response shaping, security
 * headers, owner authentication, CSRF and origin validation.
 */

export const OWNER_COOKIE_PREFIX = 'clovyre_owner_';
export const CSRF_COOKIE_PREFIX = 'clovyre_csrf_';
export const CSRF_HEADER = 'x-clovyre-csrf';

export interface ApiErrorBody {
  readonly error: { readonly code: string; readonly message: string };
}

export function jsonResponse(body: unknown, init: ResponseInit = {}): NextResponse {
  const response = NextResponse.json(body, init);
  response.headers.set('cache-control', 'no-store, no-cache, must-revalidate');
  response.headers.set('x-content-type-options', 'nosniff');
  return response;
}

export function apiError(
  code: string,
  message: string,
  status: number,
  extra: Record<string, unknown> = {},
): NextResponse {
  return jsonResponse({ error: { code, message, ...extra } }, { status });
}

/** Best-effort client address for rate limiting. Never stored in the clear. */
export function clientAddress(request: NextRequest): string {
  const forwarded = request.headers.get('x-forwarded-for');
  if (forwarded) return forwarded.split(',')[0]!.trim();
  return request.headers.get('x-real-ip') ?? 'unknown';
}

export function ownerCookieName(sessionId: string): string {
  return `${OWNER_COOKIE_PREFIX}${sessionId}`;
}

export function csrfCookieName(sessionId: string): string {
  return `${CSRF_COOKIE_PREFIX}${sessionId}`;
}

/**
 * Verifies that the request comes from the Clovyre origin. Requests without an
 * Origin header (server-to-server, curl) are allowed only for non-mutating calls;
 * mutations always require a matching Origin or Sec-Fetch-Site: same-origin.
 */
export function originIsTrusted(request: NextRequest): boolean {
  const origin = request.headers.get('origin');
  if (!origin) {
    return request.headers.get('sec-fetch-site') === 'same-origin';
  }
  const expected = resolvePublicBaseUrl(request.headers);
  try {
    return new URL(origin).host === new URL(expected).host;
  } catch {
    return false;
  }
}

export type OwnerAuthResult =
  | { ok: true; session: SessionRecord }
  | { ok: false; response: NextResponse };

/**
 * Authenticates the browser session owner.
 *
 * `mutating` requests additionally require a same-origin request and a CSRF token
 * that matches both the double-submit cookie and the value bound to the session.
 */
export function requireOwner(
  request: NextRequest,
  sessionId: string,
  options: { mutating: boolean },
): OwnerAuthResult {
  const store = getSessionStore();

  if (options.mutating && !originIsTrusted(request)) {
    return {
      ok: false,
      response: apiError(
        'FORBIDDEN_ORIGIN',
        'This request did not come from the Clovyre app.',
        403,
      ),
    };
  }

  const ownerToken = request.cookies.get(ownerCookieName(sessionId))?.value ?? null;
  const auth = store.authenticate(sessionId, 'owner', ownerToken);
  if (!auth.ok) {
    const status = auth.reason === 'session_not_found' ? 404 : 401;
    return {
      ok: false,
      response: apiError(
        auth.reason.toUpperCase(),
        auth.reason === 'session_not_found'
          ? 'This Clovyre session does not exist.'
          : auth.reason === 'session_expired'
            ? 'This Clovyre session has expired.'
            : auth.reason === 'session_terminated'
              ? 'This Clovyre session was terminated.'
              : 'You are not the owner of this Clovyre session.',
        status,
      ),
    };
  }

  if (options.mutating) {
    const headerToken = request.headers.get(CSRF_HEADER);
    const cookieToken = request.cookies.get(csrfCookieName(sessionId))?.value ?? null;
    if (!safeEqual(headerToken, cookieToken) || !safeEqual(headerToken, auth.session.csrfToken)) {
      return {
        ok: false,
        response: apiError('CSRF_FAILED', 'The CSRF token was missing or did not match.', 403),
      };
    }

    const limit = getRateLimiter().check('owner_action', sessionId);
    if (!limit.allowed) {
      return {
        ok: false,
        response: apiError(
          'RATE_LIMITED',
          `Too many dashboard actions. Retry in ${Math.ceil(limit.retryAfterMs / 1000)} s.`,
          429,
          { retryAfterMs: limit.retryAfterMs },
        ),
      };
    }
  }

  return { ok: true, session: auth.session };
}

/** Applies the owner and CSRF cookies for a freshly created session. */
export function setOwnerCookies(
  response: NextResponse,
  sessionId: string,
  ownerToken: string,
  csrfToken: string,
  ttlMs: number,
): void {
  const config = getConfig();
  const maxAge = Math.floor(ttlMs / 1000);
  response.cookies.set({
    name: ownerCookieName(sessionId),
    value: ownerToken,
    httpOnly: true,
    secure: config.isProduction,
    sameSite: 'lax',
    path: '/',
    maxAge,
  });
  response.cookies.set({
    name: csrfCookieName(sessionId),
    // Readable by the dashboard so it can echo the value back in a header.
    value: csrfToken,
    httpOnly: false,
    secure: config.isProduction,
    sameSite: 'lax',
    path: '/',
    maxAge,
  });
}

export function clearOwnerCookies(response: NextResponse, sessionId: string): void {
  response.cookies.delete(ownerCookieName(sessionId));
  response.cookies.delete(csrfCookieName(sessionId));
}

/** Reads and size-limits a JSON request body. */
export async function readJsonBody(
  request: NextRequest,
  maxBytes = 64 * 1024,
): Promise<{ ok: true; body: unknown } | { ok: false; response: NextResponse }> {
  const declared = request.headers.get('content-length');
  if (declared && Number(declared) > maxBytes) {
    return {
      ok: false,
      response: apiError('PAYLOAD_TOO_LARGE', 'The request body is too large.', 413),
    };
  }
  let text: string;
  try {
    text = await request.text();
  } catch {
    return {
      ok: false,
      response: apiError('BAD_REQUEST', 'The request body could not be read.', 400),
    };
  }
  if (text.length > maxBytes) {
    return {
      ok: false,
      response: apiError('PAYLOAD_TOO_LARGE', 'The request body is too large.', 413),
    };
  }
  if (text.trim() === '') return { ok: true, body: {} };
  try {
    return { ok: true, body: JSON.parse(text) };
  } catch {
    return {
      ok: false,
      response: apiError('INVALID_JSON', 'The request body is not valid JSON.', 400),
    };
  }
}
