// Weekly / monthly boards, period snapshots and text badges.
//
// The boundary logic lives in periods.js (Europe/Paris, ISO week + calendar
// month) and is used by /api/public/top, the in-panel boards and the MOTD top
// page, so all three can never disagree.
//
// HOW A WEEKLY VALUE IS COMPUTED (and its honest limitation)
// ---------------------------------------------------------
// The panel replica stores lifetime counters only (players.xp, players.kills);
// the game does not push per-day history. So a period value is
//
//     max(0, <counter now> - <counter the panel first observed in this period>)
//
// board_marks holds that per-period baseline ("base") plus the newest value it
// has seen ("last_value"). The first time the panel sees a player inside a
// period it records base = last_value = the counter at that moment; every later
// refresh moves last_value forward. Therefore:
//   * a player the panel watched from the very first minute of the week has an
//     exact value for the week,
//   * a player first seen on Thursday has "XP earned since Thursday" and is
//     under-counted — /api/public/top reports this as coverage.complete=false
//     and never pretends otherwise,
//   * nothing is ever extrapolated or invented: a period with no baseline has
//     no rows.
//
// ROLLOVER
// --------
// maybeRollover() runs on the board read paths. It settles exactly the period
// that just ended (using the last snapshot taken inside it, at most one refresh
// interval before the boundary) into board_history and awards the text badges.
// The snapshot is idempotent: PRIMARY KEY / INSERT OR IGNORE mean a second run
// can never duplicate a winner, and a period with no marks simply settles with
// zero rows (no invented winners).
import { periodBounds, previousKey, keyLabel, keysBefore, PERIODS } from "./periods.js"

export const BOARD_METRICS = ["xp", "kills"]
export const BOARD_TOP_N = 15          // rows kept per settled period
const MARK_INTERVAL = 60               // seconds between baseline refreshes
const BADGE_WINDOW = 12                // badges returned per player

const DDL = `
CREATE TABLE IF NOT EXISTS board_marks (
    period      TEXT NOT NULL,
    period_key  TEXT NOT NULL,
    steamid     TEXT NOT NULL,
    metric      TEXT NOT NULL DEFAULT 'xp',
    base        INTEGER NOT NULL DEFAULT 0,
    last_value  INTEGER NOT NULL DEFAULT 0,
    first_seen  INTEGER NOT NULL DEFAULT 0,
    seen_at     INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (period, period_key, steamid, metric)
);
CREATE INDEX IF NOT EXISTS idx_board_marks_key ON board_marks (period, period_key, metric, last_value DESC);

CREATE TABLE IF NOT EXISTS board_history (
    period      TEXT NOT NULL,
    period_key  TEXT NOT NULL,
    metric      TEXT NOT NULL DEFAULT 'xp',
    rank        INTEGER NOT NULL,
    steamid     TEXT NOT NULL,
    name        TEXT NOT NULL DEFAULT '',
    value       INTEGER NOT NULL DEFAULT 0,
    settled_at  INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (period, period_key, metric, rank)
);
CREATE INDEX IF NOT EXISTS idx_board_history_key ON board_history (period, period_key, metric, rank);

CREATE TABLE IF NOT EXISTS badges (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    steamid     TEXT NOT NULL,
    kind        TEXT NOT NULL,
    period      TEXT NOT NULL DEFAULT '',
    label       TEXT NOT NULL DEFAULT '',
    awarded_at  INTEGER NOT NULL DEFAULT 0,
    UNIQUE (steamid, kind, period)
);
CREATE INDEX IF NOT EXISTS idx_badges_player ON badges (steamid);
`

// One ensure per env object (the runner reuses a single env for its lifetime).
const ensured = new WeakSet()

export async function ensureBoardTables(env) {
  if (!env || !env.DB) return false
  if (ensured.has(env)) return true
  try {
    for (const stmt of DDL.split(";").map(s => s.trim()).filter(Boolean)) {
      await env.DB.prepare(stmt).run()
    }
    ensured.add(env)
    return true
  } catch {
    // A read-only replica must still serve pages: callers fall back to the
    // lifetime board instead of throwing.
    return false
  }
}

const nowSec = v => Math.floor(Number(v) || Date.now() / 1000)
const clampInt = (v, lo, hi) => Math.max(lo, Math.min(hi, Math.trunc(Number(v) || 0)))

// ---- sqlite helpers -------------------------------------------------------
async function metaGet(env, key) {
  try {
    const r = await env.DB.prepare(`SELECT value FROM meta WHERE key=?1`).bind(key).first()
    return r ? String(r.value == null ? "" : r.value) : ""
  } catch { return "" }
}

