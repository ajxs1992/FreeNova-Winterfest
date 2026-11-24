# Winterfest Spin Wheel — `/spin`, `spin.ini`, `/winter/spin`

Workstream 13 of `docs/WINTERFEST-WORKSTREAMS.md`. Product contract:
`docs/WINTERFEST.md` §4 and the owner decision of 2026-11-22 ("spin wheel
ships", `docs/design/WINTERFEST-DASHBOARD.md` — *Spins 0* in the top bar next to
Coins and GingerBread).

| file | what it is |
| --- | --- |
| `game-server/…/scripting/winterfest_spin.sma` | the wheel: `/spin`, the roll, the reveal, the prize payment, the operator and test commands |
| `game-server/…/configs/freenova/winterfest/spin.ini` | the sectors, the odds, the caps, the reveal timing |
| `web-panel/src/winter/spin.js` | `/winter/spin` — the page (read-only viewer) |
| `web-panel/src/winter/spin_data.js` | the same wheel as data, the odds arithmetic, the mirror read |
| `web-panel/src/index.js` | **one** import + **one** route line (see §6.1) |
| `tests/winterfest-spin/wfspin_scenario.*` | the scripted server scenario (commands + expect) |
| `tests/winterfest-spin/test_odds.py` | the offline odds + reset-clock harness (15 tests) |
| `web-panel/test_harness.mjs` | 35 checks appended as section "10. the Spin Wheel" |

**The one sentence:** a spin consumes one token and pays one prize from a
weighted table; the token is taken before the prize is paid and the claim key is
written before the announcement, so no reconnect and no double `/spin` can ever
pay twice.

---

## 1. Who owns what (the split with the core)

`winterfest_core.amxx` owns the **counter**: a per-player balance, one idempotent
free spin per player per calendar day (claim key `spin#<YYYYMMDD>`, granted at
connect, `[spins]` in `winterfest.ini`), and a consume that refuses at zero. It
exposes `wf_get_spins`, `wf_add_spins`, `wf_consume_spin`.

This module owns the **wheel**: the sectors, the odds, the reveal, the prize
payment and the anti-dupe discipline around them. It keeps **no second counter**
— two counters is two bugs — and it never grants the daily itself.

| native | used for | when it is missing |
| --- | --- | --- |
| `wf_consume_spin(id)` | taking the token, first, before anything else | no token is taken, no wheel |
| `wf_get_spins(id)` | the balance line, the eligibility of a "spin back" prize | the wheel is unavailable |
| `wf_add_spins(id, n)` | the "1 Extra Spin" sector, an admin grant, a refund | no spin prize, no grant |
| `wf_grant(id, kind, id, key)` | GingerBread, ornaments, titles, presents | nothing is paid; the log says which prize failed |
| `wf_tree_level(id)` | "is this player's record loaded yet" (the probe the other modules use) | treated as not loaded |
| `menabp_is_ready` / `menabp_add_coins_once` | coin prizes (the core has no coin reward type) | coin sectors are **excluded** from the roll |

Missing providers are declared with the `set_native_filter` pattern from
`fn_servers.sma`, so a server without `winterfest_core` or `battlepass_core`
loads this plugin and `/spin` answers "unavailable" — **no token is spent and no
prize is paid** (fail closed, one log line per map).

## 2. The daily reset clock

`spin.ini` carries `reset_hour` (0..23) and `timezone = Europe/Paris`.

`reset_hour = 0` is the value the implementation actually honours, because the
core's daily claim key is `spin#<get_time("%Y%m%d")>` — its **server-local
calendar day**. So the boundary is midnight, and Europe/Paris is only true if the
game server runs on Paris time (it does in production; the panel's whole period
model assumes it — `web-panel/src/periods.js`).

What this module does with the setting, honestly:

* it prints the countdown a player sees (`Reset 00:00 Europe/Paris (in 4h 12m)`);
* `wfspin_day [unixtime]` prints, for any timestamp: the UTC stamp, the **Paris**
  stamp, the Paris offset in seconds, the reset-hour spin-day index and the
  core's claim day. That is the diagnostic that proves the arithmetic;
* the panel prints the next reset as a `<time>` element, so a browser renders it
  in the reader's own locale while the server-rendered text stays Paris.

