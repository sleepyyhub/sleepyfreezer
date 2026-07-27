import type {
  CharacterState,
  EnemyAttackDef,
  EnemyDef,
  ItemDef,
  ZoneDef,
} from '@/shared/types';
import { RNG, hashSeed, weightedPick } from './rng';
import { Terrain } from './terrain';
import {
  COMBO_CHAIN,
  DODGE,
  HITSTOP_HEAVY_S,
  HITSTOP_S,
  INPUT_BUFFER_S,
  MOVES,
  SPECIAL_COOLDOWN_S,
} from './moves';
import {
  computeDamage,
  STAGGER_DECAY_DELAY_S,
  STAGGER_DECAY_PER_S,
  STAGGER_DURATION_S,
  xpForKill,
} from './formulas';
import {
  EnemyEntity,
  PlayerEntity,
  makeEnemy,
  newEntityId,
  resetEntityIds,
} from './entities';
import { rollTable } from './loot';
import { bus } from '@/core/EventBus';

export interface InputIntent {
  moveX: number;
  moveZ: number;
  light: boolean;
  heavy: boolean;
  dodge: boolean;
  special: boolean;
  interact: boolean;
  lockOn: boolean;
}

export const EMPTY_INTENT: InputIntent = {
  moveX: 0,
  moveZ: 0,
  light: false,
  heavy: false,
  dodge: false,
  special: false,
  interact: false,
  lockOn: false,
};

export interface ChestState {
  id: string;
  x: number;
  y: number;
  z: number;
  table: string;
  opened: boolean;
}

export interface SpawnGroupState {
  id: string;
  respawnAt: number;
  alive: number;
}

const PLAYER_SPEED = 6.4;
const PLAYER_RADIUS = 0.5;
const ENEMY_RADIUS = 0.7;
const GRAVITY = 26;
const MAX_SLOPE = 1.4;
const INTERACT_RANGE = 3.2;
const BOSS_TRIGGER_RANGE = 18;

export interface WorldDeps {
  zone: ZoneDef;
  character: CharacterState;
  itemDefs: Map<string, ItemDef>;
  dropTables: Map<string, import('@/shared/types').DropTable>;
  getEnemyDef: (id: string) => EnemyDef;
}

/**
 * The authoritative game state. Contains no reference to three.js: the
 * renderer observes this, never the reverse.
 */
export class SimWorld {
  readonly terrain: Terrain;
  readonly zone: ZoneDef;
  player: PlayerEntity;
  enemies: EnemyEntity[] = [];
  chests: ChestState[] = [];
  spawnGroups = new Map<string, SpawnGroupState>();

  time = 0;
  hitstopUntil = 0;
  paused = false;
  lockOnTarget: number | null = null;

  private deps: WorldDeps;
  private rng: RNG;
  private killCounter = 0;
  private bossSpawned = false;
  private character: CharacterState;

  constructor(deps: WorldDeps) {
    resetEntityIds();
    this.deps = deps;
    this.zone = deps.zone;
    this.character = deps.character;
    this.terrain = new Terrain(deps.zone.terrain);
    this.rng = new RNG(hashSeed(deps.zone.id, 'sim'));

    this.player = {
      id: newEntityId(),
      kind: 'player',
      x: 0,
      y: this.terrain.heightAt(0, 0),
      z: 0,
      vy: 0,
      yaw: 0,
      grounded: true,
      hp: 1,
      stamina: 1,
      stats: {
        maxHp: 1,
        atk: 1,
        def: 0,
        critChance: 0,
        critMultiplier: 1.5,
        maxStamina: 100,
        staminaRegen: 18,
      },
      action: 'idle',
      actionT: 0,
      currentMove: null,
      comboNext: 'light1',
      hitSet: new Set(),
      bufferedInput: null,
      bufferT: 0,
      specialCooldown: 0,
      invulnUntil: -1,
      hurtLock: 0,
      lastDodgeStart: -999,
    };

    this.buildZone();
  }

  // ---------------------------------------------------------------- setup

  private buildZone() {
    for (const s of this.zone.spawns) {
      this.spawnGroups.set(s.id, { id: s.id, respawnAt: 0, alive: 0 });
      this.spawnPack(s.id);
    }
    for (const c of this.zone.chests) {
      this.chests.push({
        id: c.id,
        x: c.at[0],
        z: c.at[2],
        y: this.terrain.heightAt(c.at[0], c.at[2]),
        table: c.table,
        opened: false,
      });
    }
  }

