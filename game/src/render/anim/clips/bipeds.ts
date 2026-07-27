import type { Clip, Track } from '../types';

const k = (t: number, pose: Track[number]['pose']): Track[number] => ({ t, pose });

/**
 * Golem clips. Everything about this set is about weight: long ground-contact
 * times, a hard settle after each step, arms that lag behind the torso, and
 * no airborne phase ever. A heavy character that moves on the same timing
 * curve as a light one just reads as a light one wearing rocks.
 */

export const GOLEM_IDLE: Clip = {
  name: 'idle',
  duration: 5.0,
  loop: true,
  tracks: {
    hips: [k(0, { py: 0, rz: 0.02 }), k(0.5, { py: -0.025, rz: -0.02 }), k(1, { py: 0, rz: 0.02 })],
    spine: [k(0, { rx: 0.08 }), k(0.5, { rx: 0.12 }), k(1, { rx: 0.08 })],
    chest: [k(0, { rx: 0.02, ry: 0.03 }), k(0.5, { rx: -0.03, ry: -0.03 }), k(1, { rx: 0.02, ry: 0.03 })],
    neck: [k(0, { rx: 0.12 }), k(0.5, { rx: 0.16 }), k(1, { rx: 0.12 })],
    head: [k(0, { ry: 0.06, rx: 0.05 }), k(0.35, { ry: -0.08, rx: 0.08 }), k(1, { ry: 0.06, rx: 0.05 })],
    // Arms hang heavy and swing minimally — mass resists motion.
    armL: [k(0, { rx: 0.06, rz: -0.3 }), k(0.5, { rx: -0.02, rz: -0.34 }), k(1, { rx: 0.06, rz: -0.3 })],
    armR: [k(0, { rx: -0.02, rz: 0.34 }), k(0.5, { rx: 0.06, rz: 0.3 }), k(1, { rx: -0.02, rz: 0.34 })],
    forearmL: [k(0, { rx: -0.32, rz: -0.1 }), k(0.5, { rx: -0.4 }), k(1, { rx: -0.32, rz: -0.1 })],
    forearmR: [k(0, { rx: -0.4 }), k(0.5, { rx: -0.32, rz: 0.1 }), k(1, { rx: -0.4 })],
    thighL: [k(0, { rz: -0.09 }), k(1, { rz: -0.09 })],
    thighR: [k(0, { rz: 0.09 }), k(1, { rz: 0.09 })],
    shinL: [k(0, { rx: -0.06 }), k(0.5, { rx: -0.09 }), k(1, { rx: -0.06 })],
    shinR: [k(0, { rx: -0.09 }), k(0.5, { rx: -0.06 }), k(1, { rx: -0.09 })],
  },
};

/** Lumbering stomp. Long stance, brief swing, hard landing compression. */
export const GOLEM_WALK: Clip = {
  name: 'walk',
  duration: 1.55,
  loop: true,
  tracks: {
    hips: [
      k(0, { py: 0.01, rz: -0.07, ry: 0.06 }),
      k(0.1, { py: -0.07 }), // landing compression
      k(0.25, { py: 0.02 }),
      k(0.5, { py: 0.01, rz: 0.07, ry: -0.06 }),
      k(0.6, { py: -0.07 }),
      k(0.75, { py: 0.02 }),
      k(1, { py: 0.01, rz: -0.07, ry: 0.06 }),
    ],
    spine: [k(0, { rx: 0.14, ry: -0.05 }), k(0.5, { rx: 0.14, ry: 0.05 }), k(1, { rx: 0.14, ry: -0.05 })],
    chest: [k(0, { ry: -0.09, rx: 0.03 }), k(0.5, { ry: 0.09, rx: 0.03 }), k(1, { ry: -0.09, rx: 0.03 })],
    neck: [k(0, { rx: 0.1 }), k(0.1, { rx: 0.18 }), k(0.6, { rx: 0.18 }), k(1, { rx: 0.1 })],
    head: [k(0, { rx: 0.04, ry: 0.06 }), k(0.5, { rx: 0.04, ry: -0.06 }), k(1, { rx: 0.04, ry: 0.06 })],

    // Arms swing late, so they trail the torso by roughly an eighth of a cycle.
    armL: [k(0, { rx: -0.3, rz: -0.28 }), k(0.62, { rx: 0.26, rz: -0.32 }), k(1, { rx: -0.3, rz: -0.28 })],
    armR: [k(0, { rx: 0.26, rz: 0.32 }), k(0.62, { rx: -0.3, rz: 0.28 }), k(1, { rx: 0.26, rz: 0.32 })],
    forearmL: [k(0, { rx: -0.28 }), k(0.62, { rx: -0.5 }), k(1, { rx: -0.28 })],
    forearmR: [k(0, { rx: -0.5 }), k(0.62, { rx: -0.28 }), k(1, { rx: -0.5 })],

    thighL: [k(0, { rx: 0.4, rz: -0.09 }), k(0.3, { rx: 0.1 }), k(0.5, { rx: -0.3 }), k(0.82, { rx: 0.28 }), k(1, { rx: 0.4, rz: -0.09 })],
    shinL: [k(0, { rx: -0.12 }), k(0.1, { rx: -0.3 }), k(0.5, { rx: -0.1 }), k(0.72, { rx: -0.85 }), k(0.9, { rx: -0.3 }), k(1, { rx: -0.12 })],
    footL: [k(0, { rx: -0.16 }), k(0.12, { rx: 0.08 }), k(0.5, { rx: 0.05 }), k(0.6, { rx: -0.3 }), k(1, { rx: -0.16 })],
    thighR: [k(0, { rx: -0.3, rz: 0.09 }), k(0.32, { rx: 0.28 }), k(0.5, { rx: 0.4 }), k(0.8, { rx: 0.1 }), k(1, { rx: -0.3, rz: 0.09 })],
    shinR: [k(0, { rx: -0.1 }), k(0.22, { rx: -0.85 }), k(0.4, { rx: -0.3 }), k(0.5, { rx: -0.12 }), k(0.6, { rx: -0.3 }), k(1, { rx: -0.1 })],
    footR: [k(0, { rx: 0.05 }), k(0.1, { rx: -0.3 }), k(0.5, { rx: -0.16 }), k(0.62, { rx: 0.08 }), k(1, { rx: 0.05 })],
  },
};

