// Map-end MOTD — final standings, same shell as the Top 15.
// The old page split the first ten players into fake T/CT teams; this one
// shows one honest top-10 table plus the podium.
import { loadTheme } from "./store.js"
import { serverMeta } from "./meta.js"
import {
  motdFrame, esc, fmt, rankName, rankFile, kdOf, isOn, ago, podiumCard
} from "./render.js"
import { flagImg } from "../ui.js"

export async function pageMapEnd(env, url) {
  const theme = await loadTheme(env)
  const now = Math.floor(Date.now() / 1000)
  const meta = await serverMeta(env, now)
  const steamid = String(url.searchParams.get("steamid") || "")
  const rawMap = String(url.searchParams.get("map") || "THIS MAP").replace(/[^a-zA-Z0-9_]/g, "").slice(0, 24)
  const map = (rawMap || "THIS MAP").toUpperCase()

  let rows = []
  try {
    rows = ((await env.DB.prepare(
      `SELECT steamid, name, xp, kills, deaths, headshots, rank_id, last_seen, cc, level, wins, mvps
       FROM players ORDER BY xp DESC, kills DESC, steamid ASC LIMIT 10`
    ).all()).results) || []
  } catch {
    return motdFrame({
      theme, meta, title: "Map End", kicker: "Match Result", sub: map,
      backHref: "/top15", backLabel: "Leaderboard",
      content: `<div class='panel msg'><b>Unable to load map-end</b><br>The panel could not read the snapshot.</div>`
    })
  }

  const c = { steamid }
  const maxXp = Math.max(1, ...rows.map(r => Number(r.xp) || 0))
  const podiumRows = rows.slice(0, 3)
  const boardRows = rows.slice(3)
  const yourIndex = steamid ? rows.findIndex(r => r.steamid === steamid) : -1

  let podium = ""
  if (podiumRows.length) {
    const cards = []
    if (podiumRows[1]) cards.push(podiumCard(podiumRows[1], 2, c, now, maxXp))
    if (podiumRows[0]) cards.push(podiumCard(podiumRows[0], 1, c, now, maxXp))
    if (podiumRows[2]) cards.push(podiumCard(podiumRows[2], 3, c, now, maxXp))
    podium = `<table class='podium' cellspacing='4' cellpadding='0'><tr>${cards.join("")}</tr></table>`
  }

  let tableRows = ""
  if (boardRows.length) {
    tableRows = boardRows.map((r, i) => {
      const pos = i + 4
      const me = steamid && r.steamid === steamid
      const on = isOn(r, now)
      const rank = rankName(r.rank_id)
      const url = "/profile?steamid=" + encodeURIComponent(r.steamid || "")
      const seen = on ? "Online now" : (Number(r.last_seen) ? "Last seen " + ago(now - Number(r.last_seen)) + " ago" : "No activity data")
      return `<tr class='${me ? "you" : "row"}' style='cursor:pointer;' onclick="location.href='${url}'">
        <td class='c'><span class='pos'>${pos}</span></td>
        <td class='l'>
          <span class='pname-cell'>${flagImg(r.cc, 13, 10)}<a href='${url}'>${esc(r.name || r.steamid || "Unknown")}</a>${me ? "<span class='youtag'>YOU</span>" : ""}</span>
          <span class='psub' title='${esc(seen)}'>L${Number(r.level) || 1} · ${esc(rank)} · ${on ? "online" : (Number(r.last_seen) ? "seen " + esc(ago(now - Number(r.last_seen))) : "—")}</span>
        </td>
        <td><span class='xpnum'>${fmt(r.xp)}</span></td>
        <td>${fmt(r.kills)}</td>
        <td class='muted'>${fmt(r.deaths)}</td>
        <td>${kdOf(r)}</td>
        <td class='c'><img class='rankimg' src='${rankFile(r)}' width='22' height='22' alt='${esc(rank)}' title='${esc(rank)}'></td>
      </tr>`
    }).join("")
  } else if (!rows.length) {
    tableRows = `<tr><td colspan='7'><div class='msg'><b>No snapshot yet</b><br>The map-end board fills after the first XP push.</div></td></tr>`
  }

  const yourRank = yourIndex >= 0 ? "#" + (yourIndex + 1) : "—"
  const content = `<table class='kpis' cellspacing='4' cellpadding='0'><tr>
      <td><span class='k'>Map</span><span class='v'>${esc(map)}</span></td>
      <td><span class='k'>Standings</span><span class='v p'>${fmt(rows.length)}</span></td>
      <td><span class='k'>Peak XP</span><span class='v'>${fmt(maxXp)}</span></td>
      <td><span class='k'>Your place</span><span class='v'>${esc(yourRank)}</span></td>
    </tr></table>
    ${podium}
    <div class='sect' style='margin-top:8px;'>${boardRows.length ? `Ranks 4–${3 + boardRows.length} · top 3 above` : "Top 3"}</div>
    <div class='boardwrap'>
      <table class='board' cellspacing='0' cellpadding='0'>
        <colgroup>
          <col style='width:6%'><col style='width:40%'><col style='width:14%'>
          <col style='width:8%'><col style='width:8%'><col style='width:10%'><col style='width:14%'>
        </colgroup>
        <tr>
          <th class='c'>#</th><th class='l'>Player</th><th>XP</th>
          <th>K</th><th>D</th><th>K/D</th><th class='c'>Rank</th>
        </tr>
        ${tableRows}
      </table>
    </div>`

  return motdFrame({
    theme, meta,
    title: "Map End",
    kicker: "Match Result · Final Standings",
    sub: `${map} · top ${rows.length || 10} by XP`,
    backHref: "/top15" + (steamid ? "?steamid=" + encodeURIComponent(steamid) : ""),
    backLabel: "Leaderboard",
    content
  })
}
