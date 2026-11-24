/*
    =============================================================================
     FreeNova — ZG-7 "ZGUN" · VIP custom sniper
    =============================================================================
     Deliverable : source only (this file + include\freenova_zgun.inc)

     Target      : Counter-Strike 1.6 · AMX Mod X 1.10.0.5478 · ReHLDS + ReAPI

     What it is  : a VIP-exclusive custom sniper built on the custom "zgun"
                   view model (models\VENOMIX\v_awpz.mdl). The model's six
                   animation sequences were parsed and match the stock CS 1.6
                   AWP sequence table exactly, so the engine drives every
                   animation natively — see include\freenova_zgun.inc for the
                   full analysis and the constants derived from it.

     Access      : VIP only.
                     primary   AMX Mod X flag letter "t" (cvar-changeable)
                     optional  FreeNova VIP tier (freenova_vip natives)
                   Grant it with  /zgun  (chat),  /zguns  (menu),
                   or an admin with  amx_zgun <target>.

     Commands    : say /zgun              take the ZG-7 (or open the menu)
                   say /zguns             VIP weapon menu
                   say /zguninfo          weapon spec sheet (MOTD)
                   amx_zgun <target>      force give          (ADMIN_BAN)
                   amx_zgun_take <target> remove              (ADMIN_BAN)
                   amx_zgun_info          dump live state     (ADMIN_KICK)

     Notes       : two AMX Mod X constraints shape this implementation and are
                   documented rather than hidden —
                   1) AMX Mod X 1.10 removed the classic custom-weapon API
                      (cs_register_weapon / register_weapon / send_anim /
                      send_user_weapon_anim / cs_get_user_ammo), so the gun
                      drives the stock sniper class instead of a bespoke
                      weapon entity.
                   2) this server applies custom view models through the
                      ReHLDS string field pev_viewmodel2 / pev_weaponmodel2
                      (the same route weapon_models.sma already uses in
                      production), not through pev_viewmodel.
    =============================================================================
*/

#include <amxmodx>
#include <amxmisc>
#include <cstrike>
#include <fun>
#include <fakemeta>
#include <hamsandwich>
#include <newmenus>
#include <freenova_zgun>
#include <fn_common>

// FreeNova VIP integration is optional. AMX Mod X 1.10 validates every native a
// plugin uses at load time, so simply calling fnvip_* behind a runtime check
// still made the plugin fail to load on any server without freenova_vip.amxx.
// It is therefore compiled in only when the header is actually available.
#if !defined ZGUN_WITH_FNVIP
    #tryinclude <freenova_vip>
    #if defined _freenova_vip_included
        #define ZGUN_WITH_FNVIP 1
    #else
        #define ZGUN_WITH_FNVIP 0
    #endif
#endif

// The header was already pulled in by the #tryinclude above when it exists;
// including it twice hits its #endinput guard and truncates this file.
#if !ZGUN_WITH_FNVIP
    #define FNVIP_NONE 0
    #define FNVIP_VIP  1
#endif

// ------------------------------------------------------------------ state --
new bool:g_bHasZgun[MAX_PLAYERS + 1];
new bool:g_bModelSet[MAX_PLAYERS + 1];

new g_pEnabled;
new g_pFlag;
new g_pAllowVipTier;
new g_pMinTier;
new g_pMenuOnCommand;
new g_pDropOnDeath;
new g_pDebug;

// String arrays are declared without the char: tag on this compiler.
new g_szFlag[8];
new g_szCfgPath[128];

// =================================================================== init ==

public plugin_init()
{
    fn_boot_banner("zgun", 22);

    register_plugin("FreeNova ZG-7 Zgun", "1.0.0", "FreeNova");

    g_pEnabled       = register_cvar(ZGUN_CVAR_ENABLED, "1");
    g_pFlag          = register_cvar(ZGUN_CVAR_FLAG, ZGUN_DEFAULT_FLAG);
    g_pAllowVipTier  = register_cvar(ZGUN_CVAR_VIPTIER, "1");
    g_pMinTier       = register_cvar(ZGUN_CVAR_MINTIER, ZGUN_MINTIER_STR);
    g_pMenuOnCommand = register_cvar(ZGUN_CVAR_MENU, "0");
    g_pDropOnDeath   = register_cvar(ZGUN_CVAR_DROP, "1");
    g_pDebug         = register_cvar(ZGUN_CVAR_DEBUG, "0");

    register_clcmd("say /zgun", "Cmd_Zgun");
    register_clcmd("say_team /zgun", "Cmd_Zgun");
    register_clcmd("say /zguns", "Cmd_Menu");
    register_clcmd("say_team /zguns", "Cmd_Menu");
    register_clcmd("say /zguninfo", "Cmd_SpecSheet");
    register_clcmd("say_team /zguninfo", "Cmd_SpecSheet");

    register_concmd("amx_zgun", "Cmd_Give", ADMIN_BAN, "amx_zgun <target> - give the ZG-7 (VIP gate applies)");
    register_concmd("amx_zgun_force", "Cmd_GiveForce", ADMIN_BAN, "amx_zgun_force <target> - give the ZG-7 ignoring the VIP gate");
    register_concmd("amx_zgun_take", "Cmd_Take", ADMIN_BAN, "amx_zgun_take <target> - remove the ZG-7");
    register_concmd("amx_zgun_info", "Cmd_Info", ADMIN_KICK, "amx_zgun_info - dump ZG-7 state");

    register_event("HLTV", "event_new_round", "a", "1=0", "2=0");
    // HLTV fires at round RESTART, not round end - hooking it here made the
    // drop/reset logic run at the start of the next round (in freezetime,
    // right after event_new_round refilled the gun). Round_End is the engine
    // log line emitted when a round actually finishes; same hook the rest of
    // the FreeNova plugins already use (freenova_panel, battlepass_core,
    // freenova_progression, rsu_core).
    register_logevent("event_round_end", 2, "1=Round_End");
    register_event("TextMsg", "event_buy_zone", "a", "2=#Cmp_Buy_Zone");
    register_event("TextMsg", "event_buy_zone_t", "a", "2=#TER_Buy_Zone");

    // Ham handler names must not collide with the enum Ham constants in
    // ham_const.inc, so they carry the _Pre/_Post suffix this server uses.
    RegisterHam(Ham_TakeDamage, "player", "Zgun_TakeDamage_Pre")
    RegisterHam(Ham_Spawn, "player", "Zgun_Spawn_Post", 1)
}

