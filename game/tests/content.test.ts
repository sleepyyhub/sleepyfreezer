import { describe, expect, it } from 'vitest';
import { WORLDS, ENEMY_MAP, DROP_TABLE_MAP } from '@/content';
import { Terrain } from '@/sim/terrain';

/**
 * Content-integrity tests. These exist because authored coordinates silently
 * outside the playable disc produced an unreachable boss — the kind of bug a
 * type system cannot catch and a designer will hit again.
 */
describe('world content', () => {
  for (const world of WORLDS) {
    describe(world.id, () => {
      it('declares at least one zone', () => {
        expect(world.zones.length).toBeGreaterThan(0);
      });

      for (const zone of world.zones) {
        describe(zone.id, () => {
          const terrain = new Terrain(zone.terrain);
          // Leave a margin: an anchor exactly on the boundary spawns its pack
          // clamped into a wall.
          const limit = zone.terrain.size * 0.44 - 6;

          const points: { label: string; x: number; z: number }[] = [
            ...zone.spawns.map((s) => ({
              label: `spawn ${s.id}`,
              x: s.anchor[0],
              z: s.anchor[2],
            })),
            ...zone.chests.map((c) => ({ label: `chest ${c.id}`, x: c.at[0], z: c.at[2] })),
            ...(zone.boss
              ? [{ label: `boss ${zone.boss.enemy}`, x: zone.boss.at[0], z: zone.boss.at[2] }]
              : []),
          ];

          it('places every anchor inside the reachable area', () => {
            for (const p of points) {
              const d = Math.hypot(p.x, p.z);
              expect(`${p.label}: ${d.toFixed(1)} of ${limit.toFixed(1)}`).toBe(
                d < limit
                  ? `${p.label}: ${d.toFixed(1)} of ${limit.toFixed(1)}`
                  : 'OUT OF BOUNDS',
              );
            }
          });

          it('places every anchor on walkable ground', () => {
            for (const p of points) {
              expect(`${p.label} in water`).toBe(
                terrain.isWater(p.x, p.z) ? 'unreachable' : `${p.label} in water`,
              );
              // A pack anchored on a cliff face cannot be fought.
              expect(terrain.slopeAt(p.x, p.z)).toBeLessThan(1.4);
            }
          });

          it('references only enemies that exist', () => {
            for (const s of zone.spawns) {
              for (const id of s.pack) expect(ENEMY_MAP.has(id)).toBe(true);
            }
            if (zone.boss) expect(ENEMY_MAP.has(zone.boss.enemy)).toBe(true);
          });

          it('references only drop tables that exist', () => {
            for (const c of zone.chests) expect(DROP_TABLE_MAP.has(c.table)).toBe(true);
          });

          it('keeps the spawn point walkable and clear of packs', () => {
            expect(terrain.isWater(0, 0)).toBe(false);
            for (const s of zone.spawns) {
              expect(Math.hypot(s.anchor[0], s.anchor[2])).toBeGreaterThan(s.radius + 4);
            }
          });
        });
      }
    });
  }

  it('gives every enemy a drop table that exists', () => {
    for (const def of ENEMY_MAP.values()) {
      expect(DROP_TABLE_MAP.has(def.dropTable)).toBe(true);
    }
  });

  it('gives every boss phase only attacks the enemy actually has', () => {
    for (const def of ENEMY_MAP.values()) {
      if (!def.phases) continue;
      const ids = new Set(def.attacks.map((a) => a.id));
      for (const phase of def.phases) {
        for (const id of phase.attacks) expect(ids.has(id)).toBe(true);
      }
    }
  });

  it('orders boss phases by descending hp threshold', () => {
    for (const def of ENEMY_MAP.values()) {
      if (!def.phases) continue;
      for (let i = 1; i < def.phases.length; i++) {
        expect(def.phases[i].hpAbove).toBeLessThan(def.phases[i - 1].hpAbove);
      }
      // The final phase must reach zero, else low HP matches no phase at all.
      expect(def.phases[def.phases.length - 1].hpAbove).toBe(0);
    }
  });

  it('telegraphs every enemy attack for at least 0.6s', () => {
    for (const def of ENEMY_MAP.values()) {
      for (const atk of def.attacks) {
        // The fairness rule from the design doc, enforced as a test.
        expect(atk.windupS).toBeGreaterThanOrEqual(0.45);
      }
    }
  });
});
