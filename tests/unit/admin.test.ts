import { afterAll, beforeEach, describe, expect, it } from 'vitest';
import { NextRequest } from 'next/server';
import {
  authenticateAdmin,
  issueAdminCookieValue,
  verifyAdminCookie,
  verifyAdminToken,
} from '../../src/lib/admin/auth';
import { buildAdminOverview } from '../../src/lib/admin/overview';
import { getConfig, resetConfigForTests } from '../../src/lib/config';
import { getSessionStore } from '../../src/lib/sessions/store';

const TOKEN = 'operator-secret-value-for-tests-0123456789';

function configure(withAdmin: boolean): void {
  resetConfigForTests();
  process.env.SESSION_SECRET = 'admin-test-session-secret-0123456789';
  process.env.TOKEN_HASH_SECRET = 'admin-test-token-hash-secret-0123456789';
  if (withAdmin) {
    process.env.ADMIN_TOKEN = TOKEN;
  } else {
    delete process.env.ADMIN_TOKEN;
  }
  getConfig();
}

// The admin credential is process-wide, so it must not leak into other suites.
afterAll(() => {
  delete process.env.ADMIN_TOKEN;
  resetConfigForTests();
});

function requestWith(options: { query?: string; cookie?: string; header?: string }): NextRequest {
  const url = `https://clovyre.test/admin${options.query ? `?k=${options.query}` : ''}`;
  const headers = new Headers();
  if (options.cookie) headers.set('cookie', `clovyre_operator=${options.cookie}`);
  if (options.header) headers.set('x-clovyre-operator', options.header);
  return new NextRequest(url, { headers });
}

describe('operator console authentication', () => {
  beforeEach(() => configure(true));

  it('is entirely absent when no credential is configured', () => {
    configure(false);

    expect(getConfig().adminEnabled).toBe(false);
    expect(verifyAdminToken(TOKEN)).toBe(false);
    expect(authenticateAdmin(requestWith({ query: TOKEN }), '1.2.3.4')).toEqual({
      ok: false,
      reason: 'disabled',
    });
  });

  it('accepts the configured credential and rejects anything else', () => {
    expect(verifyAdminToken(TOKEN)).toBe(true);
    expect(verifyAdminToken(`${TOKEN}x`)).toBe(false);
    expect(verifyAdminToken(TOKEN.slice(0, -1))).toBe(false);
    expect(verifyAdminToken('')).toBe(false);
    expect(verifyAdminToken(null)).toBe(false);
  });

  it('issues a cookie when authenticated by the secret', () => {
    const result = authenticateAdmin(requestWith({ query: TOKEN }), '1.2.3.4');
    expect(result).toEqual({ ok: true, issueCookie: true });
  });

  it('accepts the secret through a header as well as the query string', () => {
    expect(authenticateAdmin(requestWith({ header: TOKEN }), '1.2.3.4').ok).toBe(true);
  });

  it('accepts a valid cookie without re-presenting the secret', () => {
    const cookie = issueAdminCookieValue();
    expect(verifyAdminCookie(cookie.value)).toBe(true);

    const result = authenticateAdmin(requestWith({ cookie: cookie.value }), '1.2.3.4');
    expect(result).toEqual({ ok: true });
  });

  it('rejects a tampered or forged cookie', () => {
    const cookie = issueAdminCookieValue();
    const [expiry, mac] = cookie.value.split('.');

    expect(verifyAdminCookie(`${expiry}.${'0'.repeat(mac!.length)}`)).toBe(false);
    // Extending the expiry must invalidate the signature.
    expect(verifyAdminCookie(`${Number(expiry) + 60_000}.${mac}`)).toBe(false);
    expect(verifyAdminCookie('not-a-cookie')).toBe(false);
    expect(verifyAdminCookie('')).toBe(false);
  });

  it('rejects an expired cookie', () => {
    const past = Date.now() - 1000;
    // Any value whose embedded expiry has passed fails before the MAC is checked.
    expect(verifyAdminCookie(`${past}.${'a'.repeat(64)}`)).toBe(false);
  });

  it('rejects a cookie once the credential is removed from the deployment', () => {
    const cookie = issueAdminCookieValue();
    expect(verifyAdminCookie(cookie.value)).toBe(true);

    configure(false);
    expect(verifyAdminCookie(cookie.value)).toBe(false);
  });

  it('rate limits guesses per address', () => {
    const address = '9.9.9.9';
    let lastReason: string | undefined;

    for (let attempt = 0; attempt < 20; attempt += 1) {
      const result = authenticateAdmin(requestWith({ query: 'wrong-guess' }), address);
      if (!result.ok) lastReason = result.reason;
    }
    expect(lastReason).toBe('rate_limited');

    // A different address is unaffected by another's exhausted budget.
    const other = authenticateAdmin(requestWith({ query: TOKEN }), '8.8.8.8');
    expect(other.ok).toBe(true);
  });

  it('does not spend rate-limit budget on a valid cookie', () => {
    const address = '7.7.7.7';
    const cookie = issueAdminCookieValue();
    for (let attempt = 0; attempt < 50; attempt += 1) {
      expect(authenticateAdmin(requestWith({ cookie: cookie.value }), address).ok).toBe(true);
    }
  });
});

