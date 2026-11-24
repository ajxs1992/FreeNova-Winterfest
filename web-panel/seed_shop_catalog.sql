-- ============================================================================
-- Winterfest 2026 — the SHOP shelf (page-driven addition, docs/panel/01-DATA.md §11)
-- ============================================================================
-- What this file is: the rows `/panel/shop` renders. It is a CATALOGUE, not a
-- ledger — the panel reads it and never writes it, and no purchase touches it.
--
-- WHY IT IS SMALL AND PROVABLE
-- The shelf may only hold things the game can actually hand over. That is a
-- fact about game-server/, checked row by row, not an opinion:
--
--   ornament:N  winterfest_pull.sma WfPullGrantItem() → wf_grant_ornament(id, N),
--               refused unless N is in winterfest.ini [ornament] (1..30).
--   title:N     winterfest_pull.sma WfPullGrantItem() → wf_grant(id,
--               WF_REWARD_TITLE, N), refused unless [set] N has a collector title
--               (ornament sets 1..6).
--   product X   winterfest_pull.sma → wf_grant_entitlement(id, X, "panel", key),
--               refused unless X is in winterfest.ini [entitlement]
--               (bp_premium_2026, advent_pass_2026).
--
-- Everything else the plate's shelf draws — weapon skins, player models, frames,
-- winter badges, kill icons, chat prefixes, mystery bundles, daily deals — has
-- NO deliverable in the engine today, so it is NOT on this shelf. The page draws
-- those cards with an honest "not available yet" and names the missing piece.
-- docs/panel/pages/shop.md §4 lists them one by one.
--
-- PRICES. There is no owner price list for ornaments and collector titles, so
-- every price here is a PANEL PROPOSAL, derived from numbers the game already
-- uses, and each row's `source` says so:
--   ornament, rarity 0     120 coins            | 60 GingerBread
--   ornament, rarity 1     400 coins            | 180 GingerBread
--   ornament, rarity 2     900 coins            | 400 GingerBread
--            (rarity is winterfest.ini [ornament] column 3: 0 common, 1 uncommon,
--             2 rare — the same 0..2 scale cosmetics.ini documents.)
--   collector title        2 500 GingerBread    (a set title is a trophy: the
--            rarest thing the panel can sell, priced at the top ornament's ~6x)
--   bp_premium_2026        500 GingerBread — NOT proposed: 01-data's own example
--            price in docs/panel/01-DATA.md §3 (`{"product":"bp_premium_2026",
--            "price":{"gingerbread":500}}`), i.e. the documented shape of the
--            product buy.
--   advent_pass_2026       the plate's own figure (10 000 GingerBread,
--            10 10-shop.png) — the one price the owner drew.
-- Change a price by editing a row here; nothing in the rendering path holds one.
--
-- The seed is idempotent and NEVER overwrites: `ON CONFLICT DO NOTHING`, so a
-- price the owner edits in the DB survives every boot (the same rule the
-- catalog seed follows with its version guard).
-- ============================================================================

INSERT INTO winter_shop
  (sku, kind, item, item_kind, product, name, blurb, tier, rarity, hidden,
   price_coins, price_gingerbread, sort, active, source)
