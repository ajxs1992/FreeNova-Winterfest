// MOTD v2 — the player-facing surface a GoldSrc client actually opens:
//   /m/p/<sid>            profile + player header
//   /m/i/<sid>/<tab>.htm  missions (daily | weekly | completed | special | seasonal)
//   /m/e/<sid>.htm        events: running now + next, countdown computed here
//   /m/b/<sid>.htm        battle pass: tier, XP to next, next three rewards
//   /m/t/<sid>/<tab>.htm  top 3 + your own position (all | week | month)
//
// GoldSrc MOTD constraints (HUB.md): the in-game browser is MSIE 6 /
// Mozilla/4. So every page here is one HTML document with
//   * CSS in a <style> block only — no external stylesheet, no webfonts;
//   * NO flex, NO grid, NO CSS variables (IE6 ignores them and the page
//     paints white);
//   * NO <script>, NO images, NO iframes — nothing that is a second request,
//     because a MOTD that waits on a subresource is a blank MOTD;
//   * ~800 px wide, tables for layout, dark FreeNova palette
//     #0e1116 / #36DEAB / #e8c547.
//
// Every page answers "what is in it for me" in the first two lines, and every
// page renders for a player the panel has never seen (rank null, tier 1, 0 XP,
// no missions, no badges) — that is the most common first impression.
//
// DEGRADING: if the DB stalls or throws, the page is a static
// "server info + type !missions" block (HTTP 200) instead of a hang or a
// stack trace. See renderFallback().
import { serverMeta } from "./top15/meta.js"
import { xpPerTier, BP_MAX_TIER } from "./bp_track.js"
import { missionGroups, missionDone } from "./pages.js"
import { publicPlayerSummary } from "./publicapi.js"
import {
  lifetimeBoard, periodBoard, recentChampions,
  playerLifetimeStanding, playerPeriodStanding
} from "./boards.js"
import { loadSchedule, splitSchedule, countdownText, utcText } from "./schedule.js"

const ACCENT = "#36DEAB"
const GOLD = "#e8c547"
const BG = "#0e1116"
const CARD = "#151b23"
const LINE = "#22303c"
const TEXT = "#e8edf2"
const DIM = "#8fa0b0"

const PAGE_BUDGET_MS = 2000

const nowSec = () => Math.floor(Date.now() / 1000)

export function esc(s) {
  return String(s == null ? "" : s)
    .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;").replace(/'/g, "&#39;")
}

/** 12345 -> "12,345". No locale, so the MOTD never surprises. */
export function n(v) {
  const x = Math.trunc(Number(v) || 0)
  return String(x < 0 ? -x : x).replace(/\B(?=(\d{3})+(?!\d))/g, ",").replace(/^/, x < 0 ? "-" : "")
}

const clampPct = v => Math.max(0, Math.min(100, Math.round(Number(v) || 0)))

/** Progress bar: div width percentages only (IE6-safe, no flex/grid/var). */
function bar(pct, color) {
  const p = clampPct(pct)
  return `<table class='bar' width='100%' cellspacing='0' cellpadding='0' border='0'><tr>
    <td bgcolor='#0a2b26' height='9'>
      <table width='${p}%' cellspacing='0' cellpadding='0' border='0'><tr><td bgcolor='${color}' height='9'></td></tr></table>
    </td>
  </tr></table>`
}

/** "STEAM_0:0:683671116" -> "0-0-683671116" (the packed form the MOTD uses). */
export function packed(sid) {
  const m = /^STEAM_(\d+):(\d):(\d+)$/.exec(String(sid || ""))
  return m ? `${m[1]}-${m[2]}-${m[3]}` : ""
}

function playtime(min) {
  const m = Math.trunc(Number(min) || 0)
  if (m < 60) return m + "m"
  const h = Math.floor(m / 60)
  const r = m % 60
  return h + "h" + (r ? " " + r + "m" : "")
}

