// The panel's event schedule — the one reader used by /api/public/events, by
// the MOTD events page and by the bot behind it.
//
// SCOPE / HONESTY (see docs/PUBLIC-API.md):
//   * The game server's `configs/freenova/events.ini` remains the source of
//     truth for the multipliers the game actually applies. The panel cannot
//     write that file, and this module never claims otherwise.
//   * The panel owns this *schedule*: what is running, what starts next, and
//     the player-facing blurb, which staff edit in /admin?s=events.
//   * Rows come from the panel `events` table only. The old /events page also
//     merges a catalog of legacy cards; this module deliberately does not, so
//     "state" here never describes a card that has no row.
//
// TODO(push): once the sync `actions` channel grows a `srv_event_schedule`
// action, the game could pull this schedule instead of staff editing
// events.ini by hand. Until the plugin implements and validates that action,
// nothing here writes to the game — do not pretend it does.
const SCHEDULE_TTL_MS = 15000

// Per-env cache: the MOTD and the bot both poll, and the runner keeps one env
// for its lifetime. Keyed by the env object so two DBs never share rows.
const cache = new WeakMap()

function nowSec(v) { return Math.floor(Number(v) || Date.now() / 1000) }

async function hasColumn(env, table, column) {
  try {
    const { results } = await env.DB.prepare(`PRAGMA table_info(${table})`).all()
    return (results || []).some(r => String(r.name) === column)
  } catch { return false }
}

// Per-env memo for the events.detail migration.
const detailReady = new WeakSet()

/**
 * Add the public `detail` blurb column to an existing events table. ALTER is
 * not idempotent, so this is guarded by a PRAGMA check and memoised per env;
 * a fresh database gets the column from schema.sql / ensureOpsTables. Safe on
 * the live replica: it only ever adds a column with a default.
 */
export async function ensureScheduleDetailColumn(env) {
  if (!env || !env.DB) return false
  if (detailReady.has(env)) return true
  if (await hasColumn(env, "events", "detail")) { detailReady.add(env); return true }
  try {
    await env.DB.prepare(`ALTER TABLE events ADD COLUMN detail TEXT NOT NULL DEFAULT ''`).run()
    detailReady.add(env)
    return true
  } catch { return false }
}

function cleanText(v, max = 160) {
  return String(v == null ? "" : v).replace(/[\r\n\t]+/g, " ").replace(/\s{2,}/g, " ").trim().slice(0, max)
}

/**
 * Map one events row to the public shape. `detail` is the player-facing blurb
 * (staff editable). On a replica that predates the detail column we fall back
 * to reward text, then to nothing — never to an invented sentence.
 *
 * state is derived from the row's own lifecycle status, not guessed from the
 * clock alone: a scheduled row whose window already opened is "overdue" (the
 * scheduler has not activated it yet), which is the honest label and lets the
 * bot flag it instead of announcing an event that is not running.
 */
function mapRow(row) {
  const start = Number(row.start_at) || 0
  const end = Number(row.end_at) || 0
  const status = String(row.status || "").toLowerCase()
  let state = "scheduled"
  if (status === "cancelled") state = "cancelled"
  else if (status === "completed" || status === "error") state = "ended"
  else if (status === "active") state = "active"
  else if (!start) state = "unscheduled"
  return {
    id: Number(row.id) || 0,
    title: cleanText(row.title, 80) || `Event ${Number(row.id) || ""}`.trim(),
    starts_at: start,
    ends_at: end,
    detail: cleanText(row.detail || row.reward || "", 160),
    state,
    type: cleanText(row.type, 32),
    xp_mult: Number(row.xp_mult) || 1,
    coins_mult: Number(row.coins_mult) || 1
  }
}

/**
 * The whole panel schedule, soonest first. Rows that finished more than a day
 * ago are dropped (the archive lives on /events and in event_history).
 * Cached for a few seconds per process: the MOTD and the bot both poll.
 */
export async function loadSchedule(env, now, opts = {}) {
  const at = nowSec(now)
  const hit = env ? cache.get(env) : null
  if (!opts.force && hit && hit.rows.length && at - hit.at < SCHEDULE_TTL_MS / 1000) {
    return hit.rows.map(r => ({ ...r, state: stateAt(r, at) }))
  }
  let rows = []
  let cols = null
  try {
    await ensureScheduleDetailColumn(env)
    cols = await hasColumn(env, "events", "detail")
    const sel = `SELECT id, title, type, status, start_at, end_at, xp_mult, coins_mult, reward${cols ? ", detail" : ""} FROM events`
    const q = await env.DB.prepare(
      `${sel} ORDER BY CASE WHEN start_at = 0 THEN 1 ELSE 0 END, start_at ASC, id ASC`
    ).all()
    rows = (q.results || []).map(mapRow)
  } catch {
    rows = []
  }
  const kept = rows.filter(r => !r.ends_at || r.ends_at >= at - 86400)
  if (env) cache.set(env, { at, rows: kept })
  return kept.map(r => ({ ...r, state: stateAt(r, at) }))
}

function stateAt(r, at) {
  if (r.state === "cancelled" || r.state === "ended" || r.state === "active" || r.state === "unscheduled") return r.state
  if (!r.starts_at) return "unscheduled"
  if (at < r.starts_at) return "scheduled"
  // The window opened but the scheduler has not flipped it to active: report
  // the gap instead of claiming it is running.
  return "overdue"
}

/** { now: [...], next: row|null } — the /api/public/status events block. */
export function splitSchedule(rows, now) {
  const at = nowSec(now)
  const list = rows || []
  const active = list.filter(r => stateAt(r, at) === "active")
  const upcoming = list
    .filter(r => stateAt(r, at) === "scheduled")
    .sort((a, b) => (a.starts_at || 0) - (b.starts_at || 0))
  return { now: active, next: upcoming[0] || null }
}

/** Drop the cached schedule for one env (tests). */
export function clearScheduleCache(env) { if (env) cache.delete(env) }

const UNITS = [["d", 86400], ["h", 3600], ["m", 60]]

/** Server-side countdown text: "ends in 2d 3h" / "starts in 12m" / "". */
export function countdownText(row, now) {
  if (!row) return ""
  const at = nowSec(now)
  const state = stateAt(row, at)
  const target = state === "active" ? row.ends_at : row.starts_at
  if (!target) return ""
  const left = Math.max(0, target - at)
  if (left <= 0) return state === "active" ? "closing now" : ""
  const label = state === "active" ? "ends in" : "starts in"
  let out = ""
  let rem = left
  for (const [u, size] of UNITS) {
    const n = Math.floor(rem / size)
    if (n > 0) { out += (out ? " " : "") + n + u; rem -= n * size }
    if (out && out.split(" ").length >= 2) break
  }
  if (!out) out = "<1m"
  return `${label} ${out}`
}

/** "2026-11-22 21:00 UTC" — no locale surprises, no client JS. */
export function utcText(sec) {
  const n = Number(sec) || 0
  if (!n) return "—"
  return new Date(n * 1000).toISOString().slice(0, 16).replace("T", " ") + " UTC"
}
