import { complete } from './client.js';
import { parseJson } from './parse.js';
import config from '../config.js';

/**
 * Build a full character sheet from just a name and a universe.
 *
 * The quality of a character comes almost entirely from these fields, so the
 * prompt pushes for the same things that make the hand-written seeds work:
 * contradictions rather than adjectives, concrete facts the character can
 * reference, and sample lines — which models imitate far more reliably than
 * any description of a voice.
 */

const FIELDS = ['tagline', 'personality', 'lore', 'speakingStyle', 'tags', 'themeColor'];

function buildPrompt(name, universe) {
  const where = universe?.trim()
    ? `from ${universe.trim()}`
    : 'an original character, invented from the name alone';

  return `Write a character sheet for ${name}, ${where}.

If you genuinely know this character, use what is actually true of them: their
real relationships, real events from their story, how they really speak. Do not
invent a different person. If you do not know them, say so by setting "known"
to false and write a plausible character that fits the name and setting.

Return JSON only, with exactly these keys:

{
  "known": true or false,
  "tagline": "one line, under 100 characters, that captures who they are",
  "personality": "150-250 words. Their temperament and what drives them. Include
     the contradictions — what they show versus what they feel, what they are
     insecure about, how they behave when cornered. Write it as instructions to
     someone playing them, in second person: 'You are...'",
  "lore": "100-200 words. Their world, key relationships by name, and the events
     they would actually reference in conversation. Facts, not atmosphere.",
  "speakingStyle": "100-200 words on the mechanics of their voice: sentence
     length, verbal tics, what they say when embarrassed or angry, forms of
     address. End with 'Sample lines:' followed by three short quoted lines in
     their voice, one of which should be them at their most guarded.",
  "tags": ["4 to 6 lowercase single-word traits"],
  "themeColor": "#rrggbb hex that suits them"
}

Write personality and speakingStyle in the second person, addressed to the
person who will play this character. No markdown, no commentary, JSON only.`;
}

const HEX = /^#[0-9a-f]{6}$/i;
const str = (v, max) => (typeof v === 'string' ? v.trim().slice(0, max) : '');

export async function composeCharacter({ name, universe = '' }) {
  const messages = [{ role: 'user', content: buildPrompt(name, universe) }];
  let sheet = null;
  let lastRaw = null;

  // Reasoning models spend part of max_tokens thinking before they emit a
  // character of JSON — measured at ~1,000 tokens here — so the budget has to
  // cover both or the object is cut off mid-field.
  for (let attempt = 0; attempt < 2 && !sheet; attempt += 1) {
    lastRaw = await complete(messages, {
      temperature: 0.8, // a little loose: this is invention, not conversation
      maxTokens: 6000,
    });
    sheet = parseJson(lastRaw.content || lastRaw.reasoning, null);
    if (!sheet || typeof sheet !== 'object') {
      sheet = null;
      console.warn(
        `[compose] ${name}: unparseable sheet from ${lastRaw.provider}:${lastRaw.model}`
        + ` (finish=${lastRaw.finishReason}, ${(lastRaw.content ?? '').length} chars)`,
      );
    }
  }

  if (!sheet) {
    throw Object.assign(
      new Error(
        'The model could not produce a character sheet for that name. '
        + 'Try again, or fill the form in by hand.',
      ),
      { status: 502 },
    );
  }

  // Personality is the one field the character cannot exist without; a
  // repaired sheet may legitimately be missing later ones.
  if (!sheet.personality) {
    throw Object.assign(
      new Error('The model returned a character with no personality. Try again.'),
      { status: 502 },
    );
  }

  // A repaired sheet keeps only the fields that finished. Say which are
  // missing rather than handing back a thin character as if it were complete.
  const incomplete = ['lore', 'speakingStyle', 'tagline']
    .filter((f) => !sheet[f]);

  const tags = Array.isArray(sheet.tags)
    ? sheet.tags.map((t) => String(t).trim().toLowerCase().slice(0, 30)).filter(Boolean).slice(0, 8)
    : [];

  return {
    name: name.trim(),
    universe: universe.trim() || 'Original',
    tagline: str(sheet.tagline, 140),
    personality: str(sheet.personality, 6000),
    lore: str(sheet.lore, 12000),
    speakingStyle: str(sheet.speakingStyle, 6000),
    tags,
    themeColor: HEX.test(sheet.themeColor ?? '') ? sheet.themeColor : '#34d399',
    // Surfaced so the UI can warn that the model is improvising rather than
    // recalling — the difference matters when someone asks for a real character.
    known: sheet.known !== false,
    incomplete,
    model: lastRaw?.model ?? 'unknown',
  };
}

export default composeCharacter;
