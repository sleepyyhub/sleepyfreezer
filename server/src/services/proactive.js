import prisma from '../db.js';
import config from '../config.js';
import { complete } from '../ai/client.js';
import { buildSystemPrompt, buildHistory } from '../ai/prompt.js';
import { parseReply } from '../ai/parse.js';
import { emit, channels } from '../realtime/pusher.js';
import { nudgeGroup } from './group.js';

const HOUR = 60 * 60 * 1000;
const DAY = 24 * HOUR;

const hoursSince = (date) => (Date.now() - new Date(date).getTime()) / HOUR;
const pick = (arr) => arr[Math.floor(Math.random() * arr.length)];

/**
 * A conversation is due when it has been quiet for a randomised stretch inside
 * the configured window. The randomness is the point: a character that always
 * messages exactly four hours later reads as a cron job, not a person.
 */
function isDue(lastMessageAt) {
  const quiet = hoursSince(lastMessageAt);
  const { minHoursBetween, maxHoursBetween } = config.proactive;
  if (quiet < minHoursBetween) return false;
  const threshold =
    minHoursBetween + Math.random() * (maxHoursBetween - minHoursBetween);
  return quiet >= threshold;
}

/** One character reaching into one DM thread. */
async function nudgeConversation({ user, conversation }) {
  const character = conversation.character;

  const history = await prisma.message.findMany({
    where: { conversationId: conversation.id },
    orderBy: { createdAt: 'desc' },
    take: 40,
    include: { character: { select: { id: true, name: true } } },
  });

  const messages = [
    { role: 'system', content: buildSystemPrompt(character, user, { proactive: true }) },
    ...buildHistory(history.reverse(), { selfId: character.id }),
    {
      role: 'user',
      content:
        '[System: Time has passed and nobody has messaged you. Send them ' +
        'something first, in your own voice. Begin with your inner monologue line.]',
    },
  ];

  // Occasionally a model returns only the thought line and no spoken text.
  // One retry costs a second and turns most of those into a real message.
  let thought = null;
  let content = '';
  for (let attempt = 0; attempt < 2 && !content; attempt += 1) {
    const raw = await complete(messages);
    ({ thought, content } = parseReply(raw.content, {
      reasoning: raw.reasoning,
      name: character.name,
    }));
  }

  if (!content) {
    console.warn(`[proactive] ${character.name} produced no message for user ${user.id} — skipping`);
    return null;
  }

  const stored = await prisma.message.create({
    data: {
      conversationId: conversation.id,
      senderType: 'character',
      characterId: character.id,
      content,
      thought,
      isProactive: true,
    },
    include: { character: { select: { id: true, name: true, avatarUrl: true, themeColor: true } } },
  });

  await prisma.conversation.update({
    where: { id: conversation.id },
    data: { lastMessageAt: new Date() },
  });

  await emit(channels.conversation(conversation.id), 'message', stored);
  await emit(channels.user(user.id), 'proactive', {
    conversationId: conversation.id,
    character: stored.character,
    preview: content.slice(0, 140),
  });

  return stored;
}

/**
 * Sweep every opted-in user and let at most one character reach out per run.
 * Capping at one keeps the app from feeling like a crowd of bots all shouting
 * at once when the cron catches up after downtime.
 */
export async function runProactiveSweep() {
  const activeSince = new Date(Date.now() - config.proactive.inactiveAfterDays * DAY);

  const users = await prisma.user.findMany({
    where: {
      proactiveEnabled: true,
      OR: [
        { conversations: { some: { lastMessageAt: { gte: activeSince } } } },
        { groups: { some: { lastMessageAt: { gte: activeSince } } } },
      ],
    },
    include: {
      conversations: { include: { character: true } },
      groups: { include: { members: { include: { character: true } } } },
    },
  });

  const sent = [];

  for (const user of users) {
    const dueConversations = user.conversations.filter((c) => isDue(c.lastMessageAt));
    const dueGroups = user.groups.filter(
      (g) => g.members.length > 0 && isDue(g.lastMessageAt),
    );

    const candidates = [
      ...dueConversations.map((c) => ({ kind: 'conversation', row: c })),
      ...dueGroups.map((g) => ({ kind: 'group', row: g })),
    ];
    if (!candidates.length) continue;

    const chosen = pick(candidates);

    try {
      if (chosen.kind === 'conversation') {
        const message = await nudgeConversation({ user, conversation: chosen.row });
        if (message) sent.push({ userId: user.id, conversationId: chosen.row.id });
      } else {
        const character = pick(chosen.row.members).character;
        await nudgeGroup({ user, group: chosen.row, character });
        sent.push({ userId: user.id, groupId: chosen.row.id });
      }
    } catch (err) {
      console.error(`[proactive] user ${user.id} failed:`, err.message);
    }
  }

  return { checked: users.length, sent: sent.length, details: sent };
}

export default { runProactiveSweep };
