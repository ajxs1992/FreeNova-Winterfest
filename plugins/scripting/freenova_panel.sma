// ============================================================
// FreeNova Gaming Network - Admin & Player Panel
// Press N to open the panel (or say /panel)
// ============================================================
#include <amxmodx>
#include <amxmisc>
#include <cstrike>
#include <engine>
#include <fakemeta>
#include <fakemeta_util>
#include <fun>
#include <hamsandwich>
#include <nvault>
#include <menabp>
#include <crxranks>
#include <cban_main>
#include <freenova_vip>
#include <freenova_reg>
#include <freenova_ui>
#include <ranksultimate>
#include <freenova_chat>
#include <freenova_admin>
#include <fn_common>
#include <fn_core>     // fn_resolve_target(): a console-safe target resolver
#include <freenova_web>   // fn_open_panel(): the one MOTD-vs-menu decision

// Natives from other plugins (called server-side)
native skins_open_menu(id)

// provider availability (probed in plugin_cfg)
new bool:g_bSkinsMenuAvailable = false

public plugin_natives()
{
    // skins_open_menu comes from an optional provider plugin
    // (weapon_models); stub it if missing so the panel still loads.

    set_native_filter("PanelNativeFilter")

    register_library("freenova_panelstats")
    register_native("fnstats_get", "_native_stats_get")
}

public PanelNativeFilter(const name[], index, trap)
{
    if(equal(name, "skins_open_menu") || equal(name, "fnreg_is_available") || equal(name, "fnreg_get_state"))
    {
        return PLUGIN_HANDLED
    }

    // CBan natives come from advanced_bans.amxx, which registers library
    // "cban" (verified: register_library("cban") in the provider alongside
    // register_native). Trap them here so a call with the stack
    // unloaded degrades to a no-op instead of a bad-native runtime error.
    // Fire-time CBanUsable() guards report fail-closed to the admin before
    // any call can reach this backstop.
    if(equal(name, "CBan_BanPlayer") || equal(name, "CBan_UnbanPlayer") ||
       equal(name, "CBan_GetBanCount") || equal(name, "CBan_GetBanInfo") ||
       equal(name, "CBan_UnbanById"))
    {
        return PLUGIN_HANDLED
    }

    return PLUGIN_CONTINUE
}

public plugin_cfg()
{
    g_bSkinsMenuAvailable  = PanelProviderLoaded("weapon_models")
}

stock bool:PanelProviderLoaded(const szNeedle[])
{
    new n = get_pluginsnum()
    new szFile[64]
    for(new i = 0; i < n; i++)
    {
        get_plugin(i, szFile, charsmax(szFile))
        if(containi(szFile, szNeedle) != -1)
            return true
    }
    return false
}

// CBan provider gate. advanced_bans.amxx registers library "cban", so a
// LibraryExists probe is primary; the loaded-plugin filename check stays as
// a fallback (same mechanism as PanelProviderLoaded). Evaluated live on every
// ban/unban: no-op when the stack IS loaded, fail-closed when it is not.
stock bool:CBanUsable()
{
    if( LibraryExists("cban", LibType_Library) )
        return true
    return PanelProviderLoaded("advanced_bans")
}

#define PLUGIN  "FreeNova Panel"
#define AUTHOR  "FreeNova Dev"

#define MAX_PLAYERS     32
#define TASK_PANEL      9000
#define TASK_EVENT      9100
#define TASK_AUTOSAVE   9200
#define TASK_LATELOAD   9300
#define VAULT_NAME      "freenova_stats"
new g_VaultStats = INVALID_HANDLE
new g_iStatsLateTries[MAX_PLAYERS + 1]

// Fallback define in case fakemeta_util doesn't provide it
#if !defined TR_iHitGroup
    #define TR_iHitGroup 8
#endif
// TASK_LOADOUT and TASK_CLEANUP were previously 9200/9300, colliding with
// TASK_AUTOSAVE and TASK_LATELOAD. Per-player loadout tasks (id + TASK_LOADOUT)
// were being cancelled by the global autosave remove_task(TASK_AUTOSAVE), and
// the TASK_CLEANUP recurring task silently ate TASK_LATELOAD slots.
#define TASK_LOADOUT    9400
#define TASK_CLEANUP    9500
#define TASK_COINRETRY  9600

// FL_FROZEN for freeze command
#if !defined FL_FROZEN
    #define FL_FROZEN (1<<7)
#endif

// Flag semantics (users.ini access string):
//   FLAG_ADMIN / FLAG_ADMIN_FULL = cdeijuv
//     Panel entry, kick/ban/gag/slay/slap/freeze/events/round.
//     Does NOT grant VIP or admin-flag changes.
//   FLAG_MANAGER = a
//     Highest role. Can grant/revoke VIP and admin flags.
//     Can moderate anyone except another manager (a).
//   FLAG_MOD_ADMIN = e  (subset of FLAG_ADMIN)
//     Can moderate players who do not have FLAG_ADMIN_FULL.
//     Cannot touch other admins or managers.
#define FLAG_ADMIN      read_flags("cdeijuv")

// VIP tiers are owned by freenova_vip (fnvip_*); no flag defines here.

#define FLAG_ADMIN_FULL read_flags("cdeijuv")
#define FLAG_MANAGER read_flags("a")
#define FLAG_MOD_ADMIN read_flags("e")

// ============================================================
// ROLE HIERARCHY: a (manager) > e (admin) > regular player
// ============================================================
bool:CanModerate(adminId, targetId)
{
    if(!is_user_connected(adminId) || !is_user_connected(targetId))
        return false

    new adminFlags = get_user_flags(adminId)
    new targetFlags = get_user_flags(targetId)

    // Manager (flag a) can moderate everyone except other managers
    if(adminFlags & FLAG_MANAGER)
    {
        if(targetFlags & FLAG_MANAGER)
            return false  // can't touch fellow managers
        return true
    }

    // Admin (flag e) can moderate regular players only, not any admin
    if(adminFlags & FLAG_MOD_ADMIN)
    {
        if(targetFlags & FLAG_ADMIN_FULL)
            return false  // can't touch anyone with admin flags
        return true
    }

    return false
}

// ============================================================
// EVENT SYSTEM
// ============================================================
enum _:EventType
{
    EVENT_NONE = 0,
    EVENT_KNIFE_ROUND,
    EVENT_HEADSHOT_ONLY,
    EVENT_TEMP_VIP,
    EVENT_VIP_FEST,
    EVENT_SPEED_RUSH,
    EVENT_GOLDEN_DEAGLE,
    EVENT_DOUBLE_XP,
    EVENT_LOW_GRAVITY
}

new bool:g_bEventActive[EVENT_LOW_GRAVITY + 1]
new g_iGrabTarget[33]
new bool:g_bIsGrabbing[33]
new bool:g_bFrozen[33]

// freeze window state (HLTV -> Round_Start), mirrors battlepass_core's guard
new bool:g_bFreezeWindow
new bool:g_bRoundStarted // true after Round_Start until the next HLTV

// Ban/Gag menu data
new g_iBanTarget[MAX_PLAYERS + 1]
new g_iBanUserid[MAX_PLAYERS + 1]
new g_szBanAuth[MAX_PLAYERS + 1][35]
new g_iBanTime[MAX_PLAYERS + 1]
new g_iGagTarget[MAX_PLAYERS + 1]
new g_iGagTime[MAX_PLAYERS + 1]
new g_iCoinTarget[MAX_PLAYERS + 1]
// Add Coins flow: dedicated target snapshot + single-use confirmation token.
// Kept separate from the ban snapshot so both flows can never cross-validate.
new g_iAddCoinTarget[MAX_PLAYERS + 1]
new g_iAddCoinUserid[MAX_PLAYERS + 1]
new g_szAddCoinAuth[MAX_PLAYERS + 1][35]
new g_iAddCoinPending[MAX_PLAYERS + 1]
new g_iAddCoinToken[MAX_PLAYERS + 1]
new g_iCoinRetryTries[MAX_PLAYERS + 1]
// Give Rank XP flow: its own target snapshot. Keep it out of the ban snapshot
// so rank XP and ban/slay/kick menus can never cross-validate one another.
// This snapshot is for the RSU/CRX rank ledger only.
new g_iXpTarget[MAX_PLAYERS + 1]
new g_iXpUserid[MAX_PLAYERS + 1]
new g_szXpAuth[MAX_PLAYERS + 1][35]
// Give BP XP flow: a completely separate target snapshot. BP is a separate
// ledger owned by battlepass_core, so it must never share the rank snapshot or
// its validation path.
new g_iBpXpTarget[MAX_PLAYERS + 1]
new g_iBpXpUserid[MAX_PLAYERS + 1]
new g_szBpXpAuth[MAX_PLAYERS + 1][35]
new g_unbanTarget[MAX_PLAYERS + 1][64]
new g_szConfirmAction[MAX_PLAYERS + 1][16]
new g_szPendingMap[MAX_PLAYERS + 1][32]
// Last-target memory: repeat actions without reselecting the player.
new g_iLastTarget[MAX_PLAYERS + 1]
new g_szLastAction[MAX_PLAYERS + 1][16]
new g_szLastAuth[MAX_PLAYERS + 1][35]
new g_iSavedGravity = 800


// ============================================================
// PLAYER STATS
// ============================================================
enum _:PlayerStats
{
    STAT_KILLS,
    STAT_DEATHS,
    STAT_HEADSHOTS,
    STAT_BOMB_PLANTS,
    STAT_BOMB_DEFUSES,
    STAT_WIN_CT,
    STAT_WIN_T,
    STAT_MVP,
    STAT_PLAYTIME
}

new g_iPlayerStats[MAX_PLAYERS + 1][PlayerStats]
// per-round kill counter for the round-MVP definition (reset on new round)
new g_iRoundKills[MAX_PLAYERS + 1]
// true once LoadPlayerStats actually read this player's own vault row
new bool:g_bStatsLoaded[MAX_PLAYERS + 1]
new Float:g_fConnectTime[MAX_PLAYERS + 1]

public _native_stats_get(iPlugin, iParams)
{
    new id = get_param(1)
    new iField = get_param(2)

    if(!(1 <= id <= MaxClients) || !is_user_connected(id))
        return 0
    if(iField < 0 || iField >= PlayerStats)
        return 0

    // RSU is the combat ledger. The local nVault copy remains for the
    // in-game panel UI but consumers (web sync) must not diverge.
    switch (iField)
    {
        case STAT_KILLS:        return rsu_get_user_kills(id)
        case STAT_DEATHS:       return rsu_get_user_deaths(id)
        case STAT_HEADSHOTS:    return rsu_get_user_headshots(id)
        case STAT_BOMB_PLANTS:  return rsu_get_user_bombs_planted(id)
        case STAT_BOMB_DEFUSES: return rsu_get_user_bombs_defused(id)
        case STAT_WIN_CT:       return rsu_get_user_rounds_won(id)
        // RSU has no T/CT split; T wins live in the local vault ledger.
        case STAT_WIN_T:        return g_iPlayerStats[id][STAT_WIN_T]
        case STAT_MVP:          return rsu_get_user_mvp(id)
        case STAT_PLAYTIME:     return rsu_get_user_played_time(id) / 60
    }
    return g_iPlayerStats[id][iField]
}

// ============================================================
// MENU DATA
// ============================================================
new g_iTargetPlayer[MAX_PLAYERS + 1]
new g_iMenuPage[MAX_PLAYERS + 1]

// ============================================================
// VIP/ADMIN PERSISTENCE (nvault)
// ============================================================
new const VAULT_VIPADMIN[] = "freenova_vipadmin"
new g_VaultVipAdmin = INVALID_HANDLE

SaveVipFlags(id)
{
    // VIP tiers are owned by the freenova_vip core now - only the admin
    // bit is persisted here. Event-granted states need no tracking either:
    // event entitlements use their own source key in the core.
    if(g_VaultVipAdmin == INVALID_HANDLE) return

    new key[64], value[16], authid[40]
    get_user_authid(id, authid, charsmax(authid))
    if(!authid[0] || equal(authid, "STEAM_ID_PENDING") || equal(authid, "STEAM_ID_LAN")
        || equal(authid, "BOT") || equal(authid, "HLTV"))
        return

    for(new i = 0; authid[i]; i++)
        if(authid[i] == ':') authid[i] = '_'

    // Save admin status
    formatex(key, charsmax(key), "adm#%s", authid)
    formatex(value, charsmax(value), "%d", (get_user_flags(id) & FLAG_ADMIN_FULL) ? 1 : 0)
    nvault_set(g_VaultVipAdmin, key, value)
}

LoadVipFlags(id)
{
    if(g_VaultVipAdmin == INVALID_HANDLE) return

    new key[64], value[16], authid[40]
    get_user_authid(id, authid, charsmax(authid))
    if(!authid[0] || equal(authid, "STEAM_ID_PENDING") || equal(authid, "STEAM_ID_LAN")
        || equal(authid, "BOT") || equal(authid, "HLTV"))
        return

    for(new i = 0; authid[i]; i++)
        if(authid[i] == ':') authid[i] = '_'

    new pflags = get_user_flags(id)
    new iTime = 0

    // Migrate legacy flag-tier into a permanent VIP ELITE entitlement once,
    // then delete the legacy key - the core owns VIP from here on.
    formatex(key, charsmax(key), "vip#%s", authid)
    if(nvault_lookup(g_VaultVipAdmin, key, value, charsmax(value), iTime))
    {
        new tier = str_to_num(value)
        if(tier > 0)
            fnvip_grant(id, tier, 315360000, FNVIP_SRC_ADMIN) // 10 years
        nvault_remove(g_VaultVipAdmin, key)
    }

    // Load admin status
    formatex(key, charsmax(key), "adm#%s", authid)
    if(nvault_lookup(g_VaultVipAdmin, key, value, charsmax(value), iTime))
    {
        if(str_to_num(value) == 1)
            pflags |= FLAG_ADMIN_FULL
        set_user_flags(id, pflags)
    }
}

// ============================================================
// PLUGIN INIT
// ============================================================
public plugin_init()
{
    fn_boot_banner("panel", 35)

    register_plugin(PLUGIN, "1.0", AUTHOR)

    // Where the Winterfest pages live on the panel, used by fn_open_panel()
    // (freenova_web.inc). The HOST is fnweb_url; this is only the path, so a
    // panel that moves its pages is a config edit. EMPTY by default: the panel's
    // Winterfest pages were removed in its 2026-11 rebuild, and a path that 404s
    // is worse than the menu this leaves the player with. Set it (e.g.
    // "/winter") the day the panel serves them again and every Winterfest
    // command opens the page.
    register_cvar("fnweb_winter_path", "")

    // Diagnostic: which url (or file) would a player / a SteamID be sent to for a
    // panel kind, and is Low Performance Mode in the way? Sends nothing. See
    // Cmd_PanelProbe.
    register_concmd("panel_probe", "Cmd_PanelProbe", ADMIN_CFG, "<player> <kind> [authid] - show the panel decision without sending it")

    // Panel commands
    register_clcmd("say /panel", "Cmd_OpenPanel")
    register_clcmd("say_team /panel", "Cmd_OpenPanel")

    // Quick commands
    register_clcmd("say /rules", "Cmd_Rules")
    register_clcmd("say_team /rules", "Cmd_Rules")
    register_clcmd("say /events", "Cmd_EventCatalog")
    register_clcmd("say_team /events", "Cmd_EventCatalog")
    // The Winterfest dashboard as a MOTD: the panel serves the owner's own
    // plate (web-panel/assets/dashboard.png) through /dashboard.html. /wfpanel
    // is the short alias.
    register_clcmd("say /dashboard", "Cmd_Dashboard")
    register_clcmd("say_team /dashboard", "Cmd_Dashboard")
    register_clcmd("say /wfpanel", "Cmd_Dashboard")
    register_clcmd("say_team /wfpanel", "Cmd_Dashboard")
    // /top15 and /stats are handled by the original stats plugin
    // HUD stats are accessible through /panel only
    // /admins and /cam: no provider plugins exist (verified in repo + live
    // trees) - the old quick-command entries for them were removed.
    // /vip is owned by the freenova_vip core (single owner - no duplicate here)

    // Admin commands
    register_clcmd("say /ban", "Cmd_Ban")
    register_clcmd("say_team /ban", "Cmd_Ban")
    register_clcmd("say /kick", "Cmd_Kick")
    register_clcmd("say_team /kick", "Cmd_Kick")
    register_clcmd("say /gag", "Cmd_Gag")
    register_clcmd("say_team /gag", "Cmd_Gag")
    register_clcmd("say /ungag", "Cmd_Ungag")
    register_clcmd("say_team /ungag", "Cmd_Ungag")
    register_concmd("amx_gagmenu", "Cmd_GagMenu", FLAG_ADMIN, "amx_gagmenu - open gag player menu")
    register_concmd("amx_ungagmenu", "Cmd_UngagMenu", FLAG_ADMIN, "amx_ungagmenu - open ungag player menu")
    // BP XP only. Rank XP keeps its existing rsu_give_xp / panel handler.
    register_concmd("amx_bp_givexp", "Cmd_AdminGiveBpXp", FLAG_MANAGER, "<name|#userid> <amount> - grant BattlePass XP only")
    register_clcmd("say /unban", "Cmd_Unban")
    register_clcmd("say_team /unban", "Cmd_Unban")
    register_clcmd("freenova_unban_input", "Cmd_UnbanInput")
    register_clcmd("freenova_ban_minutes", "Cmd_BanMinutes")
    register_clcmd("freenova_gag_minutes", "Cmd_GagMinutes")
    register_clcmd("freenova_addcoins_amount", "Cmd_AddCoinsAmount")

    // One long-lived handle per vault name. Load/save reuse these; never
    // nvault_open+close per call (AMXX nVault is one-handle-per-name).
    g_VaultStats = nvault_open(VAULT_NAME)
    if(g_VaultStats == INVALID_HANDLE)
        log_amx("[FreeNova Panel] Failed to open nvault '%s' - stats will not persist", VAULT_NAME)
    g_VaultVipAdmin = nvault_open(VAULT_VIPADMIN)

    // Double XP cvar (battlepass_core checks this)
    register_cvar("fn_double_xp", "0")

    // Bomb events for stat tracking
    // Using cstrike forwards: bomb_planted(id) / bomb_defused(id)

    // Round end for MVP tracking
    register_logevent("LogEvent_RoundEnd", 2, "1=Round_End")

    // Round-win tracking (STAT_WIN_CT/T were stored but never incremented)
    register_event("SendAudio", "Event_RoundWinAudio", "a", "2&%!MRAD_terwin", "2&%!MRAD_ctwin")

    // N key is owned by freenova_hub (player main menu). /panel remains
    // the admin + account surface.

    register_clcmd("say /slay", "Cmd_Slay")
    register_clcmd("say_team /slay", "Cmd_Slay")
    register_clcmd("say /slap", "Cmd_Slap")
    register_clcmd("say_team /slap", "Cmd_Slap")

    // Event system hooks
    RegisterHam(Ham_Spawn, "player", "Ham_PlayerSpawn_EventCheck", 1)
    register_event("CurWeapon", "Event_CurWeapon_ServerEvents", "be", "1=1")

    // Block buy commands during knife round / golden deagle
    register_forward(FM_ClientCommand, "FM_EventBlock_BuyCmd")
    register_clcmd("menuselect", "Cmd_BlockBuyMenu")

    // freeze window tracking (same pattern as battlepass_core) - guards the
    // PreThink maxspeed writes so they cannot un-freeze players at round start
    register_event("HLTV", "Event_NewRound", "a", "1=0", "2=0")
    register_logevent("Event_RoundStart", 2, "1=Round_Start")
    register_logevent("Event_RoundEnd_Freeze", 2, "1=Round_End")

    // crash protection: flush stats + playtime every 60s (previously the
    // only save point was client_disconnected)
    set_task(60.0, "Task_StatsAutoSave", TASK_AUTOSAVE, "", 0, "b")
}

// Periodic flush of every connected player's stats; playtime is banked from
// g_fConnectTime the same way client_disconnected does, then the anchor is
// reset so the next flush does not double-count the interval.
public Task_StatsAutoSave()
{
    new players[32], num
    get_players(players, num, "ch")

    for(new i = 0; i < num; i++)
    {
        new pid = players[i]
        if(!g_bStatsLoaded[pid])
            continue
        new Float:fPlayTime = get_gametime() - g_fConnectTime[pid]
        g_iPlayerStats[pid][STAT_PLAYTIME] += floatround(fPlayTime / 60.0)
        g_fConnectTime[pid] = get_gametime()
        SavePlayerStats(pid)
    }
}

public client_putinserver(id)
{
    g_iTargetPlayer[id] = 0
    g_iMenuPage[id] = 0
    g_bFrozen[id] = false
    g_fConnectTime[id] = get_gametime()
    arrayset(g_iPlayerStats[id], 0, _:PlayerStats)
    g_bStatsLoaded[id] = false
    g_iStatsLateTries[id] = 0
    // Never let a reused slot inherit an Add Coins target or confirmation.
    g_iAddCoinTarget[id] = 0
    g_iAddCoinUserid[id] = 0
    g_szAddCoinAuth[id][0] = 0
    g_iAddCoinPending[id] = 0
    g_iAddCoinToken[id] = 0
    g_iCoinRetryTries[id] = 0
    remove_task(id + TASK_COINRETRY)
    g_iXpTarget[id] = 0
    g_iXpUserid[id] = 0
    g_szXpAuth[id][0] = 0
    g_iBpXpTarget[id] = 0
    g_iBpXpUserid[id] = 0
    g_szBpXpAuth[id][0] = 0
    LoadPlayerStats(id)
    LoadVipFlags(id)
    // Deferred retry: LoadPlayerStats refuses pending authids. Reschedule
    // while still pending so a >3s Steam auth cannot save zeros over the
    // real stats#STEAM row.
    remove_task(id + TASK_LATELOAD)
    if(!g_bStatsLoaded[id])
        set_task(3.0, "Task_LateLoadStats", id + TASK_LATELOAD)

    // N key is handled SERVER-SIDE via the nightvision command hook.
    // No client binding = works even on restricted clients.
}

public Task_LateLoadStats(id)
{
    id -= TASK_LATELOAD
    if(!is_user_connected(id))
        return

    // Only retry when the immediate load was skipped (pending auth);
    // a loaded player's row must not be re-read over live session data.
    if(g_bStatsLoaded[id])
        return

    LoadPlayerStats(id)
    LoadVipFlags(id)

    if(!g_bStatsLoaded[id] && g_iStatsLateTries[id] < 3)
    {
        g_iStatsLateTries[id]++
        set_task(3.0, "Task_LateLoadStats", id + TASK_LATELOAD)
    }
}

public client_authorized(id)
{
    if(!is_user_connected(id) || g_bStatsLoaded[id])
        return
    LoadPlayerStats(id)
    LoadVipFlags(id)
    FlushPanelCoinPending(id)
    // If the wallet was still loading, keep retrying the parked deposit
    // instead of waiting for another admin action.
    if (PanelHasParkedCoins(id))
        SchedulePanelCoinRetry(id)
}

