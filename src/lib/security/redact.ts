/**
 * Redaction helpers. Everything that reaches a log line, an audit event or an
 * API response passes through here first.
 */

const TOKEN_PATTERN = /\b(crx|cmc|cow)_[A-Za-z0-9]{20,}\b/g;
const RENDER_KEY_PATTERN = /\brnd_[A-Za-z0-9]{16,}\b/g;
const GITHUB_TOKEN_PATTERN = /\b(gh[pousr]_[A-Za-z0-9]{16,}|github_pat_[A-Za-z0-9_]{20,})\b/g;
const BEARER_PATTERN = /\b(bearer)\s+[A-Za-z0-9._~+/=-]{8,}/gi;

const SENSITIVE_KEY_PATTERN =
  /^(authorization|cookie|set-cookie|x-clovyre-token|x-csrf-token|token|secret|password|apikey|api_key|robloxtoken|mcptoken|ownertoken|managementtoken)$/i;

export const REDACTED = '[redacted]';

/** Scrubs credential-shaped substrings out of free text. */
export function redactText(input: string): string {
  return input
    .replace(BEARER_PATTERN, `$1 ${REDACTED}`)
    .replace(TOKEN_PATTERN, REDACTED)
    .replace(RENDER_KEY_PATTERN, REDACTED)
    .replace(GITHUB_TOKEN_PATTERN, REDACTED);
}

/** Returns a copy of the headers with every sensitive value replaced. */
export function redactHeaders(
  headers: Record<string, string | string[] | undefined>,
): Record<string, string> {
  const out: Record<string, string> = {};
  for (const [key, value] of Object.entries(headers)) {
    if (value === undefined) continue;
    const flat = Array.isArray(value) ? value.join(', ') : value;
    out[key] = SENSITIVE_KEY_PATTERN.test(key) ? REDACTED : redactText(flat);
  }
  return out;
}

export type JsonValue =
  | string
  | number
  | boolean
  | null
  | JsonValue[]
  | { [key: string]: JsonValue };

/**
 * Deep-redacts a JSON-ish structure: sensitive keys are masked wholesale and
 * remaining strings are scanned for credential patterns.
 */
export function redactValue(value: unknown, depth = 0): JsonValue {
  if (depth > 8) return '[depth limit]';
  if (value === null || value === undefined) return null;
  if (typeof value === 'string') return redactText(value);
  if (typeof value === 'number') return Number.isFinite(value) ? value : String(value);
  if (typeof value === 'boolean') return value;
  if (Array.isArray(value)) {
    return value.slice(0, 50).map((item) => redactValue(item, depth + 1));
  }
  if (typeof value === 'object') {
    const out: Record<string, JsonValue> = {};
    for (const [key, entry] of Object.entries(value as Record<string, unknown>)) {
      out[key] = SENSITIVE_KEY_PATTERN.test(key) ? REDACTED : redactValue(entry, depth + 1);
    }
    return out;
  }
  return `[${typeof value}]`;
}

/** Compact, size-bounded preview of a value for activity feeds. */
export function abbreviate(value: unknown, maxChars = 240): string {
  let text: string;
  try {
    text = typeof value === 'string' ? value : JSON.stringify(redactValue(value));
  } catch {
    text = '[unserializable]';
  }
  if (text === undefined) text = 'undefined';
  text = redactText(text);
  if (text.length <= maxChars) return text;
  return `${text.slice(0, maxChars)}… (+${text.length - maxChars} chars)`;
}
