/* fn_maps: single map-stack router. Exactly one stack active per install.
 * Detects modern (manager+rtv) vs classic (chooser) and refuses dual-stack.
 * Extend + status here; rotation itself stays in the active stack plugin. */
#include <amxmodx>
#include <amxmisc>
#include <fn_core>
#include <fn_common>

new g_stack;
new g_voteActive;
new g_voteOrigin[32];
new g_voteStart;
new g_lastExtend;
new g_cvarVoteTimeout;
new g_cvarExtendCd;

public plugin_natives()
{
	register_library("fn_maps");
	set_native_filter("native_filter");
	register_native("fn_map_extend", "_map_extend");
	register_native("fn_nextmap_get", "_nextmap_get");
	register_native("fn_vote_active", "_vote_active");
	register_native("fn_vote_begin", "_vote_begin");
	register_native("fn_vote_end", "_vote_end");
	register_native("fn_vote_extend_ok", "_vote_extend_ok");
	register_native("fn_vote_extended", "_vote_extended");
}

public native_filter(const name[], index, trap)
{
	if (!trap && contain(name, "fn_") == 0)
		return PLUGIN_HANDLED;
	return PLUGIN_CONTINUE;
}

public plugin_init()
{
	fn_boot_banner("maps", 12);

	register_plugin("FreeNova Maps", "2.0.0", "FreeNova");
	register_concmd("fn_maps_status", "cmdStatus", ADMIN_MAP, "- active stack + next map");
	register_concmd("fn_extendmap", "cmdExtend", ADMIN_MAP, "<minutes> - extend via active stack");
	g_stack = register_cvar("fn_maps_stack", "0");
	g_cvarVoteTimeout = register_cvar("fn_vote_timeout", "180");
	g_cvarExtendCd = register_cvar("fn_extend_cooldown", "0");
	if (!LibraryExists("fn_core", LibType_Library))
	{
		log_amx("[FN-MAPS] fn_core missing, pausing self");
		pause("d");
		return;
	}
	fn_health_set("maps", "ok");
}

hasModern() { return get_cvar_pointer("amx_mapmanager_extend_max") != 0 && get_cvar_pointer("amx_rtv_ratio") != 0; }
hasClassic() { return get_cvar_pointer("amx_extendmap_max") != 0; }

public _map_extend(plugin, params)
{
	new mins = get_param(1);
	if (mins < 1 || mins > 90) return 0;
	if (voteExtendRemain() > 0) return 0;
	server_cmd("amx_extendmap %d", mins);
	g_lastExtend = get_systime();
	fn_safe_log(get_param(2), 0, "map.extend", "");
	return 1;
}

public plugin_cfg()
{
	g_voteActive = 0;
	g_voteOrigin[0] = 0;
}

/* M5 coordinator: single map-vote session with staleness expiry (classic
 * end-of-map votes close internally; without this, a lost end-signal
 * would block votes forever). Extend cooldown is opt-in (0 = off). */
refreshVote()
{
	if (!g_voteActive)
		return;
	new to = get_pcvar_num(g_cvarVoteTimeout);
	if (to < 30)
		to = 30;
	if (get_systime() - g_voteStart > to)
	{
		g_voteActive = 0;
		g_voteOrigin[0] = 0;
	}
}

public _vote_active(plugin, params)
{
	refreshVote();
	return g_voteActive;
}

public _vote_begin(plugin, params)
{
	new o[32];
	get_string(1, o, charsmax(o));
	refreshVote();
	if (g_voteActive)
		return 0;
	g_voteActive = 1;
	copy(g_voteOrigin, charsmax(g_voteOrigin), o);
	g_voteStart = get_systime();
	return 1;
}

public _vote_end(plugin, params)
{
	g_voteActive = 0;
	g_voteOrigin[0] = 0;
	return 1;
}

voteExtendRemain()
{
	new cd = get_pcvar_num(g_cvarExtendCd);
	if (cd <= 0)
		return 0;
	new left = cd - (get_systime() - g_lastExtend);
	return (left > 0) ? left : 0;
}

public _vote_extend_ok(plugin, params)
{
	return voteExtendRemain() > 0 ? 0 : 1;
}

public _vote_extended(plugin, params)
{
	g_lastExtend = get_systime();
	return 1;
}

public _nextmap_get(plugin, params)
{
	new outlen = get_param(2);
	new map[64];
	get_cvar_string("amx_nextmap", map, charsmax(map));
	set_string(1, map, outlen);
	return map[0] ? 1 : 0;
}

public cmdStatus(id, level, cid)
{
	if (!cmd_access(id, level, cid, 1)) return PLUGIN_HANDLED;
	new map[64], next[64];
	get_mapname(map, charsmax(map));
	get_cvar_string("amx_nextmap", next, charsmax(next));
	new modern = hasModern(), classic = hasClassic();
	console_print(id, "[FN] map=%s next=%s modern=%d classic=%d want=%d", map, next, modern, classic, get_pcvar_num(g_stack));
	if ((get_pcvar_num(g_stack) == 1 && !modern) || (get_pcvar_num(g_stack) == 2 && !classic))
		console_print(id, "[FN] WARNING: expected stack missing (0=auto,1=modern,2=classic)");
	if (modern && classic)
		console_print(id, "[FN] WARNING: dual map stacks detected (R3 violation)");
	refreshVote();
	console_print(id, "[FN] vote active=%d origin=%s age=%ds extend_cd_left=%ds", g_voteActive, g_voteOrigin, g_voteActive ? (get_systime() - g_voteStart) : 0, voteExtendRemain());
	return PLUGIN_HANDLED;
}

public cmdExtend(id, level, cid)
{
	if (!cmd_access(id, level, cid, 2)) return PLUGIN_HANDLED;
	new a[12];
	read_argv(1, a, charsmax(a));
	new mins = str_to_num(a);
	if (mins < 1 || mins > 90) { console_print(id, "[FN] minutes 1-90"); return PLUGIN_HANDLED; }
	if (voteExtendRemain() > 0) { console_print(id, "[FN] extend on cooldown (%ds left)", voteExtendRemain()); return PLUGIN_HANDLED; }
	server_cmd("amx_extendmap %d", mins);
	g_lastExtend = get_systime();
	fn_safe_log(id, 0, "map.extend", a);
	console_print(id, "[FN] map extended %d min", mins);
	return PLUGIN_HANDLED;
}