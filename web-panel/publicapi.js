// Public, unauthenticated read-only JSON for the Discord bot (and anything
// else that wants the boards without scraping HTML).
//
// Contract, limits and examples: docs/PUBLIC-API.md
//
// Principles:
//   * no session, no secret, no token — nothing here can mutate anything;
//   * no personal data: no IPs, no sessions, no action queue, no other
//     players' private state. A player endpoint answers game statistics only;
//   * no invented numbers. Anything the panel cannot know is null and the
//     docs say why;
//   * every response is `Cache-Control: no-store` (a live board is not a
//     cacheable document) and JSON only.
import { serverMeta } from "./top15/meta.js"
import { xpPerTier, playerBpTier, bpInto, BP_MAX_TIER } from "./bp_track.js"
import { playerBadges, lifetimeBoard, periodBoard, playerLifetimeRank } from "./boards.js"
import { loadSchedule, splitSchedule } from "./schedule.js"
import { periodBounds } from "./periods.js"

const nowSec = () => Math.floor(Date.now() / 1000)

// ---- rate limiting --------------------------------------------------------
// Same policy the rest of the panel runs under (there is no shared counter to
// hook into; the admin login lockout lives in meta and is deliberately not
// touched here). A fixed one-minute window per client address is enough to
// keep a poll loop honest without a dependency.
const RATE_LIMIT = Number(process.env.PANEL_PUBLIC_RATE_LIMIT || 120)
const RATE_BUCKETS = new Map()

function clientKey(request) {
  // The runner strips client-supplied forwarding headers and stamps the socket
  // address here; cf-connecting-ip is the platform's own value on Cloudflare.
  const ip = request.headers.get("x-freenova-client-ip") || request.headers.get("cf-connecting-ip") || ""
  return ip || "unknown"
}

function rateCheck(request, now) {
  const key = clientKey(request) + ":" + Math.floor(now / 60)
  const n = (RATE_BUCKETS.get(key) || 0) + 1
  RATE_BUCKETS.set(key, n)
  if (RATE_BUCKETS.size > 4000) {
    // Prune closed windows so a long-running process cannot grow for ever.
    const cut = Math.floor(now / 60) - 1
    for (const k of RATE_BUCKETS.keys()) {
      const w = Number(String(k).slice(String(k).lastIndexOf(":") + 1))
      if (!Number.isFinite(w) || w < cut) RATE_BUCKETS.delete(k)
    }
  }
  return n <= RATE_LIMIT
}

function json(body, status = 200) {
  return new Response(JSON.stringify(body, null, 2), {
    status,
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store",
      "x-content-type-options": "nosniff",
      "access-control-allow-origin": "*"
    }
  })
}

function fail(status, error, message, extra) {
  return json({ error, message, ...(extra || {}) }, status)
}

// ---- shared helpers -------------------------------------------------------

/** Canonical STEAM_x:y:z from "0-0-123", "STEAM_0:0:123", any case. */
export function normalizeSteamid(raw) {
  const s = String(raw == null ? "" : raw).trim()
  const packed = /^(\d{1,2})-(\d)-(\d{1,20})$/.exec(s)
  if (packed) return `STEAM_${Number(packed[1])}:${packed[2]}:${packed[3]}`
  const full = /^STEAM_(\d{1,2}):(\d):(\d{1,20})$/i.exec(s)
  if (full) return `STEAM_${Number(full[1])}:${full[2]}:${full[3]}`
  return ""
}

const int = v => {
  const n = Number(v)
  return Number.isFinite(n) ? Math.trunc(n) : 0
}

async function bpTrack(env) {
  try {
    const cat = await env.DB.prepare(`SELECT json FROM catalog WHERE key = 'reward_track'`).first()
    if (cat && cat.json) return JSON.parse(cat.json)
  } catch {}
  return null
}

/**
 * The player block the bot and the MOTD header both read. One implementation
 * so /api/public/player and the in-game header can never disagree.
 *
 * rank is null for a player with no XP (an unranked new player has no
 * meaningful position on the lifetime board).
 */
export async function publicPlayerSummary(env, steamid) {
  const sid = normalizeSteamid(steamid)
  if (!sid) return null
  let p = null
  try {
    p = await env.DB.prepare(`SELECT * FROM players WHERE steamid = ?1`).bind(sid).first()
  } catch { p = null }
  if (!p) return null

  const track = await bpTrack(env)
  const need = xpPerTier(track)
  const tier = Math.min(BP_MAX_TIER, playerBpTier(p, need))
  const bpXp = Math.max(0, int(p.bp_xp))
  const maxed = tier >= BP_MAX_TIER
  const into = bpInto(bpXp, need)
  const rank = await playerLifetimeRank(env, p)
  const badges = await playerBadges(env, sid)

  return {
    steamid: sid,
    name: String(p.name || "").trim(),
    rank,
    bp_tier: tier,
    bp_xp: bpXp,
    bp_next_xp: maxed ? 0 : Math.max(0, need - into),
    bp_progress: maxed ? need : into,
    bp_tier_xp: need,
    bp_max_tier: BP_MAX_TIER,
    coins: int(p.coins),
    playtime_minutes: int(p.playtime_minutes),
    badges: badges.map(b => ({ kind: b.kind, period: b.period, label: b.label }))
  }
}

