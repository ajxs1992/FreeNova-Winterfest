/*
 * ============================================================================
 * winterfest_progress - the seasonal layer: Christmas missions, seasonal
 * achievements and the daily login gift
 * ============================================================================
 * Product contract: docs/WINTERFEST.md §3/§4/§5/§6, workstream 9 of
 * docs/WINTERFEST-WORKSTREAMS.md. Operator/developer notes:
 * docs/WINTERFEST-PROGRESS.md (this module's own document).
 *
 * WHY THIS EXISTS AS A SEPARATE PLUGIN
 *   The live tree already has freenova_missions (48 contracts from
 *   configs/freenova/missions.ini) and freenova_achievements. Both are general,
 *   year-round systems with their own slots, ledgers and owners. Winterfest needs
 *   content that appears only in December and disappears in January. So this is
 *   an ADDITIVE seasonal layer with its own config files
 *   (configs/freenova/winterfest/missions.ini, achievements.ini, progress.ini):
 *   the base plugins never read them, no base slot is touched, and deleting these
 *   three files stops the seasonal content without touching the base rotation.
 *
 * WHAT IT OWNS
 *   - seasonal contracts and their progress (12-16 contracts, daily/weekly/season
 *     periods), tracked event-driven;
 *   - seasonal achievements and their PERMANENT badges;
 *   - the daily login gift (first connect of the day, one small bundle);
 *   - /christmasmissions and /christmasrank;
 *   - its own nvault (freenova_wfprog), its own keys, its own save path.
 *
 * WHAT IT MUST NEVER DO
 *   - pay a reward itself. Every payment is wf_grant() in winterfest_core, with a
 *     claim key that names the season, the contract and the steamid, so two
 *     completions in the same second pay once (docs/WINTERFEST.md §5.2);
 *   - depend on the core to keep running: with winterfest_core missing the
 *     missions still track and persist progress, they simply never pay, and
 *     nothing at all is announced (see WfProgCore());
 *   - do anything outside its own window: no config load, no vault, no hooks, no
 *     tasks, no commands, no player-facing line (see plugin_init());
 *   - do any per-frame work. Kills/headshots/streaks/rounds/wins are engine
 *     events, hooks and forwards; the only timed work is one 2 s observation of
 *     the core's present inventory plus one 10 s core read (the core is
 *     pull-only: it publishes no forward for "a present was picked up"), and one
 *     30 s autosave - three bounded tasks, none of them per frame, all gated on
 *     a human being connected;
 *   - touch a bot. Bots never load, never progress, never see a menu.
 *
 * THE PERIOD MODEL (why a reconnect cannot reset anything)
 *   Every contract has a period string derived from the clock:
 *       daily   "d20261201"     weekly "w2026-48"      season "s2026"
 *   Progress is stored with the period it belongs to, so a period change resets
 *   exactly once, on the first read after midnight / the ISO week / the season,
 *   and a reconnect inside the period reads the same numbers back. The rolled
 *   variant is derived from (steamid, season, slot, period), so it is stable
 *   across reconnects too.
 * ============================================================================
 */

#include <amxmodx>
#include <amxmisc>
#include <nvault>
#include <winterfest>     // constants, natives, WfField/WfSay stocks
#include <freenova_ui>    // menu chrome only (FN_MenuFinish) - no runtime dependency

#define PLUGIN  "Winterfest Progress"
#define VERSION "1.0.0"
#define AUTHOR  "FreeNova"

// ---------------------------------------------------------------------------
// Files and limits
// ---------------------------------------------------------------------------
#define CFG_PROGRESS "freenova/winterfest/progress.ini"
#define CFG_MISSIONS "freenova/winterfest/missions.ini"
#define CFG_ACHIEVE  "freenova/winterfest/achievements.ini"

// Own vault: the core's freenova_wf holds the currency/inventory/tree; this one
// holds only seasonal progress, so an operator can inspect or drop one without
// touching the other.
#define VAULT_NAME "freenova_wfprog"

// Same ceiling the core enforces on its keys. A longer key is refused (loudly),
// never truncated: two truncated keys would silently alias two players.
#define MAX_KEY 64

#define MAX_CTR      24   // active contracts (ships 14)
#define MAX_ACH      16   // achievements (ships 12)
#define MAX_CAND     6    // target variants per contract slot
#define MAX_PAGE     7    // contract rows per menu page (plus Next + badges + exit)
#define ADVENT_DAYS  24   // the calendar in docs/WINTERFEST.md §6.3

// Task ids. AMXX task ids are per plugin, so these only have to be unique inside
// this file; the +N client tasks live below the tick base so remove_task sweeps
// cannot collide.
enum
{
	TASK_LOGIN    = 96600,
	TASK_READY    = 96800,
	TASK_GATE     = 97200,
	TASK_TICK     = 97210,
	TASK_DEEP     = 97220,
	TASK_AUTOSAVE = 97230
}

// Contract groups. These are periods, not the base plugin's daily/bonus/weekly/
// vip: a seasonal contract is either a day, a week, or the whole window.
#define GRP_DAILY  0
#define GRP_WEEKLY 1
#define GRP_SEASON 2
#define GRP_COUNT  3

// Metrics. The names are the ini vocabulary; the classes below decide how a
// value moves.
#define MTR_NONE        0
#define MTR_KILLS       1
#define MTR_HEADSHOTS   2
#define MTR_STREAK      3
#define MTR_ROUNDS      4
#define MTR_MAP_ROUNDS  5
#define MTR_WINS        6
#define MTR_PRESENTS    7
#define MTR_OPENS       8
#define MTR_LEGENDARY   9
#define MTR_ADVENT      10
#define MTR_SETS        11
#define MTR_TREE        12
#define MTR_PASS_TIER   13
#define MTR_SNOWBALL_HS 14
#define MTR_COUNT       15

// How a metric moves:
//   EVENT   an engine event adds to it (kills, rounds, ...)
//   MAX     an event raises it and it keeps the best value (streak)
//   COUNTER a monotonic number read from the core; progress is the delta since
//           the period began (presents picked up today, advent days claimed
//           this week, ...)
//   LEVEL   a core level; progress is the level itself, so a LEVEL metric may
//           only appear in a season contract (a level does not reset daily)
#define MC_EVENT   0
#define MC_MAX     1
#define MC_COUNTER 2
#define MC_LEVEL   3

// Per-player season record cells: the numbers that are not per contract.
#define META_GIFTSEQ   0   // highest present instance id ever seen = presents collected
#define META_CARRIED   1   // present count at the last observation (for the open delta)
#define META_OPENS     2   // presents opened (delta-derived, monotonic)
#define META_LEGENDARY 3   // legendary presents seen in the bag and then gone = opened
#define META_STREAK    4   // best kill streak this season
#define META_ROUNDS    5   // rounds started this season
#define META_WINS      6   // rounds won this season
#define META_KILLS     7   // kills this season
#define META_HEADSHOTS 8   // headshot kills this season
#define META_SNOWBALL  9   // snowball headshots this season
#define META_LOGINDATE 10  // YYYYMMDD of the last paid daily login
#define META_COUNT     11

// ============================================================
// State
// ============================================================
new g_Vault = INVALID_HANDLE

// progress.ini
new bool:g_bCfgOk
new bool:g_bEnabled
new g_szSeasonName[48]
new g_iSeasonYear
new g_iStartDate, g_iStartMin   // YYYYMMDD, minutes into the day
new g_iEndDate, g_iEndMin
new bool:g_bLoginOn
new g_iLoginSnow
new g_iLegendaryRarity

// The window as it is right now. g_bOpen is the single fast gate every callback
// asks; it is recomputed once a minute so a season that closes at midnight
// stops mid-map without waiting for a map change.
new bool:g_bOpen
new bool:g_bHooksReady            // we registered the commands/hooks at boot
new g_szMap[32]

// missions.ini
new g_iCtrCount
new g_szCtrId[MAX_CTR][24]
new g_szCtrKey[MAX_CTR][8]        // "d0", "w1", "s5" - the stable contract identity
new g_iCtrGroup[MAX_CTR]
new g_iCtrSlot[MAX_CTR]
new g_iCtrMetric[MAX_CTR]
// Rolled per player with the target, because a target variant may pay
// differently: "collect 5 presents" is worth more than "collect 3".
new g_iCtrSnow[MAX_CTR][MAX_PLAYERS + 1]
new g_iCtrXp[MAX_CTR][MAX_PLAYERS + 1]
new g_szCtrMap[MAX_CTR][32]       // map= tag, only used by map_rounds
new g_iCandRow[MAX_CTR][MAX_CAND]
new g_iCandWeight[MAX_CTR][MAX_CAND]
new g_iCandTarget[MAX_CTR][MAX_CAND]
new g_iCandSnow[MAX_CTR][MAX_CAND]
new g_iCandXp[MAX_CTR][MAX_CAND]
new g_iCandCount[MAX_CTR]
new g_iSeasonTag                  // [settings] season of missions.ini/achievements.ini

// achievements.ini
new g_iAchCount
new g_szAchId[MAX_ACH][24]
new g_szAchName[MAX_ACH][32]
new g_szAchBadge[MAX_ACH][24]
new g_iAchMetric[MAX_ACH]
new g_iAchTarget[MAX_ACH]
new g_iAchSnow[MAX_ACH]
new g_iAchXp[MAX_ACH]

// Per player
new bool:g_bLoaded[MAX_PLAYERS + 1]
new bool:g_bDirty[MAX_PLAYERS + 1]
new bool:g_bNoCoreWarned[MAX_PLAYERS + 1]
new g_iReadyTries[MAX_PLAYERS + 1]
new g_iLoginTries[MAX_PLAYERS + 1]

new g_iCtrProg[MAX_CTR][MAX_PLAYERS + 1]
new g_szCtrPeriod[MAX_CTR][MAX_PLAYERS + 1][12]
new bool:g_bCtrPaid[MAX_CTR][MAX_PLAYERS + 1]
new g_iCtrLast[MAX_CTR][MAX_PLAYERS + 1]      // last observed core counter (-1 = baseline due)
new g_iCtrTarget[MAX_CTR][MAX_PLAYERS + 1]    // rolled target for this period

new g_iMeta[MAX_PLAYERS + 1][META_COUNT]
new g_szBadges[MAX_PLAYERS + 1][192]          // permanent achievement ids, "1,4,7"
new g_iStreakRun[MAX_PLAYERS + 1]
new g_szTopBag[MAX_PLAYERS + 1][96]           // legendary instances carried last tick

new g_iCtrPage[MAX_PLAYERS + 1]
new g_iAchPage[MAX_PLAYERS + 1]

new const g_szMetricName[MTR_COUNT][] =
{
	"none",
	"kills", "headshots", "streak", "rounds", "map_rounds", "wins",
	"presents", "opens", "legendary", "advent", "sets", "tree", "pass_tier",
	"snowball_hs"
}

// ============================================================
// Lifecycle
// ============================================================
public plugin_natives()
{
	// Registered so the gameplay modules can report the metrics only they can
	// see (workstream 7's snowball headshots today). No include is needed on
	// their side: if the library is there, call wfprog_report().
	register_library("winterfest_progress")
	set_native_filter("WfProgNativeFilter")
	register_native("wfprog_report", "native_report")
	register_native("wfprog_season_open", "native_season_open")
}

// A missing wf_* native must not turn this plugin into a bad load: with no core
// the natives resolve to 0 and the seasonal layer runs in track-only mode. This
// is the set_native_filter pattern from fn_servers.sma (docs/WINTERFEST.md §5.1
// asks every module for it).
public WfProgNativeFilter(const name[], index, trap)
{
	#pragma unused index
	if (trap)
		return PLUGIN_CONTINUE
	// Own natives are always resolvable; never filter them.
	if (contain(name, "wfprog_") == 0)
		return PLUGIN_CONTINUE
	if (contain(name, "wf_") == 0 && !WfProgCore())
		return PLUGIN_HANDLED
	return PLUGIN_CONTINUE
}

