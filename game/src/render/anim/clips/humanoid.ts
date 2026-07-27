import { UPPER_BODY_MASK } from '../../models/skeleton';
import type { Clip, Track } from '../types';

/**
 * Hand-authored humanoid clips. Conventions:
 *   +rx  = limb swings forward (shoulder/hip flexion)
 *   +rz  = limb swings away from the body's midline on the left side
 *   Joints are keyed in normalised time; duration is set per clip.
 *
 * Every cycle keys t:0 and t:1 identically so loops don't pop.
 */

const k = (t: number, pose: Track[number]['pose']): Track[number] => ({ t, pose });

// ------------------------------------------------------------------ idle

/**
 * Idle is where a character reads as alive or dead. Three things do the work:
 * asymmetric weight on one hip, a breathing cycle on the chest at a different
 * period from the sway, and the arms hanging with a slight lag.
 */
export const IDLE: Clip = {
  name: 'idle',
  duration: 4.2,
  loop: true,
  tracks: {
    hips: [
      k(0, { py: 0, rz: 0.02, ry: -0.03 }),
      k(0.5, { py: -0.012, rz: -0.02, ry: 0.03 }),
      k(1, { py: 0, rz: 0.02, ry: -0.03 }),
    ],
    spine: [k(0, { rx: 0.02 }), k(0.5, { rx: 0.05 }), k(1, { rx: 0.02 })],
    // Chest breathes at roughly 2.5x the sway period.
    chest: [
      k(0, { rx: -0.02, ry: 0.02 }),
      k(0.2, { rx: -0.055 }),
      k(0.4, { rx: -0.015 }),
      k(0.6, { rx: -0.055, ry: -0.02 }),
      k(0.8, { rx: -0.015 }),
      k(1, { rx: -0.02, ry: 0.02 }),
    ],
    neck: [k(0, { rx: 0.03, ry: 0.04 }), k(0.55, { rx: 0.01, ry: -0.05 }), k(1, { rx: 0.03, ry: 0.04 })],
    head: [k(0, { ry: 0.03, rz: 0.02 }), k(0.45, { ry: -0.04, rz: -0.01 }), k(1, { ry: 0.03, rz: 0.02 })],

    shoulderL: [k(0, { rz: -0.03 }), k(0.5, { rz: -0.06 }), k(1, { rz: -0.03 })],
    shoulderR: [k(0, { rz: 0.03 }), k(0.5, { rz: 0.06 }), k(1, { rz: 0.03 })],
    armL: [k(0, { rx: 0.04, rz: -0.1 }), k(0.5, { rx: -0.03, rz: -0.14 }), k(1, { rx: 0.04, rz: -0.1 })],
    armR: [k(0, { rx: -0.03, rz: 0.14 }), k(0.5, { rx: 0.04, rz: 0.1 }), k(1, { rx: -0.03, rz: 0.14 })],
    forearmL: [k(0, { rx: -0.28, ry: 0.1 }), k(0.5, { rx: -0.36 }), k(1, { rx: -0.28, ry: 0.1 })],
    forearmR: [k(0, { rx: -0.36 }), k(0.5, { rx: -0.28, ry: -0.1 }), k(1, { rx: -0.36 })],
    handL: [k(0, { rx: -0.1, rz: -0.06 }), k(0.5, { rx: 0.04 }), k(1, { rx: -0.1, rz: -0.06 })],
    handR: [k(0, { rx: 0.04 }), k(0.5, { rx: -0.1, rz: 0.06 }), k(1, { rx: 0.04 })],

    // Standing weight on the left leg; the right knee stays soft.
    thighL: [k(0, { rx: -0.02, rz: -0.03 }), k(0.5, { rx: 0.01 }), k(1, { rx: -0.02, rz: -0.03 })],
    thighR: [k(0, { rx: 0.05, rz: 0.05 }), k(0.5, { rx: 0.02 }), k(1, { rx: 0.05, rz: 0.05 })],
    shinL: [k(0, { rx: 0.03 }), k(0.5, { rx: 0.01 }), k(1, { rx: 0.03 })],
    shinR: [k(0, { rx: 0.12 }), k(0.5, { rx: 0.08 }), k(1, { rx: 0.12 })],
    footL: [k(0, { rx: 0 }), k(1, { rx: 0 })],
    footR: [k(0, { rx: -0.06 }), k(0.5, { rx: -0.04 }), k(1, { rx: -0.06 })],
    hair: [k(0, { rx: 0.02 }), k(0.5, { rx: -0.03 }), k(1, { rx: 0.02 })],
  },
};

// ------------------------------------------------------------------ walk

/**
 * Four-pose walk: contact, down, pass, up — then mirrored. The hips drop on
 * the down pose and rise on the pass; without that vertical the walk floats.
 */
