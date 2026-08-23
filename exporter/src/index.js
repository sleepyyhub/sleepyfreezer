#!/usr/bin/env node
import { writeFileSync, mkdirSync, existsSync, readFileSync } from 'node:fs';
import { join, resolve } from 'node:path';
import { createInterface } from 'node:readline/promises';
import { stdin, stdout } from 'node:process';

import { Discord } from './api.js';
import { viaSearch, viaCrawl } from './scrape.js';
import { toJson, toText, toPlain } from './format.js';

loadDotenv();

const args = parseArgs(process.argv.slice(2));
const rl = createInterface({ input: stdin, output: stdout });

try {
  await main();
} catch (err) {
  console.error(`\n✖ ${err.message}`);
  process.exitCode = 1;
} finally {
  rl.close();
}

async function main() {
  console.log('\n  Discord Message Exporter\n  ────────────────────────\n');

  // 1. Token
  const botToken = process.env.DISCORD_BOT_TOKEN;
  const userToken = process.env.DISCORD_USER_TOKEN;
  let token = botToken ?? userToken;
  let isBot = Boolean(botToken);

  if (!token) {
    token = (await rl.question('  Token (Bot- oder Account-Token): ')).trim();
    if (!token) throw new Error('Ohne Token geht nichts.');
    const kind = (await rl.question('  Ist das ein Bot-Token? [j/N]: ')).trim().toLowerCase();
    isBot = kind === 'j' || kind === 'y';
  }

  const api = new Discord(token, { isBot });

  const me = await api.me().catch(() => {
    throw new Error('Token abgelehnt. Falsch kopiert, abgelaufen, oder Bot/User verwechselt?');
  });
  console.log(`  Eingeloggt als ${me.username} (${isBot ? 'Bot' : 'Account'})\n`);

  // 2. Server
  const guilds = await api.guilds();
  if (guilds.length === 0) throw new Error('Dieser Token sieht keine Server.');

  const guild = args.guild
    ? guilds.find((g) => g.id === args.guild || g.name === args.guild) ??
      (() => {
        throw new Error(`Server nicht gefunden: ${args.guild}`);
      })()
    : await pick('Server', guilds, (g) => g.name);

  // 3. Ziel-User
  let userId = args.user ?? (await rl.question('  User-ID des Ziels: ')).trim();
  userId = userId.replace(/[<@!>]/g, '');
  if (!/^\d{16,20}$/.test(userId)) {
    throw new Error('Das ist keine User-ID. Entwicklermodus an, Rechtsklick auf den User → ID kopieren.');
  }

  const target = await api.request(`/users/${userId}`).catch(() => ({
    id: userId,
    username: userId,
  }));

  // 4. Format
  const format =
    args.format ??
    (await pick(
      'Format',
      [
        { key: 'plain', label: 'plain — nur Text, eine Nachricht pro Zeile (Stilvorlage)' },
        { key: 'json', label: 'json  — alles inklusive Metadaten' },
        { key: 'txt', label: 'txt   — lesbar mit Zeitstempel und Channel' },
      ],
      (f) => f.label,
    ).then((f) => f.key));

  // 5. Strategie
  const max = Number(args.max ?? 100000);
  const useSearch = !isBot && !args.crawl && !args.channel;

  console.log(
    `\n  Suche Nachrichten von ${target.username} in "${guild.name}"` +
      `\n  Methode: ${useSearch ? 'Search-API (schnell)' : 'History durchblättern (gründlich)'}\n`,
  );

  let last = 0;
  const onProgress = (p) => {
    const now = Date.now();
    if (now - last < 400) return;
    last = now;
    const line = p.channel
      ? `  ${p.scanned} durchsucht · ${p.found} gefunden · #${p.channel}`
      : `  ${p.found}${p.total ? ` / ${p.total}` : ''} gefunden`;
    stdout.write(`\r${line.padEnd(78).slice(0, 78)}`);
  };

  const params = { api, guildId: guild.id, userId, max, channelId: args.channel, onProgress };
  let result;
  if (useSearch) {
    try {
      result = await viaSearch(params);
    } catch (err) {
      console.log(`\n  Search fehlgeschlagen (${err.message}) — falle auf Crawl zurück.\n`);
      result = await viaCrawl(params);
    }
  } else {
    result = await viaCrawl(params);
  }
  stdout.write('\r'.padEnd(80) + '\r');

  if (result.messages.length === 0) {
    console.log('  Keine Nachrichten gefunden.\n');
    return;
  }

  // 6. Schreiben
  const payload = { user: target, guild, result };
  const body =
    format === 'json' ? toJson(payload) : format === 'txt' ? toText(payload) : toPlain(payload);

  const outDir = resolve(args.out ?? 'exports');
  mkdirSync(outDir, { recursive: true });
  const file = join(
    outDir,
    `${target.username}-${guild.name.replace(/[^\w-]/g, '_')}-${new Date()
      .toISOString()
      .slice(0, 10)}.${format === 'json' ? 'json' : 'txt'}`,
  );
  writeFileSync(file, body, 'utf8');

  const kb = (Buffer.byteLength(body) / 1024).toFixed(0);
  console.log(`  ✓ ${result.messages.length} Nachrichten → ${file} (${kb} KB)`);
  if (result.skipped?.length) {
    console.log(`    ${result.skipped.length} Channel(s) übersprungen (keine Leserechte).`);
  }
  console.log();
}

async function pick(label, items, render) {
  console.log(`  ${label}:`);
  items.forEach((item, i) => console.log(`    ${String(i + 1).padStart(2)}) ${render(item)}`));
  const answer = (await rl.question(`  Nummer [1-${items.length}]: `)).trim();
  const index = Number(answer) - 1;
  if (!Number.isInteger(index) || index < 0 || index >= items.length) {
    throw new Error('Ungültige Auswahl.');
  }
  console.log();
  return items[index];
}

function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (!arg.startsWith('--')) continue;
    const key = arg.slice(2);
    if (key === 'crawl') out.crawl = true;
    else out[key] = argv[++i];
  }
  return out;
}

/** Winziger .env-Leser, damit die App ohne dotenv-Dependency auskommt. */
function loadDotenv() {
  const path = resolve('.env');
  if (!existsSync(path)) return;
  for (const line of readFileSync(path, 'utf8').split('\n')) {
    const match = line.match(/^\s*([A-Z0-9_]+)\s*=\s*(.*)\s*$/i);
    if (!match) continue;
    const value = match[2].replace(/^["']|["']$/g, '');
    if (value) process.env[match[1]] ??= value;
  }
}
