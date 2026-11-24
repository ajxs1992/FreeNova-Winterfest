// FreeNova Top15 theme — modern neon-cyan brand skin (matches official FN logo).
// Data contracts (sort/weapon/skill/XP) still follow the Tornado Rank System
// reference; visuals are the full re-layout. GoldSrc MOTD cannot use CSS
// variables; callers inline hex from this object.

export const PAGE_SIZE = 15

export const SORT_FIELDS = Object.freeze({
  xp: { label: "XP", sql: "p.xp", dirDefault: "desc" },
  name: { label: "Name", sql: "p.name COLLATE NOCASE", dirDefault: "asc" },
  kills: { label: "Kills", sql: "p.kills", dirDefault: "desc" },
  deaths: { label: "Deaths", sql: "p.deaths", dirDefault: "desc" },
  hs: { label: "HS %", sql: "CASE WHEN p.kills > 0 THEN (p.headshots * 100.0 / p.kills) ELSE 0 END", dirDefault: "desc" },
  weapon: { label: "Weapon", sql: "COALESCE(w.kills, 0)", dirDefault: "desc" },
  skill: { label: "Skill", sql: "CASE WHEN (p.kills + p.deaths) > 0 THEN (100.0 * p.kills / (p.kills + p.deaths)) ELSE 0 END", dirDefault: "desc" },
  rank: { label: "Rank", sql: "p.rank_id", dirDefault: "desc" },
  level: { label: "Level", sql: "p.level", dirDefault: "desc" },
  wins: { label: "Wins", sql: "p.wins", dirDefault: "desc" },
  mvp: { label: "MVP", sql: "p.mvps", dirDefault: "desc" },
  kd: { label: "K/D", sql: "CASE WHEN p.deaths > 0 THEN (p.kills * 1.0 / p.deaths) ELSE p.kills END", dirDefault: "desc" },
  acc: { label: "ACC", sql: "CASE WHEN p.shots > 0 THEN (p.hits * 100.0 / p.shots) ELSE 0 END", dirDefault: "desc" },
  playtime: { label: "Playtime", sql: "p.playtime_minutes", dirDefault: "desc" }
})

// DEFAULT_ORDER = 13 0 → Overall, Knife. Overall is XP with weapon-kills column.
export const DEFAULT_SORT = "xp"
export const DEFAULT_DIR = "desc"
export const DEFAULT_WEAPON = 17

// Tornado weapon_id 0..25 → player_weapons.slot (freenova_wpn.inc) or -1 if unused.
export const TORNADO_WEAPONS = Object.freeze([
  { id: 0, name: "Knife", short: "Knife", slot: 4, img: "/i/gun_knife.png" },
  { id: 1, name: "Glock-18", short: "Glock", slot: 6, img: "/i/gun_glock.png" },
  { id: 2, name: "USP", short: "USP", slot: 5, img: "/i/gun_usp.png" },
  { id: 3, name: "P228", short: "P228", slot: -1, img: "/i/gun_p228.png" },
  { id: 4, name: "Desert Eagle", short: "Deagle", slot: 3, img: "/i/gun_deagle.png" },
  { id: 5, name: "Five-Seven", short: "FiveSeven", slot: -1, img: "/i/gun_fiveseven.png" },
  { id: 6, name: "Dual Elites", short: "Elites", slot: -1, img: "/i/gun_elites.png" },
  { id: 7, name: "M3", short: "M3", slot: 18, img: "/i/gun_m3.png" },
  { id: 8, name: "XM1014", short: "XM1014", slot: 19, img: "/i/gun_xm1014.png" },
  { id: 9, name: "TMP", short: "TMP", slot: 16, img: "/i/gun_tmp.png" },
  { id: 10, name: "MAC-10", short: "MAC10", slot: 15, img: "/i/gun_mac10.png" },
  { id: 11, name: "MP5 Navy", short: "MP5", slot: 12, img: "/i/gun_mp5.png" },
  { id: 12, name: "UMP-45", short: "UMP45", slot: 14, img: "/i/gun_ump45.png" },
  { id: 13, name: "P90", short: "P90", slot: 13, img: "/i/gun_p90.png" },
  { id: 14, name: "M249", short: "M249", slot: 17, img: "/i/gun_m249.png" },
  { id: 15, name: "Galil", short: "Galil", slot: 8, img: "/i/gun_galil.png" },
  { id: 16, name: "FAMAS", short: "FAMAS", slot: 7, img: "/i/gun_famas.png" },
  { id: 17, name: "AK-47", short: "AK47", slot: 0, img: "/i/gun_ak47.png" },
  { id: 18, name: "M4A1", short: "M4A1", slot: 1, img: "/i/gun_m4a1.png" },
  { id: 19, name: "SG-552", short: "SG552", slot: 11, img: "/i/gun_sg552.png" },
  { id: 20, name: "AUG", short: "AUG", slot: 10, img: "/i/gun_aug.png" },
  { id: 21, name: "Scout", short: "Scout", slot: 9, img: "/i/gun_scout.png" },
  { id: 22, name: "AWP", short: "AWP", slot: 2, img: "/i/gun_awp.png" },
  { id: 23, name: "G3-SG1", short: "G3SG1", slot: 21, img: "/i/gun_g3sg1.png" },
  { id: 24, name: "SG-550", short: "SG550", slot: 20, img: "/i/gun_sg550.png" },
  { id: 25, name: "HE Grenade", short: "HE", slot: 22, img: "/i/gun_he.png" },
])

