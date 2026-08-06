/*
 * sim.js — the arena itself. Fixed-timestep combat over compiled loadouts.
 *
 * Units strafe, pick targets, and fire volleys whose projectiles follow their
 * weapon's math path in the aiming frame captured at launch. Damage is routed
 * through the target's polar shield before it reaches HP.
 */

import { UNIT_MAX_HP } from './rules.js';

export const ARENA = { width: 960, height: 540 };
const UNIT_RADIUS = 13;
// Front lines sit ~460px apart, comfortably inside the legal range band so a
// mid-range weapon can reach without a max-range build being mandatory.
const START_X = 250;
export const ENGAGEMENT_DISTANCE = ARENA.width - START_X * 2;
const LANE_INSET = 105;
const DRIFT_Y = 40;
const DRIFT_X = 22;
const STEP = 1 / 60;
const MAX_ROUND_SECONDS = 45;

export function createUnit(loadout, { team, index, count }) {
  // Lanes are inset far enough that the drift below never pushes a unit's
  // label off the arena floor.
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
    x,
    y,
    homeX: x,
    homeY: y,
    hp: UNIT_MAX_HP,
    alive: true,
    facing: team === 0 ? 0 : Math.PI,
    cooldown: 0.4 + index * 0.18,
    shieldCharge: loadout.shield.capacity,
    damageDealt: 0,
    damageTaken: 0,
    hitsTaken: 0,
    hitsLanded: 0,
    volleys: 0,
  };
}

export function createBattle(teamALoadouts, teamBLoadouts) {
  const units = [
    ...teamALoadouts.map((l, i) => createUnit(l, { team: 0, index: i, count: teamALoadouts.length })),
    ...teamBLoadouts.map((l, i) => createUnit(l, { team: 1, index: i, count: teamBLoadouts.length })),
  ];
  return {
    units,
    projectiles: [],
    time: 0,
    over: false,
    winner: null,
    reason: '',
    events: [],
  };
}

function nearestEnemy(battle, unit) {
  let best = null;
  let bestDistance = Infinity;
  for (const other of battle.units) {
    if (other.team === unit.team || !other.alive) continue;
    const distance = Math.hypot(other.x - unit.x, other.y - unit.y);
    if (distance < bestDistance) {
      bestDistance = distance;
      best = other;
    }
  }
  return best;
}

