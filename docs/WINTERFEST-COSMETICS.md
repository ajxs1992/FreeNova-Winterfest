# Winterfest cosmetics — the registry, the weight policy, and what works today

Workstream 8. Owner of `winterfest_cosmetics.amxx`,
`configs/freenova/winterfest/cosmetics.ini` and this file. Contract:
`docs/WINTERFEST.md` §1.1 (client content and what it costs a player) and §4
Phase 3. Boundaries: `docs/WINTERFEST-WORKSTREAMS.md` row 8.

**Status, read this first.** It compiles (63 124 bytes of code, 0 warnings) and
it runs: the local stack (`build/wf-local`, `de_dust2`, 5 bots) loads
`39 cosmetic(s), 8 precached` and the eight effects in §10 fire, cap and reap
with the numbers in §10.4. Getting there needed two fixes in this file and two
more that only a running server could show; §9 is the account, including why the
`std::bad_alloc` was never a memory problem and how to bisect it in 15 runs.
The one thing still outside this workstream: `wf_cosmetics` has never been
exercised with a **real client** wearing an effect (the local stack is bots only,
and bots are skipped by entitlement), so §10.8 lists what that leaves unproven.

---

## 1. What a cosmetic is

A cosmetic is an **id** in `cosmetics.ini`. Nothing else in the module names a
model, a sprite or a title string, so the day the download path changes is a
config edit — that is the whole point of the registry (§4 of `WINTERFEST.md`,
Phase 3).

```
id | name | kind | weight | bytes | rarity | source | dl | asset | text
```

| field | meaning |
| --- | --- |
| `id` | stable, free-form, what every other module refers to (`hat_xmas_red`) |
| `name` | what a player sees |
| `kind` | `hat` \| `skin` \| `model` \| `title` \| `badge` \| `effect` \| `kill` \| `death` \| `spawn` |
| `weight` | `small` (< 150 KB) \| `medium` (< 1 MB) \| `heavy` (≥ 1 MB) — what a **client** must download |
| `bytes` | the size the operator expects (sum over the asset column); the preflight prints it beside the real size and logs a mismatch |
| `rarity` | 0..2, the same scale as `winterfest.ini [rarity]` |
| `source` | how it is earned: `gift`, `advent:N`, `pass:N`, `tree:N`, `secret:N`, `none` |
| `dl` | `1` = the client downloads a file, `0` = pure text |
| `asset` | client file(s) relative to `cstrike/`, comma-separated, max 8 |
| `text` | the title/badge string as shown, brackets included; on a `kill` row it is the kill word (§10.6) |

`kill`, `death` and `spawn` are the three **effect** kinds (§10). They are worn
like a hat is — one per slot — and they are played by this plugin at the moment
they name, so the registry stays the one place a cosmetic is described.

Current registry: **39 rows** — 8 small props, 6 medium props/hats, 6 hats, 3
heavy rows (hat pack, two sound packs), 5 titles, 3 badges, and 8 effects
(4 kill, 2 death, 2 spawn). 31 of them name a client file; the 8 text rows need
no download at all.

Two things about this file learned the hard way:

* **Rows must sit under `[cosmetic]`.** The parser only takes rows under that
  header (a row pasted above it was ignored, and the registry loaded **zero**
  cosmetics without a word in the log). The header is in the file now, and the
  parser defaults to `cosmetic` so a missing header cannot silently empty the
  registry again.
* **A section name is not case-sensitive but is matched exactly otherwise**
  (`[cosmetic]`, not `[cosmetics]`).

### Adding a hat is one line

```ini
hat_snow_owl | Snow Owl Hat | hat | medium | 480000 | 1 | gift | 1 | models/sp_hats/snow_owl.mdl |
```

then

```
wf_cosmetics_check      # proves the file is on this host, prints its real size
wf_cosmetics_reload     # re-reads the ini
changelevel             # models are precached in plugin_precache
```

Nothing is precached unless a row asks for it **and** the file exists on this
server (`file_exists()` before every `precache_model()`), so a half-uploaded asset
can never become a missing-model error or a broken player.

---

## 2. The weight policy (the decision this module had to make)

`sv_allowdownload 1` makes GoldSrc serve a precached file **from the game port**
when the fastdl mirror 404s. The owner proved it in game on 2026-11-22 (VIP models
downloaded live). It is throttled — minutes for multiple MB — and **every client
pays it on connect**, because a precached resource is pushed to whoever joins.

So the precache list is a budget, not a switch:

| switch | default | effect |
| --- | --- | --- |
| `wf_cosmetics` | **1** | master. `0` = nothing at all: no registry read, no precache, no entity, no message |
| `wf_cosmetics_heavy` | **0** | `1` lets medium and heavy rows into the precache table. That is the operator accepting that every client fetches them on connect |
| `wf_cosmetics_name` | 1 | a worn title also prefixes the scoreboard name |
| `wf_cosmetics_chat` | 1 | borrow `freenova_cosmetics`' chat-tag slot when the player holds the licence and the slot is empty |

* **small** rows are served on connect. They are the December dressing
  (present, trees, snowmen, candy, C4, sleigh): ~487 KB in total for all eight.
* **medium/heavy** rows are *never* pushed on arrival. A player who wants one is
  told the price first — `/wfcos hat_xmas_red` answers with
  *"needs a 589 KB download; the engine throttles it, so this can take a minute.
  Repeat the command to accept."* — and only the second command equips it.
* `skin` rows are **never precached by this plugin**: `v_/w_/p_` models belong to
  `weapon_models.sma`, and a second writer there is how two plugins start fighting
  over one client's model. The registry still owns their entitlement and the
  preflight still reports whether the file is here.

### The enable sequence, exactly

1. Today, with nothing uploaded: `wf_cosmetics 1` (the default) — **titles and
   badges work**, and no client downloads anything.
2. `wf_cosmetics_check` on the console: one row per cosmetic with *exists on this
   host*, the measured byte size, and whether it is precached.
3. For the medium/heavy set, decide as the operator: the cost is one connect
   download per client per map. Then set `wf_cosmetics_heavy 1` and `changelevel`,
   and run `wf_cosmetics_check` again — the row state must say `precached`.
4. A player wearing a heavy hat is warned once, in chat, before it is applied.

Rollback is one line: `wf_cosmetics 0` (or `wf_cosmetics_heavy 0` to drop just the
expensive set).

---

## 3. Entitlement: the core is the score, and one flat file for the rest

A cosmetic is **set membership**, not a payout: there is no amount to pay twice,
so there is no claim key. Where the player's ownership lives depends on how the
cosmetic is earned:

| source | score | how the plugin asks |
| --- | --- | --- |
| `secret:N` — ornament set N complete | `winterfest_core` | `wf_set_owned(id, N)` |
| `pass:N` — Winter Pass tier N reached | `winterfest_core` | `wf_pass_tier(id) >= N` |
| `tree:N` — tree level N reached | `winterfest_core` | `wf_tree_level(id) >= N` |
| `advent:N` — advent day N claimed | `winterfest_core` | `wf_advent_claimed(id, N)` |
| `gift` / `none` — a present paid it out | this plugin | one file per player |
| `none` — a staged asset nobody is awarded | — | never owned; the preflight still watches it |

The four core-backed sources are **derived**: they are never written down, so the
core stays the single score, a season reset re-locks them, and no double-write is
possible. The fifth is **recorded**, because `winterfest_core` has no cosmetics
reward kind — its `WF_REWARD_*` enum is snow, ornament, present, pass XP and
ornament-set title, and `WF_REWARD_TITLE`'s id space is the `[set]` row number. Reusing
`wf_grant()` for a hat would corrupt the set-title list, so the plugin keeps its own
flat file instead:

```
addons/amxmodx/data/freenova_wf_cosmetics/STEAM_0_1_799106783.txt
    owned = hat_xmas_red,hat_elf_green
    hat   = hat_xmas_red
    title = title_frost_keeper
```

One file per player (the shape `freenova_cosmetics` and `freenova_bp` already
use): nothing shared to corrupt, greppable, and an operator can hand-grant with
`$EDITOR` if the console is busy. Bots and HLTV are skipped everywhere — no file
I/O, no entitlement, no attachment.

`wf_cosmetics_give <target|all> <id>` grants a **recorded** cosmetic and refuses a
derived one with a line that says which source owns it.

---

## 4. Titles and badges: the layer that works today

They are pure text and they are the reward currency of Phase 1, so they get the
most care:

* **Where they show.** The tree already has one chat formatter
  (`freenova_cosmetics.amxx`: it hooks `say`/`say_team` and renders the custom
  tag, the chat title, the colour and the VIP state). A second `say` hook here
  would either double every line or win the race against it silently, so this
  plugin **does not hook chat**. It writes the title into the two surfaces the
  tree already exposes:
  1. **the player's info string** — `set_user_info(id, "name", "[Ice Warrior] name")`.
     That is the same call `fn_scan.sma` makes, and it lands on the scoreboard
     *and* in every chat line, with no client asset. The prefix is only applied
     when it fits in 31 characters: a long name is left alone rather than
     truncated, and the player is told once. It is restored on unequip, on
     disconnect and at `plugin_end`.
  2. **`freenova_cosmetics`' tag slot**, through its own natives
     (`fncosmetics_has_tag_license` / `_get_tag` / `_set_tag` / `_clear_tag`), and
     only when the player **holds the licence** and the slot is **empty** — a tag
     somebody paid 15 000 coins for is never replaced. Cleared again on unequip.
