// Built-in game configuration catalogs (shipped with the platform)
// Generated from BattlePass.json, achievements.json, hall_of_fame.json & server configs.
import { RARITY_OF, FREE_XP, starOf, premiumPerk, FREE_COINS, premiumExtraCoins } from "./bp_track.js"

// ---- achievements display helpers (owner: catalogs.js) --------------------
// achievements: rarity ordering/styling shared by cabinet sort + filter tabs
export const RARITY_ORDER = ["legendary", "mythic", "rare", "uncommon", "common"]
export const RARITY_INDEX = { legendary: 4, mythic: 3, rare: 2, uncommon: 1, common: 0 }
export const RARITY_STYLE = {
  legendary: { label: "Legendary", color: "#e8c547", frame: "#8a6a12" },
  mythic:    { label: "Mythic",    color: "#fb7185", frame: "#6b1a24" },
  rare:      { label: "Rare",      color: "#7dd3fc", frame: "#1a3a6b" },
  uncommon:  { label: "Uncommon",  color: "#86efac", frame: "#1f6b3a" },
  common:    { label: "Common",    color: "#d1d5db", frame: "#5a6663" }
}
// achievements: per-badge metadata. Rarity tiers by AP value (1000 legendary,
// 500 rare, 250 common); categories by progression family. Unknown ids fall
// back to common/special (see achRarityOf/achCategoryOf in pages.js).
export const ACH_META = {
  kills_100:       { rarity: "common",    category: "combat" },
  kills_1000:      { rarity: "common",    category: "combat" },
  kills_5000:      { rarity: "rare",      category: "combat" },
  hs_100:          { rarity: "common",    category: "combat" },
  hs_500:          { rarity: "rare",      category: "combat" },
  bomb_specialist: { rarity: "common",    category: "objectives" },
  defusal_angel:   { rarity: "common",    category: "objectives" },
  wins_100:        { rarity: "common",    category: "progression" },
  level_25:        { rarity: "common",    category: "progression" },
  level_52:        { rarity: "legendary", category: "progression" },
  win_streak_10:   { rarity: "rare",      category: "progression" },
  coin_tycoon:     { rarity: "common",    category: "economy" },
  combat_medic:    { rarity: "rare",      category: "support" }
}
export const ACH_CATEGORIES = [
  { id: "combat", name: "Combat" },
  { id: "objectives", name: "Objectives" },
  { id: "progression", name: "Progression" },
  { id: "economy", name: "Economy" },
  { id: "support", name: "Support" }
]
// store: target for the season-premium CTA on the battle pass page. /store is
// gone() by design (index.js routes it to 404 — the panel never sells, the
// game is the only spender), so the old deep link landed on a 404 in both
// skins. The CTA now points at the real in-panel /vip route: it renders in
// both skins and carries the premium context (VIP unlocks the Battle Pass
// premium track) plus the official-store purchase steps. Season stays in the
// CTA copy only — /vip takes no season query param. When the visitor's
// steamid is known it rides along (same convention as tierHref): bare /vip
// falls back to the identity picker (needSteamid), so an authed user would
// otherwise have to re-pick themselves. compact=1 keeps the GoldSrc skin
// across the hop.
export function seasonPremiumCtaUrl({ steamid, compact } = {}) {
  const q = []
  if (steamid) q.push("steamid=" + encodeURIComponent(String(steamid)))
  if (compact) q.push("compact=1")
  return q.length ? "/vip?" + q.join("&") : "/vip"
}

