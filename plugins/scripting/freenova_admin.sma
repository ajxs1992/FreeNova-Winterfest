/* ============================================================================
 * FreeNova Admin Grants v3  (freenova_admin)
 * ============================================================================
 * Unified expiring admin grants (M13 Wave C admin system plugin).
 *
 * OWNERSHIP / NON-GOALS (do not move these lines without an owner ruling):
 *   - Persistent store is OUR OWN nVault "freenova_admin". NEVER opens,
 *     reads or writes freenova_vipadmin (panel adm#/vip# rows), freenova_bp,
 *     freenova_gag or freenova_stats.
 *   - 0 = permanent wherever an expiry is accepted (FN_ExpiryText contract).
 *   - amx_addadmin arg order untouched (external stock contract).
 *   - set_user_flags/get_user_flags + fnvip_* call sites untouched.
 *   - Preset-A ban backend owns amx_ban; this plugin has NO ban code.
 *   - users.ini / SQL entitlements are captured as BASE flags and are NEVER
 *     removed: effective = base | grant. Expiry sweep restores base only.
 *   - Self-grant is DENIED via FN_SelfAllowed(FN_SELF_GRANT) == false.
 *   - No cromchat include in this file, so no CC_DONT_OVERWRITE guard needed.
 *
 * Roles: moderator (e) < admin (cdeijuv) < manager (abcdeijuv).
 * Every mutating command/menu/native path requires the manager flag ("a");
 * server console (id 0, incl. RCON) always passes. All grants, extends,
 * revokes and sweep-expiries are log_amx audited.
 * ============================================================================
 */

#include <amxmodx>
#include <amxmisc>
#include <nvault>
#include <freenova_chat>
#include <freenova_admin>
#include <fn_common>

#define PLUGIN  "FreeNova Admin Grants v3"
#define VERSION "3.0.0"
#define AUTHOR  "FreeNova"

#define VAULT_NAME      "freenova_admin"
#define MAX_GRANT_KEY   64
#define MAX_AUTH        40
#define MAX_MINUTES     5256000   // ~10 years; larger is rejected, never clamped
#define MAX_INDEX       2047

#define TASK_SWEEP      77000
#define TASK_AUTH_BASE  77100
#define MAX_AUTH_TRIES  10

enum _:FN3_Role
{
    ROLE_NONE = 0,
    ROLE_MOD,
    ROLE_ADMIN,
    ROLE_MGR
}

new const g_szRoleName[][16] = { "none", "moderator", "admin", "manager" }

// Duration presets (minutes; 0 = permanent)
#define PRESET_1H   60
#define PRESET_1D   1440
#define PRESET_7D   10080
#define PRESET_30D  43200

// Menu modes / list kinds
#define MODE_ADD    1
#define MODE_EXTEND 2
#define MODE_REVOKE 3
#define MODE_EDIT   4

#define LIST_ONLINE   1
#define LIST_ALL      2
#define LIST_EXPIRING 3
#define LIST_EXPIRED  4

new g_iVault = INVALID_HANDLE
new g_pCvarSweep

// Live cache. Base = flags the player had without us (users.ini/SQL/static).
new g_iBaseFlags[33]
new g_iGrantFlags[33]
new g_iGrantRole[33]
new g_iGrantExpire[33]              // unix time, 0 = permanent
new g_szGrantAuth[33][MAX_AUTH]

// Recently-expired ring for the "expired" menu section ("auth role" lines)
new g_szLastExpired[10][64]
new g_iExpiredPos

// Menu wizard state per invoker
new g_iMenuTarget[33]
new g_iMenuUserid[33]
new g_szMenuAuth[33][MAX_AUTH]
new g_iMenuRole[33]
new g_iMenuMode[33]
new g_iMenuList[33]

// Sweep report counters
new g_iSweepOnline
new g_iSweepOffline
// ============================================================================
// INIT / NATIVES / LIFECYCLE
// ============================================================================

public plugin_init()
{
    fn_boot_banner("admin", 17)

    register_plugin(PLUGIN, VERSION, AUTHOR)

    register_concmd("fn_admin_grant", "Cmd_Grant", FN_FLAG_MANAGER,
        "fn_admin_grant <target> <role> <minutes> - target=#userid|nick|steamid; role=moderator|admin|manager; 0=permanent, h/d suffix ok")
    register_concmd("fn_admin_until", "Cmd_Until", FN_FLAG_MANAGER,
        "fn_admin_until <target> <YYYY-MM-DDTHH:MM> - absolute-date grant")
    register_concmd("fn_admin_extend", "Cmd_Extend", FN_FLAG_MANAGER,
        "fn_admin_extend <target> <minutes> - add time to an active grant")
    register_concmd("fn_admin_revoke", "Cmd_Revoke", FN_FLAG_MANAGER,
        "fn_admin_revoke <target> - remove the grant, keep base entitlements")
    register_concmd("fn_admin_remaining", "Cmd_Remaining", FN_FLAG_MANAGER,
        "fn_admin_remaining <target> - show time left on the grant")
    register_concmd("fn_admin_list", "Cmd_List", FN_FLAG_MANAGER,
        "- list active admin grants")
    register_concmd("fn_admin_sweep", "Cmd_Sweep", FN_FLAG_MANAGER,
        "- expire due grants now (online + indexed offline rows)")
    register_concmd("fn_admin_menu", "Cmd_Menu", FN_FLAG_MANAGER,
        "- open the grant management menu")
    register_clcmd("say /fnadmin", "Cmd_MenuSay")
    register_clcmd("say_team /fnadmin", "Cmd_MenuSay")

    g_pCvarSweep = register_cvar("fn_admin_sweep_interval", "60.0")
}

public plugin_natives()
{
    register_library("freenova_admin")
    register_native("fn_admin_grant", "_nGrant")
    register_native("fn_admin_revoke", "_nRevoke")
    register_native("fn_admin_extend", "_nExtend")
    register_native("fn_admin_remaining", "_nRemaining")
    register_native("fn_admin_has", "_nHas")
    register_native("fn_admin_get_expire", "_nGetExpire")
}

public plugin_cfg()
{
    g_iVault = nvault_open(VAULT_NAME)
    if (g_iVault == INVALID_HANDLE)
        log_amx("[FreeNova][Admin] WARNING: nvault_open '%s' failed - grants are session-only until reload", VAULT_NAME)

    new Float:fSweep = get_pcvar_float(g_pCvarSweep)
    if (fSweep < 15.0)
        fSweep = 15.0
    set_task(fSweep, "Task_Sweep", TASK_SWEEP)
}

public plugin_end()
{
    if (g_iVault != INVALID_HANDLE)
    {
        nvault_close(g_iVault)
        g_iVault = INVALID_HANDLE
    }
}

public client_putinserver(id)
{
    AdminStateReset(id)
    remove_task(TASK_AUTH_BASE + id)
    set_task(0.5, "Task_AuthRetry", TASK_AUTH_BASE + id)
}

public client_disconnected(id)
{
    remove_task(TASK_AUTH_BASE + id)
    AdminStateReset(id)
}

public client_infochanged(id)
{
    if (!is_user_connected(id) || g_szGrantAuth[id][0] || g_iBaseFlags[id])
        return
    new szAuth[MAX_AUTH]
    get_user_authid(id, szAuth, charsmax(szAuth))
    if (equal(szAuth, "STEAM_ID_PENDING") || !szAuth[0])
        return
    remove_task(TASK_AUTH_BASE + id)
    set_task(0.5, "Task_AuthRetry", TASK_AUTH_BASE + id)
}

public Task_AuthRetry(taskId)
{
    new id = taskId - TASK_AUTH_BASE
    if (id < 1 || id > 32 || !is_user_connected(id))
        return

    new szAuth[MAX_AUTH]
    get_user_authid(id, szAuth, charsmax(szAuth))

    static iTry[33]
    if (equal(szAuth, "STEAM_ID_PENDING") || !szAuth[0])
    {
        if (++iTry[id] < MAX_AUTH_TRIES)
            set_task(0.5, "Task_AuthRetry", TASK_AUTH_BASE + id)
        else
            iTry[id] = 0
        return
    }
    iTry[id] = 0

    if (is_user_bot(id) || is_user_hltv(id))
        return

    // Base FIRST (users.ini/static flags), then the grant overlays it.
    g_iBaseFlags[id] = get_user_flags(id)
    copy(g_szGrantAuth[id], charsmax(g_szGrantAuth[]), szAuth)
    LoadGrantFor(id, szAuth)
}

public Task_Sweep()
{
    new Float:fSweep = get_pcvar_float(g_pCvarSweep)
    if (fSweep < 15.0)
        fSweep = 15.0
    set_task(fSweep, "Task_Sweep", TASK_SWEEP)
    SweepAll(false)
}

stock AdminStateReset(id)
{
    g_iBaseFlags[id] = 0
    g_iGrantFlags[id] = 0
    g_iGrantRole[id] = ROLE_NONE
    g_iGrantExpire[id] = 0
    g_szGrantAuth[id][0] = 0
    g_iMenuTarget[id] = 0
    g_iMenuUserid[id] = 0
    g_szMenuAuth[id][0] = 0
    g_iMenuRole[id] = ROLE_NONE
    g_iMenuMode[id] = 0
    g_iMenuList[id] = 0
}
// ============================================================================
// ROLES / IDENTITY / VAULT ROWS
// ============================================================================

stock RoleFlags(iRole)
{
    switch (iRole)
    {
        case ROLE_MOD:   return read_flags("e")
        case ROLE_ADMIN: return read_flags("cdeijuv")
        case ROLE_MGR:   return read_flags("abcdeijuv")
    }
    return 0
}

stock ParseRole(const sz[])
{
    if (equali(sz, "moderator") || equali(sz, "mod"))
        return ROLE_MOD
    if (equali(sz, "admin"))
        return ROLE_ADMIN
    if (equali(sz, "manager"))
        return ROLE_MGR
    return ROLE_NONE
}

