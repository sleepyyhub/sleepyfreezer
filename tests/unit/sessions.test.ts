import { afterAll, beforeEach, describe, expect, it, vi } from 'vitest';
import { SessionStore } from '../../src/lib/sessions/store';
import { sessionStatus } from '../../src/lib/sessions/types';
import { getConfig, resetConfigForTests } from '../../src/lib/config';
import {
  fingerprint,
  generateSessionId,
  generateToken,
  hashToken,
  verifyToken,
} from '../../src/lib/security/tokens';

describe('session credentials', () => {
  let store: SessionStore;

  beforeEach(() => {
    resetConfigForTests();
    process.env.SESSION_SECRET = 'unit-test-session-secret-0123456789';
    process.env.TOKEN_HASH_SECRET = 'unit-test-token-hash-secret-0123456789';
    store = new SessionStore();
  });

  it('issues four independent credentials and stores only digests', () => {
    const { session, secrets } = store.create();

    const values = [secrets.robloxToken, secrets.mcpToken, secrets.ownerToken, secrets.csrfToken];
    expect(new Set(values).size).toBe(4);

    const serialized = JSON.stringify(session.credentials);
    for (const token of [secrets.robloxToken, secrets.mcpToken, secrets.ownerToken]) {
      expect(serialized).not.toContain(token);
    }
    expect(session.credentials.roblox.hash).toBe(hashToken(secrets.robloxToken));
  });

  it('does not accept the public session id as a credential', () => {
    const { session } = store.create();
    const result = store.authenticate(session.id, 'roblox', session.id);
    expect(result).toEqual({ ok: false, reason: 'invalid_credential' });
  });

  it('rejects a credential presented for the wrong role', () => {
    const { session, secrets } = store.create();
    expect(store.authenticate(session.id, 'mcp', secrets.robloxToken).ok).toBe(false);
    expect(store.authenticate(session.id, 'roblox', secrets.robloxToken).ok).toBe(true);
  });

  it('isolates sessions: a token from one session never authenticates another', () => {
    const first = store.create();
    const second = store.create();

    expect(store.authenticate(second.session.id, 'roblox', first.secrets.robloxToken)).toEqual({
      ok: false,
      reason: 'invalid_credential',
    });
    expect(store.authenticate(first.session.id, 'roblox', first.secrets.robloxToken).ok).toBe(true);
  });

  it('rejects a revoked credential while leaving the others working', () => {
    const { session, secrets } = store.create();
    store.revokeCredential(session, 'roblox', 'owner');

    expect(store.authenticate(session.id, 'roblox', secrets.robloxToken)).toEqual({
      ok: false,
      reason: 'credential_revoked',
    });
    expect(store.authenticate(session.id, 'mcp', secrets.mcpToken).ok).toBe(true);
  });

  it('rejects everything once the session is terminated', () => {
    const { session, secrets } = store.create();
    store.terminate(session, 'test termination', 'owner');

    expect(sessionStatus(session)).toBe('terminated');
    expect(store.authenticate(session.id, 'mcp', secrets.mcpToken)).toEqual({
      ok: false,
      reason: 'session_terminated',
    });
  });

  it('expires sessions on the configured timer', () => {
    const { session, secrets } = store.create();
    expect(sessionStatus(session)).toBe('active');

    session.expiresAt = Date.now() - 1;
    expect(sessionStatus(session)).toBe('expired');
    expect(store.authenticate(session.id, 'mcp', secrets.mcpToken)).toEqual({
      ok: false,
      reason: 'session_expired',
    });
  });

  it('reports an unknown session distinctly from a bad credential', () => {
    expect(store.authenticate(generateSessionId(), 'mcp', generateToken('mcp'))).toEqual({
      ok: false,
      reason: 'session_not_found',
    });
  });

  it('tracks credential usage without recording the token', () => {
    const { session, secrets } = store.create();
    store.authenticate(session.id, 'owner', secrets.ownerToken);
    store.authenticate(session.id, 'owner', secrets.ownerToken);

    expect(session.credentials.owner.useCount).toBe(2);
    expect(session.credentials.owner.lastUsedAt).not.toBeNull();
    expect(session.credentials.owner.fingerprint).toBe(fingerprint(secrets.ownerToken));
  });

  it('regenerates a credential, invalidating the previous one', () => {
    const { session, secrets } = store.create();
    expect(store.authenticate(session.id, 'roblox', secrets.robloxToken).ok).toBe(true);

    const replacement = store.rotateCredential(session, 'roblox', 'owner');

    expect(replacement).not.toBe(secrets.robloxToken);
    expect(replacement.startsWith('crx_')).toBe(true);
    expect(store.authenticate(session.id, 'roblox', replacement).ok).toBe(true);
    expect(store.authenticate(session.id, 'roblox', secrets.robloxToken)).toEqual({
      ok: false,
      reason: 'invalid_credential',
    });
  });

  it('leaves the other credentials untouched when one is regenerated', () => {
    const { session, secrets } = store.create();
    store.rotateCredential(session, 'roblox', 'owner');

    expect(store.authenticate(session.id, 'mcp', secrets.mcpToken).ok).toBe(true);
    expect(store.authenticate(session.id, 'owner', secrets.ownerToken).ok).toBe(true);
  });

  it('clears a revocation when the credential is regenerated', () => {
    const { session } = store.create();
    store.revokeCredential(session, 'mcp', 'owner');

    const replacement = store.rotateCredential(session, 'mcp', 'owner');
    expect(session.credentials.mcp.revokedAt).toBeNull();
    expect(store.authenticate(session.id, 'mcp', replacement).ok).toBe(true);
  });

  it('audits a regeneration without recording either token', () => {
    const { session, secrets } = store.create();
    const replacement = store.rotateCredential(session, 'roblox', 'owner');

    const events = session.audit.list();
    expect(events.some((event) => event.kind === 'credential_rotated')).toBe(true);

    const serialised = JSON.stringify(events);
    expect(serialised).not.toContain(secrets.robloxToken);
    expect(serialised).not.toContain(replacement);
  });

  it('sweeps sessions that ended well in the past', () => {
    const { session } = store.create();
    store.terminate(session, 'done', 'owner');
    session.terminatedAt = Date.now() - 60 * 60_000;

    expect(store.sweep()).toBe(1);
    expect(store.get(session.id)).toBeNull();
  });

  it('enforces the concurrent session ceiling', () => {
    resetConfigForTests();
    process.env.MAX_SESSIONS = '2';
    const limited = new SessionStore();
    limited.create();
    limited.create();
    expect(() => limited.create()).toThrow(/session limit/i);
    delete process.env.MAX_SESSIONS;
    resetConfigForTests();
  });
});