  private spawnPack(anchorId: string) {
    const spawn = this.zone.spawns.find((s) => s.id === anchorId);
    const group = this.spawnGroups.get(anchorId);
    if (!spawn || !group) return;

    spawn.pack.forEach((enemyId, i) => {
      const angle = (i / spawn.pack.length) * Math.PI * 2 + this.rng.next();
      const r = spawn.radius * (0.35 + this.rng.next() * 0.5);
      const { x, z } = this.terrain.clampToBounds(
        spawn.anchor[0] + Math.cos(angle) * r,
        spawn.anchor[2] + Math.sin(angle) * r,
      );
      const def = this.deps.getEnemyDef(enemyId);
      const e = makeEnemy(def, x, z, this.terrain.heightAt(x, z), { anchorId });
      e.strafeBias = this.rng.range(-1, 1);
      this.enemies.push(e);
    });
    group.alive = spawn.pack.length;
  }

  /** Called when the player walks into the boss trigger radius. */
  private spawnBoss() {
    const b = this.zone.boss;
    if (!b || this.bossSpawned) return;
    this.bossSpawned = true;
    const def = this.deps.getEnemyDef(b.enemy);
    const y = this.terrain.heightAt(b.at[0], b.at[2]);
    const e = makeEnemy(def, b.at[0], b.at[2], y, { isBoss: true });
    e.state = 'aggro';
    this.enemies.push(e);
    bus.emit('bossEngaged', { name: def.name, maxHp: e.maxHp });
  }

  /** Push updated derived stats in from the UI store after a level or gear change. */
  syncPlayerStats(stats: PlayerEntity['stats'], healToFull = false) {
    const prevMax = this.player.stats.maxHp;
    this.player.stats = stats;
    if (healToFull || this.player.hp <= 0) {
      this.player.hp = stats.maxHp;
      this.player.stamina = stats.maxStamina;
    } else if (stats.maxHp > prevMax) {
      // Gear that raises max HP grants the difference rather than diluting the bar.
      this.player.hp = Math.min(stats.maxHp, this.player.hp + (stats.maxHp - prevMax));
    } else {
      this.player.hp = Math.min(this.player.hp, stats.maxHp);
    }
  }

  respawnPlayer() {
    const p = this.player;
    p.x = 0;
    p.z = 0;
    p.y = this.terrain.heightAt(0, 0);
    p.hp = p.stats.maxHp;
    p.stamina = p.stats.maxStamina;
    p.action = 'idle';
    p.actionT = 0;
    p.currentMove = null;
    p.hitSet.clear();
    p.invulnUntil = this.time + 2;
    // Wipe aggro so the player is not immediately re-killed on the spawn pad.
    for (const e of this.enemies) {
      if (e.state !== 'dead') {
        e.state = 'idle';
        e.stateT = 0;
        e.currentAttack = null;
      }
    }
  }

  // ---------------------------------------------------------------- step

  step(dt: number, intent: InputIntent) {
    if (this.paused) return;
    this.time += dt;

    // Hitstop freezes actors, not the clock — timers keep advancing so the
    // freeze can end, but no movement or state transitions occur.
    const frozen = this.time < this.hitstopUntil;

    this.updatePlayer(dt, intent, frozen);
    if (!frozen) {
      this.updateEnemies(dt);
      this.updateSpawns();
    }
    this.updateBossTrigger();
    if (intent.interact) this.tryInteract();
    if (intent.lockOn) this.cycleLockOn();
    this.cleanupDead();
  }

  // ---------------------------------------------------------------- player

