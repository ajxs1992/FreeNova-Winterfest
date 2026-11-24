/* fn_reports: player reports (3.0 M7). Flow: /report -> target picker ->
 * reason menu -> optional desc (messagemode fn_reportdesc) -> cooldown +
 * dedup -> staff notify + case creation. Reports ride fn_case_new IDs +
 * journal + notes; open-case registry is session memory (auth<->case dual
 * Trie; a restart may open a second case for the same target, linked by
 * target identity in audit). Staff: /reports hint + fn_reportclaim /
 * fn_reportresolve console commands. Reports NEVER auto-ban: this module
 * contains zero ban calls by construction. */
#include <amxmodx>
#include <amxmisc>
#include <nvault>
#include <fn_core>
#include <fn_audit>
#include <fn_moderation>
#include <fn_common>

new g_vaultReports;
new g_cvarCooldown;
new g_repTarget[33];
new g_repReason[33][32];
new Trie:g_open;
new bool:g_live;
new Trie:g_openRev;
new g_openCount;

new const g_reasons[][32] = {"cheating", "griefing", "abuse", "spam", "other"};

public plugin_natives()
{
	set_native_filter("native_filter");
	register_library("fn_reports");
	register_native("fn_report_add", "_add");
	register_native("fn_report_claim", "_claim");
	register_native("fn_report_resolve", "_resolve");
	register_native("fn_report_open_count", "_open_count");
}

public native_filter(const name[], index, trap)
{
	if (!trap && contain(name, "fn_") == 0)
		return PLUGIN_HANDLED;
	return PLUGIN_CONTINUE;
}

public plugin_init()
{
	fn_boot_banner("reports", 12);

	register_plugin("FreeNova Reports", "3.0.0", "FreeNova");
	register_clcmd("amx_reportmenu", "cmdReport", ADMIN_ALL, "- report a player");
	register_clcmd("say /report", "cmdReport", ADMIN_ALL);
	register_clcmd("amx_reports", "cmdStaff", ADMIN_BAN, "- open reports queue");
	register_clcmd("say /reports", "cmdStaff", ADMIN_BAN);
	register_concmd("fn_reportdesc", "cmdDesc", ADMIN_ALL, "- report description input");
	register_concmd("fn_reportclaim", "cmdClaim", ADMIN_BAN, "<case> - claim a report");
	register_concmd("fn_reportresolve", "cmdResolve", ADMIN_BAN, "<case> [note] - resolve a report");
	if (!LibraryExists("fn_core", LibType_Library))
	{
		log_amx("[FN-REPORTS] fn_core missing, pausing self");
		pause("d");
		return;
	}
	if (!LibraryExists("fn_audit", LibType_Library))
	{
		log_amx("[FN-REPORTS] fn_audit missing, pausing self");
		pause("d");
		return;
	}
	g_vaultReports = nvault_open("fn_reports");
	g_cvarCooldown = register_cvar("fn_reports_cooldown", "120");
	g_open = TrieCreate();
	g_openRev = TrieCreate();
	g_live = true;
	fn_health_set("reports", "ok");
}

public plugin_end()
{
	if (g_vaultReports != INVALID_HANDLE)
		nvault_close(g_vaultReports);
	if (g_live) TrieDestroy(g_open);
	if (g_live) TrieDestroy(g_openRev);
}

public client_disconnected(id)
{
	g_repTarget[id] = 0;
	g_repReason[id][0] = 0;
}

coolOk(id)
{
	new auth[32];
	get_user_authid(id, auth, charsmax(auth));
	if (!auth[0])
		return 0;
	new data[16], ts;
	if (g_vaultReports == INVALID_HANDLE)
		return 1;
	if (!nvault_lookup(g_vaultReports, auth, data, charsmax(data), ts))
		return 1;
	new cd = get_pcvar_num(g_cvarCooldown);
	if (cd <= 0)
		return 1;
	return (get_systime() - ts) >= cd ? 1 : 0;
}

markCool(id)
{
	new auth[32];
	get_user_authid(id, auth, charsmax(auth));
	if (!auth[0] || g_vaultReports == INVALID_HANDLE)
		return;
	nvault_set(g_vaultReports, auth, "1");
}

