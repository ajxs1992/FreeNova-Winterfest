// FreeNova panel — the two shared primitives every transactional page needs.
//
// Neither of these is a layout. The contract (docs/panel/00-CONTRACT.md §1) says
// shared code is limited to data access, formatting and the action protocol, and
// this file is exactly that: the identity a POST has to carry, and the one way a
// page turns a queued / refused / paid row into text.
//
// WHY THERE IS NO SESSION
//   The panel has no player login. A page learns who it is from the signed MOTD
//   stamp (`url._fnMotdSid`, src/index.js) or from `?steamid=`, which a player can
//   type but cannot sign. So an action POST carries the identity in its BODY
//   (`s=<steamid>`), never in the URL: a URL with a steamid in it is a URL that
//   can be pasted into a chat and charged to somebody else.
//
// WHY A POST RENDERS THE WHOLE PAGE BACK
//   There is no client JavaScript doing the work: the form posts, the server
//   queues through queueAction() and re-renders the same layout with the row it
//   created. That is the "no page-level writes" rule taken literally — the only
//   writer on this path is queueAction().
import { Refusal } from "../state.js"

/** The steamid a POST is allowed to act for.
 *
 *  In a request body it must be an exact `STEAM_x:y:z`. From the MOTD stamp it is
 *  the signed value the router already validated. Anything else is "" — a page
 *  then renders read-only, which is the honest state, not an error page.
 */
export function sidFromBody(body, minted) {
  const raw = String((body && body.get("s")) || "").trim()
  if (/^STEAM_[0-9]:[0-9]:\d+$/.test(raw)) return raw
  const stamped = minted ? String(minted) : ""
  return /^STEAM_[0-9]:[0-9]:\d+$/.test(stamped) ? stamped : ""
}

/** A Refusal's reason, VERBATIM, or a stable fallback for a real crash.
 *
 *  The owner's rule: a page shows why the queue refused, in the queue's own words
 *  ("not enough gingerbread (have 75, need 9999)"), never a generic "error". Only
 *  a genuine throw gets the fallback, and the prefix says so plainly so nobody
 *  mistakes an engine fault for a policy refusal.
 */
export function refusalText(e) {
  if (e instanceof Refusal) return e.reason
  const msg = String((e && e.message) || e || "").trim()
  return msg ? `queue failed: ${msg}` : "queue failed: no reason given"
}

/** How an action row reads in a page's own words. State words only — a page
 *  formats its own sentence around them. */
export function actionState(row) {
  const state = String((row && row.state) || "pending")
  const acked = Number((row && row.game_acked_at) || 0) > 0
  if (state === "pending") return { key: "pending", label: "Queued", detail: "waiting for the game's next pull" }
  if (state === "refused") return { key: "refused", label: "Refused", detail: String((row && row.error) || "no reason given") }
  if (acked) return { key: "paid", label: "Paid", detail: "the game confirmed it" }
  return { key: "paid", label: "Paid", detail: "paid in the panel; the game has not reported back yet" }
}

/** "1 day ago" / "14:32" — the honest-sync clock, for a footer line. */
export function agoText(now, then) {
  const t = Math.trunc(Number(then) || 0)
  if (!t) return "never"
  const d = Math.max(0, Math.trunc(now - t))
  if (d < 60) return `${d}s ago`
  if (d < 3600) return `${Math.trunc(d / 60)}m ago`
  if (d < 86400) return `${Math.trunc(d / 3600)}h ${Math.trunc((d % 3600) / 60)}m ago`
  return `${Math.trunc(d / 86400)}d ago`
}
