# The game assets are not in this repo

`game-server/cstrike/` contains only what the code needs to be read and tested: the AMX Mod X
sources, the configuration and the directory layout.

Missing on purpose (binary game content, tens of GB, licensed per map):

- `maps/*.bsp` and the `.wad` texture packs
- `models/`, `sound/`, `sprites/`
- `bin/` (hlds) and the server `.so` modules

**Consequence:** the Winterfest in-game scenario harness and the per-map precache report
cannot run from this repo alone. Everything that needs only the Node runtime can — that is
the whole panel suite.

To run the game side, point a real CS 1.6 dedicated server at these files, or copy
`addons/amxmodx/{scripting,configs}` over an existing tree and build the `.amxx` files with
`tools/compile-plugins.sh`.
