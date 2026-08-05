import type { NextRequest } from 'next/server';
import { z } from 'zod';
import { apiError, jsonResponse, readJsonBody, requireOwner } from '@/lib/api/http';
import { getConfig } from '@/lib/config';
import { getSessionStore } from '@/lib/sessions/store';
import { buildSessionView } from '@/lib/sessions/view';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

const bodySchema = z.object({
  privilege: z.enum(['execute_luau', 'executor_globals', 'mutations', 'remote_spy']),
  enabled: z.boolean(),
  /**
   * Free-text acknowledgement the dashboard sends when switching a privilege on.
   * It exists so the audit trail records that a human saw the warning — an MCP
   * client cannot reach this route at all, since it has no owner cookie.
   */
  acknowledgement: z.string().max(200).optional(),
});

interface RouteContext {
  params: Promise<{ sessionId: string }>;
}

/**
 * POST /api/sessions/[sessionId]/privileges
 *
 * Grants or revokes a privileged capability. Owner-only, CSRF-protected, and
 * every grant expires automatically after PRIVILEGE_TTL_MINUTES.
 */
export async function POST(request: NextRequest, context: RouteContext): Promise<Response> {
  const { sessionId } = await context.params;
  const auth = requireOwner(request, sessionId, { mutating: true });
  if (!auth.ok) return auth.response;

  const raw = await readJsonBody(request);
  if (!raw.ok) return raw.response;

  const parsed = bodySchema.safeParse(raw.body);
  if (!parsed.success) {
    return apiError('INVALID_ARGUMENTS', 'privilege and enabled are required.', 400);
  }

  const config = getConfig();
  const { privilege, enabled } = parsed.data;

  if (enabled && privilege === 'execute_luau' && !config.executeLuauFeatureEnabled) {
    return apiError('FEATURE_DISABLED', 'Luau execution is disabled on this deployment.', 409);
  }
  if (enabled && privilege === 'mutations' && !config.mutationToolsFeatureEnabled) {
    return apiError('FEATURE_DISABLED', 'Mutation tools are disabled on this deployment.', 409);
  }
  if (enabled && privilege === 'remote_spy' && !config.remoteSpyFeatureEnabled) {
    return apiError('FEATURE_DISABLED', 'The remote spy is disabled on this deployment.', 409);
  }
  if (enabled && privilege === 'executor_globals' && !config.executeLuauFeatureEnabled) {
    return apiError(
      'FEATURE_DISABLED',
      'Executor globals only apply to Luau execution, which is disabled on this deployment.',
      409,
    );
  }

  const store = getSessionStore();
  store.setPrivilege(auth.session, privilege, enabled, 'owner');

  if (parsed.data.acknowledgement && enabled) {
    auth.session.audit.record({
      kind: 'privilege_enabled',
      actor: 'owner',
      severity: 'warn',
      message: `Owner acknowledgement recorded for "${privilege}".`,
      detail: { acknowledgement: parsed.data.acknowledgement },
    });
  }

  // Turning Luau execution off also drops the executor-globals grant, which is
  // meaningless on its own.
  if (!enabled && privilege === 'execute_luau') {
    store.setPrivilege(auth.session, 'executor_globals', false, 'system');
  }

  return jsonResponse({
    privilege,
    enabled,
    ttlMinutes: Math.round(config.privilegeTtlMs / 60_000),
    session: buildSessionView(auth.session),
  });
}