public plugin_init()
{
	register_plugin(PLUGIN, VERSION, AUTHOR)

	get_mapname(g_szMap, charsmax(g_szMap))

	// 1. Read our own window first. Everything else depends on it.
	WfProgLoadConfig()

	// 2. Outside the window: one log line and nothing else. No config files are
	//    read, no vault is opened, no hook, task or command is registered - the
	//    only callbacks that can still fire are AMXX's own client_* publics,
	//    which return on their first line because g_bOpen is false.
	if (!WfProgInWindow())
	{
		g_bOpen = false
		if (!g_bCfgOk)
		{
			log_amx("[WF-PROG] %s is missing or invalid - dormant for this map: no content, no vault, no hooks, no commands, no messages",
				CFG_PROGRESS)
			return
		}
		new ndate, nmin
		WfProgNow(ndate, nmin)
		// One line, and it says everything a person needs to tell "the season is
		// closed" from "the plugin is not installed": the window it read, the
		// clock it compared it against, and the list of things it did not do.
		log_amx("[WF-PROG] season %d window %d-%02d .. %d-%02d, now %d-%02d -> CLOSED; dormant: content not read, no vault, no hooks, no commands, no messages",
			g_iSeasonYear, g_iStartDate, g_iStartMin, g_iEndDate, g_iEndMin, ndate, nmin)
		return
	}
	g_bOpen = true

	// Test seam for the harness (docs/WINTERFEST-PROGRESS.md §7). Registered only
	// in-season; the shipped default keeps "a bot is not a player" exactly true.
	register_cvar("wfprog_test_bots", "0")

	// 3. Season content. A bad file is a log line, never a failed load.
	WfProgLoadMissions()
	WfProgLoadAchievements()

	// 4. One vault for this module only.
	g_Vault = nvault_open(VAULT_NAME)
	if (g_Vault == INVALID_HANDLE)
		log_amx("[WF-PROG] ERROR: nvault_open('%s') failed - seasonal progress will not persist", VAULT_NAME)

	// 5. Commands. Registered only in-season on purpose: outside the window
	//    typing /christmasmissions must produce no line at all.
	register_clcmd("say /christmasmissions", "cmdMissions")
	register_clcmd("say_team /christmasmissions", "cmdMissions")
	register_clcmd("say /xmasmissions", "cmdMissions")
	register_clcmd("say_team /xmasmissions", "cmdMissions")
	register_clcmd("say /christmasrank", "cmdRank")
	register_clcmd("say_team /christmasrank", "cmdRank")
	register_clcmd("say /xmasrank", "cmdRank")
	register_clcmd("say_team /xmasrank", "cmdRank")

	// 6. Operator commands (console). Same access as the core's wf_* commands.
	register_concmd("wfprog_state", "cmdState", ADMIN_CFG, "<target|all> - print seasonal progress and badges")
	register_concmd("wfprog_save", "cmdSave", ADMIN_CFG, "- flush every dirty seasonal record now")
	register_concmd("wfprog_reload", "cmdReload", ADMIN_CFG, "<target|all> - drop memory and re-read the vault (what a reconnect does)")
	register_concmd("wfprog_login", "cmdLogin", ADMIN_CFG, "<target|all> - run the daily-login check now")
	register_concmd("wfprog_report", "cmdReport", ADMIN_CFG, "<target|all> <metric> <n> - advance an event metric by hand")
	register_concmd("wfprog_reset", "cmdReset", ADMIN_CFG, "<target> <season|badges|all> - wipe seasonal progress")

	// 7. Event sources.
	//    - the tree's canonical combat forward (rsu_core) when it is there. The
	//      DeathMsg hook is registered either way: it resets the streak on every
	//      death, and it is the kill counter when rsu_core is absent (that is
	//      decided per event, not here, so load order cannot double-count).
	register_event("DeathMsg", "EventDeathMsg", "a")
	register_event("HLTV", "EventRoundStart", "a", "1=0", "2=0")
	register_logevent("EventRoundEnd", 2, "1=Round_End")

	// 8. Bounded housekeeping. Three tasks, none per frame:
	//    2 s  observe the core's present inventory (the only pull-only source)
	//    10 s read the core's levels/claims (advent, sets, tree, pass tier)
	//    30 s save what changed
	set_task(2.0, "Task_Tick", TASK_TICK, _, _, "b")
	set_task(10.0, "Task_Deep", TASK_DEEP, _, _, "b")
	set_task(30.0, "Task_AutoSave", TASK_AUTOSAVE, _, _, "b")
	set_task(60.0, "Task_Gate", TASK_GATE, _, _, "b")

	g_bHooksReady = true

	server_print("[FreeNova winterfest_progress] ready")
	log_amx("[WF-PROG] ready: %s season %d, window open, %d contract(s), %d achievement(s), core=%s",
		g_szSeasonName, g_iSeasonYear, g_iCtrCount, g_iAchCount,
		WfProgCore() ? "yes" : "MISSING (track only, no rewards)")

	if (!WfProgCore())
		log_amx("[WF-PROG] winterfest_core is not loaded: progress is tracked and saved, nothing is paid, nothing is announced")
}

public plugin_end()
{
	// Map change: every loaded record is flushed here as well as on disconnect,
	// so a crash between two maps loses at most META's 30 s of work.
	for (new id = 1; id <= MaxClients; id++)
		WfProgSave(id)
	remove_task(TASK_TICK)
	remove_task(TASK_DEEP)
	remove_task(TASK_AUTOSAVE)
	remove_task(TASK_GATE)
	for (new id = 1; id <= MaxClients; id++)
		remove_task(id + TASK_READY)
	if (g_Vault != INVALID_HANDLE)
	{
		nvault_close(g_Vault)
		g_Vault = INVALID_HANDLE
	}
}

public client_putinserver(id)
{
	WfProgResetClient(id)
	if (!g_bOpen)
		return
	if (!WfProgHuman(id))
		return
	g_iReadyTries[id] = 0
	set_task(1.0, "Task_Ready", id + TASK_READY)
}

public client_disconnected(id)
{
	remove_task(id + TASK_READY)
	remove_task(id + TASK_LOGIN)
	if (g_bOpen)
		WfProgSave(id)
	WfProgResetClient(id)
}

// The record is loaded off the connect frame: the steamid is often still
// STEAM_ID_PENDING at client_putinserver, and a record written under that key
// would be shared by every player on the box.
public Task_Ready(taskid)
{
	new id = taskid - TASK_READY
	if (!g_bOpen || !WfProgHuman(id))
		return

	new auth[48]
	if (!WfProgAuth(id, auth, charsmax(auth)))
	{
		g_iReadyTries[id]++
		if (g_iReadyTries[id] < 8)
		{
			set_task(2.0, "Task_Ready", id + TASK_READY)
			return
		}
		log_amx("[WF-PROG] no usable steamid for id %d after %d tries - seasonal progress is not tracked this session",
			id, g_iReadyTries[id])
		return
	}

	if (!WfProgLoad(id, auth))
		return

	WfProgTryLogin(id, false)
}

// ============================================================
// Guards
// ============================================================
// A bot, an HLTV proxy and a stale id have no record, no menu and nothing to
// claim (workstream rule 4).
//
// The one exception is the harness: it has no human client, so the documented
// test cvar wfprog_test_bots (default 0, see docs/WINTERFEST-PROGRESS.md §7)
// lets a bot act as the SUBJECT for progress and payment. Even then it sees
// nothing: WfProgNotice() suppresses every player-facing line for a bot, and a
// bot never sends a client command, so no menu can open. Production runs with
// the default, which is indistinguishable from "bots are not players".
stock bool:WfProgHuman(id)
{
	if (id < 1 || id > MaxClients)
		return false
	if (!is_user_connected(id) || is_user_hltv(id))
		return false
	if (is_user_bot(id))
		return (get_cvar_num("wfprog_test_bots") != 0) ? true : false
	return true
}

// One chat line, and the only place this module talks to a player. A bot never
// gets one, however it got this far.
stock WfProgNotice(id, const fmt[], ...)
{
	if (!WfProgHuman(id) || is_user_bot(id) || is_user_hltv(id))
		return
	new buf[192]
	vformat(buf, charsmax(buf), fmt, 3)
	client_print_color(id, print_team_default, "%s", buf)
}

stock bool:WfProgCore()
{
	return LibraryExists("winterfest_core", LibType_Library) ? true : false
}

// The core has no "is this player's record in memory yet" native. A loaded
// player always has tree level >= 1 (WfClearMem sets 1 and nothing lowers it),
// while a native call for an unloaded player returns 0, so this is the probe.
// It is the one core internal this module relies on and it is documented in
// docs/WINTERFEST-PROGRESS.md §6.
stock bool:WfProgCoreReady(id)
{
	if (!WfProgCore())
		return false
	return (wf_tree_level(id) >= 1) ? true : false
}

// The steamid used in every key. PENDING/UNKNOWN mean "not yet"; a LAN id is
// shared by every player on a listen/LAN box, so the name is appended to keep
// two testers apart (a real server never takes that path).
stock bool:WfProgAuth(id, out[], len)
{
	out[0] = 0
	if (!WfProgHuman(id))
		return false
	get_user_authid(id, out, len - 1)
	if (!out[0])
		return false
	if (equal(out, "STEAM_ID_PENDING") || equal(out, "UNKNOWN"))
	{
		out[0] = 0
		return false
	}
	if (is_user_bot(id))
	{
		// Only reachable with wfprog_test_bots on. YAPB bots all report the same
		// "BOT" authid, which would make every bot share one record.
		new uid = get_user_userid(id)
		formatex(out, len, "BOT#%d", uid)
	}
	if (contain(out, "ID_LAN") >= 0)
	{
		new name[MAX_NAME_LENGTH]
		get_user_name(id, name, charsmax(name))
		formatex(out, len, "LAN#%s", name)
	}
	for (new i = 0; out[i]; i++)
		if (out[i] == ':')
			out[i] = '_'
	return true
}

// ============================================================
// The season window
// ============================================================
stock WfProgLoadConfig()
{
	g_bCfgOk = false
	g_bEnabled = true
	g_szSeasonName[0] = 0
	g_iSeasonYear = 0
	g_iStartDate = 0
	g_iStartMin = 0
	g_iEndDate = 0
	g_iEndMin = 0
	g_bLoginOn = true
	g_iLoginSnow = 25
	g_iLegendaryRarity = WF_RARITY_MAX - 1

	new path[128], dir[96]
	get_configsdir(dir, charsmax(dir))
	formatex(path, charsmax(path), "%s/%s", dir, CFG_PROGRESS)

	if (!file_exists(path))
	{
		log_amx("[WF-PROG] no %s - the seasonal layer stays dormant", path)
		return
	}
	new fp = fopen(path, "rt")
	if (!fp)
	{
		log_amx("[WF-PROG] %s exists but could not be opened - dormant", path)
		return
	}

	new line[256], section[24], key[32], val[96]
	section[0] = 0
	while (fgets(fp, line, charsmax(line)))
	{
		WfProgStripComment(line)
		trim(line)
		if (!line[0])
			continue
		if (line[0] == '[')
		{
			copy(section, charsmax(section), line[1])
			new close = contain(section, "]")
			if (close >= 0)
				section[close] = 0
			trim(section)
			strtolower(section)
			continue
		}
		new eq = contain(line, "=")
		if (eq < 1)
			continue
		copy(key, charsmax(key), line)
		key[eq] = 0
		trim(key)
		strtolower(key)
		copy(val, charsmax(val), line[eq + 1])
		trim(val)

		if (equal(section, "season"))
		{
			if (equal(key, "name"))
				copy(g_szSeasonName, charsmax(g_szSeasonName), val)
			else if (equal(key, "year"))
				g_iSeasonYear = str_to_num(val)
			else if (equal(key, "start"))
				WfProgDateTime(val, g_iStartDate, g_iStartMin)
			else if (equal(key, "end"))
				WfProgDateTime(val, g_iEndDate, g_iEndMin)
			else if (equal(key, "enabled"))
				g_bEnabled = (str_to_num(val) != 0) ? true : false
		}
		else if (equal(section, "login"))
		{
			if (equal(key, "enabled"))
				g_bLoginOn = (str_to_num(val) != 0) ? true : false
			else if (equal(key, "snowflakes") || equal(key, "gingerbread"))
				g_iLoginSnow = clamp(str_to_num(val), 1, 500)
		}
		else if (equal(section, "settings"))
		{
			if (equal(key, "legendary_rarity"))
				g_iLegendaryRarity = clamp(str_to_num(val), 0, WF_RARITY_MAX - 1)
		}
	}
	fclose(fp)

	if (!g_szSeasonName[0])
		copy(g_szSeasonName, charsmax(g_szSeasonName), "Winterfest")
	if (g_iSeasonYear < 2020 || g_iSeasonYear > 2100)
	{
		log_amx("[WF-PROG] progress.ini: [season] year = %d is out of range - dormant", g_iSeasonYear)
		return
	}
	if (!g_iStartDate || !g_iEndDate)
	{
		log_amx("[WF-PROG] progress.ini: [season] start/end missing - dormant (no window, no season)")
		return
	}
	if (g_iEndDate < g_iStartDate)
	{
		log_amx("[WF-PROG] progress.ini: end is before start - dormant")
		return
	}
	g_bCfgOk = true
}

