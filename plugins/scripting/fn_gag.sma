// Gag / mute: chat + voice. Persists reconnect via nvault.

#include <amxmodx>
#include <amxmisc>
#include <engine>
#include <nvault>
#include <reapi_vtc>
#include <fn_core>
#include <fn_common>

#define TASK_UNGAG  55001

new g_vault
new g_until[MAX_PLAYERS + 1]
new bool:g_gagged[MAX_PLAYERS + 1]
new g_maxMinutes
new g_cvarVoice;
new g_mode[MAX_PLAYERS + 1]

public plugin_natives()
{
	set_native_filter("native_filter")
	register_library("gagsystem")
	register_native("is_user_gagged", "_is_user_gagged")
}

public native_filter(const name[], index, trap)
{
	if (!trap && (contain(name, "fn_") == 0 || contain(name, "VTC_") == 0))
		return PLUGIN_HANDLED
	return PLUGIN_CONTINUE
}

public _is_user_gagged(plugin, params)
{
	new id = get_param(1)
	if (id < 1 || id > MaxClients)
		return 0
	return g_gagged[id] && g_until[id] > get_systime()
}

public plugin_init()
{
	fn_boot_banner("gag", 10)

	register_plugin("Gag System", AMXX_VERSION_STR, "AMXX Dev Team")
	register_dictionary("common.txt")

	register_concmd("amx_gag", "cmdGag", ADMIN_CHAT, "<name|#userid> [minutes] - gag chat and voice")
	register_concmd("amx_ungag", "cmdUngag", ADMIN_CHAT, "<name|#userid> - remove gag")
	register_clcmd("amx_gagmenu", "cmdMenu", ADMIN_CHAT, "- gag menu")
	register_clcmd("say /gag", "cmdMenu", ADMIN_CHAT)
	register_clcmd("say_team /gag", "cmdMenu", ADMIN_CHAT)

	register_clcmd("say", "blockSay")
	register_clcmd("say_team", "blockSay")

	g_maxMinutes = register_cvar("amx_gag_max", "1440")
	g_cvarVoice = register_cvar("fn_gag_voice", "0");
	g_vault = nvault_open("gags")
	if (LibraryExists("fn_core", LibType_Library))
		fn_health_set("discipline.gag", "ok")
}

public plugin_end()
{
	if (g_vault != INVALID_HANDLE)
		nvault_close(g_vault)
}

public client_disconnected(id)
{
	remove_task(TASK_UNGAG + id)
	g_gagged[id] = false; g_mode[id] = 0
	g_until[id] = 0
	if (get_pcvar_num(g_cvarVoice) > 0) VTC_UnmuteClient(id);
}

public client_putinserver(id)
{
	restoreGag(id)
}

restoreGag(id)
{
	if (g_vault == INVALID_HANDLE || is_user_bot(id))
		return

	new auth[32], data[16]
	get_user_authid(id, auth, charsmax(auth))
	if (!auth[0] || equal(auth, "STEAM_ID_PENDING") || equal(auth, "STEAM_ID_LAN") || equal(auth, "VALVE_ID_LAN"))
		return

	new ts
	if (!nvault_lookup(g_vault, auth, data, charsmax(data), ts))
		return

	new until = str_to_num(data)
	if (until <= get_systime())
	{
		nvault_remove(g_vault, auth)
		return
	}

	applyGag(id, until)
}

applyGag(id, until, mode = 0)
{
	g_gagged[id] = true; g_mode[id] = mode
	g_until[id] = until
	if (mode != 1) set_speak(id, SPEAK_MUTED)
	if (get_pcvar_num(g_cvarVoice) > 0) VTC_MuteClient(id);

	remove_task(TASK_UNGAG + id)
	new remain = until - get_systime()
	if (remain < 1)
		remain = 1
	set_task(float(remain), "expireGag", TASK_UNGAG + id)
}

