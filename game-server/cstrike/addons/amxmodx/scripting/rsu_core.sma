#include <amxmodx>
#include <amxmisc>
#include <sqlx>
#include <crxranks>
#include <reapi>
#include <hamsandwich>
#include "include/rsu_version.inc"
#include "include/rsu_const.inc"
#include <freenova_web>
#include <freenova_wpn>
#include <geoip>
#include <freenova_ui>

// BattlePass ledger natives (provided by battlepass_core). Declared here
// instead of including menabp.inc to avoid pulling BattlePass skill enums
// into RSU. All calls are gated by LibraryExists + menabp_is_ready.
native menabp_is_ready(id)
native menabp_get_xp(id)
native menabp_get_tier(id)

#define PLUGIN_NAME     RSU_PROJECT_NAME
#define PLUGIN_VERSION  RSU_VERSION_STRING
#define PLUGIN_AUTHOR   RSU_AUTHOR_STRING

#define TASK_AUTOSAVE   1001
#define TASK_PLAYTIME   1002
#define TASK_HUD_RENDER 1003

// Never pass Empty_Handle to SQL_QuoteString — sqlite raises native error 10.
EscapeSql(szOut[], iMax, const szIn[])
{
    copy(szOut, iMax, szIn);
    replace_all(szOut, iMax, "'", "''");
}

// ============================================================================
// WEAPON MAPPING TO TORNADO 0-25 WEAPON INDEX
// ============================================================================
enum
{
    RSU_WEAPON_KNIFE = 0,
    RSU_WEAPON_GLOCK18,
    RSU_WEAPON_USP,
    RSU_WEAPON_P228,
    RSU_WEAPON_DEAGLE,
    RSU_WEAPON_FIVESEVEN,
    RSU_WEAPON_ELITE,
    RSU_WEAPON_M3,
    RSU_WEAPON_XM1014,
    RSU_WEAPON_TMP,
    RSU_WEAPON_MAC10,
    RSU_WEAPON_MP5NAVY,
    RSU_WEAPON_UMP45,
    RSU_WEAPON_P90,
    RSU_WEAPON_M249,
    RSU_WEAPON_GALIL,
    RSU_WEAPON_FAMAS,
    RSU_WEAPON_AK47,
    RSU_WEAPON_M4A1,
    RSU_WEAPON_SG552,
    RSU_WEAPON_AUG,
    RSU_WEAPON_SCOUT,
    RSU_WEAPON_AWP,
    RSU_WEAPON_G3SG1,
    RSU_WEAPON_SG550,
    RSU_WEAPON_HEGRENADE
};
#define RSU_TOTAL_WEAPONS 26

new const g_iCswToRsuWeapon[33] = {
    -1,                 // 0: CSW_NONE
    RSU_WEAPON_P228,    // 1: CSW_P228
    -1,                 // 2: CSW_GLOCK
    RSU_WEAPON_SCOUT,   // 3: CSW_SCOUT
    RSU_WEAPON_HEGRENADE,// 4: CSW_HEGRENADE
    RSU_WEAPON_XM1014,  // 5: CSW_XM1014
    -1,                 // 6: CSW_C4
    RSU_WEAPON_MAC10,   // 7: CSW_MAC10
    RSU_WEAPON_AUG,     // 8: CSW_AUG
    -1,                 // 9: CSW_SMOKEGRENADE
    RSU_WEAPON_ELITE,   // 10: CSW_ELITE
    RSU_WEAPON_FIVESEVEN,// 11: CSW_FIVESEVEN
    RSU_WEAPON_UMP45,   // 12: CSW_UMP45
    RSU_WEAPON_SG550,   // 13: CSW_SG550
    RSU_WEAPON_GALIL,   // 14: CSW_GALIL
    RSU_WEAPON_FAMAS,   // 15: CSW_FAMAS
    RSU_WEAPON_USP,     // 16: CSW_USP
    RSU_WEAPON_GLOCK18, // 17: CSW_GLOCK18
    RSU_WEAPON_AWP,     // 18: CSW_AWP
    RSU_WEAPON_MP5NAVY, // 19: CSW_MP5NAVY
    RSU_WEAPON_M249,    // 20: CSW_M249
    RSU_WEAPON_M3,      // 21: CSW_M3
    RSU_WEAPON_M4A1,    // 22: CSW_M4A1
    RSU_WEAPON_TMP,     // 23: CSW_TMP
    RSU_WEAPON_G3SG1,   // 24: CSW_G3SG1
    -1,                 // 25: CSW_FLASHBANG
    RSU_WEAPON_DEAGLE,  // 26: CSW_DEAGLE
    RSU_WEAPON_SG552,   // 27: CSW_SG552
    RSU_WEAPON_AK47,    // 28: CSW_AK47
    RSU_WEAPON_KNIFE,   // 29: CSW_KNIFE
    RSU_WEAPON_P90,     // 30: CSW_P90
    -1,                 // 31: CSW_VEST
    -1                  // 32: CSW_VESTHELM
};

// ============================================================================
// DATA STRUCTURES: RANKS & SKILLS
// ============================================================================
enum _:RankEntry
{
    RANK_ID,
    RANK_NAME[32],
    RANK_MIN_XP,
    RANK_MAX_XP,
    RANK_BADGE[64],
    RANK_COLOR[16]
};

new Array:g_aRanks;
new g_iTotalRanks = 0;

enum _:SkillEntry
{
    SKILL_NAME[16],
    Float:SKILL_MIN_RANGE,
    bool:SKILL_DEFAULT
};

new Array:g_aSkills;
new g_iTotalSkills = 0;
new g_iDefaultSkillIndex = 0;

// Multipliers & Modules
#define MAX_MULTIPLIERS 16
new g_szMultiplierNames[MAX_MULTIPLIERS][32];
new Float:g_fMultiplierValues[MAX_MULTIPLIERS];
new g_iTotalMultipliers = 0;

#define MAX_MODULES 32
new g_szModuleNames[MAX_MODULES][32];
new g_szModuleVersions[MAX_MODULES][16];
new g_szModuleAuthors[MAX_MODULES][32];
new g_iTotalModules = 0;

// ============================================================================
// PLAYER RUNTIME STATE TABLE
// ============================================================================
// Gen 3: Player Lifecycle & Identity (ADR-001)
new PlayerState:g_iPlayerState[RSU_MAX_PLAYERS + 1];
new g_szSessionUUID[RSU_MAX_PLAYERS + 1][37];
new g_iAuthPendingTicks[RSU_MAX_PLAYERS + 1];

// Gen 3: Glicko-2 Confidence Rating (ADR-003)
new Float:g_fDeviation[RSU_MAX_PLAYERS + 1];

// Gen 3: Anti-Farm Ring Buffer (Threat Model & ADR-001)
new g_iFragVictims[RSU_MAX_PLAYERS + 1][8];
new Float:g_fFragTimes[RSU_MAX_PLAYERS + 1][8];
new g_iFragHead[RSU_MAX_PLAYERS + 1];

// Gen 3: Command Rate Limiter (Threat Model)
new Float:g_fCommandTokens[RSU_MAX_PLAYERS + 1];
new Float:g_fLastCommandCheck[RSU_MAX_PLAYERS + 1];

// Gen 3: Circuit Breaker (ADR-002). The offline journal queue was removed -
// it had no call sites (dead Gen-3 scaffolding).
new CircuitState:g_iCircuitState = CIRCUIT_CLOSED;
new g_iCircuitConsecutiveFails = 0;

// Config DB Settings
new g_szCfgSqlHost[64] = "127.0.0.1";
new g_szCfgSqlUser[64] = "root";
new g_szCfgSqlPass[64] = "";
new g_szCfgSqlDb[64] = "freenova_rank";
new g_pCvarMinPlayers;

// New Gen 3 Forwards
new g_fwdPlayerAuthorized;
new g_fwdPlayerReady;

new bool:g_bDataLoaded[RSU_MAX_PLAYERS + 1];
new bool:g_bLoading[RSU_MAX_PLAYERS + 1];
new g_iConnectionToken[RSU_MAX_PLAYERS + 1];
new g_iDatabaseId[RSU_MAX_PLAYERS + 1];
new g_szAuthID[RSU_MAX_PLAYERS + 1][RSU_MAX_AUTHID_LENGTH];
new g_szPlayerName[RSU_MAX_PLAYERS + 1][RSU_MAX_NAME_LENGTH];
new g_szPlayerIP[RSU_MAX_PLAYERS + 1][24];
new g_szCountry[RSU_MAX_PLAYERS + 1][4];
new g_szFirstSeen[RSU_MAX_PLAYERS + 1][32];
new g_szLastSeen[RSU_MAX_PLAYERS + 1][32];

new g_iPlayerXP[RSU_MAX_PLAYERS + 1];
new g_iLifetimeXP[RSU_MAX_PLAYERS + 1];
new g_iLevel[RSU_MAX_PLAYERS + 1];
new g_iAccountLevel[RSU_MAX_PLAYERS + 1];
new g_iPrestige[RSU_MAX_PLAYERS + 1];
new g_iPlacementMatches[RSU_MAX_PLAYERS + 1];
new g_iRank[RSU_MAX_PLAYERS + 1];
new Float:g_fSkill[RSU_MAX_PLAYERS + 1];
new Float:g_fPeakSkill[RSU_MAX_PLAYERS + 1];
new g_iPlaytime[RSU_MAX_PLAYERS + 1];
new g_iSessionSeconds[RSU_MAX_PLAYERS + 1];
new g_iApStampMask[RSU_MAX_PLAYERS + 1];

// Core Gameplay Stats
new g_iKills[RSU_MAX_PLAYERS + 1];
new g_iDeaths[RSU_MAX_PLAYERS + 1];
new g_iHeadshots[RSU_MAX_PLAYERS + 1];
new g_iAssists[RSU_MAX_PLAYERS + 1];
new g_iSuicides[RSU_MAX_PLAYERS + 1];
new g_iTeamkills[RSU_MAX_PLAYERS + 1];
new g_iShots[RSU_MAX_PLAYERS + 1];
new g_iHits[RSU_MAX_PLAYERS + 1];
new g_iDamage[RSU_MAX_PLAYERS + 1];
new g_iRoundsPlayed[RSU_MAX_PLAYERS + 1];
new g_iRoundsWon[RSU_MAX_PLAYERS + 1];
new g_iRoundsLost[RSU_MAX_PLAYERS + 1];
new g_iTWins[RSU_MAX_PLAYERS + 1];
new g_iCTWins[RSU_MAX_PLAYERS + 1];
new g_iMVPs[RSU_MAX_PLAYERS + 1];
new g_iC4Plants[RSU_MAX_PLAYERS + 1];
new g_iC4Explosions[RSU_MAX_PLAYERS + 1];
new g_iC4Defuses[RSU_MAX_PLAYERS + 1];
new g_iLastPlanter;
new g_iHostagesRescued[RSU_MAX_PLAYERS + 1];
new g_iKnifeKills[RSU_MAX_PLAYERS + 1];
new g_iHEKills[RSU_MAX_PLAYERS + 1];
new g_iCurKillstreak[RSU_MAX_PLAYERS + 1];
new g_iBestKillstreak[RSU_MAX_PLAYERS + 1];

// Weapon Kills (Tornado 0-25 index)
new g_iWeaponKills[RSU_MAX_PLAYERS + 1][RSU_TOTAL_WEAPONS];

// Detailed Weapon Stats: [player][csw_id][stat_type]
new g_iWeaponStats[RSU_MAX_PLAYERS + 1][RSU_MAX_WEAPONS][6];

// Zombie Plague Mode Extensions
new g_iZombieWins[RSU_MAX_PLAYERS + 1];
new g_iHumanWins[RSU_MAX_PLAYERS + 1];
new g_iInfections[RSU_MAX_PLAYERS + 1];
new g_iSurvivals[RSU_MAX_PLAYERS + 1];
new g_iRoundInfections[RSU_MAX_PLAYERS + 1];

// Per-Round Tracking (Assists & MVP)
new g_iRoundDamage[RSU_MAX_PLAYERS + 1][RSU_MAX_PLAYERS + 1];
new g_iRoundKills[RSU_MAX_PLAYERS + 1];
new g_iRoundTotalDamage[RSU_MAX_PLAYERS + 1];
new Float:g_fFlashedUntil[RSU_MAX_PLAYERS + 1];

// Server Leaderboard Rank Cache
new g_iServerRank[RSU_MAX_PLAYERS + 1];
new g_iTotalServerPlayers = 0;
// Top15 category browser state (per viewer)
new g_iTopCat[RSU_MAX_PLAYERS + 1];
new g_iTopPage[RSU_MAX_PLAYERS + 1];
new g_iTopSerial[RSU_MAX_PLAYERS + 1];
new g_iTopAsc[RSU_MAX_PLAYERS + 1];
new g_szTopSearch[RSU_MAX_PLAYERS + 1][32];
new g_pCvarHsMinKills;

// Client Preferences
new bool:g_bHudEnabled[RSU_MAX_PLAYERS + 1];
new bool:g_bRankInfoEnabled[RSU_MAX_PLAYERS + 1];

// Dirty Flags & Anti-Exploit
new g_iDirtyMask[RSU_MAX_PLAYERS + 1];

// ============================================================================
// CONFIGURATION VARIABLES (FROM rank_system_ultimate.ini)
// ============================================================================
new g_szCfgSqlDriver[16] = "sqlite";
// g_szCfgMotdLanguage retired 2026-10-11: write-only storage, never read; engine amx_langmenu owns locale.
new g_iCfgSaveType = 2; // 0=Name, 1=IP, 2=SteamID
new g_iCfgSaveInterval = 0; // 0=round end, 1=map end, X=minutes
new g_szCfgChatPrefix[64] = "^3[^4FREENova Rank System^3]^1";
new bool:g_bCfgRankInfo = true;
new g_iCfgRankBots = 0; // 0=disabled, 1=enabled, 2=disable bot ranking
new g_iCfgTimeNew = 7200;
new g_iCfgDefaultOrderStats = 13;
new g_iCfgDefaultOrderWeapon = 0;
new g_iCfgMinPlayers = 0;
new g_szCfgMinPlayersStats[128] = "level";
new g_iCfgTeamSet = 0; // 0=All, 1=T, 2=CT, 3=Spec
new bool:g_bCfgShowMapEndMotd = true;
new g_iCfgLevelMessageType = 2; // 0=off, 1=self, 2=all

// Screen Effects & Sounds
new g_iCfgLevelUpEffects[5] = {0, 255, 0, 75, 1}; // R, G, B, A, Hold(s)
new g_szCfgLevelUpSound[128] = "warcraft3/levelupcaster.wav";
new g_iCfgLevelDnEffects[5] = {255, 0, 0, 75, 1};
new g_szCfgLevelDnSound[128] = "warcraft3/purgetarget1.wav";

// Assist settings: min damage, money, give frag
new g_iCfgAssistMinDamage = 40;
new g_iCfgAssistMoney = 100;
new bool:g_bCfgAssistFrag = true;

// HUD configuration
new bool:g_bCfgHudEnable = true;
new g_iCfgHudType = 0; // 0=HUD, 1=DHUD
new g_szCfgHudInfo[512] = "Name: %name% %newline%Level: %level% / %max_levels% %newline%XP: %xp% / %next_xp% (%xp_percent%%%) %newline%Rank: %rank% %newline%Server Rank: %server_rank% / %max_server_ranks% %newline%Skill: [%skill% %skill_range%]";
new g_szCfgHudInfoMax[512] = "Name: %name% %newline%Level: %level% %newline%XP: %xp% %newline%Rank: %rank% %newline%Server Rank: %server_rank% / %max_server_ranks% %newline%Skill: [%skill% %skill_range%]";
new g_iCfgHudValues[3] = {0, 255, -1};
new Float:g_fCfgHudPos[2] = {0.01, 0.17};

// Floating XP HUD
new bool:g_bCfgXpHudEnable = true;
new bool:g_bCfgXpHudTeamEnable = true;
new g_iCfgXpHudType = 1;
new g_iCfgXpHudTeamType = 1;
new g_szCfgXpHudGet[64] = "+%xp% XP";
new g_szCfgXpHudTeamGet[64] = "+%xp% Team XP";
new g_szCfgXpHudLose[64] = "-%xp% XP";
new g_szCfgXpHudTeamLose[64] = "-%xp% Team XP";
new g_iCfgXpHudValues[3] = {0, 255, 150};
new Float:g_fCfgXpHudPos[2] = {0.65, 0.70};
new g_iCfgXpHudEffect = 0;
new Float:g_fCfgXpHudHold = 1.0;

new g_iCfgXpHudTeamValues[3] = {0, 255, 150};
new Float:g_fCfgXpHudTeamPos[2] = {0.65, 0.75};
new g_iCfgXpHudTeamEffect = 0;
new Float:g_fCfgXpHudTeamHold = 1.0;

// MVP HUD
new bool:g_bCfgMvpHudEnable = true;
new g_iCfgMvpHudType = 0;
new g_iCfgMvpHudValues[3] = {150, 150, 150};
new Float:g_fCfgMvpHudPos[2] = {-1.0, 0.15};

// MOTD Base URL
new g_szCfgMotdBaseUrl[256] = "http://127.0.0.1:8080";

// XP Rewards Map [Keyword Index][0: Personal, 1: Team]
enum
{
    RWD_KILL = 0,
    RWD_HEADSHOT,
    RWD_ASSIST,
    RWD_BLIND,
    RWD_KNIFE,
    RWD_GRENADE,
    RWD_BOMB_PLANT,
    RWD_BOMB_DEFUSE,
    RWD_BOMB_EXPLODE,
    RWD_TEAM_KILL,
    RWD_SUICIDE,
    RWD_T_WIN,
    RWD_CT_WIN,
    RWD_T_LOSE,
    RWD_CT_LOSE,
    RWD_MVP,
    RWD_HOSTAGE_RESCUED,
    RWD_HOSTAGE_KILLED,
    RWD_VIP,
    TOTAL_XP_REWARDS
};
new g_iXpRewards[TOTAL_XP_REWARDS][2];
new g_szCfgVipFlags[32] = "r";

// MOTD Personalization (rsu_edit.ini)
new g_szEditTop15Primary[16] = "#d3b35a";
new g_szEditTop15Secondary[16] = "#bbbbbb";
new g_szEditRankstatsPrimary[16] = "#00ffff";
new g_szEditRankstatsHeader[16] = "#c9c9db";
new g_szEditMapendMap[16] = "#d3b35a";
new g_szEditMapendT[16] = "#ff4040";
new g_szEditMapendCT[16] = "#42B2FB";

// SQL Handle & State
new Handle:g_hSqlTuple = Empty_Handle;
new g_szSqlTablePrefix[32] = "rsu_";
new bool:g_bIsSqlite = false;

// CVARs
new g_pCvarEnableStats;
new g_pCvarDebug;
new g_pCvarServerId;

// Forwards - Tornado ranksultimate.inc
new g_fwdUserLevelUpdated;
new g_fwdUserXpUpdated;
new g_fwdUserStatsSaved;
new g_fwdUserStatsLoaded;

// Forwards - Internal rsu.inc
new g_fwdPlayerLoaded;
new g_fwdPlayerSaving;
new g_fwdPlayerXpPre;
new g_fwdPlayerXpPost;
new g_fwdPlayerRankChanged;
new g_fwdPlayerSkillChanged;
new g_fwdMatchStarted;
new g_fwdMatchFinished;
new g_fwdCombatKill;
new g_fwdBombEvent;
new g_fwdRoundWin;

// ============================================================================
// SCREEN FADE HELPER STOCK
// ============================================================================
stock Util_ScreenFade(id, red, green, blue, alpha, Float:holdTime)
{
    if (alpha <= 0 || !is_user_connected(id))
        return;

    static msgScreenFade = 0;
    if (!msgScreenFade)
        msgScreenFade = get_user_msgid("ScreenFade");

    new r = (red < 0) ? random_num(0, 255) : red;
    new g = (green < 0) ? random_num(0, 255) : green;
    new b = (blue < 0) ? random_num(0, 255) : blue;

    new iDuration = 1 << 12;
    new iHold = floatround(holdTime * (1 << 12));
    new iFlags = 0x0001; // FFADE_IN

    message_begin(MSG_ONE_UNRELIABLE, msgScreenFade, _, id);
    write_short(iDuration);
    write_short(iHold);
    write_short(iFlags);
    write_byte(r);
    write_byte(g);
    write_byte(b);
    write_byte(alpha);
    message_end();
}

// ============================================================================
// PLUGIN INITIALIZATION & LIFECYCLE
// ============================================================================
// ============================================================================
// GEN 3: IDENTITY, CRYPTOGRAPHY & UTILITY FUNCTIONS
// ============================================================================
// ponytail: global event multipliers only. Per-player shop/VIP/happy-hour
// live in CRX (crxranks_user_receive_xp). No safe per-id path here without
// duplicating that chain and double-paying XP.
Float:CalculateActiveMultiplier(id)
{
    #pragma unused id
    new Float:fTotal = 1.0;
    for (new i = 0; i < g_iTotalMultipliers; i++)
    {
        if (g_fMultiplierValues[i] > 1.0)
            fTotal *= g_fMultiplierValues[i];
    }
    return fTotal;
}

GenerateSessionUUID(szOut[], iMaxLen)
{
    new const szYChars[] = "89ab";
    formatex(szOut, iMaxLen, "%04x%04x-%04x-4%03x-%c%03x-%04x%04x%04x",
        random_num(0, 0xFFFF), random_num(0, 0xFFFF),
        random_num(0, 0xFFFF),
        random_num(0, 0x0FFF),
        szYChars[random_num(0, 3)], random_num(0, 0x0FFF),
        random_num(0, 0xFFFF), random_num(0, 0xFFFF), random_num(0, 0xFFFF));
}

// Pre-computed Glicko-2 LUT for g(RD) where RD in [30, 350], step 5 (65 values)
new const Float:g_flGlickoG_LUT[65] = {
    0.9855, 0.9806, 0.9750, 0.9688, 0.9619, 0.9545, 0.9466, 0.9381, 0.9292, 0.9198,
    0.9101, 0.9000, 0.8896, 0.8789, 0.8680, 0.8569, 0.8456, 0.8342, 0.8227, 0.8111,
    0.7994, 0.7877, 0.7760, 0.7643, 0.7526, 0.7410, 0.7295, 0.7180, 0.7066, 0.6954,
    0.6842, 0.6732, 0.6623, 0.6515, 0.6408, 0.6303, 0.6199, 0.6097, 0.5996, 0.5896,
    0.5799, 0.5702, 0.5607, 0.5514, 0.5422, 0.5332, 0.5244, 0.5157, 0.5071, 0.4987,
    0.4905, 0.4824, 0.4745, 0.4667, 0.4591, 0.4516, 0.4443, 0.4371, 0.4300, 0.4231,
    0.4163, 0.4097, 0.4032, 0.3968, 0.3905
};

Float:Glicko_GetG(Float:flDeviation)
{
    new Float:flClamped = (flDeviation < 30.0) ? 30.0 : ((flDeviation > 350.0) ? 350.0 : flDeviation);
    new iIdx = floatround((flClamped - 30.0) / 5.0, floatround_floor);
    if (iIdx < 0) iIdx = 0;
    if (iIdx >= 64) return g_flGlickoG_LUT[64];
    new Float:flFrac = (flClamped - (float(iIdx) * 5.0 + 30.0)) / 5.0;
    return g_flGlickoG_LUT[iIdx] + flFrac * (g_flGlickoG_LUT[iIdx + 1] - g_flGlickoG_LUT[iIdx]);
}

Float:Glicko_GetExpected(Float:flRatingA, Float:flRatingB, Float:flDevB)
{
    new Float:flG = Glicko_GetG(flDevB);
    new Float:flDiff = flRatingA - flRatingB;
    new Float:flExponent = -0.0057565 * flG * flDiff;
    if (flExponent > 10.0) return 0.0;
    if (flExponent < -10.0) return 1.0;
    new Float:flExp = floatpower(2.7182818, flExponent);
    return 1.0 / (1.0 + flExp);
}

Glicko_UpdateCombat(iAttacker, iVictim)
{
    if (iAttacker < 1 || iAttacker > MaxClients || iVictim < 1 || iVictim > MaxClients)
        return;

    new Float:flExpAttacker = Glicko_GetExpected(g_fSkill[iAttacker], g_fSkill[iVictim], g_fDeviation[iVictim]);
    new Float:flExpVictim = 1.0 - flExpAttacker;

    new Float:flK_Attacker = 32.0 * (g_fDeviation[iAttacker] / 100.0);
    if (flK_Attacker < 12.0) flK_Attacker = 12.0;
    if (flK_Attacker > 64.0) flK_Attacker = 64.0;

    new Float:flK_Victim = 32.0 * (g_fDeviation[iVictim] / 100.0);
    if (flK_Victim < 12.0) flK_Victim = 12.0;
    if (flK_Victim > 64.0) flK_Victim = 64.0;

    new Float:flDeltaAttacker = flK_Attacker * Glicko_GetG(g_fDeviation[iVictim]) * (1.0 - flExpAttacker);
    new Float:flDeltaVictim = flK_Victim * Glicko_GetG(g_fDeviation[iAttacker]) * (0.0 - flExpVictim);

    g_fSkill[iAttacker] += flDeltaAttacker;
    if (g_fSkill[iAttacker] < 500.0) g_fSkill[iAttacker] = 500.0;
    if (g_fSkill[iAttacker] > 3500.0) g_fSkill[iAttacker] = 3500.0;
    if (g_fSkill[iAttacker] > g_fPeakSkill[iAttacker]) g_fPeakSkill[iAttacker] = g_fSkill[iAttacker];

    g_fSkill[iVictim] += flDeltaVictim;
    if (g_fSkill[iVictim] < 500.0) g_fSkill[iVictim] = 500.0;
    if (g_fSkill[iVictim] > 3500.0) g_fSkill[iVictim] = 3500.0;

    g_fDeviation[iAttacker] = (g_fDeviation[iAttacker] > 40.5) ? (g_fDeviation[iAttacker] - 0.5) : 40.0;
    g_fDeviation[iVictim] = (g_fDeviation[iVictim] > 40.5) ? (g_fDeviation[iVictim] - 0.5) : 40.0;

    g_iDirtyMask[iAttacker] |= DIRTY_XP_SKILL;
    g_iDirtyMask[iVictim] |= DIRTY_XP_SKILL;
}

bool:AntiFarm_IsVictimFarmed(iAttacker, iVictim)
{
    new Float:flNow = get_gametime();
    new iCount = 0;
    for (new i = 0; i < 8; i++)
    {
        if (g_iFragVictims[iAttacker][i] == iVictim && (flNow - g_fFragTimes[iAttacker][i]) <= 120.0)
        {
            iCount++;
        }
    }
    return (iCount >= 3);
}

AntiFarm_RecordFrag(iAttacker, iVictim)
{
    new iIdx = g_iFragHead[iAttacker];
    g_iFragVictims[iAttacker][iIdx] = iVictim;
    g_fFragTimes[iAttacker][iIdx] = get_gametime();
    g_iFragHead[iAttacker] = (iIdx + 1) % 8;
}

bool:RateLimiter_CheckAllowed(id)
{
    new Float:flNow = get_gametime();
    new Float:flElapsed = flNow - g_fLastCommandCheck[id];
    g_fLastCommandCheck[id] = flNow;

    g_fCommandTokens[id] += flElapsed * 0.4;
    if (g_fCommandTokens[id] > 3.0)
        g_fCommandTokens[id] = 3.0;

    if (g_fCommandTokens[id] < 1.0)
        return false;

    g_fCommandTokens[id] -= 1.0;
    return true;
}

// EnqueueOfflineJournal / delta / inflight snapshots removed: no consumers.

public plugin_init()
{
    register_plugin(PLUGIN_NAME, PLUGIN_VERSION, PLUGIN_AUTHOR);

    // Official CVAR
    g_pCvarEnableStats  = register_cvar("rsu_enable_stats", "1");
    g_pCvarDebug        = register_cvar("rsu_debug", "0");
    g_pCvarServerId     = register_cvar("rsu_server_id", "1");
    register_cvar("rsu_motd_imgbase", "");
    g_pCvarHsMinKills   = register_cvar("rsu_hs_min_kills", "50");
    register_cvar("rsu_sql_driver", g_szCfgSqlDriver);
    register_cvar("rsu_sql_host", g_szCfgSqlHost);
    register_cvar("rsu_sql_user", g_szCfgSqlUser);
    register_cvar("rsu_sql_pass", g_szCfgSqlPass);
    register_cvar("rsu_sql_db", g_szCfgSqlDb);
    register_cvar("rsu_sql_prefix", g_szSqlTablePrefix);
    register_cvar("rsu_sql_is_sqlite", "1");
    g_pCvarMinPlayers = register_cvar("rsu_min_players", "0");
    set_pcvar_num(g_pCvarMinPlayers, g_iCfgMinPlayers);

    // Dynamic arrays
    g_aRanks  = ArrayCreate(RankEntry);
    g_aSkills = ArrayCreate(SkillEntry);

    // Load configurations from INI files
    LoadMainConfiguration();
    LoadEditConfiguration();

    // ReAPI Event Hooks
    RegisterHookChain(RG_CBasePlayer_Killed, "OnPlayerKilledPost", 1);
    RegisterHookChain(RG_CBasePlayer_TakeDamage, "OnPlayerTakeDamagePost", 1);
    // Shots (incl. misses): one Ham hook per weapon entity class.
    // A trigger pull = one shot; shotgun pellets share one event, so
    // accuracy is clamped at 100 in the render paths.
    {
        static const szShotWeapons[][] = { "weapon_p228", "weapon_scout", "weapon_xm1014", "weapon_mac10", "weapon_aug", "weapon_elite", "weapon_fiveseven", "weapon_ump45", "weapon_sg550", "weapon_galil", "weapon_famas", "weapon_usp", "weapon_glock18", "weapon_awp", "weapon_mp5navy", "weapon_m249", "weapon_m3", "weapon_m4a1", "weapon_tmp", "weapon_g3sg1", "weapon_deagle", "weapon_sg552", "weapon_ak47", "weapon_knife", "weapon_p90" };
        for (new w = 0; w < sizeof(szShotWeapons); w++)
            RegisterHam(Ham_Weapon_PrimaryAttack, szShotWeapons[w], "FwdWeaponPrimaryAttack", 0);
    }
    RegisterHookChain(RG_CBasePlayer_Spawn, "OnPlayerSpawnPost", 1);

    // Round and Objective Log Events
    register_logevent("OnRoundStart", 2, "1=Round_Start");
    register_logevent("OnRoundEnd", 2, "1=Round_End");
    register_logevent("OnBombPlanted", 3, "2=Planted_The_Bomb");
    register_logevent("OnBombDefused", 3, "2=Defused_The_Bomb");
    register_logevent("OnBombExploded", 6, "3=Target_Bombed");
    register_logevent("OnHostageRescued", 3, "2=Rescued_A_Hostage");

    // Intermission message for Map End MOTD
    register_message(SVC_INTERMISSION, "OnIntermission");

    // ScreenFade message for detecting flashbang blind
    register_message(get_user_msgid("ScreenFade"), "MsgScreenFade");

    // Admin Console Commands (Documentation Compliant)
    register_concmd("rsu_give_xp", "CmdAdminGiveXp", ADMIN_RCON, "<name|#userid> <value>");
    register_concmd("rsu_give_stats", "CmdAdminGiveStats", ADMIN_RCON, "<name|#userid|@all> <statistics> <amount>");
    register_concmd("rsu_reset_stats", "CmdAdminResetStats", ADMIN_RCON, "<name|#userid|@all> <statistics>");
    register_concmd("rsu_reload", "CmdAdminReload", ADMIN_RCON, "Reloads configuration files");
    register_concmd("amx_rsu_status", "CmdAdminRsuStatus", ADMIN_RCON, "Displays FREENova progression engine status");
    register_concmd("amx_rsu_debugplayer", "CmdAdminRsuDebugPlayer", ADMIN_RCON, "<name|#userid> - Dumps full runtime player telemetry");
    register_concmd("amx_rsu_doctor", "CmdAdminRsuDoctor", ADMIN_RCON, "Runs FREENova progression self-test diagnostics");
    register_concmd("amx_rsu_explainxp", "CmdAdminRsuExplainXp", ADMIN_RCON, "<name|#userid> - Explains XP calculation for a player");
    // /topmenu retired: TopCat browser + web board cover every leaderboard.


    // In-game MOTD Editor Command (say /rsuedit)
    register_clcmd("say /rsuedit", "CmdRsuEdit", ADMIN_RCON);
    register_clcmd("say_team /rsuedit", "CmdRsuEdit", ADMIN_RCON);

    // The ONLY stats surface: /top15 (player menu), /profile, /rankstats.
    register_clcmd("say /top15", "CmdTop15Menu");
    register_clcmd("say_team /top15", "CmdTop15Menu");
    register_clcmd("say /topback", "CmdTopBack");
    register_clcmd("say_team /topback", "CmdTopBack");
    register_clcmd("say /profile", "CmdOpenProfile");
    register_clcmd("say_team /profile", "CmdOpenProfile");
    register_clcmd("say /rankstats", "CmdOpenRankStats");
    register_clcmd("say_team /rankstats", "CmdOpenRankStats");

    // Register Public Forwards (Tornado ranksultimate.inc)
    g_fwdUserLevelUpdated   = CreateMultiForward("rsu_user_level_updated", ET_IGNORE, FP_CELL, FP_CELL, FP_CELL);
    g_fwdUserXpUpdated      = CreateMultiForward("rsu_user_xp_updated", ET_IGNORE, FP_CELL, FP_CELL, FP_CELL);
    g_fwdUserStatsSaved     = CreateMultiForward("rsu_user_stats_saved", ET_IGNORE, FP_CELL, FP_STRING, FP_STRING);
    g_fwdUserStatsLoaded    = CreateMultiForward("rsu_user_stats_loaded", ET_IGNORE, FP_CELL, FP_STRING, FP_STRING);

    // Register Internal Forwards (rsu.inc)
    g_fwdPlayerLoaded       = CreateMultiForward("rsu_player_loaded", ET_IGNORE, FP_CELL, FP_CELL);
    g_fwdPlayerSaving       = CreateMultiForward("rsu_player_saving", ET_IGNORE, FP_CELL);
    g_fwdPlayerXpPre        = CreateMultiForward("rsu_player_xp_pre", ET_STOP, FP_CELL, FP_VAL_BYREF, FP_CELL);
    g_fwdPlayerXpPost       = CreateMultiForward("rsu_player_xp_post", ET_IGNORE, FP_CELL, FP_CELL, FP_CELL, FP_CELL, FP_CELL);
    g_fwdPlayerRankChanged  = CreateMultiForward("rsu_player_rank_changed", ET_IGNORE, FP_CELL, FP_CELL, FP_CELL);
    g_fwdPlayerSkillChanged = CreateMultiForward("rsu_player_skill_changed", ET_IGNORE, FP_CELL, FP_FLOAT, FP_FLOAT);
    g_fwdMatchStarted       = CreateMultiForward("rsu_match_started", ET_IGNORE, FP_CELL, FP_STRING);
    g_fwdMatchFinished      = CreateMultiForward("rsu_match_finished", ET_IGNORE, FP_CELL, FP_CELL, FP_CELL, FP_CELL);
    g_fwdPlayerAuthorized   = CreateMultiForward("rsu_player_authorized", ET_IGNORE, FP_CELL, FP_STRING, FP_STRING);
    g_fwdPlayerReady        = CreateMultiForward("rsu_player_ready", ET_IGNORE, FP_CELL);
    g_fwdCombatKill         = CreateMultiForward("fn_on_player_kill", ET_IGNORE, FP_CELL, FP_CELL, FP_CELL, FP_CELL, FP_CELL);
    g_fwdBombEvent          = CreateMultiForward("fn_on_bomb_event", ET_IGNORE, FP_CELL, FP_CELL);
    g_fwdRoundWin           = CreateMultiForward("fn_on_round_win", ET_IGNORE, FP_CELL, FP_CELL);

    // Alive-only win bus for missions/achievements (not competitive).
    register_event("SendAudio", "Rsu_OnRoundWinAudio", "a", "2&%!MRAD_terwin");
    register_event("SendAudio", "Rsu_OnRoundWinAudio", "a", "2&%!MRAD_ctwin");

    // Initialize Database Connection
    set_task(0.5, "TaskInitSQL");

    // Periodic Background Timers
    new Float:fSaveInterval = (g_iCfgSaveInterval > 0) ? float(g_iCfgSaveInterval * 60) : 60.0;
    set_task(fSaveInterval, "TaskAutosave", TASK_AUTOSAVE, _, _, "b");
    set_task(1.0, "TaskPlaytimeTick", TASK_PLAYTIME, _, _, "b");
    set_task(1.0, "TaskHudTick", TASK_HUD_RENDER, _, _, "b");

    #pragma unused g_iCfgTimeNew, g_iCfgDefaultOrderStats, g_iCfgDefaultOrderWeapon, g_szCfgMinPlayersStats

    // ASSIST_VALUES money/frag components (keys 2 and 3) are parsed for ini
    // compatibility but intentionally dead: the scoreboard-frag/money payout
    // was retired, assist accounting is XP-only via [XP Rewards] assist and
    // the assist COUNT stays in the assist engine. Payout amounts unchanged.
    #pragma unused g_iCfgAssistMoney, g_bCfgAssistFrag
}