public client_disconnected(id)
{
    // Accumulate playtime only after a real Steam row was loaded — otherwise
    // a late-auth disconnect writes zeros over stats#STEAM_x_y_z.
    if(g_bStatsLoaded[id])
    {
        new Float:fPlayTime = get_gametime() - g_fConnectTime[id]
        g_iPlayerStats[id][STAT_PLAYTIME] += floatround(fPlayTime / 60.0)
        SavePlayerStats(id)
    }
    SaveVipFlags(id)
    g_iLastTarget[id] = 0
    g_szLastAction[id][0] = 0
    g_szLastAuth[id][0] = 0
    g_iAddCoinTarget[id] = 0
    g_iAddCoinUserid[id] = 0
    g_szAddCoinAuth[id][0] = 0
    g_iAddCoinPending[id] = 0
    g_iXpTarget[id] = 0
    g_iXpUserid[id] = 0
    g_szXpAuth[id][0] = 0
    g_iBpXpTarget[id] = 0
    g_iBpXpUserid[id] = 0
    g_szBpXpAuth[id][0] = 0
    remove_task(id + TASK_PANEL)
    remove_task(id + TASK_EVENT)
    remove_task(id + TASK_LATELOAD)
    remove_task(id + TASK_LOADOUT) // slot-reuse guard: cancel any pending event loadout
    remove_task(id + TASK_COINRETRY)
    g_iCoinRetryTries[id] = 0
    g_bStatsLoaded[id] = false

    // Stop grab if this player was grabbing
    if(g_bIsGrabbing[id])
        StopGrab(id)

    // Clear grab target if someone was grabbing this player
    for(new i = 1; i <= 32; i++)
    {
        if(g_bIsGrabbing[i] && g_iGrabTarget[i] == id)
            StopGrab(i)
    }

    // Clear freeze state
    g_bFrozen[id] = false
}

// ============================================================
// SAY COMMAND HANDLERS
// ============================================================
public Cmd_Ban(id)
{
    if(!is_user_connected(id)) return PLUGIN_HANDLED
    if(!(get_user_flags(id) & FLAG_ADMIN))
    {
        client_printcolor(id, "!g[FreeNova] !nAdmin only.")
        return PLUGIN_HANDLED
    }
    ShowPlayerSelect(id, "ban")
    return PLUGIN_HANDLED
}

public Cmd_Kick(id)
{
    if(!is_user_connected(id)) return PLUGIN_HANDLED
    if(!(get_user_flags(id) & FLAG_ADMIN))
    {
        client_printcolor(id, "!g[FreeNova] !nAdmin only.")
        return PLUGIN_HANDLED
    }
    ShowPlayerSelect(id, "kick")
    return PLUGIN_HANDLED
}

public Cmd_GagMenu(id, level, cid)
{
    if(!cmd_access(id, level, cid, 1))
        return PLUGIN_HANDLED
    ShowPlayerSelect(id, "gag")
    return PLUGIN_HANDLED
}

public Cmd_UngagMenu(id, level, cid)
{
    if(!cmd_access(id, level, cid, 1))
        return PLUGIN_HANDLED
    ShowPlayerSelect(id, "ungag")
    return PLUGIN_HANDLED
}

public Cmd_Gag(id)
{
    if(!is_user_connected(id)) return PLUGIN_HANDLED
    if(!(get_user_flags(id) & FLAG_ADMIN))
    {
        client_printcolor(id, "!g[FreeNova] !nAdmin only.")
        return PLUGIN_HANDLED
    }
    ShowPlayerSelect(id, "gag")
    return PLUGIN_HANDLED
}

public Cmd_Slay(id)
{
    if(!is_user_connected(id)) return PLUGIN_HANDLED
    if(!(get_user_flags(id) & FLAG_ADMIN))
    {
        client_printcolor(id, "!g[FreeNova] !nAdmin only.")
        return PLUGIN_HANDLED
    }
    ShowPlayerSelect(id, "slay")
    return PLUGIN_HANDLED
}

public Cmd_Slap(id)
{
    if(!is_user_connected(id)) return PLUGIN_HANDLED
    if(!(get_user_flags(id) & FLAG_ADMIN))
    {
        client_printcolor(id, "!g[FreeNova] !nAdmin only.")
        return PLUGIN_HANDLED
    }
    ShowPlayerSelect(id, "slap")
    return PLUGIN_HANDLED
}

// ============================================================
// PANEL OPEN
// ============================================================
public Cmd_OpenPanel(id)
{
    if(!is_user_connected(id))
        return PLUGIN_HANDLED

    if(!(get_user_flags(id) & FLAG_ADMIN))
    {
        // Players use the hub (N / /menu). Admins keep this panel.
        client_cmd(id, "say /menu")
        return PLUGIN_HANDLED
    }

    ShowAdminPanel(id)
    return PLUGIN_HANDLED
}

// Account hub: registration status + VIP entitlement snapshot (source and
// remaining time), so admins and players see where VIP came from.
ShowAccountInfo(id)
{
    new szTitle[64]
    FN_MenuTitle(szTitle, charsmax(szTitle), "My Account")
    new menu = menu_create(szTitle, "AccountInfoHandler")

    new szTier[16]
    fnvip_get_tier_name(id, szTier, charsmax(szTier))
    new remaining = fnvip_get_remaining(id)

    new szVip[64]
    if(remaining == 0)
        formatex(szVip, charsmax(szVip), "\wVIP: \y%s", szTier)
    else if(remaining == -1)
        formatex(szVip, charsmax(szVip), "\wVIP: \y%s \d(no expiry)", szTier)
    else
    {
        new days = remaining / 86400
        new hours = (remaining % 86400) / 3600
        formatex(szVip, charsmax(szVip), "\wVIP: \y%s \d(expires in %dd %dh)", szTier, days, hours)
    }

    menu_additem(menu, szVip, "0")
    menu_additem(menu, fnreg_is_available()
        ? (fnvip_is_registered_trial_claimed(id)
            ? "\wAccount: \yRegistered"
            : "\wAccount: \rNot registered - type /register")
        : "\wAccount: \dForum linking unavailable", "0")
    menu_additem(menu, "\wView VIP benefits", "1")
    menu_additem(menu, "\wBattlePass", "2")

    FN_MenuFinish(menu, true)
    menu_display(id, menu, 0)
}

public AccountInfoHandler(id, menu, item)
{
    if(item == MENU_EXIT)
    {
        menu_destroy(menu)
        ShowToolsPanel(id)
        return PLUGIN_HANDLED
    }

    new data[8], name[64], access, callback
    menu_item_getinfo(menu, item, access, data, charsmax(data), name, charsmax(name), callback)
    menu_destroy(menu)

    switch(str_to_num(data))
    {
        case 1: fnvip_show_vip_motd(id)
        case 2: menabp_show_battlepass(id)
    }

    return PLUGIN_HANDLED
}

// ============================================================
// PLAYER STATS
// ============================================================
ShowPlayerStats(id, targetId)
{
    new name[32]
    get_user_name(targetId, name, charsmax(name))

    new szTitle[64]
    FN_MenuTitle(szTitle, charsmax(szTitle), name)
    new menu = menu_create(szTitle, "StatsHandler")

    new k = g_iPlayerStats[targetId][STAT_KILLS]
    new d = g_iPlayerStats[targetId][STAT_DEATHS]
    new hs = g_iPlayerStats[targetId][STAT_HEADSHOTS]
    new kd = d > 0 ? k * 100 / d : k * 100

    new hsRate = k > 0 ? hs * 100 / k : 0

    menu_additem(menu, fmt("\wKills: \y%d", k), "x")
    menu_additem(menu, fmt("\wDeaths: \y%d", d), "x")
    menu_additem(menu, fmt("\wHeadshots: \y%d (%d%%)", hs, hsRate), "x")
    menu_additem(menu, fmt("\wK/D Ratio: \y%d%%", kd), "x")
    menu_additem(menu, fmt("\wBomb Plants: \y%d", g_iPlayerStats[targetId][STAT_BOMB_PLANTS]), "x")
    menu_additem(menu, fmt("\wBomb Defuses: \y%d", g_iPlayerStats[targetId][STAT_BOMB_DEFUSES]), "x")
    menu_additem(menu, fmt("\wCT Wins: \y%d", g_iPlayerStats[targetId][STAT_WIN_CT]), "x")
    menu_additem(menu, fmt("\wT Wins: \y%d", g_iPlayerStats[targetId][STAT_WIN_T]), "x")
    menu_additem(menu, fmt("\wMVPs: \y%d", g_iPlayerStats[targetId][STAT_MVP]), "x")
    menu_additem(menu, fmt("\wPlaytime: \y%d min", g_iPlayerStats[targetId][STAT_PLAYTIME]), "x")

    // Level info (target's progression, not the viewer's)
    new level = crxranks_get_user_level(targetId)
    new xp = crxranks_get_user_xp(targetId)
    new prestige = menabp_get_prestige(targetId)
    new coins = menabp_get_coins(targetId)

    menu_additem(menu, "\d ", "x")
    menu_additem(menu, fmt("\wLevel: \y%d/52 | XP: \y%d", level, xp), "x")
    menu_additem(menu, fmt("\wPrestige: \y%d | Coins: \y%d", prestige, coins), "x")

    FN_MenuFinish(menu, true)
    menu_display(id, menu, 0)
}

public StatsHandler(id, menu, item)
{
    if(item == MENU_EXIT)
    {
        menu_destroy(menu)
        ShowToolsPanel(id)
        return PLUGIN_HANDLED
    }
    if(item < 0)
        return PLUGIN_CONTINUE

    menu_destroy(menu)
    ShowPlayerStats(id, id)
    return PLUGIN_HANDLED
}

// ============================================================
// BEST PLAYERS
// ============================================================
ShowBestPlayers(id)
{
    new szTitle[64]
    FN_MenuTitle(szTitle, charsmax(szTitle), "Top Players")
    new menu = menu_create(szTitle, "BestPlayersHandler")

    // Simple ranking by kills
    new players[32], num, tempId
    new names[32][32]
    new scores[32]
    new count = 0

    get_players(players, num, "ch")

    for(new i = 0; i < num; i++)
    {
        tempId = players[i]
        get_user_name(tempId, names[count], 31)
        scores[count] = g_iPlayerStats[tempId][STAT_KILLS] * 2 +
                       g_iPlayerStats[tempId][STAT_HEADSHOTS] * 3 +
                       g_iPlayerStats[tempId][STAT_MVP] * 5 +
                       g_iPlayerStats[tempId][STAT_BOMB_PLANTS] * 4 +
                       g_iPlayerStats[tempId][STAT_BOMB_DEFUSES] * 6
        count++
    }

    // Sort by score (simple bubble sort)
    for(new i = 0; i < count - 1; i++)
    {
        for(new j = 0; j < count - i - 1; j++)
        {
            if(scores[j] < scores[j + 1])
            {
                // Swap scores
                new temp = scores[j]
                scores[j] = scores[j + 1]
                scores[j + 1] = temp

                // Swap names
                new tempName[32]
                copy(tempName, 31, names[j])
                copy(names[j], 31, names[j + 1])
                copy(names[j + 1], 31, tempName)
            }
        }
    }

    // Show top 10
    new limit = min(count, 10)
    for(new i = 0; i < limit; i++)
    {
        menu_additem(menu, fmt("\w#%d \y%s \w- \r%d pts", i + 1, names[i], scores[i]), "x")
    }

    if(count == 0)
    {
        menu_additem(menu, "\dNo players online", "x")
    }

    FN_MenuFinish(menu, true)
    menu_display(id, menu, 0)
}

public BestPlayersHandler(id, menu, item)
{
    if(item == MENU_EXIT)
    {
        menu_destroy(menu)
        ShowToolsPanel(id)
        return PLUGIN_HANDLED
    }
    if(item < 0)
        return PLUGIN_CONTINUE

    menu_destroy(menu)
    return PLUGIN_HANDLED
}

// ============================================================
// RESET SCORE
// ============================================================
ConfirmReset(id)
{
    new szTitle[64]
    FN_MenuTitle(szTitle, charsmax(szTitle), "Reset score?")
    new menu = menu_create(szTitle, "ResetScoreHandler")
    menu_additem(menu, "\wYes, \rreset my stats", "yes")
    menu_additem(menu, "\wNo, \ykeep them", "no")
    FN_MenuFinish(menu, true)
    menu_display(id, menu, 0)
}

public ResetScoreHandler(id, menu, item)
{
    if(item == MENU_EXIT)
    {
        menu_destroy(menu)
        ShowToolsPanel(id)
        return PLUGIN_HANDLED
    }

    new data[8], name[64], access, callback
    menu_item_getinfo(menu, item, access, data, charsmax(data), name, charsmax(name), callback)
    menu_destroy(menu)

    if(equal(data, "yes"))
    {
        arrayset(g_iPlayerStats[id], 0, _:PlayerStats)
        client_printcolor(id, "!g[FreeNova] !nYour score has been reset.")
    }

    return PLUGIN_HANDLED
}

// ============================================================
// ADMIN PANEL
// ============================================================
ShowAdminPanel(id)
{
    if(!(get_user_flags(id) & FLAG_ADMIN))
    {
        client_printcolor(id, "!g[FreeNova] !nAccess denied.")
        return
    }

    new players[32], iOnline
    get_players(players, iOnline, "ch")

    new iEvents = 0
    for(new i = EVENT_KNIFE_ROUND; i <= EVENT_LOW_GRAVITY; i++)
        if(g_bEventActive[i]) iEvents++

    new szTitle[64]
    FN_MenuTitle(szTitle, charsmax(szTitle), "Admin")
    new menu = menu_create(szTitle, "AdminPanelHandler")

    new szItem[96]
    formatex(szItem, charsmax(szItem), "\rModerate \d[ %d online ]", iOnline)
    menu_additem(menu, szItem, "moderate")
    menu_additem(menu, "\yEconomy \d[ Rank XP | BP XP | coins | VIP ]", "economy")
    if(iEvents)
        formatex(szItem, charsmax(szItem), "\yServer \d[ %d event ON | map | admins ]", iEvents)
    else
        formatex(szItem, charsmax(szItem), "\wServer \d[ events | map | admins ]")
    menu_additem(menu, szItem, "server")
    menu_additem(menu, "\wTools \d[ account | stats | reset ]", "tools")

    FN_MenuFinish(menu, false)
    menu_display(id, menu, 0)
}

public AdminPanelHandler(id, menu, item)
{
    if(item == MENU_EXIT)
    {
        menu_destroy(menu)
        return PLUGIN_HANDLED
    }
    if(item < 0)
        return PLUGIN_CONTINUE

    new data[16], name[64], access, callback
    menu_item_getinfo(menu, item, access, data, charsmax(data), name, charsmax(name), callback)
    menu_destroy(menu)

    if(equal(data, "moderate"))
        ShowModeratePanel(id)
    else if(equal(data, "economy"))
        ShowEconomyPanel(id)
    else if(equal(data, "server"))
        ShowServerPanel(id)
    else if(equal(data, "tools"))
        ShowToolsPanel(id)

    return PLUGIN_HANDLED
}

ShowModeratePanel(id)
{
    new szTitle[64]
    FN_MenuTitle(szTitle, charsmax(szTitle), "Moderate")
    new menu = menu_create(szTitle, "ModerateHandler")
    if (g_iLastTarget[id] > 0 && is_user_connected(g_iLastTarget[id]) && CanModerate(id, g_iLastTarget[id]))
    {
        new szLastName[32], szLastAuth[35]
        get_user_name(g_iLastTarget[id], szLastName, charsmax(szLastName))
        get_user_authid(g_iLastTarget[id], szLastAuth, charsmax(szLastAuth))
        if (equal(szLastAuth, g_szLastAuth[id]))
            menu_additem(menu, fmt("\yLast: \w%s \d[%s]", szLastName, g_szLastAction[id]), "last")
    }
    menu_additem(menu, "\rBan player", "ban")
    menu_additem(menu, "\wUnban", "unban")
    menu_additem(menu, "\wKick", "kick")
    menu_additem(menu, "\wGag", "gag")
    menu_additem(menu, "\wUngag", "ungag")
    menu_additem(menu, "\wSlay", "slay")
    menu_additem(menu, "\wSlap", "slap")
    menu_additem(menu, "\wFreeze", "freeze")
    menu_additem(menu, "\wGrab", "grab")
    FN_MenuFinish(menu, true)
    menu_display(id, menu, 0)
}

public ModerateHandler(id, menu, item)
{
    if(item == MENU_EXIT)
    {
        menu_destroy(menu)
        ShowAdminPanel(id)
        return PLUGIN_HANDLED
    }
    if(item < 0)
        return PLUGIN_CONTINUE

    new data[16], name[64], access, callback
    menu_item_getinfo(menu, item, access, data, charsmax(data), name, charsmax(name), callback)
    menu_destroy(menu)

    if(equal(data, "last"))
    {
        new tid = g_iLastTarget[id]
        if (tid > 0 && is_user_connected(tid) && CanModerate(id, tid))
        {
            new szAuth[35]
            get_user_authid(tid, szAuth, charsmax(szAuth))
            if (equal(szAuth, g_szLastAuth[id]) && g_szLastAction[id][0])
                DispatchModerateAction(id, tid, g_szLastAction[id])
            else
                client_printcolor(id, "!g[FreeNova] !nThat player left; pick again.")
        }
        else
            ShowModeratePanel(id)
    }
    else if(equal(data, "ban"))
        ShowPlayerSelect(id, "ban")
    else if(equal(data, "unban"))
        ShowUnbanPanel(id)
    else if(equal(data, "kick"))
        ShowPlayerSelect(id, "kick")
    else if(equal(data, "gag"))
        ShowPlayerSelect(id, "gag")
    else if(equal(data, "ungag"))
        ShowPlayerSelect(id, "ungag")
    else if(equal(data, "slay"))
        ShowPlayerSelect(id, "slay")
    else if(equal(data, "slap"))
        ShowPlayerSelect(id, "slap")
    else if(equal(data, "freeze"))
        ShowPlayerSelect(id, "freeze")
    else if(equal(data, "grab"))
        ShowPlayerSelect(id, "grab")
    return PLUGIN_HANDLED
}

ShowEconomyPanel(id)
{
    new szTitle[64]
    FN_MenuTitle(szTitle, charsmax(szTitle), "Economy")
    new menu = menu_create(szTitle, "EconomyHandler")
    menu_additem(menu, "\wGive Rank XP", "givexp")
    menu_additem(menu, "\wGive BP XP", "givebpxp")
    menu_additem(menu, "\wCoins", "coins")
    menu_additem(menu, "\yAdd Coins \d(manager)", "addcoins")
    menu_additem(menu, "\yVIP grant / revoke", "vip")
    FN_MenuFinish(menu, true)
    menu_display(id, menu, 0)
}

public EconomyHandler(id, menu, item)
{
    if(item == MENU_EXIT)
    {
        menu_destroy(menu)
        ShowAdminPanel(id)
        return PLUGIN_HANDLED
    }
    if(item < 0)
        return PLUGIN_CONTINUE

    new data[16], name[64], access, callback
    menu_item_getinfo(menu, item, access, data, charsmax(data), name, charsmax(name), callback)
    menu_destroy(menu)

    if(equal(data, "givexp"))
        ShowGiveXP(id)
    else if(equal(data, "givebpxp"))
        ShowGiveBpXP(id)
    else if(equal(data, "coins"))
        ShowCoinPlayerSelect(id)
    else if(equal(data, "addcoins"))
        ShowAddCoinPlayerSelect(id)
    else if(equal(data, "vip"))
        ShowVIPManagement(id)
    return PLUGIN_HANDLED
}

ShowServerPanel(id)
{
    new iEvents = 0
    for(new i = EVENT_KNIFE_ROUND; i <= EVENT_LOW_GRAVITY; i++)
        if(g_bEventActive[i]) iEvents++

    new szMap[32]
    get_mapname(szMap, charsmax(szMap))

    new szTitle[64]
    FN_MenuTitle(szTitle, charsmax(szTitle), "Server")
    new menu = menu_create(szTitle, "ServerHandler")

    new szItem[96]
    if(iEvents)
        formatex(szItem, charsmax(szItem), "\yEvents \d[ %d ON ]", iEvents)
    else
        formatex(szItem, charsmax(szItem), "\wEvents")
    menu_additem(menu, szItem, "events")
    formatex(szItem, charsmax(szItem), "\wRound / Map \d[ %s ]", szMap)
    menu_additem(menu, szItem, "round")
    menu_additem(menu, "\wAdmins", "admin")
    FN_MenuFinish(menu, true)
    menu_display(id, menu, 0)
}

public ServerHandler(id, menu, item)
{
    if(item == MENU_EXIT)
    {
        menu_destroy(menu)
        ShowAdminPanel(id)
        return PLUGIN_HANDLED
    }
    if(item < 0)
        return PLUGIN_CONTINUE

    new data[16], name[64], access, callback
    menu_item_getinfo(menu, item, access, data, charsmax(data), name, charsmax(name), callback)
    menu_destroy(menu)

    if(equal(data, "events"))
        ShowEventsPanel(id)
    else if(equal(data, "round"))
        ShowRoundSettings(id)
    else if(equal(data, "admin"))
        ShowAdminManagement(id)
    return PLUGIN_HANDLED
}

ShowToolsPanel(id)
{
    new szTitle[64]
    FN_MenuTitle(szTitle, charsmax(szTitle), "Tools")
    new menu = menu_create(szTitle, "ToolsHandler")
    menu_additem(menu, "\wMy Account", "account")
    menu_additem(menu, "\wLocal Stats", "stats")
    menu_additem(menu, "\wTop Players (this map)", "best")
    menu_additem(menu, "\wQuick Commands", "quick")
    menu_additem(menu, "\rReset local score", "resetscore")
    FN_MenuFinish(menu, true)
    menu_display(id, menu, 0)
}

public ToolsHandler(id, menu, item)
{
    if(item == MENU_EXIT)
    {
        menu_destroy(menu)
        ShowAdminPanel(id)
        return PLUGIN_HANDLED
    }
    if(item < 0)
        return PLUGIN_CONTINUE

    new data[16], name[64], access, callback
    menu_item_getinfo(menu, item, access, data, charsmax(data), name, charsmax(name), callback)
    menu_destroy(menu)

    if(equal(data, "account"))
        ShowAccountInfo(id)
    else if(equal(data, "stats"))
        ShowPlayerStats(id, id)
    else if(equal(data, "best"))
        ShowBestPlayers(id)
    else if(equal(data, "quick"))
        ShowQuickCommands(id)
    else if(equal(data, "resetscore"))
        ConfirmReset(id)
    return PLUGIN_HANDLED
}

// ============================================================
// PLAYER SELECTOR (for admin actions)
// ============================================================
// Single dispatch for every moderation action (player-select + last-target
// repeat share it, so both paths validate and record identically).
stock DispatchModerateAction(id, tid, const action[])
{
    g_iBanTarget[id] = tid
    g_iBanUserid[id] = get_user_userid(tid)
    get_user_authid(tid, g_szBanAuth[id], charsmax(g_szBanAuth[]))
    g_iLastTarget[id] = tid
    copy(g_szLastAction[id], charsmax(g_szLastAction[]), action)
    copy(g_szLastAuth[id], charsmax(g_szLastAuth[]), g_szBanAuth[id])
    if(equal(action, "ban"))
        ExecuteBan(id, tid)
    else if(equal(action, "kick") || equal(action, "slay") || equal(action, "slap") || equal(action, "freeze"))
        ShowActionConfirm(id, tid, action)
    else if(equal(action, "gag"))
        ExecuteGag(id, tid)
    else if(equal(action, "ungag"))
    {
        if(!PanelBanTargetValid(id))
        {
            client_printcolor(id, "!g[FreeNova] !nPlayer is no longer connected or slot was reused.")
            return
        }
        ExecuteUngag(id, tid)
    }
    else if(equal(action, "grab"))
    {
        if(!PanelBanTargetValid(id))
        {
            client_printcolor(id, "!g[FreeNova] !nPlayer is no longer connected or slot was reused.")
            return
        }
        if(!(get_user_flags(id) & FLAG_ADMIN) || !CanModerate(id, tid))
        {
            client_printcolor(id, "!g[FreeNova] !nYou cannot grab this player.")
            return
        }
        ExecuteGrab(id, tid)
    }
}

