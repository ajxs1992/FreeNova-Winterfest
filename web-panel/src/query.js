// FreeNova panel — the read-only query layer (docs/panel/00-CONTRACT.md).
//
// Every page reads through here and never touches a state table itself. Two rules:
//
//  1. READ ONLY. Nothing in this file writes a row. The one call it makes into the
//     state layer is ensureStateSchema(), which creates missing tables/columns and
//     never touches data — so a page cannot fail on a fresh database.
//  2. PARAMETERISED. Every value a caller supplies is a bound parameter (?1, ?2 …).
//     The only identifiers that appear in a statement body come from the frozen
//     maps below, never from a caller, so there is no SQL string concatenation in
//     this file to get wrong.
//
// A helper that has no data to give returns an empty list or an explicit null, not
// an invented number: "not collected yet" is a render decision the page makes from
// `null`, and a zero that means "unknown" is a bug (contract §Rules).

import { ensureStateSchema, MAX_TREE_SLOT, validSteamid, Refusal } from "./state.js"

async function allOn(db, sql, params) {
  const res = await db.prepare(sql).bind(...(params || [])).all()
  return (res && res.results) || []
}

function clampLimit(raw, fallback, max) {
  const n = Math.trunc(Number(raw))
  if (!Number.isFinite(n) || n <= 0) return fallback
  return Math.min(n, max)
}

function sid(steamid) {
  const s = String(steamid || "")
  if (!validSteamid(s)) throw new Refusal("bad steamid")
  return s
}

// ------------------------------------------------------------------- boards --
// A top board is one metric, one statement, `LIMIT ?1`. The metric is never
// interpolated: a caller names a key in this map, and the map holds the SQL.
const BOARDS = Object.freeze({
  xp: {
    label: "XP",
    sql: `SELECT steamid, name, xp AS value FROM players WHERE xp > 0 ORDER BY xp DESC, steamid LIMIT ?1`
  },
  level: {
    label: "Level",
    sql: `SELECT steamid, name, level AS value FROM players WHERE level > 0 ORDER BY level DESC, xp DESC, steamid LIMIT ?1`
  },
  kills: {
    label: "Kills",
    sql: `SELECT steamid, name, kills AS value FROM players WHERE kills > 0 ORDER BY kills DESC, steamid LIMIT ?1`
  },
  coins: {
    label: "Coins",
    sql: `SELECT steamid, name, coins AS value FROM players WHERE coins > 0 ORDER BY coins DESC, steamid LIMIT ?1`
  },
  gingerbread: {
    label: "Gingerbread",
    // The winter currency lives in winter_players; the name comes from players
    // when the panel has a row for that steamid, and is empty otherwise.
    sql: `SELECT w.steamid AS steamid, COALESCE(p.name, '') AS name, w.snowflakes AS value
            FROM winter_players w LEFT JOIN players p ON p.steamid = w.steamid
           WHERE w.snowflakes > 0
           ORDER BY w.snowflakes DESC, w.steamid LIMIT ?1`
  }
})

export const BOARD_KEYS = Object.freeze(Object.keys(BOARDS))

function rankRows(rows) {
  return rows.map((r, i) => ({
    rank: i + 1,
    steamid: r.steamid,
    name: String(r.name || ""),
    value: Number(r.value || 0)
  }))
}

// All the top lists one page needs, from one call: { xp: [...], level: [...], … }.
// `boards` narrows which ones are read (a page that shows two lists does not pay
// for five).
export async function topBoards(db, opts) {
  await ensureStateSchema(db)
  const limit = clampLimit(opts && opts.limit, 15, 100)
  const wanted = (opts && Array.isArray(opts.boards) && opts.boards.length ? opts.boards : BOARD_KEYS)
    .filter(k => Object.prototype.hasOwnProperty.call(BOARDS, k))
  const out = {}
  for (const key of wanted) out[key] = rankRows(await allOn(db, BOARDS[key].sql, [limit]))
  return out
}

