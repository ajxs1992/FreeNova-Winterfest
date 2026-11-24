// FreeNova panel — the advent calendar (page 3 of the Winterfest UI, plate
// docs/design/refs/winterfest/11-advent.png, 1622x969).
//
// THE OWNER'S DATE LAW (this file is the whole of it, and nothing else decides)
//   1. Every date is a Europe/Paris calendar date. The clock comes from
//      src/periods.js (parisParts / parisMidnight), never from a UTC guess and
//      never from the client: a browser in Auckland and a browser in Lisbon see
//      the same "today", because the server says what today is.
//   2. Day N can be claimed ON DAY N ONLY. Its Paris date is the Nth of December
//      of the season. Before that date the day is LOCKED, after it MISSED. There
//      is no catch-up and no half-value fallback while the event runs - which is
//      why `stateOf()` has no "late" branch at all.
//   3. A day that is MISSED cannot be claimed by anyone during the event, and
//      the calendar does not even draw it as claimable.
//   4. After 24 December 23:59:59 Paris, a player who owns the Advent Pass may
//      claim the days they missed (and only until the end of 31 December - see
//      PASS_GRACE_LAST_DAY); everyone else is closed. Before 25 December the
//      Pass changes nothing at all.
//
// The page only ever DRAWS these verdicts; it never recomputes a date, and
// src/state.js enforces the same verdicts again at apply time.
import {
  parisParts, parisMidnight, isoWeekday,
  SEASON_YEAR, SEASON_LAST_DAY, PASS_REOPENS_FROM, PASS_GRACE_LAST_DAY
} from "../periods.js"

export const ADVENT_DAYS = 24

// The 24 daily rewards, EXACTLY the game's own calendar
// (game-server/.../configs/freenova/winterfest/advent.ini, the [advent] section
// winterfest_core.amxx pays from). snow = gingerbread here; ornament ids are
// [ornament] ids from ornaments.ini; gift = a present of that rarity; title = a
// [set] id. Never invent a day: an entry this file cannot parse is drawn as a
// mystery box, not as a reward the player will not get.
export const ADVENT_REWARDS = [
  { day: 1, type: "snow", id: 0, amount: 40 },
  { day: 2, type: "snow", id: 0, amount: 45 },
  { day: 3, type: "snow", id: 0, amount: 50 },
  { day: 4, type: "snow", id: 0, amount: 55 },
  { day: 5, type: "snow", id: 0, amount: 60 },
  { day: 6, type: "snow", id: 0, amount: 70 },
  { day: 7, type: "snow", id: 0, amount: 80 },
  { day: 8, type: "snow", id: 0, amount: 90 },
  { day: 9, type: "ornament", id: 1, amount: 0 },
  { day: 10, type: "snow", id: 0, amount: 100 },
  { day: 11, type: "ornament", id: 2, amount: 0 },
  { day: 12, type: "snow", id: 0, amount: 110 },
  { day: 13, type: "ornament", id: 6, amount: 0 },
  { day: 14, type: "snow", id: 0, amount: 130 },
  { day: 15, type: "ornament", id: 11, amount: 0 },
  { day: 16, type: "gift", id: 1, amount: 0 },
  { day: 17, type: "ornament", id: 16, amount: 0 },
  { day: 18, type: "snow", id: 0, amount: 180 },
  { day: 19, type: "ornament", id: 21, amount: 0 },
  { day: 20, type: "ornament", id: 3, amount: 0 },
  { day: 21, type: "gift", id: 2, amount: 0 },
  { day: 22, type: "ornament", id: 28, amount: 0 },
  { day: 23, type: "snow", id: 0, amount: 300 },
  { day: 24, type: "title", id: 6, amount: 0 }
]

// The names the page may print. ornaments.ini is the game's catalogue; these are
// the only strings this page owns, and they are the catalogue's own names.
export const ORNAMENT_NAMES = {
  1: "Crystal Snowflake", 2: "Frosted Snowflake", 3: "Silver Snowflake",
  6: "Jolly Santa", 11: "Grumpy Grinch", 16: "Tiny Sleigh",
  21: "Brass Bell", 28: "Star of the Season"
}
export const SET_NAMES = { 6: "Winterfest Legend" }
export const GIFT_NAMES = { 1: "Uncommon Present", 2: "Rare Present" }

