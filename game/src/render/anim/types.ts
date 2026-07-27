/**
 * Pose data is plain numbers, never THREE objects. Blending happens on these
 * values and is applied to the rig exactly once per frame, which is what makes
 * layered masked blending cheap and correct — writing transforms directly from
 * each layer would make the last writer win instead of blending.
 *
 * All rotations are radians, applied as deltas from the joint's bind pose.
 */
export interface JointPose {
  rx?: number;
  ry?: number;
  rz?: number;
  /** Positional offset from bind, in metres. Used sparingly (crouch, recoil). */
  px?: number;
  py?: number;
  pz?: number;
}

export interface Keyframe {
  /** Normalised clip time, 0..1. */
  t: number;
  pose: JointPose;
}

export type Track = Keyframe[];

export interface Clip {
  name: string;
  /** Seconds for one pass. Attack clips get time-scaled to match frame data. */
  duration: number;
  loop: boolean;
  tracks: Record<string, Track>;
  /**
   * Joints this clip is allowed to write. Omit for a full-body clip. An
   * upper-body attack declares a mask so the legs keep running underneath.
   */
  mask?: string[];
}

export const POSE_KEYS = ['rx', 'ry', 'rz', 'px', 'py', 'pz'] as const;
export type PoseKey = (typeof POSE_KEYS)[number];

/** Mutable pose accumulator, reused every frame to avoid per-frame allocation. */
export type PoseBuffer = Map<string, Required<JointPose>>;

export function emptyPose(): Required<JointPose> {
  return { rx: 0, ry: 0, rz: 0, px: 0, py: 0, pz: 0 };
}

export function resetPose(p: Required<JointPose>) {
  p.rx = 0;
  p.ry = 0;
  p.rz = 0;
  p.px = 0;
  p.py = 0;
  p.pz = 0;
}

/** Smootherstep — C2 continuous, so eased keyframes don't pop at the seams. */
export function ease(t: number): number {
  return t * t * t * (t * (t * 6 - 15) + 10);
}

/**
 * Samples one track at normalised time `t`, writing into `out` scaled by
 * `weight`. Keyframes are assumed sorted; tracks are short enough that a
 * linear scan beats any index bookkeeping.
 */
export function sampleTrack(
  track: Track,
  t: number,
  weight: number,
  out: Required<JointPose>,
) {
  if (track.length === 0) return;

  if (track.length === 1 || t <= track[0].t) {
    addPose(out, track[0].pose, weight);
    return;
  }
  const last = track[track.length - 1];
  if (t >= last.t) {
    addPose(out, last.pose, weight);
    return;
  }

  let i = 0;
  while (i < track.length - 2 && track[i + 1].t < t) i++;

  const a = track[i];
  const b = track[i + 1];
  const span = b.t - a.t;
  const local = span <= 0 ? 0 : ease((t - a.t) / span);

  for (const k of POSE_KEYS) {
    const av = a.pose[k] ?? 0;
    const bv = b.pose[k] ?? 0;
    if (av === 0 && bv === 0) continue;
    out[k] += (av + (bv - av) * local) * weight;
  }
}

function addPose(out: Required<JointPose>, pose: JointPose, weight: number) {
  for (const k of POSE_KEYS) {
    const v = pose[k];
    if (v) out[k] += v * weight;
  }
}
