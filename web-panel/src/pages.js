// FreeNova web panel — page renderers. All read-only views over D1 (pushed
// game truth) + action queueing through sync.js. Zero client-side JS.
import {
  html, page404, needSteamid, notFound, errorState,
  esc, fmt, num, ratingStr, kdStr, pct, isOnline, ago, skillName, vipName,
  progressBar, emptyState, sortHeader, WEAPONS, COSMETICS, isMotdCompact,
  panelHref, navHref, tabBar, medalTable, flagImg, eventKind, eventIcon
} from "./ui.js"
import { queueAction, actionStatusLine, saveFeatured, mintActionToken, localTrustEnabled, NO_MINT_MSG } from "./sync.js"
import {
  DEFAULT_REWARD_TRACK, DEFAULT_SKILLS, DEFAULT_SKINS, DEFAULT_MODELS,
  DEFAULT_ACHIEVEMENTS, DEFAULT_COSMETICS, DEFAULT_HALL_OF_FAME,
  RARITY_ORDER, RARITY_INDEX, RARITY_STYLE, ACH_META, ACH_CATEGORIES, seasonPremiumCtaUrl
} from "./catalogs.js"
import { RANKS, rankName, rankProgress } from "./ranks.js"
import {
  premiumLaneName, premiumPerk, normalizeBpRarity, hasSeasonPremium, premiumExtraCoins,
  playerBpTier, bpInto
} from "./bp_track.js"

// Canonical Battle Pass tier: the BP ledger only (REVIEW.md §2.4 H1). Rank
// level and bp_milestone used to win here, which is why a player with rank
// level 40 and no BP XP read "tier 40". The curve lives in bp_track.js.
function bpTierOf(p, need) {
  return playerBpTier(p, need)
}
function vipLane(vipTier) {
  const t = num(vipTier)
  if (t >= 3) return 3
  if (t >= 2) return 2
  if (t >= 1) return 1
  return 0
}

// Premium reward label. The catalog text names the drop and (on coin tiers)
// restates the TOTAL premium payout, but the player also earns the free-lane
// coin floor at the same tier. The panel therefore shows the game-computed
// EXTRA coins (bp_track.premiumExtraCoins = premium total - free floor) so
// the label never double-counts: tier 60 lane 2 reads "+7,500c Global Elite"
// (12,500c total - 5,000c free), and non-coin drops lose the stale "+100c"
// prefix the catalog carries ("Medic Vapor", not "+100c Medic Vapor").
// Catalog amounts are display-source data only and are never edited here.
function stripCoinText(s) {
  return String(s)
    .replace(/^\s*\+\s*[\d,]+\s*(?:c\b|coins?\b)\s*[:,]?\s*/i, "")
    .replace(/\s*\+\s*[\d,]+\s*(?:c\b|coins?\b)\s*$/i, "")
    .trim()
}
function premiumLabel(t, lane) {
  const raw = lane >= 3 ? String(t.premium_elite || t.premium_plus || t.premium || "ELITE drop")
    : lane >= 2 ? String(t.premium_plus || t.premium || "VIP+ drop")
    : String(t.premium || "VIP drop")
  const name = stripCoinText(raw) || raw
  const extra = premiumExtraCoins(num(t && t.tier), lane || 1)
  return extra > 0 ? `+${fmt(extra)}c ${name}` : name
}

function tierPerk(t) {
  if (t && t.premium_perk && t.premium_perk.key) return t.premium_perk
  return premiumPerk(num(t && t.tier))
}

const PERK_BOX = {
  jumps: { label: "Double Jump", tint: "#0d4a3a", ink: "#36DEAB" },
  hp: { label: "+HP", tint: "#4a1a32", ink: "#e879a8" },
  xpboost: { label: "XP Boost", tint: "#4a3208", ink: "#fbbf24" },
  sniper: { label: "Fast Sniper", tint: "#2a1a4a", ink: "#c084fc" },
  title: { label: "Title", tint: "#4a3a08", ink: "#fbbf24" },
  tag: { label: "Chat Tag", tint: "#4a3a08", ink: "#fbbf24" },
  spawn: { label: "Spawn FX", tint: "#083a4a", ink: "#22d3ee" },
  chat_color: { label: "Chat Color", tint: "#2a4a08", ink: "#a3e635" },
  skin_flip: { label: "Knife Skin", tint: "#4a0d3a", ink: "#e879f9" },
  model_legend: { label: "Player Model", tint: "#08344a", ink: "#38bdf8" },
  chute: { label: "Parachute", tint: "#083a42", ink: "#67e8f9" },
  laststand: { label: "Last Stand", tint: "#4a1220", ink: "#fb7185" }
}

function boxLabel(t) {
  const perk = tierPerk(t)
  if (perk && perk.key === "hp") return "+" + (perk.n || 2) + " HP"
  if (perk && perk.key === "jumps") return perk.n >= 2 ? "Triple Jump" : "Double Jump"
  if (perk && PERK_BOX[perk.key]) return PERK_BOX[perk.key].label
  if (t && t.free_coins) return "+" + fmt(t.free_coins) + "c"
  return String((t && (t.name || t.free)) || "Coins").replace(/\s*\(.*\)\s*$/, "").slice(0, 18)
}

function boxTint(t) {
  const perk = tierPerk(t)
  if (perk && PERK_BOX[perk.key]) return PERK_BOX[perk.key].tint
  // normalizeBpRarity: D1 pushes UPPERCASE rarities; without this every
  // compact cell fell back to flat #3A4240 (fixed 2026-10-10).
  return BP_RARITY_BG[normalizeBpRarity(t && t.rarity)] || "#3A4240"
}

function boxInk(t) {
  const perk = tierPerk(t)
  if (perk && PERK_BOX[perk.key]) return PERK_BOX[perk.key].ink
  return (t && t.star === "gold") ? "#FFD700" : "#EDF1EF"
}

function steamidOf(url) {
  // MOTD stamp from index.js wins over a conflicting ?steamid= (same as VIP).
  // Public /profile?steamid= without a stamp still uses the query.
  const minted = vipMintedSteamid(url)
  if (minted) return minted
  const q = url.searchParams.get("steamid") || ""
  if (/^STEAM_[0-9]:[0-9]:\d+$/.test(q)) return q
  const short = String(url.pathname || "").match(/\/m\/[pbtisavoer]\/(\d+-\d+-\d+)/i)
  if (short) return "STEAM_" + short[1].replace(/-/g, ":")
  const m = String(url.pathname || "").match(/\/u\/(STEAM_[0-9]-[0-9]-\d+)/i)
  if (m) {
    const restored = m[1].replace(/-/g, ":").replace(/^STEAM:/i, "STEAM_")
    if (/^STEAM_[0-9]:[0-9]:\d+$/.test(restored)) return restored
    const parts = m[1].split("-")
    if (parts.length >= 3)
      return `STEAM_${parts[0].replace(/^STEAM_/i, "")}:${parts[1]}:${parts.slice(2).join("")}`
  }
  return ""
}

function compact(url) {
  // GoldSrc compact hint: MOTD viewports are narrow; large values force it.
  return url.searchParams.get("compact") === "1" ? "1" : ""
}

function vipMintedSteamid(url) {
  // Only index.js can set this, and only when the original path was a
  // game-minted /m/v/<d>-<d>-<d> or /u/STEAM_... rewrite. Query/UA/compact
  // cannot create url._fnMotdSid.
  const sid = url && url._fnMotdSid
  return /^STEAM_[0-9]:[0-9]:\d+$/.test(sid) ? sid : ""
}

// Action token for THIS render. Explicit ?t= always wins, so a game-minted
// /u/<sid>/<slug>/k/<token> link keeps working on any deployment. Beyond that
// the panel only mints when it is explicitly trusted to (FN_LOCAL_TRUST=1, see
// sync.js localTrustEnabled): REVIEW.md §3.8 - a silent mint turns "I can render
// this page" into "I may act for this steamid", which a public deployment must
// never allow. No steamid / no SYNC_SECRET / no trust → "" and every caller
// falls back to its read-only state.
async function pageActionToken(env, url, steamid) {
  const explicit = url.searchParams.get("t") || ""
  if (explicit) return explicit
  if (!steamid || !env || !env.SYNC_SECRET) return ""
  if (!localTrustEnabled(env)) return ""
  return await mintActionToken(env, steamid)
}

// ============================================================ HOME
export async function pageHome(env, url) {
  let rows
  try {
    rows = await env.DB.prepare(
      `SELECT COUNT(*) AS total, SUM(CASE WHEN last_seen > ?1 THEN 1 ELSE 0 END) AS online
       FROM players`).bind(Math.floor(Date.now() / 1000) - 900).first()
  } catch { return errorState("HOME", "home", "platform statistics") }

  const body = `
  <div class='card ok'><div class='h2'>FREENOVA PLATFORM</div>
    <p class='muted'>One progression system. One currency. One inventory. Live data pushed
    straight from the game server — everything you see here is the same truth the server uses.</p></div>
  <div class='card'><div class='h2'>PANELS</div><table class='t'>
    <tr><td class='k'>Profile</td><td><a href='/profile'>/profile</a> <span class='muted'>/rank /rankstats /statsme</span></td></tr>
    <tr><td class='k'>Leaderboards</td><td><a href='/top'>/top</a> <span class='muted'>same theme as MOTD rsu.php</span></td></tr>
    <tr><td class='k'>Battle Pass</td><td><a href='/battlepass'>/battlepass</a> <span class='muted'>/bp</span></td></tr>
    <tr><td class='k'>Missions</td><td><a href='/missions'>/missions</a></td></tr>
    <tr><td class='k'>Achievements</td><td><a href='/achievements'>/achievements</a></td></tr>
    <tr><td class='k'>Tournament</td><td><a href='/tournament'>/tournament</a> <span class='muted'>/ctop</span></td></tr>
    <tr><td class='k'>Events</td><td><a href='/events'>/events</a></td></tr>
    <tr><td class='k'>VIP</td><td><a href='/vip'>/vip</a> <span class='muted'>in-game /vip · /help</span></td></tr>
    <tr><td class='k'>Shop</td><td class='muted'>in-game only — N menu or /shop</td></tr>
    <tr><td class='k'>In-game</td><td class='muted'>N or /menu · /help · /profile · /bp · /shop · /vip</td></tr>
    <tr><td class='k'>Discord</td><td><a href='https://discord.gg/vuGaWjuX'>discord.gg/vuGaWjuX</a> <span class='muted'>official invite</span></td></tr>
  </table></div>
  <div class='card'><div class='h2'>PLATFORM STATUS</div><table class='t'>
    <tr><td class='k'>Tracked players</td><td class='v'>${fmt(rows && rows.total)}</td></tr>
    <tr><td class='k'>Online (last 15 min)</td><td class='v'>${fmt(rows && rows.online)}</td></tr>
  </table></div>`
  return html("HOME", body, { nav: "home" })
}

// ============================================================ STATS VIEWER
// Read-only "who is online" board (was src/top15/viewer.js, inlined by the
// rewrite). Sort keys are whitelisted through SV_MODES and mapped to fixed
// SQL columns; unknown keys fall back to xp and are never concatenated raw.
const SV_MODES = {
  xp: "xp",
  kills: "kills",
  mvp: "mvps",
  wins: "wins",
  plants: "bp_daily_plants",
  explode: "bp_daily_plants",
  defuse: "bp_daily_defuses",
  playtime: "playtime_minutes",
  skill: "kills"
}
// Kill-share skill bands — contract copied from the retired top15/theme.js.
const SV_SKILL_BANDS = [
  [0, "L-"], [60, "L"], [75, "L+"], [85, "M-"], [100, "M"], [115, "M+"],
  [130, "H-"], [140, "H"], [150, "H+"], [165, "P-"], [180, "P"], [195, "P+"], [210, "G"]
]
function svSkill(kills, deaths) {
  const tot = num(kills) + num(deaths)
  const ratio = tot > 0 ? (100 * num(kills)) / tot : 0
  let band = SV_SKILL_BANDS[0]
  for (const b of SV_SKILL_BANDS) if (ratio >= b[0]) band = b
  return { ratio, name: band[1] }
}

export async function pageStatsViewer(env, url) {
  const sortRaw = url.searchParams.get("sort")
  const sort = Object.prototype.hasOwnProperty.call(SV_MODES, sortRaw) ? sortRaw : "xp"
  const col = SV_MODES[sort]
  let rows = []
  try {
    const q = await env.DB.prepare(
      `SELECT steamid, name, xp, kills, deaths, mvps, wins, bp_daily_plants, bp_daily_defuses, playtime_minutes, last_seen
       FROM players WHERE last_seen > ?1
       ORDER BY ${col} DESC, xp DESC, steamid ASC LIMIT 32`
    ).bind(Math.floor(Date.now() / 1000) - 900).all()
    rows = q.results || []
  } catch { rows = [] }
  const links = Object.keys(SV_MODES).map(k =>
    k === sort ? `<b>${esc(k)}</b>` : `<a href='/statsviewer?sort=${esc(k)}'>${esc(k)}</a>`
  ).join(" · ")
  let body = `<div class='card'><div class='h2'>STATS VIEWER</div>
    <div class='muted'>Online last 15 min · sort: ${links}</div>
    <table class='t' cellspacing='0' cellpadding='4' border='0'>
    <tr><th>#</th><th>Name</th><th>XP</th><th>Kills</th><th>Skill</th><th></th></tr>`
  let i = 0
  for (const r of rows) {
    i++
    const s = svSkill(r.kills, r.deaths)
    const from = encodeURIComponent("/statsviewer?sort=" + sort)
    body += `<tr>
      <td class='v'>${i}</td>
      <td><b>${esc(r.name)}</b></td>
      <td class='v'>${fmt(r.xp)}</td>
      <td class='v'>${fmt(r.kills)}</td>
      <td>${esc(s.name)} ${Math.round(s.ratio)}</td>
      <td><a href='/profile?steamid=${encodeURIComponent(r.steamid)}&from=${from}'>open</a></td>
    </tr>`
  }
  if (!rows.length) body += `<tr><td colspan='6' class='muted'>No online players on the replica yet.</td></tr>`
  body += `</table></div>`
  return html("STATS VIEWER", body, { product: "top" })
}

const WEAPON_MASTERY_THRESHOLDS = [
  0, 50, 150, 300, 500, 750, 1100, 1500, 2000, 2600, 3300, 4100, 5000, 6000, 7200, 8500, 10000
]

function weaponMastery(kills) {
  const k = Math.max(0, num(kills))
  let lvl = 1
  for (let i = 0; i < WEAPON_MASTERY_THRESHOLDS.length; i++) {
    if (k >= WEAPON_MASTERY_THRESHOLDS[i]) lvl = i + 1
    else break
  }
  const maxLvl = WEAPON_MASTERY_THRESHOLDS.length
  const isMax = lvl >= maxLvl
  const curReq = WEAPON_MASTERY_THRESHOLDS[lvl - 1] || 0
  const nextReq = isMax ? curReq : (WEAPON_MASTERY_THRESHOLDS[lvl] || curReq)
  const span = Math.max(1, nextReq - curReq)
  const earned = Math.max(0, k - curReq)
  const progressPct = isMax ? 100 : Math.min(100, Math.round((earned / span) * 100))
  return {
    level: lvl,
    max: maxLvl,
    isMax,
    curReq,
    nextReq,
    remaining: Math.max(0, nextReq - k),
    progressPct
  }
}

const GUN_KEYS = [
  "ak47", "m4a1", "awp", "deagle", "knife", "usp", "glock",
  "famas", "galil", "scout", "aug", "sg552", "mp5", "p90", "ump45",
  "mac10", "tmp", "m249", "m3", "xm1014", "sg550", "g3sg1", "he"
]

// Owner-editable mastery locker. Empty gun list = hover stats only, no click-through.
// Mirrors addons/amxmodx/configs/mastery_skins.ini
const MASTERY_SKINS = [
  // { slot: 0, mastery: 8, flag: "public", name: "AK Field Camo", v: "models/v_ak47.mdl", p: "models/p_ak47.mdl" }
]

function skinsForSlot(slot) {
  return MASTERY_SKINS.filter(s => num(s.slot) === num(slot))
}

function flagAllows(flag, vipTier) {
  const f = String(flag || "public").toLowerCase()
  if (f === "public" || f === "all") return true
  if (f === "vip") return num(vipTier) >= 1
  if (f === "vipplus" || f === "vip+") return num(vipTier) >= 2
  if (f === "vipelite") return num(vipTier) >= 3
  return false
}

function masteryHoverBox(w) {
  return `<span class='tipc'>
    <div class='tt'>${esc(w.name)}</div>
    <div class='td'>Mastery <b>${fmt(w.mastery)}${w.isMax ? " MAX" : ""}</b></div>
    <div class='td'>Kills: <b>${fmt(w.kills)}</b> · HS: <b>${fmt(w.hs)}</b> (${w.hsPct}%)</div>
    <div class='td'>Damage: <b>${fmt(w.damage)}</b></div>
    ${w.isMax ? "" : `<div class='td'>Next level in <b>${fmt(w.remaining)}</b> kills</div>`}
  </span>`
}

function masteryCardBody(w) {
  return `<table width='100%' cellspacing='0' cellpadding='6' border='0'>
    <tr>
      <td width='60' valign='middle'>${gunIcon(w.slot)}</td>
      <td valign='middle'><b>${esc(w.name)}</b><br><span class='muted'>Mastery ${w.mastery}${w.isMax ? " MAX" : ""} · ${fmt(w.kills)} kills · ${w.hsPct}% HS · ${fmt(w.damage)} dmg</span></td>
    </tr>
    <tr><td colspan='2'><div class='bar'><div style='width:${w.progressPct}%'></div></div></td></tr>
  </table>`
}

function masteryCard(w, steamid) {
  const skins = skinsForSlot(w.slot)
  const inner = masteryCardBody(w)
  const boxed = `<span class='tip'>${inner}${masteryHoverBox(w)}</span>`
  if (!skins.length) {
    return `<div class='card' style='margin:0;'>${boxed}</div>`
  }
  return `<a class='card' href='/profile?tab=mastery&gun=${num(w.slot)}&steamid=${encodeURIComponent(steamid)}' style='margin:0;display:block;text-decoration:none;color:inherit;'>${boxed}</a>`
}

const SHOWCASE = [
  { id: "kills_100", title: "FIRST BLOOD CENTURY", type: "BADGE", field: "kills", target: 100, ap: 250, desc: "Record 100 ranked kills." },
  { id: "kills_1000", title: "KILLING MACHINE", type: "BADGE", field: "kills", target: 1000, ap: 250, desc: "Record 1,000 ranked kills." },
  { id: "kills_5000", title: "FREENOVA LEGEND KILLER", type: "MEDAL", field: "kills", target: 5000, ap: 500, desc: "Record 5,000 ranked kills." },
  { id: "hs_100", title: "SHARPSHOOTER", type: "BADGE", field: "headshots", target: 100, ap: 250, desc: "Land 100 ranked headshots." },
  { id: "hs_500", title: "HEADHUNTER", type: "BADGE", field: "headshots", target: 500, ap: 500, desc: "Land 500 ranked headshots." },
  { id: "bomb_specialist", title: "DEMOLITION EXPERT", type: "BADGE", field: "plants", target: 50, ap: 250, desc: "Plant the bomb 50 times." },
  { id: "defusal_angel", title: "BOMB SQUAD", type: "BADGE", field: "defuses", target: 25, ap: 250, desc: "Defuse the bomb 25 times." },
  { id: "wins_100", title: "TEAM PLAYER", type: "BADGE", field: "wins", target: 100, ap: 250, desc: "Win 100 rounds while alive." },
  { id: "level_25", title: "SEASONED SOLDIER", type: "MEDAL", field: "level", target: 26, ap: 250, desc: "Reach level 26." },
  { id: "level_52", title: "FREENOVA LEGEND", type: "MEDAL", field: "level", target: 52, ap: 1000, desc: "Reach level 52." },
  { id: "win_streak_10", title: "UNSTOPPABLE", type: "MEDAL", field: "streak", target: 10, ap: 500, desc: "Get a 10-kill streak in one life." },
  { id: "coin_tycoon", title: "COIN MAGNET", type: "BADGE", field: "coins", target: 10000, ap: 250, desc: "Hold 10,000 coins at once." },
  { id: "combat_medic", title: "COMBAT MEDIC", type: "MEDAL", field: "revives", target: 25, ap: 500, desc: "Revive 25 teammates." }
]
const LIVE_ACH_BITS = {
  kills_100: 0, first_blood: 0,
  kills_1000: 1, kill_machine_1: 1,
  kills_5000: 2,
  hs_100: 3,
  hs_500: 4, headhunter_1: 4,
  bomb_specialist: 5, plants_50: 5,
  defusal_angel: 6, defuses_25: 6,
  wins_100: 7,
  level_25: 8, level_26: 8,
  level_52: 9,
  prestige_1: 10,
  win_streak_10: 11, streak_10: 11,
  coin_tycoon: 12, coins_10000: 12,
  combat_medic: 13, revives_25: 13
}

function hasCol(p, key) {
  return p && Object.prototype.hasOwnProperty.call(p, key) && p[key] != null
}

function achProgressOf(p, metric) {
  if (!p) return { val: 0, tracked: true, note: "" }
  if (metric === "kills") return { val: hasCol(p, "ach_kills") ? num(p.ach_kills) : num(p.kills), tracked: true, note: "" }
  if (metric === "hs" || metric === "headshots") return { val: hasCol(p, "ach_hs") ? num(p.ach_hs) : num(p.headshots), tracked: true, note: "" }
  if (metric === "wins") return { val: hasCol(p, "ach_wins") ? num(p.ach_wins) : num(p.wins), tracked: true, note: "" }
  if (metric === "level") return { val: num(p.level), tracked: true, note: "" }
  if (metric === "coins") return { val: num(p.coins), tracked: true, note: "" }
  if (metric === "streak") {
    if (hasCol(p, "ach_streak")) return { val: num(p.ach_streak), tracked: true, note: "" }
    return { val: num(p.bp_daily_streak), tracked: true, note: "today's best until lifetime sync" }
  }
  if (metric === "plants") {
    if (hasCol(p, "ach_plants")) return { val: num(p.ach_plants), tracked: true, note: "" }
    return { val: 0, tracked: false, note: "Tracked in-game" }
  }
  if (metric === "defuses") {
    if (hasCol(p, "ach_defuses")) return { val: num(p.ach_defuses), tracked: true, note: "" }
    return { val: 0, tracked: false, note: "Tracked in-game" }
  }
  if (metric === "revives") {
    if (hasCol(p, "ach_revives")) return { val: num(p.ach_revives), tracked: true, note: "" }
    return { val: 0, tracked: false, note: "Tracked in-game" }
  }
  return { val: 0, tracked: false, note: "Tracked in-game" }
}

function achUnlockedOf(p, def, progress) {
  if (!p || !def) return false
  const bit = def.bit != null ? def.bit : LIVE_ACH_BITS[def.id]
  if (bit == null) return false
  return !!(num(p.ach_unlocked) & (1 << bit))
}

function liveAchList(catalog) {
  const raw = Array.isArray(catalog) ? catalog : (catalog && Array.isArray(catalog.achievements) ? catalog.achievements : [])
  const live = raw.filter(a => a && LIVE_ACH_BITS[a.id] != null && num(a.bit) !== 10)
  if (live.length === 13) return live.map(a => ({ ...a, bit: a.bit != null ? a.bit : LIVE_ACH_BITS[a.id] }))
  return DEFAULT_ACHIEVEMENTS.achievements
}

// Compact-MOTD achievement glyph: distinct shape per medal family (same
// keyword idea as msnGlyph), rarity color via medalColor. No image packs.
function medalGlyph(it) {
  const s = String((it && it.id) || "")
  if (/hs_/.test(s)) return "\u25CE"
  if (/plants|bomb_specialist/.test(s)) return "\u25A3"
  if (/defus/.test(s)) return "\u271A"
  if (/wins/.test(s)) return "\u265B"
  if (/level/.test(s)) return "\u2B22"
  if (/streak/.test(s)) return "\u2738"
  if (/coin/.test(s)) return "\u25C9"
  if (/medic|reviv/.test(s)) return "\u2665"
  return "\u2605"
}

// Compact-MOTD medallion color: rarity color, no photo art (uniform with the
// generic treatment on battlepass/missions).
function medalColor(it) {
  if (!it || !it.unlocked) return "#3f5f57"
  if ((it.type || "") === "MEDAL") return num(it.ap) >= 1000 ? "#FFD700" : "#c084fc"
  return num(it.ap) >= 500 ? "#7dd3fc" : "#9aa7b0"
}

function showcaseValue(def, p) {
  return achProgressOf(p, def.field || def.metric)
}

function deriveShowcase(p) {
  return badgeCabinet(p, null)
}

// ---- Single-source badge cabinet (2026-10-10) ----
// ONE helper feeds the Achievements page, the Badge Cabinet, and every
// player profile (own + public). Sort: Legendary > Mythic > Rare >
// Uncommon > Common, then most-recently-earned first, then title.
// earnedMap: {code: earned_at} from ap_unlocks (null = before date tracking).
function rarityBadge(rarity) {
  const st = RARITY_STYLE[rarity] || RARITY_STYLE.common
  return `<span class='rarity rarity-${esc(String(rarity || "common"))}' style='color:${st.color};border-color:${st.frame};'>${st.label}</span>`
}
function achRarityOf(id) {
  return (ACH_META[id] && ACH_META[id].rarity) || "common"
}
function achCategoryOf(id) {
  return (ACH_META[id] && ACH_META[id].category) || "special"
}
async function apUnlocksMap(env, steamid) {
  const map = {}
  try {
    const rows = ((await env.DB.prepare(
      `SELECT code, earned_at FROM ap_unlocks WHERE steamid = ?1`
    ).bind(steamid).all()).results) || []
    for (const r of rows) if (r && r.code) map[String(r.code).toLowerCase()] = num(r.earned_at)
  } catch {}
  return map
}
function badgeCabinet(p, earnedMap) {
  const items = SHOWCASE.map((def, idx) => {
    const progress = showcaseValue(def, p)
    const unlocked = achUnlockedOf(p, def, progress)
    const rarity = achRarityOf(def.id)
    const category = achCategoryOf(def.id)
    const key = String(def.id || "").toLowerCase()
    const earnedRaw = earnedMap && earnedMap[key] ? num(earnedMap[key]) : 0
    return {
      ...def,
      rarity, category,
      val: progress.val,
      tracked: progress.tracked,
      note: progress.note,
      unlocked,
      earned_at: unlocked ? earnedRaw : 0,
      state: unlocked ? "completed" : (progress.val > 0 ? "in-progress" : "locked"),
      art: achArt(def, idx)
    }
  })
  items.sort((a, b) =>
    (RARITY_INDEX[b.rarity] - RARITY_INDEX[a.rarity]) ||
    ((b.earned_at || 0) - (a.earned_at || 0)) ||
    String(a.title).localeCompare(String(b.title)))
  const earnedAP = items.filter(i => i.unlocked).reduce((s, i) => s + i.ap, 0)
  const totalAP = items.reduce((s, i) => s + i.ap, 0)
  const featured = items.filter(i => i.unlocked).slice(0, 5)
  const counts = { total: items.length, unlocked: items.filter(i => i.unlocked).length }
  return { items, earnedAP, totalAP, featured, counts }
}
function fmtEarned(ts) {
  const t = num(ts)
  if (!t) return "Earned before date tracking"
  try { return new Date(t * 1000).toISOString().slice(0, 10) } catch { return "Earned before date tracking" }
}

function pad2(n) {
  return String(Math.max(1, num(n))).padStart(2, "0")
}
function rankSrc(rankId) {
  const n = String(Math.min(Math.max(num(rankId) || 1, 1), 19)).padStart(2, "0")
  return `/ranks/rank_${n}.png`
}
function badgeSrc(n) {
  const i = ((Math.max(1, num(n)) - 1) % 32) + 1
  return `/medals/fn_badge_${pad2(i)}.png`
}

