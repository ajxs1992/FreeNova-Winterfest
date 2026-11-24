#include <amxmodx>
#include <cstrike>
#include <nvault>
#include <crxranks>
#include <menabp>
#include <rsu>
#include <fn_common>

#define PLUGIN  "FreeNova Clutch Tracker"
#define VERSION "1.0"
#define AUTHOR  "FreeNova Dev"

#define MAX_PLAYERS 32
#define CLUTCH_TIERS 6 // 1v1 to 1v5 (index 1..5)
#define TASK_LATELOAD 46200

new g_iClutchWon[MAX_PLAYERS + 1][CLUTCH_TIERS]
new g_iClutchAtt[MAX_PLAYERS + 1][CLUTCH_TIERS]
new bool:g_bLoaded[MAX_PLAYERS + 1]
new g_szAuth[MAX_PLAYERS + 1][35]
new g_iLateTries[MAX_PLAYERS + 1]

new g_iActiveClutcher
new g_iActiveTier
new CsTeams:g_iClutcherTeam
new bool:g_bRoundEnded
new g_VaultClutch = INVALID_HANDLE
new g_iClutchPending[MAX_PLAYERS + 1]

public plugin_init()
{
    fn_boot_banner("clutch", 10)

    register_plugin(PLUGIN, VERSION, AUTHOR)

    register_event("HLTV", "Event_RoundStart", "a", "1=0", "2=0")
    register_event("DeathMsg", "Event_DeathMsg", "a")
    register_event("SendAudio", "Event_TerroristWin", "a", "2=%!MRAD_terwin")
    register_event("SendAudio", "Event_CtWin", "a", "2=%!MRAD_ctwin")

    register_clcmd("say /clutch", "Cmd_Clutch")
    register_clcmd("say_team /clutch", "Cmd_Clutch")

    g_VaultClutch = nvault_open("freenova_clutch")
    if(g_VaultClutch == INVALID_HANDLE)
        log_amx("[FreeNova Clutch] Warning: Unable to open nvault 'freenova_clutch'")
}

public plugin_end()
{
    if(g_VaultClutch != INVALID_HANDLE)
        nvault_close(g_VaultClutch)
}

public plugin_natives()
{
    register_library("freenova_clutch")
    register_native("fnclutch_get_won", "native_get_won")
    register_native("fnclutch_get_att", "native_get_att")
    register_native("fnclutch_get_total_won", "native_get_total_won")
    register_native("fnclutch_get_total_att", "native_get_total_att")
}

public native_get_won(plugin, params)
{
    new id = get_param(1)
    new tier = get_param(2)
    if(!(1 <= id <= MAX_PLAYERS) || tier < 1 || tier >= CLUTCH_TIERS)
        return 0
    return g_iClutchWon[id][tier]
}

public native_get_att(plugin, params)
{
    new id = get_param(1)
    new tier = get_param(2)
    if(!(1 <= id <= MAX_PLAYERS) || tier < 1 || tier >= CLUTCH_TIERS)
        return 0
    return g_iClutchAtt[id][tier]
}

public native_get_total_won(plugin, params)
{
    new id = get_param(1)
    if(!(1 <= id <= MAX_PLAYERS)) return 0
    new total = 0
    for(new i = 1; i < CLUTCH_TIERS; i++)
        total += g_iClutchWon[id][i]
    return total
}

public native_get_total_att(plugin, params)
{
    new id = get_param(1)
    if(!(1 <= id <= MAX_PLAYERS)) return 0
    new total = 0
    for(new i = 1; i < CLUTCH_TIERS; i++)
        total += g_iClutchAtt[id][i]
    return total
}

public client_putinserver(id)
{
    remove_task(id + TASK_LATELOAD)
    g_szAuth[id][0] = 0
    for(new i = 0; i < CLUTCH_TIERS; i++)
    {
        g_iClutchWon[id][i] = 0
        g_iClutchAtt[id][i] = 0
    }
    g_bLoaded[id] = false
    g_iClutchPending[id] = 0
    g_iLateTries[id] = 0
    // Authid is frequently STEAM_ID_PENDING at putinserver; defer so each
    // player gets their own row instead of pooling into one shared key.
    set_task(3.0, "Task_LateLoad", id + TASK_LATELOAD)
}

