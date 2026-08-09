import { randomBytes } from 'node:crypto';
import { z } from 'zod';

/**
 * Runtime configuration for Clovyre.
 *
 * Every value is read once, validated with Zod, and frozen on globalThis so the
 * Next.js bundle and the custom Node server observe the same configuration
 * object even though they load modules through different registries.
 */

const intFromEnv = (fallback: number, min: number, max: number) =>
  z
    .string()
    .optional()
    .transform((value) => (value === undefined || value === '' ? fallback : Number(value)))
    .pipe(z.number().int().min(min).max(max));

const boolFromEnv = (fallback: boolean) =>
  z
    .string()
    .optional()
    .transform((value) => {
      if (value === undefined || value === '') return fallback;
      return value === '1' || value.toLowerCase() === 'true';
    })
    .pipe(z.boolean());

const envSchema = z.object({
  NODE_ENV: z.enum(['development', 'test', 'production']).default('development'),
  PORT: intFromEnv(3000, 1, 65535),
  PUBLIC_BASE_URL: z.string().url().optional(),
  SESSION_SECRET: z.string().min(16).optional(),
  TOKEN_HASH_SECRET: z.string().min(16).optional(),
  /** Session lifetime in minutes. 0 means sessions never expire on a timer. */
  SESSION_TTL_MINUTES: intFromEnv(60, 0, 7 * 24 * 60),
  MAX_WS_PAYLOAD_BYTES: intFromEnv(512 * 1024, 4096, 8 * 1024 * 1024),
  MAX_COMMAND_TIMEOUT_MS: intFromEnv(30_000, 1000, 120_000),
  MAX_SCRIPT_SOURCE_BYTES: intFromEnv(256 * 1024, 1024, 4 * 1024 * 1024),
  ENABLE_EXECUTE_LUAU_FEATURE: boolFromEnv(true),
  ENABLE_MUTATION_TOOLS_FEATURE: boolFromEnv(true),
  ENABLE_REMOTE_SPY_FEATURE: boolFromEnv(true),
  PRIVILEGE_TTL_MINUTES: intFromEnv(15, 1, 120),
  /**
   * Lifetime of the mutation grant. 0 means it stands until the owner turns it
   * off. Mutation tools write local client state only, so a standing grant is a
   * far smaller exposure than one for arbitrary Luau execution.
   */
  MUTATION_PRIVILEGE_TTL_MINUTES: intFromEnv(0, 0, 24 * 60),
  MAX_SESSIONS: intFromEnv(500, 1, 100_000),
  /**
   * Postgres connection string. When unset the store runs in memory only and
   * sessions do not survive a restart, which the health endpoint reports.
   */
  DATABASE_URL: z.string().min(1).optional(),
  /** Sessions one address may create per minute. Raised only for test runs. */
  SESSION_CREATE_PER_MINUTE: intFromEnv(12, 1, 10_000),
  /**
   * Operator console credential. When unset the console does not exist at all:
   * every one of its routes answers 404, indistinguishable from a path that was
   * never implemented.
   */
  ADMIN_TOKEN: z.string().min(24).optional(),
  /** How long an operator console sign-in lasts. */
  ADMIN_SESSION_MINUTES: intFromEnv(120, 5, 1440),
});

export interface ClovyreConfig {
  readonly nodeEnv: 'development' | 'test' | 'production';
  readonly isProduction: boolean;
  readonly port: number;
  readonly publicBaseUrl: string | null;
  readonly sessionSecret: string;
  readonly tokenHashSecret: string;
  /** Null when sessions never expire on a timer. */
  readonly sessionTtlMs: number | null;
  readonly maxWsPayloadBytes: number;
  readonly maxCommandTimeoutMs: number;
  readonly maxScriptSourceBytes: number;
  readonly executeLuauFeatureEnabled: boolean;
  readonly mutationToolsFeatureEnabled: boolean;
  readonly remoteSpyFeatureEnabled: boolean;
  readonly privilegeTtlMs: number;
  /** Null when the mutation grant never expires on a timer. */
  readonly mutationPrivilegeTtlMs: number | null;
  readonly maxSessions: number;
  readonly databaseUrl: string | null;
  readonly sessionCreatePerMinute: number;
  /** Null when no operator console credential is configured. */
  readonly adminToken: string | null;
  readonly adminSessionMs: number;
  readonly adminEnabled: boolean;
  /** True when secrets were generated at boot instead of supplied by the environment. */
  readonly usingEphemeralSecrets: boolean;
  readonly version: string;
}

