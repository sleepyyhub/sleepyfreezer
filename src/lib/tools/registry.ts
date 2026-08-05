import { z } from 'zod';
import { instanceTargetSchema, normalizeTarget, targetShape } from '../protocol/path';
import type { CapabilityName } from '../protocol/messages';
import type { PrivilegeName } from '../sessions/types';

/**
 * Clovyre MCP tool registry.
 *
 * Tools fall into two groups:
 *  - "remote" tools are forwarded to the Roblox client over the WebSocket gateway;
 *  - "local" tools are answered by the Clovyre backend from session state.
 *
 * Every tool declares its Zod input schema, its optional executor capability
 * requirement, and whether the session owner must grant a privilege first.
 */

export type ToolCategory =
  | 'session'
  | 'discovery'
  | 'scripts'
  | 'runtime'
  | 'activity'
  | 'privileged';

export interface ToolDefinition<TSchema extends z.ZodTypeAny = z.ZodTypeAny> {
  readonly name: string;
  readonly title: string;
  readonly description: string;
  readonly category: ToolCategory;
  readonly inputSchema: TSchema;
  /** Executor capability the Roblox client must report before this tool is offered. */
  readonly requiresCapability?: CapabilityName;
  /** Owner-granted privilege required before the tool may be called. */
  readonly requiresPrivilege?: PrivilegeName;
  /** Answered by the backend rather than forwarded to Roblox. */
  readonly local?: boolean;
  /** True when the tool cannot change client state. */
  readonly readOnly: boolean;
  readonly defaultTimeoutMs: number;
  /** Maps validated MCP arguments onto the payload sent to the Roblox client. */
  readonly toCommand?: (args: z.infer<TSchema>) => Record<string, unknown>;
}

const empty = z.object({}).strict();

const limitField = (max: number, fallback: number) =>
  z.number().int().min(1).max(max).default(fallback);

const target = instanceTargetSchema;

/**
 * Builds an object schema that carries the instance-addressing fields inline.
 * Intersections would serialise to `allOf`, which several MCP clients render
 * poorly, so the target fields are merged into a single flat object instead.
 */
function withTarget<TShape extends z.ZodRawShape>(shape: TShape) {
  return z
    .object({ ...targetShape, ...shape })
    .refine(
      (value) => Boolean(value.ref ?? value.path ?? value.displayPath),
      'Provide "ref", "path" or "displayPath" to identify the instance.',
    );
}

const targetToCommand = (args: { ref?: string; path?: unknown; displayPath?: string }) =>
  normalizeTarget(args as Parameters<typeof normalizeTarget>[0]) as Record<string, unknown>;

/** Helper that keeps the definitions terse while preserving inference. */
function tool<TSchema extends z.ZodTypeAny>(definition: ToolDefinition<TSchema>): ToolDefinition {
  return definition as unknown as ToolDefinition;
}

/* ------------------------------------------------------------------ */
/* Core session                                                        */
/* ------------------------------------------------------------------ */

const sessionTools: ToolDefinition[] = [
  tool({
    name: 'clovyre_session_info',
    title: 'Session information',
    description:
      'Returns the live state of this Clovyre session: Roblox connection state, place id, universe id, ' +
      'job id, local player, executor name, protocol version, reported capabilities, uptime and expiry.',
    category: 'session',
    inputSchema: empty,
    local: true,
    readOnly: true,
    defaultTimeoutMs: 5_000,
  }),
  tool({
    name: 'clovyre_list_capabilities',
    title: 'List client capabilities',
    description:
      'Lists every capability the connected Roblox executor reported, and which Clovyre tools each one ' +
      'unlocks. Capabilities that are absent mean the corresponding tools are unavailable, not broken.',
    category: 'session',
    inputSchema: empty,
    local: true,
    readOnly: true,
    defaultTimeoutMs: 5_000,
  }),
  tool({
    name: 'clovyre_ping',
    title: 'Ping the Roblox client',
    description:
      'Measures round-trip time to the connected Roblox client. Use this to confirm the bridge is live ' +
      'before running a longer sequence of inspections.',
    category: 'session',
    inputSchema: empty,
    readOnly: true,
    defaultTimeoutMs: 10_000,
    toCommand: () => ({}),
  }),
];

