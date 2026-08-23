import { Client, Events, GatewayIntentBits, Partials } from 'discord.js';

import { config } from './config.js';
import { handleCommand } from './commands.js';
import { chat } from './openrouter.js';
import { getPersonality } from './personalities/index.js';
import { getGuildPersonality, getHistory, pushHistory } from './state.js';
import { startKeepAlive } from './keepalive.js';
import { deployCommands } from './deploy-commands.js';

const client = new Client({
  intents: [
    GatewayIntentBits.Guilds,
    GatewayIntentBits.GuildMessages,
    GatewayIntentBits.MessageContent,
  ],
  partials: [Partials.Channel],
});

// Pro Channel nur eine Anfrage gleichzeitig — sonst überholen sich Antworten.
const busy = new Set();

client.once(Events.ClientReady, async (c) => {
  console.log(`Eingeloggt als ${c.user.tag} — Modell: ${config.model}`);

  // Auf Render gibt es keine Shell für "npm run deploy" — beim Start selbst
  // registrieren. Der PUT ist idempotent.
  if (process.env.AUTO_DEPLOY_COMMANDS !== 'false') {
    try {
      await deployCommands();
    } catch (err) {
      console.error('[commands] Registrieren fehlgeschlagen:', err.message);
    }
  }
});

startKeepAlive(() => ({
  bot: client.user?.tag ?? null,
  ready: client.isReady(),
  guilds: client.guilds.cache.size,
  uptime: Math.floor((client.uptime ?? 0) / 1000),
}));

client.on(Events.InteractionCreate, async (interaction) => {
  if (!interaction.isChatInputCommand()) return;
  try {
    await handleCommand(interaction);
  } catch (err) {
    console.error('[command]', err);
    const payload = { content: 'Da ist was schiefgelaufen.', ephemeral: true };
    if (interaction.deferred || interaction.replied) {
      await interaction.followUp(payload).catch(() => {});
    } else {
      await interaction.reply(payload).catch(() => {});
    }
  }
});

client.on(Events.MessageCreate, async (message) => {
  if (message.author.bot || !message.guildId) return;

  // Der Bot antwortet auf Erwähnungen und auf Replies auf eigene Nachrichten.
  const mentioned = message.mentions.has(client.user);
  const isReplyToBot =
    message.reference?.messageId &&
    (await message.channel.messages
      .fetch(message.reference.messageId)
      .then((m) => m.author.id === client.user.id)
      .catch(() => false));

  if (!mentioned && !isReplyToBot) return;

  const content = message.content
    .replace(new RegExp(`<@!?${client.user.id}>`, 'g'), '')
    .trim();
  if (!content) return;

  const key = `${message.guildId}:${message.channelId}`;
  if (busy.has(key)) {
    await message.react('⏳').catch(() => {});
    return;
  }
  busy.add(key);

  try {
    const persona = getPersonality(getGuildPersonality(message.guildId));
    const history = getHistory(message.guildId, message.channelId);

    const messages = [
      { role: 'system', content: persona.systemPrompt },
      ...history,
      { role: 'user', content: `${message.author.displayName}: ${content}` },
    ];

    await message.channel.sendTyping();
    const reply = await chat(messages);

    pushHistory(message.guildId, message.channelId, {
      role: 'user',
      content: `${message.author.displayName}: ${content}`,
    });
    pushHistory(message.guildId, message.channelId, {
      role: 'assistant',
      content: reply,
    });

    // Discord deckelt bei 2000 Zeichen — an Zeilenumbrüchen aufteilen.
    for (const chunk of splitMessage(reply, 1900)) {
      await message.reply(chunk);
    }
  } catch (err) {
    console.error('[chat]', err);
    await message
      .reply('Ich komm gerade nicht ans Modell ran. Versuch es gleich nochmal.')
      .catch(() => {});
  } finally {
    busy.delete(key);
  }
});

function splitMessage(text, limit) {
  if (text.length <= limit) return [text];

  const chunks = [];
  let current = '';
  for (const line of text.split('\n')) {
    if (current.length + line.length + 1 > limit) {
      if (current) chunks.push(current);
      // Einzelne überlange Zeile hart schneiden.
      let rest = line;
      while (rest.length > limit) {
        chunks.push(rest.slice(0, limit));
        rest = rest.slice(limit);
      }
      current = rest;
    } else {
      current = current ? `${current}\n${line}` : line;
    }
  }
  if (current) chunks.push(current);
  return chunks;
}

client.login(config.discordToken);
