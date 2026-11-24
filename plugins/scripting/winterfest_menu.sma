/*
 * ============================================================================
 * winterfest_menu — the in-game face of Winterfest
 * ============================================================================
 * Product contract: docs/WINTERFEST.md §4.2 and the owner decisions in §6.
 * Module map: docs/WINTERFEST-DEV.md.
 *
 * Commands
 *   /christmas    the Winterfest PANEL page (/winter on the panel base URL).
 *                 Falls back to the hub menu below whenever the panel cannot be
 *                 shown: no panel configured, auth still pending, or Low
 *                 Performance Mode on (see fn_open_panel in freenova_web.inc).
 *   /wintermenu   the hub menu, always. One command away from every screen, and
 *                 the automatic fallback behind /christmas.
 *   /gifts        presents you carry, and opening one from the list   (panel
 *                 page /winter/gifts first, this menu when it cannot open)
 *   /tree         style, level, how many of the 24 slots are filled, the next
 *                 milestone and where the panel page lives   (/winter/tree)
 *   /ornaments    the catalogue: owned / missing / which set it belongs to
 *                 (/winter/ornaments)
 *   /advent       the 24 calendar days, claim the one that is open
 *                 (/winter/advent)
 *   /winterpass   tier, XP, and the rewards ahead (free track only)
 *                 (/winter/pass)
 *   /christmashop says what it is: Phase 2 - a menu, because there is no page
 *   /opengift     owned by winterfest_gifts (the opening theatre). If that
 *                 module is not loaded this plugin registers a fallback so the
 *                 option is never dead.
 *
 * The menu body of each command is a plain function (GiftMenu, OrnMenu, ...) so
 * the hub menu can open the menu directly instead of bouncing the player back
 * through the panel decision a second time.
 *
 * RULES THIS FILE FOLLOWS
 *   - a brand-new player (0 GingerBread, 0 presents, 0 ornaments, no claims) sees
 *     a working hub, not an empty screen: every count is guarded and every list
 *     has an explicit "you have none yet" row;
 *   - no dead options: an entry that is not implemented yet says so in one line
 *     instead of opening an empty submenu;
 *   - bots and HLTV proxies never reach a menu (they have no client to draw on);
 *   - every wf_* native call is behind LibraryExists, and a missing core pauses
 *     this plugin instead of half-loading it.
 * ============================================================================
 */

#include <amxmodx>
#include <amxmisc>
#include <winterfest>
#include <freenova_ui>   // stocks only (menu chrome) - no runtime dependency
#include <freenova_web>  // fn_open_panel(): the MOTD-vs-menu decision, LPM included

#define PLUGIN  "Winterfest Menu"
#define VERSION "1.0.0"
#define AUTHOR  "FreeNova"

// Menu pages: 8 rows + a Next/Back row + the exit row stays inside AMXX's
// ten-item limit.
#define PAGE_SIZE 8

// ============================================================
// Lifecycle
// ============================================================
public plugin_natives()
{
	register_library("winterfest_menu")
	set_native_filter("WfMenuNativeFilter")
}

// Two optional providers, so the filter has to know which one owns which name.
// A missing native returns 0 rather than failing the load; plugin_init() then
// pauses this plugin (no core) or takes the fallback path (no gifts module).
public WfMenuNativeFilter(const name[], index, trap)
{
	if (trap)
		return PLUGIN_CONTINUE
	if (equal(name, "wf_gifts_open"))
		return LibraryExists("winterfest_gifts", LibType_Library) ? PLUGIN_CONTINUE : PLUGIN_HANDLED
	if (contain(name, "wf_") == 0 && !LibraryExists("winterfest_core", LibType_Library))
		return PLUGIN_HANDLED
	return PLUGIN_CONTINUE
}

