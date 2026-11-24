// FreeNova panel — the Winterfest state layer: THE ONLY WRITER of player state.
//
// Contract: docs/panel/00-CONTRACT.md (owner decision 2026-11-22), column list and
// kind vocabulary: docs/panel/01-DATA.md.
//
//   panel page        reads  → src/query.js (read-only)
//   panel action      writes → winter_actions            (queueAction, never a state table)
//   apply step        writes → state tables + winter_ledger, in ONE transaction (applyAction)
//   game pull         reads  → GET  /api/game/pending     (pendingActions)
//   game reports back writes → POST /api/game/ack         (ackAction)
//
// Four rules, and everything below exists to keep them:
//
//  1. NOBODY ELSE WRITES. Every column this module touches is written here and
//     nowhere else: no page UPDATEs a state table, and the game's signed snapshot
//     push does not write winter_players / winter_inventory / winter_entitlements /
//     winter_ledger / winter_actions at all (see the ingest note in 01-DATA.md).
//  2. EVERY CURRENCY CHANGE WRITES A LEDGER ROW with `balance_after`, in the same
//     transaction as the balance itself. addCurrency() is the only function that
//     moves coins / gingerbread / spins, so a balance without its ledger row is
//     not expressible through this API.
//  3. IDEMPOTENT. winter_actions has UNIQUE (steamid, kind, idem) — a refreshed
//     page, a double-clicked button or a retried claim can only ever create ONE
//     row — and applyAction() only applies a row whose state is still 'pending',
//     so applying twice returns the first verdict and pays once.
//  4. A REFUSAL WRITES NOTHING. Validation happens before the first write and a
//     refusal inside the transaction rolls the whole action back; the row is then
//     marked 'refused' outside it, with the reason, and the balances are untouched.
//
// WHAT THE PANEL OWNS vs WHAT THE GAME STILL OVERWRITES
//   panel-owned (no ingest writer): winter_players.*, winter_inventory,
//     winter_entitlements, winter_ledger, winter_actions, pass xp/tier, spins,
//     gingerbread (winter_players.snowflakes).
//   STILL GAME-OWNED: players.xp / players.level / players.rank_id and — the one
//     real overlap left — players.coins, which the ingest upserts on every push.
//     So the panel can pay coins and record the ledger row, but the next signed
//     snapshot re-states coins from the game. That is deliberate for now (the game
//     is still the spender for coins) and it is why rebuildBalance() is exact for
//     gingerbread and spins and only advisory for coins. 01-DATA.md says the same
//     thing where the AMXX side will read it.
//
// LANDMINE: schema.sql is exec'd on every boot and ADD COLUMN is not idempotent,
// so the four columns winter_players gained are added here by a guarded ALTER
// (PRAGMA table_info first). ensureStateSchema() is lazy and memoised per DB
// object, the same pattern as src/boards.js — do not move it to boot only.

// The owner's advent date law lives in exactly one place (src/panel/advent.js);
// this layer only enforces it, at apply time, inside the transaction.
// The advent calendar's clock and its date law, moved to src/periods.js: the
// page (src/panel/advent.js) and this apply step must read ONE implementation,
// and state.js must not import a page for it.
import { adventClock, claimRefusal } from "./panel/advent.js"

export const SEASON = "2026"                 // one season per Winterfest; a rollover changes this one line
export const MAX_TREE_SLOT = 24
export const MAX_ADVENT_DAY = 24
export const PASS_MAX_TIER = 30
export const PREMIUM_PRODUCT = "bp_premium_2026"
export const ADVENT_PRODUCT = "advent_pass_2026"

export const ACTION_KINDS = Object.freeze([
  "claim_mission", "claim_advent", "plant_ornament", "place_ornament", "buy", "equip", "grant", "spin"
])

// The Spin Wheel's table IS the game's table — never a second one.
//
// The wheel a player sees in game is configs/freenova/winterfest/spin.ini [sector]
// (winterfest_spin.amxx reads it), and the same file is the panel's source of the
// odds: ten wedges, in file order = wheel order, weights sum to 100:
//
//   Nothing 12 | 5 GingerBread 20 | 15 GingerBread 18 | 25 Coins 12 | 75 Coins 10
//   1 Extra Spin 8 | Common Present 9 | Mystery Ornament 6 | Collector Title 3
//   Rare Present 2                                              (71/24/5 common/uncommon/rare)
//
// THE PANEL CANNOT DELIVER THREE OF THEM, and says so instead of inventing:
//   gift     present.sma opens a present in GAME (pickup + open). A panel row has
//            no present to hand to the game — the pull's reward fields are
//            coins/gingerbread/spins/pass_xp/item/product — so "Common Present"
//            and "Rare Present" are not wedges the page can land on.
//   ornament pays "a random ornament you do not own yet". The panel would have to
//            pick one at apply time, which reads ownership inside the transaction;
//            left out until that selection lives in one place.
// A spin whose sector WOULD have been one of those is a `Nothing` (the table's own
// 12 % gap) and the page's spin history prints it as "Nothing (the wheel stopped
// on one of the three prizes this page cannot deliver)". Nothing is silently
// upgraded to a prize, and nothing is silently lost.
//
// `weight` is the game's weight, unchanged. `none: true` is the gap.
export const SPIN_WHEEL = Object.freeze([
  { key: "nothing", label: "Nothing", weight: 12, rarity: "common", none: true },
  { key: "gb5", label: "5 GingerBread", weight: 20, rarity: "common", reward: { gingerbread: 5 } },
  { key: "gb15", label: "15 GingerBread", weight: 18, rarity: "common", reward: { gingerbread: 15 } },
  { key: "coins25", label: "25 Coins", weight: 12, rarity: "common", reward: { coins: 25 } },
  { key: "coins75", label: "75 Coins", weight: 10, rarity: "uncommon", reward: { coins: 75 } },
  { key: "spin1", label: "1 Extra Spin", weight: 8, rarity: "uncommon", reward: { spins: 1 } },
  { key: "nothing", label: "Nothing (a present — the page cannot open one)", weight: 9, rarity: "common", none: true },
  { key: "nothing", label: "Nothing (a mystery ornament — chosen in game only)", weight: 6, rarity: "uncommon", none: true },
  { key: "title6", label: "Collector Title", weight: 3, rarity: "rare",
    reward: { item: "title:6", item_kind: "title" } },
  { key: "nothing", label: "Nothing (a rare present — the page cannot open one)", weight: 2, rarity: "rare", none: true }
])

/** The wheel's weight table as integer shares — the game's own integers. */
export function spinTickets() {
  return SPIN_WHEEL.map((p, i) => ({ i, n: Math.round(p.weight) }))
}

/** The wedge an action id lands on — deterministic, and the ONLY place a prize is
 *  chosen. Rendering the page again cannot reroll it, and two rows never share a
 *  landing by anything but the weights. */
export function spinWedge(actionId) {
  const tickets = spinTickets()
  const total = tickets.reduce((a, t) => a + t.n, 0)
  let x = ((Math.trunc(Number(actionId) || 0) * 2654435761) >>> 0) % total
  for (const t of tickets) {
    if (x < t.n) return SPIN_WHEEL[t.i]
    x -= t.n
  }
  return SPIN_WHEEL[0]
}

