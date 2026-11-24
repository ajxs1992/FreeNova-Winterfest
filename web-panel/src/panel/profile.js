// FreeNova panel — the Winterfest PROFILE (docs/panel/00-CONTRACT.md page 6,
// plate docs/design/refs/winterfest/02-profile.png, 1672x941).
//
// WHAT THE PAGE IS
//   The plate's own composition, drawn at its own pixel grid: the rail on the
//   left, the resource bar on top, a hero banner with the player's identity, the
//   tab row, four cards (summary, current frame, current badge, tree), and the
//   bottom pair (season statistics, recent achievements). Every number on it is
//   the player's own, read through getPlayer() and src/query.js. Every picture is
//   a crop of the plate (src/panel/kit.js SHEET) or a shipped asset in
//   web-panel/assets — nothing is generated.
//
// WHAT IT REFUSES TO SAY
//   * A counter the schema has no source for is printed "Not collected" (or an
//     em dash where the row is a figure, never a 0 pretending to be data).
//   * There is no player model render anywhere in the panel's assets and the
//     game does not push one, so the avatar is drawn as the player's initial in
//     the plate's own ring and the model is NAMED from the equipped state.
//   * "Member since" is only printed when the panel has a date for it. Nothing
//     in the schema records a registration: players.first_seen does not exist
//     (docs/panel/01-DATA.md §11), and the page does not invent a date to fill
//     the plate's line.
//   * No frame vocabulary exists in the panel's item kinds (state.js ITEM_KINDS),
//     so the "Current Frame" card is EMPTY by design and says so.
//
// ONE SCREEN, NEVER A SCROLL: a fixed 1672x941 stage, scaled as a whole by
// min(vw/W, vh/H) and letterboxed (src/panel/kit.js scaleCss/fitScript).
import { getPlayer } from "../state.js"
import {
  presence, treeSlots, recentUnlocks, equippedCosmetics, rarestOrnament,
  badgeHoldings, recentLedger
} from "../query.js"
import { rankName } from "../ranks.js"
import { NAV_GROUPS } from "./nav.js"
import {
  PLATE_URL, PLATE_CSS_W, PLATE_CSS_H, plateDigest, fitScript,
  fragEsc as esc, thousands as fmt, numOr, show, kdText, pctText,
  agoText, stampText, steam64, NOT_COLLECTED
} from "./kit.js"

export const PROFILE_W = 1672, PROFILE_H = 941
const PLATE = PLATE_URL + "?v=" + plateDigest()

// --------------------------------------------------------------- the rail ----
// The plate's rail width; a page that wants the same rail uses the same box.
const RAIL_W = 300

// ------------------------------------------------------- what a code means ---
// ap_unlocks.code is written by the ingest from the game's achievement bit mask
// (src/sync.js ACH_BIT_META) plus whatever the game pushed. The page may only
// NAME a code it knows; an unknown one is skipped, never printed raw.
const AP_NAMES = {
  kills_100: "Hunter", kills_1000: "Executioner", kills_5000: "Warlord",
  hs_100: "Sharp Eye", hs_500: "Sharpshooter", bomb_specialist: "Bomb Specialist",
  defusal_angel: "Defusal Angel", wins_100: "Victor", level_25: "Veteran",
  level_52: "Elder", win_streak_10: "Unstoppable", coin_tycoon: "Coin Tycoon",
  combat_medic: "Combat Medic"
}

// The plate's own achievements row: five names. The page lights one only when
// the player really holds the matching medal (badges) or unlock (ap_unlocks).
const MEDAL_ROW = [
  { name: "Snow Collector", kinds: ["weekly_champion"], unlocks: [] },
  { name: "Gift Hunter", kinds: ["weekly_top3"], unlocks: [] },
  { name: "Gingerbread Master", kinds: ["weekly_streak3"], unlocks: [] },
  { name: "Tree Decorator", kinds: [], unlocks: ["wins_100"] },
  { name: "Winterfest Legend", kinds: ["monthly_champion"], unlocks: ["level_52"] }
]

