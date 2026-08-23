import { REST, Routes } from 'discord.js';

import { config } from './config.js';
import { commandData } from './commands.js';

const rest = new REST({ version: '10' }).setToken(config.discordToken);

const route = config.guildId
  ? Routes.applicationGuildCommands(config.clientId, config.guildId)
  : Routes.applicationCommands(config.clientId);

try {
  await rest.put(route, { body: commandData });
  console.log(
    config.guildId
      ? `${commandData.length} Commands auf Guild ${config.guildId} registriert.`
      : `${commandData.length} Commands global registriert (kann bis zu 1h dauern).`,
  );
} catch (err) {
  console.error('Registrieren fehlgeschlagen:', err);
  process.exit(1);
}
