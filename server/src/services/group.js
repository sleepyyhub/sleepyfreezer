import prisma from '../db.js';
import config from '../config.js';
import { complete } from '../ai/client.js';
import { generateInCharacter } from '../ai/generate.js';
import { buildSystemPrompt, buildHistory } from '../ai/prompt.js';
import { loadMemories, maybeExtractMemories } from './memory.js';
import { parseJson } from '../ai/parse.js';
import { emit, channels } from '../realtime/pusher.js';
import { MESSAGE_FIELDS } from './chat.js';

const HISTORY_LIMIT = 120;

export async function loadGroup(groupId) {
  return prisma.group.findUnique({
    where: { id: groupId },
    include: { members: { include: { character: true } } },
  });
}

export async function loadHistory(groupId, limit = HISTORY_LIMIT) {
  const rows = await prisma.message.findMany({
    where: { groupId },
    orderBy: { createdAt: 'desc' },
    take: limit,
    select: MESSAGE_FIELDS,
  });
  return rows.reverse();
}

/**
 * Decide who speaks up.
 *
 * Picking at random makes a group feel like a slot machine — the character the
 * message was obviously aimed at stays silent half the time. So we ask the
 * model instead, cheaply and at low temperature, and fall back to random only
 * if that call fails.
 */
async function pickResponders(cast, history, trigger, { exclude = [], max = 2 } = {}) {
  const eligible = cast.filter((c) => !exclude.includes(c.id));
  if (eligible.length === 0) return [];
  if (eligible.length === 1) return eligible;

  // Being spoken to by name is not a judgement call — if someone is addressed
  // directly they answer, whatever the director thinks. Asking the model to
  // honour this was unreliable in practice.
  const addressed = eligible.filter((c) => {
    const first = c.name.split(/\s+/)[0];
    return new RegExp(`\\b${escapeRegex(first)}\\b`, 'i').test(trigger);
  });
  if (addressed.length) return addressed.slice(0, max);

  const roster = eligible
    .map((c) => `- ${c.name}: ${c.tagline || c.personality.slice(0, 120)}`)
    .join('\n');

  const recent = history
    .slice(-8)
    .map((m) => `${m.senderType === 'user' ? 'User' : m.character?.name ?? '?'}: ${m.content}`)
    .join('\n');

  const prompt = `You are directing a group conversation. These characters are present:
${roster}

Recent messages:
${recent}

New message:
${trigger}

Who would realistically speak next? Pick between 1 and ${max} of them — only the
ones with a genuine reason to react. Someone addressed by name always answers.
Reply with a JSON array of names and nothing else, e.g. ["Nino"].`;

  try {
    const raw = await complete([{ role: 'user', content: prompt }], {
      temperature: config.ai.directorTemperature,
      maxTokens: config.ai.directorMaxTokens,
    });
    const names = parseJson(raw.content, null);
    if (Array.isArray(names) && names.length) {
      const picked = names
        .map((n) => eligible.find((c) => c.name.toLowerCase() === String(n).trim().toLowerCase()))
        .filter(Boolean)
        .slice(0, max);
      if (picked.length) return picked;
    }
  } catch (err) {
    console.warn('[group] director failed, falling back to random:', err.message);
  }

  return [eligible[Math.floor(Math.random() * eligible.length)]];
}

function escapeRegex(s) {
  return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

/** Generate and store one character's turn in a group. */
async function speak({ character, cast, user, group, replyToId = null }) {
  const [history, memories] = await Promise.all([
    loadHistory(group.id),
    loadMemories({ groupId: group.id }),
  ]);
  const others = cast.filter((c) => c.id !== character.id);

  const messages = [
    { role: 'system', content: buildSystemPrompt(character, user, { others, memories }) },
    ...buildHistory(history, { selfId: character.id, isGroup: true }),
  ];

  const { thought, content } = await generateInCharacter(messages, {
    name: character.name,
  });

  const stored = await prisma.message.create({
    data: {
      groupId: group.id,
      senderType: 'character',
      characterId: character.id,
      content: content || '...',
      thought,
      replyToId,
    },
    select: MESSAGE_FIELDS,
  });

  await prisma.character.update({
    where: { id: character.id },
    data: { messageCount: { increment: 1 } },
  });

  await emit(channels.group(group.id), 'message', stored);
  return stored;
}

/**
 * Run a full group turn: the user speaks, one or two characters answer, and
 * then the characters may keep going among themselves for a few exchanges.
 */
export async function sendGroupMessage({ user, group, content }) {
  const cast = group.members.map((m) => m.character);

  const userMessage = await prisma.message.create({
    data: { groupId: group.id, senderType: 'user', content },
  });
  await emit(channels.group(group.id), 'message', userMessage);

  const history = await loadHistory(group.id);
  const responders = await pickResponders(cast, history, content, {
    max: config.group.maxDirectResponders,
  });

  const replies = [];
  for (const character of responders) {
    replies.push(await speak({ character, cast, user, group }));
  }

  // Bot-to-bot: whoever spoke last may get a reaction from someone else.
  let depth = 0;
  while (depth < config.group.maxChainDepth && replies.length) {
    if (Math.random() > config.group.chainProbability) break;

    const last = replies[replies.length - 1];
    const nextUp = await pickResponders(cast, await loadHistory(group.id), last.content, {
      exclude: [last.characterId],
      max: 1,
    });
    if (!nextUp.length) break;

    replies.push(
      await speak({ character: nextUp[0], cast, user, group, replyToId: last.id }),
    );
    depth += 1;
  }

  await prisma.group.update({
    where: { id: group.id },
    data: { lastMessageAt: new Date() },
  });

  // One extraction for the thread, attributed to whoever spoke last.
  const speaker = cast.find((c) => c.id === replies[replies.length - 1]?.characterId) ?? cast[0];
  maybeExtractMemories({ scope: { groupId: group.id }, character: speaker, user })
    .catch((err) => console.warn('[memory]', err.message));

  return { userMessage, replies };
}

/** A character opens the group unprompted — used by the proactive cron. */
export async function nudgeGroup({ user, group, character }) {
  const cast = group.members.map((m) => m.character);
  const message = await speak({ character, cast, user, group });

  await prisma.group.update({
    where: { id: group.id },
    data: { lastMessageAt: new Date() },
  });

  return message;
}

export default { sendGroupMessage, nudgeGroup, loadGroup, loadHistory };
