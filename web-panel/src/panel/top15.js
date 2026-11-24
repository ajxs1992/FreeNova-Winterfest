// FreeNova panel — the WINTERFEST TOP 15 (the rail's "Top 15: Christmas
// leaderboard", docs/panel/00-CONTRACT.md).
//
// WHAT IT IS
//   The plate's whole ladder in one screen: the podium of the top three on the
//   XP board, then the rest of the fifteen as rows, with the player's own place
//   pinned beneath - because a ladder that only shows the top is useless to
//   everyone who is not on it.
//
// WHERE THE ROWS COME FROM
//   src/query.js boardPlacings({metric}) - one ORDER BY per board, the same one
//   boards.js uses, so the page and the board cannot disagree. Every figure is
//   the value the board is ordered by (lifetime XP, or kills); nothing is
//   estimated and no prize is promised - the panel does not decide awards.
import { boardPlacings, myPlacement } from "../query.js"
import { rankName } from "../ranks.js"
import { NAV_GROUPS } from "./nav.js"
import { fitScript, PLATE_URL, plateDigest, fragEsc as esc, thousands as fmt, numOr,
  NOT_COLLECTED, stampText } from "./kit.js"

export const TOP15_W = 1672, TOP15_H = 941
const RAIL_W = 292

const BOARDS = [
  { key: "xp", label: "Lifetime XP", unit: "XP" },
  { key: "kills", label: "Kills", unit: "kills" }
]

