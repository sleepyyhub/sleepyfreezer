'use client';

import { use, useCallback, useMemo, useState } from 'react';
import { CopyButton, EmptyState, ErrorNote, Panel } from '@/components/ui';
import { SessionShell } from '@/components/session/session-chrome';
import { useSession } from '@/components/session/use-session';

/**
 * Replicated script explorer.
 *
 * Representation honesty is the point of this screen: every source view states
 * whether it came from a real Source property, a decompiler, or nothing at all.
 */

interface ScriptEntry {
  ref: string;
  name: string;
  className: string;
  displayPath: string;
  enabled?: boolean;
  sourceAvailability?: string;
}

interface ScriptDetail {
  name?: string;
  className?: string;
  displayPath?: string;
  representation?: string;
  source?: string | null;
  note?: string;
  truncated?: boolean;
  totalBytes?: number;
  lineCount?: number;
  bytecodeBytes?: number;
}

const REPRESENTATION_COPY: Record<
  string,
  { label: string; tone: 'good' | 'warn' | 'muted'; note: string }
> = {
  source: {
    label: 'Original source',
    tone: 'good',
    note: 'Read directly from the Source property. This is the genuine script text.',
  },
  decompiled: {
    label: 'Decompiled (best effort)',
    tone: 'warn',
    note:
      'Produced by the executor decompiler. This is NOT guaranteed to match the original source — names, ' +
      'formatting and control flow may differ, and the output can simply be wrong.',
  },
  bytecode: {
    label: 'Bytecode only',
    tone: 'muted',
    note: 'Compiled bytecode is present but this executor cannot decompile it, so no readable source exists.',
  },
  unavailable: {
    label: 'Unavailable',
    tone: 'muted',
    note: 'No source representation is obtainable for this script on this client.',
  },
};

