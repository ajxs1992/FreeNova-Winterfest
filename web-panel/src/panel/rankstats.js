// FreeNova panel — RANKSTATS (the rail's "Rankstats: Festive statistics").
// docs/panel/00-CONTRACT.md page 7, the plate at docs/design/refs/winterfest/.
//
// WHAT IT IS
//   The player's own record, one screen at the plate's 1672x941 grid: the hero
//   (level, rank, XP to the next rank), the headline career figures, every
//   weapon the game has pushed and what it did, and the maps it was played on.
//   The right column answers the one question a statistics page is for: where
//   this player stands among the players the panel knows.
//
// WHERE EVERY NUMBER COMES FROM
//   players.*            kills, deaths, assists, headshots, damage, mvps, wins,
//                        losses, playtime_minutes, xp, level, rank_id, rating_x100
//   player_weapons       slot, kills, hs, damage        (weaponStats)
//   player_maps          per-map matches/wins/kills…    (mapStats)
//   comp_history         the competitive seasons pushed (seasonHistory)
//   rankStanding         the player directly above, and the gap to them
//
// A figure with no source prints "Not collected" or an em dash. A weapon the
// game never pushed is not listed at all - the page shows what happened, never
// what the plate's sample SA claims happened.
import { getPlayer } from "../state.js"
import { presence, rankStanding, weaponStats, mapStats, seasonHistory } from "../query.js"
import { rankName, rankProgress } from "../ranks.js"
import { WEAPONS } from "../ui.js"
import { NAV_GROUPS } from "./nav.js"
import { fitScript, PLATE_URL, plateDigest, fragEsc as esc, thousands as fmt, numOr,
  kdText, pctText, agoText, dateText, spanText, NOT_COLLECTED } from "./kit.js"

export const RANKSTATS_W = 1672, RANKSTATS_H = 941
const RAIL_W = 292

// The weapon name the panel already uses for a slot (src/ui.js WEAPONS, mirrored
// from the game's own weapon table). A slot the table does not name is listed by
// its number rather than given a name the panel made up.
function weaponName(slot) {
  // player_weapons.slot is ZERO-BASED as the game pushes it (src/query.js
  // weaponStats returns slot 0..N straight from the row, and the harness's own
  // fixture writes slot 0), while src/ui.js WEAPONS is a 1-based list whose
  // entry 0 is the AK-47. So the list is indexed by the slot itself.
  const n = Number(slot)
  const w = Number.isFinite(n) ? (WEAPONS || [])[n] : null
  return typeof w === "string" && w ? w : "Slot " + slot
}

