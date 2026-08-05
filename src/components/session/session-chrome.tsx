'use client';

import Link from 'next/link';
import { usePathname } from 'next/navigation';
import type { ReactNode } from 'react';
import type { SessionView } from '@/lib/sessions/view';
import { ErrorNote, StatusPill, formatDuration } from '../ui';

/** Navigation and shared framing for every session route. */

const tabs = [
  { slug: '', label: 'Overview' },
  { slug: '/explorer', label: 'Explorer' },
  { slug: '/scripts', label: 'Scripts' },
  { slug: '/activity', label: 'Activity' },
];

export function SessionNav({ sessionId }: { sessionId: string }) {
  const pathname = usePathname();
  const base = `/session/${sessionId}`;

  return (
    <nav className="cl-scroll -mx-1 flex gap-1 overflow-x-auto pb-1">
      {tabs.map((tab) => {
        const href = `${base}${tab.slug}`;
        const active = pathname === href;
        return (
          <Link
            key={tab.slug}
            href={href}
            aria-current={active ? 'page' : undefined}
            className={`shrink-0 rounded-xl px-3.5 py-2 text-[13px] font-medium transition-colors duration-200 ease-calm ${
              active
                ? 'border border-line-strong bg-clover-600/12 text-ink'
                : 'border border-transparent text-ink-muted hover:text-ink'
            }`}
          >
            {tab.label}
          </Link>
        );
      })}
    </nav>
  );
}

export function SessionHeader({ session }: { session: SessionView }) {
  const robloxTone = session.roblox.connected ? 'live' : 'idle';
  const mcpTone = session.mcp.connectionCount > 0 ? 'live' : 'idle';
  const statusTone =
    session.status === 'active' ? 'live' : session.status === 'expired' ? 'warn' : 'down';

  return (
    <div className="flex flex-col gap-4">
      <div className="flex flex-wrap items-baseline justify-between gap-x-6 gap-y-2">
        <div className="min-w-0">
          <p className="cl-label">Session</p>
          <h1 className="mt-1.5 break-all font-mono text-[19px] font-medium text-ink sm:text-[22px]">
            {session.id}
          </h1>
        </div>
        <p className="text-[12.5px] text-ink-faint">
          {session.status === 'active'
            ? `Expires in ${formatDuration(session.expiresInSeconds)}`
            : session.status === 'expired'
              ? 'Expired'
              : `Terminated — ${session.terminationReason ?? 'no reason recorded'}`}
        </p>
      </div>

      <div className="flex flex-wrap gap-2">
        <StatusPill tone={statusTone} pulse={session.status === 'active'}>
          {session.status === 'active' ? 'Session active' : `Session ${session.status}`}
        </StatusPill>
        <StatusPill tone={robloxTone} pulse={session.roblox.connected}>
          {session.roblox.connected ? 'Roblox connected' : 'Roblox not connected'}
        </StatusPill>
        <StatusPill tone={mcpTone} pulse={session.mcp.connectionCount > 0}>
          {session.mcp.connectionCount > 0
            ? `${session.mcp.connectionCount} MCP client${session.mcp.connectionCount === 1 ? '' : 's'}`
            : 'No MCP client'}
        </StatusPill>
        {session.pendingCommandCount > 0 ? (
          <StatusPill tone="warn">{`${session.pendingCommandCount} command${
            session.pendingCommandCount === 1 ? '' : 's'
          } in flight`}</StatusPill>
        ) : null}
      </div>
    </div>
  );
}

export function PrivilegeBanner({ session }: { session: SessionView }) {
  const active = session.privileges.filter((privilege) => privilege.enabled);
  if (active.length === 0) return null;

  return (
    <div className="cl-surface border-[rgba(255,138,120,0.3)] bg-[rgba(255,96,74,0.07)] p-4">
      <p className="text-[13px] font-medium text-[#ffb4a8]">
        Privileged access is live on this session
      </p>
      <p className="mt-1.5 text-[12.5px] leading-relaxed text-ink-muted">
        {active
          .map(
            (privilege) =>
              `${privilege.name} (expires in ${formatDuration(privilege.expiresInSeconds ?? 0)})`,
          )
          .join(' · ')}
        . Any connected MCP client can use these tools until the grant lapses or you disable it.
      </p>
    </div>
  );
}

export function SessionShell({
  sessionId,
  session,
  loading,
  error,
  unauthorised,
  onRetry,
  children,
}: {
  sessionId: string;
  session: SessionView | null;
  loading: boolean;
  error: string | null;
  unauthorised: boolean;
  onRetry: () => void;
  children: ReactNode;
}) {
  if (unauthorised) {
    return (
      <div className="cl-shell py-16">
        <div className="cl-surface mx-auto max-w-lg p-8 text-center">
          <h1 className="text-[20px] font-semibold text-ink">This session is not open here</h1>
          <p className="mt-3 text-[13.5px] leading-relaxed text-ink-muted">
            {error ??
              'Clovyre sessions are bound to the browser that created them. The owner credential for this session is not present in this browser, or the session has ended.'}
          </p>
          <Link href="/#start" className="cl-btn-primary mt-7 inline-flex">
            Create a new session
          </Link>
        </div>
      </div>
    );
  }

  if (loading && !session) {
    return (
      <div className="cl-shell py-16">
        <div className="cl-surface p-8">
          <p className="text-sm text-ink-muted">Loading session…</p>
        </div>
      </div>
    );
  }

  if (!session) {
    return (
      <div className="cl-shell py-16">
        <ErrorNote message={error ?? 'This session could not be loaded.'} onRetry={onRetry} />
      </div>
    );
  }

  return (
    <div className="cl-shell cl-rise py-10 sm:py-14">
      <SessionHeader session={session} />
      <div className="mt-7">
        <SessionNav sessionId={sessionId} />
      </div>
      {error ? (
        <div className="mt-5">
          <ErrorNote message={error} onRetry={onRetry} />
        </div>
      ) : null}
      <div className="mt-6 flex flex-col gap-5">
        <PrivilegeBanner session={session} />
        {children}
      </div>
    </div>
  );
}
