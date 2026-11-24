/*
 * FreeNova Season Manager 1.0
 *
 * Ported from RSU monthly reset, re-homed onto the CRX store as the
 * single progression owner requires. Fixes the RSU missed-reset bug:
 * the check re-fires daily instead of once per map load.
 * Missed-window: only day/day+1/day+2 of the current month fire a reset.
 * Offline for those three days = no catch-up later (avoids mid-month wipe).
 * fn_season_reset_day 29-31 is clamped to 28 so February cannot skip.
 *
 * Reset policy (RSU defaults preserved): CRX XP/rank reset to season start;
 * lifetime counters, BattlePass coins/skills and weapon skins survive.
 */

#include <amxmodx>
#include <amxmisc>
#include <sqlx>
#include <nvault>
#include <crxranks>
#include <crxranks_const>
// RSU_DEFAULT_SKILL: same default the core uses in EnsureDatabaseSchema /
// player INSERT, so an offline reset lands on the same skill baseline.
#include <rsu_const>
#include <fn_common>

#define PLUGIN  "FreeNova Season Manager"
#define VERSION "1.0"
#define AUTHOR  "FreeNova"

#define TASK_CHECK 5501

new pcvar_enabled, pcvar_day, pcvar_reset_skill
new g_szMonthStamp[8]
new Handle:g_hSeasonTuple = Empty_Handle

// Same pattern as rsu_core EscapeSql. Never SQL_QuoteString(Empty_Handle).
EscapeSql(szOut[], iMax, const szIn[])
{
	copy(szOut, iMax, szIn);
	replace_all(szOut, iMax, "'", "''");
}

// Prefix-aware table name, matching rsu_core: the core registers the
// rsu_sql_prefix cvar (default "rsu_") and re-publishes the effective value
// in TaskInitSQL, so reading it keeps this UPDATE on the exact table the
// core reads/writes. Falls back to the core default when the cvar (or the
// core itself) is absent - same literal the core builds its CREATE TABLE
// with, so a default deployment is byte-identical to the old hardcode.
GetPlayersTable(szOut[], iMax)
{
	new szPrefix[32];
	new pPrefix = get_cvar_pointer("rsu_sql_prefix");
	if(pPrefix)
		get_pcvar_string(pPrefix, szPrefix, charsmax(szPrefix));
	if(!szPrefix[0])
		copy(szPrefix, charsmax(szPrefix), "rsu_");
	formatex(szOut, iMax, "`%splayers`", szPrefix);
}

public plugin_init()
{
	fn_boot_banner("season", 4)

	register_plugin(PLUGIN, VERSION, AUTHOR)

	pcvar_enabled     = register_cvar("fn_season_enabled", "1")
	pcvar_day         = register_cvar("fn_season_reset_day", "1")
	pcvar_reset_skill = register_cvar("fn_season_reset_skill", "0")

	register_concmd("amx_freenova_season_reset", "CmdForceReset", ADMIN_RCON, "- force a season reset now")
	// Distinct task ids: the hourly repeat previously replaced the initial
	// 15s check (same id), delaying the first reset check by a full hour.
	set_task(15.0, "TaskCheckSeason", TASK_CHECK)
	set_task(3600.0, "TaskCheckSeason", TASK_CHECK + 1, _, _, "b")
}

public TaskCheckSeason()
{
	if(!get_pcvar_num(pcvar_enabled))
	{
		return
	}

	new szDate[12]
	format_time(szDate, charsmax(szDate), "%Y-%m")
	copy(g_szMonthStamp, charsmax(g_szMonthStamp), szDate)

	new szStampFile[64]
	formatex(szStampFile, charsmax(szStampFile), "freenova_season_%s.stamp", g_szMonthStamp)
	new szStampPath[128]
	get_localinfo("datadir", szStampPath, charsmax(szStampPath))
	add(szStampPath, charsmax(szStampPath), "/")
	add(szStampPath, charsmax(szStampPath), szStampFile)

	if(file_exists(szStampPath))
	{
		return // this month already handled
	}

	new iDay = get_pcvar_num(pcvar_day)
	if(iDay < 1)
		iDay = 1
	else if(iDay > 28)
		iDay = 28
	new szToday[3]
	format_time(szToday, charsmax(szToday), "%d")
	new iToday = str_to_num(szToday)

	// Only reset inside the reset-day window (day .. day+2). A fresh
	// deployment mid-month must NOT wipe all XP on its first boot.
	// Day clamped to 28 so Feb never misses the 3-day window.
	if(iToday == iDay || iToday == iDay + 1 || iToday == iDay + 2)
	{
		ExecuteReset()
		write_file(szStampPath, g_szMonthStamp)
	}
}

ExecuteReset()
{
	log_amx("[FreeNova Season] Executing season reset for %s", g_szMonthStamp)

	// 1) Reset every connected player through the compat layer (single owner).
	for(new id = 1; id <= MaxClients; id++)
	{
		if(is_user_connected(id) && !is_user_bot(id) && !is_user_hltv(id))
		{
			crxranks_set_user_xp(id, 0, CRXRANKS_XPS_ADMIN)
		}
	}

	// 2) Reset OFFLINE players directly in the persistence store. With the
	// RSU backend this is the SQLite RanksUltimate database (the old
	// server_cmd("crx_endseason") targeted the retired CRX plugin and was a
	// silent no-op for everyone not online).
	ResetOfflinePlayers()

	client_print_color(0, print_team_default, "^4[FreeNova]^1 A new ranked season has begun! Ranks have been reset - good luck!")
}

