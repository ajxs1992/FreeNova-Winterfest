/*
 * ============================================================================
 * FreeNova Random Events  (freenova_randevent)
 * ============================================================================
 * Event driver with two modes that share one owner-cvar contract:
 *
 *   dice      - what this plugin has always done: after fn_re_min..fn_re_max
 *               minutes pick one available flavour at random and hold it for
 *               fn_re_duration minutes. This is the default, so removing
 *               configs/freenova/events.ini leaves the server exactly as it was.
 *   schedule  - configs/freenova/events.ini names up to 16 windows
 *               (weekday set + start/end clock time + flavour + multiplier) and
 *               the plugin opens and closes them on the wall clock. A window
 *               that is already open when the map starts is re-opened for the
 *               time that is left, not restarted.
 *
 * mode = random | schedule | both, from [settings] in that file.
 *
 * OWNERSHIP (read-only here; this plugin only WRITES values, never registers
 * the cvars — set via get_cvar_pointer + set_pcvar_*, never register_cvar):
 *   fn_event_xp_mult    (float, 1.0 = off) - owned by freenova_sync
 *   fn_event_coins_mult (float, 1.0 = off) - owned by freenova_sync
 *   fn_double_xp        (int, 0 = off)      - owned by freenova_panel
 *   fn_happy_hour       (float, 1.0 = off)  - owned by freenova_progression
 *
 * SKIP-WHEN-ACTIVE (checked at every fire; float compare tolerance 0.001):
 *   fn_event_xp_mult != 1.0 OR fn_event_coins_mult != 1.0 OR
 *   fn_double_xp != 0 OR fn_happy_hour != 1.0  -> event active, skip firing,
 *   log only (no chat spam), retry on the next tick / in FN_RE_RETRY_MIN minutes.
 *
 * EVENT FLAVORS (a flavour whose owner cvar does not exist, e.g. owner plugin
 * absent, is excluded and can never be picked):
 *   xp      -> fn_event_xp_mult    = 1.5..3.0 (default; [flavor] overrides)
 *   coins   -> fn_event_coins_mult = 1.5..3.0
 *   double  -> fn_double_xp        = 1 (panel 1/0 int contract)
 *   happy   -> fn_happy_hour       = 2.0
 * Magnitudes are clamped to 1.0..5.0, the range freenova_sync's ClampEventMult
 * accepts. A [map] multiplier for the current map scales the magnitude on top
 * of that (double is a boolean and is never scaled).
 *
 * HAPPY-HOUR NOTE: freenova_progression TaskHappyHour rewrites fn_happy_hour
 * every 30s from its schedule. During a happy_hour event this plugin
 * re-asserts the event value every 20s until revert, then restores the prior
 * value so the schedule resumes cleanly. This re-assert loop runs ONLY while
 * OUR event is active; scheduled/progression happy hours are detected by the
 * skip check and never overridden at fire time.
 *
 * DURATION: dice events hold fn_re_duration minutes. Scheduled windows hold
 * until the window's end time. Chat announce (client_print_color to all) + HUD
 * announce (set_hudmessage channel -1 = auto-select, 5s hold) on start AND end.
 *
 * NEVER STACK (this is the part REVIEW.md 5.2 broke and round one fixed):
 *   - every fire stores the value it replaced and the value it wrote;
 *   - a revert only writes the stored prior if the cvar still holds OUR value,
 *     so a panel-driven event that took over is never clobbered;
 *   - the prior travels in the vault record (freenova_randevent, key "state"), so
 *     a map change or a restart in the middle of a window restores the PRIOR
 *     instead of treating the boosted value as the new baseline, and never
 *     multiplies a multiplier;
 *   - plugin_end reverts, as before, and leaves the record saying "reverted,
 *     window still open" so the next map re-opens the window cleanly.
 *
 * Cvars (fn_re_*, owned here - unchanged, defaults unchanged):
 *   fn_re_enabled   1  - master switch (dice AND windows)
 *   fn_re_min       20 - minutes between dice events (random window low end)
 *   fn_re_max       45 - minutes between dice events (random window high end)
 *   fn_re_duration  10 - dice event length in minutes before revert
 * ============================================================================
 */

#include <amxmodx>
#include <amxmisc>
#include <fn_common>
#include <nvault>

#define PLUGIN  "FreeNova Random Events"
#define VERSION "1.1.0"
#define AUTHOR  "FreeNova"

#define TASK_FIRE   63001
#define TASK_END    63002
#define TASK_ASSERT 63003
#define TASK_TICK   63004

#define FN_RE_RETRY_MIN 5       // retry delay after a skip (minutes)
#define FN_RE_ASSERT_SEC 20.0   // happy-hour re-assert period (seconds)
#define FN_RE_TICK_SEC 30.0     // window scheduler period (seconds)
#define FLOAT_TOL 0.001

// Owner-cvar value range accepted downstream (freenova_sync ClampEventMult).
#define EVENT_MIN_MULT 1.0
#define EVENT_MAX_MULT 5.0

#define CFG_FILE       "freenova/events.ini"
// Its OWN vault, not the shared "freenova_events" one: AMXX nvault hands the
// same handle to every plugin that opens the same name, and nvault_close from
// one plugin invalidates it for the other. freenova_sync keeps event-reward
// flags in freenova_events, so when both closed it in plugin_end one of them -
// here - got "Invalid vault id" and a run time error on EVERY map change
// (observed in the harness). The record this plugin keeps is one transient
// window key ("state"), so the split costs at most one window's resume.
#define VAULT_NAME     "freenova_randevent"
#define VAULT_STATE    "state"

#define MODE_RANDOM   0
#define MODE_SCHEDULE 1
#define MODE_BOTH     2

#define FLAVOR_XP     0
#define FLAVOR_COINS  1
#define FLAVOR_DOUBLE 2
#define FLAVOR_HAPPY  3
#define FLAVOR_COUNT  4

#define MAX_WINDOWS   16
#define MAX_MAPS      32

new g_pCvarEnabled
new g_pCvarMin
new g_pCvarMax
new g_pCvarDuration

