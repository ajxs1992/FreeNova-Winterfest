# WINTERFEST-ATMOS.md — atmosphere and festive effects

Workstream 6 of [WINTERFEST-WORKSTREAMS.md](WINTERFEST-WORKSTREAMS.md) row 6,
under the constraints of [WINTERFEST.md](WINTERFEST.md) §1. Written 2026-11-22.

Two plugins and three files:

| file | what |
| --- | --- |
| `game-server/cstrike/addons/amxmodx/scripting/winterfest_atmos.sma` | snowfall, the snowstorm window, the Christmas C4 |
| `game-server/cstrike/addons/amxmodx/scripting/winterfest_killfeed.sma` | the festive kill feed |
| `game-server/cstrike/addons/amxmodx/scripting/include/winterfest_atmos.inc` | the shared seasonal gate, ini plumbing and text helpers |
| `game-server/cstrike/addons/amxmodx/configs/freenova/winterfest/atmos.ini` | the date window |
| `game-server/cstrike/addons/amxmodx/configs/freenova/winterfest/killfeed.ini` | the wording table |

Built binaries live next to every other plugin in
`game-server/cstrike/addons/amxmodx/plugins/` (`winterfest_atmos.amxx`,
`winterfest_killfeed.amxx`). **Neither `plugins.ini` nor `winterfest.ini` was
touched** — the coordinator adds the two plugin lines; the two config files above
are this workstream's own.

Nothing here needs a client download, a module this stack does not already load,
or `winterfest_core`. The core is only ever *offered* a snowflake award
(§8.5) and the call is gated twice over.

---

## 1. Cvars

### 1.1 `winterfest_atmos.amxx`

| cvar | default | range | what it does |
| --- | --- | --- | --- |
| `wf_atmos` | `1` | 0/1 | master switch for the whole module. `0` = no timers at all, whatever the date |
| `wf_atmos_force` | `0` | 0/1 | ignore the date window (rehearsal, screenshot, stream in November) |
| `wf_snow` | `1` | 0/1 | snowfall on/off |
| `wf_snow_rate` | `6` | 0–60 | flakes per second per player |
| `wf_snow_radius` | `300` | 50–1000 | half-width of the flake box around the player, units |
| `wf_snow_height` | `220` | 32–1000 | how far above the player's feet a flake may start, units |
| `wf_snow_life` | `8` | 1–40 | flake lifetime in 0.1 s (0.8 s). Also sets the fall distance: 50 u/s × life |
| `wf_snow_scale` | `2` | 1–40 | sprite scale in 0.1 (0.2 → a 64px sprite drawn about 13 units wide) |
| `wf_snow_kind` | `1` | 0/1 | `1` = `TE_SPRITETRAIL` (falls, honours life), `0` = literal `TE_SPRITE` (see §5.2) |
| `wf_storm` | `0` | 0/1 | arms a snowstorm **window**; the plugin clears it back to 0 when the window ends |
| `wf_storm_len` | `90` | 10–600 | seconds of storm |
| `wf_storm_rate` | `18` | 0–60 | flakes/s/player while the storm runs |
| `wf_bombfx` | `1` | 0/1 | the C4 glow, the red/green column, the plant/defuse tints and lines. `0` is a **complete** no-op |
| `wf_atmos_debug` | `0` | 0/1 | one console line per second from the snow loop (humans, bots, flakes) |

Values outside the ranges are clamped where they are read, not rejected, so a
wild cvar can never produce a burst of sprites or a divide-by-zero.

### 1.2 `winterfest_killfeed.amxx`

| cvar | default | range | what it does |
| --- | --- | --- | --- |
| `wf_killfeed` | `1` | 0/1 | master switch for the feed |
| `wf_killfeed_force` | `0` | 0/1 | ignore the date window |
| `wf_kf_lang` | `en` | `en`/`fr`/`de` | which column of the wording table to use; anything else falls back to `en` |
| `wf_kf_santa` | `2` | 0–100 | percent chance that a kill also prints the rare "Santa's chosen" line (0 = never) |
| `wf_kf_reward` | `1` | 0/1 | 10- and 15-streak also grant 2 snowflakes **through the core**, only when `winterfest_core` is loaded |
| `wf_kf_debug` | `0` | 0/1 | echo every announced line and every reward result to the console |

