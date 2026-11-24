# Winterfest — progression extras (workstream 9)

Christmas missions, seasonal achievements and the daily login gift: the seasonal
layer that appears only inside the December window and disappears in January
without touching the year-round systems.

Product contract: `docs/WINTERFEST.md` §1/§4/§6. Module map:
`docs/WINTERFEST-WORKSTREAMS.md` row 9. Everything below is this module's own
implementation record — what it owns, how it is wired, what it proves and what it
still needs from `winterfest_core`.

---

## 1. Why it is a separate plugin

The live tree already has `freenova_missions` (48 contracts from
`configs/freenova/missions.ini`) and `freenova_achievements`. Both are general,
year-round systems with their own slots, own ledgers and own owners.
`freenova_missions` in particular packs contract status into fixed sync digits
that the panel reads by slot index: adding seasonal rows there would change a
server protocol that other things depend on.

So Winterfest gets an **additive** layer:

| file | owner | read by |
| --- | --- | --- |
| `scripting/winterfest_progress.sma` | this workstream | AMXX |
| `configs/freenova/winterfest/progress.ini` | this workstream | this plugin (season window, login bundle, legendary rarity) |
| `configs/freenova/winterfest/missions.ini` | this workstream | this plugin |
| `configs/freenova/winterfest/achievements.ini` | this workstream | this plugin |
| `docs/WINTERFEST-PROGRESS.md` | this workstream | humans |
| `tests/winterfest-progress/**` | this workstream | the ReHLDS harness |

`freenova_missions`, `freenova_achievements`, `plugins.ini`, `winterfest.ini`,
`events.ini` and the panel are **not touched**. Deleting the three seasonal ini
files stops the seasonal content and leaves the base rotation exactly as it is.

Nothing is Christmas-hardcoded: the season name, year, dates, the login bundle,
the "legendary" rarity index, every contract and every badge are data.

---

## 2. The season window (`progress.ini`)

```ini
[season]
name    = Winterfest 2026
year    = 2026
start   = 2026-12-01 00:00
end     = 2026-12-24 23:59
enabled = 1

[login]
enabled    = 1
snowflakes = 25

[settings]
legendary_rarity = 2
```

* `year` stamps **every** nvault key and every claim key this module writes, so
  December 2027 (`year = 2027`, new dates) starts clean without deleting 2026.
* Dates are read against the **server clock**. The live box runs Europe/Paris;
  AMXX has no timezone database, so the timezone in the brief is documentation
  for the reader, not a conversion. A UTC box moves the boundary by an hour or
  two — that changes *when* the window opens, never whether a reward pays twice.
* The window here is the Advent deadline (24 December 23:59) rather than the
  core's 31 December, on purpose: missions, badges and the daily login belong to
  the calendar part of the season. The core keeps its own, wider window.

### Outside the window nothing loads

`plugin_init()` reads `progress.ini` first and, when the window is shut, returns
after **one** log line. Nothing else happens:

* the missions and achievements files are **not read**;
* the vault is **not opened** (`freenova_wfprog` does not even exist yet);
* no `register_event`, `register_logevent`, `register_concmd`,
  `register_clcmd` and no `set_task` runs;
* therefore `/christmasmissions` and `/christmasrank` are not registered
  commands at all — a player typing them gets no line, not even "the season is
  closed";
* the plugin still *loads* (it registers its library and two natives), so
  "dormant" is visibly a decision rather than a missing file.

The line, from the verified closed-season run (§9):

```
L 11/22/2026 - 20:15:54: [winterfest_progress.amxx] [WF-PROG] season 2026
  window 20261201-00 .. 20261224-1439, now 20261122-1215 -> CLOSED; dormant:
  content not read, no vault, no hooks, no commands, no messages
```

`window 20261201-00 .. 20261224-1439` is `YYYYMMDD-minutes`: 1 December 00:00 to
24 December 23:59. `now` is the same encoding of the server clock.

Once a season *is* open at map start and then closes mid-map (a server that
crosses midnight without changing maps), a 60 s gate task flushes every dirty
record and logs one line:

```
[WF-PROG] the window closed mid-map - progress saved, every hook is now silent
```

From that moment every callback returns on its first line (`if (!g_bOpen)`), so
no progress moves and no message appears. The next map start registers nothing.

---

## 3. Seasonal missions (`missions.ini`)