const SKILL_ART = {
  multi_jump: "/bp/skill_multi_jump.png", spawn_hp: "/bp/skill_spawn_hp.png",
  spawn_armor: "/bp/skill_spawn_armor.png", vampire: "/bp/skill_vampire.png",
  nimble: "/bp/skill_nimble.png", featherfall: "/bp/skill_featherfall.png",
  healthnade: "/bp/skill_healthnade.png", fast_sniper: "/bp/skill_fast_sniper.png",
  revive: "/bp/skill_revive.png", laststand: "/bp/skill_laststand.png",
  parachute: "/bp/skill_parachute.png", awp_unlock: "/bp/skill_awp_unlock.png",
  chat_color: "/bp/skill_chat_color.png"
}
const ACH_ART = {
  first_blood: "/medals/fn_first_blood.png", kill_machine_1: "/medals/fn_kill_machine_1.png",
  rampage: "/medals/fn_rampage.png", kill_machine_2: "/medals/fn_kill_machine_2.png",
  headhunter_1: "/medals/fn_headhunter_1.png", headhunter_2: "/medals/fn_headhunter_2.png",
  headhunter_3: "/medals/fn_headhunter_3.png", ace_master: "/medals/fn_ace_master.png",
  damage_dealer: "/medals/fn_damage_dealer.png",
  ak47_specialist: "/medals/fn_ak47_specialist.png", ak_spec: "/medals/fn_ak_spec.png",
  ak_master: "/medals/fn_ak_master.png", m4a1_operative: "/medals/fn_m4a1_operative.png",
  awp_god: "/medals/fn_awp_god.png", deagle_artist: "/medals/fn_deagle_artist.png",
  ninja_blade: "/medals/fn_ninja_blade.png", he_maestro: "/medals/fn_he_maestro.png",
  scout_elite: "/medals/fn_scout_elite.png",
  kills_100: "/medals/fn_kills_100.png", kills_1000: "/medals/fn_kills_1000.png",
  kills_5000: "/medals/fn_kills_5000.png", kills_10000: "/medals/fn_kills_10000.png",
  hs_100: "/medals/fn_hs_100.png", hs_500: "/medals/fn_hs_500.png",
  wins_100: "/medals/fn_wins_100.png", mvp_50: "/medals/fn_mvp_50.png",
  hours_100: "/medals/fn_hours_100.png", hours_500: "/medals/fn_hours_500.png",
  rank_max: "/medals/fn_rank_max.png",
  comp_ladder: "/medals/fn_comp_ladder.png", comp_master: "/medals/fn_comp_master.png",
  win_streak_10: "/medals/fn_win_streak_10.png", mvp_magnet: "/medals/fn_mvp_magnet.png",
  bomb_specialist: "/medals/fn_bomb_specialist.png", defusal_angel: "/medals/fn_defusal_angel.png",
  clutch_1v1: "/medals/fn_clutch_1v1.png", clutch_1v2: "/medals/fn_clutch_1v2.png",
  clutch_1v3: "/medals/fn_clutch_1v3.png", clutch_1v4: "/medals/fn_clutch_1v4.png",
  clutch_1v5: "/medals/fn_clutch_1v5.png",
  map_dust2: "/medals/fn_map_dust2.png", map_inferno: "/medals/fn_map_inferno.png",
  map_nuke: "/medals/fn_map_nuke.png", map_mirage: "/medals/fn_map_mirage.png",
  level_25: "/medals/fn_level_25.png", level_52: "/medals/fn_level_52.png",
  coin_tycoon: "/medals/fn_coin_tycoon.png", skill_master: "/medals/fn_skill_master.png",
  playtime_100h: "/medals/fn_playtime_100h.png", daily_streaker: "/medals/fn_daily_streaker.png",
  weekly_conqueror: "/medals/fn_weekly_conqueror.png", comeback_kings: "/medals/fn_comeback_kings.png",
  flawless_half: "/medals/fn_flawless_half.png", collector: "/medals/fn_collector.png",
  knife_the_awp: "/medals/fn_knife_the_awp.png", one_hp_survivor: "/medals/fn_one_hp_survivor.png",
  smoke_defuse: "/medals/fn_smoke_defuse.png",
  event_kill_race: "/medals/event_kill_race.png", event_hs_frenzy: "/medals/event_hs_frenzy.png",
  event_objective: "/medals/event_objective.png",
  combat_medic: "/medals/fn_combat_medic.png"
}
function achArt(a, idx) {
  const id = String((a && (a.id || a.metric)) || "").replace(/[^a-z0-9_]/gi, "")
  if (id && ACH_ART[id]) return ACH_ART[id]
  if (a && a.art) return a.art
  return badgeSrc((idx || 0) + 1)
}
// CS2-style service medals: ORIGINAL vector art (no Valve assets).
// Browser-only; MOTD compact keeps the existing <img> art path.
// Look: gold coin band + rivets, dark navy disc, level-color star,
// SERVICE MEDAL 2026 caption with the CS level (2-6, MAX).
function cs2MedalLevel(a) {
  const nm = String((a && (a.title || a.name)) || "").toUpperCase()
  const ap = num(a && a.ap)
  const ty = String((a && a.type) || "").toUpperCase()
  if (ap >= 1000 || nm === "FREENOVA LEGEND") return ["#e8c547", "MAX"]
  if (ty === "MEDAL" && ap >= 500) return ["#eb4b4b", "6"]
  if (ty === "MEDAL") return ["#d32ee6", "5"]
  if (ap >= 500) return ["#8847ff", "4"]
  if (num(a && a.target) >= 500) return ["#4b69ff", "3"]
  return ["#5e98d9", "2"]
}
const CS2_STAR = "50,12 58.9,37.7 86.1,38.3 64.5,54.7 72.3,80.7 50,65.2 27.7,80.7 35.5,54.7 13.9,38.3 41.1,37.7"
// Server-side alias ids share a bit with their canonical medal -> same emblem.
function cs2Canon(a) {
  const id = String((a && (a.id || a.metric)) || "")
  return { first_blood: "kills_100", kill_machine_1: "kills_1000", headhunter_1: "hs_500",
    plants_50: "bomb_specialist", defuses_25: "defusal_angel", level_26: "level_25",
    streak_10: "win_streak_10", coins_10000: "coin_tycoon", revives_25: "combat_medic",
    s1_champ: "wins_100", alltime_frags: "kills_5000", first_lvl52: "level_52",
    hs_master_10k: "hs_500", clutch_god_1v5: "win_streak_10", coin_billionaire: "coin_tycoon" }[id] || id
}
// Disc tint per medal family (kills/headshots/bomb/wins/level/streak/coins/medic).
function cs2Disc(id) {
  if (/^kills_/.test(id)) return "#1a0f14"
  if (/^hs_/.test(id)) return "#0d1a26"
  if (/bomb|defusal/.test(id)) return "#1c1408"
  if (/wins_/.test(id)) return "#0e1c12"
  if (/level_/.test(id)) return "#141a2e"
  if (/streak/.test(id)) return "#1c0e08"
  if (/coin/.test(id)) return "#1a1608"
  if (/medic/.test(id)) return "#0c1a16"
  return "#0d1526"
}
// One ORIGINAL emblem per medal. Stroke-style line icons, drawn for FreeNova.
// Detail pass 2026-10-10: every emblem gained inner detail (shine, ticks,
// secondary shapes) while keeping its approved silhouette.
function cs2Emblem(id, accent, hi) {
  const g = (inner) => `<g stroke-linecap='round' stroke-linejoin='round'>${inner}</g>`
  const ticks = (cx, cy, r1, r2, n, col, w, op) => {
    let s = ""
    for (let k = 0; k < n; k++) {
      const a = (Math.PI * 2 * k) / n
      s += `<line x1='${(cx + r1 * Math.cos(a)).toFixed(1)}' y1='${(cy + r1 * Math.sin(a)).toFixed(1)}' x2='${(cx + r2 * Math.cos(a)).toFixed(1)}' y2='${(cy + r2 * Math.sin(a)).toFixed(1)}' stroke='${col}' stroke-width='${w}' opacity='${op}'/>`
    }
    return s
  }
  const spark = (x, y, r, col, op) => `<path d='M${x} ${y - r} l${(r * 0.32).toFixed(1)} ${(r * 0.68).toFixed(1)} l${(r * 0.68).toFixed(1)} ${(r * 0.32).toFixed(1)} l${(-r * 0.68).toFixed(1)} ${(r * 0.32).toFixed(1)} l${(-r * 0.32).toFixed(1)} ${(r * 0.68).toFixed(1)} l${(-r * 0.32).toFixed(1)} ${(-r * 0.68).toFixed(1)} l${(-r * 0.68).toFixed(1)} ${(-r * 0.32).toFixed(1)} z' fill='${col}' opacity='${op}'/>`
  switch (id) {
    case "kills_100":
      return g(`<ellipse cx='50' cy='76' rx='20' ry='5' fill='${accent}' opacity='.18'/>`
        + `<path d='M50 20 C50 20 33 43 33 56 a17 17 0 0 0 34 0 C67 43 50 20 50 20z' fill='${accent}' stroke='${hi}' stroke-width='3'/>`
        + `<path d='M50 26 C50 26 39 42 39 54 a11 11 0 0 0 22 0 C61 42 50 26 50 26z' fill='${hi}' opacity='.22'/>`
        + `<ellipse cx='43.5' cy='52' rx='4' ry='6.5' fill='${hi}' opacity='.6'/>`
        + `<circle cx='58' cy='45' r='2.2' fill='${hi}' opacity='.85'/><circle cx='60.5' cy='58' r='1.4' fill='${hi}' opacity='.7'/>`
        + `<path d='M50 14 q-3 5 0 9 q3 -4 0 -9' fill='${accent}' opacity='.9'/>`
        + `<circle cx='31' cy='70' r='2' fill='${accent}' opacity='.8'/><circle cx='69' cy='70' r='2' fill='${accent}' opacity='.8'/><circle cx='38' cy='76' r='1.4' fill='${hi}' opacity='.7'/>`
        + `<path d='M28 76 q5.5 3.5 11 0 q5.5 -3.5 11 0 q5.5 3.5 11 0' fill='none' stroke='${hi}' stroke-width='2' opacity='.7'/>`
        + `<path d='M35 82 q5 3 10 0 q5 -3 10 0' fill='none' stroke='${accent}' stroke-width='1.8' opacity='.7'/>`
        + spark(68, 30, 6, hi, .9) + spark(30, 34, 4, hi, .7))
    case "kills_1000":
      return g(`<circle cx='50' cy='50' r='28' fill='none' stroke='${hi}' stroke-width='2' opacity='.5' stroke-dasharray='6 3'/>`
        + `<circle cx='50' cy='50' r='23' fill='none' stroke='${accent}' stroke-width='1.2' opacity='.5'/>`
        + `<g transform='rotate(45 50 50)'><rect x='42' y='18' width='16' height='26' rx='3' fill='${accent}' stroke='${hi}' stroke-width='2.4'/><rect x='42' y='56' width='16' height='26' rx='3' fill='${accent}' stroke='${hi}' stroke-width='2.4'/></g>`
        + `<line x1='35' y1='65' x2='65' y2='35' stroke='${hi}' stroke-width='6'/><line x1='35' y1='35' x2='65' y2='65' stroke='${hi}' stroke-width='6'/>`
        + `<line x1='35' y1='65' x2='65' y2='35' stroke='${accent}' stroke-width='2' opacity='.8'/><line x1='35' y1='35' x2='65' y2='65' stroke='${accent}' stroke-width='2' opacity='.8'/>`
        + `<polygon points='50,43 57,50 50,57 43,50' fill='${accent}' stroke='${hi}' stroke-width='1.8'/>`
        + `<circle cx='50' cy='50' r='2.2' fill='${hi}'/>`
        + `<circle cx='35' cy='65' r='4' fill='${accent}'/><circle cx='65' cy='65' r='4' fill='${accent}'/><circle cx='35' cy='35' r='4' fill='${accent}'/><circle cx='65' cy='35' r='4' fill='${accent}'/>`
        + `<circle cx='35' cy='65' r='1.4' fill='${hi}'/><circle cx='65' cy='35' r='1.4' fill='${hi}'/>`)
    case "kills_5000":
      return g(ticks(50, 46, 31, 34, 16, hi, 1.4, .45)
        + `<ellipse cx='50' cy='76' rx='20' ry='4.5' fill='#000000' opacity='.35'/>`
        + `<polygon points='36,30 40,16 46,25 50,12 54,25 60,16 64,30' fill='${hi}'/>`
        + `<polygon points='40,24 43,18 46,23 50,15 54,23 57,18 60,24' fill='${accent}' opacity='.85'/>`
        + `<circle cx='43' cy='21' r='2' fill='${accent}'/><circle cx='57' cy='21' r='2' fill='${accent}'/>`
        + `<circle cx='50' cy='47' r='14' fill='${accent}' stroke='${hi}' stroke-width='3'/>`
        + `<circle cx='50' cy='47' r='9' fill='none' stroke='${hi}' stroke-width='1.4' opacity='.6'/>`
        + `<path d='M50 38 l6 2 -6 2 -6 -2 z' fill='${hi}' opacity='.5'/>`
        + `<rect x='42' y='55' width='16' height='10' rx='3' fill='${accent}' stroke='${hi}' stroke-width='2'/>`
        + `<line x1='46.5' y1='57' x2='46.5' y2='63' stroke='#0d1526' stroke-width='1.4'/><line x1='50' y1='57' x2='50' y2='63' stroke='#0d1526' stroke-width='1.4'/><line x1='53.5' y1='57' x2='53.5' y2='63' stroke='#0d1526' stroke-width='1.4'/>`
        + `<circle cx='44.5' cy='45' r='3.2' fill='#0d1526'/><circle cx='55.5' cy='45' r='3.2' fill='#0d1526'/>`
        + `<circle cx='44.5' cy='45' r='1.1' fill='${hi}'/><circle cx='55.5' cy='45' r='1.1' fill='${hi}'/>`
        + `<polygon points='47,31 48.5,34.5 52,34.5 49.2,36.8 50.2,40.3 47,38.2 43.8,40.3 44.8,36.8 42,34.5 45.5,34.5' fill='${hi}'/>`
        + `<path d='M38 68 h24' stroke='${hi}' stroke-width='1.6' opacity='.6'/>`)
    case "hs_100":
      return g(ticks(50, 50, 28.5, 32, 12, hi, 1.6, .55)
        + `<circle cx='50' cy='50' r='15' fill='none' stroke='${hi}' stroke-width='3.5'/>`
        + `<circle cx='50' cy='50' r='15' fill='${accent}' opacity='.14'/>`
        + `<circle cx='50' cy='50' r='10.5' fill='none' stroke='${accent}' stroke-width='1.6' opacity='.8'/>`
        + `<line x1='50' y1='24' x2='50' y2='31' stroke='${hi}' stroke-width='3.5'/><line x1='50' y1='69' x2='50' y2='76' stroke='${hi}' stroke-width='3.5'/><line x1='24' y1='50' x2='31' y2='50' stroke='${hi}' stroke-width='3.5'/><line x1='69' y1='50' x2='76' y2='50' stroke='${hi}' stroke-width='3.5'/>`
        + `<circle cx='50' cy='39.5' r='1.3' fill='${hi}' opacity='.8'/><circle cx='50' cy='60.5' r='1.3' fill='${hi}' opacity='.8'/><circle cx='39.5' cy='50' r='1.3' fill='${hi}' opacity='.8'/><circle cx='60.5' cy='50' r='1.3' fill='${hi}' opacity='.8'/>`
        + `<circle cx='50' cy='50' r='3' fill='${accent}'/><circle cx='50' cy='50' r='6.5' fill='none' stroke='${accent}' stroke-width='1.4' opacity='.8'/>`)
    case "hs_500":
      return g(ticks(50, 50, 28.5, 32, 8, hi, 2, .6)
        + `<circle cx='50' cy='50' r='27' fill='none' stroke='${accent}' stroke-width='1.2' opacity='.45'/>`
        + `<circle cx='50' cy='50' r='21' fill='none' stroke='${hi}' stroke-width='2.5'/>`
        + `<circle cx='50' cy='50' r='14' fill='none' stroke='${accent}' stroke-width='2.5'/>`
        + `<circle cx='50' cy='48' r='9' fill='${accent}' stroke='${hi}' stroke-width='2'/>`
        + `<circle cx='46' cy='44' r='4.6' fill='#0d1526'/><circle cx='54' cy='44' r='4.6' fill='#0d1526'/>`
        + `<path d='M46 52 q4 3.4 8 0 q4 -3.4 8 0' fill='none' stroke='#0d1526' stroke-width='1.8'/>`
        + `<circle cx='46' cy='44' r='1.4' fill='${hi}'/><circle cx='54' cy='44' r='1.4' fill='${hi}'/>`
        + `<line x1='50' y1='24' x2='50' y2='29' stroke='${hi}' stroke-width='2.5'/><line x1='50' y1='71' x2='50' y2='76' stroke='${hi}' stroke-width='2.5'/><line x1='24' y1='50' x2='29' y2='50' stroke='${hi}' stroke-width='2.5'/><line x1='71' y1='50' x2='76' y2='50' stroke='${hi}' stroke-width='2.5'/>`
        + spark(50, 24, 4, hi, .8))
    case "bomb_specialist":
      return g(`<ellipse cx='50' cy='72' rx='22' ry='4.5' fill='#000000' opacity='.35'/>`
        + `<rect x='33' y='44' width='34' height='22' rx='4' fill='${accent}' stroke='${hi}' stroke-width='3'/>`
        + `<rect x='37' y='48' width='26' height='6' rx='2' fill='${hi}' opacity='.35'/>`
        + `<line x1='37' y1='56' x2='63' y2='56' stroke='#0d1526' stroke-width='1.4' opacity='.55'/>`
        + `<rect x='37' y='59' width='14' height='3' rx='1.5' fill='#0d1526' opacity='.5'/>`
        + `<line x1='42' y1='44' x2='42' y2='66' stroke='${hi}' stroke-width='2'/><line x1='58' y1='44' x2='58' y2='66' stroke='${hi}' stroke-width='2'/>`
        + `<rect x='44' y='38' width='12' height='7' rx='2' fill='${hi}'/>`
        + `<rect x='47' y='38' width='6' height='7' fill='${accent}' opacity='.7'/>`
        + `<path d='M50 38 q-1 -6 3 -9 q3 -2 2 -6 q6 1 5 7 q3 3 1 8' fill='none' stroke='${hi}' stroke-width='2.4'/>`
        + `<circle cx='63' cy='20' r='2.6' fill='${hi}'/>`
        + spark(70, 14, 7, hi, .95) + spark(58, 10, 4, accent, .9) + spark(78, 24, 3.4, hi, .8)
        + `<polygon points='33,68 37,64 41,68 37,72' fill='${hi}' opacity='.8'/>`)
    case "defusal_angel":
      return g(ticks(50, 50, 27, 31, 12, hi, 1.6, .4)
        + `<path d='M28 44 q-6 8 -10 10 q4 1 6 -2 q-4 6 -3 10 q5 -2 7 -6 z' fill='${hi}' opacity='.8'/>`
        + `<path d='M72 44 q6 8 10 10 q-4 1 -6 -2 q4 6 3 10 q-5 -2 -7 -6 z' fill='${hi}' opacity='.8'/>`
        + `<path d='M50 24 L66 30 V48 C66 60 58 66 50 70 C42 66 34 60 34 48 V30 z' fill='${accent}' stroke='${hi}' stroke-width='3'/>`
        + `<path d='M50 28 L62 33 V48 C62 57 55 62 50 65 C45 62 38 57 38 48 V33 z' fill='none' stroke='${hi}' stroke-width='1.2' opacity='.6'/>`
        + `<polyline points='43,48 48,54 58,40' fill='none' stroke='${hi}' stroke-width='4'/>`
        + `<polyline points='43,48 48,54 58,40' fill='none' stroke='#ffffff' stroke-width='1.4' opacity='.6'/>`
        + `<circle cx='50' cy='34' r='2.4' fill='${hi}'/>`
        + `<circle cx='36' cy='72' r='1.8' fill='${hi}' opacity='.7'/><circle cx='64' cy='72' r='1.8' fill='${hi}' opacity='.7'/>`)
    case "wins_100":
      return g(`<ellipse cx='50' cy='72' rx='20' ry='4' fill='#000000' opacity='.35'/>`
        + `<path d='M39 28 h22 v12 c0 9 -5 15 -11 17 v5 h5 v5 h-10 v-5 h5 v-5 c-6 -2 -11 -8 -11 -17 z' fill='${accent}' stroke='${hi}' stroke-width='3'/>`
        + `<ellipse cx='50' cy='38' rx='5' ry='7' fill='${hi}' opacity='.4'/>`
        + `<polygon points='50,32 52,37 57,37 53,40 54,45 50,42 46,45 47,40 43,37 48,37' fill='${hi}'/>`
        + `<path d='M39 30 c-7 0 -9 9 -2 13' fill='none' stroke='${hi}' stroke-width='3'/><path d='M61 30 c7 0 9 9 2 13' fill='none' stroke='${hi}' stroke-width='3'/>`
        + `<path d='M39 30 c-7 0 -9 9 -2 13' fill='none' stroke='${accent}' stroke-width='1.2' opacity='.7'/>`
        + `<path d='M61 30 c7 0 9 9 2 13' fill='none' stroke='${accent}' stroke-width='1.2' opacity='.7'/>`
        + `<rect x='42' y='62' width='16' height='4' rx='2' fill='${hi}'/><rect x='38' y='67' width='24' height='3.4' rx='1.7' fill='${hi}' opacity='.8'/>`
        + `<circle cx='30' cy='52' r='1.8' fill='${hi}' opacity='.8'/><circle cx='70' cy='52' r='1.8' fill='${accent}' opacity='.8'/><circle cx='50' cy='22' r='1.8' fill='${hi}' opacity='.8'/>`
        + spark(30, 22, 4.4, hi, .85) + spark(70, 22, 4.4, hi, .85))
    case "level_25":
      return g(`<rect x='24' y='22' width='52' height='60' rx='10' fill='none' stroke='${hi}' stroke-width='1.6' opacity='.5'/>`
        + `<polyline points='34,32 50,45 66,32' fill='none' stroke='${hi}' stroke-width='4' opacity='.5'/>`
        + `<polyline points='34,44 50,57 66,44' fill='none' stroke='${hi}' stroke-width='6'/>`
        + `<polyline points='34,44 50,57 66,44' fill='none' stroke='${accent}' stroke-width='2' opacity='.8'/>`
        + `<polyline points='34,58 50,71 66,58' fill='none' stroke='${accent}' stroke-width='6'/>`
        + `<polygon points='50,14 54,22 50,30 46,22' fill='${hi}'/>`
        + `<circle cx='50' cy='22' r='1.6' fill='${accent}'/>`
        + `<line x1='30' y1='78' x2='70' y2='78' stroke='${hi}' stroke-width='2.5' opacity='.7'/>`
        + `<circle cx='34' cy='78' r='2' fill='${accent}'/><circle cx='66' cy='78' r='2' fill='${accent}'/>`
        + `<circle cx='30' cy='57' r='1.8' fill='${hi}' opacity='.7'/><circle cx='70' cy='57' r='1.8' fill='${hi}' opacity='.7'/>`)
    case "level_52":
      return g(ticks(50, 50, 28, 32, 16, hi, 1.5, .5)
        + `<path d='M12 44 L34 50 L12 58 z' fill='${hi}'/><path d='M88 44 L66 50 L88 58 z' fill='${hi}'/>`
        + `<line x1='16' y1='48' x2='30' y2='51' stroke='${accent}' stroke-width='1.6'/><line x1='84' y1='48' x2='70' y2='51' stroke='${accent}' stroke-width='1.6'/>`
        + `<line x1='16' y1='53' x2='30' y2='51' stroke='${accent}' stroke-width='1' opacity='.7'/><line x1='84' y1='53' x2='70' y2='51' stroke='${accent}' stroke-width='1' opacity='.7'/>`
        + `<circle cx='12' cy='51' r='2.4' fill='${accent}'/><circle cx='88' cy='51' r='2.4' fill='${accent}'/>`
        + `<ellipse cx='50' cy='72' rx='16' ry='5' fill='${accent}' opacity='.2'/>`
        + `<polygon points='${CS2_STAR}' fill='${accent}' stroke='${hi}' stroke-width='2'/>`
        + `<polygon points='50,30 53,39 62,39 55,45 57,54 50,48 43,54 45,45 38,39 47,39' fill='${hi}' opacity='.85'/>`
        + `<circle cx='50' cy='42' r='2' fill='${hi}'/>`
        + `<path d='M38 68 l4 -6 4 6 4 -6 4 6' fill='none' stroke='${hi}' stroke-width='2'/>`
        + spark(24, 28, 4, hi, .8) + spark(76, 28, 4, hi, .8) + spark(50, 14, 3.4, accent, .9))
    case "win_streak_10":
      return g(`<circle cx='50' cy='50' r='28' fill='${accent}' opacity='.10'/>`
        + ticks(50, 50, 29, 32, 10, hi, 1.6, .4)
        + `<path d='M50 20 C56 32 64 38 64 52 a14 14 0 0 1 -28 0 C36 44 40 40 42 34 C44 38 46 40 48 40 C46 34 47 26 50 20z' fill='${accent}' stroke='${hi}' stroke-width='3'/>`
        + `<path d='M52 40 C54 46 58 48 58 54 a8 8 0 0 1 -16 0' fill='none' stroke='${hi}' stroke-width='2' opacity='.7'/>`
        + `<path d='M53 46 c1.5 3 4 4.5 4 8 a5.5 5.5 0 0 1 -11 0' fill='${accent}' stroke='${hi}' stroke-width='1.4'/>`
        + `<path d='M54 52 c1 1.8 2.6 2.8 2.6 5 a3.4 3.4 0 0 1 -6.8 0' fill='${hi}' opacity='.8'/>`
        + `<ellipse cx='50' cy='72' rx='14' ry='3.6' fill='#000000' opacity='.4'/>`
        + `<ellipse cx='50' cy='71' rx='9' ry='2.2' fill='${accent}' opacity='.5'/>`
        + spark(70, 30, 5, hi, .9) + spark(32, 62, 4, hi, .8) + spark(68, 64, 3.2, accent, .9)
        + `<circle cx='38' cy='72' r='1.8' fill='${hi}' opacity='.7'/><circle cx='44' cy='76' r='1.4' fill='${accent}' opacity='.8'/>`
        + `<path d='M60 14 q4 -1 5 -5' fill='none' stroke='${hi}' stroke-width='1.8' opacity='.6'/>`)
    case "coin_tycoon":
      return g(`<ellipse cx='50' cy='70' rx='22' ry='4.5' fill='#000000' opacity='.35'/>`
        + `<path d='M28 66 q-4 6 -8 7 q4 2 5 -1 q-2 5 0 8 q4 -3 5 -7 z' fill='${hi}' opacity='.8'/>`
        + `<ellipse cx='50' cy='62' rx='17' ry='6.5' fill='${accent}' stroke='${hi}' stroke-width='2.5'/>`
        + `<ellipse cx='50' cy='62' rx='9' ry='3.2' fill='none' stroke='${hi}' stroke-width='1.4' opacity='.7'/>`
        + `<ellipse cx='50' cy='53' rx='17' ry='6.5' fill='${accent}' stroke='${hi}' stroke-width='2.5'/>`
        + `<ellipse cx='50' cy='53' rx='9' ry='3.2' fill='none' stroke='${hi}' stroke-width='1.4' opacity='.7'/>`
        + `<line x1='33' y1='53' x2='33' y2='62' stroke='${hi}' stroke-width='1.4' opacity='.6'/><line x1='67' y1='53' x2='67' y2='62' stroke='${hi}' stroke-width='1.4' opacity='.6'/>`
        + `<ellipse cx='50' cy='44' rx='17' ry='6.5' fill='none' stroke='${hi}' stroke-width='3'/>`
        + `<ellipse cx='50' cy='40' rx='10' ry='4' fill='${accent}' opacity='.85'/>`
        + `<ellipse cx='47' cy='39' rx='3.4' ry='1.6' fill='${hi}' opacity='.8'/>`
        + `<polygon points='50,30 52,35 57,35 53,38 54,43 50,40 46,43 47,38 43,35 48,35' fill='${hi}'/>`
        + `<line x1='40' y1='42' x2='46' y2='42' stroke='${hi}' stroke-width='2.5'/>`
        + spark(72, 34, 4.4, hi, .85) + spark(28, 40, 3.4, accent, .85) + `<circle cx='64' cy='60' r='1.6' fill='${hi}' opacity='.7'/>`)
    case "combat_medic":
      return g(`<circle cx='50' cy='50' r='27' fill='none' stroke='${hi}' stroke-width='1.4' opacity='.4'/>`
        + ticks(50, 50, 28.5, 32, 12, hi, 1.8, .55)
        + `<circle cx='50' cy='50' r='17' fill='none' stroke='${hi}' stroke-width='3.5'/>`
        + `<circle cx='50' cy='50' r='17' fill='${accent}' opacity='.12'/>`
        + `<path d='M50 30 a4 4 0 0 1 4 4' fill='none' stroke='${hi}' stroke-width='2' opacity='.8'/>`
        + `<rect x='45' y='36' width='10' height='28' fill='${accent}'/>`
        + `<rect x='36' y='45' width='28' height='10' fill='${accent}'/>`
        + `<rect x='45' y='36' width='10' height='28' fill='none' stroke='${hi}' stroke-width='1.6'/>`
        + `<rect x='36' y='45' width='28' height='10' fill='none' stroke='${hi}' stroke-width='1.6'/>`
        + `<rect x='47.5' y='39' width='5' height='22' fill='${hi}' opacity='.5'/>`
        + `<circle cx='50' cy='50' r='2' fill='${hi}'/>`
        + `<path d='M28 38 a24 24 0 0 1 8 -8' fill='none' stroke='${accent}' stroke-width='2' opacity='.8'/>`
        + `<path d='M72 62 a24 24 0 0 1 -8 8' fill='none' stroke='${accent}' stroke-width='2' opacity='.8'/>`
        + spark(50, 22, 3.6, hi, .8))
    default:
      return g(ticks(50, 50, 27, 31, 12, hi, 1.6, .45)
        + `<circle cx='50' cy='48' r='20' fill='${accent}' opacity='.10'/>`
        + `<polygon points='${CS2_STAR}' fill='${accent}' stroke='${hi}' stroke-width='2'/>`
        + `<polygon points='50,30 53,39 62,39 55,45 57,54 50,48 43,54 45,45 38,39 47,39' fill='${hi}' opacity='.7'/>`
        + `<circle cx='50' cy='60' r='2' fill='${hi}'/>`
        + spark(50, 20, 3.6, hi, .8) + spark(72, 62, 3, accent, .8) + spark(28, 62, 3, accent, .8))
  }
}
let CS2_UID = 0
function hexRgba(hex, alpha) {
  const h = String(hex || "").replace("#", "")
  const full = h.length === 3 ? h.split("").map(c => c + c).join("") : h.padEnd(6, "0").slice(0, 6)
  const n = parseInt(full, 16) || 0
  return `rgba(${(n >> 16) & 255},${(n >> 8) & 255},${n & 255},${alpha})`
}
function cs2Frac(a, unlocked) {
  if (unlocked) return 1
  const need = num(a && a.target)
  if (!need) return 0
  return Math.max(0, Math.min(1, num(a && a.val) / need))
}
function cs2Medal(a, unlocked, size) {
  const s = num(size) || 64
  const id = cs2Canon(a)
  const lv = cs2MedalLevel(a)
  const acc = (a && a.accent) || lv[0]
  const frac = cs2Frac(a, unlocked)
  const full = frac >= 1
  const uid = "cs2c" + (++CS2_UID)
  const rivets = (band, bandHi) =>
    `<circle cx='71.2' cy='28.8' r='3' fill='${band}' stroke='${bandHi}' stroke-width='1'/>`
    + `<circle cx='28.8' cy='28.8' r='3' fill='${band}' stroke='${bandHi}' stroke-width='1'/>`
    + `<circle cx='28.8' cy='71.2' r='3' fill='${band}' stroke='${bandHi}' stroke-width='1'/>`
    + `<circle cx='71.2' cy='71.2' r='3' fill='${band}' stroke='${bandHi}' stroke-width='1'/>`
  const coin = (star, band, bandHi, disc, lvlName, glowCol, isFull) => {
    const gid = `${uid}e`, mid = `${uid}m`, fid = `${uid}g`, cid = `${uid}s`
    const laurels = lvlName === "MAX"
      ? `<g fill='${bandHi}' opacity='.9'>`
        + [0, 1, 2, 3].map(k => `<ellipse cx='${34 - k * 4}' cy='${76 + k * 3}' rx='4.6' ry='2.4' transform='rotate(${-38 + k * 12} ${34 - k * 4} ${76 + k * 3})'/><ellipse cx='${66 + k * 4}' cy='${76 + k * 3}' rx='4.6' ry='2.4' transform='rotate(${38 - k * 12} ${66 + k * 4} ${76 + k * 3})'/>`).join("")
        + `<circle cx='50' cy='89' r='2.6' fill='${star}'/></g>`
      : ""
    const ribbon = (lvlName === "MAX" || lvlName === "6")
      ? `<polygon points='32,80 68,80 63,90 50,86 37,90' fill='${band}' stroke='${bandHi}' stroke-width='1.6'/><circle cx='50' cy='83.5' r='2.4' fill='${bandHi}'/>`
      : ""
    const halo = isFull
      ? `<circle cx='50' cy='50' r='47' fill='none' stroke='${glowCol}' stroke-width='7' opacity='.5' filter='url(#${fid})'/>`
      : ""
    return `<defs>`
      + `<radialGradient id='${gid}' cx='50%' cy='34%' r='72%'><stop offset='0%' stop-color='#232f3d'/><stop offset='55%' stop-color='${disc}'/><stop offset='100%' stop-color='#05080d'/></radialGradient>`
      + `<linearGradient id='${mid}' x1='0' y1='0' x2='1' y2='1'><stop offset='0%' stop-color='${bandHi}'/><stop offset='45%' stop-color='${band}'/><stop offset='100%' stop-color='${bandHi}'/></linearGradient>`
      + `<filter id='${fid}' x='-40%' y='-40%' width='180%' height='180%'><feGaussianBlur stdDeviation='3.2' result='b'/><feMerge><feMergeNode in='b'/><feMergeNode in='SourceGraphic'/></feMerge></filter>`
      + `<clipPath id='${cid}'><circle cx='50' cy='50' r='37'/></clipPath>`
      + `</defs>`
      + halo
      + `<circle cx='50' cy='50' r='45' fill='url(#${gid})' stroke='url(#${mid})' stroke-width='6'/>`
      + `<circle cx='50' cy='50' r='38.5' fill='none' stroke='${bandHi}' stroke-width='1.4' opacity='.8'/>`
      + `<circle cx='50' cy='50' r='34' fill='none' stroke='${bandHi}' stroke-width='1.2' stroke-dasharray='4 2' opacity='.7'/>`
      + `<g clip-path='url(#${cid})'><ellipse cx='36' cy='28' rx='22' ry='10' fill='#ffffff' opacity='.13' transform='rotate(-24 36 28)'/></g>`
      + rivets(band, bandHi)
      + `<g clip-path='url(#${cid})'>${cs2Emblem(id, star, bandHi)}</g>`
      + ribbon + laurels
  }
  const glow = full ? `box-shadow:0 0 ${Math.round(s / 5)}px ${lv[0]};` : (frac > 0 ? `box-shadow:0 0 ${Math.round(s / 8)}px ${hexRgba(lv[0], 0.4)};` : "")
  // Base: grey locked coin. Overlay: full color clipped rising from the
  // bottom by progress fraction -> the medal "colors in" as you grind.
  const lvlName = lv[1]
  const base = full
    ? coin(acc, "#c9a227", "#f5d76e", cs2Disc(id), lvlName, acc, true)
    : coin("#3a4652", "#2a343c", "#46525e", "#0a0e14", lvlName, "#000000", false)
  const y = (100 * (1 - frac)).toFixed(1)
  const overlay = (!full && frac > 0)
    ? `<defs><clipPath id='${uid}'><rect x='0' y='${y}' width='100' height='100'/></clipPath></defs>`
      + `<g clip-path='url(#${uid})'>${coin(acc, "#c9a227", "#f5d76e", cs2Disc(id), lvlName, acc, false)}</g>`
    : ""
  return `<span class='cs2-medal' data-e='${id}' data-p='${Math.round(frac * 100)}' style='display:inline-block;width:${s}px;height:${s}px;border-radius:50%;${glow}vertical-align:top;'><svg width='${s}' height='${s}' viewBox='0 0 100 100'>${base}${overlay}</svg></span>`
}
function skillArt(s) {
  const id = String((s && s.id) || "").replace(/[^a-z0-9_]/gi, "")
  return SKILL_ART[id] || "/bp/star.png"
}
function emblemBox(name, faded, rankId, size) {
  const src = rankId ? rankSrc(rankId) : "/ranks/rank_01.png"
  const cls = faded ? "rank-img faded" : (size === "lg" ? "rank-img-lg" : "rank-img")
  const n = String(Math.min(Math.max(num(rankId) || 1, 1), 19)).padStart(2, "0")
  const wrap = [
    "rank-anim",
    "rank-a-" + n,
    size === "lg" ? "rank-anim-lg" : "",
    faded ? "faded" : ""
  ].filter(Boolean).join(" ")
  const wh = size === "lg" ? 148 : 56
  return `<span class='${wrap}'><img class='${cls}' src='${src}' width='${wh}' height='${wh}' alt='${esc(name || "")}'></span>`
}
function medalSrc(itemOrIdx) {
  if (itemOrIdx && (itemOrIdx.id || itemOrIdx.art)) return achArt(itemOrIdx)
  return "/medals/fn_badge_01.png"
}
const GUN_ICONS = [
  "ak47", "m4a1", "awp", "deagle", "knife", "usp", "glock",
  "famas", "galil", "scout", "aug", "sg552", "mp5", "p90", "ump",
  "mac10", "tmp", "m249", "m3", "xm1014", "sg550", "g3sg1", "he"
]
const GUN_PIXEL = [
  "wpn_011", "wpn_012", "cmb_034", "wpn_023", "wpn_031", "wpn_021", "wpn_022",
  "wpn_013", "wpn_014", "wpn_018", "wpn_015", "wpn_016", "wpn_017", "wpn_026", "wpn_027",
  "wpn_025", "wpn_025", "wpn_019", "wpn_020", "wpn_028", "cmb_025", "cmb_034", "wpn_035"
]
function gunIcon(slot, faded) {
  const key = GUN_ICONS[num(slot)] || "ak47"
  const src = `/i/gun_${key}.png`
  const cls = faded ? "gun-img faded" : "gun-img"
  return `<img class='${cls}' src='${src}' width='56' height='56' alt=''>`
}
function medalImg(item, faded, size) {
  const dim = faded || (item && !item.unlocked)
  const cls = dim ? "medal-img faded" : "medal-img"
  const mid = item && item.id ? String(item.id).replace(/[^a-z0-9_]/gi, "") : "generic"
  const wrap = ["medal-anim", "medal-" + mid, dim ? "faded" : ""].filter(Boolean).join(" ")
  const wh = size === "sm" ? 48 : 72
  // Browser: the dark service-coin badges (approved look); compact MOTD
  // keeps the lightweight PNG (GoldSrc cannot do inline SVG).
  const inner = (!isMotdCompact() && item && item.id)
    ? cs2Medal(item, !dim, wh)
    : `<img class='${cls}' src='${(item && item.art) ? item.art : medalSrc(item)}' width='${wh}' height='${wh}' alt='${esc((item && item.title) || "medal")}'>`
  return `<span class='${wrap}'>${inner}</span>`
}
function tipCard(item) {
  const pctDone = item.target ? Math.min(100, Math.round((item.val / item.target) * 100)) : 0
  return `<span class='tip'>
    ${medalImg(item, !item.unlocked)}
    <span class='tipc'>
      <div class='tt'>${esc(item.title)}</div>
      ${item.rarity ? `<div class='tr'>${esc(item.rarity)} ${esc(item.type || "")}</div>` : ""}
      <div class='td'>${esc(item.desc)}</div>
      <div class='td' style='margin-top:8px;'>Requirement: <b style='color:#fff'>${fmt(item.target)}</b></div>
      <div class='td'>Progress: <b style='color:#fff'>${item.tracked === false ? "Tracked in-game" : `${fmt(item.val)} / ${fmt(item.target)} (${pctDone}%)`}</b></div>
      ${item.note ? `<div class='td'>${esc(item.note)}</div>` : ""}
      <div class='td' style='margin-top:6px;'>${item.unlocked ? "<span class='green'>UNLOCKED — display only</span>" : "<span class='muted'>IN PROGRESS</span>"}</div>
    </span>
  </span>`
}

