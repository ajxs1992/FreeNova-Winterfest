#include <amxmodx>
#include <amxmisc>
#include <nvault>
#include <freenova_chat>
#include <fn_common>

// FreeNova Preferences - persistent per-player settings layer.
// One vault ("freenova_prefs"), one key per player holding a compact
// pipe-separated value list. New preferences are appended at the end of
// the key string, so older saved rows keep loading (missing tail = default).

#define PLUGIN  "FreeNova Preferences"
#define VERSION "1.0"
#define AUTHOR  "FreeNova"

// Preference indexes (persisted order - NEVER reorder or reuse slots)
enum
{
    FN_PREF_RANK_HUD = 0,   // 1 = rank HUD visible (default 1)
    FN_PREF_DAMAGE_HUD,     // 1 = bullet damage numbers visible (default 1)
    FN_PREF_COMPACT_MENUS,  // 1 = short hub menu labels (default 0)
    FN_PREF_LANG,           // 0 = English (en), 1 = Romanian (ro) (default 0)
    FN_PREF_LOW_PERF,       // 1 = Low Performance Mode, skip rich MOTDs (default 0)
    // NOTE: FN_PREF_LANG currently has zero consumers beyond the /prefs
    // status display and the unused fnpref_get_lang/set_lang stocks in
    // freenova_prefs.inc. It stays persisted (append-only vault format:
    // dropping the slot would shift every saved row) so a future
    // multilingual feature can adopt it without a data migration.
    // ^ add new preferences above this line
    FN_PREF_COUNT
}

// Defaults applied when a player has no saved row (or a short legacy row)
new g_iDefaults[FN_PREF_COUNT] = { 1, 1, 0, 0, 0 }

new g_iPrefs[MAX_PLAYERS + 1][FN_PREF_COUNT]
new bool:g_bLoaded[MAX_PLAYERS + 1]
new g_iSession[MAX_PLAYERS + 1]         // putinserver counter (callback safety)
new g_iLoadTries[MAX_PLAYERS + 1]
new g_iVault = INVALID_HANDLE

new g_szAuthPending[MAX_PLAYERS + 1][40]

new g_hFwdPrefChanged = INVALID_HANDLE

public plugin_init()
{
    fn_boot_banner("prefs", 6)

    register_plugin(PLUGIN, VERSION, AUTHOR)

    g_hFwdPrefChanged = CreateMultiForward("fnpref_changed", ET_IGNORE, FP_CELL, FP_CELL, FP_CELL)

    register_clcmd("say /prefs", "Cmd_Prefs", _, "preference status")
    register_clcmd("say_team /prefs", "Cmd_Prefs")
}

public plugin_cfg()
{
    g_iVault = nvault_open("freenova_prefs")
    if (g_iVault == INVALID_HANDLE)
        log_amx("[FreeNova] Failed to open nvault 'freenova_prefs' - preferences will not persist")
}

public plugin_end()
{
    if (g_hFwdPrefChanged != INVALID_HANDLE)
        DestroyForward(g_hFwdPrefChanged)

    if (g_iVault != INVALID_HANDLE)
        nvault_close(g_iVault)
}

// ---------------------------------------------------------------- natives

public plugin_natives()
{
    register_library("freenova_prefs")
    register_native("fnpref_get", "_native_get")
    register_native("fnpref_set", "_native_set")
    register_native("fnpref_is_loaded", "_native_is_loaded")
}

public _native_get(iPlugin, iParams)
{
    new id = get_param(1)
    new iPref = get_param(2)

    if (!IsIndexValid(id) || iPref < 0 || iPref >= FN_PREF_COUNT)
        return 0

    return g_iPrefs[id][iPref]
}

public _native_set(iPlugin, iParams)
{
    new id = get_param(1)
    new iPref = get_param(2)
    new iValue = get_param(3) ? 1 : 0

    if (!IsIndexValid(id) || !g_bLoaded[id] || iPref < 0 || iPref >= FN_PREF_COUNT)
        return 0

    if (g_iPrefs[id][iPref] == iValue)
        return 1

    g_iPrefs[id][iPref] = iValue
    SavePrefs(id)

    new iReturn
    ExecuteForward(g_hFwdPrefChanged, iReturn, id, iPref, iValue)
    return 1
}

public _native_is_loaded(iPlugin, iParams)
{
    new id = get_param(1)
    return (IsIndexValid(id) && g_bLoaded[id]) ? 1 : 0
}

IsIndexValid(id)
{
    return (id >= 1 && id <= MaxClients)
}

// ---------------------------------------------------------------- lifecycle

public client_putinserver(id)
{
    remove_task(id + 47100)
    g_bLoaded[id] = false
    g_iSession[id]++
    g_iLoadTries[id] = 0
    for (new i; i < FN_PREF_COUNT; i++)
        g_iPrefs[id][i] = g_iDefaults[i]
    g_szAuthPending[id][0] = 0

    if (is_user_bot(id) || is_user_hltv(id))
        return

    get_user_authid(id, g_szAuthPending[id], charsmax(g_szAuthPending[]))
    set_task(0.5, "Task_TryLoad", id + 47100)
}

