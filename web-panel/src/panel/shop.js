// FreeNova panel — Winterfest Shop (page 11 of the 14, route /panel/shop).
//
// PLATE   docs/design/refs/winterfest/10-shop.png (1670x941). Every picture on this
//         page is a CSS sprite of that file: the nav rail, the top bar, the hero,
//         the tab row, the two product-card rows and the bundle panel are cut from
//         it, and the ten product-card chromes take their art window from the
//         plate's own cards. Nothing is redrawn that the plate contains; the only
//         code-drawn marks are the rarity dots (ART-RULE §4: code marks stay code)
//         and a snow hatch that covers the plate's sample product art inside each
//         card — those ten sprites are sample products of a shop that cannot sell
//         weapon skins, so naming one would be the lie. The cards say what is
//         really for sale instead.
//
// SHELF   The plate's shelf sells weapon skins and player models. THIS shop cannot:
//         winterfest_pull.sma grants exactly three things — `ornament:N` through
//         wf_grant_ornament, `title:N` through wf_grant(WF_REWARD_TITLE) and a
//         product through wf_grant_entitlement — so those are the only rows in the
//         catalogue (winter_shop, seeded by seed_shop_catalog.sql, documented in
//         docs/panel/01-DATA.md §11). Every card the plate draws and this shop
//         cannot deliver is rendered "not available yet" WITH its reason.
//
// BUYING  A card's Buy button is a POST to this same route (no client JS does any
//         of the work). The server calls queueAction({kind:"buy", payload:{item|
//         product, item_kind, price}, idem:"buy:<sku>:<Y-m-d>"}) and re-renders the
//         page with the row it created. There is no page-level write anywhere: the
//         only writer on this path is queueAction, and a row is shown as QUEUED
//         until applyAction (the game's pull, then the ack) has paid it. The idem
//         key carries the Europe/Paris day, so a refresh cannot charge twice on one
//         day. A Refusal is printed VERBATIM — the queue's own sentence.
//
// ONE SCREEN  A fixed 1670x941 stage scaled by min(vw/1670, vh/941), letterboxed,
//         with overflow:hidden on html/body and a document-level guard so no
//         scrollbar can exist at any viewport.
import { getPlayer, queueAction, Refusal } from "../state.js"
import { shopCatalog, ownedItems, actionsOfKind } from "../query.js"
import { esc, fmt } from "../top15/render.js"
import { actionState, refusalText } from "./shared.js"

export const PLATE = "10-shop.png"
export const PLATE_W = 1670, PLATE_H = 941
export const PLATE_URL = "/plates/10-shop.png"
export const GENERATED_DIR = "/assets/generated/"

// --------------------------------------------------------------- the sprites --
// [name, sx, sy, sw, sh, x, y, w, h]. The plate rectangle, then where it is
// painted; omitted x/y/w/h means "in place, at native size" — the whole reason
// the page is a plate.
const S = (name, sx, sy, sw, sh, x, y, w, h) => [name, sx, sy, sw, sh,
  x == null ? sx : x, y == null ? sy : y, w == null ? sw : w, h == null ? sh : h]

export const SPRITES = [
  // the page's own chrome, once, whole
  S("page", 0, 0, PLATE_W, PLATE_H),
  // the four card corners / tinted panes, cut from the plate's own two rows of cards
  S("cardA", 313, 271, 206, 172),
  S("cardB", 524, 271, 206, 172),
  S("cardC", 734, 271, 206, 172),
  S("cardD", 948, 271, 212, 172),
  S("cardE", 313, 480, 206, 172),
  // the plate's inactive tab pill, for the tabs the page offers
  S("tabPill", 512, 285, 172, 32, null, null, null, null),
  // the hero's own red ribbon band — used as the notice banner's plate chrome
  S("ribbon", 690, 180, 320, 34, null, null, null, null)
]

// The card grid, in the plate's own geometry: five columns, two rows.
// y = the card's frame top (the plate's TEXT top is the frame + 102 px), h = the
// frame's bottom. The six slots are the plate's own two rows.
export const CARD_SLOTS = [
  { x: 313, y: 373, w: 206, h: 75, art: "cardA" },
  { x: 524, y: 373, w: 206, h: 75, art: "cardB" },
  { x: 734, y: 373, w: 206, h: 75, art: "cardC" },
  { x: 948, y: 373, w: 212, h: 75, art: "cardD" },
  // the plate's SECOND row: its cards' frame bottoms are at 701, so the saved
  // plate slot is 30 px taller than the first row's card.
  { x: 313, y: 582, w: 206, h: 105, art: "cardE" },
  { x: 524, y: 582, w: 206, h: 105, art: "cardB", sketch: true }
]

