/* fn_pinfo: player intelligence panel (3.0 M7). Verified server-side facts
 * only: nick/steam/userid/connected-time/team/alive/ping/loss/role/VIP/
 * gag/warns/scan/session + previous names. IPs restricted to ADMIN_RCON.
 * Previous names: last 3 per authid in nvault (recorded at disconnect,
 * deduped); bots/pending IDs are session-only and never stored (policy).
 * No per-open database queries (all state is memory/nvault). */
#include <amxmodx>
#include <amxmisc>
#include <cstrike>
#include <nvault>
#include <fn_core>
#include <fn_perms>
#include <fn_moderation>
#include <fn_common>

native is_user_gagged(id);
native fn_scan_state(id);

new g_vaultNames;
new g_pickUser[33];

public plugin_natives()
{
	set_native_filter("native_filter");
	register_library("fn_pinfo");
}

public native_filter(const name[], index, trap)
{
	if (!trap && (contain(name, "fn_") == 0 || equal(name, "is_user_gagged")))
		return PLUGIN_HANDLED;
	return PLUGIN_CONTINUE;
}

public plugin_init()
{
	fn_boot_banner("pinfo", 2);

	register_plugin("FreeNova Intel", "3.0.0", "FreeNova");
	register_clcmd("amx_pinfo", "cmdPinfo", ADMIN_KICK, "- player intelligence");
	register_clcmd("say /pinfo", "cmdPinfo", ADMIN_KICK);
	if (!LibraryExists("fn_core", LibType_Library))
	{
		log_amx("[FN-PINFO] fn_core missing, pausing self");
		pause("d");
		return;
	}
	g_vaultNames = nvault_open("fn_names");
	fn_health_set("pinfo", "ok");
}

public plugin_end()
{
	if (g_vaultNames != INVALID_HANDLE)
		nvault_close(g_vaultNames);
}

public client_disconnected(id)
{
	g_pickUser[id] = 0;
	if (is_user_bot(id))
		return;
	new auth[32];
	get_user_authid(id, auth, charsmax(auth));
	if (!auth[0] || equal(auth, "STEAM_ID_PENDING") || contain(auth, "LAN") != -1)
		return;
	new name[MAX_NAME_LENGTH];
	get_user_name(id, name, charsmax(name));
	if (!name[0])
		return;
	if (g_vaultNames == INVALID_HANDLE)
		return;
	new data[128], ts;
	if (nvault_lookup(g_vaultNames, auth, data, charsmax(data), ts))
	{
		if (containi(data, name) != -1)
			return;
		new grown[128];
		formatex(grown, charsmax(grown), "%s|%s", name, data);
		grown[100] = 0;
		nvault_set(g_vaultNames, auth, grown);
	}
	else
		nvault_set(g_vaultNames, auth, name);
}

public cmdPinfo(id, level, cid)
{
	if (!cmd_access(id, level, cid, 1))
		return PLUGIN_HANDLED;
	showPicker(id);
	return PLUGIN_HANDLED;
}

showPicker(id)
{
	new menu = menu_create("\yPlayer intel\w", "pickIntel");
	new players[32], num, name[MAX_NAME_LENGTH], line[96], info[8];
	get_players(players, num, "h");
	for (new i = 0; i < num; i++)
	{
		new pl = players[i];
		get_user_name(pl, name, charsmax(name));
		formatex(line, charsmax(line), "%s \y[%s]", name, is_user_alive(pl) ? "A" : "D");
		num_to_str(get_user_userid(pl), info, charsmax(info));
		menu_additem(menu, line, info);
	}
	if (!num)
		menu_additem(menu, "(no players)", "0");
	menu_display(id, menu);
}

public pickIntel(id, menu, item)
{
	if (item < 0)
	{
		menu_destroy(menu);
		return PLUGIN_HANDLED;
	}
	new info[8], access, callback, dummy[1];
	menu_item_getinfo(menu, item, access, info, charsmax(info), dummy, 0, callback);
	menu_destroy(menu);
	new t = find_player("k", str_to_num(info));
	if (t < 1 || !is_user_connected(t))
	{
		client_print(id, print_chat, "[FN] player left.");
		return PLUGIN_HANDLED;
	}
	showPanel(id, t);
	return PLUGIN_HANDLED;
}

showPanel(id, t)
{
	new name[MAX_NAME_LENGTH], auth[32], ip[32];
	get_user_name(t, name, charsmax(name));
	get_user_authid(t, auth, charsmax(auth));
	get_user_ip(t, ip, charsmax(ip), 1);
	new ping, loss;
	get_user_ping(t, ping, loss);
	new team[16];
	new CsTeams:ct = cs_get_user_team(t);
	if (ct == CS_TEAM_T)
		copy(team, charsmax(team), "T");
	else if (ct == CS_TEAM_CT)
		copy(team, charsmax(team), "CT");
	else if (ct == CS_TEAM_SPECTATOR)
		copy(team, charsmax(team), "SPEC");
	else
		copy(team, charsmax(team), "-");
	console_print(id, "[FN] ---- %s ----", name);
	console_print(id, "  auth=%s userid=%d", auth, get_user_userid(t));
	console_print(id, "  team=%s alive=%d ping=%d loss=%d connected=%ds",
		team, is_user_alive(t) ? 1 : 0, ping, loss, get_user_time(t));
	if (id == 0 || (get_user_flags(id) & ADMIN_RCON))
		console_print(id, "  ip=%s", ip);
	else
		console_print(id, "  ip=(restricted)");
	new hasRoles = LibraryExists("fn_core", LibType_Library);
	if (hasRoles)
		console_print(id, "  role=%d expiry=%ds", fn_role_get(t), fn_role_expiry(t));
	new vip = 0;
	if (LibraryExists("fn_perms", LibType_Library))
	{
		new pr = fn_perm_profile(t);
		vip = (pr == 1) ? 1 : 0;
		console_print(id, "  profile=%d warns=%d", pr, fn_mod_warns(t));
	}
	else if (LibraryExists("fn_moderation", LibType_Library))
		console_print(id, "  warns=%d", fn_mod_warns(t));
	new gag = 0;
	if (LibraryExists("gagsystem", LibType_Library))
		gag = is_user_gagged(t) ? 1 : 0;
	console_print(id, "  gagged=%d vip=%d", gag, vip);
	if (LibraryExists("fn_scan", LibType_Library))
		console_print(id, "  scan=%d", fn_scan_state(t));
	else
		console_print(id, "  scan=n/a");
	if (g_vaultNames != INVALID_HANDLE && !is_user_bot(t))
	{
		new data[128], ts;
		if (nvault_lookup(g_vaultNames, auth, data, charsmax(data), ts))
			console_print(id, "  names=%s", data);
	}
	fn_safe_log(id, t, "pinfo.view", name);
}
