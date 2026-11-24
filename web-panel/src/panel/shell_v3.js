// FreeNova panel — the shared v3 Winterfest shell: the linear resources bar, the
// sidebar of sections, and the icon plates they are painted from.
//
// THE RULE (docs/design/PAGE-KIT.md, and the dashboard's own header)
//   A page paints ONE plate whole at the plate's own size. Everything the page
//   then shows is either a FIELD (a text box on a strip cut from that same
//   plate, so the plate's chrome - borders, glows, snow, gradients - stays
//   whole) or a SPRITE (an icon or picture cut out of the same plate).
//
// WHY THE SHELL IS PAINTED, NOT DRAWN
//   The bartender and the sidebar in the owner's plates are full of illustrated
//   chrome: a snow cap running down the bar, twinkling snowflakes, a bell, an
//   envelope, a gift at the foot of the nav. Hand-drawn CSS never survives that
//   comparison (the live dashboard's covers did not: their scaling moved every
//   sample value to the wrong place). So the shell is CUT from the page's own
//   plate, one row at a time, and the page's words are what is laid on top:
//     BAR_ROW   - the whole top bar, sliced vertically into one element per icon
//                 run (the four chips, the bell/envelope, the profile block). A
//                 bar row REPLACES the plate's own bar: the plate is painted from
//                 y = 90 down, so nothing of the bar that is not one of our cut
//                 rows can show through.
//     NAV_ROW   - the sidebar, cut as one row per nav entry (icon + title +
//                 subtitle, 42px tall, the entry's own plate background).
//
// This module owns only those tables and the CSS/HTML that draws them. It is
// not page data: it never prints a number that came from the database.
import { stripCss } from "./plates.js"

// The bar is 90px tall on every plate (1622/1624 wide plates, 969 tall).
export const BAR_H = 90
export const NAV_W = 296

// One-party resources: every player-facing page shows the same four counters and
// the same two icons. Texts are drawn by the page; this table says where the
// plate's own value/glyph sits, so the page can cover exactly it.
//   [name, plate x, y, w, h, text x, y, w, h, font px, weight]
export const BAR_FIELDS = [
  ["b_coins", 484, 16, 84, 22, 484, 16, 84, 22, 17, 800],
  ["b_coins_l", 484, 42, 100, 18, 484, 40, 100, 20, 13, 600],
  ["b_gb", 713, 16, 84, 22, 713, 16, 84, 22, 17, 800],
  ["b_gb_l", 713, 42, 120, 18, 713, 40, 120, 20, 13, 600],
  ["b_spins", 1081, 16, 50, 22, 1081, 16, 50, 22, 17, 800],
  ["b_spins_l", 1081, 42, 60, 18, 1081, 40, 60, 20, 13, 600],
  ["b_miss", 1173, 16, 46, 22, 1173, 16, 46, 22, 17, 800],
  ["b_miss_l", 1173, 42, 60, 18, 1173, 40, 60, 20, 13, 600],
  ["b_badge", 1298, 12, 18, 18, 1298, 12, 18, 18, 11, 800],
  ["b_who", 1436, 14, 130, 24, 1436, 14, 130, 24, 14, 700],
  ["b_lvl", 1436, 42, 100, 20, 1436, 42, 100, 20, 12, 600]
]

// The bar rows, in paint order. Each is a cut of the plate's bar.
//   [name, plateX, y, w, h, outX, w]
// `outH` defaults to h. The tiny -8 offsets make neighbouring rows overlap by a
// pixel so no hairline of the plate's own value can show between them.
// Every row is painted at the same place it was cut from, so no slice is ever
// stretched; together they cover the whole bar, 0..1622.
export const BAR_ROWS = [
  // x starts at 6: the sidebar's plate edge and the bar's left cap are one piece
  ["bar_left", 6, 0, 290, BAR_H, 6, 290],
  ["bar_coins", 296, 0, 188, BAR_H, 296, 188],
  ["bar_gap", 484, 0, 222, BAR_H, 484, 222],
  ["bar_gb", 706, 0, 266, BAR_H, 706, 266],
  ["bar_spins", 972, 0, 146, BAR_H, 972, 146],
  ["bar_gap2", 1118, 0, 52, BAR_H, 1118, 52],
  ["bar_bell", 1170, 0, 109, BAR_H, 1170, 109],
  ["bar_bell2", 1279, 0, 110, BAR_H, 1279, 110],
  ["bar_mail", 1389, 0, 118, BAR_H, 1389, 118],
  ["bar_who", 1507, 0, 115, BAR_H, 1507, 115]
]

