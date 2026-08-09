import type { NextRequest } from 'next/server';
import { handleMcpConnectRequest, mcpDeleteResponse, mcpGetResponse } from '@/lib/mcp/http';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

/**
 * POST /mcp/connect
 *
 * One fixed URL for every Clovyre user. The agent identifies itself with its
 * permanent link token in the Authorization header, and the server routes to the
 * session bound to that link.
 */
export async function POST(request: NextRequest): Promise<Response> {
  return handleMcpConnectRequest(request);
}

export function GET(): Response {
  return mcpGetResponse();
}

export function DELETE(): Response {
  return mcpDeleteResponse();
}
