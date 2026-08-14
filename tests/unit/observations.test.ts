import { beforeEach, describe, expect, it } from 'vitest';
import { resetConfigForTests } from '../../src/lib/config';
import { ingestClientEvent, resetObservations } from '../../src/lib/sessions/observations';
import { getSessionStore } from '../../src/lib/sessions/store';
import { OBSERVATION_LIMITS, type SessionRecord } from '../../src/lib/sessions/types';
import { getWatchEvents, getRemoteCalls, listWatches } from '../../src/lib/mcp/local-tools';
import { listResources } from '../../src/lib/mcp/resources';

function freshSession(): SessionRecord {
  resetConfigForTests();
  process.env.SESSION_SECRET = 'obs-test-session-secret-0123456789';
  process.env.TOKEN_HASH_SECRET = 'obs-test-token-hash-secret-0123456789';
  const store = getSessionStore();
  store.clear();
  return store.create().session;
}

describe('watch event ingest', () => {
  let session: SessionRecord;
  beforeEach(() => {
    session = freshSession();
  });

  it('records a well-formed watch event', () => {
    const consumed = ingestClientEvent(session,'rc_test', 'watch', {
      watchId: 'w1',
      kind: 'property',
      target: 'Workspace.Part',
      detail: { property: 'Transparency', value: 0.5 },
    });

    expect(consumed).toBe(true);
    const view = getWatchEvents(session, { limit: 10 }) as { events: unknown[] };
    expect(view.events).toHaveLength(1);
  });

  it('rejects a malformed event without consuming it', () => {
    expect(ingestClientEvent(session,'rc_test', 'watch', { kind: 'property' })).toBe(false);
    expect(ingestClientEvent(session,'rc_test', 'watch', null)).toBe(false);
    expect(session.observations.watchEvents).toHaveLength(0);
  });

  it('ignores an unknown event so it falls through to the audit log', () => {
    expect(ingestClientEvent(session,'rc_test', 'something_else', { a: 1 })).toBe(false);
  });

  it('caps the buffer and counts what it dropped', () => {
    for (let index = 0; index < OBSERVATION_LIMITS.maxWatchEvents + 25; index += 1) {
      ingestClientEvent(session,'rc_test', 'watch', {
        watchId: 'w1',
        kind: 'property',
        target: 'Workspace.Part',
        detail: { index },
      });
    }

    expect(session.observations.watchEvents).toHaveLength(OBSERVATION_LIMITS.maxWatchEvents);
    expect(session.observations.droppedWatchEvents).toBe(25);
    const view = getWatchEvents(session, { limit: 5 }) as { dropped: number; note?: string };
    expect(view.dropped).toBe(25);
    expect(view.note).toContain('dropped');
  });

  it('re-bounds untrusted detail payloads', () => {
    ingestClientEvent(session,'rc_test', 'watch', {
      watchId: 'w1',
      kind: 'property',
      target: 'Workspace.Part',
      detail: { huge: 'x'.repeat(100_000) },
    });

    const serialised = JSON.stringify(session.observations.watchEvents[0]!.detail);
    expect(serialised.length).toBeLessThan(20_000);
    expect(serialised).toContain('truncated');
  });

  it('filters by watch id and by timestamp', () => {
    ingestClientEvent(session,'rc_test', 'watch', { watchId: 'a', kind: 'property', target: 't', at: 1000 });
    ingestClientEvent(session,'rc_test', 'watch', { watchId: 'b', kind: 'property', target: 't', at: 2000 });

    expect(
      (getWatchEvents(session, { limit: 10, watchId: 'a' }) as { events: unknown[] }).events,
    ).toHaveLength(1);
    expect(
      (getWatchEvents(session, { limit: 10, since: 1500 }) as { events: unknown[] }).events,
    ).toHaveLength(1);
  });

  it('clears the buffer on request', () => {
    ingestClientEvent(session,'rc_test', 'watch', { watchId: 'a', kind: 'property', target: 't' });
    getWatchEvents(session, { limit: 10, clear: true });
    expect(session.observations.watchEvents).toHaveLength(0);
  });

  it('tracks which watchers the client reports as installed', () => {
    ingestClientEvent(session,'rc_test', 'watch_state', {
      watches: [{ watchId: 'w1', target: 'Workspace.Part', kinds: ['property'] }],
    });

    const view = listWatches(session) as { count: number; active: Array<{ watchId: string }> };
    expect(view.count).toBe(1);
    expect(view.active[0]!.watchId).toBe('w1');
  });
});

