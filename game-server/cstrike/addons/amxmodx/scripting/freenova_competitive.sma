#include <amxmodx>
#include <cstrike>
#include <csx>
#include <sqlx>
#include <freenova_ui>
#include <freenova_web>
#include <menabp>
#include <freenova_cosmetics>
#include <rsu>
#include <fn_common>

#pragma dynamic 16384

// ============================================================
// FreeNova Competitive (v1.0)
// Owns Top15 Points (competitive currency, separate from XP, Coins and
// BattlePass XP), competitive missions and server competitions.
//
// Ownership (data integrity first):
//   XP/levels      = CRX (crx_ranksystem)      - untouched
//   Coins/BP       = battlepass_core (menabp)  - untouched
//   VIP tiers      = freenova_vip              - untouched
//   Kills/HS/etc   = freenova_panel (fnstats)  - untouched
//   Top15 Points   = THIS PLUGIN (SQLite)      - new authority
//
// Identity: SteamID; PENDING/LAN pooled into "PENDING" like the other
// FreeNova plugins so unrelated clients never share a row. All SQL async;
// player-bound callbacks re-validate the cached SteamID per slot.
//
// Season awareness: mirrors freenova_season's month key ("YYYY-MM").
// Season rows reset with the month; the career lifetime total lives in its
// own table and survives seasons (same policy as freenova_season).
//
// Scoring rules (all gated on fnc_enabled + fnc_min_players humans):
//   kill = fnc_kill_points, headshot kill += fnc_headshot_bonus,
//   plant = fnc_plant_points, defuse = fnc_defuse_points,
//   round win (survivors of the winning team) = fnc_round_win_points,
//   MVP = fnc_mvp_points (defuser on defuse win, planter on bomb-explosion
//   win, else the winning team's top round-damage survivor),
//   teamkill = fnc_teamkill_penalty (floored at 0 total).
// Bots/HLTV never earn or cost points; kills involving bots score nothing.
//
// Daily missions (identical for everyone, auto-claimed, reset at midnight):
//   RIFLEMAN 25 kills, SHARPSHOOTER 20 headshots, WINNER 10 round wins,
//   MVP 3 MVP awards.
//
// Storage: SQLite (data/freenova.sq3) - leaderboards need ORDER BY LIMIT,
// which nVault cannot provide. Load-failed players are never saved from
// cache, so a backend outage can never wipe an existing row.
//
// Chat commands (collision-checked against top15_styled/battlepass/hub):
//   /pts        - personal points + season rank + mission progress
//   /ctop       - season Top15 by points
//   /cmissions  - daily competitive missions detail
// ============================================================

#define PLUGIN  "FreeNova Competitive"
#define VERSION "1.0"
#define AUTHOR  "FreeNova"

#define TASK_AUTOSAVE 43100
#define AUTOSAVE_INTERVAL 60.0

// ---------------------------------------------------------------- cvars

new g_pEnabled
new g_pMinPlayers
new g_pKillPts
new g_pHsPts
new g_pMvpPts
new g_pWinPts
new g_pPlantPts
new g_pDefusePts
new g_pTkPenalty
new g_pDebug

// ---------------------------------------------------------------- state

new g_szSeason[8]
new Handle:g_SqlTuple
new bool:g_bSqlReady
new g_iMaxSlots

// per-slot player cache (points cached in RAM, flushed by autosave)
new bool:g_bLoaded[33]
new g_iPoints[33]
new g_iLifetime[33]
new g_iKills[33]
new g_iHeadshots[33]
new g_iWins[33]
new g_iMvp[33]
new g_szAuth[33][40]

// Season leaderboard cache: every known (auth, points, kills) row, kept live
// by Award()/loads and refreshed from SQLite. Bounded (1024); overflow logs
// and ignores. Claims read rank synchronously from here - never SQL in line.
#define COMP_CACHE_MAX 1024
new g_CacheAuth[COMP_CACHE_MAX][40]
new g_CachePoints[COMP_CACHE_MAX]
new g_CacheKills[COMP_CACHE_MAX]
new g_CacheN
new bool:g_bCacheReady

// per-round trackers for MVP resolution
new g_iRoundDamage[33]
new g_iPlanter
new g_iDefuser
new bool:g_bBombExploded

// ---------------------------------------------------------------- missions

// daily set, identical for everyone (fair distribution), auto-claim
enum _:MISSIONS
{
    MSN_KILLS = 0,
    MSN_HS,
    MSN_WINS,
    MSN_MVP,
    MSN_COUNT
}

new const g_szMissionName[MSN_COUNT][] = {
    "RIFLEMAN",
    "SHARPSHOOTER",
    "WINNER",
    "MVP"
}

new const g_iMissionTarget[MSN_COUNT] = { 25, 20, 10, 3 }
new const g_iMissionPoints[MSN_COUNT] = { 120, 130, 100, 150 }

new g_iMissionProgress[33][MSN_COUNT]
new bool:g_bMissionDone[33][MSN_COUNT]
new g_iMissionDay[33]
new bool:g_bSeasonClaimed[33]

public plugin_init()
{
    fn_boot_banner("competitive", 37)

    register_plugin(PLUGIN, VERSION, AUTHOR)

    g_pEnabled    = register_cvar("fnc_enabled", "1")
    g_pMinPlayers = register_cvar("fnc_min_players", "2")
    g_pKillPts    = register_cvar("fnc_kill_points", "10")
    g_pHsPts      = register_cvar("fnc_headshot_bonus", "5")
    g_pMvpPts     = register_cvar("fnc_mvp_points", "25")
    g_pWinPts     = register_cvar("fnc_round_win_points", "20")
    g_pPlantPts   = register_cvar("fnc_plant_points", "10")
    g_pDefusePts  = register_cvar("fnc_defuse_points", "15")
    g_pTkPenalty  = register_cvar("fnc_teamkill_penalty", "-15")
    g_pDebug      = register_cvar("fnc_debug", "0")

    register_clcmd("say /pts", "Cmd_MyPoints")
    register_clcmd("say_team /pts", "Cmd_MyPoints")
    register_clcmd("say /competitive", "Cmd_CompetitiveMenu")
    register_clcmd("say_team /competitive", "Cmd_CompetitiveMenu")
    register_clcmd("say /comp", "Cmd_CompetitiveMenu")
    register_clcmd("say_team /comp", "Cmd_CompetitiveMenu")
    register_clcmd("say /ctop", "Cmd_Top15")
    register_clcmd("say_team /ctop", "Cmd_Top15")
    register_clcmd("say /tournament", "Cmd_Top15")
    register_clcmd("say_team /tournament", "Cmd_Top15")
    register_clcmd("say /cmissions", "Cmd_Missions")
    register_clcmd("say_team /cmissions", "Cmd_Missions")
    register_clcmd("say /cclaim", "Cmd_Claim")
    register_clcmd("say_team /cclaim", "Cmd_Claim")

    // one hook per verdict - a single register_event with both conditions
    // ANDed could never fire (a SendAudio is terwin OR ctwin, never both)
    register_event("SendAudio", "Event_TWin", "a", "2&%!MRAD_terwin")
    register_event("SendAudio", "Event_CtWin", "a", "2&%!MRAD_ctwin")
    register_logevent("Event_RoundStart", 2, "1=Round_Start")

    set_task(AUTOSAVE_INTERVAL, "Task_AutoSave", TASK_AUTOSAVE, _, _, "b")
}