export const WALK: Clip = {
  name: 'walk',
  duration: 1.0,
  loop: true,
  tracks: {
    hips: [
      k(0, { py: 0, ry: 0.1, rz: -0.03 }),
      k(0.125, { py: -0.035 }),
      k(0.25, { py: 0.015, rz: 0.04 }),
      k(0.5, { py: 0, ry: -0.1, rz: 0.03 }),
      k(0.625, { py: -0.035 }),
      k(0.75, { py: 0.015, rz: -0.04 }),
      k(1, { py: 0, ry: 0.1, rz: -0.03 }),
    ],
    spine: [k(0, { rx: 0.06, ry: -0.05 }), k(0.5, { rx: 0.06, ry: 0.05 }), k(1, { rx: 0.06, ry: -0.05 })],
    chest: [k(0, { ry: -0.09 }), k(0.5, { ry: 0.09 }), k(1, { ry: -0.09 })],
    neck: [k(0, { rx: 0.04 }), k(0.25, { rx: 0.01 }), k(0.75, { rx: 0.01 }), k(1, { rx: 0.04 })],
    head: [k(0, { ry: 0.05 }), k(0.5, { ry: -0.05 }), k(1, { ry: 0.05 })],

    // Arms counter-swing against the legs.
    armL: [k(0, { rx: -0.5, rz: -0.12 }), k(0.5, { rx: 0.42, rz: -0.16 }), k(1, { rx: -0.5, rz: -0.12 })],
    armR: [k(0, { rx: 0.42, rz: 0.16 }), k(0.5, { rx: -0.5, rz: 0.12 }), k(1, { rx: 0.42, rz: 0.16 })],
    forearmL: [k(0, { rx: -0.2 }), k(0.5, { rx: -0.55 }), k(1, { rx: -0.2 })],
    forearmR: [k(0, { rx: -0.55 }), k(0.5, { rx: -0.2 }), k(1, { rx: -0.55 })],
    handL: [k(0, { rx: 0.1 }), k(0.5, { rx: -0.12 }), k(1, { rx: 0.1 })],
    handR: [k(0, { rx: -0.12 }), k(0.5, { rx: 0.1 }), k(1, { rx: -0.12 })],

    thighL: [
      k(0, { rx: 0.52 }), // contact, heel forward
      k(0.25, { rx: 0.05 }), // passing under the body
      k(0.5, { rx: -0.42 }), // toe-off behind
      k(0.75, { rx: 0.02 }), // swinging through
      k(1, { rx: 0.52 }),
    ],
    shinL: [
      k(0, { rx: -0.06 }),
      k(0.15, { rx: -0.12 }),
      k(0.5, { rx: -0.12 }),
      k(0.7, { rx: -0.95 }), // knee bends hard on the swing
      k(0.85, { rx: -0.5 }),
      k(1, { rx: -0.06 }),
    ],
    footL: [
      k(0, { rx: -0.2 }),
      k(0.12, { rx: 0.06 }),
      k(0.45, { rx: 0.12 }),
      k(0.58, { rx: -0.42 }), // toe pushes off
      k(0.8, { rx: 0.1 }),
      k(1, { rx: -0.2 }),
    ],
    thighR: [
      k(0, { rx: -0.42 }),
      k(0.25, { rx: 0.02 }),
      k(0.5, { rx: 0.52 }),
      k(0.75, { rx: 0.05 }),
      k(1, { rx: -0.42 }),
    ],
    shinR: [
      k(0, { rx: -0.12 }),
      k(0.2, { rx: -0.95 }),
      k(0.35, { rx: -0.5 }),
      k(0.5, { rx: -0.06 }),
      k(0.65, { rx: -0.12 }),
      k(1, { rx: -0.12 }),
    ],
    footR: [
      k(0, { rx: 0.12 }),
      k(0.08, { rx: -0.42 }),
      k(0.3, { rx: 0.1 }),
      k(0.5, { rx: -0.2 }),
      k(0.62, { rx: 0.06 }),
      k(1, { rx: 0.12 }),
    ],
    hair: [k(0, { rx: -0.06 }), k(0.25, { rx: 0.08 }), k(0.75, { rx: 0.08 }), k(1, { rx: -0.06 })],
  },
};

// ------------------------------------------------------------------ run