public plugin_init()
{
	register_plugin(PLUGIN, VERSION, AUTHOR)

	register_clcmd("say /christmas", "cmdChristmas")
	register_clcmd("say_team /christmas", "cmdChristmas")
	register_clcmd("say /xmas", "cmdChristmas")
	register_clcmd("say_team /xmas", "cmdChristmas")
	register_clcmd("say /winter", "cmdChristmas")
	register_clcmd("say_team /winter", "cmdChristmas")
	// The menu itself, one command away whatever the panel does.
	register_clcmd("say /wintermenu", "cmdHub")
	register_clcmd("say_team /wintermenu", "cmdHub")
	register_clcmd("say /christmasmenu", "cmdHub")
	register_clcmd("say_team /christmasmenu", "cmdHub")
	register_clcmd("say /gifts", "cmdGifts")
	register_clcmd("say_team /gifts", "cmdGifts")
	register_clcmd("say /tree", "cmdTree")
	register_clcmd("say_team /tree", "cmdTree")
	register_clcmd("say /ornaments", "cmdOrnaments")
	register_clcmd("say_team /ornaments", "cmdOrnaments")
	register_clcmd("say /advent", "cmdAdvent")
	register_clcmd("say_team /advent", "cmdAdvent")
	register_clcmd("say /winterpass", "cmdPass")
	register_clcmd("say_team /winterpass", "cmdPass")
	register_clcmd("say /christmashop", "cmdShop")
	register_clcmd("say_team /christmashop", "cmdShop")

	// The panel page path, and the last-resort in-game link printer. Both are
	// cvars because the panel release owns where its pages live; a wrong path is
	// a config edit, not a recompile. The HOST never lives here: it is fnweb_url
	// (see fn_open_panel in freenova_web.inc).
	register_cvar("wf_panel_url", "")

	if (!LibraryExists("winterfest_core", LibType_Library))
	{
		log_amx("[WF-MENU] winterfest_core missing - pausing self (/christmas is not advertised)")
		pause("d")
		return
	}

	// Load order matters: winterfest_gifts must be in plugins.ini before this
	// plugin for the check below to see it. If it is not loaded, /opengift is
	// registered here as a fallback that still pays the reward - the theatre is
	// all that is missing, and a player must never be stuck holding a present.
	if (!LibraryExists("winterfest_gifts", LibType_Library))
	{
		register_clcmd("say /opengift", "cmdOpenFallback")
		register_clcmd("say_team /opengift", "cmdOpenFallback")
		log_amx("[WF-MENU] winterfest_gifts not loaded - /opengift falls back to the core (no opening theatre)")
	}

	server_print("[FreeNova winterfest_menu] ready (build 3, %d features)", 22)
}

// ============================================================
// Guards
// ============================================================
// One gate for every command: a bot, an HLTV proxy and a console caller have no
// menu to draw and nothing to claim.
stock bool:WfPlayer(id)
{
	if (!(1 <= id <= MaxClients))
		return false
	if (!is_user_connected(id) || is_user_bot(id) || is_user_hltv(id))
		return false
	return true
}

// Winterfest only runs inside its window. Outside it the menus still explain
// themselves (an empty "closed" hub is friendlier than silence), so the callers
// check this per entry rather than refusing the command outright.
stock bool:WfOpen()
{
	return wf_season_open() ? true : false
}

stock WfClosedLine(id)
{
	new window[48], name[48]
	wf_season_name(name, charsmax(name))
	wf_season_window(window, charsmax(window))
	WfSayFmt(id, "%s runs %s. Nothing to do until then.", name, window)
}

// ============================================================
// Entry point: the panel
// ============================================================
// /christmas opens the WINTERFEST PANEL PAGE. The menu is not gone - it is
// /wintermenu - and it is what this function does whenever fn_open_panel() says
// the panel cannot be shown (Low Performance Mode, no panel configured, auth
// still pending, loopback host, cooldown). One function decides, so the answer
// is the same for every command in this file.
public cmdChristmas(id)
{
	if (!WfPlayer(id))
		return PLUGIN_HANDLED

	if (!WfOpen())
	{
		WfClosedLine(id)
		return PLUGIN_HANDLED
	}

	if (fn_open_panel(id, FN_PANEL_WINTER))
		return PLUGIN_HANDLED

	return cmdHub(id)
}