// ----------------------------------------------------------------- missions --
// The panel owns CLAIM STATE, not the mission ladder: what a mission pays and
// whether it is finished is the game's `winterfest/missions.ini`, published through
// the signed push (catalog key "winterfest"). What this returns is the one thing the
// panel can honestly answer — which missions this player has claimed, which are
// still queued, and why one was refused.
export async function missionsFor(db, steamid, opts) {
  await ensureStateSchema(db)
  const sidValue = sid(steamid)
  const limit = clampLimit(opts && opts.limit, 60, 200)
  const rows = await allOn(db,
    `SELECT id, payload, state, idem, created_at, applied_at, error, result
       FROM winter_actions
      WHERE steamid=?1 AND kind='claim_mission'
      ORDER BY id DESC LIMIT ?2`, [sidValue, limit])
  return rows.map(r => {
    let payload = {}
    try { payload = JSON.parse(r.payload || "{}") } catch {}
    return {
      action_id: Number(r.id),
      mission: payload.mission == null ? "" : String(payload.mission),
      state: r.state,                       // pending | applied | refused
      idem: r.idem,
      created_at: Number(r.created_at || 0),
      applied_at: Number(r.applied_at || 0),
      error: r.error || "",
      paid: parseOrNull(r.result)
    }
  })
}

// ------------------------------------------------------------ achievements --
// What the panel has actually GRANTED this player as a badge or a title, from
// winter_inventory. The achievement ladder itself (achievements.ini) is game-side
// and is not mirrored here; a page that needs the ladder reads the pushed catalogue.
export async function achievements(db, steamid) {
  await ensureStateSchema(db)
  const sidValue = sid(steamid)
  const rows = await allOn(db,
    `SELECT item, kind, equipped, acquired_at
       FROM winter_inventory
      WHERE steamid=?1 AND kind IN ('title', 'badge')
      ORDER BY acquired_at DESC, item`, [sidValue])
  return rows.map(r => ({
    item: r.item,
    kind: r.kind,
    equipped: Number(r.equipped || 0) === 1,
    acquired_at: Number(r.acquired_at || 0)
  }))
}

// --------------------------------------------------------------------- mail --
// The inbox. One row per message per recipient (schema.sql), unread first and then
// newest; an expired row is invisible but never deleted.
export async function mail(db, steamid, opts) {
  await ensureStateSchema(db)
  const sidValue = sid(steamid)
  const limit = clampLimit(opts && opts.limit, 20, 100)
  const now = Math.trunc(Number(opts && opts.now)) || Math.floor(Date.now() / 1000)
  const rows = await allOn(db,
    `SELECT id, kind, title, body, created_at, read_at, expires_at, payload
       FROM winter_mail
      WHERE steamid=?1 AND (expires_at = 0 OR expires_at > ?2)
      ORDER BY (read_at = 0) DESC, created_at DESC, id DESC
      LIMIT ?3`, [sidValue, now, limit])
  return rows.map(r => ({
    id: Number(r.id),
    kind: r.kind,
    title: r.title || "",
    body: r.body || "",
    created_at: Number(r.created_at || 0),
    read_at: Number(r.read_at || 0),
    unread: Number(r.read_at || 0) === 0,
    expires_at: Number(r.expires_at || 0),
    payload: parseOrNull(r.payload)
  }))
}

// ---------------------------------------------------------------- tree slots --
// The 24 slots, always 24 and always in order: a slot with no row is `ornament: null`
// (empty), never a gap in the list, so a page can render a tree without inventing
// placeholders. `filled` counts the real rows.
export async function treeSlots(db, steamid) {
  await ensureStateSchema(db)
  const sidValue = sid(steamid)
  const rows = await allOn(db,
    `SELECT slot, ornament, moved_at FROM winter_tree WHERE steamid=?1 ORDER BY slot`, [sidValue])
  const bySlot = new Map(rows.map(r => [Number(r.slot), r]))
  const slots = []
  for (let slot = 1; slot <= MAX_TREE_SLOT; slot++) {
    const row = bySlot.get(slot)
    slots.push({
      slot,
      ornament: row ? Number(row.ornament) : null,
      moved_at: row ? Number(row.moved_at || 0) : 0
    })
  }
  return { slots, filled: rows.length, capacity: MAX_TREE_SLOT }
}

