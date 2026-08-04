/**
 * Split a message into spoken text and roleplay action.
 *
 * Characters narrate physical action in asterisks — `*steps back*`, `*yawns
 * dramatically*` — which is convention, not markup the reader should see. The
 * asterisks come out and the action is styled apart from speech.
 *
 * Both `*single*` and `**double**` are treated the same way. Models mix them
 * freely and the distinction carries no meaning here.
 */

// Double first, so `**x**` is not mistaken for an empty `*` pair around `*x*`.
// Both ends must sit against a non-space character, which is the markdown rule
// and what keeps arithmetic like `2 * 3` from being read as an action.
const SEGMENT = /\*\*(\S(?:[^*\n]*\S)?)\*\*|\*(\S(?:[^*\n]*\S)?)\*/g;

// An action still being typed: an opening asterisk with no closing one yet.
const UNCLOSED = /\*{1,2}(\S[^*\n]*)?$/;

/**
 * @returns {{type: 'text'|'action', value: string}[]}
 */
export function splitRoleplay(input) {
  const text = input ?? '';
  if (!text) return [];

  const segments = [];
  let cursor = 0;
  let match;

  SEGMENT.lastIndex = 0;
  while ((match = SEGMENT.exec(text)) !== null) {
    if (match.index > cursor) {
      segments.push({ type: 'text', value: text.slice(cursor, match.index) });
    }
    segments.push({ type: 'action', value: match[1] ?? match[2] });
    cursor = match.index + match[0].length;
  }

  let tail = text.slice(cursor);

  // While the typewriter is mid-action the closing asterisk has not arrived.
  // Rendering it as action already avoids a visible flicker when it does.
  const open = tail.match(UNCLOSED);
  if (open) {
    const before = tail.slice(0, open.index);
    if (before) segments.push({ type: 'text', value: before });
    if (open[1]) segments.push({ type: 'action', value: open[1] });
    tail = '';
  }

  if (tail) segments.push({ type: 'text', value: tail });

  return segments;
}

/** Plain text with the markers removed — for previews and notifications. */
export function stripRoleplay(input) {
  return splitRoleplay(input).map((s) => s.value).join('').replace(/\s+/g, ' ').trim();
}

export default splitRoleplay;
