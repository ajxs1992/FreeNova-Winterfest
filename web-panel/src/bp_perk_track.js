// Live Season 1 60-tier perk track. Mirrored by the AMXX Battle Pass grants.
// This table is the display source for free/premium rewards.


const comma = (n) => String(n).replace(/\B(?=(\d{3})+(?!\d))/g, ",")
const freeCoins = (t) => 100 + Math.floor((t - 1) / 2) * 50
const premCoins = (t) => 150 + Math.floor((t - 1) / 2) * 75

const overrides = {}
function set(tier, free, icon, opts = {}) {
  overrides[tier] = { free, icon, ...opts }
}

// Early vanilla perks.
set(2, "+1 HP on spawn", "heart")
set(4, "+2 Armor on spawn", "armor", { premium: "Premium Chat Color", premIcon: "paint" })
set(6, "+1% Move Speed", "speed")
set(8, "Defuse Kit on Spawn", "defuse", { premium: "Premium Tag", premIcon: "tag" })
set(10, "Parachute", "chute")
set(12, "Double Jump", "jump", { premium: "Premium Spawn Effect", premIcon: "aura" })
set(14, "Extra HE Purchase", "he")

// First skill stages.
set(16, "Spawn HP +2", "heart", { premium: "Premium AK Skin", premIcon: "rifle" })
set(18, "Spawn Armor +3", "armor")
set(20, "Nimble +1% Speed", "speed", { premium: "Premium Spawn Effect", premIcon: "aura" })
set(22, "Vampire +1 HP/Kill", "vampire")
set(24, "Featherfall 15%", "chute", { premium: "Premium Knife Skin", premIcon: "knife" })
set(26, "Fast Sniper 10%", "sniper")
set(28, "HealthNade 15 HP", "medkit", { premium: "Premium Model", premIcon: "model" })
set(30, "Combat Medic 3s", "medkit")
set(32, "Last Stand 5 HP", "shield", { premium: "Premium Aura", premIcon: "aura" })
set(34, "AWP License", "sniper")
set(36, "Chat Color", "paint", { premium: "Premium Title", premIcon: "title" })

// Second and third skill stages.
set(38, "Spawn HP +4", "heart")
set(39, "Spawn Armor +6", "armor")
set(40, "Nimble +2% Speed", "speed", { premium: "Premium M4 Skin", premIcon: "rifle" })
set(41, "Vampire +2 HP/Kill", "vampire")
set(42, "Featherfall 30%", "chute")
set(43, "Fast Sniper 20%", "sniper")
set(44, "HealthNade 30 HP", "medkit", { premium: "Premium AWP Skin", premIcon: "sniper" })
set(45, "Combat Medic 2s", "medkit")
set(46, "Last Stand 10 HP", "shield")
set(47, "Triple Jump", "jump")
set(48, "Spawn HP +6", "heart", { premium: "Premium Title", premIcon: "title" })
set(49, "Spawn Armor +9", "armor")
set(50, "Nimble +3% Speed", "speed")
set(51, "Vampire +3 HP/Kill", "vampire")
set(52, "Featherfall 45%", "chute", { premium: "Premium Knife", premIcon: "knife" })
set(53, "Quad Jump", "jump")

// Late small stat stacks.
set(54, "+1 HP on spawn", "heart")
set(55, "+2 Armor on spawn", "armor")
set(56, "+1% Move Speed", "speed", { premium: "Premium Model II", premIcon: "model" })
set(57, "+1 HP on spawn", "heart")
set(58, "+2 Armor on spawn", "armor")
set(59, "+1% Move Speed", "speed")
set(60, "+2,000 Coins", "coins", { premium: "Global Elite Title + 5,000 Coins", premIcon: "title" })

// Premium-only skill bonuses. These are small, capped upgrades after the base
// skill unlocks, so premium does not double the free track.
function primeOn(tier, text, icon) {
  const base = overrides[tier] || {
    free: `+${comma(freeCoins(tier))} Coins`,
    icon: "coins"
  }
  overrides[tier] = { ...base, premium: text, premIcon: icon }
}
primeOn(17, "Spawn HP Prime +1", "heart")
primeOn(19, "Spawn Armor Prime +2", "armor")
primeOn(21, "Nimble Prime +1%", "speed")
primeOn(25, "Featherfall Prime +5%", "chute")
primeOn(33, "Spawn Armor Prime +2", "armor")
primeOn(37, "Nimble Prime +1%", "speed")
primeOn(45, "Fast Sniper Prime +5%", "sniper")
primeOn(49, "HealthNade Prime +5 HP", "medkit")
primeOn(53, "Last Stand Prime +2 HP", "shield")
primeOn(55, "Spawn HP Prime +1", "heart")
primeOn(57, "Nimble Prime +1%", "speed")

export const PERK_PREVIEW_TRACK = {
  season: 1,
  xp_per_tier: 1000,
  tiers: Array.from({ length: 60 }, (_, i) => {
    const tier = i + 1
    const o = overrides[tier]
    if (!o) {
      return {
        tier,
        free: `+${comma(freeCoins(tier))} Coins`,
        premium: `+${comma(premCoins(tier))} Coins`,
        name: "Coin cache",
        icon: "coins",
        premIcon: "coins",
        rarity: "normal"
      }
    }
    return {
      tier,
      free: o.free,
      premium: o.premium || (o.premSame ? o.free : `+${comma(premCoins(tier))} Coins`),
      name: o.free,
      icon: o.icon,
      premIcon: o.premIcon || (o.premSame ? o.icon : "coins"),
      rarity: o.icon === "coins" ? "normal" : "rare"
    }
  })
}
