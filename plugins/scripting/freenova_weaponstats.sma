#include <amxmodx>
#include <amxmisc>
#include <nvault>
#include <cstrike>
#include <csx>
#include <menabp>
#include <fn_common>

// FreeNova Weapon Stats - persistent per-weapon kill/headshot/damage records.
//
// Data sources (master prompt section 18 - accuracy rules):
//   - kills/headshots: csx client_death (attacker, victim, weapon, hitplace, TK)
//     -> suicides, world deaths and TKs do NOT count; victim must be a real
//        connected player; attacker must differ from victim.
//   - damage: csx client_damage (attacker != victim, alive check on attacker
//        when known; friendly fire excluded).
// Storage: one nVault ("freenova_wpn"), one key per steamid holding a packed
// CSV of the tracked weapons, loaded once per session and written on
// disconnect + periodic autosave. Bots are excluded (shared vault key issue).

#define PLUGIN  "FreeNova Weapon Stats"
#define VERSION "1.0"
#define AUTHOR  "FreeNova"

// Tracked weapons - order matters (vault CSV layout; append-only)
enum
{
    WPN_AK47 = 0,
    WPN_M4A1,
    WPN_AWP,
    WPN_DEAGLE,
    WPN_KNIFE,
    WPN_USP,
    WPN_GLOCK18,
    WPN_FAMAS,
    WPN_GALIL,
    WPN_SCOUT,
    WPN_AUG,
    WPN_SG552,
    WPN_MP5NAVY,
    WPN_P90,
    WPN_UMP45,
    WPN_MAC10,
    WPN_TMP,
    WPN_M249,
    WPN_M3,
    WPN_XM1014,
    WPN_SG550,
    WPN_G3SG1,
    WPN_HEGRENADE,
    WPN_COUNT
}

new const g_szWeaponNames[WPN_COUNT][] =
{
    "AK-47", "M4A1", "AWP", "Deagle", "Knife", "USP", "Glock-18",
    "FAMAS", "Galil", "Scout", "AUG", "SG552", "MP5", "P90",
    "UMP-45", "MAC-10", "TMP", "M249", "M3", "XM1014", "SG550",
    "G3SG1", "HE Grenade"
}

// csx weapon indexes -> our slots (CSW_* constants from cstrike_const)
new g_iCswToSlot[CSW_P90 + 1]

new g_iKills[MAX_PLAYERS + 1][WPN_COUNT]
new g_iHeadshots[MAX_PLAYERS + 1][WPN_COUNT]
new g_iDamage[MAX_PLAYERS + 1][WPN_COUNT]
new g_iMasteryPaid[MAX_PLAYERS + 1][WPN_COUNT]
new g_iBestWeapon[MAX_PLAYERS + 1]      // cached favorite weapon slot
new bool:g_bLoaded[MAX_PLAYERS + 1]

// Must stay in lockstep with web-panel WEAPON_MASTERY_THRESHOLDS.
new const g_iMasteryNeed[] = { 0, 50, 150, 300, 500, 750, 1100, 1500, 2000, 2600, 3300, 4100, 5000, 6000, 7200, 8500, 10000 }
new g_szAuth[MAX_PLAYERS + 1][40]
new g_iVault = INVALID_HANDLE

new const TASK_AUTOSAVE = 45200
new const TASK_LATELOAD = 45600
new g_iLateTries[MAX_PLAYERS + 1]

public plugin_init()
{
    fn_boot_banner("weaponstats", 5)

    register_plugin(PLUGIN, VERSION, AUTHOR)

    BuildWeaponMap()

    g_iVault = nvault_open("freenova_wpn")
    if (g_iVault == INVALID_HANDLE)
        log_amx("[FreeNova] Failed to open nvault 'freenova_wpn' - weapon stats will not persist")

    set_task(120.0, "Task_AutoSave", TASK_AUTOSAVE, "", 0, "b")
}

public plugin_end()
{
    remove_task(TASK_AUTOSAVE)
    new iPlayers[MAX_PLAYERS], iNum
    get_players(iPlayers, iNum, "ch")
    for (new i; i < iNum; i++)
        if (g_bLoaded[iPlayers[i]])
            SaveStats(iPlayers[i])
    if (g_iVault != INVALID_HANDLE)
        nvault_close(g_iVault)
}