* **Which text.** A title sourced from `secret:N` is named in
  `winterfest.ini [set]`, which is the single source of truth: the core's
  `wf_set_title()` wins and the registry's `text` column is only the fallback for
  a server without the core.
* **Wearing one.** `/wfcos` lists what you own; `/wfcos <id>` wears it,
  `/wfcos off` removes both slots. `/wfcos <id>` on something you do not own says
  where it comes from (`"advent day 24"`), so the list is not a dead end.

---

## 5. Hats: an engine-side follower, three honest limits

A worn hat is one `info_target` entity with `pev_movetype = MOVETYPE_FOLLOW` and
`pev_aiment = player` — the trick `parachute.sma` uses in this tree. The engine
copies the player's origin and angles every frame, so there is **no per-frame
task** and no `set_pev` loop in the plugin. It is created on spawn, removed on
death, disconnect and unequip.

The owner's six hats are authored with their geometry **58–73 units above the
model origin** (measured from the .mdl sequence bounding box), which is exactly
head height above a player origin at the feet. That is why the follower needs no
offset.

Honest limits:

1. **A client without the file sees nothing** and downloads it (mirror, or the
   game port with `sv_allowdownload 1`). A player who never fetches it sees other
   players bare-headed; the engine does not crash and the server never notices.
2. **The wearer's own hat sits in their first-person camera.** The follower is a
   world entity at head height; inside a first-person view the brim can appear at
   the top of the screen. Making it invisible to its owner needs per-client
   entity state, which GoldSrc does not offer for a normal entity.
3. **Crouching does not lower the hat.** The follower tracks the player *origin*,
   and a crouched player's origin does not move relative to the model's bones.
   Fixing that needs bone attachment (`GetAttachment` in ReAPI) plus a per-frame
   update — the one thing this module is not allowed to add.

`skin`, `model` and `effect` rows are **entitlement only**: the visual belongs to
`weapon_models.sma` (weapon models), the model owner (player models) and
`winterfest_atmos` / `winterfest_snow` (sprites, sounds). They can ask
`wfcos_owned(id, index)` and `wfcos_precached(index)` instead of growing their own
copy of the registry. The three effect kinds (`kill`, `death`, `spawn`) are the
exception: those *are* played by this module, because the moment they belong to
(`Ham_Killed`, `Ham_Spawn`) is a moment no other module owns - §10.


---

## 6. The preflight: `wf_cosmetics_check`

This is the tool that turns "the download path might work" into facts. One line
per cosmetic that needs a download:

```
[WF-COS] registry 'freenova/winterfest/cosmetics.ini': 31 cosmetic(s), wf_cosmetics=1 heavy=0 core=yes
[WF-COS] id                     kind   weight   declared      host  fils  note
[WF-COS] present_classic        model  small       33320     33320     1  precached
...
[WF-COS] summary: 22 of 23 download row(s) complete on this host (24 file(s), 0 missing, 14472894 bytes)
[WF-COS] note: exists-on-host is all this server knows. A mirror 404 is survivable
         (sv_allowdownload 1 falls back to the game port) and a 200 proves nothing -
         only a real client joining proves a download path.
```

What it says and what it does not:

* **exists on this host** — authoritative. The only thing the server can know.
* **the byte size** — measured with `file_size()`, printed beside the operator's
  `bytes` column; a mismatch is also logged at load ("the size column is stale").
* **precached / not precached (gate) / host only (weapon_models) / MISSING** —
  the state that decides whether a client can be served it *this map*.
* **the mirror is not checked by the plugin.** fastdl is HTTPS and the sockets
  module this tree ships has no TLS, so a plugin-side HEAD is impossible. The
  operator's one-liner for a single file is
  `curl -sI https://fastdl.fn-gaming.net/cstrike/models/winterfest/present1.mdl`,
  and the known state of the mirror (2026-11-22) is: it serves what it already
  had (`awp_india.bsp` → 200) and 404s anything new (`de_tuscan.bsp` → 404).
  With `sv_allowdownload 1` a mirror 404 is survivable; only a real client
  joining proves a download path.

