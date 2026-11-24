// Europe/Paris period boundaries — the ONE place weekly/monthly boards are cut.
//
// /api/public/top, the in-panel boards and the MOTD top page all call this
// module, so the site, the MOTD and the Discord bot can never disagree about
// where "this week" starts.
//
//   week  = ISO week (Monday 00:00 Europe/Paris .. next Monday 00:00)
//   month = calendar month (1st 00:00 Europe/Paris .. 1st of next month)
//
// DST is handled without any date library: we only ever read the Paris wall
// clock through Intl (so the offset is whatever Paris actually used at that
// instant) and convert a Paris midnight back to epoch seconds by iterating the
// offset twice. Paris changes clocks at 02:00/03:00 local, never at midnight,
// so every midnight this module asks for exists.
//
// Everything here is pure and synchronous: no DB, no network, unit-testable.

export const PARIS_TZ = "Europe/Paris"

// The Winterfest season, in Paris calendar terms. One season per event; a
// rollover changes these four lines and nothing else (src/state.js SEASON and
// the advent page read them too). Day N of the advent calendar is the (N)th of
// December, the event ends on the last day (24th), and an Advent Pass owner may
// still claim missed days from the 25th until the grace day (31st) - then the
// calendar is closed for everybody.
export const SEASON_YEAR = 2026
export const SEASON_LAST_DAY = 24
export const PASS_REOPENS_FROM = 25
export const PASS_GRACE_LAST_DAY = 31

const MONTHS = [
  "January", "February", "March", "April", "May", "June",
  "July", "August", "September", "October", "November", "December"
]

// Small cache: one formatter per timezone string. Intl formatters are not
// cheap to build and these run on every board request.
const FMT = new Map()
function fmtFor(tz) {
  let f = FMT.get(tz)
  if (!f) {
    f = new Intl.DateTimeFormat("en-GB", {
      timeZone: tz, year: "numeric", month: "2-digit", day: "2-digit",
      hour: "2-digit", minute: "2-digit", second: "2-digit", hourCycle: "h23"
    })
    FMT.set(tz, f)
  }
  return f
}

function partsAt(sec, tz) {
  const base = Math.floor(Number(sec) || 0)
  const out = { y: 1970, m: 1, d: 1, hh: 0, mm: 0, ss: 0 }
  for (const p of fmtFor(tz).formatToParts(new Date(base * 1000))) {
    if (p.type === "year") out.y = Number(p.value)
    else if (p.type === "month") out.m = Number(p.value)
    else if (p.type === "day") out.d = Number(p.value)
    else if (p.type === "hour") out.hh = Number(p.value) % 24
    else if (p.type === "minute") out.mm = Number(p.value)
    else if (p.type === "second") out.ss = Number(p.value)
  }
  return { ...out, base }
}

/** Paris wall-clock parts for an epoch-second timestamp. */
export function parisParts(sec) {
  const p = partsAt(sec, PARIS_TZ)
  return { y: p.y, m: p.m, d: p.d, hh: p.hh, mm: p.mm, ss: p.ss }
}

/** Seconds east of UTC that Paris is using at that instant (+3600 / +7200). */
export function parisOffset(sec) {
  const p = partsAt(sec, PARIS_TZ)
  const asIfUtc = Date.UTC(p.y, p.m - 1, p.d, p.hh, p.mm, p.ss) / 1000
  return asIfUtc - p.base
}

/**
 * Epoch seconds of 00:00 Europe/Paris on a calendar date. y/m/d may overflow
 * (m = 13, d = 32) — Date.UTC normalises the calendar for us.
 */
export function parisMidnight(y, m, d) {
  const wall = Date.UTC(y, m - 1, d) / 1000
  let t = wall
  for (let i = 0; i < 3; i++) {
    const next = wall - parisOffset(t)
    if (next === t) break
    t = next
  }
  return t
}

/** ISO weekday of a calendar date: Monday = 1 .. Sunday = 7. */
export function isoWeekday(y, m, d) {
  return new Date(Date.UTC(y, m - 1, d)).getUTCDay() || 7
}

/** ISO week number + ISO week-year for a calendar date (ISO 8601: Thursday rule). */
export function isoWeekOf(y, m, d) {
  const t = new Date(Date.UTC(y, m - 1, d))
  t.setUTCDate(t.getUTCDate() + 4 - (t.getUTCDay() || 7))
  const yearStart = Date.UTC(t.getUTCFullYear(), 0, 1)
  const week = Math.ceil(((t.getTime() - yearStart) / 86400000 + 1) / 7)
  return { year: t.getUTCFullYear(), week }
}

