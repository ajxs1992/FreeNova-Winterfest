# WINTERFEST-DEV.md — the developer's map of the Winterfest server module

Phase 1, server side. The product contract is `docs/WINTERFEST.md` (what we can
ship on GoldSrc, and the owner's four decisions in §6); the content pack's own
map is `docs/WINTERFEST-CONTENT.md`. This file is the code-side map: files,
natives, storage, config, how to extend it, and what was deliberately left out.

Written 2026-11-22 for the December 1st product. It is meant to be enough to add
an ornament or a present spot without opening a `.sma`.

---

## 1. What Phase 1 is

Three plugins, one config file, zero client assets.

**Two decisions landed after the first cut and are in this build** (authority:
`docs/WINTERFEST.md` §6, rewritten, and §7):

* **Advent is a strict one-day window.** Day *n* is claimable on its date only;
  afterwards it is *expired*, not discounted (the half-value catch-up is
  withdrawn). The **Advent Pass** entitlement unlocks the whole calendar at once.
* **The Battle Pass has a premium track.** It is an **entitlement**, never a
  gameplay grant: `[pass_premium]` carries the rewards, `[entitlement]` carries
  the product ids, and nothing pays without ownership.

**The clock is Europe/Paris, everywhere** (owner decision §6.4): the daily spin,
the Advent unlock, the pass rollover and the day boundaries all read the
*server's* local date, so the host must run `TZ=Europe/Paris`. The core prints the
offset at boot so a wrong host is obvious immediately:

```
[WF] clock: local 2026-11-22 21:05, UTC+1 (Europe/Paris is +1 in winter, +2 in summer - the host must run TZ=Europe/Paris)
```

There is no per-player timezone and no UTC fallback: one constant, one clock.

**The currency is GingerBread** (owner naming, 2026-11-22; id `gb`). It was
called *snowflakes* earlier in the same week: `wf_get_gingerbread` /
`wf_add_gingerbread` are the canonical natives, `wf_get_snowflakes` /
`wf_add_snowflakes` still work as deprecated aliases, the vault key is `wf_gb_*`
with a fallback that reads the old `wf_snow_*` record, and the ini accepts both
`gingerbread` and the legacy `snow` in a reward-kind column. "Snowflakes" also
survives as the *ornament set* name (set 1), which is content and has nothing to
do with the currency.

| plugin | owns |
| --- | --- |
| `winterfest_core.amxx` | every piece of state: GingerBread (the soft currency, id `gb`), **spins**, presents, ornaments, the tree grid, advent claims, Winter Pass XP/tier, set titles, the envelope's pending counter. Every payoff goes through one idempotent grant path. Operator commands. |
| `winterfest_gifts.amxx` | presents in the world (stock-sprite glow, walk-over pickup, respawn), the death-drop snowflake pouch, and the `/opengift` theatre. |
| `winterfest_menu.amxx` | `/christmas` and the seven entries behind it. No state of its own. |

Everything a player can do is **engine messages, stock sprites and data**:
`docs/WINTERFEST.md` §1.1 explains why nothing else is possible until fastdl
works. There is exactly **one** new precache entry in the whole module
(`sprites/glow01.spr`); `sprites/laserbeam.spr` was already in the table via
`freenova_cosmetics`, so it is free. See `docs/PRECACHE-BUDGET.md`.

Not in this build: the panel (`web-panel/**`, another workstream), seasonal
missions and 12-day windows (`events.ini` / `missions.ini`, Phase 2), and any
model, sound or map (Phase 3, blocked on fastdl).

---

## 2. Files

```
game-server/cstrike/addons/amxmodx/
  scripting/winterfest_core.sma        state + ledger + natives + admin commands
  scripting/winterfest_gifts.sma       world presents, pouch, opening theatre
  scripting/winterfest_menu.sma        /christmas and friends
  scripting/include/winterfest.inc     the shared vocabulary: constants, natives,
                                       three stocks (field splitter, list test, chat)
  configs/freenova/winterfest.ini      ALL data. The only file the plugins open.
  plugins/winterfest_*.amxx            build output (tools/compile-plugins.sh)
docs/WINTERFEST-DEV.md                 this file
tests/winterfest/wf_scenario.sma       the scripted scenario (+ .expect, .commands)
tests/winterfest/wf_scenario_generic.expect   the same scenario on a map with no rows
```

`configs/freenova/winterfest/` (`season.ini`, `ornaments.ini`, `presents.ini`,
`advent.ini`, `pass.ini`, …) is the **content pack**: source material authored by
another workstream, merged into `winterfest.ini` (see §4.1). The plugins never
open that directory.

### 2.1 Load order (plugins.ini)

```ini
winterfest_core.amxx
winterfest_gifts.amxx
winterfest_menu.amxx
```

Order matters twice: `winterfest_menu` checks `LibraryExists("winterfest_gifts")`
in `plugin_init` to decide whether it must register its own `/opengift` fallback,
and the core's `wf_reload` asks the gifts module to re-read its spots. Reversed
order still works, it just degrades: no fallback check, no immediate re-spawn.

### 2.2 The dependency rule: self-pause, never crash

Every module except the core treats the core as optional:

* `plugin_natives()` installs `set_native_filter()`; an unresolved `wf_*` native
  degrades to `0` instead of failing the load with a bad load.
* `plugin_init()` checks `LibraryExists("winterfest_core")` and calls
  `pause("d")` with one log line:

```
[winterfest_gifts.amxx] [WF-GIFTS] winterfest_core missing - pausing self (no presents this map)
[winterfest_menu.amxx]  [WF-MENU] winterfest_core missing - pausing self (/christmas is not advertised)
```

Proof (harness, `--profile freenova`, core removed from `plugins.ini`): both
plugins show as `stopped`, nothing bad-loads, no run-time errors, the map runs
and the server behaves exactly like one without Winterfest. A missing
`winterfest_gifts` additionally makes `winterfest_menu` register a `/opengift`
fallback, so a player holding a present can still open it — without the theatre.

A missing or unreadable `winterfest.ini` is **not** an error either: the module
loads, `wf_season_open()` returns false, everything downstream goes quiet, and
one line records why.

---

## 3. The grant path (read this before touching rewards)

There is exactly one function that can move currency, inventory or XP:
`WfApplyReward()` in `winterfest_core.sma`. There is exactly one public way in:

```
wf_grant(id, reward_type, reward_id, claim_key[])
```

* `claim_key` **non-empty** — a reward. The key is hashed (CRC32) together with
  the season year, the player's authid and the player's reset epoch, and written
  to the vault **before** the reward is applied or announced. A second call with
  the same key returns `WF_GRANT_DUPLICATE (0)` and pays nothing. A reconnect, a
  retry, two `/opengift` in the same second, or two code paths racing for the
  same present cannot double-pay.
* `claim_key` **empty** — an operator action (`wf_give`). Applied every time and
  logged with `[WF] operator grant`. Two identical `wf_give` lines mean two
  grants; that is the point of typing it twice.

Trade-off, on purpose: because the key is written first, a crash in the
microseconds between the write and the apply loses that one reward. It can never
pay twice. Fail closed.

Reward kinds (`reward_id` meaning in brackets):

| constant | value | `reward_id` is |
| --- | --- | --- |
| `WF_REWARD_GINGERBREAD` | 1 | how much GingerBread (`WF_REWARD_SNOWFLAKES` is the deprecated alias) |
| `WF_REWARD_ORNAMENT` | 2 | ornament id |
| `WF_REWARD_GIFT` | 3 | present rarity 0..2 |
| `WF_REWARD_PASS_XP` | 4 | how much pass XP |
| `WF_REWARD_TITLE` | 5 | ornament-set id |
| `WF_REWARD_SPINS` | 6 | how many spins |
| `WF_REWARD_COINS` | 7 | how many Coins — paid through BattlePass' own once-only path (`menabp_add_coins_once`, guarded by `LibraryExists("menabp")`); with no BattlePass it pays GingerBread and logs why |

Claim keys in use today (all of them are composed by the caller and hashed by the
core, so they can be long and readable):

| where | key |
| --- | --- |
| present pickup | `spot#<map>#<spot>#<round>` |
| present opening | `open#<present instance>` |
| snowflake pouch | `pouch#<pouch id>` |
| advent day | `advent#<day>` (same key with and without the Advent Pass) |
| daily spin | `spin#<YYYYMMDD>` |
| free pass tier | `pass:<tier>:free` |
| premium pass tier | `pass:<tier>:premium` |
| entitlement | the caller's claim key (e.g. `order:<order_id>`) |
| set completion | `set#<set id>` (title), `setbx#<set id>` (snow) |
| ornament ownership | `orn#own` |

---

## 4. The config: `configs/freenova/winterfest.ini`

One file, sections read by two plugins. Format: `;`/`#` comments, `[section]`
headers, `a | b | c` rows, `key = value` inside `[season]` and `[pouch]`.
Unknown sections and unknown keys are ignored, so documenting a key in the file
is always safe.

Rows are bounded by the `WF_MAX_*` caps in `include/winterfest.inc`; a row that
does not fit is **logged and skipped**, never fatal. `wf_reload` on the console
re-reads it live (and asks `winterfest_gifts` to re-spawn its spots).

| section | reader | what it holds |
| --- | --- | --- |
| `[season]` | core | name, year, date window, advent deadline, enabled |
| `[rarity]` | core + gifts | 3 rarities: name, colour, spawn weight |
| `[visual]` | core | what every prop looks like: name, kind, asset, colour, scale, fallback |
| `[props]` | core | which `[visual]` row each prop slot uses |
| `[ornament]` | core | the catalogue: id, name, rarity, set |
| `[set]` | core | secret collections: id, name, collector title, bonus snow |
| `[tree]` | core | 3 tree styles × 24 slot coordinates for the panel |
| `[open]` | core | what is inside a present, per rarity |
| `[pouch]` | gifts | death-drop pouch: snow, life, enable |
| `[presents]` | gifts | present spots per map |
| `[advent]` | core | 24 calendar days, a strict one-day window each |
| `[pass_premium]` | core | the paid track: 30 tiers, its own rewards |
| `[entitlement]` | core | the product catalogue (premium track, Advent Pass) |
| `[pass]` | core | 30 free tiers |

### 4.1 Content-pack merge

`docs/WINTERFEST-CONTENT.md` §9 is the authoritative merge table. In short:
**replace sections, never append** — the ornament ids are a namespace shared with
the panel and with the `[advent]`/`[pass]` rows, so two catalogues side by side
produce wrong set totals and rewards that name the wrong ornament.

What was merged into `winterfest.ini` in this build:

| section | source | rows |
| --- | --- | --- |
| `[season]`, `[pouch]` | `winterfest/season.ini` | 7 keys + 3 keys |
| `[ornament]`, `[set]` | `winterfest/ornaments.ini` | 30 + 6 |
| `[advent]` | `winterfest/advent.ini` | 24 |
| `[pass]` | `winterfest/pass.ini` | 30 (23 700 XP total) |
| `[presents]` | `winterfest/presents.ini` (generated) | 186 map rows + 8 `*` rows |

`[rarity]`, `[visual]`, `[props]`, `[tree]` and `[open]` are owned by this module
(the pack has no version of them). The `*` rows must stay **last** in
`[presents]`: the loader decides once, on the first matching row, whether a map
uses its own rows or the generic set, so a `*` row placed first would silently
disable every map's rows.

Re-merge after a pack update by replacing the **rows** of `[ornament]`, `[set]`,
`[advent]`, `[pass]` and the per-map rows of `[presents]`, keeping the prose
blocks, the `[visual]`/`[props]`/`[tree]`/`[open]` sections and the trailing `*`
block. A pack update that adds a map (it did: `de_tuscan`) changes only
`[presents]`.

### 4.2 How to add an ornament

1. Append to `[ornament]` with the **next free id** — never renumber, never
   insert: an id is stored in a player's data and mirrored by the panel, so a
   renumber changes what an already-granted reward was.

   ```ini
   31 | Frozen Mistletoe | 1 | 7 | 0
   ```

   Columns: `id | name | rarity | set | hidden`. `set` points at a `[set]` row
   (0 = no set). `hidden = 1` means the menus and the panel show `? ? ?` until
   the player owns it — the core does not read that column yet, the readers do.
2. If the set you named is new, add the `[set]` row too:

   ```ini
   7 | Winter Wood | Mistletoe Monarch | 150
   ```
3. If you want it reachable, name it in an `[advent]`/`[pass]` row
   (`ornament | 31 | 0`) or let `[open]` roll it: a pool row with
   `ornament | 0 | 0 | 0 | <weight>` hands out *any unowned ornament of that
   present's rarity*, so a new ornament of an existing rarity needs no config at
   all to become findable.
4. `wf_reload` on the console, then `/ornaments` on the server: the new row is at
   the end of the catalogue. Nothing to recompile.

### 4.3 How to add a present spot

Two ways, both one row in `[presents]`:

```ini
; hand-placed, walked to in game
de_dust2 | -1360 2400 0 | 2 | 180

; or anchored on a spawn (always inside the playable area)
de_inferno | @ct3 | 1 | 120
```

`map | origin | rarity | respawn`:

* `map` — the `.bsp` name without extension, or `*` for the generic fallback set.
* `origin` — `x y z`, or a spawn reference resolved **at spawn time** against the
  map's own entities: `@spawn<N>` (the Nth player spawn of any class), `@t<N>`,
  `@ct<N>`, `@start<N>`, `@dm<N>`. `@t`/`@ct` fall back to the class CS 1.6 maps
  actually use (`info_player_deathmatch` is de_dust2's T spawn,
  `info_player_start` is its CT spawn — measured, not assumed).
* `rarity` — `0`, `1`, `2`, or `?` to roll from the `[rarity]` weights.
* `respawn` — seconds until the spot comes back (clamped 10..900).

Rules:

* a map with **at least one row of its own** uses only its own rows;
* a map with **no rows** uses the `*` set (8 spots);
* if even `*` is missing, a built-in set of 8 spawn-derived spots is used.
  A map never has zero presents.
* 6–10 spots per map, default 8 (owner decision §6.4). The boot log states the
  count **and** whether it satisfies the rule:

  ```
  [WF-GIFTS] 7 present spot(s) on de_dust2 from map rows - ok (rule: 6-10, default 8)
  ```

* a map that is not in `[presents]` at all (a new map added to the rotation, or
  `de_tuscan` before the pack was regenerated) simply gets the generic set — it
  never produces a spot at the origin. Resolved origins are sanity-checked:
  `(0,0,0)` (what an entity that failed to spawn reports) and anything past
  ±8000 units is refused.

* `wf_dump_spawns` on the server console prints the current map's player spawns
  as ready-to-paste rows — that is how the shipped numbers were obtained.
* a hand-placed coordinate cannot be verified by the server: walk to it yourself,
  then check it with a harness boot. A spot in the void floats where nobody can
  reach it and nothing will complain.

### 4.4 How to change what a prop looks like (visual ids)

Nothing in the plugins hardcodes a sprite or a model. `[visual]` is a table of
named looks and `[props]` says which look each prop uses:

```ini
[visual]
; name | kind | asset | colour | scale | fallback
sprite_glow_rare   | sprite_glow   | sprites/glow01.spr          | 255 215 90 | 1.00 | -
present_classic    | model_present | models/present1.mdl         | - | 1.00 | sprite_glow_rare

[props]
present_rare = sprite_glow_rare
```

* `sprite_glow` — a stock sprite: usable today, and the only thing Phase 1
  precaches (`sprites/glow01.spr`, one new precache item; see
  `docs/PRECACHE-BUDGET.md`).
* `model_present` — a client model from the owner's pack
  (`thirdparty/winterfest-assets/README.md`, registry names `present_classic`,
  `tree_classic`, `tree_green`, `c4_xmas`). **Unusable while `wf_allow_models`
  is 0** or while the file is not on disk, and unusable means the prop resolves
  down its `fallback` chain.
* the six prop slots are `present_common`, `present_uncommon`, `present_rare`,
  `pouch`, `tree`, `c4`. `tree` and `c4` have no sprite fallback in Phase 1, so
  they resolve to nothing and are named in one boot line:
  `[WF] 4 of 6 prop slot(s) drawable now; waiting for downloads: tree, c4`.
* a module that draws a prop asks the core, never the file:
  `wf_visual_id("c4")` → `wf_visual_asset()` / `wf_visual_colour()` /
  `wf_visual_scale()` / `wf_visual_is_model()`. That is how `winterfest_atmos`
  gets the Christmas C4 without naming a model.

**The Phase 3 switch is config, not code:**

1. upload the models to fastdl (ops);
2. `configs/plugins/wf_gifts.cfg`: `wf_allow_models 1` (read in
   `plugin_precache`, which is why it lives in that file and not in `amxx.cfg`);
3. point the slots at the model visuals:
   `present_common = present_classic`, `present_uncommon = present_classic`,
   `present_rare = present_classic`, `tree = tree_classic`, `c4 = c4_xmas`.

The model paths the engine is told about live in one table in
`winterfest_gifts.sma` (`g_szModelAssets`); all four of the pack's models are
already in it, so no recompile is needed for any of them. A *new* model file is
one line in that table plus one `[visual]` row.

### 4.5 Advent: a strict one-day window, and the Advent Pass

Day *n* unlocks on its Europe/Paris date, is claimable **that day only**, and
after midnight it is **expired** — not discounted (the half-value catch-up that
was in the first cut is withdrawn). `wf_advent_state(id, day)` answers honestly:

| value | meaning |
| --- | --- |
| `WF_ADVENT_TODAY` | today is its date: claimable now |
| `WF_ADVENT_EXPIRED` | its date has passed and it was not claimed |
| `WF_ADVENT_LOCKED` | its date has not arrived |
| `WF_ADVENT_CLAIMED` | already claimed |
| `WF_ADVENT_UNLOCKED` | claimable now because the player owns the Advent Pass |

`wf_advent_claim()` returns the same truth (`WF_ADVENT_CLAIM_OK / _CLAIMED /
_EXPIRED / _LOCKED / _INVALID`), so a caller never has to guess why a claim was
refused. The record of what was missed is kept — the claimed-day list plus the
stored date is enough for the panel's illustrated village and for the Advent Pass
to show the whole track.

**The Advent Pass** (`advent_pass_2026` in `[entitlement]`) makes every day
claimable at once, including days that have not arrived. The claim key is still
`advent#<day>`, so a day pays at most once whether it was claimed on time or
through the pass. Nothing buys it in game — the panel sells it, and it arrives as
an entitlement (§4.6).

### 4.6 The premium track, and what an entitlement is

`[pass]` is the **free** track and is unchanged. `[pass_premium]` is the paid one:
the same 30 tiers and the same XP thresholds, its own reward rows, its own claim
key (`pass:<tier>:premium` vs `pass:<tier>:free` — they can never collide).

Premium is an **entitlement**, not a flag and not a column:

* `[entitlement]` lists the products (`product id | display name | kind`):
  `bp_premium_2026`, `advent_pass_2026`. Gameplay only ever asks
  `wf_has_entitlement(id, "bp_premium_2026")`; it never asks how the player got
  it, and it never charges anything.
* `wf_grant_entitlement(id, product, source, claim_key)` is the **only** door
  ownership comes through — a paid order, a manual admin grant, or an automatic
  in-game grant. The claim key is the idempotency record (`order:<order_id>` for
  a fulfilment), so a replayed push cannot grant twice.
* A premium tier is refused (`WF_GRANT_INVALID`) while the entitlement is missing,
  and paid once when it is there. **Buying mid-season back-pays every premium tier
  already reached** — a purchase is not a downgrade — and each claim key keeps
  that to one payment per tier.
* Storage is one string per player: `wf_ents_s<year>#<auth>` =
  `product@source,...`. The source is kept so an operator can answer "who gave
  this player the pass, and when".

In game, `wf_ent <target|all> <product> [source]` is the manual grant (admin
level, logged, idempotent per player+product).

**What the panel must push for ownership to appear in game.** Two halves, and
only the second one touches this module:

1. the panel's own `entitlements` row (`steamid, product_id, season, granted_at,
   source, order_id`) is the display record — that is `docs/WINTERFEST.md` §7, and
   it is the panel's business;
2. the game server has to *learn* about it, because ownership lives in the game's
   per-player vault. The push is one call per product:
   `wf_grant_entitlement(id, "<product id>", "panel", "order:<order_id>")`, made by
   whatever bridge already runs panel actions — or, until that bridge exists, by
   an operator with `wf_ent`. An entitlement granted while the player is offline
   cannot be written in game (there is no player to write it for), so the bridge
   must queue the call and make it when that steamid connects; the claim key makes
   a repeated push harmless. A product id that is not in `[entitlement]` is
   refused with a log line, which is the guard against a panel typo silently
   owning nothing.

### 4.7 How to change the reward pools, advent days, pass tiers, tree layout

* `[open]` — `rarity | kind | id | min | max | weight`. `min`/`max` are the roll
  range for `snow` and `pass`; `id` is the catalog id for `ornament`/`gift`/
  `title`. A present that would roll an ornament you already own pays snow
  instead, so a present is never a dud. The pass-XP amounts are calibrated
  against `[pass]`'s 24 000 XP curve — change them together or the pass stops
  being reachable.
* `[advent]` — `day | kind | id | amount`, days 1..24, one row each.
* `[pass]` — `tier | xp | kind | id | amount`, `xp` is **cumulative**, strictly
  increasing (the loader clamps a backwards row and logs it). Tier 1 is 0 XP, so
  every player starts at tier 1 and its reward is paid on the first sync.
* `[tree]` — `style | name | slot | x | y`, x/y are percentages 0..100 of the tree
  box; 24 slots per style. A fourth style needs `WF_MAX_STYLES` bumped in the
  include plus 24 rows.

### 4.8 Season rollover (December 2027)

1. `[season]`: `year = 2027`, `start`/`end`/`advent_end` to the new window.
2. Nothing else. Every vault key and every claim key is stamped with `year`, so
   the new season starts empty; last year's record stays on disk untouched (an
   operator who really wants it back sets `year` back to 2026).

---

## 5. Storage: the nvault schema

Vault name `freenova_wf` (its own file, separate from `freenova_bp`, so nothing
here can collide with `bpxp`/`level`/`credits` and an operator can back up or
delete Winterfest without touching progression).

Every data key is built by `WfKey()`:

```
wf_<base>_s<season year>#<authid with ':' -> '_'>

wf_snow_s2026#STEAM_0_0_12345
wf_gifts_s2026#STEAM_0_0_12345
```

The `_s<year>` stamp mirrors `BpCursorKey` in `battlepass_core.sma`. Keys are
refused (write skipped, loud log) if they would reach 64 characters — a
truncated key would silently alias another player's record.

| base | value | type |
| --- | --- | --- |
| `gb` | GingerBread balance | int (`0..2 000 000 000`, clamped). A record written before the rename lives under `snow` and is read as a fallback |
| `spins` | spin balance | int |
| `pending` | reserved for the envelope (workstream 15) | int, round-tripped, written by the envelope |
| `ents` | entitlements owned: `product@source,product@source` | csv, max 8 products |
| `pass` | Winter Pass XP | int |
| `tree` | tree level = 1 + completed sets | int |
| `gseq` | present instance counter | int |
| `style` | tree style id (1..3) | int |
| `gifts` | present inventory: `instance:rarity,instance:rarity` | csv, max 16 |
| `orn` | owned ornament ids: `1,4,7` | csv, max 64 |
| `advent` | claimed days: `1,2,3` | csv, max 31 |
| `titles` | completed set ids: `1,3` | csv, max 8 |
| `slots` | tree grid: `slot:ornament,slot:ornament` | csv, max 24 |
| `epoch` | reset counter (see below) | int |

Claim ledger keys live in the same vault:

```
wf_claim_s<year>#<authid>#e<epoch>#<crc32 of the caller's claim key> = "1"
```

`e<epoch>` is what makes `wf_reset` cheap: bumping the epoch retires every claim
the player ever made **without enumerating the vault** (nvault has no key
iterator), so a reset player can earn everything again and nothing from before
can be re-claimed.

One save path: `WfSave(id, force)` writes every field above and nothing else
writes to these keys. Autosave runs every 30 s over the players flagged dirty;
`client_disconnected` and `plugin_end` flush unconditionally. Loading is
`WfLoad(id)` on `client_putinserver` (with three retries if the authid is still
`STEAM_ID_PENDING`) and it ends with a **repair pass** (`WfSyncTiers`,
`WfSyncSets`) that pays any tier or set whose claim key is missing — idempotent,
so logging in twice never pays twice.

---

## 6. Natives

Registered by `winterfest_core.amxx` (`register_library("winterfest_core")`),
declared in `include/winterfest.inc`. Read the include for the exact signatures;
this is the map of what exists and why.

| group | natives |
| --- | --- |
| season | `wf_season_open`, `wf_season_name`, `wf_season_window` |
| currency | `wf_get_gingerbread`, `wf_add_gingerbread`, `wf_grant` (aliases: `wf_get_snowflakes`, `wf_add_snowflakes`) |
| spins | `wf_get_spins`, `wf_add_spins`, `wf_consume_spin` |
| envelope hook | `wf_get_pending` |
| ornaments | `wf_grant_ornament`, `wf_has_ornament`, `wf_ornament_count`, `wf_ornament_total`, `wf_ornament_name`, `wf_ornament_rarity`, `wf_ornament_set` |
| tree | `wf_tree_level`, `wf_tree_style`, `wf_tree_set_style`, `wf_tree_slot`, `wf_tree_set_slot`, `wf_tree_filled`, `wf_tree_slots`, `wf_tree_next_set`, `wf_tree_style_count`, `wf_tree_style_name`, `wf_tree_slot_x`, `wf_tree_slot_y` |
| sets | `wf_set_count`, `wf_set_name`, `wf_set_title`, `wf_set_owned`, `wf_set_total` |
| pass | `wf_get_pass_xp`, `wf_get_pass_tier` (canonical, workstream 14), `wf_pass_next_xp`, `wf_pass_max_tier`, `wf_pass_tier_xp`, `wf_pass_tier_reward`, `wf_pass_tier_reward_premium`, `wf_claim_pass_tier`, `wf_pass_premium_unlocked`, plus the aliases `wf_pass_xp` / `wf_pass_tier` |
| advent | `wf_advent_today`, `wf_advent_state`, `wf_advent_claim`, `wf_advent_claimed` |
| entitlements | `wf_has_entitlement`, `wf_grant_entitlement`, `wf_entitlement_count`, `wf_entitlement_name`, `wf_entitlement_label` |
| presents | `wf_gift_count`, `wf_gift_instance`, `wf_gift_rarity`, `wf_open_gift` |
| names | `wf_rarity_name` |
| visuals | `wf_visual_id`, `wf_visual_is_model`, `wf_visual_asset`, `wf_visual_colour`, `wf_visual_scale`, `wf_visual_count` |

`winterfest_gifts.amxx` registers one more (`register_library("winterfest_gifts")`):
`wf_gifts_open(id, instance)` — the opening theatre; `winterfest_menu` calls it and
falls back to `wf_open_gift` when it is missing.

`winterfest_menu.amxx` registers `winterfest_menu` as a library so a future
module can ask "is there a UI for this?" — it exposes no natives.

Notes worth knowing before you call one:

* every `id` parameter is a **client index 1..MaxClients**; 0 or 33 returns
  `0`/`WF_GRANT_NOTLOADED`, never an error and never a crash;
* `WF_GRANT_NOTLOADED` means the player's vault record is not in memory yet (join
  within ~0.5 s) — retry, do not treat it as a refusal;
* `wf_advent_claim` is date-gated: future day → `WF_GRANT_INVALID`, missed day →
  half value, already claimed → `WF_GRANT_DUPLICATE`;
* `wf_open_gift` is the only way to open a present, and it is idempotent per
  present instance.

---

## 7. Runtime design of the gifts module

**Present spots.** `env_sprite` entities using `sprites/glow01.spr`, colour and
scale from the `[rarity]` row. They exist for the eye only.

**Pickup.** One repeating 0.2 s task walks the spot list (≤ 16) and the human
player list and compares **squared distances** (60 units). On a 10-spot map with
32 players that is 320 float subtractions twice a second — nothing next to what
the engine does per frame — and it needs no traceline, no per-player per-spot
task and no entity think hook. The alternative (`env_sprite` + traceline per
frame per player) costs more and ties the decision to an entity a client may not
have in its PVS.

On pickup: `wf_grant(id, WF_REWARD_GIFT, rarity, "spot#<map>#<spot>#<round>")`,
the glow is killed, a `TE_SPRITE` burst plays, and the spot returns after its
`respawn` seconds. "One pickup per player per spot per round" is enforced twice:
an in-memory `taken[spot][player]` grid reset on the new-round event, and the
ledger key (which also survives a reconnect inside the same round).

**Bots never collect.** The scan uses `get_players(..., "ch")` (no bots, no HLTV
proxies), and every entry point checks `is_user_bot`/`is_user_hltv`.

**Opening.** `/opengift` (or a row in `/gifts`) → `ScreenFade` in a warm gold
(RGB deliberately not near-white, so `freenova_flash`'s flashbang gate never
matches it) + a HUD line + a `TE_SPRITE` burst, then 1.0 s later
`wf_open_gift()`. The roll and the payment happen in the core (one path), the
theatre here. Two `/opengift` in the same second: the second returns
`WF_OPEN_NOTHING` and pays nothing.

**Snowflake pouch** (owner decision §6.4). A death leaves a small
`sprites/glow01.spr` pouch worth `[pouch] snow` for whoever reaches it first. It
is a kill reward, not a death penalty: nothing is taken from the player who died
and the present they were carrying is not dropped. No pouch for a bot's death (a
bot kill is not worth currency) and none on a suicide. Up to 8 pouches alive; the
oldest slot is reused.

**Season watch.** The season is a date, not an event: a 15 s task spawns the
presents when the window opens (or when an operator sets `wf_force_open 1`) and
removes the glows when it closes, so a season that starts at midnight does not
wait for the next map change.

**Death drops a present?** No, never — owner decision §6.4.

---

## 8. The menus

`/christmas` (`/xmas`) opens the hub; every row carries its own state so a
brand-new player never sees an empty screen and never sees a dead option.

| command | what it does |
| --- | --- |
| `/christmas` | hub: presents carried, open a present, tree, ornaments, advent, pass, shop |
| `/gifts` | the presents you carry, one row each, selecting one opens it |
| `/opengift` | opens the oldest present (owned by `winterfest_gifts`; registered here as a fallback if that module is absent) |
| `/tree` | style, level, `filled / 24`, the next milestone (closest incomplete set) and the panel URL when `wf_panel_url` is set |
| `/ornaments` | the catalogue, paginated, owned/missing, and each row explains its set and title |
| `/advent` | 24 days: claimed / open now (full) / missed (half) / locked |
| `/winterpass` | tier, XP, next threshold and the next three tier rewards |
| `/christmashop` | one line: the shop opens in Phase 2, snowflakes are kept |

Bots, HLTV proxies and the console get nothing (they have no menu to draw on), and
outside the season each command prints the window and returns instead of showing
an empty menu.

In-game the tree is text: a 1999 chat console cannot render a 2D grid, and the
owner's decision is that the tree itself is a **panel** surface (§6.1). `[tree]`
in the ini is the data the panel draws from (§9).

---

## 9. For the panel: the sync payload (design only — not implemented)

Phase 1 ships the storage and the natives; the panel is another workstream. These
are the fields it will need, written down so nothing is invented later. **None of
this is implemented in Phase 1**, and there is **no premium/pass-purchase field
anywhere** (owner decision §6.2).

```
winterfest: {
  season:   { name, year, start, end, advent_end, open, days_left }
  wallet:   { gingerbread }            /* id `gb` */
  spins:    { balance, free_today, next_free_at }
  presents: [ { instance, rarity, rarity_name, opened: false } ]
  ornaments:[ { id, name, rarity, set, owned, hidden } ]
  sets:     [ { id, name, title, owned, total, complete } ]
  tree:     { style, style_name, level, filled, slots: [ {slot, ornament_id, x, y} ] }
  advent:   [ { day, reward_text, claimed, state } ]   /* state = the wf_advent_state() value */
  pass:     { tier, xp, next_xp, max_tier, premium_owned,
              tiers: [ {tier, xp, free_reward_text, free_claimed,
                        premium_reward_text, premium_claimed} ] }
  entitlements: [ { product_id, label, owned, source, granted_at } ]
  titles:   [ set_id ]
  pending:  { count }                  /* the envelope's counter (workstream 15) */
}
```

Read them through the natives in §6 rather than re-parsing the ini on the panel
side: the ids are the join key between the two, and a second parser is a second
source of truth. Anything the panel writes back (a slot drag, an advent claim)
must go through `wf_tree_set_slot` / `wf_advent_claim` so the ledger stays the
only record of what has been paid.

### 9.1 The other workstreams' hooks (owner decisions, 2026-11-22)

Three workstreams need a slice of this module. **Nothing of their features is
built here** — these are the seams, and each one is deliberately small.

| workstream | what it gets from the core | what it owns (not here) |
| --- | --- | --- |
| 13 — Spin Wheel | `wf_get_spins`, `wf_add_spins`, `wf_consume_spin`; one free spin per player per day granted at connect (claim key `spin#<YYYYMMDD>`, idempotent); `[spins] free_per_day` / `enabled` in the ini; a `spins` counter in the vault | the wheel UI, the prize table, the table of outcomes, anything that *pays* a prize. `wf_add_spins` is the only way it can top a player up |
| 14 — Levels page | `wf_get_pass_xp`, `wf_get_pass_tier` (canonical; `wf_pass_xp`/`wf_pass_tier` are aliases), the whole threshold table by iterating `t = 1..wf_pass_max_tier()` over `wf_pass_tier_xp(t)` / `wf_pass_tier_reward(t, …)` / `wf_pass_tier_reward_premium(t, …)`, `wf_pass_next_xp` for the bar, and `wf_pass_premium_unlocked` to draw the two tracks | the page itself. The free track has no purchase path; premium is `bp_premium_2026` in `[entitlement]` (§4.6) and the page only *reads* ownership |
| 15 — Envelope (inbox) | a reserved per-player counter: vault key `pending` (base `wf_pending_s<year>#<auth>`), exposed read-only as `wf_get_pending(id)`, round-tripped by the normal save path so it survives relogs | writing it (the envelope's own channel), the messages, the UI. The core assigns it no behaviour, which is why there is nothing to rip out if the feature changes shape |

If a spin, a level and an envelope notification ever need to be paid *in the
same tick*, they all still go through the one ledger: `wf_grant` with a claim
key, never a second counter.

---

## 10. Deliberately not in Phase 1

| thing | why, and when |
| --- | --- |
| panel pages (`/winter`, `/winter/tree`, …) | another workstream; the data model is §9 |
| the drag UI for the tree | panel surface (owner decision §6.1); in game the tree is a summary |
| selling premium / the Advent Pass | the *gameplay* half is in this build (§4.5, §4.6); the store page, orders, Stripe and the action bridge are the panel's (`docs/WINTERFEST.md` §7) |
| seasonal missions, 12 Days windows | Phase 2 (`missions.ini`, `events.ini` — existing owners) |
| leaderboards, community goal, Secret Santa | Phase 2, on the existing `boards.js` |
| Christmas shop | Phase 2 (`/christmashop` says so instead of opening an empty menu) |
| models, skins, sounds, winter maps | Phase 3, blocked on fastdl (`docs/WINTERFEST.md` §1.1). The prop models are already wired as ids: flipping `[props]` to `present_classic`/`tree_classic`/`c4_xmas` and `wf_allow_models 1` is the whole switch (§4.4) |
| present drop on death | owner decision §6.4: never. A pouch instead |
| tournament/free-form tree placement | owner decision §6.1: fixed 24-slot grid |
| in-game ornament placement | nothing in Phase 1 needs it; the natives are there for the panel |

---

## 11. Verification

### 11.1 Static (both are CI gates)

```bash
bash tools/compile-plugins.sh          # every plugin; expect "failed: 0"
python3 tools/lint-plugins.py          # 7 rules; expect "0 error"
```

`tools/lint-plugins.py` is a real linter (format-string alias, `%n`, a variable
format argument, a `LibraryExists` for a library nothing registers). **No
allowance was added for any file in this module** — if it flags something here,
the code is wrong.

### 11.2 The scripted scenario (needs the `cs16-linux-base` harness)

```bash
cd /path/to/cs16-linux-base
./scripts/assemble.sh --profile freenova
# the three plugin lines are the coordinator's job in the repo's plugins.ini;
# for a harness run, append them to the build tree instead:
printf 'winterfest_core.amxx\nwinterfest_gifts.amxx\nwinterfest_menu.amxx\n' \
  >> build/server-freenova/cstrike/addons/amxmodx/configs/plugins.ini

./scripts/test-plugin.sh /path/to/tests/winterfest/wf_scenario.sma \
    --profile freenova --bots 1

./scripts/test-plugin.sh /path/to/tests/winterfest/wf_scenario.sma \
    --profile freenova --bots 1 --map fy_snow \
    --expect /path/to/tests/winterfest/wf_scenario_generic.expect
```

What those two runs prove, with nobody at the keyboard:

| assertion | what it shows |
| --- | --- |
| `reset-clean` | `wf_reset all` really wipes the season (and its epoch bump lets the player earn again) |
| `gb-add`, `grant-once`, `grant-second-key` | a GingerBread add lands; the same claim key pays **once**; a different key still pays |
| `gb-legacy-alias` | `wf_add_snowflakes` still adds to the GingerBread balance (one-season alias) |
| `spins-consume` | two spins are consumable, the third is refused at zero |
| `pass-natives` | `wf_get_pass_xp`/`wf_get_pass_tier` agree with their aliases (workstream 14) |
| `daily spin granted to id N` | the once-per-day free spin is paid at connect (the boot asserts the log line; `wf_reset` clears it later in the run) |
| `ornament-once` | an ornament is granted once, and `wf_has_ornament` agrees |
| `visual-data`, `visual-model-gated` | a prop's look is config data, and with `wf_allow_models 0` the rare present resolves to its stock-sprite fallback — the model is never drawn (owner hand-over) |
| `tree-slot`, `tree-slot-refused`, `tree-clear` | the 24-slot grid accepts an owned ornament, refuses one you do not own, and clears a slot |
| `gift-once`, `gift-instance` | a present is added once and carries its rarity |
| `open-once`, `open-second-pays` | **the anti-dupe rule**: the same present opened twice in the same tick pays once and leaves the bag unchanged; a different present still opens |
| `advent-today`, `advent-expired`, `advent-locked` | today's day pays once; **yesterday answers `expired`** (there is no catch-up) and today+1 answers `locked` |
| `advent-pass` | the Advent Pass entitlement makes a missed day claimable, once, and granting it twice is a duplicate |
| `premium-locked` | a premium tier is refused while the entitlement is missing |
| `pass-free-claim` | the free track pays once and then refuses (independent of premium) |
| `premium-entitled` | granting the entitlement back-pays the reached premium tiers exactly once (GingerBread and spins both move), the explicit claim then answers "already paid", and the free key is untouched |
| `entitlement-unknown` | an unknown product id is refused rather than silently owned |
| `pass-xp` | one claim key moves pass XP once and the tier follows |
| `season is closed … not spawned` | a closed window spawns no presents (the boot is in November) |
| `spawned N/N present glow(s)` | once the window is open, the spots really resolve and spawn |
| `… from map rows - ok (rule: 6-10, default 8)` | de_dust2's own rows, and that the count satisfies the owner's rule |
| `… from generic * rows - ok` | a map with no rows of its own (fy_snow) falls back to the `*` set and still lands inside the rule |
| `[WF] admin … gave …`, `[WF] season … open=yes`, `reloaded`, `no client matched` | the **console** half: `wf_give`, `wf_state`, `wf_reload`, and the error path, all through the same functions |
| `absent: [WF-TEST] FAIL`, `Run time error`, `bad load` | nothing failed, nothing threw, nothing bad-loaded (77 plugins running) |

The self-pause path is verified separately: remove `winterfest_core.amxx` from
`plugins.ini`, boot, and read the two `pausing self` lines (§2.2). The harness
reports that run as a failure only because it asserts every plugin is running —
that is the point of the test.

### 11.3 What a human still has to confirm

The harness has no human client, so these are **not** machine-verified:

* the menus render sensibly in the real client (`/christmas` and its six
  submenus) and each row's text fits the GoldSrc menu width;
* a walk to a present really picks it up (the harness proves the spots spawn and
  the distance maths compiles, not that a body can reach a coordinate);
* the opening theatre reads as "opened" (fade + HUD + burst timing);
* the pouch appears at a death and is taken by the first player to reach it;
* the panel contract in §9 against the real panel.

---

## 12. Operator commands

| command | what it does |
| --- | --- |
| `wf_state <target\|all>` | season window, vault state, and one line per player: snow, presents, ornaments, tree, pass XP/tier, advent days, titles |
| `wf_give <target\|all> <gingerbread\|spins\|ornament\|gift> <id> <n>` | grants through the same path players use, logged as an operator action. `id` is the ornament id / present rarity (0 and ignored for gingerbread and spins). `snowflakes`/`snow` are still accepted |
| `wf_reset <target\|all>` | wipes the **current season** for that player, bumps the reset epoch so nothing can be re-claimed, logs it |
| `wf_ent <target\|all> <product> [source]` | grants an entitlement (`bp_premium_2026`, `advent_pass_2026`), logged with its source, idempotent per player and product |
| `wf_reload` | re-reads `winterfest.ini` and asks `winterfest_gifts` to re-spawn its spots |
| `wf_gifts_reload` (server) | the gifts half of the above, on its own |
| `wf_dump_spawns` (server) | prints the current map's player spawns as ready-to-paste `[presents]` rows |
| `wf_enabled 0/1` (cvar) | the global kill switch; 0 makes `wf_season_open()` false everywhere |
| `wf_force_open 1` (cvar) | opens the season outside its window — for a rehearsal, a captured video, or the tests |
| `wf_panel_url "<url>"` (cvar) | what `/tree` prints as the panel link (empty = "opens with the panel release") |
| `wf_allow_models 0/1` (cvar, `configs/plugins/wf_gifts.cfg`) | allow client-model visuals (the Phase 3 switch, §4.4). Read in `plugin_precache`, so it belongs in that cfg and not in `amxx.cfg` |

`wf_give`/`wf_state`/`wf_reset`/`wf_reload` require `ADMIN_CFG`; `wf_state all`
and `wf_give all` are console-safe and target every connected client, bots
included (a bot is a valid vault record and the harness has no humans).