const _RAW_REWARD_TRACK = {
  "version": 1,
  "season": "1",
  "xp_per_tier": 1000,
  "tiers": [
    {
      "tier": 1,
      "free": "+100 Coins (Recruit Stash)",
      "premium": "+100c Recruit Stash",
      "name": "Recruit Stash",
      "icon": "★",
      "rarity": "COMMON",
      "milestone": false
    },
    {
      "tier": 2,
      "free": "+50 Coins (Field Ammo Pack)",
      "premium": "+50c Munitions",
      "name": "Field Ammo Pack",
      "icon": "✦",
      "rarity": "COMMON",
      "milestone": false
    },
    {
      "tier": 3,
      "free": "+150 Coins (Tactical Ration)",
      "premium": "+100c Supply Crate",
      "name": "Tactical Ration",
      "icon": "★",
      "rarity": "COMMON",
      "milestone": false
    },
    {
      "tier": 4,
      "free": "+50 Coins (Recon Scout Kit)",
      "premium": "+50c Recon Munitions",
      "name": "Recon Scout Kit",
      "icon": "✦",
      "rarity": "COMMON",
      "milestone": false
    },
    {
      "tier": 5,
      "free": "+250 Coins (Double Jump Perk)",
      "premium": "Double Jump Stage I",
      "name": "Double Jump Perk",
      "icon": "✦",
      "rarity": "UNCOMMON",
      "milestone": true
    },
    {
      "tier": 6,
      "free": "+100 Coins (Kevlar Vest Supply)",
      "premium": "+100c Light Armor",
      "name": "Kevlar Vest Supply",
      "icon": "✦",
      "rarity": "COMMON",
      "milestone": false
    },
    {
      "tier": 7,
      "free": "+50 Coins (Medkit Drops)",
      "premium": "+50c Field Dressing",
      "name": "Medkit Drops",
      "icon": "✦",
      "rarity": "COMMON",
      "milestone": false
    },
    {
      "tier": 8,
      "free": "+100 Coins (Defuse Kit Stash)",
      "premium": "+100c Rapid Defuser",
      "name": "Defuse Kit Stash",
      "icon": "✦",
      "rarity": "COMMON",
      "milestone": false
    },
    {
      "tier": 9,
      "free": "+50 Coins (Flashbang Pouch)",
      "premium": "+50c Tactical Blinding",
      "name": "Flashbang Pouch",
      "icon": "★",
      "rarity": "COMMON",
      "milestone": false
    },
    {
      "tier": 10,
      "free": "+500 Coins (Novice Vanguard)",
      "premium": "+500c & Bronze Badge",
      "name": "Novice Vanguard",
      "icon": "★",
      "rarity": "RARE",
      "milestone": true
    },
    {
      "tier": 11,
      "free": "+100 Coins (Smoke Cloud Vapor)",
      "premium": "+100c Smoke Reserve",
      "name": "Smoke Cloud Vapor",
      "icon": "✦",
      "rarity": "COMMON",
      "milestone": false
    },
    {
      "tier": 12,
      "free": "+50 Coins (HE Fragment Crate)",
      "premium": "+50c HE Munitions",
      "name": "HE Fragment Crate",
      "icon": "✦",
      "rarity": "COMMON",
      "milestone": false
    },
    {
      "tier": 13,
      "free": "+100 Coins (Deagle Ammo Reserve)",
      "premium": "+100c Heavy Caliber",
      "name": "Deagle Ammo Reserve",
      "icon": "✦",
      "rarity": "COMMON",
      "milestone": false
    },
    {
      "tier": 14,
      "free": "+50 Coins (Armor Repair Kit)",
      "premium": "+50c Kevlar Patch",
      "name": "Armor Repair Kit",
      "icon": "✦",
      "rarity": "COMMON",
      "milestone": false
    },
    {
      "tier": 15,
      "free": "+750 Coins (1.5x XP Booster)",
      "premium": "30m 1.5x XP Boost",
      "name": "1.5x XP Booster",
      "icon": "★",
      "rarity": "RARE",
      "milestone": true
    },
    {
      "tier": 16,
      "free": "+100 Coins (Silver Reserve)",
      "premium": "+100c Combat Currency",
      "name": "Silver Reserve",
      "icon": "★",
      "rarity": "COMMON",
      "milestone": false
    },
    {
      "tier": 17,
      "free": "+50 Coins (Assault Rations)",
      "premium": "+50c Field Pack",
      "name": "Assault Rations",
      "icon": "✦",
      "rarity": "COMMON",
      "milestone": false
    },
    {
      "tier": 18,
      "free": "+250 Coins (Tactical Holster)",
      "premium": "+250c Sidearm Draw",
      "name": "Tactical Holster",
      "icon": "✦",
      "rarity": "UNCOMMON",
      "milestone": false
    },
    {
      "tier": 19,
      "free": "+100 Coins (Radio Decoy Unit)",
      "premium": "+100c Decoy Sound",
      "name": "Radio Decoy Unit",
      "icon": "✦",
      "rarity": "COMMON",
      "milestone": false
    },
    {
      "tier": 20,
      "free": "+500 Coins (Quick Bolt Module)",
      "premium": "Fast Sniper Stage I",
      "name": "Quick Bolt Module",
      "icon": "✦",
      "rarity": "RARE",
      "milestone": true
    },
    {
      "tier": 21,
      "free": "+500 Coins (Coin Vault Key)",
      "premium": "+500c Vault Access",
      "name": "Coin Vault Key",
      "icon": "★",
      "rarity": "UNCOMMON",
      "milestone": false
    },
    {
      "tier": 22,
      "free": "+100 Coins (Targeting Laser)",
      "premium": "+100c Dot Reticle",
      "name": "Targeting Laser",
      "icon": "✦",
      "rarity": "COMMON",
      "milestone": false
    },
    {
      "tier": 23,
      "free": "+50 Coins (Combat Adrenaline)",
      "premium": "+50c Speed Stim",
      "name": "Combat Adrenaline",
      "icon": "✦",
      "rarity": "COMMON",
      "milestone": false
    },
    {
      "tier": 24,
      "free": "+100 Coins (Wallbang Piercer)",
      "premium": "+100c Heavy Penetration",
      "name": "Wallbang Piercer",
      "icon": "✦",
      "rarity": "COMMON",
      "milestone": false
    },
    {
      "tier": 25,
      "free": "+1,000 Coins + QS Carbon AK",
      "premium": "+1,000c, [★ GODLIKE] & QS Carbon AK",
      "name": "Godlike Title License",
      "icon": "★",
      "rarity": "EPIC",
      "milestone": true
    },
    {
      "tier": 26,
      "free": "+100 Coins (Glock Burst Tuning)",
      "premium": "+100c Sidearm Mod",
      "name": "Glock Burst Tuning",
      "icon": "✦",
      "rarity": "COMMON",
      "milestone": false
    },
    {
      "tier": 27,
      "free": "+50 Coins (USP Silencer Kit)",
      "premium": "+50c Baffled Suppressor",
      "name": "USP Silencer Kit",
      "icon": "✦",
      "rarity": "COMMON",
      "milestone": false
    },
    {
      "tier": 28,
      "free": "+500 Coins (Clutch Armor Boost)",
      "premium": "+500c 1vX Vitality",
      "name": "Clutch Armor Boost",
      "icon": "✦",
      "rarity": "UNCOMMON",
      "milestone": false
    },
    {
      "tier": 29,
      "free": "+100 Coins (Night Vision Tech)",
      "premium": "+100c Thermal Sensor",
      "name": "Night Vision Tech",
      "icon": "✦",
      "rarity": "COMMON",
      "milestone": false
    },
    {
      "tier": 30,
      "free": "+750 Coins (Tag License Voucher)",
      "premium": "+1,000c Tag Voucher",
      "name": "Tag License Voucher",
      "icon": "✦",
      "rarity": "EPIC",
      "milestone": true
    },
    {
      "tier": 31,
      "free": "+100 Coins (M4A1 Buffer Spring)",
      "premium": "+100c Recoil Dampener",
      "name": "M4A1 Buffer Spring",
      "icon": "✦",
      "rarity": "COMMON",
      "milestone": false
    },
    {
      "tier": 32,
      "free": "+50 Coins (AK47 Heavy Bolt)",
      "premium": "+50c Steel Bolt",
      "name": "AK47 Heavy Bolt",
      "icon": "✦",
      "rarity": "COMMON",
      "milestone": false
    },
    {
      "tier": 33,
      "free": "+100 Coins (Healthnade Vapor)",
      "premium": "+100c Medic Vapor",
      "name": "Healthnade Vapor",
      "icon": "✦",
      "rarity": "COMMON",
      "milestone": false
    },
    {
      "tier": 34,
      "free": "+50 Coins (Armor Plate IV)",
      "premium": "+50c Titanium Plate",
      "name": "Armor Plate IV",
      "icon": "✦",
      "rarity": "COMMON",
      "milestone": false
    },
    {
      "tier": 35,
      "free": "+500 Coins (Spawn HP Titan Perk)",
      "premium": "Vitality II (+20 HP)",
      "name": "Spawn HP Titan Perk",
      "icon": "★",
      "rarity": "RARE",
      "milestone": true
    },
    {
      "tier": 36,
      "free": "+100 Coins (Coin Treasury Drop)",
      "premium": "+100c Vault Dividend",
      "name": "Coin Treasury Drop",
      "icon": "★",
      "rarity": "COMMON",
      "milestone": false
    },
    {
      "tier": 37,
      "free": "+50 Coins (Speed Rush Pouch)",
      "premium": "+50c Sprint Juice",
      "name": "Speed Rush Pouch",
      "icon": "★",
      "rarity": "COMMON",
      "milestone": false
    },
    {
      "tier": 38,
      "free": "+100 Coins (AWP Heavy Bipod)",
      "premium": "+100c Stability System",
      "name": "AWP Heavy Bipod",
      "icon": "✦",
      "rarity": "COMMON",
      "milestone": false
    },
    {
      "tier": 39,
      "free": "+50 Coins (Kevlar Helmet MK3)",
      "premium": "+50c Reinforced Visor",
      "name": "Kevlar Helmet MK3",
      "icon": "✦",
      "rarity": "COMMON",
      "milestone": false
    },
    {
      "tier": 40,
      "free": "+750 Coins (Lightning Spawn Aura)",
      "premium": "Lightning Spawn Effect",
      "name": "Lightning Spawn Aura",
      "icon": "★",
      "rarity": "EPIC",
      "milestone": true
    },
    {
      "tier": 41,
      "free": "+200 Coins (High Caliber Ammo)",
      "premium": "+200c Match Grade",
      "name": "High Caliber Ammo",
      "icon": "✦",
      "rarity": "COMMON",
      "milestone": false
    },
    {
      "tier": 42,
      "free": "+100 Coins (CPR Defibrillator Cell)",
      "premium": "+100c CPR Cell",
      "name": "CPR Defibrillator Cell",
      "icon": "★",
      "rarity": "COMMON",
      "milestone": false
    },
    {
      "tier": 43,
      "free": "+200 Coins (Parachute Canopy)",
      "premium": "Stealth Glide Chute",
      "name": "Parachute Canopy",
      "icon": "✦",
      "rarity": "COMMON",
      "milestone": false
    },
    {
      "tier": 44,
      "free": "+100 Coins (Tactical Grenadier)",
      "premium": "+100c Blast Shield",
      "name": "Tactical Grenadier",
      "icon": "✦",
      "rarity": "COMMON",
      "milestone": false
    },
    {
      "tier": 45,
      "free": "+1,000 Coins (2.0x Double XP Boost)",
      "premium": "Double XP (30m) + 1,000c",
      "name": "2.0x Double XP Boost",
      "icon": "★",
      "rarity": "EPIC",
      "milestone": true
    },
    {
      "tier": 46,
      "free": "+200 Coins (Vampire Siphon Tech)",
      "premium": "+200c Leech Protocol",
      "name": "Vampire Siphon Tech",
      "icon": "✦",
      "rarity": "COMMON",
      "milestone": false
    },
    {
      "tier": 47,
      "free": "+100 Coins (Headshot Multiplier)",
      "premium": "+100c Precision Bonus",
      "name": "Headshot Multiplier",
      "icon": "✦",
      "rarity": "COMMON",
      "milestone": false
    },
    {
      "tier": 48,
      "free": "+200 Coins (Toxic Green Color Clearance)",
      "premium": "Toxic Cyber Green (^4)",
      "name": "Toxic Green Color Clearance",
      "icon": "✦",
      "rarity": "RARE",
      "milestone": true
    },
    {
      "tier": 49,
      "free": "+100 Coins (Final Surge Stim)",
      "premium": "+100c Adrenaline Shot",
      "name": "Final Surge Stim",
      "icon": "✦",
      "rarity": "COMMON",
      "milestone": false
    },
    {
      "tier": 50,
      "free": "+2,000 Coins (Tactical Flip Knife Skin)",
      "premium": "Flip + Redline + 2,500c",
      "premium_plus": "Flip + Redline + 3,000c",
      "premium_elite": "Flip + Redline + 4,000c",
      "name": "Tactical Flip Knife Skin",
      "icon": "✦",
      "rarity": "LEGENDARY",
      "milestone": true
    },
    {
      "tier": 51,
      "free": "+5,000 Coins (Grand Treasury Dividend)",
      "premium": "+5,000 Coins Grand Stash",
      "name": "Grand Treasury Dividend",
      "icon": "★",
      "rarity": "LEGENDARY",
      "milestone": false
    },
    {
      "tier": 52,
      "free": "+10,000 Coins (Legend CT/T models)",
      "premium": "Legend CT/T + 10,000c",
      "premium_plus": "Legend CT/T + 12,500c",
      "premium_elite": "Legend CT/T + 15,000c",
      "name": "Legend Player Models",
      "icon": "★",
      "rarity": "TRANSCENDENT",
      "milestone": true
    },
    {
      "tier": 53,
      "free": "+500 Coins + S1 Operator CT/T + Asiimov AK (exclusive)",
      "premium": "+500c + S1 Operator + Asiimov",
      "name": "Season 1 Operator + Asiimov",
      "icon": "★",
      "rarity": "RARE",
      "milestone": false
    },
    {
      "tier": 54,
      "free": "+500 Coins (Ghost Recon Chute)",
      "premium": "Black Ops Chute",
      "name": "Ghost Recon Chute",
      "icon": "✦",
      "rarity": "RARE",
      "milestone": false
    },
    {
      "tier": 55,
      "free": "+2,500 Coins (Major MVP Title Badge)",
      "premium": "[ MAJOR MVP ] Title Drop",
      "name": "Major MVP Title Badge",
      "icon": "★",
      "rarity": "LEGENDARY",
      "milestone": true
    },
    {
      "tier": 56,
      "free": "+500 Coins (Titan Armor Core)",
      "premium": "+500c Titan Armor",
      "premium_plus": "S1 VIP+ Howl + Karambit",
      "premium_elite": "S1 Elite Howl + Karambit",
      "name": "Season 1 VIP Operator + Guns",
      "icon": "✦",
      "rarity": "RARE",
      "milestone": false
    },
    {
      "tier": 57,
      "free": "+500 Coins (Quad Jump Acrobatic)",
      "premium": "+500c Quad Jump Access",
      "name": "Quad Jump Acrobatic",
      "icon": "✦",
      "rarity": "RARE",
      "milestone": false
    },
    {
      "tier": 58,
      "free": "+1,000 Coins (Divine Ray Aura)",
      "premium": "Divine Spawn Effect",
      "name": "Divine Ray Aura",
      "icon": "✦",
      "rarity": "EPIC",
      "milestone": false
    },
    {
      "tier": 59,
      "free": "+1,000 Coins (Final Stand Defiance)",
      "premium": "1 HP Defiance Surge",
      "name": "Final Stand Defiance",
      "icon": "✦",
      "rarity": "EPIC",
      "milestone": false
    },
    {
      "tier": 60,
      "free": "+5,000 Coins (The Global Elite Trophy)",
      "premium": "Global Elite + 10,000c",
      "premium_plus": "Global Elite + 12,500c",
      "premium_elite": "Global Elite + 15,000c",
      "name": "The Global Elite Trophy",
      "icon": "★",
      "rarity": "TRANSCENDENT",
      "milestone": true
    }
  ]
}

