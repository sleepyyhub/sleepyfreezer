import type { NextRequest } from 'next/server';
import { createHash } from 'node:crypto';
import { getConfig } from '../config';
import { handleMcpPayload, JsonRpcErrorCodes, MCP_PROTOCOL_VERSION } from './server';
import { getRateLimiter } from '../security/rate-limit';
import { getSessionStore } from '../sessions/store';
import { linkFingerprint, verifyAgentLink } from '../sessions/link';
import type { SessionRecord } from '../sessions/types';

/**
 * Remote MCP endpoint (Streamable HTTP).
 *
 * Two equivalent forms:
 *
 *   POST /api/mcp/<sessionId>            Authorization: Bearer <MCP token>
 *   POST /api/mcp/<sessionId>/<MCP token>
 *
 * The second exists because several connector UIs — claude.ai's custom
 * connector among them — accept only a URL and provide no way to attach a
 * header. The trade-off is real and is stated in the interface: a token in a URL
 * path is visible to proxy and platform access logs. It is mitigated by the fact
 * that the credential is session-scoped, expires with the session, and can be
 * regenerated or revoked from the dashboard at any time.
 *
 * Either way the session is addressed by the URL and authenticated against that
 * session's own digest, so a token issued for one session can never drive another.
 */

const MAX_BODY_BYTES = 1024 * 1024;

function rpcError(code: number, message: string, status: number): Response {
  return new Response(JSON.stringify({ jsonrpc: '2.0', id: null, error: { code, message } }), {
    status,
    headers: {
      'content-type': 'application/json',
      'cache-control': 'no-store',
      ...(status === 401
        ? { 'www-authenticate': 'Bearer realm="Clovyre MCP", error="invalid_token"' }
        : {}),
    },
  });
}

function bearerToken(request: NextRequest): string | null {
  const header = request.headers.get('authorization');
  if (header) {
    const match = /^Bearer\s+(.+)$/i.exec(header.trim());
    if (match) return match[1]!.trim();
  }
  // Some connector UIs only allow a custom header rather than Authorization.
  return request.headers.get('x-clovyre-token');
}

/** Stable per-client connection id derived from the caller, never from a secret. */
function connectionIdFor(request: NextRequest, sessionId: string): string {
  const material = [
    sessionId,
    request.headers.get('mcp-session-id') ?? '',
    request.headers.get('user-agent') ?? '',
    request.headers.get('x-forwarded-for')?.split(',')[0]?.trim() ?? '',
  ].join('|');
  return createHash('sha256').update(material).digest('hex').slice(0, 16);
}

/**
 * Shared handler for both MCP entry points: the header-authenticated
 * `/api/mcp/<sessionId>` and the URL-authenticated
 * `/api/mcp/<sessionId>/<token>`.
 *
 * `pathToken` is supplied only by the second form.
 */
export async function handleMcpHttpRequest(
  request: NextRequest,
  sessionId: string,
  pathToken: string | null,
): Promise<Response> {
  const store = getSessionStore();

  const limit = getRateLimiter().check('mcp_request', sessionId);
  if (!limit.allowed) {
    return rpcError(
      JsonRpcErrorCodes.INTERNAL_ERROR,
      `Rate limit reached. Retry in ${Math.ceil(limit.retryAfterMs / 1000)} s.`,
      429,
    );
  }

  // A token in the path wins, because a client that used that URL form cannot
  // send a header at all.
  const token = pathToken ?? bearerToken(request);
  const auth = store.authenticate(sessionId, 'mcp', token);
  if (!auth.ok) {
    store.get(sessionId)?.audit.record({
      kind: 'mcp_rejected',
      actor: 'mcp',
      severity: 'warn',
      message: `An MCP request was rejected: ${auth.reason}.`,
    });
    const status = auth.reason === 'session_not_found' ? 404 : 401;
    const message =
      auth.reason === 'session_not_found'
        ? 'Unknown Clovyre session.'
        : auth.reason === 'session_expired'
          ? 'This Clovyre session has expired. Create a new one and reconnect.'
          : auth.reason === 'session_terminated'
            ? 'This Clovyre session was terminated.'
            : auth.reason === 'credential_revoked'
              ? 'The MCP credential for this session was revoked.'
              : 'The bearer token is not valid for this Clovyre session.';
    return rpcError(JsonRpcErrorCodes.INVALID_REQUEST, message, status);
  }

  return serveMcpForSession(request, auth.session);
}

/**
 * Serves an MCP request against a session that has already been authenticated,
 * whether by a per-session token or by a persistent agent link.
 */
export async function serveMcpForSession(
  request: NextRequest,
  session: SessionRecord,
): Promise<Response> {
  const sessionId = session.id;

  const declaredLength = request.headers.get('content-length');
  if (declaredLength && Number(declaredLength) > MAX_BODY_BYTES) {
    return rpcError(JsonRpcErrorCodes.INVALID_REQUEST, 'Request body is too large.', 413);
  }

  const text = await request.text();
  if (text.length > MAX_BODY_BYTES) {
    return rpcError(JsonRpcErrorCodes.INVALID_REQUEST, 'Request body is too large.', 413);
  }

  let body: unknown;
  try {
    body = JSON.parse(text);
  } catch {
    return rpcError(JsonRpcErrorCodes.PARSE_ERROR, 'Request body is not valid JSON.', 400);
  }

  const connectionId = connectionIdFor(request, sessionId);
  const existing = session.mcpConnections.get(connectionId);
  if (existing) {
    existing.lastSeenAt = Date.now();
  } else {
    session.mcpConnections.set(connectionId, {
      connectionId,
      connectedAt: Date.now(),
      lastSeenAt: Date.now(),
      clientName: null,
      clientVersion: null,
      protocolVersion: null,
    });
  }

  const { response, httpStatus } = await handleMcpPayload(session, body, connectionId);

  if (response === null) {
    return new Response(null, { status: httpStatus, headers: { 'cache-control': 'no-store' } });
  }

  return new Response(JSON.stringify(response), {
    status: httpStatus,
    headers: {
      'content-type': 'application/json',
      'cache-control': 'no-store',
      'mcp-session-id': connectionId,
    },
  });
}