export const ENTITLEMENTS = Object.freeze([PREMIUM_PRODUCT, ADVENT_PRODUCT])
export const ITEM_KINDS = Object.freeze(["ornament", "title", "model", "skin", "badge", "cosmetic"])

// ------------------------------------------------------------------ refusals --
// A refusal is a verdict, not a crash: it carries the sentence the panel and the
// game both get to show the player ("not enough gingerbread"), and it is the only
// way out of an apply that writes nothing.
export class Refusal extends Error {
  constructor(reason) {
    super(String(reason || "refused"))
    this.name = "Refusal"
    this.reason = String(reason || "refused")
  }
}

// --------------------------------------------------------------- pass curve --
// The Winter Pass ladder as the season defines it (winterfest/pass.ini): 30
// tiers, FREE TRACK ONLY, tier 1 at 0 XP (the welcome reward). Steps are 300 XP
// for tiers 2-10, 700 for 11-20, 1400 for 21-30 — that is the documented pacing,
// so the panel derives tier from cumulative XP here instead of trusting a number
// in a payload. Kept deliberately small and pure so the harness can prove it.
export function passTierXp(tier) {
  const t = Math.max(1, Math.min(PASS_MAX_TIER, Math.trunc(Number(tier) || 1)))
  if (t <= 1) return 0
  if (t <= 10) return 300 * (t - 1)
  if (t <= 20) return 2700 + 700 * (t - 10)
  return 9700 + 1400 * (t - 20)
}

export function passTierFromXp(xp) {
  const n = Math.max(0, Math.trunc(Number(xp) || 0))
  let tier = 1
  for (let t = 2; t <= PASS_MAX_TIER; t++) {
    if (n < passTierXp(t)) break
    tier = t
  }
  return tier
}

// ------------------------------------------------------------------- schema --
// The same DDL as schema.sql, repeated lazily: a deployment that never execs that
// file still gets these tables the first time an action is queued (the pattern
// src/boards.js and src/register.js already use). Every statement is IF NOT EXISTS
// so running it over the live database only creates what is missing.
const STATE_DDL = [
  // Full definition INCLUDING the four contract columns, so a database created by
  // this module alone has them. A live table gets them via WINTER_COLUMNS below.
  `CREATE TABLE IF NOT EXISTS winter_players (
      steamid          TEXT PRIMARY KEY,
      season           TEXT NOT NULL DEFAULT '',
      snowflakes       INTEGER NOT NULL DEFAULT 0,
      spins            INTEGER NOT NULL DEFAULT 0,
      gifts_found      INTEGER NOT NULL DEFAULT 0,
      tree_style       INTEGER NOT NULL DEFAULT 1,
      tree_level       INTEGER NOT NULL DEFAULT 0,
      ornaments_total  INTEGER NOT NULL DEFAULT 0,
      advent_claimed   INTEGER NOT NULL DEFAULT 0,
      pass_xp          INTEGER NOT NULL DEFAULT 0,
      pass_tier        INTEGER NOT NULL DEFAULT 1,
      premium          INTEGER NOT NULL DEFAULT 0,
      seen_at          INTEGER NOT NULL DEFAULT 0)`,
  `CREATE TABLE IF NOT EXISTS winter_actions (
      id            INTEGER PRIMARY KEY AUTOINCREMENT,
      steamid       TEXT NOT NULL,
      kind          TEXT NOT NULL,
      payload       TEXT NOT NULL DEFAULT '{}',
      state         TEXT NOT NULL DEFAULT 'pending',
      idem          TEXT NOT NULL,
      created_at    INTEGER NOT NULL DEFAULT 0,
      applied_at    INTEGER NOT NULL DEFAULT 0,
      error         TEXT NOT NULL DEFAULT '',
      result        TEXT NOT NULL DEFAULT '',
      game_state    TEXT NOT NULL DEFAULT '',
      game_error    TEXT NOT NULL DEFAULT '',
      game_acked_at INTEGER NOT NULL DEFAULT 0,
      UNIQUE (steamid, kind, idem))`,
  `CREATE INDEX IF NOT EXISTS idx_winter_actions_queue ON winter_actions (steamid, game_acked_at, id)`,
  `CREATE INDEX IF NOT EXISTS idx_winter_actions_state ON winter_actions (state, id)`,
  `CREATE TABLE IF NOT EXISTS winter_ledger (
      id            INTEGER PRIMARY KEY AUTOINCREMENT,
      steamid       TEXT NOT NULL,
      currency      TEXT NOT NULL,
      delta         INTEGER NOT NULL,
      balance_after INTEGER NOT NULL,
      reason        TEXT NOT NULL DEFAULT '',
      ref           TEXT NOT NULL DEFAULT '',
      action_id     INTEGER NOT NULL DEFAULT 0,
      created_at    INTEGER NOT NULL DEFAULT 0)`,
  `CREATE INDEX IF NOT EXISTS idx_winter_ledger_player ON winter_ledger (steamid, id DESC)`,
  `CREATE INDEX IF NOT EXISTS idx_winter_ledger_action ON winter_ledger (action_id)`,
  `CREATE TABLE IF NOT EXISTS winter_entitlements (
      steamid    TEXT NOT NULL,
      product    TEXT NOT NULL,
      source     TEXT NOT NULL DEFAULT '',
      granted_at INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY (steamid, product))`,
  `CREATE TABLE IF NOT EXISTS winter_inventory (
      steamid     TEXT NOT NULL,
      item        TEXT NOT NULL,
      kind        TEXT NOT NULL DEFAULT 'cosmetic',
      qty         INTEGER NOT NULL DEFAULT 1,
      equipped    INTEGER NOT NULL DEFAULT 0,
      acquired_at INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY (steamid, item))`,
  `CREATE INDEX IF NOT EXISTS idx_winter_inventory_player ON winter_inventory (steamid, kind, equipped)`,
  // The other winter tables this layer writes. They are in schema.sql too; a
  // boot that never exec'd it still needs them before the first apply.
  `CREATE TABLE IF NOT EXISTS winter_tree (
      steamid    TEXT NOT NULL,
      slot       INTEGER NOT NULL,
      ornament   INTEGER NOT NULL,
      moved_at   INTEGER NOT NULL DEFAULT 0,
      PRIMARY KEY (steamid, slot))`,
  `CREATE UNIQUE INDEX IF NOT EXISTS idx_winter_tree_ornament ON winter_tree (steamid, ornament)`,
  `CREATE TABLE IF NOT EXISTS winter_advent (
      steamid    TEXT NOT NULL,
      season     TEXT NOT NULL DEFAULT '',
      day        INTEGER NOT NULL,
      claimed_at INTEGER NOT NULL DEFAULT 0,
      claim_key  TEXT NOT NULL DEFAULT '',
      PRIMARY KEY (steamid, season, day))`,
  // Read by getPlayer() (unread count) and src/query.js (the inbox). Nothing in
  // this layer writes it: mail is staff-authored through /admin.
  `CREATE TABLE IF NOT EXISTS winter_mail (
      id          INTEGER PRIMARY KEY AUTOINCREMENT,
      steamid     TEXT NOT NULL,
      kind        TEXT NOT NULL DEFAULT 'system',
      title       TEXT NOT NULL DEFAULT '',
      body        TEXT NOT NULL DEFAULT '',
      created_at  INTEGER NOT NULL DEFAULT 0,
      read_at     INTEGER NOT NULL DEFAULT 0,
      expires_at  INTEGER NOT NULL DEFAULT 0,
      payload     TEXT NOT NULL DEFAULT '')`,
  `CREATE INDEX IF NOT EXISTS idx_winter_mail_inbox ON winter_mail (steamid, created_at DESC)`
]