// ============================================================
// Hub menu (/wintermenu, and the fallback behind every panel command)
// ============================================================
public cmdHub(id)
{
	if (!WfPlayer(id))
		return PLUGIN_HANDLED

	if (!WfOpen())
	{
		WfClosedLine(id)
		return PLUGIN_HANDLED
	}

	new gifts = wf_gift_count(id)
	new gb = wf_get_gingerbread(id)
	new orn = wf_ornament_count(id)
	new total = wf_ornament_total()
	new tier = wf_get_pass_tier(id)
	new today = wf_advent_today()

	new title[64]
	new name[48]
	wf_season_name(name, charsmax(name))
	formatex(title, charsmax(title), "\y%s \r| \w%d GingerBread", name, gb)

	new menu = menu_create(title, "hubHandler")
	new row[96]
	new word[24]

	WfGiftWord(gifts, word, charsmax(word))
	formatex(row, charsmax(row), "\wPresents you carry \d- %s", word)
	menu_additem(menu, row, "1")
	formatex(row, charsmax(row), "\wOpen a present \d- %s", gifts ? "unwraps one" : "none yet")
	menu_additem(menu, row, "2")
	WfStyleName(id, word, charsmax(word))
	formatex(row, charsmax(row), "\wYour tree \d- level %d, style %s", wf_tree_level(id), word)
	menu_additem(menu, row, "3")
	formatex(row, charsmax(row), "\wOrnaments \d- %d of %d collected", orn, total)
	menu_additem(menu, row, "4")
	if (today > 0)
		formatex(row, charsmax(row), "\wAdvent calendar \d- day %d is open", today)
	else
		formatex(row, charsmax(row), "\wAdvent calendar \d- closed", today)
	menu_additem(menu, row, "5")
	formatex(row, charsmax(row), "\wWinter pass \d- tier %d of %d", tier, wf_pass_max_tier())
	menu_additem(menu, row, "6")
	menu_additem(menu, "\wChristmas shop \d- opens in Phase 2", "7")
	FN_MenuFinish(menu)
	menu_display(id, menu)
	return PLUGIN_HANDLED
}

stock WfGiftWord(count, out[], len)
{
	switch (count)
	{
		case 0: copy(out, len, "none yet")
		case 1: copy(out, len, "1 present")
		default: formatex(out, len, "%d presents", count)
	}
}

// The tree style name in one call (Pawn cannot return an array, so it is an out
// parameter like every other string helper here).
stock WfStyleName(id, out[], len)
{
	wf_tree_style_name(wf_tree_style(id), out, len)
}

public hubHandler(id, menu, item)
{
	menu_destroy(menu)
	if (!WfPlayer(id))
		return PLUGIN_HANDLED
	if (item < 0)
		return PLUGIN_HANDLED

	switch (item)
	{
		case 0: GiftMenu(id)
		case 1: cmdOpenFallback(id)
		case 2: TreeSummary(id)
		case 3: OrnMenu(id, 0)
		case 4: AdventMenu(id, 0)
		case 5: PassSummary(id)
		case 6: cmdShop(id)
	}
	return PLUGIN_HANDLED
}

// ============================================================
// Presents
// ============================================================
// The command asks the panel first; the menu body is a separate function so the
// hub menu can open it without a second panel decision.
public cmdGifts(id)
{
	if (!WfPlayer(id))
		return PLUGIN_HANDLED
	if (!WfOpen())
	{
		WfClosedLine(id)
		return PLUGIN_HANDLED
	}

	if (fn_open_panel(id, FN_PANEL_WINTER_GIFTS))
		return PLUGIN_HANDLED

	return GiftMenu(id)
}

GiftMenu(id)
{
	if (!WfPlayer(id))
		return PLUGIN_HANDLED

	new count = wf_gift_count(id)
	new title[64]
	formatex(title, charsmax(title), "\yPresents you carry \r| \w%d", count)
	new menu = menu_create(title, "giftsHandler")

	if (count <= 0)
	{
		// Never an empty menu: one row that says where presents come from.
		menu_additem(menu, "\wNone yet \d- look for a glowing present in the map", "0")
	}
	else
	{
		new shown = min(count, PAGE_SIZE)
		new rar, name[24], row[96], data[12]
		for (new i = 0; i < shown; i++)
		{
			new instance = wf_gift_instance(id, i)
			rar = wf_gift_rarity(id, instance)
			wf_rarity_name(rar, name, charsmax(name))
			formatex(row, charsmax(row), "\w%s present \d- open it", name)
			formatex(data, charsmax(data), "%d", instance)
			menu_additem(menu, row, data)
		}
		if (count > shown)
			menu_additem(menu, "\w(and more) \d- /opengift opens the oldest", "0")
	}

	FN_MenuFinish(menu)
	menu_display(id, menu)
	return PLUGIN_HANDLED
}

