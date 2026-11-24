#include <amxmodx>
#include <amxmisc>
#include <cstrike>
#include <csx>
#include <hamsandwich>
#include <nvault>
#include <crxranks>
#include <crxranks_const>
#include <menabp>
#include <freenova_vip>
#include <rsu>
#include <freenova_ui>
#include <freenova_web>
#include <freenova_missions>
#include <freenova_achievements>
#include <fn_common>

native fn_hub_open(id)

#define PLUGIN  "FreeNova Missions"
#define VERSION "1.2.0"
#define AUTHOR  "FreeNova"

#define TASK_LATELOAD  55000
// Global ticker. 55100 is advanced_bans TASK_KICK (client+55100). remove_task(55100) cancelled a slot-1 ban kick.
#define TASK_PERIOD    56500
#define MAX_PLAYERS    32

// Contract definitions live in configs/freenova/missions.ini. The g_iBuiltin
// table and LoadBuiltinGroup() below are the compiled-in copy of that file and
// are only used when it is missing or a whole group has no valid row, so
// deleting the config can never leave the server without missions.
#define CFG_FILE             "freenova/missions.ini"
#define DEF_DAILY_SET_XP     500
#define DEF_DAILY_SET_COINS  0
#define DEF_WEEKLY_SET_XP    5000
#define DEF_WEEKLY_SET_COINS 1000

// Contract groups. This order is protocol, not preference: freenova_sync packs
// the status of group 0 (daily), 1 (bonus), 2 (weekly) and 3 (VIP) into fixed
// decimal digits and the web panel reads progress by slot index. The config
// changes the rows inside a slot; it never changes how many slots exist.
#define GRP_DAILY  0
#define GRP_BONUS  1
#define GRP_WEEKLY 2
#define GRP_VIP    3
#define GRP_COUNT  4

#define MAX_DAILY_SLOTS  5
#define MAX_BONUS_SLOTS  3
#define MAX_WEEKLY_SLOTS 4
#define MAX_VIP_SLOTS    1
#define MAX_SLOTS        5   // widest group; sizes the shared per-slot arrays

// What advances a slot. A config row names one of these and the counter paths
// feed every open slot that asks for it, so a metric can move between slots
// without touching code.
#define MTR_KILLS     0
#define MTR_HEADSHOTS 1
#define MTR_PLANTS    2
#define MTR_DEFUSES   3
#define MTR_WINS      4
#define MTR_STREAK    5
#define MTR_DAMAGE    6
#define MTR_SURVIVES  7
#define MTR_COUNT     8

// One row per validated [mission] line; candidates are the rows sharing one
// type+slot, i.e. the target variants a roll picks between.
#define MAX_CFG_ROWS 96
#define MAX_CAND     8

new g_VaultBP = INVALID_HANDLE
new bool:g_bPaused
new bool:g_bLoaded[MAX_PLAYERS + 1]

// Per-slot progress. Slot i of each group counts whatever metric the config
// assigns to it, so the counter paths below are metric-driven, not slot-driven.
new g_iDailyProg[MAX_DAILY_SLOTS][MAX_PLAYERS + 1]
new g_iBonusProg[MAX_BONUS_SLOTS][MAX_PLAYERS + 1]
new g_iWeeklyProg[MAX_WEEKLY_SLOTS][MAX_PLAYERS + 1]
new bool:g_bMissionComplete[MAX_PLAYERS + 1]
new bool:g_bWeeklyComplete[MAX_PLAYERS + 1]

// Running kill streak for streak-metric slots (the saved progress is the best).
new g_iStreakRun[MAX_PLAYERS + 1]
new bool:g_bDaily2Paid[MAX_BONUS_SLOTS][MAX_PLAYERS + 1]

new g_iMissionDay[MAX_PLAYERS + 1]
new g_szMissionWeek[MAX_PLAYERS + 1][8]

#define ST_ACTIVE     0
#define ST_CLAIMABLE  1
#define ST_CLAIMED    2

new g_iDailyTarget[MAX_DAILY_SLOTS][MAX_PLAYERS + 1]
new g_iBonusTarget[MAX_BONUS_SLOTS][MAX_PLAYERS + 1]
new g_iWeeklyTarget[MAX_WEEKLY_SLOTS][MAX_PLAYERS + 1]
new g_iDailyStatus[MAX_DAILY_SLOTS][MAX_PLAYERS + 1]
new g_iBonusStatus[MAX_BONUS_SLOTS][MAX_PLAYERS + 1]
new g_iWeeklyStatus[MAX_WEEKLY_SLOTS][MAX_PLAYERS + 1]
new g_iVipProgress[MAX_PLAYERS + 1]
new g_iVipTarget[MAX_PLAYERS + 1]
new g_iVipStatus[MAX_PLAYERS + 1]
new g_iRerollsUsed[MAX_PLAYERS + 1]
new g_iTrackGroup[MAX_PLAYERS + 1]
new g_iTrackSlot[MAX_PLAYERS + 1]
new bool:g_bClaiming[MAX_PLAYERS + 1]

// ---------------------------------------------------------------------------
// Contract config (configs/freenova/missions.ini), resolved at map start.
// ---------------------------------------------------------------------------
new g_iRowCount
new g_szRowId[MAX_CFG_ROWS][40]
new g_szRowTags[MAX_CFG_ROWS][64]
new g_iRowTarget[MAX_CFG_ROWS]
new g_iRowWeight[MAX_CFG_ROWS]

new g_iCandRow[GRP_COUNT][MAX_SLOTS][MAX_CAND]     // row indices, in file order
new g_iCandWeight[GRP_COUNT][MAX_SLOTS][MAX_CAND]  // resolved weight per candidate
new g_iCandCount[GRP_COUNT][MAX_SLOTS]
new g_iSlotMetric[GRP_COUNT][MAX_SLOTS]
new g_iSlotXp[GRP_COUNT][MAX_SLOTS]
new g_iSlotCoins[GRP_COUNT][MAX_SLOTS]
new g_iSlotBaseTarget[GRP_COUNT][MAX_SLOTS]        // first candidate = deterministic base
new bool:g_bSlotUsed[GRP_COUNT][MAX_SLOTS]

new g_iSetXp[GRP_COUNT]
new g_iSetCoins[GRP_COUNT]
new g_iSetNeed[GRP_COUNT]      // 0 = all used slots of the group
new g_szSeason[24]
new bool:g_bCfgLoaded

new const g_szMetricName[MTR_COUNT][] = {
	"kills", "headshots", "plants", "defuses", "wins", "streak", "damage", "survives"
}
new const g_szGroupName[GRP_COUNT][] = { "daily", "bonus", "weekly", "vip" }

public plugin_natives()
{
	register_library("freenova_missions")
	set_native_filter("FnmsnNativeFilter")
	register_native("fnmsn_is_complete", "native_is_complete")
	register_native("fnmsn_get_daily_progress", "native_get_daily")
	register_native("fnmsn_get_daily2_progress", "native_get_daily2")
	register_native("fnmsn_get_weekly_progress", "native_get_weekly")
	register_native("fnmsn_get_daily_done", "native_daily_done")
	register_native("fnmsn_get_bonus_done", "native_bonus_done")
	register_native("fnmsn_get_weekly_done", "native_weekly_done")
	register_native("fnmsn_show", "native_show")
	register_native("fnmsn_claim", "native_claim")
	register_native("fnmsn_reroll", "native_reroll")
	register_native("fnmsn_get_rerolls_left", "native_rerolls_left")
	register_native("fnmsn_get_status", "native_get_status")
	register_native("fnmsn_get_target", "native_get_target")
	register_native("fnmsn_set_track", "native_set_track")
	register_native("fnmsn_get_track", "native_get_track")
	register_native("fnmsn_get_vip_progress", "native_vip_progress")
	register_native("fnmsn_claim_all", "native_claim_all")
}

public FnmsnNativeFilter(const name[], index, trap)
{
	if (equal(name, "menabp_add_coins")
		|| equal(name, "menabp_add_coins_once")
		|| equal(name, "menabp_add_xp_once")
		|| equal(name, "menabp_is_ready")
		|| equal(name, "menabp_get_coins")
		|| equal(name, "fn_hub_open")
		|| equal(name, "fnach_get_count")
		|| equal(name, "fnach_show")
		|| equal(name, "fnvip_get_tier"))
		return PLUGIN_HANDLED
	return PLUGIN_CONTINUE
}

public plugin_init()
{
	fn_boot_banner("missions", 28)

	register_plugin(PLUGIN, VERSION, AUTHOR)

	// lint:allow library-missing - legacy provider name from before the RSU
	// merge (same reason as freenova_achievements.sma): nothing registers it
	// today, so the pause is a no-op until such a plugin is installed again.
	if (LibraryExists("rsu_missions", LibType_Library))
	{
		g_bPaused = true
		log_amx("[FreeNova] rsu_missions loaded — pausing fnmsn grants")
	}

	g_VaultBP = nvault_open("freenova_bp")
	if (g_VaultBP == INVALID_HANDLE)
		log_amx("[FreeNova] missions: nvault freenova_bp failed to open")

	register_clcmd("say /missions", "Cmd_Missions")
	register_clcmd("say_team /missions", "Cmd_Missions")
	register_clcmd("say /daily", "Cmd_Missions")
	register_clcmd("say_team /daily", "Cmd_Missions")
	register_clcmd("say /weekly", "Cmd_Missions")
	register_clcmd("say_team /weekly", "Cmd_Missions")
	register_clcmd("say /mission", "Cmd_Missions")
	register_clcmd("say_team /mission", "Cmd_Missions")
	register_clcmd("say /rsumissions", "Cmd_Missions")
	register_clcmd("say_team /rsumissions", "Cmd_Missions")

	register_logevent("Event_RoundEnd", 2, "1=Round_End")
	RegisterHam(Ham_TakeDamage, "player", "Ham_TakeDamage_Pre")
	set_task(45.0, "Task_PeriodTick", TASK_PERIOD, "", 0, "b")

	LoadMissionsConfig()
}

// Contract definitions are read once per map, before anybody can be connected
// (plugin_init runs first, and only touches the file - no native from another
// plugin is needed). plugin_cfg is kept as the documented reload hook: a late
// amx_load gets its table from whichever of the two runs first.
public plugin_cfg()
{
	if (!g_bCfgLoaded)
		LoadMissionsConfig()
}

public Task_PeriodTick()
{
	new iPlayers[32], iNum
	get_players(iPlayers, iNum, "ch")
	for (new i; i < iNum; i++)
	{
		new id = iPlayers[i]
		if (!g_bLoaded[id])
			continue
		EnsureMissionPeriod(id)
		// Retry parked VIP auto-claims. A deposit that failed because the
		// wallet was not ready (menabp_is_ready false) leaves the slot
		// ST_CLAIMABLE; re-attempt once the wallet is live so the reward is
		// never lost for the session. Gated on wallet-ready so we never
		// re-hit the weekly "could not be paid" notice in a down-wallet loop.
		if (IsVipAuto(id) && LibraryExists("menabp", LibType_Library) && menabp_is_ready(id))
			TryAutoClaimAll(id)
	}
}

