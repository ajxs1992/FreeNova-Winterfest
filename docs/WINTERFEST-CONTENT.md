# Winterfest content pack: present spots, catalogue, Advent, pass, 12 Days

Owner of this pack: the content agent. Files it writes and nothing else:

| file | what it is | read by |
| --- | --- | --- |
| `tools/winterfest/bsp.py` | GoldSrc BSP v30 reader (header, lumps, entity text) | `gen_spots.py`, tests |
| `tools/winterfest/gen_spots.py` | generates the present spots, verifies them | operators, tests |
| `configs/freenova/winterfest/presents.ini` | 186 present spots over 25 maps | **generated**, merged into `winterfest.ini` `[presents]` |
| `configs/freenova/winterfest/ornaments.ini` | 30 ornaments, 6 sets, 6 secret-collection rewards | merged into `[ornament]` + `[set]` |
| `configs/freenova/winterfest/advent.ini` | 24 Advent days | merged into `[advent]` |
| `configs/freenova/winterfest/pass.ini` | 30 free pass tiers, 23 700 XP | merged into `[pass]` |
| `configs/freenova/winterfest/season.ini` | season window, death pouch, present counts | merged into `[season]` + `[pouch]`; `[present_defaults]` is generator input |
| `configs/freenova/winterfest/12days.ini` | the 13-24 December windows | **draft** for `events.ini` (another owner) |
| `tests/winterfest/` | 101 tests: BSP reader, generator, shipped content | CI / `python3 -m unittest` |

Paths above are relative to `game-server/cstrike/addons/amxmodx/` for the config
files. Nothing here touches `winterfest.ini`, any `.sma`, `plugins.ini`,
`events.ini`, `missions.ini` or `web-panel/**` - the last section of this
document says exactly how the coordinator merges each block.

The product contract is `docs/WINTERFEST.md` (section 1 constraints, section 4
Phase 1, section 6 owner decisions). This document is the *content* contract.

---

## 1. Present spots: why the BSP, and how

### 1.1 The problem

Phase 1 needs 6-10 presents per map, on the ground, in a reachable place, spread
over the map, on every map in `mapcycle.txt`. Hand-placing 25 maps x 8 spots is
a week of walking around with `getpos` and it goes stale the first time a map
file is replaced. The server cannot test reachability for you either: nothing in
the engine can answer "can a player stand here".

### 1.2 The honest shortcut

A GoldSrc BSP (version 30) stores its entities as **text** in lump 0:

```
{
"classname" "info_player_deathmatch"
"origin" "-1024 -896 192"
"angles" "0 90 0"
}
```

`info_player_start` and `info_player_deathmatch` are positions the *engine*
guarantees: the map's own spawns. Every one of them is on the floor, outside
geometry, inside a play area, and a map with two bombsites has spawns at both.
That is the entire trick - no map editor, no recompile, no client assets, and it
works for a map nobody has ever looked at.

`tools/winterfest/bsp.py` reads the file:

* a GoldSrc header is `int32 version` (must be 30) followed by 15 `(offset,
  length)` pairs = 124 bytes. Source BSPs start with the ASCII magic `VBSP` and
  have 64 lumps; version 20 is the Source/HL2 era. Both are rejected with a
  message that says what the file actually is, because "not a GoldSrc map" is
  the one mistake that would silently produce garbage coordinates.
* lump 0 is NUL-terminated cp1252 text. The tokenizer follows the engine's own
  `COM_Parse`: whitespace separates, `"` groups a value that contains spaces,
  `//` starts a comment, `{`/`}` delimit a block. Unterminated quotes, dangling
  keys, a missing closing brace and junk between blocks all degrade instead of
  raising - one bad entity must not cost a map its presents.
* `parse_origin()` accepts `"x y z"` with extra spaces, tabs, commas and
  exponents, and returns `None` for everything else (`""`, `"abc"`, two
  components, four components, `nan`, `inf`). It never guesses.
* lump 14, model 0 is the world, whose `mins`/`maxs` are the map's bounding box.
  That is the "inside the map" filter, and it comes from the map's own data
  rather than from the candidate cloud (which would filter nothing).

### 1.3 Candidates, in the order they are trusted

