// FreeNova web panel — shared design system (GoldSrc-first).
// Rules that keep panels working inside the CS 1.6 MOTD browser:
//   - server-rendered HTML, ZERO client-side JS (tabs/sorting are plain links)
//   - fluid percentage layout; no fixed widths, no position:fixed overlays
//   - table-based structure (renders identically in old IE-era engines and CEF)
//   - no custom cursors, no drag handling, no iframes (prevents MOTD cursor bugs)
//   - everything user-controlled (names, tags) passes through esc()

const ACCENT = "#2EBF92"

// Per-product chrome tokens (GoldSrc-safe: inline style overrides only, no CSS vars).
// accent   → header text, .h2, links, progress-bar fill, active-tab highlight
// headBg   → <body bgcolor> and motd-head <table bgcolor>
// kicker   → sub-line under the FREENOVA logotype
const PRODUCT_THEME = {
  profile:      { accent: "#7dd3fc", headBg: "#0a1218", kicker: "AGENT FILE" },
  top:          { accent: "#fbbf24", headBg: "#14100a", kicker: "LEADERBOARD" },
  battlepass:   { accent: "#e8c547", headBg: "#141208", kicker: "SEASON TRACK" },
  missions:     { accent: "#36DEAB", headBg: "#070B0C", kicker: "CONTRACTS" },
  achievements: { accent: "#c084fc", headBg: "#120a18", kicker: "MEDALS" },
  tournament:   { accent: "#f07178", headBg: "#180a0c", kicker: "SEASON" },
  vip:          { accent: "#e8c547", headBg: "#141208", kicker: "MEMBERSHIP" },
  events:       { accent: "#2EBF92", headBg: "#071210", kicker: "LIVE" }
}
let motdCompact = false
export function setMotdCompact(v) { motdCompact = !!v }
export function isMotdCompact() { return motdCompact }

// Display names for the stable weapon slots defined in freenova_wpn.inc.
// These mirror the game plugin's slot table (contract, not invented data).
const WEAPONS = [
  "AK-47", "M4A1", "AWP", "Desert Eagle", "Knife", "USP", "Glock-18",
  "FAMAS", "Galil", "Scout", "AUG", "SG-552", "MP5 Navy", "P90", "UMP-45",
  "MAC-10", "TMP", "M249", "M3", "XM1014", "SG-550", "G3-SG1", "HE Grenade"
]

// FreeNova skill word tiers, derived from the Rating value (one decimal
// step ladder, defined here AND in the game HUD/sync code — contract).
const SKILL_TIERS = [
  [80, "Rookie"], [100, "Developing"], [115, "Average"], [130, "Skilled"],
  [150, "Advanced"], [175, "Elite"], [200, "Master"], [250, "Champion"],
  [Infinity, "Global"]
]

function skillName(ratingX100) {
  const r = num(ratingX100)
  for (const [max, name] of SKILL_TIERS) if (r < max) return name
  return "Global"
}

function vipName(t) {
  return t === 3 ? "VIP Elite" : t === 2 ? "VIP+" : t === 1 ? "VIP" : "Member"
}

// Cosmetic display names, mirroring freenova_cosmetics.sma catalogs.
const COSMETICS = {
  spawn: ["None", "Neon Energy Ring", "Blazing Fire Aura", "Thunder Spark Halo", "Shadow Void Ring", "Divine Angelic Beacon"],
  title: ["None", "GODLIKE", "PHANTOM", "WARLORD", "LEGEND", "IMMORTAL"],
  death: ["None", "Sky Lightning", "Crimson Blood", "Glacial Frost", "Ascending Skull"],
  color: ["Default", "Green", "Team"]
}

// 16px PNG icons served from /i/<name>.png (assets folder). If an icon file
// does not exist the Worker emits a safe text glyph instead (verified
// server-side via the assets binding — no broken-image icons ever).
const ICONS = {
  home: "*", top: "#", battlepass: "P", missions: "v", tournament: "F",
  skins: "W", models: "M", profile: "@", kill: "x", death: "-",
  hs: "T", assist: ">", win: "W", rating: "S", xp: "X", coins: "C",
  level: "L", time: "o", vip: "V", tag: '"', search: "?", lock: "x",
  check: "v", pass: "P", damage: "D", arrow_up: "^", arrow_down: "v"
}

function flagImg(cc, w, h) {
  const code = String(cc || "").toLowerCase().replace(/[^a-z]/g, "").slice(0, 2)
  if (!/^[a-z]{2}$/.test(code)) return ""
  const ww = w || 20, hh = h || 15
  return `<img src='https://flagcdn.com/20x15/${code}.png' width='${ww}' height='${hh}' alt='${code}' border='0' onerror='this.style.display="none"'> `
}

