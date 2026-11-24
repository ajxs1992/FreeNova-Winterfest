/* fn_modes: game-mode profiles (3.0 M9). cvar bundles from
 * configs/fn_modes.ini ([profile] sections, `cvar value` lines, ;comments).
 * apply snapshots befores into fn_state (section modesnap) for rollback;
 * unknown cvars are skipped and reported (never created); every apply and
 * rollback writes a case + audit line. Profiles never assume gameplay
 * plugins exist; zombie/dm/surf entries carry coexistence notes in the file.
 * Pair with amx_profiles (plugin pause sets) for maintenance/event modes. */
#include <amxmodx>
#include <amxmisc>
#include <fn_core>
#include <fn_audit>
#include <fn_state>
#include <fn_common>

#define MAXPROF 12
#define MAXCV 48

new g_profiles[MAXPROF][32];
new g_nprof;
new g_cur[32];

public plugin_natives()
{
	set_native_filter("native_filter");
	register_library("fn_modes");
	register_native("fn_mode_apply", "_apply");
	register_native("fn_mode_current", "_current");
	register_native("fn_mode_rollback", "_rollback");
}

public native_filter(const name[], index, trap)
{
	if (!trap && contain(name, "fn_") == 0)
		return PLUGIN_HANDLED;
	return PLUGIN_CONTINUE;
}

public plugin_init()
{
	fn_boot_banner("modes", 6);

	register_plugin("FreeNova Modes", "3.0.0", "FreeNova");
	register_concmd("fn_mode", "cmdApply", ADMIN_CFG, "<profile> - apply cvar bundle (snapshots for rollback)");
	register_concmd("fn_modes", "cmdList", ADMIN_ADMIN, "- list mode profiles");
	register_concmd("fn_mode_rollback", "cmdRollback", ADMIN_CFG, "- restore pre-apply cvar values");
	if (!LibraryExists("fn_core", LibType_Library))
	{
		log_amx("[FN-MODES] fn_core missing, pausing self");
		pause("d");
		return;
	}
	if (!LibraryExists("fn_audit", LibType_Library))
	{
		log_amx("[FN-MODES] fn_audit missing, pausing self");
		pause("d");
		return;
	}
	if (!LibraryExists("fn_state", LibType_Library))
	{
		log_amx("[FN-MODES] fn_state missing, pausing self");
		pause("d");
		return;
	}
	loadProfiles();
	fn_state_get("modesnap", "_current", g_cur, charsmax(g_cur));
	fn_health_set("modes", "ok");
}

loadProfiles()
{
	g_nprof = 0;
	new path[128], cfg[96];
	get_configsdir(cfg, charsmax(cfg));
	formatex(path, charsmax(path), "%s/fn_modes.ini", cfg);
	if (!file_exists(path))
		return;
	new fp = fopen(path, "rt");
	if (!fp)
		return;
	new line[128];
	while (g_nprof < MAXPROF && fgets(fp, line, charsmax(line)))
	{
		trim(line);
		if (line[0] != '[')
			continue;
		new e = contain(line, "]");
		if (e < 2)
			continue;
		line[e] = 0;
		trim(line[1]);
		if (!line[1])
			continue;
		copy(g_profiles[g_nprof], 31, line[1]);
		g_nprof++;
	}
	fclose(fp);
}

findProfile(const name[])
{
	for (new i = 0; i < g_nprof; i++)
	{
		if (equali(g_profiles[i], name))
			return i;
	}
	return -1;
}