public plugin_precache()
{
    precache_model(ZGUN_VIEW_MODEL);
    precache_model(ZGUN_PLAYER_MODEL);
    precache_model(ZGUN_WORLD_MODEL);

    // The models are the whole point of the plugin: fail loudly and clearly
    // rather than letting CS silently fall back to the stock AWP view model.
    new szLog[352];
    if (!file_exists(ZGUN_VIEW_MODEL))
    {
        formatex(szLog, charsmax(szLog),
            "FATAL: %s is missing. Copy v_awpz.mdl / p_awpz.mdl / w_awpz.mdl to cstrike%s",
            ZGUN_VIEW_MODEL, ZGUN_VIEW_MODEL);
        ZLog(szLog);
    }
    else
    {
        formatex(szLog, charsmax(szLog),
            "view model %s loaded, %d sequences (idle=%d fire=%d/%d/%d reload=%d draw=%d)",
            ZGUN_VIEW_MODEL, ZGUN_SEQ_COUNT,
            ZGUN_SEQ_IDLE, ZGUN_SEQ_SHOOT1, ZGUN_SEQ_SHOOT2, ZGUN_SEQ_SHOOT3,
            ZGUN_SEQ_RELOAD, ZGUN_SEQ_DRAW);
        ZLog(szLog);
    }
}

public plugin_cfg()
{
    // REVIEW.md 5.5: this used to delete and rewrite its own config file on
    // every map start, so an operator edit lasted until the next changelevel
    // (and the whole file was rewritten for nothing each map). Write the
    // defaults once, when the file is absent, then execute it - which the old
    // code never did, so the file was documentation that changed nothing.
    new szCfgDir[96];
    get_configsdir(szCfgDir, charsmax(szCfgDir));
    formatex(g_szCfgPath, charsmax(g_szCfgPath), "%s/%s", szCfgDir, CONFIG_NAME);

    if (!file_exists(g_szCfgPath))
        WriteDefaultZgunConfig();

    server_cmd("exec %s", g_szCfgPath);
    server_exec();

    // The file is authoritative for the flag cvar, so read it back now.
    RefreshFlagString();
}

// Writes the documented defaults. Only called when the file does not exist.
WriteDefaultZgunConfig()
{
    new szSpecs[128];
    formatex(szSpecs, charsmax(szSpecs),
        "// clip 10, bolt cycle %.1f s, reload %.1f s, deploy %.1f s",
        ZGUN_BOLT_TIME, ZGUN_RELOAD_TIME, ZGUN_DRAW_TIME);

    write_file(g_szCfgPath, "// FreeNova ZG-7 Zgun - VIP custom sniper");
    write_file(g_szCfgPath, "//");
    write_file(g_szCfgPath, "// VIP gate is the AMX Mod X flag letter below. Grant it with:");
    write_file(g_szCfgPath, "//    amx_addadmin STEAM_0:0:12345678 t");
    write_file(g_szCfgPath, "// or in game:   set_flags PlayerName t");
    write_file(g_szCfgPath, "// Leave it empty to require a FreeNova VIP tier instead.");
    write_file(g_szCfgPath, "freenova_zgun_flag t");
    write_file(g_szCfgPath, "");
    write_file(g_szCfgPath, "// Also accept an active FreeNova VIP tier as an alternative path");
    write_file(g_szCfgPath, "freenova_zgun_allow_vip_tier 1");
    write_file(g_szCfgPath, "");
    write_file(g_szCfgPath, "// Minimum tier for that path (1 = VIP, 2 = VIP+, 3 = Elite)");
    write_file(g_szCfgPath, "freenova_zgun_min_tier 1");
    write_file(g_szCfgPath, "");
    write_file(g_szCfgPath, "// 0 = /zgun hands over the gun, 1 = /zgun opens the menu");
    write_file(g_szCfgPath, "freenova_zgun_menu_on_command 0");
    write_file(g_szCfgPath, "");
    write_file(g_szCfgPath, "// 1 = the gun is dropped when the round ends instead of kept");
    write_file(g_szCfgPath, "freenova_zgun_drop_on_death 1");
    write_file(g_szCfgPath, "");
    write_file(g_szCfgPath, "// Specs: 260 damage scoped, x0.45 unscoped, 30 reserve rounds,");
    write_file(g_szCfgPath, szSpecs);
    write_file(g_szCfgPath, "");
    write_file(g_szCfgPath, "// Extra staff logging");
    write_file(g_szCfgPath, "freenova_zgun_debug 0");
}

