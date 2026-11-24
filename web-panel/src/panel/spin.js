// FreeNova panel — Spin Wheel (route /panel/spin).
//
// PLATE   docs/design/refs/winterfest/12-spin.png (1672x941). Every picture on this
//         page is a CSS sprite of that file — the nav rail, the top bar, the hero,
//         the wheel, the two side panels and the Spin Now button all come from it.
//         The only drawing this file does is CSS: the wheel's marker, the spin
//         count and the Wedge table's lettering, because the plate's own wedges
//         name prizes this page cannot pay (see below).
//
// THE TABLE IS THE GAME'S  winterfest_spin.amxx rolls spin.ini [sector]: ten wedges,
//         weights 12/20/18/12/10/8/9/6/3/2 (sum 100), and that table lives in
//         src/state.js SPIN_WHEEL, where the apply step reads it. This page reads
//         the SAME constant, so the odds printed here cannot drift from the odds
//         paid there.
//
// THREE WEDGES THE PAGE CANNOT PAY  `Common Present`, `Rare Present` and `Mystery
//         Ornament` are delivered in game by present.sma (open a present) and by
//         the engine picking an ornament; the pull's reward fields are coins,
//         gingerbread, spins, pass_xp, item, product. A panel spin that lands on
//         one of those three is `Nothing` — the table's own gap — and the history
//         says which one it was. Nothing is invented and nothing is silently lost.
//
// SPENDING A spin is a POST to this route: the server computes the player's nth
//         spin of the day, calls queueAction({kind:"spin", payload:{n}, idem:
//         "spin:<day>:<n>"}) and re-renders. A double submit with the same n is one
//         row (the UNIQUE (steamid, kind, idem) does the work). The row stays
//         QUEUED until applyAction (the game's pull, then the ack) has spent the
//         token and paid the wedge. A Refusal is printed VERBATIM.
//
// ONE SCREEN  A fixed 1672x941 stage scaled by min(vw/W, vh/H), letterboxed, with
//         overflow:hidden and a document guard, so no scrollbar exists at any size.
import { getPlayer, queueAction, Refusal, SPIN_WHEEL, spinWedge } from "../state.js"
import { actionsOfKind } from "../query.js"
import { esc, fmt } from "../top15/render.js"
import { actionState, refusalText } from "./shared.js"

export const PLATE = "12-spin.png"
export const PLATE_W = 1672, PLATE_H = 941
export const PLATE_URL = "/plates/12-spin.png"

// --------------------------------------------------------------- the sprites --
const S = (name, sx, sy, sw, sh, x, y, w, h) => [name, sx, sy, sw, sh,
  x == null ? sx : x, y == null ? sy : y, w == null ? sw : w, h == null ? sh : h]

export const SPRITES = [
  S("page", 0, 0, PLATE_W, PLATE_H),
  // the wedges table (the plate's "Possible Rewards" panel) — repainted dark with
  // `.cover`, then the page's own wedges are written on it.
  S("rewards", 1190, 515, 480, 300),
  // the plate's Spin Now button, minus its own dice-and-count (see .cover)
  S("spinBtn", 700, 836, 480, 74),
  // the two side panels' headers, for the panels this page repaints
  S("hdrSpins", 318, 296, 268, 22),
  S("hdrFeatured", 1218, 296, 440, 24)
]

// The plate's wheel: centre and radius measured off 12-spin.png (the outer gold rim
// runs from x 610 to x 1260, y 240 to y 850).
export const WHEEL = { cx: 942, cy: 556, r: 296, inner: 110 }

// The plates' rarity colours (spin.ini [sector] comment, ART-RULE §3).
export const RARITY_COLOUR = { common: "#9fb0d0", uncommon: "#3fbf6f", rare: "#4070c0", legendary: "#f5c451" }

// The plate's wedges draw prizes this page cannot pay; these are the plate's words
// for the eight sectors it prints, in plate order (clockwise from the top).
export const PLATE_WEDGES = [
  "AK-47 | Winterfest (Skin)", "1,000 GingerBread", "+10,000 XP", "VIP (7 Days)",
  "Christmas Hat (Cosmetic)", "Snow Frame (Exclusive)", "+5 Battle Pass Levels", "5,000 Coins"
]