new const g_szFlavorName[FLAVOR_COUNT][] = {"xp", "coins", "double", "happy"}
// The owner cvar of each flavour - the only channels this plugin can drive.
new const g_szOwnerCvar[FLAVOR_COUNT][] = {
    "fn_event_xp_mult", "fn_event_coins_mult", "fn_double_xp", "fn_happy_hour"
}
new g_iActiveFlavor = -1   // -1 = idle, else FLAVOR_*
new g_iSavedDouble = 0
new Float:g_fSavedXp = 1.0
new Float:g_fSavedCoins = 1.0
new Float:g_fSavedHappy = 1.0
new Float:g_fEventValue = 1.0
new g_iActiveWindow = -1   // window index driving the current event, -1 = dice

new g_Vault = INVALID_HANDLE
new bool:g_bCfgLoaded = false
new g_iMode = MODE_RANDOM

// [flavor] - weight 0 disables the flavour entirely.
new g_iFlavWeight[FLAVOR_COUNT]
new Float:g_fFlavMin[FLAVOR_COUNT]
new Float:g_fFlavMax[FLAVOR_COUNT]

// [window] rows, in file order.
new g_iWinCount
new g_szWinId[MAX_WINDOWS][32]
new g_iWinDays[MAX_WINDOWS]        // bitmask, bit 0 = Sunday
new g_iWinStart[MAX_WINDOWS]       // HHMM as an int (2000 = 20:00)
new g_iWinEnd[MAX_WINDOWS]
new g_iWinFlavor[MAX_WINDOWS]      // -1 = roll from the [flavor] pool
new Float:g_fWinMult[MAX_WINDOWS]  // <= 0 = roll the flavour's min..max

// [map] rows: magnitude scaling for one map.
new g_iMapCount
new g_szMapName[MAX_MAPS][32]
new Float:g_fMapMult[MAX_MAPS]

// Persisted window state (see NEVER STACK above).
new g_iStateWindow = -1
new g_szStateUntil[16]             // "YYYYMMDDHHMM" of the window end
new bool:g_bStateApplied = false

public plugin_init()
{
    fn_boot_banner("randevent", 4)

    register_plugin(PLUGIN, VERSION, AUTHOR)

    g_pCvarEnabled  = register_cvar("fn_re_enabled", "1")
    g_pCvarMin      = register_cvar("fn_re_min", "20")
    g_pCvarMax      = register_cvar("fn_re_max", "45")
    g_pCvarDuration = register_cvar("fn_re_duration", "10")

    g_Vault = nvault_open(VAULT_NAME)
    if (g_Vault == INVALID_HANDLE)
        log_amx("[FreeNova][RandEvent] nvault %s failed to open - window state will not survive a map change", VAULT_NAME)

    LoadEventsConfig()
}

public plugin_cfg()
{
    // Per-map state: never inherit an active flavour from an in-place reload.
    g_iActiveFlavor = -1
    g_iActiveWindow = -1

    if (!g_bCfgLoaded)
        LoadEventsConfig()

    RestoreState()
    ArmDriver()
}

public plugin_end()
{
    remove_task(TASK_FIRE)
    remove_task(TASK_END)
    remove_task(TASK_ASSERT)
    remove_task(TASK_TICK)

    if (g_iActiveFlavor == -1)
    {
        CloseVault()
        return
    }

    // REVIEW.md 5.2: an event that fired just before a map change used to leave
    // its owner cvar boosted for ever (AnyEventActive() stayed true, Task_Fire
    // retried for ever and Task_End could never run). Revert exactly as
    // Task_End() does, then record that the window is still open so the next
    // map re-opens it with the ORIGINAL prior, not with the boosted value.
    RevertEvent()
    log_amx("[FreeNova][RandEvent] unloaded mid-event: flavor=%d window=%d restored", g_iActiveFlavor, g_iActiveWindow)
    SaveState(false)
    g_iActiveFlavor = -1
    g_iActiveWindow = -1
    CloseVault()
}

CloseVault()
{
    // freenova_randevent is this plugin's own vault (see VAULT_NAME), so
    // closing it here cannot invalidate another plugin's handle - the bug the
    // shared "freenova_events" name caused on every map change.
    if (g_Vault != INVALID_HANDLE)
    {
        nvault_close(g_Vault)
        g_Vault = INVALID_HANDLE
    }
}

// --- config: configs/freenova/events.ini ------------------------------------
// Sections: [settings] key = value, then pipe-separated rows in [flavor],
// [window] and [map]. Schema: the file's own header and docs/RETENTION.md.

ResetConfig()
{
    g_bCfgLoaded = false
    g_iMode = MODE_RANDOM
    g_iWinCount = 0
    g_iMapCount = 0
    for (new i; i < FLAVOR_COUNT; i++)
    {
        g_iFlavWeight[i] = 25
        if (i == FLAVOR_XP || i == FLAVOR_COINS)
        {
            g_fFlavMin[i] = 1.5
            g_fFlavMax[i] = 3.0
        }
        else if (i == FLAVOR_HAPPY)
        {
            g_fFlavMin[i] = 2.0
            g_fFlavMax[i] = 2.0
        }
        else
        {
            g_fFlavMin[i] = 1.0
            g_fFlavMax[i] = 1.0
        }
    }
}

FlavorFromName(const szName[])
{
    for (new i; i < FLAVOR_COUNT; i++)
        if (equali(szName, g_szFlavorName[i]))
            return i
    return -1
}

StripConfigLine(szLine[])
{
    for (new i; szLine[i]; i++)
    {
        if (szLine[i] == ';' || szLine[i] == '#')
        {
            szLine[i] = 0
            break
        }
    }
    trim(szLine)
}

