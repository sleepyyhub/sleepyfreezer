-- SleepyAuth D1 schema
CREATE TABLE IF NOT EXISTS keys (
  id          TEXT PRIMARY KEY,
  key_hash    TEXT NOT NULL UNIQUE,      -- sha256(key || pepper); raw key shown once
  status      TEXT NOT NULL DEFAULT 'active', -- active | paused | revoked
  expires_at  INTEGER,                   -- unix seconds, NULL = never
  max_hwids   INTEGER NOT NULL DEFAULT 1,
  discord_id  TEXT,
  note        TEXT,
  created_at  INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS hwid_bindings (
  key_id        TEXT NOT NULL,
  hwid          TEXT NOT NULL,
  first_seen    INTEGER NOT NULL,
  last_seen     INTEGER NOT NULL,
  reset_count   INTEGER NOT NULL DEFAULT 0,
  last_reset_at INTEGER,
  PRIMARY KEY (key_id, hwid)
);

CREATE TABLE IF NOT EXISTS bans (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  kind       TEXT NOT NULL,              -- hwid | ip | key
  value      TEXT NOT NULL,
  reason     TEXT,
  created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_bans_value ON bans(kind, value);

CREATE TABLE IF NOT EXISTS scripts (
  id         INTEGER PRIMARY KEY AUTOINCREMENT,
  version    INTEGER NOT NULL,
  source     TEXT NOT NULL,              -- the Luau source (pre-watermark, pre-encrypt)
  active     INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS watermarks (
  wm_id          TEXT PRIMARY KEY,
  key_id         TEXT NOT NULL,
  hwid           TEXT NOT NULL,
  script_version INTEGER NOT NULL,
  issued_at      INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS executions (
  id       INTEGER PRIMARY KEY AUTOINCREMENT,
  key_id   TEXT,
  hwid     TEXT,
  ip       TEXT,
  executor TEXT,
  place_id TEXT,
  wm_id    TEXT,
  ts       INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_exec_key ON executions(key_id);

CREATE TABLE IF NOT EXISTS discord_links (
  discord_id TEXT PRIMARY KEY,
  key_id     TEXT NOT NULL,
  linked_at  INTEGER NOT NULL
);
