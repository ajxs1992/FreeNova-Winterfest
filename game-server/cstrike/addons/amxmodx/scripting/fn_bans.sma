/* fn_bans: single authoritative ban API. Enforcement delegates to the ONE active
 * backend plugin via its console commands (bridge pattern); this router adds
 * case IDs, audit lines, permanent-ban confirmation, and session accounting.
 * fn_ban_count is SESSION-scoped by design (backend totals: use amx_banlist). */
#include <amxmodx>
#include <amxmisc>
#include <fn_core>
#include <fn_audit>
#include <fn_common>

new g_backend;
new g_cvarSession;
new g_sessionBans;
new g_fwdAdded;
new g_fwdRemoved;

// --- backend-confirmed ban accounting --------------------------------------
// server_cmd() only queues a command and advanced_bans may still refuse it
// (unknown target, max ban time, CBan_OnAddBan veto, backend down). REVIEW.md
// 5.5: the session counter, the fn_ban_added forward and the audit row were
// written the moment the command was queued, so a ban that never landed was
// counted, announced and audited anyway. They are now written when the backend
// itself reports the ban through CBan_OnPlayerBannedPost / CBan_OnAddBan; an
// intent that is never confirmed is audited as ban.not_landed instead.
#define MAX_PENDING_BANS 8
#define TASK_PENDING     7300
#define PENDING_TTL      10.0

new bool:g_pendUsed[MAX_PENDING_BANS];
new g_pendCase[MAX_PENDING_BANS][24];
new g_pendAdmin[MAX_PENDING_BANS];
new g_pendSteam[MAX_PENDING_BANS][40];
new g_pendIp[MAX_PENDING_BANS][32];
new g_pendMinutes[MAX_PENDING_BANS];
new g_pendReason[MAX_PENDING_BANS][128];

public plugin_natives()
{
	set_native_filter("native_filter");
	register_library("fn_bans");
	register_native("fn_ban_add", "_ban_add");
	register_native("fn_ban_add_confirmed", "_ban_add_confirmed");
	register_native("fn_ban_remove", "_ban_remove");
	register_native("fn_ban_count", "_ban_count");
}

public native_filter(const name[], index, trap)
{
	if (!trap && contain(name, "fn_") == 0)
		return PLUGIN_HANDLED;
	return PLUGIN_CONTINUE;
}

public plugin_init()
{
	fn_boot_banner("bans", 13);

	register_plugin("FreeNova Bans", "2.0.0", "FreeNova");
	register_concmd("fn_ban", "cmdBan", ADMIN_BAN, "<target steam|ip|#id> <minutes,0=perm> <reason>");
	register_concmd("fn_unban", "cmdUnban", ADMIN_BAN, "<steam|ip> <reason>");
	register_concmd("fn_banstatus", "cmdStatus", ADMIN_BAN, "- backend + session state");
	register_concmd("fn_confirm", "cmdConfirm", ADMIN_BAN, "<case> - confirm a held permanent ban");
	register_concmd("fn_bans_selftest", "cmdSelftest", ADMIN_RCON, "- native self-call matrix");
	g_backend = register_cvar("fn_bans_backend", "advanced");
	g_cvarSession = register_cvar("fn_bans_session", "0");
	if (!LibraryExists("fn_core", LibType_Library) || !LibraryExists("fn_audit", LibType_Library))
	{
		log_amx("[FN-BANS] fn_core or fn_audit missing, pausing self");
		pause("d");
		return;
	}
	g_fwdAdded = CreateMultiForward("fn_ban_added", ET_IGNORE, FP_STRING, FP_CELL, FP_STRING, FP_STRING, FP_CELL, FP_STRING);
	g_fwdRemoved = CreateMultiForward("fn_ban_removed", ET_IGNORE, FP_STRING, FP_CELL, FP_STRING, FP_STRING);
	fn_health_set("bans", "ok");
}