// External shop URL removed — VIP is granted in-game only (/vip · /help).

async function recentPlayersHtml(env, slug) {
  let rows = []
  try {
    rows = ((await env.DB.prepare(
      `SELECT steamid, name, level FROM players ORDER BY last_seen DESC LIMIT 8`
    ).all()).results || [])
  } catch { rows = [] }
  if (!rows.length) return ""
  return `<div class='card'><div class='h2'>RECENT PLAYERS</div>
    <table width='100%' cellspacing='0' cellpadding='6' border='0'>${rows.map(r =>
      `<tr><td><a href='/${slug}?steamid=${encodeURIComponent(r.steamid || "")}'>${esc(r.name || r.steamid || "?")}</a></td><td align='right'><span class='muted small'>L${fmt(r.level)}</span></td></tr>`
    ).join("")}</table></div>`
}

export async function pageProfile(env, url) {
  const steamid = steamidOf(url)
  const compactMode = isMotdCompact() || compact(url) === "1"
  if (!steamid) return needSteamid("PROFILE", "profile", "/profile", await recentPlayersHtml(env, "profile"))
  let p
  try { p = await env.DB.prepare(`SELECT * FROM players WHERE steamid = ?1`).bind(steamid).first() }
  catch { return errorState("PROFILE", "profile", "player data") }
  if (!p) return notFound("PROFILE", "profile", "This SteamID has no snapshot yet. Play a few minutes in game, then retry.")

  const now = Math.floor(Date.now() / 1000)
  const rp = rankProgress(p.xp, p.rank_id)

  const earnedMap = await apUnlocksMap(env, steamid)
  const show = badgeCabinet(p, earnedMap)
  const online = isOnline(p.last_seen, now)
  const titleName = (COSMETICS.title && COSMETICS.title[p.eq_title]) || ""
  const activeTitle = (titleName && titleName !== "None") ? titleName : (p.custom_tag || "")
  const vipLabel = vipName(p.vip_tier)

  const token = await pageActionToken(env, url, steamid)
  const ownedIds = show.items.filter(i => i.unlocked).map(i => i.id)
  const featureCsv = url.searchParams.get("feature") || url.searchParams.getAll("ids").join(",")
  if (featureCsv && steamid && token) {
    await saveFeatured(env, steamid, featureCsv, token, ownedIds)
  }
  let featuredCsv = ""
  try {
    const pref = await env.DB.prepare(`SELECT featured FROM player_profile WHERE steamid = ?1`).bind(steamid).first()
    featuredCsv = pref && pref.featured ? String(pref.featured) : ""
  } catch {}
  const featuredIds = featuredCsv.split(",").map(s => s.trim()).filter(Boolean)
  const picked = featuredIds.map(id => show.items.find(i => i.id === id && i.unlocked)).filter(Boolean).slice(0, 5)
  const badgesList = picked.length ? picked : show.featured

  // RSU rankstats column 3: top-5 favorite weapons, plain names + kills
  // (no mastery tiers — those live on the Missions/Skills side).
  let topGuns = []
  try {
    topGuns = ((await env.DB.prepare(
      `SELECT slot, kills, hs, damage FROM player_weapons WHERE steamid = ?1 ORDER BY kills DESC LIMIT 5`
    ).bind(steamid).all()).results || []).filter(w => num(w.kills) > 0)
  } catch {}
  const topGunsHtml = topGuns.length ? `<div class='card'><div class='h2'>TOP WEAPONS</div>
    <table class='t' width='100%' cellspacing='0' cellpadding='6' border='0'>${topGuns.map((w, i) =>
      `<tr><td class='k'>#${i + 1}</td><td><b>${esc(WEAPONS[w.slot] || ("Slot " + w.slot))}</b></td><td class='v'>${fmt(w.kills)} kills</td></tr>`
    ).join("")}</table></div>` : ""
  const unlockedMedals = show.items.filter(i => i.unlocked)
  // MOTD compact: glyph cells (same medalGlyph/medalColor treatment as the
  // achievements cabinet) instead of 3KB inline-SVG coins GoldSrc cannot
  // render — same titles, rarity and count, ~90% fewer bytes. Browser keeps
  // the service-coin badges verbatim.
  const medalsHtml = compactMode
    ? `<div class='h2'>MEDALS &amp; TROPHIES</div>` + (unlockedMedals.length
      ? `<div class='card'><div class='muted small' style='text-align:center;'>${fmt(show.earnedAP)} AP earned of ${fmt(show.totalAP)} &#183; ${unlockedMedals.length}/${show.items.length} medals &#183; sorted by rarity</div>` + medalTable(unlockedMedals, (it) =>
        `<font color='${medalColor(it)}' size='+3'>${medalGlyph(it)}</font><br><b>${esc(it.title || "")}</b><br>${rarityBadge(it.rarity || "common")}`) + `</div>`
      : `<table width='100%' cellspacing='8' cellpadding='0' border='0'><tr><td class='tile'><div class='muted small' style='text-align:center;'>No medals earned yet — achievements unlock automatically in-game.</div></td></tr></table>`)
    : `<div class='h2'>MEDALS &amp; TROPHIES</div>` + (unlockedMedals.length
    ? `<div class='card'><div class='muted small' style='text-align:center;'>${fmt(show.earnedAP)} AP earned of ${fmt(show.totalAP)} &#183; ${unlockedMedals.length}/${show.items.length} medals &#183; sorted by rarity</div>` + medalTable(unlockedMedals, (it) =>
      `${cs2Medal(it, true, 48)}<br><b>${esc(it.title || "")}</b><br>${rarityBadge(it.rarity || "common")}<br><span class='muted small'>${esc(fmtEarned(it.earned_at))}</span>`) + `</div>`
    : `<table width='100%' cellspacing='8' cellpadding='0' border='0'><tr><td class='tile'><div class='muted small' style='text-align:center;'>No medals earned yet — achievements unlock automatically in-game.</div></td></tr></table>`)
  const editorRows = show.items.filter(i => i.unlocked).map(m => {
    const isF = featuredIds.includes(m.id)
    const next = isF ? featuredIds.filter(id => id !== m.id) : [...featuredIds, m.id].slice(0, 5)
    const href = `/profile?steamid=${encodeURIComponent(steamid)}&feature=${encodeURIComponent(next.join(","))}&t=${token}`
    return `<tr><td width='40' align='center' valign='middle'>${cs2Medal(m, true, 32)}</td><td valign='middle'><b>${esc(m.title)}</b> ${rarityBadge(m.rarity || "common")}<br><span class='muted small'>${esc(m.type || "BADGE")} · ${fmt(m.ap)} AP · ${esc(fmtEarned(m.earned_at))}</span></td><td width='90' align='right' valign='middle'>${isF ? `<span class='badge done'>★</span> <a href='${href}'>remove</a>` : `<a href='${href}'>☆ feature</a>`}</td></tr>`
  }).join("")
  const editorHtml = (!compactMode && token && show.items.some(i => i.unlocked))
    ? `<div class='h2'>SHOWCASE EDITOR</div><div class='card'><div class='muted small' style='text-align:center;'>Pick up to 5 badges \u00b7 browser only (links too long for in-game MOTD).</div><table width='100%' cellspacing='0' cellpadding='6' border='0'>${editorRows}</table></div>`
    : ""

  let track = null
  try {
    const cat = await env.DB.prepare(`SELECT json FROM catalog WHERE key = 'reward_track'`).first()
    if (cat && cat.json) track = JSON.parse(cat.json)
  } catch { track = null }
  if (!track || !track.tiers || !track.tiers.length) track = DEFAULT_REWARD_TRACK
  let pushAgo = ""
  try {
    const m = await env.DB.prepare(`SELECT value FROM meta WHERE key = 'last_push'`).first()
    if (m && m.value) pushAgo = ago(now - num(m.value))
  } catch { pushAgo = "" }
  const freshNote = pushAgo ? `Updated ${pushAgo} \u00b7 snapshots every ~30s` : "snapshots every ~30s - stats lag the live server by one push"
  const bpNeed = Math.max(1, num(track.xp_per_tier) || 1000)
  const xp = Math.max(0, num(p.xp))
  const bpLevel = bpTierOf(p, bpNeed)
  const bpPremium = num(p.vip_tier) > 0
  const bpReward = (() => {
    const tiers = Array.isArray(track.tiers) ? track.tiers : []
    const reached = tiers.filter(t => num(t.tier) <= Math.max(1, bpLevel))
    const pick = reached.length ? reached[reached.length - 1] : null
    if (!pick) return "No tier claimed yet"
    return bpPremium ? (pick.premium || pick.name || pick.free) : (pick.free || pick.name)
  })()

  const featuredSlots = [0, 1, 2, 3, 4].map(i => badgesList[i] || null)
  const featuredHtml = featuredSlots.map(b => b
    ? `<div class='csgo-medal-slot'>${tipCard(b)}</div>`
    : `<div class='csgo-medal-slot empty'></div>`
  ).join("")

  const hsPct = pct(p.headshots || 0, p.kills || 0)
  const winPct = pct(p.wins || 0, num(p.wins) + num(p.losses))

  const featuredCount = badgesList.length
  const showcaseNote = featuredCount ? "" : `<div class='muted small' style='text-align:center;'>No badges showcased yet \u2014 earn achievements in-game.</div>`
  // MOTD compact: one-line glyph strip with visible titles. The browser
  // slots show titles only via hover (.tipc), which MOTD has no pointer for,
  // so compact prints them inline instead of shipping hidden hover bytes.
  const showcaseHtml = compactMode
    ? `<div class='h2'>FEATURED SHOWCASE</div><div class='card'><div class='muted small' style='text-align:center;'>` +
      (badgesList.length
        ? badgesList.map(b => `<font color='${medalColor(b)}' size='+2'>${medalGlyph(b)}</font> <b>${esc(b.title || "")}</b>`).join(" &nbsp;&#183;&nbsp; ")
        : `No badges showcased yet \u2014 earn achievements in-game.`) + `</div></div>`
    : `<div class='h2'>FEATURED SHOWCASE</div>
  <table width='100%' cellspacing='8' cellpadding='0' border='0'><tr><td class='tile' colspan='2'><div style='text-align:center;'>` + featuredSlots.join("") + `</div>` + showcaseNote + `</td></tr></table>`
  const motdOverview = motdProfileOverview({
    p, steamid, rp, online, vipLabel, activeTitle, show, bpLevel, bpPremium, bpReward,
    hsPct, winPct, xp, bpNeed, topGunsHtml, medalsHtml, showcaseHtml, freshNote
  })

  // Compact MOTD keeps the identity/overview block only. The overview tiles
  // carry every stat exactly once, so there are no repeat cards.
  // from= (emitted by Top15 row links) renders a relative-only back link.
  const fromRaw = String(url.searchParams.get("from") || "")
  const fromOk = fromRaw.startsWith("/") && !fromRaw.startsWith("//") && !/[<>"']/.test(fromRaw)
  const backLink = fromOk ? `<p class='muted small'><a href='${esc(fromRaw)}'>&#8249; back</a></p>` : ""
  const body = `${backLink}${motdOverview}${editorHtml}`

  return html("PROFILE", body, { steamid, product: "profile", compact: compactMode })
}

function metricGrid(rows) {
  let out = `<table width='100%' cellspacing='8' cellpadding='0' border='0'><tr>`
  rows.forEach(([k, v], i) => {
    if (i % 2 === 0 && i > 0) out += `</tr><tr>`
    out += `<td class='tile' width='50%'><div class='statk'>${esc(k)}</div><div class='statv'>${v}</div></td>`
  })
  if (rows.length % 2) out += `<td width='50%'></td>`
  return out + `</tr></table>`
}

function motdProfileOverview({ p, steamid, rp, online, vipLabel, activeTitle, show, bpLevel, bpPremium, bpReward, hsPct, winPct, xp, bpNeed, topGunsHtml, medalsHtml, showcaseHtml, freshNote }) {
  const rankPng = rankSrc(p.rank_id)
  const statusDot = online ? "#3dff9e" : "#3f5f57"
  return `
  <table class='card' width='100%' cellspacing='0' cellpadding='8' border='0' bgcolor='#0D0F0E'>
    <tr>
      <td width='72' valign='top'><img src='${rankPng}' width='64' height='64' alt='${esc(rp.curName)}' border='0'></td>
      <td valign='top'>
        <b style='color:#ffffff;font-size:20px;'>${flagImg(p.cc)}${esc(p.name)}</b>
        ${num(p.vip_tier) > 0 ? ` <span class='badge done'>${esc(vipLabel)}</span>` : ""}
        ${activeTitle ? `<br><span style='color:#e8c547;'>${esc(activeTitle)}</span>` : ""}
        <br><span style='color:${statusDot};'>\u25cf</span> <b style='color:${statusDot};'>${online ? "ONLINE" : "OFFLINE"}</b>
        &nbsp;<span class='muted'>${esc(steamid)}</span>
        <br><span class='chip'>${esc(rp.curName)}<b>L${fmt(p.level)}</b></span> <span class='muted small'>${freshNote || "snapshots every ~30s - stats lag the live server by one push"}</span>
        <span class='chip'>${fmt(show.earnedAP)}<b>AP</b></span>
        <span class='chip'>BP ${fmt(bpLevel)}<b>${bpPremium ? "PREMIUM" : "FREE"}</b></span>
      </td>
    </tr>
  </table>
  ${showcaseHtml || ""}
  <div class='h2'>PROGRESSION</div>
  <table width='100%' cellspacing='8' cellpadding='0' border='0'>
    <tr><td class='tile' colspan='2'><div class='statk'>XP \u2014 ${esc(rp.nextName || "next rank")} ${fmt(rp.nextReq || p.xp)}</div><div class='statv'>${fmt(p.xp)} / ${fmt(rp.nextReq || p.xp)} (${rp.progressPct}%)</div><div class='bar'><div style='width:${rp.progressPct}%'></div></div></td></tr>
    <tr>
      <td class='tile' width='50%'><div class='statk'>Rating</div><div class='statv'>${ratingStr(p.rating_x100)} <span class='muted' style='font-size:13px;'>${esc(skillName(p.rating_x100))}</span></div></td>
      <td class='tile' width='50%'><div class='statk'>Playtime</div><div class='statv'>${fmt(p.playtime_minutes)} min</div></td>
    </tr>
    <tr><td class='tile' colspan='2'><div class='statk'>Battle Pass</div><div class='statv' style='font-size:15px;'>Tier ${fmt(Math.max(1, bpLevel))} \u00b7 ${bpPremium ? "PREMIUM" : "FREE"} \u00b7 ${esc(bpReward)}</div></td></tr>
  </table>
  <div class='h2'>COMBAT</div>
  <table width='100%' cellspacing='8' cellpadding='0' border='0'>
    <tr>
      <td class='tile' width='50%'><div class='statk'>Kills / Deaths / HS%</div><div class='statv'>${fmt(p.kills)} / ${fmt(p.deaths)} / ${hsPct}%</div></td>
      <td class='tile' width='50%'><div class='statk'>K/D \u00b7 MVPs</div><div class='statv'>${kdStr(p.kills, p.deaths)} \u00b7 ${fmt(p.mvps)}</div></td>
    </tr>
    <tr>
      <td class='tile' width='50%'><div class='statk'>Headshots</div><div class='statv'>${fmt(p.headshots)}</div></td>
      <td class='tile' width='50%'><div class='statk'>Damage</div><div class='statv'>${fmt(p.damage)}</div></td>
    </tr>
    <tr>
      <td class='tile' width='50%'><div class='statk'>Accuracy</div><div class='statv'>${pct(p.hits, p.shots)}%</div></td>
      <td class='tile' width='50%'><div class='statk'>Assists</div><div class='statv'>${fmt(p.assists)}</div></td>
    </tr>
    <tr>
      <td class='tile' width='50%'><div class='statk'>Record (W / L)</div><div class='statv'>${fmt(p.wins)} / ${fmt(p.losses)}</div></td>
      <td class='tile' width='50%'><div class='statk'>Win %</div><div class='statv'>${winPct}%</div></td>
    </tr>
  </table>
  <div class='h2'>WALLET &amp; STYLE</div>
  <table width='100%' cellspacing='8' cellpadding='0' border='0'>
    <tr>
      <td class='tile' width='50%'><div class='statk'>Coins</div><div class='statv' style='color:#e8c547;'>${fmt(p.coins)}</div></td>
      <td class='tile' width='50%'><div class='statk'>Model</div><div class='statv' style='font-size:15px;'>${esc(p.eq_model || "default")}</div></td>
    </tr>
  </table>
  ${topGunsHtml}
  ${medalsHtml}
  `
}

function digitAt(packed, slot) {
  const n = num(packed)
  return Math.floor(n / Math.pow(10, slot)) % 10
}

function parseTargets(p) {
  const raw = String(p.msn_tg || "")
  const parts = raw.split("|")
  const daily = (parts[0] || "").split(",").map(n => num(n))
  const bonus = (parts[1] || "").split(",").map(n => num(n))
  const weekly = (parts[2] || "").split(",").map(n => num(n))
  const vip = num((parts[3] || "").split(",")[0])
  return { daily, bonus, weekly, vip }
}

function missionGroups(p) {
  const tg = parseTargets(p)
  const daily = [
    { title: "FRAG HUNTER", desc: `Get ${tg.daily[0] || 15} ranked kills`, val: p.bp_daily_kills, target: tg.daily[0] || 15, reward: "Daily AND-set", kind: "daily", icon: "/missions/msn_01.png", remaining: "Resets midnight server time", counts: "Ranked kills today. All 5 daily tasks grant +500 XP together.", group: 0, slot: 0, status: digitAt(p.msn_st_d, 0) },
    { title: "HEAD HUNTER", desc: `Get ${tg.daily[1] || 3} headshots`, val: p.bp_daily_hs, target: tg.daily[1] || 3, reward: "Daily AND-set", kind: "daily", icon: "/missions/msn_02.png", remaining: "Resets midnight server time", counts: "Headshot kills today.", group: 0, slot: 1, status: digitAt(p.msn_st_d, 1) },
    { title: "BOMB SQUAD", desc: `Plant the bomb ${tg.daily[2] || 2} times`, val: p.bp_daily_plants, target: tg.daily[2] || 2, reward: "Daily AND-set", kind: "daily", icon: "/missions/msn_03.png", remaining: "Resets midnight server time", counts: "Successful C4 plants today.", group: 0, slot: 2, status: digitAt(p.msn_st_d, 2) },
    { title: "DEFUSER", desc: `Defuse the bomb ${tg.daily[3] || 1} time`, val: p.bp_daily_defuses, target: tg.daily[3] || 1, reward: "Daily AND-set", kind: "daily", icon: "/missions/msn_04.png", remaining: "Resets midnight server time", counts: "Successful C4 defuses today.", group: 0, slot: 3, status: digitAt(p.msn_st_d, 3) },
    { title: "WINNER", desc: `Win ${tg.daily[4] || 2} rounds`, val: p.bp_daily_wins, target: tg.daily[4] || 2, reward: "+500 XP when all 5 claimed", kind: "daily", icon: "/missions/msn_05.png", remaining: "Resets midnight server time", counts: "Rounds won as T or CT today.", group: 0, slot: 4, status: digitAt(p.msn_st_d, 4) }
  ]
  const bonus = [
    { title: "STREAK", desc: `Reach a ${tg.bonus[0] || 5}-kill streak`, val: p.bp_daily_streak, target: tg.bonus[0] || 5, reward: "+150 Coins", kind: "bonus", icon: "/missions/msn_06.png", remaining: "Resets midnight server time", counts: "Highest consecutive kills without dying today.", group: 1, slot: 0, status: digitAt(p.msn_st_b, 0) },
    { title: "DAMAGE", desc: `Deal ${tg.bonus[1] || 500} damage`, val: p.bp_daily_damage, target: tg.bonus[1] || 500, reward: "+100 Coins", kind: "bonus", icon: "/missions/msn_07.png", remaining: "Resets midnight server time", counts: "Damage dealt to enemies today.", group: 1, slot: 1, status: digitAt(p.msn_st_b, 1) },
    { title: "SURVIVOR", desc: `Survive ${tg.bonus[2] || 3} rounds`, val: p.bp_daily_survives, target: tg.bonus[2] || 3, reward: "+100 Coins", kind: "bonus", icon: "/missions/msn_08.png", remaining: "Resets midnight server time", counts: "Rounds survived without dying today.", group: 1, slot: 2, status: digitAt(p.msn_st_b, 2) }
  ]
  if (num(p.vip_tier) >= 1) {
    bonus.push({ title: "VIP EXTRA", desc: `Get ${tg.vip || 20} extra kills`, val: p.msn_vip_p, target: tg.vip || 20, reward: "+150 Coins", kind: "bonus", icon: "/missions/msn_20.png", remaining: "VIP extra daily", counts: "Optional VIP extra slot. Core 5 stay free.", group: 3, slot: 0, status: num(p.msn_st_v) })
  }
  const weekly = [
    { title: "WEEKLY FRAGS", desc: `Get ${tg.weekly[0] || 100} weekly kills`, val: p.bp_weekly_kills, target: tg.weekly[0] || 100, reward: "Weekly AND-set", kind: "weekly", icon: "/missions/msn_09.png", remaining: "Resets ISO week (%G-%V)", counts: "Ranked kills this ISO week.", group: 2, slot: 0, status: digitAt(p.msn_st_w, 0) },
    { title: "WEEKLY HEAD HUNTER", desc: `Get ${tg.weekly[1] || 25} weekly headshots`, val: p.bp_weekly_hs, target: tg.weekly[1] || 25, reward: "Weekly AND-set", kind: "weekly", icon: "/missions/msn_10.png", remaining: "Resets ISO week (%G-%V)", counts: "Headshot kills this ISO week.", group: 2, slot: 1, status: digitAt(p.msn_st_w, 1) },
    { title: "PLANTER", desc: `Plant the bomb ${tg.weekly[2] || 10} times`, val: p.bp_weekly_plants, target: tg.weekly[2] || 10, reward: "Weekly AND-set", kind: "weekly", icon: "/missions/msn_11.png", remaining: "Resets ISO week (%G-%V)", counts: "C4 plants this ISO week.", group: 2, slot: 2, status: digitAt(p.msn_st_w, 2) },
    { title: "MATCH WINNER", desc: `Win ${tg.weekly[3] || 15} rounds`, val: p.bp_weekly_wins, target: tg.weekly[3] || 15, reward: "+5000 XP + 1000c when all 4 claimed", kind: "weekly", icon: "/missions/msn_12.png", remaining: "Resets ISO week (%G-%V)", counts: "Round wins this ISO week.", group: 2, slot: 3, status: digitAt(p.msn_st_w, 3) }
  ]
  const seasonal = [
    { title: "SEASON FRAGS", desc: "Competitive kills this season", val: p.comp_kills, target: Math.max(1, num(p.comp_kills)), reward: "Tracker", kind: "seasonal", icon: "/missions/msn_13.png", remaining: "Season window", tracker: true, counts: "fncomp season kill counter. Not a paid contract." },
    { title: "SEASON WINS", desc: "Competitive round wins this season", val: p.comp_wins, target: Math.max(1, num(p.comp_wins)), reward: "Tracker", kind: "seasonal", icon: "/missions/msn_14.png", remaining: "Season window", tracker: true, counts: "fncomp season round wins. Not a paid contract." },
    { title: "SEASON MVP", desc: "Competitive MVPs this season", val: p.comp_mvp, target: Math.max(1, num(p.comp_mvp)), reward: "Tracker", kind: "seasonal", icon: "/missions/msn_15.png", remaining: "Season window", tracker: true, counts: "fncomp season MVP awards. Not a paid contract." }
  ]
  const special = [
    { title: "RIFLEMAN", desc: "25 competitive kills", val: p.comp_msn_k, target: 25, reward: "+120 pts", kind: "special", icon: "/missions/msn_16.png", remaining: "Resets midnight server time", forced: p.comp_msn_done & 1, counts: "Competitive daily kills." },
    { title: "SHARPSHOOTER", desc: "20 competitive headshots", val: p.comp_msn_h, target: 20, reward: "+130 pts", kind: "special", icon: "/missions/msn_17.png", remaining: "Resets midnight server time", forced: p.comp_msn_done & 2, counts: "Competitive daily headshots." },
    { title: "WINNER", desc: "10 competitive round wins", val: p.comp_msn_w, target: 10, reward: "+100 pts", kind: "special", icon: "/missions/msn_18.png", remaining: "Resets midnight server time", forced: p.comp_msn_done & 4, counts: "Competitive daily round wins." },
    { title: "MVP", desc: "3 competitive MVP awards", val: p.comp_msn_m, target: 3, reward: "+150 pts", kind: "special", icon: "/missions/msn_19.png", remaining: "Resets midnight server time", forced: p.comp_msn_done & 8, counts: "Competitive daily MVPs." }
  ]
  const version = (list) => list.map(m => ({
    ...m,
    icon: `${m.icon || "/missions/msn_01.png"}${String(m.icon || "").includes("?") ? "&" : "?"}v=4`
  }))
  return {
    daily: version(daily),
    bonus: version(bonus),
    weekly: version(weekly),
    seasonal: version(seasonal),
    special: version(special)
  }
}

function missionDone(m) {
  if (m.tracker) return false
  if (m.forced != null) return !!m.forced
  if (num(m.status) >= 1) return true
  return num(m.val) >= num(m.target)
}

function compactMissionRail(p) {
  const g = missionGroups(p)
  function rows(list) {
    return list.map(m => {
      const have = num(m.val)
      const need = num(m.target) || 1
      const done = missionDone(m)
      const bar = pct(have, need)
      const ink = done ? "#36DEAB" : (m.kind === "weekly" ? "#c084fc" : "#fbbf24")
      return `<table width='100%' cellspacing='0' cellpadding='4' border='0' bgcolor='#0D0F0E'>
        <tr><td><b><font color='${ink}' size='2'>${esc(m.desc || m.title)}</font></b></td></tr>
        <tr><td bgcolor='#16352C'><div style='width:${bar}%;background:${ink};height:6px;'></div></td></tr>
        <tr>
          <td><font color='#B7C1BC' size='1'>${fmt(Math.min(have, need))} / ${fmt(need)}</font>
          <font color='${ink}' size='1'> ${esc(m.reward)}</font>
          ${done ? "<font color='#36DEAB' size='1'> ✓</font>" : ""}</td>
        </tr>
      </table>`
    }).join("")
  }
  return `<div class='card'><div class='h2'>DAILY MISSIONS</div>${rows(g.daily)}</div>
  <div class='card'><div class='h2'>BONUS DAILIES</div>${rows(g.bonus)}</div>
  <div class='card'><div class='h2'>WEEKLY MISSIONS</div>${rows(g.weekly)}</div>`
}

function missionStatus(m) {
  if (m.tracker) return "TRACKER"
  const st = num(m.status)
  if (st === 2) return "CLAIMED"
  if (st === 1) return "CLAIMABLE"
  if (m.forced != null) return m.forced ? "CLAIMED" : "IN PROGRESS"
  // Progress met locally but the game has not flagged it claimable yet
  // (snapshot lag) — never display CLAIMED here; the CLAIM button appears
  // only once the game reports status 1.
  return num(m.val) >= num(m.target) ? "READY" : "IN PROGRESS"
}

// Generic esports glyphs per objective type (inline SVG, stroke-only).
// Browser pages only; compact MOTD keeps its text rail.
function msnGlyph(m) {
  const s = String((m && m.title) + " " + (m && m.desc)).toUpperCase()
  const S = (inner) => `<svg width='44' height='44' viewBox='0 0 44 44' fill='none' stroke='#3dff9e' stroke-width='2.4' stroke-linecap='round' stroke-linejoin='round'>${inner}</svg>`
  if (/HEAD|PRECISION|SHARPSHOOTER|TARGET/.test(s)) return S("<circle cx='22' cy='22' r='12'/><circle cx='22' cy='22' r='5'/><path d='M22 2v6M22 36v6M2 22h6M36 22h6'/>")
  if (/PLANT|BOMB|GRENAD|C4/.test(s)) return S("<rect x='14' y='16' width='16' height='18'/><path d='M22 16c0-5 3-7 7-8M17 34h10'/>")
  if (/DEFUS|SURVIV/.test(s)) return S("<path d='M22 5l12 5v10c0 9-5 15-12 19-7-4-12-10-12-19V10z'/><path d='M17 20l4 4 7-8'/>")
  if (/WIN|VICTORY|MATCH/.test(s)) return S("<path d='M14 6h16v10c0 6-3 10-8 12-5-2-8-6-8-12z'/><path d='M14 9H8v3c0 4 3 7 7 7M30 9h6v3c0 4-3 7-7 7M19 28v5M14 38h16'/>")
  if (/STREAK|FLAME|FIRE/.test(s)) return S("<path d='M22 4c4 8 10 12 10 21a10 10 0 0 1-20 0c0-4 2-7 4-9 0 4 2 6 4 7-.5-6 0-13 2-19z'/>")
  if (/DAMAGE|BURST|BLAST/.test(s)) return S("<path d='M22 4l3 8 8-2-2 8 9 1-7 5 3 8-8-3-5 7-5-7-8 3 3-8-7-5 9-1-2-8 8 2z'/>")
  if (/MVP|MEDAL|CROWN|VIP|CHAMP/.test(s)) return S("<path d='M10 30l-2-14 8 5 6-9 6 9 8-5-2 14z'/><path d='M12 33h20'/>")
  if (/SEASON|TRACK/.test(s)) return S("<path d='M4 28l8-8 6 6 8-12 6 6 8-10'/><path d='M32 10h6v6'/>")
  return S("<circle cx='22' cy='22' r='12'/><path d='M22 14v16M22 30l-6-2M22 30l6-2'/>")
}