const CSS = `
html,body{margin:0;padding:0;background:${BG};color:${TEXT};}
body{font-family:Tahoma,Verdana,Arial,sans-serif;font-size:12px;line-height:1.45;}
a{color:${ACCENT};text-decoration:none;}
a:hover{color:#7ff0cd;}
.wrap{width:760px;margin:0 auto;padding:8px 6px 14px;}
.hdr{background:#0b1017;border:1px solid ${LINE};padding:8px 10px;}
.brand{font-size:15px;letter-spacing:3px;color:${ACCENT};font-weight:bold;}
.brand i{font-style:normal;color:${GOLD};}
.dim{color:${DIM};}
.sml{font-size:10px;}
.big{font-size:20px;font-weight:bold;}
.who{font-size:15px;font-weight:bold;color:#fff;margin-top:3px;}
.who .tag{color:${GOLD};}
.you{color:${ACCENT};font-size:10px;letter-spacing:1px;}
.live{font-size:11px;color:${ACCENT};}
.off{font-size:11px;color:#f07178;}
.bar{margin:3px 0 2px;}
.card{background:${CARD};border:1px solid ${LINE};padding:7px 9px;margin-top:7px;}
.lead{background:#10221e;border:1px solid #1d4d41;border-left:4px solid ${ACCENT};padding:7px 9px;margin-top:7px;font-size:13px;}
.lead b{color:${ACCENT};}
.lead .gold{color:${GOLD};}
.h2{color:${ACCENT};font-size:10px;letter-spacing:2px;font-weight:bold;margin:9px 0 3px;}
.h2 span{color:${DIM};letter-spacing:0;font-weight:normal;}
.t{width:100%;border-collapse:collapse;}
.t td{padding:4px 5px;border-bottom:1px solid #1b2530;vertical-align:middle;}
.t th{text-align:left;padding:3px 5px;color:${DIM};font-size:9px;letter-spacing:1px;border-bottom:1px solid ${LINE};}
.t .num{text-align:right;color:${GOLD};font-weight:bold;}
.t .pos{color:${DIM};width:26px;text-align:center;}
.t .pos.g1{color:${GOLD};}.t .pos.g2{color:#cfd8e3;}.t .pos.g3{color:#c98b5e;}
.t tr.me td{background:#10251f;}
.t .m{color:${TEXT};font-weight:bold;}
.t .s{color:${DIM};font-size:10px;}
.done{color:${ACCENT};}
.pill{display:inline-block;padding:2px 8px;border:1px solid ${LINE};color:${DIM};margin-right:4px;font-size:10px;}
.pill.on{background:${ACCENT};color:#06231c;border-color:${ACCENT};font-weight:bold;}
.kpi{width:100%;border-collapse:separate;border-spacing:4px 0;}
.kpi td{background:#0b1017;border:1px solid ${LINE};padding:5px 7px;width:25%;}
.kpi .k{display:block;color:${DIM};font-size:9px;letter-spacing:1px;}
.kpi .v{display:block;color:#fff;font-size:14px;font-weight:bold;}
.kpi .v.p{color:${ACCENT};}
.badge{display:inline-block;border:1px solid #3a4a58;color:${GOLD};padding:0 5px;margin:0 4px 2px 0;font-size:9px;letter-spacing:.5px;}
.msg{background:#0b1017;border:1px solid ${LINE};padding:8px 10px;color:${DIM};}
.foot{margin-top:10px;color:#5d6b79;font-size:9px;}
.foot a{color:#5d6b79;}
.fb{background:#0b1017;border:1px solid ${LINE};padding:14px;}
.fb .t1{font-size:17px;color:${ACCENT};font-weight:bold;letter-spacing:2px;}
`

// ---- shell ----------------------------------------------------------------

/**
 * One page. `header` is the player/server strip, `body` the product.
 * No script, no img, no external resource: a MOTD must never wait on a second
 * request.
 */
function shell({ title, kicker, header, lead, body, tabs, sid }) {
  const links = tabs && tabs.length
    ? `<div class='tabs'>${tabs.map(t => t.on
      ? `<span class='pill on'>${esc(t.label)}</span>`
      : `<a class='pill' href='${esc(t.href)}'>${esc(t.label)}</a>`).join("")}</div>`
    : ""
  const html = `<!DOCTYPE html><html><head><meta charset='utf-8'>
<meta name='viewport' content='width=780'>
<title>FreeNova | ${esc(title)}</title>
<style>${CSS}</style></head>
<body bgcolor='${BG}' text='${TEXT}' link='${ACCENT}' vlink='${ACCENT}'>
<div class='wrap'>
${header || ""}
${lead ? `<div class='lead'>${lead}</div>` : ""}
<table width='100%' cellspacing='0' cellpadding='0' border='0'><tr>
  <td><div class='h2'>${esc(kicker || title)} <span>${esc(title)}</span></div></td>
</tr></table>
${links}
${body || ""}
<div class='foot'>FreeNova CS 1.6 &middot; server-authoritative &middot; snapshot every 30s<br>
Type <b>!missions</b> in chat for contracts, <b>!bp</b> for the battle pass${sid ? ` &middot; <a href='/m/p/${esc(packed(sid))}.htm'>profile</a> &middot; <a href='/m/t/${esc(packed(sid))}.htm'>top</a>` : ""}</div>
</div></body></html>`
  return new Response(html, {
    status: 200,
    headers: {
      "content-type": "text/html; charset=utf-8",
      "cache-control": "no-store",
      "x-robots-tag": "noindex",
      "referrer-policy": "no-referrer"
    }
  })
}

