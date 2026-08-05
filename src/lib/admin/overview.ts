import { getConfig } from '../config';
import { getSessionBroker } from '../sessions/broker';
import { getSessionStore } from '../sessions/store';
import { sessionStatus, type SessionRecord } from '../sessions/types';

/**
 * Operator console data.
 *
 * Deliberately narrow. This view answers exactly two questions — who is
 * connected, and what agent are they driving it with — and nothing else.
 *
 * It does NOT expose, and must not grow to expose:
 *  - any credential or credential fingerprint;
 *  - tool arguments, results, or anything a user's agent read from their game;
 *  - the session audit trail;
 *  - any way to act on a session.
 *
 * That boundary is the difference between operating a service and surveilling
 * the people using it. Keep it.
 */

export interface ConnectedRobloxAccount {
  readonly username: string;
  readonly displayName: string | null;
  readonly userId: number;
  readonly accountAge: number | null;
}

export interface ConnectedAgent {
  /** Name the MCP client reported at initialize, e.g. "claude-ai". */
  readonly client: string;
  readonly version: string | null;
  readonly protocolVersion: string | null;
  readonly connectedAt: string;
  readonly lastSeenAt: string;
}

export interface ConnectedSessionRow {
  readonly sessionId: string;
  readonly status: 'active' | 'expired' | 'terminated';
  readonly robloxConnected: boolean;
  readonly account: ConnectedRobloxAccount | null;
  readonly executor: string | null;
  readonly placeId: number | null;
  readonly gameName: string | null;
  readonly agents: readonly ConnectedAgent[];
  readonly startedAt: string;
  readonly ageSeconds: number;
  readonly expiresInSeconds: number;
}

export interface AdminOverview {
  readonly generatedAt: string;
  readonly service: {
    readonly version: string;
    readonly uptimeSeconds: number;
    readonly sessionTtlMinutes: number;
  };
  readonly totals: {
    /** Every one of these is measured, never configured. */
    readonly sessions: number;
    readonly activeSessions: number;
    readonly robloxConnected: number;
    readonly agentConnections: number;
    readonly distinctAccounts: number;
  };
  readonly rows: readonly ConnectedSessionRow[];
}

function toRow(session: SessionRecord, now: number): ConnectedSessionRow {
  const player = session.metadata?.localPlayer ?? null;

  return {
    sessionId: session.id,
    status: sessionStatus(session, now),
    robloxConnected: getSessionBroker().isConnected(session.id) && session.roblox !== null,
    account: player
      ? {
          username: player.name,
          displayName: player.displayName ?? null,
          userId: player.userId,
          accountAge: player.accountAge ?? null,
        }
      : null,
    executor: session.metadata?.executor ?? null,
    placeId: session.metadata?.placeId ?? null,
    gameName: session.metadata?.gameName ?? null,
    agents: [...session.mcpConnections.values()].map((connection) => ({
      client: connection.clientName ?? 'unidentified client',
      version: connection.clientVersion,
      protocolVersion: connection.protocolVersion,
      connectedAt: new Date(connection.connectedAt).toISOString(),
      lastSeenAt: new Date(connection.lastSeenAt).toISOString(),
    })),
    startedAt: new Date(session.createdAt).toISOString(),
    ageSeconds: Math.floor((now - session.createdAt) / 1000),
    expiresInSeconds: Math.max(0, Math.floor((session.expiresAt - now) / 1000)),
  };
}

export function buildAdminOverview(now = Date.now()): AdminOverview {
  const config = getConfig();
  const store = getSessionStore();
  const stats = store.stats(now);

  const rows: ConnectedSessionRow[] = [];
  const accounts = new Set<number>();

  // The store owns its map; snapshotting through the public stats plus a scan
  // keeps this module read-only with respect to session state.
  for (const session of store.listAll()) {
    const row = toRow(session, now);
    if (row.status !== 'active') continue;
    rows.push(row);
    if (row.account) accounts.add(row.account.userId);
  }

  // Most recently started first: what just connected is what an operator looks at.
  rows.sort((a, b) => Date.parse(b.startedAt) - Date.parse(a.startedAt));

  return {
    generatedAt: new Date(now).toISOString(),
    service: {
      version: config.version,
      uptimeSeconds: Math.floor(process.uptime()),
      sessionTtlMinutes: Math.round(config.sessionTtlMs / 60_000),
    },
    totals: {
      sessions: stats.total,
      activeSessions: stats.active,
      robloxConnected: stats.robloxConnected,
      agentConnections: stats.mcpConnections,
      distinctAccounts: accounts.size,
    },
    rows,
  };
}
