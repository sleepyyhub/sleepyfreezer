'use client';

import { use, useState } from 'react';
import { useRouter } from 'next/navigation';
import {
  CodeBlock,
  ConfirmButton,
  EmptyState,
  Field,
  Panel,
  Toggle,
  formatDuration,
  relativeTime,
} from '@/components/ui';
import { SessionShell } from '@/components/session/session-chrome';
import { useSession } from '@/components/session/use-session';
import type { PrivilegeView } from '@/lib/sessions/view';

const PRIVILEGE_COPY: Record<
  string,
  { title: string; summary: string; warning: string; confirm: string }
> = {
  execute_luau: {
    title: 'Luau execution',
    summary:
      'Lets a connected agent run arbitrary Luau inside your live client via clovyre_execute_luau.',
    warning:
      'Arbitrary Luau can modify local client state, read anything this client can see, call executor-provided ' +
      'functions, and interfere with or crash the running client. The chunk runs inside the executor environment. ' +
      'It is not sandboxed.',
    confirm: 'Enable Luau execution',
  },
  executor_globals: {
    title: 'Executor globals in executed code',
    summary:
      'Controls whether executed chunks can reach executor-specific globals such as getgenv and hookfunction.',
    warning:
      'With this off, Clovyre masks well-known executor globals from the chunk. That is a convenience filter, not a ' +
      'security boundary: a determined chunk can still reach the real environment on most executors. Treat any ' +
      'executed code as fully privileged either way.',
    confirm: 'Expose executor globals',
  },
  mutations: {
    title: 'Mutation tools',
    summary:
      'Unlocks set_property, set_attribute, create_instance, destroy_instance and reparent_instance.',
    warning:
      'These write to local client state only. The Roblox server stays authoritative and will usually ignore or ' +
      'overwrite the change, but destroying an instance is irreversible for this session.',
    confirm: 'Enable mutation tools',
  },
};