// "2026-12-01 00:00" or "2026-12-01" -> YYYYMMDD + minutes into the day.
stock WfProgDateTime(const val[], &date, &minutes)
{
	new buf[8]
	new year = 0, month = 0, day = 0, hour = 0, minute = 0
	// The format is fixed, so the offsets are too; a value that does not look
	// like it is refused as 0 rather than guessed at.
	if (strlen(val) < 10)
	{
		date = 0
		minutes = 0
		return
	}
	copy(buf, charsmax(buf), val[0])
	year = str_to_num(buf)
	copy(buf, charsmax(buf), val[5])
	month = str_to_num(buf)
	copy(buf, charsmax(buf), val[8])
	day = str_to_num(buf)
	if (strlen(val) >= 16)
	{
		copy(buf, charsmax(buf), val[11])
		hour = str_to_num(buf)
		copy(buf, charsmax(buf), val[14])
		minute = str_to_num(buf)
	}
	date = year * 10000 + month * 100 + day
	minutes = clamp(hour, 0, 23) * 60 + clamp(minute, 0, 59)
}

// Now, as YYYYMMDD + minutes. The server clock is the clock (progress.ini
// explains why there is no timezone conversion).
stock WfProgNow(&date, &minutes)
{
	new buf[16]
	format_time(buf, charsmax(buf), "%Y%m%d")
	date = str_to_num(buf)
	format_time(buf, charsmax(buf), "%H%M")
	minutes = str_to_num(buf) / 100 * 60 + str_to_num(buf) % 100
}

stock bool:WfProgInWindow()
{
	if (!g_bCfgOk || !g_bEnabled)
		return false
	new ndate, nmin
	WfProgNow(ndate, nmin)
	if (ndate < g_iStartDate || ndate > g_iEndDate)
		return false
	if (ndate == g_iStartDate && nmin < g_iStartMin)
		return false
	if (ndate == g_iEndDate && nmin > g_iEndMin)
		return false
	return true
}

public Task_Gate()
{
	if (!g_bHooksReady)
		return
	new bool:was = g_bOpen
	g_bOpen = WfProgInWindow()
	if (was && !g_bOpen)
	{
		// Flush before going quiet: the season just ended mid-map.
		for (new id = 1; id <= MaxClients; id++)
			WfProgSave(id)
		log_amx("[WF-PROG] the window closed mid-map - progress saved, every hook is now silent (the next map starts dormant)")
	}
	else if (!was && g_bOpen)
	{
		log_amx("[WF-PROG] the window opened mid-map - commands and hooks are live from here; a contract's period starts at its next advance")
	}
}

// ============================================================
// Config: seasonal missions (same shape as configs/freenova/missions.ini)
// ============================================================
stock WfProgLoadMissions()
{
	g_iCtrCount = 0
	g_iSeasonTag = g_iSeasonYear

	new path[128], dir[96]
	get_configsdir(dir, charsmax(dir))
	formatex(path, charsmax(path), "%s/%s", dir, CFG_MISSIONS)
	if (!file_exists(path))
	{
		log_amx("[WF-PROG] no %s - the season runs without missions (the daily login still works)", path)
		return
	}
	new fp = fopen(path, "rt")
	if (!fp)
	{
		log_amx("[WF-PROG] %s could not be opened - no seasonal missions", path)
		return
	}

	new line[256], section[24]
	new lineno = 0, rows = 0
	section[0] = 0
	while (fgets(fp, line, charsmax(line)))
	{
		lineno++
		WfProgStripComment(line)
		trim(line)
		if (!line[0])
			continue
		if (line[0] == '[')
		{
			copy(section, charsmax(section), line[1])
			new close = contain(section, "]")
			if (close >= 0)
				section[close] = 0
			trim(section)
			strtolower(section)
			continue
		}
		if (equal(section, "settings"))
		{
			if (containi(line, "season") == 0)
			{
				new eq = contain(line, "=")
				if (eq > 0)
					g_iSeasonTag = str_to_num(line[eq + 1])
			}
			continue
		}
		if (equal(section, "mission"))
		{
			rows++
			WfProgParseMission(line, lineno)
		}
	}
	fclose(fp)

	WfProgDropEmptyContracts()

	if (g_iCtrCount < 1)
		log_amx("[WF-PROG] missions.ini: %d row(s), no valid contract - the panel and /christmasmissions will show none", rows)
	else
		log_amx("[WF-PROG] missions.ini: %d row(s) -> %d contract(s)", rows, g_iCtrCount)
}

// Finds or creates the contract for type+slot, then stores the row as a target
// variant. A weight-0 row is STAGED (kept in the file, never rolled) and only
// contributes if the slot has at least one weighted row, which is how a contract
// for a mode that has not shipped yet stays in the file without being dead.
stock WfProgParseMission(const line[], lineno)
{
	new id[24], type[12], slotbuf[8], metricbuf[24], targetbuf[8]
	new weightbuf[8], xpbuf[16], coinbuf[16], seasonbuf[8], tags[64]

	if (!WfField(line, 0, id, charsmax(id)) || !WfField(line, 1, type, charsmax(type))
		|| !WfField(line, 2, slotbuf, charsmax(slotbuf)) || !WfField(line, 3, metricbuf, charsmax(metricbuf))
		|| !WfField(line, 4, targetbuf, charsmax(targetbuf)))
	{
		log_amx("[WF-PROG] missions.ini: line %d: fewer than 5 fields - row skipped", lineno)
		return
	}
	WfField(line, 5, weightbuf, charsmax(weightbuf))
	WfField(line, 6, xpbuf, charsmax(xpbuf))
	WfField(line, 7, coinbuf, charsmax(coinbuf))
	WfField(line, 8, seasonbuf, charsmax(seasonbuf))
	WfField(line, 9, tags, charsmax(tags))

	if (seasonbuf[0] && str_to_num(seasonbuf) != g_iSeasonTag)
		return   // staged for another season, silently: that is what the column is for

	new group = WfProgGroupFromName(type)
	if (group < 0)
	{
		log_amx("[WF-PROG] missions.ini: line %d: unknown type '%s' (daily|weekly|season) - row skipped", lineno, type)
		return
	}
	new slot = str_to_num(slotbuf)
	if (slot < 0 || slot >= WfProgSlotCap(group))
	{
		log_amx("[WF-PROG] missions.ini: line %d: slot %d out of range for '%s' - row skipped", lineno, slot, type)
		return
	}
	new metric = WfProgMetricFromName(metricbuf)
	if (metric == MTR_NONE)
	{
		log_amx("[WF-PROG] missions.ini: line %d: unknown metric '%s' - row skipped", lineno, metricbuf)
		return
	}
	new target = str_to_num(targetbuf)
	if (target <= 0)
	{
		log_amx("[WF-PROG] missions.ini: line %d: target must be > 0 - row skipped", lineno)
		return
	}
	new weight = str_to_num(weightbuf)
	if (weight < 0)
		weight = 0

	new mapname[32]
	if (!WfProgTagValue(tags, "map", mapname, charsmax(mapname)))
		mapname[0] = 0

	if (WfProgClass(metric) == MC_LEVEL && group != GRP_SEASON)
	{
		log_amx("[WF-PROG] missions.ini: line %d: '%s' is a level and cannot be a %s contract - row skipped",
			lineno, metricbuf, type)
		return
	}
	if (metric == MTR_MAP_ROUNDS && !mapname[0])
	{
		log_amx("[WF-PROG] missions.ini: line %d: map_rounds needs a map=<name> tag - row skipped", lineno)
		return
	}

	new ctr = WfProgFindContract(group, slot)
	if (ctr < 0)
	{
		if (g_iCtrCount >= MAX_CTR)
		{
			log_amx("[WF-PROG] missions.ini: line %d: more than %d contracts - row skipped", lineno, MAX_CTR)
			return
		}
		ctr = g_iCtrCount++
		copy(g_szCtrId[ctr], charsmax(g_szCtrId[]), id)
		formatex(g_szCtrKey[ctr], charsmax(g_szCtrKey[]), "%s%d", WfProgGroupLetter(group), slot)
		g_iCtrGroup[ctr] = group
		g_iCtrSlot[ctr] = slot
		g_iCtrMetric[ctr] = metric
		copy(g_szCtrMap[ctr], charsmax(g_szCtrMap[]), mapname)
		g_iCandCount[ctr] = 0
	}
	else if (g_iCtrMetric[ctr] != metric)
	{
		// One slot measures one thing: two variants counting different metrics
		// would make the same contract id mean two different things.
		log_amx("[WF-PROG] missions.ini: line %d: '%s' disagrees with the metric of slot %s - using the first row",
			lineno, metricbuf, g_szCtrKey[ctr])
		return
	}

	if (weight <= 0)
	{
		log_amx("[WF-PROG] missions.ini: line %d: '%s' is staged (weight 0) - it is not rolled", lineno, id)
		return
	}
	if (g_iCandCount[ctr] >= MAX_CAND)
	{
		log_amx("[WF-PROG] missions.ini: line %d: more than %d target variants for %s - row skipped",
			lineno, MAX_CAND, g_szCtrKey[ctr])
		return
	}
	new n = g_iCandCount[ctr]
	g_iCandRow[ctr][n] = 0
	g_iCandWeight[ctr][n] = weight
	g_iCandTarget[ctr][n] = target
	g_iCandSnow[ctr][n] = clamp(str_to_num(coinbuf), 0, 100000)
	g_iCandXp[ctr][n] = clamp(str_to_num(xpbuf), 0, 100000)
	g_iCandCount[ctr] = n + 1
}

// A contract created by a staged (weight 0) row alone has no candidate: drop it
// so the menu and the payment loop never see a contract nobody can complete.
stock WfProgDropEmptyContracts()
{
	for (new c = 0; c < g_iCtrCount; c++)
	{
		if (g_iCandCount[c] > 0)
			continue
		for (new k = c; k < g_iCtrCount - 1; k++)
		{
			copy(g_szCtrId[k], charsmax(g_szCtrId[]), g_szCtrId[k + 1])
			copy(g_szCtrKey[k], charsmax(g_szCtrKey[]), g_szCtrKey[k + 1])
			g_iCtrGroup[k] = g_iCtrGroup[k + 1]
			g_iCtrSlot[k] = g_iCtrSlot[k + 1]
			g_iCtrMetric[k] = g_iCtrMetric[k + 1]
			copy(g_szCtrMap[k], charsmax(g_szCtrMap[]), g_szCtrMap[k + 1])
			g_iCandCount[k] = g_iCandCount[k + 1]
			for (new v = 0; v < MAX_CAND; v++)
			{
				g_iCandRow[k][v] = g_iCandRow[k + 1][v]
				g_iCandWeight[k][v] = g_iCandWeight[k + 1][v]
				g_iCandTarget[k][v] = g_iCandTarget[k + 1][v]
				g_iCandSnow[k][v] = g_iCandSnow[k + 1][v]
				g_iCandXp[k][v] = g_iCandXp[k + 1][v]
			}
		}
		g_iCtrCount--
		c--   // the row that moved into slot c has to be checked too
	}
}

stock WfProgFindContract(group, slot)
{
	for (new c = 0; c < g_iCtrCount; c++)
		if (g_iCtrGroup[c] == group && g_iCtrSlot[c] == slot)
			return c
	return -1
}

stock WfProgSlotCap(group)
{
	switch (group)
	{
		case GRP_DAILY:  return 6
		case GRP_WEEKLY: return 4
		case GRP_SEASON: return 8
	}
	return 0
}

stock WfProgGroupFromName(const s[])
{
	if (equal(s, "daily")) return GRP_DAILY
	if (equal(s, "weekly")) return GRP_WEEKLY
	if (equal(s, "season") || equal(s, "seasonal")) return GRP_SEASON
	return -1
}

stock WfProgGroupLetter(group)
{
	switch (group)
	{
		case GRP_DAILY:  return 'd'
		case GRP_WEEKLY: return 'w'
	}
	return 's'
}