/** Golems don't run; they lean in and stomp faster. Same shape, more urgency. */
export const GOLEM_RUN: Clip = {
  ...GOLEM_WALK,
  name: 'run',
  duration: 1.0,
};

/**
 * Slam: a very long overhead wind-up (matching the 1.2s telegraph), then both
 * fists into the ground. The hold at the top is what makes the telegraph
 * legible without needing the ground decal.
 */
export const GOLEM_SLAM: Clip = {
  name: 'slam',
  duration: 2.3,
  loop: false,
  tracks: {
    hips: [k(0, { py: 0 }), k(0.3, { py: 0.06 }), k(0.5, { py: 0.08 }), k(0.58, { py: -0.22 }), k(0.7, { py: -0.16 }), k(1, { py: 0 })],
    spine: [k(0, { rx: 0.14 }), k(0.3, { rx: -0.4 }), k(0.5, { rx: -0.45 }), k(0.58, { rx: 0.7 }), k(0.72, { rx: 0.6 }), k(1, { rx: 0.14 })],
    chest: [k(0, { rx: 0.03 }), k(0.4, { rx: -0.3 }), k(0.58, { rx: 0.45 }), k(1, { rx: 0.03 })],
    neck: [k(0, { rx: 0.12 }), k(0.4, { rx: -0.35 }), k(0.58, { rx: 0.5 }), k(1, { rx: 0.12 })],
    head: [k(0, { rx: 0.04 }), k(0.4, { rx: -0.25 }), k(0.58, { rx: 0.4 }), k(1, { rx: 0.04 })],

    armL: [k(0, { rx: -0.3, rz: -0.28 }), k(0.32, { rx: -2.6, rz: -0.5 }), k(0.5, { rx: -2.75, rz: -0.45 }), k(0.58, { rx: 0.5, rz: -0.18 }), k(0.72, { rx: 0.42 }), k(1, { rx: 0.06, rz: -0.3 })],
    armR: [k(0, { rx: -0.3, rz: 0.28 }), k(0.32, { rx: -2.6, rz: 0.5 }), k(0.5, { rx: -2.75, rz: 0.45 }), k(0.58, { rx: 0.5, rz: 0.18 }), k(0.72, { rx: 0.42 }), k(1, { rx: 0.06, rz: 0.3 })],
    forearmL: [k(0, { rx: -0.32 }), k(0.35, { rx: -0.7 }), k(0.58, { rx: -0.05 }), k(1, { rx: -0.32 })],
    forearmR: [k(0, { rx: -0.32 }), k(0.35, { rx: -0.7 }), k(0.58, { rx: -0.05 }), k(1, { rx: -0.32 })],
    handL: [k(0, { rx: 0 }), k(0.35, { rx: -0.4 }), k(0.58, { rx: 0.5 }), k(1, { rx: 0 })],
    handR: [k(0, { rx: 0 }), k(0.35, { rx: -0.4 }), k(0.58, { rx: 0.5 }), k(1, { rx: 0 })],

    // Drops into a deep brace on impact.
    thighL: [k(0, { rx: 0, rz: -0.09 }), k(0.35, { rx: -0.15 }), k(0.58, { rx: 0.55, rz: -0.22 }), k(0.75, { rx: 0.45 }), k(1, { rx: 0, rz: -0.09 })],
    thighR: [k(0, { rx: 0, rz: 0.09 }), k(0.35, { rx: -0.15 }), k(0.58, { rx: 0.55, rz: 0.22 }), k(0.75, { rx: 0.45 }), k(1, { rx: 0, rz: 0.09 })],
    shinL: [k(0, { rx: -0.06 }), k(0.58, { rx: -0.95 }), k(0.75, { rx: -0.8 }), k(1, { rx: -0.06 })],
    shinR: [k(0, { rx: -0.06 }), k(0.58, { rx: -0.95 }), k(0.75, { rx: -0.8 }), k(1, { rx: -0.06 })],
    footL: [k(0, { rx: 0 }), k(0.58, { rx: 0.4 }), k(1, { rx: 0 })],
    footR: [k(0, { rx: 0 }), k(0.58, { rx: 0.4 }), k(1, { rx: 0 })],
  },
};

