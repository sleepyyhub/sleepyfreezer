export type QualityTier = 'low' | 'medium' | 'high';

export interface QualitySettings {
  maxPixelRatio: number;
  shadows: boolean;
  shadowMapSize: number;
  antialias: boolean;
  foliageFraction: number;
  drawDistance: number;
}

const TIERS: Record<QualityTier, QualitySettings> = {
  low: {
    maxPixelRatio: 0.75,
    shadows: false,
    shadowMapSize: 512,
    antialias: false,
    foliageFraction: 0.25,
    drawDistance: 90,
  },
  medium: {
    maxPixelRatio: 1,
    shadows: true,
    shadowMapSize: 1024,
    antialias: true,
    foliageFraction: 0.6,
    drawDistance: 130,
  },
  high: {
    maxPixelRatio: 2,
    shadows: true,
    shadowMapSize: 2048,
    antialias: true,
    foliageFraction: 1,
    drawDistance: 180,
  },
};

export function qualityFor(tier: QualityTier): QualitySettings {
  return { ...TIERS[tier] };
}

/**
 * Coarse startup heuristic. Deliberately conservative: the Low tier must be
 * genuinely playable on integrated graphics, since running anywhere is the
 * whole advantage of a browser game.
 */
export function detectTier(): QualityTier {
  const override = localStorage.getItem('verdant-reach:quality');
  if (override === 'low' || override === 'medium' || override === 'high') return override;

  const cores = navigator.hardwareConcurrency ?? 4;
  const mem = (navigator as Navigator & { deviceMemory?: number }).deviceMemory ?? 4;
  const mobile = /Android|iPhone|iPad|iPod/i.test(navigator.userAgent);

  if (mobile || cores <= 2 || mem <= 2) return 'low';
  if (cores >= 8 && mem >= 8) return 'high';
  return 'medium';
}

export function setQualityOverride(tier: QualityTier | null) {
  if (tier) localStorage.setItem('verdant-reach:quality', tier);
  else localStorage.removeItem('verdant-reach:quality');
}
