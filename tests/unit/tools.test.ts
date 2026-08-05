import { beforeEach, describe, expect, it } from 'vitest';
import { resetConfigForTests } from '../../src/lib/config';
import { getTool, TOOL_DEFINITIONS, toolNames } from '../../src/lib/tools/registry';
import { toolInputJsonSchema, handleMcpPayload } from '../../src/lib/mcp/server';
import { evaluateTool, listableTools } from '../../src/lib/mcp/tool-availability';
import { getSessionStore } from '../../src/lib/sessions/store';
import type { SessionRecord } from '../../src/lib/sessions/types';

function freshSession(): SessionRecord {
  const store = getSessionStore();
  store.clear();
  return store.create().session;
}

beforeEach(() => {
  resetConfigForTests();
  process.env.SESSION_SECRET = 'unit-test-session-secret-0123456789';
  process.env.TOKEN_HASH_SECRET = 'unit-test-token-hash-secret-0123456789';
});

describe('tool registry', () => {
  it('exposes uniquely named, clovyre-prefixed tools', () => {
    const names = toolNames();
    expect(new Set(names).size).toBe(names.length);
    for (const name of names) expect(name.startsWith('clovyre_')).toBe(true);
  });

  it('gives every tool a title, a description and a timeout', () => {
    for (const tool of TOOL_DEFINITIONS) {
      expect(tool.title.length).toBeGreaterThan(3);
      expect(tool.description.length).toBeGreaterThan(40);
      expect(tool.defaultTimeoutMs).toBeGreaterThan(0);
    }
  });

  it('produces a valid object JSON schema for every tool', () => {
    for (const tool of TOOL_DEFINITIONS) {
      const schema = toolInputJsonSchema(tool);
      expect(schema.type).toBe('object');
      expect(schema).not.toHaveProperty('$schema');
      expect(() => JSON.stringify(schema)).not.toThrow();
    }
  });

  it('requires an instance target on addressing tools', () => {
    const tool = getTool('clovyre_inspect_instance')!;
    expect(tool.inputSchema.safeParse({}).success).toBe(false);
    expect(tool.inputSchema.safeParse({ ref: 'ref_1' }).success).toBe(true);
    expect(tool.inputSchema.safeParse({ displayPath: 'Workspace' }).success).toBe(true);
  });

  it('applies documented defaults for pagination arguments', () => {
    const tool = getTool('clovyre_get_children')!;
    const parsed = tool.inputSchema.parse({ ref: 'ref_1' }) as { offset: number; limit: number };
    expect(parsed.offset).toBe(0);
    expect(parsed.limit).toBe(50);
  });

  it('rejects a limit above the documented ceiling', () => {
    const tool = getTool('clovyre_get_children')!;
    expect(tool.inputSchema.safeParse({ ref: 'ref_1', limit: 100_000 }).success).toBe(false);
  });

  it('requires a filter on the garbage-collector summary', () => {
    const tool = getTool('clovyre_get_gc_summary')!;
    expect(tool.inputSchema.safeParse({ kind: 'function' }).success).toBe(false);
    expect(tool.inputSchema.safeParse({ kind: 'function', nameFilter: 'combat' }).success).toBe(
      true,
    );
  });

  it('caps the Luau chunk length', () => {
    const tool = getTool('clovyre_execute_luau')!;
    expect(tool.inputSchema.safeParse({ code: 'return 1' }).success).toBe(true);
    expect(tool.inputSchema.safeParse({ code: 'x'.repeat(20_001) }).success).toBe(false);
  });

  it('marks mutating tools as not read-only', () => {
    for (const name of [
      'clovyre_execute_luau',
      'clovyre_set_property',
      'clovyre_destroy_instance',
    ]) {
      expect(getTool(name)!.readOnly).toBe(false);
    }
    expect(getTool('clovyre_inspect_instance')!.readOnly).toBe(true);
  });

  it('requires a privilege for every privileged tool', () => {
    for (const tool of TOOL_DEFINITIONS.filter((entry) => entry.category === 'privileged')) {
      expect(tool.requiresPrivilege).toBeDefined();
    }
  });
});

