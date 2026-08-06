/*
 * sim.js — the arena. Turn-based: one unit per team attacks per round.
 *
 * A match is a single continuous battle. HP and shield charge persist across
 * rounds, so the two-attack survival rule is visible over the whole match
 * rather than reset each time.
 *
 * Each round runs two turns — team 0's attacker, then team 1's. A turn is:
 *
 *   announce   the attacker declares its weapon name and the equation
 *   fire       one volley flies, following the weapon's math path
 *   settle     leftover projectiles resolve
 *
 * Only the attacker fires. Everyone else holds position with shields up.
 */

import { UNIT_MAX_HP } from './rules.js';

export const ARENA = { width: 960, height: 540 };
const UNIT_RADIUS = 13;
const STEP = 1 / 60;

// Front lines sit ~460px apart, comfortably inside the legal range band so a
// mid-range weapon can reach without a max-range build being mandatory.
const START_X = 250;
export const ENGAGEMENT_DISTANCE = ARENA.width - START_X * 2;
const LANE_INSET = 105;
const DRIFT_Y = 40;
const DRIFT_X = 22;

export const ANNOUNCE_SECONDS = 3.4;
const FIRE_TIMEOUT = 7;
const SETTLE_SECONDS = 0.7;

export function createUnit(loadout, { team, index, count }) {
  const laneSpan = ARENA.height - 2 * LANE_INSET;
  const y = count === 1
    ? ARENA.height / 2
    : LANE_INSET + (laneSpan * index) / (count - 1);
  const x = team === 0 ? START_X : ARENA.width - START_X;
  return {
    id: `${team}-${index}`,
    team,
    index,
    loadout,
    callsign: loadout.callsign,
    x, y,
    homeX: x,
    homeY: y,
    hp: UNIT_MAX_HP,
    alive: true,
    facing: team === 0 ? 0 : Math.PI,
    shieldCharge: loadout.shield.capacity,
    damageDealt: 0,
    damageTaken: 0,
    hitsTaken: 0,
    hitsLanded: 0,
    turnsTaken: 0,
  };
}

export function createMatch(teamALoadouts, teamBLoadouts) {
  const units = [
    ...teamALoadouts.map((l, i) => createUnit(l, { team: 0, index: i, count: teamALoadouts.length })),
    ...teamBLoadouts.map((l, i) => createUnit(l, { team: 1, index: i, count: teamBLoadouts.length })),
  ];
  return {
    units,
    projectiles: [],
    time: 0,
    round: 0,
    phase: 'idle',
    phaseTimer: 0,
    announcement: null,
    turnQueue: [],
    turnIndex: 0,
    roundComplete: true,
    over: false,
    winner: null,
    reason: '',
    events: [],
  };
}

/** Swap in a freshly designed loadout, keeping the unit's accrued damage. */
export function setLoadout(match, unitId, loadout) {
  const unit = match.units.find((u) => u.id === unitId);
  if (!unit) return;
  unit.loadout = loadout;
  unit.callsign = loadout.callsign;
  // A new shield arrives at full charge; its capacity may have changed.
  unit.shieldCharge = loadout.shield.capacity;
}

/**
 * Choose which unit attacks for a team this round: rotate through the living
 * units so every bot gets a turn, and the same one never monopolises the match.
 */
export function pickAttacker(match, team, round) {
  const alive = match.units.filter((u) => u.team === team && u.alive);
  if (!alive.length) return null;
  return alive[(round - 1) % alive.length];
}

export function beginRound(match, round, attackerIds) {
  match.round = round;
  match.turnQueue = attackerIds.filter(Boolean);
  match.turnIndex = 0;
  match.roundComplete = false;
  startTurn(match);
}

function currentAttacker(match) {
  const id = match.turnQueue[match.turnIndex];
  return match.units.find((u) => u.id === id) || null;
}

