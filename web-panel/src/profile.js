// Player profile MOTD — same shell and tokens; one rank crest, level as text.
// Data is read-only: players row + top weapons + medal count + server rank.
import { loadTheme } from "./top15/store.js"
import { serverMeta } from "./top15/meta.js"
import {
  motdFrame, esc, fmt, rankName, rankFile, levelTile, isOn, ago, kdOf, hsOf
} from "./top15/render.js"
import { TORNADO_WEAPONS, skillOf, xpColorOf } from "./top15/theme.js"
import { rankProgress } from "./ranks.js"
import { flagImg } from "./ui.js"
import { apUnlocksMap, badgeCabinet } from "./pages.js"
import { xpPerTier, playerBpTier, bpInto } from "./bp_track.js"

function steamidOf(url) {
  const minted = url && url._fnMotdSid
  if (minted && /^STEAM_[0-9]:[0-9]:\d+$/.test(String(minted))) return String(minted)
  const q = (url.searchParams.get("steamid") || "").trim()
  if (/^STEAM_[0-9]:[0-9]:\d+$/.test(q)) return q
  const m = String(url.pathname || "").match(/\/m\/p\/(\d+-\d+-\d+)/i)
  if (m) return "STEAM_" + m[1].replace(/-/g, ":")
  return ""
}

const MEDAL_ART = {
  kills_100: "/medals2/kills_100.png",
  kills_1000: "/medals2/kills_1000.png",
  kills_5000: "/medals2/kills_5000.png",
  hs_100: "/medals2/hs_100.png",
  hs_500: "/medals2/hs_500.png",
  bomb_specialist: "/medals2/bomb_specialist.png",
  defusal_angel: "/medals2/defusal_angel.png",
  wins_100: "/medals2/wins_100.png",
  level_25: "/medals2/level_25.png",
  level_52: "/medals2/level_52.png",
  win_streak_10: "/medals2/win_streak_10.png",
  coin_tycoon: "/medals2/coin_tycoon.png",
  combat_medic: "/medals2/combat_medic.png"
}

const MEDAL_NAME = {
  kills_100: "FIRST BLOOD CENTURY",
  kills_1000: "KILLING MACHINE",
  kills_5000: "FREENOVA LEGEND KILLER",
  hs_100: "SHARPSHOOTER",
  hs_500: "HEADHUNTER",
  bomb_specialist: "DEMOLITION EXPERT",
  defusal_angel: "BOMB SQUAD",
  wins_100: "TEAM PLAYER",
  level_25: "SEASONED SOLDIER",
  level_52: "FREENOVA LEGEND",
  win_streak_10: "UNSTOPPABLE",
  coin_tycoon: "COIN MAGNET",
  combat_medic: "COMBAT MEDIC"
}

function medalSrc(code) {
  const c = String(code || "").toLowerCase()
  return MEDAL_ART[c] || `/medals/fn_${esc(c)}.png`
}

function vipName(t) {
  return t === 3 ? "VIP Elite" : t === 2 ? "VIP+" : t === 1 ? "VIP" : "Member"
}

function skillPill(kills, deaths) {
  const s = skillOf(kills, deaths)
  const fg = s.name === "G" ? "#fff" : "#111"
  return `<span class='skill' style='background-color:${s.color};color:${fg}'>${esc(s.name)} ${Math.round(s.ratio)}</span>`
}

function played(min) {
  const m = Number(min) || 0
  if (m < 60) return m + "m"
  const h = Math.floor(m / 60)
  const r = m % 60
  return h + "h" + (r ? " " + r + "m" : "")
}

function weaponOf(slot) {
  return TORNADO_WEAPONS.find(w => w.slot === Number(slot)) || {
    name: "Slot " + slot, short: "Slot " + slot, img: "/i/gun_knife.png"
  }
}

function statCell(label, value) {
  return `<td><span class='sk'>${esc(label)}</span><span class='sv'>${value}</span></td>`
}

function idCard(p, rp, rankPos, own, now) {
  const on = isOn(p, now)
  const name = p.name || p.steamid || "Unknown"
  const rank = rankName(p.rank_id)
  const seen = ago(now - (Number(p.last_seen) || 0))
  return `<div class='panel idpanel'>
    <table class='idtable' cellspacing='0' cellpadding='0'><tr>
      <td class='idcrestcell'>
        <div class='rank-kicker'>Rank</div>
        <img class='bigcrest' src='${rankFile(p)}' width='42' height='42' alt='${esc(rank)}' title='${esc(rank)}'>
      </td>
      <td>
        <div class='pbig'>${flagImg(p.cc, 15, 11)}${esc(name)}${own ? "<span class='youtag'>YOU</span>" : ""}</div>
        <div class='psmall'>Lvl ${fmt(p.level)} · ${esc(rank)} · ${on ? "<span class='on'>●</span> online" : "offline · seen " + esc(seen)}</div>
      </td>
      <td align='right' width='126'>
        <div class='pxpbig'>${fmt(p.xp)}<span>XP</span></div>
        <div class='psmall'>Server rank #${fmt(rankPos)}</div>
      </td>
    </tr></table>
  </div>`
}

