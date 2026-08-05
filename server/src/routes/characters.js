import { Router } from 'express';
import { z } from 'zod';
import prisma from '../db.js';
import { requireAuth } from '../middleware/auth.js';
import { composeCharacter } from '../ai/compose.js';
import { generateAvatar, imageGenerationEnabled } from '../ai/image.js';

const router = Router();

const publicFields = {
  id: true,
  name: true,
  universe: true,
  tagline: true,
  tags: true,
  avatarUrl: true,
  themeColor: true,
  nsfwAllowed: true,
  isFeatured: true,
  messageCount: true,
  createdAt: true,
  creatorId: true,
  avatarMime: true, // presence of a generated avatar; the bytes are served separately
};

const SORTS = {
  popular: [{ messageCount: 'desc' }, { createdAt: 'desc' }],
  new: [{ createdAt: 'desc' }],
  name: [{ name: 'asc' }],
};

/**
 * Mark which of these characters the signed-in user has bookmarked.
 *
 * One extra query for the whole page rather than a relation on every row: the
 * list is read constantly and by signed-out visitors too, for whom the answer
 * is always false and no query runs at all.
 */
async function withSavedFlag(characters, user) {
  if (!user || characters.length === 0) {
    return characters.map((c) => ({ ...c, saved: false }));
  }

  const rows = await prisma.savedCharacter.findMany({
    where: { userId: user.id, characterId: { in: characters.map((c) => c.id) } },
    select: { characterId: true },
  });
  const saved = new Set(rows.map((r) => r.characterId));

  return characters.map((c) => ({ ...c, saved: saved.has(c.id) }));
}

/** GET /api/characters?filter=popular&q=nino&tag=tsundere */
router.get('/', async (req, res, next) => {
  try {
    const { q, tag, filter = 'popular' } = req.query;
    const limit = Math.min(Number(req.query.limit) || 40, 100);
    const cursor = req.query.cursor;

    const where = { isPublic: true };

    // Users who have not enabled mature content never see mature characters.
    if (!req.user?.nsfwEnabled) where.nsfwAllowed = false;

    if (filter === 'mine') {
      if (!req.user) return res.status(401).json({ error: 'Not signed in' });
      delete where.isPublic;
      where.creatorId = req.user.id;
    } else if (filter === 'community') {
      where.creatorId = { not: null };
    } else if (filter === 'saved') {
      if (!req.user) return res.status(401).json({ error: 'Not signed in' });
      where.savedBy = { some: { userId: req.user.id } };
    }

    if (q) {
      where.OR = [
        { name: { contains: q, mode: 'insensitive' } },
        { universe: { contains: q, mode: 'insensitive' } },
        { tagline: { contains: q, mode: 'insensitive' } },
      ];
    }
    if (tag) where.tags = { has: tag };

    const characters = await prisma.character.findMany({
      where,
      select: publicFields,
      orderBy: SORTS[filter] ?? SORTS.popular,
      take: limit + 1,
      ...(cursor ? { skip: 1, cursor: { id: cursor } } : {}),
    });

    const hasMore = characters.length > limit;
    const page = hasMore ? characters.slice(0, limit) : characters;

    res.json({
      characters: await withSavedFlag(page, req.user),
      nextCursor: hasMore ? characters[limit - 1].id : null,
    });
  } catch (err) {
    next(err);
  }
});

/** GET /api/characters/:id */
router.get('/:id', async (req, res, next) => {
  try {
    const character = await prisma.character.findUnique({
      where: { id: req.params.id },
      select: {
        ...publicFields,
        personality: true,
        lore: true,
        // Shown on the character page: the sample lines are the most concrete
        // thing you can read about someone before talking to them.
        speakingStyle: true,
        creator: { select: { id: true, name: true, avatarUrl: true } },
      },
    });

    if (!character) return res.status(404).json({ error: 'Character not found' });
    if (character.nsfwAllowed && !req.user?.nsfwEnabled) {
      return res.status(403).json({ error: 'Enable mature content to view this character' });
    }

    const [withFlag] = await withSavedFlag([character], req.user);
    res.json({ character: withFlag });
  } catch (err) {
    next(err);
  }
});

const composeInput = z.object({
  name: z.string().trim().min(1, 'Enter a character name').max(60),
  universe: z.string().trim().max(80).default(''),
});

/**
 * POST /api/characters/compose
 *
 * Drafts a full character sheet from a name and a universe. Deliberately does
 * not save anything — the draft lands in the create form so it can be read and
 * edited before it becomes a character.
 */
router.post('/compose', requireAuth, async (req, res, next) => {
  try {
    const parsed = composeInput.safeParse(req.body);
    if (!parsed.success) {
      return res.status(400).json({ error: parsed.error.issues[0]?.message ?? 'Invalid request' });
    }

    const draft = await composeCharacter(parsed.data);
    res.json({ draft });
  } catch (err) {
    next(err);
  }
});

/**
 * PUT / DELETE /api/characters/:id/save — bookmark a character.
 *
 * Idempotent in both directions, because the UI flips the icon optimistically
 * and a double click should not become an error.
 */
