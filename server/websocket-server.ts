import type { IncomingMessage, Server as HttpServer } from 'node:http';
import type { Duplex } from 'node:stream';
import { WebSocketServer, type WebSocket } from 'ws';
import { getConfig } from '../src/lib/config';
import {
  ErrorCodes,
  PROTOCOL_VERSION,
  parseClientMessage,
  type HelloMessage,
  type ServerMessage,
} from '../src/lib/protocol/messages';
import { getSessionBroker, type RobloxTransport } from '../src/lib/sessions/broker';
import { getSessionStore, hashAddress } from '../src/lib/sessions/store';
import { sessionStatus, type SessionRecord } from '../src/lib/sessions/types';
import { getRateLimiter } from '../src/lib/security/rate-limit';
import { normalizeIncoming } from '../src/lib/serialization/roblox-value';
import { generateEventId } from '../src/lib/security/tokens';
import { abbreviate } from '../src/lib/security/redact';

/**
 * Roblox WebSocket gateway.
 *
 * Executor WebSocket APIs cannot set request headers, so authentication happens in
 * the first application-level frame (`hello`) rather than during the HTTP upgrade.
 * A connection that does not authenticate within HELLO_TIMEOUT_MS is dropped, and
 * nothing but `hello` is accepted before that point.
 */

export const ROBLOX_WS_PATH = '/ws/roblox';

const HELLO_TIMEOUT_MS = 10_000;
const HEARTBEAT_INTERVAL_MS = 20_000;
/** Two missed heartbeats plus slack before we consider the client gone. */
const HEARTBEAT_GRACE_MS = HEARTBEAT_INTERVAL_MS * 3;

interface ConnectionState {
  readonly id: string;
  readonly socket: WebSocket;
  readonly remoteAddressHash: string;
  sessionId: string | null;
  helloTimer: NodeJS.Timeout | null;
  closed: boolean;
}

function send(socket: WebSocket, message: ServerMessage): void {
  if (socket.readyState !== socket.OPEN) return;
  socket.send(JSON.stringify(message));
}

function sendError(socket: WebSocket, code: string, message: string): void {
  send(socket, { protocolVersion: PROTOCOL_VERSION, type: 'error', code, message });
}

function clientAddress(request: IncomingMessage): string | null {
  const forwarded = request.headers['x-forwarded-for'];
  if (typeof forwarded === 'string' && forwarded.length > 0) {
    return forwarded.split(',')[0]!.trim();
  }
  return request.socket.remoteAddress ?? null;
}

export interface GatewayHandle {
  readonly wss: WebSocketServer;
  close(): Promise<void>;
}

