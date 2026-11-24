// FreeNova panel — the one file every Winterfest page shares
// (docs/panel/00-CONTRACT.md §1: pages share DATA ACCESS, FORMATTING and the
// ACTION PROTOCOL, never layout).
//
// Three things live here, and nothing else:
//
//   plate()   the sprites CUT FROM THE PLATE (web-panel/assets/dashboard.png).
//             A page never draws chrome of its own: an icon, a chip, a capsule,
//             a strip of panel or snow is a crop of the owner's own artwork at
//             its own pixels, painted as a CSS background. "Pictures are CSS
//             sprites of the plate; nothing is generated" (SPEC-14.md). A sheet
//             region must sit on TEXT-FREE plate pixels - the census in
//             test_plate_census.mjs is what proves it - so a sprite can never
//             carry a sample word into the page.
//
//   frag()    the type and measurement rules: escaping, thousands, a number or
//             an honest em dash, a percentage, a duration, "2 h ago". A null is
//             ALWAYS printed as a dash (or by the caller as "not collected"), so
//             a zero that means "unknown" cannot reach a page.
//
//   scaleCss()/fitScript()  ONE SCREEN. The stage is a fixed size at the plate's
//             own pixel grid, scaled as a whole by min(vw/W, vh/H) and
//             letterboxed. Never a reflow, never a scrollbar: a player must not
//             scroll a panel.
//
// A page that wants a new picture adds it to SHEET here, next to the strip it
// was cut from, and runs `node test_plate_census.mjs --check` before shipping.
import { createHash } from "node:crypto"
import { readFileSync } from "node:fs"
import { fileURLToPath } from "node:url"

export const PLATE_URL = "/dashboard.png"
export const PLATE_CSS_W = 1672, PLATE_CSS_H = 941

// The plate's own digest. A page bakes it into its background URL, so a browser
// holding yesterday's chrome cannot mix it with today's layout.
export function plateDigest() {
  try {
    return createHash("sha256")
      .update(readFileSync(fileURLToPath(new URL("../../assets/dashboard.png", import.meta.url))))
      .digest("hex").slice(0, 12)
  } catch { return "0" }
}

// ---------------------------------------------------------------------------
// THE SHEET. [name, srcX, srcY, srcW, srcH] — a rectangle of the plate, in plate
// pixels. Every entry is a crop of TEXT-FREE artwork:
//
//   avatar      the left of the hero band: the decorated pine, the star, the
//               snowy hill. The page paints its own disc over the star and keeps
//               the tree around it.
//   sky         the hero's night sky: snowflakes, the aurora, the mountain
//   cabin       the cabin and the pines under the aurora (right-hand artwork)
//   snow_lip    the snow lip that runs along the top edge of every card
//   cold        a slice of cold purple panel, for a strip with no text on it
//   hero_sky    a clean square of the hero's snowy night sky - the ONLY text-free
//               sky on the plate. A page that needs a banner paints this tile at
//               the plate's own scale (background-size:AUTO, repeat) rather than
//               stretching it: a panorama would stretch one snowflake into a smear.
//   podium_sky  the same tile, used as the backdrop of a podium band
//   pill_green  the capsule row's green pill body (the tree's plane)
//   pill_violet the capsule row's violet pill body (the battle pass's plane)
//   pill_gold   the same pill in the gold plane (advent / missions)
//   hero_tab    the hero tab row's blue plane
//   tile        a reward tile's dark inner pane, its glowing edge kept
//   btn_green   the tree card's "Decorate Tree" button
//   rail        text-free night sky and snow that sits UNDER a page's fields
// ---------------------------------------------------------------------------
export const SHEET = Object.freeze({
  avatar:      [372, 92, 170, 190],
  sky:         [1090, 120, 160, 140],
  cabin:       [1084, 140, 150, 140],
  snow_lip:    [600, 464, 60, 16],
  cold:        [318, 404, 40, 30],
  hero_sky:    [1300, 150, 40, 40],
  podium_sky:  [1310, 120, 40, 40],
  pill_green:  [432, 394, 96, 40],
  pill_violet: [576, 394, 96, 40],
  pill_gold:   [1006, 394, 96, 40],
  hero_tab:    [876, 90, 100, 42],
  tile:        [1186, 440, 100, 66],
  btn_green:   [372, 664, 240, 30],
  rail:        [420, 100, 140, 80]
})