Numbers are cvars, wording is a file (§3.2). That split is deliberate: an
operator changes the language and the chance live, and nobody has to restart for
a typo fix in a chat line.

### 1.3 Commands (console or admin: `ADMIN_ALL`, so rcon works)

| command | what |
| --- | --- |
| `wf_atmos_apply` | re-read `atmos.ini`, re-evaluate the season, start or stop every timer. Idempotent |
| `wf_atmos_report` | the gate, the window, today, which timers exist, the counters, the precache indices, the entity count |
| `wf_atmos_test` | lab: run a flake, a storm window, the C4 glow/column/line and a fade through their real code paths — no players needed |
| `wf_killfeed_apply` | re-read `killfeed.ini` and re-evaluate the season |
| `wf_killfeed_report` | the gate, the language, which table is in use, the counters, whether the core is present |
| `wf_killfeed_test` | lab: render every line of the table with a fake name and print it to the console |

The three `report`/`test` commands are what the harness asserts on; they are also
the answer to "is this thing actually running?" without connecting a client.

---

## 2. The seasonal switch

```
wf_atmos on  AND  (today is inside atmos.ini's window  OR  wf_atmos_force 1)
```

If that is false, the plugin prints one line and does nothing else — no task, no
timer, no message, no entity:

```
[WF-ATMOS] atmos idle: outside window (2026-11-22, window 12-01..12-31 (every year, config))
[WF-KF] killfeed idle: outside window (reason: plugin_cfg)
```

`wf_killfeed` has the same gate against the same window (its own copy of the
state, loaded from the same `atmos.ini`).

**When it is evaluated.** In `plugin_cfg()` — which AMX Mod X runs once per map
load — and again on `wf_atmos_apply` / `wf_killfeed_apply`. Not on a timer.

That is a real trade-off and it is the requirement's trade-off: "outside the
window: zero timers" cannot coexist with a clock that wakes up to re-check. So a
server left running across midnight on 1 December changes over at the next map
change (or immediately with `wf_atmos_apply`, which is what an admin would type
anyway). The window check itself is a date comparison, not a countdown.

**The window format** (`atmos.ini`, `[season] start` / `end`) accepts either a
recurring month-day (`12-01`, every year) or a pinned full date (`2026-12-01`).
`start` later in the year than `end` wraps the new year, so `12-20 .. 01-06` is
one window. A missing, unreadable or half-written file falls back to
`12-01..12-31` of every year and logs why: December is never dark because of an
ini mistake.

---

## 3. Config files

### 3.1 `configs/freenova/winterfest/atmos.ini`

```ini
[season]
start = 12-01
end   = 12-31
```

That is the whole file. It is intentionally the only thing in it: everything
numeric is a cvar (§1.1) because it belongs next to the rest of the server's
live settings, and the *window* is the one value that is a season rather than a
setting.

### 3.2 `configs/freenova/winterfest/killfeed.ini`

```ini
[lines]
; id | english | french | german
streak3    | {player} is on a hattrick - ho ho ho! | |
headshot   | Ho ho ho! {player} hung that one on the mantel. | |
santa      | Santa's chosen: {player} is handing out early presents. | |
```

* **One table, keyed by id.** Ids: `streak3 streak5 streak7 streak10 streak15
  headshot santa`. An unknown id is logged and ignored.
* **Three language columns: English, French, German.** English is the product
  language and is mandatory on every row — a row without it is logged and
  ignored (the built-in English line stays). **French and German ship empty on
  purpose:** the owner's audience is EU, but machine-translated festive copy
  reads worse than English, so the columns exist and are ready. An empty column
  falls back to English, so a language can be filled in row by row, later,
  without touching code or shipping a blank line.
* **Tokens, not `%s`.** `{player}`, `{victim}`, `{n}`. The substitution is a
  bounded literal copy (`WfAtmosToken`), never a printf pass, so a `%` in a line
  or in a player name is just a character. This is `tools/lint-plugins.py` rule 4
  applied to operator-written text: a format string that comes out of a file is
  a varargs read waiting to happen.
* `|` is the field separator, so a line may not contain one.
* A missing `killfeed.ini` is not silence: the plugin keeps a built-in English
  copy of the same seven lines and says so in the AMXX log.

---

## 4. What the modules never do

* They never run `plugin_end`-surviving state: no entity, no vault key, no nvault
  handle, no SQL.