public plugin_end()
{
	remove_task(TASK_PERIOD)
		// freenova_bp is a shared global nVault handle. battlepass_core is the
	// sole closer; consumer closes here raced it at map end (Invalid vault id).
}

// ===========================================================================
// Contract config: loading and validation
// ===========================================================================
// Schema and operator notes: the header of configs/freenova/missions.ini and
// docs/RETENTION.md. Every failure path here is "log the line, skip the row,
// keep going": a bad config must never take missions off the server.

GroupSlots(group)
{
	switch (group)
	{
		case GRP_DAILY:  return MAX_DAILY_SLOTS
		case GRP_BONUS:  return MAX_BONUS_SLOTS
		case GRP_WEEKLY: return MAX_WEEKLY_SLOTS
		case GRP_VIP:    return MAX_VIP_SLOTS
	}
	return 0
}

GroupFromName(const szName[])
{
	for (new i; i < GRP_COUNT; i++)
		if (equali(szName, g_szGroupName[i]))
			return i
	return -1
}

MetricFromName(const szName[])
{
	if (equali(szName, "kills") || equali(szName, "frags") || equali(szName, "kill"))
		return MTR_KILLS
	if (equali(szName, "headshots") || equali(szName, "headshot") || equali(szName, "hs"))
		return MTR_HEADSHOTS
	if (equali(szName, "plants") || equali(szName, "plant") || equali(szName, "bomb_plants"))
		return MTR_PLANTS
	if (equali(szName, "defuses") || equali(szName, "defuse") || equali(szName, "bomb_defuses"))
		return MTR_DEFUSES
	if (equali(szName, "wins") || equali(szName, "win") || equali(szName, "round_wins"))
		return MTR_WINS
	if (equali(szName, "streak") || equali(szName, "killstreak"))
		return MTR_STREAK
	if (equali(szName, "damage") || equali(szName, "dmg"))
		return MTR_DAMAGE
	if (equali(szName, "survives") || equali(szName, "survive") || equali(szName, "survived"))
		return MTR_SURVIVES
	return -1
}

// Slots that must be claimed to complete a set. [settings] can lower this;
// otherwise every used slot of the group counts.
SetNeedCount(group)
{
	if (group < 0 || group >= GRP_COUNT)
		return 0
	if (g_iSetNeed[group] > 0)
		return g_iSetNeed[group]
	new iNeed
	for (new i; i < GroupSlots(group); i++)
		if (g_bSlotUsed[group][i])
			iNeed++
	return iNeed
}

ResetConfig()
{
	g_iRowCount = 0
	g_bCfgLoaded = false
	g_szSeason[0] = 0
	for (new g; g < GRP_COUNT; g++)
	{
		g_iSetXp[g] = (g == GRP_DAILY) ? DEF_DAILY_SET_XP : ((g == GRP_WEEKLY) ? DEF_WEEKLY_SET_XP : 0)
		g_iSetCoins[g] = (g == GRP_DAILY) ? DEF_DAILY_SET_COINS : ((g == GRP_WEEKLY) ? DEF_WEEKLY_SET_COINS : 0)
		g_iSetNeed[g] = 0
		for (new s; s < MAX_SLOTS; s++)
		{
			g_bSlotUsed[g][s] = false
			g_iCandCount[g][s] = 0
			g_iSlotMetric[g][s] = -1
			g_iSlotXp[g][s] = 0
			g_iSlotCoins[g][s] = 0
			g_iSlotBaseTarget[g][s] = 0
		}
	}
}

// Strips a trailing comment and surrounding whitespace. A ';' or '#' anywhere
// on the line ends it, so keep both out of ids and tags.
StripConfigLine(szLine[])
{
	for (new i; szLine[i]; i++)
	{
		if (szLine[i] == ';' || szLine[i] == '#')
		{
			szLine[i] = 0
			break
		}
	}
	trim(szLine)
}

// Stores one validated row. The first row of a (group,slot) fixes that slot's
// metric and reward; later rows are target variants and must agree with it,
// otherwise a player's payout would depend on which variant they rolled.
StoreRow(group, slot, metric, target, weight, xp, coins, const szId[], const szTags[], iLine)
{
	if (g_iRowCount >= MAX_CFG_ROWS)
	{
		log_amx("[FreeNova Missions] missions.ini:%d '%s' ignored: row limit %d reached", iLine, szId, MAX_CFG_ROWS)
		return 0
	}
	if (g_iCandCount[group][slot] >= MAX_CAND)
	{
		log_amx("[FreeNova Missions] missions.ini:%d '%s' ignored: %s slot %d already has %d target variants (max %d)",
			iLine, szId, g_szGroupName[group], slot, g_iCandCount[group][slot], MAX_CAND)
		return 0
	}
	if (g_bSlotUsed[group][slot])
	{
		if (g_iSlotMetric[group][slot] != metric || g_iSlotXp[group][slot] != xp || g_iSlotCoins[group][slot] != coins)
		{
			log_amx("[FreeNova Missions] missions.ini:%d '%s' keeps %s slot %d first-row metric %s / xp %d / coins %d",
				iLine, szId, g_szGroupName[group], slot,
				g_szMetricName[g_iSlotMetric[group][slot]], g_iSlotXp[group][slot], g_iSlotCoins[group][slot])
		}
	}
	else
	{
		g_bSlotUsed[group][slot] = true
		g_iSlotMetric[group][slot] = metric
		g_iSlotXp[group][slot] = xp
		g_iSlotCoins[group][slot] = coins
		g_iSlotBaseTarget[group][slot] = target
	}
	new iRow = g_iRowCount
	g_iRowCount++
	copy(g_szRowId[iRow], charsmax(g_szRowId[]), szId)
	copy(g_szRowTags[iRow], charsmax(g_szRowTags[]), szTags)
	g_iRowTarget[iRow] = target
	g_iRowWeight[iRow] = weight
	new iCand = g_iCandCount[group][slot]
	g_iCandRow[group][slot][iCand] = iRow
	g_iCandWeight[group][slot][iCand] = weight
	g_iCandCount[group][slot]++
	return 1
}

// "key = value" line inside [settings].
ParseSettingLine(const szLine[], iLine)
{
	new szLeft[96], szRight[160]
	strtok(szLine, szLeft, charsmax(szLeft), szRight, charsmax(szRight), '=')
	trim(szLeft)
	trim(szRight)
	if (!szLeft[0] || !szRight[0])
	{
		log_amx("[FreeNova Missions] missions.ini:%d skipped: settings line is not 'key = value'", iLine)
		return
	}
	if (equali(szLeft, "season"))
		copy(g_szSeason, charsmax(g_szSeason), szRight)
	else if (equali(szLeft, "daily_set_xp"))
		g_iSetXp[GRP_DAILY] = max(0, str_to_num(szRight))
	else if (equali(szLeft, "daily_set_coins"))
		g_iSetCoins[GRP_DAILY] = max(0, str_to_num(szRight))
	else if (equali(szLeft, "bonus_set_xp"))
		g_iSetXp[GRP_BONUS] = max(0, str_to_num(szRight))
	else if (equali(szLeft, "bonus_set_coins"))
		g_iSetCoins[GRP_BONUS] = max(0, str_to_num(szRight))
	else if (equali(szLeft, "weekly_set_xp"))
		g_iSetXp[GRP_WEEKLY] = max(0, str_to_num(szRight))
	else if (equali(szLeft, "weekly_set_coins"))
		g_iSetCoins[GRP_WEEKLY] = max(0, str_to_num(szRight))
	else if (equali(szLeft, "vip_set_xp"))
		g_iSetXp[GRP_VIP] = max(0, str_to_num(szRight))
	else if (equali(szLeft, "vip_set_coins"))
		g_iSetCoins[GRP_VIP] = max(0, str_to_num(szRight))
	else if (equali(szLeft, "daily_set_slots"))
		g_iSetNeed[GRP_DAILY] = clamp(str_to_num(szRight), 0, MAX_DAILY_SLOTS)
	else if (equali(szLeft, "weekly_set_slots"))
		g_iSetNeed[GRP_WEEKLY] = clamp(str_to_num(szRight), 0, MAX_WEEKLY_SLOTS)
	else
		log_amx("[FreeNova Missions] missions.ini:%d unknown setting '%s' ignored", iLine, szLeft)
}

// One "id | type | slot | metric | target | weight | xp | coins | season | tags"
// line. Missing trailing fields are allowed and read as 0 or empty.
ParseMissionLine(const szLine[], iLine)
{
	new szField[10][64]
	new szRest[256], szRight[256]
	new iFields

	copy(szRest, charsmax(szRest), szLine)
	while (iFields < 10)
	{
		strtok(szRest, szField[iFields], charsmax(szField[]), szRight, charsmax(szRight), '|')
		trim(szField[iFields])
		iFields++
		if (!szRight[0])
			break
		copy(szRest, charsmax(szRest), szRight)
	}
	if (iFields < 5)
	{
		log_amx("[FreeNova Missions] missions.ini:%d skipped: needs at least id, type, slot, metric and target", iLine)
		return
	}

	new szId[40], szTags[64]
	copy(szId, charsmax(szId), szField[0])
	if (!szId[0])
		copy(szId, charsmax(szId), "<unnamed>")
	if (iFields > 9)
		copy(szTags, charsmax(szTags), szField[9])

	new iGroup = GroupFromName(szField[1])
	if (iGroup < 0)
	{
		log_amx("[FreeNova Missions] missions.ini:%d '%s' skipped: type '%s' is not daily, bonus, weekly or vip",
			iLine, szId, szField[1])
		return
	}

	new iSlot = str_to_num(szField[2])
	if (iSlot < 0 || iSlot >= GroupSlots(iGroup))
	{
		log_amx("[FreeNova Missions] missions.ini:%d '%s' skipped: %s slot %d out of range 0..%d",
			iLine, szId, g_szGroupName[iGroup], iSlot, GroupSlots(iGroup) - 1)
		return
	}

	new iMetric = MetricFromName(szField[3])
	if (iMetric < 0)
	{
		log_amx("[FreeNova Missions] missions.ini:%d '%s' skipped: metric '%s' is not one of kills, headshots, plants, defuses, wins, streak, damage, survives",
			iLine, szId, szField[3])
		return
	}

	new iTarget = str_to_num(szField[4])
	if (iTarget <= 0)
	{
		log_amx("[FreeNova Missions] missions.ini:%d '%s' skipped: target '%s' must be greater than 0",
			iLine, szId, szField[4])
		return
	}

	new iWeight = szField[5][0] ? str_to_num(szField[5]) : 1
	if (iWeight <= 0)
	{
		log_amx("[FreeNova Missions] missions.ini:%d '%s' is inactive (weight 0) - kept in the file, never rolled",
			iLine, szId)
		return
	}

	new iXp = szField[6][0] ? str_to_num(szField[6]) : 0
	if (iXp < 0)
	{
		log_amx("[FreeNova Missions] missions.ini:%d '%s': xp %d clamped to 0", iLine, szId, iXp)
		iXp = 0
	}
	new iCoins = szField[7][0] ? str_to_num(szField[7]) : 0
	if (iCoins < 0)
	{
		log_amx("[FreeNova Missions] missions.ini:%d '%s': coins %d clamped to 0", iLine, szId, iCoins)
		iCoins = 0
	}

	// A row tagged with another season is staged for later, not an error.
	if (szField[8][0] && g_szSeason[0] && !equali(szField[8], g_szSeason))
	{
		log_amx("[FreeNova Missions] missions.ini:%d '%s' staged: season '%s', active season is '%s'",
			iLine, szId, szField[8], g_szSeason)
		return
	}

	StoreRow(iGroup, iSlot, iMetric, iTarget, iWeight, iXp, iCoins, szId, szTags, iLine)
}

