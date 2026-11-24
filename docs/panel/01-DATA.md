# Panel data layer — schema, kinds, and the game's exact JSON

Layer 1 of the rebuild (`docs/panel/00-CONTRACT.md`): the data everything else sits
on. This document is the spec for the two sides that touch it — the panel pages and
the game server — and it is the one place a column, a kind or a response field is
defined. If the code and this file disagree, one of them is a bug.

Owner: the panel. `src/state.js` is **the only writer** of the tables below.
`src/query.js` is the only reader the pages use. `src/index.js` carries the two
game-facing routes.

```
panel page (14 layouts)      reads  → src/query.js            (read-only)
panel action (POST, no JS)   writes → winter_actions           (queueAction)
apply step                   writes → state tables + winter_ledger, ONE transaction (applyAction)
game pull (AMXX)             GET  /api/game/pending           → mirrors, then reports
game report (AMXX)           POST /api/game/ack               → ackAction
game push (existing ingest)  POST /api/v1/server/stats        → unchanged, see §9
```

---

## 1. Who owns which column

The contract makes the DB authoritative, so every column has exactly one writer.

| column group | writer | notes |
| --- | --- | --- |
| `players.name/xp/level/rank_id/…` (rank, combat, VIP) | the **ingest** (game snapshot) | unchanged; `players.last_seen` carries the push clock |
| `players.coins` | **both** — the ingest overwrites it, the panel pays from it | the one real overlap left; see §9 |
| `winter_players.*` (gingerbread, spins, tree, pass, premium) | `src/state.js` only | no ingest writer |
| `winter_inventory`, `winter_entitlements` | `src/state.js` only | no ingest writer |
| `winter_actions`, `winter_ledger` | `src/state.js` only | queue + append-only ledger |
| `winter_tree`, `winter_advent` | `src/state.js` only (via `plant_ornament`, `claim_advent`) | `winter_advent`'s primary key is the duplicate-claim guard |
| `winter_mail` | staff `/admin` | read here, never written here |

Nothing in `game-server/**` writes any `winter_*` table. The game only *reads* the
queue and *reports* on it (§7), and the AI/AMXX work streams build against §7.

---

## 2. The tables — final column list

