/* fn_reconnect: session ledger + safe team restore (3.0 M8). nvault
 * "fn_sessions": authid -> visits count; team holds authid -> team|map|time.
 * Restores TEAM ONLY (never weapons/money/health/alive - spawn logic owns
 * those), only to a stored T/CT team, only on the same map, only when the
 * joiner is still unassigned/spec, and only with fn_reconnect_team 1
 * (default 0 = ledger only). */
#include <amxmodx>
#include <amxmisc>
#include <cstrike>
#include <nvault>
#include <fn_core>
#include <fn_common>

#define RCTASK 90510

new g_vaultSess;
new g_cvarTeam;

public plugin_natives()
{
	set_native_filter("native_filter");
	register_library("fn_reconnect");
	register_native("fn_reconnect_visits", "_visits");
}

public native_filter(const name[], index, trap)
{
	if (!trap && contain(name, "fn_") == 0)
		return PLUGIN_HANDLED;
	return PLUGIN_CONTINUE;
}

public plugin_init()
{
	fn_boot_banner("reconnect", 2);

	register_plugin("FreeNova Reconnect", "3.0.0", "FreeNova");
	g_cvarTeam = register_cvar("fn_reconnect_team", "0");
	if (!LibraryExists("fn_core", LibType_Library))
	{
		log_amx("[FN-RECONNECT] fn_core missing, pausing self");
		pause("d");
		return;
	}
	g_vaultSess = nvault_open("fn_sessions");
	fn_health_set("reconnect", "ok");
}

public plugin_end()
{
	if (g_vaultSess != INVALID_HANDLE)
		nvault_close(g_vaultSess);
}

public client_authorized(id)
{
	if (is_user_bot(id) || is_user_hltv(id))
		return;
	new auth[32];
	get_user_authid(id, auth, charsmax(auth));
	if (!auth[0] || equal(auth, "STEAM_ID_PENDING") || contain(auth, "LAN") != -1)
		return;
	if (g_vaultSess == INVALID_HANDLE)
		return;
	new data[16], ts;
	new n = 0;
	if (nvault_lookup(g_vaultSess, auth, data, charsmax(data), ts))
		n = str_to_num(data);
	n++;
	num_to_str(n, data, charsmax(data));
	nvault_set(g_vaultSess, auth, data);
}

public client_disconnected(id)
{
	remove_task(RCTASK + id);
	if (is_user_bot(id) || is_user_hltv(id))
		return;
	new auth[32];
	get_user_authid(id, auth, charsmax(auth));
	if (!auth[0] || equal(auth, "STEAM_ID_PENDING") || contain(auth, "LAN") != -1)
		return;
	if (g_vaultSess == INVALID_HANDLE)
		return;
	new team = _:cs_get_user_team(id);
	if (team != _:CS_TEAM_T && team != _:CS_TEAM_CT)
		return;
	new map[32];
	get_mapname(map, charsmax(map));
	new key[64], val[64];
	formatex(key, charsmax(key), "%s|team", auth);
	formatex(val, charsmax(val), "%d|%s|%d", team, map, get_systime());
	nvault_set(g_vaultSess, key, val);
}

public client_putinserver(id)
{
	if (is_user_bot(id) || is_user_hltv(id))
		return;
	remove_task(RCTASK + id);
	set_task(3.0, "maybeRestore", RCTASK + id);
}

public maybeRestore(taskid)
{
	new id = taskid - RCTASK;
	if (id < 1 || id > MaxClients || !is_user_connected(id))
		return;
	if (!get_pcvar_num(g_cvarTeam))
		return;
	new cur = _:cs_get_user_team(id);
	if (cur == _:CS_TEAM_T || cur == _:CS_TEAM_CT)
		return;
	new auth[32];
	get_user_authid(id, auth, charsmax(auth));
	if (!auth[0] || g_vaultSess == INVALID_HANDLE)
		return;
	new key[64], val[64], ts;
	formatex(key, charsmax(key), "%s|team", auth);
	if (!nvault_lookup(g_vaultSess, key, val, charsmax(val), ts))
		return;
	new ts_[4][32];
	parse(val, ts_[0], 31, ts_[1], 31, ts_[2], 31);
	new team = str_to_num(ts_[0]);
	if (team != _:CS_TEAM_T && team != _:CS_TEAM_CT)
		return;
	new map[32];
	get_mapname(map, charsmax(map));
	if (!equal(map, ts_[1]))
		return;
	if (team == _:CS_TEAM_T)
		cs_set_user_team(id, CS_TEAM_T);
	else
		cs_set_user_team(id, CS_TEAM_CT);
	fn_safe_log(0, id, "reconnect.team", ts_[1]);
}

public _visits(plugin, params)
{
	new auth[40];
	get_string(1, auth, charsmax(auth));
	if (!auth[0] || g_vaultSess == INVALID_HANDLE)
		return 0;
	new data[16], ts;
	if (!nvault_lookup(g_vaultSess, auth, data, charsmax(data), ts))
		return 0;
	return str_to_num(data);
}
