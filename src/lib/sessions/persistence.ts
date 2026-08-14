import { Pool } from 'pg';
import { AuditLog } from '../audit/audit-log';
import { getConfig } from '../config';
import type { CapabilityMap, ClientMetadata } from '../protocol/messages';
import {
  createObservations,
  createSettings,
  type PrivilegeState,
  type SessionRecord,
  type SessionSettings,
} from './types';

/**
 * Session persistence.
 *
 * Sessions are the unit a user configures their agent against, so they have to
 * outlive a restart or a redeploy — otherwise the MCP configuration silently
 * breaks every time the service ships.
 *
 * What persists is the durable identity of a session: its id, credential
 * digests, lifecycle, privilege grants and last-known client metadata. What does
 * not persist is anything that describes a live connection — the WebSocket
 * transport, pending commands, observation buffers, MCP connections and the
 * audit trail. Those are properties of a process that just died, and pretending
 * otherwise would show the dashboard connections that do not exist. They rebuild
 * naturally when the Roblox client reconnects.
 *
 * Writes are fire-and-forget so the rest of the store keeps its synchronous API;
 * a failed write is logged and the in-memory copy remains authoritative for the
 * life of the process.
 */

const SCHEMA = `
CREATE TABLE IF NOT EXISTS clovyre_sessions (
  id                   TEXT PRIMARY KEY,
  created_at           BIGINT NOT NULL,
  sequence             BIGINT NOT NULL,
  expires_at           BIGINT,
  terminated_at        BIGINT,
  termination_reason   TEXT,
  credentials          JSONB NOT NULL,
  csrf_token           TEXT NOT NULL,
  privileges           JSONB NOT NULL,
  capabilities         JSONB NOT NULL DEFAULT '{}'::JSONB,
  metadata             JSONB,
  settings             JSONB NOT NULL DEFAULT '{}'::JSONB,
  creator_address_hash TEXT NOT NULL,
  updated_at           BIGINT NOT NULL
);
CREATE INDEX IF NOT EXISTS clovyre_sessions_terminated_idx
  ON clovyre_sessions (terminated_at);

-- Added after the table shipped, so existing deployments need the column too.
-- CREATE TABLE IF NOT EXISTS leaves an existing table untouched.
ALTER TABLE clovyre_sessions
  ADD COLUMN IF NOT EXISTS settings JSONB NOT NULL DEFAULT '{}'::JSONB;
`;

type PoolGlobal = typeof globalThis & { __clovyrePool?: Pool | null };

/** Null when no DATABASE_URL is configured; the store then runs in memory only. */
export function getPool(): Pool | null {
  const store = globalThis as PoolGlobal;
  if (store.__clovyrePool !== undefined) return store.__clovyrePool;

  const url = getConfig().databaseUrl;
  if (!url) {
    store.__clovyrePool = null;
    return null;
  }

  store.__clovyrePool = new Pool({
    connectionString: url,
    max: 4,
    idleTimeoutMillis: 30_000,
    connectionTimeoutMillis: 10_000,
    // Render's managed Postgres terminates TLS with its own chain.
    ssl: url.includes('localhost') ? false : { rejectUnauthorized: false },
  });

  store.__clovyrePool.on('error', (error) => {
    console.error('[clovyre] postgres pool error:', error.message);
  });

  return store.__clovyrePool;
}

export function persistenceEnabled(): boolean {
  return getPool() !== null;
}

export async function initialiseSchema(): Promise<void> {
  const pool = getPool();
  if (!pool) return;
  await pool.query(SCHEMA);
}

interface SessionRow {
  id: string;
  created_at: string;
  sequence: string;
  expires_at: string | null;
  terminated_at: string | null;
  termination_reason: string | null;
  credentials: SessionRecord['credentials'];
  csrf_token: string;
  privileges: Record<string, PrivilegeState>;
  capabilities: CapabilityMap;
  metadata: ClientMetadata | null;
  settings: Partial<SessionSettings> | null;
  creator_address_hash: string;
}

const emptyPrivilege = (): PrivilegeState => ({
  enabled: false,
  expiresAt: null,
  enabledAt: null,
});