* They never create an entity. Not one `CreateEntity`, not one `env_sprite` —
  snow, tints, C4 glow and the C4 "christmas light" are temp entities
  (`SVC_TEMPENTITY`) and client messages. There is no edict that could be
  orphaned, and `plugin_end()` still removes every task it owns by id and prints
  the count (§10).
* They never touch another workstream's file, and never award anything except
  through the core's ledger (§8.5).
* They never index slot 0 or `-1` for a per-player effect: every loop is
  `for (id = 1; id <= MaxClients; id++)` with `is_user_bot()` /
  `is_user_hltv()` skipped. Player 0 is only ever a *broadcast target* for the
  shared C4 glow and the announcements.

---

## 5. Snowfall (`wf_snow`)

### 5.1 How it is drawn

One repeating 0.1 s task for the whole server. Per tick, per **human, alive**
player: a flake budget (`rate × 0.1`) is added to that player's debt, and one
flake is emitted for every whole flake owed, up to 4 per tick. So
`wf_snow_rate 6` emits 0.6 flakes per tick — 6 a second on average, not a rounded
"one per tick" that would really be 10 a second.

A flake is placed in a box around the player *now*:

```
x, y  = player ± wf_snow_radius
z     = player + random(24, wf_snow_height)
fall  = 50 units/s × wf_snow_life      (the end point is straight below the start)
```

Each flake is one message, sent `MSG_ONE_UNRELIABLE` **to the player it belongs
to**, so nobody pays for anyone else's snow and nobody sees a flake hanging in
the air where another player used to be.

### 5.2 Why the flake is `TE_SPRITETRAIL` by default

`TE_SPRITE` — the obvious call, and the one the brief names — has no `life` and
no velocity: the engine plays the sprite for one cycle. `sprites/glow01.spr` is a
single 64×64 frame, so a `TE_SPRITE` flake lives about a tenth of a second. At
6 flakes/s you would see well under one flake on screen; it reads as a flicker,
not as snow. `TE_SPRITETRAIL` is the same additive stock-sprite particle with
`life` (0.1 s units) and a speed field, so `wf_snow_life` means something and
each flake visibly falls.

Both are one sprite and one message, so the cost is identical.
`wf_snow_kind 0` switches back to the literal `TE_SPRITE` if that is what you
want to compare on a real client — that comparison is a "needs a human eye" item
in §11.

### 5.3 Cost

| | messages | bytes/s/player | 32 players |
| --- | --- | --- | --- |
| `wf_snow_rate 6` (default) | 6/s | ~170 B/s | ~5 KB/s total |
| `wf_storm_rate 18` (storm) | 18/s | ~540 B/s | ~17 KB/s total |

Unreliable, one sprite per message, no entity, no per-frame work, and a hard cap
of 4 flakes per player per tick so an absurd cvar cannot become a packet storm.
With no human on the server the timer still runs and emits nothing at all —
`wf_atmos_report` shows `humans=0 bots_skipped=6` to prove it (bots have no eyes
and are excluded by rule 4 of the workstream map).

---

## 6. Snowstorm (`wf_storm`) — and what it cannot be

Setting `wf_storm 1` (and applying, or on the next map load) opens a **window**:

1. `wf_storm_len` seconds (default 90), `wf_storm_rate` flakes/s/player
   (default 18 — three times the calm rate).
2. A chat line and a centre-of-screen line, immediately.
3. An ice-blue `ScreenFade` (150,185,225 @ alpha 45) for every human, refreshed
   every 6 s for as long as the window lasts. The fade is deliberately far below
   `freenova_flash`'s near-white gate (R,G,B ≥ 200 **and** alpha ≥ 200), so the
   single ScreenFade owner in this stack never suppresses it.
4. A `ScreenShake` nudge (amplitude 6, frequency 45, 30 units) with the same
   refresh — a view wobble, not a camera.
5. When the window ends the plugin prints "the snowstorm has passed", removes
   both tasks **and sets `wf_storm` back to 0**, so the next map does not inherit
   a storm nobody asked for. If the map ends mid-storm, `plugin_end` clears the
   switch and says so (§10).

**What a snowstorm cannot do on GoldSrc, stated plainly:**

