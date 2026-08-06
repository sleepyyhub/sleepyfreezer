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
import {
  beginRound,
  collectIntel,
  createMatch,
  decideOnPoints,
  pickAttacker,
  runRound,
  setLoadout,
} from './sim.js';
import { extractJson, needsRelay, offlineLoadout, resolveEndpoint } from './agents.js';
import { patchWebmDuration, readVint, writeVint } from './webm.js';

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

/* ------------------------------ webm patch ------------------------------ */

section('recording duration patch');
{
  // A minimal but structurally real header: EBML head, unknown-size Segment,
  // Info containing only TimecodeScale — exactly MediaRecorder's shape.
  const build = () => {
    const parts = [
      [0x1a, 0x45, 0xdf, 0xa3, 0x84, 0x42, 0x86, 0x81, 0x01],       // EBML head
      [0x18, 0x53, 0x80, 0x67, 0x01, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff], // Segment, unknown size
      [0x15, 0x49, 0xa9, 0x66, 0x84],                                // Info, size 4
      [0x2a, 0xd7, 0xb1, 0x83, 0x0f, 0x42, 0x40],                    // TimecodeScale (1ms)
    ];
    // Info's declared size covers TimecodeScale's 3-byte ID+size and payload.
    return new Uint8Array(parts.flat());
  };

  check('vint round-trips', (() => {
    const encoded = writeVint(32, 1);
    const decoded = readVint(encoded, 0);
    return decoded.value === 32 && decoded.length === 1;
  })());

  check('multi-byte vints round-trip', (() => {
    const encoded = writeVint(5000, 2);
    const decoded = readVint(encoded, 0);
    return decoded.value === 5000 && decoded.length === 2;
  })());

  const original = build();
  const patched = patchWebmDuration(original, 12345.5);

  check('duration element is inserted', patched.length === original.length + 11,
    `${original.length} -> ${patched.length}`);

  const infoAt = patched.indexOf(0x15);
  check('Info size grew by the element size', patched[infoAt + 4] === 0x80 + 4 + 11,
    `size byte 0x${patched[infoAt + 4].toString(16)}`);

  const durAt = (() => {
    for (let i = 0; i < patched.length - 1; i++) {
      if (patched[i] === 0x44 && patched[i + 1] === 0x89) return i;
    }
    return -1;
  })();
  check('Duration element is present', durAt !== -1);
  check('Duration payload is an 8-byte float', patched[durAt + 2] === 0x88);
  check('Duration holds the right value', (() => {
    const view = new DataView(patched.buffer, patched.byteOffset, patched.byteLength);
    return Math.abs(view.getFloat64(durAt + 3, false) - 12345.5) < 1e-6;
  })());

  // Patching an already-patched file must overwrite, not append a second one.
  const twice = patchWebmDuration(patched, 999);
  check('patching twice overwrites in place', twice.length === patched.length,
    `${patched.length} -> ${twice.length}`);
  check('the overwritten value is correct', (() => {
    const view = new DataView(twice.buffer, twice.byteOffset, twice.byteLength);
    return Math.abs(view.getFloat64(durAt + 3, false) - 999) < 1e-6;
  })());

  check('garbage input is returned untouched',
    patchWebmDuration(new Uint8Array([1, 2, 3, 4]), 500).length === 4);
  check('a non-finite duration is refused',
    patchWebmDuration(original, Infinity) === original);
  check('a zero duration is refused',
    patchWebmDuration(original, 0) === original);
}

/* ----------------------------- simulation ------------------------------- */

const build = (team, n, round = 1) => Array.from({ length: n }, (_, i) =>
  buildLoadout(offlineLoadout({ round, unitIndex: i, teamName: team })));

/** Play `rounds` turn-based rounds of a match, no rendering. */
function playMatch(unitsPerTeam = 3, rounds = 6) {
  const match = createMatch(build('Alpha', unitsPerTeam), build('Bravo', unitsPerTeam));
  for (let round = 1; round <= rounds && !match.over; round++) {
    const attackers = [0, 1].map((team) => pickAttacker(match, team, round));
    if (attackers.some((a) => !a)) break;
    beginRound(match, round, attackers.map((a) => a.id));
    runRound(match);
  }
  return match;
}