function fire(battle, unit, target) {
  const weapon = unit.loadout.weapon;
  const angle = Math.atan2(target.y - unit.y, target.x - unit.x);
  unit.facing = angle;
  unit.volleys++;

  for (let i = 0; i < weapon.count; i++) {
    battle.projectiles.push({
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

/** Evaluate a projectile's world position from its path expressions. */
function projectilePosition(p, targetAngle) {
  const t = Math.min(p.age / p.weapon.life, 1);
  const scope = { t, i: p.index, n: p.weapon.count, d: p.weapon.range };
  const forward = p.weapon.forward(scope);
  const lateral = p.weapon.lateral(scope);
  // Homing rotates the whole aiming frame toward the current target bearing.
  const angle = targetAngle == null
    ? p.angle
    : p.angle + angleDelta(p.angle, targetAngle) * p.weapon.homing * t;
  const cos = Math.cos(angle);
  const sin = Math.sin(angle);
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

/** Shortest distance from point p to segment ab — projectiles move fast. */
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
 * Apply a hit. The shield eats `absorb` of the damage while it has charge,
 * but only where the shield actually is: the incoming bearing is converted to
 * the shield's local angle and the polar shape decides whether it covers that
 * arc. A lopsided shield really does leave a flank exposed.
 */
function applyHit(battle, projectile, target, damage) {
  const shield = target.loadout.shield;
  const incoming = Math.atan2(projectile.y - target.y, projectile.x - target.x);
  const localAngle = normalizeAngle(incoming - target.facing);
  const coverRadius = shield.radiusAt(localAngle, battle.time);
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
    battle.events.push({
      time: battle.time,
      text: `${target.callsign} destroyed after ${target.hitsTaken} hits.`,
    });
  }
  return { through, absorbed, covered };
}

function normalizeAngle(a) {
  let angle = a % (Math.PI * 2);
  if (angle < 0) angle += Math.PI * 2;
  return angle;
}

function stepOnce(battle, dt) {
  battle.time += dt;

  for (const unit of battle.units) {
    if (!unit.alive) continue;

    // Shield regen.
    const shield = unit.loadout.shield;
    unit.shieldCharge = Math.min(unit.shieldCharge + shield.regen * dt, shield.capacity);

    const target = nearestEnemy(battle, unit);
    if (!target) continue;

    // Units drift on a slow sinusoid — enough motion that a fixed curve
    // cannot be trivially pre-aimed, without turning this into a dodging game.
    const phase = battle.time * 0.9 + unit.index * 1.7 + unit.team * 2.3;
    unit.y = unit.homeY + Math.sin(phase) * DRIFT_Y;
    unit.x = unit.homeX + Math.cos(phase * 0.6) * DRIFT_X;
    unit.facing = Math.atan2(target.y - unit.y, target.x - unit.x);

    unit.cooldown -= dt;
    if (unit.cooldown <= 0) {
      unit.cooldown = unit.loadout.weapon.cooldown;
      fire(battle, unit, target);
    }
  }

  const survivors = [];
  for (const p of battle.projectiles) {
    p.age += dt;
    p.prevX = p.x;
    p.prevY = p.y;

    let homingAngle = null;
    if (p.weapon.homing > 0) {
      const owner = battle.units.find((u) => u.id === p.owner);
      const target = owner ? nearestEnemy(battle, owner) : null;
      if (target) homingAngle = Math.atan2(target.y - p.originY, target.x - p.originX);
    }
    const pos = projectilePosition(p, homingAngle);
    p.x = pos.x;
    p.y = pos.y;

    if (p.age >= p.weapon.life) p.dead = true;
    if (p.x < -80 || p.x > ARENA.width + 80 || p.y < -80 || p.y > ARENA.height + 80) p.dead = true;

    if (!p.dead) {
      for (const unit of battle.units) {
        if (!unit.alive || unit.team === p.team || p.hitIds.has(unit.id)) continue;
        const reach = UNIT_RADIUS + p.weapon.radius;
        if (segmentDistance(p.prevX, p.prevY, p.x, p.y, unit.x, unit.y) > reach) continue;

        p.hitIds.add(unit.id);
        const result = applyHit(battle, p, unit, p.weapon.damage);
        const owner = battle.units.find((u) => u.id === p.owner);
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
  battle.projectiles = survivors;

  const aliveA = battle.units.some((u) => u.team === 0 && u.alive);
  const aliveB = battle.units.some((u) => u.team === 1 && u.alive);

  if (!aliveA || !aliveB) {
    battle.over = true;
    battle.winner = aliveA && !aliveB ? 0 : !aliveA && aliveB ? 1 : null;
    battle.reason = battle.winner === null ? 'Mutual destruction.' : 'Enemy team eliminated.';
  } else if (battle.time >= MAX_ROUND_SECONDS) {
    battle.over = true;
    const hpA = battle.units.filter((u) => u.team === 0).reduce((s, u) => s + u.hp, 0);
    const hpB = battle.units.filter((u) => u.team === 1).reduce((s, u) => s + u.hp, 0);
    battle.winner = hpA === hpB ? null : hpA > hpB ? 0 : 1;
    battle.reason = `Time limit — ${hpA.toFixed(0)} HP vs ${hpB.toFixed(0)} HP remaining.`;
  }
}

/** Advance the battle by real elapsed time using a fixed internal timestep. */
export function advance(battle, elapsed, speedMultiplier = 1) {
  if (battle.over) return;
  let remaining = Math.min(elapsed, 0.25) * speedMultiplier;
  let guard = 0;
  while (remaining > 0 && !battle.over && guard++ < 600) {
    const dt = Math.min(STEP, remaining);
    stepOnce(battle, dt);
    remaining -= dt;
  }
}

/** Run a battle to completion with no rendering — used for instant results. */
export function runToCompletion(battle) {
  let guard = 0;
  while (!battle.over && guard++ < MAX_ROUND_SECONDS / STEP + 10) {
    stepOnce(battle, STEP);
  }
  return battle;
}

/** Post-round intel handed to the other team's agents next round. */
export function collectIntel(battle, team) {
  return battle.units
    .filter((u) => u.team === team)
    .map((u) => ({
      callsign: u.callsign,
      weapon: u.loadout.weapon.name,
      damage: u.loadout.weapon.damage,
      count: u.loadout.weapon.count,
      pathY: u.loadout.weapon.source.y,
      shield: u.loadout.shield.name,
      shieldShape: u.loadout.shield.source,
      absorb: u.loadout.shield.absorb,
      dealt: u.damageDealt,
      alive: u.alive,
    }));
}

export { UNIT_RADIUS, MAX_ROUND_SECONDS };