applyProfile(id, const name[])
{
	if (findProfile(name) < 0)
	{
		if (id >= 0)
			console_print(id, "[FN] unknown mode profile: %s (see fn_modes)", name);
		return -1;
	}
	new path[128], cfg[96];
	get_configsdir(cfg, charsmax(cfg));
	formatex(path, charsmax(path), "%s/fn_modes.ini", cfg);
	new fp = fopen(path, "rt");
	if (!fp)
	{
		if (id >= 0)
			console_print(id, "[FN] fn_modes.ini missing.");
		return -1;
	}
	new line[192], insec = 0, applied = 0, skipped = 0;
	new cvar[64], val[128];
	while (fgets(fp, line, charsmax(line)))
	{
		trim(line);
		if (!line[0] || line[0] == ';' || line[0] == '/')
			continue;
		if (line[0] == '[')
		{
			new e = contain(line, "]");
			if (e > 1)
			{
				line[e] = 0;
				insec = equali(line[1], name) ? 1 : 0;
			}
			continue;
		}
		if (!insec)
			continue;
		new sp = contain(line, " ");
		if (sp < 1)
			continue;
		copy(cvar, charsmax(cvar), line);
		cvar[sp] = 0;
		copy(val, charsmax(val), line[sp + 1]);
		trim(val);
		if (val[0] == '"' && val[strlen(val) - 1] == '"')
		{
			val[strlen(val) - 1] = 0;
			copy(val, charsmax(val), val[1]);
		}
		if (!cvar[0])
			continue;
		new ptr = get_cvar_pointer(cvar);
		if (!ptr)
		{
			skipped++;
			continue;
		}
		new oldv[128];
		get_cvar_string(cvar, oldv, charsmax(oldv));
		fn_state_set("modesnap", cvar, oldv);
		set_cvar_string(cvar, val);
		applied++;
	}
	fclose(fp);
	fn_state_set("modesnap", "_current", name);
	copy(g_cur, charsmax(g_cur), name);
	if (LibraryExists("fn_audit", LibType_Library))
	{
		new c[24];
		fn_case_new(id, c, charsmax(c));
		new detail[64];
		formatex(detail, charsmax(detail), "profile=%s applied=%d skipped=%d", name, applied, skipped);
		fn_audit_append(c, id, 0, "mode.apply", detail);
	}
	if (id >= 0)
		console_print(id, "[FN] mode %s: %d applied, %d unknown skipped.", name, applied, skipped);
	log_amx("[FN-MODES] %s applied=%d skipped=%d", name, applied, skipped);
	return applied;
}

public cmdApply(id, level, cid)
{
	if (!cmd_access(id, level, cid, 2))
		return PLUGIN_HANDLED;
	new arg[32];
	read_argv(1, arg, charsmax(arg));
	applyProfile(id, arg);
	return PLUGIN_HANDLED;
}

public cmdList(id, level, cid)
{
	if (!cmd_access(id, level, cid, 1))
		return PLUGIN_HANDLED;
	console_print(id, "[FN] mode profiles (current: %s):", g_cur[0] ? g_cur : "-");
	for (new i = 0; i < g_nprof; i++)
		console_print(id, "  %s", g_profiles[i]);
	return PLUGIN_HANDLED;
}

public cmdRollback(id, level, cid)
{
	if (!cmd_access(id, level, cid, 1))
		return PLUGIN_HANDLED;
	new r = doRollback(id);
	if (r < 0)
		console_print(id, "[FN] nothing to roll back.");
	else
		console_print(id, "[FN] rollback restored %d cvars.", r);
	return PLUGIN_HANDLED;
}

doRollback(id)
{
	new buf[1024];
	new total = fn_state_list("modesnap", buf, charsmax(buf));
	if (total <= 0)
		return -1;
	new restored = 0, start = 0;
	new key[64], cur[128];
	while (total > 0)
	{
		new comma = contain(buf[start], ",");
		if (comma < 0)
			copy(key, charsmax(key), buf[start]);
		else
			copy(key, comma, buf[start]);
		if (key[0] && !equal(key, "_current") && fn_state_get("modesnap", key, cur, charsmax(cur)))
		{
			if (get_cvar_pointer(key))
			{
				set_cvar_string(key, cur);
				restored++;
			}
		}
		if (comma < 0)
			break;
		start += comma + 1;
		if (start >= strlen(buf))
			break;
	}
	fn_state_del("modesnap", "_current");
	g_cur[0] = 0;
	if (LibraryExists("fn_audit", LibType_Library))
	{
		new c[24];
		fn_case_new(id, c, charsmax(c));
		new detail[32];
		formatex(detail, charsmax(detail), "restored=%d", restored);
		fn_audit_append(c, id, 0, "mode.rollback", detail);
	}
	log_amx("[FN-MODES] rollback restored=%d", restored);
	return restored;
}

public _apply(plugin, params)
{
	new name[32];
	get_string(1, name, charsmax(name));
	return applyProfile(-1, name);
}

public _current(plugin, params)
{
	new outlen = get_param(2);
	set_string(1, g_cur, outlen);
	return g_cur[0] ? 1 : 0;
}

public _rollback(plugin, params)
{
	return doRollback(-1);
}
