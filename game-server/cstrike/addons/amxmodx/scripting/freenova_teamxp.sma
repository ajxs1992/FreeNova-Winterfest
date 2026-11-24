#include <amxmodx>
#include <amxmisc>
#include <csx>
#include <csstats_const>
#include <fakemeta>
#include <cstrike>
#include <crxranks>
#include <freenova_vip>
#include <rsu>
#include <fn_common>

// RANK_BOTS master switch reader: true only when rsu_core runs RANK_BOTS=1.
// Victim-side assist credit opens when on; payees stay human (bots are
// never CRX-loaded, so crxranks_is_user_loaded still gates every payout).
stock bool:BotCountOn()
{
    return LibraryExists("rsu_core", LibType_Library) && rsu_bots_count();
}

// FreeNova Team XP (RSU-merge feature set): damage-based assists and team
// objective/win XP shares, mirroring Tornado Rank System Ultimate behavior:
//   - assist: >= RSU_ASSIST_MINDMG damage to a victim killed by a teammate,
//             attacker and assistant each get their own reward (no frag steal)
//   - team XP: bomb plant/defuse/explode pay a share to the whole team,
//              winners get a share on round win - fed via crxranks_give_user_xp
//              so BattlePass/VIP multiplier chain still applies (XP ownership
//              stays in CRX - see FREENOVA_SYSTEM_DOCUMENTATION section 4).
//
// STACKING vs rsu_core (documented, amounts intentionally unchanged):
// crxranks_give_user_xp() here is routed by rsu_crx_compat into rsu_add_xp(),
// i.e. this plugin and rsu_core feed the SAME XP pool. Ownership is split by
// config, not by code - each side still evaluates independently, so the split
// only holds while rank_system_ultimate.ini keeps these keys at zero:
//   - ASSIST      : ini assist = 0 0  -> core COUNTS assists (rsu_players
//                   stats) but pays 0; this plugin pays fn_teamxp_assist to
//                   the best damager. If assist is raised in the ini, the
//                   assistant is paid TWICE (both engines fire on DeathMsg).
//   - BOMB        : ini bomb_plant/defuse/explode = <personal> 0 -> core pays
//                   the personal part only; the team share comes from
//                   fn_teamxp_plant/defuse/explode. Raising the ini team
//                   column stacks a second team share on top of ours.
//   - ROUND WIN   : ini t_win/ct_win/t_lose/ct_lose = 0 0 -> core's
//                   Rsu_OnRoundWinAudio only counts rounds and fires
//                   fn_on_round_win (no XP paid), so win/lose shares here are
//                   not doubled. Raising those keys would stack.
//   - KILL/HS/Knife/MVP/hostage: core-only (this plugin never pays them).
// Payout numbers are governed by the fn_teamxp_* cvars above and the ini;
// do not change them in this file to "fix" stacking - tune one side instead.

#define PLUGIN_NAME     "FreeNova Team XP"
#define PLUGIN_VERSION  "1.0"
#define PLUGIN_AUTHOR   "FreeNova"

new g_pEnabled
new g_pAssistXP
new g_pAssistMinDmg
new g_pTeamPlant
new g_pTeamDefuse
new g_pTeamExplode
new g_pTeamWin
new g_pTeamLose

new g_iDamage[33][33] // attacker -> victim accumulated damage this life

public plugin_init()
{
    fn_boot_banner("teamxp", 12)

    register_plugin(PLUGIN_NAME, PLUGIN_VERSION, PLUGIN_AUTHOR)

    g_pEnabled      = register_cvar("fn_teamxp_enabled", "1")
    g_pAssistXP     = register_cvar("fn_teamxp_assist", "1")
    g_pAssistMinDmg = register_cvar("fn_teamxp_assist_mindmg", "40")
    g_pTeamPlant    = register_cvar("fn_teamxp_plant", "2")
    g_pTeamDefuse   = register_cvar("fn_teamxp_defuse", "5")
    g_pTeamExplode  = register_cvar("fn_teamxp_explode", "2")
    g_pTeamWin      = register_cvar("fn_teamxp_win", "1")
    g_pTeamLose     = register_cvar("fn_teamxp_lose", "1")

    register_event("Damage", "OnDamage", "b", "2!0")
    register_event("DeathMsg", "OnPlayerKilled", "a")
    // NOTE: terwin AND ctwin on one SendAudio never fires (one event carries
    // only one sound) - two registrations, same handler (cf. competitive).
    register_event("SendAudio", "OnTeamWin", "a", "2&%!MRAD_terwin")
    register_event("SendAudio", "OnTeamWin", "a", "2&%!MRAD_ctwin")
    register_logevent("LogEvent_TeamXpRoundStart", 2, "1=Round_Start")
}

public client_putinserver(id)
{
    arrayset(g_iDamage[id], 0, sizeof(g_iDamage[]))
}

public client_disconnected(id)
{
    // Row g_iDamage[id] = damage dealt TO id; column g_iDamage[][id] = damage
    // dealt BY id. Both must go or the next slot occupant inherits credit.
    arrayset(g_iDamage[id], 0, sizeof(g_iDamage[]))
    for (new i = 1; i <= MaxClients; i++)
        g_iDamage[i][id] = 0
}