// -------------------------------------------------------------- recent ledger --
// The last N currency movements with the balance each one left, newest first. This
// is the page-side view of winter_ledger; the append-only truth itself.
export async function recentLedger(db, steamid, opts) {
  await ensureStateSchema(db)
  const sidValue = sid(steamid)
  const limit = clampLimit(opts && opts.limit, 20, 100)
  const rows = await allOn(db,
    `SELECT id, currency, delta, balance_after, reason, ref, action_id, created_at
       FROM winter_ledger
      WHERE steamid=?1
      ORDER BY id DESC LIMIT ?2`, [sidValue, limit])
  return rows.map(r => ({
    id: Number(r.id),
    currency: r.currency,
    delta: Number(r.delta || 0),
    balance_after: Number(r.balance_after || 0),
    reason: r.reason || "",
    ref: r.ref || "",
    action_id: Number(r.action_id || 0),
    created_at: Number(r.created_at || 0)
  }))
}

// --------------------------------------------------------- the queue, viewed --
// A player's own action rows, newest first — what a page shows as "queued" or
// "done". The game's side of the same rows is pendingActions() in src/state.js.
export async function recentActions(db, steamid, opts) {
  await ensureStateSchema(db)
  const sidValue = sid(steamid)
  const limit = clampLimit(opts && opts.limit, 10, 100)
  const rows = await allOn(db,
    `SELECT id, kind, payload, state, error, result, created_at, applied_at,
            game_state, game_acked_at
       FROM winter_actions
      WHERE steamid=?1
      ORDER BY id DESC LIMIT ?2`, [sidValue, limit])
  return rows.map(r => {
    let payload = {}
    try { payload = JSON.parse(r.payload || "{}") } catch {}
    return {
      action_id: Number(r.id),
      kind: r.kind,
      payload,
      state: r.state,
      error: r.error || "",
      result: parseOrNull(r.result),
      created_at: Number(r.created_at || 0),
      applied_at: Number(r.applied_at || 0),
      game_state: r.game_state || "",
      game_acked_at: Number(r.game_acked_at || 0)
    }
  })
}

function parseOrNull(text) {
  if (text == null || text === "") return null
  try { return JSON.parse(text) } catch { return null }
}

// ------------------------------------------------------------- the shop shelf --
// Page-driven addition (docs/panel/01-DATA.md §11). The catalogue the shop renders:
// `winter_shop` rows, read-only, plus what THIS player already owns so the page can
// show "Owned" instead of a Buy button. One query each — nothing runs in a loop.
//
// A row is returned as it is stored: a kind, the `item`/`product` key the buy action
// carries, a tier (the plate's tab), a rarity, a hidden flag, and a price in both
// currencies. The page decides what to draw; this file decides nothing.
export async function shopCatalog(db, opts) {
  const onlyActive = !(opts && opts.includeInactive)
  const rows = await allOn(db,
    `SELECT sku, kind, item, item_kind, product, name, blurb, tier, rarity, hidden,
            price_coins, price_gingerbread, sort, active, source
       FROM winter_shop
      ${onlyActive ? "WHERE active=1" : ""}
      ORDER BY sort, sku`)
  return rows.map(r => ({
    sku: r.sku,
    kind: r.kind,
    item: r.item || "",
    item_kind: r.item_kind || "",
    product: r.product || "",
    name: r.name || "",
    blurb: r.blurb || "",
    tier: r.tier || "misc",
    rarity: r.rarity || "common",
    hidden: Number(r.hidden || 0) === 1,
    price: { coins: Number(r.price_coins || 0), gingerbread: Number(r.price_gingerbread || 0) },
    sort: Number(r.sort || 0),
    active: Number(r.active || 0) === 1,
    source: r.source || ""
  }))
}

// What this player already owns, in the two shapes a buy can produce: inventory
// item keys with their kind and equipped flag, and entitlement products. A page
// needs both to answer "can this be bought" without a second read.
export async function ownedItems(db, steamid) {
  await ensureStateSchema(db)
  const sidValue = sid(steamid)
  const items = await allOn(db,
    `SELECT item, kind, qty, equipped, acquired_at
       FROM winter_inventory WHERE steamid=?1 ORDER BY acquired_at DESC, item`, [sidValue])
  const products = await allOn(db,
    `SELECT product, source, granted_at
       FROM winter_entitlements WHERE steamid=?1 ORDER BY granted_at DESC, product`, [sidValue])
  return {
    items: items.map(r => ({
      item: r.item,
      kind: r.kind || "cosmetic",
      qty: Number(r.qty || 1),
      equipped: Number(r.equipped || 0) === 1,
      acquired_at: Number(r.acquired_at || 0)
    })),
    products: products.map(r => ({
      product: r.product,
      source: r.source || "",
      granted_at: Number(r.granted_at || 0)
    }))
  }
}

