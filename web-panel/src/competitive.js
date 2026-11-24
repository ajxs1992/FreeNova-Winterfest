// Competitive season panel — ladder, personal standing, daily set, prize ladder.
import { loadTheme } from "./top15/store.js"
import { serverMeta } from "./top15/meta.js"
import { motdFrame, esc, fmt, rankName, rankFile, isOn, ago } from "./top15/render.js"
import { flagImg } from "./ui.js"
import { pageActionToken } from "./pages.js"
import { queueAction, localTrustEnabled, NO_MINT_MSG } from "./sync.js"

function steamidOf(url) {
  const minted = url && url._fnMotdSid
  if (minted && /^STEAM_[0-9]:[0-9]:\d+$/.test(String(minted))) return String(minted)
  const q = (url.searchParams.get("steamid") || "").trim()
  if (/^STEAM_[0-9]:[0-9]:\d+$/.test(q)) return q
  const m = String(url.pathname || "").match(/\/m\/c\/(\d+-\d+-\d+)/i)
  if (m) return "STEAM_" + m[1].replace(/-/g, ":")
  return ""
}

const MONTHS = ["JANUARY", "FEBRUARY", "MARCH", "APRIL", "MAY", "JUNE", "JULY", "AUGUST", "SEPTEMBER", "OCTOBER", "NOVEMBER", "DECEMBER"]

function prettySeason(key) {
  const m = String(key || "").match(/(\d{4})-(\d{2})/)
  if (!m) return "OFF-SEASON"
  return `${MONTHS[Math.max(0, Math.min(11, Number(m[2]) - 1))]} ${m[1]}`
}