ParseSettingLine(const szLine[], iLine)
{
    new szLeft[64], szRight[128]
    strtok(szLine, szLeft, charsmax(szLeft), szRight, charsmax(szRight), '=')
    trim(szLeft)
    trim(szRight)
    if (!szLeft[0] || !szRight[0])
    {
        log_amx("[FreeNova][RandEvent] events.ini:%d skipped: settings line is not 'key = value'", iLine)
        return
    }
    if (equali(szLeft, "mode"))
    {
        if (equali(szRight, "random"))
            g_iMode = MODE_RANDOM
        else if (equali(szRight, "schedule"))
            g_iMode = MODE_SCHEDULE
        else if (equali(szRight, "both"))
            g_iMode = MODE_BOTH
        else
            log_amx("[FreeNova][RandEvent] events.ini:%d mode '%s' is not random, schedule or both - staying on random",
                iLine, szRight)
    }
    else if (equali(szLeft, "flavor") || equali(szLeft, "flavour"))
    {
        // Convenience form: "flavor = xp=25,coins=25,double=0,happy=25"
        // turns flavours on/off (weight) without a [flavor] block.
        new szPair[64], szRest[128], szLeftOver[128]
        copy(szRest, charsmax(szRest), szRight)
        while (szRest[0])
        {
            strtok(szRest, szPair, charsmax(szPair), szLeftOver, charsmax(szLeftOver), ',')
            trim(szPair)
            new szName[16], szWeight[16], szTmp[64]
            strtok(szPair, szName, charsmax(szName), szTmp, charsmax(szTmp), '=')
            trim(szName)
            trim(szTmp)
            copy(szWeight, charsmax(szWeight), szTmp)
            new iFlavor = FlavorFromName(szName)
            if (iFlavor < 0)
                log_amx("[FreeNova][RandEvent] events.ini:%d unknown flavor '%s' ignored", iLine, szName)
            else
                g_iFlavWeight[iFlavor] = max(0, str_to_num(szWeight))
            copy(szRest, charsmax(szRest), szLeftOver)
        }
    }
    else
        log_amx("[FreeNova][RandEvent] events.ini:%d unknown setting '%s' ignored", iLine, szLeft)
}

// id | weight | min | max
ParseFlavorLine(const szLine[], iLine)
{
    new szField[4][32]
    new iFields = SplitFields(szLine, szField, 4)
    if (iFields < 2)
    {
        log_amx("[FreeNova][RandEvent] events.ini:%d skipped: flavor needs 'name | weight [| min | max]'", iLine)
        return
    }
    new iFlavor = FlavorFromName(szField[0])
    if (iFlavor < 0)
    {
        log_amx("[FreeNova][RandEvent] events.ini:%d skipped: flavor '%s' is not xp, coins, double or happy",
            iLine, szField[0])
        return
    }
    g_iFlavWeight[iFlavor] = max(0, str_to_num(szField[1]))
    if (iFields > 2 && szField[2][0])
    {
        new Float:fMin = str_to_float(szField[2])
        if (fMin < EVENT_MIN_MULT)
            fMin = EVENT_MIN_MULT
        if (fMin > EVENT_MAX_MULT)
            fMin = EVENT_MAX_MULT
        g_fFlavMin[iFlavor] = fMin
    }
    if (iFields > 3 && szField[3][0])
    {
        new Float:fMax = str_to_float(szField[3])
        if (fMax < EVENT_MIN_MULT)
            fMax = EVENT_MIN_MULT
        if (fMax > EVENT_MAX_MULT)
            fMax = EVENT_MAX_MULT
        g_fFlavMax[iFlavor] = fMax
    }
    if (g_fFlavMax[iFlavor] < g_fFlavMin[iFlavor])
    {
        log_amx("[FreeNova][RandEvent] events.ini:%d flavor '%s': max below min, using min for both",
            iLine, szField[0])
        g_fFlavMax[iFlavor] = g_fFlavMin[iFlavor]
    }
}

// id | days | start | end | flavor | multiplier
ParseWindowLine(const szLine[], iLine)
{
    if (g_iWinCount >= MAX_WINDOWS)
    {
        log_amx("[FreeNova][RandEvent] events.ini:%d skipped: window limit %d reached", iLine, MAX_WINDOWS)
        return
    }
    new szField[6][32]
    new iFields = SplitFields(szLine, szField, 6)
    if (iFields < 4)
    {
        log_amx("[FreeNova][RandEvent] events.ini:%d skipped: window needs 'id | days | start | end'", iLine)
        return
    }
    new iDays = ParseDays(szField[1])
    if (iDays <= 0)
    {
        log_amx("[FreeNova][RandEvent] events.ini:%d '%s' skipped: days '%s' selects no weekday",
            iLine, szField[0], szField[1])
        return
    }
    new iStart = ParseHHMM(szField[2])
    new iEnd = ParseHHMM(szField[3])
    if (iStart < 0 || iEnd < 0)
    {
        log_amx("[FreeNova][RandEvent] events.ini:%d '%s' skipped: start/end must be HH:MM",
            iLine, szField[0])
        return
    }
    if (iEnd <= iStart)
    {
        log_amx("[FreeNova][RandEvent] events.ini:%d '%s' skipped: end %04d must be after start %04d (a window cannot cross midnight)",
            iLine, szField[0], iEnd, iStart)
        return
    }
    new iFlavor = -1
    if (iFields > 4 && szField[4][0] && !equal(szField[4], "-"))
    {
        iFlavor = FlavorFromName(szField[4])
        if (iFlavor < 0)
        {
            log_amx("[FreeNova][RandEvent] events.ini:%d '%s' skipped: flavor '%s' is not xp, coins, double or happy",
                iLine, szField[0], szField[4])
            return
        }
    }
    new Float:fMult = 0.0
    if (iFields > 5 && szField[5][0])
        fMult = str_to_float(szField[5])

    new iWin = g_iWinCount
    g_iWinCount++
    copy(g_szWinId[iWin], charsmax(g_szWinId[]), szField[0])
    g_iWinDays[iWin] = iDays
    g_iWinStart[iWin] = iStart
    g_iWinEnd[iWin] = iEnd
    g_iWinFlavor[iWin] = iFlavor
    g_fWinMult[iWin] = fMult
}

// map | multiplier
ParseMapLine(const szLine[], iLine)
{
    if (g_iMapCount >= MAX_MAPS)
    {
        log_amx("[FreeNova][RandEvent] events.ini:%d skipped: map limit %d reached", iLine, MAX_MAPS)
        return
    }
    new szField[2][32]
    new iFields = SplitFields(szLine, szField, 2)
    if (iFields < 2 || !szField[0][0] || !szField[1][0])
    {
        log_amx("[FreeNova][RandEvent] events.ini:%d skipped: map row needs 'map | multiplier'", iLine)
        return
    }
    new Float:fMult = str_to_float(szField[1])
    if (fMult < EVENT_MIN_MULT || fMult > EVENT_MAX_MULT)
    {
        log_amx("[FreeNova][RandEvent] events.ini:%d '%s': multiplier %.2f clamped to %.1f..%.1f",
            iLine, szField[0], fMult, EVENT_MIN_MULT, EVENT_MAX_MULT)
        fMult = floatclamp(fMult, EVENT_MIN_MULT, EVENT_MAX_MULT)
    }
    copy(g_szMapName[g_iMapCount], charsmax(g_szMapName[]), szField[0])
    g_fMapMult[g_iMapCount] = fMult
    g_iMapCount++
}

