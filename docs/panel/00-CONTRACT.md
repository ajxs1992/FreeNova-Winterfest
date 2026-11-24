# Panel rebuild — the contract (owner decisions 2026-11-22)

1. **Each of the 14 pages follows its own mockup.** No shared page template. Shared
   code is limited to data access, formatting and the action protocol — never layout.
   The mockups are `docs/design/refs/winterfest/*.png`, one per page.
2. **The database is authoritative.** Player state lives in the panel DB and is the
   truth. The game server *reconciles* to it. A panel action writes the DB; the game
   applies the resulting change on its next pull and reports back.

## Layers, and who owns what
```
panel page (14 layouts)            reads →  query layer (read-only)
panel action (POST, no JS)         writes → wf_actions  (never a state table directly)
applyAction()                      writes → state tables + wf_ledger, in one transaction
game pull (AMXX)                   GET /api/game/pending   → applies, then POSTs result
game push (existing ingest)        POST /api/ingest (HMAC) → reconciled snapshot
```

## Tables
| table | role |
| --- | --- |
| `players` | identity + coins + level/xp (existing) |
| `winter_players` | gingerbread (`snowflakes`), spins, tree level, pass xp/tier, flags |
| `winter_inventory` | owned cosmetics/ornaments, one row per item |
| `winter_entitlements` | products a player owns: `bp_premium_2026`, `advent_pass_2026` |
| `winter_actions` | **the queue**: panel → game, one row per intent |
| `winter_ledger` | **append-only**: every currency change with `reason` and `ref` |
| `winter_mail` | inbox rows |

## Rules
- **No page ever UPDATEs a state table.** It inserts a `winter_actions` row; the
  apply step does the write and the ledger entry in the same transaction.
- **Every currency change writes a ledger row** with `balance_after`. If the ledger
  and the balance disagree, the ledger wins and the balance is rebuilt.
- **Idempotent**: `winter_actions.idem` is unique per `(steamid, kind, ref)`. A
  retried claim pays once. The game applying an action twice is harmless.
- **Nothing is invented**: a page renders a value, or "not collected yet". A zero
  that means "unknown" is a bug.
- **Honest sync**: the panel shows when the DB last heard from the game
  (`players.updated_at`), and never claims a live game state it does not have.

## Actions (the queue)
```
winter_actions(id, steamid, kind, payload, state, idem, created_at, applied_at, error)
   kind: claim_mission | claim_advent | plant_ornament | buy | equip | grant
   state: pending → applied | refused
```
The game pulls `pending` where `steamid = <player>`, applies, and PATCHes the row.
A page that offers an action shows it as **queued**, never as done.

## Page list and owner mockup
| route | mockup |
| --- | --- |
| `/dashboard` | `01-dashboard.png` |
| `/profile` | `02-profile.png` |
| `/rankstats` | `03-rankstats.png` |
| `/top15` | `04-top15.png` |
| `/battlepass` | `05-battlepass.png` |
| `/missions` | `06-missions.png` |
| `/achievements` | `07-achievements.png` |
| `/events` | `08-events.png` |
| `/vip` | `09-vip.png` |
| `/shop` | `10-shop.png` |
| `/advent` | `11-advent.png` |
| `/spin` | `12-spin.png` |
| `/levels` | `13-levels.png` |
| `/admin` | `14-admin.png` |