| wanted | why not | what ships instead |
| --- | --- | --- |
| reduced visibility / real fog | fog is a **map property** (worldspawn / `env_fog` compiled into the `.bsp`, rendered client-side). No server message changes it, and the map is a client download | denser snow, a pale tint and a shake |
| wind, drifting snow, snow lying on the ground | no engine weather, no decal that survives without a map edit | nothing — the flakes fall, they do not accumulate |
| slippery ice, reduced traction | movement physics come from the map's surface properties | nothing |
| thunder/storm audio | any `.wav` is a client download (fastdl is blocked) | silent |
| snow that hides players | needs fog or client-side occlusion | nothing |
| "heavy snow" honestly | the flakes are stock additive sprites, not a particle system | 3× density, faster fall, a tint |

The one thing that *is* available, `sv_...` fog-free visibility tricks, does not
exist in this engine build; the honest answer is "a custom winter map, the day
fastdl works" ([WINTERFEST.md](WINTERFEST.md) §1.1, §4 Phase 3).

---

## 7. Christmas C4 (`wf_bombfx`)

With `wf_bombfx 0` no handler runs at all — not one sprite, message or line.
With it on (and the season open):

| event | what happens |
| --- | --- |
| `bomb_planted` | 0.2 s later (the entity can lag the forward by a frame) find `planted_c4` and take its origin; if the entity is not there, fall back to the planter's origin and log it. Three `sprites/glow01.spr` sprites at the C4, a chat line, a warm red tint (alpha 55, 1 s) to every human, and a 1 s repeating task |
| the planted C4, 1/s | a 24-unit `sprites/laserbeam.spr` column above the C4, alternating red / green: the cheapest Christmas light GoldSrc has (a beam carries RGB; `TE_SPRITE` cannot be coloured) |
| `bomb_defused` | column stopped, a farewell glow, a green tint and its own line |
| round start | one chat line (three variants) and a 0.6 s pale wash (alpha 30) for every human. **No glow**: at round start there is no bomb origin — the C4 is not planted yet — and sprites at arbitrary points would be noise |
| round end | column stopped, state cleared (covers "the C4 exploded", which has no csteam forward) |
| map end | every task removed, the column gone, no entity left behind |

The bomb effects are **not** persisted anywhere: they are a decoration for the
current round, and a `wf_bombfx 1` server that never plants a C4 does nothing.

---

## 8. Festive kill feed (`wf_killfeed`)

### 8.1 What is announced

| trigger | line id | default English |
| --- | --- | --- |
| 3 kills in a round | `streak3` | `{player} is on a hattrick - ho ho ho!` |
| 5 | `streak5` | `{player} has five in a row and a stocking full of grenades.` |
| 7 | `streak7` | `{player} is on Santa's nice list - {n} straight.` |
| 10 | `streak10` | `{player} is a one-elf army - {n} kills without dying.` |
| 15 | `streak15` | `{player} IS Santa's chosen - {n} kills in a row!` |
| any headshot | `headshot` | `Ho ho ho! {player} hung that one on the mantel.` |
| any kill, `wf_kf_santa` % | `santa` | `Santa's chosen: {player} is handing out early presents.` |

Streaks are **per round**: the HLTV new-round event clears every counter, so "15
in a row" means 15 in one round. A death always ends the victim's streak, even to
a bot.

Bots: a **bot killer** never announces and never counts (`bots_ignored` in the
report). A **bot victim** does count as a kill — on a bot-filled server the
alternative is a feed that almost never fires, and the human still had to make
the shot. If that is the wrong call for the live mix, it is one `if` in
`OnDeath`.

The feed **augments**; it never replaces. Nothing in the stack currently
announces streaks (`freenova_clutch`, `freenova_progression`, `freenova_teamxp`,
`rsu_botxp` all read `DeathMsg` but none of them print a streak line), and this
plugin only reads the event.

### 8.2 Why the wording table is not a printf format

See §3.2: tokens + literal print formats. `tools/lint-plugins.py` rule 4 is about
exactly this class of bug (REVIEW.md 5.5), and operator-editable text is the
worst possible place to treat a string as a format.

### 8.3 Language

`wf_kf_lang en|fr|de` selects the column, and an empty column falls back to
English. The harness proves the fallback end to end: the probe re-applies with
`wf_kf_lang fr` while the French column is empty, and the self-test prints
`selftest lang=1 fallbacks=7` with every row still rendering its English text
(`selftest streak10[0]: ...` — column 0, not 1). English is the product
language; the FR/DE slots are ready for a translator, not for a machine.