// ------------------------------------------------- the Winter Pass, 30 tiers --
// Page-driven addition (docs/panel/01-DATA.md §11). The ladder is the game's
// `winterfest/pass.ini`, published through the signed push; the panel owns claim
// state only. So this returns the ladder as it was published — ordered, and empty
// when nothing was: a page that gets [] says "not published yet" instead of
// drawing thirty tiers it made up. `unlocked` is decided from the player's own
// pass XP (getPlayer().pass), not from a `pass` reading the panel does not have.
export async function passLadder(db, opts) {
  await ensureStateSchema(db)
  const rows = await allOn(db,
    `SELECT tier, xp, kind, item_id, amount, season, label, source
       FROM winter_pass_tier ORDER BY tier`)
  return rows.map(r => ({
    tier: Number(r.tier),
    xp: Number(r.xp || 0),
    kind: r.kind || "snow",
    item_id: Number(r.item_id || 0),
    amount: Number(r.amount || 0),
    season: r.season || "",
    label: r.label || "",
    source: r.source || ""
  }))
}

// What the player did earn on the pass: the ledger lines the panel wrote when a
// tier was claimed or a reward was paid from one (`reason` is the ledger's own
// label, e.g. "pass-tier-12"). Bounded, newest first — never a guess.
export async function passRewards(db, steamid, opts) {
  await ensureStateSchema(db)
  const sidValue = sid(steamid)
  const limit = clampLimit(opts && opts.limit, 8, 40)
  const rows = await allOn(db,
    `SELECT id, currency, delta, balance_after, reason, ref, created_at
       FROM winter_ledger
      WHERE steamid=?1 AND (reason LIKE 'pass%' OR reason LIKE 'tier%' OR ref LIKE 'pass:%')
      ORDER BY id DESC LIMIT ?2`, [sidValue, limit])
  return rows.map(r => ({
    id: Number(r.id),
    currency: r.currency,
    delta: Number(r.delta || 0),
    balance_after: Number(r.balance_after || 0),
    reason: r.reason || "",
    ref: r.ref || "",
    created_at: Number(r.created_at || 0)
  }))
}

// ------------------------------------------------------- the mission ladder --
// Page-driven addition (§11). Every row of the game's `missions.ini`, as the push
// published it; target variants of one slot are separate rows and the PAGE groups
// them, because which variant a player was rolled is the game's answer, not this
// layer's. Claims are `missionsFor()` above.
export async function missionLadder(db, opts) {
  await ensureStateSchema(db)
  const type = opts && opts.type ? String(opts.type) : ""
  const rows = type
    ? await allOn(db, `SELECT * FROM winter_mission WHERE type=?1 ORDER BY slot, id`, [type])
    : await allOn(db, `SELECT * FROM winter_mission ORDER BY CASE type WHEN 'daily' THEN 0 WHEN 'weekly' THEN 1 ELSE 2 END, slot, id`)
  return rows.map(r => ({
    id: r.id,
    type: r.type || "daily",
    slot: Number(r.slot || 0),
    metric: r.metric || "",
    target: Number(r.target || 0),
    weight: Number(r.weight || 0),
    xp: Number(r.xp || 0),
    coins: Number(r.coins || 0),
    season: r.season || "",
    name: r.name || "",
    blurb: r.blurb || "",
    tags: r.tags || "",
    source: r.source || ""
  }))
}