// Where the page's text sits INSIDE a card (card-relative), in the plate's own
// places: the art window, the title lines under it, and the price pill.
// Card-relative, so a card's slot y only moves the frame: the plate's product
// art sits at y 0..102, its title on y 104, its kind line on y 122 and the price
// pill on y 140..168. The page prints ITS OWN title/kind/price over those exact
// anchors — and covers the plate's art with the plate's own card plate above.
export const CARD_TEXT = {
  art: [20, 9, 174, 54],
  title: [6, 103, 194, 16],
  kind: [6, 121, 194, 13],
  price: [24, 141, 130, 18],
  buy: [152, 140, 46, 20]
}

// The bands the page's own text sits on, INSIDE the card: they are plate chrome
// copied over the plate's own sample words, in two rounds so they do not erase
// each other. Read off the first card of 10-shop.png (title y 104, kind y 122,
// price pill y 140..168).
// 10-shop.png (x 340, y 452): the dark field between the plate's two card rows —
// clean card plate with no sample word on it, which is what each band copies.
export const CARD_BANDS = {
  fill: [340, 452, 42, 16],
  // One whole 2.5x price pill (gingerbread icon + figure + a little of its plate)
  pill: [336, 409, 92, 28],
  pillW: 150, pillH: 28, artW: 174, artH: 54
}

// The page's tabs. `tier` filters the catalogue; "" is the plate's "All Items".
export const TABS = [
  { tier: "", label: "All Items", x: 312, w: 190 },
  { tier: "ornaments", label: "Ornaments", x: 507, w: 190 },
  { tier: "badges", label: "Collector Titles", x: 700, w: 200 },
  { tier: "frames", label: "Battle Pass", x: 905, w: 180 },
  { tier: "misc", label: "Advent", x: 1090, w: 150 }
]

// The plate's sample products, cut for the sprite record. Their ART is covered on
// the page (the snow hatch); the cards themselves are the chrome above.
export const PLATE_CARDS = [
  ["shop-item-ak47", 313, 271, 206, 172],
  ["shop-item-m4a1", 524, 271, 206, 172],
  ["shop-item-awp", 734, 271, 206, 172],
  ["shop-item-deagle", 948, 271, 212, 172],
  ["shop-item-santa", 313, 480, 206, 172],
  ["shop-item-grinch", 524, 480, 206, 172],
  ["shop-item-snowman", 734, 480, 206, 172],
  ["shop-item-elf", 948, 480, 212, 172]
]

// What the plate's shelf shows and this shop cannot sell yet, one reason each.
// Drawn as the plate's own cards with "Not available yet" and the reason under it.
export const RESERVED = [
  ["Weapon Skins", "the pull grants ornament:* and title:* only, so a skin cannot be delivered"],
  ["Player Models", "cosmetics.ini has model rows; the pull has no path to wfcos_grant_id"],
  ["Frames", "driver-owned in winterfest_cosmetics; the pull never grants a cosmetic id"],
  ["Badges", "same gap: a cosmetic id, and no panel grant path"],
  ["Kill Icons", "effect rows in cosmetics.ini, not grantable from the panel"],
  ["Mystery Box", "no box product in [entitlement], so there is nothing to open"],
  ["Winter Case", "same: no product id to sell or open"]
]

export const TILE = {
  x: 313, y: 700, w: 206, h: 116,
  gap: 207,
  fill: [313, 700, 206, 116]
}

