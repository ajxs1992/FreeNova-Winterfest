# Winterfest 2026 — the 14 panels and the shared systems (owner's master list)

Owner's words: *"make the rest of all the dashboard and implement every single feature we
talked about and make the current plugins in the christmas test server better since they
are kind of broken."* This is the checklist of record. Progress lives in
`projects/freenova-classic/STATUS.md` in the vault; this file says **what**.

## The 14 pages and their plates
| # | page | plate | route (proposed) |
| --- | --- | --- | --- |
| 1 | Dashboard | `01-dashboard.png` | `/dashboard` (plate) · `/panel` (live) |
| 2 | Battle Pass | `05-battlepass.png` | `/panel/battlepass` |
| 3 | Missions | `06-missions.png` | `/panel/missions` |
| 4 | Achievements | `07-achievements.png` | `/panel/achievements` |
| 5 | Events | `08-events.png` | `/panel/events` |
| 6 | Profile | `02-profile.png` | `/panel/profile` |
| 7 | Rankstats | `03-rankstats.png` | `/panel/rankstats` |
| 8 | Top 15 | `04-top15.png` | `/panel/top15` |
| 9 | Spin Wheel | `12-spin.png` | `/panel/spin` |
| 10 | VIP | `09-vip.png` | `/panel/vip` |
| 11 | Shop | `10-shop.png` | `/panel/shop` |
| 12 | Advent | `11-advent.png` | `/panel/advent` |
| 13 | Levels | `13-levels.png` | `/panel/levels` |
| 14 | Admin | `14-admin.png` | `/panel/admin` |

## Page contents, condensed
Anything a plate does not show and the DB does not hold is an **empty state**, never an
invention.

**1 Dashboard** — banner, live countdown, level+XP, coins, GingerBread, spins, active
missions, tree showcase + decoration progress, recent rewards, featured events, upcoming
announcements, daily login reward, advent progress, pass preview, quick access, latest
activity, leaderboard preview.

**2 Battle Pass** — 30 levels, free + premium tracks, horizontal progression, current
level, XP bar, XP to next, free/premium previews, claimable vs locked, skins/models/
badges/frames/coins/GingerBread/spins/XP boosters, premium purchase, mission integration,
weekly challenges, season countdown, full collection, premium-exclusive rewards.

**3 Missions** — daily / weekly / event / seasonal, completed, categories+filters,
descriptions, progress bars, completion indicators, coins/GingerBread/XP/spins/cosmetics,
daily+weekly reset countdowns, streaks, daily chests, claim, history, statistics,
admin-configurable.

**4 Achievements** — ~120 seasonal, gameplay/event/collection/progression/special,
categories, earned/locked/in-progress, descriptions, progress, rarity bronze→legendary,
icons, rewards (coins/GingerBread/XP/titles/badges), tracking, notifications, secret
achievements, full-collection reward, "Winterfest Legend" medal.

**5 Events** — overview, active/upcoming/completed, countdowns, December calendar,
descriptions, participation stats, progress, rewards, event leaderboards, history,
announcements, registration, live status, event missions. Featured: Grinch Boss Fight,
Protect Santa, Great Gift Hunt, Snowball Fight, Santa's Delivery, Elf vs Grinch, Christmas
Roulette, Midnight Christmas, Reindeer Hunt, 12 Days of Christmas.

**6 Profile** — avatar, name, steamid, level, XP, frame, badges, titles, VIP indicator,
tree showcase + progress, ornaments + rarest one, weapon collection, models, achievements,
recent rewards, pass progress, stats (gifts/ornaments/missions/events), registration info,
customisation, public viewing.

**7 Rankstats** — kills, deaths, K/D, headshots + %, wins, losses, win rate, rounds,
matches, playtime, rank, XP, level, rank history, performance charts, daily/weekly/
monthly/seasonal buckets, top weapons with kills and accuracy, map stats, recent matches,
kill streaks, MVP, event stats, gifts, ornaments, pass progression.

**8 Top 15** — overall board, 15 rows, top-3 podium, medals, avatars, names, levels,
badges, rank icons, kills, deaths, K/D, wins, playtime, XP, gifts, ornaments, missions,
events, multiple categories, search, sort/filter, own position, refresh, countdown,
top-15 rewards, historical boards.

