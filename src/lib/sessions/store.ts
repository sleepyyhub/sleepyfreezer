import { createHash } from 'node:crypto';
import { AuditLog } from '../audit/audit-log';
import { getConfig } from '../config';
import type { CapabilityMap, ClientMetadata } from '../protocol/messages';
import {
  fingerprint,
  generateSessionId,
  generateToken,
  hashToken,
  verifyToken,
} from '../security/tokens';
import {
  isPrivilegeActive,
  sessionStatus,
  type CredentialRole,
  type PrivilegeName,
  type SessionRecord,
  type SessionStatus,
} from './types';

/**
 * In-memory session store.
 *
 * Clovyre sessions are deliberately ephemeral: nothing here survives a process
 * restart, which is documented behaviour for the single-instance deployment. The
 * store owns lifecycle (creation, expiry, termination) and credential checks;
 * command routing lives in the session broker.
 */

export interface CreatedSession {
  readonly session: SessionRecord;
  /** Plaintext credentials — returned exactly once, at creation. */
  readonly secrets: {
    readonly robloxToken: string;
    readonly mcpToken: string;
    readonly ownerToken: string;
    readonly csrfToken: string;
  };
}

export type AuthFailure =
  | 'session_not_found'
  | 'session_expired'
  | 'session_terminated'
  | 'credential_revoked'
  | 'invalid_credential';

export type AuthResult = { ok: true; session: SessionRecord } | { ok: false; reason: AuthFailure };

/** Addresses are only ever retained as a salted digest. */
export function hashAddress(address: string | null | undefined): string {
  if (!address) return 'unknown';
  return createHash('sha256')
    .update(`${getConfig().sessionSecret}:${address}`)
    .digest('hex')
    .slice(0, 16);
}

export class SessionStore {
  private readonly sessions = new Map<string, SessionRecord>();
  private sweepTimer: NodeJS.Timeout | null = null;

  create(options: { creatorAddress?: string | null } = {}): CreatedSession {
    const config = getConfig();
    this.sweep();

    if (this.sessions.size >= config.maxSessions) {
      throw new Error('Clovyre is at its concurrent session limit. Try again shortly.');
    }

    const now = Date.now();
    const robloxToken = generateToken('roblox');
    const mcpToken = generateToken('mcp');
    const ownerToken = generateToken('owner');
    const csrfToken = generateToken('owner');

    const makeCredential = (token: string) => ({
      hash: hashToken(token),
      createdAt: now,
      fingerprint: fingerprint(token),
      revokedAt: null,
      lastUsedAt: null,
      useCount: 0,
    });

    const session: SessionRecord = {
      id: generateSessionId(),
      createdAt: now,
      expiresAt: now + config.sessionTtlMs,
      terminatedAt: null,
      terminationReason: null,
      credentials: {
        roblox: makeCredential(robloxToken),
        mcp: makeCredential(mcpToken),
        owner: makeCredential(ownerToken),
      },
      csrfToken,
      privileges: {
        execute_luau: { enabled: false, expiresAt: null, enabledAt: null },
        executor_globals: { enabled: false, expiresAt: null, enabledAt: null },
        mutations: { enabled: false, expiresAt: null, enabledAt: null },
      },
      roblox: null,
      mcpConnections: new Map(),
      capabilities: {},
      metadata: null,
      commands: new Map(),
      commandOrder: [],
      audit: new AuditLog(),
      creatorAddressHash: hashAddress(options.creatorAddress),
    };

    session.audit.record({
      kind: 'session_created',
      actor: 'owner',
      message: `Session created with a ${Math.round(config.sessionTtlMs / 60_000)} minute lifetime.`,
      detail: {
        robloxCredential: session.credentials.roblox.fingerprint,
        mcpCredential: session.credentials.mcp.fingerprint,
        ownerCredential: session.credentials.owner.fingerprint,
      },
    });

    this.sessions.set(session.id, session);
    this.ensureSweeper();

    return {
      session,
      secrets: { robloxToken, mcpToken, ownerToken, csrfToken },
    };
  }

  get(sessionId: string): SessionRecord | null {
    return this.sessions.get(sessionId) ?? null;
  }

  status(sessionId: string): SessionStatus | null {
    const session = this.sessions.get(sessionId);
    return session ? sessionStatus(session) : null;
  }

  /**
   * Verifies a credential for a specific role on a specific session. Cross-session
   * routing is impossible here because the token is only ever checked against the
   * digest stored on the addressed session.
   */
  authenticate(sessionId: string, role: CredentialRole, presentedToken: string | null): AuthResult {
    const session = this.sessions.get(sessionId);
    if (!session) return { ok: false, reason: 'session_not_found' };

    const status = sessionStatus(session);
    if (status === 'terminated') return { ok: false, reason: 'session_terminated' };
    if (status === 'expired') {
      this.expire(session);
      return { ok: false, reason: 'session_expired' };
    }

    const credential = session.credentials[role];
    if (credential.revokedAt !== null) return { ok: false, reason: 'credential_revoked' };
    if (!verifyToken(presentedToken, credential.hash)) {
      return { ok: false, reason: 'invalid_credential' };
    }

    credential.lastUsedAt = Date.now();
    credential.useCount += 1;
    return { ok: true, session };
  }

  revokeCredential(
    session: SessionRecord,
    role: CredentialRole,
    actor: 'owner' | 'system',
  ): boolean {
    const credential = session.credentials[role];
    if (credential.revokedAt !== null) return false;
    credential.revokedAt = Date.now();
    session.audit.record({
      kind: 'credential_revoked',
      actor,
      severity: 'warn',
      message: `The ${role} credential was revoked.`,
      detail: { credential: credential.fingerprint },
    });
    return true;
  }

