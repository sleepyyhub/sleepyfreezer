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
export type PrivilegeName = 'execute_luau' | 'executor_globals' | 'mutations';

export interface PrivilegeState {
  enabled: boolean;
  /** Absolute time the grant lapses. Null when disabled. */
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

export interface SessionRecord {
  readonly id: string;
  readonly createdAt: number;
  expiresAt: number;
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

  /** Populated when the session was created behind a proxy. Hashed, not raw. */
  readonly creatorAddressHash: string;
}

export type SessionStatus = 'active' | 'expired' | 'terminated';

export function sessionStatus(session: SessionRecord, now = Date.now()): SessionStatus {
  if (session.terminatedAt !== null) return 'terminated';
  if (session.expiresAt <= now) return 'expired';
  return 'active';
}

export function isPrivilegeActive(state: PrivilegeState, now = Date.now()): boolean {
  return state.enabled && state.expiresAt !== null && state.expiresAt > now;
}
