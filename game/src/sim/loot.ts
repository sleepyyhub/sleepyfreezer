import type {
  Affix,
  DropTable,
  ItemDef,
  ItemInstance,
  Rarity,
  Stats,
} from '@/shared/types';
import { RNG, weightedPick } from './rng';
import { RARITY_AFFIX_COUNT } from './formulas';

export interface Drop {
  defId: string;
  quantity: number;
  rarity: Rarity;
  affixes: Affix[];
}

export interface LootResult {
  drops: Drop[];
  currency: number;
}

const RARITY_WEIGHTS: { rarity: Rarity; weight: number }[] = [
  { rarity: 'common', weight: 600 },
  { rarity: 'uncommon', weight: 250 },
  { rarity: 'rare', weight: 110 },
  { rarity: 'epic', weight: 35 },
  { rarity: 'legendary', weight: 5 },
];

const AFFIX_POOL: { id: string; label: string; stat: keyof Stats; min: number; max: number }[] = [
  { id: 'ki_surge', label: 'Ki Surge', stat: 'atk', min: 2, max: 9 },
  { id: 'stoneblood', label: 'Stoneblood', stat: 'def', min: 2, max: 8 },
  { id: 'vitality', label: 'Vitality', stat: 'maxHp', min: 8, max: 40 },
  { id: 'keen', label: 'Keen Edge', stat: 'critChance', min: 0.01, max: 0.05 },
  { id: 'savage', label: 'Savage', stat: 'critMultiplier', min: 0.05, max: 0.2 },
  { id: 'weightless', label: 'Weightless', stat: 'maxStamina', min: 4, max: 15 },
  { id: 'secondwind', label: 'Second Wind', stat: 'staminaRegen', min: 1, max: 5 },
];

export function rollRarity(rng: RNG, luck = 0): Rarity {
  const weights = RARITY_WEIGHTS.map((r) => ({
    ...r,
    // Luck shifts weight off common and onto everything above it.
    weight: r.rarity === 'common' ? r.weight * (1 - luck * 0.3) : r.weight * (1 + luck),
  }));
  return weightedPick(weights, rng).rarity;
}

export function rollAffixes(rarity: Rarity, itemLevel: number, rng: RNG): Affix[] {
  const count = RARITY_AFFIX_COUNT[rarity];
  const out: Affix[] = [];
  const used = new Set<string>();
  const lvlScale = 1 + itemLevel * 0.06;

  for (let i = 0; i < count; i++) {
    // Reject duplicates rather than allowing "Ki Surge x3" on one item.
    let pick = AFFIX_POOL[rng.int(0, AFFIX_POOL.length - 1)];
    let guard = 0;
    while (used.has(pick.id) && guard++ < 12) {
      pick = AFFIX_POOL[rng.int(0, AFFIX_POOL.length - 1)];
    }
    if (used.has(pick.id)) break;
    used.add(pick.id);

    const isRatio = pick.stat === 'critChance' || pick.stat === 'critMultiplier';
    const raw = rng.range(pick.min, pick.max) * (isRatio ? 1 : lvlScale);
    out.push({
      id: pick.id,
      label: pick.label,
      stat: pick.stat,
      value: isRatio ? Math.round(raw * 1000) / 1000 : Math.round(raw),
    });
  }
  return out;
}

/**
 * Rolls a drop table. `pity` is mutated: pity counters are what stop a 1%
 * drop from producing a player who kills something 300 times and quits.
 */
export function rollTable(
  table: DropTable,
  defs: Map<string, ItemDef>,
  rng: RNG,
  pity: Record<string, number>,
  luck = 0,
): LootResult {
  const drops: Drop[] = [];

  const push = (defId: string, quantity: number, rarityOverride?: Rarity) => {
    const def = defs.get(defId);
    if (!def) return;
    const rarity =
      def.kind === 'equipment' ? rarityOverride ?? rollRarity(rng, luck) : 'common';
    drops.push({
      defId,
      quantity,
      rarity,
      affixes: def.kind === 'equipment' ? rollAffixes(rarity, def.itemLevel, rng) : [],
    });
  };

  for (const g of table.guaranteed) push(g.item, rng.int(g.min, g.max));

  for (let i = 0; i < table.rolls; i++) {
    const pool = table.pool.map((e) => ({
      ...e,
      weight: e.item === null ? e.weight * (1 - luck * 0.3) : e.weight,
    }));
    const picked = weightedPick(pool, rng);
    if (picked.item === null) continue;
    push(picked.item, rng.int(picked.min ?? 1, picked.max ?? 1), picked.rarityOverride);
  }

  if (table.pityCounter) {
    const key = table.pityCounter.trackKey;
    pity[key] = (pity[key] ?? 0) + 1;
    const alreadyDropped = drops.some((d) => d.defId === table.pityCounter!.grants);
    if (alreadyDropped) {
      pity[key] = 0;
    } else if (pity[key] >= table.pityCounter.after) {
      push(table.pityCounter.grants, 1, 'rare');
      pity[key] = 0;
    }
  }

  return { drops, currency: rng.int(table.currency.min, table.currency.max) };
}

let uidCounter = 0;

export function dropToInstance(d: Drop): ItemInstance {
  return {
    uid: `it_${Date.now().toString(36)}_${(uidCounter++).toString(36)}`,
    defId: d.defId,
    quantity: d.quantity,
    rarity: d.rarity,
    affixes: d.affixes,
    equippedSlot: null,
  };
}

/** Adds a drop to a bag, merging into an existing stack when stackable. */
export function addToInventory(
  inventory: ItemInstance[],
  d: Drop,
  def: ItemDef,
): ItemInstance[] {
  if (def.stackable) {
    const existing = inventory.find((i) => i.defId === d.defId && !i.equippedSlot);
    if (existing) {
      return inventory.map((i) =>
        i.uid === existing.uid ? { ...i, quantity: i.quantity + d.quantity } : i,
      );
    }
  }
  return [...inventory, dropToInstance(d)];
}