// Pawn cannot return a string, so the name is an out parameter like every other
// string helper in this tree.
stock WfProgGroupName(group, out[], len)
{
	switch (group)
	{
		case GRP_DAILY:  copy(out, len, "daily")
		case GRP_WEEKLY: copy(out, len, "weekly")
		default:         copy(out, len, "season")
	}
}

// ============================================================
// Config: seasonal achievements
// ============================================================
stock WfProgLoadAchievements()
{
	g_iAchCount = 0

	new path[128], dir[96]
	get_configsdir(dir, charsmax(dir))
	formatex(path, charsmax(path), "%s/%s", dir, CFG_ACHIEVE)
	if (!file_exists(path))
	{
		log_amx("[WF-PROG] no %s - the season runs without achievements", path)
		return
	}
	new fp = fopen(path, "rt")
	if (!fp)
	{
		log_amx("[WF-PROG] %s could not be opened - no seasonal achievements", path)
		return
	}

	new line[256], section[24]
	new lineno = 0
	section[0] = 0
	while (fgets(fp, line, charsmax(line)))
	{
		lineno++
		WfProgStripComment(line)
		trim(line)
		if (!line[0])
			continue
		if (line[0] == '[')
		{
			copy(section, charsmax(section), line[1])
			new close = contain(section, "]")
			if (close >= 0)
				section[close] = 0
			trim(section)
			strtolower(section)
			continue
		}
		if (equal(section, "achievement"))
			WfProgParseAchievement(line, lineno)
	}
	fclose(fp)

	log_amx("[WF-PROG] achievements.ini: %d badge(s)", g_iAchCount)
}

stock WfProgParseAchievement(const line[], lineno)
{
	new id[24], name[32], check[24], targetbuf[8], xpbuf[16], coinbuf[16], badge[24], seasonbuf[8]

	if (!WfField(line, 0, id, charsmax(id)) || !WfField(line, 1, name, charsmax(name))
		|| !WfField(line, 2, check, charsmax(check)) || !WfField(line, 3, targetbuf, charsmax(targetbuf)))
	{
		log_amx("[WF-PROG] achievements.ini: line %d: fewer than 4 fields - row skipped", lineno)
		return
	}
	WfField(line, 4, xpbuf, charsmax(xpbuf))
	WfField(line, 5, coinbuf, charsmax(coinbuf))
	WfField(line, 6, badge, charsmax(badge))
	WfField(line, 7, seasonbuf, charsmax(seasonbuf))

	if (seasonbuf[0] && str_to_num(seasonbuf) != g_iSeasonTag)
		return

	new metric = WfProgMetricFromName(check)
	if (metric == MTR_NONE)
	{
		log_amx("[WF-PROG] achievements.ini: line %d: unknown check '%s' - row skipped", lineno, check)
		return
	}
	if (metric == MTR_MAP_ROUNDS)
	{
		log_amx("[WF-PROG] achievements.ini: line %d: map_rounds has no map here - row skipped", lineno)
		return
	}
	new target = str_to_num(targetbuf)
	if (target <= 0)
	{
		log_amx("[WF-PROG] achievements.ini: line %d: target must be > 0 - row skipped", lineno)
		return
	}
	if (g_iAchCount >= MAX_ACH)
	{
		log_amx("[WF-PROG] achievements.ini: line %d: more than %d achievements - row skipped", lineno, MAX_ACH)
		return
	}
	if (!badge[0])
		copy(badge, charsmax(badge), name)

	new n = g_iAchCount++
	copy(g_szAchId[n], charsmax(g_szAchId[]), id)
	copy(g_szAchName[n], charsmax(g_szAchName[]), name)
	copy(g_szAchBadge[n], charsmax(g_szAchBadge[]), badge)
	g_iAchMetric[n] = metric
	g_iAchTarget[n] = target
	g_iAchSnow[n] = str_to_num(coinbuf)
	g_iAchXp[n] = str_to_num(xpbuf)
}

// ============================================================
// Small parsing helpers
// ============================================================
// A ';' or '#' anywhere starts a comment, including at the first character
// (which is how the shipped files separate the daily/weekly/season blocks).
stock WfProgStripComment(line[])
{
	for (new i = 0; line[i]; i++)
	{
		if (line[i] == ';' || line[i] == '#')
		{
			line[i] = 0
			return
		}
	}
}

// "a,b,map=de_dust2" -> the value of `key`. Bounded by the string.
stock bool:WfProgTagValue(const tags[], const key[], out[], len)
{
	out[0] = 0
	new n = strlen(tags), start = 0, klen = strlen(key)
	for (new i = 0; i <= n; i++)
	{
		if (i < n && tags[i] != ',')
			continue
		new c = i - start
		if (c > klen && tags[start + klen] == '=')
		{
			new match = 1
			for (new k = 0; k < klen; k++)
			{
				if (tags[start + k] != key[k])
				{
					match = 0
					break
				}
			}
			if (match)
			{
				new vlen = c - klen - 1
				if (vlen > len - 1)
					vlen = len - 1
				for (new k = 0; k < vlen; k++)
					out[k] = tags[start + klen + 1 + k]
				out[vlen] = 0
				trim(out)
				return (out[0] != 0) ? true : false
			}
		}
		start = i + 1
	}
	return false
}

stock WfProgMetricFromName(const s[])
{
	for (new i = 1; i < MTR_COUNT; i++)
		if (equal(s, g_szMetricName[i]))
			return i
	// The base file's vocabulary, so an operator can copy a row between the two
	// files without learning a second set of words.
	if (equal(s, "frags")) return MTR_KILLS
	if (equal(s, "hs")) return MTR_HEADSHOTS
	if (equal(s, "round_wins")) return MTR_WINS
	if (equal(s, "gift") || equal(s, "gifts")) return MTR_PRESENTS
	if (equal(s, "opened")) return MTR_OPENS
	if (equal(s, "collection") || equal(s, "collections")) return MTR_SETS
	if (equal(s, "level")) return MTR_TREE
	if (equal(s, "tier")) return MTR_PASS_TIER
	if (equal(s, "snowball")) return MTR_SNOWBALL_HS
	return MTR_NONE
}

stock WfProgClass(metric)
{
	switch (metric)
	{
		case MTR_PRESENTS, MTR_OPENS, MTR_LEGENDARY, MTR_ADVENT, MTR_SETS:
			return MC_COUNTER
		case MTR_TREE, MTR_PASS_TIER:
			return MC_LEVEL
		case MTR_STREAK:
			return MC_MAX
	}
	return MC_EVENT
}

// The player-facing wording of a contract. Derived from the metric and the
// target, so a config edit never needs a second name column and the panel and
// the game cannot disagree about what a contract asks for.
stock WfProgLabel(metric, target, const map[], out[], len)
{
	switch (metric)
	{
		case MTR_KILLS:        formatex(out, len, "Get %d kills", target)
		case MTR_HEADSHOTS:    formatex(out, len, "Get %d headshot kills", target)
		case MTR_STREAK:       formatex(out, len, "Reach a %d-kill streak", target)
		case MTR_ROUNDS:       formatex(out, len, "Play %d rounds", target)
		case MTR_MAP_ROUNDS:   formatex(out, len, "Play %d rounds on %s", target, map)
		case MTR_WINS:         formatex(out, len, "Win %d rounds", target)
		case MTR_PRESENTS:     formatex(out, len, "Collect %d presents", target)
		case MTR_OPENS:        formatex(out, len, "Open %d presents", target)
		case MTR_LEGENDARY:    formatex(out, len, "Find %d legendary presents", target)
		case MTR_ADVENT:       formatex(out, len, "Claim %d Advent days", target)
		case MTR_SETS:         formatex(out, len, "Complete %d secret collection", target)
		case MTR_TREE:         formatex(out, len, "Reach tree level %d", target)
		case MTR_PASS_TIER:    formatex(out, len, "Reach Winter Pass tier %d", target)
		case MTR_SNOWBALL_HS:  formatex(out, len, "Headshot %d players with a snowball", target)
		default:               copy(out, len, "Seasonal contract")
	}
}

// ============================================================
// Periods and the roll
// ============================================================
stock WfProgGetPeriod(ctr, out[], len)
{
	switch (g_iCtrGroup[ctr])
	{
		case GRP_DAILY:  format_time(out, len, "d%Y%m%d")
		case GRP_WEEKLY: format_time(out, len, "w%G-%V")
		default:         formatex(out, len, "s%d", g_iSeasonYear)
	}
}

// Starts a new period exactly once: the progress, the paid flag, the core
// baseline and the rolled variant all belong to the period they were created in.
stock WfProgEnsurePeriod(ctr, id)
{
	new per[12]
	WfProgGetPeriod(ctr, per, charsmax(per))
	if (equal(g_szCtrPeriod[ctr][id], per))
		return
	copy(g_szCtrPeriod[ctr][id], charsmax(g_szCtrPeriod[]), per)
	g_iCtrProg[ctr][id] = 0
	g_bCtrPaid[ctr][id] = false
	g_iCtrLast[ctr][id] = -1
	WfProgRoll(ctr, id, per)
	g_bDirty[id] = true
	if (g_iCtrGroup[ctr] == GRP_DAILY)
		g_iStreakRun[id] = 0
}

// Deterministic: steamid + season + contract + period. A reconnect inside the
// same period gets the same variant, so a half-finished contract cannot change
// its target under the player.
stock WfProgRoll(ctr, id, const period[])
{
	g_iCtrTarget[ctr][id] = 0
	g_iCtrSnow[ctr][id] = 0
	g_iCtrXp[ctr][id] = 0

	new total = 0
	for (new v = 0; v < g_iCandCount[ctr]; v++)
		total += g_iCandWeight[ctr][v]
	if (total <= 0)
		return

	new auth[48], seed[128]
	if (!WfProgAuth(id, auth, charsmax(auth)))
	{
		WfProgSetCandidate(ctr, id, 0)
		return
	}
	formatex(seed, charsmax(seed), "%s#%d#%s#%s", auth, g_iSeasonYear, g_szCtrKey[ctr], period)

	new pick = WfProgHash(seed) % total
	for (new v = 0; v < g_iCandCount[ctr]; v++)
	{
		pick -= g_iCandWeight[ctr][v]
		if (pick < 0)
		{
			WfProgSetCandidate(ctr, id, v)
			return
		}
	}
	WfProgSetCandidate(ctr, id, 0)
}

stock WfProgSetCandidate(ctr, id, v)
{
	g_iCtrTarget[ctr][id] = g_iCandTarget[ctr][v]
	g_iCtrSnow[ctr][id] = g_iCandSnow[ctr][v]
	g_iCtrXp[ctr][id] = g_iCandXp[ctr][v]
}

// djb2, masked to stay positive. Only used to pick a variant, so a hash
// collision costs a different target, never a wrong payment.
stock WfProgHash(const s[])
{
	new h = 5381
	for (new i = 0; s[i]; i++)
		h = (h * 33 + s[i]) & 0x7FFFFFFF
	return h
}

// ============================================================
// Persistence
// ============================================================
stock bool:WfProgKey(const auth[], const suffix[], key[], len)
{
	formatex(key, len, "wfprog_s%d#%s#%s", g_iSeasonYear, auth, suffix)
	if (strlen(key) >= MAX_KEY)
	{
		log_amx("[WF-PROG] ERROR: vault key too long (%d >= %d) - refusing the write", strlen(key), MAX_KEY)
		key[0] = 0
		return false
	}
	return true
}

stock WfProgLoad(id, const auth[])
{
	WfProgResetClient(id)
	if (g_Vault == INVALID_HANDLE)
	{
		// No vault: the session still tracks in memory, it just cannot persist.
		g_bLoaded[id] = true
		return true
	}

	new key[MAX_KEY], val[256]

	// Season numbers (presents, opens, totals, last login date).
	new suffix[16]
	formatex(suffix, charsmax(suffix), "meta")
	if (WfProgKey(auth, suffix, key, charsmax(key)) && nvault_get(g_Vault, key, val, charsmax(val)))
		WfProgReadMeta(id, val)

	// Permanent badges. Deliberately not season-stamped: a badge earned in
	// December 2026 is still the player's in December 2027.
	formatex(key, charsmax(key), "wfprog_badge#%s", auth)
	if (strlen(key) < MAX_KEY && nvault_get(g_Vault, key, val, charsmax(val)))
		copy(g_szBadges[id], charsmax(g_szBadges[]), val)

	// Per-contract progress, one key each: a corrupted contract cannot take the
	// rest of the record with it, and adding a contract to the ini does not
	// change the layout of the ones already stored.
	for (new c = 0; c < g_iCtrCount; c++)
	{
		if (!WfProgKey(auth, g_szCtrKey[c], key, charsmax(key)))
			continue
		if (!nvault_get(g_Vault, key, val, charsmax(val)))
			continue
		WfProgReadContract(id, c, val)
	}

	g_bLoaded[id] = true
	g_bDirty[id] = false
	return true
}