function colsCard(p) {
  const skill = skillPill(p.kills, p.deaths)
  const acc = Number(p.shots) > 0 ? (Number(p.hits) * 100 / Number(p.shots)) : null
  const vip = vipName(p.vip_tier)
  return `<div class='panel'>
    <table class='cols' cellspacing='0' cellpadding='0'><tr>
      <td class='c1' width='30%'>
        <table class='c1head' cellspacing='0' cellpadding='0'><tr>
          <td class='sect'>Medals</td>
          <td class='r'><a href='/achievements?steamid=${encodeURIComponent(p.steamid || "")}&compact=1'>All</a></td>
        </tr></table>
        ${(p._medalCodes || []).length === 1
          ? `<div class='medalrow2 single'><img src='${medalSrc(p._medalCodes[0])}' width='64' height='64' alt='' onerror='this.style.display="none"'></div><div class='medal-name'>${esc(MEDAL_NAME[String(p._medalCodes[0]).toLowerCase()] || "MEDAL")}</div>`
          : `<div class='medalrow2'>${(p._medalCodes || []).slice(0, 5).map(c => `<img src='${medalSrc(c)}' width='28' height='28' alt='' onerror='this.style.display="none"'>`).join("")}${(p._medalCodes || []).length > 5 ? `<span class='medalmore'>+${(p._medalCodes.length - 5)}</span>` : ""}</div>`}
        <div class='medal-count'>${fmt(p._medals)} / ${fmt(p._achTotal || 13)} medals</div>
        <div class='medal-progress'><i style='width:${p._achTotal ? Math.round(Number(p._medals) * 100 / Number(p._achTotal)) : 0}%'></i></div>
        <div class='skillrow'>Skill ${skill}</div>
        <div class='skillrow'>${esc(vip)}${p.custom_tag ? " · " + esc(p.custom_tag) : ""}</div>
      </td>
      <td class='c2' width='40%'>
        <table class='statgrid' cellspacing='0' cellpadding='0'>
          <tr>${statCell("Kills", fmt(p.kills))}${statCell("Deaths", fmt(p.deaths))}</tr>
          <tr>${statCell("K/D", kdOf(p))}${statCell("HS%", hsOf(p) === "—" ? "—" : hsOf(p) + "%")}</tr>
          <tr>${statCell("Accuracy", acc === null ? "—" : acc.toFixed(1) + "%")}${statCell("Assists", fmt(p.assists))}</tr>
          <tr>${statCell("Wins", fmt(p.wins))}${statCell("MVP", fmt(p.mvps))}</tr>
          <tr>${statCell("Damage", fmt(p.damage))}${statCell("Headshots", fmt(p.headshots))}</tr>
          <tr>${statCell("Playtime", played(p.playtime_minutes))}${statCell("Rating", (Number(p.rating_x100 || 0) / 100).toFixed(2))}</tr>
        </table>
      </td>
      <td class='c3' width='30%'>
        <div class='sect'>Top weapons</div>
        ${weaponsHtml(p)}
        <div class='psmall' style='font-size:6px;margin-top:3px;'>Icons: game-icons.net · CC BY 3.0</div>
      </td>
    </tr></table>
  </div>`
}

function weaponsHtml(p) {
  const list = (p._weapons || []).filter(w => Number(w.kills) > 0).slice(0, 5)
  if (!list.length) return `<div class='psmall'>No weapon kills yet.</div>`
  const total = Math.max(1, Number(p.kills) || 0)
  return list.map(w => {
    const def = weaponOf(w.slot)
    const share = Math.max(0, Math.min(100, Math.round(Number(w.kills) * 100 / total)))
    return `<table class='wrow' cellspacing='0' cellpadding='0'><tr>
      <td class='wicon'><span class='wtile'><img src='${def.img}' width='20' height='20' alt=''></span></td>
      <td class='wname'>${esc(def.short || def.name)}<div class='wbar'><i style='width:${share}%'></i></div></td>
      <td class='wk'>${fmt(w.kills)}</td>
    </tr></table>`
  }).join("")
}

