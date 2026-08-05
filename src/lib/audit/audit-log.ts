import { generateEventId } from '../security/tokens';
import { abbreviate, redactValue, type JsonValue } from '../security/redact';

/**
 * Per-session, in-memory audit trail. Bounded so a chatty client cannot grow
 * the process heap without limit.
 */

export const AUDIT_KINDS = [
  'session_created',
  'session_terminated',
  'session_expired',
  'credential_revoked',
  'credential_rotated',
  'roblox_connected',
  'roblox_disconnected',
  'roblox_rejected',
  'capabilities_reported',
  'mcp_connected',
  'mcp_disconnected',
  'mcp_rejected',
  'tool_called',
  'tool_succeeded',
  'tool_failed',
  'command_cancelled',
  'command_timeout',
  'privilege_enabled',
  'privilege_disabled',
  'privilege_expired',
  'client_log',
  'client_event',
  'rate_limited',
  'protocol_violation',
] as const;

export type AuditKind = (typeof AUDIT_KINDS)[number];

export type AuditSeverity = 'info' | 'warn' | 'error';

export interface AuditEvent {
  readonly id: string;
  readonly at: number;
  readonly kind: AuditKind;
  readonly severity: AuditSeverity;
  readonly message: string;
  readonly actor: 'owner' | 'roblox' | 'mcp' | 'system';
  readonly detail?: JsonValue;
}

const MAX_EVENTS_PER_SESSION = 500;

export class AuditLog {
  private readonly events: AuditEvent[] = [];

  record(input: {
    kind: AuditKind;
    message: string;
    actor: AuditEvent['actor'];
    severity?: AuditSeverity;
    detail?: unknown;
  }): AuditEvent {
    const event: AuditEvent = {
      id: generateEventId(),
      at: Date.now(),
      kind: input.kind,
      severity: input.severity ?? 'info',
      // Messages are redacted defensively: some carry client-supplied text.
      message: abbreviate(input.message, 500),
      actor: input.actor,
      ...(input.detail === undefined ? {} : { detail: redactValue(input.detail) }),
    };
    this.events.push(event);
    if (this.events.length > MAX_EVENTS_PER_SESSION) {
      this.events.splice(0, this.events.length - MAX_EVENTS_PER_SESSION);
    }
    return event;
  }

  /** Most recent first. */
  list(
    options: { limit?: number; kinds?: readonly AuditKind[]; severity?: AuditSeverity } = {},
  ): AuditEvent[] {
    const limit = Math.min(Math.max(options.limit ?? 100, 1), MAX_EVENTS_PER_SESSION);
    let items = this.events;
    if (options.kinds && options.kinds.length > 0) {
      const allowed = new Set<string>(options.kinds);
      items = items.filter((event) => allowed.has(event.kind));
    }
    if (options.severity) {
      items = items.filter((event) => event.severity === options.severity);
    }
    return items.slice(-limit).reverse();
  }

  get size(): number {
    return this.events.length;
  }
}