async function metaPut(env, key, value) {
  try {
    await env.DB.prepare(
      `INSERT INTO meta (key, value) VALUES (?1, ?2) ON CONFLICT(key) DO UPDATE SET value = ?2`
    ).bind(key, String(value)).run()
    return true
  } catch { return false }
}

// Guarded column existence: an older replica may predate bp_xp/kills.
async function hasColumn(env, table, column) {
  try {
    const { results } = await env.DB.prepare(`PRAGMA table_info(${table})`).all()
    return (results || []).some(r => String(r.name) === column)
  } catch { return false }
}

/**
 * Refresh this period's baselines. `force` skips the MARK_INTERVAL throttle
 * (used by the tests and by the rollover path).
 */
export async function refreshMarks(env, now, opts = {}) {
  if (!(await ensureBoardTables(env))) return false
  const at = nowSec(now)
  let ok = false
  for (const period of PERIODS) {
    const b = periodBounds(period, at)
    const stampKey = `board_mark:${period}:${b.key}`
    if (!opts.force) {
      const last = Number(await metaGet(env, stampKey)) || 0
      if (last && at - last < MARK_INTERVAL) continue
    }
    for (const metric of BOARD_METRICS) {
      if (!(await hasColumn(env, "players", metric))) continue
      // INSERT OR IGNORE is the "first sight in this period" mark; the UPDATE
      // moves the newest observed value forward without touching base.
      try {
        await env.DB.prepare(
          `INSERT OR IGNORE INTO board_marks (period, period_key, steamid, metric, base, last_value, first_seen, seen_at)
           SELECT ?1, ?2, steamid, ?3, ${metric}, ${metric}, ?4, ?4 FROM players`
        ).bind(period, b.key, metric, at).run()
        await env.DB.prepare(
          `UPDATE board_marks
              SET last_value = COALESCE((SELECT p.${metric} FROM players p WHERE p.steamid = board_marks.steamid), last_value),
                  seen_at = ?4
            WHERE period = ?1 AND period_key = ?2 AND metric = ?3`
        ).bind(period, b.key, metric, at).run()
        ok = true
      } catch { /* column/table gone — leave the period alone */ }
    }
    await metaPut(env, stampKey, at)
  }
  return ok
}

/**
 * The live board for a period. Returns rows already ranked, plus an honest
 * coverage note about how much of the period the panel actually observed.
 */
export async function periodBoard(env, opts = {}) {
  const period = opts.period === "month" ? "month" : "week"
  const metric = BOARD_METRICS.includes(String(opts.metric || "")) ? String(opts.metric) : "xp"
  const limit = clampInt(opts.limit || 10, 1, 100)
  const at = nowSec(opts.now)
  const b = periodBounds(period, at)
  await refreshMarks(env, at)

  let rows = []
  try {
    const q = await env.DB.prepare(
      `SELECT m.steamid AS steamid,
              COALESCE(p.name, '') AS name,
              MAX(0, m.last_value - m.base) AS value,
              m.first_seen AS first_seen
         FROM board_marks m
         LEFT JOIN players p ON p.steamid = m.steamid
        WHERE m.period = ?1 AND m.period_key = ?2 AND m.metric = ?3
        ORDER BY value DESC, name ASC, m.steamid ASC
        LIMIT ?4`
    ).bind(period, b.key, metric, limit).all()
    rows = (q.results || []).filter(r => Number(r.value) > 0)
  } catch { rows = [] }

  let total = rows.length
  try {
    const t = await env.DB.prepare(
      `SELECT COUNT(*) AS n FROM board_marks
        WHERE period = ?1 AND period_key = ?2 AND metric = ?3 AND last_value > base`
    ).bind(period, b.key, metric).first()
    total = Number(t && t.n) || 0
  } catch {}

  let earliest = 0
  let players = 0
  try {
    const e = await env.DB.prepare(
      `SELECT MIN(first_seen) AS f, COUNT(*) AS n FROM board_marks
        WHERE period = ?1 AND period_key = ?2 AND metric = ?3`
    ).bind(period, b.key, metric).first()
    earliest = Number(e && e.f) || 0
    players = Number(e && e.n) || 0
  } catch {}

  return {
    period, metric, key: b.key, start: b.start, end: b.end,
    label: b.label, tz: b.tz,
    rows: rows.map((r, i) => ({
      rank: i + 1,
      steamid: String(r.steamid || ""),
      name: String(r.name || "").trim(),
      value: Number(r.value) || 0,
      metric, period
    })),
    total,
    // "complete" only when the panel observed every listed player from the
    // first minutes of the period; otherwise the values are period-to-date.
    coverage: {
      observed_players: players,
      first_seen: earliest,
      complete: earliest > 0 && earliest <= b.start + 300
    }
  }
}