| tier | classnames | why |
| --- | --- | --- |
| 0 | `info_player_start`, `info_player_deathmatch` | the engine's own spawn points |
| 1 | `info_player_terrorist`, `info_player_counterterrorist` | same, team-specific |
| 2 | `info_target` | a mapper's marker: usually on the floor, sometimes mid-air |
| 3 | `item_*` | pickups sit on the floor in the play area, sometimes on a crate |

Tiers 0-1 are the pool for a normal map. Tiers 2-3 are a **documented fallback**,
added only when a map cannot fill 6 spots from spawns; the report names every
map that needed one (today: `de_nuke`). A fallback spot is the weakest claim in
this pack - a marker can be in the air - so it is never used on a map that has
enough spawns.

Filters, applied to every candidate:

1. origin parsed (see above),
2. `z > -2000` (below that is the void under the map),
3. inside the world model's bounding box, with 1 unit of slack,
4. `|x|, |y|, |z| <= 8000` (the sanity rule, enforced earlier than the check),
5. not a duplicate of an origin already seen (some maps list a spawn twice),
6. rounded to whole units, so the distance rule, the check and the file agree.

### 1.4 Choosing 8 spots that are actually spread out

Farthest-point sampling: start somewhere, then repeatedly add the candidate whose
nearest already-chosen spot is furthest away. Each new spot lands in the largest
gap, so the set covers the map instead of piling into one spawn room.

Two refinements, both from real data:

* the greedy walk depends on where it starts. On `de_dust2` one start yields 6
  spots, a better one yields 7. So the walk is run from **every** candidate (an
  even sample of 64 when a map has more) and the winner is the one with the most
  spots, then the widest spread, then the lowest start index.
* farthest-point is greedy, not optimal. `de_survivor`'s spawns do fit 6 spots
  300 units apart, but every farthest-point walk found only 5. So when the walk
  cannot reach the target, a **bounded branch-and-bound** (maximum independent
  set on the "too close" graph, which is exactly what the 300-unit rule is)
  looks for one more, with the walk's result as the incumbent so it can never
  come back worse. Its budget is a **node count** (60 000), never a clock: the
  same BSP has to give the same answer on a fast machine and a slow one.