stock bool:IsGrantableAuth(const szAuth[])
{
    if (!szAuth[0] || equal(szAuth, "STEAM_ID_PENDING"))
        return false
    if (equali(szAuth, "STEAM_ID_LAN") || equali(szAuth, "VALVE_ID_LAN"))
        return false
    if (equali(szAuth, "BOT") || equali(szAuth, "HLTV"))
        return false
    return true
}

stock SanitizeAuth(const szAuth[], szOut[], iLen)
{
    copy(szOut, iLen, szAuth)
    replace_all(szOut, iLen, ":", "_")
    replace_all(szOut, iLen, ".", "_")
}

stock BuildGrantKey(const szAuth[], szKey[], iLen)
{
    new szSan[40]
    SanitizeAuth(szAuth, szSan, charsmax(szSan))
    formatex(szKey, iLen, "grant#%s", szSan)
}

// Row value: "<role>|<expire>|<flags>|<rawauth>"
stock bool:ParseGrantValue(const szValue[], &iRole, &iExpire, &iFlags, szAuth[], iAuthLen)
{
    new szCopy[128]
    copy(szCopy, charsmax(szCopy), szValue)

    new iA = FindBar(szCopy)
    if (iA < 0)
        return false
    szCopy[iA] = 0
    iRole = str_to_num(szCopy)
    if (iRole < ROLE_MOD || iRole > ROLE_MGR)
        return false

    new szRest[96]
    copy(szRest, charsmax(szRest), szCopy[iA + 1])
    new iB = FindBar(szRest)
    if (iB < 0)
        return false
    szRest[iB] = 0
    iExpire = str_to_num(szRest)

    new szRest2[64]
    copy(szRest2, charsmax(szRest2), szRest[iB + 1])
    new iC = FindBar(szRest2)
    if (iC < 0)
    {
        iFlags = str_to_num(szRest2)
        szAuth[0] = 0
    }
    else
    {
        szRest2[iC] = 0
        iFlags = str_to_num(szRest2)
        copy(szAuth, iAuthLen, szRest2[iC + 1])
    }
    if (iFlags == 0)
        iFlags = RoleFlags(iRole)
    return true
}

stock FindBar(const sz[])
{
    new iLen = strlen(sz)
    for (new i = 0; i < iLen; i++)
    {
        if (sz[i] == 124) // "|"
            return i
    }
    return -1
}

// Strict duration: "<n>", "<n>m", "<n>h", "<n>d". Returns minutes, -1 invalid.
// Anything unparsable (incl. negatives, junk, overflow) is INVALID and must
// NEVER fall through to 0/permanent at the call site.
stock ParseMinutesArg(const sz[], &iMinutes)
{
    iMinutes = -1
    new iLen = strlen(sz)
    if (iLen < 1 || iLen > 8)
        return -1

    new iMult = 1
    new iDigits = iLen
    new cLast = sz[iLen - 1]
    if (cLast == 109 || cLast == 77)          // m/M
        iDigits = iLen - 1
    else if (cLast == 104 || cLast == 72)     // h/H
    {
        iDigits = iLen - 1
        iMult = 60
    }
    else if (cLast == 100 || cLast == 68)     // d/D
    {
        iDigits = iLen - 1
        iMult = 1440
    }
    if (iDigits < 1 || iDigits > 7)
        return -1
    for (new i = 0; i < iDigits; i++)
    {
        if (!isdigit(sz[i]))
            return -1
    }
    new iVal = 0
    for (new i = 0; i < iDigits; i++)
        iVal = iVal * 10 + (sz[i] - 48)
    new iTotal = iVal * iMult
    if (iTotal < 0 || iTotal > MAX_MINUTES)
        return -1
    iMinutes = iTotal
    return iMinutes
}

stock bool:IsLeapYear(y)
{
    return ((y % 4 == 0 && y % 100 != 0) || y % 400 == 0)
}

stock DaysInMonth(y, m)
{
    switch (m)
    {
        case 1, 3, 5, 7, 8, 10, 12: return 31
        case 4, 6, 9, 11: return 30
        case 2: return IsLeapYear(y) ? 29 : 28
    }
    return 0
}

// Days since 1970-01-01 (civil algorithm; inputs validated positive first).
stock DaysFromCivil(y, m, d)
{
    if (m <= 2)
    {
        y -= 1
        m += 12
    }
    new era = y / 400
    new yoe = y - era * 400
    new doy = (153 * (m - 3) + 2) / 5 + d - 1
    new doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
    return era * 146097 + doe - 719468
}

// Strict "YYYY-MM-DDTHH:MM". Returns absolute systime or -1 when invalid/past.
// Year capped at 2037 (signed-32-bit systime). Never returns 0/permanent.
stock ParseDateArg(const sz[])
{
    new szCopy[32]
    copy(szCopy, charsmax(szCopy), sz)
    replace_all(szCopy, charsmax(szCopy), "-", " ")
    replace_all(szCopy, charsmax(szCopy), "T", " ")
    replace_all(szCopy, charsmax(szCopy), "t", " ")
    replace_all(szCopy, charsmax(szCopy), ":", " ")

    new sY[8], sM[8], sD[8], sH[8], sMi[8]
    if (parse(szCopy, sY, charsmax(sY), sM, charsmax(sM), sD, charsmax(sD),
        sH, charsmax(sH), sMi, charsmax(sMi)) != 5)
        return -1
    if (!IsAllDigits(sY) || !IsAllDigits(sM) || !IsAllDigits(sD)
        || !IsAllDigits(sH) || !IsAllDigits(sMi))
        return -1

    new y = str_to_num(sY)
    new m = str_to_num(sM)
    new d = str_to_num(sD)
    new h = str_to_num(sH)
    new mi = str_to_num(sMi)

    new iNow = get_systime()
    if (y < 2026 || y > 2037 || m < 1 || m > 12 || h < 0 || h > 23 || mi < 0 || mi > 59)
        return -1
    if (d < 1 || d > DaysInMonth(y, m))
        return -1

    new iExpire = DaysFromCivil(y, m, d) * 86400 + h * 3600 + mi * 60
    if (iExpire <= 0 || iExpire <= iNow)
        return -1
    return iExpire
}

stock bool:IsAllDigits(const sz[])
{
    new iLen = strlen(sz)
    if (!iLen)
        return false
    for (new i = 0; i < iLen; i++)
    {
        if (!isdigit(sz[i]))
            return false
    }
    return true
}
// ============================================================================
// INDEX (offline enumeration; nVault has no key listing)
// ============================================================================

stock IndexLoad(szOut[], iLen)
{
    szOut[0] = 0
    if (g_iVault == INVALID_HANDLE)
        return 0
    new iStamp
    new szVal[MAX_INDEX + 1]
    if (!nvault_lookup(g_iVault, "index", szVal, charsmax(szVal), iStamp))
        return 0
    copy(szOut, iLen, szVal)
    return 1
}

stock IndexSave(const szIndex[])
{
    if (g_iVault == INVALID_HANDLE)
        return 0
    if (!szIndex[0])
    {
        nvault_remove(g_iVault, "index")
        return 1
    }
    nvault_set(g_iVault, "index", szIndex)
    return 1
}

stock bool:IndexHas(const szIndex[], const szSan[])
{
    new szPad[MAX_INDEX + 4]
    formatex(szPad, charsmax(szPad), " %s ", szIndex)
    new szNeedle[48]
    formatex(szNeedle, charsmax(szNeedle), " %s ", szSan)
    return contain(szPad, szNeedle) != -1
}

stock AddToIndex(const szSan[])
{
    new szIndex[MAX_INDEX + 1]
    IndexLoad(szIndex, charsmax(szIndex))
    if (IndexHas(szIndex, szSan))
        return 1
    if (szIndex[0])
        add(szIndex, charsmax(szIndex), " ")
    add(szIndex, charsmax(szIndex), szSan)
    return IndexSave(szIndex)
}

stock RemoveFromIndex(const szSan[])
{
    new szIndex[MAX_INDEX + 1]
    IndexLoad(szIndex, charsmax(szIndex))
    if (!szIndex[0])
        return 1
    new szOut[MAX_INDEX + 1]
    szOut[0] = 0
    new szTok[48]
    new iPos = 0
    new iLen = strlen(szIndex)
    new iTok = 0
    while (iPos <= iLen)
    {
        new c = (iPos < iLen) ? szIndex[iPos] : 32
        if (c == 32 || c == 9)
        {
            if (iTok > 0)
            {
                szTok[iTok] = 0
                if (!equal(szTok, szSan))
                {
                    if (szOut[0])
                        add(szOut, charsmax(szOut), " ")
                    add(szOut, charsmax(szOut), szTok)
                }
                iTok = 0
            }
        }
        else if (iTok < charsmax(szTok) - 1)
            szTok[iTok++] = c
        iPos++
    }
    return IndexSave(szOut)
}

// ============================================================================
// CORE GRANT STORE
// ============================================================================

// Lookup by RAW auth. Returns: 1 active row, 0 none, -1 expired (row purged).
stock GetGrantRow(const szAuth[], &iRole, &iExpire, &iFlags)
{
    iRole = ROLE_NONE
    iExpire = 0
    iFlags = 0
    if (g_iVault == INVALID_HANDLE || !IsGrantableAuth(szAuth))
        return 0

    new szSan[40]
    SanitizeAuth(szAuth, szSan, charsmax(szSan))
    new szKey[MAX_GRANT_KEY]
    formatex(szKey, charsmax(szKey), "grant#%s", szSan)

    new szValue[128], iStamp
    if (!nvault_lookup(g_iVault, szKey, szValue, charsmax(szValue), iStamp))
        return 0

    new szRowAuth[MAX_AUTH]
    if (!ParseGrantValue(szValue, iRole, iExpire, iFlags, szRowAuth, charsmax(szRowAuth)))
    {
        nvault_remove(g_iVault, szKey)
        RemoveFromIndex(szSan)
        return 0
    }
    if (iExpire > 0 && get_systime() >= iExpire)
    {
        nvault_remove(g_iVault, szKey)
        RemoveFromIndex(szSan)
        PushExpired(szAuth, iRole)
        log_amx("[FreeNova][Admin] Grant expired on read: %s role=%s", szAuth, g_szRoleName[iRole])
        iRole = ROLE_NONE
        iExpire = 0
        iFlags = 0
        return -1
    }
    return 1
}