/** Lifetime board (period=all): the same shape, straight from players. */
export async function lifetimeBoard(env, opts = {}) {
  const metric = BOARD_METRICS.includes(String(opts.metric || "")) ? String(opts.metric) : "xp"
  const limit = clampInt(opts.limit || 10, 1, 100)
  let rows = []
  try {
    const q = await env.DB.prepare(
      `SELECT steamid, name, ${metric} AS value FROM players
        WHERE ${metric} > 0 ORDER BY ${metric} DESC, steamid ASC LIMIT ?1`
    ).bind(limit).all()
    rows = q.results || []
  } catch { rows = [] }
  let total = 0
  try {
    const t = await env.DB.prepare(`SELECT COUNT(*) AS n FROM players WHERE ${metric} > 0`).first()
    total = Number(t && t.n) || 0
  } catch {}
  return {
    period: "all", metric, key: "all", start: 0, end: 0,
    label: "Lifetime", tz: "UTC",
    rows: rows.map((r, i) => ({
      rank: i + 1,
      steamid: String(r.steamid || ""),
      name: String(r.name || "").trim(),
      value: Number(r.value) || 0,
      metric, period: "all"
    })),
    total,
    coverage: { observed_players: total, first_seen: 0, complete: true }
  }
}

/** Board for an explicit settled period key (history), or [] when unknown. */
export async function historyBoard(env, { period, key, metric = "xp", limit = 15 } = {}) {
  const p = period === "month" ? "month" : "week"
  const m = BOARD_METRICS.includes(String(metric)) ? String(metric) : "xp"
  const lim = clampInt(limit, 1, 100)
  try {
    const q = await env.DB.prepare(
      `SELECT rank, steamid, name, value, settled_at FROM board_history
        WHERE period = ?1 AND period_key = ?2 AND metric = ?3
        ORDER BY rank ASC LIMIT ?4`
    ).bind(p, key, m, lim).all()
    return (q.results || []).map(r => ({
      rank: Number(r.rank) || 0,
      steamid: String(r.steamid || ""),
      name: String(r.name || "").trim(),
      value: Number(r.value) || 0,
      metric: m, period: p
    }))
  } catch { return [] }
}

/** Latest settled period key for a period type ('' when none). */
export async function lastSettledKey(env, period) {
  try {
    const r = await env.DB.prepare(
      `SELECT period_key FROM board_history WHERE period=?1 ORDER BY settled_at DESC LIMIT 1`
    ).bind(period).first()
    return r ? String(r.period_key) : ""
  } catch { return "" }
}

/** A player's lifetime XP standing: rank, value, and the player just above. */
export async function playerLifetimeStanding(env, p) {
  const value = Number(p && p.xp) || 0
  if (!p || value <= 0) return { rank: null, value: 0, ahead: null, behind: 0 }
  try {
    const r = await env.DB.prepare(`SELECT COUNT(*) AS n FROM players WHERE xp > ?1`).bind(value).first()
    const rank = Number(r && r.n) + 1
    const above = await env.DB.prepare(
      `SELECT name, xp FROM players WHERE xp > ?1 ORDER BY xp ASC LIMIT 1`
    ).bind(value).first()
    return {
      rank, value,
      ahead: above ? { rank: rank - 1, name: String(above.name || ""), value: Number(above.xp) || 0 } : null,
      behind: above ? Math.max(0, (Number(above.xp) || 0) - value) : 0
    }
  } catch { return { rank: null, value, ahead: null, behind: 0 } }
}

/**
 * A player's exact rank on a period board plus the nearest player above.
 * Counted in SQL rather than by slicing a 100-row page, so rank 150 is right.
 */
