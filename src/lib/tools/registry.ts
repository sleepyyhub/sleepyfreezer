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
  | 'observation'
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
    name: 'clovyre_list_clients',
    title: 'List connected Roblox clients',
    description:
      'Lists every Roblox client attached to this session, with the account, executor and place ' +
      'for each. Call this when a tool reports CLIENT_AMBIGUOUS: show the user this list, ask ' +
      'which client they mean, then pass that client id as the "client" argument. Never guess ' +
      'which client to act on -- they are different people\u2019s games.',
    category: 'session',
    inputSchema: empty,
    local: true,
    readOnly: true,
    defaultTimeoutMs: 5_000,
  }),
  tool({
    name: 'clovyre_broadcast_tool',
    title: 'Run one read-only tool on every client',
    description:
      'Runs a single read-only tool on every connected Roblox client and returns the results side by side. ' +
      'Use it to answer "does everyone see the same thing" without calling the tool once per client. Only ' +
      'read-only, non-privileged, Roblox-bound tools are allowed: broadcasting a change to everyone at once ' +
      'is not something this tool will do.',
    category: 'session',
    inputSchema: z.object({
      tool: z.string().min(1).max(64),
      arguments: z.record(z.unknown()).default({}),
    }),
    local: true,
    readOnly: true,
    defaultTimeoutMs: 30_000,
  }),
  tool({
    name: 'clovyre_compare_clients',
    title: 'Diff a subtree between two clients',
    description:
      'Takes the same tree snapshot from two connected clients and reports what differs: instances only one of ' +
      'them can see, and instances whose class differs. This is how to investigate whether something is ' +
      'client-local, replicated late, or streamed out for one player and not the other.',
    category: 'session',
    inputSchema: z.object({
      clientA: z.string().min(1).max(128),
      clientB: z.string().min(1).max(128),
      path: z.string().min(1).max(2048).optional(),
      maxDepth: z.number().int().min(1).max(6).default(3),
      maxNodes: limitField(600, 250),
    }),
    local: true,
    readOnly: true,
    defaultTimeoutMs: 30_000,
  }),
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
    name: 'clovyre_get_properties',
    title: 'Read many properties at once',
    description:
      'Reads several safe-registry properties across several instances in one call. Prefer this over ' +
      'repeated clovyre_get_property: one round trip instead of one per property. Omit "properties" to ' +
      'read every safe property each instance has. Properties outside the safe registry are reported as ' +
      'rejected per instance rather than failing the whole call.',
    category: 'discovery',
    inputSchema: z
      .object({
        refs: z.array(z.string().min(1).max(128)).min(1).max(50).optional(),
        paths: z.array(z.string().min(1).max(2048)).min(1).max(50).optional(),
        properties: z.array(z.string().min(1).max(128)).max(40).optional(),
      })
      .refine(
        (value) => Boolean(value.refs?.length ?? value.paths?.length),
        'Provide "refs" or "paths" to identify the instances.',
      ),
    readOnly: true,
    defaultTimeoutMs: 20_000,
    toCommand: (args) => ({
      refs: args.refs ?? [],
      paths: args.paths ?? [],
      properties: args.properties ?? [],
    }),
  }),
  tool({
    name: 'clovyre_search_properties',
    title: 'Find instances by property value',
    description:
      'Searches a subtree for instances whose safe-registry property matches a comparison — for example ' +
      'every BasePart with CanCollide false, or every TextLabel whose Text contains "Coins". Compares ' +
      'against the serialized value, so numbers, booleans and strings all work.',
    category: 'discovery',
    inputSchema: z.object({
      property: z.string().min(1).max(128),
      operator: z
        .enum(['equals', 'notEquals', 'contains', 'greaterThan', 'lessThan', 'exists'])
        .default('equals'),
      value: z.unknown().optional(),
      root: z.string().min(1).max(2048).optional(),
      classNames: z.array(z.string().min(1).max(64)).max(20).optional(),
      maxResults: limitField(200, 50),
      maxDepth: z.number().int().min(1).max(16).default(8),
    }),
    readOnly: true,
    defaultTimeoutMs: 25_000,
    toCommand: (args) => ({
      property: args.property,
      operator: args.operator,
      value: args.value ?? null,
      root: args.root ?? null,
      classNames: args.classNames ?? [],
      maxResults: args.maxResults,
      maxDepth: args.maxDepth,
    }),
  }),
  tool({
    name: 'clovyre_list_remotes',
    title: 'List remote objects',
    description:
      'Enumerates the RemoteEvent, UnreliableRemoteEvent and RemoteFunction objects visible to this client, ' +
      'with their paths and parents. This maps the surface the game uses to talk to its server. Clovyre ' +
      'reads this surface and never fires anything on it — there is no tool that invokes a remote.',
    category: 'discovery',
    inputSchema: z.object({
      root: z.string().min(1).max(2048).optional(),
      maxResults: limitField(500, 200),
      maxDepth: z.number().int().min(1).max(16).default(10),
    }),
    readOnly: true,
    defaultTimeoutMs: 25_000,
    toCommand: (args) => ({
      root: args.root ?? null,
      maxResults: args.maxResults,
      maxDepth: args.maxDepth,
    }),
  }),
  tool({
    name: 'clovyre_find_gui_elements',
    title: 'Search the on-screen GUI',
    description:
      'Searches the visible GUI for elements by name or by their displayed text. Use this instead of walking ' +
      'clovyre_get_gui_tree when you already know what you are looking for.',
    category: 'discovery',
    inputSchema: z.object({
      query: z.string().max(256).optional(),
      text: z.string().max(256).optional(),
      classNames: z.array(z.string().min(1).max(64)).max(20).optional(),
      visibleOnly: z.boolean().default(true),
      maxResults: limitField(200, 50),
    }),
    readOnly: true,
    defaultTimeoutMs: 20_000,
    toCommand: (args) => ({
      query: args.query ?? null,
      text: args.text ?? null,
      classNames: args.classNames ?? [],
      visibleOnly: args.visibleOnly,
      maxResults: args.maxResults,
    }),
  }),
  tool({
    name: 'clovyre_get_screen_text',
    title: 'Read the text on screen',
    description:
      'Returns the text currently displayed by the GUI, in rough top-to-bottom screen order, with the path of ' +
      'each element. This is how to find out what the interface is telling the player; Clovyre cannot take ' +
      'screenshots, and this is the closest honest equivalent.',
    category: 'discovery',
    inputSchema: z.object({
      visibleOnly: z.boolean().default(true),
      includeEmpty: z.boolean().default(false),
      maxResults: limitField(400, 150),
    }),
    readOnly: true,
    defaultTimeoutMs: 20_000,
    toCommand: (args) => ({
      visibleOnly: args.visibleOnly,
      includeEmpty: args.includeEmpty,
      maxResults: args.maxResults,
    }),
  }),
  tool({
    name: 'clovyre_get_ancestors',
    title: 'Walk up from an instance',
    description:
      'Returns the ancestor chain of the addressed instance, nearest parent first, up to the DataModel. Useful ' +
      'for working out what owns something you found by search.',
    category: 'discovery',
    inputSchema: withTarget({}),
    readOnly: true,
    defaultTimeoutMs: 10_000,
    toCommand: (args) => targetToCommand(args),
  }),
  tool({
    name: 'clovyre_get_tag_index',
    title: 'Index CollectionService tags',
    description:
      'Lists every CollectionService tag in use on this client with how many instances carry it, and optionally ' +
      'a sample of those instances. Good for finding the conventions a game uses.',
    category: 'discovery',
    inputSchema: z.object({
      samplesPerTag: z.number().int().min(0).max(10).default(3),
      maxTags: limitField(200, 80),
    }),
    readOnly: true,
    defaultTimeoutMs: 20_000,
    toCommand: (args) => ({ samplesPerTag: args.samplesPerTag, maxTags: args.maxTags }),
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
  tool({
    name: 'clovyre_get_gui_tree',
    title: 'Inspect the GUI hierarchy',
    description:
      'Returns the on-screen GUI hierarchy with text, visibility, absolute position and size already ' +
      'resolved, so you can answer questions about the interface without walking the tree property by ' +
      'property. Defaults to the local PlayerGui; pass a root to scope it elsewhere, and set ' +
      'visibleOnly to skip hidden branches.',
    category: 'discovery',
    inputSchema: z.object({
      root: target.optional(),
      maxDepth: z.number().int().min(1).max(12).default(6),
      maxNodes: limitField(800, 250),
      visibleOnly: z.boolean().default(false),
      includeText: z.boolean().default(true),
      includeCoreGui: z.boolean().default(false),
    }),
    readOnly: true,
    defaultTimeoutMs: 20_000,
    toCommand: (args) => ({
      root: args.root ? targetToCommand(args.root) : null,
      maxDepth: args.maxDepth,
      maxNodes: args.maxNodes,
      visibleOnly: args.visibleOnly,
      includeText: args.includeText,
      includeCoreGui: args.includeCoreGui,
    }),
  }),
];

/* ------------------------------------------------------------------ */
/* Observation: watchers and the remote spy                            */
/* ------------------------------------------------------------------ */

const observationTools: ToolDefinition[] = [
  tool({
    name: 'clovyre_watch_start',
    title: 'Watch an instance for changes',
    description:
      'Installs a watcher on a visible instance and streams its changes back to Clovyre, where they are ' +
      'buffered for you to poll with clovyre_get_watch_events. Watch a property, attributes, or ' +
      'children being added and removed. Use this instead of polling the same tool repeatedly: it ' +
      'catches changes you would otherwise miss between calls.',
    category: 'observation',
    inputSchema: withTarget({
      kinds: z
        .array(z.enum(['property', 'attribute', 'childAdded', 'childRemoved']))
        .min(1)
        .max(4)
        .default(['property']),
      /** Required when watching a property; must be in the safe registry. */
      property: z.string().max(128).optional(),
      attribute: z.string().max(128).optional(),
      label: z.string().max(64).optional(),
    }),
    readOnly: true,
    defaultTimeoutMs: 15_000,
    toCommand: (args) => ({
      ...targetToCommand(args),
      kinds: args.kinds,
      property: args.property ?? null,
      attribute: args.attribute ?? null,
      label: args.label ?? null,
    }),
  }),
  tool({
    name: 'clovyre_watch_stop',
    title: 'Stop a watcher',
    description:
      'Removes one watcher by id, or every watcher when "all" is true. Watchers are also cleared ' +
      'automatically when the Roblox client disconnects.',
    category: 'observation',
    inputSchema: z.object({
      watchId: z.string().max(64).optional(),
      all: z.boolean().default(false),
    }),
    readOnly: true,
    defaultTimeoutMs: 10_000,
    toCommand: (args) => ({ watchId: args.watchId ?? null, all: args.all }),
  }),
  tool({
    name: 'clovyre_wait_for',
    title: 'Wait for something to change',
    description:
      'Blocks on the client until a condition happens, then returns what happened. Waits for a property to ' +
      'change (or to reach a specific value), for a child matching a name to appear, or for an attribute to ' +
      'change. Use this instead of polling the same instance in a loop: one call, one result, and it returns ' +
      'the moment the change occurs rather than at the end of a poll interval. Returns timedOut true if ' +
      'nothing happened in time, which is an answer, not an error.',
    category: 'observation',
    inputSchema: withTarget({
      condition: z
        .enum(['propertyChanged', 'childAdded', 'attributeChanged'])
        .default('propertyChanged'),
      property: z.string().min(1).max(128).optional(),
      attribute: z.string().min(1).max(128).optional(),
      childName: z.string().min(1).max(128).optional(),
      /** Await this exact serialized value rather than any change. */
      equals: z.unknown().optional(),
      // Bounded well under the command timeout so the wait, not the transport,
      // is what decides the outcome.
      timeoutSeconds: z.number().int().min(1).max(25).default(10),
    }),
    readOnly: true,
    defaultTimeoutMs: 30_000,
    toCommand: (args) => ({
      ...targetToCommand(args),
      condition: args.condition,
      property: args.property ?? null,
      attribute: args.attribute ?? null,
      childName: args.childName ?? null,
      equals: args.equals ?? null,
      hasEquals: args.equals !== undefined,
      timeoutSeconds: args.timeoutSeconds,
    }),
  }),
  tool({
    name: 'clovyre_list_watches',
    title: 'List active watchers',
    description:
      'Returns the watchers currently installed on the client and what each one observes.',
    category: 'observation',
    inputSchema: empty,
    local: true,
    readOnly: true,
    defaultTimeoutMs: 5_000,
  }),
  tool({
    name: 'clovyre_get_watch_events',
    title: 'Read buffered watch events',
    description:
      'Returns changes recorded by active watchers, newest first. The buffer is capped, so poll it ' +
      'while you work rather than waiting until the end. Reports how many events were dropped if the ' +
      'buffer overflowed.',
    category: 'observation',
    inputSchema: z.object({
      limit: limitField(200, 50),
      watchId: z.string().max(64).optional(),
      since: z.number().int().min(0).optional(),
      clear: z.boolean().default(false),
    }),
    local: true,
    readOnly: true,
    defaultTimeoutMs: 5_000,
  }),
  tool({
    name: 'clovyre_remote_spy_start',
    title: 'Observe outgoing remote traffic (privileged)',
    description:
      'Records RemoteEvent and RemoteFunction calls this client sends to the server, with serialized ' +
      'arguments and where each call came from — the calling script, the line, the function name and a ' +
      'short stack. Each call gets a callId you can pass to clovyre_get_calling_code to read the code that ' +
      'made it. Observation only — Clovyre has no tool for firing a remote. This installs a metatable hook ' +
      'in the running client, which can break the game, so the session owner must enable the remote spy in ' +
      'the dashboard first.',
    category: 'observation',
    inputSchema: z.object({
      includeArguments: z.boolean().default(true),
      nameFilter: z.string().max(128).optional(),
      maxArgumentBytes: z.number().int().min(64).max(20_000).default(2_000),
      /**
       * Walking the stack per call costs a little time inside the hook. It is on
       * by default because attribution is most of the value, and off is there for
       * a game that fires remotes hot enough to feel it.
       */
      captureStack: z.boolean().default(true),
    }),
    requiresPrivilege: 'remote_spy',
    requiresCapability: 'hookmetamethod',
    readOnly: true,
    defaultTimeoutMs: 15_000,
    toCommand: (args) => ({
      includeArguments: args.includeArguments,
      nameFilter: args.nameFilter ?? null,
      maxArgumentBytes: args.maxArgumentBytes,
      captureStack: args.captureStack,
    }),
  }),
  tool({
    name: 'clovyre_get_calling_code',
    title: 'Read the code behind an observed call',
    description:
      'Returns the source around a recorded call site: pass a callId from clovyre_get_remote_calls to see ' +
      'the code that fired that remote, or address a script and line directly. Source comes from the Source ' +
      'property where the client owns the script and from the decompiler otherwise, and the result always ' +
      'says which — decompiled output is a reconstruction, and its line numbers align only approximately.',
    category: 'observation',
    inputSchema: z.object({
      callId: z.string().min(1).max(64).optional(),
      ref: z.string().min(1).max(128).optional(),
      path: z.string().min(1).max(2048).optional(),
      displayPath: z.string().min(1).max(2048).optional(),
      line: z.number().int().min(1).max(10_000_000).optional(),
      contextLines: z.number().int().min(0).max(200).default(20),
      maxBytes: z.number().int().min(1024).max(262_144).default(60_000),
    }),
    readOnly: true,
    defaultTimeoutMs: 25_000,
    toCommand: (args) => ({
      callId: args.callId ?? null,
      ref: args.ref ?? null,
      path: args.path ?? null,
      displayPath: args.displayPath ?? null,
      line: args.line ?? null,
      contextLines: args.contextLines,
      maxBytes: args.maxBytes,
    }),
  }),
  tool({
    name: 'clovyre_remote_spy_stop',
    title: 'Stop observing remote traffic',
    description: 'Removes the remote spy hook. Already-recorded calls stay readable in the buffer.',
    category: 'observation',
    inputSchema: empty,
    readOnly: true,
    defaultTimeoutMs: 10_000,
    toCommand: () => ({}),
  }),
  tool({
    name: 'clovyre_get_remote_calls',
    title: 'Read observed remote calls',
    description:
      'Returns remote calls recorded by the spy, newest first, with their serialized arguments. ' +
      'Filter by remote name to follow one channel.',
    category: 'observation',
    inputSchema: z.object({
      limit: limitField(200, 50),
      remoteName: z.string().max(128).optional(),
      method: z.enum(['FireServer', 'InvokeServer', 'any']).default('any'),
      since: z.number().int().min(0).optional(),
      clear: z.boolean().default(false),
    }),
    local: true,
    readOnly: true,
    defaultTimeoutMs: 5_000,
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
    name: 'clovyre_raycast',
    title: 'Cast a ray',
    description:
      'Casts a ray through the world and reports the first thing it hits: the instance, the hit position, the ' +
      'surface normal and the distance. Default origin and direction are the camera and where it is looking, ' +
      'which answers "what am I looking at" in one call.',
    category: 'runtime',
    inputSchema: z.object({
      from: z.enum(['camera', 'character', 'point']).default('camera'),
      origin: z.array(z.number()).length(3).optional(),
      direction: z.array(z.number()).length(3).optional(),
      maxDistance: z.number().min(1).max(10_000).default(500),
      ignoreCharacter: z.boolean().default(true),
    }),
    readOnly: true,
    defaultTimeoutMs: 15_000,
    toCommand: (args) => ({
      from: args.from,
      origin: args.origin ?? null,
      direction: args.direction ?? null,
      maxDistance: args.maxDistance,
      ignoreCharacter: args.ignoreCharacter,
    }),
  }),
  tool({
    name: 'clovyre_query_region',
    title: 'Find parts near a point',
    description:
      'Lists the parts within a radius of a point, the character or the camera, nearest first, with each ' +
      'distance. This is spatial awareness: what is around me, rather than what is in the tree.',
    category: 'runtime',
    inputSchema: z.object({
      around: z.enum(['character', 'camera', 'point']).default('character'),
      point: z.array(z.number()).length(3).optional(),
      radius: z.number().min(1).max(2_000).default(50),
      classNames: z.array(z.string().min(1).max(64)).max(20).optional(),
      maxResults: limitField(300, 60),
    }),
    readOnly: true,
    defaultTimeoutMs: 25_000,
    toCommand: (args) => ({
      around: args.around,
      point: args.point ?? null,
      radius: args.radius,
      classNames: args.classNames ?? [],
      maxResults: args.maxResults,
    }),
  }),
  tool({
    name: 'clovyre_get_stats',
    title: 'Get client performance stats',
    description:
      'Returns what the client can measure about its own health: frame rate, ping, memory use and physics ' +
      'stepping. Use it to tell "the game is slow" apart from "Clovyre is slow".',
    category: 'runtime',
    inputSchema: z.object({}).strict(),
    readOnly: true,
    defaultTimeoutMs: 15_000,
  }),
  tool({
    name: 'clovyre_get_teams',
    title: 'List teams',
    description:
      'Lists the Teams service entries with their colours and current members, as this client sees them.',
    category: 'runtime',
    inputSchema: z.object({}).strict(),
    readOnly: true,
    defaultTimeoutMs: 15_000,
  }),
  tool({
    name: 'clovyre_get_leaderstats',
    title: 'Read leaderstats',
    description:
      'Reads the leaderstats values replicated for each player — the scoreboard numbers a game keeps, such as ' +
      'coins, kills or level. Only what the server chose to replicate is visible.',
    category: 'runtime',
    inputSchema: z.object({
      playerName: z.string().max(64).optional(),
      maxPlayers: limitField(100, 50),
    }),
    readOnly: true,
    defaultTimeoutMs: 15_000,
    toCommand: (args) => ({
      playerName: args.playerName ?? null,
      maxPlayers: args.maxPlayers,
    }),
  }),
  tool({
    name: 'clovyre_get_backpack',
    title: 'List carried tools',
    description:
      'Lists the Tools in the local player\u2019s Backpack and whichever is currently equipped to the character.',
    category: 'runtime',
    inputSchema: z.object({ includeProperties: z.boolean().default(false) }),
    readOnly: true,
    defaultTimeoutMs: 15_000,
    toCommand: (args) => ({ includeProperties: args.includeProperties }),
  }),
  tool({
    name: 'clovyre_get_lighting',
    title: 'Get lighting and atmosphere',
    description:
      'Returns the Lighting service settings plus any Atmosphere, Sky, Clouds and post-processing effects, so ' +
      'you can see how the scene is lit and why it looks the way it does.',
    category: 'runtime',
    inputSchema: z.object({}).strict(),
    readOnly: true,
    defaultTimeoutMs: 15_000,
  }),
  tool({
    name: 'clovyre_get_sounds',
    title: 'List playing sounds',
    description:
      'Lists Sound instances that are currently playing, with their volume, id and where in the tree they live. ' +
      'Answers "what is making that noise".',
    category: 'runtime',
    inputSchema: z.object({
      includeStopped: z.boolean().default(false),
      maxResults: limitField(200, 60),
    }),
    readOnly: true,
    defaultTimeoutMs: 20_000,
    toCommand: (args) => ({
      includeStopped: args.includeStopped,
      maxResults: args.maxResults,
    }),
  }),
  tool({
    name: 'clovyre_get_animations',
    title: 'List playing animations',
    description:
      'Lists the animation tracks currently playing on a character, with their animation ids, weights and ' +
      'speeds. Defaults to the local player.',
    category: 'runtime',
    inputSchema: z.object({ playerName: z.string().max(64).optional() }),
    readOnly: true,
    defaultTimeoutMs: 15_000,
    toCommand: (args) => ({ playerName: args.playerName ?? null }),
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
    name: 'clovyre_set_properties',
    title: 'Set many properties (privileged, local only)',
    description:
      'Writes several safe-registry properties in one call, reporting success or failure per property rather ' +
      'than failing the whole batch. Local client state only — the Roblox server stays authoritative and will ' +
      'usually ignore or overwrite the change. Requires the owner to enable mutation tools.',
    category: 'privileged',
    inputSchema: withTarget({
      properties: z
        .array(
          z.object({
            property: z.string().min(1).max(128),
            value: z.unknown(),
          }),
        )
        .min(1)
        .max(40),
    }),
    requiresPrivilege: 'mutations',
    readOnly: false,
    defaultTimeoutMs: 20_000,
    toCommand: (args) => ({
      ...targetToCommand(args),
      properties: args.properties.map((entry) => ({
        property: entry.property,
        value: entry.value ?? null,
      })),
    }),
  }),
  tool({
    name: 'clovyre_clone_instance',
    title: 'Clone an instance (privileged, local only)',
    description:
      'Clones a client-visible instance and parents the copy where you say. Local client state only. Requires ' +
      'the owner to enable mutation tools.',
    category: 'privileged',
    inputSchema: withTarget({
      parentPath: z.string().min(1).max(2048).optional(),
      parentRef: z.string().min(1).max(128).optional(),
      name: z.string().min(1).max(128).optional(),
    }),
    requiresPrivilege: 'mutations',
    readOnly: false,
    defaultTimeoutMs: 15_000,
    toCommand: (args) => ({
      ...targetToCommand(args),
      parentPath: args.parentPath ?? null,
      parentRef: args.parentRef ?? null,
      name: args.name ?? null,
    }),
  }),
  tool({
    name: 'clovyre_set_tag',
    title: 'Add or remove a CollectionService tag (privileged, local only)',
    description:
      'Adds or removes a CollectionService tag on a client-visible instance. Local client state only. Requires ' +
      'the owner to enable mutation tools.',
    category: 'privileged',
    inputSchema: withTarget({
      tag: z.string().min(1).max(128),
      add: z.boolean().default(true),
    }),
    requiresPrivilege: 'mutations',
    readOnly: false,
    defaultTimeoutMs: 15_000,
    toCommand: (args) => ({ ...targetToCommand(args), tag: args.tag, add: args.add }),
  }),
  tool({
    name: 'clovyre_set_camera',
    title: 'Move the camera (privileged, local only)',
    description:
      'Points the camera at a position, or at an instance, and optionally changes its field of view or camera ' +
      'type. Purely local: it changes what this client sees and nothing else. Note that a game with its own ' +
      'camera script will usually take control back on the next frame. Requires the owner to enable mutation ' +
      'tools.',
    category: 'privileged',
    inputSchema: z.object({
      lookAtPath: z.string().min(1).max(2048).optional(),
      lookAtRef: z.string().min(1).max(128).optional(),
      position: z.array(z.number()).length(3).optional(),
      lookAt: z.array(z.number()).length(3).optional(),
      fieldOfView: z.number().min(1).max(120).optional(),
      cameraType: z.enum(['Custom', 'Scriptable', 'Follow', 'Track', 'Fixed', 'Attach']).optional(),
    }),
    requiresPrivilege: 'mutations',
    readOnly: false,
    defaultTimeoutMs: 15_000,
    toCommand: (args) => ({
      lookAtPath: args.lookAtPath ?? null,
      lookAtRef: args.lookAtRef ?? null,
      position: args.position ?? null,
      lookAt: args.lookAt ?? null,
      fieldOfView: args.fieldOfView ?? null,
      cameraType: args.cameraType ?? null,
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
  ...observationTools,
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