// Compiled-in copy of the shipped missions.ini, as {group, slot, metric, target,
// weight, coins}. Only reached for a missing file, or for a group whose rows
// were all rejected.
new const g_iBuiltin[][6] = {
	// DAILY
	{GRP_DAILY,  0, MTR_KILLS,      10, 1,   0},
	{GRP_DAILY,  0, MTR_KILLS,      15, 1,   0},
	{GRP_DAILY,  0, MTR_KILLS,      25, 1,   0},
	{GRP_DAILY,  0, MTR_KILLS,      40, 1,   0},
	{GRP_DAILY,  1, MTR_HEADSHOTS,   2, 1,   0},
	{GRP_DAILY,  1, MTR_HEADSHOTS,   3, 1,   0},
	{GRP_DAILY,  1, MTR_HEADSHOTS,   6, 1,   0},
	{GRP_DAILY,  1, MTR_HEADSHOTS,  10, 1,   0},
	{GRP_DAILY,  2, MTR_PLANTS,      1, 1,   0},
	{GRP_DAILY,  2, MTR_PLANTS,      2, 1,   0},
	{GRP_DAILY,  2, MTR_PLANTS,      3, 1,   0},
	{GRP_DAILY,  2, MTR_PLANTS,      5, 1,   0},
	{GRP_DAILY,  3, MTR_DEFUSES,     1, 2,   0},
	{GRP_DAILY,  3, MTR_DEFUSES,     2, 1,   0},
	{GRP_DAILY,  3, MTR_DEFUSES,     3, 1,   0},
	{GRP_DAILY,  4, MTR_WINS,        1, 1,   0},
	{GRP_DAILY,  4, MTR_WINS,        2, 1,   0},
	{GRP_DAILY,  4, MTR_WINS,        4, 1,   0},
	{GRP_DAILY,  4, MTR_WINS,        6, 1,   0},
	// BONUS
	{GRP_BONUS,  0, MTR_STREAK,      3, 1, 150},
	{GRP_BONUS,  0, MTR_STREAK,      5, 1, 150},
	{GRP_BONUS,  0, MTR_STREAK,      8, 1, 150},
	{GRP_BONUS,  0, MTR_STREAK,     10, 1, 150},
	{GRP_BONUS,  1, MTR_DAMAGE,    300, 1, 100},
	{GRP_BONUS,  1, MTR_DAMAGE,    500, 1, 100},
	{GRP_BONUS,  1, MTR_DAMAGE,   1000, 1, 100},
	{GRP_BONUS,  1, MTR_DAMAGE,   2000, 1, 100},
	{GRP_BONUS,  2, MTR_SURVIVES,    2, 1, 100},
	{GRP_BONUS,  2, MTR_SURVIVES,    3, 1, 100},
	{GRP_BONUS,  2, MTR_SURVIVES,    5, 1, 100},
	{GRP_BONUS,  2, MTR_SURVIVES,    8, 1, 100},
	// WEEKLY
	{GRP_WEEKLY, 0, MTR_KILLS,      70, 1,   0},
	{GRP_WEEKLY, 0, MTR_KILLS,     100, 1,   0},
	{GRP_WEEKLY, 0, MTR_KILLS,     150, 1,   0},
	{GRP_WEEKLY, 0, MTR_KILLS,     200, 1,   0},
	{GRP_WEEKLY, 1, MTR_HEADSHOTS,  15, 1,   0},
	{GRP_WEEKLY, 1, MTR_HEADSHOTS,  25, 1,   0},
	{GRP_WEEKLY, 1, MTR_HEADSHOTS,  40, 1,   0},
	{GRP_WEEKLY, 1, MTR_HEADSHOTS,  60, 1,   0},
	{GRP_WEEKLY, 2, MTR_PLANTS,      6, 1,   0},
	{GRP_WEEKLY, 2, MTR_PLANTS,     10, 1,   0},
	{GRP_WEEKLY, 2, MTR_PLANTS,     15, 1,   0},
	{GRP_WEEKLY, 2, MTR_PLANTS,     20, 1,   0},
	{GRP_WEEKLY, 3, MTR_WINS,       10, 1,   0},
	{GRP_WEEKLY, 3, MTR_WINS,       15, 1,   0},
	{GRP_WEEKLY, 3, MTR_WINS,       25, 1,   0},
	{GRP_WEEKLY, 3, MTR_WINS,       40, 1,   0},
	// VIP EXTRA
	{GRP_VIP,    0, MTR_KILLS,      20, 1, 150}
}

LoadBuiltinGroup(group)
{
	for (new i; i < sizeof g_iBuiltin; i++)
	{
		if (g_iBuiltin[i][0] != group)
			continue
		StoreRow(group, g_iBuiltin[i][1], g_iBuiltin[i][2], g_iBuiltin[i][3],
			g_iBuiltin[i][4], 0, g_iBuiltin[i][5], "builtin", "builtin", 0)
	}
}

// Fills any group that ended up with no usable slot, then reports what was
// loaded. Never fails: all four groups exist afterwards.
FinishConfig(const szSource[])
{
	new iFallback
	for (new g; g < GRP_COUNT; g++)
	{
		new bool:bAny
		for (new s; s < GroupSlots(g); s++)
		{
			if (g_iCandCount[g][s] > 0)
			{
				bAny = true
				break
			}
		}
		if (!bAny)
		{
			log_amx("[FreeNova Missions] no usable %s row in %s - using the built-in %s table",
				g_szGroupName[g], CFG_FILE, g_szGroupName[g])
			LoadBuiltinGroup(g)
			iFallback++
		}
	}

	g_bCfgLoaded = true
	new iDaily, iBonus, iWeekly, iVip
	for (new s; s < MAX_DAILY_SLOTS; s++)  if (g_bSlotUsed[GRP_DAILY][s])  iDaily++
	for (new s; s < MAX_BONUS_SLOTS; s++)  if (g_bSlotUsed[GRP_BONUS][s])  iBonus++
	for (new s; s < MAX_WEEKLY_SLOTS; s++) if (g_bSlotUsed[GRP_WEEKLY][s]) iWeekly++
	for (new s; s < MAX_VIP_SLOTS; s++)    if (g_bSlotUsed[GRP_VIP][s])    iVip++
	log_amx("[FreeNova Missions] contract table from %s: %d rows, season '%s', slots daily %d/%d bonus %d/%d weekly %d/%d vip %d/%d, %d group(s) on built-in",
		szSource, g_iRowCount, g_szSeason[0] ? g_szSeason : "any",
		iDaily, MAX_DAILY_SLOTS, iBonus, MAX_BONUS_SLOTS, iWeekly, MAX_WEEKLY_SLOTS,
		iVip, MAX_VIP_SLOTS, iFallback)
}

LoadMissionsConfig()
{
	ResetConfig()

	new szPath[128]
	get_configsdir(szPath, charsmax(szPath))
	add(szPath, charsmax(szPath), "/")
	add(szPath, charsmax(szPath), CFG_FILE)

	if (!file_exists(szPath))
	{
		log_amx("[FreeNova Missions] %s is missing - running on the built-in contract table", szPath)
		FinishConfig("built-in")
		return
	}

	new fp = fopen(szPath, "rt")
	if (!fp)
	{
		log_amx("[FreeNova Missions] cannot open %s - running on the built-in contract table", szPath)
		FinishConfig("built-in")
		return
	}

	new szLine[256], szSection[24], iLine
	while (fgets(fp, szLine, charsmax(szLine)))
	{
		iLine++
		StripConfigLine(szLine)
		if (!szLine[0])
			continue
		if (szLine[0] == '[')
		{
			new iEnd = contain(szLine, "]")
			if (iEnd > 1)
				szLine[iEnd] = 0
			else
				szLine[0] = 0
			copy(szSection, charsmax(szSection), szLine[1])
			trim(szSection)
			if (!equali(szSection, "settings") && !equali(szSection, "mission"))
				log_amx("[FreeNova Missions] missions.ini:%d unknown section [%s] ignored", iLine, szSection)
			continue
		}
		if (equali(szSection, "settings"))
			ParseSettingLine(szLine, iLine)
		else if (equali(szSection, "mission"))
			ParseMissionLine(szLine, iLine)
		else
			log_amx("[FreeNova Missions] missions.ini:%d line outside [settings]/[mission] ignored", iLine)
	}
	fclose(fp)

	FinishConfig(CFG_FILE)
}

public client_putinserver(id)
{
	ResetClient(id)
	if (is_user_bot(id))
		return
	new szAuth[40]
	get_user_authid(id, szAuth, charsmax(szAuth))
	if (!szAuth[0] || equal(szAuth, "STEAM_ID_PENDING") || equal(szAuth, "UNKNOWN"))
	{
		set_task(5.0, "Task_LateLoad", id + TASK_LATELOAD)
		return
	}
	DoLoad(id)
}

public Task_LateLoad(taskid)
{
	new id = taskid - TASK_LATELOAD
	if (!is_user_connected(id) || is_user_bot(id))
		return
	new szAuth[40]
	get_user_authid(id, szAuth, charsmax(szAuth))
	if (!szAuth[0] || equal(szAuth, "STEAM_ID_PENDING") || equal(szAuth, "UNKNOWN"))
	{
		set_task(3.0, "Task_LateLoad", id + TASK_LATELOAD)
		return
	}
	DoLoad(id)
}

