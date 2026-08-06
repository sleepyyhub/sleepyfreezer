/*
 * rules.js — turns raw agent JSON into a legal, compiled loadout.
 *
 * The arena has three hard rules. Agents are told about them in the prompt,
 * but the prompt is not the enforcement — this file is. Anything an agent
 * sends is clamped, repaired or rejected here before it can touch the sim.
 *
 *   RULE 1  No one-shot kills. A unit must survive at least two hits, so
 *           per-hit damage is capped at MAX_DAMAGE_FRACTION of max HP.
 *   RULE 2  Every projectile must fly a curved path. A trajectory that is
 *           straight (or as good as) gets an arc injected.
 *   RULE 3  Only the math mini-language. No code, no unknown identifiers.
 */

import { compileExpression, MathLangError } from './mathlang.js';

export const UNIT_MAX_HP = 100;

// A hit may take at most 45% of max HP: two hits leave 10% and the unit
// lives, so every unit withstands two attacks. The third can finish it.
export const MAX_DAMAGE_FRACTION = 0.45;
export const MAX_DAMAGE = UNIT_MAX_HP * MAX_DAMAGE_FRACTION;

// Minimum perpendicular deviation, in pixels, from the straight line between
// a projectile's launch point and its end point. Below this it is a bullet,
// not a curve, and RULE 2 rewrites it.
export const MIN_CURVE_DEVIATION = 14;

export const PATH_VARS = ['t', 'i', 'n', 'd'];
export const SHIELD_VARS = ['a', 't'];

const clamp = (x, lo, hi) => Math.min(Math.max(x, lo), hi);

function num(value, fallback, lo, hi) {
  const n = typeof value === 'number' ? value : parseFloat(value);
  if (!Number.isFinite(n)) return fallback;
  return clamp(n, lo, hi);
}

function text(value, fallback, maxLength = 42) {
  if (typeof value !== 'string') return fallback;
  const cleaned = value.replace(/[\r\n\t]+/g, ' ').trim().slice(0, maxLength);
  return cleaned || fallback;
}

/**
 * Sample the local-frame path and measure how far it strays from the straight
 * line joining its first and last sample. Returns pixels of deviation.
 */
export function measureCurvature(pathX, pathY, scope = {}) {
  const SAMPLES = 24;
  const pts = [];
  for (let s = 0; s <= SAMPLES; s++) {
    const t = s / SAMPLES;
    const local = { ...scope, t };
    pts.push([pathX(local), pathY(local)]);
  }
  const [x0, y0] = pts[0];
  const [x1, y1] = pts[pts.length - 1];
  const dx = x1 - x0;
  const dy = y1 - y0;
  const len = Math.hypot(dx, dy);
  if (len < 1e-6) {
    // Degenerate: start and end coincide. Measure spread from the start point.
    return pts.reduce((m, [x, y]) => Math.max(m, Math.hypot(x - x0, y - y0)), 0);
  }
  let worst = 0;
  for (const [x, y] of pts) {
    const perpendicular = Math.abs((x - x0) * dy - (y - y0) * dx) / len;
    if (perpendicular > worst) worst = perpendicular;
  }
  return worst;
}

/**
 * RULE 2 fallback: a sine-arc lateral offset, scaled to the shot's range and
 * fanned per projectile index so multi-shot weapons braid instead of overlap.
 */
function arcFallback(range) {
  const amplitude = Math.max(MIN_CURVE_DEVIATION * 2.2, range * 0.22);
  return `sin(t * pi) * ${amplitude.toFixed(1)} * (1 + i * 0.35) * (1 - 2 * mod(i, 2))`;
}

function compileOrThrow(source, vars, label) {
  try {
    return compileExpression(source, { allowedVars: vars });
  } catch (error) {
    const reason = error instanceof MathLangError ? error.message : 'invalid expression';
    throw new MathLangError(`${label}: ${reason}`);
  }
}

/**
 * Validate + compile a weapon spec.
 * Returns { weapon, notes } where notes records every correction we applied,
 * so the UI can show what the referee changed and why.
 */
