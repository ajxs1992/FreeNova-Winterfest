#include <amxmodx>
#include <amxmisc>
#include <sqlx>
#include <reapi>
#include "include/rsu.inc"

#define PLUGIN_NAME     "RSU Match Tracking & Analytics"
#define PLUGIN_VERSION  RSU_VERSION_STRING
#define PLUGIN_AUTHOR   RSU_AUTHOR_STRING

new g_iMatchId = 0;
new g_iInitRetries = 0;
new g_szCurrentMap[64];
new g_iTScore = 0;
new g_iCTScore = 0;
new g_iRoundsCount = 0;

// Match Telemetry & Advanced Stats
new g_iMatchKills[RSU_MAX_PLAYERS + 1];
new g_iMatchDeaths[RSU_MAX_PLAYERS + 1];
new g_iMatchAssists[RSU_MAX_PLAYERS + 1];
new g_iMatchHeadshots[RSU_MAX_PLAYERS + 1];
new g_iMatchDamage[RSU_MAX_PLAYERS + 1];
new g_iMatchXpEarned[RSU_MAX_PLAYERS + 1];
new Float:g_fMatchSkillDelta[RSU_MAX_PLAYERS + 1];
new g_iMatchTeam[RSU_MAX_PLAYERS + 1];
new g_iMatchJoinTime[RSU_MAX_PLAYERS + 1];
new g_iMatchPlayedSeconds[RSU_MAX_PLAYERS + 1];
new bool:g_bCumulativeFlushed[RSU_MAX_PLAYERS + 1];

// Round Analytics Trackers
new g_iOpeningKills[RSU_MAX_PLAYERS + 1];
new g_iOpeningDeaths[RSU_MAX_PLAYERS + 1];
new g_iTradeKills[RSU_MAX_PLAYERS + 1];
new g_iTimesTraded[RSU_MAX_PLAYERS + 1];
new g_iClutchesWon[RSU_MAX_PLAYERS + 1];
new g_iClutchesAttempted[RSU_MAX_PLAYERS + 1];
new g_iClutchAttempt[RSU_MAX_PLAYERS + 1];
new g_iKastRounds[RSU_MAX_PLAYERS + 1];
new g_iAces[RSU_MAX_PLAYERS + 1];
new g_iKills2K[RSU_MAX_PLAYERS + 1];
new g_iKills3K[RSU_MAX_PLAYERS + 1];
new g_iKills4K[RSU_MAX_PLAYERS + 1];

// Per-Round Temporary State
new g_iRoundKills[RSU_MAX_PLAYERS + 1];
new g_iRoundAssists[RSU_MAX_PLAYERS + 1];
new g_iRoundDmgTo[RSU_MAX_PLAYERS + 1][RSU_MAX_PLAYERS + 1];
new bool:g_bRoundTraded[RSU_MAX_PLAYERS + 1];
new bool:g_bFirstFragOccurred = false;
new g_iLastKiller = 0;
new g_iLastVictim = 0;
new g_iLastVictimTeam = 0;
new Float:g_fLastKillGametime = 0.0;

// CVars & SQL
new g_pCvarServerId;
new g_pCvarAutoShowSummary;
new Handle:g_hSqlTuple;
new g_szSqlTablePrefix[32] = "rsu_";
new Float:g_fLastMatchCmd[RSU_MAX_PLAYERS + 1];

// Never pass Empty_Handle to SQL_QuoteString — sqlite raises native error 10.
EscapeSql(szOut[], iMax, const szIn[])
{
    copy(szOut, iMax, szIn);
    replace_all(szOut, iMax, "'", "''");
}

public plugin_natives()
{
    register_library("rsu_matchstats");
    register_native("rsu_get_match_adr", "_rsu_get_match_adr");
    register_native("rsu_get_match_kast", "_rsu_get_match_kast");
    register_native("rsu_get_match_opening_kills", "_rsu_get_match_opening_kills");
    register_native("rsu_get_match_trade_kills", "_rsu_get_match_trade_kills");
    register_native("rsu_get_match_clutches_won", "_rsu_get_match_clutches_won");
    register_native("rsu_get_match_aces", "_rsu_get_match_aces");
}

