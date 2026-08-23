const BASE = 'https://discord.com/api/v10';

/**
 * Minimaler Discord-REST-Client. Keine Dependencies — Node 18+ hat fetch.
 *
 * Bot-Token wird als "Bot <token>" geschickt, User-Token roh. Das ist der
 * einzige Unterschied im Header, aber er entscheidet, welche Endpunkte
 * überhaupt erreichbar sind (Search gibt es nur für User).
 */
export class Discord {
  constructor(token, { isBot }) {
    this.auth = isBot ? `Bot ${token}` : token;
    this.isBot = isBot;
  }

  async request(path, { retries = 5 } = {}) {
    for (let attempt = 0; ; attempt++) {
      let res;
      try {
        res = await fetch(`${BASE}${path}`, {
          // Ohne Timeout hängt fetch bei Netzproblemen unbegrenzt.
          signal: AbortSignal.timeout(20000),
          headers: {
            Authorization: this.auth,
            'User-Agent': 'DiscordBot (https://github.com/sleepyyhub/sleepyfreezer, 1.0)',
          },
        });
      } catch (err) {
        if (attempt >= retries) {
          throw new Error(`Discord nicht erreichbar (${path}): ${err.message}`);
        }
        await sleep(2 ** attempt * 500);
        continue;
      }

      if (res.status === 429) {
        const body = await res.json().catch(() => ({}));
        const wait = Math.ceil((body.retry_after ?? 1) * 1000) + 250;
        if (attempt >= retries) throw new Error(`Rate limit hält an (${path})`);
        process.stderr.write(`  … rate limit, warte ${(wait / 1000).toFixed(1)}s\n`);
        await sleep(wait);
        continue;
      }

      if (res.status >= 500) {
        if (attempt >= retries) throw new Error(`Discord ${res.status} bei ${path}`);
        await sleep(2 ** attempt * 500);
        continue;
      }

      if (!res.ok) {
        const text = await res.text();
        const err = new Error(`Discord ${res.status} bei ${path}: ${text.slice(0, 300)}`);
        err.status = res.status;
        throw err;
      }

      // Proaktiv bremsen, bevor Discord uns bremst.
      const remaining = Number(res.headers.get('x-ratelimit-remaining'));
      const resetAfter = Number(res.headers.get('x-ratelimit-reset-after'));
      if (remaining === 0 && resetAfter > 0) await sleep(resetAfter * 1000 + 100);

      return res.status === 204 ? null : res.json();
    }
  }

  me() {
    return this.request('/users/@me');
  }

  guilds() {
    return this.request('/users/@me/guilds?limit=200');
  }

  channels(guildId) {
    return this.request(`/guilds/${guildId}/channels`);
  }

  messages(channelId, { before, limit = 100 } = {}) {
    const query = new URLSearchParams({ limit: String(limit) });
    if (before) query.set('before', before);
    return this.request(`/channels/${channelId}/messages?${query}`);
  }

  activeThreads(guildId) {
    return this.request(`/guilds/${guildId}/threads/active`);
  }

  archivedThreads(channelId) {
    return this.request(`/channels/${channelId}/threads/archived/public?limit=100`);
  }

  /**
   * Nur mit User-Token verfügbar. Liefert direkt alle Nachrichten eines Autors
   * in der Guild, 25 pro Seite — deutlich schneller als jeden Channel zu
   * durchblättern.
   */
  search(guildId, authorId, offset = 0) {
    const query = new URLSearchParams({
      author_id: authorId,
      offset: String(offset),
      sort_by: 'timestamp',
      sort_order: 'desc',
    });
    return this.request(`/guilds/${guildId}/messages/search?${query}`);
  }
}

export function sleep(ms) {
  return new Promise((r) => setTimeout(r, ms));
}