// ------------------------------------------------------------------ styles ---
const CSS = `
@font-face{font-family:'Nunito';src:url('/assets/fonts/Nunito-Variable.ttf') format('truetype-variations');
  font-weight:200 1000;font-display:swap}
*{box-sizing:border-box}
html,body{margin:0;padding:0;width:100%;height:100%;background:#07040f;overflow:hidden}
body{font-family:Nunito,'Trebuchet MS','Segoe UI',Cantarell,Arial,sans-serif;-webkit-font-smoothing:antialiased;
  color:#fff}
#stage{position:absolute;left:0;top:0;width:${PROFILE_W}px;height:${PROFILE_H}px;overflow:hidden;
  background:#0b0716 radial-gradient(120% 80% at 50% 0,#2a1152 0,#120a26 55%,#0a0616 100%);
  transform-origin:0 0;will-change:transform;scale:min(calc(100vw / ${PROFILE_W}), calc(100vh / ${PROFILE_H}), 1)}
.bg{position:absolute;left:0;top:0;width:${PLATE_CSS_W}px;height:${PLATE_CSS_H}px;
  background-image:url(${PLATE});background-repeat:no-repeat;background-size:${PLATE_CSS_W}px ${PLATE_CSS_H}px}
/* ---- the rail ---- */
#rail{position:absolute;left:0;top:0;width:${RAIL_W}px;height:${PROFILE_H}px;
  background:linear-gradient(180deg,rgba(20,10,42,.94),rgba(12,6,28,.96));
  border-right:1px solid rgba(150,110,255,.18)}
#rail .brand{position:absolute;left:26px;top:14px;width:248px;height:52px;display:flex;align-items:center;gap:10px}
#rail .brand b{font-size:27px;font-weight:900;letter-spacing:-.4px;
  background:linear-gradient(180deg,#fff,#cfe3ff 60%,#8fb6ff);-webkit-background-clip:text;background-clip:text;
  color:transparent;text-shadow:0 2px 10px rgba(90,150,255,.35)}
#rail .brand i{flex:1;height:20px;border-radius:10px;
  background:linear-gradient(180deg,#c8102e,#8c0a20);display:flex;align-items:center;justify-content:center;
  font-style:normal;font-size:9.5px;font-weight:900;letter-spacing:1.2px;color:#fff;
  box-shadow:0 2px 8px rgba(200,16,46,.45)}
#rail .grp{position:absolute;left:24px;width:252px;height:16px;font-size:9.5px;font-weight:800;letter-spacing:2.4px;
  color:#8f9ec4;text-transform:uppercase;display:flex;align-items:center;gap:8px}
#rail .grp:before,#rail .grp:after{content:"";height:1px;flex:1;background:linear-gradient(90deg,transparent,#4a3a7a,transparent)}
#rail a.it{position:absolute;left:12px;width:276px;height:44px;display:flex;align-items:center;gap:8px;
  padding:0 10px 0 8px;border-radius:12px;text-decoration:none;color:inherit}
#rail a.it .ic{width:26px;height:26px;flex:0 0 26px;border-radius:8px;
  background:rgba(120,90,220,.16);border:1px solid rgba(160,130,255,.22);display:flex;align-items:center;
  justify-content:center;font-size:14px;font-weight:900;color:#c9b8ff}
#rail a.it .tx{flex:1;min-width:0}
#rail a.it .tx b{display:block;font-size:13.5px;font-weight:800;line-height:15px;color:#fff;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
#rail a.it .tx span{display:block;font-size:9px;font-weight:600;line-height:11px;color:#95a1c2;
  white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
#rail a.it.on{background:linear-gradient(90deg,rgba(120,70,240,.55),rgba(80,40,170,.18));
  box-shadow:inset 0 0 0 1.5px rgba(180,140,255,.75),0 0 18px rgba(130,80,255,.35)}
#rail a.it.on .ic{background:rgba(180,150,255,.28)}
#rail a.it del{display:none}
#rail a.it .drift{position:absolute;right:8px;top:6px;width:34px;height:34px;border-radius:50%;
  background:rgba(255,255,255,.06);border:1px solid rgba(255,255,255,.08)}
/* ---- the top bar ---- */
#top{position:absolute;left:${RAIL_W}px;top:0;right:0;height:84px;display:flex;gap:10px;padding:12px 14px 0 14px}
.chip{position:relative;height:56px;border-radius:14px;background:linear-gradient(180deg,rgba(34,20,70,.96),rgba(18,10,40,.96));
  box-shadow:inset 0 0 0 1.5px rgba(140,110,240,.35),0 6px 18px rgba(0,0,0,.35);
  display:flex;align-items:center;gap:10px;padding:0 12px;min-width:0}
.chip .em{width:30px;height:30px;border-radius:8px;flex:0 0 30px;
  background:rgba(255,255,255,.07);display:flex;align-items:center;justify-content:center;font-size:15px}
.chip .v{display:flex;flex-direction:column;min-width:0}
.chip .v b{font-size:17px;font-weight:800;line-height:19px;font-variant-numeric:tabular-nums}
.chip .v span{font-size:11px;font-weight:600;line-height:13px;color:#b9c3dd}
.chip .plus{width:26px;height:26px;border-radius:8px;margin-left:auto;flex:0 0 26px;
  background:linear-gradient(180deg,#3fd76b,#1f9d46);display:flex;align-items:center;justify-content:center;
  font-size:16px;font-weight:900;color:#04220f}
#who{justify-content:flex-end;margin-left:auto}
#who .dot{width:34px;height:34px;border-radius:50%;flex:0 0 34px;background:linear-gradient(160deg,#6f7ad6,#2c2a55);
  display:flex;align-items:center;justify-content:center;font-weight:900;font-size:15px;
  box-shadow:inset 0 0 0 2px rgba(255,255,255,.18)}
#who .nm{text-align:right;margin-right:6px}
#who .nm b{display:block;font-size:13.5px;font-weight:800}
#who .nm span{display:block;font-size:11px;color:#b9c3dd;font-weight:600}
#who .cv{font-size:13px;color:#9aa6c8}
#who .live{width:8px;height:8px;border-radius:50%;margin-right:2px;background:#3fd76b;box-shadow:0 0 8px #3fd76b}
#who .live.off{background:#8a8fa8;box-shadow:none}
#who .live.unk{background:#6b5b2a;box-shadow:none}
/* ---- the hero ---- */
#hero{position:absolute;left:${RAIL_W + 12}px;top:92px;width:1348px;height:196px;border-radius:16px;overflow:hidden;
  box-shadow:inset 0 0 0 1.5px rgba(150,110,255,.35),0 10px 30px rgba(0,0,0,.45)}
/* The hero's backdrop is the plate's own text-free snowy-night tile, repeated at
   the plate's own scale (background-size:AUTO) and faded out towards the middle,
   so the tile's mountain keeps its own snowline instead of being smeared by a
   background-size:100%. Nothing else from the plate is painted here: a crop that
   carries the plate's own words or figures is not a background. */
#hero .sky{position:absolute;left:0;top:0;width:100px;height:210px;opacity:.75;
  background-image:url(${PLATE_URL});background-size:auto;background-repeat:repeat;
  background-position:-1300px -150px;
  -webkit-mask-image:linear-gradient(90deg,rgba(0,0,0,.95) 0,rgba(0,0,0,.9) 55%,transparent 100%);
  mask-image:linear-gradient(90deg,rgba(0,0,0,.95) 0,rgba(0,0,0,.9) 55%,transparent 100%)}
#hero .art{position:absolute;left:0;top:0;width:168px;height:196px}
#hero .av{position:absolute;left:44px;top:30px;width:132px;height:132px;border-radius:50%;
  background:radial-gradient(circle at 50% 35%,#6a4fd0,#2a1d59 70%);
  display:flex;align-items:center;justify-content:center;font-size:54px;font-weight:900;color:#fff;
  box-shadow:0 0 0 5px #f2b544,0 0 0 8px #b97d18,0 0 22px rgba(242,181,68,.55)}
#hero .ring{position:absolute;left:0;top:0;width:168px;height:196px;pointer-events:none;
  background-image:url(${PLATE});background-repeat:no-repeat;background-position:-372px -92px;
  background-size:170px 190px}
#hero .who{position:absolute;left:196px;top:24px;right:20px}
#hero .who h1{margin:0;font-size:34px;line-height:38px;font-weight:900;letter-spacing:-.4px;
  text-shadow:0 2px 10px rgba(0,0,0,.7);display:flex;align-items:center;gap:10px}
#hero .who h1 .vf{width:22px;height:22px;border-radius:6px;background:#1c9cf0;display:inline-flex;
  align-items:center;justify-content:center;font-size:13px;font-weight:900;color:#fff}
#hero .row2{display:flex;align-items:center;gap:12px;margin-top:6px}
#hero .lv{display:inline-flex;align-items:center;gap:7px;font-size:17px;font-weight:800;
  text-shadow:0 2px 6px rgba(0,0,0,.6)}
#hero .lv i{font-style:normal;font-size:15px;color:#f2b544}
#hero .tag{display:inline-flex;align-items:center;gap:6px;padding:3px 14px;border-radius:9px;
  background:linear-gradient(180deg,#c8102e,#8c0a20);font-size:13px;font-weight:800;
  box-shadow:0 3px 10px rgba(200,16,46,.4)}
#hero .xpbar{margin-top:12px;width:520px}
#hero .xpbar .tr{position:relative;height:22px;border-radius:11px;background:rgba(6,10,30,.72);
  box-shadow:inset 0 0 0 1.5px rgba(120,150,255,.3)}
#hero .xpbar .tr b{position:absolute;left:1.5px;top:1.5px;bottom:1.5px;border-radius:10px;
  background:linear-gradient(180deg,#8bf07a,#2fbf3d 60%,#1d8c2a);box-shadow:0 0 12px rgba(70,220,90,.45)}
#hero .xpbar .tr i{position:absolute;right:12px;top:0;line-height:22px;font-style:normal;font-size:12px;
  font-weight:800;font-variant-numeric:tabular-nums;text-shadow:0 1px 2px #000}
#hero .meta{display:flex;gap:16px;margin-top:10px;font-size:12.5px;font-weight:700;color:#dfe6f6}
#hero .meta span{display:inline-flex;align-items:center;gap:6px;padding:2px 10px;border-radius:7px;
  background:rgba(10,14,40,.62);box-shadow:inset 0 0 0 1px rgba(120,140,220,.22)}
#hero .meta .nc{color:#dcc78e}
#hero .vb{cursor:default}
/* ---- the tab row ---- */
#tabs{position:absolute;left:${RAIL_W + 12}px;top:298px;display:flex;gap:8px}
#tabs .tb{height:48px;min-width:140px;padding:0 15px;border-radius:12px;display:flex;align-items:center;gap:9px;
  font-size:14.5px;font-weight:800;color:#dfe6f6;text-decoration:none;
  background:linear-gradient(180deg,rgba(22,26,64,.95),rgba(12,14,38,.95));
  box-shadow:inset 0 0 0 1.5px rgba(110,120,200,.35)}
#tabs .tb .ic{font-size:15px}
#tabs .tb.off{opacity:.45;color:#9aa6c8;box-shadow:inset 0 0 0 1.5px rgba(110,120,200,.18)}
#tabs .tb.on{background:linear-gradient(180deg,#8a4bf0,#5a1fc0);
  box-shadow:inset 0 0 0 1.5px rgba(200,170,255,.8),0 0 18px rgba(140,80,255,.5)}
/* ---- cards ---- */
.card{position:absolute;border-radius:14px;overflow:hidden;
  background:linear-gradient(180deg,rgba(26,18,58,.96),rgba(14,10,34,.97));
  box-shadow:inset 0 0 0 1.5px rgba(140,110,240,.35),0 10px 26px rgba(0,0,0,.42)}
.card .hd{position:relative;height:40px;display:flex;align-items:center;gap:9px;padding:0 14px;
  background:linear-gradient(180deg,rgba(44,30,92,.95),rgba(26,18,58,.6))}
.card .hd .ic{width:22px;height:22px;border-radius:6px;background:rgba(120,90,220,.28);border:1px solid rgba(160,130,255,.3);display:inline-flex;align-items:center;justify-content:center;font-size:10px;font-weight:900;color:#e2d8ff}
.card .hd b{font-size:15.5px;font-weight:800}
.card .hd:after{content:"";position:absolute;left:0;right:0;bottom:0;height:2px;
  background:linear-gradient(90deg,transparent,rgba(150,110,255,.6),transparent)}
.card .bd{position:relative;padding:10px 14px}
/* summary rows */
.srow{display:flex;align-items:center;gap:9px;height:30px;border-bottom:1px solid rgba(120,110,200,.16)}
.srow:last-child{border-bottom:0}
.srow .k{font-size:12.5px;font-weight:700;color:#cfd6ea;flex:1;display:flex;align-items:center;gap:8px}
.srow .k i{font-style:normal;width:20px;height:20px;border-radius:6px;background:rgba(120,90,220,.18);
  border:1px solid rgba(160,130,255,.22);display:inline-flex;align-items:center;justify-content:center;font-size:10px}
.srow .vxx{font-size:13px;font-weight:800;font-variant-numeric:tabular-nums}
.srow .vxx.g{color:#8bf07a}
.srow .vxx.gold{color:#f2c24a}
em.nc{font-style:normal}
.tile .nc{display:inline-block;color:#e8d9a4;font-weight:800;font-size:10.5px;font-style:normal;
  letter-spacing:.4px;padding:1px 7px;border-radius:6px;background:rgba(120,96,40,.28);
  box-shadow:inset 0 0 0 1px rgba(200,170,90,.35);white-space:nowrap;text-transform:none}
/* frame / badge slots */
.slot{display:flex;flex-direction:column;align-items:center;justify-content:center;height:100%;gap:8px}
.slot .ring{width:150px;height:150px;border-radius:18px;display:flex;align-items:center;justify-content:center;
  font-size:40px;font-weight:900;color:#cfd6ea;
  background:radial-gradient(circle at 50% 30%,rgba(60,40,120,.55),rgba(12,8,28,.9));
  box-shadow:inset 0 0 0 2px rgba(150,110,255,.35)}
.slot .ring.empty{box-shadow:inset 0 0 0 2px rgba(120,110,200,.22);border:2px dashed rgba(150,140,220,.28)}
.slot .nm{font-size:13px;font-weight:800;text-align:center}
.slot .st{margin-top:2px;padding:3px 14px;border-radius:8px;font-size:11.5px;font-weight:800;
  background:linear-gradient(180deg,#3fd76b,#1f9d46);color:#04220f}
.slot .st.none{background:linear-gradient(180deg,#43506e,#2a3350);color:#cdd6ee}
.slot .note{font-size:10.5px;font-weight:600;color:#9aa6c8;text-align:center;padding:0 10px;line-height:13px}
/* tree card */
.treepl{position:absolute;left:10px;top:44px;width:122px;height:140px;border-radius:12px;overflow:hidden}
.treepl .tree{position:absolute;left:0;top:0;width:122px;height:140px}
.tstat{position:absolute;left:142px;top:50px;right:11px}
.tstat .h{display:flex;justify-content:space-between;align-items:baseline;font-size:13px;font-weight:800}
.tstat .h span{color:#8bf07a}
.tstat .tr{position:relative;height:16px;border-radius:8px;background:rgba(6,10,30,.72);
  box-shadow:inset 0 0 0 1.5px rgba(120,150,255,.3);margin-top:6px}
.tstat .tr b{position:absolute;left:1.5px;top:1.5px;bottom:1.5px;border-radius:7px;
  background:linear-gradient(180deg,#8bf07a,#2fbf3d 60%,#1d8c2a)}
.chips{display:flex;gap:6px;margin-top:10px;margin-bottom:42px}
.chips .c b{font-size:12px;font-weight:900}
.chips .c i{font-style:normal;font-size:7.5px;font-weight:700;color:#a9b3d0;margin-top:1px}
.chips .c{min-width:30px;height:32px;padding:0 4px;flex-direction:column;line-height:1;
  border-radius:10px;display:flex;align-items:center;justify-content:center;
  font-size:15px;font-weight:900;background:rgba(80,60,160,.35);box-shadow:inset 0 0 0 1.5px rgba(160,130,255,.4)}
.btn{position:absolute;right:12px;bottom:12px;height:28px;padding:0 12px;border-radius:8px;display:flex;white-space:nowrap;
  align-items:center;gap:6px;font-size:12.5px;font-weight:800;color:#052510;text-decoration:none;
  background:linear-gradient(180deg,#3fd76b,#1f9d46);box-shadow:0 4px 12px rgba(40,180,80,.35)}
.btn.v{background:linear-gradient(180deg,#8a4bf0,#5a1fc0);color:#fff;box-shadow:0 4px 12px rgba(130,70,240,.4)}
/* stats row */
.stat{flex:1;border-radius:12px;padding:9px 10px;text-align:center;
  background:linear-gradient(180deg,rgba(40,28,86,.85),rgba(18,12,42,.92));
  box-shadow:inset 0 0 0 1.5px rgba(140,110,240,.28)}
.stat .em{font-size:15px}
.stat .L{font-size:11px;font-weight:700;color:#c2cae0;margin-top:2px}
.stat .V{font-size:19px;font-weight:900;font-variant-numeric:tabular-nums;margin-top:1px}

.stat .V.g{color:#8bf07a}
.stat .V.gold{color:#f2c24a}
/* achievement tiles */
.tiles{display:flex;gap:10px}
.tile{position:relative;width:88px;height:136px;border-radius:12px;overflow:hidden;
  background:linear-gradient(180deg,rgba(50,34,96,.9),rgba(16,10,36,.95));
  box-shadow:inset 0 0 0 1.5px rgba(140,110,240,.3)}
.tile.on{box-shadow:inset 0 0 0 2px rgba(242,194,74,.85),0 0 16px rgba(242,194,74,.3)}
.tile .em{position:absolute;left:0;right:0;top:26px;text-align:center;font-size:30px;filter:grayscale(1) brightness(.55)}
.tile.on .em{filter:none}
.tile .nm{position:absolute;left:4px;right:4px;bottom:8px;text-align:center;font-size:10.5px;line-height:13px;
  font-weight:800;color:#e6ebf7}
.tile .lk{position:absolute;right:5px;top:5px;font-size:9px;font-weight:800;color:#9aa6c8}
.nc{color:#e8d9a4;font-weight:800}
`.trim()