public plugin_init()
{
    register_plugin(PLUGIN_NAME, PLUGIN_VERSION, PLUGIN_AUTHOR);

    rsu_register_module("Match Tracker", PLUGIN_VERSION, PLUGIN_AUTHOR);

    g_pCvarServerId = get_cvar_pointer("rsu_server_id");
    g_pCvarAutoShowSummary = register_cvar("rsu_match_autoshow", "1");

    register_clcmd("say /match", "CmdShowMatchMotd");
    register_clcmd("say_team /match", "CmdShowMatchMotd");
    register_clcmd("say /lastmatch", "CmdShowMatchMotd");
    register_clcmd("say_team /lastmatch", "CmdShowMatchMotd");

    // ReAPI hooks
    RegisterHookChain(RG_CBasePlayer_Killed, "OnPlayerKilledPost", 1);
    RegisterHookChain(RG_CBasePlayer_TakeDamage, "OnPlayerDamagePost", 1);

    // Round and Score events
    register_logevent("OnRoundStart", 2, "1=Round_Start");
    register_logevent("OnRoundEnd", 2, "1=Round_End");
    register_event("TeamScore", "EventTeamScore", "a");

    get_mapname(g_szCurrentMap, charsmax(g_szCurrentMap));

    set_task(1.0, "TaskInitMatchSession");
}

public TaskInitMatchSession()
{
    get_cvar_string("rsu_sql_prefix", g_szSqlTablePrefix, charsmax(g_szSqlTablePrefix));
    if (!g_szSqlTablePrefix[0])
        copy(g_szSqlTablePrefix, charsmax(g_szSqlTablePrefix), "rsu_");
    g_hSqlTuple = rsu_get_sql_tuple();
    if (g_hSqlTuple == Empty_Handle)
    {
        // Bounded retry: if the RSU database never comes up (down for the
        // whole map) stop re-arming every second - 20 tries ≈ 20s covers a
        // normal core init; a real outage just means no match tracking.
        g_iInitRetries++;
        if (g_iInitRetries <= 20)
        {
            set_task(1.0, "TaskInitMatchSession");
        }
        else
            log_amx("[RSU MATCH] Database unavailable after %d attempts - match tracking disabled for this map.", g_iInitRetries);
        return;
    }

    new iServerId = g_pCvarServerId ? get_pcvar_num(g_pCvarServerId) : 1;

    new szTime[32];
    get_time("%Y-%m-%d %H:%M:%S", szTime, charsmax(szTime));

    new szEscMap[80];
    EscapeSql(szEscMap, charsmax(szEscMap), g_szCurrentMap);

    new szQuery[256];
    formatex(szQuery, charsmax(szQuery),
        "INSERT INTO `%smatches` (`server_id`, `map_name`, `started_at`) VALUES (%d, '%s', '%s');",
        g_szSqlTablePrefix, iServerId, szEscMap, szTime);

    SQL_ThreadQuery(g_hSqlTuple, "ThreadQuery_CreateMatch", szQuery);
}

public ThreadQuery_CreateMatch(iFailState, Handle:hQuery, szError[], iErrorCode, data[], iDataSize)
{
    if (iFailState != TQUERY_SUCCESS)
    {
        log_amx("[RSU MATCH ERROR] Failed to create match session: [%d] %s", iErrorCode, szError);
        return;
    }

    g_iMatchId = SQL_GetInsertId(hQuery);
    log_amx("[RSU MATCH] Active match session registered (ID #%d, Map: %s)", g_iMatchId, g_szCurrentMap);

    rsu_trigger_match_started(g_iMatchId, g_szCurrentMap);
}

