import { sleep } from './api.js';

// Text- und Announcement-Channels sowie Threads. Voice/Kategorien fliegen raus.
const READABLE = new Set([0, 5, 10, 11, 12]);

/** Schneller Weg: Discords Guild-Search, nur mit User-Token erreichbar. */
export async function viaSearch({ api, guildId, userId, max, onProgress }) {
  const messages = [];
  let offset = 0;
  let total = null;

  for (;;) {
    const page = await api.search(guildId, userId, offset);

    // Discord antwortet mit 202, während der Index noch gebaut wird.
    if (page.retry_after) {
      await sleep((page.retry_after ?? 1) * 1000);
      continue;
    }

    total ??= page.total_results ?? 0;
    // messages ist ein Array von Arrays — der Treffer plus Kontext drumherum.
    const hits = (page.messages ?? []).map((group) => group.find((m) => m.hit) ?? group[0]);
    if (hits.length === 0) break;

    for (const m of hits) {
      if (m.author?.id === userId) messages.push(serialize(m));
    }

    onProgress({ found: messages.length, total });

    offset += 25;
    if (messages.length >= max || offset >= Math.min(total, 5000)) break;
  }

  return {
    messages: chronological(messages),
    scanned: total ?? messages.length,
    channelCount: 0,
    skipped: [],
  };
}

/** Robuster Weg: jeden Channel rückwärts durchblättern. Funktioniert mit beiden Token-Arten. */
export async function viaCrawl({ api, guildId, userId, max, channelId, onProgress }) {
  const all = await api.channels(guildId);
  let targets = all.filter((c) => READABLE.has(c.type));
  if (channelId) targets = targets.filter((c) => c.id === channelId);

  // Threads mitnehmen — dort steckt oft der Großteil der Unterhaltung.
  if (!channelId) {
    try {
      const active = await api.activeThreads(guildId);
      targets.push(...(active.threads ?? []));
    } catch {
      // Ohne Bot-Token nicht verfügbar; Archiv-Threads pro Channel reichen dann.
    }
  }
  for (const channel of [...targets]) {
    if (channel.type !== 0 && channel.type !== 5) continue;
    try {
      const archived = await api.archivedThreads(channel.id);
      targets.push(...(archived.threads ?? []));
    } catch {
      // Keine Rechte auf Threads dieses Channels.
    }
  }

  const seen = new Set();
  targets = targets.filter((c) => !seen.has(c.id) && seen.add(c.id));

  const messages = [];
  const skipped = [];
  let scanned = 0;

  outer: for (const channel of targets) {
    let before;

    for (;;) {
      let batch;
      try {
        batch = await api.messages(channel.id, { before });
      } catch (err) {
        // 403 heißt schlicht: dieser Channel ist für uns nicht lesbar.
        skipped.push({ channel: channel.name, reason: err.status ?? err.message });
        break;
      }

      if (batch.length === 0) break;

      for (const m of batch) {
        scanned++;
        if (m.author?.id === userId) messages.push(serialize(m, channel.name));
      }

      onProgress({ scanned, found: messages.length, channel: channel.name });

      before = batch[batch.length - 1].id;
      if (batch.length < 100) break;
      if (scanned >= max) break outer;
    }
  }

  return { messages: chronological(messages), scanned, channelCount: targets.length, skipped };
}

/**
 * Discord liefert pro Channel neueste zuerst. Ein einfaches reverse() über die
 * Gesamtliste würde nur die Channel-Reihenfolge umdrehen, nicht chronologisch
 * sortieren — deshalb über die Snowflake-ID, in der der Zeitstempel steckt.
 */
function chronological(messages) {
  return messages.sort((a, b) => (BigInt(a.id) < BigInt(b.id) ? -1 : 1));
}

function serialize(m, channelName) {
  return {
    id: m.id,
    channelId: m.channel_id,
    channel: channelName ?? null,
    timestamp: m.timestamp,
    editedAt: m.edited_timestamp ?? null,
    content: m.content ?? '',
    replyTo: m.referenced_message?.id ?? m.message_reference?.message_id ?? null,
    attachments: (m.attachments ?? []).map((a) => a.url),
    stickers: (m.sticker_items ?? []).map((s) => s.name),
  };
}
