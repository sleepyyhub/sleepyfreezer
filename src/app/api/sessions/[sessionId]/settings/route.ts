import type { NextRequest } from 'next/server';
import { z } from 'zod';
import { apiError, jsonResponse, readJsonBody, requireOwner } from '@/lib/api/http';
import { PROTOCOL_VERSION } from '@/lib/protocol/messages';
import { getSessionBroker } from '@/lib/sessions/broker';
import { getSessionStore } from '@/lib/sessions/store';
import { buildSessionView } from '@/lib/sessions/view';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

const bodySchema = z.object({
  clientLogging: z.boolean(),
});

interface RouteContext {
  params: Promise<{ sessionId: string }>;
}

/**
 * POST /api/sessions/[sessionId]/settings
 *
 * Owner-only session settings. Currently just whether the bridge is allowed to
 * print to the executor console.
 *
 * The change is pushed to every connected client immediately rather than waiting
 * for a reconnect: the setting exists so someone can stop output that is in their
 * way right now, and a setting that takes effect later would not do that.
 */
export async function POST(request: NextRequest, context: RouteContext): Promise<Response> {
  const { sessionId } = await context.params;
  const auth = requireOwner(request, sessionId, { mutating: true });
  if (!auth.ok) return auth.response;

  const raw = await readJsonBody(request);
  if (!raw.ok) return raw.response;

  const parsed = bodySchema.safeParse(raw.body);
  if (!parsed.success) {
    return apiError('INVALID_ARGUMENTS', 'clientLogging must be a boolean.', 400);
  }

  const store = getSessionStore();
  store.setClientLogging(auth.session, parsed.data.clientLogging, 'owner');

  getSessionBroker().notify(sessionId, {
    protocolVersion: PROTOCOL_VERSION,
    type: 'settings_update',
    logging: parsed.data.clientLogging,
  });

  return jsonResponse({
    settings: { clientLogging: auth.session.settings.clientLogging },
    session: buildSessionView(auth.session),
  });
}