const CSS = `
@font-face{font-family:'Nunito';src:url('/assets/fonts/Nunito-Variable.ttf') format('truetype-variations');
  font-weight:200 1000;font-display:swap}
*{box-sizing:border-box}
html,body{margin:0;padding:0;width:100%;height:100%;background:#07040f;overflow:hidden}
body{font-family:Nunito,'Trebuchet MS','Segoe UI',Cantarell,Arial,sans-serif;color:#fff;-webkit-font-smoothing:antialiased}
#stage{position:absolute;left:0;top:0;width:${TOP15_W}px;height:${TOP15_H}px;overflow:hidden;transform-origin:0 0;
  will-change:transform;scale:min(calc(100vw / ${TOP15_W}), calc(100vh / ${TOP15_H}), 1);
  background:#0b0716 radial-gradient(120% 80% at 50% 0,#2a1152 0,#120a26 55%,#0a0616 100%)}
#rail{position:absolute;left:0;top:0;width:${RAIL_W}px;height:${TOP15_H}px;
  background:linear-gradient(180deg,rgba(20,10,42,.94),rgba(12,6,28,.96));border-right:1px solid rgba(150,110,255,.18)}
#rail .brand{position:absolute;left:24px;top:14px;width:244px;height:52px;display:flex;align-items:center;gap:9px}
#rail .brand b{font-size:26px;font-weight:900;letter-spacing:-.4px;background:linear-gradient(180deg,#fff,#cfe3ff 60%,#8fb6ff);
  -webkit-background-clip:text;background-clip:text;color:transparent}
#rail .brand i{flex:1;height:20px;border-radius:10px;background:linear-gradient(180deg,#c8102e,#8c0a20);font-style:normal;
  display:flex;align-items:center;justify-content:center;font-size:9px;font-weight:900;letter-spacing:1.1px}
#rail .grp{position:absolute;left:22px;width:248px;height:16px;font-size:9.5px;font-weight:800;letter-spacing:2.2px;
  color:#8f9ec4;text-transform:uppercase;display:flex;align-items:center;gap:8px}
#rail .grp:before,#rail .grp:after{content:"";height:1px;flex:1;background:linear-gradient(90deg,transparent,#4a3a7a,transparent)}
#rail a.it{position:absolute;left:12px;width:268px;height:44px;display:flex;align-items:center;gap:8px;padding:0 10px 0 8px;
  border-radius:12px;text-decoration:none;color:inherit}
#rail a.it .ic{width:26px;height:26px;flex:0 0 26px;border-radius:8px;background:rgba(120,90,220,.16);
  border:1px solid rgba(160,130,255,.22);display:flex;align-items:center;justify-content:center;font-size:10px;font-weight:900;color:#c9b8ff}
#rail a.it .tx{flex:1;min-width:0}
#rail a.it .tx b{display:block;font-size:13.5px;font-weight:800;line-height:15px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
#rail a.it .tx span{display:block;font-size:9px;font-weight:600;line-height:11px;color:#95a1c2;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
#rail a.it.on{background:linear-gradient(90deg,rgba(120,70,240,.55),rgba(80,40,170,.18));
  box-shadow:inset 0 0 0 1.5px rgba(180,140,255,.75),0 0 18px rgba(130,80,255,.35)}
#top{position:absolute;left:${RAIL_W}px;top:0;right:0;height:76px;display:flex;align-items:center;gap:14px;padding:12px 16px 0}
#top h1{margin:0;font-size:26px;font-weight:900;letter-spacing:.4px}
#top .kick{font-size:11px;font-weight:800;letter-spacing:2.4px;color:#9fb0d6;text-transform:uppercase}
.switch{margin-left:auto;display:flex;gap:8px}
.switch a{padding:8px 16px;border-radius:10px;text-decoration:none;color:#dfe6f6;font-size:13px;font-weight:800;
  background:linear-gradient(180deg,rgba(22,26,64,.95),rgba(12,14,38,.95));box-shadow:inset 0 0 0 1.5px rgba(110,120,200,.35)}
.switch a.on{background:linear-gradient(180deg,#8a4bf0,#5a1fc0);box-shadow:inset 0 0 0 1.5px rgba(200,170,255,.8)}
.card{position:absolute;border-radius:14px;overflow:hidden;background:linear-gradient(180deg,rgba(26,18,58,.96),rgba(14,10,34,.97));
  box-shadow:inset 0 0 0 1.5px rgba(140,110,240,.35),0 10px 26px rgba(0,0,0,.42)}
.card .hd{position:relative;height:38px;display:flex;align-items:center;gap:9px;padding:0 14px;
  background:linear-gradient(180deg,rgba(44,30,92,.95),rgba(26,18,58,.6))}
.card .hd .ic{width:20px;height:20px;border-radius:6px;background:rgba(120,90,220,.28);border:1px solid rgba(160,130,255,.3);
  display:inline-flex;align-items:center;justify-content:center;font-size:9.5px;font-weight:900;color:#e2d8ff}
.card .hd b{font-size:15px;font-weight:800}
.card .hd:after{content:"";position:absolute;left:0;right:0;bottom:0;height:2px;
  background:linear-gradient(90deg,transparent,rgba(150,110,255,.6),transparent)}
.podium{position:absolute;left:${RAIL_W + 12}px;top:90px;width:1368px;height:292px;border-radius:16px;overflow:hidden;
  box-shadow:inset 0 0 0 1.5px rgba(150,110,255,.35),0 10px 30px rgba(0,0,0,.45)}
/* The podium's night field is PAINTED, not cropped. Every text-free square of the
   hero on the plate is only tile-sized (40x40): repeated across a 1368 band it
   reads as wallpaper, and every larger crop of the hero carries a sample word.
   A gradient cannot lie about a number, so the band is a gradient. */
.podium{background:
  radial-gradient(120% 150% at 50% 0,rgba(96,56,190,.55) 0,rgba(40,22,92,.9) 55%,rgba(18,10,42,.98) 100%)}
.pod{position:absolute;bottom:0;width:330px;text-align:center;display:flex;flex-direction:column;align-items:center;
  justify-content:flex-end;padding-bottom:26px}
.pod .av{width:86px;height:86px;border-radius:50%;display:flex;align-items:center;justify-content:center;font-size:32px;
  font-weight:900;background:radial-gradient(circle at 50% 35%,#6a4fd0,#2a1d59 70%);box-shadow:inset 0 0 0 3px rgba(255,255,255,.2)}
.pod .nm{font-size:18px;font-weight:900;margin-top:10px;max-width:100%;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.pod .vv{font-size:22px;font-weight:900;font-variant-numeric:tabular-nums;margin-top:2px}
.pod .cr{font-size:12px;font-weight:700;color:#c2cae0;margin-top:4px}
.pod .medal{position:absolute;top:6px;width:44px;height:44px;border-radius:50%;left:50%;transform:translateX(-50%);
  display:flex;align-items:center;justify-content:center;font-size:22px;font-weight:900;color:#241a06;
  box-shadow:0 4px 14px rgba(0,0,0,.45),inset 0 0 0 2px rgba(255,255,255,.35)}
.pod .m1{background:linear-gradient(180deg,#ffe08a,#e8a319)}
.pod .m2{background:linear-gradient(180deg,#f2f6ff,#aeb9cf)}
.pod .m3{background:linear-gradient(180deg,#f3c39a,#b9763f)}
.pod .base{position:absolute;left:0;right:0;bottom:0;height:74px;border-radius:12px 12px 0 0;
  background:linear-gradient(180deg,rgba(120,90,220,.5),rgba(40,26,90,.9));box-shadow:inset 0 0 0 1.5px rgba(170,140,255,.5)}
.pod.p1{left:559px;height:292px}.pod.p1 .av{width:104px;height:104px;font-size:40px;box-shadow:0 0 0 4px #f2b544,0 0 22px rgba(242,181,68,.6)}
.pod.p1 .base{height:100px;background:linear-gradient(180deg,rgba(242,181,68,.55),rgba(90,60,16,.9));box-shadow:inset 0 0 0 1.5px rgba(255,214,120,.7)}
.pod.p2{left:210px;height:250px}.pod.p3{left:896px;height:250px}
.pod .vv.gold{color:#f2c24a}.pod .vv.silver{color:#dfe6f6}.pod .vv.bronze{color:#e2a06a}
table.b{width:100%;border-collapse:collapse;font-size:14px}
table.b th{text-align:left;font-size:10.5px;letter-spacing:1.1px;text-transform:uppercase;color:#9fb0d6;font-weight:800;
  padding:6px 12px;border-bottom:1px solid rgba(140,110,240,.28)}
table.b td{padding:8px 12px;border-bottom:1px solid rgba(120,110,200,.13);font-weight:700;font-variant-numeric:tabular-nums}
table.b td.r{width:64px;font-weight:900;color:#f2c24a}
table.b td.n{text-align:right}
table.b td.p{font-weight:900}
table.b tr.me{background:rgba(120,70,240,.28)}
.empty{font-size:13px;font-weight:700;color:#b7a26a;font-style:italic;padding:16px}
.mine{font-size:13.5px;font-weight:800}
.mine .big{font-size:26px;font-weight:900;color:#f2c24a}
`.trim()

