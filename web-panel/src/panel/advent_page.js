// FreeNova panel — /panel/advent, the advent calendar (page 3 of the Winterfest
// UI; the plate is docs/design/refs/winterfest/11-advent.png, 1622x969, served
// from assets/plates/11-advent.png).
//
// HOW THIS PAGE IS BUILT (one rule, no exceptions)
//   #plate paints the plate ONCE, whole, at its own size. The shell (the
//   resources bar and the sidebar) is cut rows of that same plate and REPLACES the
//   bar (see src/panel/shell_v3.js). The road's own band - the one the plate
//   paints "Nov 18".."Nov 24" and a house per stop on - is covered with clean sky
//   from the same plate, and the page lays the plate's OWN house art along a
//   24-stop path, one house per day.
//
// THE OWNER'S DATE LAW (src/panel/advent.js is the only implementation)
//   day N is the Nth of December Paris, claimable ON that date only; a missed day
//   cannot be claimed during the event; after 24 December the Advent Pass reopens
//   the missed days, and only until 31 December. This page never computes a date:
//   it draws the verdicts loadAdvent() gives it, and a claim it queues carries the
//   reward src/panel/advent.js says the day pays.
//
// DATA
//   loadAdvent() (src/panel/advent_data.js) → getPlayer() + winter_advent. A
//   missing player says "No player"; a month the panel cannot know prints an em
//   dash, never a zero pretending to be data.
import { getPlayer } from "../state.js"
import { parisParts } from "../periods.js"
import { envNow } from "./clock.js"
import { PLATE_URL, FONT_FACE, stageCss, stageScript, CARD_TITLE_SLICE } from "./plates.js"
import { BAR_H, NAV_W, shellCss, shellHtml } from "./shell_v3.js"
import { loadAdvent, requestClaim } from "./advent_data.js"
import { STOPS, houseFor, roadCss, roadPathCss, ROAD, HOUSES } from "./advent_road.js"
import { ADVENT_DAYS } from "./advent.js"

export const PLATE = PLATE_URL.advent
export const PLATE_W = 1622, PLATE_H = 969

// The three bottom cards, as boxes on the plate: [title, x, y, w, h]
export const CARDS = {
  progress: { x: 305, y: 800, w: 393, h: 122 },
  next: { x: 712, y: 800, w: 393, h: 122 },
  final: { x: 1143, y: 800, w: 400, h: 122 }
}

// The reward strip on the right: heading, then eight rows of 55px from y=194.
export const STRIP = { x: 1232, y: 94, w: 372, h: 690, rowY: 194, rowH: 55, rows: 8 }

// Type sizes read off the plate's own glyphs.
const T = {
  chip: 17, chipLabel: 13, who: 14, whoLevel: 12,
  stripTitle: 16, stripDays: 11,
  rowTitle: 13.5, rowSub: 11.5, rowName: 12.5,
  cardTitle: 15.5, cardBig: 22, cardText: 12.5, cardSub: 11.5,
  badge: 10.5, hsTitle: 9
}

async function allOn(db, sql, params) {
  // a broken or absent DB is "no rows", never a thrown page
  if (!db || typeof db.prepare !== "function") return []
  try {
    const res = await db.prepare(sql).bind(...(params || [])).all()
    return (res && res.results) || []
  } catch { return [] }
}

// --------------------------------------------------------------- the page ---
export async function pageAdvent(env, url) {
  const now = envNow(env)
  const minted = url && url._fnMotdSid
  const raw = (minted && String(minted)) || (url.searchParams.get("steamid") || "").trim()
  const sid = /^STEAM_[0-9]:[0-9]:\d+$/.test(raw) ? raw : ""
  const data = await loadAdvent(env, sid, now)
  return new Response(renderAdvent(data, env), {
    status: 200,
    headers: {
      "content-type": "text/html; charset=utf-8",
      "cache-control": "no-store",
      "x-content-type-options": "nosniff"
    }
  })
}

/**
 * POST /panel/advent/claim { day }. The board is the player named by the request
 * (a game-minted ?t= link or ?steamid=): the panel has no player session, so the
 * claim is queued for that player and the apply step re-checks the date law.
 * Answers JSON: { ok, error, day, action }.
 */