public client_putinserver(id)
{
    ResetPlayerMatchStats(id);
    g_iMatchJoinTime[id] = get_systime();
}

public client_disconnected(id)
{
    if (g_iMatchJoinTime[id] > 0)
    {
        g_iMatchPlayedSeconds[id] += (get_systime() - g_iMatchJoinTime[id]);
    }
    if (g_iMatchId > 0 && rsu_is_data_loaded(id))
    {
        SavePlayerMatchRecord(id);
    }
    // Mark the row as finalized for this session: SavePlayerMatchRecord
    // already wrote the additive UPDATE above; the REPLACE below in
    // FinalizeMatchSession will re-write the row, but the cumulative
    // counters were preserved via FlushCumulativeMatchStats.
}

ResetPlayerMatchStats(id)
{
    g_iMatchKills[id] = 0;
    g_iMatchDeaths[id] = 0;
    g_iMatchAssists[id] = 0;
    g_iMatchHeadshots[id] = 0;
    g_iMatchDamage[id] = 0;
    g_iMatchXpEarned[id] = 0;
    g_fMatchSkillDelta[id] = 0.0;
    g_iMatchTeam[id] = _:RSU_TEAM_UNASSIGNED;
    g_iMatchJoinTime[id] = 0;
    g_iMatchPlayedSeconds[id] = 0;
    g_bCumulativeFlushed[id] = false;

    g_iOpeningKills[id] = 0;
    g_iOpeningDeaths[id] = 0;
    g_iTradeKills[id] = 0;
    g_iTimesTraded[id] = 0;
    g_iClutchesWon[id] = 0;
    g_iClutchesAttempted[id] = 0;
    g_iClutchAttempt[id] = 0;
    g_iKastRounds[id] = 0;
    g_iAces[id] = 0;
    g_iKills2K[id] = 0;
    g_iKills3K[id] = 0;
    g_iKills4K[id] = 0;

    g_iRoundKills[id] = 0;
    g_iRoundAssists[id] = 0;
    g_bRoundTraded[id] = false;
    for (new v = 1; v <= MaxClients; v++)
        g_iRoundDmgTo[id][v] = 0;
}

public EventTeamScore()
{
    new szTeam[2];
    read_data(1, szTeam, charsmax(szTeam));
    new iScore = read_data(2);

    if (szTeam[0] == 'T')
    {
        g_iTScore = iScore;
    }
    else if (szTeam[0] == 'C')
    {
        g_iCTScore = iScore;
    }
}

public OnRoundStart()
{
    g_bFirstFragOccurred = false;
    g_iLastKiller = 0;
    g_iLastVictim = 0;
    g_iLastVictimTeam = 0;
    g_fLastKillGametime = 0.0;

    for (new id = 1; id <= MaxClients; id++)
    {
        g_iRoundKills[id] = 0;
        g_iRoundAssists[id] = 0;
        g_bRoundTraded[id] = false;
        g_iClutchAttempt[id] = 0;
        for (new v = 1; v <= MaxClients; v++)
            g_iRoundDmgTo[id][v] = 0;
    }
}

public OnRoundEnd()
{
    if (get_cvar_num("amx_knife_round_active") == 1)
        return;

    g_iRoundsCount++;

    for (new id = 1; id <= MaxClients; id++)
    {
        if (!is_user_connected(id))
            continue;

        // KAST Check: Kill, Assist, Survived, or Traded
        if (g_iRoundKills[id] > 0 || g_iRoundAssists[id] > 0 || is_user_alive(id) || g_bRoundTraded[id])
        {
            g_iKastRounds[id]++;
        }

        // Multikill check
        if (g_iRoundKills[id] == 2)
            g_iKills2K[id]++;
        else if (g_iRoundKills[id] == 3)
            g_iKills3K[id]++;
        else if (g_iRoundKills[id] == 4)
            g_iKills4K[id]++;
        else if (g_iRoundKills[id] >= 5)
            g_iAces[id]++;

        // Clutch won check
        if (g_iClutchAttempt[id] > 0 && is_user_alive(id))
        {
            g_iClutchesWon[id]++;
        }
    }
}

