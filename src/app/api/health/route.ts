import { getConfig } from '@/lib/config';
import { jsonResponse } from '@/lib/api/http';
import { getSessionBroker } from '@/lib/sessions/broker';
import { getSessionStore } from '@/lib/sessions/store';
import { TOOL_DEFINITIONS } from '@/lib/tools/registry';
import { PROTOCOL_VERSION } from '@/lib/protocol/messages';
import { persistenceEnabled } from '@/lib/sessions/persistence';

export const runtime = 'nodejs';
export const dynamic = 'force-dynamic';

/**
 * GET /api/health
 *
 * Service status for Render health checks and the status pill on the landing page.
 * Reports dependency state without disclosing configuration values or secrets.
 */
export function GET(): Response {
  const config = getConfig();
  const store = getSessionStore();
  const broker = getSessionBroker();
  const stats = store.stats();

  return jsonResponse({
    status: 'ok',
    service: 'clovyre-mcp',
    version: config.version,
    protocolVersion: PROTOCOL_VERSION,
    uptimeSeconds: Math.floor(process.uptime()),
    timestamp: new Date().toISOString(),
    dependencies: {
      sessionStore: persistenceEnabled()
        ? { kind: 'postgres', status: 'ok', durable: true }
        : { kind: 'memory', status: 'ok', durable: false },
      websocketGateway: { status: 'ok', connections: broker.connectionCount },
      mcp: { status: 'ok', transport: 'streamable-http', tools: TOOL_DEFINITIONS.length },
    },
    sessions: stats,
    pendingCommands: broker.pendingCount,
    features: {
      executeLuau: config.executeLuauFeatureEnabled,
      mutationTools: config.mutationToolsFeatureEnabled,
      ownershipVerification: false,
    },
  });
}
