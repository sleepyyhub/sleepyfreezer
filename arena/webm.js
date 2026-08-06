/*
 * webm.js — write a Duration into a MediaRecorder WebM.
 *
 * MediaRecorder produces a live stream: it never knows how long the recording
 * will be, so it omits the Duration element from the Segment Info header. The
 * file plays, but players report a length of 0:00 and refuse to seek, which
 * makes a perfectly good recording look broken.
 *
 * We know the real duration once recording stops, so we patch it in. The
 * Segment element uses an "unknown size" marker, so inserting bytes inside
 * Info only requires fixing Info's own size — no ancestor sizes change.
 *
 * Everything here is best-effort: if the layout is not what we expect, the
 * original bytes are returned untouched rather than risking a corrupt file.
 */

const ID_SEGMENT = [0x18, 0x53, 0x80, 0x67];
const ID_INFO = [0x15, 0x49, 0xa9, 0x66];
const ID_DURATION = [0x44, 0x89];

// Info sits in the header, well before any cluster payload. Bounding the
// search stops us matching these bytes by chance inside compressed video data.
const SEARCH_LIMIT = 8192;

function indexOfBytes(bytes, pattern, from = 0, to = bytes.length) {
  const last = Math.min(to, bytes.length) - pattern.length;
  outer: for (let i = from; i <= last; i++) {
    for (let j = 0; j < pattern.length; j++) {
      if (bytes[i + j] !== pattern[j]) continue outer;
    }
    return i;
  }
  return -1;
}

/** Read an EBML variable-length integer. Returns null if malformed. */
export function readVint(bytes, pos) {
  const first = bytes[pos];
  if (first === undefined || first === 0) return null;
  let length = 1;
  for (let mask = 0x80; mask && !(first & mask); mask >>= 1) length++;
  if (length > 8 || pos + length > bytes.length) return null;

  let value = first & (0xff >> length);
  for (let i = 1; i < length; i++) value = value * 256 + bytes[pos + i];
  return { value, length };
}

/** Encode `value` as an EBML vint using exactly `length` bytes. */
export function writeVint(value, length) {
  const out = new Uint8Array(length);
  let remaining = value;
  for (let i = length - 1; i >= 0; i--) {
    out[i] = remaining % 256;
    remaining = Math.floor(remaining / 256);
  }
  out[0] |= 1 << (8 - length);
  return out;
}

/**
 * Insert or overwrite the Segment Info Duration.
 *
 * @param {Uint8Array} bytes    the recorded WebM
 * @param {number} durationMs   real duration in milliseconds
 * @returns {Uint8Array}        patched bytes, or the input if patching is unsafe
 */
export function patchWebmDuration(bytes, durationMs) {
  if (!(bytes instanceof Uint8Array) || !Number.isFinite(durationMs) || durationMs <= 0) {
    return bytes;
  }

  const segment = indexOfBytes(bytes, ID_SEGMENT, 0, SEARCH_LIMIT);
  if (segment === -1) return bytes;

  const info = indexOfBytes(bytes, ID_INFO, segment, SEARCH_LIMIT);
  if (info === -1) return bytes;

  const sizePos = info + ID_INFO.length;
  const size = readVint(bytes, sizePos);
  if (!size) return bytes;

  const bodyStart = sizePos + size.length;
  const bodyEnd = bodyStart + size.value;
  if (bodyEnd > bytes.length) return bytes;

  // Duration is stored in timecode-scale units. MediaRecorder always writes a
  // scale of 1ms, which is what makes milliseconds the right unit here.
  const existing = indexOfBytes(bytes, ID_DURATION, bodyStart, bodyEnd);
  if (existing !== -1) {
    const durSize = readVint(bytes, existing + ID_DURATION.length);
    if (!durSize) return bytes;
    const valuePos = existing + ID_DURATION.length + durSize.length;
    const out = bytes.slice();
    const view = new DataView(out.buffer, out.byteOffset, out.byteLength);
    if (durSize.value === 4) view.setFloat32(valuePos, durationMs, false);
    else if (durSize.value === 8) view.setFloat64(valuePos, durationMs, false);
    else return bytes;
    return out;
  }

  // Build "Duration" as an 8-byte big-endian float element.
  const element = new Uint8Array(11);
  element[0] = ID_DURATION[0];
  element[1] = ID_DURATION[1];
  element[2] = 0x88; // vint: 8 bytes of payload
  new DataView(element.buffer).setFloat64(3, durationMs, false);

  // Re-encode Info's size, keeping the same vint width so nothing shifts twice.
  const newSize = size.value + element.length;
  const maxForWidth = 2 ** (7 * size.length) - 2;
  if (newSize > maxForWidth) return bytes;
  const encodedSize = writeVint(newSize, size.length);

  const out = new Uint8Array(bytes.length + element.length);
  out.set(bytes.subarray(0, sizePos), 0);
  out.set(encodedSize, sizePos);
  out.set(element, bodyStart);
  out.set(bytes.subarray(bodyStart), bodyStart + element.length);
  return out;
}
