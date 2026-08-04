/**
 * Provider registry.
 *
 * Every provider here is OpenAI-compatible, so they differ only by base URL,
 * key, and model names. A provider is enabled by setting its API key; the
 * ladder then spans providers as well as models, which matters because free
 * allowances are per-account. Exhausting one provider's daily quota falls
 * through to the next rather than taking the whole app down.
 *
 * Order matters: put the provider with the most headroom first.
 */

const DEFAULTS = {
  /**
   * Novita hosts Ling-3.0-flash at zero cost per token and is the upstream
   * OpenRouter resells it from, so going direct avoids OpenRouter's free-tier
   * request cap. Novita applies its own rate limits, which are not published
   * per-account — treat this as "cheaper to call", not "unlimited".
   */
  novita: {
    baseUrl: 'https://api.novita.ai/v3/openai',
    envKey: 'NOVITA_API_KEY',
    models: ['inclusionai/ling-3.0-flash'],
  },

  /**
   * Free models here are capped per day per account, and the cap is shared
   * across every `:free` model, so listing more of them does not buy headroom.
   */
  openrouter: {
    baseUrl: 'https://openrouter.ai/api/v1',
    envKey: 'OPENROUTER_API_KEY',
    models: [
      'inclusionai/ling-3.0-flash:free',
      'google/gemma-4-31b-it:free',
      'nvidia/nemotron-3-nano-30b-a3b:free',
      'openai/gpt-oss-20b:free',
    ],
    headers: (config) => ({
      'HTTP-Referer': config.clientUrl,
      'X-Title': 'Clovyre',
    }),
  },

  /**
   * The best free fallback measured here: no card required, roughly 14k
   * requests a day, and the lowest latency of anything tried — Groq runs on
   * its own inference hardware. Capped at 30 requests/minute, which a group
   * chat can brush against during a bot-to-bot chain.
   */
  groq: {
    baseUrl: 'https://api.groq.com/openai/v1',
    envKey: 'GROQ_API_KEY',
    models: ['llama-3.3-70b-versatile', 'llama-3.1-8b-instant'],
  },

  /**
   * Around 1,500 requests a day, no card. Note that Google's terms allow
   * free-tier prompts to be used for training, which is a poor fit for private
   * conversations — reach for this after the others.
   */
  gemini: {
    baseUrl: 'https://generativelanguage.googleapis.com/v1beta/openai',
    envKey: 'GEMINI_API_KEY',
    // Model names move fast here; check the provider's list if one 404s.
    models: ['gemini-flash-latest', 'gemini-2.5-flash'],
  },

  /** Very fast, ~1M tokens/day. The no-card free tier is being retired in
   *  favour of a credit-based one, so treat it as temporary. */
  cerebras: {
    baseUrl: 'https://api.cerebras.ai/v1',
    envKey: 'CEREBRAS_API_KEY',
    models: ['llama-3.3-70b'],
  },

  /**
   * A separate free allowance, but measured here as the least reliable of the
   * set: 503s, 529s and requests exceeding 70s on the larger models. The 8B
   * model answers in under a second and is the only one worth keeping.
   */
  nvidia: {
    baseUrl: 'https://integrate.api.nvidia.com/v1',
    envKey: 'NVIDIA_API_KEY',
    models: ['meta/llama-3.1-8b-instruct'],
  },

  mistral: {
    baseUrl: 'https://api.mistral.ai/v1',
    envKey: 'MISTRAL_API_KEY',
    models: ['mistral-small-latest'],
  },
};

// Quality first while allowances last, then the fastest free fallbacks, with
// the least reliable provider last.
const DEFAULT_ORDER = ['novita', 'openrouter', 'groq', 'cerebras', 'gemini', 'mistral', 'nvidia'];

const parseList = (raw) => {
  const items = (raw ?? '').split(',').map((s) => s.trim()).filter(Boolean);
  return items.length ? items : undefined;
};

/**
 * Resolve the enabled providers, in the order they should be tried.
 * A provider without a key is skipped silently — that is how it stays optional.
 */
export function resolveProviders(env = process.env) {
  const order = parseList(env.AI_PROVIDERS) ?? DEFAULT_ORDER;

  return order
    .map((name) => {
      const spec = DEFAULTS[name];
      if (!spec) {
        console.warn(`[ai] unknown provider "${name}" in AI_PROVIDERS — skipping`);
        return null;
      }

      const apiKey = env[spec.envKey];
      if (!apiKey) return null;

      // Per-provider model override, e.g. NOVITA_MODELS=a,b
      const override = parseList(env[`${name.toUpperCase()}_MODELS`]);

      return {
        name,
        baseUrl: env[`${name.toUpperCase()}_BASE_URL`] ?? spec.baseUrl,
        apiKey,
        models: override ?? spec.models,
        headers: spec.headers,
      };
    })
    .filter(Boolean);
}

export { DEFAULTS as PROVIDER_DEFAULTS, DEFAULT_ORDER };
