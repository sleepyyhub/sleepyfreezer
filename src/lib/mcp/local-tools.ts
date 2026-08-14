import { PROTOCOL_VERSION, CAPABILITY_NAMES, type CapabilityName } from '../protocol/messages';
import { getSessionBroker } from '../sessions/broker';
import { getSessionStore } from '../sessions/store';
import { connectedClients, sessionStatus, type SessionRecord } from '../sessions/types';
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
  const clients = connectedClients(session);
  const primary = clients[0] ?? null;

  return {
    sessionId: session.id,
    status: sessionStatus(session, now),
    protocolVersion: PROTOCOL_VERSION,
    roblox: {
      connected,
      clientCount: clients.length,
      /**
       * Every attached client. With more than one, a tool call must name which
       * client it is for via the "client" argument, or it fails with
       * CLIENT_AMBIGUOUS rather than picking one.
       */
      clients: clients.map((client) => ({
        client: client.clientId,
        label: client.label,
        account: client.metadata?.localPlayer?.name ?? null,
        executor: client.metadata?.executor ?? null,
        place: client.metadata?.gameName ?? null,
        connectedAt: new Date(client.connectedAt).toISOString(),
        uptimeSeconds: Math.floor((now - client.connectedAt) / 1000),
        bridgeVersion: client.bridgeVersion,
        capabilities: client.capabilities,
      })),
      connectedAt: primary ? new Date(primary.connectedAt).toISOString() : null,
      lastHeartbeatAt: primary ? new Date(primary.lastHeartbeatAt).toISOString() : null,
      uptimeSeconds: primary ? Math.floor((now - primary.connectedAt) / 1000) : null,
      bridgeVersion: primary?.bridgeVersion ?? null,
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
      expiresAt: session.expiresAt === null ? null : new Date(session.expiresAt).toISOString(),
      expiresInSeconds:
        session.expiresAt === null
          ? null
          : Math.max(0, Math.floor((session.expiresAt - now) / 1000)),
      neverExpires: session.expiresAt === null,
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

/** Watchers the client currently has installed. */
export function listWatches(session: SessionRecord): Record<string, unknown> {
  const observations = session.observations;
  return {
    active: [...observations.activeWatches.entries()].map(([watchId, watch]) => ({
      watchId,
      client: watch.clientId,
      target: watch.target,
      kinds: watch.kinds,
    })),
    count: observations.activeWatches.size,
    bufferedEvents: observations.watchEvents.length,
    droppedEvents: observations.droppedWatchEvents,
    note:
      observations.activeWatches.size === 0
        ? 'No watchers are installed. Use clovyre_watch_start to add one.'
        : 'Poll clovyre_get_watch_events to read what these watchers recorded.',
  };
}

export function getWatchEvents(
  session: SessionRecord,
  options: {
    limit: number;
    clientId?: string | null;
    watchId?: string;
    since?: number;
    clear?: boolean;
  },
): Record<string, unknown> {
  const observations = session.observations;
  let events = observations.watchEvents;

  if (options.clientId) events = events.filter((event) => event.clientId === options.clientId);
  if (options.watchId) events = events.filter((event) => event.watchId === options.watchId);
  if (options.since) events = events.filter((event) => event.at > options.since!);

  const selected = events.slice(-options.limit).reverse();
  const dropped = observations.droppedWatchEvents;

  if (options.clear) {
    observations.watchEvents.length = 0;
    observations.droppedWatchEvents = 0;
  }

  return {
    events: selected.map((event) => ({
      at: new Date(event.at).toISOString(),
      atEpochMs: event.at,
      client: event.clientId,
      watchId: event.watchId,
      kind: event.kind,
      target: event.target,
      detail: event.detail,
    })),
    returned: selected.length,
    buffered: observations.watchEvents.length,
    dropped,
    activeWatches: observations.activeWatches.size,
    note:
      dropped > 0
        ? `${dropped} event(s) were dropped because the buffer filled. Poll more often or narrow the watch.`
        : undefined,
  };
}

export function getRemoteCalls(
  session: SessionRecord,
  options: {
    limit: number;
    clientId?: string | null;
    remoteName?: string;
    method?: string;
    since?: number;
    clear?: boolean;
  },
): Record<string, unknown> {
  const observations = session.observations;
  let calls = observations.remoteCalls;

  if (options.clientId) calls = calls.filter((call) => call.clientId === options.clientId);

  if (options.remoteName) {
    const needle = options.remoteName.toLowerCase();
    calls = calls.filter((call) => call.remote.toLowerCase().includes(needle));
  }
  if (options.method && options.method !== 'any') {
    calls = calls.filter((call) => call.method === options.method);
  }
  if (options.since) calls = calls.filter((call) => call.at > options.since!);

  const selected = calls.slice(-options.limit).reverse();
  const dropped = observations.droppedRemoteCalls;

  if (options.clear) {
    observations.remoteCalls.length = 0;
    observations.droppedRemoteCalls = 0;
  }

  return {
    spyActive: observations.remoteSpyActive,
    startedAt: observations.remoteSpyStartedAt
      ? new Date(observations.remoteSpyStartedAt).toISOString()
      : null,
    calls: selected.map((call) => ({
      at: new Date(call.at).toISOString(),
      atEpochMs: call.at,
      client: call.clientId,
      remote: call.remote,
      className: call.className,
      method: call.method,
      argCount: call.argCount,
      args: call.args,
      callerScript: call.callerScript,
      truncated: call.truncated,
    })),
    returned: selected.length,
    buffered: observations.remoteCalls.length,
    dropped,
    note: !observations.remoteSpyActive
      ? 'The remote spy is not running. The session owner must enable it, then call clovyre_remote_spy_start.'
      : dropped > 0
        ? `${dropped} call(s) were dropped because the buffer filled. Poll more often or use nameFilter.`
        : 'Outgoing client-to-server calls only. Clovyre cannot fire remotes.',
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
