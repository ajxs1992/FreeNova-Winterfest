# The playtest fix batch — seven problems, what each one really was

Written 2026-11-23 on branch `winterfest`, for the owner's seven reports from the
local Winterfest server. Every claim below has a `file:line` and a log line from
`build/wf-local/server` (the local stack on port 27016, panel on 18101).

Read this with `docs/WINTERFEST.md` §6 (the owner decisions) and
`docs/WINTERFEST-DEV.md` (the natives): nothing here changes a decision, it makes
the shipped behaviour match them.

**How the proofs were produced.** `tests/winterfest/wf_playtest_probe.sma` (a
test-only plugin, loaded only on the local tree) drives the real commands and
natives for one connected client on a timer; the plugins gained three debug
echoes (`wf_chat_debug`, `fn_chat_debug`, `fnvip_debug`) that write the exact
chat line a player receives, with the colour control bytes re-escaped as
`^1`..`^4`, so the log shows what the client was asked to render. Two operator
diagnostics came out of it: `panel_probe` (which url a player/SteamID would get,
and why not) and `hud_preview` (the rank HUD block, for a client the server
cannot draw on).

---

## 1. `/christmas` opened a menu — now it opens the panel

**Broken.** `winterfest_menu.sma:73-76` registered `/christmas` → `cmdHub`, a
console menu. There was no panel path at all.

**Changed.**
* `include/freenova_web.inc` gained `fn_open_panel(id, kind)` — the single
  MOTD-vs-menu decision for the whole stack. It maps a kind to a panel path, a
  `/m/` bridge code or a local file, builds the url from `fnweb_url` +
  `fnweb_winter_path` (never a hardcoded host), and returns false when there is
  nothing to show.
* `/christmas` (`cmdChristmas`, `winterfest_menu.sma:176`) asks it for
  `FN_PANEL_WINTER` and falls back to the hub menu. `/wintermenu` +
  `/christmasmenu` are the menu, always. `/gifts`, `/tree`, `/ornaments`,
  `/advent`, `/winterpass` map to their pages the same way; `/christmashop`
  stays a menu (there is no shop page).
* **The panel's Winterfest routes were deleted in its 2026-11 rebuild**
  (`web-panel/src/winter/` is gone; `/winter` now answers 404). So
  `fnweb_winter_path` defaults to **empty**, and every Winterfest command opens
  its menu until an operator points the cvar at a page that exists. Pointing a
  MOTD at a 404 would be a blank window with no way back.

**Proof** (local server, `panel_probe` = the same decision `fn_open_panel` makes):

```
[PANEL-PROBE] kind=winter target=path  auth=STEAM_0 lpm=unloaded url=none
[PANEL-PROBE] kind=profile target=bridge /m/profile auth=STEAM_0 lpm=unloaded url=http://192.168.1.5:18101/m/p/0.htm
[PANEL-PROBE] kind=rules target=file addons/amxmodx/configs/freenova_rules.html auth=BOT lpm=unloaded url=(local file)
```

With the old hardcoded default set (`fnweb_winter_path /winter`) the same probe
builds `http://192.168.1.5:18101/winter?steamid=0&compact=1`, and
`curl` on that url answers **404** — that is why the default is empty, not
`/winter`. The two bridge urls the probe builds answer **200** on the live panel
(`/m/p/0-0-12345.htm`, `/m/v/0-0-12345.htm`).

**Left for others.** The panel owner: when a Winterfest page exists, set
`fnweb_winter_path` (one cvar, no recompile) and every command lights up. The
`/spin` page has no kind wired into `winterfest_menu` because `/spin` belongs to
`winterfest_spin.sma` — its owner adds one `fn_open_panel(id, FN_PANEL_WINTER_SPIN)`
call; the kind is already in the enum.

---

## 2. Low performance mode did something — it now does nothing web

**Broken.** The switch existed (`freenova_prefs.sma:23`, slot
`FNPREF_LOW_PERF`, nvault `prefs#<steamid>`, default 0) and the hub row toggled
it, but the only consumer was `FNWeb_LowPerf` in the `/m/` bridge. Nothing else
asked: `fn_join`'s `/motd` (`fn_join.sma:108`), the rules page
(`freenova_panel.sma:4790`), the VIP page (`freenova_vip.sma:1382`) and the
Winterfest menu all opened HTML regardless, and the confirmation line said
"using in-game panels" while nothing changed.