// ================================================================== VIP gate ==

// The FreeNova VIP core (freenova_vip.amxx) can be paused or unloaded by an
// admin at any time; calling its natives then raises "dynanative into a paused
// plugin" runtime errors. Gate every call behind this check — same pattern as
// weaponmenu.sma's MenabpUsable().
stock bool:FnVipUsable()
{
#if !ZGUN_WITH_FNVIP
    return false;          // compiled without the FreeNova VIP header
#else
    if (!g_pAllowVipTier) return false;
    if (LibraryExists("freenova_vip", LibType_Library)) return true;

    new iPlugins = get_pluginsnum();
    new szFile[64], szTitle[32], szVersion[16], szAuthor[32], szStatus[16];
    for (new i = 0; i < iPlugins; i++)
    {
        get_plugin(i, szFile, charsmax(szFile), szTitle, charsmax(szTitle),
                   szVersion, charsmax(szVersion), szAuthor, charsmax(szAuthor),
                   szStatus, charsmax(szStatus));
        if (equali(szFile, "freenova_vip.amxx"))
            return equali(szStatus, "running") ? true : false;
    }
    return false;
#endif
}

stock bool:PlayerHasFlag(id)
{
    // Read the cvar here, not once at hand-over time. The gate runs BEFORE
    // GrantZgun()'s RefreshFlagString(), so with only that one call g_szFlag
    // was empty on every eligibility test and a flag-only VIP was denied for
    // ever (only the VIP-tier path could get in). REVIEW.md 5.5.
    RefreshFlagString();
    if (!g_szFlag[0]) return false;
    return has_flag(id, g_szFlag) ? true : false;
}

stock bool:PlayerHasVipTier(id)
{
#if ZGUN_WITH_FNVIP
    if (!FnVipUsable()) return false;
    return fnvip_has_tier(id, g_pMinTier);
#else
    return false;
#endif
}

stock bool:PlayerIsEligible(id)
{
    if (!is_user_connected(id)) return false;
    if (PlayerHasFlag(id)) return true;
    if (PlayerHasVipTier(id)) return true;
    return false;
}

stock PrintDenied(id)
{
    new szPath[64];
    if (PlayerHasFlag(id))
        formatex(szPath, charsmax(szPath), "VIP tier");
    else if (FnVipUsable() && g_szFlag[0])
        formatex(szPath, charsmax(szPath), "flag ^"%s^" or a VIP tier", g_szFlag);
    else
        formatex(szPath, charsmax(szPath), "a VIP tier");

    client_print(id, print_chat, "[ZG-7] The Zgun is reserved for VIP. You need %s.", szPath);
    client_print(id, print_center, "ZG-7 Zgun  -  VIP only");

    // Audit trail for staff; gated so a spam attempt cannot flood the log.
    if (get_pcvar_num(g_pDebug))
    {
        new szLog[352];
        formatex(szLog, charsmax(szLog), "denied %s (flag=%d tier_path=%d)", PlayerName(id), PlayerHasFlag(id));
        ZLog(szLog);
    }
}

// ================================================================ inventory ==

stock bool:HasZgunInInventory(id)
{
    new iWeapons[32], iNum;
    get_user_weapons(id, iWeapons, iNum);

    for (new i = 0; i < iNum; i++)
    {
        if (iWeapons[i] == ZGUN_BASE_WEAPON)
            return true;
    }
    return false;
}

// Drop every primary the player carries so the ZG-7 always lands in a clean
// slot. Same approach weaponmenu.sma already uses on this server.
stock StripPrimaries(id)
{
    new iWeapons[32], iNum;
    get_user_weapons(id, iWeapons, iNum);

    for (new i = 0; i < iNum; i++)
    {
        new iWid = iWeapons[i];
        if (iWid == CSW_KNIFE || iWid == CSW_C4 || iWid == CSW_HEGRENADE ||
            iWid == CSW_FLASHBANG || iWid == CSW_SMOKEGRENADE)
            continue;

        // primary slot only (1..CSW_P90 plus M249 and the G3SG1)
        if ((1 <= iWid <= CSW_P90) || iWid == CSW_M249 || iWid == CSW_G3SG1)
        {
            new szName[32];
            get_weaponname(iWid, szName, charsmax(szName));
            engclient_cmd(id, "drop", szName);
        }
    }
}