stock Core_GrantAuth(const szAuth[], iRole, iExpire, const szGranter[])
{
    if (g_iVault == INVALID_HANDLE || !IsGrantableAuth(szAuth))
        return 0
    if (iRole < ROLE_MOD || iRole > ROLE_MGR)
        return 0
    if (iExpire < 0)
        return 0

    new szSan[40]
    SanitizeAuth(szAuth, szSan, charsmax(szSan))
    new szKey[MAX_GRANT_KEY]
    formatex(szKey, charsmax(szKey), "grant#%s", szSan)

    new szValue[128]
    formatex(szValue, charsmax(szValue), "%d|%d|%d|%s",
        iRole, iExpire, RoleFlags(iRole), szAuth)
    nvault_set(g_iVault, szKey, szValue)
    AddToIndex(szSan)

    // Live overlay when the owner is online.
    new id = FindOnlineByAuth(szAuth)
    if (id > 0)
    {
        g_iGrantRole[id] = iRole
        g_iGrantFlags[id] = RoleFlags(iRole)
        g_iGrantExpire[id] = iExpire
        RecalcFlags(id)
        NotifyGrant(id)
    }

    log_amx("[FreeNova][Admin] GRANT auth=%s role=%s expire=%d (%s) by=%s",
        szAuth, g_szRoleName[iRole], iExpire,
        iExpire == 0 ? "permanent" : "timed", szGranter[0] ? szGranter : "console")
    return 1
}

stock Core_RevokeAuth(const szAuth[], const szRevoker[])
{
    if (g_iVault == INVALID_HANDLE || !IsGrantableAuth(szAuth))
        return 0

    new szSan[40]
    SanitizeAuth(szAuth, szSan, charsmax(szSan))
    new szKey[MAX_GRANT_KEY]
    formatex(szKey, charsmax(szKey), "grant#%s", szSan)

    new szValue[128], iStamp
    new bool:bHad = nvault_lookup(g_iVault, szKey, szValue, charsmax(szValue), iStamp) != 0
    if (bHad)
        nvault_remove(g_iVault, szKey)
    RemoveFromIndex(szSan)

    new id = FindOnlineByAuth(szAuth)
    if (id > 0)
    {
        g_iGrantRole[id] = ROLE_NONE
        g_iGrantFlags[id] = 0
        g_iGrantExpire[id] = 0
        RecalcFlags(id)   // restores BASE flags only; users.ini/SQL untouched
        if (is_user_connected(id))
            fn_chat_warning(id, "Your admin grant was revoked. Base entitlements unchanged.")
    }

    if (bHad)
        log_amx("[FreeNova][Admin] REVOKE auth=%s by=%s", szAuth, szRevoker[0] ? szRevoker : "console")
    return bHad ? 1 : 0
}

// Returns new expire, -1 on failure (none/expired/invalid).
stock Core_ExtendAuth(const szAuth[], iAddMinutes, const szExtender[])
{
    if (iAddMinutes < 0 || iAddMinutes > MAX_MINUTES)
        return -1
    new iRole, iExpire, iFlags
    new iRow = GetGrantRow(szAuth, iRole, iExpire, iFlags)
    if (iRow != 1)
        return -1
    if (iExpire == 0)
    {
        log_amx("[FreeNova][Admin] EXTEND auth=%s role=%s permanent unchanged by=%s",
            szAuth, g_szRoleName[iRole], szExtender[0] ? szExtender : "console")
        return 0   // permanent: nothing to add, stays permanent
    }
    new iNew = iExpire + iAddMinutes * 60
    if (iNew <= iExpire)
        return -1
    Core_GrantAuth(szAuth, iRole, iNew, szExtender)
    log_amx("[FreeNova][Admin] EXTEND auth=%s role=%s +%d min new_expire=%d by=%s",
        szAuth, g_szRoleName[iRole], iAddMinutes, iNew, szExtender[0] ? szExtender : "console")
    return iNew
}

stock FindOnlineByAuth(const szAuth[])
{
    new players[32], iNum
    get_players(players, iNum, "ch")
    for (new i = 0; i < iNum; i++)
    {
        new p = players[i]
        if (!is_user_connected(p) || is_user_bot(p) || is_user_hltv(p))
            continue
        new szA[MAX_AUTH]
        get_user_authid(p, szA, charsmax(szA))
        if (equali(szA, szAuth))
            return p
    }
    return 0
}

stock LoadGrantFor(id, const szAuth[])
{
    new iRole, iExpire, iFlags
    new iRow = GetGrantRow(szAuth, iRole, iExpire, iFlags)
    if (iRow != 1)
    {
        g_iGrantRole[id] = ROLE_NONE
        g_iGrantFlags[id] = 0
        g_iGrantExpire[id] = 0
        RecalcFlags(id)
        return 0
    }
    g_iGrantRole[id] = iRole
    g_iGrantFlags[id] = iFlags
    g_iGrantExpire[id] = iExpire
    RecalcFlags(id)
    NotifyGrant(id)
    return 1
}

// Effective permissions = base | active grant. NEVER subtracts base.
stock RecalcFlags(id)
{
    if (!is_user_connected(id))
        return 0
    new iNow = get_systime()
    new bool:bActive = g_iGrantRole[id] >= ROLE_MOD && g_iGrantRole[id] <= ROLE_MGR
        && (g_iGrantExpire[id] == 0 || iNow < g_iGrantExpire[id])
    new iEff = g_iBaseFlags[id]
    if (bActive)
        iEff |= g_iGrantFlags[id]
    set_user_flags(id, iEff)
    return 1
}

stock NotifyGrant(id)
{
    if (!is_user_connected(id) || g_iGrantRole[id] < ROLE_MOD)
        return 0
    if (g_iGrantExpire[id] == 0)
        fn_chat_success(id, "Admin grant active: ^4%s^1 (^3permanent^1).", g_szRoleName[g_iGrantRole[id]])
    else
    {
        new szExp[64]
        FN_ExpiryText(g_iGrantExpire[id], szExp, charsmax(szExp))
        fn_chat_success(id, "Admin grant active: ^4%s^1 (expires %s).", g_szRoleName[g_iGrantRole[id]], szExp)
    }
    return 1
}

stock PushExpired(const szAuth[], iRole)
{
    formatex(g_szLastExpired[g_iExpiredPos % 10], 63, "%s %s", szAuth,
        (iRole >= ROLE_MOD && iRole <= ROLE_MGR) ? g_szRoleName[iRole] : "grant")
    g_iExpiredPos++
}

// Sweep online players AND indexed offline rows. Removes ONLY expired grants;
// base flags are restored via RecalcFlags, never touched otherwise.
stock SweepAll(bool:bVerbose)
{
    g_iSweepOnline = 0
    g_iSweepOffline = 0
    new iNow = get_systime()

    new players[32], iNum
    get_players(players, iNum, "ch")
    for (new i = 0; i < iNum; i++)
    {
        new p = players[i]
        if (!is_user_connected(p) || g_iGrantRole[p] < ROLE_MOD)
            continue
        if (g_iGrantExpire[p] > 0 && iNow >= g_iGrantExpire[p])
        {
            new szAuth[MAX_AUTH]
            get_user_authid(p, szAuth, charsmax(szAuth))
            new iRole = g_iGrantRole[p]
            new szSan[40]
            SanitizeAuth(szAuth, szSan, charsmax(szSan))
            new szKey[MAX_GRANT_KEY]
            formatex(szKey, charsmax(szKey), "grant#%s", szSan)
            if (g_iVault != INVALID_HANDLE)
                nvault_remove(g_iVault, szKey)
            RemoveFromIndex(szSan)
            PushExpired(szAuth, iRole)
            g_iGrantRole[p] = ROLE_NONE
            g_iGrantFlags[p] = 0
            g_iGrantExpire[p] = 0
            RecalcFlags(p)
            fn_chat_warning(p, "Your admin grant (^3%s^1) expired. Base entitlements unchanged.", g_szRoleName[iRole])
            log_amx("[FreeNova][Admin] SWEEP expired online auth=%s role=%s", szAuth, g_szRoleName[iRole])
            g_iSweepOnline++
        }
    }

    // Offline rows via the index (nVault cannot enumerate keys).
    new szIndex[MAX_INDEX + 1]
    if (IndexLoad(szIndex, charsmax(szIndex)) && szIndex[0] && g_iVault != INVALID_HANDLE)
    {
        new szTok[48]
        new iPos = 0
        new iLen = strlen(szIndex)
        new iTok = 0
        while (iPos <= iLen)
        {
            new c = (iPos < iLen) ? szIndex[iPos] : 32
            if (c == 32 || c == 9)
            {
                if (iTok > 0)
                {
                    szTok[iTok] = 0
                    SweepIndexToken(szTok, iNow)
                    iTok = 0
                }
            }
            else if (iTok < charsmax(szTok) - 1)
                szTok[iTok++] = c
            iPos++
        }
    }

    if (bVerbose || g_iSweepOnline > 0 || g_iSweepOffline > 0)
        log_amx("[FreeNova][Admin] SWEEP done online=%d offline=%d", g_iSweepOnline, g_iSweepOffline)
    return g_iSweepOnline + g_iSweepOffline
}

