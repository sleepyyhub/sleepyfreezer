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
const RATE_LIMIT_COOLDOWN_MS = 15 * 60 * 1000;

/**
 * A provider that accepts a request and never answers is worse than one that
 * refuses: every message pays the full timeout before falling through. Benched
 * shorter than the rate-limit cooldown because a hang is more often transient
 * load than an exhausted allowance.
 */
const TIMEOUT_COOLDOWN_MS = 5 * 60 * 1000;

/**
 * Keyed per provider *and* model, not per provider. One account can hold a
 * capped free model and a paid one side by side — OpenRouter is exactly this —
 * and a 429 on the free model says nothing about the paid one. Cooling the
 * whole provider there would disable the fallback the credit was bought for.
 * When every model of a provider is cooling, the effect is the same as a
 * provider-wide cooldown anyway.
 */
const coolingUntil = new Map();

const rungKey = (provider, model) => `${provider}:${model}`;

const isCoolingDown = (provider, model) =>
  (coolingUntil.get(rungKey(provider, model)) ?? 0) > Date.now();

const isTimeout = (err) =>
  /timeout/i.test(err?.name ?? '') || /timed?\s*out/i.test(err?.message ?? '');

function startCooldown(provider, model, ms, reason) {
  const key = rungKey(provider, model);
  if ((coolingUntil.get(key) ?? 0) > Date.now()) return;
  coolingUntil.set(key, Date.now() + ms);
  console.warn(`[ai] ${key} ${reason} — skipping it for ${ms / 60000} minutes`);
}

/**
 * Canned replies for MOCK_AI=true. Front-end work — animation, layout, scroll
 * behaviour — needs a steady stream of messages, and spending a limited daily
 * allowance on that is wasteful. Never enabled unless explicitly asked for.
 */
const MOCK_REPLIES = [
  "*Nino thinks: he noticed. Of course he noticed.*\nHah? Say that again. I wasn't — I didn't want to say anything. There's a difference.\n\n...You just stare at people too much, you know that? It's creepy.",
  "*Nino thinks: why is he still here, and why don't I mind.*\nFine. *pulls out the chair opposite with her foot* Sit down if you're going to hover. I made too much anyway — don't read into it.",
  "*Nino thinks: he's fishing for something and I'm not biting.*\nWhat? Why are you looking at me like that. Say what you actually mean or go bother one of my sisters.",
];
let mockIndex = 0;

/**
 * Call the model, walking the ladder when a rung is unavailable.
 *
 * Free allowances are per-account, so a 429 means this provider is done for
 * now — not that the request is bad. Dropping straight to the next provider is
 * both faster and more likely to succeed than backing off here.
 */
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
  const live = all.filter((r) => !isCoolingDown(r.provider, r.model));
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

        coolingUntil.delete(rungKey(provider, model));
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
          startCooldown(provider, model, RATE_LIMIT_COOLDOWN_MS, 'is rate-limited');
        } else if (isTimeout(err)) {
          startCooldown(provider, model, TIMEOUT_COOLDOWN_MS, 'timed out');
        }

        // A timeout has already cost the full budget; retrying the same rung
        // would just spend it again.
        if (status === 429 || isTimeout(err) || !RETRYABLE.has(status)) break;
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