// "<progress> <period> <paid> <last observed counter>"
stock WfProgReadContract(id, ctr, const val[])
{
	new pos = 0, cell[24]
	if (!WfProgNextCell(val, pos, cell, charsmax(cell)))
		return
	g_iCtrProg[ctr][id] = clamp(str_to_num(cell), 0, 100000)
	if (!WfProgNextCell(val, pos, cell, charsmax(cell)))
		return
	copy(g_szCtrPeriod[ctr][id], charsmax(g_szCtrPeriod[]), cell)
	if (!WfProgNextCell(val, pos, cell, charsmax(cell)))
		return
	g_bCtrPaid[ctr][id] = (str_to_num(cell) != 0) ? true : false
	if (!WfProgNextCell(val, pos, cell, charsmax(cell)))
		return
	g_iCtrLast[ctr][id] = str_to_num(cell)
}

// The meta cells, space separated, version first so a future format can be
// recognised instead of misread.
stock WfProgReadMeta(id, const val[])
{
	new pos = 0, cell[24], ver = 0
	if (!WfProgNextCell(val, pos, cell, charsmax(cell)))
		return
	ver = str_to_num(cell)
	if (ver != 1)
	{
		log_amx("[WF-PROG] meta record for id %d is version %d, this build writes 1 - starting a fresh record", id, ver)
		return
	}
	for (new m = 0; m < META_COUNT; m++)
	{
		if (!WfProgNextCell(val, pos, cell, charsmax(cell)))
			return
		g_iMeta[id][m] = str_to_num(cell)
	}
}

stock WfProgSave(id)
{
	if (!g_bOpen && !g_bHooksReady)
		return
	if (id < 1 || id > MaxClients)
		return
	if (!g_bLoaded[id] || !g_bDirty[id] || g_Vault == INVALID_HANDLE)
		return

	new auth[48]
	if (!WfProgAuth(id, auth, charsmax(auth)))
		return

	new key[MAX_KEY], val[256], suffix[16]
	formatex(suffix, charsmax(suffix), "meta")
	if (WfProgKey(auth, suffix, key, charsmax(key)))
	{
		new pos = 0
		pos += formatex(val[pos], charsmax(val) - pos, "1")
		for (new m = 0; m < META_COUNT; m++)
			pos += formatex(val[pos], charsmax(val) - pos, " %d", g_iMeta[id][m])
		nvault_set(g_Vault, key, val)
	}

	for (new c = 0; c < g_iCtrCount; c++)
	{
		if (!WfProgKey(auth, g_szCtrKey[c], key, charsmax(key)))
			continue
		formatex(val, charsmax(val), "%d %s %d %d",
			g_iCtrProg[c][id], g_szCtrPeriod[c][id],
			_:g_bCtrPaid[c][id], g_iCtrLast[c][id])
		nvault_set(g_Vault, key, val)
	}

	g_bDirty[id] = false
}

stock WfProgSaveBadges(id)
{
	if (g_Vault == INVALID_HANDLE || !g_bLoaded[id])
		return
	new auth[48], key[MAX_KEY]
	if (!WfProgAuth(id, auth, charsmax(auth)))
		return
	formatex(key, charsmax(key), "wfprog_badge#%s", auth)
	if (strlen(key) >= MAX_KEY)
		return
	nvault_set(g_Vault, key, g_szBadges[id])
}

stock WfProgResetClient(id)
{
	g_bLoaded[id] = false
	g_bDirty[id] = false
	g_bNoCoreWarned[id] = false
	g_iReadyTries[id] = 0
	g_iLoginTries[id] = 0
	g_iStreakRun[id] = 0
	g_szBadges[id][0] = 0
	g_szTopBag[id][0] = 0
	g_iCtrPage[id] = 0
	g_iAchPage[id] = 0
	for (new m = 0; m < META_COUNT; m++)
		g_iMeta[id][m] = 0
	for (new c = 0; c < MAX_CTR; c++)
	{
		g_iCtrProg[c][id] = 0
		g_szCtrPeriod[c][id][0] = 0
		g_bCtrPaid[c][id] = false
		g_iCtrLast[c][id] = -1
		g_iCtrTarget[c][id] = 0
	}
}

// One space separated cell. Bounded by the string, never by a guess.
stock bool:WfProgNextCell(const line[], &pos, out[], len)
{
	new n = strlen(line), c = 0
	out[0] = 0
	while (pos < n && (line[pos] == ' ' || line[pos] == 9))
		pos++
	if (pos >= n)
		return false
	while (pos < n && line[pos] != ' ' && line[pos] != 9)
	{
		if (c < len - 1)
			out[c++] = line[pos]
		pos++
	}
	out[c] = 0
	return (c > 0) ? true : false
}

public Task_AutoSave()
{
	if (!g_bOpen)
		return
	for (new id = 1; id <= MaxClients; id++)
		WfProgSave(id)
}

// ============================================================
// Metric values
// ============================================================
stock WfProgCumulative(id, metric)
{
	if (!WfProgCoreReady(id))
		return -1
	switch (metric)
	{
		case MTR_PRESENTS:  return g_iMeta[id][META_GIFTSEQ]
		case MTR_OPENS:     return g_iMeta[id][META_OPENS]
		case MTR_LEGENDARY: return g_iMeta[id][META_LEGENDARY]
		case MTR_ADVENT:
		{
			new n = 0
			for (new d = 1; d <= ADVENT_DAYS; d++)
				if (wf_advent_claimed(id, d))
					n++
			return n
		}
		case MTR_SETS:
		{
			new n = 0
			new sets = wf_set_count()
			for (new s = 1; s <= sets; s++)
				if (wf_set_owned(id, s))
					n++
			return n
		}
		case MTR_TREE:      return wf_tree_level(id)
		case MTR_PASS_TIER: return wf_pass_tier(id)
	}
	return -1
}

// What an achievement measures. Counter/level metrics are the core's numbers;
// the event metrics read this module's own season totals.
stock WfProgAchValue(id, metric)
{
	new cls = WfProgClass(metric)
	if (cls == MC_COUNTER || cls == MC_LEVEL)
		return WfProgCumulative(id, metric)
	switch (metric)
	{
		case MTR_KILLS:       return g_iMeta[id][META_KILLS]
		case MTR_HEADSHOTS:   return g_iMeta[id][META_HEADSHOTS]
		case MTR_STREAK:      return g_iMeta[id][META_STREAK]
		case MTR_ROUNDS:      return g_iMeta[id][META_ROUNDS]
		case MTR_WINS:        return g_iMeta[id][META_WINS]
		case MTR_SNOWBALL_HS: return g_iMeta[id][META_SNOWBALL]
	}
	return 0
}

// ============================================================
// Progress, evaluation, payment
// ============================================================
// One engine event (or a report from another module) hitting every contract
// that counts it. `amount` is the delta, or the new streak for MTR_STREAK.
stock WfProgEvent(id, metric, amount)
{
	if (!g_bLoaded[id] || amount <= 0)
		return
	new cls = WfProgClass(metric)
	if (cls == MC_COUNTER || cls == MC_LEVEL)
		return   // those are read from the core, never pushed

	for (new c = 0; c < g_iCtrCount; c++)
	{
		if (g_iCtrMetric[c] != metric)
			continue
		WfProgEnsurePeriod(c, id)
		if (g_bCtrPaid[c][id] || g_iCtrTarget[c][id] <= 0)
			continue
		if (metric == MTR_MAP_ROUNDS && !equal(g_szCtrMap[c], g_szMap))
			continue
		if (cls == MC_MAX)
		{
			if (amount > g_iCtrProg[c][id])
			{
				g_iCtrProg[c][id] = amount
				g_bDirty[id] = true
			}
		}
		else
		{
			new next = g_iCtrProg[c][id] + amount
			if (next > g_iCtrTarget[c][id])
				next = g_iCtrTarget[c][id]
			if (next != g_iCtrProg[c][id])
			{
				g_iCtrProg[c][id] = next
				g_bDirty[id] = true
			}
		}
	}
}

// Walks every contract once: starts overdue periods, applies the core-derived
// deltas, caps progress at the target and pays what has completed. Called from
// the two timed tasks, from an event that just moved something, and when a
// menu is opened (so the numbers on screen are the numbers on disk).
stock WfProgEvaluate(id)
{
	if (!g_bLoaded[id])
		return
	new bool:ready = WfProgCoreReady(id)
	new values[MTR_COUNT]
	for (new m = 0; m < MTR_COUNT; m++)
		values[m] = -1

	for (new c = 0; c < g_iCtrCount; c++)
	{
		WfProgEnsurePeriod(c, id)
		new target = g_iCtrTarget[c][id]
		if (target <= 0)
			continue

		new cls = WfProgClass(g_iCtrMetric[c])
		if (ready && (cls == MC_COUNTER || cls == MC_LEVEL))
		{
			new metric = g_iCtrMetric[c]
			new cur = values[metric]
			if (cur < 0)
			{
				cur = WfProgCumulative(id, metric)
				values[metric] = cur
			}
			if (cur >= 0)
			{
				if (cls == MC_COUNTER)
				{
					if (g_iCtrLast[c][id] < 0)
					{
						// First look inside this period: that reading is the
						// baseline, so a player's season totals from last week do
						// not complete today's contract on the first tick.
						g_iCtrLast[c][id] = cur
					}
					else if (cur > g_iCtrLast[c][id])
					{
						new add = cur - g_iCtrLast[c][id]
						g_iCtrLast[c][id] = cur
						g_iCtrProg[c][id] += add
						g_bDirty[id] = true
					}
				}
				else if (cur > g_iCtrProg[c][id])
				{
					g_iCtrProg[c][id] = cur
					g_bDirty[id] = true
				}
			}
		}

		if (g_iCtrProg[c][id] > target)
			g_iCtrProg[c][id] = target
		if (!g_bCtrPaid[c][id] && g_iCtrProg[c][id] >= target)
			WfProgPayContract(c, id)
	}

	WfProgCheckAchievements(id)
}

stock WfProgPayContract(ctr, id)
{
	if (!g_bLoaded[id])
		return

	// Track-only mode: the contract is complete, but there is nobody to pay it.
	// It stays unclaimed, so a core that appears later (or a restart with the
	// core present) pays it exactly once. The log says so once per session, not
	// once per tick.
	if (!WfProgCore())
	{
		if (!g_bNoCoreWarned[id])
		{
			log_amx("[WF-PROG] winterfest_core missing: contract %s completed for id %d but cannot be paid", g_szCtrKey[ctr], id)
			g_bNoCoreWarned[id] = true
		}
		return
	}

	new auth[48], key[96]
	if (!WfProgAuth(id, auth, charsmax(auth)))
		return

	// One claim key per paid reward, and the key names the season, the contract,
	// the period and the steamid: the same contract completed twice in the same
	// second hashes to the same core claim and pays once (docs/WINTERFEST.md
	// §5.2). The core stamps the authid and season again - belt and braces, on
	// purpose.
	formatex(key, charsmax(key), "wfprog_m#%d#%s#%s#%s#gb",
		g_iSeasonYear, g_szCtrKey[ctr], g_szCtrPeriod[ctr][id], auth)
	new c1 = WF_GRANT_INVALID
	if (g_iCtrSnow[ctr][id] > 0)
		c1 = wf_grant(id, WF_REWARD_SNOWFLAKES, g_iCtrSnow[ctr][id], key)

	formatex(key, charsmax(key), "wfprog_m#%d#%s#%s#%s#xp",
		g_iSeasonYear, g_szCtrKey[ctr], g_szCtrPeriod[ctr][id], auth)
	new c2 = WF_GRANT_INVALID
	if (g_iCtrXp[ctr][id] > 0)
		c2 = wf_grant(id, WF_REWARD_PASS_XP, g_iCtrXp[ctr][id], key)

	if (c1 == WF_GRANT_NOTLOADED || c2 == WF_GRANT_NOTLOADED)
		return   // the core has not loaded this player yet: try again next tick

	// OK or DUPLICATE both mean "do not pay again" - the core writes the claim
	// before it pays, so a duplicate is a spent claim, not an invitation to retry.
	g_bCtrPaid[ctr][id] = true
	g_bDirty[id] = true

	new label[64]
	WfProgLabel(g_iCtrMetric[ctr], g_iCtrTarget[ctr][id], g_szCtrMap[ctr], label, charsmax(label))
	WfProgNotice(id, "^4[WF]^1 contract complete: ^3%s^1 \d(+%d %s, +%d pass XP)",
		label, g_iCtrSnow[ctr][id], WF_CURRENCY_NAME, g_iCtrXp[ctr][id])

	// "paid" = the core wrote the claim and paid in this call. "already-claimed"
	// = the claim was spent before (a second completion, a crash-and-retry, a
	// reconnect) and the core refused to pay twice - codes 0/0. The word is in
	// the log because that is the idempotency record an operator greps for.
	new verdict[24] = "paid"
	if (c1 != WF_GRANT_OK && c2 != WF_GRANT_OK)
		copy(verdict, charsmax(verdict), "already-claimed")
	// The label is the slot's FIRST row id (the shape's `id` column is a log
	// label, not a contract identity); target= says which variant this player
	// actually got.
	log_amx("[WF-PROG] contract %s (%s) id %d -> %s (target=%d gb=%d xp=%d codes=%d/%d)",
		g_szCtrKey[ctr], g_szCtrId[ctr], id, verdict,
		g_iCtrTarget[ctr][id], g_iCtrSnow[ctr][id], g_iCtrXp[ctr][id], c1, c2)
}