describe('privileges', () => {
  let store: SessionStore;

  beforeEach(() => {
    resetConfigForTests();
    process.env.SESSION_SECRET = 'unit-test-session-secret-0123456789';
    process.env.TOKEN_HASH_SECRET = 'unit-test-token-hash-secret-0123456789';
    store = new SessionStore();
  });

  it('starts every privilege disabled', () => {
    const { session } = store.create();
    expect(store.hasPrivilege(session, 'execute_luau')).toBe(false);
    expect(store.hasPrivilege(session, 'executor_globals')).toBe(false);
    expect(store.hasPrivilege(session, 'mutations')).toBe(false);
  });

  it('grants a privilege with an expiry and revokes it on demand', () => {
    const { session } = store.create();
    store.setPrivilege(session, 'execute_luau', true, 'owner');

    expect(store.hasPrivilege(session, 'execute_luau')).toBe(true);
    expect(session.privileges.execute_luau.expiresAt).toBeGreaterThan(Date.now());

    store.setPrivilege(session, 'execute_luau', false, 'owner');
    expect(store.hasPrivilege(session, 'execute_luau')).toBe(false);
  });

  it('lets a grant lapse automatically and records the expiry', () => {
    const { session } = store.create();
    store.setPrivilege(session, 'execute_luau', true, 'owner');

    const later = Date.now() + getConfig().privilegeTtlMs + 1000;
    expect(store.hasPrivilege(session, 'execute_luau', later)).toBe(false);
    expect(session.privileges.execute_luau.enabled).toBe(false);
    expect(session.audit.list().some((event) => event.kind === 'privilege_expired')).toBe(true);
  });
});

