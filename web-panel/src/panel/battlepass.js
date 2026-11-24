// FreeNova panel — the Battle Pass page (page 5 of the Winterfest UI).
//
// The owner approved the plate web-panel/assets/battlepass-plate.png: that
// photograph IS the page. It paints every border, glow, snow cap and fairy light
// at its own 1672x941 size, and nothing here redraws one. The page only prints
// data into the holes the plate already has, each on clean CHROME cut from the
// same plate (a strip), so no sample glyph survives and no edge is covered.
//
// WHAT IS MEASURED, AND HOW (tools/design/prog_measure.py, docs/panel/05-BATTLEPASS.md)
//   The plate is painted, not laid out: its ten reward cells have no fixed pitch
//   (127, 125, 128, 128, 123, 138, 130, 133 px). So no page may compute a cell
//   from a count. Every rectangle below was read off the picture by
//   `prog_measure.py` (a column notch is the dip in brightness between two
//   cells; a row boundary is the step between two stacked cards), then checked by
//   eye on the PNG it draws, then pasted here as data. CRATE[i], TRACK_ROWS and
//   CARD_BOXES are that reading.
//
// ONE SCREEN, NEVER A SCROLL
//   A fixed 1672x941 stage, scaled as a whole by min(vw/1672, vh/941) capped at
//   1:1, letterboxed. Not a responsive reflow, and it must not become one: a
//   player never scrolls a reward track.
//
// THE CRATE COLUMN IS NOT A STRIP
//   The plate's crate column (x 306..471) holds the Free/Premium label cards. A
//   BATTLE PASS track is [crown][10 cells] on each of two rows: a label, then the
//   ten rewards of 1-15. The plate's crate column is therefore covered once with
//   a clean crop of the plate's own background, and the page's two crown cards
//   are printed on it — the crate's frame is kept, its snowman and its gift are
//   not part of a pass.
//
// DATA
//   getPlayer() (src/state.js) and src/query.js only. The ladder itself is the
//   game's pass.ini, published through the signed push into winter_pass_tier
//   (docs/panel/01-DATA.md §11); when nothing was published the page says so and
//   still draws the plate. A claim is queued through src/state.js queueAction()
//   and is shown as QUEUED — never as done, because the game is what pays.
import { getPlayer, queueAction, PASS_MAX_TIER, passTierXp, Refusal } from "../state.js"
import { passLadder, passRewards, recentActions } from "../query.js"
import { loadSchedule } from "../schedule.js"
import { parisParts, parisMidnight } from "../periods.js"
import { esc, fmt } from "../top15/render.js"
import { localTrustEnabled, mintActionToken } from "../sync.js"

export const PLATE_W = 1672, PLATE_H = 941
const PLATE_URL = "/battlepass-plate.png"

// ---------------------------------------------------------------- the plate --
// The reward cells, [x, cell top, w, cell bottom] of each cell's INTERIOR
// (inside its border): row 1 is the free track (1-15), row 2 the premium track
// (16-30). Ten cells per row, measured one by one — the pitch drifts from 127 to
// 133 px across a row, so `row width / 10` is wrong by six pixels at the end.
export const CRATE = [
  // free row, tiers 1..10
  { i: 0, x: 477, y: 469, w: 115, b: 565 },
  { i: 1, x: 601, y: 469, w: 117, b: 565 },
  { i: 2, x: 727, y: 469, w: 118, b: 565 },
  { i: 3, x: 853, y: 469, w: 118, b: 565 },
  { i: 4, x: 978, y: 469, w: 117, b: 565 },
  { i: 5, x: 1106, y: 469, w: 128, b: 565 },
  { i: 6, x: 1243, y: 469, w: 123, b: 565 },
  { i: 7, x: 1374, y: 469, w: 127, b: 565 },
  { i: 8, x: 1507, y: 469, w: 129, b: 565 },
  { i: 9, x: 1636, y: 469, w: 20, b: 565 },     // the frame's right edge (cells 18/19 of the plate)
  // premium row, tiers 11..20
  { i: 10, x: 477, y: 547, w: 115, b: 643 },
  { i: 11, x: 601, y: 547, w: 117, b: 643 },
  { i: 12, x: 727, y: 547, w: 118, b: 643 },
  { i: 13, x: 853, y: 547, w: 118, b: 643 },
  { i: 14, x: 978, y: 547, w: 117, b: 643 },
  { i: 15, x: 1106, y: 547, w: 128, b: 643 },
  { i: 16, x: 1243, y: 547, w: 123, b: 643 },
  { i: 17, x: 1374, y: 547, w: 127, b: 643 },
  { i: 18, x: 1507, y: 547, w: 129, b: 643 },
  { i: 19, x: 1636, y: 547, w: 20, b: 643 }
]
const CELL_BOTTOM = 565, PREM_BOTTOM = 643
// Where the page's own tier count goes: under each row of cells, on the plate's
// page background (which has no sample text there).
const NUM_FREE_Y = 452, NUM_PREM_Y = 655

