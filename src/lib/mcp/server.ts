import { z } from 'zod';
import { zodToJsonSchema } from 'zod-to-json-schema';
import { getConfig } from '../config';
import type { SessionRecord } from '../sessions/types';
import { invokeTool } from '../tools/invoke';
import { type ToolDefinition } from '../tools/registry';
import { listableTools } from './tool-availability';
import { listResources, readResource } from './resources';

/**
 * Remote MCP server over Streamable HTTP.
 *
 * The transport is a single POST endpoint that accepts JSON-RPC 2.0 and answers
 * with `application/json`. That is a conformant Streamable HTTP server response —
 * SSE is only required when the server needs to stream, and Clovyre's tool calls
 * are request/response.
 */

export const MCP_PROTOCOL_VERSION = '2025-06-18';
const SUPPORTED_PROTOCOL_VERSIONS = ['2025-06-18', '2025-03-26', '2024-11-05'];

export const JsonRpcErrorCodes = {
  PARSE_ERROR: -32700,
  INVALID_REQUEST: -32600,
  METHOD_NOT_FOUND: -32601,
  INVALID_PARAMS: -32602,
  INTERNAL_ERROR: -32603,
} as const;

const jsonRpcIdSchema = z.union([z.string(), z.number(), z.null()]);

const jsonRpcRequestSchema = z.object({
  jsonrpc: z.literal('2.0'),
  id: jsonRpcIdSchema.optional(),
  method: z.string().min(1).max(128),
  params: z.unknown().optional(),
});

export type JsonRpcRequest = z.infer<typeof jsonRpcRequestSchema>;

export interface JsonRpcResponse {
  jsonrpc: '2.0';
  id: string | number | null;
  result?: unknown;
  error?: { code: number; message: string; data?: unknown };
}

export interface McpHandlerResult {
  /** Null when the payload was a notification and no response is owed. */
  readonly response: JsonRpcResponse | JsonRpcResponse[] | null;
  readonly httpStatus: number;
}

function ok(id: string | number | null, result: unknown): JsonRpcResponse {
  return { jsonrpc: '2.0', id, result };
}

function fail(
  id: string | number | null,
  code: number,
  message: string,
  data?: unknown,
): JsonRpcResponse {
  return {
    jsonrpc: '2.0',
    id,
    error: data === undefined ? { code, message } : { code, message, data },
  };
}

/** JSON Schema for a tool, derived from its Zod definition. */
export function toolInputJsonSchema(definition: ToolDefinition): Record<string, unknown> {
  const schema = zodToJsonSchema(definition.inputSchema, {
    target: 'jsonSchema7',
    $refStrategy: 'none',
  }) as Record<string, unknown>;
  // MCP clients expect a plain object schema at the top level.
  if (schema.type !== 'object') {
    return { type: 'object', properties: {}, additionalProperties: false };
  }
  delete schema.$schema;
  return schema;
}

function describeTool(definition: ToolDefinition, availabilityNote: string | null) {
  return {
    name: definition.name,
    title: definition.title,
    description: availabilityNote
      ? `${definition.description}\n\nCurrently unavailable: ${availabilityNote}`
      : definition.description,
    inputSchema: toolInputJsonSchema(definition),
    annotations: {
      title: definition.title,
      readOnlyHint: definition.readOnly,
      destructiveHint: !definition.readOnly,
      openWorldHint: !definition.local,
    },
  };
}

/** Wraps a structured payload in the MCP content shape. */
function toolSuccess(payload: unknown): Record<string, unknown> {
  const text = JSON.stringify(payload, null, 2);
  return {
    content: [{ type: 'text', text }],
    structuredContent:
      typeof payload === 'object' && payload !== null && !Array.isArray(payload)
        ? (payload as Record<string, unknown>)
        : { value: payload },
    isError: false,
  };
}

/**
 * Tool-level failures are reported as successful JSON-RPC responses carrying
 * `isError: true`, which is what the MCP specification asks for: the agent should
 * see and reason about the failure rather than treat it as a protocol fault.
 */
function toolFailure(code: string, message: string, detail?: unknown): Record<string, unknown> {
  const payload = detail === undefined ? { code, message } : { code, message, detail };
  return {
    content: [{ type: 'text', text: JSON.stringify(payload, null, 2) }],
    structuredContent: payload,
    isError: true,
  };
}

async function callTool(
  session: SessionRecord,
  toolName: string,
  rawArguments: unknown,
): Promise<Record<string, unknown>> {
  const result = await invokeTool(session, toolName, rawArguments, 'mcp');
  if (!result.ok) {
    return toolFailure(result.code, result.message, {
      ...(result.detail === undefined ? {} : { detail: result.detail }),
      ...(result.commandId ? { commandId: result.commandId } : {}),
      durationMs: result.durationMs,
    });
  }
  return toolSuccess({
    ...(result.commandId ? { commandId: result.commandId } : {}),
    durationMs: result.durationMs,
    truncated: result.truncated,
    data: result.data,
  });
}