/** The static block served when live data cannot be read in time. */
export function renderFallback(reason, env) {
  const addr = String((env && env.FN_PUBLIC_ADDR) || "193.70.81.30:27015")
  const header = `<div class='hdr'>
    <table width='100%' cellspacing='0' cellpadding='0' border='0'><tr>
      <td><div class='brand'>FREE<i>NOVA</i> <span class='dim sml'>CS 1.6</span></div></td>
      <td align='right'><span class='off'>panel data unavailable</span></td>
    </tr></table>
  </div>`
  const body = `<div class='fb'>
    <div class='t1'>FREENOVA CS 1.6</div>
    <div class='dim' style='margin:4px 0 10px;'>${esc(addr)} &middot; fn-gaming.net</div>
    <table width='100%' cellspacing='0' cellpadding='0' border='0' class='t'>
      <tr><td class='m'>Your contracts</td><td class='num'>type !missions</td></tr>
      <tr><td class='m'>Battle pass</td><td class='num'>type !bp</td></tr>
      <tr><td class='m'>Leaderboard</td><td class='num'>type !top15</td></tr>
      <tr><td class='m'>Events</td><td class='num'>type !events</td></tr>
    </table>
    <div class='msg' style='margin-top:10px;'>The live panel did not answer in time, so this page shows the static
    server card instead of waiting. Everything above still works in game.</div>
    <div class='sml dim' style='margin-top:6px;'>${esc(reason || "live data unavailable")}</div>
  </div>`
  return shell({ title: "Server info", kicker: "Panels", header, lead: "", body })
}

// ---- shared blocks --------------------------------------------------------

function serverStrip(meta, now) {
  const fresh = meta && meta.lastPush && now - meta.lastPush <= 180
  const live = Boolean(meta && meta.online && fresh)
  const stale = Boolean(meta && meta.online && !fresh)
  const label = live
    ? `${n(meta.players)} / ${n(meta.maxplayers || 32)} &middot; ${esc(meta.map || "—")}`
    : stale ? "server stale" : "server offline"
  return `<div class='${live ? "live" : "off"}'>${live ? "&#9679;" : "&#9675;"} ${label}</div>
    <div class='dim sml'>${esc((meta && meta.hostname) || "FreeNova CS 1.6")}</div>`
}

/**
 * The player header every v2 page carries: name, rank, BP tier + XP bar to the
 * next tier, coins and text badges. Works for a player with no row at all.
 */
function playerHeader(p, meta, now) {
  const name = p && p.name ? p.name : (p ? p.steamid : "New player")
  const rank = p && p.rank ? "#" + n(p.rank) : "Unranked"
  const tier = p ? p.bp_tier : 1
  const maxed = tier >= BP_MAX_TIER
  const need = p ? p.bp_tier_xp || 1000 : 1000
  const into = p ? (maxed ? need : p.bp_progress) : 0
  const pct = maxed ? 100 : clampPct(into * 100 / Math.max(1, need))
  const coins = p ? n(p.coins) : "0"
  const badges = (p && p.badges) || []
  const badgeHtml = badges.length
    ? `<div style='margin-top:3px;'>${badges.slice(0, 4).map(b => `<span class='badge'>${esc(b.label || b.kind)}</span>`).join("")}</div>`
    : ""
  return `<div class='hdr'>
    <table width='100%' cellspacing='0' cellpadding='0' border='0'><tr>
      <td width='58%' valign='top'>
        <div class='brand'>FREE<i>NOVA</i> <span class='dim sml'>PANELS</span></div>
        <div class='who'>${esc(name)} <span class='tag'>${esc(rank)}</span>
          <span class='you'>TIER ${n(tier)}/${BP_MAX_TIER}</span></div>
        ${bar(pct, maxed ? GOLD : ACCENT)}
        <div class='dim sml'>${maxed ? "MAX TIER" : `${n(into)} / ${n(need)} BP XP to tier ${n(tier + 1)}`}
          &middot; <span style='color:${GOLD}'>${coins} coins</span></div>
        ${badgeHtml}
      </td>
      <td width='42%' align='right' valign='top'>${serverStrip(meta, now)}</td>
    </tr></table>
  </div>`
}