// The guarded ALTER: columns winter_players gained for the contract. Names and
// DDL come from this frozen list, never from a caller, so the interpolation into
// the ALTER statement cannot carry user input.
const WINTER_COLUMNS = [
  ["spins", "INTEGER NOT NULL DEFAULT 0"],
  ["pass_xp", "INTEGER NOT NULL DEFAULT 0"],
  ["pass_tier", "INTEGER NOT NULL DEFAULT 1"],
  ["premium", "INTEGER NOT NULL DEFAULT 0"],
  ["tree_level", "INTEGER NOT NULL DEFAULT 0"]     // in the baseline CREATE already; guarded for an older table
]

// One migration per DB object, memoised on the promise so two concurrent first
// calls cannot run the ALTER twice.
const migrated = new WeakMap()

export function ensureStateSchema(db) {
  if (!db || typeof db.prepare !== "function") return Promise.reject(new Refusal("no database"))
  let p = migrated.get(db)
  if (!p) {
    p = migrateStateSchema(db).catch(e => { migrated.delete(db); throw e })
    migrated.set(db, p)
  }
  return p
}

async function migrateStateSchema(db) {
  const raw = db.raw && typeof db.raw.exec === "function" ? db.raw : null
  for (const sql of STATE_DDL) {
    if (raw) raw.exec(sql)
    else await db.prepare(sql).run()
  }
  const info = await db.prepare("PRAGMA table_info(winter_players)").all()
  const have = new Set(((info && info.results) || []).map(r => r.name))
  for (const [name, ddl] of WINTER_COLUMNS) {
    if (have.has(name)) continue
    await db.prepare(`ALTER TABLE winter_players ADD COLUMN ${name} ${ddl}`).run()
  }
  // Page-driven addition (docs/panel/01-DATA.md §11): players.hits_at, the
  // snapshot that last stamped a row (src/sync.js writes it beside last_seen).
  // Same guarded pattern as the columns above - PRAGMA first, ALTER only when
  // the column is missing - so a live database gains it once and never twice.
  const pInfo = await db.prepare("PRAGMA table_info(players)").all()
  const pHave = new Set(((pInfo && pInfo.results) || []).map(r => r.name))
  if (pHave.size && !pHave.has("hits_at")) {
    await db.prepare(`ALTER TABLE players ADD COLUMN hits_at INTEGER NOT NULL DEFAULT 0`).run()
  }
  return true
}

// --------------------------------------------------------------- db helpers --
async function firstOn(db, sql, params) {
  const row = await db.prepare(sql).bind(...(params || [])).first()
  return row == null ? null : row
}

async function allOn(db, sql, params) {
  const res = await db.prepare(sql).bind(...(params || [])).all()
  return (res && res.results) || []
}

async function runOn(db, sql, params) {
  return db.prepare(sql).bind(...(params || [])).run()
}

function changesOf(res) {
  return res && res.meta ? Number(res.meta.changes || 0) : 0
}

// One apply is one transaction. Two drivers, one interface:
//
//   local runner (server_local.mjs → src/sqlite_d1.js) exposes `raw`, a real
//   node:sqlite handle, so this is an interactive BEGIN IMMEDIATE … COMMIT and
//   every read inside `fn` sees the uncommitted writes.
//
//   A Cloudflare D1 binding has no interactive transaction. There the reads run
//   immediately and the writes are collected and handed to db.batch(), which D1
//   documents as the all-or-nothing unit; a throw before the flush writes nothing
//   (that is the refusal path). Applies are serialised per isolate so two of them
//   cannot interleave between the read and the batch.
//
// Do not call this from inside fn (no nesting) and do not read a value back after
// writing it in the same fn on the D1 path — the queued write has not run yet.
function hasInteractiveTx(db) {
  return !!(db && db.raw && typeof db.raw.exec === "function")
}

let solo = Promise.resolve()      // serialises the batch (D1) path only

export function withTransaction(db, fn) {
  if (hasInteractiveTx(db)) return localTransaction(db, fn)
  const mine = solo.then(() => batchTransaction(db, fn))
  solo = mine.then(() => {}, () => {})
  return mine
}

async function localTransaction(db, fn) {
  const raw = db.raw
  const tx = {
    first: (sql, params) => firstOn(db, sql, params),
    all: (sql, params) => allOn(db, sql, params),
    run: (sql, params) => runOn(db, sql, params)
  }
  raw.exec("BEGIN IMMEDIATE")                     // >>> transaction opens
  try {
    const out = await fn(tx)
    raw.exec("COMMIT")                            // >>> transaction commits
    return out
  } catch (e) {
    try { raw.exec("ROLLBACK") } catch {}
    throw e
  }
}

async function batchTransaction(db, fn) {
  const queued = []
  const tx = {
    first: (sql, params) => firstOn(db, sql, params),
    all: (sql, params) => allOn(db, sql, params),
    run: (sql, params) => {
      queued.push(db.prepare(sql).bind(...(params || [])))
      return Promise.resolve({ queued: true })
    }
  }
  const out = await fn(tx)                        // a throw here writes nothing
  if (queued.length) await db.batch(queued)       // >>> the all-or-nothing write
  return out
}

// ------------------------------------------------------------------ clock ----
export function nowSec() { return Math.floor(Date.now() / 1000) }

function nowOf(opt) {
  const n = Math.trunc(Number(opt))
  return Number.isFinite(n) && n > 0 ? n : nowSec()
}

// ------------------------------------------------------------- identities ----
// Same shape the ingest accepts, so a steamid that works on one endpoint works on
// the other. "PENDING" (an unauthenticated client) is refused: it would be a
// shadow row, not a player.
export function validSteamid(s) {
  return typeof s === "string" && /^STEAM_[0-9]:[0-9]:\d+$/.test(s)
}

const KEY_TEXT = /^[A-Za-z0-9_][A-Za-z0-9_.:-]{0,39}$/     // mission ids, reason words
const KEY_ITEM = /^[a-z][a-z0-9_]{0,15}:[A-Za-z0-9_.-]{1,40}$/   // ornament:12, title:3, model:snowman
const KEY_IDEM = /^[A-Za-z0-9_][A-Za-z0-9_.:-]{0,63}$/

async function sha256Hex(text) {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text))
  return [...new Uint8Array(digest)].map(b => b.toString(16).padStart(2, "0")).join("")
}