// ----------------------------------------------------------------- helpers ---
function pad2(n) { return n < 10 ? "0" + n : String(n) }

// The rail: the same list every page draws (src/panel/nav.js is the data).
function railHtml(activeKey) {
  const out = [`<nav id="rail" aria-label="Panel">
  <div class="brand"><b>FreeNova</b><i>WINTERFEST 2026</i></div>`]
  let y = 78
  for (const g of NAV_GROUPS) {
    out.push(`<div class="grp" style="top:${y}px">${esc(g.title)}</div>`)
    y += 22
    for (const it of g.items) {
      const on = it.key === activeKey ? " on" : ""
      const href = it.key === activeKey ? "" : ` href="/panel/${it.key}"`
      const tag = it.key === activeKey ? "span" : "a"
      out.push(`<${tag} class="it${on}"${href} style="top:${y}px">` +
        `<span class="ic">${esc(it.icon.slice(0, 2).toUpperCase())}</span>` +
        `<span class="tx"><b>${esc(it.label)}</b><span>${esc(it.sub)}</span></span></${tag}>`)
      y += 46
    }
    y += 8
  }
  out.push(`</nav>`)
  return out.join("\n")
}

function topBar(p, presence, now) {
  const known = p && p.exists
  const lvl = known ? numOr(p.level) : null
  const live = !presence || !presence.known ? "unk" : (presence.online ? "" : " off")
  const liveTitle = !presence || !presence.known ? "The panel has not heard from the game yet"
    : presence.online ? "On the server as of the last snapshot (" + stampText(presence.pushed_at) + ")"
      : "Not in the last snapshot (" + stampText(presence.pushed_at) + ")"
  return `<header id="top">
  <div class="chip"><span class="em">🪙</span><span class="v"><b>${known ? show(p.coins) : "—"}</b><span>Coins</span></span><span class="plus">+</span></div>
  <div class="chip"><span class="em">🍪</span><span class="v"><b>${known ? show(p.gingerbread) : "—"}</b><span>GingerBread</span></span><span class="plus">+</span></div>
  <div class="chip"><span class="em">🎲</span><span class="v"><b>${known ? show(p.spins) : "—"}</b><span>Spins</span></span><span class="plus">+</span></div>
  <div class="chip"><span class="em">📋</span><span class="v"><b>${known ? show(p.pass ? p.pass.tier : null) : "—"}</b><span>Pass tier</span></span><span class="plus">+</span></div>
  <div id="who" class="chip">
    <span class="live${live}" title="${esc(liveTitle)}"></span>
    <span class="nm"><b>${known && p.name ? esc(p.name) : "No player"}</b><span>${lvl == null ? NOT_COLLECTED : "Level " + fmt(lvl)}</span></span>
    <span class="dot">${known && p.name ? esc(String(p.name).slice(0, 1).toUpperCase()) : "?"}</span>
    <span class="cv">▾</span>
  </div>
</header>`
}