const CSS = `
@font-face{font-family:'Nunito';src:url('/assets/fonts/Nunito-Variable.ttf') format('truetype-variations');
  font-weight:200 1000;font-display:swap}
*{box-sizing:border-box}
html,body{margin:0;padding:0;width:100%;height:100%;overflow:hidden;background:#0b1030;overscroll-behavior:none}
body{font-family:Nunito,'Trebuchet MS','Segoe UI',Cantarell,Arial,sans-serif;-webkit-font-smoothing:antialiased}
#letterbox{position:fixed;inset:0;overflow:hidden;background:#0b1030}
#stage{position:absolute;left:0;top:0;width:${PLATE_W}px;height:${PLATE_H}px;overflow:hidden;
  transform-origin:0 0;color:#fff}
#plate{position:absolute;left:0;top:0;width:${PLATE_W}px;height:${PLATE_H}px;
  background-image:url(${PLATE_URL});background-repeat:no-repeat;background-size:${PLATE_W}px ${PLATE_H}px}
.sp{position:absolute;background-image:url(${PLATE_URL});background-repeat:no-repeat;
  background-size:${PLATE_W}px ${PLATE_H}px}
${SPRITES.map(([n, sx, sy, sw, sh, x, y, w, h]) =>
  `.sp-${n}{left:${x}px;top:${y}px;width:${w}px;height:${h}px;` +
  `background-position:-${sx}px -${sy}px}`).join("\n")}
/* A repainted plate panel: the plate's own panel frame stays, its sample words are
   covered by the panel's own dark field, and the page writes on top. */
.cover{position:absolute;background:linear-gradient(rgba(11,16,48,.97),rgba(9,13,38,.97));
  border:2px solid #2a3d6e;border-radius:14px;box-shadow:0 8px 24px rgba(0,0,0,.45)}
.cover .t{position:absolute;font-weight:800;color:#f5c451;text-shadow:0 1px 2px #000;white-space:nowrap}
.cover .b{position:absolute;font-weight:700;color:#e7eeff;text-shadow:0 1px 2px #000}
.cover .g{position:absolute;font-weight:800;color:#8ef0b0;text-shadow:0 1px 2px #000}
.who{position:absolute;left:318px;top:250px;width:620px;font-size:12.5px;line-height:16px;
  font-weight:800;color:#fff;text-shadow:0 1px 3px #000;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.wal{position:absolute;left:320px;top:583px;width:270px;display:flex;gap:6px;align-items:center;flex-wrap:wrap}
.chip{display:inline-flex;align-items:center;padding:1px 7px;border-radius:9px;font-size:10.5px;
  font-weight:800;background:#1b2a52;color:#fff;border:1px solid #2a3d6e;white-space:nowrap}
.chip.pending{background:#3a2c07;color:#ffd975;border-color:#6b5410}
.chip.paid{background:#0f3322;color:#8ef0b0;border-color:#1f6b3a}
.chip.refused{background:#3a0d16;color:#ffb3c0;border-color:#7a1a2a}
/* the wheel's marker: the plate's red pin, drawn as CSS over its own position */
.mark{position:absolute;left:${WHEEL.cx - 13}px;top:${WHEEL.cy - WHEEL.r - 18}px;width:26px;height:34px;
  filter:drop-shadow(0 2px 3px rgba(0,0,0,.6))}
.mark:before{content:"";position:absolute;left:0;top:0;width:26px;height:26px;border-radius:50%;
  background:radial-gradient(circle at 40% 35%,#ff8a8a,#e3242b 60%,#8d0c14)}
.mark:after{content:"";position:absolute;left:8px;top:20px;width:10px;height:16px;
  background:#c0151f;clip-path:polygon(50% 100%,0 0,100% 0)}
/* the count on the plate's spin button: its own dice-and-figure is covered by the
   plate's purple pill sampled from the same button, then the number goes on */
.spinCount{position:absolute;left:1110px;top:846px;width:120px;height:54px;
  display:flex;align-items:center;justify-content:center;
  background:linear-gradient(#5b1f9e,#3a0f6e);border-radius:27px;border:2px solid #b06bff;
  font-size:22px;font-weight:900;color:#fff;text-shadow:0 2px 3px #000}
.spinBtn{position:absolute;left:700px;top:836px;width:480px;height:74px;border:0;padding:0;
  background:transparent;cursor:pointer;font:inherit}
.spinBtn:hover{filter:brightness(1.08)}
.spinBtn:disabled{cursor:default}
.notice{position:absolute;left:632px;top:918px;width:616px;padding:7px 14px;border-radius:12px;
  font-size:12px;line-height:16px;font-weight:800;text-align:center}
.notice.ok{background:rgba(15,51,34,.97);border:2px solid #1f6b3a;color:#b9ffd2}
.notice.bad{background:rgba(58,13,22,.97);border:2px solid #7a1a2a;color:#ffc4cf}
.notice.warn{background:rgba(58,44,7,.97);border:2px solid #6b5410;color:#ffe1a3}
.row{display:flex;align-items:center;gap:6px;font-variant-numeric:tabular-nums}
`;

