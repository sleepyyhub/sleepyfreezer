/**
 * Fixed-window rate limiting.
 *
 * Deliberately simple: Clovyre runs as a single instance, so a shared in-process
 * map is both correct and cheap. Buckets are swept lazily on access.
 */

export interface RateLimitResult {
  readonly allowed: boolean;
  readonly remaining: number;
  readonly resetAt: number;
  readonly retryAfterMs: number;
}

interface Bucket {
  count: number;
  resetAt: number;
}

export interface RateLimitRule {
  readonly limit: number;
  readonly windowMs: number;
}

export class RateLimiter {
  private readonly buckets = new Map<string, Bucket>();
  private lastSweep = Date.now();

  constructor(private readonly rules: Record<string, RateLimitRule>) {}

  check(ruleName: string, key: string, now = Date.now()): RateLimitResult {
    const rule = this.rules[ruleName];
    if (!rule) {
      throw new Error(`Unknown rate limit rule: ${ruleName}`);
    }
    this.sweep(now);

    const bucketKey = `${ruleName}:${key}`;
    const existing = this.buckets.get(bucketKey);
    if (!existing || existing.resetAt <= now) {
      const resetAt = now + rule.windowMs;
      this.buckets.set(bucketKey, { count: 1, resetAt });
      return { allowed: true, remaining: rule.limit - 1, resetAt, retryAfterMs: 0 };
    }

    if (existing.count >= rule.limit) {
      return {
        allowed: false,
        remaining: 0,
        resetAt: existing.resetAt,
        retryAfterMs: existing.resetAt - now,
      };
    }

    existing.count += 1;
    return {
      allowed: true,
      remaining: rule.limit - existing.count,
      resetAt: existing.resetAt,
      retryAfterMs: 0,
    };
  }

  /** Drops a bucket, e.g. after a successful authentication. */
  reset(ruleName: string, key: string): void {
    this.buckets.delete(`${ruleName}:${key}`);
  }

  private sweep(now: number): void {
    if (now - this.lastSweep < 30_000) return;
    this.lastSweep = now;
    for (const [key, bucket] of this.buckets) {
      if (bucket.resetAt <= now) this.buckets.delete(key);
    }
  }

  get bucketCount(): number {
    return this.buckets.size;
  }
}

export const RATE_LIMIT_RULES = {
  /** Session creation, keyed by client IP. */
  session_create: { limit: 12, windowMs: 60_000 },
  /** Roblox gateway handshake attempts, keyed by IP. */
  ws_handshake: { limit: 30, windowMs: 60_000 },
  /** MCP JSON-RPC requests, keyed by session. */
  mcp_request: { limit: 240, windowMs: 60_000 },
  /** Tool invocations dispatched to the Roblox client, keyed by session. */
  tool_call: { limit: 120, windowMs: 60_000 },
  /** Privileged Luau execution, keyed by session. */
  execute_luau: { limit: 12, windowMs: 60_000 },
  /** Owner-authenticated dashboard mutations, keyed by session. */
  owner_action: { limit: 60, windowMs: 60_000 },
} as const satisfies Record<string, RateLimitRule>;

export type RateLimitRuleName = keyof typeof RATE_LIMIT_RULES;

type LimiterGlobal = typeof globalThis & { __clovyreRateLimiter?: RateLimiter };

export function getRateLimiter(): RateLimiter {
  const store = globalThis as LimiterGlobal;
  if (!store.__clovyreRateLimiter) {
    store.__clovyreRateLimiter = new RateLimiter(RATE_LIMIT_RULES);
  }
  return store.__clovyreRateLimiter;
}