/* ------------------------------------------------------------------ */
/* Instance discovery                                                  */
/* ------------------------------------------------------------------ */

const discoveryTools: ToolDefinition[] = [
  tool({
    name: 'clovyre_get_services',
    title: 'List replicated services',
    description:
      'Returns the Roblox services visible to this client, with child counts. Server-only containers such ' +
      'as ServerStorage and ServerScriptService are never accessible from a client and are reported as such.',
    category: 'discovery',
    inputSchema: empty,
    readOnly: true,
    defaultTimeoutMs: 10_000,
    toCommand: () => ({}),
  }),
  tool({
    name: 'clovyre_get_children',
    title: 'Get children of an instance',
    description:
      'Returns a page of direct children for the addressed instance. Identify the instance with a ' +
      'session-scoped "ref", a structured "path", or an escaped "displayPath".',
    category: 'discovery',
    inputSchema: withTarget({
      offset: z.number().int().min(0).max(100_000).default(0),
      limit: limitField(200, 50),
      classFilter: z.array(z.string().max(128)).max(20).optional(),
    }),
    readOnly: true,
    defaultTimeoutMs: 15_000,
    toCommand: (args) => ({
      ...targetToCommand(args),
      offset: args.offset,
      limit: args.limit,
      classFilter: args.classFilter ?? null,
    }),
  }),
  tool({
    name: 'clovyre_get_descendants',
    title: 'Get descendants of an instance',
    description:
      'Walks the subtree beneath the addressed instance with a hard depth and result cap. Prefer ' +
      'clovyre_find_instances when you are looking for something specific.',
    category: 'discovery',
    inputSchema: withTarget({
      maxDepth: z.number().int().min(1).max(12).default(4),
      maxResults: limitField(500, 200),
      classFilter: z.array(z.string().max(128)).max(20).optional(),
    }),
    readOnly: true,
    defaultTimeoutMs: 20_000,
    toCommand: (args) => ({
      ...targetToCommand(args),
      maxDepth: args.maxDepth,
      maxResults: args.maxResults,
      classFilter: args.classFilter ?? null,
    }),
  }),
  tool({
    name: 'clovyre_find_instances',
    title: 'Search for instances by name',
    description:
      'Case-insensitive substring search over instance names within the replicated tree, optionally scoped ' +
      'to a root and filtered by class.',
    category: 'discovery',
    inputSchema: z.object({
      query: z.string().min(1).max(256),
      root: target.optional(),
      classNames: z.array(z.string().max(128)).max(20).optional(),
      exactName: z.boolean().default(false),
      maxResults: limitField(200, 50),
      maxDepth: z.number().int().min(1).max(12).default(8),
    }),
    readOnly: true,
    defaultTimeoutMs: 20_000,
    toCommand: (args) => ({
      query: args.query,
      root: args.root ? targetToCommand(args.root) : null,
      classNames: args.classNames ?? null,
      exactName: args.exactName,
      maxResults: args.maxResults,
      maxDepth: args.maxDepth,
    }),
  }),
  tool({
    name: 'clovyre_inspect_instance',
    title: 'Inspect an instance',
    description:
      'Returns a full snapshot of one instance: name, class, structured path, session-scoped ref, parent, ' +
      'a children summary, attributes, CollectionService tags and safe-registry properties.',
    category: 'discovery',
    inputSchema: withTarget({
      includeProperties: z.boolean().default(true),
      includeChildren: z.boolean().default(true),
      childLimit: limitField(200, 25),
    }),
    readOnly: true,
    defaultTimeoutMs: 15_000,
    toCommand: (args) => ({
      ...targetToCommand(args),
      includeProperties: args.includeProperties,
      includeChildren: args.includeChildren,
      childLimit: args.childLimit,
    }),
  }),
  tool({
    name: 'clovyre_get_attributes',
    title: 'Get instance attributes',
    description: 'Returns every attribute set on the addressed instance, with serialized values.',
    category: 'discovery',
    inputSchema: target,
    readOnly: true,
    defaultTimeoutMs: 10_000,
    toCommand: targetToCommand,
  }),
  tool({
    name: 'clovyre_get_tags',
    title: 'Get CollectionService tags',
    description: 'Returns the CollectionService tags applied to the addressed instance.',
    category: 'discovery',
    inputSchema: target,
    readOnly: true,
    defaultTimeoutMs: 10_000,
    toCommand: targetToCommand,
  }),
  tool({
    name: 'clovyre_get_property',
    title: 'Read a single property',
    description:
      'Reads one property from the addressed instance. Only properties present in the Clovyre safe-property ' +
      'registry for that class can be read; anything else is rejected with PROPERTY_NOT_ALLOWED.',
    category: 'discovery',
    inputSchema: withTarget({ property: z.string().min(1).max(128) }),
    readOnly: true,
    defaultTimeoutMs: 10_000,
    toCommand: (args) => ({ ...targetToCommand(args), property: args.property }),
  }),
  tool({
    name: 'clovyre_get_instance_tree',
    title: 'Get a tree snapshot',
    description:
      'Returns a depth-limited, node-capped tree snapshot rooted at the addressed instance. Designed for ' +
      'orienting yourself quickly without paging through children one level at a time.',
    category: 'discovery',
    inputSchema: withTarget({
      maxDepth: z.number().int().min(1).max(8).default(3),
      maxNodes: limitField(600, 200),
      childLimitPerNode: limitField(100, 25),
    }),
    readOnly: true,
    defaultTimeoutMs: 20_000,
    toCommand: (args) => ({
      ...targetToCommand(args),
      maxDepth: args.maxDepth,
      maxNodes: args.maxNodes,
      childLimitPerNode: args.childLimitPerNode,
    }),
  }),
];