// Compact-MOTD twin of msnGlyph: one text glyph per contract kind (no PNG,
// no SVG — old MSHTML renders neither reliably in MOTD).
// Compact-MOTD twin of msnGlyph: distinct per objective (same keyword
// families as the SVG set), text-only for old MSHTML.
function msnGlyphChar(m) {
  const s = String((m && m.title) + " " + (m && m.desc)).toUpperCase()
  if (/HEAD|PRECISION|SHARPSHOOTER|TARGET/.test(s)) return "\u25CE"
  if (/PLANT|BOMB|GRENAD|C4/.test(s)) return "\u25A3"
  if (/DEFUS|SURVIV/.test(s)) return "\u271A"
  if (/WIN|VICTORY|MATCH/.test(s)) return "\u265B"
  if (/STREAK|FLAME|FIRE/.test(s)) return "\u25B2"
  if (/DAMAGE|BURST|BLAST/.test(s)) return "\u2738"
  if (/MVP|MEDAL|CROWN|VIP|CHAMP/.test(s)) return "\u2655"
  if (/SEASON|TRACK/.test(s)) return "\u25C6"
  return "\u2605"
}

function msnXp(m) {
  const t = String((m && m.reward) + " " + (m && m.desc))
  const mt = t.match(/\+([\d,]+)\s*XP/i)
  return mt ? parseInt(mt[1].replace(/,/g, ""), 10) : 0
}
function missionCard(m, opts) {
  const have = num(m.val)
  const need = num(m.target) || 1
  const status = missionStatus(m)
  const ico = m.icon || "/missions/msn_01.png"
  const mode = m.kind === "special" ? "Competitive dailies" : (m.kind === "seasonal" ? "Season tracker" : (m.kind === "bonus" ? "Bonus daily" : (m.kind === "weekly" ? "Weekly AND-set" : "Daily AND-set")))
  const token = opts && opts.token
  const steamid = opts && opts.steamid
  const badge = status === "CLAIMABLE"
    ? `<span class='badge done'>CLAIMABLE</span>`
    : (status === "CLAIMED" ? `<span class='badge done'>CLAIMED</span>`
      : (status === "READY" ? `<span class='badge done'>READY</span>`
      : (status === "TRACKER" ? `<span class='badge'>TRACKER</span>`
        : `<span class='badge'>IN PROGRESS</span>`)))
  let action = ""
  if (token && steamid && m.kind !== "special" && m.kind !== "seasonal") {
    const href = (type, arg, label) => `<a href='/missions?steamid=${encodeURIComponent(steamid)}${opts && opts.tab ? `&tab=${opts.tab}` : ""}&t=${encodeURIComponent(token)}&act=${type}:${encodeURIComponent(arg)}' class='btn-store btn-buy'><b>${esc(label)}</b></a>`
    if (num(m.status) === 1) action = href("claim_mission", `${m.group}:${m.slot}`, "CLAIM")
    // Reroll price mirrors the game exactly (FreeRerolls/RerollCost in
    // freenova_missions.sma): free rerolls first, then 100/150/200c by tier.
    else if (m.kind === "daily" && num(m.status) === 0) {
      const rrFree = num(opts && opts.rerollsLeft) > 0
      const rrVip = num(opts && opts.vipTier)
      const rrCost = rrVip >= 3 ? 100 : (rrVip >= 2 ? 150 : 200)
      action = href("reroll_mission", String(m.slot), rrFree ? "REROLL (FREE)" : `REROLL (${rrCost}c)`)
    }
  }
  return `<table class='msn-card' width='100%' cellspacing='0' cellpadding='6' border='0' bgcolor='#1E2422'>
    <tr>
      <td width='76' valign='top' align='center'><div class='msn-art'>${(opts && opts.compact) || isMotdCompact() ? `<font size='+4' color='#3dff9e'>${msnGlyphChar(m)}</font>` : msnGlyph(m)}</div></td>
      <td valign='top'><b class='msn-title'>${esc(m.title)}</b> ${badge}<br><span class='muted'>${esc(m.desc)}</span></td>
      <td width='22' valign='top' align='right'>${opts && opts.selHrefFor ? `<a href='${opts.selHrefFor(m.group, m.slot)}' class='muted' style='font-size:20px;'>&#8250;</a>` : ""}</td>
    </tr>
    ${(opts && opts.compact) || isMotdCompact()
      ? `<tr><td colspan='2' bgcolor='#0D0F0E'><table width='100%' cellspacing='0' cellpadding='0' border='0'><tr><td bgcolor='#16352C'><div style='width:${pct(have, need)}%;background:#3dff9e;height:6px;'></div></td></tr></table></td></tr>`
      : `<tr><td colspan='2'><div class='bar'><div style='width:${pct(have, need)}%'></div></div></td></tr>`}
    <tr>
      <td class='muted'><b>${fmt(Math.min(have, need))} / ${fmt(need)}</b></td>
      <td align='right'><b class='msn-rew'>${esc(m.reward)}</b>${action ? `&nbsp;${action}` : ""}</td>
    </tr>
    <tr>
      <td class='muted small'>${opts && opts.compact ? "" : esc(mode)}</td>
      <td align='right'><b>${status === "CLAIMED" ? "[\u2713] CLAIMED" : esc(status)}</b></td>
    </tr>
    ${opts && opts.compact ? "" : `<tr><td colspan='2' class='muted small'>${esc(m.counts || m.desc)} \u00b7 ${esc(m.remaining || "")}</td></tr>`}
  </table>`
}

function missionsOverview(g, opts) {
  const dailyDone = g.daily.filter(missionDone).length
  const coreBonus = g.bonus.filter(m => m.group !== 3)
  const bonusDone = coreBonus.filter(missionDone).length
  const weeklyDone = g.weekly.filter(missionDone).length
  const compDone = g.special.filter(missionDone).length
  const allDaily = dailyDone === 5 && bonusDone === 3
  const availXp = g.daily.concat(g.bonus, g.weekly, g.special).filter(m => num(m.status) === 1).reduce((s, m) => s + msnXp(m), 0)
  const nowD = new Date()
  const mid = new Date(nowD.getFullYear(), nowD.getMonth(), nowD.getDate() + 1)
  const msMid = Math.max(0, mid - nowD)
  const midTxt = Math.floor(msMid / 3600000) + "h " + Math.floor((msMid % 3600000) / 60000) + "m"
  const mon0 = new Date(nowD.getFullYear(), nowD.getMonth(), nowD.getDate() + ((8 - nowD.getDay()) % 7 || 7))
  const msMon = Math.max(0, mon0 - nowD)
  const monTxt = Math.floor(msMon / 86400000) + "d " + Math.floor((msMon % 86400000) / 3600000) + "h"
  const tile = (label, have, need) => `<td class='tile' width='33%'><div class='statk'>${label}</div><div class='statv'>${have} / ${need}</div><div class='bar'><div style='width:${need ? Math.round(100 * Math.min(have, need) / need) : 0}%'></div></div></td>`
  return `<div class='card'><div class='h2'>MISSIONS OVERVIEW</div>
    <table width='100%' cellspacing='0' cellpadding='0' border='0'><tr><td align='right' class='muted small'>Resets in ${midTxt} (daily) \u00b7 ${monTxt} (weekly)</td></tr></table>
    <table width='100%' cellspacing='8' cellpadding='0' border='0'>
      <tr>${tile("Daily", dailyDone, 5)}${tile("Weekly", weeklyDone, 4)}${tile("Bonus", bonusDone, 3)}</tr>
    </table>
    <table width='100%' cellspacing='0' cellpadding='0' border='0'><tr><td align='right'><b style='color:#e8c547;font-size:17px;'>+${fmt(availXp)} XP</b> <span class='muted small'>Available rewards</span></td></tr></table>
    <p class='muted'>Rewards grant automatically in-game. This page never pays coins/XP.${allDaily ? " Daily + bonus: ALL COMPLETE." : ""}</p>
  </div>`

}
async function weaponsCard(env, steamid) {
  let rows
  try { rows = (await env.DB.prepare(
    `SELECT slot, kills, hs, damage FROM player_weapons WHERE steamid = ?1 ORDER BY kills DESC`)
    .bind(steamid).all()).results } catch { return errorState("WEAPONS", "profile", "weapon statistics") }
  if (!rows || !rows.length) return emptyState("No weapon statistics recorded yet.")
  let out = ""
  for (const r of rows) {
    const wm = weaponMastery(r.kills)
    out += `<tr>
      <td><b>${esc(WEAPONS[r.slot] || "Slot " + r.slot)}</b></td>
      <td>
        <span class='tier-badge ${wm.level >= 10 ? "tier-gold" : wm.level >= 5 ? "tier-global" : "tier-guardian"}' style='font-size:10px;'>
          Tier ${wm.level}
        </span>
      </td>
      <td class='v'>${fmt(r.kills)}</td>
      <td class='v'>${fmt(r.hs)}</td>
      <td class='v'>${pct(r.hs, r.kills)}%</td>
      <td class='v'>${fmt(r.damage)}</td>
      <td style='min-width:110px;'>
        <div style='display:flex;justify-content:space-between;font-size:9.5px;color:var(--text-dim);margin-bottom:2px;'>
          <span>${wm.isMax ? "MAX" : `Next: L${wm.level + 1}`}</span>
          <span>${wm.isMax ? "MASTER" : `${fmt(wm.remaining)} k`}</span>
        </div>
        <div style='background:rgba(255,255,255,0.06);height:5px;border-radius:3px;overflow:hidden;'>
          <div style='background:var(--lime);height:100%;width:${wm.progressPct}%;'></div>
        </div>
      </td>
    </tr>`
  }
  return `<div class='card'><div class='h2'>WEAPON MASTERY &amp; COMBAT RECORDS</div><table class='t'>
    <tr><th>Weapon</th><th>Mastery</th><th>Kills</th><th>HS</th><th>HS%</th><th>Damage</th><th>Progress</th></tr>${out}</table></div>`
}

function achTableRow(a, p, idx) {
  const progress = achProgressOf(p, a.metric || a.field)
  const unlocked = p ? achUnlockedOf(p, a, progress) : false
  const progText = !p ? `0 / ${fmt(a.target)}`
    : (progress.tracked
      ? `${fmt(Math.min(progress.val, a.target))} / ${fmt(a.target)}${progress.note ? " · " + progress.note : ""}`
      : progress.note)
  const bar = !p || !progress.tracked ? progressBar(0) : progressBar(pct(progress.val, a.target))
  const status = unlocked ? "<span class='badge done'>UNLOCKED</span>" : "<span class='badge'>IN PROGRESS</span>"
  return `<tr>
    <td class='c'>${isMotdCompact() ? ((d) => `<font color='${medalColor({ type: d ? d.type : "BADGE", ap: d ? d.ap : 250, unlocked: unlocked })}' size='+3'>${medalGlyph(a)}</font>`)(SHOWCASE.find(x => x.id === a.id)) : cs2Medal({ ...a, title: a.name || a.title, val: progress.val, target: a.target }, unlocked, 40)}</td>
    <td><b>${esc(a.name || a.title)}</b><br><span class='muted small'>${esc(a.desc)}</span></td>
    <td class='v'>${esc(progText)}</td>
    <td class='v'>${bar}</td>
    <td class='v green'>${esc(a.reward || "")}</td>
    <td class='c'>${status}</td>
  </tr>`
}

// ---- Modern achievement cards + cabinet gallery (2026-10-10) ----
// MOTD-safe: tables + GET links (?cat/?rar/?expand/?preview=), zero JS.
// Browser enhances with the same markup (hover titles, bigger bars via CSS).
function filterTabs(items, ctx) {
  // Category tabs (data-driven counts) + rarity filter row. GET links only.
  // baseHref must already carry identity + compact context (e.g. via
  // navHref) so tabs never flip MOTD-compact <-> browser or drop SteamID.
  const base = ctx.baseHref || ""
  const q = (k, v) => {
    const u = (s, val) => `${s}=${encodeURIComponent(val)}`
    const parts = []
    if (k !== "cat" && ctx.cat && ctx.cat !== "all") parts.push(u("cat", ctx.cat))
    if (k !== "rar" && ctx.rar && ctx.rar !== "all") parts.push(u("rar", ctx.rar))
    if (v && v !== "all") parts.push(u(k, v))
    return parts.length ? base + (base.includes("?") ? "&" : "?") + parts.join("&") : base
  }
  const catTabs = [{ id: "all", name: "All" }, ...ACH_CATEGORIES].map(c => {
    const n = c.id === "all" ? items.length : items.filter(a => achCategoryOf(a.id) === c.id).length
    const on = (ctx.cat || "all") === c.id
    return on ? `<b>${esc(c.name)} (${n})</b>` : `<a href='${q("cat", c.id)}'>${esc(c.name)} (${n})</a>`
  }).join(" · ")
  const rarTabs = [{ id: "all", name: "All" }, ...RARITY_ORDER.map(r => ({ id: r, name: RARITY_STYLE[r].label }))].map(c => {
    const n = c.id === "all" ? items.length : items.filter(a => achRarityOf(a.id) === c.id).length
    const on = (ctx.rar || "all") === c.id
    return on ? `<b>${esc(c.name)}</b>` : `<a href='${q("rar", c.id)}'>${esc(c.name)}</a>`
  }).join(" · ")
  return `<div class='card'><div class='muted small'>Category: ${catTabs}</div>`
    + `<div class='muted small'>Rarity: ${rarTabs}</div></div>`
}
function cabinetGallery(items, ctx) {
  // Trophy gallery grouped by category, rarity-sorted (items arrive sorted).
  ctx = ctx || {}
  const base = ctx.baseHref || ""
  const enc = (v) => encodeURIComponent(v)
  // Preview toggles keep the full filter context (cat/rar/compact/identity)
  // so inspecting a badge never resets the gallery or flips MOTD mode.
  const prevHref = (id) => {
    const parts = []
    if (ctx.cat && ctx.cat !== "all") parts.push("cat=" + enc(ctx.cat))
    if (ctx.rar && ctx.rar !== "all") parts.push("rar=" + enc(ctx.rar))
    parts.push(`preview=${enc(ctx.preview === id ? "" : id)}`)
    return base + (base.includes("?") ? "&" : "?") + parts.join("&")
  }
  const groups = []
  for (const c of ACH_CATEGORIES) {
    const g = items.filter(i => (i.category || achCategoryOf(i.id)) === c.id)
    if (g.length) groups.push({ ...c, items: g })
  }
  const rest = items.filter(i => !ACH_CATEGORIES.some(c => c.id === (i.category || achCategoryOf(i.id))))
  if (rest.length) groups.push({ id: "other", name: "Other", items: rest })
  return groups.map(g => {
    const cellArr = g.items.map(it => {
      const rarity = it.rarity || achRarityOf(it.id)
      const livePct = (!it.unlocked && it.tracked && num(it.target) > 0)
        ? ` &#183; ${Math.min(99, Math.max(1, Math.round(100 * num(it.val) / num(it.target))))}%` : ""
      const artSize = isMotdCompact() ? 48 : 56
      const art = `<img src='${achArt(it, g.items.indexOf(it))}' width='${artSize}' height='${artSize}' alt='' style='opacity:${it.unlocked ? 1 : 0.45};${it.unlocked ? "" : "filter:grayscale(1);"}'>`
      const earned = it.unlocked ? (it.earned_at ? fmtEarned(it.earned_at) : "Earned before date tracking") : "Locked"
      const prev = ctx.preview === (it.id || it.code)
      const more = prev && (it.desc || it.note)
        ? `<br><span class='muted small'>${esc(it.desc || "")}${it.note ? " · " + esc(it.note) : ""}<br>Earned: ${esc(earned)}</span>` : ""
      // Progress under the badge; the coin above colors in with the same
      // fraction. Tooltip reveals description + earned date after 2s hover
      // (CSS); click/expand is the instant MOTD-safe fallback.
      const need = num(it.target)
      const pctd = (it.tracked && need > 0) ? Math.min(99, Math.max(it.unlocked ? 100 : 1, Math.round(100 * num(it.val) / need))) : 0
      const progLine = it.tracked
        ? `${fmt(Math.min(num(it.val), need))} / ${fmt(need)}${it.unlocked ? "" : ` (${pctd}%)`}`
        : (it.note || "Tracked in-game")
      const tip = (!isMotdCompact())
        ? `<span class='cab-tip' hidden><b>${esc(it.title || it.name || "")}</b><br>${esc(it.desc || "")}<br><span class='muted'>${it.unlocked ? "Earned: " + esc(earned) : "Not yet earned"}</span></span>`
        : ""
      return `<td width='20%' align='center' valign='top' class='cab-cell rarity-${rarity} ${it.unlocked ? "st-completed" : "st-locked"}'>`
        + `<a href='${prevHref(it.id || it.code)}' style='text-decoration:none;color:inherit;'>${art}<br><b>${esc(it.title || it.name || "")}</b></a>${tip}<br>`
        + `<span class='muted small'>${esc(progLine)}</span><br>`
        + `${rarityBadge(rarity)}<br><span class='muted small'>${it.unlocked ? "UNLOCKED" : "IN PROGRESS" + livePct}</span><br>`
        + `<span class='muted small'>${esc(earned)}</span>${more}</td>`
    })
    const rows = []
    for (let i = 0; i < cellArr.length; i += 5) rows.push(`<tr>${cellArr.slice(i, i + 5).join("")}</tr>`)
    return `<div class='card'><div class='h2'>${esc(g.name).toUpperCase()}</div>`
      + `<table width='100%' cellspacing='4' cellpadding='6' border='0'>${rows.join("")}</table></div>`
  }).join("")
}

async function cosmeticsCard(env, p) {
  const spawn = COSMETICS.spawn[p.eq_spawn] || "None"
  const title = COSMETICS.title[p.eq_title] || "None"
  const death = COSMETICS.death[p.eq_death] || "None"
  const color = COSMETICS.color[p.eq_color] || "Default"
  return `<div class='card'><div class='h2'>EQUIPPED COSMETICS</div><table class='t'>
    <tr><td class='k'>Chat title</td><td class='v'>${esc(title)}</td></tr>
    <tr><td class='k'>Custom tag</td><td class='v'>${p.custom_tag ? esc(p.custom_tag) : "<span class='muted'>none — buy the Custom Tag License in the Store</span>"}</td></tr>
    <tr><td class='k'>Chat color</td><td class='v'>${esc(color)}</td></tr>
    <tr><td class='k'>Spawn effect</td><td class='v'>${esc(spawn)}</td></tr>
    <tr><td class='k'>Death effect</td><td class='v'>${esc(death)}</td></tr>
    <tr><td class='k'>Player model</td><td class='v'>${p.eq_model ? esc(p.eq_model) : "<span class='muted'>default</span>"}</td></tr>
  </table></div>`
}

async function tournamentCard(env, p, steamid) {
  let rankRow
  try { rankRow = await env.DB.prepare(
    `SELECT COUNT(*) + 1 AS pos FROM players WHERE comp_points > ?1`).bind(p.comp_points).first() } catch { rankRow = null }
    return `<div class='card'><div class='h2'>TOURNAMENT (TOP 15 POINTS)</div><table class='t'>
    <tr><td class='k'>Season</td><td class='v'>${esc(p.comp_season || "—")}</td></tr>
    <tr><td class='k'>Season points</td><td class='v'>${fmt(p.comp_points)} <span class='muted'>${rankRow ? "(position #" + fmt(rankRow.pos) + ")" : ""}</span></td></tr>
    <tr><td class='k'>Career points</td><td class='v'>${fmt(p.comp_lifetime)}</td></tr>
    <tr><td class='k'>Full board</td><td class='muted'>in-game /pts</td></tr>
  </table></div>`
}

const BP_RARITY_BG = {
  normal: "#3A4240",
  rare: "#1F6B3A",
  super_rare: "#1A3A6B",
  mythic: "#6B1A24",
  legendary: "#8A6A12"
}

function passTierState(n, cursor) {
  if (n === Math.max(1, cursor) || (cursor === 0 && n === 1)) return "now"
  if (n <= cursor) return "done"
  return "lock"
}

function passCellState(n, cursor) {
  const st = passTierState(n, cursor)
  return st === "now" ? "current" : (st === "done" ? "claimed" : "locked")
}

// Reward-type labels for the tier detail card (text classification only;
// lane art is per-tier medallion PNGs via bpLaneFile below).
function bpIconKindText(text, name) {
  const s = String(text + " " + (name || "")).toLowerCase()
  if (/xp boost|double xp|1\.5x|2\.0x/.test(s)) return "xp"
  if (/knife|flip knife|karambit/.test(s)) return "knife"
  if (/skin|awp|ak-?47|m4a1|deagle|usp\b|glock|model|bipod|silencer|buffer spring|heavy bolt/.test(s)) return "skin"
  if (/title|medal(?!.*slot)|trophy|\bmvp\b|badge|tag license|tag voucher/.test(s)) return "badge"
  if (/key\b|vault access|coin vault key/.test(s)) return "key"
  if (/jump|vitality|\bhp\b|armor|titan|parachute|chute|defuse|revive|sniper|bolt module|last stand|defiance|vampire|nimble|dressing|stim|adrenaline|siphon|multiplier|matrix|patch|plate|helmet|visor|surge/.test(s)) return "perk"
  if (/smoke|grenade|flash|blind|color|glide|thermal|decoy|grenadier|he frag|toxic/.test(s)) return "gear"
  if (/vip|elite|premium track|guardian|syndicate|legend player model/.test(s)) return "crown"
  if (/mvp title|global elite/.test(s)) return "badge"
  if (/case|crate|supply|stash|munitions|ammo|pack|reserve|ration|holster|tuning|mod|cell|currency|treasury|dividend|warchest|drop|stimpack|medkit|drops|vapor|mist|cloud/.test(s)) return "case"
  return "coins"
}
function bpIconTypeLabel(text, name) {
  return { coins: "Coins", case: "Supply", skin: "Weapon", knife: "Knife", badge: "Badge",
    key: "Key", xp: "XP Boost", perk: "Perk", gear: "Gear", crown: "VIP" }[bpIconKindText(text, name)] || "Reward"
}

// Battle-pass lane art: every tier has its own collectible medallion.
// Free lane steel, premium lane gold; ornaments by tier rarity.
// (Replaces the old uniform-SVG-lane treatment: each tier is now unique.)
function bpLaneFile(lane, n) {
  const pad = String(Math.max(1, Math.min(60, num(n) || 1))).padStart(2, "0")
  return lane === "prem" ? `/bp/prem_${pad}.png` : `/bp/free_${pad}.png`
}
function bpLaneImg(lane, n, size) {
  const px = size || 40
  return `<img src='${bpLaneFile(lane, n)}' width='${px}' height='${px}' alt='' border='0'>`
}

function renderPassTrack(tiers, opts) {
  opts = opts || {}
  const season = opts.season || "1"
  const tier = num(opts.tier)
  const premiumCursor = opts.premium != null ? num(opts.premium) : 0
  const into = num(opts.into)
  const need = num(opts.need) || 1000
  const vip = !!opts.vip
  const lane = opts.lane != null ? num(opts.lane) : (vip ? 1 : 0)
  const laneName = premiumLaneName(lane)
  const name = opts.name || ""
  const coins = num(opts.coins)
  const progress = pct(into, need)
  const list = Array.isArray(tiers) ? tiers : []
  const seasonDay = new Date().getDate()
  const seasonDim = new Date(new Date().getFullYear(), new Date().getMonth() + 1, 0).getDate()
  const seasonLeft = Math.max(0, seasonDim - seasonDay)
  const nextTier = list.find(t => num(t.tier != null ? t.tier : 0) > Math.max(0, tier))
  const nextTeaser = nextTier
    ? `NEXT: Tier ${fmt(num(nextTier.tier))} \u2014 ${esc(nextTier.name || premiumLabel(nextTier, lane))}`
    : "Track complete \u2014 all tiers claimed"
  const logo = opts.logoSrc || "/logo.png"
  const compact = !!opts.compact || isMotdCompact()

  const tierCount = list.length || 60
  const cursor = Math.max(0, tier)
  // Reveal window (compact MOTD only): unlocked history (tiers 1..cursor,
  // minimum 8). Future tiers are never rendered there. The browser track
  // always shows the full season so you can travel back and forth.
  const windowN = Math.max(8, Math.min(tierCount, Math.max(1, cursor)))
  const visible = compact
    ? list.filter(t => { const n = num(t.tier != null ? t.tier : 0); return n >= 1 && n <= windowN })
    : list
  const selMax = compact ? windowN : tierCount
  const selTier = Math.min(selMax, Math.max(1, num(opts.selTier) || Math.max(1, cursor)))
  const sel = list.find(t => num(t.tier != null ? t.tier : 0) === selTier) || list[selTier - 1] || null
  const tierHref = (n) => {
    const q = []
    if (opts.steamid) q.push("steamid=" + encodeURIComponent(opts.steamid))
    q.push("tier=" + n)
    if (compact) q.push("compact=1")
    return "/battlepass?" + q.join("&") + "#tier-" + n
  }
  let detail = ""
  if (!compact && sel) {
    const sn = num(sel.tier != null ? sel.tier : 0) || selTier
    const sFree = String(sel.free || sel.name || "")
    const sPrem = premiumLabel(sel, lane)
    const sDone = passTierState(sn, tier) !== "lock"
    const sPad = String(sn).padStart(2, "0")
    const sState = passTierState(sn, tier) === "now" ? "CURRENT TIER" : (sDone ? "CLAIMED" : "LOCKED")
    const sPrev = sn > 1 ? `<a href='${tierHref(sn - 1)}'>&#8249; tier ${sn - 1}</a>` : "&#8249;"
    const sNext = sn < tierCount ? `<a href='${tierHref(sn + 1)}'>tier ${sn + 1} &#8250;</a>` : "&#8250;"
    const sPad2 = String(sn).padStart(2, "0")
    const sFreeType = bpIconTypeLabel(String(sel.free || "").replace(/\s*\(.*?\)\s*/g, " ").trim(), "")
    const sPremType = bpIconTypeLabel(sPrem, sel.name)
    detail = `<div class='card'>
    <table width='100%' cellspacing='0' cellpadding='6' border='0'><tr>
      <td width='112' align='center' valign='top'>${bpLaneImg("free", sn, 72)}<br><span class='muted small'>FREE · ${sFreeType.toUpperCase()}</span><br><br>${bpLaneImg("prem", sn, 72)}<br><span class='muted small'>PREMIUM · ${sPremType.toUpperCase()}</span></td>
      <td valign='top'><div class='hero-kick' style='color:#e8c547;'>TIER ${sPad2} · ${esc(normalizeBpRarity(sel.rarity).toUpperCase())}${sel.milestone ? " · MILESTONE" : ""}</div>
        <div style='color:#ffffff;font-size:17px;font-weight:bold;'>${esc(sel.name || ("Tier " + sn))} <span class='badge ${sDone ? "done" : ""}'>${sState}</span></div>
        <p><table cellspacing='0' cellpadding='2' border='0'><tr><td valign='middle'>${bpLaneImg("free", sn, 24)}</td><td valign='middle'>FREE — ${esc(sFree)}</td></tr><tr><td valign='middle'>${bpLaneImg("prem", sn, 24)}</td><td valign='middle'>PREMIUM — ${esc(sPrem)}</td></tr></table></p>
        <p class='muted small'>Requires Tier ${fmt(sn)} (${fmt(sn * need)} total XP) · ${sPrev} · ${sNext}</p></td>
    </tr></table></div>`
  }

  const hero = compact
    ? `<table width='100%' cellspacing='0' cellpadding='6' border='0' bgcolor='#0D0F0E'>
    <tr>
      <td>
        <b><font color='#36DEAB'>SEASON ${esc(season)}</font></b>
        &nbsp;<b><font color='#ffffff'>CYBER GENESIS</font></b>
        ${vip ? `&nbsp;<b><font color='#ffd700'>PREMIUM · ${esc(laneName)}</font></b>` : `&nbsp;<font color='#B7C1BC'>FREE</font>`}<br>
        <font color='#B7C1BC' size='2'>${esc(name || "FreeNova")} · Tier ${fmt(tier)} / ${fmt(list.length || 60)}</font>
        &nbsp;<b><font color='#ffffff'>${fmt(into)} / ${fmt(need)} XP</font></b>
        ${coins ? `&nbsp;<font color='#B7C1BC'>${fmt(coins)}c</font>` : ""}
        <table width='100%' cellspacing='0' cellpadding='0' border='0'><tr><td bgcolor='#16352C'><div style='width:${progress}%;background:#36DEAB;height:8px;'></div></td></tr></table>
      </td>
    </tr>
  </table>`
    : `<div class='csgo-pass'>
    <div class='csgo-pass-layout'>
      <div class='csgo-pass-left'>
        <table width='100%' cellspacing='0' cellpadding='6' border='0'><tr>
          <td valign='top'><div class='op-kicker'>SEASON ${esc(season)} · CYBER GENESIS</div>
            <div class='op-title'>Battle Pass</div>
            <div class='muted'>${seasonLeft} days remaining</div> · Cyber Genesis · ends in ${seasonLeft}d</div>
            <div class='op-meta'>${esc(name || "FreeNova")} · ${vip ? esc(laneName) + " track" : "Free track"}${coins ? ` · <b style='color:#e8c547;'>${fmt(coins)}c</b>` : ""}</div>
            <table width='100%' cellspacing='0' cellpadding='0' border='0'><tr><td bgcolor='#16352C'><div style='width:${progress}%;background:#e8c547;height:14px;'></div></td></tr></table>
            <div class='muted small'>${nextTeaser}</div></td>
          <td width='110' align='right' valign='top'><div style='color:#e8c547;font-size:20px;font-weight:bold;'>Tier ${fmt(tier)}</div>
            <div class='muted small'>${fmt(into)} / ${fmt(need)} XP</div></td>
        </tr></table>
      </div>
      <div class='csgo-pass-track-wrap'><div class='csgo-pass-track'>`

  if (compact) {
    // Windowed dual-lane MOTD table: tier header + Prem row + Free row.
    // Text/glyph cells only (GoldSrc-safe, no img/SVG) — same lanes and
    // reveal window as the browser track, so in-game matches the panel.
    const premOwned = opts.premiumOwned !== false
    let head = "<tr><td class='pass-cell'></td>"
    let premRow = "<tr><td class='pass-cell' valign='top' align='center'><font color='#FFD700' size='1'><b>Prem</b></font></td>"
    let freeRow = "<tr><td class='pass-cell' valign='top' align='center'><font color='#B7C1BC' size='1'><b>Free</b></font></td>"
    for (const t of visible) {
      const n = num(t.tier != null ? t.tier : 0) || 0
      if (!n) continue
      const bg = boxTint(t)
      const ink = boxInk(t)
      const starColor = (t.star === "gold") ? "#FFD700" : "#EDF1EF"
      head += `<td class='pass-cell' valign='top' align='center'><font color='#B7C1BC' size='1'>${n}</font></td>`
      const fst = passTierState(n, tier)
      const fmark = fst === "now" ? "<br><font color='#FFD700' size='1'>NOW</font>" : (fst === "done" ? "<br><font color='#36DEAB' size='1'>✓</font>" : "<br><font color='#71827A' size='1'>🔒</font>")
      freeRow += `<td class='pass-cell' valign='top' align='center' bgcolor='${bg}'>`
        + `<font color='${starColor}' size='4'>★</font><br>`
        + `<b><font color='${ink}' size='1'>${esc(boxLabel(t))}</font></b>${fmark}</td>`
      const pmark = !premOwned ? "<br><font color='#71827A' size='1'>🔒</font>"
        : (n <= premiumCursor ? "<br><font color='#36DEAB' size='1'>✓</font>"
          : (n === premiumCursor + 1 ? "<br><font color='#FFD700' size='1'>NOW</font>" : "<br><font color='#71827A' size='1'>🔒</font>"))
      const plabel = String(premiumLabel(t, lane) || "VIP drop").slice(0, 14)
      premRow += `<td class='pass-cell' valign='top' align='center' bgcolor='${bg}'>`
        + `<font color='${starColor}' size='4'>★</font><br>`
        + `<b><font color='${ink}' size='1'>${esc(plabel)}</font></b>${pmark}</td>`
    }
    head += "</tr>"
    premRow += "</tr>"
    freeRow += "</tr>"
    const rail = opts.missionsHtml || ""
    const premCtaCompact = (opts.premiumOwned === false && opts.ctaUrl)
      ? `<div class='card'><b><font color='#FFD700'>PREMIUM LOCKED</font></b><br>`
        + `<font color='#B7C1BC' size='2'>Premium is season-based (Season ${esc(season)}). </font>`
        + `<a href='${esc(opts.ctaUrl)}'><font color='#FFD700'>Buy Premium</font></a></div>`
      : ""
    // MOTD width fix: bp-cols (table-layout:fixed, width:100%, already in
    // the shared sheet so the compact subset stays a subset) forces the 9
    // window columns to share the ~620px viewport instead of overflowing it
    // at 16% each, and the wrap drops its overflow-x:scroll slider (scroll
    // always paints a slider track in old MSHTML, even with nothing to show).
    const boxes = `<div class='card'><div class='h2'>TIER REWARDS — DUAL TRACK</div>
      <p class='muted small'>GoldSrc view: Prem + Free lanes, text cells. Full art lanes live in the browser panel.${premOwned ? "" : " Premium is LOCKED this season."}</p>
      <div class='csgo-pass-track-wrap' style='overflow-x:visible;'><table class='bp-grid bp-cols' cellspacing='4' cellpadding='6' border='0'>${head}${premRow}${freeRow}</table></div>
      <p class='muted small'>white=claimed green=open grey=locked · future tiers unlock as you progress</p>
    </div>`
    if (rail) {
      return `${hero}
      ${premCtaCompact}
      <table width='100%' cellspacing='0' cellpadding='4' border='0'>
        <tr>
          <td width='34%' valign='top'>${rail}</td>
          <td width='66%' valign='top'>${boxes}</td>
        </tr>
      </table>`
    }
    return `${hero}${premCtaCompact}${boxes}`
  }

  // Full horizontal dual-track: every tier renders in one scrollable lane
  // (no pagination). Tier links open the detail card above the lanes and
  // anchor the lane to that tier (cells carry id='tier-N').
  const prem = []
  const free = []
  let claimedN = 0
  // Per-season premium (2026-10-10): premiumOwned comes from the store
  // entitlement (bp_premium_season + bp_ent_lane), NOT from VIP tier.
  // Legacy S1 VIP auto-grants keep working via the season==="1" fallback
  // computed in pageBattlePass; future seasons require a store purchase.
  const premiumOwned = opts.premiumOwned !== false
  for (const item of visible) {
    const idx = list.indexOf(item)
    const t = list[idx]
    const n = num(t.tier != null ? t.tier : 0) || (idx + 1)
    const rarity = normalizeBpRarity(t.rarity)
    const star = (t.star === "gold") ? "gold" : "white"
    const tst = passTierState(n, tier)
    if (tst === "done") claimedN++
    const freeCls = passCellState(n, tier)
    let premCls = n <= premiumCursor ? "claimed" : "locked"
    if (!premiumOwned || (!vip && rarity !== "normal")) premCls = "locked"
    if (!premiumOwned) premCls += " premium-only"
    const mile = t.milestone ? " milestone" : ""
    const pad = String(n).padStart(2, "0")
    const mileTag = t.milestone ? `<div style='color:#ffd700;font-size:9px;font-weight:bold;'>MILESTONE</div>` : ""
    const selCls = (!compact && n === selTier) ? " selected" : ""
    const freeRw = boxLabel(t)
    const premRw = String(premiumLabel(t, lane) || "VIP drop").slice(0, 18)
    prem.push(`<div class='csgo-pass-cell premium ${premCls}${mile} bp-rarity-${rarity}${selCls}' id='tier-${n}'>
      <a href='${tierHref(n)}'>${bpLaneImg("prem", n, 40)}
      <div class='nm'>${n}</div><div class='rw'>${esc(premRw)}</div>${mileTag}</a>
    </div>`)
    free.push(`<div class='csgo-pass-cell ${freeCls}${mile} bp-rarity-${rarity}${selCls}'>
      <a href='${tierHref(n)}'>${bpLaneImg("free", n, 40)}
      <div class='nm'>${n}</div><div class='rw'>${esc(freeRw)}</div></a>${mileTag}
    </div>`)
  }
  const premCta = (!premiumOwned && opts.ctaUrl)
    ? `<div class='card prem-cta'><div class='h2'>PREMIUM TRACK LOCKED</div>`
      + `<p>Premium is <b>season-based</b> — Season ${esc(season)} requires its own Premium pass. Free track stays playable.</p>`
      + `<p><a class='btn-gold' href='${esc(opts.ctaUrl)}'>BUY SEASON ${esc(season)} PREMIUM</a></p></div>`
    : ""

  const trackNav = compact
    ? `<table width='100%' cellspacing='0' cellpadding='0' border='0'><tr><td class='muted small'>Tier ${fmt(cursor)} / ${fmt(tierCount)} · ${claimedN} claimed · future tiers unlock as you progress</td><td align='right'><a href='#tier-${Math.max(1, Math.min(windowN, cursor))}'>jump to current &#8250;</a></td></tr></table>`
    : `<table width='100%' cellspacing='0' cellpadding='0' border='0'><tr><td class='muted small'>Tier ${fmt(cursor)} / ${fmt(tierCount)} · ${claimedN} claimed · travel the season sideways</td><td align='right'><a href='#tier-${Math.max(1, cursor)}'>jump to current &#8250;</a></td></tr></table>`

  return `${hero}
          ${trackNav}
          ${detail}
          <div class='csgo-pass-rail premium'>Premium${lane >= 1 ? " · " + esc(laneName) : ""}${premiumOwned ? "" : " · LOCKED"}<span style='float:right;'>SEASON TRACK · ${fmt(tierCount)} TIERS</span></div>
          <div class='csgo-pass-row'>${prem.join("")}</div>
          <div class='csgo-pass-row'>${free.join("")}</div>
          <div class='csgo-pass-rail free'>Free<span style='float:right;'>${fmt(tierCount)} TIERS</span></div>
          ${premCta}
        </div></div></div></div>`
}

