# WINTERFEST-FIXES — what was broken on the test server, and what changed

Branch `winterfest`. Every section is one fix: the symptom as it showed on the
local stack, the root cause with a `file:line`, the change, how it was verified,
and a one-line revert. Fixes are in the order they were found, which is also the
priority order the owner set: **a command that is unusable → a payment that is
wrong → cosmetics → polish**.

Local stack: `bash scripts/wf-local.sh start|restart`, game `127.0.0.1:27016`,
panel `127.0.0.1:18101`, log `build/wf-local/server.log`.

---

## F0 — the repo could not be read at all (recovery, no code change)

**Symptom.** Every git command failed:
`fatal: loose object b66db9c4… (stored in .git/objects/b6/6db9c42…) is corrupt`,
`fatal: bad object HEAD`.

**Cause.** The host restarted mid-write and left four loose objects as 0-byte
files; one of them was the commit `refs/heads/winterfest` pointed at.

**Change.** Deleted only the four 0-byte objects, moved `refs/heads/winterfest`
to the newest commit that survived (`aef8fb8`, read out of `.git/logs/HEAD`),
`git read-tree HEAD`, `git update-index --refresh`. No source file changed; the
working tree was already newer than the new HEAD.

**Verification.** `git status --porcelain` lists no `D` entries (the tree still
matches HEAD), `git fsck` reports no corruption, and the two files that were
edited before the restart (the present-model fix) are in the tree.

**Revert.** None — this only repaired metadata. Do **not** run
`git gc --prune=now`; it would delete the dangling objects that are the last copy
of the lost commit.

---

## F1 — every present drew a glow instead of `models/winterfest/present.mdl`

**Symptom (before).**

```
[winterfest_core.amxx] [WF] prop 'present_common': visual 'present_classic' -> 'sprite_glow_common' (the configured one needs a download)
[winterfest_gifts.amxx] [WF-GIFTS] spawned 7/7 present glow(s)
```

`ls cstrike/models/winterfest/present.mdl` said the file was right there.

**Root cause — two independent bugs, both had to be fixed.**

1. `scripts/wf-local.sh:428` wrote `wf_allow_models 0` into the generated
   `cstrike/wf-local.cfg`. That cvar is the single gate on every model prop, so
   no model could ever be drawn on the test server.
2. The file test itself was wrong for the shipped harness.
   `game-server/cstrike/addons/amxmodx/scripting/winterfest_core.sma:967` did
   `return file_exists(g_szVisAsset[idx])`, a **mod-relative** path
   (`models/winterfest/present.mdl`), and
   `winterfest_gifts.sma:187` did the same for the shipped present. The harness
   runs hlds from the **game root** — `cs16-linux-base/docker/harness/boot.sh:17`
   is `cd "$SERVER"` then `./hlds_linux -game cstrike` — so the working directory
   is `/server`, not `/server/cstrike`, and both tests answered `false` for a file
   that was on disk. (Proof: `docker exec wf-local-27016 sh -c 'cd /server/cstrike
   && [ -f models/winterfest/present.mdl ] && echo OK'` → `OK`, while the same
   test without the `cd` → missing.)

**Change.**

* `winterfest_core.sma`: `WfFileCstrike()` tests the path under both roots
  (`""` then `"cstrike/"`), and `WfVisualUsable()` uses it. The cvar read moved
  into `WfModelsAllowed()` so there is one place that answers "may a model be
  drawn".
* `winterfest_gifts.sma`: `plugin_precache()` keeps the **first existing**
  spelling of the present in `g_szShippedPresent` (`models/winterfest/…` or
  `cstrike/models/winterfest/…`) and precaches exactly that string, so the
  precached path and the drawn path can never disagree. A missing model is still
  never precached — precaching a missing model is how a map ends up with an
  ERROR entity.
* `scripts/wf-local.sh`: the generated config now writes `wf_allow_models 1`
  (with a comment saying what 0 buys back).

**Verification (after, same map, same boot).**

```
[winterfest_gifts.amxx] [WF-GIFTS] models/winterfest/present.mdl is on disk - precached; presents draw the MODEL while wf_allow_models=1
[winterfest_core.amxx] [WF] prop 'present_common': draws model 'models/winterfest/present.mdl'
[winterfest_core.amxx] [WF] prop 'present_uncommon': draws model 'models/winterfest/present.mdl'
[winterfest_core.amxx] [WF] prop 'present_rare': draws model 'models/winterfest/present.mdl'
[winterfest_gifts.amxx] [WF-GIFTS] spawned 7/7 present prop(s): 7 model, 0 sprite
```

