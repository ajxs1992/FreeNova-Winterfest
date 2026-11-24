# FreeNova Winterfest 2026 — the 14-panel feature plan

The owner's master list. Each panel is a page; the shared systems at the end are not pages.
`docs/panel/SPEC-14.md` maps each panel to its reference plate, and `docs/panel/00-CONTRACT.md`
holds the two rules all of it hangs off: **the database is authoritative** and **each page
follows its own mockup**.

## Shared systems (apply to every panel)
Global navigation and resource bar (branding, 14 nav entries, coins, GingerBread, spins,
missions counter, notifications, inbox, avatar/account menu).

Currencies: **Coins** (main), **Christmas GingerBread** (seasonal), **Spins** (wheel),
**Ornaments** (tree and collections).

Technical: one visual identity; responsive desktop and mobile; the dark purple/blue/red/
green/gold palette; animated snow; consistent icons and typography; real player data from
the CS 1.6 server; database integration (this build uses SQLite behind `query.js`, not
MySQL — see `docs/panel/RUN-PLAN.md`); ReHLDS + AMX Mod X; API between server and panels;
persistent inventories and reward history; central currency and reward management;
server-side reward validation; secure authentication; SteamID identity; admin permissions;
anti-duplication; transaction history; event configuration; seasonal reset; audit logs.

---

## 1. Dashboard — Winterfest overview
Welcome banner · Christmas-themed design · live event countdown · player level and XP ·
coins balance · GingerBread balance · spins counter · active missions counter · personal
tree showcase · tree decoration progress · recent rewards and achievements · featured
events · upcoming announcements · daily login reward · advent progress · battle pass
preview · quick access to every panel · latest server activity · seasonal leaderboard
preview.

## 2. Battle Pass — Christmas reward tracks
30 levels · free and premium tracks · horizontal progression · current level · XP bar ·
XP to next level · free and premium reward previews · claimable and locked indicators ·
weapon skins · player models · badges and frames · coins · GingerBread · spins · XP
boosters · premium purchase · mission integration · weekly challenges · season countdown ·
complete collection · premium-exclusive rewards.

## 3. Missions — Christmas quests
Daily · weekly · event · seasonal · completed · categories and filters · descriptions ·
progress bars · completion indicators · coins · GingerBread · XP · spins · cosmetics ·
daily and weekly reset countdowns · streaks · daily chests · claim · history · statistics ·
admin-configurable.

## 4. Achievements — seasonal medals
120 seasonal achievements · gameplay / event / collection / progression / special ·
categories and filters · earned, locked, in-progress · descriptions · progress bars ·
rarity · bronze, silver, gold, legendary medals · icons · coins / GingerBread / XP ·
titles · profile badges · tracking · completion notifications · secret achievements ·
complete-collection reward · "Winterfest Legend" medal.

## 5. Events — Christmas event calendar
Main event overview · active, upcoming, completed · countdowns · December calendar ·
descriptions · participation statistics · progress tracking · exclusive rewards · event
leaderboards · history · announcements · registration · live status · event-specific
missions.

Featured events: Grinch Boss Fight · Protect Santa · The Great Gift Hunt · Snowball Fight ·
Santa's Delivery · Elf vs Grinch · Christmas Roulette · Midnight Christmas · Reindeer Hunt ·
12 Days of Christmas.

## 6. Profile — Christmas player profile
Avatar · nickname · SteamID · level · XP progression · profile frame · seasonal badges ·
titles · VIP indicator · tree showcase and progress · collected ornaments · rare ornament
showcase · weapon collection · unlocked models · seasonal achievements · recent rewards ·
battle pass progression · statistics (gifts, ornaments, missions, events) · registration
info · customisation · public viewing.

## 7. Rankstats — festive player statistics
Kills · deaths · K/D · headshots and % · wins · losses · win rate · rounds · matches ·
playtime · rank · XP · level · rank history · performance charts · daily, weekly, monthly,
seasonal buckets · top weapons with kills and accuracy · map statistics · best maps ·
recent matches · kill streaks · MVP · event statistics · gifts · ornaments · battle pass
stats.