const CSS = `
@font-face{font-family:'Nunito';src:url('/assets/fonts/Nunito-Variable.ttf') format('truetype-variations');
  font-weight:200 1000;font-display:swap}
*{box-sizing:border-box}
html,body{margin:0;padding:0;width:100%;height:100%;overflow:hidden;background:#0b1030;overscroll-behavior:none}
body{font-family:Nunito,'Trebuchet MS','Segoe UI',Cantarell,Arial,sans-serif;-webkit-font-smoothing:antialiased}
#letterbox{position:fixed;inset:0;overflow:hidden;background:#0b1030}
#stage{position:absolute;left:0;top:0;width:${PLATE_W}px;height:${PLATE_H}px;overflow:hidden;
  transform-origin:0 0;color:#fff}
#plate{position:absolute;left:0;top:0;width:${PLATE_W}px;height:${PLATE_H}px;
  background-image:url(${PLATE_URL});background-repeat:no-repeat;background-size:${PLATE_W}px ${PLATE_H}px}
.sp{position:absolute;background-image:url(${PLATE_URL});background-repeat:no-repeat;
  background-size:${PLATE_W}px ${PLATE_H}px}
${SPRITES.map(([n, sx, sy, sw, sh, x, y, w, h]) =>
  `.sp-${n}{left:${x}px;top:${y}px;width:${w}px;height:${h}px;` +
  `background-position:-${sx}px -${sy}px}`).join("\n")}
/* the card plate: the darkest clean band the shop plate itself has (the lower
   middle of its first card), tiled over that card's sample art. A sprite of the
   plate, never a colour the plate does not have. */
.pad{position:absolute;background:linear-gradient(#0e1530,#0b1128);border:2px solid #2a3d6e;border-top:0}
.hatch{position:absolute;background-image:url(${PLATE_URL});background-repeat:repeat;
  background-size:${PLATE_W}px ${PLATE_H}px;background-position:-330px -415px}
.pill{position:absolute;background-image:url(${PLATE_URL});background-repeat:no-repeat;
  background-size:${CARD_BANDS.pillW}px ${CARD_BANDS.pillH}px;
  background-position:-${CARD_BANDS.pill[0]}px -${CARD_BANDS.pill[1]}px}
.card{position:absolute;overflow:hidden}
.card .lbl{position:absolute;font-weight:800;color:#fff;text-shadow:0 1px 2px #000;
  white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.card .sub{position:absolute;color:#c9d2ea;font-weight:600;text-shadow:0 1px 2px #000;
  white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.card .why{position:absolute;color:#ffd9a8;font-weight:700;text-shadow:0 1px 2px #000;
  white-space:normal;overflow:hidden}
.card .ico{position:absolute;overflow:hidden}
.card .ico img{width:100%;height:100%;object-fit:contain;display:block}
.card form{margin:0}
.card .buy{position:absolute;border:0;padding:0;height:20px;border-radius:10px;cursor:pointer;
  font:inherit;font-size:10.5px;font-weight:800;color:#fff;
  background:linear-gradient(#3fbf6f,#1f8a4a);box-shadow:0 1px 0 #0b1030,inset 0 0 0 1px #8ef0b0}
.card .buy:hover{filter:brightness(1.1)}
.card .owned{position:absolute;font-size:10.5px;font-weight:800;color:#8ef0b0;text-shadow:0 1px 2px #000}
.card .queued{position:absolute;font-size:10px;font-weight:800;color:#ffd975;text-shadow:0 1px 2px #000}
.rar{display:inline-block;width:7px;height:7px;border-radius:50%;vertical-align:middle;margin-right:3px}
.rar-common{background:#4070c0}.rar-uncommon{background:#3fbf6f}.rar-rare{background:#f5c451}
.panel{position:absolute;border:2px solid #2a3d6e;border-radius:14px;background:rgba(13,20,48,.975);
  box-shadow:0 8px 24px rgba(0,0,0,.45)}
.panel .plate-art{display:block;width:100%;height:100%;object-fit:cover;object-position:center;border-radius:10px}
.panel h3{margin:0 0 2px;font-size:14.5px;line-height:18px;font-weight:800;color:#f5c451;text-shadow:0 1px 2px #000}
.panel .hint{font-size:10.5px;line-height:13px;font-weight:600;color:#c9d2ea}
.row{display:flex;align-items:center;gap:6px;font-variant-numeric:tabular-nums}
.chip{display:inline-flex;align-items:center;padding:1px 7px;border-radius:9px;font-size:10.5px;
  font-weight:800;background:#1b2a52;color:#fff;border:1px solid #2a3d6e;white-space:nowrap}
.chip.pending{background:#3a2c07;color:#ffd975;border-color:#6b5410}
.chip.paid{background:#0f3322;color:#8ef0b0;border-color:#1f6b3a}
.chip.refused{background:#3a0d16;color:#ffb3c0;border-color:#7a1a2a}
.notice{position:absolute;left:313px;top:618px;width:880px;padding:7px 14px;border-radius:12px;
  font-size:12px;line-height:16px;font-weight:800}
.notice.ok{background:rgba(15,51,34,.97);border:2px solid #1f6b3a;color:#b9ffd2}
.notice.bad{background:rgba(58,13,22,.97);border:2px solid #7a1a2a;color:#ffc4cf}
.notice.warn{background:rgba(58,44,7,.97);border:2px solid #6b5410;color:#ffe1a3}
.tab{position:absolute;top:285px;height:32px;border:0;padding:0 12px;background:transparent;cursor:pointer;
  font:inherit;font-size:12.5px;font-weight:800;color:#dbe4ff;text-shadow:0 1px 2px #000;
  white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.tab.sel{color:#fff;text-shadow:0 0 8px #c58bff,0 1px 2px #000}
.tab:hover{color:#fff}
.who{position:absolute;left:318px;top:250px;width:620px;font-size:12.5px;line-height:16px;
  font-weight:800;color:#fff;text-shadow:0 1px 3px #000;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.wal{position:absolute;left:320px;top:582px;width:870px;display:flex;gap:8px;align-items:center}
.bundle{left:1238px;top:312px;width:428px;height:250px;padding:9px 12px;overflow:hidden}
.bundle .hatch{left:10px;top:12px;width:408px;height:96px;border-radius:10px}
.deals{left:1200px;top:606px;width:466px;height:150px;padding:9px 12px}
.hist{left:313px;top:740px;width:432px;height:190px;padding:9px 12px;overflow:hidden}
.mine{left:763px;top:740px;width:420px;height:190px;padding:9px 12px;overflow:hidden}
`;