/* ------------------------------------------------------------------ */
/* Scripts                                                             */
/* ------------------------------------------------------------------ */

const scriptTools: ToolDefinition[] = [
  tool({
    name: 'clovyre_list_scripts',
    title: 'List replicated scripts',
    description:
      'Lists LocalScripts and ModuleScripts that are replicated to this client, with their paths and whether ' +
      'a source representation is obtainable. Server Scripts are not replicated and never appear.',
    category: 'scripts',
    inputSchema: z.object({
      root: target.optional(),
      classNames: z
        .array(z.enum(['LocalScript', 'ModuleScript', 'Script']))
        .max(3)
        .optional(),
      maxResults: limitField(500, 100),
      maxDepth: z.number().int().min(1).max(12).default(8),
    }),
    readOnly: true,
    defaultTimeoutMs: 25_000,
    toCommand: (args) => ({
      root: args.root ? targetToCommand(args.root) : null,
      classNames: args.classNames ?? null,
      maxResults: args.maxResults,
      maxDepth: args.maxDepth,
    }),
  }),
  tool({
    name: 'clovyre_inspect_script',
    title: 'Inspect a script',
    description:
      'Returns metadata and, where available, a source representation for one script. The response always ' +
      'states the representation type: "source" (genuine Source property), "decompiled" (best-effort output ' +
      'from the executor decompiler, which is NOT guaranteed to match the original), "bytecode" or ' +
      '"unavailable". Never present decompiled output as the original source.',
    category: 'scripts',
    inputSchema: withTarget({
      includeSource: z.boolean().default(true),
      maxSourceBytes: z.number().int().min(256).max(1_000_000).default(200_000),
    }),
    readOnly: true,
    defaultTimeoutMs: 30_000,
    toCommand: (args) => ({
      ...targetToCommand(args),
      includeSource: args.includeSource,
      maxSourceBytes: args.maxSourceBytes,
    }),
  }),
  tool({
    name: 'clovyre_search_scripts',
    title: 'Search script sources',
    description:
      'Searches available script representations for a substring or Lua pattern and returns bounded matches ' +
      'with surrounding context lines.',
    category: 'scripts',
    inputSchema: z.object({
      query: z.string().min(2).max(256),
      root: target.optional(),
      isPattern: z.boolean().default(false),
      caseSensitive: z.boolean().default(false),
      maxScripts: limitField(200, 40),
      maxMatches: limitField(200, 40),
      contextLines: z.number().int().min(0).max(6).default(2),
    }),
    readOnly: true,
    defaultTimeoutMs: 45_000,
    toCommand: (args) => ({
      query: args.query,
      root: args.root ? targetToCommand(args.root) : null,
      isPattern: args.isPattern,
      caseSensitive: args.caseSensitive,
      maxScripts: args.maxScripts,
      maxMatches: args.maxMatches,
      contextLines: args.contextLines,
    }),
  }),
  tool({
    name: 'clovyre_get_script_dependencies',
    title: 'Discover script dependencies',
    description:
      'Best-effort dependency discovery: scans an available script representation for require() calls and ' +
      'resolves the ones that address a visible instance. Dynamic requires cannot be resolved statically and ' +
      'are reported as unresolved.',
    category: 'scripts',
    inputSchema: withTarget({ maxResults: limitField(200, 50) }),
    readOnly: true,
    defaultTimeoutMs: 30_000,
    toCommand: (args) => ({ ...targetToCommand(args), maxResults: args.maxResults }),
  }),
  tool({
    name: 'clovyre_get_loaded_modules',
    title: 'List loaded modules',
    description:
      'Returns ModuleScripts the Luau VM has already loaded, via the executor getloadedmodules function. ' +
      'Only available when the executor reports the getloadedmodules capability.',
    category: 'scripts',
    inputSchema: z.object({
      maxResults: limitField(500, 100),
      excludeCoreGui: z.boolean().default(true),
    }),
    requiresCapability: 'getloadedmodules',
    readOnly: true,
    defaultTimeoutMs: 20_000,
    toCommand: (args) => ({ maxResults: args.maxResults, excludeCoreGui: args.excludeCoreGui }),
  }),
];

