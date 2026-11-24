/* fn_policy: protection policy engine, observe-and-flag (3.0 M8). Watches
 * chat text (ad patterns), reconnect rate per IP, and guard verdicts;
 * DECIDES nothing destructive in M8: flags produce staff notify (throttled)
 * + audit lines only. Automated mute/kick/ban matrices need traffic-tuned
 * thresholds (M8b). Uses existing guard via fn_guard_verdict (guarded);
 * never a second VPN framework. Say hook is observe-only (CONTINUE always)
 * and runs last by preset order. */
#include <amxmodx>
#include <amxmisc>
#include <fn_core>
#include <fn_audit>
#include <fn_guard>
#include <fn_common>

new g_cvarOn, g_cvarAdMax, g_cvarRecon, g_cvarReconWin, g_cvarNotify;
new g_adHits[MAX_PLAYERS + 1];
new g_lastNotify[MAX_PLAYERS + 1];
new Trie:g_ipHits;
new bool:g_live;

public plugin_natives()
{
	set_native_filter("native_filter");
	register_library("fn_policy");
	register_native("fn_policy_flags", "_flags");
}

public native_filter(const name[], index, trap)
{
	if (!trap && contain(name, "fn_") == 0)
		return PLUGIN_HANDLED;
	return PLUGIN_CONTINUE;
}

public plugin_init()
{
	fn_boot_banner("policy", 8);

	register_plugin("FreeNova Policy", "3.0.0", "FreeNova");
	register_clcmd("say", "observeSay");
	register_clcmd("say_team", "observeSay");
	g_cvarOn = register_cvar("fn_policy_on", "1");
	g_cvarAdMax = register_cvar("fn_policy_admax", "3");
	g_cvarRecon = register_cvar("fn_policy_recon", "4");
	g_cvarReconWin = register_cvar("fn_policy_reconwin", "60");
	g_cvarNotify = register_cvar("fn_policy_notify", "1");
	if (!LibraryExists("fn_core", LibType_Library))
	{
		log_amx("[FN-POLICY] fn_core missing, pausing self");
		pause("d");
		return;
	}
	g_ipHits = TrieCreate();
	g_live = true;
	fn_health_set("policy", "ok");
}

public plugin_end()
{
	if (g_live) TrieDestroy(g_ipHits);
}

public client_connect(id)
{
	g_adHits[id] = 0;
	g_lastNotify[id] = 0;
	if (is_user_bot(id) || is_user_hltv(id))
		return;
	if (!get_pcvar_num(g_cvarOn))
		return;
	new ip[32];
	get_user_ip(id, ip, charsmax(ip), 1);
	if (!ip[0])
		return;
	new data[32], kept = 0, winstart = 0;
	if (TrieGetString(g_ipHits, ip, data, charsmax(data)))
	{
		new a[12], b[12];
		replace_all(data, charsmax(data), "|", " ");
		parse(data, a, charsmax(a), b, charsmax(b));
		kept = str_to_num(a);
		winstart = str_to_num(b);
	}
	new now = get_systime();
	new win = get_pcvar_num(g_cvarReconWin);
	if (win < 10)
		win = 10;
	if (now - winstart > win)
	{
		kept = 0;
		winstart = now;
	}
	kept++;
	new out[32];
	formatex(out, charsmax(out), "%d|%d", kept, winstart);
	TrieSetString(g_ipHits, ip, out);
	new lim = get_pcvar_num(g_cvarRecon);
	if (lim > 0 && kept > lim)
		flag(id, "reconnect-abuse");
}

public client_disconnected(id)
{
	g_adHits[id] = 0;
}

public observeSay(id)
{
	if (!get_pcvar_num(g_cvarOn))
		return PLUGIN_CONTINUE;
	if (id < 1 || id > MaxClients || !is_user_connected(id) || is_user_bot(id))
		return PLUGIN_CONTINUE;
	new said[192];
	read_args(said, charsmax(said));
	remove_quotes(said);
	trim(said);
	if (!said[0])
		return PLUGIN_CONTINUE;
	if (containi(said, ".com") != -1 || containi(said, "www.") != -1 || containi(said, "http") != -1 || containi(said, ":27") != -1 || containi(said, ".net") != -1)
	{
		g_adHits[id]++;
		new lim = get_pcvar_num(g_cvarAdMax);
		if (lim > 0 && g_adHits[id] == lim)
			flag(id, "ad-spam");
	}
	return PLUGIN_CONTINUE;
}

public client_authorized(id)
{
	if (!get_pcvar_num(g_cvarOn))
		return;
	if (is_user_bot(id) || is_user_hltv(id))
		return;
	if (!LibraryExists("fn_guard", LibType_Library))
		return;
	new gv[16];
	new r = fn_guard_verdict(id, gv, charsmax(gv));
	if (r == 1 && equal(gv, "pending"))
		flag(id, "guard-pending");
}

flag(id, const why[])
{
	if (!get_pcvar_num(g_cvarNotify))
		return;
	new now = get_systime();
	if (now - g_lastNotify[id] < 300)
		return;
	g_lastNotify[id] = now;
	new name[MAX_NAME_LENGTH], auth[32];
	if (id >= 1 && is_user_connected(id))
	{
		get_user_name(id, name, charsmax(name));
		get_user_authid(id, auth, charsmax(auth));
	}
	else
	{
		copy(name, charsmax(name), "?");
		copy(auth, charsmax(auth), "?");
	}
	new players[32], num;
	get_players(players, num, "ch");
	for (new i = 0; i < num; i++)
	{
		if (access(players[i], ADMIN_BAN))
			client_print(players[i], print_chat, "[FN] policy flag: %s (%s) - %s", name, auth, why);
	}
	if (LibraryExists("fn_audit", LibType_Library))
	{
		new c[24];
		fn_case_new(id > 0 ? id : 0, c, charsmax(c));
		fn_audit_append(c, 0, id > 0 ? id : 0, "policy.flag", why);
	}
	log_amx("[FN-POLICY] %s (%s): %s", name, auth, why);
}

public _flags(plugin, params)
{
	new id = get_param(1);
	if (id < 1 || id > MaxClients || !is_user_connected(id))
		return 0;
	new n = 0;
	if (g_adHits[id] > 0)
		n++;
	return n;
}
