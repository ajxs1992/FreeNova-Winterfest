// High ping kicker: toggle, threshold, warnings, immunity. ReAPI drop.

#include <amxmodx>
#include <amxmisc>
#include <reapi>
#include <fn_common>

#define TASK_CHECK  87001
#define MAX_WARN    5

new g_cvarEnabled
new g_cvarMaxPing
new g_cvarMaxLoss
new g_cvarChecks
new g_cvarInterval
new g_cvarImmunity
new g_cvarMinPlayers
new g_cvarNotify

new g_warn[MAX_PLAYERS + 1]
new Float:g_nextWarn[MAX_PLAYERS + 1]

public plugin_init()
{
	fn_boot_banner("pingkick", 15)

	register_plugin("High Ping Kicker", AMXX_VERSION_STR, "AMXX Dev Team")

	// cvar names must NOT equal concmd names: GoldSrc resolves an existing
	// engine cvar BEFORE AMXX's command hook, so a same-name cvar silently
	// swallows the command ("on" rejected as non-numeric, no handler runs).
	g_cvarEnabled = register_cvar("amx_pingkicker_enabled", "0", FCVAR_PROTECTED)
	g_cvarMaxPing = register_cvar("amx_pingkicker_maxping", "200", FCVAR_PROTECTED)
	g_cvarMaxLoss = register_cvar("amx_pingkicker_maxloss", "0", FCVAR_PROTECTED)
	g_cvarChecks = register_cvar("amx_pingkicker_checks", "3", FCVAR_PROTECTED)
	g_cvarInterval = register_cvar("amx_pingkicker_interval", "10.0", FCVAR_PROTECTED)
	g_cvarImmunity = register_cvar("amx_pingkicker_immunity", "1", FCVAR_PROTECTED)
	g_cvarMinPlayers = register_cvar("amx_pingkicker_minplayers", "1", FCVAR_PROTECTED)
	g_cvarNotify = register_cvar("amx_pingkicker_notify", "1", FCVAR_PROTECTED)

	register_concmd("amx_pingkicker", "cmdToggle", ADMIN_KICK, "<0|1|on|off> - enable or disable ping kicker")
	register_concmd("amx_maxping", "cmdMaxPing", ADMIN_KICK, "<ms> - set max allowed ping")
	register_concmd("amx_maxloss", "cmdMaxLoss", ADMIN_KICK, "<percentage> - set max allowed loss (0 = off)")
	register_clcmd("amx_pingmenu", "cmdMenu", ADMIN_KICK, "- ping kicker settings")
	register_clcmd("say /pingkicker", "cmdMenu", ADMIN_KICK)
	register_clcmd("say /maxping", "cmdStatus")
	register_clcmd("say_team /maxping", "cmdStatus")
}

public plugin_cfg()
{
	new Float:interval = get_pcvar_float(g_cvarInterval)
	if (interval < 5.0)
		interval = 5.0
	set_task(interval, "checkPings", TASK_CHECK, "", 0, "b")
	set_task(0.4, "addFront")
}

public addFront()
{
	AddMenuItem("Ping Kicker", "amx_pingmenu", ADMIN_KICK, "High Ping Kicker")
}

public client_disconnected(id)
{
	g_warn[id] = 0
	g_nextWarn[id] = 0.0
}

public cmdStatus(id)
{
	new enabled = get_pcvar_num(g_cvarEnabled)
	new maxping = get_pcvar_num(g_cvarMaxPing)
	new maxloss = get_pcvar_num(g_cvarMaxLoss)
	if (maxping < 50)
		maxping = 50
	if (maxloss > 0)
		client_print(id, print_chat, "[AMXX] Ping kicker is %s. Max ping: %d ms | Max loss: %d%%.", enabled ? "ON" : "OFF", maxping, maxloss)
	else
		client_print(id, print_chat, "[AMXX] Ping kicker is %s. Max ping: %d ms.", enabled ? "ON" : "OFF", maxping)
	return PLUGIN_HANDLED
}