ShowPlayerSelect(id, const action[])
{
    new szPage[32], szTitle[64]
    formatex(szPage, charsmax(szPage), "Select - %s", action)
    FN_MenuTitle(szTitle, charsmax(szTitle), szPage)
    new menu = menu_create(szTitle, "PlayerSelectHandler")

    new players[32], num, tempId, name[32]
    // no "a" flag: dead players must be moderable too (ban/kick/gag a leaver
    // or someone who died mid-round); bots are excluded via "h"
    get_players(players, num, "ch")

    for(new i = 0; i < num; i++)
    {
        tempId = players[i]

        // M13: never silently hide self; hierarchy enforced at fire time.
        // Self proceeds only for self-capable actions (gag/ungag/slap/slay).
        if(tempId != id && !CanModerate(id, tempId))
            continue

        get_user_name(tempId, name, charsmax(name))

        // P2-7 draw-time snapshot: userid+authid per item so fire time can
        // detect slot reuse (compare idiom mirrors PanelBanTargetValid).
        new iSnapUid = get_user_userid(tempId)
        new szSnapAuth[35]
        get_user_authid(tempId, szSnapAuth, charsmax(szSnapAuth))

        new targetFlags = get_user_flags(tempId)
        new szRole[16] = ""
        if(targetFlags & FLAG_MANAGER)
            copy(szRole, charsmax(szRole), "MGR")
        else if(targetFlags & FLAG_MOD_ADMIN)
            copy(szRole, charsmax(szRole), "ADM")

        new iVip = fnvip_get_tier(tempId)
        new szVip[8]
        fnvip_get_tier_name_raw(iVip, szVip, charsmax(szVip))
        if(!szVip[0] || iVip < 1)
            copy(szVip, charsmax(szVip), "-")

        new iHp = is_user_alive(tempId) ? get_user_health(tempId) : 0
        if(szRole[0])
            menu_additem(menu, fmt("\w%s \d[ L%d | %s | %s | %dhp ]", name, crxranks_get_user_level(tempId), szVip, szRole, iHp), fmt("%d %s %d %s", tempId, action, iSnapUid, szSnapAuth))
        else
            menu_additem(menu, fmt("\w%s \d[ L%d | %s | %dhp ]", name, crxranks_get_user_level(tempId), szVip, iHp), fmt("%d %s %d %s", tempId, action, iSnapUid, szSnapAuth))
    }

    if(menu_items(menu) == 0)
    {
        menu_additem(menu, "\dNo players you can moderate", "x")
    }

    FN_MenuFinish(menu, true)
    menu_display(id, menu, 0)
}

public PlayerSelectHandler(id, menu, item)
{
    if(item == MENU_EXIT)
    {
        menu_destroy(menu)
        ShowModeratePanel(id)
        return PLUGIN_HANDLED
    }
    if(item < 0)
        return PLUGIN_CONTINUE

    new data[64], name[64], access, callback
    menu_item_getinfo(menu, item, access, data, charsmax(data), name, charsmax(name), callback)
    menu_destroy(menu)

    new targetId[8], action[16], snapUid[16], snapAuth[35]
    parse(data, targetId, charsmax(targetId), action, charsmax(action), snapUid, charsmax(snapUid), snapAuth, charsmax(snapAuth))
    new tid = str_to_num(targetId)

    if(!is_user_connected(tid))
    {
        fn_chat_error(id, "This player is no longer connected. Please select another player.")
        return PLUGIN_HANDLED
    }

    // P2-7 fire-time snapshot compare (draw -> fire): slap/slay/freeze/grab
    // dispatch off this single check, so reject a reused slot here. Gag/ban
    // get a second save downstream via PanelBanTargetValid. Wrong-occupant
    // drill (code path, no live test): A opens select on slot 5 (uid 100,
    // auth STEAM_X), target leaves, B joins same slot (new uid/auth), A
    // presses the stale item -> uid/auth mismatch below -> error, no action.
    if(snapUid[0])
    {
        if(get_user_userid(tid) != str_to_num(snapUid))
        {
            fn_chat_error(id, "This player is no longer connected. Slot may have been reused.")
            return PLUGIN_HANDLED
        }
        if(snapAuth[0])
        {
            new curAuth[35]
            get_user_authid(tid, curAuth, charsmax(curAuth))
            if(!equal(curAuth, snapAuth))
            {
                fn_chat_error(id, "This player is no longer connected. Slot may have been reused.")
                return PLUGIN_HANDLED
            }
        }
    }

    // M13 execution-time validation: self only for self-capable actions,
    // everyone else through the hierarchy. Never fail silently.
    if(tid == id)
    {
        if(!FN_SelfAllowedName(action))
        {
            fn_chat_permission(id, "You cannot use %s on yourself.", action)
            return PLUGIN_HANDLED
        }
    }
    else if(!CanModerate(id, tid))
    {
        fn_chat_error(id, "This player is immune to your administrative actions.")
        return PLUGIN_HANDLED
    }

    DispatchModerateAction(id, tid, action)

    return PLUGIN_HANDLED
}

ShowActionConfirm(id, tid, const action[])
{
    if(!is_user_connected(tid))
        return

    g_iBanTarget[id] = tid
    g_iBanUserid[id] = get_user_userid(tid)
    get_user_authid(tid, g_szBanAuth[id], charsmax(g_szBanAuth[]))
    copy(g_szConfirmAction[id], charsmax(g_szConfirmAction[]), action)

    new targetName[32]
    get_user_name(tid, targetName, charsmax(targetName))

    new szTitle[64]
    FN_MenuTitle(szTitle, charsmax(szTitle), "Confirm")
    new menu = menu_create(szTitle, "ActionConfirmHandler")
    menu_additem(menu, fmt("\wYes, \r%s \y%s", action, targetName), "yes")
    menu_additem(menu, "\wNo, cancel", "no")
    FN_MenuFinish(menu, true)
    menu_display(id, menu, 0)
}

public ActionConfirmHandler(id, menu, item)
{
    if(item == MENU_EXIT)
    {
        menu_destroy(menu)
        ShowModeratePanel(id)
        return PLUGIN_HANDLED
    }

    new data[8], name[64], access, callback
    menu_item_getinfo(menu, item, access, data, charsmax(data), name, charsmax(name), callback)
    menu_destroy(menu)

    if(!equal(data, "yes"))
        return PLUGIN_HANDLED

    if(!PanelBanTargetValid(id))
    {
        client_printcolor(id, "!g[FreeNova] !nPlayer is no longer connected or slot was reused.")
        return PLUGIN_HANDLED
    }

    new tid = g_iBanTarget[id]
    if(!CanModerate(id, tid))
    {
        client_printcolor(id, "!g[FreeNova] !nYou cannot moderate this player.")
        return PLUGIN_HANDLED
    }
    if(equal(g_szConfirmAction[id], "kick"))
        ExecuteKick(id, tid)
    else if(equal(g_szConfirmAction[id], "slay"))
        ExecuteSlay(id, tid)
    else if(equal(g_szConfirmAction[id], "slap"))
        ExecuteSlap(id, tid)
    else if(equal(g_szConfirmAction[id], "freeze"))
        ExecuteFreeze(id, tid)

    return PLUGIN_HANDLED
}

// ============================================================
// ADMIN ACTIONS
// ============================================================
ExecuteSlay(id, tid)
{
    new name[32]
    get_user_name(tid, name, charsmax(name))

    if(!is_user_alive(tid))
    {
        client_printcolor(id, "!g[FreeNova] !n%s is not alive.", name)
        return
    }

    user_kill(tid, 1)
    client_printcolor(0, "!g[FreeNova] !t%s !nwas slain by an admin!", name)
    log_amx("[FreeNova] Admin slew %s", name)
}

ExecuteSlap(id, tid)
{
    new name[32]
    get_user_name(tid, name, charsmax(name))

    if(!is_user_alive(tid))
    {
        client_printcolor(id, "!g[FreeNova] !n%s is not alive.", name)
        return
    }

    user_slap(tid, 25)
    client_printcolor(0, "!g[FreeNova] !t%s !nwas slapped by an admin!", name)
    log_amx("[FreeNova] Admin slapped %s", name)
}

ExecuteBan(id, tid)
{
    if( !is_user_connected(tid) ) return
    g_iBanTarget[id] = tid
    g_iBanUserid[id] = get_user_userid(tid)
    get_user_authid(tid, g_szBanAuth[id], charsmax(g_szBanAuth[]))
    ShowBanTimeSelect(id)
}

bool:PanelBanTargetValid(id)
{
    new tid = g_iBanTarget[id]
    if( !tid || !is_user_connected(tid) ) return false
    if( get_user_userid(tid) != g_iBanUserid[id] ) return false
    new auth[35]
    get_user_authid(tid, auth, charsmax(auth))
    if( g_szBanAuth[id][0] && !equal(auth, g_szBanAuth[id]) ) return false
    return true
}

ShowBanTimeSelect(id)
{
    if(!PanelBanTargetValid(id))
    {
        client_printcolor(id, "!g[FreeNova] !nPlayer is no longer connected or slot was reused.")
        return
    }

    new szTitle[64]
    FN_MenuTitle(szTitle, charsmax(szTitle), "Ban time")
    new menu = menu_create(szTitle, "BanTimeHandler")

    new tid = g_iBanTarget[id]
    new targetName[32]
    get_user_name(tid, targetName, charsmax(targetName))

    menu_additem(menu, fmt("\wBan \y%s \w- \r10 Minutes", targetName), "10")
    menu_additem(menu, fmt("\wBan \y%s \w- \r30 Minutes", targetName), "30")
    menu_additem(menu, fmt("\wBan \y%s \w- \r1 Hour", targetName), "60")
    menu_additem(menu, fmt("\wBan \y%s \w- \r6 Hours", targetName), "360")
    menu_additem(menu, fmt("\wBan \y%s \w- \r24 Hours", targetName), "1440")
    menu_additem(menu, fmt("\wBan \y%s \w- \r7 Days", targetName), "10080")
    menu_additem(menu, fmt("\wBan \y%s \w- \rPermanent", targetName), "0")
    menu_additem(menu, fmt("\wBan \y%s \w- \yCustom minutes", targetName), "custom")

    FN_MenuFinish(menu, true)
    menu_display(id, menu, 0)
}

public BanTimeHandler(id, menu, item)
{
    if(item == MENU_EXIT)
    {
        menu_destroy(menu)
        ShowModeratePanel(id)
        return PLUGIN_HANDLED
    }
    if(item < 0)
        return PLUGIN_CONTINUE

    new data[16], name[64], access, callback
    menu_item_getinfo(menu, item, access, data, charsmax(data), name, charsmax(name), callback)
    menu_destroy(menu)

    if( !PanelBanTargetValid(id) )
    {
        fn_chat_error(id, "This player is no longer connected. Slot may have been reused.")
        return PLUGIN_HANDLED
    }
    // Ban is never self-applied (matrix); hierarchy enforced for everyone.
    if(!CanModerate(id, g_iBanTarget[id]))
    {
        fn_chat_error(id, "This player is immune to your administrative actions.")
        return PLUGIN_HANDLED
    }

    if(equal(data, "custom"))
    {
        client_printcolor(id, "!g[FreeNova] !nType ban duration in minutes (0 = permanent).")
        client_cmd(id, "messagemode freenova_ban_minutes")
        return PLUGIN_HANDLED
    }

    g_iBanTime[id] = str_to_num(data)
    ShowBanReasonSelect(id)

    return PLUGIN_HANDLED
}

public Cmd_BanMinutes(id)
{
    if(!is_user_connected(id) || !(get_user_flags(id) & FLAG_ADMIN))
        return PLUGIN_HANDLED

    new arg[16]
    read_args(arg, charsmax(arg))
    remove_quotes(arg)
    trim(arg)

    new minutes = str_to_num(arg)
    if(minutes < 0)
        minutes = 0

    if(!PanelBanTargetValid(id))
    {
        client_printcolor(id, "!g[FreeNova] !nPlayer is no longer connected or slot was reused.")
        return PLUGIN_HANDLED
    }

    g_iBanTime[id] = minutes
    ShowBanReasonSelect(id)
    return PLUGIN_HANDLED
}

ShowBanReasonSelect(id)
{
    new szTitle[64]
    FN_MenuTitle(szTitle, charsmax(szTitle), "Ban reason")
    new menu = menu_create(szTitle, "BanReasonHandler")

    menu_additem(menu, "\wCheating", "0")
    menu_additem(menu, "\wExploiting", "1")
    menu_additem(menu, "\wOffensive Language", "2")
    menu_additem(menu, "\wGriefing / Team Killing", "3")
    menu_additem(menu, "\wSpamming", "4")
    menu_additem(menu, "\wMic Spam", "5")
    menu_additem(menu, "\wBreaking Rules", "6")
    menu_additem(menu, "\wAdmin Abuse", "7")
    menu_additem(menu, "\wOther", "8")

    FN_MenuFinish(menu, true)
    menu_display(id, menu, 0)
}

public BanReasonHandler(id, menu, item)
{
    if(item == MENU_EXIT || item == MENU_BACK)
    {
        menu_destroy(menu)
        ShowBanTimeSelect(id)
        return PLUGIN_HANDLED
    }
    if(item == MENU_MORE)
        return PLUGIN_CONTINUE

    new reasons[9][32] = {
        "Cheating",
        "Exploiting",
        "Offensive Language",
        "Griefing / Team Killing",
        "Spamming",
        "Mic Spam",
        "Breaking Rules",
        "Admin Abuse",
        "Other"
    }

    new data[8], name[64], access, callback
    menu_item_getinfo(menu, item, access, data, charsmax(data), name, charsmax(name), callback)
    menu_destroy(menu)

    new reasonIdx = str_to_num(data)
    if(reasonIdx < 0 || reasonIdx >= 9)
        return PLUGIN_HANDLED

    if( !PanelBanTargetValid(id) )
    {
        client_printcolor(id, "!g[FreeNova] !nPlayer is no longer connected or slot was reused.")
        return PLUGIN_HANDLED
    }

    new tid = g_iBanTarget[id]
    if(!CanModerate(id, tid))
    {
        client_printcolor(id, "!g[FreeNova] !nYou cannot moderate this player.")
        return PLUGIN_HANDLED
    }
    // Fail-closed: ban stack unloaded -> admin message, NO native call (no
    // kick, no DB row, target untouched), failure logged so web retries.
    if(!CBanUsable())
    {
        client_printcolor(id, "!g[FreeNova] !nBan system unavailable - no ban was applied. Try again later.")
        log_amx("[FreeNova] CBan unavailable; ban by admin %d on target %d FAILED (not applied)", id, tid)
        return PLUGIN_HANDLED
    }
    CBan_BanPlayer(id, tid, g_iBanTime[id], reasons[reasonIdx])

    new targetName[32], adminName[32]
    get_user_name(tid, targetName, charsmax(targetName))
    get_user_name(id, adminName, charsmax(adminName))
    log_amx("[FreeNova] Admin %s banned player %s for reason: %s", adminName, targetName, reasons[reasonIdx])

    return PLUGIN_HANDLED
}

ExecuteKick(id, tid)
{
    new name[32]
    get_user_name(tid, name, charsmax(name))

    server_cmd("kick #%d ^"Kicked by admin^"", get_user_userid(tid))

    new adminName[32]
    get_user_name(id, adminName, charsmax(adminName))
    log_amx("[FreeNova] Admin %s kicked player %s", adminName, name)
}

ExecuteGag(id, tid)
{
    // M13 entry guard: explain instead of silently returning. Self is
    // always admitted for gag; others go through the hierarchy.
    if(!is_user_connected(tid))
    {
        fn_chat_error(id, "This player is no longer connected. Please select another player.")
        return
    }
    if(tid != id && !CanModerate(id, tid))
    {
        fn_chat_permission(id, "This player is immune to your administrative actions.")
        return
    }
    g_iGagTarget[id] = tid
    g_iBanTarget[id] = tid
    g_iBanUserid[id] = get_user_userid(tid)
    get_user_authid(tid, g_szBanAuth[id], charsmax(g_szBanAuth[]))
    ShowGagTimeSelect(id)
}

ShowGagTimeSelect(id)
{
    if( !PanelBanTargetValid(id) )
    {
        client_printcolor(id, "!g[FreeNova] !nPlayer is no longer connected or slot was reused.")
        return
    }

    new szTitle[64]
    FN_MenuTitle(szTitle, charsmax(szTitle), "Gag time")
    new menu = menu_create(szTitle, "GagTimeHandler")

    new tid = g_iBanTarget[id]
    g_iGagTarget[id] = tid
    new targetName[32]
    get_user_name(tid, targetName, charsmax(targetName))

    menu_additem(menu, fmt("\wGag \y%s \w- \r5 Minutes", targetName), "5")
    menu_additem(menu, fmt("\wGag \y%s \w- \r10 Minutes", targetName), "10")
    menu_additem(menu, fmt("\wGag \y%s \w- \r30 Minutes", targetName), "30")
    menu_additem(menu, fmt("\wGag \y%s \w- \r1 Hour", targetName), "60")
    menu_additem(menu, fmt("\wGag \y%s \w- \r24 Hours", targetName), "1440")
    menu_additem(menu, fmt("\wGag \y%s \w- \rPermanent", targetName), "0")
    menu_additem(menu, fmt("\wGag \y%s \w- \yCustom minutes", targetName), "custom")

    FN_MenuFinish(menu, true)
    menu_display(id, menu, 0)
}

public GagTimeHandler(id, menu, item)
{
    if(item == MENU_EXIT)
    {
        menu_destroy(menu)
        ShowModeratePanel(id)
        return PLUGIN_HANDLED
    }
    if(item < 0)
        return PLUGIN_CONTINUE

    new data[16], name[64], access, callback
    menu_item_getinfo(menu, item, access, data, charsmax(data), name, charsmax(name), callback)
    menu_destroy(menu)

    if( !PanelBanTargetValid(id) )
    {
        fn_chat_error(id, "This player is no longer connected. Slot may have been reused.")
        return PLUGIN_HANDLED
    }
    // M13: gag is self-capable; hierarchy revalidates for everyone else.
    new iTGT = g_iBanTarget[id]
    if(iTGT != id && !CanModerate(id, iTGT))
    {
        fn_chat_error(id, "This player is immune to your administrative actions.")
        return PLUGIN_HANDLED
    }

    if(equal(data, "custom"))
    {
        client_printcolor(id, "!g[FreeNova] !nType gag duration in minutes (0 = permanent).")
        client_cmd(id, "messagemode freenova_gag_minutes")
        return PLUGIN_HANDLED
    }

    g_iGagTime[id] = str_to_num(data)
    ShowGagTypeSelect(id)

    return PLUGIN_HANDLED
}

public Cmd_GagMinutes(id)
{
    if(!is_user_connected(id) || !(get_user_flags(id) & FLAG_ADMIN))
        return PLUGIN_HANDLED

    new arg[16]
    read_args(arg, charsmax(arg))
    remove_quotes(arg)
    trim(arg)

    new minutes = str_to_num(arg)
    if(minutes < 0)
        minutes = 0

    if(!PanelBanTargetValid(id))
    {
        client_printcolor(id, "!g[FreeNova] !nPlayer is no longer connected or slot was reused.")
        return PLUGIN_HANDLED
    }

    g_iGagTime[id] = minutes
    ShowGagTypeSelect(id)
    return PLUGIN_HANDLED
}

ShowGagTypeSelect(id)
{
    if( !PanelBanTargetValid(id) )
    {
        client_printcolor(id, "!g[FreeNova] !nPlayer is no longer connected or slot was reused.")
        return
    }

    new szTitle[64]
    FN_MenuTitle(szTitle, charsmax(szTitle), "Gag type")
    new menu = menu_create(szTitle, "GagTypeHandler")

    new tid = g_iBanTarget[id]
    g_iGagTarget[id] = tid
    new targetName[32]
    get_user_name(tid, targetName, charsmax(targetName))

    menu_additem(menu, fmt("\wMute \y%s \w- \rChat", targetName), "a")
    menu_additem(menu, fmt("\wMute \y%s \w- \rTeam Chat", targetName), "b")
    menu_additem(menu, fmt("\wMute \y%s \w- \rVoice Communications", targetName), "c")

    FN_MenuFinish(menu, true)
    menu_display(id, menu, 0)
}

public GagTypeHandler(id, menu, item)
{
    if(item == MENU_EXIT)
    {
        menu_destroy(menu)
        ShowModeratePanel(id)
        return PLUGIN_HANDLED
    }
    if(item < 0)
        return PLUGIN_CONTINUE

    new data[16], name[64], access, callback
    menu_item_getinfo(menu, item, access, data, charsmax(data), name, charsmax(name), callback)
    menu_destroy(menu)

    if( !PanelBanTargetValid(id) )
    {
        client_printcolor(id, "!g[FreeNova] !nPlayer is no longer connected or slot was reused.")
        return PLUGIN_HANDLED
    }

    // P2-6: same self-aware re-check as GagTimeHandler; immunity granted
    // between time select and type select must not slip through.
    new tid = g_iBanTarget[id]
    if(tid != id && !CanModerate(id, tid))
    {
        fn_chat_error(id, "This player is immune to your administrative actions.")
        return PLUGIN_HANDLED
    }
    g_iGagTarget[id] = tid

    new targetName[32], adminName[32]
    get_user_name(tid, targetName, charsmax(targetName))
    get_user_name(id, adminName, charsmax(adminName))

    // Correct syntax: amx_gag <nick or #userid> <time> <a|b|c> [reason]
    // a = Chat, b = Team Chat, c = Voice Communications
    server_cmd("amx_gag #%d %d %s", get_user_userid(tid), g_iGagTime[id], data)

    log_amx("[FreeNova] Admin %s requested gag for player %s (type: %s, time: %d min)", adminName, targetName, data, g_iGagTime[id])

    // M13: request-accepted, not success. The gag plugin notifies the target
    // and audits to console; claiming success here would be optimistic.
    if(g_iGagTime[id] > 0)
        fn_chat_info(id, "Gag request for %s (%d minutes) sent.", targetName, g_iGagTime[id])
    else
        fn_chat_info(id, "Permanent gag request for %s sent.", targetName)

    return PLUGIN_HANDLED
}

// ============================================================
// UNBAN
// ============================================================
ShowUnbanPanel(id)
{
    new iCount = 0
    if(CBanUsable())
        iCount = CBan_GetBanCount()

    new szTitle[64]
    FN_MenuTitle(szTitle, charsmax(szTitle), "Active bans")
    new menu = menu_create(szTitle, "UnbanListHandler")

    new iBanId, szName[32], szIdentity[35], szReason[128]
    new iLength, szUnban[32], szItem[180], szData[8], szDuration[16]
    for(new i = 0; i < iCount; i++)
    {
        if(!CBan_GetBanInfo(i, iBanId, szName, charsmax(szName),
            szIdentity, charsmax(szIdentity), szReason, charsmax(szReason),
            iLength, szUnban, charsmax(szUnban)))
            continue

        if(iLength > 0)
            formatex(szDuration, charsmax(szDuration), "%d min", iLength)
        else
            copy(szDuration, charsmax(szDuration), "permanent")

        formatex(szItem, charsmax(szItem), "\y#%d \w%s \d[%s] \y%s \d(%s)",
            iBanId, szName, szIdentity, szReason, szDuration)
        formatex(szData, charsmax(szData), "%d", iBanId)
        menu_additem(menu, szItem, szData)
    }

    if(!iCount)
        menu_additem(menu, "\dNo active bans", "none")

    menu_additem(menu, "\wManual unban (SteamID / IP / nick)", "manual")
    FN_MenuFinish(menu, true)
    menu_display(id, menu, 0)
}