stock SweepIndexToken(const szSan[], iNow)
{
    if (FindOnlineBySan(szSan) > 0)
        return 0   // handled in the online pass
    new szKey[MAX_GRANT_KEY]
    formatex(szKey, charsmax(szKey), "grant#%s", szSan)
    new szValue[128], iStamp
    if (!nvault_lookup(g_iVault, szKey, szValue, charsmax(szValue), iStamp))
    {
        RemoveFromIndex(szSan)
        return 0
    }
    new iRole, iExpire, iFlags
    new szRowAuth[MAX_AUTH]
    if (!ParseGrantValue(szValue, iRole, iExpire, iFlags, szRowAuth, charsmax(szRowAuth)))
    {
        nvault_remove(g_iVault, szKey)
        RemoveFromIndex(szSan)
        return 0
    }
    if (iExpire > 0 && iNow >= iExpire)
    {
        nvault_remove(g_iVault, szKey)
        RemoveFromIndex(szSan)
        PushExpired(szRowAuth[0] ? szRowAuth : szSan, iRole)
        log_amx("[FreeNova][Admin] SWEEP expired offline key=%s role=%s", szKey, g_szRoleName[iRole])
        g_iSweepOffline++
        return 1
    }
    return 0
}

stock FindOnlineBySan(const szSan[])
{
    new players[32], iNum
    get_players(players, iNum, "ch")
    for (new i = 0; i < iNum; i++)
    {
        new p = players[i]
        if (!is_user_connected(p) || is_user_bot(p) || is_user_hltv(p))
            continue
        new szA[MAX_AUTH], szS[40]
        get_user_authid(p, szA, charsmax(szA))
        SanitizeAuth(szA, szS, charsmax(szS))
        if (equali(szS, szSan))
            return p
    }
    return 0
}
// ============================================================================
// TARGET RESOLUTION (#userid / nick / steamid live-or-offline / live ip)
// ============================================================================

#define RT_OK        0
#define RT_NO_MATCH  1
#define RT_AMBIGUOUS 2
#define RT_INVALID   3

// Offline grants are steamid-only (stable identity). Nick/ip must be live.
stock ResolveTarget(const szArg[], &iTarget, szAuth[], iAuthLen)
{
    iTarget = 0
    szAuth[0] = 0
    if (!szArg[0])
        return RT_INVALID

    if (szArg[0] == 35) // "#userid"
    {
        new uid = str_to_num(szArg[1])
        if (uid <= 0)
            return RT_INVALID
        new players[32], iNum
        get_players(players, iNum, "ch")
        for (new i = 0; i < iNum; i++)
        {
            if (get_user_userid(players[i]) == uid)
            {
                iTarget = players[i]
                get_user_authid(iTarget, szAuth, iAuthLen)
                return RT_OK
            }
        }
        return RT_NO_MATCH
    }

    if (containi(szArg, "STEAM_") == 0 || containi(szArg, "VALVE_") == 0)
    {
        new p = FindOnlineByAuthRaw(szArg)
        if (p > 0)
        {
            iTarget = p
            get_user_authid(iTarget, szAuth, iAuthLen)
            return RT_OK
        }
        if (!IsGrantableAuth(szArg))
            return RT_NO_MATCH
        copy(szAuth, iAuthLen, szArg)
        return RT_OK   // offline steamid identity
    }

    if (isdigit(szArg[0]) && IsIpLiteral(szArg))
    {
        new players[32], iNum
        get_players(players, iNum, "ch")
        for (new i = 0; i < iNum; i++)
        {
            new szIP[24]
            get_user_ip(players[i], szIP, charsmax(szIP), 1)
            if (equal(szIP, szArg))
            {
                iTarget = players[i]
                get_user_authid(iTarget, szAuth, iAuthLen)
                return RT_OK
            }
        }
        return RT_NO_MATCH
    }

    // Nick: exact pass, then substring pass.
    new iMatches
    new iFound
    for (new pass = 0; pass < 2 && !iFound; pass++)
    {
        iMatches = 0
        iFound = 0
        new players[32], iNum
        get_players(players, iNum, "ch")
        for (new i = 0; i < iNum; i++)
        {
            new szName[32]
            get_user_name(players[i], szName, charsmax(szName))
            new bool:bHit = false
            if (pass == 0)
                bHit = (equali(szName, szArg) != 0)
            else
                bHit = (containi(szName, szArg) != -1)
            if (bHit)
            {
                iMatches++
                iFound = players[i]
            }
        }
        if (iMatches > 1)
            return RT_AMBIGUOUS
    }
    if (!iFound)
        return RT_NO_MATCH
    iTarget = iFound
    get_user_authid(iTarget, szAuth, iAuthLen)
    return RT_OK
}

stock FindOnlineByAuthRaw(const szAuth[])
{
    new players[32], iNum
    get_players(players, iNum, "ch")
    for (new i = 0; i < iNum; i++)
    {
        if (is_user_bot(players[i]) || is_user_hltv(players[i]))
            continue
        new szA[MAX_AUTH]
        get_user_authid(players[i], szA, charsmax(szA))
        if (equali(szA, szAuth))
            return players[i]
    }
    return 0
}

stock bool:IsIpLiteral(const sz[])
{
    new iLen = strlen(sz)
    if (iLen < 7 || iLen > 15)
        return false
    new iDots
    for (new i = 0; i < iLen; i++)
    {
        if (sz[i] == 46)
        {
            iDots++
            if (i == 0 || sz[i - 1] == 46)
                return false
        }
        else if (!isdigit(sz[i]))
            return false
    }
    return (iDots == 3)
}

stock GranterName(id, szOut[], iLen)
{
    if (id <= 0)
    {
        copy(szOut, iLen, "console")
        return 0
    }
    new szAuth[MAX_AUTH]
    get_user_authid(id, szAuth, charsmax(szAuth))
    copy(szOut, iLen, szAuth)
    return 1
}

// Manager gate for commands: console/RCON (id 0) passes, players need "a".
stock bool:CmdGate(id)
{
    if (id == 0)
        return true
    if (!is_user_connected(id))
        return false
    if (!(get_user_flags(id) & FN_FLAG_MANAGER))
    {
        fn_chat_permission(id, "Manager access required.")
        return false
    }
    return true
}

stock ReportResolveError(id, iRes)
{
    switch (iRes)
    {
        case RT_INVALID:   fn_chat_error(id, "Invalid target.")
        case RT_AMBIGUOUS: fn_chat_error(id, "More than one player matches - use #userid.")
        case RT_NO_MATCH:  fn_chat_error(id, "No player matches that target.")
    }
}

// ============================================================================
// COMMANDS
// ============================================================================

public Cmd_Grant(id, level, cid)
{
    if (!cmd_access(id, level, cid, 4))
        return PLUGIN_HANDLED
    if (!CmdGate(id))
        return PLUGIN_HANDLED

    new szTarget[64], szRole[16], szDur[16]
    read_argv(1, szTarget, charsmax(szTarget))
    read_argv(2, szRole, charsmax(szRole))
    read_argv(3, szDur, charsmax(szDur))
    trim(szTarget)

    new iRole = ParseRole(szRole)
    if (iRole == ROLE_NONE)
    {
        fn_chat_usage(id, "Usage: fn_admin_grant <target> <moderator|admin|manager> <minutes|0|1h|7d>")
        return PLUGIN_HANDLED
    }
    new iMinutes
    if (ParseMinutesArg(szDur, iMinutes) < 0)
    {
        // Invalid durations are REJECTED, never silently permanent.
        fn_chat_error(id, "Invalid duration. Use minutes, 0 for permanent, or h/d suffix (ex: 90, 1h, 7d).")
        return PLUGIN_HANDLED
    }

    new iTarget
    new szAuth[MAX_AUTH]
    new iRes = ResolveTarget(szTarget, iTarget, szAuth, charsmax(szAuth))
    if (iRes != RT_OK)
    {
        ReportResolveError(id, iRes)
        return PLUGIN_HANDLED
    }
    if (!IsGrantableAuth(szAuth))
    {
        fn_chat_error(id, "Target has no grantable SteamID yet.")
        return PLUGIN_HANDLED
    }
    if (iTarget > 0)
    {
        new iCode = FN_CheckTarget(id, iTarget, FN_SELF_GRANT)
        if (iCode == FN_TARGET_SELF_DENIED)
        {
            fn_chat_error(id, "You cannot grant admin to yourself.")
            return PLUGIN_HANDLED
        }
        if (iCode != FN_TARGET_OK)
        {
            fn_chat_error(id, "This player is immune to your administrative actions.")
            return PLUGIN_HANDLED
        }
    }

    new iExpire = (iMinutes == 0) ? 0 : (get_systime() + iMinutes * 60)
    new szGranter[MAX_AUTH]
    GranterName(id, szGranter, charsmax(szGranter))
    if (!Core_GrantAuth(szAuth, iRole, iExpire, szGranter))
    {
        fn_chat_error(id, "Grant store unavailable. Try again after reload.")
        return PLUGIN_HANDLED
    }

    new szExp[64]
    FN_ExpiryText(iExpire, szExp, charsmax(szExp))
    if (iTarget > 0)
    {
        new szName[32]
        get_user_name(iTarget, szName, charsmax(szName))
        fn_chat_success(id, "Granted ^4%s^1 to %s (expires %s).", g_szRoleName[iRole], szName, szExp)
    }
    else
        fn_chat_success(id, "Granted ^4%s^1 to %s (expires %s, applies on connect).", g_szRoleName[iRole], szAuth, szExp)
    return PLUGIN_HANDLED
}

