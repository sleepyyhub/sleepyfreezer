import { complete } from './client.js';
import { parseReply, looksLikeMetaReasoning, salvageAfterDraft } from './parse.js';

// Kept low on purpose: the free tier has a small daily allowance, and salvage
// recovers most narration without spending another call.
const MAX_ATTEMPTS = 2;

/**
 * Produce one in-character message.
 *
 * Free models intermittently narrate the task instead of playing the part —
 * describing the character in the third person, quoting the conversation
 * structure, planning the reply out loud. Roughly one group reply in six did
 * this before these guards. Showing that to a reader breaks the illusion
 * completely and exposes the prompt, so it is worth a retry rather than a
 * best-effort clean-up.
 *
 * Order of preference:
 *   1. a clean reply
 *   2. the real line recovered from after a "let me draft:" marker
 *   3. another attempt
 *   4. whatever we have, so the conversation never dead-ends
 */
export async function generateInCharacter(messages, { name = '', ...opts } = {}) {
  let best = null;

  for (let attempt = 0; attempt < MAX_ATTEMPTS; attempt += 1) {
    const raw = await complete(messages, opts);
    const parsed = parseReply(raw.content, { reasoning: raw.reasoning, name });

    if (parsed.content && !looksLikeMetaReasoning(parsed.content)) {
      return { ...parsed, model: raw.model, attempts: attempt + 1 };
    }

    const salvaged = salvageAfterDraft(parsed.content);
    if (salvaged) {
      return {
        thought: parsed.thought,
        content: salvaged,
        model: raw.model,
        attempts: attempt + 1,
        salvaged: true,
      };
    }

    // Keep the longest usable candidate as a floor for the final fallback.
    if (!best || (parsed.content?.length ?? 0) > (best.content?.length ?? 0)) best = parsed;

    console.warn(
      `[ai] ${name || 'character'} narrated instead of speaking (attempt ${attempt + 1}/${MAX_ATTEMPTS})`,
    );
  }

  // Every attempt narrated. Return the thought alone rather than the narration:
  // an empty message is handled by callers, leaked reasoning is not.
  return { thought: best?.thought ?? null, content: '', attempts: MAX_ATTEMPTS, failed: true };
}

export default generateInCharacter;