/** Handles one JSON-RPC message (request or notification). */
async function handleSingle(
  session: SessionRecord,
  request: JsonRpcRequest,
  connectionId: string,
): Promise<JsonRpcResponse | null> {
  const id = request.id ?? null;
  const isNotification = request.id === undefined;

  switch (request.method) {
    case 'initialize': {
      const params = (request.params ?? {}) as {
        protocolVersion?: string;
        clientInfo?: { name?: string; version?: string };
      };
      const negotiated = SUPPORTED_PROTOCOL_VERSIONS.includes(params.protocolVersion ?? '')
        ? params.protocolVersion!
        : MCP_PROTOCOL_VERSION;

      const connection = session.mcpConnections.get(connectionId);
      if (connection) {
        connection.clientName = params.clientInfo?.name ?? null;
        connection.clientVersion = params.clientInfo?.version ?? null;
        connection.protocolVersion = negotiated;
      }
      session.audit.record({
        kind: 'mcp_connected',
        actor: 'mcp',
        message: `MCP client "${params.clientInfo?.name ?? 'unknown'}" initialised (protocol ${negotiated}).`,
      });

      return ok(id, {
        protocolVersion: negotiated,
        capabilities: { tools: { listChanged: false }, resources: { listChanged: true } },
        serverInfo: {
          name: 'clovyre-mcp',
          title: 'Clovyre MCP',
          version: getConfig().version,
        },
        instructions:
          'Clovyre bridges a live Roblox client to this agent. Only state replicated to that client is ' +
          'reachable: server scripts, ServerStorage, ServerScriptService and server memory are not. Start ' +
          'with clovyre_session_info to confirm the client is connected, then clovyre_get_services to orient, ' +
          'or attach the clovyre://session and clovyre://services resources instead. Script sources may be ' +
          'decompiled and are best-effort, not guaranteed originals. To observe change over time, install a ' +
          'watcher with clovyre_watch_start and poll clovyre_get_watch_events rather than re-reading the same ' +
          'instance repeatedly.',
      });
    }

    case 'notifications/initialized':
    case 'notifications/cancelled':
    case 'notifications/roots/list_changed':
      return null;

    case 'ping':
      return isNotification ? null : ok(id, {});

    case 'tools/list': {
      const tools = listableTools(session).map((entry) =>
        describeTool(entry.definition, entry.available ? null : entry.detail),
      );
      return ok(id, { tools });
    }

    case 'tools/call': {
      const params = (request.params ?? {}) as { name?: unknown; arguments?: unknown };
      if (typeof params.name !== 'string') {
        return fail(id, JsonRpcErrorCodes.INVALID_PARAMS, 'tools/call requires a string "name".');
      }
      const result = await callTool(session, params.name, params.arguments);
      return ok(id, result);
    }

    case 'resources/list':
      return ok(id, { resources: listResources(session) });

    case 'resources/read': {
      const params = (request.params ?? {}) as { uri?: unknown };
      if (typeof params.uri !== 'string') {
        return fail(
          id,
          JsonRpcErrorCodes.INVALID_PARAMS,
          'resources/read requires a string "uri".',
        );
      }
      try {
        const contents = await readResource(session, params.uri);
        return ok(id, { contents: [contents] });
      } catch (error) {
        return fail(
          id,
          JsonRpcErrorCodes.INVALID_PARAMS,
          error instanceof Error ? error.message : 'That resource could not be read.',
        );
      }
    }

    case 'resources/templates/list':
      return ok(id, { resourceTemplates: [] });
    case 'prompts/list':
      return ok(id, { prompts: [] });

    default:
      if (isNotification) return null;
      return fail(id, JsonRpcErrorCodes.METHOD_NOT_FOUND, `Unknown method: ${request.method}`);
  }
}

/**
 * Entry point used by the /mcp route. `body` is the already-parsed JSON payload;
 * authentication and session resolution happen before this is called.
 */
export async function handleMcpPayload(
  session: SessionRecord,
  body: unknown,
  connectionId: string,
): Promise<McpHandlerResult> {
  const messages = Array.isArray(body) ? body : [body];
  if (messages.length === 0) {
    return {
      response: fail(null, JsonRpcErrorCodes.INVALID_REQUEST, 'Empty JSON-RPC batch.'),
      httpStatus: 400,
    };
  }
  if (messages.length > 32) {
    return {
      response: fail(null, JsonRpcErrorCodes.INVALID_REQUEST, 'Batch too large (max 32 messages).'),
      httpStatus: 400,
    };
  }

  const responses: JsonRpcResponse[] = [];
  for (const message of messages) {
    const parsed = jsonRpcRequestSchema.safeParse(message);
    if (!parsed.success) {
      responses.push(
        fail(
          typeof (message as { id?: unknown } | null)?.id === 'string' ||
            typeof (message as { id?: unknown } | null)?.id === 'number'
            ? (message as { id: string | number }).id
            : null,
          JsonRpcErrorCodes.INVALID_REQUEST,
          'Malformed JSON-RPC message.',
        ),
      );
      continue;
    }
    try {
      const response = await handleSingle(session, parsed.data, connectionId);
      if (response) responses.push(response);
    } catch (error) {
      responses.push(
        fail(
          parsed.data.id ?? null,
          JsonRpcErrorCodes.INTERNAL_ERROR,
          error instanceof Error ? error.message : 'Internal Clovyre error.',
        ),
      );
    }
  }

  if (responses.length === 0) {
    // Every message was a notification: HTTP 202 with no body.
    return { response: null, httpStatus: 202 };
  }
  return {
    response: Array.isArray(body) ? responses : responses[0]!,
    httpStatus: 200,
  };
}
