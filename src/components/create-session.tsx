'use client';

import { useRouter } from 'next/navigation';
import { useState } from 'react';
import { ErrorNote } from './ui';

/**
 * Session creation. The response carries the only copy of the Roblox and MCP
 * tokens, so they are handed straight to the dashboard through sessionStorage and
 * never written anywhere durable.
 */

export const SECRETS_STORAGE_PREFIX = 'clovyre.secrets.';



export interface StoredSecrets {
  robloxToken: string;
  mcpToken: string;
  loadstring: string;
  mcpUrl: string;
  mcpConnectorUrl: string;
  mcpRemoteJson: string;
  mcpProxyJson: string;
  authorizationHeader: string;
  claudeCodeCommand: string;
}

export function CreateSessionButton({ className = 'cl-btn-primary' }: { className?: string }) {
  const router = useRouter();
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const create = async () => {
    setBusy(true);
    setError(null);
    try {
      const response = await fetch('/api/sessions', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({}),
      });
      const payload = await response.json();

      if (!response.ok) {
        setError(
          payload?.error?.message ?? 'Clovyre could not create a session. Please try again.',
        );
        return;
      }

      const secrets: StoredSecrets = {
        robloxToken: payload.secrets.robloxToken,
        mcpToken: payload.secrets.mcpToken,
        loadstring: payload.loadstring,
        mcpUrl: payload.mcpConfig.url,
        mcpConnectorUrl: payload.mcpConfig.connectorUrl,
        mcpRemoteJson: payload.mcpConfig.remoteJson,
        mcpProxyJson: payload.mcpConfig.proxyJson,
        authorizationHeader: payload.mcpConfig.authorizationHeader,
        claudeCodeCommand: payload.mcpConfig.claudeCodeCommand,
      };

      try {
        // Session-scoped and tab-scoped: closing the tab discards the tokens.
        sessionStorage.setItem(
          `${SECRETS_STORAGE_PREFIX}${payload.session.id}`,
          JSON.stringify(secrets),
        );
      } catch {
        // Private-mode Safari can refuse storage; the dashboard handles that case.
      }

      router.push(`/session/${payload.session.id}`);
    } catch {
      setError('The network request failed. Check your connection and try again.');
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="w-full">
      <button type="button" onClick={create} disabled={busy} className={className}>
        {busy ? 'Creating session…' : 'Create session'}
      </button>
      {error ? (
        <div className="mt-3">
          <ErrorNote message={error} onRetry={create} />
        </div>
      ) : null}
    </div>
  );
}