public Cmd_Until(id, level, cid)
{
    if (!cmd_access(id, level, cid, 3))
        return PLUGIN_HANDLED
    if (!CmdGate(id))
        return PLUGIN_HANDLED

    new szTarget[64], szDate[32]
    read_argv(1, szTarget, charsmax(szTarget))
    read_argv(2, szDate, charsmax(szDate))
    trim(szTarget)

    new iExpire = ParseDateArg(szDate)
    if (iExpire <= 0)
    {
        fn_chat_error(id, "Invalid date. Use YYYY-MM-DDTHH:MM, future only (ex: 2026-12-31T23:59).")
        return PLUGIN_HANDLED
    }

    new iTarget
    new szAuth[MAX_AUTH]
    new iRes = ResolveTarget(szTarget, iTarget, szAuth, charsmax(szAuth))
    if (iRes != RT_OK)
    {
        ReportResolveError(id, iRes)
        return PLUGIN_HANDLED
    }
    if (!IsGrantableAuth(szAuth))
    {
        fn_chat_error(id, "Target has no grantable SteamID yet.")
        return PLUGIN_HANDLED
    }
    if (iTarget > 0)
    {
        new iCode = FN_CheckTarget(id, iTarget, FN_SELF_GRANT)
        if (iCode == FN_TARGET_SELF_DENIED)
        {
            fn_chat_error(id, "You cannot grant admin to yourself.")
            return PLUGIN_HANDLED
        }
        if (iCode != FN_TARGET_OK)
        {
            fn_chat_error(id, "This player is immune to your administrative actions.")
            return PLUGIN_HANDLED
        }
    }

    // Role defaults to admin when the target has no grant; keeps role on edit.
    new iRole = ROLE_ADMIN
    new iOldRole, iOldExp, iOldFlags
    if (GetGrantRow(szAuth, iOldRole, iOldExp, iOldFlags) == 1)
        iRole = iOldRole

    new szGranter[MAX_AUTH]
    GranterName(id, szGranter, charsmax(szGranter))
    if (!Core_GrantAuth(szAuth, iRole, iExpire, szGranter))
    {
        fn_chat_error(id, "Grant store unavailable. Try again after reload.")
        return PLUGIN_HANDLED
    }
    new szExp[64]
    FN_ExpiryText(iExpire, szExp, charsmax(szExp))
    new szWho[MAX_AUTH]
    if (iTarget > 0)
        get_user_name(iTarget, szWho, charsmax(szWho))
    else
        copy(szWho, charsmax(szWho), szAuth)
    fn_chat_success(id, "Granted ^4%s^1 to %s until %s.", g_szRoleName[iRole], szWho, szExp)
    return PLUGIN_HANDLED
}

public Cmd_Extend(id, level, cid)
{
    if (!cmd_access(id, level, cid, 3))
        return PLUGIN_HANDLED
    if (!CmdGate(id))
        return PLUGIN_HANDLED

    new szTarget[64], szDur[16]
    read_argv(1, szTarget, charsmax(szTarget))
    read_argv(2, szDur, charsmax(szDur))
    trim(szTarget)

    new iMinutes
    if (ParseMinutesArg(szDur, iMinutes) < 0 || iMinutes <= 0)
    {
        fn_chat_error(id, "Invalid extend amount. Use minutes or h/d suffix (ex: 60, 1h, 7d).")
        return PLUGIN_HANDLED
    }

    new iTarget
    new szAuth[MAX_AUTH]
    new iRes = ResolveTarget(szTarget, iTarget, szAuth, charsmax(szAuth))
    if (iRes != RT_OK)
    {
        ReportResolveError(id, iRes)
        return PLUGIN_HANDLED
    }
    if (iTarget > 0 && FN_CheckTarget(id, iTarget, FN_SELF_GRANT) != FN_TARGET_OK)
    {
        fn_chat_error(id, "You cannot extend your own grant.")
        return PLUGIN_HANDLED
    }

    new szExtender[MAX_AUTH]
    GranterName(id, szExtender, charsmax(szExtender))
    new iNew = Core_ExtendAuth(szAuth, iMinutes, szExtender)
    if (iNew < 0)
    {
        fn_chat_error(id, "No active grant for that target. Use fn_admin_grant first.")
        return PLUGIN_HANDLED
    }
    if (iNew == 0)
        fn_chat_success(id, "Grant is permanent - nothing to extend.")
    else
    {
        new szExp[64]
        FN_ExpiryText(iNew, szExp, charsmax(szExp))
        fn_chat_success(id, "Grant extended by %d minutes. New expiry: %s.", iMinutes, szExp)
    }
    return PLUGIN_HANDLED
}

public Cmd_Revoke(id, level, cid)
{
    if (!cmd_access(id, level, cid, 2))
        return PLUGIN_HANDLED
    if (!CmdGate(id))
        return PLUGIN_HANDLED

    new szTarget[64]
    read_argv(1, szTarget, charsmax(szTarget))
    trim(szTarget)

    new iTarget
    new szAuth[MAX_AUTH]
    new iRes = ResolveTarget(szTarget, iTarget, szAuth, charsmax(szAuth))
    if (iRes != RT_OK)
    {
        ReportResolveError(id, iRes)
        return PLUGIN_HANDLED
    }
    if (iTarget > 0 && FN_CheckTarget(id, iTarget, FN_SELF_GRANT) != FN_TARGET_OK)
    {
        fn_chat_error(id, "You cannot revoke with this grant path.")
        return PLUGIN_HANDLED
    }

    new szRevoker[MAX_AUTH]
    GranterName(id, szRevoker, charsmax(szRevoker))
    if (!Core_RevokeAuth(szAuth, szRevoker))
        fn_chat_info(id, "No active grant for that target.")
    else
        fn_chat_success(id, "Grant revoked. Base entitlements (users.ini/SQL) unchanged.")
    return PLUGIN_HANDLED
}

public Cmd_Remaining(id, level, cid)
{
    if (!cmd_access(id, level, cid, 2))
        return PLUGIN_HANDLED
    if (!CmdGate(id))
        return PLUGIN_HANDLED

    new szTarget[64]
    read_argv(1, szTarget, charsmax(szTarget))
    trim(szTarget)

    new iTarget
    new szAuth[MAX_AUTH]
    new iRes = ResolveTarget(szTarget, iTarget, szAuth, charsmax(szAuth))
    if (iRes != RT_OK)
    {
        ReportResolveError(id, iRes)
        return PLUGIN_HANDLED
    }

    new iRole, iExpire, iFlags
    new iRow = GetGrantRow(szAuth, iRole, iExpire, iFlags)
    if (iRow != 1)
    {
        fn_chat_info(id, "No active grant for that target.")
        return PLUGIN_HANDLED
    }
    if (iExpire == 0)
    {
        fn_chat_info(id, "Grant: ^4%s^1, ^3permanent^1.", g_szRoleName[iRole])
        return PLUGIN_HANDLED
    }
    new iLeft = iExpire - get_systime()
    if (iLeft < 0)
        iLeft = 0
    new szExp[64]
    FN_ExpiryText(iExpire, szExp, charsmax(szExp))
    fn_chat_info(id, "Grant: ^4%s^1, ^3%dd %dh %dm^1 left (expires %s).",
        g_szRoleName[iRole], iLeft / 86400, (iLeft % 86400) / 3600, (iLeft % 3600) / 60, szExp)
    return PLUGIN_HANDLED
}

public Cmd_List(id, level, cid)
{
    if (!cmd_access(id, level, cid, 1))
        return PLUGIN_HANDLED
    if (!CmdGate(id))
        return PLUGIN_HANDLED

    console_print(id, "=== FreeNova Admin Grants ===")
    new iCount
    new players[32], iNum
    get_players(players, iNum, "ch")
    for (new i = 0; i < iNum; i++)
    {
        new p = players[i]
        if (g_iGrantRole[p] < ROLE_MOD)
            continue
        new szName[32]
        get_user_name(p, szName, charsmax(szName))
        new szExp[64]
        FN_ExpiryText(g_iGrantExpire[p], szExp, charsmax(szExp))
        console_print(id, "%s [%s] %s : %s", g_szGrantAuth[p], szName, g_szRoleName[g_iGrantRole[p]], szExp)
        iCount++
    }
    new szIndex[MAX_INDEX + 1]
    IndexLoad(szIndex, charsmax(szIndex))
    console_print(id, "online=%d index=[%s]", iCount, szIndex[0] ? szIndex : "-")
    log_amx("[FreeNova][Admin] Listed %d online grant(s)", iCount)
    return PLUGIN_HANDLED
}

public Cmd_Sweep(id, level, cid)
{
    if (!cmd_access(id, level, cid, 1))
        return PLUGIN_HANDLED
    if (!CmdGate(id))
        return PLUGIN_HANDLED
    SweepAll(true)
    fn_chat_success(id, "Sweep done: %d online + %d offline grant(s) expired.", g_iSweepOnline, g_iSweepOffline)
    return PLUGIN_HANDLED
}

public Cmd_Menu(id, level, cid)
{
    if (!cmd_access(id, level, cid, 1))
        return PLUGIN_HANDLED
    if (!CmdGate(id))
        return PLUGIN_HANDLED
    ShowMainMenu(id)
    return PLUGIN_HANDLED
}

public Cmd_MenuSay(id)
{
    if (!is_user_connected(id))
        return PLUGIN_HANDLED
    if (!(get_user_flags(id) & FN_FLAG_MANAGER))
    {
        fn_chat_permission(id, "Manager access required.")
        return PLUGIN_HANDLED
    }
    ShowMainMenu(id)
    return PLUGIN_HANDLED
}


// ============================================================================
// MENU (sections: add / remove / edit / extend / online / all / expiring /
// expired / roles; presets 1h / 1d / 7d / 30d / permanent / custom / date)
// ============================================================================

stock ShowMainMenu(id)
{
    new szTitle[64]
    FN_MenuTitle(szTitle, charsmax(szTitle), "Admin grants")
    new menu = menu_create(szTitle, "MainMenuHandler")
    menu_additem(menu, "Add grant (online player)", "add")
    menu_additem(menu, "Extend grant", "extend")
    menu_additem(menu, "Revoke grant (remove)", "revoke")
    menu_additem(menu, "Change role (edit)", "edit")
    menu_additem(menu, "Online grants", "online")
    menu_additem(menu, "All grants", "all")
    menu_additem(menu, "Expiring soon", "expiring")
    menu_additem(menu, "Expired log", "expired")
    menu_additem(menu, "Roles", "roles")
    FN_MenuFinish(menu)
    menu_display(id, menu, 0)
}