public client_disconnected(id)
{
	remove_task(id + TASK_LATELOAD)
	if (g_bLoaded[id] && !is_user_bot(id))
	{
		SaveDailyMissions(id)
		SaveWeeklyMissions(id)
		SaveDaily2(id)
		SaveRoll(id)
	}
	ResetClient(id)
}

ResetClient(id)
{
	g_bLoaded[id] = false
	for (new i; i < MAX_DAILY_SLOTS; i++)
	{
		g_iDailyProg[i][id] = 0
		g_iDailyTarget[i][id] = 0
		g_iDailyStatus[i][id] = ST_ACTIVE
	}
	for (new i; i < MAX_BONUS_SLOTS; i++)
	{
		g_iBonusProg[i][id] = 0
		g_iBonusTarget[i][id] = 0
		g_iBonusStatus[i][id] = ST_ACTIVE
		g_bDaily2Paid[i][id] = false
	}
	for (new i; i < MAX_WEEKLY_SLOTS; i++)
	{
		g_iWeeklyProg[i][id] = 0
		g_iWeeklyTarget[i][id] = 0
		g_iWeeklyStatus[i][id] = ST_ACTIVE
	}
	g_bMissionComplete[id] = false
	g_bWeeklyComplete[id] = false
	g_iStreakRun[id] = 0
	g_iMissionDay[id] = 0
	g_szMissionWeek[id][0] = 0
	g_iVipProgress[id] = 0
	g_iVipTarget[id] = (g_iSlotBaseTarget[GRP_VIP][0] > 0) ? g_iSlotBaseTarget[GRP_VIP][0] : 20
	g_iVipStatus[id] = ST_ACTIVE
	g_iRerollsUsed[id] = 0
	g_iTrackGroup[id] = -1
	g_iTrackSlot[id] = 0
	g_bClaiming[id] = false
}

DoLoad(id)
{
	LoadDailyMissions(id)
	LoadWeeklyMissions(id)
	LoadDaily2(id)
	g_bLoaded[id] = true
	EnsureRoll(id)
	CheckDailyMissions(id)
	CheckWeeklyMissions(id)
	CheckDaily2(id)
	TryAutoClaimAll(id)
}

GetVaultKey(id, output[], len, const prefix[])
{
	new authid[40]
	get_user_authid(id, authid, charsmax(authid))
	for (new i = 0; authid[i]; i++)
	{
		if (authid[i] == ':')
			authid[i] = '_'
	}
	if (equal(prefix, "weekly"))
	{
		new szWeek[8]
		format_time(szWeek, charsmax(szWeek), "%G-%V")
		formatex(output, len, "%s#%s#%s", prefix, szWeek, authid)
		return
	}
	if (equal(prefix, "daily") || equal(prefix, "daily2") || equal(prefix, "roll"))
	{
		new szDay[12]
		format_time(szDay, charsmax(szDay), "%Y%m%d")
		formatex(output, len, "%s#%s#%s", prefix, szDay, authid)
		return
	}
	formatex(output, len, "%s#%s", prefix, authid)
}

// Award-id period tag: per day for daily/bonus/vip, per ISO week for weekly.
// Keeps every once-only payout of a period idempotent across reconnects.
PeriodTag(group, output[], len)
{
	if (group == GRP_WEEKLY)
		format_time(output, len, "%G-%V")
	else
		format_time(output, len, "%Y%m%d")
}

EnsureMissionPeriod(id)
{
	if (!ValidId(id) || is_user_bot(id) || !g_bLoaded[id])
		return
	new szDay[12], iDay
	format_time(szDay, charsmax(szDay), "%Y%m%d")
	iDay = str_to_num(szDay)
	new szWeek[8]
	format_time(szWeek, charsmax(szWeek), "%G-%V")
	if (g_iMissionDay[id] == iDay && equal(g_szMissionWeek[id], szWeek))
		return
	if (g_iMissionDay[id] != iDay)
	{
		LoadDailyMissions(id)
		LoadDaily2(id)
		g_iStreakRun[id] = 0
		g_iRerollsUsed[id] = 0
		g_iVipProgress[id] = 0
		g_iVipStatus[id] = ST_ACTIVE
		EnsureRoll(id)
	}
	if (!equal(g_szMissionWeek[id], szWeek))
	{
		LoadWeeklyMissions(id)
		EnsureRoll(id)
	}
}

LoadDailyMissions(id)
{
	for (new i; i < MAX_DAILY_SLOTS; i++)
		g_iDailyProg[i][id] = 0
	g_bMissionComplete[id] = false
	if (g_VaultBP != INVALID_HANDLE)
	{
		new key[64], value[64]
		GetVaultKey(id, key, charsmax(key), "daily")
		if (nvault_get(g_VaultBP, key, value, charsmax(value)))
		{
			new part[16], left[64]
			copy(left, charsmax(left), value)
			for (new i; i < MAX_DAILY_SLOTS; i++)
			{
				strtok(left, part, charsmax(part), left, charsmax(left), ' ')
				g_iDailyProg[i][id] = str_to_num(part)
			}
			g_bMissionComplete[id] = bool:str_to_num(left)
		}
	}
	new szDay[12]
	format_time(szDay, charsmax(szDay), "%Y%m%d")
	g_iMissionDay[id] = str_to_num(szDay)
}

SaveDailyMissions(id)
{
	if (g_VaultBP == INVALID_HANDLE || !g_bLoaded[id])
		return
	new key[64], value[64]
	GetVaultKey(id, key, charsmax(key), "daily")
	// Format unchanged from 1.1.0 on purpose: five progress cells then the
	// set-complete flag, so a player mid-period keeps their progress.
	formatex(value, charsmax(value), "%d %d %d %d %d %d",
		g_iDailyProg[0][id], g_iDailyProg[1][id], g_iDailyProg[2][id],
		g_iDailyProg[3][id], g_iDailyProg[4][id], _:g_bMissionComplete[id])
	nvault_set(g_VaultBP, key, value)
}

LoadWeeklyMissions(id)
{
	for (new i; i < MAX_WEEKLY_SLOTS; i++)
		g_iWeeklyProg[i][id] = 0
	g_bWeeklyComplete[id] = false
	if (g_VaultBP != INVALID_HANDLE)
	{
		new key[64], value[64]
		GetVaultKey(id, key, charsmax(key), "weekly")
		if (nvault_get(g_VaultBP, key, value, charsmax(value)))
		{
			new part[16], left[64]
			copy(left, charsmax(left), value)
			for (new i; i < MAX_WEEKLY_SLOTS; i++)
			{
				strtok(left, part, charsmax(part), left, charsmax(left), ' ')
				g_iWeeklyProg[i][id] = str_to_num(part)
			}
			g_bWeeklyComplete[id] = bool:str_to_num(left)
		}
	}
	format_time(g_szMissionWeek[id], charsmax(g_szMissionWeek[]), "%G-%V")
}

SaveWeeklyMissions(id)
{
	if (g_VaultBP == INVALID_HANDLE || !g_bLoaded[id])
		return
	new key[64], value[64]
	GetVaultKey(id, key, charsmax(key), "weekly")
	formatex(value, charsmax(value), "%d %d %d %d %d",
		g_iWeeklyProg[0][id], g_iWeeklyProg[1][id], g_iWeeklyProg[2][id],
		g_iWeeklyProg[3][id], _:g_bWeeklyComplete[id])
	nvault_set(g_VaultBP, key, value)
}

LoadDaily2(id)
{
	for (new i; i < MAX_BONUS_SLOTS; i++)
	{
		g_iBonusProg[i][id] = 0
		g_bDaily2Paid[i][id] = false
	}
	if (g_VaultBP != INVALID_HANDLE)
	{
		new key[64], value[64]
		GetVaultKey(id, key, charsmax(key), "daily2")
		if (nvault_get(g_VaultBP, key, value, charsmax(value)))
		{
			new part[16], left[64]
			copy(left, charsmax(left), value)
			for (new i; i < MAX_BONUS_SLOTS; i++)
			{
				strtok(left, part, charsmax(part), left, charsmax(left), ' ')
				g_iBonusProg[i][id] = str_to_num(part)
			}
			for (new i; i < MAX_BONUS_SLOTS; i++)
			{
				strtok(left, part, charsmax(part), left, charsmax(left), ' ')
				g_bDaily2Paid[i][id] = bool:str_to_num(part)
			}
		}
	}
}

SaveDaily2(id)
{
	if (g_VaultBP == INVALID_HANDLE || !g_bLoaded[id])
		return
	new key[64], value[64]
	GetVaultKey(id, key, charsmax(key), "daily2")
	formatex(value, charsmax(value), "%d %d %d %d %d %d",
		g_iBonusProg[0][id], g_iBonusProg[1][id], g_iBonusProg[2][id],
		_:g_bDaily2Paid[0][id], _:g_bDaily2Paid[1][id], _:g_bDaily2Paid[2][id])
	nvault_set(g_VaultBP, key, value)
}

AddCoins(id, amount)
{
	if (amount == 0)
		return 1
	if (!LibraryExists("menabp", LibType_Library))
		return 0
	if (amount > 0)
	{
		// Fail-safe: a deposit only counts as paid when the wallet is live
		// and the native accepted it (menabp_add_coins returns 0 while the
		// player's BP data is not loaded yet).
		if (!menabp_is_ready(id))
			return 0
		if (menabp_add_coins(id, amount) != 0)
			return 1
		return 0
	}
	new iCost = -amount
	new iBefore = menabp_get_coins(id)
	if (iBefore < iCost)
		return 0
	new iAfter = menabp_add_coins(id, amount)
	if (iAfter == 0 && menabp_get_coins(id) >= iBefore)
		return 0
	if (menabp_get_coins(id) > iBefore - iCost)
		return 0
	return 1
}

VipTier(id)
{
	if (LibraryExists("freenova_vip", LibType_Library))
		return fnvip_get_tier(id)
	return 0
}

bool:IsVipAuto(id)
{
	return VipTier(id) >= FNVIP_VIP
}

FreeRerolls(id)
{
	new t = VipTier(id)
	if (t >= FNVIP_ELITE) return 4
	if (t >= FNVIP_VIPPLUS) return 3
	if (t >= FNVIP_VIP) return 2
	return 1
}

RerollCost(id)
{
	new t = VipTier(id)
	if (t >= FNVIP_ELITE) return 100
	if (t >= FNVIP_VIPPLUS) return 150
	return 200
}

RerollsLeft(id)
{
	new left = FreeRerolls(id) - g_iRerollsUsed[id]
	return (left > 0) ? left : 0
}

