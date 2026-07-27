import type { CharacterState } from '@/shared/types';

/**
 * Persistence sits behind this interface so the Supabase adapter can replace
 * the local one without touching a caller. The prototype ships local-only.
 */
export interface SaveAdapter {
  load(): Promise<CharacterState | null>;
  save(state: CharacterState): Promise<void>;
  clear(): Promise<void>;
}

const KEY = 'verdant-reach:save:v1';
export const SAVE_VERSION = 1;

export const initialCharacter = (): CharacterState => ({
  level: 1,
  xp: 0,
  statPoints: 0,
  allocation: { vit: 0, str: 0, end: 0, agi: 0 },
  currentWorld: 'w1_verdant_reach',
  currentZone: 'z1_landing_flats',
  unlockedZones: ['z1_landing_flats'],
  flags: {},
  kills: {},
  currencies: { zeni: 0 },
  inventory: [],
  pity: {},
  playtimeS: 0,
  saveVersion: SAVE_VERSION,
});

export class LocalSaveAdapter implements SaveAdapter {
  async load(): Promise<CharacterState | null> {
    try {
      const raw = localStorage.getItem(KEY);
      if (!raw) return null;
      const parsed = JSON.parse(raw) as CharacterState;
      if (parsed.saveVersion !== SAVE_VERSION) {
        console.warn('Save version mismatch; starting fresh.');
        return null;
      }
      // Merge over a fresh character so a save written by an older build that
      // lacked a field still loads instead of producing undefined at runtime.
      return { ...initialCharacter(), ...parsed };
    } catch (err) {
      console.error('Failed to load save', err);
      return null;
    }
  }

  async save(state: CharacterState): Promise<void> {
    try {
      localStorage.setItem(KEY, JSON.stringify(state));
    } catch (err) {
      console.error('Failed to write save', err);
    }
  }

  async clear(): Promise<void> {
    localStorage.removeItem(KEY);
  }
}

/**
 * Debounced writer. Saves happen on meaningful transitions, never per frame.
 */
export class SaveScheduler {
  private timer: ReturnType<typeof setTimeout> | null = null;
  private pending: CharacterState | null = null;

  constructor(
    private adapter: SaveAdapter,
    private debounceMs = 2000,
  ) {
    window.addEventListener('visibilitychange', () => {
      if (document.visibilityState === 'hidden') this.flush();
    });
    window.addEventListener('pagehide', () => this.flush());
  }

  request(state: CharacterState) {
    this.pending = state;
    if (this.timer) clearTimeout(this.timer);
    this.timer = setTimeout(() => this.flush(), this.debounceMs);
  }

  flush() {
    if (this.timer) {
      clearTimeout(this.timer);
      this.timer = null;
    }
    if (!this.pending) return;
    void this.adapter.save(this.pending);
    this.pending = null;
  }
}
