// D1-shaped wrapper over Node's built-in SQLite (no Cloudflare, no extra native module).
import { DatabaseSync } from "node:sqlite"

const OPS_DDL = `
CREATE TABLE IF NOT EXISTS staff (
    steamid     TEXT PRIMARY KEY,
    name        TEXT NOT NULL DEFAULT '',
    pin_hash    TEXT NOT NULL DEFAULT '',
    role        TEXT NOT NULL DEFAULT 'admin',
    enabled     INTEGER NOT NULL DEFAULT 1,
    created_at  INTEGER NOT NULL DEFAULT 0,
    last_login  INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_staff_steamid ON staff (steamid);

CREATE TABLE IF NOT EXISTS admin_sessions (
    token       TEXT PRIMARY KEY,
    steamid     TEXT NOT NULL,
    created_at  INTEGER NOT NULL DEFAULT 0,
    expires_at  INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS admin_audit (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    steamid     TEXT NOT NULL DEFAULT '',
    action      TEXT NOT NULL DEFAULT '',
    detail      TEXT NOT NULL DEFAULT '',
    created_at  INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_admin_audit_created ON admin_audit (created_at DESC);

CREATE TABLE IF NOT EXISTS events (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    title           TEXT NOT NULL DEFAULT '',
    type            TEXT NOT NULL DEFAULT 'event',
    status          TEXT NOT NULL DEFAULT 'scheduled',
    start_at        INTEGER NOT NULL DEFAULT 0,
    end_at          INTEGER NOT NULL DEFAULT 0,
    xp_mult         REAL NOT NULL DEFAULT 1,
    coins_mult      REAL NOT NULL DEFAULT 1,
    conflict_group  TEXT NOT NULL DEFAULT '',
    error_msg       TEXT NOT NULL DEFAULT '',
    created_by      TEXT NOT NULL DEFAULT '',
    created_at      INTEGER NOT NULL DEFAULT 0,
    metric          TEXT DEFAULT 'none',
    target          INTEGER DEFAULT 0,
    scope           TEXT DEFAULT 'global',
    reward          TEXT DEFAULT '',
    reward_coins    INTEGER DEFAULT 0,
    reward_viptier  INTEGER DEFAULT 0,
    reward_vipdays  INTEGER DEFAULT 0,
    min_score       INTEGER DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_events_status_start ON events (status, start_at);

CREATE TABLE IF NOT EXISTS event_history (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    event_id        INTEGER NOT NULL UNIQUE,
    title           TEXT NOT NULL DEFAULT '',
    type            TEXT NOT NULL DEFAULT '',
    xp_mult         REAL NOT NULL DEFAULT 1,
    coins_mult      REAL NOT NULL DEFAULT 1,
    start_at        INTEGER NOT NULL DEFAULT 0,
    end_at          INTEGER NOT NULL DEFAULT 0,
    completed_at    INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS event_baselines (
    event_id        INTEGER NOT NULL,
    steamid         TEXT NOT NULL,
    metric          TEXT NOT NULL,
    baseline        INTEGER NOT NULL DEFAULT 0,
    taken_at        INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (event_id, steamid, metric)
);
CREATE TABLE IF NOT EXISTS event_winners (
    event_id        INTEGER NOT NULL,
    placement       INTEGER NOT NULL,
    steamid         TEXT NOT NULL,
    score           INTEGER NOT NULL DEFAULT 0,
    reward_coins    INTEGER NOT NULL DEFAULT 0,
    reward_viptier  INTEGER NOT NULL DEFAULT 0,
    reward_vipdays  INTEGER NOT NULL DEFAULT 0,
    issued_at       INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (event_id, placement)
);
CREATE INDEX IF NOT EXISTS idx_winners_event ON event_winners (event_id);
CREATE TABLE IF NOT EXISTS event_audit (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    ts              INTEGER NOT NULL DEFAULT 0,
    actor           TEXT NOT NULL DEFAULT '',
    action          TEXT NOT NULL DEFAULT '',
    entity          TEXT NOT NULL DEFAULT '',
    meta            TEXT NOT NULL DEFAULT ''
);
`