// The two number lines above the cells, measured (first/last tier's own chip).
export const NUM_ROW = [
  { x: 483, y: 418, w: 121, h: 34 },
  { x: 607, y: 418, w: 121, h: 34 },
  { x: 732, y: 418, w: 123, h: 34 },
  { x: 857, y: 418, w: 122, h: 34 },
  { x: 982, y: 418, w: 124, h: 34 },
  { x: 1114, y: 418, w: 139, h: 34 },
  { x: 1249, y: 418, w: 130, h: 34 },
  { x: 1377, y: 418, w: 134, h: 34 },
  { x: 1511, y: 418, w: 136, h: 34 },
  { x: 1636, y: 418, w: 20, h: 34 }
]
// The plate's own paint for the three surfaces a strip has to reproduce, each
// read off the picture where it is flattest (colour <N>) — a 1x1 root the page
// stretches, so the strip is the plate's exact colour, not a re-drawn one:
//   panel  (5,20,51)   the page background every number chip sits on
//   free   (16,42,66)  an untouched free-track cell's blue
//   prem   (64,38,26)  an untouched premium-track cell's brown
//   button             the upsell card's grey button face (its copy prints on it)
export const PAINT = {
  panel: { srcX: 470, srcY: 410, w: 1, h: 1 },
  button: { srcX: 1620, srcY: 328, w: 1, h: 1 },   // the upsell card's gold button face
  card: { srcX: 720, srcY: 341, w: 1, h: 1 },       // the hero progress card's deep blue
  free: { srcX: 490, srcY: 470, w: 1, h: 1 },
  prem: { srcX: 1294, srcY: 554, w: 1, h: 1 }
}
// Where the page's own chips sit inside a cell: the watermark band.
export const CHIP_H = 22

// The two row bands as measured: the number/crown line above each row of cells,
// and the cells themselves. [name, x, y, w, h, srcX, srcY]
export const TRACK_ROWS = {
  numbersFree: { x: 477, y: 418, w: 1159, h: 48, srcX: 860, srcY: 388 },
  numbersPrem: { x: 477, y: 499, w: 1159, h: 46, srcX: 860, srcY: 499 },
  free: { x: 471, y: 463, w: 1165, h: 104, srcX: 800, srcY: 460 },
  prem: { x: 471, y: 542, w: 1165, h: 104, srcX: 800, srcY: 538 }
}

// The side column's crown cards (a clean crop of the plate's own side panel).
export const CROWN = {
  free: { x: 316, y: 392, w: 148, h: 214 },
  prem: { x: 316, y: 542, w: 148, h: 214 },
  srcX: 320, srcY: 392, srcW: 140, srcH: 214
}

// The three cards at the bottom, and the rows inside the first of them.
export const CARD_BOXES = [
  { x: 328, y: 715, w: 268, h: 205 },
  { x: 770, y: 715, w: 358, h: 205 },
  { x: 1236, y: 715, w: 408, h: 205 }
]
// The three progress rows inside the first card: [label x/y/w, bar x/y/w/h, pct x, pct w]
export const CARD_ROWS = [
  { label: { x: 342, y: 745, w: 220 }, bar: { x: 345, y: 794, w: 164, h: 6 }, pct: { x: 528, y: 744, w: 58 } },
  { label: { x: 342, y: 776, w: 220 }, bar: { x: 345, y: 842, w: 159, h: 8 }, pct: { x: 528, y: 775, w: 58 } },
  { label: { x: 342, y: 807, w: 220 }, bar: { x: 346, y: 891, w: 142, h: 8 }, pct: { x: 528, y: 806, w: 58 } }
]
// The plate's own bar trough: the darkest point of the row-1 track, which is
// what a full bar stretches to when a mission is further along than the sample.
export const BAR_TROUGH = { x: 509, y: 794, w: 3, h: 6, full: 559 }
export const BAR_GREEN = { x: 347, y: 794, w: 8, h: 6 }

// The hero's progress bar (Battle Pass Progress) and its XP reading.
export const HERO = {
  bar: { x: 503, y: 324, w: 240, h: 9 },
  trough: { x: 746, y: 324, w: 4, h: 9, full: 559 },
  green: { x: 512, y: 326, w: 8, h: 6 },
  xp: { x: 698, y: 344, w: 178, h: 20 },
  sample: { x: 694, y: 310, w: 146, h: 28 }
}