// --------------------------------------------------------------- formatting --
const DAYS = new Intl.DateTimeFormat("en-CA", {
  timeZone: "Europe/Paris", year: "numeric", month: "2-digit", day: "2-digit"
})

/** The Europe/Paris calendar day — the day a spin key is scoped to. */
export function parisDay(now) { return DAYS.format(new Date(now * 1000)) }

/** The idempotency key for one spin: `spin:<day>:<n>`. */
export function spinIdem(day, n) { return `spin:${day}:${n}` }

/** The nth spin's number for a day: one more than the highest `n` already queued
 *  that day, so a double submit computes the SAME n and lands on the same row. */
export function nextSpinNo(spins, day) {
  let max = 0
  for (const r of spins || []) {
    const pl = r.payload || {}
    if (r.idem && String(r.idem).startsWith(`spin:${day}:`)) {
      const n = Number(String(r.idem).slice(`spin:${day}:`.length))
      if (Number.isFinite(n)) max = Math.max(max, n)
    }
    if (pl.now && parisDay(Number(pl.now)) !== day) continue
  }
  return max + 1
}

// --------------------------------------------------------------- the loader --
export async function loadSpin(env, sid, now) {
  let p = null, spins = []
  if (env && env.DB) {
    if (sid) {
      try { p = await getPlayer(env.DB, sid) } catch { p = null }
      if (p && p.exists) {
        try { spins = await actionsOfKind(env.DB, sid, "spin", { limit: 20 }) } catch { spins = [] }
      }
    }
  }
  return { sid, p, known: !!(p && p.exists), spins, now, day: parisDay(now) }
}

// ------------------------------------------------------------------ actions --
/** The one write path: queue one `spin` and say what happened.
 *  Never writes a state table — queueAction is the only writer in the panel. */
export async function submitSpin(env, sid, now) {
  const day = parisDay(now)
  const out = { ok: false, kind: "", message: "", action: null, created: false }
  if (!sid) {
    out.kind = "warn"
    out.message = "No SteamID: the wheel cannot spend a token for a player it cannot name. " +
      "Open the page with ?steamid=STEAM_0:0:123."
    return out
  }
  let spins = []
  try { spins = await actionsOfKind(env.DB, sid, "spin", { limit: 40 }) } catch { spins = [] }
  const n = nextSpinNo(spins, day)
  try {
    const res = await queueAction(env.DB, { steamid: sid, kind: "spin", payload: { n, now }, idem: spinIdem(day, n), now })
    out.ok = true
    out.created = !!res.created
    out.action = res.action
    out.kind = "ok"
    out.message = res.created
      ? `Queued: spin ${n} of ${day}. The token is NOT spent yet — the row stays queued until the game ` +
        `pulls it and the apply step spends the spin and pays the wedge.`
      : `Already queued: action #${res.action.id} is spin ${n} of ${day}. Nothing new was created ` +
        `(a refresh or a double click cannot spend twice).`
  } catch (e) {
    out.kind = "bad"
    out.message = refusalText(e)
    out.refused = e instanceof Refusal
  }
  return out
}

// ----------------------------------------------------------------- rendering --
function wedgeLabel(r, row) {
  const pl = (r && r.payload) || {}
  const n = pl.n
  if (r && r.state === "applied" && r.result && r.result.prize) return String(r.result.prize)
  // Not applied yet: the wedge its ID lands on is already decided (that is the
  // point of the deterministic draw), so the page can say where it will stop.
  if (r && r.id != null && r.state !== "refused") return spinWedge(r.id).label
  return "—"
}

function stateChip(r) {
  const st = actionState(r)
  const cls = st.key === "pending" ? "pending" : st.key === "refused" ? "refused" : "paid"
  return { cls, label: st.key === "pending" ? "Queued" : st.label, detail: st.detail }
}