// --------------------------------------------------------- payload contract --
// A payload is a small JSON object, validated field by field. What is stored is
// the NORMALISED object, never the caller's bytes, so every consumer downstream
// (the apply step, the game's pull) sees the same shape and only known fields.
function parsePayload(raw) {
  if (raw == null) return {}
  if (typeof raw === "string") {
    if (raw.length > 2000) throw new Refusal("payload too large")
    let parsed
    try { parsed = JSON.parse(raw) } catch { throw new Refusal("payload is not valid JSON") }
    return parsePayload(parsed)
  }
  if (typeof raw !== "object" || Array.isArray(raw)) throw new Refusal("payload must be an object")
  if (JSON.stringify(raw).length > 2000) throw new Refusal("payload too large")
  return raw
}

function intField(p, name, min, max) {
  const v = p[name]
  if (v == null) return null
  if (typeof v !== "number" || !Number.isInteger(v)) throw new Refusal(`${name} must be an integer`)
  if (v < min || v > max) throw new Refusal(`${name} out of range (${min}..${max})`)
  return v
}

function keyField(p, name, pattern, label) {
  const v = p[name]
  if (v == null || v === "") return null
  const s = String(v)
  if (s.length > 64 || !pattern.test(s)) throw new Refusal(`bad ${label || name}`)
  return s
}

const REWARD_LIMITS = {
  coins: [0, 1000000],
  gingerbread: [0, 1000000],
  spins: [0, 100],
  pass_xp: [0, 50000]
}

// The reward block shared by claim_mission / claim_advent / grant. At least one
// field must actually pay something — an action that does nothing is a bug, not a
// no-op, so it is refused instead of queued.
function rewardFields(p) {
  const out = {}
  for (const [name, [min, max]] of Object.entries(REWARD_LIMITS)) {
    const v = intField(p, name, min, max)
    if (v) out[name] = v
  }
  const item = keyField(p, "item", KEY_ITEM, "item key (kind:id)")
  if (item) {
    out.item = item
    const kind = keyField(p, "item_kind", KEY_TEXT, "item kind")
    out.item_kind = kind || (item.startsWith("ornament:") ? "ornament" : "cosmetic")
  }
  const product = keyField(p, "product", KEY_TEXT, "product")
  if (product) {
    if (!ENTITLEMENTS.includes(product)) throw new Refusal(`unknown product ${product}`)
    out.product = product
  }
  if (!out.coins && !out.gingerbread && !out.spins && !out.pass_xp && !out.item && !out.product)
    throw new Refusal("nothing to pay")
  return out
}

function validatePayload(kind, raw) {
  const p = parsePayload(raw)
  switch (kind) {
    case "claim_mission": {
      const mission = keyField(p, "mission", KEY_TEXT, "mission id")
        || (intField(p, "mission", 1, 999999999) != null ? String(p.mission) : null)
      if (!mission) throw new Refusal("mission id required")
      return { mission, ...rewardFields(p) }
    }
    case "claim_advent": {
      const day = intField(p, "day", 1, MAX_ADVENT_DAY)
      if (day == null) throw new Refusal("advent day required")
      // `now` is the SERVER's clock (only a test passes one). The date verdicts -
      // today only, a missed day is gone, the Advent Pass reopens them after 24
      // December - live in src/panel/advent.js and are enforced again at apply
      // time, inside the transaction.
      // An ornament day carries its slot, and the panel places it in the same
      // action that grants it (see payReward's `placed`).
      const slot = intField(p, "slot", 1, MAX_TREE_SLOT)
      const out = slot == null ? { day, ...rewardFields(p) } : { day, slot, ...rewardFields(p) }
      const when = intField(p, "now", 0, 4000000000)
      if (when) out.now = when
      // The label the ledger line carries ("advent-day-9"), so "recent rewards"
      // reads as a day rather than as the generic kind name.
      const reason = keyField(p, "reason", KEY_TEXT, "reason")
      if (reason) out.reason = reason
      return out
    }
    case "place_ornament": {
      // The GAME's own tree primitive (winterfest_core's place path) without the
      // ownership requirement of plant_ornament: used by the panel when it grants
      // an ornament and wants it on the tree in the same action.
      const slot = intField(p, "slot", 1, MAX_TREE_SLOT)
      const ornament = intField(p, "ornament", 1, 9999)
      if (slot == null) throw new Refusal("tree slot required (1..24)")
      if (ornament == null) throw new Refusal("ornament id required")
      return { slot, ornament }
    }
    case "plant_ornament": {
      const slot = intField(p, "slot", 1, MAX_TREE_SLOT)
      const ornament = intField(p, "ornament", 1, 9999)
      if (slot == null) throw new Refusal("tree slot required (1..24)")
      if (ornament == null) throw new Refusal("ornament id required")
      const level = intField(p, "level", 0, MAX_TREE_SLOT)
      return level == null ? { slot, ornament } : { slot, ornament, level }
    }
    case "buy": {
      const item = keyField(p, "item", KEY_ITEM, "item key (kind:id)")
      const product = keyField(p, "product", KEY_TEXT, "product")
      if (!item && !product) throw new Refusal("item or product required")
      if (item && product) throw new Refusal("one of item or product, not both")
      if (product && !ENTITLEMENTS.includes(product)) throw new Refusal(`unknown product ${product}`)
      const price = parsePayload(p.price)
      const coins = intField(price, "coins", 0, 1000000) || 0
      const gingerbread = intField(price, "gingerbread", 0, 1000000) || 0
      if (!coins && !gingerbread) throw new Refusal("a price is required (a free grant is kind 'grant')")
      const out = { price: { coins, gingerbread } }
      if (item) {
        out.item = item
        const ik = keyField(p, "item_kind", KEY_TEXT, "item kind")
        out.item_kind = ik || (item.startsWith("ornament:") ? "ornament" : "cosmetic")
      }
      if (product) out.product = product
      return out
    }
    case "equip": {
      const item = keyField(p, "item", KEY_ITEM, "item key (kind:id)")
      if (!item) throw new Refusal("item required")
      return { item }
    }
    case "grant": {
      const reason = keyField(p, "reason", KEY_TEXT, "reason") || "manual"
      return { reason, ...rewardFields(p) }
    }
    default:
      throw new Refusal(`unknown kind ${kind}`)
  }
}

// The ledger's `ref`: the subject of the action, in words a person can read in a
// ledger listing. Never parsed back — it is a label, not a key.
function subjectOf(kind, p) {
  switch (kind) {
    case "claim_mission": return `mission:${p.mission}`
    case "claim_advent": return `advent:${p.day}`
    case "plant_ornament": return `tree:${p.slot}`
    case "place_ornament": return `tree:${p.slot}`
    case "buy": return `buy:${p.item || p.product}`
    case "equip": return `equip:${p.item}`
    case "grant": return `grant:${p.reason || "manual"}`
    default: return kind
  }
}