public plugin_cfg()
{
    g_iMaxSlots = get_maxplayers()
    LoadSeason()
    SqlInit()
    CacheRefresh()
}

public plugin_end()
{
    remove_task(TASK_AUTOSAVE)
    SaveAll()
    // tuple handle is intentionally not freed: pending threaded saves from
    // SaveAll() must survive this callback, and AMXX reclaims plugin-owned
    // handles at unload anyway
}

// ---------------------------------------------------------------- helpers

LoadSeason()
{
    // mirrors freenova_season's "YYYY-MM" month key
    format_time(g_szSeason, charsmax(g_szSeason), "%Y-%m")
}

GetToday()
{
    new szTime[12]
    format_time(szTime, charsmax(szTime), "%Y%m%d")
    return str_to_num(szTime)
}

bool:PointsActive()
{
    if (!get_pcvar_num(g_pEnabled))
        return false

    if (get_cvar_num("amx_knife_round_active") == 1)
        return false

    new iMin = get_pcvar_num(g_pMinPlayers)
    if (iMin > 0 && HumanCount() < iMin)
        return false

    return true
}

HumanCount()
{
    new iPlayers[MAX_PLAYERS], iNum
    get_players(iPlayers, iNum, "ch")   // connected, skip bots + HLTV
    return iNum
}

DebugLog(const szFmt[], any:...)
{
    if (!get_pcvar_num(g_pDebug))
        return

    new szMsg[192]
    vformat(szMsg, charsmax(szMsg), szFmt, 2)
    log_amx("[DBG] %s", szMsg)
}

// Never pass Empty_Handle to SQL_QuoteString â€” that is native error 10 on sqlite.
EscapeSql(szOut[], iMax, const szIn[])
{
    copy(szOut, iMax, szIn)
    replace_all(szOut, iMax, "'", "''")
}

// ---------------------------------------------------------------- sql init

SqlInit()
{
    // sql.cfg defaults to mysql; this database is local SQLite
    if (!SQL_SetAffinity("sqlite"))
    {
        log_amx("[FreeNova Competitive] sqlite affinity unavailable - plugin disabled")
        return
    }

    g_SqlTuple = SQL_MakeDbTuple("localhost", "", "", "freenova")

    SQL_ThreadQuery(g_SqlTuple, "HandleCreateTables",
        "CREATE TABLE IF NOT EXISTS fn_comp_season ( \
            auth      TEXT    NOT NULL, \
            season    TEXT    NOT NULL, \
            points    INTEGER NOT NULL DEFAULT 0, \
            kills     INTEGER NOT NULL DEFAULT 0, \
            headshots INTEGER NOT NULL DEFAULT 0, \
            wins      INTEGER NOT NULL DEFAULT 0, \
            mvp       INTEGER NOT NULL DEFAULT 0, \
            name      TEXT    NOT NULL DEFAULT '', \
            msn_day   INTEGER NOT NULL DEFAULT 0, \
            msn_k     INTEGER NOT NULL DEFAULT 0, \
            msn_h     INTEGER NOT NULL DEFAULT 0, \
            msn_w     INTEGER NOT NULL DEFAULT 0, \
            msn_m     INTEGER NOT NULL DEFAULT 0, \
            msn_done  INTEGER NOT NULL DEFAULT 0, \
            last_seen INTEGER NOT NULL DEFAULT 0, \
            PRIMARY KEY (auth, season)); \
         CREATE TABLE IF NOT EXISTS fn_comp_career ( \
            auth      TEXT    NOT NULL, \
            lifetime  INTEGER NOT NULL DEFAULT 0, \
            name      TEXT    NOT NULL DEFAULT '', \
            last_seen INTEGER NOT NULL DEFAULT 0, \
            PRIMARY KEY (auth)); \
         CREATE TABLE IF NOT EXISTS fn_comp_claims ( \
            auth       TEXT    NOT NULL, \
            season     TEXT    NOT NULL, \
            coins      INTEGER NOT NULL DEFAULT 0, \
            claimed_at INTEGER NOT NULL DEFAULT 0, \
            PRIMARY KEY (auth, season))")
}

public HandleCreateTables(failstate, Handle:query, error[], errnum, data[], size)
{
    if (failstate != TQUERY_SUCCESS)
    {
        log_amx("[FreeNova Competitive] table init failed (%d): %s", errnum, error)
        return
    }

    g_bSqlReady = true
    DebugLog("tables ready, season %s", g_szSeason)

    // players who connected before the backend answered load now
    for (new id = 1; id <= g_iMaxSlots; id++)
        if (g_szAuth[id][0] && !g_bLoaded[id])
            LoadPlayer(id)
}

// ---------------------------------------------------------------- lifecycle

TryAuthorize(id)
{
    if (is_user_bot(id) || is_user_hltv(id))
        return

    new szAuth[40]
    get_user_authid(id, szAuth, charsmax(szAuth))

    // Unauthenticated clients must NEVER share a row. Defer the load
    // until Steam hands a real SteamID.
    if (equal(szAuth, "STEAM_ID_PENDING") || equal(szAuth, "STEAM_ID_LAN")
        || equal(szAuth, "VALVE_ID_PENDING") || equal(szAuth, "VALVE_ID_LAN")
        || !szAuth[0])
    {
        g_szAuth[id][0] = 0
        return
    }

    copy(g_szAuth[id], charsmax(g_szAuth[]), szAuth)
    LoadPlayer(id)
}

public client_authorized(id)
{
    TryAuthorize(id)
}

public client_putinserver(id)
{
    // slot reuse must never inherit the previous occupant's state
    g_bLoaded[id] = false
    g_szAuth[id][0] = 0
    g_iPoints[id] = 0
    g_iLifetime[id] = 0
    g_iKills[id] = 0
    g_iHeadshots[id] = 0
    g_iWins[id] = 0
    g_iMvp[id] = 0
    g_iRoundDamage[id] = 0
    arrayset(g_iMissionProgress[id], 0, MSN_COUNT)
    arrayset(g_bMissionDone[id], 0, MSN_COUNT)
    g_iMissionDay[id] = 0
    g_bSeasonClaimed[id] = false

    if (!is_user_bot(id) && !is_user_hltv(id) && !g_szAuth[id][0])
        TryAuthorize(id)
}

public client_disconnected(id)
{
    if (g_bLoaded[id])
        SavePlayer(id)

    g_bLoaded[id] = false
    g_szAuth[id][0] = 0
}

// ---------------------------------------------------------------- load

LoadPlayer(id)
{
    if (!g_bSqlReady || !g_szAuth[id][0])
        return

    new szAuthQ[96], szSeasonQ[16]
    copy(szAuthQ, charsmax(szAuthQ), g_szAuth[id])
    copy(szSeasonQ, charsmax(szSeasonQ), g_szSeason)
    replace_all(szAuthQ, charsmax(szAuthQ), "'", "''")
    replace_all(szSeasonQ, charsmax(szSeasonQ), "'", "''")

    new szQuery[768], szData[64]
    formatex(szQuery, charsmax(szQuery),
        "SELECT s.points, s.kills, s.headshots, s.wins, s.mvp, \
            s.msn_day, s.msn_k, s.msn_h, s.msn_w, s.msn_m, s.msn_done, c.lifetime, cl.coins \
         FROM fn_comp_season s LEFT JOIN fn_comp_career c ON c.auth = s.auth \
         LEFT JOIN fn_comp_claims cl ON cl.auth = s.auth AND cl.season = s.season \
         WHERE s.auth = '%s' AND s.season = '%s'", szAuthQ, szSeasonQ)
    formatex(szData, charsmax(szData), "%d %s", id, g_szAuth[id])

    SQL_ThreadQuery(g_SqlTuple, "HandleLoadPlayer", szQuery, szData, strlen(szData))
}