export const DEFAULT_REWARD_TRACK = {
  version: 2,
  season: _RAW_REWARD_TRACK.season,
  xp_per_tier: _RAW_REWARD_TRACK.xp_per_tier,
  tiers: _RAW_REWARD_TRACK.tiers.map((t) => {
    const rarity = RARITY_OF[t.tier]
    const perk = premiumPerk(t.tier)
    return {
      tier: t.tier,
      free: t.free,
      premium: t.premium,
      premium_plus: t.premium_plus || t.premium,
      premium_elite: t.premium_elite || t.premium_plus || t.premium,
      name: t.name,
      rarity,
      star: starOf(rarity),
      free_xp: FREE_XP[rarity],
      free_coins: FREE_COINS[t.tier],
      premium_perk: perk,
      milestone: perk != null,
    }
  }),
}

// Live server track: mirrors battlepass_core.sma g_iBpFreeCoins,
// g_iLaneSkillUnlock (regular lane 0 / VIP lane 1), BpPremiumTotalCoins and
// BpApplyPerkOnly. This is deliberately separate from the concept preview in
// bp_perk_track.js: the normal page must never promise a grant AMXX lacks.
export const SERVER_REWARD_TRACK = (() => {
  const comma = n => String(n).replace(/\B(?=(\d{3})+(?!\d))/g, ",")
  const perkLabel = {
    jumps: "Multi-Jump",
    hp: "Spawn HP",
    xpboost: "XP Boost",
    sniper: "Fast Sniper",
    title: "Cosmetic Title",
    tag: "Tag License",
    spawn: "Spawn Effect",
    chat_color: "Chat Color",
    skin_flip: "Flip Knife Skin",
    model_legend: "Legend Models",
    chute: "Parachute",
    laststand: "Last Stand"
  }
  const perkIcon = {
    jumps: "jump",
    hp: "heart",
    xpboost: "speed",
    sniper: "sniper",
    title: "title",
    tag: "tag",
    spawn: "aura",
    chat_color: "paint",
    skin_flip: "knife",
    model_legend: "model",
    chute: "chute",
    laststand: "shield"
  }
  // AMXX g_iLaneSkillUnlock: regular lane 0, premium VIP lane 1.
  const regularLane = { 30: "Multi-Jump I", 45: "Parachute", 50: "AWP License", 55: "Chat Color" }
  const vipLane = { 20: "Multi-Jump I", 30: "Parachute", 40: "AWP License", 50: "Chat Color", 60: "Multi-Jump II" }
  const regularIcon = { 30: "jump", 45: "chute", 50: "sniper", 55: "paint" }
  const vipIcon = { 20: "jump", 30: "chute", 40: "sniper", 50: "paint", 60: "jump" }
  const freePerk = {
    2: "Spawn HP +1", 4: "Spawn Armor +2", 6: "Nimble +1%",
    10: "Parachute", 12: "Multi-Jump I", 16: "Spawn HP +2", 18: "Spawn Armor +3",
    20: "Nimble +2%", 22: "Vampire +1", 24: "Featherfall 15%", 26: "Fast Sniper 10%",
    28: "HealthNade 15", 30: "Combat Medic 3s", 32: "Last Stand 5", 34: "AWP License",
    36: "Chat Color", 38: "Spawn HP +4", 39: "Spawn Armor +6", 40: "Nimble +3%",
    41: "Vampire +2", 42: "Featherfall 30%", 43: "Fast Sniper 20%", 44: "HealthNade 30",
    45: "Combat Medic 2s", 46: "Last Stand 10", 47: "Triple Jump", 48: "Spawn HP +6",
    49: "Spawn Armor +9", 51: "Vampire +3", 52: "Featherfall 45%", 53: "Quad Jump",
    54: "Spawn HP +7", 55: "Spawn Armor +11", 57: "Spawn HP +8", 58: "Spawn Armor +13"
  }

  return {
    version: 3,
    season: 1,
    xp_per_tier: 1000,
    authority: "amxx",
    tiers: Array.from({ length: 60 }, (_, i) => {
      const tier = i + 1
      const free = FREE_COINS[tier] || 0
      const extra = premiumExtraCoins(tier, 1)
      const total = free + extra
      const perk = premiumPerk(tier)
      const freeBits = [`+${comma(free)} Coins`]
      if (freePerk[tier]) freeBits.push(freePerk[tier])
      if (regularLane[tier]) freeBits.push(regularLane[tier])
      const premiumBits = [`+${comma(total)} Coins`]
      if (vipLane[tier]) premiumBits.push(vipLane[tier])
      if (perk && perkLabel[perk.key]) premiumBits.push(perkLabel[perk.key])
      return {
        tier,
        free: freeBits.join(" · "),
        premium: premiumBits.join(" · "),
        name: freeBits[0],
        icon: regularIcon[tier] || "coins",
        premIcon: perk && perkIcon[perk.key] ? perkIcon[perk.key] : (vipIcon[tier] || "coins"),
        rarity: "normal",
        free_coins: free,
        premium_coins: total
      }
    })
  }
})()

