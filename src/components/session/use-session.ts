'use client';

import { useCallback, useEffect, useMemo, useRef, useState, useSyncExternalStore } from 'react';
import type { SessionView } from '@/lib/sessions/view';
import { SECRETS_STORAGE_PREFIX, type StoredSecrets } from '../create-session';

/**
 * Dashboard data layer.
 *
 * State is polled rather than streamed: a short interval is more reliable across
 * iPad Safari backgrounding than a long-lived EventSource, and the payload is
 * small. Polling pauses while the tab is hidden.
 */

export interface SessionEndpoints {
  baseUrl: string;
  websocket: string;
  mcp: string;
  clientScript: string;
}

export interface AgentLinkView {
  token: string;
  url: string;
  remoteJson: string;
  proxyJson: string;
  claudeCodeCommand: string;
}

export interface SessionState {
  session: SessionView | null;
  endpoints: SessionEndpoints | null;
  agentLink: AgentLinkView | null;
  loading: boolean;
  error: string | null;
  /** True when the browser holds no owner cookie for this session. */
  unauthorised: boolean;
}

const POLL_INTERVAL_MS = 2500;

function readCsrfToken(sessionId: string): string | null {
  const name = `clovyre_csrf_${sessionId}=`;
  for (const part of document.cookie.split('; ')) {
    if (part.startsWith(name)) return decodeURIComponent(part.slice(name.length));
  }
  return null;
}

/** sessionStorage never changes under us, so the subscription is a no-op. */
const subscribeToNothing = () => () => undefined;

