// The panel's clock, in one place.
//
// A page draws dates that the STATE LAYER will then check again
// (src/panel/advent.js: "day N is the Nth of December Paris, claimable on that
// date only"), so the two must not be able to disagree by a second. The process
// clock is the default; WF_NOW freezes it for a local run or a test, which is how
// the frozen-clock cases (1 Dec, 10 Dec, 24 Dec 23:59:59, 25 Dec) are proven
// against the real route instead of against a copy of it.
//
//   WF_NOW=2026-12-10T12:00:00Z   an ISO instant
//   WF_NOW=2026-12-10             that date at 00:00 Europe/Paris
//   WF_NOW=1796900000             epoch seconds
import { parisMidnight } from "../periods.js"

export function envNow(env) {
  const raw = String((env && env.WF_NOW) || "").trim()
  if (!raw) return Math.floor(Date.now() / 1000)
  if (/^\d{9,}$/.test(raw)) return Number(raw)
  const dateOnly = /^(\d{4})-(\d{2})-(\d{2})$/.exec(raw)
  if (dateOnly) {
    // A Paris midnight written as a date: reuse the panel's own conversion so a
    // frozen date means the same thing as an event's start date.
    const [, y, m, d] = dateOnly
    return parisMidnight(Number(y), Number(m), Number(d))
  }
  const t = Date.parse(raw)
  return Number.isFinite(t) ? Math.floor(t / 1000) : Math.floor(Date.now() / 1000)
}

/**
 * Parse a date and a time of day in Paris: "2026-12-10" + "23:59:59" ->
 * epoch seconds. Used by the frozen-clock tests, and by anything that wants to
 * speak in Paris wall-clock words.
 */
export function parisAt(dateIso, timeIso) {
  const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(String(dateIso || ""))
  if (!m) return null
  const t = /^(\d{2}):(\d{2})(?::(\d{2}))?$/.exec(String(timeIso || "00:00:00"))
  if (!t) return null
  const midnight = parisMidnight(Number(m[1]), Number(m[2]), Number(m[3]))
  return midnight + Number(t[1]) * 3600 + Number(t[2]) * 60 + Number(t[3] || 0)
}