const CSS = `
@font-face{font-family:'Nunito';src:url('/assets/fonts/Nunito-Variable.ttf') format('truetype-variations');
  font-weight:200 1000;font-display:swap}
*{box-sizing:border-box}
html,body{margin:0;padding:0;width:100%;height:100%;background:#07040f;overflow:hidden}
body{font-family:Nunito,'Trebuchet MS','Segoe UI',Cantarell,Arial,sans-serif;color:#fff;-webkit-font-smoothing:antialiased}
#stage{position:absolute;left:0;top:0;width:${RANKSTATS_W}px;height:${RANKSTATS_H}px;overflow:hidden;transform-origin:0 0;
  will-change:transform;scale:min(calc(100vw / ${RANKSTATS_W}), calc(100vh / ${RANKSTATS_H}), 1);
  background:#0b0716 radial-gradient(120% 80% at 50% 0,#2a1152 0,#120a26 55%,#0a0616 100%)}
#rail{position:absolute;left:0;top:0;width:${RAIL_W}px;height:${RANKSTATS_H}px;
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
.hero{position:absolute;left:${RAIL_W + 12}px;top:76px;width:1368px;height:216px;border-radius:16px;overflow:hidden;
  box-shadow:inset 0 0 0 1.5px rgba(150,110,255,.35),0 10px 30px rgba(0,0,0,.45)}
/* The plate's text-free snowy-night tile, repeated at the plate's own scale
   (background-size:AUTO) inside a narrow band, faded out to the right. Never a
   stretched crop: a stretched tile smears its snowline, and a crop that carries
   the plate's own words or figures is not a background at all. */
.hero .sky{position:absolute;left:0;top:0;width:104px;height:216px;opacity:.75;
  background-image:url(${PLATE_URL});background-size:auto;background-repeat:repeat;
  background-position:-1300px -150px;
  -webkit-mask-image:linear-gradient(90deg,rgba(0,0,0,.95) 0,rgba(0,0,0,.9) 55%,transparent 100%);
  mask-image:linear-gradient(90deg,rgba(0,0,0,.95) 0,rgba(0,0,0,.9) 55%,transparent 100%)}
.hero .av{position:absolute;left:44px;top:42px;width:128px;height:128px;border-radius:50%;display:flex;align-items:center;
  justify-content:center;font-size:52px;font-weight:900;background:radial-gradient(circle at 50% 35%,#6a4fd0,#2a1d59 70%);
  box-shadow:0 0 0 5px #f2b544,0 0 0 8px #b97d18,0 0 22px rgba(242,181,68,.55)}
.hero .ring{position:absolute;left:0;top:0;width:208px;height:196px;background-image:url(${PLATE_URL});background-repeat:no-repeat;
  background-position:-372px -92px;background-size:208px 196px}
.hero .who{position:absolute;left:220px;top:30px;right:24px}
.hero .who h2{margin:0;font-size:32px;font-weight:900;text-shadow:0 2px 10px rgba(0,0,0,.7)}
.hero .row{display:flex;align-items:center;gap:12px;margin-top:8px;font-size:15px;font-weight:800}
.hero .tag{padding:3px 14px;border-radius:9px;background:linear-gradient(180deg,#c8102e,#8c0a20);font-size:13px}
.hero .next{margin-top:12px;width:620px}
.hero .next .tr{position:relative;height:22px;border-radius:11px;background:rgba(6,10,30,.72);box-shadow:inset 0 0 0 1.5px rgba(120,150,255,.3)}
.hero .next .tr b{position:absolute;left:1.5px;top:1.5px;bottom:1.5px;border-radius:10px;
  background:linear-gradient(180deg,#8bf07a,#2fbf3d 60%,#1d8c2a)}
.hero .next .tr i{position:absolute;right:12px;top:0;line-height:22px;font-style:normal;font-size:12px;font-weight:800}
.hero .next .cap{margin-top:6px;font-size:12px;font-weight:700;color:#cfd6ea}
.tiles{position:absolute;left:${RAIL_W + 12}px;top:304px;width:1368px;display:flex;gap:10px}
.tile{flex:1;border-radius:12px;padding:10px 12px;height:96px;background:linear-gradient(180deg,rgba(40,28,86,.85),rgba(18,12,42,.92));
  box-shadow:inset 0 0 0 1.5px rgba(140,110,240,.28)}
.tile .L{font-size:11.5px;font-weight:800;color:#bcc6de;letter-spacing:.4px;text-transform:uppercase}
.tile .V{font-size:27px;font-weight:900;font-variant-numeric:tabular-nums;margin-top:4px;line-height:30px}
.tile .S{font-size:10.5px;font-weight:700;color:#93a0c0;margin-top:2px}
.tile .V.g{color:#8bf07a}.tile .V.gold{color:#f2c24a}.tile .V.nc{font-size:14px;color:#b7a26a;font-style:italic;font-weight:700}
table.w{width:100%;border-collapse:collapse;font-size:13px}
table.w th{text-align:left;font-size:10.5px;letter-spacing:1.1px;text-transform:uppercase;color:#9fb0d6;font-weight:800;
  padding:5px 8px;border-bottom:1px solid rgba(140,110,240,.28)}
table.w td{padding:6px 8px;border-bottom:1px solid rgba(120,110,200,.13);font-weight:700;font-variant-numeric:tabular-nums}
table.w td.n{text-align:right}
table.w td.b{font-weight:900}
table.w tr:last-child td{border-bottom:0}
.bar{display:inline-block;height:8px;width:120px;border-radius:5px;background:rgba(6,10,30,.75);vertical-align:middle;
  box-shadow:inset 0 0 0 1px rgba(120,150,255,.25)}
.bar b{display:block;height:100%;border-radius:5px;background:linear-gradient(90deg,#7b4bf0,#4fd76b)}
.empty{font-size:12.5px;font-weight:700;color:#b7a26a;font-style:italic;padding:14px}
.mrow{display:flex;align-items:center;gap:10px;height:30px;border-bottom:1px solid rgba(120,110,200,.14);font-size:13px}
.mrow:last-child{border-bottom:0}
.mrow .n{flex:1;font-weight:800;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.mrow .v{font-weight:800;font-variant-numeric:tabular-nums;color:#8bf07a}
.mrow .u{font-size:10.5px;font-weight:700;color:#93a0c0;width:56px;text-align:right}
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
export async function loadRankstats(env, sid, now) {
  const out = { sid, now, known: false, p: null, presence: null, standing: null, weapons: [], maps: [], seasons: [] }
  if (!sid || !env || !env.DB) return out
  try { out.p = await getPlayer(env.DB, sid) } catch { out.p = null }
  out.known = !!(out.p && out.p.exists)
  try { out.presence = await presence(env.DB, sid, { now }) } catch {}
  if (!out.known) return out
  try { out.standing = await rankStanding(env.DB, sid) } catch {}
  try { out.weapons = await weaponStats(env.DB, sid, { limit: 10 }) } catch {}
  try { out.maps = await mapStats(env.DB, sid, { limit: 8 }) } catch {}
  try { out.seasons = await seasonHistory(env.DB, sid, { limit: 5 }) } catch {}
  return out
}

function statTile(label, value, sub, cls) {
  return `<div class="tile"><div class="L">${esc(label)}</div>` +
    `<div class="V${cls ? " " + cls : ""}">${value}</div><div class="S">${esc(sub || "")}</div></div>`
}

const DASH = `<span class="nc">—</span>`

export function renderRankstats(d) {
  const { sid, known, p, standing, weapons, maps, seasons, now } = d
  const c = (known && p.career) || {}
  const kills = numOr(c.kills), deaths = numOr(c.deaths), assists = numOr(c.assists)
  const hs = numOr(c.headshots), damage = numOr(c.damage), mvps = numOr(c.mvps)
  const wins = numOr(c.wins), losses = numOr(c.losses), play = numOr(c.playtime_minutes)
  const level = known ? numOr(p.level) : null
  const xp = known ? numOr(p.xp) : null
  const rankId = known ? numOr(p.rank_id) : null
  const rp = known && xp != null ? rankProgress(xp, rankId || 1) : null
  const name = known && p.name ? String(p.name) : ""
  const initial = name ? esc(name.slice(0, 1).toUpperCase()) : "?"
  const matches = (wins != null && losses != null) ? wins + losses : null
  const decided = matches
  const rating = known ? numOr(p.rating_x100) : null

  // the gap to the player above, in the words a player uses for it
  const above = standing && standing.above
  const nextLine = !known ? NOT_COLLECTED
    : rp && rp.isMax ? "Top rank — nothing left to climb"
      : rp ? `${fmt(rp.remaining)} XP to ${esc(rp.nextName)}`
        : NOT_COLLECTED
  const aboveLine = above ? `${above.name || above.steamid} holds ${fmt(above.xp)} XP — ${fmt(standing.behind)} XP ahead` : ""

  const heroPct = rp && !rp.isMax ? Math.max(0, Math.min(100, rp.progressPct)) : (rp && rp.isMax ? 100 : 0)

  const hero = `<section class="hero">
  <div class="sky"></div>
  <div class="av">${initial}</div>
  <div class="ring"></div>
  <div class="who">
    <h2>${name ? esc(name) : "No player"}</h2>
    <div class="row">
      <span>♛ ${level == null ? NOT_COLLECTED : "Level " + fmt(level)}</span>
      <span class="tag">❄ ${esc(rankId ? rankName(rankId) : "Rank not collected")} ❄</span>
      <span>${standing && standing.rank ? "#" + fmt(standing.rank) + " on the server" : "Placement not collected"}</span>
    </div>
    <div class="next">
      <div class="tr"><b style="width:${heroPct}%"></b><i>${xp == null ? NOT_COLLECTED : fmt(xp) + " XP"}</i></div>
      <div class="cap">${nextLine}${aboveLine ? " · " + esc(aboveLine) : ""}</div>
    </div>
  </div>
