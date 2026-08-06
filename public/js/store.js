// Local persistence: conversations, workspace files, settings.

const KEY = 'clovyre.v1';

const DEFAULT_SYSTEM =
  'You are Clovyre, a thoughtful and precise AI assistant powered by Kimi K3. ' +
  'Answer clearly and get to the point. Use markdown — headings, lists and tables — when structure helps, ' +
  'and always put code in fenced blocks with a language tag. Say when you are unsure rather than guessing.';

const DEFAULTS = {
  chats: {},
  order: [],
  files: {},
  settings: {
    system: DEFAULT_SYSTEM,
    temperature: 0.6,
    topP: 1,
    maxTokens: 8192,
    autoTitle: true,
    sendOnEnter: true,
    theme: 'dark',
  },
};

function load() {
  try {
    const raw = localStorage.getItem(KEY);
    if (!raw) return structuredClone(DEFAULTS);
    const parsed = JSON.parse(raw);
    return {
      ...structuredClone(DEFAULTS),
      ...parsed,
      settings: { ...DEFAULTS.settings, ...(parsed.settings || {}) },
    };
  } catch {
    return structuredClone(DEFAULTS);
  }
}

export const state = load();
export const DEFAULT_SYSTEM_PROMPT = DEFAULT_SYSTEM;

let saveTimer;
export function save() {
  clearTimeout(saveTimer);
  saveTimer = setTimeout(() => {
    try {
      localStorage.setItem(KEY, JSON.stringify(state));
    } catch {
      // Quota exceeded — drop the oldest conversations and try once more.
      const victims = state.order.slice(-5);
      victims.forEach((id) => delete state.chats[id]);
      state.order = state.order.filter((id) => !victims.includes(id));
      try { localStorage.setItem(KEY, JSON.stringify(state)); } catch { /* give up quietly */ }
    }
  }, 180);
}

export const uid = () => Math.random().toString(36).slice(2, 10) + Date.now().toString(36);

/* ---------------- conversations ---------------- */

export function createChat() {
  const chat = { id: uid(), title: 'New conversation', createdAt: Date.now(), updatedAt: Date.now(), mode: 'chat', messages: [] };
  state.chats[chat.id] = chat;
  state.order.unshift(chat.id);
  save();
  return chat;
}

export function deleteChat(id) {
  delete state.chats[id];
  state.order = state.order.filter((x) => x !== id);
  save();
}

export function touch(chat) {
  chat.updatedAt = Date.now();
  state.order = [chat.id, ...state.order.filter((x) => x !== chat.id)];
  save();
}

export function groupChats(query = '') {
  const q = query.trim().toLowerCase();
  const now = Date.now();
  const day = 864e5;
  const buckets = [
    ['Today', 0, day],
    ['Yesterday', day, 2 * day],
    ['Previous 7 days', 2 * day, 7 * day],
    ['Previous 30 days', 7 * day, 30 * day],
    ['Older', 30 * day, Infinity],
  ];
  const groups = buckets.map(([label]) => ({ label, chats: [] }));

  for (const id of state.order) {
    const chat = state.chats[id];
    if (!chat) continue;
    if (q) {
      const hay = (chat.title + ' ' + chat.messages.map((m) => (typeof m.content === 'string' ? m.content : '')).join(' ')).toLowerCase();
      if (!hay.includes(q)) continue;
    }
    const age = now - (chat.updatedAt || 0);
    const idx = buckets.findIndex(([, lo, hi]) => age >= lo && age < hi);
    groups[idx < 0 ? groups.length - 1 : idx].chats.push(chat);
  }
  return groups.filter((g) => g.chats.length);
}

/* ---------------- workspace files ---------------- */

export function writeFile(name, content, language = '') {
  const clean = String(name).replace(/^[./\\]+/, '').replace(/[\\]/g, '/').trim() || 'untitled.txt';
  const existing = state.files[clean];
  state.files[clean] = {
    name: clean,
    content: String(content ?? ''),
    language: language || existing?.language || guessLanguage(clean),
    createdAt: existing?.createdAt || Date.now(),
    updatedAt: Date.now(),
  };
  save();
  return state.files[clean];
}

export function deleteFile(name) {
  delete state.files[name];
  save();
}

export function guessLanguage(name) {
  const ext = name.split('.').pop().toLowerCase();
  return {
    js: 'javascript', mjs: 'javascript', jsx: 'javascript', ts: 'typescript', tsx: 'typescript',
    py: 'python', rb: 'ruby', go: 'go', rs: 'rust', java: 'java', c: 'c', h: 'c', cpp: 'cpp',
    cs: 'csharp', php: 'php', swift: 'swift', kt: 'kotlin', sh: 'bash', bash: 'bash', zsh: 'bash',
    html: 'html', htm: 'html', css: 'css', scss: 'scss', json: 'json', yml: 'yaml', yaml: 'yaml',
    xml: 'xml', svg: 'svg', md: 'markdown', sql: 'sql', toml: 'toml', csv: 'csv', txt: 'text',
  }[ext] || 'text';
}

export const bytes = (n) =>
  n < 1024 ? `${n} B` : n < 1048576 ? `${(n / 1024).toFixed(1)} KB` : `${(n / 1048576).toFixed(1)} MB`;