function tabsFor(code, sid, tabs, active) {
  const base = `/m/${code}/${packed(sid)}`
  return tabs.map(([key, label]) => ({
    label,
    href: key ? `${base}/${key}.htm` : `${base}.htm`,
    on: key === active
  }))
}

// ---- missions -------------------------------------------------------------

function missionRow(m) {
  const done = missionDone(m)
  const val = Math.max(0, Number(m.val) || 0)
  const target = Math.max(1, Number(m.target) || 1)
  const pct = done ? 100 : clampPct(val * 100 / target)
  const reward = String(m.reward || "").trim()
  const state = done ? "DONE" : (m.tracker ? "TRACKER" : "OPEN")
  return `<tr>
    <td width='46%'><span class='m'>${esc(m.title || "Contract")}</span><br><span class='s'>${esc(m.desc || "")}</span></td>
    <td width='34%'>${bar(pct, done ? ACCENT : GOLD)}
      <span class='s'>${n(Math.min(val, target))} / ${n(target)}${reward ? " &middot; " + esc(reward) : ""}</span></td>
    <td width='20%' class='${done ? "done" : "num"}'>${state}</td>
  </tr>`
}

function missionsBody(g, tab) {
  const all = [].concat(g.daily, g.bonus, g.weekly, g.special)
  const doneCount = all.filter(missionDone).length
  const section = (title, list) => list.length
    ? `<div class='card'><div class='h2'>${esc(title)} <span>${list.filter(missionDone).length}/${list.length}</span></div>
       <table class='t' width='100%' cellspacing='0' cellpadding='0' border='0'>${list.map(missionRow).join("")}</table></div>`
    : ""
  if (tab === "completed") {
    const done = all.filter(missionDone)
    return done.length
      ? `<div class='card'><div class='h2'>COMPLETED <span>${done.length}</span></div>
         <table class='t' width='100%' cellspacing='0' cellpadding='0' border='0'>${done.map(missionRow).join("")}</table></div>
         <div class='msg' style='margin-top:7px;'>Rewards are paid by the game server. Type <b>!missions</b> in chat to claim.</div>`
      : `<div class='msg'><b>Nothing completed yet today.</b><br>Your first contract pays out immediately: get 15 ranked kills, or type <b>!missions</b> in chat to see the set.</div>
         ${section("Daily contracts", g.daily)}`
  }
  if (tab === "weekly") return section("Weekly contracts", g.weekly)
  if (tab === "special") return section("Competitive dailies", g.special)
  if (tab === "seasonal") return section("Season trackers", g.seasonal)
  return section("Daily contracts", g.daily) + section("Bonus contracts", g.bonus) + section("Weekly contracts", g.weekly)
}

async function pageMissionsV2(env, url, ctx, data) {
  const { p, row, meta, now } = data
  const g = row ? missionGroups(row) : { daily: [], bonus: [], weekly: [], special: [], seasonal: [] }
  const tab = String(ctx.tab || "").toLowerCase()
  const known = ["daily", "weekly", "completed", "special", "seasonal"]
  const active = known.includes(tab) ? tab : ""
  const all = [].concat(g.daily, g.bonus, g.weekly, g.special)
  const done = all.filter(missionDone).length
  const dailyDone = g.daily.filter(missionDone).length
  const lead = !row
    ? `<b>Play one round to unlock your contracts.</b> The daily set pays <span class='gold'>+500 XP</span> when all 5 are claimed.`
    : done === 0
      ? `<b>${n(all.length)} contracts open &middot; +500 XP</b> for the 5-daily set. Type <b>!missions</b> in chat to claim.`
      : `<b>${n(done)} / ${n(all.length)} contracts done</b> &middot; ${dailyDone}/${g.daily.length} daily. Claim the payouts in game with <b>!missions</b>.`
  const body = `<table class='kpi' cellspacing='4' cellpadding='0' border='0' width='100%'><tr>
      <td><span class='k'>DAILY</span><span class='v p'>${dailyDone}/${g.daily.length}</span></td>
      <td><span class='k'>WEEKLY</span><span class='v'>${g.weekly.filter(missionDone).length}/${g.weekly.length}</span></td>
      <td><span class='k'>SPECIAL</span><span class='v'>${g.special.filter(missionDone).length}/${g.special.length}</span></td>
      <td><span class='k'>DONE</span><span class='v'>${n(done)}</span></td>
    </tr></table>
    ${missionsBody(g, active)}`
  return shell({
    title: "Missions", kicker: "Contracts", header: playerHeader(p, meta, now), lead,
    tabs: tabsFor("i", ctx.steamid, [["daily", "Daily"], ["weekly", "Weekly"], ["special", "Special"], ["seasonal", "Season"], ["completed", "Completed"]], active),
    body, sid: ctx.steamid
  })
}