function icon(name, alt) {
  return `<img src='/i/${esc(name)}.png' width='16' height='16' alt='${esc(alt || name)}' border='0' style='vertical-align:-3px'> `
}

/* Navigation shared by every page matching Image #1 Navbar */
function navQ(steamid, extra) {
  const p = []
  if (steamid) p.push("steamid=" + encodeURIComponent(steamid))
  const compactBit = extra && String(extra).includes("compact=1")
  if (compactBit) p.push("compact=1")
  if (extra && extra !== "compact=1") {
    for (const part of String(extra).split("&")) {
      if (!part || part === "compact=1" || part.startsWith("steamid=")) continue
      p.push(part)
    }
  }
  return p.length ? ("?" + p.join("&")) : ""
}

function motdSidShort(steamid) {
  return String(steamid || "").replace(/^STEAM_/i, "").replace(/:/g, "-")
}

const PAGE_CODE = { profile: "p", battlepass: "b", top: "t", missions: "i", achievements: "a", vip: "v", models: "o", events: "e", tournament: "r", store: "s" }

function navHref(page, steamid, compactMode, tab) {
  const slug = String(page || "profile").replace(/^\//, "")
  const code = PAGE_CODE[slug] || "p"
  const tabSafe = String(tab || "").toLowerCase().replace(/[^a-z0-9]/g, "").slice(0, 12)
  if (compactMode && steamid) {
    const short = motdSidShort(steamid)
    return tabSafe ? `/m/${code}/${short}/${tabSafe}.htm` : `/m/${code}/${short}.htm`
  }
  const extra = [compactMode ? "compact=1" : "", tabSafe ? ("tab=" + tabSafe) : ""].filter(Boolean).join("&")
  return "/" + slug + navQ(steamid, extra)
}

function panelHref(page, steamid, tab) {
  return navHref(page, steamid, isMotdCompact(), tab)
}

function nav(_active, _steamid, _compactMode) {
  // MOTD panels are standalone. In-game N menu is the only way between products.
  return ""
}

function tabBar(items, active, hrefFn) {
  return `<table class='tabs' width='100%' cellspacing='0' cellpadding='6' border='0'><tr><td>` +
    items.map(([k, label]) => k === active
      ? `<span class='pill on'>${esc(label)}</span>`
      : `<a class='pill' href='${hrefFn(k)}'>${esc(label)}</a>`
    ).join("") + `</td></tr></table>`
}

function medalTable(items, renderCell) {
  const perRow = 5
  const cell = renderCell || ((it) => {
    const src = it.art || it.src || "/medals/fn_badge_01.png"
    return `<img src='${src}' width='48' height='48' alt='' border='0'><br><b>${esc(it.title || it.name || "")}</b>`
  })
  let out = `<table width='100%' cellspacing='4' cellpadding='6' border='0'>`
  for (let i = 0; i < items.length; i += perRow) {
    out += `<tr>`
    for (let j = 0; j < perRow; j++) {
      const it = items[i + j]
      out += it
        ? `<td class='medal-td' width='20%' align='center' valign='top'>${cell(it)}</td>`
        : `<td width='20%'></td>`
    }
    out += `</tr>`
  }
  return out + `</table>`
}

// Tornado RSU MOTD recipe: HTTP + tables + hex colors. GoldSrc IE ignores
// CSS variables, flex, grid, and Google Fonts — that is why the full theme
// painted white and hid logos. These rules duplicate the modern palette
// with only IE-safe properties.
const MOTD_CSS = `
html,body{background:#04110e;color:#e3f4ee;margin:0;padding:4px;font-family:Segue UI,Tahoma,Arial,sans-serif;font-size:13px;line-height:1.45;}
a{color:#3dff9e;text-decoration:none;}
a:hover{color:#2be7e7;}
img{border:0;background:#0a1c18;vertical-align:middle;}
.wrap{width:780px;max-width:100%;margin:0 auto;padding:4px 4px 12px;}
.motd-head{background:#0a1c18;border:1px solid #17493d;border-radius:14px;padding:10px 14px;margin-bottom:10px;}
.hero-title{font-size:22px;font-weight:800;letter-spacing:4px;}
.hero-title{font-size:22px;font-weight:800;letter-spacing:4px;color:#3dff9e;}
.hero-kick{font-size:10px;letter-spacing:2px;color:#7fa89d;}
.hero-sub{font-size:11px;color:#7fa89d;}
.hero-sub{font-size:11px;color:#7fa89d;}
.nav{background:#0a1c18;border:1px solid #17493d;border-radius:12px;margin-bottom:10px;}
.nav-td{white-space:nowrap;}
.nav-td a{color:#7fa89d;font-weight:bold;}
.nav-td .nav-a{color:#04110e;background:#3dff9e;}
.tabs{background:#0a1c18;border:1px solid #17493d;border-radius:12px;margin-bottom:10px;}
.tab-td{white-space:nowrap;}
.tab-td a{color:#7fa89d;font-weight:bold;border:1px solid #17493d;border-radius:99px;padding:3px 11px;}
.tab-td b{color:#04110e;background:#3dff9e;border-radius:99px;padding:3px 11px;}
.card,.csgo-hud-card{background:#0a1c18;border:1px solid #17493d;border-radius:12px;padding:8px 11px;margin-bottom:10px;color:#e3f4ee;}
.h2{color:#3dff9e;font-size:14px;font-weight:bold;letter-spacing:1.5px;margin:0 0 4px;text-transform:uppercase;}
.sub{font-size:10px;letter-spacing:1.7px;color:#7fa89d;}
.muted{color:#7fa89d;}
.small{font-size:11px;color:#7fa89d;}
.c{text-align:center;}
.t{width:100%;border-collapse:collapse;background:#0a1c18;color:#e3f4ee;}
.t th{background:#0d2620;color:#3dff9e;text-align:left;padding:4px;border-bottom:1px solid #17493d;font-size:11px;letter-spacing:1px;}
.t td{padding:4px;border-bottom:1px solid #0d2620;color:#e3f4ee;}
.rank-img,.rank-img-lg,.brand-logo-img,.gun-img,.medal-img,.msn-ico,.trophy{display:inline;}
.bar{background:#0a1c18;height:10px;overflow:hidden;border:1px solid #17493d;border-radius:99px;}
.bar div{background:#3dff9e;height:10px;}
.t .k{color:#7fa89d;}
.t .v{color:#ffffff;text-align:right;font-weight:bold;}
.badge{display:inline-block;border:1px solid #17493d;background:#061512;color:#7fa89d;border-radius:99px;padding:2px 10px;font-size:11px;font-weight:bold;letter-spacing:.5px;}
.badge.done{border-color:#3dff9e;color:#3dff9e;}
.ok{color:#3dff9e;font-weight:bold;}
.green{color:#3dff9e;}
.err{border:1px solid #f07178;background:#180a0c;border-radius:12px;padding:8px 11px;color:#e3f4ee;margin-bottom:10px;}
.err b{color:#f07178;}
.msn-card{background:#0a1c18;border:1px solid #17493d;border-radius:12px;margin-bottom:8px;padding:8px 11px;}
.msn-art{border:1px solid #17493d;border-radius:10px;background:#04110e;padding:4px;display:inline-block;}
.msn-title{color:#ffffff;font-weight:bold;}
.msn-rew{color:#3dff9e;}
.msn-meta{font-size:11px;color:#7fa89d;}
.medal-td{color:#e3f4ee;}
.chip{display:inline-block;border:1px solid #17493d;background:#061512;border-radius:99px;padding:3px 11px;font-size:11px;color:#7fa89d;}
.chip b{color:#3dff9e;font-weight:800;margin-left:6px;}
.tile{background:#0a1c18;border:1px solid #17493d;border-radius:12px;padding:8px 11px;vertical-align:top;}
.statk{font-size:10px;letter-spacing:1.5px;color:#7fa89d;text-transform:uppercase;}
.statv{font-size:19px;font-weight:800;color:#ffffff;margin-top:2px;}
.pill{display:inline-block;border:1px solid #17493d;background:#061512;color:#7fa89d;border-radius:99px;padding:3px 11px;margin:4px 6px 0 0;font-size:11px;}
a.pill:hover{border-color:#2be7e7;color:#2be7e7;}
.pill.on{background:#0e3229;border-color:#3dff9e;color:#3dff9e;font-weight:800;}
.btn,.btn-buy,.btn-store{display:inline-block;background:#3dff9e;color:#04110e;border:0;border-radius:8px;padding:5px 14px;font-family:inherit;font-size:13px;font-weight:800;text-align:center;}
.btn-locked{display:inline-block;background:#0d2620;color:#3f5f57;border:1px solid #17493d;border-radius:8px;padding:5px 14px;font-size:13px;text-align:center;}
.inp{background:#04110e;color:#3dff9e;border:1px solid #17493d;border-radius:8px;padding:5px 10px;font-family:inherit;font-size:13px;}
.store-grid{width:100%;}
.store-card{background:#0a1c18;border:1px solid #17493d;border-radius:12px;padding:8px 11px;}
.store-card-header{font-size:14px;font-weight:bold;color:#3dff9e;letter-spacing:1px;}
.store-card-sub{font-size:11px;color:#7fa89d;}
.store-card-title{color:#ffffff;font-weight:bold;}
.store-card-img{text-align:center;}
.store-card-footer{margin-top:6px;}
.store-price{color:#e8c547;font-weight:bold;}
.store-hero{background:#0a1c18;border:1px solid #17493d;border-radius:12px;padding:8px 11px;margin-bottom:10px;}
.store-hero-balance{color:#e8c547;font-weight:bold;}
.tier-badge{display:inline-block;border:1px solid #17493d;border-radius:99px;padding:2px 10px;font-size:11px;font-weight:bold;color:#7fa89d;}
.tier-radiant{border-color:#e8c547;color:#e8c547;}
.tip{font-size:11px;color:#7fa89d;}
.tt{font-size:11px;}
.foot{display:none;}
.icon-shine,.tipc{display:none;}
.empty{border:1px dashed #17493d;border-radius:12px;color:#7fa89d;padding:10px;text-align:center;}
code{color:#3dff9e;}
.pass-scroll { width:100%; overflow-x:scroll; overflow-y:hidden; }
.pass-scroll table { border-collapse:collapse; }
.pass-cell { width:16%; }
.bp-grid td { width:16%; }
/* Battle Pass browser skin -- reference layout: header bar (level badge,
   segmented XP, pass-state chips), lane ticket cards, dual reward rows with
   numbered nodes between. GoldSrc rules: solid hex only, tables, no
   flex/grid display, no custom-property calls, no fixed positioning, no
   viewport units, no child-index selectors -- degrades to plain blocks in IE7. */
.csgo-pass { width:100%; }
.bp-head td { background:#0D0F0E; border:1px solid #2A3A36; padding:6px; color:#EDF1EF; vertical-align:middle; }
.bp-lvl { background:#e8c547; color:#141208; font-size:24px; font-weight:bold; text-align:center; border:2px solid #ffd700; padding:6px 0; border-radius:6px; }
.bp-lvl-lab { color:#B7C1BC; font-size:9px; text-align:center; letter-spacing:2px; padding-top:3px; }
.bp-kick { color:#e8c547; font-size:10px; letter-spacing:2px; }
.bp-season { color:#ffffff; font-size:15px; font-weight:bold; }
.bp-meta { color:#B7C1BC; font-size:11px; }
.bp-seg { width:100%; margin-top:5px; }
.bp-seg td { height:9px; background:#16352C; border:1px solid #2A3A36; font-size:1px; line-height:1px; padding:0; }
.bp-seg td.on { background:#e8c547; }
.bp-xp { color:#ffffff; font-size:11px; font-weight:bold; }
.bp-next { color:#B7C1BC; font-size:10px; }
.bp-chip { border:1px solid #2A3A36; background:#1E2422; padding:3px 7px; text-align:center; margin-bottom:4px; }
.bp-chip .lab { color:#B7C1BC; font-size:9px; letter-spacing:1px; }
.bp-chip .val { font-size:11px; font-weight:bold; }
.bp-chip.gold { border-color:#e8c547; background:#141208; }
.bp-chip.gold .val { color:#e8c547; }
.bp-chip.mint { border-color:#3dff9e; background:#04110e; }
.bp-chip.mint .val { color:#3dff9e; }
.bp-ticket { border:2px solid #2A3A36; background:#0D0F0E; padding:7px 5px; margin-bottom:6px; text-align:center; }
.bp-ticket.gold { border-color:#e8c547; background:#141208; }
.bp-ticket.mint { border-color:#3dff9e; background:#04110e; }
.bp-ticket .tk { color:#ffffff; font-size:12px; font-weight:bold; letter-spacing:1px; }
.bp-ticket .st { font-size:10px; color:#B7C1BC; padding-top:2px; }
.bp-ticket .st.on { color:#3dff9e; }
.bp-ticket .st.no { color:#71827A; }
.bp-ticket .nt { font-size:9px; color:#71827A; padding-top:3px; }
.csgo-pass-rail { font-size:10px; letter-spacing:2px; color:#B7C1BC; background:#0D0F0E; border:1px solid #2A3A36; padding:3px 6px; margin-top:5px; }
.csgo-pass-rail.premium { color:#a78bfa; border-color:#7c5cff; }
.csgo-pass-rail.free { color:#2be7e7; border-color:#2be7e7; }
.csgo-pass-cell { border:1px solid #2A3A36; background:#161B1A; padding:4px 3px; text-align:center; white-space:nowrap; }
.csgo-pass-cell .bp-star { font-size:18px; line-height:20px; }
.bp-star.gold { color:#FFD700; }
.bp-star.white { color:#EDF1EF; }
.csgo-pass-cell .nm { color:#ffffff; font-size:10px; font-weight:bold; }
.csgo-pass-cell .rw { color:#B7C1BC; font-size:9px; }
.csgo-pass-cell .stg { font-size:11px; font-weight:bold; padding-top:2px; }
.csgo-pass-cell.locked .nm { color:#71827A; }
.csgo-pass-cell.locked .bp-star { color:#4a5651; }
.st-ok { color:#3dff9e; }
.st-now { color:#e8c547; }
.st-no { color:#71827A; }
/* RGBA reward icons ship a transparent 8px outer margin; the global img
   background would paint a dark square behind those corners on top of the
   rarity field. Scoped reset only -- other panels keep the dark tile. */
.csgo-pass-cell img, .tier-badge img, .op-art img { background:transparent; }
.csgo-pass-cell.bp-rarity-normal { background:#3A4240; }
.csgo-pass-cell.bp-rarity-rare { background:#1F6B3A; box-shadow:inset 0 0 0 1px #4CFFA8; }
.csgo-pass-cell.bp-rarity-super_rare { background:#1A3A6B; box-shadow:inset 0 0 0 1px #5CA9FF; }
.csgo-pass-cell.bp-rarity-mythic { background:#6B1A24; box-shadow:inset 0 0 0 1px #FF5C6E; }
.csgo-pass-cell.bp-rarity-legendary { background:#8A6A12; box-shadow:inset 0 0 0 1px #FFD24A; }
.csgo-pass-cell.bp-rarity-COMMON { background:#3A4240; }
.csgo-pass-cell.bp-rarity-UNCOMMON { background:#1F6B3A; box-shadow:inset 0 0 0 1px #4CFFA8; }
.csgo-pass-cell.bp-rarity-RARE { background:#1A3A6B; box-shadow:inset 0 0 0 1px #5CA9FF; }
.csgo-pass-cell.bp-rarity-EPIC { background:#6B1A24; box-shadow:inset 0 0 0 1px #FF5C6E; }
.csgo-pass-cell.bp-rarity-LEGENDARY { background:#8A6A12; box-shadow:inset 0 0 0 1px #FFD24A; }
.csgo-pass-cell.bp-rarity-TRANSCENDENT { background:#3B2A6B; box-shadow:inset 0 0 0 1px #A98BFF; }
.csgo-pass-cell.current { border-color:#e8c547; border-width:2px; }
.csgo-pass-cell.claimed { border-color:#3dff9e; }
.csgo-pass-cell.premium { border-color:#7c5cff; }
.csgo-pass-cell.premium.claimed { border-color:#a78bfa; }
.csgo-pass-cell.premium.locked .nm { color:#6b63a0; }
.csgo-pass-cell.milestone { border-color:#ffd700; border-width:2px; }
.csgo-pass-grid td { padding:2px; vertical-align:top; }
.bp-cols { table-layout:fixed; width:100%; }
.csgo-pass-grid .bp-node { background:#161B1A; border:1px solid #2A3A36; color:#71827A; font-size:11px; font-weight:bold; text-align:center; padding:0; }
.csgo-pass-grid .bp-node.done { background:#0b2b20; border-color:#3dff9e; color:#3dff9e; }
.csgo-pass-grid .bp-node.now { background:#e8c547; border-color:#ffd700; color:#141208; }
.bp-spacer { background:#0D0F0E; }
/* Rewrite track markup (div hero + div rows/cells, op-art header). Same
   GoldSrc contract as the block above: solid hex only, no custom-property
   calls, no flex/grid display, no child-index selectors, no viewport
   units -- degrades to plain blocks. */
.csgo-pass-layout { width:100%; }
.csgo-pass-left { width:100%; background:#0D0F0E; border:1px solid #2A3A36; padding:8px; margin-bottom:6px; }
.op-art { text-align:center; margin-bottom:6px; }
.op-art img { width:72px; height:72px; border:1px solid #2A3A36; }
.op-kicker { color:#e8c547; font-size:10px; letter-spacing:2px; text-transform:uppercase; }
.op-title { color:#ffffff; font-size:18px; font-weight:bold; text-transform:uppercase; }
.op-meta { color:#B7C1BC; font-size:11px; margin-bottom:6px; }
.csgo-pass-xp { background:#0D0F0E; border:1px solid #2A3A36; padding:6px; margin-top:6px; }
.csgo-pass-xp .lvl { background:#e8c547; color:#141208; font-size:24px; font-weight:bold; text-align:center; border:2px solid #ffd700; width:56px; padding:4px 0; margin-bottom:4px; }
.csgo-pass-track-wrap { width:100%; overflow-x:scroll; overflow-y:hidden; }
.csgo-pass-track { width:100%; }
.csgo-pass-row { white-space:nowrap; margin-bottom:0; }
.csgo-pass-track { border:1px solid #2A3A36; border-radius:8px; padding:6px; background:#0D0F0E; }
.csgo-pass-cell.locked img { opacity:.45; filter:alpha(opacity=45); }
.csgo-pass-cell.locked svg { opacity:.8; }
.csgo-pass-cell.current { background:#2a230f; border-color:#e8c547; }
.pgbtn { display:inline-block; border:1px solid #2A3A36; border-radius:6px; padding:3px 10px; color:#4a5651; font-weight:bold; }
a.pgbtn { color:#e8c547; border-color:#e8c547; }
.csgo-pass-row .csgo-pass-cell { display:inline-block; width:11%; margin:0 1px 1px 0; vertical-align:top; }
.csgo-medal-slot { display:inline-block; width:74px; height:74px; text-align:center; vertical-align:top; }
.csgo-medal-slot.empty { border:1px dashed #2A3A36; }
`

// Compact MOTD micro-stylesheet. The in-game MOTD window is an old IE control,
// so compact pages inline only the MOTD_CSS rules their own rendered markup can
// actually match (plus class-less base rules: html/body/a/img/code). The sheet
// is derived FROM MOTD_CSS itself, so compact output is always an exact subset
// of the browser sheet — the browser (non-compact) path keeps MOTD_CSS
// byte-for-byte and never loses styling.
function cssRulesOf(css) {
  const src = String(css).replace(/\/\*[\s\S]*?\*\//g, "")
  const out = []
  let i = 0
  for (;;) {
    const open = src.indexOf("{", i)
    if (open < 0) break
    const close = src.indexOf("}", open)
    if (close < 0) break
    out.push({
      sel: src.slice(i, open).trim().replace(/\s+/g, " "),
      decl: src.slice(open + 1, close).trim().replace(/\s+/g, " ")
    })
    i = close + 1
  }
  return out
}

function compactCssFor(markup) {
  const used = new Set()
  for (const m of String(markup).matchAll(/class\s*=\s*(?:"([^"]*)"|'([^']*)')/g))
    for (const tok of (m[1] || m[2] || "").split(/\s+/)) if (tok) used.add(tok)
  const kept = []
  for (const r of cssRulesOf(MOTD_CSS)) {
    const classes = [...r.sel.matchAll(/\.([A-Za-z][\w-]*)/g)].map(x => x[1])
    if (!classes.length || classes.some(c => used.has(c))) kept.push(`${r.sel} { ${r.decl} }`)
  }
  return kept.join("\n")
}

function html(title, body, opts) {
  opts = opts || {}
  // Compact MOTD: text title only. /logo.png is a second GET; GoldSrc hangs if
  // the MOTD host is loopback. Browser preview (non-compact) keeps the logo.
  const compactMode = !!(opts.compact || isMotdCompact())

  // Per-product chrome: accent colour, header background, kicker label.
  // Falls back to default teal theme when no product slug is supplied.
  const theme = PRODUCT_THEME[opts.product] || { accent: "#36DEAB", headBg: "#070B0C", kicker: "" }
  const ac = theme.accent
  const hbg = theme.headBg
  const kicker = theme.kicker

  // Tiny inline <style> that overrides the shared accent selectors for this
  // product. No CSS variables — GoldSrc IE ignores them. The block is small
  // (< 300 chars) so it does not meaningfully duplicate MOTD_CSS.
  const accentOverride = ac === "#36DEAB" ? "" : `<style>
a{color:${ac}}
.h2{color:${ac}}
.t th{color:${ac}}
.bar div{background:${ac}}
.msn-rew{color:${ac}}
code{color:${ac}}
.nav-td .nav-a{background:${ac}}
b[style*="color:#36DEAB"]{color:${ac}!important}
</style>`

  const kick = kicker ? `FREENOVA | ${kicker}` : "FREENOVA"
  const head = compactMode
    ? `<table class='motd-head' width='100%' cellspacing='0' cellpadding='0' border='0' bgcolor='${hbg}'>
  <tr>
    <td valign='middle'><span class='hero-kick'>${esc(kick)}</span><br><span class='hero-title' style='color:${ac};'>${esc(title)}</span></td>
  </tr>
</table>`
    : `<table class='motd-head' width='100%' cellspacing='0' cellpadding='0' border='0' bgcolor='${hbg}'>
  <tr>
    <td width='56' valign='middle'><img src='/logo.png' width='44' height='44' alt='FREENOVA' border='0'></td>
    <td valign='middle'><span class='hero-kick'>${esc(kick)}</span><br><span class='hero-title' style='color:${ac};'>${esc(title)}</span></td>
  </tr>
</table>`
  // Compact MOTD: inline only the stylesheet subset this page's markup uses.
  // Browser (non-compact) keeps MOTD_CSS byte-for-byte.
  // MOTD width fix (compact only): IE7-era MSHTML ignores max-width, so the
  // .wrap{width:780px} rule pinned every compact page 160px past the ~620px
  // GoldSrc MOTD window. The inline width wins over the stylesheet in old IE
  // exactly like in modern engines; the browser path below is untouched.
  const wrapOpen = compactMode ? "<div class='wrap' style='width:100%;'>" : "<div class='wrap'>"
  const css = compactMode ? compactCssFor(`<div class='wrap'>${head}${body}`) : MOTD_CSS
  return new Response(`<!DOCTYPE html>
<html><head><meta charset='utf-8'><title>FreeNova | ${esc(title)}</title>${compactMode ? "" : `<link rel='icon' href='/i/logo_mark.png'>`}
<style>${css}</style>${accentOverride}</head>
<body bgcolor='${hbg}' text='#EDF1EF'>${wrapOpen}
${head}
${body}
</div></body></html>`,
    { headers: { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" } })
}

// ---------- shared state helpers ----------

function page404() {
  // Unknown routes answer HTTP 404 with the same body (gone() in index.js
  // already wrapped this body with 404 by design — both paths agree now).
  const res = html("NOT FOUND", `<div class='card'><div class='h2'>404</div>
  <p>Unknown panel. Open the matching in-game command.</p></div>`)
  return new Response(res.body, { status: 404, headers: res.headers })
}

// Home hub at "/". The bare panel URL used to dead-end at 404 ("Unknown
// panel"), so anyone typing the address by hand hit a wall. This directory
// lists every product; browser mode links the canonical slug exactly
// (href='/profile', href='/top15', ...), compact MOTD visits get short
// /m/<code>/<sid>.htm paths. Isolation still holds: this is not a product
// page, and product pages never link here (foreignHits treats "" as retired).
function pageHub(url) {
  const steamid = (url && url.searchParams && url.searchParams.get("steamid")) || ""
  const short = steamid ? motdSidShort(steamid) : ""
  const rows = [
    ["p", "Profile", "profile", "Rank, XP, K/D and career stats", "#7dd3fc"],
    ["t", "Top 15", "top15", "Server leaderboard", "#fbbf24"],
    ["b", "Battle Pass", "battlepass", "Season track - free and premium lanes", "#e8c547"],
    ["i", "Missions", "missions", "Daily and weekly contracts", "#36DEAB"],
    ["a", "Achievements", "achievements", "Medals, records and hall of fame", "#c084fc"],
    ["r", "Competitive", "tournament", "Season standings and points", "#f07178"],
    ["v", "VIP", "vip", "Membership tiers and perks", "#e8c547"],
    ["e", "Events", "events", "Live server events", "#2EBF92"]
  ]
  const cells = rows.map(([code, name, slug, desc, ac]) => {
    const href = isMotdCompact() && short ? `/m/${code}/${short}.htm` : `/${slug}`
    return `<tr>
  <td width='28' align='center'><b style='color:${ac};font-size:14px;'>${code}</b></td>
  <td><a href='${href}' style='color:${ac}'><b>${esc(name)}</b></a><br><span class='muted'>/${slug}</span></td>
  <td class='muted'>${esc(desc)}</td>
</tr>`
  }).join("\n")
  return html("PANELS", `
<div class='card'>
  <div class='h2'>PANEL DIRECTORY</div>
  <p class='muted'>FreeNova panels - open the one you need. In game, every panel also opens from its command or the N menu.</p>
</div>
<table class='t' width='100%' cellspacing='0' cellpadding='0' border='0'>
<tr><th width='28'>#</th><th>PANEL</th><th>WHAT IT SHOWS</th></tr>
${cells}
</table>
<div class='card'>
  <span class='muted'>Tools:</span> <a href='/statsviewer'>Stats viewer</a>
  <span class='muted'> - sort every player by any stat.</span>
</div>`)
}

function needSteamid(title, navKey, what) {
  const cmd = String(title || "this panel").toUpperCase() === "VIP" ? "/vip"
    : String(title || "").toUpperCase() === "PROFILE" ? "/profile"
    : String(title || "").toUpperCase() === "BATTLE PASS" ? "/battlepass"
    : String(title || "").toUpperCase() === "ACHIEVEMENTS" ? "/achievements"
    : String(title || "").toUpperCase() === "COMPETITIVE" ? "/pts"
    : String(title || "").toUpperCase() === "EVENTS" ? "/events"
    : String(title || "").toUpperCase() === "TOP 15" ? "/top"
    : "/menu"
  return html(title, `<div class='card'><div class='h2'>OPEN FROM THE GAME</div>
  <p>Run <code>${cmd}</code> in chat.</p></div>`, { nav: navKey })
}

function notFound(title, navKey, why) {
  // esc() even though every caller passes a literal: this is a rendered sink and
  // the first caller that passes a SteamID would otherwise inject markup.
  return html(title, `<div class='card'><div class='h2'>NO DATA YET</div><p>${esc(why)}</p></div>`, { nav: navKey })
}

function errorState(title, navKey, what) {
  return html(title, `<div class='err'><b>Unable to load ${esc(what)}</b><br>
  <span class='small'>The panel could not read authoritative server data. Values are never guessed,
  so nothing is shown rather than something wrong. Try again shortly.</span></div>`, { nav: navKey })
}

// ---------- small helpers ----------

function esc(s) {
  return String(s == null ? "" : s)
    .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;").replace(/'/g, "&#39;")
}

function fmt(n) { return String(n == null ? 0 : n).replace(/\B(?=(\d{3})+(?!\d))/g, ",") }
function num(v) { const n = parseInt(v, 10); return Number.isFinite(n) ? n : 0 }
function clamp(v, lo, hi) { return Math.min(Math.max(v, lo), hi) }
function ratingStr(x100) { return (num(x100) / 100).toFixed(2) }
function kdStr(k, d) { return num(d) ? (num(k) / num(d)).toFixed(2) : fmt(k) }
function pct(part, whole) { return num(whole) ? clamp(Math.floor((num(part) * 100) / num(whole)), 0, 100) : 0 }
function isOnline(lastSeen, now) { return now - (lastSeen || 0) < 900 }

function ago(sec) {
  if (sec < 90) return "just now"
  if (sec < 3600) return Math.max(1, Math.floor(sec / 60)) + " min ago"
  if (sec < 86400) return Math.floor(sec / 3600) + " h ago"
  return Math.floor(sec / 86400) + " d ago"
}

function progressBar(p) {
  return `<div class='bar'><div style='width:${clamp(p, 0, 100)}%'></div></div>`
}

function emptyState(msg) { return `<div class='empty'>${esc(msg)}</div>` }

// Builds a sortable column header link. sortKeys: the active query state.
function sortHeader(label, field, q, extraParams) {
  const active = q.sort === field
  // Was `active && q.order === "asc" ? "desc" : "desc"`, so the second click on a
  // column never reversed the order: the "↑" arrow was unreachable.
  const nextOrder = active ? (q.order === "asc" ? "desc" : "asc") : "desc"
  const arrow = active ? (q.order === "asc" ? " ↑" : " ↓") : ""
  const params = new URLSearchParams(extraParams || {})
  params.set("sort", field)
  params.set("order", nextOrder)
  const base = params.toString()
  return `<a href='${q.path}?${esc(base)}' class='${active ? "sort" : ""}'>${esc(label)}${arrow}</a>`
}

// ---- events display helpers (owner: ui.js) --------------------------------
// eventKind: kind slug for the evt-kind-* CSS family ("community_goal"->"community")
export function eventKind(e) {
  return String((e && e.type) || "event").split("_")[0].toLowerCase() || "event"
}
// eventIcon: inline emblem. GoldSrc MOTD (MSIE) cannot render inline SVG; the
// compact path keeps a text glyph, same posture as cs2Medal/medalGlyph.
export function eventIcon(e, size) {
  const px = Math.max(16, Math.min(96, num(size) || 40))
  if (isMotdCompact()) {
    return `<font color='#e8c547' size='+3'><b>${esc(eventKind(e).slice(0, 1).toUpperCase())}</b></font>`
  }
  return `<svg width='${px}' height='${px}' viewBox='0 0 16 16' xmlns='http://www.w3.org/2000/svg'>`
    + `<polygon points='8,1 10,6 15,6 11,9 12.5,14 8,11 3.5,14 5,9 1,6 6,6' fill='#e8c547'/></svg>`
}

export {
  ACCENT, PRODUCT_THEME, MOTD_CSS, WEAPONS, SKILL_TIERS, COSMETICS,
  skillName, vipName, icon, flagImg, html, nav, navHref, panelHref, tabBar, medalTable,
  page404, pageHub, needSteamid, notFound, errorState,
  esc, fmt, num, clamp, ratingStr, kdStr, pct, isOnline, ago,
  progressBar, emptyState, sortHeader
}

export default {
  ACCENT, PRODUCT_THEME, MOTD_CSS, WEAPONS, SKILL_TIERS, COSMETICS,
  skillName, vipName, icon, flagImg, html, nav, navHref, panelHref, tabBar, medalTable,
  page404, pageHub, needSteamid, notFound, errorState,
  esc, fmt, num, clamp, ratingStr, kdStr, pct, isOnline, ago,
  progressBar, emptyState, sortHeader
}
