// Ghostchat: dead/spec/HLTV can read (and optionally talk to) the living.

#include <amxmodx>
#include <amxmisc>
#include <reapi>
#include <fn_chat>

#define MODE_OFF     0
#define MODE_DEAD    1
#define MODE_BOTH    2
#define MODE_HLTV    3

native is_user_gagged(id)

new g_mode
new g_teamChat
new g_alltalk

public plugin_natives()
{
	set_native_filter("native_filter")
}

public native_filter(const name[], index, trap)
{
	if (!trap && equal(name, "is_user_gagged"))
		return PLUGIN_HANDLED
	return PLUGIN_CONTINUE
}

public plugin_init()
{
	register_plugin("Ghostchat", AMXX_VERSION_STR, "AMXX Dev Team")

	// cvar name must NOT equal the concmd name ("amx_ghostchat"): an existing
	// engine cvar is resolved before AMXX's command hook and swallows the command.
	g_mode = register_cvar("amx_ghostchat_mode", "1")
	g_teamChat = register_cvar("amx_ghostchat_team", "1")
	g_alltalk = get_cvar_pointer("sv_alltalk")

	register_clcmd("say", "handleSay")
	register_clcmd("say_team", "handleTeamSay")
	register_concmd("amx_ghostchat", "cmdGhost", ADMIN_CHAT, "<0-3> - 0 off, 1 dead hear alive, 2 both, 3 HLTV only")
	register_clcmd("amx_ghostchatmenu", "cmdMenu", ADMIN_CHAT, "- ghostchat modes")
	register_clcmd("say /ghostchat", "cmdMenu", ADMIN_CHAT)
}

public plugin_cfg()
{
	set_task(0.5, "addFront")
}

public addFront()
{
	AddMenuItem("Ghostchat", "amx_ghostchatmenu", ADMIN_CHAT, "Ghostchat")
}

public cmdGhost(id, level, cid)
{
	if (read_argc() < 2)
	{
		printStatus(id)
		if (id == 0 || (get_user_flags(id) & ADMIN_CHAT))
			console_print(id, "[AMXX] Usage: amx_ghostchat 0(off) 1(dead hear alive) 2(dead+alive) 3(HLTV only)")
		return PLUGIN_HANDLED
	}

	if (!cmd_access(id, level, cid, 2))
		return PLUGIN_HANDLED

	new arg[8]
	read_argv(1, arg, charsmax(arg))
	new mode = str_to_num(arg)
	if (mode < MODE_OFF || mode > MODE_HLTV)
	{
		console_print(id, "[AMXX] Mode must be 0-3.")
		return PLUGIN_HANDLED
	}

	set_pcvar_num(g_mode, mode)
	announceMode(mode)
	log_amx("Ghostchat mode %d by #%d", mode, id)
	return PLUGIN_HANDLED
}

public cmdMenu(id, level, cid)
{
	if (!cmd_access(id, level, cid, 1))
		return PLUGIN_HANDLED

	new menu = menu_create("\yGhostchat\w", "menuGhost")
	new mode = get_pcvar_num(g_mode)
	new team = get_pcvar_num(g_teamChat)
	new line[64]
	formatex(line, charsmax(line), "Off%s", mode == MODE_OFF ? " \y*\w" : "")
	menu_additem(menu, line, "0")
	formatex(line, charsmax(line), "Dead/spec hear alive%s", mode == MODE_DEAD ? " \y*\w" : "")
	menu_additem(menu, line, "1")
	formatex(line, charsmax(line), "Dead and alive hear each other%s", mode == MODE_BOTH ? " \y*\w" : "")
	menu_additem(menu, line, "2")
	formatex(line, charsmax(line), "HLTV hears alive%s", mode == MODE_HLTV ? " \y*\w" : "")
	menu_additem(menu, line, "3")
	formatex(line, charsmax(line), "Relay team chat: %s", team ? "ON" : "OFF")
	menu_additem(menu, line, "team")
	menu_display(id, menu)
	return PLUGIN_HANDLED
}