public cmdReport(id, level, cid)
{
	if (!cmd_access(id, level, cid, 1))
		return PLUGIN_HANDLED;
	if (is_user_bot(id))
		return PLUGIN_HANDLED;
	showTargets(id);
	return PLUGIN_HANDLED;
}

showTargets(id)
{
	new menu = menu_create("\yReport player\w", "repPick");
	new players[32], num, name[MAX_NAME_LENGTH], info[8];
	get_players(players, num, "h");
	for (new i = 0; i < num; i++)
	{
		new pl = players[i];
		if (pl == id || is_user_bot(pl))
			continue;
		get_user_name(pl, name, charsmax(name));
		num_to_str(get_user_userid(pl), info, charsmax(info));
		menu_additem(menu, name, info);
	}
	menu_display(id, menu);
}

public repPick(id, menu, item)
{
	if (item < 0)
	{
		menu_destroy(menu);
		return PLUGIN_HANDLED;
	}
	new info[8], access, callback, dummy[1];
	menu_item_getinfo(menu, item, access, info, charsmax(info), dummy, 0, callback);
	menu_destroy(menu);
	new t = find_player("k", str_to_num(info));
	if (t < 1 || !is_user_connected(t))
	{
		client_print(id, print_chat, "[FN] player left.");
		return PLUGIN_HANDLED;
	}
	g_repTarget[id] = get_user_userid(t);
	showReasons(id);
	return PLUGIN_HANDLED;
}

showReasons(id)
{
	new menu = menu_create("\yReport reason\w", "repReason");
	for (new i = 0; i < sizeof(g_reasons); i++)
		menu_additem(menu, g_reasons[i], g_reasons[i]);
	menu_display(id, menu);
}

public repReason(id, menu, item)
{
	if (item < 0)
	{
		menu_destroy(menu);
		return PLUGIN_HANDLED;
	}
	new info[32], access, callback, dummy[1];
	menu_item_getinfo(menu, item, access, info, charsmax(info), dummy, 0, callback);
	menu_destroy(menu);
	copy(g_repReason[id], charsmax(g_repReason[]), info);
	client_cmd(id, "messagemode fn_reportdesc");
	client_print(id, print_chat, "[FN] describe it briefly (or empty):");
	return PLUGIN_HANDLED;
}

public cmdDesc(id, level, cid)
{
	if (!cmd_access(id, level, cid, 1))
		return PLUGIN_HANDLED;
	new desc[96];
	read_argv(1, desc, charsmax(desc));
	new t = find_player("k", g_repTarget[id]);
	if (t < 1 || !is_user_connected(t))
	{
		client_print(id, print_chat, "[FN] player left, report cancelled.");
		return PLUGIN_HANDLED;
	}
	if (!coolOk(id))
	{
		client_print(id, print_chat, "[FN] report cooldown, try later.");
		return PLUGIN_HANDLED;
	}
	new r = fileReport(id, t, g_repReason[id], desc);
	if (r == 1)
		client_print(id, print_chat, "[FN] report filed, staff notified.");
	else if (r == 2)
		client_print(id, print_chat, "[FN] similar open report exists, yours was added to it.");
	else
		client_print(id, print_chat, "[FN] report failed.");
	g_repTarget[id] = 0;
	return PLUGIN_HANDLED;
}

fileReport(reporter, target, const treason[], const desc[])
{
	if (!LibraryExists("fn_audit", LibType_Library))
		return 0;
	new tauth[32], tname[MAX_NAME_LENGTH];
	get_user_authid(target, tauth, charsmax(tauth));
	get_user_name(target, tname, charsmax(tname));
	if (!tauth[0] || !treason[0])
		return 0;
	new clean[96];
	copy(clean, charsmax(clean), desc);
	replace_all(clean, charsmax(clean), "|", " ");
	replace_all(clean, charsmax(clean), "^n", " ");
	new openCase[24];
	if (TrieGetString(g_open, tauth, openCase, charsmax(openCase)))
	{
		fn_audit_append(openCase, reporter, target, "report.again", treason);
		notifyStaff(openCase, tname, treason);
		markCool(reporter);
		return 2;
	}
	new c[24];
	fn_case_new(reporter, c, charsmax(c));
	fn_audit_append(c, reporter, target, "report.open", treason);
	if (clean[0])
		fn_case_note(reporter, c, clean);
	TrieSetString(g_open, tauth, c);
	TrieSetString(g_openRev, c, tauth);
	g_openCount++;
	notifyStaff(c, tname, treason);
	markCool(reporter);
	return 1;
}