Same file shape as the base `missions.ini` — same `[settings]`, same `[mission]`,
same ten columns in the same order — so the panel's contract renderer can read
these rows with its existing parser. Two columns mean Winterfest things because
Winterfest has no coins and its XP is the Winter Pass:

| column | base meaning | here |
| --- | --- | --- |
| `xp` | BattlePass XP | **Winter Pass XP** |
| `coins` | coins | **the season currency** (GingerBread, id `gb`; `snowflakes` is the legacy name for the same reward kind — `docs/WINTERFEST-DEV.md`) |
| `metric` | 8 base metrics | the vocabulary in §3.2 (**superset**) |
| `tags` | free-form | free-form, plus `map=<name>` for `map_rounds` |

### 3.1 The contract list (14 contracts, 20 rows)

Type is the period: `daily` resets at midnight server time, `weekly` on the ISO
week, `season` runs for the whole window.

| key | type | slot | id (row) | metric | target | pays (currency / pass XP) |
| --- | --- | --- | --- | --- | --- | --- |
| `d0` | daily | 0 | `daily_presents_3` / `_5` | presents | 3 **or** 5 | 80/60 or 120/80 |
| `d1` | daily | 1 | `daily_opens_2` / `_3` | opens | 2 **or** 3 | 60/50 or 90/70 |
| `d2` | daily | 2 | `daily_kills_10` / `_20` | kills | 10 **or** 20 | 100/80 or 150/120 |
| `d3` | daily | 3 | `daily_headshots_3` | headshots | 3 | 80/60 |
| `d4` | daily | 4 | `daily_rounds_5` | rounds | 5 | 60/40 |
| `w0` | weekly | 0 | `weekly_presents_25` / `_40` | presents | 25 **or** 40 | 300/250 or 450/350 |
| `w1` | weekly | 1 | `weekly_opens_15` | opens | 15 | 250/200 |
| `w2` | weekly | 2 | `weekly_streak_6` / `_9` | streak | 6 **or** 9 | 250/200 or 350/300 |
| `s0` | season | 0 | `season_dust2_10` | map_rounds (`de_dust2`) | 10 | 200/150 |
| `s1` | season | 1 | `season_mirage_8` | map_rounds (`de_mirage`) | 8 | 200/150 |
| `s2` | season | 2 | `season_advent_12` | advent | 12 days | 300/250 |
| `s3` | season | 3 | `season_collection_1` | sets | 1 collection | 400/300 |
| `s4` | season | 4 | `season_tree_3` | tree | level 3 | 300/250 |
| `s5` | season | 5 | `season_legendary_2` | legendary | 2 finds | 500/400 |
| — | season | 6 | `season_snowball_1` | snowball_hs | 1 | **staged** (weight 0) |

**Variants.** Rows sharing a type+slot are target variants: one is picked per
player, weighted, *deterministically* from
`steamid # season # slot # period`. A reconnect inside the same period therefore
keeps the contract the player is half-way through — and a bigger target may pay
more, because the reward is stored with the variant (not with the slot).

**Staged row.** `season_snowball_1` is `weight 0`: the contract is in the file,
in the panel's data and in this document, but it is never rolled, so a mode that
has not shipped cannot leave a dead contract on a player's board. Turning it on
is a one-character edit the day workstream 7 reports the metric (§7).

**Refused rows** (logged, never fatal): an unknown type/metric, a target ≤ 0, a
slot outside `daily 0-5 / weekly 0-3 / season 0-7`, `map_rounds` without a
`map=` tag, and `tree`/`pass_tier` in a daily or weekly contract — a *level* does
not reset, so a daily "reach tree level 3" would instantly pay every day.

### 3.2 Metric vocabulary and how each moves

| metric | class | source |
| --- | --- | --- |
| `kills` `headshots` | EVENT | rsu_core's `fn_on_player_kill` forward (DeathMsg fallback) |
| `streak` | MAX | the same event; the run resets on death |
| `rounds` `map_rounds` | EVENT | the `HLTV` round-start event |
| `wins` | EVENT | rsu_core's `fn_on_round_win` forward (survivor fallback) |
| `presents` | COUNTER | highest present instance id the core has ever handed out |
| `opens` | COUNTER | `(presents collected) − (presents carried)`, both read in one tick |
| `legendary` | COUNTER | top-rarity present seen in the bag and then gone (opened) |
| `advent` | COUNTER | `wf_advent_claimed()` for days 1..24 |
| `sets` | COUNTER | `wf_set_owned()` over `wf_set_count()` |
| `tree` | LEVEL | `wf_tree_level()` |
| `pass_tier` | LEVEL | `wf_pass_tier()` |
| `snowball_hs` | EVENT | `wfprog_report()` from the gameplay module (§7) |