stock RefreshFlagString()
{
    get_pcvar_string(g_pFlag, g_szFlag, charsmax(g_szFlag));
}

// Hand the weapon over. bEnforceGate is false only for the explicit
// amx_zgun_force award path, so a stray "amx_zgun <target>" can never hand
// VIP-only gear to a player who does not qualify.
stock bool:GrantZgun(id, bool:bEnforceGate)
{
    if (!get_pcvar_num(g_pEnabled))
    {
        client_print(id, print_chat, "[ZG-7] The Zgun is currently disabled.");
        return false;
    }
    if (!is_user_connected(id)) return false;
    if (!is_user_alive(id))
    {
        client_print(id, print_chat, "[ZG-7] You must be alive to take the Zgun.");
        return false;
    }
    if (bEnforceGate && !PlayerIsEligible(id))
    {
        PrintDenied(id);
        return false;
    }

    RefreshFlagString();

    StripPrimaries(id);
    give_item(id, "weapon_awp");

    // Reserve ammunition. The clip is filled by the engine on deploy.
    cs_set_user_bpammo(id, ZGUN_BASE_WEAPON, ZGUN_MAX_AMMO);

    g_bHasZgun[id] = true;
    ApplyModel(id);
    set_task(ZGUN_REFRESH_TIME, "Task_Refresh", id + ZGUN_TASK_REFRESH);

    client_print(id, print_chat, "[ZG-7] You equipped the %s.", ZGUN_DISPLAY_NAME);
    // lint:allow format-var - ZGUN_DISPLAY_NAME is a string literal define
    // (see the #define), so it cannot carry a player-controlled format.
    client_print(id, print_center, ZGUN_DISPLAY_NAME);

    new iTier = FnVipUsable() ? fnvip_get_tier(id) : -1;

    new szLog[352];
    formatex(szLog, charsmax(szLog), "gave ZG-7 to %s (flag=%d tier=%d gate=%d)",
        PlayerName(id), PlayerHasFlag(id), iTier, bEnforceGate ? 1 : 0);
    ZLog(szLog);
    return true;
}

stock bool:GiveZgun(id)
{
    return GrantZgun(id, true);
}

stock ResetZgun(id)
{
    g_bHasZgun[id] = false;
    g_bModelSet[id] = false;
    remove_task(id + ZGUN_TASK_REFRESH);

    if (is_user_connected(id))
    {
        // Empty the custom model strings so the engine falls back to the
        // weapon's own view model again (same reset weapon_models.sma uses).
        set_pev(id, pev_viewmodel2, "");
        set_pev(id, pev_weaponmodel2, "");
    }
}

// ================================================================== models ==

// ReHLDS reads the player's first/third person weapon models from the second
// string field. Keep re-asserting them because the engine resets these on every
// weapon switch, and weapon_models.sma (VIP weapon skins) may overwrite them.
public Task_Refresh(taskid)
{
    new id = taskid - ZGUN_TASK_REFRESH;
    if (!(1 <= id <= MaxClients)) return;
    if (!is_user_connected(id)) return;

    if (g_bHasZgun[id])
    {
        if (!HasZgunInInventory(id))
        {
            new szLog[352];
            formatex(szLog, charsmax(szLog), "%s lost the ZG-7 (dropped or traded), model released", PlayerName(id));
            ZLog(szLog);
            ResetZgun(id);
            return;
        }

        if (cs_get_user_weapon(id) == ZGUN_BASE_WEAPON)
            ApplyModel(id);
    }

    set_task(ZGUN_REFRESH_TIME, "Task_Refresh", id + ZGUN_TASK_REFRESH);
}

stock ApplyModel(id)
{
    if (!is_user_connected(id)) return;

    set_pev(id, pev_viewmodel2, ZGUN_VIEW_MODEL);
    set_pev(id, pev_weaponmodel2, ZGUN_PLAYER_MODEL);

    if (!g_bModelSet[id])
    {
        g_bModelSet[id] = true;
        new szLog[352];
        formatex(szLog, charsmax(szLog), "%s view model -> %s", PlayerName(id), ZGUN_VIEW_MODEL);
        ZLog(szLog);
    }
}

// =================================================================== hooks ==

public client_putinserver(id)
{
    // Clear any stale loop from a previous occupant BEFORE anything can
    // re-arm it (slot reuse would otherwise inherit the refresh tick).
    ResetZgun(id);
    remove_task(id + ZGUN_TASK_REFRESH + 1);
    g_bHasZgun[id] = false;
    g_bModelSet[id] = false;
}

public client_disconnected(id, bool:drop, message[], maxlen)
{
    ResetZgun(id);
    remove_task(id + ZGUN_TASK_REFRESH + 1);
}

// Player names are needed in log lines; AMXX has no name() stock on 1.10 and
// a shared buffer keeps the call sites short.
new g_szName[64];

stock PlayerName(id)
{
    get_user_name(id, g_szName, charsmax(g_szName));
    return g_szName;
}