// ============================================================
// Achievements
// ============================================================
stock WfProgCheckAchievements(id)
{
	for (new a = 0; a < g_iAchCount; a++)
	{
		if (WfProgHasBadge(id, a + 1))
			continue
		new cur = WfProgAchValue(id, g_iAchMetric[a])
		if (cur < 0)
			continue
		if (cur < g_iAchTarget[a])
			continue
		WfProgUnlockAchievement(a, id)
	}
}

stock bool:WfProgHasBadge(id, achid)
{
	return WfListHas(g_szBadges[id], achid)
}

stock WfProgUnlockAchievement(a, id)
{
	if (!g_bLoaded[id])
		return
	if (!WfProgCore())
	{
		if (!g_bNoCoreWarned[id])
		{
			log_amx("[WF-PROG] winterfest_core missing: badge %s earned by id %d but cannot be paid", g_szAchId[a], id)
			g_bNoCoreWarned[id] = true
		}
		return
	}

	new auth[48], key[96]
	if (!WfProgAuth(id, auth, charsmax(auth)))
		return

	formatex(key, charsmax(key), "wfprog_a#%d#%s#%s#gb", g_iSeasonYear, g_szAchId[a], auth)
	new c1 = WF_GRANT_INVALID
	if (g_iAchSnow[a] > 0)
		c1 = wf_grant(id, WF_REWARD_SNOWFLAKES, g_iAchSnow[a], key)

	formatex(key, charsmax(key), "wfprog_a#%d#%s#%s#xp", g_iSeasonYear, g_szAchId[a], auth)
	new c2 = WF_GRANT_INVALID
	if (g_iAchXp[a] > 0)
		c2 = wf_grant(id, WF_REWARD_PASS_XP, g_iAchXp[a], key)

	if (c1 == WF_GRANT_NOTLOADED || c2 == WF_GRANT_NOTLOADED)
		return

	// Badge AFTER the payment: if the box dies in between, the badge is simply
	// re-earned on the next connect and the spent claim pays zero, so the
	// failure mode is "badge shows up a bit late", never "paid twice".
	if (!WfListAdd(g_szBadges[id], charsmax(g_szBadges[]), a + 1))
	{
		log_amx("[WF-PROG] badge list full for id %d - %s not recorded", id, g_szAchId[a])
		return
	}
	WfProgSaveBadges(id)
	g_bDirty[id] = true

	WfProgNotice(id, "^4[WF]^1 achievement unlocked: ^3%s^1 \d(badge: %s, +%d %s, +%d pass XP)",
		g_szAchName[a], g_szAchBadge[a], g_iAchSnow[a], WF_CURRENCY_NAME, g_iAchXp[a])

	new verdict[24] = "paid"
	if (c1 != WF_GRANT_OK && c2 != WF_GRANT_OK)
		copy(verdict, charsmax(verdict), "already-claimed")
	log_amx("[WF-PROG] achievement %s (%s) unlocked for id %d -> %s (badge '%s' gb=%d xp=%d codes=%d/%d)",
		g_szAchId[a], g_szAchName[a], id, verdict, g_szAchBadge[a], g_iAchSnow[a], g_iAchXp[a], c1, c2)
}

// ============================================================
// The daily login gift
// ============================================================
// `force` re-attempts the payment even when the record already says "paid today"
// so the core's claim ledger answers, not this module's own date. That is what
// the operator command and the harness use to prove the claim key.
stock WfProgTryLogin(id, bool:force)
{
	if (!g_bOpen || !g_bLoginOn)
		return
	if (!WfProgHuman(id))
		return
	if (!g_bLoaded[id])
	{
		// The record is loaded off the connect frame (the steamid is often still
		// pending when the client appears), so an early attempt waits instead of
		// losing the day.
		if (g_iLoginTries[id] < 8)
		{
			g_iLoginTries[id]++
			set_task(1.0, "Task_Login", id + TASK_LOGIN)
		}
		return
	}

	new date, minutes
	WfProgNow(date, minutes)
	if (g_iMeta[id][META_LOGINDATE] == date && !force)
		return   // already paid today: the cheap path, no native call at all

	if (!WfProgCore())
	{
		if (!g_bNoCoreWarned[id])
		{
			log_amx("[WF-PROG] winterfest_core missing: no daily login bundle for id %d", id)
			g_bNoCoreWarned[id] = true
		}
		return
	}
	if (!WfProgCoreReady(id))
	{
		// The core loads the player record 0.5 s after connect and retries; this
		// module waits for it rather than losing the day's bundle to a race.
		if (g_iLoginTries[id] < 8)
		{
			g_iLoginTries[id]++
			set_task(2.0, "Task_Login", id + TASK_LOGIN)
		}
		return
	}

	new auth[48], key[96]
	if (!WfProgAuth(id, auth, charsmax(auth)))
		return

	// Claim key = season + date + steamid, exactly as the brief asks. The core
	// adds its own season stamp and authid on top, so this can never collide
	// with another day, another player or another season.
	formatex(key, charsmax(key), "wfprog_login#%d#%d#%s", g_iSeasonYear, date, auth)
	new code = wf_grant(id, WF_REWARD_SNOWFLAKES, g_iLoginSnow, key)

	if (code == WF_GRANT_NOTLOADED)
	{
		if (g_iLoginTries[id] < 8)
		{
			g_iLoginTries[id]++
			set_task(2.0, "Task_Login", id + TASK_LOGIN)
		}
		return
	}

	// OK = paid now, DUPLICATE = already paid (a reconnect, a restart, a retry):
	// both record the date so the rest of the session takes the cheap path, and
	// only OK gets the one line.
	g_iMeta[id][META_LOGINDATE] = date
	g_bDirty[id] = true

	if (code == WF_GRANT_OK)
	{
		new day = date % 100
		WfProgNotice(id, "^4[WF]^1 daily Winterfest gift: ^3+%d %s^1 \d(day %d of %d - back tomorrow for more)",
			g_iLoginSnow, WF_CURRENCY_NAME, day, ADVENT_DAYS)
		log_amx("[WF-PROG] daily login paid for id %d (%d gb, date %d) code=%d",
			id, g_iLoginSnow, date, code)
	}
	else
	{
		log_amx("[WF-PROG] daily login already claimed for id %d (date %d) code=%d", id, date, code)
	}
}

public Task_Login(taskid)
{
	new id = taskid - TASK_LOGIN
	if (!g_bOpen || !WfProgHuman(id))
		return
	WfProgTryLogin(id, false)
}

// ============================================================
// The 2 s observation of the core's present inventory
// ============================================================
// This is the one thing this module has to poll, and it is worth being honest
// about why: winterfest_core exposes the present inventory only through pull
// natives (wf_gift_count / wf_gift_instance / wf_gift_rarity) and publishes no
// "a present was picked up / opened" forward. Rather than fork the core (another
// owner's file) or check per frame, this walks the (at most WF_MAX_GIFTS = 16)
// carried instances every 2 s for connected humans only. Everything else -
// kills, headshots, streaks, rounds, wins, the snowball report - is a real
// event. See docs/WINTERFEST-PROGRESS.md §6 for the forward the core could add
// to delete this tick entirely.
public Task_Tick()
{
	if (!g_bOpen)
		return
	for (new id = 1; id <= MaxClients; id++)
	{
		if (!g_bLoaded[id] || !WfProgHuman(id))
			continue
		if (!WfProgCoreReady(id))
			continue
		WfProgObserveGifts(id)
		WfProgEvaluate(id)
	}
}

stock WfProgObserveGifts(id)
{
	new carried = wf_gift_count(id)
	if (carried < 0)
		return

	new maxinst = 0
	new top[96]
	top[0] = 0
	for (new i = 0; i < carried; i++)
	{
		new inst = wf_gift_instance(id, i)
		if (inst <= 0)
			continue
		if (inst > maxinst)
			maxinst = inst
		if (wf_gift_rarity(id, inst) == g_iLegendaryRarity)
			WfListAdd(top, charsmax(top), inst)
	}

	// Presents collected = the highest instance id ever handed out, which the
	// core keeps per player and season. Monotonic by construction, so it needs no
	// bookkeeping of its own.
	new dnew = maxinst - g_iMeta[id][META_GIFTSEQ]
	if (dnew > 0)
	{
		g_iMeta[id][META_GIFTSEQ] = maxinst
		g_bDirty[id] = true
	}

	// Opens = (presents collected) - (presents now carried), both read in the
	// same tick. Collecting raises both and changes nothing; opening lowers the
	// second and counts one.
	new dcarry = carried - g_iMeta[id][META_CARRIED]
	new dopens = dnew - dcarry
	if (dopens > 0)
	{
		g_iMeta[id][META_OPENS] += dopens
		g_bDirty[id] = true
	}
	g_iMeta[id][META_CARRIED] = carried

	// A legendary instance that was in the bag at the previous look and is gone
	// now was opened (the only way a present leaves the bag). A pick-up-and-open
	// inside one 2 s window can be missed by this badge and by nothing else; the
	// `opens` metric above still counts it.
	new oldlen = WfListCount(g_szTopBag[id])
	new oldbuf[16], pos = 0
	for (new i = 0; i < oldlen; i++)
	{
		if (!WfProgNextCellComma(g_szTopBag[id], pos, oldbuf, charsmax(oldbuf)))
			break
		new inst = str_to_num(oldbuf)
		if (inst > 0 && !WfListHas(top, inst))
		{
			g_iMeta[id][META_LEGENDARY]++
			g_bDirty[id] = true
			log_amx("[WF-PROG] id %d opened a legendary present (instance %d)", id, inst)
		}
	}
	copy(g_szTopBag[id], charsmax(g_szTopBag[]), top)
}

// The 10 s read of the core's counters that have no event either: advent days,
// completed sets, tree level, pass tier. Cheap and bounded (24 days, WF_MAX_SETS
// sets, one native each), and it is what turns "you own 4 ornaments" into the
// "secret collection completed" badge.
public Task_Deep()
{
	if (!g_bOpen)
		return
	for (new id = 1; id <= MaxClients; id++)
	{
		if (!g_bLoaded[id] || !WfProgHuman(id))
			continue
		if (!WfProgCoreReady(id))
			continue
		WfProgEvaluate(id)
	}
}

// ============================================================
// Engine events
// ============================================================
// rsu_core's canonical combat forward: the same one freenova_missions and
// battlepass_core count kills from. If rsu_core is absent the DeathMsg hook
// below does the counting instead (decided per event, so load order between the
// two plugins cannot double-count).
public fn_on_player_kill(attacker, victim, wpnindex, headshot, tk)
{
	#pragma unused wpnindex
	if (!g_bOpen || tk)
		return
	if (!g_bLoaded[attacker] || !WfProgHuman(attacker))
		return
	// A suicide has no attacker; own-team kills are already filtered by rsu.
	if (attacker == victim)
		return
	WfProgCountKill(attacker, headshot)
}

