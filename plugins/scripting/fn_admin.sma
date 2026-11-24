/* fn_admin: command-center hub (3.0 M7). A HUB, not a second player menu:
 * player actions live in fn_menus (opened via its native); server/maps/
 * config sections open the existing menus by their client commands; ban
 * flows keep their confirms. R2-safe by construction: this plugin issues
 * no kick/ban/slay/slap itself. Entries are permission-aware (flag +
 * guarded fn_perm check); destructive paths stay where their confirms are.
 * Recent-targets ring records hub-initiated picks only (documented limit). */
#include <amxmodx>
#include <amxmisc>
#include <fn_core>
#include <fn_menus>
#include <fn_perms>
#include <fn_common>

new g_recent[33];
new g_recentAct[33][24];

public plugin_natives()
{
	set_native_filter("native_filter");
	register_library("fn_admin");
	register_native("fn_hub_pick", "hubPick");
}

public native_filter(const name[], index, trap)
{
	if (!trap && contain(name, "fn_") == 0)
		return PLUGIN_HANDLED;
	return PLUGIN_CONTINUE;
}

public plugin_init()
{
	fn_boot_banner("admin", 2);

	register_plugin("FreeNova Admin Hub", "3.0.0", "FreeNova");
	register_clcmd("amx_admin", "cmdHub", ADMIN_ADMIN, "- administration hub");
	/* NOTE (debug M12): say /admin belongs to menufront (loaded earlier,
	 * consumes unconditionally) - do NOT register it here or the hub entry
	 * silently never fires. amx_admin is the hub entry. */
	if (!LibraryExists("fn_core", LibType_Library))
	{
		log_amx("[FN-ADMIN] fn_core missing, pausing self");
		pause("d");
		return;
	}
	fn_health_set("admin", "ok");
}

public client_disconnected(id)
{
	g_recent[id] = 0;
	g_recentAct[id][0] = 0;
}

bool:can(id, flag, node)
{
	if (id == 0)
		return true;
	if (get_user_flags(id) & flag)
		return true;
	if (LibraryExists("fn_perms", LibType_Library) && fn_perm_check(id, node))
		return true;
	return false;
}

public cmdHub(id, level, cid)
{
	if (!cmd_access(id, level, cid, 1))
		return PLUGIN_HANDLED;
	showHub(id);
	return PLUGIN_HANDLED;
}

showHub(id)
{
	new menu = menu_create("\yFreeNova Admin\w", "hubH");
	if (can(id, ADMIN_KICK, FN_PERM_MENU))
		menu_additem(menu, "Player management", "players");
	if (can(id, ADMIN_BAN, FN_PERM_REPORTS))
		menu_additem(menu, "Reports", "reports");
	if (can(id, ADMIN_CFG, FN_PERM_CONFIG))
		menu_additem(menu, "Server menus", "server");
	if (can(id, ADMIN_MAP, FN_PERM_MAPS_CHANGE))
		menu_additem(menu, "Map menus", "maps");
	if (can(id, ADMIN_CHAT, FN_PERM_CHAT))
		menu_additem(menu, "Communication", "comms");
	if (can(id, ADMIN_ADMIN, FN_PERM_DIAG))
		menu_additem(menu, "Diagnostics", "diag");
	if (can(id, ADMIN_CFG, FN_PERM_CONFIG))
		menu_additem(menu, "Configuration", "config");
	new recent = (id >= 1 && g_recent[id] > 0) ? g_recent[id] : 0;
	if (recent > 0 && is_user_connected(recent))
	{
		new nm[MAX_NAME_LENGTH], line[96];
		get_user_name(recent, nm, charsmax(nm));
		if (g_recentAct[id][0])
			formatex(line, charsmax(line), "Recent: %s (%s)", nm, g_recentAct[id]);
		else
			formatex(line, charsmax(line), "Recent: %s", nm);
		menu_additem(menu, line, "recent");
	}
	menu_display(id, menu);
}

public hubH(id, menu, item)
{
	if (item == MENU_EXIT)
	{
		menu_destroy(menu);
		return PLUGIN_HANDLED;
	}
	new info[16], access, callback, dummy[1];
	menu_item_getinfo(menu, item, access, info, charsmax(info), dummy, 0, callback);
	menu_destroy(menu);
	if (equal(info, "players"))
	{
		if (LibraryExists("fn_menus", LibType_Library))
			fn_menu_open(id);
		else
			client_print(id, print_chat, "[FN] player menu unavailable.");
	}
	else if (equal(info, "reports"))
		client_cmd(id, "say /reports");
	else if (equal(info, "server"))
		client_cmd(id, "amxmodmenu");
	else if (equal(info, "maps"))
		client_cmd(id, "amx_mapmenu");
	else if (equal(info, "comms"))
		client_cmd(id, "amx_helpmenu");
	else if (equal(info, "diag"))
		client_cmd(id, "fn_status");
	else if (equal(info, "config"))
		client_cmd(id, "amx_plugincvarmenu");
	else if (equal(info, "recent"))
	{
		new t = g_recent[id];
		if (t > 0 && is_user_connected(t) && LibraryExists("fn_menus", LibType_Library))
			fn_menu_open(id);
		else
			showHub(id);
	}
	return PLUGIN_HANDLED;
}

public hubPick(plugin, params)
{
	new id = get_param(1);
	new target = get_param(2);
	new action[24];
	get_string(3, action, charsmax(action));
	if (id >= 1 && id <= MaxClients && target >= 1 && target <= MaxClients)
	{
		g_recent[id] = target;
		copy(g_recentAct[id], charsmax(g_recentAct[]), action);
	}
	return 1;
}
