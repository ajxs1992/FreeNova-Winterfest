/* fn_settings: player preferences (3.0 M7). v1 owns the "welcome" toggle
 * (consumed by fn_welcome) and links language to the multilingual menu
 * (single owner, no duplication). HUD/sound/frequency prefs belong to the
 * M8 HUD manager; storing toggles no consumer reads would be dead state.
 * Keyed by authid; pending/LAN/bot IDs are session-only by policy. */
#include <amxmodx>
#include <amxmisc>
#include <nvault>
#include <fn_core>
#include <fn_common>

new g_vaultPrefs;

public plugin_natives()
{
	set_native_filter("native_filter");
	register_library("fn_settings");
	register_native("fn_pref_get", "_get");
	register_native("fn_pref_set", "_set");
}

public native_filter(const name[], index, trap)
{
	if (!trap && contain(name, "fn_") == 0)
		return PLUGIN_HANDLED;
	return PLUGIN_CONTINUE;
}

public plugin_init()
{
	fn_boot_banner("settings", 4);

	register_plugin("FreeNova Settings", "3.0.0", "FreeNova");
	register_clcmd("amx_settings", "cmdSettings", ADMIN_ALL, "- your preferences");
	register_clcmd("say /settings", "cmdSettings", ADMIN_ALL);
	if (!LibraryExists("fn_core", LibType_Library))
	{
		log_amx("[FN-SETTINGS] fn_core missing, pausing self");
		pause("d");
		return;
	}
	g_vaultPrefs = nvault_open("fn_prefs");
	fn_health_set("settings", "ok");
}

public plugin_end()
{
	if (g_vaultPrefs != INVALID_HANDLE)
		nvault_close(g_vaultPrefs);
}

stableId(id, auth[], len)
{
	if (id < 1 || id > MaxClients || !is_user_connected(id) || is_user_bot(id))
		return 0;
	get_user_authid(id, auth, len);
	if (!auth[0] || equal(auth, "STEAM_ID_PENDING") || contain(auth, "LAN") != -1)
		return 0;
	return 1;
}

public cmdSettings(id, level, cid)
{
	if (!cmd_access(id, level, cid, 1))
		return PLUGIN_HANDLED;
	new menu = menu_create("\ySettings\w", "setH");
	menu_additem(menu, "Welcome messages: toggle", "welcome");
	menu_additem(menu, "Language...", "lang");
	menu_display(id, menu);
	return PLUGIN_HANDLED;
}

public setH(id, menu, item)
{
	if (item < 0)
	{
		menu_destroy(menu);
		return PLUGIN_HANDLED;
	}
	new info[16], access, callback, dummy[1];
	menu_item_getinfo(menu, item, access, info, charsmax(info), dummy, 0, callback);
	menu_destroy(menu);
	if (equal(info, "welcome"))
	{
		new cur[8];
		prefGet(id, "welcome", cur, charsmax(cur));
		new on = !equal(cur, "0");
		prefSet(id, "welcome", on ? "0" : "1");
		client_print(id, print_chat, "[FN] welcome messages %s.", on ? "OFF" : "ON");
	}
	else if (equal(info, "lang"))
		client_cmd(id, "amx_langmenu");
	return PLUGIN_HANDLED;
}

prefGet(id, const key[], out[], len)
{
	new auth[32];
	if (!stableId(id, auth, charsmax(auth)) || g_vaultPrefs == INVALID_HANDLE)
	{
		copy(out, len, "");
		return 0;
	}
	new data[128], ts, k[64];
	formatex(k, charsmax(k), "%s|%s", auth, key);
	if (!nvault_lookup(g_vaultPrefs, k, data, charsmax(data), ts))
	{
		copy(out, len, "");
		return 0;
	}
	copy(out, len, data);
	return 1;
}

prefSet(id, const key[], const val[])
{
	new auth[32];
	if (!stableId(id, auth, charsmax(auth)) || g_vaultPrefs == INVALID_HANDLE)
		return 0;
	new k[64];
	formatex(k, charsmax(k), "%s|%s", auth, key);
	nvault_set(g_vaultPrefs, k, val);
	return 1;
}

public _get(plugin, params)
{
	new id = get_param(1);
	new key[32], outlen = get_param(4);
	get_string(2, key, charsmax(key));
	new auth[32];
	if (!stableId(id, auth, charsmax(auth)) || g_vaultPrefs == INVALID_HANDLE)
	{
		set_string(3, "", outlen);
		return 0;
	}
	new data[128], ts, k[64];
	formatex(k, charsmax(k), "%s|%s", auth, key);
	if (!nvault_lookup(g_vaultPrefs, k, data, charsmax(data), ts))
	{
		set_string(3, "", outlen);
		return 0;
	}
	set_string(3, data, outlen);
	return 1;
}

public _set(plugin, params)
{
	new id = get_param(1);
	new key[32], val[64];
	get_string(2, key, charsmax(key));
	get_string(3, val, charsmax(val));
	if (!key[0])
		return 0;
	new auth[32];
	if (!stableId(id, auth, charsmax(auth)) || g_vaultPrefs == INVALID_HANDLE)
		return 0;
	new k[64];
	formatex(k, charsmax(k), "%s|%s", auth, key);
	nvault_set(g_vaultPrefs, k, val);
	return 1;
}