No two spots on a map are closer than **300 units**. When the geometry cannot
supply `count` spots at that spacing, the map gets fewer and this pack says so in
three places: the console table, the `presents.ini` header (a "below target"
block naming every short map), and above the map's own rows (`7 of 8 spots
(separation-limited)`). Nothing is ever invented to fill the quota.

### 1.4.1 Why `de_dust2` gets 7 and not 8

This is the one number that shows up in the in-game log
(`[WF-GIFTS] 7 present spot(s) on de_dust2`), so it is worth stating precisely:

* `de_dust2.bsp` contains **40 usable spawn origins** (20 `info_player_start`,
  20 `info_player_deathmatch`) plus 3 `info_target` entities.
* Run over those 40 spawns, an **exact** maximum independent set at 300 units is
  **7**. There is no arrangement of 8 spawn origins on dust2 that keeps every
  pair 300 units apart - the spawns sit in two clusters (T spawn on the raised
  shelf, CT spawn below), and each cluster only fits 3-4 spots at that spacing.
* 8 *is* reachable if the three `info_target` entities are allowed in, because
  they are `cam1a`/`cam2a`/`cam4a`: **camera anchors**. They are placed where a
  spectator camera looks from, i.e. at or above eye height, and the plugin's
  pickup radius is a 3D distance of **60 units measured from the player's feet**
  (`WINTERFEST.md` section 4.3, `PICKUP_RADIUS` in `winterfest_gifts.sma`). A
  present floating 64+ units up can never be collected by walking under it.
  Padding dust2 from 7 to 8 with a camera anchor would trade one missing row for
  one unreachable present, which is worse.
* So the generator pads **only up to the 6-spot floor**, never up to the target,
  and dust2 ships 7 - inside the owner's 6-10 range, and labelled as
  separation-limited in the file.

The same test was run on every short map:

| map | spawns only | with cameras/items | what is in the way |
| --- | --- | --- | --- |
| `de_tuscan` | 7 | 8 | 4 `info_target` camera anchors |
| `de_dust2` | 7 | 8 | 3 camera anchors |
| `de_train` | 7 | 8 | 5 camera anchors |
| `cs_backalley` | 6 | 8 | 4 camera anchors |
| `de_airstrip` | 7 | 8 | 4 `item_*` pickups (on the ground, but a pickup is not a spawn) |
| `cs_italy` | 7 | 7 | nothing - 7 is the ceiling |
| `de_chateau` | 7 | 7 | nothing - 7 is the ceiling |
| `de_inferno` | 6 | 6 | nothing - 6 is the ceiling |
| `de_piranesi` | 6 | 6 | nothing - 6 is the ceiling |
| `de_survivor` | 6 | 6 | nothing - 6 is the ceiling |

Five maps could be padded to 8 by allowing camera anchors (or, on `de_airstrip`,
ground items); none is, for the reason above. Five maps cannot reach 8 with any
entity in the BSP at that spacing, so 6-7 is their real ceiling.

### 1.5 Rarity mix

Each map gets an exact largest-remainder quota from `common 55 / uncommon 30 /
rare 15`, then a deterministic shuffle (seed = map name) decides which spot gets
which rarity:

| spots | common | uncommon | rare |
| --- | --- | --- | --- |
| 6 | 3 | 2 | 1 |
| 7 | 4 | 2 | 1 |
| 8 | 5 | 2 | 1 |
| 9 | 5 | 3 | 1 |
| 10 | 6 | 3 | 1 |

A per-map quota (rather than a global one) is what keeps a map's rows stable
when another map is added or removed. The aggregate over the shipped file is
**111 / 50 / 25 = 59.7% / 26.9% / 13.4%**, not 55/30/15, because 6-, 7- and
8-spot maps round differently: an 8-spot map is 62.5/25/12.5 by arithmetic, not
by choice. That is as close as an exact quota can get; the alternative (a
weighted dice roll per spot) would hit 55/30/15 on average but leave some maps
with no rare present at all, which is the worse product.

Respawn is 120 s on every row - the Phase 1 value from `WINTERFEST.md` section
4.3. `--respawn N` changes it for a whole regeneration.

### 1.6 Determinism, and how it is proven

* the selection enumerates start points (no random start),
* the rarity shuffle is seeded from a SHA-256 of the map name,
* rows are sorted by origin before they are written,
* the ini header carries the generator version but **no timestamp**,
* `tests/winterfest/test_gen_spots.py` renders the same map twice and compares
  the row lists, and `CommandLineTests` writes, then re-writes and re-checks.

Regenerating an unchanged map produces a byte-identical file. That is what makes
this safe to commit and safe to re-run before a deploy:

```
$ python3 tools/winterfest/gen_spots.py --write ...   # sha256 26a6e1d2...
$ python3 tools/winterfest/gen_spots.py --write ...   # sha256 26a6e1d2...
```

### 1.7 Running it

The stock live maps are **not in this repository** (they come from FastDL; see
`docs/MAPS.md`), so the tool needs to be told where the `.bsp` files are. The
repository's `game-server/cstrike/maps/` is always searched first, because that
is where the staged community maps live; `--bsp-dir` (repeatable) and
`FREENOVA_BSP_DIRS` (colon-separated) add more.

```bash
# 1. look before you write: prints the table, writes nothing
python3 tools/winterfest/gen_spots.py \
    --bsp-dir "/home/ajxs/Desktop/Projects/cs16/CS16-FREENOVA/Server CS 1.6/cstrike/maps"

# 2. regenerate every map in mapcycle.txt
python3 tools/winterfest/gen_spots.py --write \
    --bsp-dir "/home/ajxs/Desktop/Projects/cs16/CS16-FREENOVA/Server CS 1.6/cstrike/maps"

# 3. verify what landed on disk (no BSP needed - it reads the ini)
python3 tools/winterfest/gen_spots.py --check
```

**After a map is added to `mapcycle.txt`** - the exact command:

```bash
python3 tools/winterfest/gen_spots.py --write --map de_tuscan \
    --bsp-dir "/home/ajxs/Desktop/Projects/cs16/CS16-FREENOVA/Server CS 1.6/cstrike/maps"
