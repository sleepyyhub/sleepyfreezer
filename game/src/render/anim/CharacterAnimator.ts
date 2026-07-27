import type { EnemyEntity, PlayerEntity } from '@/sim/entities';
import { MOVES, DODGE } from '@/sim/moves';
import { Animator } from './Animator';
import type { Rig } from '../models/skeleton';
import type { Clip } from './types';
import { HUMANOID_CLIPS } from './clips/humanoid';
import { INSECT_CLIPS } from './clips/insect';
import { GOLEM_CLIPS, WARDEN_CLIPS } from './clips/bipeds';

const WALK_SPEED = 2.2;
const RUN_SPEED = 5.4;

/**
 * Maps simulation state onto clips. The important rule: an action clip is
 * *time-scaled* to the move's real duration, so the visual contact frame
 * always lands on the sim's active window. Retuning frame data then never
 * desyncs the animation from the hitbox.
 */
export class PlayerAnimator {
  private anim: Animator;
  private lastAction: string | null = null;
  private lastMove: string | null = null;
  private smoothedSpeed = 0;

  constructor(rig: Rig) {
    this.anim = new Animator(rig);
    this.anim.playBase(HUMANOID_CLIPS.idle, { fade: 0 });
  }

  update(p: PlayerEntity, speed: number, dt: number, aimYawOffset: number) {
    // Locomotion blend. Smoothing the speed stops a single-frame stutter in
    // the sim from flickering between walk and run.
    this.smoothedSpeed += (speed - this.smoothedSpeed) * (1 - Math.exp(-12 * dt));
    this.updateLocomotion(p);
    this.updateAction(p);
    this.updateProcedural(p, aimYawOffset);
    this.anim.update(dt);
  }

  private updateLocomotion(p: PlayerEntity) {
    if (p.action === 'dead') return;
    const s = this.smoothedSpeed;

    if (s < 0.35) {
      this.anim.playBase(HUMANOID_CLIPS.idle, { fade: 0.25 });
    } else if (s < WALK_SPEED + 1.4) {
      // Cycle rate tracks ground speed, so feet don't skate.
      this.anim.playBase(HUMANOID_CLIPS.walk, {
        fade: 0.2,
        speed: Math.max(0.55, s / WALK_SPEED),
      });
    } else {
      this.anim.playBase(HUMANOID_CLIPS.run, {
        fade: 0.18,
        speed: Math.max(0.7, s / RUN_SPEED),
      });
    }
  }

  private updateAction(p: PlayerEntity) {
    const changed = p.action !== this.lastAction || p.currentMove !== this.lastMove;
    this.lastAction = p.action;
    this.lastMove = p.currentMove;

    if (p.action === 'dead') {
      if (changed) this.anim.playAction(HUMANOID_CLIPS.death, { fade: 0.1 });
      return;
    }

    if (p.action === 'attack' && p.currentMove) {
      if (!changed) return;
      const clip = HUMANOID_CLIPS[p.currentMove as keyof typeof HUMANOID_CLIPS] as Clip | undefined;
      if (!clip) return;
      const mv = MOVES[p.currentMove];
      const moveDuration = mv.startupS + mv.activeS + mv.recoverS;
      this.anim.playAction(clip, {
        fade: 0.07,
        speed: clip.duration / moveDuration,
        restart: true,
      });
      return;
    }

    if (p.action === 'dodge') {
      if (changed) {
        this.anim.playAction(HUMANOID_CLIPS.dodge, {
          fade: 0.05,
          speed: HUMANOID_CLIPS.dodge.duration / DODGE.totalS,
          restart: true,
        });
      }
      return;
    }

    if (p.action === 'hurt') {
      if (changed) this.anim.playAction(HUMANOID_CLIPS.hurt, { fade: 0.04, restart: true });
      return;
    }

    if (changed) this.anim.clearAction(0.16);
  }

  /**
   * Procedural layer on top of the clips: the torso leans into movement and
   * the head turns toward the lock-on target. Authoring these as keyframes is
   * impossible — they depend on runtime state.
   */
  private updateProcedural(p: PlayerEntity, aimYawOffset: number) {
    if (p.action === 'dead') {
      this.anim.clearAdditive();
      return;
    }
    const leanAmount = Math.min(1, this.smoothedSpeed / RUN_SPEED);
    this.anim.setAdditive('spine', { rx: leanAmount * 0.1 });

    const look = clamp(aimYawOffset, -0.7, 0.7);
    this.anim.setAdditive('neck', { ry: look * 0.35 });
    this.anim.setAdditive('head', { ry: look * 0.45 });
  }

  get animator(): Animator {
    return this.anim;
  }
}