  private updatePlayer(dt: number, intent: InputIntent, frozen: boolean) {
    const p = this.player;
    if (p.action === 'dead') return;

    p.specialCooldown = Math.max(0, p.specialCooldown - dt);
    p.hurtLock = Math.max(0, p.hurtLock - dt);

    // Input buffering: remember the last attack press briefly so it fires the
    // instant the current action becomes cancellable.
    const pressed = intent.special
      ? 'special'
      : intent.heavy
        ? 'heavy'
        : intent.light
          ? 'light'
          : intent.dodge
            ? 'dodge'
            : null;
    if (pressed) {
      p.bufferedInput = pressed;
      p.bufferT = INPUT_BUFFER_S;
    } else if (p.bufferT > 0) {
      p.bufferT -= dt;
      if (p.bufferT <= 0) p.bufferedInput = null;
    }

    if (frozen) return;

    p.actionT += dt;

    switch (p.action) {
      case 'attack':
        this.tickAttack(dt);
        break;
      case 'dodge':
        this.tickDodge(dt);
        break;
      case 'hurt':
        if (p.hurtLock <= 0) p.action = 'idle';
        break;
      case 'idle':
        break;
    }

    if (this.canAct()) this.consumeBufferedInput(intent);
    if (this.canMove()) this.movePlayer(dt, intent);

    // Stamina only regenerates when not mid-swing, which is what makes the
    // heavy/dodge economy a real decision.
    if (p.action === 'idle') {
      p.stamina = Math.min(p.stats.maxStamina, p.stamina + p.stats.staminaRegen * dt);
    }

    this.applyGravity(p, dt);
  }

  private canAct(): boolean {
    const p = this.player;
    if (p.action === 'idle') return true;
    if (p.action === 'hurt' || p.action === 'dead') return false;
    if (p.action === 'dodge') return p.actionT >= DODGE.cancelAfterS;
    if (p.action === 'attack' && p.currentMove) {
      return p.actionT >= MOVES[p.currentMove].cancelAfterS;
    }
    return false;
  }

  private canMove(): boolean {
    const p = this.player;
    if (p.action === 'idle') return true;
    if (p.action === 'attack' && p.currentMove) {
      const mv = MOVES[p.currentMove];
      // Free to move again once the recovery tail starts.
      return p.actionT >= mv.startupS + mv.activeS + mv.recoverS * 0.55;
    }
    return false;
  }

  private consumeBufferedInput(_intent: InputIntent) {
    const p = this.player;
    if (!p.bufferedInput) return;
    const want = p.bufferedInput;

    if (want === 'dodge') {
      if (p.stamina >= DODGE.staminaCost) {
        this.startDodge();
        p.bufferedInput = null;
      }
      return;
    }
    if (want === 'special') {
      if (p.specialCooldown <= 0) {
        this.startAttack('special');
        p.specialCooldown = SPECIAL_COOLDOWN_S;
        p.bufferedInput = null;
      }
      return;
    }
    if (want === 'heavy') {
      if (p.stamina >= MOVES.heavy.staminaCost) {
        this.startAttack('heavy');
        p.bufferedInput = null;
      }
      return;
    }
    if (want === 'light') {
      const next =
        p.action === 'attack' && p.currentMove && COMBO_CHAIN[p.currentMove]
          ? COMBO_CHAIN[p.currentMove]
          : 'light1';
      if (p.stamina >= MOVES[next].staminaCost) {
        this.startAttack(next);
        p.bufferedInput = null;
      }
    }
  }

  private startAttack(moveId: string) {
    const p = this.player;
    const mv = MOVES[moveId];
    p.action = 'attack';
    p.actionT = 0;
    p.currentMove = moveId;
    p.hitSet.clear();
    p.stamina = Math.max(0, p.stamina - mv.staminaCost);

    // Face the lock-on target, else keep current facing.
    const target = this.lockOnTarget
      ? this.enemies.find((e) => e.id === this.lockOnTarget && e.state !== 'dead')
      : this.nearestEnemy(p.x, p.z, 6);
    if (target) p.yaw = Math.atan2(target.x - p.x, target.z - p.z);
  }

  private tickAttack(dt: number) {
    const p = this.player;
    if (!p.currentMove) {
      p.action = 'idle';
      return;
    }
    const mv = MOVES[p.currentMove];

    // Lunge is applied across the startup window only.
    if (p.actionT < mv.startupS && mv.lungeM > 0) {
      const step = (mv.lungeM / mv.startupS) * dt;
      this.tryMove(p, Math.sin(p.yaw) * step, Math.cos(p.yaw) * step, PLAYER_RADIUS);
    }

    const activeStart = mv.startupS;
    const activeEnd = mv.startupS + mv.activeS;
    if (p.actionT >= activeStart && p.actionT <= activeEnd) {
      this.resolvePlayerHits(mv);
    }

    if (p.actionT >= activeEnd + mv.recoverS) {
      p.action = 'idle';
      p.actionT = 0;
      p.currentMove = null;
    }
  }

