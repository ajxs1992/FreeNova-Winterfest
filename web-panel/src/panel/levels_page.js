// The Levels page (/panel/levels) - the plate's own "Progress & rewards" entry.
//
// WHAT IT SHOWS, AND WHAT IT REFUSES TO SHOW
// Every figure is read from state the panel already owns: `players` for the rank
// ladder and XP (the same ladder the HUD reads, src/ranks.js), `winter_players`
// for the pass XP/tier and the tree, and `winter_ledger` for the XP-shaped
// history. A value the database does not carry prints "Not collected", and a
// page with no player says so and links back - never a zero dressed as data.
//
// The page does NOT print "reward for reaching level N": no season config maps a
// level to a reward, so such a line would be an invented promise. The rank rungs
// ARE printed, because src/ranks.js is the authoritative ladder.
import { getPlayer, passTierXp, PASS_MAX_TIER } from "../state.js"
import { recentLedger } from "../query.js"
import { rankName, rankProgress, RANKS, RANK_XP } from "../ranks.js"
import { NAV_GROUPS } from "./nav.js"
import { fitScript, PLATE_URL, fragEsc as esc, thousands as fmt, numOr, NOT_COLLECTED } from "./kit.js"

export const LEVELS_W = 1672, LEVELS_H = 941
const RAIL_W = 300

// ---------------------------------------------------------------- the maths --
// (pure and exported: the harness proves them without a browser)

/** The next row of the rank ladder, or null at the top of it. */
export function nextRank(xp, rankId) {
  const rp = rankProgress(numOr(xp) || 0, numOr(rankId) || 1)
  if (rp.isMax) return null
  const nextRankId = Math.min((numOr(rankId) || 1) + 1, RANKS.length)
  return {
    rank: nextRankId,
    name: rankName(nextRankId),
    need: RANK_XP[nextRankId - 1],
    remaining: rp.remaining,
    pct: rp.progressPct
  }
}

/** Every rung of the rank ladder with where the player stands on it. */
export function ladderRungs(xp, rankId) {
  const x = numOr(xp)
  const id = numOr(rankId) || 1
  return RANK_XP.map((need, i) => ({
    rank: i + 1,
    name: RANKS[i],
    need,
    reached: x != null && (i + 1 <= id || x >= need),
    current: x != null && i + 1 === id,
    next: x != null && i + 1 === id + 1
  }))
}

/**
 * The Winter Pass rung the player's XP has bought. passTierXp is the panel's own
 * curve (state.js, sourced from winterfest/pass.ini), so the page never trusts a
 * tier a payload sent: it derives the tier from the XP it actually holds.
 */
export function passStanding(passXp) {
  const xp = numOr(passXp)
  if (xp == null) return null
  let tier = 1
  for (let t = 2; t <= PASS_MAX_TIER; t++) {
    if (xp < passTierXp(t)) break
    tier = t
  }
  const need = passTierXp(tier)
  const next = tier >= PASS_MAX_TIER ? null : passTierXp(tier + 1)
  const span = next == null ? 1 : Math.max(1, next - need)
  const into = Math.max(0, xp - need)
  return {
    xp, tier, need, next,
    pct: next == null ? 100 : Math.max(0, Math.min(100, Math.round((into / span) * 100))),
    remaining: next == null ? 0 : Math.max(0, next - xp)
  }
}

// ----------------------------------------------------------------- the data --
/**
 * Load what the page prints. A missing DB, a broken row or an unknown player all
 * end in known:false - the page then says "Not collected" and never invents a
 * figure. Only a real refusal (bad steamid) would surface, and the id is regexed
 * by the route before it gets here.
 */
export async function loadLevels(env, sid) {
  const out = { sid, known: false, p: null, ledger: [], ranks: [], pass: null }
  if (!sid || !env || !env.DB) return out
  try { out.p = await getPlayer(env.DB, sid) } catch { out.p = null }
  out.known = !!(out.p && out.p.exists)
  if (!out.known) return out
  try { out.ledger = await recentLedger(env.DB, sid, { limit: 8 }) } catch { out.ledger = [] }
  out.ranks = ladderRungs(out.p.xp, out.p.rank_id)
  // getPlayer answers the Winter Pass as `pass` (XP + derived tier): the same
  // object the Battle Pass plate prints, so both pages can never disagree.
  out.pass = passStanding(out.p.pass && out.p.pass.xp)
  return out
}

// ------------------------------------------------------------------ the page --
const NOT_COLLECTED_EN = NOT_COLLECTED

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

