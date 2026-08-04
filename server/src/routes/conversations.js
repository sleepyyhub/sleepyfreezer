import { Router } from 'express';
import { z } from 'zod';
import prisma from '../db.js';
import { requireAuth } from '../middleware/auth.js';
import { sendMessage, getOrCreateConversation, loadHistory } from '../services/chat.js';

const router = Router();
router.use(requireAuth);

/** GET /api/conversations — the DM sidebar */
router.get('/', async (req, res, next) => {
  try {
    const rows = await prisma.conversation.findMany({
      where: { userId: req.user.id },
      orderBy: { lastMessageAt: 'desc' },
      include: {
        character: {
          select: { id: true, name: true, avatarUrl: true, themeColor: true, universe: true },
        },
        messages: {
          orderBy: { createdAt: 'desc' },
          take: 1,
          select: { content: true, senderType: true, createdAt: true, isProactive: true },
        },
      },
    });

    res.json({
      conversations: rows.map(({ messages, ...rest }) => ({
        ...rest,
        lastMessage: messages[0] ?? null,
      })),
    });
  } catch (err) {
    next(err);
  }
});

/** POST /api/conversations — open (or reopen) a DM with a character */
router.post('/', async (req, res, next) => {
  try {
    const { characterId } = req.body ?? {};
    if (!characterId) return res.status(400).json({ error: 'characterId is required' });

    const character = await prisma.character.findUnique({ where: { id: characterId } });
    if (!character) return res.status(404).json({ error: 'Character not found' });
    if (character.nsfwAllowed && !req.user.nsfwEnabled) {
      return res.status(403).json({ error: 'Enable mature content to chat with this character' });
    }

    const conversation = await getOrCreateConversation(req.user.id, characterId);
    res.status(201).json({ conversation });
  } catch (err) {
    next(err);
  }
});

/** GET /api/conversations/:id/messages */
router.get('/:id/messages', async (req, res, next) => {
  try {
    const conversation = await prisma.conversation.findUnique({
      where: { id: req.params.id },
      include: { character: true },
    });
    if (!conversation) return res.status(404).json({ error: 'Conversation not found' });
    if (conversation.userId !== req.user.id) {
      return res.status(403).json({ error: 'Not your conversation' });
    }

    const messages = await loadHistory(conversation.id, Number(req.query.limit) || 120);
    res.json({ conversation, messages });
  } catch (err) {
    next(err);
  }
});

const messageInput = z.object({ content: z.string().min(1).max(8000) });

/** POST /api/conversations/:id/messages — the main 1-on-1 chat call */
router.post('/:id/messages', async (req, res, next) => {
  try {
    const parsed = messageInput.safeParse(req.body);
    if (!parsed.success) return res.status(400).json({ error: 'A message is required' });

    const conversation = await prisma.conversation.findUnique({
      where: { id: req.params.id },
      include: { character: true },
    });
    if (!conversation) return res.status(404).json({ error: 'Conversation not found' });
    if (conversation.userId !== req.user.id) {
      return res.status(403).json({ error: 'Not your conversation' });
    }

    const result = await sendMessage({
      user: req.user,
      conversation,
      content: parsed.data.content,
    });

    res.json(result);
  } catch (err) {
    next(err);
  }
});

/** DELETE /api/conversations/:id */
router.delete('/:id', async (req, res, next) => {
  try {
    const conversation = await prisma.conversation.findUnique({
      where: { id: req.params.id },
      select: { userId: true },
    });
    if (!conversation) return res.status(404).json({ error: 'Conversation not found' });
    if (conversation.userId !== req.user.id) {
      return res.status(403).json({ error: 'Not your conversation' });
    }

    await prisma.conversation.delete({ where: { id: req.params.id } });
    res.json({ ok: true });
  } catch (err) {
    next(err);
  }
});

export default router;
