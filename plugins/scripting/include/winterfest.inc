// include/winterfest.inc
//
// Winterfest: the shared vocabulary of the module. Constants, the natives that
// winterfest_core registers, and the three stocks every Winterfest file needs
// (an ini field splitter, a comma-list test, and one chat line).
//
// Every consumer INCLUDES this, none of them link against each other
// statically: the natives are resolved at load time, and a module that finds
// them missing pauses itself instead of failing to load (gifts/menu call
// set_native_filter() for that reason - see winterfest_gifts.sma).
//
// Design notes, the nvault schema and the ini format live in
// docs/WINTERFEST-DEV.md. The product contract is docs/WINTERFEST.md.

#if defined _winterfest_included
	#endinput
#endif

#define _winterfest_included

// ---------------------------------------------------------------------------
// Reward kinds
// ---------------------------------------------------------------------------
// One enum for every payoff in the module. WF_Grant() takes one of these plus a
// reward id, exactly like the BattlePass ledgers.
//
//   WF_REWARD_GINGERBREAD reward_id = how much GingerBread (the soft currency,
//                                     id `gb`; owner naming, 2026-11-22)
//   WF_REWARD_ORNAMENT    reward_id = ornament id (1..wf_ornament_total())
//   WF_REWARD_GIFT        reward_id = rarity index (0..WF_RARITY_MAX-1)
//   WF_REWARD_PASS_XP     reward_id = how much Winter Pass XP
//   WF_REWARD_TITLE       reward_id = ornament-set id (1..wf_set_count())
//   WF_REWARD_SPINS       reward_id = how many spins (the wheel's currency)
//   WF_REWARD_COINS       reward_id = how many Coins, paid through BattlePass
//                                     (menabp_add_coins_once); with no BattlePass
//                                     it pays GingerBread instead and says so
#define WF_REWARD_NONE        0
#define WF_REWARD_GINGERBREAD 1
#define WF_REWARD_ORNAMENT    2
#define WF_REWARD_GIFT        3
#define WF_REWARD_PASS_XP     4
#define WF_REWARD_TITLE       5
#define WF_REWARD_SPINS       6
#define WF_REWARD_COINS       7

// Deprecated alias, kept for one season: the currency was originally called
// "snowflakes" in the code, the ini (`snow`), the vault key (`wf_snow_...`) and
// a few call sites. The canonical name is GingerBread; the old one still
// resolves, and the old vault key is read as a fallback (see WfLoad).
#define WF_REWARD_SNOWFLAKES  WF_REWARD_GINGERBREAD
#define WF_CURRENCY_ID        "gb"
#define WF_CURRENCY_NAME      "GingerBread"

// WF_Grant() / wf_advent_claim() results.
#define WF_GRANT_OK           1   // applied now
#define WF_GRANT_DUPLICATE    0   // claim key already spent: paid once, refused now
#define WF_GRANT_INVALID     -1   // bad id, bad reward, or the season is closed
#define WF_GRANT_NOTLOADED   -2   // the player's vault data is not in memory yet

// wf_open_gift() results.
#define WF_OPEN_OK            1
#define WF_OPEN_NOTHING       0   // nothing carried, or this instance was opened
#define WF_OPEN_INVALID      -1

// ---------------------------------------------------------------------------
// Advent: a strict one-day window (owner decision §6.3, final - the half-value
// catch-up is withdrawn). Day n unlocks on its date, is claimable THAT DAY ONLY
// in Europe/Paris, and afterwards it is expired, not discounted.
// ---------------------------------------------------------------------------
#define WF_ADVENT_LOCKED   0   // not its day yet
#define WF_ADVENT_TODAY    1   // claimable now, because today is its day
#define WF_ADVENT_EXPIRED  2   // its day has passed and it was not claimed
#define WF_ADVENT_CLAIMED  3   // claimed already
#define WF_ADVENT_UNLOCKED 4   // claimable now because the player owns the Advent Pass
#define WF_ADVENT_INVALID -1   // no such day / the calendar is shut

