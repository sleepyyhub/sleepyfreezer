import { Router } from 'express';
import { z } from 'zod';
import prisma from '../db.js';
import { clearSession, requireAuth } from '../middleware/auth.js';

const router = Router();
router.use(requireAuth);

const settingsInput = z.object({
  name: z.string().min(1).max(60).optional(),
  nsfwEnabled: z.boolean().optional(),
  // "auto" mirrors whatever the user writes in; anything else pins the reply language.
  language: z.string().min(2).max(40).optional(),
  proactiveEnabled: z.boolean().optional(),
  sceneImagesEnabled: z.boolean().optional(),
});

router.get('/', (req, res) => {
  const { id, email, name, username, avatarUrl, nsfwEnabled, language, proactiveEnabled, sceneImagesEnabled } = req.user;
  res.json({
    settings: {
      id, email, name, username, avatarUrl,
      nsfwEnabled, language, proactiveEnabled, sceneImagesEnabled,
    },
  });
});

router.patch('/', async (req, res, next) => {
  try {
    const parsed = settingsInput.safeParse(req.body);
    if (!parsed.success) {
      return res.status(400).json({ error: 'Invalid settings', issues: parsed.error.issues });
    }

    const user = await prisma.user.update({
      where: { id: req.user.id },
      data: parsed.data,
      select: {
        id: true,
        email: true,
        name: true,
        username: true,
        avatarUrl: true,
        nsfwEnabled: true,
        language: true,
        proactiveEnabled: true,
        sceneImagesEnabled: true,
      },
    });

    res.json({ settings: user });
  } catch (err) {
    next(err);
  }
});

/**
 * Delete the account for real.
 *
 * Everything personal cascades from the user row — accounts, conversations,
 * groups, and through those the messages and memories. Characters the user
 * published are the exception: `creatorId` is `SetNull`, so they survive as
 * unattributed rather than vanishing out of other people's chats.
 *
 * The confirmation is the username or email typed back, which is the usual
 * bar for an irreversible action and the only proof available for an account
 * that signed in through Google or Discord and has no password here.
 */
router.delete('/account', async (req, res, next) => {
  try {
    const typed = String(req.body?.confirm ?? '').trim().toLowerCase();
    const expected = (req.user.username ?? req.user.email).toLowerCase();

    if (typed !== expected) {
      return res.status(400).json({
        error: `Type ${req.user.username ?? req.user.email} to confirm`,
      });
    }

    await prisma.user.delete({ where: { id: req.user.id } });
    clearSession(res);
    res.json({ deleted: true });
  } catch (err) {
    next(err);
  }
});

export default router;