// The premium upsell card's button line and its copy.
export const UPSELL = {
  btn: { x: 1357, y: 300, w: 250, h: 34 },
  copy: { x: 1349, y: 284, w: 266, h: 14 }
}

// The pager (1-15 / 16-30) and the two arrows.
export const PAGER = {
  one: { x: 1000, y: 642, w: 106, h: 40 },
  two: { x: 1118, y: 642, w: 106, h: 40 }
}

// ------------------------------------------------------------------ styles --
const CSS = `
/*
  Font: Nunito, family 'Nunito', source github.com/google/fonts/ofl/nunito,
  licence OFL-1.1 (assets/fonts/OFL.txt is committed next to the file). One
  variable file, weights 200-1000, font-display:swap so a slow font never hides
  a number.
*/
@font-face{font-family:'Nunito';src:url('/assets/fonts/Nunito-Variable.ttf') format('truetype-variations');
  font-weight:200 1000;font-display:swap}
*{box-sizing:border-box}
html,body{margin:0;padding:0;width:100%;height:100%;background:#070a1c;overflow:hidden}
body{font-family:Nunito,'Trebuchet MS','Segoe UI',Cantarell,'Arial',sans-serif;-webkit-font-smoothing:antialiased}
/* ONE SCREEN: the fixed 1672x941 stage, scaled as a whole (the CSS line is the
   no-script fallback; the script below re-centres it and records data-scale). */
#stage{position:absolute;left:0;top:0;width:${PLATE_W}px;height:${PLATE_H}px;overflow:hidden;
  background:#070a1c;color:#fff;transform-origin:0 0;will-change:transform;
  scale:min(calc(100vw / ${PLATE_W}), calc(100vh / ${PLATE_H}), 1)}
#plate{position:absolute;left:0;top:0;width:${PLATE_W}px;height:${PLATE_H}px;
  background-image:url(${PLATE_URL});background-repeat:no-repeat;background-size:${PLATE_W}px ${PLATE_H}px}
/* a strip: a clean slice of the plate stretched over the field it covers */
.strip{position:absolute;background-image:url(${PLATE_URL});background-repeat:no-repeat;pointer-events:none}
/* a field: transparent, so the plate's own paint shows through it */
.fld{position:absolute;margin:0;padding:0;background:transparent;overflow:hidden}
.fld span{display:block;width:100%;height:100%;color:#fff;font-variant-numeric:tabular-nums;
  text-shadow:0 1px 2px rgba(0,0,0,.75);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.say{color:#cfd8f5}
.dim{color:#93a0c4}
.gold{color:#ffd66e}
.green{color:#7ef2a4}
/* the two tracks: numbers over each cell, the cell's own status chip under it */
.num{position:absolute;height:44px;line-height:44px;text-align:center;font-size:20px;font-weight:800;
  color:#e8eeff;text-shadow:0 1px 3px #000}
.num.now{color:#ffd66e}
.cell{position:absolute;overflow:hidden}
.chip{position:absolute;left:0;bottom:0;width:100%;height:22px;line-height:22px;text-align:center;
  font-size:11px;font-weight:800;letter-spacing:.02em;color:#fff;background:rgba(4,8,22,.62)}
.chip.got{background:rgba(18,120,64,.72);color:#d9ffe6}
.chip.now{background:rgba(160,112,8,.78);color:#fff3cf}
.chip.lock{background:rgba(10,14,32,.72);color:#c3cbe4}
.chip.off{background:rgba(60,10,10,.6);color:#ffd7d7}
/* the queue strip and the honest "nothing yet" line */
.note{position:absolute;font-size:13px;font-weight:700;text-shadow:0 1px 2px #000}
.q{display:inline-block;padding:0 8px;border-radius:8px;background:#7a5a12;color:#ffe9a8;
  font-size:12px;font-weight:800;line-height:20px}
.ok{background:#1f7a45;color:#e6fff0}
.btn{position:absolute;display:block;border:0;margin:0;padding:0;cursor:pointer;background:transparent;
  color:inherit;font:inherit;text-align:inherit}
.btn[disabled]{cursor:default}
`.trim()

// ----------------------------------------------------------------- helpers --
function num(v) { return typeof v === "number" && Number.isFinite(v) ? v : null }
const DASH = "—"

/** The season window, from the game's pushed row or the documented default
 *  (1 Dec 00:00 → 24 Dec 23:59 Europe/Paris — docs/panel/03-DASHBOARD.md §6.3). */