```

`--map` replaces only that map's rows and leaves every other line in the file
untouched, so a single new map is one command and a two-line diff. Without
`--map` the whole file is regenerated from `mapcycle.txt` (maps that are in the
file but no longer in the cycle disappear - that is the point).

Failure behaviour is deliberate:

* a map whose BSP cannot be found makes `--write` exit `2` and write **nothing**
  (silently shipping 24 of 25 maps is how a map loses its presents);
  `--allow-missing` overrides it and the missing maps are listed;
* a corrupt BSP, a Source map or a truncated file is reported per map and exits
  `2`;
* a map that yields fewer than 6 spots exits `1` and is called out in the table
  and the notes - it is a finding, not a crash.

Flags: `--count`, `--min-distance`, `--respawn`, `--out`, `--season`,
`--print`, `--quiet`.

### 1.8 What `--check` enforces

Reads `presents.ini` and fails (`exit 1`) on:

* a map in `mapcycle.txt` with no rows, fewer than 6 rows, or more than 10;
* an origin that is not three numbers, or any coordinate beyond `+-8000`;
* two spots on a map closer than 300 units (it prints the distance);
* a duplicate row, a rarity outside 0..2, a respawn outside the plugin's
  10..900 clamp;
* a line in `[presents]` that parsed into no row at all (a malformed row is
  skipped by the parser, so this catches it instead of losing a spot silently).

It prints the same table as generation, from the file rather than from memory,
plus a per-map note when a map is outside `mapcycle.txt` (allowed - a staged map
can be generated ahead of going live).

---

## 2. Evidence: the shipped `presents.ini`

**The pool is 25 maps.** `mapcycle.txt` held 24 stock maps when this work
started; `de_tuscan` (already staged in `game-server/cstrike/maps/`, content
uploaded to the host) was added to the cycle by the map agent and is now a live
map. The pack was regenerated after that change, so `presents.ini` covers all
25 - including `de_tuscan`, which is first in the cycle.

```
map                spots   cand  min pair   spread  source
--------------------------------------------------------------------
de_tuscan              7     28       306     4440  spawns
de_dust2               7     43       304     3606  spawns
de_inferno             6     32       336     4628  spawns
de_nuke                8     23       382     6384  spawns+targets
de_train               7     29       400     5179  spawns
de_aztec               8     37       345     5741  spawns
cs_office              8     24       316     4056  spawns
de_cbble               8     41       371     5299  spawns
de_piranesi            6     32       346     5319  spawns
de_prodigy             8     24       372     2930  spawns
cs_italy               7     20       329     4640  spawns
de_vertigo             8     33       301     1438  spawns
cs_militia             8     25       342     3791  spawns
de_airstrip            7     42       310     5641  spawns
de_chateau             7     35       336     4178  spawns
de_storm               8     37       304     5161  spawns
de_survivor            6     20       320     4141  spawns
de_torn                8     40       384     4848  spawns
cs_assault             8     25       345     2863  spawns
cs_estate              8     21       303     2247  spawns
cs_backalley           6     24       330     2163  spawns
de_dust                8     36       336     5609  spawns
cs_747                 8     29       460     3723  spawns
cs_siege               8     22       341     6699  spawns
as_oilrig              8     36       561     2120  spawns
```

`spots` rows written, `cand` usable candidate origins in the BSP, `min pair` the
closest two spots on that map (must be >= 300), `spread` the distance between
the two spots furthest apart - the coverage figure. `source` says which pool
produced them; `spawns+targets` is the fallback.

Totals: **25 maps, 186 rows**; 15 maps at 8, 6 at 7, 4 at 6; closest pair on any
map 300.6 units (`de_vertigo`); spread 1 438 - 6 699 units, mean 4 274.

Every map in `mapcycle.txt` has 6-10 rows, every coordinate is three integers
inside `+-8000`, and `--check` reports **0 issues**:

```
$ python3 tools/winterfest/gen_spots.py --check
... 25 map(s), 186 row(s), 0 issue(s)      # exit 0
```

**Ten maps do not reach the default of 8, and the file says so twice.** That is
the 300-unit rule doing its job, not a bug: those spawn lists do not contain 8
origins that far apart. Section 1.4.1 has the per-map measurement (dust2: exact
maximum 7 from its 40 spawns; 8 only via its 3 camera anchors), and the header of
`presents.ini` carries a "below target today (10 of 25 maps)" block listing each
one with its actual count, while each map's own comment reads like
`; de_dust2 - 7 of 8 spots (separation-limited), min pair 304 u, spread 3606 u`.

That is deliberate: **the count is the geometry's, never the target's.** Padding
dust2 to 8 would mean a present at a spectator-camera anchor that no player can
reach with a 60-unit pickup radius; loosening the spacing rule would mean two
presents in one spawn room. Both are worse than a 7 that works. All ten are
inside the owner's 6-10 range, and the in-game log (`[WF-GIFTS] 7 present
spot(s) on de_dust2`) now matches a documented, labelled expectation instead of
looking like a generator failure.

---

## 3. `presents.ini` - format and merge rules

Row format (read by `winterfest_gifts.amxx`, `WfAddSpot`):

```
map | x y z | rarity | respawn
```

* `map` - BSP name without `.bsp`, as spelled in `mapcycle.txt`.
* `x y z` - origin in map units, three integers. Literal coordinates, not an
  `@t3` spawn reference. Both are supported by the plugin; literals were chosen
  because they are what the BSP actually says, they can be checked offline
  (`--check`), and they do not depend on the plugin's own class fallback order
  (`@t` -> `info_player_deathmatch` -> ...). `wf_dump_spawns` on the console is
  the in-game equivalent if a spot is ever added by hand.
* `rarity` - `0` common, `1` uncommon, `2` rare. Names, colours and roll weights
  live in `winterfest.ini`'s `[rarity]` rows; this column only classifies.
* `respawn` - seconds before the present returns (10-900, clamped by the plugin).

The file starts with a `[presents]` header so it can be pasted as a block.

### 3.1 Merging into `winterfest.ini` - order matters

`winterfest_gifts.amxx` scans `[presents]` twice, and decides **once**, on the
first row that matches the current map, whether that map uses its own rows or
the generic `*` rows:

```
if (!mine && !generic) continue;
if (use_generic < 0) use_generic = mine ? 0 : 1;
```

So a `*` row that appears **before** a map's own rows silently disables that
map's rows. The merge must therefore be:

1. replace the hand-written per-map rows in `[presents]` with this file's rows,
2. keep the existing `8` generic `* | @tN | ...` rows **at the very end** of the
   section (they are the safety net for a map added without regenerating),
3. delete `de_dust2`'s eight hand-written rows - this pack supersedes them (and
   keeping both would give dust2 15 spots, over the 10 maximum).

`winterfest.ini` as it stands has 8 `de_dust2` rows + 8 `*` rows; after the merge
it has 186 generated rows + the 8 `*` rows last.

---

## 4. `ornaments.ini` - catalogue and secret collections

30 ornaments in 6 named sets, each set exactly 5 (the secret collections).

```
[ornament]  id | name | rarity | set | hidden
[set]       id | name | title | snow
```

* `hidden` (`1` = the panel and `/ornaments` show `? ? ?` until owned) is an
  **additive fifth column that `winterfest_core.amxx` does not read today**:
  `parseOrnament()` reads fields 0-3 and ignores the rest, so the row is
  forward-compatible and nothing breaks. 12 of the 30 are hidden - the two
  rarest of every set. The menu/panel readers are the ones that must honour it.
* The set `title` is what the engine can grant (`WF_REWARD_TITLE`, reward id =
  set id). The brief names *models* for sets 2 and 3 (Santa's Helper, Grinch);
  models need FastDL (`WINTERFEST.md` section 1.1), so today the title carries
  the name and the model ships in Phase 3 keyed off the same set id.
* `snow` is a real reward: `WfSyncSets()` pays the title and the bonus once when
  the set completes, through claim keys `set#<id>` and `setbx#<id>`.
