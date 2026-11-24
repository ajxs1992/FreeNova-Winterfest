// FreeNova panel — the Winterfest dashboard (page 1 of the Winterfest UI).
//
// The owner approved this look: the plate, web-panel/assets/dashboard.png
// (1672x941). This page keeps it — the plate photograph IS the chrome and the
// page never redraws it — and only the data is drawn as text.
//
// HOW THE PAGE IS BUILT (one rule, no exceptions)
//   #plate paints the plate ONCE, whole, at its own size. Every value then goes
//   into a FIELD: a marked area on a panel, painted with clean CHROME cut from
//   the plate itself — either a strip of that same panel (a slice with no
//   sample glyph in it, stretched over the field) or a clean pane of the same
//   surface — with the page's text on it. The plate's borders, glows, fairy
//   lights and gradients stay whole, because a field is inset inside them.
//
// WHAT IS NOT A FIELD
//   Nothing above: the page has no opaque pads and no re-drawn chrome.
//   The event row (y >= 704) is the one place the plate is not used directly:
//   its cards carry art under their own titles and two glyphs of the heading sit
//   on the Grinch, so the row is a uniform crop of the plate's background
//   (ROW_BG) with the page's four cards on it. No sample title is ever shown.
//
// ONE SCREEN, NEVER A SCROLL
//   A FIXED 1672x941 stage, scaled as a whole by min(vw/1672, vh/941) (capped
//   at 1:1) and letterboxed. Not a responsive reflow, and must not become one:
//   a player must never scroll a dashboard. A CSS `scale:` line carries the same
//   formula for a no-script client.
//
// DATA
//   getPlayer() (src/state.js) and src/query.js only — never ad-hoc SQL in this
//   file. A missing player says "No player"; a counter the panel does not have
//   prints an em dash, never a 0 pretending to be data.
import { getPlayer } from "../state.js"
import { recentLedger, treeSlots, missionsFor } from "../query.js"
import { loadSchedule } from "../schedule.js"
import { parisParts, parisMidnight } from "../periods.js"
import { esc, fmt } from "../top15/render.js"

export const PLATE_W = 1672, PLATE_H = 941

// ------------------------------------------------------------- chrome ------
// A TILE: a clean stripe of plate chrome that a field repaints itself with.
//   [name, srcX, srcY, srcW, srcH, x, y, w, h]
// The stripe is srcX..srcW at srcY, srcH inside a panel; the field it covers is
// x, y, w, h. The stripe lies on plain surface with no sample glyph and runs
// the panel's full inner height, so the repeated copy carries the panel's own
// vertical gradient with it.
export const STRIPS = [
  // currency chips: the clear band between the icon and the "+" button, over the
  // chip's full inner height (the frame itself is never covered)
  ["s_chip1", 420, 22, 72, 50, 418, 20, 190, 50],
  ["s_chip2", 662, 22, 72, 50, 660, 20, 170, 50],
  ["s_chip3", 930, 22, 52, 50, 928, 20, 66, 50],
  ["s_chip4", 1152, 22, 72, 50, 1150, 20, 76, 50],
  ["s_profile", 1640, 22, 20, 44, 1512, 22, 136, 44],
  // the countdown panel's clear band, over its label and its four numerals
  ["s_cd", 774, 326, 24, 14, 872, 264, 196, 24],
  ["s_cd_num", 774, 326, 24, 14, 806, 300, 326, 34],
  // capsules: each one's empty right end under its title and its figure
  ["s_tree", 760, 386, 30, 48, 338, 383, 394, 52],
  ["s_pass", 1024, 386, 30, 48, 986, 383, 264, 52],
  ["s_adv", 1284, 386, 30, 48, 1250, 383, 370, 52],
  ["s_mis", 1526, 386, 30, 48, 1492, 383, 174, 52],
  ["s_evt", 1622, 386, 30, 48, 1620, 383, 46, 52],
  // the capsules row as one course: a clean stretch of its panel, wide enough
  // for every capsule's title and figure (checked before the per-capsule tiles)
  ["s_caps", 1160, 386, 30, 48, 450, 383, 1216, 52],
  // the card heading AND its caption, as one band: a clean stretch of each
  // card's surface stretched over the whole heading area
  ["s_band1", 1000, 560, 30, 16, 404, 478, 344, 60],
  ["s_band2", 1000, 560, 30, 16, 854, 478, 330, 60],
  ["s_band3", 700, 560, 30, 16, 1294, 478, 220, 60],
  // the four progress rows: the card's empty middle between icon and bar
  ["s_rows", 1090, 546, 30, 16, 866, 532, 206, 136],
  // the tree art, slotted exactly where the plate's card had it
  ["s_treeart", 308, 461, 328, 289, 313, 596, 328, 252],
  // the tree progress line
  ["s_tprog", 760, 532, 40, 20, 520, 536, 250, 44]
]