public Task_LateLoad(taskid)
{
    new id = taskid - TASK_LATELOAD
    if(!is_user_connected(id) || is_user_bot(id))
        return

    new szAuth[40]
    get_user_authid(id, szAuth, charsmax(szAuth))
    if(!szAuth[0] || equal(szAuth, "STEAM_ID_PENDING") || equal(szAuth, "STEAM_ID_LAN"))
    {
        // Give up after 3 extra tries rather than saving under a shared pending key.
        if(g_iLateTries[id] < 3)
        {
            g_iLateTries[id]++
            set_task(3.0, "Task_LateLoad", id + TASK_LATELOAD)
        }
        return
    }

    copy(g_szAuth[id], charsmax(g_szAuth[]), szAuth)
    LoadClutchData(id)
}

public client_disconnected(id)
{
    remove_task(id + TASK_LATELOAD)
    if(g_bLoaded[id])
        SaveClutchData(id)
    g_bLoaded[id] = false
}

public Event_RoundStart()
{
    g_iActiveClutcher = 0
    g_iActiveTier = 0
    g_iClutcherTeam = CS_TEAM_UNASSIGNED
    g_bRoundEnded = false
}

// RANK_BOTS master switch reader: true only when rsu_core runs RANK_BOTS=1.
// Clutcher candidates stay human; bot teammates count as mates when on.
stock bool:BotCountOn()
{
    return LibraryExists("rsu_core", LibType_Library) && rsu_bots_count();
}

public Event_DeathMsg()
{
    if(g_bRoundEnded)
        return
    if(get_cvar_num("amx_knife_round_active") == 1)
        return
    new players[32], pnum
    get_players(players, pnum, "ch")
    if(pnum < 6)
        return

    new aliveT[32], countT = 0
    new aliveCT[32], countCT = 0

    for(new i = 1; i <= MAX_PLAYERS; i++)
    {
        if(!is_user_alive(i))
            continue
        // Bots neither form nor win clutches - no attempts, no rewards.
        // With RANK_BOTS=1 they still count as OPPONENTS for tier sizing
        // (counted below, never stored in the candidate arrays).
        if(is_user_bot(i))
        {
            if(BotCountOn())
            {
                if(cs_get_user_team(i) == CS_TEAM_T)
                    countT++
                else if(cs_get_user_team(i) == CS_TEAM_CT)
                    countCT++
            }
            continue
        }

        new CsTeams:team = cs_get_user_team(i)
        if(team == CS_TEAM_T)
            aliveT[countT++] = i
        else if(team == CS_TEAM_CT)
            aliveCT[countCT++] = i
    }

    // 1v1 is a duel, not a clutch. Start at 1v2.
    if(countT == 1 && (2 <= countCT <= 5) && g_iActiveClutcher == 0)
    {
        new clutcher = aliveT[0]
        g_iActiveClutcher = clutcher
        g_iActiveTier = countCT
        g_iClutcherTeam = CS_TEAM_T
        g_iClutchAtt[clutcher][countCT]++
        SaveClutchData(clutcher)
    }
    else if(countCT == 1 && (2 <= countT <= 5) && g_iActiveClutcher == 0)
    {
        new clutcher = aliveCT[0]
        g_iActiveClutcher = clutcher
        g_iActiveTier = countT
        g_iClutcherTeam = CS_TEAM_CT
        g_iClutchAtt[clutcher][countT]++
        SaveClutchData(clutcher)
    }
}

public Event_TerroristWin()
{
    HandleRoundEnd(CS_TEAM_T)
}

public Event_CtWin()
{
    HandleRoundEnd(CS_TEAM_CT)
}