export default function SessionOverviewPage({
  params,
}: {
  params: Promise<{ sessionId: string }>;
}) {
  const { sessionId } = use(params);
  const router = useRouter();
  const state = useSession(sessionId);
  const [actionError, setActionError] = useState<string | null>(null);
  const [pendingPrivilege, setPendingPrivilege] = useState<string | null>(null);

  const { session, endpoints, secrets, mutate } = state;

  const setPrivilege = async (privilege: PrivilegeView, enabled: boolean) => {
    setActionError(null);
    const outcome = await mutate(`/api/sessions/${sessionId}/privileges`, {
      body: {
        privilege: privilege.name,
        enabled,
        acknowledgement: enabled
          ? 'Owner confirmed the warning in the Clovyre dashboard.'
          : undefined,
      },
    });
    if (!outcome.ok) setActionError(outcome.message);
    setPendingPrivilege(null);
  };

  const revokeCredential = async (role: string) => {
    setActionError(null);
    const outcome = await mutate(`/api/sessions/${sessionId}/credentials`, { body: { role } });
    if (!outcome.ok) setActionError(outcome.message);
  };

  const terminate = async () => {
    setActionError(null);
    const outcome = await mutate(`/api/sessions/${sessionId}`, {
      method: 'DELETE',
      body: { reason: 'Terminated from the Clovyre dashboard.' },
    });
    if (!outcome.ok) {
      setActionError(outcome.message);
      return;
    }
    try {
      sessionStorage.removeItem(`clovyre.secrets.${sessionId}`);
    } catch {
      // Non-fatal: the tokens stop working regardless.
    }
    router.push('/');
  };

  return (
    <SessionShell
      sessionId={sessionId}
      session={session}
      loading={state.loading}
      error={state.error}
      unauthorised={state.unauthorised}
      onRetry={state.refresh}
    >
      {session && endpoints ? (
        <>
          {actionError ? (
            <div className="rounded-xl border border-[rgba(255,138,120,0.3)] bg-[rgba(255,96,74,0.07)] px-4 py-3 text-[13px] text-[#ffb4a8]">
              {actionError}
            </div>
          ) : null}

          {/* Roblox connection */}
          <Panel
            title="Roblox client"
            description={
              session.roblox.connected
                ? 'The bridge is connected and answering heartbeats.'
                : 'Run the loadstring below in your executor to connect this session.'
            }
          >
            <div className="grid grid-cols-2 gap-x-6 gap-y-4 sm:grid-cols-3 lg:grid-cols-4">
              <Field label="Place ID">{session.metadata?.placeId ?? '—'}</Field>
              <Field label="Universe ID">{session.metadata?.universeId ?? '—'}</Field>
              <Field label="Job ID">
                <span className="font-mono text-[12px]">{session.metadata?.jobId ?? '—'}</span>
              </Field>
              <Field label="Experience">{session.metadata?.gameName ?? '—'}</Field>
              <Field label="Local player">
                {session.metadata?.localPlayer
                  ? `${session.metadata.localPlayer.name} (${session.metadata.localPlayer.userId})`
                  : '—'}
              </Field>
              <Field label="Executor">{session.metadata?.executor ?? '—'}</Field>
              <Field label="Bridge version">{session.roblox.bridgeVersion ?? '—'}</Field>
              <Field label="Last heartbeat">{relativeTime(session.roblox.lastHeartbeatAt)}</Field>
              <Field label="Session age">{formatDuration(session.ageSeconds)}</Field>
              <Field label="Protocol">v{session.protocolVersion}</Field>
            </div>
          </Panel>

          {/* Loadstring */}
          <Panel
            title="Roblox loadstring"
            description="Copy this into your executor. It carries the Roblox credential for this session only."
          >
            {secrets ? (
              <>
                <CodeBlock
                  code={secrets.loadstring}
                  caption="Executor loadstring"
                  copyLabel="Copy loadstring"
                />
                <p className="mt-3 text-[12.5px] leading-relaxed text-ink-faint">
                  Running it twice cleans up the previous connection instead of creating a
                  duplicate. Call{' '}
                  <code className="text-ink-muted">getgenv().ClovyreDisconnect()</code> to stop the
                  bridge.
                </p>
              </>
            ) : (
              <EmptyState
                title="The Roblox token is no longer available in this tab."
                hint="Tokens are shown once, at creation, and held only in tab-scoped storage. Create a new session to get a fresh loadstring."
              />
            )}
          </Panel>

          {/* MCP */}
          <Panel
            title="Remote MCP endpoint"
            description="Connect Claude, Claude Code, Codex or any Streamable HTTP MCP client to this session."
          >
            <div className="grid gap-4">
              <div>
                <div className="cl-label mb-1.5">Endpoint URL</div>
                <CodeBlock code={endpoints.mcp} caption="MCP endpoint" copyLabel="Copy URL" />
              </div>

              {secrets ? (
                <>
                  <div>
                    <div className="cl-label mb-1.5">Authorization header</div>
                    <CodeBlock
                      code={`Authorization: ${secrets.authorizationHeader}`}
                      caption="Bearer credential"
                      copyLabel="Copy header"
                    />
                  </div>
                  <div>
                    <div className="cl-label mb-1.5">Configuration for HTTP-capable clients</div>
                    <CodeBlock
                      code={secrets.mcpRemoteJson}
                      caption="mcpServers (remote HTTP)"
                      copyLabel="Copy config"
                    />
                  </div>
                  <div>
                    <div className="cl-label mb-1.5">
                      Configuration for stdio-only desktop clients
                    </div>
                    <CodeBlock
                      code={secrets.mcpProxyJson}
                      caption="mcpServers (via mcp-remote)"
                      copyLabel="Copy config"
                    />
                  </div>
                </>
              ) : (
                <EmptyState
                  title="The MCP token is no longer available in this tab."
                  hint="Create a new session to receive a fresh endpoint and bearer token."
                />
              )}

              <div className="rounded-xl border border-line bg-base-800/40 p-4">
                <p className="text-[12.5px] leading-relaxed text-ink-muted">
                  In Claude, add a custom connector with the endpoint URL above and the bearer token
                  as the authorization header. Tools appear once the client sends{' '}
                  <code>initialize</code>. Tools that need an executor capability your client did
                  not report stay listed but fail with a clear reason, and privileged tools are
                  hidden entirely until you enable them below.
                </p>
              </div>
            </div>
          </Panel>

          {/* Capabilities */}
          <Panel
            title="Client capabilities"
            description="Probed by the bridge at startup. Missing entries disable their tools; they are not faults."
          >
            {Object.keys(session.capabilities).length === 0 ? (
              <EmptyState
                title="No capabilities reported yet."
                hint="Capabilities arrive with the first hello frame from the Roblox client."
              />
            ) : (
              <div className="flex flex-wrap gap-2">
                {Object.entries(session.capabilities).map(([name, available]) => (
                  <span
                    key={name}
                    className={`cl-pill ${
                      available ? 'border-line-strong text-ink' : 'opacity-55'
                    }`}
                  >
                    <span
                      className={`h-1.5 w-1.5 rounded-full ${
                        available ? 'bg-clover-300' : 'bg-ink-faint'
                      }`}
                    />
                    {name}
                  </span>
                ))}
              </div>
            )}
          </Panel>

          {/* Tools */}
          <Panel
            title="Tool availability"
            description="What a connected agent can call right now, and why anything unavailable is unavailable."
          >
            <div className="cl-scroll max-h-96 rounded-xl border border-line">
              <table className="w-full min-w-[560px] text-left text-[12.5px]">
                <thead className="sticky top-0 bg-base-800/95 backdrop-blur">
                  <tr className="text-ink-faint">
                    <th className="px-3 py-2.5 font-medium">Tool</th>
                    <th className="px-3 py-2.5 font-medium">Category</th>
                    <th className="px-3 py-2.5 font-medium">State</th>
                  </tr>
                </thead>
                <tbody>
                  {session.tools.map((tool) => (
                    <tr key={tool.name} className="border-t border-line align-top">
                      <td className="px-3 py-2.5">
                        <div className="font-mono text-[12px] text-ink">{tool.name}</div>
                        <div className="mt-0.5 text-ink-faint">{tool.title}</div>
                      </td>
                      <td className="px-3 py-2.5 text-ink-muted">{tool.category}</td>
                      <td className="px-3 py-2.5">
                        {tool.available ? (
                          <span className="text-clover-300">Available</span>
                        ) : (
                          <span className="text-ink-faint">{tool.detail ?? tool.reason}</span>
                        )}
                      </td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          </Panel>

          {/* Privileged controls */}
          <Panel
            title="Privileged capabilities"
            description="Off by default. Only you, in this browser, can enable them — never a connected agent."
            tone="alert"
          >
            <div className="flex flex-col gap-4">
              {session.privileges.map((privilege) => {
                const copy = PRIVILEGE_COPY[privilege.name]!;
                const isPending = pendingPrivilege === privilege.name;
                return (
                  <div
                    key={privilege.name}
                    className="rounded-xl border border-line bg-base-800/40 p-4"
                  >
                    <div className="flex flex-wrap items-start justify-between gap-3">
                      <div className="min-w-0 flex-1">
                        <h3 className="text-[13.5px] font-semibold text-ink">{copy.title}</h3>
                        <p className="mt-1.5 text-[12.5px] leading-relaxed text-ink-muted">
                          {copy.summary}
                        </p>
                        {privilege.enabled ? (
                          <p className="mt-2 text-[12px] text-[#ffb4a8]">
                            Enabled — expires in {formatDuration(privilege.expiresInSeconds ?? 0)}.
                          </p>
                        ) : null}
                        {!privilege.featureEnabled ? (
                          <p className="mt-2 text-[12px] text-ink-faint">
                            Disabled at the deployment level by an environment variable.
                          </p>
                        ) : null}
                      </div>
                      <Toggle
                        checked={privilege.enabled}
                        disabled={!privilege.featureEnabled || session.status !== 'active'}
                        label={copy.title}
                        onChange={(next) => {
                          if (next) {
                            setPendingPrivilege(privilege.name);
                          } else {
                            void setPrivilege(privilege, false);
                          }
                        }}
                      />
                    </div>

                    {isPending ? (
                      <div className="mt-4 rounded-xl border border-[rgba(255,138,120,0.35)] bg-[rgba(255,96,74,0.08)] p-4">
                        <p className="text-[12.5px] leading-relaxed text-ink-muted">
                          {copy.warning}
                        </p>
                        <div className="mt-4 flex flex-wrap gap-2">
                          <button
                            type="button"
                            className="cl-btn-danger !min-h-0 !px-3.5 !py-2 !text-[12.5px]"
                            onClick={() => void setPrivilege(privilege, true)}
                          >
                            {copy.confirm}
                          </button>
                          <button
                            type="button"
                            className="cl-btn-ghost !min-h-0 !px-3.5 !py-2 !text-[12.5px]"
                            onClick={() => setPendingPrivilege(null)}
                          >
                            Cancel
                          </button>
                        </div>
                      </div>
                    ) : null}
                  </div>
                );
              })}
            </div>
          </Panel>

          {/* Credentials */}
          <Panel
            title="Credentials"
            description="Only fingerprints are stored. Revoking one credential leaves the others working."
          >
            <div className="flex flex-col gap-3">
              {session.credentials.map((credential) => (
                <div
                  key={credential.role}
                  className="flex flex-wrap items-center justify-between gap-3 rounded-xl border border-line bg-base-800/40 px-4 py-3"
                >
                  <div className="min-w-0">
                    <div className="text-[13px] font-medium text-ink">{credential.role}</div>
                    <div className="mt-1 font-mono text-[11.5px] text-ink-faint">
                      {credential.fingerprint} · used {credential.useCount}× ·{' '}
                      {credential.lastUsedAt ? relativeTime(credential.lastUsedAt) : 'never used'}
                    </div>
                  </div>
                  {credential.revoked ? (
                    <span className="cl-pill text-[#ffb4a8]">Revoked</span>
                  ) : (
                    <ConfirmButton
                      className="cl-btn-danger !min-h-0 !px-3 !py-1.5 !text-xs"
                      label="Revoke"
                      confirmLabel="Confirm revoke"
                      disabled={session.status !== 'active'}
                      onConfirm={() => revokeCredential(credential.role)}
                    />
                  )}
                </div>
              ))}
            </div>
          </Panel>

          {/* Termination */}
          <Panel
            title="End this session"
            description="Closes the Roblox socket, fails pending commands and invalidates every credential."
            tone="alert"
          >
            <ConfirmButton
              label="Terminate session"
              confirmLabel="Confirm termination"
              disabled={session.status !== 'active'}
              onConfirm={terminate}
            />
          </Panel>
        </>
      ) : null}
    </SessionShell>
  );
}