// Text boxes: where the page's value is printed. [id, x, y, w, h, tint]
// The COVER for each id is its strip in STRIPS above; a cover is always at least
// as big as this box, so no plate glyph can poke out around the text.
export const FIELD_TEXT = [
  ["f_coins", 431, 22, 104, 26, "white"],
  ["f_coins_l", 431, 50, 62, 18, "white"],
  ["f_gb", 664, 22, 104, 26, "white"],
  ["f_gb_l", 664, 50, 96, 18, "white"],
  ["f_spins", 934, 22, 40, 26, "white"],
  ["f_spins_l", 934, 50, 38, 18, "white"],
  ["f_miss", 1156, 25, 40, 24, "white"],
  ["f_miss_l", 1156, 50, 52, 16, "white"],
  ["f_who", 1512, 22, 136, 20, "white"],
  ["f_lvl", 1512, 46, 70, 18, "white"],
  ["f_cd_lbl", 872, 270, 196, 18, "white"],
  ["f_cd_1", 806, 302, 40, 30, "white"],
  ["f_cd_2", 902, 302, 40, 30, "white"],
  ["f_cd_3", 996, 302, 40, 30, "white"],
  ["f_cd_4", 1092, 302, 40, 30, "white"],
  ["f_cap_tree", 472, 388, 104, 18, "white"],
  ["f_cap_tree_v", 472, 414, 44, 18, "green"],
  ["f_cap_pass", 720, 388, 104, 18, "white"],
  ["f_cap_pass_v", 720, 414, 60, 18, "gold"],
  ["f_cap_adv", 968, 388, 104, 18, "white"],
  ["f_cap_adv_v", 968, 414, 100, 18, "gold"],
  ["f_cap_mis", 1218, 388, 104, 18, "white"],
  ["f_cap_mis_v", 1218, 414, 60, 18, "gold"],
  ["f_cap_evt", 1472, 388, 76, 18, "white"],
  ["f_cap_evt_v", 1472, 414, 76, 18, "gold"],
  ["f_tree_hd", 408, 482, 196, 20, "white"],
  ["f_tree_sub", 408, 506, 300, 18, "white"],
  ["f_tree_lbl", 526, 541, 112, 20, "white"],
  ["f_tree_pct", 690, 539, 62, 26, "green"],
  ["f_prog_hd", 857, 482, 150, 20, "white"],
  ["f_prog_sub", 857, 506, 300, 18, "white"],
  ["f_rew_hd", 1298, 482, 160, 20, "white"],
  ["f_rew_sub", 1298, 506, 190, 18, "white"],
  ["f_row1_l", 872, 535, 140, 16, "white"],
  ["f_row1_v", 1128, 535, 52, 16, "white"],
  ["f_row2_l", 872, 575, 150, 16, "white"],
  ["f_row2_v", 1128, 575, 52, 16, "white"],
  ["f_row3_l", 872, 617, 150, 16, "white"],
  ["f_row3_v", 1128, 617, 52, 16, "white"],
  ["f_row4_l", 872, 659, 150, 16, "white"],
  ["f_row4_v", 1128, 659, 52, 16, "white"]
]

