import prisma from '../db.js';
import { generateInCharacter } from '../ai/generate.js';
import { extractScene } from '../ai/parse.js';
import { generateScene, imageGenerationEnabled } from '../ai/image.js';
import { buildSystemPrompt, buildHistory } from '../ai/prompt.js';
import { loadMemories, maybeExtractMemories } from './memory.js';
import { emit, channels } from '../realtime/pusher.js';

// Inkling holds 256k tokens, so history is generous — this cap exists to keep
// latency and cost sane, not because the model runs out of room.
const HISTORY_LIMIT = 120;

// Never select imageData here: a single illustration is hundreds of kilobytes
// and would ride along in every history response. imageMime is enough for the
// client to know there is one and fetch it from its own endpoint.
export const MESSAGE_FIELDS = {
  id: true,
  conversationId: true,
  groupId: true,
  senderType: true,
  characterId: true,
  content: true,
  thought: true,
  replyToId: true,
  isProactive: true,
  imageMime: true,
  imagePrompt: true,
  createdAt: true,
  character: { select: { id: true, name: true, avatarUrl: true, themeColor: true, avatarMime: true } },
};


// An illustration costs a real image generation, so however keen a character
// is, there is a floor on how often one can actually be drawn.
const MIN_MESSAGES_BETWEEN_SCENES = 20;

/**
 * May this thread draw a scene right now?
 *
 * Three gates, cheapest first: the reader has opted in, a provider exists, and
 * enough has been said since the last illustration.
 */
async function sceneAllowed({ user, conversationId }) {
  if (!user?.sceneImagesEnabled || !imageGenerationEnabled()) return false;

  const lastImage = await prisma.message.findFirst({
    where: { conversationId, imageMime: { not: null } },
    orderBy: { createdAt: 'desc' },
    select: { createdAt: true },
  });
  if (!lastImage) return true;

  const since = await prisma.message.count({
    where: { conversationId, createdAt: { gt: lastImage.createdAt } },
  });
  return since >= MIN_MESSAGES_BETWEEN_SCENES;
}

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
    select: MESSAGE_FIELDS,
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

  const [history, memories] = await Promise.all([
    loadHistory(conversation.id),
    loadMemories({ conversationId: conversation.id }),
  ]);

  // Whether a scene is permitted is decided before generating, so the character
  // is only invited to ask for one when it could actually be drawn.
  const scenesOpen = await sceneAllowed({ user, conversationId: conversation.id });

  const messages = [
    { role: 'system', content: buildSystemPrompt(character, user, { memories, scenes: scenesOpen }) },
    ...buildHistory(history, { selfId: character.id }),
  ];

  const { thought, content: raw } = await generateInCharacter(messages, {
    name: character.name,
  });

  // The marker comes out whether or not an image follows — it is an
  // instruction to the app, never something to show the reader.
  const { content: reply, scene } = extractScene(raw);

  let image = null;
  if (scene && scenesOpen) {
    try {
      image = await generateScene(character, scene);
    } catch (err) {
      // A failed illustration must not cost the reader their reply.
      console.warn(`[scene] ${character.name}: ${err.message}`);
    }
  }

  const characterMessage = await prisma.message.create({
    data: {
      conversationId: conversation.id,
      senderType: 'character',
      characterId: character.id,
      // An illustration can stand on its own; a bare '...' cannot.
      content: reply || (image ? '' : '...'),
      thought,
      ...(image ? { imageData: image.data, imageMime: image.mime, imagePrompt: scene } : {}),
    },
    select: MESSAGE_FIELDS,
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

  // After the reply is on its way: extraction costs a model call, and nobody
  // should wait for it. A failure here leaves memory stale, nothing worse.
  maybeExtractMemories({ scope: { conversationId: conversation.id }, character, user })
    .catch((err) => console.warn('[memory]', err.message));

  return { userMessage, characterMessage };
}

export default { sendMessage, getOrCreateConversation, loadHistory };
