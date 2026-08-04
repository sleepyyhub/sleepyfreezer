import express from 'express';
import cors from 'cors';
import path from 'node:path';
import { existsSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import cookieParser from 'cookie-parser';
import config from './config.js';
import passport from './auth/passport.js';
import { attachUser } from './middleware/auth.js';
import authRoutes from './auth/routes.js';
import characterRoutes from './routes/characters.js';
import conversationRoutes from './routes/conversations.js';
import groupRoutes from './routes/groups.js';
import settingsRoutes from './routes/settings.js';
import cronRoutes from './routes/cron.js';
import { startScheduler } from './services/scheduler.js';
import { configuredProviders, configuredLadder } from './ai/client.js';
import { brand } from '../../shared/brand.js';

const dirname = path.dirname(fileURLToPath(import.meta.url));

const app = express();

// Harmless when the API also serves the frontend — the browser sends no
// preflight for same-origin requests. It matters for `npm run dev:web`, where
// Vite is on another port, and for a split deployment.
app.use(cors({ origin: config.clientUrl, credentials: true }));
app.use(express.json({ limit: '1mb' }));
app.use(cookieParser());
app.use(passport.initialize());
app.use(attachUser);

app.get('/api/health', (_req, res) =>
  res.json({ ok: true, app: brand.name, providers: configuredProviders, ladder: configuredLadder }),
);

app.use('/api/auth', authRoutes);
app.use('/api/characters', characterRoutes);
app.use('/api/conversations', conversationRoutes);
app.use('/api/groups', groupRoutes);
app.use('/api/settings', settingsRoutes);
app.use('/api/cron', cronRoutes);

/**
 * Serve the built frontend when it exists, so the whole app runs from one
 * origin. That keeps the session cookie first-party and removes CORS from the
 * picture entirely — useful in production and when exposing a dev instance
 * through a tunnel.
 */
const webDist = path.resolve(dirname, '../../web/dist');
if (existsSync(webDist)) {
  app.use(express.static(webDist));
  app.get(/^\/(?!api\/).*/, (_req, res) => res.sendFile(path.join(webDist, 'index.html')));
  console.log(`  web:    serving ${webDist}`);
}

app.use((_req, res) => res.status(404).json({ error: 'Not found' }));

// eslint-disable-next-line no-unused-vars
app.use((err, _req, res, _next) => {
  console.error('[error]', err);
  const status = err.status ?? 500;
  // Messages we wrote ourselves are useful to the person who hit them and are
  // shown verbatim; only a genuine internal failure is hidden. 502 here means
  // the upstream model misbehaved, which the reader can act on by retrying.
  const safe = status < 500 || status === 502 || status === 503 || !config.isProd;
  res.status(status).json({ error: safe ? err.message : 'Something went wrong' });
});

app.listen(config.port, () => {
  console.log(`${brand.name} API on http://localhost:${config.port}`);
  console.log(`  models: ${configuredLadder.join(' -> ') || '(none configured)'}`);
  console.log(`  temp:   ${config.ai.temperature}`);
  console.log(`  client: ${config.clientUrl}`);
  startScheduler();
});

export default app;