// ------------------------------------------------------------------- page ----
export async function pageProfile(env, url) {
  const now = Math.floor(Date.now() / 1000)
  const minted = url && url._fnMotdSid
  const raw = (minted && String(minted)) || (url && url.searchParams.get("steamid")) || ""
  const sidIn = /^STEAM_[0-9]:[0-9]:\d+$/.test(String(raw).trim()) ? String(raw).trim() : ""
  const d = await loadProfile(env, sidIn, now)
  return new Response(renderProfile(d), {
    status: 200,
    headers: {
      "content-type": "text/html; charset=utf-8",
      "cache-control": "no-store",
      "x-content-type-options": "nosniff"
    }
  })
}

/** One fixed set of reads; nothing runs in a loop and nothing writes. */
export async function loadProfile(env, sid, now) {
  const out = { sid, now, known: false, p: null, presence: null, tree: null, unlocks: [], cosmetic: null,
    rarest: null, medals: [], ledger: [] }
  if (!sid || !env || !env.DB) return out
  let p = null
  try { p = await getPlayer(env.DB, sid) } catch { p = null }
  out.p = p
  out.known = !!(p && p.exists)
  try { out.presence = await presence(env.DB, sid, { now }) } catch {}
  if (!out.known) return out
  try { out.tree = await treeSlots(env.DB, sid) } catch {}
  try { out.unlocks = await recentUnlocks(env.DB, sid, { limit: 12 }) } catch {}
  try { out.cosmetic = await equippedCosmetics(env.DB, sid) } catch {}
  try { out.rarest = await rarestOrnament(env.DB, sid) } catch {}
  try { out.medals = await badgeHoldings(env.DB, sid, { limit: 12 }) } catch {}
  // "Recent Achievements" is the plate's right-hand bottom card: the newest
  // things the panel actually granted, newest first.
  try { out.ledger = await recentLedger(env.DB, sid, { limit: 6 }) } catch {}
  return out
}

