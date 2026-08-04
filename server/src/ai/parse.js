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

  // A truncated reply has no closing bracket at all, so this is only worth
  // trying when one exists — repair below handles the rest.
  if (end > start) {
    try {
      return JSON.parse(body.slice(start, end + 1));
    } catch {
      // Fall through to repair.
    }
  }

  // A reply cut off mid-object is common when reasoning tokens eat the budget.
  // Closing the open string and braces recovers every complete field.
  const repaired = repairTruncatedJson(body.slice(start));
  if (repaired) {
    try {
      return JSON.parse(repaired);
    } catch {
      return fallback;
    }
  }

  return fallback;
}

/**
 * Close an object that stops mid-value. Everything already written stays;
 * only the incomplete tail is discarded.
 */
function repairTruncatedJson(text) {
  let inString = false;
  let escaped = false;
  const stack = [];
  let lastComplete = -1;
  let closersAtCut = null;

  for (let i = 0; i < text.length; i += 1) {
    const ch = text[i];

    if (escaped) { escaped = false; continue; }
    if (ch === '\\' && inString) { escaped = true; continue; }
    if (ch === '"') { inString = !inString; continue; }
    if (inString) continue;

    if (ch === '{' || ch === '[') stack.push(ch === '{' ? '}' : ']');
    else if (ch === '}' || ch === ']') stack.pop();
    else if (ch === ',' && stack.length === 1) {
      // A comma at depth 1 ends a complete top-level field. Remember how deep
      // we were here, not how deep the truncated tail went — closing to the
      // wrong depth produces something like {"a": "b"]} which parses no better.
      lastComplete = i;
      closersAtCut = [...stack];
    }
  }

  if (stack.length === 0) return null; // not truncated
  if (lastComplete === -1) return null; // nothing complete to salvage

  return text.slice(0, lastComplete) + closersAtCut.reverse().join('');
}

/**
 * Does this read as the model narrating its task instead of playing the part?
 *
 * A character never refers to "the user", never plans a reply out loud, and
 * never describes itself in the third person. Any one of these is conclusive,
 * so a single hit is enough — the cost of a false positive is one regenerated
 * message, while a miss puts raw chain-of-thought in front of a reader.
 */
const META_SIGNALS = [
  /\brole:\s*(user|assistant|system)\b/i,
  /\bthe user\b/i,
  /\bLet me (craft|draft|write|re-?read|think|analyz|consider|check|look)/i,
  /\bI (should|need to|will|must) (respond|reply|answer|say|write|keep|stay|start|begin)/i,
  /\bin character as\b|\bstay in character\b/i,
  /\bsystem prompt\b|\binner monologue line\b|\bthought line\b/i,
  /\bmy (previous )?(response|reply|answer)\b/i,
  /\b(she|he|they)'?s (laid-back|blunt|shy|energetic|serious|supposed to)\b/i,
  /^\s*[-*]\s+(She|He|They)'?(s| is| should| would)\b/m,
  /\bconversation (flow|history|so far)\b/i,
  /\bTurn \d+\s*:/i,
];

// A character asking for an illustration: [scene: ...] on its own.
const SCENE_MARKER = /\[\s*scene\s*:\s*([^\]]+)\]/i;

/**
 * Split off a scene request. The marker is an instruction to the app, never
 * something the reader should see, so it always comes out of the text whether
 * or not an image ends up being drawn.
 */
export function extractScene(text) {
  const match = (text ?? '').match(SCENE_MARKER);
  if (!match) return { content: text ?? '', scene: null };
  return {
    content: (text ?? '').replace(SCENE_MARKER, '').replace(/\n{3,}/g, '\n\n').trim(),
    scene: match[1].trim().slice(0, 400),
  };
}

export function looksLikeMetaReasoning(text) {
  if (!text) return false;
  return META_SIGNALS.some((re) => re.test(text));
}

/**
 * When the model narrates first and then writes the line anyway, the real reply
 * follows a drafting marker. Recover it rather than paying for another call.
 */
const DRAFT_MARKER =
  /(?:let me (?:craft|draft|write)[^:\n]*:|^\s*(?:draft|response|reply|my reply)\s*:)\s*/gim;

export function salvageAfterDraft(text) {
  if (!text) return '';
  let last = null;
  let match;
  DRAFT_MARKER.lastIndex = 0;
  while ((match = DRAFT_MARKER.exec(text)) !== null) last = match;
  if (!last) return '';
  const tail = text.slice(last.index + last[0].length).trim();
  // A salvaged tail that still narrates is no better than what we started with.
  return tail && !looksLikeMetaReasoning(tail) ? tail : '';
}

function escapeRegex(s) {
  return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
}

export default parseReply;
