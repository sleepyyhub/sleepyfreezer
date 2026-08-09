import { afterAll, beforeEach, describe, expect, it } from 'vitest';
import { resetConfigForTests } from '../../src/lib/config';
import { persistenceEnabled } from '../../src/lib/sessions/persistence';
import { SessionStore } from '../../src/lib/sessions/store';

/**
 * Persistence behaviour that does not need a database.
 *
 * The round trip through Postgres is verified against the real deployment; what
 * matters here is that the store degrades honestly when no database is
 * configured, rather than appearing to persist and silently losing sessions.
 */

function configure(databaseUrl?: string): void {
  resetConfigForTests();
  process.env.SESSION_SECRET = 'persist-test-session-secret-0123456789';
  process.env.TOKEN_HASH_SECRET = 'persist-test-token-hash-secret-0123456789';
  if (databaseUrl) {
    process.env.DATABASE_URL = databaseUrl;
  } else {
    delete process.env.DATABASE_URL;
  }
}

afterAll(() => {
  delete process.env.DATABASE_URL;
  resetConfigForTests();
});

describe('persistence configuration', () => {
  beforeEach(() => configure());

  it('reports persistence as unavailable when no database is configured', () => {
    expect(persistenceEnabled()).toBe(false);
  });

  it('still creates and authenticates sessions with no database', () => {
    const store = new SessionStore();
    const { session, secrets } = store.create();

    expect(store.authenticate(session.id, 'mcp', secrets.mcpToken).ok).toBe(true);
    expect(store.get(session.id)).not.toBeNull();
  });

  it('hydrates to nothing rather than failing when no database is configured', async () => {
    const store = new SessionStore();
    await expect(store.hydrate()).resolves.toBe(0);
  });

  it('keeps sequence numbers monotonic after a hydrate', async () => {
    const store = new SessionStore();
    await store.hydrate();

    const first = store.create().session;
    const second = store.create().session;
    expect(second.sequence).toBeGreaterThan(first.sequence);
  });
});