export async function pageCompetitive(env, url) {
  const theme = await loadTheme(env)
  const now = Math.floor(Date.now() / 1000)
  const meta = await serverMeta(env, now)
  const steamid = steamidOf(url)
  const token = await pageActionToken(env, url, steamid)
  const claimArg = url.searchParams.get("claim") || ""

  // A ?claim= click without a token used to fall through silently: the page
  // rendered as if nothing had been asked. Say why instead - no token means
  // this deployment does not mint action tokens (REVIEW.md §3.8), or the link
  // was opened without a steamid.
  // Why a click cannot act, in the caller's words: either this deployment does
  // not mint tokens at all, or the link carried no steamid to act for.
  const noTokenWhy = localTrustEnabled(env)
    ? "Open this page from the game server to claim a prize."
    : NO_MINT_MSG
  let claimMsg = ""
  if (claimArg && !token) {
    claimMsg = `<div class='panel msg'>${esc(noTokenWhy)}</div>`
  } else if (claimArg && steamid && token) {
    try {
      const res = await queueAction(env, steamid, "claim_tournament", claimArg, token)
      claimMsg = res.ok
        ? `<div class='panel msg'>Prize claim queued. It will be processed in game.</div>`
        : `<div class='panel msg'>${esc(res.error || "Could not queue prize claim.")}</div>`
    } catch {
      claimMsg = `<div class='panel msg'>Could not queue prize claim.</div>`
    }
  }

  let rows = []
  let ranked = 0
  try {
    const result = await env.DB.prepare(
      `SELECT steamid, name, comp_points, comp_kills, comp_hs, comp_wins, comp_mvp,
              rank_id, level, last_seen, cc
       FROM players WHERE comp_points > 0
       ORDER BY comp_points DESC, comp_kills DESC LIMIT 10`
    ).all()
    rows = result.results || []
    const count = await env.DB.prepare(`SELECT COUNT(*) AS n FROM players WHERE comp_points > 0`).first()
    ranked = Number(count && count.n) || 0
  } catch {
    return motdFrame({
      theme, meta, title: "Competitive", kicker: "Ranked season",
      sub: "Standings unavailable", backHref: "/", backLabel: "Panels",
      content: `<div class='panel msg'><b>Standings unavailable</b><br>Try again after the next sync.</div>`
    })
  }

  let p = null
  let claimRecord = null
  if (steamid) {
    try {
      p = await env.DB.prepare(`SELECT * FROM players WHERE steamid = ?1`).bind(steamid).first()
    } catch {}
    try {
      claimRecord = await env.DB.prepare(
        `SELECT id, status, result, created_at FROM actions
         WHERE steamid = ?1 AND type = 'claim_tournament' ORDER BY created_at DESC LIMIT 1`
      ).bind(steamid).first()
    } catch {}
  }

  let myPos = 0
  if (p && Number(p.comp_points) > 0) {
    try {
      const r = await env.DB.prepare(`SELECT COUNT(*) + 1 AS pos FROM players WHERE comp_points > ?1`).bind(p.comp_points).first()
      myPos = Number(r && r.pos) || 0
    } catch {}
  }
  let nextGap = 0
  if (p && myPos > 1) {
    try {
      const above = await env.DB.prepare(
        `SELECT comp_points FROM players WHERE comp_points > ?1 ORDER BY comp_points ASC LIMIT 1`
      ).bind(p.comp_points).first()
      if (above) nextGap = Math.max(0, Number(above.comp_points) - Number(p.comp_points) + 1)
    } catch {}
  }

  let prizeTier = ""
  let prizeCoins = 0
  if (p && (Number(p.comp_points) > 0 || Number(p.comp_wins) > 0)) {
    const msnDone = [
      Number(p.comp_msn_k) >= 25,
      Number(p.comp_msn_h) >= 20,
      Number(p.comp_msn_w) >= 10,
      Number(p.comp_msn_m) >= 3
    ].filter(Boolean).length
    const maskDone = [1, 2, 4, 8].filter(b => (Number(p.comp_msn_done) & b)).length
    const stage = Math.max(msnDone, maskDone)
    if (myPos === 1) {
      prizeTier = "CHAMPION (#1)"
      prizeCoins = 10000
    } else if (myPos === 2) {
      prizeTier = "RUNNER-UP (#2)"
      prizeCoins = 5000
    } else if (myPos === 3) {
      prizeTier = "PODIUM BRONZE (#3)"
      prizeCoins = 2500
    } else if (myPos > 0 && myPos <= 15) {
      prizeTier = `TOP 15 QUALIFIER (#${myPos})`
      prizeCoins = 1000
    } else if (stage >= 4) {
      prizeTier = "DAILY STAGE GRAND SLAM"
      prizeCoins = 500
    } else if (Number(p.comp_wins) >= 5 || Number(p.comp_points) >= 100) {
      prizeTier = "COMPETITIVE VICTOR"
      prizeCoins = 250
    }
  }

  let claimButton = ""
  if (steamid) {
    const pending = claimRecord && (claimRecord.status === "pending" || claimRecord.status === "sent")
    const done = claimRecord && claimRecord.status === "done"
    if (pending) {
      claimButton = `<span class='badge'>QUEUED</span>`
    } else if (done) {
      claimButton = `<span class='badge done'>CLAIMED</span>`
    } else if (prizeTier) {
      const href = `/competitive?steamid=${encodeURIComponent(steamid)}&t=${encodeURIComponent(token)}&claim=${encodeURIComponent(prizeTier)}`
      claimButton = token
        ? `<a class='badge done' href='${href}'>CLAIM ${fmt(prizeCoins)}c</a>`
        : `<span class='badge done'>CLAIM ${fmt(prizeCoins)}c</span>`
    } else {
      claimButton = `<span class='badge lock'>NO PRIZE</span>`
    }
  }

  let modeSeason = ""
  try {
    const srows = ((await env.DB.prepare(`SELECT comp_season AS s FROM players WHERE comp_points > 0 LIMIT 200`).all()).results) || []
    const freq = {}
    for (const s of srows) if (s && s.s) freq[s.s] = (freq[s.s] || 0) + 1
    modeSeason = Object.keys(freq).sort((a, b) => freq[b] - freq[a])[0] || ""
  } catch {}

  const cur = new Date()
  const curMonth = `${cur.getFullYear()}-${String(cur.getMonth() + 1).padStart(2, "0")}`
  const hasSeason = !!modeSeason
  const seasonEnded = hasSeason && modeSeason < curMonth
  const dim = new Date(cur.getFullYear(), cur.getMonth() + 1, 0).getDate()
  const daysLeft = Math.max(0, dim - cur.getDate())
  const seasonPct = Math.max(0, Math.min(100, Math.round(cur.getDate() * 100 / dim)))
  const state = !hasSeason ? "OFF-SEASON" : seasonEnded ? "FINAL" : "LIVE"

  const kpis = p && Number(p.comp_points) > 0
    ? `<table class='kpis' cellspacing='4' cellpadding='0'><tr>
        <td><span class='k'>Points</span><span class='v p'>${fmt(p.comp_points)}</span></td>
        <td><span class='k'>Position</span><span class='v'>${myPos > 0 ? "#" + fmt(myPos) : "—"}</span></td>
        <td><span class='k'>Wins</span><span class='v'>${fmt(p.comp_wins)}</span></td>
        <td><span class='k'>MVP</span><span class='v'>${fmt(p.comp_mvp)}</span></td>
      </tr></table>`
    : `<table class='kpis' cellspacing='4' cellpadding='0'><tr>
        <td><span class='k'>Ranked</span><span class='v p'>${fmt(ranked)}</span></td>
        <td><span class='k'>Season</span><span class='v'>${hasSeason ? esc(prettySeason(modeSeason)) : "—"}</span></td>
        <td><span class='k'>Days left</span><span class='v'>${hasSeason && !seasonEnded ? fmt(daysLeft) : "—"}</span></td>
        <td><span class='k'>State</span><span class='v'>${state}</span></td>
      </tr></table>`

  const myStrip = p
    ? `<table class='strip' cellspacing='0' cellpadding='0'><tr>
        <td class='first'><span class='k'>Your season</span><span class='v'>${myPos > 0 ? "#" + fmt(myPos) : "UNRANKED"}</span><span class='comp-gap'>${myPos > 1 && nextGap > 0 ? `${fmt(nextGap)} pts to #${fmt(myPos - 1)}` : (myPos === 1 ? "Season leader" : "")}</span></td>
        <td><span class='k'>Points</span><span class='v'>${fmt(p.comp_points)}</span></td>
        <td><span class='k'>Prize</span><span class='v'>${esc(prizeTier || "—")}</span></td>
        <td class='r'><span class='k'>Claim</span>${claimButton}</td>
      </tr></table>`
    : `<div class='panel msg'><b>Open from the game</b><br>Run <b>/pts</b> in chat to see your standing.</div>`

  const seasonBar = hasSeason && !seasonEnded
    ? `<table class='proghead' cellspacing='0' cellpadding='0'><tr>
        <td>Season progress</td><td class='r'>${fmt(daysLeft)} days left</td>
      </tr></table><div class='progbar'><i style='width:${seasonPct}%'></i></div>`
    : ""

  const ladderRows = rows.length
    ? rows.map((r, i) => {
        const pos = i + 1
        const me = steamid && r.steamid === steamid
        const on = isOn(r, now)
        const urlProfile = "/profile?steamid=" + encodeURIComponent(r.steamid || "")
        const seen = on ? "online" : (Number(r.last_seen) ? ago(now - Number(r.last_seen)) + " ago" : "—")
        const posCls = pos === 1 ? " gold" : pos === 2 ? " silver" : pos === 3 ? " bronze" : ""
        const posCell = pos <= 3
          ? `<img src='/medals/medal_0${pos}.png' width='18' height='22' alt='#${pos}' title='#${pos}'>`
          : pos
        return `<tr class='${me ? "you" : "row"}' style='cursor:pointer;' onclick="location.href='${urlProfile}'">
          <td class='c'><span class='pos${posCls}'>${posCell}</span></td>
          <td class='l'>
            <span class='pname-cell'>${flagImg(r.cc, 13, 10)}<a href='${urlProfile}'>${esc(r.name || r.steamid || "Unknown")}</a>${me ? "<span class='youtag'>YOU</span>" : ""}</span>
            <span class='psub' title='${esc(seen)}'>L${Number(r.level) || 1} · ${esc(rankName(r.rank_id))} · ${esc(seen)}</span>
          </td>
          <td><span class='xpnum'>${fmt(r.comp_points)}</span></td>
          <td>${fmt(r.comp_wins)}</td>
          <td>${fmt(r.comp_kills)}</td>
          <td>${fmt(r.comp_mvp)}</td>
          <td class='c'><img class='rankimg' src='${rankFile(r)}' width='22' height='22' alt='${esc(rankName(r.rank_id))}' title='${esc(rankName(r.rank_id))}'></td>
        </tr>`
      }).join("")
    : `<tr><td colspan='7'><div class='msg'><b>No ranked players yet</b><br>Season points appear after competitive matches.</div></td></tr>`

  const ladder = `<div class='boardwrap'>
    <table class='board' cellspacing='0' cellpadding='0'>
      <colgroup>
        <col style='width:6%'><col style='width:40%'><col style='width:13%'>
        <col style='width:8%'><col style='width:9%'><col style='width:8%'><col style='width:16%'>
      </colgroup>
      <tr><th class='c'>#</th><th class='l'>Player</th><th>Points</th><th>W</th><th>K</th><th>MVP</th><th class='c'>Rank</th></tr>
      ${ladderRows}
    </table>
  </div>`

  const missions = [
    { title: "FRAG HUNTER", desc: "25 competitive kills", val: Number(p && p.comp_msn_k) || 0, target: 25, bit: 1 },
    { title: "SHARPSHOOTER", desc: "20 competitive headshots", val: Number(p && p.comp_msn_h) || 0, target: 20, bit: 2 },
    { title: "WINNER", desc: "10 competitive round wins", val: Number(p && p.comp_msn_w) || 0, target: 10, bit: 4 },
    { title: "MVP", desc: "3 competitive MVP awards", val: Number(p && p.comp_msn_m) || 0, target: 3, bit: 8 }
  ]
  const doneCount = missions.filter(m => ((Number(p && p.comp_msn_done) & m.bit) || m.val >= m.target)).length
  const missionRows = missions.map(m => {
    const done = (Number(p && p.comp_msn_done) & m.bit) || m.val >= m.target
    const pct = Math.max(0, Math.min(100, Math.round(m.val * 100 / m.target)))
    return `<tr class='msn-row${done ? " done" : ""}'>
      <td><div class='msn-title'>${m.title}</div><span class='msn-desc'>${m.desc}</span></td>
      <td class='msn-prog'><div class='mbar'><i style='width:${pct}%'></i></div><span>${fmt(Math.min(m.val, m.target))} / ${fmt(m.target)}</span></td>
      <td class='msn-state'>${done ? "DONE" : "OPEN"}</td>
    </tr>`
  }).join("")

  const prizes = `<table class='comp-prizes' cellspacing='0' cellpadding='0'>
    <tr><td class='k'>CHAMPION</td><td class='v'>10,000c</td><td class='gap'></td><td class='k'>RUNNER-UP</td><td class='v'>5,000c</td></tr>
    <tr><td class='k'>THIRD</td><td class='v'>2,500c</td><td class='gap'></td><td class='k'>TOP 15</td><td class='v'>1,000c</td></tr>
    <tr><td class='k'>GRAND SLAM</td><td class='v'>500c</td><td class='gap'></td><td class='k'>VICTOR</td><td class='v'>250c</td></tr>
  </table>`

  const content = `${claimMsg}${kpis}${myStrip}${seasonBar}
    <div class='sect' style='margin-top:8px;'>Season ladder · top 10</div>
    ${ladder}
    <div class='sect' style='margin-top:8px;'>Daily set · ${doneCount}/4</div>
    <table class='msn-list' cellspacing='0' cellpadding='0'>${missionRows}</table>
    <div class='sect' style='margin-top:8px;'>Prizes</div>
    ${prizes}`

  return motdFrame({
    theme, meta,
    title: "Competitive",
    kicker: hasSeason ? `Season ${prettySeason(modeSeason)} · ${state}` : "Ranked · Off-season",
    sub: hasSeason
      ? `${fmt(ranked)} ranked · ${seasonEnded ? "final standings" : fmt(daysLeft) + " days left"}`
      : `${fmt(ranked)} ranked · next season pending`,
    backHref: "/profile?steamid=" + encodeURIComponent(steamid || ""),
    backLabel: "Profile",
    content
  })
}
