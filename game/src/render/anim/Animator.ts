import type { Rig } from '../models/skeleton';
import {
  emptyPose,
  resetPose,
  sampleTrack,
  type Clip,
  type JointPose,
  type PoseBuffer,
} from './types';

interface PlayOptions {
  /** Cross-fade duration in seconds. 0 snaps. */
  fade?: number;
  /** Playback rate multiplier. Used to stretch attack clips onto frame data. */
  speed?: number;
  /** Restart from 0 even if this clip is already playing. */
  restart?: boolean;
}

interface Playing {
  clip: Clip;
  time: number;
  speed: number;
  /** Set once a non-looping clip has run past its end. */
  finished: boolean;
}

/**
 * One animation layer: a currently-playing clip plus an outgoing clip it is
 * cross-fading from. Two slots is enough — a third simultaneous blend is never
 * perceptible and the bookkeeping cost is real.
 */
class Layer {
  current: Playing | null = null;
  outgoing: Playing | null = null;
  fadeT = 0;
  fadeDuration = 0;
  /** Layer-wide weight, used to fade an action layer out entirely. */
  weight = 1;

  play(clip: Clip, opts: PlayOptions = {}) {
    const fade = opts.fade ?? 0.12;
    if (this.current?.clip === clip && !opts.restart) {
      this.current.speed = opts.speed ?? 1;
      return;
    }
    if (this.current && fade > 0) {
      this.outgoing = this.current;
      this.fadeT = 0;
      this.fadeDuration = fade;
    } else {
      this.outgoing = null;
      this.fadeT = 0;
      this.fadeDuration = 0;
    }
    this.current = { clip, time: 0, speed: opts.speed ?? 1, finished: false };
  }

  stop() {
    this.current = null;
    this.outgoing = null;
  }

  update(dt: number) {
    const advance = (p: Playing | null) => {
      if (!p) return;
      p.time += dt * p.speed;
      if (p.clip.loop) {
        if (p.clip.duration > 0) p.time %= p.clip.duration;
      } else if (p.time >= p.clip.duration) {
        p.time = p.clip.duration;
        p.finished = true;
      }
    };
    advance(this.current);
    advance(this.outgoing);

    if (this.outgoing) {
      this.fadeT += dt;
      if (this.fadeT >= this.fadeDuration) this.outgoing = null;
    }
  }

  /** Blend factor for the incoming clip, 0..1. */
  private incomingWeight(): number {
    if (!this.outgoing || this.fadeDuration <= 0) return 1;
    return Math.min(1, this.fadeT / this.fadeDuration);
  }

  writeInto(buffer: PoseBuffer, layerWeight: number) {
    if (!this.current || layerWeight <= 0) return;
    const w = this.incomingWeight();

    if (this.outgoing) {
      this.sample(this.outgoing, buffer, (1 - w) * layerWeight);
    }
    this.sample(this.current, buffer, w * layerWeight);
  }

  private sample(p: Playing, buffer: PoseBuffer, weight: number) {
    if (weight <= 0) return;
    const norm = p.clip.duration > 0 ? p.time / p.clip.duration : 0;
    for (const jointName of Object.keys(p.clip.tracks)) {
      let pose = buffer.get(jointName);
      if (!pose) {
        pose = emptyPose();
        buffer.set(jointName, pose);
      }
      sampleTrack(p.clip.tracks[jointName], norm, weight, pose);
    }
  }

  /** Joints this layer currently writes, honouring the clip's mask. */
  affectedJoints(out: Set<string>) {
    for (const p of [this.current, this.outgoing]) {
      if (!p) continue;
      const names = p.clip.mask ?? Object.keys(p.clip.tracks);
      for (const n of names) out.add(n);
    }
  }

  get isFinished(): boolean {
    return this.current?.finished ?? true;
  }

  get clipName(): string | null {
    return this.current?.clip.name ?? null;
  }

  /** Progress through the current clip, 0..1. */
  get progress(): number {
    if (!this.current || this.current.clip.duration <= 0) return 1;
    return Math.min(1, this.current.time / this.current.clip.duration);
  }
}