  private resolvePlayerHits(mv: (typeof MOVES)[string]) {
    const p = this.player;
    const cos = Math.cos((mv.arcDeg / 2) * (Math.PI / 180));

    for (const e of this.enemies) {
      if (e.state === 'dead' || p.hitSet.has(e.id)) continue;

      const dx = e.x - p.x;
      const dz = e.z - p.z;
      const dist = Math.hypot(dx, dz);
      if (dist > mv.range + ENEMY_RADIUS) continue;

      if (dist > 0.001) {
        const dot = (dx / dist) * Math.sin(p.yaw) + (dz / dist) * Math.cos(p.yaw);
        if (dot < cos) continue;
      }

      p.hitSet.add(e.id);
      this.damageEnemy(e, mv, dx, dz, dist);
    }
  }

  private damageEnemy(
    e: EnemyEntity,
    mv: (typeof MOVES)[string],
    dx: number,
    dz: number,
    dist: number,
  ) {
    const p = this.player;
    const wasStaggered = e.state === 'stagger';
    const result = computeDamage(
      {
        atk: p.stats.atk,
        critChance: p.stats.critChance,
        critMultiplier: p.stats.critMultiplier,
      },
      { def: e.def_, staggered: wasStaggered },
      mv,
      this.rng,
    );

    e.hp -= result.amount;
    e.lastHitAt = this.time;
    bus.emit('damage', {
      at: { x: e.x, y: e.y + 1.2, z: e.z },
      amount: result.amount,
      isCrit: result.isCrit,
      onPlayer: false,
    });

    this.hitstopUntil = Math.max(
      this.hitstopUntil,
      this.time + (mv.multiplier >= 2 ? HITSTOP_HEAVY_S : HITSTOP_S),
    );
    bus.emit('hitstop', { seconds: mv.multiplier >= 2 ? HITSTOP_HEAVY_S : HITSTOP_S });

    if (e.hp <= 0) {
      this.killEnemy(e);
      return;
    }

    // Aggro on damage even from outside the aggro radius.
    if (e.state === 'idle') e.state = 'aggro';

    e.stagger += result.stagger;
    if (e.stagger >= e.staggerMax && e.state !== 'stagger') {
      e.state = 'stagger';
      e.stateT = 0;
      e.stagger = 0;
      e.currentAttack = null;
      bus.emit('staggered', { at: { x: e.x, y: e.y + 1.5, z: e.z } });
    }

    if (mv.knockback > 0 && dist > 0.001 && !e.isBoss) {
      const k = (mv.knockback * 0.12) / Math.max(1, e.def.visual.scale);
      this.tryMove(e, (dx / dist) * k, (dz / dist) * k, ENEMY_RADIUS);
    }
  }

  private killEnemy(e: EnemyEntity) {
    e.state = 'dead';
    e.hp = 0;
    e.deadAt = this.time;

    const group = e.spawnAnchorId ? this.spawnGroups.get(e.spawnAnchorId) : null;
    if (group) group.alive = Math.max(0, group.alive - 1);

    const xp = xpForKill(e.level, this.character.level, e.def.tier);

    // Seeding per kill makes drops reproducible from a bug report and immune
    // to save-scumming by reload.
    const lootRng = new RNG(
      hashSeed(this.zone.id, e.defId, this.killCounter++, this.character.level),
    );
    const table = this.deps.dropTables.get(e.def.dropTable);
    const loot = table
      ? rollTable(table, this.deps.itemDefs, lootRng, this.character.pity)
      : { drops: [], currency: 0 };

    bus.emit('enemyKilled', {
      enemyId: e.defId,
      at: { x: e.x, y: e.y, z: e.z },
      xp,
      drops: loot.drops,
      currency: loot.currency,
      isBoss: e.isBoss,
    });

    if (e.isBoss) bus.emit('bossDisengaged', {});
    if (this.lockOnTarget === e.id) this.lockOnTarget = null;
  }

  // ---------------------------------------------------------------- dodge

  private startDodge() {
    const p = this.player;
    p.action = 'dodge';
    p.actionT = 0;
    p.currentMove = null;
    p.hitSet.clear();
    p.stamina = Math.max(0, p.stamina - DODGE.staminaCost);
    p.lastDodgeStart = this.time;
    p.invulnUntil = this.time + DODGE.iframeEndS;
  }

