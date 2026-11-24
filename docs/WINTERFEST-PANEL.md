# Winterfest 2026 — the panel surface (`/winter`)

Owner: workstream 5 (`docs/WINTERFEST-WORKSTREAMS.md`). This document is the
contract between the game-side module (`winterfest_core.amxx`, `winterfest_gifts.amxx`,
`winterfest_menu.amxx`) and the browser surface. It says what the panel renders,
what it stores, **exactly which payload fields the game has to push**, and where
the two sides still have to meet.

Product contract: `docs/WINTERFEST.md` (§1 constraints, §4 Phase 1, §6 decisions).
Housing rules: `web-panel/HUB.md`. Data-format source of truth: `winterfest.ini`.

> **The game is authoritative. The panel is a mirror.** No page here grants a
> reward, moves an ornament, or decides a season date. Everything a player sees
> is either read from the mirror the game filled in, or computed from data the
> game published.

---

## 1. Routes

| Route | Page | Status |
| --- | --- | --- |
| `GET /winter` | December hub: days left, Advent progress, snowflakes, gifts, tree level + filled/24, pass tier + XP bar, three headlines | 200 |
| `GET /winter/tree` | the player's 24-slot tree, three styles, move form, set milestones | 200 |
| `GET /winter/tree/<steamid>` | somebody else's tree, **read-only**, same renderer | 200 (invalid steamid → 404) |
| `GET /winter/gifts` | counts by rarity, the last ten openings, link to the book | 200 |
| `GET /winter/ornaments` | the collection book: sets, owned/missing, secret entries, set unlock state | 200 |
| `GET /winter/advent` | the 24-day calendar, claimed/today/missed/locked, half-value rule | 200 |
| `GET /winter/pass` | 30 free-track tiers, current tier, next three rewards, `?full=1` = full ladder | 200 |
| `POST /winter/tree` | queue a tree move (`action=move&from=&to=`) or a style change (`action=style&style=`) | 303 queued · 403 refused |
| anything else under `/winter` | 404 page | 404 |

`?steamid=` accepts the packed (`0-0-12345`) and colon (`STEAM_0:0:12345`) forms;
`?compact=1` (and any GoldSrc user agent) selects the in-game skin exactly as it
does on the other products. Every page renders for a player the panel has never
seen — that is the zero state, and it says what to do in game.

**No-JS contract.** Every page is server-rendered and fully usable with
JavaScript disabled. The move form is two `<select>`s and a submit button; the
style switch is the same. JavaScript adds exactly two things, and only in a
browser (never in the compact MOTD skin): dragging a filled slot onto another
one (it posts the same form), and re-printing the season deadline in the
player's own timezone (server-side it always says Europe/Paris).

Authentication is the panel's existing one: reads need nothing, writes need the
`?t=` action token minted by the game (`src/sync.js` `checkActionToken`), and a
deployment that does not mint tokens (no `FN_LOCAL_TRUST`) shows
`NO_MINT_MSG` and refuses the POST with 403.

---

## 2. Tables (`web-panel/schema.sql`, mirror only)

All of them are `CREATE TABLE IF NOT EXISTS` — safe to run over the live replica,
which only gains tables and never has a row rewritten. `src/winter/store.js`
carries the same DDL and runs it lazily (once per DB object), so a deployment
that never execs `schema.sql` still gets them on the first push. The one
non-`CREATE` migration is guarded: `winter_gifts.reward_amount` is added with an
`ALTER TABLE` only when `PRAGMA table_info` says it is missing (`src/winter/store.js`
`ensureWinterTables`).