const BY_DAY = new Map(ADVENT_REWARDS.map(r => [r.day, r]))
export function rewardForDay(day) { return BY_DAY.get(Number(day)) || null }

/** A one-line name for a day's reward, e.g. "80 GingerBread", "Crystal Snowflake". */
export function rewardLabel(r) {
  if (!r) return "Mystery Reward"
  if (r.type === "snow") return `${r.amount} GingerBread`
  if (r.type === "ornament") return ORNAMENT_NAMES[r.id] || `Ornament #${r.id}`
  if (r.type === "gift") return GIFT_NAMES[r.id] || "Mystery Reward"
  if (r.type === "title") return SET_NAMES[r.id] || "Winterfest Badge"
  return "Mystery Reward"
}

/**
 * The ledger/payload block for a day: what the PANEL pays when it applies the
 * claim, in the vocabulary src/state.js validates (snow -> gingerbread,
 * ornament -> item). The panel is the authority for these rewards (01-DATA.md
 * §Ownership), so the page names what it pays instead of the plugin.
 */
export function rewardBlock(day) {
  const r = rewardForDay(day)
  if (!r) return null
  // The ledger's reason is one of the documented kind vocabulary words; the
  // day itself is already the ledger's ref (`advent:9`).
  const out = { reason: "advent_day" }
  if (r.type === "snow") out.gingerbread = r.amount
  else if (r.type === "ornament") {
    out.item = `ornament:${r.id}`
    out.item_kind = "ornament"
    // The tree is what an ornament is FOR: an advent ornament arrives placed in
    // the first free slot, and placeOrnament() moves it out of the way if the
    // slot is taken. Without a slot an ornament would be inventory-only.
    out.slot = r.day
  } else if (r.type === "gift") {
    // A present has no item id the panel can name yet: the gift table is the
    // game's. Pay its documented snow value instead of queueing a phantom item.
    out.gingerbread = r.id === 2 ? 60 : 40
  } else if (r.type === "title") {
    out.item = `title:${r.id}`
    out.item_kind = "title"
  }
  return out
}

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

/** "Tuesday" from a Paris calendar date (the day stop of the walk). */
export function weekdayName(day, season) {
  const p = parisParts(dayStart(day, season))
  const wd = isoWeekday(p.y, p.m, p.d)
  return ["", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"][wd] || ""
}

/**
 * Where the calendar stands right now. `phase` drives every date rule:
 *   before - before 1 December Paris: nothing is claimable, nothing is missed
 *   during - 1..24 December: today's day is the only open one
 *   closed - 25..31 December: everybody is closed except a Pass owner (grace)
 *   ended  - from 1 January Paris: closed for everyone, pass or not
 */
export function adventClock(now, opts) {
  const sec = Math.floor(Number(now))
  const season = (opts && opts.season) || SEASON_YEAR
  const today = todayDate(sec)
  const start = parisMidnight(season, 12, 1)
  const lastDayStart = parisMidnight(season, 12, SEASON_LAST_DAY)
  const endExclusive = parisMidnight(season, 12, SEASON_LAST_DAY + 1)      // 25 Dec 00:00
  const graceEnd = parisMidnight(season, 12, PASS_GRACE_LAST_DAY + 1)      // 1 Jan 00:00

  let phase = "during"
  if (sec < start) phase = "before"
  else if (sec >= graceEnd) phase = "ended"
  else if (sec >= endExclusive) phase = "closed"
  // The grace window is 25-31 December and nothing else: where the event is over
  // for good, "the event is over" means over, for a Pass owner too.
  const grace = phase === "closed"

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
    grace,
    todayDay,
    start,
    lastDayStart,
    endExclusive,
    graceEnd,
    // The day the page centres on: today's day while the calendar runs, day 1
    // before it opens (the plate's own walk is a preview of the road ahead) and
    // day 24 once it is over.
    focusDay: todayDay || (phase === "before" ? 1 : ADVENT_DAYS)
  }
}

/**
 * The state of one day for one player:
 *   claimed - a row exists in winter_advent for it
 *   open    - it is today AND nothing else, or (after 24 Dec) it was missed AND
 *             the player owns the Advent Pass inside the grace window
 *   locked  - it is still in the future (or the calendar is over for them)
 *   missed  - its date has gone by and the player does not hold it
 */
