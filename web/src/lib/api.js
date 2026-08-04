const BASE = import.meta.env.VITE_API_URL ?? 'http://localhost:4000';

async function request(path, { method = 'GET', body } = {}) {
  const res = await fetch(`${BASE}${path}`, {
    method,
    // The session lives in an httpOnly cookie, so every call must carry it.
    credentials: 'include',
    headers: body ? { 'Content-Type': 'application/json' } : undefined,
    body: body ? JSON.stringify(body) : undefined,
  });

  if (!res.ok) {
    let message = `Request failed (${res.status})`;
    try {
      const data = await res.json();
      if (data?.error) message = data.error;
    } catch {
      // Non-JSON error body — keep the status message.
    }
    const error = new Error(message);
    error.status = res.status;
    throw error;
  }

  return res.status === 204 ? null : res.json();
}

export const api = {
  base: BASE,

  auth: {
    me: () => request('/api/auth/me'),
    providers: () => request('/api/auth/providers'),
    logout: () => request('/api/auth/logout', { method: 'POST' }),
    register: (data) => request('/api/auth/register', { method: 'POST', body: data }),
    login: (identifier, password) =>
      request('/api/auth/login', { method: 'POST', body: { identifier, password } }),
    signInUrl: (provider) => `${BASE}/api/auth/${provider}`,
  },

  characters: {
    list: ({ filter = 'popular', q = '', tag = '' } = {}) => {
      const params = new URLSearchParams({ filter });
      if (q) params.set('q', q);
      if (tag) params.set('tag', tag);
      return request(`/api/characters?${params}`);
    },
    get: (id) => request(`/api/characters/${id}`),
    create: (data) => request('/api/characters', { method: 'POST', body: data }),
    compose: (name, universe) =>
      request('/api/characters/compose', { method: 'POST', body: { name, universe } }),
    update: (id, data) => request(`/api/characters/${id}`, { method: 'PATCH', body: data }),
    remove: (id) => request(`/api/characters/${id}`, { method: 'DELETE' }),
  },

  conversations: {
    list: () => request('/api/conversations'),
    open: (characterId) => request('/api/conversations', { method: 'POST', body: { characterId } }),
    messages: (id) => request(`/api/conversations/${id}/messages`),
    send: (id, content) =>
      request(`/api/conversations/${id}/messages`, { method: 'POST', body: { content } }),
    remove: (id) => request(`/api/conversations/${id}`, { method: 'DELETE' }),
  },

  groups: {
    list: () => request('/api/groups'),
    create: (name, characterIds) =>
      request('/api/groups', { method: 'POST', body: { name, characterIds } }),
    messages: (id) => request(`/api/groups/${id}/messages`),
    send: (id, content) =>
      request(`/api/groups/${id}/messages`, { method: 'POST', body: { content } }),
    addMember: (id, characterId) =>
      request(`/api/groups/${id}/members`, { method: 'POST', body: { characterId } }),
    removeMember: (id, characterId) =>
      request(`/api/groups/${id}/members/${characterId}`, { method: 'DELETE' }),
    remove: (id) => request(`/api/groups/${id}`, { method: 'DELETE' }),
  },

  settings: {
    get: () => request('/api/settings'),
    update: (data) => request('/api/settings', { method: 'PATCH', body: data }),
  },
};

export default api;