public Zgun_Spawn_Post(id)
{
    if (!(1 <= id <= MaxClients)) return HAM_IGNORED;
    g_bModelSet[id] = false;

    if (g_bHasZgun[id] && HasZgunInInventory(id))
    {
        ApplyModel(id);
        set_task(ZGUN_REFRESH_TIME, "Task_Refresh", id + ZGUN_TASK_REFRESH);
    }
    return HAM_IGNORED;
}

// Custom damage profile:
//   scoped   -> flat 260 so any hit is lethal (the VIP reward)
//   unscoped -> 45% of the sniper's own damage, so hip-firing is punished
// Only touches shots that come from a tracked ZG-7 holder.
public Zgun_TakeDamage_Pre(victim, inflictor, attacker, Float:damage, damagebits)
{
    if (!g_bHasZgun[attacker]) return;
    if (victim == attacker || attacker == 0) return;
    if (!is_user_connected(attacker) || !is_user_alive(attacker)) return;
    if (cs_get_user_weapon(attacker) != ZGUN_BASE_WEAPON) return;

    new iZoom = cs_get_user_zoom(attacker);

    if (iZoom == ZGUN_ZOOM_FIRST || iZoom == ZGUN_ZOOM_SECOND)
    {
        new Float:fScoped = Float:ZGUN_DAMAGE_SCOPED;
        damage = fScoped;
        if (get_pcvar_num(g_pDebug))
        {
            new szLog[352];
            formatex(szLog, charsmax(szLog), "scoped hit from %s: damage forced to %d",
                PlayerName(attacker), ZGUN_DAMAGE_SCOPED);
            ZLog(szLog);
        }
    }
    else
    {
        new Float:fMult = ZGUN_UNSCOPED_MULT;
        damage *= fMult;
    }
}

// ================================================================== events ==

public event_new_round()
{
    for (new id = 1; id <= MaxClients; id++)
    {
        g_bModelSet[id] = false;
        if (g_bHasZgun[id] && HasZgunInInventory(id))
        {
            // Top the reserve back up so a fresh round starts full.
            cs_set_user_bpammo(id, ZGUN_BASE_WEAPON, ZGUN_REFILL_AMMO);
            ApplyModel(id);
        }
    }
}

public event_round_end()
{
    for (new id = 1; id <= MaxClients; id++)
    {
        if (!g_bHasZgun[id]) continue;

        if (g_pDropOnDeath && is_user_connected(id) && is_user_alive(id))
            DropZgun(id);
        else
            ResetZgun(id);
    }
}

public event_buy_zone(id)
{
    if (g_bHasZgun[id] && is_user_alive(id))
    {
        if (cs_get_user_bpammo(id, ZGUN_BASE_WEAPON) < ZGUN_REFILL_AMMO)
            cs_set_user_bpammo(id, ZGUN_BASE_WEAPON, ZGUN_REFILL_AMMO);
    }
}

public event_buy_zone_t(id)
{
    event_buy_zone(id);
}

// -------------------------------------------------------------- drop helper --

// The ZG-7 is a VIP weapon, so it is not left lying on the floor: switch to the
// knife and drop it far enough away that the round reset handles it.
stock DropZgun(id)
{
    if (!is_user_connected(id) || !is_user_alive(id)) return;
    if (!HasZgunInInventory(id)) { ResetZgun(id); return; }

    engclient_cmd(id, "weapon_knife");
    set_task(0.3, "Task_Drop", id + ZGUN_TASK_REFRESH + 1);
}

public Task_Drop(taskid)
{
    new id = taskid - ZGUN_TASK_REFRESH - 1;
    if (!(1 <= id <= MaxClients)) return;
    if (!is_user_connected(id) || !is_user_alive(id)) return;

    if (HasZgunInInventory(id))
        engclient_cmd(id, "drop", "weapon_awp");

    ResetZgun(id);
}

// ================================================================ commands ==

public Cmd_Zgun(id)
{
    if (!is_user_connected(id)) return PLUGIN_HANDLED;

    if (get_pcvar_num(g_pMenuOnCommand))
    {
        ShowMenu(id);
        return PLUGIN_HANDLED;
    }

    if (!GiveZgun(id))
        ShowMenu(id);        // denied players still get the explanation
    return PLUGIN_HANDLED;
}

public Cmd_Menu(id)
{
    if (!is_user_connected(id)) return PLUGIN_HANDLED;
    ShowMenu(id);
    return PLUGIN_HANDLED;
}

