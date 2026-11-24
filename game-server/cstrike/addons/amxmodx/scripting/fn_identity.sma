/* fn_identity: stable player identity + slot-reuse guard (3.0 M4). Slot ids
 * are recycled on every connect; this module tags each slot lifetime with a
 * generation counter so menu/action state can detect stale references.
 * Auth/IP snapshots are taken at authorize time (not per use). */
#include <amxmodx>
#include <fn_core>
#include <fn_common>

new g_gen[MAX_PLAYERS + 1];
new g_live[MAX_PLAYERS + 1];
new g_auth[MAX_PLAYERS + 1][32];
new g_ip[MAX_PLAYERS + 1][32];

public plugin_natives()
{
	set_native_filter("native_filter");
	register_library("fn_identity");
	register_native("fn_id_gen", "_gen");
	register_native("fn_id_same", "_same");
	register_native("fn_id_auth", "_auth");
	register_native("fn_id_ip", "_ip");
}

public native_filter(const name[], index, trap)
{
	if (!trap && contain(name, "fn_") == 0)
		return PLUGIN_HANDLED;
	return PLUGIN_CONTINUE;
}

public plugin_init()
{
	fn_boot_banner("identity", 4);

	register_plugin("FreeNova Identity", "3.0.0", "FreeNova");
	if (!LibraryExists("fn_core", LibType_Library))
	{
		log_amx("[FN-ID] fn_core missing, pausing self");
		pause("d");
		return;
	}
	fn_health_set("identity", "ok");
}

public client_connect(id)
{
	g_gen[id]++;
	g_live[id] = false;
	g_auth[id][0] = 0;
	g_ip[id][0] = 0;
}

public client_authorized(id)
{
	snap(id);
}

public client_putinserver(id)
{
	if (!g_auth[id][0])
		snap(id);
}

public client_disconnected(id)
{
	g_live[id] = false;
}

snap(id)
{
	if (id < 1 || id > MaxClients)
		return;
	if (!is_user_connected(id))
		return;
	get_user_authid(id, g_auth[id], charsmax(g_auth[]));
	get_user_ip(id, g_ip[id], charsmax(g_ip[]), 1);
	g_live[id] = true;
}

public _gen(plugin, params)
{
	new id = get_param(1);
	if (id < 1 || id > MaxClients)
		return 0;
	return g_gen[id];
}

public _same(plugin, params)
{
	new id = get_param(1);
	new gen = get_param(2);
	if (id < 1 || id > MaxClients)
		return 0;
	if (!g_live[id] || !is_user_connected(id))
		return 0;
	return g_gen[id] == gen ? 1 : 0;
}

public _auth(plugin, params)
{
	new id = get_param(1);
	new outlen = get_param(3);
	new tmp[32];
	if (id >= 1 && id <= MaxClients && g_live[id] && is_user_connected(id))
		copy(tmp, charsmax(tmp), g_auth[id]);
	else
		tmp[0] = 0;
	set_string(2, tmp, outlen);
	return tmp[0] ? 1 : 0;
}

public _ip(plugin, params)
{
	new id = get_param(1);
	new outlen = get_param(3);
	new tmp[32];
	if (id >= 1 && id <= MaxClients && g_live[id] && is_user_connected(id))
		copy(tmp, charsmax(tmp), g_ip[id]);
	else
		tmp[0] = 0;
	set_string(2, tmp, outlen);
	return tmp[0] ? 1 : 0;
}
