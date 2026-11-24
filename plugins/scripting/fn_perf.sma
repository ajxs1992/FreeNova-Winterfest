/* fn_perf: lightweight observability (3.0 M6). Honest scope: Pawn cannot see
 * frame times, hook counts, or task tables, so this module does NOT claim
 * them. It measures what exists: scheduler jitter (1s-task lateness via
 * gametime deltas), uptime, map time, player count, session/ban/chat-denial
 * counters, error-log growth. Sampler task runs ONLY in mode 1 or during a
 * benchmark (default off = zero polling). */
#include <amxmodx>
#include <amxmisc>
#include <fn_core>
#include <fn_bans>
#include <fn_chat>
#include <fn_common>

#define PERF_TASK 90310

new g_mode;
new Float:g_lastTick;
new g_maxGap;
new g_sumGap;
new g_samples;
new g_benchLeft;
new g_bootTime;

public plugin_natives()
{
	set_native_filter("native_filter");
	register_library("fn_perf");
	register_native("fn_perf_jitter", "_jitter");
	register_native("fn_perf_uptime", "_uptime");
}

public native_filter(const name[], index, trap)
{
	if (!trap && contain(name, "fn_") == 0)
		return PLUGIN_HANDLED;
	return PLUGIN_CONTINUE;
}

public plugin_init()
{
	fn_boot_banner("perf", 5);

	register_plugin("FreeNova Perf", "3.0.0", "FreeNova");
	register_concmd("fn_perf", "cmdPerf", ADMIN_ADMIN, "- performance snapshot");
	register_concmd("fn_perf_bench", "cmdBench", ADMIN_RCON, "<seconds> - burst sampler (RCON only)");
	g_mode = register_cvar("fn_perf_mode", "0");
	if (!LibraryExists("fn_core", LibType_Library))
	{
		log_amx("[FN-PERF] fn_core missing, pausing self");
		pause("d");
		return;
	}
	g_bootTime = get_systime();
	g_lastTick = 0.0;
	fn_health_set("perf", "ok");
}

public plugin_cfg()
{
	if (get_pcvar_num(g_mode) > 0)
	{
		remove_task(PERF_TASK);
		set_task(1.0, "sample", PERF_TASK, "", 0, "b");
	}
}

public sample()
{
	new Float:now = get_gametime();
	if (g_lastTick > 0.0)
	{
		new gap = floatround((now - g_lastTick) * 100.0);
		if (gap > g_maxGap)
			g_maxGap = gap;
		g_sumGap += gap;
		g_samples++;
	}
	g_lastTick = now;
	if (g_benchLeft > 0)
	{
		g_benchLeft--;
		if (g_benchLeft <= 0)
		{
			remove_task(PERF_TASK);
			log_amx("[PERF] bench done samples=%d maxgap_cs=%d avggap_cs=%d", g_samples, g_maxGap, g_samples ? (g_sumGap / g_samples) : 0);
		}
	}
}

snapshot(id)
{
	new players[32], num;
	get_players(players, num, "ch");
	new bans = 0, denied = 0;
	if (LibraryExists("fn_bans", LibType_Library))
		bans = fn_ban_count();
	if (LibraryExists("fn_chat", LibType_Library))
		denied = fn_chat_denied();
	new map[64];
	get_mapname(map, charsmax(map));
	new elines = errLines();
	if (id > 0)
	{
		console_print(id, "[FN] uptime=%ds map=%s players=%d bans(session)=%d chatdenied=%d errlog=%d samples=%d maxgap_cs=%d",
			get_systime() - g_bootTime, map, num, bans, denied, elines, g_samples, g_maxGap);
	}
	log_amx("[PERF] uptime=%d map=%s players=%d bans=%d denied=%d errlog=%d samples=%d maxgap=%d",
		get_systime() - g_bootTime, map, num, bans, denied, elines, g_samples, g_maxGap);
}

errLines()
{
	new stamp[16];
	get_time("%Y%m%d", stamp, charsmax(stamp));
	new dir[96], path[192];
	get_datadir(dir, charsmax(dir));
	formatex(path, charsmax(path), "%s/error_%s.log", dir, stamp);
	if (!file_exists(path))
		return 0;
	new f = fopen(path, "rt");
	if (!f)
		return 0;
	new n = 0, line[64];
	while (fgets(f, line, charsmax(line)))
		n++;
	fclose(f);
	return n;
}

public cmdPerf(id, level, cid)
{
	if (!cmd_access(id, level, cid, 1))
		return PLUGIN_HANDLED;
	snapshot(id);
	return PLUGIN_HANDLED;
}

public cmdBench(id, level, cid)
{
	if (!cmd_access(id, level, cid, 1))
		return PLUGIN_HANDLED;
	new a[12];
	read_argv(1, a, charsmax(a));
	new secs = str_to_num(a);
	if (secs < 5)
		secs = 5;
	if (secs > 300)
		secs = 300;
	g_samples = 0;
	g_maxGap = 0;
	g_sumGap = 0;
	g_lastTick = 0.0;
	g_benchLeft = secs;
	remove_task(PERF_TASK);
	set_task(1.0, "sample", PERF_TASK, "", 0, "b");
	console_print(id, "[FN] bench running %ds (sampler only, no gameplay impact)", secs);
	log_amx("[PERF] bench start secs=%d by #%d", secs, id);
	return PLUGIN_HANDLED;
}

public _jitter(plugin, params)
{
	return g_maxGap;
}

public _uptime(plugin, params)
{
	return get_systime() - g_bootTime;
}