// wf_advent_claim() results. It answers with the same truth wf_advent_state()
// reports, so a caller never has to guess why a claim was refused.
#define WF_ADVENT_CLAIM_OK        1
#define WF_ADVENT_CLAIM_CLAIMED   0
#define WF_ADVENT_CLAIM_EXPIRED  -1
#define WF_ADVENT_CLAIM_LOCKED   -2
#define WF_ADVENT_CLAIM_INVALID  -3

// ---------------------------------------------------------------------------
// Entitlements (owner decision §6.5/§7): the only thing gameplay reads when it
// asks "does this player own the premium track / the Advent Pass?". Product ids
// are strings and live in winterfest.ini [entitlement], so the game and the
// panel cannot disagree about what is on sale.
// ---------------------------------------------------------------------------
#define WF_PRODUCT_BP_PREMIUM   "bp_premium_2026"
#define WF_PRODUCT_ADVENT_PASS  "advent_pass_2026"

// wf_has_entitlement() / wf_grant_entitlement() results.
#define WF_ENT_NO       0
#define WF_ENT_YES      1
#define WF_ENT_UNKNOWN -1   // product id not in the catalogue (the call is refused)

// ---------------------------------------------------------------------------
// Limits. These are the sizes of the fixed arrays in winterfest_core.sma and
// the caps enforced while the ini is parsed: a config row beyond a cap is
// refused with a log line, never silently dropped.
// ---------------------------------------------------------------------------
#define WF_RARITY_MAX     3    // common / uncommon / rare (the ini may define fewer)
#define WF_MAX_ORNAMENTS  64
#define WF_MAX_SETS       8
#define WF_MAX_ADVENT     31
#define WF_MAX_TIERS      30
#define WF_MAX_GIFTS      16   // presents a player may carry at once
#define WF_MAX_POOL       8    // reward-pool rows per rarity
#define WF_TREE_SLOTS     24   // fixed grid, owner decision 2026-11-22 §6.1
#define WF_MAX_STYLES     3    // classic / tall / wide
#define WF_MAX_SPOTS      16   // present spots per map
#define WF_MAX_POUCHES    8    // snowflake pouches alive at once

// The present-count rule (owner decision §6.4): 6-10 spots per map, 8 when the
// map has no rows of its own. It lives here so the log line, the fallback set
// and the tests all quote one number instead of three copies.
#define WF_SPOTS_MIN      6
#define WF_SPOTS_MAX      10
#define WF_SPOTS_DEFAULT  8

// ---------------------------------------------------------------------------
// Visuals (owner hand-over 2026-11-22: thirdparty/winterfest-assets/README.md)
// ---------------------------------------------------------------------------
// A prop's look is DATA: winterfest.ini [visual] names a visual id, [props] says
// which id each prop uses. Phase 1 resolves every model id to its stock-sprite
// fallback (no client asset), so switching a present to models/present1.mdl is a
// config edit once downloads work - no code change, no hardcoded sprite.
//
// Kinds: "sprite_glow" (a stock sprite, usable today) and "model_present" (a
// client model, only usable when wf_allow_models is 1 and the file is on disk).
// Every native below takes the visual NAME, and the name a prop currently
// resolves to is what a caller should ask for - so a caller never has to know
// whether this season ships sprites or models.
#define WF_MAX_VISUALS    16
#define WF_PROP_SLOTS     6    // present_common, present_uncommon, present_rare,
                               // pouch, tree, c4

#define WF_VISUAL_SPRITE  0
#define WF_VISUAL_MODEL   1

// Slot names accepted by wf_visual_id(). Kept in the include so every module
// spells them the same way.
#define WF_PROP_PRESENT_COMMON   "present_common"
#define WF_PROP_PRESENT_UNCOMMON "present_uncommon"
#define WF_PROP_PRESENT_RARE     "present_rare"
#define WF_PROP_POUCH            "pouch"
#define WF_PROP_TREE             "tree"
#define WF_PROP_C4               "c4"

// ---------------------------------------------------------------------------
// Natives registered by winterfest_core.amxx (register_library("winterfest_core"))
// ---------------------------------------------------------------------------
// Season state. wf_season_open() is the single gate every module asks before it
// does anything player-visible: false means "outside the date window, disabled
// by cvar, or no ini" and all of Winterfest is dormant.
native bool:wf_season_open();
native wf_season_name(output[], len);
native wf_season_window(output[], len);       // "2026-12-01 .. 2026-12-31"

