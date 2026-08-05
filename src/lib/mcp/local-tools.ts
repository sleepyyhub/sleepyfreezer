import { PROTOCOL_VERSION, CAPABILITY_NAMES, type CapabilityName } from '../protocol/messages';
import { getSessionBroker } from '../sessions/broker';
import { getSessionStore } from '../sessions/store';
import { sessionStatus, type SessionRecord } from '../sessions/types';
import { TOOL_DEFINITIONS } from '../tools/registry';

/**
 * Tools the Clovyre backend answers itself, without touching the Roblox client.
 * These stay available even when no client is connected, which is what makes them
 * useful for diagnosing a bridge that has not come up yet.
 */

export function sessionInfo(session: SessionRecord): Record<string, unknown> {
  const broker = getSessionBroker();
  const now = Date.now();
  const connected = broker.isConnected(session.id);

  return {
    sessionId: session.id,
    status: sessionStatus(session, now),
    protocolVersion: PROTOCOL_VERSION,
    roblox: {
      connected,
      connectedAt: session.roblox ? new Date(session.roblox.connectedAt).toISOString() : null,
      lastHeartbeatAt: session.roblox
        ? new Date(session.roblox.lastHeartbeatAt).toISOString()
        : null,
      uptimeSeconds: session.roblox ? Math.floor((now - session.roblox.connectedAt) / 1000) : null,
      bridgeVersion: session.roblox?.bridgeVersion ?? null,
    },
    place: {
      placeId: session.metadata?.placeId ?? null,
      universeId: session.metadata?.universeId ?? null,
      jobId: session.metadata?.jobId ?? null,
      gameName: session.metadata?.gameName ?? null,
    },
    localPlayer: session.metadata?.localPlayer ?? null,
    executor: session.metadata?.executor ?? null,
    capabilities: session.capabilities,
    privileges: {
      execute_luau: getSessionStore().hasPrivilege(session, 'execute_luau', now),
      executor_globals: getSessionStore().hasPrivilege(session, 'executor_globals', now),
      mutations: getSessionStore().hasPrivilege(session, 'mutations', now),
    },
    session: {
      createdAt: new Date(session.createdAt).toISOString(),
      expiresAt: new Date(session.expiresAt).toISOString(),
      expiresInSeconds: Math.max(0, Math.floor((session.expiresAt - now) / 1000)),
      ageSeconds: Math.floor((now - session.createdAt) / 1000),
      mcpConnections: session.mcpConnections.size,
    },
    scope:
      'Only state replicated to this live Roblox client is reachable. Server scripts, ServerStorage, ' +
      'ServerScriptService and server memory are not accessible.',
  };
}

export function listCapabilities(session: SessionRecord): Record<string, unknown> {
  const reported = session.capabilities;
  const toolsByCapability = new Map<string, string[]>();
  for (const definition of TOOL_DEFINITIONS) {
    if (!definition.requiresCapability) continue;
    const list = toolsByCapability.get(definition.requiresCapability) ?? [];
    list.push(definition.name);
    toolsByCapability.set(definition.requiresCapability, list);
  }

  const capabilities = CAPABILITY_NAMES.map((name: CapabilityName) => ({
    name,
    available: reported[name] === true,
    unlocksTools: toolsByCapability.get(name) ?? [],
  }));

  return {
    clientConnected: getSessionBroker().isConnected(session.id),
    executor: session.metadata?.executor ?? null,
    capabilities,
    note:
      'Capabilities are probed by the Clovyre bridge at startup and reflect what this specific executor ' +
      'exposes. A missing capability disables its tools; it does not indicate a fault.',
  };
}

export function recentActivity(session: SessionRecord, limit: number): Record<string, unknown> {
  const commands = session.commandOrder
    .slice(-limit)
    .reverse()
    .map((id) => session.commands.get(id))
    .filter((record): record is NonNullable<typeof record> => Boolean(record))
    .map((record) => ({
      commandId: record.id,
      tool: record.tool,
      origin: record.origin,
      status: record.status,
      startedAt: new Date(record.startedAt).toISOString(),
      durationMs: record.durationMs,
      arguments: record.argumentsPreview,
      result: record.resultPreview,
      errorCode: record.errorCode,
      errorMessage: record.errorMessage,
    }));

  return {
    commands,
    events: session.audit.list({ limit }).map((event) => ({
      id: event.id,
      at: new Date(event.at).toISOString(),
      kind: event.kind,
      severity: event.severity,
      actor: event.actor,
      message: event.message,
    })),
  };
}

export function recentErrors(session: SessionRecord, limit: number): Record<string, unknown> {
  const failed = session.commandOrder
    .slice(-200)
    .reverse()
    .map((id) => session.commands.get(id))
    .filter(
      (record): record is NonNullable<typeof record> =>
        Boolean(record) && record!.status !== 'succeeded' && record!.status !== 'pending',
    )
    .slice(0, limit)
    .map((record) => ({
      commandId: record.id,
      tool: record.tool,
      status: record.status,
      errorCode: record.errorCode,
      errorMessage: record.errorMessage,
      durationMs: record.durationMs,
      at: new Date(record.startedAt).toISOString(),
    }));

  return {
    failedCommands: failed,
    errorEvents: session.audit.list({ limit, severity: 'error' }).map((event) => ({
      id: event.id,
      at: new Date(event.at).toISOString(),
      kind: event.kind,
      message: event.message,
    })),
  };
}

export function cancelCommand(
  session: SessionRecord,
  commandId: string,
): { cancelled: boolean; message: string } {
  const cancelled = getSessionBroker().cancel(session.id, commandId);
  return {
    cancelled,
    message: cancelled
      ? `Cancellation was sent to the Roblox client for ${commandId}. Work already committed on the client cannot be undone.`
      : `No in-flight command with id ${commandId} exists on this session.`,
  };
}
