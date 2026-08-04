import { api } from './api.js';

const API_BASE = api.base;

/**
 * The API and the UI describe a character slightly differently — the UI was
 * built against mock data with a two-colour gradient and formatted counts.
 * Adapting here keeps every component's props unchanged.
 */

export function initialsOf(name = '') {
  const parts = name.trim().split(/\s+/).filter(Boolean);
  if (!parts.length) return 'AI';
  if (parts.length === 1) return parts[0].slice(0, 2).toUpperCase();
  return (parts[0][0] + parts[1][0]).toUpperCase();
}

export function formatCount(n = 0) {
  if (n >= 1_000_000) return `${(n / 1_000_000).toFixed(1)}m`;
  if (n >= 1_000) return `${(n / 1_000).toFixed(1)}k`;
  return String(n);
}

/* --- colour helpers: one stored theme colour becomes a gradient pair --- */

function hexToHsl(hex) {
  const clean = hex.replace('#', '');
  const r = parseInt(clean.slice(0, 2), 16) / 255;
  const g = parseInt(clean.slice(2, 4), 16) / 255;
  const b = parseInt(clean.slice(4, 6), 16) / 255;
  const max = Math.max(r, g, b);
  const min = Math.min(r, g, b);
  const l = (max + min) / 2;
  if (max === min) return [0, 0, l];
  const d = max - min;
  const s = l > 0.5 ? d / (2 - max - min) : d / (max + min);
  let h;
  if (max === r) h = ((g - b) / d + (g < b ? 6 : 0)) / 6;
  else if (max === g) h = ((b - r) / d + 2) / 6;
  else h = ((r - g) / d + 4) / 6;
  return [h, s, l];
}

function hslToHex(h, s, l) {
  const f = (n) => {
    const k = (n + h * 12) % 12;
    const a = s * Math.min(l, 1 - l);
    const c = l - a * Math.max(-1, Math.min(k - 3, Math.min(9 - k, 1)));
    return Math.round(255 * c).toString(16).padStart(2, '0');
  };
  return `#${f(0)}${f(8)}${f(4)}`;
}

/** Rotate the hue a little and lift it — reads as a gradient, not two colours. */
export function gradientFor(hex = '#34d399') {
  try {
    const [h, s, l] = hexToHsl(hex);
    const second = hslToHex((h + 0.07) % 1, Math.min(1, s * 0.95), Math.min(0.72, l + 0.1));
    return [hex, second];
  } catch {
    return ['#34d399', '#a3e635'];
  }
}

export function adaptCharacter(c) {
  if (!c) return null;
  return {
    id: c.id,
    name: c.name,
    // Served from the API when one has been generated; the initials tile is
    // the fallback, so a character always renders.
    imageUrl: c.avatarMime ? `${API_BASE}/api/characters/${c.id}/avatar` : (c.avatarUrl ?? null),
    initials: initialsOf(c.name),
    role: c.universe || 'Original character',
    description: c.tagline || c.personality?.slice(0, 160) || '',
    tags: c.tags ?? [],
    chats: formatCount(c.messageCount ?? 0),
    likes: formatCount(Math.round((c.messageCount ?? 0) * 0.32)),
    badge: c.isFeatured ? 'Featured' : null,
    online: true,
    colors: gradientFor(c.themeColor),
    nsfwAllowed: c.nsfwAllowed,
    creatorId: c.creatorId,
    // Detail-only fields, present when fetched from /characters/:id
    personality: c.personality,
    lore: c.lore,
    creator: c.creator,
  };
}

export function formatClock(iso) {
  if (!iso) return '';
  return new Date(iso).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', hour12: false });
}

export function formatRelative(iso) {
  if (!iso) return '';
  const seconds = Math.max(0, (Date.now() - new Date(iso).getTime()) / 1000);
  if (seconds < 60) return 'now';
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m`;
  if (seconds < 86400) return `${Math.floor(seconds / 3600)}h`;
  if (seconds < 604800) return `${Math.floor(seconds / 86400)}d`;
  return new Date(iso).toLocaleDateString([], { day: 'numeric', month: 'short' });
}

export function adaptMessage(m) {
  return {
    id: m.id,
    speaker: m.senderType === 'user' ? 'user' : m.characterId,
    character: m.character ? adaptCharacter(m.character) : null,
    text: m.content,
    thought: m.thought ?? null,
    time: formatClock(m.createdAt),
    isProactive: m.isProactive,
  };
}