/** Horizontal sweep — one arm, faster wind-up than the slam. */
export const GOLEM_SWEEP: Clip = {
  name: 'sweep',
  duration: 1.8,
  loop: false,
  tracks: {
    hips: [k(0, { ry: 0 }), k(0.42, { ry: 0.55 }), k(0.6, { ry: -0.65 }), k(1, { ry: 0 })],
    spine: [k(0, { ry: 0, rx: 0.14 }), k(0.42, { ry: 0.6, rx: 0.05 }), k(0.6, { ry: -0.7, rx: 0.25 }), k(1, { ry: 0, rx: 0.14 })],
    chest: [k(0, { ry: 0 }), k(0.42, { ry: 0.5 }), k(0.6, { ry: -0.6 }), k(1, { ry: 0 })],
    head: [k(0, { ry: 0 }), k(0.42, { ry: -0.3 }), k(0.6, { ry: 0.35 }), k(1, { ry: 0 })],

    armR: [k(0, { rx: -0.3, rz: 0.28 }), k(0.42, { rx: -0.6, rz: 1.5 }), k(0.6, { rx: -0.5, rz: -0.3 }), k(0.75, { rx: -0.3, rz: -0.1 }), k(1, { rx: 0.06, rz: 0.3 })],
    forearmR: [k(0, { rx: -0.32 }), k(0.42, { rx: -0.5 }), k(0.6, { rx: -0.15 }), k(1, { rx: -0.32 })],
    armL: [k(0, { rx: -0.3, rz: -0.28 }), k(0.42, { rx: -0.2, rz: -0.75 }), k(0.6, { rx: -0.6, rz: -0.9 }), k(1, { rx: 0.06, rz: -0.3 })],
    forearmL: [k(0, { rx: -0.32 }), k(0.5, { rx: -0.8 }), k(1, { rx: -0.32 })],

    thighL: [k(0, { rx: 0, rz: -0.09 }), k(0.42, { rx: 0.2 }), k(0.6, { rx: -0.25 }), k(1, { rx: 0, rz: -0.09 })],
    thighR: [k(0, { rx: 0, rz: 0.09 }), k(0.42, { rx: -0.25 }), k(0.6, { rx: 0.3 }), k(1, { rx: 0, rz: 0.09 })],
    shinL: [k(0, { rx: -0.06 }), k(0.5, { rx: -0.35 }), k(1, { rx: -0.06 })],
    shinR: [k(0, { rx: -0.06 }), k(0.5, { rx: -0.35 }), k(1, { rx: -0.06 })],
  },
};

export const GOLEM_HURT: Clip = {
  name: 'hurt',
  duration: 0.42,
  loop: false,
  tracks: {
    hips: [k(0, { py: 0 }), k(0.22, { py: -0.06, pz: -0.05 }), k(1, { py: 0 })],
    spine: [k(0, { rx: 0.14 }), k(0.2, { rx: -0.18, rz: 0.14 }), k(1, { rx: 0.14 })],
    chest: [k(0, { rx: 0.03 }), k(0.2, { rx: -0.15, ry: 0.16 }), k(1, { rx: 0.03 })],
    head: [k(0, { rx: 0.04 }), k(0.18, { rx: -0.3, rz: 0.2 }), k(1, { rx: 0.04 })],
    armL: [k(0, { rx: 0.06, rz: -0.3 }), k(0.22, { rx: -0.35, rz: -0.55 }), k(1, { rx: 0.06, rz: -0.3 })],
    armR: [k(0, { rx: -0.02, rz: 0.34 }), k(0.22, { rx: -0.25, rz: 0.5 }), k(1, { rx: -0.02, rz: 0.34 })],
    shinL: [k(0, { rx: -0.06 }), k(0.22, { rx: -0.3 }), k(1, { rx: -0.06 })],
    shinR: [k(0, { rx: -0.06 }), k(0.22, { rx: -0.25 }), k(1, { rx: -0.06 })],
  },
};

