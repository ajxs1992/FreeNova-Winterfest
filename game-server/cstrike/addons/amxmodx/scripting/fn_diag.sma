/* fn_diag: one diagnostics surface. Aggregates core health store, backend and
 * guard presence, server facts. Never prints secrets. */
#include <amxmodx>
#include <amxmisc>
#include <fn_core>
#include <fn_common>

public plugin_natives()
{
	register_library("fn_diag");
	set_native_filter("native_filter");
	register_native("fn_health_status", "_health_status");
	register_native("fn_diag_dump", "_diag_dump");
}

public native_filter(const name[], index, trap)
{
	if (!trap && contain(name, "fn_") == 0)
		return PLUGIN_HANDLED;
	return PLUGIN_CONTINUE;
}

public plugin_init()
{
	fn_boot_banner("diag", 3);

	register_plugin("FreeNova Diagnostics", "2.0.0", "FreeNova");
	register_concmd("fn_status", "cmdStatus", ADMIN_ADMIN, "- framework health");
	if (!LibraryExists("fn_core", LibType_Library))
	{
		log_amx("[FN-DIAG] fn_core missing, pausing self");
		pause("d");
		return;
	}
	fn_health_set("diag", "ok");
}

public _health_status(plugin, params)
{
	new module[32], outlen = get_param(3);
	get_string(1, module, charsmax(module));
	static s[64];
	if (fn_health_get(module, s, charsmax(s))) { set_string(2, s, outlen); return 1; }
	set_string(2, "unknown", outlen);
	return 0;
}

public _diag_dump(plugin, params)
{
	dumpTo(0);
	return 1;
}

dumpTo(id)
{
	new mods[33][16];
	copy(mods[0], 15, "core"); copy(mods[1], 15, "roles");
	copy(mods[2], 15, "audit"); copy(mods[3], 15, "bans");
	copy(mods[4], 15, "menus"); copy(mods[5], 15, "maps");
	copy(mods[6], 15, "guard"); copy(mods[7], 15, "sync");
	copy(mods[8], 15, "diag"); copy(mods[9], 15, "discipline.gag");
	copy(mods[10], 15, "moderation"); copy(mods[11], 15, "chat");
	copy(mods[12], 15, "perms"); copy(mods[13], 15, "identity"); copy(mods[14], 15, "state");
	copy(mods[15], 15, "doctor"); copy(mods[16], 15, "mods"); copy(mods[17], 15, "perf");
	copy(mods[18], 15, "admin"); copy(mods[19], 15, "pinfo"); copy(mods[20], 15, "reports");
	copy(mods[21], 15, "settings"); copy(mods[22], 15, "welcome"); copy(mods[23], 15, "servers");
	copy(mods[24], 15, "spectate"); copy(mods[25], 15, "afk"); copy(mods[26], 15, "reconnect");
	copy(mods[27], 15, "hud"); copy(mods[28], 15, "policy"); copy(mods[29], 15, "limits");
	copy(mods[30], 15, "modes"); copy(mods[31], 15, "match");
	copy(mods[32], 15, "link");
	for (new i = 0; i < 33; i++)
	{
		static s[64];
		if (!fn_health_get(mods[i], s, charsmax(s))) copy(s, charsmax(s), "unknown");
		if (id > 0) console_print(id, "[FN] %-14s %s", mods[i], s);
		else log_amx("[FN] %-14s %s", mods[i], s);
	}
	new map[64], players[32], num;
	get_mapname(map, charsmax(map));
	get_players(players, num, "ch");
	if (id > 0) console_print(id, "[FN] map=%s players=%d/%d ab=%d guard=%d", map, num, get_maxplayers(), get_cvar_pointer("ab_website") != 0, get_cvar_pointer("bypass_guard_enabled") != 0);
	else log_amx("[FN] map=%s players=%d ab=%d guard=%d", map, num, get_cvar_pointer("ab_website") != 0, get_cvar_pointer("bypass_guard_enabled") != 0);
}

public cmdStatus(id, level, cid)
{
	if (!cmd_access(id, level, cid, 1)) return PLUGIN_HANDLED;
	console_print(id, "[FN] core v%d", fn_core_version());
	dumpTo(id);
	return PLUGIN_HANDLED;
}