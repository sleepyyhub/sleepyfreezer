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

/**
 * One live Roblox client. A session may hold several at once: two people running
 * the same script both belong to the session, and a tool call names which one it
 * is for.
 */
export interface RobloxClientState {
  /** Server-assigned handle, stable for as long as this client stays connected. */
  readonly clientId: string;
  readonly connectionId: string;
  readonly connectedAt: number;
  lastHeartbeatAt: number;
  readonly remoteAddressHash: string;
  bridgeVersion: string | null;
  /** Capabilities this particular executor reported. They differ between clients. */
  capabilities: CapabilityMap;
  metadata: ClientMetadata | null;
  /** Display name: the Roblox account where known, else the executor. */
  label: string;
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
  /** Which Roblox client the command was sent to. */
  readonly clientId: string;
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
  /** Which client observed it. Several clients may watch at once. */
  readonly clientId: string;
  readonly watchId: string;
  readonly kind: 'property' | 'childAdded' | 'childRemoved' | 'attribute';
  readonly target: string;
  readonly detail: unknown;
}

/** One outbound remote call observed on the client. */
export interface StackFrame {
  readonly source: string;
  readonly line: number | null;
  readonly name: string | null;
}

export interface RemoteCallEvent {
  readonly at: number;
  readonly clientId: string;
  /**
   * Handle for this specific call, good for as long as the client keeps it in
   * its call-site window. Pass it to clovyre_get_calling_code to see the code
   * that made the call.
   */
  readonly callId: string | null;
  readonly remote: string;
  readonly className: string;
  readonly method: string;
  readonly args: unknown;
  readonly argCount: number;
  readonly callerScript: string | null;
  /** Where in the caller the call happened, from the Luau stack. */
  readonly callerSource: string | null;
  readonly callerLine: number | null;
  readonly callerFunction: string | null;
  readonly stack: readonly StackFrame[];
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
  activeWatches: Map<
    string,
    { target: string; kinds: string[]; startedAt: number; clientId: string }
  >;
  /** Clients currently running the remote spy. */
  remoteSpyClients: Set<string>;
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
    remoteSpyClients: new Set(),
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

  /** Every live Roblox client, keyed by clientId, in connection order. */
  readonly robloxClients: Map<string, RobloxClientState>;
  readonly mcpConnections: Map<string, McpConnectionState>;

  /**
   * Session-level capability view: the union across connected clients. The MCP
   * tool list is per session, not per client, so a tool is offered when some
   * connected client can run it. Whether the *chosen* client can is settled at
   * dispatch, where the bridge answers CAPABILITY_UNAVAILABLE by name.
   */
  capabilities: CapabilityMap;
  /** Metadata of the first-connected client, kept for the dashboard summary. */
  metadata: ClientMetadata | null;

  readonly settings: SessionSettings;

  readonly commands: Map<string, CommandRecord>;
  readonly commandOrder: string[];

  readonly audit: AuditLog;

  readonly observations: Observations;

  /** Populated when the session was created behind a proxy. Hashed, not raw. */
  readonly creatorAddressHash: string;
}

export interface SessionSettings {
  /**
   * Whether the bridge prints to the executor console. Off by default: the
   * console is the user's own output window, and a tool bridge has no business
   * writing to it unless asked. Logs are always kept in the client's ring buffer
   * and reachable through clovyre_get_logs regardless.
   */
  clientLogging: boolean;
}

export function createSettings(): SessionSettings {
  return { clientLogging: false };
}

/** Live clients in connection order, oldest first. */
export function connectedClients(session: SessionRecord): RobloxClientState[] {
  return [...session.robloxClients.values()].sort((a, b) => a.connectedAt - b.connectedAt);
}

/**
 * Resolves the client a tool call names. Accepts the clientId or the label, and
 * matches case-insensitively so an agent can pass back what a human said.
 */
export function findClient(session: SessionRecord, selector: string): RobloxClientState | null {
  const wanted = selector.trim().toLowerCase();
  if (wanted.length === 0) return null;
  const clients = connectedClients(session);
  return (
    clients.find((client) => client.clientId.toLowerCase() === wanted) ??
    clients.find((client) => client.label.toLowerCase() === wanted) ??
    // A unique prefix is enough; an ambiguous one is treated as no match.
    (clients.filter((client) => client.clientId.toLowerCase().startsWith(wanted)).length === 1
      ? (clients.find((client) => client.clientId.toLowerCase().startsWith(wanted)) ?? null)
      : null)
  );
}

/** Builds the display label for a client from whatever identity it reported. */
export function buildClientLabel(metadata: ClientMetadata | null, clientId: string): string {
  const player = metadata?.localPlayer?.name;
  if (player) return player;
  if (metadata?.executor) return metadata.executor;
  return clientId;
}

/** Union of what every connected client reports. */
export function unionCapabilities(session: SessionRecord): CapabilityMap {
  const union: CapabilityMap = {};
  for (const client of session.robloxClients.values()) {
    for (const [name, enabled] of Object.entries(client.capabilities)) {
      if (enabled) union[name as keyof CapabilityMap] = true;
    }
  }
  return union;
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