export const SKILL_BANDS = Object.freeze([
  { min: 0, name: "L-", color: "#FCE590" },
  { min: 60, name: "L", color: "#FCE590" },
  { min: 75, name: "L+", color: "#FCE590" },
  { min: 85, name: "M-", color: "#FFC900" },
  { min: 100, name: "M", color: "#FFC900" },
  { min: 115, name: "M+", color: "#FFC900" },
  { min: 130, name: "H-", color: "#F2880F" },
  { min: 140, name: "H", color: "#F2880F" },
  { min: 150, name: "H+", color: "#F2880F" },
  { min: 165, name: "P-", color: "#FF3333" },
  { min: 180, name: "P", color: "#FF3333" },
  { min: 195, name: "P+", color: "#FF3333" },
  { min: 210, name: "G", color: "#000000" }
])

export const XP_COLORS = Object.freeze([
  { min: 30000, color: "#FBD701" },
  { min: 25000, color: "#E94A46" },
  { min: 20000, color: "#E315F1" },
  { min: 15000, color: "#BD6DFA" },
  { min: 10000, color: "#6A80E4" },
  { min: 5000, color: "#8BBCE6" },
  { min: 0, color: "#E1D9D1" }
])

export const DEFAULT_THEME = Object.freeze({
  bg: "#08130f",
  surface: "#0f201a",
  headerBg: "#152c23",
  rowOdd: "#0c1a15",
  rowEven: "#11231c",
  youBg: "#153b2e",
  border: "#2b4c3f",
  text: "#f3fbf7",
  muted: "#a3c1b4",
  primary: "#3dff9e",
  secondary: "#4de8e0",
  accent: "#b18cff",
  hot: "#ff4dd2",
  idColor: "#3dff9e",
  pageColor: "#4de8e0",
  searchColor: "#3dff9e",
  online: "#3dff9e",
  offline: "#5d7a6e",
  newTag: "#ff4dd2",
  font: "Segoe UI Variable Text,Segoe UI,Tahoma,Arial,sans-serif",
  fontSize: 12,
  rowHeight: 34,
  cellPad: 5,
  rankW: 30,
  weaponW: 18,
  trophyW: 16,
  pageSize: PAGE_SIZE,
  newSeconds: 7200
})

const HEX = /^#[0-9a-fA-F]{6}$/
const THEME_KEYS = Object.keys(DEFAULT_THEME)