clearGag(id)
{
	remove_task(TASK_UNGAG + id)
	g_gagged[id] = false; g_mode[id] = 0
	g_until[id] = 0
	if (is_user_connected(id))
	{
		set_speak(id, SPEAK_NORMAL)
		if (get_pcvar_num(g_cvarVoice) > 0) VTC_UnmuteClient(id);
	}

	new auth[32]
	get_user_authid(id, auth, charsmax(auth))
	if (g_vault != INVALID_HANDLE && auth[0])
		nvault_remove(g_vault, auth)
}

public expireGag(taskid)
{
	new id = taskid - TASK_UNGAG
	if (!is_user_connected(id))
		return
	clearGag(id)
	client_print(id, print_chat, "[AMXX] Your gag expired.")
	fn_safe_log(0, id, "gag.expire", "")
}

public blockSay(id)
{
	if (!g_gagged[id] || g_mode[id] == 2)
		return PLUGIN_CONTINUE
	if (g_until[id] <= get_systime())
	{
		clearGag(id)
		return PLUGIN_CONTINUE
	}
	client_print(id, print_chat, "[AMXX] You are gagged (%d min left).", (g_until[id] - get_systime()) / 60)
	return PLUGIN_HANDLED
}

public cmdGag(id, level, cid)
{
	if (!cmd_access(id, level, cid, 2))
		return PLUGIN_HANDLED

	new arg[32], minsArg[16], modeArg[8]
	read_argv(1, arg, charsmax(arg))
	read_argv(2, minsArg, charsmax(minsArg)); read_argv(3, modeArg, charsmax(modeArg))

	new player;
	if (id == 0)
	{
		player = fn_resolve_target(arg, id);
		if (!player)
		{
			new hits[8], nm2[MAX_NAME_LENGTH];
			new nh = fn_resolve_list(arg, hits, 8, id);
			if (nh > 1)
			{
				console_print(id, "[AMXX] %d players match, be more specific:", nh);
				for (new si = 0; si < nh && si < 8; si++)
				{
					get_user_name(hits[si], nm2, charsmax(nm2));
					console_print(id, "  %s", nm2);
				}
			}
			else console_print(id, "[AMXX] No such player: %s", arg);
			return PLUGIN_HANDLED;
		}
	}
	else
	{
		player = cmd_target(id, arg, CMDTARGET_OBEY_IMMUNITY | CMDTARGET_NO_BOTS);
		if (!player)
			return PLUGIN_HANDLED;
	}
	if (!fn_safe_can_hit(id, player))
	{
		console_print(id, "[AMXX] Target outranks you.")
		return PLUGIN_HANDLED
	}
	if (get_user_flags(player) & ADMIN_IMMUNITY)
	{
		if (id != 0 && !(get_user_flags(id) & ADMIN_RCON))
		{
			console_print(id, "[AMXX] Target has immunity.")
			return PLUGIN_HANDLED
		}
	}

	new minutes = str_to_num(minsArg)
	if (minutes < 1)
		minutes = 15
	new maxMin = get_pcvar_num(g_maxMinutes)
	if (maxMin > 0 && minutes > maxMin)
		minutes = maxMin

	gagPlayer(id, player, minutes, str_to_num(modeArg))
	return PLUGIN_HANDLED
}

gagPlayer(admin, player, minutes, mode)
{
	new until = get_systime() + (minutes * 60)
	applyGag(player, until, mode)

	new auth[32]
	get_user_authid(player, auth, charsmax(auth))
	if (g_vault != INVALID_HANDLE && auth[0] && !equal(auth, "STEAM_ID_PENDING"))
	{
		new data[16]
		num_to_str(until, data, charsmax(data))
		nvault_set(g_vault, auth, data)
	}

	new name[MAX_NAME_LENGTH], aname[MAX_NAME_LENGTH]
	get_user_name(player, name, charsmax(name))
	get_user_name(admin, aname, charsmax(aname))
	client_print(0, print_chat, "[AMXX] %s gagged %s for %d minute(s).", aname, name, minutes)
	log_amx("Gag: %s gagged %s<%s> %d min", aname, name, auth, minutes); fn_safe_log(admin, player, "gag", "mode")
}

