# Overnight run plan (owner sleeping, 5–6 hours, no questions)

Owner: *"work with how many agents you want continuously for the next few hours … implement
every single feature we talked about and make the current plugins … better since they are
kind of broken."*

## Decisions I took on the owner's behalf (they were open; all reversible)
1. **Timezone stays Europe/Paris.** The spec bullet says Romania; Paris is what the whole
   panel, the leaderboard periods and the advent window already use. Changing it would
   silently move every deadline. Recorded as a one-line revert if the owner disagrees.
2. **Database stays SQLite** behind `query.js`. The spec says MySQL; migrating is a
   cross-cutting risk for zero page-level benefit, and the single file backs up with the
   vault. Revisit only if there is a real multi-writer need.
3. **120 achievements / 30 pass levels are the target counts**, but the registry ships
   with what exists and grows — no empty rows to hit a number.

## Waves (each wave is gated, not just started)
**Wave 1 — parallel, non-overlapping files**
- A: pages Battle Pass, Missions, Achievements (own page files + their read helpers).
- B: pages Profile, Rankstats, Top 15.
- C: pages Spin, VIP, Shop.
- D: pages Advent, Levels, Admin.
- E: plugins — the "broken" pass: runtime errors, chat, menus, spawn logic.

**Wave 2 — integration** after 1 lands: nav + resource bar across all pages, then the
dashboard live data, then the plate switch-over (mine to make).

**Wave 3 — hardening**: full compile/lint/harness, one page-by-page walk with the browser,
and the vault STATUS updated with what is done and what is left.

## Rules every agent gets
- Own files only; never the router, the theme, `state.js`, `query.js`, another page.
- Real data via `getPlayer()`/`query.js`; honest empty states; no hard-coded sample numbers.
- Pictures are CSS sprites of the owner's plate; nothing generated.
- `node test_harness.mjs` green plus your own checks; commit early and often, by explicit
  path, on `winterfest`.

## Nights log — started 2026-11-23 ~23:40
| session | owns | status |
| --- | --- | --- |
| `s_ea6e1ebd…` | live dashboard `/panel`, one-screen scaling, real data | running |
| `s_678f66b3…` | Battle Pass, Missions, Achievements | started |
| `s_061d4bc7…` | Profile, Rankstats, Top 15 | started |
| `s_cb995aaf…` | Spin Wheel, VIP, Shop (+ queue/idempotency) | started |
| `s_b08cae01…` | Advent, Levels, Admin (+ auth gate) | started |
| `s_06947cd1…` | the game-side plugins ("broken") | started |

Sequencing rule for me (the controller): **integration after pages land** — nav + resource
bar across all pages, then the dashboard data switch-over, then a full walk with the
browser and the compile/lint/harness gates, then update the vault STATUS so the owner has
a single place to read what happened overnight.

## Owner's blanket mandate (2026-11-23, night)

> "You can do ANYTHING and I mean absolutely anything to just achieve the final goals and
> to make the plugins as best as possible."

What that unlocks, and what it still does not:
- **Unlocked**: fetching well-known open-source modules (ipwho.is style HTTP checks, nvault
  helpers already present), rewriting a plugin's internals where the current design is
  the bug, adding natives/includes, adding config sections, generating art, changing
  defaults, deleting dead code, adding DB columns, writing tests, committing per fix.
- **Not unlocked, because it is irreversible or outside this machine**: anything on the
  live Classic servers, pushing to a remote, force-pushing, deleting the vault, wiping
  `game-server/` backups, changing the timezone/DB decisions that are recorded as open.
  Those still wait for a word from the owner.
- Every "did it my own way" decision goes into the doc with a one-line revert.

## Watch duty (controller)
- **`scripts/dev-watch.sh start`** keeps the local panel alive on `:18101`. It died
  silently twice tonight; a dead panel makes every page agent read a 404 as a finished
  page, which is the worst failure mode available. Watcher pid is in `/tmp/dev-watch/`.
- **Honesty gate is mine, not theirs.** A page is done when *I* can see it: `curl` 200,
  a screenshot at the plate's size **and** 800×600, no scrollbar, and no sample numbers
  (`git grep '28,450\|999,862\|Lv. 12'`). Agents' own claims are only the start.
- **Commit per page/per fix is enforced**; anything green and uncommitted gets committed
  by me at the next sweep with a note saying so, rather than left as risk.