// Splits a pipe-separated row in place; returns the number of fields (1..iMax).
SplitFields(const szLine[], szOut[][32], iMax)
{
    new szRest[256], szRight[256], iFields
    copy(szRest, charsmax(szRest), szLine)
    while (iFields < iMax)
    {
        strtok(szRest, szOut[iFields], charsmax(szOut[]), szRight, charsmax(szRight), '|')
        trim(szOut[iFields])
        iFields++
        if (!szRight[0])
            break
        copy(szRest, charsmax(szRest), szRight)
    }
    return iFields
}

// "sun,mon,fri" or "0,1,5" (0 = Sunday). Returns a bitmask, 0 = nothing matched.
ParseDays(const szDays[])
{
    new iMask, szRest[64], szPart[32], szLeft[64]
    copy(szRest, charsmax(szRest), szDays)
    while (szRest[0])
    {
        strtok(szRest, szPart, charsmax(szPart), szLeft, charsmax(szLeft), ',')
        trim(szPart)
        if (szPart[0])
        {
            new iDay = -1
            if (equali(szPart, "sun") || equal(szPart, "sunday")) iDay = 0
            else if (equali(szPart, "mon") || equali(szPart, "monday")) iDay = 1
            else if (equali(szPart, "tue") || equali(szPart, "tuesday")) iDay = 2
            else if (equali(szPart, "wed") || equali(szPart, "wednesday")) iDay = 3
            else if (equali(szPart, "thu") || equali(szPart, "thursday")) iDay = 4
            else if (equali(szPart, "fri") || equali(szPart, "friday")) iDay = 5
            else if (equali(szPart, "sat") || equali(szPart, "saturday")) iDay = 6
            else if (equali(szPart, "weekday")) iDay = 10
            else if (equali(szPart, "weekend")) iDay = 11
            else
            {
                new iNum = str_to_num(szPart)
                if (iNum >= 0 && iNum <= 6 && szPart[0] >= '0' && szPart[0] <= '9')
                    iDay = iNum
            }
            if (iDay == 10)
                iMask |= (1 << 1) | (1 << 2) | (1 << 3) | (1 << 4) | (1 << 5)
            else if (iDay == 11)
                iMask |= (1 << 0) | (1 << 6)
            else if (iDay >= 0)
                iMask |= (1 << iDay)
            else
                log_amx("[FreeNova][RandEvent] events.ini: day '%s' not understood", szPart)
        }
        copy(szRest, charsmax(szRest), szLeft)
    }
    return iMask
}

// "20:00" / "2000" / "20" -> 2000. -1 when it is not a clock time.
ParseHHMM(const szText[])
{
    new szLeft[16], szRight[16]
    strtok(szText, szLeft, charsmax(szLeft), szRight, charsmax(szRight), ':')
    trim(szLeft)
    trim(szRight)
    new iHour, iMin
    if (szRight[0])
    {
        iHour = str_to_num(szLeft)
        iMin = str_to_num(szRight)
    }
    else
    {
        new iVal = str_to_num(szLeft)
        if (iVal < 0)
            return -1
        if (iVal <= 24)
        {
            iHour = iVal
            iMin = 0
        }
        else
        {
            iHour = iVal / 100
            iMin = iVal % 100
        }
    }
    if (iHour < 0 || iHour > 24 || iMin < 0 || iMin > 59)
        return -1
    return iHour * 100 + iMin
}

LoadEventsConfig()
{
    ResetConfig()

    new szPath[128]
    get_configsdir(szPath, charsmax(szPath))
    add(szPath, charsmax(szPath), "/")
    add(szPath, charsmax(szPath), CFG_FILE)

    if (!file_exists(szPath))
    {
        // Default behaviour, unchanged from 1.0.0: dice only.
        g_bCfgLoaded = true
        log_amx("[FreeNova][RandEvent] %s missing - dice mode, built-in flavour pool", szPath)
        return
    }

    new fp = fopen(szPath, "rt")
    if (!fp)
    {
        g_bCfgLoaded = true
        log_amx("[FreeNova][RandEvent] cannot open %s - dice mode, built-in flavour pool", szPath)
        return
    }

    new szLine[256], szSection[24], iLine
    while (fgets(fp, szLine, charsmax(szLine)))
    {
        iLine++
        StripConfigLine(szLine)
        if (!szLine[0])
            continue
        if (szLine[0] == '[')
        {
            new iEnd = contain(szLine, "]")
            if (iEnd > 1)
                szLine[iEnd] = 0
            else
                szLine[0] = 0
            copy(szSection, charsmax(szSection), szLine[1])
            trim(szSection)
            if (!equali(szSection, "settings") && !equali(szSection, "flavor")
                && !equali(szSection, "flavour") && !equali(szSection, "window") && !equali(szSection, "map"))
                log_amx("[FreeNova][RandEvent] events.ini:%d unknown section [%s] ignored", iLine, szSection)
            continue
        }
        if (equali(szSection, "settings"))
            ParseSettingLine(szLine, iLine)
        else if (equali(szSection, "flavor") || equali(szSection, "flavour"))
            ParseFlavorLine(szLine, iLine)
        else if (equali(szSection, "window") || equali(szSection, "windows"))
            ParseWindowLine(szLine, iLine)
        else if (equali(szSection, "map") || equali(szSection, "maps"))
            ParseMapLine(szLine, iLine)
        else
            log_amx("[FreeNova][RandEvent] events.ini:%d line outside a section ignored", iLine)
    }
    fclose(fp)

    g_bCfgLoaded = true
    if (g_iMode != MODE_RANDOM && g_iWinCount == 0)
    {
        log_amx("[FreeNova][RandEvent] events.ini: mode is %s but no valid [window] row - falling back to dice",
            (g_iMode == MODE_SCHEDULE) ? "schedule" : "both")
        g_iMode = MODE_RANDOM
    }
    log_amx("[FreeNova][RandEvent] events.ini loaded: mode=%s windows=%d maps=%d flavors=%d/%d/%d/%d",
        (g_iMode == MODE_RANDOM) ? "random" : ((g_iMode == MODE_SCHEDULE) ? "schedule" : "both"),
        g_iWinCount, g_iMapCount,
        g_iFlavWeight[FLAVOR_XP], g_iFlavWeight[FLAVOR_COINS],
        g_iFlavWeight[FLAVOR_DOUBLE], g_iFlavWeight[FLAVOR_HAPPY])
}