public OnPlayerKilledPost(const victim, const attacker, const iGib)
{
    #pragma unused iGib
    if (get_cvar_num("amx_knife_round_active") == 1)
        return;

    if (!is_user_connected(victim) || !is_user_connected(attacker) || victim == attacker)
        return;

    if (get_user_team(victim) == get_user_team(attacker))
        return;

    g_iMatchKills[attacker]++;
    g_iRoundKills[attacker]++;
    g_iMatchDeaths[victim]++;
    g_iMatchTeam[attacker] = get_user_team(attacker);
    g_iMatchTeam[victim] = get_user_team(victim);

    if (bool:get_member(victim, m_bHeadshotKilled))
    {
        g_iMatchHeadshots[attacker]++;
    }

    // Opening duel tracking
    if (!g_bFirstFragOccurred)
    {
        g_bFirstFragOccurred = true;
        g_iOpeningKills[attacker]++;
        g_iOpeningDeaths[victim]++;
    }

    // Trade kill detection (4.0s window)
    if (g_iLastKiller == victim && (get_gametime() - g_fLastKillGametime <= 4.0) && (get_user_team(attacker) == g_iLastVictimTeam))
    {
        g_iTradeKills[attacker]++;
        if (g_iLastVictim >= 1 && g_iLastVictim <= MaxClients)
        {
            g_iTimesTraded[g_iLastVictim]++;
            g_bRoundTraded[g_iLastVictim] = true;
        }
    }

    g_iLastKiller = attacker;
    g_iLastVictim = victim;
    g_iLastVictimTeam = get_user_team(victim);
    g_fLastKillGametime = get_gametime();

    // Assist feed: anyone with damage on this victim this round, except the killer.
    for (new a = 1; a <= MaxClients; a++)
    {
        if (a == attacker || a == victim || !is_user_connected(a))
            continue;
        if (g_iRoundDmgTo[a][victim] <= 0)
            continue;
        g_iMatchAssists[a]++;
        g_iRoundAssists[a]++;
        g_iRoundDmgTo[a][victim] = 0;
    }

    // Check clutch situations
    CheckClutchSituation();
}

CheckClutchSituation()
{
    new iAliveT = 0, iLastT = 0;
    new iAliveCT = 0, iLastCT = 0;

    for (new i = 1; i <= MaxClients; i++)
    {
        if (is_user_alive(i))
        {
            new iTeam = get_user_team(i);
            if (iTeam == 1)
            {
                if (is_user_bot(i))
                    continue;
                iAliveT++;
                iLastT = i;
            }
            else if (iTeam == 2)
            {
                if (is_user_bot(i))
                    continue;
                iAliveCT++;
                iLastCT = i;
            }
        }
    }

    if (iAliveT == 1 && iAliveCT >= 1 && g_iClutchAttempt[iLastT] == 0)
    {
        g_iClutchAttempt[iLastT] = iAliveCT;
        g_iClutchesAttempted[iLastT]++;
    }

    if (iAliveCT == 1 && iAliveT >= 1 && g_iClutchAttempt[iLastCT] == 0)
    {
        g_iClutchAttempt[iLastCT] = iAliveT;
        g_iClutchesAttempted[iLastCT]++;
    }
}

public OnPlayerDamagePost(const victim, const inflictor, const attacker, const Float:flDamage, const bitsDamageType)
{
    #pragma unused inflictor, bitsDamageType
    if (!is_user_connected(attacker) || !is_user_connected(victim) || attacker == victim)
        return;

    if (get_cvar_num("amx_knife_round_active") == 1)
        return;

    if (get_user_team(victim) == get_user_team(attacker))
        return;

    g_iMatchDamage[attacker] += floatround(flDamage);
    g_iRoundDmgTo[attacker][victim] += floatround(flDamage);
}