### 8.4 The optional snowflake award

With `wf_kf_reward 1`, a 10- or 15-streak also grants 2 snowflakes **through
`winterfest_core`'s single grant path**, with the claim key
`kf_streak<streak>_<authid>_<round>` — so a retry cannot pay twice and the
milestone pays once per player per round.

Three guards, all of them required before that call is reachable:

1. `wf_kf_reward 0` removes it entirely (the kill path is then the whole plugin);
2. `LibraryExists("winterfest_core", LibType_Library)` must succeed;
3. `plugin_natives()` installs `set_native_filter("KfNativeFilter")` — the
   `fn_servers.sma` pattern — so a declared `wf_*` native that no loaded library
   registers degrades to a stub instead of a **bad load**.

A server without the core runs every announcement unchanged. That is what rule 2
of the workstream map asks for, and the harness tree currently *has* the core
loaded (workstream 1 tests in the same tree), which is why the report line reads
`core=1` there; with `wf_kf_reward 0` the difference is not observable at all.

---

## 9. Precache cost — measured

Two `precache_model` call sites, both stock, both already in the table:

| sprite | who else precaches it (live stack) | new items |
| --- | --- | --- |
| `sprites/glow01.spr` | `winterfest_gifts`, `winterfest_snow`, `winterfest_reindeer` | 0 |
| `sprites/laserbeam.spr` | `freenova_cosmetics` (and the three above) | 0 |

* **Distinct new items with the Winterfest stack deployed: 0.**
  Loaded alone, the module would cost 2 — that is the number to quote if
  everything else is ever removed.
* Runtime evidence from the harness boot: `precache_model` returned
  `glow01=115 laserbeam=112`, i.e. both already had an index in the table before
  this plugin asked for them (a fresh item would have been allocated at the end).
* `tools/precache-report.py` on the live plugin list: **130 named / 52
  worst-case plugin-side items** (77 plugins, `weapon_models` is 97 of them).
  `docs/PRECACHE-BUDGET.md` §8: `de_dust2` = map 43 + plugins 130 = **173/512**.
  This module adds nothing to either side.
* `sprites/white.spr` is **not** used: it is not in the live client mirror
  (`cstrike/sprites/`), so precaching it would fail the map load for no reason.
  `sprites/flare1.spr` is not used either — `glow01` already reads as a speck and
  `laserbeam` is the only one that can be coloured.

No `.mdl`, no `.wav`, no `.bsp`, no `precache_generic`. The map budget is
untouched, which matters because `de_torn` and `de_piranesi` are already fatal
on this stack (`docs/PRECACHE-BUDGET.md` §2).

---

## 10. What the harness proved

Three scripted boots in `cs16-linux-base`, profile `freenova` (the real live
stack: 81 plugins running with these two loaded, 12/12 modules correct),
`--bots 2` on the first two, all under `flock /tmp/cs16-harness.lock`. The two
binaries in `plugins/` are the ones that ran (sha256 in §12). The test plugins
live in the harness repo, `tests/atmos/`, next to `tests/modes/` — the
established place for probes. The two plugin lines were appended to the profile's
`plugins.ini` for each run and the file was restored afterwards.

```bash
./scripts/test-plugin.sh tests/atmos/atmos_probe.sma     --profile freenova --bots 2
./scripts/test-plugin.sh tests/atmos/atmos_mapchange.sma --profile freenova --bots 2
./scripts/test-plugin.sh tests/atmos/wf6win.sma          --profile freenova   # §10.3
```

### 10.1 Boot 1 — the modules load, the gate is closed, then opened

`RESULT ok slug=atmos_probe`. Console log `artifacts/atmos_probe/console.log`:

