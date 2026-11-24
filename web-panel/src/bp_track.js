export const FREE_XP = { normal: 50, rare: 150, super_rare: 300, mythic: 750, legendary: 1500 }

export const FREE_COINS = {
  1:100,2:50,3:150,4:50,5:250,6:100,7:50,8:100,9:50,10:500,
  11:100,12:50,13:100,14:50,15:750,16:100,17:50,18:250,19:100,20:50,
  21:500,22:100,23:50,24:100,25:1000,26:100,27:50,28:500,29:100,30:750,
  31:100,32:50,33:100,34:50,35:500,36:100,37:50,38:100,39:50,40:750,
  41:200,42:100,43:200,44:100,45:1000,46:200,47:100,48:200,49:100,50:2000,
  51:5000,52:10000,53:500,54:500,55:2500,56:500,57:500,58:1000,59:1000,60:5000
}

// Premium-lane coin payout per tier, mirrored verbatim from the game:
// battlepass_core.sma `stock const g_iBpPremiumCoins[MAX_LEVELS + 1]` (line
// ~157). 0 means that tier pays a premium item/perk instead of coins, which is
// exactly what the server does (`BpPremiumExtraCoinsLane()` returns this value
// and ignores the lane for coins - lane modifiers change perks, not money).
//
// REVIEW.md §4.2 M8: this file used to carry a three-entry PREMIUM_TOTAL table,
// so premiumExtraCoins() answered "nothing" for 57 of the 60 tiers and every
// premium column on /battlepass read the same as the free one. The table below
// is the server's own numbers; keep it in step with battlepass_core.sma rather
// than inventing values here - the panel displays, the game pays.
export const PREMIUM_COINS = {
  1:150, 2:150, 3:225, 4:0, 5:300, 6:300, 7:375, 8:0, 9:450, 10:450,
  11:525, 12:0, 13:600, 14:600, 15:675, 16:0, 17:0, 18:750, 19:0, 20:0,
  21:0, 22:900, 23:975, 24:0, 25:0, 26:1050, 27:1125, 28:0, 29:1200, 30:1200,
  31:1275, 32:0, 33:0, 34:1350, 35:1425, 36:0, 37:0, 38:1500, 39:1575, 40:0,
  41:1650, 42:1650, 43:1725, 44:0, 45:0, 46:1800, 47:1875, 48:0, 49:0, 50:1950,
  51:2025, 52:0, 53:0, 54:2100, 55:0, 56:0, 57:0, 58:2250, 59:2325, 60:0,
}

export function premiumLaneName(lane) {
  if (lane >= 3) return "ELITE"
  if (lane >= 2) return "VIP+"
  if (lane >= 1) return "VIP"
  return "FREE"
}

// Raw premium-lane coin table lookup (0 outside 1..60). Kept separate from
// premiumExtraCoins() so a caller can tell "no premium payout" from "unknown".
export function premiumCoins(tier) {
  const t = Math.trunc(Number(tier))
  if (!Number.isFinite(t) || t < 1 || t > 60) return 0
  return PREMIUM_COINS[t] || 0
}

// Coins a premium lane pays ON TOP of the free lane at `tier`, straight from
// the server table above. `lane` is accepted for call-site compatibility and is
// deliberately not used: the game's coin table does not vary by lane.
export function premiumExtraCoins(tier, lane = 1) {
  const t = Math.trunc(Number(tier))
  if (!Number.isFinite(t) || t < 1 || t > 60) return 0
  const n = PREMIUM_COINS[t] || 0
  return n > 0 ? n : 0
}

// Battle-pass XP needed per tier: one source for every page (REVIEW.md §4.3).
// The live value is the `reward_track` catalog row the game pushes; 1000 is the
// fallback the tree has always used. profile.js used to hard-code 1000 instead.
export const BP_XP_PER_TIER_FALLBACK = 1000
export function xpPerTier(track) {
  const n = Number(track && track.xp_per_tier)
  return Math.max(1, Number.isFinite(n) && n > 0 ? n : BP_XP_PER_TIER_FALLBACK)
}

// ---- BattlePass XP / tier ledger (REVIEW.md §2.4 H1) -----------------------
// BattlePass XP is its own ledger on the game side (battlepass_core.sma keeps
// it in the `bpxp` key of the freenova_bp vault) and rank XP/level is a
// different counter. The curve below is the ONLY tier curve in the panel:
// tier 1 covers [0, need), tier N covers [(N-1)*need, N*need), capped at 60, so
// a player with 0 BP XP reads "tier 1, empty progress" - never tier 0, never
// NaN, never a rank-derived tier. It mirrors battlepass_core.sma
// BpTierFromXp()/BpXpPerTier() (`fn_bp_xp_per_tier`, default 1000).
export const BP_MAX_TIER = 60

export function bpTierFromXp(bpXp, need) {
  const per = Math.max(1, Number(need) || BP_XP_PER_TIER_FALLBACK)
  const xp = Number(bpXp)
  const safe = Number.isFinite(xp) && xp > 0 ? xp : 0
  return Math.min(BP_MAX_TIER, 1 + Math.floor(safe / per))
}