/**
 * Drives a rig from clips. Two layers:
 *   base   — locomotion, always playing, full body.
 *   action — attacks/dodge/hurt/death, overrides masked joints on top.
 *
 * The action layer's weight ramps rather than switching, so an attack blends
 * out of a run instead of snapping.
 */
export class Animator {
  readonly base = new Layer();
  readonly action = new Layer();

  private buffer: PoseBuffer = new Map();
  private baseBuffer: PoseBuffer = new Map();
  private actionJoints = new Set<string>();
  private actionWeight = 0;
  private actionTarget = 0;

  /** Procedural offsets applied after clips — look-at, lean, recoil. */
  readonly additive: Map<string, JointPose> = new Map();

  constructor(private rig: Rig) {
    for (const name of rig.joints.keys()) {
      this.buffer.set(name, emptyPose());
      this.baseBuffer.set(name, emptyPose());
    }
  }

  playBase(clip: Clip, opts?: PlayOptions) {
    this.base.play(clip, opts);
  }

  /** Starts an action clip and ramps the action layer in. */
  playAction(clip: Clip, opts?: PlayOptions) {
    this.action.play(clip, opts);
    this.actionTarget = 1;
  }

  /** Ramps the action layer out; the base layer takes over as it fades. */
  clearAction(fade = 0.15) {
    this.actionTarget = 0;
    this.actionFadeRate = fade > 0 ? 1 / fade : Infinity;
  }

  private actionFadeRate = 8;

  get actionClip(): string | null {
    return this.action.clipName;
  }

  get actionFinished(): boolean {
    return this.action.isFinished;
  }

  get actionProgress(): number {
    return this.action.progress;
  }

  update(dt: number) {
    this.base.update(dt);
    this.action.update(dt);

    // Ramp the action layer toward its target rather than switching, so the
    // transition out of an attack blends back into locomotion.
    const rate = this.actionTarget > this.actionWeight ? 14 : this.actionFadeRate;
    this.actionWeight += (this.actionTarget - this.actionWeight) * (1 - Math.exp(-rate * dt));
    if (Math.abs(this.actionTarget - this.actionWeight) < 0.002) {
      this.actionWeight = this.actionTarget;
    }

    for (const pose of this.buffer.values()) resetPose(pose);
    for (const pose of this.baseBuffer.values()) resetPose(pose);

    this.actionJoints.clear();
    if (this.actionWeight > 0) this.action.affectedJoints(this.actionJoints);

    // Base first into its own buffer, then action into the main buffer, then
    // blend per joint by the action weight. Joints outside the action's mask
    // keep the base pose at full strength.
    this.base.writeInto(this.baseBuffer, 1);
    if (this.actionWeight > 0) this.action.writeInto(this.buffer, 1);

    this.apply();
  }

  private apply() {
    for (const [name, joint] of this.rig.joints) {
      const basePose = this.baseBuffer.get(name);
      const actionPose = this.buffer.get(name);
      const w = this.actionJoints.has(name) ? this.actionWeight : 0;
      const add = this.additive.get(name);

      const mix = (key: 'rx' | 'ry' | 'rz' | 'px' | 'py' | 'pz') => {
        const b = basePose ? basePose[key] : 0;
        const a = actionPose ? actionPose[key] : 0;
        const blended = b * (1 - w) + a * w;
        return blended + (add?.[key] ?? 0);
      };

      joint.rotation.set(
        joint.bindRotation.x + mix('rx'),
        joint.bindRotation.y + mix('ry'),
        joint.bindRotation.z + mix('rz'),
      );
      joint.position.set(
        joint.bindPosition.x + mix('px'),
        joint.bindPosition.y + mix('py'),
        joint.bindPosition.z + mix('pz'),
      );
    }
  }

  /** Sets a procedural offset on a joint, layered on top of all clips. */
  setAdditive(joint: string, pose: JointPose | null) {
    if (pose === null) this.additive.delete(joint);
    else this.additive.set(joint, pose);
  }

  clearAdditive() {
    this.additive.clear();
  }
}