// Type inside the fields: [id, font-px, weight, align]. Sizes are the plate's
// own glyph heights, read off the OCR boxes (docs/panel/03-DASHBOARD.md §6).
export const FONT_RULES = [
  ["f_coins", 20, 700, "left"], ["f_coins_l", 15, 600, "left"],
  ["f_gb", 20, 700, "left"], ["f_gb_l", 13.5, 600, "left"],
  ["f_spins", 20, 700, "left"], ["f_spins_l", 13.5, 600, "left"],
  ["f_miss", 20, 700, "left"], ["f_miss_l", 13, 600, "left"],
  ["f_who", 14.5, 600, "left"], ["f_lvl", 12, 600, "left"],
  ["f_cd_lbl", 18, 700, "left"],
  ["f_cd_1", 22, 700, "center"], ["f_cd_2", 22, 700, "center"],
  ["f_cd_3", 22, 700, "center"], ["f_cd_4", 22, 700, "center"],
  ["f_card_hd", 15.5, 800, "left"], ["f_card_cap", 10.5, 600, "left"],
  ["f_prog_hd2", 15, 600, "left"], ["f_prog_cap2", 10.5, 400, "left"],
  ["f_rew_hd3", 14, 600, "left"], ["f_rew_cap3", 10.5, 400, "left"],
  ["f_cap_tree", 15, 600, "left"], ["f_cap_tree_v", 14, 700, "left"],
  ["f_cap_pass", 13.5, 600, "left"], ["f_cap_pass_v", 13, 700, "left"],
  ["f_cap_adv", 13.5, 600, "left"], ["f_cap_adv_v", 13, 700, "left"],
  ["f_cap_mis", 13.5, 600, "left"], ["f_cap_mis_v", 13, 700, "left"],
  ["f_cap_evt", 13.5, 600, "left"], ["f_cap_evt_v", 13, 700, "left"],
  ["f_card_hd", 15.5, 800, "left"], ["f_card_cap", 10.5, 600, "left"],
  ["f_prog_hd2", 15, 600, "left"], ["f_prog_cap2", 10.5, 400, "left"],
  ["f_rew_hd3", 14, 600, "left"], ["f_rew_cap3", 10.5, 400, "left"],
  ["f_tree_hd", 15.5, 800, "left"], ["f_tree_sub", 10.5, 600, "left"],
  ["f_tree_lbl", 13.5, 700, "left"], ["f_tree_pct", 19, 700, "left"],
  ["f_prog_hd", 15, 600, "left"], ["f_prog_sub", 10.5, 400, "left"],
  ["f_rew_hd", 14, 600, "left"], ["f_rew_sub", 10.5, 400, "left"],
  ["f_row1_l", 11, 700, "left"], ["f_row1_v", 11, 700, "right"],
  ["f_row2_l", 11, 700, "left"], ["f_row2_v", 11, 700, "right"],
  ["f_row3_l", 11, 700, "left"], ["f_row3_v", 11, 700, "right"],
  ["f_row4_l", 11, 700, "left"], ["f_row4_v", 11, 700, "right"]
]

// Where the four event cards sit when the row is rebuilt, and the plate's own
// background crop that row is painted with (a clean rectangle of plate sky).
export const EVENTS_POS = [
  { x: 456, y: 786, w: 250 },
  { x: 772, y: 786, w: 240 },
  { x: 1064, y: 786, w: 250 },
  { x: 1428, y: 786, w: 240 }
]
export const ROW_BG = { x: 1100, y: 730, w: 100, h: 60, x0: 306, y0: 704, x1: 1666, y1: 936 }