// The default idempotency key: derived from what the action is ABOUT, so a caller
// that forgets to pass one still cannot double-queue by refreshing. A grant has no
// natural subject, so it falls back to a digest of its own payload: a byte-identical
// retry collapses into one row, two genuinely different grants do not.
async function defaultIdem(kind, p) {
  switch (kind) {
    case "claim_mission": return `mission:${p.mission}`
    case "claim_advent": return `advent:${p.day}`
    case "plant_ornament": return `tree:${p.slot}:${p.ornament}`
    case "place_ornament": return `tree:${p.slot}:${p.ornament}`
    case "buy": return `buy:${p.item || p.product}`
    case "equip": return `equip:${p.item}`
    case "spin": return `spin:${p.n}`
    default: return `grant:` + (await sha256Hex(JSON.stringify(p))).slice(0, 24)
  }
}

// ------------------------------------------------------- the ledger helpers --
// The ONLY functions that move a currency. The table/column identifiers come from
// this frozen map and never from a caller, which is what keeps the statements
// below free of interpolated input.
const CURRENCY = {
  coins: { table: "players", column: "coins" },
  gingerbread: { table: "winter_players", column: "snowflakes" },
  spins: { table: "winter_players", column: "spins" }
}

export const CURRENCIES = Object.freeze(Object.keys(CURRENCY))

async function ensureWinterRow(tx, steamid, now) {
  await tx.run(
    `INSERT OR IGNORE INTO winter_players (steamid, season, seen_at) VALUES (?1,?2,?3)`,
    [steamid, SEASON, now])
}

async function ensurePlayerRow(tx, steamid) {
  await tx.run(`INSERT OR IGNORE INTO players (steamid) VALUES (?1)`, [steamid])
}

// Credit (delta > 0) or debit (delta < 0) and write the ledger row with the
// balance it leaves behind. A debit that would go negative is a Refusal, and the
// caller's transaction rolls back — including any credit already made in the same
// apply (a two-currency price pays both or neither).
async function addCurrency(tx, steamid, currency, delta, meta, now) {
  const spec = CURRENCY[currency]
  if (!spec) throw new Refusal(`unknown currency ${currency}`)
  const n = Math.trunc(Number(delta) || 0)
  if (n === 0) throw new Refusal("zero currency change")
  if (currency === "coins") await ensurePlayerRow(tx, steamid)
  else await ensureWinterRow(tx, steamid, now)
  const row = await tx.first(`SELECT ${spec.column} AS v FROM ${spec.table} WHERE steamid=?1`, [steamid])
  const balance = Number((row && row.v) || 0)
  const next = balance + n
  if (next < 0) throw new Refusal(`not enough ${currency} (have ${balance}, need ${-n})`)
  await tx.run(`UPDATE ${spec.table} SET ${spec.column}=?2 WHERE steamid=?1`, [steamid, next])
  await tx.run(
    `INSERT INTO winter_ledger (steamid, currency, delta, balance_after, reason, ref, action_id, created_at)
     VALUES (?1,?2,?3,?4,?5,?6,?7,?8)`,
    [steamid, currency, n, next, meta.reason, meta.ref, meta.action_id || 0, now])
  return next
}

async function addPassXp(tx, steamid, amount, now) {
  await ensureWinterRow(tx, steamid, now)
  const row = await tx.first(`SELECT pass_xp, pass_tier FROM winter_players WHERE steamid=?1`, [steamid])
  const xp = Number((row && row.pass_xp) || 0) + Math.trunc(Number(amount) || 0)
  // Monotonic: a tier never goes down, exactly like the pass ledger the game kept.
  const tier = Math.max(Number((row && row.pass_tier) || 1), passTierFromXp(xp))
  await tx.run(`UPDATE winter_players SET pass_xp=?2, pass_tier=?3 WHERE steamid=?1`, [steamid, xp, tier])
  return { xp, tier }
}

async function addItem(tx, steamid, item, kind, now) {
  await tx.run(
    `INSERT INTO winter_inventory (steamid, item, kind, qty, equipped, acquired_at)
     VALUES (?1,?2,?3,1,0,?4)
     ON CONFLICT(steamid, item) DO UPDATE SET qty = qty + 1`,
    [steamid, item, kind || "cosmetic", now])
}

/**
 * Put one ornament in one tree slot. Shared by plant_ornament (which requires
 * the player to own it first) and place_ornament (the panel's own grant path, in
 * the same action as the award). One ornament per slot and one slot per ornament
 * (schema.sql's unique index): the ornament is taken out of any other slot first,
 * then this slot is claimed. `level` is only written when the caller has one.
 */
async function placeOnTree(tx, steamid, slot, ornament, level, now) {
  await tx.run(
    `DELETE FROM winter_tree WHERE steamid=?1 AND ornament=?2 AND slot<>?3`,
    [steamid, ornament, slot])
  await tx.run(
    `INSERT INTO winter_tree (steamid, slot, ornament, moved_at) VALUES (?1,?2,?3,?4)
     ON CONFLICT(steamid, slot) DO UPDATE SET ornament=?3, moved_at=?4`,
    [steamid, slot, ornament, now])
  if (level != null) {
    await tx.run(
      `UPDATE winter_players
          SET ornaments_total = (SELECT COUNT(*) FROM winter_tree WHERE steamid=?1), tree_level=?2
        WHERE steamid=?1`, [steamid, level])
  } else {
    await tx.run(
      `UPDATE winter_players
          SET ornaments_total = (SELECT COUNT(*) FROM winter_tree WHERE steamid=?1)
        WHERE steamid=?1`, [steamid])
  }
  return { slot, ornament }
}

async function addEntitlement(tx, steamid, product, source, now) {
  await tx.run(
    `INSERT INTO winter_entitlements (steamid, product, source, granted_at) VALUES (?1,?2,?3,?4)
     ON CONFLICT(steamid, product) DO NOTHING`,
    [steamid, product, source || "", now])
  // `premium` is a cache of the entitlement, never a second truth: getPlayer()
  // reports the entitlement, and this keeps the column honest for the game's pull.
  if (product === PREMIUM_PRODUCT) {
    await ensureWinterRow(tx, steamid, now)
    await tx.run(`UPDATE winter_players SET premium=1 WHERE steamid=?1`, [steamid])
  }
}

// The shared payment block for claim_mission, claim_advent and grant.
async function payReward(tx, steamid, p, meta, now) {
  const out = { coins: null, gingerbread: null, spins: null, pass_xp: null, item: null, product: null }
  if (p.coins) out.coins = await addCurrency(tx, steamid, "coins", p.coins, meta, now)
  if (p.gingerbread) out.gingerbread = await addCurrency(tx, steamid, "gingerbread", p.gingerbread, meta, now)
  if (p.spins) out.spins = await addCurrency(tx, steamid, "spins", p.spins, meta, now)
  if (p.pass_xp) out.pass_xp = await addPassXp(tx, steamid, p.pass_xp, now)
  if (p.item) { await addItem(tx, steamid, p.item, p.item_kind, now); out.item = p.item }
  if (p.product) { await addEntitlement(tx, steamid, p.product, meta.reason, now); out.product = p.product }
  // An ornament that arrives WITH a slot goes straight onto the tree: the same
  // action grants it and places it, so a claim player cannot lose the placement
  // if their second action fails. Only an ornament item takes a slot.
  if (p.item && p.slot && String(p.item).startsWith("ornament:")) {
    const ord = Number(String(p.item).slice("ornament:".length))
    if (ord > 0) out.placed = await placeOnTree(tx, steamid, p.slot, ord, null, now)
  }
  return out
}

