# Winterfest 2026 — workstreams, owners and file boundaries

One row per module. Every agent owns its files exclusively; anything shared
(`plugins.ini`, `winterfest.ini`, `web-panel/src/index.js`, `schema.sql`) has a
single named owner. The coordinator merges, verifies and deploys — agents never
deploy.

| # | workstream | status | owns |
| --- | --- | --- | --- |
| 1 | **Core** — state, currency, inventory, tree, advent, pass XP, idempotent grants | building | `winterfest_core.sma`, `winterfest_*.inc`, `configs/freenova/winterfest.ini` |
| 2 | **Presents & opening** — world spawns, proximity pickup, open sequence | building | `winterfest_gifts.sma` |
| 3 | **Menus** — `/christmas` hub + real entries | building | `winterfest_menu.sma` |
| 4 | **Content pack** — BSP-derived present spots, ornament catalogue, advent/pass/12-days tables | building | `tools/winterfest/*.py`, `configs/freenova/winterfest/*.ini` |
| 5 | **Panel surface** — `/winter` hub, tree grid, gifts, ornaments, advent, pass, Christmas skin | building | `web-panel/src/winter*`, `schema.sql` |
| 6 | **Atmosphere & effects** — dynamic snowfall (stock sprites), snowstorm modifier, festive kill feed, Christmas bomb/fuse effects | starting | `winterfest_atmos.sma`, `winterfest_killfeed.sma` |
| 7 | **Gameplay modes** — snowball fight, frozen grenades, reindeer hunt (behind `fn_mode`) | starting | `winterfest_snow.sma`, `winterfest_reindeer.sma` |
| 8 | **Cosmetics registry** — hats (the owner's 7 .mdl), weapon skins, player models, titles, badges; disabled until the download path is proven | starting | `winterfest_cosmetics.sma`, `configs/freenova/winterfest/cosmetics.ini` |
| 9 | **Progression extras** — Christmas missions, seasonal achievements, daily login | starting | `winterfest_progress.sma`, `configs/freenova/winterfest/missions.ini` |
| 10 | **Community systems** — Secret Santa, gift-between-players, lottery, community goal | queued (needs 5) | `winterfest_social.sma`, panel tables via owner of 5 |
| 11 | **Santa's Revenge / Grinch / elf / boss fight** | queued (needs 7) | `winterfest_santa.sma`, `winterfest_grinch.sma` |
| 13 | **Spin Wheel** — daily free spin, tokens, prize table | starting | `winterfest_spin.sma`, `configs/freenova/winterfest/spin.ini`, `web-panel/src/winter/spin*` |
| 14 | **Levels page** — XP curve, per-level rewards, progress | starting | `web-panel/src/winter/levels*` |
| 15 | **Messaging (the envelope)** — inbox, announcements, admin broadcast | starting | `winterfest_mail.sma`, `web-panel/src/winter/mail*`, `winter_mail` table |
| 12 | **Admin & analytics** — event controls, reward grants, analytics | queued (needs 1+5) | `winterfest_admin.sma`, panel admin section |

## Owner decisions recorded 2026-11-22 (second round)

1. **Currency is GingerBread.** The game-side core was built as "snowflakes";
   it is renamed to **gingerbread** (id `gb`), and "snowflake" survives only as
   the ornament *set* name. The dashboard reference is authoritative.
2. **Spin Wheel ships** — a daily free spin plus bought/earned spins, with a
   prize table in config.
3. **The Levels page exists** — XP curve and per-level rewards, reachable from
   the sidebar.
4. **The envelope exists** — an in-panel inbox for system announcements and
   admin broadcasts (player-to-player mail is a later step).

## Rules every workstream follows

1. **No client asset.** Stock sprites only (`sprites/glow01.spr` and friends);
   the owner's hat models stay inert until fastdl or direct download is proven.
2. **Optional dependency.** Declare natives, use the `set_native_filter` pattern
   from `fn_servers.sma`, and pause yourself if `winterfest_core` is missing. A
   server without the core must behave exactly like today.
3. **One idempotent grant.** Every reward goes through the core's claim-key path;
   never write a reward directly.
4. **Bots excluded** from every player-facing entry point.
5. **Precache budget.** At most 2-3 stock sprites per module; the 512-item cap is
   tight and `de_museum`'s crash is the warning.
6. **Never edit another workstream's files**, including `plugins.ini` (the
   coordinator adds plugin lines), `winterfest.ini` (owner: 1), `schema.sql`
   (owner: 5).
7. **Verify locally** (compile `137/0` + lint 0 errors + a boot in the shared
   harness under `flock`), then report; the coordinator deploys.