// Currency and the one grant path.
// Canonical names (owner naming, 2026-11-22): GingerBread, id `gb`.
// wf_get_snowflakes / wf_add_snowflakes are DEPRECATED aliases of the two
// GingerBread natives - they work, they are documented, and they should be gone
// next season. The vault key moved from `wf_snow_*` to `wf_gb_*` with a read
// fallback, so an existing player's balance survives the rename.
native wf_get_gingerbread(id);
native wf_add_gingerbread(id, amount);        // operator/direct add, no ledger
native wf_get_snowflakes(id);                 // deprecated alias of wf_get_gingerbread
native wf_add_snowflakes(id, amount);         // deprecated alias of wf_add_gingerbread
native wf_grant(id, reward_type, reward_id, const claim_key[]);

// Spins: a second counter (owner decision 2026-11-22). The wheel and the prize
// table belong to workstream 13 - this module only owns the state: a balance,
// one idempotent free spin per player per day (granted at connect, claim key
// season+date+authid), and a consume that refuses at zero.
native wf_get_spins(id);
native wf_add_spins(id, amount);
native wf_consume_spin(id);                   // 1 = consumed, 0 = nothing left

// The envelope hook (workstream 15): a reserved per-player counter the inbox can
// use for "you have something pending". The core round-trips the value in the
// vault and exposes it read-only; the envelope owns writing it (through the
// panel/actions channel), so nothing here has behaviour of its own.
native wf_get_pending(id);

// Ornaments and the tree.
native wf_grant_ornament(id, ornament_id);    // 1 = granted now, 0 = already owned
native wf_has_ornament(id, ornament_id);
native wf_ornament_count(id);
native wf_ornament_total();
native wf_ornament_name(ornament_id, output[], len);
native wf_ornament_rarity(ornament_id);
native wf_ornament_set(ornament_id);          // set id this ornament counts for, 0 = none
native wf_tree_level(id);

// The tree grid: style + slot -> ornament, 24 slots (owner decision §6.1).
// Storage only - the drag UI is the panel's job (Phase 2), and nothing in game
// writes a slot yet. An ornament sits in at most one slot.
native wf_tree_style(id);
native wf_tree_set_style(id, style);                    // WF_GRANT_OK / WF_GRANT_INVALID
native wf_tree_slot(id, slot);                          // ornament id at 1..24, 0 = empty
native wf_tree_set_slot(id, slot, ornament_id);         // 0 as ornament_id clears the slot
native wf_tree_filled(id);                              // how many of the 24 are filled
native wf_tree_slots();                                 // WF_TREE_SLOTS
native wf_tree_next_set(id);                            // closest incomplete set, 0 = none
native wf_tree_style_count();
native wf_tree_style_name(style, output[], len);
native wf_tree_slot_x(style, slot);                     // 0..100, for the panel grid
native wf_tree_slot_y(style, slot);                     // 0..100

// Ornament sets = the "secret collections" (5 snowflakes -> a title).
native wf_set_count();
native wf_set_name(set_id, output[], len);
native wf_set_title(set_id, output[], len);
native wf_set_owned(id, set_id);
native wf_set_total(set_id);