/** Faster, lower, with a forward lean and a genuine airborne phase. */
export const RUN: Clip = {
  name: 'run',
  duration: 0.62,
  loop: true,
  tracks: {
    hips: [
      k(0, { py: 0.02, ry: 0.16, rz: -0.05 }),
      k(0.12, { py: -0.06 }), // impact compression
      k(0.3, { py: 0.05 }), // airborne
      k(0.5, { py: 0.02, ry: -0.16, rz: 0.05 }),
      k(0.62, { py: -0.06 }),
      k(0.8, { py: 0.05 }),
      k(1, { py: 0.02, ry: 0.16, rz: -0.05 }),
    ],
    spine: [k(0, { rx: 0.2, ry: -0.08 }), k(0.5, { rx: 0.2, ry: 0.08 }), k(1, { rx: 0.2, ry: -0.08 })],
    chest: [k(0, { rx: 0.06, ry: -0.15 }), k(0.5, { rx: 0.06, ry: 0.15 }), k(1, { rx: 0.06, ry: -0.15 })],
    neck: [k(0, { rx: -0.16 }), k(1, { rx: -0.16 })], // head stays level against the lean
    head: [k(0, { rx: -0.06, ry: 0.04 }), k(0.5, { rx: -0.06, ry: -0.04 }), k(1, { rx: -0.06, ry: 0.04 })],

    armL: [k(0, { rx: -1.05, rz: -0.2 }), k(0.5, { rx: 0.62, rz: -0.14 }), k(1, { rx: -1.05, rz: -0.2 })],
    armR: [k(0, { rx: 0.62, rz: 0.14 }), k(0.5, { rx: -1.05, rz: 0.2 }), k(1, { rx: 0.62, rz: 0.14 })],
    // Elbows stay bent near 90 degrees throughout a run.
    forearmL: [k(0, { rx: -1.5 }), k(0.5, { rx: -1.15 }), k(1, { rx: -1.5 })],
    forearmR: [k(0, { rx: -1.15 }), k(0.5, { rx: -1.5 }), k(1, { rx: -1.15 })],
    handL: [k(0, { rx: 0.15 }), k(0.5, { rx: -0.1 }), k(1, { rx: 0.15 })],
    handR: [k(0, { rx: -0.1 }), k(0.5, { rx: 0.15 }), k(1, { rx: -0.1 })],

    thighL: [k(0, { rx: 0.95 }), k(0.25, { rx: 0.1 }), k(0.5, { rx: -0.62 }), k(0.72, { rx: 0.25 }), k(1, { rx: 0.95 })],
    shinL: [k(0, { rx: -0.5 }), k(0.15, { rx: -0.2 }), k(0.5, { rx: -0.25 }), k(0.65, { rx: -1.75 }), k(0.85, { rx: -1.1 }), k(1, { rx: -0.5 })],
    footL: [k(0, { rx: -0.15 }), k(0.15, { rx: 0.15 }), k(0.5, { rx: -0.5 }), k(0.75, { rx: 0.2 }), k(1, { rx: -0.15 })],
    thighR: [k(0, { rx: -0.62 }), k(0.22, { rx: 0.25 }), k(0.5, { rx: 0.95 }), k(0.75, { rx: 0.1 }), k(1, { rx: -0.62 })],
    shinR: [k(0, { rx: -0.25 }), k(0.15, { rx: -1.75 }), k(0.35, { rx: -1.1 }), k(0.5, { rx: -0.5 }), k(0.65, { rx: -0.2 }), k(1, { rx: -0.25 })],
    footR: [k(0, { rx: -0.5 }), k(0.25, { rx: 0.2 }), k(0.5, { rx: -0.15 }), k(0.65, { rx: 0.15 }), k(1, { rx: -0.5 })],
    hair: [k(0, { rx: -0.22 }), k(0.3, { rx: -0.1 }), k(0.7, { rx: -0.26 }), k(1, { rx: -0.22 })],
  },
};

// ------------------------------------------------------------------ attacks

/**
 * Attack clips are authored in normalised time and then *time-scaled at play
 * time* to the move's real duration, so the visual contact frame always lands
 * on the sim's active window no matter how the frame data is retuned.
 *
 * Shape of every swing: anticipation (wind back), then a fast pass with the
 * hips leading the shoulders, then a settle. The hip lead is what makes a
 * punch look like it came from the body rather than the arm.
 */