/* ------------------------------------------------------------------ */
/* Runtime                                                             */
/* ------------------------------------------------------------------ */

const runtimeTools: ToolDefinition[] = [
  tool({
    name: 'clovyre_get_players',
    title: 'List players',
    description:
      'Returns the players currently replicated to this client, with safe Player properties.',
    category: 'runtime',
    inputSchema: z.object({
      includeCharacters: z.boolean().default(false),
      maxResults: limitField(100, 50),
    }),
    readOnly: true,
    defaultTimeoutMs: 15_000,
    toCommand: (args) => ({
      includeCharacters: args.includeCharacters,
      maxResults: args.maxResults,
    }),
  }),
  tool({
    name: 'clovyre_get_local_player',
    title: 'Get the local player',
    description:
      'Returns the local player, their team, and a summary of their PlayerGui and Backpack.',
    category: 'runtime',
    inputSchema: empty,
    readOnly: true,
    defaultTimeoutMs: 15_000,
    toCommand: () => ({}),
  }),
  tool({
    name: 'clovyre_get_character',
    title: 'Get a character model',
    description:
      'Returns the character model for the local player or a named player, including Humanoid state and the ' +
      'root part CFrame when those are replicated.',
    category: 'runtime',
    inputSchema: z.object({
      playerName: z.string().max(64).optional(),
      includeDescendants: z.boolean().default(false),
    }),
    readOnly: true,
    defaultTimeoutMs: 15_000,
    toCommand: (args) => ({
      playerName: args.playerName ?? null,
      includeDescendants: args.includeDescendants,
    }),
  }),
  tool({
    name: 'clovyre_get_camera',
    title: 'Get the current camera',
    description:
      'Returns the current Workspace camera: CFrame, focus, field of view, type and subject.',
    category: 'runtime',
    inputSchema: empty,
    readOnly: true,
    defaultTimeoutMs: 10_000,
    toCommand: () => ({}),
  }),
  tool({
    name: 'clovyre_get_workspace_summary',
    title: 'Summarise the workspace',
    description:
      'Returns a high-level Workspace summary: gravity, streaming configuration, top-level child counts and ' +
      'a class histogram bounded to the most common classes.',
    category: 'runtime',
    inputSchema: z.object({ maxClasses: limitField(60, 25) }),
    readOnly: true,
    defaultTimeoutMs: 20_000,
    toCommand: (args) => ({ maxClasses: args.maxClasses }),
  }),
  tool({
    name: 'clovyre_get_logs',
    title: 'Get client logs',
    description:
      'Returns log lines captured by the Clovyre bridge, plus client output where the executor exposes it.',
    category: 'runtime',
    inputSchema: z.object({
      maxResults: limitField(300, 100),
      minLevel: z.enum(['trace', 'debug', 'info', 'warn', 'error']).default('debug'),
    }),
    readOnly: true,
    defaultTimeoutMs: 15_000,
    toCommand: (args) => ({ maxResults: args.maxResults, minLevel: args.minLevel }),
  }),
  tool({
    name: 'clovyre_get_connections',
    title: 'Inspect signal connections',
    description:
      'Returns connection metadata for one signal on a visible instance, via the executor getconnections ' +
      'function. Only available when the executor reports the getconnections capability.',
    category: 'runtime',
    inputSchema: withTarget({
      signal: z.string().min(1).max(128),
      maxResults: limitField(100, 25),
    }),
    requiresCapability: 'getconnections',
    readOnly: true,
    defaultTimeoutMs: 15_000,
    toCommand: (args) => ({
      ...targetToCommand(args),
      signal: args.signal,
      maxResults: args.maxResults,
    }),
  }),
  tool({
    name: 'clovyre_get_gc_summary',
    title: 'Summarise garbage-collected objects',
    description:
      'Returns a filtered, strictly capped summary of objects reachable through the executor getgc function. ' +
      'A filter is mandatory — Clovyre never dumps the whole GC. Requires the getgc capability.',
    category: 'runtime',
    inputSchema: z.object({
      kind: z.enum(['function', 'table']),
      /** Required so a caller cannot request an unbounded dump. */
      nameFilter: z.string().min(2).max(128),
      includeMetatables: z.boolean().default(false),
      maxResults: limitField(100, 25),
    }),
    requiresCapability: 'getgc',
    readOnly: true,
    defaultTimeoutMs: 25_000,
    toCommand: (args) => ({
      kind: args.kind,
      nameFilter: args.nameFilter,
      includeMetatables: args.includeMetatables,
      maxResults: args.maxResults,
    }),
  }),
  tool({
    name: 'clovyre_inspect_environment',
    title: 'Inspect a script environment',
    description:
      'Returns the upvalue and global key summary for one specific visible client script, via the executor ' +
      'getsenv function. Requires the getsenv capability and a concrete script target — there is no ' +
      'whole-environment dump.',
    category: 'runtime',
    inputSchema: withTarget({ maxKeys: limitField(200, 50) }),
    requiresCapability: 'getsenv',
    readOnly: true,
    defaultTimeoutMs: 20_000,
    toCommand: (args) => ({ ...targetToCommand(args), maxKeys: args.maxKeys }),
  }),
];