HandleRoundEnd(CsTeams:winningTeam)
{
    if(g_bRoundEnded)
        return
    g_bRoundEnded = true

    // Flush parked clutch coins every round end (cheap; no-ops when empty).
    for (new i = 1; i <= MAX_PLAYERS; i++)
        FlushClutchPending(i)

    if(g_iActiveClutcher > 0 && is_user_connected(g_iActiveClutcher))
    {
        // Revive can bring a teammate back after the 1vX lock - re-verify solo.
        new aliveMates = 0
        for(new i = 1; i <= MAX_PLAYERS; i++)
        {
            if(i == g_iActiveClutcher || !is_user_alive(i) || (is_user_bot(i) && !BotCountOn()))
                continue
            if(cs_get_user_team(i) == g_iClutcherTeam)
                aliveMates++
        }
        if(aliveMates == 0 && g_iClutcherTeam == winningTeam && is_user_alive(g_iActiveClutcher))
        {
            new tier = g_iActiveTier
            if(2 <= tier <= 5)
            {
                g_iClutchWon[g_iActiveClutcher][tier]++
                SaveClutchData(g_iActiveClutcher)

                new szName[32]
                get_user_name(g_iActiveClutcher, szName, charsmax(szName))

                new xpBonus = 0, coinBonus = 0
                switch(tier)
                {
                    case 2: { xpBonus = 300; coinBonus = 50; }
                    case 3: { xpBonus = 600; coinBonus = 100; }
                    case 4: { xpBonus = 1200; coinBonus = 200; }
                    case 5: { xpBonus = 3000; coinBonus = 500; }
                }

                if(LibraryExists("crxranks", LibType_Library))
                    crxranks_give_user_xp(g_iActiveClutcher, xpBonus)

                // menabp_add_coins returns the new balance (0 = fail-closed
                // while BP data loads): never announce coins that did not land.
                // Unpaid coins park in the vault and flush on later rounds.
                new bool:bCoinsPaid = false
                if(LibraryExists("menabp", LibType_Library))
                    bCoinsPaid = (menabp_add_coins(g_iActiveClutcher, coinBonus) > 0)
                if (!bCoinsPaid)
                {
                    new cid = g_iActiveClutcher
                    g_iClutchPending[cid] += coinBonus
                    // Two buffers: format() writes into its destination while it
                    // consumes the format string, so format(buf, n, "...%s", buf)
                    // loses the authid and every player collides on one vault row.
                    new szPId[48], szPKey[64]
                    ClutchKey(cid, szPId, charsmax(szPId))
                    format(szPKey, charsmax(szPKey), "clutchpend#%s", szPId)
                    if (g_VaultClutch != INVALID_HANDLE)
                    {
                        new szPAmt[16]
                        formatex(szPAmt, charsmax(szPAmt), "%d", g_iClutchPending[cid])
                        nvault_set(g_VaultClutch, szPKey, szPAmt)
                    }
                    log_amx("[FreeNova Clutch] Parked %d unpaid coins (wallet not ready)", coinBonus)
                }

                if (bCoinsPaid)
                    client_print(0, print_chat, "^4[FreeNova Clutch]^1 %s WON THE 1v%d CLUTCH! (+%d XP, +%d Coins)", szName, tier, xpBonus, coinBonus)
                else
                    client_print(0, print_chat, "^4[FreeNova Clutch]^1 %s WON THE 1v%d CLUTCH! (+%d XP, coins pending)", szName, tier, xpBonus)
            }
        }
    }

    g_iActiveClutcher = 0
    g_iActiveTier = 0
}

// Tier layout: index 0 is unused padding (natives accept 1..5 only) and
// index 1 (the 1v1 "tier") is always zero - 1v1 is a duel, not a clutch,
// and tracking starts at 1v2. Both zero slots are still serialized because
// the vault row is positional ("W1 W2 W3 W4 W5|A1..A5"): dropping a slot
// would shift every existing row on load. Keep the format, keep the zeros.
LoadClutchData(id)
{
    if(g_VaultClutch == INVALID_HANDLE || !g_szAuth[id][0] || equal(g_szAuth[id], "BOT"))
        return

    MigrateClutchKey(id)

    new szKey[48]
    ClutchKey(id, szKey, charsmax(szKey))
    new szVal[128]
    if(nvault_get(g_VaultClutch, szKey, szVal, charsmax(szVal)))
    {
        new szWon[64], szAtt[64]
        strtok(szVal, szWon, charsmax(szWon), szAtt, charsmax(szAtt), '|')

        new p[8], left[64]
        copy(left, charsmax(left), szWon)
        for(new i = 1; i <= 5; i++)
        {
            if(!left[0]) break
            strtok(left, p, charsmax(p), left, charsmax(left), ' ')
            g_iClutchWon[id][i] = str_to_num(p)
        }

        copy(left, charsmax(left), szAtt)
        for(new i = 1; i <= 5; i++)
        {
            if(!left[0]) break
            strtok(left, p, charsmax(p), left, charsmax(left), ' ')
            g_iClutchAtt[id][i] = str_to_num(p)
        }
    }

    // Pending clutch coins survive disconnects in the vault; pick them up.
    new szPendId[48], szPendKey[64], szPend[16]
    ClutchKey(id, szPendId, charsmax(szPendId))
    format(szPendKey, charsmax(szPendKey), "clutchpend#%s", szPendId)
    if (nvault_get(g_VaultClutch, szPendKey, szPend, charsmax(szPend)))
        g_iClutchPending[id] = str_to_num(szPend)
    g_bLoaded[id] = true
}

