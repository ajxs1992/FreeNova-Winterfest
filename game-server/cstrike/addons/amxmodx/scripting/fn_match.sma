/* fn_match: optional match administration (3.0 M9). Explicit FSM:
 * IDLE -> WARMUP -> READY -> LIVE -> END, with PAUSED beside LIVE and RESET
 * from anywhere. Ready collection via say /ready (connected non-bot T/CT);
 * the referee may force-start. Scores are REFEREE-ENTERED (no hook-guessed
 * numbers); automatic round detection is M9b (needs runtime-verified
 * hooks). All transitions audit under one match case. Pause uses
 * mp_pause_match when the cvar exists, else reports unsupported. Restarts
 * and map moves use stock server commands. Overtime is NOT implemented
 * (documented M9b with round hooks). */
#include <amxmodx>
#include <amxmisc>
#include <cstrike>
#include <fn_core>
#include <fn_audit>
#include <fn_common>

#define ST_IDLE 0
#define ST_WARMUP 1
#define ST_READY 2
#define ST_LIVE 3
#define ST_PAUSED 4
#define ST_END 5

new g_state;
new g_matchCase[24];
new g_scoreT;
new g_scoreCT;
new g_ready[MAX_PLAYERS + 1];

public plugin_natives()
{
	set_native_filter("native_filter");
	register_library("fn_match");
	register_native("fn_match_state", "_state");
}

public native_filter(const name[], index, trap)
{
	if (!trap && contain(name, "fn_") == 0)
		return PLUGIN_HANDLED;
	return PLUGIN_CONTINUE;
}

public plugin_init()
{
	fn_boot_banner("match", 13);

	register_plugin("FreeNova Match", "3.0.0", "FreeNova");
	register_concmd("fn_match_warmup", "cmdWarmup", ADMIN_RCON, "- open warmup + ready collection");
	register_concmd("fn_match_start", "cmdStart", ADMIN_RCON, "- force live (referee)");
	register_concmd("fn_match_pause", "cmdPause", ADMIN_RCON, "- pause live match");
	register_concmd("fn_match_unpause", "cmdUnpause", ADMIN_RCON, "- resume paused match");
	register_concmd("fn_match_end", "cmdEnd", ADMIN_RCON, "- end match, announce score");
	register_concmd("fn_match_reset", "cmdReset", ADMIN_RCON, "- reset to idle");
	register_concmd("fn_match_point", "cmdPoint", ADMIN_RCON, "<t|ct> - referee scores a round");
	register_concmd("fn_match_team", "cmdTeam", ADMIN_RCON, "<name|#id> <t|ct> - referee team switch");
	register_concmd("fn_match_map", "cmdMap", ADMIN_RCON, "<map> - validated map move");
	register_concmd("fn_match_score", "cmdScore", ADMIN_RCON, "- show score");
	register_clcmd("say /ready", "cmdReady");
	register_clcmd("say_team /ready", "cmdReady");
	if (!LibraryExists("fn_core", LibType_Library))
	{
		log_amx("[FN-MATCH] fn_core missing, pausing self");
		pause("d");
		return;
	}
	fn_health_set("match", "ok");
}

stateName(st, out[], len)
{
	switch (st)
	{
		case ST_IDLE: copy(out, len, "idle");
		case ST_WARMUP: copy(out, len, "warmup");
		case ST_READY: copy(out, len, "ready");
		case ST_LIVE: copy(out, len, "live");
		case ST_PAUSED: copy(out, len, "paused");
		case ST_END: copy(out, len, "end");
		default: copy(out, len, "?");
	}
}

auditMatch(admin, const action[], const detail[])
{
	if (!LibraryExists("fn_audit", LibType_Library))
		return;
	if (!g_matchCase[0])
	{
		fn_case_new(admin, g_matchCase, charsmax(g_matchCase));
		fn_audit_append(g_matchCase, admin, 0, "match.open", "");
	}
	fn_audit_append(g_matchCase, admin, 0, action, detail);
}

announce(const text[])
{
	client_print(0, print_chat, "[MATCH] %s", text);
	log_amx("[FN-MATCH] %s", text);
}

eligible(id)
{
	if (id < 1 || id > MaxClients || !is_user_connected(id) || is_user_bot(id) || is_user_hltv(id))
		return 0;
	new CsTeams:t = cs_get_user_team(id);
	return (t == CS_TEAM_T || t == CS_TEAM_CT) ? 1 : 0;
}

readyCount(&total)
{
	new n = 0, r = 0;
	for (new i = 1; i <= MaxClients; i++)
	{
		if (!eligible(i))
			continue;
		n++;
		if (g_ready[i])
			r++;
	}
	total = n;
	return r;
}

public cmdReady(id)
{
	if (g_state != ST_WARMUP && g_state != ST_READY)
		return PLUGIN_CONTINUE;
	if (!eligible(id))
		return PLUGIN_CONTINUE;
	g_ready[id] = !g_ready[id];
	new total, r = readyCount(total);
	client_print(0, print_chat, "[MATCH] ready %d/%d.", r, total);
	if (total > 0 && r >= total)
	{
		g_state = ST_READY;
		announce("all ready. Referee: fn_match_start.");
		auditMatch(id, "match.ready", "");
	}
	return PLUGIN_CONTINUE;
}

public client_disconnected(id)
{
	g_ready[id] = 0;
}

public cmdWarmup(id, level, cid)
{
	if (!cmd_access(id, level, cid, 1))
		return PLUGIN_HANDLED;
	g_state = ST_WARMUP;
	g_scoreT = 0;
	g_scoreCT = 0;
	for (new i = 1; i <= MaxClients; i++)
		g_ready[i] = 0;
	g_matchCase[0] = 0;
	auditMatch(id, "match.warmup", "");
	announce("warmup open. Type /ready when set.");
	return PLUGIN_HANDLED;
}