const CSS = `
@font-face{font-family:'Nunito';src:url('/assets/fonts/Nunito-Variable.ttf') format('truetype-variations');
  font-weight:200 1000;font-display:swap}
*{box-sizing:border-box}
html,body{margin:0;padding:0;width:100%;height:100%;background:#07040f;overflow:hidden}
body{font-family:Nunito,'Trebuchet MS','Segoe UI',Cantarell,Arial,sans-serif;color:#fff;-webkit-font-smoothing:antialiased}
#stage{position:absolute;left:0;top:0;width:${LEVELS_W}px;height:${LEVELS_H}px;overflow:hidden;transform-origin:0 0;
  will-change:transform;scale:min(calc(100vw / ${LEVELS_W}), calc(100vh / ${LEVELS_H}), 1);
  background:#0b0716 radial-gradient(120% 80% at 50% 0,#2a1152 0,#120a26 55%,#0a0616 100%)}
#rail{position:absolute;left:0;top:0;width:${RAIL_W}px;height:${LEVELS_H}px;
  background:linear-gradient(180deg,rgba(20,10,42,.94),rgba(12,6,28,.96));border-right:1px solid rgba(150,110,255,.18)}
#rail .brand{position:absolute;left:24px;top:14px;width:244px;height:52px;display:flex;align-items:center;gap:9px}
#rail .brand b{font-size:26px;font-weight:900;letter-spacing:-.4px;background:linear-gradient(180deg,#fff,#cfe3ff 60%,#8fb6ff);
  -webkit-background-clip:text;background-clip:text;color:transparent}
#rail .brand i{flex:1;height:20px;border-radius:10px;background:linear-gradient(180deg,#c8102e,#8c0a20);font-style:normal;
  display:flex;align-items:center;justify-content:center;font-size:9px;font-weight:900;letter-spacing:1.1px}
#rail .grp{position:absolute;left:22px;width:248px;height:16px;font-size:9.5px;font-weight:800;letter-spacing:2.2px;
  color:#8f9ec4;text-transform:uppercase;display:flex;align-items:center;gap:8px}
#rail .grp:before,#rail .grp:after{content:"";height:1px;flex:1;background:linear-gradient(90deg,transparent,#4a3a7a,transparent)}
#rail a.it,#rail span.it{position:absolute;left:12px;width:268px;height:44px;display:flex;align-items:center;gap:8px;
  padding:0 10px 0 8px;border-radius:12px;text-decoration:none;color:inherit}
#rail .it .ic{width:26px;height:26px;flex:0 0 26px;border-radius:8px;background:rgba(120,90,220,.16);
  border:1px solid rgba(160,130,255,.22);display:flex;align-items:center;justify-content:center;font-size:10px;
  font-weight:900;color:#c9b8ff}
#rail .it .tx{flex:1;min-width:0}
#rail .it .tx b{display:block;font-size:13.5px;font-weight:800;line-height:15px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
#rail .it .tx span{display:block;font-size:9px;font-weight:600;line-height:11px;color:#95a1c2;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
#rail .it.on{background:linear-gradient(90deg,rgba(120,70,240,.55),rgba(80,40,170,.18));
  box-shadow:inset 0 0 0 1.5px rgba(180,140,255,.75),0 0 18px rgba(130,80,255,.35)}
#top{position:absolute;left:${RAIL_W}px;top:0;right:0;height:76px;display:flex;align-items:center;gap:12px;padding:12px 16px 0}
#top h1{margin:0;font-size:26px;font-weight:900;letter-spacing:.4px}
#top .kick{font-size:11px;font-weight:800;letter-spacing:2.4px;color:#9fb0d6;text-transform:uppercase}
#top .who{margin-left:auto;display:flex;align-items:center;gap:10px;font-size:13px;font-weight:800}
#top .who .dot{width:28px;height:28px;border-radius:50%;background:linear-gradient(160deg,#6f7ad6,#2c2a55);display:flex;
  align-items:center;justify-content:center;font-size:13px;font-weight:900;box-shadow:inset 0 0 0 2px rgba(255,255,255,.18)}
.card{position:absolute;border-radius:14px;overflow:hidden;background:linear-gradient(180deg,rgba(26,18,58,.96),rgba(14,10,34,.97));
  box-shadow:inset 0 0 0 1.5px rgba(140,110,240,.35),0 10px 26px rgba(0,0,0,.42)}
.card .hd{position:relative;height:38px;display:flex;align-items:center;gap:9px;padding:0 14px;
  background:linear-gradient(180deg,rgba(44,30,92,.95),rgba(26,18,58,.6))}
.card .hd .ic{width:20px;height:20px;border-radius:6px;background:rgba(120,90,220,.28);border:1px solid rgba(160,130,255,.3);
  display:inline-flex;align-items:center;justify-content:center;font-size:9.5px;font-weight:900;color:#e2d8ff}
.card .hd b{font-size:15px;font-weight:800}
.card .hd:after{content:"";position:absolute;left:0;right:0;bottom:0;height:2px;
  background:linear-gradient(90deg,transparent,rgba(150,110,255,.6),transparent)}
.card .bd{padding:14px}
/* the hero: who, the level, and the ladder they are standing on */
#hero{left:${RAIL_W + 12}px;top:76px;width:1368px;height:208px}
#hero .sky{position:absolute;left:0;top:0;width:150px;height:208px;opacity:.7;
  background-image:url(${PLATE_URL});background-size:auto;background-repeat:repeat;background-position:-1300px -150px;
  -webkit-mask-image:linear-gradient(90deg,rgba(0,0,0,.95),transparent);mask-image:linear-gradient(90deg,rgba(0,0,0,.95),transparent)}
#hero .av{position:absolute;left:44px;top:34px;width:120px;height:120px;border-radius:50%;display:flex;align-items:center;
  justify-content:center;font-size:46px;font-weight:900;background:radial-gradient(circle at 50% 35%,#6a4fd0,#2a1d59 70%);
  box-shadow:0 0 0 5px #f2b544,0 0 0 8px #b97d18,0 0 22px rgba(242,181,68,.55)}
#hero .who{position:absolute;left:196px;top:22px;right:24px}
#hero .who h2{margin:0;font-size:30px;font-weight:900;text-shadow:0 2px 10px rgba(0,0,0,.7)}
#hero .who .row{display:flex;align-items:center;gap:12px;margin-top:8px;font-size:15px;font-weight:800}
#hero .tag{padding:3px 14px;border-radius:9px;background:linear-gradient(180deg,#c8102e,#8c0a20);font-size:13px}
#hero .next{margin-top:14px;width:700px}
.track{position:relative;height:24px;border-radius:12px;background:rgba(6,10,30,.72);
  box-shadow:inset 0 0 0 1.5px rgba(120,150,255,.3)}
.track b{position:absolute;left:1.5px;top:1.5px;bottom:1.5px;border-radius:11px;
  background:linear-gradient(180deg,#8bf07a,#2fbf3d 60%,#1d8c2a)}
.track b.gold{background:linear-gradient(180deg,#ffe08a,#f2b544 60%,#b97d18)}
.track i{position:absolute;right:12px;top:0;line-height:24px;font-style:normal;font-size:12px;font-weight:800}
.cap{margin-top:6px;font-size:12.5px;font-weight:700;color:#cfd6ea}
.nc{color:#c9b06a;font-style:italic;font-weight:700}
/* the four tiles */
#tiles{left:${RAIL_W + 12}px;top:296px;width:1368px;display:flex;gap:10px}
.tile{flex:1;border-radius:12px;padding:10px 12px;height:92px;background:linear-gradient(180deg,rgba(40,28,86,.85),rgba(18,12,42,.92));
  box-shadow:inset 0 0 0 1.5px rgba(140,110,240,.28)}
.tile .L{font-size:11.5px;font-weight:800;color:#bcc6de;letter-spacing:.4px;text-transform:uppercase}
.tile .V{font-size:27px;font-weight:900;font-variant-numeric:tabular-nums;margin-top:4px;line-height:30px}
.tile .S{font-size:10.5px;font-weight:700;color:#93a0c0;margin-top:2px}
.tile .V.gold{color:#f2c24a}
.tile .V.nc,.tile .V em{font-size:14px;color:#b7a26a;font-style:italic;font-weight:700}
/* the ladder */
#ladder{left:${RAIL_W + 12}px;top:400px;width:900px;height:520px}
#ladder .bd{padding:12px 14px}
.rung{display:flex;align-items:center;gap:10px;height:30px;font-size:13px;font-weight:800;
  border-bottom:1px solid rgba(120,110,200,.13)}
.rung:last-child{border-bottom:0}
.rung .n{width:34px;color:#9fb0d6;font-variant-numeric:tabular-nums;font-size:11.5px}
.rung .nm{flex:1;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;color:#c9d2ea}
.rung .xp{width:120px;text-align:right;font-variant-numeric:tabular-nums;color:#9fb0d6;font-size:12px}
.rung .st{width:96px;text-align:right;font-size:10.5px;font-weight:800;letter-spacing:.6px;text-transform:uppercase}
.rung.reached{background:rgba(60,200,110,.07)}
.rung.reached .nm{color:#fff}
.rung.reached .st{color:#8bf07a}
.rung.current{background:linear-gradient(90deg,rgba(120,70,240,.35),rgba(80,40,170,.05));
  box-shadow:inset 3px 0 0 #b98cff}
.rung.current .st{color:#d9c4ff}
.rung.next .st{color:#f2c24a}
.rung .st.none{color:#6f7ba0}
/* the pass + the XP history */
#pass{left:${RAIL_W + 924}px;top:400px;width:456px;height:250px}
#pass .bd{padding:12px 16px}
#pass .big{font-size:34px;font-weight:900;line-height:38px}
#pass .big span{font-size:15px;font-weight:800;color:#9fb0d6}
#pass .mt{margin-top:10px}
#hist{left:${RAIL_W + 924}px;top:662px;width:456px;height:258px}
#hist .bd{padding:8px 14px}
.hrow{display:flex;align-items:center;gap:8px;height:26px;font-size:12px;font-weight:700;
  border-bottom:1px solid rgba(120,110,200,.13)}
.hrow:last-child{border-bottom:0}
.hrow .w{width:74px;color:#9fb0d6;text-transform:capitalize}
.hrow .d{width:58px;text-align:right;font-variant-numeric:tabular-nums}
.hrow .d.up{color:#8bf07a}
.hrow .d.dn{color:#ff9d8f}
.hrow .r{flex:1;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;color:#b9c3dd}
.empty{font-size:12.5px;font-weight:700;color:#b7a26a;font-style:italic;padding:14px}
`.trim()