  private tickDodge(dt: number) {
    const p = this.player;
    // Ease-out displacement so the roll starts fast and settles.
    const progress = Math.min(1, p.actionT / DODGE.totalS);
    const speed = (DODGE.distanceM / DODGE.totalS) * (1.6 - progress * 1.2);
    this.tryMove(
      p,
      Math.sin(p.yaw) * speed * dt,
      Math.cos(p.yaw) * speed * dt,
      PLAYER_RADIUS,
    );
    if (p.actionT >= DODGE.totalS) {
      p.action = 'idle';
      p.actionT = 0;
    }
  }

  private isPlayerInvulnerable(): boolean {
    const p = this.player;
    if (this.time < p.invulnUntil) return true;
    // Coyote window: a hit landing just before i-frames open still counts.
    const sinceDodge = this.time - p.lastDodgeStart;
    return (
      sinceDodge >= DODGE.iframeStartS - DODGE.coyoteS && sinceDodge <= DODGE.iframeEndS
    );
  }

  // ---------------------------------------------------------------- movement

  private movePlayer(dt: number, intent: InputIntent) {
    const p = this.player;
    const len = Math.hypot(intent.moveX, intent.moveZ);
    if (len < 0.01) return;

    const nx = intent.moveX / len;
    const nz = intent.moveZ / len;
    const speed = PLAYER_SPEED * (p.action === 'attack' ? 0.35 : 1);

    this.tryMove(p, nx * speed * dt, nz * speed * dt, PLAYER_RADIUS);

    // Facing follows movement unless locked on.
    const target = this.lockOnTarget
      ? this.enemies.find((e) => e.id === this.lockOnTarget && e.state !== 'dead')
      : null;
    const desiredYaw = target
      ? Math.atan2(target.x - p.x, target.z - p.z)
      : Math.atan2(nx, nz);
    p.yaw = turnToward(p.yaw, desiredYaw, 14 * dt);
  }

  /**
   * Kinematic move with axis-separated sliding, slope limiting and entity
   * separation. No physics engine: an action-RPG character that can be shoved
   * by a rigid body feels broken.
   */
  private tryMove(
    ent: PlayerEntity | EnemyEntity,
    dx: number,
    dz: number,
    radius: number,
  ) {
    const attempt = (ax: number, az: number): boolean => {
      const tx = ent.x + ax;
      const tz = ent.z + az;
      const clamped = this.terrain.clampToBounds(tx, tz);
      if (Math.abs(clamped.x - tx) > 0.001 || Math.abs(clamped.z - tz) > 0.001) {
        return false;
      }
      if (this.terrain.slopeAt(tx, tz) > MAX_SLOPE) return false;
      if (this.terrain.isWater(tx, tz)) return false;
      if (this.overlapsEntity(ent, tx, tz, radius)) return false;
      ent.x = tx;
      ent.z = tz;
      return true;
    };

    // Try the full move, then each axis alone — this is what produces sliding
    // along a wall instead of sticking to it.
    if (!attempt(dx, dz)) {
      attempt(dx, 0);
      attempt(0, dz);
    }
    ent.y = this.terrain.heightAt(ent.x, ent.z);
  }

  private overlapsEntity(
    self: PlayerEntity | EnemyEntity,
    x: number,
    z: number,
    radius: number,
  ): boolean {
    for (const e of this.enemies) {
      if (e.id === self.id || e.state === 'dead') continue;
      const r = radius + ENEMY_RADIUS * e.def.visual.scale * 0.6;
      if ((e.x - x) ** 2 + (e.z - z) ** 2 < r * r) return true;
    }
    if (self.id !== this.player.id) {
      const r = radius + PLAYER_RADIUS;
      if ((this.player.x - x) ** 2 + (this.player.z - z) ** 2 < r * r) return true;
    }
    return false;
  }

  private applyGravity(p: PlayerEntity, dt: number) {
    const ground = this.terrain.heightAt(p.x, p.z);
    if (p.y > ground + 0.05) {
      p.vy -= GRAVITY * dt;
      p.y += p.vy * dt;
      if (p.y <= ground) {
        p.y = ground;
        p.vy = 0;
        p.grounded = true;
      }
    } else {
      p.y = ground;
      p.vy = 0;
      p.grounded = true;
    }
  }