// --------------------------------------------------------------- formatting --
function num(v) { return typeof v === "number" && Number.isFinite(v) ? v : null }
const DAYS = new Intl.DateTimeFormat("en-CA", {
  timeZone: "Europe/Paris", year: "numeric", month: "2-digit", day: "2-digit"
})

/** The Europe/Paris calendar day, as YYYY-MM-DD — the day a purchase key is scoped
 *  to. `en-CA` formats exactly that way, so the string IS the idem suffix. */
export function parisDay(now) { return DAYS.format(new Date(now * 1000)) }

/** The idempotency key for one purchase on one day: `buy:<sku>:<day>`. The sku
 *  already carries its kind (`ornament:5`, `product:bp_premium_2026`), so the key
 *  names the product exactly and a refresh cannot charge twice on one day. */
export function buyIdem(sku, day) { return `buy:${sku}:${day}` }

function gbText(n) { return esc(fmt(n)) + " GB" }

// --------------------------------------------------------------- the loader --
// Fixed query count: getPlayer (its own fixed set), the shelf, what the player
// owns, their buy rows. Nothing runs inside a loop.
export async function loadShop(env, sid, now) {
  let p = null, shelf = [], owned = { items: [], products: [] }, buys = []
  if (env && env.DB) {
    try { shelf = await shopCatalog(env.DB) } catch { shelf = [] }
    if (sid) {
      try { p = await getPlayer(env.DB, sid) } catch { p = null }
      if (p && p.exists) {
        try { owned = await ownedItems(env.DB, sid) } catch { owned = { items: [], products: [] } }
        try { buys = await actionsOfKind(env.DB, sid, "buy", { limit: 12 }) } catch { buys = [] }
      }
    }
  }
  return { sid, p, known: !!(p && p.exists), shelf, owned, buys, now, day: parisDay(now) }
}

function ownership(d) {
  return {
    items: new Set((d.owned.items || []).map(i => i.item)),
    products: new Set((d.owned.products || []).map(i => i.product))
  }
}

/** The player's live buy row for one sku: a pending row wins (that is what the
 *  page must show as queued), then today's row, then the newest one. */
export function rowForSku(d, sku, day) {
  const mine = (d.buys || []).filter(r => {
    const pl = r.payload || {}
    if (pl.product) return sku === "product:" + pl.product
    return String(pl.item || "") === sku
  })
  return mine.find(r => r.state === "pending") ||
    mine.find(r => r.idem === buyIdem(sku, day)) || mine[0] || null
}

