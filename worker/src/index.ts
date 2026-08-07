// SleepyAuth Worker — Phase 1
// Routes: /handshake, /script, /loader.lua  (+ /admin stubs land in Phase 3)
import {
  hashKey, hmacHex, deriveSessionKey, aesGcmEncrypt, randomHex, sha256Hex,
} from "./crypto";

export interface Env {
  DB: D1Database;
  EPHEMERAL: KVNamespace;
  SERVER_PEPPER: string;
  LOADER_PEPPER: string;
  ADMIN_SECRET: string;
  BOT_SECRET: string;
}

const now = () => Math.floor(Date.now() / 1000);
const json = (data: unknown, status = 200) =>
  new Response(JSON.stringify(data), { status, headers: { "content-type": "application/json" } });
const deny = (msg = "forbidden") => json({ error: msg }, 403);

// ---- request-shape gate: bounces bare curl / browsers / bots -----------------
// A legitimate executor sets these; a plain `curl -s URL` does not.
function looksLikeExecutor(req: Request): boolean {
  const ua = req.headers.get("user-agent") || "";
  // Roblox executors identify with a Roblox/HttpGet-style client, never a browser UA.
  if (/mozilla|chrome|safari|curl|wget|python|postman|insomnia/i.test(ua)) return false;
  return true;
}

async function isBanned(env: Env, kind: string, value: string): Promise<boolean> {
  const r = await env.DB.prepare("SELECT 1 FROM bans WHERE kind=? AND value=? LIMIT 1")
    .bind(kind, value).first();
  return !!r;
}

async function rateLimit(env: Env, id: string, max = 20, windowSec = 60): Promise<boolean> {
  const k = `rl:${id}`;
  const cur = parseInt((await env.EPHEMERAL.get(k)) || "0", 10);
  if (cur >= max) return false;
  await env.EPHEMERAL.put(k, String(cur + 1), { expirationTtl: windowSec });
  return true;
}

// ---- /handshake --------------------------------------------------------------
// in:  { key, hwid, executor, place_id, job_id }
// out: { nonce, token }   token: one-time, 10s TTL, stored in KV
async function handshake(req: Request, env: Env, ip: string): Promise<Response> {
  if (!looksLikeExecutor(req)) return deny("bad client");
  let body: any;
  try { body = await req.json(); } catch { return deny("bad body"); }
  const { key, hwid, executor, place_id } = body || {};
  if (!key || !hwid || !executor) return deny("missing fields");

  if (!(await rateLimit(env, ip))) return json({ error: "rate limited" }, 429);
  if (await isBanned(env, "ip", ip)) return deny("banned");
  if (await isBanned(env, "hwid", hwid)) return deny("banned");

  const kh = await hashKey(key, env.SERVER_PEPPER);
  const row: any = await env.DB.prepare(
    "SELECT id, status, expires_at, max_hwids FROM keys WHERE key_hash=? LIMIT 1",
  ).bind(kh).first();
  if (!row) return deny("invalid key");
  if (row.status !== "active") return deny("key " + row.status);
  if (row.expires_at && row.expires_at < now()) return deny("key expired");
  if (await isBanned(env, "key", row.id)) return deny("banned");

  // HWID lock
  const binding: any = await env.DB.prepare(
    "SELECT hwid FROM hwid_bindings WHERE key_id=? AND hwid=? LIMIT 1",
  ).bind(row.id, hwid).first();
  if (!binding) {
    const count: any = await env.DB.prepare(
      "SELECT COUNT(*) AS n FROM hwid_bindings WHERE key_id=?",
    ).bind(row.id).first();
    if ((count?.n ?? 0) >= row.max_hwids) return deny("hwid limit reached");
    await env.DB.prepare(
      "INSERT INTO hwid_bindings (key_id, hwid, first_seen, last_seen) VALUES (?,?,?,?)",
    ).bind(row.id, hwid, now(), now()).run();
  } else {
    await env.DB.prepare("UPDATE hwid_bindings SET last_seen=? WHERE key_id=? AND hwid=?")
      .bind(now(), row.id, hwid).run();
  }

  // mint nonce + one-time token
  const nonce = randomHex(16);
  const token = randomHex(24);
  const tokenSig = await hmacHex(env.SERVER_PEPPER, `${token}|${row.id}|${hwid}|${nonce}`);
  await env.EPHEMERAL.put(
    `tok:${token}`,
    JSON.stringify({ key_id: row.id, hwid, nonce, sig: tokenSig, key, place_id, executor, ip }),
    { expirationTtl: 10 },
  );
  return json({ nonce, token });
}