public giftsHandler(id, menu, item)
{
	menu_destroy(menu)
	if (!WfPlayer(id))
		return PLUGIN_HANDLED
	if (item < 0)
		return PLUGIN_HANDLED

	new info[16], access, callback, name[1]
	menu_item_getinfo(menu, item, access, info, charsmax(info), name, 0, callback)
	new instance = str_to_num(info)
	if (instance <= 0)
		return PLUGIN_HANDLED

	WfOpenOne(id, instance)
	// Back to the list: the player usually has more than one present. The menu,
	// not cmdGifts(): the player is already past the panel decision.
	GiftMenu(id)
	return PLUGIN_HANDLED
}

// One entry point for "open this present", whichever module is loaded.
stock WfOpenOne(id, instance)
{
	if (instance <= 0)
	{
		WfSay(id, "you are not carrying a present - look for a glowing one (or /gifts).")
		return
	}
	if (LibraryExists("winterfest_gifts", LibType_Library))
	{
		wf_gifts_open(id, instance)
		return
	}
	// No gifts module: pay it from the core. No fade, no burst, no HUD - the
	// reward is the part that must never be lost.
	new code = wf_open_gift(id, instance)
	if (code == WF_OPEN_NOTHING)
		WfSay(id, "that present was already opened.")
	else if (code != WF_OPEN_OK)
		WfSay(id, "that present could not be opened - ask an admin to check the log.")
}

// Registered only when winterfest_gifts is missing (see plugin_init), so the
// hub's "open a present" row and /opengift always reach a real opening.
public cmdOpenFallback(id)
{
	if (!WfPlayer(id))
		return PLUGIN_HANDLED
	if (!WfOpen())
	{
		WfClosedLine(id)
		return PLUGIN_HANDLED
	}
	if (wf_gift_count(id) <= 0)
	{
		WfSay(id, "you are not carrying a present - look for a glowing one in the map.")
		return PLUGIN_HANDLED
	}
	WfOpenOne(id, wf_gift_instance(id, 0))
	return PLUGIN_HANDLED
}

// ============================================================
// Tree
// ============================================================
// Text, not a menu: the owner's decision (§6.1) is that the tree is a panel
// surface. /tree opens the panel page; when there is no panel the same facts are
// printed as a five-line summary, which is all a 1999 chat console can honestly
// render.
public cmdTree(id)
{
	if (!WfPlayer(id))
		return PLUGIN_HANDLED
	if (!WfOpen())
	{
		WfClosedLine(id)
		return PLUGIN_HANDLED
	}

	if (fn_open_panel(id, FN_PANEL_WINTER_TREE))
		return PLUGIN_HANDLED

	return TreeSummary(id)
}