// --- clock helpers -----------------------------------------------------------

// HHMM as an int, in server-local time, so "20:00" means 20:00 for the players.
NowHHMM()
{
    new szTime[8]
    format_time(szTime, charsmax(szTime), "%H%M")
    return str_to_num(szTime)
}

NowDateKey(output[], len)
{
    format_time(output, len, "%Y%m%d")
}

// 0 = Sunday .. 6 = Saturday, from the local date (Sakamoto; no strftime %w
// dependency, which AMX Mod X builds differ on).
Weekday0Sun()
{
    new szDate[12]
    format_time(szDate, charsmax(szDate), "%Y%m%d")
    new iVal = str_to_num(szDate)
    new iY = iVal / 10000
    new iM = (iVal / 100) % 100
    new iD = iVal % 100
    new const iT[12] = {0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4}
    if (iM < 3)
        iY -= 1
    new iDow = (iY + iY / 4 - iY / 100 + iY / 400 + iT[iM - 1] + iD) % 7
    if (iDow < 0)
        iDow += 7
    return iDow
}

// "YYYYMMDDHHMM" for a day's clock time. Lexicographic order is chronological.
UntilKey(iWin, output[], len)
{
    new szDate[12]
    NowDateKey(szDate, charsmax(szDate))
    formatex(output, len, "%s%04d", szDate, g_iWinEnd[iWin])
}

Float:MapMultiplier()
{
    if (g_iMapCount <= 0)
        return 1.0
    new szMap[32]
    get_mapname(szMap, charsmax(szMap))
    for (new i; i < g_iMapCount; i++)
        if (equali(szMap, g_szMapName[i]))
            return g_fMapMult[i]
    return 1.0
}

// --- driver ------------------------------------------------------------------

// Starts the dice timer, the window ticker, or both, for the configured mode.
ArmDriver()
{
    remove_task(TASK_FIRE)
    remove_task(TASK_TICK)

    if (g_iMode == MODE_SCHEDULE)
    {
        set_task(FN_RE_TICK_SEC, "Task_Tick", TASK_TICK, "", 0, "b")
        return
    }
    if (g_iMode == MODE_BOTH)
        set_task(FN_RE_TICK_SEC, "Task_Tick", TASK_TICK, "", 0, "b")
    ScheduleNext()
}

ScheduleNext()
{
    remove_task(TASK_FIRE)

    new iMin = get_pcvar_num(g_pCvarMin)
    new iMax = get_pcvar_num(g_pCvarMax)
    if (iMin < 1)
        iMin = 1
    if (iMax < iMin)
        iMax = iMin

    new iWait = random_num(iMin, iMax)
    set_task(float(iWait * 60), "Task_Fire", TASK_FIRE)
    log_amx("[FreeNova][RandEvent] next roll in %d minutes", iWait)
}

ScheduleRetry()
{
    remove_task(TASK_FIRE)
    set_task(float(FN_RE_RETRY_MIN * 60), "Task_Fire", TASK_FIRE)
    log_amx("[FreeNova][RandEvent] skipped (event already active) - retry in %d minutes", FN_RE_RETRY_MIN)
}

// --- owner cvar pointers (resolved lazily: owners may load after us) --------

ResolvePtr(const szName[])
{
    return get_cvar_pointer(szName)
}

// --- skip-when-active -------------------------------------------------------

bool:AnyEventActive()
{
    new pXp = ResolvePtr("fn_event_xp_mult")
    new pCoins = ResolvePtr("fn_event_coins_mult")
    new pDouble = ResolvePtr("fn_double_xp")
    new pHappy = ResolvePtr("fn_happy_hour")

    if (pXp && floatabs(get_pcvar_float(pXp) - 1.0) > FLOAT_TOL)
        return true
    if (pCoins && floatabs(get_pcvar_float(pCoins) - 1.0) > FLOAT_TOL)
        return true
    if (pDouble && get_pcvar_num(pDouble) != 0)
        return true
    if (pHappy && floatabs(get_pcvar_float(pHappy) - 1.0) > FLOAT_TOL)
        return true
    return false
}

// True while the owner cvar of `iFlavor` still holds `fValue`, i.e. nobody
// (panel, progression, an admin) took the channel over after we set it.
bool:ValueStillOurs(iFlavor, Float:fValue)
{
    if (iFlavor == FLAVOR_XP)
    {
        new p = ResolvePtr("fn_event_xp_mult")
        return (p && floatabs(get_pcvar_float(p) - fValue) <= FLOAT_TOL) ? true : false
    }
    if (iFlavor == FLAVOR_COINS)
    {
        new p = ResolvePtr("fn_event_coins_mult")
        return (p && floatabs(get_pcvar_float(p) - fValue) <= FLOAT_TOL) ? true : false
    }
    if (iFlavor == FLAVOR_DOUBLE)
    {
        new p = ResolvePtr("fn_double_xp")
        return (p && get_pcvar_num(p) == floatround(fValue)) ? true : false
    }
    if (iFlavor == FLAVOR_HAPPY)
    {
        new p = ResolvePtr("fn_happy_hour")
        return (p && floatabs(get_pcvar_float(p) - fValue) <= FLOAT_TOL) ? true : false
    }
    return false
}

// --- flavours ----------------------------------------------------------------