/** Staggered: down on one knee, arm braced against the ground. */
export const GOLEM_STAGGER: Clip = {
  name: 'stagger',
  duration: 0.7,
  loop: true,
  tracks: {
    hips: [k(0, { py: -0.24, rz: 0.1 }), k(0.5, { py: -0.28, rz: -0.06 }), k(1, { py: -0.24, rz: 0.1 })],
    spine: [k(0, { rx: 0.5, ry: 0.1 }), k(0.5, { rx: 0.56, ry: -0.08 }), k(1, { rx: 0.5, ry: 0.1 })],
    chest: [k(0, { rx: 0.2 }), k(0.5, { rx: 0.26 }), k(1, { rx: 0.2 })],
    neck: [k(0, { rx: 0.3 }), k(1, { rx: 0.3 })],
    head: [k(0, { rx: 0.25, ry: 0.1 }), k(0.5, { rx: 0.3, ry: -0.1 }), k(1, { rx: 0.25, ry: 0.1 })],
    armL: [k(0, { rx: 0.75, rz: -0.2 }), k(0.5, { rx: 0.8, rz: -0.24 }), k(1, { rx: 0.75, rz: -0.2 })],
    armR: [k(0, { rx: 0.3, rz: 0.45 }), k(0.5, { rx: 0.36, rz: 0.4 }), k(1, { rx: 0.3, rz: 0.45 })],
    forearmL: [k(0, { rx: -0.35 }), k(1, { rx: -0.35 })],
    forearmR: [k(0, { rx: -0.6 }), k(1, { rx: -0.6 })],
    thighL: [k(0, { rx: 0.95, rz: -0.15 }), k(1, { rx: 0.95, rz: -0.15 })],
    shinL: [k(0, { rx: -1.7 }), k(1, { rx: -1.7 })],
    thighR: [k(0, { rx: 0.2, rz: 0.15 }), k(1, { rx: 0.2, rz: 0.15 })],
    shinR: [k(0, { rx: -0.45 }), k(1, { rx: -0.45 })],
  },
};

/** Death: buckles, then topples forward. Slow, because it weighs a tonne. */
export const GOLEM_DEATH: Clip = {
  name: 'death',
  duration: 1.5,
  loop: false,
  tracks: {
    root: [k(0, { rx: 0 }), k(0.5, { rx: 0.15 }), k(1, { rx: 1.5, py: -0.25 })],
    hips: [k(0, { py: 0 }), k(0.35, { py: -0.4 }), k(1, { py: -0.6 })],
    spine: [k(0, { rx: 0.14 }), k(0.3, { rx: -0.25 }), k(1, { rx: 0.55 })],
    chest: [k(0, { rx: 0.03 }), k(1, { rx: 0.3 })],
    neck: [k(0, { rx: 0.12 }), k(0.3, { rx: -0.3 }), k(1, { rx: 0.55 })],
    head: [k(0, { rx: 0.04 }), k(1, { rx: 0.4, rz: 0.2 })],
    armL: [k(0, { rx: 0.06, rz: -0.3 }), k(0.4, { rx: -0.5, rz: -0.8 }), k(1, { rx: 0.5, rz: -0.9 })],
    armR: [k(0, { rx: -0.02, rz: 0.34 }), k(0.4, { rx: -0.4, rz: 0.75 }), k(1, { rx: 0.45, rz: 0.85 })],
    forearmL: [k(0, { rx: -0.32 }), k(1, { rx: -0.15 })],
    forearmR: [k(0, { rx: -0.32 }), k(1, { rx: -0.2 })],
    thighL: [k(0, { rx: 0 }), k(0.4, { rx: 1.0 }), k(1, { rx: 1.3 })],
    thighR: [k(0, { rx: 0 }), k(0.4, { rx: 0.85 }), k(1, { rx: 1.1 })],
    shinL: [k(0, { rx: -0.06 }), k(0.4, { rx: -1.7 }), k(1, { rx: -1.9 })],
    shinR: [k(0, { rx: -0.06 }), k(0.4, { rx: -1.5 }), k(1, { rx: -1.75 })],
  },
};

export const GOLEM_CLIPS = {
  idle: GOLEM_IDLE,
  walk: GOLEM_WALK,
  run: GOLEM_RUN,
  slam: GOLEM_SLAM,
  sweep: GOLEM_SWEEP,
  hurt: GOLEM_HURT,
  stagger: GOLEM_STAGGER,
  death: GOLEM_DEATH,
} as const;

// ------------------------------------------------------------------ warden

const ROBE_PANELS = [0, 1, 2, 3, 4, 5];

/**
 * Robe sway. Each panel is offset in phase around the body so the skirt
 * ripples rather than flapping as one rigid cone — the single detail that
 * makes cloth read as cloth on a rigid-segment rig.
 */
function robeSway(amp: number, period = 1): Record<string, Track> {
  const out: Record<string, Track> = {};
  for (const i of ROBE_PANELS) {
    const phase = (i / ROBE_PANELS.length) * period;
    const at = (t: number) => (t + phase) % 1;
    out[`robe${i}`] = [
      { t: 0, pose: { rx: amp * Math.sin(phase * Math.PI * 2) } },
      { t: at(0.25) < 1 ? at(0.25) : 0.99, pose: { rx: amp } },
      { t: at(0.75) < 1 ? at(0.75) : 0.99, pose: { rx: -amp } },
      { t: 1, pose: { rx: amp * Math.sin(phase * Math.PI * 2) } },
    ].sort((a, b) => a.t - b.t);
  }
  return out;
}