export function seasonWindow(metaRow, now) {
  let start = null, end = null
  if (metaRow && metaRow.value) {
    try {
      const s = JSON.parse(metaRow.value)
      const a = Number(s.start || s.start_at || s.starts_at || 0)
      const b = Number(s.end || s.end_at || s.ends_at || 0)
      if (a > 0) start = a
      if (b > 0) end = b
    } catch {}
  }
  const season = parisParts(now).y
  if (start == null) start = parisMidnight(season, 12, 1)
  if (end == null) end = parisMidnight(season, 12, 25) - 60
  return { start, end }
}

/** What one tier of the ladder IS, in words, from its own kind/amount/id. */
export function rewardText(t) {
  if (!t) return ""
  if (t.label) return t.label
  switch (t.kind) {
    case "snow": return fmt(t.amount) + " GingerBread"
    case "gift": return "Present (rarity " + t.item_id + ")"
    case "ornament": return "Ornament #" + t.item_id
    case "title": return "Collector title"
    case "pass": return fmt(t.amount) + " Pass XP"
    default: return String(t.kind || "")
  }
}

/** The state of one track cell for this player, and the word the page prints.
 *  `pass` is getPlayer().pass — the panel's own pass XP/tier (never a guess). */
export function cellState(tier, pass, premium, ladderHas) {
  const held = num(pass && pass.tier)
  if (!ladderHas) return { cls: "off", word: "no ladder" }
  if (held == null) return { cls: "lock", word: "locked" }
  if (tier <= held) return { cls: "got", word: "unlocked" }
  if (tier === held + 1) {
    // the next tier, and what it costs
    const need = num(pass && pass.needed) || 0
    return { cls: "now", word: need > 0 ? fmt(need) + " XP" : "next" }
  }
  return { cls: "lock", word: "locked" }
}

// ------------------------------------------------------------------ loader --
/** Everything the page prints, from a fixed number of queries. Nothing runs in
 *  a loop, and no DB (a static preview) is not an error: `db: false` makes the
 *  page say the ladder is unpublished instead of throwing on env.DB. */
export async function loadBattlepass(env, sid, now, url) {
  const hasDb = !!(env && env.DB)
  const schedule = hasDb ? await loadSchedule(env, now).catch(() => []) : []
  const seasonRow = hasDb
    ? await env.DB.prepare("SELECT value FROM winter_meta WHERE key='season'").first().catch(() => null)
    : null
  const window = seasonWindow(seasonRow, now)
  let p = null, ladder = [], earned = [], queue = []
  if (hasDb && sid) {
    try { p = await getPlayer(env.DB, sid) } catch { p = null }
    if (p && p.exists) {
      ladder = await passLadder(env.DB).catch(() => [])
      earned = await passRewards(env.DB, sid, { limit: 6 }).catch(() => [])
      queue = await recentActions(env.DB, sid, { limit: 40 }).catch(() => [])
    } else {
      ladder = await passLadder(env.DB).catch(() => [])
    }
  }
  // The claim link: the page may only carry one when the game minted it (?t=) or
  // this deployment is trusted to mint locally (sync.js localTrustEnabled).
  let token = url ? (url.searchParams.get("t") || "") : ""
  if (!token && sid && hasDb && localTrustEnabled(env)) token = await mintActionToken(env, sid)
  return {
    sid, known: !!(p && p.exists), p, ladder, earned, queue, token,
    window, now, active: (schedule || []).filter(e => e.state === "active")
  }
}

// ------------------------------------------------------------------- route --
export async function pageBattlepass(env, url) {
  const now = Math.floor(Date.now() / 1000)
  const minted = url && url._fnMotdSid
  const raw = (minted && String(minted)) || (url.searchParams.get("steamid") || "").trim()
  const sid = /^STEAM_[0-9]:[0-9]:\d+$/.test(raw) ? raw : ""
  const d = await loadBattlepass(env, sid, now, url)
  return new Response(renderBattlepass(d), {
    status: 200,
    headers: {
      "content-type": "text/html; charset=utf-8",
      "cache-control": "no-store",
      "x-content-type-options": "nosniff"
    }
  })
}

/** The claim form target. The page's own POST is the one writer; it goes through
 *  state.js queueAction(), which is validated and idempotent per (player, tier). */
