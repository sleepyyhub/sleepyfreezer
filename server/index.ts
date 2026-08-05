import { createServer, type IncomingMessage, type ServerResponse } from 'node:http';
import next from 'next';
import { getConfig } from '../src/lib/config';
import { createRobloxGateway, ROBLOX_WS_PATH } from './websocket-server';

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
    void gateway.close().finally(() => {
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
