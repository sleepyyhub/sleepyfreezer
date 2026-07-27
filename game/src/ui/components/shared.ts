import type { Rarity, Stats } from '@/shared/types';

export const RARITY_COLOR: Record<Rarity, string> = {
  common: '#b8c4bd',
  uncommon: '#7ee08a',
  rare: '#6bb6ff',
  epic: '#c07cff',
  legendary: '#ffb648',
};

export function panelShell(width: number): React.CSSProperties {
  return {
    // Panels opt back into pointer events; the UI root is click-through.
    pointerEvents: 'auto',
    position: 'absolute',
    top: '50%',
    left: '50%',
    transform: 'translate(-50%,-50%)',
    width: `min(${width}px, 94vw)`,
    maxHeight: '88vh',
    overflowY: 'auto',
    padding: '22px 26px',
    borderRadius: 12,
    background: 'rgba(10, 22, 17, 0.94)',
    border: '1px solid rgba(143,240,208,.22)',
    boxShadow: '0 24px 70px rgba(0,0,0,.6)',
    backdropFilter: 'blur(6px)',
  };
}

export function statLabel(k: keyof Stats): string {
  switch (k) {
    case 'maxHp':
      return 'Health';
    case 'atk':
      return 'Attack';
    case 'def':
      return 'Defence';
    case 'critChance':
      return 'Crit chance';
    case 'critMultiplier':
      return 'Crit damage';
    case 'maxStamina':
      return 'Stamina';
    case 'staminaRegen':
      return 'Stamina regen';
  }
}

export function formatStat(k: keyof Stats, v: number): string {
  if (k === 'critChance') return `${(v * 100).toFixed(1)}%`;
  if (k === 'critMultiplier') return `${v.toFixed(2)}x`;
  if (k === 'staminaRegen') return `${v.toFixed(1)}/s`;
  return String(Math.round(v));
}
