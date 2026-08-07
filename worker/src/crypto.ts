// Crypto helpers for SleepyAuth. Uses WebCrypto (available in Workers).

const enc = new TextEncoder();

export function toHex(buf: ArrayBuffer): string {
  return [...new Uint8Array(buf)].map((b) => b.toString(16).padStart(2, "0")).join("");
}
export function fromHex(hex: string): Uint8Array {
  const out = new Uint8Array(hex.length / 2);
  for (let i = 0; i < out.length; i++) out[i] = parseInt(hex.substr(i * 2, 2), 16);
  return out;
}
export function toB64(buf: ArrayBuffer): string {
  return btoa(String.fromCharCode(...new Uint8Array(buf)));
}

export async function sha256Hex(input: string): Promise<string> {
  return toHex(await crypto.subtle.digest("SHA-256", enc.encode(input)));
}

// hashKey: how raw keys are stored. sha256(key || pepper).
export async function hashKey(rawKey: string, pepper: string): Promise<string> {
  return sha256Hex(rawKey + "|" + pepper);
}

// HMAC-SHA256, hex output. Used to authenticate handshake tokens.
export async function hmacHex(secret: string, msg: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    "raw", enc.encode(secret), { name: "HMAC", hash: "SHA-256" }, false, ["sign"],
  );
  return toHex(await crypto.subtle.sign("HMAC", key, enc.encode(msg)));
}

// Derive the per-request AES key via HKDF.
//   ikm  = serverPepper || loaderPepper   (split-knowledge; neither half alone works)
//   salt = nonce
//   info = hwid || key
// The client re-derives the identical key locally; the key is NEVER transmitted.
export async function deriveSessionKey(
  serverPepper: string, loaderPepper: string, nonce: string, hwid: string, rawKey: string,
): Promise<CryptoKey> {
  const ikm = await crypto.subtle.importKey(
    "raw", enc.encode(serverPepper + loaderPepper), "HKDF", false, ["deriveKey"],
  );
  return crypto.subtle.deriveKey(
    { name: "HKDF", hash: "SHA-256", salt: enc.encode(nonce), info: enc.encode(hwid + "|" + rawKey) },
    ikm,
    { name: "AES-GCM", length: 256 },
    false,
    ["encrypt"],
  );
}

// AES-256-GCM encrypt. Returns {ct, iv} both base64. Tag is appended to ct by WebCrypto.
export async function aesGcmEncrypt(key: CryptoKey, plaintext: string) {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const ct = await crypto.subtle.encrypt({ name: "AES-GCM", iv }, key, enc.encode(plaintext));
  return { ct: toB64(ct), iv: toB64(iv.buffer) };
}

export function randomHex(bytes = 16): string {
  return toHex(crypto.getRandomValues(new Uint8Array(bytes)).buffer);
}