  // ---------------------------------------------------------------- enemy AI

  private updateEnemies(dt: number) {
    const p = this.player;
    for (const e of this.enemies) {
      if (e.state === 'dead') continue;

      e.stateT += dt;
      for (const k of Object.keys(e.attackCooldowns)) {
        e.attackCooldowns[k] = Math.max(0, e.attackCooldowns[k] - dt);
      }

      // Stagger decays only after a grace period without being hit.
      if (this.time - e.lastHitAt > STAGGER_DECAY_DELAY_S && e.stagger > 0) {
        e.stagger = Math.max(0, e.stagger - STAGGER_DECAY_PER_S * dt);
      }

      if (e.isBoss) this.updateBossPhase(e);

      const dist = Math.hypot(p.x - e.x, p.z - e.z);
      const playerAlive = p.action !== 'dead';

      switch (e.state) {
        case 'idle': {
          if (playerAlive && dist <= e.def.ai.aggroRadius) {
            e.state = 'aggro';
            e.stateT = 0;
            e.reactionT = e.def.ai.reactionDelayS;
          }
          break;
        }

        case 'aggro': {
          if (!playerAlive) {
            e.state = 'idle';
            break;
          }
          const fromHome = Math.hypot(e.x - e.homeX, e.z - e.homeZ);
          if (fromHome > e.def.ai.leashRadius) {
            e.state = 'flee';
            e.stateT = 0;
            break;
          }
          if (
            e.def.ai.fleeAtHpPct > 0 &&
            e.hp / e.maxHp < e.def.ai.fleeAtHpPct &&
            e.stateT > 1
          ) {
            e.state = 'flee';
            e.stateT = 0;
            break;
          }

          this.faceTarget(e, p.x, p.z, dt);

          if (dist > e.def.ai.attackRange * 0.85) {
            this.moveEnemyToward(e, p.x, p.z, dt, e.def.ai.moveSpeed);
            e.reactionT = e.def.ai.reactionDelayS;
          } else {
            // In range: hesitate, then commit. The hesitation is the opening.
            e.reactionT -= dt;
            if (e.reactionT <= 0) {
              const attack = this.pickAttack(e);
              if (attack) {
                e.currentAttack = attack;
                e.hasHitThisSwing = false;
                e.state = 'windup';
                e.stateT = 0;
              } else {
                // Everything on cooldown — circle instead of standing still.
                this.strafe(e, p.x, p.z, dt);
              }
            }
          }
          break;
        }

        case 'windup': {
          this.faceTarget(e, p.x, p.z, dt * 0.4);
          if (e.currentAttack && e.stateT >= e.currentAttack.windupS) {
            e.state = 'attack';
            e.stateT = 0;
          }
          break;
        }

        case 'attack': {
          if (!e.currentAttack) {
            e.state = 'aggro';
            break;
          }
          if (!e.hasHitThisSwing) this.resolveEnemyHit(e, e.currentAttack);
          if (e.stateT >= e.currentAttack.activeS) {
            e.state = 'recover';
            e.stateT = 0;
            e.attackCooldowns[e.currentAttack.id] = e.currentAttack.cooldownS;
          }
          break;
        }

        case 'recover': {
          if (!e.currentAttack || e.stateT >= e.currentAttack.recoverS) {
            e.currentAttack = null;
            e.state = 'aggro';
            e.stateT = 0;
            e.reactionT = e.def.ai.reactionDelayS;
          }
          break;
        }

        case 'stagger': {
          if (e.stateT >= STAGGER_DURATION_S) {
            e.state = 'aggro';
            e.stateT = 0;
            e.reactionT = e.def.ai.reactionDelayS;
          }
          break;
        }

        case 'flee': {
          this.moveEnemyToward(e, e.homeX, e.homeZ, dt, e.def.ai.moveSpeed * 1.1);
          const home = Math.hypot(e.x - e.homeX, e.z - e.homeZ);
          if (home < 2) {
            e.state = 'idle';
            e.stateT = 0;
            // Leashing home restores the pack, so a kite-and-reset loop is
            // never a viable strategy.
            e.hp = e.maxHp;
            e.stagger = 0;
          }
          break;
        }
      }
    }
  }

