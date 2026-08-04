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

  /** Separate free allowance again. Avoid the reasoning models here — they
   *  leak planning prose into the reply and are slow on the free tier. */
  nvidia: {
    baseUrl: 'https://integrate.api.nvidia.com/v1',
    envKey: 'NVIDIA_API_KEY',
    models: ['meta/llama-3.3-70b-instruct', 'mistralai/mistral-medium-3.5-128b'],
  },

  /** Fast, generous free tier, but smaller models. */
  groq: {
    baseUrl: 'https://api.groq.com/openai/v1',
    envKey: 'GROQ_API_KEY',
    models: ['llama-3.3-70b-versatile'],
  },
};

const DEFAULT_ORDER = ['novita', 'openrouter', 'nvidia', 'groq'];

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