describe('token primitives', () => {
  beforeEach(() => {
    resetConfigForTests();
    process.env.TOKEN_HASH_SECRET = 'unit-test-token-hash-secret-0123456789';
  });

  it('generates role-tagged tokens with high entropy', () => {
    const token = generateToken('roblox');
    expect(token.startsWith('crx_')).toBe(true);
    expect(token.length).toBeGreaterThanOrEqual(47);

    const many = new Set(Array.from({ length: 500 }, () => generateToken('mcp')));
    expect(many.size).toBe(500);
  });

  it('verifies a token only against its own digest', () => {
    const token = generateToken('owner');
    const digest = hashToken(token);
    expect(verifyToken(token, digest)).toBe(true);
    expect(verifyToken(generateToken('owner'), digest)).toBe(false);
    expect(verifyToken(null, digest)).toBe(false);
    expect(verifyToken('', digest)).toBe(false);
  });

  it('produces a stable, non-reversible fingerprint', () => {
    const token = generateToken('mcp');
    expect(fingerprint(token)).toBe(fingerprint(token));
    expect(token).not.toContain(fingerprint(token));
    expect(fingerprint(token)).toHaveLength(12);
  });

  it('never emits an ambiguous character in a display session id', () => {
    for (let index = 0; index < 200; index += 1) {
      expect(generateSessionId().slice(3)).not.toMatch(/[O0Il1]/);
    }
  });
});

describe('config', () => {
  beforeEach(() => resetConfigForTests());

  it('rejects an out-of-range session lifetime rather than silently defaulting', () => {
    // 0 is meaningful now (never expire), so the invalid case is out of range.
    process.env.SESSION_TTL_MINUTES = '999999';
    expect(() => getConfig()).toThrow(/Invalid Clovyre environment/);

    process.env.SESSION_TTL_MINUTES = '-5';
    resetConfigForTests();
    expect(() => getConfig()).toThrow(/Invalid Clovyre environment/);

    delete process.env.SESSION_TTL_MINUTES;
    resetConfigForTests();
  });

  it('generates ephemeral secrets when none are supplied and flags it', () => {
    const previousSession = process.env.SESSION_SECRET;
    const previousHash = process.env.TOKEN_HASH_SECRET;
    delete process.env.SESSION_SECRET;
    delete process.env.TOKEN_HASH_SECRET;
    const warn = vi.spyOn(console, 'warn').mockImplementation(() => undefined);

    const config = getConfig();
    expect(config.usingEphemeralSecrets).toBe(true);
    expect(config.tokenHashSecret.length).toBeGreaterThan(16);

    warn.mockRestore();
    if (previousSession) process.env.SESSION_SECRET = previousSession;
    if (previousHash) process.env.TOKEN_HASH_SECRET = previousHash;
    resetConfigForTests();
  });
});