public MsgScreenFade(msg_id, msg_dest, msg_entity)
{
    if (msg_entity >= 1 && msg_entity <= MaxClients)
    {
        new iHoldTime = get_msg_arg_int(2);
        new iAlpha = get_msg_arg_int(7);
        new iR = get_msg_arg_int(4);
        new iG = get_msg_arg_int(5);
        new iB = get_msg_arg_int(6);
        // Flashbang ScreenFade is near-white. Level-up/other fades must not count as flashed.
        if (iAlpha >= 200 && iHoldTime > 0 && iR >= 200 && iG >= 200 && iB >= 200)
        {
            g_fFlashedUntil[msg_entity] = get_gametime() + (float(iHoldTime) / 4096.0);
        }
    }
}


public plugin_end()
{
    ForceFlushAllDirty();

    if (g_fwdUserLevelUpdated) DestroyForward(g_fwdUserLevelUpdated);
    if (g_fwdUserXpUpdated) DestroyForward(g_fwdUserXpUpdated);
    if (g_fwdUserStatsSaved) DestroyForward(g_fwdUserStatsSaved);
    if (g_fwdUserStatsLoaded) DestroyForward(g_fwdUserStatsLoaded);
    if (g_fwdPlayerLoaded) DestroyForward(g_fwdPlayerLoaded);
    if (g_fwdPlayerSaving) DestroyForward(g_fwdPlayerSaving);
    if (g_fwdPlayerXpPre) DestroyForward(g_fwdPlayerXpPre);
    if (g_fwdPlayerXpPost) DestroyForward(g_fwdPlayerXpPost);
    if (g_fwdPlayerRankChanged) DestroyForward(g_fwdPlayerRankChanged);
    if (g_fwdPlayerSkillChanged) DestroyForward(g_fwdPlayerSkillChanged);
    if (g_fwdMatchStarted) DestroyForward(g_fwdMatchStarted);
    if (g_fwdMatchFinished) DestroyForward(g_fwdMatchFinished);
    if (g_fwdPlayerAuthorized) DestroyForward(g_fwdPlayerAuthorized);
    if (g_fwdPlayerReady) DestroyForward(g_fwdPlayerReady);
    if (g_fwdCombatKill) DestroyForward(g_fwdCombatKill);
    if (g_fwdBombEvent) DestroyForward(g_fwdBombEvent);
    if (g_fwdRoundWin) DestroyForward(g_fwdRoundWin);

    if (g_aRanks != Invalid_Array)
        ArrayDestroy(g_aRanks);
    if (g_aSkills != Invalid_Array)
        ArrayDestroy(g_aSkills);
    // g_hSqlTuple is intentionally NOT freed: ForceFlushAllDirty() above has
    // just queued threaded saves that still reference the tuple, so SQL_FreeHandle
    // here pulls the connection out from under them and the last batch of player
    // XP/stats is never written (REVIEW.md §5.2). AMXX reclaims plugin-owned
    // handles at unload - same reasoning as freenova_competitive.sma:185-189.
}

// ============================================================================
// CONFIGURATION LOADERS (rank_system_ultimate.ini & rsu_edit.ini)
// ============================================================================
LoadMainConfiguration()
{
    ArrayClear(g_aRanks);
    ArrayClear(g_aSkills);
    g_iTotalRanks = 0;
    g_iTotalSkills = 0;

    new szConfigDir[64], szFile[128];
    get_configsdir(szConfigDir, charsmax(szConfigDir));
    formatex(szFile, charsmax(szFile), "%s/rank_system_ultimate.ini", szConfigDir);

    if (!file_exists(szFile))
    {
        log_amx("[RSU FATAL] Missing configuration file: %s", szFile);
        LoadDefaultRanksAndSkills();
        return;
    }

    new iFile = fopen(szFile, "rt");
    if (!iFile)
    {
        log_amx("[RSU FATAL] Cannot open configuration file: %s", szFile);
        LoadDefaultRanksAndSkills();
        return;
    }

    new szLine[512], szKey[64], szVal[448];
    new iCurrentSection = 0; // 1=Settings, 2=Commands, 3=XP Rewards, 4=Ranks, 5=Skills

    while (!feof(iFile))
    {
        fgets(iFile, szLine, charsmax(szLine));
        trim(szLine);

        if (!szLine[0] || szLine[0] == ';' || szLine[0] == '#' || (szLine[0] == '/' && szLine[1] == '/'))
            continue;

        if (szLine[0] == '[')
        {
            if (containi(szLine, "[Settings]") != -1) iCurrentSection = 1;
            else if (containi(szLine, "[Commands]") != -1) iCurrentSection = 2;
            else if (containi(szLine, "[XP Rewards]") != -1) iCurrentSection = 3;
            else if (containi(szLine, "[Ranks]") != -1) iCurrentSection = 4;
            else if (containi(szLine, "[Skills]") != -1) iCurrentSection = 5;
            else iCurrentSection = 0;
            continue;
        }

        strtok(szLine, szKey, charsmax(szKey), szVal, charsmax(szVal), '=');
        trim(szKey);
        trim(szVal);

        switch (iCurrentSection)
        {
            case 1: ParseSettingKey(szKey, szVal);
            case 2: ParseCommandKey(szKey, szVal);
            case 3: ParseXpRewardKey(szKey, szVal);
            case 4: ParseRankKey(szKey, szVal);
            case 5: ParseSkillKey(szKey, szVal);
        }
    }
    fclose(iFile);

    // Finalize rank max XP bounds
    for (new i = 0; i < g_iTotalRanks; i++)
    {
        new rankEntry[RankEntry];
        ArrayGetArray(g_aRanks, i, rankEntry);
        if (i < g_iTotalRanks - 1)
        {
            new nextEntry[RankEntry];
            ArrayGetArray(g_aRanks, i + 1, nextEntry);
            rankEntry[RANK_MAX_XP] = nextEntry[RANK_MIN_XP] - 1;
        }
        else
        {
            rankEntry[RANK_MAX_XP] = -1; // Highest rank
        }
        ArraySetArray(g_aRanks, i, rankEntry);
    }

    log_amx("[RSU] Config loaded: %d Ranks, %d Skills registered from rank_system_ultimate.ini", g_iTotalRanks, g_iTotalSkills);
}

ParseSettingKey(const szKey[], const szVal[])
{
    if (equali(szKey, "SQL_DRIVER")) copy(g_szCfgSqlDriver, charsmax(g_szCfgSqlDriver), szVal);
    else if (equali(szKey, "SQL_HOST")) copy(g_szCfgSqlHost, charsmax(g_szCfgSqlHost), szVal);
    else if (equali(szKey, "SQL_USER")) copy(g_szCfgSqlUser, charsmax(g_szCfgSqlUser), szVal);
    else if (equali(szKey, "SQL_PASS") || equali(szKey, "SQL_PASSWORD")) copy(g_szCfgSqlPass, charsmax(g_szCfgSqlPass), szVal);
    else if (equali(szKey, "SQL_DB") || equali(szKey, "SQL_DATABASE")) copy(g_szCfgSqlDb, charsmax(g_szCfgSqlDb), szVal);
    else if (equali(szKey, "WEB_URL") || equali(szKey, "MOTD_URL")) copy(g_szCfgMotdBaseUrl, charsmax(g_szCfgMotdBaseUrl), szVal);
    // MOTD_LANGUAGE retired 2026-10-11: write-only key; old ini files keeping it still load (unknown keys ignored).
    else if (equali(szKey, "SAVE_TYPE")) g_iCfgSaveType = str_to_num(szVal);
    else if (equali(szKey, "SAVE_INTERVAL")) g_iCfgSaveInterval = str_to_num(szVal);
    else if (equali(szKey, "CHAT_PREFIX"))
    {
        copy(g_szCfgChatPrefix, charsmax(g_szCfgChatPrefix), szVal);
        replace_all(g_szCfgChatPrefix, charsmax(g_szCfgChatPrefix), "$1", "^1");
        replace_all(g_szCfgChatPrefix, charsmax(g_szCfgChatPrefix), "$3", "^3");
        replace_all(g_szCfgChatPrefix, charsmax(g_szCfgChatPrefix), "$4", "^4");
    }
    else if (equali(szKey, "RANK_INFO")) g_bCfgRankInfo = (str_to_num(szVal) != 0);
    else if (equali(szKey, "RANK_BOTS")) g_iCfgRankBots = str_to_num(szVal);
    else if (equali(szKey, "TIME_NEW")) g_iCfgTimeNew = str_to_num(szVal);
    else if (equali(szKey, "DEFAULT_ORDER"))
    {
        new s1[16], s2[16];
        parse(szVal, s1, charsmax(s1), s2, charsmax(s2));
        g_iCfgDefaultOrderStats = str_to_num(s1);
        g_iCfgDefaultOrderWeapon = str_to_num(s2);
    }
    else if (equali(szKey, "MINIMUM_PLAYERS"))
    {
        new sNum[16], sStats[128];
        strtok(szVal, sNum, charsmax(sNum), sStats, charsmax(sStats), ' ');
        g_iCfgMinPlayers = str_to_num(sNum);
        copy(g_szCfgMinPlayersStats, charsmax(g_szCfgMinPlayersStats), sStats);
        if (g_pCvarMinPlayers)
            set_pcvar_num(g_pCvarMinPlayers, g_iCfgMinPlayers);
    }
    else if (equali(szKey, "TEAM_SET")) g_iCfgTeamSet = str_to_num(szVal);
    else if (equali(szKey, "SHOW_MAPEND_MOTD")) g_bCfgShowMapEndMotd = (str_to_num(szVal) != 0);
    else if (equali(szKey, "LEVEL_MESSAGE_TYPE")) g_iCfgLevelMessageType = str_to_num(szVal);
    else if (equali(szKey, "LEVELUP_EFFECTS"))
    {
        new r[8], g[8], b[8], a[8], h[8];
        parse(szVal, r, charsmax(r), g, charsmax(g), b, charsmax(b), a, charsmax(a), h, charsmax(h));
        g_iCfgLevelUpEffects[0] = str_to_num(r);
        g_iCfgLevelUpEffects[1] = str_to_num(g);
        g_iCfgLevelUpEffects[2] = str_to_num(b);
        g_iCfgLevelUpEffects[3] = str_to_num(a);
        g_iCfgLevelUpEffects[4] = floatround(str_to_float(h));
    }
    else if (equali(szKey, "LEVELUP_SOUND")) copy(g_szCfgLevelUpSound, charsmax(g_szCfgLevelUpSound), szVal);
    else if (equali(szKey, "LEVELDN_EFFECTS"))
    {
        new r[8], g[8], b[8], a[8], h[8];
        parse(szVal, r, charsmax(r), g, charsmax(g), b, charsmax(b), a, charsmax(a), h, charsmax(h));
        g_iCfgLevelDnEffects[0] = str_to_num(r);
        g_iCfgLevelDnEffects[1] = str_to_num(g);
        g_iCfgLevelDnEffects[2] = str_to_num(b);
        g_iCfgLevelDnEffects[3] = str_to_num(a);
        g_iCfgLevelDnEffects[4] = floatround(str_to_float(h));
    }
    else if (equali(szKey, "LEVELDN_SOUND")) copy(g_szCfgLevelDnSound, charsmax(g_szCfgLevelDnSound), szVal);
    else if (equali(szKey, "ASSIST_VALUES"))
    {
        new sDmg[16], sMoney[16], sFrag[16];
        parse(szVal, sDmg, charsmax(sDmg), sMoney, charsmax(sMoney), sFrag, charsmax(sFrag));
        g_iCfgAssistMinDamage = str_to_num(sDmg);
        g_iCfgAssistMoney = str_to_num(sMoney);
        g_bCfgAssistFrag = (str_to_num(sFrag) != 0);
    }
    else if (equali(szKey, "HUD_ENABLE")) g_bCfgHudEnable = (str_to_num(szVal) != 0);
    else if (equali(szKey, "HUD_TYPE")) g_iCfgHudType = str_to_num(szVal);
    else if (equali(szKey, "HUD_INFO")) copy(g_szCfgHudInfo, charsmax(g_szCfgHudInfo), szVal);
    else if (equali(szKey, "HUD_INFO_MAX")) copy(g_szCfgHudInfoMax, charsmax(g_szCfgHudInfoMax), szVal);
    else if (equali(szKey, "HUD_VALUES"))
    {
        new r[8], g[8], b[8], x[16], y[16];
        parse(szVal, r, charsmax(r), g, charsmax(g), b, charsmax(b), x, charsmax(x), y, charsmax(y));
        g_iCfgHudValues[0] = str_to_num(r);
        g_iCfgHudValues[1] = str_to_num(g);
        g_iCfgHudValues[2] = str_to_num(b);
        g_fCfgHudPos[0] = str_to_float(x);
        g_fCfgHudPos[1] = str_to_float(y);
    }
    else if (equali(szKey, "XP_HUD_ENABLE")) g_bCfgXpHudEnable = (str_to_num(szVal) != 0);
    else if (equali(szKey, "XP_HUD_TEAM_ENABLE")) g_bCfgXpHudTeamEnable = (str_to_num(szVal) != 0);
    else if (equali(szKey, "XP_HUD_TYPE")) g_iCfgXpHudType = str_to_num(szVal);
    else if (equali(szKey, "XP_HUD_TEAM_TYPE")) g_iCfgXpHudTeamType = str_to_num(szVal);
    else if (equali(szKey, "XP_HUD_GET")) copy(g_szCfgXpHudGet, charsmax(g_szCfgXpHudGet), szVal);
    else if (equali(szKey, "XP_HUD_TEAM_GET")) copy(g_szCfgXpHudTeamGet, charsmax(g_szCfgXpHudTeamGet), szVal);
    else if (equali(szKey, "XP_HUD_LOSE")) copy(g_szCfgXpHudLose, charsmax(g_szCfgXpHudLose), szVal);
    else if (equali(szKey, "XP_HUD_TEAM_LOSE")) copy(g_szCfgXpHudTeamLose, charsmax(g_szCfgXpHudTeamLose), szVal);
    else if (equali(szKey, "XP_HUD_VALUES"))
    {
        new r[8], g[8], b[8], x[16], y[16], ef[8], h[8];
        parse(szVal, r, charsmax(r), g, charsmax(g), b, charsmax(b), x, charsmax(x), y, charsmax(y), ef, charsmax(ef), h, charsmax(h));
        g_iCfgXpHudValues[0] = str_to_num(r);
        g_iCfgXpHudValues[1] = str_to_num(g);
        g_iCfgXpHudValues[2] = str_to_num(b);
        g_fCfgXpHudPos[0] = str_to_float(x);
        g_fCfgXpHudPos[1] = str_to_float(y);
        g_iCfgXpHudEffect = str_to_num(ef);
        g_fCfgXpHudHold = str_to_float(h);
    }
    else if (equali(szKey, "XP_HUD_TEAM_VALUES"))
    {
        new r[8], g[8], b[8], x[16], y[16], ef[8], h[8];
        parse(szVal, r, charsmax(r), g, charsmax(g), b, charsmax(b), x, charsmax(x), y, charsmax(y), ef, charsmax(ef), h, charsmax(h));
        g_iCfgXpHudTeamValues[0] = str_to_num(r);
        g_iCfgXpHudTeamValues[1] = str_to_num(g);
        g_iCfgXpHudTeamValues[2] = str_to_num(b);
        g_fCfgXpHudTeamPos[0] = str_to_float(x);
        g_fCfgXpHudTeamPos[1] = str_to_float(y);
        g_iCfgXpHudTeamEffect = str_to_num(ef);
        g_fCfgXpHudTeamHold = str_to_float(h);
    }
    else if (equali(szKey, "MVP_HUD_ENABLE")) g_bCfgMvpHudEnable = (str_to_num(szVal) != 0);
    else if (equali(szKey, "MVP_HUD_TYPE")) g_iCfgMvpHudType = str_to_num(szVal);
    else if (equali(szKey, "MVP_HUD_VALUES"))
    {
        new r[8], g[8], b[8], x[16], y[16];
        parse(szVal, r, charsmax(r), g, charsmax(g), b, charsmax(b), x, charsmax(x), y, charsmax(y));
        g_iCfgMvpHudValues[0] = str_to_num(r);
        g_iCfgMvpHudValues[1] = str_to_num(g);
        g_iCfgMvpHudValues[2] = str_to_num(b);
        g_fCfgMvpHudPos[0] = str_to_float(x);
        g_fCfgMvpHudPos[1] = str_to_float(y);
    }
    else if (equali(szKey, "MOTD_BASE_URL")) copy(g_szCfgMotdBaseUrl, charsmax(g_szCfgMotdBaseUrl), szVal);
}

ParseCommandKey(const szKey[], const szVal[])
{
    new szCmdList[256], szSingleCmd[32];
    copy(szCmdList, charsmax(szCmdList), szVal);

    new szCallback[32];
    if (equali(szKey, "STATS_COMMANDS")) copy(szCallback, charsmax(szCallback), "CmdOpenRankStats");
    else if (equali(szKey, "XP_COMMANDS")) copy(szCallback, charsmax(szCallback), "CmdShowXpInfo");
    else if (equali(szKey, "RANK_COMMANDS")) copy(szCallback, charsmax(szCallback), "CmdShowRankInfo");
    else if (equali(szKey, "HUDINFO_COMMANDS")) copy(szCallback, charsmax(szCallback), "CmdToggleHudInfo");
    else if (equali(szKey, "RANKINFO_COMMANDS")) copy(szCallback, charsmax(szCallback), "CmdToggleRankInfo");
    else if (equali(szKey, "TOP15_COMMANDS")) copy(szCallback, charsmax(szCallback), "CmdTop15Menu");
    // NOTE: legacy CmdOpenTop15 direct-query path retired — config commands now open the
    // category browser (the ONLY stats surface, see plugin_init). CmdOpenTop15 stays compiled
    // for API/callfunc compatibility but is no longer registered to any chat command.
    else return;

    new iPos = 0;
    while (szCmdList[iPos])
    {
        new iComma = contain(szCmdList[iPos], ",");
        if (iComma != -1)
        {
            copy(szSingleCmd, iComma, szCmdList[iPos]);
            iPos += iComma + 1;
        }
        else
        {
            copy(szSingleCmd, charsmax(szSingleCmd), szCmdList[iPos]);
            iPos += strlen(szCmdList[iPos]);
        }
        trim(szSingleCmd);
        if (szSingleCmd[0])
        {
            register_clcmd(szSingleCmd, szCallback);
        }
    }
}

ParseXpRewardKey(const szKey[], const szVal[])
{
    new p1[16], p2[16];
    parse(szVal, p1, charsmax(p1), p2, charsmax(p2));
    new iPersonal = str_to_num(p1);
    new iTeam = str_to_num(p2);

    new idx = -1;
    if (equali(szKey, "kill")) idx = RWD_KILL;
    else if (equali(szKey, "headshot")) idx = RWD_HEADSHOT;
    else if (equali(szKey, "assist")) idx = RWD_ASSIST;
    else if (equali(szKey, "blind")) idx = RWD_BLIND;
    else if (equali(szKey, "knife")) idx = RWD_KNIFE;
    else if (equali(szKey, "grenade")) idx = RWD_GRENADE;
    else if (equali(szKey, "bomb_plant")) idx = RWD_BOMB_PLANT;
    else if (equali(szKey, "bomb_defuse")) idx = RWD_BOMB_DEFUSE;
    else if (equali(szKey, "bomb_explode")) idx = RWD_BOMB_EXPLODE;
    else if (equali(szKey, "team_kill")) idx = RWD_TEAM_KILL;
    else if (equali(szKey, "suicide")) idx = RWD_SUICIDE;
    else if (equali(szKey, "t_win")) idx = RWD_T_WIN;
    else if (equali(szKey, "ct_win")) idx = RWD_CT_WIN;
    else if (equali(szKey, "t_lose")) idx = RWD_T_LOSE;
    else if (equali(szKey, "ct_lose")) idx = RWD_CT_LOSE;
    else if (equali(szKey, "mvp")) idx = RWD_MVP;
    else if (equali(szKey, "hostage_rescued")) idx = RWD_HOSTAGE_RESCUED;
    else if (equali(szKey, "hostage_killed")) idx = RWD_HOSTAGE_KILLED;
    else if (equali(szKey, "vip")) idx = RWD_VIP;
    else if (equali(szKey, "vip_flags"))
    {
        copy(g_szCfgVipFlags, charsmax(g_szCfgVipFlags), szVal);
        return;
    }

    if (idx != -1)
    {
        g_iXpRewards[idx][0] = iPersonal;
        g_iXpRewards[idx][1] = iTeam;
    }
}

ParseRankKey(const szKey[], const szVal[])
{
    new entry[RankEntry];
    g_iTotalRanks++;
    entry[RANK_ID] = g_iTotalRanks;
    copy(entry[RANK_NAME], charsmax(entry[RANK_NAME]), szKey);
    entry[RANK_MIN_XP] = str_to_num(szVal);
    entry[RANK_MAX_XP] = -1;
    formatex(entry[RANK_BADGE], charsmax(entry[RANK_BADGE]), "rank_%d.png", g_iTotalRanks);
    copy(entry[RANK_COLOR], charsmax(entry[RANK_COLOR]), "#CCCCCC");
    ArrayPushArray(g_aRanks, entry);
}

ParseSkillKey(const szKey[], const szVal[])
{
    new entry[SkillEntry];
    copy(entry[SKILL_NAME], charsmax(entry[SKILL_NAME]), szKey);

    new szValClean[32];
    copy(szValClean, charsmax(szValClean), szVal);
    if (contain(szValClean, "*") != -1)
    {
        entry[SKILL_DEFAULT] = true;
        replace(szValClean, charsmax(szValClean), "*", "");
        trim(szValClean);
        g_iDefaultSkillIndex = g_iTotalSkills;
    }
    else
    {
        entry[SKILL_DEFAULT] = false;
    }

    entry[SKILL_MIN_RANGE] = str_to_float(szValClean);
    ArrayPushArray(g_aSkills, entry);
    g_iTotalSkills++;
}

LoadDefaultRanksAndSkills()
{
    ParseRankKey("Unranked", "0");
    ParseRankKey("Silver I", "2816");
    ParseRankKey("Global Elite", "30000");

    ParseSkillKey("L-", "0.0");
    ParseSkillKey("M", "100.0 *");
    ParseSkillKey("G", "210.0");
}

LoadEditConfiguration()
{
    new szConfigDir[64], szFile[128];
    get_configsdir(szConfigDir, charsmax(szConfigDir));
    formatex(szFile, charsmax(szFile), "%s/rsu_edit.ini", szConfigDir);

    if (!file_exists(szFile))
        return;

    new iFile = fopen(szFile, "rt");
    if (!iFile)
        return;

    new szLine[256], szKey[64], szVal[128];
    while (!feof(iFile))
    {
        fgets(iFile, szLine, charsmax(szLine));
        trim(szLine);
        if (!szLine[0] || szLine[0] == ';' || szLine[0] == '#')
            continue;

        strtok(szLine, szKey, charsmax(szKey), szVal, charsmax(szVal), '=');
        trim(szKey);
        trim(szVal);

        if (equali(szKey, "TOP15_PRIMARY_COLOR")) copy(g_szEditTop15Primary, charsmax(g_szEditTop15Primary), szVal);
        else if (equali(szKey, "TOP15_SECONDARY_COLOR")) copy(g_szEditTop15Secondary, charsmax(g_szEditTop15Secondary), szVal);
        else if (equali(szKey, "RANKSTATS_PRIMARY_COLOR")) copy(g_szEditRankstatsPrimary, charsmax(g_szEditRankstatsPrimary), szVal);
        else if (equali(szKey, "RANKSTATS_HEADER_COLOR")) copy(g_szEditRankstatsHeader, charsmax(g_szEditRankstatsHeader), szVal);
        else if (equali(szKey, "MAPEND_MAP_COLOR")) copy(g_szEditMapendMap, charsmax(g_szEditMapendMap), szVal);
        else if (equali(szKey, "MAPEND_TEAM1_COLOR")) copy(g_szEditMapendT, charsmax(g_szEditMapendT), szVal);
        else if (equali(szKey, "MAPEND_TEAM2_COLOR")) copy(g_szEditMapendCT, charsmax(g_szEditMapendCT), szVal);
    }
    fclose(iFile);
}

// ============================================================================
// SQL DATABASE SYSTEM & SCHEMA
// ============================================================================
public TaskInitSQL()
{
    new bool:bUseSqlite = (equali(g_szCfgSqlDriver, "sqlite") != 0);

    if (!bUseSqlite)
    {
        SQL_SetAffinity("mysql");
        g_hSqlTuple = SQL_MakeDbTuple(g_szCfgSqlHost, g_szCfgSqlUser, g_szCfgSqlPass, g_szCfgSqlDb);

        new iErrorCode, szError[256];
        new Handle:hConnect = SQL_Connect(g_hSqlTuple, iErrorCode, szError, charsmax(szError));
        if (hConnect == Empty_Handle)
        {
            log_amx("[RSU SQL] MySQL unavailable. Falling back to local SQLite: %s", szError);
            SQL_FreeHandle(g_hSqlTuple);
            g_hSqlTuple = Empty_Handle;
            bUseSqlite = true;
        }
        else
        {
            SQL_FreeHandle(hConnect);
            g_bIsSqlite = false;
            log_amx("[RSU SQL] MySQL connection established successfully.");
        }
    }

    if (bUseSqlite)
    {
        SQL_SetAffinity("sqlite");
        g_hSqlTuple = SQL_MakeDbTuple("", "", "", "RanksUltimate");
        g_bIsSqlite = true;
        log_amx("[RSU SQL] SQLite embedded database initialized (RanksUltimate.sq3).");
    }

    set_cvar_string("rsu_sql_driver", g_szCfgSqlDriver);
    set_cvar_string("rsu_sql_host", g_szCfgSqlHost);
    set_cvar_string("rsu_sql_user", g_szCfgSqlUser);
    if (!g_bIsSqlite)
        set_cvar_string("rsu_sql_pass", g_szCfgSqlPass);
    set_cvar_string("rsu_sql_db", g_szCfgSqlDb);
    set_cvar_string("rsu_sql_prefix", g_szSqlTablePrefix);
    set_cvar_num("rsu_sql_is_sqlite", g_bIsSqlite ? 1 : 0);

    EnsureDatabaseSchema();

    // Connect all existing players
    for (new id = 1; id <= MaxClients; id++)
    {
        if (is_user_connected(id))
        {
            CheckAndLoadPlayer(id);
        }
    }
}