function historyPanel(d) {
  const rows = (d.spins || []).slice(0, 6).map(r => {
    const s = stateChip(r)
    const pl = r.payload || {}
    const n = pl.n == null ? "?" : pl.n
    const lbl = wedgeLabel(r, pl)
    const fight = s.cls === "refused" ? esc(String(r.error || "")) : esc(lbl)
    return `<div class="row" style="margin-top:3px"><span class="chip ${s.cls}" style="min-width:52px;` +
      `justify-content:center">${s.label}</span>` +
      `<span class="b" style="position:static;font-size:10.5px;white-space:nowrap;overflow:hidden;` +
      `text-overflow:ellipsis;max-width:326px" title="spin ${esc(String(n))} · ${esc(s.detail)}">` +
      `#${esc(String(n))} · ${fight}</span></div>`
  })
  const body = rows.length ? rows.join("") :
    `<div class="b" style="position:static;margin-top:6px;font-size:10.5px;color:#c9d2ea">` +
    `No spin yet: nothing has been queued from this page.</div>`
  return `<div class="cover" style="left:1190px;top:515px;width:480px;height:300px;padding:9px 12px;z-index:3">` +
    `<div class="t" style="position:static;font-size:14.5px;line-height:18px">Spin History</div>` +
    `<div class="b" style="position:static;font-size:10.5px;line-height:13px;color:#c9d2ea;` +
    `margin:2px 0 4px">A row says Paid only once the apply step has spent the token and paid the wedge.</div>` +
    body + `</div>`
}

/** The wedge table: the game's own ten sectors, read from SPIN_WHEEL. Two columns,
 *  five rows each, in the plate's "Possible Rewards" panel. */
function wedgeTable() {
  const total = SPIN_WHEEL.reduce((a, w) => a + w.weight, 0)
  const cell = (w, i) => {
    const y = 34 + (i % 5) * 52
    const x = i < 5 ? 10 : 244
    const col = RARITY_COLOUR[w.rarity] || RARITY_COLOUR.common
    const pct = Math.round((w.weight / total) * 100)
    return `<div class="b" style="left:${x}px;top:${y}px;width:224px;font-size:10.5px;line-height:13px;` +
      `white-space:normal"><span style="display:inline-block;width:7px;height:7px;border-radius:50%;` +
      `background:${col};margin-right:4px"></span>${esc(w.label)}<br>` +
      `<span style="color:#ffd975;font-weight:800">${pct}%</span>` +
      `<span style="color:#9fb0d0"> · ${esc(w.rarity)}</span>` +
      `${w.none ? `<span style="color:#ffb3c0"> · in game only</span>` : ""}</div>`
  }
  return `<div class="cover" style="left:1190px;top:515px;width:480px;height:300px;padding:9px 12px">` +
    `<div class="t" style="position:static;font-size:14.5px;line-height:18px">Wheel sectors (spin.ini [sector])</div>` +
    `<div class="b" style="position:static;font-size:10.5px;line-height:13px;color:#c9d2ea;margin:2px 0 0">` +
    `The game rolls these ten: weights ${SPIN_WHEEL.map(w => w.weight).join("+")} = ${total}. ` +
    `Three of them (present, rare present, mystery ornament) are handed out in game and cannot be ` +
    `delivered by a panel row — a spin that lands there is Nothing, and the history names it.</div>` +
    SPIN_WHEEL.map(cell).join("") + `</div>`
}

function featuredPanel() {
  return `<div class="cover" style="left:1186px;top:290px;width:452px;height:52px;padding:6px 12px;z-index:2">` +
    `<div class="t" style="position:static;font-size:14.5px;line-height:18px">Featured Reward</div>` +
    `<div class="b" style="position:static;font-size:10.5px;line-height:13px;color:#ffd9a8">` +
    `<b>Not available yet.</b> The plate's prize is a weapon skin, and the pull grants no skin. ` +
    `The wheel's real top prize is the Collector Title (3 %).</div></div>`
}

function spinsPanel(d) {
  const p = d.p
  const known = d.known
  const wallet = known
    ? `<span class="chip">${esc(String(p.spins == null ? 0 : p.spins))} Spins</span>` +
      `<span class="chip">${esc(fmt(p.gingerbread))} GingerBread</span>`
    : `<span class="chip">No player</span>`
  // The plate's "Your Spins" card already prints a dice and a 0; this covers that
  // figure with the player's real count.
  return `<div class="cover" style="left:${460}px;top:${330}px;width:120px;height:44px;` +
    `background:transparent;border:0;box-shadow:none;z-index:2">` +
    `<div style="font-size:30px;line-height:40px;font-weight:900;text-align:center;color:#fff;` +
    `text-shadow:0 2px 4px #000">${known ? esc(String(p.spins == null ? 0 : p.spins)) : "—"}</div></div>` +
    `<div class="wal">${wallet}</div>`
}

