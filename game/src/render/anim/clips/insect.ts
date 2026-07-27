import { INSECT_LEGS, type InsectLeg } from '../../models/enemies';
import type { Clip, Track } from '../types';

const k = (t: number, pose: Track[number]['pose']): Track[number] => ({ t, pose });

/**
 * Insect gait clips. Real hexapods use an alternating tripod: front+back on
 * one side move with the middle leg of the other, so three feet are always
 * planted. Faking it with all-six-in-sync reads as a wind-up toy.
 *
 * Tripod A = FL, MR, BL   Tripod B = FR, ML, BR
 */
const TRIPOD_A: InsectLeg[] = ['FL', 'MR', 'BL'];

function isTripodA(leg: InsectLeg): boolean {
  return TRIPOD_A.includes(leg);
}

/** Builds leg tracks for a walk cycle by phase-offsetting the two tripods. */
function tripodGait(
  lift: number,
  reach: number,
  opts: { femurBase?: number } = {},
): Record<string, Track> {
  const tracks: Record<string, Track> = {};
  const base = opts.femurBase ?? 0;

  for (const leg of INSECT_LEGS) {
    const side = leg.endsWith('L') ? -1 : 1;
    const jump = leg.startsWith('B');
    // The two tripods run half a cycle apart.
    const off = isTripodA(leg) ? 0 : 0.5;
    const at = (t: number) => (t + off) % 1;

    const scale = jump ? 0.7 : 1;
    const r = reach * scale;
    const l = lift * scale;

    // Stance sweeps back (propulsion), swing lifts and reaches forward.
    tracks[`coxa${leg}`] = sortTrack([
      k(at(0), { ry: side * r }),
      k(at(0.5), { ry: side * -r }),
      k(at(0.75), { ry: side * r * 1.1 }),
      k(at(1), { ry: side * r }),
    ]);
    tracks[`femur${leg}`] = sortTrack([
      k(at(0), { rx: base }),
      k(at(0.5), { rx: base + 0.05 }),
      k(at(0.62), { rx: base - l * 1.4 }), // lifted clear of the ground
      k(at(0.85), { rx: base - l * 0.5 }),
      k(at(1), { rx: base }),
    ]);
    tracks[`tibia${leg}`] = sortTrack([
      k(at(0), { rx: 0 }),
      k(at(0.5), { rx: -0.12 }),
      k(at(0.62), { rx: l * 1.8 }), // folds up during the swing
      k(at(0.85), { rx: l * 0.4 }),
      k(at(1), { rx: 0 }),
    ]);
    tracks[`tarsus${leg}`] = sortTrack([
      k(at(0), { rx: 0 }),
      k(at(0.6), { rx: -l }),
      k(at(0.9), { rx: l * 0.5 }),
      k(at(1), { rx: 0 }),
    ]);
  }
  return tracks;
}

/** Keyframes must be time-sorted; phase offsets wrap past 1. */
function sortTrack(track: Track): Track {
  const sorted = [...track].sort((a, b) => a.t - b.t);
  // Guarantee the loop closes: mirror the first key at t=1 if it isn't there.
  if (sorted[0].t > 0) sorted.unshift({ t: 0, pose: sorted[sorted.length - 1].pose });
  if (sorted[sorted.length - 1].t < 1) sorted.push({ t: 1, pose: sorted[0].pose });
  return sorted;
}