public rsu_player_xp_post(id, old_xp, new_xp, amount, RsuXpSource:source)
{
    #pragma unused old_xp, new_xp, source
    if (amount > 0 && id >= 1 && id <= MaxClients)
    {
        g_iMatchXpEarned[id] += amount;
    }
}

public rsu_player_skill_changed(id, Float:old_skill, Float:new_skill)
{
    if (id >= 1 && id <= MaxClients)
    {
        g_fMatchSkillDelta[id] += (new_skill - old_skill);
    }
}

public plugin_end()
{
    FinalizeMatchSession();
}

FinalizeMatchSession()
{
    if (g_iMatchId <= 0 || g_hSqlTuple == Empty_Handle)
        return;

    new iWinner = 0; // undecided / no score yet
    if (g_iTScore > g_iCTScore)
        iWinner = 1;
    else if (g_iCTScore > g_iTScore)
        iWinner = 2;
    else if (g_iTScore > 0 || g_iCTScore > 0)
        iWinner = 3; // scored draw

    new szTime[32];
    get_time("%Y-%m-%d %H:%M:%S", szTime, charsmax(szTime));

    new szQuery[512];
    formatex(szQuery, charsmax(szQuery),
        "UPDATE `%smatches` SET `t_score` = %d, `ct_score` = %d, `winner_team` = %d, \
         `ended_at` = '%s' WHERE `id` = %d;",
        g_szSqlTablePrefix, g_iTScore, g_iCTScore, iWinner, szTime, g_iMatchId);
    SQL_ThreadQuery(g_hSqlTuple, "ThreadQuery_GenericMatch", szQuery);

    // Save each connected player's scorecard
    for (new id = 1; id <= MaxClients; id++)
    {
        if (is_user_connected(id) && rsu_is_data_loaded(id))
        {
            SavePlayerMatchRecord(id);
            if (get_pcvar_num(g_pCvarAutoShowSummary) && !is_user_bot(id))
            {
                CmdShowMatchMotd(id);
            }
        }
    }

    rsu_trigger_match_finished(g_iMatchId, g_iTScore, g_iCTScore, iWinner);
}