export const DEFAULT_SKILLS = {
  "version": 1,
  "skills": [
    {
      "id": "multi_jump",
      "name": "Multi-Jump",
      "desc": "Leap multiple times mid-air to reach high ledges and evade fire",
      "price": 2500,
      "icon": "👟",
      "max_stage": 3,
      "stages": [
        {
          "stage": 1,
          "cost": 2500,
          "name": "Double Jump",
          "desc": "2 Jumps total (1 Ground + 1 Mid-Air)"
        },
        {
          "stage": 2,
          "cost": 5000,
          "name": "Triple Jump",
          "desc": "3 Jumps total (1 Ground + 2 Mid-Air)"
        },
        {
          "stage": 3,
          "cost": 10000,
          "name": "Quad Jump",
          "desc": "4 Jumps total (1 Ground + 3 Mid-Air - Acrobatic)"
        }
      ]
    },
    {
      "id": "spawn_hp",
      "name": "Spawn HP Boost",
      "desc": "Begin every round with enhanced vitality above standard 100 HP",
      "price": 2000,
      "icon": "❤️",
      "max_stage": 3,
      "stages": [
        {
          "stage": 1,
          "cost": 2000,
          "name": "Vitality I",
          "desc": "+10 Max HP on spawn (110 HP)"
        },
        {
          "stage": 2,
          "cost": 4500,
          "name": "Vitality II",
          "desc": "+20 Max HP on spawn (120 HP)"
        },
        {
          "stage": 3,
          "cost": 8000,
          "name": "Vitality III",
          "desc": "+30 Max HP on spawn (130 HP Titan)"
        }
      ]
    },
    {
      "id": "spawn_armor",
      "name": "Spawn Armor Boost",
      "desc": "Spawn automatically equipped with military body armor & helmet",
      "price": 1500,
      "icon": "🛡️",
      "max_stage": 3,
      "stages": [
        {
          "stage": 1,
          "cost": 1500,
          "name": "Reinforced Kevlar",
          "desc": "+50 Kevlar Armor on spawn"
        },
        {
          "stage": 2,
          "cost": 3500,
          "name": "Assault Suit",
          "desc": "+100 Kevlar & Helmet on spawn"
        },
        {
          "stage": 3,
          "cost": 6000,
          "name": "Juggernaut Vest",
          "desc": "+125 Reinforced Armor & Helmet on spawn"
        }
      ]
    },
    {
      "id": "vampire",
      "name": "Vampire Lifesteal",
      "desc": "Extract health directly from fallen opponents upon every frag",
      "price": 2500,
      "icon": "🩸",
      "max_stage": 3,
      "stages": [
        {
          "stage": 1,
          "cost": 2500,
          "name": "Blood Sip",
          "desc": "+10 HP restored per kill"
        },
        {
          "stage": 2,
          "cost": 5000,
          "name": "Blood Feast",
          "desc": "+20 HP per kill (+30 HP on Headshot)"
        },
        {
          "stage": 3,
          "cost": 8500,
          "name": "Vampiric Lord",
          "desc": "+30 HP per kill (+45 HP on Headshot)"
        }
      ]
    },
    {
      "id": "nimble",
      "name": "Nimble Agility",
      "desc": "Passive movement speed enhancement for faster rotations & flanking",
      "price": 1500,
      "icon": "⚡",
      "max_stage": 3,
      "stages": [
        {
          "stage": 1,
          "cost": 1500,
          "name": "Swiftness I",
          "desc": "+5% Permanent Movement Speed"
        },
        {
          "stage": 2,
          "cost": 3500,
          "name": "Swiftness II",
          "desc": "+10% Permanent Movement Speed"
        },
        {
          "stage": 3,
          "cost": 6500,
          "name": "Swiftness III",
          "desc": "+15% Permanent Movement Speed"
        }
      ]
    },
    {
      "id": "featherfall",
      "name": "Featherfall",
      "desc": "Absorbs kinetic impact from severe heights and cliff drops",
      "price": 1000,
      "icon": "🪶",
      "max_stage": 3,
      "stages": [
        {
          "stage": 1,
          "cost": 1000,
          "name": "Cushion",
          "desc": "35% Fall Damage Reduction"
        },
        {
          "stage": 2,
          "cost": 2500,
          "name": "Shock Absorber",
          "desc": "70% Fall Damage Reduction"
        },
        {
          "stage": 3,
          "cost": 5000,
          "name": "Zero-G Boots",
          "desc": "100% Fall Damage Immunity (0 Damage)"
        }
      ]
    },
    {
      "id": "healthnade",
      "name": "HealthNade",
      "desc": "Transforms your smoke grenade into a high-potency restorative vapor",
      "price": 2500,
      "icon": "🧪",
      "max_stage": 2,
      "stages": [
        {
          "stage": 1,
          "cost": 2500,
          "name": "Medic Smoke",
          "desc": "Smoke grenade emits 250-unit healing zone restoring +35 HP to nearby allies"
        },
        {
          "stage": 2,
          "cost": 5000,
          "name": "Nano Mist",
          "desc": "Enhanced nanotech vapor heals +70 HP and repairs +35 Armor"
        }
      ]
    },
    {
      "id": "fast_sniper",
      "name": "Fast Sniper",
      "desc": "Accelerates bolt-action chambering and weapon draw speed on sniper rifles",
      "price": 2000,
      "icon": "🎯",
      "max_stage": 2,
      "stages": [
        {
          "stage": 1,
          "cost": 2000,
          "name": "Quick Bolt",
          "desc": "15% faster bolt cycle & re-zoom on AWP/Scout"
        },
        {
          "stage": 2,
          "cost": 4500,
          "name": "Master Marksman",
          "desc": "30% faster bolt cycle & instant weapon switch"
        }
      ]
    },
    {
      "id": "revive",
      "name": "Combat Medic",
      "desc": "Resurrect dead teammates right where they fell using the CPR defibrillator",
      "price": 3000,
      "icon": "💉",
      "max_stage": 2,
      "stages": [
        {
          "stage": 1,
          "cost": 3000,
          "name": "Field Medic",
          "desc": "Revive teammates within 3.0 seconds"
        },
        {
          "stage": 2,
          "cost": 6000,
          "name": "Trauma Specialist",
          "desc": "Rapid Revive within 1.5 seconds"
        }
      ]
    },
    {
      "id": "laststand",
      "name": "Last Stand",
      "desc": "Emergency adrenaline surge defying death when taking fatal damage",
      "price": 3500,
      "icon": "🛡️",
      "max_stage": 2,
      "stages": [
        {
          "stage": 1,
          "cost": 3500,
          "name": "Second Wind",
          "desc": "Survive fatal hit with 10 HP + invulnerability frame (once per round)"
        },
        {
          "stage": 2,
          "cost": 7000,
          "name": "Defiance",
          "desc": "Survive fatal hit with 30 HP + 3s Adrenaline Sprint (+25% speed)"
        }
      ]
    },
    {
      "id": "parachute",
      "name": "Tactical Parachute",
      "desc": "Deployable canopy for precision gliding and silent high-ground flanking",
      "price": 1500,
      "icon": "🪂",
      "max_stage": 1,
      "stages": [
        {
          "stage": 1,
          "cost": 1500,
          "name": "Canopy Glider",
          "desc": "Hold [USE / E] mid-air to glide safely to the ground"
        }
      ]
    },
    {
      "id": "awp_unlock",
      "name": "AWP Armory License",
      "desc": "Permanent security clearance allowing AWP purchase in the weapon armory",
      "price": 2000,
      "icon": "🔫",
      "max_stage": 1,
      "stages": [
        {
          "stage": 1,
          "cost": 2000,
          "name": "Sniper License",
          "desc": "Permanent access to AWP in the weapon menu"
        }
      ]
    },
    {
      "id": "chat_color",
      "name": "Chat Color License",
      "desc": "Permanent clearance to transmit custom colored chat text (Toxic Green & Team Color)",
      "price": 8000,
      "icon": "💬",
      "max_stage": 1,
      "stages": [
        {
          "stage": 1,
          "cost": 8000,
          "name": "Color Transmitter",
          "desc": "Permanent access to /color - unlock Toxic Green (^4) and Dynamic Team Color (^3)"
        }
      ]
    }
  ]
}