* "All six sets complete -> Winterfest Legend weapon pack" cannot be a per-set
  title (the core grants one title per set). Set 6's title deliberately carries
  the name as a badge; the **pack** needs the panel/coordinator to check all six
  set ownerships.

| set | name | title | snow | ornaments |
| --- | --- | --- | --- | --- |
| 1 | Snowflakes | Ice Warrior | 100 | 1-5 |
| 2 | Santas | Santa's Helper | 150 | 6-10 |
| 3 | Grinches | Grinch | 150 | 11-15 |
| 4 | Sleighs | Sleigh Bells | 200 | 16-20 |
| 5 | Bells & Candy Canes | Candy Cane Kid | 120 | 21-25 |
| 6 | Special | Winterfest Legend | 500 | 26-30 |

Shape: 10 common, 12 uncommon, 8 rare; 12 hidden. Ids are contiguous 1-30 and
never reordered - `[advent]`, `[pass]` and the reward pool all name them, and the
core's `wf_ornament_total()` is the highest id (the menu pages the catalogue by
id, so a gap is a "missing ornament" row).

---

## 5. `advent.ini` - 24 days

```
[advent]  day | type | id | amount
```

`type` is `snow | ornament | gift | pass | title`; `id` is a catalogue id (an
ornament id, a present rarity, a set id) and `amount` is the magnitude for
`snow`/`pass`.

