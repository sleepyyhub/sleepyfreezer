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
  const raw = await complete([{ role: 'user', content: buildPrompt(name, universe) }], {
    temperature: 0.8, // a little loose: this is invention, not conversation
    maxTokens: 2000,
  });

  const sheet = parseJson(raw.content ?? raw.reasoning, null);
  if (!sheet || typeof sheet !== 'object') {
    throw Object.assign(new Error('The model did not return a usable character sheet'), {
      status: 502,
    });
  }

  const missing = FIELDS.filter((f) => !sheet[f]);
  if (missing.includes('personality')) {
    throw Object.assign(new Error('The model returned an incomplete character'), { status: 502 });
  }

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
    model: raw.model ?? config.ai.models[0],
  };
}

export default composeCharacter;