// ============================================================ BATTLE PASS
export async function pageBattlePass(env, url) {
  const steamid = steamidOf(url)
  const useCompact = isMotdCompact() || compact(url) === "1"
  let track = null
  try {
    const cat = await env.DB.prepare(`SELECT json FROM catalog WHERE key = 'reward_track'`).first()
    if (cat && cat.json) track = JSON.parse(cat.json)
  } catch { track = null }
  if (!track || !track.tiers || !track.tiers.length) track = DEFAULT_REWARD_TRACK

  const tiers = Array.isArray(track.tiers) ? track.tiers : []
  const need = Math.max(1, num(track.xp_per_tier) || 1000)

  if (!steamid) {
    const season0 = String(track.season || "1")
    const body = `
    <div class='card ok'><div class='h2'>OPEN FROM THE GAME</div>
      <p>Run <code>/battlepass</code> in chat.</p>
    </div>
    ${renderPassTrack(tiers, { season: season0, tier: 0, premium: 0, claimed: 0, into: 0, need, vip: false, premiumOwned: false, ctaUrl: seasonPremiumCtaUrl({ compact: useCompact }), compact: useCompact, selTier: num(url.searchParams.get("tier")), tpage: num(url.searchParams.get("tpage")), from: num(url.searchParams.get("from")) })}
    <p class='muted'>${tiers.length} live tiers from the game catalog. Claim in-game with /bp. Premium is season-based — <a href='${esc(seasonPremiumCtaUrl({ compact: useCompact }))}'>buy Season ${esc(season0)} Premium</a>.</p>`
    return html("BATTLE PASS", body, { compact: useCompact, product: "battlepass" })
  }

  let p
  try { p = await env.DB.prepare(`SELECT * FROM players WHERE steamid = ?1`).bind(steamid).first() }
  catch { return errorState("BATTLE PASS", "battlepass", "Battle Pass data") }
  if (!p) {
    return notFound("BATTLE PASS", "battlepass", "This SteamID has no snapshot yet. Play a few minutes, then retry.")
  }

  const vip = num(p.vip_tier) > 0
  // BattlePass progress is BP XP / BP tier - never rank xp/level and never the
  // milestone cursor (REVIEW.md §2.4 H1).
  const tier = bpTierOf(p, need)
  const claimed = 0
  const into = bpInto(p.bp_xp, need)
  const season = String(track.season || p.bp_season || "1")
  // S1 grandfathering: premium was VIP-gated auto-grant, so S1 honors the
  // legacy bp_premium cursor. Seasons >1 require a store entitlement row.
  const premiumOwned = hasSeasonPremium(p, season) || (season === "1" && (num(p.bp_premium) > 0 || vip))
  // Display lane follows the same rule: S1 shows the VIP lane, S2+ shows
  // the purchased entitlement lane (0 = locked rail, no lane name).
  const dispLane = season === "1"
    ? vipLane(p.vip_tier)
    : ((String(p.bp_premium_season || "") === season) ? num(p.bp_ent_lane) : 0)

  // Owned combat skill stages (game snapshot via player_skills). Show-only:
  // purchases/upgrades stay game-authoritative (/shop in game).
  const skillsCard = await ownedSkillsCard(env, steamid, useCompact)

  const body = `${renderPassTrack(tiers, {
    season,
    tier, premium: num(p.bp_premium), claimed, into, need, vip: premiumOwned,
    lane: dispLane,
    premiumOwned, ctaUrl: seasonPremiumCtaUrl({ steamid, compact: useCompact }),
    name: p.name, coins: p.coins, steamid, compact: useCompact,
    selTier: num(url.searchParams.get("tier")), tpage: num(url.searchParams.get("tpage")),
    from: url.searchParams.get("from")
  })}
  ${skillsCard}
  <p class='muted'>Rewards grant automatically in-game when you cross a tier. There is no separate web claim. Premium is season-based and must be bought again each season.</p>`
  return html("BATTLE PASS", body, { steamid, compact: useCompact, product: "battlepass" })
}


// Owned combat skill stages (game snapshot via player_skills, filled by the
// sync push from players[].skills). Read-only: buy/upgrade stays in-game
// (/shop) — the panel never spends. Returns "" when nothing is owned.
async function ownedSkillsCard(env, steamid, compactCap) {
  try {
    const skRows = (await env.DB.prepare(
      `SELECT skill, stage FROM player_skills WHERE steamid = ?1 AND stage > 0 ORDER BY skill`).bind(steamid).all()).results || []
    if (!skRows.length) return ""
    // MOTD window: the full stage table is vertical bulk; compact shows the
    // first 5 with a count line, the rest live in the browser panel.
    const shown = compactCap ? skRows.slice(0, 5) : skRows
    const extra = compactCap && skRows.length > shown.length ? skRows.length - shown.length : 0
    if (!skRows.length) return ""
    let defs = DEFAULT_SKILLS.skills || []
    try {
      const c = await env.DB.prepare(`SELECT json FROM catalog WHERE key = 'skills'`).first()
      if (c && c.json) {
        const parsed = JSON.parse(c.json)
        if (Array.isArray(parsed.skills) && parsed.skills.length) defs = parsed.skills
      }
    } catch {}
    const rows = shown.map(r => {
      const def = (defs.find(d => d && d.id === r.skill) || {})
      const mx = def.max_stage || (def.stages ? def.stages.length : 3)
      return `<tr><td class='c'><img src='${skillArt({ id: r.skill })}' width='24' height='24' alt='' border='0'></td>
        <td><b>${esc(def.name || r.skill)}</b></td><td class='v'>STAGE ${num(r.stage)}/${mx}</td></tr>`
    }).join("")
    return `<div class='card'><div class='h2'>COMBAT SKILLS (${skRows.length})</div>
      <table class='t' width='100%' cellspacing='0' cellpadding='6' border='0'>
      <tr><th></th><th>Skill</th><th class='v'>Owned</th></tr>${rows}</table>${extra ? `
      <p class='muted small'>+${extra} more skill${extra === 1 ? "" : "s"} in the browser panel.</p>` : ""}
      <p class='muted small'>Snapshot pushed by the game. Buy / upgrade with <code>/shop</code> in game.</p></div>`
  } catch { return "" }
}

// ============================================================ MISSIONS
export async function pageMissions(env, url) {
  const steamid = steamidOf(url)
  const useCompact = isMotdCompact() || compact(url) === "1"

  if (!steamid) {
    return html("MISSIONS", `<div class='card'><div class='h2'>OPEN FROM THE GAME</div>
      <p>Run <code>/missions</code> in chat.</p>
      <p class='muted'>No snapshot yet. Play on the server, then reopen /missions.</p></div>${await recentPlayersHtml(env, "missions")}`,
      { compact: useCompact, product: "missions" })
  }

  let p
  try { p = await env.DB.prepare(`SELECT * FROM players WHERE steamid = ?1`).bind(steamid).first() }
  catch { return errorState("MISSIONS", "missions", "mission data") }
  if (!p) return notFound("MISSIONS", "missions", "No snapshot yet. Play on the server, then reopen /missions.")

  const g = missionGroups(p)
  const token = await pageActionToken(env, url, steamid)
  const act = url.searchParams.get("act") || ""
  let actMsg = ""
  if (act && token) {
    const colon = act.indexOf(":")
    const type = colon >= 0 ? act.slice(0, colon) : act
    const arg  = colon >= 0 ? act.slice(colon + 1) : ""
    const res = await queueAction(env, steamid, type, arg || "", token)
    actMsg = res.ok
      ? `<div class='card ok'><span class='green'>Request queued — the game server will validate and apply it within a minute.</span></div>`
      : `<div class='err'>${esc(res.error || "Could not queue the request.")}</div>`
  }
  const status = token ? await actionStatusLine(env, steamid) : ""
  const VALID_TABS = ["daily", "weekly", "bonus", "competitive", "seasonal", "completed", "premium"]
  let tab = String(url.searchParams.get("tab") || "").toLowerCase()
  if (!VALID_TABS.includes(tab)) tab = ""
  const cardOpts = { token, steamid, compact: useCompact, tab: tab || "",
    vipTier: num(p.vip_tier), rerollsLeft: num(p.rerolls_left),
    selHrefFor: (gm, gs) => {
      const q = [`steamid=${encodeURIComponent(steamid)}`]
      if (tab) q.push(`tab=${tab}`)
      q.push(`sel=${gm}:${gs}`)
      if (useCompact) q.push("compact=1")
      return `/missions?${q.join("&")}`
    } }
  // Only game-flagged claimables (status 1) count — progress-met rows without
  // the flag would be rejected by the game as "nothing to claim".
  const readyCount = g.daily.concat(g.bonus, g.weekly).filter(m => num(m.status) === 1).length
  const claimAll = token
    ? (readyCount
      ? `<p><a href='/missions?steamid=${encodeURIComponent(steamid)}&t=${encodeURIComponent(token)}&act=claim_mission_all:' class='btn-store btn-buy'><b>CLAIM ALL READY (${readyCount})</b></a> · ${fmt(p.rerolls_left)} free rerolls left</p>`
      : `<p class='muted'>Nothing ready to claim right now. · ${fmt(p.rerolls_left)} free rerolls left</p>`)
    : `<p class='muted'>Open /missions from the game to claim or reroll.</p>`

  const tabHref = (k) => {
    const q = [`steamid=${encodeURIComponent(steamid)}`]
    if (k) q.push(`tab=${k}`)
    if (useCompact) q.push("compact=1")
    return `/missions?${q.join("&")}`
  }
  const tabPill = (k, label) => (tab ? tab === k : k === "")
    ? `<span class='pill on'>${label}</span>`
    : `<a class='pill' href='${tabHref(k)}'>${label}</a>`
  const tabBar = `<div class='card'><div>${tabPill("", "All")}${tabPill("daily", "Daily")}${tabPill("weekly", "Weekly")}${tabPill("bonus", "Bonus")}${tabPill("competitive", "Competitive")}${tabPill("seasonal", "Season")}${tabPill("completed", "Completed")}${tabPill("premium", "Premium")}</div></div>`
  const groupCard = (title, note, list) => `<div class='card'><div class='h2'>${title}</div>${note ? `<p class='muted'>${note}</p>` : ""}</div>${list.map(m => missionCard(m, cardOpts)).join("")}`
  const allFlat = g.daily.concat(g.bonus, g.weekly, g.special, g.seasonal)
  const selMatch = String(url.searchParams.get("sel") || "").match(/^(\d+):(\d+)$/)
  let detail = ""
  if (selMatch) {
    const sg = num(selMatch[1]), ss = num(selMatch[2])
    const dm = allFlat.find(m => num(m.group) === sg && num(m.slot) === ss)
    if (dm) {
      const dhave = num(dm.val), dneed = num(dm.target) || 1
      const dstatus = missionStatus(dm)
      detail = `<div class='card'><div class='h2'>${esc(dm.title)}</div>
      <table width='100%' cellspacing='0' cellpadding='6' border='0'><tr>
        <td width='76' align='center' valign='top'><div class='msn-art'>${isMotdCompact() ? `<font size='+4' color='#3dff9e'>${msnGlyphChar(dm)}</font>` : msnGlyph(dm)}</div></td>
        <td valign='top'><b class='msn-title'>${esc(dm.title)}</b> <span class='badge ${dstatus === "CLAIMED" || dstatus === "CLAIMABLE" ? "done" : ""}'>${dstatus}</span><br><span class='muted'>${esc(dm.desc)}</span></td>
      </tr></table>
      <div class='bar'><div style='width:${pct(dhave, dneed)}%'></div></div>
      <table class='t' width='100%' cellspacing='0' cellpadding='6' border='0'>
        <tr><td class='k'>Progress</td><td class='v'>${fmt(Math.min(dhave, dneed))} / ${fmt(dneed)}</td></tr>
        <tr><td class='k'>Reward</td><td class='v'>${esc(dm.reward)}</td></tr>
        <tr><td class='k'>Resets</td><td class='v'>${esc(dm.remaining || "")}</td></tr>
        <tr><td class='k'>Details</td><td class='v muted'>${esc(dm.counts || "")}</td></tr>
      </table></div>`
    }
  }
  const showDaily = !tab || tab === "daily"
  const showWeekly = !tab || tab === "weekly"
  const showBonus = !tab || tab === "bonus"
  const showComp = !tab || tab === "competitive"
  const showSeason = !tab || tab === "seasonal"
  let groups = ""
  if (!tab || tab === "daily") groups += groupCard("DAILY MISSIONS", "AND-set: all 5 grant +500 XP together when claimed." + (claimAll ? "<br>" + claimAll : ""), g.daily)
  if (!tab || tab === "weekly") groups += groupCard("WEEKLY MISSIONS", "AND-set: all 4 grant +5000 XP + 1000c. Resets ISO week (%G-%V). No reroll.", g.weekly)
  if (!tab || tab === "bonus") groups += groupCard("BONUS DAILIES", "Each bonus pays coins on its own.", g.bonus)
  // MOTD window: the All view keeps the three claimable groups; competitive
  // dailies + season trackers collapse to one summary line with tab links
  // (their tabs still render full cards). Filtered tab views are unchanged.
  if (showComp && (!useCompact || tab)) groups += groupCard("COMPETITIVE DAILIES", null, g.special)
  if (showSeason && (!useCompact || tab)) groups += groupCard("SEASON TRACKERS", "Seasonal rows are trackers, not paid contracts.", g.seasonal)
  if (useCompact && !tab) {
    const compDone = g.special.filter(missionDone).length
    groups += `<div class='card'><div class='h2'>MORE CONTRACTS</div>`
      + `<p class='muted small'>Competitive dailies ${compDone}/${g.special.length} complete · ${g.seasonal.length} season trackers — `
      + `<a href='${tabHref("competitive")}'>Competitive</a> · <a href='${tabHref("seasonal")}'>Season</a></p></div>`
  }
  if (tab === "completed") {
    const done = allFlat.filter(missionDone)
    groups += `<div class='card'><div class='h2'>COMPLETED</div><p class='muted'>${done.length} mission${done.length === 1 ? "" : "s"} complete.</p></div>` + done.map(m => missionCard(m, cardOpts)).join("")
  }
  if (tab === "premium") {
    const vipx = g.bonus.filter(m => m.group === 3)
    groups += `<div class='card'><div class='h2'>PREMIUM</div><p class='muted'>VIP EXTRA contracts${vipx.length ? "" : " unlock with VIP membership."}</p></div>` + vipx.map(m => missionCard(m, cardOpts)).join("")
  }
  const showM = deriveShowcase(p)
  const unlockedM = showM.items.filter(i => i.unlocked)
  const medalsStrip = `<div class='h2'>MEDALS</div>` + (unlockedM.length
    ? `<div class='card'><div class='muted small' style='text-align:center;'>${fmt(showM.earnedAP)} AP earned of ${fmt(showM.totalAP)}</div>` + medalTable(unlockedM.map(m => ({ title: m.title, art: m.art })), (it) =>
      `<img src='${it.art}' width='48' height='48' alt='' border='0'><br><b>${esc(it.title || "")}</b>`) + `</div>`
    : `<div class='card'><div class='muted small' style='text-align:center;'>No medals yet — achievements unlock automatically in-game.</div></div>`)
  // MOTD window: skills + medals live on the Battle Pass / Achievements
  // pages, so compact drops both strips (their tabs stay one tap away).
  const skillsStrip = useCompact ? "" : await ownedSkillsCard(env, steamid)
  const medalsExtra = useCompact ? "" : medalsStrip
  const body = `${actMsg}${status}${missionsOverview(g)}${tabBar}${groups}${skillsStrip}${medalsExtra}${detail}`


  return html("MISSIONS", body, { steamid, compact: useCompact, product: "missions" })
}