function tile(label, valueHtml, sub, cls) {
  return `<div class="tile"><div class="L">${esc(label)}</div>` +
    `<div class="V${cls ? " " + cls : ""}">${valueHtml}</div><div class="S">${esc(sub || "")}</div></div>`
}

function rungRow(r) {
  const state = r.current ? "You" : (r.next ? "Next" : (r.reached ? "Reached" : "—"))
  const cls = `rung${r.reached ? " reached" : ""}${r.current ? " current" : ""}${r.next ? " next" : ""}`
  return `<div class="${cls}"><span class="n">#${r.rank}</span>` +
    `<span class="nm">${esc(r.name)}</span>` +
    `<span class="xp">${r.rank === 1 ? "0" : fmt(r.need)} XP</span>` +
    `<span class="st${state === "—" ? " none" : ""}">${state}</span></div>`
}

/** Render the page. Pure: same data in, same HTML out (the harness proves it). */
export function renderLevels(d) {
  const { known, p } = d
  const name = known && p.name ? String(p.name) : ""
  const initial = name ? esc(name.slice(0, 1).toUpperCase()) : "?"
  const level = known ? numOr(p.level) : null
  const xp = known ? numOr(p.xp) : null
  const rankId = known ? numOr(p.rank_id) : null
  const rp = known && xp != null ? rankProgress(xp, rankId || 1) : null
  const next = rp && !rp.isMax ? nextRank(xp, rankId || 1) : null
  const tree = known ? (p.tree || {}) : {}
  const pass = d.pass

  const levelTile = level == null
    ? tile("Level", NOT_COLLECTED_EN, "the game has not reported it", "nc")
    : tile("Level", "♛ " + fmt(level), levelsToNext(level), "gold")
  const rankTile = rp
    ? tile("Rank", esc(rp.curName), next ? `${fmt(rp.remaining)} XP to ${next.name}` : "top of the ladder", "")
    : tile("Rank", NOT_COLLECTED_EN, "", "nc")
  const treeTile = numOr(tree.level) == null
    ? tile("Tree level", NOT_COLLECTED_EN, "", "nc")
    : tile("Tree level", fmt(tree.level), `${numOr(tree.slots) == null ? "—" : fmt(tree.slots)} of ${numOr(tree.capacity) == null ? "—" : fmt(tree.capacity)} slots hung`, "")
  // A player row with no pass XP is tier 1 with an empty bar - the panel's own
  // rule (bp_track.js: "never tier 0, never NaN"). No row at all is "not collected".
  const passTile = pass
    ? tile("Winter Pass", "Tier " + fmt(pass.tier), pass.next == null ? "top tier" : `${fmt(pass.remaining)} XP to tier ${pass.tier + 1}`, "gold")
    : tile("Winter Pass", NOT_COLLECTED_EN, "", "nc")

  const heroTrack = rp
    ? `<div class="track"><b${rp.isMax ? ' class="gold"' : ""} style="width:${rp.isMax ? 100 : rp.progressPct}%"></b>` +
      `<i>${xp == null ? NOT_COLLECTED_EN : fmt(xp) + " XP"}</i></div>` +
      `<div class="cap">${rp.isMax ? "Top rank — nothing left to climb"
        : `Next rank ${esc(rp.nextName)} at ${fmt(rp.nextReq)} XP · ${fmt(rp.remaining)} to go`}</div>`
    : `<div class="cap nc">${NOT_COLLECTED_EN} — this page prints only what the panel holds.</div>`

  const passBody = pass
    ? `<div class="big">Tier ${fmt(pass.tier)} <span>of ${PASS_MAX_TIER}</span></div>` +
      `<div class="track mt"><b class="gold" style="width:${pass.pct}%"></b><i>${fmt(pass.xp)} XP</i></div>` +
      `<div class="cap">${pass.next == null ? "Every tier of this pass is bought."
        : `${fmt(pass.remaining)} XP to tier ${pass.tier + 1} (${fmt(pass.next)} XP)`}</div>`
    : `<div class="cap nc">${NOT_COLLECTED_EN} — no player, so no pass XP has been written.</div>`

  const hist = (d.ledger || []).length
    ? d.ledger.map(r => `<div class="hrow"><span class="w">${esc(r.currency)}</span>` +
      `<span class="d ${r.delta > 0 ? "up" : "dn"}">${r.delta > 0 ? "+" : ""}${fmt(r.delta)}</span>` +
      `<span class="r">${esc(r.reason || r.ref || "—")}</span></div>`).join("")
    : `<div class="empty">No ledger rows for this player yet.</div>`

  const player = known
    ? `<h2>${esc(name || "Unnamed player")}</h2>` +
      `<div class="row"><span>♛ ${level == null ? NOT_COLLECTED_EN : "Level " + fmt(level)}</span>` +
      `<span class="tag">❄ ${esc(rankId ? rankName(rankId) : "Rank not collected")} ❄</span></div>` +
      `<div class="next">${heroTrack}</div>`
    : `<h2>No player</h2><div class="cap nc">Open this page from the game (the panel command)
       or with ?steamid=STEAM_0:0:12345 on the URL — nothing here is guessed for a missing id.</div>`

  return `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>FreeNova · Winterfest levels${name ? " · " + esc(name) : ""}</title>
<style>${CSS}</style></head>
<body><div id="stage" data-page="levels">
${railHtml("levels")}
<header id="top">
  <div><div class="kick">Progress &amp; rewards · Winterfest</div><h1>Levels</h1></div>
  <div class="who"><span>${known ? esc(name || "Unnamed player") : "No player"}</span><span class="dot">${initial}</span></div>
</header>
<section class="card" id="hero"><div class="sky"></div><div class="av">${initial}</div><div class="who">${player}</div></section>
<div id="tiles">${levelTile}${rankTile}${treeTile}${passTile}</div>
<section class="card" id="ladder"><div class="hd"><span class="ic">▲</span><b>Rank ladder</b></div>
  <div class="bd">${d.ranks.map(rungRow).join("")}</div></section>
<section class="card" id="pass"><div class="hd"><span class="ic">WP</span><b>Winter Pass progress</b></div>
  <div class="bd">${passBody}</div></section>
<section class="card" id="hist"><div class="hd"><span class="ic">◈</span><b>Recent rewards</b></div>
  <div class="bd">${hist}</div></section>
</div>
<script>${fitScript(LEVELS_W, LEVELS_H)}</script>
</body></html>`
}

/**
 * What is left to the next level. The panel holds `level` and `xp` but no table
 * of level thresholds - the game computes them - so this line names the level and
 * says where the number would come from rather than inventing a bracket.
 */
function levelsToNext(level) {
  return `to level ${fmt(level + 1)} · next bracket computed by the game`
}

/** The route: /panel/levels. A missing player is a page with no player, never a 5xx. */
export async function pageLevels(env, url) {
  const now = Math.floor(Date.now() / 1000)
  const minted = url && url._fnMotdSid
  const raw = (minted && String(minted)) || (url && url.searchParams.get("steamid")) || ""
  const sid = /^STEAM_[0-9]:[0-9]:\d+$/.test(String(raw).trim()) ? String(raw).trim() : ""
  const d = await loadLevels(env, sid)
  d.now = now
  return new Response(renderLevels(d), {
    status: 200,
    headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store", "x-content-type-options": "nosniff" }
  })
}
