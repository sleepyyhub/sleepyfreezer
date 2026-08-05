import type { NextRequest } from 'next/server';
import { getConfig, resolvePublicBaseUrl, toWebSocketOrigin } from '@/lib/config';
import {
  apiError,
  clientAddress,
  jsonResponse,
  originIsTrusted,
  setOwnerCookies,
} from '@/lib/api/http';
import { getRateLimiter } from '@/lib/security/rate-limit';
import { getSessionStore } from '@/lib/sessions/store';
import { buildSessionView } from '@/lib/sessions/view';
import { buildLoadstring, buildMcpConfigSnippets } from '@/lib/sessions/snippets';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

/**
 * POST /api/sessions
 *
 * Creates a temporary session with four independent credentials. The Roblox token
 * and the MCP token are returned exactly once, in this response; the owner token
 * and CSRF token are set as cookies and never appear in a response body again.
 */
export async function POST(request: NextRequest): Promise<Response> {
  if (!originIsTrusted(request)) {
    return apiError('FORBIDDEN_ORIGIN', 'This request did not come from the Clovyre app.', 403);
  }

  const address = clientAddress(request);
  const limit = getRateLimiter().check('session_create', address);
  if (!limit.allowed) {
    return apiError(
      'RATE_LIMITED',
      `Too many sessions created from this address. Retry in ${Math.ceil(limit.retryAfterMs / 1000)} s.`,
      429,
      { retryAfterMs: limit.retryAfterMs },
    );
  }

  const config = getConfig();
  const baseUrl = resolvePublicBaseUrl(request.headers);

  let created;
  try {
    created = getSessionStore().create({ creatorAddress: address });
  } catch (error) {
    return apiError(
      'CAPACITY',
      error instanceof Error ? error.message : 'Clovyre could not create a session right now.',
      503,
    );
  }

  const { session, secrets } = created;

  const response = jsonResponse(
    {
      session: buildSessionView(session),
      // Shown once. Reload the dashboard and these are gone for good.
      secrets: {
        robloxToken: secrets.robloxToken,
        mcpToken: secrets.mcpToken,
      },
      endpoints: {
        baseUrl,
        websocket: `${toWebSocketOrigin(baseUrl)}/ws/roblox`,
        mcp: `${baseUrl}/api/mcp/${session.id}`,
        clientScript: `${baseUrl}/client.lua`,
      },
      loadstring: buildLoadstring(baseUrl, session.id, secrets.robloxToken),
      mcpConfig: buildMcpConfigSnippets(baseUrl, session.id, secrets.mcpToken),
      ttlMinutes: Math.round(config.sessionTtlMs / 60_000),
    },
    { status: 201 },
  );

  setOwnerCookies(response, session.id, secrets.ownerToken, secrets.csrfToken, config.sessionTtlMs);
  return response;
}
