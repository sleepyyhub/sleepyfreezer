import { Router } from 'express';
import { requireCronSecret } from '../middleware/auth.js';
import { runProactiveSweep } from '../services/proactive.js';

const router = Router();

/**
 * POST /api/cron/proactive
 *
 * Meant to run every 30-60 minutes. The sweep decides internally which users
 * are actually due, so firing it more often than necessary is harmless.
 */
router.post('/proactive', requireCronSecret, async (_req, res, next) => {
  try {
    const started = Date.now();
    const result = await runProactiveSweep();
    res.json({ ...result, ms: Date.now() - started });
  } catch (err) {
    next(err);
  }
});

export default router;