EVENT metrics are pushed by hooks. COUNTER metrics are *cumulative* numbers the
core already owns, so a contract stores the reading it started the period at
(`last`) and progress is the delta since: "collect 3 presents **today**" cannot
be satisfied by last week's collection. LEVEL metrics are used as-is and are
therefore season-only.

---

## 4. Seasonal achievements (`achievements.ini`)

12 badges, one per achievable thing:

| id | name | check | target | pays | badge |
| --- | --- | --- | --- | --- | --- |
| `ach_first_present` | First Snow | presents | 1 | 50/40 | First Snow |
| `ach_ten_presents` | Gift Gatherer | presents | 10 | 200/150 | Gift Gatherer |
| `ach_first_open` | Wrapper Ripper | opens | 1 | 50/40 | Wrapper Ripper |
| `ach_ten_opens` | Unwrapping Pro | opens | 10 | 200/150 | Unwrapping Pro |
| `ach_legendary_find` | Legendary Find | legendary | 1 | 500/400 | Legendary Find |
| `ach_secret_collection` | Secret Collector | sets | 1 | 500/400 | Secret Collector |
| `ach_advent_1` | Advent Starter | advent | 1 | 100/80 | Advent Starter |
| `ach_advent_24` | Advent Faithful | advent | 24 | 1000/800 | Advent Faithful |
| `ach_tree_5` | Tree Whisperer | tree | 5 | 500/400 | Tree Whisperer |
| `ach_streak_8` | Blizzard Streak | streak | 8 | 300/250 | Blizzard Streak |
| `ach_rounds_50` | Season Regular | rounds | 50 | 300/250 | Season Regular |
| `ach_pass_10` | Pass Rider | pass_tier | 10 | 400/300 | Pass Rider |

The four the brief names are there: opened a legendary present
(`ach_legendary_find`), completed a secret collection — a **core set**, queried
with `wf_set_owned` (`ach_secret_collection`), 24 of 24 Advent days
(`ach_advent_24`), tree level 5 (`ach_tree_5`).

**"Permanent badge" means permanent.** The unlock is written to an unseasoned
key, `wfprog_badge#<steamid>`, so a badge earned in December 2026 is still shown
in December 2027. The **reward** is per season (`year` is in the claim key), so
next December's badge pays next December's reward once and the old claim stays
spent.

`presents`/`opens`/`legendary` are cumulative totals this module keeps;
`advent`/`sets`/`tree`/`pass_tier` are read from the core; `kills`/`headshots`/
`streak`/`rounds`/`wins`/`snowball_hs` are the season totals this module counts.
`map_rounds` is refused for a badge: an achievement has no map column, so a
map-specific badge would be dead by construction.

---

## 5. The claim-key scheme (idempotency)

Every payment goes through `wf_grant()` in `winterfest_core`, never a direct
write. The core hashes the claim string (CRC32) and stores it under
`wf_claim_s<year>#<authid>#e<epoch>#<hash>` **before** it pays, so a spent claim
can never pay twice. This module's claim strings:

| what | claim string | where the identity comes from |
| --- | --- | --- |
| daily login | `wfprog_login#<season>#<YYYYMMDD>#<steamid>` | season + **date** + steamid, exactly as the brief specifies |
| contract | `wfprog_m#<season>#<contract key>#<period>#<steamid>#gb` and `… #xp` | the contract's *period*, so the same contract next day/week/season is a new claim and the same one is not |
| achievement | `wfprog_a#<season>#<achievement id>#<steamid>#gb` / `#xp` | season + badge id |

Notes that matter in an incident:

* **Two rewards per payment** = two claim keys (`#snow`, `#xp`). If the second
  fails, the first is already spent; the module marks the contract paid on `OK`
  **or** `DUPLICATE` (fail closed — never retry a possibly-paid claim) and only
  retries on `WF_GRANT_NOTLOADED`, which the core returns *before* touching the
  ledger. A crash between the two grants can therefore underpay once, never pay
  twice.
