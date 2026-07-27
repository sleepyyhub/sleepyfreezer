import type { DropTable } from '@/shared/types';

/**
 * `null` entries are explicit "nothing" outcomes rather than an implicit
 * failure chance, so every real item's drop rate reads straight off the
 * weights as weight/total.
 */
export const DROP_TABLES: DropTable[] = [
  {
    id: 'dt_grasshopper',
    currency: { min: 3, max: 9 },
    guaranteed: [],
    rolls: 1,
    pool: [
      { item: null, weight: 520 },
      { item: 'stone_shard', weight: 300, min: 1, max: 2 },
      { item: 'namekian_crystal', weight: 90 },
      { item: 'training_wraps', weight: 50 },
      { item: 'grasp_wraps', weight: 40 },
    ],
  },
  {
    id: 'dt_rockhide',
    currency: { min: 18, max: 34 },
    guaranteed: [{ item: 'namekian_crystal', min: 1, max: 2 }],
    rolls: 2,
    pool: [
      { item: null, weight: 400 },
      { item: 'stone_shard', weight: 250, min: 1, max: 3 },
      { item: 'sentinel_plate', weight: 120, rarityOverride: 'uncommon' },
      { item: 'pool_striders', weight: 60 },
      { item: 'spire_staff', weight: 40 },
      { item: 'hollowed_core', weight: 8, rarityOverride: 'rare' },
    ],
    // Guarantees the chase item by kill 40 instead of leaving a miserable tail.
    pityCounter: { trackKey: 'rockhide_rare', after: 40, grants: 'hollowed_core' },
  },
  {
    id: 'dt_warden_zhun',
    currency: { min: 140, max: 220 },
    guaranteed: [
      { item: 'elders_waystone', min: 1, max: 1 },
      { item: 'namekian_crystal', min: 4, max: 7 },
      { item: 'warden_helm', min: 1, max: 1 },
    ],
    rolls: 2,
    pool: [
      { item: 'ki_blade', weight: 120, rarityOverride: 'epic' },
      { item: 'sentinel_plate', weight: 120, rarityOverride: 'rare' },
      { item: 'hollowed_core', weight: 80, rarityOverride: 'epic' },
      { item: 'spire_staff', weight: 100, rarityOverride: 'rare' },
    ],
    pityCounter: { trackKey: 'zhun_legendary', after: 6, grants: 'ki_blade' },
  },
  {
    id: 'chest_w1_common',
    currency: { min: 25, max: 60 },
    guaranteed: [{ item: 'stone_shard', min: 2, max: 4 }],
    rolls: 2,
    pool: [
      { item: null, weight: 200 },
      { item: 'namekian_crystal', weight: 220, min: 1, max: 2 },
      { item: 'weighted_gi', weight: 120 },
      { item: 'pool_striders', weight: 100 },
      { item: 'grasp_wraps', weight: 100 },
      { item: 'spire_staff', weight: 60 },
    ],
  },
];

export const DROP_TABLE_MAP: Map<string, DropTable> = new Map(
  DROP_TABLES.map((t) => [t.id, t]),
);