// ---- battle pass ----------------------------------------------------------

async function rewardTrack(env) {
  try {
    const cat = await env.DB.prepare(`SELECT json FROM catalog WHERE key = 'reward_track'`).first()
    if (cat && cat.json) {
      const j = JSON.parse(cat.json)
      if (j && Array.isArray(j.tiers) && j.tiers.length) return j
    }
  } catch {}
  return null
}

async function pageBattlePassV2(env, url, ctx, data) {
  const { p, meta, now } = data
  const track = await rewardTrack(env)
  const need = xpPerTier(track)
  const tier = p ? p.bp_tier : 1
  const maxed = tier >= BP_MAX_TIER
  const into = p ? (maxed ? need : p.bp_progress) : 0
  const pct = maxed ? 100 : clampPct(into * 100 / Math.max(1, need))
  const tiers = track && Array.isArray(track.tiers) ? track.tiers : []
  const upcoming = tiers
    .filter(t => Number(t.tier) > tier)
    .sort((a, b) => Number(a.tier) - Number(b.tier))
    .slice(0, 3)
  const rows = upcoming.length
    ? upcoming.map(t => {
        const prem = String(t.premium || "").trim()
        const free = String(t.free || "").trim()
        return `<tr>
          <td class='pos'>${n(t.tier)}</td>
          <td><span class='m'>${esc(t.name || "Reward")}</span><br>
            <span class='s'>Free: ${esc(free || "—")}${prem ? " &middot; <span style='color:" + GOLD + "'>Premium: " + esc(prem) + "</span>" : ""}</span></td>
          <td class='num'>${n((Number(t.tier) - tier) * need - into)} XP</td>
        </tr>`
      }).join("")
    : `<tr><td colspan='3' class='s'>${maxed ? "Every tracked reward is unlocked." : "The live reward track has not been pushed yet - it appears after the next sync."}</td></tr>`
  const lead = maxed
    ? `<b>MAX TIER ${BP_MAX_TIER}.</b> Every reward on the track is unlocked. <span class='gold'>Coins and skills are paid in game.</span>`
    : `<b>${n(Math.max(0, need - into))} BP XP to tier ${n(tier + 1)}</b> &middot; next reward: ${esc((upcoming[0] && upcoming[0].name) || "coin payout")}.`
  const body = `<div class='card'>
      <div class='h2'>PROGRESS <span>${maxed ? "max tier" : `${n(into)} / ${n(need)} this tier`}</span></div>
      ${bar(pct, maxed ? GOLD : ACCENT)}
      <table class='kpi' cellspacing='4' cellpadding='0' border='0' width='100%' style='margin-top:6px;'><tr>
        <td><span class='k'>TIER</span><span class='v p'>${n(tier)}/${BP_MAX_TIER}</span></td>
        <td><span class='k'>BP XP</span><span class='v'>${n(p ? p.bp_xp : 0)}</span></td>
        <td><span class='k'>TO NEXT</span><span class='v'>${maxed ? "—" : n(Math.max(0, need - into))}</span></td>
        <td><span class='k'>TRACK XP</span><span class='v'>${n(need)}/tier</span></td>
      </tr></table></div>
    <div class='card'><div class='h2'>NEXT THREE REWARDS</div>
      <table class='t' width='100%' cellspacing='0' cellpadding='0' border='0'>
        <tr><th>Tier</th><th>Reward</th><th style='text-align:right'>XP to go</th></tr>
        ${rows}
      </table></div>
    <div class='msg' style='margin-top:7px;'>The game pays every tier. Open <b>!bp</b> in chat to claim, and
    <b>!missions</b> for the contracts that earn the XP.</div>`
  return shell({
    title: "Battle Pass", kicker: "Season track", header: playerHeader(p, meta, now), lead,
    body, sid: ctx.steamid
  })
}