function startTurn(match) {
  const attacker = currentAttacker(match);
  if (!attacker) {
    finishRound(match);
    return;
  }
  if (!attacker.alive) {
    // Destroyed before it could act — skip its turn.
    match.events.push({ text: `${attacker.callsign} was destroyed before it could attack.` });
    nextTurn(match);
    return;
  }

  const weapon = attacker.loadout.weapon;
  match.announcement = {
    unitId: attacker.id,
    team: attacker.team,
    callsign: attacker.callsign,
    weaponName: weapon.name,
    equation: weapon.source.y,
    forward: weapon.source.x,
    aim: weapon.source.aim,
    aimed: weapon.aimed,
    doctrine: attacker.loadout.doctrine,
  };
  match.phase = 'announce';
  match.phaseTimer = ANNOUNCE_SECONDS;
  match.events.push({
    text: `${attacker.callsign} declares "${weapon.name}"  ·  y(t) = ${weapon.source.y}`,
    kind: 'announce',
  });
}

function nextTurn(match) {
  match.turnIndex++;
  if (match.turnIndex >= match.turnQueue.length) {
    finishRound(match);
    return;
  }
  startTurn(match);
}

function finishRound(match) {
  match.roundComplete = true;
  match.phase = 'idle';
  match.announcement = null;
}

function nearestEnemy(match, unit) {
  let best = null;
  let bestDistance = Infinity;
  for (const other of match.units) {
    if (other.team === unit.team || !other.alive) continue;
    const distance = Math.hypot(other.x - unit.x, other.y - unit.y);
    if (distance < bestDistance) {
      bestDistance = distance;
      best = other;
    }
  }
  return best;
}

/**
 * The drift velocity of a unit right now, so an agent can lead its target.
 * Analytic derivative of the drift in stepOnce — no finite differences, so the
 * number an agent is given is exactly the motion it is aiming at.
 */
export function unitVelocity(unit, time) {
  const phase = time * 0.9 + unit.index * 1.7 + unit.team * 2.3;
  return {
    vx: -Math.sin(phase * 0.6) * DRIFT_X * 0.6 * 0.9,
    vy: Math.cos(phase) * DRIFT_Y * 0.9,
  };
}

function fire(match, unit, target) {
  const weapon = unit.loadout.weapon;

  // The agent's own firing solution decides where this goes. The engine
  // supplies raw geometry and nothing else — no auto-aim.
  const velocity = unitVelocity(target, match.time);
  const angle = weapon.aim({
    sx: unit.x,
    sy: unit.y,
    tx: target.x,
    ty: target.y,
    tvx: velocity.vx,
    tvy: velocity.vy,
    speed: weapon.speed,
    range: weapon.range,
  });

  // Recorded so the log can show what the solution cost or bought them.
  const direct = Math.atan2(target.y - unit.y, target.x - unit.x);
  unit.lastAim = {
    angle,
    direct,
    offsetDegrees: (angleDelta(direct, angle) * 180) / Math.PI,
  };

  unit.facing = angle;
  unit.turnsTaken++;

  const offset = unit.lastAim.offsetDegrees;
  match.events.push({
    text: weapon.aimed
      ? `${unit.callsign} computes its firing solution: ${((angle * 180) / Math.PI).toFixed(1)}° `
        + `(${offset >= 0 ? '+' : ''}${offset.toFixed(1)}° off the direct bearing).`
      : `${unit.callsign} fires without a solution — the referee points it straight at the target.`,
    kind: weapon.aimed ? 'aim' : 'warn',
  });

  for (let i = 0; i < weapon.count; i++) {
    match.projectiles.push({
      owner: unit.id,
      team: unit.team,
      weapon,
      originX: unit.x,
      originY: unit.y,
      angle,
      index: i,
      age: 0,
      x: unit.x,
      y: unit.y,
      prevX: unit.x,
      prevY: unit.y,
      dead: false,
      hitIds: new Set(),
    });
  }
}

function projectilePosition(p) {
  const t = Math.min(p.age / p.weapon.life, 1);
  const scope = { t, i: p.index, n: p.weapon.count, d: p.weapon.range };
  const forward = p.weapon.forward(scope);
  const lateral = p.weapon.lateral(scope);
  // The launch angle is fixed at fire time by the agent's firing solution.
  // Nothing steers a shot after it leaves the barrel.
  const cos = Math.cos(p.angle);
  const sin = Math.sin(p.angle);
  return {
    x: p.originX + forward * cos - lateral * sin,
    y: p.originY + forward * sin + lateral * cos,
  };
}

