# SleepyAuth — Architecture & Build Plan

A self-owned Lua script authentication + protection system on Cloudflare Workers.
Goal: harder to crack than Luarmor for *your* threat model, and a bare
`curl -s https://api/script` returns nothing usable.

---

## 0. Threat model — read this first

**What we CAN guarantee**
- A bare `curl`, browser, or bot with no valid key + signed nonce gets `403`. ✅
- A dumped/leaked HTTP response body is **inert ciphertext** — the decryption
  key is never in the response; it's derived per-request from `HWID + key + nonce`. ✅
- Every delivered script is **uniquely watermarked**, so a leak maps back to one key. ✅
- A stolen key is **HWID-locked** and rate-limited, so it can't be shared widely. ✅
- Loader tokens are **one-time, ~10s TTL** — a copied loader URL is dead on arrival. ✅

**What NOBODY can guarantee (including Luarmor)**
- Your script runs inside an executor the attacker fully controls. They can hook
  `loadstring`, `game:HttpGet`, `debug.*`, and metatables, and dump the decrypted
  chunk from live memory. This is unpreventable in principle.
- Therefore our target is **not** "impossible to extract" — it's:
  1. Make extraction expensive and skill-gated.
  2. Make a leaked dump **worthless to the leaker** (watermark → ban → burn key).
  3. **Detect and revoke** fast.

"Impossible to get the source" is marketing, never engineering. We build the
achievable version, which is genuinely strong.

---

## 1. High-level flow

```
Roblox client (loader)                 Cloudflare Worker + D1/KV
──────────────────────                 ─────────────────────────
1. loadstring(HttpGet(loader.lua))
2. POST /handshake  {key, hwid,   ──▶  validate key, HWID lock, bans,
   executor_fp, place, job}            executor fingerprint, rate limit
                                  ◀──  {nonce, token}  (token: one-time, 10s TTL, KV)
3. POST /script  {token, hwid,    ──▶  verify token+nonce+HMAC, consume token,
   hmac}                               pick script version, inject watermark,
                                       AES-GCM encrypt with key = KDF(hwid,key,nonce)
                                  ◀──  {ciphertext, iv, tag}  (NO decryption key)
4. derive same key locally, decrypt,
   loadstring(plaintext)()             log execution (hwid, key, ip, ts, wm_id)
```

Key property: step 3's response is useless without the secret the client
re-derives locally and the server never transmits.

---

## 2. Components

### 2.1 Auth Worker (`worker/`)
Cloudflare Worker, TypeScript. Routes:
- `POST /handshake` — key/HWID/ban/fingerprint checks → issue nonce + one-time token.
- `POST /script` — consume token, deliver watermarked encrypted payload.
- `POST /admin/*` — key CRUD, bans, analytics (behind admin auth, separate secret).
- `GET  /loader.lua` — serves the *minimal* bootstrap (itself lightly obfuscated).

### 2.2 Storage
- **D1 (SQLite)** — durable: `keys`, `hwid_bindings`, `bans`, `executions`,
  `scripts` (versioned ciphertext blobs), `watermarks`, `discord_links`.
- **KV** — ephemeral: `nonce:<id>` and `token:<id>` with native TTL (10s),
  plus `ratelimit:<ip|hwid>` counters.

### 2.3 Admin dashboard (`dashboard/`)
Static SPA (served as a Worker asset or Pages). Talks only to `/admin/*`.
Features: create/revoke/expire keys, HWID reset, ban HWID/IP, live executions
table, per-watermark leak lookup, upload new script version.

### 2.4 Discord bot (`bot/`)
Ties keys to Discord user IDs. Slash commands: `/redeem`, `/resethwid`
(rate-limited), `/mykey`, admin `/genkey`, `/ban`. Whitelist gated by server role.
Talks to the same `/admin/*` API with a bot secret.

### 2.5 Client loader (`client/loader.lua`)
Tiny bootstrap: collects HWID + executor fingerprint, does handshake, derives
key, decrypts, executes. Kept small so the obfuscated surface is minimal.

---

## 3. Security mechanisms (detail)

### 3.1 Blocking `curl` / browsers / bots
- Require `key` + valid `hwid` + `executor_fp` on `/handshake`; missing → 403.
- Verify a **Roblox executor fingerprint**: `identifyexecutor()` value, presence
  of executor-only globals challenge (server sends a challenge, client must
  answer using an executor API), and Roblox HTTP client heuristics.
- Require real `place_id` + `job_id`; optionally verify shape/format.
- `/script` requires a one-time token that only `/handshake` mints. curl can't
  get one without passing all above.