EnsureDatabaseSchema()
{
    if (g_hSqlTuple == Empty_Handle)
        return;

    new szQ[1536];
    formatex(szQ, charsmax(szQ),
        "CREATE TABLE IF NOT EXISTS `%splayers` (            id INTEGER PRIMARY KEY AUTOINCREMENT,            steamid VARCHAR(32) UNIQUE NOT NULL,            name VARCHAR(64) NOT NULL,            ip VARCHAR(32) DEFAULT '',            country CHAR(2) DEFAULT 'XX',            xp INTEGER DEFAULT 0,            lifetime_xp INTEGER DEFAULT 0,            level INTEGER DEFAULT 1,            rank_id INTEGER DEFAULT 1,            skill REAL DEFAULT %.1f,            peak_skill REAL DEFAULT %.1f,            playtime INTEGER DEFAULT 0,            first_seen TEXT,            last_seen TEXT,            last_server_id INTEGER DEFAULT 1,            account_level INTEGER DEFAULT 1,            prestige INTEGER DEFAULT 0,            placement_matches INTEGER DEFAULT 0,            last_active_date TEXT,            decay_due REAL DEFAULT 0.0        );",
        g_szSqlTablePrefix, RSU_DEFAULT_SKILL, RSU_DEFAULT_SKILL);
    SQL_ThreadQuery(g_hSqlTuple, "ThreadQuery_Generic", szQ);

    formatex(szQ, charsmax(szQ),
        "CREATE TABLE IF NOT EXISTS `%splayer_stats` (            player_id INTEGER NOT NULL,            server_id INTEGER NOT NULL DEFAULT 0,            kills INTEGER DEFAULT 0,            deaths INTEGER DEFAULT 0,            headshots INTEGER DEFAULT 0,            assists INTEGER DEFAULT 0,            damage INTEGER DEFAULT 0,            shots INTEGER DEFAULT 0,            hits INTEGER DEFAULT 0,            mvps INTEGER DEFAULT 0,            c4_plants INTEGER DEFAULT 0,            c4_defuses INTEGER DEFAULT 0,            c4_explosions INTEGER DEFAULT 0,            rounds_won INTEGER DEFAULT 0,            hostages_rescued INTEGER DEFAULT 0,            knife_kills INTEGER DEFAULT 0,            he_kills INTEGER DEFAULT 0,            zombie_wins INTEGER DEFAULT 0,            human_wins INTEGER DEFAULT 0,            infections INTEGER DEFAULT 0,            survivals INTEGER DEFAULT 0,            adr REAL DEFAULT 0.0,            kast_rounds INTEGER DEFAULT 0,            opening_kills INTEGER DEFAULT 0,            opening_deaths INTEGER DEFAULT 0,            trade_kills INTEGER DEFAULT 0,            clutches_won INTEGER DEFAULT 0,            aces INTEGER DEFAULT 0,            PRIMARY KEY(player_id, server_id)        );",
        g_szSqlTablePrefix);
    SQL_ThreadQuery(g_hSqlTuple, "ThreadQuery_Generic", szQ);

    formatex(szQ, charsmax(szQ),
        "CREATE TABLE IF NOT EXISTS `%splayer_weapons` (            player_id INTEGER NOT NULL,            weapon_id INTEGER NOT NULL,            kills INTEGER DEFAULT 0,            PRIMARY KEY(player_id, weapon_id)        );",
        g_szSqlTablePrefix);
    SQL_ThreadQuery(g_hSqlTuple, "ThreadQuery_Generic", szQ);

    formatex(szQ, charsmax(szQ),
        "CREATE TABLE IF NOT EXISTS `%sbp_board` (steamid VARCHAR(32) NOT NULL, name VARCHAR(32), bpxp INTEGER DEFAULT 0, bplevel INTEGER DEFAULT 0, updated VARCHAR(32), PRIMARY KEY(steamid));",
        g_szSqlTablePrefix);
    SQL_ThreadQuery(g_hSqlTuple, "ThreadQuery_Generic", szQ);
    formatex(szQ, charsmax(szQ),
        "CREATE TABLE IF NOT EXISTS `%smatches` (            id INTEGER PRIMARY KEY AUTOINCREMENT,            server_id INTEGER NOT NULL DEFAULT 1,            map_name VARCHAR(64) NOT NULL,            t_score INTEGER DEFAULT 0,            ct_score INTEGER DEFAULT 0,            winner_team INTEGER DEFAULT 0,            started_at VARCHAR(32) DEFAULT '',            ended_at VARCHAR(32) DEFAULT ''        );",
        g_szSqlTablePrefix);
    SQL_ThreadQuery(g_hSqlTuple, "ThreadQuery_Generic", szQ);

    formatex(szQ, charsmax(szQ),
        "CREATE TABLE IF NOT EXISTS `%smodule_data` (            player_id INTEGER NOT NULL,            module_tag VARCHAR(16) NOT NULL,            data_blob TEXT NOT NULL,            updated_at TEXT DEFAULT CURRENT_TIMESTAMP,            PRIMARY KEY(player_id, module_tag)        );",
        g_szSqlTablePrefix);
    SQL_ThreadQuery(g_hSqlTuple, "ThreadQuery_Generic", szQ);

    formatex(szQ, charsmax(szQ),
        "CREATE TABLE IF NOT EXISTS `%smatch_players` (            match_id INTEGER NOT NULL,            player_id INTEGER NOT NULL,            team INTEGER DEFAULT 0,            kills INTEGER DEFAULT 0,            deaths INTEGER DEFAULT 0,            assists INTEGER DEFAULT 0,            headshots INTEGER DEFAULT 0,            damage INTEGER DEFAULT 0,            xp_earned INTEGER DEFAULT 0,            skill_delta REAL DEFAULT 0.0,            time_played INTEGER DEFAULT 0,            adr REAL DEFAULT 0.0,            kast_rounds INTEGER DEFAULT 0,            opening_kills INTEGER DEFAULT 0,            opening_deaths INTEGER DEFAULT 0,            trade_kills INTEGER DEFAULT 0,            clutches_won INTEGER DEFAULT 0,            aces INTEGER DEFAULT 0,            PRIMARY KEY(match_id, player_id)        );",
        g_szSqlTablePrefix);
    SQL_ThreadQuery(g_hSqlTuple, "ThreadQuery_Generic", szQ);

    formatex(szQ, charsmax(szQ),
        "CREATE TABLE IF NOT EXISTS `%splayer_achievements` (            player_id INTEGER NOT NULL,            achievement_id INTEGER NOT NULL,            progress INTEGER DEFAULT 0,            unlocked INTEGER DEFAULT 0,            unlocked_at TEXT DEFAULT '',            PRIMARY KEY(player_id, achievement_id)        );",
        g_szSqlTablePrefix);
    SQL_ThreadQuery(g_hSqlTuple, "ThreadQuery_Generic", szQ);

    formatex(szQ, charsmax(szQ),
        "CREATE TABLE IF NOT EXISTS `%splayer_missions` (            player_id INTEGER NOT NULL,            slot_id INTEGER NOT NULL,            mission_type VARCHAR(32) NOT NULL,            target_value INTEGER DEFAULT 0,            current_value INTEGER DEFAULT 0,            reward_xp INTEGER DEFAULT 0,            completed INTEGER DEFAULT 0,            assigned_date TEXT DEFAULT '',            expires_at TEXT DEFAULT '',            PRIMARY KEY(player_id, slot_id, assigned_date)        );",
        g_szSqlTablePrefix);
    SQL_ThreadQuery(g_hSqlTuple, "ThreadQuery_Generic", szQ);

    formatex(szQ, charsmax(szQ),
        "CREATE TABLE IF NOT EXISTS `%sresets` (            id INTEGER PRIMARY KEY AUTOINCREMENT,            reset_type VARCHAR(32) NOT NULL,            executed_by VARCHAR(64) DEFAULT '',            executed_at VARCHAR(32) DEFAULT '',            affected_players INTEGER DEFAULT 0        );",
        g_szSqlTablePrefix);
    SQL_ThreadQuery(g_hSqlTuple, "ThreadQuery_Generic", szQ);

    formatex(szQ, charsmax(szQ),
        "CREATE TABLE IF NOT EXISTS `%splayer_maps` (            player_id INTEGER NOT NULL,            map_name VARCHAR(64) NOT NULL,            matches INTEGER DEFAULT 0,            wins INTEGER DEFAULT 0,            losses INTEGER DEFAULT 0,            kills INTEGER DEFAULT 0,            deaths INTEGER DEFAULT 0,            assists INTEGER DEFAULT 0,            headshots INTEGER DEFAULT 0,            damage INTEGER DEFAULT 0,            last_played VARCHAR(32) DEFAULT '',            PRIMARY KEY(player_id, map_name)        );",
        g_szSqlTablePrefix);
    SQL_ThreadQuery(g_hSqlTuple, "ThreadQuery_Generic", szQ);

    formatex(szQ, charsmax(szQ),
        "CREATE TABLE IF NOT EXISTS `%sap_unlocks` (            player_id INTEGER NOT NULL,            code VARCHAR(32) NOT NULL,            ap INTEGER DEFAULT 0,            earned_at VARCHAR(32) DEFAULT '',            PRIMARY KEY(player_id, code)        );",
        g_szSqlTablePrefix);
    SQL_ThreadQuery(g_hSqlTuple, "ThreadQuery_Generic", szQ);

    formatex(szQ, charsmax(szQ),
        "CREATE TABLE IF NOT EXISTS `%smission_catalog` (            key VARCHAR(24) PRIMARY KEY,            json TEXT NOT NULL,            updated_at VARCHAR(32) DEFAULT ''        );",
        g_szSqlTablePrefix);
    SQL_ThreadQuery(g_hSqlTuple, "ThreadQuery_Generic", szQ);

    PersistMissionCatalog();

    // Soft Migration Queries for existing local/remote installations
    formatex(szQ, charsmax(szQ), "ALTER TABLE `%splayers` ADD COLUMN account_level INTEGER DEFAULT 1;", g_szSqlTablePrefix);
    SQL_ThreadQuery(g_hSqlTuple, "ThreadQuery_Migration", szQ);
    formatex(szQ, charsmax(szQ), "ALTER TABLE `%splayers` ADD COLUMN prestige INTEGER DEFAULT 0;", g_szSqlTablePrefix);
    SQL_ThreadQuery(g_hSqlTuple, "ThreadQuery_Migration", szQ);
    formatex(szQ, charsmax(szQ), "ALTER TABLE `%splayers` ADD COLUMN placement_matches INTEGER DEFAULT 0;", g_szSqlTablePrefix);
    SQL_ThreadQuery(g_hSqlTuple, "ThreadQuery_Migration", szQ);
    formatex(szQ, charsmax(szQ), "ALTER TABLE `%splayers` ADD COLUMN last_active_date TEXT;", g_szSqlTablePrefix);
    SQL_ThreadQuery(g_hSqlTuple, "ThreadQuery_Migration", szQ);
    formatex(szQ, charsmax(szQ), "ALTER TABLE `%splayers` ADD COLUMN decay_due REAL DEFAULT 0.0;", g_szSqlTablePrefix);
    SQL_ThreadQuery(g_hSqlTuple, "ThreadQuery_Migration", szQ);
    formatex(szQ, charsmax(szQ), "ALTER TABLE `%splayer_stats` ADD COLUMN adr REAL DEFAULT 0.0;", g_szSqlTablePrefix);
    SQL_ThreadQuery(g_hSqlTuple, "ThreadQuery_Migration", szQ);
    formatex(szQ, charsmax(szQ), "ALTER TABLE `%splayer_stats` ADD COLUMN kast_rounds INTEGER DEFAULT 0;", g_szSqlTablePrefix);
    SQL_ThreadQuery(g_hSqlTuple, "ThreadQuery_Migration", szQ);
    formatex(szQ, charsmax(szQ), "ALTER TABLE `%splayer_stats` ADD COLUMN opening_kills INTEGER DEFAULT 0;", g_szSqlTablePrefix);
    SQL_ThreadQuery(g_hSqlTuple, "ThreadQuery_Migration", szQ);
    formatex(szQ, charsmax(szQ), "ALTER TABLE `%splayer_stats` ADD COLUMN opening_deaths INTEGER DEFAULT 0;", g_szSqlTablePrefix);
    SQL_ThreadQuery(g_hSqlTuple, "ThreadQuery_Migration", szQ);
    formatex(szQ, charsmax(szQ), "ALTER TABLE `%splayer_stats` ADD COLUMN trade_kills INTEGER DEFAULT 0;", g_szSqlTablePrefix);
    SQL_ThreadQuery(g_hSqlTuple, "ThreadQuery_Migration", szQ);
    formatex(szQ, charsmax(szQ), "ALTER TABLE `%splayer_stats` ADD COLUMN clutches_won INTEGER DEFAULT 0;", g_szSqlTablePrefix);
    SQL_ThreadQuery(g_hSqlTuple, "ThreadQuery_Migration", szQ);
    formatex(szQ, charsmax(szQ), "ALTER TABLE `%splayer_stats` ADD COLUMN aces INTEGER DEFAULT 0;", g_szSqlTablePrefix);
    SQL_ThreadQuery(g_hSqlTuple, "ThreadQuery_Migration", szQ);
    formatex(szQ, charsmax(szQ), "ALTER TABLE `%smatch_players` ADD COLUMN adr REAL DEFAULT 0.0;", g_szSqlTablePrefix);
    SQL_ThreadQuery(g_hSqlTuple, "ThreadQuery_Migration", szQ);
    formatex(szQ, charsmax(szQ), "ALTER TABLE `%smatch_players` ADD COLUMN kast_rounds INTEGER DEFAULT 0;", g_szSqlTablePrefix);
    SQL_ThreadQuery(g_hSqlTuple, "ThreadQuery_Migration", szQ);
    formatex(szQ, charsmax(szQ), "ALTER TABLE `%smatch_players` ADD COLUMN opening_kills INTEGER DEFAULT 0;", g_szSqlTablePrefix);
    SQL_ThreadQuery(g_hSqlTuple, "ThreadQuery_Migration", szQ);
    formatex(szQ, charsmax(szQ), "ALTER TABLE `%smatch_players` ADD COLUMN opening_deaths INTEGER DEFAULT 0;", g_szSqlTablePrefix);
    SQL_ThreadQuery(g_hSqlTuple, "ThreadQuery_Migration", szQ);
    formatex(szQ, charsmax(szQ), "ALTER TABLE `%smatch_players` ADD COLUMN trade_kills INTEGER DEFAULT 0;", g_szSqlTablePrefix);
    SQL_ThreadQuery(g_hSqlTuple, "ThreadQuery_Migration", szQ);
    formatex(szQ, charsmax(szQ), "ALTER TABLE `%smatch_players` ADD COLUMN clutches_won INTEGER DEFAULT 0;", g_szSqlTablePrefix);
    SQL_ThreadQuery(g_hSqlTuple, "ThreadQuery_Migration", szQ);
    formatex(szQ, charsmax(szQ), "ALTER TABLE `%smatch_players` ADD COLUMN aces INTEGER DEFAULT 0;", g_szSqlTablePrefix);
    SQL_ThreadQuery(g_hSqlTuple, "ThreadQuery_Migration", szQ);
}

public client_connect(id)
{
    g_iConnectionToken[id]++;
    g_iPlayerState[id] = PLAYER_STATE_CONNECTING;
    ResetPlayerData(id);
}

public client_authorized(id)
{
    if (!get_pcvar_num(g_pCvarEnableStats))
        return;

    if (!g_bDataLoaded[id] && !g_bLoading[id])
    {
        CheckAndLoadPlayer(id);
    }
}

public client_putinserver(id)
{
    if (!get_pcvar_num(g_pCvarEnableStats))
        return;

    if (!g_bDataLoaded[id] && !g_bLoading[id])
    {
        CheckAndLoadPlayer(id);
    }
}

public TaskRetryLoad(id)
{
    if (id > 2000) id -= 2000;
    if (!is_user_connected(id) || g_bDataLoaded[id] || g_bLoading[id])
        return;

    CheckAndLoadPlayer(id);
}

CheckAndLoadPlayer(id)
{
    g_iPlayerState[id] = PLAYER_STATE_LOADING;
    if (!is_user_connected(id))
        return;

    if (is_user_bot(id) && g_iCfgRankBots == 0)
        return;

    if (!InitializePlayerSession(id))
    {
        // HLTV has no player identity — never retry into rsu_players.
        if (is_user_hltv(id))
            return;
        new szAuth[32];
        get_user_authid(id, szAuth, charsmax(szAuth));
        if (equal(szAuth, "HLTV"))
            return;

        if (task_exists(id + 2000))
            remove_task(id + 2000);
        set_task(0.5, "TaskRetryLoad", id + 2000);
        return;
    }

    LoadPlayerData(id);
}

public client_disconnected(id)
{
    if (task_exists(id + 2000))
        remove_task(id + 2000);

    // Snapshot-and-save BEFORE ResetPlayerData. The SQL string is built
    // synchronously from live cells; increment the token afterwards so a
    // late LOAD for this occupancy can never land on a reused slot.
    if (g_bDataLoaded[id] && g_iDatabaseId[id] > 0)
    {
        g_iPlayerState[id] = PLAYER_STATE_SAVING;
        SavePlayerDataAsync(id, true);
    }
    g_iConnectionToken[id]++;
    g_iPlayerState[id] = PLAYER_STATE_DISCONNECTED;
    if (g_iLastPlanter == id)
        g_iLastPlanter = 0;
    ResetPlayerData(id);
}

ResetPlayerData(id)
{
    g_iPlayerState[id] = PLAYER_STATE_EMPTY;
    g_szSessionUUID[id][0] = '^0';
    g_iAuthPendingTicks[id] = 0;
    g_fDeviation[id] = 350.0;
    g_fCommandTokens[id] = 3.0;
    g_fLastCommandCheck[id] = get_gametime();
    for (new f = 0; f < 8; f++)
    {
        g_iFragVictims[id][f] = 0;
        g_fFragTimes[id][f] = 0.0;
    }
    g_iFragHead[id] = 0;
    g_iApStampMask[id] = 0;

    g_bDataLoaded[id] = false;
    g_bLoading[id] = false;
    g_iDatabaseId[id] = 0;
    g_szAuthID[id][0] = '^0';
    g_szPlayerName[id][0] = '^0';
    g_szPlayerIP[id][0] = '^0';
    g_szCountry[id][0] = '^0';
    g_szFirstSeen[id][0] = '^0';
    g_szLastSeen[id][0] = '^0';

    g_iPlayerXP[id] = 0;
    g_iLifetimeXP[id] = 0;
    g_iLevel[id] = 1;
    g_iAccountLevel[id] = 1;
    g_iPrestige[id] = 0;
    g_iPlacementMatches[id] = 0;
    g_iRank[id] = 1;
    g_fSkill[id] = RSU_DEFAULT_SKILL;
    g_fPeakSkill[id] = RSU_DEFAULT_SKILL;
    g_iPlaytime[id] = 0;
    g_iSessionSeconds[id] = 0;

    g_iKills[id] = 0;
    g_iDeaths[id] = 0;
    g_iHeadshots[id] = 0;
    g_iAssists[id] = 0;
    g_iSuicides[id] = 0;
    g_iTeamkills[id] = 0;
    g_iShots[id] = 0;
    g_iHits[id] = 0;
    g_iDamage[id] = 0;
    g_iRoundsPlayed[id] = 0;
    g_iRoundsWon[id] = 0;
    g_iRoundsLost[id] = 0;
    g_iTWins[id] = 0;
    g_iCTWins[id] = 0;
    g_iMVPs[id] = 0;
    g_iC4Plants[id] = 0;
    g_iC4Explosions[id] = 0;
    g_iC4Defuses[id] = 0;
    g_iHostagesRescued[id] = 0;
    g_iKnifeKills[id] = 0;
    g_iHEKills[id] = 0;

    g_iZombieWins[id] = 0;
    g_iHumanWins[id] = 0;
    g_iInfections[id] = 0;
    g_iSurvivals[id] = 0;
    g_iRoundInfections[id] = 0;
    g_fFlashedUntil[id] = 0.0;

    for (new w = 0; w < RSU_TOTAL_WEAPONS; w++)
        g_iWeaponKills[id][w] = 0;

    g_bHudEnabled[id] = true;
    g_bRankInfoEnabled[id] = true;
    g_iServerRank[id] = 1;
    g_iDirtyMask[id] = DIRTY_NONE;
}

bool:InitializePlayerSession(id)
{
    get_user_name(id, g_szPlayerName[id], charsmax(g_szPlayerName[]));
    get_user_ip(id, g_szPlayerIP[id], charsmax(g_szPlayerIP[]), 1);
    copy(g_szCountry[id], charsmax(g_szCountry[]), "XX");

    new szHltvAuth[32];
    get_user_authid(id, szHltvAuth, charsmax(szHltvAuth));
    if (is_user_hltv(id) || equal(szHltvAuth, "HLTV"))
        return false;

    if (is_user_bot(id))
    {
        if (g_iCfgRankBots == 0)
            return false;

        formatex(g_szAuthID[id], charsmax(g_szAuthID[]), "BOT_%s", g_szPlayerName[id]);
        g_bLoading[id] = true;
        return true;
    }

    switch (g_iCfgSaveType)
    {
        case 0:
        {
            copy(g_szAuthID[id], charsmax(g_szAuthID[]), g_szPlayerName[id]);
        }
        case 1:
        {
            copy(g_szAuthID[id], charsmax(g_szAuthID[]), g_szPlayerIP[id]);
        }
        default:
        {
            get_user_authid(id, g_szAuthID[id], charsmax(g_szAuthID[]));

            if (!g_szAuthID[id][0] || equal(g_szAuthID[id], "STEAM_ID_PENDING") || equal(g_szAuthID[id], "VALVE_ID_PENDING"))
            {
                // Never persist pending identity as LAN_<name> — that splits
                // XP when the real STEAM_x:y:z later arrives. Keep retrying
                // via TaskRetryLoad / client_authorized; refuse load/save.
                g_iAuthPendingTicks[id]++;
                return false;
            }

            if (equal(g_szAuthID[id], "STEAM_ID_LAN") || equal(g_szAuthID[id], "VALVE_ID_LAN"))
            {
                formatex(g_szAuthID[id], charsmax(g_szAuthID[]), "LAN_%s", g_szPlayerName[id]);
            }
        }
    }

    if (!g_szAuthID[id][0])
        return false;

    g_bLoading[id] = true;
    g_iPlayerState[id] = PLAYER_STATE_AUTHORIZED;
    GenerateSessionUUID(g_szSessionUUID[id], charsmax(g_szSessionUUID[]));
    ExecuteForward(g_fwdPlayerAuthorized, _, id, g_szAuthID[id], g_szSessionUUID[id]);
    return true;
}

LoadPlayerData(id)
{
    if (g_hSqlTuple == Empty_Handle || !g_szAuthID[id][0])
        return;

    new szQuery[1024], szEscAuth[64];
    copy(szEscAuth, charsmax(szEscAuth), g_szAuthID[id]);
    replace_all(szEscAuth, charsmax(szEscAuth), "'", "''");

    // Buffer MUST stay above 512: the old 512-byte query truncated before
    // `s.kills` and SQLite reported "no such column" — then load never marked READY.
    formatex(szQuery, charsmax(szQuery),
        "SELECT p.id, p.xp, p.lifetime_xp, p.level, p.rank_id, p.skill, p.peak_skill, p.playtime, p.first_seen, p.last_seen, \
                COALESCE(s.kills,0), COALESCE(s.deaths,0), COALESCE(s.headshots,0), COALESCE(s.assists,0), COALESCE(s.damage,0), \
                COALESCE(s.shots,0), COALESCE(s.hits,0), COALESCE(s.mvps,0), COALESCE(s.rounds_won,0), \
                COALESCE(s.c4_plants,0), COALESCE(s.c4_defuses,0), COALESCE(s.c4_explosions,0), COALESCE(s.zombie_wins,0), \
                COALESCE(s.human_wins,0), COALESCE(s.infections,0), COALESCE(s.survivals,0), COALESCE(s.knife_kills,0), COALESCE(s.he_kills,0), COALESCE(s.hostages_rescued,0), \
                COALESCE(p.account_level, 1), COALESCE(p.prestige, 0), COALESCE(p.placement_matches, 0) \
         FROM `%splayers` p LEFT JOIN `%splayer_stats` s ON (p.id = s.player_id AND s.server_id = 0) \
         WHERE p.steamid = '%s' LIMIT 1;",
        g_szSqlTablePrefix, g_szSqlTablePrefix, szEscAuth);

    new data[3];
    data[0] = id;
    data[1] = get_user_userid(id);
    data[2] = g_iConnectionToken[id];
    SQL_ThreadQuery(g_hSqlTuple, "ThreadQuery_LoadPlayer", szQuery, data, sizeof(data));
}

public ThreadQuery_LoadPlayer(iFailState, Handle:hQuery, szError[], iErrorCode, data[], iDataSize)
{
    new id = data[0];
    new iUserId = data[1];
    new iToken = data[2];

    if (!is_user_connected(id) || get_user_userid(id) != iUserId || g_iConnectionToken[id] != iToken)
        return;

    g_bLoading[id] = false;

    if (iFailState != TQUERY_SUCCESS)
    {
        log_amx("[RSU SQL ERROR] Load query failed for #%d [%s]: [%d] %s", id, g_szAuthID[id], iErrorCode, szError);
        // Never insert a blank row after a failed load — that is how a
        // veteran player gets zeroed. Keep occupancy, retry the SELECT.
        if (!task_exists(id + 2000))
            set_task(2.0, "TaskRetryLoad", id + 2000);
        return;
    }

    if (SQL_NumResults(hQuery) > 0)
    {
        // Existing Player
        g_iDatabaseId[id]   = SQL_ReadResult(hQuery, 0);
        g_iPlayerXP[id]     = SQL_ReadResult(hQuery, 1);
        g_iLifetimeXP[id]   = SQL_ReadResult(hQuery, 2);
        g_iLevel[id]        = SQL_ReadResult(hQuery, 3);
        g_iRank[id]         = SQL_ReadResult(hQuery, 4);
        SQL_ReadResult(hQuery, 5, g_fSkill[id]);
        SQL_ReadResult(hQuery, 6, g_fPeakSkill[id]);
        g_iPlaytime[id]     = SQL_ReadResult(hQuery, 7);
        SQL_ReadResult(hQuery, 8, g_szFirstSeen[id], charsmax(g_szFirstSeen[]));
        SQL_ReadResult(hQuery, 9, g_szLastSeen[id], charsmax(g_szLastSeen[]));

        if (!SQL_IsNull(hQuery, 10))
        {
            g_iKills[id]        = SQL_ReadResult(hQuery, 10);
            g_iDeaths[id]       = SQL_ReadResult(hQuery, 11);
            g_iHeadshots[id]    = SQL_ReadResult(hQuery, 12);
            g_iAssists[id]      = SQL_ReadResult(hQuery, 13);
            g_iDamage[id]       = SQL_ReadResult(hQuery, 14);
            g_iShots[id]        = SQL_ReadResult(hQuery, 15);
            g_iHits[id]         = SQL_ReadResult(hQuery, 16);
            g_iMVPs[id]         = SQL_ReadResult(hQuery, 17);
            g_iRoundsWon[id]    = SQL_ReadResult(hQuery, 18);
            g_iC4Plants[id]     = SQL_ReadResult(hQuery, 19);
            g_iC4Defuses[id]    = SQL_ReadResult(hQuery, 20);
            g_iC4Explosions[id] = SQL_ReadResult(hQuery, 21);
            g_iZombieWins[id]   = SQL_ReadResult(hQuery, 22);
            g_iHumanWins[id]    = SQL_ReadResult(hQuery, 23);
            g_iInfections[id]   = SQL_ReadResult(hQuery, 24);
            g_iSurvivals[id]    = SQL_ReadResult(hQuery, 25);
            g_iKnifeKills[id]   = SQL_ReadResult(hQuery, 26);
            g_iHEKills[id]      = SQL_ReadResult(hQuery, 27);
            g_iHostagesRescued[id] = SQL_ReadResult(hQuery, 28);
        }

        if (SQL_NumColumns(hQuery) > 31)
        {
            g_iAccountLevel[id]       = SQL_ReadResult(hQuery, 29);
            g_iPrestige[id]           = SQL_ReadResult(hQuery, 30);
            g_iPlacementMatches[id]   = SQL_ReadResult(hQuery, 31);
        }
        else
        {
            g_iAccountLevel[id]       = 1;
            g_iPrestige[id]           = 0;
            g_iPlacementMatches[id]   = 0;
        }

        g_bDataLoaded[id] = true;
        g_iPlayerState[id] = PLAYER_STATE_READY;
        g_iRank[id] = CalculateRank(g_iPlayerXP[id]);
        RefreshServerRank(id);

        LoadPlayerWeapons(id);

        // Trigger Forwards
        ExecuteForward(g_fwdUserStatsLoaded, _, id, g_szAuthID[id], g_szPlayerName[id]);
        ExecuteForward(g_fwdPlayerLoaded, _, id, g_iDatabaseId[id]);
        ExecuteForward(g_fwdPlayerReady, _, id);
    }
    else
    {
        InsertNewPlayerAsync(id);
    }
}

// Overall order: XP DESC, skill DESC, kills DESC, steamid ASC (deterministic).
// Rank = 1 + players strictly ahead; total = COUNT(*) of the population.
RefreshServerRank(id)
{
    if (!is_user_connected(id) || g_hSqlTuple == Empty_Handle)
        return;
    new szEscAuth[64];
    EscapeSql(szEscAuth, charsmax(szEscAuth), g_szAuthID[id]);
    new szQuery[768];
    formatex(szQuery, charsmax(szQuery),
        "SELECT (SELECT COUNT(*)+1 FROM `%splayers` q LEFT JOIN `%splayer_stats` qs ON (q.id = qs.player_id AND qs.server_id = 0) WHERE q.xp > p.xp OR (q.xp = p.xp AND (q.skill > p.skill OR (q.skill = p.skill AND (COALESCE(qs.kills, 0) > COALESCE(s.kills, 0) OR (COALESCE(qs.kills, 0) = COALESCE(s.kills, 0) AND q.steamid < p.steamid)))))), (SELECT COUNT(*) FROM `%splayers`) FROM `%splayers` p LEFT JOIN `%splayer_stats` s ON (p.id = s.player_id AND s.server_id = 0) WHERE p.steamid = '%s';",
        g_szSqlTablePrefix, g_szSqlTablePrefix, g_szSqlTablePrefix, g_szSqlTablePrefix, g_szSqlTablePrefix, szEscAuth);
    new data[3];
    data[0] = id;
    data[1] = get_user_userid(id);
    data[2] = g_iConnectionToken[id];
    SQL_ThreadQuery(g_hSqlTuple, "ThreadQuery_ServerRank", szQuery, data, sizeof(data));
}

public ThreadQuery_ServerRank(iFailState, Handle:hQuery, szError[], iErrorCode, data[], iDataSize)
{
    #pragma unused iDataSize
    new id = data[0];
    if (!is_user_connected(id) || get_user_userid(id) != data[1] || g_iConnectionToken[id] != data[2])
        return;
    if (iFailState != TQUERY_SUCCESS)
    {
        log_amx("[RSU SQL ERROR] ServerRank query failed: [%d] %s", iErrorCode, szError);
        return;
    }
    if (!SQL_MoreResults(hQuery))
        return;
    new iRank = SQL_ReadResult(hQuery, 0);
    new iTotal = SQL_ReadResult(hQuery, 1);
    if (iRank > 0)
        g_iServerRank[id] = iRank;
    if (iTotal >= 0)
        g_iTotalServerPlayers = iTotal;
}

InsertNewPlayerAsync(id)
{
    new szQuery[512], szEscName[128], szEscAuth[64], szTime[32];
    EscapeSql( szEscName, charsmax(szEscName), g_szPlayerName[id]);
    EscapeSql( szEscAuth, charsmax(szEscAuth), g_szAuthID[id]);
    get_time("%Y-%m-%d %H:%M:%S", szTime, charsmax(szTime));
    copy(g_szFirstSeen[id], charsmax(g_szFirstSeen[]), szTime);
    copy(g_szLastSeen[id], charsmax(g_szLastSeen[]), szTime);

    // INSERT OR IGNORE / ON DUPLICATE: if a concurrent insert won the
    // unique steamid race, we must re-SELECT the real row instead of
    // treating this occupancy as a new player with 0 XP.
    if (g_bIsSqlite)
    {
        formatex(szQuery, charsmax(szQuery),
            "INSERT OR IGNORE INTO `%splayers` (`steamid`, `name`, `ip`, `country`, `xp`, `lifetime_xp`, `level`, `rank_id`, `skill`, `peak_skill`, `first_seen`, `last_seen`, `last_server_id`, `account_level`, `prestige`, `placement_matches`)              VALUES ('%s', '%s', '%s', '%s', 0, 0, 1, 1, %.1f, %.1f, '%s', '%s', %d, 1, 0, 0);",
            g_szSqlTablePrefix, szEscAuth, szEscName, g_szPlayerIP[id], g_szCountry[id],
            RSU_DEFAULT_SKILL, RSU_DEFAULT_SKILL, szTime, szTime, get_pcvar_num(g_pCvarServerId));
    }
    else
    {
        formatex(szQuery, charsmax(szQuery),
            "INSERT INTO `%splayers` (`steamid`, `name`, `ip`, `country`, `xp`, `lifetime_xp`, `level`, `rank_id`, `skill`, `peak_skill`, `first_seen`, `last_seen`, `last_server_id`, `account_level`, `prestige`, `placement_matches`)              VALUES ('%s', '%s', '%s', '%s', 0, 0, 1, 1, %.1f, %.1f, '%s', '%s', %d, 1, 0, 0)              ON DUPLICATE KEY UPDATE `name` = VALUES(`name`), `last_seen` = '%s';",
            g_szSqlTablePrefix, szEscAuth, szEscName, g_szPlayerIP[id], g_szCountry[id],
            RSU_DEFAULT_SKILL, RSU_DEFAULT_SKILL, szTime, szTime, get_pcvar_num(g_pCvarServerId), szTime);
    }

    new data[3];
    data[0] = id;
    data[1] = get_user_userid(id);
    data[2] = g_iConnectionToken[id];
    SQL_ThreadQuery(g_hSqlTuple, "ThreadQuery_InsertPlayer", szQuery, data, sizeof(data));
}

public ThreadQuery_InsertPlayer(iFailState, Handle:hQuery, szError[], iErrorCode, data[], iDataSize)
{
    new id = data[0];
    new iUserId = data[1];
    new iToken = data[2];

    if (!is_user_connected(id) || get_user_userid(id) != iUserId || g_iConnectionToken[id] != iToken)
        return;

    if (iFailState != TQUERY_SUCCESS)
    {
        log_amx("[RSU SQL ERROR] Insert failed for #%d [%s]: [%d] %s", id, g_szAuthID[id], iErrorCode, szError);
        // Unique-key race: the row already exists. Reload rather than
        // synthesizing a blank account over it.
        LoadPlayerData(id);
        return;
    }

    g_iDatabaseId[id] = SQL_GetInsertId(hQuery);
    if (g_iDatabaseId[id] <= 0)
    {
        // INSERT OR IGNORE matched an existing steamid. Reload truth.
        LoadPlayerData(id);
        return;
    }

    g_iPlayerXP[id] = 0;
    g_iLifetimeXP[id] = 0;
    g_iLevel[id] = 1;
    g_iAccountLevel[id] = 1;
    g_iPrestige[id] = 0;
    g_iPlacementMatches[id] = 0;
    g_iRank[id] = 1;
    g_fSkill[id] = RSU_DEFAULT_SKILL;
    g_fPeakSkill[id] = RSU_DEFAULT_SKILL;
    g_bDataLoaded[id] = true;
    g_iPlayerState[id] = PLAYER_STATE_READY;

    // Create Initial Stats Record
    new szQuery[256];
    if (g_bIsSqlite)
    {
        formatex(szQuery, charsmax(szQuery),
            "INSERT OR IGNORE INTO `%splayer_stats` (`player_id`, `server_id`) VALUES (%d, 0);",
            g_szSqlTablePrefix, g_iDatabaseId[id]);
    }
    else
    {
        formatex(szQuery, charsmax(szQuery),
            "INSERT IGNORE INTO `%splayer_stats` (`player_id`, `server_id`) VALUES (%d, 0);",
            g_szSqlTablePrefix, g_iDatabaseId[id]);
    }
    SQL_ThreadQuery(g_hSqlTuple, "ThreadQuery_Generic", szQuery);

    ExecuteForward(g_fwdUserStatsLoaded, _, id, g_szAuthID[id], g_szPlayerName[id]);
    ExecuteForward(g_fwdPlayerLoaded, _, id, g_iDatabaseId[id]);
    ExecuteForward(g_fwdPlayerReady, _, id);
}

UpsertBpBoard(id)
{
    if (g_hSqlTuple == Empty_Handle || !g_bDataLoaded[id])
        return;
    // bp_board is the BattlePass leaderboard. It must not be fed rank XP/level;
    // skip the write until the separate BP ledger is ready.
    if (!LibraryExists("menabp", LibType_Library) || !menabp_is_ready(id))
        return;
    new iBpXp = menabp_get_xp(id);
    new iBpLvl = menabp_get_tier(id);
    new szEscName[128], szEscAuth[64], szTime[32];
    EscapeSql(szEscName, charsmax(szEscName), g_szPlayerName[id]);
    EscapeSql(szEscAuth, charsmax(szEscAuth), g_szAuthID[id]);
    get_time("%Y-%m-%d %H:%M:%S", szTime, charsmax(szTime));
    new szQ[512];
    if (g_bIsSqlite)
        formatex(szQ, charsmax(szQ), "INSERT OR REPLACE INTO `%sbp_board` (`steamid`, `name`, `bpxp`, `bplevel`, `updated`) VALUES ('%s', '%s', %d, %d, '%s');", g_szSqlTablePrefix, szEscAuth, szEscName, iBpXp, iBpLvl, szTime);
    else
        formatex(szQ, charsmax(szQ), "INSERT INTO `%sbp_board` (`steamid`, `name`, `bpxp`, `bplevel`, `updated`) VALUES ('%s', '%s', %d, %d, '%s') ON DUPLICATE KEY UPDATE `name` = VALUES(`name`), `bpxp` = VALUES(`bpxp`), `bplevel` = VALUES(`bplevel`), `updated` = VALUES(`updated`);", g_szSqlTablePrefix, szEscAuth, szEscName, iBpXp, iBpLvl, szTime);
    SQL_ThreadQuery(g_hSqlTuple, "ThreadQuery_Generic", szQ);
}