export const WARDEN_IDLE: Clip = {
  name: 'idle',
  duration: 4.5,
  loop: true,
  tracks: {
    // Hovers rather than stands — the feet never quite settle.
    hips: [k(0, { py: 0.03 }), k(0.5, { py: -0.03 }), k(1, { py: 0.03 })],
    spine: [k(0, { rx: -0.03 }), k(0.5, { rx: 0.02 }), k(1, { rx: -0.03 })],
    chest: [k(0, { rx: 0.02, ry: 0.02 }), k(0.5, { rx: -0.02, ry: -0.02 }), k(1, { rx: 0.02, ry: 0.02 })],
    head: [k(0, { ry: 0.05, rx: -0.03 }), k(0.4, { ry: -0.06, rx: 0.02 }), k(1, { ry: 0.05, rx: -0.03 })],
    halo: [k(0, { ry: 0 }), k(1, { ry: Math.PI * 2 })],
    armL: [k(0, { rx: -0.12, rz: -0.24 }), k(0.5, { rx: -0.18, rz: -0.3 }), k(1, { rx: -0.12, rz: -0.24 })],
    armR: [k(0, { rx: -0.18, rz: 0.3 }), k(0.5, { rx: -0.12, rz: 0.24 }), k(1, { rx: -0.18, rz: 0.3 })],
    forearmL: [k(0, { rx: -0.55 }), k(0.5, { rx: -0.42 }), k(1, { rx: -0.55 })],
    forearmR: [k(0, { rx: -0.42 }), k(0.5, { rx: -0.55 }), k(1, { rx: -0.42 })],
    thighL: [k(0, { rx: 0.06 }), k(1, { rx: 0.06 })],
    thighR: [k(0, { rx: -0.04 }), k(1, { rx: -0.04 })],
    ...robeSway(0.05),
  },
};

export const WARDEN_WALK: Clip = {
  name: 'walk',
  duration: 1.15,
  loop: true,
  tracks: {
    hips: [k(0, { py: 0.02, ry: 0.06 }), k(0.25, { py: 0.06 }), k(0.5, { py: 0.02, ry: -0.06 }), k(0.75, { py: 0.06 }), k(1, { py: 0.02, ry: 0.06 })],
    spine: [k(0, { rx: 0.04, ry: -0.04 }), k(0.5, { rx: 0.04, ry: 0.04 }), k(1, { rx: 0.04, ry: -0.04 })],
    chest: [k(0, { ry: -0.07 }), k(0.5, { ry: 0.07 }), k(1, { ry: -0.07 })],
    head: [k(0, { ry: 0.04 }), k(0.5, { ry: -0.04 }), k(1, { ry: 0.04 })],
    halo: [k(0, { ry: 0 }), k(1, { ry: Math.PI * 2 })],
    armL: [k(0, { rx: -0.35, rz: -0.24 }), k(0.5, { rx: 0.2, rz: -0.28 }), k(1, { rx: -0.35, rz: -0.24 })],
    armR: [k(0, { rx: 0.2, rz: 0.28 }), k(0.5, { rx: -0.35, rz: 0.24 }), k(1, { rx: 0.2, rz: 0.28 })],
    forearmL: [k(0, { rx: -0.4 }), k(0.5, { rx: -0.7 }), k(1, { rx: -0.4 })],
    forearmR: [k(0, { rx: -0.7 }), k(0.5, { rx: -0.4 }), k(1, { rx: -0.7 })],
    thighL: [k(0, { rx: 0.42 }), k(0.5, { rx: -0.35 }), k(0.78, { rx: 0.1 }), k(1, { rx: 0.42 })],
    thighR: [k(0, { rx: -0.35 }), k(0.28, { rx: 0.1 }), k(0.5, { rx: 0.42 }), k(1, { rx: -0.35 })],
    shinL: [k(0, { rx: -0.08 }), k(0.7, { rx: -0.8 }), k(1, { rx: -0.08 })],
    shinR: [k(0, { rx: -0.5 }), k(0.2, { rx: -0.8 }), k(0.5, { rx: -0.08 }), k(1, { rx: -0.5 })],
    ...robeSway(0.22, 1),
  },
};

export const WARDEN_RUN: Clip = { ...WARDEN_WALK, name: 'run', duration: 0.78 };

/** Lunge: glides forward behind an outstretched arm. */
export const WARDEN_LUNGE: Clip = {
  name: 'lunge',
  duration: 1.58,
  loop: false,
  tracks: {
    hips: [k(0, { py: 0.02, pz: 0 }), k(0.4, { py: 0.12, pz: -0.12 }), k(0.55, { py: -0.04, pz: 0.22 }), k(1, { py: 0.02, pz: 0 })],
    spine: [k(0, { rx: 0 }), k(0.4, { rx: -0.3 }), k(0.55, { rx: 0.5 }), k(1, { rx: 0 })],
    chest: [k(0, { ry: 0 }), k(0.4, { ry: 0.35 }), k(0.55, { ry: -0.4 }), k(1, { ry: 0 })],
    head: [k(0, { rx: 0 }), k(0.4, { rx: -0.2 }), k(0.55, { rx: 0.3 }), k(1, { rx: 0 })],
    halo: [k(0, { ry: 0 }), k(0.4, { ry: 2.5 }), k(1, { ry: 6.28 })],
    armR: [k(0, { rx: -0.18, rz: 0.3 }), k(0.4, { rx: 0.6, rz: 0.7 }), k(0.55, { rx: -1.55, rz: 0.1 }), k(0.72, { rx: -1.45 }), k(1, { rx: -0.18, rz: 0.3 })],
    forearmR: [k(0, { rx: -0.42 }), k(0.4, { rx: -1.6 }), k(0.55, { rx: -0.05 }), k(1, { rx: -0.42 })],
    handR: [k(0, { rx: 0 }), k(0.55, { rx: 0.4 }), k(1, { rx: 0 })],
    armL: [k(0, { rx: -0.12, rz: -0.24 }), k(0.4, { rx: -0.8, rz: -0.6 }), k(0.55, { rx: -0.3, rz: -0.5 }), k(1, { rx: -0.12, rz: -0.24 })],
    forearmL: [k(0, { rx: -0.55 }), k(0.4, { rx: -1.7 }), k(1, { rx: -0.55 })],
    thighL: [k(0, { rx: 0.06 }), k(0.4, { rx: -0.4 }), k(0.55, { rx: 0.7 }), k(1, { rx: 0.06 })],
    thighR: [k(0, { rx: -0.04 }), k(0.4, { rx: 0.35 }), k(0.55, { rx: -0.5 }), k(1, { rx: -0.04 })],
    shinL: [k(0, { rx: -0.08 }), k(0.55, { rx: -0.6 }), k(1, { rx: -0.08 })],
    shinR: [k(0, { rx: -0.08 }), k(0.55, { rx: -0.3 }), k(1, { rx: -0.08 })],
    ...robeSway(0.4, 0.6),
  },
};

