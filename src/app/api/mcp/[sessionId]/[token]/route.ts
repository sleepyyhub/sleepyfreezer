import type { NextRequest } from 'next/server';
import { handleMcpHttpRequest, mcpDeleteResponse, mcpGetResponse } from '@/lib/mcp/http';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

/**
 * Remote MCP endpoint, URL-authenticated.
 *
 * POST /api/mcp/[sessionId]/[token]
 *
 * Functionally identical to the header form. It exists for connector UIs that
 * accept only a URL and offer no way to set an Authorization header — claude.ai's
 * custom connector is the motivating case. See src/lib/mcp/http.ts for the
 * trade-off this makes and why it is acceptable for a short-lived, revocable,
 * session-scoped credential.
 */
export async function POST(
  request: NextRequest,
  context: { params: Promise<{ sessionId: string; token: string }> },
): Promise<Response> {
  const { sessionId, token } = await context.params;
  return handleMcpHttpRequest(request, sessionId, decodeURIComponent(token));
}

export function GET(): Response {
  return mcpGetResponse();
}

export function DELETE(): Response {
  return mcpDeleteResponse();
}