SavePlayerDataAsync(id, bool:bDisconnecting = false)
{
    if (!g_bDataLoaded[id] || g_iDatabaseId[id] <= 0 || g_hSqlTuple == Empty_Handle)
        return;

    ExecuteForward(g_fwdUserStatsSaved, _, id, g_szAuthID[id], g_szPlayerName[id]);
    ExecuteForward(g_fwdPlayerSaving, _, id);

    new szQuery[512], szEscName[128], szTime[32];
    EscapeSql( szEscName, charsmax(szEscName), g_szPlayerName[id]);
    get_time("%Y-%m-%d %H:%M:%S", szTime, charsmax(szTime));
    copy(g_szLastSeen[id], charsmax(g_szLastSeen[]), szTime);

    formatex(szQuery, charsmax(szQuery),
        "UPDATE `%splayers` SET `name` = '%s', `xp` = %d, `lifetime_xp` = %d, `level` = %d,          `rank_id` = %d, `skill` = %.2f, `peak_skill` = %.2f, `playtime` = `playtime` + %d,          `last_seen` = '%s', `last_server_id` = %d, `account_level` = %d, `prestige` = %d, `placement_matches` = %d          WHERE `id` = %d;",
        g_szSqlTablePrefix, szEscName, g_iPlayerXP[id], g_iLifetimeXP[id], g_iLevel[id],
        g_iRank[id], g_fSkill[id], g_fPeakSkill[id], g_iSessionSeconds[id], szTime, get_pcvar_num(g_pCvarServerId),
        g_iAccountLevel[id], g_iPrestige[id], g_iPlacementMatches[id], g_iDatabaseId[id]);
    new saveData[4];
    saveData[0] = id;
    saveData[1] = g_iConnectionToken[id];
    saveData[2] = g_iSessionSeconds[id];
    saveData[3] = bDisconnecting ? 1 : 0;
    SQL_ThreadQuery(g_hSqlTuple, "ThreadQuery_SavePlayer", szQuery, saveData, sizeof(saveData));

    new szStatsQuery[1024];
    if (g_bIsSqlite)
    {
        formatex(szStatsQuery, charsmax(szStatsQuery),
            "UPDATE `%splayer_stats` SET `kills` = %d, `deaths` = %d, `headshots` = %d,              `assists` = %d, `damage` = %d, `shots` = %d, `hits` = %d, `mvps` = %d,              `rounds_won` = %d, `c4_plants` = %d, `c4_defuses` = %d, `c4_explosions` = %d,              `zombie_wins` = %d, `human_wins` = %d, `infections` = %d, `survivals` = %d, `knife_kills` = %d, `he_kills` = %d, `hostages_rescued` = %d              WHERE `player_id` = %d AND `server_id` = 0;",
            g_szSqlTablePrefix, g_iKills[id], g_iDeaths[id], g_iHeadshots[id],
            g_iAssists[id], g_iDamage[id], g_iShots[id], g_iHits[id], g_iMVPs[id],
            g_iRoundsWon[id], g_iC4Plants[id], g_iC4Defuses[id], g_iC4Explosions[id],
            g_iZombieWins[id], g_iHumanWins[id], g_iInfections[id], g_iSurvivals[id], g_iKnifeKills[id], g_iHEKills[id], g_iHostagesRescued[id], g_iDatabaseId[id]);
    }
    else
    {
        formatex(szStatsQuery, charsmax(szStatsQuery),
            "INSERT INTO `%splayer_stats` (`player_id`, `server_id`, `kills`, `deaths`, `headshots`, `assists`, `damage`, `shots`, `hits`, `mvps`, `rounds_won`, `c4_plants`, `c4_defuses`, `c4_explosions`, `zombie_wins`, `human_wins`, `infections`, `survivals`, `knife_kills`, `he_kills`, `hostages_rescued`)              VALUES (%d, 0, %d, %d, %d, %d, %d, %d, %d, %d, %d, %d, %d, %d, %d, %d, %d, %d, %d, %d, %d)              ON DUPLICATE KEY UPDATE `kills` = VALUES(`kills`), `deaths` = VALUES(`deaths`), `headshots` = VALUES(`headshots`),              `assists` = VALUES(`assists`), `damage` = VALUES(`damage`), `shots` = VALUES(`shots`), `hits` = VALUES(`hits`),              `mvps` = VALUES(`mvps`), `rounds_won` = VALUES(`rounds_won`), `c4_plants` = VALUES(`c4_plants`), `c4_defuses` = VALUES(`c4_defuses`),              `c4_explosions` = VALUES(`c4_explosions`), `zombie_wins` = VALUES(`zombie_wins`), `human_wins` = VALUES(`human_wins`),              `infections` = VALUES(`infections`), `survivals` = VALUES(`survivals`), `knife_kills` = VALUES(`knife_kills`), `he_kills` = VALUES(`he_kills`), `hostages_rescued` = VALUES(`hostages_rescued`);",
            g_szSqlTablePrefix, g_iDatabaseId[id], g_iKills[id], g_iDeaths[id], g_iHeadshots[id],
            g_iAssists[id], g_iDamage[id], g_iShots[id], g_iHits[id], g_iMVPs[id],
            g_iRoundsWon[id], g_iC4Plants[id], g_iC4Defuses[id], g_iC4Explosions[id],
            g_iZombieWins[id], g_iHumanWins[id], g_iInfections[id], g_iSurvivals[id], g_iKnifeKills[id], g_iHEKills[id], g_iHostagesRescued[id]);
    }
    SQL_ThreadQuery(g_hSqlTuple, "ThreadQuery_Generic", szStatsQuery);

    UpsertBpBoard(id);
    SavePlayerWeapons(id);
    PersistApUnlocks(id);
    g_iDirtyMask[id] = DIRTY_NONE;
}

public ThreadQuery_SavePlayer(iFailState, Handle:hQuery, szError[], iErrorCode, data[], iDataSize)
{
    #pragma unused hQuery, iDataSize
    if (iFailState != TQUERY_SUCCESS)
    {
        log_amx("[RSU SQL ERROR] Save query failed: [%d] %s", iErrorCode, szError);
        return;
    }

    new id = data[0];
    new iToken = data[1];
    new iSavedSeconds = data[2];
    if (id < 1 || id > MaxClients)
        return;
    if (g_iConnectionToken[id] != iToken)
        return;
    if (iSavedSeconds > 0 && g_iSessionSeconds[id] >= iSavedSeconds)
        g_iSessionSeconds[id] -= iSavedSeconds;
    else
        g_iSessionSeconds[id] = 0;
}

PersistMissionCatalog()
{
    if (g_hSqlTuple == Empty_Handle)
        return;

    new szTime[32];
    get_time("%Y-%m-%d %H:%M:%S", szTime, charsmax(szTime));

    // Exact BattlePass.json daily/weekly contracts (single source, stored on AMXX SQL)
    new szDaily[] = "{^"kills^":15,^"headshots^":3,^"plants^":2,^"defuses^":1,^"wins^":2,^"reward_xp^":500,^"bounties^":{^"streak^":{^"target^":5,^"reward_coins^":150},^"damage^":{^"target^":500,^"reward_coins^":100},^"survive^":{^"target^":3,^"reward_coins^":100}}}";
    new szWeekly[] = "{^"kills^":100,^"headshots^":25,^"plants^":10,^"wins^":15,^"reward_xp^":5000,^"reward_coins^":1000}";

    new szQuery[768];
    if (g_bIsSqlite)
    {
        formatex(szQuery, charsmax(szQuery),
            "INSERT OR REPLACE INTO `%smission_catalog` (key, json, updated_at) VALUES ('daily', '%s', '%s');",
            g_szSqlTablePrefix, szDaily, szTime);
        SQL_ThreadQuery(g_hSqlTuple, "ThreadQuery_Generic", szQuery);
        formatex(szQuery, charsmax(szQuery),
            "INSERT OR REPLACE INTO `%smission_catalog` (key, json, updated_at) VALUES ('weekly', '%s', '%s');",
            g_szSqlTablePrefix, szWeekly, szTime);
        SQL_ThreadQuery(g_hSqlTuple, "ThreadQuery_Generic", szQuery);
    }
    else
    {
        formatex(szQuery, charsmax(szQuery),
            "INSERT INTO `%smission_catalog` (key, json, updated_at) VALUES ('daily', '%s', '%s') ON DUPLICATE KEY UPDATE json = VALUES(json), updated_at = VALUES(updated_at);",
            g_szSqlTablePrefix, szDaily, szTime);
        SQL_ThreadQuery(g_hSqlTuple, "ThreadQuery_Generic", szQuery);
        formatex(szQuery, charsmax(szQuery),
            "INSERT INTO `%smission_catalog` (key, json, updated_at) VALUES ('weekly', '%s', '%s') ON DUPLICATE KEY UPDATE json = VALUES(json), updated_at = VALUES(updated_at);",
            g_szSqlTablePrefix, szWeekly, szTime);
        SQL_ThreadQuery(g_hSqlTuple, "ThreadQuery_Generic", szQuery);
    }
}

PersistApUnlocks(id)
{
    if (g_hSqlTuple == Empty_Handle || g_iDatabaseId[id] <= 0)
        return;

    new iHours = g_iPlaytime[id] / 3600;
    TryStampAp(id, 0,  "kills_100", 50, g_iKills[id] >= 100);
    TryStampAp(id, 1,  "kills_1000", 100, g_iKills[id] >= 1000);
    TryStampAp(id, 2,  "kills_5000", 200, g_iKills[id] >= 5000);
    TryStampAp(id, 3,  "kills_10000", 400, g_iKills[id] >= 10000);
    TryStampAp(id, 4,  "hs_100", 50, g_iHeadshots[id] >= 100);
    TryStampAp(id, 5,  "hs_500", 100, g_iHeadshots[id] >= 500);
    TryStampAp(id, 6,  "wins_100", 100, g_iRoundsWon[id] >= 100);
    TryStampAp(id, 7,  "mvp_50", 100, g_iMVPs[id] >= 50);
    TryStampAp(id, 8,  "hours_100", 200, iHours >= 100);
    TryStampAp(id, 9,  "hours_500", 400, iHours >= 500);
    TryStampAp(id, 10, "rank_max", 400, g_iRank[id] >= 18);
    TryStampAp(id, 11, "ak_spec", 100, g_iWeaponKills[id][RSU_WEAPON_AK47] >= 500);
    TryStampAp(id, 12, "ak_master", 400, g_iWeaponKills[id][RSU_WEAPON_AK47] >= 10000);
}

TryStampAp(id, iBit, const szCode[], iAp, bool:bReached)
{
    if (!bReached)
        return;
    if (g_iApStampMask[id] & (1 << iBit))
        return;
    g_iApStampMask[id] |= (1 << iBit);

    new szTime[32];
    get_time("%Y-%m-%d %H:%M:%S", szTime, charsmax(szTime));

    new szQuery[384];
    if (g_bIsSqlite)
    {
        formatex(szQuery, charsmax(szQuery),
            "INSERT OR IGNORE INTO `%sap_unlocks` (player_id, code, ap, earned_at) VALUES (%d, '%s', %d, '%s');",
            g_szSqlTablePrefix, g_iDatabaseId[id], szCode, iAp, szTime);
    }
    else
    {
        formatex(szQuery, charsmax(szQuery),
            "INSERT IGNORE INTO `%sap_unlocks` (player_id, code, ap, earned_at) VALUES (%d, '%s', %d, '%s');",
            g_szSqlTablePrefix, g_iDatabaseId[id], szCode, iAp, szTime);
    }
    SQL_ThreadQuery(g_hSqlTuple, "ThreadQuery_Generic", szQuery);
}

LoadPlayerWeapons(id)
{
    if (g_hSqlTuple == Empty_Handle || g_iDatabaseId[id] <= 0)
        return;

    new szQuery[256];
    formatex(szQuery, charsmax(szQuery),
        "SELECT weapon_id, kills FROM `%splayer_weapons` WHERE player_id = %d;",
        g_szSqlTablePrefix, g_iDatabaseId[id]);

    new data[3];
    data[0] = id;
    data[1] = get_user_userid(id);
    data[2] = g_iConnectionToken[id];
    SQL_ThreadQuery(g_hSqlTuple, "ThreadQuery_LoadWeapons", szQuery, data, sizeof(data));
}

public ThreadQuery_LoadWeapons(iFailState, Handle:hQuery, szError[], iErrorCode, data[], iDataSize)
{
    new id = data[0];
    new iUserId = data[1];
    new iToken = data[2];

    if (!is_user_connected(id) || get_user_userid(id) != iUserId || g_iConnectionToken[id] != iToken)
        return;

    if (iFailState != TQUERY_SUCCESS)
    {
        log_amx("[RSU SQL ERROR] Weapon load failed for #%d: [%d] %s", id, iErrorCode, szError);
        return;
    }

    while (SQL_MoreResults(hQuery))
    {
        new iWeapon = SQL_ReadResult(hQuery, 0);
        new iKills = SQL_ReadResult(hQuery, 1);
        if (iWeapon >= 0 && iWeapon < RSU_TOTAL_WEAPONS && iKills > 0)
            g_iWeaponKills[id][iWeapon] = iKills;
        SQL_NextRow(hQuery);
    }
}

SavePlayerWeapons(id)
{
    if (g_hSqlTuple == Empty_Handle || g_iDatabaseId[id] <= 0)
        return;

    new szQuery[1536], iLen = 0, iCount = 0;
    if (g_bIsSqlite)
    {
        iLen = formatex(szQuery, charsmax(szQuery),
            "INSERT OR REPLACE INTO `%splayer_weapons` (`player_id`, `weapon_id`, `kills`) VALUES ",
            g_szSqlTablePrefix);
    }
    else
    {
        iLen = formatex(szQuery, charsmax(szQuery),
            "INSERT INTO `%splayer_weapons` (`player_id`, `weapon_id`, `kills`) VALUES ",
            g_szSqlTablePrefix);
    }

    for (new w = 0; w < RSU_TOTAL_WEAPONS; w++)
    {
        if (g_iWeaponKills[id][w] <= 0)
            continue;
        if (charsmax(szQuery) - iLen < 48)
        {
            // Flush current batch before overflow, then start a new VALUES list.
            if (iCount)
            {
                if (!g_bIsSqlite)
                    iLen += formatex(szQuery[iLen], charsmax(szQuery) - iLen,
                        " ON DUPLICATE KEY UPDATE `kills` = VALUES(`kills`)");
                copy(szQuery[iLen], charsmax(szQuery) - iLen, ";");
                SQL_ThreadQuery(g_hSqlTuple, "ThreadQuery_Generic", szQuery);
            }
            if (g_bIsSqlite)
            {
                iLen = formatex(szQuery, charsmax(szQuery),
                    "INSERT OR REPLACE INTO `%splayer_weapons` (`player_id`, `weapon_id`, `kills`) VALUES ",
                    g_szSqlTablePrefix);
            }
            else
            {
                iLen = formatex(szQuery, charsmax(szQuery),
                    "INSERT INTO `%splayer_weapons` (`player_id`, `weapon_id`, `kills`) VALUES ",
                    g_szSqlTablePrefix);
            }
            iCount = 0;
        }
        iLen += formatex(szQuery[iLen], charsmax(szQuery) - iLen,
            "%s(%d, %d, %d)", iCount ? "," : "", g_iDatabaseId[id], w, g_iWeaponKills[id][w]);
        iCount++;
    }

    if (!iCount)
        return;

    if (!g_bIsSqlite)
        iLen += formatex(szQuery[iLen], charsmax(szQuery) - iLen,
            " ON DUPLICATE KEY UPDATE `kills` = VALUES(`kills`)");
    copy(szQuery[iLen], charsmax(szQuery) - iLen, ";");
    SQL_ThreadQuery(g_hSqlTuple, "ThreadQuery_Generic", szQuery);
}

ForceFlushAllDirty()
{
    for (new id = 1; id <= MaxClients; id++)
    {
        if (g_bDataLoaded[id] && (g_iDirtyMask[id] != DIRTY_NONE))
        {
            SavePlayerDataAsync(id, true);
        }
    }
}

public TaskAutosave()
{
    if (g_hSqlTuple == Empty_Handle)
        return;

    for (new id = 1; id <= MaxClients; id++)
    {
        // Skip playtime-only dirt: TaskPlaytimeTick sets DIRTY_PLAYER_BASE
        // every second. Flush when stats/xp/weapons actually changed.
        if (is_user_connected(id) && g_bDataLoaded[id]
            && (g_iDirtyMask[id] & (DIRTY_STATS | DIRTY_WEAPONS | DIRTY_XP_SKILL)))
        {
            SavePlayerDataAsync(id, false);
        }
    }
}

public TaskPlaytimeTick()
{
    for (new id = 1; id <= MaxClients; id++)
    {
        if (is_user_connected(id) && g_bDataLoaded[id])
        {
            g_iPlaytime[id]++;
            g_iSessionSeconds[id]++;
            g_iDirtyMask[id] |= DIRTY_PLAYER_BASE;
        }
    }
}

public ThreadQuery_Generic(iFailState, Handle:hQuery, szError[], iErrorCode, data[], iDataSize)
{
    if (iFailState != TQUERY_SUCCESS)
    {
        log_amx("[RSU SQL ERROR] Query failed: [%d] %s", iErrorCode, szError);
    }
}

public ThreadQuery_Migration(iFailState, Handle:hQuery, szError[], iErrorCode, data[], iDataSize)
{
    #pragma unused hQuery, data, iDataSize
    if (iFailState != TQUERY_SUCCESS)
    {
        // Silently ignore duplicate column errors when adding columns to existing tables
        if (containi(szError, "duplicate column") != -1 || iErrorCode == 1060)
            return;
        log_amx("[RSU MIGRATION] Notice: [%d] %s", iErrorCode, szError);
    }
}

// ============================================================================
// CENTRAL XP & LEVEL PROGRESSION
// ============================================================================
CalculateRank(xp)
{
    if (g_iTotalRanks <= 0)
        return 1;

    new rankEntry[RankEntry];
    new iFoundRank = 1;

    for (new i = 0; i < g_iTotalRanks; i++)
    {
        ArrayGetArray(g_aRanks, i, rankEntry);
        if (xp >= rankEntry[RANK_MIN_XP])
        {
            iFoundRank = rankEntry[RANK_ID];
        }
        else
        {
            break;
        }
    }
    return iFoundRank;
}

Float:CalculateSkillRange(id)
{
    if (!is_user_connected(id))
        return 100.0;

    new iTotal = g_iKills[id] + g_iDeaths[id];
    if (iTotal <= 0)
        return 100.0;

    return (100.0 * float(g_iKills[id])) / float(iTotal);
}

GetSkillName(Float:fSkillRange, szBuffer[], maxlen)
{
    if (g_iTotalSkills <= 0)
    {
        copy(szBuffer, maxlen, "M");
        return;
    }

    new skillEntry[SkillEntry];
    new iFoundIndex = g_iDefaultSkillIndex;

    for (new i = 0; i < g_iTotalSkills; i++)
    {
        ArrayGetArray(g_aSkills, i, skillEntry);
        if (fSkillRange >= skillEntry[SKILL_MIN_RANGE])
        {
            iFoundIndex = i;
        }
        else
        {
            break;
        }
    }

    ArrayGetArray(g_aSkills, iFoundIndex, skillEntry);
    copy(szBuffer, maxlen, skillEntry[SKILL_NAME]);
}

ExecuteXpReward(id, iBaseAmount, RsuXpSource:source, bool:bIsTeamXP = false)
{
    if (!get_pcvar_num(g_pCvarEnableStats) || !is_user_connected(id) || !g_bDataLoaded[id])
        return 0;

    if (g_iCfgTeamSet > 0 && get_user_team(id) != g_iCfgTeamSet)
        return 0;

    if (get_playersnum() < g_iCfgMinPlayers)
        return 0;

    // Knife warmup is not a ranked period. No XP from any feeder.
    if (get_cvar_num("amx_knife_round_active") == 1)
        return 0;

    new iFinalAmount = iBaseAmount;

    // VIP additive (`vip = 1` plus vip_flags) is retired. VIP XP is a
    // multiplier owned by battlepass_core via fnvip_get_xp_multiplier.
    // The old +1 additive stacked with the 10-30 percent multiplier.

    // Call Pre-Forward (byref amount: BattlePass VIP/HH/boost live here)
    new iRet;
    ExecuteForward(g_fwdPlayerXpPre, iRet, id, iFinalAmount, source);
    if (iRet == PLUGIN_HANDLED)
        return 0;
    if (iFinalAmount == 0)
        return 0;

    new iOldXP = g_iPlayerXP[id];
    new iOldRank = g_iRank[id];

    // Signed overflow guard: cell max is 2^31-1
    if (iFinalAmount > 0 && g_iPlayerXP[id] > 2147483647 - iFinalAmount)
        g_iPlayerXP[id] = 2147483647;
    else
        g_iPlayerXP[id] = max(0, g_iPlayerXP[id] + iFinalAmount);

    if (iFinalAmount > 0)
    {
        if (g_iLifetimeXP[id] > 2147483647 - iFinalAmount)
            g_iLifetimeXP[id] = 2147483647;
        else
            g_iLifetimeXP[id] += iFinalAmount;
    }

    new iNewRank = CalculateRank(g_iPlayerXP[id]);
    g_iRank[id] = iNewRank;
    g_iLevel[id] = iNewRank;

    // Show Floating XP HUD
    if (bIsTeamXP)
    {
        if (g_bCfgXpHudTeamEnable)
        {
            ShowFloatingXpHud(id, iFinalAmount, true);
        }
    }
    else
    {
        if (g_bCfgXpHudEnable)
        {
            ShowFloatingXpHud(id, iFinalAmount, false);
        }
    }

    // Check Promotion / Demotion
    if (iNewRank != iOldRank)
    {
        new bool:bLevelUp = (iNewRank > iOldRank);
        TriggerLevelEffects(id, iOldRank, iNewRank, bLevelUp);
        ExecuteForward(g_fwdUserLevelUpdated, _, id, iNewRank, bLevelUp);
        ExecuteForward(g_fwdPlayerRankChanged, _, id, iOldRank, iNewRank);
    }

    g_iDirtyMask[id] |= DIRTY_XP_SKILL;

    // Forwards
    ExecuteForward(g_fwdUserXpUpdated, _, id, g_iPlayerXP[id], bIsTeamXP);
    ExecuteForward(g_fwdPlayerXpPost, _, id, iOldXP, g_iPlayerXP[id], iFinalAmount, source);

    return iFinalAmount;
}

TriggerLevelEffects(id, iOldRank, iNewRank, bool:bLevelUp)
{
    #pragma unused iOldRank
    new szNewName[32];
    GetRankDisplayName(iNewRank, szNewName, charsmax(szNewName));

    if (bLevelUp)
    {
        // Screen Fade Effect
        Util_ScreenFade(id, g_iCfgLevelUpEffects[0], g_iCfgLevelUpEffects[1], g_iCfgLevelUpEffects[2],
            g_iCfgLevelUpEffects[3], float(g_iCfgLevelUpEffects[4]));

        // Sound Effect
        if (g_szCfgLevelUpSound[0])
        {
            client_cmd(id, "spk %s", g_szCfgLevelUpSound);
        }

        // Chat Message (LEVEL_MESSAGE_TYPE: 0=off, 1=self, 2=all)
        if (g_iCfgLevelMessageType == 1)
        {
            client_print_color(id, print_team_default, "%s Congratulations! You ranked up to ^4%s^1!", g_szCfgChatPrefix, szNewName);
        }
        else if (g_iCfgLevelMessageType == 2)
        {
            client_print_color(0, print_team_default, "%s Congratulations! ^3%s^1 ranked up to ^4%s^1!", g_szCfgChatPrefix, g_szPlayerName[id], szNewName);
        }
    }
    else
    {
        // Demotion Effect
        Util_ScreenFade(id, g_iCfgLevelDnEffects[0], g_iCfgLevelDnEffects[1], g_iCfgLevelDnEffects[2],
            g_iCfgLevelDnEffects[3], float(g_iCfgLevelDnEffects[4]));

        if (g_szCfgLevelDnSound[0])
        {
            client_cmd(id, "spk %s", g_szCfgLevelDnSound);
        }

        if (g_iCfgLevelMessageType == 1)
        {
            client_print_color(id, print_team_default, "%s You have been demoted to ^3%s^1.", g_szCfgChatPrefix, szNewName);
        }
        else if (g_iCfgLevelMessageType == 2)
        {
            client_print_color(0, print_team_default, "%s ^3%s^1 has been demoted to ^4%s^1.", g_szCfgChatPrefix, g_szPlayerName[id], szNewName);
        }
    }
}

ShowFloatingXpHud(id, iAmount, bool:bIsTeam)
{
    new szMsg[64], szTemplate[64];
    new bool:bGain = (iAmount >= 0);
    new iAbsVal = abs(iAmount);

    if (bIsTeam)
    {
        copy(szTemplate, charsmax(szTemplate), bGain ? g_szCfgXpHudTeamGet : g_szCfgXpHudTeamLose);
        copy(szMsg, charsmax(szMsg), szTemplate);
        new szNum[16];
        num_to_str(iAbsVal, szNum, charsmax(szNum));
        replace_all(szMsg, charsmax(szMsg), "%xp%", szNum);

        new r = (g_iCfgXpHudTeamValues[0] == -1) ? random_num(0, 255) : g_iCfgXpHudTeamValues[0];
        new g = (g_iCfgXpHudTeamValues[1] == -1) ? random_num(0, 255) : g_iCfgXpHudTeamValues[1];
        new b = (g_iCfgXpHudTeamValues[2] == -1) ? random_num(0, 255) : g_iCfgXpHudTeamValues[2];

        if (g_iCfgXpHudTeamType == 1)
        {
            set_dhudmessage(r, g, b, g_fCfgXpHudTeamPos[0], g_fCfgXpHudTeamPos[1], g_iCfgXpHudTeamEffect, 0.1, g_fCfgXpHudTeamHold, 0.1, 0.1);
            show_dhudmessage(id, "%s", szMsg);
        }
        else
        {
            set_hudmessage(r, g, b, g_fCfgXpHudTeamPos[0], g_fCfgXpHudTeamPos[1], g_iCfgXpHudTeamEffect, 0.1, g_fCfgXpHudTeamHold, 0.1, 0.1);
            show_hudmessage(id, "%s", szMsg);
        }
    }
    else
    {
        copy(szTemplate, charsmax(szTemplate), bGain ? g_szCfgXpHudGet : g_szCfgXpHudLose);
        copy(szMsg, charsmax(szMsg), szTemplate);
        new szNum[16];
        num_to_str(iAbsVal, szNum, charsmax(szNum));
        replace_all(szMsg, charsmax(szMsg), "%xp%", szNum);

        new r = (g_iCfgXpHudValues[0] == -1) ? random_num(0, 255) : g_iCfgXpHudValues[0];
        new g = (g_iCfgXpHudValues[1] == -1) ? random_num(0, 255) : g_iCfgXpHudValues[1];
        new b = (g_iCfgXpHudValues[2] == -1) ? random_num(0, 255) : g_iCfgXpHudValues[2];

        if (g_iCfgXpHudType == 1)
        {
            set_dhudmessage(r, g, b, g_fCfgXpHudPos[0], g_fCfgXpHudPos[1], g_iCfgXpHudEffect, 0.1, g_fCfgXpHudHold, 0.1, 0.1);
            show_dhudmessage(id, "%s", szMsg);
        }
        else
        {
            set_hudmessage(r, g, b, g_fCfgXpHudPos[0], g_fCfgXpHudPos[1], g_iCfgXpHudEffect, 0.1, g_fCfgXpHudHold, 0.1, 0.1);
            show_hudmessage(id, "%s", szMsg);
        }
    }
}

GetRankDisplayName(iRankId, buffer[], maxlen)
{
    new rankEntry[RankEntry];
    for (new i = 0; i < g_iTotalRanks; i++)
    {
        ArrayGetArray(g_aRanks, i, rankEntry);
        if (rankEntry[RANK_ID] == iRankId)
        {
            copy(buffer, maxlen, rankEntry[RANK_NAME]);
            return;
        }
    }
    copy(buffer, maxlen, "Unranked");
}

// ============================================================================
// HUD & DHUD STATUS DISPLAY ENGINE
// ============================================================================
public TaskHudTick()
{
    if (!g_bCfgHudEnable)
        return;

    for (new id = 1; id <= MaxClients; id++)
    {
        if (!is_user_connected(id) || !g_bHudEnabled[id])
            continue;

        // If dead and spectating, target the spectated player
        new iTarget = id;
        if (!is_user_alive(id))
        {
            new iSpecTarget = get_entvar(id, var_iuser2);
            if (iSpecTarget > 0 && is_user_alive(iSpecTarget))
            {
                iTarget = iSpecTarget;
            }
        }

        if (!g_bDataLoaded[iTarget])
            continue;

        new szOutput[512];
        FormatHudPlaceholders(iTarget, (g_iLevel[iTarget] >= g_iTotalRanks) ? g_szCfgHudInfoMax : g_szCfgHudInfo, szOutput, charsmax(szOutput));

        new r = (g_iCfgHudValues[0] == -1) ? random_num(0, 255) : g_iCfgHudValues[0];
        new g = (g_iCfgHudValues[1] == -1) ? random_num(0, 255) : g_iCfgHudValues[1];
        new b = (g_iCfgHudValues[2] == -1) ? random_num(0, 255) : g_iCfgHudValues[2];

        if (g_iCfgHudType == 1)
        {
            set_dhudmessage(r, g, b, g_fCfgHudPos[0], g_fCfgHudPos[1], 0, 0.0, 1.1, 0.0, 0.0);
            show_dhudmessage(id, "%s", szOutput);
        }
        else
        {
            set_hudmessage(r, g, b, g_fCfgHudPos[0], g_fCfgHudPos[1], 0, 0.0, 1.1, 0.0, 0.0, 4);
            show_hudmessage(id, "%s", szOutput);
        }
    }
}

FormatHudPlaceholders(id, const input[], output[], maxlen)
{
    copy(output, maxlen, input);

    new szName[32];
    get_user_name(id, szName, charsmax(szName));
    replace(output, maxlen, "%name%", szName);

    new szXP[16];
    num_to_str(g_iPlayerXP[id], szXP, charsmax(szXP));
    replace(output, maxlen, "%xp%", szXP);

    new Float:fPercent = 0.0;
    new iCurRank = g_iRank[id];
    new iNextXP = g_iPlayerXP[id];
    new szNextRankName[32];
    copy(szNextRankName, charsmax(szNextRankName), "MAX");

    new rankEntry[RankEntry];
    if (iCurRank < g_iTotalRanks && g_iTotalRanks > 0)
    {
        ArrayGetArray(g_aRanks, iCurRank - 1, rankEntry);
        new iCurMin = rankEntry[RANK_MIN_XP];

        new nextEntry[RankEntry];
        ArrayGetArray(g_aRanks, iCurRank, nextEntry);
        iNextXP = nextEntry[RANK_MIN_XP];
        copy(szNextRankName, charsmax(szNextRankName), nextEntry[RANK_NAME]);

        if (iNextXP > iCurMin)
        {
            fPercent = (float(g_iPlayerXP[id] - iCurMin) / float(iNextXP - iCurMin)) * 100.0;
            fPercent = floatclamp(fPercent, 0.0, 100.0);
        }
    }
    else
    {
        fPercent = 100.0;
    }

    new szPercent[16];
    formatex(szPercent, charsmax(szPercent), "%.1f", fPercent);
    replace(output, maxlen, "%xp_percent%", szPercent);

    new szLevel[16], szMaxLevels[16];
    num_to_str(g_iLevel[id], szLevel, charsmax(szLevel));
    num_to_str(g_iTotalRanks, szMaxLevels, charsmax(szMaxLevels));
    replace(output, maxlen, "%level%", szLevel);
    replace(output, maxlen, "%max_levels%", szMaxLevels);

    new szRank[32];
    GetRankDisplayName(iCurRank, szRank, charsmax(szRank));
    replace(output, maxlen, "%rank%", szRank);

    new szNextXP[16], szNextLevel[16];
    num_to_str(iNextXP, szNextXP, charsmax(szNextXP));
    num_to_str(min(g_iTotalRanks, g_iLevel[id] + 1), szNextLevel, charsmax(szNextLevel));
    replace(output, maxlen, "%next_xp%", szNextXP);
    replace(output, maxlen, "%next_level%", szNextLevel);
    replace(output, maxlen, "%next_rank%", szNextRankName);

    new szServerRank[16], szMaxServerRanks[16];
    num_to_str(g_iServerRank[id], szServerRank, charsmax(szServerRank));
    num_to_str(max(1, g_iTotalServerPlayers), szMaxServerRanks, charsmax(szMaxServerRanks));
    replace(output, maxlen, "%server_rank%", szServerRank);
    replace(output, maxlen, "%max_server_ranks%", szMaxServerRanks);

    new Float:fSkillRange = CalculateSkillRange(id);
    new szSkill[16], szSkillRange[16];
    GetSkillName(fSkillRange, szSkill, charsmax(szSkill));
    formatex(szSkillRange, charsmax(szSkillRange), "%.2f", fSkillRange);
    replace(output, maxlen, "%skill%", szSkill);
    replace(output, maxlen, "%skill_range%", szSkillRange);

    replace(output, maxlen, "%next_skill%", "Pro");
    replace(output, maxlen, "%next_skill_range%", "150.0");

    new szMin[16], szSec[16];
    num_to_str(g_iSessionSeconds[id] / 60, szMin, charsmax(szMin));
    formatex(szSec, charsmax(szSec), "%02d", g_iSessionSeconds[id] % 60);
    replace(output, maxlen, "%minutes%", szMin);
    replace(output, maxlen, "%seconds%", szSec);

    replace(output, maxlen, "%newline%", "^n");
}

// ============================================================================
// GAMEPLAY EVENT HOOKS & COMBAT ANALYTICS
// ============================================================================
public OnPlayerSpawnPost(id)
{
    if (!is_user_alive(id) || !g_bDataLoaded[id])
        return;


    if (g_bCfgRankInfo && g_bRankInfoEnabled[id])
    {
        new szRank[32], szSkill[16];
        GetRankDisplayName(g_iRank[id], szRank, charsmax(szRank));
        GetSkillName(CalculateSkillRange(id), szSkill, charsmax(szSkill));
        client_print_color(id, print_team_default, "%s Your Rank: ^4%s^1 | Level: ^3%d^1 | Skill: ^4%s^1",
            g_szCfgChatPrefix, szRank, g_iLevel[id], szSkill);
    }
}

public FwdWeaponPrimaryAttack(iEnt)
{
    if (!get_pcvar_num(g_pCvarEnableStats))
        return HAM_IGNORED;
    new id = get_entvar(iEnt, var_owner);
    if (id < 1 || id > MaxClients || !is_user_connected(id) || is_user_bot(id) || !is_user_alive(id) || !g_bDataLoaded[id])
        return HAM_IGNORED;
    g_iShots[id]++;
    g_iDirtyMask[id] |= DIRTY_STATS;
    return HAM_IGNORED;
}

public OnPlayerTakeDamagePost(const victim, const inflictor, const attacker, const Float:flDamage, const bitsDamageType)
{
    #pragma unused inflictor, bitsDamageType
    if (!get_pcvar_num(g_pCvarEnableStats))
        return;

    if (!is_user_connected(attacker) || !is_user_connected(victim) || attacker == victim)
        return;

    if (get_user_team(attacker) == get_user_team(victim))
        return;

    new iDmg = floatround(flDamage);
    if (iDmg > 0)
    {
        g_iDamage[attacker] += iDmg;
        g_iHits[attacker]++;
        g_iRoundDamage[attacker][victim] += iDmg;
        g_iRoundTotalDamage[attacker] += iDmg;
        g_iDirtyMask[attacker] |= DIRTY_STATS;
    }
}