public HandleLoadPlayer(failstate, Handle:query, error[], errnum, data[], size)
{
    if (failstate != TQUERY_SUCCESS)
    {
        log_amx("[FreeNova Competitive] load failed (%d): %s", errnum, error)
        return
    }

    // re-validate the slot against the identity the query was built for
    new szId[16], szAuth[40], szRest[64]
    argbreak(data, szId, charsmax(szId), szRest, charsmax(szRest))
    argbreak(szRest, szAuth, charsmax(szAuth), szRest, charsmax(szRest))
    new id = str_to_num(szId)

    if (!IsConnected(id) || !equal(szAuth, g_szAuth[id]) || g_bLoaded[id])
        return

    if (!SQL_NumResults(query))
    {
        // fresh competitor: all zeroed already by putinserver
        g_iMissionDay[id] = GetToday()
        g_bLoaded[id] = true
        DebugLog("%s new competitor registered for season %s", szAuth, g_szSeason)
        return
    }

    g_iPoints[id]    = SQL_ReadResult(query, 0)
    g_iKills[id]     = SQL_ReadResult(query, 1)
    g_iHeadshots[id] = SQL_ReadResult(query, 2)
    g_iWins[id]      = SQL_ReadResult(query, 3)
    g_iMvp[id]       = SQL_ReadResult(query, 4)

    new iSavedDay = SQL_ReadResult(query, 5)
    g_iMissionProgress[id][MSN_KILLS] = SQL_ReadResult(query, 6)
    g_iMissionProgress[id][MSN_HS]    = SQL_ReadResult(query, 7)
    g_iMissionProgress[id][MSN_WINS]  = SQL_ReadResult(query, 8)
    g_iMissionProgress[id][MSN_MVP]   = SQL_ReadResult(query, 9)

    new iDoneMask = SQL_ReadResult(query, 10)
    for (new i; i < MSN_COUNT; i++)
        g_bMissionDone[id][i] = (iDoneMask & (1 << i)) != 0

    if (!SQL_IsNull(query, 11))
        g_iLifetime[id] = SQL_ReadResult(query, 11)

    g_bSeasonClaimed[id] = false
    if (SQL_NumColumns(query) > 12 && !SQL_IsNull(query, 12))
        g_bSeasonClaimed[id] = (SQL_ReadResult(query, 12) > 0)

    // missions are daily: stale progress from an earlier day is discarded
    if (iSavedDay != GetToday())
    {
        arrayset(g_iMissionProgress[id], 0, MSN_COUNT)
        arrayset(g_bMissionDone[id], 0, MSN_COUNT)
        g_iMissionDay[id] = GetToday()
    }
    else
    {
        g_iMissionDay[id] = iSavedDay
    }

    g_bLoaded[id] = true
    CacheUpsert(szAuth, g_iPoints[id], g_iKills[id])
    DebugLog("%s loaded: %d pts (season %s)", szAuth, g_iPoints[id], g_szSeason)
}

// ---------------------------------------------------------------- save

SavePlayer(id)
{
    if (!g_bSqlReady || !g_bLoaded[id] || !g_szAuth[id][0])
        return

    new szAuthQ[96], szSeasonQ[16], szNameQ[128]
    EscapeSql( szAuthQ, charsmax(szAuthQ), g_szAuth[id])
    EscapeSql( szSeasonQ, charsmax(szSeasonQ), g_szSeason)

    // name is player-controlled: quote it (auth/season are validated chars,
    // but quoting costs nothing and keeps every statement uniform)
    new szName[32]
    get_user_name(id, szName, charsmax(szName))
    EscapeSql( szNameQ, charsmax(szNameQ), szName)

    new iDoneMask
    for (new i; i < MSN_COUNT; i++)
        if (g_bMissionDone[id][i])
            iDoneMask |= (1 << i)

    new szQuery[640], szData[16]
    formatex(szQuery, charsmax(szQuery),
        "INSERT OR REPLACE INTO fn_comp_season \
            (auth, season, points, kills, headshots, wins, mvp, name, \
             msn_day, msn_k, msn_h, msn_w, msn_m, msn_done, last_seen) \
         VALUES ('%s', '%s', %d, %d, %d, %d, %d, '%s', %d, %d, %d, %d, %d, %d, %d)",
        szAuthQ, szSeasonQ, g_iPoints[id], g_iKills[id], g_iHeadshots[id],
        g_iWins[id], g_iMvp[id], szNameQ, g_iMissionDay[id],
        g_iMissionProgress[id][MSN_KILLS], g_iMissionProgress[id][MSN_HS],
        g_iMissionProgress[id][MSN_WINS], g_iMissionProgress[id][MSN_MVP],
        iDoneMask, get_systime())
    formatex(szData, charsmax(szData), "%d", id)
    SQL_ThreadQuery(g_SqlTuple, "HandleSave", szQuery, szData, strlen(szData))

    // career lifetime survives seasons (same policy as freenova_season)
    formatex(szQuery, charsmax(szQuery),
        "INSERT OR REPLACE INTO fn_comp_career (auth, lifetime, name, last_seen) \
         VALUES ('%s', %d, '%s', %d)", szAuthQ, g_iLifetime[id], szNameQ, get_systime())
    SQL_ThreadQuery(g_SqlTuple, "HandleSave", szQuery, szData, strlen(szData))
}

public HandleSave(failstate, Handle:query, error[], errnum, data[], size)
{
    if (failstate != TQUERY_SUCCESS)
        log_amx("[FreeNova Competitive] save failed for slot %s (%d): %s", data, errnum, error)
}

SaveAll()
{
    if (!g_bSqlReady)
        return

    for (new id = 1; id <= g_iMaxSlots; id++)
        if (g_bLoaded[id] && IsConnected(id))
            SavePlayer(id)
}

public Task_AutoSave()
{
    if (!g_bSqlReady)
        return

    // season rollover: flush under the old season, then re-key everyone
    new szNow[8]
    format_time(szNow, charsmax(szNow), "%Y-%m")
    if (!equal(szNow, g_szSeason))
    {
        SaveAll()
        log_amx("[FreeNova Competitive] season rollover %s -> %s", g_szSeason, szNow)
        copy(g_szSeason, charsmax(g_szSeason), szNow)
        g_CacheN = 0
        CacheRefresh()

        for (new id = 1; id <= g_iMaxSlots; id++)
            if (g_bLoaded[id] && IsConnected(id))
            {
                g_bLoaded[id] = false
                g_iPoints[id] = 0
                g_iKills[id] = 0
                g_iHeadshots[id] = 0
                g_iWins[id] = 0
                g_iMvp[id] = 0
                g_bSeasonClaimed[id] = false
                LoadPlayer(id)   // career lifetime is preserved by the load
            }
        return
    }

    // midnight rollover for connected players' daily missions
    new iToday = GetToday()
    for (new id = 1; id <= g_iMaxSlots; id++)
        if (g_bLoaded[id] && g_iMissionDay[id] != iToday)
        {
            arrayset(g_iMissionProgress[id], 0, MSN_COUNT)
            arrayset(g_bMissionDone[id], 0, MSN_COUNT)
            g_iMissionDay[id] = iToday
        }

    for (new id = 1; id <= g_iMaxSlots; id++)
        if (g_bLoaded[id] && IsConnected(id))
            SavePlayer(id)
    CacheRefresh()
}