// Flavour whose owner cvar exists right now. Writes the weighted pick into
// iAvail/iAvailNum, then returns one of them, or -1 when nothing is available.
PickFlavor()
{
    new iAvail[FLAVOR_COUNT], iWeight[FLAVOR_COUNT], iNum, iTotal
    if (g_iFlavWeight[FLAVOR_XP] > 0 && ResolvePtr("fn_event_xp_mult"))
    {
        iAvail[iNum] = FLAVOR_XP;
        iWeight[iNum] = g_iFlavWeight[FLAVOR_XP];
        iTotal += iWeight[iNum];
        iNum++;
    }
    if (g_iFlavWeight[FLAVOR_COINS] > 0 && ResolvePtr("fn_event_coins_mult"))
    {
        iAvail[iNum] = FLAVOR_COINS;
        iWeight[iNum] = g_iFlavWeight[FLAVOR_COINS];
        iTotal += iWeight[iNum];
        iNum++;
    }
    if (g_iFlavWeight[FLAVOR_DOUBLE] > 0 && ResolvePtr("fn_double_xp"))
    {
        iAvail[iNum] = FLAVOR_DOUBLE;
        iWeight[iNum] = g_iFlavWeight[FLAVOR_DOUBLE];
        iTotal += iWeight[iNum];
        iNum++;
    }
    if (g_iFlavWeight[FLAVOR_HAPPY] > 0 && ResolvePtr("fn_happy_hour"))
    {
        iAvail[iNum] = FLAVOR_HAPPY;
        iWeight[iNum] = g_iFlavWeight[FLAVOR_HAPPY];
        iTotal += iWeight[iNum];
        iNum++;
    }
    if (!iNum || iTotal <= 0)
        return -1
    new iPick = random_num(1, iTotal)
    for (new i; i < iNum; i++)
    {
        iPick -= iWeight[i]
        if (iPick <= 0)
            return iAvail[i]
    }
    return iAvail[iNum - 1]
}

// Rolled (or configured) magnitude for a flavour, scaled by the map multiplier.
Float:FlavorValue(iFlavor, Float:fConfigured)
{
    new Float:fValue
    if (fConfigured > 0.0)
        fValue = fConfigured
    else if (iFlavor == FLAVOR_DOUBLE)
        fValue = 1.0
    else
    {
        // 0.1 steps inside [min,max], the same grain 1.0.0 used for 1.5..3.0.
        new iLow = floatround(g_fFlavMin[iFlavor] * 10.0)
        new iHigh = floatround(g_fFlavMax[iFlavor] * 10.0)
        if (iHigh < iLow)
            iHigh = iLow
        if (iHigh > iLow)
            fValue = float(random_num(iLow, iHigh)) / 10.0
        else
            fValue = g_fFlavMin[iFlavor]
    }
    // fn_double_xp is a 0/1 flag for the panel: never scale it.
    if (iFlavor != FLAVOR_DOUBLE)
    {
        fValue *= MapMultiplier()
        fValue = floatclamp(fValue, EVENT_MIN_MULT, EVENT_MAX_MULT)
    }
    return fValue
}

DescribeFlavor(iFlavor, Float:fValue, output[], len)
{
    switch (iFlavor)
    {
        case FLAVOR_XP: formatex(output, len, "%.1fx XP", fValue)
        case FLAVOR_COINS: formatex(output, len, "%.1fx coins", fValue)
        case FLAVOR_DOUBLE: copy(output, len, "Double XP")
        default: formatex(output, len, "Happy Hour (%.1fx)", fValue)
    }
}

// --- fire --------------------------------------------------------------------

public Task_Fire()
{
    if (!get_pcvar_num(g_pCvarEnabled))
    {
        ScheduleNext()
        return
    }

    // Dice never runs while a window is open: the ticker owns the clock then.
    if (g_iMode != MODE_RANDOM && WindowOpenNow())
    {
        ScheduleRetry()
        return
    }

    // Fallback only: never fire while a panel/schedule event is active.
    if (AnyEventActive())
    {
        ScheduleRetry()
        return
    }

    new iFlavor = PickFlavor()
    if (iFlavor < 0)
    {
        log_amx("[FreeNova][RandEvent] no available flavour (owner cvars missing or all weights 0) - retry later")
        ScheduleRetry()
        return
    }

    new Float:fValue = FlavorValue(iFlavor, 0.0)
    new iDur = get_pcvar_num(g_pCvarDuration)
    if (iDur < 1)
        iDur = 1

    if (!ApplyEvent(iFlavor, fValue, -1, 0.0, 0.0, 0, 0.0, false))
    {
        ScheduleRetry()
        return
    }

    new szDesc[64]
    DescribeFlavor(iFlavor, fValue, szDesc, charsmax(szDesc))
    Announce("Random event started: %s for %d minute%s!", szDesc, iDur, iDur == 1 ? "" : "s")
    log_amx("[FreeNova][RandEvent] FIRED flavor=%d (%s) duration=%d min", iFlavor, szDesc, iDur)

    remove_task(TASK_END)
    set_task(float(iDur * 60), "Task_End", TASK_END)
}

// Window scheduler. Runs every FN_RE_TICK_SEC in schedule/both mode.
public Task_Tick()
{
    if (!get_pcvar_num(g_pCvarEnabled))
        return
    if (g_iMode == MODE_RANDOM || g_iWinCount <= 0)
        return
    if (g_iActiveFlavor != -1)
        return
    if (AnyEventActive())
        return

    new iWin = DueWindow()
    if (iWin < 0)
        return
    OpenWindow(iWin, false, 0.0, 0.0, 0, 0.0)
}

// First window that is open right now and has not been handled for this
// occurrence; -1 when none. The occurrence is identified by its end key, which
// is what the vault record stores, so a map change cannot re-open a window that
// already ran its course today.
DueWindow()
{
    new iNow = NowHHMM()
    new iDow = Weekday0Sun()
    new szUntil[16]
    for (new i; i < g_iWinCount; i++)
    {
        if (!(g_iWinDays[i] & (1 << iDow)))
            continue
        if (iNow < g_iWinStart[i] || iNow >= g_iWinEnd[i])
            continue
        UntilKey(i, szUntil, charsmax(szUntil))
        if (g_iStateWindow == i && equal(g_szStateUntil, szUntil))
            continue
        return i
    }
    return -1
}

bool:WindowOpenNow()
{
    return (DueWindow() >= 0) ? true : false
}

