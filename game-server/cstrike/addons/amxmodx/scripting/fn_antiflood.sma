// vim: set ts=4 sw=4 tw=99 noet:
//
// AMX Mod X, based on AMX Mod by Aleksander Naszko ("OLO").
// Copyright (C) The AMX Mod X Development Team.
//
// This software is licensed under the GNU General Public License, version 3 or higher.
// Additional exceptions apply. For full license details, see LICENSE.txt or visit:
//     https://alliedmods.net/amxmodx-license

//
// Anti Flood Plugin
//

#include <amxmodx>
#include <fn_core>
#include <fn_common>



native is_user_gagged(id)

stock bool:safeGagged(id)
{
	if (!LibraryExists("gagsystem", LibType_Library)) return false;
	return is_user_gagged(id) ? true : false;
}


new Float:g_Flooding[MAX_PLAYERS + 1] = {0.0, ...}
new g_Flood[MAX_PLAYERS + 1] = {0, ...}

new amx_flood_time;

public plugin_natives()
{
	set_native_filter("native_filter")
}

public native_filter(const name[], index, trap)
{
	if (!trap && (equal(name, "is_user_gagged") || contain(name, "fn_") == 0))
		return PLUGIN_HANDLED
	return PLUGIN_CONTINUE
}

public plugin_init()
{
	fn_boot_banner("antiflood", 3)

	register_plugin("Anti Flood", AMXX_VERSION_STR, "AMXX Dev Team")
	register_dictionary("antiflood.txt")
	register_clcmd("say", "chkFlood")
	register_clcmd("say_team", "chkFlood")
	amx_flood_time=register_cvar("amx_flood_time", "0.75")
	if (LibraryExists("fn_core", LibType_Library))
		fn_health_set("discipline.antiflood", "ok");
}

public chkFlood(id)
{
	if (safeGagged(id))
		return PLUGIN_HANDLED

	new Float:maxChat = get_pcvar_float(amx_flood_time)

	if (maxChat)
	{
		new Float:nexTime = get_gametime()
		
		if (g_Flooding[id] > nexTime)
		{
			if (g_Flood[id] >= 3)
			{
				client_print(id, print_notify, "** %L **", id, "STOP_FLOOD")
				new Float:extra = 3.0
				if (g_Flood[id] >= 8)
				{
					new name[MAX_NAME_LENGTH]
					get_user_name(id, name, charsmax(name))
					server_cmd("amx_gag #%d 5 ^"Chat flood spam^"", get_user_userid(id))
					client_print(0, print_chat, "[AMXX] %s was auto-gagged for 5 minutes (chat flood).", name)
					log_amx("AntiFlood: auto-gagged #%d (%s) for 5 minutes", get_user_userid(id), name)
					fn_safe_log(0, id, "flood.autogag", "5 min");
					g_Flood[id] = 0
					return PLUGIN_HANDLED
				}
				else if (g_Flood[id] >= 6)
					extra = 30.0
				else if (g_Flood[id] >= 4)
					extra = 5.0
				g_Flooding[id] = nexTime + maxChat + extra
				return PLUGIN_HANDLED
			}
			g_Flood[id]++
		}
		else if (g_Flood[id])
		{
			g_Flood[id]--
		}
		
		g_Flooding[id] = nexTime + maxChat
	}

	return PLUGIN_CONTINUE
}

public client_disconnected(id)
{
	g_Flooding[id] = 0.0
	g_Flood[id] = 0
}