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
   * The fastest option measured, and no card required. Watch the per-model
   * daily cap rather than the headline account figure: llama-3.3-70b is
   * limited to about 1,000 requests a day and 30 a minute, and a group chat
   * spends several of those per message. Allowances reset daily.
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

  /**
   * Routes to open-weight models on Hugging Face's inference partners. Free
   * monthly credits with a plain HF token, no card.
   */
  huggingface: {
    baseUrl: 'https://router.huggingface.co/v1',
    envKey: 'HF_TOKEN',
    models: ['meta-llama/Llama-3.3-70B-Instruct'],
  },

  /**
   * Free with a GitHub account; the allowance is tied to your Copilot tier.
   * Uses a GitHub personal access token as the key.
   */
  github: {
    baseUrl: 'https://models.github.ai/inference',
    envKey: 'GITHUB_MODELS_TOKEN',
    models: ['openai/gpt-4.1-mini'],
  },

  /**
   * Free daily allowance, no card. Needs the account id as well as the token,
   * since it is part of the URL rather than a header.
   */
  cloudflare: {
    baseUrl: (env) =>
      `https://api.cloudflare.com/client/v4/accounts/${env.CLOUDFLARE_ACCOUNT_ID ?? ''}/ai/v1`,
    envKey: 'CLOUDFLARE_API_TOKEN',
    requires: ['CLOUDFLARE_ACCOUNT_ID'],
    models: ['@cf/meta/llama-3.3-70b-instruct-fp8-fast'],
  },

  /**
   * An aggregator. Its promotional `kimi-k3-free` accepted requests and never
   * answered when measured — 150s with zero bytes — while a paid model on the
   * same endpoint refused in 2s with a clear quota error. That is why it sits
   * last, and why the client now cools a provider down after a timeout.
   *
   * Note that an aggregator sees the full text of every conversation.
   */
  tokenrouter: {
    baseUrl: 'https://api.tokenrouter.com/v1',
    envKey: 'TOKENROUTER_API_KEY',
    models: ['moonshotai/kimi-k3-free'],
  },
};

// Quality first while allowances last, then the fastest free fallbacks, with
// the least reliable provider last.
const DEFAULT_ORDER = [
  'novita', 'openrouter', 'groq', 'cerebras', 'gemini', 'mistral',
  'cloudflare', 'huggingface', 'github', 'nvidia', 'tokenrouter',
];

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

      // Some providers need more than a key — Cloudflare puts the account id
      // in the URL. Skip rather than build a request that cannot work.
      const missing = (spec.requires ?? []).filter((v) => !env[v]);
      if (missing.length) {
        console.warn(`[ai] ${name} needs ${missing.join(', ')} as well as its key — skipping`);
        return null;
      }

      // Per-provider model override, e.g. NOVITA_MODELS=a,b
      const override = parseList(env[`${name.toUpperCase()}_MODELS`]);

      return {
        name,
        baseUrl:
          env[`${name.toUpperCase()}_BASE_URL`]
          ?? (typeof spec.baseUrl === 'function' ? spec.baseUrl(env) : spec.baseUrl),
        apiKey,
        models: override ?? spec.models,
        headers: spec.headers,
      };
    })
    .filter(Boolean);
}

export { DEFAULTS as PROVIDER_DEFAULTS, DEFAULT_ORDER };