SavePlayerMatchRecord(id)
{
    new iDbId = rsu_get_player_database_id(id);
    if (iDbId <= 0 || g_iMatchId <= 0)
        return;

    new iTotalTime = g_iMatchPlayedSeconds[id];
    if (g_iMatchJoinTime[id] > 0)
    {
        iTotalTime += (get_systime() - g_iMatchJoinTime[id]);
    }

    new Float:flADR = (g_iRoundsCount > 0) ? (float(g_iMatchDamage[id]) / float(g_iRoundsCount)) : 0.0;

    new szQuery[1024];
    if (rsu_is_sqlite())
    {
        formatex(szQuery, charsmax(szQuery),
            "INSERT INTO `%smatch_players` (`match_id`, `player_id`, `team`, `kills`, `deaths`, `assists`, `headshots`, `damage`, `xp_earned`, `skill_delta`, `time_played`, `adr`, `kast_rounds`, `opening_kills`, `opening_deaths`, `trade_kills`, `clutches_won`, `aces`) \
             VALUES (%d, %d, %d, %d, %d, %d, %d, %d, %d, %.2f, %d, %.2f, %d, %d, %d, %d, %d, %d) \
             ON CONFLICT(`match_id`, `player_id`) DO UPDATE SET \
              `kills` = `kills` + excluded.`kills`, `deaths` = `deaths` + excluded.`deaths`, `assists` = `assists` + excluded.`assists`, \
              `headshots` = `headshots` + excluded.`headshots`, `damage` = `damage` + excluded.`damage`, `xp_earned` = `xp_earned` + excluded.`xp_earned`, \
              `skill_delta` = `skill_delta` + excluded.`skill_delta`, `time_played` = `time_played` + excluded.`time_played`, \
              `adr` = excluded.`adr`, `kast_rounds` = `kast_rounds` + excluded.`kast_rounds`, \
              `opening_kills` = `opening_kills` + excluded.`opening_kills`, `opening_deaths` = `opening_deaths` + excluded.`opening_deaths`, \
              `trade_kills` = `trade_kills` + excluded.`trade_kills`, `clutches_won` = `clutches_won` + excluded.`clutches_won`, `aces` = `aces` + excluded.`aces`;",
            g_szSqlTablePrefix, g_iMatchId, iDbId, g_iMatchTeam[id] ? g_iMatchTeam[id] : _:RSU_TEAM_SPEC,
            g_iMatchKills[id], g_iMatchDeaths[id], g_iMatchAssists[id], g_iMatchHeadshots[id],
            g_iMatchDamage[id], g_iMatchXpEarned[id], g_fMatchSkillDelta[id], iTotalTime,
            flADR, g_iKastRounds[id], g_iOpeningKills[id], g_iOpeningDeaths[id], g_iTradeKills[id],
            g_iClutchesWon[id], g_iAces[id]);
    }
    else
    {
        formatex(szQuery, charsmax(szQuery),
            "INSERT INTO `%smatch_players` (`match_id`, `player_id`, `team`, `kills`, `deaths`, `assists`, `headshots`, `damage`, `xp_earned`, `skill_delta`, `time_played`, `adr`, `kast_rounds`, `opening_kills`, `opening_deaths`, `trade_kills`, `clutches_won`, `aces`) \
             VALUES (%d, %d, %d, %d, %d, %d, %d, %d, %d, %.2f, %d, %.2f, %d, %d, %d, %d, %d, %d) \
              ON DUPLICATE KEY UPDATE `kills` = `kills` + VALUES(`kills`), `deaths` = `deaths` + VALUES(`deaths`), `assists` = `assists` + VALUES(`assists`), `headshots` = `headshots` + VALUES(`headshots`), \
              `damage` = `damage` + VALUES(`damage`), `xp_earned` = `xp_earned` + VALUES(`xp_earned`), `skill_delta` = `skill_delta` + VALUES(`skill_delta`), `time_played` = `time_played` + VALUES(`time_played`), \
              `adr` = VALUES(`adr`), `kast_rounds` = `kast_rounds` + VALUES(`kast_rounds`), `opening_kills` = `opening_kills` + VALUES(`opening_kills`), `opening_deaths` = `opening_deaths` + VALUES(`opening_deaths`), \
              `trade_kills` = `trade_kills` + VALUES(`trade_kills`), `clutches_won` = `clutches_won` + VALUES(`clutches_won`), `aces` = `aces` + VALUES(`aces`);",
            g_szSqlTablePrefix, g_iMatchId, iDbId, g_iMatchTeam[id] ? g_iMatchTeam[id] : _:RSU_TEAM_SPEC,
            g_iMatchKills[id], g_iMatchDeaths[id], g_iMatchAssists[id], g_iMatchHeadshots[id],
            g_iMatchDamage[id], g_iMatchXpEarned[id], g_fMatchSkillDelta[id], iTotalTime,
            flADR, g_iKastRounds[id], g_iOpeningKills[id], g_iOpeningDeaths[id], g_iTradeKills[id],
            g_iClutchesWon[id], g_iAces[id]);
    }
    SQL_ThreadQuery(g_hSqlTuple, "ThreadQuery_GenericMatch", szQuery);

    PersistPlayerMapStats(id);

    // Update cumulative player stats table (additive; flushed once per
    // session - see FlushCumulativeMatchStats / g_bCumulativeFlushed)
    if (!g_bCumulativeFlushed[id])
    {
        g_bCumulativeFlushed[id] = true;
        FlushCumulativeMatchStats(id);
    }
}