router.put('/:id/save', requireAuth, async (req, res, next) => {
  try {
    const character = await prisma.character.findUnique({
      where: { id: req.params.id },
      select: { id: true, nsfwAllowed: true },
    });
    if (!character) return res.status(404).json({ error: 'Character not found' });
    if (character.nsfwAllowed && !req.user.nsfwEnabled) {
      return res.status(403).json({ error: 'Enable mature content to save this character' });
    }

    await prisma.savedCharacter.upsert({
      where: { userId_characterId: { userId: req.user.id, characterId: character.id } },
      create: { userId: req.user.id, characterId: character.id },
      update: {},
    });

    res.json({ saved: true });
  } catch (err) {
    next(err);
  }
});

router.delete('/:id/save', requireAuth, async (req, res, next) => {
  try {
    await prisma.savedCharacter.deleteMany({
      where: { userId: req.user.id, characterId: req.params.id },
    });
    res.json({ saved: false });
  } catch (err) {
    next(err);
  }
});

/** GET /api/characters/:id/avatar — the generated image itself. */
router.get('/:id/avatar', async (req, res, next) => {
  try {
    const row = await prisma.character.findUnique({
      where: { id: req.params.id },
      select: { avatarData: true, avatarMime: true, updatedAt: true },
    });
    if (!row?.avatarData) return res.status(404).json({ error: 'No avatar for this character' });

    // Immutable in practice: regenerating writes a new updatedAt, and the URL
    // carries it as a cache buster.
    res.set('Content-Type', row.avatarMime ?? 'image/jpeg');
    res.set('Cache-Control', 'public, max-age=31536000, immutable');
    res.send(Buffer.from(row.avatarData));
  } catch (err) {
    next(err);
  }
});

/**
 * POST /api/characters/:id/avatar — generate one.
 *
 * Deliberately a separate, explicit action rather than part of creating a
 * character: images cost per picture, so nobody should spend one by accident.
 */
router.post('/:id/avatar', requireAuth, async (req, res, next) => {
  try {
    const character = await prisma.character.findUnique({ where: { id: req.params.id } });
    if (!character) return res.status(404).json({ error: 'Character not found' });
    if (character.creatorId && character.creatorId !== req.user.id) {
      return res.status(403).json({ error: 'Not your character' });
    }
    if (character.avatarData && !req.body?.regenerate) {
      return res.status(409).json({ error: 'This character already has an avatar' });
    }

    const image = await generateAvatar(character);
    const updated = await prisma.character.update({
      where: { id: character.id },
      data: { avatarData: image.data, avatarMime: image.mime },
      select: { id: true, updatedAt: true },
    });

    res.json({
      ok: true,
      provider: image.provider,
      bytes: image.data.length,
      avatarUrl: `/api/characters/${updated.id}/avatar?v=${updated.updatedAt.getTime()}`,
    });
  } catch (err) {
    next(err);
  }
});

const characterInput = z.object({
  name: z.string().min(1).max(60),
  universe: z.string().max(80).default('Original'),
  tagline: z.string().max(140).default(''),
  personality: z.string().min(20).max(6000),
  lore: z.string().max(12000).default(''),
  speakingStyle: z.string().max(6000).default(''),
  tags: z.array(z.string().max(30)).max(10).default([]),
  avatarUrl: z.string().url().nullish(),
  themeColor: z.string().regex(/^#[0-9a-f]{6}$/i).default('#34d399'),
  nsfwAllowed: z.boolean().default(false),
  isPublic: z.boolean().default(true),
});

/** POST /api/characters */
router.post('/', requireAuth, async (req, res, next) => {
  try {
    const parsed = characterInput.safeParse(req.body);
    if (!parsed.success) {
      return res.status(400).json({ error: 'Invalid character', issues: parsed.error.issues });
    }

    const character = await prisma.character.create({
      data: { ...parsed.data, creatorId: req.user.id },
      select: publicFields,
    });

    res.status(201).json({ character });
  } catch (err) {
    next(err);
  }
});

/** PATCH /api/characters/:id — creator only */
router.patch('/:id', requireAuth, async (req, res, next) => {
  try {
    const existing = await prisma.character.findUnique({
      where: { id: req.params.id },
      select: { creatorId: true },
    });
    if (!existing) return res.status(404).json({ error: 'Character not found' });
    if (existing.creatorId !== req.user.id) {
      return res.status(403).json({ error: 'Not your character' });
    }

    const parsed = characterInput.partial().safeParse(req.body);
    if (!parsed.success) {
      return res.status(400).json({ error: 'Invalid character', issues: parsed.error.issues });
    }

    const character = await prisma.character.update({
      where: { id: req.params.id },
      data: parsed.data,
      select: publicFields,
    });

    res.json({ character });
  } catch (err) {
    next(err);
  }
});

/** DELETE /api/characters/:id — creator only */
router.delete('/:id', requireAuth, async (req, res, next) => {
  try {
    const existing = await prisma.character.findUnique({
      where: { id: req.params.id },
      select: { creatorId: true },
    });
    if (!existing) return res.status(404).json({ error: 'Character not found' });
    if (existing.creatorId !== req.user.id) {
      return res.status(403).json({ error: 'Not your character' });
    }

    await prisma.character.delete({ where: { id: req.params.id } });
    res.json({ ok: true });
  } catch (err) {
    next(err);
  }
});

export default router;
