/* fn_spectate: admin spectator utility (3.0 M8). Honest scope: team-state
 * preserving spec/back moves + staff shortcut menu. Next/prev/follow target
 * switching is CLIENT UI (mouse) and is not faked server-side. Never
 * restores alive state or equipment; moves respect teams (stored T/CT only,
 * never fabricated). */
#include <amxmodx>
#include <amxmisc>
#include <cstrike>
#include <fn_core>
#include <fn_common>

new CsTeams:g_prevTeam[MAX_PLAYERS + 1];

public plugin_natives()
{
	set_native_filter("native_filter");
	register_library("fn_spectate");
}

public native_filter(const name[], index, trap)
{
	if (!trap && contain(name, "fn_") == 0)
		return PLUGIN_HANDLED;
	return PLUGIN_CONTINUE;
}

public plugin_init()
{
	fn_boot_banner("spectate", 3);

	register_plugin("FreeNova Spectate", "3.0.0", "FreeNova");
	register_concmd("amx_spec", "cmdSpec", ADMIN_KICK, "<name|#userid> - move to spectator (team remembered)");
	register_concmd("amx_back", "cmdBack", ADMIN_KICK, "<name|#userid> - return to remembered team");
	register_clcmd("amx_specmenu", "cmdMenu", ADMIN_KICK, "- spectator shortcuts");
	if (!LibraryExists("fn_core", LibType_Library))
	{
		log_amx("[FN-SPEC] fn_core missing, pausing self");
		pause("d");
		return;
	}
	fn_health_set("spectate", "ok");
}

public client_disconnected(id)
{
	g_prevTeam[id] = CS_TEAM_UNASSIGNED;
}

resolveTarget(admin, const arg[])
{
	new t = 0;
	if (admin == 0)
		t = fn_resolve_target(arg, admin);
	else
		t = cmd_target(admin, arg, CMDTARGET_ALLOW_SELF);
	return t;
}

public cmdSpec(id, level, cid)
{
	if (!cmd_access(id, level, cid, 2))
		return PLUGIN_HANDLED;
	new arg[32];
	read_argv(1, arg, charsmax(arg));
	new t = resolveTarget(id, arg);
	if (t < 1)
		return PLUGIN_HANDLED;
	new CsTeams:cur = cs_get_user_team(t);
	if (cur == CS_TEAM_T || cur == CS_TEAM_CT)
		g_prevTeam[t] = cur;
	if (cur == CS_TEAM_SPECTATOR)
	{
		console_print(id, "[FN] already spectator.");
		return PLUGIN_HANDLED;
	}
	cs_set_user_team(t, CS_TEAM_SPECTATOR);
	fn_safe_log(id, t, "spec.move", "");
	client_print(t, print_chat, "[FN] moved to spectator by staff.");
	return PLUGIN_HANDLED;
}

public cmdBack(id, level, cid)
{
	if (!cmd_access(id, level, cid, 2))
		return PLUGIN_HANDLED;
	new arg[32];
	read_argv(1, arg, charsmax(arg));
	new t = resolveTarget(id, arg);
	if (t < 1)
		return PLUGIN_HANDLED;
	new CsTeams:back = g_prevTeam[t];
	if (back != CS_TEAM_T && back != CS_TEAM_CT)
	{
		console_print(id, "[FN] no remembered team for that player.");
		return PLUGIN_HANDLED;
	}
	cs_set_user_team(t, back);
	g_prevTeam[t] = CS_TEAM_UNASSIGNED;
	fn_safe_log(id, t, "spec.back", "");
	return PLUGIN_HANDLED;
}

public cmdMenu(id, level, cid)
{
	if (!cmd_access(id, level, cid, 1))
		return PLUGIN_HANDLED;
	new menu = menu_create("\ySpectate\w", "specH");
	menu_additem(menu, "Me to spectator", "me");
	menu_additem(menu, "Me back", "backme");
	menu_additem(menu, "Player to spectator...", "other");
	menu_display(id, menu);
	return PLUGIN_HANDLED;
}

public specH(id, menu, item)
{
	if (item < 0)
	{
		menu_destroy(menu);
		return PLUGIN_HANDLED;
	}
	new info[16], access, callback, dummy[1];
	menu_item_getinfo(menu, item, access, info, charsmax(info), dummy, 0, callback);
	menu_destroy(menu);
	if (equal(info, "me"))
	{
		new CsTeams:cur = cs_get_user_team(id);
		if (cur == CS_TEAM_T || cur == CS_TEAM_CT)
			g_prevTeam[id] = cur;
		cs_set_user_team(id, CS_TEAM_SPECTATOR);
		fn_safe_log(id, id, "spec.move", "self");
	}
	else if (equal(info, "backme"))
	{
		new CsTeams:back = g_prevTeam[id];
		if (back == CS_TEAM_T || back == CS_TEAM_CT)
		{
			cs_set_user_team(id, back);
			g_prevTeam[id] = CS_TEAM_UNASSIGNED;
			fn_safe_log(id, id, "spec.back", "self");
		}
		else
			client_print(id, print_chat, "[FN] no remembered team.");
	}
	else
		client_print(id, print_chat, "[FN] use: amx_spec <name>, amx_back <name>.");
	return PLUGIN_HANDLED;
}