</section>`

  const tiles = `<div class="tiles">
  ${statTile("Kills", kills == null ? NOT_COLLECTED : fmt(kills), hs == null ? "" : fmt(hs) + " headshots", kills == null ? "nc" : "")}
  ${statTile("Deaths", deaths == null ? NOT_COLLECTED : fmt(deaths), matches == null ? "" : fmt(matches) + " matches", deaths == null ? "nc" : "")}
  ${statTile("K/D", deaths ? kdText(kills, deaths) : "—", "kills per death", "")}
  ${statTile("Assists", assists == null ? NOT_COLLECTED : fmt(assists), "", assists == null ? "nc" : "")}
  ${statTile("Headshot rate", kills ? pctText(hs, kills) : "—", "of all kills", "g")}
  ${statTile("MVPs", mvps == null ? NOT_COLLECTED : fmt(mvps), "", mvps == null ? "nc" : "gold")}
  ${statTile("Win rate", decided ? `${fmt(wins)} / ${fmt(decided)}` : "—", decided ? pctText(wins, decided) : "no decided matches", "g")}
  ${statTile("Playtime", play == null ? NOT_COLLECTED : fmt(play) + " min", play == null ? "" : spanText(play * 60), play == null ? "nc" : "")}
</div>`

  // ---- weapons: only what the game pushed, biggest first ----
  const wRows = (weapons || []).map(w => `<tr>
    <td class="b">${esc(weaponName(w.slot))}</td>
    <td class="n">${fmt(w.kills)}</td>
    <td class="n">${fmt(w.hs)}</td>
    <td class="n">${w.kills ? pctText(w.hs, w.kills) : "—"}</td>
    <td class="n">${fmt(w.damage)}</td>
    <td>${bar(w.kills, Math.max(1, ...(weapons || []).map(x => x.kills)))}</td>
  </tr>`).join("")
  const weaponsCard = `<section class="card" style="left:${RAIL_W + 12}px;top:414px;width:700px;height:514px">
    <div class="hd"><span class="ic">WK</span><b>Weapons</b></div>
    ${wRows ? `<table class="w"><thead><tr><th>Weapon</th><th style="text-align:right">Kills</th><th style="text-align:right">HS</th>
      <th style="text-align:right">HS %</th><th style="text-align:right">Damage</th><th></th></tr></thead>
      <tbody>${wRows}</tbody></table>`
      : `<div class="empty">The panel has no per-weapon record for this player yet — the game pushes one with each snapshot.</div>`}
  </section>`

  // ---- maps ----
  const mRows = (maps || []).map(m => `<div class="mrow">
    <span class="n">${esc(m.map || "—")}</span>
    <span class="u">${fmt(m.matches)} played</span>
    <span class="u">${m.winrate == null ? "—" : pctText(m.wins, m.wins + m.losses)}</span>
    <span class="v">${fmt(m.kills)}</span>
  </div>`).join("")
  const mapsCard = `<section class="card" style="left:${RAIL_W + 724}px;top:414px;width:340px;height:254px">
    <div class="hd"><span class="ic">MP</span><b>Top maps</b></div>
    <div style="padding:6px 14px">
      ${mRows || `<div class="empty">No per-map record yet.</div>`}
    </div>
  </section>`

  // ---- competitive seasons the game has pushed ----
  const sRows = (seasons || []).map(s => `<div class="mrow">
    <span class="n">Season ${esc(s.season)}</span>
    <span class="u">${fmt(s.wins)} wins</span>
    <span class="v">${fmt(s.points)} pts</span>
  </div>`).join("")
  const seasonsCard = `<section class="card" style="left:${RAIL_W + 724}px;top:680px;width:340px;height:248px">
    <div class="hd"><span class="ic">SE</span><b>Competitive seasons</b></div>
    <div style="padding:6px 14px">
      ${sRows || `<div class="empty">No season history pushed for this player.</div>`}
      <div style="margin-top:10px;font-size:11.5px;font-weight:700;color:#93a0c0">
        Rating ${rating == null ? "not collected" : (rating / 100).toFixed(2)}
      </div>
    </div>
  </section>`

  // ---- where this player stands ----
  const standCard = `<section class="card" style="left:${RAIL_W + 1076}px;top:414px;width:280px;height:514px">
    <div class="hd"><span class="ic">ST</span><b>Standing</b></div>
    <div style="padding:12px 14px;font-size:13px;font-weight:700;line-height:20px;color:#cfd6ea">
      <div style="display:flex;justify-content:space-between;padding:6px 0;border-bottom:1px solid rgba(120,110,200,.14)">
        <span>Server rank</span><b>${standing && standing.rank ? "#" + fmt(standing.rank) : "—"}</b></div>
      <div style="display:flex;justify-content:space-between;padding:6px 0;border-bottom:1px solid rgba(120,110,200,.14)">
        <span>Lifetime XP</span><b>${xp == null ? "—" : fmt(xp)}</b></div>
      <div style="display:flex;justify-content:space-between;padding:6px 0;border-bottom:1px solid rgba(120,110,200,.14)">
        <span>Rating</span><b>${rating == null ? "—" : (rating / 100).toFixed(2)}</b></div>
      <div style="display:flex;justify-content:space-between;padding:6px 0;border-bottom:1px solid rgba(120,110,200,.14)">
        <span>Damage dealt</span><b>${damage == null ? "—" : fmt(damage)}</b></div>
      <div style="display:flex;justify-content:space-between;padding:6px 0;border-bottom:1px solid rgba(120,110,200,.14)">
        <span>Last seen</span><b>${known ? agoText(p.last_seen, now) : "—"}</b></div>
      <div style="margin-top:14px;font-size:11.5px;font-weight:700;color:#93a0c0">
        These figures are the game's own snapshot of this player; the panel stores them and never recomputes one.
      </div>
    </div>
  </section>`

  return `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>FreeNova · Winterfest rankstats${name ? " · " + esc(name) : ""}</title>