// ============================================================ TOURNAMENT
export async function pageTournament(env, url) {
  const steamid = steamidOf(url)
  const token = await pageActionToken(env, url, steamid)
  const useCompact = isMotdCompact() || compact(url) === "1"
  const claimArg = url.searchParams.get("claim") || ""

  let claimMsg = ""
  if (claimArg && steamid && token) {
    const res = await queueAction(env, steamid, "claim_tournament", claimArg, token)
    if (res.ok) {
      claimMsg = `<div class='card'><div class='h2'>TOURNAMENT PRIZE CLAIM QUEUED</div>
        <p>Queued for the game server. Claim is processed in-game.</p>
      </div>`
    } else {
      claimMsg = `<div class='err'>${esc(res.error || "Could not queue tournament prize claim.")}</div>`
    }
  }

  let p = null
  let claimRecord = null
  if (steamid) {
    try {
      p = await env.DB.prepare(`SELECT * FROM players WHERE steamid = ?1`).bind(steamid).first()
    } catch {}
    try {
      claimRecord = await env.DB.prepare(
        `SELECT id, status, result, created_at FROM actions WHERE steamid = ?1 AND type = 'claim_tournament' ORDER BY created_at DESC LIMIT 1`
      ).bind(steamid).first()
    } catch {}
  }

  let rows
  try {
    rows = (await env.DB.prepare(
      `SELECT steamid, name, comp_points, comp_kills, comp_hs, comp_wins, comp_mvp,
              comp_msn_k, comp_msn_h, comp_msn_w, comp_msn_m, comp_msn_done, last_seen
       FROM players WHERE comp_points > 0 ORDER BY comp_points DESC, comp_kills DESC LIMIT 20`).all()).results
  } catch { return errorState("COMPETITIVE", "tournament", "tournament standings") }

  const now = Math.floor(Date.now() / 1000)

  let myPos = 0
  let isWinner = false
  let prizeTier = ""
  let prizeCoins = 0
  let prizeDesc = ""

  if (p) {
    try {
      const r = await env.DB.prepare(
        `SELECT COUNT(*) + 1 AS pos FROM players WHERE comp_points > ?1`
      ).bind(p.comp_points).first()
      myPos = r ? r.pos : 0
    } catch { myPos = 0 }

    const msnDone = [p.comp_msn_k >= 25, p.comp_msn_h >= 20, p.comp_msn_w >= 10, p.comp_msn_m >= 3].filter(Boolean).length
    const maskDone = [1, 2, 4, 8].filter(b => p.comp_msn_done & b).length
    const myStage = Math.max(msnDone, maskDone)
    const myCompleted = (p.comp_msn_done & 15) === 15

    if (p.comp_points > 0 || p.comp_wins > 0 || myCompleted) {
      if (myPos === 1) {
        isWinner = true
        prizeTier = "CHAMPION (#1)"
        prizeCoins = 10000
        prizeDesc = "Tournament Champion Trophy • [👑 TOURNAMENT CHAMPION] Title"
      } else if (myPos === 2) {
        isWinner = true
        prizeTier = "RUNNER-UP (#2)"
        prizeCoins = 5000
        prizeDesc = "Tournament Silver Medal • [ PREMIER MASTER ] Title"
      } else if (myPos === 3) {
        isWinner = true
        prizeTier = "PODIUM BRONZE (#3)"
        prizeCoins = 2500
        prizeDesc = "Tournament Bronze Medal • [ SUPREME MASTER ] Title"
      } else if (myPos <= 15 && myPos > 0) {
        isWinner = true
        prizeTier = `TOP 15 QUALIFIER (#${myPos})`
        prizeCoins = 1000
        prizeDesc = "Official Season Finalist • [ PRO ] Tag"
      } else if (myCompleted || myStage >= 4) {
        isWinner = true
        prizeTier = "DAILY STAGE GRAND SLAM"
        prizeCoins = 500
        prizeDesc = "All 4 Daily Competitive Missions Completed"
      } else if (p.comp_wins >= 5 || p.comp_points >= 100) {
        isWinner = true
        prizeTier = "COMPETITIVE VICTOR"
        prizeCoins = 250
        prizeDesc = "Competitive Match Victory Bonus"
      }
    }
  }

  let claimButtonHtml = ""
  if (steamid) {
    const isPending = claimRecord && (claimRecord.status === "pending" || claimRecord.status === "sent")
    const isDone = claimRecord && claimRecord.status === "done"

    if (isPending) {
      claimButtonHtml = `<span class='badge'>queued</span>`
    } else if (isDone) {
      claimButtonHtml = `<span class='badge done'>claimed</span>`
    } else if (isWinner) {
      // In-page claim action: carries the same token the rest of the page uses
      // (pageActionToken mints it locally — see sync.js mintActionToken).
      claimButtonHtml = token
        ? `<a href='/tournament?steamid=${encodeURIComponent(steamid)}&t=${encodeURIComponent(token)}&claim=${encodeURIComponent(prizeTier)}' class='badge done'>CLAIM PRIZE · ${fmt(prizeCoins)} COINS</a>`
        : `<span class='badge done'>CLAIM PRIZE · ${fmt(prizeCoins)} COINS</span>`
    } else {
      claimButtonHtml = `<span class='badge lock'>ineligible</span>`
    }
  }

  let meCard = ""
  if (steamid && p) {
    meCard = `<div class='card'><div class='h2'>COMPETITIVE</div>
      <table class='t' width='100%' cellspacing='0' cellpadding='6' border='0'>
        <tr><td class='k'>Player</td><td class='v'>${esc(p.name)} #${myPos > 0 ? myPos : "—"}</td></tr>
        <tr><td class='k'>Points</td><td class='v'>${fmt(p.comp_points)}</td></tr>
        <tr><td class='k'>Wins / Kills / MVP</td><td class='v'>${fmt(p.comp_wins)} / ${fmt(p.comp_kills)} / ${fmt(p.comp_mvp)}</td></tr>
        ${prizeTier ? `<tr><td class='k'>Prize</td><td class='v'>${esc(prizeTier)}${prizeDesc ? " · " + esc(prizeDesc) : ""}</td></tr>` : ""}
        <tr><td class='k'>Claim</td><td class='v'>${claimButtonHtml}</td></tr>
      </table>
    </div>`
  } else if (!steamid) {
    meCard = `<div class='card'><div class='h2'>OPEN FROM THE GAME</div>
      <p>Run <code>/pts</code> in chat.</p></div>`
  }

  // Lower-tier prize listing. Top-3 rewards ride the season podium above
  // (PLACES). The rest — including COMPETITIVE VICTOR — lives here so the
  // claimable ladder is complete and matches the game's claim_tournament
  // tiers exactly. No separate "PRIZE POOL" card (harness: pool card gone).
  const prizePoolCard = `
  <div class='card'><div class='h2'>Also up for grabs</div>
    <table class='t' width='100%' cellspacing='0' cellpadding='6' border='0'>
      <tr><td class='k'>TOP 15 QUALIFIERS</td><td class='v'>1,000 COINS</td></tr>
      <tr><td class='k'>4-STAGE GRAND SLAM</td><td class='v'>500 COINS</td></tr>
      <tr><td class='k'>COMPETITIVE VICTOR</td><td class='v'>250 COINS</td></tr>
    </table>
    <p class='muted small'>VICTOR: 5+ match wins or 100+ season points. Podium: 10,000 / 5,000 / 2,500 COINS. All prizes are claimed and paid in game.</p>
  </div>`

  // Season state machine. The data's modal comp_season decides: current
  // month -> RUNNING (podium vacant); past month with no new season yet ->
  // ENDED (top 3 frozen as winners). Purely derived, never guessed.
  const curD = new Date()
  const curMonth = `${curD.getFullYear()}-${String(curD.getMonth() + 1).padStart(2, "0")}`
  let modeSeason = ""
  try {
    const srows = ((await env.DB.prepare(
      `SELECT comp_season AS s FROM players WHERE comp_points > 0 LIMIT 200`).all()).results) || []
    const freq = {}
    for (const s of srows) if (s && s.s) freq[s.s] = (freq[s.s] || 0) + 1
    modeSeason = Object.keys(freq).sort((a, b) => freq[b] - freq[a])[0] || ""
  } catch {}
  const seasonEnded = !!modeSeason && modeSeason < curMonth
  const hasSeason = !!modeSeason
  const MON = ["JANUARY", "FEBRUARY", "MARCH", "APRIL", "MAY", "JUNE", "JULY", "AUGUST", "SEPTEMBER", "OCTOBER", "NOVEMBER", "DECEMBER"]
  const prettySeason = (m) => {
    const mt = String(m || "").match(/(\d{4})-(\d{2})/)
    return mt ? `${MON[Math.max(0, Math.min(11, num(mt[2]) - 1))]} ${mt[1]}` : "OFF-SEASON"
  }
  const dim = new Date(curD.getFullYear(), curD.getMonth() + 1, 0).getDate()
  const daysLeft = Math.max(0, dim - curD.getDate())
  const stateBadge = !hasSeason ? "<span class='badge'>OFF-SEASON</span>"
    : (seasonEnded ? "<span class='badge'>FINAL</span>" : "<span class='badge done'>LIVE</span>")
  // Event-period aggregates across the whole board (no LIMIT).
  let evt = { n: 0, pts: 0, kills: 0, hs: 0, wins: 0, mvp: 0 }
  try {
    evt = (await env.DB.prepare(
      `SELECT COUNT(*) AS n, SUM(comp_points) AS pts, SUM(comp_kills) AS kills, SUM(comp_hs) AS hs, SUM(comp_wins) AS wins, SUM(comp_mvp) AS mvp FROM players WHERE comp_points > 0`
    ).first()) || evt
  } catch {}
  const evtLeader = rows && rows[0]
    ? `<b>${esc(rows[0].name)}</b> <span class='muted'>${fmt(rows[0].comp_points)} pts</span>` : "<span class='muted'>-</span>"
  const seasonCard = `<div class='card'><div class='h2'>SEASON ${prettySeason(modeSeason || curMonth)} ${stateBadge}</div>`
    + `<table class='t' width='100%' cellspacing='0' cellpadding='6' border='0'>`
    + `<tr><td class='k'>Players in event</td><td class='v'>${fmt(evt.n)}</td>`
    + `<td class='k'>Points scored</td><td class='v'>${fmt(evt.pts)}</td></tr>`
    + `<tr><td class='k'>Event kills</td><td class='v'>${fmt(evt.kills)}</td>`
    + `<td class='k'>Event headshots</td><td class='v'>${fmt(evt.hs)}</td></tr>`
    + `<tr><td class='k'>Event wins</td><td class='v'>${fmt(evt.wins)}</td>`
    + `<td class='k'>Event MVPs</td><td class='v'>${fmt(evt.mvp)}</td></tr>`
    + `<tr><td class='k'>Leader</td><td class='v' colspan='3'>${evtLeader}</td></tr>`
    + `</table>`
    + (!hasSeason
      ? `<p class='muted'>No season data yet. The board fills at the next snapshot.</p>`
      : (seasonEnded
        ? `<p class='muted'>Season ${prettySeason(modeSeason)} ended. Winners below are locked until the next season's first snapshot.</p>`
        : `<p class='muted'>Season ends in ${daysLeft} day${daysLeft === 1 ? "" : "s"} - reset on the 1st. Every stat on this page is event-period only.</p>`))
    + `</div>`
  const PLACES = [
    ["GOLD - 1ST", "#e8c547", "10,000 COINS", "Champion Trophy + [TOURNAMENT CHAMPION] title"],
    ["SILVER - 2ND", "#b0c3d9", "5,000 COINS", "Silver Medal + [PREMIER MASTER] title"],
    ["BRONZE - 3RD", "#b08d57", "2,500 COINS", "Bronze Medal + [SUPREME MASTER] title"]
  ]
  const podCells = [0, 1, 2].map(i => {
    const w = (!seasonEnded || !rows) ? null : (rows[i] || null)
    const coin = (!w || isMotdCompact())
      ? ((!w && !isMotdCompact()) ? cs2Medal({ id: "level_52", title: "x", ap: 0 }, false, 56) : "")
      : cs2Medal({ id: "level_52", title: "FREENOVA LEGEND", ap: 1000, accent: PLACES[i][1] }, true, 56)
    const inner = w
      ? `<b>${esc(w.name)}</b><br><b style='color:${PLACES[i][1]};'>${PLACES[i][2]}</b><br><span class='muted small'>${PLACES[i][3]}</span>${(steamid && w.steamid === steamid) ? `<br>${claimButtonHtml}` : ""}`
      : `<b class='muted'>${!hasSeason ? "NO SEASON" : (seasonEnded ? "VACANT" : "DECIDED AT SEASON END")}</b>`
    return `<td width='33%' align='center' valign='top'><b style='color:${PLACES[i][1]};font-size:15px;'>${PLACES[i][0]}</b><br>${coin}<br>${inner}</td>`
  }).join("")
  const podiumCard = (rows && rows.length)
    ? `<div class='card'><div class='h2'>SEASON PODIUM</div>`
      + `<table width='100%' cellspacing='4' cellpadding='6' border='0'><tr>${podCells}</tr></table>`
      + `<p class='muted small'>Also up for grabs: Top-15 qualifier 1,000c &#183; Daily Grand Slam 500c &#183; Victor 250c.</p>`
      + `<p class='muted small'>This board is the monthly season, which runs itself. Short specials run on Events (in-game <code>/events</code>).</p></div>`
    : ""
  let rowsOut = ""
  let i = 0
  // MOTD window: top 10 with key columns only (# / Player / Points / Kills
  // / Wins / Progress) — the 10-column board slides at 620px. Claim buttons
  // live in the COMPETITIVE card above, so windowing drops no actions; a
  // same-product link opens the full board. Browser keeps all 20 x 10.
  const boardRows = useCompact ? rows.slice(0, 10) : rows
  for (const r of boardRows) {
    i++
    const msnDone = [r.comp_msn_k >= 25, r.comp_msn_h >= 20, r.comp_msn_w >= 10, r.comp_msn_m >= 3].filter(Boolean).length
    const maskDone = [1, 2, 4, 8].filter(b => r.comp_msn_done & b).length
    const stage = Math.max(msnDone, maskDone)
    const completed = (r.comp_msn_done & 15) === 15
    const status = completed ? "<span class='badge done'>COMPLETED</span>"
      : `<span class='badge'>STAGE ${stage}/4</span>`
    const isMe = steamid === r.steamid
    const meCls = isMe ? " you" : ""

    const inlineAction = ""

    rowsOut += useCompact ? `<tr class='${i <= 3 ? `r${i}` : ""}${meCls}'>
      <td class='c'>#${i}</td>
      <td><a href='/profile?steamid=${encodeURIComponent(r.steamid || "")}'>${esc(r.name)}</a></td>
      <td class='v'>${fmt(r.comp_points)}</td><td class='v'>${fmt(r.comp_kills)}</td>
      <td class='v'>${fmt(r.comp_wins)}</td>
      <td class='c'>${status}</td></tr>`
    : `<tr class='${i <= 3 ? `r${i}` : ""}${meCls}'>
      <td class='c'>#${i}</td>
      <td><a href='/profile?steamid=${encodeURIComponent(r.steamid || "")}'>${esc(r.name)}</a></td>
      <td class='v'>${fmt(r.comp_points)}</td><td class='v'>${fmt(r.comp_kills)}</td>
      <td class='v'>${fmt(r.comp_hs)}</td><td class='v'>${num(r.comp_kills) ? Math.round(100 * num(r.comp_hs) / num(r.comp_kills)) + "%" : "-"}</td>
      <td class='v'>${fmt(r.comp_wins)}</td><td class='v'>${fmt(r.comp_mvp)}</td>
      <td class='c'>${status}${inlineAction}</td>
      <td class='muted small'>${isOnline(r.last_seen, now) ? "online" : esc(ago(now - r.last_seen))}</td></tr>`
  }
  if (!rowsOut) rowsOut = emptyState("No tournament entries yet — points are scored every round in game.")

  const body = `${claimMsg}${seasonCard}${meCard}${podiumCard}${prizePoolCard}
  <div class='card'>
        <div class='h2'>TOP 15 - ${prettySeason(modeSeason || curMonth)} ${stateBadge} <span class='sub'>&nbsp;event-period stats, reset monthly</span></div>
    <table class='t'>
      <tr>${useCompact
        ? `<th class='c'>#</th><th>Player</th><th>Points</th><th>Kills</th><th>Wins</th><th>Progress</th>`
        : `<th class='c'>#</th><th>Player</th><th>Points</th><th>Kills</th><th>HS</th><th>HS%</th><th>Wins</th><th>MVP</th><th>Progress</th><th>Seen</th>`}</tr>
      ${rowsOut}
    </table>${useCompact && rows.length > boardRows.length
      ? `
    <p class='muted small'>Showing top ${boardRows.length} of ${rows.length} — <a href='/tournament${steamid ? "?steamid=" + encodeURIComponent(steamid) : ""}'>full board</a></p>`
      : ""}
    <p class='muted small'>Progress = event-period daily missions (kills / headshots / round wins / MVP). COMPLETED = all four done today. Kills, HS, wins and MVP count only during the event period.</p>
  </div>`
  return html("COMPETITIVE", body, { nav: "tournament", steamid, product: "tournament" })
}

// ============================================================ ACHIEVEMENTS
export async function pageAchievements(env, url) {
  const steamid = steamidOf(url)
  const useCompact = isMotdCompact() || url.searchParams.get("compact") === "1"
  const tab = (url.searchParams.get("tab") || "achievements").toLowerCase()
  const tabs = tabBar(
    [["achievements", "Medals"], ["hof", "Hall of Fame"], ["records", "Records"]],
    (tab === "hof" || tab === "halloffame") ? "hof" : (tab === "records" ? "records" : "achievements"),
    (k) => panelHref("achievements", steamid, k)
  )

  let ach = null
  try {
    const cat = await env.DB.prepare(`SELECT json FROM catalog WHERE key = 'achievements'`).first()
    if (cat && cat.json) ach = JSON.parse(cat.json)
  } catch {}
  if (!ach) ach = DEFAULT_ACHIEVEMENTS

  let hof = null
  try {
    const c = await env.DB.prepare(`SELECT json FROM catalog WHERE key = 'hall_of_fame'`).first()
    if (c && c.json) hof = JSON.parse(c.json)
  } catch {}
  if (!hof) hof = DEFAULT_HALL_OF_FAME

  if (tab === "hof" || tab === "halloffame") {
    const liveLeaders = []
    try {
      const mostXp = await env.DB.prepare(`SELECT steamid, name, xp, level FROM players ORDER BY xp DESC LIMIT 1`).first()
      const mostKills = await env.DB.prepare(`SELECT steamid, name, kills FROM players ORDER BY kills DESC LIMIT 1`).first()
      const mostHs = await env.DB.prepare(`SELECT steamid, name, headshots FROM players ORDER BY headshots DESC LIMIT 1`).first()
      const mostPts = await env.DB.prepare(`SELECT steamid, name, comp_points FROM players WHERE comp_points > 0 ORDER BY comp_points DESC LIMIT 1`).first()
      if (mostXp && num(mostXp.xp) > 0) liveLeaders.push({ title: "Highest XP", holder_name: mostXp.name, holder_steamid: mostXp.steamid, record_value: fmt(mostXp.xp) + " XP · L" + fmt(mostXp.level), season: "LIVE D1" })
      if (mostKills && num(mostKills.kills) > 0) liveLeaders.push({ title: "Most Career Kills", holder_name: mostKills.name, holder_steamid: mostKills.steamid, record_value: fmt(mostKills.kills) + " kills", season: "LIVE D1" })
      if (mostHs && num(mostHs.headshots) > 0) liveLeaders.push({ title: "Most Headshots", holder_name: mostHs.name, holder_steamid: mostHs.steamid, record_value: fmt(mostHs.headshots) + " HS", season: "LIVE D1" })
      if (mostPts && num(mostPts.comp_points) > 0) liveLeaders.push({ title: "Tournament Points Leader", holder_name: mostPts.name, holder_steamid: mostPts.steamid, record_value: fmt(mostPts.comp_points) + " pts", season: "LIVE D1" })
    } catch {}
    const lCards = liveLeaders.map(l => `
      <table class='card' width='100%' cellspacing='0' cellpadding='8' border='0' bgcolor='#1E2422'>
        <tr><td class='muted'>${esc(l.season)} LIVE</td></tr>
        <tr><td><b style='color:#36DEAB;font-size:16px;'>${esc(l.title)}</b></td></tr>
        <tr><td><b>${esc(l.holder_name)}</b> <span class='muted'>(${esc(l.holder_steamid)})</span></td></tr>
        <tr><td class='msn-rew'>${esc(l.record_value)}</td></tr>
      </table>`).join("")
    // Catalog examples: clearly badged EXAMPLE, never presented as live records.
    // MOTD window: illustrative cards drop out of compact (live holders and
    // the podium stay); the header note below still says where they live.
    const examples = Array.isArray(hof.hall_of_fame) ? hof.hall_of_fame : []
    const champCoin = { title: "FREENOVA LEGEND", ap: 1000 }
    const xCards = useCompact ? "" : examples.map(e => `
      <table class='card' width='100%' cellspacing='0' cellpadding='8' border='0' bgcolor='#1E2422'>
        <tr><td><span class='badge'>EXAMPLE</span> <span class='muted small'>${esc(e.season || "")} &#183; illustrative, not a live record</span></td></tr>
        <tr>
          ${isMotdCompact() ? "" : `<td width='72' valign='top' align='center'>${cs2Medal({ id: e.id, ...champCoin }, true, 56)}</td>`}
          <td valign='top'><b style='color:#e8c547;font-size:16px;'>${esc(e.title)}</b><br>
          <b>${esc(e.holder_name)}</b> <span class='muted'>(${esc(e.holder_steamid || "")})</span><br>
          <span class='msn-rew'>${esc(e.record_value)}</span></td>
        </tr>
      </table>`).join("")
    // Hardest-medal podium: top 3 by MEDAL-tier completions, then XP.
    // Earned dates derive in sync.js on ach_unlocked bit flips; pre-tracking
    // medals carry no date, so "first" still cannot be ordered honestly;
    // vacant slots invite the first finishers. Ordered by completions, then XP.
    const hofList = liveAchList(ach)
    // Live catalog entries carry no `type`; tier comes from the canonical set.
    const SHOWTYPE = {}
    for (const d of SHOWCASE) SHOWTYPE[d.id] = d.type
    const hardest = hofList.filter(a => SHOWTYPE[cs2Canon(a)] === "MEDAL")
    let podium = []
    try {
      const all = ((await env.DB.prepare(`SELECT steamid, name, xp, ach_unlocked FROM players`).all()).results) || []
      podium = all.map(r => {
        const bits = num(r.ach_unlocked)
        const got = hardest.filter(d => {
          const b = d.bit != null ? d.bit : LIVE_ACH_BITS[d.id]
          return b != null && (bits & (1 << b)) !== 0
        }).length
        return { name: r.name, steamid: r.steamid, xp: num(r.xp), got }
      }).filter(r => r.got > 0).sort((x, y) => y.got - x.got || y.xp - x.xp).slice(0, 3)
    } catch {}
    const PLACES = [["1ST", "#e8c547"], ["2ND", "#b0c3d9"], ["3RD", "#b08d57"]]
    const podCells = [0, 1, 2].map(i => {
      const q = podium[i]
      const coin = (q && !isMotdCompact())
        ? cs2Medal({ id: "level_52", title: "FREENOVA LEGEND", ap: 1000, accent: PLACES[i][1] }, true, 56)
        : ((!q && !isMotdCompact()) ? cs2Medal({ id: "level_52", title: "x", ap: 0 }, false, 56) : "")
      const inner = q
        ? `<b>${esc(q.name)}</b><br><span class='muted small'>${q.got}/${hardest.length} hardest &#183; ${fmt(q.xp)} XP</span>`
        : `<b class='muted'>VACANT</b><br><span class='muted small'>be the first to finish a hardest medal</span>`
      return `<td width='33%' align='center' valign='top'><b style='color:${PLACES[i][1]};font-size:16px;'>${PLACES[i][0]}</b><br>${coin}<br>${inner}</td>`
    }).join("")
    const podiumCard = hardest.length
      ? `<div class='card'><div class='h2'>HARDEST-MEDAL PODIUM</div>`
        + `<table width='100%' cellspacing='4' cellpadding='6' border='0'><tr>${podCells}</tr></table>`
        + `<p class='muted small'>First 3 by hardest-medal completions, then XP. Earned dates record automatically on unlock; medals earned before date tracking show no date.</p></div>`
      : ""
    const body = `${tabs}
    ${podiumCard}
    <div class='card ok'><div class='h2'>HALL OF FAME</div>
      <p class='muted'>Live holders from the server snapshot.</p>
    </div>
    ${lCards || `<p class='muted'>No live holders yet. Play on the server until the next snapshot, then refresh.</p>`}
    <div class='card'><div class='h2'>PAST SEASONS &#8212; EXAMPLES</div>
      <p class='muted'>Example layout. Real season champions will take these slots.</p>
      ${xCards || emptyState("No examples defined.")}</div>`
    return html("ACHIEVEMENTS", body, { nav: "achievements", steamid, product: "achievements" })
  }

  if (tab === "records") {
    const recs = (hof.server_records || hof.server_records_catalog || [])
    const byKey = {}
    for (const r of recs) if (r && r.key) byKey[r.key] = r
    // Live holders computed from real snapshot columns only. Categories the
    // snapshot cannot answer stay honestly pending - never guessed.
    let prow = []
    try { prow = ((await env.DB.prepare(`SELECT * FROM players`).all()).results) || [] } catch {}
    let wrow = []
    try {
      wrow = ((await env.DB.prepare(
        `SELECT w.slot AS slot, w.kills AS kills, p.name AS name FROM player_weapons w JOIN players p ON p.steamid = w.steamid`
      ).all()).results) || []
    } catch {}
    const bestP = (need, val, txt) => {
      let b = null
      for (const r of prow) {
        if (!need(r)) continue
        const v = val(r)
        if (v == null) continue
        if (!b || v > b.v) b = { v, t: txt(r, v), name: r.name }
      }
      return b
    }
    const bestW = (slot) => {
      let b = null
      for (const w of wrow) {
        if (num(w.slot) !== slot || num(w.kills) <= 0) continue
        if (!b || num(w.kills) > num(b.kills)) b = w
      }
      return b ? { name: b.name, t: fmt(b.kills) + " kills" } : null
    }
    const HOLDERS = {
      highest_rating: () => bestP(r => num(r.rating_x100) > 0, r => num(r.rating_x100), (r, v) => ratingStr(v) + " rating"),
      most_kills: () => bestP(r => num(r.kills) > 0, r => num(r.kills), (r, v) => fmt(v) + " kills"),
      highest_kd: () => bestP(r => num(r.deaths) >= 20, r => num(r.kills) / Math.max(1, num(r.deaths)), (r, v) => v.toFixed(2) + " K/D"),
      most_headshots: () => bestP(r => num(r.headshots) > 0, r => num(r.headshots), (r, v) => fmt(v) + " HS"),
      highest_hs_pct: () => bestP(r => num(r.kills) >= 100, r => num(r.headshots) / num(r.kills), (r, v) => (100 * v).toFixed(1) + " %"),
      longest_killstreak: () => bestP(
        r => (hasCol(r, "ach_streak") ? num(r.ach_streak) : num(r.bp_daily_streak)) > 0,
        r => (hasCol(r, "ach_streak") ? num(r.ach_streak) : num(r.bp_daily_streak)),
        (r, v) => fmt(v) + " streak"),
      most_mvps: () => bestP(r => num(r.mvps) > 0, r => num(r.mvps), (r, v) => fmt(v) + " MVPs"),
      most_ak_kills: () => bestW(0),
      most_awp_kills: () => bestW(2),
      most_deagle_kills: () => bestW(3),
      most_knife_kills: () => bestW(4),
      most_playtime: () => bestP(r => num(r.playtime_minutes) > 0, r => num(r.playtime_minutes),
        (r, v) => Math.floor(v / 60) + "h " + (v % 60) + "m")
    }
    const GROUPS = [
      { title: "COMBAT", color: "#eb4b4b", keys: ["highest_rating", "most_kills", "highest_kd", "highest_adr", "most_match_kills"] },
      { title: "PRECISION", color: "#5e98d9", keys: ["most_headshots", "highest_hs_pct", "most_wallbangs", "longest_killstreak"] },
      { title: "HONORS", color: "#e8c547", keys: ["most_1v5_clutches", "most_mvps"] },
      { title: "ARSENAL", color: "#8847ff", keys: ["most_ak_kills", "most_awp_kills", "most_deagle_kills", "most_knife_kills"] },
      { title: "DEDICATION", color: "#36DEAB", keys: ["most_playtime"] }
    ]
    const groupCards = GROUPS.map(g => {
      const cards = g.keys.map(k => {
        const def = byKey[k] || { name: k, unit: "" }
        const hold = HOLDERS[k] ? HOLDERS[k]() : null
        // MOTD window: unheld categories collapse to a count line — every
        // live holder stays visible, nothing is guessed either way.
        if (useCompact && !hold) return ""
        const line = hold
          ? `<b>${esc(hold.name)}</b><br><span class='msn-rew'>${esc(hold.t)}</span> <span class='badge done'>LIVE</span>`
          : `<span class='muted'>Tracked in-game &#8212; first holder lands at the next snapshot.</span>`
        return `<table class='card' width='100%' cellspacing='0' cellpadding='8' border='0' bgcolor='#1E2422'>`
          + `<tr><td><span class='badge'>${esc(def.unit || "")}</span></td></tr>`
          + `<tr><td><b style='font-size:15px;'>${esc(def.name)}</b></td></tr>`
          + `<tr><td>${line}</td></tr></table>`
      }).join("")
      const pending = useCompact ? g.keys.filter(k => !(HOLDERS[k] && HOLDERS[k]())).length : 0
      return `<div class='card'><div class='h2' style='color:${g.color};'>${g.title}</div>${cards}`
        + `${pending ? `<p class='muted small'>+${pending} more categor${pending === 1 ? "y" : "ies"} tracked in-game.</p>` : ""}</div>`
    }).join("")
    const body = `${tabs}
    <div class='card ok'><div class='h2'>SERVER RECORDS</div>
      <p class='muted'>Record holders read live from the server snapshot. Unheld categories are tracked in-game, never guessed.</p>
    </div>
    ${groupCards || emptyState("No record categories defined yet.")}`
    return html("ACHIEVEMENTS", body, { nav: "achievements", steamid, product: "achievements" })
  }

  const list = liveAchList(ach)
  const catFilter = (url.searchParams.get("cat") || "all").toLowerCase()
  const rarFilter = (url.searchParams.get("rar") || "all").toLowerCase()
  const previewId = url.searchParams.get("preview") || ""
  // Context-full link base (identity + compact/MOTD mode): every tab,
  // filter, and preview link below stays on it, so interacting never
  // flips compact<->browser, drops SteamID, or resets sibling filters.
  const achBase = navHref("achievements", steamid, isMotdCompact() || url.searchParams.get("compact") === "1")
  if (!steamid) {
    const fctx = { baseHref: achBase, cat: catFilter, rar: rarFilter }
    const cabinetItems = badgeCabinet(null, null).items.filter(i =>
      (catFilter === "all" || (i.category || achCategoryOf(i.id)) === catFilter) &&
      (rarFilter === "all" || (i.rarity || achRarityOf(i.id)) === rarFilter))
    const body = `${tabs}
    ${filterTabs(list, fctx)}
    <div class='card ok'><div class='h2'>OPEN FROM THE GAME</div>
      <p>Run <code>/achievements</code> in chat.</p>
    </div>
    <div class='h2'>BADGE CABINET — LIVE MEDALS (${cabinetItems.length}/${list.length})</div>
    <p class='muted'>Seasonal medals persist after their season unless marked temporary. Earned dates record from this season onward; older medals show “before date tracking”. Hover a badge 2 seconds for its story — click it on MOTD.</p>
    ${cabinetGallery(cabinetItems, { baseHref: achBase, preview: previewId, cat: catFilter, rar: rarFilter })
      || emptyState("No achievements match this filter.")}`
    return html("ACHIEVEMENTS", body, { nav: "achievements", product: "achievements" })
  }

  let p
  try { p = await env.DB.prepare(`SELECT * FROM players WHERE steamid = ?1`).bind(steamid).first() }
  catch { return errorState("ACHIEVEMENTS", "achievements", "player data") }
  if (!p) return notFound("ACHIEVEMENTS", "achievements", "This SteamID has no snapshot yet. Play a few minutes, then retry.")

  if (!list.length) return notFound("ACHIEVEMENTS", "achievements", "The achievements catalog is empty. The game server pushes its real achievement definitions during sync.")

  const earnedMap = await apUnlocksMap(env, steamid)
  const show = badgeCabinet(p, earnedMap)
  const fctx = { baseHref: achBase, cat: catFilter, rar: rarFilter }
  const cabItems = show.items.filter(i =>
    (catFilter === "all" || (i.category || achCategoryOf(i.id)) === catFilter) &&
    (rarFilter === "all" || (i.rarity || achRarityOf(i.id)) === rarFilter))
  const unlockedN = list.filter(a => achUnlockedOf(p, a, achProgressOf(p, a.metric || a.field))).length
  const body = `${tabs}
  ${filterTabs(list, fctx)}
  <div class='card ok'><div class='h2'>ACHIEVEMENTS</div>
    <table class='t'>
      <tr><td class='k'>Unlocked</td><td class='v'>${unlockedN} / ${list.length}</td></tr>
      <tr><td class='k'>AP earned</td><td class='v'>${fmt(show.earnedAP)} of ${fmt(show.totalAP)}</td></tr>
    </table>
    <p class='muted small'>Medals here are display. Coin rewards are granted once in-game. This page never pays coins/XP.</p>
  </div>
  <div class='h2'>BADGE CABINET - LIVE MEDALS (${cabItems.length}/${list.length})</div>
  <p class='muted'>Seasonal medals persist after their season unless marked temporary. Earned dates record from this season onward; older medals show “before date tracking”. Hover a badge 2 seconds for its story — click it on MOTD.</p>
  ${cabinetGallery(cabItems, { baseHref: achBase, preview: previewId, cat: catFilter, rar: rarFilter })
    || emptyState("No achievements match this filter.")}`
  return html("ACHIEVEMENTS", body, { nav: "achievements", steamid, product: "achievements" })
}

function humanizeVipRemaining(sec) {
  const s = num(sec)
  if (s < 60) return Math.max(1, s) + "s"
  if (s < 3600) return Math.floor(s / 60) + "m"
  if (s < 86400) {
    const h = Math.floor(s / 3600)
    const m = Math.floor((s % 3600) / 60)
    return m ? (h + "h " + m + "m") : (h + "h")
  }
  const d = Math.floor(s / 86400)
  const h = Math.floor((s % 86400) / 3600)
  return h ? (d + "d " + h + "h") : (d + "d")
}

export async function pageVip(env, url) {
  // Read-only page: tiers are granted in-game (fnvip nVault) and the web
  // never sells VIP, mints coins, or mutates anything — so viewing needs no
  // token. Identity resolves like profile/missions: the game-minted MOTD
  // stamp wins, else a valid ?steamid=. No steamid → the game-open view.
  const steamid = steamidOf(url)
  if (!steamid) return needSteamid("VIP", "store", "/vip", await recentPlayersHtml(env, "vip"))
  let p
  try { p = await env.DB.prepare(`SELECT * FROM players WHERE steamid = ?1`).bind(steamid).first() }
  catch { return errorState("VIP", "store", "VIP data") }
  if (!p) return notFound("VIP", "store", "This SteamID has no snapshot yet.")
  const tier = Math.max(0, Math.min(3, num(p.vip_tier)))
  const remaining = num(p.vip_remaining)
  const label = vipName(tier)
  const TCOL = ["#8a99a8", "#5e98d9", "#8847ff", "#e8c547"]
  const TEMB = ["level_25", "level_25", "vip_plus", "level_52"]
  const tcol = TCOL[tier]
  // Hero coin mirrors the LIVE snapshot tier: grey member coin at 0, tier
  // color + tier emblem above. Browser only; MOTD keeps text.
  const heroCoin = isMotdCompact() ? "" : cs2Medal(
    { id: TEMB[tier], title: tier >= 3 ? "FREENOVA LEGEND" : label, ap: tier >= 3 ? 1000 : 250, accent: tcol },
    tier > 0, 72)
  const xpB = ["", "+50%", "+100%", "+150%"][tier] || "-"
  const coinB = ["", "1.5x", "2.0x", "2.5x"][tier] || "-"
  const expiryLine = tier === 0 ? "No membership - earn VIP in-game"
    : (remaining === -1 ? "Permanent" : (remaining > 0 ? humanizeVipRemaining(remaining) + " left" : "Active (snapshot)"))
  // Perk tiers mirror freenova_vip.sma feature gates exactly: VIP(1) chat /
  // notices / TAB / kill bonus / defuse (+ shop + BP premium, both gated on
  // vip_tier >= 1); VIP+(2) spawn HP/AP+money, armory, model, damage HUD,
  // parachute; ELITE(3) multi-jump. Shop/BP rows verified in motdStoreBody
  // (vipOnly) and purchase flow (bpPremium = vip_tier > 0).
  const PERKS = [
    ["XP bonus", 1, xpB, ["+50%", "+100%", "+150%"]],
    ["Coin multiplier", 1, coinB, ["1.5x", "2.0x", "2.5x"]],
    ["Chat tag + TAB badge", 1, null, null],
    ["Join / leave notices", 1, null, null],
    ["Kill bonus (AP/cash/HS rewards)", 1, null, null],
    ["CT defuse kit", 1, null, null],
    ["Shop VIP skins", 1, null, null],
    ["Battle Pass premium track", 1, null, null],
    ["Spawn cash bonus ($1,000)", 2, null, null],
    ["Armory menu (/vmenu)", 2, null, null],
    ["VIP player model", 2, null, null],
    ["Bullet-damage HUD", 2, null, null],
    ["Parachute (hold E falling)", 2, null, null],
    ["Multi-jump (when server enables it)", 3, null, null]
  ]
  const activeN = PERKS.filter(k => tier >= k[1]).length
  // Tier groups: every perk appears ONCE, under the tier that unlocks it.
  // No YES-matrix repetition. Owned rows color in, locked rows stay gray.
  const perkRow = (k) => {
    const on = tier >= k[1]
    const name = on ? `<b style='color:#36DEAB;'>${esc(k[0])}</b>` : `<span class='muted'>${esc(k[0])}</span>`
    const st = on
      ? `<b style='color:#36DEAB;'>ACTIVE${k[2] ? " " + esc(k[2]) : ""}</b>`
      : `<span class='muted'>LOCKED</span>`
    return `<tr><td>${name}</td><td class='v' align='right'>${st}</td></tr>`
  }
  // Store tiers (fn-gaming.net/store.php?section=vip, verified Oct 2026):
  // VIP $3 / VIP Gold $4 / VIP Diamond $6 per month. Store order matches
  // game tier order 1:1. Manual purchase via staff, lifetime never expires.
  const STORE = {
    1: { alias: "VIP", from: "$3/mo" },
    2: { alias: "VIP Gold", from: "$4/mo" },
    3: { alias: "VIP Diamond", from: "$6/mo" }
  }
  const STORE_URL = "https://fn-gaming.net/store.php?section=vip"
  const useCompact = isMotdCompact() || compact(url) === "1"
  const groupCard = (t, gname, bonus, below) => {
    const members = PERKS.filter(k => k[1] === t)
    const owned = members.filter(k => tier >= k[1]).length
    const full = owned === members.length
    const coin = isMotdCompact() ? "" : cs2Medal(
      { id: TEMB[t], title: t >= 3 ? "FREENOVA LEGEND" : gname, ap: t >= 3 ? 1000 : 250, accent: TCOL[t] }, true, 40 + t * 8)
    const head = `<div class='card'><div class='h2' style='color:${TCOL[t]};'>${gname} `
      + (full ? `<span class='badge done'>OWNED</span>` : `<span class='muted small'>${owned}/${members.length}</span>`)
      + (tier === t ? ` <span class='badge done'>YOUR TIER</span>` : "") + `</div>`
    // MOTD window: only the viewer's own tier expands; sibling tiers
    // collapse to bonus + price + BUY + count with a full-list link.
    if (useCompact && t !== tier) {
      return head
        + `<p><b style='font-size:16px;'>${bonus}</b><br><span class='muted small'>${below}</span><br>`
        + `<b style='color:#e8c547;'>from ${STORE[t].from}</b> <span class='muted small'>Store: ${STORE[t].alias} · ${owned}/${members.length} perks</span> `
        + `<a href='${STORE_URL}'>BUY</a> · <a href='/vip${steamid ? "?steamid=" + encodeURIComponent(steamid) : ""}'>full list</a></p></div>`
    }
    return head
      + `<table width='100%' cellspacing='0' cellpadding='6' border='0'><tr>`
      + (coin ? `<td width='88' align='center' valign='top'>${coin}</td>` : "")
      + `<td valign='top'><b style='font-size:16px;'>${bonus}</b><br><span class='muted small'>${below}</span><br>`
      + `<b style='color:#e8c547;'>from ${STORE[t].from}</b> <span class='muted small'>Store: ${STORE[t].alias}</span> `
      + `<a href='${STORE_URL}'>BUY</a></td>`
      + `</tr></table>`
      + `<table class='t' width='100%' cellspacing='0' cellpadding='6' border='0'>`
      + members.map(perkRow).join("") + `</table></div>`
  }
  const expiryChip = tier === 0 ? `<span class='badge'>NO MEMBERSHIP</span>`
    : (remaining === -1 ? `<span class='badge done'>PERMANENT</span>`
      : (remaining > 0 ? `<span class='badge done'>${esc(humanizeVipRemaining(remaining))} LEFT</span>`
        : `<span class='muted'>Active (snapshot)</span>`))
  const body = `
  <div class='card'><div class='h2'>VIP STATUS - YOUR TIER</div>
    <table width='100%' cellspacing='0' cellpadding='6' border='0'><tr>
      ${heroCoin ? `<td width='88' align='center' valign='top'>${heroCoin}</td>` : ""}
      <td valign='top'><b style='font-size:24px;color:${tcol};'>${esc(label)}</b> <span class='badge${tier > 0 ? " done" : ""}'>${tier > 0 ? "CURRENT TIER" : "TIER 0 / 3"}</span><br>
      <span class='muted'>${esc(p.name)} &#183; ${esc(steamid)}</span><br>
      ${expiryChip}<br>
      <span class='muted small'>XP ${esc(xpB)} &#183; Coins ${esc(coinB)} &#183; ${activeN}/${PERKS.length} perks active</span></td>
    </tr></table>
  </div>
  ${groupCard(1, "VIP UNLOCKS", "+50% XP &#183; 1.5x coins", "8 perks - the foundation every member starts from.")}
  ${groupCard(2, "VIP+ ADDS", "+100% XP &#183; 2.0x coins", "5 new perks - includes all VIP unlocks.")}
  ${groupCard(3, "ELITE ADDS", "+150% XP &#183; 2.5x coins", "Multi-jump + maxed rates - includes everything below.")}
  <div class='card'><div class='h2'>GET VIP - OFFICIAL STORE</div>
    <table class='t' width='100%' cellspacing='0' cellpadding='6' border='0'>
      <tr><td><b>VIP</b> <span class='muted small'>in-game tier 1</span></td><td class='v'>$3/mo &#183; $8/3mo &#183; $15/6mo &#183; $45 lifetime</td></tr>
      <tr><td><b>VIP Gold</b> <span class='muted small'>in-game VIP+</span></td><td class='v'>$4/mo &#183; $11/3mo &#183; $21/6mo &#183; $63 lifetime</td></tr>
      <tr><td><b>VIP Diamond</b> <span class='muted small'>in-game Elite</span></td><td class='v'>$6/mo &#183; $17/3mo &#183; $33/6mo &#183; $99 lifetime</td></tr>
    </table>
    <table class='t' width='100%' cellspacing='0' cellpadding='6' border='0'>
      <tr><td class='k'>1</td><td>Pick a tier and duration at <a href='${STORE_URL}'>fn-gaming.net/store.php?section=vip</a></td></tr>
      <tr><td class='k'>2</td><td>Message staff on <a href='https://discord.gg/vuGaWjuX'>Discord</a> with the package and your game nickname.</td></tr>
      <tr><td class='k'>3</td><td>Staff apply it to your game account. No automatic billing, no surprises. Lifetime never expires.</td></tr>
    </table>
    <p class='muted'>Night Free-VIP windows grant VIP free while live.</p>
  </div>`
  return html("VIP", body, { nav: "vip", steamid, product: "vip" })
}