The Paris offset is computed from the EU rule by hand (no tz database in AMXX):
+2 h from 01:00 UTC on the last Sunday of March to 01:00 UTC on the last Sunday
of October, +1 h otherwise. It is checked against Python's `zoneinfo` for every
6 hours of a year in `tests/winterfest-spin/test_odds.py`, and four fixed
instants are pinned in `wfspin_scenario.expect`:

| unixtime | UTC | Paris | offset | spin-day |
| --- | --- | --- | --- | --- |
| 1796081400 | 2026-11-30 23:30 | 2026-12-01 00:30 | 3600 | 20788 |
| 1784116800 | 2026-07-15 12:00 | 2026-07-15 14:00 | 7200 | 20649 |
| 1774744200 | 2026-03-29 00:30 | 2026-03-29 01:30 | 3600 | 20541 |
| 1774747800 | 2026-03-29 01:30 | 2026-03-29 03:30 | 7200 | 20541 |

**Limitation, stated:** if the box runs UTC while `timezone = Europe/Paris`, the
core's free spin arrives at 01:00 Paris, not midnight, and this module cannot
change that (the core's clock is the core's). `wfspin_day` is how you notice.

## 3. `spin.ini` — the shape

```
[wheel]
free_per_day = 1      ; display only - the core's [spins] grants the daily
reset_hour   = 0      ; 0..23, the boundary the countdown is computed from
timezone     = Europe/Paris
max          = 10     ; the product cap on a balance (wfspin_grant clamps to it)
fade_rarity  = rare   ; the wheel rarity that also fades the screen
step         = 0.65   ; seconds between reveal steps (4 steps = 2.6 s)
enabled      = 1      ; 0 stops /spin without touching a balance

[sector]
label | kind | amount | weight | rarity
```

| field | meaning |
| --- | --- |
| `label` | what the player sees on the wheel and in the table (≤ 18 chars, no `%`) |
| `kind` | `gingerbread`, `coins`, `ornament`, `title`, `spin`, `gift`, `nothing` |
| `amount` | magnitude for gingerbread/coins/spin · rarity 0/1/2 for gift · `[set]` id for title · ornament id (`0` = a random one you do not own) for ornament |
| `weight` | integer **≥ 2**; chance = weight / Σweight. A 1/100 sector sits inside the noise of the 1000-roll check, so it is refused |
| `rarity` | `common`, `uncommon`, `rare`, `legendary` — **cosmetic only** (reveal colour, fade threshold) |

8..12 sectors are enforced (fewer is refused with a log line and the wheel stays
shut); more than 12 is truncated with a log line per extra row. A bad row is
skipped **with its line number**; a missing file leaves the plugin loaded and the
wheel unavailable.

Shipped table (weights sum to 100):

| # | label | kind | amount | weight | chance | rarity |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | Nothing | nothing | — | 12 | 12.0 % | common |
| 2 | 5 GingerBread | gingerbread | 5 | 20 | 20.0 % | common |
| 3 | 15 GingerBread | gingerbread | 15 | 18 | 18.0 % | common |
| 4 | 25 Coins | coins | 25 | 12 | 12.0 % | common |
| 5 | 75 Coins | coins | 75 | 10 | 10.0 % | uncommon |
| 6 | 1 Extra Spin | spin | 1 | 8 | 8.0 % | uncommon |
| 7 | Common Present | gift | 0 | 9 | 9.0 % | common |
| 8 | Mystery Ornament | ornament | 0 | 6 | 6.0 % | uncommon |
| 9 | Collector Title | title | 6 | 3 | 3.0 % | rare |
| 10 | Rare Present | gift | 2 | 2 | 2.0 % | rare |

71 % common · 24 % uncommon · **5 % rare-or-better** (the fade threshold).
Expected GingerBread per spin: `0.20·5 + 0.18·15 = 3.7`, plus a 11 % chance of a
present and a 6 % chance of the ornament you are missing.

## 4. The roll, and why a complaint can be audited

```
total = Σ weight                       // integer
r     = random_num(1, total)
acc   = 0
for each sector in FILE ORDER:
    acc += weight
    if r <= acc: that sector wins
```

Integer arithmetic only (no float drift), every sector with weight ≥ 1 is
reachable, and **reordering the rows changes no odd** — a sector's interval width
is its weight (`test_odds.py` asserts exactly that).

