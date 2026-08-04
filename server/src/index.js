import express from 'express';
import cors from 'cors';
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
import { brand } from '../../shared/brand.js';

const app = express();

app.use(
  cors({
    origin: config.clientUrl,
    credentials: true,
  }),
);
app.use(express.json({ limit: '1mb' }));
app.use(cookieParser());
app.use(passport.initialize());
app.use(attachUser);

app.get('/api/health', (_req, res) =>
  res.json({ ok: true, app: brand.name, models: config.ai.models }),
);

app.use('/api/auth', authRoutes);
app.use('/api/characters', characterRoutes);
app.use('/api/conversations', conversationRoutes);
app.use('/api/groups', groupRoutes);
app.use('/api/settings', settingsRoutes);
app.use('/api/cron', cronRoutes);

app.use((_req, res) => res.status(404).json({ error: 'Not found' }));

// eslint-disable-next-line no-unused-vars
app.use((err, _req, res, _next) => {
  console.error('[error]', err);
  res.status(err.status ?? 500).json({
    error: config.isProd ? 'Something went wrong' : err.message,
  });
});

app.listen(config.port, () => {
  console.log(`${brand.name} API on http://localhost:${config.port}`);
  console.log(`  models: ${config.ai.models.join(' -> ')}`);
  console.log(`  temp:   ${config.ai.temperature}`);
  console.log(`  client: ${config.clientUrl}`);
});

export default app;