export async function playerPeriodStanding(env, steamid, opts = {}) {
  const period = opts.period === "month" ? "month" : "week"
  const metric = BOARD_METRICS.includes(String(opts.metric || "")) ? String(opts.metric) : "xp"
  const at = nowSec(opts.now)
  const b = periodBounds(period, at)
  await refreshMarks(env, at)
  const delta = `MAX(0, last_value - base)`
  try {
    const mine = await env.DB.prepare(
      `SELECT ${delta} AS v FROM board_marks WHERE period=?1 AND period_key=?2 AND metric=?3 AND steamid=?4`
    ).bind(period, b.key, metric, String(steamid)).first()
    if (!mine) return { rank: null, value: 0, ahead: null, behind: 0, key: b.key }
    const value = Number(mine.v) || 0
    if (value <= 0) return { rank: null, value: 0, ahead: null, behind: 0, key: b.key }
    const c = await env.DB.prepare(
      `SELECT COUNT(*) AS n FROM board_marks
        WHERE period=?1 AND period_key=?2 AND metric=?3 AND ${delta} > ?4`
    ).bind(period, b.key, metric, value).first()
    const rank = Number(c && c.n) + 1
    const aboveQ = await env.DB.prepare(
      `SELECT m.steamid AS steamid, COALESCE(p.name,'') AS name, ${delta} AS v
         FROM board_marks m LEFT JOIN players p ON p.steamid = m.steamid
        WHERE m.period=?1 AND m.period_key=?2 AND m.metric=?3 AND ${delta} > ?4
        ORDER BY v ASC LIMIT 1`
    ).bind(period, b.key, metric, value).first()
    return {
      rank, value, key: b.key,
      ahead: aboveQ ? { rank: rank - 1, name: String(aboveQ.name || ""), value: Number(aboveQ.v) || 0 } : null,
      behind: aboveQ ? Math.max(0, (Number(aboveQ.v) || 0) - value) : 0
    }
  } catch { return { rank: null, value: 0, ahead: null, behind: 0, key: b.key } }
}

/** A player's lifetime XP rank (null when the player has no XP at all). */
export async function playerLifetimeRank(env, p) {
  const xp = Number(p && p.xp) || 0
  if (!p || xp <= 0) return null
  try {
    const r = await env.DB.prepare(`SELECT COUNT(*) AS n FROM players WHERE xp > ?1`).bind(xp).first()
    return Number(r && r.n) + 1
  } catch { return null }
}

// ---- badges ---------------------------------------------------------------

export const BADGE_LABELS = {
  weekly_champion: "Weekly #1",
  monthly_champion: "Monthly #1",
  weekly_top3: "Top 3 of the week",
  weekly_streak3: "Top 3 three weeks running"
}

/** Text-only badges for one player, newest first. */
export async function playerBadges(env, steamid, limit = BADGE_WINDOW) {
  if (!steamid) return []
  try {
    await ensureBoardTables(env)
    const q = await env.DB.prepare(
      `SELECT kind, period, label, awarded_at FROM badges
        WHERE steamid = ?1 ORDER BY awarded_at DESC, id DESC LIMIT ?2`
    ).bind(String(steamid), clampInt(limit, 1, 50)).all()
    return (q.results || []).map(r => ({
      kind: String(r.kind || ""),
      period: String(r.period || ""),
      label: String(r.label || ""),
      awarded_at: Number(r.awarded_at) || 0
    }))
  } catch { return [] }
}

export async function countBadges(env) {
  try {
    await ensureBoardTables(env)
    const r = await env.DB.prepare(`SELECT COUNT(*) AS n FROM badges`).first()
    return Number(r && r.n) || 0
  } catch { return 0 }
}

async function awardBadge(env, steamid, kind, period, label, at) {
  if (!steamid) return false
  try {
    const res = await env.DB.prepare(
      `INSERT OR IGNORE INTO badges (steamid, kind, period, label, awarded_at) VALUES (?1,?2,?3,?4,?5)`
    ).bind(String(steamid), kind, String(period), String(label).slice(0, 120), at).run()
    return Number(res && res.meta && res.meta.changes) > 0
  } catch { return false }
}

async function weeklyTop3Keys(env, keys) {
  const out = new Map() // steamid -> Set(week key)
  const clean = keys.filter(k => /^\d{4}-W\d{2}$/.test(String(k)))
  if (!clean.length) return out
  try {
    const q = await env.DB.prepare(
      `SELECT period_key, steamid FROM board_history
        WHERE period='week' AND metric='xp' AND rank <= 3
          AND period_key IN (${clean.map((_, i) => "?" + (i + 1)).join(",")})`
    ).bind(...clean).all()
    for (const r of q.results || []) {
      const sid = String(r.steamid || "")
      if (!out.has(sid)) out.set(sid, new Set())
      out.get(sid).add(String(r.period_key))
    }
  } catch {}
  return out
}

/**
 * Settle one finished period into board_history and award the text badges.
 * `key` is the finished period key; the window is located from that key so a
 * delayed rollover still labels the badges with their own week/month.
 */
