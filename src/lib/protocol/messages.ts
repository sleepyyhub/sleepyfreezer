import { z } from 'zod';

/**
 * Versioned Clovyre WebSocket protocol.
 *
 * Both directions are validated with Zod on the backend. Unknown message types
 * and oversized payloads are rejected by the gateway before reaching this layer.
 */

export const PROTOCOL_VERSION = 1;

const protocolVersion = z.literal(PROTOCOL_VERSION);

/** Optional executor capabilities the client probes for at startup. */
export const CAPABILITY_NAMES = [
  'websocket',
  'decompile',
  'getscriptbytecode',
  'getloadedmodules',
  'getconnections',
  'getgc',
  'getsenv',
  'getgenv',
  'identifyexecutor',
  'getcustomasset',
  'loadstring',
  'setclipboard',
  'gethui',
  'hookmetamethod',
  'getnamecallmethod',
] as const;

export type CapabilityName = (typeof CAPABILITY_NAMES)[number];

export const capabilitySchema = z.enum(CAPABILITY_NAMES);

export const capabilityMapSchema = z.record(capabilitySchema, z.boolean());

export type CapabilityMap = Partial<Record<CapabilityName, boolean>>;

export const clientMetadataSchema = z.object({
  placeId: z.number().optional(),
  universeId: z.number().nullable().optional(),
  jobId: z.string().max(128).optional(),
  gameName: z.string().max(256).nullable().optional(),
  localPlayer: z
    .object({
      name: z.string().max(64),
      displayName: z.string().max(64).optional(),
      userId: z.number(),
      accountAge: z.number().optional(),
    })
    .nullable()
    .optional(),
  executor: z.string().max(128).nullable().optional(),
  clientVersion: z.string().max(64).optional(),
  luaVersion: z.string().max(64).optional(),
});

export type ClientMetadata = z.infer<typeof clientMetadataSchema>;

/* ------------------------------------------------------------------ */
/* Roblox -> server                                                     */
/* ------------------------------------------------------------------ */

export const helloMessageSchema = z.object({
  protocolVersion,
  type: z.literal('hello'),
  sessionId: z.string().max(64),
  token: z.string().max(256),
  capabilities: capabilityMapSchema,
  metadata: clientMetadataSchema,
  bridgeVersion: z.string().max(32).optional(),
});

export const heartbeatMessageSchema = z.object({
  protocolVersion,
  type: z.literal('heartbeat'),
  sentAt: z.number().optional(),
});

export const commandErrorSchema = z.object({
  code: z.string().max(64),
  message: z.string().max(4096),
  detail: z.unknown().optional(),
});

export type CommandError = z.infer<typeof commandErrorSchema>;

export const resultMessageSchema = z.object({
  protocolVersion,
  type: z.literal('result'),
  id: z.string().max(64),
  ok: z.boolean(),
  result: z.unknown().optional(),
  error: commandErrorSchema.optional(),
  truncated: z.boolean().optional(),
  durationMs: z.number().optional(),
});

export const eventMessageSchema = z.object({
  protocolVersion,
  type: z.literal('event'),
  event: z.string().max(64),
  data: z.unknown().optional(),
});

export const logMessageSchema = z.object({
  protocolVersion,
  type: z.literal('log'),
  level: z.enum(['trace', 'debug', 'info', 'warn', 'error']),
  message: z.string().max(8192),
  at: z.number().optional(),
});

export const capabilitiesUpdateMessageSchema = z.object({
  protocolVersion,
  type: z.literal('capabilities_update'),
  capabilities: capabilityMapSchema,
});

export const goodbyeMessageSchema = z.object({
  protocolVersion,
  type: z.literal('goodbye'),
  reason: z.string().max(256).optional(),
});

export const clientMessageSchema = z.discriminatedUnion('type', [
  helloMessageSchema,
  heartbeatMessageSchema,
  resultMessageSchema,
  eventMessageSchema,
  logMessageSchema,
  capabilitiesUpdateMessageSchema,
  goodbyeMessageSchema,
]);

export type ClientMessage = z.infer<typeof clientMessageSchema>;
export type HelloMessage = z.infer<typeof helloMessageSchema>;
export type ResultMessage = z.infer<typeof resultMessageSchema>;

/* ------------------------------------------------------------------ */
/* Server -> Roblox                                                     */
/* ------------------------------------------------------------------ */