export function bpInto(bpXp, need) {
  const per = Math.max(1, Number(need) || BP_XP_PER_TIER_FALLBACK)
  const xp = Number(bpXp)
  const safe = Number.isFinite(xp) && xp > 0 ? xp : 0
  return safe % per
}

// A players row -> BP tier. The stored bp_tier wins (the game derived it from
// this same curve); with no tier we derive it from bp_xp; a row carrying
// neither is tier 1. Rank xp/level and bp_milestone are deliberately NOT read
// here: they are the counters §2.4 H1 conflated with BattlePass progress.
export function playerBpTier(p, need) {
  const t = Math.trunc(Number(p && p.bp_tier))
  if (Number.isFinite(t) && t >= 1) return Math.min(BP_MAX_TIER, t)
  return bpTierFromXp(p && p.bp_xp, need)
}

export const PERKS = {
  5: { key: "jumps", n: 1 },
  10: { key: "hp", n: 2 },
  15: { key: "xpboost", n: 1.5, sec: 1800 },
  20: { key: "sniper", n: 1 },
  25: { key: "title", n: 1 },
  30: { key: "tag", n: 1 },
  35: { key: "hp", n: 2 },
  40: { key: "spawn", n: 3 },
  45: { key: "xpboost", n: 2.0, sec: 1800 },
  48: { key: "chat_color", n: 1 },
  50: { key: "skin_flip", n: 1 },
  52: { key: "model_legend", n: 1 },
  54: { key: "chute", n: 1 },
  55: { key: "title", n: 11 },
  57: { key: "jumps", n: 1 },
  58: { key: "spawn", n: 5 },
  59: { key: "laststand", n: 1 },
  60: { key: "title", n: 6 }
}

export function premiumPerk(tier) { return PERKS[tier] || null }

export function RARITY_OF_BUILD() {
  const r = {}
  for (let t = 1; t <= 60; t++) r[t] = "normal"
  for (const t of [5,10,15,20,35,48,53,54,56,57]) r[t] = "rare"
  for (const t of [25,30,40,45,58,59]) r[t] = "super_rare"
  for (const t of [50,51,55]) r[t] = "mythic"
  r[52] = "legendary"; r[60] = "legendary"
  return r
}
export const RARITY_OF = RARITY_OF_BUILD()
export function starOf(rarity) { return rarity === "normal" ? "white" : "gold" }
export function cellClass(rarity) { return `bp-rarity-${rarity}` }

export function emptyBoosts() {
  return { hp: 0, armor: 0, jumps: 0, sniper: 0, laststand: 0, chute: 0, chat_color: 0 }
}

export function applyPremiumPerk(boosts, shop, tier, now, xpBoost) {
  const p = PERKS[tier]
  if (!p) return { skipped: false }
  if (p.key === "hp") boosts.hp = Math.min(20, boosts.hp + p.n)
  else if (p.key === "jumps") boosts.jumps = Math.min(2, boosts.jumps + p.n)
  else if (p.key === "chute") boosts.chute = 1
  else if (p.key === "chat_color") boosts.chat_color = 1
  else if (p.key === "sniper") {
    const have = Math.max(shop.sniper || 0, boosts.sniper)
    boosts.sniper = Math.min(2, have === 0 ? 1 : have + 1)
  } else if (p.key === "laststand") {
    const have = Math.max(shop.laststand || 0, boosts.laststand)
    boosts.laststand = Math.min(2, have === 0 ? 1 : have + 1)
  } else if (p.key === "xpboost") {
    if (xpBoost.active && xpBoost.end > now && xpBoost.mult > p.n)
      return { skipped: true }
    xpBoost.active = true
    xpBoost.mult = p.n
    xpBoost.end = now + p.sec
  }
  return { skipped: false }
}

export function migrateVip(milestone, shop) {
  const b = emptyBoosts()
  const xp = { active: false, end: 0, mult: 1 }
  for (let t = 1; t <= milestone; t++) applyPremiumPerk(b, shop, t, 0, xp)
  return b
}

export function spawnHp(level, shopHp, passHp) {
  const table = Math.min(15, Math.max(0, level - 1))
  return 100 + table + (shopHp || 0) + Math.min(20, passHp || 0)
}

// ---- battle pass display helpers (owner: bp_track.js) ---------------------
import { num } from "./ui.js"
// battle pass: D1 pushes UPPERCASE rarities; cells key off lowercase ids
export function normalizeBpRarity(r) {
  return String(r == null ? "" : r).trim().toLowerCase().replace(/[\s-]+/g, "_") || "normal"
}
// battle pass: per-season premium entitlement (S2+ store rows; S1 handled
// inline with the legacy bp_premium cursor at the call site)
export function hasSeasonPremium(p, season) {
  return !!p && String(p.bp_premium_season || "") === String(season) && num(p.bp_ent_lane) > 0
}
