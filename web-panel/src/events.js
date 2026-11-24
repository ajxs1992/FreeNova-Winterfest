// Events panel — live/upcoming list, detail, boards and winner history.
import { loadTheme } from "./top15/store.js"
import { serverMeta } from "./top15/meta.js"
import { motdFrame, esc, fmt } from "./top15/render.js"
import { pct, isMotdCompact } from "./ui.js"
import {
  pageActionToken, eventKey, eventMetricKey, playerEventScore, parseEventEnds,
  eventCountdown, loadEventsList, loadEventBoardRows, eventBoardSort,
  eventWinnersMap, eventHistoryRows, fmtEventWhen
} from "./pages.js"
import { queueAction, localTrustEnabled, NO_MINT_MSG } from "./sync.js"

function steamidOf(url) {
  const minted = url && url._fnMotdSid
  if (minted && /^STEAM_[0-9]:[0-9]:\d+$/.test(String(minted))) return String(minted)
  const q = (url.searchParams.get("steamid") || "").trim()
  if (/^STEAM_[0-9]:[0-9]:\d+$/.test(q)) return q
  const m = String(url.pathname || "").match(/\/m\/e\/(\d+-\d+-\d+)/i)
  if (m) return "STEAM_" + m[1].replace(/-/g, ":")
  return ""
}

function eventArt(e, size) {
  const s = `${e && e.name ? e.name : ""} ${e && e.type ? e.type : ""}`.toLowerCase()
  let key = "badge"
  if (/xp|happy|boost|double|multiplier/.test(s)) key = "xp"
  else if (/coin|gold|reward/.test(s)) key = "coins"
  else if (/race|headshot|aim|target|kill|frag/.test(s)) key = "target"
  else if (/tournament|champ|mvp|trophy/.test(s)) key = "trophy"
  const px = Math.max(16, Math.min(96, Number(size) || 40))
  return `<img src='/evt/evt_${key}.png' width='${px}' height='${px}' alt='' onerror='this.style.display="none"'>`
}

