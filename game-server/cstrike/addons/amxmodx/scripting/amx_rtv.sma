// RTV + extend chat commands. Uses mapchooser / mapmanager.

#include <amxmodx>
#include <amxmisc>
#include <fn_maps>

new g_rtv[MAX_PLAYERS + 1]
new g_ratio
new g_minPlayers
new bool:g_done

public plugin_natives()
{
	set_native_filter("native_filter");
}
public native_filter(const name[], index, trap)
{
	if (!trap && contain(name, "fn_") == 0)
		return PLUGIN_HANDLED;
	return PLUGIN_CONTINUE;
}

public plugin_init()
{
	register_plugin("Map RTV", AMXX_VERSION_STR, "AMXX Dev Team")
	register_clcmd("say rtv", "cmdRtv")
	register_clcmd("say /rtv", "cmdRtv")
	register_clcmd("say rockthevote", "cmdRtv")
	register_clcmd("say /extend", "cmdExtend")
	g_ratio = register_cvar("amx_rtv_ratio", "0.60")
	g_minPlayers = register_cvar("amx_rtv_minplayers", "3")
}

public client_disconnected(id)
{
	g_rtv[id] = 0
}

public cmdRtv(id)
{
	if (g_done)
	{
		client_print(id, print_chat, "[AMXX] Map vote already started.")
		return PLUGIN_HANDLED
	}
	new players[MAX_PLAYERS], num
	get_players(players, num, "ch")
	if (num < get_pcvar_num(g_minPlayers))
	{
		client_print(id, print_chat, "[AMXX] Need at least %d players for RTV.", get_pcvar_num(g_minPlayers))
		return PLUGIN_HANDLED
	}
	if (g_rtv[id])
	{
		client_print(id, print_chat, "[AMXX] You already voted to rock the vote.")
		return PLUGIN_HANDLED
	}
	g_rtv[id] = 1
	new votes
	for (new i = 1; i <= MaxClients; i++)
		if (g_rtv[i]) votes++
	new need = floatround(float(num) * get_pcvar_float(g_ratio), floatround_ceil)
	if (need < 1) need = 1
	new name[MAX_NAME_LENGTH]
	get_user_name(id, name, charsmax(name))
	client_print(0, print_chat, "[AMXX] %s wants to rock the vote (%d/%d).", name, votes, need)
	if (votes >= need)
		startVote()
	return PLUGIN_HANDLED
}

/* NOTE (M1): vote entry lives in mapchooser (classic stack) only; on the
 * modern stack (mapmanager, no mapchooser) a passed RTV ends here with a
 * message instead of a vote. Classic-only by design until fn_maps owns
 * voting sessions (M5). */
startVote()
{
	g_done = true
	client_print(0, print_chat, "[AMXX] RTV passed. Starting map vote...")
	if (LibraryExists("fn_maps", LibType_Library) && !fn_vote_begin("rtv"))
	{
		client_print(0, print_chat, "[AMXX] A map vote is already running.");
		return;
	}
	new plugin = is_plugin_loaded("Nextmap Chooser")
	if (plugin != -1)
		callfunc_begin("voteNextmap", "mapchooser.amxx") == 1 ? callfunc_end() : 0
	else
		client_print(0, print_chat, "[AMXX] mapchooser is not loaded.")
}

public cmdExtend(id)
{
	if (!(get_user_flags(id) & ADMIN_MAP))
	{
		client_print(id, print_chat, "[AMXX] Admins only. Use RTV to vote.")
		return PLUGIN_HANDLED
	}
	client_cmd(id, "amx_mapmanager")
	return PLUGIN_HANDLED
}