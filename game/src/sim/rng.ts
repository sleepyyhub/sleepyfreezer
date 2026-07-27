/**
 * Seeded PRNG (mulberry32). Loot rolls are seeded per kill so that drops are
 * reproducible from a bug report and cannot be re-rolled by reloading.
 */
export class RNG {
  private state: number;

  constructor(seed: number) {
    this.state = seed >>> 0;
  }

  next(): number {
    this.state = (this.state + 0x6d2b79f5) >>> 0;
    let t = this.state;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  }

  int(min: number, max: number): number {
    return min + Math.floor(this.next() * (max - min + 1));
  }

  range(min: number, max: number): number {
    return min + this.next() * (max - min);
  }

  pick<T>(items: T[]): T {
    return items[Math.floor(this.next() * items.length)];
  }
}

/** Deterministic 32-bit hash, used to build reproducible seeds from strings. */
export function hashSeed(...parts: (string | number)[]): number {
  let h = 2166136261 >>> 0;
  const s = parts.join(':');
  for (let i = 0; i < s.length; i++) {
    h ^= s.charCodeAt(i);
    h = Math.imul(h, 16777619) >>> 0;
  }
  return h >>> 0;
}

export function weightedPick<T extends { weight: number }>(
  entries: T[],
  rng: RNG,
): T {
  let total = 0;
  for (const e of entries) total += Math.max(0, e.weight);
  let roll = rng.next() * total;
  for (const e of entries) {
    roll -= Math.max(0, e.weight);
    if (roll <= 0) return e;
  }
  return entries[entries.length - 1];
}

/** Value noise over a 2D grid — terrain heightfield without a noise library. */
export function valueNoise2D(x: number, z: number, seed: number): number {
  const xi = Math.floor(x);
  const zi = Math.floor(z);
  const xf = x - xi;
  const zf = z - zi;

  const corner = (cx: number, cz: number) => {
    let h = seed >>> 0;
    h = Math.imul(h ^ (cx * 374761393), 2654435761) >>> 0;
    h = Math.imul(h ^ (cz * 668265263), 2246822519) >>> 0;
    h ^= h >>> 13;
    return (h >>> 0) / 4294967296;
  };

  // Smoothstep keeps the surface C1-continuous, so normals don't crease.
  const sx = xf * xf * (3 - 2 * xf);
  const sz = zf * zf * (3 - 2 * zf);

  const n00 = corner(xi, zi);
  const n10 = corner(xi + 1, zi);
  const n01 = corner(xi, zi + 1);
  const n11 = corner(xi + 1, zi + 1);

  return (
    n00 * (1 - sx) * (1 - sz) +
    n10 * sx * (1 - sz) +
    n01 * (1 - sx) * sz +
    n11 * sx * sz
  );
}

/** Layered value noise. Returns roughly [0, 1]. */
export function fbm2D(x: number, z: number, seed: number, octaves = 4): number {
  let sum = 0;
  let amp = 1;
  let freq = 1;
  let norm = 0;
  for (let i = 0; i < octaves; i++) {
    sum += valueNoise2D(x * freq, z * freq, seed + i * 1013) * amp;
    norm += amp;
    amp *= 0.5;
    freq *= 2;
  }
  return sum / norm;
}