export function useSession(sessionId: string) {
  const [state, setState] = useState<SessionState>({
    session: null,
    endpoints: null,
    agentLink: null,
    loading: true,
    error: null,
    unauthorised: false,
  });
  const mounted = useRef(true);

  useEffect(() => {
    mounted.current = true;
    return () => {
      mounted.current = false;
    };
  }, []);

  // Tokens are handed over by the creation flow through sessionStorage. Reading
  // them through useSyncExternalStore keeps the server render (null) and the
  // client render consistent without a state-setting effect.
  const rawSecrets = useSyncExternalStore(
    subscribeToNothing,
    () => {
      try {
        return sessionStorage.getItem(`${SECRETS_STORAGE_PREFIX}${sessionId}`);
      } catch {
        // Private-mode Safari can refuse storage entirely.
        return null;
      }
    },
    () => null,
  );

  // Rotated credentials arrive after mount, so they live in state and take
  // precedence over whatever the creation flow stored.
  const [rotated, setRotated] = useState<Partial<StoredSecrets> | null>(null);

  const secrets = useMemo<StoredSecrets | null>(() => {
    let stored: StoredSecrets | null = null;
    if (rawSecrets) {
      try {
        stored = JSON.parse(rawSecrets) as StoredSecrets;
      } catch {
        stored = null;
      }
    }
    if (!stored && !rotated) return null;
    return { ...(stored ?? {}), ...(rotated ?? {}) } as StoredSecrets;
  }, [rawSecrets, rotated]);

  const refresh = useCallback(async () => {
    try {
      const response = await fetch(`/api/sessions/${sessionId}`, { cache: 'no-store' });
      if (!mounted.current) return;

      if (response.status === 401 || response.status === 404) {
        const payload = await response.json().catch(() => null);
        setState((previous) => ({
          ...previous,
          loading: false,
          unauthorised: true,
          error: payload?.error?.message ?? 'This session is not available in this browser.',
        }));
        return;
      }

      if (!response.ok) {
        setState((previous) => ({
          ...previous,
          loading: false,
          error: 'Clovyre could not load this session. Retrying.',
        }));
        return;
      }

      const payload = await response.json();
      setState((previous) => ({
        ...previous,
        session: payload.session as SessionView,
        endpoints: payload.endpoints as SessionEndpoints,
        agentLink: (payload.agentLink as AgentLinkView | null) ?? null,
        loading: false,
        error: null,
        unauthorised: false,
      }));
    } catch {
      if (!mounted.current) return;
      setState((previous) => ({
        ...previous,
        loading: false,
        error: 'The connection to Clovyre failed. Retrying.',
      }));
    }
  }, [sessionId]);

  useEffect(() => {
    let timer: ReturnType<typeof setInterval> | null = null;
    // The initial load is deferred to a task so the effect body itself never
    // sets state; `refresh` only writes after its first await resolves.
    const initial = setTimeout(() => void refresh(), 0);

    const start = () => {
      if (timer) return;
      timer = setInterval(() => void refresh(), POLL_INTERVAL_MS);
    };
    const stop = () => {
      if (!timer) return;
      clearInterval(timer);
      timer = null;
    };

    const onVisibility = () => {
      if (document.visibilityState === 'visible') {
        void refresh();
        start();
      } else {
        stop();
      }
    };

    if (document.visibilityState === 'visible') start();
    document.addEventListener('visibilitychange', onVisibility);
    return () => {
      clearTimeout(initial);
      stop();
      document.removeEventListener('visibilitychange', onVisibility);
    };
  }, [refresh]);

  /** Owner-authenticated mutation with the double-submit CSRF token attached. */
  const mutate = useCallback(
    async (
      path: string,
      init: { method?: string; body?: unknown } = {},
    ): Promise<{ ok: boolean; data: unknown; message: string | null }> => {
      const csrf = readCsrfToken(sessionId);
      if (!csrf) {
        return {
          ok: false,
          data: null,
          message: 'This browser no longer holds the owner credential for this session.',
        };
      }
      try {
        const response = await fetch(path, {
          method: init.method ?? 'POST',
          headers: { 'content-type': 'application/json', 'x-clovyre-csrf': csrf },
          body: JSON.stringify(init.body ?? {}),
        });
        const data = await response.json().catch(() => null);
        if (!response.ok) {
          return {
            ok: false,
            data,
            message:
              (data as { error?: { message?: string } } | null)?.error?.message ??
              'The request was rejected by Clovyre.',
          };
        }
        void refresh();
        return { ok: true, data, message: null };
      } catch {
        return {
          ok: false,
          data: null,
          message: 'The network request failed. Check your connection.',
        };
      }
    },
    [refresh, sessionId],
  );

  /** Runs a Clovyre tool through the owner route (same path MCP clients use). */
  const callTool = useCallback(
    async (tool: string, args: Record<string, unknown> = {}) => {
      const outcome = await mutate(`/api/sessions/${sessionId}/tools`, {
        body: { tool, arguments: args },
      });
      if (!outcome.ok) {
        return {
          ok: false as const,
          code: 'REQUEST_FAILED',
          message: outcome.message ?? 'Request failed.',
          data: null,
        };
      }
      const result = (outcome.data as { result?: Record<string, unknown> } | null)?.result;
      if (!result) {
        return {
          ok: false as const,
          code: 'BAD_RESPONSE',
          message: 'Clovyre returned an unexpected response.',
          data: null,
        };
      }
      if (result.ok === true) {
        return { ok: true as const, data: result.data, truncated: Boolean(result.truncated) };
      }
      return {
        ok: false as const,
        code: String(result.code ?? 'ERROR'),
        message: String(result.message ?? 'The tool call failed.'),
        data: null,
      };
    },
    [mutate, sessionId],
  );

  /**
   * Issues a fresh Roblox or MCP credential so the dashboard can always show a
   * working script. Only digests are stored server-side, so a token that has
   * scrolled out of this tab genuinely cannot be recovered — regenerating is the
   * honest alternative to showing nothing.
   */
  const regenerate = useCallback(
    async (
      role: 'roblox' | 'mcp',
      options: { force?: boolean } = {},
    ): Promise<{ ok: boolean; message: string | null; requiresConfirmation: boolean }> => {
      const outcome = await mutate(`/api/sessions/${sessionId}/credentials/rotate`, {
        body: { role, force: options.force ?? false },
      });

      if (!outcome.ok) {
        const requiresConfirmation = Boolean(
          (outcome.data as { error?: { requiresConfirmation?: boolean } } | null)?.error
            ?.requiresConfirmation,
        );
        return { ok: false, message: outcome.message, requiresConfirmation };
      }

      const payload = outcome.data as {
        secret: string;
        loadstring?: string;
        mcpConfig?: {
          url: string;
          connectorUrl: string;
          authorizationHeader: string;
          claudeCodeCommand: string;
          remoteJson: string;
          proxyJson: string;
        };
      };

      const next: Partial<StoredSecrets> =
        role === 'roblox'
          ? { robloxToken: payload.secret, loadstring: payload.loadstring }
          : {
              mcpToken: payload.secret,
              mcpUrl: payload.mcpConfig?.url,
              mcpConnectorUrl: payload.mcpConfig?.connectorUrl,
              authorizationHeader: payload.mcpConfig?.authorizationHeader,
              claudeCodeCommand: payload.mcpConfig?.claudeCodeCommand,
              mcpRemoteJson: payload.mcpConfig?.remoteJson,
              mcpProxyJson: payload.mcpConfig?.proxyJson,
            };

      setRotated((previous) => ({ ...(previous ?? {}), ...next }));

      // Keep the tab's copy in step so a reload does not lose it again.
      try {
        const key = `${SECRETS_STORAGE_PREFIX}${sessionId}`;
        const existing = sessionStorage.getItem(key);
        const merged = { ...(existing ? JSON.parse(existing) : {}), ...next };
        sessionStorage.setItem(key, JSON.stringify(merged));
      } catch {
        // Storage refused; the in-memory copy still drives this tab.
      }

      return { ok: true, message: null, requiresConfirmation: false };
    },
    [mutate, sessionId],
  );

  return { ...state, secrets, refresh, mutate, callTool, regenerate };
}