// -------------------------------------------------- the achievement ladder --
// Page-driven addition (§11). `achievements()` above answers what the panel
// GRANTED; this answers what the game DEFINES. `owned` is joined here so a page
// renders "earned" from the inventory and never from its own memory.
export async function achievementLadder(db, steamid, opts) {
  await ensureStateSchema(db)
  const rows = await allOn(db,
    `SELECT id, name, check_, target, xp, coins, badge, category, season, source
       FROM winter_achievement ORDER BY category, id`)
  let owned = new Set()
  if (steamid) {
    const sidValue = sid(steamid)
    for (const r of await allOn(db,
      `SELECT item FROM winter_inventory WHERE steamid=?1 AND kind IN ('title','badge')`, [sidValue])) {
      owned.add(String(r.item))
    }
  }
  return rows.map(r => ({
    id: r.id,
    name: r.name || "",
    check: r.check_ || "",
    target: Number(r.target || 0),
    xp: Number(r.xp || 0),
    coins: Number(r.coins || 0),
    badge: r.badge || "",
    category: r.category || "special",
    season: r.season || "",
    source: r.source || "",
    // The badge is stored under the achievement id; a title under its set id.
    owned: owned.has(String(r.id)) || owned.has(String(r.badge))
  }))
}

// The daily-login streak the GAME paid (winter_login, §11): the day of the last
// paid login and the run of consecutive days. Null means the game never reported
// one — which the Missions page prints as "not reported", never as 0 days.
export async function loginStreak(db, steamid) {
  await ensureStateSchema(db)
  const sidValue = sid(steamid)
  const row = await allOn(db,
    `SELECT last_day, streak, seen_at FROM winter_login WHERE steamid=?1 LIMIT 1`, [sidValue])
  const r = row[0]
  if (!r) return null
  return { last_day: r.last_day || "", streak: Number(r.streak || 0), seen_at: Number(r.seen_at || 0) }
}

// The player's own queue rows of ONE kind, newest first — what a page prints in a
// "pending" strip or a purchase history. `kind` is bound, never interpolated.
export async function actionsOfKind(db, steamid, kind, opts) {
  await ensureStateSchema(db)
  const sidValue = sid(steamid)
  const limit = clampLimit(opts && opts.limit, 12, 100)
  const k = String(kind || "")
  const rows = await allOn(db,
    `SELECT id, kind, payload, state, idem, error, result, created_at, applied_at, game_acked_at
       FROM winter_actions
      WHERE steamid=?1 AND kind=?2
      ORDER BY id DESC LIMIT ?3`, [sidValue, k, limit])
  return rows.map(r => ({
    action_id: Number(r.id),
    kind: r.kind,
    payload: parseOrNull(r.payload) || {},
    state: r.state,
    idem: r.idem || "",
    error: r.error || "",
    result: parseOrNull(r.result),
    created_at: Number(r.created_at || 0),
    applied_at: Number(r.applied_at || 0),
    game_acked_at: Number(r.game_acked_at || 0)
  }))
}

// ============================================================================
// Profile, Rankstats and Top 15 (docs/panel/01-DATA.md §11, "page-driven
// additions"). Read-only, parameterised, one statement each unless a page needs
// two facts that cannot be answered by one — and nothing here writes.
//
// Every helper returns `null` (or an empty list) for a value the schema has no
// source for. That is the page's "not collected" verdict, and it is the only
// honest answer: a zero that means "unknown" is a bug (contract §Rules).
// ============================================================================

// ---------------------------------------------------------------- presence --
// Is this steamid on the game server RIGHT NOW?
//
// freenova_sync.sma pushes only the players inside the game loop, and it stamps
// players.last_seen with the snapshot clock (fnweb_interval, 30 s by default) for
// every one of them, whether they have played a round or not. So "the newest
// snapshot is fresh" plus "this row was stamped by it" is exactly "in the loop".
// What it deliberately does NOT prove: that the player is at the keyboard -
// nothing does, and the page must not say so.
//
// A panel that has never been pushed to (an empty `meta` clock) knows nothing
// and answers null, not "offline": unknown and absent are different claims.
// PRESENCE_FRESH_SEC is generous on purpose (three push intervals plus a whole
// minute of slack), so a busy server or a slow relay cannot flicker a player
// offline between two pushes.
export const PRESENCE_FRESH_SEC = 150