* The module ALSO keeps its own `paid` flag per contract per period, which is
  what stops it re-attempting every 2 s. That flag is not the safety net; the
  claim key is. The harness proves the claim key by wiping the local flag and
  earning the same contract again — see §9.
* Badges are written **after** the payment. A crash between them re-earns the
  badge on the next connect, the core refuses the second payment (codes `0/0`),
  and the badge is written. The failure mode is "badge shows up a bit late".
* `wfprog_reset` clears this module's records only. It does **not** undo the
  core's claim ledger, so an operator who wants a player to earn rewards again
  must run the core's `wf_reset` too. That is deliberate: a seasonal reset
  command that could re-open payouts would be a dupe bug.

---

## 6. Persistence, periods and reconnects

One private vault, `freenova_wfprog` (`data/vault/`), three key shapes:

```
wfprog_s<year>#<auth>#meta          "1 <giftseq> <carried> <opens> <legendary>
                                       <streak> <rounds> <wins> <kills> <hs>
                                       <snowball> <logindate>"
wfprog_s<year>#<auth>#<contract>    "<progress> <period> <paid> <last counter>"
wfprog_badge#<auth>                 "1,4,7"        (permanent, not season-stamped)
```

* One key per contract, so a corrupted contract cannot take the rest of the
  record with it and adding a contract to the ini does not change the layout of
  the stored ones. A key longer than 63 characters is refused with a log line,
  never truncated (two truncated keys would alias two players).
* **Period strings** — `d20261201`, `w2026-48`, `s2026` — are stored with the
  progress. A period change resets *once*, on the first read after midnight / the
  ISO week / the season; a reconnect inside the period reads the same numbers
  back. The rolled variant is derived from `steamid#season#slot#period`, so it is
  stable across reconnects too.
* Saved on `client_disconnected`, on `plugin_end` (map change), and by one 30 s
  autosave task that writes only dirty records. Nothing is ever "saved later by
  someone else".
* A record is loaded ~1 s after connect and retried while the steamid is still
  `STEAM_ID_PENDING` (8 tries, then the session runs memory-only with a log
  line) — a record keyed on `STEAM_ID_PENDING` would be shared by every player on
  the box.
* `wfprog_reload <player>` drops the in-memory record and re-reads the vault:
  that is exactly what a reconnect does, and it is how the harness proves
  persistence without a second client.

---

## 7. Event wiring, and the one thing that is polled