const pad2 = n => String(n).padStart(2, "0")

/** "2026-W47" / "2026-11" */
export function weekKeyAt(sec) {
  const p = parisParts(sec)
  const { year, week } = isoWeekOf(p.y, p.m, p.d)
  return `${year}-W${pad2(week)}`
}

export function monthKeyAt(sec) {
  const p = parisParts(sec)
  return `${p.y}-${pad2(p.m)}`
}

/**
 * The [start, end) window of the current week (or month) around `sec`, in UTC
 * epoch seconds, plus the period key and a human label.
 */
export function periodBounds(period, sec) {
  const p = parisParts(sec)
  if (period === "month") {
    const start = parisMidnight(p.y, p.m, 1)
    const end = parisMidnight(p.y, p.m + 1, 1)
    return {
      period: "month",
      key: `${p.y}-${pad2(p.m)}`,
      start, end,
      label: `${MONTHS[p.m - 1]} ${p.y}`,
      tz: PARIS_TZ
    }
  }
  const dow = isoWeekday(p.y, p.m, p.d)
  // Monday of this ISO week, as a normalised calendar date.
  const mondayMs = Date.UTC(p.y, p.m - 1, p.d - (dow - 1))
  const md = new Date(mondayMs)
  const start = parisMidnight(md.getUTCFullYear(), md.getUTCMonth() + 1, md.getUTCDate())
  const nd = new Date(mondayMs + 7 * 86400000)
  const end = parisMidnight(nd.getUTCFullYear(), nd.getUTCMonth() + 1, nd.getUTCDate())
  const { year, week } = isoWeekOf(p.y, p.m, p.d)
  return {
    period: "week",
    key: `${year}-W${pad2(week)}`,
    start, end,
    label: `Week ${week} · ${year}`,
    tz: PARIS_TZ
  }
}

/** The key of the period that ended just before the current one. */
export function previousKey(period, sec) {
  const cur = periodBounds(period, sec)
  return periodBounds(period, cur.start - 1).key
}

/** The window for an explicit period key (accepts any instant inside it). */
export function keyLabel(period, key) {
  if (period === "month") {
    const m = /^(\d{4})-(\d{2})$/.exec(String(key || ""))
    if (m && Number(m[2]) >= 1 && Number(m[2]) <= 12)
      return `${MONTHS[Number(m[2]) - 1]} ${m[1]}`
    return String(key || "")
  }
  const m = /^(\d{4})-W(\d{2})$/.exec(String(key || ""))
  return m ? `Week ${Number(m[2])} · ${m[1]}` : String(key || "")
}

/**
 * The `count` period keys immediately before `key`, newest first. Walks back
 * from `sec` (the current instant) until it meets `key`, so it needs no key
 * parsing and stays correct across an ISO week-year or calendar-year change.
 */
export function keysBefore(period, key, sec, count = 2) {
  const out = []
  let cursor = Math.floor(Number(sec) || 0)
  let found = false
  for (let i = 0; i < 200; i++) {
    const b = periodBounds(period, cursor)
    if (found) out.push(b.key)
    else if (b.key === key) found = true
    cursor = b.start - 1
    if (found && out.length >= count) break
  }
  return found ? out.slice(0, Math.max(0, count)) : []
}

/** Is `sec` inside the [start, end) window of a period key? */
export function keyWindow(period, key, sec) {
  const cur = periodBounds(period, sec)
  if (cur.key !== key) {
    // Walk back from now at most ~26 periods to locate the key (cheap, no
    // dependency on string parsing) and return its window.
    let probe = cur.start - 1
    for (let i = 0; i < 26; i++) {
      const b = periodBounds(period, probe)
      if (b.key === key) return b
      probe = b.start - 1
    }
    return null
  }
  return cur
}

export const PERIODS = ["week", "month"]
// ============================================================================
// The advent calendar's clock and its date law (docs/panel/03-DASHBOARD.md and
// the owner's date law, stated in full below).
//
// It lives HERE, not in the page, because two layers read it and they must read
// the same arithmetic: the advent page (src/panel/advent.js draws its verdicts)
// and applyAction() in src/state.js (which ENFORCES them inside the transaction
// that pays the reward). A second copy of this rule in either place is a way for
// a client to claim a day the calendar has not opened.
//
//   1. Every date is a Europe/Paris calendar date, from parisParts/parisMidnight.
//   2. Day N can be claimed ON DAY N ONLY. Before that date LOCKED, after it
//      MISSED. No catch-up while the event runs.
//   3. After 24 December 23:59:59 Paris, only an Advent Pass owner may claim the
//      missed days, and only until the end of 31 December.
// ============================================================================