export async function presence(db, steamid, opts) {
  await ensureStateSchema(db)
  const sidValue = sid(steamid)
  const now = Math.trunc(Number(opts && opts.now)) || Math.floor(Date.now() / 1000)
  const fresh = Math.trunc(Number(opts && opts.fresh)) || PRESENCE_FRESH_SEC
  const clock = await allOn(db, `SELECT value FROM meta WHERE key='last_push'`)
  const pushedAt = Number((clock[0] && clock[0].value) || 0)
  const row = await allOn(db, `SELECT last_seen, hits_at FROM players WHERE steamid=?1`, [sidValue])
  if (!clock.length || pushedAt <= 0) return { known: false, online: null, pushed_at: 0, last_seen: 0 }
  const lastSeen = Number((row[0] && row[0].last_seen) || 0)
  const hitsAt = Number((row[0] && row[0].hits_at) || 0)
  const serverUp = now - pushedAt <= fresh
  // A row stamped by a snapshot that has itself gone stale is not presence either:
  // both clocks must be inside the window, and they must BE the same snapshot.
  const stamped = hitsAt > 0 && Math.abs(pushedAt - hitsAt) <= 5
  return { known: true, online: serverUp && stamped, pushed_at: pushedAt, last_seen: lastSeen, hits_at: hitsAt }
}

// -------------------------------------------------------------- rank history --
// Lifetime rank and the player directly above, for the "next rank" card.
// `rating_x100` is the game's own season score (computed once game-side and
// pushed), so this is a real standing, not a derived guess.
export async function rankStanding(db, steamid) {
  await ensureStateSchema(db)
  const sidValue = sid(steamid)
  const me = await allOn(db, `SELECT xp, rating_x100, rank_id, level FROM players WHERE steamid=?1`, [sidValue])
  if (!me.length) return null
  const xp = Number(me[0].xp || 0)
  if (xp <= 0) return { rank: null, xp, above: null, behind: 0, rating_x100: Number(me[0].rating_x100 || 0) }
  const above = await allOn(db,
    `SELECT steamid, name, xp FROM players WHERE xp > ?1 ORDER BY xp ASC, steamid ASC LIMIT 1`, [xp])
  const ahead = await allOn(db, `SELECT COUNT(*) AS n FROM players WHERE xp > ?1`, [xp])
  return {
    rank: Number((ahead[0] && ahead[0].n) || 0) + 1,
    xp,
    rating_x100: Number(me[0].rating_x100 || 0),
    above: above.length
      ? { steamid: String(above[0].steamid || ""), name: String(above[0].name || ""), xp: Number(above[0].xp || 0) }
      : null,
    behind: above.length ? Math.max(0, Number(above[0].xp || 0) - xp) : 0
  }
}

// ------------------------------------------------------------- weapon stats --
// Per-slot career totals plus accuracy, for the "Top Weapons" card. `slot` is
// freenova_wpn.inc's index; the NAME of a slot is the game's vocabulary, so it
// is not invented here - the caller passes the table it already has (ui.js
// WEAPONS) and this helper returns the slot and the numbers only.
//
// Accuracy is hits/shots, and the schema holds `shots` per PLAYER, not per
// weapon, so this helper reports no accuracy at all rather than dividing a
// weapon's hits by the whole account's shots.
export async function weaponStats(db, steamid, opts) {
  await ensureStateSchema(db)
  const sidValue = sid(steamid)
  const limit = clampLimit(opts && opts.limit, 10, 25)
  const rows = await allOn(db,
    `SELECT slot, kills, hs, damage FROM player_weapons
      WHERE steamid=?1 AND kills > 0 ORDER BY kills DESC, slot ASC LIMIT ?2`, [sidValue, limit])
  return rows.map(r => ({
    slot: Number(r.slot),
    kills: Number(r.kills || 0),
    hs: Number(r.hs || 0),
    hs_pct: Number(r.kills || 0) > 0 ? Number(r.hs || 0) / Number(r.kills) : null,
    damage: Number(r.damage || 0)
  }))
}