// All rows from skins_menu.cfg (idx = 1-based position within weapon group; Default = idx 0).
// vipOnly: 0=none, 1=VIP, 2=Legend. bpLevel: minimum CRX rank. price: coin cost (0 = locked/free).
export const DEFAULT_SKINS = {
  "version": 3,
  "skins": [
    { "grp": "ak47",   "idx": 1,  "name": "QS Carbon AK",        "price": 25000, "vipOnly": 0, "bpLevel": 0  },
    { "grp": "ak47",   "idx": 2,  "name": "AK-47 Asiimov",        "price": 28000, "vipOnly": 0, "bpLevel": 53 },
    { "grp": "ak47",   "idx": 3,  "name": "CSGO AK",              "price": 20000, "vipOnly": 0, "bpLevel": 0  },
    { "grp": "ak47",   "idx": 4,  "name": "CSGO AK T-Arms",       "price": 20000, "vipOnly": 0, "bpLevel": 0  },
    { "grp": "ak47",   "idx": 5,  "name": "QS Carbon AK VIP",     "price": 0,     "vipOnly": 1, "bpLevel": 0  },
    { "grp": "ak47",   "idx": 6,  "name": "CSGO AK VIP+",         "price": 0,     "vipOnly": 1, "bpLevel": 0  },
    { "grp": "ak47",   "idx": 7,  "name": "CSGO AK VIP",          "price": 0,     "vipOnly": 1, "bpLevel": 0  },
    { "grp": "ak47",   "idx": 8,  "name": "QS Carbon AK Legend",  "price": 0,     "vipOnly": 2, "bpLevel": 0  },
    { "grp": "ak47",   "idx": 9,  "name": "CSGO AK Legend",       "price": 0,     "vipOnly": 2, "bpLevel": 0  },
    { "grp": "ak47",   "idx": 10, "name": "CSGO AK Lv.10",        "price": 0,     "vipOnly": 0, "bpLevel": 10 },
    { "grp": "ak47",   "idx": 11, "name": "CSGO AK Lv.20",        "price": 0,     "vipOnly": 0, "bpLevel": 20 },
    { "grp": "ak47",   "idx": 12, "name": "CSGO AK Lv.30",        "price": 0,     "vipOnly": 0, "bpLevel": 30 },
    { "grp": "ak47",   "idx": 13, "name": "QS Carbon AK Lv.40",   "price": 0,     "vipOnly": 0, "bpLevel": 40 },
    { "grp": "ak47",   "idx": 14, "name": "QS Carbon Elite",      "price": 0,     "vipOnly": 1, "bpLevel": 20 },
    { "grp": "ak47",   "idx": 15, "name": "CSGO AK Elite",        "price": 0,     "vipOnly": 1, "bpLevel": 30 },
    { "grp": "ak47",   "idx": 16, "name": "QS Field Issue",       "price": 8000,  "vipOnly": 0, "bpLevel": 0  },
    { "grp": "ak47",   "idx": 17, "name": "QS Worn",              "price": 12000, "vipOnly": 0, "bpLevel": 0  },
    { "grp": "ak47",   "idx": 18, "name": "CSGO AK Promo",        "price": 5000,  "vipOnly": 0, "bpLevel": 0  },
    { "grp": "ak47",   "idx": 19, "name": "CSGO T Promo",         "price": 5000,  "vipOnly": 0, "bpLevel": 0  },
    { "grp": "ak47",   "idx": 20, "name": "QS BP52",              "price": 0,     "vipOnly": 2, "bpLevel": 0  },
    { "grp": "m4a1",   "idx": 1,  "name": "S1 Howl",              "price": 0,     "vipOnly": 2, "bpLevel": 56 },
    { "grp": "m4a1",   "idx": 2,  "name": "M4A4 Howl Classic",    "price": 30000, "vipOnly": 0, "bpLevel": 0  },
    { "grp": "m4a1",   "idx": 3,  "name": "M4A4 Desolate Space",  "price": 28000, "vipOnly": 0, "bpLevel": 0  },
    { "grp": "m4a1",   "idx": 4,  "name": "M4A4 Dragon King",     "price": 32000, "vipOnly": 0, "bpLevel": 0  },
    { "grp": "m4a1",   "idx": 5,  "name": "M4A4 Poseidon",        "price": 32000, "vipOnly": 0, "bpLevel": 0  },
    { "grp": "m4a1",   "idx": 6,  "name": "CSGO M4A1-S",          "price": 20000, "vipOnly": 0, "bpLevel": 0  },
    { "grp": "m4a1",   "idx": 7,  "name": "CSGO M4A1-S T-Arms",   "price": 20000, "vipOnly": 0, "bpLevel": 0  },
    { "grp": "m4a1",   "idx": 8,  "name": "Howl Classic VIP",     "price": 0,     "vipOnly": 1, "bpLevel": 0  },
    { "grp": "m4a1",   "idx": 9,  "name": "Dragon King VIP",      "price": 0,     "vipOnly": 1, "bpLevel": 0  },
    { "grp": "m4a1",   "idx": 10, "name": "Poseidon VIP",         "price": 0,     "vipOnly": 1, "bpLevel": 0  },
    { "grp": "m4a1",   "idx": 11, "name": "Desolate Legend",      "price": 0,     "vipOnly": 2, "bpLevel": 0  },
    { "grp": "m4a1",   "idx": 12, "name": "CSGO M4 Lv.10",        "price": 0,     "vipOnly": 0, "bpLevel": 10 },
    { "grp": "m4a1",   "idx": 13, "name": "Dragon Lv.20",         "price": 0,     "vipOnly": 0, "bpLevel": 20 },
    { "grp": "m4a1",   "idx": 14, "name": "Desolate Lv.30",       "price": 0,     "vipOnly": 0, "bpLevel": 30 },
    { "grp": "m4a1",   "idx": 15, "name": "Dragon Lv.40",         "price": 0,     "vipOnly": 0, "bpLevel": 40 },
    { "grp": "m4a1",   "idx": 16, "name": "Poseidon Elite",       "price": 0,     "vipOnly": 1, "bpLevel": 20 },
    { "grp": "m4a1",   "idx": 17, "name": "CSGO M4 Promo",        "price": 5000,  "vipOnly": 0, "bpLevel": 0  },
    { "grp": "m4a1",   "idx": 18, "name": "CSGO M4 Field",        "price": 15000, "vipOnly": 0, "bpLevel": 0  },
    { "grp": "m4a1",   "idx": 19, "name": "Poseidon Promo",       "price": 8000,  "vipOnly": 0, "bpLevel": 0  },
    { "grp": "m4a1",   "idx": 20, "name": "Dragon BP52",          "price": 0,     "vipOnly": 2, "bpLevel": 0  },
    { "grp": "awp",    "idx": 1,  "name": "AWP Redline",          "price": 50000, "vipOnly": 0, "bpLevel": 0  },
    { "grp": "awp",    "idx": 2,  "name": "CSGO AWP",             "price": 25000, "vipOnly": 0, "bpLevel": 0  },
    { "grp": "awp",    "idx": 3,  "name": "CSGO AWP T-Arms",      "price": 25000, "vipOnly": 0, "bpLevel": 0  },
    { "grp": "awp",    "idx": 4,  "name": "AWP Redline VIP",      "price": 0,     "vipOnly": 1, "bpLevel": 0  },
    { "grp": "awp",    "idx": 5,  "name": "CSGO AWP VIP",         "price": 0,     "vipOnly": 1, "bpLevel": 0  },
    { "grp": "awp",    "idx": 6,  "name": "AWP Redline Legend",   "price": 0,     "vipOnly": 2, "bpLevel": 0  },
    { "grp": "awp",    "idx": 7,  "name": "CSGO AWP Legend",      "price": 0,     "vipOnly": 2, "bpLevel": 0  },
    { "grp": "awp",    "idx": 8,  "name": "CSGO AWP Lv.10",       "price": 0,     "vipOnly": 0, "bpLevel": 10 },
    { "grp": "awp",    "idx": 9,  "name": "Redline Lv.20",        "price": 0,     "vipOnly": 0, "bpLevel": 20 },
    { "grp": "awp",    "idx": 10, "name": "CSGO AWP Lv.30",       "price": 0,     "vipOnly": 0, "bpLevel": 30 },
    { "grp": "awp",    "idx": 11, "name": "Redline Lv.40",        "price": 0,     "vipOnly": 0, "bpLevel": 40 },
    { "grp": "awp",    "idx": 12, "name": "Redline Elite",        "price": 0,     "vipOnly": 1, "bpLevel": 20 },
    { "grp": "awp",    "idx": 13, "name": "CSGO AWP Elite",       "price": 0,     "vipOnly": 1, "bpLevel": 30 },
    { "grp": "awp",    "idx": 14, "name": "Redline Field",        "price": 18000, "vipOnly": 0, "bpLevel": 0  },
    { "grp": "awp",    "idx": 15, "name": "CSGO AWP Promo",       "price": 8000,  "vipOnly": 0, "bpLevel": 0  },
    { "grp": "awp",    "idx": 16, "name": "CSGO T Promo",         "price": 8000,  "vipOnly": 0, "bpLevel": 0  },
    { "grp": "awp",    "idx": 17, "name": "Redline Worn",         "price": 12000, "vipOnly": 0, "bpLevel": 0  },
    { "grp": "awp",    "idx": 18, "name": "CSGO AWP Scout",       "price": 0,     "vipOnly": 0, "bpLevel": 5  },
    { "grp": "awp",    "idx": 19, "name": "Redline BP52",         "price": 0,     "vipOnly": 2, "bpLevel": 0  },
    { "grp": "awp",    "idx": 20, "name": "CSGO AWP BP52",        "price": 0,     "vipOnly": 2, "bpLevel": 0  },
    { "grp": "deagle", "idx": 1,  "name": "Deagle Blaze",         "price": 18000, "vipOnly": 0, "bpLevel": 0  },
    { "grp": "deagle", "idx": 2,  "name": "CSGO Deagle",          "price": 15000, "vipOnly": 0, "bpLevel": 0  },
    { "grp": "deagle", "idx": 3,  "name": "CSGO Deagle T-Arms",   "price": 15000, "vipOnly": 0, "bpLevel": 0  },
    { "grp": "deagle", "idx": 4,  "name": "Deagle Blaze VIP",     "price": 0,     "vipOnly": 1, "bpLevel": 0  },
    { "grp": "deagle", "idx": 5,  "name": "CSGO Deagle VIP",      "price": 0,     "vipOnly": 1, "bpLevel": 0  },
    { "grp": "deagle", "idx": 6,  "name": "Deagle Blaze Legend",  "price": 0,     "vipOnly": 2, "bpLevel": 0  },
    { "grp": "deagle", "idx": 7,  "name": "CSGO Deagle Legend",   "price": 0,     "vipOnly": 2, "bpLevel": 0  },
    { "grp": "deagle", "idx": 8,  "name": "CSGO Deagle Lv.10",    "price": 0,     "vipOnly": 0, "bpLevel": 10 },
    { "grp": "deagle", "idx": 9,  "name": "Blaze Lv.20",          "price": 0,     "vipOnly": 0, "bpLevel": 20 },
    { "grp": "deagle", "idx": 10, "name": "CSGO Deagle Lv.30",    "price": 0,     "vipOnly": 0, "bpLevel": 30 },
    { "grp": "deagle", "idx": 11, "name": "Blaze Lv.40",          "price": 0,     "vipOnly": 0, "bpLevel": 40 },
    { "grp": "deagle", "idx": 12, "name": "Blaze Elite",          "price": 0,     "vipOnly": 1, "bpLevel": 20 },
    { "grp": "deagle", "idx": 13, "name": "CSGO Deagle Elite",    "price": 0,     "vipOnly": 1, "bpLevel": 30 },
    { "grp": "deagle", "idx": 14, "name": "Blaze Field",          "price": 7000,  "vipOnly": 0, "bpLevel": 0  },
    { "grp": "deagle", "idx": 15, "name": "CSGO Deagle Promo",    "price": 4000,  "vipOnly": 0, "bpLevel": 0  },
    { "grp": "deagle", "idx": 16, "name": "CSGO T Promo",         "price": 4000,  "vipOnly": 0, "bpLevel": 0  },
    { "grp": "deagle", "idx": 17, "name": "Blaze Worn",           "price": 5000,  "vipOnly": 0, "bpLevel": 0  },
    { "grp": "deagle", "idx": 18, "name": "CSGO Deagle Scout",    "price": 0,     "vipOnly": 0, "bpLevel": 5  },
    { "grp": "deagle", "idx": 19, "name": "Blaze BP52",           "price": 0,     "vipOnly": 2, "bpLevel": 0  },
    { "grp": "deagle", "idx": 20, "name": "CSGO Deagle BP52",     "price": 0,     "vipOnly": 2, "bpLevel": 0  },
    { "grp": "knife",  "idx": 1,  "name": "Tactical Flip Knife",  "price": 15000, "vipOnly": 0, "bpLevel": 0  },
    { "grp": "knife",  "idx": 2,  "name": "Silver Knife",         "price": 0,     "vipOnly": 1, "bpLevel": 0  },
    { "grp": "knife",  "idx": 3,  "name": "S1 Karambit",          "price": 0,     "vipOnly": 2, "bpLevel": 56 },
    { "grp": "knife",  "idx": 4,  "name": "Bayonet",              "price": 35000, "vipOnly": 0, "bpLevel": 0  },
    { "grp": "knife",  "idx": 5,  "name": "M9 Bayonet",           "price": 40000, "vipOnly": 0, "bpLevel": 0  },
    { "grp": "knife",  "idx": 6,  "name": "Butterfly",            "price": 0,     "vipOnly": 1, "bpLevel": 0  },
    { "grp": "knife",  "idx": 7,  "name": "Huntsman",             "price": 30000, "vipOnly": 0, "bpLevel": 0  },
    { "grp": "knife",  "idx": 8,  "name": "Flip CSGO",            "price": 25000, "vipOnly": 0, "bpLevel": 0  },
    { "grp": "knife",  "idx": 9,  "name": "Gut",                  "price": 20000, "vipOnly": 0, "bpLevel": 0  },
    { "grp": "knife",  "idx": 10, "name": "Falchion",             "price": 28000, "vipOnly": 0, "bpLevel": 0  },
    { "grp": "knife",  "idx": 11, "name": "Bowie",                "price": 0,     "vipOnly": 1, "bpLevel": 0  },
    { "grp": "knife",  "idx": 12, "name": "Talon",                "price": 40000, "vipOnly": 0, "bpLevel": 0  },
    { "grp": "knife",  "idx": 13, "name": "Stiletto",             "price": 35000, "vipOnly": 0, "bpLevel": 0  },
    { "grp": "knife",  "idx": 14, "name": "Ursus",                "price": 30000, "vipOnly": 0, "bpLevel": 0  },
    { "grp": "knife",  "idx": 15, "name": "Navaja",               "price": 22000, "vipOnly": 0, "bpLevel": 0  },
    { "grp": "knife",  "idx": 16, "name": "Nomad",                "price": 0,     "vipOnly": 0, "bpLevel": 10 },
    { "grp": "knife",  "idx": 17, "name": "Skeleton",             "price": 0,     "vipOnly": 0, "bpLevel": 20 },
    { "grp": "knife",  "idx": 18, "name": "Survival",             "price": 0,     "vipOnly": 0, "bpLevel": 30 },
    { "grp": "knife",  "idx": 19, "name": "Paracord",             "price": 0,     "vipOnly": 1, "bpLevel": 0  },
    { "grp": "knife",  "idx": 20, "name": "Shadow Daggers",       "price": 0,     "vipOnly": 2, "bpLevel": 0  }
  ]
}

