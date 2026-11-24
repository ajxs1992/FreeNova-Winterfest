/* fn_modules: dependency inspector (3.0 M6). Loaded vs initialized vs
 * degraded vs missing per module - health != library-exists. Titles are
 * exact register_plugin strings (a wrong title reports missing, never
 * crashes). Console table + fn_mods_status summary for dashboards. */
#include <amxmodx>
#include <amxmisc>
#include <fn_core>
#include <fn_common>

#define MAXMOD 60

new g_titles[MAXMOD][32];
new g_healthk[MAXMOD][16];
new g_mods;

public plugin_natives()
{
	set_native_filter("native_filter");
	register_library("fn_mods");
	register_native("fn_mods_status", "_status");
}

public native_filter(const name[], index, trap)
{
	if (!trap && contain(name, "fn_") == 0)
		return PLUGIN_HANDLED;
	return PLUGIN_CONTINUE;
}

public plugin_init()
{
	fn_boot_banner("modules", 2);

	register_plugin("FreeNova Modules", "3.0.0", "FreeNova");
	register_concmd("fn_modules", "cmdModules", ADMIN_ADMIN, "- loaded/initialized/degraded/missing per module");
	addMod("FreeNova Core", "core");
	addMod("FreeNova Roles", "roles");
	addMod("FreeNova Audit", "audit");
	addMod("FreeNova Bans", "bans");
	addMod("FreeNova Range Bans", "");
	addMod("FreeNova Moderation", "moderation");
	addMod("FreeNova Identity", "identity");
	addMod("FreeNova State", "state");
	addMod("FreeNova Chat", "chat");
	addMod("FreeNova Permissions", "perms");
	addMod("FreeNova Menus", "menus");
	addMod("FreeNova Maps", "maps");
	addMod("FreeNova Guard Glue", "guard");
	addMod("FreeNova Sync", "sync");
	addMod("FreeNova Diagnostics", "diag");
	addMod("FreeNova Doctor", "doctor");
	addMod("Gag System", "discipline.gag");
	addMod("Scan System", "");
	addMod("Anti Flood", "discipline.antiflood");
	addMod("Map Manager", "");
	addMod("Map RTV", "");
	addMod("Nextmap Chooser", "");
	addMod("NextMap", "");
	addMod("TimeLeft", "");
	addMod("Admin Votes", "");
	addMod("Teleport Menu", "");
	addMod("Ghostchat", "");
	addMod("Chat Tags", "");
	addMod("Admin Chat", "");
	addMod("Admin Base", "");
	addMod("FreeNova Admin Hub", "admin");
	addMod("FreeNova Intel", "pinfo");
	addMod("FreeNova Reports", "reports");
	addMod("FreeNova Settings", "settings");
	addMod("FreeNova Welcome", "welcome");
	addMod("FreeNova Servers", "servers");
	addMod("FreeNova Spectate", "spectate");
	addMod("FreeNova AFK", "afk");
	addMod("FreeNova Reconnect", "reconnect");
	addMod("FreeNova HUD", "hud");
	addMod("FreeNova Policy", "policy");
	addMod("FreeNova Limits", "limits");
	addMod("FreeNova Modes", "modes");
	addMod("FreeNova Match", "match");
	addMod("FreeNova Link", "link");
	if (LibraryExists("fn_core", LibType_Library))
		fn_health_set("mods", "ok");
}

addMod(const title[], const hkey[])
{
	if (g_mods >= MAXMOD)
		return;
	copy(g_titles[g_mods], 31, title);
	copy(g_healthk[g_mods], 15, hkey);
	g_mods++;
}

modState(idx, out[], len)
{
	if (is_plugin_loaded(g_titles[idx]) == -1)
	{
		copy(out, len, "missing");
		return 0;
	}
	if (!g_healthk[idx][0])
	{
		copy(out, len, "loaded");
		return 2;
	}
	if (!LibraryExists("fn_core", LibType_Library))
	{
		copy(out, len, "loaded");
		return 1;
	}
	new s[64];
	if (!fn_health_get(g_healthk[idx], s, charsmax(s)))
	{
		copy(out, len, "loaded-uninitialized");
		return 1;
	}
	if (equal(s, "ok"))
	{
		copy(out, len, "ok");
		return 2;
	}
	copy(out, len, s);
	return 1;
}

public cmdModules(id, level, cid)
{
	if (!cmd_access(id, level, cid, 1))
		return PLUGIN_HANDLED;
	new st[32], ok = 0, bad = 0, miss = 0;
	console_print(id, "[FN] modules: title -> state");
	for (new i = 0; i < g_mods; i++)
	{
		new r = modState(i, st, charsmax(st));
		if (r == 2)
			ok++;
		else if (r == 1)
			bad++;
		else
			miss++;
		console_print(id, "  %-22s %s", g_titles[i], st);
		log_amx("[MODS] %s = %s", g_titles[i], st);
	}
	console_print(id, "[FN] ok=%d degraded=%d missing=%d", ok, bad, miss);
	return PLUGIN_HANDLED;
}

public _status(plugin, params)
{
	new outlen = get_param(2);
	new ok = 0, bad = 0, miss = 0, st[32];
	for (new i = 0; i < g_mods; i++)
	{
		new r = modState(i, st, charsmax(st));
		if (r == 2)
			ok++;
		else if (r == 1)
			bad++;
		else
			miss++;
	}
	new buf[64];
	formatex(buf, charsmax(buf), "ok=%d degraded=%d missing=%d", ok, bad, miss);
	set_string(1, buf, outlen);
	return (bad > 0 || miss > 0) ? 0 : 1;
}