// Additive UPDATE of the lifetime analytics columns for this session. Called
// exactly once per player session: on disconnect before the RAM reset, or on
// match finalize. The g_bCumulativeFlushed guard prevents double-adding the
// same counters when both paths fire for one session.
FlushCumulativeMatchStats(id)
{
    new iDbId = rsu_get_player_database_id(id);
    if (iDbId <= 0 || g_hSqlTuple == Empty_Handle || !g_iMatchId)
        return;

    // REVIEW.md §5.5: this UPDATE used to bind `server_id = 0`, while every other
    // write in the tree (rsu_core.sma:1695,1702,1809,4640 and TaskInitMatchSession
    // below) uses the `rsu_server_id` cvar, default 1. No row has server_id 0, so
    // the lifetime KAST/trade/ace flush silently updated nothing at all.
    new iServerId = g_pCvarServerId ? get_pcvar_num(g_pCvarServerId) : 1;

    new szCumulativeQuery[512];
    formatex(szCumulativeQuery, charsmax(szCumulativeQuery),
        "UPDATE `%splayer_stats` SET `kast_rounds` = `kast_rounds` + %d, `opening_kills` = `opening_kills` + %d, \
         `opening_deaths` = `opening_deaths` + %d, `trade_kills` = `trade_kills` + %d, \
         `clutches_won` = `clutches_won` + %d, `aces` = `aces` + %d \
         WHERE `player_id` = %d AND `server_id` = %d;",
        g_szSqlTablePrefix, g_iKastRounds[id], g_iOpeningKills[id], g_iOpeningDeaths[id],
        g_iTradeKills[id], g_iClutchesWon[id], g_iAces[id], iDbId, iServerId);
    SQL_ThreadQuery(g_hSqlTuple, "ThreadQuery_GenericMatch", szCumulativeQuery);
}

PersistPlayerMapStats(id)
{
    new iDbId = rsu_get_player_database_id(id);
    if (iDbId <= 0 || g_hSqlTuple == Empty_Handle || !g_szCurrentMap[0])
        return;

    new iWinner = 0;
    if (g_iTScore > g_iCTScore) iWinner = 1;
    else if (g_iCTScore > g_iTScore) iWinner = 2;
    else if (g_iTScore > 0 || g_iCTScore > 0) iWinner = 3;

    new iWin = 0, iLoss = 0;
    if (iWinner == 1 || iWinner == 2)
    {
        if (g_iMatchTeam[id] == iWinner) iWin = 1;
        else if (g_iMatchTeam[id] == 1 || g_iMatchTeam[id] == 2) iLoss = 1;
    }

    new szTime[32];
    get_time("%Y-%m-%d %H:%M:%S", szTime, charsmax(szTime));

    new szEscMap[80];
    EscapeSql(szEscMap, charsmax(szEscMap), g_szCurrentMap);

    new szQuery[768];
    if (rsu_is_sqlite())
    {
        formatex(szQuery, charsmax(szQuery),
            "INSERT INTO `%splayer_maps` (player_id, map_name, matches, wins, losses, kills, deaths, assists, headshots, damage, last_played) \
             VALUES (%d, '%s', 1, %d, %d, %d, %d, %d, %d, %d, '%s') \
             ON CONFLICT(player_id, map_name) DO UPDATE SET \
               matches = matches + 1, wins = wins + %d, losses = losses + %d, \
               kills = kills + %d, deaths = deaths + %d, assists = assists + %d, \
               headshots = headshots + %d, damage = damage + %d, last_played = '%s';",
            g_szSqlTablePrefix, iDbId, szEscMap, iWin, iLoss,
            g_iMatchKills[id], g_iMatchDeaths[id], g_iMatchAssists[id], g_iMatchHeadshots[id], g_iMatchDamage[id], szTime,
            iWin, iLoss, g_iMatchKills[id], g_iMatchDeaths[id], g_iMatchAssists[id], g_iMatchHeadshots[id], g_iMatchDamage[id], szTime);
    }
    else
    {
        formatex(szQuery, charsmax(szQuery),
            "INSERT INTO `%splayer_maps` (player_id, map_name, matches, wins, losses, kills, deaths, assists, headshots, damage, last_played) \
             VALUES (%d, '%s', 1, %d, %d, %d, %d, %d, %d, %d, '%s') \
             ON DUPLICATE KEY UPDATE matches = matches + 1, wins = wins + %d, losses = losses + %d, \
               kills = kills + %d, deaths = deaths + %d, assists = assists + %d, \
               headshots = headshots + %d, damage = damage + %d, last_played = '%s';",
            g_szSqlTablePrefix, iDbId, szEscMap, iWin, iLoss,
            g_iMatchKills[id], g_iMatchDeaths[id], g_iMatchAssists[id], g_iMatchHeadshots[id], g_iMatchDamage[id], szTime,
            iWin, iLoss, g_iMatchKills[id], g_iMatchDeaths[id], g_iMatchAssists[id], g_iMatchHeadshots[id], g_iMatchDamage[id], szTime);
    }
    SQL_ThreadQuery(g_hSqlTuple, "ThreadQuery_GenericMatch", szQuery);
}

