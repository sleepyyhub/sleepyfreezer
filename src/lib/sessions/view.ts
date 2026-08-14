import { getConfig } from '../config';
import { PROTOCOL_VERSION, type CapabilityMap, type ClientMetadata } from '../protocol/messages';
import { evaluateAllTools } from '../mcp/tool-availability';
import { getSessionBroker } from './broker';
import { getSessionStore } from './store';
import {
  connectedClients,
  sessionStatus,
  type CredentialRole,
  type PrivilegeName,
  type SessionRecord,
  type SessionStatus,
} from './types';

/**
 * Serialisable view of a session for the dashboard.
 *
 * This is the only shape that crosses into the browser. It deliberately contains
 * no credential material — only fingerprints, which are non-reversible.
 */

export interface CredentialView {
  readonly role: CredentialRole;
  readonly fingerprint: string;
  readonly createdAt: string;
  readonly lastUsedAt: string | null;
  readonly useCount: number;
  readonly revoked: boolean;
  readonly revokedAt: string | null;
}

export interface PrivilegeView {
  readonly name: PrivilegeName;
  readonly enabled: boolean;
  readonly expiresAt: string | null;
  readonly expiresInSeconds: number | null;
  /** False when this grant stands until the owner turns it off. */
  readonly expires: boolean;
  readonly featureEnabled: boolean;
}

export interface CommandView {
  readonly id: string;
  readonly tool: string;
  readonly origin: 'mcp' | 'owner' | 'system';
  readonly status: 'pending' | 'succeeded' | 'failed' | 'timeout' | 'cancelled';
  readonly startedAt: string;
  readonly durationMs: number | null;
  readonly argumentsPreview: string;
  readonly resultPreview: string | null;
  readonly errorCode: string | null;
  readonly errorMessage: string | null;
}

export interface AuditView {
  readonly id: string;
  readonly at: string;
  readonly kind: string;
  readonly severity: 'info' | 'warn' | 'error';
  readonly actor: string;
  readonly message: string;
}

export interface ToolAvailabilityView {
  readonly name: string;
  readonly title: string;
  readonly category: string;
  readonly available: boolean;
  readonly reason: string | null;
  readonly detail: string | null;
  readonly readOnly: boolean;
  readonly requiresCapability: string | null;
  readonly requiresPrivilege: string | null;
}

export interface RobloxClientView {
  readonly clientId: string;
  readonly label: string;
  readonly account: string | null;
  readonly userId: number | null;
  readonly executor: string | null;
  readonly place: string | null;
  readonly connectedAt: string;
  readonly lastHeartbeatAt: string;
  readonly bridgeVersion: string | null;
}

export interface SessionView {
  readonly id: string;
  readonly status: SessionStatus;
  readonly createdAt: string;
  /** Null when the session has no timed expiry. */
  readonly expiresAt: string | null;
  readonly expiresInSeconds: number | null;
  readonly ageSeconds: number;
  readonly terminationReason: string | null;
  readonly protocolVersion: number;

  readonly roblox: {
    readonly connected: boolean;
    readonly clientCount: number;
    readonly clients: readonly RobloxClientView[];
    /** Summary fields describing the first-connected client. */
    readonly connectedAt: string | null;
    readonly lastHeartbeatAt: string | null;
    readonly bridgeVersion: string | null;
  };
  readonly metadata: ClientMetadata | null;
  readonly capabilities: CapabilityMap;
  readonly settings: { readonly clientLogging: boolean };

  readonly mcp: {
    readonly connectionCount: number;
    readonly connections: ReadonlyArray<{
      readonly id: string;
      readonly clientName: string | null;
      readonly clientVersion: string | null;
      readonly protocolVersion: string | null;
      readonly connectedAt: string;
      readonly lastSeenAt: string;
    }>;
  };

  readonly credentials: readonly CredentialView[];
  readonly privileges: readonly PrivilegeView[];
  readonly commands: readonly CommandView[];
  readonly events: readonly AuditView[];
  readonly tools: readonly ToolAvailabilityView[];
  readonly pendingCommandCount: number;
}

const iso = (value: number | null): string | null =>
  value === null ? null : new Date(value).toISOString();