export function migratePlayers(raw) {
  const have = new Set((raw.prepare("PRAGMA table_info(players)").all() || []).map(r => r.name))
  const add = [
    ["bp_hp", "INTEGER NOT NULL DEFAULT 0"],
    ["bp_armor", "INTEGER NOT NULL DEFAULT 0"],
    ["bp_jumps", "INTEGER NOT NULL DEFAULT 0"],
    ["bp_sniper", "INTEGER NOT NULL DEFAULT 0"],
    ["bp_laststand", "INTEGER NOT NULL DEFAULT 0"],
    ["bp_chute", "INTEGER NOT NULL DEFAULT 0"],
    ["bp_premium", "INTEGER NOT NULL DEFAULT 0"],
    ["bp_milestone", "INTEGER NOT NULL DEFAULT 0"],
    ["bp_xp", "INTEGER NOT NULL DEFAULT 0"],
    ["bp_tier", "INTEGER NOT NULL DEFAULT 0"],
    ["bp_season", "TEXT NOT NULL DEFAULT '1'"],
    ["bp_premium_season", "TEXT NOT NULL DEFAULT ''"],
    ["bp_ent_lane", "INTEGER NOT NULL DEFAULT 0"],
    ["bp_ent_order", "TEXT NOT NULL DEFAULT ''"],
    ["bp_ent_at", "INTEGER NOT NULL DEFAULT 0"],
    ["ach_unlocked", "INTEGER"],
    ["ach_kills", "INTEGER"],
    ["ach_hs", "INTEGER"],
    ["ach_plants", "INTEGER"],
    ["ach_defuses", "INTEGER"],
    ["ach_wins", "INTEGER"],
    ["ach_revives", "INTEGER"],
    ["ach_streak", "INTEGER"],
    ["rerolls_left", "INTEGER"],
    ["msn_st_d", "INTEGER"],
    ["msn_st_b", "INTEGER"],
    ["msn_st_w", "INTEGER"],
    ["msn_st_v", "INTEGER"],
    ["msn_vip_p", "INTEGER"],
    ["msn_tg", "TEXT"],
    ["cc", "TEXT NOT NULL DEFAULT ''"],
    ["vip_remaining", "INTEGER NOT NULL DEFAULT 0"]
  ]
  for (const [name, ddl] of add) {
    if (have.has(name)) continue
    try { raw.exec(`ALTER TABLE players ADD COLUMN ${name} ${ddl}`) }
    catch (e) { /* already present or locked */ }
  }
  try { raw.exec(OPS_DDL) }
  catch (e) { /* already present or locked */ }
}

export function openLocalD1(file) {
  const raw = new DatabaseSync(file)
  raw.exec("PRAGMA journal_mode = WAL")
  raw.exec("PRAGMA foreign_keys = ON")
  try { migratePlayers(raw) } catch {}
  return {
    raw,
    prepare(sql) {
      return new D1Statement(raw, sql)
    },
    async batch(stmts) {
      // D1's batch is all-or-nothing and sync.js relies on it: a per-player
      // skins update deletes every row and then re-inserts the truth, so a
      // failure between the two used to leave a player with no inventory.
      // DatabaseSync is synchronous, so a plain transaction is exact here.
      if (!Array.isArray(stmts) || stmts.length === 0) return []
      const out = []
      raw.exec("BEGIN IMMEDIATE")
      try {
        for (const s of stmts) {
          if (s && typeof s.run === "function") out.push(await s.run())
        }
        raw.exec("COMMIT")
      } catch (e) {
        try { raw.exec("ROLLBACK") } catch {}
        throw e
      }
      return out
    }
  }
}

function toNamed(sql, params) {
  const named = {}
  const out = sql.replace(/\?(\d+)/g, (_, n) => {
    const i = Number(n) - 1
    named["p" + n] = params[i]
    return ":p" + n
  })
  return { sql: out, named, plain: params }
}

class D1Statement {
  constructor(raw, sql) {
    this.raw = raw
    this.sql = sql
    this.params = []
  }
  bind(...args) {
    this.params = args
    return this
  }
  _runKind(kind) {
    const { sql, named, plain } = toNamed(this.sql, this.params)
    const stmt = this.raw.prepare(sql)
    if (sql.includes(":p")) return stmt[kind](named)
    return plain.length ? stmt[kind](...plain) : stmt[kind]()
  }
  async first() {
    const row = this._runKind("get")
    return row == null ? null : row
  }
  async all() {
    const rows = this._runKind("all")
    return { results: Array.isArray(rows) ? rows : [] }
  }
  async run() {
    const info = this._runKind("run")
    return {
      meta: {
        last_row_id: Number(info.lastInsertRowid || 0),
        changes: Number(info.changes || 0)
      }
    }
  }
}
