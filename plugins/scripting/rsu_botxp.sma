/*
 * RSU Bot XP  (rsu_botxp)
 * ============================================================================
 * Pays human players CRX XP for killing BOTS, through the same pipe as every
 * other FreeNova payer:
 *
 *     crxranks_give_user_xp(id, amount, "", CRXRANKS_XPS_PLUGIN)
 *
 * so the BattlePass/VIP/happy-hour multiplier chain applies exactly ONCE per
 * bot kill (XP ownership stays in CRX - see FREENOVA_SYSTEM_DOCUMENTATION
 * section 4 and the freenova_teamxp.sma header). This plugin never touches
 * rank storage directly.
 *
 * Rules (all per kill, evaluated in order):
 *   - victim must be a bot (is_user_bot); killer must be a connected human
 *   - suicides (killer == victim) are skipped
 *   - knife/warmup rounds are skipped (amx_knife_round_active == 1 guard,
 *     same as freenova_teamxp / freenova_progression)
 *   - team kills are skipped unless rsu_botxp_teamkill is 1
 *   - per-player per-round cap via rsu_botxp_roundcap (counter reset on
 *     Round_Start logevent; 0 = uncapped)
 *   - CRX must be present (LibraryExists("crxranks") gate, same as
 *     freenova_clutch) and the killer's CRX row loaded
 *
 * STACKING vs freenova_progression (verified defaults):
 *   freenova_progression.sma owns its own capped bot-kill award
 *   (fn_botxp_enabled = 1, fn_botxp_kill = 3, fn_botxp_hs = 1,
 *   fn_botxp_max_round = 20 - defaults ON). Both plugins feed the SAME pool
 *   through crxranks_give_user_xp, so with both enabled a human killing a
 *   bot is paid TWICE (once here, once there). This plugin's default
 *   (rsu_botxp_kill = 5) is intentionally low for that case. Tune ONE side:
 *   disable one plugin's bot XP (rsu_botxp_enabled 0 / fn_botxp_enabled 0)
 *   rather than editing amounts in either file.
 *
 * Cvars (rsu_botxp_*, FCVAR_PROTECTED):
 *   rsu_botxp_enabled    1   - master switch
 *   rsu_botxp_kill       5   - XP per bot kill (clamped 0..100)
 *   rsu_botxp_roundcap   30  - max bot-kill XP per player per round (0 = off, clamped 0..500)
 *   rsu_botxp_teamkill   0   - 1 = also pay for bot team kills
 * ============================================================================
 */

#include <amxmodx>
#include <cstrike>
#include <crxranks>
#include <crxranks_const>

#define PLUGIN_NAME     "RSU Bot XP"
#define PLUGIN_VERSION  "1.0"
#define PLUGIN_AUTHOR   "FreeNova"

#define MAX_BOTXP_KILL  100
#define MAX_BOTXP_CAP   500

new g_pEnabled
new g_pKillXP
new g_pRoundCap
new g_pTeamKill

new g_iRoundBotXp[33]

public plugin_init()
{
    register_plugin(PLUGIN_NAME, PLUGIN_VERSION, PLUGIN_AUTHOR)

    g_pEnabled  = register_cvar("rsu_botxp_enabled", "1", FCVAR_PROTECTED)
    g_pKillXP   = register_cvar("rsu_botxp_kill", "5", FCVAR_PROTECTED)
    g_pRoundCap = register_cvar("rsu_botxp_roundcap", "30", FCVAR_PROTECTED)
    g_pTeamKill = register_cvar("rsu_botxp_teamkill", "0", FCVAR_PROTECTED)

    register_event("DeathMsg", "OnPlayerKilled", "a")
    register_logevent("LogEvent_BotXpRoundStart", 2, "1=Round_Start")
}

public client_putinserver(id)
{
    if (id >= 1 && id <= MaxClients)
        g_iRoundBotXp[id] = 0
}

public client_disconnected(id)
{
    if (id >= 1 && id <= MaxClients)
        g_iRoundBotXp[id] = 0
}

public LogEvent_BotXpRoundStart()
{
    for (new i = 1; i <= MaxClients; i++)
        g_iRoundBotXp[i] = 0
}

// DeathMsg (a flag): param1 = killer id, param2 = victim id
public OnPlayerKilled()
{
    if (!LibraryExists("crxranks", LibType_Library))
        return
    if (!get_pcvar_num(g_pEnabled))
        return
    if (get_cvar_num("amx_knife_round_active") == 1)
        return

    new iKiller = read_data(1)
    new iVictim = read_data(2)

    if (!iKiller || iKiller == iVictim)
        return
    if (!is_user_connected(iKiller) || !is_user_connected(iVictim))
        return
    if (is_user_bot(iKiller) || !is_user_bot(iVictim))
        return

    // team kill: same team pays only when explicitly enabled
    if (cs_get_user_team(iKiller) == cs_get_user_team(iVictim) && !get_pcvar_num(g_pTeamKill))
        return

    if (!crxranks_is_user_loaded(iKiller))
        return

    new iReward = get_pcvar_num(g_pKillXP)
    if (iReward <= 0)
        return
    if (iReward > MAX_BOTXP_KILL)
        iReward = MAX_BOTXP_KILL

    new iCap = get_pcvar_num(g_pRoundCap)
    if (iCap < 0)
        iCap = 0
    else if (iCap > MAX_BOTXP_CAP)
        iCap = MAX_BOTXP_CAP
    if (iCap > 0 && g_iRoundBotXp[iKiller] + iReward > iCap)
        return

    g_iRoundBotXp[iKiller] += iReward

    // empty reward keyword: raw amount, BattlePass/VIP multiplier forward
    // still applies inside CRX (crxranks_user_receive_xp) exactly once
    crxranks_give_user_xp(iKiller, iReward, "", CRXRANKS_XPS_PLUGIN)

    new szName[32]
    get_user_name(iKiller, szName, charsmax(szName))
    log_amx("[RSU][BotXP] %s earned %d XP for killing a bot (round total %d)", szName, iReward, g_iRoundBotXp[iKiller])
}