The curve: days 1-8 snow only (40 -> 90), an ornament every other day from 9,
the good ornaments and presents on 20-23, and the set-6 badge on 24. Totals
1 310 snowflakes, 8 ornaments, 2 presents, 1 title.

**The half-value rule is documented in the header and implemented in the core**,
not in this file - the file always lists the full value:

* snow/pass rows claimed late: `floor(amount / 2)`, minimum 1;
* ornament/gift/title rows: paid as-is (no smaller unit exists);
* an ornament the player already owns becomes snow (20/40/60 by rarity), so a
  late day never pays nothing.

---

## 6. `pass.ini` - 30 free tiers

```
[pass]  tier | xp | type | id | amount
```

`xp` is **cumulative**, not a step, and must strictly increase (the loader clamps
a row that goes backwards and logs it). No premium column, no price, no paid
path anywhere - owner decision 6.2 - and `tests/winterfest/test_content.py`
asserts that no data row mentions premium/price/cost/paid.

| tiers | step | cumulative | what it feels like |
| --- | --- | --- | --- |
| 1-10 | +300 | 0 - 2 700 | 3-4 tiers a day for a regular player |
| 11-20 | +700 | 3 400 - 9 700 | about a tier a day |
| 21-30 | +1400 | 11 100 - 23 700 | a tier every day and a half |

Total 23 700 XP over 24 playable days = just under 1 000 XP/day. Tier 1 is 0 XP
because `WfTierFromXp()` never returns below 1 and `WfSyncTiers()` pays it on the
first sync - it is the welcome reward; tiers 2-30 are the ones that cost.

Rewards: 18 snow rows (5 650 snowflakes), 8 ornaments across all six sets, 3
presents (one uncommon, two rare), and the set-6 title at tier 30.

---

## 7. `season.ini` - window, pouch, present counts

```
[season]   name / year / start / end / advent_end / enabled (+ timezone, documentation)
[pouch]    snow = 5, life = 30, enable = 1
[present_defaults] default = 8, min = 6, max = 10
```

`start`/`end` are read by `WfDateKey()`, which keeps the first eight digits, so
`2026-12-01 00:00` becomes `20261201`: the plugin compares calendar dates, and
the time of day is for humans. The comparison uses the **server's local clock**
(`get_time("%Y%m%d")`), so the host must run Europe/Paris for the season to open
and close when the file says - `timezone = Europe/Paris` records that intent for
whoever provisions the host, and nothing reads it.

`[pouch]` is the death drop from owner decision 6.4: dying never drops a present
and never costs the victim anything; the killer's prize is a 5-snowflake pouch
that fades after 30 s. Bots and suicides drop nothing (plugin rules, not config).

`[present_defaults]` is **generator input, not plugin config**: `gen_spots.py`
reads it so "default 8, min 6, max 10" lives in data. Neither plugin looks at that
section, which is why it is not called `[presents]` (that name is a table of map
rows, and a key = value line there would be logged as a bad spot).

---

## 8. `12days.ini` - the draft for `events.ini`

`events.ini` window rows are `id | days | start | end | flavor | multiplier`,
and `days` is a **weekday list, not a date**. There is no date-range column, so
no row can say "13 December only". That is the one real gap between the brief and
what the scheduler can express, and it drives the shape of this file:

* **Part A** is the plan: twelve date-anchored days, 13-24 December, each with its
  own theme and multiplier, with the day -> weekday -> window -> blurb mapping.
  This is what the MOTD and Discord copy their one-liners from.
* **Part B** is paste-ready `[window]` rows for all twelve days, for when
  `freenova_randevent` grows a date range. The repeated weekdays (13/20 Sun,
  14/21 Mon, 15/22 Tue, 16/23 Wed, 17/24 Thu) are split into an early and a late
  slot, so even without a date gate no two rows share a weekday and a time - the
  plugin refuses to open a window while another event owns the channel, and a
  collision would silently drop a day.
* **Part C** is the safe-now variant: seven rows, one per weekday, the stronger
  theme of each pair. It runs weekly rather than for twelve days and the MOTD
  should call it a weekly rotation. It lives under `[window-safe-now]`, a section
  the plugin does not know, so pasting the whole file into `events.ini` cannot
  load both variants by accident.