TreeSummary(id)
{
	if (!WfPlayer(id))
		return PLUGIN_HANDLED

	new style = wf_tree_style(id)
	new sname[32]
	wf_tree_style_name(style, sname, charsmax(sname))

	new filled = wf_tree_filled(id)
	new slots = wf_tree_slots()
	new level = wf_tree_level(id)

	WfSayFmt(id, "Tree: style ^3%s^1, level ^3%d^1.", sname, level)
	WfSayFmt(id, "Slots filled: ^3%d / %d^1.", filled, slots)

	new next = wf_tree_next_set(id)
	if (next > 0)
	{
		new setname[48], title[64]
		wf_set_name(next, setname, charsmax(setname))
		wf_set_title(next, title, charsmax(title))
		WfSayFmt(id,
			"Next milestone: ^3%s^1 (%d/%d ornaments) - it unlocks the ^3%s^1 title.",
			setname, wf_set_owned(id, next), wf_set_total(next), title)
	}
	else
	{
		WfSayFmt(id,
			"Every set is complete - level %d is as tall as this tree grows this season.", level)
	}

	// Where the 2D tree lives. Built from the panel's own base URL and its
	// Winterfest root (fnweb_url + fnweb_winter_path), so a moved panel is a
	// config edit and no host is hardcoded here. wf_panel_url stays as the last
	// resort for an operator who set it by hand.
	new szBase[80], szRoot[48], szWhere[128]
	szWhere[0] = 0
	if (FNWeb_BaseUrl(szBase, charsmax(szBase)))
	{
		FNWeb_WinterRoot(szRoot, charsmax(szRoot))
		formatex(szWhere, charsmax(szWhere), "%s%s", szBase, szRoot)
	}
	else
		get_cvar_string("wf_panel_url", szWhere, charsmax(szWhere))

	if (szWhere[0])
		WfSayFmt(id, "Panel: ^3%s^1", szWhere)
	else
		WfSayFmt(id,
			"The 2D tree (drag ornaments between the 24 slots) opens on the panel - ask an admin for the address.")
	return PLUGIN_HANDLED
}

// ============================================================
// Ornaments
// ============================================================
public cmdOrnaments(id)
{
	if (!WfPlayer(id))
		return PLUGIN_HANDLED
	if (!WfOpen())
	{
		WfClosedLine(id)
		return PLUGIN_HANDLED
	}

	if (fn_open_panel(id, FN_PANEL_WINTER_ORNAMENTS))
		return PLUGIN_HANDLED

	return OrnMenu(id, 0)
}

OrnMenu(id, page)
{
	if (!WfPlayer(id))
		return PLUGIN_HANDLED

	ornPage(id, page)
	return PLUGIN_HANDLED
}

ornPage(id, page)
{
	new total = wf_ornament_total()
	if (total <= 0)
	{
		WfSay(id, "the ornament catalogue is empty - the config has no [ornament] rows.")
		return
	}

	new owned = wf_ornament_count(id)
	new pages = (total + PAGE_SIZE - 1) / PAGE_SIZE
	if (page < 0)
		page = 0
	if (page >= pages)
		page = pages - 1

	new title[72]
	formatex(title, charsmax(title), "\yOrnaments \r| \w%d of %d \d(page %d/%d)", owned, total, page + 1, pages)
	new menu = menu_create(title, "ornHandler")

	new first = page * PAGE_SIZE + 1
	new last = min(first + PAGE_SIZE - 1, total)
	new row[96], data[12], name[48]

	for (new orn = first; orn <= last; orn++)
	{
		wf_ornament_name(orn, name, charsmax(name))
		if (wf_has_ornament(id, orn))
			formatex(row, charsmax(row), "\w%s \d- collected", name)
		else
			formatex(row, charsmax(row), "\d%s \d- missing", name)
		formatex(data, charsmax(data), "o%d", orn)
		menu_additem(menu, row, data)
	}

	if (pages > 1)
	{
		new data[12]
		if (page + 1 < pages)
		{
			formatex(data, charsmax(data), "p%d", page + 1)
			menu_additem(menu, "\wNext page \y>>", data)
		}
		else
			menu_additem(menu, "\wBack to the start \y<<", "p0")
	}

	FN_MenuFinish(menu)
	menu_display(id, menu)
}

public ornHandler(id, menu, item)
{
	menu_destroy(menu)
	if (!WfPlayer(id))
		return PLUGIN_HANDLED
	if (item < 0)
		return PLUGIN_HANDLED

	new info[16], access, callback, name[1]
	menu_item_getinfo(menu, item, access, info, charsmax(info), name, 0, callback)
	if (!info[0])
		return PLUGIN_HANDLED

	// "p<page>" is navigation, "o<ornament>" is a catalogue row.
	if (info[0] == 'p')
	{
		ornPage(id, str_to_num(info[1]))
		return PLUGIN_HANDLED
	}

	new orn = str_to_num(info[1])
	if (orn <= 0)
		return PLUGIN_HANDLED

	new oname[48], rname[24]
	wf_ornament_name(orn, oname, charsmax(oname))
	wf_rarity_name(wf_ornament_rarity(orn), rname, charsmax(rname))

	new setid = wf_ornament_set(orn)
	if (setid > 0)
	{
		new setname[48], title[64]
		wf_set_name(setid, setname, charsmax(setname))
		wf_set_title(setid, title, charsmax(title))
		WfSayFmt(id,
			"%s ^3(%s)^1 - set ^3%s^1 %d/%d, unlocks ^3%s^1.",
			oname, rname, setname, wf_set_owned(id, setid), wf_set_total(setid), title)
	}
	else
	{
		WfSayFmt(id, "%s ^3(%s)^1 - no set.", oname, rname)
	}

	ornPage(id, 0)
	return PLUGIN_HANDLED
}

