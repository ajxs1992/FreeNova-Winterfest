/* fn_menus: the ONE player-management menu. AB-syntax bans with reason prompt,
 * duration presets, permanent-ban confirmation via fn_bans, audit on actions.
 * Requires an AB-syntax backend for bans; without fn_bans it issues amx_ban
 * directly (same syntax) and logs the gap. */
#include <amxmodx>
#include <amxmisc>
#include <cstrike>
#include <fn_core>
#include <fn_bans>
#include <fn_admin>
#include <fn_common>

new g_menuTarget[33];
new g_menuUser[33];
new g_menuAction[33][8];
new g_menuMins[33];

public plugin_natives()
{
	register_library("fn_menus");
	set_native_filter("native_filter");
	register_native("fn_menu_open", "_menu_open");
}

public native_filter(const name[], index, trap)
{
	if (!trap && contain(name, "fn_") == 0)
		return PLUGIN_HANDLED;
	return PLUGIN_CONTINUE;
}

public plugin_init()
{
	fn_boot_banner("menus", 4);

	register_plugin("FreeNova Menus", "2.0.0", "FreeNova");
	register_clcmd("amx_playermenu", "cmdMenu", ADMIN_KICK, "- player management");
	register_clcmd("say /players", "cmdMenu", ADMIN_KICK);
	register_clcmd("fn_banreason", "cmdReason", ADMIN_BAN, "- ban reason input");
	if (!LibraryExists("fn_core", LibType_Library))
	{
		log_amx("[FN-MENUS] fn_core missing, pausing self");
		pause("d");
		return;
	}
	if (!LibraryExists("fn_bans", LibType_Library))
	{
		log_amx("[FN-MENUS] fn_bans missing, pausing self (M2: bans need the authority, no silent fallback)");
		pause("d");
		return;
	}
	fn_health_set("menus", "ok");
}

public _menu_open(plugin, params)
{
	new admin = get_param(1);
	if (admin < 1 || !is_user_connected(admin)) return 0;
	showPlayers(admin);
	return 1;
}

public cmdMenu(id, level, cid)
{
	if (!cmd_access(id, level, cid, 1)) return PLUGIN_HANDLED;
	showPlayers(id);
	return PLUGIN_HANDLED;
}

showPlayers(id)
{
	new menu = menu_create("\yPlayers \r(fresh list)", "pickPlayer");
	new players[32], num, name[32], line[96], info[8];
	get_players(players, num, "h"); // admins must see bot slots
	for (new i = 0; i < num; i++)
	{
		new p = players[i];
		get_user_name(p, name, charsmax(name));
		new ping, loss;
		get_user_ping(p, ping, loss);
		formatex(line, charsmax(line), "%s \y[%s%dms]", name, is_user_alive(p) ? "A" : "D", ping);
		num_to_str(p, info, charsmax(info));
		menu_additem(menu, line, info);
	}
	menu_display(id, menu);
}

menuTarget(id)
{
	new want = g_menuUser[id];
	if (want <= 0) return 0;
	new players[32], num;
	get_players(players, num, "h"); // admins must see bot slots
	for (new i = 0; i < num; i++)
		if (get_user_userid(players[i]) == want) return players[i];
	return 0;
}

clearMenu(id) { g_menuTarget[id] = 0; g_menuUser[id] = 0; g_menuMins[id] = 0; }

public client_disconnected(id) { clearMenu(id); }

needFlag(id, flag)
{
	if (id == 0) return 1;
	if (get_user_flags(id) & flag) return 1;
	client_print(id, print_chat, "[FN] missing access for that action.");
	return 0;
}

targetOK(id, t)
{
	if (!fn_safe_can_hit(id, t)) { client_print(id, print_chat, "[FN] target outranks you."); return 0; }
	if ((get_user_flags(t) & ADMIN_IMMUNITY) && id != 0 && !(get_user_flags(id) & ADMIN_RCON))
	{
		client_print(id, print_chat, "[FN] target has immunity.");
		return 0;
	}
	return 1;
}

public pickPlayer(id, menu, item)
{
	if (item == MENU_EXIT) { menu_destroy(menu); return PLUGIN_HANDLED; }
	new info[8];
	menu_item_getinfo(menu, item, _, info, charsmax(info));
	menu_destroy(menu);
	new target = str_to_num(info);
	if (target < 1 || !is_user_connected(target))
	{
		client_print(id, print_chat, "[FN] player left.");
		return PLUGIN_HANDLED;
	}
	g_menuTarget[id] = target;
	g_menuUser[id] = get_user_userid(target);
	if (LibraryExists("fn_admin", LibType_Library))
		fn_hub_pick(id, target, "players");
	showActions(id);
	return PLUGIN_HANDLED;
}