// ---- events ---------------------------------------------------------------

async function pageEventsV2(env, url, ctx, data) {
  const { p, meta, now } = data
  const schedule = await loadSchedule(env, now)
  const { now: live, next } = splitSchedule(schedule, now)
  const lead = live.length
    ? `<b>${esc(live[0].title)} is live now</b> &middot; ${esc(countdownText(live[0], now) || "running")}. ${esc(live[0].detail || "")}`
    : next
      ? `<b>NEXT: ${esc(next.title)}</b> &middot; ${esc(countdownText(next, now))} (${esc(utcText(next.starts_at))}). ${esc(next.detail || "")}`
      : `<b>No scheduled event right now.</b> The server still pays normal XP and coins; watch <b>!events</b> in chat.`
  const row = (e, tag) => `<tr>
      <td width='58%'><span class='m'>${esc(e.title)}</span><br><span class='s'>${esc(e.detail || "")}</span></td>
      <td width='22%' class='s'>${esc(utcText(e.starts_at))}<br>${esc(utcText(e.ends_at))}</td>
      <td width='20%' class='${e.state === "active" ? "done" : "num"}'>${esc(tag)}</td>
    </tr>`
  const liveRows = live.length
    ? live.map(e => row(e, countdownText(e, now) || "LIVE")).join("")
    : `<tr><td colspan='3' class='s'>Nothing running right now.</td></tr>`
  const upcoming = schedule.filter(e => e.state === "scheduled").slice(0, 5)
  const nextRows = upcoming.length
    ? upcoming.map(e => row(e, countdownText(e, now) || "scheduled")).join("")
    : `<tr><td colspan='3' class='s'>No upcoming events on the panel schedule.</td></tr>`
  const body = `<div class='card'><div class='h2'>RUNNING NOW <span>${live.length} live</span></div>
      <table class='t' width='100%' cellspacing='0' cellpadding='0' border='0'>${liveRows}</table></div>
    <div class='card'><div class='h2'>UP NEXT</div>
      <table class='t' width='100%' cellspacing='0' cellpadding='0' border='0'>${nextRows}</table></div>
    <div class='msg' style='margin-top:7px;'>Countdowns are computed on the server. The multipliers the game
    actually applies come from the game's own <b>events.ini</b>; this page shows the panel schedule.</div>`
  return shell({
    title: "Events", kicker: "Live operations", header: playerHeader(p, meta, now), lead,
    body, sid: ctx.steamid
  })
}

// ---- top ------------------------------------------------------------------

function boardTable(rows, meSid, emptyText) {
  if (!rows.length) return `<div class='msg'>${esc(emptyText)}</div>`
  return `<table class='t' width='100%' cellspacing='0' cellpadding='0' border='0'>
    <tr><th>#</th><th>Player</th><th style='text-align:right'>XP</th></tr>
    ${rows.map(r => `<tr class='${meSid && r.steamid === meSid ? "me" : ""}'>
      <td class='pos${r.rank === 1 ? " g1" : r.rank === 2 ? " g2" : r.rank === 3 ? " g3" : ""}'>${n(r.rank)}</td>
      <td><span class='m'>${esc(r.name || r.steamid || "Unknown")}</span>${meSid && r.steamid === meSid ? " <span class='you'>YOU</span>" : ""}</td>
      <td class='num'>${n(r.value)}</td>
    </tr>`).join("")}
  </table>`
}

