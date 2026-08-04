import OpenAI from 'openai';
import config from '../config.js';
import { resolveProviders } from './providers.js';

const providers = resolveProviders();

if (providers.length === 0) {
  console.warn(
    '[ai] no provider configured — set NOVITA_API_KEY or OPENROUTER_API_KEY (see .env.example)',
  );
}

// One client per provider, built once.
const clients = new Map(
  providers.map((p) => [
    p.name,
    new OpenAI({
      baseURL: p.baseUrl,
      apiKey: p.apiKey,
      defaultHeaders: p.headers ? p.headers(config) : undefined,
    }),
  ]),
);

/** Flat list of every (provider, model) pair, in the order they are tried. */
const ladder = providers.flatMap((p) => p.models.map((model) => ({ provider: p.name, model })));

export const configuredProviders = providers.map((p) => p.name);
export const configuredLadder = ladder.map((r) => `${r.provider}:${r.model}`);

const RETRYABLE = new Set([408, 409, 500, 502, 503, 504]);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/**
 * A daily allowance does not come back in the next few seconds, so once a
 * provider reports 429 there is no point paying its latency again on every
 * message. Without this, a exhausted primary added ~35s to each reply while the
 * request walked dead rungs before reaching a working provider.
 */
const COOLDOWN_MS = 15 * 60 * 1000;
const coolingUntil = new Map();

const isCoolingDown = (provider) => (coolingUntil.get(provider) ?? 0) > Date.now();

function startCooldown(provider) {
  if (isCoolingDown(provider)) return;
  coolingUntil.set(provider, Date.now() + COOLDOWN_MS);
  console.warn(`[ai] ${provider} is rate-limited — skipping it for ${COOLDOWN_MS / 60000} minutes`);
}

/**
 * Call the model, walking the ladder when a rung is unavailable.
 *
 * Free allowances are per-account, so a 429 means this provider is done for
 * now — not that the request is bad. Dropping straight to the next provider is
 * both faster and more likely to succeed than backing off here.
 */
/**
 * Canned replies for MOCK_AI=true. Front-end work — animation, layout, scroll
 * behaviour — needs a steady stream of messages, and spending a limited daily
 * allowance on that is wasteful. Never enabled unless explicitly asked for.
 */
const MOCK_REPLIES = [
  "*Nino thinks: he noticed. Of course he noticed.*\nHah? Say that again. I wasn't — I didn't want to say anything. There's a difference.\n\n...You just stare at people too much, you know that? It's creepy.",
  "*Nino thinks: why is he still here, and why don't I mind.*\nFine. Sit down if you're going to hover. I made too much anyway — don't read into it.",
  "*Nino thinks: he's fishing for something and I'm not biting.*\nWhat? Why are you looking at me like that. Say what you actually mean or go bother one of my sisters.",
];
let mockIndex = 0;

export async function complete(messages, opts = {}) {
  if (config.ai.mock) {
    await sleep(400);
    const content = MOCK_REPLIES[mockIndex % MOCK_REPLIES.length];
    mockIndex += 1;
    return { content, reasoning: null, model: 'mock', provider: 'mock', finishReason: 'stop' };
  }

  if (ladder.length === 0) {
    throw Object.assign(new Error('No AI provider is configured on the server'), { status: 503 });
  }

  const all = opts.model ? [{ provider: providers[0].name, model: opts.model }] : ladder;

  // Skip providers known to be out of allowance. If that leaves nothing, try
  // everything anyway — a stale cooldown must never be the reason chat is down.
  const live = all.filter((r) => !isCoolingDown(r.provider));
  const rungs = live.length ? live : all;

  let lastError;
  let sawRateLimit = false;

  for (const { provider, model } of rungs) {
    for (let attempt = 0; attempt < 2; attempt += 1) {
      try {
        const res = await clients.get(provider).chat.completions.create(
          {
            model,
            messages,
            temperature: opts.temperature ?? config.ai.temperature,
            top_p: opts.topP ?? config.ai.topP,
            max_tokens: opts.maxTokens ?? config.ai.maxTokens,
            stream: false,
          },
          { timeout: opts.timeout ?? config.ai.timeoutMs },
        );

        const choice = res.choices?.[0];
        if (!choice) throw new Error('Model returned no choices');

        const content = choice.message?.content ?? '';
        const reasoning = choice.message?.reasoning_content ?? choice.message?.reasoning ?? null;

        // A model that answers with nothing usable is worse than no model —
        // drop to the next rung rather than surfacing an empty bubble.
        if (!content.trim() && !reasoning) throw new Error('Model returned empty content');

        coolingUntil.delete(provider);
        return {
          content,
          reasoning,
          model,
          provider,
          finishReason: choice.finish_reason ?? null,
        };
      } catch (err) {
        lastError = err;
        const status = err.status ?? err.response?.status;
        if (status === 429) {
          sawRateLimit = true;
          startCooldown(provider);
        }

        if (status === 429 || !RETRYABLE.has(status)) break; // next rung
        await sleep(400 * (attempt + 1));
      }
    }
    console.warn(`[ai] ${provider}:${model} unavailable (${lastError?.message}) — trying next`);
  }

  if (sawRateLimit) {
    const others = configuredProviders.length > 1 ? '' : ' Adding a second provider avoids this.';
    const err = new Error(
      `Every configured AI provider is rate-limited right now.${others} ` +
      'Free allowances usually reset at 00:00 UTC.',
    );
    err.status = 429;
    throw err;
  }

  throw new Error(`All models failed. Last error: ${lastError?.message ?? 'unknown'}`);
}

export default complete;
