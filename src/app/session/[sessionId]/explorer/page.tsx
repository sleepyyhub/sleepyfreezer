'use client';

import { use, useCallback, useEffect, useMemo, useState } from 'react';
import { CopyButton, EmptyState, ErrorNote, Panel } from '@/components/ui';
import { SessionShell } from '@/components/session/session-chrome';
import { useSession } from '@/components/session/use-session';
import { formatValue, isTaggedValue } from '@/lib/serialization/roblox-value';

/**
 * Replicated instance explorer.
 *
 * The hierarchy loads lazily: each expansion issues one clovyre_get_children call
 * with an explicit page size, so a fan-out of thousands of children never lands in
 * the browser at once.
 */

interface InstanceSummary {
  ref: string;
  name: string;
  className: string;
  displayPath: string;
  childCount: number;
}

interface NodeState {
  expanded: boolean;
  loading: boolean;
  children: InstanceSummary[];
  total: number;
  hasMore: boolean;
  error: string | null;
}

const PAGE_SIZE = 50;

export default function ExplorerPage({ params }: { params: Promise<{ sessionId: string }> }) {
  const { sessionId } = use(params);
  const state = useSession(sessionId);
  const { callTool, session } = state;

  const [roots, setRoots] = useState<InstanceSummary[]>([]);
  const [rootsError, setRootsError] = useState<string | null>(null);
  const [rootsLoading, setRootsLoading] = useState(false);
  const [nodes, setNodes] = useState<Record<string, NodeState>>({});
  const [selected, setSelected] = useState<InstanceSummary | null>(null);
  const [detail, setDetail] = useState<Record<string, unknown> | null>(null);
  const [detailError, setDetailError] = useState<string | null>(null);
  const [detailLoading, setDetailLoading] = useState(false);

  const [query, setQuery] = useState('');
  const [classFilter, setClassFilter] = useState('');
  const [searchResults, setSearchResults] = useState<InstanceSummary[] | null>(null);
  const [searching, setSearching] = useState(false);
  const [searchError, setSearchError] = useState<string | null>(null);

  const connected = session?.roblox.connected ?? false;

  const loadServices = useCallback(async () => {
    setRootsLoading(true);
    setRootsError(null);
    const outcome = await callTool('clovyre_get_services');
    setRootsLoading(false);
    if (!outcome.ok) {
      setRootsError(outcome.message);
      return;
    }
    const services = (outcome.data as { services?: InstanceSummary[] } | null)?.services ?? [];
    setRoots(services);
  }, [callTool]);

  useEffect(() => {
    if (!connected || roots.length > 0 || rootsLoading || rootsError) return undefined;
    // Deferred so the effect body does not set state synchronously.
    const timer = setTimeout(() => void loadServices(), 0);
    return () => clearTimeout(timer);
  }, [connected, roots.length, rootsLoading, rootsError, loadServices]);

  const loadChildren = useCallback(
    async (node: InstanceSummary, offset: number) => {
      setNodes((previous) => ({
        ...previous,
        [node.ref]: {
          expanded: true,
          loading: true,
          children: previous[node.ref]?.children ?? [],
          total: previous[node.ref]?.total ?? 0,
          hasMore: false,
          error: null,
        },
      }));

      const outcome = await callTool('clovyre_get_children', {
        ref: node.ref,
        offset,
        limit: PAGE_SIZE,
        ...(classFilter.trim() ? { classFilter: [classFilter.trim()] } : {}),
      });

      setNodes((previous) => {
        const existing = previous[node.ref];
        if (!outcome.ok) {
          return {
            ...previous,
            [node.ref]: {
              expanded: true,
              loading: false,
              children: existing?.children ?? [],
              total: existing?.total ?? 0,
              hasMore: false,
              error: outcome.message,
            },
          };
        }
        const payload = outcome.data as {
          children?: InstanceSummary[];
          totalMatching?: number;
          hasMore?: boolean;
        } | null;
        const incoming = payload?.children ?? [];
        return {
          ...previous,
          [node.ref]: {
            expanded: true,
            loading: false,
            children: offset === 0 ? incoming : [...(existing?.children ?? []), ...incoming],
            total: payload?.totalMatching ?? incoming.length,
            hasMore: Boolean(payload?.hasMore),
            error: null,
          },
        };
      });
    },
    [callTool, classFilter],
  );

  const toggle = useCallback(
    (node: InstanceSummary) => {
      const existing = nodes[node.ref];
      if (existing?.expanded) {
        setNodes((previous) => ({ ...previous, [node.ref]: { ...existing, expanded: false } }));
        return;
      }
      if (existing && existing.children.length > 0) {
        setNodes((previous) => ({ ...previous, [node.ref]: { ...existing, expanded: true } }));
        return;
      }
      void loadChildren(node, 0);
    },
    [loadChildren, nodes],
  );

  const select = useCallback(
    async (node: InstanceSummary) => {
      setSelected(node);
      setDetail(null);
      setDetailError(null);
      setDetailLoading(true);
      const outcome = await callTool('clovyre_inspect_instance', {
        ref: node.ref,
        includeProperties: true,
        includeChildren: true,
        childLimit: 25,
      });
      setDetailLoading(false);
      if (!outcome.ok) {
        setDetailError(outcome.message);
        return;
      }
      setDetail(outcome.data as Record<string, unknown>);
    },
    [callTool],
  );

  const runSearch = useCallback(async () => {
    if (query.trim().length === 0) {
      setSearchResults(null);
      return;
    }
    setSearching(true);
    setSearchError(null);
    const outcome = await callTool('clovyre_find_instances', {
      query: query.trim(),
      maxResults: 50,
      maxDepth: 8,
      ...(classFilter.trim() ? { classNames: [classFilter.trim()] } : {}),
    });
    setSearching(false);
    if (!outcome.ok) {
      setSearchError(outcome.message);
      setSearchResults([]);
      return;
    }
    setSearchResults((outcome.data as { matches?: InstanceSummary[] } | null)?.matches ?? []);
  }, [callTool, classFilter, query]);

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
          title="Explorer"
          description="The replicated instance hierarchy for the connected client."
        >
          <EmptyState
            title="No Roblox client is connected."
            hint="Run the loadstring from the overview tab, then return here."
          />
        </Panel>
      ) : (
        <>
          <Panel
            title="Search"
            description="Case-insensitive substring match over instance names, capped at 50 results."
            actions={
              <button
                type="button"
                className="cl-btn-ghost !min-h-0 !px-3 !py-1.5 !text-xs"
                onClick={() => {
                  setSearchResults(null);
                  setQuery('');
                  setSearchError(null);
                }}
              >
                Clear
              </button>
            }
          >
            <div className="flex flex-col gap-3 sm:flex-row">
              <input
                className="cl-input"
                placeholder="Instance name contains…"
                value={query}
                onChange={(event) => setQuery(event.target.value)}
                onKeyDown={(event) => {
                  if (event.key === 'Enter') void runSearch();
                }}
              />
              <input
                className="cl-input sm:max-w-52"
                placeholder="Class filter (optional)"
                value={classFilter}
                onChange={(event) => setClassFilter(event.target.value)}
              />
              <button
                type="button"
                className="cl-btn-primary shrink-0"
                onClick={() => void runSearch()}
                disabled={searching || query.trim().length === 0}
              >
                {searching ? 'Searching…' : 'Search'}
              </button>
            </div>

            {searchError ? (
              <div className="mt-4">
                <ErrorNote message={searchError} onRetry={() => void runSearch()} />
              </div>
            ) : null}

            {searchResults ? (
              <div className="mt-4">
                {searchResults.length === 0 ? (
                  <EmptyState title="No instances matched that query." />
                ) : (
                  <ul className="cl-scroll max-h-72 divide-y divide-line rounded-xl border border-line">
                    {searchResults.map((result) => (
                      <li key={result.ref}>
                        <button
                          type="button"
                          onClick={() => void select(result)}
                          className="w-full px-4 py-2.5 text-left transition-colors duration-200 ease-calm hover:bg-base-700/50"
                        >
                          <div className="truncate text-[13px] text-ink">{result.name}</div>
                          <div className="truncate font-mono text-[11.5px] text-ink-faint">
                            {result.className} · {result.displayPath}
                          </div>
                        </button>
                      </li>
                    ))}
                  </ul>
                )}
              </div>
            ) : null}
          </Panel>

          <div className="grid gap-5 lg:grid-cols-[minmax(0,1fr)_minmax(0,1fr)]">
            <Panel
              title="Hierarchy"
              description="Children load on demand, 50 at a time."
              actions={
                <button
                  type="button"
                  className="cl-btn-ghost !min-h-0 !px-3 !py-1.5 !text-xs"
                  onClick={() => {
                    setNodes({});
                    void loadServices();
                  }}
                >
                  Reload
                </button>
              }
            >
              {rootsError ? (
                <ErrorNote message={rootsError} onRetry={() => void loadServices()} />
              ) : roots.length === 0 ? (
                <EmptyState title={rootsLoading ? 'Loading services…' : 'No services returned.'} />
              ) : (
                <div className="cl-scroll max-h-[32rem] rounded-xl border border-line p-2">
                  {roots.map((root) => (
                    <TreeNode
                      key={root.ref}
                      node={root}
                      depth={0}
                      nodes={nodes}
                      onToggle={toggle}
                      onSelect={select}
                      onLoadMore={loadChildren}
                      selectedRef={selected?.ref ?? null}
                    />
                  ))}
                </div>
              )}
            </Panel>

            <Panel
              title="Details"
              description={selected ? selected.displayPath : 'Select an instance.'}
            >
              {!selected ? (
                <EmptyState
                  title="Nothing selected."
                  hint="Pick an instance from the tree or a search result."
                />
              ) : detailLoading ? (
                <EmptyState title="Loading instance…" />
              ) : detailError ? (
                <ErrorNote message={detailError} onRetry={() => void select(selected)} />
              ) : detail ? (
                <InstanceDetail detail={detail} />
              ) : null}
            </Panel>
          </div>
        </>
      )}
    </SessionShell>
  );
}