public client_disconnected(id)
{
    remove_task(id + 47100)

    if (g_bLoaded[id] && g_iVault != INVALID_HANDLE)
        SavePrefs(id)

    g_bLoaded[id] = false
    g_szAuthPending[id][0] = 0
}

// SteamID can still be pending at putinserver - retry briefly, then give up
// (BOT/HLTV have no steamid either; they simply never load preferences).
public client_infochanged(id)
{
    if (!is_user_connected(id) || g_bLoaded[id])
        return

    new szAuth[40]
    get_user_authid(id, szAuth, charsmax(szAuth))

    if (equal(szAuth, "STEAM_ID_PENDING") || !szAuth[0])
        return

    // re-check from a task so we do not load inside the infochanged hook
    remove_task(id + 47100)
    set_task(0.5, "Task_TryLoad", id + 47100)
}

public Task_TryLoad(idTask)
{
    new id = idTask - 47100
    if (!is_user_connected(id) || g_bLoaded[id])
        return

    new szAuth[40]
    get_user_authid(id, szAuth, charsmax(szAuth))

    if (equal(szAuth, "STEAM_ID_PENDING") || !szAuth[0])
    {
        if (++g_iLoadTries[id] < 10)
            set_task(0.5, "Task_TryLoad", id + 47100)
        return
    }

    if (equal(szAuth, "BOT") || equal(szAuth, "HLTV") || equal(szAuth, "STEAM_ID_LAN"))
        return

    LoadPrefs(id, szAuth)
}

LoadPrefs(id, const szAuth[])
{
    if (g_iVault == INVALID_HANDLE)
    {
        g_bLoaded[id] = true
        return
    }

    // Session safety: remember which authid we load for
    copy(g_szAuthPending[id], charsmax(g_szAuthPending[]), szAuth)

    new szKey[64]
    FormatKey(szAuth, szKey, charsmax(szKey))

    new szData[64], iTimestamp
    if (nvault_lookup(g_iVault, szKey, szData, charsmax(szData), iTimestamp))
    {
        ParsePrefs(id, szData)
    }
    else
    {
        for (new i; i < FN_PREF_COUNT; i++)
            g_iPrefs[id][i] = g_iDefaults[i]
    }

    g_bLoaded[id] = true
}

ParsePrefs(id, const szData[])
{
    // format: "1|1|0|0|0" (one number per FN_PREF slot, pipe separated; FN_PREF_LANG: 0 = en, 1 = ro)
    new szCopy[64]
    copy(szCopy, charsmax(szCopy), szData)

    new iSlot
    new szToken[8]

    new iPos, iNext
    while (iSlot < FN_PREF_COUNT)
    {
        iNext = find_char(szCopy[iPos], '|')
        if (iNext >= 0)
        {
            copy(szToken, charsmax(szToken), szCopy[iPos])
            szToken[iNext] = 0
            iPos += iNext + 1
        }
        else
        {
            copy(szToken, charsmax(szToken), szCopy[iPos])
        }

        trim(szToken)
        g_iPrefs[id][iSlot] = str_to_num(szToken) ? 1 : 0
        iSlot++

        if (iNext < 0)
            break
    }

    // any slot beyond the saved string keeps its default (already applied)
}

find_char(const szStr[], const cChar)
{
    new iLen = strlen(szStr)
    for (new i; i < iLen; i++)
        if (szStr[i] == cChar)
            return i
    return -1
}

SavePrefs(id)
{
    if (g_iVault == INVALID_HANDLE)
        return

    new szAuth[40]
    get_user_authid(id, szAuth, charsmax(szAuth))

    // Callback safety: only save the identity we actually loaded
    if (!szAuth[0] || !equal(szAuth, g_szAuthPending[id]))
        return

    // Vault row buffer: 5 slots today ("1|1|0|0|0" = 9 chars); sized 64 to
    // match the load path and leave headroom for future appended slots.
    new szKey[64], szData[64], szChunk[8]
    FormatKey(szAuth, szKey, charsmax(szKey))

    for (new i; i < FN_PREF_COUNT; i++)
    {
        formatex(szChunk, charsmax(szChunk), "%s%d", i ? "|" : "", g_iPrefs[id][i])
        add(szData, charsmax(szData), szChunk)
    }

    nvault_set(g_iVault, szKey, szData)
}

FormatKey(const szAuth[], szKey[], iLen)
{
    new szTemp[40]
    copy(szTemp, charsmax(szTemp), szAuth)
    replace_all(szTemp, charsmax(szTemp), ":", "_")
    formatex(szKey, iLen, "pref#%s", szTemp)
}

// ---------------------------------------------------------------- status cmd

public Cmd_Prefs(id)
{
    fn_chat_info(id, "Rank HUD: %s | Damage HUD: %s | Compact menus: %s | Low perf: %s | Language: %s",
        g_iPrefs[id][FN_PREF_RANK_HUD] ? "ON" : "OFF",
        g_iPrefs[id][FN_PREF_DAMAGE_HUD] ? "ON" : "OFF",
        g_iPrefs[id][FN_PREF_COMPACT_MENUS] ? "ON" : "OFF",
        g_iPrefs[id][FN_PREF_LOW_PERF] ? "ON" : "OFF",
        g_iPrefs[id][FN_PREF_LANG] ? "ro" : "en")
    return PLUGIN_HANDLED
}
