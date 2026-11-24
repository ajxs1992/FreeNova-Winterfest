// Weekly / monthly boards on the website (/top/week, /top/month).
//
// Deliberately thin: the numbers come from src/boards.js, the boundaries from
// src/periods.js — the exact same functions /api/public/top and the MOTD top
// page call. This page exists so "the site" has a weekly/monthly board that
// cannot disagree with the bot or the in-game panel.
import { loadTheme } from "./top15/store.js"
import { serverMeta } from "./top15/meta.js"
import { motdFrame, esc, fmt } from "./top15/render.js"
import { periodBoard, recentChampions } from "./boards.js"

export async function pageBoards(env, url, period) {
  const p = period === "month" ? "month" : "week"
  const theme = await loadTheme(env)
  const now = Math.floor(Date.now() / 1000)
  const meta = await serverMeta(env, now)
  const board = await periodBoard(env, { period: p, metric: "xp", limit: 15, now })
  const champions = await recentChampions(env, p, 3)
  const compact = url.searchParams.get("compact") === "1"

  const rows = board.rows.length
    ? board.rows.map(r => `<tr class='${r.rank <= 3 ? "top" : "row"}'>
        <td class='c'><span class='pos${r.rank === 1 ? " gold" : r.rank === 2 ? " silver" : r.rank === 3 ? " bronze" : ""}'>${fmt(r.rank)}</span></td>
        <td class='l'><a href='/profile?steamid=${encodeURIComponent(r.steamid || "")}${compact ? "&compact=1" : ""}'>${esc(r.name || r.steamid || "Unknown")}</a></td>
        <td><span class='xpnum'>${fmt(r.value)}</span></td>
      </tr>`).join("")
    : `<tr><td colspan='3'><div class='msg'><b>No ${p} progress recorded yet</b><br>
        The panel starts counting a player's ${p} XP from the first snapshot it sees inside the period.</div></td></tr>`

  const coverage = board.coverage.complete
    ? "Complete period so far: the panel has observed every listed player since the period started."
    : `Period to date${board.coverage.first_seen ? ` — counting from ${esc(new Date(board.coverage.first_seen * 1000).toISOString().slice(0, 16).replace("T", " "))} UTC` : ""}. Players first seen later are under-counted; nothing is extrapolated.`

  const champHtml = champions.length
    ? `<div class='sect' style='margin-top:8px;'>Previous winners</div>
       <table class='board' cellspacing='0' cellpadding='0'>
         <tr><th>Player</th><th class='l'>Period</th><th>XP</th></tr>
         ${champions.map(c => `<tr><td class='l'><b>${esc(c.name || c.steamid || "?")}</b></td>
           <td class='l muted'>${esc(c.label || c.period_key)}</td>
           <td><span class='xpnum'>${fmt(c.value)}</span></td></tr>`).join("")}
       </table>`
    : `<div class='panel msg'>No settled ${p} on record yet. The first snapshot of a finished period appears here.</div>`

  const tabs = [["week", "This week", "/top/week"], ["month", "This month", "/top/month"]]
    .map(([k, label, href]) => k === p
      ? `<span class='pill on'>${label}</span>`
      : `<a class='pill' href='${href}${compact ? "?compact=1" : ""}'>${label}</a>`).join("")

  const content = `<div class='kpis' cellspacing='4' cellpadding='0'><tr>
      <td><span class='k'>Window</span><span class='v'>${esc(board.label)}</span><span class='sub'>${esc(board.key)}</span></td>
      <td><span class='k'>Timezone</span><span class='v p'>${esc(board.tz)}</span></td>
      <td><span class='k'>Starts</span><span class='v'>${esc(new Date(board.start * 1000).toISOString().slice(0, 16).replace("T", " "))}</span></td>
      <td><span class='k'>Ranked</span><span class='v'>${fmt(board.total)}</span></td>
    </tr></table>
    <div class='pills'>${tabs}</div>
    <div class='boardwrap'><table class='board' cellspacing='0' cellpadding='0'>
      <colgroup><col style='width:10%'><col style='width:68%'><col style='width:22%'></colgroup>
      <tr><th class='c'>#</th><th class='l'>Player</th><th>XP this ${esc(p)}</th></tr>
      ${rows}
    </table></div>
    <div class='panel msg'>${esc(coverage)}</div>
    ${champHtml}`

  return motdFrame({
    theme, meta,
    title: p === "month" ? "Monthly board" : "Weekly board",
    kicker: p === "month" ? "Calendar month · Europe/Paris" : "ISO week · Europe/Paris",
    sub: `${board.label} · ${fmt(board.total)} ranked`,
    backHref: "/top15",
    backLabel: "Top 15",
    content
  })
}
