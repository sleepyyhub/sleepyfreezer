#!/usr/bin/env node
// Uploads LUCK.lua to Luarmor, keeping the script's existing settings.
//
//   node upload-luarmor.mjs --key <api key>
//   node upload-luarmor.mjs --key <api key> --dry
//
// Node 18+, no dependencies. The key can also come from LUARMOR_API_KEY.

import { readFileSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const args = parseArgs(process.argv.slice(2));
const apiKey = args.key ?? process.env.LUARMOR_API_KEY;
const base = args.base ?? 'https://api.luarmor.net';
const here = dirname(fileURLToPath(import.meta.url));
const file = resolve(args.file ?? `${here}/LUCK.lua`);

if (!apiKey) {
  bail('Kein API-Key. --key <key> oder LUARMOR_API_KEY setzen.');
}

const source = readFileSync(file, 'utf8');
console.log(`\n  Datei    ${file}`);
console.log(`  Größe    ${(Buffer.byteLength(source) / 1024).toFixed(1)} KB\n`);

// ── 1. was liegt im Account ────────────────────────────────────────────────
const details = await api('GET', `/v3/keys/${apiKey}/details`);
if (!details.success) bail(`Key abgelehnt: ${details.message ?? 'unbekannt'}`);

const projects = details.projects ?? [];
const project = pick(projects, args.project, (p) => p.id, 'Projekt', (p) =>
  `${p.name} (${p.id}, ${p.platform})`,
);
const scripts = project.scripts ?? [];
const script = pick(scripts, args.script, (s) => s.script_id, 'Script', (s) =>
  `${s.script_name} (${s.script_id}, v${s.script_version})`,
);

console.log(`  Projekt  ${project.name}  ${project.id}`);
console.log(`  Script   ${script.script_name}  ${script.script_id}`);
console.log(`  Version  ${script.script_version}`);
console.log(`  Settings ffa=${script.ffa}  silent=${script.silent}\n`);

// ── 2. Body: neuer Code, alte Settings ─────────────────────────────────────
// ffa und silent werden ausdrücklich zurückgeschickt, damit sie sicher stehen
// bleiben. heartbeat und lightning liefert /details nicht aus, die bleiben
// weg — nur mit --heartbeat / --lightning werden sie mitgesetzt.
const body = { script: source, ffa: script.ffa, silent: script.silent };
if (args.heartbeat !== undefined) body.heartbeat = args.heartbeat === 'true';
if (args.lightning !== undefined) body.lightning = args.lightning === 'true';

if (args.dry) {
  console.log('  --dry: nichts gesendet. Body wäre:');
  console.log(`    ${JSON.stringify({ ...body, script: `<${source.length} Zeichen>` })}\n`);
  process.exit(0);
}

// ── 3. hochladen ───────────────────────────────────────────────────────────
console.log('  Lade hoch und obfuskiere…');
const result = await api(
  'PUT',
  `/v3/projects/${project.id}/scripts/${script.script_id}`,
  body,
);

if (!result.success) bail(`Upload abgelehnt: ${result.message ?? JSON.stringify(result)}`);
console.log(`\n  ✓ ${result.message ?? 'fertig'}`);
if (result.script_version) console.log(`  Neue Version: ${result.script_version}`);
console.log();

// ───────────────────────────────────────────────────────────────────────────
async function api(method, path, payload) {
  let response;
  try {
    response = await fetch(`${base}${path}`, {
      method,
      // Obfuskieren dauert; Luarmor antwortet erst danach.
      signal: AbortSignal.timeout(180000),
      headers: {
        Authorization: apiKey,
        'Content-Type': 'application/json',
      },
      body: payload ? JSON.stringify(payload) : undefined,
    });
  } catch (err) {
    bail(`${method} ${path} fehlgeschlagen: ${err.message}`);
  }

  const text = await response.text();
  let json;
  try {
    json = JSON.parse(text);
  } catch {
    // Cloudflare schiebt bei geblockten IPs eine HTML-Seite dazwischen.
    const hint = text.includes('Not Authorized')
      ? ' — Cloudflare blockt diese IP. Von einem normalen Anschluss aus laufen lassen, nicht aus VPS/Cloud.'
      : '';
    bail(`${method} ${path}: HTTP ${response.status}, kein JSON${hint}`);
  }
  return json;
}

function pick(list, wanted, idOf, label, render) {
  if (list.length === 0) bail(`Kein ${label} im Account gefunden.`);
  if (wanted) {
    const hit = list.find((x) => idOf(x) === wanted);
    if (!hit) bail(`${label} ${wanted} nicht gefunden.`);
    return hit;
  }
  if (list.length === 1) return list[0];
  console.log(`  Mehrere ${label}e — mit --${label.toLowerCase()} <id> auswählen:`);
  for (const item of list) console.log(`    ${render(item)}`);
  process.exit(1);
}

function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i++) {
    if (!argv[i].startsWith('--')) continue;
    const key = argv[i].slice(2);
    if (key === 'dry') out.dry = true;
    else out[key] = argv[++i];
  }
  return out;
}

function bail(message) {
  console.error(`\n  ✖ ${message}\n`);
  process.exit(1);
}