## 8. Top 15 — Christmas leaderboard
Overall Winterfest board · top 15 · highlighted top 3 · gold/silver/bronze · avatars ·
names · levels · badges · rank icons · kills · deaths · K/D · wins · playtime · XP ·
gifts · ornaments · missions · events · multiple categories · search · sort and filter ·
own position · refresh · season countdown · top-15 rewards · historical boards.

## 9. Spin Wheel — Christmas roulette
Large interactive wheel · animated spin · spins counter · spin history · randomised
rewards · weapon skins · models · coins · GingerBread · XP · battle pass levels · VIP ·
badges · frames · rare and legendary · jackpot · featured reward · possible rewards ·
result animation · claim · ways to earn spins · daily spin · admin-configurable rewards ·
configurable probabilities.

## 10. VIP — Christmas VIP membership
Overview · status · expiry countdown · VIP / VIP+ / VIP Elite · comparison · benefits ·
VIP weapon skins · models · animated frames · badges · chat prefixes · name colours ·
VIP-only events · VIP missions · reward bonuses · cosmetics · VIP shop · purchase options ·
management · reward history · activation status.

## 11. Shop — Christmas cosmetics store
Themed interface · featured products · weapon skins (AK-47, M4A1, AWP, Deagle, Glock, USP,
knives) · collections (Santa, Frozen, Candy Cane) · models (Santa, Grinch, Elf, Snowman,
Reindeer) · badges · titles · animated frames · kill effects · trails · ornaments · mystery
boxes · bundles · daily deals · discount timers · rarity · previews · descriptions ·
coins and GingerBread pricing · purchase confirmation · inventory integration · purchase
history.

## 12. Calendar Advent — 24-day Christmas village
Illustrated village · 24 houses · S-shaped snowy road · glowing windows · snow-covered
roofs · lights · trees · pine forests · reindeer · benches and fences · street lamps ·
presents along the road · falling snow · chimney smoke · glowing gifts · vertical scroll ·
revisit previous rewards · discover upcoming · interactive houses and presents ·
1–24 December daily unlocks · per-day reward · house and present opening animations ·
claim · locked future houses · missed rewards stay hidden mysteries · missed rewards are
not claimable during the event · after 24 December everything becomes visible ·
Advent Pass (proposed $1.99) unlocks previously missed rewards · exclusive badge and frame ·
Christmas Eve grand reward · reward history · **server-side date validation** · admin
configurable.

**Rule:** the Advent Pass unlocks missed rewards only **after** the 24-day event has ended.

## 13. Levels — player progression and XP
Level · XP balance · XP bar · XP to next · next-level reward preview · reward track ·
claimable and locked · coins · GingerBread · XP · badges · frames · seasonal models ·
**Santa Operative model at level 50** · **Winterfest AK-47 skin at level 75** ·
**Winterfest Elite animated frame at level 100** · XP sources (kills, round wins, match
wins, missions, playtime) · seasonal multipliers · global level leaderboard · progression
history · admin XP management.

## 14. Admin Panel — Winterfest management
Overview · event status monitoring · start and stop controls · countdown · live statistics
(active players, logins, XP earned, coins in circulation, GingerBread in circulation,
rewards claimed) · search by nickname and SteamID · account information · level and XP
management · add or remove coins and GingerBread · give rewards · ban and manage ·
management of battle pass, advent, spin, shop, VIP, missions, achievements · module
enable/disable · event configuration (start and end dates, XP multipliers, coin and
GingerBread drop rates, Advent Pass price, visibility) · reward creation, editing, import
and export · recent administrator activity · system logs · player synchronisation · XP
recalculation · event data management · reset event progress · save configuration ·
reset to defaults.

---

## Build order (owner's recommendation, and what this repo follows)
**Core first** — database, currencies, inventory, rewards, authentication, API — then the
14 panels on top of that one core, so no panel invents its own currency, reward or
progression. One ecosystem, not fourteen websites.