/** Water jet: braces sideways and channels a beam from both palms. */
export const WARDEN_JET: Clip = {
  name: 'water_jet',
  duration: 2.05,
  loop: false,
  tracks: {
    hips: [k(0, { py: 0.02, ry: 0 }), k(0.45, { py: 0.1, ry: 0.35 }), k(0.62, { py: 0.04, ry: 0.2 }), k(1, { py: 0.02, ry: 0 })],
    spine: [k(0, { rx: 0 }), k(0.45, { rx: -0.25, ry: 0.2 }), k(0.62, { rx: 0.2 }), k(1, { rx: 0 })],
    chest: [k(0, { ry: 0 }), k(0.45, { ry: 0.3 }), k(0.62, { ry: -0.1 }), k(1, { ry: 0 })],
    head: [k(0, { ry: 0 }), k(0.45, { ry: -0.35 }), k(1, { ry: 0 })],
    halo: [k(0, { ry: 0 }), k(0.45, { ry: 3.5 }), k(1, { ry: 9 })],
    armL: [k(0, { rx: -0.12, rz: -0.24 }), k(0.42, { rx: -0.55, rz: -0.7 }), k(0.6, { rx: -1.5, rz: -0.14 }), k(0.8, { rx: -1.45, rz: -0.14 }), k(1, { rx: -0.12, rz: -0.24 })],
    armR: [k(0, { rx: -0.18, rz: 0.3 }), k(0.42, { rx: -0.55, rz: 0.7 }), k(0.6, { rx: -1.5, rz: 0.14 }), k(0.8, { rx: -1.45, rz: 0.14 }), k(1, { rx: -0.18, rz: 0.3 })],
    forearmL: [k(0, { rx: -0.55 }), k(0.42, { rx: -1.9 }), k(0.6, { rx: -0.1 }), k(1, { rx: -0.55 })],
    forearmR: [k(0, { rx: -0.42 }), k(0.42, { rx: -1.9 }), k(0.6, { rx: -0.1 }), k(1, { rx: -0.42 })],
    handL: [k(0, { rx: 0 }), k(0.45, { rx: -0.5 }), k(0.62, { rx: 0.5 }), k(1, { rx: 0 })],
    handR: [k(0, { rx: 0 }), k(0.45, { rx: -0.5 }), k(0.62, { rx: 0.5 }), k(1, { rx: 0 })],
    thighL: [k(0, { rx: 0.06 }), k(0.45, { rx: 0.35, rz: 0.15 }), k(1, { rx: 0.06 })],
    thighR: [k(0, { rx: -0.04 }), k(0.45, { rx: -0.3, rz: -0.15 }), k(1, { rx: -0.04 })],
    ...robeSway(0.3, 0.8),
  },
};