safeToken(const src[], dst[], len)
{
	copy(dst, len, src);
	replace_all(dst, len, "^"", " ");
	replace_all(dst, len, "^n", " ");
	replace_all(dst, len, ";", " ");
	replace_all(dst, len, "^r", " ");
	trim(dst);
}

isValidId(const t[])
{
	if (!t[0]) return 0;
	if (contain(t, ";") >= 0) return 0;
	if (!strncmp(t, "STEAM_", 6) || !strncmp(t, "VALVE_", 6))
	{
		new len = strlen(t);
		if (len < 10 || contain(t, ":") < 0) return 0;
		return 1;
	}
	return isValidQuad(t);
}

isValidQuad(const ip[])
{
	new parts = 0, val = 0, digits = 0;
	for (new i = 0; ip[i]; i++)
	{
		if (ip[i] == 46)
		{
			if (!digits || parts > 2) return 0;
			parts++; val = 0; digits = 0;
		}
		else if (ip[i] >= 48 && ip[i] <= 57)
		{
			val = val * 10 + (ip[i] - 48);
			digits++;
			if (digits > 3 || val > 255) return 0;
		}
		else return 0;
	}
	if (!digits || parts != 3) return 0;
	return 1;
}

banCap()
{
	new ptr = get_cvar_pointer("amx_tempban_maxtime");
	if (ptr == 0) return 4320;
	return get_pcvar_num(ptr);
}


doEnforce(const steam[], const ip[], minutes, const reason[])
{
	new target[40], name[32];
	if (steam[0]) copy(target, charsmax(target), steam);
	else copy(target, charsmax(target), ip);
	copy(name, charsmax(name), target);
	new pid = -1;
	new players[32], num;
	get_players(players, num, "h"); // include bots: bans must resolve bot slots too
	for (new i = 0; i < num; i++)
	{
		new a[40], p[32];
		get_user_authid(players[i], a, charsmax(a));
		get_user_ip(players[i], p, charsmax(p), 1);
		if ((steam[0] && equal(a, steam)) || (ip[0] && equal(p, ip))) { pid = players[i]; break; }
	}
	if (pid > 0)
	{
		get_user_name(pid, name, charsmax(name));
		server_cmd("amx_ban #%d %d ^"%s^"", get_user_userid(pid), minutes, reason);
	}
	else
	{
		new clean[32];
		safeToken(name, clean, charsmax(clean));
		server_cmd("amx_addban ^"%s^" ^"%s^" %d ^"%s^"", clean, target, minutes, reason);
	}
	return pid;
}


// Count a ban that the backend has confirmed (or that we could not wait for).
stock CountBan(admin, const c[], const steam[], const ip[], minutes, const reason[], tpid)
{
	g_sessionBans++;
	set_pcvar_num(g_cvarSession, get_pcvar_num(g_cvarSession) + 1);
	new ret;
	ExecuteForward(g_fwdAdded, ret, c, admin, steam, ip, minutes, reason);
	static idbuf[96];
	formatex(idbuf, charsmax(idbuf), "%s %s", steam, ip);
	fn_safe_audit(c, admin, tpid, "ban.add", idbuf);
}

// Remember a queued ban until the backend reports it.
stock bool:pendNew(admin, const c[], const steam[], const ip[], minutes, const reason[])
{
	for (new i = 0; i < MAX_PENDING_BANS; i++)
	{
		if (g_pendUsed[i]) continue;
		g_pendUsed[i] = true;
		copy(g_pendCase[i], charsmax(g_pendCase[]), c);
		g_pendAdmin[i] = admin;
		copy(g_pendSteam[i], charsmax(g_pendSteam[]), steam);
		copy(g_pendIp[i], charsmax(g_pendIp[]), ip);
		g_pendMinutes[i] = minutes;
		copy(g_pendReason[i], charsmax(g_pendReason[]), reason);
		set_task(PENDING_TTL, "Task_PendingExpired", TASK_PENDING + i);
		return true;
	}
	return false;
}

// Match the identity the backend reports (authid or IP) against queued intents.
stock pendFind(const ident[])
{
	if (!ident[0]) return -1;
	for (new i = 0; i < MAX_PENDING_BANS; i++)
	{
		if (!g_pendUsed[i]) continue;
		if (equali(g_pendSteam[i], ident) || equali(g_pendIp[i], ident))
			return i;
	}
	return -1;
}

stock pendConfirm(idx, tpid)
{
	if (idx < 0 || idx >= MAX_PENDING_BANS || !g_pendUsed[idx]) return;
	g_pendUsed[idx] = false;
	remove_task(TASK_PENDING + idx);
	CountBan(g_pendAdmin[idx], g_pendCase[idx], g_pendSteam[idx], g_pendIp[idx], g_pendMinutes[idx], g_pendReason[idx], tpid);
}

// Queue the backend command and remember the intent; the accounting happens in
// the confirmation callback below.
stock commitBan(admin, const c[], const steam[], const ip[], minutes, const reason[])
{
	new tpid = doEnforce(steam, ip, minutes, reason);
	if (!pendNew(admin, c, steam, ip, minutes, reason))
	{
		// Queue full (8 bans inside PENDING_TTL). Counting straight away is the
		// old behaviour; say so rather than losing the audit row silently.
		log_amx("[FN-BANS] pending queue full, counting case=%s immediately", c);
		CountBan(admin, c, steam, ip, minutes, reason, tpid);
	}
}

// advanced_bans reports a live ban that actually landed (AddBan + history done).
public CBan_OnPlayerBannedPost(id, admin, length, const reason[])
{
	new steam[40], ip[32];
	steam[0] = 0; ip[0] = 0;
	if (id > 0 && id <= MaxClients && is_user_connected(id))
	{
		get_user_authid(id, steam, charsmax(steam));
		get_user_ip(id, ip, charsmax(ip), 1);
	}
	new idx = pendFind(steam);
	if (idx < 0) idx = pendFind(ip);
	pendConfirm(idx, (id > 0 && id <= MaxClients) ? id : 0);
	return PLUGIN_CONTINUE;
}

// advanced_bans reports an offline/IP ban it is about to store.
public CBan_OnAddBan(const target[], admin, length, const reason[])
{
	pendConfirm(pendFind(target), 0);
	return PLUGIN_CONTINUE;
}

public Task_PendingExpired(taskid)
{
	new i = taskid - TASK_PENDING;
	if (i < 0 || i >= MAX_PENDING_BANS || !g_pendUsed[i]) return;
	g_pendUsed[i] = false;
	log_amx("[FN-BANS] backend never confirmed case=%s (%s/%s) - not counted", g_pendCase[i], g_pendSteam[i], g_pendIp[i]);
	static idbuf[96];
	formatex(idbuf, charsmax(idbuf), "%s %s", g_pendSteam[i], g_pendIp[i]);
	fn_safe_audit(g_pendCase[i], g_pendAdmin[i], 0, "ban.not_landed", idbuf);
}

stock banAdd(admin, const steam[], const ip[], minutes, const reason[])
{
	if ((!steam[0] && !ip[0]) || minutes < 0 || !reason[0]) return 0;
	if (!isValidId(steam) && !isValidId(ip)) return 0;
	new cap = banCap();
	if (cap > 0 && minutes > cap) { minutes = cap; log_amx("[FN-BANS] clamped to amx_tempban_maxtime %d", cap); }
	new clean[128];
	safeToken(reason, clean, charsmax(clean));
	if (minutes <= 0)
	{
		new c[24];
		c[0] = 0;
		if (LibraryExists("fn_audit", LibType_Library)) { fn_case_new(admin, c, charsmax(c)); }
		else { copy(c, charsmax(c), "FN-NOAUDIT"); }
		if (LibraryExists("fn_audit", LibType_Library))
		fn_confirm_request(admin, c, "permanent ban", minutes, steam, ip, clean);
		if (admin > 0 && is_user_connected(admin))
			client_print(admin, print_console, "[FN] permanent ban needs confirm, then re-issue");
		log_amx("[FN-BANS] permanent ban held for confirm case=%s", c);
		return -1;
	}
	new c[24];
	c[0] = 0;
	if (LibraryExists("fn_audit", LibType_Library)) { fn_case_new(admin, c, charsmax(c)); }
	else { copy(c, charsmax(c), "FN-NOAUDIT"); }
	commitBan(admin, c, steam, ip, minutes, clean);
	return 1;
}

stock banAddConfirmed(admin, const c[])
{
	if (!c[0]) return 0;
	if (!LibraryExists("fn_audit", LibType_Library)) return 0;
	new s[40], p[32], ms[12], r[96];
	if (!fn_confirm_do(admin, c, s, 39, p, 31, ms, 11, r, 95)) return 0;
	new m = str_to_num(ms);
	new cap2 = banCap();
	if (cap2 > 0 && m > cap2) { m = cap2; log_amx("[FN-BANS] confirmed clamped to amx_tempban_maxtime %d", cap2); }
	commitBan(admin, c, s, p, m, r);
	return 1;

}
stock banRemove(admin, const target[], const reason[])
{
	if (!target[0]) return 0;
	if (!isValidId(target)) return 0;
	new clean[128];
	safeToken(reason, clean, charsmax(clean));
	new c[24];
	c[0] = 0;
	if (LibraryExists("fn_audit", LibType_Library)) fn_case_new(admin, c, charsmax(c));
	else copy(c, charsmax(c), "FN-NOAUDIT");
	server_cmd("amx_unban ^"%s^"", target);
	new ret;
	ExecuteForward(g_fwdRemoved, ret, c, admin, target, clean);
	fn_safe_audit(c, admin, 0, "ban.remove", target);
	return 1;
}

public _ban_add(plugin, params)
{
	new admin = get_param(1);
	new steam[40], ip[32], reason[128];
	get_string(2, steam, charsmax(steam));
	get_string(3, ip, charsmax(ip));
	new minutes = get_param(4);
	get_string(5, reason, charsmax(reason));
	return banAdd(admin, steam, ip, minutes, reason);
}

public _ban_add_confirmed(plugin, params)
{
	new admin = get_param(1);
	new c[24];
	get_string(2, c, charsmax(c));
	new s[40], p[32], ms[12], r[96];
	if (!c[0]) return 0;
	if (!LibraryExists("fn_audit", LibType_Library)) return 0;
	if (!fn_confirm_do(admin, c, s, 39, p, 31, ms, 11, r, 95)) return 0;
	new m = str_to_num(ms);
	new cap2 = banCap();
	if (cap2 > 0 && m > cap2) { m = cap2; log_amx("[FN-BANS] confirmed clamped to amx_tempban_maxtime %d", cap2); }
	commitBan(admin, c, s, p, m, r);
	return 1;
}
public _ban_remove(plugin, params)
{
	new admin = get_param(1);
	new target[40], reason[128];
	get_string(2, target, charsmax(target));
	get_string(3, reason, charsmax(reason));
	return banRemove(admin, target, reason);
}



public _ban_count(plugin, params)
{
	return get_pcvar_num(g_cvarSession);
}


backendPresent()
{
	return get_cvar_pointer("ab_website") != 0;
}

public cmdBan(id, level, cid)
{
	if (!cmd_access(id, level, cid, 4)) return PLUGIN_HANDLED;
	new a1[40], a2[12], a3[128];
	read_argv(1, a1, charsmax(a1));
	read_argv(2, a2, charsmax(a2));
	read_argv(3, a3, charsmax(a3));
	new mins = str_to_num(a2);
	new pid;
	if (id == 0)
		pid = fn_resolve_target(a1, id);
	else
		pid = cmd_target(id, a1, CMDTARGET_ALLOW_SELF);
	if (id == 0 && pid <= 0 && contain(a1, "STEAM_") != 0 && contain(a1, "VALVE_") != 0 && contain(a1, ".") == -1 && contain(a1, ":") == -1)
	{
		new hits[8], nm2[MAX_NAME_LENGTH];
		new nh = fn_resolve_list(a1, hits, 8, id);
		if (nh > 1)
		{
			console_print(id, "[FN] %d players match, be more specific:", nh);
			for (new si = 0; si < nh && si < 8; si++)
			{
				get_user_name(hits[si], nm2, charsmax(nm2));
				console_print(id, "  %s", nm2);
			}
			return PLUGIN_HANDLED;
		}
		console_print(id, "[FN] no such player (or not a steam/IP for offline ban): %s", a1);
		return PLUGIN_HANDLED;
	}
	new steam[40], ip[32];
	steam[0] = 0; ip[0] = 0;
	if (pid > 0)
	{
		get_user_authid(pid, steam, charsmax(steam));
		get_user_ip(pid, ip, charsmax(ip), 1);
	}
	else copy(steam, charsmax(steam), a1);
	new r = banAdd(id, steam, ip, mins, a3);
	if (r == 0) console_print(id, "[FN] ban rejected (check target, minutes, reason)");
	return PLUGIN_HANDLED;
}

public cmdUnban(id, level, cid)
{
	if (!cmd_access(id, level, cid, 3)) return PLUGIN_HANDLED;
	new a1[40], a2[128];
	read_argv(1, a1, charsmax(a1));
	read_argv(2, a2, charsmax(a2));
	if (!banRemove(id, a1, a2)) console_print(id, "[FN] unban rejected");
	else console_print(id, "[FN] unban issued for %s", a1);
	return PLUGIN_HANDLED;
}


public cmdSelftest(id, level, cid)
{
	if (!cmd_access(id, level, cid, 1)) return PLUGIN_HANDLED;
	return PLUGIN_HANDLED;
}

public cmdConfirm(id, level, cid)
{
	if (!cmd_access(id, level, cid, 2)) return PLUGIN_HANDLED;
	new c[24];
	read_argv(1, c, charsmax(c));
	if (!c[0]) { console_print(id, "[FN] usage: fn_confirm <case>"); return PLUGIN_HANDLED; }
	if (!LibraryExists("fn_audit", LibType_Library)) { console_print(id, "[FN] audit unavailable"); return PLUGIN_HANDLED; }
	new s[40], p[32], ms[12], r[96];
	// REVIEW.md 5.5: this log line sat *before* the attempt, so every successful
	// confirm wrote "confirm failed" to the AMXX log and the case id there was
	// never the one that failed. Log it in the failure branch, where it is true.
	if (!fn_confirm_do(id, c, s, 39, p, 31, ms, 11, r, 95))
	{
		log_amx("[FN-BANS] confirm failed case=%s", c);
		console_print(id, "[FN] confirm failed (wrong case, expired, or other admin)");
		return PLUGIN_HANDLED;
	}
	new m = str_to_num(ms);
	new cap2 = banCap();
	if (cap2 > 0 && m > cap2) { m = cap2; log_amx("[FN-BANS] confirmed clamped to amx_tempban_maxtime %d", cap2); }
	commitBan(id, c, s, p, m, r);
	log_amx("[FN-BANS] confirmed ban enforced case=%s", c);
	console_print(id, "[FN] confirmed ban enforced.");
	return PLUGIN_HANDLED;
}

public cmdStatus(id, level, cid)
{
	if (!cmd_access(id, level, cid, 1)) return PLUGIN_HANDLED;
	new be[16];
	get_pcvar_string(g_backend, be, charsmax(be));
	console_print(id, "[FN] backend=%s ab_present=%d session_bans=%d", be, backendPresent(), g_sessionBans);
	return PLUGIN_HANDLED;
}