// ---------------------------------------------------------------- map stats --
// Per-map career, for "Top Maps" and the map tab. The game pushes player_maps
// only when freenova_sync reports a map block; an empty list therefore means
// "the panel has no per-map record", which the page prints as such.
export async function mapStats(db, steamid, opts) {
  await ensureStateSchema(db)
  const sidValue = sid(steamid)
  const limit = clampLimit(opts && opts.limit, 20, 100)
  const rows = await allOn(db,
    `SELECT map_name, matches, wins, losses, kills, deaths, assists, headshots, damage, last_played
       FROM player_maps WHERE steamid=?1
      ORDER BY matches DESC, map_name ASC LIMIT ?2`, [sidValue, limit])
  return rows.map(r => {
    const wins = Number(r.wins || 0), losses = Number(r.losses || 0)
    const decided = wins + losses > 0 ? wins + losses : 0
    return {
      map: String(r.map_name || ""),
      matches: Number(r.matches || 0),
      wins, losses,
      kills: Number(r.kills || 0),
      deaths: Number(r.deaths || 0),
      assists: Number(r.assists || 0),
      headshots: Number(r.headshots || 0),
      damage: Number(r.damage || 0),
      last_played: Number(r.last_played || 0),
      // A winrate is decided matches, not played rows: a row with no decided
      // result has no winrate at all (null), not 0%.
      winrate: decided ? wins / decided : null
    }
  })
}

// ------------------------------------------------------------- season history --
// The competitive seasons the game has pushed (comp_history), newest first.
export async function seasonHistory(db, steamid, opts) {
  await ensureStateSchema(db)
  const sidValue = sid(steamid)
  const limit = clampLimit(opts && opts.limit, 12, 36)
  const rows = await allOn(db,
    `SELECT season, points, kills, hs, wins, mvp FROM comp_history
      WHERE steamid=?1 ORDER BY season DESC LIMIT ?2`, [sidValue, limit])
  return rows.map(r => ({
    season: String(r.season || ""),
    points: Number(r.points || 0),
    kills: Number(r.kills || 0),
    hs: Number(r.hs || 0),
    wins: Number(r.wins || 0),
    mvp: Number(r.mvp || 0)
  }))
}

// ------------------------------------------------------------- the T ----

// A player's own Top-15 standing on the XP board, whether or not they are in
// the 15 rows a board page shows. One board, the same ORDER BY as
// boards.js lifetimeBoard (players.xp), so the two can never disagree.
export async function myPlacement(db, steamid) {
  await ensureStateSchema(db)
  const sidValue = sid(steamid)
  const me = await allOn(db, `SELECT name, xp FROM players WHERE steamid=?1`, [sidValue])
  if (!me.length) return { known: false, rank: null, xp: null, name: "", total: 0 }
  const xp = Number(me[0].xp || 0)
  const ahead = await allOn(db, `SELECT COUNT(*) AS n FROM players WHERE xp > ?1`, [xp])
  const total = await allOn(db, `SELECT COUNT(*) AS n FROM players WHERE xp > 0`)
  return {
    known: true,
    rank: xp > 0 ? Number((ahead[0] && ahead[0].n) || 0) + 1 : null,
    xp,
    name: String(me[0].name || ""),
    total: Number((total[0] && total[0].n) || 0)
  }
}

// ------------------------------------------------------- owner-of-the-place --
// Whether a place on the board is still occupied by the same steamid: the
// rewards card promises something "at the end of the season", so the page can
// only say who holds place N right now.
export async function boardPlacings(db, opts) {
  await ensureStateSchema(db)
  const limit = clampLimit(opts && opts.limit, 15, 15)
  const board = (opts && opts.metric) === "kills"
    ? `SELECT steamid, name, kills AS value, level, cc FROM players WHERE kills > 0 ORDER BY kills DESC, steamid ASC LIMIT ?1`
    : `SELECT steamid, name, xp AS value, level, cc FROM players WHERE xp > 0 ORDER BY xp DESC, steamid ASC LIMIT ?1`
  const rows = await allOn(db, board, [limit])
  return rows.map((r, i) => ({
    rank: i + 1,
    steamid: String(r.steamid || ""),
    name: String(r.name || ""),
    value: Number(r.value || 0),
    level: Number(r.level || 0),
    cc: String(r.cc || "")
  }))
}

