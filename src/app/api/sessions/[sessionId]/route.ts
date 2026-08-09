import type { NextRequest } from 'next/server';
import { PROTOCOL_VERSION } from '@/lib/protocol/messages';
import {
  apiError,
  clearOwnerCookies,
  jsonResponse,
  readJsonBody,
  requireOwner,
} from '@/lib/api/http';
import { resolvePublicBaseUrl, toWebSocketOrigin } from '@/lib/config';
import { getSessionBroker } from '@/lib/sessions/broker';
import { getSessionStore } from '@/lib/sessions/store';
import { buildSessionView } from '@/lib/sessions/view';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

interface RouteContext {
  params: Promise<{ sessionId: string }>;
}

/**
 * GET /api/sessions/[sessionId]
 *
 * Live dashboard state. Owner-authenticated: the public session id alone is not
 * enough to read a session.
 */
export async function GET(request: NextRequest, context: RouteContext): Promise<Response> {
  const { sessionId } = await context.params;
  const auth = requireOwner(request, sessionId, { mutating: false });
  if (!auth.ok) return auth.response;

  const baseUrl = resolvePublicBaseUrl(request.headers);


  return jsonResponse({
    session: buildSessionView(auth.session),
    endpoints: {
      baseUrl,
      websocket: `${toWebSocketOrigin(baseUrl)}/ws/roblox`,
      mcp: `${baseUrl}/api/mcp/${sessionId}`,
      clientScript: `${baseUrl}/client.lua`,
    },
  });
}

/**
 * DELETE /api/sessions/[sessionId]
 *
 * Terminates the session immediately: the Roblox socket is closed, pending
 * commands fail, and every credential stops working.
 */
export async function DELETE(request: NextRequest, context: RouteContext): Promise<Response> {
  const { sessionId } = await context.params;
  const auth = requireOwner(request, sessionId, { mutating: true });
  if (!auth.ok) return auth.response;

  const body = await readJsonBody(request);
  if (!body.ok) return body.response;

  const reason =
    typeof (body.body as { reason?: unknown }).reason === 'string'
      ? String((body.body as { reason: string }).reason).slice(0, 200)
      : 'Terminated by the session owner.';

  const store = getSessionStore();
  store.terminate(auth.session, reason, 'owner');
  getSessionBroker().teardown(
    sessionId,
    { protocolVersion: PROTOCOL_VERSION, type: 'session_revoked', reason },
    4003,
    'session terminated',
  );

  const response = jsonResponse({ terminated: true, session: buildSessionView(auth.session) });
  clearOwnerCookies(response, sessionId);
  return response;
}

export function POST(): Response {
  return apiError('METHOD_NOT_ALLOWED', 'Use DELETE to terminate a session.', 405);
}
