import prisma from '../db.js';
import { generateInCharacter } from '../ai/generate.js';
import { buildSystemPrompt, buildHistory } from '../ai/prompt.js';
import { emit, channels } from '../realtime/pusher.js';

// Inkling holds 256k tokens, so history is generous — this cap exists to keep
// latency and cost sane, not because the model runs out of room.
const HISTORY_LIMIT = 120;

export async function getOrCreateConversation(userId, characterId) {
  const existing = await prisma.conversation.findUnique({
    where: { userId_characterId: { userId, characterId } },
    include: { character: true },
  });
  if (existing) return existing;

  return prisma.conversation.create({
    data: { userId, characterId },
    include: { character: true },
  });
}

export async function loadHistory(conversationId, limit = HISTORY_LIMIT) {
  const rows = await prisma.message.findMany({
    where: { conversationId },
    orderBy: { createdAt: 'desc' },
    take: limit,
    include: { character: { select: { id: true, name: true } } },
  });
  return rows.reverse();
}

/**
 * Send one user message and get the character's reply.
 * Returns both stored rows so the client can render them immediately.
 */
export async function sendMessage({ user, conversation, content }) {
  const character = conversation.character;

  const userMessage = await prisma.message.create({
    data: {
      conversationId: conversation.id,
      senderType: 'user',
      content,
    },
  });

  const history = await loadHistory(conversation.id);

  const messages = [
    { role: 'system', content: buildSystemPrompt(character, user) },
    ...buildHistory(history, { selfId: character.id }),
  ];

  const { thought, content: reply } = await generateInCharacter(messages, {
    name: character.name,
  });

  const characterMessage = await prisma.message.create({
    data: {
      conversationId: conversation.id,
      senderType: 'character',
      characterId: character.id,
      content: reply || '...',
      thought,
    },
    include: { character: { select: { id: true, name: true, avatarUrl: true, themeColor: true } } },
  });

  await Promise.all([
    prisma.conversation.update({
      where: { id: conversation.id },
      data: { lastMessageAt: new Date() },
    }),
    prisma.character.update({
      where: { id: character.id },
      data: { messageCount: { increment: 1 } },
    }),
  ]);

  await emit(channels.conversation(conversation.id), 'message', characterMessage);

  return { userMessage, characterMessage };
}

export default { sendMessage, getOrCreateConversation, loadHistory };
