import { createServer, type IncomingMessage, type ServerResponse } from 'node:http';
import next from 'next';
import { getConfig } from '../src/lib/config';
import { createRobloxGateway, ROBLOX_WS_PATH } from './websocket-server';
import { getSessionStore } from '../src/lib/sessions/store';
import { closePool, initialiseSchema, persistenceEnabled } from '../src/lib/sessions/persistence';

/**
 * Clovyre process entry point.
 *
 * The Next.js app and the Roblox WebSocket gateway share one HTTP server so that
 * a single Render web service can hold long-lived upgrade connections alongside
 * the dashboard, the session API and the remote MCP endpoint.
 */

async function main(): Promise<void> {
  const config = getConfig();
  const dev = config.nodeEnv !== 'production';

  const app = next({ dev, dir: process.cwd() });
  const handle = app.getRequestHandler();
  await app.prepare();

  // Sessions are what users configure their agents against, so they are restored
  // before the first request rather than lazily: a request that arrived first
  // would otherwise be told its perfectly valid session does not exist.
  if (persistenceEnabled()) {
    try {
      await initialiseSchema();
      const restored = await getSessionStore().hydrate();
      console.warn(`[clovyre] restored ${restored} persisted session(s).`);
    } catch (error) {
      console.error(
        '[clovyre] session persistence is unavailable; running in memory only:',
        error instanceof Error ? error.message : error,
      );
    }
  } else {
    console.warn('[clovyre] DATABASE_URL is not set; sessions will not survive a restart.');
  }

  const server = createServer((request: IncomingMessage, response: ServerResponse) => {
    handle(request, response).catch((error: unknown) => {
      console.error(
        '[clovyre] request handler failed:',
        error instanceof Error ? error.message : error,
      );
      if (!response.headersSent) {
        response.statusCode = 500;
        response.setHeader('content-type', 'application/json');
      }
      response.end(JSON.stringify({ error: 'Internal server error.' }));
    });
  });

  // Render's proxy idles connections out at 100s; keep ours a little longer.
  server.keepAliveTimeout = 120_000;
  server.headersTimeout = 125_000;

  const gateway = createRobloxGateway(server);

  await new Promise<void>((resolve) => {
    server.listen(config.port, () => resolve());
  });

  console.warn(
    `[clovyre] v${config.version} listening on port ${config.port} ` +
      `(${config.nodeEnv}); Roblox gateway at ${ROBLOX_WS_PATH}`,
  );

  const shutdown = (signal: string) => {
    console.warn(`[clovyre] ${signal} received, shutting down.`);
    void gateway
      .close()
      .then(() => closePool())
      .finally(() => {
      server.close(() => process.exit(0));
      // Do not let a stuck connection block the restart forever.
      setTimeout(() => process.exit(0), 8_000).unref();
    });
  };

  process.on('SIGTERM', () => shutdown('SIGTERM'));
  process.on('SIGINT', () => shutdown('SIGINT'));

  process.on('unhandledRejection', (reason) => {
    console.error(
      '[clovyre] unhandled rejection:',
      reason instanceof Error ? reason.message : String(reason),
    );
  });
}

main().catch((error: unknown) => {
  console.error('[clovyre] failed to start:', error instanceof Error ? error.stack : error);
  process.exit(1);
});
