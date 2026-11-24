// Live stats viewer MOTD — online players, sortable. Same shell and level
// tiles as the Top 15; table layout only for GoldSrc.
import { loadTheme } from "./store.js"
import { serverMeta } from "./meta.js"
import {
  motdFrame, esc, fmt, rankName, rankFile, isOn, kdOf, ago
} from "./render.js"
import { skillOf } from "./theme.js"
import { flagImg, isMotdCompact } from "../ui.js"

const MODES = {
  xp: { label: "XP", sql: "p.xp" },
  kills: { label: "Kills", sql: "p.kills" },
  mvp: { label: "MVP", sql: "p.mvps" },
  wins: { label: "Wins", sql: "p.wins" },
  playtime: { label: "Playtime", sql: "p.playtime_minutes" },
  skill: { label: "Skill", sql: "CASE WHEN (p.kills + p.deaths) > 0 THEN (100.0 * p.kills / (p.kills + p.deaths)) ELSE 0 END" }
}

function skillPill(kills, deaths) {
  const s = skillOf(kills, deaths)
  const fg = s.name === "G" ? "#fff" : "#111"
  return `<span class='skill' style='background-color:${s.color};color:${fg}'>${esc(s.name)} ${Math.round(s.ratio)}</span>`
}

function played(min) {
  const m = Number(min) || 0
  if (!m) return "—"
  if (m < 60) return m + "m"
  const h = Math.floor(m / 60)
  const r = m % 60
  return h + "h" + (r ? " " + r + "m" : "")
}

export async function pageStatsViewer(env, url) {
  const theme = await loadTheme(env)
  const now = Math.floor(Date.now() / 1000)
  const meta = await serverMeta(env, now)
  const steamid = String(url.searchParams.get("steamid") || "")
  const requested = String(url.searchParams.get("sort") || "xp").toLowerCase()
  const sort = Object.prototype.hasOwnProperty.call(MODES, requested) ? requested : "xp"
  const mode = MODES[sort]

  let rows = []
  try {
    rows = ((await env.DB.prepare(
      `SELECT p.steamid, p.name, p.xp, p.kills, p.deaths, p.mvps, p.wins,
              p.playtime_minutes, p.rank_id, p.level, p.last_seen, p.cc
       FROM players p
       WHERE p.last_seen > ?1
       ORDER BY ${mode.sql} DESC, p.xp DESC, p.steamid ASC LIMIT 32`
    ).bind(now - 900).all()).results) || []
  } catch { rows = [] }

  const pills = Object.keys(MODES).map(k => {
    const href = "/statsviewer?sort=" + k + (steamid ? "&steamid=" + encodeURIComponent(steamid) : "") + (isMotdCompact() ? "&compact=1" : "")
    return k === sort
      ? `<span class='pill on'>${esc(MODES[k].label)}</span>`
      : `<a class='pill' href='${href}'>${esc(MODES[k].label)}</a>`
  }).join("")

  let tableRows = ""
  if (rows.length) {
    tableRows = rows.map((r, i) => {
      const rank = rankName(r.rank_id)
      const on = isOn(r, now)
      const me = steamid && r.steamid === steamid
      const seen = on ? "Online now" : (Number(r.last_seen) ? "Last seen " + ago(now - Number(r.last_seen)) + " ago" : "No activity data")
      return `<tr class='${me ? "you" : (i % 2 ? "even" : "odd")}' style='cursor:pointer;' onclick="location.href='/profile?steamid=${encodeURIComponent(r.steamid || "")}'">
        <td class='c'><span class='pos'>${i + 1}</span></td>
        <td class='l'>
          <span class='pname-cell'>${flagImg(r.cc, 13, 10)}<a href='/profile?steamid=${encodeURIComponent(r.steamid || "")}'>${esc(r.name || r.steamid || "Unknown")}</a></span>
          <span class='psub' title='${esc(seen)}'>L${Number(r.level) || 1} · ${esc(rank)} · ${on ? "online" : (Number(r.last_seen) ? "seen " + esc(ago(now - Number(r.last_seen))) : "—")}</span>
        </td>
        <td><span class='xpnum'>${fmt(r.xp)}</span></td>
        <td>${fmt(r.kills)}</td>
        <td>${kdOf(r)}</td>
        <td class='muted'>${played(r.playtime_minutes)}</td>
        <td class='c'>${skillPill(r.kills, r.deaths)}</td>
        <td class='c'><img class='rankimg' src='${rankFile(r)}' width='22' height='22' alt='${esc(rank)}' title='${esc(rank)}'></td>
      </tr>`
    }).join("")
  } else {
    tableRows = `<tr><td colspan='8'><div class='msg'><b>No players online</b><br>The viewer lists players active in the last 15 minutes.</div></td></tr>`
  }

  const content = `<div class='pills' style='border-top:0;padding-top:0;margin:0 0 5px;'>
      <span class='wlab'>Sort players</span>
      <span class='clr' style='float:right;'>${rows.length} recent</span>
    </div>
    <div class='pills' style='border-top:0;padding-top:0;margin:0 0 5px;'>${pills}</div>
    <div class='boardwrap'>
      <table class='board' cellspacing='0' cellpadding='0'>
        <colgroup>
          <col style='width:6%'><col style='width:38%'><col style='width:14%'><col style='width:8%'>
          <col style='width:9%'><col style='width:9%'><col style='width:8%'><col style='width:8%'>
        </colgroup>
        <tr>
          <th class='c'>#</th><th class='l'>Player</th><th>XP</th><th>K</th>
          <th>K/D</th><th>Time</th><th class='c'>Skill</th><th class='c'>Rank</th>
        </tr>
        ${tableRows}
      </table>
    </div>`

  return motdFrame({
    theme, meta, title: "Stats Viewer", kicker: "Activity · Last 15 min", sub: "Players active in the last 15 minutes · sorted by performance",
    backHref: "/top15", backLabel: "Leaderboard",
    content
  })
}