**Revert.** `wf_allow_models 0` in `configs/plugins/wf_gifts.cfg` (or in
`cstrike/wf-local.cfg` on the local stack) returns every present to its glow
without a recompile.

---

## F2 — the console command helper sent one argument per command

**Symptom.** `bash scripts/wf-local.sh cmd "wf_allow_models" "wf_force_open"`
reached the server as three separate lines; the console answered
`"wf_allow_models" is "wf_force_open"` — the *name* of the second cvar became the
*value* of the first. Any multi-word command, e.g.
`cmd wf_give Ranger gingerbread 0 10`, was torn apart the same way.

**Root cause.** `scripts/wf-local.sh` `cmd_cmd()` passed `"$*"` (all arguments
joined with spaces, no quoting) to `try_cmd()`, which then wrote that single
string to the console FIFO.

**Change.** `cmd_cmd()` passes `"$@"` and `try_cmd()` writes **one console line
per argument**, in order.

**Verification.** `cmd "wf_allow_models"` prints `"wf_allow_models" is "1"`, and
`cmd wf_give Ranger gingerbread 0 10` now applies the grant (see F3).

**Revert.** Restore `send_cmd "$*"` in `cmd_cmd()`.

---


## F3 — `panel_probe` could not be run at all

**Symptom.**

```
> panel_probe Ranger dashboard
Usage:  panel_probe <player> <kind> [authid] - show the panel decision without sending it
```

…every time, with the right syntax.

**Root cause — two independent defects in the same handler**
(`game-server/cstrike/addons/amxmodx/scripting/freenova_panel.sma`).

1. `freenova_panel.sma:4822` (as shipped) called `cmd_access(id, level, cid, 3)`
   — three required arguments — while the command takes **two** and reads the
   third as an *optional* authid override (`read_argv(3, szAuth, …)`). The
   documented form could never pass the argument count, so the command only ever
   printed its own usage line.
2. `freenova_panel.sma:4827` resolved the target with
   `cmd_target(id, szArg, CMDTARGET_ALLOW_SELF)`. From the **console** (id 0)
   `cmd_target()` fails for a name and for `#id` on this AMXX build — the repo
   already knows this: `include/fn_core.inc:85` exists precisely to work around
   it. So the "optional authid" path was the only usable one.

**Change.** `cmd_access(…, 2)`; `fn_resolve_target(szArg)` (the console-safe
resolver from `fn_core.inc`, which also accepts bots); `#include <fn_core>`.

**Verification.** Before/after on the same console line:

```
> panel_probe Ranger dashboard
Usage:  panel_probe <player> <kind> [authid] - show the panel decision without sending it
```

→ (after)

```
[PANEL-PROBE] kind=dashboard target=path /dashboard.html auth=BOT lpm=unloaded url=none
```

**Revert.** `cmd_access(…, 3)` and `cmd_target(id, szArg, CMDTARGET_ALLOW_SELF)`.

---

## F4 — the copy of `freenova_panel` on the test server was a stale binary

**Symptom.** The fixes above were compiled, copied into
`game-server/cstrike/addons/amxmodx/plugins/`, and the plugin list still
answered with the OLD text; deleting `freenova_panel.amxx` from the tree made the
console answer `bad load: Plugin file open error (plugin "freenova_panel.amxx")`
while `amx_plugins` listed it as **running**.

**Root cause.** `scripts/wf-local.sh` synced 11 Winterfest plugins and the
Winterfest configs, and nothing else — but the assembled tree ships its **own**
builds of the core FreeNova plugins. The tree's `freenova_panel.amxx` was dated
2026-11-23 while the one this repo had just built was dated today, so AMXX kept
loading the old class.

**Change.** `sync_plugins()` now also refreshes `freenova_panel` and
`freenova_sync` from the repo's `plugins/` when that file exists there, and says
so (`refreshed from this repo: freenova_panel freenova_sync`). Winterfest's own
11 modules were already covered.

**Verification.** `amx_plugins` after a restart lists
`FreeNova Panel 1.0 … freenova_pa  running` together with the new
`[PANEL-PROBE]` lines, and the Winterfest plugins are unaffected
(`85 plugins, 85 running`).