// ---- /script -----------------------------------------------------------------
// in:  { token, hwid }
// out: { ct, iv }  — AES-GCM ciphertext only; decryption key never sent.
async function script(req: Request, env: Env, ip: string): Promise<Response> {
  if (!looksLikeExecutor(req)) return deny("bad client");
  let body: any;
  try { body = await req.json(); } catch { return deny("bad body"); }
  const { token, hwid } = body || {};
  if (!token || !hwid) return deny("missing fields");

  const raw = await env.EPHEMERAL.get(`tok:${token}`);
  if (!raw) return deny("expired token");
  await env.EPHEMERAL.delete(`tok:${token}`); // one-time use
  const t = JSON.parse(raw);
  if (t.hwid !== hwid) return deny("hwid mismatch");

  // fetch active script
  const s: any = await env.DB.prepare(
    "SELECT version, source FROM scripts WHERE active=1 ORDER BY version DESC LIMIT 1",
  ).first();
  if (!s) return json({ error: "no active script" }, 503);

  // per-user watermark (comment + semantic marker)
  const wmId = randomHex(8);
  await env.DB.prepare(
    "INSERT INTO watermarks (wm_id, key_id, hwid, script_version, issued_at) VALUES (?,?,?,?,?)",
  ).bind(wmId, t.key_id, hwid, s.version, now()).run();
  const marked =
    `--[[wm:${wmId}]]\nlocal _wm=("${wmId}"):rep(1)\n` + s.source + `\n--[[/wm:${wmId}]]`;

  // encrypt with per-request derived key (client re-derives the same key)
  const sk = await deriveSessionKey(env.SERVER_PEPPER, env.LOADER_PEPPER, t.nonce, hwid, t.key);
  const { ct, iv } = await aesGcmEncrypt(sk, marked);

  await env.DB.prepare(
    "INSERT INTO executions (key_id, hwid, ip, executor, place_id, wm_id, ts) VALUES (?,?,?,?,?,?,?)",
  ).bind(t.key_id, hwid, ip, t.executor || null, t.place_id || null, wmId, now()).run();

  return json({ ct, iv });
}

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    const url = new URL(req.url);
    const ip = req.headers.get("cf-connecting-ip") || "0.0.0.0";
    try {
      if (req.method === "POST" && url.pathname === "/handshake") return await handshake(req, env, ip);
      if (req.method === "POST" && url.pathname === "/script") return await script(req, env, ip);
      if (req.method === "GET" && url.pathname === "/loader.lua") {
        // Loader is public by necessity, but contains no secrets beyond the
        // obfuscated LOADER_PEPPER half and no source. Served as text/plain.
        return new Response(LOADER_TEMPLATE(url.origin), { headers: { "content-type": "text/plain" } });
      }
      return new Response("Not found", { status: 404 });
    } catch (e: any) {
      return json({ error: "server error" }, 500);
    }
  },
};

// Minimal bootstrap. The real distributable is produced by client/build.lua which
// bakes LOADER_PEPPER + obfuscates. This inline copy is the source of truth.
function LOADER_TEMPLATE(origin: string): string {
  return `-- SleepyAuth loader (bootstrap). Obfuscate before distribution.\nprint("Use client/loader.lua as the source of truth.")\n`;
}
