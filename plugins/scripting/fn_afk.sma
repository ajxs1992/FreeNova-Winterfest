/* fn_afk: conservative AFK manager (3.0 M8). Low-frequency poll (default
 * 15s) of buttons + origin for ALIVE non-spectator players only; dead/spec
 * players are never punished (respawn/observe). Warn once at threshold minus
 * warn window, then move-to-spectator (default) or kick. Immune flags and
 * (optionally) all flagged admins are exempt. Single repeating task that
 * removes itself when disabled (no permanent task for a disabled feature). */
#include <amxmodx>
#include <amxmisc>
#include <cstrike>
#include <reapi>
#include <fn_core>
#include <fn_hud>
#include <fn_common>
#include <fn_hud>

#define AFK_TASK 90610

new g_cvarOn, g_cvarTime, g_cvarWarn, g_cvarAction, g_cvarAdmins, g_cvarInterval;
new Float:g_lastAct[MAX_PLAYERS + 1];
new g_lastBtn[MAX_PLAYERS + 1];
new Float:g_lastOrg[MAX_PLAYERS + 1][3];
new bool:g_warned[MAX_PLAYERS + 1];

public plugin_natives()
{
	set_native_filter("native_filter");
	register_library("fn_afk");
	register_native("fn_afk_idle", "_idle");
}

public native_filter(const name[], index, trap)
{
	if (!trap && contain(name, "fn_") == 0)
		return PLUGIN_HANDLED;
	return PLUGIN_CONTINUE;
}

public plugin_init()
{
	fn_boot_banner("afk", 7);

	register_plugin("FreeNova AFK", "3.0.0", "FreeNova");
	g_cvarOn = register_cvar("fn_afk_on", "1");
	g_cvarTime = register_cvar("fn_afk_time", "120");
	g_cvarWarn = register_cvar("fn_afk_warn", "30");
	g_cvarAction = register_cvar("fn_afk_action", "0");
	g_cvarAdmins = register_cvar("fn_afk_admins", "1");
	g_cvarInterval = register_cvar("fn_afk_interval", "15");
	if (!LibraryExists("fn_core", LibType_Library))
	{
		log_amx("[FN-AFK] fn_core missing, pausing self");
		pause("d");
		return;
	}
	fn_health_set("afk", "ok");
}

public plugin_cfg()
{
	remove_task(AFK_TASK);
	set_task(5.0, "poll", AFK_TASK, "", 0, "b");
}

activeNow(id)
{
	if (id < 1 || id > MaxClients || !is_user_connected(id) || is_user_bot(id) || is_user_hltv(id))
		return 0;
	if (!is_user_alive(id))
		return 0;
	if (cs_get_user_team(id) == CS_TEAM_SPECTATOR)
		return 0;
	if (get_user_flags(id) & ADMIN_IMMUNITY)
		return 0;
	if (get_pcvar_num(g_cvarAdmins) && is_user_admin(id))
		return 0;
	return 1;
}

public client_putinserver(id)
{
	g_lastAct[id] = get_gametime();
	g_lastBtn[id] = 0;
	g_warned[id] = false;
}

public client_disconnected(id)
{
	g_lastAct[id] = 0.0;
	g_warned[id] = false;
}

public poll()
{
	if (!get_pcvar_num(g_cvarOn))
	{
		remove_task(AFK_TASK);
		return;
	}
	new iv = get_pcvar_num(g_cvarInterval);
	if (iv < 5)
		iv = 5;
	remove_task(AFK_TASK);
	set_task(float(iv), "poll", AFK_TASK);
	new threshold = get_pcvar_num(g_cvarTime);
	if (threshold < 30)
		threshold = 30;
	new warnAt = get_pcvar_num(g_cvarWarn);
	if (warnAt < 0)
		warnAt = 0;
	if (warnAt >= threshold)
		warnAt = threshold / 2;
	new Float:now = get_gametime();
	for (new id = 1; id <= MaxClients; id++)
	{
		if (!activeNow(id))
			continue;
		new btn = get_entvar(id, var_button);
		new Float:org[3];
		get_entvar(id, var_origin, org);
		if (btn != g_lastBtn[id] || org[0] != g_lastOrg[id][0] || org[1] != g_lastOrg[id][1] || org[2] != g_lastOrg[id][2])
		{
			g_lastBtn[id] = btn;
			g_lastOrg[id][0] = org[0];
			g_lastOrg[id][1] = org[1];
			g_lastOrg[id][2] = org[2];
			g_lastAct[id] = now;
			g_warned[id] = false;
			continue;
		}
		new idle = floatround(now - g_lastAct[id]);
		if (!g_warned[id] && idle >= threshold - warnAt)
		{
			g_warned[id] = true;
			new msg[128];
			formatex(msg, charsmax(msg), "[FN] AFK check: move or act within %ds or you will be moved.", threshold - idle);
			client_print(id, print_chat, "%s", msg);
			if (LibraryExists("fn_hud", LibType_Library))
				fn_hud_show(5, 5.0, 255, 180, 40, -1.0, 0.30, msg);
			fn_safe_log(0, id, "afk.warn", "");
		}
		if (idle >= threshold)
		{
			g_warned[id] = false;
			g_lastAct[id] = now;
			if (get_pcvar_num(g_cvarAction) == 1)
			{
				server_cmd("kick #%d ^"AFK %d seconds^"", get_user_userid(id), threshold);
				fn_safe_log(0, id, "afk.kick", "");
			}
			else
			{
				cs_set_user_team(id, CS_TEAM_SPECTATOR);
				new aname[MAX_NAME_LENGTH];
				get_user_name(id, aname, charsmax(aname));
				fn_safe_log(0, id, "afk.spec", aname);
				client_print(0, print_chat, "[FN] %s moved to spectator (AFK).", aname);
			}
		}
	}
}

public _idle(plugin, params)
{
	new id = get_param(1);
	if (id < 1 || id > MaxClients || !is_user_connected(id))
		return -1;
	if (g_lastAct[id] <= 0.0)
		return 0;
	new d = floatround(get_gametime() - g_lastAct[id]);
	return d < 0 ? 0 : d;
}