describe('remote spy ingest', () => {
  let session: SessionRecord;
  beforeEach(() => {
    session = freshSession();
  });

  it('records an observed call with serialized arguments', () => {
    ingestClientEvent(session,'rc_test', 'remote_spy_state', { active: true });
    ingestClientEvent(session,'rc_test', 'remote_call', {
      remote: 'ReplicatedStorage.Remotes.BuyItem',
      className: 'RemoteEvent',
      method: 'FireServer',
      args: [{ itemId: 7 }],
      argCount: 1,
    });

    const view = getRemoteCalls(session, { limit: 10 }) as {
      spyActive: boolean;
      calls: Array<{ remote: string; method: string }>;
    };
    expect(view.spyActive).toBe(true);
    expect(view.calls[0]!.remote).toContain('BuyItem');
    expect(view.calls[0]!.method).toBe('FireServer');
  });

  it('filters by remote name and method', () => {
    for (const [remote, method] of [
      ['A.Buy', 'FireServer'],
      ['B.Sell', 'InvokeServer'],
    ] as const) {
      ingestClientEvent(session,'rc_test', 'remote_call', {
        remote,
        className: 'RemoteEvent',
        method,
        argCount: 0,
      });
    }

    expect(
      (getRemoteCalls(session, { limit: 10, remoteName: 'buy' }) as { calls: unknown[] }).calls,
    ).toHaveLength(1);
    expect(
      (getRemoteCalls(session, { limit: 10, method: 'InvokeServer' }) as { calls: unknown[] })
        .calls,
    ).toHaveLength(1);
  });

  it('caps the call buffer', () => {
    for (let index = 0; index < OBSERVATION_LIMITS.maxRemoteCalls + 10; index += 1) {
      ingestClientEvent(session,'rc_test', 'remote_call', {
        remote: 'R',
        className: 'RemoteEvent',
        method: 'FireServer',
        argCount: 0,
      });
    }
    expect(session.observations.remoteCalls).toHaveLength(OBSERVATION_LIMITS.maxRemoteCalls);
    expect(session.observations.droppedRemoteCalls).toBe(10);
  });

  it('says so when the spy is not running', () => {
    const view = getRemoteCalls(session, { limit: 10 }) as { note: string };
    expect(view.note).toContain('not running');
  });

  it('clears hook state when the client disconnects', () => {
    ingestClientEvent(session,'rc_test', 'remote_spy_state', { active: true });
    ingestClientEvent(session,'rc_test', 'watch_state', {
      watches: [{ watchId: 'w1', target: 't', kinds: ['property'] }],
    });

    resetObservations(session);

    expect(session.observations.remoteSpyActive).toBe(false);
    expect(session.observations.activeWatches.size).toBe(0);
    // Already-recorded observations survive; only the live hooks are gone.
    expect(session.observations.remoteCalls).toEqual([]);
  });
});

describe('MCP resources', () => {
  it('offers only client-independent resources while disconnected', () => {
    const session = freshSession();
    const uris = listResources(session).map((resource) => resource.uri);

    expect(uris).toContain('clovyre://session');
    expect(uris).toContain('clovyre://capabilities');
    expect(uris).not.toContain('clovyre://tree');
  });

  it('gives every resource a uri, title and mime type', () => {
    for (const resource of listResources(freshSession())) {
      expect(resource.uri.startsWith('clovyre://')).toBe(true);
      expect(resource.title.length).toBeGreaterThan(3);
      expect(resource.mimeType).toBe('application/json');
    }
  });
});