// Winter Pass (free track only in Phase 1).
// wf_get_pass_xp / wf_get_pass_tier are the canonical names (owner decision
// 2026-11-22, workstream 14's Levels page); wf_pass_xp / wf_pass_tier are the
// originals, kept as aliases for one season. The whole threshold table is
// readable without a new native: iterate t = 1..wf_pass_max_tier() and call
// wf_pass_tier_xp(t) / wf_pass_tier_reward(t, out, len).
native wf_get_pass_xp(id);
native wf_get_pass_tier(id);
native wf_pass_xp(id);                        // alias of wf_get_pass_xp
native wf_pass_tier(id);                      // alias of wf_get_pass_tier
native wf_pass_next_xp(id);                   // cumulative XP of the next tier
native wf_pass_max_tier();
native wf_pass_tier_xp(tier);                 // cumulative XP that opens `tier`
native wf_pass_tier_reward(tier, output[], len);          // the free track's reward text
native wf_pass_tier_reward_premium(tier, output[], len);  // the premium track's reward text
// Claim a tier explicitly. The free track pays itself on tier-up; this is for
// the premium track (which needs the entitlement) and for a panel that wants to
// (re)try a claim. Keys are `pass:<tier>:free` and `pass:<tier>:premium`, so the
// two tracks can never collide. Returns WF_GRANT_OK / _DUPLICATE / _INVALID.
native wf_claim_pass_tier(id, tier, bool:premium);
native wf_pass_premium_unlocked(id);          // 1 when the player owns the premium product

// Advent calendar. A day is claimable on its own Europe/Paris date only, unless
// the player owns the Advent Pass - then every day is claimable at once. The
// claim keys are `advent#<day>` either way, so nothing can pay twice.
native wf_advent_today();                     // day of month, 0 when the season is shut
native wf_advent_state(id, day);              // WF_ADVENT_LOCKED / _TODAY / _EXPIRED / _CLAIMED / _UNLOCKED
native wf_advent_claim(id, day);              // WF_ADVENT_CLAIM_* (never pays twice)
native wf_advent_claimed(id, day);

// Entitlements: what the player OWNS (premium track, Advent Pass). Gameplay reads
// these; nothing here is a gameplay grant and nothing here charges anything.
native wf_has_entitlement(id, const product[]);                          // WF_ENT_YES / WF_ENT_NO / WF_ENT_UNKNOWN
native wf_grant_entitlement(id, const product[], const source[], const claim_key[]);  // WF_GRANT_OK / _DUPLICATE / _INVALID
native wf_entitlement_count();                                           // products in the [entitlement] catalogue
native wf_entitlement_name(index, output[], len);                        // product id by 0-based index
native wf_entitlement_label(index, output[], len);                       // its display name

// Presents (gift instances: each one is opened exactly once).
native wf_gift_count(id);
native wf_gift_instance(id, index);           // instance id at 0-based index, 0 = none
native wf_gift_rarity(id, instance);
native wf_open_gift(id, instance);            // pays the reward through the ledger

// Names for menus.
native wf_rarity_name(rarity, output[], len);

// Visuals. `slot` is one of WF_PROP_* ("present_common", "pouch", "tree", "c4");
// wf_visual_id() returns the visual NAME that slot currently resolves to (the
// sprite fallback while models are gated), and the rest describe that visual.
native wf_visual_id(const slot[], output[], len);
native wf_visual_is_model(const visual[]);                 // 1 = a download is required
native wf_visual_asset(const visual[], output[], len);      // "sprites/glow01.spr"
native wf_visual_colour(const visual[], output[], len);     // "R G B", sprites only
native Float:wf_visual_scale(const visual[]);
native wf_visual_count();                                  // [visual] rows configured

// Registered by winterfest_gifts.amxx (register_library("winterfest_gifts")),
// not by the core: the menu reaches the opening theatre through this, and falls
// back to wf_open_gift when the gifts module is not loaded.
native wf_gifts_open(id, instance);

// ---------------------------------------------------------------------------
// Stocks
// ---------------------------------------------------------------------------
// One chat line. The format is a literal here and the text is a %s argument, so
// a player name containing '%' can never become a format string (lint rule 4).
stock WfSay(id, const text[])
{
	client_print_color(id, print_team_default, "^4[WF]^1 %s", text)
	WfChatDebug(text)
}

// Formatted variant: the literal is the call site, so the lint rule
// (tools/lint-plugins.py rule `chat-escape`) can see it, and the [WF] prefix is
// added in exactly one place instead of being retyped in every line.
stock WfSayFmt(id, const fmt[], any:...)
{
	new text[192]
	vformat(text, charsmax(text), fmt, 3)
	client_print_color(id, print_team_default, "^4[WF]^1 %s", text)
	WfChatDebug(text)
}