/** Straight right cross. */
export const LIGHT_1: Clip = {
  name: 'light1',
  duration: 0.4,
  loop: false,
  mask: UPPER_BODY_MASK,
  tracks: {
    hips: [k(0, { ry: 0.12 }), k(0.25, { ry: 0.2 }), k(0.45, { ry: -0.3 }), k(1, { ry: -0.1 })],
    spine: [k(0, { ry: 0.14, rx: 0.05 }), k(0.25, { ry: 0.28 }), k(0.45, { ry: -0.42, rx: 0.12 }), k(1, { ry: -0.12, rx: 0.04 })],
    chest: [k(0, { ry: 0.18 }), k(0.25, { ry: 0.34 }), k(0.45, { ry: -0.5 }), k(1, { ry: -0.15 })],
    head: [k(0, { ry: -0.1 }), k(0.45, { ry: 0.18 }), k(1, { ry: 0.05 })],

    shoulderR: [k(0, { rz: 0.05 }), k(0.25, { rz: 0.16, ry: -0.1 }), k(0.45, { rz: -0.1, ry: 0.34 }), k(1, { rz: 0.03 })],
    armR: [
      k(0, { rx: -0.2, rz: 0.3 }),
      k(0.25, { rx: 0.5, rz: 0.5 }), // chamber
      k(0.45, { rx: -1.42, rz: 0.12 }), // extension
      k(0.62, { rx: -1.35, rz: 0.15 }),
      k(1, { rx: -0.1, rz: 0.25 }),
    ],
    forearmR: [k(0, { rx: -0.5 }), k(0.25, { rx: -1.7 }), k(0.45, { rx: -0.05 }), k(0.62, { rx: -0.12 }), k(1, { rx: -0.5 })],
    handR: [k(0, { rx: 0 }), k(0.42, { rx: 0.1, ry: -0.4 }), k(1, { rx: 0 })],

    shoulderL: [k(0, { rz: -0.05 }), k(0.45, { rz: -0.14 }), k(1, { rz: -0.04 })],
    armL: [k(0, { rx: -0.3, rz: -0.28 }), k(0.25, { rx: -0.75, rz: -0.2 }), k(0.45, { rx: -0.2, rz: -0.4 }), k(1, { rx: -0.05, rz: -0.22 })],
    forearmL: [k(0, { rx: -1.1 }), k(0.25, { rx: -1.6 }), k(0.45, { rx: -1.2 }), k(1, { rx: -0.6 })],
    hair: [k(0, { rx: 0 }), k(0.3, { rx: 0.18 }), k(0.5, { rx: -0.2 }), k(1, { rx: 0 })],
  },
};

/** Left hook — travels across the body on a horizontal arc. */
export const LIGHT_2: Clip = {
  name: 'light2',
  duration: 0.42,
  loop: false,
  mask: UPPER_BODY_MASK,
  tracks: {
    hips: [k(0, { ry: -0.12 }), k(0.24, { ry: -0.24 }), k(0.44, { ry: 0.32 }), k(1, { ry: 0.1 })],
    spine: [k(0, { ry: -0.16, rx: 0.06 }), k(0.24, { ry: -0.3 }), k(0.44, { ry: 0.46, rx: 0.14 }), k(1, { ry: 0.12, rx: 0.04 })],
    chest: [k(0, { ry: -0.2, rz: 0.04 }), k(0.24, { ry: -0.36 }), k(0.44, { ry: 0.52, rz: -0.08 }), k(1, { ry: 0.16 })],
    head: [k(0, { ry: 0.12 }), k(0.44, { ry: -0.2 }), k(1, { ry: -0.06 })],

    shoulderL: [k(0, { rz: -0.06 }), k(0.24, { rz: -0.2, ry: 0.12 }), k(0.44, { rz: 0.06, ry: -0.3 }), k(1, { rz: -0.05 })],
    armL: [
      k(0, { rx: -0.35, rz: -0.3 }),
      k(0.24, { rx: -0.2, rz: -0.95 }), // wound out to the side
      k(0.44, { rx: -0.85, rz: 0.25 }), // hook crosses the centre line
      k(0.6, { rx: -0.7, rz: 0.15 }),
      k(1, { rx: -0.1, rz: -0.24 }),
    ],
    forearmL: [k(0, { rx: -0.9 }), k(0.24, { rx: -1.5 }), k(0.44, { rx: -1.15 }), k(1, { rx: -0.55 })],
    handL: [k(0, { rx: 0 }), k(0.42, { rz: -0.35 }), k(1, { rx: 0 })],

    shoulderR: [k(0, { rz: 0.05 }), k(0.44, { rz: 0.16 }), k(1, { rz: 0.04 })],
    armR: [k(0, { rx: -0.15, rz: 0.28 }), k(0.24, { rx: -0.55, rz: 0.22 }), k(0.44, { rx: -0.3, rz: 0.42 }), k(1, { rx: -0.05, rz: 0.24 })],
    forearmR: [k(0, { rx: -0.6 }), k(0.24, { rx: -1.5 }), k(0.44, { rx: -1.25 }), k(1, { rx: -0.55 })],
    hair: [k(0, { rx: 0 }), k(0.3, { rx: 0.2, rz: 0.12 }), k(1, { rx: 0 })],
  },
};

