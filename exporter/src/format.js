export function toJson({ user, guild, result }) {
  return JSON.stringify(
    {
      user: { id: user.id, tag: user.username, displayName: user.global_name ?? user.username },
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
    '# Nachrichten-Export',
    `User:    ${user.username} (${user.id})`,
    `Server:  ${guild.name}`,
    `Export:  ${new Date().toISOString()}`,
    `Treffer: ${result.messages.length}`,
    '',
    '---',
    '',
  ];

  for (const m of result.messages) {
    const date = String(m.timestamp).replace('T', ' ').slice(0, 19);
    const extras = [];
    if (m.attachments.length) extras.push(`[${m.attachments.length} Anhang/Anhänge]`);
    if (m.stickers.length) extras.push(`[Sticker: ${m.stickers.join(', ')}]`);
    if (m.editedAt) extras.push('[bearbeitet]');

    const body = [m.content, extras.join(' ')].filter(Boolean).join(' ');
    lines.push(`[${date}]${m.channel ? ` #${m.channel}` : ''}: ${body}`);
  }

  return lines.join('\n');
}

/** Nur der reine Text, eine Nachricht pro Zeile — die beste Stilvorlage. */
export function toPlain({ result }) {
  return result.messages
    .map((m) => m.content.replace(/\s+/g, ' ').trim())
    .filter(Boolean)
    .join('\n');
}