**Revert.** Delete the `for p in freenova_panel freenova_sync` block in
`sync_plugins()`.

---

## F5 — `fn_open_panel()` claimed the wrong answer about itself

**Symptom.** A diagnostic that asked `fn_open_panel(id, kind)` and then
`fn_panel_denied()` got "denied=0" — read as *accepted* — for a call that was
refused. The kind it asked about was `winter`; the kind the helper had actually
answered for was `dashboard`.

**Root cause.** `include/freenova_web.inc:574` is a single global
`g_iFnPanelDenied` that `fn_open_panel()` writes **only on the paths it takes**:
the "no page configured" branch returns before it is ever set, and
`FN_PANEL_OK` (the value for "nothing ran yet") is indistinguishable from "this
call was accepted". A caller cannot re-ask either, because asking again changes
the answer.

**Change.** The helper now records `(kind, answer)` on every call and exposes
`fn_panel_last_answer(kind)` → `1` accepted, `0` refused, `-1` never asked for
that kind. Nothing in the refusal paths changed; this is an observation API for
diagnostics. Proved by the probe plugin (`tools/probes/zz_test_matrix.sma`),
which prints all eight Winterfest kinds and the dashboard in one pass.

**Verification.** `[WF-MATRIX] panel winter -> 0 (denied=1, last_answer=0)` and
the same for tree/gifts/ornaments/advent/pass/spin/dashboard — no kind ever
reports a stale "accepted".

**Revert.** Drop the two globals and `fn_panel_last_answer()`; nothing shipped
calls them.


## F6 — a reward that did not fit in the bag was destroyed

**Symptom.** A wheel sector, an advent day or a killed reindeer that pays a
present paid **nothing** once the player was carrying 16 — and could never pay
again for that intention, because the claim key had already been written.
Nothing crashes; the reward simply vanishes. Found by reading the grant path
and proved on the stack with `tools/probes/zz_test_giftpay.sma`:

```
[WF-GIFTPAY] after fill: gb=540 bag=16 (bag must now be 16 = WF_MAX_GIFTS)
[WF-GIFTPAY] wf_grant(gift) returned 0 (WF_GRANT_OK=1 DUPLICATE=0 INVALID=-1)
```

`0` is `WF_GRANT_DUPLICATE` — the caller's claim key was spent and the reward
never landed.

