# Winterfest — the Levels page and the envelope

Workstreams 14 and 15 of `docs/WINTERFEST-WORKSTREAMS.md`. Owner decisions:
`docs/WINTERFEST.md` §6.3 (the envelope ships) and §6.4 (the Levels page ships);
the drawing they live in is `docs/design/WINTERFEST-DASHBOARD.md` (a `Levels` item
under PROGRESSION, an envelope with a red dot in the top bar).

Written 2026-11-23, together with the code, so every number, route and payload
below is the shipped one rather than a plan.

---

## 1. What is on the wire

| route | method | what it is |
| --- | --- | --- |
| `/levels` | GET | the rank ladder, its per-level rewards, the player's position, a top-10 by rank XP |
| `/mail` | GET | the inbox: unread count, message list, one message with `?id=` |
| `/mail?id=` | GET | that message, if it belongs to the steamid in the URL (404 otherwise) |
| `/admin?s=mail` | GET | staff: the broadcast form and the last 20 messages (existing admin session) |
| `/admin/mail` | POST | staff: send one message to `*` or one steamid (session + CSRF) |

`/levels` and `/mail` are **GET only**. There is no POST to either — the harness
asserts `405` for both — because neither has a write in Phase 1 (see §3 and §5).

Both pages are drawn with the same chrome, built in
`web-panel/src/winter/levels.js` and reused by `mail.js`:

* a **top bar** with the player, the rung they are on, and the **envelope** —
  its red dot and count are the unread messages in `winter_mail`;
* a **sidebar** with the owner's grouping: `PROGRESSION` › Levels, Battle Pass,
  Winter Pass · `REWARDS` › Mail (unread badge) · `WINTERFEST` › hub, tree,
  gifts, ornaments, advent.

Table layout, solid hex, no flex/grid/variables/transforms: the same
IE-safe contract `src/winter/render.js` uses, so the compact MOTD skin can read
these pages too (the envelope degrades to `MAIL (2)` text there — no SVG).

**The sidebar is a real element on these two pages, not a global one.** The
dashboard in the owner's reference is a design target, not code yet; the panel's
other pages have their own tab strip (`src/winter/render.js`, `SECTIONS`). Adding
`Levels`/`Mail` there is a two-line hand-off that belongs to workstream 5 (§9).

---

## 2. The Levels page — where every number comes from

### 2.1 The curve is the plugin's own table

"Level" in this tree is the **Rank System Ultimate** ladder: the 19 rows of
`configs/rank_system_ultimate.ini [Ranks]` (Unranked … Global Elite, XP floors
0 … 30000). The game pushes that as `players.level` — `freenova_sync.sma` sends
`crxranks_get_user_level()`, which `rsu_crx_compat.sma` maps onto
`rsu_get_user_level()`. `players.rank_id` is the same number clamped by the game.