export function normalizeTheme(raw) {
  const out = { ...DEFAULT_THEME }
  if (!raw || typeof raw !== "object") return out
  for (const k of THEME_KEYS) {
    if (raw[k] == null || raw[k] === "") continue
    if (typeof DEFAULT_THEME[k] === "number") {
      const n = Number(raw[k])
      if (Number.isFinite(n) && n > 0 && n < 10000) out[k] = n
    } else if (typeof DEFAULT_THEME[k] === "string" && DEFAULT_THEME[k][0] === "#") {
      const v = String(raw[k])
      if (HEX.test(v)) out[k] = v
    } else if (k === "font") {
      const v = String(raw[k]).replace(/[^a-zA-Z0-9,\- ]/g, "").slice(0, 80)
      if (v) out[k] = v
    }
  }
  return out
}

export function skillOf(kills, deaths) {
  const tot = Number(kills) + Number(deaths)
  const ratio = tot > 0 ? (100 * Number(kills)) / tot : 0
  let band = SKILL_BANDS[0]
  for (const b of SKILL_BANDS) if (ratio >= b.min) band = b
  return { ratio, name: band.name, color: band.color }
}

export function xpColorOf(xp) {
  const n = Number(xp) || 0
  for (const step of XP_COLORS) if (n >= step.min) return step.color
  return "#E1D9D1"
}

export function weaponById(id) {
  const n = Number(id)
  return TORNADO_WEAPONS.find(w => w.id === n) || TORNADO_WEAPONS[0]
}

// Canonical name aliases (mp5/mp5navy, glock/glock18, cv47/ak47, ...).
// Nothing in the hot path resolves by name today; the gallery and any
// future consumer use this so aliases never fork the asset set.
const WEAPON_ALIASES = Object.freeze({
  knife: 0, glock: 1, glock18: 1, usp: 2, p228: 3, deagle: 4, "desert eagle": 4,
  fiveseven: 5, "five-seven": 5, elite: 6, elites: 6, "dual elites": 6,
  m3: 7, xm1014: 8, tmp: 9, mac10: 10, "mac-10": 10, mp5: 11, mp5navy: 11,
  "mp5 navy": 11, ump45: 12, "ump-45": 12, p90: 13, m249: 14, galil: 15,
  famas: 16, ak47: 17, cv47: 17, "ak-47": 17, m4a1: 18, sg552: 19, "sg-552": 19,
  aug: 20, scout: 21, awp: 22, g3sg1: 23, "g3-sg1": 23, sg550: 24, he: 25,
  hegrenade: 25, "he grenade": 25, flashbang: -1, c4: -2, smoke: -3
})

export function weaponByName(raw) {
  const k = String(raw || "").toLowerCase().replace(/[^a-z0-9]+/g, "")
  const plain = String(raw || "").toLowerCase().trim()
  if (Object.prototype.hasOwnProperty.call(WEAPON_ALIASES, plain)) {
    const id = WEAPON_ALIASES[plain]
    if (id < 0) return { id, name: plain, slot: -1, img: id === -2 ? "/i/gun_c4.png" : (id === -1 ? "/i/gun_flashbang.png" : "") }
    return weaponById(id)
  }
  if (Object.prototype.hasOwnProperty.call(WEAPON_ALIASES, k)) {
    const id = WEAPON_ALIASES[k]
    if (id < 0) return { id, name: plain, slot: -1, img: id === -2 ? "/i/gun_c4.png" : (id === -1 ? "/i/gun_flashbang.png" : "") }
    return weaponById(id)
  }
  return null
}

export function parseSort(raw) {
  const k = String(raw || "").toLowerCase()
  return SORT_FIELDS[k] ? k : DEFAULT_SORT
}

export function parseDir(raw) {
  return String(raw || "").toLowerCase() === "asc" ? "asc" : "desc"
}

export function parseWeapon(raw) {
  const n = parseInt(raw, 10)
  return Number.isInteger(n) && n >= 0 && n <= 25 ? n : DEFAULT_WEAPON
}

export function parsePage(raw) {
  const n = parseInt(raw, 10)
  return Number.isInteger(n) && n >= 1 && n <= 10000 ? n : 1
}

export function parseQuery(raw) {
  return String(raw || "").trim().slice(0, 32)
}
