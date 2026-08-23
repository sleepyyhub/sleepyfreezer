import { readFileSync, writeFileSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

import { config } from './config.js';
import { DEFAULT_PERSONALITY } from './personalities/index.js';

const dataDir = join(dirname(fileURLToPath(import.meta.url)), '..', 'data');
const stateFile = join(dataDir, 'state.json');

// Persönlichkeit pro Guild — überlebt Neustarts.
let guildPersonalities = {};
// Verlauf pro Channel — nur im RAM, wird beim Neustart geleert.
const channelHistory = new Map();

try {
  guildPersonalities = JSON.parse(readFileSync(stateFile, 'utf8'));
} catch {
  guildPersonalities = {};
}

function persist() {
  try {
    mkdirSync(dataDir, { recursive: true });
    writeFileSync(stateFile, JSON.stringify(guildPersonalities, null, 2));
  } catch (err) {
    console.error('[state] Konnte state.json nicht schreiben:', err.message);
  }
}

export function getGuildPersonality(guildId) {
  return guildPersonalities[guildId] ?? DEFAULT_PERSONALITY;
}

export function setGuildPersonality(guildId, key) {
  guildPersonalities[guildId] = key;
  persist();
  // Beim Wechsel den Verlauf verwerfen, damit die neue Persona nicht die
  // Antworten der alten als eigene liest.
  for (const id of [...channelHistory.keys()]) {
    if (id.startsWith(`${guildId}:`)) channelHistory.delete(id);
  }
}

export function getHistory(guildId, channelId) {
  return channelHistory.get(`${guildId}:${channelId}`) ?? [];
}

export function pushHistory(guildId, channelId, message) {
  const key = `${guildId}:${channelId}`;
  const list = channelHistory.get(key) ?? [];
  list.push(message);
  while (list.length > config.historyLength) list.shift();
  channelHistory.set(key, list);
}

export function clearHistory(guildId, channelId) {
  channelHistory.delete(`${guildId}:${channelId}`);
}
