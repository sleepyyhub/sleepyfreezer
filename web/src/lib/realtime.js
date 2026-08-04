import { api } from './api.js';

/**
 * Live updates are optional. Sending a message returns the replies over HTTP,
 * so the app is fully usable without Pusher configured — realtime only adds
 * character-to-character messages appearing as they land, and proactive DMs
 * arriving without a refresh.
 */

const KEY = import.meta.env.VITE_PUSHER_KEY ?? '';
const CLUSTER = import.meta.env.VITE_PUSHER_CLUSTER ?? 'eu';

let clientPromise = null;

async function getClient() {
  if (!KEY) return null;
  if (!clientPromise) {
    clientPromise = import('pusher-js')
      .then(({ default: Pusher }) => new Pusher(KEY, {
        cluster: CLUSTER,
        channelAuthorization: {
          // A custom handler so the session cookie rides along; the default
          // ajax transport does not send credentials cross-origin.
          customHandler: ({ socketId, channelName }, callback) => {
            fetch(`${api.base}/api/auth/realtime`, {
              method: 'POST',
              credentials: 'include',
              headers: { 'Content-Type': 'application/json' },
              body: JSON.stringify({ socket_id: socketId, channel_name: channelName }),
            })
              .then((res) => (res.ok ? res.json() : Promise.reject(new Error(`auth ${res.status}`))))
              .then((data) => callback(null, data))
              .catch((err) => callback(err, null));
          },
        },
      }))
      .catch((err) => {
        console.warn('[realtime] disabled:', err.message);
        return null;
      });
  }
  return clientPromise;
}

/**
 * Subscribe to one channel. Returns an unsubscribe function that is safe to
 * call even if the connection never came up.
 */
export function subscribe(channel, handlers = {}) {
  let bound = null;
  let cancelled = false;

  getClient().then((client) => {
    if (!client || cancelled) return;
    bound = client.subscribe(channel);
    for (const [event, handler] of Object.entries(handlers)) {
      bound.bind(event, handler);
    }
  });

  return () => {
    cancelled = true;
    if (!bound) return;
    for (const event of Object.keys(handlers)) bound.unbind(event);
    getClient().then((client) => client?.unsubscribe(channel));
  };
}

export const channels = {
  user: (id) => `private-user-${id}`,
  conversation: (id) => `private-conversation-${id}`,
  group: (id) => `private-group-${id}`,
};

export const realtimeEnabled = Boolean(KEY);
