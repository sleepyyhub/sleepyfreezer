/**
 * Clovyre brand tokens.
 * Shared between the Vite frontend and the API server so the two never drift.
 * Import from the frontend as `import { brand } from '../../shared/brand.js'`.
 */

export const brand = {
  name: 'Clovyre',
  tagline: 'conversations that feel alive',
  description: 'Clovyre — conversations that feel alive.',

  // Luck / clover palette on a near-black base.
  color: {
    bg: '#0d0d0f',
    surface: '#141418',
    surfaceRaised: '#1c1c22',
    border: '#26262e',

    text: '#f1f0f5',
    textMuted: '#8b8b96',
    textFaint: '#5c5c66',

    // Clover green — the primary accent.
    accent: '#34d399',
    accentSoft: '#6ee7b7',
    accentDeep: '#0f9b6c',
    accentGradient: 'linear-gradient(135deg, #34d399 0%, #4ade80 100%)',

    // "Four-leaf" gold. Used sparingly: rare badges, featured cards.
    lucky: '#fbbf24',

    nsfw: '#ef4444',
    online: '#4ade80',
  },

  font: {
    sans: "'Plus Jakarta Sans', 'Inter', system-ui, sans-serif",
    body: "'Inter', system-ui, sans-serif",
  },
};

export default brand;