// Deterministic base targets: the first configured candidate of every used
// slot. RollTargets() replaces them with the weighted pick when a roll is due.
ApplyMediumDefaults(id)
{
	for (new i; i < MAX_SLOTS; i++)
	{
		g_iDailyTarget[i][id] = g_bSlotUsed[GRP_DAILY][i] ? g_iSlotBaseTarget[GRP_DAILY][i] : 0
		g_iBonusTarget[i][id] = g_bSlotUsed[GRP_BONUS][i] ? g_iSlotBaseTarget[GRP_BONUS][i] : 0
		g_iWeeklyTarget[i][id] = g_bSlotUsed[GRP_WEEKLY][i] ? g_iSlotBaseTarget[GRP_WEEKLY][i] : 0
	}
	if (g_bSlotUsed[GRP_VIP][0] && g_iSlotBaseTarget[GRP_VIP][0] > 0)
		g_iVipTarget[id] = g_iSlotBaseTarget[GRP_VIP][0]
	else if (!g_iVipTarget[id])
		g_iVipTarget[id] = 20
}

// Weighted pick among the rows of one (group,slot). 0 = the slot has no row.
RollSlotTarget(group, slot)
{
	if (group < 0 || group >= GRP_COUNT || !g_bSlotUsed[group][slot])
		return 0
	if (g_iCandCount[group][slot] <= 0)
		return 0
	new iTotal
	for (new i; i < g_iCandCount[group][slot]; i++)
		iTotal += g_iCandWeight[group][slot][i]
	if (iTotal <= 0)
		return g_iSlotBaseTarget[group][slot]
	new iPick = random_num(1, iTotal)
	for (new i; i < g_iCandCount[group][slot]; i++)
	{
		iPick -= g_iCandWeight[group][slot][i]
		if (iPick <= 0)
			return g_iRowTarget[g_iCandRow[group][slot][i]]
	}
	return g_iSlotBaseTarget[group][slot]
}

RollTargets(id, bool:bForce)
{
	// bForce = a new period: every used slot is re-rolled and reopened. Without
	// it only slots still ST_ACTIVE are re-rolled, so a claimable or claimed
	// slot keeps the target the player was working on.
	for (new i; i < MAX_DAILY_SLOTS; i++)
	{
		if (!g_bSlotUsed[GRP_DAILY][i])
		{
			g_iDailyTarget[i][id] = 0
			g_iDailyStatus[i][id] = ST_CLAIMED
			continue
		}
		if (!bForce && g_iDailyStatus[i][id] != ST_ACTIVE)
			continue
		g_iDailyTarget[i][id] = RollSlotTarget(GRP_DAILY, i)
		if (g_iDailyStatus[i][id] != ST_CLAIMED)
			g_iDailyStatus[i][id] = ST_ACTIVE
	}
	for (new i; i < MAX_BONUS_SLOTS; i++)
	{
		if (!g_bSlotUsed[GRP_BONUS][i])
		{
			g_iBonusTarget[i][id] = 0
			g_iBonusStatus[i][id] = ST_CLAIMED
			continue
		}
		if (!bForce && g_iBonusStatus[i][id] != ST_ACTIVE)
			continue
		g_iBonusTarget[i][id] = RollSlotTarget(GRP_BONUS, i)
		if (g_iBonusStatus[i][id] != ST_CLAIMED)
			g_iBonusStatus[i][id] = ST_ACTIVE
	}
	for (new i; i < MAX_WEEKLY_SLOTS; i++)
	{
		if (!g_bSlotUsed[GRP_WEEKLY][i])
		{
			g_iWeeklyTarget[i][id] = 0
			g_iWeeklyStatus[i][id] = ST_CLAIMED
			continue
		}
		if (!bForce && g_iWeeklyStatus[i][id] != ST_ACTIVE)
			continue
		g_iWeeklyTarget[i][id] = RollSlotTarget(GRP_WEEKLY, i)
		if (g_iWeeklyStatus[i][id] != ST_CLAIMED)
			g_iWeeklyStatus[i][id] = ST_ACTIVE
	}
	if (!g_bSlotUsed[GRP_VIP][0])
		g_iVipStatus[id] = ST_CLAIMED
	else if (!g_iVipTarget[id])
		g_iVipTarget[id] = RollSlotTarget(GRP_VIP, 0)
}

// A slot that has no row cannot be worked on or claimed. Marking it claimed
// keeps it out of the set-completion count without ever paying anything.
PruneUnusedSlots(id)
{
	for (new i; i < MAX_DAILY_SLOTS; i++)
	{
		if (g_bSlotUsed[GRP_DAILY][i])
			continue
		g_iDailyTarget[i][id] = 0
		g_iDailyStatus[i][id] = ST_CLAIMED
	}
	for (new i; i < MAX_BONUS_SLOTS; i++)
	{
		if (g_bSlotUsed[GRP_BONUS][i])
			continue
		g_iBonusTarget[i][id] = 0
		g_iBonusStatus[i][id] = ST_CLAIMED
	}
	for (new i; i < MAX_WEEKLY_SLOTS; i++)
	{
		if (g_bSlotUsed[GRP_WEEKLY][i])
			continue
		g_iWeeklyTarget[i][id] = 0
		g_iWeeklyStatus[i][id] = ST_CLAIMED
	}
	if (!g_bSlotUsed[GRP_VIP][0])
		g_iVipStatus[id] = ST_CLAIMED
}

bool:AnySlotTarget(id)
{
	for (new i; i < MAX_DAILY_SLOTS; i++)
		if (g_bSlotUsed[GRP_DAILY][i] && g_iDailyTarget[i][id] > 0)
			return true
	for (new i; i < MAX_WEEKLY_SLOTS; i++)
		if (g_bSlotUsed[GRP_WEEKLY][i] && g_iWeeklyTarget[i][id] > 0)
			return true
	return false
}

LoadRoll(id)
{
	ApplyMediumDefaults(id)
	if (g_VaultBP == INVALID_HANDLE)
		return 0
	new key[64], value[128]
	GetVaultKey(id, key, charsmax(key), "roll")
	if (!nvault_get(g_VaultBP, key, value, charsmax(value)))
		return 0
	new part[16], left[128]
	copy(left, charsmax(left), value)
	for (new i; i < MAX_DAILY_SLOTS; i++)
	{
		strtok(left, part, charsmax(part), left, charsmax(left), ' ')
		g_iDailyTarget[i][id] = str_to_num(part)
		strtok(left, part, charsmax(part), left, charsmax(left), ' ')
		g_iDailyStatus[i][id] = str_to_num(part)
	}
	for (new i; i < MAX_BONUS_SLOTS; i++)
	{
		strtok(left, part, charsmax(part), left, charsmax(left), ' ')
		g_iBonusTarget[i][id] = str_to_num(part)
		strtok(left, part, charsmax(part), left, charsmax(left), ' ')
		g_iBonusStatus[i][id] = str_to_num(part)
	}
	for (new i; i < MAX_WEEKLY_SLOTS; i++)
	{
		strtok(left, part, charsmax(part), left, charsmax(left), ' ')
		g_iWeeklyTarget[i][id] = str_to_num(part)
		strtok(left, part, charsmax(part), left, charsmax(left), ' ')
		g_iWeeklyStatus[i][id] = str_to_num(part)
	}
	strtok(left, part, charsmax(part), left, charsmax(left), ' ')
	g_iVipTarget[id] = str_to_num(part)
	strtok(left, part, charsmax(part), left, charsmax(left), ' ')
	g_iVipProgress[id] = str_to_num(part)
	strtok(left, part, charsmax(part), left, charsmax(left), ' ')
	g_iVipStatus[id] = str_to_num(part)
	strtok(left, part, charsmax(part), left, charsmax(left), ' ')
	g_iRerollsUsed[id] = str_to_num(part)
	// A stored status outside 0..2 would make a slot permanently unclaimable.
	for (new i; i < MAX_DAILY_SLOTS; i++)
		if (g_iDailyStatus[i][id] < ST_ACTIVE || g_iDailyStatus[i][id] > ST_CLAIMED)
			g_iDailyStatus[i][id] = ST_ACTIVE
	for (new i; i < MAX_BONUS_SLOTS; i++)
		if (g_iBonusStatus[i][id] < ST_ACTIVE || g_iBonusStatus[i][id] > ST_CLAIMED)
			g_iBonusStatus[i][id] = ST_ACTIVE
	for (new i; i < MAX_WEEKLY_SLOTS; i++)
		if (g_iWeeklyStatus[i][id] < ST_ACTIVE || g_iWeeklyStatus[i][id] > ST_CLAIMED)
			g_iWeeklyStatus[i][id] = ST_ACTIVE
	if (g_iVipStatus[id] < ST_ACTIVE || g_iVipStatus[id] > ST_CLAIMED)
		g_iVipStatus[id] = ST_ACTIVE
	PruneUnusedSlots(id)
	return 1
}

SaveRoll(id)
{
	if (g_VaultBP == INVALID_HANDLE || !g_bLoaded[id])
		return
	new key[64], value[128]
	GetVaultKey(id, key, charsmax(key), "roll")
	// 28 cells, 28 format specifiers. The 1.1.0 string had 27 specifiers for 28
	// arguments, so g_iRerollsUsed was never written and every reconnect handed
	// the day's free rerolls back. Old blobs simply have no 28th cell and read
	// it as 0, which is exactly the old behaviour.
	formatex(value, charsmax(value), "%d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d %d",
		g_iDailyTarget[0][id], g_iDailyStatus[0][id],
		g_iDailyTarget[1][id], g_iDailyStatus[1][id],
		g_iDailyTarget[2][id], g_iDailyStatus[2][id],
		g_iDailyTarget[3][id], g_iDailyStatus[3][id],
		g_iDailyTarget[4][id], g_iDailyStatus[4][id],
		g_iBonusTarget[0][id], g_iBonusStatus[0][id],
		g_iBonusTarget[1][id], g_iBonusStatus[1][id],
		g_iBonusTarget[2][id], g_iBonusStatus[2][id],
		g_iWeeklyTarget[0][id], g_iWeeklyStatus[0][id],
		g_iWeeklyTarget[1][id], g_iWeeklyStatus[1][id],
		g_iWeeklyTarget[2][id], g_iWeeklyStatus[2][id],
		g_iWeeklyTarget[3][id], g_iWeeklyStatus[3][id],
		g_iVipTarget[id], g_iVipProgress[id], g_iVipStatus[id], g_iRerollsUsed[id])
	nvault_set(g_VaultBP, key, value)
}