export const INSECT_IDLE: Clip = {
  name: 'idle',
  duration: 3.0,
  loop: true,
  tracks: {
    thorax: [k(0, { py: 0, rx: 0 }), k(0.5, { py: 0.014, rx: -0.03 }), k(1, { py: 0, rx: 0 })],
    abdomen: [k(0, { rx: 0 }), k(0.35, { rx: 0.07 }), k(0.7, { rx: -0.04 }), k(1, { rx: 0 })],
    head: [k(0, { ry: 0.1, rx: 0.03 }), k(0.4, { ry: -0.12, rx: -0.02 }), k(1, { ry: 0.1, rx: 0.03 })],
    // Antennae never stop moving; a still antenna kills the illusion instantly.
    antennaL: [k(0, { rx: 0, rz: 0.1 }), k(0.28, { rx: -0.3, rz: 0.25 }), k(0.6, { rx: 0.2, rz: -0.05 }), k(1, { rx: 0, rz: 0.1 })],
    antennaR: [k(0, { rx: 0.15, rz: -0.05 }), k(0.34, { rx: -0.25, rz: -0.28 }), k(0.72, { rx: 0.25, rz: 0.08 }), k(1, { rx: 0.15, rz: -0.05 })],
    mandibleL: [k(0, { rz: 0 }), k(0.3, { rz: -0.28 }), k(0.45, { rz: 0 }), k(1, { rz: 0 })],
    mandibleR: [k(0, { rz: 0 }), k(0.3, { rz: 0.28 }), k(0.45, { rz: 0 }), k(1, { rz: 0 })],
    // Micro-adjustments on the legs so it never looks frozen.
    femurFL: [k(0, { rx: 0 }), k(0.5, { rx: -0.05 }), k(1, { rx: 0 })],
    femurBR: [k(0, { rx: 0 }), k(0.6, { rx: -0.06 }), k(1, { rx: 0 })],
  },
};

export const INSECT_WALK: Clip = {
  name: 'walk',
  duration: 0.62,
  loop: true,
  tracks: {
    thorax: [
      k(0, { py: 0, rz: 0.04 }),
      k(0.25, { py: 0.02 }),
      k(0.5, { py: 0, rz: -0.04 }),
      k(0.75, { py: 0.02 }),
      k(1, { py: 0, rz: 0.04 }),
    ],
    abdomen: [k(0, { ry: 0.06, rx: 0.03 }), k(0.5, { ry: -0.06, rx: 0.03 }), k(1, { ry: 0.06, rx: 0.03 })],
    head: [k(0, { ry: -0.05 }), k(0.5, { ry: 0.05 }), k(1, { ry: -0.05 })],
    antennaL: [k(0, { rx: -0.15 }), k(0.5, { rx: 0.12 }), k(1, { rx: -0.15 })],
    antennaR: [k(0, { rx: 0.12 }), k(0.5, { rx: -0.15 }), k(1, { rx: 0.12 })],
    ...tripodGait(0.35, 0.3),
  },
};

/** Aggro charge: faster, body low and forward, abdomen raised. */
export const INSECT_RUN: Clip = {
  name: 'run',
  duration: 0.36,
  loop: true,
  tracks: {
    thorax: [
      k(0, { py: -0.05, rx: 0.12, rz: 0.05 }),
      k(0.25, { py: 0.02 }),
      k(0.5, { py: -0.05, rx: 0.12, rz: -0.05 }),
      k(0.75, { py: 0.02 }),
      k(1, { py: -0.05, rx: 0.12, rz: 0.05 }),
    ],
    abdomen: [k(0, { rx: -0.22, ry: 0.08 }), k(0.5, { rx: -0.22, ry: -0.08 }), k(1, { rx: -0.22, ry: 0.08 })],
    head: [k(0, { rx: -0.1, ry: -0.06 }), k(0.5, { rx: -0.1, ry: 0.06 }), k(1, { rx: -0.1, ry: -0.06 })],
    antennaL: [k(0, { rx: -0.45 }), k(0.5, { rx: -0.3 }), k(1, { rx: -0.45 })],
    antennaR: [k(0, { rx: -0.3 }), k(0.5, { rx: -0.45 }), k(1, { rx: -0.3 })],
    ...tripodGait(0.5, 0.42),
  },
};

/**
 * Bite: rears back on the rear legs, then lunges. The whole body commits,
 * which is what makes a 0.45s windup readable at a glance.
 */
