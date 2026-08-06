#!/usr/bin/env node
/*
 * serve.js — static server for the arena, plus an optional CORS relay.
 *
 *   node arena/serve.js            # http://localhost:8080
 *   node arena/serve.js 9000       # pick a port
 *
 * The arena loads as ES modules, so it needs to be served over http rather
 * than opened as a file:// URL.
 *
 * CORS relay: browsers block direct calls to an endpoint that does not send
 * CORS headers. If a "Test" click fails with a CORS/network error even though
 * the endpoint works from curl, set the team's Base URL to:
 *
 *   http://localhost:8080/relay/http://106.54.43.21:3000/v1
 *
 * and the request is forwarded from Node instead, where CORS does not apply.
 */

import { createServer } from 'node:http';
import { readFile } from 'node:fs/promises';
import { extname, join, normalize } from 'node:path';
import { fileURLToPath } from 'node:url';

const ROOT = fileURLToPath(new URL('.', import.meta.url));
const PORT = parseInt(process.argv[2], 10) || 8080;

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml',
};

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'Content-Type, Authorization',
  'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
};

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on('data', (chunk) => chunks.push(chunk));
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
  });
}

async function handleRelay(req, res, targetUrl) {
  if (!/^https?:\/\//i.test(targetUrl)) {
    res.writeHead(400, { 'Content-Type': 'text/plain', ...CORS });
    res.end('relay target must be an absolute http(s) URL');
    return;
  }

  const body = req.method === 'POST' ? await readBody(req) : undefined;
  const headers = { 'Content-Type': 'application/json' };
  if (req.headers.authorization) headers.Authorization = req.headers.authorization;

  try {
    const upstream = await fetch(targetUrl, { method: req.method, headers, body });
    const text = await upstream.text();
    res.writeHead(upstream.status, {
      'Content-Type': upstream.headers.get('content-type') || 'application/json',
      ...CORS,
    });
    res.end(text);
  } catch (error) {
    res.writeHead(502, { 'Content-Type': 'text/plain', ...CORS });
    res.end(`relay failed: ${error.message}`);
  }
}

const server = createServer(async (req, res) => {
  if (req.method === 'OPTIONS') {
    res.writeHead(204, CORS);
    res.end();
    return;
  }

  const url = new URL(req.url, `http://localhost:${PORT}`);

  if (url.pathname.startsWith('/relay/')) {
    // Everything after /relay/ is the upstream URL, query string included.
    const target = req.url.slice('/relay/'.length);
    await handleRelay(req, res, target);
    return;
  }

  const requested = url.pathname === '/' ? '/index.html' : url.pathname;
  const filePath = join(ROOT, normalize(requested).replace(/^(\.\.[/\\])+/, ''));
  if (!filePath.startsWith(ROOT)) {
    res.writeHead(403).end('forbidden');
    return;
  }

  try {
    const data = await readFile(filePath);
    res.writeHead(200, { 'Content-Type': MIME[extname(filePath)] || 'application/octet-stream' });
    res.end(data);
  } catch {
    res.writeHead(404, { 'Content-Type': 'text/plain' });
    res.end('not found');
  }
});

server.listen(PORT, () => {
  console.log(`Math Weapon Arena  →  http://localhost:${PORT}`);
  console.log(`CORS relay          →  http://localhost:${PORT}/relay/<full-endpoint-url>`);
});
