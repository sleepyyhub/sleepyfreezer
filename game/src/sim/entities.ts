import type { EnemyDef, EnemyAttackDef, EntityId, Stats } from '@/shared/types';

export type PlayerAction = 'idle' | 'attack' | 'dodge' | 'hurt' | 'dead';

export interface PlayerEntity {
  id: EntityId;
  kind: 'player';
  x: number;
  y: number;
  z: number;
  vy: number;
  yaw: number;
  grounded: boolean;

  hp: number;
  stamina: number;
  stats: Stats;

  action: PlayerAction;
  /** Seconds elapsed inside the current action. */
  actionT: number;
  currentMove: string | null;
  comboNext: string;
  /** Entities already hit by the in-flight swing — one hit per swing each. */
  hitSet: Set<EntityId>;

  bufferedInput: string | null;
  bufferT: number;

  specialCooldown: number;
  invulnUntil: number;
  hurtLock: number;
  /** Timestamp of the most recent dodge start, for the coyote window. */
  lastDodgeStart: number;
}

export type AIState =
  | 'idle'
  | 'aggro'
  | 'windup'
  | 'attack'
  | 'recover'
  | 'stagger'
  | 'flee'
  | 'dead';

export interface EnemyEntity {
  id: EntityId;
  kind: 'enemy';
  defId: string;
  def: EnemyDef;
  spawnAnchorId: string | null;
  isBoss: boolean;

  x: number;
  y: number;
  z: number;
  yaw: number;
  homeX: number;
  homeZ: number;

  hp: number;
  maxHp: number;
  atk: number;
  def_: number;
  level: number;

  stagger: number;
  staggerMax: number;
  lastHitAt: number;

  state: AIState;
  stateT: number;
  /** Deliberate hesitation before committing to an attack. */
  reactionT: number;
  currentAttack: EnemyAttackDef | null;
  attackCooldowns: Record<string, number>;
  hasHitThisSwing: boolean;

  phase: number;
  deadAt: number;
  /** Small per-entity offset so a pack doesn't move as one rigid block. */
  strafeBias: number;
}

export type Entity = PlayerEntity | EnemyEntity;

let nextId = 1;
export const newEntityId = (): EntityId => nextId++;
export const resetEntityIds = () => {
  nextId = 1;
};

export function makeEnemy(
  def: EnemyDef,
  x: number,
  z: number,
  y: number,
  opts: { anchorId?: string | null; isBoss?: boolean; levelOverride?: number } = {},
): EnemyEntity {
  const level = opts.levelOverride ?? def.level;
  return {
    id: newEntityId(),
    kind: 'enemy',
    defId: def.id,
    def,
    spawnAnchorId: opts.anchorId ?? null,
    isBoss: opts.isBoss ?? false,

    x,
    y,
    z,
    yaw: 0,
    homeX: x,
    homeZ: z,

    hp: def.baseStats.hp,
    maxHp: def.baseStats.hp,
    atk: def.baseStats.atk,
    def_: def.baseStats.def,
    level,

    stagger: 0,
    staggerMax: def.baseStats.staggerMax,
    lastHitAt: -999,

    state: 'idle',
    stateT: 0,
    reactionT: 0,
    currentAttack: null,
    attackCooldowns: {},
    hasHitThisSwing: false,

    phase: 0,
    deadAt: 0,
    strafeBias: 0,
  };
}