function progressCard(rp) {
  const right = rp.isMax ? "MAX RANK" : fmt(rp.remaining) + " XP to go"
  const pct = Math.max(0, Math.min(100, Number(rp.progressPct) || 0))
  return `<div class='panel'>
    <table class='proghead' cellspacing='0' cellpadding='0'><tr>
      <td>${esc(rp.curName)} → ${esc(rp.isMax ? "Global Elite" : rp.nextName)}</td>
      <td class='r'>${esc(right)}</td>
    </tr></table>
    <div class='progbar'><i style='width:${pct}%'></i></div>
  </div>`
}

async function directory(env, theme, meta, now) {
  let rows = []
  try {
    rows = ((await env.DB.prepare(
      `SELECT steamid, name, xp, rank_id, level, last_seen, cc
       FROM players ORDER BY last_seen DESC LIMIT 12`
    ).all()).results) || []
  } catch { rows = [] }
  const body = rows.length ? `<div class='boardwrap'><table class='board roster' cellspacing='0' cellpadding='0'>
    <colgroup><col style='width:10%'><col style='width:46%'><col style='width:26%'><col style='width:18%'></colgroup>
    <tr><th class='c'>#</th><th class='l'>Player</th><th class='l'>Rank</th><th>XP</th></tr>
    ${rows.map((r, i) => {
      const rank = rankName(r.rank_id)
      const on = isOn(r, now)
      return `<tr class='${i % 2 ? "even" : "odd"}'>
        <td class='c'><span class='pos'>${i + 1}</span></td>
        <td class='l'><table class='pl' cellspacing='0' cellpadding='0'><tr>
          <td class='plv'>${levelTile(r, "roster")}</td>
          <td><span class='pname-cell'>${flagImg(r.cc, 13, 10)}<a href='/profile?steamid=${encodeURIComponent(r.steamid || "")}'>${esc(r.name || r.steamid || "Unknown")}</a></span>
          <span class='psub'><span class='${on ? "on" : "offdot"}'>●</span>${on ? "online" : "seen " + esc(ago(now - (Number(r.last_seen) || 0)))}</span></td>
        </tr></table></td>
        <td class='l muted roster-rank'>${esc(rank)}</td>
        <td><span class='xpnum' style='color:${xpColorOf(r.xp)}'>${fmt(r.xp)}</span></td>
      </tr>`
    }).join("")}
  </table></div>` : `<div class='panel msg'><b>No players yet</b><br>The first snapshot lands after a map loads.</div>`

  const content = `<div class='panel msg'><b>Select a player</b><br>In game use <b>/rank</b> or <b>/statsme</b>, or pick a recent player below.</div>${body}`
  return motdFrame({ theme, title: "Player Profile", kicker: "Roster", sub: "Select a player · recent activity", meta, content })
}