// ---------------------------------------------------------------- scoring

CacheUpsert(const szAuth[], iPoints, iKills)
{
    if (!szAuth[0])
        return
    for (new i = 0; i < g_CacheN; i++)
    {
        if (equal(g_CacheAuth[i], szAuth))
        {
            g_CachePoints[i] = iPoints
            g_CacheKills[i] = iKills
            return
        }
    }
    if (g_CacheN >= COMP_CACHE_MAX)
    {
        log_amx("[FreeNova Competitive] rank cache full (%d) - rank approximate", g_CacheN)
        return
    }
    copy(g_CacheAuth[g_CacheN], charsmax(g_CacheAuth[]), szAuth)
    g_CachePoints[g_CacheN] = iPoints
    g_CacheKills[g_CacheN] = iKills
    g_CacheN++
}

CacheRefresh()
{
    if (g_SqlTuple == Empty_Handle)
        return
    g_bCacheReady = false
    new szSeasonQ[16]
    EscapeSql(szSeasonQ, charsmax(szSeasonQ), g_szSeason)
    new szQuery[192]
    formatex(szQuery, charsmax(szQuery),
        "SELECT auth, points, kills FROM fn_comp_season WHERE season = '%s' LIMIT %d",
        szSeasonQ, COMP_CACHE_MAX)
    SQL_ThreadQuery(g_SqlTuple, "HandleCacheFill", szQuery)
}

public HandleCacheFill(failstate, Handle:query, error[], errnum, data[], size)
{
    if (failstate == TQUERY_SUCCESS)
    {
        g_CacheN = 0
        new szAuth[40]
        while (SQL_MoreResults(query))
        {
            SQL_ReadResult(query, 0, szAuth, charsmax(szAuth))
            if (szAuth[0] && g_CacheN < COMP_CACHE_MAX)
            {
                copy(g_CacheAuth[g_CacheN], charsmax(g_CacheAuth[]), szAuth)
                g_CachePoints[g_CacheN] = SQL_ReadResult(query, 1)
                g_CacheKills[g_CacheN] = SQL_ReadResult(query, 2)
                g_CacheN++
            }
            SQL_NextRow(query)
        }
    }
    else
        log_amx("[FreeNova Competitive] rank cache refresh failed: %s", error)
    g_bCacheReady = true
}

Award(id, iDelta)
{
    // every caller gates on PointsActive(); this only guards the cache
    if (!g_bLoaded[id])
        return

    g_iPoints[id] += iDelta
    g_iLifetime[id] += iDelta

    // penalties can never drag a competitor below zero
    if (g_iPoints[id] < 0)   g_iPoints[id] = 0
    if (g_iLifetime[id] < 0) g_iLifetime[id] = 0
    CacheUpsert(g_szAuth[id], g_iPoints[id], g_iKills[id])

    DebugLog("%s %+d pts -> %d", g_szAuth[id], iDelta, g_iPoints[id])
}

MissionProgress(id, iMission)
{
    if (g_bMissionDone[id][iMission])
        return

    g_iMissionProgress[id][iMission]++

    if (g_iMissionProgress[id][iMission] < g_iMissionTarget[iMission])
        return

    g_bMissionDone[id][iMission] = true

    new iReward = g_iMissionPoints[iMission]
    Award(id, iReward)
    client_print_color(id, print_team_default,
        "^4[FreeNova]^1 Daily mission complete: ^3%s^1 (+%d pts)", g_szMissionName[iMission], iReward)
    DebugLog("%s mission %s complete", g_szAuth[id], g_szMissionName[iMission])
}

// ---------------------------------------------------------------- natives

// state exports for freenova_sync (web panel push); all read-only
public plugin_natives()
{
    set_native_filter("CompNativeFilter")
    register_library("freenova_comp")
    register_native("fncomp_get_points", "_native_points")
    register_native("fncomp_get_lifetime", "_native_lifetime")
    register_native("fncomp_get_kills", "_native_kills")
    register_native("fncomp_get_headshots", "_native_hs")
    register_native("fncomp_get_wins", "_native_wins")
    register_native("fncomp_get_mvp", "_native_mvp")
    register_native("fncomp_get_mission_progress", "_native_mission")
    register_native("fncomp_get_mission_done", "_native_mission_done")
    register_native("fncomp_claim_season_prize", "_native_claim")
    register_native("fncomp_is_season_claimed", "_native_is_claimed")
    register_native("fncomp_get_rank", "_native_rank")
}

public CompNativeFilter(const name[], index, trap)
{
    #pragma unused index, trap
    if (equal(name, "menabp_add_coins"))
        return PLUGIN_HANDLED
    return PLUGIN_CONTINUE
}

public _native_points(iPlugin, iParams)
{
    new id = get_param(1)
    return g_bLoaded[id] ? g_iPoints[id] : 0
}

public _native_lifetime(iPlugin, iParams)
{
    new id = get_param(1)
    return g_bLoaded[id] ? g_iLifetime[id] : 0
}

public _native_kills(iPlugin, iParams)
{
    new id = get_param(1)
    return g_bLoaded[id] ? g_iKills[id] : 0
}

public _native_hs(iPlugin, iParams)
{
    new id = get_param(1)
    return g_bLoaded[id] ? g_iHeadshots[id] : 0
}

public _native_wins(iPlugin, iParams)
{
    new id = get_param(1)
    return g_bLoaded[id] ? g_iWins[id] : 0
}

public _native_mvp(iPlugin, iParams)
{
    new id = get_param(1)
    return g_bLoaded[id] ? g_iMvp[id] : 0
}

public _native_mission(iPlugin, iParams)
{
    new id = get_param(1)
    new iMission = get_param(2)
    if (iMission < 0 || iMission >= MSN_COUNT)
        return 0
    return g_bLoaded[id] ? g_iMissionProgress[id][iMission] : 0
}

public _native_mission_done(iPlugin, iParams)
{
    new id = get_param(1)
    if (!(1 <= id <= 32) || !g_bLoaded[id])
        return 0

    new iDoneMask
    for (new i; i < MSN_COUNT; i++)
    {
        if (g_bMissionDone[id][i])
            iDoneMask |= (1 << i)
    }
    return iDoneMask
}

// Season rank by board order (points DESC, kills DESC) over the live cache.
// Synchronous and hook-safe. 0 while the cache fills (claim retries later).
CompRank(id)
{
    if (!(1 <= id <= 32) || !g_bLoaded[id] || !g_szAuth[id][0] || !g_bCacheReady)
        return 0
    new iRank = 1, iPts = g_iPoints[id], iK = g_iKills[id]
    for (new i = 0; i < g_CacheN; i++)
    {
        if (equal(g_CacheAuth[i], g_szAuth[id]))
            continue
        if (g_CachePoints[i] > iPts || (g_CachePoints[i] == iPts && g_CacheKills[i] > iK))
            iRank++
    }
    return iRank
}

