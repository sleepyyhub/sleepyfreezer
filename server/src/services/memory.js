import prisma from '../db.js';
import { complete } from '../ai/client.js';
import { parseJson } from '../ai/parse.js';

/**
 * Durable memory.
 *
 * Characters already receive the last 120 messages, so context is not the
 * problem — salience is. A detail mentioned forty messages ago is technically
 * present and practically invisible, and once a conversation runs past the
 * window it is gone for good.
 *
 * So facts worth keeping are extracted periodically and pinned near the top of
 * the system prompt, where they carry weight. They are short, first-person from
 * the character's side, and about the person being spoken to or the shared
 * history — not a summary of what was said.
 */

// Extract once this many new messages have accumulated. Small enough that a
// long session is captured, large enough that it costs one call per exchange.
const EXTRACT_EVERY = 14;

// Injected into the prompt. Beyond this the section stops being a reminder and
// starts competing with the character sheet.
const MAX_INJECTED = 24;

const scopeWhere = ({ conversationId, groupId }) =>
  (conversationId ? { conversationId } : { groupId });

/** Facts for a thread, oldest first, capped. */
export async function loadMemories(scope) {
  const rows = await prisma.memory.findMany({
    where: scopeWhere(scope),
    orderBy: { createdAt: 'desc' },
    take: MAX_INJECTED,
    select: { content: true },
  });
  return rows.reverse().map((r) => r.content);
}

function buildExtractionPrompt(character, userName, transcript, existing) {
  return `Below is part of a conversation between ${character.name} and ${userName}.

Pull out only facts worth remembering long after this conversation ends —
things ${character.name} would still know weeks later. Good examples: the other
person's name, job, where they live, people and pets in their life, what they
like and hate, plans they made, promises given, things that happened between the
two of them, how the relationship has changed.

Ignore small talk, passing moods, and anything already listed below.

${existing.length ? `Already known:\n${existing.map((m) => `- ${m}`).join('\n')}\n` : ''}
Transcript:
${transcript}

Reply with a JSON array of short strings, each one fact, written from
${character.name}'s point of view — for example ["He works nights at a bakery",
"I promised to teach him to cook"]. Return [] if there is nothing new worth
keeping. JSON only.`;
}

/**
 * Extract new facts if enough has been said since the last pass.
 *
 * Runs after a reply has already been delivered, so its latency and its
 * failures never affect the message the reader is waiting for.
 */
export async function maybeExtractMemories({ scope, character, user }) {
  const where = scopeWhere(scope);

  const [total, thread] = await Promise.all([
    prisma.message.count({ where }),
    scope.conversationId
      ? prisma.conversation.findUnique({
        where: { id: scope.conversationId },
        select: { memoryCursor: true },
      })
      : prisma.group.findUnique({
        where: { id: scope.groupId },
        select: { memoryCursor: true },
      }),
  ]);

  const cursor = thread?.memoryCursor ?? 0;
  if (total - cursor < EXTRACT_EVERY) return { extracted: 0, skipped: true };

  // Claim this window before doing any work. Extraction is fired without being
  // awaited, so two messages in quick succession can both reach here with the
  // same cursor and extract the same facts twice — which is exactly what
  // happened before this. Moving the cursor conditionally makes the claim
  // atomic: whoever loses the race updates nothing and stops.
  const claim = scope.conversationId
    ? await prisma.conversation.updateMany({
      where: { id: scope.conversationId, memoryCursor: cursor },
      data: { memoryCursor: total },
    })
    : await prisma.group.updateMany({
      where: { id: scope.groupId, memoryCursor: cursor },
      data: { memoryCursor: total },
    });

  if (claim.count === 0) return { extracted: 0, skipped: true };

  const releaseClaim = async () => {
    const undo = { where: { id: scope.conversationId ?? scope.groupId }, data: { memoryCursor: cursor } };
    if (scope.conversationId) await prisma.conversation.update(undo);
    else await prisma.group.update(undo);
  };

  const fresh = await prisma.message.findMany({
    where,
    orderBy: { createdAt: 'asc' },
    skip: cursor,
    include: { character: { select: { name: true } } },
  });
  if (fresh.length === 0) {
    await releaseClaim();
    return { extracted: 0, skipped: true };
  }

  const userName = user?.name || 'them';
  const transcript = fresh
    .map((m) => `${m.senderType === 'user' ? userName : m.character?.name ?? '?'}: ${m.content}`)
    .join('\n')
    .slice(-8000);

  const existing = await loadMemories(scope);

  let facts = [];
  try {
    const raw = await complete(
      [{ role: 'user', content: buildExtractionPrompt(character, userName, transcript, existing) }],
      { temperature: 0.2, maxTokens: 1200 },
    );
    const parsed = parseJson(raw.content || raw.reasoning, []);
    if (Array.isArray(parsed)) facts = parsed;
  } catch (err) {
    // Memory is an enhancement; failing to update it must not break the chat.
    // Hand the window back so the next message retries it rather than losing
    // whatever was said in it.
    console.warn(`[memory] extraction failed: ${err.message}`);
    await releaseClaim().catch(() => {});
    return { extracted: 0, failed: true };
  }

  const seen = new Set(existing.map((m) => m.toLowerCase()));
  const clean = facts
    .map((f) => String(f).trim().replace(/\s+/g, ' ').slice(0, 300))
    .filter((f) => f.length > 3 && !seen.has(f.toLowerCase()))
    .slice(0, 10);

  if (clean.length) {
    await prisma.memory.createMany({
      data: clean.map((content) => ({ ...where, content })),
    });
    console.log(`[memory] +${clean.length} for ${character.name}`);
  }
  return { extracted: clean.length };
}

export default { loadMemories, maybeExtractMemories };
