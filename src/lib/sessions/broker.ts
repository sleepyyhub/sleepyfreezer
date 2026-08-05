import { getConfig } from '../config';
import {
  ErrorCodes,
  PROTOCOL_VERSION,
  type CommandError,
  type ServerMessage,
} from '../protocol/messages';
import { abbreviate } from '../security/redact';
import { generateCommandId } from '../security/tokens';
import type { CommandRecord, SessionRecord } from './types';
import { sessionStatus } from './types';

/**
 * Session broker: owns the live Roblox transport per session and the registry of
 * commands awaiting a result.
 *
 * A command is only ever resolved through the transport that owns its session, so
 * a result arriving on session A can never satisfy a pending command on session B.
 */

export interface RobloxTransport {
  readonly connectionId: string;
  send(message: ServerMessage): void;
  close(code: number, reason: string): void;
}

interface PendingCommand {
  readonly sessionId: string;
  readonly record: CommandRecord;
  readonly timer: NodeJS.Timeout;
  resolve(outcome: CommandOutcome): void;
}

export type CommandOutcome =
  | { ok: true; result: unknown; truncated: boolean; durationMs: number }
  | { ok: false; error: CommandError; durationMs: number };

const MAX_COMMAND_HISTORY = 200;
const MAX_CONCURRENT_COMMANDS = 16;

export class SessionBroker {
  private readonly transports = new Map<string, RobloxTransport>();
  private readonly pending = new Map<string, PendingCommand>();

  attachRoblox(sessionId: string, transport: RobloxTransport): void {
    const existing = this.transports.get(sessionId);
    if (existing && existing.connectionId !== transport.connectionId) {
      // A second live client would double-answer every command; the older one goes.
      existing.close(4004, 'Replaced by a newer Clovyre connection.');
    }
    this.transports.set(sessionId, transport);
  }

  detachRoblox(sessionId: string, connectionId: string): void {
    const existing = this.transports.get(sessionId);
    if (!existing || existing.connectionId !== connectionId) return;
    this.transports.delete(sessionId);
    this.failAllPending(sessionId, {
      code: ErrorCodes.CLIENT_NOT_CONNECTED,
      message: 'The Roblox client disconnected before the command completed.',
    });
  }

  isConnected(sessionId: string): boolean {
    return this.transports.has(sessionId);
  }

  getTransport(sessionId: string): RobloxTransport | null {
    return this.transports.get(sessionId) ?? null;
  }

  /** Pushes a control frame to the client without expecting a result. */
  notify(sessionId: string, message: ServerMessage): boolean {
    const transport = this.transports.get(sessionId);
    if (!transport) return false;
    transport.send(message);
    return true;
  }

  countPending(sessionId: string): number {
    let count = 0;
    for (const entry of this.pending.values()) {
      if (entry.sessionId === sessionId) count += 1;
    }
    return count;
  }

  /**
   * Dispatches a tool invocation and resolves when the client answers, the
   * command times out, or the session ends. Never rejects.
   */
  async dispatch(
    session: SessionRecord,
    input: {
      tool: string;
      arguments: Record<string, unknown>;
      timeoutMs?: number;
      origin: CommandRecord['origin'];
    },
  ): Promise<{ commandId: string; outcome: CommandOutcome }> {
    const config = getConfig();
    const commandId = generateCommandId();
    const startedAt = Date.now();
    const timeoutMs = Math.min(
      Math.max(input.timeoutMs ?? 15_000, 250),
      config.maxCommandTimeoutMs,
    );

    const record: CommandRecord = {
      id: commandId,
      tool: input.tool,
      startedAt,
      timeoutMs,
      origin: input.origin,
      status: 'pending',
      finishedAt: null,
      durationMs: null,
      argumentsPreview: abbreviate(input.arguments, 300),
      resultPreview: null,
      errorCode: null,
      errorMessage: null,
    };
    this.remember(session, record);

    session.audit.record({
      kind: 'tool_called',
      actor: input.origin === 'mcp' ? 'mcp' : 'owner',
      message: `${input.tool} dispatched (${commandId}).`,
      detail: { arguments: input.arguments },
    });

    const fail = (error: CommandError): { commandId: string; outcome: CommandOutcome } => {
      const outcome: CommandOutcome = { ok: false, error, durationMs: Date.now() - startedAt };
      this.finalize(session, record, outcome);
      return { commandId, outcome };
    };

    const status = sessionStatus(session);
    if (status !== 'active') {
      return fail({
        code: status === 'expired' ? ErrorCodes.SESSION_EXPIRED : ErrorCodes.SESSION_REVOKED,
        message:
          status === 'expired'
            ? 'This Clovyre session has expired.'
            : 'This Clovyre session was terminated.',
      });
    }

    const transport = this.transports.get(session.id);
    if (!transport) {
      return fail({
        code: ErrorCodes.CLIENT_NOT_CONNECTED,
        message: 'No Roblox client is connected to this Clovyre session.',
      });
    }

    if (this.countPending(session.id) >= MAX_CONCURRENT_COMMANDS) {
      return fail({
        code: ErrorCodes.RATE_LIMITED,
        message: `At most ${MAX_CONCURRENT_COMMANDS} commands may be in flight per session.`,
      });
    }

    const outcome = await new Promise<CommandOutcome>((resolve) => {
      const timer = setTimeout(() => {
        this.pending.delete(commandId);
        transport.send({
          protocolVersion: PROTOCOL_VERSION,
          type: 'cancel_command',
          id: commandId,
        });
        resolve({
          ok: false,
          error: {
            code: ErrorCodes.COMMAND_TIMEOUT,
            message: `The Roblox client did not answer within ${timeoutMs} ms.`,
          },
          durationMs: Date.now() - startedAt,
        });
      }, timeoutMs);
      timer.unref?.();

      this.pending.set(commandId, { sessionId: session.id, record, timer, resolve });

      try {
        transport.send({
          protocolVersion: PROTOCOL_VERSION,
          type: 'command',
          id: commandId,
          tool: input.tool,
          arguments: input.arguments,
          timeoutMs,
        });
      } catch (error) {
        clearTimeout(timer);
        this.pending.delete(commandId);
        resolve({
          ok: false,
          error: {
            code: ErrorCodes.INTERNAL_ERROR,
            message: `Failed to reach the Roblox client: ${
              error instanceof Error ? error.message : 'unknown transport error'
            }`,
          },
          durationMs: Date.now() - startedAt,
        });
      }
    });

    this.finalize(session, record, outcome);
    return { commandId, outcome };
  }

