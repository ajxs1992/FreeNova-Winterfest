# WINTERFEST-MODES.md — snowball fight, frozen grenades, reindeer hunt

The gameplay modes of Winterfest 2026 (workstream 7 of
`docs/WINTERFEST-WORKSTREAMS.md`). Product contract: `docs/WINTERFEST.md` §3
("snowballs, reindeer hunt ... each a mode; they plug into the `fn_mode` arbiter
being built now") and §1.3 (stock sprites, engine messages, **no client
download**).

Read §3 (the arbiter contract) before changing anything here: it is the rule
that keeps a mode from leaking a cvar into the next round.

---

## 1. What ships

| file | what it is |
| --- | --- |
| `scripting/winterfest_snow.sma` → `.amxx` | the `snow` mode: snowballs, the slow effect, "frozen solid", frozen grenades, and the workstream's plumbing (`wf_mode`, `/wfsnow`, the rotation, the hand-off to the reindeer module) |
| `scripting/winterfest_reindeer.sma` → `.amxx` | the `reindeer` mode: non-solid targets, geometric hit test, snowflake reward, respawn, `wf_reindeer` |
| `configs/freenova/winterfest/modes.ini` | every number, the rotation list, the reindeer spawn points |
| `tests/winterfest-snow7/` (harness repo) | the scripted restore proof: `wf7_probe.sma` + `.commands` + `.expect` |