// ------------------------------------------------------------------ styles --
const CSS = `
/* Nunito: the plate's face. Family Nunito, source github.com/google/fonts/ofl/nunito,
   licence OFL-1.1 (assets/fonts/OFL.txt sits next to the font). One variable
   file, weights 200-1000; font-display:swap so a slow font never hides a number. */
@font-face{font-family:'Nunito';src:url('/assets/fonts/Nunito-Variable.ttf') format('truetype-variations');
  font-weight:200 1000;font-display:swap}
*{box-sizing:border-box}
html,body{margin:0;padding:0;width:100%;height:100%;background:#0d0b18;overflow:hidden}
body{font-family:Nunito,'Trebuchet MS','Segoe UI',Cantarell,'Arial',sans-serif;-webkit-font-smoothing:antialiased}
#stage{position:absolute;left:0;top:0;width:${PLATE_W}px;height:${PLATE_H}px;background:#0d0b18;
  overflow:hidden;will-change:transform;transform-origin:0 0;color:#fff;
  scale:min(calc(100vw / ${PLATE_W}), calc(100vh / ${PLATE_H}), 1)}
/* EXPLICIT PAINT ORDER (the same order the markup is written in, so a page never
   depends on which elements happen to be positioned): the plate, then the
   chrome strips that cover its sample glyphs, then the fields' text. Anything
   stacked without a z-index would come out in DOM order; saying it here keeps a
   strip under a field even if a future edit moves the nodes. */
#plate{position:absolute;left:0;top:0;z-index:0;width:${PLATE_W}px;height:${PLATE_H}px;
  background-image:url(/dashboard.png);background-repeat:no-repeat;background-size:${PLATE_W}px ${PLATE_H}px}
/* A field is transparent: whatever chrome shows through it is what the page
   keeps. The plate itself paints no text (the glyphs on the PLATE are covered
   by COVERS below, and they are covered before any field's own text is drawn).
   The strips are those covers: each one a clean slice of its own panel. */
/* isolation:isolate — a strip's own stacking context, so nothing a cover contains
   (a field that overlaps it) can ever rise above the cover itself.
   image-rendering:pixelated — the tiles are copied plate pixels drawn 1:1;
   smooth resampling would put a half-transparent ghost of the sample glyph on
   top of the real one. */
.strip{position:absolute;z-index:1;isolation:isolate;image-rendering:pixelated;
  background-image:url(/dashboard.png);background-repeat:no-repeat}
${STRIPS.map(([n, sx, sy, sw, sh]) =>
  `.st-${n}{--tile:url(/dashboard.png);--tsz:${sw}px ${sh}px;--tpos:${-sx}px ${-sy}px;` +
  `--tpos-y:${-sy}px}`).join("\n")}
/* A field paints its own cover: a stripe of its own panel (a .st-<name> class
   sets --tile/--tsz/--tpos), repeated across the box, with a small overhang so
   nothing the plate drew at the edges of the text can peek out. The text box
   is inset 2px from that paint box. The gradient keeps the tile inside the
   vertical band only, so the chrome above and below a single-line field (a
   chip's rounded frame, a capsule's rim) is still the plate's own.
   The cover never depends on a sibling's width: the earlier sprite design did,
   and anywhere its slice was narrower than the field the plate's sample glyph
   and its shadow showed through. */
.fld{position:absolute;z-index:2;box-sizing:border-box;padding:2px 4px;margin:0;
  background-image:linear-gradient(var(--tile),var(--tile)),linear-gradient(var(--bg,#0d0b18),var(--bg,#0d0b18));
  background-size:var(--tsz),100% 100%;background-position:var(--tpos),0 0;
  /* the tile stays a stripe: outside the field's text band the panel's own
     surface paints, so a chip's frame and a capsule's rim stay the plate's */
  background-position-y:calc(var(--tpos-y) - var(--pad-y)),0;
  background-repeat:repeat,no-repeat;background-clip:content-box,padding-box;
  image-rendering:pixelated}
${FIELD_TEXT.map(([id, x, y, w, h]) => `#${id}{left:${x - 4}px;top:${y - 2}px;width:${w + 8}px;height:${h + 4}px}`).join("\n")}
${FIELD_TEXT.map(([id, x, y, w, h]) => `#${id}{--pad-y:${y - 2}px;--pad-h:${h + 4}px}`).join("\n")}
/* the printed text: the plate's own look — white, tabular, with the plate's
   soft drop shadow; a tint is a filter, never a second colour */