`wf_cosmetics_reload` re-reads the ini (titles/badges take effect immediately;
models need a `changelevel` because precache happens in `plugin_precache`).

---

## 7. What this module does not do

* **No weapon skins.** `weapon_models.sma` owns them.
* **No new chat pipe** (§4).
* **No per-player download control.** Precache is per map, not per player: either
  a file is in the table (everyone downloads it) or it is not. "Heavy only for
  players who asked" is therefore implemented as *the operator decides* plus *the
  player is warned before wearing*.
* **No second source of truth for ownership.** Derived cosmetics are asked of the
  core every time; recorded ones live in one file.
* **No per-viewer effect filtering.** A world effect is a tempentity: everyone in
  the PVS sees it. `wf_fx_lpm` honours the wearer's preference and `wf_fx 0` is
  the operator's off switch; there is no third option that hides one effect from
  one observer (§10.5).
* **No effect on a bot.** Bots are skipped by entitlement like every other
  cosmetic, so a bot never wears one (the operator command in §10.7 can still
  play one for a screenshot).

---

## 8. Files

| file | what it is |
| --- | --- |
| `scripting/winterfest_cosmetics.sma` | the plugin (registry, entitlement, preflight, and the effects of §10) |
| `scripting/include/winterfest_cosmetics.inc` | the natives (`wfcos_*`), the kind/weight/source constants and the five slots |
| `configs/freenova/winterfest/cosmetics.ini` | the registry (39 rows) |
| `plugins/winterfest_cosmetics.amxx` | the build (63 124 bytes of code) |
| `sprites/winterfest/wf_*.spr` | the six effect sprites (§10.2), 217 588 bytes in total |
| `models/winterfest/present.mdl` | the prop `death_present` leaves where you fell |
| `tools/art/mksprite.py` | PNG → GoldSrc `.spr`. Verified byte-for-byte against 269 retail sprites |
| `tools/art/gen_effect_sprites.py` | draws the six effects; the PNG strips it writes are the source of record |
| `thirdparty/winterfest-assets/effects-src/` | those PNG strips (committed, so a rebuilt `.spr` is reproducible) |
| `tests/winterfest/wfcos_bisect/` | the amxxpc bisect harness used in §9 |

`configs/plugins.ini` is the coordinator's file: the line to add is
`winterfest_cosmetics.amxx`, after `winterfest_core.amxx`. `scripts/wf-local.sh`
already lists `winterfest_cosmetics` in `WF_OPTIONAL_PLUGINS`, so the local stack
picks it up with `bash scripts/wf-local.sh sync` as soon as the `.amxx` is in
`game-server/cstrike/addons/amxmodx/plugins/`.

---

## 9. The compiler: what actually crashed, and why it looked like memory

`tools/compile-plugins.sh --only winterfest_cosmetics` used to die with

```
FAIL winterfest_cosmetics.sma: terminate called after throwing an instance of 'std::bad_alloc'
```

It compiles now, with 0 warnings. There were **two** faults in this file, and
neither was the compiler running out of memory.

### 9.1 The root cause: a C-style character escape (lines 443 and 445)

`WfcosPathAt()` trims a field and skips spaces and tabs:

```amxx
while (s < e && (list[s] == ' ' || list[s] == '\t'))     // <- this
while (e > s && (list[e - 1] == ' ' || list[e - 1] == '\t'))  // <- and this
```

This `amxxpc` build (`1.10.0.5467`) does **not** translate `\t` inside a
character constant. It reads `'\'` as `error 027: invalid character constant`,
then `t'` as the symbol `t` (`error 017: undefined symbol "t"`). On its own that
is an ordinary two-line error. Inside a nested `&&`/`||` expression it is not:
the error-recovery path parses the rest of the expression on garbage and
**throws `std::bad_alloc`**, printing nothing else.

Reproduce it in eight lines:

```amxx
public plugin_init()
{
	new c = 9, d = 3
	if (c < d && (c == ' ' || c == '\t'))   // aborts the compiler
		server_print("y")
}
```

The same line with `' '` on both sides compiles. The same `'\t'` outside a
compound expression compiles *into an error*, which is why the whole thing looks
like a memory bug that moves when the code around it moves.

**Fix:** the Pawn control-character escape, which the rest of this tree already
uses (`freenova_sync.sma:2485` has `case '^n', '^r', '^t':`):

```amxx
while (s < e && (list[s] == ' ' || list[s] == '^t'))
```

`'^t'` is one character constant, no backslash. There is a comment at the site so
it does not come back. **Rule for this tree: never write a backslash escape in a
`.sma`.** `"^n"` for a newline in strings (the file already used that), `'^t'`
for a tab.