// Opens a window: picks its flavour (or rolls one when the row says "-"),
// computes the magnitude, and arms Task_End for the time the window has left.
// bContinue = the map-change path: the priors come from the vault record, NOT
// from the cvar, which may still hold our own boost.
OpenWindow(iWin, bool:bContinue, Float:fBaseXp, Float:fBaseCoins, iBaseDouble, Float:fBaseHappy)
{
    new iNow = NowHHMM()
    new iLeft = (g_iWinEnd[iWin] / 100 - iNow / 100) * 3600 + (g_iWinEnd[iWin] % 100 - iNow % 100) * 60
    if (iLeft <= 0)
        return

    new iFlavor = g_iWinFlavor[iWin]
    if (iFlavor < 0)
        iFlavor = PickFlavor()
    if (iFlavor < 0)
    {
        log_amx("[FreeNova][RandEvent] window '%s' cannot open: no available flavour", g_szWinId[iWin])
        return
    }
    if (!ResolvePtr(g_szOwnerCvar[iFlavor]))
    {
        log_amx("[FreeNova][RandEvent] window '%s' cannot open: owner cvar %s missing",
            g_szWinId[iWin], g_szOwnerCvar[iFlavor])
        return
    }

    new Float:fValue = FlavorValue(iFlavor, g_fWinMult[iWin])
    if (!ApplyEvent(iFlavor, fValue, iWin, fBaseXp, fBaseCoins, iBaseDouble, fBaseHappy, bContinue))
        return

    new szDesc[64], szEnd[8]
    DescribeFlavor(iFlavor, fValue, szDesc, charsmax(szDesc))
    formatex(szEnd, charsmax(szEnd), "%02d:%02d", g_iWinEnd[iWin] / 100, g_iWinEnd[iWin] % 100)
    if (bContinue)
    {
        Announce("Scheduled event continues: %s until %s!", szDesc, szEnd)
        log_amx("[FreeNova][RandEvent] window '%s' re-opened: flavor=%d value=%.2f ends=%s (%d min left)",
            g_szWinId[iWin], iFlavor, fValue, szEnd, iLeft / 60)
    }
    else
    {
        Announce("Scheduled event started: %s until %s!", szDesc, szEnd)
        log_amx("[FreeNova][RandEvent] WINDOW '%s' opened flavor=%d value=%.2f ends=%s (%d min left)",
            g_szWinId[iWin], iFlavor, fValue, szEnd, iLeft / 60)
    }

    g_iActiveWindow = iWin
    remove_task(TASK_END)
    set_task(float(iLeft), "Task_End", TASK_END)
}

// Writes the owner cvar for one flavour, remembering what it replaced.
// bHaveBase = the priors are passed in (map-change re-open) instead of being
// snapshotted from the live cvars.
bool:ApplyEvent(iFlavor, Float:fValue, iWindow, Float:fBaseXp, Float:fBaseCoins,
    iBaseDouble, Float:fBaseHappy, bool:bHaveBase)
{
    new pXp = ResolvePtr("fn_event_xp_mult")
    new pCoins = ResolvePtr("fn_event_coins_mult")
    new pDouble = ResolvePtr("fn_double_xp")
    new pHappy = ResolvePtr("fn_happy_hour")

    if (bHaveBase)
    {
        g_fSavedXp = fBaseXp
        g_fSavedCoins = fBaseCoins
        g_iSavedDouble = iBaseDouble
        g_fSavedHappy = fBaseHappy
    }
    else
    {
        g_fSavedXp = pXp ? get_pcvar_float(pXp) : 1.0
        g_fSavedCoins = pCoins ? get_pcvar_float(pCoins) : 1.0
        g_iSavedDouble = pDouble ? get_pcvar_num(pDouble) : 0
        g_fSavedHappy = pHappy ? get_pcvar_float(pHappy) : 1.0
    }

    g_fEventValue = fValue
    switch (iFlavor)
    {
        case FLAVOR_XP:
        {
            if (!pXp)
                return false
            set_pcvar_float(pXp, fValue)
        }
        case FLAVOR_COINS:
        {
            if (!pCoins)
                return false
            set_pcvar_float(pCoins, fValue)
        }
        case FLAVOR_DOUBLE:
        {
            if (!pDouble)
                return false
            set_pcvar_num(pDouble, 1)
        }
        default:
        {
            if (!pHappy)
                return false
            set_pcvar_float(pHappy, fValue)
            // See HAPPY-HOUR NOTE: re-assert against the 30s schedule tick.
            remove_task(TASK_ASSERT)
            set_task(FN_RE_ASSERT_SEC, "Task_AssertHappy", TASK_ASSERT)
        }
    }

    g_iActiveFlavor = iFlavor
    g_iActiveWindow = iWindow
    SaveState(true)
    return true
}

public Task_AssertHappy()
{
    // Re-assert loop: runs only while OUR happy_hour event is active.
    if (g_iActiveFlavor != FLAVOR_HAPPY)
        return

    new pHappy = ResolvePtr("fn_happy_hour")
    if (pHappy)
        set_pcvar_float(pHappy, g_fEventValue)

    set_task(FN_RE_ASSERT_SEC, "Task_AssertHappy", TASK_ASSERT)
}

// --- revert -----------------------------------------------------------------

public Task_End()
{
    remove_task(TASK_ASSERT)
    RevertEvent()
    // Record the occurrence with applied = 0 BEFORE the window id is cleared: it
    // is what stops the same window being fired twice in one occurrence.
    SaveState(false)

    log_amx("[FreeNova][RandEvent] ENDED flavor=%d window=%d, values restored", g_iActiveFlavor, g_iActiveWindow)
    g_iActiveFlavor = -1
    g_iActiveWindow = -1

    Announce("Random event ended. Thanks for playing!")
    ArmDriver()
}

// Restores the one owner cvar this event changed, from the value snapshotted at
// fire time. Shared by Task_End(), plugin_end() and RestoreState(). Refuses to
// write when the channel no longer holds our value, so a panel-driven event that
// started during ours is never clobbered.
RevertEvent()
{
    if (g_iActiveFlavor < 0 || g_iActiveFlavor >= FLAVOR_COUNT)
        return

    if (!ValueStillOurs(g_iActiveFlavor, g_fEventValue))
    {
        log_amx("[FreeNova][RandEvent] flavour %d was taken over while active - leaving its cvar alone",
            g_iActiveFlavor)
        return
    }

    switch (g_iActiveFlavor)
    {
        case FLAVOR_XP:
        {
            new pXp = ResolvePtr("fn_event_xp_mult")
            if (pXp)
                set_pcvar_float(pXp, g_fSavedXp)
        }
        case FLAVOR_COINS:
        {
            new pCoins = ResolvePtr("fn_event_coins_mult")
            if (pCoins)
                set_pcvar_float(pCoins, g_fSavedCoins)
        }
        case FLAVOR_DOUBLE:
        {
            new pDouble = ResolvePtr("fn_double_xp")
            if (pDouble)
                set_pcvar_num(pDouble, g_iSavedDouble)
        }
        case FLAVOR_HAPPY:
        {
            new pHappy = ResolvePtr("fn_happy_hour")
            if (pHappy)
                set_pcvar_float(pHappy, g_fSavedHappy)
        }
    }
}