public cmdStart(id, level, cid)
{
	if (!cmd_access(id, level, cid, 1))
		return PLUGIN_HANDLED;
	if (g_state != ST_WARMUP && g_state != ST_READY)
	{
		console_print(id, "[FN] start needs warmup (current: %d).", g_state);
		return PLUGIN_HANDLED;
	}
	g_state = ST_LIVE;
	server_cmd("sv_restartround 3");
	auditMatch(id, "match.live", "");
	announce("LIVE. Good luck.");
	return PLUGIN_HANDLED;
}

public cmdPause(id, level, cid)
{
	if (!cmd_access(id, level, cid, 1))
		return PLUGIN_HANDLED;
	if (g_state != ST_LIVE)
	{
		console_print(id, "[FN] pause needs a live match.");
		return PLUGIN_HANDLED;
	}
	new ptr = get_cvar_pointer("mp_pause_match");
	if (!ptr)
	{
		console_print(id, "[FN] pause unsupported on this game build.");
		return PLUGIN_HANDLED;
	}
	set_pcvar_num(ptr, 1);
	g_state = ST_PAUSED;
	auditMatch(id, "match.pause", "");
	announce("paused by referee.");
	return PLUGIN_HANDLED;
}

public cmdUnpause(id, level, cid)
{
	if (!cmd_access(id, level, cid, 1))
		return PLUGIN_HANDLED;
	if (g_state != ST_PAUSED)
	{
		console_print(id, "[FN] nothing paused.");
		return PLUGIN_HANDLED;
	}
	new ptr = get_cvar_pointer("mp_pause_match");
	if (ptr)
		set_pcvar_num(ptr, 0);
	g_state = ST_LIVE;
	auditMatch(id, "match.unpause", "");
	announce("resumed. LIVE.");
	return PLUGIN_HANDLED;
}

public cmdEnd(id, level, cid)
{
	if (!cmd_access(id, level, cid, 1))
		return PLUGIN_HANDLED;
	if (g_state != ST_LIVE && g_state != ST_PAUSED)
	{
		console_print(id, "[FN] no live match to end.");
		return PLUGIN_HANDLED;
	}
	g_state = ST_END;
	new line[64];
	formatex(line, charsmax(line), "match over. T %d - %d CT.", g_scoreT, g_scoreCT);
	auditMatch(id, "match.end", line);
	announce(line);
	return PLUGIN_HANDLED;
}

public cmdReset(id, level, cid)
{
	if (!cmd_access(id, level, cid, 1))
		return PLUGIN_HANDLED;
	g_state = ST_IDLE;
	g_scoreT = 0;
	g_scoreCT = 0;
	g_matchCase[0] = 0;
	for (new i = 1; i <= MaxClients; i++)
		g_ready[i] = 0;
	auditMatch(id, "match.reset", "");
	announce("match module reset to idle.");
	return PLUGIN_HANDLED;
}

public cmdPoint(id, level, cid)
{
	if (!cmd_access(id, level, cid, 2))
		return PLUGIN_HANDLED;
	if (g_state != ST_LIVE)
	{
		console_print(id, "[FN] points count only while live.");
		return PLUGIN_HANDLED;
	}
	new arg[8];
	read_argv(1, arg, charsmax(arg));
	if (equali(arg, "t"))
		g_scoreT++;
	else if (equali(arg, "ct"))
		g_scoreCT++;
	else
	{
		console_print(id, "[FN] usage: fn_match_point <t|ct>");
		return PLUGIN_HANDLED;
	}
	new line[48];
	formatex(line, charsmax(line), "T %d - %d CT", g_scoreT, g_scoreCT);
	auditMatch(id, "match.point", line);
	announce(line);
	return PLUGIN_HANDLED;
}

public cmdTeam(id, level, cid)
{
	if (!cmd_access(id, level, cid, 3))
		return PLUGIN_HANDLED;
	new a1[32], a2[8];
	read_argv(1, a1, charsmax(a1));
	read_argv(2, a2, charsmax(a2));
	new t = 0;
	if (id == 0)
		t = fn_resolve_target(a1, id);
	else
		t = cmd_target(id, a1, CMDTARGET_ALLOW_SELF);
	if (t < 1)
		return PLUGIN_HANDLED;
	if (equali(a2, "t"))
		cs_set_user_team(t, CS_TEAM_T);
	else if (equali(a2, "ct"))
		cs_set_user_team(t, CS_TEAM_CT);
	else
	{
		console_print(id, "[FN] usage: fn_match_team <player> <t|ct>");
		return PLUGIN_HANDLED;
	}
	fn_safe_log(id, t, "match.team", a2);
	return PLUGIN_HANDLED;
}

public cmdMap(id, level, cid)
{
	if (!cmd_access(id, level, cid, 2))
		return PLUGIN_HANDLED;
	new arg[32];
	read_argv(1, arg, charsmax(arg));
	if (!is_map_valid(arg))
	{
		console_print(id, "[FN] invalid map: %s", arg);
		return PLUGIN_HANDLED;
	}
	auditMatch(id, "match.map", arg);
	server_cmd("changelevel %s", arg);
	return PLUGIN_HANDLED;
}

public cmdScore(id, level, cid)
{
	if (!cmd_access(id, level, cid, 1))
		return PLUGIN_HANDLED;
	new st[16];
	stateName(g_state, st, charsmax(st));
	console_print(id, "[FN] match=%s score T %d - %d CT", st, g_scoreT, g_scoreCT);
	return PLUGIN_HANDLED;
}

public _state(plugin, params)
{
	return g_state;
}
