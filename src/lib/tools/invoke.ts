import { getConfig } from '../config';
import { ErrorCodes } from '../protocol/messages';
import { evaluateTool } from '../mcp/tool-availability';
import {
  cancelCommand,
  getRemoteCalls,
  getWatchEvents,
  listCapabilities,
  listWatches,
  recentActivity,
  recentErrors,
  sessionInfo,
} from '../mcp/local-tools';
import { getRateLimiter } from '../security/rate-limit';
import { normalizeIncoming } from '../serialization/roblox-value';
import { getSessionBroker } from '../sessions/broker';
import { getSessionStore } from '../sessions/store';
import type { CommandRecord, RobloxClientState, SessionRecord } from '../sessions/types';
import { connectedClients, findClient } from '../sessions/types';
import { getTool } from './registry';

/**
 * Single execution path for every Clovyre tool.
 *
 * Both callers — the remote MCP endpoint and the dashboard's own explorer — go
 * through here, so availability gating, argument validation, rate limiting and
 * auditing behave identically no matter who asked.
 */

export interface ToolInvocationSuccess {
  readonly ok: true;
  readonly commandId: string | null;
  readonly durationMs: number;
  readonly truncated: boolean;
  readonly data: unknown;
}

export interface ToolInvocationFailure {
  readonly ok: false;
  readonly commandId: string | null;
  readonly durationMs: number;
  readonly code: string;
  readonly message: string;
  readonly detail?: unknown;
}

export type ToolInvocationResult = ToolInvocationSuccess | ToolInvocationFailure;

function failure(code: string, message: string, detail?: unknown): ToolInvocationFailure {
  return {
    ok: false,
    commandId: null,
    durationMs: 0,
    code,
    message,
    ...(detail === undefined ? {} : { detail }),
  };
}

/**
 * Describes a client to the agent. Deliberately identity-only: enough to ask a
 * human "which one?" and nothing that would leak between users of a session.
 */
function describeClient(client: RobloxClientState) {
  return {
    client: client.clientId,
    label: client.label,
    account: client.metadata?.localPlayer?.name ?? null,
    executor: client.metadata?.executor ?? null,
    place: client.metadata?.gameName ?? null,
    connectedAt: new Date(client.connectedAt).toISOString(),
  };
}

/**
 * Picks the Roblox client a call is for.
 *
 * With one client attached the choice is obvious and is made silently. With
 * several, guessing would be the wrong move: the clients are different people's
 * games, and running a mutation against the wrong one is not recoverable by
 * retrying. So an unaddressed call fails with the roster attached and an
 * instruction to ask, which is what turns into "which client should I use?" in
 * the agent's own words.
 */
function resolveClient(
  session: SessionRecord,
  selector: string | undefined,
): { ok: true; client: RobloxClientState } | { ok: false; failure: ToolInvocationFailure } {
  const clients = connectedClients(session);

  if (clients.length === 0) {
    return {
      ok: false,
      failure: failure(
        ErrorCodes.CLIENT_NOT_CONNECTED,
        'No Roblox client is connected to this Clovyre session.',
      ),
    };
  }

  if (selector !== undefined && selector.trim().length > 0) {
    const found = findClient(session, selector);
    if (!found) {
      return {
        ok: false,
        failure: failure(
          ErrorCodes.CLIENT_NOT_FOUND,
          `No connected Roblox client matches "${selector}". Choose one of the clients listed in "clients".`,
          { clients: clients.map(describeClient) },
        ),
      };
    }
    return { ok: true, client: found };
  }

  if (clients.length === 1) return { ok: true, client: clients[0]! };

  return {
    ok: false,
    failure: failure(
      ErrorCodes.CLIENT_AMBIGUOUS,
      `${clients.length} Roblox clients are connected to this session, so it is not clear which one this call is for. Ask the user which client they mean, then repeat the call with the "client" argument set to that client's id. Do not guess.`,
      { clients: clients.map(describeClient) },
    ),
  };
}