Merging needs `[settings] mode = schedule` (or `both`) - with the shipped
`mode = random` no window runs at all - and fits the 16-window cap
(3 existing + 12 = 15).

---

## 9. Merging the pack into `winterfest.ini`

`winterfest.ini` is owned by the core/menu agent and is the only file the plugins
open. These files are the content for it. **Replace sections, never append** -
the ids are a namespace, and two catalogues side by side would produce
`g_iOrnCount` = the highest id in either, set totals that count both, and Advent
or pass rows that name the wrong ornament.

What is in `winterfest.ini` as this pack is handed over, and what replaces it:

| section | in `winterfest.ini` now | this pack | action |
| --- | --- | --- | --- |
| `[ornament]` | 18 rows (Snow Crystal, Frost Bauble, ...) | 30 rows, 6 sets | replace the whole section body |
| `[set]` | 5 rows (Snowflakes, Northern Lights, Gingerbread, Star of Wonder, Frozen Relics) | 6 rows | replace |
| `[advent]` | 24 rows | 24 rows | replace (ids follow the new catalogue) |
| `[pass]` | 30 rows, tier 1 = 0, total 16 250 | 30 rows, total 23 700 | replace |
| `[season]` | 6 keys | same keys | replace the values |
| `[pouch]` | 3 keys | same keys | keep (5 / 30 / 1 already matches) |
| `[presents]` | 179 map rows over 24 maps + 8 `*` rows | 186 rows over 25 maps + `[presents]` header | replace the per-map rows, keep `*` **last** |
| `[rarity]`, `[tree]`, `[open]` | 3 / 72 / 12 rows | not in this pack | leave alone |
| `events.ini` | 3 windows, `mode = random` | `12days.ini` | separate file, separate owner |

**Known gap at handover:** the merged `[presents]` in `winterfest.ini` holds 24
of the 25 maps - `de_tuscan` was added to the cycle after that merge, so the live
map currently falls back to the 8 generic `*` spots instead of its 7 spread ones.
Re-merging the block fixes it; the rows are byte-identical apart from those seven
lines and the comments. The `*` ordering is already correct in the file (last),
so the only action is "replace the map rows, keep `*` where it is".

The ornament renumbering is the sharp edge: the core stores owned ornaments as
ids and the panel mirrors them, so **before the season starts** is the only safe
time to swap the catalogue. After 1 December, a new ornament has to be appended
at the end (`id = 31`), never inserted.

---

## 10. Tests

Standard library only; no pytest, no BSP files, no network.

```bash
python3 -m unittest discover -s tests/winterfest -v
# or one file at a time
python3 tests/winterfest/test_bsp.py
python3 tests/winterfest/test_gen_spots.py
python3 tests/winterfest/test_content.py
```

101 tests:

* `test_bsp.py` - the reader. Synthetic BSPs: good entity lump (quoted values
  with spaces), empty lump, a lump of NULs, version 20, Source `VBSP`, version
  29, an empty file, a truncated header, a lump past EOF, CRLF, comments,
  unterminated quotes, dangling keys, junk between blocks, key case, every
  origin shape (including `nan`/`inf`/two and four components), world bounds,
  inverted bounds, `BspMap.load` and its class query.
* `test_gen_spots.py` - the generator. Quota fills from spread candidates; no
  two spots under 300 units; a tight cluster yields one spot, not eight; the two
  opposite corners are both chosen; **determinism** (same map twice -> identical
  rows, and identical rendered text); rows sorted and well formed; the rarity
  quota and its shuffle; the candidate filters (z, box, +-8000, duplicates,
  unparseable origins, rounding); the `info_target` fallback; `verify()` catching
  each failure mode; a render -> parse -> render round trip; the short-map
  labelling (`7 of 8 spots (separation-limited)` plus the header block) and its
  absence when every map is at target; `mapcycle` and `season.ini` parsing; and
  end-to-end runs of `--write`, `--check`, `--map` (one map regenerated, the
  others byte-identical), `--allow-missing`, a Source map, and a dry run that
  writes nothing. It also re-verifies the **shipped** `presents.ini`, so a bad
  regeneration fails the suite.
* `test_content.py` - the data. Catalogue arithmetic (30 ornaments, 5 per set,
  contiguous ids, unique names, 12 hidden, `hidden` in {0,1}), the briefed set
  titles, Advent day coverage and escalation, the half-value/type rules, pass
  tier count and monotonic cumulative XP with no premium column, season window
  and pouch values, and the 12 Days rows (12 date rows + 7 weekday rows,
  `events.ini` shape, no midnight crossing, no weekday/time collision, a blurb
  above every row).