public cmdUngag(id, level, cid)
{
	if (!cmd_access(id, level, cid, 2))
		return PLUGIN_HANDLED

	new arg[32]
	read_argv(1, arg, charsmax(arg))
	new player;
	if (id == 0)
	{
		player = fn_resolve_target(arg, id);
		if (!player)
		{
			new hits[8], nm2[MAX_NAME_LENGTH];
			new nh = fn_resolve_list(arg, hits, 8, id);
			if (nh > 1)
			{
				console_print(id, "[AMXX] %d players match, be more specific:", nh);
				for (new si = 0; si < nh && si < 8; si++)
				{
					get_user_name(hits[si], nm2, charsmax(nm2));
					console_print(id, "  %s", nm2);
				}
			}
			else console_print(id, "[AMXX] No such player: %s", arg);
			return PLUGIN_HANDLED;
		}
	}
	else
	{
		player = cmd_target(id, arg, CMDTARGET_ALLOW_SELF | CMDTARGET_NO_BOTS);
		if (!player)
			return PLUGIN_HANDLED;
	}

	if (!fn_safe_can_hit(id, player)) { console_print(id, "[AMXX] Target outranks you."); return PLUGIN_HANDLED; }
	new name[MAX_NAME_LENGTH]
	get_user_name(player, name, charsmax(name))
	clearGag(player)
	console_print(id, "[AMXX] Ungagged %s.", name)
	fn_safe_log(id, player, "ungag", name)
	client_print(player, print_chat, "[AMXX] You were ungagged.")
	return PLUGIN_HANDLED
}

public cmdMenu(id, level, cid)
{
	if (!cmd_access(id, level, cid, 1))
		return PLUGIN_HANDLED
	showGagMenu(id)
	return PLUGIN_HANDLED
}

showGagMenu(id)
{
	new menu = menu_create("\yGag / Ungag\w", "menuGag")
	new players[MAX_PLAYERS], num, name[MAX_NAME_LENGTH], info[8]
	get_players(players, num, "ch")
	for (new i; i < num; i++)
	{
		new pl = players[i]
		get_user_name(pl, name, charsmax(name))
		if (g_gagged[pl] && g_until[pl] > get_systime())
			format(name, charsmax(name), "%s \r[gagged %d min]\w", name, (g_until[pl] - get_systime()) / 60)
		num_to_str(get_user_userid(pl), info, charsmax(info))
		menu_additem(menu, name, info)
	}
	menu_display(id, menu)
}

public menuGag(id, menu, item)
{
	if (item < 0)
	{
		menu_destroy(menu)
		return PLUGIN_HANDLED
	}
	new info[8], access, callback, dummy[1]
	menu_item_getinfo(menu, item, access, info, charsmax(info), dummy, 0, callback)
	menu_destroy(menu)

	new player = find_player("k", str_to_num(info))
	if (!player)
		return PLUGIN_HANDLED

	if (g_gagged[player] && g_until[player] > get_systime())
	{
		client_cmd(id, "amx_ungag #%d", get_user_userid(player))
		return PLUGIN_HANDLED
	}

	new times = menu_create("\yGag duration\w", "menuGagTime")
	new packed[16]
	formatex(packed, charsmax(packed), "%d 5", get_user_userid(player)); menu_additem(times, "5 minutes", packed)
	formatex(packed, charsmax(packed), "%d 15", get_user_userid(player)); menu_additem(times, "15 minutes", packed)
	formatex(packed, charsmax(packed), "%d 60", get_user_userid(player)); menu_additem(times, "60 minutes", packed)
	menu_display(id, times)
	return PLUGIN_HANDLED
}

public menuGagTime(id, menu, item)
{
	if (item < 0)
	{
		menu_destroy(menu)
		return PLUGIN_HANDLED
	}
	new info[16], access, callback, dummy[1], userStr[8], minStr[8]
	menu_item_getinfo(menu, item, access, info, charsmax(info), dummy, 0, callback)
	menu_destroy(menu)
	parse(info, userStr, charsmax(userStr), minStr, charsmax(minStr))
	client_cmd(id, "amx_gag #%s %s", userStr, minStr)
	return PLUGIN_HANDLED
}