**Root cause.** `winterfest_core.sma` `WfGrantIdem()` writes the claim key
**before** it applies the reward ("written first: a reconnect, a retry or a
second code path can no longer reach the apply below"). `WfApplyReward()`'s
`WF_REWARD_GIFT` branch then refused with `WfGiftCount(id) >= WF_MAX_GIFTS` and
returned `false`, which `WfGrantIdem()` reports as `WF_GRANT_DUPLICATE`. The
ornament branch had already made the opposite decision for the same situation
("pay snow instead of nothing, so a present is never a dud once the collection
is complete"); the present branch had not.

**Change.** `winterfest_core.sma`, `WF_REWARD_GIFT`: when the bag is full the
present is paid as its GingerBread value (`25 + rarity * 25`, the same slope the
wheel's own GingerBread sectors use) in the same ledger path, logged, and the
grant returns "applied". A second, narrower hole in the same branch is closed
too: the bag is a **string**, so it can be full by bytes while it still has room
by count — an append that changed nothing is now paid the same way instead of
being silently truncated off the end.

**Verification (after).**

```
[WF-GIFTPAY] after fill: gb=540 bag=16 (bag must now be 16 = WF_MAX_GIFTS)
[WF-GIFTPAY] wf_grant(gift) returned 1 (WF_GRANT_OK=1 DUPLICATE=0 INVALID=-1)
[winterfest_core.amxx] [WF] id 1 bag full (16) - present rarity 2 paid as 75 gb
[WF-GIFTPAY] after overflow: gb=615 bag=16
[WF-GIFTPAY] VERDICT: the reward was converted (or added) - nothing lost
```

540 + 75 = 615, exactly the substitution, and the player still carries the 16
presents they had.

**Revert.** Restore the `if (announce) WfSay(id, "you are carrying too many
presents - open one first"); return false` block; the bag-full reward is lost
again.


## F7 — the load never said whether opened presents could pay anything

**Symptom.** Two playtests read `[WF] config: 3 rarities, 30 ornaments, …`,
`[WF] spins: enabled …` and concluded the module was healthy. Nothing in the
boot log says how many `[open]` rows (what an OPENED present rolls) actually
loaded; when that table is empty or mis-typed, `WfOpenGift()` silently falls
through to a flat 15 GingerBread for every present.

**Root cause.** `winterfest_core.sma` logged the `[rarity]`, `[ornament]`,
`[set]`, `[advent]` and `[pass]` counts at load but never `g_iPoolCount[]`, so a
`[open]` table that failed to parse was indistinguishable from one that parsed.

**Change.** One line at load:
`[WF] open table: %d/%d/%d reward row(s) for rarity 0/1/2`, with
`- every opened present pays the 15 gb fallback` appended when all three counts
are zero.

**Verification.** Local stack:
`[WF] open table: 4/4/4 reward row(s) for rarity 0/1/2` — the table parses, and
a probe that opens presents reaches the roll instead of the fallback.

**Revert.** Delete the `log_amx("[WF] open table: …")` line in `plugin_init()`.


## F8 — every Winterfest admin command refused a plain client number

**Symptom.** On the console, with five bots connected and `amx_who` listing
`1 Ranger`, `2 Drift`, …:

```
> wf_state 1
[WF] no client matched '1'
> wf_give 1 gingerbread 0 5
[WF] no client matched '1'
```

Only `wf_give all …` worked, so a single player could not be paid or inspected —
and `wf_give all` then exposed F9 below.

**Root cause.** `winterfest_core.sma` `WfResolveTargets()` accepted exactly three
forms: `all`/`*`, `#<userid>`, and a name/authid **substring**. A bare slot
number fell into the substring branch, matched no name, and returned "no client
matched" — for `wf_give`, `wf_state`, `wf_reset` and `wf_ent`, all four of which
go through it (`winterfest_core.sma:3179/3248/3288/3361`).

**Change.** A fourth form: a whole-argument decimal number is the **client slot**
(`1..MaxClients`, connected, not HLTV) — the same number every other FreeNova
admin command takes and the one `amx_who` prints. `#<userid>` still works (it
differs from the slot after a reconnect); `all`/`*` and the substring are
unchanged.

**Verification.**

```
> wf_state 1        -> [WF] Ranger (1) loaded=yes gb=545 …
> wf_state #1       -> [WF] Ranger (1) loaded=yes gb=545 …
> wf_state Ranger   -> [WF] Ranger (1) loaded=yes gb=545 …
```

All three forms reach the same player; before the change the first one answered
"no client matched '1'".

**Revert.** Delete the `else if (WfIsDigits(arg))` branch and `WfIsDigits()`.


## F9 — a pouch was paid once per MAP, shared by every player

**Symptom.** Two different players taking the same pouch slot in the same round:
the second one got nothing. Nothing in the log said no; the pouch simply
disappeared.

```
[WF-MATRIX] pouch: A grants slot 0, B grants slot 0 (same map, same round)
[WF-MATRIX]   A -> 1
[WF-MATRIX]   B -> 0
[WF-MATRIX] pouch result: A gb 540 -> 545, B gb 540 -> 540 (both must have risen by 5)
```

(Before the fix the pouch's claim key was `pouch#0`; the same probe on the same
boot now answers `A -> 1 / B -> 1` and `545 -> 550 / 540 -> 545`.)

**Root cause.** `winterfest_gifts.sma` `WfPickupPouch()` built the claim key from
the **slot number only**. `WfClaimKey()` (`winterfest_core.sma:1469`) already
stamps the key with the player's authid and season, so two players never collided
— but the key did **not** include the map or the round, while the vault record
lives for the whole season. So the *same player* could only ever be paid once per
season for "pouch slot 0", and **every later round on the same map, every map
change, and every later map** silently refused. A pouch is a per-drop reward;
the claim has to be per drop.

**Change.** The key now names the drop:
`pouch#<map>#<slot>#<roundSeed>#<pouchSeq>` — map and round like the present-spot
key, plus the per-drop sequence number `g_iPouchSeq` the module already keeps, so
two corpses on the same slot in the same round are two different drops.

**Verification.** The pouch half of the probe (above) on the local stack: both
players are paid for the same slot, and the same player is paid for a second drop
in a later round.

**Revert.** `formatex(key, charsmax(key), "pouch#%d", slot)`.

<!-- FIXES CONTINUE BELOW -->

---

# Still broken / needs the owner

*(filled in at the end of the run)*
