# FreeNova Winterfest — progress snapshot

Exported: 2026-11-24 22:52:09 EET  ·  branch `winterfest`  ·  HEAD `63e8c89`

## What is in this folder

`source/`    the working tree exactly as it is on disk — **including every uncommitted edit in flight** at export time.
`git/`       `freenova-classic-winterfest.bundle` — the full history, every branch and tag. Restore with `git clone freenova-classic-winterfest.bundle .`
`progress/`  the documents: panel contracts and the 14-page spec, the run plan, design references, and the agent session map.

Excluded on purpose: `build/` (2.4 GB of rebuilt server trees), `node_modules`, the local SQLite database.

## Panel routes — measured from the running panel

| route | code | title | bytes |
| --- | --- | --- | --- |
| `/panel` | 200 | FreeNova · Winterfest dashboard | 23242 |
| `/panel/battlepass` | 200 | FreeNova · Winterfest battle pass | 10128 |
| `/panel/missions` | 200 | FreeNova | Missions | 39807 |
| `/panel/achievements` | 200 | FreeNova | Achievements | 39859 |
| `/panel/profile` | 200 | FreeNova · Winterfest profile | 25274 |
| `/panel/rankstats` | 200 | FreeNova · Winterfest rankstats | 15697 |
| `/panel/top15` | 200 | FreeNova · Winterfest Top 15 | 15110 |
| `/panel/spin` | 200 | FreeNova · Winterfest Spin Wheel | 12377 |
| `/panel/vip` | 200 | FreeNova | VIP | 44138 |
| `/panel/shop` | 200 | FreeNova · Winterfest Shop | 19983 |
| `/panel/advent` | 200 | FreeNova · Calendar Advent | 35879 |
| `/panel/levels` | 200 | FreeNova · Winterfest levels | 13491 |
| `/panel/admin` | 200 | FreeNova | Admin | 3457 |
| `/dashboard` | 200 | FreeNova | 3463 |
| `/` | 200 | FreeNova | Panels | 44507 |

## Gates (run at export)

```
$ bash tools/compile-plugins.sh
compiled: 155   failed: 0   allowed-failures: 0   output: /home/ajxs/projects/FreeNova-Classic-Server/tools/build/plugins
$ python3 tools/lint-plugins.py
lint-plugins: 155 files, 8 rules, 43 findings (0 error, 43 allowed)
$ cd web-panel && npm test
FAILURES: 25 (passed 344)
```

## Uncommitted work at export (in flight)

```
 M AGENTS.md
 M docs/WINTERFEST-FIXES.md
 M game-server/cstrike/addons/amxmodx/configs/freenova/winterfest/cosmetics.ini
 M game-server/cstrike/addons/amxmodx/plugins/winterfest_core.amxx
 M game-server/cstrike/addons/amxmodx/plugins/winterfest_cosmetics.amxx
 M game-server/cstrike/addons/amxmodx/plugins/winterfest_gifts.amxx
 M game-server/cstrike/addons/amxmodx/plugins/winterfest_mail.amxx
 M game-server/cstrike/addons/amxmodx/plugins/winterfest_menu.amxx
 M game-server/cstrike/addons/amxmodx/scripting/winterfest_core.sma
 M game-server/cstrike/addons/amxmodx/scripting/winterfest_cosmetics.sma
 M game-server/cstrike/addons/amxmodx/scripting/winterfest_gifts.sma
 M scripts/dev-watch.sh
 M tools/art/mksprite.py
 M tools/probes/zz_test_giftpay.sma
 M tools/probes/zz_test_matrix.sma
 M web-panel/data/freenova_panel.sq3
 M web-panel/data/freenova_panel.sq3-shm
 M web-panel/data/freenova_panel.sq3-wal
 M web-panel/schema.sql
 M web-panel/server_local.mjs
 M web-panel/src/index.js
 M web-panel/src/panel/battlepass.js
 M web-panel/src/panel/dashboard.js
 M web-panel/src/panel/kit.js
 M web-panel/src/panel/profile.js
 M web-panel/src/periods.js
 M web-panel/src/state.js
 M web-panel/src/sync.js
 M web-panel/test_harness.mjs
?? .gen/
... 170 entries
```

## Recent history

```
63e8c89 feat(panel): the Battle Pass page draws plate 05 and fills its own holes
2e6da56 fix(winterfest): a bare client number is a target, not a name substring
f298937 fix(winterfest): the load reports whether the [open] table can pay anything
8a4a31a feat(panel): the Winterfest profile page, drawn on the plate it was cut from
d515f8f fix(winterfest): a present that does not fit in the bag is paid, not destroyed
7233f43 fix(winterfest): a usable panel_probe, an honest fn_open_panel, and a test harness that stops lying
c9ff1dc fix(winterfest): draw the present model - both roots tested, cvar on, console cmd fixed
24d99b8 feat(panel): the dashboard prints its numbers on strips of its own plate
2f95d36 fix(winterfest): the present model is on disk, so draw it (repo state as of the interrupted run)
aef8fb8 docs(panel): watch duty - the controller keeps the panel alive and owns the honesty gate
bf0b655 feat(dev): keep the local panel alive beside the agents
601b7e6 docs(panel): record the owner's blanket mandate and its one hard boundary
```
