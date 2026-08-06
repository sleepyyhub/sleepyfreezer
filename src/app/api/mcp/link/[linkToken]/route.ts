import type { NextRequest } from 'next/server';
import { handleMcpLinkRequest, mcpDeleteResponse, mcpGetResponse } from '@/lib/mcp/http';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

/**
 * Stable MCP endpoint.
 *
 * POST /api/mcp/link/[linkToken]
 *
 * Configure this once in your agent and never touch it again: it resolves to
 * whichever Clovyre session is currently bound to the link, so regenerating a
 * Roblox script never invalidates the agent's configuration.
 */
export async function POST(
  request: NextRequest,
  context: { params: Promise<{ linkToken: string }> },
): Promise<Response> {
  const { linkToken } = await context.params;
  return handleMcpLinkRequest(request, decodeURIComponent(linkToken));
}

export function GET(): Response {
  return mcpGetResponse();
}

export function DELETE(): Response {
  return mcpDeleteResponse();
}