Every spin logs one line with the numbers:

```
[WF-SPIN] roll id 2: r=37/100 -> sector #3 '15 GingerBread' (gingerbread 15,
          weight 18, rarity common) serial 7; balance now 2
[WF-SPIN] spin result id 2: sector #3 '15 GingerBread' -> paid (gingerbread 15)
```

### Eligibility: a token always buys a real prize

A sector whose prize the player **cannot receive right now** is excluded before
the roll, and its weight is spread over the rest (the wheel still pays 100 % of
the time, and the chance of everything else rises slightly):

| kind | excluded when |
| --- | --- |
| `coins` | the coin wallet is not loaded for this player (`menabp_is_ready` = 0) |
| `ornament` | the named ornament (or every ornament, for amount 0) is already owned |
| `title` | the set has no title configured, or the title is already owned |
| `spin` | the balance is already at `max` |
| `gift` | the player carries `WF_MAX_GIFTS` presents |

If **nothing** is payable, the token is refunded and the player is told — the one
outcome this module refuses to ship is a spent token that buys nothing. The
in-game prize table says how many sectors are being skipped for that player.

## 5. Anti-dupe: the five rules and the proof

1. **One spin in flight per player.** `g_bSpinning` is set when the token is
   taken and cleared when the last reveal step has paid. A second `/spin` in that
   window is refused with one line and spends nothing.
2. **The token is consumed first**, and only if `wf_consume_spin` returns 1. No
   token, no wheel.
3. **The intent is written to the vault before the reveal and the claim key
   before the announcement.** The key is `wfspin#<serial>`; `<serial>` is a
   monotonic per-player counter in this module's vault, and `serial:sector` is
   written at the moment the token is taken.
4. **Every prize API is idempotent by key**: core grants take the claim key,
   coins use `menabp_add_coins_once`'s award ledger, and the one prize with no
   ledger in the core (a spin back) writes a per-serial marker **before** the add.
   A crash between "key written" and "prize applied" loses one prize; it can
   never pay two.
5. **Bots are excluded** (except through the harness seam `wfspin_test_bots`).

Vault `freenova_wfspin`, keys (refused, never truncated, at 64 chars):

| key | value | purpose |
| --- | --- | --- |
| `wfspin_meta#<auth>` | `serial\|pending` | the claim serial + the in-flight intent (`serial:sector`, empty when clean) |
| `wfspin_pd#<auth>#<serial>` | `1` | "this spin already paid a spin-back prize" |

`<auth>` is the authid with `:` replaced by `_`, the same shape the core uses.

**The invariant that cost a debugging round, written down so it is never broken
again:** the serial must never restart at 0 for a session that can spin. It is
read from the vault at `client_putinserver` (**unconditionally** — an out-of-season
connect still loads it) and re-read through `WfSpinEnsure()` on every path that
can spin. Before that fix, a session that connected in November and had the
season forced open later reused serials from a previous run and the core's claim
ledger answered `already-paid` for a fresh spin. Two consecutive harness runs now
prove the counter keeps climbing (serials 36 → 54 in the two runs recorded below).

### The proof, in the harness

```
[WF-SPIN-TEST] PASS drive-conserved id=2 start=3 paid=3 won=0 refused=1 end=0
[WF-SPIN] drive id 2 #4 refused: no spins left (balance 0)
[WF-SPIN-TEST] PASS dupe-one-token id=2 spent=1        <- two /spin, one token
[WF-SPIN] id 2 refused: a spin is already in flight
[WF-SPIN] resume id 2: serial 54 sector #2 '5 GingerBread' -> paid
[WF-SPIN] resume id 2: serial 54 sector #2 '5 GingerBread' -> already-paid
[WF-SPIN] resume id 2: sector #2 '5 GingerBread' gb 520 -> 525 -> 525 -> 525
[WF-SPIN-TEST] PASS resume-paid-once id=2 gb0=520 gb1=525 gb2=525 gb3=525
```

`wfspin_resume` is the whole story in one command: take a token, record the
intent, drop the module's memory ("the client vanished"), re-read the vault, pay
→ **+5 once**; then restore the intent as if the "pending cleared" write had been
lost in the same crash → the core's claim ledger answers `already-paid` and pays
nothing; then a clean reconnect → nothing. Token conservation is asserted on
every drive (`start - spent + won == end`).