### 9.2 The bug the crash was hiding: five undefined natives

With the crash gone the compiler could finally report the next problem:
`fncosmetics_has_tag_license`, `_get_tag`, `_set_tag`, `_clear_tag` were called
(§4, the borrowed chat-tag slot) but `<freenova_cosmetics>` was never included —
**5 x error 017**. The include is in the file now, and every call is still gated
on `LibraryExists("freenova_cosmetics")` plus the native filter, so the module
runs on a server without that plugin.

### 9.3 Two faults that only a running server would have shown

Both were found on the local stack, not by the compiler:

* `get_players(players, n, "ch")` in `wf_cosmetics_give` and `wf_cosmetics_fx`.
  The `h` flag means "match the authid given as an argument", and with no authid
  argument it matches **nobody** — so `wf_cosmetics_give all …` and
  `wf_cosmetics_fx all …` silently did nothing (`on 0 of 0 client(s)`). Both now
  take every client and skip bots/HLTV in the loop.
* An effect row naming a **`.mdl`** (`death_present`) was never precached: the
  effect branch of the precache loop only handled sprites. The first
  `EngFunc_SetModel` on it took the whole **map** down with
  `Host_Error: PF_setmodel_I: no precache: models/winterfest/present.mdl`. Both
  file types are precached now, and `wf_cosmetics_fxinfo` says so if an effect
  row has no sprite.

### 9.4 Why the first pass got this wrong (worth reading before you bisect it)

An earlier pass on this file concluded "a budget in the compiler, not a bug in
one function" and left §9 open. The measurements behind that conclusion were
real; the conclusion was not. What is true:

* Deleting one statement of `WfcosPathAt` never fixed the crash; deleting the two
  `'\t'` lines together did. The culprit is a *token*, and it only crashes in a
  context the parser reaches while recovering from it.
* Because the crash happens **while recovering from an error**, anything that
  changes whether the compiler has to recover changes the result. Adding three
  statements elsewhere removes the crash; removing one elsewhere creates it. That
  is why "it moved when I touched it" was misread as a size budget.
* The method that works is the one in `tests/winterfest/wfcos_bisect/`: **stub
  whole function bodies** (`{ return 0; }`) so the file stays error-free and the
  back end runs, then bisect by function, then by statement inside the function
  that owns it. Here: 15 stub runs to name `WfcosPathAt`, then 2 more to name the
  two lines.
* A related trap, met while writing §10: referencing a **global declared later
  in the file** also ends in `std::bad_alloc` (no error, no line number). If a
  bisect says "adding one `g_something++` crashes", check where `g_something` is
  declared before you believe it.

---

## 10. The effects: kill, death, spawn, and the kill word

This is the layer the owner asked for: *"the cosmetics, the kill / death / spawn
effects should be made better, more unique, more special … with custom sprites,
cool animations"*. What existed before (§5 last paragraph) was entitlement only,
and the two effect systems elsewhere in the tree are a single
`TE_BEAMCYLINDER`/`TE_SPARKS` with a stock sprite (`freenova_cosmetics.amxx`,
which keeps its own coin-shop effects and is not touched by this module).

### 10.1 Three slots, three moments, one row each

| slot | when it plays | where | who owns it |
| --- | --- | --- | --- |
| `kill` (`WFCOS_SLOT_KILL`) | `Ham_Killed`, on the **killer** | the victim's body | the killer |
| `death` (`WFCOS_SLOT_DEATH`) | `Ham_Killed`, on the **dying** player | where they fell | the dying player |
| `spawn` (`WFCOS_SLOT_SPAWN`) | `Ham_Spawn` + 0.45 s | at their feet | the spawning player |

A player wears one of each (they are independent slots, `WFCOS_MAX_SLOTS` is 5:
hat, title, kill, death, spawn). Nothing is granted by this module except through
the sources in §3, and `/wfcos <id>` is still how one is worn.

The spawn delay is deliberate: half a second after the body appears, so nothing
it draws can cover the first instant of the round, and it is gone (0.7 s sprite)
before anyone can line up a shot. It never creates anything solid.

### 10.2 The assets: where every byte came from, and its licence