public _native_rank(iPlugin, iParams)
{
    new id = get_param(1)
    if (!(1 <= id <= 32) || !g_bLoaded[id])
        return 0
    return CompRank(id)
}

ComputeSeasonPrize(id)
{
    if (!g_bLoaded[id])
        return 0
    new iPoints = g_iPoints[id]
    new iWins = g_iWins[id]
    new bool:bMsnDone = (g_iMissionProgress[id][MSN_KILLS] >= g_iMissionTarget[MSN_KILLS] &&
                         g_iMissionProgress[id][MSN_HS] >= g_iMissionTarget[MSN_HS] &&
                         g_iMissionProgress[id][MSN_WINS] >= g_iMissionTarget[MSN_WINS] &&
                         g_iMissionProgress[id][MSN_MVP] >= g_iMissionTarget[MSN_MVP])
    // Rank-based (owner ruling): ranks 1-3 podium, 4-15 qualifier.
    // Below rank 15 the mission/victor fallbacks apply, never thresholds.
    //
    // A player with no points and no wins this season has no standing to rank.
    // Without this gate an empty or half-loaded rank cache made everybody rank
    // 1, so the first claimant took the 10,000 coin champion tier for free -
    // while the web panel (comp_points > 0 || comp_wins > 0) and
    // freenova_sync's own refusal ("You need tournament points or wins to
    // claim prizes!") both refuse the same player. Points are clamped at 0 by
    // teamkill penalties, so wins are checked as well.
    new bool:bHasStanding = (iPoints > 0 || iWins > 0)
    new iRank = bHasStanding ? CompRank(id) : 0
    if (iRank == 1)
        return 10000
    if (iRank == 2)
        return 5000
    if (iRank == 3)
        return 2500
    if (iRank >= 4 && iRank <= 15)
        return 1000
    if (bMsnDone)
        return 500
    if (iWins >= 5 || iPoints >= 100)
        return 250
    return 0
}

public _native_is_claimed(iPlugin, iParams)
{
    new id = get_param(1)
    return (1 <= id <= 32 && g_bLoaded[id] && g_bSeasonClaimed[id]) ? 1 : 0
}

ClaimSeasonPrize(id)
{
    if (!(1 <= id <= 32) || !g_bLoaded[id] || !g_szAuth[id][0])
        return 0
    if (g_bSeasonClaimed[id])
        return 0

    // Rank 0 with live points means the cache is mid-refresh: refuse without
    // locking so the player can claim the correct tier moments later.
    if (CompRank(id) == 0 && (g_iPoints[id] > 0 || g_iWins[id] > 0))
        return 0
    new iCoins = ComputeSeasonPrize(id)
    if (iCoins <= 0)
        return 0

    // Credit BEFORE recording: the economy call is the fallible step.
    // Refuse (unlocked, retryable) when the provider is down or the grant
    // fails, so a prize is never burned with no coins.
    if (!LibraryExists("menabp", LibType_Library))
        return 0
    if (menabp_add_coins(id, iCoins) <= 0)
        return 0

    // Lock only after the coins landed, so a second call in the same
    // occupancy cannot double-pay while the INSERT is in flight.
    g_bSeasonClaimed[id] = true

    // Rank marks: rank 1 takes the champion tag (server-set, persists);
    // ranks 2-3 unlock their named titles (non-destructive); ranks 4-15
    // get the tag license (PRO tag stays a 3000c premade purchase).
    // Deviation from web copy is deliberate and documented for approval.
    if (LibraryExists("freenova_cosmetics", LibType_Library))
    {
        new iRank = CompRank(id)
        if (iRank == 1)
            fncosmetics_set_tag(id, "[TOURNAMENT CHAMPION]")
        else if (iRank == 2)
            fncosmetics_unlock_title(id, 7)
        else if (iRank == 3)
            fncosmetics_unlock_title(id, 8)
        else if (iRank >= 4 && iRank <= 15)
            fncosmetics_grant_tag_license(id)
    }

    if (g_SqlTuple != Empty_Handle && g_bSqlReady)
    {
        new szAuthQ[96], szSeasonQ[16], szQuery[320]
        EscapeSql( szAuthQ, charsmax(szAuthQ), g_szAuth[id])
        EscapeSql( szSeasonQ, charsmax(szSeasonQ), g_szSeason)
        formatex(szQuery, charsmax(szQuery),
            "INSERT OR IGNORE INTO fn_comp_claims (auth, season, coins, claimed_at) \
             VALUES ('%s', '%s', %d, %d)", szAuthQ, szSeasonQ, iCoins, get_systime())
        SQL_ThreadQuery(g_SqlTuple, "HandleSave", szQuery)
    }
    return iCoins
}

public _native_claim(iPlugin, iParams)
{
    return ClaimSeasonPrize(get_param(1))
}

public Cmd_Claim(id)
{
    if (!IsConnected(id))
        return PLUGIN_HANDLED

    if (!g_bLoaded[id])
    {
        client_print_color(id, print_team_default,
            "^4[FreeNova]^1 Competitive stats are not ready yet.")
        return PLUGIN_HANDLED
    }
    if (g_bSeasonClaimed[id])
    {
        client_print_color(id, print_team_default,
            "^4[FreeNova]^1 Season prize already claimed.")
        return PLUGIN_HANDLED
    }

    // ClaimSeasonPrize already credited the coins (credit-then-record);
    // iCoins here means paid.
    new iCoins = ClaimSeasonPrize(id)
    if (iCoins <= 0)
    {
        client_print_color(id, print_team_default,
            "^4[FreeNova]^1 No season prize available this month.")
        return PLUGIN_HANDLED
    }

    client_print_color(id, print_team_default,
        "^4[FreeNova]^1 Claimed season prize: ^3+%d coins^1.", iCoins)
    return PLUGIN_HANDLED
}

public client_death(iAttacker, iVictim, iWeapon, iHitplace, iTK)
{
    #pragma unused iVictim, iWeapon, iHitplace
    // Ranked kills arrive through fn_on_player_kill. Teamkills never do.
    if (!iTK)
        return
    if (!IsConnected(iAttacker) || is_user_bot(iAttacker))
        return
    if (!PointsActive() || !g_bLoaded[iAttacker])
        return
    Award(iAttacker, get_pcvar_num(g_pTkPenalty))
}

public fn_on_player_kill(iAttacker, iVictim, iWeapon, iHeadshot, iTK)
{
    #pragma unused iVictim
    // Teamkills are penalized on the client_death path; never award kill
    // points here even if a provider ever forwards one.
    if (iTK)
        return
    if (!IsConnected(iAttacker) || !PointsActive() || !g_bLoaded[iAttacker])
        return

    g_iKills[iAttacker]++
    Award(iAttacker, get_pcvar_num(g_pKillPts))
    MissionProgress(iAttacker, MSN_KILLS)

    if (iHeadshot)
    {
        g_iHeadshots[iAttacker]++
        Award(iAttacker, get_pcvar_num(g_pHsPts))
        MissionProgress(iAttacker, MSN_HS)
    }
}