### 3.2 Per-request encryption (dumped body is inert)
- `session_key = HKDF(secret = server_pepper, salt = nonce, info = hwid||key)`.
- Payload encrypted **AES-256-GCM**; response carries `ciphertext, iv, tag` only.
- Client re-derives `session_key` from values it already holds (hwid, key) + the
  nonce it received in handshake. The server pepper is baked (obfuscated) into
  the loader AND mixed server-side — split-knowledge so neither half alone leaks it.
- Nonce is single-use, 10s TTL. Replaying a captured `/script` request fails.

### 3.3 One-time loader tokens
- `token` stored in KV, deleted on first `/script` use, expires in 10s.
- A copied loader URL / captured request is dead almost immediately.

### 3.4 HWID lock + key system
- On first use a key binds to one HWID. Mismatch → reject + log.
- Resets are rate-limited (e.g. 1/day) and logged; abuse auto-flags the key.
- Keys have: `expires_at`, `max_hwids` (usually 1), `status` (active/paused/revoked),
  optional `note`, `discord_id`.

### 3.5 Per-user watermarking (the real anti-leak)
- At delivery, inject a unique marker into the payload before encryption:
  - a `--[[<base64 wm_id>]]` style comment, AND
  - a semantic marker (e.g. a dead-code constant / reordered table) so trivial
    comment-stripping doesn't remove it.
- Store `wm_id → key_id, hwid, ts` in D1. A leaked copy → paste into dashboard
  "leak lookup" → identifies the exact key → auto-ban + burn.

### 3.6 Runtime integrity (best-effort)
- Loader periodically re-checks: `identifyexecutor`, hook detection on
  `game.HttpGet`/`loadstring` (compare `tostring`/`debug.info`), heartbeat ping.
- On tamper signal → server can revoke the session and future tokens.
- Explicitly "best-effort": raises cost, not a guarantee.

### 3.7 Server hygiene
- Cloudflare gives DDoS + bot mgmt for free at the edge.
- Per-IP and per-HWID rate limits in KV.
- Admin + bot endpoints behind separate long secrets; all admin actions logged.
- Secrets in Worker env vars / `wrangler secret`, never in the repo.

---

## 4. Data model (D1)

```sql
keys(id, key_hash, status, expires_at, max_hwids, discord_id, note, created_at)
hwid_bindings(key_id, hwid, first_seen, last_seen, reset_count, last_reset_at)
bans(id, kind /*hwid|ip|key*/, value, reason, created_at)
scripts(id, version, ciphertext, meta, active, created_at)
watermarks(wm_id, key_id, hwid, script_version, issued_at)
executions(id, key_id, hwid, ip, executor, place_id, wm_id, ts)
discord_links(discord_id, key_id, linked_at)
```
Keys are stored **hashed** (argon2/scrypt/sha256+pepper); raw key shown once at creation.

---

## 5. Build phases

- **Phase 1 — Core Worker + D1 schema.** `/handshake`, `/script`, KDF + AES-GCM,
  nonce/token lifecycle, HWID lock. Minimal loader. *End-to-end encrypted delivery works.*
- **Phase 2 — Watermarking + executions logging + leak lookup.**
- **Phase 3 — Admin API + dashboard** (key CRUD, bans, analytics).
- **Phase 4 — Discord bot** (redeem/reset/whitelist).
- **Phase 5 — Hardening**: executor fingerprint challenge, integrity heartbeat,
  rate limits, loader obfuscation pipeline.

Each phase is independently testable and shippable.

---

## 6. Repo layout (proposed)

```
/worker         Cloudflare Worker (TS), routes + crypto + D1/KV bindings
  /src
  wrangler.toml
  schema.sql
/dashboard      static admin SPA
/bot            Discord bot (Node)
/client         loader.lua + build/obfuscation script
/docs           this file + API spec
```

---

## 7. Honest limitations (say these out loud)
- Memory dumping of the decrypted chunk by a skilled attacker with a good
  executor remains possible. Watermark + fast revocation is the answer, not prevention.
- Obfuscation of the loader deters, doesn't stop, reverse engineering.
- Anything baked into the client (peppers, keys) can eventually be extracted;
  that's why the design uses split-knowledge and per-request derivation so a
  single extracted value doesn't unlock past/future payloads for other users.

This is a realistic, strong, ownable system. It will not make extraction
"impossible" — nothing does — but it makes a leak *identifiable, revocable, and
low-value*, which is what actually protects a paid script.
```
