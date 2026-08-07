# SleepyAuth — Master Plan (Backend • Frontend • Bot • Client • Everything)

This is the complete plan for the whole system. Nothing here is built until you
approve. Code already scaffolded (worker crypto/routes/schema) is Phase 1 and
fits into this plan unchanged.

---

## 0. Ground truth (the non-negotiable reality)
- The loader that runs in the executor is **client-side Lua**; its final
  decrypted form can be dumped from memory by a skilled attacker. No product
  (ours or Luarmor's) prevents that.
- Our job is therefore: **(a)** block trivial extraction (`curl`, browser, bot,
  replay) completely, **(b)** make a dump *identifiable* (watermark) and
  *revocable* (key/HWID burn), **(c)** raise the cost of a real dump as high as
  practical (encryption, one-time tokens, integrity checks, obfuscation).
- We build to that target, honestly. Everything below serves it.

---

## 1. System map

```
                         ┌────────────────────────────┐
   Roblox client         │   Cloudflare (edge)         │
   (executor)            │                             │
  ┌───────────┐  HTTPS   │  ┌──────────────────────┐   │
  │ loader.lua│─────────▶│  │  Auth Worker (API)   │   │
  └───────────┘  handshake │  │  /handshake /script  │   │
        ▲         /script │  │  /admin/* /bot/*     │   │
        │                 │  └───────┬──────────────┘   │
        │ encrypted       │          │                  │
        │ payload         │   ┌──────┴───────┐  ┌──────┐│
        └─────────────────│   │  D1 (SQLite) │  │  KV  ││
                          │   │  durable data│  │ TTL  ││
                          │   └──────────────┘  └──────┘│
                          └───────▲─────────────▲───────┘
                                  │ /admin/*     │ /bot/*
                     ┌────────────┴───┐    ┌─────┴────────┐
                     │ Admin Dashboard│    │ Discord Bot  │
                     │ (static SPA)   │    │ (Node)       │
                     └────────────────┘    └──────────────┘
```

Five deliverables: **Auth Worker**, **D1/KV storage**, **Admin Dashboard**,
**Discord Bot**, **Client loader + build pipeline**.

---

## 2. BACKEND — Auth Worker

### 2.1 Tech
- Cloudflare Worker, **TypeScript**, WebCrypto (no external crypto deps).
- **D1** (SQLite) durable; **KV** ephemeral (nonces/tokens/rate-limit).
- Deploy via `wrangler`. Secrets via `wrangler secret` (never in repo).

### 2.2 Public endpoints (client-facing)
| Method | Path | Purpose | Auth |
|---|---|---|---|
| POST | `/handshake` | validate key+HWID+ban+client-shape → nonce + one-time token | key |
| POST | `/script` | consume token → watermarked, encrypted payload | one-time token |
| POST | `/heartbeat` | integrity ping; server may invalidate session | token/session |
| GET  | `/loader.lua` | serve obfuscated bootstrap | none (public by nature) |

### 2.3 Admin endpoints (`/admin/*`, bearer `ADMIN_SECRET`)
- `POST /admin/keys` create key(s) → returns raw key once.
- `GET  /admin/keys` list/search (paginated, key never returned in raw).
- `PATCH /admin/keys/:id` pause / revoke / set expiry / note / max_hwids.
- `POST /admin/keys/:id/resethwid` clear bindings.
- `POST /admin/bans` ban hwid/ip/key; `DELETE /admin/bans/:id` unban.
- `GET  /admin/executions` recent executions (filter by key/hwid).
- `POST /admin/scripts` upload new script version; `POST /admin/scripts/:v/activate`.
- `POST /admin/leaklookup` paste leaked snippet → returns matching wm_id → key/hwid.
- `GET  /admin/stats` counts: active keys, execs/day, unique HWIDs.

### 2.4 Bot endpoints (`/bot/*`, bearer `BOT_SECRET`)
- `POST /bot/redeem` {discord_id, key} → link.
- `POST /bot/resethwid` {discord_id} → rate-limited reset.
- `GET  /bot/mykey` {discord_id} → status/expiry (never raw key).
- `POST /bot/genkey` (admin-role gated in bot) → create+link.

### 2.5 Security middleware (every request)
- Client-shape gate (reject browser/curl/bot UAs on client routes).
- Per-IP + per-HWID rate limits (KV counters).
- Ban checks (hwid/ip/key).
- Constant-time-ish comparisons for secrets; all admin actions audit-logged.

### 2.6 Crypto (already scaffolded)
- Key storage: `sha256(key || SERVER_PEPPER)`.
- Session key: `HKDF(ikm=SERVER_PEPPER||LOADER_PEPPER, salt=nonce, info=hwid||key)`
  → **AES-256-GCM**. Response carries `{ct, iv}` only; **key never transmitted**.
- Token integrity: HMAC-SHA256 over `token|key_id|hwid|nonce`.
- One-time tokens + nonces, 10s TTL in KV.

---

## 3. STORAGE — D1 schema (built in `worker/schema.sql`)
Tables: `keys`, `hwid_bindings`, `bans`, `scripts` (versioned), `watermarks`,
`executions`, `discord_links`. Keys stored **hashed**. Full DDL already written.

---

## 4. FRONTEND — Admin Dashboard

### 4.1 Tech
- Static SPA, **no framework required** (vanilla + a little Preact optional),
  served from Cloudflare Pages or as Worker static assets. Talks only to `/admin/*`.
- Auth: login form → stores `ADMIN_SECRET` bearer in memory/session (never in code).

### 4.2 Screens
1. **Login** — enter admin secret; validated by a `/admin/stats` probe.
2. **Dashboard** — stat tiles: active keys, executions today, unique HWIDs,
   bans; recent-executions table with live refresh.
3. **Keys** — table (status, expiry, HWIDs used, discord, note); actions:
   create (bulk count + expiry + max_hwids), reveal-once on create, pause,
   revoke, reset HWID, edit note. Search/filter/pagination.
4. **Bans** — list + add (hwid/ip/key + reason) + remove.
5. **Scripts** — upload new version (paste/upload Luau), see versions,
   activate one. Shows which version is live.
6. **Leak Lookup** — paste a leaked snippet → highlights the wm_id → shows the
   exact key/hwid/discord that received it → one-click ban+revoke.
7. **Analytics** — executions over time, top HWIDs, geo (from CF), anomalies
   (same key many HWIDs, rapid resets).

### 4.3 Design
- Dark, minimal, responsive. Theme-aware. Charts via the dataviz approach.
- No secrets in the bundle; all privileged data fetched at runtime with the bearer.

---

## 5. Discord Bot

### 5.1 Tech
- Node.js (discord.js) OR a second Worker using Discord interactions webhook
  (serverless, no host). **Recommendation: interactions Worker** — no VPS,
  same stack, verifies Ed25519 signatures from Discord.
- Talks to `/bot/*` with `BOT_SECRET`.

### 5.2 Commands
- `/redeem <key>` — link key to caller's Discord ID, grant whitelist role.
- `/resethwid` — rate-limited (e.g. 1/day) self-service HWID reset.
- `/mykey` — show status/expiry (ephemeral reply, never the raw key).
- Admin (role-gated): `/genkey <days> [count]`, `/ban <hwid|key>`, `/revoke <key>`.

### 5.3 Whitelist flow
- Redeem success → bot assigns a "Customer" role → your Discord gates a
  channel with the current loader string. Ties access to membership.

---

## 6. CLIENT — Loader + Build Pipeline

### 6.1 Runtime loader (`client/loader.lua`)
Responsibilities, in order:
1. Collect **HWID** (`gethwid()`/executor identity fallback) + **executor
   fingerprint** (`identifyexecutor()`), `place_id`, `job_id`.
2. `POST /handshake` → receive `{nonce, token}`.
3. `POST /script {token, hwid}` → receive `{ct, iv}`.
4. Re-derive session key locally: `HKDF(LOADER_PEPPER||<server half via challenge>,
   salt=nonce, info=hwid||key)` — matching the server. Decrypt AES-GCM.
5. `loadstring(plaintext)()`.
6. Optional `/heartbeat` loop with hook-detection.

### 6.2 Anti-dump hardening (best-effort, layered)
- Decrypt into a **local**, execute immediately, don't keep plaintext in a global.
- Hook detection on `loadstring`, `game.HttpGet`, `crypt.*` (compare via
  `debug.info`/`tostring`); on tamper → abort + report.
- Anti-`hookfunction`/`getgc` scan for our own decrypt fn before use.
- Randomized per-session variable names in the built loader.
- No plaintext string of the API URL — assembled at runtime from parts.

### 6.3 Build pipeline (`client/build.mjs` or `.lua`)
- Bakes the `LOADER_PEPPER` half (split-knowledge) into the loader.
- Runs it through an **obfuscator** (Phase 5 — we can integrate an OSS Luau
  obfuscator or a VM-based one). Output = the distributable string users paste.
- The distributable is a **1-line** `loadstring(game:HttpGet("…/loader.lua"))()`
  where `/loader.lua` returns the obfuscated bootstrap.

### 6.4 What the attacker can/can't get (state plainly to users of the plan)
- `curl -s .../loader.lua` → obfuscated bootstrap **with no source and no keys**;
  it 403s on `/script` without a full valid handshake.
- `curl -s .../script` → **403** (no token).
- Captured `/script` response → **inert ciphertext**, key never present.
- A memory dump of the running, decrypted main script → **possible**; mitigated
  by watermark → identify → ban. (The honest limit.)

---

## 7. Secrets & config
| Secret | Where | Purpose |
|---|---|---|
| `SERVER_PEPPER` | wrangler secret | key hashing + KDF half + HMAC |
| `LOADER_PEPPER` | wrangler secret + baked (obfuscated) in loader | KDF split-knowledge half |
| `ADMIN_SECRET` | wrangler secret | `/admin/*` bearer |
| `BOT_SECRET` | wrangler secret | `/bot/*` bearer |
| `DISCORD_PUBLIC_KEY` | bot env | verify Discord interaction signatures |

---

## 8. Build phases & milestones
| Phase | Deliverable | Done-when |
|---|---|---|
| **1** | Auth Worker core: `/handshake`, `/script`, D1 schema, crypto, HWID lock, minimal loader | end-to-end encrypted delivery works; curl gets 403 |
| **2** | Watermarking + executions logging + `/admin/leaklookup` | a leaked snippet resolves to a key |
| **3** | Admin API (`/admin/*`) + Dashboard SPA | keys/bans/scripts/analytics manageable in UI |
| **4** | Discord bot (interactions Worker) + `/bot/*` | redeem/reset/whitelist works from Discord |
| **5** | Hardening: executor challenge, heartbeat, rate limits, obfuscation build pipeline | distributable is obfuscated; replay/hook attempts blocked |

Each phase is independently testable and shippable.

---

## 9. Testing plan
- Worker unit tests (crypto round-trip: server encrypt ↔ client-equivalent decrypt in a Lua test harness).
- `curl` matrix: every client route must 403 without proper handshake/token.
- Replay test: reused token/nonce → rejected.
- HWID: second HWID on a `max_hwids=1` key → rejected; reset → allowed.
- Watermark: two deliveries → distinct wm_ids → leaklookup resolves each.
- Load test on KV rate limits.

---

## 10. Open decisions for you
1. **Dashboard host**: Cloudflare Pages vs Worker static assets. (Rec: Pages.)
2. **Bot host**: interactions Worker (serverless, rec) vs Node discord.js (VPS).
3. **Obfuscator** (Phase 5): OSS Luau obfuscator integration vs the existing
   wearedevs output vs a custom minifier. (Rec: integrate a real VM obfuscator.)
4. **HWID source**: `gethwid()` where available, fallback strategy for executors
   without it — confirm your target executors (Synapse/Script-Ware/Wave/etc.).
5. **Reset policy**: default resets/day for self-service via bot. (Rec: 1/day.)