public cmdMaxLoss(id, level, cid)
{
	if (!cmd_access(id, level, cid, 2))
		return PLUGIN_HANDLED

	new arg[16]
	read_argv(1, arg, charsmax(arg))
	new value = clamp(str_to_num(arg), 0, 100)
	set_pcvar_num(g_cvarMaxLoss, value)
	if (value > 0)
		client_print(0, print_chat, "[AMXX] Max loss set to %d%%.", value)
	else
		client_print(0, print_chat, "[AMXX] Loss checking disabled.")
	log_amx("PingKicker: max loss %d by #%d", value, id)
	return PLUGIN_HANDLED
}

public cmdToggle(id, level, cid)
{
	if (!cmd_access(id, level, cid, 2))
		return PLUGIN_HANDLED

	new arg[16]
	read_argv(1, arg, charsmax(arg))

	new enable
	if (equali(arg, "on") || equal(arg, "1"))
		enable = 1
	else if (equali(arg, "off") || equal(arg, "0"))
		enable = 0
	else
	{
		console_print(id, "[AMXX] Usage: amx_pingkicker <0|1|on|off>")
		return PLUGIN_HANDLED
	}

	set_pcvar_num(g_cvarEnabled, enable)
	announceState(id, enable)
	return PLUGIN_HANDLED
}

public cmdMaxPing(id, level, cid)
{
	if (!cmd_access(id, level, cid, 2))
		return PLUGIN_HANDLED

	new arg[16]
	read_argv(1, arg, charsmax(arg))
	new value = str_to_num(arg)
	if (value < 50 || value > 999)
	{
		console_print(id, "[AMXX] Max ping must be 50-999.")
		return PLUGIN_HANDLED
	}

	set_pcvar_num(g_cvarMaxPing, value)
	client_print(0, print_chat, "[AMXX] Max ping set to %d ms.", value)
	log_amx("PingKicker: max ping %d by #%d", value, id)
	return PLUGIN_HANDLED
}

announceState(id, enable)
{
	client_print(0, print_chat, "[AMXX] High ping kicker is now %s (max %d ms).", enable ? "ON" : "OFF", get_pcvar_num(g_cvarMaxPing))
	log_amx("PingKicker: %s by #%d", enable ? "enabled" : "disabled", id)
}

public cmdMenu(id, level, cid)
{
	if (!cmd_access(id, level, cid, 1))
		return PLUGIN_HANDLED
	showMenu(id)
	return PLUGIN_HANDLED
}

showMenu(id)
{
	new enabled = get_pcvar_num(g_cvarEnabled)
	new maxping = clampPing(get_pcvar_num(g_cvarMaxPing))
	new checks = clampChecks(get_pcvar_num(g_cvarChecks))
	new immunity = get_pcvar_num(g_cvarImmunity)
	new title[64]
	formatex(title, charsmax(title), "\yPing Kicker\w")
	new menu = menu_create(title, "menuPing")

	new line[64]
	formatex(line, charsmax(line), "Status: %s", enabled ? "\yON\w" : "\rOFF\w")
	menu_additem(menu, line, "toggle")
	formatex(line, charsmax(line), "Max ping: %d ms", maxping)
	menu_additem(menu, line, "ping")
	formatex(line, charsmax(line), "Warnings before kick: %d", checks)
	menu_additem(menu, line, "warn")
	formatex(line, charsmax(line), "Admin immunity: %s", immunity ? "ON" : "OFF")
	menu_additem(menu, line, "imm")
	menu_additem(menu, "Set max ping 150", "p150")
	menu_additem(menu, "Set max ping 200", "p200")
	menu_additem(menu, "Set max ping 250", "p250")
	menu_additem(menu, "Set max ping 300", "p300")
	menu_display(id, menu)
}