// ---------------------------------------------------------------- the queue --
// Insert one intent. `steamid`, `kind` and the idempotency key are the identity of
// the intent: a second call with the same three returns the row that already
// exists (`created: false`) and touches nothing. That is the whole anti-double-click
// story — the UNIQUE constraint does the work, not a check-then-insert.
export async function queueAction(db, input) {
  await ensureStateSchema(db)
  const src = input || {}
  const steamid = String(src.steamid || "")
  if (!validSteamid(steamid)) throw new Refusal("bad steamid")
  const kind = String(src.kind || "")
  if (!ACTION_KINDS.includes(kind)) throw new Refusal(`unknown kind ${kind || "(empty)"}`)
  const payload = validatePayload(kind, src.payload)
  const t = nowOf(src.now)

  let idem = src.idem == null || src.idem === "" ? "" : String(src.idem)
  if (idem && (idem.length > 64 || !KEY_IDEM.test(idem))) throw new Refusal("bad idempotency key")
  if (!idem) idem = await defaultIdem(kind, payload)

  const res = await runOn(db,
    `INSERT INTO winter_actions (steamid, kind, payload, state, idem, created_at)
     VALUES (?1,?2,?3,'pending',?4,?5)
     ON CONFLICT(steamid, kind, idem) DO NOTHING`,
    [steamid, kind, JSON.stringify(payload), idem, t])
  const row = await firstOn(db,
    `SELECT * FROM winter_actions WHERE steamid=?1 AND kind=?2 AND idem=?3`, [steamid, kind, idem])
  if (!row) throw new Refusal("action queue is unavailable")
  return { ok: true, created: changesOf(res) === 1, action: mapActionRow(row) }
}

function mapActionRow(row) {
  return {
    id: Number(row.id),
    steamid: row.steamid,
    kind: row.kind,
    payload: safeJson(row.payload) || {},
    state: row.state,
    idem: row.idem,
    created_at: Number(row.created_at || 0),
    applied_at: Number(row.applied_at || 0),
    error: row.error || "",
    result: safeJson(row.result) || null,
    game_state: row.game_state || "",
    game_error: row.game_error || "",
    game_acked_at: Number(row.game_acked_at || 0)
  }
}

function safeJson(text) {
  if (text == null || text === "") return null
  if (typeof text === "object") return text
  try { return JSON.parse(text) } catch { return null }
}

// ---------------------------------------------------------------- the apply --
// Apply ONE queued row: write the state tables and the ledger in one transaction,
// mark the row with the verdict, and return the balances it left behind.
//
//   { ok, action_id, state: applied|refused, error, result, balances, already }
//
// Applying a row that is no longer 'pending' is not an error: it returns the stored
// verdict with `already: true` and writes nothing. That is what makes a retried
// claim (and a game that pulls the same action twice) pay exactly once.
export async function applyAction(db, action, opts) {
  await ensureStateSchema(db)
  const id = typeof action === "number" ? action : Number(action && action.id)
  if (!Number.isInteger(id) || id <= 0) throw new Refusal("action id required")
  const row = await firstOn(db, `SELECT * FROM winter_actions WHERE id=?1`, [id])
  if (!row) throw new Refusal(`no action ${id}`)
  if (row.state !== "pending") {
    return {
      ok: row.state === "applied",
      action_id: id,
      state: row.state,
      error: row.error || "",
      result: safeJson(row.result),
      balances: await balancesOf(db, row.steamid),
      already: true
    }
  }
  const t = nowOf(opts && opts.now)
  const payload = safeJson(row.payload) || {}
  let result
  try {
    result = await withTransaction(db, async tx => {
      const out = await applyOne(tx, { ...row, id, payload }, t)
      await tx.run(
        `UPDATE winter_actions SET state='applied', applied_at=?2, error='', result=?3
         WHERE id=?1 AND state='pending'`,
        [id, t, JSON.stringify(out)])
      return out
    })
  } catch (e) {
    const reason = e instanceof Refusal ? e.reason
      : String((e && e.message) || "apply failed").slice(0, 200)
    // The rollback already undid every write of the attempt. Record the verdict
    // outside it, so "refused" survives and the balances stay untouched.
    try {
      await runOn(db,
        `UPDATE winter_actions SET state='refused', error=?2, applied_at=?3
         WHERE id=?1 AND state='pending'`, [id, reason, t])
    } catch {}
    return {
      ok: false,
      action_id: id,
      state: "refused",
      error: reason,
      result: null,
      balances: await balancesOf(db, row.steamid),
      already: false
    }
  }
  return {
    ok: true,
    action_id: id,
    state: "applied",
    error: "",
    result,
    balances: await balancesOf(db, row.steamid),
    already: false
  }
}

