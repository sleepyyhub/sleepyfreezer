import type { ZoneDef } from '@/shared/types';
import { fbm2D } from './rng';

/**
 * The heightfield is a pure function of (x, z). Sim and renderer both call it,
 * so the collision surface and the visible mesh can never disagree — which is
 * the entire reason there is no separate collision proxy in the prototype.
 */
export class Terrain {
  readonly size: number;
  readonly heightScale: number;
  readonly seed: number;
  readonly waterLevel: number;

  constructor(def: ZoneDef['terrain']) {
    this.size = def.size;
    this.heightScale = def.heightScale;
    this.seed = def.seed;
    this.waterLevel = def.waterLevel;
  }

  heightAt(x: number, z: number): number {
    const s = 0.022;
    const base = fbm2D(x * s, z * s, this.seed, 4);

    // Ridged detail gives the low-poly plateaus their hard edges.
    const ridge = Math.abs(fbm2D(x * 0.05 + 40, z * 0.05 - 17, this.seed + 991, 2) - 0.5) * 2;

    // Flatten a bowl around the origin so the spawn point is always playable.
    const d = Math.hypot(x, z);
    const spawnFlatten = smoothstep(6, 22, d);

    // Fall away at the edges so the world reads as an island, not a cut cube.
    const edge = 1 - smoothstep(this.size * 0.36, this.size * 0.5, d);

    const h = (base * 0.8 + ridge * 0.35) * this.heightScale * spawnFlatten;
    return h * edge - (1 - edge) * 9;
  }

  /** Central-difference normal. Used for slope limiting and prop alignment. */
  slopeAt(x: number, z: number): number {
    const e = 0.6;
    const hx = this.heightAt(x + e, z) - this.heightAt(x - e, z);
    const hz = this.heightAt(x, z + e) - this.heightAt(x, z - e);
    return Math.hypot(hx, hz) / (2 * e);
  }

  isWater(x: number, z: number): boolean {
    return this.heightAt(x, z) < this.waterLevel;
  }

  /** Clamps a position to the playable disc. */
  clampToBounds(x: number, z: number): { x: number; z: number } {
    const limit = this.size * 0.44;
    const d = Math.hypot(x, z);
    if (d <= limit) return { x, z };
    const k = limit / d;
    return { x: x * k, z: z * k };
  }
}

export function smoothstep(edge0: number, edge1: number, x: number): number {
  const t = Math.min(1, Math.max(0, (x - edge0) / (edge1 - edge0)));
  return t * t * (3 - 2 * t);
}