public menuGhost(id, menu, item)
{
	if (item < 0)
	{
		menu_destroy(menu)
		return PLUGIN_HANDLED
	}
	new info[8], dummy[1]
	menu_item_getinfo(menu, item, dummy[0], info, charsmax(info), dummy, 0, dummy[0])
	menu_destroy(menu)

	if (equal(info, "team"))
	{
		new team = !get_pcvar_num(g_teamChat)
		set_pcvar_num(g_teamChat, team)
		client_print(id, print_chat, "[AMXX] Ghostchat team relay is now %s.", team ? "ON" : "OFF")
	}
	else
	{
		new mode = str_to_num(info)
		set_pcvar_num(g_mode, mode)
		announceMode(mode)
	}
	cmdMenu(id, ADMIN_CHAT, 0)
	return PLUGIN_HANDLED
}

printStatus(id)
{
	new status[64]
	modeName(get_pcvar_num(g_mode), status, charsmax(status))
	console_print(id, "[AMXX] Ghostchat: %s | team relay: %s", status, get_pcvar_num(g_teamChat) ? "ON" : "OFF")
	client_print(id, print_chat, "[AMXX] Ghostchat: %s", status)
}

announceMode(mode)
{
	new status[64]
	modeName(mode, status, charsmax(status))
	client_print(0, print_chat, "[AMXX] Ghostchat: %s", status)
}

modeName(mode, out[], len)
{
	switch (mode)
	{
		case MODE_DEAD: copy(out, len, "Dead/spec can read alive chat")
		case MODE_BOTH: copy(out, len, "Dead and alive can read each other")
		case MODE_HLTV: copy(out, len, "HLTV can read alive chat")
		default: copy(out, len, "Disabled")
	}
}

public handleSay(id)
{
	return relayChat(id, false)
}

public handleTeamSay(id)
{
	if (!get_pcvar_num(g_teamChat))
		return PLUGIN_CONTINUE
	return relayChat(id, true)
}

relayChat(id, bool:team)
{
	new mode = get_pcvar_num(g_mode)
	if (mode <= MODE_OFF)
		return PLUGIN_CONTINUE
	if (!is_user_connected(id) || is_user_bot(id))
		return PLUGIN_CONTINUE
	if (LibraryExists("fn_chat", LibType_Library))
	{
		if (!fn_chat_can_speak(id))
			return PLUGIN_CONTINUE;
	}
	else if (is_user_gagged(id))
		return PLUGIN_CONTINUE;

	new said[128]
	read_args(said, charsmax(said))
	remove_quotes(said)
	trim(said)
	if (!said[0] || said[0] == '/' || said[0] == '@' || said[0] == '!')
		return PLUGIN_CONTINUE

	new bool:alive = bool:is_user_alive(id)
	new TeamName:senderTeam = get_member(id, m_iTeam)
	new name[MAX_NAME_LENGTH], msg[192], stateTag[8]
	get_user_name(id, name, charsmax(name))
	if (alive)
		copy(stateTag, charsmax(stateTag), "ALIVE")
	else if (senderTeam == TEAM_SPECTATOR || senderTeam == TEAM_UNASSIGNED)
		copy(stateTag, charsmax(stateTag), "SPEC")
	else
		copy(stateTag, charsmax(stateTag), "DEAD")

	if (team)
		formatex(msg, charsmax(msg), "^4[G] ^3*%s* (TEAM) %s^1 :  %s", stateTag, name, said)
	else
		formatex(msg, charsmax(msg), "^4[G] ^3*%s* %s^1 :  %s", stateTag, name, said)

	new alltalk = g_alltalk ? get_pcvar_num(g_alltalk) : 0
	for (new i = 1; i <= MaxClients; i++)
	{
		if (i == id || !is_user_connected(i) || is_user_bot(i))
			continue
		if (!shouldRelay(mode, alive, bool:is_user_alive(i), is_user_hltv(i), alltalk))
			continue
		if (team && get_member(i, m_iTeam) != senderTeam)
			continue
		client_print_color(i, id, "%s", msg)
	}
	return PLUGIN_CONTINUE
}

bool:shouldRelay(mode, bool:senderAlive, bool:recvAlive, recvHltv, alltalk)
{
	if (alltalk && mode != MODE_HLTV)
		return false

	if (senderAlive && !recvAlive)
	{
		if (mode == MODE_HLTV)
			return recvHltv != 0
		return mode == MODE_DEAD || mode == MODE_BOTH
	}

	if (!senderAlive && recvAlive)
		return mode == MODE_BOTH

	return false
}