/** Enemy clip sets, keyed by rig family. */
const ENEMY_CLIP_SETS = {
  insect: INSECT_CLIPS as unknown as Record<string, Clip>,
  golem: GOLEM_CLIPS as unknown as Record<string, Clip>,
  warden: WARDEN_CLIPS as unknown as Record<string, Clip>,
  humanoid: HUMANOID_CLIPS as unknown as Record<string, Clip>,
} as const;

export class EnemyAnimator {
  private anim: Animator;
  private clips: Record<string, Clip>;
  private lastState: string | null = null;
  private lastAttack: string | null = null;
  private lastPhase = 0;
  private smoothedSpeed = 0;
  private prevX: number;
  private prevZ: number;

  constructor(rig: Rig, e: EnemyEntity) {
    this.anim = new Animator(rig);
    this.clips = ENEMY_CLIP_SETS[rig.family] ?? ENEMY_CLIP_SETS.humanoid;
    this.prevX = e.x;
    this.prevZ = e.z;
    this.anim.playBase(this.clips.idle, { fade: 0 });
  }

  update(e: EnemyEntity, dt: number) {
    const moved = Math.hypot(e.x - this.prevX, e.z - this.prevZ);
    this.prevX = e.x;
    this.prevZ = e.z;
    const speed = dt > 0 ? moved / dt : 0;
    this.smoothedSpeed += (speed - this.smoothedSpeed) * (1 - Math.exp(-10 * dt));

    this.updateLocomotion(e);
    this.updateAction(e);
    this.anim.update(dt);
  }

  private updateLocomotion(e: EnemyEntity) {
    if (e.state === 'dead') return;
    const s = this.smoothedSpeed;
    const cruise = e.def.ai.moveSpeed;

    if (s < 0.25) {
      this.anim.playBase(this.clips.idle, { fade: 0.3 });
    } else if (s < cruise * 0.75 || !this.clips.run) {
      this.anim.playBase(this.clips.walk, { fade: 0.22, speed: clamp(s / cruise, 0.5, 1.8) });
    } else {
      this.anim.playBase(this.clips.run, { fade: 0.18, speed: clamp(s / cruise, 0.6, 1.7) });
    }
  }

  private updateAction(e: EnemyEntity) {
    // Boss phase transitions get their own one-shot, which the sim already
    // holds the enemy in 'recover' for.
    if (e.isBoss && e.phase !== this.lastPhase) {
      this.lastPhase = e.phase;
      const roar = this.clips.roar;
      if (roar) {
        this.anim.playAction(roar, { fade: 0.12, restart: true });
        this.lastState = 'phase';
        return;
      }
    }

    const stateChanged = e.state !== this.lastState;
    const attackChanged = (e.currentAttack?.id ?? null) !== this.lastAttack;
    this.lastState = e.state;
    this.lastAttack = e.currentAttack?.id ?? null;

    switch (e.state) {
      case 'dead':
        if (stateChanged) this.anim.playAction(this.clips.death, { fade: 0.1, restart: true });
        return;

      case 'stagger':
        if (stateChanged) {
          this.anim.playAction(this.clips.stagger ?? this.clips.hurt, { fade: 0.08 });
        }
        return;

      case 'windup':
      case 'attack':
      case 'recover': {
        if (!e.currentAttack) return;
        // Start the clip once, at windup, and let it run through the strike.
        if (!stateChanged && !attackChanged) return;
        if (e.state !== 'windup' && !attackChanged) return;

        const atk = e.currentAttack;
        const clip = this.clips[atk.id] ?? this.clips.attack;
        if (!clip) return;
        const total = atk.windupS + atk.activeS + atk.recoverS;
        this.anim.playAction(clip, {
          fade: 0.08,
          speed: clip.duration / Math.max(0.1, total),
          restart: e.state === 'windup',
        });
        return;
      }

      default:
        if (stateChanged) this.anim.clearAction(0.2);
    }
  }

  /** Plays the hurt reaction without disturbing the current action clip. */
  flinch(e: EnemyEntity) {
    if (e.state === 'dead' || e.state === 'stagger') return;
    // Never interrupt a committed swing — a boss that flinches out of its own
    // telegraph is unreadable and unfair.
    if (e.state === 'windup' || e.state === 'attack') return;
    if (this.clips.hurt) {
      this.anim.playAction(this.clips.hurt, { fade: 0.04, restart: true });
      this.lastState = 'flinch';
    }
  }

  get animator(): Animator {
    return this.anim;
  }
}

function clamp(v: number, lo: number, hi: number): number {
  return v < lo ? lo : v > hi ? hi : v;
}