public MainMenuHandler(id, menu, item)
{
    if (item == MENU_EXIT || item < 0)
    {
        menu_destroy(menu)
        return PLUGIN_HANDLED
    }
    new data[16], szName[64], access, callback
    menu_item_getinfo(menu, item, access, data, charsmax(data), szName, charsmax(szName), callback)
    menu_destroy(menu)

    if (!is_user_connected(id) || !(get_user_flags(id) & FN_FLAG_MANAGER))
    {
        fn_chat_permission(id, "Manager access required.")
        return PLUGIN_HANDLED
    }

    if (equal(data, "add"))
    {
        g_iMenuMode[id] = MODE_ADD
        ShowOnlineSelect(id)
    }
    else if (equal(data, "extend"))
    {
        g_iMenuMode[id] = MODE_EXTEND
        ShowGrantSelect(id)
    }
    else if (equal(data, "revoke"))
    {
        g_iMenuMode[id] = MODE_REVOKE
        ShowGrantSelect(id)
    }
    else if (equal(data, "edit"))
    {
        g_iMenuMode[id] = MODE_EDIT
        ShowGrantSelect(id)
    }
    else if (equal(data, "online"))
        ShowGrantList(id, LIST_ONLINE)
    else if (equal(data, "all"))
        ShowGrantList(id, LIST_ALL)
    else if (equal(data, "expiring"))
        ShowGrantList(id, LIST_EXPIRING)
    else if (equal(data, "expired"))
        ShowGrantList(id, LIST_EXPIRED)
    else if (equal(data, "roles"))
        ShowRolesMenu(id)
    else
        ShowMainMenu(id)
    return PLUGIN_HANDLED
}

stock ShowOnlineSelect(id)
{
    new szTitle[64]
    FN_MenuTitle(szTitle, charsmax(szTitle), "Select player")
    new menu = menu_create(szTitle, "SelectHandler")
    new players[32], iNum
    get_players(players, iNum, "ch")
    new iAdded
    for (new i = 0; i < iNum; i++)
    {
        new p = players[i]
        if (is_user_bot(p) || is_user_hltv(p))
            continue
        // Self is shown (matrix rule: listed, denied with words at fire time).
        // Payload is a draw-time snapshot "slot userid authid" so the fire
        // handler can reject stale picks (disconnect / slot reuse).
        new szName[32], szItem[64], szData[64], szSnap[MAX_AUTH]
        get_user_name(p, szName, charsmax(szName))
        formatex(szItem, charsmax(szItem), "%s%s", szName,
            (g_iGrantRole[p] >= ROLE_MOD) ? " [grant]" : "")
        get_user_authid(p, szSnap, charsmax(szSnap))
        formatex(szData, charsmax(szData), "%d %d %s", p, get_user_userid(p), szSnap)
        menu_additem(menu, szItem, szData)
        iAdded++
    }
    if (!iAdded)
    {
        menu_destroy(menu)
        fn_chat_info(id, "No players online.")
        ShowMainMenu(id)
        return 0
    }
    FN_MenuFinish(menu, true)
    menu_display(id, menu, 0)
    return 1
}

stock ShowGrantSelect(id)
{
    new szTitle[64]
    FN_MenuTitle(szTitle, charsmax(szTitle), "Select grant")
    new menu = menu_create(szTitle, "SelectHandler")
    new players[32], iNum
    get_players(players, iNum, "ch")
    new iAdded
    for (new i = 0; i < iNum; i++)
    {
        new p = players[i]
        if (g_iGrantRole[p] < ROLE_MOD)
            continue
        // Draw-time snapshot payload "slot userid authid" (see ShowOnlineSelect).
        new szName[32], szItem[64], szData[64], szSnap[MAX_AUTH]
        get_user_name(p, szName, charsmax(szName))
        formatex(szItem, charsmax(szItem), "%s [%s]", szName, g_szRoleName[g_iGrantRole[p]])
        get_user_authid(p, szSnap, charsmax(szSnap))
        formatex(szData, charsmax(szData), "%d %d %s", p, get_user_userid(p), szSnap)
        menu_additem(menu, szItem, szData)
        iAdded++
    }
    if (!iAdded)
    {
        menu_destroy(menu)
        fn_chat_info(id, "No active grants online. Use fn_admin_grant <steamid> for offline targets.")
        ShowMainMenu(id)
        return 0
    }
    FN_MenuFinish(menu, true)
    menu_display(id, menu, 0)
    return 1
}

public SelectHandler(id, menu, item)
{
    if (item == MENU_EXIT || item < 0)
    {
        menu_destroy(menu)
        ShowMainMenu(id)
        return PLUGIN_HANDLED
    }
    new data[64], szName[64], access, callback
    menu_item_getinfo(menu, item, access, data, charsmax(data), szName, charsmax(szName), callback)
    menu_destroy(menu)

    if (!is_user_connected(id) || !(get_user_flags(id) & FN_FLAG_MANAGER))
    {
        fn_chat_permission(id, "Manager access required.")
        return PLUGIN_HANDLED
    }

    // Draw-time snapshot from the menu payload ("slot userid authid").
    // Verified BEFORE any grant use: a stale pick (disconnect / slot reuse
    // between draw and fire) is rejected instead of hitting the occupant.
    new sSlot[8], sUid[16], szSnapAuth[MAX_AUTH]
    parse(data, sSlot, charsmax(sSlot), sUid, charsmax(sUid), szSnapAuth, charsmax(szSnapAuth))
    new tid = str_to_num(sSlot)
    new iSnapUserid = str_to_num(sUid)
    if (!is_user_connected(tid) || !FN_StillSame(tid, szSnapAuth, iSnapUserid))
    {
        fn_chat_error(id, "That player is no longer available (slot changed). Please select another player.")
        ShowMainMenu(id)
        return PLUGIN_HANDLED
    }
    new iCode = FN_CheckTarget(id, tid, FN_SELF_GRANT)
    if (iCode == FN_TARGET_SELF_DENIED)
    {
        fn_chat_error(id, "You cannot use this action on yourself.")
        ShowMainMenu(id)
        return PLUGIN_HANDLED
    }
    if (iCode != FN_TARGET_OK)
    {
        fn_chat_error(id, "This player is immune to your administrative actions.")
        ShowMainMenu(id)
        return PLUGIN_HANDLED
    }

    // Verified snapshot is the source of truth downstream (it equals the
    // live authid: FN_StillSame just passed above).
    new szAuth[MAX_AUTH]
    copy(szAuth, charsmax(szAuth), szSnapAuth)
    if (!IsGrantableAuth(szAuth))
    {
        fn_chat_error(id, "Target has no grantable SteamID yet.")
        ShowMainMenu(id)
        return PLUGIN_HANDLED
    }

    g_iMenuTarget[id] = tid
    g_iMenuUserid[id] = iSnapUserid
    copy(g_szMenuAuth[id], charsmax(g_szMenuAuth[]), szAuth)

    if (g_iMenuMode[id] == MODE_REVOKE)
    {
        new szRevoker[MAX_AUTH]
        GranterName(id, szRevoker, charsmax(szRevoker))
        if (Core_RevokeAuth(szAuth, szRevoker))
            fn_chat_success(id, "Grant revoked. Base entitlements (users.ini/SQL) unchanged.")
        else
            fn_chat_info(id, "No active grant for that target.")
        ShowMainMenu(id)
        return PLUGIN_HANDLED
    }
    if (g_iMenuMode[id] == MODE_EXTEND)
    {
        new iRole, iExpire, iFlags
        if (GetGrantRow(szAuth, iRole, iExpire, iFlags) != 1)
        {
            fn_chat_info(id, "No active grant for that target.")
            ShowMainMenu(id)
            return PLUGIN_HANDLED
        }
        ShowDurationMenu(id)
        return PLUGIN_HANDLED
    }
    ShowRoleMenu(id)
    return PLUGIN_HANDLED
}

stock ShowRoleMenu(id)
{
    new szTitle[64]
    FN_MenuTitle(szTitle, charsmax(szTitle), "Select role")
    new menu = menu_create(szTitle, "RoleHandler")
    menu_additem(menu, "Moderator [e]", "1")
    menu_additem(menu, "Admin [cdeijuv]", "2")
    menu_additem(menu, "Manager [abcdeijuv]", "3")
    FN_MenuFinish(menu, true)
    menu_display(id, menu, 0)
}

public RoleHandler(id, menu, item)
{
    if (item == MENU_EXIT || item < 0)
    {
        menu_destroy(menu)
        ShowMainMenu(id)
        return PLUGIN_HANDLED
    }
    new data[8], szName[64], access, callback
    menu_item_getinfo(menu, item, access, data, charsmax(data), szName, charsmax(szName), callback)
    menu_destroy(menu)

    if (!is_user_connected(id) || !(get_user_flags(id) & FN_FLAG_MANAGER))
    {
        fn_chat_permission(id, "Manager access required.")
        return PLUGIN_HANDLED
    }

    new iRole = str_to_num(data)
    if (iRole < ROLE_MOD || iRole > ROLE_MGR)
    {
        fn_chat_error(id, "Invalid role.")
        ShowMainMenu(id)
        return PLUGIN_HANDLED
    }
    g_iMenuRole[id] = iRole

    if (g_iMenuMode[id] == MODE_EDIT)
    {
        // Edit = replace role, keep the existing expiry.
        // Fire-time revalidation: the occupant must still be the snapshotted
        // target, and hierarchy/self rules apply here too.
        new tid = g_iMenuTarget[id]
        if (is_user_connected(tid))
        {
            if (!FN_StillSame(tid, g_szMenuAuth[id], g_iMenuUserid[id]))
            {
                fn_chat_error(id, "Target changed since the menu was drawn. Please select again.")
                ShowMainMenu(id)
                return PLUGIN_HANDLED
            }
            new iCode = FN_CheckTarget(id, tid, FN_SELF_GRANT)
            if (iCode == FN_TARGET_SELF_DENIED)
            {
                fn_chat_error(id, "You cannot use this action on yourself.")
                ShowMainMenu(id)
                return PLUGIN_HANDLED
            }
            if (iCode != FN_TARGET_OK)
            {
                fn_chat_error(id, "This player is immune to your administrative actions.")
                ShowMainMenu(id)
                return PLUGIN_HANDLED
            }
        }
        new iOldRole, iOldExp, iOldFlags
        if (GetGrantRow(g_szMenuAuth[id], iOldRole, iOldExp, iOldFlags) != 1)
        {
            fn_chat_info(id, "No active grant for that target.")
            ShowMainMenu(id)
            return PLUGIN_HANDLED
        }
        new szGranter[MAX_AUTH]
        GranterName(id, szGranter, charsmax(szGranter))
        Core_GrantAuth(g_szMenuAuth[id], iRole, iOldExp, szGranter)
        fn_chat_success(id, "Grant role changed to ^4%s^1 (expiry kept).", g_szRoleName[iRole])
        ShowMainMenu(id)
        return PLUGIN_HANDLED
    }
    ShowDurationMenu(id)
    return PLUGIN_HANDLED
}

