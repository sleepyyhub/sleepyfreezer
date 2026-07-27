import type { Drop } from '@/sim/loot';
import type { Vec3 } from '@/shared/types';

/**
 * Typed one-way channel: sim -> (renderer, UI, audio). The sim never reads
 * back from a listener, which is what keeps it deterministic and headless.
 */
export interface GameEvents {
  damage: {
    at: Vec3;
    amount: number;
    isCrit: boolean;
    onPlayer: boolean;
  };
  hitstop: { seconds: number };
  enemyKilled: {
    enemyId: string;
    at: Vec3;
    xp: number;
    drops: Drop[];
    currency: number;
    isBoss: boolean;
  };
  playerDied: Record<string, never>;
  levelUp: { level: number; statPoints: number };
  bossPhase: { phase: number; name: string };
  bossEngaged: { name: string; maxHp: number };
  bossDisengaged: Record<string, never>;
  chestOpened: { chestId: string; drops: Drop[]; currency: number };
  dodgeSuccess: { at: Vec3 };
  staggered: { at: Vec3 };
  toast: { text: string; tone: 'info' | 'good' | 'bad' };
}

type Handler<K extends keyof GameEvents> = (payload: GameEvents[K]) => void;

export class EventBus {
  private handlers = new Map<string, Set<Handler<never>>>();

  on<K extends keyof GameEvents>(key: K, fn: Handler<K>): () => void {
    let set = this.handlers.get(key as string);
    if (!set) {
      set = new Set();
      this.handlers.set(key as string, set);
    }
    set.add(fn as Handler<never>);
    return () => set!.delete(fn as Handler<never>);
  }

  emit<K extends keyof GameEvents>(key: K, payload: GameEvents[K]): void {
    const set = this.handlers.get(key as string);
    if (!set) return;
    for (const fn of set) (fn as Handler<K>)(payload);
  }

  clear(): void {
    this.handlers.clear();
  }
}

export const bus = new EventBus();