  /**
   * Mints a fresh credential for one role and returns the plaintext once.
   *
   * This is what lets the dashboard regenerate a loadstring after a reload:
   * only digests are stored, so the previous token genuinely cannot be shown
   * again — a new one has to be issued. The old token stops authenticating
   * immediately, but an already-authenticated live connection is left alone, so
   * regenerating a script never knocks a working bridge offline.
   */
  rotateCredential(
    session: SessionRecord,
    role: CredentialRole,
    actor: 'owner' | 'system',
  ): string {
    const token = generateToken(role);
    const previous = session.credentials[role];

    session.credentials[role] = {
      hash: hashToken(token),
      createdAt: Date.now(),
      fingerprint: fingerprint(token),
      revokedAt: null,
      lastUsedAt: null,
      useCount: 0,
    };

    session.audit.record({
      kind: 'credential_rotated',
      actor,
      severity: 'warn',
      message: `The ${role} credential was regenerated. The previous one no longer authenticates.`,
      detail: {
        previousCredential: previous.fingerprint,
        newCredential: session.credentials[role].fingerprint,
      },
    });
    return token;
  }

  terminate(session: SessionRecord, reason: string, actor: 'owner' | 'system'): void {
    if (session.terminatedAt !== null) return;
    session.terminatedAt = Date.now();
    session.terminationReason = reason;
    session.audit.record({
      kind: 'session_terminated',
      actor,
      severity: 'warn',
      message: `Session terminated: ${reason}`,
    });
  }

  private expire(session: SessionRecord): void {
    if (session.terminatedAt !== null) return;
    session.audit.record({
      kind: 'session_expired',
      actor: 'system',
      severity: 'warn',
      message: 'Session reached its expiry time.',
    });
  }

  setPrivilege(
    session: SessionRecord,
    privilege: PrivilegeName,
    enabled: boolean,
    actor: 'owner' | 'system',
  ): void {
    const config = getConfig();
    const state = session.privileges[privilege];
    if (enabled) {
      state.enabled = true;
      state.enabledAt = Date.now();
      state.expiresAt = Date.now() + config.privilegeTtlMs;
      session.audit.record({
        kind: 'privilege_enabled',
        actor,
        severity: 'warn',
        message: `Privileged capability "${privilege}" was enabled for ${Math.round(
          config.privilegeTtlMs / 60_000,
        )} minutes.`,
      });
    } else {
      state.enabled = false;
      state.expiresAt = null;
      state.enabledAt = null;
      session.audit.record({
        kind: 'privilege_disabled',
        actor,
        message: `Privileged capability "${privilege}" was disabled.`,
      });
    }
  }

  hasPrivilege(session: SessionRecord, privilege: PrivilegeName, now = Date.now()): boolean {
    const state = session.privileges[privilege];
    if (state.enabled && !isPrivilegeActive(state, now)) {
      // Lapsed grants are cleared on read so the dashboard reflects reality.
      state.enabled = false;
      state.expiresAt = null;
      state.enabledAt = null;
      session.audit.record({
        kind: 'privilege_expired',
        actor: 'system',
        message: `Privileged capability "${privilege}" expired automatically.`,
      });
      return false;
    }
    return isPrivilegeActive(state, now);
  }

  updateCapabilities(session: SessionRecord, capabilities: CapabilityMap): void {
    session.capabilities = capabilities;
  }

  updateMetadata(session: SessionRecord, metadata: ClientMetadata): void {
    session.metadata = metadata;
  }

  /** Removes sessions that expired or terminated long enough ago to be useless. */
  sweep(now = Date.now()): number {
    const graceMs = 10 * 60_000;
    let removed = 0;
    for (const [id, session] of this.sessions) {
      const status = sessionStatus(session, now);
      if (status === 'active') continue;
      const endedAt = session.terminatedAt ?? session.expiresAt;
      if (now - endedAt > graceMs) {
        this.sessions.delete(id);
        removed += 1;
      } else if (status === 'expired') {
        this.expire(session);
      }
    }
    return removed;
  }

  private ensureSweeper(): void {
    if (this.sweepTimer) return;
    this.sweepTimer = setInterval(() => this.sweep(), 60_000);
    // Never hold the event loop open for housekeeping.
    this.sweepTimer.unref?.();
  }

  get size(): number {
    return this.sessions.size;
  }

  /** Snapshot used by the health endpoint. Contains no credential material. */
  stats(now = Date.now()): {
    total: number;
    active: number;
    robloxConnected: number;
    mcpConnections: number;
  } {
    let active = 0;
    let robloxConnected = 0;
    let mcpConnections = 0;
    for (const session of this.sessions.values()) {
      if (sessionStatus(session, now) === 'active') {
        active += 1;
        if (session.roblox) robloxConnected += 1;
        mcpConnections += session.mcpConnections.size;
      }
    }
    return { total: this.sessions.size, active, robloxConnected, mcpConnections };
  }

  /** Test-only: drops every session. */
  clear(): void {
    this.sessions.clear();
  }
}

type StoreGlobal = typeof globalThis & { __clovyreSessionStore?: SessionStore };

export function getSessionStore(): SessionStore {
  const store = globalThis as StoreGlobal;
  if (!store.__clovyreSessionStore) {
    store.__clovyreSessionStore = new SessionStore();
  }
  return store.__clovyreSessionStore;
}