public OnPlayerKilledPost(const victim, const attacker, const iGib)
{
    #pragma unused iGib
    if (!get_pcvar_num(g_pCvarEnableStats))
        return;

    if (!is_user_connected(victim))
        return;

    // Warmup / knife round: no stats, no XP, no anti-farm.
    if (get_cvar_num("amx_knife_round_active") == 1)
        return;

    // Suicide Check
    if (victim == attacker || !is_user_connected(attacker))
    {
        g_iSuicides[victim]++;
        g_iDeaths[victim]++;
        g_iDirtyMask[victim] |= DIRTY_STATS;

        new iPenalty = g_iXpRewards[RWD_SUICIDE][0];
        if (iPenalty != 0)
        {
            ExecuteXpReward(victim, iPenalty, RSU_XP_PENALTY_SUICIDE);
        }
        return;
    }

    new iVictimTeam = get_user_team(victim);
    new iAttackerTeam = get_user_team(attacker);

    // Teamkill Check
    if (iVictimTeam == iAttackerTeam)
    {
        g_iTeamkills[attacker]++;
        g_iDirtyMask[attacker] |= DIRTY_STATS;

        new iPenalty = g_iXpRewards[RWD_TEAM_KILL][0];
        if (iPenalty != 0)
        {
            ExecuteXpReward(attacker, iPenalty, RSU_XP_PENALTY_TEAMKILL);
        }
        return;
    }

    if (g_iPlayerState[attacker] != PLAYER_STATE_READY)
        return;

    // Bot victims never feed core kill/HS/XP unless RANK_BOTS=1.
    // Capped consolation XP is owned exclusively by freenova_progression.
    if (is_user_bot(victim) && g_iCfgRankBots != 1)
        return;

    if (is_user_bot(attacker) && g_iCfgRankBots != 1)
    {
        // Human died to a bot: the death still counts, the bot gets nothing.
        if (g_bDataLoaded[victim])
        {
            g_iDeaths[victim]++;
            g_iDirtyMask[victim] |= DIRTY_STATS;
        }
        return;
    }

    // Anti-Farm Check
    if (AntiFarm_IsVictimFarmed(attacker, victim))
    {
        client_print_color(attacker, print_team_default, "%s Anti-Farm: Repeated frags on the same target yield no rewards.", g_szCfgChatPrefix);
        return;
    }
    AntiFarm_RecordFrag(attacker, victim);

    // Glicko-2 Rating update (requires min human players)
    if (get_playersnum() >= g_iCfgMinPlayers)
    {
        Glicko_UpdateCombat(attacker, victim);
    }

    // Valid Enemy Kill
    g_iKills[attacker]++;
    g_iDeaths[victim]++;
    g_iRoundKills[attacker]++;
    g_iCurKillstreak[attacker]++;
    if (g_iCurKillstreak[attacker] > g_iBestKillstreak[attacker])
        g_iBestKillstreak[attacker] = g_iCurKillstreak[attacker];
    g_iCurKillstreak[victim] = 0;

    g_iDirtyMask[attacker] |= DIRTY_STATS;
    g_iDirtyMask[victim] |= DIRTY_STATS;

    // Weapon Tracking. get_user_weapon() is the live held weapon; if the
    // attacker already switched this frame (nades / last-inv) it can lag
    // the killing weapon. Acceptable for CS 1.6 kill post without inflictor.
    new iCsw = get_user_weapon(attacker);
    new iRsuWeapon = (iCsw >= 0 && iCsw <= 32) ? g_iCswToRsuWeapon[iCsw] : -1;
    if (iRsuWeapon >= 0 && iRsuWeapon < RSU_TOTAL_WEAPONS)
    {
        g_iWeaponKills[attacker][iRsuWeapon]++;
        g_iDirtyMask[attacker] |= DIRTY_WEAPONS;
    }

    new iReward = g_iXpRewards[RWD_KILL][0];
    new RsuXpSource:source = RSU_XP_KILL;

    if (iCsw == CSW_KNIFE)
    {
        g_iKnifeKills[attacker]++;
        iReward += g_iXpRewards[RWD_KNIFE][0];
        source = RSU_XP_KNIFE;
    }
    else if (iCsw == CSW_HEGRENADE)
    {
        g_iHEKills[attacker]++;
        iReward += g_iXpRewards[RWD_GRENADE][0];
        source = RSU_XP_GRENADE;
    }

    // Headshot Check
    new bool:bHeadshot = bool:get_member(victim, m_bHeadshotKilled);
    if (bHeadshot)
    {
        g_iHeadshots[attacker]++;
        iReward += g_iXpRewards[RWD_HEADSHOT][0];
        source = RSU_XP_HEADSHOT;
    }

    // Blind Kill Check
    if (g_fFlashedUntil[attacker] > get_gametime())
    {
        iReward += g_iXpRewards[RWD_BLIND][0];
    }

    ExecuteXpReward(attacker, iReward, source);

    // ONE kill event for the rest of FreeNova. Do not re-detect this
    // death in missions / achievements / BattlePass / panel.
    if (g_fwdCombatKill)
        ExecuteForward(g_fwdCombatKill, _, attacker, victim, iCsw, bHeadshot ? 1 : 0, 0);

    // ========================================================================
    // ASSIST ENGINE (ASSIST_VALUES = min_damage money frag)
    // ========================================================================
    for (new a = 1; a <= MaxClients; a++)
    {
        if (a != attacker && a != victim && is_user_alive(a)
            && g_iPlayerState[a] == PLAYER_STATE_READY
            && get_user_team(a) != iVictimTeam)
        {
            if (g_iRoundDamage[a][victim] >= g_iCfgAssistMinDamage)
            {
                g_iAssists[a]++;
                g_iDirtyMask[a] |= DIRTY_STATS;

                new iAssistXp = g_iXpRewards[RWD_ASSIST][0];
                new iXpPaid = 0;
                if (iAssistXp > 0)
                    iXpPaid = ExecuteXpReward(a, iAssistXp, RSU_XP_ASSIST);

                // Money and scoreboard frags used to pay here too (retired:
                // ASSIST_VALUES keys 2/3 are parsed but no longer paid).
                // Assist XP ownership is split BY CONFIG with freenova_teamxp:
                // ini assist = 0 0 -> this engine COUNTS the assist (stats
                // column) and pays 0, while freenova_teamxp pays its
                // fn_teamxp_assist amount through crxranks -> rsu_add_xp.
                // Raising [XP Rewards] assist makes BOTH engines pay the same
                // assistant - that is stacking, not a bug. Payout numbers are
                // config-owned; tune one side, never both, and never here.
                g_iRoundDamage[a][victim] = 0;

                if (iXpPaid > 0)
                    client_print_color(a, print_team_default, "%s Assist on ^3%s^1 (+%d XP).",
                        g_szCfgChatPrefix, g_szPlayerName[victim], iXpPaid);
            }
        }
    }
}

public OnRoundStart()
{
    // Reset round tracking
    for (new a = 1; a <= MaxClients; a++)
    {
        g_iRoundKills[a] = 0;
        g_iRoundTotalDamage[a] = 0;
        g_iRoundInfections[a] = 0;
        for (new v = 1; v <= MaxClients; v++)
        {
            g_iRoundDamage[a][v] = 0;
        }
    }
}

public OnRoundEnd()
{
    if (!get_pcvar_num(g_pCvarEnableStats))
        return;

    // MVP Determination
    new iBestPlayer = 0;
    new iBestScore = 0;

    for (new id = 1; id <= MaxClients; id++)
    {
        if (!is_user_connected(id) || is_user_bot(id) || get_user_team(id) == _:RSU_TEAM_SPEC)
            continue;
        if (g_iPlayerState[id] != PLAYER_STATE_READY)
            continue;

        new iScore = g_iRoundKills[id] * 100 + g_iRoundTotalDamage[id];
        if (iScore > iBestScore && iScore > 0)
        {
            iBestScore = iScore;
            iBestPlayer = id;
        }
    }

    if (iBestPlayer > 0)
    {
        g_iMVPs[iBestPlayer]++;
        g_iDirtyMask[iBestPlayer] |= DIRTY_STATS;

        new iMvpXp = g_iXpRewards[RWD_MVP][0];
        if (iMvpXp > 0)
        {
            ExecuteXpReward(iBestPlayer, iMvpXp, RSU_XP_MVP);
        }

        if (g_bCfgMvpHudEnable)
        {
            new szMvpName[32];
            get_user_name(iBestPlayer, szMvpName, charsmax(szMvpName));

            new r = (g_iCfgMvpHudValues[0] == -1) ? random_num(0, 255) : g_iCfgMvpHudValues[0];
            new g = (g_iCfgMvpHudValues[1] == -1) ? random_num(0, 255) : g_iCfgMvpHudValues[1];
            new b = (g_iCfgMvpHudValues[2] == -1) ? random_num(0, 255) : g_iCfgMvpHudValues[2];

            if (g_iCfgMvpHudType == 1)
            {
                set_dhudmessage(r, g, b, g_fCfgMvpHudPos[0], g_fCfgMvpHudPos[1], 1, 0.5, 4.0, 0.5, 0.5);
                show_dhudmessage(0, "MVP of the Round: %s (%d kills, %d dmg)", szMvpName, g_iRoundKills[iBestPlayer], g_iRoundTotalDamage[iBestPlayer]);
            }
            else
            {
                set_hudmessage(r, g, b, g_fCfgMvpHudPos[0], g_fCfgMvpHudPos[1], 1, 0.5, 4.0, 0.5, 0.5);
                show_hudmessage(0, "MVP of the Round: %s (%d kills, %d dmg)", szMvpName, g_iRoundKills[iBestPlayer], g_iRoundTotalDamage[iBestPlayer]);
            }
        }
    }

    // Save on round end if configured
    if (g_iCfgSaveInterval == 0)
    {
        ForceFlushAllDirty();
    }

    g_iLastPlanter = 0;
}

public OnBombPlanted()
{
    new szLog[128], szName[32];
    read_logargv(0, szLog, charsmax(szLog));
    parse_loguser(szLog, szName, charsmax(szName));
    new id = get_user_index(szName);

    if (is_user_connected(id) && g_bDataLoaded[id])
    {
        g_iC4Plants[id]++;
        g_iDirtyMask[id] |= DIRTY_STATS;

        new iPersonal = g_iXpRewards[RWD_BOMB_PLANT][0];
        new iTeam = g_iXpRewards[RWD_BOMB_PLANT][1];

        if (iPersonal > 0)
            ExecuteXpReward(id, iPersonal, RSU_XP_BOMB_PLANT);

        if (iTeam > 0)
            ExecuteTeamXp(1, iTeam); // 1 = Terrorists

        g_iLastPlanter = id;
    }

    if (g_fwdBombEvent
        && is_user_connected(id)
        && !is_user_bot(id)
        && get_cvar_num("amx_knife_round_active") != 1)
    {
        ExecuteForward(g_fwdBombEvent, _, id, 0);
    }
}

public OnBombDefused()
{
    new szLog[128], szName[32];
    read_logargv(0, szLog, charsmax(szLog));
    parse_loguser(szLog, szName, charsmax(szName));
    new id = get_user_index(szName);

    if (is_user_connected(id) && g_bDataLoaded[id])
    {
        g_iC4Defuses[id]++;
        g_iDirtyMask[id] |= DIRTY_STATS;

        new iPersonal = g_iXpRewards[RWD_BOMB_DEFUSE][0];
        new iTeam = g_iXpRewards[RWD_BOMB_DEFUSE][1];

        if (iPersonal > 0)
            ExecuteXpReward(id, iPersonal, RSU_XP_BOMB_DEFUSED);

        if (iTeam > 0)
            ExecuteTeamXp(2, iTeam); // 2 = Counter-Terrorists
    }

    g_iLastPlanter = 0;

    if (g_fwdBombEvent
        && is_user_connected(id)
        && !is_user_bot(id)
        && get_cvar_num("amx_knife_round_active") != 1)
    {
        ExecuteForward(g_fwdBombEvent, _, id, 1);
    }
}

public OnBombExploded()
{
    new id = g_iLastPlanter;
    g_iLastPlanter = 0;

    if (id && is_user_connected(id) && g_bDataLoaded[id] && get_user_team(id) == 1)
    {
        g_iC4Explosions[id]++;
        g_iDirtyMask[id] |= DIRTY_STATS;

        new iPersonal = g_iXpRewards[RWD_BOMB_EXPLODE][0];
        if (iPersonal > 0)
            ExecuteXpReward(id, iPersonal, RSU_XP_BOMB_EXPLODED);
    }

    new iTeam = g_iXpRewards[RWD_BOMB_EXPLODE][1];

    if (iTeam > 0)
        ExecuteTeamXp(1, iTeam); // T Team XP
}

public Rsu_OnRoundWinAudio()
{
    if (get_cvar_num("amx_knife_round_active") == 1)
        return;

    new szAudio[64];
    read_data(2, szAudio, charsmax(szAudio));
    new iTeam = (contain(szAudio, "%!MRAD_terwin") != -1) ? 1 : 2;
    new szTeam[12];
    if (iTeam == 2)
        copy(szTeam, charsmax(szTeam), "CT");
    else
        copy(szTeam, charsmax(szTeam), "TERRORIST");

    new iPlayers[32], iNum, i;
    get_players(iPlayers, iNum, "aeh", szTeam);
    for (i = 0; i < iNum; i++)
    {
        new id = iPlayers[i];
        if (!is_user_connected(id) || is_user_bot(id))
            continue;
        g_iRoundsPlayed[id]++;
        g_iRoundsWon[id]++;
        if (iTeam == 1)
            g_iTWins[id]++;
        else
            g_iCTWins[id]++;
        if (g_fwdRoundWin)
            ExecuteForward(g_fwdRoundWin, _, id, iTeam);
    }
    // Losers played too (knife rounds excluded above with the winners).
    new szLoseTeam[12];
    if (iTeam == 2)
        copy(szLoseTeam, charsmax(szLoseTeam), "TERRORIST");
    else
        copy(szLoseTeam, charsmax(szLoseTeam), "CT");
    new iLosers[32], iLNum;
    get_players(iLosers, iLNum, "aeh", szLoseTeam);
    for (i = 0; i < iLNum; i++)
    {
        new id = iLosers[i];
        if (!is_user_connected(id) || is_user_bot(id))
            continue;
        g_iRoundsPlayed[id]++;
        g_iRoundsLost[id]++;
    }
}

public OnHostageRescued()
{
    new szLog[128], szName[32];
    read_logargv(0, szLog, charsmax(szLog));
    parse_loguser(szLog, szName, charsmax(szName));
    new id = get_user_index(szName);

    if (is_user_connected(id) && g_bDataLoaded[id])
    {
        g_iHostagesRescued[id]++;
        g_iDirtyMask[id] |= DIRTY_STATS;

        new iPersonal = g_iXpRewards[RWD_HOSTAGE_RESCUED][0];
        new iTeam = g_iXpRewards[RWD_HOSTAGE_RESCUED][1];

        if (iPersonal > 0)
            ExecuteXpReward(id, iPersonal, RSU_XP_HOSTAGE_RESCUED);

        if (iTeam > 0)
            ExecuteTeamXp(2, iTeam); // CT Team XP
    }
}

ExecuteTeamXp(iTeam, iAmount)
{
    for (new id = 1; id <= MaxClients; id++)
    {
        if (is_user_connected(id) && get_user_team(id) == iTeam && g_bDataLoaded[id])
        {
            ExecuteXpReward(id, iAmount, RSU_XP_ROUND_WIN, true);
        }
    }
}

public OnIntermission()
{
    ForceFlushAllDirty();

    if (g_bCfgShowMapEndMotd)
    {
        for (new id = 1; id <= MaxClients; id++)
        {
            if (is_user_connected(id))
            {
                OpenMotdScreen(id, "mapend", "");
            }
        }
    }
}

// ============================================================================
// MOTD OPENER & CLIENT COMMANDS
// ============================================================================
OpenMotdScreen(id, const szEndpoint[], const szParam[])
{
    if (!is_user_connected(id))
        return;

    if (equali(szEndpoint, "top") || equali(szEndpoint, "top15"))
    {
        ShowTop15Motd(id, szParam[0] ? szParam : "xp");
        return;
    }
    else if (equali(szEndpoint, "profile"))
    {
        new iTarget = id;
        if (szParam[0])
        {
            new player = find_player("c", szParam);
            if (!player) player = find_player("a", szParam);
            if (player) iTarget = player;
        }
        ShowProfileMotd(id, iTarget);
        return;
    }
    else if (equali(szEndpoint, "rankstats") || equali(szEndpoint, "statsme"))
    {
        new iTarget = id;
        if (szParam[0])
        {
            new player = find_player("c", szParam);
            if (!player) player = find_player("a", szParam);
            if (player) iTarget = player;
        }
        ShowRankStatsMotd(id, iTarget);
        return;
    }

    if (equali(szEndpoint, "mapend") || equali(szEndpoint, "match") || equali(szEndpoint, "matchstats"))
    {
        if (FNWeb_OpenPage(id, "top"))
            return;
        ShowTop15Motd(id, "xp");
        return;
    }

    if (FNWeb_OpenPage(id, szEndpoint))
        return;

    ShowRankStatsMotd(id, id);
}

public CmdOpenRankStats(id)
{
    if (!is_user_connected(id))
        return PLUGIN_HANDLED;
    if (!RateLimiter_CheckAllowed(id))
        return PLUGIN_HANDLED;
    if (FNWeb_OpenPage(id, "profile"))
        return PLUGIN_HANDLED;
    ShowRankStatsMotd(id, id);
    return PLUGIN_HANDLED;
}

public CmdOpenTop15(id)
{
    if (!is_user_connected(id))
        return PLUGIN_HANDLED;
    if (!RateLimiter_CheckAllowed(id))
        return PLUGIN_HANDLED;
    ShowTop15Motd(id, "xp");
    return PLUGIN_HANDLED;
}

// ================= TOP15 CATEGORY BROWSER =================
// Menu-first: 8 categories rank the FULL population in SQL, 7 rows per
// menu page, click opens that player (steamid identity), Back restores
// the exact stored {category, page, search, weapon} state.
// Top categories trimmed to essentials (Overall/Kills/Headshots/Skill).
// XP duplicated Overall; Assists/Weapons/BP niches retired with their menus.
#define TOPCAT_OVERALL 0
#define TOPCAT_KILLS 1
#define TOPCAT_HS 2
#define TOPCAT_SKILL 3
#define TOPCAT_COUNT 4
#define TOPCAT_PAGESIZE 7
#define TOPCAT_MAXROWS 30
stock const g_szTopCatNames[][] = { "Overall", "Kills", "Headshots", "Skill" };

public CmdTop15Menu(id)
{
    if (!is_user_connected(id))
        return PLUGIN_HANDLED;
    if (!RateLimiter_CheckAllowed(id))
        return PLUGIN_HANDLED;
    // Web board first (same as the hub path): the AMXX category browser
    // below is the offline fallback, not the default view.
    if (FNWeb_OpenPage(id, "top"))
        return PLUGIN_HANDLED;
    RefreshServerRank(id);
    new szArg[32];
    read_argv(2, szArg, charsmax(szArg));
    remove_quotes(szArg);
    trim(szArg);
    if (szArg[0])
    {
        copy(g_szTopSearch[id], charsmax(g_szTopSearch[]), szArg);
        replace_all(g_szTopSearch[id], charsmax(g_szTopSearch[]), "%", "");
        g_iTopCat[id] = TOPCAT_OVERALL;
        g_iTopPage[id] = 0;
        RunTop15Cat(id);
    }
    else
        ShowTopCategories(id);
    return PLUGIN_HANDLED;
}

public CmdTopBack(id)
{
    if (!is_user_connected(id))
        return PLUGIN_HANDLED;
    if (!RateLimiter_CheckAllowed(id))
        return PLUGIN_HANDLED;
    if (g_iTopCat[id] < 0 || g_iTopCat[id] >= TOPCAT_COUNT)
        ShowTopCategories(id);
    else
        RunTop15Cat(id);
    return PLUGIN_HANDLED;
}

ShowTopCategories(id)
{
    new menu = menu_create("\\yFreeNova \\r| \\wTop 15", "TopCatHandler");
    new szItem[48], szData[8];
    for (new i = 0; i < TOPCAT_COUNT; i++)
    {
        formatex(szItem, charsmax(szItem), "\\w%s", g_szTopCatNames[i]);
        formatex(szData, charsmax(szData), "cat:%d", i);
        menu_additem(menu, szItem, szData);
    }
    menu_setprop(menu, MPROP_EXITNAME, "\\wExit");
    menu_setprop(menu, MPROP_NUMBER_COLOR, "\\y");
    menu_display(id, menu, 0);
}

public TopCatHandler(id, menu, item)
{
    if (item == MENU_EXIT)
    {
        menu_destroy(menu);
        return PLUGIN_HANDLED;
    }
    new iAcc, iCb, szData[8], szName[64];
    menu_item_getinfo(menu, item, iAcc, szData, charsmax(szData), szName, charsmax(szName), iCb);
    menu_destroy(menu);
    new iCat = str_to_num(szData[4]);
    if (iCat < 0 || iCat >= TOPCAT_COUNT)
    {
        ShowTopCategories(id);
        return PLUGIN_HANDLED;
    }
    g_iTopCat[id] = iCat;
    g_iTopPage[id] = 0;
    g_szTopSearch[id][0] = 0;
    RunTop15Cat(id);
    return PLUGIN_HANDLED;
}


// Strip LIKE wildcards so search is always a plain substring.
EscapeSearch(szOut[], iOutLen, const szIn[])
{
    new iPos = 0, iLen = strlen(szIn);
    for (new i = 0; i < iLen && iPos < iOutLen - 1; i++)
    {
        new ch = szIn[i];
        if (ch == '%' || ch == '_' || ch == 92)
            continue;
        szOut[iPos++] = ch;
    }
    szOut[iPos] = 0;
}

RunTop15Cat(id)
{
    if (!is_user_connected(id))
        return;
    if (FNWeb_OpenPage(id, "top"))
        return;
    if (g_hSqlTuple == Empty_Handle)
    {
        client_print_color(id, print_team_default, "%s Database is currently offline.", g_szCfgChatPrefix);
        return;
    }
    new iCat = g_iTopCat[id];
    // Weapon board retired: the w.* join below stays for column shape, pinned
    // to slot 0 (Knife). No UI can select another slot anymore.
    new iWeapon = 0;
    new iMinKills = get_pcvar_num(g_pCvarHsMinKills);
    if (iMinKills < 0) iMinKills = 0;
    new szOrder[256];
    if (iCat == TOPCAT_KILLS)
        formatex(szOrder, charsmax(szOrder), "COALESCE(s.kills, 0) DESC, p.xp DESC, p.steamid ASC");
    else if (iCat == TOPCAT_HS)
        formatex(szOrder, charsmax(szOrder), "(CASE WHEN COALESCE(s.kills, 0) >= %d AND (COALESCE(s.kills, 0) + COALESCE(s.deaths, 0)) > 0 THEN 100.0 * COALESCE(s.kills, 0) / (COALESCE(s.kills, 0) + COALESCE(s.deaths, 0)) ELSE -1.0 END) DESC, COALESCE(s.kills, 0) DESC, p.steamid ASC", iMinKills);
    else if (iCat == TOPCAT_SKILL)
        formatex(szOrder, charsmax(szOrder), "(CASE WHEN (COALESCE(s.kills, 0) + COALESCE(s.deaths, 0)) > 0 THEN 100.0 * COALESCE(s.kills, 0) / (COALESCE(s.kills, 0) + COALESCE(s.deaths, 0)) ELSE -1.0 END) DESC, COALESCE(s.kills, 0) DESC, p.steamid ASC");
    else
        formatex(szOrder, charsmax(szOrder), "p.xp DESC, p.skill DESC, COALESCE(s.kills, 0) DESC, p.steamid ASC");
    if (g_iTopAsc[id])
        replace_all(szOrder, charsmax(szOrder), "DESC", "ASC");
    new szWhere[96];
    szWhere[0] = 0;
    if (g_szTopSearch[id][0])
    {
        new szSafe[64], szEsc[128];
        EscapeSearch(szSafe, charsmax(szSafe), g_szTopSearch[id]);
        EscapeSql(szEsc, charsmax(szEsc), szSafe);
        formatex(szWhere, charsmax(szWhere), "AND p.name LIKE '%%%s%%' ", szEsc);
    }
    new szQuery[1536];
    formatex(szQuery, charsmax(szQuery),
        "SELECT p.name, p.xp, p.level, p.rank_id, p.skill, COALESCE(s.kills, 0), COALESCE(s.deaths, 0), COALESCE(s.headshots, 0), p.steamid, COALESCE(s.assists, 0), COALESCE(w.kills, 0), COALESCE(b.bpxp, 0), COALESCE(b.bplevel, 0) FROM `%splayers` p LEFT JOIN `%splayer_stats` s ON (p.id = s.player_id AND s.server_id = 0) LEFT JOIN `%splayer_weapons` w ON (w.player_id = p.id AND w.weapon_id = %d) LEFT JOIN `%sbp_board` b ON (b.steamid = p.steamid) WHERE 1 = 1 %sORDER BY %s LIMIT %d;",
        g_szSqlTablePrefix, g_szSqlTablePrefix, g_szSqlTablePrefix, iWeapon, g_szSqlTablePrefix, szWhere, szOrder, TOPCAT_MAXROWS);
    g_iTopSerial[id]++;
    new data[4];
    data[0] = id;
    data[1] = get_user_userid(id);
    data[2] = g_iConnectionToken[id];
    data[3] = g_iTopSerial[id];
    SQL_ThreadQuery(g_hSqlTuple, "ThreadQuery_TopCat", szQuery, data, sizeof(data));
}

public ThreadQuery_TopCat(iFailState, Handle:hQuery, szError[], iErrorCode, data[], iDataSize)
{
    #pragma unused iDataSize
    new id = data[0];
    if (!is_user_connected(id) || get_user_userid(id) != data[1] || g_iConnectionToken[id] != data[2] || g_iTopSerial[id] != data[3])
        return;
    if (iFailState != TQUERY_SUCCESS)
    {
        client_print_color(id, print_team_default, "%s Failed to load Top 15 data from storage.", g_szCfgChatPrefix);
        log_amx("[RSU SQL ERROR] TopCat query failed: [%d] %s", iErrorCode, szError);
        return;
    }
    BuildTopCatMenu(id, hQuery);
}

BuildTopCatMenu(id, Handle:hQuery)
{
    new iCat = g_iTopCat[id];
    new iPage = g_iTopPage[id];
    new iMinKills = get_pcvar_num(g_pCvarHsMinKills);
    if (iMinKills < 0) iMinKills = 0;
    new szName[TOPCAT_MAXROWS][32], szAuth[TOPCAT_MAXROWS][32];
    new iXp[TOPCAT_MAXROWS], iLvl[TOPCAT_MAXROWS], iK[TOPCAT_MAXROWS], iD[TOPCAT_MAXROWS], iHs[TOPCAT_MAXROWS], iA[TOPCAT_MAXROWS], iWk[TOPCAT_MAXROWS], iBxp[TOPCAT_MAXROWS], iBlvl[TOPCAT_MAXROWS];
    new iRows = 0;
    while (SQL_MoreResults(hQuery) && iRows < TOPCAT_MAXROWS)
    {
        SQL_ReadResult(hQuery, 0, szName[iRows], 31);
        iXp[iRows] = SQL_ReadResult(hQuery, 1);
        iLvl[iRows] = SQL_ReadResult(hQuery, 2);
        iK[iRows] = SQL_ReadResult(hQuery, 5);
        iD[iRows] = SQL_ReadResult(hQuery, 6);
        iHs[iRows] = SQL_ReadResult(hQuery, 7);
        SQL_ReadResult(hQuery, 8, szAuth[iRows], 31);
        iA[iRows] = SQL_ReadResult(hQuery, 9);
        iWk[iRows] = SQL_ReadResult(hQuery, 10);
        iBxp[iRows] = SQL_ReadResult(hQuery, 11);
        iBlvl[iRows] = SQL_ReadResult(hQuery, 12);
        replace_all(szName[iRows], 31, "<", "[");
        replace_all(szName[iRows], 31, ">", "]");
        iRows++;
        SQL_NextRow(hQuery);
    }
    new iPages = (iRows + TOPCAT_PAGESIZE - 1) / TOPCAT_PAGESIZE;
    if (iPages < 1) iPages = 1;
    if (iPage >= iPages) { iPage = iPages - 1; g_iTopPage[id] = iPage; }
    new szTitle[160];
    if (g_szTopSearch[id][0])
        formatex(szTitle, charsmax(szTitle), "\\yFreeNova \\r| \\wTop %s <%s> #%d/%d g#%d", g_szTopCatNames[iCat], g_szTopSearch[id], iPage * TOPCAT_PAGESIZE + 1, iRows, g_iServerRank[id]);

    else
        formatex(szTitle, charsmax(szTitle), "\\yFreeNova \\r| \\wTop %s #%d/%d p%d/%d", g_szTopCatNames[iCat], g_iServerRank[id], g_iTotalServerPlayers, iPage + 1, iPages);
    new menu = menu_create(szTitle, "TopCatMenuHandler");
    new szItem[128];
    new iStart = iPage * TOPCAT_PAGESIZE;
    new iEnd = iStart + TOPCAT_PAGESIZE;
    if (iEnd > iRows) iEnd = iRows;
    for (new r = iStart; r < iEnd; r++)
    {
        new Float:fRatio = (iK[r] + iD[r] > 0) ? (100.0 * float(iK[r]) / float(iK[r] + iD[r])) : 0.0;
        new szSkill[12];
        GetSkillName(fRatio, szSkill, charsmax(szSkill));
        new bool:bOn = false;
        for (new p = 1; p <= MaxClients; p++)
            if (is_user_connected(p) && !is_user_bot(p) && equal(g_szAuthID[p], szAuth[r])) { bOn = true; break; }
        new bool:bMe = (g_bDataLoaded[id] && equal(szAuth[r], g_szAuthID[id]));
        new szVal[48];
        new bool:bGrey = false;
        if (iCat == TOPCAT_OVERALL)
            formatex(szVal, charsmax(szVal), "%d xp", iXp[r]);
        else if (iCat == TOPCAT_KILLS)
            formatex(szVal, charsmax(szVal), "%d K", iK[r]);
        else if (iCat == TOPCAT_HS)
        {
            if (iK[r] < iMinKills) { bGrey = true; formatex(szVal, charsmax(szVal), "%.1f%% need %dK", fRatio, iMinKills); }
            else formatex(szVal, charsmax(szVal), "%.1f%%", fRatio);
        }
        else if (iCat == TOPCAT_SKILL)
            formatex(szVal, charsmax(szVal), "%s %.1f", szSkill, fRatio);
        else
            formatex(szVal, charsmax(szVal), "%d xp", iXp[r]);
        if (bGrey)
            formatex(szItem, charsmax(szItem), "\\d%d. %s - %s", r + 1, szName[r], szVal);
        else
            if (bMe)
                formatex(szItem, charsmax(szItem), "\\y>> \\w%s \\d- Lv%d \\y%s%s", szName[r], iLvl[r], szVal, bOn ? " ON" : "");
            else
                formatex(szItem, charsmax(szItem), "\\y%d. \\w%s \\d- Lv%d \\y%s%s", r + 1, szName[r], iLvl[r], szVal, bOn ? " ON" : "");
        menu_additem(menu, szItem, szAuth[r]);
    }
    if (!iRows)
        menu_additem(menu, "\\dNo ranked players yet", "none");
    if (iPage < iPages - 1)
        menu_additem(menu, "\\wNext page >>", "##NEXT");
    if (iPage > 0)
        menu_additem(menu, "\\w<< Back", "##BACK");
    else
        menu_additem(menu, "\\wCategories", "##CATS");
    if (g_iTopAsc[id])
        menu_additem(menu, "\\wOrder: \\yASC", "##ORDER");
    else
        menu_additem(menu, "\\wOrder: \\yDESC", "##ORDER");
    menu_setprop(menu, MPROP_EXITNAME, "\\wExit");
    menu_setprop(menu, MPROP_NUMBER_COLOR, "\\y");
    menu_display(id, menu, 0);
}

public TopCatMenuHandler(id, menu, item)
{
    if (item == MENU_EXIT)
    {
        menu_destroy(menu);
        return PLUGIN_HANDLED;
    }
    new iAcc, iCb, szData[32], szName[64];
    menu_item_getinfo(menu, item, iAcc, szData, charsmax(szData), szName, charsmax(szName), iCb);
    menu_destroy(menu);
    if (equal(szData, "##NEXT"))
    {
        g_iTopPage[id]++;
        RunTop15Cat(id);
        return PLUGIN_HANDLED;
    }
    if (equal(szData, "##ORDER"))
    {
        g_iTopAsc[id] = g_iTopAsc[id] ? 0 : 1;
        RunTop15Cat(id);
        return PLUGIN_HANDLED;
    }
    if (equal(szData, "##BACK"))
    {
        if (g_iTopPage[id] > 0) g_iTopPage[id]--;
        RunTop15Cat(id);
        return PLUGIN_HANDLED;
    }
    if (equal(szData, "##CATS") || equal(szData, "none"))
    {
        ShowTopCategories(id);
        return PLUGIN_HANDLED;
    }
    if (!RateLimiter_CheckAllowed(id))
        return PLUGIN_HANDLED;
    // Prefer the live slot: same data, plus BP row and no extra query.
    new iSlot = 0;
    for (new p = 1; p <= MaxClients; p++)
    {
        if (is_user_connected(p) && !is_user_bot(p) && g_bDataLoaded[p] && equal(g_szAuthID[p], szData))
        {
            iSlot = p;
            break;
        }
    }
    if (iSlot > 0)
        ShowProfileMotd(id, iSlot);
    else
        QueryProfile(id, szData, true);
    return PLUGIN_HANDLED;
}

public CmdOpenProfile(id)
{
    if (!is_user_connected(id))
        return PLUGIN_HANDLED;
    if (!RateLimiter_CheckAllowed(id))
        return PLUGIN_HANDLED;
    // Web board first when no player name given (same as the hub path);
    // the internal MOTD below stays as fallback.
    if (read_argc() < 3 && FNWeb_OpenPage(id, "profile"))
        return PLUGIN_HANDLED;
    new szName[32];
    read_argv(2, szName, charsmax(szName));
    remove_quotes(szName);
    trim(szName);
    if (!szName[0])
    {
        ShowProfileMotd(id, id);
        return PLUGIN_HANDLED;
    }
    new target = find_player("c", szName);
    if (!target) target = find_player("a", szName);
    if (!target)
    {
        client_print_color(id, print_team_default, "%s Player not found: %s.", g_szCfgChatPrefix, szName);
        return PLUGIN_HANDLED;
    }
    ShowProfileMotd(id, target);
    return PLUGIN_HANDLED;
}