export async function pageEvents(env, url) {
  const theme = await loadTheme(env)
  const now = Math.floor(Date.now() / 1000)
  const nowMs = Date.now()
  const meta = await serverMeta(env, now)
  const steamid = steamidOf(url)
  const compact = isMotdCompact()

  let p = null
  if (steamid) {
    try { p = await env.DB.prepare(`SELECT * FROM players WHERE steamid = ?1`).bind(steamid).first() } catch {}
  }

  let happy = false
  try {
    const m = await env.DB.prepare(`SELECT value FROM meta WHERE key = 'happy_hour'`).first()
    happy = !!(m && m.value === "1")
  } catch {}

  let list = []
  try { list = await loadEventsList(env) } catch {}

  const base = steamid
    ? `/events?steamid=${encodeURIComponent(steamid)}${compact ? "&compact=1" : ""}`
    : `/events${compact ? "?compact=1" : ""}`
  const withQ = (extra) => base + (base.includes("?") ? "&" : "?") + extra
  const token = steamid ? await pageActionToken(env, url, steamid) : ""

  const stateOf = (e) => {
    if (e.active) return "active"
    const t = parseEventEnds(e.ends)
    return t != null && t > nowMs ? "upcoming" : "past"
  }
  const progressOf = (e) => {
    const metric = eventMetricKey(e)
    const target = Number(e.target) || 0
    const measurable = target > 0 && metric !== "none"
    const mine = p && measurable ? playerEventScore(p, metric) : 0
    return { metric, target, measurable, mine }
  }

  let actMsg = ""
  const act = String(url.searchParams.get("act") || "")
  const am = act.match(/^claim_event:(\d{1,9})$/)
  // Same silent no-op as /competitive?claim= had: explain, do not pretend.
  const noTokenWhy = localTrustEnabled(env)
    ? "Open this page from the game server to claim."
    : NO_MINT_MSG
  if (am && !token) {
    actMsg = `<div class='panel msg'>${esc(noTokenWhy)}</div>`
  } else if (am && steamid && token) {
    try {
      const res = await queueAction(env, steamid, "claim_event", am[1], token)
      actMsg = res.ok
        ? `<div class='panel msg'>Reward claim queued. The game server pays it.</div>`
        : `<div class='panel msg'>${esc(res.error || "Could not queue the claim.")}</div>`
    } catch {
      actMsg = `<div class='panel msg'>Could not queue the claim.</div>`
    }
  }

  const openId = String(url.searchParams.get("id") || "").toLowerCase()
  const open = openId
    ? list.find(e => eventKey(e).toLowerCase() === openId || String(e.id || "").toLowerCase() === openId)
    : null

  if (open) {
    const { metric, target, measurable, mine } = progressOf(open)
    const isBoost = target <= 0
    const isGoal = String(open.type || "").toLowerCase() === "community_goal"
    const state = stateOf(open)
    const countdown = state === "active" ? eventCountdown(open.ends, nowMs) : ""
    const minePct = measurable ? pct(mine, target) : 0

    let board = []
    if (isGoal || measurable) {
      const boardMetric = metric === "none" ? "kills" : metric
      const rows = await loadEventBoardRows(env, boardMetric)
      board = eventBoardSort(rows, boardMetric).slice(0, 10)
    }
    let myRank = 0
    if (p && board.length) {
      const idx = board.findIndex(r => String(r.steamid) === String(p.steamid))
      myRank = idx >= 0 ? idx + 1 : 0
    }

    let claim = ""
    const eid = Number(open.id) || 0
    if (eid > 0 && p) {
      let winner = null
      try {
        winner = await env.DB.prepare(
          `SELECT placement, score FROM event_winners WHERE event_id = ?1 AND steamid = ?2`
        ).bind(eid, steamid).first()
      } catch {}
      if (winner) {
        let paid = null
        try {
          paid = await env.DB.prepare(
            `SELECT result FROM actions WHERE steamid = ?1 AND type IN ('srv_event_reward','claim_event')
             AND (arg = ?2 OR arg LIKE ?3) AND status = 'done'`
          ).bind(steamid, String(eid), String(eid) + ":%").first()
        } catch {}
        const pending = paid && /pending/i.test(String(paid.result || ""))
        if (paid && !pending) {
          claim = `<div class='panel msg'><span class='badge done'>CLAIMED</span> Placement #${fmt(winner.placement)} · ${fmt(winner.score)}</div>`
        } else if (token) {
          claim = `<div class='panel msg'><b>PLACEMENT #${fmt(winner.placement)}</b> · ${fmt(winner.score)}<br>
            <a class='badge done' href='${withQ("id=" + encodeURIComponent(eventKey(open)) + "&act=claim_event:" + eid + "&t=" + encodeURIComponent(token))}'>CLAIM REWARD</a></div>`
        } else {
          claim = `<div class='panel msg'>Placement #${fmt(winner.placement)} · open <b>/events</b> in game to claim.</div>`
        }
      }
    }

    const metricLabel = metric === "none" ? "boost" : metric.toUpperCase()
    const rows = board.map((r, i) => `<tr class='${p && r.steamid === steamid ? "you" : "row"}'>
      <td class='c'><span class='pos${i === 0 ? " gold" : i === 1 ? " silver" : i === 2 ? " bronze" : ""}'>${i + 1}</span></td>
      <td class='l'><a href='/profile?steamid=${encodeURIComponent(r.steamid || "")}'>${esc(r.name || r.steamid || "Unknown")}</a></td>
      <td><span class='xpnum'>${fmt(playerEventScore(r, metric === "none" ? "kills" : metric))}</span></td>
    </tr>`).join("")

    const boardHtml = (isGoal || measurable)
      ? `<div class='sect' style='margin-top:8px;'>Top players · ${esc(metricLabel)}</div>
        <div class='boardwrap'><table class='board' cellspacing='0' cellpadding='0'>
          <colgroup><col style='width:8%'><col style='width:72%'><col style='width:20%'></colgroup>
          <tr><th class='c'>#</th><th class='l'>Player</th><th>${esc(metricLabel)}</th></tr>
          ${rows || `<tr><td colspan='3'><div class='msg'><b>No scores yet</b></div></td></tr>`}
        </table></div>`
      : ""

    const progress = isBoost
      ? `<div class='panel msg'>Boost only · no personal target</div>`
      : measurable
        ? `<table class='proghead' cellspacing='0' cellpadding='0'><tr>
            <td>${p ? `${fmt(mine)} / ${fmt(target)} (${minePct}%)` : `Target ${fmt(target)}`}</td>
            <td class='r'>${myRank > 0 ? "Rank #" + fmt(myRank) : ""}</td>
          </tr></table><div class='evt-bar'><i style='width:${p ? minePct : 0}%'></i></div>`
        : `<div class='panel msg'>Target ${fmt(target)} · no progress metric set</div>`

    const rewards = String(open.bonus || "In-game settlement")
      .split(/[+•|/]/).map(s => s.trim()).filter(Boolean)
      .map(r => `<div class='msn-rew'>${esc(r)}</div>`).join("")

    const content = `${actMsg}
      <div class='evt-back'><a href='${base}'>‹ All events</a></div>
      <table class='evt-hero' cellspacing='0' cellpadding='0'><tr>
        <td class='ic'>${eventArt(open, 44)}</td>
        <td><div class='name'>${esc(open.name || "Event")}</div><div class='desc'>${esc(open.desc || "")}</div></td>
        <td class='right'><span class='badge${state === "active" ? " done" : ""}'>${state.toUpperCase()}</span><div class='cd'>${esc(countdown || open.ends || "")}</div></td>
      </tr></table>
      <table class='kpis' cellspacing='4' cellpadding='0'><tr>
        <td><span class='k'>Metric</span><span class='v'>${esc(metricLabel)}</span></td>
        <td><span class='k'>Target</span><span class='v'>${isBoost ? "Boost" : fmt(target)}</span></td>
        <td><span class='k'>Scope</span><span class='v'>${esc(open.scope || "global")}</span></td>
        <td><span class='k'>Ends</span><span class='v'>${esc(open.ends || "—")}</span></td>
      </tr></table>
      ${progress}
      ${boardHtml}
      <div class='sect' style='margin-top:8px;'>Rewards</div>
      ${rewards || "<div class='panel msg'>No reward listed.</div>"}
      ${claim}
      <div class='sect' style='margin-top:8px;'><a href='${base}'>‹ All events</a></div>`

    return motdFrame({
      theme, meta,
      title: "Events",
      kicker: `Limited-time · ${state}`,
      sub: open.name || "Event detail",
      backHref: "/profile?steamid=" + encodeURIComponent(steamid || ""),
      backLabel: "Profile",
      content
    })
  }

  const show = ["active", "upcoming", "past", "mine"].includes(String(url.searchParams.get("show") || "").toLowerCase())
    ? String(url.searchParams.get("show")).toLowerCase() : ""
  const ordered = list.slice().sort((a, b) => {
    const ta = a.active ? (parseEventEnds(a.ends) ?? Infinity) : Infinity
    const tb = b.active ? (parseEventEnds(b.ends) ?? Infinity) : Infinity
    return ta - tb
  })
  const activeCount = list.filter(e => stateOf(e) === "active").length
  const upcomingCount = list.filter(e => stateOf(e) === "upcoming").length
  const historyAll = await eventHistoryRows(env, 30)
  const history = historyAll.slice(0, 5)
  const winMap = await eventWinnersMap(env, historyAll.map(h => h.event_id))

  let filtered = ordered
  if (show === "active") filtered = ordered.filter(e => stateOf(e) === "active")
  else if (show === "upcoming") filtered = ordered.filter(e => stateOf(e) === "upcoming")
  else if (show === "mine") filtered = ordered.filter(e => progressOf(e).mine > 0)

  const tabs = [["", "All"], ["active", "Active"], ["upcoming", "Upcoming"], ["past", "Past"], ["mine", "Mine"]]
    .map(([k, label]) => k === show
      ? `<span class='pill on'>${label}</span>`
      : `<a class='pill' href='${k ? withQ("show=" + k) : base}'>${label}</a>`).join("")

  let rows = ""
  if (show === "past") {
    rows = historyAll.length
      ? historyAll.map(h => {
          const w = (winMap.get(Number(h.event_id)) || [])[0]
          return `<tr><td>${esc(String(h.title || "").trim() || `Event ${fmt(h.event_id)}`)}</td>
            <td>${w ? `<b>${esc(w.nm)}</b>` : "<span class='muted'>—</span>"}</td>
            <td class='date'>${esc(fmtEventWhen(Number(h.completed_at)) || "—")}</td></tr>`
        }).join("")
      : `<tr><td colspan='3'><div class='msg'><b>No closed events</b></div></td></tr>`
  } else {
    rows = filtered.length
      ? filtered.map(e => {
          const state = stateOf(e)
          const { metric, target, measurable, mine } = progressOf(e)
          const isBoost = target <= 0
          const minePct = measurable ? pct(mine, target) : 0
          const countdown = state === "active" ? eventCountdown(e.ends, nowMs) : ""
          const href = withQ("id=" + encodeURIComponent(eventKey(e)))
          const prog = measurable
            ? `<div class='mbar'><i style='width:${p ? minePct : 0}%'></i></div><span>${p ? `${fmt(mine)} / ${fmt(target)}` : `Target ${fmt(target)}`}</span>`
            : isBoost ? "<span>Boost only</span>" : "<span>—</span>"
          return `<tr class='evt-row' style='cursor:pointer;' onclick="location.href='${href}'">
            <td class='ic'>${eventArt(e, 28)}</td>
            <td><div class='name'><a href='${href}'>${esc(e.name || "Event")}</a></div><div class='desc'>${esc(e.desc || "")}</div><div class='reward'>${esc(e.bonus || "")}</div></td>
            <td class='prog'>${prog}</td>
            <td class='state${state === "active" ? " on" : ""}'>${state === "active" ? "LIVE" : state.toUpperCase()}${countdown ? `<span class='cd'>${esc(countdown)}</span>` : ""}</td>
          </tr>`
        }).join("")
      : `<tr><td colspan='4'><div class='msg'><b>No events</b></div></td></tr>`
  }

  const kpis = `<table class='kpis' cellspacing='4' cellpadding='0'><tr>
      <td><span class='k'>Live</span><span class='v p'>${fmt(activeCount)}</span></td>
      <td><span class='k'>Upcoming</span><span class='v'>${fmt(upcomingCount)}</span></td>
      <td><span class='k'>Happy hour</span><span class='v'>${happy ? "2x XP" : "—"}</span></td>
      <td><span class='k'>Closed</span><span class='v'>${fmt(historyAll.length)}</span></td>
    </tr></table>`

  const historyHtml = show === "past"
    ? `<div class='sect' style='margin-top:8px;'>Archive</div>
       <table class='evt-history' cellspacing='0' cellpadding='0'>
         <tr><td>Event</td><td>Winner</td><td class='date'>Closed</td></tr>
         ${rows}
       </table>`
    : `<div class='sect' style='margin-top:8px;'>Winners history</div>
       <table class='evt-history' cellspacing='0' cellpadding='0'>
         <tr><td>Event</td><td>Winner</td><td class='date'>Closed</td></tr>
         ${history.length
           ? history.map(h => {
               const w = (winMap.get(Number(h.event_id)) || [])[0]
               return `<tr><td>${esc(String(h.title || "").trim() || `Event ${fmt(h.event_id)}`)}</td>
                 <td>${w ? `<b>${esc(w.nm)}</b>` : "<span class='muted'>—</span>"}</td>
                 <td class='date'>${esc(fmtEventWhen(Number(h.completed_at)) || "—")}</td></tr>`
             }).join("")
           : `<tr><td colspan='3'><div class='msg'><b>No closed events</b></div></td></tr>`}
       </table>`

  // actMsg belongs on the list view too: without it, a ?act=click on a
  // deployment that cannot queue read as if nothing had been clicked.
  const content = `${actMsg}${kpis}
    <div class='pills' style='border-top:0;padding-top:0;margin:4px 0 5px;'>${tabs}</div>
    ${show === "past"
      ? historyHtml
      : `<table class='evt-list' cellspacing='0' cellpadding='0'>
           <tr><th class='ic'></th><th>Event</th><th class='prog'>Progress</th><th class='state'>State</th></tr>
           ${rows}
         </table>
         ${historyHtml}`}`

  return motdFrame({
    theme, meta,
    title: "Events",
    kicker: `Live operations · ${activeCount} active`,
    sub: `${upcomingCount} upcoming · ${historyAll.length} closed`,
    backHref: steamid ? "/profile?steamid=" + encodeURIComponent(steamid) : "/",
    backLabel: steamid ? "Profile" : "Panels",
    content
  })
}