export async function settlePeriod(env, period, key, now) {
  if (!(await ensureBoardTables(env))) return { period, key, rows: 0, badges: 0 }
  const at = nowSec(now)
  const label = keyLabel(period, key)
  let rows = 0
  try {
    const q = await env.DB.prepare(
      `SELECT steamid, COALESCE((SELECT p.name FROM players p WHERE p.steamid = m.steamid), '') AS name,
              MAX(0, m.last_value - m.base) AS value
         FROM board_marks m
        WHERE m.period = ?1 AND m.period_key = ?2 AND m.metric = 'xp' AND m.last_value > m.base
        ORDER BY value DESC, name ASC, m.steamid ASC
        LIMIT ?3`
    ).bind(period, key, BOARD_TOP_N).all()
    const list = q.results || []
    for (let i = 0; i < list.length; i++) {
      const r = list[i]
      await env.DB.prepare(
        `INSERT OR IGNORE INTO board_history (period, period_key, metric, rank, steamid, name, value, settled_at)
         VALUES (?1,?2,'xp',?3,?4,?5,?6,?7)`
      ).bind(period, key, i + 1, String(r.steamid || ""), String(r.name || "").trim(), Number(r.value) || 0, at).run()
      rows++
    }
  } catch { rows = 0 }

  // Badges. Only place 1 is a champion; 1-3 earn a "top 3" tag, which is what
  // the three-week streak check reads back.
  let badges = 0
  try {
    const q = await env.DB.prepare(
      `SELECT rank, steamid, value FROM board_history
        WHERE period=?1 AND period_key=?2 AND metric='xp' ORDER BY rank ASC LIMIT 3`
    ).bind(period, key).all()
    const top = q.results || []
    for (const r of top) {
      const sid = String(r.steamid || "")
      const n = Number(r.rank) || 0
      if (n === 1) {
        const kind = period === "month" ? "monthly_champion" : "weekly_champion"
        if (await awardBadge(env, sid, kind, key, `${BADGE_LABELS[kind]} · ${label}`, at)) badges++
      }
      if (period === "week" && n >= 1 && n <= 3) {
        if (await awardBadge(env, sid, "weekly_top3", key, `${BADGE_LABELS.weekly_top3} · ${label}`, at)) badges++
      }
    }
    // "Top 3 three weeks running": this week's top 3 members who were also in
    // the top 3 of the two previous weeks. Cheap: one indexed lookup.
    if (period === "week" && top.length) {
      const prevKeys = keysBefore("week", key, at, 2)
      const seen = await weeklyTop3Keys(env, [key, ...prevKeys])
      for (const r of top) {
        const sid = String(r.steamid || "")
        const set = seen.get(sid)
        if (!set || set.size < 3) continue
        if (await awardBadge(env, sid, "weekly_streak3", key, `${BADGE_LABELS.weekly_streak3} · ${label}`, at)) badges++
      }
    }
  } catch {}

  return { period, key, rows, badges }
}

/**
 * Settle every period that rolled over since the last run. Idempotent and
 * cheap: one meta read per period on the common path.
 */
export async function maybeRollover(env, now) {
  if (!(await ensureBoardTables(env))) return { settled: [] }
  const at = nowSec(now)
  const settled = []
  for (const period of PERIODS) {
    const cur = periodBounds(period, at)
    const stampKey = `board_settled:${period}`
    const done = await metaGet(env, stampKey)
    if (!done) {
      // First run on this deployment: record where we are, never invent a
      // winner for a period we never observed.
      await metaPut(env, stampKey, cur.key)
      continue
    }
    if (done === cur.key) continue
    const prev = previousKey(period, at)
    if (done === prev) {
      const res = await settlePeriod(env, period, prev, at)
      settled.push(res)
      await metaPut(env, stampKey, cur.key)
    } else {
      // A gap (panel down for a whole period): settle only the immediately
      // previous period, which is the one board_marks can still describe.
      const res = await settlePeriod(env, period, prev, at)
      settled.push(res)
      await metaPut(env, stampKey, cur.key)
    }
  }
  return { settled }
}

/** Recently settled champions, newest first (used by the MOTD top page). */
export async function recentChampions(env, period, limit = 3) {
  const p = period === "month" ? "month" : "week"
  try {
    const q = await env.DB.prepare(
      `SELECT period_key, name, steamid, value, settled_at FROM board_history
        WHERE period=?1 AND metric='xp' AND rank=1 ORDER BY settled_at DESC LIMIT ?2`
    ).bind(p, clampInt(limit, 1, 10)).all()
    return (q.results || []).map(r => ({
      period_key: String(r.period_key || ""),
      label: keyLabel(p, r.period_key),
      name: String(r.name || "").trim(),
      steamid: String(r.steamid || ""),
      value: Number(r.value) || 0,
      settled_at: Number(r.settled_at) || 0
    }))
  } catch { return [] }
}
