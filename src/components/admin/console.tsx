'use client';

import { useCallback, useEffect, useRef, useState } from 'react';
import type { AdminOverview, ConnectedSessionRow } from '@/lib/admin/overview';
import { EmptyState, ErrorNote, StatusDot, formatDuration, relativeTime } from '@/components/ui';

/**
 * Operator console.
 *
 * Shows who is connected and which agent they are driving Clovyre with. Every
 * number on this screen is measured from live state — there is no configured or
 * adjustable figure anywhere in this component, by design.
 */

const POLL_INTERVAL_MS = 5000;

export function AdminConsole({ bootstrapToken }: { bootstrapToken?: string }) {
  const [overview, setOverview] = useState<AdminOverview | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [query, setQuery] = useState('');
  const bootstrapped = useRef(false);

  const load = useCallback(async () => {
    // The secret is sent once, as a header, to trade it for the cookie. After
    // that every poll is cookie-authenticated and carries no credential.
    const useToken = Boolean(bootstrapToken) && !bootstrapped.current;
    try {
      const response = await fetch('/api/admin/overview', {
        cache: 'no-store',
        headers: useToken ? { 'x-clovyre-operator': bootstrapToken! } : undefined,
      });
      if (!response.ok) {
        setError('The operator session has ended. Re-open the console with your credential.');
        return;
      }
      bootstrapped.current = true;
      setOverview((await response.json()) as AdminOverview);
      setError(null);
    } catch {
      setError('Could not reach the service.');
    }
  }, [bootstrapToken]);

  useEffect(() => {
    const initial = setTimeout(() => void load(), 0);
    const timer = setInterval(() => void load(), POLL_INTERVAL_MS);
    return () => {
      clearTimeout(initial);
      clearInterval(timer);
    };
  }, [load]);

  // Strip the secret out of the address bar as soon as the cookie is set.
  useEffect(() => {
    if (!bootstrapToken || !overview) return;
    window.history.replaceState(null, '', '/admin');
  }, [bootstrapToken, overview]);

  const rows = filterRows(overview?.rows ?? [], query);

  return (
    <div className="cl-shell cl-rise py-10 sm:py-14">
      <header className="flex flex-wrap items-end justify-between gap-4">
        <div>
          <p className="cl-label">Operator console</p>
          <h1 className="mt-2 text-[28px] font-semibold tracking-[-0.02em] text-ink sm:text-[34px]">
            Connected sessions
          </h1>
        </div>
        <p className="text-[12px] text-ink-faint">
          {overview ? `Updated ${relativeTime(overview.generatedAt)}` : 'Loading…'}
          {overview ? ` · service up ${formatDuration(overview.service.uptimeSeconds)}` : ''}
        </p>
      </header>

      {error ? (
        <div className="mt-6">
          <ErrorNote message={error} onRetry={() => void load()} />
        </div>
      ) : null}

      {overview ? (
        <>
          <div className="mt-8 grid grid-cols-2 gap-3 sm:grid-cols-3 lg:grid-cols-5">
            <Stat label="Active sessions" value={overview.totals.activeSessions} />
            <Stat label="Roblox connected" value={overview.totals.robloxConnected} emphasis />
            <Stat label="Agent connections" value={overview.totals.agentConnections} />
            <Stat label="Distinct accounts" value={overview.totals.distinctAccounts} />
            <Stat label="Sessions in memory" value={overview.totals.sessions} />
          </div>

          <p className="mt-3 text-[11.5px] text-ink-faint">
            Every figure above is counted from live state. Sessions last{' '}
            {overview.service.sessionTtlMinutes} minutes and vanish on restart, so these are current
            occupancy, not totals over time.
          </p>

          <div className="mt-8">
            <input
              className="cl-input"
              placeholder="Filter by Roblox username, user id, agent or place…"
              value={query}
              onChange={(event) => setQuery(event.target.value)}
            />
          </div>

          <div className="mt-4">
            {rows.length === 0 ? (
              <EmptyState
                title={query ? 'No sessions match that filter.' : 'No active sessions right now.'}
                hint={
                  query
                    ? undefined
                    : 'Sessions appear here the moment someone creates one, and disappear when it expires.'
                }
              />
            ) : (
              <ul className="flex flex-col gap-3">
                {rows.map((row) => (
                  <SessionCard key={row.sessionId} row={row} />
                ))}
              </ul>
            )}
          </div>

          <p className="mt-10 text-[11.5px] leading-relaxed text-ink-faint">
            This console shows connection metadata only: the Roblox account a session reported and
            the agent connected to it. It does not expose credentials, and it cannot read what any
            agent inspected — that data belongs to the person whose session it is.
          </p>
        </>
      ) : null}
    </div>
  );
}

