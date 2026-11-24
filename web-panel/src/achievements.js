// Achievements — completion hero, closest unlocks, rarity spread and medal cabinet.
import { loadTheme } from "./top15/store.js"
import { serverMeta } from "./top15/meta.js"
import { motdFrame, esc, fmt, rankFile, rankName } from "./top15/render.js"
import {
  liveAchList, achRarityOf, achCategoryOf, apUnlocksMap, badgeCabinet, achArt
} from "./pages.js"
import {
  ACH_CATEGORIES, RARITY_STYLE, RARITY_ORDER, DEFAULT_ACHIEVEMENTS, DEFAULT_HALL_OF_FAME
} from "./catalogs.js"
import { isMotdCompact } from "./ui.js"

function steamidOf(url) {
  const minted = url && url._fnMotdSid
  if (minted && /^STEAM_[0-9]:[0-9]:\d+$/.test(String(minted))) return String(minted)
  const q = (url.searchParams.get("steamid") || "").trim()
  if (/^STEAM_[0-9]:[0-9]:\d+$/.test(q)) return q
  const m = String(url.pathname || "").match(/\/m\/a\/(\d+-\d+-\d+)/i)
  if (m) return "STEAM_" + m[1].replace(/-/g, ":")
  return ""
}

function ctxQuery(steamid, extra) {
  const p = []
  if (steamid) p.push("steamid=" + encodeURIComponent(steamid))
  if (isMotdCompact()) p.push("compact=1")
  if (extra) p.push(extra)
  return p.length ? "?" + p.join("&") : ""
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

function medalArt(it, idx) {
  const id = String((it && it.id) || "").toLowerCase()
  if (MEDAL_ART[id]) return MEDAL_ART[id]
  const t = String(it.title || it.name || "").toUpperCase()
  if (t.includes("KILLER")) return "/medals/fn_kills_100.png"
  if (t.includes("COIN")) return "/medals/fn_coin_tycoon.png"
  if (t.includes("LEGEND")) return "/medals/fn_level_52.png"
  if (t.includes("MEDIC")) return "/medals/fn_combat_medic.png"
  if (t.includes("HEAD") || t.includes("SHARP")) return "/medals/fn_hs_100.png"
  if (t.includes("BOMB") || t.includes("DEMOLITION")) return "/medals/fn_bomb_specialist.png"
  if (t.includes("KILLING") || t.includes("FIRST BLOOD")) return "/medals/fn_kills_100.png"
  if (t.includes("SEASONED")) return "/medals/fn_hours_100.png"
  if (t.includes("TEAM") || t.includes("UNSTOPPABLE")) return "/medals/fn_wins_100.png"
  return achArt(it, idx)
}

function dateOf(sec) {
  const n = Number(sec) || 0
  if (!n) return ""
  const d = new Date(n > 1e12 ? n : n * 1000)
  return d.toISOString().slice(0, 10)
}

function tabsHtml(steamid, active) {
  const link = (id, label) => id === active
    ? `<span class='pill on'>${label}</span>`
    : `<a class='pill' href='/achievements${ctxQuery(steamid, "tab=" + id)}'>${label}</a>`
  return `<div class='pills' style='margin:0 0 5px;border-top:0;padding-top:0;'>
    ${link("achievements", "Medals")}
    ${link("hof", "Hall of Fame")}
    ${link("records", "Records")}
  </div>`
}

async function hallOfFamePage(env, theme, meta, steamid) {
  let players = []
  let medalRows = []
  try {
    players = ((await env.DB.prepare(
      `SELECT steamid, name, xp, level, kills, headshots, comp_points, rank_id, cc
       FROM players`
    ).all()).results) || []
    medalRows = ((await env.DB.prepare(
      `SELECT steamid, COUNT(*) AS n FROM ap_unlocks GROUP BY steamid`
    ).all()).results) || []
  } catch {}
  const medals = {}
  for (const r of medalRows) medals[String(r.steamid)] = Number(r.n) || 0
  const list = players.map(p => ({
    ...p,
    medals: medals[String(p.steamid)] || 0
  }))
  const medalists = list.filter(p => p.medals > 0)
    .sort((a, b) => b.medals - a.medals || Number(b.xp) - Number(a.xp))
  const totalMedals = medalists.reduce((s, p) => s + p.medals, 0)
  const top = medalists[0]
  const podium = medalists.slice(0, 3)
  const topOf = (field) => list.filter(p => Number(p[field]) > 0)
    .sort((a, b) => Number(b[field]) - Number(a[field]))[0]

  const places = [
    ["1ST", "#f5c451"],
    ["2ND", "#c9d6d2"],
    ["3RD", "#d08a54"]
  ]
  const podiumHtml = `<table class='hof-podium' cellspacing='4' cellpadding='0'><tr>
    ${places.map(([label, color], i) => {
      const p = podium[i]
      const url = p ? "/profile?steamid=" + encodeURIComponent(p.steamid) : ""
      return `<td class='hof-pod${p ? "" : " vacant"}' style='border-top-color:${color}'>
        <div class='hof-place' style='color:${color}'>${label}</div>
        ${p ? `<img class='hof-crest' src='${rankFile(p)}' width='42' height='42' alt=''>
          <div class='hof-name'><a href='${url}'>${esc(p.name || p.steamid || "Unknown")}</a></div>
          <div class='hof-meta'>${fmt(p.medals)} medal${p.medals === 1 ? "" : "s"} · L${fmt(p.level)}</div>
          <div class='hof-meta'>${esc(rankName(p.rank_id))}</div>`
        : `<div class='hof-vacant'>VACANT</div><div class='hof-meta'>First finisher takes this place</div>`}
      </td>`
    }).join("")}
  </tr></table>`

  const leaders = [
    ["Highest XP", topOf("xp"), "xp", "XP"],
    ["Most kills", topOf("kills"), "kills", "kills"],
    ["Most headshots", topOf("headshots"), "headshots", "HS"],
    ["Competitive points", topOf("comp_points"), "comp_points", "pts"]
  ].filter(x => x[1])
  const leaderRows = leaders.map(([label, p, field, unit]) => `<tr>
    <td class='hof-k'>${label}</td>
    <td><a href='/profile?steamid=${encodeURIComponent(p.steamid)}'>${esc(p.name || p.steamid || "Unknown")}</a></td>
    <td class='hof-v'>${fmt(p[field])} ${unit}</td>
  </tr>`).join("")

  const medalTable = medalists.slice(0, 5).map((p, i) => {
    const color = i === 0 ? " gold" : i === 1 ? " silver" : i === 2 ? " bronze" : ""
    return `<tr>
      <td class='c'><span class='pos${color}'>${i + 1}</span></td>
      <td><a href='/profile?steamid=${encodeURIComponent(p.steamid)}'>${esc(p.name || p.steamid || "Unknown")}</a></td>
      <td>${fmt(p.medals)}</td>
      <td class='hof-v'>${fmt(p.xp)} XP</td>
    </tr>`
  }).join("")

  let recent = []
  try {
    recent = ((await env.DB.prepare(
      `SELECT a.code AS code, a.earned_at AS earned_at, p.name AS name, p.steamid AS steamid
       FROM ap_unlocks a JOIN players p ON p.steamid = a.steamid
       WHERE a.earned_at > 0 ORDER BY a.earned_at DESC LIMIT 5`
    ).all()).results) || []
  } catch {}
  const recentRows = recent.map(r => {
    const code = String(r.code || "").toLowerCase()
    return `<tr>
      <td><img class='hof-recent-art' src='${medalArt({ id: code }, 0)}' width='24' height='24' alt=''> ${esc(MEDAL_NAME[code] || code.replace(/_/g, " ").toUpperCase())}</td>
      <td><a href='/profile?steamid=${encodeURIComponent(r.steamid || "")}'>${esc(r.name || "Unknown")}</a></td>
      <td class='hof-v'>${esc(dateOf(r.earned_at) || "—")}</td>
    </tr>`
  }).join("")

  const kpis = `<table class='kpis' cellspacing='4' cellpadding='0'><tr>
    <td><span class='k'>Medalists</span><span class='v p'>${fmt(medalists.length)}</span></td>
    <td><span class='k'>Medals earned</span><span class='v'>${fmt(totalMedals)}</span></td>
    <td><span class='k'>Top holder</span><span class='v'>${top ? esc(top.name || "—") : "—"}</span></td>
    <td><span class='k'>Players</span><span class='v'>${fmt(list.length)}</span></td>
  </tr></table>`

  const content = `${tabsHtml(steamid, "hof")}${kpis}
    <div class='sect' style='margin-top:8px;'>Medal leaderboard</div>
    ${podiumHtml}
    <div class='sect' style='margin-top:8px;'>Top medalists</div>
    <table class='hof-leaders' cellspacing='0' cellpadding='0'>
      <tr><th class='c'>#</th><th>Player</th><th>Medals</th><th class='hof-v'>XP</th></tr>
      ${medalTable || `<tr><td colspan='4'><div class='panel msg'><b>No medals earned yet</b></div></td></tr>`}
    </table>
    <div class='sect' style='margin-top:8px;'>Live leaders</div>
    <table class='hof-leaders' cellspacing='0' cellpadding='0'>${leaderRows || `<tr><td colspan='3'><div class='panel msg'><b>No live leaders yet</b></div></td></tr>`}</table>
    ${recentRows ? `<div class='sect' style='margin-top:8px;'>Recent medal unlocks</div>
      <table class='hof-leaders' cellspacing='0' cellpadding='0'>
        <tr><th>Medal</th><th>Player</th><th class='hof-v'>Earned</th></tr>
        ${recentRows}
      </table>` : ""}`

  return motdFrame({
    theme, meta,
    title: "Achievements",
    kicker: "Hall of Fame · Live",
    sub: `${medalists.length} medalists · ${fmt(totalMedals)} medals earned`,
    backHref: steamid ? "/profile?steamid=" + encodeURIComponent(steamid) : "/top",
    backLabel: steamid ? "Profile" : "Leaderboard",
    content
  })
}

async function recordsPage(env, theme, meta, steamid) {
  let hof = DEFAULT_HALL_OF_FAME
  try {
    const c = await env.DB.prepare(`SELECT json FROM catalog WHERE key = 'hall_of_fame'`).first()
    if (c && c.json) hof = JSON.parse(c.json)
  } catch {}
  const defs = Array.isArray(hof.server_records) ? hof.server_records
    : (Array.isArray(hof.server_records_catalog) ? hof.server_records_catalog : [])
  const byKey = {}
  for (const d of defs) if (d && d.key) byKey[d.key] = d

  let prow = []
  let wrow = []
  try { prow = ((await env.DB.prepare(`SELECT * FROM players`).all()).results) || [] } catch {}
  try {
    wrow = ((await env.DB.prepare(
      `SELECT w.slot AS slot, w.kills AS kills, p.name AS name, p.steamid AS steamid
       FROM player_weapons w JOIN players p ON p.steamid = w.steamid`
    ).all()).results) || []
  } catch {}

  const hasCol = (r, k) => r && Object.prototype.hasOwnProperty.call(r, k) && r[k] != null
  const bestP = (need, val, txt) => {
    let b = null
    for (const r of prow) {
      if (!need(r)) continue
      const v = val(r)
      if (v == null) continue
      if (!b || v > b.v) b = { v, t: txt(r, v), name: r.name, steamid: r.steamid }
    }
    return b
  }
  const bestW = (slot) => {
    let b = null
    for (const w of wrow) {
      if (Number(w.slot) !== slot || Number(w.kills) <= 0) continue
      if (!b || Number(w.kills) > Number(b.kills)) b = w
    }
    return b ? { name: b.name, steamid: b.steamid, t: fmt(b.kills) + " kills" } : null
  }
  const HOLDERS = {
    highest_rating: () => bestP(r => Number(r.rating_x100) > 0, r => Number(r.rating_x100), (r, v) => (v / 100).toFixed(2) + " rating"),
    most_kills: () => bestP(r => Number(r.kills) > 0, r => Number(r.kills), (r, v) => fmt(v) + " kills"),
    highest_kd: () => bestP(r => Number(r.deaths) >= 20, r => Number(r.kills) / Math.max(1, Number(r.deaths)), (r, v) => v.toFixed(2) + " K/D"),
    most_headshots: () => bestP(r => Number(r.headshots) > 0, r => Number(r.headshots), (r, v) => fmt(v) + " HS"),
    highest_hs_pct: () => bestP(r => Number(r.kills) >= 100, r => Number(r.headshots) / Number(r.kills), (r, v) => (100 * v).toFixed(1) + " %"),
    longest_killstreak: () => bestP(
      r => (hasCol(r, "ach_streak") ? Number(r.ach_streak) : Number(r.bp_daily_streak)) > 0,
      r => (hasCol(r, "ach_streak") ? Number(r.ach_streak) : Number(r.bp_daily_streak)),
      (r, v) => fmt(v) + " streak"
    ),
    most_mvps: () => bestP(r => Number(r.mvps) > 0, r => Number(r.mvps), (r, v) => fmt(v) + " MVPs"),
    most_ak_kills: () => bestW(0),
    most_awp_kills: () => bestW(2),
    most_deagle_kills: () => bestW(3),
    most_knife_kills: () => bestW(4),
    most_playtime: () => bestP(r => Number(r.playtime_minutes) > 0, r => Number(r.playtime_minutes),
      (r, v) => Math.floor(v / 60) + "h " + (v % 60) + "m")
  }
  const GROUPS = [
    { title: "Combat", color: "#ff6b6b", keys: ["highest_rating", "most_kills", "highest_kd", "highest_adr", "most_match_kills"] },
    { title: "Precision", color: "#7dd3fc", keys: ["most_headshots", "highest_hs_pct", "most_wallbangs", "longest_killstreak"] },
    { title: "Honors", color: "#f5c451", keys: ["most_1v5_clutches", "most_mvps"] },
    { title: "Arsenal", color: "#b18cff", keys: ["most_ak_kills", "most_awp_kills", "most_deagle_kills", "most_knife_kills"] },
    { title: "Dedication", color: "#3dff9e", keys: ["most_playtime"] }
  ]

  let held = 0
  const holderCount = {}
  const groups = GROUPS.map(g => {
    const rows = g.keys.map(k => {
      const def = byKey[k] || { name: k, unit: "" }
      const hold = HOLDERS[k] ? HOLDERS[k]() : null
      if (hold) {
        held++
        const key = String(hold.steamid || hold.name)
        holderCount[key] = (holderCount[key] || 0) + 1
      }
      return `<tr class='${hold ? "" : "pending"}'>
        <td class='rec-name'>${esc(def.name || k)}</td>
        <td class='rec-holder'>${hold ? `<a href='/profile?steamid=${encodeURIComponent(hold.steamid || "")}'>${esc(hold.name || "—")}</a>` : "<span class='muted'>—</span>"}</td>
        <td class='rec-val'>${hold ? esc(hold.t) : "<span class='muted'>Tracked in-game</span>"}</td>
      </tr>`
    }).join("")
    return `<div class='sect rec-grouptitle' style='color:${g.color}'>${g.title}</div>
      <table class='rec-list' cellspacing='0' cellpadding='0'>${rows}</table>`
  }).join("")

  let topHolder = "—"
  let topCount = 0
  for (const [sid, n] of Object.entries(holderCount)) {
    if (n > topCount) {
      topCount = n
      const p = prow.find(x => String(x.steamid) === sid)
      topHolder = p ? p.name : "—"
    }
  }

  const kpis = `<table class='kpis' cellspacing='4' cellpadding='0'><tr>
    <td><span class='k'>Live records</span><span class='v p'>${fmt(held)} / ${fmt(defs.length)}</span></td>
    <td><span class='k'>Top holder</span><span class='v'>${esc(topHolder)}</span></td>
    <td><span class='k'>Records held</span><span class='v'>${fmt(topCount)}</span></td>
    <td><span class='k'>Categories</span><span class='v'>${fmt(GROUPS.length)}</span></td>
  </tr></table>`

  const content = `${tabsHtml(steamid, "records")}${kpis}${groups}`

  return motdFrame({
    theme, meta,
    title: "Achievements",
    kicker: "Server Records · Live",
    sub: `${held} of ${defs.length} records held · live snapshot`,
    backHref: steamid ? "/profile?steamid=" + encodeURIComponent(steamid) : "/top",
    backLabel: steamid ? "Profile" : "Leaderboard",
    content
  })
}

export async function pageAchievements(env, url) {
  const tab = String(url.searchParams.get("tab") || "achievements").toLowerCase()

  const theme = await loadTheme(env)
  const now = Math.floor(Date.now() / 1000)
  const meta = await serverMeta(env, now)
  const steamid = steamidOf(url)

  if (tab === "hof" || tab === "halloffame") return hallOfFamePage(env, theme, meta, steamid)
  if (tab === "records") return recordsPage(env, theme, meta, steamid)

  if (!steamid) {
    return motdFrame({
      theme, meta, title: "Achievements", kicker: "Medals · Season 1",
      sub: "Open this panel from the game",
      backHref: "/", backLabel: "Panels",
      content: `<div class='panel msg'><b>Open from the game</b><br>Run <b>/achievements</b> in chat, or open your profile from the leaderboard.</div>`
    })
  }

  let p = null
  try {
    p = await env.DB.prepare(`SELECT * FROM players WHERE steamid = ?1`).bind(steamid).first()
  } catch {}
  if (!p) {
    return motdFrame({
      theme, meta, title: "Achievements", kicker: "Medals · Season 1",
      sub: "No player snapshot",
      backHref: "/top15", backLabel: "Leaderboard",
      content: `<div class='panel msg'><b>No snapshot for ${esc(steamid)}</b><br>Play a few minutes on the server, then retry.</div>`
    })
  }

  let ach = DEFAULT_ACHIEVEMENTS
  try {
    const cat = await env.DB.prepare(`SELECT json FROM catalog WHERE key = 'achievements'`).first()
    if (cat && cat.json) ach = JSON.parse(cat.json)
  } catch {}
  const list = liveAchList(ach)
  const earnedMap = await apUnlocksMap(env, steamid)
  const show = badgeCabinet(p, earnedMap)

  const catFilter = String(url.searchParams.get("cat") || "all").toLowerCase()
  const items = show.items.filter(i =>
    catFilter === "all" || (i.category || achCategoryOf(i.id)) === catFilter
  )
  const unlocked = show.items.filter(i => i.unlocked).length
  const total = show.items.length
  const completion = total ? Math.round(unlocked * 100 / total) : 0
  const latest = show.items
    .filter(i => i.unlocked)
    .sort((a, b) => (Number(b.earned_at) || 0) - (Number(a.earned_at) || 0))[0]

  const closest = show.items
    .filter(i => !i.unlocked && i.tracked && Number(i.target) > 0)
    .map(i => ({ ...i, pct: Math.max(0, Math.min(100, Math.round(Number(i.val) * 100 / Number(i.target)))) }))
    .sort((a, b) => b.pct - a.pct)
    .slice(0, 3)

  const tabs = `<div class='pills' style='margin:0 0 5px;border-top:0;padding-top:0;'>
    <span class='pill on'>Medals</span>
    <a class='pill' href='/achievements${ctxQuery(steamid, "tab=hof")}'>Hall of Fame</a>
    <a class='pill' href='/achievements${ctxQuery(steamid, "tab=records")}'>Records</a>
  </div>`

  const hero = `<table class='ach-hero' cellspacing='0' cellpadding='0'><tr>
      <td class='ach-hero-pct'>
        <div class='ach-pct'>${completion}%</div>
        <div class='ach-kicker'>Completion</div>
      </td>
      <td class='ach-hero-mid'>
        <div class='ach-hero-title'>${fmt(unlocked)} of ${fmt(total)} medals</div>
        <div class='ach-hero-bar'><i style='width:${completion}%'></i></div>
        <div class='ach-hero-meta'>${fmt(show.earnedAP)} / ${fmt(show.totalAP)} AP · ${fmt(total - unlocked)} to go</div>
      </td>
      <td class='ach-hero-latest'>
        <div class='ach-kicker'>Latest unlock</div>
        ${latest
          ? `<table class='ach-latest' cellspacing='0' cellpadding='0'><tr>
              <td class='ach-latest-art'><img src='${medalArt(latest, 0)}' width='30' height='30' alt=''></td>
              <td><div class='ach-latest-name'>${esc(latest.title || latest.name || "Medal")}</div>
                <div class='ach-latest-date'>${esc(dateOf(latest.earned_at) || "Unlocked")}</div></td>
            </tr></table>`
          : `<div class='ach-latest-empty'>No medals yet</div>`}
      </td>
    </tr></table>`

  const rarityCells = RARITY_ORDER.map(r => {
    const style = RARITY_STYLE[r]
    const all = show.items.filter(i => i.rarity === r)
    const got = all.filter(i => i.unlocked).length
    return `<td><span class='k' style='color:${style.color}'>${esc(style.label)}</span><span class='v'>${got} / ${all.length}</span></td>`
  }).join("")
  const rarityBar = `<table class='ach-rarity' cellspacing='4' cellpadding='0'><tr>${rarityCells}</tr></table>`

  const closestRows = closest.length
    ? closest.map(i => {
        const style = RARITY_STYLE[i.rarity] || RARITY_STYLE.common
        return `<tr>
          <td class='ach-next-art'><img src='${medalArt(i, 0)}' width='30' height='30' alt='' style='opacity:.72'></td>
          <td>
            <div class='ach-next-name'>${esc(i.title || i.name || "Medal")}</div>
            <div class='ach-next-meta' style='color:${style.color}'>${esc(style.label)} · ${fmt(i.ap)} AP</div>
          </td>
          <td class='ach-next-prog'><div class='ach-next-bar'><i style='width:${i.pct}%'></i></div><span>${fmt(i.val)} / ${fmt(i.target)}</span></td>
          <td class='ach-next-pct'>${i.pct}%</td>
        </tr>`
      }).join("")
    : `<tr><td colspan='4'><div class='panel msg'><b>All medals unlocked</b></div></td></tr>`

  const cats = [{ id: "all", name: "All" }, ...ACH_CATEGORIES]
  const filters = `<div class='pills' style='margin:0 0 6px;border-top:0;padding-top:0;'>${cats.map(c =>
    c.id === catFilter
      ? `<span class='pill on'>${esc(c.name)}</span>`
      : `<a class='pill' href='/achievements${ctxQuery(steamid, "cat=" + c.id)}'>${esc(c.name)}</a>`
  ).join("")}</div>`

  const cells = items.map((it, idx) => {
    const rarity = it.rarity || achRarityOf(it.id)
    const style = RARITY_STYLE[rarity] || RARITY_STYLE.common
    const art = medalArt(it, idx)
    const cat = it.category || achCategoryOf(it.id)
    const target = Number(it.target) || 0
    const val = Number(it.val) || 0
    const pct = it.unlocked ? 100 : (target > 0 ? Math.max(0, Math.min(100, Math.round(val * 100 / target))) : 0)
    const prog = it.unlocked
      ? "Unlocked"
      : (it.tracked && target > 0 ? `${fmt(Math.min(val, target))} / ${fmt(target)}` : (it.note || "Tracked in game"))
    return `<td class='ach-cell'>
      <div class='ach-tile${it.unlocked ? " unlocked" : " locked"}' style='border-top-color:${style.frame}'>
        <div class='ach-artwrap'>
          <img class='ach-art' src='${art}' width='64' height='64' alt='' style='opacity:${it.unlocked ? 1 : 0.46}'>
          ${it.unlocked ? `<span class='ach-check'>&#10003;</span>` : ""}
        </div>
        <div class='ach-name'>${esc(it.title || it.name || "Medal")}</div>
        <div class='ach-cat'>${esc(cat)} · ${fmt(it.ap)} AP</div>
        <div class='ach-tile-bar'><i style='width:${pct}%'></i></div>
        <div class='ach-tile-foot'>
          <span class='ach-tile-prog'>${esc(prog)}</span>
          <span class='ach-rar' style='color:${style.color};border-color:${style.frame};'>${esc(style.label)}</span>
        </div>
      </div>
    </td>`
  })

  const rows = []
  for (let i = 0; i < cells.length; i += 3) {
    rows.push(`<tr>${cells.slice(i, i + 3).join("")}${cells.length - i < 3 ? `<td class='ach-cell'></td>`.repeat(3 - (cells.length - i)) : ""}</tr>`)
  }

  const grid = items.length
    ? `<table class='ach-grid' cellspacing='4' cellpadding='0'>${rows.join("")}</table>`
    : `<div class='panel msg'><b>No medals in this category</b><br>Try another filter.</div>`

  const content = `${tabs}${hero}${rarityBar}
    <div class='sect' style='margin-top:8px;'>Closest unlocks</div>
    <table class='ach-next' cellspacing='0' cellpadding='0'>${closestRows}</table>
    ${filters}
    ${grid}`

  return motdFrame({
    theme, meta,
    title: "Achievements",
    kicker: "Medals · Season 1",
    sub: `${unlocked} of ${total} unlocked · ${fmt(show.earnedAP)} / ${fmt(show.totalAP)} AP`,
    backHref: "/profile" + ctxQuery(steamid),
    backLabel: "Profile",
    content
  })
}