Six sprites and one model. The owner's rule for this workstream is *"use exactly
the photos I provided - just put them there and make them functional - do NOT
make anything by itself"*, so nothing here is AI-generated and nothing was
downloaded. Each sprite is **procedural geometry drawn in code** (circles,
triangles, rings, polygon wings - "a procedural snow burst is fine: it is shapes,
not a picture"), and each is reproducible from this repo alone.

| file | size | dims | frames | origin | licence |
| --- | --- | --- | --- | --- | --- |
| `sprites/winterfest/wf_snowpuff.spr` | 25 506 B | 64x64 | 6 | `tools/art/gen_effect_sprites.py` `snowpuff()` - 8 radial puffs + 1 ring, drawn with PIL | this repo's own work: procedural geometry, no third-party asset, no AI |
| `sprites/winterfest/wf_bauble.spr` | 33 738 B | 64x64 | 8 | same file, `bauble()` - 3 ellipses, 2 crack strokes, 9 shard polygons | same: this repo's own work |
| `sprites/winterfest/wf_gift.spr` | 29 622 B | 64x64 | 7 | same file, `gift()` - 5 rectangles, 2 bow ellipses, 8 star shards | same: this repo's own work |
| `sprites/winterfest/wf_iceshard.spr` | 25 506 B | 64x64 | 6 | same file, `iceshard()` - 7 shard polygons + 1 ring | same: this repo's own work |
| `sprites/winterfest/wf_snowangel.spr` | 56 226 B | 96x96 | 6 | same file, `snowangel()` - 2 wing polygons + 2 body ellipses | same: this repo's own work |
| `sprites/winterfest/wf_ring.spr` | 46 990 B | 96x96 | 5 | same file, `ring_aurora()` - 2 polygon rings + 1 core puff | same: this repo's own work |
| `models/winterfest/present.mdl` | 42 828 B | - | - | owner-supplied Christmas pack, already in the tree (`thirdparty/winterfest-assets/README.md`) | the owner's asset; it shipped in `models/winterfest/` before this module existed |

The repository as a whole has **no chosen licence** yet (`README.md` §License),
which is an owner decision; what matters here is that no sprite in this module
carries a third party's terms, because there is no third party: every pixel of the
six `.spr` files is generated by this repo's own code from shapes, and the one
model was already in the owner's tree.

What each one draws, one line each, is §10.3. The PNG strips the sprites are
packed from are committed under `thirdparty/winterfest-assets/effects-src/`, so a
`.spr` is never hand-edited: it is regenerated.

The stock engine sprites this module leaves alone: nothing is shipped as a copy of
`sprites/glow01.spr`, `sprites/laserbeam.spr` or `sprites/explode*`. Those are
used only where the engine already guarantees them (a `TE_ELIGHT` needs no sprite
at all, and every `TE_SPRITETRAIL` here uses our own `.spr`, never a stock one),
so a client with a stripped install still sees the effects.

Total new client bytes: **217 588 B across six rows**, every row individually
under the 150 KB `small` line, so they ride the connect download the way the
small props do (§2). At 8-bit indexed that is ~5 KB/frame - a 32-bit RGBA version
of the same set would have been four times the connect cost for art that is
mostly one flat colour.

Regenerate, in order, from this repo alone:

```sh
python3 tools/art/gen_effect_sprites.py      # PNG strips + .spr
python3 tools/art/gen_effect_sprites.py --list
python3 tools/art/mksprite.py --verify-sprites build/wf-local/server/cstrike/sprites
```

That last command is the reason to trust the writer: it re-encodes **every**
retail `.spr` on the box (269 of them, single- and multi-frame) and diffs the
bytes against the original. The first time it was run, everything matched, which
is how the container layout in `mksprite.py`'s docstring was confirmed - GoldSrc
has no specification that agrees with itself, so the layout was derived from
retail files and then proved by round-trip.

Sizing rules the art follows (a kill effect is seen for well under a second, at
range, on a 640x480 client): one big silhouette, a bright core, no thin detail;
4x supersampled then downscaled so the edges stay soft at 8 bits. The two 96x96
sprites are the ones a player reads from their own feet.

### 10.3 The eight effects, by id

| id | name | slot | rarity | source | sprite | what it looks like |
| --- | --- | --- | --- | --- | --- | --- |
| `kill_snowpuff` | Snow Puff | kill | 0 | gift | snowpuff | the corpse disappears into a cold white puff of snow with a blue light |
| `kill_bauble` | Bauble Shatter | kill | 1 | pass:7 | bauble | a bauble holds for a beat, cracks, and bursts into red and gold shards with sparks |
| `kill_gift` | Gift Pop | kill | 2 | secret:2 | gift | a parcel implodes, snaps open, and a gold eight-point star rolls out of it |
| `kill_iceshard` | Frost Shards | kill | 2 | tree:12 | iceshard | seven ice shards stab up out of the body under a white flare |
| `death_snowangel` | Snow Angel | death | 1 | gift | snowangel | an angel's wings and body spread in the snow where you fell, and fade over five seconds |
| `death_present` | Last Present | death | 2 | advent:12 | present.mdl | a wrapped present is left exactly where you died and stays for twenty seconds |
| `spawn_aurora` | Aurora Ring | spawn | 0 | gift | ring | a violet and green ring blooms outward from your feet and is gone in under a second |
| `spawn_frost` | Frost Bloom | spawn | 1 | pass:3 | snowpuff | a small frost flower puffs open at your feet as you leave the spawn point |

Each one is: an **animated sprite the engine animates**, plus a **message layer
that costs no entity** (a `TE_SPRITETRAIL` rising off the body in the effect's own
sprite, a `TE_ELIGHT` in the effect's own colour, `TE_SPARKS` where it fits). The
look is picked from the sprite the row names, so an operator who adds
`kill_mything | … | kill | … | sprites/winterfest/wf_bauble.spr` gets the bauble
colours, trail and light for free; an unknown sprite falls back to the snow
grammar rather than inventing one.

### 10.4 What it costs, and the caps (measured, not estimated)

Two decisions keep this affordable on the owner's low-end boxes:

* **the animation is the engine's.** The sprite is one `env_sprite` with
  `pev_framerate` set; the engine advances `pev_frame` itself. This plugin has
  **no per-frame loop, no think hook and no per-effect task.** The only timer in
  the whole effect system is one 0.25 s reaper that exists only while something is
  alive.
* **an effect is not all-or-nothing.** The message layer is sent whether or not
  the entity layer is allowed, so a server at its ceiling still shows a burst.

| switch | default | what it does |
| --- | --- | --- |
| `wf_fx` | **1** | master. `0` = no message, no entity, no light: the registry still loads |
| `wf_fx_entmax` | **12** | live effect entities on the whole server (clamped to the 16-slot table) |
| `wf_fx_entmax_p` | **2** | live effect entities per player, so one player spamming cannot eat the budget |
| `wf_fx_verb` | **1** | the kill line: `0` off, `1` killer and victim, `2` everyone (§10.6) |
| `wf_fx_lpm` | **1** | a player in Low Performance Mode gets no entity and no sprite (§10.5) |
| `wf_fx_debug` | 0 | one `log_amx` line per effect with the live count and the engine's own entity count |

Lifetimes (all reaped by the same table scan): kill sprite 0.9 s, spawn sprite
0.7 s, death imprint 4-5 s, death prop 20 s.

Measured on the local stack (`build/wf-local`, `de_dust2`, 5 bots, fresh boot)
with `wf_cosmetics_fx` (the operator command of §10.7) as the trigger, and
`wf_fx_debug 1` writing one line per effect to
`addons/amxmodx/logs/L<date>.log`:

| what | live effect entities | engine `EngFunc_NumberOfEntities` | counters |
| --- | --- | --- | --- |
| idle, nothing playing | 0 | **125** | - |
| one `kill_bauble` on every client (5) | 5 | **130** (+1 per effect, exactly) | played 5, refused 0 |
| two seconds later | **0** | 128 (baseline drifts with bots spawning) | - |
| 6 tries on ONE client, 20 s prop | **2**, then flat | 130 | played 11, **refused 4** |
| + two passes on all 5, per-player ceiling raised to 8 | **12** (the global ceiling, held; "room for 0 more") | 140 | played 21 |
| 21 s later, past the 20 s prop lifetime | **0** | 128 | - |
| `wf_cosmetics 0` (the same early return LPM uses) | 0 | unchanged | 15 tries, **15 downgraded**, 0 entities |

The raw lines, one per effect, are the evidence - e.g.

```
[WF-COS] fx kill_bauble slot 3 at 5: 5 live entity(s), 1 for that player, 0 skipped, engine 130 entities
[WF-COS] fx death_present slot 4 at 1: 1 live entity(s), 1 for that player, 0 skipped, engine 129 entities
```

So the worst case a busy round can add is **12 entities** - and the plugin's own
counts agree with the engine's (`125 → 130` for five effects is exactly one entity
each, and the count returns to the baseline once the reaper has run). That is the
number to watch on a real box: `wf_cosmetics_fxinfo` prints it live, in one line,
with the engine's count beside it.

### 10.5 Low Performance Mode

`wf_fx_lpm 1` (default) asks `freenova_prefs` through its **native**
(`fnpref_get(id, FNPREF_LOW_PERF)`), never by reading another plugin's file, and
the call is gated on `LibraryExists("freenova_prefs")` plus the native filter.
A player with LPM on gets the kill line and nothing else: no entity, no sprite,
no light. An absent or unloaded `freenova_prefs` means "no preference", not
"assume low".

**The honest limit:** this module plays a *world* effect, and GoldSrc sends a
tempentity to every client in the PVS. It cannot be hidden from a low-end
*observer* - only the wearer's own preference and the two ceilings can be
honoured. An operator who wants zero cost for everyone sets `wf_fx 0`; that is
the switch that actually protects the observers, and the doc should say so rather
than imply per-viewer filtering we do not have.

### 10.6 The kill word, and the kill feed it must not duplicate

A `kill` row's `text` column is a **verb**: `snowed under`, `shattered`,
`gifted`, `froze`. On a kill, with `wf_fx_verb`:

* `1` (default) - one line to the killer and one to the victim:
  `you shattered X` / `Y shattered you`. A 32-slot server with everyone wearing a
  kill effect therefore adds **two** chat lines per kill, not 32.
* `2` - one line to everyone: `[WF] Y shattered X`.
* `0` - no line at all; the visuals still play.

**Integration, and why it duplicates nothing.** `winterfest_killfeed.amxx`
(workstream 6, not touched here) also reads `DeathMsg`; it owns the streak lines
at 3/5/7/10/15, the headshot "ho ho ho" and the rare Santa line, and it never
prints the victim's name. This module's line names the killer, the verb and the
victim - a different sentence, from a different file, on the same event. There is
no native to call and no config to share; the event is the interface, exactly as
the killfeed's own header describes it. The one overlap to know about is a
headshot kill: with `wf_fx_verb 2` that kill shows killfeed's line and ours, which
is why the default is `1` (killer and victim only).

### 10.7 Seeing one without dying: `/cospreview`

```
/cospreview            list the eight effect ids
/cospreview <id>       play it on your own body
```

Owners may preview what they own; an admin (`ADMIN_CFG`) may preview anything,
which is how an effect gets looked at before it is priced. One preview every 3
seconds per player, alive only, and it grants/equips nothing. It refuses with a
reason that says why (`effects are off (wf_fx 0)`, `not yours yet - it comes from
pass tier 7`, `Low Performance Mode is on for you, so nothing was drawn`).

The operator side of the same call:

```
wf_cosmetics_fx <target|all> <effect id>   play it now, no kill and no ownership
wf_cosmetics_fxinfo                        live entities, ceilings, counters, engine count
wf_cosmetics_check                         the preflight of §6 (now includes the effect rows)
```

`wf_cosmetics_fx all kill_bauble` is how the measurement table in §10.4 was taken
with nobody at the keyboard.

### 10.8 What is not proven (read before believing the screenshots)

1. **No real client has worn one yet.** The local stack is five bots, and bots are
   skipped by entitlement (`is_user_bot`), so the *event wiring*
   (`Ham_Killed → WfcosFxPlay`, `Ham_Spawn → +0.45 s → WfcosFxPlay`) was exercised
   through `wf_cosmetics_fx`, which calls the same function with the same slot;
   the `/wfcos` equip path for a real player is reviewed, not observed.
2. **The engine's own animation is assumed, not observed.** `env_sprite` is
   created with `pev_framerate` and `DLLFunc_Spawn`, so the engine's sprite think
   animates it. If a future engine build did not, the effect would show frame 0 -
   still a legible burst, and the `TE_SPRITETRAIL` layer (which animates by
   construction) is unaffected.
3. **A billboard cannot lie flat.** `wf_snowangel` is a `SPR_VP_PARALLEL` sprite,
   so it always faces the viewer rather than lying on the floor. It reads as an
   angel rising out of the snow, which is the better of the two options at
   640x480, but it is not an imprint decal and is not described as one in game.
4. **`texFormat` is copied, not understood.** The `.spr` writer reproduces the
   byte layout of retail sprites exactly, but the meaning of the `texFormat` field
   is not documented anywhere reliable; blending is set on the entity
   (`kRenderGlow`) instead, so nothing depends on it.

### 10.9 Adding a ninth effect is one row

```ini
kill_mything | My Thing | kill | small | 25506 | 1 | gift | 1 | sprites/winterfest/wf_snowpuff.spr | froze
```

then `wf_cosmetics_reload`, `changelevel` (sprites are precached in
`plugin_precache`), and `wf_cosmetics_check` to prove the file is here and its
byte count matches. A new *sprite* is `tools/art/gen_effect_sprites.py`
(`EFFECTS` table) + `mksprite.py`; nothing in the plugin names a file.