BuildWeaponMap()
{
    // default: every engine weapon id maps to "not tracked"
    for (new i; i <= CSW_P90; i++)
        g_iCswToSlot[i] = -1

    g_iCswToSlot[CSW_SCOUT]       = WPN_SCOUT
    g_iCswToSlot[CSW_XM1014]      = WPN_XM1014
    g_iCswToSlot[CSW_MAC10]       = WPN_MAC10
    g_iCswToSlot[CSW_AUG]         = WPN_AUG
    g_iCswToSlot[CSW_ELITE]       = -1
    g_iCswToSlot[CSW_FIVESEVEN]   = -1
    g_iCswToSlot[CSW_UMP45]       = WPN_UMP45
    g_iCswToSlot[CSW_SG550]       = WPN_SG550
    g_iCswToSlot[CSW_GALIL]       = WPN_GALIL
    g_iCswToSlot[CSW_FAMAS]       = WPN_FAMAS
    g_iCswToSlot[CSW_USP]         = WPN_USP
    g_iCswToSlot[CSW_GLOCK18]     = WPN_GLOCK18
    g_iCswToSlot[CSW_AWP]         = WPN_AWP
    g_iCswToSlot[CSW_MP5NAVY]     = WPN_MP5NAVY
    g_iCswToSlot[CSW_M249]        = WPN_M249
    g_iCswToSlot[CSW_M4A1]        = WPN_M4A1
    g_iCswToSlot[CSW_TMP]         = WPN_TMP
    g_iCswToSlot[CSW_G3SG1]       = WPN_G3SG1
    g_iCswToSlot[CSW_DEAGLE]      = WPN_DEAGLE
    g_iCswToSlot[CSW_SG552]       = WPN_SG552
    g_iCswToSlot[CSW_AK47]        = WPN_AK47
    g_iCswToSlot[CSW_P90]         = WPN_P90
    // knife + grenades are handled directly in the death handler; C4,
    // flashbang and smoke fall through to the -1 default above
}

// ---------------------------------------------------------------- natives

public plugin_natives()
{
    register_library("freenova_wpn")
    register_native("fnwps_get_kills", "_native_kills")
    register_native("fnwps_get_headshots", "_native_hs")
    register_native("fnwps_get_damage", "_native_dmg")
    register_native("fnwps_get_best_weapon", "_native_best")
    register_native("fnwps_get_weapon_name", "_native_name")
    set_native_filter("WpnNativeFilter")
}

public WpnNativeFilter(const name[], index, trap)
{
    if (equal(name, "menabp_add_coins"))
        return PLUGIN_HANDLED
    return PLUGIN_CONTINUE
}

public _native_kills(iPlugin, iParams)
{
    new id = get_param(1)
    new iSlot = get_param(2)
    return ValidSlot(id, iSlot) ? g_iKills[id][iSlot] : 0
}

public _native_hs(iPlugin, iParams)
{
    new id = get_param(1)
    new iSlot = get_param(2)
    return ValidSlot(id, iSlot) ? g_iHeadshots[id][iSlot] : 0
}

public _native_dmg(iPlugin, iParams)
{
    new id = get_param(1)
    new iSlot = get_param(2)
    return ValidSlot(id, iSlot) ? g_iDamage[id][iSlot] : 0
}

public _native_best(iPlugin, iParams)
{
    new id = get_param(1)
    if (!IsConnected(id) || !g_bLoaded[id])
        return -1
    return g_iBestWeapon[id]
}

public _native_name(iPlugin, iParams)
{
    new iSlot = get_param(1)
    if (iSlot < 0 || iSlot >= WPN_COUNT)
    {
        set_string(2, "", 0)
        return 0
    }
    set_string(2, g_szWeaponNames[iSlot], get_param(3))
    return 1
}

ValidSlot(id, iSlot)
{
    return (IsConnected(id) && g_bLoaded[id] && 0 <= iSlot < WPN_COUNT)
}

IsConnected(id)
{
    return (1 <= id <= MaxClients && is_user_connected(id))
}

// ---------------------------------------------------------------- lifecycle

public client_putinserver(id)
{
    g_bLoaded[id] = false
    g_iLateTries[id] = 0
    arrayset(g_iKills[id], 0, sizeof(g_iKills[]))
    arrayset(g_iHeadshots[id], 0, sizeof(g_iHeadshots[]))
    arrayset(g_iDamage[id], 0, sizeof(g_iDamage[]))
    arrayset(g_iMasteryPaid[id], 0, sizeof(g_iMasteryPaid[]))
    g_iBestWeapon[id] = -1

    // bots share one vault identity - never load/save them
    if (is_user_bot(id))
        return

    get_user_authid(id, g_szAuth[id], charsmax(g_szAuth[]))
    LoadStats(id)
    remove_task(id + TASK_LATELOAD)
    if (!g_bLoaded[id])
        set_task(3.0, "Task_LateLoadStats", id + TASK_LATELOAD)
}