describe('sessions that never expire', () => {
  beforeEach(() => {
    resetConfigForTests();
    process.env.SESSION_SECRET = 'unit-test-session-secret-0123456789';
    process.env.TOKEN_HASH_SECRET = 'unit-test-token-hash-secret-0123456789';
    process.env.SESSION_TTL_MINUTES = '0';
  });

  afterAll(() => {
    delete process.env.SESSION_TTL_MINUTES;
    resetConfigForTests();
  });

  it('creates sessions with no expiry when the TTL is zero', () => {
    const store = new SessionStore();
    const { session } = store.create();

    expect(getConfig().sessionTtlMs).toBeNull();
    expect(session.expiresAt).toBeNull();
    expect(sessionStatus(session)).toBe('active');
  });

  it('stays active arbitrarily far into the future', () => {
    const store = new SessionStore();
    const { session, secrets } = store.create();

    const aYearOn = Date.now() + 365 * 24 * 60 * 60_000;
    expect(sessionStatus(session, aYearOn)).toBe('active');
    expect(store.authenticate(session.id, 'mcp', secrets.mcpToken).ok).toBe(true);
  });

  it('can still be terminated explicitly', () => {
    const store = new SessionStore();
    const { session, secrets } = store.create();

    store.terminate(session, 'done', 'owner');
    expect(sessionStatus(session)).toBe('terminated');
    expect(store.authenticate(session.id, 'mcp', secrets.mcpToken)).toEqual({
      ok: false,
      reason: 'session_terminated',
    });
  });

  it('is never swept while it is still active', () => {
    const store = new SessionStore();
    const { session } = store.create();

    expect(store.sweep(Date.now() + 10 * 365 * 24 * 60 * 60_000)).toBe(0);
    expect(store.get(session.id)).not.toBeNull();
  });
});

describe('per-privilege grant lifetimes', () => {
  let store: SessionStore;

  beforeEach(() => {
    resetConfigForTests();
    process.env.SESSION_SECRET = 'unit-test-session-secret-0123456789';
    process.env.TOKEN_HASH_SECRET = 'unit-test-token-hash-secret-0123456789';
    store = new SessionStore();
  });

  it('grants mutations without a timed expiry by default', () => {
    const { session } = store.create();
    store.setPrivilege(session, 'mutations', true, 'owner');

    expect(store.privilegeTtlMs('mutations')).toBeNull();
    expect(session.privileges.mutations.expiresAt).toBeNull();
    expect(store.hasPrivilege(session, 'mutations')).toBe(true);
  });

  it('keeps a standing mutation grant alive arbitrarily far ahead', () => {
    const { session } = store.create();
    store.setPrivilege(session, 'mutations', true, 'owner');

    const aYearOn = Date.now() + 365 * 24 * 60 * 60_000;
    expect(store.hasPrivilege(session, 'mutations', aYearOn)).toBe(true);
    expect(session.privileges.mutations.enabled).toBe(true);
  });

  it('still lets the owner revoke a standing grant', () => {
    const { session } = store.create();
    store.setPrivilege(session, 'mutations', true, 'owner');
    store.setPrivilege(session, 'mutations', false, 'owner');

    expect(store.hasPrivilege(session, 'mutations')).toBe(false);
    expect(session.privileges.mutations.expiresAt).toBeNull();
  });

  it('leaves execution and hooking on a short timer', () => {
    const { session } = store.create();
    for (const privilege of ['execute_luau', 'remote_spy'] as const) {
      store.setPrivilege(session, privilege, true, 'owner');
      expect(store.privilegeTtlMs(privilege)).toBe(getConfig().privilegeTtlMs);
      expect(session.privileges[privilege].expiresAt).not.toBeNull();

      const later = Date.now() + getConfig().privilegeTtlMs + 1000;
      expect(store.hasPrivilege(session, privilege, later)).toBe(false);
    }
  });

  it('never treats a disabled privilege as standing', () => {
    const { session } = store.create();
    // Disabled state also carries a null expiry; `enabled` must be authoritative.
    expect(session.privileges.mutations.expiresAt).toBeNull();
    expect(store.hasPrivilege(session, 'mutations')).toBe(false);
  });

  it('honours a configured mutation lifetime when one is set', () => {
    process.env.MUTATION_PRIVILEGE_TTL_MINUTES = '30';
    resetConfigForTests();
    const limited = new SessionStore();
    const { session } = limited.create();

    limited.setPrivilege(session, 'mutations', true, 'owner');
    expect(session.privileges.mutations.expiresAt).not.toBeNull();
    expect(limited.hasPrivilege(session, 'mutations', Date.now() + 31 * 60_000)).toBe(false);

    delete process.env.MUTATION_PRIVILEGE_TTL_MINUTES;
    resetConfigForTests();
  });
});