async function pageTopV2(env, url, ctx, data) {
  const { p, row, meta, now } = data
  const tab = ["week", "month"].includes(String(ctx.tab || "").toLowerCase())
    ? String(ctx.tab).toLowerCase() : "all"
  const sid = ctx.steamid

  const board = tab === "all"
    ? await lifetimeBoard(env, { metric: "xp", limit: 3 })
    : await periodBoard(env, { period: tab, metric: "xp", limit: 5, now })

  // Own standing: lifetime by XP, or the current period's board. Both are
  // counted in SQL, so a rank below 100 is still exact.
  let own = { rank: null, value: 0, ahead: null, behind: 0 }
  if (row) {
    own = tab === "all"
      ? await playerLifetimeStanding(env, row)
      : await playerPeriodStanding(env, sid, { period: tab, metric: "xp", now })
  }
  const windowText = tab === "all"
    ? "lifetime XP"
    : `${board.label} · ${tab === "week" ? "Monday 00:00" : "1st 00:00"} Europe/Paris`
  const lead = !row
    ? `<b>No rank yet.</b> Play a round: your first XP puts you on the board.`
    : own.rank
      ? `<b>You are #${n(own.rank)}</b> with ${n(own.value)} XP${own.ahead ? ` &middot; <span class='gold'>${n(own.behind)} XP behind #${n(own.ahead.rank)} (${esc(own.ahead.name || "?")})</span>` : " &middot; <span class='gold'>top of the board</span>"}.`
      : `<b>Not on this board yet.</b> ${tab === "all" ? "Score XP to enter the top 15." : "This period has no XP recorded for you yet - the panel starts counting from your first snapshot inside it."}`
  const champions = tab === "all" ? [] : await recentChampions(env, tab, 3)
  const champHtml = champions.length
    ? `<div class='card'><div class='h2'>PREVIOUS WINNERS</div>
       <table class='t' width='100%' cellspacing='0' cellpadding='0' border='0'>${champions.map(c =>
         `<tr><td width='40%'><span class='m'>${esc(c.name || c.steamid || "?")}</span></td>
          <td class='s'>${esc(c.label || c.period_key)}</td><td class='num'>${n(c.value)}</td></tr>`).join("")}</table></div>`
    : ""
  const body = `<div class='card'><div class='h2'>${tab === "all" ? "TOP 3 &middot; LIFETIME" : `TOP 5 &middot; ${esc(board.label)}`}
      <span>${esc(windowText)}</span></div>
      ${boardTable(board.rows, sid, "No ranked players yet - the first snapshot fills this board.")}</div>
    ${champHtml}
    <div class='msg' style='margin-top:7px;'>Weekly boards cut at Monday 00:00 Europe/Paris, monthly boards on the
    1st at 00:00 Europe/Paris - the same boundary the website and the bot use.</div>`
  return shell({
    title: "Top 15", kicker: "Leaderboard", header: playerHeader(p, meta, now), lead,
    tabs: tabsFor("t", sid, [["", "Lifetime"], ["week", "This week"], ["month", "This month"]], tab === "all" ? "" : tab),
    body, sid
  })
}

// ---- profile --------------------------------------------------------------

