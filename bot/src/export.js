import { ChannelType, PermissionsBitField } from 'discord.js';

// Discord gibt maximal 100 Nachrichten pro Request zurück.
const PAGE_SIZE = 100;

/**
 * Durchsucht die Channels einer Guild nach Nachrichten eines Users.
 *
 * Discord bietet keinen Endpunkt "alle Nachrichten von User X", also wird die
 * History jedes lesbaren Channels rückwärts durchgeblättert und clientseitig
 * gefiltert. onProgress wird gedrosselt vom Aufrufer aufgerufen.
 */
export async function scrapeUserMessages({
  guild,
  userId,
  maxScanned,
  channelFilter = null,
  onProgress = () => {},
}) {
  const me = guild.members.me ?? (await guild.members.fetchMe());

  const channels = [...guild.channels.cache.values()]
    .filter((ch) => {
      if (channelFilter) return ch.id === channelFilter.id;
      return (
        ch.type === ChannelType.GuildText ||
        ch.type === ChannelType.GuildAnnouncement
      );
    })
    .filter((ch) => {
      const perms = ch.permissionsFor(me);
      return (
        perms?.has(PermissionsBitField.Flags.ViewChannel) &&
        perms?.has(PermissionsBitField.Flags.ReadMessageHistory)
      );
    });

  // Threads mitnehmen — dort steckt oft der Großteil der Unterhaltung.
  const targets = [...channels];
  for (const ch of channels) {
    try {
      const [active, archived] = await Promise.all([
        ch.threads.fetchActive(),
        ch.threads.fetchArchived({ limit: 100 }).catch(() => ({ threads: new Map() })),
      ]);
      targets.push(...active.threads.values(), ...archived.threads.values());
    } catch {
      // Keine Thread-Rechte in diesem Channel — überspringen.
    }
  }

  const found = [];
  const skipped = [];
  let scanned = 0;

  outer: for (const channel of targets) {
    let before;

    for (;;) {
      let batch;
      try {
        batch = await channel.messages.fetch({ limit: PAGE_SIZE, before });
      } catch (err) {
        skipped.push({ channel: channel.name, reason: err.message });
        break;
      }

      if (batch.size === 0) break;

      for (const msg of batch.values()) {
        scanned++;
        if (msg.author.id === userId) found.push(serialize(msg, channel));
      }

      onProgress({ scanned, found: found.length, channel: channel.name });

      before = batch.last().id;
      if (batch.size < PAGE_SIZE) break;
      if (scanned >= maxScanned) break outer;
    }
  }

  // Discord liefert pro Channel neueste zuerst. Ein reverse() über die
  // Gesamtliste würde nur die Channel-Reihenfolge umdrehen — deshalb über die
  // Snowflake-ID sortieren, in der der Zeitstempel steckt.
  found.sort((a, b) => (BigInt(a.id) < BigInt(b.id) ? -1 : 1));

  return { messages: found, scanned, skipped, channelCount: targets.length };
}

function serialize(msg, channel) {
  return {
    id: msg.id,
    channel: channel.name,
    channelId: channel.id,
    timestamp: msg.createdAt.toISOString(),
    content: msg.content,
    replyTo: msg.reference?.messageId ?? null,
    attachments: msg.attachments.map((a) => a.url),
    stickers: msg.stickers.map((s) => s.name),
    editedAt: msg.editedAt?.toISOString() ?? null,
  };
}

export function toJson({ user, guild, result }) {
  return JSON.stringify(
    {
      user: { id: user.id, tag: user.tag, displayName: user.displayName },
      guild: { id: guild.id, name: guild.name },
      exportedAt: new Date().toISOString(),
      stats: {
        messages: result.messages.length,
        scanned: result.scanned,
        channels: result.channelCount,
        skipped: result.skipped,
      },
      messages: result.messages,
    },
    null,
    2,
  );
}

export function toText({ user, guild, result }) {
  const lines = [
    `# Nachrichten-Export`,
    `User:    ${user.tag} (${user.id})`,
    `Server:  ${guild.name}`,
    `Export:  ${new Date().toISOString()}`,
    `Treffer: ${result.messages.length} von ${result.scanned} durchsuchten Nachrichten`,
    '',
    '---',
    '',
  ];

  for (const m of result.messages) {
    const date = m.timestamp.replace('T', ' ').slice(0, 19);
    const extras = [];
    if (m.attachments.length) extras.push(`[${m.attachments.length} Anhang/Anhänge]`);
    if (m.stickers.length) extras.push(`[Sticker: ${m.stickers.join(', ')}]`);
    if (m.editedAt) extras.push('[bearbeitet]');

    const body = [m.content, extras.join(' ')].filter(Boolean).join(' ');
    lines.push(`[${date}] #${m.channel}: ${body}`);
  }

  return lines.join('\n');
}

/** Nur der reine Text, eine Nachricht pro Zeile — gut als Trainings-/Stilvorlage. */
export function toPlain({ result }) {
  return result.messages
    .map((m) => m.content.trim())
    .filter(Boolean)
    .join('\n');
}
