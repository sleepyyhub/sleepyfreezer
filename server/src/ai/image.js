import config from '../config.js';

/**
 * Avatar generation.
 *
 * Deliberately separate from the text ladder: image models are priced per
 * picture rather than per token, and the difference is stark. Measured on
 * OpenRouter, one Gemini avatar costs about $0.034 — a few dollars of credit
 * buys under a hundred. So this is opt-in per image, never automatic, and a
 * generated avatar is stored so it is produced exactly once.
 *
 * Free providers go first. Cloudflare's Workers AI has a daily allowance and
 * needs no card, which makes it the right default once a token is configured;
 * the paid rung only runs when nothing free is available.
 */

const PROVIDERS = [
  {
    name: 'cloudflare',
    envKey: 'CLOUDFLARE_API_TOKEN',
    requires: ['CLOUDFLARE_ACCOUNT_ID'],
    free: true,
    async generate({ prompt, env }) {
      // No reference-image support on this endpoint; scenes fall back to
      // description alone, which is why it is only used when it is all we have.
      const model = env.CLOUDFLARE_IMAGE_MODEL ?? '@cf/black-forest-labs/flux-1-schnell';
      const res = await fetch(
        `https://api.cloudflare.com/client/v4/accounts/${env.CLOUDFLARE_ACCOUNT_ID}/ai/run/${model}`,
        {
          method: 'POST',
          headers: {
            'Content-Type': 'application/json',
            Authorization: `Bearer ${env.CLOUDFLARE_API_TOKEN}`,
          },
          body: JSON.stringify({ prompt, steps: 4 }),
        },
      );
      if (!res.ok) throw new Error(`Cloudflare ${res.status}: ${(await res.text()).slice(0, 160)}`);

      const body = await res.json();
      const b64 = body?.result?.image;
      if (!b64) throw new Error('Cloudflare returned no image');
      return { data: Buffer.from(b64, 'base64'), mime: 'image/jpeg', cost: 0 };
    },
  },

  {
    name: 'openrouter',
    envKey: 'OPENROUTER_API_KEY',
    free: false,
    async generate({ prompt, env, reference }) {
      const model = env.OPENROUTER_IMAGE_MODEL ?? 'google/gemini-3.1-flash-lite-image';

      // Passing the character's own portrait keeps a scene recognisably them
      // rather than a fresh stranger who happens to match the description.
      const content = reference
        ? [
          { type: 'text', text: prompt },
          { type: 'image_url', image_url: { url: reference } },
        ]
        : prompt;

      const res = await fetch('https://openrouter.ai/api/v1/chat/completions', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${env.OPENROUTER_API_KEY}`,
          'HTTP-Referer': config.clientUrl,
          'X-Title': 'Clovyre',
        },
        body: JSON.stringify({
          model,
          messages: [{ role: 'user', content }],
          modalities: ['image', 'text'],
        }),
      });
      if (!res.ok) throw new Error(`OpenRouter ${res.status}: ${(await res.text()).slice(0, 160)}`);

      const body = await res.json();
      const url = body?.choices?.[0]?.message?.images?.[0]?.image_url?.url ?? '';
      const match = url.match(/^data:(image\/[a-z+]+);base64,(.+)$/i);
      if (!match) throw new Error('OpenRouter returned no image');

      return {
        data: Buffer.from(match[2], 'base64'),
        mime: match[1],
        cost: body?.usage?.cost ?? null,
      };
    },
  },
];

/** Which image providers are usable with the current environment. */
export function availableImageProviders(env = process.env) {
  return PROVIDERS.filter(
    (p) => env[p.envKey] && (p.requires ?? []).every((v) => env[v]),
  );
}

export const imageGenerationEnabled = () => availableImageProviders().length > 0;

/**
 * Turn a character sheet into a portrait prompt. Deliberately describes a
 * head-and-shoulders portrait on a plain background — an avatar is displayed
 * small and round, so composition matters more than scenery.
 */
export function buildAvatarPrompt(character) {
  const traits = (character.tags ?? []).slice(0, 4).join(', ');
  const look = (character.personality ?? '').slice(0, 300);

  return [
    'Anime-style character portrait, head and shoulders, centred, square composition.',
    `The character is ${character.name}${character.universe && character.universe !== 'Original' ? ` from ${character.universe}` : ''}.`,
    traits && `They read as: ${traits}.`,
    look && `Character notes: ${look}`,
    'Clean flat background, soft even lighting, expressive face, no text, no watermark, no border.',
  ].filter(Boolean).join(' ');
}

/**
 * A scene the character asked to show, drawn to look like them.
 *
 * `reference` is the character's stored avatar as a data URL, when there is
 * one — without it the same description produces a different person each time.
 */
export function buildScenePrompt(character, description, { hasReference = false } = {}) {
  return [
    'Anime-style illustration of a scene.',
    `Subject: ${character.name}.`,
    `Scene: ${description}`,
    hasReference
      ? 'Match the appearance of the reference portrait exactly — same face, hair and colouring.'
      // Without a portrait to match, the character sheet is all there is to
      // keep them looking like themselves.
      : `Appearance: ${(character.personality ?? '').slice(0, 240)}`,
    'Expressive, cinematic framing, no text, no watermark.',
  ].filter(Boolean).join(' ');
}

export async function generateScene(character, description, { env = process.env } = {}) {
  const reference = character.avatarData
    ? `data:${character.avatarMime ?? 'image/jpeg'};base64,${Buffer.from(character.avatarData).toString('base64')}`
    : null;

  return runProviders({
    env,
    prompt: buildScenePrompt(character, description, { hasReference: Boolean(reference) }),
    reference,
    label: `${character.name} scene`,
  });
}

export async function generateAvatar(character, { env = process.env } = {}) {
  return runProviders({
    env,
    prompt: buildAvatarPrompt(character),
    label: character.name,
  });
}

async function runProviders({ env, prompt, reference = null, label }) {
  const providers = availableImageProviders(env);
  if (providers.length === 0) {
    throw Object.assign(
      new Error(
        'Image generation is not configured. Add CLOUDFLARE_API_TOKEN and '
        + 'CLOUDFLARE_ACCOUNT_ID for the free option, or OPENROUTER_API_KEY for the paid one.',
      ),
      { status: 503 },
    );
  }

  let lastError;

  for (const provider of providers) {
    try {
      const started = Date.now();
      const result = await provider.generate({ prompt, env, reference });
      console.log(
        `[image] ${label} via ${provider.name}`
        + ` — ${(result.data.length / 1024).toFixed(0)}KB in ${Date.now() - started}ms`
        + (result.cost ? `, cost $${result.cost.toFixed(4)}` : ' (free)'),
      );
      return { ...result, provider: provider.name };
    } catch (err) {
      lastError = err;
      console.warn(`[image] ${provider.name} failed: ${err.message}`);
    }
  }

  throw Object.assign(
    new Error(`Could not generate an image. ${lastError?.message ?? ''}`.trim()),
    { status: 502 },
  );
}

export default generateAvatar;
