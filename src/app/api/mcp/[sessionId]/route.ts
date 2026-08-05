import type { NextRequest } from 'next/server';
import { createHash } from 'node:crypto';
import { getConfig } from '@/lib/config';
import { handleMcpPayload, JsonRpcErrorCodes, MCP_PROTOCOL_VERSION } from '@/lib/mcp/server';
import { getRateLimiter } from '@/lib/security/rate-limit';
import { getSessionStore } from '@/lib/sessions/store';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

/**
 * Remote MCP endpoint (Streamable HTTP).
 *
 * POST /api/mcp/[sessionId]
 *   Authorization: Bearer <session MCP token>
 *
 * The session is addressed by the URL and authenticated by the bearer token bound
 * to that session, so a token issued for one session can never drive another.
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

export async function POST(
  request: NextRequest,
  context: { params: Promise<{ sessionId: string }> },
): Promise<Response> {
  const { sessionId } = await context.params;
  const store = getSessionStore();

  const limit = getRateLimiter().check('mcp_request', sessionId);
  if (!limit.allowed) {
    return rpcError(
      JsonRpcErrorCodes.INTERNAL_ERROR,
      `Rate limit reached. Retry in ${Math.ceil(limit.retryAfterMs / 1000)} s.`,
      429,
    );
  }

  const token = bearerToken(request);
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

  const session = auth.session;

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
export function GET(): Response {
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

export function DELETE(): Response {
  // Streamable HTTP session teardown. Clovyre sessions end via the dashboard.
  return new Response(null, { status: 204, headers: { 'cache-control': 'no-store' } });
}