// amx_zgun - respects the VIP gate, so a VIP weapon cannot be mis-awarded.
public Cmd_Give(id, level, cid)
{
    new iAccess = cmd_access(id, level, cid, 1);

    // cmd_target() takes the target PATTERN as its 2nd argument - it does NOT
    // read the console arguments itself. Without read_argv(1) the pattern was
    // always an empty string. Resolve it exactly once (the double call before
    // resolved the same empty pattern twice, and charsmax() was being passed
    // as the FLAGS slot, not as a length).
    new szTarget[32];
    read_argv(1, szTarget, charsmax(szTarget));

    new iVictim = szTarget[0] ? cmd_target(id, szTarget, CMDTARGET_OBEY_IMMUNITY | CMDTARGET_ALLOW_SELF) : 0;

    if (get_pcvar_num(g_pDebug))
    {
        new szTrace[352];
        new szA0[32], szA1[32], szArgs[96];
        read_argv(0, szA0, charsmax(szA0));
        read_argv(1, szA1, charsmax(szA1));
        read_args(szArgs, charsmax(szArgs));
        formatex(szTrace, charsmax(szTrace),
            "amx_zgun from=%d access=%d raw=^"%s^" resolved=%d argv0=^"%s^" argv1=^"%s^" args=^"%s^"",
            id, iAccess, szTarget, iVictim, szA0, szA1, szArgs);
        ZLog(szTrace);
    }

    if (!iAccess) return PLUGIN_HANDLED;

    if (!szTarget[0])
    {
        client_print(id, print_chat, "Usage: amx_zgun <#userid|name|nick|STEAM_ID>");
        return PLUGIN_HANDLED;
    }

    if (!iVictim)
    {
        client_print(id, print_chat, "[ZG-7] No such target.");
        return PLUGIN_HANDLED;
    }

    if (GrantZgun(iVictim, true))
    {
        client_print(id, print_chat, "[ZG-7] Gave the Zgun to %s.", szTarget);
    }
    else
    {
        new szLog[352];
        formatex(szLog, charsmax(szLog),
            "amx_zgun REFUSED for %s (eligible=%d flag=%d tier=%d)",
            PlayerName(iVictim), PlayerIsEligible(iVictim) ? 1 : 0,
            PlayerHasFlag(iVictim) ? 1 : 0, PlayerHasVipTier(iVictim) ? 1 : 0);
        ZLog(szLog);
        client_print(id, print_chat, "[ZG-7] %s does not qualify for the Zgun.", szTarget);
    }

    return PLUGIN_HANDLED;
}

// amx_zgun_force - explicit bypass for award scripts and testing.
public Cmd_GiveForce(id, level, cid)
{
    if (!cmd_access(id, level, cid, 1)) return PLUGIN_HANDLED;

    new szTarget[32];
    read_argv(1, szTarget, charsmax(szTarget));

    if (!szTarget[0])
    {
        client_print(id, print_chat, "Usage: amx_zgun_force <#userid|name|nick|STEAM_ID>");
        return PLUGIN_HANDLED;
    }

    new iVictim = cmd_target(id, szTarget, CMDTARGET_OBEY_IMMUNITY | CMDTARGET_ALLOW_SELF);
    if (!iVictim)
    {
        client_print(id, print_chat, "[ZG-7] No such target.");
        return PLUGIN_HANDLED;
    }

    if (GrantZgun(iVictim, false))
        client_print(id, print_chat, "[ZG-7] Force-gave the Zgun to %s.", szTarget);

    return PLUGIN_HANDLED;
}

public Cmd_Take(id, level, cid)
{
    if (!cmd_access(id, level, cid, 1)) return PLUGIN_HANDLED;

    new szTarget[32];
    read_argv(1, szTarget, charsmax(szTarget));
    new iVictim = szTarget[0] ? cmd_target(id, szTarget, CMDTARGET_OBEY_IMMUNITY | CMDTARGET_ALLOW_SELF) : 0;

    if (!iVictim)
    {
        client_print(id, print_chat, "Usage: amx_zgun_take <#userid|name|nick|STEAM_ID>");
        return PLUGIN_HANDLED;
    }

    DropZgun(iVictim);
    client_print(id, print_chat, "[ZG-7] Removed the Zgun from %s.", szTarget);
    return PLUGIN_HANDLED;
}