Load order (the coordinator's `plugins.ini`): **`fn_mode.amxx` before both**,
`winterfest_reindeer.amxx` before `winterfest_snow.amxx`. The snow module calls
the reindeer module's natives; the reindeer module calls nobody (see §7), so
that one direction is the only ordering constraint. Both also work alone.

Neither plugin needs `winterfest_core`: the snowball fight pays nothing, and the
reindeer reward is skipped (with a log line) when the core is absent or the
season is shut.

---

## 2. The inputs (the design call this workstream had to make)

`+use` is the drop key and `+attack2` is the scope / silencer key, so **no input
is free**. The module does both halves of the honest answer instead of picking
one and pretending:

| input | who | notes |
| --- | --- | --- |
| `bind <key> +snowball` | the player, once | The server never issues a `bind`: rewriting a player's keys is rude and can wreck a whole config for one mode. The mode's start line names the bind. |
| `+attack2` (mouse2) | nobody, it just works | While the `snow` mode runs, mouse2 throws. **Cost:** inside the mode mouse2 stops scoping and stops toggling a silencer. |
| `say /wfsnow` / `say_team /wfsnow` | any human | The public vote. Gated by the cvar `wf_snow_vote`. |
| `wf_mode <snow\|reindeer\|off\|status> [force]` | admin, `ADMIN_CFG` | The one mode command. `force` skips the "nobody is playing" check (used to set a mode up before players arrive, and by the harness). |
| `wf_reindeer <on\|off\|status> [force]` | admin, `ADMIN_CFG` | The reindeer module's own entry point, for a server that does not load `winterfest_snow`. |
| `wf_modes_reload` | admin, `ADMIN_CFG` | Re-reads `modes.ini` in **both** modules (registered by `winterfest_snow`; if only the reindeer module is loaded it is not available - a map change also reloads). |

`[snow] input` chooses: `0` = `+attack2` (default), `1` = `+snowball` only,
`2` = both. With `1`, mouse2 keeps scoping inside the mode.

Bots and HLTV proxies are never a thrower, never count as a vote, never get a
reindeer reward, and are never frozen by a grenade - the workstream rule
("bots excluded from every player-facing entry point").

---

## 3. The arbiter contract (`include/fn_mode.inc`)

`fn_mode.amxx` is the **only** thing that writes an engine cvar for a mode. What
these plugins do, and refuse to do:

1. **`fn_mode_begin(mode, payload, initiator)` first, before anything else.** It
   is refused while another mode holds the arbiter, and the refusal is logged,
   shown to admins, and shown to whoever tried (chat for a player, a console
   line for the console). Both plugins additionally print the arbiter's reason
   to the server console, so an operator reading the console is never left
   guessing: `[WF-SNOW] not started: <reason>`.
2. **Never a direct cvar write.** Every engine cvar goes through
   `fn_mode_set(mode, cvar, value)`, which snapshots the pre-mode value the first
   time that cvar is touched. A refused set is logged, never retried directly:
   a cvar this plugin wanted and did not get is better than a cvar it cannot
   restore.
3. **`fn_mode_end(mode)` last.** It restores the whole table (last set, first
   restored) and releases the arbiter. The number of restored cvars is in the
   log line: `[WF-SNOW] ended (<reason>) - 2 cvar(s) restored`.
4. **The arbiter's `plugin_end` is the net.** A map change, a plugin reload or an
   admin who forgets `wf_mode off` cannot leave `mp_friendlyfire 0` or
   `mp_freezetime 0` behind: `fn_mode` restores on unload and logs
   `[FN-MODE] plugin_end: 'snow' still active, restored 2 cvars`.
5. **Missing arbiter ⇒ no mode.** If `fn_mode.amxx` is not loaded, `wf_mode
   <anything>` is refused with one line (`fn_mode (the mode arbiter) is not
   loaded - no mode can start`) and **nothing is changed**. The plugin still
   loads: `plugin_natives()` installs a native filter (`set_native_filter`, the
   `fn_servers.sma` pattern), so an absent `fn_mode` is a clean load rather than
   a bad load. Same treatment for `winterfest_core` and `winterfest_reindeer`.

**What is *not* the arbiter's job, and is ours:**

* **Per-player maxspeed.** `set_user_maxspeed` is an entity field, not a cvar -
  `fn_mode` cannot restore it. Both effects (the slow and the freeze) share one
  per-player table in `winterfest_snow.sma`: the speed the player had **before**
  the first effect is captured once, the strongest active effect is applied, and
  the remembered value goes back when the last one expires. A mode end, a death,
  a respawn, a disconnect and `plugin_end` all clear it, so nobody is ever left
  crawling at `maxspeed 1`.
* **Entities.** The reindeer (`info_target` + `env_sprite`) and the present-style
  glows are killed on mode end and on `plugin_end`; the arbiter knows nothing
  about entities.

| mode | engine cvars it sets (via `fn_mode_set`) |
| --- | --- |
| `snow` | `mp_friendlyfire` (`[snow] friendlyfire`, default 0), `mp_freezetime` (`[snow] freezetime`, default 0; `-1` = not touched, not tracked) |
| `reindeer` | none - it adds targets, it does not rewrite the round. It still claims the arbiter, so a hunt can never run on top of a warmup or an event mode. |

### 3.1 The missing-arbiter boot (verified)

`tests/winterfest-snow7/wf7_noarbiter.{sma,commands,expect}` is the second
scripted proof: it boots the live stack with `fn_mode.amxx` commented out and
asserts three things - the arbiter really is absent
(`[WF7NOARB] tick fn_mode=0 core=1`), a start is refused with **one line**
(`[WF-SNOW] fn_mode (the mode arbiter) is not loaded - no mode can start`), and
**nothing changed** (`pre freezetime=7 ff=1` / `after freezetime=7 ff=1`). Both
Winterfest modules are still `running` in that boot: a missing arbiter is a
refusal, never a bad load and never a half-applied mode.

*Found while proving that (not this workstream's files, reported to the
coordinator):* with `fn_mode.amxx` absent, `simple_warmup.sma` and
`fn_balance.sma` **bad load** - they include `<fn_mode>` without a
`set_native_filter` guard. Every other plugin in that boot, both Winterfest modes
included, runs.

---

## 4. Cvars

Everything except these five switches is `modes.ini` (§5); the switches are cvars
so an operator can flip them live.

| cvar | default | meaning |
| --- | --- | --- |
| `wf_snow_enable` | `1` | master switch for the snow mode (both this and `[modes] snow enabled` must be on) |
| `wf_reindeer_enable` | `1` | master switch for the reindeer hunt |
| `wf_snow_vote` | `1` | gate for `say /wfsnow` |
| `wf_rotation_enable` | `-1` | `-1` = follow `[rotation] enable`, `0` = off, `1` = on |
| `wf_modes_debug` | `0` | one log line per snowball trace / per near miss on a reindeer, plus the resolved reindeer spot origins on load - this is the tuning and "did my ini row land?" switch |

---

## 5. `modes.ini`

`addons/amxmodx/configs/freenova/winterfest/modes.ini`. Two row shapes:
`key = value`, and `id | a | b | c` tables. `;` and `#` start a comment. Every
cap and range is enforced while parsing; a row that does not fit is skipped with
a log line, never applied half-way.

| section | fields |
| --- | --- |
| `[modes]` | `id \| enabled \| rounds \| max_seconds` - `rounds` is how many round starts the mode holds; `max_seconds` is a hard ceiling (`0` = none). **A mode always has a way out**: rounds, the ceiling, an empty server, an admin, or `fn_mode`'s map-end net. |
| `[snow]` | `damage`, `damage_spread` (12 ± 2 = 10..14), `slow` (percent of the player's own speed), `slow_time`, `cooldown`, `ammo` (0 = unlimited), `range`, `freeze_time`, `freeze_on_kill`, `lethal`, `friendlyfire`, `freezetime`, `input`, `visual` |
| `[grenade]` | `enable`, `radius`, `freeze_time` |
| `[reindeer]` | `count` (1..8), `respawn`, `reward` (snowflakes, 0 = none), `radius` (hit radius), `range`, `glow_scale`, `visual` |
| `[vote]` | `ratio` (percent of connected humans), `min` (votes always needed) |
| `[rotation]` | `enable`, `every_rounds`, `min_humans`, `list` (`snow, reindeer`) |
| `[reindeer_spots]` | `map \| x y z`, plus `*` generic rows. No map rows ship on purpose - see the file's own comment: the built-in spawn-derived set covers any map (measured: 8 spots on `de_dust2`, 2 on `de_inferno`), and per-map rows are how an operator buys *spread*. |

`visual` deserves a note: **only `sprite` exists today**. The staged assets
(`thirdparty/winterfest-assets/README.md`: `models/{p,v,w}_flashbang.mdl` as a
snowball, `sneeuwman.mdl` / `frost_man.mdl` as targets) are client content and
blocked until fastdl works (`docs/WINTERFEST.md` §1.1). The key is read, and a
value other than `sprite` is **logged and refused at mode start** rather than
ignored - so the day the models ship, the config change is one accepted value
and the code change is a precache.

---

## 6. Lifecycle, and the rotation

```
wf_mode snow force        -> fn_mode_begin("snow") + fn_mode_set(mp_friendlyfire, mp_freezetime)
   ... rounds / clock / an empty server / `wf_mode off` / map end ...
                          -> fn_mode_end("snow")  (every cvar restored)
```

* the mode lasts `[modes] snow rounds` round starts, or `max_seconds`, whichever
  comes first; an empty server ends it too unless it was started with `force`
  (which is what `force` is for: setting a mode up before players arrive - the
  rounds and the ceiling still end it);
* the reindeer hunt counts its rounds the same way and respawns a shot reindeer
  after `[reindeer] respawn` seconds at another spot;
* the rotation starts one mode every `[rotation] every_rounds` round starts, in
  `list` order, **one at a time** (that is the arbiter, not a limitation of the
  rotation). An entry that cannot start (disabled, its module missing, the
  arbiter busy) is skipped and the next one is tried, so one broken row cannot
  burn the rotation.

Announcements are one line at start and one at end, to everyone, e.g.
`[WF] Snowball fight! Mouse2 (or 'bind <key> +snowball') throws - frozen grenades work too.`
and `[WF] Snowball fight over - normal weapons, damage and rules are back.`

The snowball itself: a **hitscan in the view cone** (`EngFunc_TraceLine`, no
entity, no projectile physics, no per-frame cost), a white stock-sprite
`TE_BEAMPOINTS` trail and a `TE_SPRITE` puff at the impact, per-life ammo, a
per-player cooldown, a slow effect, and - by default - **"frozen solid" instead
of a death**: a hit that would take the last HP leaves 1 HP, sets
`maxspeed 1` and swallows `+attack` for `freeze_time`. The mode therefore never
produces a death, a frag, an XP event or a BattlePass tick. `[snow] lethal = 1`
switches to the engine's damage path for an operator who wants real deaths (and
everything downstream then sees them, as usual).

Frozen grenades: an `hegrenade` explosion freezes everyone inside
`[grenade] radius` for `[grenade] freeze_time`. The thrown entity is identified
by its world model (`w_hegrenade.mdl`), the only discriminator this AMXX build
exposes (there is no `Ham_Explode` and no ReAPI `CBaseGrenade::Explode` in this
tree), and the explosion is handled once per grenade entity. A flashbang still
hurts and blinds exactly like before.

Reindeer hit test, in one paragraph: every gun class gets one
`Ham_Weapon_PrimaryAttack` pre-hook (the same idiom `rsu_core.sma` uses for shot
counting), so one trigger pull = one hook. The hook does nothing unless the mode
runs; when it runs, the shooter's eye position and view angle are projected onto
each live reindeer's origin, and a target inside `radius` of that ray - with a
clear line of sight by `EngFunc_TraceLine` - is hit. A non-solid entity cannot be
hit by a bullet in GoldSrc (the bullet trace only tests solid entities), so a
shootable marker has to be geometry; the marker itself is an `info_target` with
`SOLID_NOT`, which cannot block a player, be touched, or become a bot.

---

## 7. Module contract (natives)

`winterfest_snow` registers `register_library("winterfest_snow")` and the native
`wf_snow_mode_active()`. `winterfest_reindeer` registers
`register_library("winterfest_reindeer")` and:

| native | returns |
| --- | --- |
| `wf_reindeer_start(initiator, bForce)` | `1` started, `0` refused (the reason is on the console + the log) |
| `wf_reindeer_stop()` | `1` was running and was ended, `0` was not running |
| `wf_reindeer_active()` | `1` while the hunt runs |
| `wf_reindeer_reload()` | `1` - re-read `modes.ini`, and move the targets if the hunt is running |

They are declared **in the calling `.sma`**, not in `include/winterfest.inc`,
because that include belongs to workstream 1 and this workstream must not edit
it. `winterfest_reindeer` deliberately calls *no* native of
`winterfest_snow`: "is the snow mode running" is answered from the arbiter
(`fn_mode_active`), which loads before both, so a status line can never be a
no-op stub lying about it.

---

## 8. The restore proof

Scripted, in the harness (`cs16-linux-base`), on the live plugin stack:

```bash
cd /home/ajxs/Desktop/Projects/cs16/cs16-linux-base
# winterfest_snow.amxx + winterfest_reindeer.amxx must be in the profile's
# plugins list (the coordinator adds them to the repo plugins.ini; for the
# harness tree they are appended by hand - test tree only)
flock /tmp/cs16-harness.lock ./scripts/test-plugin.sh \
  tests/winterfest-snow7/wf7_probe.sma --profile freenova --boot-timeout 180
```

The probe sets `mp_freezetime 7` and `mp_friendlyfire 1` first - **neither is the
default** (`mp_freezetime` is 5, `mp_friendlyfire` is 0), so a "restore to the
default" fails the test and only a restore to the *pre-mode* value passes it -
then drives the cycle. Verbatim from the console log of the recorded run:

```
[WF7PROBE] pre freezetime=7 ff=1 arbiter=<free>
[fn_mode] [FN-MODE] begin 'snow' (payload 'rounds=3 max=900', by winterfest_snow.amxx)
[fn_mode] [FN-MODE] snow: mp_friendlyfire '1' -> '0' (pre-mode '1')
[fn_mode] [FN-MODE] snow: mp_freezetime '7' -> '0' (pre-mode '7')
[WF-SNOW] started by 0 (rounds=3 max=900s damage=12 ammo=8 ff=0 lethal=0 forced=1 tracked=2)
[WF7PROBE] during freezetime=0 ff=0 count=2 arbiter=snow
[WF7PROBE] tracked mp_friendlyfire pre=1
[WF7PROBE] tracked mp_freezetime pre=7
[WF-SNOW] the snowball fight is already running (wf_mode off ends it)
[fn_mode] [FN-MODE] can't start 'reindeer': 'snow' is already running (payload 'rounds=3 max=900')
[WF-REINDEER] not started: 'reindeer' refused: 'snow' is active (payload 'rounds=3 max=900', by winterfest_snow.amxx)
[WF7PROBE] still_running_after_refusal=2
[fn_mode] [FN-MODE] end 'snow' (restored 2 cvars)
[WF-SNOW] ended (wf_mode off) - 2 cvar(s) restored
[WF7PROBE] after freezetime=7 ff=1 count=0 arbiter=<free>
[WF7PROBE] restore_ok=1
```

Read it in four parts:

1. **begin, and what it changed** - two cvars, both snapshotted with their
   pre-mode values (`1` and `7`).
2. **a second start is refused with a reason** - the module's own reason
   (`already running`) on the console *and* in the log.
3. **a second, different mode is refused by the arbiter** - `fn_mode` says who
   holds it and with what payload; the reindeer module repeats the reason.
4. **end restores everything** - `restored 2 cvars`, the tracked table is empty
   (`count=0`), the arbiter is `<free>`, and the two cvars are back at `7` and
   `1`. `restore_ok=1` is that comparison, computed by the probe.

The same run then starts the reindeer hunt on the same arbiter, checks its
targets, ends it, and asserts the arbiter is free again:

```
[fn_mode] [FN-MODE] begin 'reindeer' (payload 'deer=3 rounds=2 spots=8', by winterfest_reindeer.amxx)
[WF-REINDEER] spawned 3/8 reindeer
[WF-REINDEER] mode=1 forced=1 rounds_left=2 seconds=0 kills=0 starts=1 ends=0 arbiter_cvars=0
[WF-REINDEER] alive=3/3 spots=8 radius=40 range=4000 respawn=20s visual=sprite
[fn_mode] [FN-MODE] end 'reindeer' (restored 0 cvars)
[WF-REINDEER] ended (stop requested) kills=0 - 0 cvar(s) restored
[WF7PROBE] deer_after count=0 arbiter=<free>
```

Recorded run: `RESULT ok slug=wf7_probe` - every expect line passed, no
`Run time error`, no `bad load`, all plugins running. The same probe was also run
on `de_inferno` (no map rows in `modes.ini`, so the built-in spawn-derived spots
and the "any map" path are covered): `RESULT ok slug=wf7_probe`.

**Also proven, for free:** the map-end net. In an earlier run the server was
stopped while the mode was still active, and `fn_mode` put the cvars back on
unload: `[FN-MODE] plugin_end: 'snow' still active, restored 2 cvars
(end-of-map safety net)`.

---

## 9. What a human has to verify in game

Nothing below can be proven by a headless boot; it needs a person with a mouse.

1. **Input feel.** `bind v +snowball`, then throw with `v` and with mouse2 in
   turn. The cooldown (0.8 s) should feel like a rhythm, not a stutter. If mouse2
   stealing the scope is unacceptable on a knife/AWP round, set `[snow] input = 1`.
2. **Damage numbers.** Default 12 ± 2 should take 4-6 snowballs to freeze
   someone. Watch `[snow] damage` / `damage_spread` against how often people
   actually freeze; `wf_modes_debug 1` logs every trace if a hit rate looks wrong.
3. **The slow.** 55 % for 2 s should be noticeable without being a death
   sentence; check that the speed goes back to normal (maxspeed restore) after
   the timer, after a respawn, and after `wf_mode off`.
4. **"Frozen solid".** A frozen player should not be able to shoot or move for
   1.5 s, and their HUD should say so. Check the fade is readable and is *not*
   white enough to look like a flashbang (`freenova_flash` suppresses near-white
   fades on purpose, which is why this one is pale blue).
5. **Frozen grenades.** Throw an HE into a group: everyone inside 250 units
   freezes for 2 s; a flashbang behaves exactly as before. 250 is a starting
   number - raise it if it feels useless, lower it if a single grenade ends the
   round.
6. **Reindeer.** With `wf_modes_debug 1` and `wf_reindeer on`, look at where the
   targets sit on the maps you actually play (`wf_modes_debug` logs the resolved
   spots). The built-in set sits near spawn points; if the hunt feels like
   shooting fish in a barrel, add `[reindeer_spots]` rows (§5) - that is the knob.
7. **The hit radius.** 40 units is generous. If bullets that visually miss still
   count, drop it to 28-32; the debug line prints "missed by N units", which is
   the number to tune against.
8. **The rotation.** `wf_rotation_enable 1` with `every_rounds = 6` on a busy
   server: one mode every six rounds, always one at a time, and normal play
   between them.
9. **Spread of the reward.** 5 snowflakes per reindeer, once per reindeer
   instance. Check it against the present payout before December.

---

## 10. Deliberately not done

* **No client content.** No snowball model, no reindeer/snowman model, no custom
  sprite, no sound. `visual = sprite` is the only working value (§5). The staged
  assets stay staged.
* **No `wf_core` requirement, and no direct reward write.** The reindeer reward
  goes through `wf_grant()` with the reindeer instance as the claim key, so an
  instance pays once, and a server without the core simply pays nothing.
* **No snowball stat/XP/BP feed.** By default snowball damage is subtracted from
  health by hand, on purpose: the mode is a break, and it must not move the
  leaderboards. `[snow] lethal = 1` is the opt-in.
* **No vote for the reindeer hunt.** `/wfsnow` was asked for; the hunt is
  admin/rotation driven. Adding `/wfdeer` is a copy of `cmdVote`.
* **No per-map spawn rows shipped.** See §5: the built-in set works anywhere,
  and shipping guessed coordinates would be worse than shipping none.
* **No `Ham_Explode`/grenade-vtable hook.** The HE grenade is identified by its
  world model because this AMXX build exposes neither.
* **The harness test lives in the harness repo** (`tests/winterfest-snow7/`),
  and it needs `winterfest_snow.amxx` + `winterfest_reindeer.amxx` in that
  profile's `plugins.ini`. Those two lines are the coordinator's to add to the
  repo `plugins.ini`.