describe('tool availability', () => {
  it('hides privileged tools until the owner grants them', () => {
    const session = freshSession();
    const execute = getTool('clovyre_execute_luau')!;

    const blocked = evaluateTool(session, execute);
    expect(blocked.available).toBe(false);
    expect(blocked.reason).toBe('privilege_required');
    expect(listableTools(session).map((entry) => entry.definition.name)).not.toContain(
      'clovyre_execute_luau',
    );
  });

  it('still gates a granted tool on the executor capability', () => {
    const store = getSessionStore();
    const session = freshSession();
    store.setPrivilege(session, 'execute_luau', true, 'owner');

    const withoutCapability = evaluateTool(session, getTool('clovyre_execute_luau')!);
    expect(withoutCapability.available).toBe(false);
    expect(withoutCapability.reason).toBe('capability_missing');
  });

  it('reports a missing capability rather than hiding the tool', () => {
    const session = freshSession();
    const availability = evaluateTool(session, getTool('clovyre_get_loaded_modules')!);
    expect(availability.reason).toBe('capability_missing');
    expect(listableTools(session).map((entry) => entry.definition.name)).toContain(
      'clovyre_get_loaded_modules',
    );
  });

  it('reports remote tools as unavailable while no client is connected', () => {
    const session = freshSession();
    const availability = evaluateTool(session, getTool('clovyre_get_services')!);
    expect(availability.available).toBe(false);
    expect(availability.reason).toBe('client_disconnected');
  });

  it('keeps local tools available with no client connected', () => {
    const session = freshSession();
    expect(evaluateTool(session, getTool('clovyre_session_info')!).available).toBe(true);
  });

  it('honours the deployment kill switch for Luau execution', () => {
    process.env.ENABLE_EXECUTE_LUAU_FEATURE = 'false';
    resetConfigForTests();

    const store = getSessionStore();
    const session = freshSession();
    store.setPrivilege(session, 'execute_luau', true, 'owner');

    expect(evaluateTool(session, getTool('clovyre_execute_luau')!).reason).toBe('feature_disabled');

    delete process.env.ENABLE_EXECUTE_LUAU_FEATURE;
    resetConfigForTests();
  });
});

describe('connection snippets', () => {
  it('offers a URL that carries its own credential for header-less clients', async () => {
    const { buildMcpConfigSnippets } = await import('../../src/lib/sessions/snippets');
    const snippets = buildMcpConfigSnippets('https://example.test', 'cs_ABC', 'cmc_secret');

    expect(snippets.url).toBe('https://example.test/api/mcp/cs_ABC');
    expect(snippets.connectorUrl).toBe('https://example.test/api/mcp/cs_ABC/cmc_secret');
    expect(snippets.claudeCodeCommand).toContain('--transport http');
    expect(snippets.claudeCodeCommand).toContain('Authorization: Bearer cmc_secret');
    // The header form must never smuggle the token into the URL.
    expect(snippets.url).not.toContain('cmc_secret');
  });

  it('builds a loadstring that carries the session and token', async () => {
    const { buildLoadstring } = await import('../../src/lib/sessions/snippets');
    const loadstring = buildLoadstring('https://example.test', 'cs_ABC', 'crx_secret');

    expect(loadstring).toContain('getgenv().ClovyreConfig');
    expect(loadstring).toContain('SessionId = "cs_ABC"');
    expect(loadstring).toContain('RobloxToken = "crx_secret"');
    expect(loadstring).toContain('https://example.test/client.lua');
  });
});