function TreeNode({
  node,
  depth,
  nodes,
  onToggle,
  onSelect,
  onLoadMore,
  selectedRef,
}: {
  node: InstanceSummary;
  depth: number;
  nodes: Record<string, NodeState>;
  onToggle: (node: InstanceSummary) => void;
  onSelect: (node: InstanceSummary) => void;
  onLoadMore: (node: InstanceSummary, offset: number) => void;
  selectedRef: string | null;
}) {
  const state = nodes[node.ref];
  const expandable = node.childCount > 0;
  const selected = selectedRef === node.ref;

  return (
    <div>
      <div
        className={`flex items-center gap-1 rounded-lg ${selected ? 'bg-clover-600/14' : ''}`}
        style={{ paddingLeft: `${depth * 14}px` }}
      >
        <button
          type="button"
          aria-label={state?.expanded ? `Collapse ${node.name}` : `Expand ${node.name}`}
          disabled={!expandable}
          onClick={() => onToggle(node)}
          className={`flex h-8 w-7 shrink-0 items-center justify-center rounded-md text-[11px] ${
            expandable ? 'text-ink-muted hover:text-ink' : 'text-transparent'
          }`}
        >
          {state?.loading ? '·' : state?.expanded ? '▾' : '▸'}
        </button>
        <button
          type="button"
          onClick={() => onSelect(node)}
          className="min-w-0 flex-1 truncate py-1.5 pr-2 text-left"
        >
          <span className="text-[13px] text-ink">{node.name}</span>
          <span className="ml-2 font-mono text-[11px] text-ink-faint">{node.className}</span>
          {node.childCount > 0 ? (
            <span className="ml-2 text-[11px] text-ink-faint">{node.childCount}</span>
          ) : null}
        </button>
      </div>

      {state?.expanded ? (
        <div>
          {state.error ? (
            <p className="py-1.5 pl-8 text-[12px] text-[#ffb4a8]">{state.error}</p>
          ) : null}
          {state.children.map((child) => (
            <TreeNode
              key={child.ref}
              node={child}
              depth={depth + 1}
              nodes={nodes}
              onToggle={onToggle}
              onSelect={onSelect}
              onLoadMore={onLoadMore}
              selectedRef={selectedRef}
            />
          ))}
          {state.hasMore ? (
            <button
              type="button"
              onClick={() => onLoadMore(node, state.children.length)}
              className="ml-8 my-1 rounded-lg px-2 py-1.5 text-[12px] text-clover-300"
            >
              Load more ({state.children.length} of {state.total})
            </button>
          ) : null}
        </div>
      ) : null}
    </div>
  );
}

