import type { NextRequest } from 'next/server';
import { z } from 'zod';
import {
  apiError,
  clearOwnerCookies,
  jsonResponse,
  readJsonBody,
  requireOwner,
} from '@/lib/api/http';
import { PROTOCOL_VERSION } from '@/lib/protocol/messages';
import { getSessionBroker } from '@/lib/sessions/broker';
import { getSessionStore } from '@/lib/sessions/store';
import { buildSessionView } from '@/lib/sessions/view';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

const bodySchema = z.object({ role: z.enum(['roblox', 'mcp', 'owner']) });

interface RouteContext {
  params: Promise<{ sessionId: string }>;
}

/**
 * POST /api/sessions/[sessionId]/credentials
 *
 * Revokes one credential without ending the session, so a leaked Roblox token can
 * be killed while the MCP agent keeps working (or the reverse).
 */
export async function POST(request: NextRequest, context: RouteContext): Promise<Response> {
  const { sessionId } = await context.params;
  const auth = requireOwner(request, sessionId, { mutating: true });
  if (!auth.ok) return auth.response;

  const raw = await readJsonBody(request);
  if (!raw.ok) return raw.response;

  const parsed = bodySchema.safeParse(raw.body);
  if (!parsed.success) {
    return apiError('INVALID_ARGUMENTS', 'role must be one of roblox, mcp or owner.', 400);
  }

  const { role } = parsed.data;
  const store = getSessionStore();
  const broker = getSessionBroker();

  const changed = store.revokeCredential(auth.session, role, 'owner');
  if (!changed) {
    return apiError('ALREADY_REVOKED', `The ${role} credential is already revoked.`, 409);
  }

  if (role === 'roblox') {
    // Drop the live socket immediately; a revoked token must not survive as an
    // already-authenticated connection.
    broker.teardown(
      sessionId,
      {
        protocolVersion: PROTOCOL_VERSION,
        type: 'session_revoked',
        reason: 'The Roblox credential for this session was revoked.',
      },
      4003,
      'roblox credential revoked',
    );
    // Every client authenticated with the credential that was just revoked.
    auth.session.robloxClients.clear();
  }

  if (role === 'mcp') {
    auth.session.mcpConnections.clear();
  }

  const view = buildSessionView(auth.session);
  const response = jsonResponse({ revoked: role, session: view });

  if (role === 'owner') {
    // The caller just revoked their own access; clear the cookies so the UI
    // reflects that rather than looping on 401s.
    clearOwnerCookies(response, sessionId);
  }
  return response;
}
