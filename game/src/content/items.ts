import type { ItemDef } from '@/shared/types';

/**
 * Item *definitions* are static content. Saves store only `defId` + rolled
 * values, so rebalancing an item is a static deploy, never a migration.
 */
export const ITEM_DEFS: ItemDef[] = [
  // ---------------------------------------------------------- weapons
  {
    id: 'training_wraps',
    name: 'Training Wraps',
    kind: 'equipment',
    slot: 'weapon',
    itemLevel: 1,
    base: { atk: 4 },
    description: 'Frayed cloth wraps. They have seen a great deal of practice.',
    stackable: false,
    world: 'w1_verdant_reach',
  },
  {
    id: 'spire_staff',
    name: 'Spire Staff',
    kind: 'equipment',
    slot: 'weapon',
    itemLevel: 5,
    base: { atk: 11, critChance: 0.02 },
    description: 'Cut from a fallen rock spire. Lighter than it has any right to be.',
    stackable: false,
    world: 'w1_verdant_reach',
  },
  {
    id: 'ki_blade',
    name: 'Ki Blade',
    kind: 'equipment',
    slot: 'weapon',
    itemLevel: 9,
    base: { atk: 19, critChance: 0.03, critMultiplier: 0.1 },
    description: 'An edge of condensed energy. It hums when you breathe out.',
    stackable: false,
    world: 'w1_verdant_reach',
  },

  // ---------------------------------------------------------- armour
  {
    id: 'weighted_gi',
    name: 'Weighted Gi',
    kind: 'equipment',
    slot: 'chest',
    itemLevel: 2,
    base: { maxHp: 22, def: 4 },
    description: 'Heavier than it looks. That is the point.',
    stackable: false,
    world: 'w1_verdant_reach',
  },
  {
    id: 'sentinel_plate',
    name: 'Sentinel Plate',
    kind: 'equipment',
    slot: 'chest',
    itemLevel: 6,
    base: { maxHp: 46, def: 11 },
    description: 'Segmented stone scale, prised from a Rockhide.',
    stackable: false,
    world: 'w1_verdant_reach',
  },
  {
    id: 'warden_helm',
    name: "Warden's Helm",
    kind: 'equipment',
    slot: 'head',
    itemLevel: 7,
    base: { maxHp: 28, def: 7 },
    description: 'Cool to the touch, even under two suns.',
    stackable: false,
    world: 'w1_verdant_reach',
  },
  {
    id: 'pool_striders',
    name: 'Pool Striders',
    kind: 'equipment',
    slot: 'legs',
    itemLevel: 4,
    base: { maxStamina: 10, staminaRegen: 2, def: 3 },
    description: 'Wrapped soles that shed water without a sound.',
    stackable: false,
    world: 'w1_verdant_reach',
  },
  {
    id: 'grasp_wraps',
    name: 'Grasping Wraps',
    kind: 'equipment',
    slot: 'hands',
    itemLevel: 3,
    base: { atk: 3, critChance: 0.015 },
    description: 'Tight at the knuckle, loose at the wrist.',
    stackable: false,
    world: 'w1_verdant_reach',
  },
  {
    id: 'hollowed_core',
    name: 'Hollowed Core',
    kind: 'equipment',
    slot: 'accessory',
    itemLevel: 8,
    base: { atk: 8, maxHp: 30, critMultiplier: 0.15 },
    description: 'It should be inert. It is not.',
    stackable: false,
    world: 'w1_verdant_reach',
  },

  // ---------------------------------------------------------- materials
  {
    id: 'stone_shard',
    name: 'Stone Shard',
    kind: 'material',
    itemLevel: 1,
    description: 'Common crafting material.',
    stackable: true,
    world: 'w1_verdant_reach',
  },
  {
    id: 'namekian_crystal',
    name: 'Verdant Crystal',
    kind: 'material',
    itemLevel: 1,
    description:
      'World-exclusive material. Still wanted by high-tier recipes long after you outlevel this world.',
    stackable: true,
    world: 'w1_verdant_reach',
  },

  // ---------------------------------------------------------- key items
  {
    id: 'elders_waystone',
    name: "Elder's Waystone",
    kind: 'key',
    itemLevel: 1,
    description: 'Opens the way deeper into the Reach. Taken from Warden Zhun.',
    stackable: false,
    world: 'w1_verdant_reach',
  },
  {
    id: 'fractured_dragon_sigil',
    name: 'Fractured Dragon Sigil',
    kind: 'key',
    itemLevel: 1,
    description: 'A broken seal, warm at the edges. Something else recognises it.',
    stackable: false,
    world: 'w1_verdant_reach',
  },
];

export const ITEM_MAP: Map<string, ItemDef> = new Map(
  ITEM_DEFS.map((d) => [d.id, d]),
);

export function getItemDef(id: string): ItemDef | undefined {
  return ITEM_MAP.get(id);
}