// RANK_BOTS master switch reader: true only when rsu_core runs RANK_BOTS=1.
// Only VICTIM-side counters open (round damage vs bots); payees stay human.
// Human-vs-bot points are farmable by design when switched on (operator choice).
stock bool:BotCountOn()
{
    return LibraryExists("rsu_core", LibType_Library) && rsu_bots_count();
}

public client_damage(iAttacker, iVictim, iDamage, iWeapon, iHitplace, iTa)
{
    if (!IsConnected(iAttacker) || !IsConnected(iVictim))
        return
    if (iAttacker == iVictim)
        return
    if (is_user_bot(iAttacker) || (is_user_bot(iVictim) && !BotCountOn()))
        return
    if (get_user_team(iAttacker) == get_user_team(iVictim))
        return

    g_iRoundDamage[iAttacker] += iDamage
}

public bomb_planted(iPlanter)
{
    g_iPlanter = iPlanter
    g_bBombExploded = false

    if (IsConnected(iPlanter) && !is_user_bot(iPlanter) && g_bLoaded[iPlanter] && PointsActive())
        Award(iPlanter, get_pcvar_num(g_pPlantPts))
}

public bomb_explode(iPlanter, iDefuser)
{
    g_bBombExploded = true
}

public bomb_defused(iDefuser)
{
    g_iDefuser = iDefuser

    if (IsConnected(iDefuser) && !is_user_bot(iDefuser) && g_bLoaded[iDefuser] && PointsActive())
        Award(iDefuser, get_pcvar_num(g_pDefusePts))
}

public Event_RoundStart()
{
    arrayset(g_iRoundDamage, 0, sizeof(g_iRoundDamage))
    g_iPlanter = 0
    g_iDefuser = 0
    g_bBombExploded = false
}

public Event_TWin()
{
    OnTeamWin(CsTeams:CS_TEAM_T)
}

public Event_CtWin()
{
    OnTeamWin(CsTeams:CS_TEAM_CT)
}

OnTeamWin(CsTeams:iTeam)
{
    if (!PointsActive())
        return

    new iPlayers[MAX_PLAYERS], iNum
    get_players(iPlayers, iNum, "che", iTeam == CsTeams:CS_TEAM_T ? "TERRORIST" : "CT")

    new iMvp = ResolveMvp(iTeam, iPlayers, iNum)

    for (new i; i < iNum; i++)
    {
        new id = iPlayers[i]
        if (!g_bLoaded[id])
            continue

        g_iWins[id]++
        Award(id, get_pcvar_num(g_pWinPts))
        MissionProgress(id, MSN_WINS)
    }

    if (iMvp)
    {
        g_iMvp[iMvp]++
        Award(iMvp, get_pcvar_num(g_pMvpPts))
        MissionProgress(iMvp, MSN_MVP)

        new szName[32]
        get_user_name(iMvp, szName, charsmax(szName))
        client_print_color(0, print_team_default,
            "^4[FreeNova]^3 %s^1 is the round MVP (+%d pts)", szName, get_pcvar_num(g_pMvpPts))
    }

    // self-contained per-round reset (RoundStart re-clears as a backstop)
    arrayset(g_iRoundDamage, 0, sizeof(g_iRoundDamage))
    g_iPlanter = 0
    g_iDefuser = 0
    g_bBombExploded = false
}

ResolveMvp(CsTeams:iTeam, iPlayers[], iNum)
{
    // objective MVP: defuser on a defuse win, planter on a bomb-explosion win
    if (iTeam == CsTeams:CS_TEAM_CT && IsConnected(g_iDefuser)
        && cs_get_user_team(g_iDefuser) == CsTeams:CS_TEAM_CT)
        return g_iDefuser

    if (iTeam == CsTeams:CS_TEAM_T && g_bBombExploded && IsConnected(g_iPlanter)
        && cs_get_user_team(g_iPlanter) == CsTeams:CS_TEAM_T)
        return g_iPlanter

    // fallback: the winning team's top round-damage survivor (ties -> lowest id)
    new iBest, iBestDmg = -1
    for (new i; i < iNum; i++)
    {
        new id = iPlayers[i]
        if (g_iRoundDamage[id] > iBestDmg)
        {
            iBestDmg = g_iRoundDamage[id]
            iBest = id
        }
    }
    return (iBestDmg > 0) ? iBest : 0
}

// ---------------------------------------------------------------- commands

IsConnected(id)
{
    return (1 <= id <= g_iMaxSlots && is_user_connected(id))
}

public Cmd_CompetitiveMenu(id)
{
    if (!IsConnected(id))
        return PLUGIN_HANDLED
    ShowCompetitiveLiteMenu(id)
    return PLUGIN_HANDLED
}

public Cmd_MyPoints(id)
{
    if (!IsConnected(id))
        return PLUGIN_HANDLED

    if (FNWeb_LowPerf(id))
    {
        ShowCompetitiveLiteMenu(id)
        return PLUGIN_HANDLED
    }

    // hosted panel first; local MOTD only when fnweb_url is unset
    if (FNWeb_OpenPage(id, "pts"))
        return PLUGIN_HANDLED

    if (!g_bLoaded[id])
    {
        client_print_color(id, print_team_default,
            "^4[FreeNova]^1 Competitive stats are not ready yet (backend offline?)")
        return PLUGIN_HANDLED
    }

    // season rank comes from the DB: COUNT of strictly-better competitors + 1
    new szAuthQ[96], szSeasonQ[16]
    EscapeSql( szAuthQ, charsmax(szAuthQ), g_szAuth[id])
    EscapeSql( szSeasonQ, charsmax(szSeasonQ), g_szSeason)

    new szQuery[256], szData[80]
    formatex(szQuery, charsmax(szQuery),
        "SELECT COUNT(*) + 1 FROM fn_comp_season \
         WHERE season = '%s' AND points > %d", szSeasonQ, g_iPoints[id])
    formatex(szData, charsmax(szData), "%d %s", id, g_szAuth[id])
    SQL_ThreadQuery(g_SqlTuple, "HandleRankQuery", szQuery, szData, strlen(szData))

    return PLUGIN_HANDLED
}

// Low Performance Mode: competitive summary and grant actions as a native menu.
ShowCompetitiveLiteMenu(id)
{
    if (!IsConnected(id))
        return
    if (!g_bLoaded[id])
    {
        client_print_color(id, print_team_default, "^4[FreeNova]^1 Competitive stats are still loading.")
        return
    }

    new szTitle[64], szItem[112]
    FN_MenuTitle(szTitle, charsmax(szTitle), "Competitive")
    new menu = menu_create(szTitle, "CompLite_Handler")

    new iRank = CompRank(id)
    new szRank[16]
    if (iRank > 0)
        formatex(szRank, charsmax(szRank), "#%d", iRank)
    else
        copy(szRank, charsmax(szRank), "unranked")
    formatex(szItem, charsmax(szItem), "\wPoints \y%d  \d|  \wRank \y%s", g_iPoints[id], szRank)
    menu_additem(menu, szItem, "0")
    formatex(szItem, charsmax(szItem), "\wKills \y%d  \d|  \wHS \y%d  \d|  \wWins \y%d  \d|  \wMVP \y%d", g_iKills[id], g_iHeadshots[id], g_iWins[id], g_iMvp[id])
    menu_additem(menu, szItem, "0")

    new iDone
    for (new i; i < MSN_COUNT; i++)
        if (g_iMissionProgress[id][i] >= g_iMissionTarget[i])
            iDone++
    formatex(szItem, charsmax(szItem), "\wDaily set \y%d \d/ %d", iDone, MSN_COUNT)
    menu_additem(menu, szItem, "0")

    new iClaim = ComputeSeasonPrize(id)
    if (iClaim > 0 && !g_bSeasonClaimed[id])
    {
        formatex(szItem, charsmax(szItem), "\yClaim season prize \d- %dc", iClaim)
        menu_additem(menu, szItem, "5")
    }

    menu_additem(menu, "\wLeaderboard \d- /ctop", "1")
    menu_additem(menu, "\wDaily missions \d- /cmissions", "2")
    FN_MenuFinish(menu, false)
    menu_display(id, menu, 0)
}