---

## 11. Approximations, choices and things to know

1. **The stock BSPs are not in the repository.** They come from FastDL, so the
   generator needs `--bsp-dir` pointing at the host copy. Without it, `--write`
   refuses to run rather than shipping a partial file. If the maps move, update
   the command in section 1.7 (and `FREENOVA_BSP_DIRS` for convenience).
2. **Ten maps get 6-7 spots instead of 8**, because their spawn lists do not
   contain 8 origins 300 units apart - section 1.4.1 has the per-map numbers
   (exact maximum independent set, not a search failure). Five of them *could*
   be padded to 8 through `info_target` camera anchors or `item_*` pickups, and
   deliberately are not: the count is geometry's, not the target's. Loosening
   the 300-unit rule would hit 8 everywhere and put presents in a pile. The
   shortfall is stated in the `presents.ini` header, above each short map's
   rows, in `--check`'s summary and here.
3. **`de_nuke` is the one map whose spots are not all spawn points.** Its spawns
   max out at 5 spots 300 units apart, so the pool widens to `info_target` and
   three of its eight spots are camera anchors (`cam1`, `cam2`, `cam3`, at
   z -128/-304/-672 while its spawns sit at -368..-308). They are inside the
   map and inside a play area, but a camera anchor can be above head height, so
   **check nuke in game**: if one of those three cannot be collected, drop that
   row and let nuke run with 7. It is the one entry in this pack that needs a
   human eye, and it is named for that reason.
4. **A spot at a spawn origin is picked up instantly** if a player spawns on it
   (pickup radius is 60 units). That is the same behaviour the plugin's own
   `@tN` references have, and it is the price of "guaranteed on the floor".
   Moving a spot off the spawn would need a traceline to prove it is still on
   the floor, which the server cannot do offline.
5. **`spread` is the widest pair, not an area or a Voronoi measure.** It is a
   cheap, honest coverage number; the real spread guarantee is min pair >= 300
   plus farthest-point placement.
6. **The rarity aggregate is 59.7/26.9/13.4, not 55/30/15** - see section 1.5.
   Per-map quotas round; the choice is deliberate and the alternative is worse.
7. **`hidden` is not read by the core today.** It is an additive column for the
   menu/panel readers; the row stays valid for `parseOrnament()` because extra
   fields are ignored.
8. **Set-completion models are titles until FastDL works.** Santa's Helper and
   Grinch are set titles today; the models are Phase 3, keyed off the same set
   ids.
9. **"All six sets -> Winterfest Legend weapon pack"** is a panel/coordinator
   rule, because the core's title grant is per set. Set 6's title shares the
   name as a badge.
10. **`12days.ini` cannot be a real 12-day schedule yet.** `events.ini` has no
    date column; Part B is ready for when it does, Part C is what can ship
    without a plugin change (a weekly rotation), and the file says both.
11. **`mapcycle.txt` changed under this work** (the map agent added `de_tuscan`).
    The pack was regenerated for the 25-map cycle; if the cycle grows again, one
    `--map` command per map, or a full `--write`, keeps the file current.
12. **The numbers are content, not physics.** The Advent curve, the pass steps
    and the set bonuses are a designed first draft that `test_content.py` keeps
    internally consistent; rebalancing is an edit to the ini plus a test run.

---

## 12. Extending the pack

| want | do |
| --- | --- |
| add a map | add it to `mapcycle.txt`, then `--write --map <name>` |
| drop a map | remove it from `mapcycle.txt`, then `--write` (its rows go away) |
| move a spot | do not hand-edit `presents.ini` - change the map, or add a `winterfest.ini` override row for that map (its own rows replace the generated ones) |
| change the spacing | `--min-distance`, then `--write`; expect fewer spots on cramped maps |
| add an ornament | append `id = highest + 1` to `ornaments.ini`, give it a set, run the tests |
| rebalance the pass | edit `pass.ini` `xp` (cumulative, strictly increasing), keep the total near 24 000, run the tests |
| change the season dates | `season.ini`, `[season] start`/`end`/`advent_end` |
| verify before a deploy | `python3 tools/winterfest/gen_spots.py --check` and the unittest suite |