public UnbanListHandler(id, menu, item)
{
    if(item == MENU_EXIT)
    {
        menu_destroy(menu)
        ShowModeratePanel(id)
        return PLUGIN_HANDLED
    }

    new szData[8], szName[64], iAccess, iCallback
    menu_item_getinfo(menu, item, iAccess, szData, charsmax(szData), szName, charsmax(szName), iCallback)
    menu_destroy(menu)

    if(equal(szData, "manual"))
    {
        ShowUnbanMethodPanel(id)
        return PLUGIN_HANDLED
    }
    if(equal(szData, "none"))
    {
        ShowUnbanPanel(id)
        return PLUGIN_HANDLED
    }

    if(!CBanUsable())
    {
        client_printcolor(id, "!g[FreeNova] !nBan system unavailable - no unban was applied.")
        return PLUGIN_HANDLED
    }

    new iBanId = str_to_num(szData)
    if(CBan_UnbanById(id, iBanId))
        client_printcolor(id, "!g[FreeNova] !nBan #%d removed.", iBanId)
    else
        client_printcolor(id, "!g[FreeNova] !nBan #%d is no longer active.", iBanId)

    ShowUnbanPanel(id)
    return PLUGIN_HANDLED
}

ShowUnbanMethodPanel(id)
{
    new szTitle[64]
    FN_MenuTitle(szTitle, charsmax(szTitle), "Manual unban")
    new menu = menu_create(szTitle, "UnbanMethodHandler")
    menu_additem(menu, "\wBy \yNick", "nick")
    menu_additem(menu, "\wBy \ySteamID", "steamid")
    menu_additem(menu, "\wBy \yIP", "ip")
    FN_MenuFinish(menu, true)
    menu_display(id, menu, 0)
}

public UnbanMethodHandler(id, menu, item)
{
    if(item == MENU_EXIT)
    {
        menu_destroy(menu)
        ShowUnbanPanel(id)
        return PLUGIN_HANDLED
    }

    // Save unban type and prompt for input
    new data[8], name[64], access, callback
    menu_item_getinfo(menu, item, access, data, charsmax(data), name, charsmax(name), callback)
    menu_destroy(menu)
    copy(g_unbanTarget[id], charsmax(g_unbanTarget[]), data)

    set_hudmessage(255, 255, 255, -1.0, 0.35, 0, 0.0, 8.0, 0.0, 0.0, -1)
    show_hudmessage(id, "Type the target %s, then press Enter:", data)
    client_printcolor(id, "!g[FreeNova] !nType the %s to unban.", data)
    client_cmd(id, "messagemode freenova_unban_input")

    return PLUGIN_HANDLED
}

public Cmd_UnbanInput(id)
{
    if(!is_user_connected(id) || !(get_user_flags(id) & FLAG_ADMIN))
        return PLUGIN_HANDLED

    new arg[64]
    read_args(arg, charsmax(arg))
    remove_quotes(arg)
    trim(arg)

    if(strlen(arg) < 3)
    {
        client_printcolor(id, "!g[FreeNova] !nUnban cancelled: value too short.")
        return PLUGIN_HANDLED
    }

    for(new i = 0; arg[i]; i++)
    {
        new c = arg[i]
        if(!(('A' <= c <= 'Z') || ('a' <= c <= 'z') || ('0' <= c <= '9') ||
             c == ':' || c == '_' || c == '.' || c == '-' || c == ' '))
        {
            arg[i] = ' '
        }
    }
    trim(arg)

    new targetType = UT_NICK
    if(equal(g_unbanTarget[id], "steamid") || contain(arg, "STEAM") != -1)
        targetType = UT_STEAMID
    else if(equal(g_unbanTarget[id], "ip") || (contain(arg, ".") != -1 && isdigit(arg[0])))
        targetType = UT_IP

    // Fail-closed: ban stack unloaded -> admin message, NO native call, NO
    // state change (g_unbanTarget kept so the admin can retry), failure
    // logged so web retries.
    if(!CBanUsable())
    {
        client_printcolor(id, "!g[FreeNova] !nBan system unavailable - no unban was applied. Try again later.")
        log_amx("[FreeNova] CBan unavailable; unban of %s FAILED (not applied)", arg)
        return PLUGIN_HANDLED
    }

    CBan_UnbanPlayer(id, arg, targetType)

    new adminName[32]
    get_user_name(id, adminName, charsmax(adminName))
    log_amx("[FreeNova] Admin %s unbanned %s target: %s", adminName, g_unbanTarget[id], arg)
    client_printcolor(id, "!g[FreeNova] !nUnban requested for %s.", arg)
    g_unbanTarget[id][0] = 0
    return PLUGIN_HANDLED
}

public Cmd_Unban(id)
{
    if(!is_user_connected(id)) return PLUGIN_HANDLED
    if(!(get_user_flags(id) & FLAG_ADMIN))
    {
        client_printcolor(id, "!g[FreeNova] !nAdmin only.")
        return PLUGIN_HANDLED
    }

    new arg[64]
    read_argv(1, arg, charsmax(arg))
    remove_quotes(arg)
    trim(arg)

    if(strlen(arg) < 3)
    {
        client_printcolor(id, "!g[FreeNova] !nUsage: /unban <steamid | ip | nick>")
        return PLUGIN_HANDLED
    }

    // Sanitize: only SteamID/IP/nick characters may pass into server_cmd.
    // Raw admin text with ; quotes or newlines would be command injection.
    for(new i = 0; arg[i]; i++)
    {
        new c = arg[i]
        if(!(('A' <= c <= 'Z') || ('a' <= c <= 'z') || ('0' <= c <= '9') ||
             c == ':' || c == '_' || c == '.' || c == '-' || c == ' '))
        {
            arg[i] = ' '
        }
    }
    trim(arg)

    // Determine unban type
    new targetType = UT_STEAMID
    if(contain(arg, "STEAM") != -1)
        targetType = UT_STEAMID
    else if(contain(arg, ".") != -1 && isdigit(arg[0]))
        targetType = UT_IP
    else
        targetType = UT_NICK

    new szTypeName[16]
    if(targetType == UT_STEAMID) copy(szTypeName, charsmax(szTypeName), "steamid")
    else if(targetType == UT_IP) copy(szTypeName, charsmax(szTypeName), "ip")
    else copy(szTypeName, charsmax(szTypeName), "nick")

    // Fail-closed: ban stack unloaded -> admin message, NO native call, NO
    // state change, failure logged so web retries.
    if(!CBanUsable())
    {
        client_printcolor(id, "!g[FreeNova] !nBan system unavailable - no unban was applied. Try again later.")
        log_amx("[FreeNova] CBan unavailable; unban of %s FAILED (not applied)", arg)
        return PLUGIN_HANDLED
    }

    CBan_UnbanPlayer(id, arg, targetType)

    new adminName[32]
    get_user_name(id, adminName, charsmax(adminName))
    log_amx("[FreeNova] Admin %s unbanned %s target: %s", adminName, szTypeName, arg)

    return PLUGIN_HANDLED
}

// ============================================================
// UNGAG COMMAND
// ============================================================
public Cmd_Ungag(id)
{
    if(!is_user_connected(id)) return PLUGIN_HANDLED
    if(!(get_user_flags(id) & FLAG_ADMIN))
    {
        client_printcolor(id, "!g[FreeNova] !nAdmin only.")
        return PLUGIN_HANDLED
    }
    ShowPlayerSelect(id, "ungag")
    return PLUGIN_HANDLED
}

ExecuteUngag(id, tid)
{
    // M13 entry guard: explain instead of acting blind. Self-ungag allowed.
    if(!is_user_connected(tid))
    {
        fn_chat_error(id, "This player is no longer connected. Please select another player.")
        return
    }
    if(tid != id && !CanModerate(id, tid))
    {
        fn_chat_permission(id, "This player is immune to your administrative actions.")
        return
    }
    new name[32]
    get_user_name(tid, name, charsmax(name))

    // Correct syntax: amx_ungag <nick or #userid or steamid or ip>
    server_cmd("amx_ungag #%d", get_user_userid(tid))

    new adminName[32]
    get_user_name(id, adminName, charsmax(adminName))
    log_amx("[FreeNova] Admin %s requested ungag for player %s", adminName, name)
    // M13: request-accepted; the ungag plugin reports the outcome.
    if(tid == id)
        fn_chat_info(id, "Your ungag request was sent.")
    else
        fn_chat_info(id, "Ungag request for %s sent.", name)
}

ExecuteFreeze(id, tid)
{
    new name[32]
    get_user_name(tid, name, charsmax(name))

    // Toggle freeze using FL_FROZEN flag
    if(g_bFrozen[tid])
    {
        set_pev(tid, pev_flags, pev(tid, pev_flags) & ~FL_FROZEN)
        set_user_maxspeed(tid, 250.0)
        g_bFrozen[tid] = false
        client_printcolor(id, "!g[FreeNova] !n%s unfrozen.", name)
    }
    else
    {
        set_pev(tid, pev_flags, pev(tid, pev_flags) | FL_FROZEN)
        set_user_maxspeed(tid, 1.0)
        g_bFrozen[tid] = true
        client_printcolor(id, "!g[FreeNova] !n%s frozen.", name)
    }
}

ExecuteGrab(id, tid)
{
    if(!(get_user_flags(id) & FLAG_ADMIN) || !CanModerate(id, tid))
        return

    new name[32]
    get_user_name(tid, name, charsmax(name))

    if(g_bIsGrabbing[id])
    {
        // Already grabbing someone - release
        StopGrab(id)
        client_printcolor(id, "!g[FreeNova] !nReleased %s.", name)
        return
    }

    // Start grab: noclip target and track them
    g_bIsGrabbing[id] = true
    g_iGrabTarget[id] = tid

    set_user_noclip(tid, 1)

    // Move target in front of admin
    new Float:origin[3], Float:angles[3], Float:fwd[3]
    pev(id, pev_origin, origin)
    pev(id, pev_v_angle, angles)
    angle_vector(angles, ANGLEVECTOR_FORWARD, fwd)
    origin[0] += fwd[0] * 200.0
    origin[1] += fwd[1] * 200.0
    origin[2] += fwd[2] * 200.0 + 50.0
    set_pev(tid, pev_origin, origin)

    // Start following task
    set_task(0.1, "Task_GrabFollow", id + TASK_EVENT, "", 0, "b")

    client_printcolor(id, "!g[FreeNova] !nGrabbed %s. Press grab again to release.", name)
}

StopGrab(id)
{
    if(g_iGrabTarget[id] > 0 && is_user_connected(g_iGrabTarget[id]))
    {
        set_user_noclip(g_iGrabTarget[id], 0)
    }
    g_bIsGrabbing[id] = false
    g_iGrabTarget[id] = 0
    remove_task(id + TASK_EVENT)
}

public Task_GrabFollow(taskid)
{
    new id = taskid - TASK_EVENT

    if(!is_user_connected(id) || !g_bIsGrabbing[id])
    {
        StopGrab(id)
        return
    }

    new tid = g_iGrabTarget[id]
    if(!is_user_connected(tid))
    {
        StopGrab(id)
        return
    }

    // Keep target in front of admin's view
    new Float:origin[3], Float:angles[3], Float:fwd[3]
    pev(id, pev_origin, origin)
    pev(id, pev_v_angle, angles)
    angle_vector(angles, ANGLEVECTOR_FORWARD, fwd)

    new Float:targetOrigin[3]
    targetOrigin[0] = origin[0] + fwd[0] * 200.0
    targetOrigin[1] = origin[1] + fwd[1] * 200.0
    targetOrigin[2] = origin[2] + fwd[2] * 200.0 + 50.0

    set_pev(tid, pev_origin, targetOrigin)
    set_pev(tid, pev_velocity, {0.0, 0.0, 0.0})
}

// ============================================================
// COINS MANAGEMENT
// ============================================================
ShowCoinPlayerSelect(id)
{
    new szTitle[64]
    FN_MenuTitle(szTitle, charsmax(szTitle), "Coins")
    new menu = menu_create(szTitle, "CoinPlayerHandler")

    new players[32], num, tempId, name[32]
    get_players(players, num, "ch")

    for(new i = 0; i < num; i++)
    {
        tempId = players[i]
        if(!CanModerate(id, tempId))
            continue
        get_user_name(tempId, name, charsmax(name))
        new coins = menabp_get_coins(tempId)
        menu_additem(menu, fmt("\w%s \y- \r%d coins", name, coins), fmt("%d", tempId))
    }

    if(menu_items(menu) == 0)
        menu_additem(menu, "\dNo other players online", "x")

    FN_MenuFinish(menu, true)
    menu_display(id, menu, 0)
}

public CoinPlayerHandler(id, menu, item)
{
    if(item == MENU_EXIT)
    {
        menu_destroy(menu)
        ShowServerPanel(id)
        return PLUGIN_HANDLED
    }
    if(item < 0)
        return PLUGIN_CONTINUE

    new data[16], name[64], access, callback
    menu_item_getinfo(menu, item, access, data, charsmax(data), name, charsmax(name), callback)
    menu_destroy(menu)

    new tid = str_to_num(data)

    if(!is_user_connected(tid))
    {
        client_printcolor(id, "!g[FreeNova] !nPlayer is no longer connected.")
        return PLUGIN_HANDLED
    }
    if(!(get_user_flags(id) & FLAG_MANAGER) || !CanModerate(id, tid))
    {
        client_printcolor(id, "!g[FreeNova] !nManager access required.")
        return PLUGIN_HANDLED
    }

    g_iCoinTarget[id] = tid
    g_iBanTarget[id] = tid
    g_iBanUserid[id] = get_user_userid(tid)
    get_user_authid(tid, g_szBanAuth[id], charsmax(g_szBanAuth[]))
    ShowCoinActionSelect(id)

    return PLUGIN_HANDLED
}

ShowCoinActionSelect(id)
{
    if( !PanelBanTargetValid(id) )
    {
        client_printcolor(id, "!g[FreeNova] !nPlayer is no longer connected or slot was reused.")
        return
    }

    new szTitle[64]
    FN_MenuTitle(szTitle, charsmax(szTitle), "Coin action")
    new menu = menu_create(szTitle, "CoinActionHandler")

    new tid = g_iBanTarget[id]
    g_iCoinTarget[id] = tid
    new targetName[32]
    get_user_name(tid, targetName, charsmax(targetName))

    menu_additem(menu, fmt("\wGive coins to \y%s", targetName), "give")
    menu_additem(menu, fmt("\wRemove coins from \y%s", targetName), "remove")

    FN_MenuFinish(menu, true)
    menu_display(id, menu, 0)
}

public CoinActionHandler(id, menu, item)
{
    if(item == MENU_EXIT)
    {
        menu_destroy(menu)
        ShowCoinPlayerSelect(id)
        return PLUGIN_HANDLED
    }

    new data[8], name[64], access, callback
    menu_item_getinfo(menu, item, access, data, charsmax(data), name, charsmax(name), callback)
    menu_destroy(menu)

    if( !PanelBanTargetValid(id) )
    {
        client_printcolor(id, "!g[FreeNova] !nPlayer is no longer connected or slot was reused.")
        return PLUGIN_HANDLED
    }

    if(equal(data, "give"))
        ShowCoinAmount(id, true) // positive = give
    else
        ShowCoinAmount(id, false) // false = remove

    return PLUGIN_HANDLED
}

ShowCoinAmount(id, bool:isGive)
{
    if( !PanelBanTargetValid(id) )
    {
        client_printcolor(id, "!g[FreeNova] !nPlayer is no longer connected or slot was reused.")
        return
    }

    new szTitle[64]
    FN_MenuTitle(szTitle, charsmax(szTitle), "Coin amount")
    new menu = menu_create(szTitle, "CoinAmountHandler")

    new tid = g_iBanTarget[id]
    g_iCoinTarget[id] = tid
    new targetName[32]
    get_user_name(tid, targetName, charsmax(targetName))

    menu_additem(menu, fmt("\w%s \y100 coins \wto \r%s", isGive ? "Give" : "Remove", targetName), isGive ? "100" : "-100")
    menu_additem(menu, fmt("\w%s \y500 coins \wto \r%s", isGive ? "Give" : "Remove", targetName), isGive ? "500" : "-500")
    menu_additem(menu, fmt("\w%s \y1000 coins \wto \r%s", isGive ? "Give" : "Remove", targetName), isGive ? "1000" : "-1000")
    menu_additem(menu, fmt("\w%s \y2500 coins \wto \r%s", isGive ? "Give" : "Remove", targetName), isGive ? "2500" : "-2500")
    menu_additem(menu, fmt("\w%s \y5000 coins \wto \r%s", isGive ? "Give" : "Remove", targetName), isGive ? "5000" : "-5000")
    menu_additem(menu, fmt("\w%s \y10000 coins \wto \r%s", isGive ? "Give" : "Remove", targetName), isGive ? "10000" : "-10000")
    FN_MenuFinish(menu, true)
    menu_display(id, menu, 0)
}

// Parked coin deposits (bounced while the target's BP wallet was loading).
// Key lives in the stats vault; flushed on join and before every new deposit.
PanelCoinKey(tid, szOut[], iLen)
{
    new szAuth[40]
    get_user_authid(tid, szAuth, charsmax(szAuth))
    for (new i = 0; szAuth[i]; i++)
    {
        if (szAuth[i] == ':')
            szAuth[i] = '_'
    }
    formatex(szOut, iLen, "panelcoinpend#%s", szAuth)
}

PanelParkCoins(tid, amount)
{
    if (g_VaultStats == INVALID_HANDLE || !is_user_connected(tid))
        return
    new szKey[64], szOld[16]
    PanelCoinKey(tid, szKey, charsmax(szKey))
    new iOld = 0
    if (nvault_get(g_VaultStats, szKey, szOld, charsmax(szOld)))
        iOld = str_to_num(szOld)
    // Keep the accumulated park inside a safe 32-bit range. The wallet itself
    // is capped at 2B, so a wrapped total could otherwise turn a credit into a
    // debit when it is flushed.
    new iNew
    if (amount > 0 && iOld > 2000000000 - amount)
        iNew = 2000000000
    else if (amount < 0 && iOld < -2000000000 - amount)
        iNew = -2000000000
    else
        iNew = iOld + amount
    new szVal[16]
    formatex(szVal, charsmax(szVal), "%d", iNew)
    nvault_set(g_VaultStats, szKey, szVal)
}

stock bool:FlushPanelCoinPending(tid)
{
    if (g_VaultStats == INVALID_HANDLE || !is_user_connected(tid))
        return false
    new szKey[64], szVal[16]
    PanelCoinKey(tid, szKey, charsmax(szKey))
    if (!nvault_get(g_VaultStats, szKey, szVal, charsmax(szVal)))
        return false
    new iAmt = str_to_num(szVal)
    if (iAmt == 0)
    {
        nvault_remove(g_VaultStats, szKey)
        return false
    }
    if (!LibraryExists("menabp", LibType_Library) || !menabp_is_ready(tid))
        return false
    new beforeCoins = menabp_get_coins(tid)
    new newCoins = menabp_add_coins(tid, iAmt)
    if (newCoins == 0 && beforeCoins + iAmt != 0)
        return false
    nvault_remove(g_VaultStats, szKey)
    log_amx("[FreeNova] Flushed %d parked panel coins", iAmt)
    return true
}

stock bool:PanelHasParkedCoins(tid)
{
    if (g_VaultStats == INVALID_HANDLE || !is_user_connected(tid))
        return false
    new szKey[64], szVal[16]
    PanelCoinKey(tid, szKey, charsmax(szKey))
    if (!nvault_get(g_VaultStats, szKey, szVal, charsmax(szVal)))
        return false
    return (str_to_num(szVal) != 0) ? true : false
}

// Retry a parked credit while the wallet finishes loading (12 x 5s). The
// deposit stays in the vault if this expires, so it is never lost.
stock SchedulePanelCoinRetry(tid)
{
    if (tid < 1 || tid > MAX_PLAYERS)
        return
    remove_task(tid + TASK_COINRETRY)
    g_iCoinRetryTries[tid] = 0
    set_task(5.0, "Task_RetryAddCoinFlush", tid + TASK_COINRETRY, "", 0, "b")
}

public Task_RetryAddCoinFlush(taskid)
{
    new id = taskid - TASK_COINRETRY
    if (id < 1 || id > MAX_PLAYERS || !is_user_connected(id))
    {
        remove_task(taskid)
        return
    }
    if (!PanelHasParkedCoins(id))
    {
        remove_task(taskid)
        return
    }

    if (LibraryExists("menabp", LibType_Library) && menabp_is_ready(id))
    {
        if (FlushPanelCoinPending(id))
            client_printcolor(id, "!g[FreeNova] !nYour pending coin adjustment has been applied.")
        if (!PanelHasParkedCoins(id))
        {
            remove_task(taskid)
            return
        }
    }

    g_iCoinRetryTries[id]++
    if (g_iCoinRetryTries[id] >= 12)
    {
        remove_task(taskid)
        log_amx("[FreeNova] Parked coins for player %d still pending after retries; will retry on next join/deposit", id)
    }
}

public CoinAmountHandler(id, menu, item)
{
    if(item == MENU_EXIT)
    {
        menu_destroy(menu)
        ShowCoinActionSelect(id)
        return PLUGIN_HANDLED
    }
    if(item < 0)
        return PLUGIN_CONTINUE

    new data[16], name[64], access, callback
    menu_item_getinfo(menu, item, access, data, charsmax(data), name, charsmax(name), callback)
    menu_destroy(menu)

    if( !PanelBanTargetValid(id) )
    {
        client_printcolor(id, "!g[FreeNova] !nPlayer is no longer connected or slot was reused.")
        return PLUGIN_HANDLED
    }

    new tid = g_iBanTarget[id]
    if(!(get_user_flags(id) & FLAG_MANAGER) || !CanModerate(id, tid))
    {
        client_printcolor(id, "!g[FreeNova] !nManager access required.")
        return PLUGIN_HANDLED
    }
    g_iCoinTarget[id] = tid

    // Fail-closed: without the battlepass provider no balance exists to
    // change. Never fall through to menabp_add_coins (runtime error).
    if(!LibraryExists("menabp", LibType_Library))
    {
        fn_chat_error(id, "Coin service is not available right now - no coins were changed.")
        return PLUGIN_HANDLED
    }

    new amount = str_to_num(data)

    new targetName[32], adminName[32]
    get_user_name(tid, targetName, charsmax(targetName))
    get_user_name(id, adminName, charsmax(adminName))

    // Flush any coins parked for this target first (previous deposit that
    // bounced while their BP wallet was still loading).
    FlushPanelCoinPending(tid)

    // Readiness gate: an unloaded wallet makes add_coins return 0 and the
    // deposit would vanish silently. Park it instead (see achievements).
    if (!menabp_is_ready(tid))
    {
        PanelParkCoins(tid, amount)
        if (g_VaultStats != INVALID_HANDLE)
            SchedulePanelCoinRetry(tid)
        client_printcolor(id, "!g[FreeNova] !nWallet not ready - %d coins parked for %s, will retry automatically.", amount, targetName)
        client_printcolor(tid, "!g[FreeNova] !nAdmin %s tried to give you coins, but your wallet is loading. They are parked.", adminName)
        log_amx("[FreeNova] Coin deposit of %+d for %s parked (wallet not ready)", amount, targetName)
        return PLUGIN_HANDLED
    }
    new beforeCoins = menabp_get_coins(tid)
    new newCoins = menabp_add_coins(tid, amount)
    if (newCoins == 0 && beforeCoins + amount != 0)
    {
        // Deposit did not land (unloaded mid-call or refused): park + retry.
        PanelParkCoins(tid, amount)
        if (g_VaultStats != INVALID_HANDLE)
            SchedulePanelCoinRetry(tid)
        client_printcolor(id, "!g[FreeNova] !nDeposit failed - %d coins parked for %s, will retry automatically.", amount, targetName)
        log_amx("[FreeNova] Coin deposit of %+d for %s failed verification, parked", amount, targetName)
        return PLUGIN_HANDLED
    }

    if(amount > 0)
    {
        client_printcolor(id, "!g[FreeNova] !nGave %d coins to %s (balance: %d)", amount, targetName, newCoins)
        client_printcolor(tid, "!g[FreeNova] !nAdmin %s gave you %d coins! Balance: %d", adminName, amount, newCoins)
    }
    else
    {
        new absAmount = -amount
        client_printcolor(id, "!g[FreeNova] !nRemoved %d coins from %s (balance: %d)", absAmount, targetName, newCoins)
        client_printcolor(tid, "!g[FreeNova] !nAdmin %s removed %d coins! Balance: %d", adminName, absAmount, newCoins)
    }

    log_amx("[FreeNova] Admin %s modified coins for %s: %+d (balance: %d)", adminName, targetName, amount, newCoins)

    return PLUGIN_HANDLED
}

