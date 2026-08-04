/**
 * Split a raw model reply into { thought, content }.
 *
 * We ask characters to open with `*Name thinks: ...*`, but reasoning models
 * also leak `<think>` blocks and providers expose `reasoning_content`
 * separately. All three end up in the same place: the thought bubble above
 * the message.
 */

const THINK_TAG = /<think(?:ing)?>([\s\S]*?)<\/think(?:ing)?>/i;
const UNCLOSED_THINK_TAG = /^\s*<think(?:ing)?>([\s\S]*)$/i;

// *Nino thinks: ...*  /  *Nino thought: ...*  /  (Nino thinks: ...)
const THOUGHT_LINE =
  /^\s*[*_(\[]{1,2}\s*([^*_:()\[\]\n]{1,60}?)\s+think(?:s|ing|though?t)?\s*:\s*([\s\S]*?)\s*[*_)\]]{1,2}\s*(?:\n|$)/i;

// Bare form with no wrapping punctuation, e.g. "Nino thinks: ..." on line one.
const BARE_THOUGHT_LINE = /^\s*([^\n:]{1,60}?)\s+think(?:s|ing)?\s*:\s*([^\n]*)\n/i;

// Same shape but anywhere in the body. Models sometimes emit a second thought
// line mid-reply; it must never render as spoken dialogue.
const STRAY_THOUGHT = /[*_]{1,2}\s*[^*_:()\[\]\n]{1,60}?\s+think(?:s|ing)?\s*:\s*[^*_\n]*[*_]{1,2}/gi;

// Reasoning models occasionally leak their planning prose into `content`
// instead of the reasoning field. It always opens in the same few ways.
const LEAKED_PLANNING =
  /^\s*(?:We need to|We should|I need to|Let me|The user (?:says|asks|wants)|Okay,? so)\b[\s\S]{0,600}?(?:\n\n|$)/i;

const clean = (s) =>
  (s ?? '')
    .replace(/\s+/g, ' ')
    .trim();

export function parseReply(raw, { reasoning = null, name = '' } = {}) {
  let text = (raw ?? '').trim();
  let thought = null;

  // Some providers hand back an empty `content` and put the whole reply —
  // thought line and spoken text together — in the reasoning channel. Treat
  // that as the body rather than mistaking all of it for the inner monologue.
  const reasoningIsBody = !text && Boolean(reasoning?.trim());
  if (reasoningIsBody) text = reasoning.trim();

  const tagged = text.match(THINK_TAG);
  if (tagged) {
    thought = clean(tagged[1]);
    text = text.replace(THINK_TAG, '').trim();
  } else {
    const unclosed = text.match(UNCLOSED_THINK_TAG);
    if (unclosed) {
      // Model ran out of tokens mid-thought — salvage what we can.
      thought = clean(unclosed[1]);
      text = '';
    }
  }

  if (!thought) {
    const marked = text.match(THOUGHT_LINE) || text.match(BARE_THOUGHT_LINE);
    if (marked) {
      thought = clean(marked[2]);
      text = text.slice(marked[0].length).trim();
    }
  }

  // Any further thought lines further down are stripped out of the spoken
  // text — the first one we find becomes the thought if we still lack one.
  const strays = text.match(STRAY_THOUGHT);
  if (strays) {
    if (!thought) {
      const inner = strays[0].match(/think(?:s|ing)?\s*:\s*([^*_\n]*)/i);
      if (inner) thought = clean(inner[1]);
    }
    text = text.replace(STRAY_THOUGHT, '').replace(/\n{3,}/g, '\n\n').trim();
  }

  // Drop planning prose that leaked out of the reasoning channel. Only safe
  // when something remains afterwards, otherwise we would blank the message.
  const leaked = text.match(LEAKED_PLANNING);
  if (leaked && text.slice(leaked[0].length).trim()) {
    text = text.slice(leaked[0].length).trim();
  }

  // Provider-side reasoning is the last resort — it is the least in-character
  // of the three, so we only use it when the model gave us nothing better and
  // we have not already consumed it as the message body.
  if (!thought && reasoning && !reasoningIsBody) thought = clean(reasoning);

  // Strip a leading "Name:" speaker label; the UI already shows who is talking.
  if (name) {
    const label = new RegExp(`^\\s*${escapeRegex(name)}\\s*:\\s*`, 'i');
    text = text.replace(label, '').trim();
  }

  return { thought: thought || null, content: text };
}

/**
 * Pull a JSON value out of a reply that may be fenced or padded with prose.
 * Used by the group director, which is asked to answer with JSON only.
 */
export function parseJson(raw, fallback = null) {
  if (!raw) return fallback;

  const fenced = raw.match(/```(?:json)?\s*([\s\S]*?)```/i);
  const body = fenced ? fenced[1] : raw;

  const start = body.search(/[[{]/);
  if (start === -1) return fallback;

  const opener = body[start];
  const closer = opener === '[' ? ']' : '}';
  const end = body.lastIndexOf(closer);
  if (end <= start) return fallback;

  try {
    return JSON.parse(body.slice(start, end + 1));
  } catch {
    return fallback;
  }
}

function escapeRegex(s) {
  return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

export default parseReply;