## 6. The panel page `/winter/spin`

### 6.1 The route

`web-panel/src/index.js` gets exactly two lines (nothing else in that file
changes): the import and

```js
if (path === "/winter/spin")
  return await pageWinterSpin(request, env, url)
```

placed **before** the `/winter/*` catch-all, because `src/winter/index.js` (the
/winter route table) is not this workstream's file. `pageWinterSpin(request, env,
url)` builds its own context from `season.js` / `store.js` / `catalog.js`.

### 6.2 What it shows, and what it refuses to show

* the wheel as **inline SVG** — a slice's angle *is* its chance, its colour is its
  rarity, the labels are the sector labels around the ring;
* your spins (and the cap), the daily free spin and the **next reset** as a
  `<time>` element the browser renders in the reader's locale;
* the full prize table with the chance as a percentage and a weight bar;
* your last 10 results;
* a "how a spin works" card that states the anti-dupe rules in player words.

The page is **read-only by design**, and says so on the page:

> The panel cannot take a token: only the game can spend one atomically, and this
> deployment has no authenticated panel→game write path for spins. A button that
> queued an action nothing consumes would be a lie, so there is none.

That is the honest version of the brief's "if the panel has no write path, render
it read-only". The queue exists (`actions`), but nothing in the game server reads
`wf_*` actions today — `wf_tree_move` has the same gap — so a spin button would
silently do nothing while looking like it worked.

**What the game has not pushed yet, and the exact DDL that would fix it.** There
is no spin column and no spin log in `schema.sql`, and nothing writes them. The
page therefore reads them defensively and prints `not mirrored` today; the moment
workstream 5 (schema.sql) and workstream 1 (sync payload) add these, the page
lights up with **no change on this side** (the harness creates them and asserts
it):

```sql
ALTER TABLE winter_players ADD COLUMN spins INTEGER NOT NULL DEFAULT 0;
ALTER TABLE winter_players ADD COLUMN spin_serial INTEGER NOT NULL DEFAULT 0;

CREATE TABLE IF NOT EXISTS winter_spin_log (
    steamid   TEXT    NOT NULL,
    season    TEXT    NOT NULL DEFAULT '',
    serial    INTEGER NOT NULL,          -- wfspin#<serial>
    sector    INTEGER NOT NULL,          -- 1..N, the wheel index
    label     TEXT    NOT NULL DEFAULT '',
    kind      TEXT    NOT NULL DEFAULT '',
    amount    INTEGER NOT NULL DEFAULT 0,
    rarity    TEXT    NOT NULL DEFAULT '',
    claim_key TEXT    NOT NULL DEFAULT '',
    at        INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (steamid, serial)
);
```

The claim key is stored but never rendered (it is the game's ledger record).

### 6.3 Palette

The page uses the **dashboard reference** colours for its own surfaces — page
`#0b1030`, card `#0d1430`, border `#2a3d6e`, gold `#f5c451`, green `#3fbf6f`,
muted `#9fb0d0`, ice `#4070c0` — as the mission asks. The shared shell
(`src/winter/render.js`, owner: workstream 5) is currently on the pine-green
seasonal palette; the page paints its own background so it reads as one
document, and needs no change when the shell moves to the reference palette. The
Christmas skin (`skin.js`) is beaten on that one property by document order; its
`!important` rules for the shell's classes (`.card`, `.wf-row`) do not touch this
page because it uses its own `wfs-*` class family.

### 6.4 The compact (GoldSrc MOTD) skin

MSIE cannot render SVG and must not run a script: with `?compact=1` (or an MSIE
user agent) the page renders the same sectors, chances and notes as tables, says
"the wheel itself is drawn in a browser", and ships **no `<script>` at all**.

## 7. Tests

### 7.1 The scripted server scenario

```bash
cd /home/ajxs/Desktop/Projects/cs16/cs16-linux-base
./scripts/assemble.sh --profile freenova
# the plugin lines the coordinator will add to the repo's plugins.ini; for a
# harness run, append them to the generated build tree instead:
printf 'winterfest_core.amxx\nwinterfest_spin.amxx\n' \
  >> build/server-freenova/cstrike/addons/amxmodx/configs/plugins.ini

flock -w 300 /tmp/cs16-harness.lock ./scripts/test-plugin.sh \
  /home/ajxs/projects/FreeNova-Classic-Server/tests/winterfest-spin/wfspin_scenario.sma \
  --profile freenova --bots 1
```