EnsureRoll(id)
{
	if (LoadRoll(id) && AnySlotTarget(id))
	{
		new iNeedDaily = SetNeedCount(GRP_DAILY), iNeedWeekly = SetNeedCount(GRP_WEEKLY)
		new bool:bRepairDaily = false, bool:bRepairWeekly = false
		if (iNeedDaily > 0 && !g_bMissionComplete[id] && DailyDoneCount(id) >= iNeedDaily)
		{
			g_bMissionComplete[id] = true
			bRepairDaily = true
		}
		if (iNeedWeekly > 0 && !g_bWeeklyComplete[id] && WeeklyDoneCount(id) >= iNeedWeekly)
		{
			g_bWeeklyComplete[id] = true
			bRepairWeekly = true
		}
		if (bRepairDaily)
			SaveDailyMissions(id)
		if (bRepairWeekly)
			SaveWeeklyMissions(id)
		if (bRepairDaily || bRepairWeekly)
			SaveRoll(id)
		return
	}
	ApplyMediumDefaults(id)
	RollTargets(id, true)
	// Repair a crash window between the slot save and the completion save.
	new iNeedDaily = SetNeedCount(GRP_DAILY), iNeedWeekly = SetNeedCount(GRP_WEEKLY)
	if (iNeedDaily > 0 && !g_bMissionComplete[id] && DailyDoneCount(id) >= iNeedDaily)
		g_bMissionComplete[id] = true
	if (iNeedWeekly > 0 && !g_bWeeklyComplete[id] && WeeklyDoneCount(id) >= iNeedWeekly)
		g_bWeeklyComplete[id] = true
	if (g_bMissionComplete[id])
	{
		for (new i; i < MAX_DAILY_SLOTS; i++)
			g_iDailyStatus[i][id] = ST_CLAIMED
	}
	for (new i; i < MAX_BONUS_SLOTS; i++)
	{
		if (g_bDaily2Paid[i][id])
			g_iBonusStatus[i][id] = ST_CLAIMED
	}
	if (g_bWeeklyComplete[id])
	{
		for (new i; i < MAX_WEEKLY_SLOTS; i++)
			g_iWeeklyStatus[i][id] = ST_CLAIMED
	}
	SaveRoll(id)
	if (g_bMissionComplete[id])
		SaveDailyMissions(id)
	if (g_bWeeklyComplete[id])
		SaveWeeklyMissions(id)
}

MarkClaimable(id, group, slot)
{
	new iOld
	if (group == GRP_DAILY)
	{
		iOld = g_iDailyStatus[slot][id]
		if (iOld != ST_ACTIVE)
			return
		g_iDailyStatus[slot][id] = ST_CLAIMABLE
	}
	else if (group == GRP_BONUS)
	{
		iOld = g_iBonusStatus[slot][id]
		if (iOld != ST_ACTIVE)
			return
		g_iBonusStatus[slot][id] = ST_CLAIMABLE
	}
	else if (group == GRP_WEEKLY)
	{
		iOld = g_iWeeklyStatus[slot][id]
		if (iOld != ST_ACTIVE)
			return
		g_iWeeklyStatus[slot][id] = ST_CLAIMABLE
	}
	else if (group == GRP_VIP)
	{
		iOld = g_iVipStatus[id]
		if (iOld != ST_ACTIVE)
			return
		g_iVipStatus[id] = ST_CLAIMABLE
	}
	SaveRoll(id)
	// Single print per completed slot. For VIP auto-claim the outcome is
	// printed by DoClaim; only fall back to the "ready to claim" notice when
	// the auto-claim did not run or did not pay (wallet not ready). This
	// removes the old double path where l.767 printed "ready to claim" AND
	// DoClaim printed "slot claimed" for the same slot in one event.
	if (IsVipAuto(id) && DoClaim(id, group, slot))
		return
	client_printcolor(id, "!g[FreeNova] !n Mission ready to claim. Open /missions.")
}

// Pays the xp/coins a CONFIG ROW attaches to one slot. Both natives are
// once-only per award id, and the award id is per period, so a claim that is
// retried (wallet came up late, player reconnected) can never pay twice while
// still paying exactly once. Out params report what was credited THIS attempt:
// 0 means "already credited earlier", which is why they are not used to decide
// success. Returns false only when the wallet cannot pay yet - the caller then
// leaves the slot claimable instead of marking it done.
bool:PaySlotReward(id, group, slot, &iXpPaid, &iCoinPaid)
{
	iXpPaid = 0
	iCoinPaid = 0
	if (group < 0 || group >= GRP_COUNT || slot < 0 || slot >= MAX_SLOTS)
		return true
	new iXp = g_iSlotXp[group][slot]
	new iCoins = g_iSlotCoins[group][slot]
	if (iXp <= 0 && iCoins <= 0)
		return true
	if (!LibraryExists("menabp", LibType_Library) || !menabp_is_ready(id))
		return false

	new szTag[16], szAward[64]
	PeriodTag(group, szTag, charsmax(szTag))
	if (iXp > 0)
	{
		formatex(szAward, charsmax(szAward), "msn_%s_%d_xp#%s", g_szGroupName[group], slot, szTag)
		new iGot = menabp_add_xp_once(id, iXp, szAward)
		if (iGot < 0)
			return false
		iXpPaid = iGot
	}
	if (iCoins > 0)
	{
		formatex(szAward, charsmax(szAward), "msn_%s_%d_coins#%s", g_szGroupName[group], slot, szTag)
		new iGot = menabp_add_coins_once(id, iCoins, szAward)
		if (iGot < 0)
			return false
		iCoinPaid = (iGot > 0) ? iCoins : 0
	}
	return true
}

// Pays the set-completion bonus of a group. Same once-only-by-period contract
// as PaySlotReward; the award ids are the ones 1.1.0 already used, so nobody
// who completed a period before this build can be paid a second time.
bool:PaySetReward(id, group, &iXpPaid, &iCoinPaid)
{
	iXpPaid = 0
	iCoinPaid = 0
	if (group < 0 || group >= GRP_COUNT)
		return true
	new szTag[16], szAward[64]
	PeriodTag(group, szTag, charsmax(szTag))
	if (g_iSetXp[group] > 0)
	{
		if (group == GRP_DAILY)
			formatex(szAward, charsmax(szAward), "daily_complete#%s", szTag)
		else
			formatex(szAward, charsmax(szAward), "%s_xp#%s", g_szGroupName[group], szTag)
		new iGot = menabp_add_xp_once(id, g_iSetXp[group], szAward)
		if (iGot < 0)
			return false
		iXpPaid = iGot
	}
	if (g_iSetCoins[group] > 0)
	{
		if (group == GRP_DAILY)
			formatex(szAward, charsmax(szAward), "daily_complete_coins#%s", szTag)
		else
			formatex(szAward, charsmax(szAward), "%s_coins#%s", g_szGroupName[group], szTag)
		new iGot = menabp_add_coins_once(id, g_iSetCoins[group], szAward)
		if (iGot < 0)
			return false
		iCoinPaid = (iGot > 0) ? g_iSetCoins[group] : 0
	}
	return true
}

bool:DoClaim(id, group, slot)
{
	if (g_bPaused || !g_bLoaded[id] || g_bClaiming[id])
		return false
	// Coins and BP XP are both owned by battlepass_core. Fail closed until
	// the player's BP ledger is ready instead of marking a slot claimed.
	if (!LibraryExists("menabp", LibType_Library) || !menabp_is_ready(id))
	{
		client_printcolor(id, "!g[FreeNova] !n BattlePass is still loading - try again shortly.")
		return false
	}
	g_bClaiming[id] = true
	new bool:bOk = false
	if (group == GRP_DAILY && slot >= 0 && slot < MAX_DAILY_SLOTS && g_iDailyStatus[slot][id] == ST_CLAIMABLE)
	{
		// Reward order matters: every payment happens BEFORE the status is
		// written, and each payment is idempotent by period, so a refused or
		// interrupted claim retries instead of losing anything.
		new iNeed = SetNeedCount(GRP_DAILY)
		new bool:bCompletes = (iNeed > 0 && DailyDoneCount(id) + 1 >= iNeed && !g_bMissionComplete[id])
		new iXpPaid, iCoinsPaid
		if (!PaySlotReward(id, GRP_DAILY, slot, iXpPaid, iCoinsPaid))
		{
			g_bClaiming[id] = false
			client_printcolor(id, "!g[FreeNova] !n The reward could not be paid yet - try again shortly.")
			return false
		}
		new iSetXp = 0, iSetCoins = 0
		if (bCompletes && !PaySetReward(id, GRP_DAILY, iSetXp, iSetCoins))
		{
			g_bClaiming[id] = false
			client_printcolor(id, "!g[FreeNova] !n BattlePass XP could not be paid yet - try again shortly.")
			return false
		}
		g_iDailyStatus[slot][id] = ST_CLAIMED
		SaveRoll(id)
		if (bCompletes)
		{
			g_bMissionComplete[id] = true
			SaveDailyMissions(id)
			if (iSetXp > 0 && iSetCoins > 0)
				client_printcolor(id, "!g[FreeNova] !n Daily Missions Complete! +!g%d BP XP !n, +!g%d Coins !n", iSetXp, iSetCoins)
			else if (iSetXp > 0)
				client_printcolor(id, "!g[FreeNova] !n Daily Missions Complete! +!g%d BP XP !n", iSetXp)
			else if (iSetCoins > 0)
				client_printcolor(id, "!g[FreeNova] !n Daily Missions Complete! +!g%d Coins !n", iSetCoins)
			else
				client_printcolor(id, "!g[FreeNova] !n Daily Missions Complete!")
		}
		else if (iXpPaid > 0 || iCoinsPaid > 0)
			client_printcolor(id, "!g[FreeNova] !n Daily slot claimed! +!g%d BP XP !n, +!g%d Coins !n", iXpPaid, iCoinsPaid)
		else
			client_printcolor(id, "!g[FreeNova] !n Daily slot claimed.")
		g_bClaiming[id] = false
		return true
	}
	if (group == GRP_BONUS && slot >= 0 && slot < MAX_BONUS_SLOTS && g_iBonusStatus[slot][id] == ST_CLAIMABLE)
	{
		new iXpPaid, iCoinsPaid
		if (!PaySlotReward(id, GRP_BONUS, slot, iXpPaid, iCoinsPaid))
		{
			g_bClaiming[id] = false
			return false
		}
		g_iBonusStatus[slot][id] = ST_CLAIMED
		g_bDaily2Paid[slot][id] = true
		SaveDaily2(id)
		SaveRoll(id)
		g_bClaiming[id] = false
		if (iCoinsPaid > 0)
			client_printcolor(id, "!g[FreeNova] !n Bonus mission claimed! +!g%d Coins !n", iCoinsPaid)
		else
			client_printcolor(id, "!g[FreeNova] !n Bonus mission claimed.")
		return true
	}
	if (group == GRP_WEEKLY && slot >= 0 && slot < MAX_WEEKLY_SLOTS && g_iWeeklyStatus[slot][id] == ST_CLAIMABLE)
	{
		// The last claim completes the weekly set. Both set rewards are keyed
		// per ISO week, so a partial payout can be retried without duplication.
		new iNeed = SetNeedCount(GRP_WEEKLY)
		new bool:bCompletes = (iNeed > 0 && WeeklyDoneCount(id) + 1 >= iNeed && !g_bWeeklyComplete[id])
		new iXpPaid, iCoinsPaid
		if (!PaySlotReward(id, GRP_WEEKLY, slot, iXpPaid, iCoinsPaid))
		{
			g_bClaiming[id] = false
			client_printcolor(id, "!g[FreeNova] !n The reward could not be paid yet - try again shortly.")
			return false
		}
		new iSetXp = 0, iSetCoins = 0
		if (bCompletes && !PaySetReward(id, GRP_WEEKLY, iSetXp, iSetCoins))
		{
			g_bClaiming[id] = false
			client_printcolor(id, "!g[FreeNova] !n Weekly rewards could not be paid yet - try again shortly.")
			return false
		}
		g_iWeeklyStatus[slot][id] = ST_CLAIMED
		SaveRoll(id)
		if (bCompletes)
		{
			g_bWeeklyComplete[id] = true
			SaveWeeklyMissions(id)
			if (iSetXp > 0 && iSetCoins > 0)
				client_printcolor(id, "!g[FreeNova] !n Weekly Missions Complete! +!g%d BP XP !n, +!g%d Coins !n", iSetXp, iSetCoins)
			else if (iSetXp > 0)
				client_printcolor(id, "!g[FreeNova] !n Weekly Missions Complete! +!g%d BP XP !n", iSetXp)
			else if (iSetCoins > 0)
				client_printcolor(id, "!g[FreeNova] !n Weekly Missions Complete! +!g%d Coins !n", iSetCoins)
			else
				client_printcolor(id, "!g[FreeNova] !n Weekly Missions Complete!")
		}
		else if (iXpPaid > 0 || iCoinsPaid > 0)
			client_printcolor(id, "!g[FreeNova] !n Weekly slot claimed! +!g%d BP XP !n, +!g%d Coins !n", iXpPaid, iCoinsPaid)
		else
			client_printcolor(id, "!g[FreeNova] !n Weekly slot claimed.")
		g_bClaiming[id] = false
		return true
	}
	if (group == GRP_VIP && g_iVipStatus[id] == ST_CLAIMABLE && VipTier(id) >= FNVIP_VIP)
	{
		// The VIP gate is code, not config: no contract row can pay a non-VIP.
		new iXpPaid, iCoinsPaid
		if (!PaySlotReward(id, GRP_VIP, 0, iXpPaid, iCoinsPaid))
		{
			g_bClaiming[id] = false
			return false
		}
		g_iVipStatus[id] = ST_CLAIMED
		SaveRoll(id)
		g_bClaiming[id] = false
		if (iCoinsPaid > 0)
			client_printcolor(id, "!g[FreeNova] !n VIP extra claimed! +!g%d Coins !n", iCoinsPaid)
		else
			client_printcolor(id, "!g[FreeNova] !n VIP extra claimed!")
		return true
	}
	g_bClaiming[id] = false
	return bOk
}

