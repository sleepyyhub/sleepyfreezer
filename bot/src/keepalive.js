import { createServer } from 'node:http';

/**
 * Render Web Services müssen einen Port öffnen, sonst gilt der Deploy als
 * fehlgeschlagen. Der Free Tier schläft zusätzlich nach 15 Minuten ohne
 * Requests ein — diese Route ist der Anker für einen externen Pinger
 * (UptimeRobot, cron-job.org, …), der den Bot wachhält.
 */
export function startKeepAlive(getStatus) {
  const port = Number(process.env.PORT || 3000);

  const server = createServer((req, res) => {
    if (req.url === '/health' || req.url === '/') {
      res.writeHead(200, { 'Content-Type': 'application/json' });
      res.end(JSON.stringify({ status: 'ok', ...getStatus() }));
      return;
    }
    res.writeHead(404).end();
  });

  server.listen(port, () => console.log(`[keepalive] lauscht auf Port ${port}`));
  return server;
}