function motdStoreBody({ skins, skills, cos, catName, p, owned, steamid }) {
  const tabs = tabBar(
    [["featured", "All"], ["skins", "Skins"], ["skills", "Skills"], ["cosmetics", "Titles"]],
    catName,
    (k) => `/store?cat=${k}${steamid ? "&steamid=" + encodeURIComponent(steamid) : ""}&compact=1`
  )
  const hero = p
    ? `<div class='card'><div class='h2'>STORE PREVIEW</div>
        <table class='t' width='100%' cellspacing='0' cellpadding='6' border='0'>
          <tr><td class='k'>Player</td><td class='v'>${esc(p.name)}</td></tr>
          <tr><td class='k'>Coins</td><td class='v'>${fmt(p.coins)}</td></tr>
          <tr><td class='k'>VIP</td><td class='v'>${esc(vipName(p.vip_tier))}</td></tr>
          <tr><td class='k'>Level</td><td class='v'>${fmt(p.level)}</td></tr>
        </table>
        <p class='muted'>Read-only MOTD preview. Buy and equip in game: <code>/shop</code> or N menu. VIP: <code>/vip</code> · <code>/help</code>.</p>
      </div>`
    : `<div class='card'><div class='h2'>STORE PREVIEW</div>
        <p class='muted'>Read-only catalog. Buy in game with <code>/shop</code>. VIP: <code>/vip</code> · <code>/help</code>.</p>
      </div>`
  let tables = ""
  if (catName === "featured" || catName === "skills") {
    const rows = (skills || []).map(s => {
      const maxStage = s.max_stage || (s.stages ? s.stages.length : 3)
      const firstCost = (s.stages && s.stages[0] && s.stages[0].cost) ? s.stages[0].cost : s.price
      const curStage = (p && p.skills && typeof p.skills[s.id] === "number") ? p.skills[s.id] : 0
      const status = !p ? `Buy / Upgrade in /shop (${maxStage} stages)`
        : (curStage >= maxStage ? `<span class='green'>MAX STAGE ${maxStage}/${maxStage}</span>`
          : (curStage > 0 ? `<b>STAGE ${curStage}/${maxStage}</b> — upgrade in /shop`
            : `Buy / Upgrade in /shop (${maxStage} stages)`))
      return `<tr><td class='c'><img src='${skillArt(s)}' width='36' height='36' alt='' border='0'></td><td><b>${esc(s.name)}</b><br><span class='muted'>${esc(s.desc || "")}</span></td>
      <td class='v'>${fmt(firstCost)}c</td><td class='c'>${status}</td></tr>`
    }).join("")
    tables += `<div class='card'><div class='h2'>SKILLS (${(skills || []).length})</div>
      <table class='t' width='100%' cellspacing='0' cellpadding='6' border='0'>
        <tr><th></th><th>Skill</th><th class='v'>Price</th><th class='c'>Status</th></tr>
        ${rows || emptyState("No skills in the catalog yet.")}
      </table></div>`
  }
  if (catName === "featured" || catName === "skins") {
    const rows = (skins || []).map(s => {
      const own = owned && owned.has(`${s.grp}:${s.idx}`)
      const status = !p ? "PREVIEW" : (own ? "OWNED" : (s.vipOnly === 1 && num(p.vip_tier) < 1 ? "VIP REQ" : (s.bpLevel > num(p.level) ? "LEVEL " + s.bpLevel : fmt(s.price) + "c")))
      return `<tr><td><b>${esc(s.name)}</b><br><span class='muted'>${esc((s.grp || "").toUpperCase())}</span></td>
        <td class='v'>${fmt(s.price)}c</td><td class='c'>${esc(status)}</td></tr>`
    }).join("")
    tables += `<div class='card'><div class='h2'>SKINS (${(skins || []).length})</div>
      <table class='t' width='100%' cellspacing='0' cellpadding='6' border='0'>
        <tr><th>Skin</th><th class='v'>Price</th><th class='c'>Status</th></tr>
        ${rows || emptyState("No skins in the catalog yet.")}
      </table></div>`
  }
  if (catName === "featured" || catName === "cosmetics") {
    const titles = Object.values((cos && cos.chat_titles) || {})
    const rows = titles.map(t => `<tr><td><b>${esc(t.name)}</b><br><span class='muted'>${esc(t.desc || "")}</span></td>
      <td class='v'>${fmt(t.cost)}c</td><td class='c'>IN GAME</td></tr>`).join("")
    tables += `<div class='card'><div class='h2'>TITLES (${titles.length})</div>
      <table class='t' width='100%' cellspacing='0' cellpadding='6' border='0'>
        <tr><th>Title</th><th class='v'>Price</th><th class='c'>Status</th></tr>
        ${rows || emptyState("No titles in the catalog yet.")}
      </table></div>`
  }
  return `${tabs}${hero}${tables}`
}

function motdModelsBody({ p, models, mine }) {
  const rows = (models || []).map(m => {
    const o = mine && mine.get(m.id)
    let status = "PREVIEW"
    if (p) {
      if (o && o.forced) status = "ASSIGNED"
      else if (o && o.equipped) status = "EQUIPPED"
      else if (o) status = "OWNED"
      else if (m.vipTier > num(p.vip_tier)) status = vipName(m.vipTier) + " REQ"
      else if (m.bpLevel > num(p.level)) status = "LEVEL " + m.bpLevel + " REQ"
      else if (m.price > 0) status = fmt(m.price) + "c"
      else status = "RANK / VIP"
    }
    return `<tr><td><b>${esc(m.name)}</b><br><span class='muted'>${esc(m.team || "")}</span></td>
      <td class='v'>${m.price > 0 ? fmt(m.price) + "c" : "UNLOCK"}</td>
      <td class='c'>${esc(status)}</td></tr>`
  }).join("")
  const hero = p
    ? `<div class='card'><div class='h2'>MODELS PREVIEW</div>
        <table class='t' width='100%' cellspacing='0' cellpadding='6' border='0'>
          <tr><td class='k'>Player</td><td class='v'>${esc(p.name)}</td></tr>
          <tr><td class='k'>Coins</td><td class='v'>${fmt(p.coins)}</td></tr>
          <tr><td class='k'>Current</td><td class='v'>${esc(p.eq_model || "default")}</td></tr>
        </table>
        <p class='muted'>Read-only MOTD preview. Equip in game: <code>/models</code>.</p></div>`
    : `<div class='card'><div class='h2'>MODELS PREVIEW</div>
        <p class='muted'>Read-only catalog. Equip in game with <code>/models</code>.</p></div>`
  return `${hero}<div class='card'><div class='h2'>OPERATOR LOCKER (${(models || []).length})</div>
    <table class='t' width='100%' cellspacing='0' cellpadding='6' border='0'>
      <tr><th>Model</th><th class='v'>Price</th><th class='c'>Status</th></tr>
      ${rows || emptyState("No models in the catalog yet.")}
    </table></div>`
}

// ============================================================ STORE (unified: skins / models / skills / cosmetics / tags)
export async function pageStore(env, url) {
  const steamid = steamidOf(url)
  const catName = (url.searchParams.get("cat") || "featured").toLowerCase()
  const token = await pageActionToken(env, url, steamid)

  let skins = [], skills = []
  try {
    const c = await env.DB.prepare(`SELECT json FROM catalog WHERE key = 'skins'`).first()
    if (c && c.json) skins = (JSON.parse(c.json).skins || [])
  } catch {}
  if (!skins.length) skins = DEFAULT_SKINS.skins
  // Keep all skins for now; filter to purchasable-only after owned set is resolved
  // so players can see skins they already own even if bpLevel/vipOnly gated.
  const allSkins = skins

  try {
    const s = await env.DB.prepare(`SELECT json FROM catalog WHERE key = 'skills'`).first()
    if (s && s.json) skills = (JSON.parse(s.json).skills || [])
  } catch {}
  if (!skills.length) skills = DEFAULT_SKILLS.skills

  let cos = DEFAULT_COSMETICS
  try {
    const catCos = await env.DB.prepare(`SELECT json FROM catalog WHERE key = 'cosmetics'`).first()
    if (catCos && catCos.json) cos = JSON.parse(catCos.json)
  } catch {}

  if (isMotdCompact() || compact(url) === "1") {
    let p = null
    let owned = new Set()
    if (steamid) {
      try { p = await env.DB.prepare(`SELECT * FROM players WHERE steamid = ?1`).bind(steamid).first() } catch {}
      if (p) {
        try {
          owned = new Set(
            (await env.DB.prepare(`SELECT grp, skin FROM player_skins WHERE steamid = ?1`).bind(steamid).all()).results
              .map(r => `${r.grp}:${r.skin}`))
        } catch {}
        // owned skill stages (game snapshot) for the MOTD skills table
        try {
          const sk = (await env.DB.prepare(`SELECT skill, stage FROM player_skills WHERE steamid = ?1`).bind(steamid).all()).results || []
          if (sk.length) {
            p.skills = {}
            for (const row of sk) p.skills[row.skill] = num(row.stage)
          }
        } catch {}
      }
    }
    // Coin-sold rows + anything the player already owns (even BP/VIP gated)
    skins = allSkins.filter(s => s.price > 0 && (!s.vipOnly && !s.bpLevel || owned.has(`${s.grp}:${s.idx}`)))
    return html("STORE", motdStoreBody({ skins, skills, cos, catName, p, owned, steamid }), { nav: "store", steamid, compact: true })
  }

  const storeTabs = [
    ["featured", "★ All Items"],
    ["skins", "🔫 Weapon Skins"],
    ["skills", "⚡ Combat Skills"],
    ["cosmetics", "💬 Titles & Cosmetics"]
  ]
  const tabs = `<div class='tabs'>` + storeTabs.map(([cat, label]) =>
    cat === catName ? `<span>${label}</span>`
      : `<a href='/store?cat=${cat}${steamid ? `&steamid=${encodeURIComponent(steamid)}` : ""}${token ? `&t=${encodeURIComponent(token)}` : ""}'>${label}</a>`).join("") + `</div>`

  function getSkinRarity(name) {
    const lower = name.toLowerCase()
    if (lower.includes("howl") || lower.includes("dragon king")) return { cls: "rarity-covert", name: "COVERT" }
    if (lower.includes("knife") || lower.includes("bayonet") || lower.includes("talon")) return { cls: "rarity-gold", name: "KNIFE" }
    if (lower.includes("blaze") || lower.includes("redline")) return { cls: "rarity-restricted", name: "RESTRICTED" }
    return { cls: "rarity-milspec", name: "MIL-SPEC" }
  }

  if (!steamid) {
    const skinGroups = [...new Set(allSkins.filter(s => s.price > 0 && !s.vipOnly && !s.bpLevel).map(s => s.grp))]
    let body = `
    <div class='store-hero'>
      <div>
        <div style='display:flex;align-items:center;gap:8px;margin-bottom:6px;'>
          <span class='tier-badge tier-radiant'>★ FREENOVA TACTICAL ARMORY</span>
          <span class='tier-badge' style='border-color:var(--cyan);color:var(--cyan);'>SEASON 1 STORE</span>
        </div>
        <h2 style='font-family:var(--font-heading);font-size:24px;font-weight:800;color:#fff;margin-bottom:4px;letter-spacing:1px;'>
          ELITE WEAPON SKINS &amp; COMBAT SKILLS
        </h2>
        <p class='muted' style='max-width:560px;margin:0;'>
          Browse server-exclusive custom weapon skins, train multi-stage tactical perks, and inspect official CS2 chat titles. Purchases apply instantly in-game!
        </p>
      </div>
      <div class='store-hero-balance'>
        <div style='font-size:10px;color:var(--text-dim);text-transform:uppercase;letter-spacing:1px;font-weight:700;'>BROWSER PREVIEW</div>
        <div style='font-family:var(--font-heading);font-size:15px;font-weight:800;color:var(--lime);'>OPEN FROM THE GAME</div>
        <div style='font-size:10.5px;color:var(--text-muted);margin-top:2px;'>Type <code>/store</code> in CS 1.6</div>
      </div>
    </div>
    <div class='card ok' style='margin-bottom:14px;'><div class='h2'>OPEN FROM THE GAME</div>
      <p>This panel follows your in-game identity. Run the matching command (<code>/store</code>) from the in-game chat to buy or equip items with your coins.</p>
      <form method='GET' action='/store' style='margin-top:12px;display:flex;gap:8px;max-width:450px;'>
        <input type='text' name='steamid' placeholder='STEAM_0:1:12345678' style='flex:1;padding:8px 12px;background:#0D0F0E;border:1px solid rgba(46,191,146,0.25);color:#fff;border-radius:6px;'>
        <input type='submit' value='LOOKUP' style='padding:8px 16px;background:linear-gradient(135deg,#2EBF92,#0B6B4A);color:#000;font-weight:800;border:none;border-radius:6px;cursor:pointer;'>
      </form>
    </div>
    ${tabs}`

    if (catName === "featured" || catName === "skills") {
      const sCards = skills.map(s => `
        <div class='store-card rarity-legend'>
          <div class='store-card-header'>
            <span class='tier-badge tier-radiant' style='font-size:10px;'><img src='${skillArt(s)}' width='18' height='18' alt='' border='0'> SKILL</span>
            <span class='tier-badge' style='font-size:9px;'>MAX STAGE ${s.max_stage || 3}</span>
          </div>
          <div style='margin:10px 0 6px 0;'>
            <div class='store-card-title' style='color:var(--lime);'>${esc(s.name)}</div>
            <div class='store-card-sub'>${esc(s.desc)}</div>
          </div>
          ${s.stages && s.stages.length ? `
          <div style='background:rgba(0,0,0,0.4);padding:8px;border-radius:6px;font-size:10px;margin-bottom:8px;display:flex;flex-direction:column;gap:5px;'>
            ${s.stages.slice(0, 3).map(st => `
              <div>
                <div style='display:flex;justify-content:space-between;align-items:center;'>
                  <span style='color:#fff;font-weight:600;'>Stage ${st.stage}: ${esc(st.name || "")}</span>
                  <span style='color:var(--gold);'>${fmt(st.cost)}c</span>
                </div>
                ${st.desc ? `<div style='color:var(--text-dim);font-size:9.5px;margin-top:1px;'>${esc(st.desc)}</div>` : ""}
              </div>`).join("")}
          </div>` : ""}
          <div class='store-card-footer'>
            <div class='store-price'>🪙 ${fmt(s.price)} <span style='font-size:10px;color:var(--text-dim);'>COINS</span></div>
            <span class='btn-store btn-buy'>Buy / Upgrade in /shop</span>
          </div>
        </div>`).join("")
      body += `<div class='card'><div class='h2'>TACTICAL COMBAT SKILLS (${skills.length})</div>
        <div class='store-grid'>${sCards}</div></div>`
    }

    if (catName === "featured" || catName === "skins") {
      for (const g of skinGroups) {
        const inGrp = skins.filter(s => s.grp === g)
        if (!inGrp.length) continue
        const gCards = inGrp.map(s => {
          const rarity = getSkinRarity(s.name)
          return `
          <div class='store-card ${rarity.cls}'>
            <div class='store-card-header'>
              <span class='tier-badge' style='font-size:9.5px;'>${esc(s.grp.toUpperCase())}</span>
              <span class='tier-badge' style='font-size:9px;'>${rarity.name}</span>
            </div>
            <div class='store-card-img'>
              <img src='/i/skin_${esc(s.grp)}_${s.idx}.png' alt='${esc(s.name)}' border='0'>
            </div>
            <div class='store-card-title'>${esc(s.name)}</div>
            <div class='store-card-sub'>${s.vipOnly === 1 ? "★ VIP Elite Exclusive • " : ""}${s.bpLevel > 1 ? "Rank Level " + s.bpLevel + " Required • " : ""}First-person View &amp; World Model</div>
            <div class='store-card-footer'>
              <div class='store-price'>🪙 ${fmt(s.price)} <span style='font-size:10px;color:var(--text-dim);'>COINS</span></div>
              <span class='btn-store btn-buy'>${fmt(s.price)} COINS</span>
            </div>
          </div>`
        }).join("")
        body += `<div class='card'><div class='h2'>${esc(g.toUpperCase())} WEAPON SKINS</div>
          <div class='store-grid'>${gCards}</div></div>`
      }
    }

    if (catName === "featured" || catName === "cosmetics") {
      const titles = Object.values(cos.chat_titles || {})
      if (titles.length) {
        const tCards = titles.map(t => `
          <div class='store-card rarity-gold'>
            <div class='store-card-header'>
              <span class='tier-badge' style='border-color:${esc(t.color || "var(--gold)")};color:${esc(t.color || "var(--gold)")};font-size:9px;'>${esc(t.badge || "TITLE")}</span>
              <span class='tier-badge tier-radiant' style='font-size:9px;'>CS2 CHAT</span>
            </div>
            <div style='margin:10px 0 8px 0;'>
              <div style='font-family:var(--font-heading);font-size:17px;font-weight:800;color:${esc(t.color || "#fff")};'>${esc(t.name)}</div>
              <div class='store-card-sub'>${esc(t.desc || "Official in-game chat title prefix.")}</div>
            </div>
            <div class='store-card-footer'>
              <div class='store-price'>🪙 ${fmt(t.cost)} <span style='font-size:10px;color:var(--text-dim);'>COINS</span></div>
              <span class='btn-store btn-locked'>OPEN /SHOP IN GAME</span>
            </div>
          </div>`).join("")
        body += `<div class='card'><div class='h2'>CHAT TITLES &amp; COSMETICS (${titles.length})</div>
          <div class='store-grid'>${tCards}</div></div>`
      }
    }

    return html("STORE", body, { nav: "store" })
  }

  let p
  try { p = await env.DB.prepare(`SELECT * FROM players WHERE steamid = ?1`).bind(steamid).first() }
  catch { return errorState("STORE", "store", "store data") }
  if (!p) return notFound("STORE", "store", "This SteamID has no snapshot yet. Play a few minutes, then retry.")

  // Owned skill stages pushed by the game (player_skills) — the skill cards
  // read p.skills to show STAGE n/max + UPGRADE/MAX instead of PURCHASE.
  try {
    const sk = (await env.DB.prepare(`SELECT skill, stage FROM player_skills WHERE steamid = ?1`).bind(steamid).all()).results || []
    if (sk.length) {
      p.skills = {}
      for (const row of sk) p.skills[row.skill] = num(row.stage)
    }
  } catch {}

  const owned = new Set(
    (await env.DB.prepare(`SELECT grp, skin FROM player_skins WHERE steamid = ?1`).bind(steamid).all()).results
      .map(r => `${r.grp}:${r.skin}`))

  try {
    const sk = await env.DB.prepare(`SELECT skill, stage FROM player_skills WHERE steamid = ?1`).bind(steamid).all()
    p.skills = Object.fromEntries((sk.results || []).map(r => [r.skill, r.stage]))
  } catch {}
  // Apply skin filter here with owned bypass: coin-sold rows + anything player already owns
  skins = allSkins.filter(s => s.price > 0 && (!s.vipOnly && !s.bpLevel || owned.has(`${s.grp}:${s.idx}`)))

  // Handle ?buy=type:arg — queue the action then continue to render
  const buyParam = url.searchParams.get("buy") || ""
  if (buyParam && token) {
    const colonIdx = buyParam.indexOf(":")
    if (colonIdx > 0) {
      const bType = buyParam.slice(0, colonIdx).trim()
      const bArg  = buyParam.slice(colonIdx + 1).trim()
      const allowed = ["buy_skin", "buy_skill", "equip_skin", "set_tag", "unequip_tag"]
      if (allowed.includes(bType) && bArg) {
        try { await queueAction(env, steamid, bType, bArg, token) } catch {}
      }
    }
  }

  const status = await actionStatusLine(env, steamid)

  // buyLink: emit a real anchor so label text (PURCHASE / UPGRADE / EQUIP) is visible
  const buyLink = (type, arg, label) => {
    if (!token) return `<span class='muted'>Open /shop in-game</span>`
    const href = `/store?steamid=${encodeURIComponent(steamid)}&t=${encodeURIComponent(token)}&buy=${encodeURIComponent(type + ":" + arg)}`
    return `<a href='${href}' class='btn-store btn-buy'>${label}</a>`
  }

  const buyMsg = ``

  function skinCard(s) {
    const own = owned.has(`${s.grp}:${s.idx}`)
    const price = fmt(s.price)
    let action
    if (own) action = `<span class='badge done' style='margin-right:6px;'>OWNED</span> ` + buyLink("equip_skin", `${s.grp}:${s.idx}`, "EQUIP")
    else if (s.vipOnly === 1 && num(p.vip_tier) < 1) action = "<span class='btn-store btn-vip-req'>★ VIP REQUIRED</span>"
    else if (s.bpLevel > num(p.level)) action = `<span class='btn-store btn-locked'>🔒 LEVEL ${s.bpLevel} REQ</span>`
    else action = buyLink("buy_skin", `${s.grp}:${s.idx}`, `BUY — ${price} COINS`)

    const rarity = getSkinRarity(s.name)

    return `
    <div class='store-card ${rarity.cls}'>
      <div class='store-card-header'>
        <span class='tier-badge' style='font-size:9.5px;'>${esc(s.grp.toUpperCase())}</span>
        <span class='tier-badge' style='font-size:9px;'>${rarity.name}</span>
      </div>
      <div class='store-card-img'>
        <img src='/i/skin_${esc(s.grp)}_${s.idx}.png' alt='${esc(s.name)}'>
      </div>
      <div class='store-card-title'>${esc(s.name)}</div>
      <div class='store-card-sub'>${s.vipOnly === 1 ? "★ VIP Elite Exclusive • " : ""}${s.bpLevel > 1 ? "Rank Level " + s.bpLevel + " Required • " : ""}First-person &amp; World Model</div>
      <div class='store-card-footer'>
        <div class='store-price'>🪙 ${price} <span style='font-size:10px;color:var(--text-dim);'>COINS</span></div>
        <div>${action}</div>
      </div>
    </div>`
  }

  function skillCard(s) {
    const skillKey = s.id.replace(/-/g, '_')
    let curStage = 0
    if (p.skills && typeof p.skills[skillKey] === 'number') {
      curStage = p.skills[skillKey]
    } else if (url.searchParams.has('sk_' + skillKey)) {
      curStage = parseInt(url.searchParams.get('sk_' + skillKey), 10) || 0
    }

    const maxStage = s.max_stage || (s.stages ? s.stages.length : 3)
    const isMax = curStage >= maxStage
    const nextStageObj = s.stages && s.stages[curStage] ? s.stages[curStage] : null
    const nextCost = nextStageObj ? nextStageObj.cost : s.price

    let actionBtn = ''
    if (isMax) {
      actionBtn = `<span class='btn-store btn-owned'>✓ MAX LEVEL</span>`
    } else {
      actionBtn = buyLink("buy_skill", s.id, `${curStage === 0 ? "PURCHASE" : "UPGRADE"} • ${fmt(nextCost)} COINS`)
    }

    return `
    <div class='store-card rarity-legend'>
      <div class='store-card-header'>
        <span class='tier-badge tier-radiant' style='font-size:10px;'><img src='${skillArt(s)}' width='18' height='18' alt='' border='0'> SKILL</span>
        <span class='tier-badge ${isMax ? "tier-radiant" : ""}' style='font-size:9px;'>${isMax ? "★ MASTERED" : `STAGE ${curStage}/${maxStage}`}</span>
      </div>
      <div style='margin:10px 0 6px 0;'>
        <div class='store-card-title' style='color:var(--lime);'>${esc(s.name)}</div>
        <div class='store-card-sub'>${esc(s.desc)}</div>
      </div>
      ${s.stages && s.stages.length ? `
      <div style='background:rgba(0,0,0,0.4);padding:8px;border-radius:6px;font-size:10.5px;margin-bottom:8px;display:flex;flex-direction:column;gap:5px;'>
        ${s.stages.map(st => {
          const active = curStage >= st.stage
          const isNext = curStage === st.stage - 1
          return `
          <div>
            <div style='display:flex;justify-content:space-between;align-items:center;${active ? "color:var(--lime);" : isNext ? "color:#fff;font-weight:600;" : "color:var(--text-dim);"}'>
              <span>${active ? "✓ " : isNext ? "▸ " : ""}${st.stage}. ${esc(st.name || st.desc)}</span>
              <span style='color:${active ? "var(--lime)" : "var(--gold)"};font-size:10px;'>${active ? "OWNED" : fmt(st.cost) + "c"}</span>
            </div>
            ${st.desc && st.name ? `<div style='color:${active ? "rgba(46,191,146,0.7)" : "var(--text-dim)"};font-size:9.5px;padding-left:14px;margin-top:1px;'>${esc(st.desc)}</div>` : ""}
          </div>`
        }).join("")}
      </div>` : ""}
      <div class='store-card-footer'>
        <div class='store-price'>🪙 ${fmt(isMax ? s.price : nextCost)} <span style='font-size:10px;color:var(--text-dim);'>COINS</span></div>
        <div>${actionBtn}</div>
      </div>
    </div>`
  }

  const skinGroups = [...new Set(skins.map(s => s.grp))]
  let body = `
    <div class='store-hero'>
      <div>
        <div style='display:flex;align-items:center;gap:8px;margin-bottom:6px;'>
          <span class='tier-badge tier-radiant'>★ FREENOVA TACTICAL ARMORY</span>
          <span class='tier-badge' style='border-color:var(--gold);color:var(--gold);'>${esc(vipName(p.vip_tier)).toUpperCase()} STATUS</span>
        </div>
        <h2 style='font-family:var(--font-heading);font-size:24px;font-weight:800;color:#fff;margin-bottom:4px;letter-spacing:1px;'>
          ${esc(p.name)}'S ARSENAL &amp; SKINS
        </h2>
        <p class='muted' style='max-width:560px;margin:0;'>
          Purchases and equips are validated game-side. Your coins are verified and deducted in real time.
        </p>
      </div>
      <div class='store-hero-balance'>
        <div style='font-size:10px;color:var(--text-dim);text-transform:uppercase;letter-spacing:1px;font-weight:700;'>YOUR BALANCE</div>
        <div style='font-family:var(--font-heading);font-size:22px;font-weight:800;color:var(--gold);text-shadow:0 0 10px var(--gold-glow);'>
          🪙 ${fmt(p.coins)} <span style='font-size:12px;color:#fff;'>COINS</span>
        </div>
        <div style='font-size:10.5px;color:var(--lime);font-weight:700;margin-top:2px;'>LEVEL ${fmt(p.level)} RECRUIT</div>
      </div>
    </div>
    ${buyMsg}${status}
    ${tabs}`

  if (catName === "featured" || catName === "skills") {
    body += `<div class='card'><div class='h2'>TACTICAL COMBAT SKILLS (${skills.length})</div>
      <div class='store-grid'>${skills.map(skillCard).join("") || emptyState("No skills in the catalog yet.")}</div></div>`
  }
  if (catName === "featured" || catName === "skins") {
    for (const g of skinGroups) {
      const inGrp = skins.filter(s => s.grp === g)
      if (!inGrp.length) continue
      body += `<div class='card'><div class='h2'>${esc(g.toUpperCase())} WEAPON SKINS</div>
        <div class='store-grid'>${inGrp.map(skinCard).join("")}</div></div>`
    }
  }
  if (catName === "featured" || catName === "cosmetics") {
    const titles = Object.values(cos.chat_titles || {})
    if (titles.length) {
      const tCards = titles.map(t => {
        const tag = String(t.tag || t.name || "").slice(0, 48)
        const action = token
          ? buyLink("set_tag", tag, `EQUIP — ${fmt(t.cost)}c`)
          : `<span class='muted'>Open /shop from the game to equip</span>`
        return `
        <div class='store-card rarity-gold'>
          <div class='store-card-header'>
            <span class='tier-badge' style='border-color:${esc(t.color || "var(--gold)")};color:${esc(t.color || "var(--gold)")};font-size:9px;'>${esc(t.badge || "TITLE")}</span>
            <span class='tier-badge tier-radiant' style='font-size:9px;'>CS2 CHAT</span>
          </div>
          <div style='margin:10px 0 8px 0;'>
            <div style='font-family:var(--font-heading);font-size:17px;font-weight:800;color:${esc(t.color || "#fff")};'>${esc(t.name)}</div>
            <div class='store-card-sub'>${esc(t.desc || "Official in-game chat title prefix.")}</div>
          </div>
          <div class='store-card-footer'>
            <div class='store-price'>🪙 ${fmt(t.cost)} <span style='font-size:10px;color:var(--text-dim);'>COINS</span></div>
            <div>${action}</div>
          </div>
        </div>`
      }).join("")
      body += `<div class='card'><div class='h2'>CHAT TITLES &amp; COSMETICS (${titles.length})</div>
        <div class='store-grid'>${tCards}</div>
        ${token ? `<p class='muted small'>${buyLink("unequip_tag", "-", "CLEAR TAG")}</p>` : ""}
        <p class='muted small'>Game re-checks the tag license before apply. Coins for titles are spent in-game via <code>/cosmetics</code> if the queue rejects.</p></div>`
    }
  }

  return html("STORE", body, { nav: "store", steamid })
}

