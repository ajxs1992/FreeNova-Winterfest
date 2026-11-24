/* fn_servers: server browser (3.0 M7). Static curated list from
 * configs/fn_servers.ini (name | address | desc, ;comments, max 16).
 * Destinations are format-validated (host:port, numeric port 1-65535)
 * before any client_cmd connect. Statuses are "unknown" in M7: no live
 * querying exists yet (never claim online without a check), sockets +
 * caching + timeouts arrive with the M10 live source. Standalone local
 * config only. */
#include <amxmodx>
#include <amxmisc>
#include <fn_core>
#include <fn_common>

#define MAXSERVERS 16

new g_names[MAXSERVERS][48];
new g_addrs[MAXSERVERS][64];
new g_descs[MAXSERVERS][96];
new g_servers;

public plugin_natives()
{
	set_native_filter("native_filter");
	register_library("fn_servers");
}

public native_filter(const name[], index, trap)
{
	if (!trap && contain(name, "fn_") == 0)
		return PLUGIN_HANDLED;
	return PLUGIN_CONTINUE;
}

public plugin_init()
{
	fn_boot_banner("servers", 2);

	register_plugin("FreeNova Servers", "3.0.0", "FreeNova");
	register_clcmd("amx_serversmenu", "cmdServers", ADMIN_ALL, "- browse community servers");
	register_concmd("fn_servers", "cmdServerList", ADMIN_ALL, "- print the configured server list (console)");
	register_clcmd("say /servers", "cmdServers", ADMIN_ALL);
	register_clcmd("say_team /servers", "cmdServers", ADMIN_ALL);
	if (!LibraryExists("fn_core", LibType_Library))
	{
		log_amx("[FN-SERVERS] fn_core missing, pausing self");
		pause("d");
		return;
	}
	loadList();
	fn_health_set("servers", "ok");
}

loadList()
{
	g_servers = 0;
	new path[128], cfg[96];
	get_configsdir(cfg, charsmax(cfg));
	formatex(path, charsmax(path), "%s/fn_servers.ini", cfg);
	if (!file_exists(path))
		return;
	new fp = fopen(path, "rt");
	if (!fp)
		return;
	new line[224], nm[48], ad[64], ds[96];
	while (g_servers < MAXSERVERS && fgets(fp, line, charsmax(line)))
	{
		trim(line);
		if (!line[0] || line[0] == ';' || line[0] == '/')
			continue;
		new pos1 = contain(line, "|");
		if (pos1 < 1)
			continue;
		copy(nm, pos1, line);
		new rest[160];
		copy(rest, charsmax(rest), line[pos1 + 1]);
		new pos2 = contain(rest, "|");
		if (pos2 < 1)
			continue;
		copy(ad, pos2, rest);
		copy(ds, charsmax(ds), rest[pos2 + 1]);
		trim(nm); trim(ad); trim(ds);
		if (!nm[0] || !validDest(ad))
			continue;
		copy(g_names[g_servers], 47, nm);
		copy(g_addrs[g_servers], 63, ad);
		copy(g_descs[g_servers], 95, ds);
		g_servers++;
	}
	fclose(fp);
}

bool:validDest(const ad[])
{
	new len = strlen(ad);
	if (len < 3 || len > 63)
		return false;
	new colon = -1;
	for (new i = 0; i < len; i++)
	{
		new c = ad[i];
		if (c == ':')
		{
			if (colon != -1)
				return false;
			colon = i;
		}
		else if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '.' || c == '-'))
			return false;
	}
	if (colon < 1 || colon == len - 1)
		return false;
	new port = str_to_num(ad[colon + 1]);
	return (port > 0 && port <= 65535) ? true : false;
}

public cmdServers(id, level, cid)
{
	if (!cmd_access(id, level, cid, 1))
		return PLUGIN_HANDLED;

	// Server console / RCON: no menu to draw and nobody to connect.
	if (id <= 0)
	{
		PrintList();
		return PLUGIN_HANDLED;
	}

	// A bot has no client to draw a menu on and cannot act on a connect.
	if (!is_user_connected(id) || is_user_bot(id) || is_user_hltv(id))
		return PLUGIN_HANDLED;

	if (!g_servers)
	{
		client_print(id, print_chat, "[FN] no community servers configured (configs/fn_servers.ini).");
		return PLUGIN_HANDLED;
	}
	new menu = menu_create("\yServers \d(statuses unverified)\w", "srvH");
	new line[160], info[8];
	for (new i = 0; i < g_servers; i++)
	{
		formatex(line, charsmax(line), "%s \y%s\w - %s", g_names[i], g_addrs[i], g_descs[i]);
		num_to_str(i, info, charsmax(info));
		menu_additem(menu, line, info);
	}
	menu_display(id, menu);
	return PLUGIN_HANDLED;
}

/* The same list the menu is built from, printed to the server console. This is
 * what an operator runs after a deploy to prove the config parsed - and it is
 * the console-safe half of /servers (a console caller has no menu and nobody to
 * connect). */
PrintList()
{
	console_print(0, "[FN-SERVERS] %d configured server(s) from configs/fn_servers.ini:", g_servers);
	for (new i = 0; i < g_servers; i++)
		console_print(0, "  %d. %s | %s | %s", i + 1, g_names[i], g_addrs[i], g_descs[i]);
	if (!g_servers)
		console_print(0, "[FN-SERVERS] list is empty - /servers is advertised but does nothing.");
}

public cmdServerList(id, level, cid)
{
	if (!cmd_access(id, level, cid, 1))
		return PLUGIN_HANDLED;
	PrintList();
	return PLUGIN_HANDLED;
}

public srvH(id, menu, item)
{
	if (item < 0)
	{
		menu_destroy(menu);
		return PLUGIN_HANDLED;
	}

	// The player may have disconnected while the menu was open.
	if (!is_user_connected(id) || is_user_bot(id))
	{
		menu_destroy(menu);
		return PLUGIN_HANDLED;
	}
	new info[8], access, callback, dummy[1];
	menu_item_getinfo(menu, item, access, info, charsmax(info), dummy, 0, callback);
	menu_destroy(menu);
	new idx = str_to_num(info);
	if (idx < 0 || idx >= g_servers)
		return PLUGIN_HANDLED;
	new ad[64];
	copy(ad, charsmax(ad), g_addrs[idx]);
	if (!validDest(ad))
	{
		client_print(id, print_chat, "[FN] invalid destination, aborted.");
		return PLUGIN_HANDLED;
	}
	log_amx("[FN-SERVERS] #%d jumping to %s (%s)", id, g_names[idx], ad);
	client_cmd(id, "connect %s", ad);
	return PLUGIN_HANDLED;
}