**Changed.**
* `fn_open_panel()` is now the only place `FNPREF_LOW_PERF` is read. With LPM on
  it refuses before any url or file is touched, and logs
  `-> in-game menu (no url, no html)`.
* Every panel-opening call in the touched plugins goes through it: `fn_join`
  (`/motd`), `freenova_panel` (`/rules`), `freenova_hub` (`/profile`, `/top`),
  `freenova_vip` (the VIP page), `winterfest_menu` (the five Winterfest
  commands).
* `/lpm` (`freenova_hub.sma:293`) toggles it through the house chat service and
  says what changed; the hub Settings row calls the same function.
* When the panel is refused, each caller shows its own equivalent: the hub menu,
  the per-command menu, the VIP centre menu, a three-line rules summary in chat,
  the tree/pass text summary.
* `/lpm` also stopped lying to a client it can never save: the prefs layer keys
  on a stable SteamID, so a bot or a `STEAM_ID_LAN` client now gets
  "…your identity (BOT) is not one, so it cannot be saved".

**Proof** (local server):

```
[FN-CHAT] id=1 team=-2 ^4[FreeNova]^1 Low performance mode is stored per SteamID and your identity (BOT) is not one, so it cannot be saved. Steam-authenticated players get the toggle.
[FreeNova PANEL] id=1 kind=vip -> in-game menu (not a human client)
[FreeNova PANEL] id=1 kind=rules -> in-game menu (not a human client)
```

**Not provable on the local box, and why.** The local tree has bots only, and
`freenova_prefs.sma:190` refuses `BOT`/`HLTV`/`STEAM_ID_LAN`/`STEAM_ID_PENDING`
before loading a row (`freenova_vip.sma:721` does the same for tiers). So on this
box no client can have preferences at all — LPM cannot be switched, and the VIP
tier cannot be granted. Two-minute check on a Steam-authenticated server:
`/lpm` → `/christmas` (menu, chat says "saved for your SteamID"), reconnect →
`/christmas` still a menu, then `/lpm` off → `/christmas` opens the panel page
(or falls back to the menu with `target=path ... url=none`, which is item 1's
default).

---

## 3. Ground presents were "just shining lights"

**Broken.** Two causes, both real:
1. `winterfest_core.sma:299` defaulted `wf_allow_models` to **0**, so every model
   visual resolved down to its sprite; and
2. `winterfest_gifts.sma` created the prop as `info_target` for a model
   (`WfCreateProp`), a classname the engine does not render a static model on.
   The sprite path was therefore the only thing anyone ever saw.

**Changed.**
* `models/winterfest/present.mdl` (41.8 KB, docs/MODELS.md) is now the default
  look: `[visual]` points the three present rows at it and `[props]` binds
  `present_common/uncommon/rare` to those rows
  (`configs/freenova/winterfest.ini`).
* `wf_allow_models` defaults to **1** in both plugins, and the shipped model is
  precached **whenever the file is on disk** (even with the gate off), because a
  model drawn without being precached is an ERROR entity
  (`winterfest_gifts.sma:151-215`).
* A model prop is created as `func_wall`; the sprite path stays `env_sprite`
  (`winterfest_gifts.sma:780`).
* The decision is logged **per prop** by the core and **per spawn** by the
  gifts module, with the sprite fallback still named in `[visual]` for a client
  that has not downloaded the model yet.

**Proof** (local server):

```
[WF] prop 'present_common': draws model 'models/winterfest/present.mdl'
[WF] prop 'present_uncommon': draws model 'models/winterfest/present.mdl'
[WF] prop 'present_rare': draws model 'models/winterfest/present.mdl'
[WF-GIFTS] spawned 7/7 present prop(s): 7 model, 0 sprite
```

and with the gate off (`wf_allow_models 0`), the same server logs
`[WF] prop 'present_common': visual 'present_classic' -> 'sprite_glow_common'
(the configured one needs a download)` and `7 present prop(s): 0 model, 7
sprite` — the degradation, not a crash and not an invisible present. The
Winterfest scenario asserts both directions in the world (`present-world-prop`:
a `func_wall` with `models/winterfest/present.mdl` when models are on, no model
prop and the glow sprites when they are off).

**Left for others.** Shipping the `.mdl` to a server tree is a deploy step:
`game-server/cstrike/models/winterfest/` is in the repo, but neither
`scripts/wf-local.sh` nor the panel rebuild copies it, so an operator (or the
next deploy script) has to put `present.mdl`/`present.bmp` in
`cstrike/models/winterfest/`. The plugins degrade to sprites when it is missing
and say so in the log.