const APP_VERSION = '0.1.0';

function build(): ClovyreConfig {
  const parsed = envSchema.safeParse(process.env);
  if (!parsed.success) {
    const detail = parsed.error.issues
      .map((issue) => `${issue.path.join('.') || '(root)'}: ${issue.message}`)
      .join('; ');
    throw new Error(`Invalid Clovyre environment configuration -> ${detail}`);
  }
  const env = parsed.data;
  const isProduction = env.NODE_ENV === 'production';

  const usingEphemeralSecrets = !env.SESSION_SECRET || !env.TOKEN_HASH_SECRET;
  if (usingEphemeralSecrets && isProduction) {
    // Ephemeral secrets are survivable (sessions are in-memory anyway) but the
    // operator needs to know that a restart invalidates every issued cookie.
    console.warn(
      '[clovyre] SESSION_SECRET / TOKEN_HASH_SECRET are not set. Generating ephemeral secrets; ' +
        'all sessions and owner cookies will be invalidated on restart.',
    );
  }

  return Object.freeze({
    nodeEnv: env.NODE_ENV,
    isProduction,
    port: env.PORT,
    publicBaseUrl: env.PUBLIC_BASE_URL ? env.PUBLIC_BASE_URL.replace(/\/+$/, '') : null,
    sessionSecret: env.SESSION_SECRET ?? randomBytes(32).toString('hex'),
    tokenHashSecret: env.TOKEN_HASH_SECRET ?? randomBytes(32).toString('hex'),
    sessionTtlMs: env.SESSION_TTL_MINUTES === 0 ? null : env.SESSION_TTL_MINUTES * 60_000,
    maxWsPayloadBytes: env.MAX_WS_PAYLOAD_BYTES,
    maxCommandTimeoutMs: env.MAX_COMMAND_TIMEOUT_MS,
    maxScriptSourceBytes: env.MAX_SCRIPT_SOURCE_BYTES,
    executeLuauFeatureEnabled: env.ENABLE_EXECUTE_LUAU_FEATURE,
    mutationToolsFeatureEnabled: env.ENABLE_MUTATION_TOOLS_FEATURE,
    remoteSpyFeatureEnabled: env.ENABLE_REMOTE_SPY_FEATURE,
    privilegeTtlMs: env.PRIVILEGE_TTL_MINUTES * 60_000,
    mutationPrivilegeTtlMs:
      env.MUTATION_PRIVILEGE_TTL_MINUTES === 0 ? null : env.MUTATION_PRIVILEGE_TTL_MINUTES * 60_000,
    maxSessions: env.MAX_SESSIONS,
    databaseUrl: env.DATABASE_URL ?? null,
    sessionCreatePerMinute: env.SESSION_CREATE_PER_MINUTE,
    adminToken: env.ADMIN_TOKEN ?? null,
    adminSessionMs: env.ADMIN_SESSION_MINUTES * 60_000,
    adminEnabled: Boolean(env.ADMIN_TOKEN),
    usingEphemeralSecrets,
    version: APP_VERSION,
  });
}

type ConfigGlobal = typeof globalThis & { __clovyreConfig?: ClovyreConfig };

export function getConfig(): ClovyreConfig {
  const store = globalThis as ConfigGlobal;
  if (!store.__clovyreConfig) {
    store.__clovyreConfig = build();
  }
  return store.__clovyreConfig;
}

/** Test-only reset so suites can exercise different environment shapes. */
export function resetConfigForTests(): void {
  delete (globalThis as ConfigGlobal).__clovyreConfig;
}

/**
 * Resolves the externally reachable origin. PUBLIC_BASE_URL wins; otherwise we
 * fall back to the request's forwarded host, which is what Render provides.
 */
export function resolvePublicBaseUrl(headers: { get(name: string): string | null }): string {
  const config = getConfig();
  if (config.publicBaseUrl) return config.publicBaseUrl;

  const forwardedHost = headers.get('x-forwarded-host') ?? headers.get('host');
  const forwardedProto =
    headers.get('x-forwarded-proto') ?? (config.isProduction ? 'https' : 'http');
  if (forwardedHost) {
    return `${forwardedProto.split(',')[0]!.trim()}://${forwardedHost.split(',')[0]!.trim()}`;
  }
  return `http://localhost:${config.port}`;
}

/** Converts an http(s) origin into the matching ws(s) origin. */
export function toWebSocketOrigin(baseUrl: string): string {
  return baseUrl.replace(/^http:/, 'ws:').replace(/^https:/, 'wss:');
}