ClaimAllReady(id)
{
	new i, n
	for (i = 0; i < MAX_DAILY_SLOTS; i++)
		if (g_iDailyStatus[i][id] == ST_CLAIMABLE && DoClaim(id, GRP_DAILY, i)) n++
	for (i = 0; i < MAX_BONUS_SLOTS; i++)
		if (g_iBonusStatus[i][id] == ST_CLAIMABLE && DoClaim(id, GRP_BONUS, i)) n++
	for (i = 0; i < MAX_WEEKLY_SLOTS; i++)
		if (g_iWeeklyStatus[i][id] == ST_CLAIMABLE && DoClaim(id, GRP_WEEKLY, i)) n++
	if (g_iVipStatus[id] == ST_CLAIMABLE && VipTier(id) >= FNVIP_VIP && DoClaim(id, GRP_VIP, 0))
		n++
	return n
}

TryAutoClaimAll(id)
{
	if (!IsVipAuto(id))
		return
	ClaimAllReady(id)
}

DoReroll(id, slot)
{
	if (g_bPaused || !g_bLoaded[id] || slot < 0 || slot >= MAX_DAILY_SLOTS)
		return 0
	if (!g_bSlotUsed[GRP_DAILY][slot])
		return -1
	if (g_iDailyStatus[slot][id] != ST_ACTIVE)
		return -1
	new iLeft = RerollsLeft(id)
	if (iLeft <= 0)
	{
		new iCost = RerollCost(id)
		if (!AddCoins(id, -iCost))
			return -2
	}
	else
		g_iRerollsUsed[id]++
	new iOld = g_iDailyTarget[slot][id]
	new iNew = iOld
	// Prefer a different target, but a one-candidate slot can never change.
	if (g_iCandCount[GRP_DAILY][slot] > 1)
	{
		for (new n; n < 8; n++)
		{
			iNew = RollSlotTarget(GRP_DAILY, slot)
			if (iNew != iOld)
				break
		}
	}
	else
		iNew = RollSlotTarget(GRP_DAILY, slot)
	g_iDailyTarget[slot][id] = iNew
	g_iDailyProg[slot][id] = 0
	SaveDailyMissions(id)
	SaveRoll(id)
	client_printcolor(id, "!g[FreeNova] !n Daily slot rerolled. New target: !t%d!n.", iNew)
	return 1
}

CheckDailyMissions(id)
{
	if (g_bPaused || !g_bLoaded[id])
		return
	for (new i; i < MAX_DAILY_SLOTS; i++)
	{
		if (!g_bSlotUsed[GRP_DAILY][i])
			continue
		if (g_iDailyStatus[i][id] == ST_ACTIVE && g_iDailyProg[i][id] >= g_iDailyTarget[i][id])
			MarkClaimable(id, GRP_DAILY, i)
	}
}

CheckWeeklyMissions(id)
{
	if (g_bPaused || !g_bLoaded[id])
		return
	for (new i; i < MAX_WEEKLY_SLOTS; i++)
	{
		if (!g_bSlotUsed[GRP_WEEKLY][i])
			continue
		if (g_iWeeklyStatus[i][id] == ST_ACTIVE && g_iWeeklyProg[i][id] >= g_iWeeklyTarget[i][id])
			MarkClaimable(id, GRP_WEEKLY, i)
	}
}

CheckDaily2(id)
{
	if (g_bPaused || !g_bLoaded[id])
		return
	for (new i; i < MAX_BONUS_SLOTS; i++)
	{
		if (!g_bSlotUsed[GRP_BONUS][i])
			continue
		if (g_iBonusStatus[i][id] == ST_ACTIVE && g_iBonusProg[i][id] >= g_iBonusTarget[i][id])
			MarkClaimable(id, GRP_BONUS, i)
	}
	if (g_bSlotUsed[GRP_VIP][0] && VipTier(id) >= FNVIP_VIP
		&& g_iVipStatus[id] == ST_ACTIVE && g_iVipProgress[id] >= g_iVipTarget[id])
		MarkClaimable(id, GRP_VIP, 0)
}

// True while any open slot of the group counts `metric`. Used as a cheap gate
// on the hottest event (damage) so a finished bonus slot costs nothing.
bool:AnyOpenMetric(id, group, metric)
{
	if (group < 0 || group >= GRP_COUNT)
		return false
	new iSlots = GroupSlots(group)
	for (new i; i < iSlots; i++)
	{
		if (!g_bSlotUsed[group][i] || g_iSlotMetric[group][i] != metric)
			continue
		new iStatus
		if (group == GRP_DAILY)
			iStatus = g_iDailyStatus[i][id]
		else if (group == GRP_BONUS)
			iStatus = g_iBonusStatus[i][id]
		else if (group == GRP_WEEKLY)
			iStatus = g_iWeeklyStatus[i][id]
		else
			iStatus = (!g_bSlotUsed[GRP_VIP][0]) ? ST_CLAIMED : g_iVipStatus[id]
		if (iStatus == ST_ACTIVE)
			return true
	}
	return false
}

// The one place progress comes from. Every open slot whose configured metric
// matches is advanced, so moving a metric between slots is a config change and
// not a code change. Streak slots keep the best run instead of summing.
AdvanceMetric(id, metric, amount)
{
	if (g_bPaused || !g_bLoaded[id] || amount <= 0 || !g_bCfgLoaded)
		return
	new bool:bVipAdvanced = false
	// The run advances once per event, and only while a streak slot is actually
	// open - exactly what the single-slot 1.1.0 counter did. Every streak slot
	// then only remembers the best run it has seen.
	new bool:bStreakCounted

	for (new i; i < MAX_DAILY_SLOTS; i++)
	{
		if (!g_bSlotUsed[GRP_DAILY][i] || g_iSlotMetric[GRP_DAILY][i] != metric)
			continue
		if (g_iDailyStatus[i][id] != ST_ACTIVE)
			continue
		if (metric == MTR_STREAK)
		{
			if (!bStreakCounted)
			{
				g_iStreakRun[id] += amount
				bStreakCounted = true
			}
			if (g_iStreakRun[id] > g_iDailyProg[i][id])
				g_iDailyProg[i][id] = g_iStreakRun[id]
		}
		else
			g_iDailyProg[i][id] += amount
	}
	for (new i; i < MAX_BONUS_SLOTS; i++)
	{
		if (!g_bSlotUsed[GRP_BONUS][i] || g_iSlotMetric[GRP_BONUS][i] != metric)
			continue
		if (g_iBonusStatus[i][id] != ST_ACTIVE)
			continue
		if (metric == MTR_STREAK)
		{
			if (!bStreakCounted)
			{
				g_iStreakRun[id] += amount
				bStreakCounted = true
			}
			if (g_iStreakRun[id] > g_iBonusProg[i][id])
				g_iBonusProg[i][id] = g_iStreakRun[id]
		}
		else
			g_iBonusProg[i][id] += amount
	}
	for (new i; i < MAX_WEEKLY_SLOTS; i++)
	{
		if (!g_bSlotUsed[GRP_WEEKLY][i] || g_iSlotMetric[GRP_WEEKLY][i] != metric)
			continue
		if (g_iWeeklyStatus[i][id] != ST_ACTIVE)
			continue
		if (metric == MTR_STREAK)
		{
			if (!bStreakCounted)
			{
				g_iStreakRun[id] += amount
				bStreakCounted = true
			}
			if (g_iStreakRun[id] > g_iWeeklyProg[i][id])
				g_iWeeklyProg[i][id] = g_iStreakRun[id]
		}
		else
			g_iWeeklyProg[i][id] += amount
	}
	if (g_bSlotUsed[GRP_VIP][0] && g_iSlotMetric[GRP_VIP][0] == metric
		&& g_iVipStatus[id] == ST_ACTIVE && VipTier(id) >= FNVIP_VIP)
	{
		g_iVipProgress[id] += amount
		bVipAdvanced = true
	}
	if (bVipAdvanced)
		SaveRoll(id)
}