// --- persisted window state --------------------------------------------------
// One record, key "state" in the freenova_randevent vault:
//   window flavor value savedXp savedCoins savedDouble savedHappy applied untilKey
// "applied" says whether a revert is still owed; "untilKey" (YYYYMMDDHHMM)
// identifies the occurrence. The record is deliberately NOT cleared when a
// window ends: it stays as the "already handled" marker for that occurrence.

SaveState(bool:bApplied)
{
    if (g_Vault == INVALID_HANDLE)
        return
    // A dice event never writes the occurrence marker: the marker belongs to
    // scheduled windows, and the dice driver re-arms itself after every event.
    new iWinOut = g_iStateWindow
    new szUntil[16]
    copy(szUntil, charsmax(szUntil), g_szStateUntil)
    if (g_iActiveWindow >= 0)
    {
        iWinOut = g_iActiveWindow
        UntilKey(g_iActiveWindow, szUntil, charsmax(szUntil))
        // Carry the occurrence key forward even after the revert.
        copy(g_szStateUntil, charsmax(g_szStateUntil), szUntil)
    }
    new szVal[192]
    formatex(szVal, charsmax(szVal), "%d %d %.2f %.2f %.2f %d %.2f %d %s",
        iWinOut, (g_iActiveFlavor >= 0) ? g_iActiveFlavor : -1,
        g_fEventValue, g_fSavedXp, g_fSavedCoins, g_iSavedDouble, g_fSavedHappy,
        bApplied ? 1 : 0, szUntil[0] ? szUntil : "-")
    if (!nvault_set(g_Vault, VAULT_STATE, szVal))
        log_amx("[FreeNova][RandEvent] WARNING: nvault_set failed for %s/%s", VAULT_NAME, VAULT_STATE)
}

LoadState()
{
    g_iStateWindow = -1
    g_szStateUntil[0] = 0
    g_bStateApplied = false
    if (g_Vault == INVALID_HANDLE)
        return
    new szVal[192]
    if (!nvault_get(g_Vault, VAULT_STATE, szVal, charsmax(szVal)))
        return
    new part[24], left[192]
    copy(left, charsmax(left), szVal)
    strtok(left, part, charsmax(part), left, charsmax(left), ' ')
    g_iStateWindow = str_to_num(part)
    strtok(left, part, charsmax(part), left, charsmax(left), ' ')
    g_iActiveFlavor = str_to_num(part)
    strtok(left, part, charsmax(part), left, charsmax(left), ' ')
    g_fEventValue = str_to_float(part)
    strtok(left, part, charsmax(part), left, charsmax(left), ' ')
    g_fSavedXp = str_to_float(part)
    strtok(left, part, charsmax(part), left, charsmax(left), ' ')
    g_fSavedCoins = str_to_float(part)
    strtok(left, part, charsmax(part), left, charsmax(left), ' ')
    g_iSavedDouble = str_to_num(part)
    strtok(left, part, charsmax(part), left, charsmax(left), ' ')
    g_fSavedHappy = str_to_float(part)
    strtok(left, part, charsmax(part), left, charsmax(left), ' ')
    g_bStateApplied = (str_to_num(part) != 0) ? true : false
    strtok(left, part, charsmax(part), left, charsmax(left), ' ')
    copy(g_szStateUntil, charsmax(g_szStateUntil), part)
}

// Called once per map, after the config load. Two jobs:
//   1. if a previous map left a channel boosted (crash, plugin unload that
//      skipped plugin_end), put the recorded prior back;
//   2. if the window it belonged to is still open, re-open it for the time that
//      is left, using the recorded prior - never the boosted value.
RestoreState()
{
    LoadState()
    if (g_iStateWindow < 0)
        return

    // 1. A revert is owed whenever the record says the value was left applied.
    //    RevertEvent() reads g_iActiveFlavor/g_fEventValue and the saved priors,
    //    which LoadState() just restored from the record.
    if (g_bStateApplied && g_iActiveFlavor >= 0 && g_iActiveFlavor < FLAVOR_COUNT)
    {
        RevertEvent()
        log_amx("[FreeNova][RandEvent] prior value restored for flavour %d left over from the previous map",
            g_iActiveFlavor)
    }
    new Float:fBaseXp = g_fSavedXp, Float:fBaseCoins = g_fSavedCoins
    new iBaseDouble = g_iSavedDouble
    new Float:fBaseHappy = g_fSavedHappy
    g_iActiveFlavor = -1
    g_iActiveWindow = -1

    // 2. Same occurrence still open? The end key identifies it, so a record from
    //    yesterday (or one whose window was edited) never matches.
    if (g_iStateWindow >= g_iWinCount)
        return
    new szUntil[16]
    UntilKey(g_iStateWindow, szUntil, charsmax(szUntil))
    if (!g_szStateUntil[0] || !equal(szUntil, g_szStateUntil))
        return
    new szNow[16], szDate[12]
    NowDateKey(szDate, charsmax(szDate))
    formatex(szNow, charsmax(szNow), "%s%04d", szDate, NowHHMM())
    if (strcmp(szNow, g_szStateUntil) >= 0)
        return

    OpenWindow(g_iStateWindow, true, fBaseXp, fBaseCoins, iBaseDouble, fBaseHappy)
}

// --- announce (chat + HUD) --------------------------------------------------

Announce(const szFmt[], any:...)
{
    new szMsg[192]
    vformat(szMsg, charsmax(szMsg), szFmt, 2)

    // Chat to everyone (0 = all).
    client_print_color(0, print_team_default, "^4[FreeNova]^1 %s", szMsg)

    // HUD flash: channel -1 = auto-select (transient 5s hold, never parked).
    set_hudmessage(255, 220, 0, -1.0, 0.30, 0, 1.0, 5.0, 0.1, 0.2, -1)
    show_hudmessage(0, "[FreeNova]^n%s", szMsg)
}