export function buildWeapon(raw, notes = []) {
  const spec = raw && typeof raw === 'object' ? raw : {};
  const name = text(spec.name, 'Unnamed Ordnance');

  const range = num(spec.range, 340, 140, 620);
  const speed = num(spec.speed, 260, 90, 520);
  const count = Math.round(num(spec.count, 1, 1, 5));
  const cooldown = num(spec.cooldown, 1.1, 0.35, 4);
  const radius = num(spec.radius, 5, 2.5, 12);

  let damage = num(spec.damage, 18, 1, 999);
  if (damage > MAX_DAMAGE) {
    notes.push(
      `RULE 1 — "${name}" asked for ${damage.toFixed(0)} damage; capped to ${MAX_DAMAGE} so no unit dies in one hit.`,
    );
    damage = MAX_DAMAGE;
  }

  const path = spec.path && typeof spec.path === 'object' ? spec.path : {};

  // Forward progress along the aim axis. Defaults to a straight sweep to the
  // full range; agents may reshape it (easing, stalls, boomerangs).
  let forward;
  try {
    forward = compileOrThrow(path.x ?? `t * ${range}`, PATH_VARS, 'path.x');
  } catch (error) {
    notes.push(`${error.message} — fell back to linear forward travel.`);
    forward = compileExpression(`t * ${range}`, { allowedVars: PATH_VARS });
  }

  // Lateral offset — this is the curve.
  let lateral;
  try {
    lateral = compileOrThrow(path.y ?? arcFallback(range), PATH_VARS, 'path.y');
  } catch (error) {
    notes.push(`${error.message} — replaced with the referee's default arc.`);
    lateral = compileExpression(arcFallback(range), { allowedVars: PATH_VARS });
  }

  // RULE 2: check the shape actually bends. Test every projectile index,
  // because a fan can be straight down the middle and curved on the wings.
  let bestDeviation = 0;
  for (let i = 0; i < count; i++) {
    const deviation = measureCurvature(forward, lateral, { i, n: count, d: range });
    if (deviation > bestDeviation) bestDeviation = deviation;
  }
  if (bestDeviation < MIN_CURVE_DEVIATION) {
    notes.push(
      `RULE 2 — "${name}" flew straight (${bestDeviation.toFixed(1)}px of bend, ` +
      `${MIN_CURVE_DEVIATION}px required); the referee bent it into an arc.`,
    );
    lateral = compileExpression(arcFallback(range), { allowedVars: PATH_VARS });
    bestDeviation = measureCurvature(forward, lateral, { i: 0, n: count, d: range });
  }

  const life = clamp(range / Math.max(speed, 1), 0.35, 4.5);

  return {
    weapon: {
      name,
      damage,
      count,
      cooldown,
      radius,
      range,
      speed,
      life,
      forward,
      lateral,
      curvature: bestDeviation,
      homing: clamp(num(spec.homing, 0, 0, 1), 0, 0.65),
      pierce: spec.pierce === true,
      source: {
        x: forward.source,
        y: lateral.source,
      },
    },
    notes,
  };
}

/**
 * Validate + compile a shield spec. The shield is a polar curve r(a, t):
 * agents get complete control of its shape, which is what makes shields
 * interesting — a lopsided shield genuinely leaves a flank open.
 */
export function buildShield(raw, notes = []) {
  const spec = raw && typeof raw === 'object' ? raw : {};
  const name = text(spec.name, 'Bare Plating');

  const capacity = num(spec.capacity, 40, 0, 90);
  const regen = num(spec.regen, 4, 0, 14);
  const absorb = num(spec.absorb, 0.5, 0, 0.85);

  let shape;
  try {
    shape = compileOrThrow(spec.shape ?? '26 + 8 * cos(a * 2)', SHIELD_VARS, 'shield.shape');
  } catch (error) {
    notes.push(`${error.message} — fell back to a plain elliptical shield.`);
    shape = compileExpression('26 + 8 * cos(a * 2)', { allowedVars: SHIELD_VARS });
  }

  // Keep the shape physically sane: sample it and rescale if the agent tried
  // to wrap the whole arena in armour.
  const SAMPLES = 48;
  let maxRadius = 0;
  for (let s = 0; s < SAMPLES; s++) {
    const a = (s / SAMPLES) * Math.PI * 2;
    maxRadius = Math.max(maxRadius, Math.abs(shape({ a, t: 0 })));
  }
  const SHIELD_RADIUS_LIMIT = 58;
  const scale = maxRadius > SHIELD_RADIUS_LIMIT ? SHIELD_RADIUS_LIMIT / maxRadius : 1;
  if (scale < 1) {
    notes.push(
      `"${name}" was ${maxRadius.toFixed(0)}px across; scaled to the ${SHIELD_RADIUS_LIMIT}px arena limit.`,
    );
  }

  return {
    shield: {
      name,
      capacity,
      charge: capacity,
      regen,
      absorb,
      shape,
      scale,
      radiusAt(angle, time) {
        const r = Math.abs(shape({ a: angle, t: time })) * scale;
        return clamp(r, 12, SHIELD_RADIUS_LIMIT);
      },
      source: shape.source,
    },
    notes,
  };
}

/** Build a whole loadout, collecting referee notes across both halves. */
export function buildLoadout(raw) {
  const notes = [];
  const spec = raw && typeof raw === 'object' ? raw : {};
  const { weapon } = buildWeapon(spec.weapon, notes);
  const { shield } = buildShield(spec.shield, notes);
  return {
    callsign: text(spec.callsign, 'Unit', 24),
    doctrine: text(spec.doctrine, 'No doctrine supplied.', 160),
    weapon,
    shield,
    notes,
  };
}