stock ShowDurationMenu(id)
{
    new szTitle[64]
    FN_MenuTitle(szTitle, charsmax(szTitle), "Select duration")
    new menu = menu_create(szTitle, "DurationHandler")
    menu_additem(menu, "1 hour", "60")
    menu_additem(menu, "1 day", "1440")
    menu_additem(menu, "7 days", "10080")
    menu_additem(menu, "30 days", "43200")
    menu_additem(menu, "Permanent", "0")
    menu_additem(menu, "Custom (console fn_admin_grant)", "custom")
    menu_additem(menu, "Date (console fn_admin_until)", "date")
    FN_MenuFinish(menu, true)
    menu_display(id, menu, 0)
}

public DurationHandler(id, menu, item)
{
    if (item == MENU_EXIT || item < 0)
    {
        menu_destroy(menu)
        ShowMainMenu(id)
        return PLUGIN_HANDLED
    }
    new data[16], szName[64], access, callback
    menu_item_getinfo(menu, item, access, data, charsmax(data), szName, charsmax(szName), callback)
    menu_destroy(menu)

    if (!is_user_connected(id) || !(get_user_flags(id) & FN_FLAG_MANAGER))
    {
        fn_chat_permission(id, "Manager access required.")
        return PLUGIN_HANDLED
    }
    if (equal(data, "custom"))
    {
        fn_chat_usage(id, "Custom: fn_admin_grant <target> <role> <minutes> (0 = permanent).")
        ShowMainMenu(id)
        return PLUGIN_HANDLED
    }
    if (equal(data, "date"))
    {
        fn_chat_usage(id, "Date: fn_admin_until <target> <YYYY-MM-DDTHH:MM>.")
        ShowMainMenu(id)
        return PLUGIN_HANDLED
    }

    new iMinutes = str_to_num(data)
    if (iMinutes < 0 || iMinutes > MAX_MINUTES || (!IsAllDigits(data)))
    {
        fn_chat_error(id, "Invalid duration.")
        ShowMainMenu(id)
        return PLUGIN_HANDLED
    }

    // Fire-time revalidation before BOTH extend and grant paths: the slot
    // must still hold the snapshotted target, and FN_CheckTarget applies
    // (self-denied vs immune are distinct messages; manager gate above).
    new tid = g_iMenuTarget[id]
    if (g_iMenuMode[id] != MODE_EXTEND)
    {
        if (!is_user_connected(tid) || !FN_StillSame(tid, g_szMenuAuth[id], g_iMenuUserid[id]))
        {
            fn_chat_error(id, "This player is no longer connected. Please select another player.")
            ShowMainMenu(id)
            return PLUGIN_HANDLED
        }
        new iCode = FN_CheckTarget(id, tid, FN_SELF_GRANT)
        if (iCode == FN_TARGET_SELF_DENIED)
        {
            fn_chat_error(id, "You cannot use this action on yourself.")
            ShowMainMenu(id)
            return PLUGIN_HANDLED
        }
        if (iCode != FN_TARGET_OK)
        {
            fn_chat_error(id, "This player is immune to your administrative actions.")
            ShowMainMenu(id)
            return PLUGIN_HANDLED
        }
    }
    else
    {
        new p = FindOnlineByAuth(g_szMenuAuth[id])
        if (p <= 0)
        {
            fn_chat_error(id, "This player is no longer connected. Please select another player.")
            ShowMainMenu(id)
            return PLUGIN_HANDLED
        }
        tid = p
        g_iMenuTarget[id] = p
        // Fire-time identity compare: the occupant must still hold the
        // snapshotted authid (slot-reuse guard; same person may reconnect).
        new szNow[MAX_AUTH]
        get_user_authid(tid, szNow, charsmax(szNow))
        if (!equal(szNow, g_szMenuAuth[id]))
        {
            fn_chat_error(id, "Target changed since the menu was drawn. Please select again.")
            ShowMainMenu(id)
            return PLUGIN_HANDLED
        }
        new iCode = FN_CheckTarget(id, tid, FN_SELF_GRANT)
        if (iCode == FN_TARGET_SELF_DENIED)
        {
            fn_chat_error(id, "You cannot use this action on yourself.")
            ShowMainMenu(id)
            return PLUGIN_HANDLED
        }
        if (iCode != FN_TARGET_OK)
        {
            fn_chat_error(id, "This player is immune to your administrative actions.")
            ShowMainMenu(id)
            return PLUGIN_HANDLED
        }
    }

    new szGranter[MAX_AUTH]
    GranterName(id, szGranter, charsmax(szGranter))

    if (g_iMenuMode[id] == MODE_EXTEND)
    {
        if (iMinutes == 0)
        {
            // Extend-to-permanent: rewrite the row with expire 0.
            new iOldRole, iOldExp, iOldFlags
            if (GetGrantRow(g_szMenuAuth[id], iOldRole, iOldExp, iOldFlags) != 1)
            {
                fn_chat_info(id, "No active grant for that target.")
                ShowMainMenu(id)
                return PLUGIN_HANDLED
            }
            Core_GrantAuth(g_szMenuAuth[id], iOldRole, 0, szGranter)
            fn_chat_success(id, "Grant is now ^3permanent^1.")
        }
        else
        {
            new iNew = Core_ExtendAuth(g_szMenuAuth[id], iMinutes, szGranter)
            if (iNew < 0)
                fn_chat_error(id, "No active grant for that target.")
            else if (iNew == 0)
                fn_chat_success(id, "Grant is permanent - nothing to extend.")
            else
            {
                new szExp[64]
                FN_ExpiryText(iNew, szExp, charsmax(szExp))
                fn_chat_success(id, "Grant extended by %d minutes. New expiry: %s.", iMinutes, szExp)
            }
        }
        ShowMainMenu(id)
        return PLUGIN_HANDLED
    }

    new iExpire = (iMinutes == 0) ? 0 : (get_systime() + iMinutes * 60)
    Core_GrantAuth(g_szMenuAuth[id], g_iMenuRole[id], iExpire, szGranter)
    new szExp[64]
    FN_ExpiryText(iExpire, szExp, charsmax(szExp))
    fn_chat_success(id, "Granted ^4%s^1 (expires %s).", g_szRoleName[g_iMenuRole[id]], szExp)
    ShowMainMenu(id)
    return PLUGIN_HANDLED
}

stock ShowGrantList(id, iKind)
{
    g_iMenuList[id] = iKind
    new szTitle[64]
    new szHead[24]
    if (iKind == LIST_ALL) copy(szHead, charsmax(szHead), "All grants")
    else if (iKind == LIST_EXPIRING) copy(szHead, charsmax(szHead), "Expiring soon")
    else if (iKind == LIST_EXPIRED) copy(szHead, charsmax(szHead), "Expired log")
    else copy(szHead, charsmax(szHead), "Online grants")
    FN_MenuTitle(szTitle, charsmax(szTitle), szHead)
    new menu = menu_create(szTitle, "ListHandler")

    new iAdded
    if (iKind == LIST_EXPIRED)
        iAdded = FillExpiredList(menu)
    else if (iKind == LIST_ALL)
        iAdded = FillAllList(menu)
    else
        iAdded = FillOnlineList(menu, iKind)

    if (!iAdded)
    {
        menu_destroy(menu)
        fn_chat_info(id, "Nothing to show here.")
        ShowMainMenu(id)
        return 0
    }
    FN_MenuFinish(menu, true)
    menu_display(id, menu, 0)
    return 1
}

stock FillOnlineList(menu, iKind)
{
    new iAdded
    new iNow = get_systime()
    new players[32], iNum
    get_players(players, iNum, "ch")
    for (new i = 0; i < iNum && iAdded < 64; i++)
    {
        new p = players[i]
        if (g_iGrantRole[p] < ROLE_MOD)
            continue
        if (iKind == LIST_EXPIRING)
        {
            if (g_iGrantExpire[p] == 0 || g_iGrantExpire[p] - iNow >= 7 * 86400)
                continue
        }
        new szName[32], szItem[96], szData[48]
        get_user_name(p, szName, charsmax(szName))
        new szExp[64]
        FN_ExpiryText(g_iGrantExpire[p], szExp, charsmax(szExp))
        formatex(szItem, charsmax(szItem), "%s [%s] %s", szName, g_szRoleName[g_iGrantRole[p]], szExp)
        SanitizeAuth(g_szGrantAuth[p], szData, charsmax(szData))
        menu_additem(menu, szItem, szData)
        iAdded++
    }
    return iAdded
}

stock FillAllList(menu)
{
    // Online rows first, then indexed offline rows (nVault has no enumeration).
    new iAdded = FillOnlineList(menu, LIST_ONLINE)
    new szIndex[MAX_INDEX + 1]
    if (!IndexLoad(szIndex, charsmax(szIndex)) || !szIndex[0])
        return iAdded
    new szTok[48]
    new iPos = 0
    new iLen = strlen(szIndex)
    new iTok = 0
    while (iPos <= iLen && iAdded < 64)
    {
        new c = (iPos < iLen) ? szIndex[iPos] : 32
        if (c == 32 || c == 9)
        {
            if (iTok > 0)
            {
                szTok[iTok] = 0
                if (FindOnlineBySan(szTok) <= 0)
                    iAdded += FillIndexRow(menu, szTok)
                iTok = 0
            }
        }
        else if (iTok < charsmax(szTok) - 1)
            szTok[iTok++] = c
        iPos++
    }
    return iAdded
}