async function applyOne(tx, row, now) {
  const steamid = row.steamid
  const p = row.payload
  // A claim may carry its own label ("advent day 7"); every other kind keeps the
  // one-word reason and the subject as the ledger line.
  const meta = { reason: p.reason || row.kind, ref: subjectOf(row.kind, p), action_id: row.id }
  switch (row.kind) {
    case "claim_mission": {
      const out = await payReward(tx, steamid, p, meta, now)
      return { ...out, mission: p.mission }
    }
    case "claim_advent": {
      await ensureWinterRow(tx, steamid, now)
      const already = await tx.first(
        `SELECT day FROM winter_advent WHERE steamid=?1 AND season=?2 AND day=?3`,
        [steamid, SEASON, p.day])
      if (already) throw new Refusal(`advent day ${p.day} already claimed`)
      // THE OWNER'S DATE LAW, enforced where it cannot be skipped: at APPLY time,
      // inside the transaction, on the server's clock (p.now when the caller passes
      // one, so a test can freeze it). Today's day only; a missed day is gone; after
      // 24 December only an Advent Pass owner, and only until 31 December.
      const clock = adventClock(p.now || now, { season: Number(SEASON) })
      const owned = await tx.first(
        `SELECT product FROM winter_entitlements WHERE steamid=?1 AND product=?2`,
        [steamid, ADVENT_PRODUCT])
      const claimedDays = new Set((await tx.all(
        `SELECT day FROM winter_advent WHERE steamid=?1 AND season=?2`, [steamid, SEASON])
        .catch(() => []) || []).map(r => Number(r.day)))
      const refusal = claimRefusal(p.day, clock, claimedDays, !!owned)
      if (refusal) throw new Refusal(refusal)
      const out = await payReward(tx, steamid, p, meta, now)
      await tx.run(
        `INSERT INTO winter_advent (steamid, season, day, claimed_at, claim_key) VALUES (?1,?2,?3,?4,?5)`,
        [steamid, SEASON, p.day, now, row.idem])
      // The count is derived, never incremented: one statement after the insert,
      // inside the same transaction, so it cannot drift from the ledger.
      await tx.run(
        `UPDATE winter_players
            SET advent_claimed = (SELECT COUNT(*) FROM winter_advent WHERE steamid=?1 AND season=?2)
          WHERE steamid=?1`, [steamid, SEASON])
      return { ...out, day: p.day }
    }
    case "plant_ornament": {
      await ensureWinterRow(tx, steamid, now)
      const owned = await tx.first(
        `SELECT item FROM winter_inventory WHERE steamid=?1 AND item=?2`,
        [steamid, `ornament:${p.ornament}`])
      if (!owned) throw new Refusal(`ornament ${p.ornament} is not owned`)
      return await placeOnTree(tx, steamid, p.slot, p.ornament, p.level, now)
    }
    case "place_ornament": {
      await ensureWinterRow(tx, steamid, now)
      return await placeOnTree(tx, steamid, p.slot, p.ornament, null, now)
    }
    case "buy": {
      if (p.item) {
        const owned = await tx.first(
          `SELECT item FROM winter_inventory WHERE steamid=?1 AND item=?2`, [steamid, p.item])
        if (owned) throw new Refusal(`${p.item} is already owned`)
      }
      if (p.product) {
        const owned = await tx.first(
          `SELECT product FROM winter_entitlements WHERE steamid=?1 AND product=?2`, [steamid, p.product])
        if (owned) throw new Refusal(`${p.product} is already owned`)
      }
      // Both currencies or neither: a Refusal on the second debit rolls back the
      // first (local transaction) or never flushes the batch (D1).
      if (p.price.coins) await addCurrency(tx, steamid, "coins", -p.price.coins, meta, now)
      if (p.price.gingerbread) await addCurrency(tx, steamid, "gingerbread", -p.price.gingerbread, meta, now)
      if (p.item) await addItem(tx, steamid, p.item, p.item_kind, now)
      if (p.product) await addEntitlement(tx, steamid, p.product, "buy", now)
      return { item: p.item || null, product: p.product || null, paid: p.price }
    }
    case "equip": {
      const held = await tx.first(
        `SELECT item, kind FROM winter_inventory WHERE steamid=?1 AND item=?2`, [steamid, p.item])
      if (!held) throw new Refusal(`${p.item} is not owned`)
      // One equipped item per kind: clear the others, then wear this one.
      await tx.run(
        `UPDATE winter_inventory SET equipped=0 WHERE steamid=?1 AND kind=?2 AND item<>?3`,
        [steamid, held.kind, p.item])
      await tx.run(`UPDATE winter_inventory SET equipped=1 WHERE steamid=?1 AND item=?2`, [steamid, p.item])
      return { item: p.item, kind: held.kind, equipped: true }
    }
    case "grant": {
      const out = await payReward(tx, steamid, p, meta, now)
      return { ...out, reason: p.reason || "manual" }
    }
    case "spin": {
      // Spend the token FIRST (a debit refuses at zero, which rolls the whole
      // action back), then pay the wedge this row's id lands on. Both movements
      // carry this action's id in the ledger, so one spin is two lines and the
      // ledger is the story.
      await addCurrency(tx, steamid, "spins", -1, meta, now)
      const wedge = spinWedge(row.id)
      if (wedge.none) return { wedge: "nothing", prize: wedge.label }
      const out = await payReward(tx, steamid, { ...wedge.reward, reason: `spin-${wedge.key}` }, meta, now)
      return { ...out, wedge: wedge.key, prize: wedge.label }
    }
    default:
      // Unreachable through queueAction (it validates the kind), reachable for a
      // row written by hand — which is exactly the case the harness proves.
      throw new Refusal(`unknown kind ${row.kind}`)
  }
}

// --------------------------------------------------------------- the readout --
// What every page reads. One object, no page-level SQL: coins, gingerbread,
// spins, level/xp, pass tier+xp, tree level, entitlements and counts.
//
// `exists: false` means the PANEL HAS NEVER HEARD FROM THIS PLAYER: coins/xp/level
// are null, not zero, because a zero that means "unknown" is a bug. Winter counters
// are 0 because the panel owns them and nothing has been granted yet.
export async function getPlayer(db, steamid) {
  await ensureStateSchema(db)
  const sid = String(steamid || "")
  if (!validSteamid(sid)) throw new Refusal("bad steamid")
  const p = await firstOn(db,
    // page-driven addition (docs/panel/01-DATA.md §11), the WHOLE row is read:
    // rank_id, eq_model, cc and the career counters ride along for the profile and
    // the leaderboards. A named list would bake this file to schema.sql's columns -
    // and a D1 / test database migrated without them answers "no such column"
    // instead of a page. `SELECT *` cannot go stale.
    `SELECT * FROM players WHERE steamid=?1`, [sid])
  const w = await firstOn(db,
    `SELECT season, snowflakes, spins, tree_level, ornaments_total, advent_claimed,
            pass_xp, pass_tier, premium, seen_at
       FROM winter_players WHERE steamid=?1`, [sid])
  const ents = await allOn(db,
    `SELECT product FROM winter_entitlements WHERE steamid=?1 ORDER BY product`, [sid])
  const c = await firstOn(db,
    `SELECT
       (SELECT COUNT(*) FROM winter_actions   WHERE steamid=?1 AND state='pending')  AS actions_pending,
       (SELECT COUNT(*) FROM winter_actions   WHERE steamid=?1 AND state='applied')  AS actions_applied,
       (SELECT COUNT(*) FROM winter_actions   WHERE steamid=?1 AND state='refused')  AS actions_refused,
       (SELECT COUNT(*) FROM winter_inventory WHERE steamid=?1)                      AS inventory,
       (SELECT COUNT(*) FROM winter_inventory WHERE steamid=?1 AND kind='ornament')  AS ornaments,
       (SELECT COUNT(*) FROM winter_ledger    WHERE steamid=?1)                      AS ledger,
       (SELECT COUNT(*) FROM winter_tree      WHERE steamid=?1)                      AS tree_slots,
       (SELECT COUNT(*) FROM winter_mail      WHERE steamid=?1 AND read_at=0)        AS mail_unread`,
    [sid])
  const entitlements = ents.map(r => r.product)
  const xp = Number((w && w.pass_xp) || 0)
  const tier = Number((w && w.pass_tier) || 1)
  const nextTier = tier >= PASS_MAX_TIER ? null : tier + 1
  return {
    steamid: sid,
    exists: !!(p || w),
    name: p ? String(p.name || "") : "",
    coins: p ? Number(p.coins || 0) : null,
    gingerbread: Number((w && w.snowflakes) || 0),
    spins: Number((w && w.spins) || 0),
    level: p ? Number(p.level || 0) : null,
    xp: p ? Number(p.xp || 0) : null,
    rank_id: p ? Number(p.rank_id || 0) : null,
    cc: p ? String(p.cc || "") : "",
    eq_model: p ? String(p.eq_model || "") : "",
    // Career counters, straight from the game's snapshot; null when the panel has
    // never heard from this player (never 0 - see the note above).
    career: {
      kills: p ? Number(p.kills || 0) : null,
      deaths: p ? Number(p.deaths || 0) : null,
      wins: p ? Number(p.wins || 0) : null,
      losses: p ? Number(p.losses || 0) : null,
      playtime_minutes: p ? Number(p.playtime_minutes || 0) : null
    },
    pass: {
      xp,
      tier,
      tier_xp: passTierXp(tier),
      next_tier: nextTier,
      next_tier_xp: nextTier == null ? null : passTierXp(nextTier),
      into_tier: xp - passTierXp(tier),
      needed: nextTier == null ? 0 : passTierXp(nextTier) - xp
    },
    tree: {
      level: Number((w && w.tree_level) || 0),
      slots: Number((c && c.tree_slots) || 0),
      capacity: MAX_TREE_SLOT
    },
    // The entitlement is the truth; winter_players.premium is the cache the game pulls.
    premium: entitlements.includes(PREMIUM_PRODUCT) ? 1 : 0,
    entitlements,
    season: (w && w.season) || SEASON,
    counts: {
      actions_pending: Number((c && c.actions_pending) || 0),
      actions_applied: Number((c && c.actions_applied) || 0),
      actions_refused: Number((c && c.actions_refused) || 0),
      inventory: Number((c && c.inventory) || 0),
      ornaments: Number((c && c.ornaments) || 0),
      ledger: Number((c && c.ledger) || 0),
      tree_slots: Number((c && c.tree_slots) || 0),
      mail_unread: Number((c && c.mail_unread) || 0),
      advent_claimed: Number((w && w.advent_claimed) || 0),
      ornaments_total: Number((w && w.ornaments_total) || 0)
    },
    // Honest sync: when the panel last heard from the game, and when winter state
    // last moved. Never a claim about the live server.
    last_seen: p ? Number(p.last_seen || 0) : 0,
    seen_at: Number((w && w.seen_at) || 0)
  }
}