public CompLite_Handler(id, menu, item)
{
    if (item == MENU_EXIT || !is_user_connected(id))
    {
        menu_destroy(menu)
        return PLUGIN_HANDLED
    }

    new szData[8], iAccess, iCallback
    menu_item_getinfo(menu, item, iAccess, szData, charsmax(szData), _, _, iCallback)
    menu_destroy(menu)

    switch (str_to_num(szData))
    {
        case 1: Cmd_Top15(id)
        case 2: Cmd_Missions(id)
        case 5:
        {
            new iCoins = ClaimSeasonPrize(id)
            if (iCoins > 0)
                client_print_color(id, print_team_default, "^4[FreeNova]^1 Claimed season prize: ^3+%d coins^1.", iCoins)
            ShowCompetitiveLiteMenu(id)
        }
    }
    return PLUGIN_HANDLED
}

public HandleRankQuery(failstate, Handle:query, error[], errnum, data[], size)
{
    // re-validate the slot against the identity the query was built for
    new szId[16], szAuth[40], szRest[64]
    argbreak(data, szId, charsmax(szId), szRest, charsmax(szRest))
    argbreak(szRest, szAuth, charsmax(szAuth), szRest, charsmax(szRest))
    new id = str_to_num(szId)
    if (!IsConnected(id) || !equal(szAuth, g_szAuth[id]))
        return

    new iRank = (failstate == TQUERY_SUCCESS && SQL_NumResults(query))
        ? SQL_ReadResult(query, 0) : 0

    BuildMyMotd(id, iRank)
}

BuildMyMotd(id, iRank)
{
    new szMotd[4096], iPos
    new szSub[40]
    formatex(szSub, charsmax(szSub), "SEASON %s", g_szSeason)
    iPos = FN_MotdHeader(szMotd, charsmax(szMotd), "COMPETITIVE", szSub)

    new szPts[16], szLife[16], szRow[192]
    FN_AddCommas(g_iPoints[id], szPts, charsmax(szPts))
    FN_AddCommas(g_iLifetime[id], szLife, charsmax(szLife))

    if (iRank > 0)
        formatex(szRow, charsmax(szRow),
            "<table class='fnt'><tr><td class='k'>Season points</td><td class='v'>%s</td></tr>\
             <tr><td class='k'>Season rank</td><td class='v'>#%d</td></tr>\
             <tr><td class='k'>Career lifetime</td><td class='v'>%s</td></tr>\
             <tr><td class='k'>Kills / Headshots</td><td class='v'>%d / %d</td></tr>\
             <tr><td class='k'>Round wins / MVP</td><td class='v'>%d / %d</td></tr></table>",
            szPts, iRank, szLife, g_iKills[id], g_iHeadshots[id], g_iWins[id], g_iMvp[id])
    else
        formatex(szRow, charsmax(szRow),
            "<table class='fnt'><tr><td class='k'>Season points</td><td class='v'>%s</td></tr>\
             <tr><td class='k'>Season rank</td><td class='v fnmuted'>unavailable</td></tr>\
             <tr><td class='k'>Career lifetime</td><td class='v'>%s</td></tr>\
             <tr><td class='k'>Kills / Headshots</td><td class='v'>%d / %d</td></tr>\
             <tr><td class='k'>Round wins / MVP</td><td class='v'>%d / %d</td></tr></table>",
            szPts, szLife, g_iKills[id], g_iHeadshots[id], g_iWins[id], g_iMvp[id])
    iPos += copy(szMotd[iPos], charsmax(szMotd) - iPos, szRow)

    // daily missions
    iPos += copy(szMotd[iPos], charsmax(szMotd) - iPos,
        "<div class='fntitle' style='margin-top:6px;'>Daily Missions</div><table class='fnt'>")

    new szBar[24]
    for (new i; i < MSN_COUNT && iPos < charsmax(szMotd) - 220; i++)
    {
        FN_TextBar(g_iMissionProgress[id][i] * 100 / g_iMissionTarget[i], 14, szBar, charsmax(szBar))
        formatex(szRow, charsmax(szRow),
            "<tr><td class='k'>%s%s</td><td class='v fnbar'>%s</td><td class='v'>%d/%d</td></tr>",
            g_szMissionName[i], g_bMissionDone[id][i] ? " <span class='fngreen'>OK</span>" : "",
            szBar, g_iMissionProgress[id][i], g_iMissionTarget[i])
        iPos += copy(szMotd[iPos], charsmax(szMotd) - iPos, szRow)
    }
    iPos += copy(szMotd[iPos], charsmax(szMotd) - iPos, "</table>")

    FN_MotdFooter(szMotd, charsmax(szMotd), iPos)
    FN_MotdShow(id, szMotd, "FreeNova Competitive")
}

public Cmd_Top15(id)
{
    if (!IsConnected(id))
        return PLUGIN_HANDLED

    if (FNWeb_OpenPage(id, "ctop"))
        return PLUGIN_HANDLED

    if (!g_bSqlReady)
    {
        client_print_color(id, print_team_default,
            "^4[FreeNova]^1 Competitive leaderboard is unavailable (backend offline)")
        return PLUGIN_HANDLED
    }

    new szSeasonQ[16], szQuery[256], szData[64]
    EscapeSql( szSeasonQ, charsmax(szSeasonQ), g_szSeason)
    formatex(szQuery, charsmax(szQuery),
        "SELECT name, points FROM fn_comp_season WHERE season = '%s' \
         ORDER BY points DESC, kills DESC LIMIT 15", szSeasonQ)
    formatex(szData, charsmax(szData), "%d %s", id, g_szAuth[id])
    SQL_ThreadQuery(g_SqlTuple, "HandleTopQuery", szQuery, szData, strlen(szData))

    return PLUGIN_HANDLED
}