It must print `RESULT ok`. It is safe to run twice (the vault and the core's
ledger survive; that is the point — see §5).

What the scenario asserts, in order:

| step | assertion |
| --- | --- |
| boot | `[WF-SPIN] ready: 10 sector(s), total weight 100, … cap 10, step=650ms, fade rare+` |
| `wfspin_state` | the config, the dependencies, the Paris clock and the per-player counter |
| `wfspin_roll 1000` | the real roll, printed against the configured weights, inside 5 σ per sector |
| `wfspin_day` ×4 | the Paris DST rule and the spin-day index (the table in §2) |
| `wfspin_drive 20 plain` | drain: exactly one refusal, the balance ends at 0, tokens conserved |
| `wfspin_grant 3` + `wfspin_drive 4 plain` | **the brief's case**: 3 paid, 3 spent, **the 4th refused**, `start=3 paid=3 end=0` |
| `wfspin_grant 100` | the cap: `+10 -> 10 (clamped by the cap)` |
| `wfspin_drive 11 plain` | 10 paid, the 11th refused |
| `wfspin_drive 3` (full wheel) | the spin-back sector is eligible; conservation still holds |
| `wfspin_dupe` | two `/spin` in one tick spend **one** token |
| `wfspin_resume` | an interrupted spin pays once, a replayed intent is refused, a clean reconnect pays nothing |
| `wfspin_reload` | a config reload is safe and re-reads the same wheel |
| negatives | no `FAIL`, no `OUT-OF-TOLERANCE`, no `TOKEN-MISMATCH`, no run-time error |

### 7.2 Observed vs configured odds

In game (`wfspin_roll 1000`, one sample from the harness console log):

| # | sector | weight | expected | observed | delta |
| --- | --- | --- | --- | --- | --- |
| 1 | Nothing | 12 | 120.0 | 121 | +1.0 |
| 2 | 5 GingerBread | 20 | 200.0 | 211 | +11.0 |
| 3 | 15 GingerBread | 18 | 180.0 | 182 | +2.0 |
| 4 | 25 Coins | 12 | 120.0 | 111 | −9.0 |
| 5 | 75 Coins | 10 | 100.0 | 99 | −1.0 |
| 6 | 1 Extra Spin | 8 | 80.0 | 76 | −4.0 |
| 7 | Common Present | 9 | 90.0 | 82 | −8.0 |
| 8 | Mystery Ornament | 6 | 60.0 | 54 | −6.0 |
| 9 | Collector Title | 3 | 30.0 | 35 | +5.0 |
| 10 | Rare Present | 2 | 20.0 | 29 | +9.0 |

`PASS odds-1000` (the 5 σ bound: for weight 2 that is ±22, for weight 20 ±63).

Offline (`python3 tests/winterfest-spin/test_odds.py`, 200 000 rolls, the same
algorithm in Python):

```
 #  sector               kind         amount weight expected % observed %    delta rarity     verdict
 1  Nothing              nothing           -     12       12.0       12.0    -0.04 common     ok
 2  5 GingerBread        gingerbread       5     20       20.0       19.9    -0.09 common     ok
 3  15 GingerBread       gingerbread      15     18       18.0       18.1    +0.07 common     ok
 4  25 Coins             coins            25     12       12.0       12.0    +0.03 common     ok
 5  75 Coins             coins            75     10       10.0       10.0    +0.05 uncommon   ok
 6  1 Extra Spin         spin              1      8        8.0        8.0    +0.01 uncommon   ok
 7  Common Present       gift              0      9        9.0        9.0    -0.05 common     ok
 8  Mystery Ornament     ornament        any      6        6.0        6.0    +0.00 uncommon   ok
 9  Collector Title      title             6      3        3.0        3.0    +0.02 rare       ok
10  Rare Present         gift              2      2        2.0        2.0    -0.00 rare       ok

chi-square 3.17 on df=9, critical 27.877 at p=0.001 -> fits
rare-or-better: observed 5.02 % vs configured 5.00 %
```

