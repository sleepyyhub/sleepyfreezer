import { create } from 'zustand';
import type { CharacterState, EquipSlot, Stats, StatKey } from '@/shared/types';
import { getItemDef, ITEM_MAP } from '@/content';
import { applyXp, MAX_LEVEL, STAT_POINTS_PER_LEVEL, totalStats } from '@/sim/formulas';
import { addToInventory, type Drop } from '@/sim/loot';
import { initialCharacter, LocalSaveAdapter, SaveScheduler } from '@/net/save';

export type Panel = 'none' | 'inventory' | 'character' | 'help';

export interface Toast {
  id: number;
  text: string;
  tone: 'info' | 'good' | 'bad';
  at: number;
}

/** Values the HUD reads every frame; updated at a throttled rate, not 60 Hz. */
export interface HudVitals {
  hp: number;
  maxHp: number;
  stamina: number;
  maxStamina: number;
  specialCooldown: number;
  specialCooldownMax: number;
  bossName: string | null;
  bossHp: number;
  bossMaxHp: number;
  interactPrompt: string | null;
  fps: number;
}

interface GameStore {
  character: CharacterState;
  stats: Stats;
  panel: Panel;
  toasts: Toast[];
  vitals: HudVitals;
  dead: boolean;
  started: boolean;

  setPanel: (p: Panel) => void;
  togglePanel: (p: Panel) => void;
  setVitals: (v: Partial<HudVitals>) => void;
  pushToast: (text: string, tone?: Toast['tone']) => void;
  expireToasts: () => void;

  start: () => void;
  setDead: (d: boolean) => void;

  grantXp: (amount: number) => number;
  grantDrops: (drops: Drop[], currency: number) => void;
  recordKill: (zoneId: string) => void;
  setFlag: (key: string) => void;

  equip: (uid: string) => void;
  unequip: (slot: EquipSlot) => void;
  sellItem: (uid: string) => void;
  allocate: (stat: StatKey) => void;
  respec: () => void;

  loadFrom: (c: CharacterState) => void;
  resetSave: () => void;
}

const saveAdapter = new LocalSaveAdapter();
const scheduler = new SaveScheduler(saveAdapter);

function deriveStats(c: CharacterState): Stats {
  const equipped = c.inventory
    .filter((i) => i.equippedSlot)
    .map((inst) => ({ inst, def: ITEM_MAP.get(inst.defId)! }))
    .filter((e) => e.def);
  return totalStats(c.level, c.allocation, equipped);
}

let toastId = 0;

export const useGame = create<GameStore>((set, get) => {
  const persist = () => scheduler.request(get().character);

  const commit = (updater: (c: CharacterState) => CharacterState) => {
    set((s) => {
      const character = updater(s.character);
      return { character, stats: deriveStats(character) };
    });
    persist();
  };

  return {
    character: initialCharacter(),
    stats: deriveStats(initialCharacter()),
    panel: 'none',
    toasts: [],
    dead: false,
    started: false,
    vitals: {
      hp: 100,
      maxHp: 100,
      stamina: 100,
      maxStamina: 100,
      specialCooldown: 0,
      specialCooldownMax: 8,
      bossName: null,
      bossHp: 0,
      bossMaxHp: 1,
      interactPrompt: null,
      fps: 60,
    },

    setPanel: (panel) => set({ panel }),
    togglePanel: (p) => set((s) => ({ panel: s.panel === p ? 'none' : p })),
    setVitals: (v) => set((s) => ({ vitals: { ...s.vitals, ...v } })),

    pushToast: (text, tone = 'info') =>
      set((s) => ({
        toasts: [...s.toasts, { id: toastId++, text, tone, at: Date.now() }].slice(-6),
      })),

    expireToasts: () =>
      set((s) => {
        const now = Date.now();
        const kept = s.toasts.filter((t) => now - t.at < 3500);
        return kept.length === s.toasts.length ? {} : { toasts: kept };
      }),

    start: () => set({ started: true }),
    setDead: (dead) => set(dead ? { dead, panel: 'none' } : { dead }),

    grantXp: (amount) => {
      let levelsGained = 0;
      commit((c) => {
        const res = applyXp(c.level, c.xp, amount);
        levelsGained = res.levelsGained;
        return {
          ...c,
          level: res.level,
          xp: res.xp,
          statPoints: c.statPoints + res.levelsGained * STAT_POINTS_PER_LEVEL,
        };
      });
      return levelsGained;
    },

    grantDrops: (drops, currency) => {
      commit((c) => {
        let inv = c.inventory;
        for (const d of drops) {
          const def = ITEM_MAP.get(d.defId);
          if (!def) continue;
          inv = addToInventory(inv, d, def);
        }
        return {
          ...c,
          inventory: inv,
          currencies: { ...c.currencies, zeni: (c.currencies.zeni ?? 0) + currency },
        };
      });
    },

    recordKill: (zoneId) =>
      commit((c) => ({ ...c, kills: { ...c.kills, [zoneId]: (c.kills[zoneId] ?? 0) + 1 } })),

    setFlag: (key) => commit((c) => ({ ...c, flags: { ...c.flags, [key]: true } })),

    equip: (uid) => {
      commit((c) => {
        const item = c.inventory.find((i) => i.uid === uid);
        const def = item && ITEM_MAP.get(item.defId);
        if (!item || !def || def.kind !== 'equipment' || !def.slot) return c;
        const slot = def.slot;
        return {
          ...c,
          inventory: c.inventory.map((i) => {
            // Whatever occupied the slot goes back to the bag in the same pass.
            if (i.equippedSlot === slot) return { ...i, equippedSlot: null };
            if (i.uid === uid) return { ...i, equippedSlot: slot };
            return i;
          }),
        };
      });
    },

    unequip: (slot) =>
      commit((c) => ({
        ...c,
        inventory: c.inventory.map((i) =>
          i.equippedSlot === slot ? { ...i, equippedSlot: null } : i,
        ),
      })),

    sellItem: (uid) => {
      commit((c) => {
        const item = c.inventory.find((i) => i.uid === uid);
        const def = item && ITEM_MAP.get(item.defId);
        if (!item || !def || item.equippedSlot) return c;
        const value = Math.max(2, Math.round(def.itemLevel * 6 * item.quantity));
        return {
          ...c,
          inventory: c.inventory.filter((i) => i.uid !== uid),
          currencies: { ...c.currencies, zeni: (c.currencies.zeni ?? 0) + value },
        };
      });
    },

    allocate: (stat) =>
      commit((c) =>
        c.statPoints <= 0
          ? c
          : {
              ...c,
              statPoints: c.statPoints - 1,
              allocation: { ...c.allocation, [stat]: c.allocation[stat] + 1 },
            },
      ),

    respec: () =>
      commit((c) => ({
        ...c,
        statPoints: (c.level - 1) * STAT_POINTS_PER_LEVEL,
        allocation: { vit: 0, str: 0, end: 0, agi: 0 },
      })),

    loadFrom: (c) => set({ character: c, stats: deriveStats(c) }),

    resetSave: () => {
      void saveAdapter.clear();
      const fresh = initialCharacter();
      set({ character: fresh, stats: deriveStats(fresh), dead: false });
    },
  };
});

export { saveAdapter, scheduler, deriveStats, MAX_LEVEL, getItemDef };