/** Spinning back kick — the combo finisher, so it commits the whole body. */
export const LIGHT_3: Clip = {
  name: 'light3',
  duration: 0.67,
  loop: false,
  tracks: {
    hips: [
      k(0, { ry: 0.1, py: 0 }),
      k(0.2, { ry: -0.5, py: -0.06 }), // coil
      k(0.42, { ry: 1.5, py: 0.04 }), // spin through
      k(0.6, { ry: 2.1, py: 0 }),
      k(1, { ry: 0, py: 0 }),
    ],
    spine: [k(0, { rx: 0.05 }), k(0.2, { rx: 0.22 }), k(0.45, { rx: -0.3 }), k(1, { rx: 0.04 })],
    chest: [k(0, { ry: 0.1 }), k(0.2, { ry: -0.3 }), k(0.45, { ry: 0.4 }), k(1, { ry: 0 })],
    head: [k(0, { ry: 0 }), k(0.3, { ry: -0.5 }), k(0.5, { ry: 0.3 }), k(1, { ry: 0 })],

    armL: [k(0, { rx: -0.3, rz: -0.25 }), k(0.2, { rx: -0.6, rz: -0.9 }), k(0.45, { rx: -0.4, rz: -1.3 }), k(1, { rx: -0.05, rz: -0.22 })],
    armR: [k(0, { rx: -0.25, rz: 0.25 }), k(0.2, { rx: -0.9, rz: 0.5 }), k(0.45, { rx: -0.5, rz: 1.2 }), k(1, { rx: -0.05, rz: 0.22 })],
    forearmL: [k(0, { rx: -0.9 }), k(0.25, { rx: -1.9 }), k(1, { rx: -0.5 })],
    forearmR: [k(0, { rx: -0.9 }), k(0.25, { rx: -1.9 }), k(1, { rx: -0.5 })],

    thighR: [
      k(0, { rx: 0.05 }),
      k(0.2, { rx: -0.5 }), // load behind
      k(0.4, { rx: 0.4, rz: -0.5 }),
      k(0.5, { rx: 0.35, rz: -0.95 }), // extended kick
      k(0.68, { rx: 0.2, rz: -0.5 }),
      k(1, { rx: 0.05, rz: 0 }),
    ],
    shinR: [k(0, { rx: -0.1 }), k(0.2, { rx: -1.6 }), k(0.42, { rx: -1.5 }), k(0.5, { rx: -0.08 }), k(0.7, { rx: -0.6 }), k(1, { rx: -0.12 })],
    footR: [k(0, { rx: 0 }), k(0.5, { rx: -0.5 }), k(1, { rx: 0 })],
    thighL: [k(0, { rx: -0.02 }), k(0.2, { rx: 0.2 }), k(0.45, { rx: -0.15 }), k(1, { rx: -0.02 })],
    shinL: [k(0, { rx: -0.05 }), k(0.2, { rx: -0.45 }), k(0.45, { rx: -0.3 }), k(1, { rx: -0.05 })],
    hair: [k(0, { rx: 0 }), k(0.25, { rx: 0.3, ry: 0.3 }), k(0.5, { rx: -0.25, ry: -0.2 }), k(1, { rx: 0 })],
  },
};