export const INSECT_ATTACK: Clip = {
  name: 'attack',
  duration: 0.57,
  loop: false,
  tracks: {
    thorax: [
      k(0, { py: 0, rx: 0, pz: 0 }),
      k(0.45, { py: 0.13, rx: -0.45, pz: -0.08 }), // rear up
      k(0.62, { py: -0.06, rx: 0.4, pz: 0.16 }), // lunge
      k(0.78, { py: -0.02, rx: 0.2, pz: 0.06 }),
      k(1, { py: 0, rx: 0, pz: 0 }),
    ],
    abdomen: [k(0, { rx: 0 }), k(0.45, { rx: 0.35 }), k(0.62, { rx: -0.3 }), k(1, { rx: 0 })],
    head: [k(0, { rx: 0 }), k(0.45, { rx: -0.3 }), k(0.62, { rx: 0.45 }), k(1, { rx: 0 })],
    mandibleL: [k(0, { rz: 0 }), k(0.42, { rz: -0.6 }), k(0.62, { rz: 0.15 }), k(1, { rz: 0 })],
    mandibleR: [k(0, { rz: 0 }), k(0.42, { rz: 0.6 }), k(0.62, { rz: -0.15 }), k(1, { rz: 0 })],
    antennaL: [k(0, { rx: 0 }), k(0.45, { rx: -0.6, rz: 0.3 }), k(1, { rx: 0 })],
    antennaR: [k(0, { rx: 0 }), k(0.45, { rx: -0.6, rz: -0.3 }), k(1, { rx: 0 })],

    // Front legs paw forward on the strike; rear legs drive the lunge.
    femurFL: [k(0, { rx: 0 }), k(0.45, { rx: -0.8 }), k(0.62, { rx: 0.5 }), k(1, { rx: 0 })],
    femurFR: [k(0, { rx: 0 }), k(0.45, { rx: -0.8 }), k(0.62, { rx: 0.5 }), k(1, { rx: 0 })],
    tibiaFL: [k(0, { rx: 0 }), k(0.45, { rx: 0.7 }), k(0.62, { rx: -0.5 }), k(1, { rx: 0 })],
    tibiaFR: [k(0, { rx: 0 }), k(0.45, { rx: 0.7 }), k(0.62, { rx: -0.5 }), k(1, { rx: 0 })],
    femurBL: [k(0, { rx: 0 }), k(0.45, { rx: 0.5 }), k(0.62, { rx: -0.55 }), k(1, { rx: 0 })],
    femurBR: [k(0, { rx: 0 }), k(0.45, { rx: 0.5 }), k(0.62, { rx: -0.55 }), k(1, { rx: 0 })],
    tibiaBL: [k(0, { rx: 0 }), k(0.45, { rx: -0.6 }), k(0.62, { rx: 0.7 }), k(1, { rx: 0 })],
    tibiaBR: [k(0, { rx: 0 }), k(0.45, { rx: -0.6 }), k(0.62, { rx: 0.7 }), k(1, { rx: 0 })],
  },
};

export const INSECT_HURT: Clip = {
  name: 'hurt',
  duration: 0.36,
  loop: false,
  tracks: {
    thorax: [k(0, { py: 0, pz: 0 }), k(0.2, { py: -0.05, pz: -0.1, rz: 0.2 }), k(1, { py: 0, pz: 0 })],
    abdomen: [k(0, { rx: 0 }), k(0.2, { rx: 0.4, ry: 0.2 }), k(1, { rx: 0 })],
    head: [k(0, { rx: 0 }), k(0.18, { rx: -0.35 }), k(1, { rx: 0 })],
    antennaL: [k(0, { rx: 0 }), k(0.2, { rx: 0.5, rz: 0.4 }), k(1, { rx: 0 })],
    antennaR: [k(0, { rx: 0 }), k(0.2, { rx: 0.5, rz: -0.4 }), k(1, { rx: 0 })],
    femurFL: [k(0, { rx: 0 }), k(0.2, { rx: 0.35 }), k(1, { rx: 0 })],
    femurFR: [k(0, { rx: 0 }), k(0.2, { rx: 0.35 }), k(1, { rx: 0 })],
  },
};