The panel already mirrors that table verbatim in `src/ranks.js` (`RANK_XP`,
"keep in lockstep", used by `/profile`'s rank crest). `/levels` **reads that
module** — one curve, one place, no formula and no second copy:

```js
import { RANKS, RANK_XP, rankName, rankProgress } from "../ranks.js"
```

The page prints the whole 19-rung table, marks the player's rung, and says where
it came from. Nothing is approximated: there is no "XP × level²" curve anywhere
in the panel, because the plugin does not have one either — RSU levels are
thresholds.

### 2.2 Per-level rewards

`configs/freenova/winterfest/levels.ini` (`[level_rewards]`, this workstream's
file) is the content. A Worker has no filesystem, so `src/winter/levels.js`
carries the same rows as `LEVEL_REWARDS`, exactly the way `src/ranks.js` carries
`[Ranks]` — and **the harness parses the ini and fails if the two drift**
(`levels: LEVEL_REWARDS is byte-for-byte levels.ini`). Changing a reward means
editing the ini and the table together; the test says so immediately.

Row format:

```
level | kind | id | amount | state | note
```

`kind` is winterfest.inc's reward vocabulary — the ids the core's **one**
idempotent grant path (`wf_grant`) understands: `gingerbread`, `ornament`, `gift`,
`pass_xp`, `title`. Then the page **cross-references it against what actually
exists in this build** (`REWARD_KINDS`):

| kind | state on the page | why |
| --- | --- | --- |
| `gingerbread` | live | `wf_grant` / `WF_REWARD_GINGERBREAD` — the currency (id `gb`) |
| `ornament` | live | `WF_REWARD_ORNAMENT` — the ornament inventory |
| `gift` | live | `WF_REWARD_GIFT` — a present of the given rarity |
| `pass_xp` | live | `WF_REWARD_PASS_XP` — the free Winter Pass |
| `title` | live | `WF_REWARD_TITLE` — an ornament-set title (id = set id) |
| `spin` | **coming** | the core keeps the counter (`wf_add_spins`) but no wheel spends it yet (workstream 13) |
| `coins` | **coming** | `players.coins` exists, but the module's idempotent grant path has no coin kind, so a level payout could not be paid once |
| `cosmetic` | **coming** | client downloads are gated on fastdl (`docs/WINTERFEST.md` §1.1) |

The rule is enforced in code, not in prose: a kind that is not implemented is
`coming` **even when the ini says `live`** (the harness checks exactly that with a
deliberately lying row), and the page prints the reason next to it. A `coming`
reward is never rendered with a claim link, a form or a button — and in Phase 1
nothing on the page is claimable at all.

### 2.3 The player's position

From the `players` row the game already pushes (`xp`, `level`, `rank_id`) via
`rankProgress()`: current level and rank name, XP into the level, XP to the next,
a percentage bar, and the next reward at the next level that has one.

A level-1 player with 0 XP renders `Level 1 of 19`, `0 / 2,816`, `0% of the way`,
`2,816 to level 2` — the harness asserts every one of those strings and that the
page contains **no `NaN`** outside the timezone enhancement script, for a
level-1 player, a mid-ladder player, an unknown steamid and no steamid at all.

`players.level` and the **Battle Pass tier are different tracks** and are labelled
as such: the page shows the BP tier as its own figure with the text "a DIFFERENT
track (`bp_xp`/`bp_tier`) — not this level". Ranking up never moves a BP tier
(REVIEW.md §2.4 H1); this page must not be the place that blurs it.

### 2.4 Leaderboard-lite

The top 10 by rank XP comes from `boards.js`'s `lifetimeBoard({ metric: "xp" })` —
**the existing helper**, the same one `/top` and `/api/public/top` use. There is
no second query path; the level column next to each row is derived from the same
`RANK_XP` floors (`levelFromXp`). Players with 0 XP are absent by definition of
that board (it selects `xp > 0`), which is stated on the page.

### 2.5 No claims in Phase 1

There is no level-reward ledger in the game, so the page is **informational**: it
says so, and it has no form and no claim link (harness-asserted). When the game
can pay a rung through `wf_grant` with a claim key of the shape `level#<level>`,
a claim route can be added; the `coming` mechanism above is already the gate for
anything that cannot be paid.

---

## 3. The envelope — the table, the scoping, the honest scope

### 3.1 The table

`schema.sql` (this workstream appended it; `IF NOT EXISTS` only, no ALTER, no
UPDATE, no DROP) and `src/winter/mail.js` repeat the same DDL lazily, so a
deployment that never execs `schema.sql` still gets the table on first use:

```sql
CREATE TABLE IF NOT EXISTS winter_mail (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    steamid     TEXT NOT NULL,                  -- recipient (one row each)
    kind        TEXT NOT NULL DEFAULT 'system', -- system | event | grant | admin
    title       TEXT NOT NULL DEFAULT '',
    body        TEXT NOT NULL DEFAULT '',
    created_at  INTEGER NOT NULL DEFAULT 0,
    read_at     INTEGER NOT NULL DEFAULT 0,     -- 0 = unread
    expires_at  INTEGER NOT NULL DEFAULT 0,     -- 0 = never; expired rows are invisible
    payload     TEXT NOT NULL DEFAULT ''        -- optional JSON (grant/event reference)
);
CREATE INDEX IF NOT EXISTS idx_winter_mail_inbox  ON winter_mail (steamid, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_winter_mail_unread ON winter_mail (steamid, read_at);
```

**One row per message per recipient.** A broadcast to "everyone" is a fan-out at
send time over the `players` table (capped at 5000, audited), which is what keeps
`read_at` per player and makes "cannot be read/marked by somebody else" a property
of the primary key's shape rather than of a query someone has to remember to
filter. The cost is stated on the admin page: a player the panel has never seen
does not receive a broadcast that was sent before their first push.

### 3.2 What the panel may write, and what it may not

The panel has no authenticated player session today — a player is identified by
the `?steamid=` in the URL the game opens, exactly like every other MOTD page.
That is a **view identity, not a login**. So:

* **`/mail` is read-only by steamid.** There is deliberately **no mark-as-read
  POST**. A token-gated version would still be a fake write: the action token
  proves "this browser was handed a page for steamid X", not "the person holding
  it is X", so anyone with the link could mark a stranger's mail read. The brief's
  §15.5 honest scope is therefore the one implemented: the panel reads by
  steamid, and the **read flag is written in game** when the player opens the
  message with `!mail`, then reported back (§4.2).
* Every read is scoped in SQL: `WHERE id=?1 AND steamid=?2`. Another player's
  message id is a **404**, not a page saying "you may not see this" (which would
  confirm the row exists). Harness-checked both ways.
* The only panel-side writes are the staff broadcast in `/admin?s=mail` (existing
  admin session + CSRF, like the events section) and the lazy DDL.

### 3.3 The bell and the envelope (the documented choice)

* The **envelope** is this inbox and the only red dot in the top bar: the dot and
  its number are the unread count from `winter_mail`.
* The **bell** in the owner's reference stays the event/announcement indicator on
  the Winterfest hub (live event windows, the season countdown) — it is **not** a
  second mailbox. When something needs to be read later it becomes a message in
  this table, so there is exactly one place a player reads anything durable.
* No player-to-player mail in this round (owner decision): staff broadcasts and
  system notices only, and the page says so.

### 3.4 The admin broadcast

`/admin?s=mail` (a `Mail` item in the admin sidebar) → form: target (`*` or one
steamid), kind, title (≤ 80), body (≤ 2000), expiry in days (empty = never),
optional JSON payload. Validation lives in `sendMail()` in `src/winter/mail.js` so
the form and any later caller get the same refusals: no angle brackets (the body
is rendered on a page), no empty title, a future expiry or none, a JSON payload
when one is given, a real steamid or `*`. Sent messages are audited
(`MAIL_SENT`) and listed with recipient/read counts.

---

## 4. The game side — `winterfest_mail.amxx`

### 4.1 What it does

* **On connect** (4 s in, when the auth id is trustworthy) it reads the player's
  cache, counts unread, logs

  ```
  [WF-MAIL] STEAM_0:0:123 unread=2 cached=5 core_pending=0
  ```

  and, for a human with something to read, prints
  `You have 2 messages - type !mail to read them.`
* `/mail`, `!mail` (and their `say_team` forms) open a menu of the **five newest
  titles**, `*` marking unread. Opening the list marks **nothing**.
* Picking one shows it (kind, sent, expires) and marks **that one** read, writing
  the vault and logging `read src=1 id=42 at=…`. Opening it again is a no-op.
* `wf_mail_send <target|@all> <system|event|grant|admin> <title…>` — `ADMIN_CFG`
  console/chat command, a broadcast straight from the server, no panel needed.
* `wf_mail_state [target|@all]` — the operator view: `unread= cached=
  core_pending= reads=` plus each entry.
* `wf_mail_clear <target|@all>` — empties the in-game cache (the panel copy is
  untouched: the panel is the mailbox of record).
* `wf_mail_test [target]` — the lab command: two demo messages, then the exact
  connect read. With no target (server console) it picks a connected client.

Storage is the module's **own** vault, `freenova_wfm`, keys `wfm_<authid>`
(12 entries of `src;id;kind;created;expires;read_at;title`) and `wfm_next` (its
own id counter). Mail is deliberately **not** season-stamped like the core's
`wf_` keys: an inbox that erases itself on 1 January loses announcements people
still refer to in February.

Idempotency is the whole point: `(src, id)` is the key, so a re-delivered panel
action **refreshes** a message instead of duplicating it, and a read is written
once. Expired entries are invisible and pruned; a full cache drops its oldest row
so the newest message always lands.

### 4.2 The dependency guard (workstream rule 2)

`plugin_natives()` installs `set_native_filter("MailNativeFilter")` (the
`fn_servers.sma` pattern, narrowed to `wf_*` names outside a trap) and
`plugin_init()` calls `pause("d")` with a log line when
`LibraryExists("winterfest_core")` is false. The only core native it reads is
`wf_get_pending()` — the counter the core reserves for the envelope — and it is
used in the log line only, never to decide whether a player has mail. A server
without the core behaves exactly like today's server.

### 4.3 Natives it exports (`include/winterfest_mail.inc`)

| native | for |
| --- | --- |
| `wfm_unread(id)` | unread, unexpired count |
| `wfm_count(id)` | every cached message, read or not |
| `wfm_deliver(id, panel_id, kind, created, expires, title[])` | one panel message in → `WF_MAIL_ADDED` / `WF_MAIL_EXISTS` / `WF_MAIL_INVALID` |
| `wfm_find(id, panel_id)` | the cache index of one panel message (`-1` when absent) |
| `wfm_reads(id, output[], len)` | `"42@1795380739,45@1795380800"` — what the player has read, for the push |

`MailShow(id, index)` is `public` so a lab plugin (or a future "open message N"
action) can drive the same read path the menu uses.

---

## 5. The exact payloads

### 5.1 Levels — nothing new is needed

The page consumes what the game **already** pushes today (`freenova_sync.sma`,
one object per player):

```json
{
  "players": [
    {
      "steamid": "STEAM_0:0:123",
      "name": "Somebody",
      "xp": 12013,
      "level": 14,
      "rank_id": 14,
      "bp_xp": 900,
      "bp_tier": 2
    }
  ]
}
```

`level`/`rank_id`/`xp` are the RSU ladder (crxranks → rsu_crx_compat →
`rsu_get_user_level()`/`rsu_get_user_xp()`), `bp_xp`/`bp_tier` are the separate
BattlePass track. No payload change is required for this page, and that is the
point: the curve and the reward table are config the panel mirrors, not data the
game has to send.

### 5.2 Mail, panel → game (delivery)

One queued action per message per recipient, in the existing `actions` channel:

```json
{ "id": 1234, "steamid": "STEAM_0:0:123", "type": "wf_mail",
  "arg": "42:3:1798761600:Christmas event tonight" }
```

`arg` = `<winter_mail.id>:<kind>:<expires_at>:<title>` where kind is
`0 system · 1 event · 2 grant · 3 admin`, `expires_at` is `0` for never, and the
title is at most 40 characters with `:` and newlines stripped (the action channel
splits on `:`).

The dispatch line belongs in `freenova_sync.sma`'s `ExecuteAction()` — the same
seam `wf_tree_move` needs, and not this workstream's file:

```pawn
if (equal(szType, "wf_mail"))
{
    new szId[12], szKind[4], szExp[16], szTitle[48]
    ParseColonParts(szArg, szId, charsmax(szId), szKind, charsmax(szKind),
                    szExp, charsmax(szExp), szTitle, charsmax(szTitle))
    new iTarget = FindPlayerByAuth(szSteamId)
    if (!iTarget)
    {
        // Offline: the panel still holds the message, so this is not a failure.
        RecordActionResult(iActId, true, "offline - kept on the panel")
        return
    }
    if (!LibraryExists("winterfest_mail", LibType_Library))
    {
        RecordActionResult(iActId, false, "winterfest_mail not loaded")
        return
    }
    new r = wfm_deliver(iTarget, str_to_num(szId), str_to_num(szKind), 0,
                        str_to_num(szExp), szTitle)
    RecordActionResult(iActId, r != WF_MAIL_INVALID, r == WF_MAIL_INVALID ? "invalid mail" : "delivered")
    return
}
```

plus `#include <winterfest_mail>` and, in `plugin_natives()`, the usual
`wf_*` native filter so a stack without the module still loads.

Nothing queues `wf_mail` yet: the natural place is the panel's push handler, for
each unread `winter_mail` row of the pushing player (a few at a time, oldest
first). That is `sync.js`, which the coordinator owns; the queue write itself is
the ordinary `queueAction()`.

### 5.3 Mail, game → panel (what was read)

Inside the existing signed push body:

```json
{
  "winter": {
    "mail_read": [
      { "steamid": "STEAM_0:0:123", "id": 42, "at": 1795380739 },
      { "steamid": "STEAM_0:0:123", "id": 45, "at": 1795380800 }
    ]
  }
}
```

`at` is the epoch second the player opened the message; `id` is the panel's
`winter_mail.id` (the game only reports **panel-origin** reads — its own
`wf_mail_send` messages have no panel row). The `wfm_reads()` native emits the
compact form of the same thing, `42@1795380739,45@1795380800`, so the sync plugin
can split it instead of rebuilding JSON.

The panel side is written and tested: `applyMailReads(env, list)` in
`src/winter/mail.js` — `UPDATE winter_mail SET read_at=?1 WHERE id=?2 AND
steamid=?3 AND read_at=0`, so a replayed push is a no-op and a read never moves
backwards. Calling it next to the winter ingest in `sync.js` is the only change
that direction needs.

---

## 6. Verification (what was actually run)

Panel — `cd web-panel && node test_harness.mjs`:

```
PASS panel test suite (555 checks)
```

93 of those are this workstream's (`levels:`, `levels page:`, `mail:`,
`mail page:`, `admin mail:`), and they cover the bar the brief set:

