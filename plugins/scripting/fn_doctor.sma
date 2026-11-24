/* fn_doctor: configuration doctor (3.0 M6). Preset-independent FACTS (not
 * preset judgments): loaded/health per fn_ module, duplicate-service
 * markers, missing-file checks gated on the consumer being loaded, unsafe
 * defaults, staging-build detection. NEVER prints secret values (only
 * empty-or-not). Console table + machine-readable [DOCTOR] log lines. */
#include <amxmodx>
#include <amxmisc>
#include <fn_core>
#include <fn_common>

new g_pass;
new g_warn;
new g_fail;

public plugin_natives()
{
	set_native_filter("native_filter");
	register_library("fn_doctor");
}

public native_filter(const name[], index, trap)
{
	if (!trap && contain(name, "fn_") == 0)
		return PLUGIN_HANDLED;
	return PLUGIN_CONTINUE;
}

public plugin_init()
{
	fn_boot_banner("doctor", 1);

	register_plugin("FreeNova Doctor", "3.0.0", "FreeNova");
	register_concmd("fn_doctor", "cmdDoctor", ADMIN_ADMIN, "- configuration health check");
	if (LibraryExists("fn_core", LibType_Library))
		fn_health_set("doctor", "ok");
}

report(id, const check[], const result[], const detail[])
{
	if (equal(result, "pass"))
		g_pass++;
	else if (equal(result, "warn"))
		g_warn++;
	else
		g_fail++;
	log_amx("[DOCTOR] check=%s result=%s %s", check, result, detail);
	if (id > 0)
		console_print(id, "[%-4s] %-22s %s", result, check, detail);
}

modHealth(const module[], out[], len)
{
	if (!LibraryExists("fn_core", LibType_Library))
	{
		copy(out, len, "no-core");
		return 0;
	}
	if (!fn_health_get(module, out, len))
	{
		copy(out, len, "unknown");
		return 0;
	}
	return 1;
}

public cmdDoctor(id, level, cid)
{
	if (!cmd_access(id, level, cid, 1))
		return PLUGIN_HANDLED;
	g_pass = 0;
	g_warn = 0;
	g_fail = 0;
	new s[64], cfg[128];
	get_configsdir(cfg, charsmax(cfg));

	/* 1. core root */
	if (LibraryExists("fn_core", LibType_Library))
		report(id, "core", "pass", "fn_core library present");
	else
	{
		report(id, "core", "fail", "fn_core missing - all dependents degrade");
		finish(id);
		return PLUGIN_HANDLED;
	}

	/* 2. ban backend identity (file+pg coexist by design, not a violation) */
	new hasFile = (get_cvar_pointer("ab_website") != 0);
	new hasPg = (get_cvar_pointer("pg_interval") != 0);
	if (hasFile && hasPg)
		report(id, "backend", "pass", "file + pg reconcile design");
	else if (hasFile)
		report(id, "backend", "pass", "file backend");
	else if (hasPg)
		report(id, "backend", "pass", "pg backend");
	else
		report(id, "backend", "warn", "no ban backend markers (ab_website/pg_interval)");

	/* 3. map stacks (R3) */
	new modern = (get_cvar_pointer("amx_mapmanager_extend_max") != 0);
	new classic = (get_cvar_pointer("amx_extendmap_max") != 0);
	if (modern && classic)
		report(id, "mapstack", "fail", "modern AND classic stacks active (R3)");
	else if (modern)
		report(id, "mapstack", "pass", "modern stack");
	else if (classic)
		report(id, "mapstack", "pass", "classic stack");
	else
		report(id, "mapstack", "warn", "no map stack markers");

	/* 4. guard */
	new hasGuard = (get_cvar_pointer("bypass_guard_enabled") != 0);
	if (hasGuard)
		report(id, "guard", "pass", "bypass_guard present");
	else
		report(id, "guard", "pass", "guard absent (ok unless preset B)");

	/* 5. staging build detection */
	if (is_plugin_loaded("FN Staging Test") != -1 || is_plugin_loaded("FN Probe Count") != -1)
		report(id, "staging", "warn", "staging-only plugins loaded (never ship)");
	else
		report(id, "staging", "pass", "no staging plugins");

	/* 6. rcon set (value never printed) */
	new rcon[64];
	get_cvar_string("rcon_password", rcon, charsmax(rcon));
	if (!rcon[0])
		report(id, "rcon", "fail", "rcon_password is empty");
	else
		report(id, "rcon", "pass", "rcon_password is set");

	/* 7. hostname placeholder */
	new host[64];
	get_cvar_string("hostname", host, charsmax(host));
	if (containi(host, "CHANGE-ME") != -1)
		report(id, "hostname", "warn", "hostname still has CHANGE-ME template");
	else
		report(id, "hostname", "pass", "hostname customized");

	/* 8. consumer-gated config files */
	if (LibraryExists("gagsystem", LibType_Library))
		report(id, "gag-lib", "pass", "gagsystem present");
	else
		report(id, "gag-lib", "warn", "gagsystem absent (flood integration off)");
	new lang[192];
	formatex(lang, charsmax(lang), "%s/../data/lang/advanced_bans.txt", cfg);
	if (hasFile && !file_exists(lang))
		report(id, "lang-ab", "warn", "advanced_bans.txt missing");
	else if (hasFile)
		report(id, "lang-ab", "pass", "ban lang present");
	if (hasGuard)
	{
		new al[192];
		formatex(al, charsmax(al), "%s/bypass_guard/as_list.ini", cfg);
		if (file_exists(al))
			report(id, "guard-cfg", "pass", "local lists present");
		else
			report(id, "guard-cfg", "warn", "as_list.ini missing");
	}

	/* 9. pg credentials presence (never values) */
	if (hasPg)
	{
		new pp[128], hasPass = 0;
		get_cvar_string("pg_passfile", pp, charsmax(pp));
		if (pp[0] && file_exists(pp))
			hasPass = 1;
		if (hasPass)
			report(id, "pg-pass", "pass", "passfile present");
		else
			report(id, "pg-pass", "fail", "pg_passfile missing or unreadable");
		new dry = get_cvar_num("pg_dryrun");
		if (dry)
			report(id, "pg-dryrun", "pass", "dryrun on (safe)");
		else
			report(id, "pg-dryrun", "warn", "dryrun OFF: live writes enabled");
	}

	/* 10. module health sweep (loaded vs initialized vs degraded) */
	new mods[12][16];
	copy(mods[0], 15, "core"); copy(mods[1], 15, "roles");
	copy(mods[2], 15, "audit"); copy(mods[3], 15, "bans");
	copy(mods[4], 15, "menus"); copy(mods[5], 15, "maps");
	copy(mods[6], 15, "moderation"); copy(mods[7], 15, "perms");
	copy(mods[8], 15, "identity"); copy(mods[9], 15, "state");
	copy(mods[10], 15, "chat"); copy(mods[11], 15, "sync");
	for (new i = 0; i < 12; i++)
	{
		modHealth(mods[i], s, charsmax(s));
		if (equal(s, "ok"))
			report(id, mods[i], "pass", "health ok");
		else if (equal(s, "unknown") || equal(s, "no-core"))
			report(id, mods[i], "warn", "not reporting (absent or uninitialized)");
		else
			report(id, mods[i], "fail", s);
	}
	finish(id);
	return PLUGIN_HANDLED;
}

finish(id)
{
	log_amx("[DOCTOR] summary pass=%d warn=%d fail=%d", g_pass, g_warn, g_fail);
	if (id > 0)
		console_print(id, "[DONE] pass=%d warn=%d fail=%d", g_pass, g_warn, g_fail);
}
