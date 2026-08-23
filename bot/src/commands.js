import { EmbedBuilder, SlashCommandBuilder } from 'discord.js';

import { personalities, getPersonality } from './personalities/index.js';
import {
  getGuildPersonality,
  setGuildPersonality,
  clearHistory,
} from './state.js';

const choices = Object.entries(personalities).map(([value, p]) => ({
  name: `${p.emoji} ${p.name} — ${p.description}`,
  value,
}));

export const commandData = [
  new SlashCommandBuilder()
    .setName('personality')
    .setDescription('Wechselt die Persönlichkeit des Bots')
    .setDMPermission(false)
    .addStringOption((option) =>
      option
        .setName('name')
        .setDescription('Welche Persönlichkeit?')
        .setRequired(true)
        .addChoices(...choices),
    ),

  new SlashCommandBuilder()
    .setName('who')
    .setDescription('Zeigt, welche Persönlichkeit gerade aktiv ist')
    .setDMPermission(false),

  new SlashCommandBuilder()
    .setName('reset')
    .setDescription('Leert den Gesprächsverlauf in diesem Channel')
    .setDMPermission(false),
].map((c) => c.toJSON());

export async function handleCommand(interaction) {
  const { guildId, channelId, commandName } = interaction;

  if (commandName === 'personality') {
    const key = interaction.options.getString('name');
    const persona = getPersonality(key);
    if (!persona) {
      await interaction.reply({
        content: `Kenne ich nicht: \`${key}\`. Verfügbar: ${Object.keys(personalities).join(', ')}`,
        ephemeral: true,
      });
      return;
    }

    setGuildPersonality(guildId, key);
    await interaction.reply({
      embeds: [
        new EmbedBuilder()
          .setColor(persona.color)
          .setTitle(`${persona.emoji} ${persona.name} ist jetzt da`)
          .setDescription(persona.description)
          .setFooter({ text: 'Verlauf wurde geleert.' }),
      ],
    });
    return;
  }

  if (commandName === 'who') {
    const persona = getPersonality(getGuildPersonality(guildId));
    await interaction.reply({
      embeds: [
        new EmbedBuilder()
          .setColor(persona.color)
          .setTitle(`${persona.emoji} ${persona.name}`)
          .setDescription(persona.description),
      ],
      ephemeral: true,
    });
    return;
  }

  if (commandName === 'reset') {
    clearHistory(guildId, channelId);
    await interaction.reply({ content: 'Verlauf geleert.', ephemeral: true });
  }
}