function statCell(em, label, value, cls) {
  return `<div class="stat"><div class="em">${em}</div><div class="L">${esc(label)}</div>` +
    `<div class="V${cls ? " " + cls : ""}">${value}</div></div>`
}

export function renderProfile(d) {
  const { sid, known, p, presence: pres, tree, unlocks, cosmetic, rarest, medals, now } = d
  const counts = (p && p.counts) || {}
  const name = known && p.name ? String(p.name) : ""
  const level = known ? numOr(p.level) : null
  const xp = known ? numOr(p.xp) : null

  // ---- hero identity ----
  // rank_id and eq_model ride getPlayer() (page-driven addition, 01-DATA.md §11).
  const rankId = known ? numOr(p.rank_id) : null
  const rankLabel = rankId != null && rankId > 0 ? rankName(rankId) : null
  const xpCap = 40000
  const xpPct = xp == null ? null : Math.max(0, Math.min(100, Math.round((xp * 100) / xpCap)))
  const model = known && p.eq_model ? String(p.eq_model) : (known ? "default team model" : "—")

  const initial = name ? esc(name.slice(0, 1).toUpperCase()) : "?"

  const hero = `<section id="hero">
  <div class="sky" title=""></div>
  <div class="av">${initial}</div>
  <div class="ring"></div>
  <div class="who">
    <h1>${name ? esc(name) : "No player"}${known ? '<span class="vf" title="Verified SteamID">✓</span>' : ""}</h1>
    <div class="row2">
      <span class="lv"><i>♛</i>${level == null ? NOT_COLLECTED : "Level " + fmt(level)}</span>
      <span class="tag">❄ ${esc(rankLabel || (known ? "Rank not collected" : "Rank not collected"))} ❄</span>
    </div>
    <div class="xpbar"><div class="tr"><b style="width:${xpPct == null ? 0 : xpPct}%"></b>` +
      `<i>${xp == null ? NOT_COLLECTED : fmt(xp) + " XP"}</i></div></div>
    <div class="meta">
      <span title="SteamID">${sid ? esc(sid) : "—"}${steam64(sid) ? " · " + esc(steam64(sid)) : ""}</span>
      <span class="nc" title="The panel holds no registration date for a player (docs/panel/01-DATA.md §11)">Membership: not collected</span>
      <span title="The equipped player model the game pushed">Model: ${esc(model)}</span>
    </div>
  </div>
</section>`

  // ---- the tab row (the plate's own seven tabs) ----
  // A tab is a LINK only when the panel really has that page: a pill that looks
  // clickable and goes nowhere is the same lie as a figure nothing wrote. Today
  // that is Overview (this page) and Rankstats (the statistics page).
  const tabs = [
    ["Overview", "⌂", "/panel/profile"], ["Rankstats", "◫", "/panel/rankstats"],
    ["Top 15", "★", "/panel/top15"], ["Battle Pass", "♦", "/panel/battlepass"],
    ["Achievements", "❖", "/achievements"], ["Frames", "▣", ""], ["Tree", "🌲", ""]
  ]
  const tabRow = `<nav id="tabs">` + tabs.map(([t, ic, href]) => {
    const on = href === "/panel/profile"
    if (!href) return `<span class="tb off" title="Not built yet"><span class="ic">${ic}</span>${esc(t)}</span>`
    if (on) return `<span class="tb on"><span class="ic">${ic}</span>${esc(t)}</span>`
    return `<a class="tb" href="${href}"><span class="ic">${ic}</span>${esc(t)}</a>`
  }).join("") + `</nav>`

  // ---- card 1: player summary ----
  const cell = (k, icon, v, cls) =>
    `<div class="srow"><span class="k"><i>${icon}</i>${esc(k)}</span><span class="vxx${cls ? " " + cls : ""}">${v === "Not collected" ? `<em class="nc">${NOT_COLLECTED}</em>` : v}</span></div>`
  const summary = `<section class="card" style="left:308px;top:358px;width:384px;height:228px">
    <div class="hd"><span class="ic">♛</span><b>Player Summary</b></div>
    <div class="bd">
      ${cell("Level", "▲", level == null ? NOT_COLLECTED : fmt(level), level == null ? "nc" : "")}
      ${cell("XP", "★", xp == null ? NOT_COLLECTED : fmt(xp), xp == null ? "nc" : "gold")}
      ${cell("Rank", "FN", esc(rankLabel || "Not collected"), rankLabel ? "gold" : "nc")}
      ${cell("Coins", "🪙", known ? show(p.coins) : NOT_COLLECTED, "")}
      ${cell("GingerBread", "🍪", known ? show(p.gingerbread) : NOT_COLLECTED, "")}
      ${cell("Spins", "🎲", known ? show(p.spins) : NOT_COLLECTED, "")}
    </div>
  </section>`

  // ---- card 2: current frame (no frame vocabulary exists - say so) ----
  const frame = `<section class="card" style="left:702px;top:358px;width:344px;height:228px">
    <div class="hd"><span class="ic">🖼</span><b>Current Frame</b></div>
    <div class="bd" style="height:180px">
      <div class="slot">
        <div class="ring empty">∅</div>
        <div class="nm">No frame equipped</div>
        <div class="note">Frames are not an item kind the panel owns yet — this card stays empty rather than guess.</div>
        <div class="st none">Not collected</div>
      </div>
    </div>
  </section>`

  // ---- card 3: current badge / title ----
  const badge = cosmetic && cosmetic.badge ? cosmetic.badge.item : (cosmetic && cosmetic.title ? cosmetic.title.item : null)
  const badgeLabel = badge ? badge.replace(/^(badge|title):/, "").replace(/_/g, " ") : ""
  const badgeCard = `<section class="card" style="left:1056px;top:358px;width:304px;height:228px">
    <div class="hd"><span class="ic">🎖</span><b>Current Badge</b></div>
    <div class="bd" style="height:180px">
      <div class="slot">
        <div class="ring${badge ? "" : " empty"}">${badge ? "🎖" : "∅"}</div>
        <div class="nm">${badge ? esc(badgeLabel) : "Nothing equipped"}</div>
        <div class="st${badge ? "" : " none"}">${badge ? "✓ Equipped" : (cosmetic && cosmetic.counts && cosmetic.counts.all ? "Unequipped" : "None owned")}</div>
      </div>
    </div>
  </section>`

  // ---- card 4: my Christmas tree ----
  const filled = tree ? tree.filled : null
  const cap = tree ? tree.capacity : null
  const treePct = filled != null && cap ? Math.round((filled / cap) * 100) : null
  const treeLevel = known ? numOr(p.tree && p.tree.level) : null
  const ornamentsTotal = known ? numOr(counts.ornaments_total) : null
  const treeCard = `<section class="card" style="left:1370px;top:358px;width:290px;height:228px">
    <div class="hd"><span class="ic">🌲</span><b>My Christmas Tree</b></div>
    <div class="treepl">
      <div class="tree bg" style="background-position:-388px -284px;background-size:122px 140px"></div>
    </div>
    <div class="tstat">
      <div class="h">Tree Level <span>${treeLevel == null ? "—" : fmt(treeLevel)}</span></div>
      <div class="tr"><b style="width:${treePct == null ? 0 : treePct}%"></b></div>
      <div class="chips">
        <div class="c" title="Ornaments owned"><b>${ornamentsTotal == null ? "—" : fmt(ornamentsTotal)}</b><i>owned</i></div>
        <div class="c" title="Ornaments placed on the tree"><b>${filled == null ? "—" : fmt(filled)}</b><i>placed</i></div>
        <div class="c" title="GingerBread"><b>${known ? fmt(p.gingerbread) : "—"}</b><i>GB</i></div>
        <div class="c" title="Advent days claimed"><b>${known ? fmt(counts.advent_claimed || 0) : "—"}</b><i>/ 24</i></div>
      </div>
      <a class="btn" href="/panel/advent">View My Tree →</a>
    </div>
  </section>`

  // ---- bottom left: season statistics ----
  // Every figure is the player's own career counters from `players`. A counter
  // the panel does not hold is "Not collected" - never a 0.
  const career = (known && p && p.career) || {}
  const k = numOr(career.kills)
  const deaths = numOr(career.deaths)
  const wins = numOr(career.wins)
  const losses = numOr(career.losses)
  const matches = knowsNum(wins) && knowsNum(losses) ? wins + losses : null
  const ncCell = v => v == null ? `<span class="vxx nc">${NOT_COLLECTED}</span>` : fmt(v)
  const stats = `<section class="card" style="left:308px;top:596px;width:740px;height:200px">
    <div class="hd"><span class="ic">📊</span><b>Season Statistics (Winterfest)</b></div>
    <div class="bd" style="display:flex;gap:10px;height:140px;align-items:stretch">
      ${statCell("🎯", "Kills", ncCell(k))}
      ${statCell("💀", "Deaths", ncCell(deaths))}
      ${statCell("🏆", "K/D", deaths ? kdText(k, deaths) : `<span class="vxx nc">${NOT_COLLECTED}</span>`)}
      ${statCell("🎮", "Matches", ncCell(matches))}
      ${statCell("♛", "Wins", ncCell(wins), "gold")}
      ${statCell("📈", "Winrate", matches ? pctText(wins, matches) : `<span class="vxx nc">${NOT_COLLECTED}</span>`, "g")}
    </div>
  </section>`

  // ---- bottom right: recent achievements ----
  // The plate's five tiles, lit only when the player holds the matching medal
  // (badges, from boards.js) or the matching unlock (ap_unlocks).
  const heldKinds = new Set((medals || []).map(m => m.kind))
  const heldCodes = new Set((unlocks || []).map(u => u.code))
  const tiles = MEDAL_ROW.map(med => {
    const on = med.kinds.some(x => heldKinds.has(x)) || med.unlocks.some(x => heldCodes.has(x))
    return `<div class="tile${on ? " on" : ""}"><span class="lk">${on ? "✓" : "·"}</span>` +
      `<div class="em">❄</div><div class="nm">${esc(med.name)}</div></div>`
  }).join("")
  const ach = `<section class="card" style="left:1056px;top:596px;width:604px;height:200px">
    <div class="hd"><span class="ic">🏆</span><b>Recent Achievements</b></div>
    <div class="bd" style="height:140px;display:flex;flex-direction:column;justify-content:center;gap:8px">
      <div class="tiles">${tiles}</div>
      <div style="font-size:11px;font-weight:600;color:#9aa6c8">
        ${(unlocks && unlocks.length)
          ? "Newest unlock: " + esc(AP_NAMES[unlocks[0].code] || unlocks[0].code.replace(/_/g, " ")) + " · " + agoText(unlocks[0].earned_at, now)
          : "No achievement date recorded for this player yet."}
      </div>
    </div>
  </section>`

  const stage = `<div id="stage" data-page="profile">
  <div id="railbg"></div>
  ${railHtml("profile")}
  ${topBar(known ? p : null, pres, now)}
  ${hero}
  ${tabRow}
  ${summary}
  ${frame}
  ${badgeCard}
  ${treeCard}
  ${stats}
  ${ach}
</div>`

  return `<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>FreeNova · Winterfest profile${name ? " · " + esc(name) : ""}</title>
<style>${CSS}</style></head>
<body>${stage}
<script>${fitScript(PROFILE_W, PROFILE_H)}</script>
</body></html>`
}

function knowsNum(v) { return typeof v === "number" && Number.isFinite(v) }