export async function handleAdventClaim(request, env) {
  let body = {}
  try { body = await request.json() } catch { body = {} }
  const url = new URL(request.url)
  const raw = String(body.steamid || url.searchParams.get("steamid") || "").trim()
  const sid = /^STEAM_[0-9]:[0-9]:\d+$/.test(raw) ? raw : ""
  const day = Number(body.day)
  const res = sid ? await requestClaim(env, sid, day, envNow(env)) : { ok: false, error: "no player" }
  return new Response(JSON.stringify(res), {
    status: res.ok ? 200 : 400,
    headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store" }
  })
}

// ---------------------------------------------------------------- helpers ---
const esc = s => String(s == null ? "" : s).replace(/[&<>"']/g, c => (
  { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]))
const fmt = n => (typeof n === "number" && Number.isFinite(n)) ? n.toLocaleString("en-US") : "—"
const pad2 = n => (n < 10 ? "0" + n : String(n))
const MONTH_DAY = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

/** "Dec 4" from an advent day, using the Paris date the rules used. */
function md(iso) {
  const m = /^\d{4}-(\d{2})-(\d{2})$/.exec(String(iso || ""))
  if (!m) return "—"
  return `${MONTH_DAY[Number(m[1]) - 1]} ${Number(m[2])}`
}

const STATE_WORD = {
  claimed: "Claimed", open: "Today", locked: "Locked", missed: "Missed"
}

/** The one line the road's tooltip / the strip's status shows. */
function stateLine(row, clock, hasPass) {
  if (row.state === "claimed") return "Claimed"
  if (row.state === "open") return row.date === clock.today ? "Open today" : "Open after 24 Dec"
  if (row.state === "missed") return hasPass ? "Missed" : "Missed"
  return "Locked"
}