// ============================================================
// ADD COINS (dedicated confirmed grant flow)
// ============================================================
// This is an additive credit path on top of the existing BattlePass wallet
// (menabp_*). It deliberately does not use CanModerate(): a manager may
// credit any connected human, including themselves and other managers.
// Entering the flow still requires the existing manager flag (a), so no new
// permission node is introduced. Bots are excluded because battlepass_core
// never loads or saves a wallet for them (see its client_putinserver guard).

#define MAX_ADD_COINS_PER_GRANT 1000000000

stock bool:PanelAddCoinsAccess(id)
{
    if (!is_user_connected(id))
        return false
    return (get_user_flags(id) & FLAG_MANAGER) ? true : false
}

stock bool:PanelAddCoinTargetValid(id)
{
    if (id < 1 || id > MAX_PLAYERS)
        return false

    new tid = g_iAddCoinTarget[id]
    if (tid < 1 || tid > MAX_PLAYERS || !is_user_connected(tid))
        return false
    if (get_user_userid(tid) != g_iAddCoinUserid[id])
        return false

    // Slot reuse / auth change guard (same snapshot idiom as ban targets).
    new szAuth[35]
    get_user_authid(tid, szAuth, charsmax(szAuth))
    if (g_szAddCoinAuth[id][0] && !equal(szAuth, g_szAddCoinAuth[id]))
        return false

    return true
}

stock bool:PanelAddCoinAuthReady(targetId)
{
    // A pending/unknown authid would park the grant under a key that is never
    // read again once Steam resolves the real authid (silent coin loss).
    new szAuth[35]
    get_user_authid(targetId, szAuth, charsmax(szAuth))
    if (!szAuth[0] || equal(szAuth, "STEAM_ID_PENDING") || equal(szAuth, "UNKNOWN") || equal(szAuth, "BOT"))
        return false
    return true
}

stock bool:PanelAddCoinEligible(targetId)
{
    if (!is_user_connected(targetId))
        return false
    // Bots have no BattlePass wallet; never offer them as a credit target.
    if (is_user_bot(targetId) || is_user_hltv(targetId))
        return false
    if (!PanelAddCoinAuthReady(targetId))
        return false
    return true
}

stock bool:PanelAddCoinAmountValid(amount)
{
    return (amount >= 1 && amount <= MAX_ADD_COINS_PER_GRANT) ? true : false
}

// Strict decimal parse with a pre-multiply cap check, so a long or wrapped
// value can never sneak into the valid range through 32-bit overflow.
stock bool:PanelParseAddCoinAmount(const szInput[], &amount)
{
    amount = 0
    if (!szInput[0])
        return false

    for (new i = 0; szInput[i]; i++)
    {
        if (szInput[i] < '0' || szInput[i] > '9')
            return false
        if (amount > MAX_ADD_COINS_PER_GRANT / 10)
            return false

        amount = amount * 10 + (szInput[i] - '0')
        if (amount > MAX_ADD_COINS_PER_GRANT)
            return false
    }

    return (amount >= 1) ? true : false
}

// Abandon the flow: clear target + pending and invalidate any stale confirm.
stock PanelResetAddCoin(id)
{
    g_iAddCoinTarget[id] = 0
    g_iAddCoinUserid[id] = 0
    g_szAddCoinAuth[id][0] = 0
    g_iAddCoinPending[id] = 0
    g_iAddCoinToken[id]++
    if (g_iAddCoinToken[id] < 1)
        g_iAddCoinToken[id] = 1
}

ShowAddCoinPlayerSelect(id)
{
    if (!PanelAddCoinsAccess(id))
    {
        client_printcolor(id, "!g[FreeNova] !nManager access required.")
        return
    }

    // Starting a fresh selection invalidates any older confirmation.
    g_iAddCoinTarget[id] = 0
    g_iAddCoinUserid[id] = 0
    g_szAddCoinAuth[id][0] = 0
    g_iAddCoinPending[id] = 0
    g_iAddCoinToken[id]++
    if (g_iAddCoinToken[id] < 1)
        g_iAddCoinToken[id] = 1

    new szTitle[64]
    FN_MenuTitle(szTitle, charsmax(szTitle), "Add Coins")
    new menu = menu_create(szTitle, "AddCoinPlayerHandler")

    new bool:bWallet = bool:LibraryExists("menabp", LibType_Library)
    new players[32], num, tempId, name[32], szItem[96]
    get_players(players, num, "ch")

    for (new i = 0; i < num; i++)
    {
        tempId = players[i]
        if (!PanelAddCoinEligible(tempId))
            continue

        get_user_name(tempId, name, charsmax(name))
        new coins = bWallet ? menabp_get_coins(tempId) : 0

        if (tempId == id)
            formatex(szItem, charsmax(szItem), "\w%s \d(you) \y- \r%d coins", name, coins)
        else
            formatex(szItem, charsmax(szItem), "\w%s \y- \r%d coins", name, coins)

        menu_additem(menu, szItem, fmt("%d", tempId))
    }

    if (menu_items(menu) == 0)
        menu_additem(menu, "\dNo eligible players online", "x")

    // Make the bot limitation visible instead of silently hiding bots.
    new bots[32], iBots
    get_players(bots, iBots, "dh")
    if (iBots > 0)
        menu_additem(menu, "\dBots are not listed \d(no coin wallet)", "x")

    FN_MenuFinish(menu, true)
    menu_display(id, menu, 0)
}

public AddCoinPlayerHandler(id, menu, item)
{
    if (item == MENU_EXIT)
    {
        menu_destroy(menu)
        ShowEconomyPanel(id)
        return PLUGIN_HANDLED
    }
    if (item < 0)
        return PLUGIN_CONTINUE

    new data[16], name[64], access, callback
    menu_item_getinfo(menu, item, access, data, charsmax(data), name, charsmax(name), callback)
    menu_destroy(menu)

    if (!PanelAddCoinsAccess(id))
    {
        client_printcolor(id, "!g[FreeNova] !nManager access required.")
        return PLUGIN_HANDLED
    }

    new tid = str_to_num(data)
    if (tid < 1)
    {
        ShowAddCoinPlayerSelect(id)
        return PLUGIN_HANDLED
    }
    if (!PanelAddCoinEligible(tid))
    {
        if (is_user_bot(tid))
            client_printcolor(id, "!g[FreeNova] !nBots have no BattlePass wallet, so coins cannot be added to them.")
        else
            client_printcolor(id, "!g[FreeNova] !nThat player is not eligible for a coin grant.")
        ShowAddCoinPlayerSelect(id)
        return PLUGIN_HANDLED
    }

    g_iAddCoinTarget[id] = tid
    g_iAddCoinUserid[id] = get_user_userid(tid)
    get_user_authid(tid, g_szAddCoinAuth[id], charsmax(g_szAddCoinAuth[]))
    g_iAddCoinPending[id] = 0

    ShowAddCoinAmount(id)
    return PLUGIN_HANDLED
}

ShowAddCoinAmount(id)
{
    if (!PanelAddCoinsAccess(id))
    {
        client_printcolor(id, "!g[FreeNova] !nManager access required.")
        return
    }
    if (!PanelAddCoinTargetValid(id))
    {
        client_printcolor(id, "!g[FreeNova] !nPlayer is no longer connected or slot was reused.")
        PanelResetAddCoin(id)
        ShowAddCoinPlayerSelect(id)
        return
    }

    new tid = g_iAddCoinTarget[id]
    new targetName[32], szTitle[64]
    get_user_name(tid, targetName, charsmax(targetName))
    FN_MenuTitle(szTitle, charsmax(szTitle), fmt("Add Coins: %s", targetName))

    new menu = menu_create(szTitle, "AddCoinAmountHandler")
    menu_additem(menu, "\wAdd \y100 \wcoins", "100")
    menu_additem(menu, "\wAdd \y500 \wcoins", "500")
    menu_additem(menu, "\wAdd \y1000 \wcoins", "1000")
    menu_additem(menu, "\wAdd \y2500 \wcoins", "2500")
    menu_additem(menu, "\wAdd \y5000 \wcoins", "5000")
    menu_additem(menu, "\wAdd \y10000 \wcoins", "10000")
    menu_additem(menu, "\yCustom amount \d(type a number)", "custom")

    FN_MenuFinish(menu, true)
    menu_display(id, menu, 0)
}

public AddCoinAmountHandler(id, menu, item)
{
    if (item == MENU_EXIT)
    {
        menu_destroy(menu)
        ShowAddCoinPlayerSelect(id)
        return PLUGIN_HANDLED
    }
    if (item < 0)
        return PLUGIN_CONTINUE

    new data[16], name[64], access, callback
    menu_item_getinfo(menu, item, access, data, charsmax(data), name, charsmax(name), callback)
    menu_destroy(menu)

    if (!PanelAddCoinsAccess(id))
    {
        client_printcolor(id, "!g[FreeNova] !nManager access required.")
        return PLUGIN_HANDLED
    }
    if (!PanelAddCoinTargetValid(id))
    {
        client_printcolor(id, "!g[FreeNova] !nPlayer is no longer connected or slot was reused.")
        PanelResetAddCoin(id)
        ShowAddCoinPlayerSelect(id)
        return PLUGIN_HANDLED
    }

    if (equal(data, "custom"))
    {
        g_iAddCoinPending[id] = 0
        client_printcolor(id, "!g[FreeNova] !nType the number of coins to add (1 - %d).", MAX_ADD_COINS_PER_GRANT)
        client_cmd(id, "messagemode freenova_addcoins_amount")
        return PLUGIN_HANDLED
    }

    new amount = str_to_num(data)
    if (!PanelAddCoinAmountValid(amount))
    {
        client_printcolor(id, "!g[FreeNova] !nInvalid amount. Use 1 - %d coins.", MAX_ADD_COINS_PER_GRANT)
        ShowAddCoinAmount(id)
        return PLUGIN_HANDLED
    }

    ShowAddCoinConfirm(id, amount)
    return PLUGIN_HANDLED
}

public Cmd_AddCoinsAmount(id)
{
    if (!PanelAddCoinsAccess(id))
        return PLUGIN_HANDLED
    if (!PanelAddCoinTargetValid(id))
    {
        client_printcolor(id, "!g[FreeNova] !nPlayer is no longer connected or slot was reused.")
        PanelResetAddCoin(id)
        ShowAddCoinPlayerSelect(id)
        return PLUGIN_HANDLED
    }

    new arg[16]
    read_args(arg, charsmax(arg))
    remove_quotes(arg)
    trim(arg)

    if (!arg[0])
    {
        ShowAddCoinAmount(id)
        return PLUGIN_HANDLED
    }

    new amount
    if (!PanelParseAddCoinAmount(arg, amount))
    {
        client_printcolor(id, "!g[FreeNova] !nAmount must be a whole number between 1 and %d.", MAX_ADD_COINS_PER_GRANT)
        ShowAddCoinAmount(id)
        return PLUGIN_HANDLED
    }

    ShowAddCoinConfirm(id, amount)
    return PLUGIN_HANDLED
}

ShowAddCoinConfirm(id, amount)
{
    if (!PanelAddCoinsAccess(id))
    {
        client_printcolor(id, "!g[FreeNova] !nManager access required.")
        return
    }
    if (!PanelAddCoinTargetValid(id) || !PanelAddCoinAmountValid(amount))
    {
        client_printcolor(id, "!g[FreeNova] !nThat coin request is no longer valid.")
        PanelResetAddCoin(id)
        ShowAddCoinPlayerSelect(id)
        return
    }

    // Arm a single-use confirmation. The token makes a stale/double callback
    // harmless even if the old menu is still buffered on the client.
    g_iAddCoinToken[id]++
    if (g_iAddCoinToken[id] < 1)
        g_iAddCoinToken[id] = 1
    g_iAddCoinPending[id] = amount

    new tid = g_iAddCoinTarget[id]
    new targetName[32], szTitle[64]
    get_user_name(tid, targetName, charsmax(targetName))
    new iBalance = LibraryExists("menabp", LibType_Library) ? menabp_get_coins(tid) : 0
    FN_MenuTitle(szTitle, charsmax(szTitle), fmt("Confirm: %d coins", amount))

    new menu = menu_create(szTitle, "AddCoinConfirmHandler")
    menu_additem(menu, fmt("\yYes, add %d \wto \r%s \d(balance %d)", amount, targetName, iBalance), fmt("y%d", g_iAddCoinToken[id]))
    menu_additem(menu, "\dNo, cancel", fmt("n%d", g_iAddCoinToken[id]))

    FN_MenuFinish(menu, true)
    menu_display(id, menu, 0)
}

public AddCoinConfirmHandler(id, menu, item)
{
    if (item == MENU_EXIT)
    {
        menu_destroy(menu)
        g_iAddCoinPending[id] = 0
        ShowAddCoinAmount(id)
        return PLUGIN_HANDLED
    }
    if (item < 0)
        return PLUGIN_CONTINUE

    new data[16], name[64], access, callback
    menu_item_getinfo(menu, item, access, data, charsmax(data), name, charsmax(name), callback)
    menu_destroy(menu)

    new iToken = str_to_num(data[1])
    if (iToken != g_iAddCoinToken[id])
    {
        client_printcolor(id, "!g[FreeNova] !nThat confirmation has expired. Please choose the amount again.")
        return PLUGIN_HANDLED
    }

    new bool:bConfirm = (data[0] == 'y')
    new amount = g_iAddCoinPending[id]
    // Consume before executing so a duplicate callback cannot grant twice.
    g_iAddCoinPending[id] = 0

    if (!bConfirm)
    {
        ShowAddCoinAmount(id)
        return PLUGIN_HANDLED
    }
    if (!PanelAddCoinAmountValid(amount))
    {
        client_printcolor(id, "!g[FreeNova] !nThis confirmation was already used.")
        ShowAddCoinPlayerSelect(id)
        return PLUGIN_HANDLED
    }

    ApplyAddCoins(id, amount)
    return PLUGIN_HANDLED
}

ApplyAddCoins(id, amount)
{
    if (!PanelAddCoinsAccess(id))
    {
        client_printcolor(id, "!g[FreeNova] !nManager access required.")
        return
    }
    if (!PanelAddCoinAmountValid(amount))
    {
        client_printcolor(id, "!g[FreeNova] !nInvalid coin amount - nothing was changed.")
        return
    }
    if (!PanelAddCoinTargetValid(id))
    {
        client_printcolor(id, "!g[FreeNova] !nPlayer is no longer connected or slot was reused.")
        PanelResetAddCoin(id)
        ShowAddCoinPlayerSelect(id)
        return
    }

    new tid = g_iAddCoinTarget[id]
    if (!PanelAddCoinEligible(tid))
    {
        client_printcolor(id, "!g[FreeNova] !nThat player is not eligible for a coin grant.")
        PanelResetAddCoin(id)
        ShowAddCoinPlayerSelect(id)
        return
    }

    // Fail closed without the wallet provider: there is no balance to change.
    if (!LibraryExists("menabp", LibType_Library))
    {
        fn_chat_error(id, "Coin service is not available right now - no coins were added.")
        return
    }

    new targetName[32], adminName[32]
    new adminAuth[35], targetAuth[35]
    get_user_name(tid, targetName, charsmax(targetName))
    get_user_name(id, adminName, charsmax(adminName))
    get_user_authid(id, adminAuth, charsmax(adminAuth))
    get_user_authid(tid, targetAuth, charsmax(targetAuth))

    new szLog[256]

    // Apply anything previously parked for this wallet first.
    FlushPanelCoinPending(tid)

    // Unloaded wallet: menabp_add_coins would return 0 and the credit would
    // vanish, so park it in the existing panel vault and retry on load.
    if (!menabp_is_ready(tid))
    {
        if (g_VaultStats == INVALID_HANDLE)
        {
            fn_chat_error(id, "Coin wallet is not ready and park storage is unavailable - nothing was added.")
            formatex(szLog, charsmax(szLog), "[FreeNova] ADDCOINS FAILED admin=%s(%s) target=%s(%s) amount=%d reason=wallet_not_ready_no_park", adminName, adminAuth, targetName, targetAuth, amount)
            log_amx("%s", szLog)
            return
        }

        PanelParkCoins(tid, amount)
        SchedulePanelCoinRetry(tid)
        client_printcolor(id, "!g[FreeNova] !nWallet not ready - %d coins parked for %s; they will be applied automatically.", amount, targetName)
        if (tid != id)
            client_printcolor(tid, "!g[FreeNova] !nAdmin %s tried to add %d coins, but your wallet is loading. They are parked.", adminName, amount)

        formatex(szLog, charsmax(szLog), "[FreeNova] ADDCOINS PARKED admin=%s(%s) target=%s(%s) amount=%d self=%d", adminName, adminAuth, targetName, targetAuth, amount, tid == id ? 1 : 0)
        log_amx("%s", szLog)
        return
    }

    new beforeCoins = menabp_get_coins(tid)
    new newCoins = menabp_add_coins(tid, amount)

    // Positive credits can never legitimately end at <= 0.
    if (newCoins <= 0)
    {
        if (g_VaultStats != INVALID_HANDLE)
        {
            PanelParkCoins(tid, amount)
            SchedulePanelCoinRetry(tid)
            client_printcolor(id, "!g[FreeNova] !nDeposit failed - %d coins parked for %s; they will be retried automatically.", amount, targetName)
            formatex(szLog, charsmax(szLog), "[FreeNova] ADDCOINS PARKED admin=%s(%s) target=%s(%s) amount=%d reason=add_rejected", adminName, adminAuth, targetName, targetAuth, amount)
        }
        else
        {
            fn_chat_error(id, "Coin deposit failed and park storage is unavailable - nothing was added.")
            formatex(szLog, charsmax(szLog), "[FreeNova] ADDCOINS FAILED admin=%s(%s) target=%s(%s) amount=%d reason=add_rejected_no_park", adminName, adminAuth, targetName, targetAuth, amount)
        }
        log_amx("%s", szLog)
        return
    }

    if (tid == id)
        client_printcolor(id, "!g[FreeNova] !nAdded %d coins to your balance. New balance: %d", amount, newCoins)
    else
    {
        client_printcolor(id, "!g[FreeNova] !nAdded %d coins to %s (balance: %d)", amount, targetName, newCoins)
        client_printcolor(tid, "!g[FreeNova] !nAdmin %s added %d coins! New balance: %d", adminName, amount, newCoins)
    }

    // The BattlePass wallet clamps positive credits at 2,000,000,000.
    if (beforeCoins > 2000000000 - amount)
        client_printcolor(id, "!g[FreeNova] !nWallet cap reached - the balance was clamped to %d.", newCoins)

    formatex(szLog, charsmax(szLog), "[FreeNova] ADDCOINS OK admin=%s(%s) target=%s(%s) amount=%d before=%d after=%d self=%d", adminName, adminAuth, targetName, targetAuth, amount, beforeCoins, newCoins, tid == id ? 1 : 0)
    log_amx("%s", szLog)
}

// ============================================================
// EVENTS PANEL
// ============================================================
public Cmd_EventCatalog(id)
{
    if (!is_user_connected(id))
        return PLUGIN_HANDLED
    ShowEventCatalog(id)
    return PLUGIN_HANDLED
}

// Player-facing catalog of the eight real server event modes. The admin
// toggle lives in /panel; this menu is read-only and explains each event.
ShowEventCatalog(id)
{
    new szTitle[64]
    FN_MenuTitle(szTitle, charsmax(szTitle), "Events")
    new menu = menu_create(szTitle, "EventCatalogHandler")

    static const szNames[][] = {
        "Knife Round", "Headshot Only", "Temp VIP", "VIP Fest",
        "Speed Rush", "Golden Deagle", "Double XP", "Low Gravity"
    }
    new szItem[128], szData[8]
    for (new event = EVENT_KNIFE_ROUND; event <= EVENT_LOW_GRAVITY; event++)
    {
        formatex(szItem, charsmax(szItem), "%s \w%s",
            g_bEventActive[event] ? "\y[ON] " : "\d[OFF] ",
            szNames[event - 1])
        formatex(szData, charsmax(szData), "%d", event)
        menu_additem(menu, szItem, szData)
    }

    FN_MenuFinish(menu, false)
    menu_setprop(menu, MPROP_PERPAGE, 0)
    menu_display(id, menu, 0)
}

public EventCatalogHandler(id, menu, item)
{
    if (item == MENU_EXIT || !is_user_connected(id))
    {
        menu_destroy(menu)
        return PLUGIN_HANDLED
    }

    new szData[8], iAccess, iCallback
    menu_item_getinfo(menu, item, iAccess, szData, charsmax(szData), _, _, iCallback)
    menu_destroy(menu)

    new event = str_to_num(szData)
    if (event >= EVENT_KNIFE_ROUND && event <= EVENT_LOW_GRAVITY)
        ShowEventDetail(id, event)
    return PLUGIN_HANDLED
}

ShowEventDetail(id, event)
{
    static const szNames[][] = {
        "Knife Round", "Headshot Only", "Temp VIP", "VIP Fest",
        "Speed Rush", "Golden Deagle", "Double XP", "Low Gravity"
    }
    static const szDesc[][] = {
        "Knife-only round. Guns are stripped and buys are blocked.",
        "Only headshots deal damage.",
        "Temporary VIP access for everyone in the server.",
        "Temporary VIP+ window during the event.",
        "Movement speed is raised to 500.",
        "Golden Deagle only. Other weapons are blocked.",
        "Double XP is applied to eligible progression events.",
        "Gravity is reduced for the event window."
    }

    new szTitle[80], szItem[128]
    formatex(szTitle, charsmax(szTitle), "Event: %s", szNames[event - 1])
    new menu = menu_create(szTitle, "EventDetailHandler")

    menu_additem(menu, g_bEventActive[event] ? "\yStatus: ACTIVE" : "\dStatus: INACTIVE", "0")
    formatex(szItem, charsmax(szItem), "\w%s", szDesc[event - 1])
    menu_additem(menu, szItem, "0")
    menu_additem(menu, "\wBack to event catalog", "1")
    FN_MenuFinish(menu, false)
    menu_setprop(menu, MPROP_PERPAGE, 0)
    menu_display(id, menu, 0)
}

public EventDetailHandler(id, menu, item)
{
    menu_destroy(menu)
    if (is_user_connected(id))
        ShowEventCatalog(id)
    return PLUGIN_HANDLED
}

