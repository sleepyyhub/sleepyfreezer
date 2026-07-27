import { describe, expect, it } from 'vitest';
import {
  applyXp,
  computeDamage,
  CRIT_CHANCE_CAP,
  MAX_LEVEL,
  MITIGATION_K,
  mitigation,
  statsForLevel,
  totalStats,
  xpForKill,
  xpToReach,
} from '@/sim/formulas';
import { RNG } from '@/sim/rng';
import type { Allocation } from '@/shared/types';

const ZERO: Allocation = { vit: 0, str: 0, end: 0, agi: 0 };

describe('xp curve', () => {
  it('starts at zero and rises monotonically', () => {
    expect(xpToReach(1)).toBe(0);
    for (let l = 1; l < MAX_LEVEL; l++) {
      expect(xpToReach(l + 1)).toBeGreaterThan(xpToReach(l));
    }
  });

  it('hits the level-15 gate at roughly the designed pace', () => {
    // The World 2 gate should land near 12.7k XP — about 90 minutes of play.
    expect(xpToReach(15)).toBeGreaterThan(11000);
    expect(xpToReach(15)).toBeLessThan(14000);
  });

  it('grants multiple levels from one large award', () => {
    const res = applyXp(1, 0, xpToReach(5));
    expect(res.level).toBe(5);
    expect(res.levelsGained).toBe(4);
  });

  it('never exceeds the level cap', () => {
    const res = applyXp(1, 0, 99_999_999);
    expect(res.level).toBe(MAX_LEVEL);
    expect(res.xp).toBe(xpToReach(MAX_LEVEL));
  });
});

describe('kill xp falloff', () => {
  it('pays full value for on-level enemies', () => {
    expect(xpForKill(10, 10, 'standard')).toBe(xpForKill(10, 8, 'standard'));
  });

  it('discourages but never blocks farming trivial content', () => {
    const trivial = xpForKill(2, 20, 'chaff');
    expect(trivial).toBeGreaterThanOrEqual(1);
    expect(trivial).toBeLessThan(xpForKill(2, 2, 'chaff'));
  });

  it('scales by enemy tier', () => {
    expect(xpForKill(7, 7, 'midboss')).toBeGreaterThan(xpForKill(7, 7, 'chaff') * 10);
  });
});

describe('mitigation', () => {
  it('halves damage at DEF == K', () => {
    expect(mitigation(MITIGATION_K)).toBeCloseTo(0.5, 6);
  });

  it('never reaches zero and never goes negative', () => {
    expect(mitigation(0)).toBe(1);
    expect(mitigation(100_000)).toBeGreaterThan(0);
    expect(mitigation(-50)).toBe(1); // Negative DEF is clamped, not exploitable.
  });

  it('is monotonically decreasing', () => {
    let prev = mitigation(0);
    for (let d = 10; d <= 500; d += 10) {
      const cur = mitigation(d);
      expect(cur).toBeLessThan(prev);
      prev = cur;
    }
  });
});

describe('computeDamage', () => {
  const move = { multiplier: 1, stagger: 10, element: 'physical' as const };

  it('never deals less than 1 damage', () => {
    const rng = new RNG(1);
    for (let i = 0; i < 200; i++) {
      const r = computeDamage(
        { atk: 1, critChance: 0, critMultiplier: 1.5 },
        { def: 100_000 },
        move,
        rng,
      );
      expect(r.amount).toBeGreaterThanOrEqual(1);
    }
  });

  it('amplifies damage against a staggered target', () => {
    const a = { atk: 100, critChance: 0, critMultiplier: 1.5 };
    const normal = computeDamage(a, { def: 50 }, move, new RNG(42));
    const staggered = computeDamage(a, { def: 50, staggered: true }, move, new RNG(42));
    // Same seed, so variance is identical and only the stagger multiplier differs.
    expect(staggered.amount).toBeGreaterThan(normal.amount);
    expect(staggered.amount / normal.amount).toBeCloseTo(1.5, 1);
  });

  it('respects the crit chance cap', () => {
    const rng = new RNG(7);
    let crits = 0;
    const n = 4000;
    for (let i = 0; i < n; i++) {
      if (
        computeDamage({ atk: 10, critChance: 0.99, critMultiplier: 2 }, { def: 0 }, move, rng)
          .isCrit
      ) {
        crits++;
      }
    }
    expect(crits / n).toBeLessThan(CRIT_CHANCE_CAP + 0.03);
    expect(crits / n).toBeGreaterThan(CRIT_CHANCE_CAP - 0.03);
  });

  it('is deterministic for a given seed', () => {
    const a = { atk: 50, critChance: 0.3, critMultiplier: 1.8 };
    const first = computeDamage(a, { def: 20 }, move, new RNG(999));
    const second = computeDamage(a, { def: 20 }, move, new RNG(999));
    expect(first).toEqual(second);
  });

  it('keeps variance inside the designed +/-8% band', () => {
    const rng = new RNG(3);
    const a = { atk: 1000, critChance: 0, critMultiplier: 1.5 };
    let min = Infinity;
    let max = -Infinity;
    for (let i = 0; i < 2000; i++) {
      const d = computeDamage(a, { def: 0 }, move, rng).amount;
      min = Math.min(min, d);
      max = Math.max(max, d);
    }
    expect(min).toBeGreaterThanOrEqual(1000 * 0.92 - 1);
    expect(max).toBeLessThanOrEqual(1000 * 1.08 + 1);
  });
});

describe('stat scaling', () => {
  it('grows every stat with level', () => {
    const l1 = statsForLevel(1, ZERO);
    const l30 = statsForLevel(30, ZERO);
    expect(l30.maxHp).toBeGreaterThan(l1.maxHp);
    expect(l30.atk).toBeGreaterThan(l1.atk);
    expect(l30.def).toBeGreaterThan(l1.def);
  });

  it('caps crit chance even with extreme allocation', () => {
    const s = statsForLevel(30, { vit: 0, str: 0, end: 0, agi: 1000 });
    expect(s.critChance).toBe(CRIT_CHANCE_CAP);
  });

  it('caps crit chance after summing gear too', () => {
    const s = totalStats(10, { vit: 0, str: 0, end: 0, agi: 100 }, [
      {
        inst: {
          uid: 'x',
          defId: 'test',
          quantity: 1,
          rarity: 'legendary',
          affixes: [{ id: 'k', label: 'Keen', stat: 'critChance', value: 0.9 }],
          equippedSlot: 'weapon',
        },
        def: {
          id: 'test',
          name: 'Test',
          kind: 'equipment',
          slot: 'weapon',
          itemLevel: 1,
          base: { critChance: 0.5 },
          description: '',
          stackable: false,
          world: 'w1',
        },
      },
    ]);
    expect(s.critChance).toBe(CRIT_CHANCE_CAP);
  });
});
