// FreeNova panel — the Advent pages read here, and the one place a claim is
// QUEUED. Reads go through src/state.js getPlayer() + two queries of this
// module (the player's claimed days, and the season's own row if the game
// pushed one); nothing in this file touches a state table directly.
import { getPlayer, queueAction, ADVENT_PRODUCT } from "../state.js"
import { parisParts } from "../periods.js"
import {
  ADVENT_DAYS, ADVENT_REWARDS, adventClock, calendarRows, nextClaimable,
  startedDays, prepareClaim, rewardLabel, dayDate, weekdayName, PASS_GRACE_LAST_DAY
} from "./advent.js"

const SEASON_KEY = "season"

async function allOn(db, sql, params) {
  try {
    const res = await db.prepare(sql).bind(...(params || [])).all()
    return (res && res.results) || []
  } catch { return [] }
}

/** The days this player already holds this season, newest last. */
export async function claimedDays(db, steamid, season) {
  const rows = await allOn(db,
    `SELECT day, claimed_at FROM winter_advent WHERE steamid=?1 AND season=?2 ORDER BY day`,
    [steamid, String(season)])
  return rows.map(r => ({ day: Number(r.day), claimed_at: Number(r.claimed_at || 0) }))
}

/** The season row the game pushes (starts/ends in epoch seconds), if any. */
export async function seasonRow(db) {
  const rows = await allOn(db, `SELECT value FROM winter_meta WHERE key=?1`, [SEASON_KEY])
  if (!rows.length) return null
  try { return JSON.parse(rows[0].value || "{}") } catch { return null }
}

/**
 * Everything /panel/advent draws, in one object. `now` is the server clock; a
 * page that is asked at 23:59:59 Paris and one asked at 00:00:01 get different
 * answers, and both are the server's.
 */
export async function loadAdvent(env, sid, now) {
  const db = env.DB || null
  const clock = adventClock(now)
  let p = null, claims = []
  if (db && sid) {
    try { p = await getPlayer(db, sid) } catch { p = null }
    claims = await claimedDays(db, sid, clock.season)
  }
  const known = !!(p && p.exists)
  const hasPass = !!(p && (p.entitlements || []).includes(ADVENT_PRODUCT))
  const days = new Set(claims.map(c => c.day))
  const rows = calendarRows(clock, days, hasPass)
  const progress = {
    claimed: claims.length,
    started: startedDays(clock),
    total: ADVENT_DAYS,
    pct: startedDays(clock) ? Math.round((claims.length / startedDays(clock)) * 100) : 0
  }
  const next = nextClaimable(clock, days, hasPass)
  const finalDay = ADVENT_REWARDS[ADVENT_REWARDS.length - 1]
  return {
    sid, known, p, clock, claims, hasPass, rows, progress,
    next: next ? {
      day: next,
      date: dayDate(next, clock.season),
      name: rewardLabel(ADVENT_REWARDS[next - 1]),
      state: rows[next - 1] && rows[next - 1].state
    } : null,
    final: { ...finalDay, date: dayDate(finalDay.day, clock.season), name: rewardLabel(finalDay) },
    // The last day a Pass owner can still claim, in Paris words, for the card.
    graceEnd: `31 Dec`
  }
}

/**
 * Queue one claim for this player. The verdict is the SERVER's: the same
 * claimRefusal() the apply step runs, so a page can never queue a day that the
 * apply step would then refuse (and a second refusal is still possible if the
 * queue waits past midnight - that one is reported on the row).
 */
export async function requestClaim(env, sid, day, now) {
  if (!env.DB) return { ok: false, error: "no database" }
  if (!sid) return { ok: false, error: "no player" }
  let p
  try { p = await getPlayer(env.DB, sid) } catch { p = null }
  if (!p || !p.exists) return { ok: false, error: "no player" }
  const clock = adventClock(now)
  const claims = await claimedDays(env.DB, sid, clock.season)
  const hasPass = (p.entitlements || []).includes(ADVENT_PRODUCT)
  const prep = prepareClaim(day, clock, new Set(claims.map(c => c.day)), hasPass)
  if (!prep.ok) return { ok: false, error: prep.error }
  const res = await queueAction(env.DB, {
    steamid: sid, kind: "claim_advent", now,
    payload: { ...prep.payload, now }
  })
  return { ok: true, action: res.action, created: res.created }
}