closeCase(const c[])
{
	new tauth[40];
	if (TrieGetString(g_openRev, c, tauth, charsmax(tauth)))
	{
		TrieDeleteKey(g_openRev, c);
		TrieDeleteKey(g_open, tauth);
		if (g_openCount > 0)
			g_openCount--;
	}
}

notifyStaff(const case_id[], const tname[], const treason[])
{
	new players[32], num;
	get_players(players, num, "ch");
	for (new i = 0; i < num; i++)
	{
		new pl = players[i];
		if (access(pl, ADMIN_BAN))
			client_print(pl, print_chat, "[FN] report %s: %s (%s) - say /reports", case_id, tname, treason);
	}
	log_amx("[FN-REPORTS] %s on %s (%s)", case_id, tname, treason);
}

public cmdStaff(id, level, cid)
{
	if (!cmd_access(id, level, cid, 1))
		return PLUGIN_HANDLED;
	client_print(id, print_chat, "[FN] open reports live on cases: fn_cases, then fn_reportclaim <case>, fn_reportresolve <case> [note].");
	return PLUGIN_HANDLED;
}

public cmdClaim(id, level, cid)
{
	if (!cmd_access(id, level, cid, 2))
		return PLUGIN_HANDLED;
	new c[24];
	read_argv(1, c, charsmax(c));
	if (!c[0])
	{
		console_print(id, "[FN] usage: fn_reportclaim <case>");
		return PLUGIN_HANDLED;
	}
	if (!LibraryExists("fn_audit", LibType_Library))
		return PLUGIN_HANDLED;
	fn_audit_append(c, id, 0, "report.claim", "");
	console_print(id, "[FN] claimed %s.", c);
	return PLUGIN_HANDLED;
}

public cmdResolve(id, level, cid)
{
	if (!cmd_access(id, level, cid, 2))
		return PLUGIN_HANDLED;
	new c[24], note[96];
	read_argv(1, c, charsmax(c));
	read_argv(2, note, charsmax(note));
	if (!c[0])
	{
		console_print(id, "[FN] usage: fn_reportresolve <case> [note]");
		return PLUGIN_HANDLED;
	}
	if (!LibraryExists("fn_audit", LibType_Library))
		return PLUGIN_HANDLED;
	if (note[0])
		fn_case_note(id, c, note);
	fn_audit_append(c, id, 0, "report.resolve", note);
	closeCase(c);
	console_print(id, "[FN] resolved %s.", c);
	return PLUGIN_HANDLED;
}

public _add(plugin, params)
{
	new reporter = get_param(1);
	new target = get_param(2);
	new treason[32], desc[96];
	get_string(3, treason, charsmax(treason));
	get_string(4, desc, charsmax(desc));
	if (reporter < 1 || !is_user_connected(reporter))
		return 0;
	if (target < 1 || !is_user_connected(target))
		return 0;
	return fileReport(reporter, target, treason, desc);
}

public _claim(plugin, params)
{
	new admin = get_param(1);
	new c[24];
	get_string(2, c, charsmax(c));
	if (!c[0])
		return 0;
	if (!LibraryExists("fn_audit", LibType_Library))
		return 0;
	fn_audit_append(c, admin, 0, "report.claim", "");
	return 1;
}

public _resolve(plugin, params)
{
	new admin = get_param(1);
	new c[24], note[96];
	get_string(2, c, charsmax(c));
	get_string(3, note, charsmax(note));
	if (!c[0])
		return 0;
	if (!LibraryExists("fn_audit", LibType_Library))
		return 0;
	if (note[0])
		fn_case_note(admin, c, note);
	fn_audit_append(c, admin, 0, "report.resolve", note);
	closeCase(c);
	return 1;
}

public _open_count(plugin, params)
{
	return g_openCount;
}