export const DEFAULT_MODELS = {
  "version": 1,
  "models": [
    {
      "id": "vip_ct",
      "name": "VIP Guardian (CT)",
      "team": "Counter-Terrorist",
      "price": 25000,
      "vipTier": 1
    },
    {
      "id": "vip_tero",
      "name": "VIP Syndicate (T)",
      "team": "Terrorist",
      "price": 25000,
      "vipTier": 1
    },
    {
      "id": "legend_ct",
      "name": "Legend CT (Level 52)",
      "team": "Counter-Terrorist",
      "price": 0,
      "vipTier": 4
    },
    {
      "id": "legend_t",
      "name": "Legend T (Level 52)",
      "team": "Terrorist",
      "price": 0,
      "vipTier": 4
    },
    {
      "id": "s1_op_ct",
      "name": "S1 Operator (CT)",
      "team": "Counter-Terrorist",
      "price": 0,
      "vipTier": 0,
      "season": 1,
      "bpLevel": 53
    },
    {
      "id": "s1_op_t",
      "name": "S1 Operator (T)",
      "team": "Terrorist",
      "price": 0,
      "vipTier": 0,
      "season": 1,
      "bpLevel": 53
    },
    {
      "id": "s1_vip_ct",
      "name": "S1 VIP Operator (CT)",
      "team": "Counter-Terrorist",
      "price": 0,
      "vipTier": 2,
      "season": 1,
      "bpLevel": 56
    },
    {
      "id": "s1_vip_t",
      "name": "S1 VIP Operator (T)",
      "team": "Terrorist",
      "price": 0,
      "vipTier": 2,
      "season": 1,
      "bpLevel": 56
    }
  ]
}