// ---------------------------------------------------------------- render ----
export function renderAdvent(d, env) {
  const { sid, known, p, clock, rows, progress, next, final, hasPass } = d
  const counts = (p && p.counts) || {}
  const none = known ? "" : "No player"

  // The bar: the player's own numbers, or an em dash where the panel has none.
  const barValues = {
    b_coins: known ? fmt(p.coins) : "—",
    b_coins_l: "Coins",
    b_gb: known ? fmt(p.gingerbread) : "—",
    b_gb_l: "GingerBread",
    b_spins: known ? fmt(p.spins) : "—",
    b_spins_l: "Spins",
    b_miss: known ? fmt(Number(counts.missions_done || 0)) : "—",
    b_miss_l: "Missions",
    b_badge: "0",
    b_who: known && p.name ? esc(p.name) : (known ? esc(d.sid) : "No player"),
    b_lvl: known && p.level != null ? `Level ${fmt(p.level)}` : ""
  }

  const shown = rows.filter(r => r.shown)

  // ---- the road: one stop per day, the plate's own houses on the path
  const stops = STOPS.map((s, i) => {
    const row = rows[i]
    if (!row) return ""
    const [, sx, sy, sw, sh, dw, dh] = houseFor(s.house)
    const left = Math.round(s.x - dw / 2), top = Math.round(s.y - dh)
    const seen = row.shown
    const cls = `stop st-${row.state}${seen ? "" : " st-early"}`
    const badge = seen
      ? `<div class="hs-badge hb-${row.state}">${row.state === "claimed" ? "✓" : (row.state === "open" ? "!" : (row.state === "missed" ? "✕" : String(row.day)))}</div>`
      : ""
    return `<div class="${cls}" style="left:${left}px;top:${top}px;width:${dw}px;height:${dh}px" ` +
      `data-day="${row.day}" title="Day ${row.day} · ${esc(row.name)} · ${esc(STATE_WORD[row.state])}">` +
      `<div class="hs house-${s.house}" style="background-size:${dw}px ${dh}px"></div>` +
      `<div class="hs-tag" style="top:${dh - 4}px">${md(row.date)}</div>` +
      badge + `</div>`
  }).join("")

  // ---- the strip's rows (one element each; the plate paints the frames)
  // The window: the eight days around the focus day (today; day 1 before the
  // calendar opens; day 24 once it is over), or every day when all 24 fit.
  const listed = shown.length ? shown : rows
  const focusIdx = Math.max(0, listed.findIndex(r => r.day === clock.focusDay))
  const start = Math.max(0, Math.min(Math.max(0, listed.length - STRIP.rows), focusIdx - 3))
  const stripRows = listed.slice(start, start + STRIP.rows).map((row, i) => {
    const y = STRIP.rowY + i * STRIP.rowH
    return {
      y, row,
      icon: `<div class="ic-w">` +
        `<div class="rw-icon ic-${row.type}${row.type === "ornament" ? " ic-orn" + row.id : ""}"></div></div>`,
      name: row.revealed ? esc(row.name) : "Mystery Reward",
      state: stateLine(row, clock, hasPass),
      chip: row.state === "claimed" ? "ok" : (row.state === "open" ? "open" : (row.state === "missed" ? "miss" : "lock"))
    }
  })
  const stripRowsHtml = stripRows.map(({ y, row, icon, name, state, chip }) =>
    `<div class="rw rt-${row.day}" style="top:${y}px">` +
      `<div class="rw-mark mk-${row.state}">${row.state === "claimed" ? "✓" : (row.state === "open" ? "!" : "🔒")}</div>` +
      `<div class="rw-day">Day ${row.day} – ${md(row.date)}</div>` +
      `<div class="rw-state stt-${row.state}">${esc(state)}</div>` +
      (row.revealed ? icon : `<div class="rw-known">${icon}</div>`) +
      `<div class="rw-name${row.revealed ? "" : " mystery"}">${name}</div>` +
      `<div class="rw-chip ch-${chip}">${row.state === "open"
        ? '<a class="claim" href="#" data-day="' + row.day + '">Claim</a>'
        : esc(STATE_WORD[row.state])}</div>` +
      `</div>`).join("")

  // A row's day-specific class positions it; the CSS is generated from the same
  // table the markup was, so a row can never be drawn at another's y.
  const stripRowCss = stripRows.map(({ y, row }) =>
    `#strip .rw.rt-${row.day}{top:${y - STRIP.y}px}`).join("\n")

  // ---- the three bottom cards
  const pct = progress.pct
  const progressCard = `<div class="card" style="left:${CARDS.progress.x}px;top:${CARDS.progress.y}px;width:${CARDS.progress.w}px;height:${CARDS.progress.h}px">` +
    `<div class="card-cover strip strip-scard" style="top:13px"></div>` +
    `<div class="card-t" style="left:56px;top:14px">Your Progress</div>` +
    `<div class="card-big" style="left:0;top:44px;width:100%;text-align:center">${known ? `${progress.claimed} / ${ADVENT_DAYS} Days` : "No player"}</div>` +
    `<div class="pbar"><i style="width:${Math.max(0, Math.min(100, pct))}%"></i></div>` +
    `<div class="pbar-pct">${known ? pct + "%" : "—"}</div></div>`

  const n = next
  const nextCard = `<div class="card" style="left:${CARDS.next.x}px;top:${CARDS.next.y}px;width:${CARDS.next.w}px;height:${CARDS.next.h}px">` +
    `<div class="card-cover strip strip-scard" style="top:13px"></div>` +
    `<div class="card-t" style="left:56px;top:14px">Next Reward</div>` +
    (n
      ? `<div class="nx-icon"></div><div class="nx-day">Day ${n.day} – ${md(n.date)}</div>` +
        `<div class="nx-name">${esc(n.name)}</div>` +
        `<div class="nx-sub">${n.state === "open" ? (n.date === clock.today ? `Available today, ${md(n.date)}` : "Available with the Advent Pass") : "—"}</div>`
      : `<div class="nx-none">${known ? (clock.phase === "during" ? "Nothing left to claim today" : "The calendar is closed") : "No player"}</div>`) +
    `</div>`

  const f = final
  const finalCard = `<div class="card" style="left:${CARDS.final.x}px;top:${CARDS.final.y}px;width:${CARDS.final.w}px;height:${CARDS.final.h}px">` +
    `<div class="card-cover strip strip-scard" style="left:56px;width:290px;top:13px"></div>` +
    `<div class="card-t" style="left:52px;top:14px">Final Reward (Day ${f.day})</div>` +
    `<div class="ak47"></div>` +
    `<div class="fn-n" style="left:196px;top:40px">${esc(f.name)}</div>` +
    `<div class="fn-s" style="left:196px;top:62px">Exclusive Skin</div>` +
    `<div class="fn-s" style="left:196px;top:82px;color:#9fb0d8">${esc(md(f.date))} · ${f.day} ${md(f.date) > "" ? "" : ""}</div>` +
    `</div>`

  // ---- the pass card's state line (the plate draws the price and the three perks)
  const passLine = hasPass
    ? (clock.grace ? `Active · missed days reopen until 31 Dec` : `Active · missed days reopen after 24 Dec`)
    : (clock.grace ? "Not active · missed days are closed" : `Buy to claim missed days after 24 Dec`)

  // ---- the plate's own reward tiles (coins, badge, XP Boost) carry no data the
  // panel owns, so they are covered with their own row's clean background and the
  // page prints only the day and the reward it really pays.
  // the three cards' title line: one clean slice of the card surface
  const s = CARD_TITLE_SLICE
  const cardStrip = `.strip-scard{background-image:url(${PLATE});background-repeat:no-repeat;` +
    `background-position:${-s.x}px ${-s.y}px;background-size:${s.w}px ${s.h}px}`
  const css = [CSS, shellCss(PLATE, PLATE_W, PLATE_H), roadCss(PLATE), roadPathCss(), cardStrip,
    stripRowCss].join("\n")
  const values = barValues

  return `<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>FreeNova · Calendar Advent</title>
<style>${FONT_FACE}
${css}
</style></head>
<body>
<div id="stage" data-page="advent" data-day="${known ? clock.todayDay : 0}" data-phase="${clock.phase}">
  <div id="plate"></div>
  <div id="road_sky"></div>
  <div id="road_path"></div>
  ${stops}
  ${shellHtml({ values, active: "advent" })}
  <div id="strip">
    <div class="strip-cover" style="left:64px;top:10px;width:160px;height:22px"></div>
    <div class="strip-title">Rewards Timeline</div>
    <div class="strip-days">${shown.length} / ${ADVENT_DAYS} Days</div>
    ${stripRowsHtml}
  </div>
  ${progressCard}
  ${nextCard}
  ${finalCard}
  <div id="pass_pill"></div>
  <div id="pass_line">${esc(passLine)}</div>
</div>
<script>${stageScript(PLATE_W, PLATE_H)}
(function(){
  // A claim is a POST to the page's own route. The button is a link so the page
  // still works with no script: without JS it opens the same JSON route, which
  // answers the refusal instead of pretending.
  var st=document.getElementById('stage');
  var sid=${JSON.stringify(sid)};
  document.addEventListener('click',function(ev){
    var a=ev.target.closest&&ev.target.closest('a.claim');if(!a)return;ev.preventDefault();
    var day=parseInt(a.getAttribute('data-day'),10);if(!day)return;
    a.textContent='…';
    fetch('/panel/advent/claim',{method:'POST',headers:{'content-type':'application/json'},
      body:JSON.stringify({day:day,steamid:sid})}).then(function(r){return r.json()}).then(function(j){
        if(j&&j.ok){a.textContent='Claimed';a.classList.add('done');setTimeout(function(){location.reload()},700);}
        else{a.textContent='Unavailable';a.classList.add('bad');a.title=(j&&j.error)||'';}
      }).catch(function(){a.textContent='Retry';});
  });
})();
</scr` + `ipt>
</body></html>`
}