export async function balancesOf(db, steamid) {
  const p = await firstOn(db, `SELECT coins FROM players WHERE steamid=?1`, [steamid])
  const w = await firstOn(db, `SELECT snowflakes, spins, pass_xp, pass_tier FROM winter_players WHERE steamid=?1`, [steamid])
  return {
    coins: p ? Number(p.coins || 0) : null,
    gingerbread: Number((w && w.snowflakes) || 0),
    spins: Number((w && w.spins) || 0),
    pass_xp: Number((w && w.pass_xp) || 0),
    pass_tier: Number((w && w.pass_tier) || 1)
  }
}

// ------------------------------------------------------------- the game I/O --
// GET /api/game/pending: what the game still has to see for one player — every row
// it has not reported back on yet (game_acked_at = 0), in queue order. `state` is
// the panel's verdict: the game mirrors the 'applied' rows and acks the 'refused'
// ones without applying them.
export async function pendingActions(db, steamid, opts) {
  await ensureStateSchema(db)
  const sid = String(steamid || "")
  if (!validSteamid(sid)) throw new Refusal("bad steamid")
  const limit = Math.max(1, Math.min(100, Math.trunc(Number((opts && opts.limit) || 32))))
  const rows = await allOn(db,
    `SELECT id, steamid, kind, payload, state, idem, created_at, applied_at, error, result
       FROM winter_actions
      WHERE steamid=?1 AND game_acked_at=0
      ORDER BY id LIMIT ?2`, [sid, limit])
  return rows.map(r => ({
    id: Number(r.id),
    kind: r.kind,
    payload: safeJson(r.payload) || {},
    state: r.state,
    idem: r.idem,
    error: r.error || "",
    result: safeJson(r.result),
    created_at: Number(r.created_at || 0),
    applied_at: Number(r.applied_at || 0)
  }))
}

// POST /api/game/ack: the game's report on one action. Idempotent by construction —
// the UPDATE itself is the claim (`WHERE game_acked_at=0`), so the first report wins
// and every later one returns the stored verdict with `already: true` instead of
// rewriting it. No balance is touched here: the apply already happened.
export async function ackAction(db, input) {
  await ensureStateSchema(db)
  const src = input || {}
  const id = Number(src.id)
  if (!Number.isInteger(id) || id <= 0) throw new Refusal("action id required")
  const state = String(src.state || "")
  if (state !== "applied" && state !== "refused") throw new Refusal("state must be applied or refused")
  const error = String(src.error == null ? "" : src.error).slice(0, 200)
  const t = nowOf(src.now)

  const row = await firstOn(db, `SELECT * FROM winter_actions WHERE id=?1`, [id])
  if (!row) return { ok: false, error: `no action ${id}` }
  const res = await runOn(db,
    `UPDATE winter_actions SET game_state=?2, game_error=?3, game_acked_at=?4
      WHERE id=?1 AND game_acked_at=0`, [id, state, error, t])
  if (changesOf(res) === 1) {
    return { ok: true, id, state, error, game_acked_at: t, already: false, panel_state: row.state }
  }
  const now = await firstOn(db, `SELECT game_state, game_error, game_acked_at FROM winter_actions WHERE id=?1`, [id])
  return {
    ok: true,
    id,
    state: (now && now.game_state) || "",
    error: (now && now.game_error) || "",
    game_acked_at: Number((now && now.game_acked_at) || 0),
    already: true,
    panel_state: row.state
  }
}

// ------------------------------------------------------------ ledger rebuild --
// Replay the ledger. If it disagrees with the stored balance the ledger wins and
// rebuildBalance() puts the balance back — and records the correction as a ledger
// row of its own, so the invariant survives the repair.
export async function ledgerBalance(db, steamid, currency) {
  await ensureStateSchema(db)
  if (!CURRENCY[currency]) throw new Refusal(`unknown currency ${currency}`)
  const row = await firstOn(db,
    `SELECT COALESCE(SUM(delta), 0) AS total FROM winter_ledger WHERE steamid=?1 AND currency=?2`,
    [steamid, currency])
  return Number((row && row.total) || 0)
}

export async function rebuildBalance(db, steamid, currency, opts) {
  const spec = CURRENCY[currency]
  if (!spec) throw new Refusal(`unknown currency ${currency}`)
  const repair = !!(opts && opts.repair)
  const ledger = await ledgerBalance(db, steamid, currency)
  const row = await firstOn(db, `SELECT ${spec.column} AS v FROM ${spec.table} WHERE steamid=?1`, [steamid])
  const stored = row ? Number(row.v || 0) : null
  const out = { currency, stored, ledger, repaired: false }
  if (stored == null || stored === ledger) return out
  if (!repair) return { ...out, drift: ledger - stored }
  const t = nowOf(opts && opts.now)
  await withTransaction(db, async tx => {
    await tx.run(`UPDATE ${spec.table} SET ${spec.column}=?2 WHERE steamid=?1`, [steamid, ledger])
    // A repair is not a currency movement, so `delta` stays 0: that keeps the
    // ledger's own arithmetic (every delta sums to the newest balance_after, which
    // is the balance) true across the repair. The correction it applied is
    // `ledger - stored` and lives in the reason/ref, not in a fake delta.
    await tx.run(
      `INSERT INTO winter_ledger (steamid, currency, delta, balance_after, reason, ref, action_id, created_at)
       VALUES (?1,?2,0,?3,'rebuild','ledger',0,?4)`,
      [steamid, currency, ledger, t])
  })
  return { ...out, stored_before: stored, repaired: true }
}
