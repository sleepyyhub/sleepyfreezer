/**
 * Every number that decides an outcome lives here. Pure functions only — no
 * imports from `three`, no globals, no time. This is the file the unit tests
 * cover and the file that would run unchanged in a server-side validator.
 */
import type {
  Allocation,
  DamageResult,
  Element,
  ItemDef,
  ItemInstance,
  MoveData,
  Rarity,
  Stats,
} from '@/shared/types';
import type { RNG } from './rng';

// ------------------------------------------------------------------ leveling

/** Total XP needed to reach level L. L2:100 L10:5,297 L15:12,673 L30:56,461 */
export function xpToReach(level: number): number {
  if (level <= 1) return 0;
  return Math.floor(100 * Math.pow(level - 1, 1.85));
}

/** XP needed to go from `level` to `level + 1`. */
export function xpForNextLevel(level: number): number {
  return xpToReach(level + 1) - xpToReach(level);
}

export const TIER_XP_MULTIPLIER: Record<string, number> = {
  chaff: 0.6,
  standard: 1.0,
  caster: 1.4,
  bruiser: 1.8,
  elite: 3.5,
  midboss: 25,
  worldboss: 80,
};

/**
 * Kill XP with a level-difference falloff. Farming trivial content is
 * discouraged but never hard-blocked — the floor is 1 XP, not 0.
 */
export function xpForKill(
  enemyLevel: number,
  playerLevel: number,
  tier: string,
): number {
  const tierMul = TIER_XP_MULTIPLIER[tier] ?? 1;
  const base = 12 * Math.pow(enemyLevel, 1.4) * tierMul;
  const diff = enemyLevel - playerLevel;
  const falloff = diff >= -2 ? 1 : diff >= -5 ? 0.6 : diff >= -8 ? 0.25 : 0.05;
  return Math.max(1, Math.floor(base * falloff));
}

/** Applies XP and returns how many levels were gained. */
export function applyXp(
  level: number,
  xp: number,
  gained: number,
): { level: number; xp: number; levelsGained: number } {
  let newXp = xp + gained;
  let newLevel = level;
  while (newLevel < MAX_LEVEL && newXp >= xpToReach(newLevel + 1)) {
    newLevel++;
  }
  if (newLevel >= MAX_LEVEL) newXp = Math.min(newXp, xpToReach(MAX_LEVEL));
  return { level: newLevel, xp: newXp, levelsGained: newLevel - level };
}

export const MAX_LEVEL = 30;
export const STAT_POINTS_PER_LEVEL = 3;
export const CRIT_CHANCE_CAP = 0.6;

// ------------------------------------------------------------------ stats

export function statsForLevel(level: number, a: Allocation): Stats {
  const l = level - 1;
  return {
    maxHp: Math.floor(100 + l * 18 + a.vit * 12),
    atk: Math.floor(10 + l * 2.4 + a.str * 1.8),
    def: Math.floor(5 + l * 1.6 + a.end * 1.4),
    critChance: Math.min(0.05 + a.agi * 0.004, CRIT_CHANCE_CAP),
    critMultiplier: 1.5 + a.agi * 0.006,
    maxStamina: 100 + a.end * 3,
    staminaRegen: 18 + a.end * 0.25,
  };
}

const EMPTY_STATS: Stats = {
  maxHp: 0,
  atk: 0,
  def: 0,
  critChance: 0,
  critMultiplier: 0,
  maxStamina: 0,
  staminaRegen: 0,
};

export const RARITY_MULTIPLIER: Record<Rarity, number> = {
  common: 1.0,
  uncommon: 1.15,
  rare: 1.35,
  epic: 1.65,
  legendary: 2.0,
};

export const RARITY_AFFIX_COUNT: Record<Rarity, number> = {
  common: 0,
  uncommon: 1,
  rare: 2,
  epic: 3,
  legendary: 3,
};

/** Contribution of a single equipped item, rarity multiplier and affixes applied. */
export function itemStats(inst: ItemInstance, def: ItemDef): Stats {
  const out: Stats = { ...EMPTY_STATS };
  const mul = RARITY_MULTIPLIER[inst.rarity];
  if (def.base) {
    for (const k of Object.keys(def.base) as (keyof Stats)[]) {
      out[k] = (def.base[k] ?? 0) * mul;
    }
  }
  for (const affix of inst.affixes) {
    out[affix.stat] = (out[affix.stat] ?? 0) + affix.value;
  }
  return out;
}

/** Base stats plus every equipped item. Crit chance is capped after summing. */
export function totalStats(
  level: number,
  allocation: Allocation,
  equipped: { inst: ItemInstance; def: ItemDef }[],
): Stats {
  const base = statsForLevel(level, allocation);
  for (const e of equipped) {
    const s = itemStats(e.inst, e.def);
    base.maxHp += s.maxHp;
    base.atk += s.atk;
    base.def += s.def;
    base.critChance += s.critChance;
    base.critMultiplier += s.critMultiplier;
    base.maxStamina += s.maxStamina;
    base.staminaRegen += s.staminaRegen;
  }
  base.maxHp = Math.floor(base.maxHp);
  base.atk = Math.floor(base.atk);
  base.def = Math.floor(base.def);
  base.critChance = Math.min(base.critChance, CRIT_CHANCE_CAP);
  return base;
}

// ------------------------------------------------------------------ damage

/** Mitigation constant: DEF equal to K halves incoming damage. */
export const MITIGATION_K = 100;

export function mitigation(def: number): number {
  return MITIGATION_K / (MITIGATION_K + Math.max(0, def));
}

export function elementalModifier(
  element: Element,
  resistances: Partial<Record<Element, number>> | undefined,
): number {
  if (!resistances) return 1;
  const r = resistances[element];
  return r === undefined ? 1 : Math.max(0.25, 1 - r);
}

export interface AttackerLike {
  atk: number;
  critChance: number;
  critMultiplier: number;
  damageMul?: number;
}

export interface DefenderLike {
  def: number;
  resistances?: Partial<Record<Element, number>>;
  /** Staggered targets take amplified damage — the payoff for heavy attacks. */
  staggered?: boolean;
}

export const STAGGERED_DAMAGE_MULTIPLIER = 1.5;

export function computeDamage(
  a: AttackerLike,
  d: DefenderLike,
  mv: Pick<MoveData, 'multiplier' | 'stagger' | 'element'>,
  rng: RNG,
): DamageResult {
  const base = a.atk * mv.multiplier * (a.damageMul ?? 1);

  // Asymptotic mitigation: never reaches 100%, never produces negative damage,
  // and small DEF gains stay predictable at every level.
  const mitigated = base * mitigation(d.def);

  const isCrit = rng.next() < Math.min(a.critChance, CRIT_CHANCE_CAP);
  const crit = isCrit ? a.critMultiplier : 1;
  const variance = 0.92 + rng.next() * 0.16;
  const elem = elementalModifier(mv.element, d.resistances);
  const staggerAmp = d.staggered ? STAGGERED_DAMAGE_MULTIPLIER : 1;

  const raw = mitigated * crit * variance * elem * staggerAmp;

  return {
    // Floor of 1: a zero-damage hit always reads as a bug to the player.
    amount: Math.max(1, Math.round(raw)),
    isCrit,
    stagger: mv.stagger * (isCrit ? 1.5 : 1),
  };
}

// ------------------------------------------------------------------ stagger

export const STAGGER_DECAY_PER_S = 15;
export const STAGGER_DECAY_DELAY_S = 1.5;
export const STAGGER_DURATION_S = 1.2;