function railHtml(active) {
  const out = [`<nav id="rail" aria-label="Panel"><div class="brand"><b>FreeNova</b><i>WINTERFEST 2026</i></div>`]
  let y = 76
  for (const g of NAV_GROUPS) {
    out.push(`<div class="grp" style="top:${y}px">${esc(g.title)}</div>`)
    y += 22
    for (const it of g.items) {
      const on = it.key === active
      const tag = on ? "span" : "a"
      out.push(`<${tag} class="it${on ? " on" : ""}"${on ? "" : ` href="/panel/${it.key}"`} style="top:${y}px">` +
        `<span class="ic">${esc(it.icon.slice(0, 2).toUpperCase())}</span>` +
        `<span class="tx"><b>${esc(it.label)}</b><span>${esc(it.sub)}</span></span></${tag}>`)
      y += 46
    }
    y += 8
  }
  return out.join("\n") + `</nav>`
}

// --------------------------------------------------------------- the data ----
export async function loadTop15(env, sid, now, metric) {
  const board = metric === "kills" ? "kills" : "xp"
  const out = { sid, now, board, rows: [], mine: null, seen: 0 }
  if (!env || !env.DB) return out
  try { out.rows = await boardPlacings(env.DB, { metric: board, limit: 15 }) } catch { out.rows = [] }
  if (sid) {
    try { out.mine = board === "xp" ? await myPlacement(env.DB, sid) : await myKillPlacement(env.DB, sid) } catch { out.mine = null }
  }
  return out
}

