// Battle Pass panel — compact reward rail around the player's current tier.
import { loadTheme } from "./top15/store.js"
import { serverMeta } from "./top15/meta.js"
import { motdFrame, esc, fmt } from "./top15/render.js"
import { DEFAULT_SKILLS } from "./catalogs.js"
import { PERK_PREVIEW_TRACK } from "./bp_perk_track.js"
import { isMotdCompact } from "./ui.js"
import { xpPerTier, playerBpTier, bpInto } from "./bp_track.js"

function steamidOf(url) {
  const minted = url && url._fnMotdSid
  if (minted && /^STEAM_[0-9]:[0-9]:\d+$/.test(String(minted))) return String(minted)
  const q = (url.searchParams.get("steamid") || "").trim()
  if (/^STEAM_[0-9]:[0-9]:\d+$/.test(q)) return q
  const m = String(url.pathname || "").match(/\/m\/b\/(\d+-\d+-\d+)/i)
  if (m) return "STEAM_" + m[1].replace(/-/g, ":")
  return ""
}

export async function pageBattlePass(env, url) {
  const theme = await loadTheme(env)
  const now = Math.floor(Date.now() / 1000)
  const meta = await serverMeta(env, now)
  const steamid = steamidOf(url)
  const preview = false
  let track = PERK_PREVIEW_TRACK

  const tiers = Array.isArray(track.tiers) ? track.tiers : []
  const need = xpPerTier(track)
  const season = String(track.season || "1")

  if (!steamid) {
    return motdFrame({
      theme, meta, title: "Battle Pass", kicker: `Season ${season} · Cyber Genesis`,
      sub: "Open this panel from the game",
      backHref: "/", backLabel: "Panels",
      content: `<div class='panel msg'><b>Open from the game</b><br>Run <b>/battlepass</b> in chat.</div>`
    })
  }

  let p = null
  try {
    p = await env.DB.prepare(`SELECT * FROM players WHERE steamid = ?1`).bind(steamid).first()
  } catch {}
  if (!p) {
    return motdFrame({
      theme, meta, title: "Battle Pass", kicker: `Season ${season} · Cyber Genesis`,
      sub: "No player snapshot",
      backHref: "/profile", backLabel: "Profile",
      content: `<div class='panel msg'><b>No snapshot for ${esc(steamid)}</b><br>Play a few minutes on the server, then retry.</div>`
    })
  }

  // BattlePass XP/tier from the BP ledger columns (REVIEW.md §2.4 H1): this
  // page is the BP track, so rank xp/level and bp_milestone must not decide it.
  const bpXp = Math.max(0, Number(p.bp_xp) || 0)
  const maxTier = tiers.length || 60
  const tier = Math.min(maxTier, playerBpTier(p, need))
  const into = bpInto(bpXp, need)
  const pct = Math.max(0, Math.min(100, Math.round(into * 100 / need)))
  const premiumOwned = season === "1"
    ? (Number(p.bp_premium) > 0 || Number(p.vip_tier) > 0)
    : String(p.bp_premium_season || "") === season
  const nextTier = tiers.find(t => Number(t.tier) > tier)

  let skills = []
  try {
    skills = ((await env.DB.prepare(
      `SELECT skill, stage FROM player_skills WHERE steamid = ?1 AND stage > 0`
    ).bind(steamid).all()).results) || []
  } catch {}
  const skillDefs = DEFAULT_SKILLS.skills || []

  let start = Math.max(1, tier - 2)
  if (start + 7 > maxTier) start = Math.max(1, maxTier - 7)
  const maxStart = Math.max(1, maxTier - 7)
  const currentStart = start
  const reqFrom = Number(url.searchParams.get("from"))
  if (Number.isFinite(reqFrom) && reqFrom >= 1) {
    start = Math.min(Math.max(1, Math.floor(reqFrom)), maxStart)
  }
  const shown = tiers.filter(t => Number(t.tier) >= start && Number(t.tier) < start + 8)

  const trackRows = shown.map(t => {
    const n = Number(t.tier)
    const un = n <= tier
    const isNow = n === tier
    const isNext = nextTier && n === Number(nextTier.tier)
    const nodeCls = isNow ? " now" : un ? " un" : isNext ? " next" : ""
    const premBuyLocked = !premiumOwned
    const premDim = !un || premBuyLocked
    const freeIcon = `/bp3/free_${t.icon || "coins"}.png`
    const premIcon = `/bp3/prem_${t.premIcon || "coins"}.png`
    return `<tr class='trow${isNow ? " now" : ""}' title='${esc(t.name || "")}'>
      <td class='rew free${un ? "" : " locked"}'>
        <span class='rtxt'>${esc(t.free || "")}</span>
        <img class='ricon' src='${freeIcon}' width='32' height='32' alt='' onerror='this.style.display="none"'>
      </td>
      <td class='nodecell'><span class='tnode${nodeCls}'>${fmt(n)}</span></td>
      <td class='rew premium${premDim ? " locked" : ""}'>
        <img class='ricon' src='${premIcon}' width='32' height='32' alt='' onerror='this.style.display="none"'>
        <span class='rtxt'>${esc(t.premium || "")}</span>
      </td>
    </tr>`
  }).join("")

  const navHref = (f) => `/battlepass?from=${f}${preview ? "&preview=perks" : ""}${steamid ? "&steamid=" + encodeURIComponent(steamid) : ""}${isMotdCompact() ? "&compact=1" : ""}`
  const currentVisible = tier >= start && tier < start + shown.length
  const backCurrent = tier >= 1 && !currentVisible ? `<a href='${navHref(currentStart)}'>Back to tier ${fmt(tier)}</a> · ` : ""
  const prevStart = Math.max(1, start - 8)
  const nextStart = Math.min(maxStart, start + 8)
  const trackNav = `<table class='tracknav' cellspacing='0' cellpadding='0'><tr>
    <td>${start > 1 ? `<a href='${navHref(prevStart)}'>‹ Tiers ${prevStart}–${prevStart + 7}</a>` : ""}</td>
    <td class='c'>${backCurrent}Tiers ${start}–${start + shown.length - 1} of ${maxTier}</td>
    <td class='r'>${start + 8 <= maxStart ? `<a href='${navHref(nextStart)}'>Tiers ${nextStart}–${nextStart + 7} ›</a>` : ""}</td>
  </tr></table>`

  const skillRows = (() => {
    const rows = []
    for (let i = 0; i < skills.length; i += 2) {
      const cell = (s) => {
        if (!s) return "<td></td><td></td>"
        const def = skillDefs.find(d => d.id === s.skill)
        const name = def ? def.name : String(s.skill || "")
        const max = def && def.max_stage ? def.max_stage : "?"
        return `<td class='skn' title='${esc(def && def.desc ? def.desc : name)}'>${esc(name)}</td><td class='st'>Stage ${fmt(s.stage)} / ${esc(max)}</td>`
      }
      rows.push(`<tr>${cell(skills[i])}<td class='gap'></td>${cell(skills[i + 1])}</tr>`)
    }
    return rows.join("")
  })()

  const previewPerks = tiers.filter(t => t.icon && t.icon !== "coins").length
  const skillsBlock = skills.length
    ? `<table class='bp-skill' cellspacing='0' cellpadding='0'>${skillRows}</table>`
    : `<div class='panel msg'><b>No combat skills yet</b><br>Unlock them on the Battle Pass track; skills are granted by tier.</div>`
  const footer = preview
    ? ""
    : `<div class='sect' style='margin-top:8px;'>Combat skills · owned ${fmt(skills.length)}</div>
    ${skillsBlock}`

  const trackNote = preview
    ? `<div class='panel msg'><b>Concept preview.</b> This is the proposed perk track, not the live grant track. The game server still pays the current coin/lane rewards on the normal Battle Pass page.</div>`
    : `<div class='panel msg'>Server-authoritative. Free and premium rewards are granted by the game server; premium rewards require an active premium lane. Higher VIP lanes still unlock lane skills earlier.</div>`
  const content = `${trackNote}<table class='kpis' cellspacing='4' cellpadding='0'><tr>
      <td><span class='k'>Tier</span><span class='v p'>${fmt(tier)} / ${fmt(maxTier)}</span></td>
      <td><span class='k'>XP to next</span><span class='v'>${fmt(need - into)}</span></td>
      <td><span class='k'>Premium</span><span class='v'>${premiumOwned ? "Owned" : "Locked"}</span></td>
      <td><span class='k'>${preview ? "Perks" : "Skills"}</span><span class='v'>${preview ? fmt(previewPerks) : fmt(skills.length)}</span></td>
    </tr></table>
    <div class='bp-progress'>
      <table class='proghead' cellspacing='0' cellpadding='0'><tr>
        <td>Tier ${fmt(tier)} → ${fmt(Math.min(maxTier, tier + 1))}</td>
        <td class='r'>${fmt(into)} / ${fmt(need)} BP XP · ${fmt(bpXp)} total</td>
      </tr></table>
      <div class='progbar'><i style='width:${pct}%'></i></div>
    </div>
    <div class='sect' style='margin-top:8px;'>Reward track</div>
    <table class='track' cellspacing='0' cellpadding='0'>
      <tr class='trackhead'><td class='r'>Free track</td><td></td><td class='p'>Premium track${preview ? "" : " (VIP lane)"}${premiumOwned ? "" : " · locked"}</td></tr>
      ${trackRows}
    </table>
    ${trackNav}
    ${footer}`

  return motdFrame({
    theme, meta,
    title: "Battle Pass",
    kicker: `Season ${season} · Cyber Genesis${preview ? " · Preview" : ""}`,
    sub: preview
      ? `Preview · ${tier} of ${maxTier} tiers · ${premiumOwned ? "Premium active" : "Free track"}`
      : `${tier} of ${maxTier} tiers · ${premiumOwned ? "Premium owned" : "Free track"}`,
    backHref: "/profile?steamid=" + encodeURIComponent(steamid),
    backLabel: "Profile",
    content
  })
}
