import 'dotenv/config';

function required(name) {
  const value = process.env[name];
  if (!value) {
    console.error(`[config] Fehlende Umgebungsvariable: ${name}`);
    process.exit(1);
  }
  return value;
}

export const config = {
  discordToken: required('DISCORD_TOKEN'),
  clientId: required('DISCORD_CLIENT_ID'),
  // Optional: auf eine Guild registrieren (sofort sichtbar statt ~1h global).
  guildId: process.env.DISCORD_GUILD_ID || null,

  openRouterKey: required('OPENROUTER_API_KEY'),
  model: process.env.OPENROUTER_MODEL || 'openrouter/ox-alpha',
  baseUrl: process.env.OPENROUTER_BASE_URL || 'https://openrouter.ai/api/v1',

  maxTokens: Number(process.env.MAX_TOKENS || 600),
  temperature: Number(process.env.TEMPERATURE || 0.9),
  // Wie viele vergangene Nachrichten pro Channel im Kontext bleiben.
  historyLength: Number(process.env.HISTORY_LENGTH || 20),
};