/** Overhead two-handed smash. Big anticipation, hard stop, long recovery. */
export const HEAVY: Clip = {
  name: 'heavy',
  duration: 0.99,
  loop: false,
  tracks: {
    hips: [k(0, { py: 0, ry: 0.15 }), k(0.3, { py: -0.05, ry: 0.3 }), k(0.48, { py: -0.12, ry: -0.15 }), k(0.62, { py: -0.16 }), k(1, { py: 0, ry: 0 })],
    spine: [
      k(0, { rx: 0.05 }),
      k(0.3, { rx: -0.42, ry: 0.2 }), // arched back at full wind-up
      k(0.48, { rx: 0.55, ry: -0.1 }), // slammed forward
      k(0.62, { rx: 0.6 }),
      k(1, { rx: 0.05, ry: 0 }),
    ],
    chest: [k(0, { rx: -0.02 }), k(0.3, { rx: -0.3, ry: 0.25 }), k(0.48, { rx: 0.4, ry: -0.15 }), k(1, { rx: -0.02, ry: 0 })],
    neck: [k(0, { rx: 0 }), k(0.3, { rx: -0.25 }), k(0.5, { rx: 0.35 }), k(1, { rx: 0 })],
    head: [k(0, { rx: 0 }), k(0.3, { rx: -0.2 }), k(0.5, { rx: 0.3 }), k(1, { rx: 0 })],

    armL: [k(0, { rx: -0.3, rz: -0.25 }), k(0.3, { rx: -2.5, rz: -0.35 }), k(0.48, { rx: 0.35, rz: -0.2 }), k(0.62, { rx: 0.25 }), k(1, { rx: -0.05, rz: -0.22 })],
    armR: [k(0, { rx: -0.3, rz: 0.25 }), k(0.3, { rx: -2.5, rz: 0.35 }), k(0.48, { rx: 0.35, rz: 0.2 }), k(0.62, { rx: 0.25 }), k(1, { rx: -0.05, rz: 0.22 })],
    forearmL: [k(0, { rx: -0.8 }), k(0.3, { rx: -1.0 }), k(0.48, { rx: -0.1 }), k(1, { rx: -0.5 })],
    forearmR: [k(0, { rx: -0.8 }), k(0.3, { rx: -1.0 }), k(0.48, { rx: -0.1 }), k(1, { rx: -0.5 })],
    handL: [k(0, { rx: 0 }), k(0.3, { rx: -0.3 }), k(0.5, { rx: 0.4 }), k(1, { rx: 0 })],
    handR: [k(0, { rx: 0 }), k(0.3, { rx: -0.3 }), k(0.5, { rx: 0.4 }), k(1, { rx: 0 })],

    // Steps into the swing, then holds a deep braced stance.
    thighL: [k(0, { rx: 0 }), k(0.3, { rx: -0.3 }), k(0.48, { rx: 0.65 }), k(0.62, { rx: 0.7 }), k(1, { rx: 0 })],
    shinL: [k(0, { rx: -0.05 }), k(0.3, { rx: -0.15 }), k(0.48, { rx: -0.55 }), k(1, { rx: -0.05 })],
    footL: [k(0, { rx: 0 }), k(0.48, { rx: -0.25 }), k(1, { rx: 0 })],
    thighR: [k(0, { rx: 0 }), k(0.3, { rx: 0.3 }), k(0.48, { rx: -0.5 }), k(0.62, { rx: -0.55 }), k(1, { rx: 0 })],
    shinR: [k(0, { rx: -0.05 }), k(0.3, { rx: -0.4 }), k(0.48, { rx: -0.35 }), k(1, { rx: -0.05 })],
    footR: [k(0, { rx: 0 }), k(0.5, { rx: 0.3 }), k(1, { rx: 0 })],
    hair: [k(0, { rx: 0 }), k(0.3, { rx: -0.4 }), k(0.52, { rx: 0.45 }), k(0.7, { rx: -0.15 }), k(1, { rx: 0 })],
  },
};

/** Two-handed energy discharge — charge, brace, release, recoil. */
export const SPECIAL: Clip = {
  name: 'special',
  duration: 1.15,
  loop: false,
  tracks: {
    hips: [k(0, { py: 0, ry: 0.3 }), k(0.22, { py: -0.1, ry: 0.5 }), k(0.4, { py: -0.08, ry: 0.15 }), k(0.52, { py: -0.02, ry: 0 }), k(1, { py: 0, ry: 0 })],
    spine: [k(0, { rx: 0.05, ry: 0.25 }), k(0.22, { rx: 0.3, ry: 0.4 }), k(0.42, { rx: -0.15, ry: 0.1 }), k(0.55, { rx: -0.25 }), k(1, { rx: 0.05, ry: 0 })],
    chest: [k(0, { ry: 0.3 }), k(0.22, { ry: 0.45, rx: 0.15 }), k(0.45, { ry: 0.05, rx: -0.1 }), k(1, { ry: 0 })],
    neck: [k(0, { rx: 0.05 }), k(0.25, { rx: 0.15 }), k(0.5, { rx: -0.15 }), k(1, { rx: 0 })],
    head: [k(0, { ry: -0.25 }), k(0.3, { ry: -0.35 }), k(0.5, { ry: 0 }), k(1, { ry: 0 })],

    // Both hands cupped at the hip, then thrust forward together.
    armL: [k(0, { rx: -0.3, rz: -0.25 }), k(0.22, { rx: -0.5, rz: -0.55 }), k(0.45, { rx: -1.5, rz: -0.12 }), k(0.6, { rx: -1.45, rz: -0.14 }), k(1, { rx: -0.05, rz: -0.22 })],
    armR: [k(0, { rx: -0.3, rz: 0.25 }), k(0.22, { rx: -0.5, rz: 0.55 }), k(0.45, { rx: -1.5, rz: 0.12 }), k(0.6, { rx: -1.45, rz: 0.14 }), k(1, { rx: -0.05, rz: 0.22 })],
    forearmL: [k(0, { rx: -0.9 }), k(0.22, { rx: -1.85, ry: 0.4 }), k(0.45, { rx: -0.08 }), k(0.6, { rx: -0.12 }), k(1, { rx: -0.5 })],
    forearmR: [k(0, { rx: -0.9 }), k(0.22, { rx: -1.85, ry: -0.4 }), k(0.45, { rx: -0.08 }), k(0.6, { rx: -0.12 }), k(1, { rx: -0.5 })],
    handL: [k(0, { rx: 0 }), k(0.25, { rx: -0.5, rz: -0.3 }), k(0.45, { rx: 0.45 }), k(1, { rx: 0 })],
    handR: [k(0, { rx: 0 }), k(0.25, { rx: -0.5, rz: 0.3 }), k(0.45, { rx: 0.45 }), k(1, { rx: 0 })],

    thighL: [k(0, { rx: 0 }), k(0.22, { rx: 0.45, rz: 0.1 }), k(0.5, { rx: 0.3 }), k(1, { rx: 0 })],
    shinL: [k(0, { rx: -0.05 }), k(0.22, { rx: -0.7 }), k(0.5, { rx: -0.5 }), k(1, { rx: -0.05 })],
    thighR: [k(0, { rx: 0 }), k(0.22, { rx: -0.4, rz: -0.1 }), k(0.5, { rx: -0.3 }), k(1, { rx: 0 })],
    shinR: [k(0, { rx: -0.05 }), k(0.22, { rx: -0.45 }), k(0.5, { rx: -0.3 }), k(1, { rx: -0.05 })],
    hair: [k(0, { rx: 0 }), k(0.25, { rx: -0.35 }), k(0.5, { rx: 0.4 }), k(0.7, { rx: -0.1 }), k(1, { rx: 0 })],
  },
};