public menuPing(id, menu, item)
{
	if (item < 0)
	{
		menu_destroy(menu)
		return PLUGIN_HANDLED
	}

	new info[8], dummy[1]
	menu_item_getinfo(menu, item, dummy[0], info, charsmax(info), dummy, 0, dummy[0])
	menu_destroy(menu)

	if (equal(info, "toggle"))
	{
		new enable = !get_pcvar_num(g_cvarEnabled)
		set_pcvar_num(g_cvarEnabled, enable)
		announceState(id, enable)
	}
	else if (equal(info, "ping"))
	{
		new value = clampPing(get_pcvar_num(g_cvarMaxPing) + 50)
		if (value > 400)
			value = 100
		set_pcvar_num(g_cvarMaxPing, value)
		client_print(id, print_chat, "[AMXX] Max ping set to %d ms.", value)
	}
	else if (equal(info, "warn"))
	{
		new checks = clampChecks(get_pcvar_num(g_cvarChecks) + 1)
		if (checks > MAX_WARN)
			checks = 1
		set_pcvar_num(g_cvarChecks, checks)
		client_print(id, print_chat, "[AMXX] Warnings before kick: %d.", checks)
	}
	else if (equal(info, "imm"))
	{
		new immunity = !get_pcvar_num(g_cvarImmunity)
		set_pcvar_num(g_cvarImmunity, immunity)
		client_print(id, print_chat, "[AMXX] Admin immunity is now %s.", immunity ? "ON" : "OFF")
	}
	else if (info[0] == 'p')
	{
		new value = str_to_num(info[1])
		value = clampPing(value)
		set_pcvar_num(g_cvarMaxPing, value)
		client_print(0, print_chat, "[AMXX] Max ping set to %d ms.", value)
	}

	showMenu(id)
	return PLUGIN_HANDLED
}

public checkPings()
{
	if (!get_pcvar_num(g_cvarEnabled))
		return

	new players[MAX_PLAYERS], num
	get_players(players, num, "ch")
	if (num < get_pcvar_num(g_cvarMinPlayers))
		return

	new maxping = clampPing(get_pcvar_num(g_cvarMaxPing))
	new maxloss = get_pcvar_num(g_cvarMaxLoss)
	new need = clampChecks(get_pcvar_num(g_cvarChecks))
	new immunity = get_pcvar_num(g_cvarImmunity)
	new notify = get_pcvar_num(g_cvarNotify)
	new Float:now = get_gametime()

	for (new i; i < num; i++)
	{
		new id = players[i]
		if (!is_user_connected(id) || is_user_bot(id) || is_user_hltv(id))
			continue
		if (immunity && (get_user_flags(id) & (ADMIN_IMMUNITY | ADMIN_KICK | ADMIN_RESERVATION)))
		{
			g_warn[id] = 0
			continue
		}

		new ping, loss
		get_user_ping(id, ping, loss)
		new bool:bad = (ping > maxping) || (maxloss > 0 && loss > maxloss)

		if (!bad)
		{
			if (g_warn[id] > 0)
				g_warn[id]--
			continue
		}

		g_warn[id]++
		if (g_warn[id] < need)
		{
			if (notify && now >= g_nextWarn[id])
			{
				if (ping > maxping)
					client_print(id, print_chat, "[AMXX] Your ping is %d ms (max %d). Warning %d/%d.", ping, maxping, g_warn[id], need)
				else
					client_print(id, print_chat, "[AMXX] Your loss is %d%% (max %d%%). Warning %d/%d.", loss, maxloss, g_warn[id], need)
				g_nextWarn[id] = now + 8.0
			}
			continue
		}

		kickHighPing(id, ping, maxping, loss, maxloss, notify)
	}
}

kickHighPing(id, ping, maxping, loss, maxloss, notify)
{
	new name[MAX_NAME_LENGTH], auth[32]
	get_user_name(id, name, charsmax(name))
	get_user_authid(id, auth, charsmax(auth))

	new reason[64]
	if (ping > maxping)
		formatex(reason, charsmax(reason), "High ping %d ms (max %d)", ping, maxping)
	else
		formatex(reason, charsmax(reason), "High loss %d%% (max %d%%)", loss, maxloss)
	log_amx("PingKicker: dropped %s<%s> ping %d loss %d", name, auth, ping, loss)

	if (notify)
		client_print(0, print_chat, "[AMXX] %s was kicked (%s).", name, reason)

	g_warn[id] = 0
	rh_drop_client(id, reason)
}

clampPing(value)
{
	if (value < 50)
		return 50
	if (value > 999)
		return 999
	return value
}

clampChecks(value)
{
	if (value < 1)
		return 1
	if (value > MAX_WARN)
		return MAX_WARN
	return value
}