/* ------------------------------------------------------------------ */
/* Activity                                                            */
/* ------------------------------------------------------------------ */

const activityTools: ToolDefinition[] = [
  tool({
    name: 'clovyre_get_recent_activity',
    title: 'Get recent session activity',
    description:
      'Returns the recent Clovyre audit trail for this session: connection events, tool calls, durations and ' +
      'outcomes. Secrets are redacted before they ever reach this log.',
    category: 'activity',
    inputSchema: z.object({ limit: limitField(200, 50) }),
    local: true,
    readOnly: true,
    defaultTimeoutMs: 5_000,
  }),
  tool({
    name: 'clovyre_get_recent_errors',
    title: 'Get recent errors',
    description: 'Returns only the failing entries from the recent audit trail, newest first.',
    category: 'activity',
    inputSchema: z.object({ limit: limitField(200, 50) }),
    local: true,
    readOnly: true,
    defaultTimeoutMs: 5_000,
  }),
  tool({
    name: 'clovyre_cancel_command',
    title: 'Cancel an in-flight command',
    description:
      'Cancels a command that is still awaiting a result from the Roblox client. The client is asked to stop; ' +
      'work already committed on the client cannot be undone.',
    category: 'activity',
    inputSchema: z.object({ commandId: z.string().min(3).max(64) }),
    local: true,
    readOnly: false,
    defaultTimeoutMs: 5_000,
  }),
];

/* ------------------------------------------------------------------ */
/* Privileged                                                          */
/* ------------------------------------------------------------------ */

