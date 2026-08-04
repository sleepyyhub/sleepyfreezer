import 'dotenv/config';

const required = (key, fallback) => {
  const value = process.env[key] ?? fallback;
  if (value === undefined) throw new Error(`Missing required env var: ${key}`);
  return value;
};

/** Comma-separated env var to array, or undefined when unset/empty. */
const parseList = (raw) => {
  const items = (raw ?? '').split(',').map((s) => s.trim()).filter(Boolean);
  return items.length ? items : undefined;
};

export const config = {
  port: Number(process.env.PORT ?? 4000),
  env: process.env.NODE_ENV ?? 'development',
  isProd: process.env.NODE_ENV === 'production',
  clientUrl: process.env.CLIENT_URL ?? 'http://localhost:5173',
  jwtSecret: required('JWT_SECRET', 'dev-only-secret'),
  cronSecret: process.env.CRON_SECRET ?? 'dev-cron-secret',

  // Set only when the frontend is hosted on a different domain from the API.
  // Requires HTTPS on both ends.
  crossSiteCookies: process.env.CROSS_SITE_COOKIES === 'true',

  ai: {
    /**
     * Providers and their model ladders live in ai/providers.js.
     *
     * ling-3.0-flash leads on measured results: 2-4s replies, it holds voice
     * and verbal tics, it mirrors the user's language, it gets in-world facts
     * right, and it stays in character in mature mode.
     *
     * Deliberately excluded: the Nemotron reasoning models leak their planning
     * prose into `content`, and emit <unk> garbage when reasoning is disabled.
     */

    // Lowered from the vendor default of 1.0 — characters drift out of voice
    // at high temperature, and we want consistency over novelty.
    temperature: 0.7,
    topP: 0.95,
    maxTokens: 2048,
    timeoutMs: 60_000,

    // Dev only: serve canned replies instead of calling a provider, so UI work
    // does not consume a limited daily allowance.
    mock: process.env.MOCK_AI === 'true',

    // Cheaper settings for the group "director" call, which only picks names.
    directorTemperature: 0.3,
    directorMaxTokens: 256,
  },

  oauth: {
    google: {
      clientId: process.env.GOOGLE_CLIENT_ID ?? '',
      clientSecret: process.env.GOOGLE_CLIENT_SECRET ?? '',
    },
    discord: {
      clientId: process.env.DISCORD_CLIENT_ID ?? '',
      clientSecret: process.env.DISCORD_CLIENT_SECRET ?? '',
    },
  },

  pusher: {
    appId: process.env.PUSHER_APP_ID ?? '',
    key: process.env.PUSHER_KEY ?? '',
    secret: process.env.PUSHER_SECRET ?? '',
    cluster: process.env.PUSHER_CLUSTER ?? 'eu',
  },

  group: {
    // Chance that a second character jumps in after the first one replies.
    chainProbability: 0.4,
    // Hard cap on bot-to-bot exchanges before we wait for the user again.
    maxChainDepth: 3,
    // How many characters may answer a single user message.
    maxDirectResponders: 2,
  },

  proactive: {
    // A character will not message the same user more often than this.
    minHoursBetween: 2,
    maxHoursBetween: 6,
    // Skip users who have not opened the app in this long.
    inactiveAfterDays: 14,

    // How often the in-process scheduler sweeps. 0 disables it, leaving the
    // POST /api/cron/proactive endpoint as the only trigger.
    intervalMinutes: Number(process.env.PROACTIVE_INTERVAL_MINUTES ?? 30),
  },
};

export default config;