/** Tide crash: rises up, then slams both arms down in a radial burst. */
export const WARDEN_CRASH: Clip = {
  name: 'tide_crash',
  duration: 2.75,
  loop: false,
  tracks: {
    hips: [k(0, { py: 0.02 }), k(0.4, { py: 0.42 }), k(0.5, { py: 0.5 }), k(0.58, { py: -0.2 }), k(0.7, { py: -0.1 }), k(1, { py: 0.02 })],
    spine: [k(0, { rx: 0 }), k(0.45, { rx: -0.5 }), k(0.58, { rx: 0.6 }), k(1, { rx: 0 })],
    chest: [k(0, { rx: 0 }), k(0.45, { rx: -0.3 }), k(0.58, { rx: 0.4 }), k(1, { rx: 0 })],
    neck: [k(0, { rx: 0 }), k(0.45, { rx: -0.4 }), k(0.58, { rx: 0.45 }), k(1, { rx: 0 })],
    head: [k(0, { rx: 0 }), k(0.45, { rx: -0.35 }), k(0.58, { rx: 0.4 }), k(1, { rx: 0 })],
    halo: [k(0, { ry: 0, py: 0 }), k(0.45, { ry: 5, py: 0.25 }), k(0.58, { ry: 7, py: -0.05 }), k(1, { ry: 12, py: 0 })],
    armL: [k(0, { rx: -0.12, rz: -0.24 }), k(0.45, { rx: -2.7, rz: -0.8 }), k(0.58, { rx: 0.55, rz: -0.55 }), k(0.72, { rx: 0.4, rz: -0.45 }), k(1, { rx: -0.12, rz: -0.24 })],
    armR: [k(0, { rx: -0.18, rz: 0.3 }), k(0.45, { rx: -2.7, rz: 0.8 }), k(0.58, { rx: 0.55, rz: 0.55 }), k(0.72, { rx: 0.4, rz: 0.45 }), k(1, { rx: -0.18, rz: 0.3 })],
    forearmL: [k(0, { rx: -0.55 }), k(0.45, { rx: -0.6 }), k(0.58, { rx: -0.08 }), k(1, { rx: -0.55 })],
    forearmR: [k(0, { rx: -0.42 }), k(0.45, { rx: -0.6 }), k(0.58, { rx: -0.08 }), k(1, { rx: -0.42 })],
    thighL: [k(0, { rx: 0.06 }), k(0.45, { rx: 0.5 }), k(0.58, { rx: 0.4 }), k(1, { rx: 0.06 })],
    thighR: [k(0, { rx: -0.04 }), k(0.45, { rx: 0.45 }), k(0.58, { rx: 0.35 }), k(1, { rx: -0.04 })],
    shinL: [k(0, { rx: -0.08 }), k(0.45, { rx: -1.3 }), k(0.58, { rx: -0.5 }), k(1, { rx: -0.08 })],
    shinR: [k(0, { rx: -0.08 }), k(0.45, { rx: -1.25 }), k(0.58, { rx: -0.45 }), k(1, { rx: -0.08 })],
    ...robeSway(0.55, 0.5),
  },
};

export const WARDEN_HURT: Clip = {
  name: 'hurt',
  duration: 0.36,
  loop: false,
  tracks: {
    hips: [k(0, { py: 0.02 }), k(0.2, { py: -0.02, pz: -0.06 }), k(1, { py: 0.02 })],
    spine: [k(0, { rx: 0 }), k(0.18, { rx: -0.28, rz: 0.14 }), k(1, { rx: 0 })],
    chest: [k(0, { rx: 0 }), k(0.18, { rx: -0.18, ry: 0.18 }), k(1, { rx: 0 })],
    head: [k(0, { rx: 0 }), k(0.16, { rx: -0.3, rz: 0.18 }), k(1, { rx: 0 })],
    armL: [k(0, { rx: -0.12, rz: -0.24 }), k(0.2, { rx: -0.45, rz: -0.6 }), k(1, { rx: -0.12, rz: -0.24 })],
    armR: [k(0, { rx: -0.18, rz: 0.3 }), k(0.2, { rx: -0.4, rz: 0.55 }), k(1, { rx: -0.18, rz: 0.3 })],
    ...robeSway(0.25, 0.4),
  },
};

/** Boss phase transition: rises, arms flung wide, halo spinning hard. */
export const WARDEN_ROAR: Clip = {
  name: 'roar',
  duration: 2.0,
  loop: false,
  tracks: {
    hips: [k(0, { py: 0.02 }), k(0.35, { py: 0.5 }), k(0.7, { py: 0.45 }), k(1, { py: 0.02 })],
    spine: [k(0, { rx: 0 }), k(0.35, { rx: -0.55 }), k(0.7, { rx: -0.45 }), k(1, { rx: 0 })],
    chest: [k(0, { rx: 0 }), k(0.35, { rx: -0.35 }), k(1, { rx: 0 })],
    neck: [k(0, { rx: 0 }), k(0.35, { rx: -0.5 }), k(0.7, { rx: -0.45 }), k(1, { rx: 0 })],
    head: [k(0, { rx: 0 }), k(0.35, { rx: -0.4 }), k(1, { rx: 0 })],
    halo: [k(0, { ry: 0, py: 0 }), k(0.4, { ry: 8, py: 0.35 }), k(1, { ry: 20, py: 0 })],
    armL: [k(0, { rx: -0.12, rz: -0.24 }), k(0.35, { rx: -1.1, rz: -1.5 }), k(0.7, { rx: -1.0, rz: -1.4 }), k(1, { rx: -0.12, rz: -0.24 })],
    armR: [k(0, { rx: -0.18, rz: 0.3 }), k(0.35, { rx: -1.1, rz: 1.5 }), k(0.7, { rx: -1.0, rz: 1.4 }), k(1, { rx: -0.18, rz: 0.3 })],
    forearmL: [k(0, { rx: -0.55 }), k(0.35, { rx: -0.3 }), k(1, { rx: -0.55 })],
    forearmR: [k(0, { rx: -0.42 }), k(0.35, { rx: -0.3 }), k(1, { rx: -0.42 })],
    thighL: [k(0, { rx: 0.06 }), k(0.4, { rx: 0.35 }), k(1, { rx: 0.06 })],
    thighR: [k(0, { rx: -0.04 }), k(0.4, { rx: 0.3 }), k(1, { rx: -0.04 })],
    shinL: [k(0, { rx: -0.08 }), k(0.4, { rx: -0.9 }), k(1, { rx: -0.08 })],
    shinR: [k(0, { rx: -0.08 }), k(0.4, { rx: -0.85 }), k(1, { rx: -0.08 })],
    ...robeSway(0.6, 0.35),
  },
};