// One place that turns a kill into progress, so the rsu forward and the
// DeathMsg fallback can never drift apart (or count the same kill twice: the
// fallback only runs when rsu_core is absent).
stock WfProgCountKill(attacker, headshot)
{
	g_iMeta[attacker][META_KILLS]++
	if (headshot)
		g_iMeta[attacker][META_HEADSHOTS]++
	g_iStreakRun[attacker]++
	if (g_iStreakRun[attacker] > g_iMeta[attacker][META_STREAK])
		g_iMeta[attacker][META_STREAK] = g_iStreakRun[attacker]
	g_bDirty[attacker] = true

	WfProgEvent(attacker, MTR_KILLS, 1)
	if (headshot)
		WfProgEvent(attacker, MTR_HEADSHOTS, 1)
	WfProgEvent(attacker, MTR_STREAK, g_iStreakRun[attacker])
	WfProgEvaluate(attacker)
}

public EventDeathMsg()
{
	if (!g_bOpen)
		return

	new victim = read_data(2)
	if (WfProgHuman(victim))
		g_iStreakRun[victim] = 0

	// Fallback kill counting when rsu_core is not on this box. The check is per
	// event, not per load, so plugin order cannot make both paths count.
	if (LibraryExists("rsu_core", LibType_Library))
		return

	new attacker = read_data(1)
	new headshot = read_data(3)
	if (!g_bLoaded[attacker] || !WfProgHuman(attacker) || attacker == victim)
		return
	WfProgCountKill(attacker, headshot)
}

// The rsu_core round-win forward. The fallback for a box without rsu_core is in
// EventRoundEnd (one team left standing = that team won).
public fn_on_round_win(id, team)
{
	#pragma unused team
	if (!g_bOpen || !g_bLoaded[id] || !WfProgHuman(id))
		return
	g_iMeta[id][META_WINS]++
	g_bDirty[id] = true
	WfProgEvent(id, MTR_WINS, 1)
	WfProgEvaluate(id)
}

public EventRoundStart()
{
	if (!g_bOpen)
		return
	new players[MAX_PLAYERS], num
	get_players(players, num, "ch")
	for (new i = 0; i < num; i++)
	{
		new id = players[i]
		if (!g_bLoaded[id])
			continue
		g_iMeta[id][META_ROUNDS]++
		g_bDirty[id] = true
		WfProgEvent(id, MTR_ROUNDS, 1)
		WfProgEvent(id, MTR_MAP_ROUNDS, 1)
		WfProgEvaluate(id)
	}
}

// Only used when rsu_core is absent: at round end, a team with living players
// and no living opponent won the round. Anything ambiguous (a draw, an
// elimination by the bomb) counts for nobody rather than for the wrong team.
public EventRoundEnd()
{
	if (!g_bOpen || LibraryExists("rsu_core", LibType_Library))
		return

	new players[MAX_PLAYERS], num
	get_players(players, num, "ach")
	if (!num)
		return

	new t = 0, ct = 0
	for (new i = 0; i < num; i++)
	{
		new id = players[i]
		new team = get_user_team(id)
		if (team == 1)
			t++
		else if (team == 2)
			ct++
	}

	new winner_team = 0
	if (t > 0 && ct == 0) winner_team = 1
	else if (ct > 0 && t == 0) winner_team = 2
	if (!winner_team)
		return

	for (new i = 0; i < num; i++)
	{
		new id = players[i]
		if (get_user_team(id) != winner_team)
			continue
		if (!g_bLoaded[id] || !WfProgHuman(id))
			continue
		g_iMeta[id][META_WINS]++
		g_bDirty[id] = true
		WfProgEvent(id, MTR_WINS, 1)
		WfProgEvaluate(id)
	}
}

// ============================================================
// Natives: the cross-module channel
// ============================================================
// wfprog_report(id, "snowball_hs", 1) - how a gameplay module reports a metric
// only it can see. Event metrics only: presents/opens/advent/sets/tree are read
// from the core, so letting a plugin add to them would double-count.
public native_report(plugin, params)
{
	#pragma unused plugin, params
	new id = get_param(1)
	new metric[24]
	get_string(2, metric, charsmax(metric))
	new amount = get_param(3)
	return WfProgReport(id, metric, amount)
}

public native_season_open(plugin, params)
{
	#pragma unused plugin, params
	return g_bOpen ? 1 : 0
}

stock WfProgReport(id, const metricname[], amount)
{
	if (!g_bOpen || amount <= 0)
		return 0
	if (!g_bLoaded[id] || !WfProgHuman(id))
		return 0

	new metric = WfProgMetricFromName(metricname)
	if (metric == MTR_NONE)
		return 0
	new cls = WfProgClass(metric)
	if (cls == MC_COUNTER || cls == MC_LEVEL)
		return 0

	if (metric == MTR_SNOWBALL_HS)
	{
		g_iMeta[id][META_SNOWBALL] += amount
		g_bDirty[id] = true
	}

	WfProgEvent(id, metric, amount)
	WfProgEvaluate(id)
	return 1
}

// ============================================================
// Player-facing: /christmasmissions
// ============================================================
public cmdMissions(id)
{
	// Outside the window: silence. Not even "it is closed" - the command does not
	// exist as far as a player can tell (see progress.ini's header).
	if (!g_bOpen)
		return PLUGIN_HANDLED
	if (!WfProgHuman(id))
		return PLUGIN_HANDLED
	if (!g_bLoaded[id])
	{
		WfSay(id, "your Winterfest record is still loading - one moment.")
		return PLUGIN_HANDLED
	}

	// Refresh what can only be read from the core before drawing, so the menu is
	// not a stale copy of the tick's last look.
	WfProgEvaluate(id)
	g_iCtrPage[id] = 0
	ShowContracts(id)
	return PLUGIN_HANDLED
}

stock WfProgPaidCount(id)
{
	new n = 0
	for (new c = 0; c < g_iCtrCount; c++)
		if (g_bCtrPaid[c][id])
			n++
	return n
}

stock WfProgDoneCount(id, group)
{
	new n = 0
	for (new c = 0; c < g_iCtrCount; c++)
		if (g_iCtrGroup[c] == group && g_bCtrPaid[c][id])
			n++
	return n
}

stock ShowContracts(id)
{
	new title[96]
	formatex(title, charsmax(title), "\y%s \r| \wChristmas missions \d%d/%d \d(d%d w%d s%d)",
		g_szSeasonName, WfProgPaidCount(id), g_iCtrCount,
		WfProgDoneCount(id, GRP_DAILY), WfProgDoneCount(id, GRP_WEEKLY), WfProgDoneCount(id, GRP_SEASON))
	new menu = menu_create(title, "ContractsHandler")

	new start = g_iCtrPage[id] * MAX_PAGE
	new shown = 0
	new row[128], label[72], data[12]
	for (new c = start; c < g_iCtrCount && shown < MAX_PAGE; c++, shown++)
	{
		WfProgEnsurePeriod(c, id)
		WfProgLabel(g_iCtrMetric[c], g_iCtrTarget[c][id], g_szCtrMap[c], label, charsmax(label))
		new group[8]
		WfProgGroupName(g_iCtrGroup[c], group, charsmax(group))
		if (g_bCtrPaid[c][id])
			formatex(row, charsmax(row), "\d%s \d- %s (claimed)", label, group)
		else
			formatex(row, charsmax(row), "\w%s \d- %s \r%d/%d \d+%d %s",
				label, group, g_iCtrProg[c][id], g_iCtrTarget[c][id], g_iCtrSnow[c][id], WF_CURRENCY_NAME)
		formatex(data, charsmax(data), "c%d", c)
		menu_additem(menu, row, data)
	}

	if (start + shown < g_iCtrCount)
		menu_additem(menu, "\wNext page \d- more contracts", "n")
	formatex(row, charsmax(row), "\wSeasonal badges \d- %d of %d unlocked",
		WfListCount(g_szBadges[id]), g_iAchCount)
	menu_additem(menu, row, "a")

	FN_MenuFinish(menu)
	menu_display(id, menu)
}

public ContractsHandler(id, menu, item)
{
	menu_destroy(menu)
	if (!g_bOpen || !WfProgHuman(id) || item < 0)
		return PLUGIN_HANDLED
	if (!g_bLoaded[id])
		return PLUGIN_HANDLED

	new info[16], access, callback, name[1]
	menu_item_getinfo(menu, item, access, info, charsmax(info), name, 0, callback)

	if (equal(info, "n"))
	{
		g_iCtrPage[id] = (g_iCtrPage[id] + 1) * MAX_PAGE < g_iCtrCount ? g_iCtrPage[id] + 1 : 0
		ShowContracts(id)
		return PLUGIN_HANDLED
	}
	if (equal(info, "a"))
	{
		g_iAchPage[id] = 0
		ShowAchievements(id)
		return PLUGIN_HANDLED
	}
	if (info[0] == 'c')
	{
		new c = str_to_num(info[1])
		if (c < 0 || c >= g_iCtrCount)
			return PLUGIN_HANDLED
		WfProgEnsurePeriod(c, id)
		new label[72], done[72], group[8]
		WfProgLabel(g_iCtrMetric[c], g_iCtrTarget[c][id], g_szCtrMap[c], label, charsmax(label))
		WfProgGroupName(g_iCtrGroup[c], group, charsmax(group))
		if (g_bCtrPaid[c][id])
			formatex(done, charsmax(done), "already claimed this %s - it comes back next period",
				group)
		else if (g_iCtrProg[c][id] >= g_iCtrTarget[c][id])
			formatex(done, charsmax(done), "complete - the reward pays automatically (%d %s, %d pass XP)",
				g_iCtrSnow[c][id], WF_CURRENCY_NAME, g_iCtrXp[c][id])
		else
			formatex(done, charsmax(done), "%d of %d done - pays %d %s and %d pass XP",
				g_iCtrProg[c][id], g_iCtrTarget[c][id], g_iCtrSnow[c][id], WF_CURRENCY_NAME, g_iCtrXp[c][id])
		// One chat line per tap: the menu already shows the same numbers, this is
		// the "what do I actually have to do" answer.
		client_print_color(id, print_team_default, "^4[WF]^1 %s \d- %s", label, done)
		ShowContracts(id)
	}
	return PLUGIN_HANDLED
}

stock ShowAchievements(id)
{
	new unlocked = WfListCount(g_szBadges[id])
	new title[96]
	formatex(title, charsmax(title), "\ySeasonal badges \r| \w%d of %d", unlocked, g_iAchCount)
	new menu = menu_create(title, "AchievementsHandler")

	new start = g_iAchPage[id] * (MAX_PAGE + 1)
	new shown = 0
	new row[128], data[12]
	for (new a = start; a < g_iAchCount && shown < MAX_PAGE + 1; a++, shown++)
	{
		if (WfProgHasBadge(id, a + 1))
			formatex(row, charsmax(row), "\y%s \d- badge: %s", g_szAchName[a], g_szAchBadge[a])
		else
		{
			new cur = WfProgAchValue(id, g_iAchMetric[a])
			if (cur < 0)
				cur = 0
			formatex(row, charsmax(row), "\w%s \d- %d/%d \d+%d %s",
				g_szAchName[a], min(cur, g_iAchTarget[a]), g_iAchTarget[a], g_iAchSnow[a], WF_CURRENCY_NAME)
		}
		formatex(data, charsmax(data), "b%d", a)
		menu_additem(menu, row, data)
	}

	if (start + shown < g_iAchCount)
		menu_additem(menu, "\wNext page \d- more badges", "n")

	FN_MenuFinish(menu)
	menu_display(id, menu)
}

public AchievementsHandler(id, menu, item)
{
	menu_destroy(menu)
	if (!g_bOpen || !WfProgHuman(id) || item < 0)
		return PLUGIN_HANDLED

	new info[16], access, callback, name[1]
	menu_item_getinfo(menu, item, access, info, charsmax(info), name, 0, callback)

	if (equal(info, "n"))
	{
		g_iAchPage[id] = (g_iAchPage[id] + 1) * (MAX_PAGE + 1) < g_iAchCount ? g_iAchPage[id] + 1 : 0
		ShowAchievements(id)
		return PLUGIN_HANDLED
	}
	ShowContracts(id)
	return PLUGIN_HANDLED
}

