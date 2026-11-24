// Missions panel — daily/bonus/weekly/special contracts in one compact MOTD.
import { loadTheme } from "./top15/store.js"
import { serverMeta } from "./top15/meta.js"
import { motdFrame, esc, fmt } from "./top15/render.js"
import { missionGroups, missionDone } from "./pages.js"

function steamidOf(url) {
  const minted = url && url._fnMotdSid
  if (minted && /^STEAM_[0-9]:[0-9]:\d+$/.test(String(minted))) return String(minted)
  const q = (url.searchParams.get("steamid") || "").trim()
  if (/^STEAM_[0-9]:[0-9]:\d+$/.test(q)) return q
  const m = String(url.pathname || "").match(/\/m\/i\/(\d+-\d+-\d+)/i)
  if (m) return "STEAM_" + m[1].replace(/-/g, ":")
  return ""
}

export async function pageMissions(env, url) {
  const theme = await loadTheme(env)
  const now = Math.floor(Date.now() / 1000)
  const meta = await serverMeta(env, now)
  const steamid = steamidOf(url)

  if (!steamid) {
    return motdFrame({
      theme, meta, title: "Missions", kicker: "Contracts · Season 1",
      sub: "Open this panel from the game",
      backHref: "/", backLabel: "Panels",
      content: `<div class='panel msg'><b>Open from the game</b><br>Run <b>/missions</b> in chat.</div>`
    })
  }

  let p = null
  try {
    p = await env.DB.prepare(`SELECT * FROM players WHERE steamid = ?1`).bind(steamid).first()
  } catch {}
  if (!p) {
    return motdFrame({
      theme, meta, title: "Missions", kicker: "Contracts · Season 1",
      sub: "No player snapshot",
      backHref: "/profile", backLabel: "Profile",
      content: `<div class='panel msg'><b>No snapshot for ${esc(steamid)}</b><br>Play a few minutes on the server, then retry.</div>`
    })
  }

  const g = missionGroups(p)
  const dailyDone = g.daily.filter(missionDone).length
  const bonusDone = g.bonus.filter(missionDone).length
  const weeklyDone = g.weekly.filter(missionDone).length
  const specialDone = g.special.filter(missionDone).length

  const section = (title, list, note) => {
    const rows = list.map(m => {
      const done = missionDone(m)
      const val = Number(m.val) || 0
      const target = Number(m.target) || 0
      const pct = target > 0 ? Math.max(0, Math.min(100, Math.round(val * 100 / target))) : 0
      const tracker = !!m.tracker
      const desc = `${m.desc || ""}${m.reward ? " · " + m.reward : ""}`
      return `<tr class='msn-row${done ? " done" : ""}${tracker ? " tracker" : ""}'>
        <td class='msn-ic'><img src='${esc(m.icon || "/missions/msn_01.png?v=4")}' width='34' height='34' alt='' onerror='this.style.display="none"'></td>
        <td>
          <div class='msn-title'>${esc(m.title || "Mission")}</div>
          <span class='msn-desc' title='${esc(desc)}'>${esc(desc)}</span>
        </td>
        <td class='msn-prog'>
          ${tracker ? `<span>${fmt(val)} tracked</span>` : `<div class='mbar'><i style='width:${pct}%'></i></div><span>${fmt(Math.min(val, target))} / ${fmt(target)}</span>`}
        </td>
        <td class='msn-state'>${done ? "Done" : (tracker ? "Tracker" : "Open")}</td>
      </tr>`
    }).join("")
    return `<div class='sect' style='margin-top:8px;'>${esc(title)}</div>
      <table class='msn-list' cellspacing='0' cellpadding='0'>${rows}</table>`
  }

  const content = `<table class='kpis' cellspacing='4' cellpadding='0'><tr>
      <td><span class='k'>Daily</span><span class='v p'>${dailyDone} / ${g.daily.length}</span></td>
      <td><span class='k'>Bonus</span><span class='v'>${bonusDone} / ${g.bonus.length}</span></td>
      <td><span class='k'>Weekly</span><span class='v'>${weeklyDone} / ${g.weekly.length}</span></td>
      <td><span class='k'>Special</span><span class='v'>${specialDone} / ${g.special.length}</span></td>
    </tr></table>
    ${section("Daily contracts", g.daily)}
    ${section("Bonus contracts", g.bonus)}
    ${section("Weekly contracts", g.weekly)}
    ${section("Special contracts", g.special)}
    ${section("Season trackers", g.seasonal)}
    <div class='panel msg'>Progress is server-authoritative. Claim rewards in game with <b>/missions</b>; this page never grants coins or XP.</div>`

  return motdFrame({
    theme, meta,
    title: "Missions",
    kicker: "Contracts · Season 1",
    sub: `${dailyDone}/${g.daily.length} daily · ${weeklyDone}/${g.weekly.length} weekly · ${specialDone}/${g.special.length} special`,
    backHref: "/profile?steamid=" + encodeURIComponent(steamid),
    backLabel: "Profile",
    content
  })
}