// ------------------------------------------------------------- achievements --
// The newest lifetime achievements the panel has a date for (ap_unlocks, filled
// by the ingest when ach_unlocked gains a bit). The page names a code from its
// own table; a code it cannot name is skipped rather than printed raw.
export async function recentUnlocks(db, steamid, opts) {
  await ensureStateSchema(db)
  const sidValue = sid(steamid)
  const limit = clampLimit(opts && opts.limit, 8, 24)
  const rows = await allOn(db,
    `SELECT code, ap, earned_at FROM ap_unlocks
      WHERE steamid=?1 ORDER BY earned_at DESC, code ASC LIMIT ?2`, [sidValue, limit])
  return rows.map(r => ({ code: String(r.code || ""), ap: Number(r.ap || 0), earned_at: Number(r.earned_at || 0) }))
}

// ------------------------------------------------------------------ medals --
// The badge the player holds for a settled weekly/monthly board (boards.js),
// newest first. Empty = no settled champion badge for this player yet.
export async function badgeHoldings(db, steamid, opts) {
  await ensureStateSchema(db)
  const sidValue = sid(steamid)
  const limit = clampLimit(opts && opts.limit, 6, 24)
  const rows = await allOn(db,
    `SELECT kind, period, label, awarded_at FROM badges
      WHERE steamid=?1 ORDER BY awarded_at DESC LIMIT ?2`, [sidValue, limit])
  return rows.map(r => ({
    kind: String(r.kind || ""),
    period: String(r.period || ""),
    label: String(r.label || ""),
    awarded_at: Number(r.awarded_at || 0)
  }))
}

// ------------------------------------------------------------- slot picks --
// ------------------------------------------------------------- slot picks --
// Rarity rank of an owned ornament, read from winter_ornaments.rarity (the
// column the game fills when it grants one). An item whose row carries no rarity
// is null - not "common", which would be a claim the panel cannot make.
function rarestOf(rows) {
  let best = null
  for (const r of rows) {
    if ((r.kind || "") !== "ornament") continue
    const n = r.rarity == null ? null : Number(r.rarity)
    if (n == null || !Number.isFinite(n)) continue
    if (!best || n > best.rarity) best = { item: r.item, rarity: n }
  }
  return best
}

// The two cosmetics a profile shows large: the equipped frame and the equipped
// badge/title, straight from what the panel granted and the player equipped.
export async function equippedCosmetics(db, steamid) {
  await ensureStateSchema(db)
  const sidValue = sid(steamid)
  const rows = await allOn(db,
    // A frame is left out of the query entirely: state.js ITEM_KINDS has no
    // "frame" kind, so nothing can be equipped as one (see below). No join
    // whether a column exists: the page asks for facts, not for schema.
    `SELECT item, kind, equipped FROM winter_inventory
      WHERE steamid=?1 ORDER BY equipped DESC, acquired_at DESC, item`, [sidValue])
  const first = k => rows.find(r => (r.kind || "") === k && Number(r.equipped || 0) === 1) || null
  return {
    title: first("title"),
    badge: first("badge"),
    // state.js ITEM_KINDS has no "frame": the panel's frame vocabulary does not
    // exist yet, so no frame is EVER reported here - the page draws the plate's
    // empty frame and says it holds nothing. A column that could only ever be
    // null is not a feature, and inventing the kind would be worse.
    frame: null,
    model: first("model"),
    counts: { all: rows.length, equipped: rows.filter(r => Number(r.equipped || 0) === 1).length }
  }
}

// The rarest ornament a player HOLDS, for the profile's "rarest find".
// The panel's own copy of "which ornament is rare" is the ornament's id from
// configs/freenova/winterfest/ornaments.ini, where rarer pieces carry the higher
// ids; no rarity column is mirrored in this schema today (winter_ornaments is
// steamid/ornament/obtained_at/source), so this reports the highest ornament id
// and the page names the tier from that id - never a rarity it was not told.
export async function rarestOrnament(db, steamid) {
  await ensureStateSchema(db)
  const sidValue = sid(steamid)
  const rows = await allOn(db,
    `SELECT ornament, obtained_at, source FROM winter_ornaments
      WHERE steamid=?1 ORDER BY ornament DESC LIMIT 1`, [sidValue])
  if (!rows.length) return null
  return {
    ornament: Number(rows[0].ornament),
    obtained_at: Number(rows[0].obtained_at || 0),
    source: String(rows[0].source || "")
  }
}
