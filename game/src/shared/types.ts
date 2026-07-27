/**
 * Types shared by the simulation, the renderer, the UI and the content schemas.
 * This file must stay dependency-free — it is imported from every layer.
 */

export type EntityId = number;
export type Vec3 = { x: number; y: number; z: number };

export const vec3 = (x = 0, y = 0, z = 0): Vec3 => ({ x, y, z });

// ---------------------------------------------------------------- stats

export type StatKey = 'vit' | 'str' | 'end' | 'agi';

export interface Allocation {
  vit: number;
  str: number;
  end: number;
  agi: number;
}

export interface Stats {
  maxHp: number;
  atk: number;
  def: number;
  critChance: number;
  critMultiplier: number;
  maxStamina: number;
  staminaRegen: number;
}

// ---------------------------------------------------------------- combat

export type Element = 'physical' | 'energy' | 'nature';

export interface MoveData {
  id: string;
  /** Damage as a multiple of ATK. */
  multiplier: number;
  /** Stagger points applied on hit. */
  stagger: number;
  element: Element;
  /** Seconds from input to the first active frame. */
  startupS: number;
  /** Seconds the hitbox is live. */
  activeS: number;
  /** Seconds of lockout after the active window. */
  recoverS: number;
  /** Earliest point (seconds into the move) another action may cancel it. */
  cancelAfterS: number;
  /** Reach of the hit sphere, in metres, from the actor's chest. */
  range: number;
  /** Half-angle of the hit arc, in degrees. */
  arcDeg: number;
  staminaCost: number;
  /** Forward displacement applied over the startup window, in metres. */
  lungeM: number;
  knockback: number;
}

export interface DamageResult {
  amount: number;
  isCrit: boolean;
  stagger: number;
}

// ---------------------------------------------------------------- items

export type Rarity = 'common' | 'uncommon' | 'rare' | 'epic' | 'legendary';

export type EquipSlot =
  | 'weapon'
  | 'head'
  | 'chest'
  | 'hands'
  | 'legs'
  | 'accessory';

export interface ItemDef {
  id: string;
  name: string;
  /** `material` and `key` never occupy an equipment slot. */
  kind: 'equipment' | 'material' | 'key' | 'currency';
  slot?: EquipSlot;
  itemLevel: number;
  /** Base stat contribution before rarity multiplier and affixes. */
  base?: Partial<Stats>;
  description: string;
  stackable: boolean;
  world: string;
}

export interface Affix {
  id: string;
  label: string;
  stat: keyof Stats;
  value: number;
}

export interface ItemInstance {
  uid: string;
  defId: string;
  quantity: number;
  rarity: Rarity;
  affixes: Affix[];
  equippedSlot: EquipSlot | null;
}

// ---------------------------------------------------------------- content

export interface DropEntry {
  /** `null` is an explicit "nothing" outcome so weights read as true odds. */
  item: string | null;
  weight: number;
  rarityOverride?: Rarity;
  min?: number;
  max?: number;
}

export interface DropTable {
  id: string;
  currency: { min: number; max: number };
  guaranteed: { item: string; min: number; max: number }[];
  rolls: number;
  pool: DropEntry[];
  pityCounter?: { trackKey: string; after: number; grants: string };
}

export interface EnemyAttackDef {
  id: string;
  weight: number;
  windupS: number;
  activeS: number;
  recoverS: number;
  multiplier: number;
  range: number;
  arcDeg: number;
  stagger: number;
  cooldownS: number;
  telegraph: 'ring' | 'cone' | 'line';
  element: Element;
}

export type EnemyTier =
  | 'chaff'
  | 'standard'
  | 'bruiser'
  | 'caster'
  | 'elite'
  | 'midboss'
  | 'worldboss';

export interface BossPhase {
  hpAbove: number;
  attacks: string[];
  moveSpeed: number;
  damageMul?: number;
  onEnter?: string;
}

export interface EnemyDef {
  id: string;
  name: string;
  tier: EnemyTier;
  level: number;
  baseStats: { hp: number; atk: number; def: number; staggerMax: number };
  ai: {
    aggroRadius: number;
    leashRadius: number;
    attackRange: number;
    moveSpeed: number;
    turnSpeed: number;
    /** Deliberate hesitation before committing to an attack — see design doc. */
    reactionDelayS: number;
    fleeAtHpPct: number;
  };
  attacks: EnemyAttackDef[];
  phases?: BossPhase[];
  dropTable: string;
  /** Purely visual; consumed by the renderer's procedural mesh factory. */
  visual: { color: number; accent: number; scale: number; shape: string };
}

export type Condition =
  | { type: 'default' }
  | { type: 'level'; min: number }
  | { type: 'flag'; key: string }
  | { type: 'keyItem'; id: string }
  | { type: 'killCount'; zone: string; count: number }
  | { type: 'all'; conditions: Condition[] }
  | { type: 'any'; conditions: Condition[] };

export interface SpawnAnchor {
  id: string;
  anchor: [number, number, number];
  radius: number;
  pack: string[];
  respawnS: number;
}

export interface ZoneDef {
  id: string;
  displayName: string;
  levelRange: [number, number];
  /** Procedural terrain parameters, standing in for an authored GLB. */
  terrain: {
    size: number;
    heightScale: number;
    seed: number;
    segments: number;
    waterLevel: number;
  };
  props: { archetype: string; count: number; scaleRange: [number, number] }[];
  spawns: SpawnAnchor[];
  chests: { id: string; at: [number, number, number]; table: string }[];
  exits: { to: string; at: [number, number, number]; requires: Condition }[];
  boss?: { enemy: string; at: [number, number, number] };
}

export interface WorldPalette {
  ambient: string;
  ambientIntensity: number;
  keyLight: { color: string; intensity: number; elevation: number; azimuth: number };
  hemisphere: { sky: string; ground: string; intensity: number };
  fog: { color: string; density: number };
  rampStops: string[];
  exposure: number;
  water: string;
  terrainLow: string;
  terrainHigh: string;
}

export interface WorldDef {
  id: string;
  displayName: string;
  order: number;
  levelRange: [number, number];
  unlock: Condition;
  palette: WorldPalette;
  materials: { currency: string; craftMaterial: string };
  zones: ZoneDef[];
  completion: { grantsKeyItem: string };
}

// ---------------------------------------------------------------- character

export interface CharacterState {
  level: number;
  xp: number;
  statPoints: number;
  allocation: Allocation;
  currentWorld: string;
  currentZone: string;
  unlockedZones: string[];
  flags: Record<string, boolean>;
  kills: Record<string, number>;
  currencies: Record<string, number>;
  inventory: ItemInstance[];
  pity: Record<string, number>;
  playtimeS: number;
  saveVersion: number;
}