// ============================================================
// Advent
// ============================================================
public cmdAdvent(id)
{
	if (!WfPlayer(id))
		return PLUGIN_HANDLED
	if (!WfOpen())
	{
		WfClosedLine(id)
		return PLUGIN_HANDLED
	}

	if (fn_open_panel(id, FN_PANEL_WINTER_ADVENT))
		return PLUGIN_HANDLED

	return AdventMenu(id, 0)
}

AdventMenu(id, page)
{
	if (!WfPlayer(id))
		return PLUGIN_HANDLED

	adventPage(id, page)
	return PLUGIN_HANDLED
}

adventPage(id, page)
{
	new today = wf_advent_today()
	if (today <= 0)
	{
		WfSay(id, "the Advent calendar is closed.")
		return
	}

	new days = 24      // the calendar is 24 days (owner decision §6.3); days
	                   // beyond today show as locked rather than disappearing
	new pages = (days + PAGE_SIZE - 1) / PAGE_SIZE
	if (page < 0)
		page = 0
	if (page >= pages)
		page = pages - 1

	new claimed = 0
	for (new d = 1; d <= days; d++)
		if (wf_advent_claimed(id, d))
			claimed++

	new title[80]
	if (wf_has_entitlement(id, WF_PRODUCT_ADVENT_PASS) == WF_ENT_YES)
		formatex(title, charsmax(title), "\yAdvent \r| \wday %d \d(claimed %d, Advent Pass - all open)", today, claimed)
	else
		formatex(title, charsmax(title), "\yAdvent \r| \wday %d \d(claimed %d, page %d/%d)", today, claimed, page + 1, pages)
	new menu = menu_create(title, "adventHandler")

	new first = page * PAGE_SIZE + 1
	new last = min(first + PAGE_SIZE - 1, days)
	new row[96], data[12]

	// One row per day, and the row says the truth: claimed, open today, expired
	// (it was missed - no discount), locked (not its day yet), or unlocked by the
	// Advent Pass (every day is claimable at once).
	for (new day = first; day <= last; day++)
	{
		switch (wf_advent_state(id, day))
		{
			case WF_ADVENT_CLAIMED:
				formatex(row, charsmax(row), "\dDay %d \d- claimed", day)
			case WF_ADVENT_TODAY:
				formatex(row, charsmax(row), "\wDay %d \y- open today", day)
			case WF_ADVENT_EXPIRED:
				formatex(row, charsmax(row), "\dDay %d \d- expired", day)
			case WF_ADVENT_UNLOCKED:
				formatex(row, charsmax(row), "\wDay %d \y- open (Advent Pass)", day)
			default:
				formatex(row, charsmax(row), "\dDay %d \d- locked", day)
		}
		formatex(data, charsmax(data), "d%d", day)
		menu_additem(menu, row, data)
	}

	if (pages > 1)
	{
		if (page + 1 < pages)
		{
			formatex(data, charsmax(data), "p%d", page + 1)
			menu_additem(menu, "\wNext page \y>>", data)
		}
		else
			menu_additem(menu, "\wBack to the start \y<<", "p0")
	}

	FN_MenuFinish(menu)
	menu_display(id, menu)
}

