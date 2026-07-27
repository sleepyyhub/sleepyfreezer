import type { MoveData } from '@/shared/types';

/**
 * Player frame data. All timings in seconds; at a 60 Hz fixed step these are
 * exact frame counts and identical on every machine.
 */
export const MOVES: Record<string, MoveData> = {
  light1: {
    id: 'light1',
    multiplier: 1.0,
    stagger: 14,
    element: 'physical',
    startupS: 0.1,
    activeS: 0.08,
    recoverS: 0.22,
    cancelAfterS: 0.18,
    range: 2.6,
    arcDeg: 100,
    staminaCost: 6,
    lungeM: 1.0,
    knockback: 1.0,
  },
  light2: {
    id: 'light2',
    multiplier: 1.05,
    stagger: 16,
    element: 'physical',
    startupS: 0.1,
    activeS: 0.08,
    recoverS: 0.24,
    cancelAfterS: 0.18,
    range: 2.6,
    arcDeg: 110,
    staminaCost: 6,
    lungeM: 1.1,
    knockback: 1.2,
  },
  light3: {
    id: 'light3',
    multiplier: 1.35,
    stagger: 30,
    element: 'physical',
    startupS: 0.15,
    activeS: 0.12,
    recoverS: 0.4,
    cancelAfterS: 0.2,
    range: 3.0,
    arcDeg: 130,
    staminaCost: 10,
    lungeM: 1.6,
    knockback: 4.5,
  },
  heavy: {
    id: 'heavy',
    multiplier: 2.2,
    // High stagger is what makes heavies the answer to bruisers; light-spam
    // fills the stagger meter too slowly to ever break one.
    stagger: 80,
    element: 'physical',
    startupS: 0.35,
    activeS: 0.14,
    recoverS: 0.5,
    cancelAfterS: 0.3,
    range: 3.4,
    arcDeg: 150,
    staminaCost: 22,
    lungeM: 1.8,
    knockback: 6,
  },
  special: {
    id: 'special',
    multiplier: 3.4,
    stagger: 120,
    element: 'energy',
    startupS: 0.3,
    activeS: 0.25,
    recoverS: 0.6,
    cancelAfterS: 0.75,
    range: 7.5,
    arcDeg: 60,
    staminaCost: 0,
    lungeM: 0,
    knockback: 8,
  },
};

export const COMBO_CHAIN: Record<string, string> = {
  light1: 'light2',
  light2: 'light3',
  light3: 'light1',
};

// ------------------------------------------------------------------ dodge

export const DODGE = {
  totalS: 0.5,
  /** i-frames run 0.10s-0.42s of the roll. */
  iframeStartS: 0.1,
  iframeEndS: 0.42,
  cancelAfterS: 0.3,
  distanceM: 5.0,
  staminaCost: 25,
  /**
   * Coyote window: a hit landing this soon *before* i-frames begin still
   * counts as dodged. Nobody notices it exists; everybody notices its absence.
   */
  coyoteS: 0.05,
};

export const SPECIAL_COOLDOWN_S = 8;

/**
 * Accept an input this far ahead of the cancel window and fire it the instant
 * the window opens. Without buffering, combos feel like dropped inputs.
 */
export const INPUT_BUFFER_S = 0.2;

/** Freeze both actors' animation briefly on a connect — cheap perceived weight. */
export const HITSTOP_S = 0.08;
export const HITSTOP_HEAVY_S = 0.12;