/**
 * GET is part of Streamable HTTP for server-initiated SSE streams. Clovyre has no
 * server-initiated messages, so it declines the stream explicitly rather than
 * leaving a socket open that will never carry anything.
 */
export function mcpGetResponse(): Response {
  return new Response(
    JSON.stringify({
      service: 'clovyre-mcp',
      transport: 'streamable-http',
      protocolVersion: MCP_PROTOCOL_VERSION,
      version: getConfig().version,
      message:
        'Send JSON-RPC 2.0 requests with POST and an Authorization: Bearer <session MCP token> header. ' +
        'This server does not open server-initiated SSE streams.',
    }),
    {
      status: 405,
      headers: { 'content-type': 'application/json', allow: 'POST', 'cache-control': 'no-store' },
    },
  );
}

export function mcpDeleteResponse(): Response {
  // Streamable HTTP session teardown. Clovyre sessions end via the dashboard.
  return new Response(null, { status: 204, headers: { 'cache-control': 'no-store' } });
}

/**
 * Serves the stable, link-addressed MCP endpoint.
 *
 * The URL never changes; it resolves at request time to whichever session is
 * currently bound to the link. That is the whole point: the Roblox loadstring is
 * regenerated constantly, but the agent's configuration should be written once.
 *
 * When no session is bound yet the answer is a clear, actionable error rather
 * than a 404, because the URL itself is valid — there is simply nothing live on
 * the other end of it.
 */
export async function handleMcpLinkRequest(
  request: NextRequest,
  linkToken: string,
): Promise<Response> {
  const ownerId = verifyAgentLink(linkToken);
  if (!ownerId) {
    return rpcError(
      JsonRpcErrorCodes.INVALID_REQUEST,
      'This Clovyre agent link is not valid. Copy the current link from your dashboard.',
      401,
    );
  }

  const limit = getRateLimiter().check('mcp_request', `link:${ownerId}`);
  if (!limit.allowed) {
    return rpcError(
      JsonRpcErrorCodes.INTERNAL_ERROR,
      `Rate limit reached. Retry in ${Math.ceil(limit.retryAfterMs / 1000)} s.`,
      429,
    );
  }

  const session = getSessionStore().findActiveByLink(ownerId);
  if (!session) {
    return rpcError(
      JsonRpcErrorCodes.INVALID_REQUEST,
      'This agent link is valid but no Clovyre session is currently bound to it. ' +
        'Open the Clovyre dashboard and create a session; the link then works again ' +
        'with no reconfiguration.',
      409,
    );
  }

  session.audit.record({
    kind: 'mcp_connected',
    actor: 'mcp',
    message: 'An MCP request arrived through the persistent agent link.',
    detail: { link: linkFingerprint(ownerId) },
  });

  return serveMcpForSession(request, session);
}

/**
 * The single fixed endpoint: /mcp/connect, identical for every user.
 *
 * Routing is by credential rather than by URL. The agent presents its permanent
 * link token in a header, and the server resolves that to whichever session is
 * currently bound to it — so one URL serves everybody and each agent still
 * reaches only its own session.
 *
 * There is deliberately no fallback to "the most recently created session" when
 * no credential is presented. On a shared deployment that would hand whichever
 * stranger asked first a live Roblox client belonging to someone else, and no
 * amount of convenience justifies that.
 */
export async function handleMcpConnectRequest(request: NextRequest): Promise<Response> {
  const presented = bearerToken(request);

  if (!presented) {
    return rpcError(
      JsonRpcErrorCodes.INVALID_REQUEST,
      'This endpoint needs your Clovyre agent link as a bearer token: ' +
        'Authorization: Bearer <clk_ token from your dashboard>. ' +
        'If your client cannot send headers, use the per-session connector URL the ' +
        'dashboard also provides.',
      401,
    );
  }

  const ownerId = verifyAgentLink(presented);
  if (!ownerId) {
    return rpcError(
      JsonRpcErrorCodes.INVALID_REQUEST,
      'That agent link is not valid. Copy the current one from your Clovyre dashboard.',
      401,
    );
  }

  const limit = getRateLimiter().check('mcp_request', `link:${ownerId}`);
  if (!limit.allowed) {
    return rpcError(
      JsonRpcErrorCodes.INTERNAL_ERROR,
      `Rate limit reached. Retry in ${Math.ceil(limit.retryAfterMs / 1000)} s.`,
      429,
    );
  }

  const session = getSessionStore().findActiveByLink(ownerId);
  if (!session) {
    return rpcError(
      JsonRpcErrorCodes.INVALID_REQUEST,
      'Your agent link is valid but no Clovyre session is bound to it right now. ' +
        'Open the dashboard and create a session; this endpoint then works again with ' +
        'no reconfiguration.',
      409,
    );
  }

  session.audit.record({
    kind: 'mcp_connected',
    actor: 'mcp',
    message: 'An MCP request arrived through the shared /mcp/connect endpoint.',
    detail: { link: linkFingerprint(ownerId) },
  });

  return serveMcpForSession(request, session);
}
