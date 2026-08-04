import { Router } from 'express';
import { z } from 'zod';
import prisma from '../db.js';
import { requireAuth } from '../middleware/auth.js';
import { sendGroupMessage, loadGroup, loadHistory } from '../services/group.js';

const router = Router();
router.use(requireAuth);

const memberSelect = {
  select: { id: true, name: true, avatarUrl: true, themeColor: true, universe: true },
};

async function ownedGroup(groupId, userId) {
  const group = await loadGroup(groupId);
  if (!group) return { error: 404 };
  if (group.userId !== userId) return { error: 403 };
  return { group };
}

/** GET /api/groups */
router.get('/', async (req, res, next) => {
  try {
    const rows = await prisma.group.findMany({
      where: { userId: req.user.id },
      orderBy: { lastMessageAt: 'desc' },
      include: {
        members: { include: { character: memberSelect } },
        messages: {
          orderBy: { createdAt: 'desc' },
          take: 1,
          select: { content: true, senderType: true, createdAt: true, characterId: true },
        },
      },
    });

    res.json({
      groups: rows.map(({ members, messages, ...rest }) => ({
        ...rest,
        members: members.map((m) => m.character),
        lastMessage: messages[0] ?? null,
      })),
    });
  } catch (err) {
    next(err);
  }
});

const groupInput = z.object({
  name: z.string().min(1).max(60),
  characterIds: z.array(z.string()).min(2).max(8),
});

/** POST /api/groups */
router.post('/', async (req, res, next) => {
  try {
    const parsed = groupInput.safeParse(req.body);
    if (!parsed.success) {
      return res
        .status(400)
        .json({ error: 'A group needs a name and 2-8 characters', issues: parsed.error.issues });
    }

    const { name, characterIds } = parsed.data;
    const ids = [...new Set(characterIds)];

    const characters = await prisma.character.findMany({ where: { id: { in: ids } } });
    if (characters.length !== ids.length) {
      return res.status(404).json({ error: 'One or more characters do not exist' });
    }
    if (!req.user.nsfwEnabled && characters.some((c) => c.nsfwAllowed)) {
      return res.status(403).json({ error: 'Enable mature content to add this character' });
    }

    const group = await prisma.group.create({
      data: {
        name,
        userId: req.user.id,
        members: { create: ids.map((characterId) => ({ characterId })) },
      },
      include: { members: { include: { character: memberSelect } } },
    });

    res.status(201).json({
      group: { ...group, members: group.members.map((m) => m.character) },
    });
  } catch (err) {
    next(err);
  }
});

/** GET /api/groups/:id/messages */
router.get('/:id/messages', async (req, res, next) => {
  try {
    const { group, error } = await ownedGroup(req.params.id, req.user.id);
    if (error === 404) return res.status(404).json({ error: 'Group not found' });
    if (error === 403) return res.status(403).json({ error: 'Not your group' });

    const messages = await loadHistory(group.id, Number(req.query.limit) || 120);
    res.json({
      group: { ...group, members: group.members.map((m) => m.character) },
      messages,
    });
  } catch (err) {
    next(err);
  }
});

const messageInput = z.object({ content: z.string().min(1).max(8000) });

/** POST /api/groups/:id/messages — user speaks, the room answers */
router.post('/:id/messages', async (req, res, next) => {
  try {
    const parsed = messageInput.safeParse(req.body);
    if (!parsed.success) return res.status(400).json({ error: 'A message is required' });

    const { group, error } = await ownedGroup(req.params.id, req.user.id);
    if (error === 404) return res.status(404).json({ error: 'Group not found' });
    if (error === 403) return res.status(403).json({ error: 'Not your group' });
    if (!group.members.length) return res.status(400).json({ error: 'This group has no members' });

    const result = await sendGroupMessage({
      user: req.user,
      group,
      content: parsed.data.content,
    });

    res.json(result);
  } catch (err) {
    next(err);
  }
});

/** POST /api/groups/:id/members */
router.post('/:id/members', async (req, res, next) => {
  try {
    const { characterId } = req.body ?? {};
    if (!characterId) return res.status(400).json({ error: 'characterId is required' });

    const { group, error } = await ownedGroup(req.params.id, req.user.id);
    if (error === 404) return res.status(404).json({ error: 'Group not found' });
    if (error === 403) return res.status(403).json({ error: 'Not your group' });
    if (group.members.length >= 8) return res.status(400).json({ error: 'Group is full' });

    const character = await prisma.character.findUnique({ where: { id: characterId } });
    if (!character) return res.status(404).json({ error: 'Character not found' });
    if (character.nsfwAllowed && !req.user.nsfwEnabled) {
      return res.status(403).json({ error: 'Enable mature content to add this character' });
    }

    await prisma.groupMember.upsert({
      where: { groupId_characterId: { groupId: group.id, characterId } },
      update: {},
      create: { groupId: group.id, characterId },
    });

    res.json({ ok: true });
  } catch (err) {
    next(err);
  }
});

/** DELETE /api/groups/:id/members/:characterId */
router.delete('/:id/members/:characterId', async (req, res, next) => {
  try {
    const { group, error } = await ownedGroup(req.params.id, req.user.id);
    if (error === 404) return res.status(404).json({ error: 'Group not found' });
    if (error === 403) return res.status(403).json({ error: 'Not your group' });

    await prisma.groupMember.deleteMany({
      where: { groupId: group.id, characterId: req.params.characterId },
    });

    res.json({ ok: true });
  } catch (err) {
    next(err);
  }
});

/** DELETE /api/groups/:id */
router.delete('/:id', async (req, res, next) => {
  try {
    const { error } = await ownedGroup(req.params.id, req.user.id);
    if (error === 404) return res.status(404).json({ error: 'Group not found' });
    if (error === 403) return res.status(403).json({ error: 'Not your group' });

    await prisma.group.delete({ where: { id: req.params.id } });
    res.json({ ok: true });
  } catch (err) {
    next(err);
  }
});

export default router;