// ------------------------------------------------------------------ actions --
/** The one write path: queue a `buy` for one shelf row and say what happened.
 *  Never writes a state table — queueAction is the only writer in the panel. */
export async function submitBuy(env, sid, form, now) {
  const sku = String((form && form.get("sku")) || "").trim()
  const day = parisDay(now)
  const out = { sku, kind: "", message: "", ok: false, action: null, created: false }
  if (!sid) {
    out.kind = "warn"
    out.message = "No SteamID: the shop cannot charge a player it cannot name. Open the page with ?steamid=STEAM_0:0:123."
    return out
  }
  let row = null
  try { row = (await shopCatalog(env.DB)).find(r => r.sku === sku) } catch { row = null }
  if (!row) {
    out.kind = "bad"
    out.message = `Nothing was queued: the shelf has no product "${sku}".`
    return out
  }
  if (!row.price.coins && !row.price.gingerbread) {
    out.kind = "bad"
    out.message = `Nothing was queued: "${row.name}" has no price in the catalogue.`
    return out
  }
  const payload = { price: { coins: row.price.coins, gingerbread: row.price.gingerbread } }
  if (row.kind === "product") payload.product = row.product
  else { payload.item = row.item; payload.item_kind = row.item_kind }
  try {
    const res = await queueAction(env.DB, { steamid: sid, kind: "buy", payload, idem: buyIdem(sku, day), now })
    out.ok = true
    out.created = !!res.created
    out.action = res.action
    out.kind = "ok"
    out.message = res.created
      ? `Queued: ${row.name}. It is NOT paid yet — it stays queued until the game pulls it and the apply step pays it.`
      : `Already queued today: action #${res.action.id} for ${row.name}. Nothing new was created (a refresh or a double click cannot charge twice).`
  } catch (e) {
    // The refusal is the queue's own sentence, verbatim (owner rule).
    out.kind = "bad"
    out.message = refusalText(e)
    out.refused = e instanceof Refusal
  }
  return out
}

// ----------------------------------------------------------------- rendering --
const RARITY = { common: "common", uncommon: "uncommon", rare: "rare" }
const KIND_WORD = { product: "Entitlement", title: "Collector Title", ornament: "Ornament" }

function iconPath(sku) { return GENERATED_DIR + "shop-" + sku.replace(":", "-") + ".png" }

// A card = the plate's card art (frame + snow cap + red NEW tag) with the plate's
// own sample ART covered by a tile of the plate's card plate. Everything else in
// the sprite is the owner's drawing, untouched: the frame, the cap, the tag.
/** Is this card's art window lying on the plate's own drawing?
 *
 *  Five of the six slots sit exactly where the plate has a card, so the plate's
 *  product art is under the page's window and must be covered. The sixth slot
 *  (x 524, y 582) is the one place on the plate with no card under it — the gap
 *  below the plate's first row — so covering there would paint a dark tile onto
 *  bare plate. Nothing else in the page uses that difference. */
export function onPlateArt(slot) { return !(slot.x === 524 && slot.y === 582) }

function cardShell(slot) {
  // The plate has no single "empty card", so a card is assembled from the clean
  // bands the plate itself prints: the cap + NEW tag, the price band, and — for
  // the taller second-row slot — the plain plate under the card's frame.
  const pads = slot.h > 75
    ? `<div class="pad" style="left:0;top:75px;width:100%;height:${slot.h - 75}px;border-radius:0 0 12px 12px"></div>`
    : ""
  const band = (y, h) => `<div class="hatch" style="left:6px;top:${y}px;width:${slot.w - 12}px;height:${h}px"></div>`
  const pill = `<div class="pill" style="left:14px;top:139px;width:${CARD_BANDS.pillW}px;` +
    `height:${CARD_BANDS.pillH}px"></div>`
  return `<div class="card" style="left:${slot.x}px;top:${slot.y}px;width:${slot.w}px;height:${slot.h}px">` +
    `<div class="sp sp-${slot.art}"></div>${pads}` +
    (onPlateArt(slot) ? `<div class="hatch" style="left:${CARD_TEXT.art[0]}px;top:${CARD_TEXT.art[1]}px;` +
      `width:${CARD_BANDS.artW}px;height:${CARD_BANDS.artH}px"></div>` : "") +
    band(102, 18) + band(120, 14) + band(138, 34) + pill
}