export function buildSessionView(session: SessionRecord, now = Date.now()): SessionView {
  const config = getConfig();
  const store = getSessionStore();
  const broker = getSessionBroker();
  const clients = connectedClients(session);
  const primary = clients[0] ?? null;

  const credential = (role: CredentialRole): CredentialView => {
    const record = session.credentials[role];
    return {
      role,
      fingerprint: record.fingerprint,
      createdAt: new Date(record.createdAt).toISOString(),
      lastUsedAt: iso(record.lastUsedAt),
      useCount: record.useCount,
      revoked: record.revokedAt !== null,
      revokedAt: iso(record.revokedAt),
    };
  };

  // Each privilege answers to its own deployment kill switch. Executor globals
  // only matter alongside Luau execution, so they follow that switch.
  const privilegeFeatureEnabled = (name: PrivilegeName): boolean => {
    if (name === 'mutations') return config.mutationToolsFeatureEnabled;
    if (name === 'remote_spy') return config.remoteSpyFeatureEnabled;
    return config.executeLuauFeatureEnabled;
  };

  const privilege = (name: PrivilegeName): PrivilegeView => {
    const state = session.privileges[name];
    const active = store.hasPrivilege(session, name, now);
    return {
      name,
      enabled: active,
      expiresAt: active ? iso(state.expiresAt) : null,
      expiresInSeconds:
        active && state.expiresAt ? Math.max(0, Math.floor((state.expiresAt - now) / 1000)) : null,
      expires: store.privilegeTtlMs(name) !== null,
      featureEnabled: privilegeFeatureEnabled(name),
    };
  };

  const commands: CommandView[] = session.commandOrder
    .slice(-100)
    .reverse()
    .map((id) => session.commands.get(id))
    .filter((record): record is NonNullable<typeof record> => Boolean(record))
    .map((record) => ({
      id: record.id,
      tool: record.tool,
      origin: record.origin,
      status: record.status,
      startedAt: new Date(record.startedAt).toISOString(),
      durationMs: record.durationMs,
      argumentsPreview: record.argumentsPreview,
      resultPreview: record.resultPreview,
      errorCode: record.errorCode,
      errorMessage: record.errorMessage,
    }));

  return {
    id: session.id,
    status: sessionStatus(session, now),
    createdAt: new Date(session.createdAt).toISOString(),
    expiresAt: session.expiresAt === null ? null : new Date(session.expiresAt).toISOString(),
    expiresInSeconds:
      session.expiresAt === null ? null : Math.max(0, Math.floor((session.expiresAt - now) / 1000)),
    ageSeconds: Math.floor((now - session.createdAt) / 1000),
    terminationReason: session.terminationReason,
    protocolVersion: PROTOCOL_VERSION,

    roblox: {
      connected: clients.length > 0,
      clientCount: clients.length,
      clients: clients.map((client) => ({
        clientId: client.clientId,
        label: client.label,
        account: client.metadata?.localPlayer?.name ?? null,
        userId: client.metadata?.localPlayer?.userId ?? null,
        executor: client.metadata?.executor ?? null,
        place: client.metadata?.gameName ?? null,
        connectedAt: new Date(client.connectedAt).toISOString(),
        lastHeartbeatAt: new Date(client.lastHeartbeatAt).toISOString(),
        bridgeVersion: client.bridgeVersion,
      })),
      // The summary fields describe the first client, so a single-client session
      // reads exactly as it did before.
      connectedAt: primary ? new Date(primary.connectedAt).toISOString() : null,
      lastHeartbeatAt: primary ? new Date(primary.lastHeartbeatAt).toISOString() : null,
      bridgeVersion: primary?.bridgeVersion ?? null,
    },
    metadata: session.metadata,
    capabilities: session.capabilities,
    settings: { clientLogging: session.settings.clientLogging },

    mcp: {
      connectionCount: session.mcpConnections.size,
      connections: [...session.mcpConnections.values()].map((connection) => ({
        id: connection.connectionId,
        clientName: connection.clientName,
        clientVersion: connection.clientVersion,
        protocolVersion: connection.protocolVersion,
        connectedAt: new Date(connection.connectedAt).toISOString(),
        lastSeenAt: new Date(connection.lastSeenAt).toISOString(),
      })),
    },

    credentials: [credential('roblox'), credential('mcp'), credential('owner')],
    privileges: [
      privilege('execute_luau'),
      privilege('executor_globals'),
      privilege('mutations'),
      privilege('remote_spy'),
    ],
    commands,
    events: session.audit.list({ limit: 120 }).map((event) => ({
      id: event.id,
      at: new Date(event.at).toISOString(),
      kind: event.kind,
      severity: event.severity,
      actor: event.actor,
      message: event.message,
    })),
    tools: evaluateAllTools(session).map((entry) => ({
      name: entry.definition.name,
      title: entry.definition.title,
      category: entry.definition.category,
      available: entry.available,
      reason: entry.reason,
      detail: entry.detail,
      readOnly: entry.definition.readOnly,
      requiresCapability: entry.definition.requiresCapability ?? null,
      requiresPrivilege: entry.definition.requiresPrivilege ?? null,
    })),
    pendingCommandCount: broker.countPending(session.id),
  };
}