export const WARDEN_STAGGER: Clip = {
  name: 'stagger',
  duration: 0.65,
  loop: true,
  tracks: {
    hips: [k(0, { py: -0.12, rz: 0.12 }), k(0.5, { py: -0.16, rz: -0.1 }), k(1, { py: -0.12, rz: 0.12 })],
    spine: [k(0, { rx: 0.4, ry: 0.12 }), k(0.5, { rx: 0.45, ry: -0.12 }), k(1, { rx: 0.4, ry: 0.12 })],
    chest: [k(0, { rx: 0.2 }), k(0.5, { rx: 0.25 }), k(1, { rx: 0.2 })],
    head: [k(0, { rx: 0.3, ry: 0.15 }), k(0.5, { rx: 0.35, ry: -0.15 }), k(1, { rx: 0.3, ry: 0.15 })],
    halo: [k(0, { ry: 0, rz: 0.3 }), k(1, { ry: 1.2, rz: 0.3 })],
    armL: [k(0, { rx: 0.3, rz: -0.5 }), k(0.5, { rx: 0.35, rz: -0.45 }), k(1, { rx: 0.3, rz: -0.5 })],
    armR: [k(0, { rx: 0.25, rz: 0.45 }), k(0.5, { rx: 0.3, rz: 0.5 }), k(1, { rx: 0.25, rz: 0.45 })],
    thighL: [k(0, { rx: 0.5, rz: -0.1 }), k(1, { rx: 0.5, rz: -0.1 })],
    thighR: [k(0, { rx: 0.3, rz: 0.15 }), k(1, { rx: 0.3, rz: 0.15 })],
    shinL: [k(0, { rx: -0.9 }), k(1, { rx: -0.9 })],
    shinR: [k(0, { rx: -0.6 }), k(1, { rx: -0.6 })],
    ...robeSway(0.18, 0.5),
  },
};

export const WARDEN_DEATH: Clip = {
  name: 'death',
  duration: 1.8,
  loop: false,
  tracks: {
    root: [k(0, { rx: 0 }), k(0.6, { rx: 0.2 }), k(1, { rx: 1.25, py: -0.2 })],
    hips: [k(0, { py: 0.02 }), k(0.25, { py: 0.28 }), k(0.6, { py: -0.35 }), k(1, { py: -0.62 })],
    spine: [k(0, { rx: 0 }), k(0.25, { rx: -0.6 }), k(0.7, { rx: 0.45 }), k(1, { rx: 0.6 })],
    chest: [k(0, { rx: 0 }), k(0.25, { rx: -0.35 }), k(1, { rx: 0.35 })],
    neck: [k(0, { rx: 0 }), k(0.25, { rx: -0.5 }), k(1, { rx: 0.5 })],
    head: [k(0, { rx: 0 }), k(1, { rx: 0.4, rz: 0.2 })],
    // The halo scatters as it dies.
    halo: [k(0, { ry: 0, py: 0 }), k(0.3, { ry: 6, py: 0.3 }), k(1, { ry: 14, py: 1.4 })],
    armL: [k(0, { rx: -0.12, rz: -0.24 }), k(0.3, { rx: -1.4, rz: -1.2 }), k(1, { rx: 0.5, rz: -1.0 })],
    armR: [k(0, { rx: -0.18, rz: 0.3 }), k(0.3, { rx: -1.4, rz: 1.2 }), k(1, { rx: 0.45, rz: 0.95 })],
    forearmL: [k(0, { rx: -0.55 }), k(1, { rx: -0.2 })],
    forearmR: [k(0, { rx: -0.42 }), k(1, { rx: -0.25 })],
    thighL: [k(0, { rx: 0.06 }), k(0.6, { rx: 1.1 }), k(1, { rx: 1.4 })],
    thighR: [k(0, { rx: -0.04 }), k(0.6, { rx: 0.9 }), k(1, { rx: 1.2 })],
    shinL: [k(0, { rx: -0.08 }), k(0.6, { rx: -1.6 }), k(1, { rx: -1.9 })],
    shinR: [k(0, { rx: -0.08 }), k(0.6, { rx: -1.4 }), k(1, { rx: -1.7 })],
    ...robeSway(0.35, 0.3),
  },
};

export const WARDEN_CLIPS = {
  idle: WARDEN_IDLE,
  walk: WARDEN_WALK,
  run: WARDEN_RUN,
  lunge: WARDEN_LUNGE,
  water_jet: WARDEN_JET,
  tide_crash: WARDEN_CRASH,
  roar: WARDEN_ROAR,
  hurt: WARDEN_HURT,
  stagger: WARDEN_STAGGER,
  death: WARDEN_DEATH,
} as const;