  private updateBossPhase(e: EnemyEntity) {
    const phases = e.def.phases;
    if (!phases) return;
    const pct = e.hp / e.maxHp;
    // Phases are ordered by descending threshold; the active one is the first
    // whose threshold the current HP fraction still sits above.
    let idx = phases.findIndex((ph) => pct > ph.hpAbove);
    if (idx === -1) idx = phases.length - 1;

    if (idx > e.phase) {
      e.phase = idx;
      // Phase transitions are a stagger-immune beat: the player gets a moment
      // to read the new state instead of being punished for the transition.
      e.state = 'recover';
      e.stateT = -2.0;
      e.currentAttack = { ...e.def.attacks[0], activeS: 0, recoverS: 2.0 };
      e.stagger = 0;
      bus.emit('bossPhase', { phase: idx + 1, name: e.def.name });
      bus.emit('toast', { text: `${e.def.name} — Phase ${idx + 1}`, tone: 'bad' });
    }
  }

  private pickAttack(e: EnemyEntity): EnemyAttackDef | null {
    const phase = e.def.phases?.[e.phase];
    const allowed = phase
      ? e.def.attacks.filter((a) => phase.attacks.includes(a.id))
      : e.def.attacks;
    const ready = allowed.filter((a) => (e.attackCooldowns[a.id] ?? 0) <= 0);
    if (ready.length === 0) return null;
    return weightedPick(ready, this.rng);
  }

  private resolveEnemyHit(e: EnemyEntity, atk: EnemyAttackDef) {
    const p = this.player;
    if (p.action === 'dead') return;

    const dx = p.x - e.x;
    const dz = p.z - e.z;
    const dist = Math.hypot(dx, dz);
    if (dist > atk.range + PLAYER_RADIUS) return;

    if (atk.arcDeg < 360 && dist > 0.001) {
      const cos = Math.cos((atk.arcDeg / 2) * (Math.PI / 180));
      const dot = (dx / dist) * Math.sin(e.yaw) + (dz / dist) * Math.cos(e.yaw);
      if (dot < cos) return;
    }

    e.hasHitThisSwing = true;

    if (this.isPlayerInvulnerable()) {
      bus.emit('dodgeSuccess', { at: { x: p.x, y: p.y + 1, z: p.z } });
      return;
    }

    const damageMul = e.def.phases?.[e.phase]?.damageMul ?? 1;
    const result = computeDamage(
      { atk: e.atk, critChance: 0.05, critMultiplier: 1.5, damageMul },
      { def: p.stats.def },
      { multiplier: atk.multiplier, stagger: atk.stagger, element: atk.element },
      this.rng,
    );

    p.hp -= result.amount;
    bus.emit('damage', {
      at: { x: p.x, y: p.y + 1.6, z: p.z },
      amount: result.amount,
      isCrit: result.isCrit,
      onPlayer: true,
    });

    if (p.hp <= 0) {
      p.hp = 0;
      p.action = 'dead';
      p.actionT = 0;
      bus.emit('playerDied', {});
      return;
    }

    // Interrupt whatever the player was doing, with brief mercy invulnerability.
    p.action = 'hurt';
    p.actionT = 0;
    p.currentMove = null;
    p.hurtLock = 0.28;
    p.invulnUntil = this.time + 0.35;
  }

  private faceTarget(e: EnemyEntity, tx: number, tz: number, dt: number) {
    const desired = Math.atan2(tx - e.x, tz - e.z);
    e.yaw = turnToward(e.yaw, desired, e.def.ai.turnSpeed * dt);
  }

  private moveEnemyToward(
    e: EnemyEntity,
    tx: number,
    tz: number,
    dt: number,
    speed: number,
  ) {
    const dx = tx - e.x;
    const dz = tz - e.z;
    const d = Math.hypot(dx, dz);
    if (d < 0.01) return;
    const phaseSpeed = e.def.phases?.[e.phase]?.moveSpeed ?? speed;
    const s = (e.isBoss ? phaseSpeed : speed) * dt;
    this.tryMove(e, (dx / d) * s, (dz / d) * s, ENEMY_RADIUS);
  }

  private strafe(e: EnemyEntity, tx: number, tz: number, dt: number) {
    const dx = tx - e.x;
    const dz = tz - e.z;
    const d = Math.hypot(dx, dz) || 1;
    // Perpendicular to the player direction, sign from the per-entity bias.
    const px = -dz / d;
    const pz = dx / d;
    const s = e.def.ai.moveSpeed * 0.6 * dt * Math.sign(e.strafeBias || 1);
    this.tryMove(e, px * s, pz * s, ENEMY_RADIUS);
  }