VALUES
  -- ---- the six collector titles (winterfest.ini [set], ornaments.ini merge) --
  ('title:1', 'title', 'title:1', 'title', '', 'Ice Warrior',
   'Snowflakes set — the collector title for all five snowflake ornaments.',
   'badges', 'rare', 0, 0, 2500, 10, 1, 'winterfest.ini [set] 1; price is a panel proposal'),
  ('title:2', 'title', 'title:2', 'title', '', 'Santa''s Helper',
   'Santas set — the collector title for all five Santa ornaments.',
   'badges', 'rare', 0, 0, 2500, 20, 1, 'winterfest.ini [set] 2; price is a panel proposal'),
  ('title:3', 'title', 'title:3', 'title', '', 'Grinch',
   'Grinches set — the collector title for all five Grinch ornaments.',
   'badges', 'rare', 0, 0, 2500, 30, 1, 'winterfest.ini [set] 3; price is a panel proposal'),
  ('title:4', 'title', 'title:4', 'title', '', 'Sleigh Bells',
   'Sleighs set — the collector title for all five sleigh ornaments.',
   'badges', 'rare', 0, 0, 2500, 40, 1, 'winterfest.ini [set] 4; price is a panel proposal'),
  ('title:5', 'title', 'title:5', 'title', '', 'Candy Cane Kid',
   'Bells & Candy Canes set — the collector title for all five ornaments.',
   'badges', 'rare', 0, 0, 2500, 50, 1, 'winterfest.ini [set] 5; price is a panel proposal'),
  ('title:6', 'title', 'title:6', 'title', '', 'Winterfest Legend',
   'Special set — the collector title for all five special ornaments.',
   'badges', 'rare', 0, 0, 2500, 60, 1, 'winterfest.ini [set] 6; price is a panel proposal'),

  -- ---- the 30 ornaments (winterfest.ini [ornament], ornaments.ini merge) ----
  ('ornament:1',  'ornament', 'ornament:1',  'ornament', '', 'Crystal Snowflake', 'Snowflakes set · common',  'misc', 'common',   0, 120,  60, 101, 1, 'winterfest.ini [ornament] 1; price is a panel proposal'),
  ('ornament:2',  'ornament', 'ornament:2',  'ornament', '', 'Frosted Snowflake', 'Snowflakes set · common',  'misc', 'common',   0, 120,  60, 102, 1, 'winterfest.ini [ornament] 2; price is a panel proposal'),
  ('ornament:3',  'ornament', 'ornament:3',  'ornament', '', 'Silver Snowflake',  'Snowflakes set · uncommon','misc', 'uncommon', 0, 400, 180, 103, 1, 'winterfest.ini [ornament] 3; price is a panel proposal'),
  ('ornament:4',  'ornament', 'ornament:4',  'ornament', '', 'Frozen Star',       'Snowflakes set · uncommon','misc', 'uncommon', 1, 400, 180, 104, 1, 'winterfest.ini [ornament] 4; price is a panel proposal'),
  ('ornament:5',  'ornament', 'ornament:5',  'ornament', '', 'Diamond Snowflake', 'Snowflakes set · rare',    'misc', 'rare',     1, 900, 400, 105, 1, 'winterfest.ini [ornament] 5; price is a panel proposal'),
  ('ornament:6',  'ornament', 'ornament:6',  'ornament', '', 'Jolly Santa',       'Santas set · common',      'misc', 'common',   0, 120,  60, 111, 1, 'winterfest.ini [ornament] 6; price is a panel proposal'),
  ('ornament:7',  'ornament', 'ornament:7',  'ornament', '', 'Santa''s Boot',     'Santas set · common',      'misc', 'common',   0, 120,  60, 112, 1, 'winterfest.ini [ornament] 7; price is a panel proposal'),
  ('ornament:8',  'ornament', 'ornament:8',  'ornament', '', 'Santa''s Hat',      'Santas set · uncommon',    'misc', 'uncommon', 0, 400, 180, 113, 1, 'winterfest.ini [ornament] 8; price is a panel proposal'),
  ('ornament:9',  'ornament', 'ornament:9',  'ornament', '', 'Santa''s List',     'Santas set · uncommon',    'misc', 'uncommon', 1, 400, 180, 114, 1, 'winterfest.ini [ornament] 9; price is a panel proposal'),
  ('ornament:10', 'ornament', 'ornament:10', 'ornament', '', 'Golden Santa',      'Santas set · rare',        'misc', 'rare',     1, 900, 400, 115, 1, 'winterfest.ini [ornament] 10; price is a panel proposal'),
  ('ornament:11', 'ornament', 'ornament:11', 'ornament', '', 'Grumpy Grinch',     'Grinches set · common',    'misc', 'common',   0, 120,  60, 121, 1, 'winterfest.ini [ornament] 11; price is a panel proposal'),
  ('ornament:12', 'ornament', 'ornament:12', 'ornament', '', 'Green Fur Bauble',  'Grinches set · common',    'misc', 'common',   0, 120,  60, 122, 1, 'winterfest.ini [ornament] 12; price is a panel proposal'),
  ('ornament:13', 'ornament', 'ornament:13', 'ornament', '', 'Stolen Stocking',   'Grinches set · uncommon',  'misc', 'uncommon', 1, 400, 180, 123, 1, 'winterfest.ini [ornament] 13; price is a panel proposal'),
  ('ornament:14', 'ornament', 'ornament:14', 'ornament', '', 'Grinch Heart',      'Grinches set · uncommon',  'misc', 'uncommon', 0, 400, 180, 124, 1, 'winterfest.ini [ornament] 14; price is a panel proposal'),
  ('ornament:15', 'ornament', 'ornament:15', 'ornament', '', 'Green Comet',       'Grinches set · rare',      'misc', 'rare',     1, 900, 400, 125, 1, 'winterfest.ini [ornament] 15; price is a panel proposal'),
  ('ornament:16', 'ornament', 'ornament:16', 'ornament', '', 'Tiny Sleigh',       'Sleighs set · common',     'misc', 'common',   0, 120,  60, 131, 1, 'winterfest.ini [ornament] 16; price is a panel proposal'),
  ('ornament:17', 'ornament', 'ornament:17', 'ornament', '', 'Wooden Sleigh',     'Sleighs set · common',     'misc', 'common',   0, 120,  60, 132, 1, 'winterfest.ini [ornament] 17; price is a panel proposal'),
  ('ornament:18', 'ornament', 'ornament:18', 'ornament', '', 'Reindeer Sleigh',   'Sleighs set · uncommon',   'misc', 'uncommon', 0, 400, 180, 133, 1, 'winterfest.ini [ornament] 18; price is a panel proposal'),
  ('ornament:19', 'ornament', 'ornament:19', 'ornament', '', 'Silver Sleigh',     'Sleighs set · uncommon',   'misc', 'uncommon', 1, 400, 180, 134, 1, 'winterfest.ini [ornament] 19; price is a panel proposal'),
  ('ornament:20', 'ornament', 'ornament:20', 'ornament', '', 'Golden Sleigh',     'Sleighs set · rare',       'misc', 'rare',     1, 900, 400, 135, 1, 'winterfest.ini [ornament] 20; price is a panel proposal'),
  ('ornament:21', 'ornament', 'ornament:21', 'ornament', '', 'Brass Bell',        'Bells & Candy Canes set · common',   'misc', 'common',   0, 120,  60, 141, 1, 'winterfest.ini [ornament] 21; price is a panel proposal'),
  ('ornament:22', 'ornament', 'ornament:22', 'ornament', '', 'Candy Cane',        'Bells & Candy Canes set · common',   'misc', 'common',   0, 120,  60, 142, 1, 'winterfest.ini [ornament] 22; price is a panel proposal'),
  ('ornament:23', 'ornament', 'ornament:23', 'ornament', '', 'Striped Candy Cane','Bells & Candy Canes set · uncommon', 'misc', 'uncommon', 0, 400, 180, 143, 1, 'winterfest.ini [ornament] 23; price is a panel proposal'),
  ('ornament:24', 'ornament', 'ornament:24', 'ornament', '', 'Bell Choir',        'Bells & Candy Canes set · uncommon', 'misc', 'uncommon', 1, 400, 180, 144, 1, 'winterfest.ini [ornament] 24; price is a panel proposal'),
  ('ornament:25', 'ornament', 'ornament:25', 'ornament', '', 'Peppermint Swirl',  'Bells & Candy Canes set · rare',     'misc', 'rare',     1, 900, 400, 145, 1, 'winterfest.ini [ornament] 25; price is a panel proposal'),
  ('ornament:26', 'ornament', 'ornament:26', 'ornament', '', 'Frozen Crown',      'Special set · rare',       'misc', 'rare',     1, 900, 400, 151, 1, 'winterfest.ini [ornament] 26; price is a panel proposal'),
  ('ornament:27', 'ornament', 'ornament:27', 'ornament', '', 'Snow Globe',        'Special set · uncommon',   'misc', 'uncommon', 0, 400, 180, 152, 1, 'winterfest.ini [ornament] 27; price is a panel proposal'),
  ('ornament:28', 'ornament', 'ornament:28', 'ornament', '', 'Star of the Season','Special set · rare',       'misc', 'rare',     0, 900, 400, 153, 1, 'winterfest.ini [ornament] 28; price is a panel proposal'),
  ('ornament:29', 'ornament', 'ornament:29', 'ornament', '', 'Festival Firework', 'Special set · uncommon',   'misc', 'uncommon', 0, 400, 180, 154, 1, 'winterfest.ini [ornament] 29; price is a panel proposal'),
  ('ornament:30', 'ornament', 'ornament:30', 'ornament', '', 'Winterfest Sigil',  'Special set · rare',       'misc', 'rare',     1, 900, 400, 155, 1, 'winterfest.ini [ornament] 30; price is a panel proposal'),

  -- ---- the two entitlements (winterfest.ini [entitlement]) -----------------
  ('product:bp_premium_2026', 'product', '', '', 'bp_premium_2026', 'Battle Pass Premium 2026',
   'The premium track: its rewards unlock at the same tiers, for the whole season.',
   'frames', 'rare', 0, 0, 500, 5, 1, 'winterfest.ini [entitlement]; price from docs/panel/01-DATA.md §3'),
  ('product:advent_pass_2026', 'product', '', '', 'advent_pass_2026', 'Advent Pass 2026',
   'Unlocks the missed Advent days when the calendar closes.',
   'misc', 'rare', 0, 0, 10000, 6, 1, 'winterfest.ini [entitlement]; price is the plate''s own figure (10-shop.png)')
ON CONFLICT(sku) DO NOTHING;
