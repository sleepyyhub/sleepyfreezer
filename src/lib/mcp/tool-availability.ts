import { getSessionBroker } from '../sessions/broker';
import { getSessionStore } from '../sessions/store';
import type { SessionRecord } from '../sessions/types';
import { TOOL_DEFINITIONS, type ToolDefinition } from '../tools/registry';
import { getConfig } from '../config';

/**
 * Decides which tools a session may currently see and call.
 *
 * Availability has three independent gates: the feature must be enabled on the
 * deployment, the executor must report the required capability, and the session
 * owner must have granted any required privilege.
 */

export type UnavailableReason =
  | 'feature_disabled'
  | 'capability_missing'
  | 'privilege_required'
  | 'client_disconnected';

export interface ToolAvailability {
  readonly definition: ToolDefinition;
  readonly available: boolean;
  readonly reason: UnavailableReason | null;
  readonly detail: string | null;
}

export function evaluateTool(session: SessionRecord, definition: ToolDefinition): ToolAvailability {
  const config = getConfig();
  const store = getSessionStore();

  const deny = (reason: UnavailableReason, detail: string): ToolAvailability => ({
    definition,
    available: false,
    reason,
    detail,
  });

  if (definition.name === 'clovyre_execute_luau' && !config.executeLuauFeatureEnabled) {
    return deny('feature_disabled', 'Luau execution is disabled on this Clovyre deployment.');
  }
  if (definition.requiresPrivilege === 'mutations' && !config.mutationToolsFeatureEnabled) {
    return deny('feature_disabled', 'Mutation tools are disabled on this Clovyre deployment.');
  }
  if (definition.requiresPrivilege === 'remote_spy' && !config.remoteSpyFeatureEnabled) {
    return deny('feature_disabled', 'The remote spy is disabled on this Clovyre deployment.');
  }

  if (definition.requiresPrivilege && !store.hasPrivilege(session, definition.requiresPrivilege)) {
    return deny(
      'privilege_required',
      `The session owner must enable "${definition.requiresPrivilege}" in the Clovyre dashboard before this tool can run.`,
    );
  }

  if (definition.requiresCapability) {
    const reported = session.capabilities[definition.requiresCapability];
    if (!reported) {
      return deny(
        'capability_missing',
        `The connected executor does not report the "${definition.requiresCapability}" capability.`,
      );
    }
  }

  if (!definition.local && !getSessionBroker().isConnected(session.id)) {
    return deny('client_disconnected', 'No Roblox client is connected to this Clovyre session.');
  }

  return { definition, available: true, reason: null, detail: null };
}

/** Availability for every registered tool, in registry order. */
export function evaluateAllTools(session: SessionRecord): ToolAvailability[] {
  return TOOL_DEFINITIONS.map((definition) => evaluateTool(session, definition));
}

/**
 * Tools exposed through `tools/list`.
 *
 * Tools blocked purely because the Roblox client is momentarily disconnected stay
 * listed — the agent should see the surface and get a clear runtime error — but a
 * tool the owner has not privileged is hidden entirely, so an agent cannot even
 * attempt to invoke it.
 */
export function listableTools(session: SessionRecord): ToolAvailability[] {
  return evaluateAllTools(session).filter(
    (entry) => entry.reason !== 'privilege_required' && entry.reason !== 'feature_disabled',
  );
}