// SQLite path: zero XP/level/rank for players not currently connected.
// (MySQL deployment would need the same via UPDATE with NOT IN - the server
// currently runs SQL_DRIVER=sqlite per rank_system_ultimate.ini.)
ResetOfflinePlayers()
{
	// Tuple is created once and freed in plugin_end (no per-reset leak).
	// Must set sqlite affinity first: sqlx defaults to mysql, and this
	// server's RSU store is RanksUltimate.sq3 (see rsu_core TaskInitSQL).
	if(g_hSeasonTuple == Empty_Handle)
	{
		if(!SQL_SetAffinity("sqlite"))
		{
			log_amx("[FreeNova Season] ERROR: sqlite affinity unavailable - offline players NOT reset")
			return
		}
		g_hSeasonTuple = SQL_MakeDbTuple("", "", "", "RanksUltimate")
	}
	if(g_hSeasonTuple == Empty_Handle)
	{
		log_amx("[FreeNova Season] ERROR: could not open RanksUltimate database - offline players NOT reset")
		return
	}

	// rsu_players stores the progression; xp=0 re-derives level/rank_id on
	// the player's next load. Connected humans were already zeroed in
	// memory; exclude their authentic steamids so a dirty RSU autosave
	// cannot race a blanket UPDATE back onto pre-reset XP.
	new szAuth[64], szEsc[80], szNotIn[1024];
	szNotIn[0] = 0;
	new iExcluded = 0;
	for(new id = 1; id <= MaxClients; id++)
	{
		if(!is_user_connected(id) || is_user_bot(id) || is_user_hltv(id))
			continue;

		get_user_authid(id, szAuth, charsmax(szAuth));
		// Authentic STEAM_x:y:z only — skip pending/LAN/empty.
		if(!equali(szAuth, "STEAM_", 6) || contain(szAuth, ":") == -1)
			continue;

		EscapeSql(szEsc, charsmax(szEsc), szAuth);
		if(iExcluded)
			add(szNotIn, charsmax(szNotIn), ",");
		add(szNotIn, charsmax(szNotIn), "'");
		add(szNotIn, charsmax(szNotIn), szEsc);
		add(szNotIn, charsmax(szNotIn), "'");
		iExcluded++;
	}

	new szQuery[1536];
	new szTable[48];
	GetPlayersTable(szTable, charsmax(szTable));
	if(get_pcvar_num(pcvar_reset_skill))
	{
		// fn_season_reset_skill 1: skill rating resets with the season, to
		// RSU_DEFAULT_SKILL - the exact value rsu_core writes in
		// EnsureDatabaseSchema and in the player INSERT (the old hardcoded
		// 100.0 was RSU_MIN_SKILL and left offline players 10x below a new
		// account). lifetime_xp is deliberately preserved (season policy:
		// lifetime counters survive the reset) - matches the in-memory reset
		// of connected players, where rsu_set_xp(0) also keeps lifetime.
		if(iExcluded)
			formatex(szQuery, charsmax(szQuery),
				"UPDATE %s SET xp = 0, level = 1, rank_id = 1, skill = %.1f, peak_skill = %.1f WHERE steamid NOT IN (%s);",
				szTable, RSU_DEFAULT_SKILL, RSU_DEFAULT_SKILL, szNotIn);
		else
			formatex(szQuery, charsmax(szQuery),
				"UPDATE %s SET xp = 0, level = 1, rank_id = 1, skill = %.1f, peak_skill = %.1f;",
				szTable, RSU_DEFAULT_SKILL, RSU_DEFAULT_SKILL);
	}
	else
	{
		if(iExcluded)
			formatex(szQuery, charsmax(szQuery),
				"UPDATE %s SET xp = 0, level = 1, rank_id = 1 WHERE steamid NOT IN (%s);",
				szTable, szNotIn);
		else
			formatex(szQuery, charsmax(szQuery),
				"UPDATE %s SET xp = 0, level = 1, rank_id = 1;",
				szTable);
	}
	SQL_ThreadQuery(g_hSeasonTuple, "ThreadQuery_SeasonReset", szQuery)
}

public ThreadQuery_SeasonReset(failstate, Handle:query, error[], errnum, data[], size, Float:queuetime)
{
	if(failstate != TQUERY_SUCCESS)
	{
		log_amx("[FreeNova Season] SQL reset failed: [%d] %s", errnum, error)
	}
	else
	{
		log_amx("[FreeNova Season] Offline player progression reset in storage.")
	}
}

public plugin_end()
{
	if(g_hSeasonTuple != Empty_Handle)
	{
		SQL_FreeHandle(g_hSeasonTuple)
		g_hSeasonTuple = Empty_Handle
	}
}

public CmdForceReset(id, level, cid)
{
	if(!cmd_access(id, level, cid, 1))
	{
		return PLUGIN_HANDLED
	}

	new szDate[12]
	format_time(szDate, charsmax(szDate), "%Y-%m")
	copy(g_szMonthStamp, charsmax(g_szMonthStamp), szDate)

	ExecuteReset()

	new szStampPath[128]
	get_localinfo("datadir", szStampPath, charsmax(szStampPath))
	add(szStampPath, charsmax(szStampPath), "/freenova_season_")
	add(szStampPath, charsmax(szStampPath), g_szMonthStamp)
	add(szStampPath, charsmax(szStampPath), ".stamp")
	write_file(szStampPath, g_szMonthStamp)

	console_print(id, "[FreeNova] Season reset executed for %s", g_szMonthStamp)
	return PLUGIN_HANDLED
}