export default function ScriptsPage({ params }: { params: Promise<{ sessionId: string }> }) {
  const { sessionId } = use(params);
  const state = useSession(sessionId);
  const { callTool, session } = state;

  const [scripts, setScripts] = useState<ScriptEntry[] | null>(null);
  const [listLoading, setListLoading] = useState(false);
  const [listError, setListError] = useState<string | null>(null);
  const [filter, setFilter] = useState('');

  const [selected, setSelected] = useState<ScriptEntry | null>(null);
  const [detail, setDetail] = useState<ScriptDetail | null>(null);
  const [detailLoading, setDetailLoading] = useState(false);
  const [detailError, setDetailError] = useState<string | null>(null);
  const [sourceQuery, setSourceQuery] = useState('');

  const connected = session?.roblox.connected ?? false;

  const loadScripts = useCallback(async () => {
    setListLoading(true);
    setListError(null);
    const outcome = await callTool('clovyre_list_scripts', { maxResults: 200, maxDepth: 8 });
    setListLoading(false);
    if (!outcome.ok) {
      setListError(outcome.message);
      return;
    }
    setScripts((outcome.data as { scripts?: ScriptEntry[] } | null)?.scripts ?? []);
  }, [callTool]);

  const openScript = useCallback(
    async (entry: ScriptEntry) => {
      setSelected(entry);
      setDetail(null);
      setDetailError(null);
      setSourceQuery('');
      setDetailLoading(true);
      const outcome = await callTool('clovyre_inspect_script', {
        ref: entry.ref,
        includeSource: true,
        maxSourceBytes: 200_000,
      });
      setDetailLoading(false);
      if (!outcome.ok) {
        setDetailError(outcome.message);
        return;
      }
      setDetail(outcome.data as ScriptDetail);
    },
    [callTool],
  );

  const filtered = useMemo(() => {
    if (!scripts) return [];
    const needle = filter.trim().toLowerCase();
    if (!needle) return scripts;
    return scripts.filter(
      (entry) =>
        entry.name.toLowerCase().includes(needle) ||
        entry.displayPath.toLowerCase().includes(needle) ||
        entry.className.toLowerCase().includes(needle),
    );
  }, [filter, scripts]);

  const source = detail?.source ?? null;

  const sourceLines = useMemo(() => {
    if (!source) return [];
    const lines = source.split('\n');
    const needle = sourceQuery.trim().toLowerCase();
    if (!needle) return lines.map((text, index) => ({ index: index + 1, text, match: false }));
    return lines
      .map((text, index) => ({
        index: index + 1,
        text,
        match: text.toLowerCase().includes(needle),
      }))
      .filter((line) => line.match);
  }, [source, sourceQuery]);

  const representation = detail?.representation ?? 'unavailable';
  const representationCopy = REPRESENTATION_COPY[representation];

  return (
    <SessionShell
      sessionId={sessionId}
      session={session}
      loading={state.loading}
      error={state.error}
      unauthorised={state.unauthorised}
      onRetry={state.refresh}
    >
      {!connected ? (
        <Panel
          title="Scripts"
          description="LocalScripts and replicated ModuleScripts visible to this client."
        >
          <EmptyState
            title="No Roblox client is connected."
            hint="Run the loadstring from the overview tab, then return here."
          />
        </Panel>
      ) : (
        <>
          <Panel
            title="Replicated scripts"
            description="Server Scripts are not replicated to clients and never appear in this list."
            actions={
              <button
                type="button"
                className="cl-btn-ghost !min-h-0 !px-3 !py-1.5 !text-xs"
                onClick={() => void loadScripts()}
                disabled={listLoading}
              >
                {listLoading ? 'Scanning…' : scripts ? 'Rescan' : 'Scan for scripts'}
              </button>
            }
          >
            {listError ? (
              <ErrorNote message={listError} onRetry={() => void loadScripts()} />
            ) : !scripts ? (
              <EmptyState
                title="No scan has run yet."
                hint="Scanning walks the replicated tree from the DataModel root, capped at 200 scripts."
              />
            ) : scripts.length === 0 ? (
              <EmptyState title="No replicated scripts were found on this client." />
            ) : (
              <>
                <input
                  className="cl-input mb-3"
                  placeholder="Filter by name, class or path…"
                  value={filter}
                  onChange={(event) => setFilter(event.target.value)}
                />
                <ul className="cl-scroll max-h-96 divide-y divide-line rounded-xl border border-line">
                  {filtered.map((entry) => (
                    <li key={entry.ref}>
                      <button
                        type="button"
                        onClick={() => void openScript(entry)}
                        className={`w-full px-4 py-2.5 text-left transition-colors duration-200 ease-calm hover:bg-base-700/50 ${
                          selected?.ref === entry.ref ? 'bg-clover-600/12' : ''
                        }`}
                      >
                        <div className="flex flex-wrap items-baseline gap-x-2">
                          <span className="text-[13px] text-ink">{entry.name}</span>
                          <span className="font-mono text-[11px] text-ink-faint">
                            {entry.className}
                          </span>
                          {entry.sourceAvailability ? (
                            <span className="text-[11px] text-ink-faint">
                              · {entry.sourceAvailability}
                            </span>
                          ) : null}
                        </div>
                        <div className="truncate font-mono text-[11.5px] text-ink-faint">
                          {entry.displayPath}
                        </div>
                      </button>
                    </li>
                  ))}
                </ul>
                {filtered.length === 0 ? (
                  <p className="mt-3 text-[12.5px] text-ink-faint">No scripts match that filter.</p>
                ) : null}
              </>
            )}
          </Panel>

          <Panel
            title="Source"
            description={
              selected ? selected.displayPath : 'Select a script to view its representation.'
            }
            actions={
              detail?.source ? (
                <CopyButton
                  value={detail.source}
                  label="Copy source"
                  className="cl-btn-ghost !min-h-0 !px-3 !py-1.5 !text-xs"
                />
              ) : undefined
            }
          >
            {!selected ? (
              <EmptyState title="Nothing selected." />
            ) : detailLoading ? (
              <EmptyState title="Reading script…" />
            ) : detailError ? (
              <ErrorNote message={detailError} onRetry={() => void openScript(selected)} />
            ) : detail ? (
              <div className="flex flex-col gap-4">
                <div
                  className={`rounded-xl border p-4 ${
                    representationCopy?.tone === 'good'
                      ? 'border-line-strong bg-clover-600/8'
                      : representationCopy?.tone === 'warn'
                        ? 'border-[rgba(255,138,120,0.3)] bg-[rgba(255,96,74,0.06)]'
                        : 'border-line bg-base-800/40'
                  }`}
                >
                  <p className="text-[13px] font-medium text-ink">
                    {representationCopy?.label ?? representation}
                  </p>
                  <p className="mt-1.5 text-[12.5px] leading-relaxed text-ink-muted">
                    {detail.note ?? representationCopy?.note}
                  </p>
                  <p className="mt-2 text-[11.5px] text-ink-faint">
                    {detail.lineCount ? `${detail.lineCount} lines · ` : ''}
                    {detail.totalBytes ? `${detail.totalBytes} bytes` : ''}
                    {detail.bytecodeBytes ? `${detail.bytecodeBytes} bytes of bytecode` : ''}
                    {detail.truncated ? ' · truncated to the payload limit' : ''}
                  </p>
                </div>

                {detail.source ? (
                  <>
                    <input
                      className="cl-input"
                      placeholder="Search within this source…"
                      value={sourceQuery}
                      onChange={(event) => setSourceQuery(event.target.value)}
                    />
                    <div className="cl-scroll max-h-[30rem] rounded-xl border border-line bg-base-900/70">
                      <pre className="min-w-full p-4 text-[12px] leading-[1.65]">
                        {sourceLines.length === 0 ? (
                          <span className="text-ink-faint">No lines match that search.</span>
                        ) : (
                          sourceLines.map((line) => (
                            <div key={line.index} className="flex gap-4">
                              <span className="w-10 shrink-0 select-none text-right text-ink-faint">
                                {line.index}
                              </span>
                              <span
                                className={
                                  line.match && sourceQuery ? 'text-clover-200' : 'text-ink-muted'
                                }
                              >
                                {line.text || ' '}
                              </span>
                            </div>
                          ))
                        )}
                      </pre>
                    </div>
                  </>
                ) : (
                  <EmptyState
                    title="No readable source for this script."
                    hint="This is expected when the executor cannot decompile, or the script exposes no Source property."
                  />
                )}
              </div>
            ) : null}
          </Panel>
        </>
      )}
    </SessionShell>
  );
}