export function stateOf(day, clock, claimedDays, hasPass) {
  const d = Number(day)
  if (claimedDays && claimedDays.has(d)) return "claimed"
  if (clock.phase === "before" || clock.phase === "ended") return "locked"
  if (clock.phase === "during") {
    if (d === clock.todayDay) return "open"
    return d > clock.todayDay ? "locked" : "missed"
  }
  // 25..31 December: the event is over. Only the Pass reopens what was missed.
  return hasPass ? "open" : "missed"
}

/** Can this day be claimed by this player, right now? (server verdict) */
export function claimable(day, clock, claimedDays, hasPass) {
  return stateOf(day, clock, claimedDays, hasPass) === "open"
}

/**
 * How many days exist yet. During the event only the started days are listed
 * (today and every earlier one): tomorrow is not the player's business yet, and
 * a missed day is shown as MISSED so the record is honest. Before it opens all
 * 24 appear as a preview; after it, all 24 again (the Pass owner needs them).
 */
export function visibleDays(clock) {
  if (clock.phase === "before") return 0
  if (clock.phase === "during") return clock.todayDay
  return ADVENT_DAYS
}

/** The next day this player can still claim, or 0. */
export function nextClaimable(clock, claimedDays, hasPass) {
  for (let d = 1; d <= ADVENT_DAYS; d++)
    if (stateOf(d, clock, claimedDays, hasPass) === "open") return d
  return 0
}

/** How many days have started (claimed + missed + today's open one). */
export function startedDays(clock) {
  if (clock.phase === "before") return 0
  if (clock.phase === "during") return clock.todayDay
  return ADVENT_DAYS
}

/** The whole calendar as the page draws it: one entry per day, in order. */
export function calendarRows(clock, claimedDays, hasPass) {
  const visible = visibleDays(clock)
  return ADVENT_REWARDS.map(r => {
    const state = stateOf(r.day, clock, claimedDays, hasPass)
    return {
      ...r,
      date: dayDate(r.day, clock.season),
      name: rewardLabel(r),
      state,
      shown: r.day <= visible,
      // What the drawer prints: a Pass owner sees every reward (the owner's
      // "reveal all mystery rewards" perk); everyone else sees a name only for a
      // day they hold or a day that is still theirs, and a box otherwise.
      revealed: hasPass || state === "open" || state === "claimed"
    }
  })
}

/**
 * The server-side claim check, in words a player can act on. Returns "" when the
 * claim may be queued. Called twice on purpose: once when the page queues the
 * action, and again inside the apply transaction (src/state.js), so a queue that
 * waited past midnight cannot pay a day that has since stopped being claimable.
 */
export function claimRefusal(day, clock, claimedDays, hasPass) {
  const d = Number(day)
  if (!Number.isInteger(d) || d < 1 || d > ADVENT_DAYS) return `there is no advent day ${day}`
  if (claimedDays && claimedDays.has(d)) return `day ${d} is already claimed`
  const state = stateOf(d, clock, claimedDays, hasPass)
  if (state === "open") return ""
  if (state === "claimed") return `day ${d} is already claimed`
  if (clock.phase === "before") return "the advent calendar opens on 1 December"
  if (clock.phase === "ended") return "Winterfest is over"
  if (state === "missed") {
    if (clock.phase === "closed")
      return `day ${d} was missed - after ${SEASON_LAST_DAY} December only the Advent Pass can claim it`
    return `day ${d} was missed - a missed day cannot be claimed`
  }
  return `day ${d} opens on ${dayDate(d, clock.season)}`
}

/**
 * Everything a caller needs to queue one claim: the reward block the panel pays,
 * the label the ledger records, and the refusal (empty when it is allowed).
 * `rows` is whatever claimRows() returned; a bare array of days is accepted too.
 */
export function prepareClaim(day, clock, claimed, hasPass) {
  const claimedDays = claimed instanceof Set ? claimed
    : new Set((claimed && claimed.days ? claimed.days : claimed || []).map(Number))
  const d = Number(day)
  const refusal = claimRefusal(d, clock, claimedDays, hasPass)
  if (refusal) return { ok: false, day: d, error: refusal, payload: null }
  const payload = rewardBlock(d)
  if (!payload) return { ok: false, day: d, error: `day ${d} has no reward on this calendar`, payload: null }
  return { ok: true, day: d, error: "", payload: { day: d, ...payload } }
}

export { isoWeekday, PASS_REOPENS_FROM, PASS_GRACE_LAST_DAY, SEASON_LAST_DAY }
