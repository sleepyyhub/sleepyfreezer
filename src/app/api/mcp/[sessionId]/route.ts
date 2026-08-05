import type { NextRequest } from 'next/server';
import { handleMcpHttpRequest, mcpDeleteResponse, mcpGetResponse } from '@/lib/mcp/http';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

/**
 * Remote MCP endpoint, header-authenticated.
 *
 * POST /api/mcp/[sessionId] with `Authorization: Bearer <session MCP token>`.
 */
export async function POST(
  request: NextRequest,
  context: { params: Promise<{ sessionId: string }> },
): Promise<Response> {
  const { sessionId } = await context.params;
  return handleMcpHttpRequest(request, sessionId, null);
}

export function GET(): Response {
  return mcpGetResponse();
}

export function DELETE(): Response {
  return mcpDeleteResponse();
}