* **empty inbox** — `/mail` for a player with nothing: 200, "No messages yet",
  no red dot;
* **unread count** — the top-bar count and the sidebar badge both read
  `winter_mail` (`wf-count">2`, `pill">2`), and drop when a read is reported;
* **a stranger's message cannot be read by another player** — `?id=` of another
  steamid's row is a 404 that leaks neither title nor body, the inbox never
  contains it, and `applyMailReads` cannot mark it;
* **level 1, no NaN** — `/levels` for a 0-XP player renders `Level 1 of 19`,
  `0 / 2,816`, `0% of the way`, and `strip(script).includes("NaN") === false`
  (also for a mid-ladder player, an unknown steamid and no steamid);
* **`coming` is not claimable** — the spin/coin rows render
  `<span class="wf-tag coming">coming</span>`, the page has no `<form>`, no
  `<button>` and no `href` containing `claim`, and `rewardState()` forces
  `coming` for a kind the build cannot pay even when the config lies;
* plus: LEVEL_REWARDS ↔ `levels.ini` lockstep, the curve = `RANKS`/`RANK_XP`,
  inbox scoping in SQL, expiry, `sendMail()` refusals, and the whole admin path
  (login → CSRF → broadcast → fan-out → audit → the player's inbox).

`node --check` is clean on every file touched here.

Game — `bash tools/compile-plugins.sh --only winterfest_mail` → `PASS`, full tree
`compiled: 153 failed: 1` (the one failure is another workstream's in-flight
`winterfest_cosmetics.sma`, a compiler `bad_alloc`, not this file).
`python3 tools/lint-plugins.py` → `38 findings (0 error, 38 allowed)`; none of
them this file.

Local boot, in the shared harness under `flock /tmp/cs16-harness.lock`:

```
./scripts/test-plugin.sh .../tests/winterfest/wf_mail_probe.sma --profile freenova --bots 1
... RESULT ok slug=wf_mail_probe ...
```

The probe (`tests/winterfest/wf_mail_probe.sma` + `.expect` + `.commands`) drives
the real module through its natives: deliver-once / one-row-only / unread-count /
expired-hidden / index-lookup / mail-show-called / read-report /
unread-after-read / read-is-idempotent. The connect log line it asserts is the
proof the unread count is read on connect:

```
[WF-MAIL] BOT unread=0 cached=0 core_pending=0
[WF-MAIL] vault 'freenova_wfm' open - menu shows 5 titles, cache holds 12
```

Reproducing it needs the plugin line in the **harness build tree** (the repo's
`plugins.ini` is the coordinator's):

```bash
printf 'winterfest_mail.amxx\n' >> \
  build/server-freenova/cstrike/addons/amxmodx/configs/plugins.ini
```

---

## 7. Honest limits of this round

1. **No level-reward claim path.** Nothing on `/levels` pays anything; the table
   is a promise, not a ledger. `coming` is enforced in code.
2. **`/levels` needs the ornament catalogue for names.** Before the game pushes
   `catalogs.winterfest`, ornament rewards print as `Ornament #3` and the page
   says why — it never invents a name.
3. **The panel inbox is read-only.** No mark-as-read POST (§3.2), no player login.
   Read state moves in game and comes back through `winter.mail_read`.
4. **Broadcasts reach known players only.** `*` fans out over `players` at send
   time; a brand-new player needs the broadcast re-sent.
5. **Two seams are the coordinator's files**: the `wf_mail` dispatch line in
   `freenova_sync.sma` (§5.2) and the two calls from `sync.js`
   (`applyMailReads`, and queueing `wf_mail` on push). Until the first exists,
   panel-written mail does not reach the game; until both exist, in-game read
   state does not reach the panel. In-game mail via `wf_mail_send` works today.
6. **The sidebar is per page, not global** (§1). `Levels`/`Mail` in
   `src/winter/render.js`'s `SECTIONS` (and in the v2 dashboard shell) is a
   two-line hand-off to workstream 5 that this workstream may not make.
7. **Bots get the connect read, never the chat line.** The log line for a bot is
   how the harness proves the path; the message is human-only (rule 4).

---

## 8. Files

| file | workstream |
| --- | --- |
| `web-panel/src/winter/levels.js` | 14 — the page, the curve/reward logic, the shared chrome |
| `web-panel/src/winter/mail.js` | 15 — mailbox storage, the page, `applyMailReads`, the admin section |
| `configs/freenova/winterfest/levels.ini` | 14 — the reward table (lockstep with `LEVEL_REWARDS`) |
| `web-panel/schema.sql` (append) | 15 — `winter_mail` + two indexes |
| `web-panel/src/index.js` (route lines) | 14/15 — `/levels`, `/mail` |
| `web-panel/src/admin.js` (route lines) | 15 — `/admin?s=mail`, `POST /admin/mail` |
| `web-panel/test_harness.mjs` (appended) | 14/15 — 93 checks |
| `game-server/.../scripting/winterfest_mail.sma` + `.amxx` | 15 — the in-game inbox |
| `game-server/.../scripting/include/winterfest_mail.inc` | 15 — its natives |
| `tests/winterfest/wf_mail_probe.{sma,expect,commands}` | 15 — the harness probe |
| `docs/WINTERFEST-LEVELS-MAIL.md` | this file |