showActions(id)
{
	new t = menuTarget(id);
	if (t < 1) { client_print(id, print_chat, "[FN] player left."); return; }
	new name[32];
	get_user_name(t, name, charsmax(name));
	new title[96];
	formatex(title, charsmax(title), "\y%s \w(actions)", name);
	new menu = menu_create(title, "pickAction");
	menu_additem(menu, "Kick", "kick");
	menu_additem(menu, "Slap 10", "slap");
	menu_additem(menu, "Slay", "slay");
	menu_additem(menu, "Move T / CT", "team");
	menu_additem(menu, "Gag 15 min", "gag");
	menu_additem(menu, "Ban...", "ban");
	menu_display(id, menu);
}

public pickAction(id, menu, item)
{
	if (item == MENU_EXIT) { menu_destroy(menu); return PLUGIN_HANDLED; }
	new info[8];
	menu_item_getinfo(menu, item, _, info, charsmax(info));
	menu_destroy(menu);
	new t = menuTarget(id);
	if (t < 1)
	{
		client_print(id, print_chat, "[FN] player left.");
		return PLUGIN_HANDLED;
	}
	copy(g_menuAction[id], 7, info);
	if (equal(info, "ban"))
	{
		if (!needFlag(id, ADMIN_BAN) || !targetOK(id, t)) return PLUGIN_HANDLED;
		showDurations(id);
		return PLUGIN_HANDLED;
	}
	if (equal(info, "kick") && !needFlag(id, ADMIN_KICK)) return PLUGIN_HANDLED;
	if ((equal(info, "slap") || equal(info, "slay")) && !needFlag(id, ADMIN_SLAY)) return PLUGIN_HANDLED;
	if (equal(info, "team") && !needFlag(id, ADMIN_LEVEL_A)) return PLUGIN_HANDLED;
	if (equal(info, "gag") && !needFlag(id, ADMIN_CHAT)) return PLUGIN_HANDLED;
	if (!targetOK(id, t)) return PLUGIN_HANDLED;
	if (equal(info, "kick")) server_cmd("kick #%d", get_user_userid(t));
	else if (equal(info, "slap")) server_cmd("amx_slap #%d 10", get_user_userid(t));
	else if (equal(info, "slay")) server_cmd("amx_slay #%d", get_user_userid(t));
	else if (equal(info, "team"))
	{
		if (cs_get_user_team(t) == CS_TEAM_T) cs_set_user_team(t, CS_TEAM_CT);
		else cs_set_user_team(t, CS_TEAM_T);
	}
	else if (equal(info, "gag")) server_cmd("amx_gag #%d 15", get_user_userid(t));
	fn_safe_log(id, t, info, "menu");
	return PLUGIN_HANDLED;
}

showDurations(id)
{
	new menu = menu_create("\yBan duration", "pickDuration");
	menu_additem(menu, "5 minutes", "5");
	menu_additem(menu, "30 minutes", "30");
	menu_additem(menu, "60 minutes", "60");
	menu_additem(menu, "1 day", "1440");
	menu_additem(menu, "PERMANENT (confirm)", "0");
	menu_display(id, menu);
}

public pickDuration(id, menu, item)
{
	if (item == MENU_EXIT) { menu_destroy(menu); return PLUGIN_HANDLED; }
	new info[8];
	menu_item_getinfo(menu, item, _, info, charsmax(info));
	menu_destroy(menu);
	g_menuMins[id] = str_to_num(info);
	client_cmd(id, "messagemode fn_banreason");
	client_print(id, print_chat, "[FN] type the ban reason:");
	return PLUGIN_HANDLED;
}

public cmdReason(id, level, cid)
{
	if (!cmd_access(id, level, cid, 3)) return PLUGIN_HANDLED;
	new reason[96];
	read_argv(1, reason, charsmax(reason));
	if (!reason[0]) { client_print(id, print_chat, "[FN] empty reason, cancelled."); return PLUGIN_HANDLED; }
	new t = menuTarget(id);
	if (t < 1 || !is_user_connected(t)) { client_print(id, print_chat, "[FN] player left."); return PLUGIN_HANDLED; }
	new steam[40];
	get_user_authid(t, steam, charsmax(steam));
	new mins = g_menuMins[id];
	if (LibraryExists("fn_bans", LibType_Library))
	{
		new r = fn_ban_add(id, steam, "", mins, reason);
		if (r == 0) client_print(id, print_chat, "[FN] ban rejected.");
		else if (r == -1) client_print(id, print_chat, "[FN] permanent held: confirm, then repeat the menu.");
		else client_print(id, print_chat, "[FN] ban issued.");
	}
	/* M2: silent direct-ban fallback removed. Plugin pauses without fn_bans (above). */
	return PLUGIN_HANDLED;
}