public adventHandler(id, menu, item)
{
	menu_destroy(menu)
	if (!WfPlayer(id))
		return PLUGIN_HANDLED
	if (item < 0)
		return PLUGIN_HANDLED

	new info[16], access, callback, name[1]
	menu_item_getinfo(menu, item, access, info, charsmax(info), name, 0, callback)
	if (!info[0])
		return PLUGIN_HANDLED

	if (info[0] == 'p')
	{
		adventPage(id, str_to_num(info[1]))
		return PLUGIN_HANDLED
	}

	new day = str_to_num(info[1])
	if (day <= 0)
		return PLUGIN_HANDLED

	new code = wf_advent_claim(id, day)
	switch (code)
	{
		case WF_ADVENT_CLAIM_CLAIMED:
			WfSay(id, "that day was already claimed.")
		case WF_ADVENT_CLAIM_EXPIRED:
			WfSay(id, "that day has expired - the Advent Pass unlocks the whole calendar.")
		case WF_ADVENT_CLAIM_LOCKED:
			WfSay(id, "that day has not arrived yet.")
		case WF_ADVENT_CLAIM_INVALID:
			WfSay(id, "that day is not claimable.")
	}
	// WF_ADVENT_CLAIM_OK: the core's grant path already printed the reward.
	// The reward line itself is printed by the core's grant path.

	adventPage(id, 0)
	return PLUGIN_HANDLED
}

// ============================================================
// Winter pass
// ============================================================
public cmdPass(id)
{
	if (!WfPlayer(id))
		return PLUGIN_HANDLED
	if (!WfOpen())
	{
		WfClosedLine(id)
		return PLUGIN_HANDLED
	}

	if (fn_open_panel(id, FN_PANEL_WINTER_PASS))
		return PLUGIN_HANDLED

	return PassSummary(id)
}

PassSummary(id)
{
	if (!WfPlayer(id))
		return PLUGIN_HANDLED

	new tier = wf_get_pass_tier(id)
	new max_tier = wf_pass_max_tier()
	new xp = wf_get_pass_xp(id)
	new next = wf_pass_next_xp(id)

	WfSayFmt(id, "Winter pass: tier ^3%d^1 of %d (free track)", tier, max_tier)
	if (tier >= max_tier)
		WfSayFmt(id, "^3%d^1 XP - every tier reached this season.", xp)
	else
		WfSayFmt(id, "^3%d^1 / %d XP to tier ^3%d^1.", xp, next, tier + 1)

	// The next three tier rewards, so the pass is not just a number.
	new shown = 0
	new row[96], rtext[64]
	for (new t = tier + 1; t <= max_tier && shown < 3; t++)
	{
		wf_pass_tier_reward(t, rtext, charsmax(rtext))
		if (!rtext[0])
			continue
		formatex(row, charsmax(row), "tier %d at %d XP: %s", t, wf_pass_tier_xp(t), rtext)
		WfSayFmt(id, "%s", row)
		shown++
	}
	if (!shown)
		WfSayFmt(id, "Nothing left to unlock - nice.")

	// The premium track is an entitlement, never a grant: without it the rows are
	// refused, with it they pay for every tier already reached.
	if (wf_pass_premium_unlocked(id))
	{
		WfSayFmt(id, "Premium track: ^3owned^1 - its rewards are paid tier by tier.")
		shown = 0
		for (new t = tier + 1; t <= max_tier && shown < 3; t++)
		{
			wf_pass_tier_reward_premium(t, rtext, charsmax(rtext))
			if (!rtext[0])
				continue
			formatex(row, charsmax(row), "premium tier %d at %d XP: %s", t, wf_pass_tier_xp(t), rtext)
			WfSayFmt(id, "%s", row)
			shown++
		}
	}
	else
	{
		WfSayFmt(id,
			"Premium track: ^3not owned^1 - the shop sells it; your free tiers are unaffected.")
	}
	return PLUGIN_HANDLED
}

// ============================================================
// Shop (Phase 2)
// ============================================================
public cmdShop(id)
{
	if (!WfPlayer(id))
		return PLUGIN_HANDLED
	// One line, and the truth: there is no shop yet, and GingerBread is safe.
	WfSay(id, "the Christmas shop opens in Phase 2 - GingerBread you earn now is kept.")
	return PLUGIN_HANDLED
}