export async function invokeTool(
  session: SessionRecord,
  toolName: string,
  rawArguments: unknown,
  origin: CommandRecord['origin'],
): Promise<ToolInvocationResult> {
  const definition = getTool(toolName);
  if (!definition) {
    return failure('TOOL_NOT_FOUND', `Clovyre has no tool named "${toolName}".`);
  }

  // `client` addresses the call rather than describing it, so it is peeled off
  // before validation: the tool schemas are strict and know nothing about it.
  const rawRecord =
    typeof rawArguments === 'object' && rawArguments !== null
      ? (rawArguments as Record<string, unknown>)
      : {};
  const { client: rawClientSelector, ...toolArguments } = rawRecord;
  const clientSelector = typeof rawClientSelector === 'string' ? rawClientSelector : undefined;

  const availability = evaluateTool(session, definition);
  if (!availability.available) {
    const code =
      availability.reason === 'privilege_required'
        ? ErrorCodes.PRIVILEGE_REQUIRED
        : availability.reason === 'capability_missing'
          ? ErrorCodes.CAPABILITY_UNAVAILABLE
          : availability.reason === 'client_disconnected'
            ? ErrorCodes.CLIENT_NOT_CONNECTED
            : ErrorCodes.PRIVILEGE_REQUIRED;
    return failure(code, availability.detail ?? 'This tool is not currently available.');
  }

  const parsed = definition.inputSchema.safeParse(toolArguments);
  if (!parsed.success) {
    return failure(
      ErrorCodes.INVALID_ARGUMENTS,
      'The tool arguments failed validation.',
      parsed.error.issues.slice(0, 5).map((issue) => ({
        path: issue.path.join('.') || '(root)',
        message: issue.message,
      })),
    );
  }
  const args = parsed.data as Record<string, unknown>;

  const limiter = getRateLimiter();
  const rule = definition.name === 'clovyre_execute_luau' ? 'execute_luau' : 'tool_call';
  const limit = limiter.check(rule, session.id);
  if (!limit.allowed) {
    session.audit.record({
      kind: 'rate_limited',
      actor: origin === 'mcp' ? 'mcp' : 'owner',
      severity: 'warn',
      message: `Rate limit reached for ${definition.name}.`,
    });
    return failure(
      ErrorCodes.RATE_LIMITED,
      `Rate limit reached. Retry in ${Math.ceil(limit.retryAfterMs / 1000)} s.`,
    );
  }

  if (definition.local) {
    const started = Date.now();
    const data = runLocalTool(session, definition.name, args, clientSelector);
    return { ok: true, commandId: null, durationMs: Date.now() - started, truncated: false, data };
  }

  const resolved = resolveClient(session, clientSelector);
  if (!resolved.ok) return resolved.failure;

  const config = getConfig();
  const requestedTimeout = typeof args.timeoutMs === 'number' ? args.timeoutMs : undefined;
  const timeoutMs = Math.min(
    requestedTimeout ?? definition.defaultTimeoutMs,
    config.maxCommandTimeoutMs,
  );

  const commandArguments = definition.toCommand ? definition.toCommand(args) : { ...args };
  if (definition.name === 'clovyre_execute_luau') {
    // The bridge needs to know whether the owner unlocked executor globals.
    commandArguments.exposeExecutorGlobals = getSessionStore().hasPrivilege(
      session,
      'executor_globals',
    );
  }

  const { commandId, outcome } = await getSessionBroker().dispatch(session, {
    tool: definition.name,
    clientId: resolved.client.clientId,
    arguments: commandArguments,
    timeoutMs,
    origin,
  });

  if (!outcome.ok) {
    return {
      ok: false,
      commandId,
      durationMs: outcome.durationMs,
      code: outcome.error.code,
      message: outcome.error.message,
    };
  }

  const { value, report } = normalizeIncoming(outcome.result);
  return {
    ok: true,
    commandId,
    durationMs: outcome.durationMs,
    truncated: outcome.truncated || report.truncated,
    data: value,
  };
}

function runLocalTool(
  session: SessionRecord,
  toolName: string,
  args: Record<string, unknown>,
  clientSelector: string | undefined,
): unknown {
  switch (toolName) {
    case 'clovyre_session_info':
      return sessionInfo(session);
    case 'clovyre_list_clients':
      return { clients: connectedClients(session).map(describeClient) };
    case 'clovyre_list_capabilities':
      return listCapabilities(session);
    case 'clovyre_get_recent_activity':
      return recentActivity(session, typeof args.limit === 'number' ? args.limit : 50);
    case 'clovyre_get_recent_errors':
      return recentErrors(session, typeof args.limit === 'number' ? args.limit : 50);
    case 'clovyre_list_watches':
      return listWatches(session);
    case 'clovyre_get_watch_events':
      return getWatchEvents(session, {
        limit: typeof args.limit === 'number' ? args.limit : 50,
        clientId: clientSelector ? (findClient(session, clientSelector)?.clientId ?? null) : null,
        watchId: typeof args.watchId === 'string' ? args.watchId : undefined,
        since: typeof args.since === 'number' ? args.since : undefined,
        clear: args.clear === true,
      });
    case 'clovyre_get_remote_calls':
      return getRemoteCalls(session, {
        limit: typeof args.limit === 'number' ? args.limit : 50,
        clientId: clientSelector ? (findClient(session, clientSelector)?.clientId ?? null) : null,
        remoteName: typeof args.remoteName === 'string' ? args.remoteName : undefined,
        method: typeof args.method === 'string' ? args.method : undefined,
        since: typeof args.since === 'number' ? args.since : undefined,
        clear: args.clear === true,
      });
    case 'clovyre_cancel_command':
      return cancelCommand(session, String(args.commandId));
    default:
      throw new Error(`Local tool "${toolName}" has no handler.`);
  }
}
