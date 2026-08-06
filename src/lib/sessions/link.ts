import { createHmac, randomBytes, timingSafeEqual } from 'node:crypto';
import { getConfig } from '../config';

/**
 * Persistent agent links.
 *
 * A per-session MCP URL means reconfiguring the agent every time a session is
 * created, which is the single most tedious thing about running Clovyre. A link
 * fixes that: it is a stable URL that resolves, at request time, to whichever
 * session is currently bound to it.
 *
 * The link is **stateless and self-authenticating** — an owner id plus an HMAC
 * over it, keyed by TOKEN_HASH_SECRET. That matters because sessions live in
 * memory: anything stored server-side would die with the process and the URL
 * would break again on every restart, defeating the point. A signed token needs
 * no storage, so the same URL keeps working across restarts and redeploys.
 *
 * The security trade-off is real and deliberate. A per-session token leaks a
 * single session; a link token leaks every session you ever bind to it, until
 * you rotate the link. It is therefore treated as a long-lived credential:
 * rotatable from the dashboard, and never mixed with the per-session tokens.
 */

const LINK_PREFIX = 'clk_';

export interface AgentLink {
  /** Opaque stable identity for one dashboard user. */
  readonly ownerId: string;
  /** The full token handed to the agent, `clk_<ownerId>.<mac>`. */
  readonly token: string;
}

function sign(ownerId: string): string {
  return createHmac('sha256', getConfig().tokenHashSecret)
    .update(`agent-link:${ownerId}`)
    .digest('base64url');
}

/** Mints a brand new link. The owner id is 128 bits of entropy. */
export function createAgentLink(): AgentLink {
  const ownerId = randomBytes(16).toString('base64url');
  return { ownerId, token: `${LINK_PREFIX}${ownerId}.${sign(ownerId)}` };
}

/**
 * Verifies a link token and returns its owner id, or null when the signature
 * does not check out. Rotating TOKEN_HASH_SECRET invalidates every link.
 */
export function verifyAgentLink(token: string | null | undefined): string | null {
  if (typeof token !== 'string' || !token.startsWith(LINK_PREFIX)) return null;

  const body = token.slice(LINK_PREFIX.length);
  const separator = body.lastIndexOf('.');
  if (separator <= 0) return null;

  const ownerId = body.slice(0, separator);
  const presented = body.slice(separator + 1);
  if (ownerId.length === 0 || presented.length === 0) return null;

  const expected = sign(ownerId);
  const a = Buffer.from(presented, 'utf8');
  const b = Buffer.from(expected, 'utf8');
  if (a.length !== b.length) return null;
  if (!timingSafeEqual(a, b)) return null;

  return ownerId;
}

/** Rebuilds the full token for a known owner id. */
export function agentLinkTokenFor(ownerId: string): string {
  return `${LINK_PREFIX}${ownerId}.${sign(ownerId)}`;
}

/** Short, non-reversible label for audit lines. */
export function linkFingerprint(ownerId: string): string {
  return createHmac('sha256', getConfig().tokenHashSecret)
    .update(`agent-link-fp:${ownerId}`)
    .digest('hex')
    .slice(0, 12);
}
