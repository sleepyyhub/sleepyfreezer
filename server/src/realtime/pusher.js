import Pusher from 'pusher';
import config from '../config.js';

const configured =
  config.pusher.appId && config.pusher.key && config.pusher.secret;

const pusher = configured
  ? new Pusher({
      appId: config.pusher.appId,
      key: config.pusher.key,
      secret: config.pusher.secret,
      cluster: config.pusher.cluster,
      useTLS: true,
    })
  : null;

if (!configured) {
  console.warn(
    '[realtime] Pusher not configured — live events are disabled. ' +
      'Responses still return over HTTP; only pushed updates are lost.',
  );
}

export async function emit(channel, event, payload) {
  if (!pusher) return;
  try {
    await pusher.trigger(channel, event, payload);
  } catch (err) {
    // A dropped realtime event must never fail the request that caused it.
    console.error(`[realtime] ${channel}/${event} failed:`, err.message);
  }
}

export const channels = {
  user: (userId) => `private-user-${userId}`,
  conversation: (id) => `private-conversation-${id}`,
  group: (id) => `private-group-${id}`,
};

/** Authorises a client subscription. The route checks ownership first. */
export function authorize(socketId, channel) {
  if (!pusher) throw new Error('Realtime is not configured');
  return pusher.authorizeChannel(socketId, channel);
}

export default { emit, channels, authorize };
