import OpenAI from 'openai';
import config from '../config.js';

const client = new OpenAI({
  baseURL: config.ai.baseUrl,
  apiKey: config.ai.apiKey,
  defaultHeaders: {
    // OpenRouter uses these for attribution and free-tier ranking.
    'HTTP-Referer': config.clientUrl,
    'X-Title': 'Clovyre',
  },
});

const RETRYABLE = new Set([408, 409, 429, 500, 502, 503, 504]);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/**
 * Call the model, walking down the configured ladder when one is unavailable.
 *
 * Free models are rate-limited per-model rather than per-key, so a 429 on the
 * primary usually means the next model in the ladder is free to take the call.
 * Falling through is faster than backing off, and keeps chat responsive.
 */
export async function complete(messages, opts = {}) {
  const ladder = opts.model ? [opts.model] : config.ai.models;
  let lastError;

  for (const model of ladder) {
    for (let attempt = 0; attempt < 2; attempt += 1) {
      try {
        const res = await client.chat.completions.create(
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

        return { content, reasoning, model, finishReason: choice.finish_reason ?? null };
      } catch (err) {
        lastError = err;
        const status = err.status ?? err.response?.status;

        if (status === 429 || !RETRYABLE.has(status)) break; // next model
        await sleep(400 * (attempt + 1));
      }
    }
    console.warn(`[ai] ${model} unavailable (${lastError?.message}) — trying next`);
  }

  throw new Error(`All models failed. Last error: ${lastError?.message ?? 'unknown'}`);
}

export default complete;
