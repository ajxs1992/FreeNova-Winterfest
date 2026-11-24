/* fn_ban_range: backend-agnostic IP range bans. Ranges live in configs/fn_rban.ini
 * (one "start end reason" per line) mirrored to memory at map start (cap 128).
 * Enforcement on authorize; audit lines on add/remove. Works with any backend. */
#include <amxmodx>
#include <amxmisc>
#include <fn_core>
#include <fn_bans>
#include <fn_common>

#define MAX_RANGES 128

new g_rStart[MAX_RANGES][32];
new g_rEnd[MAX_RANGES][32];
new g_rReason[MAX_RANGES][96];
new g_rCount;
new g_file[128];

public plugin_natives()
{
	register_library("fn_range");
	set_native_filter("native_filter");
	register_native("fn_rban_add", "_rban_add");
	register_native("fn_rban_remove", "_rban_remove");
}

public native_filter(const name[], index, trap)
{
	if (!trap && contain(name, "fn_") == 0)
		return PLUGIN_HANDLED;
	return PLUGIN_CONTINUE;
}

public plugin_init()
{
	fn_boot_banner("ban_range", 6);

	register_plugin("FreeNova Range Bans", "2.0.0", "FreeNova");
	register_concmd("fn_rban", "cmdAdd", ADMIN_BAN, "<ip_start> <ip_end> <reason>");
	register_concmd("fn_unrban", "cmdRemove", ADMIN_BAN, "<ip_start> <ip_end>");
	register_concmd("fn_rbans", "cmdList", ADMIN_BAN, "- list ranges");
	register_concmd("fn_rban_selftest", "cmdSelftest", ADMIN_RCON, "- IPv4 parser vectors");
	if (!LibraryExists("fn_core", LibType_Library))
	{
		log_amx("[FN-RBAN] fn_core missing, pausing self");
		pause("d");
		return;
	}
	fn_health_set("bans.range", "ok");
}

public plugin_cfg()
{
	get_configsdir(g_file, charsmax(g_file));
	format(g_file, charsmax(g_file), "%s/fn_rban.ini", g_file);
	loadRanges();
}

loadRanges()
{
	g_rCount = 0;
	if (!file_exists(g_file)) return;
	new f = fopen(g_file, "rt");
	if (!f) return;
	static line[160];
	while (!feof(f) && g_rCount < MAX_RANGES)
	{
		line[0] = 0;
		fgets(f, line, charsmax(line));
		trim(line);
		if (!line[0] || line[0] == 59) continue;
		if (parse(line, g_rStart[g_rCount], 31, g_rEnd[g_rCount], 31, g_rReason[g_rCount], 95) < 3) continue;
		if (!ipLessEq(g_rStart[g_rCount], g_rEnd[g_rCount])) continue;
		g_rCount++;
	}
	fclose(f);
	log_amx("[FN-RBAN] loaded %d range(s)", g_rCount);
}

saveRanges()
{
	new f = fopen(g_file, "wt");
	if (!f) return;
	for (new i = 0; i < g_rCount; i++)
		fprintf(f, "%s %s ^"%s^"%n", g_rStart[i], g_rEnd[i], g_rReason[i]);
	fclose(f);
}

splitQuad(const ip[], parts[4])
{
	new cur = 0, val = 0, digits = 0;
	for (new i = 0; ip[i]; i++)
	{
		if (ip[i] == 46)
		{
			if (!digits || cur > 2) return 0;
			parts[cur++] = val;
			val = 0; digits = 0;
		}
		else if (ip[i] >= 48 && ip[i] <= 57)
		{
			val = val * 10 + (ip[i] - 48);
			digits++;
			if (digits > 3 || val > 255) return 0;
		}
		else return 0;
	}
	if (!digits || cur != 3) return 0;
	parts[cur] = val;
	return 1;
}

_ipToNum(const ip[], &valid)
{
	new parts[4];
	valid = splitQuad(ip, parts);
	if (!valid) return 0;
	return (parts[0] << 24) | (parts[1] << 16) | (parts[2] << 8) | parts[3];
}

ipLessEq(const a[], const b[])
{
	new pa[4], pb[4];
	if (!splitQuad(a, pa) || !splitQuad(b, pb)) return 0;
	for (new i = 0; i < 4; i++)
	{
		if (pa[i] < pb[i]) return 1;
		if (pa[i] > pb[i]) return 0;
	}
	return 1;
}

checkIp(const label[], const ip[], expect, expectValid)
{
	new valid = 0;
	new got = _ipToNum(ip, valid);
	if (got == expect && valid == expectValid) log_amx("[FN-RBAN] selftest %s PASS", label);
	else log_amx("[FN-RBAN] selftest %s FAIL (got %d/%d want %d/%d)", label, got, valid, expect, expectValid);
}

checkLe(const label[], const a[], const b[], expect)
{
	new got = ipLessEq(a, b);
	if (got == expect) log_amx("[FN-RBAN] selftest %s PASS", label);
	else log_amx("[FN-RBAN] selftest %s FAIL (got %d want %d)", label, got, expect);
}