/** One CSS rule painting `sel` with a sheet region, stretched to w×h. */
export function sprite(sel, name, w, h, opts) {
  const r = SHEET[name]
  if (!r) return ""
  const [sx, sy, sw, sh] = r
  const pos = opts && opts.bottom
    ? `${-sx}px ${-(sy + sh - (opts.h || h))}px`   // keep the BOTTOM edge (skies, drifts)
    : `${-sx}px ${-sy}px`
  const size = opts && opts.natural ? "auto" : `${w}px ${h}px`
  return `${sel}{background-image:url(${PLATE_URL});background-repeat:no-repeat;` +
    `background-position:${pos};background-size:${size}}`
}

/**
 * A tileable backdrop from the plate, at the plate's OWN scale.
 * `sel` gets the text-free snowy-night square (SHEET.hero_sky) repeated, never
 * stretched: a page that wants a banner behind its text uses this rather than a
 * background-size:100% (which turns one snowflake into a smear). `mask` is a CSS
 * mask-image so the tile can fade out towards the side the text sits on.
 */
export function backdrop(sel, mask, opacity) {
  const r = SHEET.hero_sky
  const m = mask || "linear-gradient(90deg,transparent 0,rgba(0,0,0,.85) 40%,rgba(0,0,0,.85) 100%)"
  return `${sel}{background-image:url(${PLATE_URL});background-size:auto;background-repeat:repeat;` +
    `background-position:${-r[0]}px ${-r[1]}px;opacity:${opacity == null ? 0.5 : opacity};` +
    `-webkit-mask-image:${m};mask-image:${m}}`
}

/** A region of the sheet as an <img>, for a place that wants a real element. */
export function spriteImg(name, x, y, w, h, alt) {
  const r = SHEET[name]
  if (!r) return ""
  return `<img class="spr" src="${PLATE_URL}" alt="${fragEsc(alt)}" style="` +
    `width:${w}px;height:${h}px;object-fit:none;object-position:${-r[0]}px ${-r[1]}px">`
}

// ---------------------------------------------------------------------------
// ONE SCREEN. The same arithmetic the dashboard page uses (src/panel/dashboard.js):
//   s = min(vw/W, vh/H, 1)     a whole-pixel stage, scaled, letterboxed.
// `scaleCss` is the no-script fallback (a CSS `scale:` with the same formula);
// `fitScript` is the exact one, and it also publishes data-scale / data-noscroll
// so the harness can assert that nothing scrolls at any viewport it is told to
// try. Both are additive: the server has already printed every value.
export function scaleCss(W, H, id) {
  const sel = id || "stage"
  return `#${sel}{position:absolute;left:0;top:0;width:${W}px;height:${H}px;transform-origin:0 0;` +
    `scale:min(calc(100vw / ${W}), calc(100vh / ${H}), 1)}`
}

export function fitScript(W, H, id) {
  const sel = id || "stage"
  return `(function(){
  var st=document.getElementById('${sel}');if(!st)return;
  var W=${W},H=${H};
  var fit=function(){
    var vw=window.innerWidth,vh=window.innerHeight;
    var s=Math.min(vw/W,vh/H,1);
    st.style.transform='translate('+((vw-W*s)/2)+'px,'+((vh-H*s)/2)+'px) scale('+s+')';
    st.style.scale='1';
    st.setAttribute('data-scale',s.toFixed(4));
    st.setAttribute('data-noscroll',String(document.documentElement.scrollWidth<=window.innerWidth&&
      document.documentElement.scrollHeight<=window.innerHeight));
  };
  fit();window.addEventListener('resize',fit);
})();`
}

// ---------------------------------------------------------------------------
// FORMATTING. The contract's rule is one line long: a page renders a value, or
// "not collected yet". A zero that means "unknown" is a bug - so every helper
// below takes null/undefined/NaN as UNKNOWN and says so, and none of them ever
// turns unknown into 0.
// ---------------------------------------------------------------------------

export const NOT_COLLECTED = "Not collected"

/** HTML-escape; used for every string that reaches the page. */
export function fragEsc(s) {
  return String(s == null ? "" : s)
    .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;").replace(/'/g, "&#39;")
}

/** A finite number, or null. "" and booleans are not numbers here. */
export function numOr(v) {
  if (typeof v === "number") return Number.isFinite(v) ? v : null
  if (typeof v === "string" && v.trim() !== "") {
    const n = Number(v)
    return Number.isFinite(n) ? n : null
  }
  return null
}

