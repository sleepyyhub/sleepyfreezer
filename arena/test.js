#!/usr/bin/env node
/*
 * test.js — headless checks for the math language, the three arena rules and
 * the simulation. Run with: node arena/test.js
 */

import { compileExpression, MathLangError } from './mathlang.js';
import {
  MAX_DAMAGE,
  MIN_CURVE_DEVIATION,
  UNIT_MAX_HP,
  buildLoadout,
  measureCurvature,
} from './rules.js';
import { createBattle, runToCompletion } from './sim.js';
import { extractJson, needsRelay, offlineLoadout, resolveEndpoint } from './agents.js';

let passed = 0;
let failed = 0;

function check(name, condition, detail = '') {
  if (condition) {
    passed++;
    console.log(`  ok   ${name}`);
  } else {
    failed++;
    console.log(`  FAIL ${name}${detail ? ` — ${detail}` : ''}`);
  }
}

function section(title) {
  console.log(`\n${title}`);
}

/* ------------------------------ mathlang ------------------------------- */

section('math language');
{
  const f = compileExpression('2 + 3 * 4');
  check('operator precedence', f({}) === 14, `got ${f({})}`);

  const g = compileExpression('sin(t * pi)', { allowedVars: ['t'] });
  check('function call + constant', Math.abs(g({ t: 0.5 }) - 1) < 1e-9, `got ${g({ t: 0.5 })}`);

  const h = compileExpression('2 ^ 3 ^ 2');
  check('right-associative power', h({}) === 512, `got ${h({})}`);

  const div = compileExpression('5 / 0');
  check('division by zero is contained', div({}) === 0, `got ${div({})}`);

  const unknownVar = compileExpression('q + 1');
  check('unbound variable reads as 0', unknownVar({}) === 1, `got ${unknownVar({})}`);

  let rejectedVar = false;
  try {
    compileExpression('window', { allowedVars: ['t'] });
  } catch (error) {
    rejectedVar = error instanceof MathLangError;
  }
  check('rejects identifiers outside the allow-list', rejectedVar);

  let rejectedCode = false;
  try {
    compileExpression('(function(){return 1})()', { allowedVars: ['t'] });
  } catch {
    rejectedCode = true;
  }
  check('rejects code-shaped input', rejectedCode);

  let rejectedFn = false;
  try {
    compileExpression('fetch(1)');
  } catch (error) {
    rejectedFn = error instanceof MathLangError;
  }
  check('rejects unknown functions', rejectedFn);

  let rejectedLong = false;
  try {
    compileExpression('1+'.repeat(400) + '1');
  } catch {
    rejectedLong = true;
  }
  check('rejects oversized expressions', rejectedLong);
}

/* ---------------------------- curve detection --------------------------- */

section('curve measurement');
{
  const x = compileExpression('t * 300', { allowedVars: ['t'] });
  const flat = compileExpression('0', { allowedVars: ['t'] });
  check('straight path measures ~0 bend', measureCurvature(x, flat, {}) < 0.001);

  const linear = compileExpression('t * 120', { allowedVars: ['t'] });
  check('linear offset is still straight', measureCurvature(x, linear, {}) < 0.001,
    `got ${measureCurvature(x, linear, {})}`);

  const arc = compileExpression('sin(t * pi) * 80', { allowedVars: ['t'] });
  check('sine arc measures real bend', measureCurvature(x, arc, {}) > 70,
    `got ${measureCurvature(x, arc, {})}`);
}

/* ------------------------------ arena rules ----------------------------- */

section('RULE 1 — no one-shot kills');
{
  const { weapon, notes } = buildLoadout({
    weapon: { name: 'Nuke', damage: 9999, path: { x: 't * 300', y: 'sin(t * pi) * 60' } },
  });
  check('damage is capped', weapon.damage === MAX_DAMAGE, `got ${weapon.damage}`);
  check('cap leaves a unit alive after two hits', UNIT_MAX_HP - weapon.damage * 2 > 0);
  check('cap is reported to the user', notes.some((n) => n.startsWith('RULE 1')));
}

section('RULE 2 — every shot must curve');
{
  const straight = buildLoadout({
    weapon: { name: 'Rail', path: { x: 't * 300', y: '0' } },
  });
  check('straight shot is corrected', straight.weapon.curvature >= MIN_CURVE_DEVIATION,
    `got ${straight.weapon.curvature}`);
  check('correction is reported', straight.notes.some((n) => n.startsWith('RULE 2')));

  const sneaky = buildLoadout({
    weapon: { name: 'Sneaky Rail', path: { x: 't * 300', y: 't * 500' } },
  });
  check('linear offset also corrected', sneaky.notes.some((n) => n.startsWith('RULE 2')));

  const curved = buildLoadout({
    weapon: { name: 'Hook', path: { x: 't * 300', y: 'sin(t * pi) * 90' } },
  });
  check('a genuine curve is left alone', !curved.notes.some((n) => n.startsWith('RULE 2')));
}

section('RULE 3 — math only');
{
  const bad = buildLoadout({
    weapon: { name: 'Exploit', path: { x: 'document.cookie', y: 'sin(t*pi)*50' } },
    shield: { name: 'Exploit Shield', shape: 'globalThis' },
  });
  check('bad path expression is replaced', bad.weapon.source.x.includes('t *'));
  check('bad shield expression is replaced', bad.shield.source.includes('cos'));
  check('both rejections are reported', bad.notes.length >= 2);
}

