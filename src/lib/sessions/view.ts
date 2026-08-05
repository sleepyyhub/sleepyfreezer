import { getConfig } from '../config';
import { PROTOCOL_VERSION, type CapabilityMap, type ClientMetadata } from '../protocol/messages';
import { evaluateAllTools } from '../mcp/tool-availability';
import { getSessionBroker } from './broker';
import { getSessionStore } from './store';
import {
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
    readonly connectedAt: string | null;
    readonly lastHeartbeatAt: string | null;
    readonly bridgeVersion: string | null;
  };
  readonly metadata: ClientMetadata | null;
  readonly capabilities: CapabilityMap;

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

  const privilege = (name: PrivilegeName): PrivilegeView => {
    const state = session.privileges[name];
    const active = store.hasPrivilege(session, name, now);
    return {
      name,
      enabled: active,
      expiresAt: active ? iso(state.expiresAt) : null,
      expiresInSeconds:
        active && state.expiresAt ? Math.max(0, Math.floor((state.expiresAt - now) / 1000)) : null,
      featureEnabled:
        name === 'mutations'
          ? config.mutationToolsFeatureEnabled
          : config.executeLuauFeatureEnabled,
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
      connected: broker.isConnected(session.id) && session.roblox !== null,
      connectedAt: session.roblox ? new Date(session.roblox.connectedAt).toISOString() : null,
      lastHeartbeatAt: session.roblox
        ? new Date(session.roblox.lastHeartbeatAt).toISOString()
        : null,
      bridgeVersion: session.roblox?.bridgeVersion ?? null,
    },
    metadata: session.metadata,
    capabilities: session.capabilities,

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
