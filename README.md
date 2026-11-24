# FreeNova Winterfest — source only

The code and the design references for the FreeNova Winterfest web panels and the AMX Mod X
plugins behind them. **No maps, sounds, models or assets** — this is what you need to read,
understand and rebuild the thing.

```bash
git clone https://github.com/ajxs1992/FreeNova-Winterfest.git
```

## Layout

| path | what it is |
| --- | --- |
| `web-panel/src/` | the panel: router, data layer, and one module per page under `src/panel/` |
| `web-panel/schema.sql` | the database, table by table, including the action queue and the ledger |
| `web-panel/test_harness.mjs` | the test suite |
| `plugins/scripting/` | every AMX Mod X `.sma` and `.inc` — the Winterfest core, shop, cosmetics, panel bridge |
| `plugins/configs/` | the `.ini` configuration the plugins read |
| `references/plates/` | the owner's 14 panel mockups, native resolution, unmodified (`SOURCES.json` has their hashes) |
| `references/dashboard/` | the dashboard plate at full size |
| `docs/` | the contract, the 14-page spec, the master feature plan, the art rule, the Winterfest plugin docs |

## The two rules everything hangs off

1. **The database is authoritative.** A page only reads. A page action inserts a
   `winter_actions` row; `applyAction` writes the state change *and* a `winter_ledger` line in
   one transaction; the game server pulls `GET /api/game/pending` and acknowledges with
   `POST /api/game/ack`. Nothing pays out twice and every currency change has a ledger row.
2. **Each page follows its own mockup.** No shared layout template. Shared code is data
   access, formatting and the action protocol — never layout.

## Start here

- `docs/FEATURE-PLAN-14-PANELS.md` — the full feature list for all fourteen panels.
- `docs/panel/SPEC-14.md` — which mockup belongs to which page, and what each page must show.
- `docs/panel/00-CONTRACT.md` — the rules above, in full, with the table roles.
- `docs/panel/01-DATA.md` — the columns, the action vocabulary and the game API.

## Running the panel

```bash
cd web-panel
npm install
PORT=18101 node server_local.mjs     # http://127.0.0.1:18101/panel
node test_harness.mjs               # the suite
```

## Building the plugins

```bash
# needs the AMX Mod X compiler (amxxpc, 32-bit) and the Pawn includes in plugins/includes/
amxxpc plugins/scripting/winterfest_core.sma
```

## Licence

MIT — see `LICENSE`. The reference images under `references/` are the owner's own artwork and
are included so a rebuild can match them exactly.