public cmdSelftest(id, level, cid)
{
	if (!cmd_access(id, level, cid, 1)) return PLUGIN_HANDLED;
	checkIp("quad", "1.2.3.4", 16909060, 1);
	checkIp("zero", "0.0.0.0", 0, 1);
	checkIp("octet-over", "256.1.1.1", 0, 0);
	checkIp("alpha", "a.b.c.d", 0, 0);
	checkIp("short", "1.2.3", 0, 0);
	checkIp("long", "1.2.3.4.5", 0, 0);
	checkIp("empty", "", 0, 0);
	checkIp("trailing-dot", "1.2.3.4.", 0, 0);
	checkIp("max", "255.255.255.255", -1, 1);
	checkLe("order", "10.0.0.1", "10.0.0.2", 1);
	checkLe("cross190", "200.0.0.1", "10.0.0.1", 0);
	checkLe("high", "128.0.0.0", "200.0.0.1", 1);
	checkLe("maxspan", "0.0.0.0", "255.255.255.255", 1);
	checkLe("same", "9.9.9.9", "9.9.9.9", 1);
	console_print(id, "[FN] range selftest done, see logs");
	return PLUGIN_HANDLED;
}
inRange(const ip[], const a[], const b[]) { return (ipLessEq(a, ip) && ipLessEq(ip, b)); }

public client_authorized(id)
{
	if (is_user_bot(id) || is_user_hltv(id)) return;
	new ip[32];
	get_user_ip(id, ip, charsmax(ip), 1);
	for (new i = 0; i < g_rCount; i++)
	{
		if (inRange(ip, g_rStart[i], g_rEnd[i]))
		{
			log_amx("[FN-RBAN] range-blocked %s (%s)", ip, g_rReason[i]);
			new clean[96];
			copy(clean, 95, g_rReason[i]);
			replace_all(clean, 95, "'", " ");
			replace_all(clean, 95, ";", " ");
			replace_all(clean, 95, "^"", " ");
			server_cmd("kick #%d ^"IP range banned: %s^"", get_user_userid(id), clean);
			break;
		}
	}
}

addRange(admin, const a[], const b[], const reason[])
{
	if (!a[0] || !b[0] || !reason[0]) return 0;
	if (contain(reason, "'") >= 0) return 0;
	if (contain(reason, "^"") >= 0) return 0;
	if (contain(reason, ";") >= 0) return 0;
	if (contain(reason, "^n") >= 0 || contain(reason, "^r") >= 0) return 0;
	if (!ipLessEq(a, b)) return 0;
	for (new i = 0; i < g_rCount; i++)
	{
		if (equal(g_rStart[i], a) && equal(g_rEnd[i], b))
		{
			copy(g_rReason[i], 95, reason);
			saveRanges();
			fn_safe_log(admin, 0, "rban.update", a);
			return 1;
		}
	}
	if (g_rCount >= MAX_RANGES) return 0;
	copy(g_rStart[g_rCount], 31, a);
	copy(g_rEnd[g_rCount], 31, b);
	copy(g_rReason[g_rCount], 95, reason);
	g_rCount++;
	saveRanges();
	fn_safe_log(admin, 0, "rban.add", a);
	return 1;
}

delRange(admin, const a[], const b[])
{
	for (new i = 0; i < g_rCount; i++)
	{
		if (equal(g_rStart[i], a) && equal(g_rEnd[i], b))
		{
			for (new j = i; j < g_rCount - 1; j++)
			{
				copy(g_rStart[j], 31, g_rStart[j + 1]);
				copy(g_rEnd[j], 31, g_rEnd[j + 1]);
				copy(g_rReason[j], 95, g_rReason[j + 1]);
			}
			g_rCount--;
			saveRanges();
			fn_safe_log(admin, 0, "rban.remove", a);
			return 1;
		}
	}
	return 0;
}

public _rban_add(plugin, params)
{
	new admin = get_param(1);
	new a[32], b[32], reason[96];
	get_string(2, a, charsmax(a));
	get_string(3, b, charsmax(b));
	get_string(4, reason, charsmax(reason));
	return addRange(admin, a, b, reason);
}

public _rban_remove(plugin, params)
{
	new admin = get_param(1);
	new a[32], b[32];
	get_string(2, a, charsmax(a));
	get_string(3, b, charsmax(b));
	return delRange(admin, a, b);
}

public cmdAdd(id, level, cid)
{
	if (!cmd_access(id, level, cid, 4)) return PLUGIN_HANDLED;
	new a[32], b[32], r[96];
	read_argv(1, a, charsmax(a));
	read_argv(2, b, charsmax(b));
	read_argv(3, r, charsmax(r));
	if (addRange(id, a, b, r)) console_print(id, "[FN] range ban %s-%s", a, b);
	else console_print(id, "[FN] range rejected (bad range or list full)");
	return PLUGIN_HANDLED;
}

public cmdRemove(id, level, cid)
{
	if (!cmd_access(id, level, cid, 3)) return PLUGIN_HANDLED;
	new a[32], b[32];
	read_argv(1, a, charsmax(a));
	read_argv(2, b, charsmax(b));
	if (delRange(id, a, b)) console_print(id, "[FN] range removed");
	else console_print(id, "[FN] range not found");
	return PLUGIN_HANDLED;
}

public cmdList(id, level, cid)
{
	if (!cmd_access(id, level, cid, 1)) return PLUGIN_HANDLED;
	console_print(id, "[FN] ranges (%d):", g_rCount);
	for (new i = 0; i < g_rCount; i++)
		console_print(id, "  %s - %s : %s", g_rStart[i], g_rEnd[i], g_rReason[i]);
	return PLUGIN_HANDLED;
}