describe('MCP JSON-RPC surface', () => {
  it('answers initialize with a negotiated protocol version and server info', async () => {
    const session = freshSession();
    const { response } = await handleMcpPayload(
      session,
      {
        jsonrpc: '2.0',
        id: 1,
        method: 'initialize',
        params: { protocolVersion: '2025-06-18', clientInfo: { name: 'vitest', version: '1' } },
      },
      'conn-1',
    );

    const result = (response as { result: Record<string, unknown> }).result;
    expect(result.protocolVersion).toBe('2025-06-18');
    expect((result.serverInfo as { name: string }).name).toBe('clovyre-mcp');
    expect(String(result.instructions)).toContain('ServerStorage');
  });

  it('falls back to the current protocol version for an unknown request', async () => {
    const session = freshSession();
    const { response } = await handleMcpPayload(
      session,
      { jsonrpc: '2.0', id: 1, method: 'initialize', params: { protocolVersion: '1999-01-01' } },
      'conn-1',
    );
    expect((response as { result: { protocolVersion: string } }).result.protocolVersion).toBe(
      '2025-06-18',
    );
  });

  it('lists tools without the privileged ones', async () => {
    const session = freshSession();
    const { response } = await handleMcpPayload(
      session,
      { jsonrpc: '2.0', id: 2, method: 'tools/list' },
      'conn-1',
    );

    const tools = (response as { result: { tools: Array<{ name: string }> } }).result.tools;
    expect(tools.length).toBeGreaterThan(20);
    expect(tools.map((tool) => tool.name)).not.toContain('clovyre_execute_luau');
    expect(tools.map((tool) => tool.name)).toContain('clovyre_session_info');
  });

  it('answers a local tool call without a Roblox client', async () => {
    const session = freshSession();
    const { response } = await handleMcpPayload(
      session,
      { jsonrpc: '2.0', id: 3, method: 'tools/call', params: { name: 'clovyre_session_info' } },
      'conn-1',
    );

    const result = (
      response as { result: { isError: boolean; structuredContent: Record<string, unknown> } }
    ).result;
    expect(result.isError).toBe(false);
    const data = result.structuredContent.data as Record<string, unknown>;
    expect((data.roblox as { connected: boolean }).connected).toBe(false);
  });

  it('refuses a privileged tool call with PRIVILEGE_REQUIRED', async () => {
    const session = freshSession();
    const { response } = await handleMcpPayload(
      session,
      {
        jsonrpc: '2.0',
        id: 4,
        method: 'tools/call',
        params: { name: 'clovyre_execute_luau', arguments: { code: 'return 1' } },
      },
      'conn-1',
    );

    const result = (
      response as { result: { isError: boolean; structuredContent: { code: string } } }
    ).result;
    expect(result.isError).toBe(true);
    expect(result.structuredContent.code).toBe('PRIVILEGE_REQUIRED');
  });

  it('reports a remote tool as CLIENT_NOT_CONNECTED when no bridge is attached', async () => {
    const session = freshSession();
    const { response } = await handleMcpPayload(
      session,
      { jsonrpc: '2.0', id: 5, method: 'tools/call', params: { name: 'clovyre_get_services' } },
      'conn-1',
    );

    const result = (response as { result: { structuredContent: { code: string } } }).result;
    expect(result.structuredContent.code).toBe('CLIENT_NOT_CONNECTED');
  });

  it('reports invalid arguments as a tool error, not a protocol error', async () => {
    const session = freshSession();
    const { response } = await handleMcpPayload(
      session,
      {
        jsonrpc: '2.0',
        id: 6,
        method: 'tools/call',
        params: { name: 'clovyre_get_recent_activity', arguments: { limit: -5 } },
      },
      'conn-1',
    );

    const result = (
      response as { result: { isError: boolean; structuredContent: { code: string } } }
    ).result;
    expect(result.isError).toBe(true);
    expect(result.structuredContent.code).toBe('INVALID_ARGUMENTS');
  });

  it('returns METHOD_NOT_FOUND for an unknown method', async () => {
    const session = freshSession();
    const { response } = await handleMcpPayload(
      session,
      { jsonrpc: '2.0', id: 7, method: 'does/not/exist' },
      'conn-1',
    );
    expect((response as { error: { code: number } }).error.code).toBe(-32601);
  });

  it('answers a notification with 202 and no body', async () => {
    const session = freshSession();
    const outcome = await handleMcpPayload(
      session,
      { jsonrpc: '2.0', method: 'notifications/initialized' },
      'conn-1',
    );
    expect(outcome.response).toBeNull();
    expect(outcome.httpStatus).toBe(202);
  });

  it('handles a batch and rejects an oversized one', async () => {
    const session = freshSession();
    const batch = await handleMcpPayload(
      session,
      [
        { jsonrpc: '2.0', id: 1, method: 'ping' },
        { jsonrpc: '2.0', id: 2, method: 'ping' },
      ],
      'conn-1',
    );
    expect(Array.isArray(batch.response)).toBe(true);
    expect((batch.response as unknown[]).length).toBe(2);

    const oversized = await handleMcpPayload(
      session,
      Array.from({ length: 40 }, (_, index) => ({ jsonrpc: '2.0', id: index, method: 'ping' })),
      'conn-1',
    );
    expect(oversized.httpStatus).toBe(400);
  });

  it('rejects a malformed JSON-RPC message without throwing', async () => {
    const session = freshSession();
    const { response } = await handleMcpPayload(session, { id: 1, method: 'ping' }, 'conn-1');
    expect((response as { error: { code: number } }).error.code).toBe(-32600);
  });
});