  // ---------------------------------------------------------------- world

  private updateSpawns() {
    for (const [id, group] of this.spawnGroups) {
      if (group.alive > 0) continue;
      if (group.respawnAt === 0) {
        const spawn = this.zone.spawns.find((s) => s.id === id);
        group.respawnAt = this.time + (spawn?.respawnS ?? 90);
      } else if (this.time >= group.respawnAt) {
        // Don't repopulate a pack the player is standing in.
        const spawn = this.zone.spawns.find((s) => s.id === id);
        if (spawn) {
          const d = Math.hypot(
            this.player.x - spawn.anchor[0],
            this.player.z - spawn.anchor[2],
          );
          if (d < spawn.radius + 12) continue;
        }
        this.enemies = this.enemies.filter((e) => e.spawnAnchorId !== id);
        group.respawnAt = 0;
        this.spawnPack(id);
      }
    }
  }

  private updateBossTrigger() {
    const b = this.zone.boss;
    if (!b || this.bossSpawned) return;
    const d = Math.hypot(this.player.x - b.at[0], this.player.z - b.at[2]);
    if (d < BOSS_TRIGGER_RANGE) this.spawnBoss();
  }

  private tryInteract() {
    const p = this.player;
    for (const c of this.chests) {
      if (c.opened) continue;
      if (Math.hypot(c.x - p.x, c.z - p.z) > INTERACT_RANGE) continue;

      c.opened = true;
      const table = this.deps.dropTables.get(c.table);
      if (!table) return;
      const rng = new RNG(hashSeed(this.zone.id, c.id, this.character.level));
      const loot = rollTable(table, this.deps.itemDefs, rng, this.character.pity);
      bus.emit('chestOpened', {
        chestId: c.id,
        drops: loot.drops,
        currency: loot.currency,
      });
      return;
    }
  }

  private cycleLockOn() {
    const p = this.player;
    const candidates = this.enemies
      .filter((e) => e.state !== 'dead')
      .filter((e) => Math.hypot(e.x - p.x, e.z - p.z) < 24)
      .sort(
        (a, b) =>
          Math.hypot(a.x - p.x, a.z - p.z) - Math.hypot(b.x - p.x, b.z - p.z),
      );
    if (candidates.length === 0) {
      this.lockOnTarget = null;
      return;
    }
    const idx = candidates.findIndex((e) => e.id === this.lockOnTarget);
    this.lockOnTarget = candidates[(idx + 1) % candidates.length].id;
  }

  private nearestEnemy(x: number, z: number, maxDist: number): EnemyEntity | null {
    let best: EnemyEntity | null = null;
    let bestD = maxDist;
    for (const e of this.enemies) {
      if (e.state === 'dead') continue;
      const d = Math.hypot(e.x - x, e.z - z);
      if (d < bestD) {
        bestD = d;
        best = e;
      }
    }
    return best;
  }

  private cleanupDead() {
    // Keep corpses around briefly so the death animation can play out.
    if (this.enemies.some((e) => e.state === 'dead' && this.time - e.deadAt > 2.5)) {
      this.enemies = this.enemies.filter(
        (e) => !(e.state === 'dead' && this.time - e.deadAt > 2.5),
      );
    }
  }

  // ---------------------------------------------------------------- queries

  nearestInteractable(): ChestState | null {
    const p = this.player;
    for (const c of this.chests) {
      if (c.opened) continue;
      if (Math.hypot(c.x - p.x, c.z - p.z) <= INTERACT_RANGE) return c;
    }
    return null;
  }

  activeBoss(): EnemyEntity | null {
    return this.enemies.find((e) => e.isBoss && e.state !== 'dead') ?? null;
  }
}

/** Shortest-arc angular step, so facing never spins the long way round. */
export function turnToward(current: number, target: number, maxStep: number): number {
  let diff = target - current;
  while (diff > Math.PI) diff -= Math.PI * 2;
  while (diff < -Math.PI) diff += Math.PI * 2;
  if (Math.abs(diff) <= maxStep) return target;
  return current + Math.sign(diff) * maxStep;
}
