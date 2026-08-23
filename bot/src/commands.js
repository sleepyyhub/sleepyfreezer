import {
  AttachmentBuilder,
  ChannelType,
  EmbedBuilder,
  PermissionFlagsBits,
  SlashCommandBuilder,
} from 'discord.js';

import { personalities, getPersonality } from './personalities/index.js';
import {
  getGuildPersonality,
  setGuildPersonality,
  clearHistory,
} from './state.js';
import { scrapeUserMessages, toJson, toText, toPlain } from './export.js';

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

  new SlashCommandBuilder()
    .setName('exportuser')
    .setDescription('Exportiert alle Nachrichten eines Users als Datei')
    .setDMPermission(false)
    // Nur Moderatoren — das hier liest die halbe Server-History aus.
    .setDefaultMemberPermissions(PermissionFlagsBits.ManageMessages)
    .addUserOption((o) =>
      o.setName('user').setDescription('Wessen Nachrichten?').setRequired(true),
    )
    .addStringOption((o) =>
      o
        .setName('format')
        .setDescription('Dateiformat (Standard: json)')
        .addChoices(
          { name: 'json — alles inkl. Metadaten', value: 'json' },
          { name: 'txt — lesbar mit Zeitstempel und Channel', value: 'txt' },
          { name: 'plain — nur der Text, eine Nachricht pro Zeile', value: 'plain' },
        ),
    )
    .addChannelOption((o) =>
      o
        .setName('channel')
        .setDescription('Nur diesen Channel durchsuchen (schneller)')
        .addChannelTypes(ChannelType.GuildText, ChannelType.GuildAnnouncement),
    )
    .addIntegerOption((o) =>
      o
        .setName('max')
        .setDescription('Wie viele Nachrichten maximal durchsuchen (Standard: 50000)')
        .setMinValue(100)
        .setMaxValue(500000),
    ),
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
    return;
  }

  if (commandName === 'exportuser') {
    await handleExport(interaction);
  }
}

// Discord nimmt ohne Nitro maximal 10 MB pro Anhang.
const MAX_UPLOAD = 9 * 1024 * 1024;

async function handleExport(interaction) {
  const user = interaction.options.getUser('user', true);
  const format = interaction.options.getString('format') ?? 'json';
  const channelFilter = interaction.options.getChannel('channel');
  const maxScanned = interaction.options.getInteger('max') ?? 50000;

  // Der Scan dauert Minuten — Antwort sofort aufschieben, sonst Timeout.
  await interaction.deferReply({ ephemeral: true });

  let lastEdit = 0;
  const onProgress = ({ scanned, found, channel }) => {
    const now = Date.now();
    if (now - lastEdit < 5000) return; // Rate-Limit schonen
    lastEdit = now;
    interaction
      .editReply(
        `Suche läuft… \`#${channel}\` — ${scanned} Nachrichten durchsucht, **${found}** von ${user.tag} gefunden.`,
      )
      .catch(() => {});
  };

  const result = await scrapeUserMessages({
    guild: interaction.guild,
    userId: user.id,
    maxScanned,
    channelFilter,
    onProgress,
  });

  if (result.messages.length === 0) {
    await interaction.editReply(
      `Keine Nachrichten von ${user.tag} gefunden (${result.scanned} durchsucht in ${result.channelCount} Channels).`,
    );
    return;
  }

  const payload = { user, guild: interaction.guild, result };
  const body =
    format === 'json' ? toJson(payload) : format === 'txt' ? toText(payload) : toPlain(payload);

  const extension = format === 'json' ? 'json' : 'txt';
  const stamp = new Date().toISOString().slice(0, 10);
  const base = `${user.username}-${stamp}.${extension}`;

  let buffer = Buffer.from(body, 'utf8');
  let filename = base;
  if (buffer.length > MAX_UPLOAD) {
    const { gzipSync } = await import('node:zlib');
    buffer = gzipSync(buffer);
    filename = `${base}.gz`;
  }

  if (buffer.length > MAX_UPLOAD) {
    await interaction.editReply(
      `Export ist mit ${(buffer.length / 1024 / 1024).toFixed(1)} MB auch gepackt zu groß für Discord. Grenz es mit \`channel:\` oder \`max:\` ein.`,
    );
    return;
  }

  const skippedNote = result.skipped.length
    ? `\n${result.skipped.length} Channel(s) übersprungen (keine Rechte).`
    : '';

  await interaction.editReply({
    content:
      `**${result.messages.length}** Nachrichten von ${user.tag} exportiert ` +
      `(${result.scanned} durchsucht, ${result.channelCount} Channels).${skippedNote}`,
    files: [new AttachmentBuilder(buffer, { name: filename })],
  });
}
