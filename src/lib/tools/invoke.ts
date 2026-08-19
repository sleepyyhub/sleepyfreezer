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

  // Two local tools reach across every client rather than answering from session
  // state, so they dispatch on their own and cannot use the synchronous path.
  if (definition.name === 'clovyre_broadcast_tool') {
    return broadcastTool(session, args, origin);
  }
  if (definition.name === 'clovyre_compare_clients') {
    return compareClients(session, args, origin);
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

/**
 * Runs one read-only tool on every connected client.
 *
 * The read-only restriction is enforced here rather than left to the caller: a
 * broadcast mutation would change several different people's games from a single
 * call, which is not a thing this tool should be able to express by accident.
 */
async function broadcastTool(
  session: SessionRecord,
  args: Record<string, unknown>,
  origin: CommandRecord['origin'],
): Promise<ToolInvocationResult> {
  const started = Date.now();
  const targetName = String(args.tool ?? '');
  const target = getTool(targetName);

  if (!target) {
    return failure('TOOL_NOT_FOUND', `Clovyre has no tool named "${targetName}".`);
  }
  if (target.local) {
    return failure(
      'INVALID_ARGUMENTS',
      `"${targetName}" is answered by the Clovyre backend, not by a Roblox client, so broadcasting it would just repeat one answer.`,
    );
  }
  if (!target.readOnly || target.requiresPrivilege) {
    return failure(
      'INVALID_ARGUMENTS',
      `"${targetName}" can change client state, and broadcast only runs read-only tools. Call it on one named client instead.`,
    );
  }

  const clients = connectedClients(session);
  if (clients.length === 0) {
    return failure(
      ErrorCodes.CLIENT_NOT_CONNECTED,
      'No Roblox client is connected to this Clovyre session.',
    );
  }

  const parsed = target.inputSchema.safeParse(args.arguments ?? {});
  if (!parsed.success) {
    return failure(
      'INVALID_ARGUMENTS',
      `Arguments for "${targetName}" are not valid.`,
      parsed.error.issues.slice(0, 5).map((issue) => ({
        path: issue.path.join('.') || '(root)',
        message: issue.message,
      })),
    );
  }
  const targetArguments = target.toCommand
    ? target.toCommand(parsed.data)
    : { ...(parsed.data as Record<string, unknown>) };

  const config = getConfig();
  const timeoutMs = Math.min(target.defaultTimeoutMs, config.maxCommandTimeoutMs);
  const broker = getSessionBroker();

  const results = await Promise.all(
    clients.map(async (client) => {
      // Availability is per client: one executor may lack a capability another has.
      const availability = evaluateTool(session, target, client.clientId);
      if (!availability.available) {
        return {
          client: client.clientId,
          label: client.label,
          ok: false,
          code: availability.reason ?? 'UNAVAILABLE',
          message: availability.detail ?? 'This tool is not available on that client.',
        };
      }
      const { outcome } = await broker.dispatch(session, {
        tool: target.name,
        clientId: client.clientId,
        arguments: targetArguments,
        timeoutMs,
        origin,
      });
      if (!outcome.ok) {
        return {
          client: client.clientId,
          label: client.label,
          ok: false,
          code: outcome.error.code,
          message: outcome.error.message,
        };
      }
      return {
        client: client.clientId,
        label: client.label,
        ok: true,
        data: normalizeIncoming(outcome.result).value,
      };
    }),
  );

  return {
    ok: true,
    commandId: null,
    durationMs: Date.now() - started,
    truncated: false,
    data: {
      tool: target.name,
      clientCount: clients.length,
      succeeded: results.filter((entry) => entry.ok).length,
      results,
    },
  };
}

interface TreeNode {
  path?: string;
  displayPath?: string;
  className?: string;
  children?: TreeNode[];
}

/** Flattens a tree snapshot into path -> className, so two can be compared. */
function flattenTree(node: unknown, into = new Map<string, string>()): Map<string, string> {
  if (typeof node !== 'object' || node === null) return into;
  const typed = node as TreeNode;
  const key = typed.displayPath ?? typed.path;
  if (typeof key === 'string') into.set(key, typed.className ?? '?');
  for (const child of typed.children ?? []) flattenTree(child, into);
  return into;
}

/**
 * Takes the same snapshot from two clients and reports where they disagree.
 *
 * Both snapshots are requested with identical arguments, so a difference is a
 * real difference in what the two clients can see rather than an artefact of
 * asking them different questions.
 */
async function compareClients(
  session: SessionRecord,
  args: Record<string, unknown>,
  origin: CommandRecord['origin'],
): Promise<ToolInvocationResult> {
  const started = Date.now();
  const a = findClient(session, String(args.clientA ?? ''));
  const b = findClient(session, String(args.clientB ?? ''));

  if (!a || !b) {
    return failure(
      ErrorCodes.CLIENT_NOT_FOUND,
      'Both clientA and clientB must name a connected client.',
      { clients: connectedClients(session).map(describeClient) },
    );
  }
  if (a.clientId === b.clientId) {
    return failure('INVALID_ARGUMENTS', 'clientA and clientB must be different clients.');
  }

  const treeTool = getTool('clovyre_get_instance_tree')!;
  const treeArguments = {
    path: args.path ?? null,
    displayPath: null,
    ref: null,
    maxDepth: typeof args.maxDepth === 'number' ? args.maxDepth : 3,
    maxNodes: typeof args.maxNodes === 'number' ? args.maxNodes : 250,
    childLimitPerNode: 25,
  };

  const config = getConfig();
  const timeoutMs = Math.min(treeTool.defaultTimeoutMs, config.maxCommandTimeoutMs);
  const broker = getSessionBroker();

  const [left, right] = await Promise.all(
    [a, b].map((client) =>
      broker.dispatch(session, {
        tool: treeTool.name,
        clientId: client.clientId,
        arguments: treeArguments,
        timeoutMs,
        origin,
      }),
    ),
  );

  if (!left!.outcome.ok || !right!.outcome.ok) {
    const broken = !left!.outcome.ok
      ? { client: a, outcome: left!.outcome }
      : { client: b, outcome: right!.outcome };
    if (broken.outcome.ok) return failure('BAD_RESPONSE', 'A client returned no snapshot.');
    return failure(
      broken.outcome.error.code,
      `${broken.client.label} could not produce a snapshot: ${broken.outcome.error.message}`,
    );
  }

  const leftNodes = flattenTree(normalizeIncoming(left!.outcome.result).value);
  const rightNodes = flattenTree(normalizeIncoming(right!.outcome.result).value);

  const onlyInA: string[] = [];
  const onlyInB: string[] = [];
  const classDiffers: Array<{ path: string; a: string; b: string }> = [];

  for (const [path, className] of leftNodes) {
    const other = rightNodes.get(path);
    if (other === undefined) onlyInA.push(path);
    else if (other !== className) classDiffers.push({ path, a: className, b: other });
  }
  for (const path of rightNodes.keys()) {
    if (!leftNodes.has(path)) onlyInB.push(path);
  }

  const identical = onlyInA.length === 0 && onlyInB.length === 0 && classDiffers.length === 0;

  return {
    ok: true,
    commandId: null,
    durationMs: Date.now() - started,
    truncated: false,
    data: {
      clientA: { client: a.clientId, label: a.label, nodeCount: leftNodes.size },
      clientB: { client: b.clientId, label: b.label, nodeCount: rightNodes.size },
      identical,
      onlyInA: onlyInA.slice(0, 200),
      onlyInB: onlyInB.slice(0, 200),
      classDiffers: classDiffers.slice(0, 200),
      note: identical
        ? 'Both clients report the same subtree.'
        : 'Differences may be streaming, client-local objects, or replication that has not caught up. The snapshots are also a moment apart, so a busy tree can differ harmlessly.',
    },
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