export const DEFAULT_ACHIEVEMENTS = {
  version: 2,
  source: "battlepass_core",
  achievements: [
    { bit: 0, id: "kills_100", name: "First Blood Century", desc: "Record 100 ranked kills.", target: 100, reward: "+250 Coins", metric: "kills" },
    { bit: 1, id: "kills_1000", name: "Killing Machine", desc: "Record 1,000 ranked kills.", target: 1000, reward: "+250 Coins", metric: "kills" },
    { bit: 2, id: "kills_5000", name: "FreeNova Legend Killer", desc: "Record 5,000 ranked kills.", target: 5000, reward: "+500 Coins", metric: "kills" },
    { bit: 3, id: "hs_100", name: "Sharpshooter", desc: "Land 100 ranked headshots.", target: 100, reward: "+250 Coins", metric: "hs" },
    { bit: 4, id: "hs_500", name: "Headhunter", desc: "Land 500 ranked headshots.", target: 500, reward: "+500 Coins", metric: "hs" },
    { bit: 5, id: "bomb_specialist", name: "Demolition Expert", desc: "Plant the bomb 50 times.", target: 50, reward: "+250 Coins", metric: "plants" },
    { bit: 6, id: "defusal_angel", name: "Bomb Squad", desc: "Defuse the bomb 25 times.", target: 25, reward: "+250 Coins", metric: "defuses" },
    { bit: 7, id: "wins_100", name: "Team Player", desc: "Win 100 rounds while alive.", target: 100, reward: "+250 Coins", metric: "wins" },
    { bit: 8, id: "level_25", name: "Seasoned Soldier", desc: "Reach level 26.", target: 26, reward: "+250 Coins", metric: "level" },
    { bit: 9, id: "level_52", name: "FreeNova Legend", desc: "Reach level 52.", target: 52, reward: "+1000 Coins", metric: "level" },
    { bit: 11, id: "win_streak_10", name: "Unstoppable", desc: "Get a 10-kill streak in one life.", target: 10, reward: "+500 Coins", metric: "streak" },
    { bit: 12, id: "coin_tycoon", name: "Coin Magnet", desc: "Hold 10,000 coins at once.", target: 10000, reward: "+250 Coins", metric: "coins" },
    { bit: 13, id: "combat_medic", name: "Combat Medic", desc: "Revive 25 teammates.", target: 25, reward: "+500 Coins", metric: "revives" }
  ]
}

export const DEFAULT_EVENTS = {
  "version": 1,
  "events": [
    {
      "id": "event_kill_race",
      "name": "Kill Race: First to 1,000 Kills",
      "desc": "First player on the server to reach 1,000 kills during the event period takes home the grand prize!",
      "active": 1,
      "metric": "kills",
      "target": 1000,
      "bonus": "10,000 Coins + 7 Days VIP ELITE",
      "ends": "2026-09-15 23:59",
      "badge": "TOURNAMENT"
    },
    {
      "id": "event_hs_frenzy",
      "name": "Headshot Frenzy Weekend",
      "desc": "All headshots grant bonus coins. First 3 players to reach 200 headshots during the weekend win bonus loot crates!",
      "active": 0,
      "metric": "headshots",
      "target": 200,
      "bonus": "3,000 Coins + 1.5x XP Boost",
      "ends": "2026-09-14 23:59",
      "badge": "WEEKEND EVENT"
    },
    {
      "id": "event_objective",
      "name": "Operation Objective Master",
      "desc": "Plant or defuse 50 C4 explosives in live matches. Teamplay and objective play rewarded!",
      "active": 1,
      "metric": "c4",
      "target": 50,
      "bonus": "5,000 Coins + Custom Chat Title",
      "ends": "2026-09-14 00:00",
      "badge": "COMMUNITY"
    }
  ]
}

export const DEFAULT_COSMETICS = {
  "version": 1,
  "spawn_effects": {
    "neon_ring": {
      "name": "Neon Energy Ring",
      "cost": 5000,
      "badge": "UNCOMMON",
      "desc": "Expanding emerald neon energy ring around your feet on spawn."
    },
    "fire_aura": {
      "name": "Blazing Fire Aura",
      "cost": 7500,
      "badge": "RARE",
      "desc": "Intense flame aura and fiery particles surrounding you on spawn."
    },
    "lightning_spark": {
      "name": "Thunder Spark Halo",
      "cost": 10000,
      "badge": "EPIC",
      "desc": "Electric discharge and bright sparks radiating upon spawning."
    },
    "shadow_void": {
      "name": "Shadow Void Ring",
      "cost": 12000,
      "badge": "MYTHIC",
      "desc": "Dark smoky dimensional void expanding from your position."
    },
    "divine_light": {
      "name": "Divine Angelic Beacon",
      "cost": 15000,
      "badge": "LEGENDARY",
      "desc": "Heavenly pillar of bright glowing light descending on your spawn."
    }
  },
  "chat_titles": {
    "title_godlike": {
      "name": "[★ GODLIKE]",
      "cost": 3000,
      "badge": "UNCOMMON",
      "tag": "[★ GODLIKE]",
      "color": "#FBBF24",
      "desc": "Golden celestial prefix before your name in all chat."
    },
    "title_phantom": {
      "name": "[⚡ PHANTOM]",
      "cost": 5000,
      "badge": "RARE",
      "tag": "[⚡ PHANTOM]",
      "color": "#38BDF8",
      "desc": "Electric cyan phantom prefix before your name in chat."
    },
    "title_warlord": {
      "name": "[🔥 WARLORD]",
      "cost": 7500,
      "badge": "EPIC",
      "tag": "[🔥 WARLORD]",
      "color": "#EF4444",
      "desc": "Fierce red warlord battle title preceding your chat messages."
    },
    "title_legend": {
      "name": "[👑 LEGEND]",
      "cost": 10000,
      "badge": "MYTHIC",
      "tag": "[👑 LEGEND]",
      "color": "#EAB308",
      "desc": "Regal golden crown title signifying server royalty."
    },
    "title_immortal": {
      "name": "[💀 IMMORTAL]",
      "cost": 15000,
      "badge": "LEGENDARY",
      "tag": "[💀 IMMORTAL]",
      "color": "#A855F7",
      "desc": "Mythical purple deathmaster title commanding maximum respect."
    },
    "title_global_elite": {
      "name": "[ THE GLOBAL ELITE ]",
      "cost": 20000,
      "badge": "CS2 COVERT",
      "tag": "[ THE GLOBAL ELITE ]",
      "color": "#EB4B4B",
      "desc": "Top of the competitive hierarchy. The legendary Global Elite title from Counter-Strike 2."
    },
    "title_premier_master": {
      "name": "[ PREMIER MASTER ]",
      "cost": 18000,
      "badge": "CS2 PINK",
      "tag": "[ PREMIER MASTER ]",
      "color": "#D32CE6",
      "desc": "CS2 Premier 20,000+ Rating champion title commanding respect in every match."
    },
    "title_supreme_master": {
      "name": "[ SUPREME MASTER ]",
      "cost": 15000,
      "badge": "CS2 CLASSIFIED",
      "tag": "[ SUPREME MASTER ]",
      "color": "#D32CE6",
      "desc": "Supreme Master First Class competitive veteran title."
    },
    "title_legendary_eagle": {
      "name": "[ LEGENDARY EAGLE ]",
      "cost": 12000,
      "badge": "CS2 RESTRICTED",
      "tag": "[ LEGENDARY EAGLE ]",
      "color": "#8847FF",
      "desc": "High-tier competitive eagle title demonstrating sharp tactical aim."
    },
    "title_clutch_god": {
      "name": "[ CLUTCH GOD ]",
      "cost": 14000,
      "badge": "CS2 SPECIAL",
      "tag": "[ CLUTCH GOD ]",
      "color": "#F59E0B",
      "desc": "Ice-cold 1vX clutch master title for round-winning anchors."
    },
    "title_major_mvp": {
      "name": "[ MAJOR MVP ]",
      "cost": 25000,
      "badge": "CS2 CONTRABAND",
      "tag": "[ MAJOR MVP ]",
      "color": "#E4AE39",
      "desc": "Crown of tournament legends. The official FreeNova CS2 Major MVP title."
    },
    "title_awp_deity": {
      "name": "[ AWP DEITY ]",
      "cost": 16000,
      "badge": "CS2 SHARPSHOOTER",
      "tag": "[ AWP DEITY ]",
      "color": "#38BDF8",
      "desc": "Unforgiving one-shot one-kill sniper deity title."
    }
  },
  "death_effects": {
    "death_lightning": {
      "name": "Sky Lightning Bolt",
      "cost": 6000,
      "badge": "RARE",
      "desc": "A thunderous lightning strike hits your victim's body upon kill."
    },
    "death_blood": {
      "name": "Crimson Blood Burst",
      "cost": 8000,
      "badge": "EPIC",
      "desc": "A violent blast of high-pressure blood erupts from the defeated enemy."
    },
    "death_frost": {
      "name": "Glacial Frost Shatter",
      "cost": 10000,
      "badge": "MYTHIC",
      "desc": "Victim's body turns to ice and violently shatters into crystal shards."
    },
    "death_skull": {
      "name": "Ascending Skull Ghost",
      "cost": 12000,
      "badge": "LEGENDARY",
      "desc": "A sinister skull spirit ascends from the corpse into the sky."
    }
  },
  "chat_colors": {
    "color_default": {
      "name": "Classic Gold (^1)",
      "cost": 0,
      "badge": "DEFAULT",
      "code": 0,
      "hex": "#EAB308",
      "desc": "Standard server golden yellow chat text."
    },
    "color_green": {
      "name": "Toxic Cyber Green (^4)",
      "cost": 8000,
      "badge": "FREENOVA",
      "code": 1,
      "hex": "#74E600",
      "desc": "Signature FreeNova radiant cyber green chat text. Requires Chat Color License skill."
    },
    "color_team": {
      "name": "Dynamic Team Color (^3)",
      "cost": 8000,
      "badge": "DYNAMIC",
      "code": 2,
      "hex": "#38BDF8",
      "desc": "Dynamic chat text matching your team color (Terrorist Crimson / CT Electric Cyan). Requires Chat Color License skill."
    }
  },
  "custom_tags": {
    "tag_slot": {
      "name": "Custom In-Game Tag Slot",
      "cost": 15000,
      "badge": "PREMIUM",
      "desc": "Permanent custom prefix slot shown before your name in all chat: [ YOUR TEXT ]. Use /tag <text> to set."
    }
  },
  "premade_tags": {
    "tag_freenova": {
      "id": 1,
      "name": "[ FreeNova ]",
      "cost": 2500,
      "badge": "BRAND",
      "color": "#74e600",
      "desc": "Official FreeNova server brand badge prefix."
    },
    "tag_pro": {
      "id": 2,
      "name": "[ PRO ]",
      "cost": 3000,
      "badge": "COMPETITIVE",
      "color": "#38bdf8",
      "desc": "Certified competitive pro shooter prefix."
    },
    "tag_beast": {
      "id": 3,
      "name": "[ BEAST ]",
      "cost": 3000,
      "badge": "WARRIOR",
      "color": "#f97316",
      "desc": "Fierce unstoppable fragger combat tag."
    },
    "tag_clutch": {
      "id": 4,
      "name": "[ CLUTCH ]",
      "cost": 3500,
      "badge": "TACTICAL",
      "color": "#a855f7",
      "desc": "Cold-blooded 1vX clutch round finisher."
    },
    "tag_ace": {
      "id": 5,
      "name": "[ ACE ]",
      "cost": 3500,
      "badge": "DEADLY",
      "color": "#ef4444",
      "desc": "Round-sweep 5-kill ace eliminator."
    },
    "tag_headshot": {
      "id": 6,
      "name": "[ HEADSHOT ]",
      "cost": 4000,
      "badge": "PRECISION",
      "color": "#ffd700",
      "desc": "Precision skull-piercing marksman prefix."
    },
    "tag_onetap": {
      "id": 7,
      "name": "[ ONE TAP ]",
      "cost": 4000,
      "badge": "SHARPSHOOTER",
      "color": "#eab308",
      "desc": "First-bullet lethal accuracy specialist."
    },
    "tag_vip": {
      "id": 8,
      "name": "[ VIP ]",
      "cost": 5000,
      "badge": "ELITE",
      "color": "#84cc16",
      "desc": "Distinguished VIP network status symbol."
    }
  }
}

