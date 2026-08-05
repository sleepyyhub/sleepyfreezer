import { z } from 'zod';
import { normalizeIncoming } from '../serialization/roblox-value';
import { OBSERVATION_LIMITS, type SessionRecord } from './types';

/**
 * Ingest for observations the client pushes between commands.
 *
 * Watchers and the remote spy are asynchronous: the client reports changes as
 * they happen rather than answering a request, so these arrive as `event` frames
 * and land in bounded ring buffers the agent polls with a tool.
 *
 * Everything here is untrusted client input and is re-validated and re-bounded
 * on arrival, exactly like a command result.
 */

export const watchEventSchema = z.object({
  watchId: z.string().max(64),
  kind: z.enum(['property', 'childAdded', 'childRemoved', 'attribute']),
  target: z.string().max(2048),
  detail: z.unknown().optional(),
  at: z.number().optional(),
});

export const remoteCallSchema = z.object({
  remote: z.string().max(2048),
  className: z.string().max(64),
  method: z.string().max(64),
  args: z.unknown().optional(),
  argCount: z.number().int().min(0).max(1000).optional(),
  callerScript: z.string().max(512).nullish(),
  truncated: z.boolean().optional(),
  at: z.number().optional(),
});

export const watchStateSchema = z.object({
  watches: z
    .array(
      z.object({
        watchId: z.string().max(64),
        target: z.string().max(2048),
        kinds: z.array(z.string().max(32)).max(8),
      }),
    )
    .max(OBSERVATION_LIMITS.maxActiveWatches),
});

export const remoteSpyStateSchema = z.object({ active: z.boolean() });

function push<T>(buffer: T[], item: T, max: number): boolean {
  buffer.push(item);
  if (buffer.length <= max) return false;
  buffer.shift();
  return true;
}

/**
 * Routes one `event` frame into session state.
 * Returns true when the event was recognised and consumed.
 */
export function ingestClientEvent(session: SessionRecord, event: string, data: unknown): boolean {
  const observations = session.observations;

  switch (event) {
    case 'watch': {
      const parsed = watchEventSchema.safeParse(data);
      if (!parsed.success) return false;
      const { value } = normalizeIncoming(parsed.data.detail);
      const dropped = push(
        observations.watchEvents,
        {
          at: parsed.data.at ?? Date.now(),
          watchId: parsed.data.watchId,
          kind: parsed.data.kind,
          target: parsed.data.target,
          detail: value,
        },
        OBSERVATION_LIMITS.maxWatchEvents,
      );
      if (dropped) observations.droppedWatchEvents += 1;
      return true;
    }

    case 'remote_call': {
      const parsed = remoteCallSchema.safeParse(data);
      if (!parsed.success) return false;
      const { value, report } = normalizeIncoming(parsed.data.args);
      const dropped = push(
        observations.remoteCalls,
        {
          at: parsed.data.at ?? Date.now(),
          remote: parsed.data.remote,
          className: parsed.data.className,
          method: parsed.data.method,
          args: value,
          argCount: parsed.data.argCount ?? 0,
          callerScript: parsed.data.callerScript ?? null,
          truncated: Boolean(parsed.data.truncated) || report.truncated,
        },
        OBSERVATION_LIMITS.maxRemoteCalls,
      );
      if (dropped) observations.droppedRemoteCalls += 1;
      return true;
    }

    case 'watch_state': {
      const parsed = watchStateSchema.safeParse(data);
      if (!parsed.success) return false;
      observations.activeWatches.clear();
      for (const watch of parsed.data.watches) {
        observations.activeWatches.set(watch.watchId, {
          target: watch.target,
          kinds: watch.kinds,
          startedAt: Date.now(),
        });
      }
      return true;
    }

    case 'remote_spy_state': {
      const parsed = remoteSpyStateSchema.safeParse(data);
      if (!parsed.success) return false;
      observations.remoteSpyActive = parsed.data.active;
      observations.remoteSpyStartedAt = parsed.data.active ? Date.now() : null;
      return true;
    }

    default:
      return false;
  }
}

/** Clears observation state when a client disconnects; the hooks went with it. */
export function resetObservations(session: SessionRecord): void {
  session.observations.activeWatches.clear();
  session.observations.remoteSpyActive = false;
  session.observations.remoteSpyStartedAt = null;
}