function InstanceDetail({ detail }: { detail: Record<string, unknown> }) {
  const tags = Array.isArray(detail.tags) ? (detail.tags as string[]) : [];
  const unavailable = Array.isArray(detail.unavailableProperties)
    ? (detail.unavailableProperties as string[])
    : [];
  const children = Array.isArray(detail.children) ? (detail.children as InstanceSummary[]) : [];
  const displayPath = String(detail.displayPath ?? '');

  const propertyRows = useMemo(() => {
    const properties = (detail.properties ?? {}) as Record<string, unknown>;
    return Object.entries(properties).filter(([key]) => !key.startsWith('__'));
  }, [detail.properties]);

  const attributeRows = useMemo(() => {
    const attributes = (detail.attributes ?? {}) as Record<string, unknown>;
    return Object.entries(attributes).filter(([key]) => !key.startsWith('__'));
  }, [detail.attributes]);

  return (
    <div className="flex flex-col gap-5">
      <div className="rounded-xl border border-line bg-base-800/40 p-4">
        <div className="flex flex-wrap items-start justify-between gap-3">
          <div className="min-w-0">
            <div className="text-[14px] font-medium text-ink">{String(detail.name ?? '?')}</div>
            <div className="mt-1 font-mono text-[11.5px] text-ink-faint">
              {String(detail.className ?? '?')} · ref {String(detail.ref ?? '?')}
            </div>
          </div>
          <CopyButton
            value={displayPath}
            label="Copy path"
            className="cl-btn-ghost !min-h-0 !px-3 !py-1.5 !text-xs"
          />
        </div>
        <p className="cl-scroll mt-3 whitespace-nowrap font-mono text-[11.5px] text-ink-muted">
          {displayPath || '(root)'}
        </p>
        <p className="mt-2 text-[11.5px] text-ink-faint">
          {String(detail.childCount ?? 0)} children
          {detail.childrenTruncated ? ' (list truncated)' : ''}
        </p>
      </div>

      <DetailSection title={`Properties (${propertyRows.length})`}>
        {propertyRows.length === 0 ? (
          <EmptyState title="No safe-registry properties were readable on this class." />
        ) : (
          <ValueTable rows={propertyRows} />
        )}
        {unavailable.length > 0 ? (
          <p className="mt-2 text-[11.5px] text-ink-faint">
            Unavailable on this instance: {unavailable.join(', ')}
          </p>
        ) : null}
      </DetailSection>

      <DetailSection title={`Attributes (${attributeRows.length})`}>
        {attributeRows.length === 0 ? (
          <EmptyState title="No attributes are set on this instance." />
        ) : (
          <ValueTable rows={attributeRows} />
        )}
      </DetailSection>

      <DetailSection title={`Tags (${tags.length})`}>
        {tags.length === 0 ? (
          <EmptyState title="No CollectionService tags." />
        ) : (
          <div className="flex flex-wrap gap-2">
            {tags.map((tag) => (
              <span key={tag} className="cl-pill">
                {tag}
              </span>
            ))}
          </div>
        )}
      </DetailSection>

      {children.length > 0 ? (
        <DetailSection title={`Children preview (${children.length})`}>
          <ul className="cl-scroll max-h-48 divide-y divide-line rounded-xl border border-line">
            {children.map((child) => (
              <li key={child.ref} className="px-3 py-2">
                <span className="text-[12.5px] text-ink">{child.name}</span>
                <span className="ml-2 font-mono text-[11px] text-ink-faint">{child.className}</span>
              </li>
            ))}
          </ul>
        </DetailSection>
      ) : null}
    </div>
  );
}

function DetailSection({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <div>
      <div className="cl-label mb-2">{title}</div>
      {children}
    </div>
  );
}

function ValueTable({ rows }: { rows: [string, unknown][] }) {
  return (
    <div className="cl-scroll max-h-72 rounded-xl border border-line">
      <table className="w-full min-w-[320px] text-left text-[12.5px]">
        <tbody>
          {rows.map(([key, value]) => (
            <tr key={key} className="border-b border-line last:border-b-0 align-top">
              <td className="w-2/5 px-3 py-2 font-mono text-[11.5px] text-ink-muted">{key}</td>
              <td className="px-3 py-2 text-ink">
                {isTaggedValue(value) || typeof value !== 'object'
                  ? formatValue(value)
                  : formatValue(value)}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
