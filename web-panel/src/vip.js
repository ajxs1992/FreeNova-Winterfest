// VIP panel — membership tier, expiry, active perks and store tiers.
import { loadTheme } from "./top15/store.js"
import { serverMeta } from "./top15/meta.js"
import { motdFrame, esc, fmt, alpha } from "./top15/render.js"
import { vipName } from "./ui.js"

const TIER_COLOR = ["#8a99a8", "#5e98d9", "#8847ff", "#e8c547"]
const TIER_STORE = ["", "VIP", "VIP Gold", "VIP Diamond"]
const TIER_PRICE = ["", "$3/mo", "$4/mo", "$6/mo"]
const XP_BONUS = ["—", "+50%", "+100%", "+150%"]
const COIN_BONUS = ["—", "1.5x", "2.0x", "2.5x"]
const STORE_URL = "https://fn-gaming.net/store.php?section=vip"

function steamidOf(url) {
  const minted = url && url._fnMotdSid
  if (minted && /^STEAM_[0-9]:[0-9]:\d+$/.test(String(minted))) return String(minted)
  const q = (url.searchParams.get("steamid") || "").trim()
  if (/^STEAM_[0-9]:[0-9]:\d+$/.test(q)) return q
  const m = String(url.pathname || "").match(/\/m\/[a-z]\/(\d+-\d+-\d+)/i)
  if (m) return "STEAM_" + m[1].replace(/-/g, ":")
  return ""
}

function humanizeRemaining(sec) {
  const s = Math.max(0, Number(sec) || 0)
  if (s < 60) return Math.max(1, s) + "s"
  if (s < 3600) return Math.floor(s / 60) + "m"
  if (s < 86400) {
    const h = Math.floor(s / 3600)
    const m = Math.floor((s % 3600) / 60)
    return m ? `${h}h ${m}m` : `${h}h`
  }
  const d = Math.floor(s / 86400)
  const h = Math.floor((s % 86400) / 3600)
  return h ? `${d}d ${h}h` : `${d}d`
}

const PERKS = [
  { tier: 1, name: "XP bonus", value: "+50%" },
  { tier: 1, name: "Coin multiplier", value: "1.5x" },
  { tier: 1, name: "Chat tag + TAB badge" },
  { tier: 1, name: "Join / leave notices" },
  { tier: 1, name: "Kill bonus rewards" },
  { tier: 1, name: "CT defuse kit" },
  { tier: 1, name: "Shop VIP skins" },
  { tier: 1, name: "Battle Pass premium track" },
  { tier: 2, name: "Spawn cash bonus", value: "$1,000" },
  { tier: 2, name: "Armory menu (/vmenu)" },
  { tier: 2, name: "VIP player model" },
  { tier: 2, name: "Bullet-damage HUD" },
  { tier: 2, name: "Parachute" },
  { tier: 3, name: "Multi-jump" }
]