function angleDelta(from, to) {
  let delta = to - from;
  while (delta > Math.PI) delta -= Math.PI * 2;
  while (delta < -Math.PI) delta += Math.PI * 2;
  return delta;
}

function segmentDistance(ax, ay, bx, by, px, py) {
  const dx = bx - ax;
  const dy = by - ay;
  const lengthSq = dx * dx + dy * dy;
  if (lengthSq < 1e-9) return Math.hypot(px - ax, py - ay);
  let u = ((px - ax) * dx + (py - ay) * dy) / lengthSq;
  u = Math.min(Math.max(u, 0), 1);
  return Math.hypot(px - (ax + dx * u), py - (ay + dy * u));
}

/**
 * Apply a hit. The shield absorbs only where it actually is: the incoming
 * bearing is converted to the shield's local angle and the polar shape decides
 * whether it covers that arc, so a lopsided shield leaves a real flank open.
 */
function applyHit(match, projectile, target, damage) {
  const shield = target.loadout.shield;
  const incoming = Math.atan2(projectile.y - target.y, projectile.x - target.x);
  const localAngle = normalizeAngle(incoming - target.facing);
  const coverRadius = shield.radiusAt(localAngle, match.time);
  const distance = Math.hypot(projectile.x - target.x, projectile.y - target.y);

  let absorbed = 0;
  const covered = distance <= coverRadius && target.shieldCharge > 0;
  if (covered) {
    absorbed = Math.min(damage * shield.absorb, target.shieldCharge);
    target.shieldCharge -= absorbed;
  }

  const through = Math.max(damage - absorbed, 0);
  target.hp = Math.max(target.hp - through, 0);
  target.damageTaken += through;
  target.hitsTaken++;

  if (target.hp <= 0 && target.alive) {
    target.alive = false;
    match.events.push({
      text: `${target.callsign} destroyed after ${target.hitsTaken} hits.`,
      kind: 'kill',
    });
  }
  return { through, absorbed, covered };
}

function normalizeAngle(a) {
  let angle = a % (Math.PI * 2);
  if (angle < 0) angle += Math.PI * 2;
  return angle;
}

function stepProjectiles(match, dt) {
  const survivors = [];
  for (const p of match.projectiles) {
    p.age += dt;
    p.prevX = p.x;
    p.prevY = p.y;

    const pos = projectilePosition(p);
    p.x = pos.x;
    p.y = pos.y;

    if (p.age >= p.weapon.life) p.dead = true;
    if (p.x < -80 || p.x > ARENA.width + 80 || p.y < -80 || p.y > ARENA.height + 80) p.dead = true;

    if (!p.dead) {
      for (const unit of match.units) {
        if (!unit.alive || unit.team === p.team || p.hitIds.has(unit.id)) continue;
        const reach = UNIT_RADIUS + p.weapon.radius;
        if (segmentDistance(p.prevX, p.prevY, p.x, p.y, unit.x, unit.y) > reach) continue;

        p.hitIds.add(unit.id);
        const result = applyHit(match, p, unit, p.weapon.damage);
        const owner = match.units.find((u) => u.id === p.owner);
        if (owner) {
          owner.damageDealt += result.through;
          owner.hitsLanded++;
        }
        if (!p.weapon.pierce) {
          p.dead = true;
          break;
        }
      }
    }

    if (!p.dead) survivors.push(p);
  }
  match.projectiles = survivors;
}

function checkElimination(match) {
  const aliveA = match.units.some((u) => u.team === 0 && u.alive);
  const aliveB = match.units.some((u) => u.team === 1 && u.alive);
  if (aliveA && aliveB) return;

  match.over = true;
  match.roundComplete = true;
  match.phase = 'idle';
  match.announcement = null;
  match.winner = aliveA && !aliveB ? 0 : !aliveA && aliveB ? 1 : null;
  match.reason = match.winner === null ? 'Mutual destruction.' : 'Enemy team eliminated.';
}