section('turn structure');
{
  const match = createMatch(build('Alpha', 3), build('Bravo', 3));
  check('a fresh match is not mid-round', match.roundComplete === true);

  const attackers = [0, 1].map((team) => pickAttacker(match, team, 1));
  check('one attacker is chosen per team', attackers.length === 2 && attackers.every(Boolean));
  check('attackers are on opposing teams', attackers[0].team === 0 && attackers[1].team === 1);

  beginRound(match, 1, attackers.map((a) => a.id));
  check('the round opens on an announcement', match.phase === 'announce');
  check('the announcement names the weapon',
    match.announcement.weaponName === attackers[0].loadout.weapon.name,
    match.announcement.weaponName);
  check('the announcement carries the equation',
    match.announcement.equation === attackers[0].loadout.weapon.source.y,
    match.announcement.equation);

  runRound(match);
  check('the round completes', match.roundComplete === true || match.over === true);

  const fired = match.units.filter((u) => u.turnsTaken > 0);
  check('exactly one unit per team fired', fired.length === 2,
    fired.map((u) => u.callsign).join(', '));
  check('the units that fired are the announced attackers',
    fired.every((u) => attackers.some((a) => a.id === u.id)));

  // Round 2 must hand the turn to a different unit.
  const second = [0, 1].map((team) => pickAttacker(match, team, 2));
  check('the attacker rotates between rounds',
    second[0].id !== attackers[0].id && second[1].id !== attackers[1].id,
    `${second[0].id} vs ${attackers[0].id}`);
}

section('match play');
{
  const match = playMatch(3, 6);

  check('the match progresses through rounds', match.round >= 1);

  const damaged = match.units.filter((u) => u.hitsTaken > 0);
  check('units actually traded fire', damaged.length > 0, `${damaged.length} units were hit`);

  const oneShot = match.units.filter((u) => !u.alive && u.hitsTaken < 3);
  check('nothing died in fewer than 3 hits', oneShot.length === 0,
    oneShot.map((u) => `${u.callsign} died in ${u.hitsTaken}`).join(', '));

  const straightShooters = match.units.filter((u) => u.loadout.weapon.curvature < MIN_CURVE_DEVIATION);
  check('every weapon in play is curved', straightShooters.length === 0,
    straightShooters.map((u) => u.callsign).join(', '));

  check('HP never goes negative', match.units.every((u) => u.hp >= 0));
  check('shields never exceed capacity',
    match.units.every((u) => u.shieldCharge <= u.loadout.shield.capacity + 1e-6));
  check('no projectiles are left hanging', match.projectiles.length === 0);

  // Each team fires once per round, so total volleys cannot exceed the rounds.
  for (const team of [0, 1]) {
    const turns = match.units
      .filter((u) => u.team === team)
      .reduce((sum, u) => sum + u.turnsTaken, 0);
    check(`team ${team} fired at most once per round`, turns <= match.round,
      `${turns} volleys across ${match.round} rounds`);
  }

  const decided = decideOnPoints(match);
  check('a match that runs out of rounds is still decided', decided.over === true);
  check('the decision has a stated reason', decided.reason.length > 0);
}

section('HP persists across rounds');
{
  const match = createMatch(build('Alpha', 1), build('Bravo', 1));
  const target = match.units[1];

  beginRound(match, 1, match.units.map((u) => u.id));
  runRound(match);
  const afterFirst = target.hp;

  if (afterFirst < UNIT_MAX_HP && target.alive) {
    beginRound(match, 2, match.units.map((u) => u.id));
    runRound(match);
    check('damage carries over between rounds', target.hp <= afterFirst,
      `${afterFirst} -> ${target.hp}`);
  } else {
    check('damage carries over between rounds', true, 'skipped — no damage landed in round 1');
  }
  check('a unit is never revived by a new round', target.hp <= UNIT_MAX_HP);
}

section('loadout swap mid-match');
{
  const match = createMatch(build('Alpha', 2), build('Bravo', 2));
  const unit = match.units[0];
  unit.hp = 55;
  const replacement = buildLoadout(offlineLoadout({ round: 3, unitIndex: 1, teamName: 'Alpha' }));

  setLoadout(match, unit.id, replacement);
  check('the new loadout is installed', unit.loadout === replacement);
  check('accrued damage survives a redesign', unit.hp === 55, `hp ${unit.hp}`);
  check('the new shield arrives charged',
    unit.shieldCharge === replacement.shield.capacity);
}

section('intel for the next round');
{
  const match = playMatch(2, 3);
  const intel = collectIntel(match, 1);
  check('intel covers every unit on the team', intel.length === 2);
  check('intel includes the path expression', typeof intel[0].pathY === 'string' && intel[0].pathY.length > 0);
  check('intel samples the shield around its arc', intel[0].shieldProfile.length === 8);
  check('the sampled profile has real radii',
    intel[0].shieldProfile.every((p) => p.radius > 0 && Number.isFinite(p.radius)));
  check('the profile spans a full turn',
    intel[0].shieldProfile[0].degrees === 0 && intel[0].shieldProfile[7].degrees === 315,
    intel[0].shieldProfile.map((p) => p.degrees).join(','));
}

section('determinism');
{
  const a = playMatch(2, 4);
  const b = playMatch(2, 4);
  check('the same match plays out identically',
    a.winner === b.winner && Math.abs(a.time - b.time) < 1e-9
      && a.units.every((u, i) => u.hp === b.units[i].hp),
    `${a.winner}@${a.time.toFixed(3)} vs ${b.winner}@${b.time.toFixed(3)}`);
}

console.log(`\n${passed} passed, ${failed} failed`);
process.exit(failed === 0 ? 0 : 1);
