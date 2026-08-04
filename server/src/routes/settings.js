import { Router } from 'express';
import { z } from 'zod';
import prisma from '../db.js';
import { requireAuth } from '../middleware/auth.js';

const router = Router();
router.use(requireAuth);

const settingsInput = z.object({
  name: z.string().min(1).max(60).optional(),
  nsfwEnabled: z.boolean().optional(),
  // "auto" mirrors whatever the user writes in; anything else pins the reply language.
  language: z.string().min(2).max(40).optional(),
  proactiveEnabled: z.boolean().optional(),
});

router.get('/', (req, res) => {
  const { id, email, name, avatarUrl, nsfwEnabled, language, proactiveEnabled } = req.user;
  res.json({ settings: { id, email, name, avatarUrl, nsfwEnabled, language, proactiveEnabled } });
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
        avatarUrl: true,
        nsfwEnabled: true,
        language: true,
        proactiveEnabled: true,
      },
    });

    res.json({ settings: user });
  } catch (err) {
    next(err);
  }
});

export default router;