public ThreadQuery_GenericMatch(iFailState, Handle:hQuery, szError[], iErrorCode, data[], iDataSize)
{
    if (iFailState != TQUERY_SUCCESS)
    {
        log_amx("[RSU MATCH SQL ERROR] Query error: [%d] %s", iErrorCode, szError);
    }
}

public CmdShowMatchMotd(id)
{
    if (!is_user_connected(id))
        return PLUGIN_HANDLED;

    new Float:flNow = get_gametime();
    if (flNow - g_fLastMatchCmd[id] < 2.0)
        return PLUGIN_HANDLED;
    g_fLastMatchCmd[id] = flNow;

    if (g_iMatchId > 0)
    {
        new szMatchStr[16];
        num_to_str(g_iMatchId, szMatchStr, charsmax(szMatchStr));
        rsu_open_motd(id, "match", szMatchStr);
    }
    else
    {
        client_print_color(id, print_team_default, "^4[RSU]^1 No match session currently active.");
    }
    return PLUGIN_HANDLED;
}

// ----------------------------------------------------------------------------
// NATIVE CALLBACKS
// ----------------------------------------------------------------------------
public Float:_rsu_get_match_adr(iPlugin, iParams)
{
    new id = get_param(1);
    if (id < 1 || id > MaxClients)
        return 0.0;
    return (g_iRoundsCount > 0) ? (float(g_iMatchDamage[id]) / float(g_iRoundsCount)) : 0.0;
}

public Float:_rsu_get_match_kast(iPlugin, iParams)
{
    new id = get_param(1);
    if (id < 1 || id > MaxClients)
        return 0.0;
    return (g_iRoundsCount > 0) ? ((float(g_iKastRounds[id]) / float(g_iRoundsCount)) * 100.0) : 0.0;
}

public _rsu_get_match_opening_kills(iPlugin, iParams)
{
    new id = get_param(1);
    return (id >= 1 && id <= MaxClients) ? g_iOpeningKills[id] : 0;
}

public _rsu_get_match_trade_kills(iPlugin, iParams)
{
    new id = get_param(1);
    return (id >= 1 && id <= MaxClients) ? g_iTradeKills[id] : 0;
}

public _rsu_get_match_clutches_won(iPlugin, iParams)
{
    new id = get_param(1);
    return (id >= 1 && id <= MaxClients) ? g_iClutchesWon[id] : 0;
}

public _rsu_get_match_aces(iPlugin, iParams)
{
    new id = get_param(1);
    return (id >= 1 && id <= MaxClients) ? g_iAces[id] : 0;
}