describe('operator overview', () => {
  beforeEach(() => {
    configure(true);
    getSessionStore().clear();
  });

  it('reports counts measured from live state', () => {
    const store = getSessionStore();
    store.create();
    store.create();

    const overview = buildAdminOverview();
    expect(overview.totals.activeSessions).toBe(2);
    expect(overview.totals.robloxConnected).toBe(0);
    expect(overview.rows).toHaveLength(2);
  });

  it('surfaces the Roblox account and the connected agent', () => {
    const store = getSessionStore();
    const { session } = store.create();

    store.updateMetadata(session, {
      placeId: 42,
      jobId: 'job',
      gameName: 'Test Place',
      executor: 'SomeExecutor 2.0',
      localPlayer: { name: 'Builderman', displayName: 'Builder', userId: 156, accountAge: 6000 },
    });
    session.mcpConnections.set('conn-1', {
      connectionId: 'conn-1',
      connectedAt: Date.now(),
      lastSeenAt: Date.now(),
      clientName: 'claude-ai',
      clientVersion: '1.4.0',
      protocolVersion: '2025-06-18',
    });

    const row = buildAdminOverview().rows.find((entry) => entry.sessionId === session.id)!;

    expect(row.account).toEqual({
      username: 'Builderman',
      displayName: 'Builder',
      userId: 156,
      accountAge: 6000,
    });
    expect(row.executor).toBe('SomeExecutor 2.0');
    expect(row.agents).toHaveLength(1);
    expect(row.agents[0]!.client).toBe('claude-ai');
    expect(row.agents[0]!.version).toBe('1.4.0');
  });

  it('never exposes credentials, audit events or command contents', () => {
    const store = getSessionStore();
    const { session, secrets } = store.create();
    session.commandOrder.push('cmd_x');
    session.commands.set('cmd_x', {
      id: 'cmd_x',
      clientId: 'rc_test',
      tool: 'clovyre_inspect_instance',
      startedAt: Date.now(),
      timeoutMs: 1000,
      origin: 'mcp',
      status: 'succeeded',
      finishedAt: Date.now(),
      durationMs: 5,
      argumentsPreview: 'a private path the operator must not see',
      resultPreview: 'private result contents',
      errorCode: null,
      errorMessage: null,
    });

    const serialised = JSON.stringify(buildAdminOverview());

    for (const secret of [secrets.robloxToken, secrets.mcpToken, secrets.ownerToken]) {
      expect(serialised).not.toContain(secret);
    }
    expect(serialised).not.toContain(session.credentials.roblox.fingerprint);
    expect(serialised).not.toContain('a private path the operator must not see');
    expect(serialised).not.toContain('private result contents');
    expect(serialised).not.toContain('clovyre_inspect_instance');
    expect(serialised).not.toContain('session_created');
  });

  it('omits sessions that are no longer active', () => {
    const store = getSessionStore();
    const { session } = store.create();
    store.terminate(session, 'done', 'owner');

    expect(buildAdminOverview().rows).toHaveLength(0);
  });
});