export interface HelloAckMessage {
  protocolVersion: typeof PROTOCOL_VERSION;
  type: 'hello_ack';
  sessionId: string;
  heartbeatIntervalMs: number;
  maxPayloadBytes: number;
  /** Null when the session has no timed expiry. */
  expiresAt: number | null;
  serverTime: number;
}

export interface CommandMessage {
  protocolVersion: typeof PROTOCOL_VERSION;
  type: 'command';
  id: string;
  tool: string;
  arguments: Record<string, unknown>;
  timeoutMs: number;
}

export interface CancelCommandMessage {
  protocolVersion: typeof PROTOCOL_VERSION;
  type: 'cancel_command';
  id: string;
}

export interface SessionRevokedMessage {
  protocolVersion: typeof PROTOCOL_VERSION;
  type: 'session_revoked';
  reason: string;
}

export interface SessionExpiredMessage {
  protocolVersion: typeof PROTOCOL_VERSION;
  type: 'session_expired';
  expiredAt: number | null;
}

export interface HeartbeatAckMessage {
  protocolVersion: typeof PROTOCOL_VERSION;
  type: 'heartbeat_ack';
  serverTime: number;
}

export interface ServerErrorMessage {
  protocolVersion: typeof PROTOCOL_VERSION;
  type: 'error';
  code: string;
  message: string;
}

export type ServerMessage =
  | HelloAckMessage
  | CommandMessage
  | CancelCommandMessage
  | SessionRevokedMessage
  | SessionExpiredMessage
  | HeartbeatAckMessage
  | ServerErrorMessage;

/** Canonical error codes shared by the gateway, broker and MCP layer. */
export const ErrorCodes = {
  INVALID_MESSAGE: 'INVALID_MESSAGE',
  PROTOCOL_VERSION_MISMATCH: 'PROTOCOL_VERSION_MISMATCH',
  PAYLOAD_TOO_LARGE: 'PAYLOAD_TOO_LARGE',
  UNAUTHORIZED: 'UNAUTHORIZED',
  SESSION_NOT_FOUND: 'SESSION_NOT_FOUND',
  SESSION_EXPIRED: 'SESSION_EXPIRED',
  SESSION_REVOKED: 'SESSION_REVOKED',
  CLIENT_NOT_CONNECTED: 'CLIENT_NOT_CONNECTED',
  COMMAND_TIMEOUT: 'COMMAND_TIMEOUT',
  COMMAND_CANCELLED: 'COMMAND_CANCELLED',
  COMMAND_NOT_FOUND: 'COMMAND_NOT_FOUND',
  CAPABILITY_UNAVAILABLE: 'CAPABILITY_UNAVAILABLE',
  PRIVILEGE_REQUIRED: 'PRIVILEGE_REQUIRED',
  RATE_LIMITED: 'RATE_LIMITED',
  INSTANCE_NOT_FOUND: 'INSTANCE_NOT_FOUND',
  PROPERTY_NOT_ALLOWED: 'PROPERTY_NOT_ALLOWED',
  INVALID_ARGUMENTS: 'INVALID_ARGUMENTS',
  TOO_MANY_CONNECTIONS: 'TOO_MANY_CONNECTIONS',
  INTERNAL_ERROR: 'INTERNAL_ERROR',
} as const;

export type ErrorCode = (typeof ErrorCodes)[keyof typeof ErrorCodes];

/** Parses a raw frame, returning a typed message or a structured failure. */
export function parseClientMessage(
  raw: string,
): { ok: true; message: ClientMessage } | { ok: false; code: ErrorCode; message: string } {
  let json: unknown;
  try {
    json = JSON.parse(raw);
  } catch {
    return { ok: false, code: ErrorCodes.INVALID_MESSAGE, message: 'Frame is not valid JSON.' };
  }

  if (typeof json === 'object' && json !== null && 'protocolVersion' in json) {
    const version = (json as { protocolVersion: unknown }).protocolVersion;
    if (version !== PROTOCOL_VERSION) {
      return {
        ok: false,
        code: ErrorCodes.PROTOCOL_VERSION_MISMATCH,
        message: `This gateway speaks protocol version ${PROTOCOL_VERSION}.`,
      };
    }
  }

  const parsed = clientMessageSchema.safeParse(json);
  if (!parsed.success) {
    const first = parsed.error.issues[0];
    return {
      ok: false,
      code: ErrorCodes.INVALID_MESSAGE,
      message: first
        ? `${first.path.join('.') || 'message'}: ${first.message}`
        : 'Invalid message.',
    };
  }
  return { ok: true, message: parsed.data };
}