// ------------------------------------------------------------------ reactions

/** Forward shoulder roll. Tucks tight through the i-frame window. */
export const DODGE: Clip = {
  name: 'dodge',
  duration: 0.5,
  loop: false,
  tracks: {
    // The root spin is what sells the roll; the tuck keeps it from looking
    // like a stiff cartwheel.
    root: [k(0, { rx: 0 }), k(0.14, { rx: -0.6 }), k(0.5, { rx: -3.6 }), k(0.82, { rx: -6.28 }), k(1, { rx: -6.28 })],
    hips: [k(0, { py: 0 }), k(0.15, { py: -0.22 }), k(0.5, { py: -0.3 }), k(0.85, { py: -0.08 }), k(1, { py: 0 })],
    spine: [k(0, { rx: 0.1 }), k(0.2, { rx: 0.85 }), k(0.55, { rx: 1.05 }), k(0.85, { rx: 0.2 }), k(1, { rx: 0.05 })],
    chest: [k(0, { rx: 0 }), k(0.25, { rx: 0.5 }), k(0.6, { rx: 0.55 }), k(1, { rx: 0 })],
    neck: [k(0, { rx: 0 }), k(0.25, { rx: 0.6 }), k(0.6, { rx: 0.5 }), k(1, { rx: 0 })],

    armL: [k(0, { rx: -0.3, rz: -0.25 }), k(0.2, { rx: -1.5, rz: -0.5 }), k(0.55, { rx: -1.9, rz: -0.35 }), k(1, { rx: -0.05, rz: -0.22 })],
    armR: [k(0, { rx: -0.3, rz: 0.25 }), k(0.2, { rx: -1.5, rz: 0.5 }), k(0.55, { rx: -1.9, rz: 0.35 }), k(1, { rx: -0.05, rz: 0.22 })],
    forearmL: [k(0, { rx: -0.7 }), k(0.25, { rx: -2.1 }), k(1, { rx: -0.5 })],
    forearmR: [k(0, { rx: -0.7 }), k(0.25, { rx: -2.1 }), k(1, { rx: -0.5 })],

    thighL: [k(0, { rx: 0 }), k(0.2, { rx: 1.7 }), k(0.55, { rx: 1.9 }), k(0.85, { rx: 0.3 }), k(1, { rx: 0 })],
    thighR: [k(0, { rx: 0 }), k(0.2, { rx: 1.6 }), k(0.55, { rx: 1.95 }), k(0.85, { rx: 0.2 }), k(1, { rx: 0 })],
    shinL: [k(0, { rx: -0.05 }), k(0.2, { rx: -2.2 }), k(0.6, { rx: -2.3 }), k(1, { rx: -0.05 })],
    shinR: [k(0, { rx: -0.05 }), k(0.2, { rx: -2.2 }), k(0.6, { rx: -2.3 }), k(1, { rx: -0.05 })],
    footL: [k(0, { rx: 0 }), k(0.3, { rx: 0.4 }), k(1, { rx: 0 })],
    footR: [k(0, { rx: 0 }), k(0.3, { rx: 0.4 }), k(1, { rx: 0 })],
    hair: [k(0, { rx: 0 }), k(0.3, { rx: 0.7 }), k(0.7, { rx: -0.3 }), k(1, { rx: 0 })],
  },
};

