import type { WorldDef } from '@/shared/types';

/**
 * A world is data. Adding World 2+ means adding a file shaped like this one
 * and registering its id — no changes to any system.
 */
export const W1_VERDANT_REACH: WorldDef = {
  id: 'w1_verdant_reach',
  displayName: 'Verdant Reach',
  order: 1,
  levelRange: [1, 15],
  unlock: { type: 'default' },

  palette: {
    ambient: '#7FE3A0',
    ambientIntensity: 0.6,
    keyLight: { color: '#FFB347', intensity: 1.2, elevation: 25, azimuth: 130 },
    hemisphere: { sky: '#9FFFC4', ground: '#2E5D3A', intensity: 0.45 },
    fog: { color: '#6FD99A', density: 0.011 },
    rampStops: ['#2A4D3A', '#4E8F63', '#8FD9A0', '#D8FFE4'],
    exposure: 1.1,
    water: '#2FA5C8',
    terrainLow: '#3E7A52',
    terrainHigh: '#C98A4B',
  },

  materials: { currency: 'zeni', craftMaterial: 'namekian_crystal' },

  zones: [
    {
      id: 'z1_landing_flats',
      displayName: 'Landing Flats',
      levelRange: [1, 4],
      terrain: { size: 130, heightScale: 7, seed: 1337, segments: 96, waterLevel: -1.2 },
      props: [
        { archetype: 'spire', count: 22, scaleRange: [1.4, 4.2] },
        { archetype: 'rock', count: 90, scaleRange: [0.5, 2.2] },
        { archetype: 'frond', count: 140, scaleRange: [0.7, 1.6] },
        { archetype: 'crystal', count: 26, scaleRange: [0.6, 1.5] },
      ],
      spawns: [
        {
          id: 'sp_a',
          anchor: [14, 0, -22],
          radius: 7,
          pack: ['grasshopper', 'grasshopper', 'grasshopper'],
          respawnS: 90,
        },
        {
          id: 'sp_b',
          anchor: [-20, 0, -34],
          radius: 8,
          pack: ['grasshopper', 'grasshopper'],
          respawnS: 90,
        },
        {
          id: 'sp_c',
          anchor: [30, 0, -40],
          radius: 9,
          pack: ['grasshopper', 'rockhide_sentinel'],
          respawnS: 110,
        },
        {
          id: 'sp_d',
          anchor: [-8, 0, -44],
          radius: 9,
          pack: ['rockhide_sentinel', 'grasshopper', 'grasshopper'],
          respawnS: 110,
        },
        {
          id: 'sp_e',
          anchor: [20, 0, 26],
          radius: 8,
          pack: ['grasshopper', 'grasshopper', 'grasshopper', 'grasshopper'],
          respawnS: 90,
        },
        {
          id: 'sp_f',
          anchor: [-32, 0, 12],
          radius: 9,
          pack: ['rockhide_sentinel', 'rockhide_sentinel'],
          respawnS: 130,
        },
      ],
      chests: [
        { id: 'ch_a', at: [26, 0, -12], table: 'chest_w1_common' },
        { id: 'ch_b', at: [-34, 0, -34], table: 'chest_w1_common' },
        { id: 'ch_c', at: [4, 0, 44], table: 'chest_w1_common' },
      ],
      exits: [],
      boss: { enemy: 'warden_zhun', at: [0, 0, -50] },
    },
  ],

  completion: { grantsKeyItem: 'fractured_dragon_sigil' },
};