| source | why |
| --- | --- |
| rsu_core forward `fn_on_player_kill` | kills + headshots + the streak (the tree's canonical combat event, the same one `freenova_missions` and `battlepass_core` use) |
| `DeathMsg` event | streak reset for the victim, and the kill counter when rsu_core is absent (decided per event, so plugin order cannot double-count) |
| rsu_core forward `fn_on_round_win` | round wins; `Round_End` with "one team left standing" is the fallback |
| `HLTV` round start | `rounds` and `map_rounds` (a round that starts while you are connected was played) |
| `wfprog_report()` native | metrics only another module can see (today: grid 7's snowball headshot) |
| 2 s task | **the core's present inventory**: collected / opened / legendary |
| 10 s task | the core's counters with no event: advent days, sets, tree level, pass tier |
| 30 s task | autosave |
| 60 s task | the window gate (§2) |

Why a tick at all, and why 2 s: `winterfest_core` exposes the present inventory
only through pull natives (`wf_gift_count`, `wf_gift_instance`,
`wf_gift_rarity`) and publishes **no** "picked up / opened" forward. The
alternatives were worse: fork the core (another owner's file), check per frame,
or poll. So this module walks the at-most-16 carried instances of each connected
human every 2 s — never per frame, never for a bot, never outside the window.
The arithmetic is exact between ticks:

* `presents` = highest instance id ever seen (the core keeps it per player per
  season, monotonic);
* `opens` = `(presents collected) − (presents carried)`, both read in the same
  tick, so a pickup and an open that happen together still cancel correctly;
* `legendary` = an instance of the top rarity that was in the bag at the previous
  look and is gone now (opening is the only way a present leaves the bag).

**Known and accepted limit:** a legendary present picked up and opened inside a
single 2 s window is counted by `opens` but not by the `legendary` counter, so
that one badge can miss it. The docs say so instead of pretending the tick is an
event. The fix is one forward in the core (`wf_on_open(id, instance, rarity)`),
which would delete the tick entirely; it is not this workstream's file.

**The core-readiness probe.** The core has no "is this player loaded yet" native.
A loaded player always has tree level ≥ 1 (`WfClearMem` sets 1 and nothing lowers
it) while a native call for an unloaded player returns 0, so `wf_tree_level() >= 1`
is the probe. It is the one core internal this module relies on, it is one line,
and it is here so it can be removed when the core grows a proper native.

---

## 8. Commands

Player-facing (registered only inside the window):

| command | what |
| --- | --- |
| `/christmasmissions`, `/xmasmissions` | the seasonal contracts, 7 per page, each row `label - period progress/target +snow`, plus a badges entry. Tapping a row prints one line saying what it pays. The page title carries `(d<n> w<n> s<n>)` per group. |
| `/christmasrank` | the season top 5 **among humans online right now**, by claimed contracts then presents, and one line pointing at the panel for the full board. No HTTP from a game thread: a synchronous request in a plugin is a lag spike for every player on the server, so the panel stays the only complete source. |

Menu chrome is `FN_MenuFinish` and the `\y/\w/\d` row language from
`freenova_ui` — the same look the rest of the Winterfest menus use.

Operator commands (console, `ADMIN_CFG`, same access as the core's `wf_*`):

| command | what |
| --- | --- |
| `wfprog_state <target\|all>` | window, vault and core state, then per player: `loaded/core_ready/badges`, the season counters, and one line per contract (`progress/target paid\|open`) |
| `wfprog_save` | flush every dirty record now |
| `wfprog_reload <target\|all>` | drop memory and re-read the vault (a reconnect, on demand) |
| `wfprog_login <target\|all> [force]` | run the daily-login check; `force` asks the core again even when the record already says today was paid, so the ledger answers |
| `wfprog_report <target\|all> <metric> <n>` | the console form of the report native |
| `wfprog_reset <target> <season\|badges\|all>` | wipe this module's records for a player (the core's claims stay spent, §5) |

---

## 9. What the harness proves

Two runs, both under `flock /tmp/cs16-harness.lock`, against the `freenova`
profile (the live stack, 78-80 plugins) with `--bots 1`. The scenarios live in
`tests/winterfest-progress/`; `README.md` there has the exact commands.

### Run A — closed season (the brief's "nothing loads, no hooks, no messages")

Shipped `progress.ini` (1–24 December) on a 22 November clock:

```
ok  expect: \[WF-PROG\] season 2026 window 20261201-00 .. 20261224-1439,
            now 20261122-.* -> CLOSED; dormant: content not read, no vault,
            no hooks, no commands, no messages
ok  expect: \[WF-PROG-TEST\] PASS library-loaded-dormant
ok  expect: \[WF-PROG-TEST\] PASS native-says-closed
ok  absent: \[WF-PROG\] ready:
ok  absent: \[WF-PROG\] missions\.ini:
ok  absent: \[WF-PROG\] achievements\.ini:
ok  absent: \[WF-PROG\] daily login
ok  absent: \[WF-PROG\] contract
ok  absent: \[WF-PROG\] achievement
ok  absent: \[WF-PROG\] id [0-9]+ opened a legendary present
ok  absent: \[WF-PROG\] season 2026 year          (wfprog_state printed nothing)
ok  absent: \[WF-PROG\] login check for           (wfprog_login printed nothing)
ok  absent: \[FreeNova winterfest_progress\] ready
RESULT ok slug=wfprog_closed
```

The same run also granted three presents to the bot and asked both player
commands to do work: **no line of ours appeared after the dormant one.**

### Run B — open season

`progress.ini` is replaced (in the harness tree only) with a window covering the
harness clock, the core's claim vault is wiped for a clean season, and a command
list drives the sequence (one line every 0.4 s; `status` lines are the clock):

```
ok  expect: \[WF-PROG\] ready: Winterfest 2026 season 2026, window open,
            14 contract(s), 12 achievement(s), core=yes
ok  expect: \[WF-PROG\] daily login paid for id N (25 gb, date 20261122)
ok  expect: \[WF-PROG\] daily login already claimed for id N (date 20261122) code=0
ok  expect: \[WF-PROG\] achievement ach_first_present (First Snow) unlocked
            -> paid (badge 'First Snow' gb=50 xp=40 codes=1/1)
ok  expect: \[WF-PROG\] contract d0 (daily_presents_3) id N -> paid
            (target=5 gb=120 xp=80 codes=1/1)
ok  expect: \[WF-PROG\] re-read ...: 1 contract(s) paid, 1 badge(s)
ok  expect: \[WF-PROG\] achievement ach_first_present ... -> already-claimed
            (badge 'First Snow' gb=50 xp=40 codes=0/0)
ok  expect: \[WF-PROG\] contract d0 ... -> already-claimed
            (target=5 gb=120 xp=80 codes=0/0)
ok  expect: \[WF-PROG\] id N opened a legendary present (instance M)
ok  expect: meta[giftseq=... carried=... opens=3 legendary=3 snowball=0]
ok  expect: \[WF-PROG\]   d1 d20261122 3/3 paid      (opens contract)
ok  expect: \[WF-PROG\]   s5 s2026 2/2 paid          (season legendary)
ok  expect: meta[... opens=3 legendary=3 snowball=1]  (the report native moved it)
ok  absent: \[WF-PROG\]   s6 s2026                    (the staged row never rolls)
RESULT ok slug=wfprog_open
```

What each of those proves:

1. **Persistence** — `wfprog_save` + `wfprog_reload` wipe the process memory and
   read the vault back; the re-read reports *1 contract paid, 1 badge*, i.e. the
   same record a reconnect would get.
2. **The claim key, not a local flag** — the run wipes this module's own record
   (`wfprog_reset <bot> all`) and earns the same contract and the same badge a
   second time in the same season. Both are attempted and both come back
   `codes=0/0` (`WF_GRANT_DUPLICATE`) → the log says `already-claimed` → nothing
   is paid. A second completion in the same second, a week later, after a
   reconnect or after a plugin restart all produce this same line, because the
   claim string is identical.
3. **The daily login** — paid once on the first connect, then refused by the
   core's ledger on a forced retry.
4. **Derived counters** — three opened presents move `opens` to 3 and the
   legendary counter to 3 (all the presents in that run are top-rarity), and the
   two contracts that count them pay.
5. **The cross-module channel** — `wfprog_report(…, "snowball_hs", 1)` moves the
   metric (`snowball=1`) while the staged contract for it still does not roll.

Run A's log line and run B's `codes=0/0` lines are the two things the brief asked
to be checked hardest; both are asserted by the expect files, not by prose.

---

## 10. What needs `winterfest_core`

`winterfest_core` is the only source of currency, pass XP and the tree/advent/
set counters, so:

| core present | core missing |
| --- | --- |
| contracts and badges pay through `wf_grant` | contracts and badges still **track and persist**, and pay nothing |
| the daily login pays the bundle | no bundle, no announcement |
| advent / sets / tree / pass tier progress | those metrics cannot move (they are the core's numbers) |
| `/christmasmissions` shows progress and claims | shows progress and says nothing is payable |

The plugin never fails to load without the core: it declares the `wf_*` natives
and uses `set_native_filter` (the `fn_servers.sma` pattern), so a missing core
resolves them to 0 instead of "bad load". The one thing it deliberately does
**not** do is pause itself: the brief for this workstream says progress must keep
being tracked without the core, and pausing would throw away a player's
December. The trade-off is that a server *without* the core still loads this
plugin — but only inside the season window, with no player-facing line unless a
player types one of the two commands.

### What workstream 7 needs to do (one line)

```pawn
	if (LibraryExists("winterfest_progress", LibType_Library))
		wfprog_report(id, "snowball_hs", 1)   // declare: native wfprog_report(id, const metric[], amount)
```

…then change `season_snowball_1`'s `weight` from `0` to `1` in `missions.ini`.

---

## 11. Deliberate limits

* `tree` / `pass_tier` contracts are **season-only** (a level does not reset, so
  a daily one would instantly pay every day). The loader refuses them in another
  period with a log line instead of silently misbehaving.
* The `legendary` counter can miss a present picked up and opened inside one 2 s
  observation window (§7). `opens` never misses.
* A badge's reward is once per season by design; the badge itself is permanent.
* `wfprog_reset` cannot re-open the core's claims (§5) — that is a feature.
* The module adds no `plugins.ini` line: the coordinator inserts it, after
  `winterfest_core`, `winterfest_gifts` and `winterfest_menu`.