```
[FreeNova winterfest_atmos] ready (build 3, 14 cvars, 3 commands, 5 tasks)
[FreeNova winterfest_killfeed] ready (build 3, 6 cvars, 3 commands, 1 event)
[WF-ATMOS] atmos idle: outside window (2026-11-22, window 12-01..12-31 (every year, config))
[WF-KF] killfeed idle: outside window (reason: plugin_cfg)
...  wf_atmos_force 1 ; wf_killfeed_force 1 ; wf_atmos_apply
[WF-ATMOS] active (wf_atmos_apply): window 12-01..12-31 (every year, config) open=0 forced=1 snow=1 rate=6 radius=300 height=220 life=8 scale=2 kind=1 bombfx=1
[WF-ATMOS] timers snow=1 storm_end=0 storm_pulse=0 bomb_find=0 bomb_pulse=0
[WF-ATMOS] last_tick humans=0 bots_skipped=6 flakes_dropped=0
...  wf_atmos_test
[WF-ATMOS] selftest flake ok kind=1 sprite=115 life=8 scale=2
[WF-ATMOS] storm started (90s, 18 flakes/s/player, reason: selftest)
[WF-ATMOS] selftest bombfx ok glow=3 column=1 lines=1
[WF-ATMOS] selftest fade ok fade_msg=98 shake_msg=97 sent_to_client=0
[WF-ATMOS] timers snow=1 storm_end=1 storm_pulse=1
[WF-ATMOS] counters flakes=1 fades=0 shakes=0 pulses=1 storms=1 bomb_pulses=0
...  wf_killfeed_test
[WF-KF] active (wf_killfeed_apply): lang=en table=killfeed.ini lines=7 forced=1 reward=1 core=1
[WF-KF] selftest streak3[0]: TestPlayer is on a hattrick - ho ho ho!
[WF-KF] selftest streak15[0]: TestPlayer IS Santa's chosen - 7 kills in a row!
[WF-KF] selftest headshot[0]: Ho ho ho! TestPlayer hung that one on the mantel.
[WF-KF] selftest santa[0]: Santa's chosen: TestPlayer is handing out early presents.
...  wf_kf_lang fr ; wf_killfeed_apply ; wf_killfeed_test
[WF-KF] active (wf_killfeed_apply): lang=fr table=killfeed.ini lines=7
[WF-KF] selftest streak10[0]: TestPlayer is a one-elf army - 7 kills without dying.
[WF-KF] selftest lang=1 fallbacks=7 (an empty column falls back to english)
```

Read that as: **zero** timers while the gate is shut; after opening, **exactly
one** snow task and nothing else; the storm window then owns exactly two more;
the snow loop counted 6 bots and gave none of them a flake (`flakes=1` is the one
the self-test asked for, `humans=0`); both `ScreenFade` (98) and `ScreenShake`
(97) exist in this gamedll; the wording table came from `killfeed.ini` with 7
rows and all tokens substituted.

Standard harness assertions on the same run: `81 plugins, 81 running`,
`all 12 modules correct`, `no runtime errors`.

### 10.2 Boot 2 — the map change, and the end of the timers

`RESULT ok slug=atmos_mapchange`. Same stack; the commands are
`wf_atmos_force 1`, `wf_storm 1`, `wf_bombfx 1`, `wf_atmos_apply`,
`wf_atmos_report`, `changelevel de_inferno`, then 60 console padding lines and a
second report.

```
[WF-ATMOS] timers snow=1 storm_end=1 storm_pulse=1        <- three tasks, storm running
[WF-ATMOS] timers stopped (map end: 3 task(s) removed, 0 flake(s) emitted over the map, 0 entities created, storm switch cleared=1)
[WF-ATMOS] precache asked for 2 stock sprites (glow01=115 laserbeam=112)   <- reloaded on de_inferno
[WF-ATMOS] active (plugin_cfg): window 12-01..12-31 (every year, config) open=0 forced=1 snow=1 ...
[WF-ATMOS] timers snow=1 storm_end=0 storm_pulse=0 bomb_find=0 bomb_pulse=0 <- snow only, no inherited storm
```

* **Timers stop**: three tasks removed by id at map end, and the new map starts
  with one.
* **The storm switch is cleared, not inherited**: `storm switch cleared=1`, and
  the reloaded plugin shows `storm=0` even though the *player-facing* intent
  (`wf_storm`) was set for the previous map.
* **No edict leak**: `ED_Alloc` and `no free edicts` are asserted absent, and the
  plugin's own line says `0 entities created` — because it never creates one.
  (`edicts=` in the report is the *map's* total and legitimately differs between
  `de_dust2` and `de_inferno`; comparing it across maps proves nothing, which is
  why the structural claim is the one that is written down.)

Both boots also run the harness' standard `no runtime errors` assertion (no
`Run time error`, no `Plugin terminated`, no `bad load`), and both passed.

### 10.3 The window parser, on the product's own date shape

One more short boot shares the same probe with a variant `atmos.ini` written the
way `season.ini` writes dates (a time of day after the date, pinned to 2026):