// ------------------------------------------------------------------- CSS ----
const CSS = `
#plate{position:absolute;left:0;top:0;width:${PLATE_W}px;height:${PLATE_H}px;background-image:url(${PLATE});
  background-repeat:no-repeat;background-size:${PLATE_W}px ${PLATE_H}px}
/* ---- the road --------------------------------------------------------- */
.stop{position:absolute}
.stop .hs{position:absolute;left:0;top:0;width:100%;height:100%;background-repeat:no-repeat}
.st-missed .hs{filter:grayscale(.75) brightness(.72)}
.st-locked .hs{filter:grayscale(.55) brightness(.82)}
.st-early{opacity:.32}
.hs-badge{position:absolute;left:-8px;top:-8px;min-width:22px;height:22px;border-radius:11px;
  padding:0 4px;font-size:11px;line-height:22px;font-weight:800;text-align:center;color:#08131b;
  box-shadow:0 2px 6px rgba(0,0,0,.55);border:2px solid rgba(255,255,255,.85)}
.hb-claimed{background:#39d353}
.hb-open{background:#ffd34d;color:#241a00}
.hb-missed{background:#c8544a;color:#fff}
.hb-locked{background:#7d8aa6;color:#fff}
.hs-tag{position:absolute;left:50%;transform:translateX(-50%);height:14px;padding:0 6px;
  border-radius:7px;background:rgba(8,12,28,.82);border:1px solid rgba(160,180,230,.35);
  font-size:9.5px;line-height:12px;font-weight:700;color:#dfe7ff;white-space:nowrap}
.st-open .hs-tag{background:#ffd34d;color:#241a00;border-color:#fff3c4}
.st-claimed .hs-tag{background:#1c7a3a;color:#d8ffe4;border-color:#5ee08a}
.st-missed .hs-tag{background:#61221e;color:#ffd9d4;border-color:#c8544a}
.st-locked .hs-tag{background:rgba(8,12,28,.82)}

/* ---- hero chip: the event's year, over the plate's own date line ------- */
.chip-y{position:absolute;left:1052px;top:167px;width:170px;height:26px;text-align:center;
  font-size:13px;line-height:26px;font-weight:800;color:#fff;text-shadow:0 1px 3px rgba(0,0,0,.8)}

/* ---- the reward strip -------------------------------------------------- */
#strip{position:absolute;left:${STRIP.x}px;top:${STRIP.y}px;width:${STRIP.w}px;height:${STRIP.h}px;
  background:rgba(9,11,30,.92);border-radius:14px;overflow:hidden;
  box-shadow:0 0 0 1px rgba(120,140,220,.25), 0 8px 26px rgba(0,0,0,.45)}
.strip-cover{position:absolute;background:#0b0d22;border-radius:6px}
.strip-title{position:absolute;left:64px;top:8px;height:26px;font-size:${T.stripTitle}px;
  line-height:26px;font-weight:800;color:#fff;text-shadow:0 1px 2px #000}
.strip-days{position:absolute;right:56px;top:12px;height:20px;font-size:${T.stripDays}px;
  line-height:20px;font-weight:700;color:#dfe6ff}
/* the plate already paints eight row frames with their own backgrounds and
   borders; a row is only the words and the chips ON that frame */
.rw{position:absolute;left:12px;right:16px;top:0;height:51px;border-radius:11px}
.rw-mark{position:absolute;left:8px;top:11px;width:26px;height:26px;border-radius:13px;
  font-size:13px;line-height:26px;text-align:center;font-weight:800}
.mk-claimed{background:#2ea54b;color:#fff}
.mk-open{background:#ffd34d;color:#241a00}
.mk-locked{background:#43527a;color:#dfe6ff;font-size:12px}
.mk-missed{background:#3a4a72;color:#c7d2ee;font-size:12px}
.rw-day{position:absolute;left:44px;top:7px;height:17px;font-size:${T.rowTitle}px;line-height:17px;
  font-weight:800;color:#fff;white-space:nowrap}
.rw-state{position:absolute;left:44px;top:25px;height:15px;font-size:${T.rowSub}px;line-height:15px;
  font-weight:700;white-space:nowrap}
.st-claimed.rw-state,.rw-state.st-claimed{color:#5ee08a}
.rw-state.st-missed{color:#ff9c92}
.rw-state.st-locked{color:#a8b6d8}
.rw-state.st-open{color:#ffd34d}
/* where the plate's own reward tile was: its row's clean background, and the
   page's day icon on top (a 26px symbol centred in the tile's box) */
.strip-srow{position:absolute;left:${STRIP.x + STRIP.w - 372 + 262}px;width:100px;height:20px}
.rw-icon-wrap,.ic-wrap,.ic-w,.rw-known{position:absolute;left:272px;top:11px;width:26px;height:26px}
.ic-w{top:0;left:0}
.rw-icon{position:absolute;left:0;top:0;width:26px;height:26px;border-radius:6px;
  background-repeat:no-repeat;background-position:center;background-size:contain}
.rw-known{width:30px;height:30px;top:9px;left:270px;border:1px solid rgba(255,205,90,.55);
  border-radius:7px;background-color:rgba(60,44,12,.85);
  box-shadow:inset 0 0 12px rgba(255,190,60,.35)}
.rw-known .ic-w{left:2px;top:2px;filter:brightness(.55)}
.ic-snow{background:radial-gradient(circle at 50% 50%,#fff 0 4px,#9fd8ff 5px 8px,transparent 9px)}
.ic-gift{background:linear-gradient(180deg,#ff6a6a 0 40%,#ffd34d 40% 55%,#e04747 55%);
  border-radius:6px;box-shadow:inset 0 0 0 2px rgba(255,255,255,.5)}
.ic-title{background:radial-gradient(circle,#ffe27a,#d9a021);border-radius:50%}
#pass_pill{position:absolute;left:1258px;top:536px;width:132px;height:30px}
.ic-orn{background:radial-gradient(circle at 50% 45%,#fff 0 5px,#7cc9ff 6px 11px,transparent 12px)}
.rw-name{position:absolute;left:308px;top:14px;height:20px;font-size:${T.rowName}px;line-height:20px;
  font-weight:700;color:#eef2ff;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;max-width:112px}
.rw-name.mystery{color:#a8b6d8;font-style:italic}
.rw-chip{position:absolute;right:6px;top:14px;height:22px;padding:0 10px;border-radius:11px;
  font-size:11px;line-height:22px;font-weight:800;color:#fff;white-space:nowrap}
.ch-ok{background:#1c7a3a;color:#d8ffe4}
.ch-miss{background:#7a231d;color:#ffd9d4}
.ch-lock{background:#2b3557;color:#c7d2ee}
.ch-open{background:#ffd34d;color:#241a00}
.rw-chip a{color:inherit;text-decoration:none}
.rw-chip a.done{opacity:.8}
.rw-chip a.bad{background:#7a231d;color:#ffd9d4}

/* ---- the three bottom cards ------------------------------------------- */
.card{position:absolute;border-radius:12px}
.card-cover{position:absolute;left:62px;width:220px;height:18px;z-index:2}
.rw{}
/* the plate's own card titles ("Your Progress", "Next Reward", "Final Reward")
   are its sample words, so they are covered and the page prints the same words
   with the page's own numbers beside them */
.card-t{position:absolute;height:22px;font-size:${T.cardTitle}px;line-height:22px;font-weight:800;color:#fff;
  z-index:3;
  text-shadow:0 1px 2px #000}
.card-big{position:absolute;height:30px;font-size:${T.cardBig}px;line-height:30px;font-weight:800;color:#fff;
  text-shadow:0 1px 2px #000}
.pbar{position:absolute;left:16px;top:88px;width:286px;height:14px;border-radius:7px;
  background:#241a4a;box-shadow:inset 0 0 0 1px rgba(150,120,255,.45)}
.pbar i{display:block;height:100%;border-radius:7px;background:linear-gradient(90deg,#8b3dff,#c86bff);
  box-shadow:0 0 10px rgba(170,90,255,.7)}
.pbar-pct{position:absolute;right:52px;top:84px;height:22px;font-size:12px;line-height:22px;
  font-weight:800;color:#fff}
.nx-icon{position:absolute;left:14px;top:44px;width:58px;height:58px;border-radius:11px;
  background:linear-gradient(180deg,rgba(120,80,20,.85),rgba(70,44,10,.9));
  box-shadow:inset 0 0 0 2px rgba(255,205,90,.6)}
.nx-icon:after{content:"?";position:absolute;inset:0;font-size:30px;line-height:58px;text-align:center;
  font-weight:800;color:#ffd34d}
.nx-day{position:absolute;left:82px;top:40px;height:20px;font-size:14px;line-height:20px;font-weight:800;color:#fff}
.nx-name{position:absolute;left:82px;top:60px;height:20px;font-size:13.5px;line-height:20px;font-weight:700;color:#fff}
.nx-sub{position:absolute;left:82px;top:80px;height:18px;font-size:11.5px;line-height:18px;font-weight:700;color:#a8b6d8}
.nx-none{position:absolute;left:20px;top:56px;width:350px;font-size:13px;font-weight:700;color:#c7d2ee}
.ak47{position:absolute;left:14px;top:34px;width:170px;height:56px;background-image:url(${PLATE});
  background-repeat:no-repeat;background-position:-1200px -836px;background-size:170px 56px}
.fn-n{position:absolute;height:20px;font-size:14.5px;line-height:20px;font-weight:800;color:#fff}
.fn-s{position:absolute;height:18px;font-size:12px;line-height:18px;font-weight:700;color:#e6eaf4}
#pass_line{position:absolute;left:1258px;top:700px;width:326px;height:18px;font-size:11.5px;
  line-height:18px;font-weight:700;color:#ffd34d;text-align:center;text-shadow:0 1px 2px #000}
`.trim()

/**
 * The tile that replaces the plate's own reward picture in one strip row: the
 * day's own symbol on a dark tile (the plate's tiles carry sample rewards that
 * are not this player's). Used by the page's renderer above via .rw-icon.
 */
export const ILLUSTRATED_TYPES = ["snow", "ornament", "gift", "title"]