export const ADVENT_DAYS = 24

/** The Paris midnight that starts advent day N of the given season. */
export function dayStart(day, season) {
  return parisMidnight(Number(season) || SEASON_YEAR, 12, Number(day))
}

/** 'YYYY-MM-DD' of advent day N, as the server counts it. */
export function dayDate(day, season) {
  const p = parisParts(dayStart(day, season))
  return `${p.y}-${String(p.m).padStart(2, "0")}-${String(p.d).padStart(2, "0")}`
}

/** The Paris calendar date `now` falls on, as 'YYYY-MM-DD'. */
export function todayDate(now) {
  const p = parisParts(Math.floor(Number(now)))
  return `${p.y}-${String(p.m).padStart(2, "0")}-${String(p.d).padStart(2, "0")}`
}

/**
 * Where the calendar stands right now. `phase` drives every date rule:
 *   before     - before 1 December Paris: nothing is claimable, nothing is missed
 *   during     - 1..24 December: today's day is the only open one
 *   closed     - 25..31 December: everybody is closed except a Pass owner
 *   ended      - from 1 January Paris: closed for everyone, pass or not
 */
export function adventClock(now, opts) {
  const sec = Math.floor(Number(now))
  const season = (opts && opts.season) || SEASON_YEAR
  const today = todayDate(sec)
  const start = parisMidnight(season, 12, 1)
  const lastDayStart = parisMidnight(season, 12, SEASON_LAST_DAY)          // 24 Dec 00:00
  const endExclusive = parisMidnight(season, 12, SEASON_LAST_DAY + 1)      // 25 Dec 00:00
  const graceEnd = parisMidnight(season, PASS_GRACE_LAST_DAY + 1)          // 1 Jan 00:00

  let phase = "during"
  if (sec < start) phase = "before"
  else if (sec >= graceEnd) phase = "ended"
  else if (sec >= endExclusive) phase = "closed"

  // The day whose Paris date is today, or 0 when today is not an advent day.
  let todayDay = 0
  if (phase === "during") {
    const p = parisParts(sec)
    if (p.m === 12) todayDay = Math.min(p.d, ADVENT_DAYS)
  }
  return {
    now: sec,
    season,
    today,
    phase,
    grace: phase === "closed",     // 25..31 December: only the Pass reopens a day
    todayDay,
    start,
    lastDayStart,
    endExclusive,
    graceEnd,
    // The day the page centres on: today's day while the calendar runs, the last
    // day once it is over, and - before 1 December - day 1, because a preview of
    // the road ahead starts at the beginning of it.
    focusDay: todayDay || (phase === "during" ? ADVENT_DAYS : (phase === "before" ? 1 : ADVENT_DAYS))
  }
}

/**
 * The state of one day for one player:
 *   claimed - a row exists in winter_advent for it
 *   open    - it is today AND nothing else, or (after 24 Dec) it was missed AND
 *             the player owns the Advent Pass inside the grace window
 *   locked  - it is still in the future
 *   missed  - its date has gone by and the player does not hold it
 */
export function adventStateOf(day, clock, claimedDays, hasPass) {
  const d = Number(day)
  if (claimedDays && claimedDays.has(d)) return "claimed"
  if (clock.phase === "before" || clock.phase === "ended") return "locked"
  if (clock.phase === "during") {
    if (d === clock.todayDay) return "open"
    return d > clock.todayDay ? "locked" : "missed"
  }
  // 25..31 December: the event is over. Only the Pass reopens what was missed.
  if (hasPass) return "open"
  return "missed"
}

/** Server-side claim check with the owner's words in the refusal. "" = allowed. */
export function claimRefusal(day, clock, claimedDays, hasPass) {
  const d = Number(day)
  if (!Number.isInteger(d) || d < 1 || d > ADVENT_DAYS) return `there is no advent day ${day}`
  const state = adventStateOf(d, clock, claimedDays, hasPass)
  if (state === "open") return ""
  if (state === "claimed") return `day ${d} is already claimed`
  if (state === "missed") return `day ${d} was missed - a missed day cannot be claimed`
  if (clock.phase === "before") return "the advent calendar opens on 1 December"
  if (clock.phase === "ended") return "Winterfest is over"
  if (clock.phase === "closed") return `day ${d} was missed - the Advent Pass is needed to claim it after ${SEASON_LAST_DAY} December`
  return `day ${d} opens on ${dayDate(d, clock.season)}`
}