stock FillIndexRow(menu, const szSan[])
{
    new szKey[MAX_GRANT_KEY]
    formatex(szKey, charsmax(szKey), "grant#%s", szSan)
    new szValue[128], iStamp
    if (g_iVault == INVALID_HANDLE)
        return 0
    if (!nvault_lookup(g_iVault, szKey, szValue, charsmax(szValue), iStamp))
        return 0
    new iRole, iExpire, iFlags
    new szRowAuth[MAX_AUTH]
    if (!ParseGrantValue(szValue, iRole, iExpire, iFlags, szRowAuth, charsmax(szRowAuth)))
        return 0
    new szItem[96]
    new szExp[64]
    FN_ExpiryText(iExpire, szExp, charsmax(szExp))
    formatex(szItem, charsmax(szItem), "%s [%s] %s (offline)",
        szRowAuth[0] ? szRowAuth : szSan, g_szRoleName[iRole], szExp)
    menu_additem(menu, szItem, szSan)
    return 1
}

stock FillExpiredList(menu)
{
    new iAdded
    for (new i = 0; i < 10 && iAdded < 10; i++)
    {
        new idx = (g_iExpiredPos - 1 - i + 100) % 10
        if (!g_szLastExpired[idx][0])
            continue
        new szData[8]
        num_to_str(idx, szData, charsmax(szData))
        menu_additem(menu, g_szLastExpired[idx], szData)
        iAdded++
    }
    return iAdded
}

public ListHandler(id, menu, item)
{
    if (item == MENU_EXIT || item < 0)
    {
        menu_destroy(menu)
        ShowMainMenu(id)
        return PLUGIN_HANDLED
    }
    new data[48], szName[96], access, callback
    menu_item_getinfo(menu, item, access, data, charsmax(data), szName, charsmax(szName), callback)
    new iKind = g_iMenuList[id]
    menu_destroy(menu)

    if (g_iMenuList[id] == LIST_EXPIRED)
    {
        fn_chat_info(id, "%s", szName)
        ShowGrantList(id, iKind)
        return PLUGIN_HANDLED
    }

    // Detail for the picked row (sanitized auth token in data).
    new szKey[MAX_GRANT_KEY]
    formatex(szKey, charsmax(szKey), "grant#%s", data)
    if (g_iVault != INVALID_HANDLE)
    {
        new szValue[128], iStamp
        if (nvault_lookup(g_iVault, szKey, szValue, charsmax(szValue), iStamp))
        {
            new iRole, iExpire, iFlags
            new szRowAuth[MAX_AUTH]
            if (ParseGrantValue(szValue, iRole, iExpire, iFlags, szRowAuth, charsmax(szRowAuth)))
            {
                new szExp[64]
                FN_ExpiryText(iExpire, szExp, charsmax(szExp))
                fn_chat_info(id, "%s: ^4%s^1, expires %s.", szRowAuth[0] ? szRowAuth : data, g_szRoleName[iRole], szExp)
            }
        }
    }
    ShowGrantList(id, iKind)
    return PLUGIN_HANDLED
}

stock ShowRolesMenu(id)
{
    new szTitle[64]
    FN_MenuTitle(szTitle, charsmax(szTitle), "Roles")
    new menu = menu_create(szTitle, "RolesHandler")
    menu_additem(menu, "Moderator - flag e", "1")
    menu_additem(menu, "Admin - flags cdeijuv", "2")
    menu_additem(menu, "Manager - flags abcdeijuv", "3")
    FN_MenuFinish(menu, true)
    menu_display(id, menu, 0)
}

public RolesHandler(id, menu, item)
{
    if (item == MENU_EXIT || item < 0)
    {
        menu_destroy(menu)
        ShowMainMenu(id)
        return PLUGIN_HANDLED
    }
    new data[8], szName[64], access, callback
    menu_item_getinfo(menu, item, access, data, charsmax(data), szName, charsmax(szName), callback)
    menu_destroy(menu)
    new iRole = str_to_num(data)
    if (iRole == ROLE_MOD)
        fn_chat_info(id, "Role ^4moderator^1: flag e. Moderates regulars only.")
    else if (iRole == ROLE_ADMIN)
        fn_chat_info(id, "Role ^4admin^1: flags cdeijuv. Full admin set.")
    else if (iRole == ROLE_MGR)
        fn_chat_info(id, "Role ^4manager^1: flags abcdeijuv. Top of the chain.")
    ShowRolesMenu(id)
    return PLUGIN_HANDLED
}


// ============================================================================
// NATIVES (fn_admin_*). Mutating natives take an invoker and enforce the same
// gate as the commands: invoker 0 (console/RCON) passes, live invokers need
// the manager flag and must pass FN_CheckTarget (self-grant always denied).
// There is deliberately NO unrestricted grant native.
// ============================================================================

stock NativeGate(iInvoker, iTarget)
{
    if (iInvoker == 0)
        return FN_TARGET_OK
    if (!is_user_connected(iInvoker))
        return FN_TARGET_DISCONNECTED
    if (!(get_user_flags(iInvoker) & FN_FLAG_MANAGER))
        return FN_TARGET_IMMUNE
    return FN_CheckTarget(iInvoker, iTarget, FN_SELF_GRANT)
}

stock NativeAuthOf(iTarget, szAuth[], iLen)
{
    if (iTarget < 1 || iTarget > 32 || !is_user_connected(iTarget))
        return 0
    get_user_authid(iTarget, szAuth, iLen)
    return IsGrantableAuth(szAuth) ? 1 : 0
}

public _nGrant(plugin, params)
{
    new iInvoker = get_param(1)
    new iTarget = get_param(2)
    new szRole[16]
    get_string(3, szRole, charsmax(szRole))
    new iMinutes = get_param(4)

    if (NativeGate(iInvoker, iTarget) != FN_TARGET_OK)
        return -1
    new szAuth[MAX_AUTH]
    if (!NativeAuthOf(iTarget, szAuth, charsmax(szAuth)))
        return 0
    new iRole = ParseRole(szRole)
    if (iRole == ROLE_NONE || iMinutes < 0 || iMinutes > MAX_MINUTES)
        return 0

    new iExpire = (iMinutes == 0) ? 0 : (get_systime() + iMinutes * 60)
    new szGranter[MAX_AUTH]
    GranterName(iInvoker, szGranter, charsmax(szGranter))
    return Core_GrantAuth(szAuth, iRole, iExpire, szGranter) ? 1 : 0
}

public _nRevoke(plugin, params)
{
    new iInvoker = get_param(1)
    new iTarget = get_param(2)
    if (NativeGate(iInvoker, iTarget) != FN_TARGET_OK)
        return -1
    new szAuth[MAX_AUTH]
    if (!NativeAuthOf(iTarget, szAuth, charsmax(szAuth)))
        return 0
    new szRevoker[MAX_AUTH]
    GranterName(iInvoker, szRevoker, charsmax(szRevoker))
    return Core_RevokeAuth(szAuth, szRevoker) ? 1 : 0
}

public _nExtend(plugin, params)
{
    new iInvoker = get_param(1)
    new iTarget = get_param(2)
    new iMinutes = get_param(3)
    if (NativeGate(iInvoker, iTarget) != FN_TARGET_OK)
        return -1
    if (iMinutes <= 0 || iMinutes > MAX_MINUTES)
        return 0
    new szAuth[MAX_AUTH]
    if (!NativeAuthOf(iTarget, szAuth, charsmax(szAuth)))
        return 0
    new szExtender[MAX_AUTH]
    GranterName(iInvoker, szExtender, charsmax(szExtender))
    new iNew = Core_ExtendAuth(szAuth, iMinutes, szExtender)
    return (iNew < 0) ? 0 : 1
}

public _nRemaining(plugin, params)
{
    new iTarget = get_param(1)
    if (iTarget < 1 || iTarget > 32 || !is_user_connected(iTarget))
        return 0
    if (g_iGrantRole[iTarget] < ROLE_MOD)
    {
        // Fall back to the vault row (cache may predate this map).
        new szAuth[MAX_AUTH]
        get_user_authid(iTarget, szAuth, charsmax(szAuth))
        new iRole, iExpire, iFlags
        if (GetGrantRow(szAuth, iRole, iExpire, iFlags) != 1)
            return 0
        if (iExpire == 0)
            return -1
        new iLeft = iExpire - get_systime()
        return (iLeft > 0) ? iLeft : 0
    }
    if (g_iGrantExpire[iTarget] == 0)
        return -1   // permanent
    new iLeft = g_iGrantExpire[iTarget] - get_systime()
    return (iLeft > 0) ? iLeft : 0
}

public _nHas(plugin, params)
{
    new iTarget = get_param(1)
    if (iTarget < 1 || iTarget > 32 || !is_user_connected(iTarget))
        return 0
    if (g_iGrantRole[iTarget] >= ROLE_MOD)
    {
        if (g_iGrantExpire[iTarget] == 0)
            return 1
        return (get_systime() < g_iGrantExpire[iTarget]) ? 1 : 0
    }
    new szAuth[MAX_AUTH]
    get_user_authid(iTarget, szAuth, charsmax(szAuth))
    new iRole, iExpire, iFlags
    return (GetGrantRow(szAuth, iRole, iExpire, iFlags) == 1) ? 1 : 0
}

public _nGetExpire(plugin, params)
{
    new iTarget = get_param(1)
    if (iTarget < 1 || iTarget > 32 || !is_user_connected(iTarget))
        return 0
    if (g_iGrantRole[iTarget] >= ROLE_MOD)
        return g_iGrantExpire[iTarget]   // 0 = permanent
    new szAuth[MAX_AUTH]
    get_user_authid(iTarget, szAuth, charsmax(szAuth))
    new iRole, iExpire, iFlags
    if (GetGrantRow(szAuth, iRole, iExpire, iFlags) == 1)
        return iExpire
    return 0
}