.fld span{display:block;width:100%;height:100%;font-variant-numeric:tabular-nums;
  text-shadow:0 1px 2px rgba(0,0,0,.75);letter-spacing:0;color:#fff}
.fld span.blank{visibility:hidden}
${FONT_RULES.map(([id, fs, wt, al]) => `#${id} span{font-size:${fs}px;line-height:${fs * 1.25}px;font-weight:${wt};text-align:${al}}`).join("\n")}
.tone-green{filter:brightness(1.34) sepia(1) hue-rotate(78deg) saturate(2.1) brightness(1.12)}
.tone-gold{filter:brightness(1.33) sepia(1) saturate(5) hue-rotate(3deg) brightness(1.02)}
#row_bg{position:absolute;left:${ROW_BG.x0}px;top:${ROW_BG.y0}px;width:${ROW_BG.x1 - ROW_BG.x0}px;` +
  `height:${ROW_BG.y1 - ROW_BG.y0}px;background-image:url(/dashboard.png);background-repeat:no-repeat;` +
  `background-position:-${ROW_BG.x}px -${ROW_BG.y}px;background-size:${ROW_BG.w}px ${ROW_BG.h}px}
#act_hd{position:absolute;left:372px;top:734px;width:300px;height:20px;font-size:16px;line-height:20px;
  font-weight:800;color:#fff;text-shadow:0 1px 2px #000}
.rw{position:absolute;top:646px;width:100px;text-align:center;color:#fff;text-shadow:0 1px 2px #000}
.rw b{display:block;font-size:11px;line-height:14px;font-weight:800}
.rw i{display:block;font-style:normal;font-size:9px;line-height:11px;font-weight:700;color:#cfd6ea}
.ev{position:absolute;overflow:hidden}
.ev b{display:block;font-size:15px;line-height:20px;font-weight:800;color:#fff;
  white-space:nowrap;overflow:hidden;text-overflow:ellipsis;text-shadow:0 1px 2px #000}
.ev span{display:block;margin-top:2px;height:32px;overflow:hidden;font-size:11.5px;line-height:16px;
  font-weight:600;color:#e6eaf4;text-shadow:0 1px 2px #000}
.ev em{display:inline-block;margin-top:4px;font-style:normal;font-size:11.5px;line-height:18px;
  font-weight:800;padding:0 10px;border-radius:9px;background:#1f9d46;color:#fff}
.ev em.wait{background:#7a5a12;color:#ffe9a8}
.ev em.off{background:#3a3f55;color:#dfe4f0}
`.trim()

// ----------------------------------------------------------------- helpers --
function num(v) { return typeof v === "number" && Number.isFinite(v) ? v : null }
function val(v, dash) { const n = num(v); return n == null ? esc(dash || "—") : esc(fmt(n)) }
function pad2(n) { return n < 10 ? "0" + n : String(n) }
function relText(sec) {
  const left = Math.max(0, Math.trunc(sec || 0))
  const d = Math.floor(left / 86400), h = Math.floor((left % 86400) / 3600), m = Math.floor((left % 3600) / 60)
  if (d > 0) return `${d}d ${h}h`
  if (h > 0) return `${h}h ${m}m`
  return `${m}m`
}

/** The season window: the game's pushed one, else the documented default
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

/** The countdown cells. Never negative: a closed window is all zeros. */
export function countdownCells(end, now) {
  const left = Math.max(0, Math.trunc(end - now))
  return {
    days: Math.floor(left / 86400),
    hours: Math.floor((left % 86400) / 3600),
    minutes: Math.floor((left % 3600) / 60),
    seconds: left % 60,
    left,
    closed: left === 0
  }
}

// -------------------------------------------------------------------- page --
export async function pageDashboard(env, url) {
  const now = Math.floor(Date.now() / 1000)
  const minted = url && url._fnMotdSid
  const raw = (minted && String(minted)) || (url.searchParams.get("steamid") || "").trim()
  const sid = /^STEAM_[0-9]:[0-9]:\d+$/.test(raw) ? raw : ""
  const data = await loadDashboard(env, sid, now)
  return new Response(renderPlate(data), {
    status: 200,
    headers: {
      "content-type": "text/html; charset=utf-8",
      "cache-control": "no-store",
      "x-content-type-options": "nosniff"
    }
  })
}

// Fixed query count: the schedule (cached per env) + the pushed season row; for
// a known player getPlayer() (its own fixed set), the last four ledger lines,
// the tree slots and the mission claims. Nothing runs inside a loop.
export async function loadDashboard(env, sid, now) {
  const schedule = env.DB ? await loadSchedule(env, now) : []
  // No DB bound (a static preview) is not an error: the schedule and the season
  // window fall back to their documented defaults.
  const seasonRow = env.DB ? await env.DB.prepare("SELECT value FROM winter_meta WHERE key='season'").first().catch(() => null) : null
  const window = seasonWindow(seasonRow, now)
  const cd = countdownCells(window.end, now)
  let p = null, ledger = [], tree = null, missions = []
  if (sid) {
    try { p = await getPlayer(env.DB, sid) } catch { p = null }
    if (p && p.exists) {
      ledger = await recentLedger(env.DB, sid, { limit: 4 })
      tree = await treeSlots(env.DB, sid)
      missions = await missionsFor(env.DB, sid, { limit: 60 })
    }
  }
  const known = !!(p && p.exists)
  return {
    sid, known, p, ledger, tree, missions, cd, window, now,
    active: (schedule || []).filter(e => e.state === "active")
      .concat((schedule || []).filter(e => e.state === "scheduled")).slice(0, 4),
    who: known ? String(p.name || "") : ""
  }
}

// ------------------------------------------------------------------ render --
export function renderPlate(d) {
  const { sid, known, p, ledger, tree, missions, active, cd, now, who } = d
  const counts = (p && p.counts) || {}
  const treePct = known && tree && tree.capacity ? Math.round((tree.filled / tree.capacity) * 100) : null

  // The panel owns CLAIM state only (query.js missionsFor): "done" is the
  // applied claims, and a denominator only when the game pushed one.
  const done = missions.filter(m => m.state === "applied").length
  const total = Number(counts.missions_total || 0) || (missions.length || 0)
  const none = "No player"

  // Field id -> the text printed in it. Every id here is a FIELD_TEXT row.
  const values = {
    f_coins: known ? val(p.coins) : none,
    f_coins_l: "Coins",
    f_gb: known ? val(p.gingerbread) : none,
    f_gb_l: "GingerBread",
    f_spins: known ? val(p.spins) : none,
    f_spins_l: "Spins",
    f_miss: known ? val(done) : none,
    f_miss_l: "Missions",
    f_who: known && who ? esc(who) : esc(none),
    f_lvl: known && num(p.level) != null ? "Level " + esc(fmt(p.level)) : (sid ? "not synced" : ""),
    f_cd_lbl: cd.closed ? "Ended" : "Event Ends In",
    f_cd_1: String(cd.days),
    f_cd_2: pad2(cd.hours),
    f_cd_3: pad2(cd.minutes),
    f_cd_4: pad2(cd.seconds),
    f_cap_tree: "My Tree",
    f_cap_tree_v: treePct == null ? (known ? "—" : none) : treePct + "%",
    f_cap_pass: "Battle Pass",
    f_cap_pass_v: known ? (num(p.pass && p.pass.tier) == null ? "—" : "Lv." + fmt(p.pass.tier)) : none,
    f_cap_adv: "Advent",
    f_cap_adv_v: known ? `${Number(counts.advent_claimed || 0)}/24` : none,
    f_cap_mis: "Missions",
    f_cap_mis_v: known ? `${done}/${total || 0}` : none,
    f_cap_evt: "Events",
    f_cap_evt_v: "Active: " + active.filter(e => e.state === "active").length,
    f_tree_lbl: "Tree Progress",
    f_tree_pct: treePct == null ? "—" : treePct + "%",
    f_prog_hd: "Event Progress",
    f_prog_sub: "Complete Winterfest objectives for exclusive rewards!",
    f_rew_hd: "Recent Rewards",
    f_rew_sub: "Your latest Christmas rewards!"
  }

  // Only counters the panel really has (03-DASHBOARD.md §7). "Gingerbread
  // earned" has no counter anywhere in the schema: a dash, never a 0.
  const rows = [
    ["Gingerbread earned", null, null],
    ["Ornaments owned", known ? num(counts.ornaments_total) : null, null],
    ["Missions done", known ? done : null, total || null],
    ["Ornaments placed", tree ? tree.filled : null, tree ? tree.capacity : null]
  ]
  rows.forEach(([label, n, target], i) => {
    values[`f_row${i + 1}_l`] = label
    values[`f_row${i + 1}_v`] = n == null ? "—" : (target ? `${fmt(n)}/${fmt(target)}` : fmt(n))
  })

  // One paint class per tile, and a class per field that names its tile.
  const paintClasses = STRIPS.map(([n]) => `st-${n}`).join(" ")
  const coverClass = {}
  // tile t covers field f when its field box (indexes 5..8) contains f's box
  const course = (t, f) => t[5] <= f[1] && t[5] + t[7] >= f[1] + f[3] && t[6] <= f[2] && t[6] + t[8] >= f[2] + f[4]
  for (const f of FIELD_TEXT) {
    const hit = STRIPS.find(t => course(t, f))
    if (hit) coverClass[f[0]] = `st-${hit[0]}`
  }

  // A field that prints nothing (no player, no value) still keeps its cover:
  // the plate's sample glyph must never show through. So the span is always
  // emitted and only the value decides whether it is painted.
  const fieldNodes = FIELD_TEXT.map(([id, x, y, w, h, tint]) => {
    const v = values[id]
    const empty = v == null || v === ""
    const cls = [tint && tint !== "white" ? `tone-${tint}` : "", empty ? "blank" : ""].filter(Boolean).join(" ")
    const cover = coverClass[id] ? ` ${coverClass[id]}` : ""
    return `<div class="fld${cover}" id="${id}" style="left:${x}px;top:${y}px;width:${w}px;height:${h}px">` +
      `<span${cls ? ` class="${cls}"` : ""}>${empty ? "" : v}</span></div>`
  }).join("\n")

  // The chrome strips: each is one clean plate slice stretched over its field.

  // The reward tiles keep the plate's frames (already clean); the page's own
  // ledger entries are printed underneath them.
  const rewards = [0, 1, 2, 3].map(i => {
    const r = ledger[i]
    const x = 1240 + i * 105
    const amt = r ? (r.delta > 0 ? "+" : "") + fmt(r.delta) : "—"
    const cur = r ? String(r.currency || "grant") : ""
    return `<div class="rw" style="left:${x}px"><b>${esc(amt)}</b><i>${esc(cur)}</i></div>`
  }).join("\n")

  // The four event cards: title, detail, state — no sample text anywhere.
  const cards = [0, 1, 2, 3].map(i => {
    const c = EVENTS_POS[i]
    const e = active[i]
    if (!e) {
      return `<div class="ev" style="left:${c.x}px;top:${c.y}px;width:${c.w}px;height:120px">` +
        `<b>No event</b><span>Nothing scheduled in this slot yet.</span></div>`
    }
    const live = e.state === "active"
    const cls = live ? "" : (e.starts_at > now ? " wait" : " off")
    const state = live ? "Active Now" : "Starts in " + relText(e.starts_at - now)
    return `<div class="ev" style="left:${c.x}px;top:${c.y}px;width:${c.w}px;height:120px">` +
      `<b>${esc(e.title)}</b><span>${esc(e.detail || "")}</span>` +
      `<em class="${cls}">${esc(state)}</em></div>`
  }).join("\n")

  const stage = `
<div id="stage" class="${paintClasses}" data-cd-sec="${cd.left}">
  <div id="plate"></div>
  <div id="row_bg"></div>
  ${fieldNodes}
  ${rewards}
  <div id="act_hd">Active Winterfest Events</div>
  ${cards}
</div>`

  return `<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>FreeNova · Winterfest dashboard</title>
<style>${CSS}</style></head>
<body>${stage}
<script>
(function(){
  // Additive only: the server's countdown is already in the markup.
  var st=document.getElementById('stage');if(!st)return;
  var left=parseInt(st.getAttribute('data-cd-sec'),10)||0;
  var f=function(n){return (n<10?'0':'')+n};
  var set=function(id,v){var e=document.getElementById(id);if(e&&e.firstChild)e.firstChild.textContent=v};
  setInterval(function(){
    if(left<=0)return;left--;
    set('f_cd_1',String(Math.floor(left/86400)));set('f_cd_2',f(Math.floor(left%86400/3600)));
    set('f_cd_3',f(Math.floor(left%3600/60)));set('f_cd_4',f(left%60));
  },1000);
  // ONE SCREEN: the fixed 1672x941 stage scaled to fit BOTH axes at the plate's
  // exact ratio (min(vw/1672, vh/941)), never above 1:1, letterboxed evenly.
  // One translate+scale on a composited layer: no reflow, nothing to scroll.
  var fit=function(){
    var vw=window.innerWidth,vh=window.innerHeight;
    var s=Math.min(vw/${PLATE_W},vh/${PLATE_H},1);
    st.style.transform='translate('+((vw-${PLATE_W}*s)/2)+'px,'+((vh-${PLATE_H}*s)/2)+'px) scale('+s+')';
    st.style.scale='1';
    st.setAttribute('data-scale',s.toFixed(4));
    st.setAttribute('data-noscroll', String(
      document.documentElement.scrollWidth <= window.innerWidth &&
      document.documentElement.scrollHeight <= window.innerHeight));
  };
  fit();window.addEventListener('resize',fit);
})();
</scr` + `ipt>
</body></html>`
}