ShowEventsPanel(id)
{
    new szTitle[64]
    FN_MenuTitle(szTitle, charsmax(szTitle), "Events")
    new menu = menu_create(szTitle, "EventsHandler")

    menu_additem(menu, g_bEventActive[EVENT_KNIFE_ROUND] ? "\w[ON] \yKnife Round" : "\wKnife Round", "1")
    menu_additem(menu, g_bEventActive[EVENT_HEADSHOT_ONLY] ? "\w[ON] \yHeadshot Only" : "\wHeadshot Only", "2")
    menu_additem(menu, g_bEventActive[EVENT_TEMP_VIP] ? "\w[ON] \yTemp VIP" : "\wTemp VIP", "3")
    menu_additem(menu, g_bEventActive[EVENT_VIP_FEST] ? "\w[ON] \yVIP Fest" : "\wVIP Fest", "4")
    menu_additem(menu, g_bEventActive[EVENT_SPEED_RUSH] ? "\w[ON] \ySpeed Rush" : "\wSpeed Rush", "5")
    menu_additem(menu, g_bEventActive[EVENT_GOLDEN_DEAGLE] ? "\w[ON] \yGolden Deagle" : "\wGolden Deagle", "6")
    menu_additem(menu, g_bEventActive[EVENT_DOUBLE_XP] ? "\w[ON] \yDouble XP" : "\wDouble XP", "7")
    menu_additem(menu, g_bEventActive[EVENT_LOW_GRAVITY] ? "\w[ON] \yLow Gravity" : "\wLow Gravity", "8")

    FN_MenuFinish(menu, true)
    menu_display(id, menu, 0)
}

public EventsHandler(id, menu, item)
{
    if(item == MENU_EXIT || item == MENU_BACK)
    {
        menu_destroy(menu)
        ShowServerPanel(id)
        return PLUGIN_HANDLED
    }
    if(item == MENU_MORE)
        return PLUGIN_CONTINUE

    if(!(get_user_flags(id) & FLAG_ADMIN))
    {
        client_printcolor(id, "!g[FreeNova] !nAdmin only.")
        menu_destroy(menu)
        return PLUGIN_HANDLED
    }

    new data[8], name[64], access, callback
    menu_item_getinfo(menu, item, access, data, charsmax(data), name, charsmax(name), callback)
    menu_destroy(menu)

    new event = str_to_num(data)
    if(event < EVENT_KNIFE_ROUND || event > EVENT_LOW_GRAVITY)
        return PLUGIN_HANDLED

    ToggleEvent(id, event)
    log_amx("[FreeNova] Admin %d toggled event %d -> %d", id, event, g_bEventActive[event])
    set_task(0.1, "Task_RefreshEvents", id)
    return PLUGIN_HANDLED
}

public Task_RefreshEvents(taskid)
{
    ShowEventsPanel(taskid)
}

ToggleEvent(id, event)
{
    new name[32]
    get_user_name(id, name, charsmax(name))

    g_bEventActive[event] = !g_bEventActive[event]

    switch(event)
    {
        case EVENT_KNIFE_ROUND:
        {
            if(g_bEventActive[event])
            {
                new players[32], num
                get_players(players, num, "ch")
                for(new i = 0; i < num; i++)
                {
                    if(is_user_alive(players[i]))
                        ArmKnifeRound(players[i])
                }

                RemoveGroundWeapons()

                // Keep deleting dropped guns while event runs
                remove_task(TASK_CLEANUP)
                set_task(0.5, "Task_RemoveGroundBoxes", TASK_CLEANUP, "", 0, "b")

                client_printcolor(0, "!g[FreeNova] !gKnife Round !nstarted by !t%s !g- Knife only!", name)
            }
            else
            {
                remove_task(TASK_CLEANUP)
                client_printcolor(0, "!g[FreeNova] !gKnife Round !nended by !t%s", name)
            }
        }
        case EVENT_HEADSHOT_ONLY:
        {
            if(g_bEventActive[event])
            {
                set_cvar_num("fn_headshot_only", 1)
                client_printcolor(0, "!g[FreeNova] !gHeadshot Only !nstarted by !t%s !g- Headshots only!", name)
            }
            else
            {
                set_cvar_num("fn_headshot_only", 0)
                client_printcolor(0, "!g[FreeNova] !gHeadshot Only !nended by !t%s", name)
            }
        }
        case EVENT_TEMP_VIP:
        {
            if(g_bEventActive[event])
            {
                new players[32], num
                get_players(players, num, "ch")
                for(new i = 0; i < num; i++)
                {
                    // Event-source entitlement: 1h auto-expiry, revoke-able on
                    // end-toggle without touching static or purchased VIP.
                    fnvip_grant(players[i], FNVIP_VIP, 3600, FNVIP_SRC_EVENT)
                }
                client_printcolor(0, "!g[FreeNova] !gTemp VIP !ngranted to all by !t%s", name)
            }
            else
            {
                new players[32], num
                get_players(players, num, "ch")
                for(new i = 0; i < num; i++)
                {
                    fnvip_revoke(players[i], FNVIP_VIP, FNVIP_SRC_EVENT)
                }
                client_printcolor(0, "!g[FreeNova] !gTemp VIP !nended by !t%s", name)
            }
        }
        case EVENT_VIP_FEST:
        {
            if(g_bEventActive[event])
            {
                new players[32], num
                get_players(players, num, "ch")
                for(new i = 0; i < num; i++)
                {
                    fnvip_grant(players[i], FNVIP_VIPPLUS, 3600, FNVIP_SRC_EVENT)
                }
                client_printcolor(0, "!g[FreeNova] !gVIP Fest !nstarted by !t%s !n- All players get VIP+!", name)
            }
            else
            {
                new players[32], num
                get_players(players, num, "ch")
                for(new i = 0; i < num; i++)
                {
                    fnvip_revoke(players[i], FNVIP_VIPPLUS, FNVIP_SRC_EVENT)
                }
                client_printcolor(0, "!g[FreeNova] !gVIP Fest !nended by !t%s", name)
            }
        }
        case EVENT_SPEED_RUSH:
        {
            new players[32], num
            get_players(players, num, "ch")

            for(new i = 0; i < num; i++)
            {
                // Never write maxspeed during freeze: that un-freezes players
                // until the engine's next speed recalc. PreThink / Round_Start
                // re-apply Speed Rush once the freeze window closes.
                if(is_user_alive(players[i]) && !g_bFreezeWindow)
                    set_user_maxspeed(players[i], g_bEventActive[event] ? 500.0 : 250.0)
            }

            if(g_bEventActive[event])
                client_printcolor(0, "!g[FreeNova] !gSpeed Rush !nstarted by !t%s !n- Everyone is fast!", name)
            else
                client_printcolor(0, "!g[FreeNova] !gSpeed Rush !nended by !t%s", name)
        }
        case EVENT_GOLDEN_DEAGLE:
        {
            if(g_bEventActive[event])
            {
                new players[32], num
                get_players(players, num, "ch")
                for(new i = 0; i < num; i++)
                {
                    if(is_user_alive(players[i]))
                        ArmGoldenDeagle(players[i])
                }

                RemoveGroundWeapons()

                remove_task(TASK_CLEANUP)
                set_task(0.5, "Task_RemoveGroundBoxes", TASK_CLEANUP, "", 0, "b")

                client_printcolor(0, "!g[FreeNova] !gGolden Deagle !nstarted by !t%s !g- Deagles for everyone!", name)
            }
            else
            {
                remove_task(TASK_CLEANUP)
                client_printcolor(0, "!g[FreeNova] !gGolden Deagle !nended by !t%s", name)
            }
        }
        case EVENT_DOUBLE_XP:
        {
            new pcvar = get_cvar_pointer("fn_double_xp")
            if(g_bEventActive[event])
            {
                if(pcvar) set_pcvar_num(pcvar, 1)
                client_printcolor(0, "!g[FreeNova] !gDouble XP !nstarted by !t%s !n- 2x XP for all!", name)
            }
            else
            {
                if(pcvar) set_pcvar_num(pcvar, 0)
                client_printcolor(0, "!g[FreeNova] !gDouble XP !nended by !t%s", name)
            }
        }
        case EVENT_LOW_GRAVITY:
        {
            if(g_bEventActive[event])
            {
                g_iSavedGravity = get_cvar_num("sv_gravity")
                if(g_iSavedGravity <= 0)
                    g_iSavedGravity = 800
                server_cmd("sv_gravity 400")
                client_printcolor(0, "!g[FreeNova] !gLow Gravity !nstarted by !t%s !n- Float like a balloon!", name)
            }
            else
            {
                server_cmd("sv_gravity %d", g_iSavedGravity)
                client_printcolor(0, "!g[FreeNova] !gLow Gravity !nended by !t%s", name)
            }
        }
    }
}

// ============================================================
// EVENT ENFORCEMENT
// ============================================================

// Spawn loadout enforcement for knife round / golden deagle
public Ham_PlayerSpawn_EventCheck(id)
{
    if(!is_user_alive(id))
        return HAM_IGNORED

    // Spawn can precede HLTV; open the freeze window so Speed Rush toggle /
    // PreThink cannot write maxspeed before the engine freeze lock.
    if(!g_bRoundStarted && get_cvar_num("mp_freezetime") > 0)
        g_bFreezeWindow = true

    if(!g_bEventActive[EVENT_KNIFE_ROUND] && !g_bEventActive[EVENT_GOLDEN_DEAGLE])
        return HAM_IGNORED

    // Small delay so the game finishes giving default gear first
    remove_task(id + TASK_LOADOUT)
    set_task(0.5, "Task_ArmEventLoadout", id + TASK_LOADOUT)
    return HAM_IGNORED
}

public Task_ArmEventLoadout(taskid)
{
    new id = taskid - TASK_LOADOUT
    if(!is_user_alive(id))
        return

    if(g_bEventActive[EVENT_KNIFE_ROUND])
        ArmKnifeRound(id)
    else if(g_bEventActive[EVENT_GOLDEN_DEAGLE])
        ArmGoldenDeagle(id)
}

ArmKnifeRound(id)
{
    new weapons[32], num
    get_user_weapons(id, weapons, num)

    for(new i = 0; i < num; i++)
    {
        if(weapons[i] != CSW_KNIFE && weapons[i] != CSW_C4)
            RemovePlayerWeapon(id, weapons[i])
    }

    engclient_cmd(id, "weapon_knife")
}

ArmGoldenDeagle(id)
{
    new weapons[32], num
    get_user_weapons(id, weapons, num)

    for(new i = 0; i < num; i++)
    {
        if(weapons[i] != CSW_DEAGLE && weapons[i] != CSW_KNIFE && weapons[i] != CSW_C4)
            RemovePlayerWeapon(id, weapons[i])
    }

    if(!user_has_weapon(id, CSW_DEAGLE))
        give_item(id, "weapon_deagle")

    cs_set_user_bpammo(id, CSW_DEAGLE, 35)
    engclient_cmd(id, "weapon_deagle")
}

// Silently DELETE a weapon entity owned by a player.
// Nothing is dropped - so there is NOTHING to pick up.
RemovePlayerWeapon(id, weaponId)
{
    if(weaponId == CSW_KNIFE || weaponId == CSW_C4)
        return

    new weaponName[32]
    get_weaponname(weaponId, weaponName, charsmax(weaponName))

    new weaponEnt = find_ent_by_owner(-1, weaponName, id)
    if(pev_valid(weaponEnt))
        set_pev(weaponEnt, pev_flags, pev(weaponEnt, pev_flags) | FL_KILLME)
}

// Delete ALL weapon entities lying on the ground
RemoveGroundWeapons()
{
    new ent = MAX_PLAYERS + 1
    while((ent = find_ent_by_class(ent, "weaponbox")) > 0)
    {
        if(pev_valid(ent))
            set_pev(ent, pev_flags, pev(ent, pev_flags) | FL_KILLME)
    }
}

public Task_RemoveGroundBoxes()
{
    if(!g_bEventActive[EVENT_KNIFE_ROUND] && !g_bEventActive[EVENT_GOLDEN_DEAGLE])
    {
        remove_task(TASK_CLEANUP)
        return
    }

    RemoveGroundWeapons()
}


// Block buy commands during knife round / golden deagle
public FM_EventBlock_BuyCmd(id)
{
    if(!is_user_connected(id) || !is_user_alive(id))
        return FMRES_IGNORED

    if(!g_bEventActive[EVENT_KNIFE_ROUND] && !g_bEventActive[EVENT_GOLDEN_DEAGLE])
        return FMRES_IGNORED

    new szArg[16]
    read_argv(0, szArg, charsmax(szArg))

    if(equal(szArg, "buy") || equal(szArg, "buyequip") || equal(szArg, "autobuy") || equal(szArg, "rebuy"))
        return FMRES_SUPERCEDE

    return FMRES_IGNORED
}

public Cmd_BlockBuyMenu(id)
{
    if(!is_user_alive(id))
        return PLUGIN_CONTINUE
    if(!g_bEventActive[EVENT_KNIFE_ROUND] && !g_bEventActive[EVENT_GOLDEN_DEAGLE])
        return PLUGIN_CONTINUE
    new oldmenu, newmenu
    player_menu_info(id, oldmenu, newmenu)
    if(newmenu != -1)
        return PLUGIN_CONTINUE
    return PLUGIN_HANDLED
}

// Per-frame event enforcement on every weapon switch
public Event_CurWeapon_ServerEvents(id)
{
    if(!is_user_alive(id))
        return

    // Knife round: instantly switch to knife and strip the weapon
    if(g_bEventActive[EVENT_KNIFE_ROUND])
    {
        new wpn = get_user_weapon(id)
        if(wpn != CSW_KNIFE && wpn != CSW_C4)
        {
            // Switch to knife FIRST so the player never sees the bought weapon
            engclient_cmd(id, "weapon_knife")
            // Then strip the unwanted weapon on the next frame
            remove_task(id + TASK_LOADOUT)
            set_task(0.1, "Task_StripWeapon", id + TASK_LOADOUT)
        }
        return
    }

    // Golden deagle: instantly switch to deagle and strip anything else
    if(g_bEventActive[EVENT_GOLDEN_DEAGLE])
    {
        new wpn = get_user_weapon(id)
        if(wpn != CSW_DEAGLE && wpn != CSW_KNIFE && wpn != CSW_C4)
        {
            engclient_cmd(id, "weapon_deagle")
            remove_task(id + TASK_LOADOUT)
            set_task(0.1, "Task_StripWeapon", id + TASK_LOADOUT)
        }
        return
    }

}

// Strip any non-knife weapon from a player (delayed task)
public Task_StripWeapon(taskid)
{
    new id = taskid - TASK_LOADOUT
    if(!is_user_alive(id))
        return

    new weapons[32], num
    get_user_weapons(id, weapons, num)

    for(new i = 0; i < num; i++)
    {
        new wid = weapons[i]
        if(wid == CSW_KNIFE || wid == CSW_C4)
            continue
        if(g_bEventActive[EVENT_GOLDEN_DEAGLE] && wid == CSW_DEAGLE)
            continue
        RemovePlayerWeapon(id, wid)
    }

    new wpn = get_user_weapon(id)
    if(wpn == CSW_C4)
        return
    if(g_bEventActive[EVENT_GOLDEN_DEAGLE] && wpn != CSW_DEAGLE && wpn != CSW_KNIFE)
        engclient_cmd(id, "weapon_deagle")
    else if(wpn != CSW_KNIFE)
        engclient_cmd(id, "weapon_knife")
}

// Speed rush enforcement: CS engine resets maxspeed on weapon switches,
// so we must re-apply it in PreThink every frame.
public client_PreThink(id)
{
    if(!is_user_alive(id))
        return PLUGIN_CONTINUE

    // Re-apply freeze every frame so the engine can't clear it.
    // Speed Rush is never written during the freezetime window: a full-speed
    // maxspeed write while frozen lets players move for ~1s at round start
    // until the engine's next speed recalc (freezetime movement bug).
    if(g_bFrozen[id])
    {
        set_pev(id, pev_flags, pev(id, pev_flags) | FL_FROZEN)
        set_user_maxspeed(id, 1.0)
    }
    else if(!g_bFreezeWindow && g_bEventActive[EVENT_SPEED_RUSH])
    {
        set_user_maxspeed(id, 500.0)
    }

    return PLUGIN_CONTINUE
}

// freeze window: opens on new round (HLTV), closes when movement resumes
public Event_NewRound()
{
    g_bRoundStarted = false
    if(get_cvar_num("mp_freezetime") > 0)
        g_bFreezeWindow = true

    // new round: clear per-round kill counters (round-MVP tracking)
    for(new i = 1; i <= MaxClients; i++)
        g_iRoundKills[i] = 0
}

public Event_RoundEnd_Freeze()
{
    // Spawn for the next round can precede HLTV. Drop last round's started
    // flag so Ham_Spawn can open the freeze window before Speed Rush writes.
    // Do not set g_bFreezeWindow here: players still walk until the next freeze.
    g_bRoundStarted = false
}

public Event_RoundStart()
{
    // freeze over - re-apply Speed Rush immediately so nothing is lost
    g_bFreezeWindow = false
    g_bRoundStarted = true

    if(g_bEventActive[EVENT_SPEED_RUSH])
    {
        new players[32], num
        get_players(players, num, "ch")

        for(new i = 0; i < num; i++)
        {
            if(is_user_alive(players[i]))
                set_user_maxspeed(players[i], 500.0)
        }
    }
}

// ============================================================
// GIVE RANK XP (RSU/CRX ledger only)
// ============================================================
// Owners/developers (manager flag a) may grant rank XP to anyone, including
// themselves and other managers. This path must only call the rank native
// (crxranks_give_user_xp). It must never call menabp_add_xp: BattlePass XP is
// a separate ledger with its own target snapshot and menu below.
// CanModerate() itself is untouched: bans, kicks, slays and the rest keep
// their existing protection.

stock bool:PanelGiveXPAccess(adminId, targetId)
{
    if(!is_user_connected(adminId) || !is_user_connected(targetId))
        return false
    return (get_user_flags(adminId) & FLAG_MANAGER) ? true : false
}

stock bool:PanelXpTargetValid(id)
{
    if(id < 1 || id > MAX_PLAYERS)
        return false

    new tid = g_iXpTarget[id]
    if(tid < 1 || tid > MAX_PLAYERS || !is_user_connected(tid))
        return false
    if(is_user_bot(tid) || is_user_hltv(tid))
        return false
    if(get_user_userid(tid) != g_iXpUserid[id])
        return false

    new szAuth[35]
    get_user_authid(tid, szAuth, charsmax(szAuth))
    if(g_szXpAuth[id][0] && !equal(szAuth, g_szXpAuth[id]))
        return false

    return true
}

stock bool:PanelGiveXPEligible(adminId, targetId)
{
    if(!is_user_connected(targetId))
        return false
    if(is_user_bot(targetId) || is_user_hltv(targetId))
        return false
    if(!PanelGiveXPAccess(adminId, targetId))
        return false
    // RSU drops XP before the target's stats row is READY. Do not offer a
    // target whose grant would silently disappear.
    if(!crxranks_is_user_loaded(targetId))
        return false
    return true
}

ShowGiveXP(id)
{
    if(!(get_user_flags(id) & FLAG_MANAGER))
    {
        client_printcolor(id, "!g[FreeNova] !nManager access required.")
        return
    }

    new szTitle[64]
    FN_MenuTitle(szTitle, charsmax(szTitle), "Give Rank XP")
    new menu = menu_create(szTitle, "GiveXPHandler")

    new players[32], num, tempId, name[32]
    get_players(players, num, "ch")

    for(new i = 0; i < num; i++)
    {
        tempId = players[i]
        if(!PanelGiveXPEligible(id, tempId))
            continue
        get_user_name(tempId, name, charsmax(name))
        if(tempId == id)
            menu_additem(menu, fmt("\w%s \y(you) \d[Lv.%d]", name, crxranks_get_user_level(tempId)), fmt("%d", tempId))
        else
            menu_additem(menu, fmt("\w%s \y(Lv.%d)", name, crxranks_get_user_level(tempId)), fmt("%d", tempId))
    }

    if(menu_items(menu) == 0)
        menu_additem(menu, "\dNo eligible players right now", "x")

    FN_MenuFinish(menu, true)
    menu_display(id, menu, 0)
}

public GiveXPHandler(id, menu, item)
{
    if(item == MENU_EXIT)
    {
        menu_destroy(menu)
        ShowEconomyPanel(id)
        return PLUGIN_HANDLED
    }
    if(item < 0)
        return PLUGIN_CONTINUE

    new data[16], name[64], access, callback
    menu_item_getinfo(menu, item, access, data, charsmax(data), name, charsmax(name), callback)
    menu_destroy(menu)

    new tid = str_to_num(data)

    if(tid < 1)
    {
        ShowGiveXP(id)
        return PLUGIN_HANDLED
    }
    if(!is_user_connected(tid))
    {
        client_printcolor(id, "!g[FreeNova] !nPlayer no longer connected.")
        return PLUGIN_HANDLED
    }
    if(!PanelGiveXPAccess(id, tid))
    {
        client_printcolor(id, "!g[FreeNova] !nManager access required.")
        return PLUGIN_HANDLED
    }
    if(is_user_bot(tid) || is_user_hltv(tid))
    {
        client_printcolor(id, "!g[FreeNova] !nOnly connected human players can receive rank XP.")
        return PLUGIN_HANDLED
    }
    if(!crxranks_is_user_loaded(tid))
    {
        client_printcolor(id, "!g[FreeNova] !nThat player's rank data is still loading - try again in a moment.")
        ShowGiveXP(id)
        return PLUGIN_HANDLED
    }

    g_iXpTarget[id] = tid
    g_iXpUserid[id] = get_user_userid(tid)
    get_user_authid(tid, g_szXpAuth[id], charsmax(g_szXpAuth[]))
    g_iTargetPlayer[id] = tid

    ShowXPAmount(id)
    return PLUGIN_HANDLED
}

ShowXPAmount(id)
{
    new szTitle[64]
    FN_MenuTitle(szTitle, charsmax(szTitle), "Rank XP amount")
    new menu = menu_create(szTitle, "XPAmountHandler")

    menu_additem(menu, "\w100 Rank XP", "0")
    menu_additem(menu, "\w500 Rank XP", "1")
    menu_additem(menu, "\w1000 Rank XP", "2")
    menu_additem(menu, "\w2500 Rank XP", "3")
    menu_additem(menu, "\w5000 Rank XP", "4")

    FN_MenuFinish(menu, true)
    menu_display(id, menu, 0)
}

public XPAmountHandler(id, menu, item)
{
    if(item == MENU_EXIT || item == MENU_BACK)
    {
        menu_destroy(menu)
        ShowGiveXP(id)
        return PLUGIN_HANDLED
    }
    if(item == MENU_MORE)
        return PLUGIN_CONTINUE

    new data[8], name[64], access, callback
    menu_item_getinfo(menu, item, access, data, charsmax(data), name, charsmax(name), callback)
    menu_destroy(menu)

    new amounts[] = {100, 500, 1000, 2500, 5000}
    new idx = str_to_num(data)
    if(idx < 0 || idx >= sizeof(amounts))
        return PLUGIN_HANDLED
    new amount = amounts[idx]

    if(!PanelXpTargetValid(id))
    {
        client_printcolor(id, "!g[FreeNova] !nPlayer is no longer connected or slot was reused.")
        return PLUGIN_HANDLED
    }

    new tid = g_iXpTarget[id]
    if(!PanelGiveXPAccess(id, tid))
    {
        client_printcolor(id, "!g[FreeNova] !nManager access required.")
        return PLUGIN_HANDLED
    }
    if(!crxranks_is_user_loaded(tid))
    {
        client_printcolor(id, "!g[FreeNova] !nThat player's rank data is still loading - nothing was added.")
        return PLUGIN_HANDLED
    }

    g_iTargetPlayer[id] = tid

    // RANK XP ONLY. Never call menabp_add_xp here. BP has its own ledger,
    // target snapshot, amount menu and handler below.
    new given = crxranks_give_user_xp(tid, amount, "", CRXRANKS_XPS_ADMIN)

    // Consume the snapshot so a replayed/stale amount callback cannot grant a
    // second time.
    g_iXpTarget[id] = 0
    g_iXpUserid[id] = 0
    g_szXpAuth[id][0] = 0

    new targetName[32], adminName[32]
    get_user_name(tid, targetName, charsmax(targetName))
    get_user_name(id, adminName, charsmax(adminName))

    if(given <= 0)
    {
        // RSU rejects XP while stats are disabled, during knife warmup, or
        // when a pre-forward blocks it. Never report a grant that did not
        // happen.
        if(!is_user_connected(tid))
            client_printcolor(id, "!g[FreeNova] !nPlayer disconnected - nothing was added.")
        else if(!crxranks_is_user_loaded(tid))
            client_printcolor(id, "!g[FreeNova] !nThat player's rank data is still loading - nothing was added.")
        else
            client_printcolor(id, "!g[FreeNova] !nThe rank system did not accept that XP (warmup/disabled/blocked) - nothing was changed.")
        log_amx("[FreeNova] GIVERANKXP FAILED admin=%s target=%s requested=%d reason=leveling_rejected", adminName, targetName, amount)
        return PLUGIN_HANDLED
    }

    if(tid == id)
    {
        client_printcolor(id, "!g[FreeNova] !nGave yourself %d Rank XP (requested %d; BP XP unchanged).", given, amount)
    }
    else
    {
        client_printcolor(id, "!g[FreeNova] !nGave %d Rank XP to %s (BP XP unchanged)", given, targetName)
        client_printcolor(tid, "!g[FreeNova] !nAdmin %s gave you %d Rank XP!", adminName, given)
    }

    log_amx("[FreeNova] Admin %s granted %d Rank XP to %s (requested %d, self=%d)", adminName, given, targetName, amount, tid == id ? 1 : 0)

    return PLUGIN_HANDLED
}

