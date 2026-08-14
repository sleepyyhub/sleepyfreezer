import { WebSocket } from 'ws';
import {
  PROTOCOL_VERSION,
  type CapabilityMap,
  type ClientMetadata,
} from '../../src/lib/protocol/messages';

/**
 * Mock Roblox client for integration tests.
 *
 * Speaks the real protocol over a real WebSocket so the gateway is exercised
 * end to end. It can advertise arbitrary capabilities, answer commands, stall to
 * force a timeout, and emit malformed frames.
 */

export type CommandResponder = (command: {
  id: string;
  tool: string;
  arguments: Record<string, unknown>;
}) =>
  | { kind: 'ok'; result: unknown }
  | { kind: 'error'; code: string; message: string }
  | { kind: 'stall' }
  | { kind: 'malformed' }
  | Promise<
      | { kind: 'ok'; result: unknown }
      | { kind: 'error'; code: string; message: string }
      | { kind: 'stall' }
      | { kind: 'malformed' }
    >;

export interface MockClientOptions {
  url: string;
  sessionId: string;
  token: string;
  capabilities?: CapabilityMap;
  metadata?: ClientMetadata;
  respond?: CommandResponder;
  /** Skip the hello frame entirely, to test the handshake timeout. */
  skipHello?: boolean;
  /**
   * Stable per-executor identity. Two mock clients sharing a key stand for one
   * person re-running the script; different keys stand for two people.
   */
  clientKey?: string;
}

export class MockRobloxClient {
  private socket: WebSocket | null = null;
  readonly received: Array<Record<string, unknown>> = [];
  private helloAck: ((value: Record<string, unknown>) => void) | null = null;
  private errorFrame: ((value: Record<string, unknown>) => void) | null = null;

  constructor(private readonly options: MockClientOptions) {}

  /** Connects and resolves with the hello_ack (or rejects on an error frame). */
  async connect(timeoutMs = 5000): Promise<Record<string, unknown>> {
    const socket = new WebSocket(this.options.url);
    this.socket = socket;

    const settled = new Promise<Record<string, unknown>>((resolve, reject) => {
      const timer = setTimeout(
        () => reject(new Error('mock client handshake timed out')),
        timeoutMs,
      );
      this.helloAck = (value) => {
        clearTimeout(timer);
        resolve(value);
      };
      this.errorFrame = (value) => {
        clearTimeout(timer);
        reject(new Error(String(value.message ?? value.code ?? 'gateway rejected the client')));
      };
      socket.on('error', (error) => {
        clearTimeout(timer);
        reject(error);
      });
      socket.on('close', (code, reason) => {
        clearTimeout(timer);
        reject(new Error(`socket closed (${code}) ${reason.toString()}`));
      });
    });

    socket.on('open', () => {
      if (this.options.skipHello) return;
      this.send({
        protocolVersion: PROTOCOL_VERSION,
        type: 'hello',
        sessionId: this.options.sessionId,
        token: this.options.token,
        capabilities: this.options.capabilities ?? { websocket: true },
        metadata: this.options.metadata ?? {
          placeId: 1818,
          universeId: 9090,
          jobId: 'mock-job-id',
          localPlayer: { name: 'MockPlayer', displayName: 'Mock', userId: 42, accountAge: 365 },
          executor: 'MockExecutor 1.0',
        },
        bridgeVersion: 'mock-0.1.0',
        ...(this.options.clientKey === undefined ? {} : { clientKey: this.options.clientKey }),
      });
    });

    socket.on('message', (data) => {
      let message: Record<string, unknown>;
      try {
        message = JSON.parse(data.toString('utf8'));
      } catch {
        return;
      }
      this.received.push(message);

      if (message.type === 'hello_ack') {
        this.helloAck?.(message);
        return;
      }
      if (message.type === 'error') {
        this.errorFrame?.(message);
        return;
      }
      if (message.type === 'command') {
        void this.answer(message);
      }
    });

    return settled;
  }

  private async answer(message: Record<string, unknown>): Promise<void> {
    const responder = this.options.respond;
    const command = {
      id: String(message.id),
      tool: String(message.tool),
      arguments: (message.arguments ?? {}) as Record<string, unknown>,
    };

    const outcome = responder
      ? await responder(command)
      : ({ kind: 'ok', result: { echoed: command.tool } } as const);

    if (outcome.kind === 'stall') return;

    if (outcome.kind === 'malformed') {
      this.socket?.send('{ this is not json');
      return;
    }

    if (outcome.kind === 'ok') {
      this.send({
        protocolVersion: PROTOCOL_VERSION,
        type: 'result',
        id: command.id,
        ok: true,
        result: outcome.result,
        durationMs: 1,
      });
      return;
    }

    this.send({
      protocolVersion: PROTOCOL_VERSION,
      type: 'result',
      id: command.id,
      ok: false,
      error: { code: outcome.code, message: outcome.message },
      durationMs: 1,
    });
  }

  send(payload: unknown): void {
    this.socket?.send(JSON.stringify(payload));
  }

  sendRaw(text: string): void {
    this.socket?.send(text);
  }

  updateCapabilities(capabilities: CapabilityMap): void {
    this.send({ protocolVersion: PROTOCOL_VERSION, type: 'capabilities_update', capabilities });
  }

  heartbeat(): void {
    this.send({ protocolVersion: PROTOCOL_VERSION, type: 'heartbeat', sentAt: Date.now() });
  }

  /** Waits until a frame satisfying the predicate arrives, or times out. */
  async waitFor(
    predicate: (message: Record<string, unknown>) => boolean,
    timeoutMs = 3000,
  ): Promise<Record<string, unknown>> {
    const deadline = Date.now() + timeoutMs;
    for (;;) {
      const found = this.received.find(predicate);
      if (found) return found;
      if (Date.now() > deadline) throw new Error('timed out waiting for a frame');
      await new Promise((resolve) => setTimeout(resolve, 20));
    }
  }

  async close(): Promise<void> {
    if (!this.socket) return;
    const socket = this.socket;
    this.socket = null;
    // Silence the rejection handlers installed during connect().
    this.helloAck = null;
    this.errorFrame = null;
    await new Promise<void>((resolve) => {
      socket.once('close', () => resolve());
      socket.close();
      setTimeout(resolve, 500);
    });
  }

  get isOpen(): boolean {
    return this.socket?.readyState === WebSocket.OPEN;
  }
}
