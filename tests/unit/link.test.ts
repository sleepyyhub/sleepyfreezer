import { beforeEach, describe, expect, it } from 'vitest';
import { resetConfigForTests } from '../../src/lib/config';
import {
  agentLinkTokenFor,
  createAgentLink,
  linkFingerprint,
  verifyAgentLink,
} from '../../src/lib/sessions/link';
import { SessionStore } from '../../src/lib/sessions/store';

function configure(hashSecret = 'link-test-token-hash-secret-0123456789'): void {
  resetConfigForTests();
  process.env.SESSION_SECRET = 'link-test-session-secret-0123456789';
  process.env.TOKEN_HASH_SECRET = hashSecret;
}

describe('agent links', () => {
  beforeEach(() => configure());

  it('round-trips a freshly minted link', () => {
    const link = createAgentLink();
    expect(link.token.startsWith('clk_')).toBe(true);
    expect(verifyAgentLink(link.token)).toBe(link.ownerId);
  });

  it('is stateless: the same token verifies after a process restart', () => {
    const link = createAgentLink();
    // A restart loses every in-memory map but keeps the configured secret.
    resetConfigForTests();
    configure();
    expect(verifyAgentLink(link.token)).toBe(link.ownerId);
  });

  it('rebuilds an identical token from a stored owner id', () => {
    const link = createAgentLink();
    expect(agentLinkTokenFor(link.ownerId)).toBe(link.token);
  });

  it('rejects tampering with the owner id or the signature', () => {
    const link = createAgentLink();
    const [body, mac] = link.token.slice(4).split('.');

    expect(verifyAgentLink(`clk_${body}x.${mac}`)).toBeNull();
    expect(verifyAgentLink(`clk_${body}.${mac!.slice(0, -1)}a`)).toBeNull();
    expect(verifyAgentLink(`clk_${body}`)).toBeNull();
    expect(verifyAgentLink('clk_')).toBeNull();
    expect(verifyAgentLink('not-a-link')).toBeNull();
    expect(verifyAgentLink(null)).toBeNull();
  });

  it('stops verifying when the signing secret changes', () => {
    const link = createAgentLink();
    configure('a-completely-different-secret-0123456789');
    expect(verifyAgentLink(link.token)).toBeNull();
  });

  it('mints distinct links each time', () => {
    const tokens = new Set(Array.from({ length: 200 }, () => createAgentLink().token));
    expect(tokens.size).toBe(200);
  });

  it('fingerprints without revealing the owner id', () => {
    const link = createAgentLink();
    const print = linkFingerprint(link.ownerId);
    expect(print).toHaveLength(12);
    expect(link.token).not.toContain(print);
  });
});

describe('link resolution', () => {
  let store: SessionStore;

  beforeEach(() => {
    configure();
    store = new SessionStore();
  });

  it('resolves to the session bound to the link', () => {
    const link = createAgentLink();
    const { session } = store.create({ ownerLinkId: link.ownerId });

    expect(store.findActiveByLink(link.ownerId)?.id).toBe(session.id);
  });

  it('follows the newest session, so a new one takes over the same URL', () => {
    const link = createAgentLink();
    const first = store.create({ ownerLinkId: link.ownerId });
    const second = store.create({ ownerLinkId: link.ownerId });

    // This is the whole point: reconfiguring the agent is never required.
    // Sessions created in the same millisecond must still order deterministically.
    expect(second.session.createdAt).toBeGreaterThanOrEqual(first.session.createdAt);
    expect(second.session.sequence).toBeGreaterThan(first.session.sequence);
    expect(store.findActiveByLink(link.ownerId)?.id).toBe(second.session.id);
  });

  it('never resolves to another owner’s session', () => {
    const mine = createAgentLink();
    const theirs = createAgentLink();
    store.create({ ownerLinkId: theirs.ownerId });

    expect(store.findActiveByLink(mine.ownerId)).toBeNull();
  });

  it('ignores sessions that are no longer active', () => {
    const link = createAgentLink();
    const { session } = store.create({ ownerLinkId: link.ownerId });
    store.terminate(session, 'done', 'owner');

    expect(store.findActiveByLink(link.ownerId)).toBeNull();
  });

  it('falls back to an earlier session when the newest one ends', () => {
    const link = createAgentLink();
    const first = store.create({ ownerLinkId: link.ownerId });
    const second = store.create({ ownerLinkId: link.ownerId });

    store.terminate(second.session, 'done', 'owner');
    expect(store.findActiveByLink(link.ownerId)?.id).toBe(first.session.id);
  });

  it('ignores sessions created without a link', () => {
    const link = createAgentLink();
    store.create();
    expect(store.findActiveByLink(link.ownerId)).toBeNull();
  });
});