---

## 4. The stats HUD shows GingerBread

**Broken.** `freenova_hud.sma:212` printed `%d coins  %s` — coins and the BP
tier only. Winterfest's currency (owner decision §6.7: GingerBread, `gb`) never
appeared, so the collectable the whole season pays into was invisible in game.

**Changed.** `RefreshCache()` reads `wf_get_gingerbread(id)` behind
`LibraryExists("winterfest_core")` and the plugin's `set_native_filter` traps
`wf_*`, so a server without the core loads this plugin unchanged. The wallet line
is built into a buffer: `"%d coins  %d gb"` with the core, `"%d coins"` without —
byte-identical to before on a non-Winterfest server. GingerBread sits on the
**same line** as coins, so the block keeps its five rows, its width behaviour and
its anchor (`fn_hud_x 0.01`, `fn_hud_y 0.18`).

**Proof** (local server, `hud_preview #1` — the plugin's own formatter, because
the HUD only draws for a real client):

```
[HUD] preview id=1 text=FreeNova
Lv 0  -
XP 0 / 0
0 coins  565 gb  BP --
Member
```

`fn_hud_debug 1` logs the same block for every real draw.

---

## 5. The Battle Pass armour perk is worth something

**Broken.** (`battlepass_core.sma`, pre-batch lines)
* `1172` set the armour to `g_iArmorBonus[id]` — the *bonus*, not 100 — so a
  perk owner with +9 spawned with 9 AP and no helmet.
* `1186-1195` was an `if/else if/else` chain: at tier 14+ it gave the grenade
  and **no armour at all**, which is where a VIP's 100 AP went.
* `3983` (the paid "Full HP + Armor") ran `cs_set_user_armor(100 + bonus)`, which
  the engine clips at 100: every point above the cap was silently lost.
* `1376` clamped the *bonus* at 100, so there was nothing left to convert.

**Changed — the numbers chosen, for the doc.**
| constant | value | why |
| --- | --- | --- |
| `BP_SPAWN_ARMOR_CAP` | 100 | the engine's own cap; granted **with a helmet** |
| `BP_ARMOR_HP_DIV` | 2 | 2 armour points that cannot be used = **1 HP** |
| `BP_SPAWN_HP_CEILING` | 120 | 100 base + the 20 HP cap `RebuildPlayerState` already enforces, so the conversion can never exceed the spawn HP ceiling |
| `BP_ARMOR_BONUS_CEILING` | 200 | sanity ceiling on the bonus itself: it must be able to pass 100 or there is nothing to convert |

`BpApplySpawnArmour()` (new) owns the whole decision on every spawn (and for the
shop restore): perk → 100 AP + helmet, overflow → HP at 2 AP per 1 HP capped by
the ceiling, no perk → VIP keeps its flat 100 + helmet, everyone else 0. The
conversion is logged once per spawn at `bp_debug 1`. Non-perk players are
untouched. The live mid-round path caps at 100 without converting (a purchase is
not a spawn).