const privilegedTools: ToolDefinition[] = [
  tool({
    name: 'clovyre_execute_luau',
    title: 'Execute Luau on the client (privileged)',
    description:
      'Runs a Luau chunk inside the live Roblox client and returns its serialized return values. This is a ' +
      'privileged development tool: it is DISABLED until the session owner enables it in the Clovyre ' +
      'dashboard, the grant expires automatically, and every call is audited. The chunk runs in the ' +
      "executor's own environment — it is not sandboxed.",
    category: 'privileged',
    inputSchema: z.object({
      code: z.string().min(1).max(20_000),
      timeoutMs: z.number().int().min(250).max(30_000).default(5_000),
      resultMode: z.enum(['serialized', 'summary']).default('serialized'),
    }),
    requiresPrivilege: 'execute_luau',
    requiresCapability: 'loadstring',
    readOnly: false,
    defaultTimeoutMs: 30_000,
    toCommand: (args) => ({
      code: args.code,
      timeoutMs: args.timeoutMs,
      resultMode: args.resultMode,
    }),
  }),
  tool({
    name: 'clovyre_set_property',
    title: 'Set a property (privileged, local only)',
    description:
      'Writes one safe-registry property on a client-visible instance. Local client state only — the Roblox ' +
      'server remains authoritative and will usually ignore or overwrite the change. Requires the owner to ' +
      'enable mutation tools.',
    category: 'privileged',
    inputSchema: withTarget({
      property: z.string().min(1).max(128),
      value: z.unknown(),
    }),
    requiresPrivilege: 'mutations',
    readOnly: false,
    defaultTimeoutMs: 15_000,
    toCommand: (args) => ({
      ...targetToCommand(args),
      property: args.property,
      value: args.value ?? null,
    }),
  }),
  tool({
    name: 'clovyre_set_attribute',
    title: 'Set an attribute (privileged, local only)',
    description:
      'Sets one attribute on a client-visible instance. Local client state only. Requires the owner to enable ' +
      'mutation tools.',
    category: 'privileged',
    inputSchema: withTarget({ attribute: z.string().min(1).max(128), value: z.unknown() }),
    requiresPrivilege: 'mutations',
    readOnly: false,
    defaultTimeoutMs: 15_000,
    toCommand: (args) => ({
      ...targetToCommand(args),
      attribute: args.attribute,
      value: args.value ?? null,
    }),
  }),
  tool({
    name: 'clovyre_create_instance',
    title: 'Create an instance (privileged, local only)',
    description:
      'Creates a new instance on the client and parents it to a visible instance. Local client state only. ' +
      'Requires the owner to enable mutation tools.',
    category: 'privileged',
    inputSchema: z.object({
      className: z.string().min(1).max(128),
      name: z.string().max(128).optional(),
      parent: target,
    }),
    requiresPrivilege: 'mutations',
    readOnly: false,
    defaultTimeoutMs: 15_000,
    toCommand: (args) => ({
      className: args.className,
      name: args.name ?? null,
      parent: targetToCommand(args.parent),
    }),
  }),
  tool({
    name: 'clovyre_destroy_instance',
    title: 'Destroy an instance (privileged, local only)',
    description:
      'Destroys a client-visible instance on this client. Local client state only, and irreversible for this ' +
      'session. Requires the owner to enable mutation tools.',
    category: 'privileged',
    inputSchema: target,
    requiresPrivilege: 'mutations',
    readOnly: false,
    defaultTimeoutMs: 15_000,
    toCommand: targetToCommand,
  }),
  tool({
    name: 'clovyre_reparent_instance',
    title: 'Reparent an instance (privileged, local only)',
    description:
      'Moves a client-visible instance under a new parent on this client. Local client state only. Requires ' +
      'the owner to enable mutation tools.',
    category: 'privileged',
    inputSchema: z.object({ instance: target, newParent: target }),
    requiresPrivilege: 'mutations',
    readOnly: false,
    defaultTimeoutMs: 15_000,
    toCommand: (args) => ({
      instance: targetToCommand(args.instance),
      newParent: targetToCommand(args.newParent),
    }),
  }),
];

export const TOOL_DEFINITIONS: readonly ToolDefinition[] = Object.freeze([
  ...sessionTools,
  ...discoveryTools,
  ...scriptTools,
  ...runtimeTools,
  ...activityTools,
  ...privilegedTools,
]);

const TOOL_INDEX = new Map(TOOL_DEFINITIONS.map((definition) => [definition.name, definition]));

export function getTool(name: string): ToolDefinition | null {
  return TOOL_INDEX.get(name) ?? null;
}

export function toolNames(): string[] {
  return TOOL_DEFINITIONS.map((definition) => definition.name);
}

export function toolsByCategory(category: ToolCategory): ToolDefinition[] {
  return TOOL_DEFINITIONS.filter((definition) => definition.category === category);
}