**9 Spin Wheel** — big wheel, animated spin, spins counter, spin history, randomised
rewards (skins, models, coins, GingerBread, XP, pass levels, VIP, badges, frames, rare,
legendary, jackpot), featured reward, reward table, result animation, claim, ways to earn
spins, daily spin, admin-configurable rewards and probabilities.

**10 VIP** — overview, status, expiry countdown, VIP / VIP+ / Elite, comparison table,
benefits, VIP skins, models, animated frames, badges, chat prefixes, name colours,
VIP-only events, VIP missions, reward bonuses, cosmetics, VIP shop, purchase,
management, reward history, activation status.

**11 Shop** — themed interface, featured products, weapon skins by collection (Santa,
Frozen, Candy Cane) and per-weapon, models (Santa, Grinch, Elf, Snowman, Reindeer),
badges, titles, animated frames, kill effects, trails, ornaments, mystery boxes, bundles,
daily deals, discount timers, rarity, previews, descriptions, coins+GingerBread pricing,
confirmation, inventory integration, purchase history.

**12 Advent** — illustrated village, 24 houses, S-shaped road, glowing windows, snow,
lights, trees, pines, reindeer, benches, fences, lamps, presents, falling snow, chimney
smoke, glowing gifts, vertical scroll, revisit past, discover upcoming, interactive
houses, 1–24 December unlocks, per-day reward, house/present opening animations, claim,
locked future houses, missed stay mysteries **during** the event, everything visible
after 24 December, Advent Pass (~$1.99) unlocks missed rewards **only after** the event,
exclusive badge+frame, Christmas Eve grand reward, reward history, server-side date
validation in the season timezone, admin-configurable rewards.

**13 Levels** — level, XP, bar, XP to next, next-level preview, reward track, claimable vs
locked, coins/GingerBread/XP/badges/frames/models, Santa Operative at 50, Winterfest
AK-47 at 75, Elite animated frame at 100, XP sources (kills, round win, match win,
missions, playtime), seasonal multipliers, global level leaderboard, history, admin XP.

**14 Admin** — overview, event monitoring, start/stop, countdown, live stats (active
players, logins, XP, coins, GingerBread, rewards claimed), search by name/steamid,
account info, level/XP management, add/remove coins+GingerBread, give rewards, ban,
and management of BP / Advent / Spin / Shop / VIP / Missions / Achievements, module
enable/disable, event config (dates, XP multiplier, drop rates, Advent Pass price,
visibility), reward CRUD + import/export, admin activity, system logs, player sync, XP
recalculation, event data, reset progress, save config, reset config.

## Shared systems (not pages)
**Navigation + resource bar**: branding, 14 nav entries, coins, GingerBread, spins,
missions counter, notifications, inbox, avatar+account menu.

**Currencies**: Coins (main), Christmas GingerBread (seasonal), Spins (wheel), Ornaments
(tree + collections).

**Technical**: unified identity, responsive desktop+mobile, the dark purple/blue/red/
green/gold palette, animated snow, consistent icons+type, real data from the server,
MySQL, ReHLDS+AMXX, panel↔server API, persistent inventory, persistent reward history,
central currency, central rewards, server-side reward validation, secure auth, steamid
identity, admin permissions, anti-duplication, transaction history, event config,
seasonal reset, audit logs.

## How this meets the decisions already in force
- **DB authoritative** (`00-CONTRACT.md`): every claim/buy/equip is a `winter_actions` row;
  `applyAction` writes state + `winter_ledger` in one transaction; the game pulls and
  acks. That *is* the list's "central currency, central rewards, anti-duplication,
  transaction history" — satisfied once by the layer rather than 14 times by the pages.
- **Each page follows its own plate**; pictures are CSS sprites of the plate; nothing is
  generated.
- **Advent**: one-day window, missed stay hidden during the event, Advent Pass unlocks
  **after** 24 December — matches this list exactly.
- **Payments**: Stripe later; Advent Pass and premium BP are entitlement rows granted by
  an admin or the game until then.

## Open questions for the owner
1. **Timezone**: this list says Romania; the panel has used **Europe/Paris**. They differ,
   and the advent window turns on it — which one is authoritative?
2. **MySQL** is listed; the panel runs on SQLite/D1 today behind `query.js`. Keep SQLite
   (single file, backs up with the vault) or migrate?
3. **120 achievements / 30 BP levels** — are those counts fixed content, or should the
   registry ship with what exists and grow?