```ini
[season]
start = 2026-12-01 00:00
end   = 2026-12-31 23:59
```

```
[WF-ATMOS] atmos idle: outside window (2026-11-22, window 2026-12-01..2026-12-31 (config))
```

So the loader accepts the product's format (the time of day is cut at the first
space; only calendar dates are compared), reports the pinned year, and still
closes the gate on 22 November.

### 10.4 Tree-wide

* `bash tools/compile-plugins.sh` -> **151 compiled, 1 failed**. The failure is
  another workstream's in-flight file (`winterfest_cosmetics.sma`:
  `std::bad_alloc`, i.e. the compiler could not write the output), not one of
  these. `winterfest_atmos.sma` and `winterfest_killfeed.sma` both `PASS`, and an
  `--only` build of just those two is `compiled: 2 failed: 0`.
* `python3 tools/lint-plugins.py` -> **152 files, 0 errors, 38 allowed** — the
  same 38 documented allowances as before this work, none of them mine.

---

## 11. What needs a human eye in game

The harness proves the code paths, the gate, the task lifecycle and the absence
of edicts. It cannot prove a single frame of it looks right. These are the
judgement calls, in the order I would check them:

1. **Snow density and size** (`wf_snow_rate`, `wf_snow_scale`). 6/s at 0.2 scale
   is deliberately light. Does a 64px soft glow at ~13 units read as a snowflake,
   or as a speck of dust on the lens? `wf_snow_scale 3` and `wf_snow_rate 10` are
   the next stops.
2. **The fall** (`wf_snow_life`, `wf_snow_kind`). 0.8 s over 40 units is 50 u/s —
   slower than a running player. Compare `wf_snow_kind 1` (trail, falls) against
   `wf_snow_kind 0` (literal `TE_SPRITE`, engine-fixed ~0.1 s): the second is the
   "flicker" the brief's `TE_SPRITE` sentence implies, and it is worth seeing
   once to know why the default is the other one.
3. **The box** (`wf_snow_radius` 300, `wf_snow_height` 220). Does snow appear at
   eye level and above, or only in the bottom half of the screen? On a small
   map, 300 units of radius may put flakes inside walls (they are additive and do
   not collide — they will show through geometry, which is a known trade-off of
   temp-entity weather, not a bug to fix by adding tracelines).
4. **The storm tint** (`STORM_FADE_SECS`, alpha 45, 150/185/225). Does 90 seconds
   of pale ice read as weather or as a broken gamma? Does it fight the
   flashbang/`freenova_flash` path in practice?
5. **The storm shake** (amplitude 6, frequency 45). A nudge or nausea? The
   amplitude is the first thing to cut; it exists because the brief asked for a
   view punch and `ScreenShake` is the only server-side way to do it.
6. **The C4 column** — visible enough to find the bomb through a wall of bodies
   without reading as a laser sight? 1/s at brightness 180, 24 units tall.
7. **The C4 tints at plant/defuse** — red 55 / green 60 alpha for 1 s. Too
   subtle? Too much in a 1v1 clutch?
8. **The round-start line and wash** — one chat line and a 0.6 s alpha-30 wash
   per round. On a 30-round match that is 30 of each; is that festive or
   wallpaper? The wait for freezetime to end is the moment it either lands or
   grates.
9. **Kill-feed spam** at 3/5/7/10/15 *plus* a headshot line *plus* 2 % Santa. A
   headshot-heavy server will see the "ho ho ho" line a lot. `wf_kf_santa 0` and
   the wording table are the knobs.
10. **Two players in one room**: nobody should see a flake that belongs to
    someone else's box. That is what `MSG_ONE_UNRELIABLE` guarantees, but it is
    worth watching for a minute with two clients.

Anything in that list is a cvar or a one-line edit — none of it needs a rebuild
except the tint colour and the shake amplitude, which are constants at the top of
`winterfest_atmos.sma`.

---

## 12. Files and digests