public Cmd_Info(id, level, cid)
{
    new iAccess = cmd_access(id, level, cid, 1);

    if (get_pcvar_num(g_pDebug))
    {
        new szA0[32], szA1[32], szA2[32], szArgs[96], szProbe[352];
        read_argv(0, szA0, charsmax(szA0));
        read_argv(1, szA1, charsmax(szA1));
        read_argv(2, szA2, charsmax(szA2));
        read_args(szArgs, charsmax(szArgs));
        formatex(szProbe, charsmax(szProbe),
            "info from=%d access=%d argv0=^"%s^" argv1=^"%s^" argv2=^"%s^" args=^"%s^"",
            id, iAccess, szA0, szA1, szA2, szArgs);
        ZLog(szProbe);
    }

    if (!iAccess) return PLUGIN_HANDLED;

    RefreshFlagString();

    new szLine[192];
    new szEnabled[8], szTier[8], szMinTier[8], szDamage[16];
    get_pcvar_string(g_pEnabled, szEnabled, charsmax(szEnabled));
    get_pcvar_string(g_pAllowVipTier, szTier, charsmax(szTier));
    get_pcvar_string(g_pMinTier, szMinTier, charsmax(szMinTier));
    formatex(szDamage, charsmax(szDamage), "%d", ZGUN_DAMAGE_SCOPED);

    formatex(szLine, charsmax(szLine),
        "[ZG-7] enabled=%s flag=^"%s^" vip_tier=%s min_tier=%s model=%s",
        szEnabled, g_szFlag[0] ? g_szFlag : "(none)",
        szTier, szMinTier, ZGUN_VIEW_MODEL);
    client_print(id, print_chat, "%s", szLine);
    ZLog(szLine);

    formatex(szLine, charsmax(szLine),
        "[ZG-7] seqs=%d idle=%d shoot=%d/%d/%d reload=%d draw=%d dmg=%s unscoped=%d pct ammo=%d",
        ZGUN_SEQ_COUNT, ZGUN_SEQ_IDLE, ZGUN_SEQ_SHOOT1, ZGUN_SEQ_SHOOT2,
        ZGUN_SEQ_SHOOT3, ZGUN_SEQ_RELOAD, ZGUN_SEQ_DRAW,
        szDamage, ZGUN_UNSCOPED_PCT, ZGUN_MAX_AMMO);
    client_print(id, print_chat, "%s", szLine);
    ZLog(szLine);

    new bModel = file_exists(ZGUN_VIEW_MODEL);
    new bVip = FnVipUsable();
    formatex(szLine, charsmax(szLine),
        "[ZG-7] model_present=%d freenova_vip=%d", bModel, bVip);
    client_print(id, print_chat, "%s", szLine);
    ZLog(szLine);

    CountHolders();

    for (new i = 1; i <= MaxClients; i++)
    {
        if (!is_user_connected(i)) continue;

        new bAlive = is_user_alive(i);
        new bFlag = PlayerHasFlag(i);
        new bTier = PlayerHasVipTier(i);
        new bElig = PlayerIsEligible(i);
        new bHold = g_bHasZgun[i];
        new iWpn = cs_get_user_weapon(i);
        new szPName[32];
        get_user_name(i, szPName, charsmax(szPName));

        formatex(szLine, charsmax(szLine),
            "[ZG-7] slot=%d name=%s alive=%d flag=%d tier=%d eligible=%d holder=%d wpn=%d",
            i, szPName, bAlive, bFlag, bTier, bElig, bHold, iWpn);
        // Format string is the literal, not the built line: a name with '%' in
        // it would otherwise be read as a conversion spec. REVIEW.md §5.5.
        client_print(id, print_chat, "%s", szLine);
        ZLog(szLine);
    }

    return PLUGIN_HANDLED;
}

// Online / holder tallies, also emitted to the AMXX log for staff.
stock CountHolders()
{
    new iHolders, iFlagHolders, iTierHolders, iOnline;

    for (new i = 1; i <= MaxClients; i++)
    {
        if (!is_user_connected(i)) continue;

        iOnline++;
        if (PlayerHasFlag(i)) iFlagHolders++;
        if (PlayerHasVipTier(i)) iTierHolders++;
        if (g_bHasZgun[i]) iHolders++;
    }

    new szLine[128];
    formatex(szLine, charsmax(szLine),
        "[ZG-7] online=%d holders=%d flag_t_players=%d vip_tier_players=%d",
        iOnline, iHolders, iFlagHolders, iTierHolders);
    ZLog(szLine);
}

// ==================================================================== menu ==

public ShowMenu(id)
{
    if (!is_user_connected(id)) return;

    new szTitle[64], szLine[256];
    Zgun_MenuTitle(szTitle, charsmax(szTitle), "VIP Weapons");

    new menu = menu_create(szTitle, "Menu_Handler");

    if (g_bHasZgun[id])
        Zgun_MenuRow(szLine, charsmax(szLine), ZGUN_DISPLAY_NAME, "OWNED")
    else if (!get_pcvar_num(g_pEnabled))
        Zgun_MenuRow(szLine, charsmax(szLine), ZGUN_DISPLAY_NAME, "DISABLED")
    else if (!is_user_alive(id))
        Zgun_MenuRow(szLine, charsmax(szLine), ZGUN_DISPLAY_NAME, "DEAD")
    else if (!PlayerIsEligible(id))
        Zgun_MenuRow(szLine, charsmax(szLine), ZGUN_DISPLAY_NAME, "VIP ONLY")
    else
        Zgun_MenuRow(szLine, charsmax(szLine), ZGUN_DISPLAY_NAME, "TAKE")

    menu_additem(menu, szLine, "1", 0);
    menu_additem(menu, "\wRefill ammunition", "2", 0);
    menu_additem(menu, "\wWeapon spec sheet", "3", 0);
    menu_additem(menu, "\wHow to get VIP access", "4", 0);

    Zgun_MenuFinish(menu, false);
    menu_display(id, menu, 0);
}