async function pageProfileV2(env, url, ctx, data) {
  const { p, row, meta, now } = data
  if (!row) {
    const body = `<div class='card'><div class='h2'>NO SNAPSHOT YET</div>
      <table class='t' width='100%' cellspacing='0' cellpadding='0' border='0'>
        <tr><td class='m'>Rank</td><td class='num'>unranked</td></tr>
        <tr><td class='m'>Battle pass</td><td class='num'>Tier 1 / ${BP_MAX_TIER} &middot; 0 XP</td></tr>
        <tr><td class='m'>Coins</td><td class='num'>0</td></tr>
        <tr><td class='m'>Playtime</td><td class='num'>0m</td></tr>
      </table></div>
      <div class='msg' style='margin-top:7px;'>The panel has no snapshot for <b>${esc(ctx.steamid)}</b> yet.
      Play a few minutes on the server and reopen this page - the game pushes a snapshot every 30 seconds.</div>`
    return shell({
      title: "Profile", kicker: "Rank stats",
      header: playerHeader(null, meta, now),
      lead: `<b>Your first contract is waiting.</b> Win a round, get 15 kills - the daily set pays <span class='gold'>+500 XP</span>.`,
      tabs: tabsFor("p", ctx.steamid, [["", "Profile"]], ""), body, sid: ctx.steamid
    })
  }

  let weekly = { rank: null, value: 0, ahead: null, behind: 0 }
  try {
    weekly = await playerPeriodStanding(env, ctx.steamid, { period: "week", metric: "xp", now })
  } catch {}
  const badgeHtml = (p.badges || []).length
    ? `<div class='card'><div class='h2'>BADGES</div><div>${p.badges.map(b => `<span class='badge'>${esc(b.label || b.kind)}</span>`).join("")}</div></div>`
    : `<div class='msg' style='margin-top:7px;'>No badges yet. Win a weekly board, or finish in the top 3 - badges are text only and stay on your profile.</div>`
  const lead = p.rank
    ? `<b>Rank #${n(p.rank)}</b> &middot; tier ${n(p.bp_tier)}/${BP_MAX_TIER} &middot; next tier needs <span class='gold'>${n(p.bp_next_xp)} XP</span>.`
    : `<b>Unranked - 0 XP.</b> Play one round to enter the board. <span class='gold'>Your first contract pays +500 XP.</span>`
  const kd = Number(row.deaths) > 0 ? (Number(row.kills) / Number(row.deaths)).toFixed(2) : (Number(row.kills) > 0 ? Number(row.kills).toFixed(2) : "—")
  const hsPct = Number(row.headshots) > 0 && Number(row.kills) > 0
    ? Math.round(Number(row.headshots) * 100 / Number(row.kills)) + "%" : "—"
  const body = `<div class='card'><div class='h2'>CAREER</div>
      <table class='kpi' cellspacing='4' cellpadding='0' border='0' width='100%'><tr>
        <td><span class='k'>KILLS</span><span class='v'>${n(row.kills)}</span></td>
        <td><span class='k'>K/D</span><span class='v'>${esc(kd)}</span></td>
        <td><span class='k'>HS%</span><span class='v'>${esc(hsPct)}</span></td>
        <td><span class='k'>PLAYTIME</span><span class='v'>${esc(playtime(row.playtime_minutes))}</span></td>
      </tr></table>
      <table class='kpi' cellspacing='4' cellpadding='0' border='0' width='100%' style='margin-top:4px;'><tr>
        <td><span class='k'>COINS</span><span class='v' style='color:${GOLD}'>${n(row.coins)}</span></td>
        <td><span class='k'>BP TIER</span><span class='v p'>${n(p ? p.bp_tier : 1)}/${BP_MAX_TIER}</span></td>
        <td><span class='k'>THIS WEEK</span><span class='v'>${weekly.rank ? "#" + n(weekly.rank) : "—"}</span></td>
        <td><span class='k'>WEEK XP</span><span class='v'>${weekly.rank ? n(weekly.value) : 0}</span></td>
      </tr></table></div>
    ${badgeHtml}
    <div class='msg' style='margin-top:7px;'>Weekly XP is counted from the panel's first snapshot inside the week
    (Monday 00:00 Europe/Paris). Everything here is server-authoritative.</div>`
  return shell({
    title: "Profile", kicker: "Rank stats", header: playerHeader(p, meta, now), lead,
    tabs: tabsFor("p", ctx.steamid, [["", "Profile"]], ""), body, sid: ctx.steamid
  })
}

// ---- entry point ----------------------------------------------------------

async function withBudget(promise, ms) {
  let timer = null
  try {
    return await Promise.race([
      promise,
      new Promise(resolve => { timer = setTimeout(() => resolve(null), ms) })
    ])
  } finally {
    if (timer) clearTimeout(timer)
  }
}

/**
 * ctx: { code: "p"|"i"|"e"|"b"|"t", steamid: "STEAM_...", tab: "daily"|... }
 */
export async function pageMotdV2(env, url, ctx) {
  const now = nowSec()
  const sid = ctx.steamid
  const collect = async () => {
    const meta = await serverMeta(env, now)
    // Two reads per page: the public summary (rank/BP/coins/badges, the same
    // shape /api/public/player answers) and the raw players row the mission
    // and career blocks are built from.
    const p = sid ? await publicPlayerSummary(env, sid) : null
    let row = null
    if (sid) {
      try { row = await env.DB.prepare(`SELECT * FROM players WHERE steamid = ?1`).bind(sid).first() }
      catch { row = null }
    }
    return { meta, p, row, now }
  }
  let data = null
  try {
    data = await withBudget(collect(), PAGE_BUDGET_MS)
  } catch (e) {
    console.error("motd v2 data:", e && e.message)
    data = null
  }
  if (!data) return renderFallback("panel data unavailable", env)

  const build = () => {
    switch (ctx.code) {
      case "i": return pageMissionsV2(env, url, ctx, data)
      case "e": return pageEventsV2(env, url, ctx, data)
      case "b": return pageBattlePassV2(env, url, ctx, data)
      case "t": return pageTopV2(env, url, ctx, data)
      default: return pageProfileV2(env, url, ctx, data)
    }
  }
  try {
    const res = await withBudget(build(), PAGE_BUDGET_MS)
    return res || renderFallback("the page took too long to build", env)
  } catch (e) {
    console.error("motd v2 render:", e && e.message)
    return renderFallback("the page could not be built", env)
  }
}