  /** Called by the gateway when a `result` frame arrives. */
  resolveResult(sessionId: string, commandId: string, outcome: CommandOutcome): boolean {
    const entry = this.pending.get(commandId);
    // Guarding on sessionId is what prevents cross-session result injection.
    if (!entry || entry.sessionId !== sessionId) return false;
    clearTimeout(entry.timer);
    this.pending.delete(commandId);
    entry.resolve(outcome);
    return true;
  }

  /** Owner- or agent-initiated cancellation of an in-flight command. */
  cancel(sessionId: string, commandId: string): boolean {
    const entry = this.pending.get(commandId);
    if (!entry || entry.sessionId !== sessionId) return false;
    clearTimeout(entry.timer);
    this.pending.delete(commandId);
    this.transports.get(sessionId)?.send({
      protocolVersion: PROTOCOL_VERSION,
      type: 'cancel_command',
      id: commandId,
    });
    entry.resolve({
      ok: false,
      error: { code: ErrorCodes.COMMAND_CANCELLED, message: 'The command was cancelled.' },
      durationMs: Date.now() - entry.record.startedAt,
    });
    return true;
  }

  failAllPending(sessionId: string, error: CommandError): void {
    for (const [commandId, entry] of this.pending) {
      if (entry.sessionId !== sessionId) continue;
      clearTimeout(entry.timer);
      this.pending.delete(commandId);
      entry.resolve({ ok: false, error, durationMs: Date.now() - entry.record.startedAt });
    }
  }

  /** Closes the transport and clears pending work for a session that is ending. */
  teardown(
    sessionId: string,
    message: ServerMessage,
    closeCode: number,
    closeReason: string,
  ): void {
    const transport = this.transports.get(sessionId);
    this.failAllPending(sessionId, {
      code: ErrorCodes.SESSION_REVOKED,
      message: closeReason,
    });
    if (transport) {
      try {
        transport.send(message);
      } finally {
        transport.close(closeCode, closeReason);
        this.transports.delete(sessionId);
      }
    }
  }

  private remember(session: SessionRecord, record: CommandRecord): void {
    session.commands.set(record.id, record);
    session.commandOrder.push(record.id);
    while (session.commandOrder.length > MAX_COMMAND_HISTORY) {
      const oldest = session.commandOrder.shift();
      if (oldest) session.commands.delete(oldest);
    }
  }

  private finalize(session: SessionRecord, record: CommandRecord, outcome: CommandOutcome): void {
    if (record.status !== 'pending') return;
    record.finishedAt = Date.now();
    record.durationMs = outcome.durationMs;

    if (outcome.ok) {
      record.status = 'succeeded';
      record.resultPreview = abbreviate(outcome.result, 400);
      session.audit.record({
        kind: 'tool_succeeded',
        actor: record.origin === 'mcp' ? 'mcp' : 'owner',
        message: `${record.tool} completed in ${outcome.durationMs} ms (${record.id}).`,
      });
      return;
    }

    record.status =
      outcome.error.code === ErrorCodes.COMMAND_TIMEOUT
        ? 'timeout'
        : outcome.error.code === ErrorCodes.COMMAND_CANCELLED
          ? 'cancelled'
          : 'failed';
    record.errorCode = outcome.error.code;
    record.errorMessage = abbreviate(outcome.error.message, 300);
    session.audit.record({
      kind:
        record.status === 'timeout'
          ? 'command_timeout'
          : record.status === 'cancelled'
            ? 'command_cancelled'
            : 'tool_failed',
      actor: record.origin === 'mcp' ? 'mcp' : 'owner',
      severity: record.status === 'cancelled' ? 'info' : 'error',
      message: `${record.tool} failed with ${outcome.error.code} (${record.id}).`,
      detail: { message: outcome.error.message },
    });
  }

  get pendingCount(): number {
    return this.pending.size;
  }

  get connectionCount(): number {
    return this.transports.size;
  }
}

type BrokerGlobal = typeof globalThis & { __clovyreBroker?: SessionBroker };

export function getSessionBroker(): SessionBroker {
  const store = globalThis as BrokerGlobal;
  if (!store.__clovyreBroker) {
    store.__clovyreBroker = new SessionBroker();
  }
  return store.__clovyreBroker;
}
