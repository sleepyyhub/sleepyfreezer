import { createServer, type Server } from 'node:http';
import { afterAll, afterEach, beforeAll, describe, expect, it } from 'vitest';
import { createRobloxGateway, type GatewayHandle } from '../../server/websocket-server';
import { resetConfigForTests } from '../../src/lib/config';
import { PROTOCOL_VERSION } from '../../src/lib/protocol/messages';
import { getSessionBroker } from '../../src/lib/sessions/broker';
import { getSessionStore } from '../../src/lib/sessions/store';
import { invokeTool } from '../../src/lib/tools/invoke';
import { MockRobloxClient } from '../helpers/mock-roblox-client';

/**
 * End-to-end gateway tests.
 *
 * A real HTTP server, a real ws upgrade and the real broker — only the Roblox
 * client is a mock, because Roblox itself cannot run in CI.
 */

process.env.SESSION_SECRET = 'integration-session-secret-0123456789';
process.env.TOKEN_HASH_SECRET = 'integration-token-hash-secret-0123456789';
// Keep command timeouts short so the stall tests do not sit for 10 seconds.
process.env.MAX_COMMAND_TIMEOUT_MS = '1200';

let server: Server;
let gateway: GatewayHandle;
let wsUrl: string;
const clients: MockRobloxClient[] = [];

function track(client: MockRobloxClient): MockRobloxClient {
  clients.push(client);
  return client;
}

beforeAll(async () => {
  resetConfigForTests();
  server = createServer((_request, response) => {
    response.statusCode = 404;
    response.end();
  });
  gateway = createRobloxGateway(server);
  await new Promise<void>((resolve) => server.listen(0, '127.0.0.1', () => resolve()));
  const address = server.address();
  if (typeof address === 'object' && address !== null) {
    wsUrl = `ws://127.0.0.1:${address.port}/ws/roblox`;
  } else {
    throw new Error('the test server did not bind to a port');
  }
});

afterEach(async () => {
  await Promise.all(clients.splice(0).map((client) => client.close()));
});

afterAll(async () => {
  await gateway.close();
  await new Promise<void>((resolve) => server.close(() => resolve()));
});

function newSession() {
  return getSessionStore().create({ creatorAddress: '127.0.0.1' });
}

describe('handshake', () => {
  it('accepts a valid hello and acknowledges it', async () => {
    const { session, secrets } = newSession();
    const client = track(
      new MockRobloxClient({ url: wsUrl, sessionId: session.id, token: secrets.robloxToken }),
    );

    const ack = await client.connect();
    expect(ack.type).toBe('hello_ack');
    expect(ack.sessionId).toBe(session.id);
    expect(ack.heartbeatIntervalMs).toBeGreaterThan(0);

    expect(getSessionBroker().isConnected(session.id)).toBe(true);
    expect(session.metadata?.placeId).toBe(1818);
    expect(session.capabilities.websocket).toBe(true);
  });

  it('rejects an invalid Roblox token', async () => {
    const { session } = newSession();
    const client = track(
      new MockRobloxClient({ url: wsUrl, sessionId: session.id, token: 'crx_not_the_real_token' }),
    );

    await expect(client.connect()).rejects.toThrow(/not valid/i);
    expect(getSessionBroker().isConnected(session.id)).toBe(false);
  });

  it('rejects a token belonging to a different session', async () => {
    const first = newSession();
    const second = newSession();
    const client = track(
      new MockRobloxClient({
        url: wsUrl,
        sessionId: second.session.id,
        token: first.secrets.robloxToken,
      }),
    );

    await expect(client.connect()).rejects.toThrow(/not valid/i);
  });

  it('rejects a revoked Roblox credential', async () => {
    const { session, secrets } = newSession();
    getSessionStore().revokeCredential(session, 'roblox', 'owner');

    const client = track(
      new MockRobloxClient({ url: wsUrl, sessionId: session.id, token: secrets.robloxToken }),
    );
    await expect(client.connect()).rejects.toThrow(/revoked/i);
  });

  it('rejects an expired session', async () => {
    const { session, secrets } = newSession();
    session.expiresAt = Date.now() - 1000;

    const client = track(
      new MockRobloxClient({ url: wsUrl, sessionId: session.id, token: secrets.robloxToken }),
    );
    await expect(client.connect()).rejects.toThrow(/expired/i);
  });

  it('rejects an unknown session id', async () => {
    const client = track(
      new MockRobloxClient({
        url: wsUrl,
        sessionId: 'cs_AAAAAAAAAAAAAAAAAAAA',
        token: 'crx_whatever',
      }),
    );
    await expect(client.connect()).rejects.toThrow(/unknown session/i);
  });
});