```
86fce5327f71a6f92d578c81b86261bcba188867d6b615423399a40ad9c293b5  winterfest_atmos.sma
78b4fba982be54da7928c2d8523efe861118a8058a08296489b72f509431fc0c  winterfest_killfeed.sma
2ab2954e5029cfd8f02b84e9a46d8b072dd552f091a5ebf02299d5d80ffd1229  include/winterfest_atmos.inc
4c70f89d8f090ffc6e670fae7c1b3e81c423e6fd7de57bc68bbc436fdc372af4  configs/freenova/winterfest/atmos.ini
5942c829942883f0642e8d21faccd8c80659778e997c997c3c224cda2955fed0  configs/freenova/winterfest/killfeed.ini
dc09d2f03766d7c390f7c17b792b1a4889bce2bb82579591a408675968ff110f  plugins/winterfest_atmos.amxx
6f9b1c0a8c96d56f90048f6ed0cd444d63a60278f4b3d8ba4181e05d003d0c08  plugins/winterfest_killfeed.amxx
```

Both `.amxx` were built from these sources with the tree's own compiler
(`tools/compile-plugins.sh`, AMXX 1.10.0.5467) and the harness ran exactly these
bytes. `amxxpc` output is not bit-reproducible (two builds of an unchanged
source differ), so the digests above identify the binaries that were tested, not
a reproducible artefact.

The coordinator adds these two lines to
`game-server/cstrike/addons/amxmodx/configs/plugins.ini` — this workstream does
not edit that file:

```
winterfest_atmos.amxx
winterfest_killfeed.amxx
```

---

## 13. Operator cookbook

| want | do |
| --- | --- |
| the mood in November (rehearsal, screenshot, stream) | `wf_atmos_force 1`, `wf_killfeed_force 1`, then `wf_atmos_apply` / `wf_killfeed_apply` |
| a different season window | edit `[season]` in `atmos.ini`, then `wf_atmos_apply` |
| a snowstorm right now | `wf_storm 1`, `wf_atmos_apply`. It ends itself after `wf_storm_len` and sets the cvar back to 0. Applying again while it runs starts a **fresh** window (the apply path is "re-arm", not "resume") |
| end a storm early | `wf_storm 0`, `wf_atmos_apply` (kills the storm tasks; the snow timer restarts at the calm rate) |
| quieter or heavier snow | `wf_snow_rate`, live; the next 0.1 s tick uses it |
| no C4 decoration at all | `wf_bombfx 0` — every bomb handler returns immediately |
| kill feed off | `wf_killfeed 0` |
| a French column | fill the 3rd column in `killfeed.ini`, `wf_killfeed_apply`, `wf_kf_lang fr` |
| nothing at all, ever | `wf_atmos 0`, `wf_killfeed 0`; or remove the two lines from `plugins.ini` |
| "is it running?" | `wf_atmos_report` / `wf_killfeed_report` |

---

## 14. Notes for the coordinator

* **Two season windows exist, on purpose, and one of them is mine.**
  The product's gate is `configs/freenova/winterfest/season.ini`'s
  `[season] start/end` (**2026-12-01 .. 2026-12-24**, owner decision
  [WINTERFEST.md](WINTERFEST.md) §6.3), read by `winterfest_core` and asked by
  every module as `wf_season_open()`. This workstream's cosmetic window is
  `configs/freenova/winterfest/atmos.ini`, **12-01 .. 12-31 every year**: the
  atmosphere gates no reward, so the room stays decorated through New Year, and
  it is one line to change if the coordinator wants the two identical (or
  `end = 01-06` for Twelfth Night — the loader wraps the new year). The two files
  are independent by design: deleting `atmos.ini` does not touch the season, and
  a broken core does not stop the snow.
* **`de_tuscan` and any future map.** These modules have **no per-map table** —
  no origins, no spots, no map keys. A map nobody has measured behaves exactly
  like `de_dust2`: there is no entry to miss, and the precache cost is the same
  two already-present sprites. (The thing that can take a new map down is the
  map's own precache; `docs/PRECACHE-BUDGET.md` §8 and
  `tools/precache-report.py --map <name> --map-dir <live cstrike/maps>` are the
  check.)
* **The core.** Both modules are standalone. `winterfest_atmos` declares no core
  native at all; `winterfest_killfeed` declares one (`wf_grant`) behind
  `set_native_filter` + `LibraryExists` + `wf_kf_reward`, so a missing or
  renamed core cannot fail the load or the plugin.
* **Two boots to re-run after any change** to these files:
  `tests/atmos/atmos_probe.sma` and `tests/atmos/atmos_mapchange.sma` with
  `--profile freenova --bots 2`, under `flock /tmp/cs16-harness.lock`. They take
  about 25 s and 45 s.