/** Flinch. Short, sharp, and asymmetric so repeated hits don't look identical. */
export const HURT: Clip = {
  name: 'hurt',
  duration: 0.4,
  loop: false,
  tracks: {
    hips: [k(0, { py: 0, pz: 0 }), k(0.2, { py: -0.06, pz: -0.09 }), k(1, { py: 0, pz: 0 })],
    spine: [k(0, { rx: 0 }), k(0.18, { rx: -0.42, rz: 0.16 }), k(0.5, { rx: 0.12 }), k(1, { rx: 0.04 })],
    chest: [k(0, { rx: 0 }), k(0.18, { rx: -0.25, ry: 0.2 }), k(1, { rx: 0 })],
    neck: [k(0, { rx: 0 }), k(0.15, { rx: -0.45, rz: 0.2 }), k(1, { rx: 0 })],
    head: [k(0, { rx: 0 }), k(0.15, { rx: -0.3, ry: 0.25 }), k(1, { rx: 0 })],
    armL: [k(0, { rx: -0.3, rz: -0.25 }), k(0.2, { rx: -0.6, rz: -0.75 }), k(1, { rx: -0.05, rz: -0.22 })],
    armR: [k(0, { rx: -0.3, rz: 0.25 }), k(0.2, { rx: -0.5, rz: 0.6 }), k(1, { rx: -0.05, rz: 0.22 })],
    forearmL: [k(0, { rx: -0.7 }), k(0.2, { rx: -1.5 }), k(1, { rx: -0.5 })],
    forearmR: [k(0, { rx: -0.7 }), k(0.2, { rx: -1.3 }), k(1, { rx: -0.5 })],
    thighL: [k(0, { rx: 0 }), k(0.22, { rx: 0.3 }), k(1, { rx: 0 })],
    thighR: [k(0, { rx: 0 }), k(0.22, { rx: -0.2 }), k(1, { rx: 0 })],
    shinL: [k(0, { rx: -0.05 }), k(0.22, { rx: -0.5 }), k(1, { rx: -0.05 })],
    hair: [k(0, { rx: 0 }), k(0.18, { rx: -0.45 }), k(0.5, { rx: 0.2 }), k(1, { rx: 0 })],
  },
};

/** Collapse: knees buckle first, then the torso follows. Holds on the last key. */
export const DEATH: Clip = {
  name: 'death',
  duration: 1.1,
  loop: false,
  tracks: {
    root: [k(0, { rx: 0 }), k(0.55, { rx: 0.25 }), k(1, { rx: 1.35, py: -0.1 })],
    hips: [k(0, { py: 0 }), k(0.3, { py: -0.35 }), k(0.65, { py: -0.62 }), k(1, { py: -0.72 })],
    spine: [k(0, { rx: 0 }), k(0.2, { rx: -0.3 }), k(0.5, { rx: 0.5 }), k(1, { rx: 0.72 })],
    chest: [k(0, { rx: 0 }), k(0.25, { rx: -0.2 }), k(1, { rx: 0.42 })],
    neck: [k(0, { rx: 0 }), k(0.3, { rx: -0.4 }), k(1, { rx: 0.6 })],
    head: [k(0, { rx: 0 }), k(1, { rx: 0.35, rz: 0.25 })],
    armL: [k(0, { rx: -0.3, rz: -0.25 }), k(0.4, { rx: -0.9, rz: -0.8 }), k(1, { rx: 0.4, rz: -1.05 })],
    armR: [k(0, { rx: -0.3, rz: 0.25 }), k(0.4, { rx: -0.7, rz: 0.7 }), k(1, { rx: 0.35, rz: 0.95 })],
    forearmL: [k(0, { rx: -0.7 }), k(1, { rx: -0.25 })],
    forearmR: [k(0, { rx: -0.7 }), k(1, { rx: -0.3 })],
    thighL: [k(0, { rx: 0 }), k(0.35, { rx: 1.1 }), k(1, { rx: 1.5, rz: 0.3 })],
    thighR: [k(0, { rx: 0 }), k(0.35, { rx: 0.8 }), k(1, { rx: 1.15, rz: -0.2 })],
    shinL: [k(0, { rx: -0.05 }), k(0.35, { rx: -1.9 }), k(1, { rx: -2.1 })],
    shinR: [k(0, { rx: -0.05 }), k(0.35, { rx: -1.6 }), k(1, { rx: -1.85 })],
    hair: [k(0, { rx: 0 }), k(0.4, { rx: -0.3 }), k(1, { rx: 0.5 })],
  },
};

export const HUMANOID_CLIPS = {
  idle: IDLE,
  walk: WALK,
  run: RUN,
  light1: LIGHT_1,
  light2: LIGHT_2,
  light3: LIGHT_3,
  heavy: HEAVY,
  special: SPECIAL,
  dodge: DODGE,
  hurt: HURT,
  death: DEATH,
} as const;