function filterRows(rows: readonly ConnectedSessionRow[], query: string): ConnectedSessionRow[] {
  const needle = query.trim().toLowerCase();
  if (!needle) return [...rows];
  return rows.filter((row) => {
    const haystack = [
      row.account?.username,
      row.account?.displayName,
      row.account ? String(row.account.userId) : null,
      row.executor,
      row.gameName,
      row.placeId ? String(row.placeId) : null,
      row.sessionId,
      ...row.agents.map((agent) => agent.client),
    ]
      .filter(Boolean)
      .join(' ')
      .toLowerCase();
    return haystack.includes(needle);
  });
}

function Stat({ label, value, emphasis }: { label: string; value: number; emphasis?: boolean }) {
  return (
    <div className="cl-surface p-4">
      <div className="cl-label">{label}</div>
      <div
        className={`mt-1.5 text-[26px] font-semibold tabular-nums ${
          emphasis ? 'text-clover-300' : 'text-ink'
        }`}
      >
        {value}
      </div>
    </div>
  );
}

function SessionCard({ row }: { row: ConnectedSessionRow }) {
  return (
    <li className="cl-surface p-4 sm:p-5">
      <div className="flex flex-wrap items-start justify-between gap-4">
        <div className="min-w-0">
          <div className="flex flex-wrap items-center gap-2">
            <StatusDot tone={row.robloxConnected ? 'live' : 'idle'} pulse={row.robloxConnected} />
            <span className="text-[15px] font-medium text-ink">
              {row.account ? row.account.username : 'No account reported'}
            </span>
            {row.account?.displayName && row.account.displayName !== row.account.username ? (
              <span className="text-[12.5px] text-ink-faint">“{row.account.displayName}”</span>
            ) : null}
          </div>
          <div className="mt-1.5 font-mono text-[11.5px] text-ink-faint">
            {row.account ? `user id ${row.account.userId}` : 'awaiting the Roblox handshake'}
            {row.account?.accountAge !== null && row.account?.accountAge !== undefined
              ? ` · account age ${row.account.accountAge}d`
              : ''}
          </div>
        </div>

        <div className="text-right text-[11.5px] text-ink-faint">
          <div>started {relativeTime(row.startedAt)}</div>
          <div>expires in {formatDuration(row.expiresInSeconds)}</div>
        </div>
      </div>

      <div className="mt-4 grid gap-4 sm:grid-cols-2">
        <div>
          <div className="cl-label mb-1.5">Executor</div>
          <div className="text-[13px] text-ink">{row.executor ?? '—'}</div>
          <div className="mt-2 text-[11.5px] text-ink-faint">
            {row.gameName ?? (row.placeId ? `place ${row.placeId}` : 'place unknown')}
          </div>
        </div>

        <div>
          <div className="cl-label mb-1.5">
            AI agent{row.agents.length === 1 ? '' : 's'} ({row.agents.length})
          </div>
          {row.agents.length === 0 ? (
            <div className="text-[13px] text-ink-faint">None connected</div>
          ) : (
            <ul className="flex flex-col gap-1.5">
              {row.agents.map((agent) => (
                <li key={agent.connectedAt + agent.client} className="text-[13px] text-ink">
                  {agent.client}
                  {agent.version ? (
                    <span className="text-ink-faint"> · {agent.version}</span>
                  ) : null}
                  <span className="text-ink-faint"> · seen {relativeTime(agent.lastSeenAt)}</span>
                </li>
              ))}
            </ul>
          )}
        </div>
      </div>

      <div className="mt-4 font-mono text-[11px] text-ink-faint">{row.sessionId}</div>
    </li>
  );
}