// Vault keys use sanitized auth (`:` -> `_`), matching every other
// FreeNova plugin. Legacy rows were written under the raw authid; the
// migration below moves them once, preserving the positional data.
ClutchKey(id, szOut[], iLen)
{
    copy(szOut, iLen, g_szAuth[id])
    for (new i = 0; szOut[i]; i++)
    {
        if (szOut[i] == ':')
            szOut[i] = '_'
    }
}

MigrateClutchKey(id)
{
    if (g_VaultClutch == INVALID_HANDLE || !g_szAuth[id][0])
        return
    new szNew[48], szOld[48]
    ClutchKey(id, szNew, charsmax(szNew))
    copy(szOld, charsmax(szOld), g_szAuth[id])
    if (equal(szNew, szOld))
        return
    new szVal[128]
    if (nvault_get(g_VaultClutch, szOld, szVal, charsmax(szVal)))
    {
        nvault_set(g_VaultClutch, szNew, szVal)
        nvault_remove(g_VaultClutch, szOld)
        log_amx("[FreeNova Clutch] Migrated vault row to sanitized key")
    }
}

// Retry unpaid clutch coins (parked when the BP wallet was not ready).
// Fail-closed: leaves the amount parked unless the deposit lands.
FlushClutchPending(id)
{
    if (g_iClutchPending[id] <= 0 || !is_user_connected(id))
        return
    if (!LibraryExists("menabp", LibType_Library) || !menabp_is_ready(id))
        return
    if (menabp_add_coins(id, g_iClutchPending[id]) > 0)
    {
        log_amx("[FreeNova Clutch] Flushed %d pending coins", g_iClutchPending[id])
        g_iClutchPending[id] = 0
        new szId[48], szKey[64]
        ClutchKey(id, szId, charsmax(szId))
        format(szKey, charsmax(szKey), "clutchpend#%s", szId)
        if (g_VaultClutch != INVALID_HANDLE)
            nvault_set(g_VaultClutch, szKey, "0")
    }
}

SaveClutchData(id)
{
    if(g_VaultClutch == INVALID_HANDLE || !g_szAuth[id][0] || equal(g_szAuth[id], "BOT"))
        return

    new szKey[48]
    ClutchKey(id, szKey, charsmax(szKey))
    new szVal[128]
    formatex(szVal, charsmax(szVal), "%d %d %d %d %d|%d %d %d %d %d",
        g_iClutchWon[id][1], g_iClutchWon[id][2], g_iClutchWon[id][3], g_iClutchWon[id][4], g_iClutchWon[id][5],
        g_iClutchAtt[id][1], g_iClutchAtt[id][2], g_iClutchAtt[id][3], g_iClutchAtt[id][4], g_iClutchAtt[id][5])

    nvault_set(g_VaultClutch, szKey, szVal)
}

public Cmd_Clutch(id)
{
    if(!is_user_connected(id))
        return PLUGIN_HANDLED

    new iWon = 0, iAtt = 0
    for(new i = 2; i < CLUTCH_TIERS; i++)
    {
        iWon += g_iClutchWon[id][i]
        iAtt += g_iClutchAtt[id][i]
    }

    client_print(id, print_chat,
        "^4[FreeNova Clutch]^1 Wins %d / Attempts %d  (1v2+)", iWon, iAtt)
    for(new t = 2; t <= 5; t++)
    {
        client_print(id, print_chat,
            "^4[FreeNova Clutch]^1 1v%d: %d won / %d attempts",
            t, g_iClutchWon[id][t], g_iClutchAtt[id][t])
    }
    return PLUGIN_HANDLED
}