// ============================================================
// Player-facing: /christmasrank
// ============================================================
// The complete seasonal board is the panel's (another workstream owns that page
// and the data behind it). This prints what the server can know for free: the
// humans online right now, ranked by claimed contracts and presents. No HTTP
// from a game thread - a synchronous request here is a lag spike for everyone on
// the server, so the panel pointer is the honest answer for the full board.
public cmdRank(id)
{
	if (!g_bOpen)
		return PLUGIN_HANDLED
	if (!WfProgHuman(id))
		return PLUGIN_HANDLED

	new players[MAX_PLAYERS], num
	get_players(players, num, "ch")

	new ids[MAX_PLAYERS], scores[MAX_PLAYERS], n = 0
	for (new i = 0; i < num; i++)
	{
		new p = players[i]
		if (!g_bLoaded[p])
			continue
		ids[n] = p
		// Claimed contracts first, presents as the tie-break, the same ordering
		// the panel's seasonal board uses (contracts > presents > currency).
		scores[n] = WfProgPaidCount(p) * 10000 + min(g_iMeta[p][META_GIFTSEQ], 9999)
		n++
	}

	// Selection sort, top 5, bounded by MaxClients: no sorting library, no
	// allocation, and "top 5 of 32" is 160 comparisons at most.
	new topn = min(n, 5)
	for (new i = 0; i < topn; i++)
	{
		new best = i
		for (new j = i + 1; j < n; j++)
			if (scores[j] > scores[best])
				best = j
		if (best != i)
		{
			new tp = ids[i]; ids[i] = ids[best]; ids[best] = tp
			new ts = scores[i]; scores[i] = scores[best]; scores[best] = ts
		}
	}

	client_print_color(id, print_team_default, "^4[WF]^1 %s \r| \wseason top 5 (online right now)",
		g_szSeasonName)
	if (!n)
	{
		WfSay(id, "nobody online has started a seasonal contract yet - be the first.")
	}
	else
	{
		new pname[MAX_NAME_LENGTH]
		for (new i = 0; i < topn; i++)
		{
			get_user_name(ids[i], pname, charsmax(pname))
			client_print_color(id, print_team_default,
				"^4%d.^1 %s \d- %d contracts, %d presents",
				i + 1, pname, WfProgPaidCount(ids[i]), g_iMeta[ids[i]][META_GIFTSEQ])
		}
	}
	WfSay(id, "full-season board: the panel (/winter) - it is the only complete source.")
	return PLUGIN_HANDLED
}

// ============================================================
// Operator commands
// ============================================================
stock WfProgTargets(const arg[], players[], &count, max)
{
	count = 0
	if (equal(arg, "all") || equal(arg, "*"))
	{
		for (new i = 1; i <= MaxClients && count < max; i++)
			if (WfProgHuman(i))
				players[count++] = i
		return
	}
	if (arg[0] == '#' && arg[1])
	{
		new uid = str_to_num(arg[1])
		for (new i = 1; i <= MaxClients; i++)
			if (is_user_connected(i) && get_user_userid(i) == uid)
			{
				players[count++] = i
				return
			}
		return
	}
	new name[MAX_NAME_LENGTH], auth[48]
	for (new i = 1; i <= MaxClients; i++)
	{
		if (!is_user_connected(i))
			continue
		get_user_name(i, name, charsmax(name))
		get_user_authid(i, auth, charsmax(auth))
		if (containi(name, arg) >= 0 || (auth[0] && containi(auth, arg) >= 0))
		{
			players[count++] = i
			return
		}
	}
}

public cmdState(id, level, cid)
{
	if (!cmd_access(id, level, cid, 2))
		return PLUGIN_HANDLED

	new arg[40]
	read_argv(1, arg, charsmax(arg))
	new targets[MAX_PLAYERS], count
	WfProgTargets(arg, targets, count, MAX_PLAYERS)
	if (!count)
	{
		console_print(id, "[WF-PROG] no client matched '%s'", arg)
		return PLUGIN_HANDLED
	}

	console_print(id, "[WF-PROG] season '%s' year %d window %d-%d..%d-%d open=%s vault=%s core=%s legendary_rarity=%d",
		g_szSeasonName, g_iSeasonYear, g_iStartDate, g_iStartMin, g_iEndDate, g_iEndMin,
		g_bOpen ? "yes" : "no",
		(g_Vault != INVALID_HANDLE) ? "ok" : "FAILED",
		WfProgCore() ? "yes" : "MISSING",
		g_iLegendaryRarity)

	for (new t = 0; t < count; t++)
	{
		new p = targets[t]
		new pname[MAX_NAME_LENGTH]
		get_user_name(p, pname, charsmax(pname))
		console_print(id, "[WF-PROG] %s (%d) loaded=%s core_ready=%s badges=%d meta[giftseq=%d carried=%d opens=%d legendary=%d snowball=%d streak=%d rounds=%d wins=%d kills=%d hs=%d login=%d]",
			pname, p, g_bLoaded[p] ? "yes" : "no", WfProgCoreReady(p) ? "yes" : "no",
			WfListCount(g_szBadges[p]),
			g_iMeta[p][META_GIFTSEQ], g_iMeta[p][META_CARRIED], g_iMeta[p][META_OPENS],
			g_iMeta[p][META_LEGENDARY], g_iMeta[p][META_SNOWBALL], g_iMeta[p][META_STREAK],
			g_iMeta[p][META_ROUNDS], g_iMeta[p][META_WINS], g_iMeta[p][META_KILLS],
			g_iMeta[p][META_HEADSHOTS], g_iMeta[p][META_LOGINDATE])
		if (!g_bLoaded[p])
			continue
		for (new c = 0; c < g_iCtrCount; c++)
		{
			console_print(id, "[WF-PROG]   %s %s %d/%d %s",
				g_szCtrKey[c], g_szCtrPeriod[c][p], g_iCtrProg[c][p], g_iCtrTarget[c][p],
				g_bCtrPaid[c][p] ? "paid" : "open")
		}
	}
	return PLUGIN_HANDLED
}

public cmdSave(id, level, cid)
{
	if (!cmd_access(id, level, cid, 1))
		return PLUGIN_HANDLED
	for (new p = 1; p <= MaxClients; p++)
	{
		if (!g_bLoaded[p])
			continue
		WfProgSave(p)
	}
	console_print(id, "[WF-PROG] dirty records flushed")
	log_amx("[WF-PROG] admin %d flushed the seasonal records", id)
	return PLUGIN_HANDLED
}

public cmdReload(id, level, cid)
{
	if (!cmd_access(id, level, cid, 2))
		return PLUGIN_HANDLED

	new arg[40]
	read_argv(1, arg, charsmax(arg))
	new targets[MAX_PLAYERS], count
	WfProgTargets(arg, targets, count, MAX_PLAYERS)
	if (!count)
	{
		console_print(id, "[WF-PROG] no client matched '%s'", arg)
		return PLUGIN_HANDLED
	}

	for (new t = 0; t < count; t++)
	{
		new p = targets[t]
		new auth[48]
		if (!WfProgAuth(p, auth, charsmax(auth)))
			continue
		// Drop the in-memory copy and read the vault back: this is exactly what a
		// reconnect does, so it is the honest way to test persistence.
		WfProgResetClient(p)
		WfProgLoad(p, auth)
		new pname[MAX_NAME_LENGTH]
		get_user_name(p, pname, charsmax(pname))
		console_print(id, "[WF-PROG] re-read %s (%d): %d contract(s) paid, %d badge(s)",
			pname, p, WfProgPaidCount(p), WfListCount(g_szBadges[p]))
		log_amx("[WF-PROG] admin %d re-read the seasonal record of %s (%d)", id, pname, p)
	}
	return PLUGIN_HANDLED
}

public cmdLogin(id, level, cid)
{
	if (!cmd_access(id, level, cid, 2))
		return PLUGIN_HANDLED

	new arg[40], flag[16]
	read_argv(1, arg, charsmax(arg))
	read_argv(2, flag, charsmax(flag))
	// "force" asks the core again even when the record already says today was
	// paid. Without it the command is a no-op on a day that has been paid, which
	// is what an operator retrying after a vault hiccup wants.
	new bool:force = equal(flag, "force") ? true : false

	new targets[MAX_PLAYERS], count
	WfProgTargets(arg, targets, count, MAX_PLAYERS)
	if (!count)
	{
		console_print(id, "[WF-PROG] no client matched '%s'", arg)
		return PLUGIN_HANDLED
	}
	for (new t = 0; t < count; t++)
	{
		new p = targets[t]
		if (!g_bLoaded[p])
			console_print(id, "[WF-PROG] id %d: record not loaded yet - the check was queued", p)
		WfProgTryLogin(p, force)
		console_print(id, "[WF-PROG] login check for %d done (recorded date %d, force=%d)",
			p, g_iMeta[p][META_LOGINDATE], _:force)
	}
	log_amx("[WF-PROG] admin %d ran the daily-login check for '%s' (force=%d)", id, arg, _:force)
	return PLUGIN_HANDLED
}

public cmdReport(id, level, cid)
{
	if (!cmd_access(id, level, cid, 3))
		return PLUGIN_HANDLED

	new arg[40], metric[24], nbuf[16]
	read_argv(1, arg, charsmax(arg))
	read_argv(2, metric, charsmax(metric))
	read_argv(3, nbuf, charsmax(nbuf))
	new amount = str_to_num(nbuf)
	if (amount <= 0)
		amount = 1

	new targets[MAX_PLAYERS], count
	WfProgTargets(arg, targets, count, MAX_PLAYERS)
	if (!count)
	{
		console_print(id, "[WF-PROG] no client matched '%s'", arg)
		return PLUGIN_HANDLED
	}
	for (new t = 0; t < count; t++)
	{
		new p = targets[t]
		new applied = WfProgReport(p, metric, amount)
		console_print(id, "[WF-PROG] report %s %d for id %d => applied %d", metric, amount, p, applied)
	}
	log_amx("[WF-PROG] admin %d reported metric '%s' x%d to '%s'", id, metric, amount, arg)
	return PLUGIN_HANDLED
}

public cmdReset(id, level, cid)
{
	if (!cmd_access(id, level, cid, 3))
		return PLUGIN_HANDLED

	new arg[40], what[16]
	read_argv(1, arg, charsmax(arg))
	read_argv(2, what, charsmax(what))

	new targets[MAX_PLAYERS], count
	WfProgTargets(arg, targets, count, MAX_PLAYERS)
	if (!count)
	{
		console_print(id, "[WF-PROG] no client matched '%s'", arg)
		return PLUGIN_HANDLED
	}

	// The keys are season-stamped, so "season" cannot touch last year. The claim
	// keys live in the core's ledger and are NOT undone here: an operator who
	// wants a player to earn the reward again must run the core's wf_reset too,
	// which is exactly the behaviour that stops this command being a dupe bug.
	for (new t = 0; t < count; t++)
	{
		new p = targets[t]
		new auth[48]
		if (!WfProgAuth(p, auth, charsmax(auth)))
			continue
		new key[MAX_KEY], pname[MAX_NAME_LENGTH]
		get_user_name(p, pname, charsmax(pname))

		if (equal(what, "badges") || equal(what, "all"))
		{
			formatex(key, charsmax(key), "wfprog_badge#%s", auth)
			if (strlen(key) < MAX_KEY && g_Vault != INVALID_HANDLE)
				nvault_remove(g_Vault, key)
			g_szBadges[p][0] = 0
		}
		if (equal(what, "season") || equal(what, "all"))
		{
			if (g_Vault != INVALID_HANDLE)
			{
				for (new c = 0; c < g_iCtrCount; c++)
				{
					if (!WfProgKey(auth, g_szCtrKey[c], key, charsmax(key)))
						continue
					nvault_remove(g_Vault, key)
				}
				formatex(key, charsmax(key), "wfprog_s%d#%s#meta", g_iSeasonYear, auth)
				if (strlen(key) < MAX_KEY)
					nvault_remove(g_Vault, key)
			}
			WfProgResetClient(p)
			WfProgLoad(p, auth)
		}
		console_print(id, "[WF-PROG] reset '%s' for %s (%d)", what, pname, p)
		log_amx("[WF-PROG] admin %d reset seasonal '%s' for %s (%d)", id, what, pname, p)
	}
	return PLUGIN_HANDLED
}

// ============================================================
// Misc helpers
// ============================================================
// A comma separated cell, for the legendary-instance list.
stock bool:WfProgNextCellComma(const line[], &pos, out[], len)
{
	new n = strlen(line), c = 0
	out[0] = 0
	while (pos < n && line[pos] == ',')
		pos++
	if (pos >= n)
		return false
	while (pos < n && line[pos] != ',')
	{
		if (c < len - 1)
			out[c++] = line[pos]
		pos++
	}
	out[c] = 0
	if (pos < n)
		pos++   // step over the separator
	return (c > 0) ? true : false
}