export async function handleBattlepassPost(env, url, request) {
  const now = Math.floor(Date.now() / 1000)
  const raw = (url && url._fnMotdSid) || url.searchParams.get("steamid") || ""
  const sid = String(raw || "").trim()
  let form = {}
  try {
    const fd = await request.formData()
    for (const [k, v] of fd.entries()) form[k] = String(v)
  } catch { form = {} }
  if (!env || !env.DB) return redirect(url, "nodb")
  if (!/^STEAM_[0-9]:[0-9]:\d+$/.test(sid)) return redirect(url, "nosid")
  // The tick the player can cross: the tier they hold, plus one.
  let p = null
  try { p = await getPlayer(env.DB, sid) } catch { p = null }
  if (!p || !p.exists) return redirect(url, "noplayer")
  const tier = Number(form.tier || 0)
  const want = Math.min(PASS_MAX_TIER, Number(p.pass.tier || 1) + 1)
  if (!Number.isFinite(tier) || tier !== want) return redirect(url, "stale")
  let verdict = "ok"
  try {
    // Idempotent per player and tier: a double-click, a back button or a
    // replayed form queues ONE row (state.js defaultIdem → `pass:<tier>`).
    await queueAction(env.DB, {
      steamid: sid,
      kind: "claim_mission",
      idem: "pass:" + tier,
      payload: {
        mission: "pass_tier_" + tier,
        reason: "pass-tier-" + tier,
        // The pass pays its own XP: a claim moves the tier, it does not pay coins.
        pass_xp: Math.max(1, Math.min(5000, Math.round(passTierXp(tier) - passTierXp(Math.max(1, tier - 1)))))
      },
      now
    })
  } catch (e) {
    verdict = e instanceof Refusal ? "refused" : "error"
  }
  return redirect(url, verdict)
}

function redirect(url, verdict) {
  const target = new URL(url.toString())
  target.searchParams.delete("t")
  target.searchParams.set("queued", verdict)
  return new Response(null, {
    status: 303,
    headers: { location: target.pathname + "?" + target.searchParams.toString(), "cache-control": "no-store" }
  })
}

// ------------------------------------------------------------------ render --
/**
 * One page, one screen: the plate, the strips that clean it, the page's fields.
 *
 * Three rules hold for everything below, and a test checks each one:
 *   1. every element is inside the 1672x941 stage (the page never scrolls);
 *   2. every field's text box sits on a strip that is at least as big;
 *   3. no two text boxes overlap, so no value can print on another value.
 */