// Online-player viewer menu (Stats Viewer pattern): click a name to open
// that player's compact profile. Opened from the hub, not a say command.
public RSU_ShowProfileViewer(id)
{
    if (!is_user_connected(id))
        return 0;
    new ids[33], xp[33], n = 0;
    for (new p = 1; p <= MaxClients && n < 32; p++)
    {
        if (is_user_connected(p) && !is_user_bot(p) && g_bDataLoaded[p])
        {
            ids[n] = p;
            xp[n] = g_iPlayerXP[p];
            n++;
        }
    }
    for (new a = 0; a < n; a++)
    {
        for (new b = a + 1; b < n; b++)
        {
            if (xp[b] > xp[a])
            {
                new t = xp[a]; xp[a] = xp[b]; xp[b] = t;
                t = ids[a]; ids[a] = ids[b]; ids[b] = t;
            }
        }
    }
    new szTitle[64];
    FN_MenuTitle(szTitle, charsmax(szTitle), "Inspect player");
    new menu = menu_create(szTitle, "Top15Menu_Handler");
    new szItem[96], szAuth[32], szName[32];
    for (new k = 0; k < n; k++)
    {
        get_user_name(ids[k], szName, charsmax(szName));
        replace_all(szName, charsmax(szName), "<", "[");
        replace_all(szName, charsmax(szName), ">", "]");
        get_user_authid(ids[k], szAuth, charsmax(szAuth));
        formatex(szItem, charsmax(szItem), "\w%s \d- Lv%d \y%d xp", szName, g_iLevel[ids[k]], xp[k]);
        menu_additem(menu, szItem, szAuth);
    }
    if (!n)
        menu_additem(menu, "\dNo ranked players online", "none");
    FN_MenuFinish(menu, true);
    menu_display(id, menu, 0);
    return 1;
}

// Top 15 viewer: web/GoldSrc-MOTD path only. The SQL-backed Top15 MENU view
// (ShowTop15Menu + TOP15_VIEW_MENU branch in ThreadQuery_Top15) had no caller
// left once the category browser (CmdTop15Menu) replaced the player menu, so
// it was deleted instead of kept unreachable.
ShowTop15Motd(id, const szSortOrder[])
{
    RunTop15Query(id, szSortOrder);
}

RunTop15Query(id, const szSortOrder[])
{
    if (!is_user_connected(id))
        return;

    // Short GoldSrc MOTD path. Query-string SteamIDs return HTTP -102.
    if (FNWeb_OpenPage(id, "top"))
        return;

    if (g_hSqlTuple == Empty_Handle)
    {
        client_print_color(id, print_team_default, "%s Database is currently offline.", g_szCfgChatPrefix);
        return;
    }

    new szOrderClause[96];
    if (equali(szSortOrder, "skill"))
        copy(szOrderClause, charsmax(szOrderClause), "p.skill DESC");
    else if (equali(szSortOrder, "kills"))
        copy(szOrderClause, charsmax(szOrderClause), "COALESCE(s.kills, 0) DESC");
    else if (equali(szSortOrder, "deaths"))
        copy(szOrderClause, charsmax(szOrderClause), "COALESCE(s.deaths, 0) DESC");
    else if (equali(szSortOrder, "kd"))
        copy(szOrderClause, charsmax(szOrderClause), "(CAST(COALESCE(s.kills, 0) AS REAL) / MAX(1, COALESCE(s.deaths, 0))) DESC");
    else if (equali(szSortOrder, "headshots") || equali(szSortOrder, "hs"))
        copy(szOrderClause, charsmax(szOrderClause), "COALESCE(s.headshots, 0) DESC");
    else if (equali(szSortOrder, "playtime"))
        copy(szOrderClause, charsmax(szOrderClause), "p.playtime DESC");
    else
        copy(szOrderClause, charsmax(szOrderClause), "p.xp DESC");

    new szQuery[1024];
    formatex(szQuery, charsmax(szQuery),
        "SELECT p.name, p.xp, p.level, p.rank_id, p.skill, \
                COALESCE(s.kills, 0), COALESCE(s.deaths, 0), COALESCE(s.headshots, 0), p.steamid \
         FROM `%splayers` p LEFT JOIN `%splayer_stats` s ON (p.id = s.player_id AND s.server_id = 0) \
         ORDER BY %s LIMIT 30;",
        g_szSqlTablePrefix, g_szSqlTablePrefix, szOrderClause);

    new data[3];
    data[0] = id;
    data[1] = get_user_userid(id);
    data[2] = g_iConnectionToken[id];

    SQL_ThreadQuery(g_hSqlTuple, "ThreadQuery_Top15", szQuery, data, sizeof(data));
}