// Runs every clock after progress changed. Kept out of AdvanceMetric so a kill
// that advances kills, headshots and streak pays for one pass, not three.
CheckAllMissions(id)
{
	CheckDailyMissions(id)
	CheckWeeklyMissions(id)
	CheckDaily2(id)
}

// True while any open slot anywhere counts `metric`. Cheap gate for the two
// events that fire per hit and per round: with nothing open, nothing is done.
bool:AnyOpenMetricAnywhere(id, metric)
{
	for (new g; g < GRP_COUNT; g++)
		if (AnyOpenMetric(id, g, metric))
			return true
	return false
}
public fn_on_player_kill(attacker, victim, wpnindex, headshot, tk)
{
	#pragma unused victim, wpnindex
	if (g_bPaused || tk)
		return
	if (!is_user_connected(attacker) || is_user_bot(attacker) || !g_bLoaded[attacker])
		return
	if (get_cvar_num("amx_knife_round_active") == 1)
		return
	EnsureMissionPeriod(attacker)
	AdvanceMetric(attacker, MTR_KILLS, 1)
	// A streak is a run of kills: it advances on the same event, not on a slot.
	AdvanceMetric(attacker, MTR_STREAK, 1)
	if (headshot)
		AdvanceMetric(attacker, MTR_HEADSHOTS, 1)
	CheckAllMissions(attacker)
}

// RANK_BOTS master switch reader: true only when rsu_core runs RANK_BOTS=1.
// Bots never load mission state, so this only opens VICTIM-side counters
// (streak reset, damage bonus) for humans. Bot PLAYERS earn nothing.
stock bool:BotCountOn()
{
	return LibraryExists("rsu_core", LibType_Library) && rsu_bots_count();
}

public client_death(attacker, victim, wpnindex, hitplace, TK)
{
	#pragma unused attacker, wpnindex, hitplace, TK
	if (is_user_connected(victim) && (!is_user_bot(victim) || BotCountOn()))
		g_iStreakRun[victim] = 0
}

public fn_on_bomb_event(id, type)
{
	if (g_bPaused || !g_bLoaded[id])
		return
	if (get_cvar_num("amx_knife_round_active") == 1)
		return
	EnsureMissionPeriod(id)
	if (type == 0)
		AdvanceMetric(id, MTR_PLANTS, 1)
	else if (type == 1)
		AdvanceMetric(id, MTR_DEFUSES, 1)
	else
		return
	CheckAllMissions(id)
}

public fn_on_round_win(id, team)
{
	#pragma unused team
	if (g_bPaused || !g_bLoaded[id])
		return
	if (get_cvar_num("amx_knife_round_active") == 1)
		return
	EnsureMissionPeriod(id)
	AdvanceMetric(id, MTR_WINS, 1)
	CheckAllMissions(id)
}

public Ham_TakeDamage_Pre(victim, inflictor, attacker, Float:damage, damagebits)
{
	#pragma unused inflictor, damagebits
	if (g_bPaused)
		return HAM_IGNORED
	if (attacker < 1 || attacker > MAX_PLAYERS || attacker == victim)
		return HAM_IGNORED
	if (!is_user_connected(attacker) || (is_user_bot(attacker) && !BotCountOn()) || (is_user_bot(victim) && !BotCountOn()))
		return HAM_IGNORED
	if (cs_get_user_team(attacker) == cs_get_user_team(victim))
		return HAM_IGNORED
	if (get_cvar_num("amx_knife_round_active") == 1)
		return HAM_IGNORED
	if (!g_bLoaded[attacker])
		return HAM_IGNORED
	// Hot path: no damage slot open anywhere means no bookkeeping at all.
	if (!AnyOpenMetricAnywhere(attacker, MTR_DAMAGE))
		return HAM_IGNORED
	EnsureMissionPeriod(attacker)
	AdvanceMetric(attacker, MTR_DAMAGE, floatround(damage))
	CheckAllMissions(attacker)
	return HAM_IGNORED
}

public Event_RoundEnd()
{
	new survivors[32], sNum
	get_players(survivors, sNum, "ah")
	for (new s; s < sNum; s++)
	{
		new sid = survivors[s]
		if (is_user_bot(sid) || !g_bLoaded[sid] || get_cvar_num("amx_knife_round_active") == 1)
			continue
		if (!AnyOpenMetricAnywhere(sid, MTR_SURVIVES))
			continue
		EnsureMissionPeriod(sid)
		AdvanceMetric(sid, MTR_SURVIVES, 1)
		CheckAllMissions(sid)
	}
}

public Cmd_Missions(id)
{
	if (!is_user_connected(id))
		return PLUGIN_HANDLED
	if (FNWeb_OpenPage(id, "missions"))
		return PLUGIN_HANDLED
	client_printcolor(id, "!g[FreeNova] !nMissions are unavailable right now - try again in a moment.")
	return PLUGIN_HANDLED
}





















bool:ValidId(id)
{
	return (1 <= id <= MAX_PLAYERS)
}

DailyDoneCount(id)
{
	new n
	for (new i; i < MAX_DAILY_SLOTS; i++)
		if (g_bSlotUsed[GRP_DAILY][i] && g_iDailyStatus[i][id] == ST_CLAIMED) n++
	return n
}

WeeklyDoneCount(id)
{
	new n
	for (new i; i < MAX_WEEKLY_SLOTS; i++)
		if (g_bSlotUsed[GRP_WEEKLY][i] && g_iWeeklyStatus[i][id] == ST_CLAIMED) n++
	return n
}

public native_is_complete(plugin, params)
{
	new id = get_param(1)
	return (ValidId(id) && g_bMissionComplete[id]) ? 1 : 0
}

public native_get_daily(plugin, params)
{
	new id = get_param(1)
	new mission = get_param(2)
	if (!ValidId(id) || mission < 0 || mission >= MAX_DAILY_SLOTS)
		return 0
	return g_iDailyProg[mission][id]
}

public native_get_daily2(plugin, params)
{
	new id = get_param(1)
	new mission = get_param(2)
	if (!ValidId(id) || mission < 0 || mission >= MAX_BONUS_SLOTS)
		return 0
	return g_iBonusProg[mission][id]
}

public native_get_weekly(plugin, params)
{
	new id = get_param(1)
	new mission = get_param(2)
	if (!ValidId(id) || mission < 0 || mission >= MAX_WEEKLY_SLOTS)
		return 0
	return g_iWeeklyProg[mission][id]
}

public native_daily_done(plugin, params)
{
	new id = get_param(1)
	return ValidId(id) ? DailyDoneCount(id) : 0
}

public native_bonus_done(plugin, params)
{
	new id = get_param(1)
	if (!ValidId(id))
		return 0
	new n
	for (new i; i < 3; i++)
		if (g_iBonusStatus[i][id] == ST_CLAIMED) n++
	return n
}

public native_weekly_done(plugin, params)
{
	new id = get_param(1)
	return ValidId(id) ? WeeklyDoneCount(id) : 0
}

public native_show(plugin, params)
{
	new id = get_param(1)
	if (!ValidId(id) || !is_user_connected(id))
		return 0
	if (FNWeb_OpenPage(id, "missions"))
		return 1
	return 0
}

public native_claim(plugin, params)
{
	new id = get_param(1)
	new group = get_param(2)
	new slot = get_param(3)
	if (!ValidId(id) || !g_bLoaded[id])
		return 0
	return DoClaim(id, group, slot) ? 1 : 0
}

public native_reroll(plugin, params)
{
	new id = get_param(1)
	new slot = get_param(2)
	if (!ValidId(id) || !g_bLoaded[id])
		return 0
	return (DoReroll(id, slot) == 1) ? 1 : 0
}

public native_rerolls_left(plugin, params)
{
	new id = get_param(1)
	return ValidId(id) ? RerollsLeft(id) : 0
}

public native_get_status(plugin, params)
{
	new id = get_param(1)
	new group = get_param(2)
	new slot = get_param(3)
	if (!ValidId(id))
		return 0
	if (group == GRP_DAILY && slot >= 0 && slot < MAX_DAILY_SLOTS)
		return g_iDailyStatus[slot][id]
	if (group == GRP_BONUS && slot >= 0 && slot < MAX_BONUS_SLOTS)
		return g_iBonusStatus[slot][id]
	if (group == GRP_WEEKLY && slot >= 0 && slot < MAX_WEEKLY_SLOTS)
		return g_iWeeklyStatus[slot][id]
	if (group == GRP_VIP)
		return g_iVipStatus[id]
	return 0
}

public native_get_target(plugin, params)
{
	new id = get_param(1)
	new group = get_param(2)
	new slot = get_param(3)
	if (!ValidId(id))
		return 0
	if (group == GRP_DAILY && slot >= 0 && slot < MAX_DAILY_SLOTS)
		return g_iDailyTarget[slot][id]
	if (group == GRP_BONUS && slot >= 0 && slot < MAX_BONUS_SLOTS)
		return g_iBonusTarget[slot][id]
	if (group == GRP_WEEKLY && slot >= 0 && slot < MAX_WEEKLY_SLOTS)
		return g_iWeeklyTarget[slot][id]
	if (group == GRP_VIP)
		return g_iVipTarget[id]
	return 0
}

public native_set_track(plugin, params)
{
	new id = get_param(1)
	new group = get_param(2)
	new slot = get_param(3)
	if (!ValidId(id))
		return 0
	g_iTrackGroup[id] = group
	g_iTrackSlot[id] = slot
	return 1
}

public native_get_track(plugin, params)
{
	new id = get_param(1)
	if (!ValidId(id))
		return 0
	new szOut[32]
	formatex(szOut, charsmax(szOut), "%d:%d", g_iTrackGroup[id], g_iTrackSlot[id])
	set_string(2, szOut, get_param(3))
	return 1
}

public native_vip_progress(plugin, params)
{
	new id = get_param(1)
	return ValidId(id) ? g_iVipProgress[id] : 0
}

public native_claim_all(plugin, params)
{
	new id = get_param(1)
	if (!ValidId(id) || !g_bLoaded[id])
		return 0
	return ClaimAllReady(id)
}

stock client_printcolor(id, const fmt[], any:...)
{
	new msg[192]
	vformat(msg, charsmax(msg), fmt, 3)
	replace_all(msg, charsmax(msg), "!g", "^4")
	replace_all(msg, charsmax(msg), "!t", "^3")
	replace_all(msg, charsmax(msg), "!n", "^1")
	replace_all(msg, charsmax(msg), "!Team", "^3")
	// REVIEW.md 5.5: the caller's text was passed as the FORMAT. A player
	// named "%s" then made client_print_color re-format garbage cells, so
	// pass it as an argument instead.
	client_print_color(id, print_team_default, "%s", msg)
}