describe('command routing', () => {
  it('routes a command to the client and returns its result', async () => {
    const { session, secrets } = newSession();
    const client = track(
      new MockRobloxClient({
        url: wsUrl,
        sessionId: session.id,
        token: secrets.robloxToken,
        respond: (command) => ({
          kind: 'ok',
          result: { tool: command.tool, echoed: command.arguments },
        }),
      }),
    );
    await client.connect();

    const outcome = await invokeTool(
      session,
      'clovyre_get_children',
      { ref: 'ref_1', limit: 10 },
      'mcp',
    );
    expect(outcome.ok).toBe(true);
    if (outcome.ok) {
      const data = outcome.data as { tool: string; echoed: Record<string, unknown> };
      expect(data.tool).toBe('clovyre_get_children');
      expect(data.echoed.ref).toBe('ref_1');
      expect(data.echoed.limit).toBe(10);
    }
  });

  it('propagates a structured client error', async () => {
    const { session, secrets } = newSession();
    const client = track(
      new MockRobloxClient({
        url: wsUrl,
        sessionId: session.id,
        token: secrets.robloxToken,
        respond: () => ({
          kind: 'error',
          code: 'INSTANCE_NOT_FOUND',
          message: 'The requested instance is unavailable.',
        }),
      }),
    );
    await client.connect();

    const outcome = await invokeTool(session, 'clovyre_inspect_instance', { ref: 'ref_9' }, 'mcp');
    expect(outcome.ok).toBe(false);
    if (!outcome.ok) expect(outcome.code).toBe('INSTANCE_NOT_FOUND');
  });

  it('times out when the client never answers, and asks it to cancel', async () => {
    const { session, secrets } = newSession();
    const client = track(
      new MockRobloxClient({
        url: wsUrl,
        sessionId: session.id,
        token: secrets.robloxToken,
        respond: () => ({ kind: 'stall' }),
      }),
    );
    await client.connect();

    const outcome = await invokeTool(session, 'clovyre_get_services', {}, 'mcp');
    expect(outcome.ok).toBe(false);
    if (!outcome.ok) expect(outcome.code).toBe('COMMAND_TIMEOUT');

    const cancel = await client.waitFor((message) => message.type === 'cancel_command');
    expect(cancel.type).toBe('cancel_command');
  });

  it('survives a malformed frame and reports the protocol violation', async () => {
    const { session, secrets } = newSession();
    const client = track(
      new MockRobloxClient({
        url: wsUrl,
        sessionId: session.id,
        token: secrets.robloxToken,
        respond: () => ({ kind: 'malformed' }),
      }),
    );
    await client.connect();

    const outcome = await invokeTool(session, 'clovyre_get_services', {}, 'mcp');
    expect(outcome.ok).toBe(false);

    await client.waitFor((message) => message.type === 'error');
    expect(session.audit.list().some((event) => event.kind === 'protocol_violation')).toBe(true);
    expect(getSessionBroker().isConnected(session.id)).toBe(true);
  });

  it('discards a result for a command that does not exist', async () => {
    const { session, secrets } = newSession();
    const client = track(
      new MockRobloxClient({ url: wsUrl, sessionId: session.id, token: secrets.robloxToken }),
    );
    await client.connect();

    client.send({
      protocolVersion: PROTOCOL_VERSION,
      type: 'result',
      id: 'cmd_does_not_exist',
      ok: true,
      result: { injected: true },
    });

    await new Promise((resolve) => setTimeout(resolve, 150));
    expect(session.audit.list().some((event) => event.message.includes('cmd_does_not_exist'))).toBe(
      true,
    );
  });

  it('cannot resolve a pending command belonging to another session', async () => {
    const first = newSession();
    const second = newSession();

    const firstClient = track(
      new MockRobloxClient({
        url: wsUrl,
        sessionId: first.session.id,
        token: first.secrets.robloxToken,
        respond: () => ({ kind: 'stall' }),
      }),
    );
    const secondClient = track(
      new MockRobloxClient({
        url: wsUrl,
        sessionId: second.session.id,
        token: second.secrets.robloxToken,
      }),
    );
    await firstClient.connect();
    await secondClient.connect();

    const pending = invokeTool(first.session, 'clovyre_get_services', {}, 'mcp');
    const command = await firstClient.waitFor((message) => message.type === 'command');

    // Session two answers session one's command id. It must be ignored.
    secondClient.send({
      protocolVersion: PROTOCOL_VERSION,
      type: 'result',
      id: String(command.id),
      ok: true,
      result: { hijacked: true },
    });

    const outcome = await pending;
    expect(outcome.ok).toBe(false);
    if (!outcome.ok) expect(outcome.code).toBe('COMMAND_TIMEOUT');
  });

  it('fails pending commands when the client disconnects', async () => {
    const { session, secrets } = newSession();
    const client = track(
      new MockRobloxClient({
        url: wsUrl,
        sessionId: session.id,
        token: secrets.robloxToken,
        respond: () => ({ kind: 'stall' }),
      }),
    );
    await client.connect();

    const pending = invokeTool(session, 'clovyre_get_services', {}, 'mcp');
    await client.waitFor((message) => message.type === 'command');
    await client.close();

    const outcome = await pending;
    expect(outcome.ok).toBe(false);
    if (!outcome.ok) expect(outcome.code).toBe('CLIENT_NOT_CONNECTED');
  });

  it('replaces the older connection when the same executor re-runs the script', async () => {
    const { session, secrets } = newSession();
    const shared = 'executor-key-same';
    const first = track(
      new MockRobloxClient({
        url: wsUrl,
        sessionId: session.id,
        token: secrets.robloxToken,
        clientKey: shared,
      }),
    );
    await first.connect();

    const second = track(
      new MockRobloxClient({
        url: wsUrl,
        sessionId: session.id,
        token: secrets.robloxToken,
        clientKey: shared,
      }),
    );
    await second.connect();

    await new Promise((resolve) => setTimeout(resolve, 200));
    // One executor, one slot: two sockets for it would double-answer commands.
    expect(first.isOpen).toBe(false);
    expect(second.isOpen).toBe(true);
    expect(session.robloxClients.size).toBe(1);
  });

  it('keeps both clients when two people run the same script', async () => {
    const { session, secrets } = newSession();
    const alice = track(
      new MockRobloxClient({
        url: wsUrl,
        sessionId: session.id,
        token: secrets.robloxToken,
        clientKey: 'executor-key-alice',
        metadata: {
          placeId: 1,
          localPlayer: { name: 'Alice', userId: 1 },
          executor: 'ExecutorA',
        },
      }),
    );
    const aliceAck = await alice.connect();

    const bob = track(
      new MockRobloxClient({
        url: wsUrl,
        sessionId: session.id,
        token: secrets.robloxToken,
        clientKey: 'executor-key-bob',
        metadata: {
          placeId: 1,
          localPlayer: { name: 'Bob', userId: 2 },
          executor: 'ExecutorB',
        },
      }),
    );
    const bobAck = await bob.connect();

    await new Promise((resolve) => setTimeout(resolve, 200));

    // Neither evicts the other, and each is told which client it is.
    expect(alice.isOpen).toBe(true);
    expect(bob.isOpen).toBe(true);
    expect(session.robloxClients.size).toBe(2);
    expect(aliceAck.clientId).not.toBe(bobAck.clientId);
    expect(aliceAck.clientLabel).toBe('Alice');
    expect(bobAck.clientLabel).toBe('Bob');
  });

  it('refuses to guess which client a tool call is for, and names both', async () => {
    const { session, secrets } = newSession();
    for (const [key, name] of [
      ['client-key-one', 'Alice'],
      ['client-key-two', 'Bob'],
    ] as const) {
      const client = track(
        new MockRobloxClient({
          url: wsUrl,
          sessionId: session.id,
          token: secrets.robloxToken,
          clientKey: key,
          metadata: { placeId: 1, localPlayer: { name, userId: 1 }, executor: 'Executor' },
          respond: () => ({ kind: 'ok', result: { ok: true } }),
        }),
      );
      await client.connect();
    }
    await new Promise((resolve) => setTimeout(resolve, 100));

    const ambiguous = await invokeTool(session, 'clovyre_get_services', {}, 'mcp');
    expect(ambiguous.ok).toBe(false);
    if (!ambiguous.ok) {
      expect(ambiguous.code).toBe('CLIENT_AMBIGUOUS');
      // The roster is what lets the agent ask a question a human can answer.
      const detail = ambiguous.detail as { clients: Array<{ label: string }> };
      expect(detail.clients.map((entry) => entry.label).sort()).toEqual(['Alice', 'Bob']);
    }

    // Naming one resolves it.
    const chosen = [...session.robloxClients.values()][0]!;
    const addressed = await invokeTool(
      session,
      'clovyre_get_services',
      { client: chosen.clientId },
      'mcp',
    );
    expect(addressed.ok).toBe(true);

    // A label works too, since that is what a human would say.
    const byLabel = await invokeTool(
      session,
      'clovyre_get_services',
      { client: chosen.label },
      'mcp',
    );
    expect(byLabel.ok).toBe(true);
  });

  it('fails a single-client call with no client argument only when none is attached', async () => {
    const { session, secrets } = newSession();
    const only = track(
      new MockRobloxClient({
        url: wsUrl,
        sessionId: session.id,
        token: secrets.robloxToken,
        clientKey: 'solo-executor-key',
        respond: () => ({ kind: 'ok', result: { services: [] } }),
      }),
    );
    await only.connect();
    await new Promise((resolve) => setTimeout(resolve, 100));

    // One client is unambiguous, so the call needs no addressing.
    const result = await invokeTool(session, 'clovyre_get_services', {}, 'mcp');
    expect(result.ok).toBe(true);
  });
});