function rowToSession(row: SessionRow): SessionRecord {
  const stored = row.privileges ?? {};
  return {
    id: row.id,
    createdAt: Number(row.created_at),
    sequence: Number(row.sequence),
    expiresAt: row.expires_at === null ? null : Number(row.expires_at),
    terminatedAt: row.terminated_at === null ? null : Number(row.terminated_at),
    terminationReason: row.termination_reason,
    credentials: row.credentials,
    csrfToken: row.csrf_token,
    privileges: {
      execute_luau: stored.execute_luau ?? emptyPrivilege(),
      executor_globals: stored.executor_globals ?? emptyPrivilege(),
      mutations: stored.mutations ?? emptyPrivilege(),
      remote_spy: stored.remote_spy ?? emptyPrivilege(),
    },
    capabilities: row.capabilities ?? {},
    metadata: row.metadata,
    settings: { ...createSettings(), ...(row.settings ?? {}) },
    creatorAddressHash: row.creator_address_hash,

    // Connection-scoped state never survives the process that owned it.
    robloxClients: new Map(),
    mcpConnections: new Map(),
    commands: new Map(),
    commandOrder: [],
    audit: new AuditLog(),
    observations: createObservations(),
  };
}

/** Loads every session that has not been terminated. */
export async function loadSessions(): Promise<SessionRecord[]> {
  const pool = getPool();
  if (!pool) return [];

  const result = await pool.query<SessionRow>(
    `SELECT id, created_at, sequence, expires_at, terminated_at, termination_reason,
            credentials, csrf_token, privileges, capabilities, metadata, settings,
            creator_address_hash
       FROM clovyre_sessions
      WHERE terminated_at IS NULL
      ORDER BY sequence ASC`,
  );

  return result.rows.map(rowToSession);
}

/** Write-through upsert. Never throws: persistence failures must not break a request. */
export function persistSession(session: SessionRecord): void {
  const pool = getPool();
  if (!pool) return;

  const values = [
    session.id,
    session.createdAt,
    session.sequence,
    session.expiresAt,
    session.terminatedAt,
    session.terminationReason,
    JSON.stringify(session.credentials),
    session.csrfToken,
    JSON.stringify(session.privileges),
    JSON.stringify(session.capabilities),
    session.metadata === null ? null : JSON.stringify(session.metadata),
    JSON.stringify(session.settings),
    session.creatorAddressHash,
    Date.now(),
  ];

  pool
    .query(
      `INSERT INTO clovyre_sessions (
         id, created_at, sequence, expires_at, terminated_at, termination_reason,
         credentials, csrf_token, privileges, capabilities, metadata, settings,
         creator_address_hash, updated_at
       ) VALUES ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14)
       ON CONFLICT (id) DO UPDATE SET
         expires_at = EXCLUDED.expires_at,
         terminated_at = EXCLUDED.terminated_at,
         termination_reason = EXCLUDED.termination_reason,
         credentials = EXCLUDED.credentials,
         privileges = EXCLUDED.privileges,
         capabilities = EXCLUDED.capabilities,
         metadata = EXCLUDED.metadata,
         settings = EXCLUDED.settings,
         updated_at = EXCLUDED.updated_at`,
      values,
    )
    .catch((error: unknown) => {
      console.error(
        '[clovyre] failed to persist session:',
        error instanceof Error ? error.message : error,
      );
    });
}

/** Removes a session permanently. Used by the sweeper once a session has ended. */
export function deleteSession(sessionId: string): void {
  const pool = getPool();
  if (!pool) return;

  pool
    .query('DELETE FROM clovyre_sessions WHERE id = $1', [sessionId])
    .catch((error: unknown) => {
      console.error(
        '[clovyre] failed to delete session:',
        error instanceof Error ? error.message : error,
      );
    });
}

export async function closePool(): Promise<void> {
  const store = globalThis as PoolGlobal;
  const pool = store.__clovyrePool;
  if (!pool) return;
  store.__clovyrePool = undefined;
  await pool.end();
}