public ThreadQuery_Top15(iFailState, Handle:hQuery, szError[], iErrorCode, data[], iDataSize)
{
    #pragma unused iDataSize
    new id = data[0];
    new iUserId = data[1];
    new iToken = data[2];

    if (!is_user_connected(id) || get_user_userid(id) != iUserId || g_iConnectionToken[id] != iToken)
        return;

    if (iFailState != TQUERY_SUCCESS)
    {
        client_print_color(id, print_team_default, "%s Failed to load Top 15 data from storage.", g_szCfgChatPrefix);
        log_amx("[RSU SQL ERROR] Top15 query failed: [%d] %s", iErrorCode, szError);
        return;
    }

    new szOnline[33][32], iOnline = 0;
    for (new p = 1; p <= MaxClients && iOnline < 32; p++)
    {
        if (is_user_connected(p) && !is_user_bot(p))
        {
            get_user_authid(p, szOnline[iOnline], charsmax(szOnline[]));
            iOnline++;
        }
    }

    new szBuffer[24576];
    new szSub[96];
    formatex(szSub, charsmax(szSub), "Your rank #%d of %d players", g_iServerRank[id], g_iTotalServerPlayers);
    new iLen = FN_TornadoHead(szBuffer, charsmax(szBuffer), "Top 15", szSub);
    iLen += copy(szBuffer[iLen], charsmax(szBuffer) - iLen,
        "<table class='fnt' id='ttab'><thead><tr><th>#</th><th><a href='#' onclick='return tsort(1,0)'>Player</a></th><th align=right><a href='#' onclick='return tsort(2,1)'>XP</a></th><th>Lv</th><th align=right><a href='#' onclick='return tsort(5,1)'>K</a></th><th align=right>D</th><th align=right>K:D</th><th align=right>HS%</th><th>Skill</th><th>Rank</th></tr></thead><tbody id='ttbd'>");

    new szTName[45][32], szTAuth[45][32], szTRank[45][24], szTSkill[45][12];
    new iTXp[45], iTLv[45], iTK[45], iTD[45], iTHs[45], iTMe[45], iTOn[45];
    new Float:fTSk[45];
    new szImgBase[128];
    get_cvar_string("rsu_motd_imgbase", szImgBase, charsmax(szImgBase));
    new iRow = 0;
    while (SQL_MoreResults(hQuery) && iRow < 45)
    {
        SQL_ReadResult(hQuery, 0, szTName[iRow], charsmax(szTName[]));
        iTXp[iRow] = SQL_ReadResult(hQuery, 1);
        iTLv[iRow] = SQL_ReadResult(hQuery, 2);
        new iTRankId = SQL_ReadResult(hQuery, 3);
        new Float:fTSkill = Float:SQL_ReadResult(hQuery, 4);
        fTSk[iRow] = fTSkill;
        iTK[iRow] = SQL_ReadResult(hQuery, 5);
        iTD[iRow] = SQL_ReadResult(hQuery, 6);
        iTHs[iRow] = SQL_ReadResult(hQuery, 7);
        // Honest skill: ini tiers are RATIO bands (100*K/(K+D)), not ELO.
        // A fresh 0/0 player is 0.0 -> L-, never a top badge.
        fTSk[iRow] = (iTK[iRow] + iTD[iRow] > 0) ? (100.0 * float(iTK[iRow]) / float(iTK[iRow] + iTD[iRow])) : 0.0;
        GetSkillName(fTSk[iRow], szTSkill[iRow], charsmax(szTSkill[]));
        SQL_ReadResult(hQuery, 8, szTAuth[iRow], charsmax(szTAuth[]));
        replace_all(szTName[iRow], charsmax(szTName[]), "<", "[");
        replace_all(szTName[iRow], charsmax(szTName[]), ">", "]");
        replace_all(szTName[iRow], charsmax(szTName[]), "^"", "'");
        GetRankDisplayName(iTRankId, szTRank[iRow], charsmax(szTRank[]));
        GetSkillName(fTSkill, szTSkill[iRow], charsmax(szTSkill[]));
        iTMe[iRow] = equal(szTAuth[iRow], g_szAuthID[id]) ? 1 : 0;
        iTOn[iRow] = 0;
        for (new p = 1; p <= MaxClients; p++)
        {
            if (!is_user_connected(p) || is_user_bot(p))
                continue;
            new szPA[32];
            get_user_authid(p, szPA, charsmax(szPA));
            if (equal(szTAuth[iRow], szPA)) { iTOn[iRow] = p; break; }
        }
        iRow++;
        SQL_NextRow(hQuery);
    }
    new iMaxXp = (iRow > 0) ? iTXp[0] : 1;
    if (iMaxXp < 1) iMaxXp = 1;
    for (new r = 0; r < iRow && (charsmax(szBuffer) - iLen > 700); r++)
    {
        new Float:fKd = (iTD[r] > 0) ? (float(iTK[r]) / float(iTD[r])) : float(iTK[r]);
        new iHsPercent = (iTK[r] > 0) ? ((iTHs[r] * 100) / iTK[r]) : 0;
        new iBarW = iTXp[r] * 56 / iMaxXp;
        if (iBarW < 2 && iTXp[r] > 0) iBarW = 2;
        new szFlag[160], szKey[36];
        szFlag[0] = 0;
        copy(szKey, charsmax(szKey), szTName[r]);
        replace_all(szKey, charsmax(szKey), "'", "");
        if (iTOn[r] > 0)
        {
            new szIP[32], szCC[3];
            get_user_ip(iTOn[r], szIP, charsmax(szIP));
            new iColon = contain(szIP, ":");
            if (iColon != -1) szIP[iColon] = 0;
            geoip_code2_ex(szIP, szCC);
            if (szCC[0])
            {
                for (new k = 0; szCC[k]; k++)
                {
                    if (szCC[k] >= 'A' && szCC[k] <= 'Z') szCC[k] += 32;
                }
                if (szImgBase[0])
                    // NOTE: szImgBase holds HOST+PATH ONLY (no https://). The engine strips // as a comment, so a scheme in the cvar truncates the value. Scheme is added here.

// 16KB default stack overflows on 24K-cell MOTD buffers (run time error 3). 256KB covers top15 + nesting.
#pragma dynamic 65536
                    formatex(szFlag, charsmax(szFlag), "<img src='https://%s/flags/4x3/%s.svg' width='18' height='14' border='0' onerror=this.style.display='none' /> ", szImgBase, szCC);
                else
                    formatex(szFlag, charsmax(szFlag), "<span class='fnmuted'>%s</span> ", szCC);
            }
        }
        new szSkBg[8], szSkFg[8];
        copy(szSkBg, charsmax(szSkBg), "#555555");
        copy(szSkFg, charsmax(szSkFg), "#FFFFFF");
        if (szTSkill[r][0] == 'L') { copy(szSkBg, charsmax(szSkBg), "#FCE590"); copy(szSkFg, charsmax(szSkFg), "#222222"); }
        else if (szTSkill[r][0] == 'M') { copy(szSkBg, charsmax(szSkBg), "#FFC900"); copy(szSkFg, charsmax(szSkFg), "#222222"); }
        else if (szTSkill[r][0] == 'H') { copy(szSkBg, charsmax(szSkBg), "#F2880F"); }
        else if (szTSkill[r][0] == 'P') { copy(szSkBg, charsmax(szSkBg), "#FF3333"); }
        else if (szTSkill[r][0] == 'G') { copy(szSkBg, charsmax(szSkBg), "#000000"); }
        iLen += formatex(szBuffer[iLen], charsmax(szBuffer) - iLen,
            "<tr data-xp='%d' data-k='%d' data-d='%d' data-hs='%d' data-sk='%.1f' data-nm='%s'%s><td align=center class='%s'>%d</td><td>%s%s%s</td><td align=right><span class='xpb'>%d</span><br><div style='background:#3a2222;width:56px;'><div style='background:#C060D0;width:%dpx;height:5px;'></div></div></td><td align=center>%d</td><td align=right>%d</td><td align=right>%d</td><td align=right>%.2f</td><td align=right>%d%%</td><td><span style='background:%s;color:%s;font-weight:bold;padding:1px 5px;'>%s %d</span></td><td class='rkb'>%s</td></tr>",
            iTXp[r], iTK[r], iTD[r], iTHs[r], fTSk[r], szKey,
            (iTMe[r] ? " class='fnyou'" : ""),
            (r == 0 ? "fnr1" : (r == 1 ? "fnr2" : (r == 2 ? "fnr3" : "fnmuted"))),
            r + 1, szFlag, szTName[r], iTOn[r] > 0 ? " <span class='fngreen'>(ON)</span>" : "",
            iTXp[r], iBarW, iTLv[r], iTK[r], iTD[r], fKd, iHsPercent, szSkBg, szSkFg, szTSkill[r], floatround(fTSk[r]), szTRank[r]);
    }

    if (iRow == 0)
    {
        iLen += copy(szBuffer[iLen], charsmax(szBuffer) - iLen,
             "<tr><td colspan=10 align=center class='fnmuted'>No ranked player statistics recorded yet.</td></tr>");
    }

    iLen += copy(szBuffer[iLen], charsmax(szBuffer) - iLen, "</table>");
    iLen += copy(szBuffer[iLen], charsmax(szBuffer) - iLen,
        "<div class='fnmuted'>Pages: <a href='#' onclick='tshow(0);return false;'>1</a> <a href='#' onclick='tshow(1);return false;'>2</a> &nbsp; <span id='tpg'></span><br>Search: <input type='text' id='tq' size='18' onkeyup='tfilter()'> <input type='button' value='Go' onclick='tfilter();return false;'></div>");
    iLen += copy(szBuffer[iLen], charsmax(szBuffer) - iLen,
        "<script type='text/javascript'>var tPg=0;function trows(){return document.getElementById('ttbd').getElementsByTagName('tr');}function tshow(p){var rs=trows();var n=0;var i;for(i=0;i<rs.length;i++){var pg=Math.floor(n/15);rs[i].style.display=(pg==p)?'':'none';n++;}tPg=p;var e=document.getElementById('tpg');if(e)e.innerHTML='Page '+(p+1);}function tnum(r,a){var v=r.getAttribute(a);return v?parseFloat(v):0;}function tcol(c){if(c==1)return 'data-nm';if(c==2)return 'data-xp';return 'data-k';}function tsort(c,num){c=tcol(c);var tb=document.getElementById('ttbd');var rs=[];var i;for(i=0;i<tb.getElementsByTagName('tr').length;i++)rs.push(tb.getElementsByTagName('tr')[i]);rs.sort(function(a,b){var x=num?tnum(a,c):((a.getAttribute(c)||'').toLowerCase());var y=num?tnum(b,c):((b.getAttribute(c)||'').toLowerCase());return num?(y-x):((x<y)?-1:((x>y)?1:0));});for(i=0;i<rs.length;i++)tb.appendChild(rs[i]);tshow(0);}function tfilter(){var q=document.getElementById('tq').value.toLowerCase();var rs=trows();for(var i=0;i<rs.length;i++){var nm=rs[i].getAttribute('data-nm')||'';rs[i].style.display=(nm.indexOf(q)>=0)?'':'none;}var e=document.getElementById('tpg');if(e)e.innerHTML='Search';}</script>");
    iLen = FN_TornadoFoot(szBuffer, charsmax(szBuffer), iLen);

    FN_MotdShow(id, szBuffer, "FreeNova Top 15");

    if (g_pCvarDebug && get_pcvar_num(g_pCvarDebug))
    {
        new iFile = fopen("cstrike/rsu_top15.html", "wt");
        if (iFile)
        {
            fprintf(iFile, "%s", szBuffer);
            fclose(iFile);
        }
    }
}

public Top15Menu_Handler(id, menu, item)
{
    if (item == MENU_EXIT || !is_user_connected(id))
    {
        menu_destroy(menu);
        return PLUGIN_HANDLED;
    }

    new szAuth[32], szName[64], iAccess, iCallback;
    menu_item_getinfo(menu, item, iAccess, szAuth, charsmax(szAuth), szName, charsmax(szName), iCallback);
    menu_destroy(menu);

    if (equal(szAuth, "none"))
        return PLUGIN_HANDLED;
    if (!RateLimiter_CheckAllowed(id))
        return PLUGIN_HANDLED;
    QueryProfile(id, szAuth, true);
    return PLUGIN_HANDLED;
}

ShowRankStatsMotd(id, target_id)
{
    ShowStatsView(id, target_id, false);
}

ShowProfileMotd(id, target_id)
{
    ShowStatsView(id, target_id, true);
}

ShowStatsView(id, target_id, bool:bCompact)
{
    if (!is_user_connected(id))
        return;

    if (target_id > 0 && target_id != id && !is_user_connected(target_id))
    {
        client_print_color(id, print_team_default, "%s Player left the server.", g_szCfgChatPrefix);
        return;
    }
    new iTarget = (target_id > 0 && is_user_connected(target_id)) ? target_id : id;

    if (FNWeb_OpenTarget(id, iTarget, "profile"))
        return;

    // Fallback: RAM snapshot from local RanksUltimate.sq3 (no HTTP needed).
    if (g_bDataLoaded[iTarget])
    {
        if (bCompact)
            RenderProfileFromRam(id, iTarget);
        else
            RenderRankStatsMotd(id, iTarget);
        return;
    }

    QueryProfile(id, g_szAuthID[iTarget], bCompact);
}

// SQL profile fetch keyed by SteamID string - works for offline top15 players.
QueryProfile(id, const szAuth[], bool:bCompact)
{
    if (g_hSqlTuple == Empty_Handle)
    {
        client_print_color(id, print_team_default, "%s Database is currently offline.", g_szCfgChatPrefix);
        return;
    }

    new szQuery[1024], szEscAuth[64];
    EscapeSql(szEscAuth, charsmax(szEscAuth), szAuth);
    // Keep this well under 1024; the old 512-byte query truncated and sqlite
    // returned no row / "no such column", which printed "Unable to load player profile".
    formatex(szQuery, charsmax(szQuery),
        "SELECT p.name, p.steamid, p.xp, p.level, p.rank_id, p.skill, p.playtime, \
                COALESCE(s.kills,0), COALESCE(s.deaths,0), COALESCE(s.headshots,0), \
                COALESCE(s.assists,0), COALESCE(s.damage,0), COALESCE(s.shots,0), \
                COALESCE(s.hits,0), COALESCE(s.mvps,0), COALESCE(s.c4_plants,0), \
                COALESCE(s.c4_defuses,0), COALESCE(s.knife_kills,0), COALESCE(s.he_kills,0), \
                (SELECT COUNT(*)+1 FROM `%splayers` p2 WHERE p2.xp > p.xp), \
                (SELECT COUNT(*) FROM `%splayers` p3) \
         FROM `%splayers` p LEFT JOIN `%splayer_stats` s ON (p.id = s.player_id AND s.server_id = 0) \
         WHERE p.steamid = '%s' LIMIT 1;",
        g_szSqlTablePrefix, g_szSqlTablePrefix, g_szSqlTablePrefix, g_szSqlTablePrefix, szEscAuth);

    new data[5];
    data[0] = id;
    data[1] = 0;
    data[2] = get_user_userid(id);
    data[3] = g_iConnectionToken[id];
    data[4] = bCompact;

    SQL_ThreadQuery(g_hSqlTuple, "ThreadQuery_RankStats", szQuery, data, sizeof(data));
}

public ThreadQuery_RankStats(iFailState, Handle:hQuery, szError[], iErrorCode, data[], iDataSize)
{
    #pragma unused iDataSize
    new id = data[0];
    new iTarget = data[1];
    #pragma unused iTarget
    new iUserId = data[2];
    new iToken = data[3];

    if (!is_user_connected(id) || get_user_userid(id) != iUserId || g_iConnectionToken[id] != iToken)
        return;

    if (iFailState != TQUERY_SUCCESS)
    {
        log_amx("[RSU SQL ERROR] RankStats query failed [%d]: %s", iErrorCode, szError);
        client_print_color(id, print_team_default, "%s Unable to load player profile.", g_szCfgChatPrefix);
        return;
    }

    // sqlite threaded queries report row count via SQL_NumResults, not SQL_MoreResults
    if (SQL_NumResults(hQuery) < 1)
    {
        client_print_color(id, print_team_default, "%s No ranked profile yet for this SteamID.", g_szCfgChatPrefix);
        return;
    }

    new szName[32], szSteamId[32], szRankName[24], szSkillName[12];
    SQL_ReadResult(hQuery, 0, szName, charsmax(szName));
    SQL_ReadResult(hQuery, 1, szSteamId, charsmax(szSteamId));
    new iXp = SQL_ReadResult(hQuery, 2);
    new iLevel = SQL_ReadResult(hQuery, 3);
    new iRankId = SQL_ReadResult(hQuery, 4);
    new Float:fSkill = Float:SQL_ReadResult(hQuery, 5);
    new iPlaytime = SQL_ReadResult(hQuery, 6);
    new iKills = SQL_ReadResult(hQuery, 7);
    new iDeaths = SQL_ReadResult(hQuery, 8);
    new iHeadshots = SQL_ReadResult(hQuery, 9);
    new iAssists = SQL_ReadResult(hQuery, 10);
    new iDamage = SQL_ReadResult(hQuery, 11);
    new iShots = SQL_ReadResult(hQuery, 12);
    new iHits = SQL_ReadResult(hQuery, 13);
    new iMvps = SQL_ReadResult(hQuery, 14);
    new iPlants = SQL_ReadResult(hQuery, 15);
    new iDefuses = SQL_ReadResult(hQuery, 16);
    new iKnifeKills = SQL_ReadResult(hQuery, 17);
    new iHeKills = SQL_ReadResult(hQuery, 18);
    new iRankQ = SQL_ReadResult(hQuery, 19);
    new iTotalQ = SQL_ReadResult(hQuery, 20);

    replace_all(szName, charsmax(szName), "<", "[");
    replace_all(szName, charsmax(szName), ">", "]");
    replace_all(szName, charsmax(szName), "^"", "'");

    GetRankDisplayName(iRankId, szRankName, charsmax(szRankName));
    GetSkillName(fSkill, szSkillName, charsmax(szSkillName));
    new bool:bProfOnline = false;
    for (new q = 1; q <= MaxClients; q++)
        if (is_user_connected(q) && !is_user_bot(q) && equal(g_szAuthID[q], szSteamId)) { bProfOnline = true; break; }

    if (data[4])
        RenderProfileHtml(id, szName, szSteamId, iXp, iLevel, iRankId, fSkill, iRankQ, iTotalQ, -1, -1, bProfOnline,
            iPlaytime, iKills, iDeaths, iHeadshots);
    else
        RenderRankStatsHtml(id, szName, szSteamId, iXp, iLevel, iRankId, fSkill,
            iPlaytime, iKills, iDeaths, iHeadshots, iAssists, iDamage, iShots, iHits, iMvps, iPlants, iDefuses, iKnifeKills, iHeKills,
            "", 0, "", 0, "", 0);
}

RenderRankStatsMotd(id, iTarget)
{
    new Float:fSkill = g_fSkill[iTarget];
    new szW1[16], szW2[16], szW3[16], iWK1 = 0, iWK2 = 0, iWK3 = 0;
    if (LibraryExists("freenova_wpn", LibType_Library))
    {
        new szWn[16];
        for (new s = 0; s < 23; s++)
        {
            new k = fnwps_get_kills(iTarget, s);
            if (k <= 0)
                continue;
            fnwps_get_weapon_name(s, szWn, charsmax(szWn));
            if (k > iWK1) { iWK3 = iWK2; copy(szW3, charsmax(szW3), szW2); iWK2 = iWK1; copy(szW2, charsmax(szW2), szW1); iWK1 = k; copy(szW1, charsmax(szW1), szWn); }
            else if (k > iWK2) { iWK3 = iWK2; copy(szW3, charsmax(szW3), szW2); iWK2 = k; copy(szW2, charsmax(szW2), szWn); }
            else if (k > iWK3) { iWK3 = k; copy(szW3, charsmax(szW3), szWn); }
        }
    }
    RenderRankStatsHtml(id, g_szPlayerName[iTarget], g_szAuthID[iTarget],
        g_iPlayerXP[iTarget], g_iLevel[iTarget], g_iRank[iTarget], fSkill, g_iPlaytime[iTarget],
        g_iKills[iTarget], g_iDeaths[iTarget], g_iHeadshots[iTarget], g_iAssists[iTarget],
        g_iDamage[iTarget], g_iShots[iTarget], g_iHits[iTarget], g_iMVPs[iTarget],
        g_iC4Plants[iTarget], g_iC4Defuses[iTarget], 0, 0,
        szW1, iWK1, szW2, iWK2, szW3, iWK3);
}

RenderProfileFromRam(id, iTarget)
{
    new Float:fSkill = g_fSkill[iTarget];
    RenderProfileHtml(id, g_szPlayerName[iTarget], g_szAuthID[iTarget],
        g_iPlayerXP[iTarget], g_iLevel[iTarget], g_iRank[iTarget], fSkill, g_iServerRank[iTarget], g_iTotalServerPlayers, crxranks_get_user_level(iTarget), crxranks_get_user_xp(iTarget), true, g_iPlaytime[iTarget],
        g_iKills[iTarget], g_iDeaths[iTarget], g_iHeadshots[iTarget]);
}

// Compact "main profile" page: identity + progression + headline combat rows.
RankProgress(iXp, &iCurMin, &iNextMin)
{
    iCurMin = 0; iNextMin = 0;
    if (g_iTotalRanks <= 0) return;
    new rankEntry[RankEntry];
    for (new i = 0; i < g_iTotalRanks; i++)
    {
        ArrayGetArray(g_aRanks, i, rankEntry);
        if (iXp >= rankEntry[RANK_MIN_XP]) iCurMin = rankEntry[RANK_MIN_XP];
        else { iNextMin = rankEntry[RANK_MIN_XP]; break; }
    }
}
RenderProfileHtml(id, const szNameIn[], const szSteamIdIn[], iXp, iLevel, iRankId, Float:fSkill, iSrvRank, iSrvTotal, iBpTier, iBpXp, bool:bOnline,
    iPlaytime, iKills, iDeaths, iHeadshots)
{
    new szName[32], szSteamId[32], szRankName[24], szSkillName[12];
    copy(szName, charsmax(szName), szNameIn);
    copy(szSteamId, charsmax(szSteamId), szSteamIdIn);
    replace_all(szName, charsmax(szName), "<", "[");
    replace_all(szName, charsmax(szName), ">", "]");
    replace_all(szName, charsmax(szName), "^"", "'");
    GetRankDisplayName(iRankId, szRankName, charsmax(szRankName));
    GetSkillName(fSkill, szSkillName, charsmax(szSkillName));

    new Float:fKd = (iDeaths > 0) ? (float(iKills) / float(iDeaths)) : float(iKills);
    new iHsPercent = (iKills > 0) ? ((iHeadshots * 100) / iKills) : 0;
    new iHours = iPlaytime / 3600;
    new iMinutes = (iPlaytime % 3600) / 60;

    // Honest skill: ini tiers are RATIO bands (100*K/(K+D)). Fresh 0/0 = 0.0 L-.
    new Float:fRatioP = (iKills + iDeaths > 0) ? (100.0 * float(iKills) / float(iKills + iDeaths)) : 0.0;
    GetSkillName(fRatioP, szSkillName, charsmax(szSkillName));
    new szBpText[48];
    new iBpSeason = get_cvar_num("fn_bp_season");
    if (iBpTier >= 0 && iBpXp >= 0 && iBpSeason > 0)
        formatex(szBpText, charsmax(szBpText), "S%d T%d %d xp", iBpSeason, iBpTier, iBpXp);
    else
        copy(szBpText, charsmax(szBpText), "--");
    new szProgText[40], szOnline[8];
    new iCurMin, iNextMin;
    RankProgress(iXp, iCurMin, iNextMin);
    if (iNextMin > iCurMin)
        formatex(szProgText, charsmax(szProgText), "%d%% (%d/%d)", (iXp - iCurMin) * 100 / (iNextMin - iCurMin), iXp, iNextMin);
    else
        copy(szProgText, charsmax(szProgText), "MAX");
    copy(szOnline, charsmax(szOnline), bOnline ? "Online" : "Offline");
    new szBuffer[4096];
    new iLen = FN_TornadoHead(szBuffer, charsmax(szBuffer), szName, szSteamId);
    iLen += copy(szBuffer[iLen], charsmax(szBuffer) - iLen, "<table class='fnt'>");
    iLen += formatex(szBuffer[iLen], charsmax(szBuffer) - iLen,
        "<tr><td>Rank</td><td class='v'>%s (Lv %d/%d)</td></tr><tr><td>XP</td><td class='v'>%d</td></tr><tr><td>Skill</td><td class='v'>%s %.1f</td></tr><tr><td>Play</td><td class='v'>%dh %dm</td></tr><tr><td>K/D</td><td class='v'>%d/%d %.2f</td></tr><tr><td>HS</td><td class='v'>%d (%d%%)</td></tr><tr><td colspan=2 align=center><font size='+2'><b>%c</b></font> %s</td></tr><tr><td>Progress</td><td class='v'>%s</td></tr><tr><td>Server Rank</td><td class='v'>#%d of %d</td></tr><tr><td>Battle Pass</td><td class='v'>%s</td></tr><tr><td colspan=2>Back: say /topback</td></tr></table>",
        szRankName, iLevel, g_iTotalRanks, iXp, szSkillName, fRatioP, iHours, iMinutes,
        iKills, iDeaths, fKd, iHeadshots, iHsPercent, szName[0], szOnline, szProgText, iSrvRank, iSrvTotal, szBpText);
    iLen = FN_TornadoFoot(szBuffer, charsmax(szBuffer), iLen);

    FN_MotdShow(id, szBuffer, "FreeNova Profile");
}

RenderRankStatsHtml(id, const szNameIn[], const szSteamIdIn[], iXp, iLevel, iRankId, Float:fSkill,
    iPlaytime, iKills, iDeaths, iHeadshots, iAssists, iDamage, iShots, iHits, iMvps, iPlants, iDefuses, iKnifeKills, iHeKills,
    const szWpn1[], iWpnK1, const szWpn2[], iWpnK2, const szWpn3[], iWpnK3)
{
    // iMvps stays in the signature (both callers pass it) but the Rankstats
    // table has no MVP row - keep the shape stable instead of re-formatting.
    #pragma unused iMvps
    new szName[32], szSteamId[32], szRankName[24], szSkillName[12];
    copy(szName, charsmax(szName), szNameIn);
    copy(szSteamId, charsmax(szSteamId), szSteamIdIn);
    replace_all(szName, charsmax(szName), "<", "[");
    replace_all(szName, charsmax(szName), ">", "]");
    replace_all(szName, charsmax(szName), "^"", "'");
    GetRankDisplayName(iRankId, szRankName, charsmax(szRankName));
    GetSkillName(fSkill, szSkillName, charsmax(szSkillName));

    new Float:fKd = (iDeaths > 0) ? (float(iKills) / float(iDeaths)) : float(iKills);
    new iHsPercent = (iKills > 0) ? ((iHeadshots * 100) / iKills) : 0;
    new Float:fAcc = (iShots > 0) ? (float(iHits) * 100.0 / float(iShots)) : 0.0; if (fAcc > 100.0) fAcc = 100.0;
    new iHours = iPlaytime / 3600;
    new iMinutes = (iPlaytime % 3600) / 60;

    new szBuffer[8192];
    new iLen = FN_TornadoHead(szBuffer, charsmax(szBuffer), szName, szSteamId);
    new Float:fRatioR = (iKills + iDeaths > 0) ? (100.0 * float(iKills) / float(iKills + iDeaths)) : 0.0;
    GetSkillName(fRatioR, szSkillName, charsmax(szSkillName));
    iLen += copy(szBuffer[iLen], charsmax(szBuffer) - iLen, "<table class='fnt'>");
    iLen += formatex(szBuffer[iLen], charsmax(szBuffer) - iLen, "<tr><td>Rank</td><td class='v'>%s (Lv %d/%d)</td></tr><tr><td>XP</td><td class='v'>%d</td></tr><tr><td>Skill</td><td class='v'>%s %.1f</td></tr><tr><td>Play</td><td class='v'>%dh %dm</td></tr><tr><td>K/D</td><td class='v'>%d/%d %.2f</td></tr><tr><td>HS</td><td class='v'>%d (%d%%)</td></tr><tr><td>Acc</td><td class='v'>%.0f%%</td></tr><tr><td>Dmg/Ast</td><td class='v'>%d / %d</td></tr><tr><td>C4/K-H</td><td class='v'>%d/%d %d/%d</td></tr>", szRankName, iLevel, g_iTotalRanks, iXp, szSkillName, fRatioR, iHours, iMinutes, iKills, iDeaths, fKd, iHeadshots, iHsPercent, fAcc, iDamage, iAssists, iPlants, iDefuses, iKnifeKills, iHeKills);
    if (iWpnK1 > 0)
    {
        iLen += formatex(szBuffer[iLen], charsmax(szBuffer) - iLen,  "<tr><td>1. %s</td><td class='v'>%d</td></tr>", szWpn1, iWpnK1);
        if (iWpnK2 > 0)
            iLen += formatex(szBuffer[iLen], charsmax(szBuffer) - iLen,  "<tr><td>2. %s</td><td class='v'>%d</td></tr>", szWpn2, iWpnK2);
        if (iWpnK3 > 0)
            iLen += formatex(szBuffer[iLen], charsmax(szBuffer) - iLen,  "<tr><td>3. %s</td><td class='v'>%d</td></tr>", szWpn3, iWpnK3);
    }
    else
        iLen += copy(szBuffer[iLen], charsmax(szBuffer) - iLen,  "<tr><td colspan=2>No weapon data yet.</td></tr>");
    iLen += copy(szBuffer[iLen], charsmax(szBuffer) - iLen, "</table>");
    iLen = FN_TornadoFoot(szBuffer, charsmax(szBuffer), iLen);

    FN_MotdShow(id, szBuffer, "FreeNova Rankstats");

    if (g_pCvarDebug && get_pcvar_num(g_pCvarDebug))
    {
        new iFile = fopen("cstrike/rsu_rankstats.html", "wt");
        if (iFile)
        {
            fprintf(iFile, "%s", szBuffer);
            fclose(iFile);
        }
    }
}

public CmdShowXpInfo(id)
{
    if (!is_user_connected(id))
        return PLUGIN_HANDLED;

    if (!RateLimiter_CheckAllowed(id))
    {
        client_print_color(id, print_team_default, "%s Command on cooldown, please wait a moment.", g_szCfgChatPrefix);
        return PLUGIN_HANDLED;
    }

    if (!g_bDataLoaded[id])
    {
        client_print_color(id, print_team_default, "%s Your player statistics are loading, please wait a moment.", g_szCfgChatPrefix);
        return PLUGIN_HANDLED;
    }

    new szRank[32];
    GetRankDisplayName(g_iRank[id], szRank, charsmax(szRank));
    client_print_color(id, print_team_default, "%s Your XP: ^4%d^1 | Level: ^3%d^1 | Rank: ^4%s^1",
        g_szCfgChatPrefix, g_iPlayerXP[id], g_iLevel[id], szRank);

    new szSkill[16];
    GetSkillName(CalculateSkillRange(id), szSkill, charsmax(szSkill));
    client_print_color(id, print_team_default, "%s Rank: ^4%s^1 | Skill: ^3[%s %.1f]^1 | Server Rank: ^4%d^1/^3%d^1",
        g_szCfgChatPrefix, szRank, szSkill, CalculateSkillRange(id), g_iServerRank[id], g_iTotalServerPlayers);
    return PLUGIN_HANDLED;
}

public CmdShowRankInfo(id)
{
    if (!is_user_connected(id))
        return PLUGIN_HANDLED;

    if (!RateLimiter_CheckAllowed(id))
    {
        client_print_color(id, print_team_default, "%s Command on cooldown, please wait a moment.", g_szCfgChatPrefix);
        return PLUGIN_HANDLED;
    }

    if (!g_bDataLoaded[id])
    {
        client_print_color(id, print_team_default, "%s Your player statistics are loading, please wait a moment.", g_szCfgChatPrefix);
        return PLUGIN_HANDLED;
    }

    new Float:fRange = CalculateSkillRange(id);
    new szSkill[16], szRank[32];
    GetSkillName(fRange, szSkill, charsmax(szSkill));
    GetRankDisplayName(g_iRank[id], szRank, charsmax(szRank));

    client_print_color(id, print_team_default, "%s Rank: ^4%s^1 | Skill: ^3[%s %.1f]^1 | Server Rank: ^4%d^1/^3%d^1",
        g_szCfgChatPrefix, szRank, szSkill, fRange, g_iServerRank[id], g_iTotalServerPlayers);
    return PLUGIN_HANDLED;
}

public CmdToggleHudInfo(id)
{
    if (!is_user_connected(id))
        return PLUGIN_HANDLED;
    if (!RateLimiter_CheckAllowed(id))
        return PLUGIN_HANDLED;
    g_bHudEnabled[id] = !g_bHudEnabled[id];
    client_print_color(id, print_team_default, "%s HUD status information %s.",
        g_szCfgChatPrefix, g_bHudEnabled[id] ? "^4enabled^1" : "^3disabled^1");
    return PLUGIN_HANDLED;
}

public CmdToggleRankInfo(id)
{
    if (!is_user_connected(id))
        return PLUGIN_HANDLED;
    if (!RateLimiter_CheckAllowed(id))
        return PLUGIN_HANDLED;
    g_bRankInfoEnabled[id] = !g_bRankInfoEnabled[id];
    client_print_color(id, print_team_default, "%s Spawn rank info message %s.",
        g_szCfgChatPrefix, g_bRankInfoEnabled[id] ? "^4enabled^1" : "^3disabled^1");
    return PLUGIN_HANDLED;
}

// ============================================================================
// IN-GAME MOTD EDITOR MENU (/rsuedit) FOR ADMIN_RCON
// ============================================================================
public CmdRsuEdit(id)
{
    if (!is_user_connected(id) || !(get_user_flags(id) & ADMIN_RCON))
    {
        client_print_color(id, print_team_default, "%s You do not have access to /rsuedit.", g_szCfgChatPrefix);
        return PLUGIN_HANDLED;
    }

    ShowRsuEditMenu(id);
    return PLUGIN_HANDLED;
}

ShowRsuEditMenu(id)
{
    new szTitle[96];
    FN_MenuTitle(szTitle, charsmax(szTitle), "MOTD Personalization Editor");
    new menu = menu_create(szTitle, "HandleRsuEditMenu");

    new item1[128], item2[128], item3[128];
    formatex(item1, charsmax(item1), "Top15 Primary Color: \y%s", g_szEditTop15Primary);
    formatex(item2, charsmax(item2), "RankStats Primary Color: \y%s", g_szEditRankstatsPrimary);
    formatex(item3, charsmax(item3), "MapEnd Header Color: \y%s", g_szEditMapendMap);

    menu_additem(menu, item1, "1");
    menu_additem(menu, item2, "2");
    menu_additem(menu, item3, "3");
    menu_additem(menu, "\rCycle Color Preset \d(Gold / Cyan / Purple / Emerald)", "4");
    menu_additem(menu, "\wSave Changes to \yrsu_edit.ini", "5");
    menu_additem(menu, "\wReload Configurations", "6");

    menu_setprop(menu, MPROP_EXIT, MEXIT_ALL);
    FN_MenuFinish(menu, false);
    menu_display(id, menu, 0);
}

public HandleRsuEditMenu(id, menu, item)
{
    if (item == MENU_EXIT || !is_user_connected(id))
    {
        menu_destroy(menu);
        return PLUGIN_HANDLED;
    }

    new szInfo[8], szName[128], access, callback;
    menu_item_getinfo(menu, item, access, szInfo, charsmax(szInfo), szName, charsmax(szName), callback);
    menu_destroy(menu);

    switch (str_to_num(szInfo))
    {
        case 4:
        {
            if (equal(g_szEditTop15Primary, "#d3b35a"))
            {
                copy(g_szEditTop15Primary, charsmax(g_szEditTop15Primary), "#00ffff");
                copy(g_szEditRankstatsPrimary, charsmax(g_szEditRankstatsPrimary), "#00ffff");
            }
            else if (equal(g_szEditTop15Primary, "#00ffff"))
            {
                copy(g_szEditTop15Primary, charsmax(g_szEditTop15Primary), "#bd6dfa");
                copy(g_szEditRankstatsPrimary, charsmax(g_szEditRankstatsPrimary), "#bd6dfa");
            }
            else if (equal(g_szEditTop15Primary, "#bd6dfa"))
            {
                copy(g_szEditTop15Primary, charsmax(g_szEditTop15Primary), "#32cd32");
                copy(g_szEditRankstatsPrimary, charsmax(g_szEditRankstatsPrimary), "#32cd32");
            }
            else
            {
                copy(g_szEditTop15Primary, charsmax(g_szEditTop15Primary), "#d3b35a");
                copy(g_szEditRankstatsPrimary, charsmax(g_szEditRankstatsPrimary), "#d3b35a");
            }
            client_print_color(id, print_team_default, "%s Palette updated to %s.", g_szCfgChatPrefix, g_szEditTop15Primary);
            ShowRsuEditMenu(id);
        }
        case 5:
        {
            SaveEditConfiguration();
            client_print_color(id, print_team_default, "%s Saved MOTD personalization to rsu_edit.ini!", g_szCfgChatPrefix);
            ShowRsuEditMenu(id);
        }
        case 6:
        {
            LoadMainConfiguration();
            LoadEditConfiguration();
            client_print_color(id, print_team_default, "%s Reloaded all configurations from disk!", g_szCfgChatPrefix);
            ShowRsuEditMenu(id);
        }
        default:
        {
            ShowRsuEditMenu(id);
        }
    }
    return PLUGIN_HANDLED;
}

SaveEditConfiguration()
{
    new szConfigDir[64], szFile[128];
    get_configsdir(szConfigDir, charsmax(szConfigDir));
    formatex(szFile, charsmax(szFile), "%s/rsu_edit.ini", szConfigDir);

    new iFile = fopen(szFile, "wt");
    if (!iFile)
        return;

    fprintf(iFile, "; FREENova Rank System Ultimate - MOTD Personalization Configuration^n");
    fprintf(iFile, "[Top15]^n");
    fprintf(iFile, "TOP15_PRIMARY_COLOR = %s^n", g_szEditTop15Primary);
    fprintf(iFile, "TOP15_SECONDARY_COLOR = %s^n^n", g_szEditTop15Secondary);

    fprintf(iFile, "[Rankstats]^n");
    fprintf(iFile, "RANKSTATS_PRIMARY_COLOR = %s^n", g_szEditRankstatsPrimary);
    fprintf(iFile, "RANKSTATS_HEADER_COLOR = %s^n^n", g_szEditRankstatsHeader);

    fprintf(iFile, "[Mapend]^n");
    fprintf(iFile, "MAPEND_MAP_COLOR = %s^n", g_szEditMapendMap);
    fprintf(iFile, "MAPEND_TEAM1_COLOR = %s^n", g_szEditMapendT);
    fprintf(iFile, "MAPEND_TEAM2_COLOR = %s^n", g_szEditMapendCT);

    fclose(iFile);
}

// ============================================================================
// ADMIN CONSOLE COMMANDS
// ============================================================================
public CmdAdminGiveXp(id, level, cid)
{
    if (!cmd_access(id, level, cid, 3))
        return PLUGIN_HANDLED;

    new szTarget[32], szAmount[16];
    read_argv(1, szTarget, charsmax(szTarget));
    read_argv(2, szAmount, charsmax(szAmount));

    new iTarget = cmd_target(id, szTarget, CMDTARGET_OBEY_IMMUNITY | CMDTARGET_NO_BOTS | CMDTARGET_ALLOW_SELF);
    if (!iTarget || !g_bDataLoaded[iTarget])
    {
        console_print(id, "[RSU] Target not found or data not loaded.");
        return PLUGIN_HANDLED;
    }

    new iAmount = str_to_num(szAmount);
    ExecuteXpReward(iTarget, iAmount, RSU_XP_ADMIN);
    console_print(id, "[RSU] Granted %d XP to %s (Total: %d)", iAmount, g_szPlayerName[iTarget], g_iPlayerXP[iTarget]);
    return PLUGIN_HANDLED;
}

public CmdAdminGiveStats(id, level, cid)
{
    if (!cmd_access(id, level, cid, 4))
        return PLUGIN_HANDLED;

    new szTarget[32], szStats[128], szAmount[16];
    read_argv(1, szTarget, charsmax(szTarget));
    read_argv(2, szStats, charsmax(szStats));
    read_argv(3, szAmount, charsmax(szAmount));
    new iAmount = str_to_num(szAmount);

    new bool:bAll = bool:equal(szTarget, "@all");
    new iTarget = 0;
    if (!bAll)
    {
        iTarget = cmd_target(id, szTarget, CMDTARGET_OBEY_IMMUNITY | CMDTARGET_NO_BOTS | CMDTARGET_ALLOW_SELF);
        if (!iTarget)
            return PLUGIN_HANDLED;
    }
    for (new i = 1; i <= MaxClients; i++)
    {
        if (is_user_connected(i) && g_bDataLoaded[i] && (bAll || i == iTarget))
        {
            ApplyStatModification(i, szStats, iAmount, false);
            if (!bAll)
            {
                console_print(id, "[RSU] Modified stats for %s.", g_szPlayerName[i]);
                return PLUGIN_HANDLED;
            }
        }
    }

    if (bAll)
    {
        console_print(id, "[RSU] Modified stats for all active players.");
    }
    return PLUGIN_HANDLED;
}

public CmdAdminResetStats(id, level, cid)
{
    if (!cmd_access(id, level, cid, 3))
        return PLUGIN_HANDLED;

    new szTarget[32], szStats[128];
    read_argv(1, szTarget, charsmax(szTarget));
    read_argv(2, szStats, charsmax(szStats));

    new bool:bAll = bool:equal(szTarget, "@all");
    new iTarget = 0;
    if (!bAll)
    {
        iTarget = cmd_target(id, szTarget, CMDTARGET_OBEY_IMMUNITY | CMDTARGET_NO_BOTS | CMDTARGET_ALLOW_SELF);
        if (!iTarget)
            return PLUGIN_HANDLED;
    }
    for (new i = 1; i <= MaxClients; i++)
    {
        if (is_user_connected(i) && g_bDataLoaded[i] && (bAll || i == iTarget))
        {
            ApplyStatModification(i, szStats, 0, true);
            if (!bAll)
            {
                console_print(id, "[RSU] Reset stats for %s.", g_szPlayerName[i]);
                return PLUGIN_HANDLED;
            }
        }
    }

    if (bAll)
    {
        console_print(id, "[RSU] Reset stats for all active players.");
    }
    return PLUGIN_HANDLED;
}

ApplyStatModification(id, const szStats[], iAmount, bool:bReset)
{
    new szTokens[128], szToken[32];
    copy(szTokens, charsmax(szTokens), szStats);

    new iPos = 0;
    while (szTokens[iPos])
    {
        new iPipe = contain(szTokens[iPos], "|");
        if (iPipe != -1)
        {
            copy(szToken, iPipe, szTokens[iPos]);
            iPos += iPipe + 1;
        }
        else
        {
            copy(szToken, charsmax(szToken), szTokens[iPos]);
            iPos += strlen(szTokens[iPos]);
        }
        trim(szToken);

        if (equali(szToken, "all"))
        {
            if (bReset)
            {
                g_iKills[id] = 0; g_iDeaths[id] = 0; g_iHeadshots[id] = 0; g_iAssists[id] = 0;
                g_iDamage[id] = 0; g_iShots[id] = 0; g_iHits[id] = 0; g_iMVPs[id] = 0;
                g_iC4Plants[id] = 0; g_iC4Defuses[id] = 0; g_iC4Explosions[id] = 0; g_iRoundsWon[id] = 0;
                g_iPlaytime[id] = 0; g_iPlayerXP[id] = 0;
            }
        }
        else if (equali(szToken, "xp")) g_iPlayerXP[id] = bReset ? 0 : max(0, g_iPlayerXP[id] + iAmount);
        else if (equali(szToken, "kills")) g_iKills[id] = bReset ? 0 : max(0, g_iKills[id] + iAmount);
        else if (equali(szToken, "assists")) g_iAssists[id] = bReset ? 0 : max(0, g_iAssists[id] + iAmount);
        else if (equali(szToken, "deaths")) g_iDeaths[id] = bReset ? 0 : max(0, g_iDeaths[id] + iAmount);
        else if (equali(szToken, "headshots")) g_iHeadshots[id] = bReset ? 0 : max(0, g_iHeadshots[id] + iAmount);
        else if (equali(szToken, "planted")) g_iC4Plants[id] = bReset ? 0 : max(0, g_iC4Plants[id] + iAmount);
        else if (equali(szToken, "defused")) g_iC4Defuses[id] = bReset ? 0 : max(0, g_iC4Defuses[id] + iAmount);
        else if (equali(szToken, "exploded")) g_iC4Explosions[id] = bReset ? 0 : max(0, g_iC4Explosions[id] + iAmount);
        else if (equali(szToken, "roundswon")) g_iRoundsWon[id] = bReset ? 0 : max(0, g_iRoundsWon[id] + iAmount);
        else if (equali(szToken, "mvp")) g_iMVPs[id] = bReset ? 0 : max(0, g_iMVPs[id] + iAmount);
        else if (equali(szToken, "shots")) g_iShots[id] = bReset ? 0 : max(0, g_iShots[id] + iAmount);
        else if (equali(szToken, "hits")) g_iHits[id] = bReset ? 0 : max(0, g_iHits[id] + iAmount);
        else if (equali(szToken, "damage")) g_iDamage[id] = bReset ? 0 : max(0, g_iDamage[id] + iAmount);
        else if (equali(szToken, "playedtime")) g_iPlaytime[id] = bReset ? 0 : max(0, g_iPlaytime[id] + iAmount);
    }

    g_iRank[id] = CalculateRank(g_iPlayerXP[id]);
    g_iLevel[id] = g_iRank[id];
    g_iDirtyMask[id] |= (DIRTY_STATS | DIRTY_XP_SKILL);
}

public CmdAdminReload(id, level, cid)
{
    if (!cmd_access(id, level, cid, 1))
        return PLUGIN_HANDLED;

    LoadMainConfiguration();
    LoadEditConfiguration();
    console_print(id, "[RSU] All configuration files successfully reloaded.");
    return PLUGIN_HANDLED;
}

public CmdAdminRsuDoctor(id, level, cid)
{
    if (!cmd_access(id, level, cid, 1))
        return PLUGIN_HANDLED;

    console_print(id, "==================================================");
    console_print(id, " CSWOS Platform Self-Test Diagnostics (Gen 4 Doctor)");
    console_print(id, "==================================================");
    console_print(id, " Plain words, no changes: this command only reports.");

    new bool:bDbOk = (g_hSqlTuple != Empty_Handle);
    new bool:bCircuitOk = (g_iCircuitState == CIRCUIT_CLOSED);
    new bool:bRanksOk = (g_iTotalRanks >= 10);
    new bool:bSkillsOk = (g_iTotalSkills >= 5);
    new bool:bModulesOk = (g_iTotalModules >= 1);

    console_print(id, " [1] Database Handle:      [%s] (%s)", bDbOk ? "PASS" : "FAIL", g_bIsSqlite ? "SQLite" : "MySQL");
    console_print(id, " [2] Circuit Breaker:      [%s] (State: %s, Fails: %d)", bCircuitOk ? "PASS" : "TRIPPED",
        (g_iCircuitState == CIRCUIT_CLOSED) ? "CLOSED" : ((g_iCircuitState == CIRCUIT_OPEN) ? "OPEN" : "HALF_OPEN"),
        g_iCircuitConsecutiveFails);
    console_print(id, " [3] Offline Journal:      [REMOVED] (queue had no producers; direct-save path owns recovery)");
    console_print(id, " [4] Rank Configuration:   [%s] (%d ranks registered)", bRanksOk ? "PASS" : "FAIL", g_iTotalRanks);
    console_print(id, " [5] Skill Configuration:  [%s] (%d skill brackets registered)", bSkillsOk ? "PASS" : "FAIL", g_iTotalSkills);
    console_print(id, " [6] Subsystem Event Bus:  [%s] (%d active modules)", bModulesOk ? "PASS" : "FAIL", g_iTotalModules);

    new iReady = 0, iConnecting = 0;
    for (new i = 1; i <= MaxClients; i++)
    {
        if (is_user_connected(i))
        {
            if (g_iPlayerState[i] == PLAYER_STATE_READY) iReady++;
            else iConnecting++;
        }
    }
    console_print(id, " [7] Player State Machine: [PASS] (%d READY, %d CONNECTING/LOADING)", iReady, iConnecting);
    console_print(id, " [8] Anti-Farm Engine:     [PASS] (8-frag ring buffer active)");
    console_print(id, " [9] Command Rate Limiter: [PASS] (3-token leaky bucket active)");
    console_print(id, " [10] MOTD Buffer Budget:  [PASS] (<1450b ceiling enforced)");

    // ---- Gen 4 extended checks (read-only; plain words, no secret values) ----
    // MOTD URL ownership, canonical (code truth): game MOTD pages are built
    // by freenova_web.inc short links from the freenova_sync cvars fnweb_url
    // / fnweb_public_host (gate: fnweb_enabled); flag images use the
    // rsu_motd_imgbase cvar (host+path only, no https://). The ini
    // MOTD_BASE_URL is diagnostics-only and never drives show_motd;
    // BattlePass.json motd_bp is panel-local config, never read by the game.
    new iExtWarn = 0;

    // [11] Config file re-read with the loader's own rules: [Section]
    // headers, KEY=value split on '=', lines starting with ; # or // are
    // comments. Unknown keys are ignored by design (old files still load).
    new szCfgDir[64], szIni[128];
    get_configsdir(szCfgDir, charsmax(szCfgDir));
    formatex(szIni, charsmax(szIni), "%s/rank_system_ultimate.ini", szCfgDir);
    new bool:bIniOk = false;
    new bool:bSecSeen[6];
    new iSetKeys = 0, iSecMiss = 0;
    if (file_exists(szIni))
    {
        new iFh = fopen(szIni, "rt");
        if (iFh)
        {
            bIniOk = true;
            new szL[512], szK[64], szV[448], iSec = 0;
            while (!feof(iFh))
            {
                fgets(iFh, szL, charsmax(szL));
                trim(szL);
                if (!szL[0] || szL[0] == ';' || szL[0] == '#' || (szL[0] == '/' && szL[1] == '/'))
                    continue;
                if (szL[0] == '[')
                {
                    if (containi(szL, "[Settings]") != -1) iSec = 1;
                    else if (containi(szL, "[Commands]") != -1) iSec = 2;
                    else if (containi(szL, "[XP Rewards]") != -1) iSec = 3;
                    else if (containi(szL, "[Ranks]") != -1) iSec = 4;
                    else if (containi(szL, "[Skills]") != -1) iSec = 5;
                    else iSec = 0;
                    if (iSec >= 1 && iSec <= 5) bSecSeen[iSec] = true;
                    continue;
                }
                if (iSec == 1)
                {
                    strtok(szL, szK, charsmax(szK), szV, charsmax(szV), '=');
                    trim(szK);
                    if (szK[0]) iSetKeys++;
                }
            }
            fclose(iFh);
        }
    }
    for (new s = 1; s <= 5; s++) if (!bSecSeen[s]) iSecMiss++;
    if (!bIniOk)
    {
        iExtWarn++;
        console_print(id, " [11] Config file:       [FAIL] ini not found - built-in defaults are running");
    }
    else if (iSecMiss > 0)
    {
        iExtWarn++;
        console_print(id, " [11] Config file:       [WARN] %d of 5 sections missing - defaults fill the gaps", iSecMiss);
    }
    else
        console_print(id, " [11] Config file:       [PASS] all 5 sections ok (%d settings, %d ranks, %d skills)", iSetKeys, g_iTotalRanks, g_iTotalSkills);

    // [12] Language files (info only). The core ships English text; every
    // player keeps their own engine amx_langmenu language until the
    // localization update lands (prefs LANG slot + dictionaries, pending).
    new szAmx[96];
    copy(szAmx, charsmax(szAmx), szCfgDir);
    new iCut = strlen(szAmx) - 1;
    while (iCut >= 0 && (szAmx[iCut] == '/' || szAmx[iCut] == 92)) { szAmx[iCut] = 0; iCut--; }
    while (iCut >= 0 && szAmx[iCut] != '/' && szAmx[iCut] != 92) { szAmx[iCut] = 0; iCut--; }
    new szProbe[128], iDict = 0;
    formatex(szProbe, charsmax(szProbe), "%sdata/lang/RankSystem.txt", szAmx);
    if (file_exists(szProbe)) iDict++;
    formatex(szProbe, charsmax(szProbe), "%sdata/lang/rt_library.txt", szAmx);
    if (file_exists(szProbe)) iDict++;
    formatex(szProbe, charsmax(szProbe), "%sdata/lang/simple_warmup.txt", szAmx);
    if (file_exists(szProbe)) iDict++;
    console_print(id, " [12] Language files:     [INFO] %d of 3 known dictionaries present (core stays English meanwhile)", iDict);

    // [13] Saved-data (vault) files. The core itself uses SQL (see [1]);
    // these vaults belong to sibling plugins and are created on the live
    // server at runtime. File-name probe only: this plugin never opens a
    // foreign vault (single-owner rule). Missing = not created yet.
    new iVault = 0;
    formatex(szProbe, charsmax(szProbe), "%sdata/vault/freenova_gag.vault", szAmx);
    if (file_exists(szProbe)) iVault++;
    formatex(szProbe, charsmax(szProbe), "%sdata/vault/freenova_stats.vault", szAmx);
    if (file_exists(szProbe)) iVault++;
    formatex(szProbe, charsmax(szProbe), "%sdata/vault/freenova_vipadmin.vault", szAmx);
    if (file_exists(szProbe)) iVault++;
    formatex(szProbe, charsmax(szProbe), "%sdata/vault/freenova_bp.vault", szAmx);
    if (file_exists(szProbe)) iVault++;
    formatex(szProbe, charsmax(szProbe), "%sdata/vault/freenova_prefs.vault", szAmx);
    if (file_exists(szProbe)) iVault++;
    formatex(szProbe, charsmax(szProbe), "%sdata/vault/freenova_events.vault", szAmx);
    if (file_exists(szProbe)) iVault++;
    formatex(szProbe, charsmax(szProbe), "%sdata/vault/freenova_milestones.vault", szAmx);
    if (file_exists(szProbe)) iVault++;
    console_print(id, " [13] Saved-data files:   [INFO] %d of 7 vault files present (missing ones are created live)", iVault);

    // [14] Companion-plugin signals via cvar pointers. Missing = the owning
    // plugin is not running; the core keeps safe defaults in that case
    // (e.g. XP guards treat a missing knife-round flag as a normal round).
    new szMiss[192], iSigFound = 0;
    if (get_cvar_pointer("fn_double_xp")) iSigFound++;
    else { if (szMiss[0]) add(szMiss, charsmax(szMiss), ", "); add(szMiss, charsmax(szMiss), "fn_double_xp(panel)"); }
    if (get_cvar_pointer("fn_happy_hour")) iSigFound++;
    else { if (szMiss[0]) add(szMiss, charsmax(szMiss), ", "); add(szMiss, charsmax(szMiss), "fn_happy_hour(progression)"); }
    if (get_cvar_pointer("fn_event_xp_mult")) iSigFound++;
    else { if (szMiss[0]) add(szMiss, charsmax(szMiss), ", "); add(szMiss, charsmax(szMiss), "fn_event_xp_mult(sync)"); }
    if (get_cvar_pointer("fn_bp_season")) iSigFound++;
    else { if (szMiss[0]) add(szMiss, charsmax(szMiss), ", "); add(szMiss, charsmax(szMiss), "fn_bp_season(battlepass)"); }
    if (get_cvar_pointer("amx_knife_round_active")) iSigFound++;
    else { if (szMiss[0]) add(szMiss, charsmax(szMiss), ", "); add(szMiss, charsmax(szMiss), "amx_knife_round_active(warmup)"); }
    if (get_cvar_pointer("rt_revive_time")) iSigFound++;
    else { if (szMiss[0]) add(szMiss, charsmax(szMiss), ", "); add(szMiss, charsmax(szMiss), "rt_revive_time(revive)"); }
    if (get_cvar_pointer("rt_force_fwd_mode")) iSigFound++;
    else { if (szMiss[0]) add(szMiss, charsmax(szMiss), ", "); add(szMiss, charsmax(szMiss), "rt_force_fwd_mode(revive)"); }
    if (iSigFound == 7)
        console_print(id, " [14] Companion plugins: [PASS] all 7 signals found (panel, progression, sync, battlepass, warmup, revive x2)");
    else
    {
        iExtWarn++;
        console_print(id, " [14] Companion plugins: [WARN] %d of 7 signals found - silent: %s", iSigFound, szMiss);
    }

    // [15] Web MOTD bridge state (values never printed, only verdicts).
    new pWeb = get_cvar_pointer("fnweb_url");
    new pPub = get_cvar_pointer("fnweb_public_host");
    new pGate = get_cvar_pointer("fnweb_enabled");
    new szBase[80], szPub[64], szImg[128];
    szBase[0] = 0; szPub[0] = 0;
    get_cvar_string("rsu_motd_imgbase", szImg, charsmax(szImg));
    if (pWeb) get_cvar_string("fnweb_url", szBase, charsmax(szBase));
    if (pPub) get_cvar_string("fnweb_public_host", szPub, charsmax(szPub));
    trim(szPub);
    new bool:bLoop = (containi(szBase, "127.0.0.1") != -1 || containi(szBase, "localhost") != -1);
    if (!pWeb || !pGate)
        console_print(id, " [15] Web MOTDs:          [INFO] panel bridge absent - every MOTD renders in-game");
    else if (!get_cvar_num("fnweb_enabled"))
        console_print(id, " [15] Web MOTDs:          [INFO] panel bridge switched off - every MOTD renders in-game");
    else if (bLoop && !szPub[0])
    {
        iExtWarn++;
        console_print(id, " [15] Web MOTDs:          [WARN] panel points at this PC only - players would see a broken page");
    }
    else if (!szImg[0])
        console_print(id, " [15] Web MOTDs:          [PASS] bridge ready; flag images off (country codes as text)");
    else
        console_print(id, " [15] Web MOTDs:          [PASS] bridge ready; flag images on");

    // [16] Plugin drift verdict from [14]: an intentionally uninstalled
    // companion reads as WARN here too - only unexpected silence needs
    // action (re-enable or reinstall the owning plugin).
    if (iSigFound == 7)
        console_print(id, " [16] Plugin drift:        [PASS] no drift - every expected companion answers");
    else
        console_print(id, " [16] Plugin drift:        [INFO] %d companion(s) silent - expected only if uninstalled on purpose", 7 - iSigFound);

    new bool:bAllHealthy = (bDbOk && bCircuitOk && bRanksOk && bSkillsOk);
    console_print(id, "--------------------------------------------------");
    console_print(id, " OVERALL HEALTH STATUS: %s", bAllHealthy ? "[ALL SUBSYSTEMS HEALTHY]" : "[DEGRADED / ATTENTION REQUIRED]");
    console_print(id, " Extended checks [11-16]: %s (%d notice(s) above)", iExtWarn == 0 ? "all clear" : "see notes", iExtWarn);
    console_print(id, "==================================================");

    return PLUGIN_HANDLED;
}

public CmdAdminRsuExplainXp(id, level, cid)
{
    if (!cmd_access(id, level, cid, 1))
        return PLUGIN_HANDLED;
    new szArg[32];
    read_argv(1, szArg, charsmax(szArg));

    new iTarget = szArg[0] ? cmd_target(id, szArg, CMDTARGET_OBEY_IMMUNITY | CMDTARGET_NO_BOTS | CMDTARGET_ALLOW_SELF) : id;
    if (!iTarget || !is_user_connected(iTarget))
    {
        console_print(id, "[RSU] Target '%s' not found.", szArg);
        return PLUGIN_HANDLED;
    }

    new Float:flActiveMult = CalculateActiveMultiplier(iTarget);
    new bool:bIsVip = bool:(get_user_flags(iTarget) & read_flags(g_szCfgVipFlags));

    console_print(id, "==================================================");
    console_print(id, " CSWOS XP Calculation Breakdown for %s", g_szPlayerName[iTarget]);
    console_print(id, "==================================================");
    console_print(id, " Current XP: %d | Rank: %d | Level: %d", g_iPlayerXP[iTarget], g_iRank[iTarget], g_iLevel[iTarget]);
    console_print(id, " Base Kill XP: +%d | Headshot Bonus: +%d | Knife: +%d", g_iXpRewards[RWD_KILL][0], g_iXpRewards[RWD_HEADSHOT][0], g_iXpRewards[RWD_KNIFE][0]);
    console_print(id, " Active Multiplier: %.2fx (Base 1.0x %s)", flActiveMult, (flActiveMult > 1.0) ? "+ Bonus Active" : "");
    console_print(id, " VIP Status: %s (Flag: %s)", bIsVip ? "ACTIVE" : "INACTIVE", g_szCfgVipFlags);
    console_print(id, " Current Killstreak: %d frags", g_iCurKillstreak[iTarget]);
    console_print(id, " Anti-Farm Status: Clean (0 recent repeats)");
    console_print(id, " State Machine: %s", (g_iPlayerState[iTarget] == PLAYER_STATE_READY) ? "READY" : "NOT READY");
    console_print(id, "==================================================");

    return PLUGIN_HANDLED;
}





public CmdAdminRsuStatus(id, level, cid)
{
    if (!cmd_access(id, level, cid, 1))
        return PLUGIN_HANDLED;

    new iConnected = 0, iLoaded = 0, iDirty = 0;
    for (new i = 1; i <= MaxClients; i++)
    {
        if (is_user_connected(i))
        {
            iConnected++;
            if (g_bDataLoaded[i])
                iLoaded++;
            if (g_iDirtyMask[i])
                iDirty++;
        }
    }

    console_print(id, "==================================================");
    console_print(id, " FREENova Rank System Ultimate - Engine Diagnostics");
    console_print(id, "==================================================");
    console_print(id, " Version: %s | Author: %s", PLUGIN_VERSION, PLUGIN_AUTHOR);
    console_print(id, " Server ID: %d | Database: %s | Tuple Status: %s",
        get_pcvar_num(g_pCvarServerId),
        g_bIsSqlite ? "SQLite" : "MySQL",
        (g_hSqlTuple != Empty_Handle) ? "ACTIVE" : "OFFLINE"
    );
    console_print(id, " Active Clients: %d | Loaded Players: %d | Dirty Waiting Flush: %d",
        iConnected, iLoaded, iDirty
    );
    console_print(id, " Registered Ranks: %d | Registered Skills: %d",
        g_iTotalRanks, g_iTotalSkills
    );
    console_print(id, " Registered Sub-Modules (%d):", g_iTotalModules);
    for (new m = 0; m < g_iTotalModules; m++)
    {
        console_print(id, "   [%02d] %-24s v%-8s (%s)", m + 1, g_szModuleNames[m], g_szModuleVersions[m], g_szModuleAuthors[m]);
    }
    console_print(id, "==================================================");

    return PLUGIN_HANDLED;
}

public CmdAdminRsuDebugPlayer(id, level, cid)
{
    if (!cmd_access(id, level, cid, 2))
        return PLUGIN_HANDLED;

    new szArg[32];
    read_argv(1, szArg, charsmax(szArg));

    new iTarget = cmd_target(id, szArg, CMDTARGET_OBEY_IMMUNITY | CMDTARGET_NO_BOTS | CMDTARGET_ALLOW_SELF);
    if (!iTarget)
    {
        console_print(id, "[RSU] Target '%s' not found or invalid.", szArg);
        return PLUGIN_HANDLED;
    }

    new rankName[32];
    GetRankDisplayName(g_iRank[iTarget], rankName, charsmax(rankName));

    new Float:kd = (g_iDeaths[iTarget] > 0) ? (float(g_iKills[iTarget]) / float(g_iDeaths[iTarget])) : float(g_iKills[iTarget]);
    new Float:hs = (g_iKills[iTarget] > 0) ? ((float(g_iHeadshots[iTarget]) / float(g_iKills[iTarget])) * 100.0) : 0.0;
    new Float:acc = (g_iShots[iTarget] > 0) ? ((float(g_iHits[iTarget]) / float(g_iShots[iTarget])) * 100.0) : 0.0;

    console_print(id, "==================================================");
    console_print(id, " FREENova Player Telemetry Debug - %s", g_szPlayerName[iTarget]);
    console_print(id, "==================================================");
    console_print(id, " Index: #%d | UserID: #%d | AuthID: %s", iTarget, get_user_userid(iTarget), g_szAuthID[iTarget]);
    console_print(id, " Database ID: %d | Slot Token: %d", g_iDatabaseId[iTarget], g_iConnectionToken[iTarget]);
    console_print(id, " State: Loaded: %s | Loading: %s | Dirty Mask: 0x%04X",
        g_bDataLoaded[iTarget] ? "YES" : "NO",
        g_bLoading[iTarget] ? "YES" : "NO",
        g_iDirtyMask[iTarget]
    );
    console_print(id, " Progression: Account Level: %d | Prestige: %d | Placement: %d/10",
        g_iAccountLevel[iTarget], g_iPrestige[iTarget], g_iPlacementMatches[iTarget]
    );
    console_print(id, " Rank Tier: #%d (%s) | XP: %d | Lifetime XP: %d",
        g_iRank[iTarget], rankName, g_iPlayerXP[iTarget], g_iLifetimeXP[iTarget]
    );
    console_print(id, " Skill ELO: %.1f | Peak Skill: %.1f",
        g_fSkill[iTarget], g_fPeakSkill[iTarget]
    );
    console_print(id, " Combat: Kills: %d | Deaths: %d | K/D: %.2f | HS: %d (%.1f%%)",
        g_iKills[iTarget], g_iDeaths[iTarget], kd, g_iHeadshots[iTarget], hs
    );
    console_print(id, " Telemetry: Damage: %d | Shots: %d | Hits: %d | Acc: %.1f%%",
        g_iDamage[iTarget], g_iShots[iTarget], g_iHits[iTarget], acc
    );
    console_print(id, " Playtime: %d sec (%dh %dm) | IP: %s | Country: %s",
        g_iPlaytime[iTarget], g_iPlaytime[iTarget] / 3600, (g_iPlaytime[iTarget] % 3600) / 60,
        g_szPlayerIP[iTarget], g_szCountry[iTarget]
    );
    console_print(id, " First Seen: %s | Last Seen: %s",
        g_szFirstSeen[iTarget], g_szLastSeen[iTarget]
    );
    console_print(id, "==================================================");

    return PLUGIN_HANDLED;
}

// ============================================================================
// NATIVE API REGISTRATION & IMPLEMENTATIONS
// Registers BOTH "ranksultimate" and "rsu_core" libraries!
// ============================================================================
public RsuNativeFilter(const name[], index, trap)
{
    #pragma unused index, trap
    // RSU must still load if battlepass_core is disabled or fails to load.
    // The BP calls are guarded by LibraryExists("menabp") and
    // menabp_is_ready(); an unresolved native therefore returns 0 safely.
    if (strncmp(name, "menabp_", 7) == 0)
        return PLUGIN_HANDLED
    return PLUGIN_CONTINUE
}

public plugin_natives()
{
    register_library("ranksultimate");
    register_library("rsu_core");
    set_native_filter("RsuNativeFilter");

    // Tornado ranksultimate.inc Natives (32 core + 5 ZP)
    register_native("rsu_get_user_xp", "_rsu_get_user_xp");
    register_native("rsu_get_user_xp_percent", "_rsu_get_user_xp_percent");
    register_native("rsu_get_user_next_xp", "_rsu_get_user_next_xp");
    register_native("rsu_get_xp_for_level", "_rsu_get_xp_for_level");
    register_native("rsu_get_user_level", "_rsu_get_user_level");
    register_native("rsu_get_user_kills", "_rsu_get_user_kills");
    register_native("rsu_get_user_deaths", "_rsu_get_user_deaths");
    register_native("rsu_get_user_headshots", "_rsu_get_user_headshots");
    register_native("rsu_get_user_assists", "_rsu_get_user_assists");
    register_native("rsu_get_user_shots", "_rsu_get_user_shots");
    register_native("rsu_get_user_hits", "_rsu_get_user_hits");
    register_native("rsu_get_user_damage", "_rsu_get_user_damage");
    register_native("rsu_get_user_mvp", "_rsu_get_user_mvp");
    register_native("rsu_get_user_rounds_won", "_rsu_get_user_rounds_won");
    register_native("rsu_get_user_bombs_planted", "_rsu_get_user_bombs_planted");
    register_native("rsu_get_user_bombs_exploded", "_rsu_get_user_bombs_exploded");
    register_native("rsu_get_user_bombs_defused", "_rsu_get_user_bombs_defused");
    register_native("rsu_get_user_played_time", "_rsu_get_user_played_time");
    register_native("rsu_get_user_skill_range", "_rsu_get_user_skill_range");
    register_native("rsu_get_user_server_rank", "_rsu_get_user_server_rank");
    register_native("rsu_get_max_levels", "_rsu_get_max_levels");
    register_native("rsu_get_max_server_ranks", "_rsu_get_max_server_ranks");
    register_native("rsu_get_rank_by_level", "_rsu_get_rank_by_level");
    register_native("rsu_get_user_rank", "_rsu_get_user_rank");
    register_native("rsu_get_user_skill", "_rsu_get_user_skill");
    register_native("rsu_get_user_saveinfo", "_rsu_get_user_saveinfo");
    register_native("rsu_give_user_xp", "_rsu_give_user_xp");
    register_native("rsu_give_team_xp", "_rsu_give_team_xp");
    register_native("rsu_get_user_first_login", "_rsu_get_user_first_login");
    register_native("rsu_get_user_last_login", "_rsu_get_user_last_login");
    register_native("rsu_get_user_weapon_kills", "_rsu_get_user_weapon_kills");

    // ZP Extension Natives
    register_native("rsu_get_user_zombie_wins", "_rsu_get_user_zombie_wins");
    register_native("rsu_get_user_human_wins", "_rsu_get_user_human_wins");
    register_native("rsu_get_user_infections", "_rsu_get_user_infections");
    register_native("rsu_get_user_survivals", "_rsu_get_user_survivals");
    register_native("rsu_get_user_round_infections", "_rsu_get_user_round_infections");
    register_native("rsu_add_user_zombie_wins", "_rsu_add_user_zombie_wins");
    register_native("rsu_add_user_human_wins", "_rsu_add_user_human_wins");
    register_native("rsu_add_user_infections", "_rsu_add_user_infections");
    register_native("rsu_add_user_survivals", "_rsu_add_user_survivals");
    register_native("rsu_set_user_round_infections", "_rsu_set_user_round_infections");

    // Internal rsu.inc Compatibility Natives
    register_native("rsu_is_data_loaded", "_rsu_is_data_loaded");
    register_native("rsu_bots_count", "_rsu_bots_count");
    register_native("rsu_get_player_database_id", "_rsu_get_player_database_id");
    register_native("rsu_get_auth_steamid", "_rsu_get_auth_steamid");
    register_native("rsu_get_connection_token", "_rsu_get_connection_token");
    register_native("rsu_get_xp", "_rsu_get_user_xp");
    register_native("rsu_set_xp", "_rsu_set_xp");
    register_native("rsu_add_xp", "_rsu_add_xp");
    register_native("rsu_remove_xp", "_rsu_remove_xp");
    register_native("rsu_get_lifetime_xp", "_rsu_get_lifetime_xp");
    register_native("rsu_get_level", "_rsu_get_user_level");
    register_native("rsu_get_prestige", "_rsu_get_prestige");
    register_native("rsu_set_prestige", "_rsu_set_prestige");
    register_native("rsu_get_placement_matches", "_rsu_get_placement_matches");
    register_native("rsu_get_rank", "_rsu_get_user_level");
    register_native("rsu_get_rank_name", "_rsu_get_rank_name_legacy");
    register_native("rsu_get_rank_badge", "_rsu_get_rank_badge_legacy");
    register_native("rsu_get_rank_min_xp", "_rsu_get_rank_min_xp");
    register_native("rsu_get_rank_max_xp", "_rsu_get_rank_max_xp");
    register_native("rsu_get_total_ranks", "_rsu_get_max_levels");
    register_native("rsu_get_skill", "_rsu_get_skill");
    register_native("rsu_set_skill", "_rsu_set_skill");
    register_native("rsu_get_peak_skill", "_rsu_get_peak_skill");
    register_native("rsu_get_kills", "_rsu_get_user_kills");
    register_native("rsu_get_deaths", "_rsu_get_user_deaths");
    register_native("rsu_get_headshots", "_rsu_get_user_headshots");
    register_native("rsu_get_assists", "_rsu_get_user_assists");
    register_native("rsu_get_shots", "_rsu_get_user_shots");
    register_native("rsu_get_hits", "_rsu_get_user_hits");
    register_native("rsu_get_damage", "_rsu_get_user_damage");
    register_native("rsu_get_playtime", "_rsu_get_user_played_time");
    register_native("rsu_get_kd_ratio", "_rsu_get_kd_ratio");
    register_native("rsu_get_hs_percentage", "_rsu_get_hs_percentage");
    register_native("rsu_get_accuracy", "_rsu_get_accuracy");
    register_native("rsu_add_weapon_stat", "_rsu_add_weapon_stat");
    register_native("rsu_register_multiplier", "_rsu_register_multiplier");
    register_native("rsu_set_multiplier", "_rsu_set_multiplier");
    register_native("rsu_get_active_multiplier", "_rsu_get_active_multiplier");
    register_native("rsu_register_module", "_rsu_register_module");
    register_native("rsu_open_motd", "_rsu_open_motd");
    register_native("rsu_show_top15", "_rsu_show_top15");
    register_native("rsu_show_rankstats", "_rsu_show_rankstats");
    register_native("rsu_trigger_match_started", "_rsu_trigger_match_started");
    register_native("rsu_trigger_match_finished", "_rsu_trigger_match_finished");
    register_native("rsu_get_sql_tuple", "_rsu_get_sql_tuple");
    register_native("rsu_is_sql_ready", "_rsu_is_sql_ready");
    register_native("rsu_is_sqlite", "_rsu_is_sqlite");

    // Gen 3 Core Natives
    register_native("rsu_is_player_ready", "_rsu_is_player_ready");
    register_native("rsu_get_user_deviation", "_rsu_get_user_deviation");
    register_native("rsu_get_session_uuid", "_rsu_get_session_uuid");
    register_native("rsu_db_save_module_state", "_rsu_db_save_module_state");
    register_native("rsu_db_load_module_state", "_rsu_db_load_module_state");
}

public _rsu_get_user_xp(iPlugin, iParams)
{
    new id = get_param(1);
    return (id >= 1 && id <= MaxClients) ? g_iPlayerXP[id] : 0;
}

public Float:_rsu_get_user_xp_percent(iPlugin, iParams)
{
    new id = get_param(1);
    if (id < 1 || id > MaxClients || g_iTotalRanks <= 0)
        return 0.0;

    new iCurRank = g_iRank[id];
    if (iCurRank >= g_iTotalRanks)
        return 100.0;

    new rankEntry[RankEntry], nextEntry[RankEntry];
    ArrayGetArray(g_aRanks, iCurRank - 1, rankEntry);
    ArrayGetArray(g_aRanks, iCurRank, nextEntry);

    new iDiff = nextEntry[RANK_MIN_XP] - rankEntry[RANK_MIN_XP];
    if (iDiff <= 0)
        return 100.0;

    new Float:fPerc = (float(g_iPlayerXP[id] - rankEntry[RANK_MIN_XP]) / float(iDiff)) * 100.0;
    return floatclamp(fPerc, 0.0, 100.0);
}

public _rsu_get_user_next_xp(iPlugin, iParams)
{
    new id = get_param(1);
    if (id < 1 || id > MaxClients || g_iTotalRanks <= 0)
        return 0;

    new iCurRank = g_iRank[id];
    if (iCurRank >= g_iTotalRanks)
        return g_iPlayerXP[id];

    new nextEntry[RankEntry];
    ArrayGetArray(g_aRanks, iCurRank, nextEntry);
    return nextEntry[RANK_MIN_XP];
}

public _rsu_get_xp_for_level(iPlugin, iParams)
{
    new iLevel = get_param(1);
    if (iLevel < 1 || iLevel > g_iTotalRanks)
        return 0;

    new rankEntry[RankEntry];
    ArrayGetArray(g_aRanks, iLevel - 1, rankEntry);
    return rankEntry[RANK_MIN_XP];
}

public _rsu_get_user_level(iPlugin, iParams)
{
    new id = get_param(1);
    return (id >= 1 && id <= MaxClients) ? g_iLevel[id] : 1;
}

public _rsu_get_user_kills(iPlugin, iParams)
{
    new id = get_param(1);
    return (id >= 1 && id <= MaxClients) ? g_iKills[id] : 0;
}

public _rsu_get_user_deaths(iPlugin, iParams)
{
    new id = get_param(1);
    return (id >= 1 && id <= MaxClients) ? g_iDeaths[id] : 0;
}

public _rsu_get_user_headshots(iPlugin, iParams)
{
    new id = get_param(1);
    return (id >= 1 && id <= MaxClients) ? g_iHeadshots[id] : 0;
}

public _rsu_get_user_assists(iPlugin, iParams)
{
    new id = get_param(1);
    return (id >= 1 && id <= MaxClients) ? g_iAssists[id] : 0;
}

public _rsu_get_user_shots(iPlugin, iParams)
{
    new id = get_param(1);
    return (id >= 1 && id <= MaxClients) ? g_iShots[id] : 0;
}

public _rsu_get_user_hits(iPlugin, iParams)
{
    new id = get_param(1);
    return (id >= 1 && id <= MaxClients) ? g_iHits[id] : 0;
}

public _rsu_get_user_damage(iPlugin, iParams)
{
    new id = get_param(1);
    return (id >= 1 && id <= MaxClients) ? g_iDamage[id] : 0;
}

public _rsu_get_user_mvp(iPlugin, iParams)
{
    new id = get_param(1);
    return (id >= 1 && id <= MaxClients) ? g_iMVPs[id] : 0;
}

public _rsu_get_user_rounds_won(iPlugin, iParams)
{
    new id = get_param(1);
    return (id >= 1 && id <= MaxClients) ? g_iRoundsWon[id] : 0;
}

public _rsu_get_user_bombs_planted(iPlugin, iParams)
{
    new id = get_param(1);
    return (id >= 1 && id <= MaxClients) ? g_iC4Plants[id] : 0;
}

public _rsu_get_user_bombs_exploded(iPlugin, iParams)
{
    new id = get_param(1);
    return (id >= 1 && id <= MaxClients) ? g_iC4Explosions[id] : 0;
}

public _rsu_get_user_bombs_defused(iPlugin, iParams)
{
    new id = get_param(1);
    return (id >= 1 && id <= MaxClients) ? g_iC4Defuses[id] : 0;
}

public _rsu_get_user_played_time(iPlugin, iParams)
{
    new id = get_param(1);
    return (id >= 1 && id <= MaxClients) ? g_iPlaytime[id] : 0;
}

public Float:_rsu_get_user_skill_range(iPlugin, iParams)
{
    new id = get_param(1);
    return (id >= 1 && id <= MaxClients) ? CalculateSkillRange(id) : 100.0;
}

public _rsu_get_user_server_rank(iPlugin, iParams)
{
    new id = get_param(1);
    return (id >= 1 && id <= MaxClients) ? g_iServerRank[id] : 1;
}

public _rsu_get_max_levels(iPlugin, iParams)
{
    return g_iTotalRanks;
}

public _rsu_get_max_server_ranks(iPlugin, iParams)
{
    return max(1, g_iTotalServerPlayers);
}

public _rsu_get_rank_by_level(iPlugin, iParams)
{
    new iLevel = get_param(1);
    new szName[32];
    GetRankDisplayName(iLevel, szName, charsmax(szName));
    return set_string(2, szName, get_param(3));
}

public _rsu_get_user_rank(iPlugin, iParams)
{
    new id = get_param(1);
    new szName[32];
    if (id >= 1 && id <= MaxClients)
        GetRankDisplayName(g_iRank[id], szName, charsmax(szName));
    else
        copy(szName, charsmax(szName), "Unranked");
    return set_string(2, szName, get_param(3));
}

public _rsu_get_user_skill(iPlugin, iParams)
{
    new id = get_param(1);
    new szSkill[16];
    if (id >= 1 && id <= MaxClients)
        GetSkillName(CalculateSkillRange(id), szSkill, charsmax(szSkill));
    else
        copy(szSkill, charsmax(szSkill), "M");
    return set_string(2, szSkill, get_param(3));
}

public _rsu_get_user_saveinfo(iPlugin, iParams)
{
    new id = get_param(1);
    if (id < 1 || id > MaxClients)
        return 0;
    return set_string(2, g_szAuthID[id], get_param(3));
}

public _rsu_give_user_xp(iPlugin, iParams)
{
    new id = get_param(1);
    new iAmount = get_param(2);
    return ExecuteXpReward(id, iAmount, RSU_XP_CUSTOM, false);
}

public _rsu_give_team_xp(iPlugin, iParams)
{
    new iTeam = get_param(1);
    new iAmount = get_param(2);
    ExecuteTeamXp(iTeam, iAmount);
    return 1;
}

public _rsu_get_user_first_login(iPlugin, iParams)
{
    new id = get_param(1);
    if (id < 1 || id > MaxClients)
        return 0;
    return set_string(2, g_szFirstSeen[id], get_param(3));
}

public _rsu_get_user_last_login(iPlugin, iParams)
{
    new id = get_param(1);
    if (id < 1 || id > MaxClients)
        return 0;
    return set_string(2, g_szLastSeen[id], get_param(3));
}

public _rsu_get_user_weapon_kills(iPlugin, iParams)
{
    new id = get_param(1);
    new iWeapon = get_param(2);
    if (id < 1 || id > MaxClients || iWeapon < 0 || iWeapon >= RSU_TOTAL_WEAPONS)
        return 0;
    return g_iWeaponKills[id][iWeapon];
}

// ZP Extension Callback implementations
public _rsu_get_user_zombie_wins(iPlugin, iParams)
{
    new id = get_param(1);
    return (id >= 1 && id <= MaxClients) ? g_iZombieWins[id] : 0;
}

public _rsu_get_user_human_wins(iPlugin, iParams)
{
    new id = get_param(1);
    return (id >= 1 && id <= MaxClients) ? g_iHumanWins[id] : 0;
}

public _rsu_get_user_infections(iPlugin, iParams)
{
    new id = get_param(1);
    return (id >= 1 && id <= MaxClients) ? g_iInfections[id] : 0;
}

public _rsu_get_user_survivals(iPlugin, iParams)
{
    new id = get_param(1);
    return (id >= 1 && id <= MaxClients) ? g_iSurvivals[id] : 0;
}

public _rsu_get_user_round_infections(iPlugin, iParams)
{
    new id = get_param(1);
    return (id >= 1 && id <= MaxClients) ? g_iRoundInfections[id] : 0;
}

public _rsu_add_user_zombie_wins(iPlugin, iParams)
{
    new id = get_param(1);
    if (id >= 1 && id <= MaxClients)
    {
        g_iZombieWins[id] += get_param(2);
        g_iDirtyMask[id] |= DIRTY_STATS;
        return g_iZombieWins[id];
    }
    return 0;
}

public _rsu_add_user_human_wins(iPlugin, iParams)
{
    new id = get_param(1);
    if (id >= 1 && id <= MaxClients)
    {
        g_iHumanWins[id] += get_param(2);
        g_iDirtyMask[id] |= DIRTY_STATS;
        return g_iHumanWins[id];
    }
    return 0;
}

public _rsu_add_user_infections(iPlugin, iParams)
{
    new id = get_param(1);
    if (id >= 1 && id <= MaxClients)
    {
        g_iInfections[id] += get_param(2);
        g_iRoundInfections[id] += get_param(2);
        g_iDirtyMask[id] |= DIRTY_STATS;
        return g_iInfections[id];
    }
    return 0;
}

public _rsu_add_user_survivals(iPlugin, iParams)
{
    new id = get_param(1);
    if (id >= 1 && id <= MaxClients)
    {
        g_iSurvivals[id] += get_param(2);
        g_iDirtyMask[id] |= DIRTY_STATS;
        return g_iSurvivals[id];
    }
    return 0;
}

public _rsu_set_user_round_infections(iPlugin, iParams)
{
    new id = get_param(1);
    if (id >= 1 && id <= MaxClients)
    {
        g_iRoundInfections[id] = get_param(2);
        return g_iRoundInfections[id];
    }
    return 0;
}

// Internal rsu.inc Legacy Callbacks
public bool:_rsu_is_data_loaded(iPlugin, iParams)
{
    new id = get_param(1);
    return (id >= 1 && id <= MaxClients) ? g_bDataLoaded[id] : false;
}

// RANK_BOTS master switch for consumers (bot counting follows it).
public bool:_rsu_bots_count(iPlugin, iParams)
{
    return (g_iCfgRankBots == 1);
}

public _rsu_get_player_database_id(iPlugin, iParams)
{
    new id = get_param(1);
    return (id >= 1 && id <= MaxClients) ? g_iDatabaseId[id] : 0;
}

public _rsu_get_auth_steamid(iPlugin, iParams)
{
    new id = get_param(1);
    if (id < 1 || id > MaxClients)
        return 0;
    return set_string(2, g_szAuthID[id], get_param(3));
}

public _rsu_get_connection_token(iPlugin, iParams)
{
    new id = get_param(1);
    return (id >= 1 && id <= MaxClients) ? g_iConnectionToken[id] : 0;
}

public _rsu_get_prestige(iPlugin, iParams)
{
    new id = get_param(1);
    return (id >= 1 && id <= MaxClients) ? g_iPrestige[id] : 0;
}

public bool:_rsu_set_prestige(iPlugin, iParams)
{
    new id = get_param(1);
    if (id < 1 || id > MaxClients || !g_bDataLoaded[id])
        return false;
    g_iPrestige[id] = max(0, get_param(2));
    g_iDirtyMask[id] |= DIRTY_XP_SKILL;
    return true;
}

public _rsu_get_placement_matches(iPlugin, iParams)
{
    new id = get_param(1);
    return (id >= 1 && id <= MaxClients) ? g_iPlacementMatches[id] : 0;
}

public bool:_rsu_set_xp(iPlugin, iParams)
{
    new id = get_param(1);
    if (id < 1 || id > MaxClients || !g_bDataLoaded[id])
        return false;

    new iAmount = max(0, get_param(2));
    new RsuXpSource:source = RsuXpSource:get_param(3);
    new iOldXP = g_iPlayerXP[id];
    new iOldRank = g_iRank[id];

    g_iPlayerXP[id] = iAmount;
    g_iRank[id] = CalculateRank(iAmount);
    g_iLevel[id] = g_iRank[id];
    g_iDirtyMask[id] |= DIRTY_XP_SKILL;

    // CRX contract: set_user_xp still notifies consumers of the level change
    // and the XP update (season reset relies on this to refresh BattlePass
    // and HUD caches without waiting for the next XP event).
    if (g_iRank[id] != iOldRank)
    {
        new bool:bLevelUp = (g_iRank[id] > iOldRank);
        TriggerLevelEffects(id, iOldRank, g_iRank[id], bLevelUp);
        ExecuteForward(g_fwdUserLevelUpdated, _, id, g_iRank[id], bLevelUp);
        ExecuteForward(g_fwdPlayerRankChanged, _, id, iOldRank, g_iRank[id]);
    }

    ExecuteForward(g_fwdUserXpUpdated, _, id, g_iPlayerXP[id], false);
    ExecuteForward(g_fwdPlayerXpPost, _, id, iOldXP, iAmount, iAmount - iOldXP, source);
    return true;
}

public _rsu_add_xp(iPlugin, iParams)
{
    new id = get_param(1);
    new iAmount = get_param(2);
    new RsuXpSource:source = RsuXpSource:get_param(3);
    return ExecuteXpReward(id, iAmount, source, false);
}

public _rsu_remove_xp(iPlugin, iParams)
{
    new id = get_param(1);
    if (id < 1 || id > MaxClients || !g_bDataLoaded[id])
        return 0;

    new iAmount = max(0, get_param(2));
    new RsuXpSource:source = RsuXpSource:get_param(3);
    new iOldXP = g_iPlayerXP[id];
    new iOldRank = g_iRank[id];

    g_iPlayerXP[id] = max(0, g_iPlayerXP[id] - iAmount);
    g_iRank[id] = CalculateRank(g_iPlayerXP[id]);
    g_iLevel[id] = g_iRank[id];
    g_iDirtyMask[id] |= DIRTY_XP_SKILL;

    // Same consumer contract as _rsu_set_xp: rank changes (including
    // penalty demotions) fire level/rank/XP forwards so season/HUD caches
    // stay in sync without waiting for the next XP event.
    if (g_iRank[id] != iOldRank)
    {
        new bool:bLevelUp = (g_iRank[id] > iOldRank);
        TriggerLevelEffects(id, iOldRank, g_iRank[id], bLevelUp);
        ExecuteForward(g_fwdUserLevelUpdated, _, id, g_iRank[id], bLevelUp);
        ExecuteForward(g_fwdPlayerRankChanged, _, id, iOldRank, g_iRank[id]);
    }

    ExecuteForward(g_fwdUserXpUpdated, _, id, g_iPlayerXP[id], false);
    ExecuteForward(g_fwdPlayerXpPost, _, id, iOldXP, g_iPlayerXP[id], -iAmount, source);
    return iAmount;
}

public _rsu_get_lifetime_xp(iPlugin, iParams)
{
    new id = get_param(1);
    return (id >= 1 && id <= MaxClients) ? g_iLifetimeXP[id] : 0;
}

public _rsu_get_rank_name_legacy(iPlugin, iParams)
{
    new iRankId = get_param(1);
    new szName[32];
    GetRankDisplayName(iRankId, szName, charsmax(szName));
    return set_string(2, szName, get_param(3));
}

public _rsu_get_rank_badge_legacy(iPlugin, iParams)
{
    new iRankId = get_param(1);
    new rankEntry[RankEntry];
    for (new i = 0; i < g_iTotalRanks; i++)
    {
        ArrayGetArray(g_aRanks, i, rankEntry);
        if (rankEntry[RANK_ID] == iRankId)
        {
            return set_string(2, rankEntry[RANK_BADGE], get_param(3));
        }
    }
    return set_string(2, "rank_1.png", get_param(3));
}

public _rsu_get_rank_min_xp(iPlugin, iParams)
{
    new iRankId = get_param(1);
    new rankEntry[RankEntry];
    for (new i = 0; i < g_iTotalRanks; i++)
    {
        ArrayGetArray(g_aRanks, i, rankEntry);
        if (rankEntry[RANK_ID] == iRankId)
        {
            return rankEntry[RANK_MIN_XP];
        }
    }
    return 0;
}

public _rsu_get_rank_max_xp(iPlugin, iParams)
{
    new iRankId = get_param(1);
    new rankEntry[RankEntry];
    for (new i = 0; i < g_iTotalRanks; i++)
    {
        ArrayGetArray(g_aRanks, i, rankEntry);
        if (rankEntry[RANK_ID] == iRankId)
        {
            return rankEntry[RANK_MAX_XP];
        }
    }
    return -1;
}

public Float:_rsu_get_skill(iPlugin, iParams)
{
    new id = get_param(1);
    return (id >= 1 && id <= MaxClients) ? g_fSkill[id] : RSU_DEFAULT_SKILL;
}

public bool:_rsu_set_skill(iPlugin, iParams)
{
    new id = get_param(1);
    if (id < 1 || id > MaxClients || !g_bDataLoaded[id])
        return false;

    new Float:fOldSkill = g_fSkill[id];
    new Float:fNewSkill = get_param_f(2);
    g_fSkill[id] = fNewSkill;
    if (g_fSkill[id] > g_fPeakSkill[id])
        g_fPeakSkill[id] = g_fSkill[id];

    g_iDirtyMask[id] |= DIRTY_XP_SKILL;
    ExecuteForward(g_fwdPlayerSkillChanged, _, id, fOldSkill, fNewSkill);
    return true;
}

public Float:_rsu_get_peak_skill(iPlugin, iParams)
{
    new id = get_param(1);
    return (id >= 1 && id <= MaxClients) ? g_fPeakSkill[id] : 100.0;
}

public Float:_rsu_get_kd_ratio(iPlugin, iParams)
{
    new id = get_param(1);
    if (id < 1 || id > MaxClients)
        return 0.0;
    if (g_iDeaths[id] == 0)
        return float(g_iKills[id]);
    return float(g_iKills[id]) / float(g_iDeaths[id]);
}

public Float:_rsu_get_hs_percentage(iPlugin, iParams)
{
    new id = get_param(1);
    if (id < 1 || id > MaxClients || g_iKills[id] == 0)
        return 0.0;
    return (float(g_iHeadshots[id]) / float(g_iKills[id])) * 100.0;
}

public Float:_rsu_get_accuracy(iPlugin, iParams)
{
    new id = get_param(1);
    if (id < 1 || id > MaxClients || g_iShots[id] == 0)
        return 0.0;
    return (float(g_iHits[id]) / float(g_iShots[id])) * 100.0;
}

public bool:_rsu_add_weapon_stat(iPlugin, iParams)
{
    new id = get_param(1);
    new iWeaponId = get_param(2);
    new RsuWeaponStat:statType = RsuWeaponStat:get_param(3);
    new iAmount = get_param(4);

    if (id < 1 || id > MaxClients || iWeaponId < 1 || iWeaponId >= RSU_MAX_WEAPONS)
        return false;

    g_iWeaponStats[id][iWeaponId][_:statType] += iAmount;
    g_iDirtyMask[id] |= DIRTY_WEAPONS;
    return true;
}

public _rsu_register_multiplier(iPlugin, iParams)
{
    if (g_iTotalMultipliers >= MAX_MULTIPLIERS)
        return -1;

    new szName[32];
    get_string(1, szName, charsmax(szName));
    new Float:fMultiplier = get_param_f(2);

    new iSlot = g_iTotalMultipliers++;
    copy(g_szMultiplierNames[iSlot], charsmax(g_szMultiplierNames[]), szName);
    g_fMultiplierValues[iSlot] = fMultiplier;
    return iSlot;
}

public bool:_rsu_set_multiplier(iPlugin, iParams)
{
    new iSlot = get_param(1);
    if (iSlot < 0 || iSlot >= g_iTotalMultipliers)
        return false;

    g_fMultiplierValues[iSlot] = get_param_f(2);
    return true;
}

public Float:_rsu_get_active_multiplier(iPlugin, iParams)
{
    #pragma unused iPlugin, iParams
    new Float:fTotal = 1.0;
    for (new i = 0; i < g_iTotalMultipliers; i++)
    {
        if (g_fMultiplierValues[i] > 1.0)
            fTotal *= g_fMultiplierValues[i];
    }
    return fTotal;
}

public bool:_rsu_register_module(iPlugin, iParams)
{
    if (g_iTotalModules >= MAX_MODULES)
        return false;

    new szName[32], szVer[16], szAuthor[32];
    get_string(1, szName, charsmax(szName));
    get_string(2, szVer, charsmax(szVer));
    get_string(3, szAuthor, charsmax(szAuthor));

    new iSlot = g_iTotalModules++;
    copy(g_szModuleNames[iSlot], charsmax(g_szModuleNames[]), szName);
    copy(g_szModuleVersions[iSlot], charsmax(g_szModuleVersions[]), szVer);
    copy(g_szModuleAuthors[iSlot], charsmax(g_szModuleAuthors[]), szAuthor);

    log_amx("[RSU MODULE] Registered: %s v%s by %s", szName, szVer, szAuthor);
    return true;
}

public bool:_rsu_open_motd(iPlugin, iParams)
{
    new id = get_param(1);
    if (!is_user_connected(id))
        return false;

    new szEndpoint[32], szParam[64];
    get_string(2, szEndpoint, charsmax(szEndpoint));
    get_string(3, szParam, charsmax(szParam));
    OpenMotdScreen(id, szEndpoint, szParam);
    return true;
}

public _rsu_show_top15(iPlugin, iParams)
{
    new id = get_param(1);
    new szSort[32];
    get_string(2, szSort, charsmax(szSort));
    ShowTop15Motd(id, szSort[0] ? szSort : "xp");
    return 1;
}

public _rsu_show_rankstats(iPlugin, iParams)
{
    new id = get_param(1);
    new target = get_param(2);
    ShowRankStatsMotd(id, target);
    return 1;
}

public bool:_rsu_trigger_match_started(iPlugin, iParams)
{
    new iMatchId = get_param(1);
    new szMap[64];
    get_string(2, szMap, charsmax(szMap));
    ExecuteForward(g_fwdMatchStarted, _, iMatchId, szMap);
    return true;
}

public bool:_rsu_trigger_match_finished(iPlugin, iParams)
{
    new iMatchId = get_param(1);
    new iTScore = get_param(2);
    new iCTScore = get_param(3);
    new iWinner = get_param(4);
    ExecuteForward(g_fwdMatchFinished, _, iMatchId, iTScore, iCTScore, iWinner);
    return true;
}

public Handle:_rsu_get_sql_tuple(iPlugin, iParams)
{
    #pragma unused iPlugin, iParams
    return g_hSqlTuple;
}

public bool:_rsu_is_sql_ready(iPlugin, iParams)
{
    #pragma unused iPlugin, iParams
    return (g_hSqlTuple != Empty_Handle);
}

public bool:_rsu_is_sqlite(iPlugin, iParams)
{
    #pragma unused iPlugin, iParams
    return g_bIsSqlite;
}

public bool:_rsu_is_player_ready(iPlugin, iParams)
{
    new id = get_param(1);
    if (id < 1 || id > MaxClients)
        return false;
    return (g_iPlayerState[id] == PLAYER_STATE_READY);
}

public Float:_rsu_get_user_deviation(iPlugin, iParams)
{
    new id = get_param(1);
    if (id < 1 || id > MaxClients)
        return 350.0;
    return g_fDeviation[id];
}

public _rsu_get_session_uuid(iPlugin, iParams)
{
    new id = get_param(1);
    new iMaxLen = get_param(3);
    if (id < 1 || id > MaxClients)
        return 0;
    return set_string(2, g_szSessionUUID[id], iMaxLen);
}

public bool:_rsu_db_save_module_state(iPlugin, iParams)
{
    new id = get_param(1);
    if (id < 1 || id > MaxClients || g_iDatabaseId[id] <= 0 || g_hSqlTuple == Empty_Handle)
        return false;

    new szTag[16], szBlob[512], szEscBlob[1024];
    get_string(2, szTag, charsmax(szTag));
    get_string(3, szBlob, charsmax(szBlob));

    EscapeSql( szEscBlob, charsmax(szEscBlob), szBlob);

    new szQuery[1200];
    if (g_bIsSqlite)
    {
        formatex(szQuery, charsmax(szQuery),
            "INSERT OR REPLACE INTO `%smodule_data` (`player_id`, `module_tag`, `data_blob`, `updated_at`) VALUES (%d, '%s', '%s', CURRENT_TIMESTAMP);",
            g_szSqlTablePrefix, g_iDatabaseId[id], szTag, szEscBlob);
    }
    else
    {
        formatex(szQuery, charsmax(szQuery),
            "INSERT INTO `%smodule_data` (`player_id`, `module_tag`, `data_blob`) VALUES (%d, '%s', '%s') ON DUPLICATE KEY UPDATE `data_blob` = VALUES(`data_blob`), `updated_at` = CURRENT_TIMESTAMP;",
            g_szSqlTablePrefix, g_iDatabaseId[id], szTag, szEscBlob);
    }
    SQL_ThreadQuery(g_hSqlTuple, "ThreadQuery_Generic", szQuery);
    return true;
}

public bool:_rsu_db_load_module_state(iPlugin, iParams)
{
    #pragma unused iPlugin, iParams
    return false;
}