export function renderSpin(d, opts) {
  const o = opts || {}
  const n = o.notice
  const notice = n ? `<div class="notice ${n.kind === "ok" ? "ok" : n.kind === "warn" ? "warn" : "bad"}">` +
    esc(n.message) + `</div>` : ""
  const p = d.p
  const timer = `<div class="cover" style="left:318px;top:636px;width:268px;height:44px;padding:4px 10px;z-index:2">` +
    `<div class="b" style="position:static;font-size:10px;line-height:12.5px;color:#ffd9a8">` +
    `GingerBread buys no spin from this page: spin.ini has no cost column — 500 GB = 1 spin is the ` +
    `plate's own copy, and the game's only spin paths are the daily grant, the wheel itself and ` +
    `<b>wfspin_grant</b>.</div></div>`
  const how = `<div class="cover" style="left:318px;top:486px;width:268px;height:142px;padding:6px 10px;z-index:2">` +
    `<div class="t" style="position:static;font-size:13px;line-height:16px">How to get spins?</div>` +
    `<div class="b" style="position:static;font-size:10.5px;line-height:13px;color:#c9d2ea;margin-top:3px">` +
    `<b style="color:#8ef0b0">+1</b> a day: winterfest.ini [spins] free_per_day = 1, granted at connect ` +
    `(claim key spin#&lt;date&gt;, so five logins pay once).<br>` +
    `<b style="color:#ffd975">The wheel itself</b> pays "1 Extra Spin" on 8 % of spins.<br>` +
    `Staff: <b>wfspin_grant</b>.</div></div>`
  const hero = `<div class="cover" style="left:318px;top:290px;width:268px;height:32px;` +
    `background:transparent;border:0;box-shadow:none;z-index:2"></div>`

  const stage = `
<div id="stage" data-day="${esc(d.day)}">
  <div class="sp sp-page"></div>
  <div class="who">${d.known
    ? `${esc(p.name || d.sid)} · Level ${p.level == null ? "—" : esc(fmt(p.level))} · Spinning ${esc(d.day)}`
    : (d.sid ? `${esc(d.sid)} — the panel has never heard from this player`
      : "No player selected — add ?steamid=STEAM_0:0:123 to load a wallet")}</div>
  ${hero}
  ${spinsPanel(d)}
  ${how}
  ${timer}
  <div class="mark"></div>
  <button class="spinBtn" type="submit" form="spinForm" aria-label="Spin the wheel"></button>
  <form id="spinForm" method="post" action="/panel/spin" style="margin:0">
    <input type="hidden" name="s" value="${esc(d.sid || "")}">
  </form>
  <div class="spinCount">${d.known ? esc(String(p.spins == null ? 0 : p.spins)) : "—"}</div>
  ${featuredPanel()}
  ${wedgeTable()}
  ${historyPanel(d)}
  ${notice}
</div>`

  return `<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>FreeNova · Winterfest Spin Wheel</title>
<style>${CSS}</style></head>
<body><div id="letterbox">${stage}</div>
<script>
(function(){
  var st=document.getElementById('stage');
  var W=${PLATE_W},H=${PLATE_H};
  function fit(){
    var vw=window.innerWidth,vh=window.innerHeight;
    var s=Math.min(vw/W,vh/H,1);
    st.style.transform='translate('+Math.round((vw-W*s)/2)+'px,'+Math.round((vh-H*s)/2)+'px) scale('+s+')';
    st.setAttribute('data-scale',s.toFixed(4));
    st.setAttribute('data-noscroll',String(
      document.documentElement.scrollWidth<=vw && document.documentElement.scrollHeight<=vh));
  }
  fit();window.addEventListener('resize',fit);
})();
</scr` + `ipt>
</body></html>`
}

// --------------------------------------------------------------------- page --
export async function pageSpin(env, url, request) {
  const now = Math.floor(Date.now() / 1000)
  const minted = url && url._fnMotdSid
  let sid = /^STEAM_[0-9]:[0-9]:\d+$/.test(String(minted || "")) ? String(minted) : ""
  if (!sid) {
    const q = String(url.searchParams.get("steamid") || "").trim()
    if (/^STEAM_[0-9]:[0-9]:\d+$/.test(q)) sid = q
  }
  let notice = null
  if (request && request.method === "POST") {
    let form = null
    try { form = await request.formData() } catch { form = null }
    if (form) {
      const bodySid = String(form.get("s") || "").trim()
      if (/^STEAM_[0-9]:[0-9]:\d+$/.test(bodySid)) sid = bodySid
      notice = await submitSpin(env, sid, now)
    } else {
      notice = { kind: "bad", message: "Nothing was queued: the form could not be read." }
    }
  }
  const d = await loadSpin(env, sid, now)
  return new Response(renderSpin(d, { notice }), {
    status: 200,
    headers: {
      "content-type": "text/html; charset=utf-8",
      "cache-control": "no-store",
      "x-content-type-options": "nosniff"
    }
  })
}