export function createRobloxGateway(server: HttpServer): GatewayHandle {
  const config = getConfig();
  const store = getSessionStore();
  const broker = getSessionBroker();
  const limiter = getRateLimiter();

  const wss = new WebSocketServer({
    noServer: true,
    maxPayload: config.maxWsPayloadBytes,
    // Roblox executor sockets do not negotiate compression reliably.
    perMessageDeflate: false,
  });

  const connections = new Set<ConnectionState>();

  server.on('upgrade', (request: IncomingMessage, socket: Duplex, head: Buffer) => {
    const { pathname } = new URL(request.url ?? '/', 'http://placeholder');
    if (pathname !== ROBLOX_WS_PATH) {
      // Next.js owns HMR upgrades in development; leave anything else alone.
      return;
    }

    const address = clientAddress(request);
    const rate = limiter.check('ws_handshake', address ?? 'unknown');
    if (!rate.allowed) {
      socket.write('HTTP/1.1 429 Too Many Requests\r\nConnection: close\r\n\r\n');
      socket.destroy();
      return;
    }

    wss.handleUpgrade(request, socket, head, (ws) => {
      wss.emit('connection', ws, request);
    });
  });

  wss.on('connection', (socket: WebSocket, request: IncomingMessage) => {
    const state: ConnectionState = {
      id: generateEventId(),
      socket,
      remoteAddressHash: hashAddress(clientAddress(request)),
      sessionId: null,
      helloTimer: null,
      closed: false,
    };
    connections.add(state);

    state.helloTimer = setTimeout(() => {
      sendError(socket, ErrorCodes.UNAUTHORIZED, 'No hello frame was received in time.');
      socket.close(4001, 'hello timeout');
    }, HELLO_TIMEOUT_MS);
    state.helloTimer.unref?.();

    socket.on('message', (data, isBinary) => {
      if (isBinary) {
        sendError(socket, ErrorCodes.INVALID_MESSAGE, 'Clovyre frames must be UTF-8 JSON text.');
        return;
      }
      const raw = data.toString('utf8');
      if (raw.length > config.maxWsPayloadBytes) {
        sendError(socket, ErrorCodes.PAYLOAD_TOO_LARGE, 'Frame exceeds the payload limit.');
        socket.close(1009, 'payload too large');
        return;
      }
      handleFrame(state, raw);
    });

    socket.on('close', () => teardown(state, 'socket closed'));
    socket.on('error', () => teardown(state, 'socket error'));
  });

  function resolveSession(state: ConnectionState): SessionRecord | null {
    if (!state.sessionId) return null;
    return store.get(state.sessionId);
  }

  function handleFrame(state: ConnectionState, raw: string): void {
    const parsed = parseClientMessage(raw);
    if (!parsed.ok) {
      const session = resolveSession(state);
      session?.audit.record({
        kind: 'protocol_violation',
        actor: 'roblox',
        severity: 'warn',
        message: `Rejected a frame: ${parsed.message}`,
      });
      sendError(state.socket, parsed.code, parsed.message);
      return;
    }

    const message = parsed.message;

    if (message.type === 'hello') {
      handleHello(state, message);
      return;
    }

    if (!state.sessionId) {
      sendError(state.socket, ErrorCodes.UNAUTHORIZED, 'Send a hello frame before anything else.');
      state.socket.close(4001, 'unauthenticated');
      return;
    }

    const session = resolveSession(state);
    if (!session) {
      sendError(state.socket, ErrorCodes.SESSION_NOT_FOUND, 'This session no longer exists.');
      state.socket.close(4404, 'session gone');
      return;
    }

    const status = sessionStatus(session);
    if (status !== 'active') {
      send(state.socket, {
        protocolVersion: PROTOCOL_VERSION,
        type: status === 'expired' ? 'session_expired' : 'session_revoked',
        ...(status === 'expired'
          ? { expiredAt: session.expiresAt }
          : { reason: session.terminationReason ?? 'Session terminated.' }),
      } as ServerMessage);
      state.socket.close(4003, `session ${status}`);
      return;
    }

    switch (message.type) {
      case 'heartbeat': {
        if (session.roblox) session.roblox.lastHeartbeatAt = Date.now();
        send(state.socket, {
          protocolVersion: PROTOCOL_VERSION,
          type: 'heartbeat_ack',
          serverTime: Date.now(),
        });
        break;
      }

      case 'result': {
        const { value, report } = normalizeIncoming(message.result);
        const resolved = broker.resolveResult(
          session.id,
          message.id,
          message.ok
            ? {
                ok: true,
                result: value,
                truncated: Boolean(message.truncated) || report.truncated,
                durationMs: message.durationMs ?? 0,
              }
            : {
                ok: false,
                error: message.error ?? {
                  code: ErrorCodes.INTERNAL_ERROR,
                  message: 'The client reported a failure without details.',
                },
                durationMs: message.durationMs ?? 0,
              },
        );
        if (!resolved) {
          // Late or duplicated results are dropped, never routed elsewhere.
          session.audit.record({
            kind: 'protocol_violation',
            actor: 'roblox',
            severity: 'warn',
            message: `Result for unknown or already-settled command ${message.id} was discarded.`,
          });
        }
        break;
      }

      case 'event': {
        session.audit.record({
          kind: 'client_event',
          actor: 'roblox',
          message: `Client event: ${message.event}`,
          detail: message.data,
        });
        break;
      }

      case 'log': {
        session.audit.record({
          kind: 'client_log',
          actor: 'roblox',
          severity:
            message.level === 'error' ? 'error' : message.level === 'warn' ? 'warn' : 'info',
          message: abbreviate(message.message, 400),
        });
        break;
      }

      case 'capabilities_update': {
        store.updateCapabilities(session, message.capabilities);
        session.audit.record({
          kind: 'capabilities_reported',
          actor: 'roblox',
          message: 'The client updated its capability matrix.',
          detail: message.capabilities,
        });
        break;
      }

      case 'goodbye': {
        session.audit.record({
          kind: 'roblox_disconnected',
          actor: 'roblox',
          message: `Client said goodbye: ${message.reason ?? 'no reason given'}`,
        });
        state.socket.close(1000, 'goodbye');
        break;
      }
    }
  }

  function handleHello(state: ConnectionState, message: HelloMessage): void {
    if (state.sessionId) {
      sendError(state.socket, ErrorCodes.INVALID_MESSAGE, 'This connection already said hello.');
      return;
    }

    const auth = store.authenticate(message.sessionId, 'roblox', message.token);
    if (!auth.ok) {
      const reasonText: Record<typeof auth.reason, string> = {
        session_not_found: 'Unknown session.',
        session_expired: 'This Clovyre session has expired.',
        session_terminated: 'This Clovyre session was terminated.',
        credential_revoked: 'The Roblox credential for this session was revoked.',
        invalid_credential: 'The Roblox credential is not valid for this session.',
      };
      const code =
        auth.reason === 'session_expired'
          ? ErrorCodes.SESSION_EXPIRED
          : auth.reason === 'session_not_found'
            ? ErrorCodes.SESSION_NOT_FOUND
            : ErrorCodes.UNAUTHORIZED;

      store.get(message.sessionId)?.audit.record({
        kind: 'roblox_rejected',
        actor: 'roblox',
        severity: 'warn',
        message: `A Roblox connection was rejected: ${auth.reason}.`,
        detail: { addressHash: state.remoteAddressHash },
      });

      sendError(state.socket, code, reasonText[auth.reason]);
      state.socket.close(4001, auth.reason);
      return;
    }

    const session = auth.session;
    if (state.helloTimer) {
      clearTimeout(state.helloTimer);
      state.helloTimer = null;
    }
    state.sessionId = session.id;

    const transport: RobloxTransport = {
      connectionId: state.id,
      send: (payload) => send(state.socket, payload),
      close: (code, reason) => {
        try {
          state.socket.close(code, reason.slice(0, 120));
        } catch {
          state.socket.terminate();
        }
      },
    };
    broker.attachRoblox(session.id, transport);

    session.roblox = {
      connectionId: state.id,
      connectedAt: Date.now(),
      lastHeartbeatAt: Date.now(),
      remoteAddressHash: state.remoteAddressHash,
      bridgeVersion: message.bridgeVersion ?? null,
    };
    store.updateCapabilities(session, message.capabilities);
    store.updateMetadata(session, message.metadata);

    session.audit.record({
      kind: 'roblox_connected',
      actor: 'roblox',
      message: `Roblox client connected${message.metadata.executor ? ` via ${message.metadata.executor}` : ''}.`,
      detail: {
        placeId: message.metadata.placeId,
        jobId: message.metadata.jobId,
        bridgeVersion: message.bridgeVersion,
        addressHash: state.remoteAddressHash,
      },
    });

    send(state.socket, {
      protocolVersion: PROTOCOL_VERSION,
      type: 'hello_ack',
      sessionId: session.id,
      heartbeatIntervalMs: HEARTBEAT_INTERVAL_MS,
      maxPayloadBytes: config.maxWsPayloadBytes,
      expiresAt: session.expiresAt,
      serverTime: Date.now(),
    });
  }

  function teardown(state: ConnectionState, reason: string): void {
    if (state.closed) return;
    state.closed = true;
    connections.delete(state);
    if (state.helloTimer) clearTimeout(state.helloTimer);

    if (!state.sessionId) return;
    const session = store.get(state.sessionId);
    if (session?.roblox?.connectionId === state.id) {
      session.roblox = null;
      session.audit.record({
        kind: 'roblox_disconnected',
        actor: 'roblox',
        message: `Roblox client disconnected (${reason}).`,
      });
    }
    broker.detachRoblox(state.sessionId, state.id);
  }

  /** Drops sessions whose client stopped sending heartbeats, and ends dead sessions. */
  const sweeper = setInterval(() => {
    const now = Date.now();
    for (const state of connections) {
      if (!state.sessionId) continue;
      const session = store.get(state.sessionId);
      if (!session) {
        state.socket.close(4404, 'session gone');
        continue;
      }
      const status = sessionStatus(session, now);
      if (status !== 'active') {
        broker.teardown(
          session.id,
          status === 'expired'
            ? {
                protocolVersion: PROTOCOL_VERSION,
                type: 'session_expired',
                expiredAt: session.expiresAt,
              }
            : {
                protocolVersion: PROTOCOL_VERSION,
                type: 'session_revoked',
                reason: session.terminationReason ?? 'Session terminated.',
              },
          4003,
          `session ${status}`,
        );
        continue;
      }
      if (session.roblox && now - session.roblox.lastHeartbeatAt > HEARTBEAT_GRACE_MS) {
        state.socket.close(4008, 'heartbeat timeout');
      }
    }
  }, HEARTBEAT_INTERVAL_MS);
  sweeper.unref?.();

  return {
    wss,
    close: () =>
      new Promise<void>((resolve) => {
        clearInterval(sweeper);
        for (const state of connections) {
          state.socket.close(1001, 'server shutting down');
        }
        wss.close(() => resolve());
      }),
  };
}
