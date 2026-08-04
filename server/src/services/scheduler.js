import config from '../config.js';
import { runProactiveSweep } from './proactive.js';

/**
 * Runs the proactive sweep on a timer inside the API process, so no external
 * cron service is needed. Any ping that keeps the host awake is then enough for
 * characters to reach out on their own.
 *
 * `POST /api/cron/proactive` still works and is the better choice if you run
 * more than one instance — this timer fires per process, so two instances would
 * sweep twice. Set PROACTIVE_INTERVAL_MINUTES=0 to turn it off and use only the
 * endpoint.
 */

let running = false;

async function tick() {
  // A sweep makes a model call per due user, so it can outlast a short
  // interval. Skipping rather than queueing avoids a pile-up.
  if (running) {
    console.warn('[scheduler] previous sweep still running — skipping this tick');
    return;
  }

  running = true;
  try {
    const started = Date.now();
    const { checked, sent } = await runProactiveSweep();
    if (sent > 0) {
      console.log(`[scheduler] swept ${checked} users, sent ${sent} (${Date.now() - started}ms)`);
    }
  } catch (err) {
    console.error('[scheduler] sweep failed:', err.message);
  } finally {
    running = false;
  }
}

export function startScheduler() {
  const minutes = config.proactive.intervalMinutes;
  if (!minutes) {
    console.log('  cron:   internal scheduler off — POST /api/cron/proactive to sweep');
    return null;
  }

  const timer = setInterval(tick, minutes * 60 * 1000);

  // A first sweep shortly after boot, so a host that just woke from sleep
  // delivers anything that came due while it was down.
  setTimeout(tick, 30_000).unref();

  console.log(`  cron:   internal scheduler every ${minutes}m`);
  return timer;
}

export default startScheduler;