// ---- endpoints ------------------------------------------------------------

// GET /api/public/status
async function status(env, now) {
  const meta = await serverMeta(env, now)
  const lastPush = int(meta.lastPush) || 0
  // The panel has no A2S client: a live player count exists only while the
  // game's own signed push is recent. Older than that and we report null
  // instead of a number that stopped being true.
  const fresh = lastPush > 0 && now - lastPush <= 180
  const schedule = await loadSchedule(env, now)
  const { now: live, next } = splitSchedule(schedule, now)
  const pick = e => e ? {
    title: e.title, starts_at: e.starts_at, ends_at: e.ends_at, detail: e.detail, state: e.state
  } : null
  return json({
    server: {
      name: meta.hostname || "FreeNova CS 1.6",
      map: meta.map && meta.map !== "—" ? meta.map : null,
      online: Boolean(meta.online && fresh),
      players: fresh ? int(meta.players) : null,
      max: fresh ? int(meta.maxplayers) || null : null,
      next_map: null,
      last_push: lastPush || null,
      stale: lastPush ? !fresh : true
    },
    events: { now: live.map(pick), next: pick(next) },
    updated: now
  })
}

// GET /api/public/top?period=week|month|all&limit=10&metric=xp|kills
async function top(env, url, now) {
  const period = String(url.searchParams.get("period") || "week").toLowerCase()
  if (!["week", "month", "all"].includes(period))
    return fail(400, "bad_period", "period must be week, month or all", { allowed: ["week", "month", "all"] })
  const rawLimit = url.searchParams.get("limit")
  let limit = 10
  if (rawLimit != null && rawLimit !== "") {
    limit = Number(rawLimit)
    if (!Number.isFinite(limit) || limit < 1)
      return fail(400, "bad_limit", "limit must be a whole number between 1 and 50")
    limit = Math.min(50, Math.trunc(limit))
  }
  const metric = String(url.searchParams.get("metric") || "xp").toLowerCase()
  if (!["xp", "kills"].includes(metric))
    return fail(400, "bad_metric", "metric must be xp or kills", { allowed: ["xp", "kills"] })

  const board = period === "all"
    ? await lifetimeBoard(env, { metric, limit })
    : await periodBoard(env, { period, metric, limit, now })

  return json({
    period: board.period,
    metric: board.metric,
    limit,
    key: board.key,
    window: period === "all"
      ? { key: "all", start: null, end: null, tz: "UTC", label: board.label }
      : { key: board.key, start: board.start, end: board.end, tz: board.tz, label: board.label },
    rows: board.rows,
    total: board.total,
    coverage: board.coverage,
    updated: now
  })
}

// GET /api/public/player/<steamid>
async function player(env, rawSid, now) {
  const sid = normalizeSteamid(rawSid)
  if (!sid)
    return fail(400, "bad_steamid", "steamid must look like STEAM_0:0:123 or 0-0-123", { given: String(rawSid || "") })
  const summary = await publicPlayerSummary(env, sid)
  if (!summary)
    return fail(404, "player_not_found", "the panel has no snapshot for this steamid yet", { steamid: sid })
  return json({ ...summary, updated: now })
}

// GET /api/public/events
async function events(env, now) {
  const schedule = await loadSchedule(env, now)
  const { now: live, next } = splitSchedule(schedule, now)
  return json({
    events: schedule.map(e => ({
      title: e.title,
      starts_at: e.starts_at,
      ends_at: e.ends_at,
      detail: e.detail,
      state: e.state
    })),
    now: live.length,
    next: next ? next.title : null,
    updated: now,
    // The game's configs/freenova/events.ini is still the source of truth for
    // the multipliers the server applies; this schedule is the panel's own.
    source: "panel"
  })
}

// ---- dispatch -------------------------------------------------------------

export async function handlePublicApi(request, env, url) {
  const now = nowSec()
  if (!rateCheck(request, now))
    return fail(429, "rate_limited", `more than ${RATE_LIMIT} requests in a minute`)

  const path = (url.pathname.replace(/\/+$/, "") || "/api/public")
  const m = /^\/api\/public\/player\/(.+)$/.exec(path)
  try {
    if (path === "/api/public/status") return await status(env, now)
    if (path === "/api/public/top") return await top(env, url, now)
    if (path === "/api/public/events") return await events(env, now)
    if (m) return await player(env, decodeURIComponent(m[1]), now)
  } catch (e) {
    // Never leak a stack or a SQL string to an unauthenticated caller.
    console.error("public api error:", e && e.message)
    return fail(500, "internal_error", "the panel could not build this response")
  }
  return fail(404, "not_found", "unknown public endpoint", {
    endpoints: ["/api/public/status", "/api/public/top", "/api/public/player/<steamid>", "/api/public/events"]
  })
}

/** Exposed for tests: reset the per-minute buckets. */
export function resetPublicRateLimit() { RATE_BUCKETS.clear() }

/** The window /api/public/top would report for a period right now (tests). */
export function currentWindow(period, now = nowSec()) {
  return periodBounds(period === "month" ? "month" : "week", now)
}