// The sidebar entries, one row each: [key, title, subtitle, bandY, h]
// bandY is the row's band on the plate PAINTED WITH THE COLUMN STRIP (an empty
// stretch of the sidebar where the item sits in the design); the entry's own
// plate band - its icon - is NAV_SRC_Y below. The four section headings are not
// entries: the plate's own words and glyphs stay, only its caption is faded.
export const NAV_ROWS = [
  ["dashboard", "Dashboard", "Winterfest overview & countdown", 94, 36],
  ["profile", "Profile", "Christmas frames, badges & tree", 170, 36],
  ["rankstats", "Rankstats", "Festive statistics", 222, 36],
  ["top", "Top 15", "Christmas leaderboard", 270, 36],
  ["battlepass", "Battle Pass", "Christmas reward tracks", 319, 36],
  ["missions", "Missions", "Christmas quests", 369, 36],
  ["achievements", "Achievements", "Seasonal medals", 419, 36],
  ["levels", "Levels", "Progress & rewards", 464, 36],
  ["events", "Events", "Christmas event calendar", 565, 36],
  ["advent", "Calendar Advent", "Advent calendar (24 days)", 611, 36],
  ["spin", "Spin Wheel", "Win coins, gingerbread & rewards", 657, 36],
  ["vip", "VIP", "Christmas VIP cosmetics", 735, 36],
  ["shop", "Shop", "Christmas-themed shop", 782, 36],
  ["admin", "Admin Panel", "Event management & settings", 829, 36]
]

// Where each entry's own icon sits on the plate (the row the plate painted it
// in). The strip above covers the column, then this band is painted back on top,
// so the icon comes back and the plate's words stay hidden.
export const NAV_SRC_Y = {
  dashboard: 94, profile: 176, rankstats: 223, top: 270,
  battlepass: 344, missions: 392, achievements: 439, levels: 486,
  events: 559, advent: 607, spin: 654, vip: 735, shop: 782, admin: 829
}

// The route each nav entry opens. A key that is not on this map is drawn but
// not linked (a page this build does not have yet) - never a 404 link.
export const NAV_HREF = {
  dashboard: "/panel/dashboard",
  profile: "/profile",
  rankstats: "/profile",
  top: "/top",
  battlepass: "/battlepass",
  missions: "/missions",
  achievements: "/achievements",
  levels: "/panel/levels",
  events: "/events",
  advent: "/panel/advent",
  spin: "/shop",
  vip: "/vip",
  shop: "/shop",
  admin: "/panel/admin"
}

// The strap rows of the sidebar. [name, y, h, href] - a row with an href is the
// one entry that also links to the plate's own brand area.
export const NAV_BRANDS = []
export const NAV_HEADERS = [
  ["PLAYER", 150, 22],
  ["PROGRESSION", 320, 22],
  ["EVENTS & ACTIVITIES", 536, 22],
  ["REWARDS & MANAGEMENT", 714, 22]
]

const esc = s => String(s == null ? "" : s).replace(/[&<>"']/g, c => (
  { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]))

// One strip repaints the whole sidebar column for a row the page has moved: the
// top of the sidebar itself, cut between two entries, so it carries the plate's
// own colour, gradient and the snow that runs down the column - and nothing else.
// A row keeps the plate's icon by painting the plate's band (NAV_ROW_SRC) first.
export const NAV_STRIPS = {
  snavcol: { sx: 6, sy: 158, sw: NAV_W - 12, sh: 80, x: 0, y: -2, w: NAV_W, h: 40 },
  snavhd: { sx: 6, sy: 158, sw: NAV_W - 12, sh: 80, x: 0, y: 0, w: NAV_W, h: 22 }
}

/**
 * The shell's CSS for one plate. `plate` is the url the plate is served from;
 * `plateH` is the height the plate is painted at (its own), and `bodyTop` is
 * where the plate's own bar would start - the bar rows are painted instead.
 */
