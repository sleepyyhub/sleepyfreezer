import type { AuditLog } from '../audit/audit-log';
import type { CapabilityMap, ClientMetadata } from '../protocol/messages';

/** Roles that hold a distinct credential. Never interchangeable. */
export type CredentialRole = 'roblox' | 'mcp' | 'owner';

export interface CredentialRecord {
  /** HMAC digest — the plaintext is shown once at creation and never stored. */
  readonly hash: string;
  readonly createdAt: number;
  /** Short non-reversible identifier used in audit lines. */
  readonly fingerprint: string;
  revokedAt: number | null;
  lastUsedAt: number | null;
  useCount: number;
}

/** Privileged capabilities the browser owner may switch on for a live session. */
export type PrivilegeName = 'execute_luau' | 'executor_globals' | 'mutations' | 'remote_spy';

export interface PrivilegeState {
  enabled: boolean;
  /**
   * Absolute time the grant lapses. Null means two different things depending on
   * `enabled`: when disabled there is no grant at all; when enabled the grant
   * stands until the owner revokes it. `enabled` is always the source of truth.
   */
  expiresAt: number | null;
  enabledAt: number | null;
}

export interface RobloxConnectionState {
  readonly connectionId: string;
  readonly connectedAt: number;
  lastHeartbeatAt: number;
  readonly remoteAddressHash: string;
  bridgeVersion: string | null;
}

export interface McpConnectionState {
  readonly connectionId: string;
  readonly connectedAt: number;
  lastSeenAt: number;
  clientName: string | null;
  clientVersion: string | null;
  protocolVersion: string | null;
}

export type CommandStatus = 'pending' | 'succeeded' | 'failed' | 'timeout' | 'cancelled';

export interface CommandRecord {
  readonly id: string;
  readonly tool: string;
  readonly startedAt: number;
  readonly timeoutMs: number;
  readonly origin: 'mcp' | 'owner' | 'system';
  status: CommandStatus;
  finishedAt: number | null;
  durationMs: number | null;
  /** Redacted, size-bounded previews. Never raw payloads. */
  argumentsPreview: string;
  resultPreview: string | null;
  errorCode: string | null;
  errorMessage: string | null;
}

/** One change reported by an active watcher on the client. */
export interface WatchEvent {
  readonly at: number;
  readonly watchId: string;
  readonly kind: 'property' | 'childAdded' | 'childRemoved' | 'attribute';
  readonly target: string;
  readonly detail: unknown;
}

/** One outbound remote call observed on the client. */
export interface RemoteCallEvent {
  readonly at: number;
  readonly remote: string;
  readonly className: string;
  readonly method: string;
  readonly args: unknown;
  readonly argCount: number;
  readonly callerScript: string | null;
  readonly truncated: boolean;
}

/**
 * Bounded ring buffers for observations pushed by the client between commands.
 * Watchers and the remote spy are fire-and-forget on the client side, so the
 * server keeps a capped window and the agent polls it.
 */
export interface Observations {
  watchEvents: WatchEvent[];
  remoteCalls: RemoteCallEvent[];
  /** Watch ids the client reports as currently installed. */
  activeWatches: Map<string, { target: string; kinds: string[]; startedAt: number }>;
  remoteSpyActive: boolean;
  remoteSpyStartedAt: number | null;
  /** Counts of what was dropped once a buffer filled. */
  droppedWatchEvents: number;
  droppedRemoteCalls: number;
}

export const OBSERVATION_LIMITS = {
  maxWatchEvents: 500,
  maxRemoteCalls: 500,
  maxActiveWatches: 32,
} as const;

export function createObservations(): Observations {
  return {
    watchEvents: [],
    remoteCalls: [],
    activeWatches: new Map(),
    remoteSpyActive: false,
    remoteSpyStartedAt: null,
    droppedWatchEvents: 0,
    droppedRemoteCalls: 0,
  };
}

export interface SessionRecord {
  readonly id: string;
  readonly createdAt: number;
  /**
   * Monotonic creation order. Millisecond timestamps tie when two sessions are
   * created in quick succession, which would otherwise make "the newest session
   * bound to a link" ambiguous — and resolve to the older one.
   */
  readonly sequence: number;
  /** Null when this session never expires on a timer. */
  expiresAt: number | null;
  terminatedAt: number | null;
  terminationReason: string | null;

  readonly credentials: Record<CredentialRole, CredentialRecord>;
  /** CSRF token paired with the owner cookie (double-submit). */
  readonly csrfToken: string;

  readonly privileges: Record<PrivilegeName, PrivilegeState>;

  roblox: RobloxConnectionState | null;
  readonly mcpConnections: Map<string, McpConnectionState>;

  capabilities: CapabilityMap;
  metadata: ClientMetadata | null;

  readonly commands: Map<string, CommandRecord>;
  readonly commandOrder: string[];

  readonly audit: AuditLog;

  readonly observations: Observations;

  /** Populated when the session was created behind a proxy. Hashed, not raw. */
  readonly creatorAddressHash: string;

}

export type SessionStatus = 'active' | 'expired' | 'terminated';

export function sessionStatus(session: SessionRecord, now = Date.now()): SessionStatus {
  if (session.terminatedAt !== null) return 'terminated';
  // A null expiry means the deployment runs sessions until they are terminated.
  if (session.expiresAt !== null && session.expiresAt <= now) return 'expired';
  return 'active';
}

export function isPrivilegeActive(state: PrivilegeState, now = Date.now()): boolean {
  if (!state.enabled) return false;
  // An enabled grant with no expiry stands until it is turned off.
  return state.expiresAt === null || state.expiresAt > now;
}
