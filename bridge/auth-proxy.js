// Tiny bearer-token gate in front of supergateway. Rejects anything without
// "Authorization: Bearer <MCP_TOKEN>", forwards everything else (incl. SSE streams).
const http = require('http');
const crypto = require('crypto');

const token = process.env.MCP_TOKEN;
const listenPort = Number(process.env.PROXY_PORT || 8001);
const targetPort = Number(process.env.TARGET_PORT || 8000);
if (!token) { console.error('MCP_TOKEN not set'); process.exit(1); }
const expected = Buffer.from(`Bearer ${token}`);

http.createServer((req, res) => {
  const got = Buffer.from(req.headers.authorization || '');
  if (got.length !== expected.length || !crypto.timingSafeEqual(got, expected)) {
    res.writeHead(401).end('unauthorized');
    return;
  }
  const headers = { ...req.headers, host: `127.0.0.1:${targetPort}` };
  delete headers.authorization;
  const upstream = http.request(
    { host: '127.0.0.1', port: targetPort, path: req.url, method: req.method, headers },
    (up) => { res.writeHead(up.statusCode, up.headers); up.pipe(res); }
  );
  upstream.on('error', () => { if (!res.headersSent) res.writeHead(502); res.end('gateway down'); });
  req.pipe(upstream);
}).listen(listenPort, '127.0.0.1', () => console.log(`auth proxy on :${listenPort} -> :${targetPort}`));