// myPlacement() is the XP board's own arithmetic; the kills board needs the same
// three queries against players.kills. It lives here, next to the page that asks.
async function myKillPlacement(db, sid) {
  const rows = await db.prepare(`SELECT name, kills FROM players WHERE steamid=?1`).bind(sid).all()
  const me = (rows && rows.results && rows.results[0]) || null
  if (!me) return { known: false, rank: null, value: null, name: "", total: 0 }
  const value = Number(me.kills || 0)
  const ahead = await db.prepare(`SELECT COUNT(*) AS n FROM players WHERE kills > ?1`).bind(value).first()
  const total = await db.prepare(`SELECT COUNT(*) AS n FROM players WHERE kills > 0`).first()
  return {
    known: true,
    rank: value > 0 ? Number((ahead && ahead.n) || 0) + 1 : null,
    value,
    name: String(me.name || ""),
    total: Number((total && total.n) || 0)
  }
}

const ORDINAL = ["", "1st", "2nd", "3rd"]

export function renderTop15(d) {
  const { board, rows, mine, sid, now } = d
  const meta = BOARDS.find(b => b.key === board) || BOARDS[0]
  const valueOf = r => (board === "kills" ? r.value : r.value)
  const label = r => (board === "kills" ? "kills" : "XP")

  const top3 = rows.slice(0, 3)
  // Every one of the fifteen in the table, in the board's own order: a ladder that
  // shows four rows under a podium of three leaves places unaccounted for.
  const rest = rows.slice()
  const mineValue = mine && mine.known ? (board === "kills" ? mine.value : mine.xp) : null
  const mineRank = mine && mine.known ? mine.rank : null
  const inTable = sid && rows.some(r => r.steamid === sid)

  const pod = (r, i) => {
    const cls = ["p1", "p2", "p3"][i]
    const vv = ["gold", "silver", "bronze"][i]
    const initial = r && r.name ? esc(String(r.name).slice(0, 1).toUpperCase()) : "?"
    return `<div class="pod ${cls}">
      <div class="base"></div>
      <span class="medal m${i + 1}">${i + 1}</span>
      <div class="av">${initial}</div>
      <div class="nm">${r ? esc(r.name || r.steamid) : "—"}</div>
      <div class="vv ${vv}">${r ? fmt(valueOf(r)) : "—"}</div>
      <div class="cr">${r ? esc(label(r)) : ""}${r && r.level ? " · Lv " + fmt(r.level) : ""}</div>
    </div>`
  }

  const podium = `<section class="podium">
    <div class="sky"></div>

    ${pod(top3[1], 1)}
    ${pod(top3[0], 0)}
    ${pod(top3[2], 2)}
  </section>`

  const body = rest.map(r => `<tr class="${sid && r.steamid === sid ? "me" : ""}">
    <td class="r">#${r.rank}</td>
    <td class="p">${esc(r.name || r.steamid)}${r.cc ? ` <span style="opacity:.6;font-weight:700">${esc(r.cc)}</span>` : ""}</td>
    <td class="n">${fmt(valueOf(r))} ${esc(label(r))}</td>
  </tr>`).join("")

  const table = `<section class="card" style="left:${RAIL_W + 12}px;top:396px;width:940px;height:532px">
    <div class="hd"><span class="ic">T15</span><b>Top 15 · ${esc(meta.label)}</b></div>
    ${rows.length ? `<table class="b"><thead><tr><th style="width:64px">#</th><th>Player</th>
      <th style="text-align:right">${esc(meta.label)}</th></tr></thead><tbody>${body}</tbody></table>
      ${rows.length < 15 ? `<div class="empty" style="padding:10px 12px">Only ${rows.length} ${rows.length === 1 ? "player has" : "players have"} a score on this board — the panel shows what exists rather than fill the rest.</div>` : ""}`
      : `<div class="empty">No player has a score on this board yet.</div>`}
  </section>`

  const mineCard = `<section class="card" style="left:${RAIL_W + 964}px;top:402px;width:392px;height:260px">
    <div class="hd"><span class="ic">ME</span><b>Your place</b></div>
    <div style="padding:16px 18px" class="mine">
      ${!sid ? `<div class="empty">No player was identified for this visit.</div>`
        : !mine || !mine.known ? `<div class="empty">This player is not in the panel's table yet.</div>`
          : `${mineRank && mineRank > 15 ? `<div style="font-size:12.5px;font-weight:800;color:#93a0c0">Not in the fifteen shown — place #${fmt(mineRank)} of ${fmt(mine.total)}.</div>` : ""}
        <div style="margin-top:10px">Place <span class="big">${mineRank ? "#" + fmt(mineRank) : "—"}</span></div>
        <div style="margin-top:6px">${mineValue == null ? NOT_COLLECTED : fmt(mineValue) + " " + esc(label())}</div>
        <div style="margin-top:10px;font-size:11.5px;font-weight:700;color:#93a0c0">
          ${mine.total ? fmt(mine.total) + " players have a score on this board." : "No player has a score on this board yet."}
          The place is counted, not estimated: everyone ahead of you, plus one.
        </div>`}
    </div>
  </section>`

  const rules = `<section class="card" style="left:${RAIL_W + 964}px;top:674px;width:392px;height:254px">
    <div class="hd"><span class="ic">RU</span><b>How this board works</b></div>
    <div style="padding:14px 18px;font-size:12.5px;font-weight:700;line-height:20px;color:#cfd6ea">
      Every row is a player the game has pushed a snapshot for. The figure is the one the board is ordered by
      (${esc(meta.label.toLowerCase())}) and it is never recomputed here.<br><br>
      The panel keeps no prize table for this board, so this page promises none. A reward is the game's to grant.
      <div style="margin-top:12px;font-size:11px;font-weight:700;color:#93a0c0">Read at ${esc(stampText(now))}.</div>
    </div>
  </section>`

  return `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>FreeNova · Winterfest Top 15</title>
<style>${CSS}</style></head>
<body><div id="stage" data-page="top15">
${railHtml("top15")}
<header id="top">
  <div><div class="kick">Leaderboard · Winterfest</div><h1>Top 15</h1></div>
  <div class="switch">
    ${BOARDS.map(b => `<a class="${b.key === board ? "on" : ""}" href="/panel/top15?board=${b.key}">${esc(b.label)}</a>`).join("")}
  </div>
</header>
${podium}
${table}
${mineCard}
${rules}
</div>
<script>${fitScript(TOP15_W, TOP15_H)}</script>
</body></html>`
}

/** The route: /panel/top15 (and ?board=kills). */
export async function pageTop15(env, url) {
  const now = Math.floor(Date.now() / 1000)
  const minted = url && url._fnMotdSid
  const raw = (minted && String(minted)) || (url && url.searchParams.get("steamid")) || ""
  const sid = /^STEAM_[0-9]:[0-9]:\d+$/.test(String(raw).trim()) ? String(raw).trim() : ""
  const board = (url && url.searchParams.get("board")) === "kills" ? "kills" : "xp"
  const d = await loadTop15(env, sid, now, board)
  return new Response(renderTop15(d), {
    status: 200,
    headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store", "x-content-type-options": "nosniff" }
  })
}