public Task_LateLoadStats(taskid)
{
    new id = taskid - TASK_LATELOAD
    if (!is_user_connected(id) || is_user_bot(id) || g_bLoaded[id])
        return

    get_user_authid(id, g_szAuth[id], charsmax(g_szAuth[]))
    LoadStats(id)
    if (!g_bLoaded[id] && g_iLateTries[id] < 3)
    {
        g_iLateTries[id]++
        set_task(3.0, "Task_LateLoadStats", id + TASK_LATELOAD)
    }
}

public client_authorized(id)
{
    if (!is_user_connected(id) || is_user_bot(id) || g_bLoaded[id])
        return
    get_user_authid(id, g_szAuth[id], charsmax(g_szAuth[]))
    LoadStats(id)
}

public client_disconnected(id)
{
    remove_task(id + TASK_LATELOAD)
    if (g_bLoaded[id])
        SaveStats(id)

    g_bLoaded[id] = false
    g_szAuth[id][0] = 0
}

public Task_AutoSave()
{
    new iPlayers[MAX_PLAYERS], iNum
    get_players(iPlayers, iNum, "ch")
    for (new i; i < iNum; i++)
        if (g_bLoaded[iPlayers[i]])
            SaveStats(iPlayers[i])
}

// ---------------------------------------------------------------- events

// Ranked kills come from rsu_core's fn_on_player_kill (warmup/bots/TK already filtered).
public fn_on_player_kill(iAttacker, iVictim, iWeapon, iHeadshot, iTK)
{
    #pragma unused iVictim, iTK
    if (!IsConnected(iAttacker) || !g_bLoaded[iAttacker])
        return

    new iSlot = WeaponToSlot(iWeapon)
    if (iSlot < 0)
        return

    g_iKills[iAttacker][iSlot]++
    if (iHeadshot)
        g_iHeadshots[iAttacker][iSlot]++

    if (g_iBestWeapon[iAttacker] < 0 || g_iKills[iAttacker][iSlot] > g_iKills[iAttacker][g_iBestWeapon[iAttacker]])
        g_iBestWeapon[iAttacker] = iSlot

    ApplyMasteryRewards(iAttacker, iSlot)
}

MasteryLevel(iKills)
{
    new iLvl = 1
    for (new i = 0; i < sizeof(g_iMasteryNeed); i++)
    {
        if (iKills >= g_iMasteryNeed[i])
            iLvl = i + 1
        else
            break
    }
    return iLvl
}

MasteryCoinReward(iLevel)
{
    // Configurable-shaped curve: coins at 5/10/20/30/40/50-equivalent tiers.
    switch (iLevel)
    {
        case 5:  return 100
        case 8:  return 250
        case 10: return 500
        case 13: return 750
        case 16: return 1500
        case 17: return 3000
    }
    return 0
}

ApplyMasteryRewards(id, iSlot)
{
    new iLvl = MasteryLevel(g_iKills[id][iSlot])
    if (iLvl <= g_iMasteryPaid[id][iSlot])
        return

    for (new l = g_iMasteryPaid[id][iSlot] + 1; l <= iLvl; l++)
    {
        new iCoins = MasteryCoinReward(l)
        if (iCoins > 0 && LibraryExists("menabp", LibType_Library))
        {
            menabp_add_coins(id, iCoins)
            client_print_color(id, print_team_default,
                "^4[FreeNova Mastery]^1 %s reached mastery ^3%d^1 (+%d coins).",
                g_szWeaponNames[iSlot], l, iCoins)
        }
    }
    g_iMasteryPaid[id][iSlot] = iLvl
    SaveMasteryPaid(id)
}

public client_damage(iAttacker, iVictim, iDamage, iWeapon, iHitplace, iTa)
{
    if (!IsConnected(iAttacker) || !IsConnected(iVictim))
        return
    if (iAttacker == iVictim)
        return
    if (get_user_team(iAttacker) == get_user_team(iVictim))
        return     // friendly fire excluded from damage records
    if (is_user_bot(iAttacker))
        return

    new iSlot = WeaponToSlot(iWeapon)
    if (iSlot < 0)
        return

    g_iDamage[iAttacker][iSlot] += iDamage
}

WeaponToSlot(iWeapon)
{
    if (iWeapon == CSW_KNIFE)
        return WPN_KNIFE
    if (iWeapon == CSW_HEGRENADE)
        return WPN_HEGRENADE
    if (iWeapon < 0 || iWeapon > CSW_P90)
        return -1
    return g_iCswToSlot[iWeapon]
}

// ---------------------------------------------------------------- storage