public LogEvent_TeamXpRoundStart()
{
    // Victims who survived the round keep a ledger; wipe it so last round's
    // damage cannot award this round's assists.
    for (new v = 1; v <= MaxClients; v++)
        arrayset(g_iDamage[v], 0, sizeof(g_iDamage[]))
}

// Damage event (b flag): param1 = attacker id, param2 = damage dealt
public OnDamage(iVictim)
{
    if (!get_pcvar_num(g_pEnabled))
        return

    // Same knife-round guard as OnPlayerKilled/GiveTeamXP: warmup damage
    // must not build assist credit. Without it the ledger keeps accruing
    // during knife warmup (the kill path returns BEFORE wiping the victim
    // row), so credit earned while amx_knife_round_active = 1 could be paid
    // by a kill once warmup ends without an intervening Round_Start wipe.
    if (get_cvar_num("amx_knife_round_active") == 1)
        return

    new iAttacker = read_data(1)
    new iDmg = read_data(2)

    if (!iAttacker || iAttacker == iVictim || !is_user_connected(iAttacker) || iDmg <= 0)
        return

    if (cs_get_user_team(iAttacker) == cs_get_user_team(iVictim))
        return // friendly fire does not build assist credit

    g_iDamage[iVictim][iAttacker] += iDmg
}

public OnPlayerKilled()
{
    if (!get_pcvar_num(g_pEnabled))
        return
    if (get_cvar_num("amx_knife_round_active") == 1)
        return

    new iKiller = read_data(1)
    new iVictim = read_data(2)

    if (!iKiller || !iVictim || !is_user_connected(iKiller) || !is_user_connected(iVictim))
        return

    if (cs_get_user_team(iKiller) == cs_get_user_team(iVictim))
        return // teamkill: no assists

    // CRX handles kill/headshot XP - here we only pay assist XP
    new iBestAssist, iBestDmg = get_pcvar_num(g_pAssistMinDmg)

    for (new i = 1; i <= MaxClients; i++)
    {
        if (i == iKiller || !is_user_connected(i))
            continue

        new iDmg = g_iDamage[iVictim][i]
        if (iDmg >= iBestDmg && iDmg > g_iDamage[iVictim][iBestAssist])
        {
            iBestAssist = i
            iBestDmg = iDmg
        }
    }

    if (iBestAssist && cs_get_user_team(iBestAssist) == cs_get_user_team(iKiller))
    {
        // RANK_BOTS master switch: victim-side assist credit opens when rsu
        // core runs RANK_BOTS=1. Payees stay human (bots are never CRX-loaded).
        // empty reward keyword: CRX looks non-empty keywords up in
        // [XP Rewards] and IGNORES the amount - "assist" is not a reward
        // key, so the keyword form silently paid 0 XP (FIX-1)
        if ((!is_user_bot(iVictim) || BotCountOn()) && crxranks_is_user_loaded(iBestAssist))
            crxranks_give_user_xp(iBestAssist, get_pcvar_num(g_pAssistXP), "", CRXRANKS_XPS_PLUGIN)
    }

    // clear the victim's damage ledger
    arrayset(g_iDamage[iVictim], 0, sizeof(g_iDamage[]))
}

public bomb_planted(iPlanter)
{
    GiveTeamXP(cs_get_user_team(iPlanter), get_pcvar_num(g_pTeamPlant))
}

public bomb_defused(iDefuser)
{
    GiveTeamXP(cs_get_user_team(iDefuser), get_pcvar_num(g_pTeamDefuse))
}

public bomb_exploded(iPlanter)
{
    GiveTeamXP(CS_TEAM_T, get_pcvar_num(g_pTeamExplode))
}

public OnTeamWin()
{
    if (!get_pcvar_num(g_pEnabled))
        return

    // same pattern as CRX OnTeamWin - MRAD_terwin / MRAD_ctwin (24 chars max)
    new szAudio[24]
    read_data(2, szAudio, charsmax(szAudio))
    new CsTeams:iWinner = (contain(szAudio, "%!MRAD_terwin") != -1) ? CS_TEAM_T : CS_TEAM_CT

    GiveTeamXP(iWinner, get_pcvar_num(g_pTeamWin))

    // losers share only if configured > 0
    new iLose = get_pcvar_num(g_pTeamLose)
    if (iLose > 0)
        GiveTeamXP(iWinner == CS_TEAM_T ? CS_TEAM_CT : CS_TEAM_T, iLose)
}

// amount is passed raw (empty reward keyword); the BattlePass/VIP multiplier
// forward still applies inside CRX (crxranks_user_receive_xp)
GiveTeamXP(CsTeams:iTeam, iXP)
{
    if (!get_pcvar_num(g_pEnabled) || iXP <= 0)
        return
    if (get_cvar_num("amx_knife_round_active") == 1)
        return

    new iPlayers[MAX_PLAYERS], iPnum
    get_players(iPlayers, iPnum, "eh", iTeam == CS_TEAM_T ? "TERRORIST" : "CT")

    for (new i; i < iPnum; i++)
    {
        if (is_user_bot(iPlayers[i]))
            continue
        if (crxranks_is_user_loaded(iPlayers[i]))
            crxranks_give_user_xp(iPlayers[i], iXP, "", CRXRANKS_XPS_PLUGIN)
    }
}