**Proof** (local server; `bp_armor_probe <player> <bonus>` runs the shipped
function for a chosen bonus, so a value above the cap is reachable today — the
real maximum isn't):

```
[BP] armour probe Ranger (1): bonus=9 -> armour=100 helmet=yes, +0 HP (ceiling 120 HP, 2 AP = 1 HP)
[BP] armour probe Ranger (1): bonus=140 -> armour=100 helmet=yes, +20 HP (ceiling 120 HP, 2 AP = 1 HP)
[BP] spawn armour id=1: bonus=9 -> 100 AP + helmet, 0 AP of overflow -> +0 HP (2 AP = 1 HP, ceiling 120)
```

(40 AP of overflow → +20 HP, exactly the chosen rate; a player already at the HP
ceiling would get +0 and the line would say so.)

**Left for others.** With today's ladder the bonus tops out around 28
(`g_iArmorByLevel` ≤ 15 + shop skill 9 + premium 4), so the conversion stays
dormant until a config or a reward pushes it past 100 — the code and the log line
are the guarantee for the day it does.

---

## 6. The VIP armory opens on every spawn

**Broken.** `freenova_vip.sma:1671` (`OnPlayerSpawn`): the armory queue sat
**after** `if (g_Tier[id] < TIER_SPAWN) return`, so a BattlePass weapon-menu
holder without VIP never reached it at all — and the queue itself only ran with
`vip_mode 2` (default was `1`, "/vmenu only"), at a fixed 0.5 s, with no answer
to the round-start weaponmenu (which displays at 0.2 s).

**Changed.**
* `vip_mode` defaults to **2** and `vip_spawn_delay` (default 0.7 s) is the new
  cvar: it runs *after* any round-start menu, so the armory is the menu the
  player sees.
* The queue runs for **every spawn**, before the VIP-tier gate, because
  `ArmoryAccess()` is "VIP+ **or** a BattlePass weapon menu".
* `Task_AutoOpenMenu` closes whatever menu is up (`VipCloseAnyMenu`: the same
  `show_menu(id, 0, "^n", 1)` + `menu_cancel` the round cleanup uses) before it
  displays the armory, so exactly one menu wins — no stacking.
* A mid-round respawn queues it again (as long as the player has not spent it
  this round, in which case the armory would only refuse).
* The chat line is **once per round** (`g_bArmoryAnnounced`), not per spawn.
* `fnvip_armory_pending(id)` is a new native so a round-start menu owner can
  skip its own display.

**Proof** (local server, two round restarts; the bots have no SteamID, so
`tier 0` here — the BattlePass weapon-menu branch of `ArmoryAccess`):

```
[VIP] armory queued id=1 in 0.6s (round 1, tier 0, menuok 1)
[VIP] armory auto-open id=1 round=1 (queued 0.6s after spawn, after any round-start menu)
[VIP-CHAT] id=1 ^3[VIP] ^1Your ^3armory^1 is open - one weapon set per round.
```

and, before the queue fix took effect at the very first spawn,
`[VIP] armory not queued id=1: mode=2 access=0 used=0 menuok=1` — the log names
the gate that refused, which is what made this findable.

**Left for others.** `weaponmenu.sma` (not this batch's file) can now call
`fnvip_armory_pending(id)` in `show_weapon_menu_to_all` and skip a player whose
armory is queued; until then the close-first behaviour in
`Task_AutoOpenMenu` guarantees the armory wins the focus anyway.

---

## 7. Chat feedback: the raw codes were the *menu* escapes

**What the owner saw.** `\d`, `\w`, `\r`, `\y` printed literally in chat — most
visibly on every reward line, because those are the lines you read all the time.

**Root cause.** Two escape alphabets, and only one of them is real:
* GoldSrc **menus** interpret `\y` (yellow) `\w` (white) `\r` (red) `\d` (dim).
  These are plain backslash sequences in the string; the *menu renderer* reads
  them, and inside `menu_additem()` / menu titles they are correct.
* **Chat** interprets `^1` (default) `^3` (team colour) `^4` (green) — as control
  bytes 0x01/0x03/0x04 (`amxmodx.inc:419-426`). In Pawn `^4` *is* 0x04; the log
  file drops control bytes, which is why a chat line looks plain in `local.log`
  unless the echo re-escapes it.
* So a `\d` in a chat string is a literal backslash the client prints. There is
  no dim/grey code in chat at all.

**Broken, with lines (pre-batch numbering):**
`winterfest_core.sma:1460` `"+%d %s  \d(balance %d)"` · `:1474`
`"ornament:^3 %s\d (%s)"` (both alphabets in one string) · `:1505`
`"a^3 %s present\d (you carry %d)"` · `:1517` `"+%d winter pass XP  \d(total %d)"`
· `:1529` `"+%d spin%s  \d(balance %d)"` · `:1550` `"+%d %s \d(no BattlePass
loaded…)"` · `:1565` `"collector title unlocked:^3 %s"` (stray `^3` before a
space). All seven are printed through `WfSay()` → `client_print_color`.
`winterfest_menu.sma:497-498`, `:503` `"%s \d(%s)\w - set …"`, `:656`
`"… of %d \d(free track)"`, `:695-696` `"Premium track: \dnot owned\w …"`.

**Mapping used everywhere** (verified against `include/freenova_chat.inc:9`,
which documents the only three supported codes, and the house prefix
`FN_CHAT_PREFIX "^4[FreeNova]^1"` in `freenova_ui.inc:201`):

| menu escape | chat code | note |
| --- | --- | --- |
| `\w` white | `^1` | default/white |
| `\y` yellow | `^3` | team-colour slot: the "gold"/emphasis code this build has |
| `\r` red | `^3` | no red body code exists (red is the *sender*: `print_team_red`) |
| `\d` dim | `^1` | no dim code exists: dropped to plain text |

**Changed.**
* All ten chat lines converted; Winterfest chat now goes through
  `WfSay()`/`WfSayFmt()` (`include/winterfest.inc:287`), so the `[WF]` prefix is
  added in exactly one place and a stray escape is visible at the call site.
* `wf_chat_debug`, `fn_chat_debug`, `fnvip_debug` echo the exact line a player
  receives, with control bytes re-escaped as `^1`..`^4`.
* `tools/lint-plugins.py` gained **rule 8 `chat-escape`**: a menu escape in
  `client_print*` / `console_print` / `WfSay*` / `fn_chat_*` / `show_hudmessage`
  text or a `show_motd` title fails the run; colour codes in HUD text and MOTD
  titles fail too. It follows one level of indirection — when the format is a
  buffer (`formatex(buf, …, "…\d…")` then `WfSay(id, buf)`), the `formatex` that
  filled it is checked. Menus are deliberately **not** policed:
  `menu_additem()`/menu titles are where `\y\w\r\d` belong.
  Self-test: `8 rules`, fixtures in `tests/lint-plugins/bad/chat_escape.sma`.

**Proof** (local server, after the fix):

```
[WF-CHAT] ^4[WF]^1 +25 GingerBread  (balance 565)
[WF-CHAT] ^4[WF]^1 a ^3Uncommon^1 present (you carry 1)
[WF-CHAT] ^4[WF]^1 +25 winter pass XP  (total 468)
[WF-CHAT] ^4[WF]^1 +1 spin  (balance 2)
[FN-CHAT] id=1 team=-2 ^4[FreeNova]^1 Low performance mode is stored per SteamID and your identity (BOT) is not one, so it cannot be saved. Steam-authenticated players get the toggle.
[VIP-CHAT] id=1 ^3[VIP] ^1Your ^3armory^1 is open - one weapon set per round.
```

Clean text, one prefix, palette `^1/^3/^4`, no escaping leaking through.

**Left for others (reported, not edited — other owners' files).**
* `winterfest_progress.sma:2279` `\d`, `:2384` `\r`, `:2396` `\d` — live
  `client_print_color` escapes; acknowledged in the lint allow-list with the
  reason so the rule stays armed.
* `freenova_calladmin.sma:155` and `:277` — `\y` in `client_print_color`
  (plus `:278` `\w`); same treatment.
* `winterfest_spin.sma` — the two escapes in that file are inside menus, which is
  correct; nothing to change. If its owner adds a chat line, rule 8 will catch it.
* `winterfest_mail.sma` has no `show_motd`/`FNWeb_`/`client_print` path at all
  (verified), so item 2's "mail list" line in the brief has nothing to gate today;
  when a mail page exists it must call `fn_open_panel(id, …)` like the rest.

---

## 8. Harness state after the batch

| check | result |
| --- | --- |
| `bash tools/compile-plugins.sh` | **155 sources, 0 failed** |
| `python3 tools/lint-plugins.py` | **155 files, 8 rules, 0 errors, 43 acknowledged** |
| `python3 tools/lint-plugins.py --self-test` | `self-test OK (8 rules, acknowledge path, clean path)` |
| Winterfest scenario (`wf_scenario.sma`, local server) | **27 pass, 0 fail** |
| `python3 -m unittest discover -s tests/winterfest` | **101 tests, OK** |
| `cd web-panel && node test_harness.mjs` | **283 checks, all PASS** (the rebuilt panel's own suite; the 556-check suite this batch started with no longer exists) |

## 9. What is still open, and who owns it

1. **Panel pages.** The Winterfest routes are gone from the rebuilt panel; the
   game side is wired and waiting on `fnweb_winter_path`. The panel owner decides
   the page and the path.
2. **`winterfest_progress` / `freenova_calladmin` chat escapes** — five lines,
   listed in §7, acknowledged in the lint allow-list.
3. **`weaponmenu.sma`** can consume `fnvip_armory_pending()` to skip its own
   menu for a player whose armory is queued.
4. **Model deployment**: `cstrike/models/winterfest/present.mdl` must reach the
   server tree (`scripts/wf-local.sh` and the deploy path do not copy it today).
5. **Identity-gated proofs** (item 2's toggle, item 5's real perk, VIP tiers):
   they need a Steam-authenticated client. The local box has bots only, and
   `freenova_prefs`/`freenova_vip` refuse `BOT`/`STEAM_ID_LAN` by design — worth
   a decision for LAN servers, where *no* client can have preferences today.