export async function pageVip(env, url) {
  const theme = await loadTheme(env)
  const now = Math.floor(Date.now() / 1000)
  const meta = await serverMeta(env, now)
  const steamid = steamidOf(url)

  let p = null
  if (steamid) {
    try {
      p = await env.DB.prepare(`SELECT * FROM players WHERE steamid = ?1`).bind(steamid).first()
    } catch {}
  }

  const tier = p ? Math.max(0, Math.min(3, Number(p.vip_tier) || 0)) : 0
  const remaining = p ? Number(p.vip_remaining) : 0
  const label = vipName(tier)
  const color = TIER_COLOR[tier] || TIER_COLOR[0]
  const activeN = PERKS.filter(k => tier >= k.tier).length
  const expiry = !p ? "No snapshot"
    : tier === 0 ? "No membership"
      : remaining === -1 ? "Permanent"
        : remaining > 0 ? humanizeRemaining(remaining) + " left"
          : "Active"

  const kpis = `<table class='kpis' cellspacing='4' cellpadding='0'><tr>
      <td><span class='k'>Tier</span><span class='v p'>${tier} / 3</span></td>
      <td><span class='k'>Status</span><span class='v'>${esc(expiry)}</span></td>
      <td><span class='k'>XP</span><span class='v'>${XP_BONUS[tier]}</span></td>
      <td><span class='k'>Coins</span><span class='v'>${COIN_BONUS[tier]}</span></td>
    </tr></table>`

  const hero = `<table class='vip-hero' style='border-left-color:${color}' cellspacing='0' cellpadding='0'><tr>
      <td class='vip-crestcol'><img class='vip-crest' src='/vip/tier_${tier}.png' width='58' height='58' alt=''></td>
    <td>
        <div class='vip-kicker'>${tier > 0 ? "Current membership" : "Membership"}</div>
        <div class='vip-name' style='color:${color}'>${esc(label)}</div>
        <div class='vip-sub'>${p ? esc(p.name) + " · " + esc(steamid) : "Open from the game to link your account"}</div>
      </td>
      <td class='r'>
        <div class='vip-expiry'>${esc(expiry)}</div>
        <div class='vip-perksactive'>${activeN} / ${PERKS.length} perks active</div>
      </td>
    </tr></table>`

  const section = (t, name, bonus, note) => {
    const list = PERKS.filter(k => k.tier === t)
    const cells = []
    for (let i = 0; i < list.length; i += 2) {
      const one = list[i]
      const two = list[i + 1]
      const oneOn = tier >= t
      const twoOn = two && tier >= t
      const cell = (k, on) => k
        ? `<td class='perk'>${esc(k.name)}${k.value ? ` <span class='vip-val'>${esc(k.value)}</span>` : ""}</td><td class='state ${on ? "on" : ""}'>${on ? "ACTIVE" : "LOCKED"}</td>`
        : `<td class='perk'></td><td class='state'></td>`
      cells.push(`<tr>${cell(one, oneOn)}${cell(two, twoOn)}</tr>`)
    }
    return `<div class='vip-tierhead' style='border-top-color:${TIER_COLOR[t]}'>
        <img class='vip-tiersmall' src='/vip/tier_${t}.png' width='18' height='18' alt=''>
        <span class='vip-tiername' style='color:${TIER_COLOR[t]}'>${name}</span>
        <span class='vip-tierbonus'>${bonus}</span>
        <span class='vip-tierprice'>${TIER_PRICE[t]} · ${TIER_STORE[t]}</span>
        ${tier === t ? `<span class='badge done'>YOUR TIER</span>` : ""}
      </div>
      <table class='vip-perks' cellspacing='0' cellpadding='0'>${cells.join("")}</table>`
  }

  const store = `<div class='sect' style='margin-top:8px;'>Membership</div>
    <table class='vip-store' cellspacing='0' cellpadding='0'>
      <tr><td><span class='vip-tiername' style='color:${TIER_COLOR[1]}'>VIP</span></td><td class='v'>${TIER_PRICE[1]}</td><td class='r'><a href='${STORE_URL}'>STORE</a></td></tr>
      <tr><td><span class='vip-tiername' style='color:${TIER_COLOR[2]}'>VIP+</span> <span class='muted'>VIP Gold</span></td><td class='v'>${TIER_PRICE[2]}</td><td class='r'><a href='${STORE_URL}'>STORE</a></td></tr>
      <tr><td><span class='vip-tiername' style='color:${TIER_COLOR[3]}'>ELITE</span> <span class='muted'>VIP Diamond</span></td><td class='v'>${TIER_PRICE[3]}</td><td class='r'><a href='${STORE_URL}'>STORE</a></td></tr>
    </table>`

  const content = `${kpis}${hero}
    ${section(1, "VIP", "+50% XP · 1.5x coins", "8 perks")}
    ${section(2, "VIP+", "+100% XP · 2.0x coins", "5 more perks")}
    ${section(3, "ELITE", "+150% XP · 2.5x coins", "Multi-jump")}
    ${store}
    <div class='panel msg'>Tier multipliers shown here match the current server defaults; the game server applies the live values and entitlement rules.</div>`

  return motdFrame({
    theme, meta,
    title: "VIP",
    kicker: `Membership · ${label}`,
    sub: `${expiry} · ${activeN}/${PERKS.length} perks active`,
    backHref: steamid ? "/profile?steamid=" + encodeURIComponent(steamid) : "/",
    backLabel: steamid ? "Profile" : "Panels",
    content
  })
}