Defined in `web-panel/schema.sql` (bottom section, "Winterfest 2026 — panel-owned
state") and repeated lazily in `src/state.js` `STATE_DDL`, so a deployment that never
execs `schema.sql` still gets them. Every statement is `CREATE … IF NOT EXISTS`.

### `winter_actions` — the queue, panel → game

(`00-CONTRACT.md`'s layer diagram abbreviates this table as `wf_actions`; the table
is `winter_actions`.)

| column | type | meaning |
| --- | --- | --- |
| `id` | INTEGER PK AUTOINCREMENT | the action id the game acks |
| `steamid` | TEXT | `STEAM_0:0:123` (packed/colon both accepted, stored colon-form) |
| `kind` | TEXT | §3 vocabulary: `claim_mission · claim_advent · plant_ornament · buy · equip · grant` |
| `payload` | TEXT | JSON, **normalised by `queueAction`** before it is stored |
| `state` | TEXT | `pending` → `applied` \| `refused` — the panel's verdict |
| `idem` | TEXT | idempotency key; **UNIQUE (steamid, kind, idem)** |
| `created_at` | INTEGER | unix seconds |
| `applied_at` | INTEGER | when the apply verdict was written (0 while pending) |
| `error` | TEXT | why the panel refused (empty when applied) |
| `result` | TEXT | JSON: the balances/items the apply produced |
| `game_state` | TEXT | `applied` \| `refused` — **the game's** report (empty until acked) |
| `game_error` | TEXT | the game's own reason, ≤200 chars |
| `game_acked_at` | INTEGER | 0 = the game has not reported back; non-zero = acked |

Indexes: `(steamid, game_acked_at, id)` for the pull, `(state, id)` for admin views.

### `winter_ledger` — append-only, one row per currency change

| column | type | meaning |
| --- | --- | --- |
| `id` | INTEGER PK AUTOINCREMENT | |
| `steamid` | TEXT | |
| `currency` | TEXT | `coins` \| `gingerbread` \| `spins` |
| `delta` | INTEGER | signed, never 0 — the one exception is a repair row (`reason='rebuild'`, delta 0) |
| `balance_after` | INTEGER | the balance this row left behind |
| `reason` | TEXT | the action kind, or `rebuild` |
| `ref` | TEXT | the subject: `mission:12`, `advent:3`, `tree:9`, `buy:ornament:4`, `equip:title:3`, `grant:staff`, `ledger` |
| `action_id` | INTEGER | `winter_actions.id` that caused it (0 for a repair) |
| `created_at` | INTEGER | |

Indexes: `(steamid, id DESC)`, `(action_id)`.

### `winter_entitlements` — products a player owns

| column | type | meaning |
| --- | --- | --- |
| `steamid` | TEXT | |
| `product` | TEXT | `bp_premium_2026` \| `advent_pass_2026` |
| `source` | TEXT | `buy` \| `grant` \| `staff` |
| `granted_at` | INTEGER | |

`PRIMARY KEY (steamid, product)` — a second grant of the same product cannot insert,
so it can never be paid for twice.

### `winter_inventory` — items a player owns

| column | type | meaning |
| --- | --- | --- |
| `steamid` | TEXT | |
| `item` | TEXT | catalogue key: `ornament:12`, `title:3`, `model:snowman`, `skin:x`, `badge:y` |
| `kind` | TEXT | `ornament` \| `title` \| `model` \| `skin` \| `badge` \| `cosmetic` |
| `qty` | INTEGER | a grant of an owned item stacks; a `buy` of one is refused |
| `equipped` | INTEGER | 0/1, at most one per `kind` per player |
| `acquired_at` | INTEGER | |

`PRIMARY KEY (steamid, item)`; index `(steamid, kind, equipped)`.

### `winter_players` — the winter scalars (one row per player)

Baseline columns: `steamid` PK, `season`, `snowflakes` (gingerbread),
`gifts_found`, `tree_style`, `tree_level`, `ornaments_total`, `advent_claimed`,
`seen_at`.

Columns the contract added: `spins`, `pass_xp`, `pass_tier`, `premium`.

| added column | default | meaning |
| --- | --- | --- |
| `spins` | 0 | wheel tokens; a currency in the ledger |
| `pass_xp` | 0 | Winter Pass XP, cumulative |
| `pass_tier` | 1 | 1..30, **monotonic** (never derived downwards) |
| `premium` | 0 | cache of the `bp_premium_2026` entitlement (the entitlement is the truth) |

`tree_level` is the milestone level from the sets catalogue: the apply step writes
it only when an action carries an explicit `level`, because the panel does not
invent the milestone curve.

### Reused tables

`winter_tree(steamid, slot, ornament, moved_at)` with `UNIQUE (steamid, ornament)` —
one ornament in at most one slot. `winter_advent(steamid, season, day, claimed_at,
claim_key)` — the PK is the duplicate-claim guard. `winter_mail` — the inbox
(`src/query.js mail()`).

### `players` (existing)

Read for `name`, `coins`, `level`, `xp`, `last_seen`. The panel only ever writes
`coins` (through the ledger) and inserts a bare row (`INSERT OR IGNORE`) when it
pays coins to a steamid it has never seen.

---

## 3. The kind vocabulary

`queueAction(db, {steamid, kind, payload, idem?, now?})` validates the payload, then
inserts. `applyAction(db, id)` performs it. Every kind is:

* **idempotent** — one row per `(steamid, kind, idem)`, and a row whose state is no
  longer `pending` is never applied again;
* **atomic** — the state writes and the ledger rows commit together or not at all;
* **refused, not crashed** — a refusal returns `{ok:false, state:"refused", error}`
  and leaves every balance exactly as it was.

Shared reward fields, used by `claim_mission`, `claim_advent` and `grant`:

| field | range | effect |
| --- | --- | --- |
| `coins` | 0..1 000 000 | `players.coins` + ledger row (`currency='coins'`) |
| `gingerbread` | 0..1 000 000 | `winter_players.snowflakes` + ledger row (`gingerbread`) |
| `spins` | 0..100 | `winter_players.spins` + ledger row (`spins`) |
| `pass_xp` | 0..50 000 | `winter_players.pass_xp` (+`pass_tier` from the curve, §5); **not** a currency, no ledger row |
| `item` | `kind:id` | `winter_inventory` row (stacks if already owned) |
| `item_kind` | §2 kinds | defaults to `ornament` for `ornament:*`, else `cosmetic` |
| `product` | entitlement | `winter_entitlements` row; `bp_premium_2026` also sets `winter_players.premium=1` |

At least one of them must be present — an action that pays nothing is refused
(`nothing to pay`), not queued.

### `claim_mission`

```jsonc
{"mission": "12", "coins": 100, "gingerbread": 25}          // id "12" or 12
{"mission": "advent_boss", "item": "ornament:7", "pass_xp": 300}
```

Pays the declared reward. `ref` is `mission:<id>`; the default `idem` is
`mission:<id>`, so a second claim of mission 12 can never queue or pay twice.

The mission *ladder* (what pays what, and whether it is complete) is the game's
`winterfest/missions.ini`, published through the signed push. The panel stores the
claim and pays what the action declares; the game re-checks completion before it
mirrors the result in-engine.

### `claim_advent`

```jsonc
{"day": 3, "gingerbread": 40}
```

`day` 1..24. Refuses if `winter_advent` already holds `(steamid, '2026', day)`
(`advent day 3 already claimed`), so the calendar can pay a day exactly once even if
two different `idem`s are queued. Writes the `winter_advent` row, then derives
`winter_players.advent_claimed` from it (`COUNT(*)`, not an increment).

### `plant_ornament`

```jsonc
{"slot": 9, "ornament": 12}          // optional "level": 3 → winter_players.tree_level
```

`slot` 1..24, `ornament` 1..9999. Refuses (`ornament N is not owned`) unless the
player owns `ornament:N` in `winter_inventory`. Takes the ornament out of any other
slot first, then writes this one, so `UNIQUE (steamid, ornament)` holds and "move"
is the same action as "plant". Recomputes `winter_players.ornaments_total` from the
tree. Default `idem` is `tree:<slot>:<ornament>`.

### `buy`

```jsonc
{"item": "ornament:12", "item_kind": "ornament", "price": {"coins": 150, "gingerbread": 50}}
{"product": "bp_premium_2026", "price": {"gingerbread": 500}}
```

Exactly one of `item` / `product`. `price` needs at least one currency and both are
debited **or neither**: an unaffordable second currency rolls the first debit back
(`not enough gingerbread (have 75, need 9999)`). Refuses an item or product the
player already owns. A price of 0 is refused — a free item is `grant`, not `buy`.
Default `idem` is `buy:<item|product>`.

There is no price book in the panel DB yet: the price travels in the action, written
by the catalogue-backed page, and the ledger records exactly what was charged. When
a shop catalogue lands, it becomes the source the page reads; the apply step does not
need to change.

### `equip`

```jsonc
{"item": "title:3"}
```

Item must be owned. Marks it `equipped=1` and clears every other row of the same
`kind`, so a player cannot wear two titles. Default `idem` is `equip:<item>`.

### `grant`

```jsonc
{"reason": "staff", "gingerbread": 250, "spins": 2}
{"reason": "comp", "product": "advent_pass_2026"}
{"reason": "ap", "item": "title:9", "item_kind": "title", "pass_xp": 400}
```

The staff/comp path: any reward combination above. `reason` is a word (letters,
digits, `_ . : -`, ≤40) and becomes the ledger `ref` (`grant:<reason>`). There is no
natural subject, so the default `idem` is a digest of the payload: a byte-identical
retry collapses into one row, two different grants do not.

### Idempotency keys

`idem` is optional; the default per kind is in the tables above. When a caller
supplies one it must match `^[A-Za-z0-9_][A-Za-z0-9_.:-]{0,63}$`. The unique
constraint is the guard — `queueAction` returns `{created:false, action}` with the
row that already exists, so a refreshed page or a double-clicked button cannot
create a second intent, and a retried claim pays once.

---

## 4. Applying one action

`applyAction(db, id)` returns:

```jsonc
{ "ok": true,  "action_id": 12, "state": "applied", "error": "", "result": {…},
  "balances": {"coins": 450, "gingerbread": 75, "spins": 0, "pass_xp": 0, "pass_tier": 1},
  "already": false }
{ "ok": false, "action_id": 13, "state": "refused", "error": "not enough gingerbread (have 75, need 9999)",
  "result": null, "balances": {…}, "already": false }
```

* A row that is not `pending` anymore returns the stored verdict with
  `already: true` and writes nothing (this is what makes a retried claim, and a game
  that pulls the same action twice, harmless).
* A refusal writes **nothing**: validation runs before the first write, and the
  refusal is recorded on the action row *outside* the transaction, after the
  rollback.

### The transaction, exactly

One apply = one interactive SQLite transaction (`src/state.js`):

* opened: **`src/state.js:286`** — `raw.exec("BEGIN IMMEDIATE")`
* committed: **`src/state.js:289`** — `raw.exec("COMMIT")`
* rolled back on any throw: `src/state.js:292` — `raw.exec("ROLLBACK")`

Everything between them is inside `withTransaction()` (`src/state.js:272`):
`ensureWinterRow`/`ensurePlayerRow`, the currency debits and credits with their
ledger rows, the item/entitlement/tree/advent writes, and the
`UPDATE winter_actions SET state='applied' …`. A Cloudflare D1 binding has no
interactive transaction, so on that driver (`src/state.js:297` `batchTransaction`)
the reads run immediately, the writes are collected and flushed as one
`db.batch()` (line 308), and applies are serialised per isolate. The local runner —
the deployment in `server_local.mjs` — always takes the interactive path.

---

## 5. The ledger, the balances and the pass curve

* `addCurrency()` (`src/state.js:512`) is the only function that moves `coins`,
  `gingerbread` or `spins`. It reads the balance, refuses a debit that would go
  negative, writes the new balance and **always** writes the ledger row with
  `balance_after`, in the same transaction.
* `ledgerBalance(db, steamid, currency)` replays the ledger (`SUM(delta)`, 0 if
  empty). `rebuildBalance(db, steamid, currency, {repair:true})` compares it with the
  stored column and, on disagreement, puts the column back and appends a repair row
  (`reason='rebuild'`, delta 0, `balance_after` = the ledger total) so the ledger's
  arithmetic survives the repair. **The ledger wins.**
* `coins` is the exception to "the ledger is exact": the ingest still rewrites
  `players.coins` on every push (§9), so a coins rebuild is advisory until that
  column drops out of the ingest. Gingerbread and spins are panel-only and rebuild
  exactly.
* Winter Pass tier: `passTierFromXp()` (`src/state.js:86`) on the documented ladder —
  tier 1 at 0 XP, +300 XP for tiers 2–10 (2 700 at tier 10), +700 for 11–20 (9 700 at
  tier 20), +1 400 for 21–30 (23 700 at tier 30). `pass_tier` is monotonic: it never
  goes down, and a stale payload cannot lower it.

---

## 6. `getPlayer` — the one object every page reads

`getPlayer(db, steamid)` (`src/state.js:800`) returns:

```jsonc
{
  "steamid": "STEAM_0:0:701", "exists": true, "name": "harness-701",
  "coins": 450, "gingerbread": 75, "spins": 0,
  "level": 12, "xp": 18400,
  "pass": { "xp": 3400, "tier": 11, "tier_xp": 3400, "next_tier": 12,
            "next_tier_xp": 4100, "into_tier": 0, "needed": 700 },
  "tree": { "level": 0, "slots": 1, "capacity": 24 },
  "premium": 1,
  "entitlements": ["bp_premium_2026"],
  "season": "2026",
  "counts": { "actions_pending": 0, "actions_applied": 6, "actions_refused": 2,
              "inventory": 3, "ornaments": 1, "ledger": 8, "tree_slots": 1,
              "mail_unread": 1, "advent_claimed": 1, "ornaments_total": 1 },
  "last_seen": 1795385000, "seen_at": 1795385100
}
```

* `exists: false` means **the panel has never heard from this player**: `coins`,
  `level` and `xp` are `null`, not `0` — a zero that means "unknown" is a bug, so a
  page renders "not collected yet" instead. Winter counters are `0` because the panel
  owns them and nothing has been granted yet.
* `premium` is derived from `winter_entitlements` (the truth), not read from the
  `winter_players.premium` cache.
* `last_seen` / `seen_at` are the honest-sync fields: the moment the panel last heard
  from the game. They are never a claim about the live server.

`src/query.js` is the read-only surface on top of it:

| helper | returns |
| --- | --- |
| `topBoards(db, {limit, boards})` | `{xp, level, kills, coins, gingerbread}` → `[{rank, steamid, name, value}]` |
| `missionsFor(db, steamid)` | one row per queued/applied/refused mission claim (`mission`, `state`, `error`, `paid`) |
| `achievements(db, steamid)` | titles/badges the panel granted (`item`, `kind`, `equipped`, `acquired_at`) |
| `mail(db, steamid, {limit, now})` | inbox, unread first, expired rows hidden |
| `treeSlots(db, steamid)` | all 24 slots in order (`ornament: null` = empty), `filled`, `capacity` |
| `recentLedger(db, steamid, {limit})` | last N currency lines, newest first |
| `recentActions(db, steamid, {limit})` | the player's own queue rows, newest first |

---

## 7. The game-facing API (two routes, one secret)

Both sign with **the ingest's `SYNC_SECRET` and formula**, with the method word as
the second field:

```
X-FreeNova-Signature = sha256( secret + ":" + METHOD + ":" + path + ":" + ts
                               + ":" + nonce + ":" + hex(sha256(body)) )
```

* `path` is the request path only — `/api/game/pending` / `/api/game/ack`. The query
  string is **not** signed.
* `X-FreeNova-Timestamp` must be within ±300 s of the panel's clock.
* `X-FreeNova-Nonce`: 1–64 chars of `[A-Za-z0-9_.-]`. It is required, and it is not
  consumed from the `meta` nonce store: a replayed *read* is harmless, and the ack is
  idempotent by construction, so the timestamp window is the whole replay guard here.
* For a `GET` the body is empty, so the last field is
  `sha256("") = e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`.

A missing signature, a wrong one, a bad nonce or a stale timestamp is a `401` with
`{"ok":false,"error":"…"}`. An unconfigured secret is a `401` too.

### `GET /api/game/pending?steamid=STEAM_0:0:703`

Returns every action for that player the game has **not reported back on yet**
(`game_acked_at = 0`), in queue order — `applied` rows to mirror and `refused` rows
to skip and ack. Limit 32 by default.

Real request (harness, `test_harness.mjs` §12) and the real response:

```
GET /api/game/pending?steamid=STEAM_0:0:703
X-FreeNova-Timestamp: 1795385742
X-FreeNova-Nonce: g1k2j3
X-FreeNova-Signature: <sha256("test-only-secret:GET:/api/game/pending:1795385742:g1k2j3:<sha256("")>")>
```

```json
{
  "ok": true,
  "steamid": "STEAM_0:0:703",
  "season": "2026",
  "server_time": 1795385742,
  "count": 1,
  "actions": [
    {
      "id": 1,
      "kind": "claim_advent",
      "payload": { "day": 4, "gingerbread": 10 },
      "state": "applied",
      "idem": "advent:4",
      "error": "",
      "result": {
        "coins": null, "gingerbread": 10, "spins": null, "pass_xp": null,
        "item": null, "product": null, "day": 4
      },
      "created_at": 1795385742,
      "applied_at": 1795385742
    }
  ]
}
```

Field meanings: `state` is the **panel's** verdict; `result` is what the apply
produced (`coins`/`gingerbread`/`spins` are the new balances, `null` where that
currency was not touched — the game must not read `null` as zero); `error` is why the
panel refused. The game mirrors `applied` rows and acks the rest (§below).

### `POST /api/game/ack`

```jsonc
{"id": 1, "state": "applied"}
{"id": 1, "state": "refused", "error": "ornament id unknown to winterfest.ini"}
```

`state` must be exactly `applied` or `refused`; `error` is optional, ≤200 chars.
`id` is `winter_actions.id`. The ack never moves a balance — the apply already
happened.

Response, first report:

```json
{"ok": true, "id": 1, "state": "applied", "error": "",
 "game_acked_at": 1795385742, "already": false, "panel_state": "applied"}
```

Response, any repeat of the same ack:

```json
{"ok": true, "id": 1, "state": "applied", "error": "",
 "game_acked_at": 1795385742, "already": true, "panel_state": "applied"}
```

Idempotent by construction: the `UPDATE … WHERE game_acked_at = 0` **is** the claim,
so the first report wins and a replay returns the stored verdict instead of rewriting
it. `404` for an unknown id, `400` for a bad state or bad JSON, `401` for a bad
signature — all with `{"ok":false,"error":"…"}`. An acked action disappears from the
next pull.

### The AMXX loop, in words

1. every N seconds, `GET /api/game/pending?steamid=<player>` (signed);
2. for each action with `state == "applied"`: set the in-engine state to the
   balances/items in `result` (the panel already committed it — the game is
   reconciling, not deciding);
3. `POST /api/game/ack` `{"id":…, "state":"applied"}` — or `refused` with the reason
   if the engine could not mirror it;
4. `state == "refused"` rows are acked without applying anything.

---

## 8. Boot safety and migration

`server_local.mjs` execs `schema.sql` on **every boot** over the live database, so:

* every `CREATE`/`CREATE INDEX` is `IF NOT EXISTS`;
* `ALTER TABLE … ADD COLUMN` is not idempotent, so the four columns
  `winter_players` gained are **not** in a bare `ALTER` in `schema.sql`. A fresh
  database gets them from the `CREATE TABLE`; a live one is upgraded by the guarded
  `ALTER` in `src/state.js` `ensureStateSchema()` (line 208), which reads
  `PRAGMA table_info(winter_players)` first and runs once per DB object
  (`WINTER_COLUMNS`, `src/state.js`). Running it twice is a no-op, not an error —
  `test_harness.mjs` proves that with two handles over one file;
* `src/state.js` repeats the same DDL lazily (`STATE_DDL`), so a deployment that
  never execs `schema.sql` still gets the tables on the first queue/apply/read.

Verified against a copy of the live panel DB: boot created the four new tables, left
`winter_players` alone, and the first `getPlayer` added `spins, pass_xp, pass_tier,
premium` to the existing row without touching its data.

---

## 9. What the ingest still overwrites (read this before changing either side)

`POST /api/v1/server/stats` (the ingest, `src/sync.js`) is **unchanged**. It still
upserts `players.coins`, `players.xp`, `players.level`, `players.rank_id` and the
combat/battlepass/mission block straight from the game snapshot, under the
`last_seen` ordering guard.

That is deliberate, and it is the one place the contract's "the DB is authoritative"
is not yet the whole truth:

* **rank XP / level / rank_id** — game-owned. The panel therefore has no reward field
  for them: an action cannot pay rank XP, because the next push would overwrite it and
  the ledger would be lying. (`pass_xp` is a different counter and is panel-owned.)
* **coins** — both. The panel pays coins through the ledger; the next push re-states
  them from the game. Until the ingest stops writing `players.coins` (one column, one
  line in `src/sync.js`, plus the AMXX side that must then send its spend events as
  actions), the game remains the truth for coins at every push and a coins ledger
  rebuild is advisory.
* Every other column this layer owns (`winter_players`, `winter_inventory`,
  `winter_entitlements`, `winter_ledger`, `winter_actions`, `winter_tree`,
  `winter_advent`) has **no** ingest writer. Do not add one: a second writer breaks
  the ledger, and `src/state.js` is the only writer by contract.

The same note is in `src/index.js` directly above the ingest route, where whoever
edits it will see it.

---

## 10. What this layer deliberately does not have

* **No page tree.** No `/winter` route, no `src/winter/`, no layout, no CSS. Pages
  are the next layer and each one follows its own mockup.
* **No price book.** A `buy` carries its price (see §3); a shop catalogue becomes the
  page's source when it exists.
* **No mission/achievement ladder.** Those are the game's ini files, published
  through the signed push; the panel owns claim state only.
* **No game-side writer.** The AMXX side pulls and acks; it does not write a
  `winter_*` table.