// wf_chat_debug 1 writes every Winterfest chat line to the server log, with its
// colour codes, so "what did the player actually get?" is a log question instead
// of a recompile. Off by default: a normal boot says nothing.
//
// The colours are CONTROL BYTES (^4 is 0x04 in Pawn - the client's chat renderer
// reads 0x01..0x04, and a log file drops them), so they are re-escaped here as
// the readable "^4" form. That is also what makes a stray "\d" (a literal
// backslash the client prints as-is) obvious in the log.
stock WfChatDebug(const text[])
{
	if (!get_cvar_num("wf_chat_debug"))
		return
	new szShow[256], j
	copy(szShow, charsmax(szShow), "^^4[WF]^^1 ")
	j = strlen(szShow)
	for (new i = 0; text[i] && j < charsmax(szShow) - 2; i++)
	{
		if (text[i] >= 1 && text[i] <= 4)
		{
			szShow[j++] = 94   // '^' is the Pawn escape character, so its code
			szShow[j++] = '0' + text[i]
		}
		else if (text[i] == 94)
		{
			szShow[j++] = 94   // '^' is the Pawn escape character, so its code
			szShow[j++] = 94   // '^' is the Pawn escape character, so its code
		}
		else
			szShow[j++] = text[i]
	}
	szShow[j] = 0
	log_amx("[WF-CHAT] %s", szShow)
}

// Field `index` (0-based) of a "a | b | c" ini row. Returns false when the row
// has fewer fields. The result is trimmed; a missing field yields "".
stock bool:WfField(const line[], index, output[], len)
{
	new n = strlen(line)
	new start = 0, cur = 0
	output[0] = 0
	for (new i = 0; i <= n; i++)
	{
		if (i < n && line[i] != '|')
			continue
		if (cur == index)
		{
			new c = i - start
			if (c < 0) c = 0
			if (c > len - 1) c = len - 1
			for (new k = 0; k < c; k++)
				output[k] = line[start + k]
			output[c] = 0
			trim(output)
			return true
		}
		cur++
		start = i + 1
	}
	return false
}

// Field `index` as an integer, with a fallback when the field is absent or not a
// number. Empty -> fallback, so an ini row may leave trailing fields out.
stock WfFieldInt(const line[], index, fallback)
{
	new buf[24]
	if (!WfField(line, index, buf, charsmax(buf)) || !buf[0])
		return fallback
	new v = str_to_num(buf)
	// str_to_num("abc") is 0, which is also a legal value, so accept it and let
	// the caller range-check.
	return v
}

// Does a comma list ("1,4,7") contain `value`? Bounded by the string, so a
// corrupted value cannot spin.
stock bool:WfListHas(const list[], value)
{
	new buf[16], len = strlen(list), start = 0, i = 0
	if (!list[0] || value <= 0)
		return false
	for (i = 0; i <= len; i++)
	{
		if (i < len && list[i] != ',')
			continue
		new c = i - start
		if (c > 0 && c < charsmax(buf))
		{
			for (new k = 0; k < c; k++)
				buf[k] = list[start + k]
			buf[c] = 0
			if (str_to_num(buf) == value)
				return true
		}
		start = i + 1
	}
	return false
}

// Digits in a number, used to size a list append before writing it.
stock WfNumLen(value)
{
	new buf[16]
	num_to_str(value, buf, charsmax(buf))
	return strlen(buf)
}

// Append `value` to a comma list. Returns false when it would not fit, so a
// caller can log instead of writing a truncated key.
stock bool:WfListAdd(list[], len, value)
{
	new buf[16]
	if (value <= 0)
		return false
	if (!list[0])
	{
		formatex(list, len, "%d", value)
		return true
	}
	new need = strlen(list) + 1 + WfNumLen(value)
	if (need >= len)
		return false
	formatex(buf, charsmax(buf), ",%d", value)
	add(list, len, buf)
	return true
}

// Count the entries of a comma list (0 for an empty string).
stock WfListCount(const list[])
{
	new n = 0, len = strlen(list)
	if (!list[0])
		return 0
	for (new i = 0; i < len; i++)
		if (list[i] == ',')
			n++
	return n + 1
}