function stepOnce(match, dt) {
  match.time += dt;

  // Everyone drifts and keeps their shield up, attacker or not.
  for (const unit of match.units) {
    if (!unit.alive) continue;
    const shield = unit.loadout.shield;
    unit.shieldCharge = Math.min(unit.shieldCharge + shield.regen * dt, shield.capacity);

    const phase = match.time * 0.9 + unit.index * 1.7 + unit.team * 2.3;
    unit.y = unit.homeY + Math.sin(phase) * DRIFT_Y;
    unit.x = unit.homeX + Math.cos(phase * 0.6) * DRIFT_X;

    const target = nearestEnemy(match, unit);
    if (target) unit.facing = Math.atan2(target.y - unit.y, target.x - unit.x);
  }

  if (match.phase === 'announce') {
    match.phaseTimer -= dt;
    if (match.phaseTimer <= 0) {
      const attacker = currentAttacker(match);
      const target = attacker ? nearestEnemy(match, attacker) : null;
      if (attacker && target) fire(match, attacker, target);
      match.phase = 'fire';
      match.phaseTimer = FIRE_TIMEOUT;
      match.announcement = null;
    }
  } else if (match.phase === 'fire') {
    match.phaseTimer -= dt;
    if (match.projectiles.length === 0 || match.phaseTimer <= 0) {
      match.phase = 'settle';
      match.phaseTimer = SETTLE_SECONDS;
    }
  } else if (match.phase === 'settle') {
    match.phaseTimer -= dt;
    if (match.phaseTimer <= 0) nextTurn(match);
  }

  stepProjectiles(match, dt);
  checkElimination(match);
}

/** Advance by real elapsed time using a fixed internal timestep. */
export function advance(match, elapsed, speedMultiplier = 1) {
  if (match.over || match.roundComplete) return;
  let remaining = Math.min(elapsed, 0.25) * speedMultiplier;
  let guard = 0;
  while (remaining > 0 && !match.over && !match.roundComplete && guard++ < 900) {
    const dt = Math.min(STEP, remaining);
    stepOnce(match, dt);
    remaining -= dt;
  }
}

/** Run the current round to completion with no rendering — used by tests. */
export function runRound(match) {
  let guard = 0;
  while (!match.over && !match.roundComplete && guard++ < 60 * 120) {
    stepOnce(match, STEP);
  }
  return match;
}

/** Decide a match that ran out of rounds without an elimination. */
export function decideOnPoints(match) {
  if (match.over) return match;
  const hp = [0, 1].map((team) => match.units
    .filter((u) => u.team === team)
    .reduce((sum, u) => sum + u.hp, 0));
  match.over = true;
  match.winner = hp[0] === hp[1] ? null : hp[0] > hp[1] ? 0 : 1;
  match.reason = `Rounds exhausted — ${hp[0].toFixed(0)} HP vs ${hp[1].toFixed(0)} HP remaining.`;
  return match;
}

/**
 * Post-round intel for the other team's agents. Includes the shield sampled
 * around its own arc, so an agent can actually locate the gap it should be
 * curving into rather than guessing from the raw expression.
 */
export function collectIntel(match, team) {
  return match.units
    .filter((u) => u.team === team)
    .map((u) => {
      const shield = u.loadout.shield;
      const profile = [];
      for (let s = 0; s < 8; s++) {
        const angle = (s / 8) * Math.PI * 2;
        profile.push({
          degrees: Math.round((angle * 180) / Math.PI),
          radius: Math.round(shield.radiusAt(angle, match.time)),
        });
      }
      return {
        callsign: u.callsign,
        alive: u.alive,
        hp: u.hp,
        weapon: u.loadout.weapon.name,
        damage: u.loadout.weapon.damage,
        count: u.loadout.weapon.count,
        pathY: u.loadout.weapon.source.y,
        shield: shield.name,
        shieldShape: shield.source,
        absorb: shield.absorb,
        shieldCharge: u.shieldCharge,
        shieldProfile: profile,
        dealt: u.damageDealt,
        hitsLanded: u.hitsLanded,
      };
    });
}

export { UNIT_RADIUS };