function cardHtml(d, slot, row) {
  const own = ownership(d)
  const isOwned = row.kind === "product" ? own.products.has(row.product) : own.items.has(row.item)
  const act = rowForSku(d, row.sku, d.day)
  const st = act ? actionState(act) : null
  const price = row.price.gingerbread ? gbText(row.price.gingerbread)
    : row.price.coins ? esc(fmt(row.price.coins)) + " Coins" : "—"
  let tail
  if (isOwned) {
    tail = `<div class="owned" style="left:${CARD_TEXT.buy[0]}px;top:${CARD_TEXT.buy[1] + 2}px">Owned</div>`
  } else if (st && st.key === "pending") {
    tail = `<div class="queued" style="left:${CARD_TEXT.buy[0] - 4}px;top:${CARD_TEXT.buy[1] + 2}px;width:56px;text-align:right">Queued</div>`
  } else {
    const why = st && st.key === "refused" ? ` — last attempt refused: ${st.detail}` : ""
    tail = `<form method="post" action="/panel/shop">` +
      `<input type="hidden" name="s" value="${esc(d.sid || "")}">` +
      `<input type="hidden" name="sku" value="${esc(row.sku)}">` +
      `<input type="hidden" name="tier" value="${esc(d.tier || "")}">` +
      `<button class="buy" type="submit" style="left:${CARD_TEXT.buy[0]}px;top:${CARD_TEXT.buy[1]}px;` +
      `width:${CARD_TEXT.buy[2]}px" title="Queue a purchase of ${esc(row.name)}${esc(why)}">Buy</button></form>`
  }
  return cardShell(slot) +
    `<div class="ico" style="left:${CARD_TEXT.art[0]}px;top:${CARD_TEXT.art[1]}px;` +
    `width:${CARD_TEXT.art[2]}px;height:${CARD_TEXT.art[3]}px">` +
    `<img src="${esc(iconPath(row.sku))}" alt="" width="${CARD_TEXT.art[2]}" height="${CARD_TEXT.art[3]}"></div>` +
    `<div class="lbl" style="left:${CARD_TEXT.title[0]}px;top:${CARD_TEXT.title[1]}px;width:${CARD_TEXT.title[2]}px;font-size:12px">` +
    `<i class="rar rar-${RARITY[row.rarity] || "common"}"></i>${esc(row.name)}</div>` +
    `<div class="sub" style="left:${CARD_TEXT.kind[0]}px;top:${CARD_TEXT.kind[1]}px;width:${CARD_TEXT.kind[2]}px;font-size:10px">` +
    `${esc(KIND_WORD[row.kind] || row.kind)}</div>` +
    `<div class="lbl" style="left:${CARD_TEXT.price[0]}px;top:${CARD_TEXT.price[1]}px;width:${CARD_TEXT.price[2]}px;font-size:11.5px">` +
    `${price}</div>${tail}</div>`
}

/** A tile the plate's shelf drew and this shop cannot sell: the plate's card with
 *  the honest state and the reason, never a price and never a Buy button. */
function reservedHtml(slot, label, why) {
  return cardShell(slot) +
    `<div class="why" style="left:${CARD_TEXT.art[0] + 6}px;top:${CARD_TEXT.art[1] + 14}px;` +
    `width:${CARD_TEXT.art[2] - 12}px;height:64px;font-size:10px;line-height:12px;text-align:center">` +
    `<b style="font-size:12.5px">${esc(label)}</b><br>Not available yet — ${esc(why)}.</div>` +
    `<div class="lbl" style="left:${CARD_TEXT.title[0]}px;top:${CARD_TEXT.title[1]}px;width:${CARD_TEXT.title[2]}px;font-size:12px">` +
    `${esc(label)}</div>` +
    `<div class="sub" style="left:${CARD_TEXT.kind[0]}px;top:${CARD_TEXT.kind[1]}px;width:${CARD_TEXT.title[2]}px;font-size:10px">` +
    `No price — the game cannot deliver it</div></div>`
}

