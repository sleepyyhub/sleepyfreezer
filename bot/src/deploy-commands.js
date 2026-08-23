import { REST, Routes } from 'discord.js';

import { config } from './config.js';
import { commandData } from './commands.js';

export async function deployCommands() {
  const rest = new REST({ version: '10' }).setToken(config.discordToken);

  const route = config.guildId
    ? Routes.applicationGuildCommands(config.clientId, config.guildId)
    : Routes.applicationCommands(config.clientId);

  await rest.put(route, { body: commandData });

  console.log(
    config.guildId
      ? `[commands] ${commandData.length} Commands auf Guild ${config.guildId} registriert.`
      : `[commands] ${commandData.length} Commands global registriert (bis zu 1h Verzögerung).`,
  );
}

// Direkt aufgerufen (npm run deploy) statt importiert.
const { realpathSync } = await import('node:fs');
const { fileURLToPath } = await import('node:url');
const isMain =
  process.argv[1] && realpathSync(process.argv[1]) === fileURLToPath(import.meta.url);

if (isMain) {
  try {
    await deployCommands();
  } catch (err) {
    console.error('[commands] Registrieren fehlgeschlagen:', err);
    process.exit(1);
  }
}