public Menu_Handler(id, menu, item)
{
    if (!(1 <= id <= MaxClients)) return PLUGIN_HANDLED;

    if (item == MENU_EXIT)
    {
        menu_destroy(menu);
        return PLUGIN_HANDLED;
    }

    new szInfo[8], szDummy[64];
    new iDummy;
    menu_item_getinfo(menu, item, iDummy, szInfo, charsmax(szInfo), szDummy, charsmax(szDummy), iDummy);

    switch (str_to_num(szInfo))
    {
        case 1:
        {
            GiveZgun(id);
        }
        case 2:
        {
            if (!g_bHasZgun[id])
            {
                client_print(id, print_chat, "[ZG-7] You do not have the Zgun.");
            }
            else if (!is_user_alive(id))
            {
                client_print(id, print_chat, "[ZG-7] You must be alive.");
            }
            else
            {
                cs_set_user_bpammo(id, ZGUN_BASE_WEAPON, ZGUN_MAX_AMMO);
                client_print(id, print_chat, "[ZG-7] Reserve ammunition topped up to %d.", ZGUN_MAX_AMMO);
            }
        }
        case 3:
        {
            ShowSpecSheet(id);
        }
        case 4:
        {
            ShowVipHelp(id);
        }
    }

    menu_destroy(menu);
    return PLUGIN_HANDLED;
}

// ============================================================== MOTD pages ==

public Cmd_SpecSheet(id)
{
    if (!is_user_connected(id)) return PLUGIN_HANDLED;
    ShowSpecSheet(id);
    return PLUGIN_HANDLED;
}

stock ShowSpecSheet(id)
{
    RefreshFlagString();

    new szPage[1536], iLen;
    iLen = Zgun_MotdHeader(szPage, charsmax(szPage), ZGUN_DISPLAY_NAME, "VIP custom sniper");

    iLen += formatex(szPage[iLen], charsmax(szPage) - iLen,
        "<table class='fnt'>\
         <tr><th colspan='2'>Weapon</th></tr>\
         <tr><td class='k'>Model</td><td class='v'>v_awpz.mdl / p_awpz.mdl</td></tr>\
         <tr><td class='k'>Animations</td><td class='v'>%d sequences</td></tr>\
         <tr><td class='k'>Idle</td><td class='v'>seq %d &bull; 4.03 s loop</td></tr>\
         <tr><td class='k'>Fire cycle</td><td class='v'>seq %d / %d / %d</td></tr>\
         <tr><td class='k'>Reload</td><td class='v'>seq %d &bull; %.1f s</td></tr>\
         <tr><td class='k'>Deploy</td><td class='v'>seq %d &bull; %.1f s</td></tr>\
         <tr><th colspan='2'>Handling</th></tr>\
         <tr><td class='k'>Damage (scoped)</td><td class='fnyou'>%d</td></tr>\
         <tr><td class='k'>Damage (unscoped)</td><td class='v'>x%.2f</td></tr>\
         <tr><td class='k'>Reserve ammo</td><td class='v'>%d rounds</td></tr>\
         <tr><td class='k'>Bolt cycle</td><td class='v'>%.1f s</td></tr>\
         <tr><th colspan='2'>Access</th></tr>\
         <tr><td class='k'>Flag</td><td class='v'>^"%s^"</td></tr>\
         </table>",
        ZGUN_SEQ_COUNT, ZGUN_SEQ_IDLE, ZGUN_SEQ_SHOOT1, ZGUN_SEQ_SHOOT2,
        ZGUN_SEQ_SHOOT3, ZGUN_SEQ_RELOAD, ZGUN_RELOAD_TIME, ZGUN_SEQ_DRAW,
        ZGUN_DRAW_TIME, ZGUN_DAMAGE_SCOPED, ZGUN_UNSCOPED_MULT, ZGUN_MAX_AMMO,
        ZGUN_BOLT_TIME, g_szFlag[0] ? g_szFlag : "none");

    iLen += Zgun_MotdFooter(szPage, charsmax(szPage), iLen);
    show_motd(id, szPage);
}

stock ShowVipHelp(id)
{
    new szPage[1536], iLen;
    iLen = Zgun_MotdHeader(szPage, charsmax(szPage), "Getting the ZG-7", "VIP access");

    iLen += formatex(szPage[iLen], charsmax(szPage) - iLen,
        "<table class='fnt'>\
         <tr><th colspan='2'>How it works</th></tr>\
         <tr><td class='k'>1</td><td class='v'>Type <span class='fngreen'>/zguns</span> in chat</td></tr>\
         <tr><td class='k'>2</td><td class='v'>Pick ^"%s^"</td></tr>\
         <tr><td class='k'>3</td><td class='v'>Or type <span class='fngreen'>/zgun</span> directly</td></tr>\
         <tr><th colspan='2'>Who is eligible</th></tr>\
         <tr><td class='k'>Flag</td><td class='v'>AMX Mod X flag ^"%s^"</td></tr>\
         <tr><td class='k'>Or</td><td class='v'>any active FreeNova VIP tier</td></tr>\
         </table>", ZGUN_DISPLAY_NAME, g_szFlag[0] ? g_szFlag : "(none)");

    iLen += Zgun_MotdFooter(szPage, charsmax(szPage), iLen);
    show_motd(id, szPage);
}

// ================================================================= logging ==

// Plain-string logger: AMX Mod X cannot forward "any:..." into another variadic
// call, so callers format their own line first.
stock ZLog(const szMsg[])
{
    new szOut[352];
    formatex(szOut, charsmax(szOut), "[ZG-7] %s", szMsg);
    log_amx("%s", szOut);
}