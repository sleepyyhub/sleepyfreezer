import type { EnemyDef, ItemDef, WorldDef, ZoneDef } from '@/shared/types';
import { W1_VERDANT_REACH } from './worlds/w1_verdant_reach';
import { ENEMY_MAP } from './enemies';
import { ITEM_MAP } from './items';
import { DROP_TABLE_MAP } from './droptables';

/** Registering a new world is a one-line change here. */
export const WORLDS: WorldDef[] = [W1_VERDANT_REACH];

export const WORLD_MAP = new Map(WORLDS.map((w) => [w.id, w]));

export function getWorld(id: string): WorldDef {
  const w = WORLD_MAP.get(id);
  if (!w) throw new Error(`Unknown world: ${id}`);
  return w;
}

export function getZone(worldId: string, zoneId: string): ZoneDef {
  const z = getWorld(worldId).zones.find((x) => x.id === zoneId);
  if (!z) throw new Error(`Unknown zone: ${worldId}/${zoneId}`);
  return z;
}

export function getEnemy(id: string): EnemyDef {
  const e = ENEMY_MAP.get(id);
  if (!e) throw new Error(`Unknown enemy: ${id}`);
  return e;
}

export function getItem(id: string): ItemDef | undefined {
  return ITEM_MAP.get(id);
}

export { ENEMY_MAP, ITEM_MAP, DROP_TABLE_MAP };
export { ITEM_DEFS, getItemDef } from './items';
export { ENEMY_DEFS } from './enemies';