// ============================================================
// GIVE BATTLEPASS XP (battlepass_core ledger only)
// ============================================================
// This flow has its own target snapshot and its own access/validation helpers.
// It must never call crxranks_give_user_xp or rsu_add_xp. The rank flow above
// must never call menabp_add_xp. BP tier-ups grant BP rewards only.

stock bool:PanelGiveBpXPAccess(adminId, targetId)
{
    if(!is_user_connected(adminId) || !is_user_connected(targetId))
        return false
    return (get_user_flags(adminId) & FLAG_MANAGER) ? true : false
}

stock bool:PanelBpReady(id)
{
    if(!LibraryExists("menabp", LibType_Library))
        return false
    return bool:menabp_is_ready(id)
}

stock bool:PanelBpXpTargetValid(id)
{
    if(id < 1 || id > MAX_PLAYERS)
        return false

    new tid = g_iBpXpTarget[id]
    if(tid < 1 || tid > MAX_PLAYERS || !is_user_connected(tid))
        return false
    if(is_user_bot(tid) || is_user_hltv(tid))
        return false
    if(get_user_userid(tid) != g_iBpXpUserid[id])
        return false

    new szAuth[35]
    get_user_authid(tid, szAuth, charsmax(szAuth))
    if(g_szBpXpAuth[id][0] && !equal(szAuth, g_szBpXpAuth[id]))
        return false

    return true
}

stock bool:PanelGiveBpXPEligible(adminId, targetId)
{
    if(!is_user_connected(targetId))
        return false
    if(is_user_bot(targetId) || is_user_hltv(targetId))
        return false
    if(!PanelGiveBpXPAccess(adminId, targetId))
        return false
    // battlepass_core owns a separate BP ledger. Do not offer a target whose
    // BP row is not READY, or the grant would be dropped.
    if(!PanelBpReady(targetId))
        return false
    return true
}

ShowGiveBpXP(id)
{
    if(!(get_user_flags(id) & FLAG_MANAGER))
    {
        client_printcolor(id, "!g[FreeNova] !nManager access required.")
        return
    }

    new szTitle[64]
    FN_MenuTitle(szTitle, charsmax(szTitle), "Give BP XP")
    new menu = menu_create(szTitle, "GiveBpXPHandler")

    new players[32], num, tempId, name[32]
    get_players(players, num, "ch")

    for(new i = 0; i < num; i++)
    {
        tempId = players[i]
        if(!PanelGiveBpXPEligible(id, tempId))
            continue
        get_user_name(tempId, name, charsmax(name))
        new iBpTier = menabp_get_tier(tempId)
        new iBpXp = menabp_get_xp(tempId)
        if(tempId == id)
            menu_additem(menu, fmt("\w%s \y(you) \d[BP T%d - %d XP]", name, iBpTier, iBpXp), fmt("%d", tempId))
        else
            menu_additem(menu, fmt("\w%s \y(BP T%d - %d XP)", name, iBpTier, iBpXp), fmt("%d", tempId))
    }

    if(menu_items(menu) == 0)
        menu_additem(menu, "\dNo eligible players right now", "x")

    FN_MenuFinish(menu, true)
    menu_display(id, menu, 0)
}

public GiveBpXPHandler(id, menu, item)
{
    if(item == MENU_EXIT)
    {
        menu_destroy(menu)
        g_iBpXpTarget[id] = 0
        g_iBpXpUserid[id] = 0
        g_szBpXpAuth[id][0] = 0
        ShowEconomyPanel(id)
        return PLUGIN_HANDLED
    }
    if(item < 0)
        return PLUGIN_CONTINUE

    new data[16], name[64], access, callback
    menu_item_getinfo(menu, item, access, data, charsmax(data), name, charsmax(name), callback)
    menu_destroy(menu)

    new tid = str_to_num(data)

    if(tid < 1)
    {
        ShowGiveBpXP(id)
        return PLUGIN_HANDLED
    }
    if(!is_user_connected(tid))
    {
        client_printcolor(id, "!g[FreeNova] !nPlayer no longer connected.")
        return PLUGIN_HANDLED
    }
    if(!PanelGiveBpXPAccess(id, tid))
    {
        client_printcolor(id, "!g[FreeNova] !nManager access required.")
        return PLUGIN_HANDLED
    }
    if(is_user_bot(tid) || is_user_hltv(tid))
    {
        client_printcolor(id, "!g[FreeNova] !nOnly connected human players can receive BP XP.")
        return PLUGIN_HANDLED
    }
    if(!PanelBpReady(tid))
    {
        client_printcolor(id, "!g[FreeNova] !nThat player's BattlePass data is still loading - try again in a moment.")
        ShowGiveBpXP(id)
        return PLUGIN_HANDLED
    }

    g_iBpXpTarget[id] = tid
    g_iBpXpUserid[id] = get_user_userid(tid)
    get_user_authid(tid, g_szBpXpAuth[id], charsmax(g_szBpXpAuth[]))
    g_iTargetPlayer[id] = tid

    ShowBpXPAmount(id)
    return PLUGIN_HANDLED
}

ShowBpXPAmount(id)
{
    new szTitle[64]
    FN_MenuTitle(szTitle, charsmax(szTitle), "BP XP amount")
    new menu = menu_create(szTitle, "BpXPAmountHandler")

    menu_additem(menu, "\w100 BP XP", "0")
    menu_additem(menu, "\w500 BP XP", "1")
    menu_additem(menu, "\w1000 BP XP", "2")
    menu_additem(menu, "\w2500 BP XP", "3")
    menu_additem(menu, "\w5000 BP XP", "4")

    FN_MenuFinish(menu, true)
    menu_display(id, menu, 0)
}

public BpXPAmountHandler(id, menu, item)
{
    if(item == MENU_EXIT || item == MENU_BACK)
    {
        menu_destroy(menu)
        g_iBpXpTarget[id] = 0
        g_iBpXpUserid[id] = 0
        g_szBpXpAuth[id][0] = 0
        ShowGiveBpXP(id)
        return PLUGIN_HANDLED
    }
    if(item == MENU_MORE)
        return PLUGIN_CONTINUE

    new data[8], name[64], access, callback
    menu_item_getinfo(menu, item, access, data, charsmax(data), name, charsmax(name), callback)
    menu_destroy(menu)

    new amounts[] = {100, 500, 1000, 2500, 5000}
    new idx = str_to_num(data)
    if(idx < 0 || idx >= sizeof(amounts))
        return PLUGIN_HANDLED
    new amount = amounts[idx]

    if(!PanelBpXpTargetValid(id))
    {
        client_printcolor(id, "!g[FreeNova] !nPlayer is no longer connected or slot was reused.")
        return PLUGIN_HANDLED
    }

    new tid = g_iBpXpTarget[id]
    if(!PanelGiveBpXPAccess(id, tid))
    {
        client_printcolor(id, "!g[FreeNova] !nManager access required.")
        return PLUGIN_HANDLED
    }
    if(!PanelBpReady(tid))
    {
        client_printcolor(id, "!g[FreeNova] !nThat player's BattlePass data is still loading - nothing was added.")
        return PLUGIN_HANDLED
    }

    g_iTargetPlayer[id] = tid

    // BATTLEPASS XP ONLY. Never call crxranks_give_user_xp here. This native
    // writes the separate BP ledger and triggers BP tier rewards only.
    new given = menabp_add_xp(tid, amount)

    // Consume the snapshot so a replayed/stale amount callback cannot grant a
    // second time.
    g_iBpXpTarget[id] = 0
    g_iBpXpUserid[id] = 0
    g_szBpXpAuth[id][0] = 0

    new targetName[32], adminName[32]
    get_user_name(tid, targetName, charsmax(targetName))
    get_user_name(id, adminName, charsmax(adminName))

    if(given <= 0)
    {
        if(!is_user_connected(tid))
            client_printcolor(id, "!g[FreeNova] !nPlayer disconnected - nothing was added.")
        else if(!PanelBpReady(tid))
            client_printcolor(id, "!g[FreeNova] !nThat player's BattlePass data is still loading - nothing was added.")
        else
            client_printcolor(id, "!g[FreeNova] !nThe BattlePass did not accept that XP (max tier/disabled) - nothing was changed.")
        log_amx("[FreeNova] GIVEBPXP FAILED admin=%s target=%s requested=%d reason=bp_rejected", adminName, targetName, amount)
        return PLUGIN_HANDLED
    }

    // Exact post-grant state. The menu must not leave the admin guessing at
    // the new total; menabp_get_xp() is the same authoritative BP ledger.
    new iTotal, iTier
    if(is_user_connected(tid) && PanelBpReady(tid))
    {
        iTotal = menabp_get_xp(tid)
        iTier = menabp_get_tier(tid)
    }

    if(tid == id)
    {
        client_printcolor(id, "!g[FreeNova] !nGave yourself %d BP XP (requested %d; rank XP unchanged).", given, amount)
    }
    else
    {
        client_printcolor(id, "!g[FreeNova] !nGave %d BP XP to %s (rank XP unchanged)", given, targetName)
        client_printcolor(tid, "!g[FreeNova] !nAdmin %s gave you %d BP XP!", adminName, given)
    }

    if(iTotal > 0)
    {
        client_printcolor(id, "!g[FreeNova] !nBP total: !g%d !nXP | !gTier %d", iTotal, iTier)
        if(tid != id)
            client_printcolor(tid, "!g[FreeNova] !nYour BP total: !g%d !nXP | !gTier %d", iTotal, iTier)
    }

    log_amx("[FreeNova] Admin %s granted %d BP XP to %s (requested %d, total=%d, tier=%d, self=%d)",
        adminName, given, targetName, amount, iTotal, iTier, tid == id ? 1 : 0)

    return PLUGIN_HANDLED
}

public Cmd_AdminGiveBpXp(id, level, cid)
{
    if(!cmd_access(id, level, cid, 3))
        return PLUGIN_HANDLED

    new szTarget[32], szAmount[16]
    read_argv(1, szTarget, charsmax(szTarget))
    read_argv(2, szAmount, charsmax(szAmount))

    new tid = cmd_target(id, szTarget, CMDTARGET_OBEY_IMMUNITY | CMDTARGET_NO_BOTS | CMDTARGET_ALLOW_SELF)
    if(!tid)
    {
        console_print(id, "[FreeNova] Target not found.")
        return PLUGIN_HANDLED
    }
    if(!PanelBpReady(tid))
    {
        console_print(id, "[FreeNova] Target BattlePass data is not ready.")
        return PLUGIN_HANDLED
    }

    new amount = str_to_num(szAmount)
    if(amount <= 0 || amount > 100000)
    {
        console_print(id, "[FreeNova] BP XP amount must be 1..100000.")
        return PLUGIN_HANDLED
    }

    // BP XP ONLY. This command must never grant rank XP.
    new given = menabp_add_xp(tid, amount)
    if(given <= 0)
    {
        console_print(id, "[FreeNova] BattlePass rejected the grant (max tier/disabled).")
        return PLUGIN_HANDLED
    }

    new targetName[32]
    get_user_name(tid, targetName, charsmax(targetName))
    new iTotal = menabp_get_xp(tid)
    new iTier = menabp_get_tier(tid)
    // Names the counter it moved, and the one it did not: amx_bp_givexp used to
    // move rank XP because menabp_add_xp called crxranks_give_user_xp
    // (REVIEW §2.4 H1). It now writes the BP ledger only.
    console_print(id, "[FreeNova] Granted %d BP XP to %s (requested %d). Total: %d BP XP | BP T%d. Rank XP unchanged.", given, targetName, amount, iTotal, iTier)
    client_printcolor(tid, "!g[FreeNova] !nAn admin gave you %d BP XP! Now %d total, BP T%d.", given, iTotal, iTier)
    log_amx("[FreeNova] ADMIN_CMD BPXP target=%s requested=%d granted=%d total=%d tier=%d", targetName, amount, given, iTotal, iTier)
    return PLUGIN_HANDLED
}

// ============================================================
// ROUND SETTINGS
// ============================================================
ShowRoundSettings(id)
{
    new szTitle[64]
    FN_MenuTitle(szTitle, charsmax(szTitle), "Round / Map")
    new menu = menu_create(szTitle, "RoundSettingsHandler")

    menu_additem(menu, "\wRestart Round", "0")
    menu_additem(menu, "\wChange Map", "1")
    menu_additem(menu, "\wExtend Round 2min", "2")
    menu_additem(menu, "\wToggle Freeze Time", "3")

    FN_MenuFinish(menu, true)
    menu_display(id, menu, 0)
}

public RoundSettingsHandler(id, menu, item)
{
    if(item == MENU_EXIT || item == MENU_BACK)
    {
        menu_destroy(menu)
        ShowServerPanel(id)
        return PLUGIN_HANDLED
    }
    if(item == MENU_MORE)
        return PLUGIN_CONTINUE

    if(!(get_user_flags(id) & FLAG_ADMIN))
    {
        client_printcolor(id, "!g[FreeNova] !nAdmin only.")
        menu_destroy(menu)
        return PLUGIN_HANDLED
    }

    new data[8], name[64], access, callback
    menu_item_getinfo(menu, item, access, data, charsmax(data), name, charsmax(name), callback)
    menu_destroy(menu)

    switch(str_to_num(data))
    {
        case 0:
        {
            server_cmd("sv_restart 1")
            client_printcolor(0, "!g[FreeNova] !gRound restarted by admin")
            log_amx("[FreeNova] Admin %d restarted round", id)
        }
        case 1:
            ShowMapSelect(id)
        case 2:
        {
            server_cmd("mp_roundtime 3")
            client_printcolor(0, "!g[FreeNova] !gRound extended to 3 minutes!")
            log_amx("[FreeNova] Admin %d extended round", id)
        }
        case 3:
        {
            new curFreeze = get_cvar_num("mp_freezetime")
            if(curFreeze > 0)
            {
                server_cmd("mp_freezetime 0")
                client_printcolor(0, "!g[FreeNova] !gFreeze time disabled")
            }
            else
            {
                server_cmd("mp_freezetime 5")
                client_printcolor(0, "!g[FreeNova] !gFreeze time enabled (5s)")
            }
            log_amx("[FreeNova] Admin %d toggled freeze time", id)
        }
    }

    return PLUGIN_HANDLED
}

ShowMapSelect(id)
{
    new szTitle[64]
    FN_MenuTitle(szTitle, charsmax(szTitle), "Select map")
    new menu = menu_create(szTitle, "MapSelectHandler")

    // Common maps — info string must be the map name; handler uses `data`.
    menu_additem(menu, "de_dust2", "de_dust2")
    menu_additem(menu, "de_inferno", "de_inferno")
    menu_additem(menu, "de_nuke", "de_nuke")
    menu_additem(menu, "de_mirage", "de_mirage")
    menu_additem(menu, "de_train", "de_train")
    menu_additem(menu, "de_cbble", "de_cbble")
    menu_additem(menu, "cs_office", "cs_office")
    menu_additem(menu, "cs_assault", "cs_assault")

    FN_MenuFinish(menu, true)
    menu_display(id, menu, 0)
}

public MapSelectHandler(id, menu, item)
{
    if(item == MENU_EXIT || item == MENU_BACK)
    {
        menu_destroy(menu)
        ShowRoundSettings(id)
        return PLUGIN_HANDLED
    }
    if(item == MENU_MORE)
        return PLUGIN_CONTINUE

    new data[32], name[64], access, callback
    menu_item_getinfo(menu, item, access, data, charsmax(data), name, charsmax(name), callback)
    menu_destroy(menu)

    if(!data[0] || contain(data, "..") != -1)
        return PLUGIN_HANDLED

    copy(g_szPendingMap[id], charsmax(g_szPendingMap[]), data)
    ShowMapConfirm(id)
    return PLUGIN_HANDLED
}

ShowMapConfirm(id)
{
    new szPage[48], szTitle[64]
    formatex(szPage, charsmax(szPage), "Map %s?", g_szPendingMap[id])
    FN_MenuTitle(szTitle, charsmax(szTitle), szPage)
    new menu = menu_create(szTitle, "MapConfirmHandler")
    menu_additem(menu, fmt("\wYes, changelevel \y%s", g_szPendingMap[id]), "yes")
    menu_additem(menu, "\wNo, cancel", "no")
    FN_MenuFinish(menu, true)
    menu_display(id, menu, 0)
}

public MapConfirmHandler(id, menu, item)
{
    if(item == MENU_EXIT || item == MENU_BACK)
    {
        menu_destroy(menu)
        ShowMapSelect(id)
        return PLUGIN_HANDLED
    }

    new data[8], name[64], access, callback
    menu_item_getinfo(menu, item, access, data, charsmax(data), name, charsmax(name), callback)
    menu_destroy(menu)

    if(!equal(data, "yes") || !g_szPendingMap[id][0])
        return PLUGIN_HANDLED

    if(!(get_user_flags(id) & FLAG_ADMIN))
    {
        client_printcolor(id, "!g[FreeNova] !nAdmin only.")
        return PLUGIN_HANDLED
    }

    log_amx("[FreeNova] Admin %d changelevel %s", id, g_szPendingMap[id])
    server_cmd("changelevel %s", g_szPendingMap[id])
    return PLUGIN_HANDLED
}

// ============================================================
// VIP MANAGEMENT
// ============================================================
ShowVIPManagement(id)
{
    if(!is_user_connected(id) || !(get_user_flags(id) & FLAG_MANAGER))
    {
        if(is_user_connected(id))
            client_printcolor(id, "!g[FreeNova] !nManager access required.")
        return
    }

    new szTitle[64]
    FN_MenuTitle(szTitle, charsmax(szTitle), "VIP")
    new menu = menu_create(szTitle, "VIPManageHandler")

    new players[32], num, tempId, name[32]
    get_players(players, num, "ch")

    for(new i = 0; i < num; i++)
    {
        tempId = players[i]
        get_user_name(tempId, name, charsmax(name))
        new vipTier = fnvip_get_tier(tempId)
        new remaining = fnvip_get_remaining(tempId)
        new szTier[16]
        fnvip_get_tier_name_raw(vipTier, szTier, charsmax(szTier))
        if(!szTier[0] || equal(szTier, "None"))
            copy(szTier, charsmax(szTier), "Member")

        new szRemain[24]
        if(vipTier < 1)
            copy(szRemain, charsmax(szRemain), "-")
        else if(remaining == -1)
            copy(szRemain, charsmax(szRemain), "Permanent")
        else if(remaining > 0)
            formatex(szRemain, charsmax(szRemain), "%dd %dh", remaining / 86400, (remaining % 86400) / 3600)
        else
            copy(szRemain, charsmax(szRemain), "Active")

        menu_additem(menu, fmt("\w%s \y[%s] \d[%s]", name, szTier, szRemain), fmt("%d", get_user_userid(tempId)))
    }

    FN_MenuFinish(menu, true)
    menu_display(id, menu, 0)
}

public VIPManageHandler(id, menu, item)
{
    if(item == MENU_EXIT)
    {
        menu_destroy(menu)
        ShowEconomyPanel(id)
        return PLUGIN_HANDLED
    }
    if(!is_user_connected(id) || !(get_user_flags(id) & FLAG_MANAGER))
    {
        menu_destroy(menu)
        if(is_user_connected(id))
            client_printcolor(id, "!g[FreeNova] !nManager access required.")
        return PLUGIN_HANDLED
    }
    if(item < 0)
        return PLUGIN_CONTINUE

    new data[16], name[64], access, callback
    menu_item_getinfo(menu, item, access, data, charsmax(data), name, charsmax(name), callback)
    menu_destroy(menu)

    new tid = find_player("k", str_to_num(data))
    if(!tid || !is_user_connected(tid))
    {
        client_printcolor(id, "!g[FreeNova] !nPlayer no longer connected.")
        return PLUGIN_HANDLED
    }

    // Userid in info: slot reuse resolves to 0/wrong slot and is rejected.
    // Snapshot userid+auth the same way ExecuteBan does so slot reuse
    // cannot grant/revoke VIP on the new occupant.
    g_iTargetPlayer[id] = tid
    g_iBanTarget[id] = tid
    g_iBanUserid[id] = get_user_userid(tid)
    get_user_authid(tid, g_szBanAuth[id], charsmax(g_szBanAuth[]))

    ShowVIPTierSelect(id)
    return PLUGIN_HANDLED
}

ShowVIPTierSelect(id)
{
    if( !PanelBanTargetValid(id) )
    {
        client_printcolor(id, "!g[FreeNova] !nPlayer is no longer connected or slot was reused.")
        return
    }

    new szTitle[64]
    FN_MenuTitle(szTitle, charsmax(szTitle), "VIP tier")
    new menu = menu_create(szTitle, "VIPTierHandler")

    new tid = g_iBanTarget[id]
    new targetName[32]
    get_user_name(tid, targetName, charsmax(targetName))

    menu_additem(menu, fmt("\wRemove VIP from \y%s", targetName), "0")
    menu_additem(menu, fmt("\wGive \rVIP \w(30 days) \wto \y%s", targetName), "1")
    menu_additem(menu, fmt("\wGive \rVIP+ \w(30 days) \wto \y%s", targetName), "2")
    menu_additem(menu, fmt("\wGive \rVIP Elite \w(30 days) \wto \y%s", targetName), "3")
    menu_additem(menu, fmt("\wMake \rVIP Elite \wPERMANENT \wfor \y%s", targetName), "4")

    FN_MenuFinish(menu, true)
    menu_display(id, menu, 0)
}