export const DEFAULT_HALL_OF_FAME = {
  "version": 1,
  "hall_of_fame": [
    {
      "id": "s1_champ",
      "title": "Season 1 Grand Champion",
      "holder_name": "zizouondc",
      "holder_steamid": "STEAM_0:1:12345678",
      "season": "Season 1 (Summer 2026)",
      "record_value": "2,840 ELO | 1.54 Rating",
      "type": "MEDAL",
      "icon": "MEDAL",
      "achieved_date": "2026-08-31"
    },
    {
      "id": "alltime_frags",
      "title": "All-Time Frag Leader",
      "holder_name": "ShadowSniper",
      "holder_steamid": "STEAM_0:0:98765432",
      "season": "Permanent All-Time",
      "record_value": "91,821 Total Kills",
      "icon": "⚔️",
      "achieved_date": "2026-09-01"
    },
    {
      "id": "first_lvl52",
      "title": "First Level 52 Legend",
      "holder_name": "xX_ProGamer_Xx",
      "holder_steamid": "STEAM_0:1:55443322",
      "season": "Milestone Record",
      "record_value": "Reached Max Rank Legend",
      "icon": "🌟",
      "achieved_date": "2026-08-15"
    },
    {
      "id": "hs_master_10k",
      "title": "First 10,000 Headshots",
      "holder_name": "OneTap99",
      "holder_steamid": "STEAM_0:0:11223344",
      "season": "Milestone Record",
      "record_value": "10,000 Pure Headshots",
      "icon": "🎯",
      "achieved_date": "2026-08-20"
    },
    {
      "id": "clutch_god_1v5",
      "title": "Master of the Impossible",
      "holder_name": "ColdBreeze",
      "holder_steamid": "STEAM_0:1:88776655",
      "season": "Competitive All-Time",
      "record_value": "18 Recorded 1v5 Clutches",
      "icon": "🛡️",
      "achieved_date": "2026-09-05"
    },
    {
      "id": "coin_billionaire",
      "title": "Server High Roller",
      "holder_name": "VipElite_King",
      "holder_steamid": "STEAM_0:1:99887766",
      "season": "Economy Milestone",
      "record_value": "125,000 Lifetime Coins",
      "icon": "💰",
      "achieved_date": "2026-09-07"
    }
  ],
  "server_records": [
    {
      "key": "highest_rating",
      "name": "Highest Match Rating",
      "icon": "⭐",
      "unit": "Rating"
    },
    {
      "key": "most_kills",
      "name": "Most Career Kills",
      "icon": "⚔️",
      "unit": "Kills"
    },
    {
      "key": "highest_kd",
      "name": "Highest K/D Ratio",
      "icon": "📊",
      "unit": "K/D"
    },
    {
      "key": "highest_adr",
      "name": "Highest Average Damage (ADR)",
      "icon": "💥",
      "unit": "ADR"
    },
    {
      "key": "most_headshots",
      "name": "Most Headshots",
      "icon": "🎯",
      "unit": "HS"
    },
    {
      "key": "highest_hs_pct",
      "name": "Highest Headshot %",
      "icon": "🎯",
      "unit": "%"
    },
    {
      "key": "longest_killstreak",
      "name": "Longest Killstreak",
      "icon": "🔥",
      "unit": "Kills"
    },
    {
      "key": "most_1v5_clutches",
      "name": "Most 1v5 Clutches",
      "icon": "🛡️",
      "unit": "Wins"
    },
    {
      "key": "most_mvps",
      "name": "Most MVP Awards",
      "icon": "🎖️",
      "unit": "MVPs"
    },
    {
      "key": "most_match_kills",
      "name": "Most Kills in One Match",
      "icon": "🩸",
      "unit": "Kills"
    },
    {
      "key": "most_ak_kills",
      "name": "Most AK-47 Kills",
      "icon": "🔫",
      "unit": "Kills"
    },
    {
      "key": "most_awp_kills",
      "name": "Most AWP Kills",
      "icon": "🔭",
      "unit": "Kills"
    },
    {
      "key": "most_deagle_kills",
      "name": "Most Deagle Kills",
      "icon": "💥",
      "unit": "Kills"
    },
    {
      "key": "most_knife_kills",
      "name": "Most Knife Kills",
      "icon": "🔪",
      "unit": "Kills"
    },
    {
      "key": "most_wallbangs",
      "name": "Most Wallbang Kills",
      "icon": "🧱",
      "unit": "Kills"
    },
    {
      "key": "most_playtime",
      "name": "Most Active Playtime",
      "icon": "⏳",
      "unit": "Hours"
    }
  ]
}
