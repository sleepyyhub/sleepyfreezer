'use client';

import { use, useMemo, useState } from 'react';
import { EmptyState, Panel, relativeTime } from '@/components/ui';
import { SessionShell } from '@/components/session/session-chrome';
import { useSession } from '@/components/session/use-session';

/**
 * Audit and activity view.
 *
 * Everything here has already passed through the redaction layer on the server —
 * no credential material ever reaches this screen, by construction.
 */

const STATUS_TONE: Record<string, string> = {
  succeeded: 'text-clover-300',
  pending: 'text-amber-300',
  failed: 'text-[#ffb4a8]',
  timeout: 'text-[#ffb4a8]',
  cancelled: 'text-ink-faint',
};

const SEVERITY_TONE: Record<string, string> = {
  info: 'text-ink-muted',
  warn: 'text-amber-300',
  error: 'text-[#ffb4a8]',
};

export default function ActivityPage({ params }: { params: Promise<{ sessionId: string }> }) {
  const { sessionId } = use(params);
  const state = useSession(sessionId);
  const { session } = state;

  const [onlyFailures, setOnlyFailures] = useState(false);
  const [eventFilter, setEventFilter] = useState('');

  const commands = useMemo(() => {
    if (!session) return [];
    return onlyFailures
      ? session.commands.filter(
          (command) => command.status !== 'succeeded' && command.status !== 'pending',
        )
      : session.commands;
  }, [onlyFailures, session]);

  const events = useMemo(() => {
    if (!session) return [];
    const needle = eventFilter.trim().toLowerCase();
    if (!needle) return session.events;
    return session.events.filter(
      (event) =>
        event.kind.toLowerCase().includes(needle) ||
        event.message.toLowerCase().includes(needle) ||
        event.actor.toLowerCase().includes(needle),
    );
  }, [eventFilter, session]);

  return (
    <SessionShell
      sessionId={sessionId}
      session={session}
      loading={state.loading}
      error={state.error}
      unauthorised={state.unauthorised}
      onRetry={state.refresh}
    >
      {session ? (
        <>
          <Panel
            title="Tool calls"
            description="Commands dispatched to the Roblox client, newest first. Arguments and results are abbreviated and redacted."
            actions={
              <button
                type="button"
                className="cl-btn-ghost !min-h-0 !px-3 !py-1.5 !text-xs"
                onClick={() => setOnlyFailures((previous) => !previous)}
              >
                {onlyFailures ? 'Show all' : 'Failures only'}
              </button>
            }
          >
            {commands.length === 0 ? (
              <EmptyState
                title={onlyFailures ? 'No failed commands.' : 'No commands yet.'}
                hint="Tool calls appear here as soon as an agent or the dashboard runs one."
              />
            ) : (
              <div className="cl-scroll max-h-[32rem] rounded-xl border border-line">
                <table className="w-full min-w-[680px] text-left text-[12.5px]">
                  <thead className="sticky top-0 bg-base-800/95 backdrop-blur">
                    <tr className="text-ink-faint">
                      <th className="px-3 py-2.5 font-medium">Tool</th>
                      <th className="px-3 py-2.5 font-medium">Origin</th>
                      <th className="px-3 py-2.5 font-medium">Status</th>
                      <th className="px-3 py-2.5 font-medium">Duration</th>
                      <th className="px-3 py-2.5 font-medium">When</th>
                    </tr>
                  </thead>
                  <tbody>
                    {commands.map((command) => (
                      <tr key={command.id} className="border-t border-line align-top">
                        <td className="px-3 py-2.5">
                          <div className="font-mono text-[12px] text-ink">{command.tool}</div>
                          <div className="mt-0.5 font-mono text-[11px] text-ink-faint">
                            {command.id}
                          </div>
                          <div className="mt-1 max-w-md truncate text-[11.5px] text-ink-faint">
                            {command.argumentsPreview}
                          </div>
                          {command.errorMessage ? (
                            <div className="mt-1 max-w-md text-[11.5px] text-[#ffb4a8]">
                              {command.errorCode}: {command.errorMessage}
                            </div>
                          ) : command.resultPreview ? (
                            <div className="mt-1 max-w-md truncate text-[11.5px] text-ink-faint">
                              → {command.resultPreview}
                            </div>
                          ) : null}
                        </td>
                        <td className="px-3 py-2.5 text-ink-muted">{command.origin}</td>
                        <td
                          className={`px-3 py-2.5 ${STATUS_TONE[command.status] ?? 'text-ink-muted'}`}
                        >
                          {command.status}
                        </td>
                        <td className="px-3 py-2.5 text-ink-muted">
                          {command.durationMs === null ? '—' : `${command.durationMs} ms`}
                        </td>
                        <td className="px-3 py-2.5 text-ink-faint">
                          {relativeTime(command.startedAt)}
                        </td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            )}
          </Panel>

          <Panel
            title="Connection and audit events"
            description="Handshakes, capability reports, privilege changes, revocations and protocol violations."
          >
            <input
              className="cl-input mb-3"
              placeholder="Filter events by kind, actor or message…"
              value={eventFilter}
              onChange={(event) => setEventFilter(event.target.value)}
            />
            {events.length === 0 ? (
              <EmptyState title="No events match that filter." />
            ) : (
              <ul className="cl-scroll max-h-[32rem] divide-y divide-line rounded-xl border border-line">
                {events.map((event) => (
                  <li key={event.id} className="px-4 py-3">
                    <div className="flex flex-wrap items-baseline justify-between gap-x-4 gap-y-1">
                      <span className={`font-mono text-[11.5px] ${SEVERITY_TONE[event.severity]}`}>
                        {event.kind}
                      </span>
                      <span className="text-[11px] text-ink-faint">
                        {event.actor} · {relativeTime(event.at)}
                      </span>
                    </div>
                    <p className="mt-1.5 text-[12.5px] leading-relaxed text-ink-muted">
                      {event.message}
                    </p>
                  </li>
                ))}
              </ul>
            )}
          </Panel>

          <Panel
            title="MCP clients"
            description="Agents that have completed an MCP initialize on this session."
          >
            {session.mcp.connections.length === 0 ? (
              <EmptyState
                title="No MCP client has connected."
                hint="Add the endpoint and bearer token from the overview tab to your agent."
              />
            ) : (
              <ul className="divide-y divide-line rounded-xl border border-line">
                {session.mcp.connections.map((connection) => (
                  <li
                    key={connection.id}
                    className="flex flex-wrap justify-between gap-3 px-4 py-3"
                  >
                    <div className="min-w-0">
                      <div className="text-[13px] text-ink">
                        {connection.clientName ?? 'Unnamed client'}
                      </div>
                      <div className="mt-0.5 font-mono text-[11.5px] text-ink-faint">
                        {connection.clientVersion ?? 'unknown version'} · MCP{' '}
                        {connection.protocolVersion ?? '—'}
                      </div>
                    </div>
                    <div className="text-[11.5px] text-ink-faint">
                      connected {relativeTime(connection.connectedAt)} · last seen{' '}
                      {relativeTime(connection.lastSeenAt)}
                    </div>
                  </li>
                ))}
              </ul>
            )}
          </Panel>
        </>
      ) : null}
    </SessionShell>
  );
}
