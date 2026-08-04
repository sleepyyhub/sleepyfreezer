import { Router } from 'express';
import passport, { enabledProviders } from './passport.js';
import localRoutes from './local.js';
import { issueSession, clearSession, requireAuth } from '../middleware/auth.js';
import { authorize, channels } from '../realtime/pusher.js';
import prisma from '../db.js';
import config from '../config.js';

const router = Router();

// Email + password sign-in, mounted alongside the OAuth strategies.
router.use('/', localRoutes);

router.get('/providers', (_req, res) =>
  res.json({ providers: enabledProviders, passwordAuth: true }));

for (const provider of enabledProviders) {
  router.get(`/${provider}`, passport.authenticate(provider, { session: false }));

  router.get(
    `/${provider}/callback`,
    passport.authenticate(provider, {
      session: false,
      failureRedirect: `${config.clientUrl}/?auth=failed`,
    }),
    (req, res) => {
      issueSession(res, req.user);
      res.redirect(config.clientUrl);
    },
  );
}

router.get('/me', (req, res) => {
  if (!req.user) return res.json({ user: null });
  const { id, email, name, username, avatarUrl, nsfwEnabled, language, proactiveEnabled } = req.user;
  res.json({ user: { id, email, name, username, avatarUrl, nsfwEnabled, language, proactiveEnabled } });
});

router.post('/logout', (_req, res) => {
  clearSession(res);
  res.json({ ok: true });
});

/**
 * Pusher private-channel auth. The client sends the channel it wants; we only
 * sign it after confirming this user actually owns that conversation or group.
 */
router.post('/realtime', requireAuth, async (req, res) => {
  const { socket_id: socketId, channel_name: channel } = req.body ?? {};
  if (!socketId || !channel) {
    return res.status(400).json({ error: 'socket_id and channel_name are required' });
  }

  const allowed = await ownsChannel(req.user.id, channel);
  if (!allowed) return res.status(403).json({ error: 'Not your channel' });

  try {
    res.send(authorize(socketId, channel));
  } catch (err) {
    res.status(503).json({ error: err.message });
  }
});

async function ownsChannel(userId, channel) {
  if (channel === channels.user(userId)) return true;

  const conversation = channel.match(/^private-conversation-(.+)$/);
  if (conversation) {
    const row = await prisma.conversation.findUnique({
      where: { id: conversation[1] },
      select: { userId: true },
    });
    return row?.userId === userId;
  }

  const group = channel.match(/^private-group-(.+)$/);
  if (group) {
    const row = await prisma.group.findUnique({
      where: { id: group[1] },
      select: { userId: true },
    });
    return row?.userId === userId;
  }

  return false;
}

export default router;