### 7.3 The panel checks (35)

`cd web-panel && node test_harness.mjs` — section "10. the Spin Wheel" (appended
at the end of the file; nothing else in it changed). The important ones:

* **`spin.ini` is parsed from disk and compared row for row with
  `spin_data.js`** — labels, kinds, amounts, weights, rarities and the whole
  `[wheel]` block. The page can never advertise odds the game does not roll.
* the wheel is inline SVG with one slice per sector, all labels present, the odds
  printed as the same percentages, the weights summing to 100;
* the reference palette is present; the rare+ chip equals the configured 5.0 %;
* **read-only**: no `<form>`, no `<button>`, no `method=post`, and the page says
  where a spin happens (`<code>/spin</code>`);
* the zero state says `not mirrored` (and names `winter_players.spins`) instead
  of printing a comfortable 0;
* the compact skin drops the SVG, keeps every sector and ships no script;
* after the DDL above is created in the test database: the counter shows `3 / 10`,
  both results are listed **newest first**, the claim key is never rendered, and a
  garbage row (`kind='weird'`, `rarity='mythic'`) or a `<script>` label cannot
  break or inject into the page.

## 8. Operations

| command | access | what it does |
| --- | --- | --- |
| `/spin`, `say_team /spin`, console `wf_spin` | players | balance line + the wheel menu (`Spin the wheel` / `Prize table`) |
| `wfspin_grant <n> <target\|all>` | ADMIN_CFG | add spins, clamped by `max`, one console + one log line per player |
| `wfspin_state <target\|all>` | ADMIN_CFG | the config, the dependencies, the Paris clock, and per player: ready · spins/cap · serial · pending · spinning · excluded sectors |
| `wfspin_reload` | ADMIN_CFG | re-read `spin.ini` (refused while a wheel is turning) |
| `wfspin_roll <n>` | ADMIN_CFG | replay the roll n times (100..200000), observed vs configured, `PASS`/`FAIL odds-n` |
| `wfspin_day [unixtime]` | ADMIN_CFG | UTC + Paris stamps, offset, spin-day, next reset, the core's claim day |

Cvars: `wfspin_test_bots` (default `0`) — the harness seam that lets a bot be the
subject; production keeps it at 0.

Log lines to know: `[WF-SPIN] ready: …` (boot, one line), `roll id N: …` (one per
spin, with the audit numbers), `spin result id N: … paid|already-paid|FAILED`,
`resume id N: …`, and the failure lines `no eligible sector, token refunded`,
`could not record this spin` (vault write failure → token refunded).

Failure modes, all fail-closed: no `spin.ini` → the wheel is unavailable and one
log line says so; no `winterfest_core` → `/spin` answers "unavailable", nothing is
spent; no `battlepass_core` → coin sectors are excluded (and logged as skipped);
no vault (`freenova_wfspin` unopenable) → the token is refunded and the spin is
refused, because a spin that cannot be made crash-safe must not be taken.

## 9. What needs a human

The harness has no human client, so these are unproven by machine:

* how the menu reads on a real client, and the reveal's *feel* (4 steps × 0.65 s,
  the HUD on channel 3, the ScreenFade on rare+);
* that the fade is not annoying in a firefight (it is 90 alpha, deliberately not
  near-white — `freenova_flash` owns the white flash);
* the panel page next to the owner's reference at 1672×941 and 1280×800 (the
  layout is tables and one SVG; a screenshot check is in §6.3's spirit but was
  only eyeballed here with a headless Firefox render).

## 10. Deliberately left out

* **No panel spin button** (§6.2) — no game-side consumer for a queued action, so
  a button would be theatre.
* **No spin column/table invented** — `schema.sql` belongs to workstream 5; the
  DDL above is the request, and the page lights up on its own when it lands.
* **No in-game history list** — the panel owns "your last N"; the game log is the
  audit trail. Adding a second history would be a third place to keep in sync.
* **No precache at all** (0 sprites, 0 models, 0 sounds): the reveal is HUD text,
  chat text and one engine ScreenFade.
* **No "buy a spin" path**: the brief says earned or granted, not purchasable.
  `wfspin_grant` is the admin door; Advent/pass/presents call `wf_add_spins`
  themselves.