export async function pageProfile(env, url) {
  const theme = await loadTheme(env)
  const now = Math.floor(Date.now() / 1000)
  const meta = await serverMeta(env, now)
  const steamid = steamidOf(url)
  if (!steamid) return directory(env, theme, meta, now)

  let p = null
  try {
    p = await env.DB.prepare(`SELECT * FROM players WHERE steamid = ?1`).bind(steamid).first()
  } catch {
    return motdFrame({
      theme, meta, title: "Player Profile", kicker: "Rank Stats · Season 1", sub: "Career snapshot · FreeNova CS 1.6",
      backHref: "/top15", backLabel: "Leaderboard",
      content: `<div class='panel msg'><b>Unable to load this profile</b><br>The panel could not read the snapshot. Try again shortly.</div>`
    })
  }
  if (!p) {
    return motdFrame({
      theme, meta, title: "Player Profile", kicker: "Rank Stats · Season 1", sub: "Career snapshot · FreeNova CS 1.6",
      backHref: "/top15", backLabel: "Leaderboard",
      content: `<div class='panel msg'><b>No snapshot for ${esc(steamid)}</b><br>Play a few minutes on the server, then retry.</div>`
    })
  }

  const rp = rankProgress(p.xp, p.rank_id)
  const own = Boolean(url._fnMotdSid && String(url._fnMotdSid) === steamid)

  let weapons = []
  try {
    weapons = ((await env.DB.prepare(
      `SELECT slot, kills FROM player_weapons WHERE steamid = ?1 ORDER BY kills DESC LIMIT 5`
    ).bind(steamid).all()).results) || []
  } catch {}
  p._weapons = weapons

  try {
    const m = await env.DB.prepare(`SELECT COUNT(*) AS n FROM ap_unlocks WHERE steamid = ?1`).bind(steamid).first()
    p._medals = Number(m && m.n) || 0
  } catch { p._medals = 0 }

  try {
    const rows = ((await env.DB.prepare(
      `SELECT code FROM ap_unlocks WHERE steamid = ?1 ORDER BY earned_at DESC LIMIT 3`
    ).bind(steamid).all()).results) || []
    p._medalCodes = rows.map(r => String(r.code || "").toLowerCase()).filter(Boolean)
  } catch { p._medalCodes = [] }

  let achTotal = 13
  let closest = []
  try {
    const earned = await apUnlocksMap(env, steamid)
    const show = badgeCabinet(p, earned)
    achTotal = show.items.length
    closest = show.items
      .filter(i => !i.unlocked && i.tracked && Number(i.target) > 0)
      .map(i => ({ ...i, pct: Math.max(0, Math.min(100, Math.round(Number(i.val) * 100 / Number(i.target)))) }))
      .sort((a, b) => b.pct - a.pct)
      .slice(0, 4)
  } catch {}

  let compPos = 0
  if (Number(p.comp_points) > 0) {
    try {
      const r = await env.DB.prepare(`SELECT COUNT(*) + 1 AS n FROM players WHERE comp_points > ?1`).bind(p.comp_points).first()
      compPos = Number(r && r.n) || 0
    } catch {}
  }

  let rankPos = 0
  try {
    const r = await env.DB.prepare(`SELECT COUNT(*) + 1 AS n FROM players WHERE xp > ?1`).bind(p.xp).first()
    rankPos = Number(r && r.n) || 1
  } catch { rankPos = 0 }

  // Battle-pass XP per tier comes from the same place /battlepass reads - the
  // `reward_track` catalog row the game pushes, via bp_track.xpPerTier.
  // REVIEW.md §4.3: this used to be a literal 1000, so the profile showed a
  // different tier than the battle pass page whenever the track said otherwise.
  let bpTrack = null
  try {
    const cat = await env.DB.prepare(`SELECT json FROM catalog WHERE key = 'reward_track'`).first()
    if (cat && cat.json) bpTrack = JSON.parse(cat.json)
  } catch {}
  // BattlePass tier/XP come from the BP ledger columns (REVIEW.md §2.4 H1).
  // This used to prefer bp_milestone, then rank level, then rank-xp progress,
  // so the profile could show a BattlePass tier the player never reached.
  const bpNeed = xpPerTier(bpTrack)
  const bpTier = playerBpTier(p, bpNeed)
  const bpProgress = bpInto(p.bp_xp, bpNeed)

  const career = `<table class='career' cellspacing='0' cellpadding='0'><tr>
      <td class='first'><span class='k'>Battle Pass</span><span class='v p'>Tier ${fmt(bpTier)} / 60</span><span class='sub'>${fmt(bpProgress)} / ${fmt(bpNeed)} BP XP</span><a href='/battlepass?steamid=${encodeURIComponent(steamid)}&compact=1'>Open</a></td>
      <td><span class='k'>Competitive</span><span class='v'>${fmt(p.comp_points)} pts</span><span class='sub'>${compPos > 0 ? "#" + fmt(compPos) : "Unranked"}</span><a href='/competitive?steamid=${encodeURIComponent(steamid)}&compact=1'>Open</a></td>
      <td><span class='k'>Achievements</span><span class='v'>${fmt(p._medals)} / ${fmt(achTotal)}</span><span class='sub'>${closest.length ? "Next: " + esc(closest[0].title) : "All medals earned"}</span><a href='/achievements?steamid=${encodeURIComponent(steamid)}&compact=1'>Open</a></td>
    </tr></table>`

  const closestHtml = closest.length
    ? `<div class='sect' style='margin-top:7px;'>Closest medals</div>
      <table class='ach-next' cellspacing='0' cellpadding='0'>${closest.map(i => `<tr>
        <td class='ach-next-art'><img src='${medalSrc(i.id)}' width='30' height='30' alt='' style='opacity:.72'></td>
        <td><div class='ach-next-name'>${esc(i.title || i.name || "Medal")}</div><div class='ach-next-meta'>${fmt(i.val)} / ${fmt(i.target)}</div></td>
        <td class='ach-next-prog'><div class='ach-next-bar'><i style='width:${i.pct}%'></i></div><span>${i.pct}%</span></td>
      </tr>`).join("")}</table>`
    : ""
  p._achTotal = achTotal

  const content = `${idCard(p, rp, rankPos, own, now)}${colsCard(p)}${progressCard(rp)}${career}${closestHtml}`
  return motdFrame({
    theme, meta, title: "Player Profile", kicker: "Rank Stats · Season 1", sub: "Career snapshot · FreeNova CS 1.6",
    backHref: "/top15" + (own ? "?steamid=" + encodeURIComponent(steamid) : ""),
    backLabel: "Leaderboard",
    content
  })
}