<style>${CSS}</style></head>
<body><div id="stage" data-page="rankstats">
${railHtml("rankstats")}
<header id="top">
  <div><div class="kick">Rank stats · Winterfest</div><h1>Rank stats</h1></div>
  <div class="who"><span>${name ? esc(name) : "No player"}</span><span class="dot">${initial}</span></div>
</header>
${hero}
${tiles}
${weaponsCard}
${mapsCard}
${seasonsCard}
${standCard}
</div>
<script>${fitScript(RANKSTATS_W, RANKSTATS_H)}</script>
</body></html>`
}

function bar(part, whole) {
  const p = numOr(part), w = numOr(whole)
  const pct = p == null || !w ? 0 : Math.max(0, Math.min(100, Math.round((p * 100) / w)))
  return `<span class="bar"><b style="width:${pct}%"></b></span>`
}

/** The route: /panel/rankstats. */
export async function pageRankstats(env, url) {
  const now = Math.floor(Date.now() / 1000)
  const minted = url && url._fnMotdSid
  const raw = (minted && String(minted)) || (url && url.searchParams.get("steamid")) || ""
  const sid = /^STEAM_[0-9]:[0-9]:\d+$/.test(String(raw).trim()) ? String(raw).trim() : ""
  const d = await loadRankstats(env, sid, now)
  return new Response(renderRankstats(d), {
    status: 200,
    headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store", "x-content-type-options": "nosniff" }
  })
}