LoadStats(id)
{
    if (g_iVault == INVALID_HANDLE)
        return

    if (equal(g_szAuth[id], "STEAM_ID_PENDING") || equal(g_szAuth[id], "STEAM_ID_LAN") || !g_szAuth[id][0])
        return

    new szKey[48], szData[1024], iTimestamp
    VaultKey(g_szAuth[id], szKey, charsmax(szKey))

    if (!nvault_lookup(g_iVault, szKey, szData, charsmax(szData), iTimestamp))
    {
        g_bLoaded[id] = true
        return
    }

    // CSV: k1,h1,d1,k2,h2,d2,...
    new szCopy[1024]
    copy(szCopy, charsmax(szCopy), szData)

    new iPos, iField
    new szToken[16]
    new iValues[WPN_COUNT][3]

    while (iField < WPN_COUNT * 3 && iPos >= 0)
    {
        new iNext = FindComma(szCopy[iPos])
        if (iNext >= 0)
        {
            copy(szToken, charsmax(szToken), szCopy[iPos])
            szToken[iNext] = 0
            iPos += iNext + 1
        }
        else
        {
            copy(szToken, charsmax(szToken), szCopy[iPos])
            iPos = -1
        }

        iValues[iField / 3][iField % 3] = str_to_num(szToken)
        iField++
    }

    for (new i; i < WPN_COUNT; i++)
    {
        g_iKills[id][i]      = iValues[i][0]
        g_iHeadshots[id][i]  = iValues[i][1]
        g_iDamage[id][i]     = iValues[i][2]
    }

    RecalcBest(id)
    LoadMasteryPaid(id)
    g_bLoaded[id] = true
}

SaveStats(id)
{
    if (g_iVault == INVALID_HANDLE)
        return

    if (equal(g_szAuth[id], "STEAM_ID_PENDING") || equal(g_szAuth[id], "STEAM_ID_LAN") || !g_szAuth[id][0])
        return

    new szKey[48], szData[1024]
    VaultKey(g_szAuth[id], szKey, charsmax(szKey))

    new iLen
    for (new i; i < WPN_COUNT; i++)
        iLen += formatex(szData[iLen], charsmax(szData) - iLen, "%s%d,%d,%d",
            i ? "," : "", g_iKills[id][i], g_iHeadshots[id][i], g_iDamage[id][i])

    nvault_set(g_iVault, szKey, szData)
}

VaultKey(const szAuth[], szKey[], iLen)
{
    new szTemp[40]
    copy(szTemp, charsmax(szTemp), szAuth)
    replace_all(szTemp, charsmax(szTemp), ":", "_")
    formatex(szKey, iLen, "wpn#%s", szTemp)
}

RecalcBest(id)
{
    g_iBestWeapon[id] = -1
    for (new i; i < WPN_COUNT; i++)
        if (g_iBestWeapon[id] < 0 || g_iKills[id][i] > g_iKills[id][g_iBestWeapon[id]])
            g_iBestWeapon[id] = i
}

LoadMasteryPaid(id)
{
    if (g_iVault == INVALID_HANDLE)
        return

    new szKey[56], szData[256], iTimestamp
    formatex(szKey, charsmax(szKey), "mst#%s", g_szAuth[id])
    replace_all(szKey, charsmax(szKey), ":", "_")

    if (!nvault_lookup(g_iVault, szKey, szData, charsmax(szData), iTimestamp))
    {
        // Existing veterans: mark current mastery as already paid so
        // reconnecting does not dump coins for historic kills.
        for (new i; i < WPN_COUNT; i++)
            g_iMasteryPaid[id][i] = MasteryLevel(g_iKills[id][i])
        SaveMasteryPaid(id)
        return
    }

    new iPos, iField, szToken[8]
    while (iField < WPN_COUNT && iPos >= 0)
    {
        new iNext = FindComma(szData[iPos])
        if (iNext >= 0)
        {
            copy(szToken, charsmax(szToken), szData[iPos])
            szToken[iNext] = 0
            iPos += iNext + 1
        }
        else
        {
            copy(szToken, charsmax(szToken), szData[iPos])
            iPos = -1
        }
        g_iMasteryPaid[id][iField] = str_to_num(szToken)
        iField++
    }
}

SaveMasteryPaid(id)
{
    if (g_iVault == INVALID_HANDLE || equal(g_szAuth[id], "STEAM_ID_PENDING") || equal(g_szAuth[id], "STEAM_ID_LAN") || !g_szAuth[id][0])
        return

    new szKey[56], szData[256], iLen
    formatex(szKey, charsmax(szKey), "mst#%s", g_szAuth[id])
    replace_all(szKey, charsmax(szKey), ":", "_")
    for (new i; i < WPN_COUNT; i++)
        iLen += formatex(szData[iLen], charsmax(szData) - iLen, "%s%d", i ? "," : "", g_iMasteryPaid[id][i])
    nvault_set(g_iVault, szKey, szData)
}

FindComma(const szStr[])
{
    new iLen = strlen(szStr)
    for (new i; i < iLen; i++)
        if (szStr[i] == ',')
            return i
    return -1
}