export function renderBattlepass(d) {
  const { known, p, ladder, queue, token } = d
  const pass = (p && p.pass) || {}
  const held = known ? num(pass.tier) : null
  const xp = known ? num(pass.xp) : null
  const nextXp = known ? num(pass.next_tier_xp) : null
  const maxXp = passTierXp(PASS_MAX_TIER)
  const hasLadder = Array.isArray(ladder) && ladder.length > 0
  const byTier = new Map((ladder || []).map(t => [Number(t.tier), t]))
  const none = "No player"
  const strips = []
  const fields = []
  const stacks = []

  // `paint` is the PAINT key this strip reproduces ("panel", "free", "prem").
  // A strip covers the plate's own sample with clean paint. `anchor` is the
  // FIELD it serves: the strip's background is centred on that field, not on the
  // wipe, so the field's text reads centred where the plate centred its sample.
  const strip = (name, paint, x, y, w, h, src, anchor) => {
    strips.push([name, paint, x, y, w, h, src, anchor])
  }
  /** A text box + the strip that cleans the plate's own sample under it. */
  // the strip is a minute wider than its own field, so its text is centred on
  // the field, not pushed off it by the wipe
  const field = (id, paint, box, text, css, spec) => {
    const [x, y, w, h] = box
    fields.push({ id, x, y, w, h, text, css: css || "" })
    const pad = (spec && spec.pad) || 2
    const sx = Math.max(0, x - pad), sy = Math.max(0, y - pad)
    const sw = Math.min(w + pad, PLATE_W - sx)          // the same pad each side
    const sh = Math.min(h + pad, PLATE_H - sy)
    strip("p_" + id, paint, sx, sy, sw, sh, null, { cx: x, cy: y, pad })
  }

  // ---- 1. the cells, on each row ------------------------------------------
  // No page text goes on the plate's number chips: they are the plate's sample
  // and two of them sit too close to their neighbours for a wipe. The cells
  // themselves are pure frame and art, so the page prints only their STATUS —
  // and a published tier's reward words, over the cell's watermark band.
  for (const [row, base] of [[0, 1], [10, 11]]) {
    for (let k = 0; k < 10; k++) {
      const tier = base + k
      const c = CRATE[row + k]
      const st = cellState(tier, pass, known, known && hasLadder)
      const t = byTier.get(tier)
      stacks.push(`<div class="chip ${st.cls}" style="left:${c.x}px;top:${c.b - CHIP_H - 8}px;width:${c.w}px;height:${CHIP_H}px">` +
        `${esc(known ? st.word : none)}</div>`)
      if (t && c.w > 60) {
        field((row ? "q" : "r") + k, row ? PAINT.prem : PAINT.free, [c.x + 4, c.b - CHIP_H - 34, c.w - 8, 18],
          rewardText(t), "font-size:11px;line-height:18px;font-weight:700;text-align:center;color:#fff3cf")
      }
    }
  }

  // ---- 1b. the page's own tier count, under each row of cells -------------
  // The plate's number chips are its sample and two of them cannot be wiped
  // without taking a neighbour, so the page says the same thing where the plate
  // has nothing: one line under each row, counting its own ten cells.
  field("ladder1", PAINT.panel, [CRATE[0].x, NUM_FREE_Y, CRATE[9].b - CRATE[0].x, 20],
    hasLadder ? "Tiers 1 – 10 on this page" : "Tier list not published",
    "font-size:12px;line-height:20px;font-weight:700;color:#a9b6dd")
  field("ladder2", PAINT.panel, [CRATE[10].x, NUM_PREM_Y, CRATE[9].b - CRATE[10].x, 20],
    hasLadder ? "Tiers 11 – 20 on this page" : "Tier list not published",
    "font-size:12px;line-height:20px;font-weight:700;color:#a9b6dd")

  // ---- 2. the hero: this player's pass XP and the bar into the next tier --
  const into = known ? Math.max(0, num(pass.into_tier) || 0) : 0
  const need = known ? Math.max(1, num(pass.needed) || 1) : 1
  const heroPct = held == null ? 0 : (held >= PASS_MAX_TIER ? 1 : Math.max(0, Math.min(1, into / need)))
  const heroW = Math.max(0, Math.round(HERO.bar.w * heroPct))
  // The plate prints "2,850 / 4,000 XP" at x 700-830 of its card, and the card
  // ends at x 884, so there is no room beside the sample: the page covers the
  // sample band with the card's own paint and prints its line UNDER the bar.
  strips.push(["hero_sample", PAINT.card, HERO.sample.x, HERO.sample.y, HERO.sample.w, HERO.sample.h])
  field("hero", PAINT.card, [HERO.xp.x, HERO.xp.y, HERO.xp.w, HERO.xp.h],
    known ? `${fmt(xp || 0)} / ${fmt(nextXp == null ? maxXp : nextXp)} XP` : none,
    `font-size:13px;line-height:${HERO.xp.h}px;font-weight:800;text-align:left`)
  strips.push(["hero_fill", PAINT.panel, HERO.green.x, HERO.green.y, Math.max(0, HERO.bar.x + heroW - HERO.green.x), HERO.green.h,
    { srcX: HERO.green.x, srcY: HERO.green.y, w: HERO.green.w, h: HERO.green.h }])
  strips.push(["hero_trough", PAINT.panel, HERO.bar.x + heroW, HERO.bar.y, HERO.bar.w - heroW, HERO.bar.h,
    { srcX: HERO.trough.x, srcY: HERO.trough.y, w: HERO.trough.w, h: HERO.trough.h }])

  // ---- 3. the label column: the plate's crate cards, relabelled ----------
  for (const [i, row] of [CROWN.free, CROWN.prem].entries()) {
    strips.push(["crown" + i, "plate", row.x, row.y, row.w, row.h,
      { srcX: CROWN.srcX, srcY: CROWN.srcY, w: CROWN.srcW, h: CROWN.srcH }])
  }
  field("lab_free", PAINT.panel, [CROWN.free.x + 12, CROWN.free.y + 146, CROWN.free.w - 24, 24],
    "Free track", "font-size:15px;line-height:24px;font-weight:800;text-align:center")
  field("lab_prem", PAINT.panel, [CROWN.prem.x + 12, CROWN.prem.y + 146, CROWN.prem.w - 24, 24],
    "Premium track", "font-size:15px;line-height:24px;font-weight:800;text-align:center")

  // ---- 5. the claim: the upsell card becomes the claim, never a fake buy --
  const claimable = known && !!token && held != null && held < PASS_MAX_TIER
  let claimBtn = ""
  if (claimable) {
    claimBtn = `<form method="post" action="/panel/battlepass">` +
      `<input type="hidden" name="tier" value="${held + 1}">` +
      `<button class="btn" type="submit" style="left:${UPSELL.btn.x}px;top:${UPSELL.btn.y}px;` +
      `width:${UPSELL.btn.w}px;height:${UPSELL.btn.h}px;font-size:15px;font-weight:800;text-align:center">` +
      `Claim tier ${held + 1}</button></form>`
  }
  const verdict = d.queued || ""
  const note = verdict === "ok" ? ["Queued — the game applies it on its next pull.", "green"]
    : verdict === "stale" ? ["That tier already moved.", "gold"]
    : verdict === "refused" ? ["The claim was refused by the panel.", ""]
    : verdict === "error" ? ["The claim could not be queued.", ""]
    : verdict ? ["Nothing was queued: " + verdict + ".", "say"]
    : [known ? (held != null && held >= PASS_MAX_TIER ? "Pass complete" : `Tier ${fmt(held || 1)} of ${PASS_MAX_TIER}`) : none, "say"]
  // The plate's upsell card prints "Premium Pass / Unlock 30 exclusive rewards!"
  // directly over the grey button, so its own sample is wiped by the button's
  // paint and the page's single line sits on it.
  const sub = hasLadder ? `${note[0]} · ${ladder.length} tiers` : note[0]
  field("up1", PAINT.button, [UPSELL.copy.x, UPSELL.copy.y, UPSELL.copy.w, UPSELL.copy.h], sub,
    `font-size:13.5px;line-height:${UPSELL.copy.h}px;font-weight:800;text-align:center;color:${note[1] === "green" ? "#7ef2a4" : note[1] === "gold" ? "#ffd66e" : "#e3e9fb"}`)

  // ---- 6. the three cards at the bottom ----------------------------------
  const claims = (queue || []).filter(a => String(a.kind || "") === "claim_mission"
    && String((a.payload && a.payload.mission) || "").startsWith("pass_tier_"))
  const queuedCount = claims.filter(a => a.state === "pending").length
  // Card 1 is THIS player's last three pass claims, newest first — every box is
  // a fully covered wipe of the plate's own sample rows, so no "Play 10 matches"
  // (the plate's sample) can ever survive next to the player's real data.
  CARD_ROWS.forEach((r, i) => {
    const a = claims[i]
    const label = a ? `Tier ${String(a.idem || "").replace("pass:", "")} — ${a.state}` : ""
    const when = a && a.created_at ? new Date(a.created_at * 1000).toISOString().slice(5, 10) : ""
    if (a) {
      field("cl" + i, PAINT.panel, [r.label.x, r.label.y - 1, r.label.w + 8, 18], label,
        "font-size:12.5px;line-height:18px;font-weight:700")
      field("cp" + i, PAINT.panel, [r.pct.x - 4, r.pct.y - 1, r.pct.w + 6, 18], when || DASH,
        "font-size:12px;line-height:18px;font-weight:800;text-align:right;color:#93a0c4")
    }
    // the bar: the plate's trough, and the green the page fills it with
    strip("t" + i, PAINT.panel, r.bar.x - 2, r.bar.y - 2, r.bar.w + 6, r.bar.h + 4,
      { srcX: BAR_TROUGH.x, srcY: BAR_TROUGH.y, w: BAR_TROUGH.w, h: BAR_TROUGH.h })
    const fill = a ? (a.state === "applied" ? r.bar.w : a.state === "pending" ? Math.round(r.bar.w * 0.5) : 0) : 0
    if (fill > 0) strip("g" + i, PAINT.panel, r.bar.x, r.bar.y, fill, r.bar.h,
      { srcX: BAR_GREEN.x, srcY: BAR_GREEN.y, w: BAR_GREEN.w, h: BAR_GREEN.h })
  })
  // the card's own heading area: what this card is about, in the player's terms
  field("c0", PAINT.panel, [CARD_BOXES[0].x + 10, CARD_BOXES[0].y + 4, 200, 16],
    known ? (claims.length ? `Your last ${claims.length} pass claim${claims.length === 1 ? "" : "s"}` : "No pass claim yet") : none,
    "font-size:11px;line-height:16px;font-weight:700;color:#a9b6dd")
  const prem = (ladder || []).filter(t => Number(t.tier) % 3 === 0).slice(0, 4)
  // Card 2 keeps the plate's own benefit checklist frame; its heading line is
  // the only text the page puts there, because the checklist IS the ladder.
  field("c1a", PAINT.panel, [CARD_BOXES[1].x + 10, CARD_BOXES[1].y + 4, CARD_BOXES[1].w - 20, 16],
    hasLadder ? `Every third tier pays · ${ladder.length} tiers` : "The tier list has not been published yet",
    "font-size:11px;line-height:16px;font-weight:700;color:#a9b6dd")
  field("c2a", PAINT.panel, [CARD_BOXES[2].x + 10, CARD_BOXES[2].y + 4, CARD_BOXES[2].w - 20, 16],
    known ? `Pass XP ${fmt(xp || 0)} of ${fmt(maxXp)}` : none,
    "font-size:11px;line-height:16px;font-weight:800;text-align:center;color:#a9b6dd")
  field("c2b", PAINT.panel, [CARD_BOXES[2].x + 10, CARD_BOXES[2].y + 22, CARD_BOXES[2].w - 20, 20],
    held != null ? `Tier ${fmt(held)} of ${PASS_MAX_TIER}` : DASH,
    "font-size:15px;line-height:22px;font-weight:800;text-align:center;color:#ffd66e")

  // ---- the markup --------------------------------------------------------
  const stripNodes = strips.map(([name, kind, x, y, w, h, src, anchor]) => {
    if (w <= 0 || h <= 0) return ""
    const s = typeof kind === "string" ? (kind === "plate" ? src : PAINT[kind]) : kind
    if (!s) throw new Error("battlepass: strip " + name + " has no paint")
    // anchor: the field's box, so the plate's paint lands centred under its text
    const pos = anchor
      ? `${anchor.cx - x}px ${-s.srcY}px`
      : `${-s.srcX}px ${-s.srcY}px`
    const size = anchor ? `${s.w}px ${s.h}px` : `${s.w}px ${s.h}px`
    return `<div class="strip" style="left:${x}px;top:${y}px;width:${w}px;height:${h}px;` +
      `background-position:${pos};background-size:${size}"></div>`
  }).join("")
  const fieldNodes = fields.map(f => `<div class="fld" id="${f.id}" style="left:${f.x}px;top:${f.y}px;` +
    `width:${f.w}px;height:${f.h}px"><span style="${f.css}">${f.text}</span></div>`).join("")

  const stage = `
<div id="stage" data-scale="1">
  <div id="plate"></div>
  ${stripNodes}
  ${fieldNodes}
  ${stacks.join("")}
  ${claimBtn}
</div>`

  return `<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>FreeNova · Winterfest battle pass</title>
<style>${CSS}</style></head>
<body>${stage}
<script>
(function(){
  // ONE SCREEN. Nothing here reads or writes data: the server printed every
  // value, and this only centres the fixed stage and records what it did, so a
  // test can assert "no scrollbars" without a browser.
  var st=document.getElementById('stage');if(!st)return;
  var fit=function(){
    var vw=window.innerWidth,vh=window.innerHeight;
    var s=Math.min(vw/${PLATE_W},vh/${PLATE_H},1);
    st.style.transform='translate('+((vw-${PLATE_W}*s)/2)+'px,'+((vh-${PLATE_H}*s)/2)+'px) scale('+s+')';
    st.style.scale='1';
    st.setAttribute('data-scale',s.toFixed(4));
    st.setAttribute('data-noscroll', String(
      document.documentElement.scrollWidth<=window.innerWidth &&
      document.documentElement.scrollHeight<=window.innerHeight));
  };
  fit();window.addEventListener('resize',fit);
})();
</scr` + `ipt>
</body></html>`
}

