import type { NextRequest } from 'next/server';
import { z } from 'zod';
import { apiError, jsonResponse, readJsonBody, requireOwner } from '@/lib/api/http';
import { invokeTool } from '@/lib/tools/invoke';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

const bodySchema = z.object({
  tool: z.string().min(3).max(64),
  arguments: z.record(z.unknown()).default({}),
});

/**
 * POST /api/sessions/[sessionId]/tools
 *
 * Lets the dashboard's own explorer and script viewer run Clovyre tools. It shares
 * the exact invocation path used by MCP clients, so gating, limits and auditing
 * are identical — the only difference is that this route authenticates the browser
 * owner instead of a bearer token.
 */
export async function POST(
  request: NextRequest,
  context: { params: Promise<{ sessionId: string }> },
): Promise<Response> {
  const { sessionId } = await context.params;
  const auth = requireOwner(request, sessionId, { mutating: true });
  if (!auth.ok) return auth.response;

  const raw = await readJsonBody(request, 128 * 1024);
  if (!raw.ok) return raw.response;

  const parsed = bodySchema.safeParse(raw.body);
  if (!parsed.success) {
    return apiError('INVALID_ARGUMENTS', 'Send { tool: string, arguments: object }.', 400);
  }

  const result = await invokeTool(auth.session, parsed.data.tool, parsed.data.arguments, 'owner');
  return jsonResponse({ result }, { status: result.ok ? 200 : 200 });
}
