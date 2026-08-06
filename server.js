import express from 'express';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { ProxyAgent, setGlobalDispatcher } from 'undici';
import 'dotenv/config';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

// Node's fetch ignores HTTPS_PROXY, so route through it explicitly when set.
const proxyUrl = process.env.HTTPS_PROXY || process.env.https_proxy || process.env.HTTP_PROXY;
if (proxyUrl) {
  setGlobalDispatcher(new ProxyAgent(proxyUrl));
  console.log(`  Outbound requests via proxy ${proxyUrl}`);
}

const PORT = process.env.PORT || 3000;
const BASE_URL = (process.env.TOKENROUTER_BASE_URL || 'https://api.tokenrouter.com/v1').replace(/\/+$/, '');
const API_KEY = process.env.TOKENROUTER_API_KEY;
const MODEL = process.env.CLOVYRE_MODEL || 'moonshotai/kimi-k3-free';

if (!API_KEY) {
  console.error('\n  Missing TOKENROUTER_API_KEY. Copy .env.example to .env and add your key.\n');
  process.exit(1);
}

const app = express();
app.use(express.json({ limit: '25mb' }));

app.get('/api/config', (_req, res) => {
  res.json({ model: MODEL });
});

// Streaming proxy. The API key never leaves the server.
app.post('/api/chat', async (req, res) => {
  const { messages, tools, temperature, top_p, max_tokens, model } = req.body || {};

  if (!Array.isArray(messages) || messages.length === 0) {
    return res.status(400).json({ error: 'messages must be a non-empty array' });
  }

  // Abort upstream when the browser disconnects. This must hang off the
  // response: `req` emits 'close' as soon as its body has been consumed.
  const controller = new AbortController();
  res.on('close', () => controller.abort());

  const payload = {
    model: model || MODEL,
    messages,
    stream: true,
    stream_options: { include_usage: true },
  };
  if (Array.isArray(tools) && tools.length) {
    payload.tools = tools;
    payload.tool_choice = 'auto';
  }
  if (typeof temperature === 'number') payload.temperature = temperature;
  if (typeof top_p === 'number') payload.top_p = top_p;
  if (typeof max_tokens === 'number') payload.max_tokens = max_tokens;

  // The gateway occasionally drops a connection before responding. Nothing has
  // been streamed to the browser yet at this point, so retrying is safe.
  let upstream;
  let lastError;
  for (let attempt = 0; attempt < 3; attempt++) {
    if (controller.signal.aborted) return res.end();
    try {
      upstream = await fetch(`${BASE_URL}/chat/completions`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${API_KEY}`,
        },
        body: JSON.stringify(payload),
        signal: controller.signal,
      });
      break;
    } catch (err) {
      if (controller.signal.aborted) return res.end();
      lastError = err;
      const cause = err.cause?.message || err.cause?.code || '';
      console.error(`[clovyre] upstream attempt ${attempt + 1} failed:`, err.message, cause);
      await new Promise((r) => setTimeout(r, 500 * 2 ** attempt));
    }
  }

  if (!upstream) {
    return res.status(502).json({
      error: 'Could not reach TokenRouter after 3 attempts',
      detail: lastError?.cause?.message || lastError?.message || '',
    });
  }

  if (!upstream.ok || !upstream.body) {
    const detail = await upstream.text().catch(() => '');
    return res.status(upstream.status || 502).json({
      error: `TokenRouter returned ${upstream.status}`,
      detail: detail.slice(0, 2000),
    });
  }

  res.setHeader('Content-Type', 'text/event-stream; charset=utf-8');
  res.setHeader('Cache-Control', 'no-cache, no-transform');
  res.setHeader('Connection', 'keep-alive');
  res.setHeader('X-Accel-Buffering', 'no');
  res.flushHeaders?.();

  try {
    for await (const chunk of upstream.body) {
      res.write(chunk);
    }
  } catch {
    // client hung up or upstream broke mid-stream; nothing useful to send
  }
  res.end();
});

app.use(express.static(path.join(__dirname, 'public'), { extensions: ['html'] }));

app.listen(PORT, () => {
  console.log(`\n  Clovyre running on http://localhost:${PORT}  ·  model: ${MODEL}\n`);
});