public HandleTopQuery(failstate, Handle:query, error[], errnum, data[], size)
{
    // re-validate the slot against the identity the query was built for
    new szId[16], szAuth[40], szRest[64]
    argbreak(data, szId, charsmax(szId), szRest, charsmax(szRest))
    argbreak(szRest, szAuth, charsmax(szAuth), szRest, charsmax(szRest))
    new id = str_to_num(szId)

    if (!IsConnected(id) || !equal(szAuth, g_szAuth[id]))
        return

    if (failstate != TQUERY_SUCCESS)
    {
        client_print_color(id, print_team_default,
            "^4[FreeNova]^1 Leaderboard query failed - try again later")
        return
    }

    if (FNWeb_LowPerf(id))
    {
        ShowCompLeaderboardMenu(id, query)
        return
    }

    new szMotd[4096], iPos
    new szSub[40]
    formatex(szSub, charsmax(szSub), "SEASON %s", g_szSeason)
    iPos = FN_MotdHeader(szMotd, charsmax(szMotd), "TOP 15 POINTS", szSub)
    if (!SQL_NumResults(query))
    {
        iPos += copy(szMotd[iPos], charsmax(szMotd) - iPos,
            "<div class='fnmuted' style='text-align:center;margin-top:10px;'>\
             No entries this season yet - score points to appear here.</div>")
    }
    else
    {
        iPos += copy(szMotd[iPos], charsmax(szMotd) - iPos,
            "<table class='fnt'><tr><th>#</th><th>Player</th><th>Points</th></tr>")

        new iRank
        new szName[64], szEsc[96], szPts[16], szRow[256]
        while (SQL_MoreResults(query) && iRank < 15 && iPos < charsmax(szMotd) - 200)
        {
            iRank++
            SQL_ReadResult(query, 0, szName, charsmax(szName))
            FN_EscapeHtml(szName, szEsc, charsmax(szEsc))
            FN_AddCommas(SQL_ReadResult(query, 1), szPts, charsmax(szPts))

            if (iRank <= 3)
                formatex(szRow, charsmax(szRow),
                    "<tr class='fnr%d'><td>%d</td><td>%s</td><td class='v'>%s</td></tr>",
                    iRank, iRank, szEsc, szPts)
            else
                formatex(szRow, charsmax(szRow),
                    "<tr><td>%d</td><td>%s</td><td class='v'>%s</td></tr>",
                    iRank, szEsc, szPts)
            iPos += copy(szMotd[iPos], charsmax(szMotd) - iPos, szRow)

            SQL_NextRow(query)
        }
        iPos += copy(szMotd[iPos], charsmax(szMotd) - iPos, "</table>")
    }

    FN_MotdFooter(szMotd, charsmax(szMotd), iPos)
    FN_MotdShow(id, szMotd, "FreeNova Top15 Points")
}

ShowCompLeaderboardMenu(id, Handle:query)
{
    if (!is_user_connected(id))
        return

    new szTitle[64]
    FN_MenuTitle(szTitle, charsmax(szTitle), "Competitive - Top 15")
    new menu = menu_create(szTitle, "CompLeaderboard_Handler")

    if (!SQL_NumResults(query))
    {
        menu_additem(menu, "\dNo entries this season yet.", "0")
    }
    else
    {
        new iRank, szName[64], szPts[16], szItem[128]
        while (SQL_MoreResults(query) && iRank < 15)
        {
            iRank++
            SQL_ReadResult(query, 0, szName, charsmax(szName))
            FN_AddCommas(SQL_ReadResult(query, 1), szPts, charsmax(szPts))
            replace_all(szName, charsmax(szName), "\\", "")
            formatex(szItem, charsmax(szItem), "\w#%d  \y%s  \d- %s pts", iRank, szName, szPts)
            menu_additem(menu, szItem, "0")
        }
    }

    FN_MenuFinish(menu, true)
    menu_setprop(menu, MPROP_PERPAGE, 0)
    menu_display(id, menu, 0)
}

public CompLeaderboard_Handler(id, menu, item)
{
    menu_destroy(menu)
    if (is_user_connected(id))
        ShowCompetitiveLiteMenu(id)
    return PLUGIN_HANDLED
}

ShowCompMissionMenu(id)
{
    if (!IsConnected(id) || !g_bLoaded[id])
        return

    new szTitle[64], szItem[112]
    FN_MenuTitle(szTitle, charsmax(szTitle), "Daily Missions")
    new menu = menu_create(szTitle, "CompMissionLite_Handler")

    for (new i; i < MSN_COUNT; i++)
    {
        formatex(szItem, charsmax(szItem), "\w%s \d- \y%d\d / %d  \w+%d pts%s",
            g_szMissionName[i], g_iMissionProgress[id][i], g_iMissionTarget[i], g_iMissionPoints[i],
            g_iMissionProgress[id][i] >= g_iMissionTarget[i] ? "  \yDONE" : "")
        menu_additem(menu, szItem, "0")
    }

    menu_additem(menu, "\wBack to Competitive", "9")
    FN_MenuFinish(menu, true)
    menu_setprop(menu, MPROP_PERPAGE, 0)
    menu_display(id, menu, 0)
}

public CompMissionLite_Handler(id, menu, item)
{
    if (item == MENU_EXIT || !is_user_connected(id))
    {
        menu_destroy(menu)
        if (is_user_connected(id))
            ShowCompetitiveLiteMenu(id)
        return PLUGIN_HANDLED
    }

    new szData[8], iAccess, iCallback
    menu_item_getinfo(menu, item, iAccess, szData, charsmax(szData), _, _, iCallback)
    menu_destroy(menu)

    if (str_to_num(szData) == 9)
        ShowCompetitiveLiteMenu(id)
    return PLUGIN_HANDLED
}

public Cmd_Missions(id)
{
    if (!IsConnected(id))
        return PLUGIN_HANDLED

    if (FNWeb_LowPerf(id))
    {
        ShowCompMissionMenu(id)
        return PLUGIN_HANDLED
    }

    if (FNWeb_OpenPage(id, "cmissions"))
        return PLUGIN_HANDLED

    if (!g_bLoaded[id])
    {
        client_print_color(id, print_team_default,
            "^4[FreeNova]^1 Competitive stats are not ready yet (backend offline?)")
        return PLUGIN_HANDLED
    }

    new szMotd[4096], iPos
    iPos = FN_MotdHeader(szMotd, charsmax(szMotd), "DAILY MISSIONS",
        "AUTO-CLAIMED - RESET AT MIDNIGHT")

    iPos += copy(szMotd[iPos], charsmax(szMotd) - iPos,
        "<table class='fnt'><tr><th>Mission</th><th>Progress</th><th>Reward</th></tr>")

    new szBar[24], szRow[192]
    for (new i; i < MSN_COUNT && iPos < charsmax(szMotd) - 220; i++)
    {
        FN_TextBar(g_iMissionProgress[id][i] * 100 / g_iMissionTarget[i], 14, szBar, charsmax(szBar))
        formatex(szRow, charsmax(szRow),
            "<tr><td>%s%s</td><td class='v fnbar'>%s %d/%d</td><td class='v fngreen'>+%d pts</td></tr>",
            g_szMissionName[i], g_bMissionDone[id][i] ? " <span class='fngreen'>OK</span>" : "",
            szBar, g_iMissionProgress[id][i], g_iMissionTarget[i], g_iMissionPoints[i])
        iPos += copy(szMotd[iPos], charsmax(szMotd) - iPos, szRow)
    }
    iPos += copy(szMotd[iPos], charsmax(szMotd) - iPos, "</table>")

    FN_MotdFooter(szMotd, charsmax(szMotd), iPos)
    FN_MotdShow(id, szMotd, "FreeNova Missions")

    return PLUGIN_HANDLED
}