| table | key | holds |
| --- | --- | --- |
| `winter_players` | `steamid` | season stamp, snowflakes, gifts found, tree style (1 classic / 2 tall / 3 wide), tree level, ornaments total, advent claimed count, `seen_at` (stale-push guard) |
| `winter_tree` | `(steamid, slot)` | slot 1..24 → ornament id. Unique index on `(steamid, ornament)`: one ornament sits in at most one slot |
| `winter_ornaments` | `(steamid, ornament)` | ownership cache, `obtained_at`, `source` |
| `winter_gifts` | `id`, `UNIQUE (steamid, claim_key)` | the opening log: instance, rarity, reward type/id/**amount**, `opened_at`. A replayed push is a no-op |
| `winter_advent` | `(steamid, season, day)` | the claim ledger. **The primary key is the duplicate-claim guard** |
| `winter_pass` | `(steamid, season)` | pass XP + tier, monotonic (a stale push can never lower them) |
| `winter_meta` | `key` | `season` (the pushed `[season]` block as JSON) and `community` (the community goal) |

Idempotency rules, all of them exercised by `test_harness.mjs` §9:

* tree push = replace-all inside one transaction (the push is the whole truth);
* ornaments = `INSERT OR IGNORE`;
* Advent = `INSERT OR IGNORE`, a duplicate is counted and never rewrites the
  original `claimed_at`;
* gifts = `INSERT OR IGNORE` on the claim key;
* pass XP/tier = `MAX(stored, pushed)`;
* a snapshot older than `winter_players.seen_at` is skipped, not applied.

---

## 3. What the game pushes

### 3.1 The catalogue — **works today, no code change needed**

`sync.js` already stores any `catalogs.<key>` into the `catalog` table, so the
catalogue needs **no new hook**:

```jsonc
POST /api/v1/server/stats            // the existing signed push
{
  "players": [],                      // required by sync.js even when empty
  "catalogs": {
    "winterfest": {
      "version": 1,
      "season":    { "name": "Winterfest", "year": 2026,
                     "start": "2026-12-01 00:00", "end": "2026-12-24 23:59",
                     "advent_end": "2026-12-24 23:59", "enabled": 1 },
      "rarities":  [ { "id": 0, "name": "Common", "color": "190 220 255", "weight": 62 } ],
      "ornaments": [ { "id": 1, "name": "Crystal Snowflake", "rarity": 0, "set": 1, "hidden": 0 } ],
      "sets":      [ { "id": 1, "name": "Snowflakes", "title": "Ice Warrior", "snow": 100 } ],
      "advent":    [ { "day": 1, "type": "snow", "id": 0, "amount": 40 } ],
      "pass":      [ { "tier": 1, "xp": 300, "type": "snow", "id": 0, "amount": 100 } ],
      "tree":      [ { "style": 1, "name": "Classic", "slot": 1, "x": 50, "y": 10 } ],
      "community": { "key": "gifts", "label": "Presents opened", "current": 4321, "target": 10000 }
    }
  }
}
```

Every field is a **mechanical copy of a `winterfest.ini` row**, which is the
point: the game should serialise the ini, not invent a second format.

| payload field | ini row | notes |
| --- | --- | --- |
| `season.*` | `[season] name/year/start/end/advent_end/enabled` | dates digit-only (`20261201`) or `2026-12-01 [00:00]` — both parse |
| `rarities[].color` | `[rarity] id \| name \| R G B \| weight` | `"190 220 255"` **or** `"#bedcff"`; both accepted |
| `ornaments[].hidden` | `[ornament] id \| name \| rarity \| set \| hidden` | the panel's "never leak a name" flag; `secret` is accepted as an alias |
| `sets[].snow` | `[set] id \| name \| title \| bonus snowflakes` | `snowflakes` also accepted |
| `advent[].type/id/amount` | `[advent] day \| kind \| id \| amount` | kind = `snow \| pass \| ornament \| gift \| title` |
| `pass[].xp/type/id/amount` | `[pass] tier \| xp \| kind \| id \| amount` | `xp` is the cumulative floor |
| `tree[]` | `[tree] style \| name \| slot \| x \| y` | one row per slot, or `{style,name,slots:[{slot,x,y}]}`; the panel's built-in layouts are only a fallback |
| `community` | not in the ini | optional; the hub/gifts pages show it only when present |

`payload.catalogs.winterfest` replaces the whole document per push, so a content
pack update is one push (sync keeps the highest `version`).

### 3.2 Per-player state — **the one hook sync.js needs**

`sync.js` writes the columns it knows about; per-player Winterfest state needs
one additive call. `src/winter/store.js` exports it, so the change is one line,
placed next to the existing players upsert:

```js
import { applyWinterPayload } from "./winter/store.js"
// ...inside handleSync, after the player rows are stored:
await applyWinterPayload(env, payload, nowSec)
```

Expected block (either shape is accepted):

```jsonc
{
  "players": [...],
  "winter": {
    "season":    { ...same object as the catalogue's season, optional... },
    "community": { "label": "...", "current": 0, "target": 0 },
    "players": [
      {
        "steamid":        "STEAM_0:0:12345",
        "at":             1796000000,      // optional snapshot clock (stale guard)
        "season":         "2026",          // optional; defaults to the season block / stored value
        "snowflakes":     145,
        "gifts_found":    12,
        "tree_style":     2,               // 1 classic | 2 tall | 3 wide
        "tree_level":     3,               // the game's wf_tree_level()
        "ornaments_total": 5,
        "advent_claimed": 7,
        "tree":      [ { "slot": 3, "ornament": 2 } ],       // or {"3": 2} — the WHOLE tree
        "ornaments": [ 1, 2, 3, 4, 5 ],                      // owned ids (additive is fine)
        "advent":    [ { "day": 1, "at": 1796000000 } ],     // or [1,2,3] or "1,2,3"
        "gifts":     [ { "instance": 41, "rarity": 1, "type": "ornament",
                         "id": 2, "amount": 0, "at": 1796000000, "key": "gift#41" } ],
        "pass":      { "xp": 1050, "tier": 3 }
      }
    ]
  }
}
```

A per-player `winter` object inside `payload.players[]` is accepted too, so the
game can push it either way (`{ "players": [ { "steamid": "...", "winter": {...} } ] }`).

`gifts[].key` (or `instance`) must be stable per opening — that is what makes a
retried push a no-op. The reward is `type/id/amount` exactly like an
`[open]` pool row.

### 3.2b The `WINTERFEST-DEV.md` §9 shape is accepted too

`docs/WINTERFEST-DEV.md` §9 (written after this surface was designed) describes
the payload the core agent has in mind: one **rendered** blob per player —
`winterfest: { season, wallet, presents, ornaments, sets, tree, advent, pass,
titles }` with `reward_text`, `claimable`, `filled` and `slots[].ornament_id`.

`src/winter/devshape.js` translates that into exactly the same internal rows, so
the panel works whichever shape ships first, and there is still one source of
truth: everything is copied from the payload, nothing is derived from what the
panel thinks the ini says. Specifically:

* `wallet.snowflakes` → `winter_players.snowflakes`;
* `tree.style/level/slots[].ornament_id` → style, level and `winter_tree`;
* `ornaments[].owned === true` → the ownership cache (the rest are *not* owned);
* `presents[]` → the gift log, **only** the ones with `opened === true`;
* `advent[].claimed === true` → the claim ledger (`claimable` is never a claim);
* `pass.xp/tier` → `winter_pass`;
* its `ornaments[]/sets[]/advent[]/pass[]` rows become a **fallback catalogue**
  in `winter_meta.catalog`, used only when `catalogs.winterfest` has not been
  pushed — so the book, the calendar and the ladder still print the game's own
  names and reward text instead of "not published yet".

Both shapes may be pushed in the same payload; the last write for a player wins,
which is the same rule the rest of the mirror follows.

§9 also says a drag or a claim "must go through `wf_tree_set_slot` /
`wf_advent_claim` so the ledger stays the only record". The panel already does
exactly that: it queues `wf_tree_move` (§3.3) and never writes player state.
Advent claims are not offered on the panel at all — the calendar says "claim in
game", which is the same rule.

### 3.3 Coming back from the panel: two action types

The panel never changes player state. A move or a style change is queued in the
existing `actions` table by `src/winter/store.js` (`queueWinterAction`, token
checked with sync's own `checkActionToken`) and the tree page says
"queued — the game applies it on its next save".

| `actions.type` | `actions.arg` | the game should do |
| --- | --- | --- |
| `wf_tree_move` | `"9:12"` = from slot 9 to slot 12 | `wf_tree_set_slot(id, 12, wf_tree_slot(id, 9))`, then clear slot 9 (a taken target swaps; the panel's copy says so) |
| `wf_tree_style` | `"1"` \| `"2"` \| `"3"` | `wf_tree_set_style(id, style)` (the native already exists) |

Until the game handles them, the rows simply sit `pending` and expire like any
other action; nothing in the mirror changes, so the page never lies about what a
player owns.

---

## 4. The Christmas skin

`src/winter/skin.js` is a **response-level** layer applied in `src/index.js`'s
`fetch` wrapper. It is not a page template and it does not touch any page's
markup:

* inside the season window it appends one `<style>` block (the last stylesheet
  in the document, so it wins on equal specificity) and one decorative snow line
  after `<body>`: cranberry / pine / candle-gold / icy-blue palette over the
  existing classes;
* outside the window — including `enabled = 0` — it returns **the same response
  object it was given**, so the panel is byte-for-byte unchanged. The harness
  asserts this by stripping the injected sheet and the snow line and comparing
  to the page rendered with the season shut;
* it never runs for JSON or non-200 responses;
* the injected CSS keeps the GoldSrc rules: solid hex only, no custom
  properties, no flex/grid, no images, no web fonts, no second request.

The switch is read as follows: **on/off** — `env.WINTER_ACTIVE`, then the `meta`
row `winter.active`, then the season the game pushed (`enabled`), then on by
default; **dates** — the season the game pushed (`winter_meta.season`), then the
`meta` rows `winter.start` / `winter.end` / `winter.advent_end`, then the
documented default window. The game is the source of truth for the dates, and
the panel-side key exists so staff can shut the season off (or test it) without
a redeploy.

**The default window is 1 December 00:00 → 24 December 23:59 Europe/Paris**
(owner decision §6.3), so the skin turns itself on and off with no configuration
at all. A missing `winterfest.ini`, a disabled season or an empty database each
leave the panel exactly as it is today.

---

## 5. What this surface still needs from the other workstreams

1. **`sync.js`: the one-line `applyWinterPayload` hook** (§3.2). Without it the
   pages render the honest zero state; nothing breaks. The hook takes either the
   panel's raw shape or `WINTERFEST-DEV.md` §9's rendered one (§3.2b).
2. **The game pushes the catalogue** (§3.1) — otherwise the ornament book, the
   Advent rewards and the pass ladder say "not published yet" instead of
   inventing entries. The panel's three tree layouts are the only content it
   carries on its own, and even those are overridden by `[tree]`.
3. **The game consumes `wf_tree_move` / `wf_tree_style`** (§3.3) for the tree
   page to be more than a viewer.
4. **A Winterfest row in the `/` panel directory** (`src/ui.js` `pageHub`) and,
   if the MOTD should link there, in `src/motd.js` — both files belong to other
   owners here. `src/pages.js` `pageHome` already lists `/winter` (the one link
   this workstream is allowed to add there).
5. **`hidden` stays a panel/menu flag.** `winterfest_core.amxx` does not read the
   fifth `[ornament]` column; the panel does, and that is where "? ? ?" lives.

---

## 6. Verification

`cd web-panel && node test_harness.mjs` — 239 checks before this surface, 367
after (128 new), 0 failures. The 239 baseline also still passes on its own: the
previous revision of `test_harness.mjs` runs green against this source tree. The winter section (§9 of the harness) asserts, on
real databases and real HTTP:

* the season window arithmetic with a fixed clock (before / open / last day /
  closed / disabled / custom dates / digit-only keys);
* catalogue parsing from the real `winterfest.ini` shapes (R G B colours,
  `hidden`, `snow`, the `amount` column, three 24-slot layouts);
* Advent states (claimed / today / missed / locked, full vs half value) and the
  pass ladder;
* the store: table creation twice, a push landing, a duplicate Advent claim
  refused without rewriting `claimed_at`, a replayed gift refused, a stale
  snapshot unable to lower pass XP, one ornament unable to occupy two slots, an
  unseen player and a malformed steamid;
* every route over HTTP, the unseen player, the empty tree (24 empty slots), the
  stranger's read-only tree (no form, none of the owner's ornaments), the secret
  ornament name never printed, the completed set's title printed, an empty gift
  log pointing at `/christmas`, 30 pass rungs and no premium wording;
* the move action: 403 without a token, 403 for an empty slot, 303 queued with
  the right `arg`, deduplicated, mirror untouched until the game confirms;
* the skin: inert in a past window, byte-identical after stripping when on,
  `enabled = 0` inert even inside the dates, JSON untouched, default window
  followed when nothing is pushed.