export function shellCss(plate, plateW, plateH) {
  // A bar row paints the WHOLE bar band from its own cut, so the plate's own
  // values in that band are never left visible beside the page's.
  const rows = BAR_ROWS.map(([n, sx, y, w, h, x, ow]) =>
    stripCss(n, plate, sx, y, w, h, x, 0, ow, h)).join("\n")
  // A nav row keeps the plate's own row (icon included) and paints the page's
  // title/subtitle on clean strips cut from the sidebar's own empty column.
  const navs = NAV_ROWS.map(([k, , , y, h, ay], i) =>
    `.nav-row.nav-${i}{top:${y}px;height:${h}px}`).join("\n")
  const navBg = NAV_ROWS.map(([k, , , y, h], i) =>
    `.nav-bg.nav-${i}{top:${y - 2}px}`).join("\n")
  // The plate's own band for each entry, so the row keeps the plate's icon.
  const navSrc = NAV_ROWS.map(([k, , , y, h], i) => {
    const sy = NAV_SRC_Y[k]
    return `.nav-src.nav-${i}{top:${sy}px;width:${NAV_W}px;height:${h}px;` +
      `background-position:0 -${sy}px;background-size:${plateW}px ${plateH}px}`
  }).join("\n")
  const navHd = NAV_HEADERS.map(([t, y, h], i) =>
    `.nav-hdc.nav-${i}{top:${y - 3}px}`).join("\n")
  const navT = NAV_ROWS.map(([k, , , y, h], i) => {
    const row = NAV_ROWS[i]
    return `.nav-cover.nav-${i}{top:${y}px}`
  }).join("\n")
  const navStrips = Object.entries(NAV_STRIPS).map(([n, s]) =>
    stripCss(n, plate, s.sx, s.sy, s.sw, s.sh, s.x, s.y || 0, s.w, s.h)).join("\n")
  return `
/* the shell is cut from the plate, never drawn */
${rows}
${navStrips}
.nav-row{position:absolute;left:0;width:${NAV_W}px;height:36px}
.nav-bg{position:absolute;left:0;width:${NAV_W}px;height:40px}
${navBg}
${navs}
${navT}
${navHd}
.nav-src{position:absolute;left:0;background-image:url(${plate});background-repeat:no-repeat}
${navSrc}
.nav-cover{position:absolute;left:88px;width:${NAV_W - 90}px;height:36px}
.nav-t2{position:absolute;left:91px;height:18px;color:#fff;font-size:15px;line-height:18px;
  font-weight:700;white-space:nowrap;text-shadow:0 1px 2px rgba(0,0,0,.75)}
.nav-s2{position:absolute;left:91px;height:14px;color:#cfd6ea;font-size:10.5px;line-height:14px;
  font-weight:600;white-space:nowrap;text-shadow:0 1px 2px rgba(0,0,0,.75)}
/* the row the plate highlights is the plate's own; ours gets the same shape */
.nav-row.on{box-shadow:inset 0 0 0 2px rgba(190,120,255,.95),0 0 14px rgba(150,80,255,.55);
  border-radius:9px}
.nav-row.on .nav-t2{color:#fff;text-shadow:0 0 10px rgba(210,150,255,.9)}
.nav-row a{position:absolute;inset:0;display:block}
/* the section headings keep the PLATE's own words and glyphs; only the caption
   under them (the previous item's subtitle, on the plate) is covered */
.nav-hdc{position:absolute;left:0;width:${NAV_W}px;height:22px}
/* the bar: cut rows, then the page's own words on them */
.bar{position:absolute;left:0;top:0;width:100%;height:${BAR_H}px}
.bf{position:absolute;margin:0;padding:0;color:#fff;font-variant-numeric:tabular-nums;
  text-shadow:0 1px 2px rgba(0,0,0,.75);white-space:nowrap}
.bf span{display:block;width:100%;height:100%}`
}

/**
 * The shell's markup: every bar row, then every bar field (filled from
 * `values`), then the sidebar rows. `active` is the nav key of the current page.
 * A field with no value prints an em dash - never a zero pretending to be data.
 */
export function shellHtml(opts) {
  const o = opts || {}
  const values = o.values || {}
  const rows = BAR_ROWS.map(([n]) => `<div class="strip strip-${n} bar"></div>`).join("")
  const fields = BAR_FIELDS.map(([id, , , , , x, y, w, h, fs, wt]) => {
    const v = values[id] == null ? "—" : values[id]
    return `<div class="bf" id="${id}" style="left:${x}px;top:${y}px;width:${w}px;height:${h}px;` +
      `font-size:${fs}px;line-height:${h}px;font-weight:${wt}">${`<span>${v}</span>`}</div>`
  }).join("")
  const nav = NAV_ROWS.map(([key, title, sub, y, h, ay], i) => {
    const href = NAV_HREF[key]
    const on = key === o.active ? " on" : ""
    return `<div class="nav-src nav-${i}"></div>` +
      `<div class="nav-bg strip strip-snavcol nav-${i}"></div>` +
      `<div class="nav-row nav-${i}${on}">` +
      `<div class="nav-t2" style="top:${y + 1}px">${esc(title)}</div>` +
      `<div class="nav-s2" style="top:${y + 18}px">${esc(sub)}</div>` +
      (href ? `<a href="${href}" aria-label="${esc(title)}"></a>` : "") + `</div>`
  }).join("")
  const heads = NAV_HEADERS.map(([t, y, h], i) =>
    `<div class="nav-hdc nav-${i} strip strip-snavhd" title="${esc(t)}"></div>`).join("")
  return `<div id="bar">${rows}${fields}</div>\n<div id="nav">${nav}${heads}</div>`
}