describe('session lifecycle over the wire', () => {
  it('acknowledges heartbeats and records the liveness', async () => {
    const { session, secrets } = newSession();
    const client = track(
      new MockRobloxClient({ url: wsUrl, sessionId: session.id, token: secrets.robloxToken }),
    );
    await client.connect();

    client.heartbeat();
    const ack = await client.waitFor((message) => message.type === 'heartbeat_ack');
    expect(ack.serverTime).toBeTypeOf('number');
  });

  it('accepts a capability update and re-gates tools on it', async () => {
    const { session, secrets } = newSession();
    const client = track(
      new MockRobloxClient({ url: wsUrl, sessionId: session.id, token: secrets.robloxToken }),
    );
    await client.connect();

    const before = await invokeTool(session, 'clovyre_get_loaded_modules', {}, 'mcp');
    expect(before.ok).toBe(false);
    if (!before.ok) expect(before.code).toBe('CAPABILITY_UNAVAILABLE');

    client.updateCapabilities({ websocket: true, getloadedmodules: true });
    await new Promise((resolve) => setTimeout(resolve, 150));
    expect(session.capabilities.getloadedmodules).toBe(true);
  });

  it('tears down the socket when the session is terminated', async () => {
    const { session, secrets } = newSession();
    const client = track(
      new MockRobloxClient({ url: wsUrl, sessionId: session.id, token: secrets.robloxToken }),
    );
    await client.connect();

    getSessionStore().terminate(session, 'terminated in a test', 'owner');
    getSessionBroker().teardown(
      session.id,
      {
        protocolVersion: PROTOCOL_VERSION,
        type: 'session_revoked',
        reason: 'terminated in a test',
      },
      4003,
      'session terminated',
    );

    await new Promise((resolve) => setTimeout(resolve, 200));
    expect(getSessionBroker().isConnected(session.id)).toBe(false);
    expect(client.isOpen).toBe(false);
  });

  it('refuses commands once the session has expired', async () => {
    const { session, secrets } = newSession();
    const client = track(
      new MockRobloxClient({ url: wsUrl, sessionId: session.id, token: secrets.robloxToken }),
    );
    await client.connect();

    session.expiresAt = Date.now() - 1;
    const outcome = await invokeTool(session, 'clovyre_get_services', {}, 'mcp');
    expect(outcome.ok).toBe(false);
    if (!outcome.ok) expect(outcome.code).toBe('SESSION_EXPIRED');
  });

  it('accepts a regenerated Roblox credential and refuses the old one', async () => {
    const { session, secrets } = newSession();
    const replacement = getSessionStore().rotateCredential(session, 'roblox', 'owner');

    const stale = track(
      new MockRobloxClient({ url: wsUrl, sessionId: session.id, token: secrets.robloxToken }),
    );
    await expect(stale.connect()).rejects.toThrow(/not valid/i);

    const fresh = track(
      new MockRobloxClient({ url: wsUrl, sessionId: session.id, token: replacement }),
    );
    const ack = await fresh.connect();
    expect(ack.type).toBe('hello_ack');
  });

  it('leaves a live bridge connected when its credential is regenerated', async () => {
    const { session, secrets } = newSession();
    const client = track(
      new MockRobloxClient({
        url: wsUrl,
        sessionId: session.id,
        token: secrets.robloxToken,
        respond: () => ({ kind: 'ok', result: { still: 'here' } }),
      }),
    );
    await client.connect();

    getSessionStore().rotateCredential(session, 'roblox', 'owner');
    await new Promise((resolve) => setTimeout(resolve, 150));

    // Regenerating a credential must not knock a working bridge offline.
    expect(getSessionBroker().isConnected(session.id)).toBe(true);
    expect(client.isOpen).toBe(true);

    const outcome = await invokeTool(session, 'clovyre_ping', {}, 'mcp');
    expect(outcome.ok).toBe(true);
  });

  it('records an audited command history with redacted previews', async () => {
    const { session, secrets } = newSession();
    const client = track(
      new MockRobloxClient({
        url: wsUrl,
        sessionId: session.id,
        token: secrets.robloxToken,
        respond: () => ({ kind: 'ok', result: { ok: true } }),
      }),
    );
    await client.connect();

    await invokeTool(session, 'clovyre_ping', {}, 'mcp');

    const record = [...session.commands.values()].find((entry) => entry.tool === 'clovyre_ping');
    expect(record?.status).toBe('succeeded');
    expect(record?.durationMs).toBeGreaterThanOrEqual(0);

    const serialisedAudit = JSON.stringify(session.audit.list());
    expect(serialisedAudit).not.toContain(secrets.robloxToken);
    expect(serialisedAudit).not.toContain(secrets.mcpToken);
  });
});