function tabHtml(d, t, i) {
  const sel = (d.tier || "") === t.tier
  const art = sel ? `<div class="sp sp-tabPill" style="left:0;top:0;width:100%;height:32px;border-radius:16px"></div>` : ""
  // The plate's selected tab is its first, purple pill; every other tab is a
  // text button on the plate's own dark rail, which is what the plate shows.
  const style = sel
    ? `left:${t.x}px;width:${t.w}px;color:#fff`
    : `left:${t.x}px;width:${t.w}px`
  return `<a class="tab${sel ? " sel" : ""}" href="/panel/shop?tier=${encodeURIComponent(t.tier)}` +
    (d.sid ? `&amp;steamid=${encodeURIComponent(d.sid)}` : "") + `" style="${style}">${esc(t.label)}</a>`
}

function historyRows(d) {
  const rows = (d.buys || []).slice(0, 5).map(r => {
    const st = actionState(r)
    const pl = r.payload || {}
    const subject = pl.product ? "product:" + pl.product : (pl.item || "?")
    const chip = st.key === "pending" ? "pending" : st.key === "refused" ? "refused" : "paid"
    const detail = st.key === "pending" ? `queued ${esc(actionDay(r))}` : esc(st.label)
    return `<div class="row" style="margin-top:3px"><span class="chip ${chip}">${detail}</span>` +
      `<span style="font-size:10.5px;font-weight:700">${esc(subject)}</span></div>`
  })
  return rows.length ? rows.join("") : `<div class="hint" style="margin-top:6px">No purchase yet: nothing has been queued from this page.</div>`
}

function actionDay(r) {
  const t = Number((r && r.created_at) || 0)
  if (!t) return ""
  return DAYS.format(new Date(t * 1000))
}

