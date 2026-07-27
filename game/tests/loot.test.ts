import { describe, expect, it } from 'vitest';
import { rollTable, rollRarity, rollAffixes, addToInventory } from '@/sim/loot';
import { RNG, weightedPick, hashSeed } from '@/sim/rng';
import { ITEM_MAP, DROP_TABLE_MAP } from '@/content';
import type { DropTable, ItemInstance } from '@/shared/types';

describe('weightedPick', () => {
  it('respects declared weights within tolerance', () => {
    const rng = new RNG(5);
    const entries = [
      { id: 'a', weight: 75 },
      { id: 'b', weight: 25 },
    ];
    const counts: Record<string, number> = { a: 0, b: 0 };
    for (let i = 0; i < 20000; i++) counts[weightedPick(entries, rng).id]++;
    expect(counts.a / 20000).toBeGreaterThan(0.72);
    expect(counts.a / 20000).toBeLessThan(0.78);
  });

  it('ignores zero and negative weights', () => {
    const rng = new RNG(11);
    const entries = [
      { id: 'a', weight: 0 },
      { id: 'b', weight: -5 },
      { id: 'c', weight: 10 },
    ];
    for (let i = 0; i < 100; i++) expect(weightedPick(entries, rng).id).toBe('c');
  });
});

describe('drop tables', () => {
  it('always yields guaranteed drops', () => {
    const table = DROP_TABLE_MAP.get('dt_warden_zhun')!;
    for (let seed = 0; seed < 40; seed++) {
      const res = rollTable(table, ITEM_MAP, new RNG(seed), {});
      // Gate items are 100% drops by design: never gate progression on RNG.
      expect(res.drops.some((d) => d.defId === 'elders_waystone')).toBe(true);
    }
  });

  it('pays currency inside the declared range', () => {
    const table = DROP_TABLE_MAP.get('dt_rockhide')!;
    for (let seed = 0; seed < 60; seed++) {
      const res = rollTable(table, ITEM_MAP, new RNG(seed), {});
      expect(res.currency).toBeGreaterThanOrEqual(table.currency.min);
      expect(res.currency).toBeLessThanOrEqual(table.currency.max);
    }
  });

  it('honours the pity counter ceiling', () => {
    const table = DROP_TABLE_MAP.get('dt_rockhide')!;
    const pity: Record<string, number> = {};
    let sawCore = false;
    // Within `after` kills the chase item must appear at least once.
    for (let i = 0; i < table.pityCounter!.after; i++) {
      const res = rollTable(table, ITEM_MAP, new RNG(1000 + i), pity);
      if (res.drops.some((d) => d.defId === 'hollowed_core')) sawCore = true;
    }
    expect(sawCore).toBe(true);
  });

  it('resets the pity counter when the item drops naturally', () => {
    const table: DropTable = {
      id: 't',
      currency: { min: 0, max: 0 },
      guaranteed: [{ item: 'hollowed_core', min: 1, max: 1 }],
      rolls: 0,
      pool: [{ item: null, weight: 1 }],
      pityCounter: { trackKey: 'k', after: 3, grants: 'hollowed_core' },
    };
    const pity: Record<string, number> = {};
    rollTable(table, ITEM_MAP, new RNG(1), pity);
    expect(pity.k).toBe(0);
  });

  it('never emits an item id that has no definition', () => {
    for (const table of DROP_TABLE_MAP.values()) {
      for (let seed = 0; seed < 30; seed++) {
        const res = rollTable(table, ITEM_MAP, new RNG(seed), {});
        for (const d of res.drops) expect(ITEM_MAP.has(d.defId)).toBe(true);
      }
    }
  });

  it('produces identical loot for identical seeds', () => {
    const table = DROP_TABLE_MAP.get('dt_rockhide')!;
    const a = rollTable(table, ITEM_MAP, new RNG(hashSeed('z1', 'rockhide', 3, 5)), {});
    const b = rollTable(table, ITEM_MAP, new RNG(hashSeed('z1', 'rockhide', 3, 5)), {});
    expect(a).toEqual(b);
  });
});

describe('content integrity', () => {
  it('every drop table entry references a real item', () => {
    for (const table of DROP_TABLE_MAP.values()) {
      for (const g of table.guaranteed) expect(ITEM_MAP.has(g.item)).toBe(true);
      for (const p of table.pool) {
        if (p.item !== null) expect(ITEM_MAP.has(p.item)).toBe(true);
      }
      if (table.pityCounter) expect(ITEM_MAP.has(table.pityCounter.grants)).toBe(true);
    }
  });

  it('every equipment item declares a slot', () => {
    for (const def of ITEM_MAP.values()) {
      if (def.kind === 'equipment') expect(def.slot).toBeTruthy();
    }
  });
});

describe('rarity and affixes', () => {
  it('rolls common most of the time and legendary rarely', () => {
    const rng = new RNG(17);
    const counts: Record<string, number> = {};
    for (let i = 0; i < 20000; i++) {
      const r = rollRarity(rng);
      counts[r] = (counts[r] ?? 0) + 1;
    }
    expect(counts.common / 20000).toBeGreaterThan(0.5);
    expect((counts.legendary ?? 0) / 20000).toBeLessThan(0.02);
  });

  it('grants affix counts matching rarity', () => {
    const rng = new RNG(23);
    expect(rollAffixes('common', 5, rng)).toHaveLength(0);
    expect(rollAffixes('rare', 5, rng)).toHaveLength(2);
    expect(rollAffixes('legendary', 5, rng)).toHaveLength(3);
  });

  it('never rolls the same affix twice on one item', () => {
    const rng = new RNG(31);
    for (let i = 0; i < 500; i++) {
      const affixes = rollAffixes('legendary', 10, rng);
      expect(new Set(affixes.map((a) => a.id)).size).toBe(affixes.length);
    }
  });
});

describe('inventory', () => {
  it('merges stackable materials instead of creating duplicates', () => {
    const def = ITEM_MAP.get('stone_shard')!;
    let inv: ItemInstance[] = [];
    inv = addToInventory(inv, { defId: 'stone_shard', quantity: 2, rarity: 'common', affixes: [] }, def);
    inv = addToInventory(inv, { defId: 'stone_shard', quantity: 3, rarity: 'common', affixes: [] }, def);
    expect(inv).toHaveLength(1);
    expect(inv[0].quantity).toBe(5);
  });

  it('keeps equipment as separate instances', () => {
    const def = ITEM_MAP.get('spire_staff')!;
    let inv: ItemInstance[] = [];
    inv = addToInventory(inv, { defId: 'spire_staff', quantity: 1, rarity: 'rare', affixes: [] }, def);
    inv = addToInventory(inv, { defId: 'spire_staff', quantity: 1, rarity: 'epic', affixes: [] }, def);
    expect(inv).toHaveLength(2);
  });
});