public VIPTierHandler(id, menu, item)
{
    if(item == MENU_EXIT)
    {
        menu_destroy(menu)
        ShowVIPManagement(id)
        return PLUGIN_HANDLED
    }

    new data[8], name[64], access, callback
    menu_item_getinfo(menu, item, access, data, charsmax(data), name, charsmax(name), callback)
    menu_destroy(menu)

    new tier = str_to_num(data)
    if( !PanelBanTargetValid(id) )
    {
        client_printcolor(id, "!g[FreeNova] !nPlayer is no longer connected or slot was reused.")
        return PLUGIN_HANDLED
    }
    new tid = g_iBanTarget[id]

    // Granting/revoking VIP is manager-level: moderators must not escalate
    if(!(get_user_flags(id) & FLAG_MANAGER) || !CanModerate(id, tid))
    {
        client_printcolor(id, "!g[FreeNova] !nManager access required.")
        return PLUGIN_HANDLED
    }

    // All tier changes go through the unified VIP core: entitlements are
    // persisted per-authid with expiry, additive (never downgrade), and
    // flag syncing is handled centrally.
    if(tier == 0)
    {
        ShowVIPRevokeConfirm(id)
        return PLUGIN_HANDLED
    }
    else if(tier == 4)
    {
        // Permanent = grant far-future entitlement (10 years)
        fnvip_grant(tid, FNVIP_ELITE, 315360000, FNVIP_SRC_ADMIN)
    }
    else
    {
        fnvip_grant(tid, tier, 2592000, FNVIP_SRC_ADMIN) // 30 days
    }

    new targetName[32], adminName[32]
    get_user_name(tid, targetName, charsmax(targetName))
    get_user_name(id, adminName, charsmax(adminName))

    new tierName[16]
    switch(tier)
    {
        case 0: copy(tierName, charsmax(tierName), "removed")
        case 1: copy(tierName, charsmax(tierName), "VIP (30d)")
        case 2: copy(tierName, charsmax(tierName), "VIP+ (30d)")
        case 3: copy(tierName, charsmax(tierName), "VIP Elite (30d)")
        case 4: copy(tierName, charsmax(tierName), "VIP Elite (permanent)")
    }

    client_printcolor(id, "!g[FreeNova] !n%s's VIP updated: %s", targetName, tierName)
    client_printcolor(tid, "!g[FreeNova] !nAdmin %s set your VIP: %s", adminName, tierName)
    log_amx("[FreeNova] Admin %s set VIP of %s: %s", adminName, targetName, tierName)

    return PLUGIN_HANDLED
}

ShowVIPRevokeConfirm(id)
{
    if(!PanelBanTargetValid(id))
    {
        client_printcolor(id, "!g[FreeNova] !nPlayer is no longer connected or slot was reused.")
        return
    }

    new tid = g_iBanTarget[id]
    new targetName[32], szTier[16]
    get_user_name(tid, targetName, charsmax(targetName))
    fnvip_get_tier_name(tid, szTier, charsmax(szTier))
    if(!szTier[0] || equal(szTier, "None"))
        copy(szTier, charsmax(szTier), "Member")

    new szTitle[64]
    FN_MenuTitle(szTitle, charsmax(szTitle), "REMOVE VIP")
    new menu = menu_create(szTitle, "VIPRevokeConfirmHandler")
    menu_additem(menu, fmt("\wPlayer: \y%s \d[%s]", targetName, szTier), "info")
    menu_additem(menu, "\r[1] Confirm Removal", "yes")
    menu_additem(menu, "\w[2] Cancel", "no")
    FN_MenuFinish(menu, true)
    menu_display(id, menu, 0)
}

public VIPRevokeConfirmHandler(id, menu, item)
{
    if(item == MENU_EXIT)
    {
        menu_destroy(menu)
        ShowVIPTierSelect(id)
        return PLUGIN_HANDLED
    }

    new data[8], name[64], access, callback
    menu_item_getinfo(menu, item, access, data, charsmax(data), name, charsmax(name), callback)
    menu_destroy(menu)

    if(!equal(data, "yes"))
    {
        ShowVIPTierSelect(id)
        return PLUGIN_HANDLED
    }

    if(!PanelBanTargetValid(id))
    {
        client_printcolor(id, "!g[FreeNova] !nPlayer is no longer connected or slot was reused.")
        return PLUGIN_HANDLED
    }
    new tid = g_iBanTarget[id]
    if(!(get_user_flags(id) & FLAG_MANAGER) || !CanModerate(id, tid))
    {
        client_printcolor(id, "!g[FreeNova] !nManager access required.")
        return PLUGIN_HANDLED
    }

    fnvip_revoke(tid, -1, -1)

    new targetName[32], adminName[32]
    get_user_name(tid, targetName, charsmax(targetName))
    get_user_name(id, adminName, charsmax(adminName))
    client_printcolor(id, "!g[FreeNova] !nRemoved VIP from %s", targetName)
    client_printcolor(tid, "!g[FreeNova] !nAdmin %s removed your VIP.", adminName)
    log_amx("[FreeNova] Admin %s removed VIP from %s", adminName, targetName)
    return PLUGIN_HANDLED
}

// ============================================================
// ADMIN MANAGEMENT
// ============================================================
ShowAdminManagement(id)
{
    new szTitle[64]
    FN_MenuTitle(szTitle, charsmax(szTitle), "Admins")
    new menu = menu_create(szTitle, "AdminManageHandler")

    new players[32], num, tempId, name[32]
    get_players(players, num, "ch")

    for(new i = 0; i < num; i++)
    {
        tempId = players[i]
        get_user_name(tempId, name, charsmax(name))
        new isAdmin = (get_user_flags(tempId) & FLAG_ADMIN) ? 1 : 0

        menu_additem(menu, fmt("\w%s \y%s", name, isAdmin ? "[ADMIN]" : ""), fmt("%d", tempId))
    }

    FN_MenuFinish(menu, true)
    menu_display(id, menu, 0)
}

public AdminManageHandler(id, menu, item)
{
    if(item == MENU_EXIT)
    {
        menu_destroy(menu)
        ShowServerPanel(id)
        return PLUGIN_HANDLED
    }
    if(item < 0)
        return PLUGIN_CONTINUE

    new data[16], name[64], access, callback
    menu_item_getinfo(menu, item, access, data, charsmax(data), name, charsmax(name), callback)
    menu_destroy(menu)

    new tid = str_to_num(data)

    if(!is_user_connected(tid))
    {
        client_printcolor(id, "!g[FreeNova] !nPlayer no longer connected.")
        return PLUGIN_HANDLED
    }

    // Granting/revoking admin flags is manager-level: moderators must
    // never be able to grant themselves or others admin flags
    if(!(get_user_flags(id) & FLAG_MANAGER) || !CanModerate(id, tid))
    {
        client_printcolor(id, "!g[FreeNova] !nManager access required.")
        return PLUGIN_HANDLED
    }

    new pflags = get_user_flags(tid)
    new isAdmin = (pflags & FLAG_ADMIN) ? 1 : 0

    if(isAdmin)
    {
        // Remove admin flags
        pflags &= ~FLAG_ADMIN_FULL
        set_user_flags(tid, pflags)
        SaveVipFlags(tid)
        client_printcolor(id, "!g[FreeNova] !nAdmin removed from %s", name)
        log_amx("[FreeNova] Admin %d removed admin flags from %s", id, name)
    }
    else
    {
        // Grant admin flags (cdeijuv)
        pflags |= FLAG_ADMIN_FULL
        set_user_flags(tid, pflags)
        SaveVipFlags(tid)
        client_printcolor(id, "!g[FreeNova] !nAdmin granted to %s", name)
        client_printcolor(tid, "!g[FreeNova] !nYou have been granted admin!")
        log_amx("[FreeNova] Admin %d granted admin flags to %s", id, name)
    }

    return PLUGIN_HANDLED
}

// ============================================================
// QUICK COMMANDS
// ============================================================
ShowQuickCommands(id)
{
    new szTitle[64]
    FN_MenuTitle(szTitle, charsmax(szTitle), "Quick commands")
    new menu = menu_create(szTitle, "QuickCmdHandler")

    menu_additem(menu, "\w/bp - BattlePass Preview", "0")
    menu_additem(menu, "\w/shop - Coin Shop", "1")
    menu_additem(menu, "\w/vip - VIP Purchase", "2")
    menu_additem(menu, "\w/rules - Server Rules", "3")
    if(g_bSkinsMenuAvailable)
        menu_additem(menu, "\w/skins - Weapon Skins", "4")
    // 5/6 were /admins + /cam: no admin_check or camera provider plugin
    // exists in this deployment, so the guarded entries were dead weight.
    menu_additem(menu, "\wReset My Score", "7")

    FN_MenuFinish(menu, true)
    menu_display(id, menu, 0)
}

public QuickCmdHandler(id, menu, item)
{
    if(item == MENU_EXIT || item == MENU_BACK)
    {
        menu_destroy(menu)
        ShowToolsPanel(id)
        return PLUGIN_HANDLED
    }
    if(item == MENU_MORE)
        return PLUGIN_CONTINUE

    new data[8], name[64], access, callback
    menu_item_getinfo(menu, item, access, data, charsmax(data), name, charsmax(name), callback)
    menu_destroy(menu)

    switch(str_to_num(data))
    {
        case 0: menabp_show_battlepass(id)
        case 1: menabp_show_shop(id)
        case 2: fnvip_show_vip_motd(id)
        case 3: Cmd_Rules(id)
        case 4: if(g_bSkinsMenuAvailable) skins_open_menu(id)
        case 7: ConfirmReset(id)
    }

    return PLUGIN_HANDLED
}

// ============================================================
// QUICK COMMAND HANDLERS
// ============================================================
// ============================================================
// PANEL DIAGNOSTIC
// ============================================================
// panel_probe <player> <kind> [authid]
//
// Answers "which url would this player get, and why not?" without sending
// anything: the kind's page path / bridge code / local file, Low Performance
// Mode state, and the exact url the identity would be sent to. An operator
// debugging "the panel page will not open" gets every input in one line, and a
// test can prove what fn_open_panel() would do for a SteamID the local server
// does not have.
public Cmd_PanelProbe(id, level, cid)
{
    // 2 arguments, not 3: read_argv(3) below is the OPTIONAL authid override and
    // cmd_access() with 3 made the documented `<player> <kind>` form unreachable -
    // the command only ever printed its own usage line.
    if(!cmd_access(id, level, cid, 2))
        return PLUGIN_HANDLED

    new szArg[40]
    read_argv(1, szArg, charsmax(szArg))
    // Not cmd_target(): from the CONSOLE (id 0) it fails for a name and for
    // `#id` on this AMXX build, and this probe's whole purpose is being usable
    // from the console (fn_core.inc:85 says the same). fn_resolve_target() takes
    // the strings a player types and includes bots, which is what a lab wants.
    new iTarget = fn_resolve_target(szArg)

    new szKindName[24]
    read_argv(2, szKindName, charsmax(szKindName))
    new iKind = fn_panel_kind_from_name(szKindName)
    if(iKind == FN_PANEL_NONE)
    {
        console_print(id, "[PANEL-PROBE] unknown kind '%s' (try winter, winter-tree, profile, vip, rules, motd, dashboard)", szKindName)
        return PLUGIN_HANDLED
    }

    new szAuth[40]
    read_argv(3, szAuth, charsmax(szAuth))
    if(!szAuth[0] && iTarget)
        get_user_authid(iTarget, szAuth, charsmax(szAuth))

    new szKind[24], szPage[16], szPath[64], szFile[96], szUrl[FNWEB_MAX_URL + 32]
    fn_panel_kind_name(iKind, szKind, charsmax(szKind))
    fn_panel_target(iKind, szPage, charsmax(szPage), szPath, charsmax(szPath), szFile, charsmax(szFile))
    new bool:bUrl = FNWeb_UrlForAuth(szAuth, iKind, szUrl, charsmax(szUrl))

    new szLpm[16]
    if(iTarget && fnpref_is_loaded(iTarget))
        formatex(szLpm, charsmax(szLpm), "%d", fnpref_get(iTarget, FNPREF_LOW_PERF))
    else
        copy(szLpm, charsmax(szLpm), "unloaded")

    new szTarget[96]
    if(szFile[0])
        formatex(szTarget, charsmax(szTarget), "file %s", szFile)
    else if(szPage[0])
        formatex(szTarget, charsmax(szTarget), "bridge /m/%s", szPage)
    else
        formatex(szTarget, charsmax(szTarget), "path %s", szPath)

    console_print(id, "[PANEL-PROBE] kind=%s target=%s auth=%s lpm=%s url=%s",
        szKind, szTarget, szAuth[0] ? szAuth : "-", szLpm,
        bUrl ? szUrl : (szFile[0] ? "(local file)" : "none"))
    log_amx("[PANEL-PROBE] target=%d kind=%s target_arg=%s auth=%s lpm=%s url=%s",
        iTarget, szKind, szTarget, szAuth[0] ? szAuth : "-", szLpm,
        bUrl ? szUrl : (szFile[0] ? "(local file)" : "none"))
    return PLUGIN_HANDLED
}

public Cmd_Rules(id)
{
    if(!is_user_connected(id)) return PLUGIN_HANDLED
    // One decision point for every MOTD in the stack (freenova_web.inc).
    if(fn_open_panel(id, FN_PANEL_RULES))
        return PLUGIN_HANDLED

    // Low performance mode: no HTML page, so the rules arrive as the same three
    // sections in chat. No panel configured: keep the local page, it needs no
    // browser and no network.
    if(fn_panel_denied() == FN_PANEL_DENY_LPM)
    {
        client_print_color(id, print_team_default, "%s Rules (low performance mode, in chat):", FN_CHAT_PREFIX)
        client_print_color(id, print_team_default, "%s 1. Respect every player - no insults, harassment or hate speech; no spam, no advertising other servers.", FN_CHAT_PREFIX)
        client_print_color(id, print_team_default, "%s 2. No cheating (wallhack, aimbot, no-recoil, scripts), no bug exploiting, no team killing or team flashing.", FN_CHAT_PREFIX)
        client_print_color(id, print_team_default, "%s 3. Admins decide edge cases - ask in chat or on Discord. The full page is on the panel.", FN_CHAT_PREFIX)
        return PLUGIN_HANDLED
    }

    show_motd(id, "addons/amxmodx/configs/freenova_rules.html", "FreeNova Rules")
    return PLUGIN_HANDLED
}

// ============================================================
// /dashboard - the Winterfest dashboard as a MOTD
// ============================================================
// The page is the owner's plate: panel asset dashboard.png, served by asset
// dashboard.html, one image at its own aspect ratio that the client letterboxes
// to its window. Nothing is drawn and nothing is loaded here - fn_open_panel()
// takes the decision it takes for every other panel, so Low Performance Mode
// and "no panel configured" behave exactly as they do for /rules and /panel.
public Cmd_Dashboard(id)
{
    if(!is_user_connected(id)) return PLUGIN_HANDLED

    if(fn_open_panel(id, FN_PANEL_DASHBOARD))
        return PLUGIN_HANDLED

    // A picture cannot be redrawn in chat, so the fallback says why it is not
    // on screen and where it lives instead.
    if(fn_panel_denied() == FN_PANEL_DENY_LPM)
    {
        client_print_color(id, print_team_default, "%s Dashboard: Low Performance Mode is on, so no page is opened. Say ^3/lpm^1 to turn it off.", FN_CHAT_PREFIX)
        return PLUGIN_HANDLED
    }

    new szBase[80]
    if(FNWeb_BaseUrl(szBase, charsmax(szBase)))
        client_print_color(id, print_team_default, "%s Dashboard: ^3%s/dashboard.html^1", FN_CHAT_PREFIX, szBase)
    else
        client_print_color(id, print_team_default, "%s Dashboard: no web panel is configured on this server.", FN_CHAT_PREFIX)
    return PLUGIN_HANDLED
}


// ============================================================
// STAT TRACKING
// ============================================================
// Round end logevent
// bomb_planted(id) and bomb_defused(id) are cstrike module forwards
// They fire with the correct player ID who planted/defused
public bomb_planted(id)
{
    if(is_user_connected(id))
        g_iPlayerStats[id][STAT_BOMB_PLANTS]++
}

public bomb_defused(id)
{
    if(is_user_connected(id))
        g_iPlayerStats[id][STAT_BOMB_DEFUSES]++
}

public LogEvent_RoundEnd()
{
    check_round_end_stats()
}

public client_death(killer, victim, weapon, hitplace, TK)
{
    #pragma unused killer, weapon, hitplace, TK
    // Deaths still count for suicides / world (the combat bus only fires
    // on ranked enemy kills). Kills/HS now come from fn_on_player_kill.
    if(!is_user_connected(victim))
        return
    g_iPlayerStats[victim][STAT_DEATHS]++
    g_iRoundKills[victim] = 0
}

public fn_on_player_kill(killer, victim, weapon, headshot, tk)
{
    #pragma unused victim, weapon, tk
    if(!is_user_connected(killer) || is_user_bot(killer))
        return
    g_iPlayerStats[killer][STAT_KILLS]++
    g_iRoundKills[killer]++
    if(headshot)
        g_iPlayerStats[killer][STAT_HEADSHOTS]++
}


public check_round_end_stats()
{
    // MVP: the player with the most kills THIS round. Tracking per-round
    // kills in a parallel counter avoids the old bug where the session kill
    // leader was crowned MVP every single round.
    new players[32], num
    get_players(players, num, "ch")

    new bestKills = 0
    new bestId = 0

    for(new i = 0; i < num; i++)
    {
        new pid = players[i]
        new kills = g_iRoundKills[pid]
        if(kills > bestKills)
        {
            bestKills = kills
            bestId = pid
        }
    }

    if(bestId > 0 && bestKills > 0)
    {
        g_iPlayerStats[bestId][STAT_MVP]++
    }
}

// Round-win tracking: SendAudio fires once per round with the winning team's
// sound (same pattern CRX/BattlePass use); alive humans on that team get a win.
public Event_RoundWinAudio()
{
    new szAudio[24]
    read_data(2, szAudio, charsmax(szAudio))

    new CsTeams:winner
    if(contain(szAudio, "%!MRAD_terwin") >= 0)
        winner = CS_TEAM_T
    else if(contain(szAudio, "%!MRAD_ctwin") >= 0)
        winner = CS_TEAM_CT
    else
        return

    new players[32], num
    get_players(players, num, "ch")

    for(new i = 0; i < num; i++)
    {
        new pid = players[i]
        if(!is_user_alive(pid) || cs_get_user_team(pid) != winner)
            continue

        g_iPlayerStats[pid][winner == CS_TEAM_T ? STAT_WIN_T : STAT_WIN_CT]++
    }
}

// ============================================================
// STATS LOADING
// ============================================================
LoadPlayerStats(id)
{
    new key[64], szValue[256]
    new szName[32]
    get_user_authid(id, szName, charsmax(szName))

    // Refuse pooled identities: pending/unassigned players would otherwise
    // all load & save into one shared vault row (cross-player stat mixing).
    // The deferred re-check in Task_LateLoadStats covers slow Steam auth.
    if(!szName[0] || equal(szName, "STEAM_ID_PENDING") || equal(szName, "STEAM_ID_LAN")
        || equal(szName, "BOT") || equal(szName, "HLTV"))
        return

    if(g_VaultStats == INVALID_HANDLE)
        return

    for(new i = 0; szName[i]; i++)
    {
        if(szName[i] == ':') szName[i] = '_'
    }

    formatex(key, charsmax(key), "stats#%s", szName)

    new iTimeStamp = 0
    if(nvault_lookup(g_VaultStats, key, szValue, charsmax(szValue), iTimeStamp))
    {
        new szPart[16], szLeft[256]
        copy(szLeft, charsmax(szLeft), szValue)

        strtok(szLeft, szPart, charsmax(szPart), szLeft, charsmax(szLeft), ' ')
        g_iPlayerStats[id][STAT_KILLS] = str_to_num(szPart)

        strtok(szLeft, szPart, charsmax(szPart), szLeft, charsmax(szLeft), ' ')
        g_iPlayerStats[id][STAT_DEATHS] = str_to_num(szPart)

        strtok(szLeft, szPart, charsmax(szPart), szLeft, charsmax(szLeft), ' ')
        g_iPlayerStats[id][STAT_HEADSHOTS] = str_to_num(szPart)

        strtok(szLeft, szPart, charsmax(szPart), szLeft, charsmax(szLeft), ' ')
        g_iPlayerStats[id][STAT_BOMB_PLANTS] = str_to_num(szPart)

        strtok(szLeft, szPart, charsmax(szPart), szLeft, charsmax(szLeft), ' ')
        g_iPlayerStats[id][STAT_BOMB_DEFUSES] = str_to_num(szPart)

        strtok(szLeft, szPart, charsmax(szPart), szLeft, charsmax(szLeft), ' ')
        g_iPlayerStats[id][STAT_WIN_CT] = str_to_num(szPart)

        strtok(szLeft, szPart, charsmax(szPart), szLeft, charsmax(szLeft), ' ')
        g_iPlayerStats[id][STAT_WIN_T] = str_to_num(szPart)

        strtok(szLeft, szPart, charsmax(szPart), szLeft, charsmax(szLeft), ' ')
        g_iPlayerStats[id][STAT_MVP] = str_to_num(szPart)

        g_iPlayerStats[id][STAT_PLAYTIME] = str_to_num(szLeft)
    }

    // Mark loaded only after a successful vault lookup (hit or confirmed empty).
    g_bStatsLoaded[id] = true
}

// ============================================================
// STATS PERSISTENCE
// ============================================================
SavePlayerStats(id)
{
    if(!g_bStatsLoaded[id])
        return

    new key[64], value[256]
    new szName[32]
    get_user_authid(id, szName, charsmax(szName))

    // Never write pooled identities (same key-collision risk as loading)
    if(!szName[0] || equal(szName, "STEAM_ID_PENDING") || equal(szName, "STEAM_ID_LAN")
        || equal(szName, "BOT") || equal(szName, "HLTV"))
        return

    if(g_VaultStats == INVALID_HANDLE)
        return

    for(new i = 0; szName[i]; i++)
    {
        if(szName[i] == ':') szName[i] = '_'
    }

    formatex(key, charsmax(key), "stats#%s", szName)
    formatex(value, charsmax(value), "%d %d %d %d %d %d %d %d %d",
        g_iPlayerStats[id][STAT_KILLS],
        g_iPlayerStats[id][STAT_DEATHS],
        g_iPlayerStats[id][STAT_HEADSHOTS],
        g_iPlayerStats[id][STAT_BOMB_PLANTS],
        g_iPlayerStats[id][STAT_BOMB_DEFUSES],
        g_iPlayerStats[id][STAT_WIN_CT],
        g_iPlayerStats[id][STAT_WIN_T],
        g_iPlayerStats[id][STAT_MVP],
        g_iPlayerStats[id][STAT_PLAYTIME])

    nvault_set(g_VaultStats, key, value)
}

// ============================================================
// ============================================================
// UTILITY
// ============================================================
stock client_printcolor(id, const fmt[], any:...)
{
    new msg[192]
    vformat(msg, charsmax(msg), fmt, 3)
    replace_all(msg, charsmax(msg), "!g", "^4")
    replace_all(msg, charsmax(msg), "!t", "^3")
    replace_all(msg, charsmax(msg), "!n", "^1")
    replace_all(msg, charsmax(msg), "!Team", "^3")
    // REVIEW.md 5.5: the caller's text was passed as the FORMAT. A player
    // named "%s" then made client_print_color re-format garbage cells, so
    // pass it as an argument instead.
    client_print_color(id, print_team_default, "%s", msg)
}

public plugin_end()
{
    if(g_bEventActive[EVENT_LOW_GRAVITY])
        server_cmd("sv_gravity %d", g_iSavedGravity > 0 ? g_iSavedGravity : 800)
    new players[32], num
    get_players(players, num, "ch")
    for(new i = 0; i < num; i++)
    {
        // Accumulate playtime for anyone still connected, then flush both
        // stores - previously only VIP flags were saved and a map change
        // lost the whole session of stats.
        new pid = players[i]
        if(g_bStatsLoaded[pid])
        {
            new Float:fPlayTime = get_gametime() - g_fConnectTime[pid]
            g_iPlayerStats[pid][STAT_PLAYTIME] += floatround(fPlayTime / 60.0)
            SavePlayerStats(pid)
        }
        SaveVipFlags(pid)
    }

    if(g_VaultStats != INVALID_HANDLE)
    {
        nvault_close(g_VaultStats)
        g_VaultStats = INVALID_HANDLE
    }
    if(g_VaultVipAdmin != INVALID_HANDLE)
    {
        nvault_close(g_VaultVipAdmin)
        g_VaultVipAdmin = INVALID_HANDLE
    }
}
