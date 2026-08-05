import type { NextRequest } from 'next/server';
import { z } from 'zod';
import { apiError, jsonResponse, readJsonBody, requireOwner } from '@/lib/api/http';
import { resolvePublicBaseUrl } from '@/lib/config';
import { getSessionBroker } from '@/lib/sessions/broker';
import { getSessionStore } from '@/lib/sessions/store';
import { buildLoadstring, buildMcpConfigSnippets } from '@/lib/sessions/snippets';
import { buildSessionView } from '@/lib/sessions/view';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

const bodySchema = z.object({
  role: z.enum(['roblox', 'mcp']),
  /**
   * Guard against regenerating a credential out from under a working setup.
   * The dashboard sets this automatically when nothing is currently connected,
   * and requires an explicit confirmation from the owner when something is.
   */
  force: z.boolean().default(false),
});

/**
 * POST /api/sessions/[sessionId]/credentials/rotate
 *
 * Issues a fresh Roblox or MCP credential and returns the plaintext exactly
 * once, along with regenerated copy-ready snippets. Owner-only and
 * CSRF-protected: an MCP client has no path to this route.
 *
 * Clovyre stores only credential digests, so a token that has scrolled out of a
 * browser tab is unrecoverable by design. Regenerating is the honest recovery
 * path, and it is why the dashboard can always show a working script.
 */
export async function POST(
  request: NextRequest,
  context: { params: Promise<{ sessionId: string }> },
): Promise<Response> {
  const { sessionId } = await context.params;
  const auth = requireOwner(request, sessionId, { mutating: true });
  if (!auth.ok) return auth.response;

  const raw = await readJsonBody(request);
  if (!raw.ok) return raw.response;

  const parsed = bodySchema.safeParse(raw.body);
  if (!parsed.success) {
    return apiError('INVALID_ARGUMENTS', 'role must be either "roblox" or "mcp".', 400);
  }

  const { role, force } = parsed.data;
  const session = auth.session;

  const inUse =
    role === 'roblox' ? getSessionBroker().isConnected(sessionId) : session.mcpConnections.size > 0;

  if (inUse && !force) {
    return apiError(
      'CREDENTIAL_IN_USE',
      role === 'roblox'
        ? 'A Roblox client is already connected with the current credential. Regenerating means the ' +
            'old loadstring stops working for future connections. Confirm to continue.'
        : 'An MCP client is already using the current credential. Regenerating means it must be ' +
            'reconnected with the new token. Confirm to continue.',
      409,
      { requiresConfirmation: true },
    );
  }

  const token = getSessionStore().rotateCredential(session, role, 'owner');
  const baseUrl = resolvePublicBaseUrl(request.headers);

  return jsonResponse({
    role,
    // Shown once. Reload the dashboard and this is gone for good.
    secret: token,
    ...(role === 'roblox'
      ? { loadstring: buildLoadstring(baseUrl, sessionId, token) }
      : { mcpConfig: buildMcpConfigSnippets(baseUrl, sessionId, token) }),
    session: buildSessionView(session),
  });
}