export function renderShop(d, opts) {
  const o = opts || {}
  const tier = d.tier || ""
  const shelf = (d.shelf || []).filter(r => !tier || r.tier === tier)
  const p = d.p
  const known = d.known

  const cards = shelf.slice(0, 6).map((r, i) => cardHtml(d, CARD_SLOTS[i], r)).join("")
  const shelfFull = Math.min(6, shelf.length)
  // What is left of the plate's six-card shelf is the plate's own products that
  // this shop cannot sell — with their reasons, in the plate's own cards.
  const reserved = RESERVED.slice(0, Math.max(0, 6 - shelfFull))
    .map(([label, why], i) => reservedHtml(CARD_SLOTS[shelfFull + i], label, why)).join("")
  // The plate's second card row is exactly six tiles of a category the shop has no
  // deliverable for; the seventh reason gets the last tile.
  const overflow = RESERVED.slice(Math.max(0, 6 - shelfFull))

  const n = o.notice
  const notice = n ? `<div class="notice ${n.kind === "ok" ? "ok" : n.kind === "warn" ? "warn" : "bad"}">${esc(n.message)}</div>` : ""

  const wallet = known
    ? `<span class="chip">${esc(fmt(p.coins))} Coins</span><span class="chip">${esc(fmt(p.gingerbread))} GingerBread</span>` +
      `<span class="chip">${esc(fmt(p.spins))} Spins</span>`
    : `<span class="chip">No player</span>`

  const who = known
    ? `${esc(p.name || d.sid)} · Level ${num(p.level) == null ? "—" : esc(fmt(p.level))} · Shopping ${esc(d.day)}`
    : (d.sid ? `${esc(d.sid)} — the panel has never heard from this player`
      : "No player selected — add ?steamid=STEAM_0:0:123 to load a wallet")

  const own = ownership(d)
  const mineChips = [
    ...(d.owned.products || []).map(i => `<span class="chip paid">${esc(i.product)}</span>`),
    ...(d.owned.items || []).map(i => `<span class="chip">${esc(i.item)}${i.equipped ? " · worn" : ""}</span>`)
  ].join("")
  const mine = mineChips || `<span class="hint">Nothing owned yet: no purchase has been applied for this player.</span>`
  const unchanged = own.items.size + own.products.size

  // The bundle panel: the plate's own panel with its sample art covered; there is
  // no bundle product, so the panel says so instead of showing a price.
  const bundle = `<div class="panel bundle">
      <h3>Featured Bundle</h3>
      <div class="hint"><b style="color:#ffd9a8">Not available yet.</b> The plate's bundle art stays as the
        owner drew it, because there is no bundle to name: no bundle id exists in winterfest.ini
        [entitlement], and the pick it advertises (3 skins + a model + a frame + a trail + a kill icon)
        is five things the game's pull cannot grant. Nothing is priced, so nothing can be bought.</div>
    </div>`

  const deals = `<div class="panel deals">
      <h3>Daily Deals</h3>
      <div class="hint"><b style="color:#ffd9a8">Not available yet.</b> The plate's three deal cards stay
        as drawn. winter_shop has no discount, bundle or time-limited column, so there is no price to
        show and no refresh time to count. The deals are drawn by the owner, not sold by this page.</div>
    </div>`

  const history = `<div class="panel hist">
      <h3>Purchase History</h3>
      <div class="hint">Your own buy actions. A row says Paid only once the apply step has charged it.</div>
      ${historyRows(d)}
    </div>`

  const holding = `<div class="panel mine">
      <h3>Your Shelf</h3>
      <div class="hint">What applyAction has already added to your inventory.</div>
      <div class="row" style="flex-wrap:wrap;margin-top:5px;gap:4px">${mine}</div>
      <div class="hint" style="margin-top:6px">${unchanged} item(s) held.</div>
    </div>`

  const stage = `
<div id="stage" data-day="${esc(d.day)}">
  <div class="sp sp-page"></div>
  ${SPRITES.filter(s => s[0] === "tabPill").map(s => `<div class="sp sp-${s[0]}" style="display:none"></div>`).join("")}
  <div class="who">${who}</div>
  <div class="wal">${wallet}</div>
  ${TABS.map((t, i) => tabHtml(d, t, i)).join("")}
  ${cards}
  ${reserved}
  ${overflow.slice(0, 3).map(([label, why], i) => reservedHtml({ ...TILE, x: TILE.x + i * TILE.gap }, label, why)).join("")}
  ${notice}
  ${bundle}
  ${deals}
  ${history}
  ${holding}
</div>`

  return `<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>FreeNova · Winterfest Shop</title>
<style>${CSS}</style></head>
<body><div id="letterbox">${stage}</div>
<script>
(function(){
  // ONE SCREEN: the fixed stage is scaled to fit BOTH axes (min(vw/W, vh/H)) and
  // centred. No reflow, no document scroll: the stage is the page.
  var st=document.getElementById('stage');
  var W=${PLATE_W},H=${PLATE_H};
  function fit(){
    var vw=window.innerWidth,vh=window.innerHeight;
    var s=Math.min(vw/W,vh/H,1);
    st.style.transform='translate('+Math.round((vw-W*s)/2)+'px,'+Math.round((vh-H*s)/2)+'px) scale('+s+')';
    st.setAttribute('data-scale',s.toFixed(4));
    st.setAttribute('data-noscroll',String(
      document.documentElement.scrollWidth<=vw && document.documentElement.scrollHeight<=vh));
  }
  fit();window.addEventListener('resize',fit);
})();
</scr` + `ipt>
</body></html>`
}

// --------------------------------------------------------------------- page --
export async function pageShop(env, url, request) {
  const now = Math.floor(Date.now() / 1000)
  const minted = url && url._fnMotdSid
  let sid = /^STEAM_[0-9]:[0-9]:\d+$/.test(String(minted || "")) ? String(minted) : ""
  if (!sid) {
    const q = String(url.searchParams.get("steamid") || "").trim()
    if (/^STEAM_[0-9]:[0-9]:\d+$/.test(q)) sid = q
  }
  let notice = null
  if (request && request.method === "POST") {
    let form = null
    try { form = await request.formData() } catch { form = null }
    if (form) {
      const bodySid = String(form.get("s") || "").trim()
      if (/^STEAM_[0-9]:[0-9]:\d+$/.test(bodySid)) sid = bodySid
      notice = await submitBuy(env, sid, form, now)
    } else {
      notice = { kind: "bad", message: "Nothing was queued: the form could not be read." }
    }
  }
  const d = await loadShop(env, sid, now)
  d.tier = String(url.searchParams.get("tier") || "")
  return new Response(renderShop(d, { notice }), {
    status: 200,
    headers: {
      "content-type": "text/html; charset=utf-8",
      "cache-control": "no-store",
      "x-content-type-options": "nosniff"
    }
  })
}