section('spec clamping');
{
  const wild = buildLoadout({
    weapon: { name: 'Wild', count: 99, cooldown: 0.001, speed: 99999, range: 99999, homing: 5 },
    shield: { name: 'Fortress', capacity: 9999, absorb: 5, regen: 999, shape: '5000' },
  });
  check('projectile count clamped', wild.weapon.count <= 5, `got ${wild.weapon.count}`);
  check('cooldown clamped', wild.weapon.cooldown >= 0.35);
  check('homing clamped', wild.weapon.homing <= 0.65);
  check('absorb clamped', wild.shield.absorb <= 0.85);
  check('shield radius clamped', wild.shield.radiusAt(0, 0) <= 58,
    `got ${wild.shield.radiusAt(0, 0)}`);
}

/* -------------------------------- JSON ---------------------------------- */

section('reply parsing');
{
  check('parses a fenced reply',
    extractJson('Sure!\n```json\n{"a":1}\n```').a === 1);
  check('parses a bare object with trailing prose',
    extractJson('{"a":{"b":2}} hope that helps').a.b === 2);
  check('handles braces inside strings',
    extractJson('{"name":"a}b","v":3}').v === 3);

  let threw = false;
  try { extractJson('no json here'); } catch { threw = true; }
  check('throws on a reply with no JSON', threw);
}

/* --------------------------- endpoint routing --------------------------- */

section('endpoint routing');
{
  const withLocation = (value, fn) => {
    const had = 'location' in globalThis;
    const previous = globalThis.location;
    globalThis.location = value;
    try { return fn(); } finally {
      if (had) globalThis.location = previous;
      else delete globalThis.location;
    }
  };

  const https = { protocol: 'https:', origin: 'https://arena.example.com' };
  const http = { protocol: 'http:', origin: 'http://localhost:8080' };

  check('https page + http endpoint needs the relay',
    withLocation(https, () => needsRelay('http://106.54.43.21:3000/v1')) === true);
  check('https page + https endpoint does not',
    withLocation(https, () => needsRelay('https://api.example.com/v1')) === false);
  check('http page never needs it',
    withLocation(http, () => needsRelay('http://106.54.43.21:3000/v1')) === false);

  const config = { baseUrl: 'http://106.54.43.21:3000/v1', useRelay: false };
  check('direct routing is unchanged',
    withLocation(https, () => resolveEndpoint(config, '/chat/completions'))
      === 'http://106.54.43.21:3000/v1/chat/completions');

  const relayed = withLocation(https, () =>
    resolveEndpoint({ ...config, useRelay: true }, '/chat/completions'));
  check('relay routing prefixes the origin',
    relayed === 'https://arena.example.com/relay/http://106.54.43.21:3000/v1/chat/completions',
    relayed);
  check('relay URL survives URL normalisation',
    new URL(relayed).pathname === '/relay/http://106.54.43.21:3000/v1/chat/completions',
    new URL(relayed).pathname);

  check('trailing slashes on the base URL are handled',
    withLocation(https, () => resolveEndpoint({ baseUrl: 'https://api.example.com/v1//' }, '/chat/completions'))
      === 'https://api.example.com/v1/chat/completions');
}

/* ----------------------------- simulation ------------------------------- */

section('simulation');
{
  const build = (team, n) => Array.from({ length: n }, (_, i) =>
    buildLoadout(offlineLoadout({ round: 1, unitIndex: i, teamName: team })));

  const battle = createBattle(build('Alpha', 3), build('Bravo', 3));
  runToCompletion(battle);

  check('battle terminates', battle.over === true);
  check('a result is recorded', battle.reason.length > 0);

  const damaged = battle.units.filter((u) => u.hitsTaken > 0);
  check('units actually traded fire', damaged.length > 0,
    `${damaged.length} units were hit`);

  const oneShot = battle.units.filter((u) => !u.alive && u.hitsTaken < 3);
  check('nothing died in fewer than 3 hits', oneShot.length === 0,
    oneShot.map((u) => `${u.callsign} died in ${u.hitsTaken}`).join(', '));

  const straightShooters = battle.units.filter((u) => u.loadout.weapon.curvature < MIN_CURVE_DEVIATION);
  check('every weapon in play is curved', straightShooters.length === 0,
    straightShooters.map((u) => u.callsign).join(', '));

  check('HP never goes negative', battle.units.every((u) => u.hp >= 0));
  check('shields never exceed capacity',
    battle.units.every((u) => u.shieldCharge <= u.loadout.shield.capacity + 1e-6));
}

section('determinism');
{
  const build = (team) => Array.from({ length: 2 }, (_, i) =>
    buildLoadout(offlineLoadout({ round: 2, unitIndex: i, teamName: team })));
  const a = runToCompletion(createBattle(build('Alpha'), build('Bravo')));
  const b = runToCompletion(createBattle(build('Alpha'), build('Bravo')));
  check('same loadouts produce the same result',
    a.winner === b.winner && Math.abs(a.time - b.time) < 1e-9,
    `${a.winner}@${a.time.toFixed(3)} vs ${b.winner}@${b.time.toFixed(3)}`);
}

console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
