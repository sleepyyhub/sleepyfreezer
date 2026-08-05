import { createHmac, randomBytes, timingSafeEqual } from 'node:crypto';
import { getConfig } from '../config';

/**
 * Credential generation, hashing and comparison.
 *
 * Clovyre never stores a reusable credential in plaintext. Tokens are handed to
 * the client once and only an HMAC-SHA256 digest is retained, so a memory dump
 * of the session store does not yield working credentials.
 */

const BASE62 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';

/** Unambiguous alphabet for the human-visible session id (no O/0/I/l/1). */
const DISPLAY_ALPHABET = 'ABCDEFGHJKMNPQRSTUVWXYZ23456789';

function randomFromAlphabet(length: number, alphabet: string): string {
  const out: string[] = [];
  const limit = Math.floor(256 / alphabet.length) * alphabet.length;
  while (out.length < length) {
    for (const byte of randomBytes(length * 2)) {
      if (out.length >= length) break;
      if (byte >= limit) continue; // reject to keep the distribution uniform
      out.push(alphabet[byte % alphabet.length]!);
    }
  }
  return out.join('');
}

/**
 * Public, shareable session identifier. This is an addressing value only — it is
 * never accepted as proof of authorization on any privileged route.
 */
export function generateSessionId(): string {
  return `cs_${randomFromAlphabet(20, DISPLAY_ALPHABET)}`;
}

export type TokenRole = 'roblox' | 'mcp' | 'owner';

const ROLE_PREFIX: Record<TokenRole, string> = {
  roblox: 'crx',
  mcp: 'cmc',
  owner: 'cow',
};

/** 256 bits of entropy encoded in base62, tagged with its role. */
export function generateToken(role: TokenRole): string {
  return `${ROLE_PREFIX[role]}_${randomFromAlphabet(43, BASE62)}`;
}

export function generateCommandId(): string {
  return `cmd_${randomFromAlphabet(18, BASE62)}`;
}

export function generateEventId(): string {
  return `ev_${randomFromAlphabet(14, BASE62)}`;
}

/** Keyed digest of a credential. The key comes from TOKEN_HASH_SECRET. */
export function hashToken(token: string): string {
  return createHmac('sha256', getConfig().tokenHashSecret).update(token, 'utf8').digest('hex');
}

/** Constant-time comparison of a presented token against a stored digest. */
export function verifyToken(presented: string | null | undefined, storedHash: string): boolean {
  if (typeof presented !== 'string' || presented.length === 0) return false;
  const candidate = Buffer.from(hashToken(presented), 'utf8');
  const expected = Buffer.from(storedHash, 'utf8');
  if (candidate.length !== expected.length) return false;
  return timingSafeEqual(candidate, expected);
}

/** Constant-time comparison of two same-purpose plaintext values (CSRF tokens). */
export function safeEqual(a: string | null | undefined, b: string | null | undefined): boolean {
  if (typeof a !== 'string' || typeof b !== 'string') return false;
  const left = Buffer.from(a, 'utf8');
  const right = Buffer.from(b, 'utf8');
  if (left.length !== right.length) return false;
  return timingSafeEqual(left, right);
}

/**
 * Renders a credential for display in logs or audit trails: enough to correlate,
 * never enough to replay.
 */
export function fingerprint(token: string): string {
  return hashToken(token).slice(0, 12);
}