/** Thousands separators, no locale surprises: 1234567 -> "1,234,567". */
export function thousands(n) {
  const v = numOr(n)
  if (v == null) return ""
  const neg = v < 0
  const s = String(Math.abs(Math.trunc(v))).replace(/\B(?=(\d{3})+(?!\d))/g, ",")
  return (neg ? "-" : "") + s
}

/** The page's value: grouped, or the honest dash when there is no value. */
export function show(n, dash) {
  return n == null || numOr(n) == null ? fragEsc(dash == null ? "—" : dash) : thousands(n)
}

/** A ratio given as {n, d} printed as "a / b", or a dash when either is unknown. */
export function showOf(n, d) {
  if (numOr(n) == null || numOr(d) == null) return "—"
  return `${thousands(n)} / ${thousands(d)}`
}

/** K/D to two places; a denominator of nothing is "—", not "0.00". */
export function kdText(k, d) {
  const a = numOr(k), b = numOr(d)
  if (a == null || b == null || b <= 0) return "—"
  return (a / b).toFixed(2)
}

/** A share as a whole percentage (0..100), or null when the whole is nothing. */
export function pctOf(part, whole) {
  const a = numOr(part), b = numOr(whole)
  if (a == null || b == null || b <= 0) return null
  return Math.max(0, Math.min(100, Math.round((a * 100) / b)))
}

/** A share printed as "60.1%" at one decimal, from two counts. */
export function pctText(part, whole, digits) {
  const a = numOr(part), b = numOr(whole)
  if (a == null || b == null || b <= 0) return "—"
  return (((a * 100) / b).toFixed(digits == null ? 1 : digits)) + "%"
}

/** "3 d 4 h" / "5 h 12 m" / "18 m" from a span in seconds. */
export function spanText(sec) {
  const v = numOr(sec)
  if (v == null) return "—"
  const t = Math.max(0, Math.trunc(v))
  const d = Math.floor(t / 86400), h = Math.floor((t % 86400) / 3600), m = Math.floor((t % 3600) / 60)
  if (d > 0) return `${d} d ${h} h`
  if (h > 0) return `${h} h ${m} m`
  return `${m} m`
}

/** Minutes of playtime the way a player reads it: "1,092 min · 18 h 12 m". */
export function playText(minutes) {
  const v = numOr(minutes)
  if (v == null) return "—"
  return `${thousands(v)} min · ${spanText(v * 60)}`
}

/** "just now" / "12 min ago" / "3 h ago" / "5 d ago"; a date past a month. */
export function agoText(when, now) {
  const t = numOr(when), n = numOr(now)
  if (t == null || t <= 0) return "—"
  const dt = Math.max(0, (n == null ? Math.floor(Date.now() / 1000) : n) - t)
  if (dt < 90) return "just now"
  if (dt < 3600) return `${Math.max(1, Math.floor(dt / 60))} min ago`
  if (dt < 86400) return `${Math.floor(dt / 3600)} h ago`
  if (dt < 86400 * 30) return `${Math.floor(dt / 86400)} d ago`
  return dateText(t)
}

/** "1 Dec 2026" in UTC, the calendar the panel stores its clocks in. */
export function dateText(sec) {
  const v = numOr(sec)
  if (v == null || v <= 0) return "—"
  const d = new Date(v * 1000)
  const months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
  return `${d.getUTCDate()} ${months[d.getUTCMonth()]} ${d.getUTCFullYear()}`
}

/** "1 Dec 2026, 14:05 UTC" - for an honest "last heard from the game" line. */
export function stampText(sec) {
  const v = numOr(sec)
  if (v == null || v <= 0) return "—"
  const d = new Date(v * 1000)
  const p2 = n => (n < 10 ? "0" : "") + n
  return `${dateText(v)}, ${p2(d.getUTCHours())}:${p2(d.getUTCMinutes())} UTC`
}

/** SteamID64 from a SteamID, for the profile link; "" when it is not one. */
export function steam64(steamid) {
  const m = /^STEAM_([0-5]):([01]):(\d+)$/.exec(String(steamid || ""))
  if (!m) return ""
  const base = BigInt("76561197960265728")
  return String(base + BigInt(m[1]) + BigInt(m[2]) * 2n + BigInt(m[3]) * 2n)
}

/** A percentage bar as markup: `w` is 0..100 or null (null = no track fill). */
export function barHtml(pct, cls) {
  const p = numOr(pct)
  const w = p == null ? 0 : Math.max(0, Math.min(100, p))
  return `<i class="bar${cls ? " " + cls : ""}"><b style="width:${w}%"></b></i>`
}