/** Staggered: legs splay, body wobbles, antennae flail. */
export const INSECT_STAGGER: Clip = {
  name: 'stagger',
  duration: 0.6,
  loop: true,
  tracks: {
    thorax: [
      k(0, { py: -0.08, rz: 0.16, rx: 0.1 }),
      k(0.33, { py: -0.1, rz: -0.14 }),
      k(0.66, { py: -0.06, rz: 0.1 }),
      k(1, { py: -0.08, rz: 0.16, rx: 0.1 }),
    ],
    head: [k(0, { rx: 0.2, ry: 0.2 }), k(0.5, { rx: 0.25, ry: -0.22 }), k(1, { rx: 0.2, ry: 0.2 })],
    abdomen: [k(0, { rx: 0.2 }), k(0.5, { rx: 0.3 }), k(1, { rx: 0.2 })],
    antennaL: [k(0, { rx: 0.4, rz: 0.5 }), k(0.4, { rx: 0.1, rz: 0.2 }), k(1, { rx: 0.4, rz: 0.5 })],
    antennaR: [k(0, { rx: 0.1, rz: -0.2 }), k(0.4, { rx: 0.4, rz: -0.5 }), k(1, { rx: 0.1, rz: -0.2 })],
    ...Object.fromEntries(
      INSECT_LEGS.flatMap((leg) => {
        const side = leg.endsWith('L') ? -1 : 1;
        return [
          [`coxa${leg}`, [k(0, { ry: side * 0.2, rz: side * 0.3 }), k(1, { ry: side * 0.2, rz: side * 0.3 })]],
          [`femur${leg}`, [k(0, { rx: 0.25 }), k(0.5, { rx: 0.35 }), k(1, { rx: 0.25 })]],
        ];
      }),
    ),
  },
};

/** Death: legs curl inward over the body — the universal dead-insect pose. */
export const INSECT_DEATH: Clip = {
  name: 'death',
  duration: 0.9,
  loop: false,
  tracks: {
    root: [k(0, { rz: 0 }), k(0.4, { rz: 0.7 }), k(1, { rz: 2.4, py: -0.12 })],
    thorax: [k(0, { py: 0 }), k(0.5, { py: -0.16 }), k(1, { py: -0.24 })],
    abdomen: [k(0, { rx: 0 }), k(1, { rx: 0.65 })],
    head: [k(0, { rx: 0 }), k(1, { rx: 0.5 })],
    antennaL: [k(0, { rx: 0 }), k(1, { rx: 0.9, rz: 0.6 })],
    antennaR: [k(0, { rx: 0 }), k(1, { rx: 0.9, rz: -0.6 })],
    mandibleL: [k(0, { rz: 0 }), k(1, { rz: -0.4 })],
    mandibleR: [k(0, { rz: 0 }), k(1, { rz: 0.4 })],
    ...Object.fromEntries(
      INSECT_LEGS.flatMap((leg) => [
        [`femur${leg}`, [k(0, { rx: 0 }), k(0.45, { rx: 0.7 }), k(1, { rx: 1.15 })]],
        [`tibia${leg}`, [k(0, { rx: 0 }), k(0.45, { rx: -1.2 }), k(1, { rx: -1.9 })]],
        [`tarsus${leg}`, [k(0, { rx: 0 }), k(1, { rx: -0.8 })]],
      ]),
    ),
  },
};

export const INSECT_CLIPS = {
  idle: INSECT_IDLE,
  walk: INSECT_WALK,
  run: INSECT_RUN,
  attack: INSECT_ATTACK,
  hurt: INSECT_HURT,
  stagger: INSECT_STAGGER,
  death: INSECT_DEATH,
} as const;