// ============================================================ MODELS (player model catalog)
export async function pageModels(env, url) {
  const steamid = steamidOf(url)
  const token = await pageActionToken(env, url, steamid)

  let catalog = null
  try {
    const c = await env.DB.prepare(`SELECT json FROM catalog WHERE key = 'models'`).first()
    if (c && c.json) catalog = JSON.parse(c.json)
  } catch {}
  if (!catalog || !catalog.models || !catalog.models.length) catalog = DEFAULT_MODELS

  if (isMotdCompact() || compact(url) === "1") {
    let p = null
    let mine = new Map()
    if (steamid) {
      try { p = await env.DB.prepare(`SELECT * FROM players WHERE steamid = ?1`).bind(steamid).first() } catch {}
      if (p) {
        try {
          mine = new Map(
            (await env.DB.prepare(`SELECT model, equipped, forced FROM player_models WHERE steamid = ?1`).bind(steamid).all())
              .results.map(r => [r.model, r]))
        } catch {}
      }
    }
    return html("PLAYER MODELS", motdModelsBody({ p, models: catalog.models || [], mine }), { nav: "models", steamid, compact: true })
  }

  function getModelCard(m, action) {
    const isCt = (m.team || "").toLowerCase().includes("ct") || (m.team || "").toLowerCase().includes("counter")
    const isT = (m.team || "").toLowerCase().includes("t") || (m.team || "").toLowerCase().includes("terror")
    const teamBadge = isCt
      ? "<span class='tier-badge tier-global'>COUNTER-TERRORIST</span>"
      : (isT ? "<span class='tier-badge tier-radiant' style='border-color:var(--red);color:var(--red);'>TERRORIST</span>" : "<span class='tier-badge tier-gold'>ALL TEAMS</span>")
    const borderCls = isCt ? "rarity-restricted" : (isT ? "rarity-covert" : "rarity-gold")

    return `
    <div class='store-card ${borderCls}'>
      <div class='store-card-header'>
        ${teamBadge}
        <span class='tier-badge' style='font-size:9px;'>${m.vipTier ? esc(vipName(m.vipTier)).toUpperCase() : "OPERATOR"}</span>
      </div>
      <div class='store-card-img' style='height:140px;'>
        <img src='/i/model_${esc(m.id)}.png' alt='${esc(m.name)}' style='max-height:120px;' border='0'>
      </div>
      <div class='store-card-title'>${esc(m.name)}</div>
      <div class='store-card-sub'>Official Server Operator Model • Applies instantly on your next round spawn</div>
      <div class='store-card-footer'>
        <div class='store-price'>${m.price > 0 ? `🪙 ${fmt(m.price)} <span style='font-size:10px;color:var(--text-dim);'>COINS</span>` : `<span style='color:var(--lime);font-size:12px;font-weight:700;'>RANK / VIP</span>`}</div>
        <div>${action}</div>
      </div>
    </div>`
  }

  if (!steamid) {
    const rows = (catalog.models || []).map(m => getModelCard(m, `<span class='btn-store btn-buy'>${m.price > 0 ? fmt(m.price) + " COINS" : "RANK UNLOCK"}</span>`)).join("")
    const body = `
    <div class='store-hero'>
      <div>
        <div style='display:flex;align-items:center;gap:8px;margin-bottom:6px;'>
          <span class='tier-badge tier-radiant'>★ SPECIAL OPERATIONS LOCKER</span>
          <span class='tier-badge' style='border-color:var(--cyan);color:var(--cyan);'>PLAYER MODELS</span>
        </div>
        <h2 style='font-family:var(--font-heading);font-size:24px;font-weight:800;color:#fff;margin-bottom:4px;letter-spacing:1px;'>
          CUSTOM AGENT OPERATORS
        </h2>
        <p class='muted' style='max-width:560px;margin:0;'>
          Elite VIP Guardian and Syndicate operator models. Server assignments in <code>player_models.ini</code> take unconditional priority.
        </p>
      </div>
      <div class='store-hero-balance'>
        <div style='font-size:10px;color:var(--text-dim);text-transform:uppercase;letter-spacing:1px;font-weight:700;'>BROWSER PREVIEW</div>
        <div style='font-family:var(--font-heading);font-size:15px;font-weight:800;color:var(--lime);'>OPEN FROM THE GAME</div>
        <div style='font-size:10.5px;color:var(--text-muted);margin-top:2px;'>Type <code>/models</code> in CS 1.6</div>
      </div>
    </div>
    <div class='card ok'><div class='h2'>OPEN FROM THE GAME</div>
      <p>This panel follows your in-game identity. Run the matching command (<code>/models</code>) from the in-game chat to equip or manage your player model.</p>
      <form method='GET' action='/models' style='margin-top:12px;display:flex;gap:8px;max-width:450px;'>
        <input type='text' name='steamid' placeholder='STEAM_0:1:12345678' style='flex:1;padding:8px 12px;background:#0D0F0E;border:1px solid rgba(46,191,146,0.25);color:#fff;border-radius:6px;'>
        <input type='submit' value='LOOKUP' style='padding:8px 16px;background:linear-gradient(135deg,#2EBF92,#0B6B4A);color:#000;font-weight:800;border:none;border-radius:6px;cursor:pointer;'>
      </form>
    </div>
    <div class='card'><div class='h2'>OPERATOR LOCKER (${(catalog.models || []).length})</div>
      <div class='store-grid'>${rows}</div>
    </div>`
    return html("PLAYER MODELS", body, { nav: "models" })
  }

  let p
  try { p = await env.DB.prepare(`SELECT * FROM players WHERE steamid = ?1`).bind(steamid).first() }
  catch { return errorState("PLAYER MODELS", "models", "model data") }
  if (!p) return notFound("PLAYER MODELS", "models", "This SteamID has no snapshot yet. Play a few minutes, then retry.")

  const mine = new Map(
    (await env.DB.prepare(`SELECT model, equipped, forced FROM player_models WHERE steamid = ?1`).bind(steamid).all())
      .results.map(r => [r.model, r]))

  const status = await actionStatusLine(env, steamid)
  const buyLink = (type, arg, label) => {
    const isEquip = type.includes("equip")
    const isUnequip = type.includes("unequip")
    const cls = isUnequip ? "btn-store btn-unequip" : (isEquip ? "btn-store btn-equip" : "btn-store btn-buy")
    return `<a href='/models?steamid=${encodeURIComponent(steamid)}&t=${encodeURIComponent(token)}&act=${type}:${encodeURIComponent(arg)}' class='${cls}'><b>${esc(label)}</b></a>`
  }

  const act = url.searchParams.get("act") || ""
  let actMsg = ""
  if (act && token) {
    const [type, arg] = act.split(":")
    const modelAllowed = ["buy_model", "equip_model", "unequip_model"]
    const res = modelAllowed.includes(type)
      ? await queueAction(env, steamid, type, arg || "", token)
      : { ok: false, error: "unknown action" }
    actMsg = res.ok
      ? `<div class='card ok'><span class='green'>Request queued — the game server will validate and apply it within a minute.</span></div>`
      : `<div class='err'>${esc(res.error || "Could not queue the request.")}</div>`
  }

  let cards = ""
  for (const m of (catalog.models || [])) {
    const o = mine.get(m.id)
    const forced = o && o.forced
    let action
    if (forced) action = "<span class='btn-store btn-owned'>ASSIGNED TO YOU</span>"
    else if (o && o.equipped) action = buyLink("unequip_model", m.id, "UNEQUIP")
    else if (o) action = buyLink("equip_model", m.id, "EQUIP")
    else if (m.vipTier > num(p.vip_tier)) action = `<span class='btn-store btn-vip-req'>${esc(vipName(m.vipTier))} REQUIRED</span>`
    else if (m.bpLevel > num(p.level)) action = `<span class='btn-store btn-locked'>LEVEL ${m.bpLevel} REQ</span>`
    else if (m.price > 0) action = buyLink("buy_model", m.id, `BUY — ${fmt(m.price)} COINS`)
    else action = "<span class='btn-store btn-locked'>UNAVAILABLE</span>"

    cards += getModelCard(m, action)
  }

  const body = `
  <div class='store-hero'>
    <div>
      <div style='display:flex;align-items:center;gap:8px;margin-bottom:6px;'>
        <span class='tier-badge tier-radiant'>★ SPECIAL OPERATIONS LOCKER</span>
        <span class='tier-badge' style='border-color:var(--gold);color:var(--gold);'>${esc(vipName(p.vip_tier)).toUpperCase()} AGENT</span>
      </div>
      <h2 style='font-family:var(--font-heading);font-size:24px;font-weight:800;color:#fff;margin-bottom:4px;letter-spacing:1px;'>
        ${esc(p.name)}'S OPERATOR LOCKER
      </h2>
      <p class='muted' style='max-width:560px;margin:0;'>
        Models equipped here apply automatically on your next round spawn. Assigned models from <code>player_models.ini</code> always take highest priority.
      </p>
    </div>
    <div class='store-hero-balance'>
      <div style='font-size:10px;color:var(--text-dim);text-transform:uppercase;letter-spacing:1px;font-weight:700;'>WALLET</div>
      <div style='font-family:var(--font-heading);font-size:20px;font-weight:800;color:var(--gold);'>🪙 ${fmt(p.coins)} COINS</div>
      <div style='font-size:10.5px;color:var(--lime);font-weight:700;margin-top:2px;'>CURRENT: ${esc(p.eq_model || "DEFAULT CS 1.6")}</div>
    </div>
  </div>
  ${actMsg}${status}
  <div class='card'><div class='h2'>OPERATOR LOCKER (${(catalog.models || []).length})</div>
    <div class='store-grid'>${cards || emptyState("No models in the catalog yet.")}</div>
  </div>`
  return html("PLAYER MODELS", body, { nav: "models", steamid })
}

function eventKey(e) {
  return String(e.id || e.name || "").toLowerCase().replace(/[^a-z0-9_]+/g, "_")
}

function eventMetricKey(e) {
  const m = String(e.metric || "").toLowerCase()
  // Builder 2 defaults metric to 'none' on multiplier-only events. Never fold
  // that into the kills fallback or a boost event renders a fake personal goal.
  if (m === "none" || m === "boost" || m === "multiplier") return "none"
  if (m === "hs" || m === "headshots") return "headshots"
  if (m === "c4" || m === "plants") return "c4"
  if (m === "wins") return "wins"
  if (m === "mvp" || m === "mvps") return "mvps"
  if (m === "xp") return "xp"
  return "kills"
}

function playerEventScore(row, metric) {
  if (metric === "headshots") return num(row.headshots)
  if (metric === "c4") return num(row.ach_plants) + num(row.ach_defuses)
  if (metric === "wins") return num(row.wins)
  if (metric === "mvps") return num(row.mvps)
  if (metric === "xp") return num(row.xp)
  return num(row.kills)
}

// "YYYY-MM-DD HH:MM" -> epoch ms (UTC, the same frame mapDbEventRow writes).
// Returns null for anything that is not a date ("season", "", "monthly") so
// open-ended catalog rows are never treated as expired.
function parseEventEnds(s) {
  const m = String(s || "").match(/^(\d{4})-(\d{2})-(\d{2})(?:[ T](\d{2}):(\d{2}))?/)
  if (!m) return null
  const t = Date.UTC(num(m[1]), num(m[2]) - 1, num(m[3]), num(m[4] || 0), num(m[5] || 0))
  return Number.isFinite(t) && t > 0 ? t : null
}

function fmtEventWhen(ms) {
  return ms > 0 ? new Date(ms > 1e12 ? ms : ms * 1000).toISOString().slice(0, 16).replace("T", " ") : ""
}

// Server-time countdown for a card. "ends in Xd Xh" — plain text, no client JS.
function eventCountdown(ends, now) {
  const t = parseEventEnds(ends)
  if (t == null) return ""
  const left = t - now
  if (left <= 0) return "end time passed - awaiting close"
  const d = Math.floor(left / 86400000)
  const h = Math.floor(left / 3600000) % 24
  return `ends in ${d}d ${h}h`
}

function eventWindowText(h) {
  const s = fmtEventWhen(num(h.start_at))
  const e = fmtEventWhen(num(h.end_at))
  return `${s || "?"} - ${e || "?"}`
}

function eventHistoryCard(h) {
  const title = String(h.title || "").trim() || `Event ${fmt(h.event_id)}`
  // Fractional multipliers (1.5x) must survive display: num() is parseInt-based.
  const fnum = v => { const n = Number(v); return Number.isFinite(n) ? n : 0 }
  const fstr = n => String(Math.round(n * 100) / 100)
  const xp = fnum(h.xp_mult)
  const co = fnum(h.coins_mult)
  const mult = [xp > 1 ? `${fstr(xp)}x XP` : "", co > 1 ? `${fstr(co)}x Coins` : ""].filter(Boolean).join(" + ")
  const closed = fmtEventWhen(num(h.completed_at))
  const win = (h._winners || []).map(w => `#${w.pl} ${esc(w.nm)} (${fmt(w.sc)})`).join(" · ")
  return `<table class='card' width='100%' cellspacing='0' cellpadding='8' border='0' bgcolor='#1E2422'>
      <tr><td><b>${esc(title)}</b></td><td align='right'>COMPLETED</td></tr>
      <tr><td colspan='2' class='muted'>${esc(String(h.type || "event"))}</td></tr>
      <tr><td class='msn-rew'>${esc(mult || "No multiplier recorded")}</td><td class='muted'>${esc(eventWindowText(h))}</td></tr>
      ${win ? `<tr><td colspan='2'><b style='color:#e8c547;'>${win}</b></td></tr>` : ""}
      <tr><td colspan='2' class='msn-meta'><span>closed ${esc(closed || "?")} - settled in-game${win ? "" : ", no recorded winners"}</span></td></tr>
    </table>`
}

function mapDbEventRow(row) {
  const status = String(row.status || "").toLowerCase()
  const slug = String(row.slug || row.id || "")
  let ends = row.ends || ""
  if (row.end_at != null && row.end_at !== "") {
    const n = Number(row.end_at)
    if (Number.isFinite(n) && n > 0)
      ends = new Date(n > 1e12 ? n : n * 1000).toISOString().slice(0, 16).replace("T", " ")
  }
  const xpMult = row.xp_mult != null ? Number(row.xp_mult) : 0
  const coMult = row.coins_mult != null ? Number(row.coins_mult) : 0
  // Builder 2 adds metric/target/scope/reward in parallel. Every read uses a
  // `row.x || fallback` so a pre-Builder-2 table without those columns renders
  // exactly like before.
  const reward = row.reward || ""
  let bonus = reward || row.bonus || ""
  if (!bonus && (xpMult > 1 || coMult > 1))
    bonus = [xpMult > 1 ? `${xpMult}x XP` : "", coMult > 1 ? `${coMult}x Coins` : ""].filter(Boolean).join(" + ")
  return {
    id: slug,
    name: row.title || row.name || slug,
    desc: row.description || row.desc || "",
    active: status === "active",
    status: status || (row.active ? "active" : ""),
    metric: row.metric || "",
    target: row.target != null ? num(row.target) : 0,
    scope: row.scope || "global",
    reward,
    bonus,
    ends,
    type: String(row.type || ""),
    badge: row.badge || row.type || "EVENT"
  }
}

async function loadEventsList(env) {
  const live = []
  try {
    const { results } = await env.DB.prepare(
      `SELECT * FROM events WHERE status IN ('active','scheduled') ORDER BY start_at`
    ).all()
    if (results && results.length)
      live.push(...results.map(mapDbEventRow))
  } catch {}
  let catalog = []
  try {
    const c = await env.DB.prepare(`SELECT json FROM catalog WHERE key = 'events'`).first()
    if (c && c.json) {
      const ev = JSON.parse(c.json)
      if (Array.isArray(ev.events)) catalog = ev.events
    }
  } catch {}
  const ids = new Set(live.map(e => String(e.id)))
  const merged = live.length ? live.concat(catalog.filter(e => !ids.has(String(e.id || "")))) : catalog
  // Drop anything whose ends ("YYYY-MM-DD HH:MM") is parseably in the past:
  // the expired 2026-09 catalog cards must never render ACTIVE. Rows with no
  // ends (or an unparseable one, e.g. "season") are kept.
  const now = Date.now()
  return merged.filter(e => {
    const t = parseEventEnds(e.ends)
    return t == null || t > now
  })
}

// SQL column for an event metric. Same vocabulary as playerEventScore() below
// and BASELINE_EXPR in sync.js; anything unknown falls back to kills.
const EVENT_BOARD_SQL = {
  kills: "kills",
  headshots: "headshots",
  wins: "wins",
  mvps: "mvps",
  xp: "xp",
  c4: "(IFNULL(ach_plants,0)+IFNULL(ach_defuses,0))"
}

// Candidate set for an event board. It used to be ordered by kills for every
// metric, so a "most XP" / "most wins" / "most C4" event only ever considered
// the 100 players with the most kills: anyone outside that set could never
// appear, and the page told them "your rank: outside the top 10" from a
// truncated set. Ordering (and therefore truncating) by the event's own metric
// makes the board honest. The column is whitelisted - never request input.
async function loadEventBoardRows(env, metric) {
  const col = EVENT_BOARD_SQL[String(metric || "").toLowerCase()] || EVENT_BOARD_SQL.kills
  try {
    const { results } = await env.DB.prepare(
      `SELECT steamid, name, kills, headshots, wins, mvps, xp, coins, ach_plants, ach_defuses
       FROM players ORDER BY ${col} DESC LIMIT 100`).all()
    return results || []
  } catch { return [] }
}

function eventBoardSort(rows, metric) {
  return rows.slice().sort((a, b) => playerEventScore(b, metric) - playerEventScore(a, metric))
}

// Winners for a set of event_history event_ids, names joined from players.
// Never invented: only finalized rows written by settleEvent.
async function eventWinnersMap(env, ids) {
  const clean = [...new Set((ids || []).map(num).filter(n => n > 0))].slice(0, 50)
  if (!clean.length) return new Map()
  try {
    const { results } = await env.DB.prepare(
      `SELECT w.event_id AS eid, w.placement AS pl, w.score AS sc, COALESCE(p.name, w.steamid) AS nm
       FROM event_winners w LEFT JOIN players p ON p.steamid = w.steamid
       WHERE w.event_id IN (${clean.join(",")}) ORDER BY w.event_id, w.placement`
    ).all()
    const m = new Map()
    for (const r of results || []) {
      if (!m.has(r.eid)) m.set(r.eid, [])
      m.get(r.eid).push(r)
    }
    return m
  } catch { return new Map() }
}

async function eventHistoryRows(env, n) {
  try {
    const { results } = await env.DB.prepare(
      `SELECT * FROM event_history ORDER BY completed_at DESC LIMIT ${Math.max(1, Math.min(50, n))}`
    ).all()
    return results || []
  } catch { return [] }
}

// ============================================================ EVENTS
export async function pageEvents(env, url) {
  const steamid = steamidOf(url)
  let hh = null
  let p = null
  if (steamid) {
    try { p = await env.DB.prepare(`SELECT * FROM players WHERE steamid = ?1`).bind(steamid).first() }
    catch { p = null }
  }

  try {
    const m = await env.DB.prepare(`SELECT value FROM meta WHERE key = 'happy_hour'`).first()
    if (m) hh = m.value
  } catch {}

  // Live `events` table first. Catalog fallback only. Never DEFAULT_EVENTS (expired 2026-09-14 cards).
  const list = await loadEventsList(env)
  const openId = (url.searchParams.get("id") || "").toLowerCase()
  const open = list.find(e => eventKey(e) === openId || String(e.id || "").toLowerCase() === openId)

  // Same-product links only (isolation contract): identity + compact mode ride
  // on the base href, the filter/detail param is appended to it.
  const baseHref = steamid ? panelHref("events", steamid) : "/events"
  const withQ = (extra) => baseHref + (baseHref.includes("?") ? "&" : "?") + extra
  const nowMs = Date.now()
  const token = steamid ? await pageActionToken(env, url, steamid) : ""
  let actMsg = ""
  {
    // claim_event:<eid> pulls the viewer's pending game-side reward, if any.
    // Queued through the standard channel; the game revalidates and pays.
    const act = String(url.searchParams.get("act") || "")
    const m = act.match(/^claim_event:(\d{1,9})$/)
    if (m && steamid && token) {
      const res = await queueAction(env, steamid, "claim_event", m[1], token)
      actMsg = res.ok
        ? `<div class='card'><span class='green'>Reward claim queued - the game server pays it within a minute.</span></div>`
        : `<div class='err'>${esc(res.error || "Could not queue the claim.")}</div>`
    }
  }

  if (open) {
    const metric = eventMetricKey(open)
    const rawTarget = num(open.target)
    const isGoal = String(open.type || "").toLowerCase() === "community_goal"
    // Multiplier-only events (Builder 2 target=0 / missing) have no personal
    // progress to draw - never a broken bar over a zero target.
    const isBoost = rawTarget <= 0
    const measurable = rawTarget > 0 && metric !== "none"
    const mine = (p && measurable) ? playerEventScore(p, metric) : 0
    const minePct = measurable ? pct(mine, rawTarget) : 0
    // F5: every goal-type event gets the board (was community_goal only).
    let lb = ""
    let board = []
    if (isGoal || measurable) {
      board = eventBoardSort(await loadEventBoardRows(env, metric), metric === "none" ? "kills" : metric).slice(0, 10)
      lb = board.map((r, i) => `<tr>
      <td class='pos c'>${i < 3 ? `<img class='trophy' src='/medals/medal_0${i + 1}.png' width='19' height='22' alt='#${i + 1}'>` : `#${i + 1}`}</td>
      <td class='player'>${esc(r.name)}</td>
      <td class='v'>${fmt(playerEventScore(r, metric === "none" ? "kills" : metric))}</td>
    </tr>`).join("")
    }
    // F3: the viewer's personal progress + their rank #N on the board.
    let rankBit = ""
    if (p && board.length) {
      const idx = board.findIndex(r => String(r.steamid) === String(p.steamid))
      rankBit = idx >= 0
        ? `Your rank: <b>#${idx + 1}</b> among ${board.length} tracked players.`
        : `Your rank: outside the top ${board.length} so far.`
    }
    let progressCard = ""
    if (isBoost) {
      progressCard = `<div class='card'><div class='h2'>YOUR PROGRESS</div>
        <p class='muted'>boost only - no personal target. This event only multiplies what you earn while it is live.</p>
      </div>`
    } else if (measurable) {
      progressCard = `<div class='card'><div class='h2'>YOUR PROGRESS</div>
        <p class='msn-meta'><span>${p ? `<b>${fmt(mine)} / ${fmt(rawTarget)} (${minePct}%)</b>` : `Target ${fmt(rawTarget)} - open the panel from the game to track your progress.`}</span></p>
        ${p ? `${progressBar(minePct)}<p class='muted small'>${rankBit}</p>` : ""}
      </div>`
    } else {
      progressCard = `<div class='card'><div class='h2'>YOUR PROGRESS</div>
        <p class='muted'>Target ${fmt(rawTarget)} but no progress metric is set for this event - the panel will not guess your progress.</p>
      </div>`
    }
    const rewards = String(open.bonus || "Rewards are paid in-game when the owner confirms the event.").split(/[+•|/]/).map(s => s.trim()).filter(Boolean)
    const countdown = open.active ? eventCountdown(open.ends, nowMs) : ""
    const back = baseHref
    let claimCell = ""
    {
      // Winner-only claim: numeric DB event + recorded win + nothing paid yet.
      const eid = num(open.id)
      if (eid > 0 && p) {
        let w = null
        try {
          w = await env.DB.prepare(
            `SELECT placement, score FROM event_winners WHERE event_id=?1 AND steamid=?2`
          ).bind(eid, steamid).first()
        } catch { w = null }
        if (w) {
          let paid = null
          try {
            paid = await env.DB.prepare(
              `SELECT result FROM actions WHERE steamid=?1 AND type IN ('srv_event_reward','claim_event')
               AND (arg=?2 OR arg LIKE ?3) AND status = 'done'`
            ).bind(steamid, String(eid), `${eid}:%`).first()
          } catch { paid = null }
          const pendingRelay = paid && /pending/i.test(String(paid.result || ""))
          if (paid && !pendingRelay) {
            claimCell = `<div class='card'><span class='badge done'>claimed</span> <span class='muted small'>placement #${num(w.placement)} · ${fmt(w.score)}</span></div>`
          } else if (token) {
            claimCell = `<div class='card'><div class='h2'>CLAIM REWARD</div>`
              + `<p class='muted'>Placement #${num(w.placement)} · ${fmt(w.score)}. Pulls anything the game still holds for you.</p>`
              + `<a href='${withQ(`id=${encodeURIComponent(eventKey(open))}&act=claim_event:${eid}`)}&t=${encodeURIComponent(token)}' class='btn-store btn-buy'><b>CLAIM</b></a></div>`
          } else {
            claimCell = `<div class='card'><p class='muted'>Placement #${num(w.placement)} - open /events from the game to claim.</p></div>`
          }
        }
      }
    }
    const body = `${actMsg}
    <div class='card evt-card evt-kind-${eventKind(open)}'><table width='100%' cellspacing='0' cellpadding='0' border='0'><tr>
      <td width='64' valign='top'>${eventIcon(open, 52)}</td>
      <td valign='top'><a href='${back}'>All events</a>
      <div class='h2'>${esc(open.name)}</div></td></tr></table>
      <span class='badge ${open.active ? "done" : "lock"}'>${open.active ? "ACTIVE" : "INACTIVE"}</span>${countdown ? ` <span class='badge'>${esc(countdown)}</span>` : ""}
    </div>
    <div class='card'><div class='h2'>DETAILS</div>
      <p>${esc(open.desc || "No extra description in the catalog.")}</p>
      <p class='muted small'>Limited-time staff event - separate from the monthly Competitive season.</p>
      <table class='t'>
        <tr><td class='k'>Metric</td><td class='v'>${esc(metric === "none" ? "none (boost)" : metric)}</td></tr>
        <tr><td class='k'>Target</td><td class='v'>${isBoost ? "boost only - no personal target" : fmt(rawTarget)}</td></tr>
        <tr><td class='k'>Scope</td><td class='v'>${esc(open.scope || "global")}</td></tr>
        <tr><td class='k'>Ends</td><td class='v'>${esc(open.ends || "Until the owner closes it")}</td></tr>
        <tr><td class='k'>Type</td><td class='v'>${esc(open.badge || open.type || "EVENT")}</td></tr>
      </table>
    </div>
    ${progressCard}
    <div class='card'><div class='h2'>REWARDS</div>
      ${rewards.map(r => `<div class='msn-rew'>${esc(r)}</div>`).join("") || "<div class='muted'>No reward listed.</div>"}
      <p class='muted small'>The web never grants coins. Settlement is in-game after the snapshot.</p>
    </div>
    ${(isGoal || measurable) ? `<div class='card'><div class='h2'>TOP PLAYERS</div>
      <table class='t'><tr><th class='pos'>#</th><th>Player</th><th class='v'>${esc((metric === "none" ? "kills" : metric).toUpperCase())}</th></tr>
      ${lb || emptyState("No snapshots yet.")}</table>
    </div>` : ""}
    <div class='card'><div class='h2'>PRIZE BOX</div>
      <div class='msn-rew'>${esc(open.bonus || "In-game settlement")}</div>
    </div>
    ${claimCell}`
    return html("EVENTS", body, { nav: "events", steamid, product: "events" })
  }

  // ---- F4: same-page filter tabs (?show=active|upcoming|past|mine) ----
  const showParam = String(url.searchParams.get("show") || "").toLowerCase()
  const show = ["active", "upcoming", "past", "mine"].includes(showParam) ? showParam : ""
  const stateOf = (e) => {
    if (e.active) return "active"
    const t = parseEventEnds(e.ends)
    return (t != null && t > nowMs) ? "upcoming" : ""
  }
  const progressOf = (e) => {
    const metric = eventMetricKey(e)
    const rawTarget = num(e.target)
    const measurable = rawTarget > 0 && metric !== "none"
    const mine = (p && measurable) ? playerEventScore(p, metric) : 0
    return { metric, rawTarget, measurable, mine }
  }
  // F5: nearest-ending active event first; rows without a parseable end sort
  // after every dated one, and everything else keeps its load order.
  const sortKey = (e) => {
    if (!e.active) return Infinity
    const t = parseEventEnds(e.ends)
    return t == null ? Infinity : t
  }
  const ordered = list.map((e, i) => ({ e, i }))
    .sort((a, b) => (sortKey(a.e) - sortKey(b.e)) || (a.i - b.i))
    .map(x => x.e)
  let filtered = ordered
  if (show === "active") filtered = ordered.filter(e => stateOf(e) === "active")
  else if (show === "upcoming") filtered = ordered.filter(e => stateOf(e) === "upcoming")
  else if (show === "mine") filtered = p ? ordered.filter(e => progressOf(e).mine > 0) : []

  // One candidate set per distinct event metric, loaded up front: the query is
  // ordered and limited by that metric, so a "most XP" card can never be scored
  // off a top-100-by-kills slice. boardFor() stays synchronous because the card
  // renderer below is a plain .map().
  const boardCache = new Map()
  const boardFor = (metric) => {
    const m = metric === "none" ? "kills" : metric
    return boardCache.get(m) || []
  }
  if (show !== "past") {
    const wanted = new Set()
    for (const e of filtered) {
      const pr = progressOf(e)
      if (pr.measurable || String(e.type || "").toLowerCase() === "community_goal")
        wanted.add(eventMetricKey(e) === "none" ? "kills" : eventMetricKey(e))
    }
    for (const m of wanted) boardCache.set(m, eventBoardSort(await loadEventBoardRows(env, m), m))
  }

  let cards = ""
  let sectionNote = ""
  const winMap = await eventWinnersMap(env,
    (await eventHistoryRows(env, 30)).map(h => h.event_id))
  if (show === "past") {
    // COMPLETED comes from event_history only - the same rows the scheduler
    // and the admin cancel path write. Nothing is reconstructed.
    const hist = await eventHistoryRows(env, 30)
    for (const h of hist) h._winners = winMap.get(num(h.event_id)) || []
    cards = hist.map(eventHistoryCard).join("")
    sectionNote = `<p class='muted small'>Completed events come from the event archive written when staff close them.</p>`
  } else {
    cards = filtered.map(e => {
      const key = eventKey(e)
      const { metric, rawTarget, measurable, mine } = progressOf(e)
      const state = stateOf(e)
      const statusText = state === "active" ? "ACTIVE" : state === "upcoming" ? "UPCOMING" : "INACTIVE"
      const countdown = state === "active" ? eventCountdown(e.ends, nowMs) : ""
      // F1: ONE span with the percentage in parens. Two adjacent spans glued
      // into "0 / 1,0000%" when the narrow MOTD viewport squeezed them.
      const progressLine = measurable
        ? (p
          ? `<div class='msn-meta'><span>${fmt(mine)} / ${fmt(rawTarget)} (${pct(mine, rawTarget)}%)</span></div>`
          : `<div class='msn-meta'><span>Target ${fmt(rawTarget)}</span></div>`)
        : rawTarget > 0
          ? `<div class='msn-meta'><span>Target ${fmt(rawTarget)} - no progress metric set</span></div>`
          : `<div class='msn-meta'><span>boost only - no personal target</span></div>`
      let miniBoard = ""
      // MOTD window: card mini-boards duplicate the detail board one tap
      // away, so compact drops them (status, bonus, progress stay).
      if (measurable && !isMotdCompact()) {
        const top = boardFor(metric).slice(0, 3)
        if (top.length) miniBoard = `<tr><td colspan='3'><table class='t' width='100%' cellspacing='0' cellpadding='2' border='0'>
          <tr><th class='pos'>#</th><th>Top ${top.length}</th><th class='v'>${esc(metric.toUpperCase())}</th></tr>
          ${top.map((r, i) => `<tr><td class='pos c'>#${i + 1}</td><td class='player'>${esc(r.name)}</td><td class='v'>${fmt(playerEventScore(r, metric))}</td></tr>`).join("")}
        </table></td></tr>`
      }
      const href = withQ("id=" + encodeURIComponent(key))
      const kind = eventKind(e)
      return `<table class='card evt-card evt-kind-${kind}' width='100%' cellspacing='0' cellpadding='8' border='0' bgcolor='#1E2422'>
      <tr><td width='48' valign='top' align='center'>${eventIcon(e, 40)}</td><td><a href='${href}'><b>${esc(e.name)}</b></a></td><td align='right'>${statusText}</td></tr>
      <tr><td colspan='3' class='muted'>${esc(e.desc || "")}</td></tr>
      <tr><td class='msn-rew' colspan='2'>${esc(e.bonus || "")}</td><td class='muted'>${esc(e.ends || "")}</td></tr>
      ${countdown ? `<tr><td colspan='3' class='msn-meta'><span>${esc(countdown)}</span></td></tr>` : ""}
      <tr><td colspan='3'>${progressLine}</td></tr>${miniBoard}
    </table>`
    }).join("")
  }

  // F5: winners-history section, sourced from event_history only.
  let winners = ""
  if (show !== "past") {
    const histAll = (await eventHistoryRows(env, 10)).map(h => ({ ...h }))
    for (const h of histAll) h._winners = winMap.get(num(h.event_id)) || []
    // MOTD window: 5 latest + count link to the past tab (same rows).
    const hist = (isMotdCompact() && histAll.length > 5) ? histAll.slice(0, 5) : histAll
    const histExtra = hist.length < histAll.length
      ? `<p class='muted small'>+${histAll.length - hist.length} more closed events — <a href='${withQ("show=past")}'>past events</a></p>`
      : ""
    winners = `<div class='card'><div class='h2'>WINNERS HISTORY</div>
    <p class='muted small'>Closed events from the event archive. Winners come from the finalized settlement record, never guessed.</p>
    ${hist.length
      ? `<table class='t' width='100%' cellspacing='0' cellpadding='4' border='0'>
      <tr><th>Event</th><th>Winner</th><th>Window</th><th>Closed</th></tr>
      ${hist.map(h => {
        const w = (h._winners || [])[0]
        return `<tr><td>${esc(String(h.title || "").trim() || `Event ${fmt(h.event_id)}`)}</td>`
          + `<td>${w ? `<b style='color:#e8c547;'>${esc(w.nm)}</b> <span class='muted small'>${fmt(w.sc)}</span>` : "<span class='muted'>-</span>"}</td>`
          + `<td class='muted'>${esc(eventWindowText(h))}</td><td class='muted'>${esc(fmtEventWhen(num(h.completed_at)) || "?")}</td></tr>`
      }).join("")}
    </table>${histExtra}`
      : emptyState("No completed events yet.")}
    </div>`
  }

  const tabs = tabBar(
    [["", "All"], ["active", "Active"], ["upcoming", "Upcoming"], ["past", "Past"], ["mine", "Mine"]],
    show,
    (k) => k ? withQ("show=" + encodeURIComponent(k)) : baseHref
  )
  const noLiveCard = `<div class='card'><div class='h2'>NO LIVE EVENTS</div>
      <p class='muted'>Nothing running right now - events are announced on Discord and in-game. The monthly season never stops: Competitive board (in-game <code>/pts</code>).</p>
    </div>`
  const emptyCard = show === "upcoming"
    ? `<div class='card'><div class='h2'>NO UPCOMING EVENTS</div><p class='muted'>Nothing scheduled right now - staff open events on Discord and in-game.</p></div>`
    : show === "past"
      ? `<div class='card'><div class='h2'>NO COMPLETED EVENTS</div><p class='muted'>No event has been closed yet.</p></div>`
      : show === "mine"
        ? (p
          ? `<div class='card'><div class='h2'>NOT IN ANY EVENT</div><p class='muted'>No event shows progress above zero for you yet.</p></div>`
          : `<div class='card'><div class='h2'>OPEN FROM THE GAME</div><p class='muted'>Open the panel from the game (with your SteamID) to see your own event progress here.</p></div>`)
        : noLiveCard
  const happy = hh === "1"
  // Products never href each other (isolation contract): name the other
  // panel in text and point at its in-game command instead.
  const body = `
  <div class='card'><div class='h2'>LIMITED-TIME EVENTS</div>
    <p class='muted'>Short bursts run by staff - weekends, races, community goals with bespoke rewards. Not the league: the monthly points season lives on Competitive (in-game <code>/pts</code>).</p>
    <p class='muted'>Click an event for details, prize box, and the live board for that metric.</p>
    ${happy ? `<p class='msn-rew'>Happy Hour is currently flagged on the replica (2x XP on the game server).</p>` : ""}
    ${tabs}
  </div>
  ${sectionNote}
  ${cards || emptyCard}
  ${winners}`
  return html("EVENTS", body, { nav: "events", steamid, product: "events" })
}

export async function pageCompare(env, url) {
  const steamid = steamidOf(url) || url.searchParams.get("a") || ""
  const loc = steamid ? `/profile?steamid=${encodeURIComponent(steamid)}` : "/profile"
  return new Response(null, { status: 302, headers: { location: loc } })
}

export {
  pageActionToken,
  liveAchList, achRarityOf, achCategoryOf, apUnlocksMap, badgeCabinet, achArt,
  missionGroups, missionDone,
  eventKey, eventMetricKey, playerEventScore, parseEventEnds, eventCountdown,
  eventWindowText, fmtEventWhen, loadEventsList, loadEventBoardRows,
  eventBoardSort, eventWinnersMap, eventHistoryRows
}