/** The geometry a test asserts: every field inside the stage, every field on a
 *  strip big enough for it, no two fields overlapping. Pure, so it runs without
 *  a browser and without the DOM. */
export function battlepassGeometry(doc) {
  const grab = (re) => [...doc.matchAll(re)].map(m => m)
  const fields = grab(/<div class="fld" id="([^"]+)" style="left:([-\d.]+)px;top:([-\d.]+)px;width:([-\d.]+)px;height:([-\d.]+)px"/g)
    .map(m => ({ id: m[1], x: +m[2], y: +m[3], w: +m[4], h: +m[5] }))
  const strips = grab(/<div class="strip" style="left:([-\d.]+)px;top:([-\d.]+)px;width:([-\d.]+)px;height:([-\d.]+)px"/g)
    .map(m => ({ x: +m[1], y: +m[2], w: +m[3], h: +m[4] }))
  const inside = (b) => b.x >= 0 && b.y >= 0 && b.x + b.w <= PLATE_W && b.y + b.h <= PLATE_H
  const covers = (o, i) => o.x <= i.x && o.y <= i.y && o.x + o.w >= i.x + i.w && o.y + o.h >= i.y + i.h
  const hit = (a, b) => a.x < b.x + b.w && b.x < a.x + a.w && a.y < b.y + b.h && b.y < a.y + a.h
  const out = fields.filter(f => !inside(f))
  const bare = fields.filter(f => !strips.some(s => covers(s, f)))
  const clash = []
  for (let i = 0; i < fields.length; i++)
    for (let j = i + 1; j < fields.length; j++)
      if (hit(fields[i], fields[j])) clash.push(fields[i].id + "/" + fields[j].id)
  return { fields: fields.length, strips: strips.length, out, bare, clash }
}
