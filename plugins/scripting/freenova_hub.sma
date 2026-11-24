#include <amxmodx>
#include <amxmisc>
#include <crxranks>
#include <menabp>
#include <freenova_vip>
#include <freenova_prefs>
#include <freenova_ui>
#include <freenova_web>
#include <freenova_chat>   // fn_chat_info: the house chat service (/lpm answers through it)
#include <fn_common>

// FreeNova Hub — single player navigation surface.
// Owns no gameplay data. Every entry delegates to the owning plugin or MOTD.
//
//   N (nightvision), /freenova /menu /hub  -> this menu
//   /settings                              -> HUD preference toggles
//   /help /commands                        -> command directory
//   /panel                                 -> admin panel (admins) or this hub

#define PLUGIN  "FreeNova Hub"
#define VERSION "3.0"
#define AUTHOR  "FreeNova"

new Float:g_fHubOpen[33]
new bool:g_bSettingsFromHub[33]

#define FLAG_FN_ADMIN read_flags("cdeijuv")

native skins_open_menu(id)
native fncosmetics_get_spawn(id)
native fncosmetics_get_title(id)
native fncosmetics_get_death(id)
native fncosmetics_get_spawn_name(id, output[], len)
native fncosmetics_get_title_name(id, output[], len)
native fncosmetics_get_death_name(id, output[], len)
native fncosmetics_get_tag(id, output[], len)
native fn_skins_get_equipped(id, group)
native fn_skins_get_name(group, skin, szName[], len)
native fn_models_get_equipped(id, szModel[], len)

public plugin_natives()
{
    register_library("freenova_hub")
    register_native("fn_hub_open", "_fn_hub_open")
    set_native_filter("HubNativeFilter")
}

public HubNativeFilter(const name[], index, trap)
{
    if (equal(name, "skins_open_menu")
        || equal(name, "fncosmetics_get_spawn")
        || equal(name, "fncosmetics_get_title")
        || equal(name, "fncosmetics_get_death")
        || equal(name, "fncosmetics_get_spawn_name")
        || equal(name, "fncosmetics_get_title_name")
        || equal(name, "fncosmetics_get_death_name")
        || equal(name, "fncosmetics_get_tag")
        || equal(name, "fn_skins_get_equipped")
        || equal(name, "fn_skins_get_name")
        || equal(name, "fn_models_get_equipped"))
        return PLUGIN_HANDLED
    return PLUGIN_CONTINUE
}

public plugin_init()
{
    fn_boot_banner("hub", 14)

    register_plugin(PLUGIN, VERSION, AUTHOR)

    register_clcmd("say /freenova", "Cmd_Hub")
    register_clcmd("say_team /freenova", "Cmd_Hub")
    register_clcmd("say /menu", "Cmd_Hub")
    register_clcmd("say_team /menu", "Cmd_Hub")
    register_clcmd("say /hub", "Cmd_Hub")
    register_clcmd("say_team /hub", "Cmd_Hub")
    register_clcmd("say /settings", "Cmd_SettingsDirect")
    register_clcmd("say_team /settings", "Cmd_SettingsDirect")
    register_clcmd("say /lpm", "Cmd_Lpm", _, "low performance mode: in-game menus instead of web panels")
    register_clcmd("say_team /lpm", "Cmd_Lpm")
    register_clcmd("say /lowperf", "Cmd_Lpm")
    register_clcmd("say_team /lowperf", "Cmd_Lpm")

    // fn_chat_debug 1 logs every line the house chat service sends (see
    // fn_chat_raw in freenova_chat.inc). Registered here because this plugin is
    // always loaded and it is the service's most frequent caller.
    register_cvar("fn_chat_debug", "0")
    register_clcmd("say /help", "Cmd_Help")
    register_clcmd("say_team /help", "Cmd_Help")
    // /commands is owned by fn_commands.amxx: it builds the list from the
    // command registry instead of a hand-written menu. Cmd_Help stays the
    // curated overview behind /help and points there.

    // CS binds N to nightvision. The hub owns that key so every client
    // gets the same main menu without a client-side bind.
    register_clcmd("nightvision", "Cmd_Hub")
}

public _fn_hub_open(iPlugin, iParams)
{
    new id = get_param(1)
    if (!(1 <= id <= MaxClients) || !is_user_connected(id))
        return 0
    Cmd_Hub(id)
    return 1
}

// Fail-closed guard for the optional battlepass provider: every menabp_*
// delegate in this plugin goes through here, so a missing battlepass_core
// degrades to a chat notice instead of a runtime "nonexistent native" error.
stock bool:HubMenabpReady(id)
{
    if (LibraryExists("menabp", LibType_Library))
        return true
    client_print_color(id, print_team_default, "%s That feature is still loading - try again in a moment.", FN_CHAT_PREFIX)
    return false
}

stock HubAddItem(menu, const szLabel[], const szState[], const szData[])
{
    new szItem[96]
    FN_MenuRow(szItem, charsmax(szItem), szLabel, szState)
    menu_additem(menu, szItem, szData)
}

public Cmd_Hub(id)
{
    if (!is_user_connected(id))
        return PLUGIN_HANDLED

    // N is bound to nightvision and fires while the menu is already open.
    new Float:fNow = get_gametime()
    if ((fNow - g_fHubOpen[id]) < 0.35)
        return PLUGIN_HANDLED
    g_fHubOpen[id] = fNow

    new iLevel = crxranks_is_user_loaded(id) ? crxranks_get_user_level(id) : 0
    new bool:bMenabp = bool:LibraryExists("menabp", LibType_Library)
    new iCoins = bMenabp ? menabp_get_coins(id) : 0
    new iVip = fnvip_get_tier(id)
    new iMsnDone = bMenabp ? menabp_get_daily_done(id) : 0
    new bool:bCompact = (fnpref_is_loaded(id) && fnpref_get(id, FNPREF_COMPACT_MENUS)) ? true : false
    new szVip[16]
    fnvip_get_tier_name_raw(iVip, szVip, charsmax(szVip))
    if (!szVip[0] || equal(szVip, "None"))
        copy(szVip, charsmax(szVip), "Member")

    new szTitle[64]
    FN_MenuTitle(szTitle, charsmax(szTitle), "Menu", iCoins)
    new menu = menu_create(szTitle, "Hub_Handler")

    new szState[16]
    formatex(szState, charsmax(szState), "L%d", iLevel)
    HubAddItem(menu, "Profile", bCompact ? "" : szState, "0")
    formatex(szState, charsmax(szState), "daily %d/5", iMsnDone)
    HubAddItem(menu, "Missions & Medals", bCompact ? "" : szState, "1")
    HubAddItem(menu, "Battle Pass skills", "", "2")
    HubAddItem(menu, "Cosmetics", "", "3")
    HubAddItem(menu, "Skins & Models", "", "4")
    HubAddItem(menu, "VIP", bCompact ? "" : szVip, "5")
    HubAddItem(menu, "Settings", "", "6")

    if (get_user_flags(id) & FLAG_FN_ADMIN)
        menu_additem(menu, "\rAdmin Panel", "7")

    FN_MenuFinish(menu, false)
    menu_display(id, menu, 0)
    return PLUGIN_HANDLED
}





public Hub_Handler(id, menu, item)
{
    if (item == MENU_EXIT)
    {
        menu_destroy(menu)
        return PLUGIN_HANDLED
    }

    new szData[8], iAccess, iCallback
    menu_item_getinfo(menu, item, iAccess, szData, charsmax(szData), _, _, iCallback)
    menu_destroy(menu)

    switch (str_to_num(szData))
    {
        case 0: OpenOrSay(id, FN_PANEL_PROFILE, "/rankstats")
        case 1:
        {
            if (HubMenabpReady(id))
                menabp_show_missions(id)
        }
        case 2:
        {
            if (HubMenabpReady(id))
                menabp_show_skills(id)
        }
        case 3: client_cmd(id, "say /cosmetics")
        case 4: OpenSkins(id)
        case 5: fnvip_show_vip_motd(id)
        case 6:
        {
            g_bSettingsFromHub[id] = true
            OpenSettings(id)
        }
        case 7:
        {
            if (get_user_flags(id) & FLAG_FN_ADMIN)
                client_cmd(id, "say /panel")
        }
    }
    return PLUGIN_HANDLED
}

OpenOrSay(id, iKind, const szFallback[])
{
    if (fn_open_panel(id, iKind))
        return
    if (szFallback[0])
        client_cmd(id, "say %s", szFallback)
}

OpenSkins(id)
{
    new szTitle[64]
    FN_MenuTitle(szTitle, charsmax(szTitle), "Skins & Models", LibraryExists("menabp", LibType_Library) ? menabp_get_coins(id) : 0)
    new menu = menu_create(szTitle, "Skins_Handler")
    menu_additem(menu, "\wWeapon skins", "0")
    menu_additem(menu, "\wPlayer models", "1")
    FN_MenuFinish(menu, true)
    menu_display(id, menu, 0)
}

public Skins_Handler(id, menu, item)
{
    if (item == MENU_EXIT)
    {
        menu_destroy(menu)
        Cmd_Hub(id)
        return PLUGIN_HANDLED
    }

    new szData[8], iAccess, iCallback
    menu_item_getinfo(menu, item, iAccess, szData, charsmax(szData), _, _, iCallback)
    menu_destroy(menu)

    switch (str_to_num(szData))
    {
        case 0: skins_open_menu(id)
        case 1: client_cmd(id, "say /models")
    }
    return PLUGIN_HANDLED
}

OpenSettings(id)
{
    new szTitle[64]
    FN_MenuTitle(szTitle, charsmax(szTitle), "Settings")
    new menu = menu_create(szTitle, "Settings_Handler")
    menu_additem(menu, FormatToggle("Rank HUD", fnpref_get(id, FNPREF_RANK_HUD)), "0")
    menu_additem(menu, FormatToggle("Damage HUD", fnpref_get(id, FNPREF_DAMAGE_HUD)), "1")
    menu_additem(menu, FormatToggle("Compact menus", fnpref_get(id, FNPREF_COMPACT_MENUS)), "2")
    menu_additem(menu, FormatToggle("Low perf mode", fnpref_get(id, FNPREF_LOW_PERF)), "3")
    FN_MenuFinish(menu, true)
    menu_display(id, menu, 0)
}

public Cmd_Settings(id)
{
    if (!fnpref_is_loaded(id))
    {
        client_print_color(id, print_team_default, "%s Still loading your profile - try again in a moment.", FN_CHAT_PREFIX)
        return PLUGIN_HANDLED
    }

    OpenSettings(id)
    return PLUGIN_HANDLED
}

public Cmd_SettingsDirect(id)
{
    g_bSettingsFromHub[id] = false
    return Cmd_Settings(id)
}

// ---------------------------------------------------------------- low perf mode
// /lpm - the switch behind every panel command. One preference slot
// (FNPREF_LOW_PERF) that freenova_prefs persists per SteamID in nvault
// (key pref#<steamid>, default off), so it survives a reconnect and a server
// restart. What it DOES is decided in one place: fn_open_panel() in
// freenova_web.inc refuses every MOTD while it is on, and each command opens its
// in-game surface instead. This file only owns the switch and the confirmation.
public Cmd_Lpm(id)
{
    if (!is_user_connected(id))
        return PLUGIN_HANDLED

    if (!fnpref_is_loaded(id))
    {
        // Distinguish "not loaded yet" from "cannot ever load here": the prefs
        // layer keys on a stable SteamID, so a bot or a LAN (STEAM_ID_LAN)
        // client has no row to save to. Saying "try again" forever is a lie.
        new szAuth[40]
        get_user_authid(id, szAuth, charsmax(szAuth))
        if (equali(szAuth, "BOT") || equali(szAuth, "HLTV") || equali(szAuth, "STEAM_ID_LAN")
            || equali(szAuth, "STEAM_ID_PENDING") || !szAuth[0])
            fn_chat_error(id, "Low performance mode is stored per SteamID and your identity (%s) is not one, so it cannot be saved. Steam-authenticated players get the toggle.", szAuth[0] ? szAuth : "none")
        else
            fn_chat_info(id, "Still loading your profile - say /lpm again in a moment.")
        return PLUGIN_HANDLED
    }

    HubToggleLowPerf(id)
    return PLUGIN_HANDLED
}

stock HubToggleLowPerf(id)
{
    new iOn = fnpref_get(id, FNPREF_LOW_PERF) ? 0 : 1
    fnpref_set(id, FNPREF_LOW_PERF, iOn)

    // Through the house chat service (fn_chat_*, FN_CHAT_PREFIX) like every other
    // user-triggered answer, so the look and the log line match the rest.
    if (iOn)
    {
        // Say what changed, not only that something did.
        fn_chat_info(id,
            "Low performance mode ^3ON^1 - web panels are off: /christmas, /gifts, /tree, /ornaments, /advent, /winterpass, /profile, /vip and /rules open in game instead. Saved for your SteamID.")
    }
    else
    {
        fn_chat_info(id,
            "Low performance mode ^1OFF^1 - web panels are back for /christmas, /gifts, /tree, /profile and the rest. Saved for your SteamID.")
    }

    new szAuth[40]
    get_user_authid(id, szAuth, charsmax(szAuth))
    log_amx("[HUB] low performance mode %s for id=%d (%s)", iOn ? "ON" : "OFF", id, szAuth)
    return iOn
}

FormatToggle(const szLabel[], iValue)
{
    static szItem[48]
    formatex(szItem, charsmax(szItem), "\w%-14s %s", szLabel, iValue ? "\y(ON)" : "\d(OFF)")
    return szItem
}

public Settings_Handler(id, menu, item)
{
    if (item == MENU_EXIT)
    {
        menu_destroy(menu)
        if (g_bSettingsFromHub[id])
            Cmd_Hub(id)
        return PLUGIN_HANDLED
    }

    new szData[8], iAccess, iCallback
    menu_item_getinfo(menu, item, iAccess, szData, charsmax(szData), _, _, iCallback)
    menu_destroy(menu)

    switch (str_to_num(szData))
    {
        case 0:
        {
            fnpref_set(id, FNPREF_RANK_HUD, fnpref_get(id, FNPREF_RANK_HUD) ? 0 : 1)
            client_print_color(id, print_team_default, "%s Rank HUD > %s",
                FN_CHAT_PREFIX, fnpref_get(id, FNPREF_RANK_HUD) ? "ENABLED" : "DISABLED")
        }
        case 1:
        {
            fnpref_set(id, FNPREF_DAMAGE_HUD, fnpref_get(id, FNPREF_DAMAGE_HUD) ? 0 : 1)
            client_print_color(id, print_team_default, "%s Damage HUD > %s",
                FN_CHAT_PREFIX, fnpref_get(id, FNPREF_DAMAGE_HUD) ? "ENABLED" : "DISABLED")
        }
        case 2:
        {
            fnpref_set(id, FNPREF_COMPACT_MENUS, fnpref_get(id, FNPREF_COMPACT_MENUS) ? 0 : 1)
            client_print_color(id, print_team_default, "%s Compact menus > %s",
                FN_CHAT_PREFIX, fnpref_get(id, FNPREF_COMPACT_MENUS) ? "ENABLED" : "DISABLED")
        }
        case 3:
        {
            // One switch, one message: /lpm and this row do the same thing.
            HubToggleLowPerf(id)
        }
    }
    Cmd_Settings(id)
    return PLUGIN_HANDLED
}

public Cmd_Help(id)
{
    if (!is_user_connected(id))
        return PLUGIN_HANDLED

    new szTitle[64]
    FN_MenuTitle(szTitle, charsmax(szTitle), "Help")
    new menu = menu_create(szTitle, "Help_Handler")
    // The full, generated list lives in fn_commands (/commands): this menu is
    // the short curated path for the things players ask for by name.
    client_print_color(id, print_team_default, "%s This menu is the short list - say /commands for every command.", FN_CHAT_PREFIX)
    menu_additem(menu, "\wProfile / stats \d(/rankstats)", "0")
    menu_additem(menu, "\wBattle Pass \d(/bp)", "1")
    menu_additem(menu, "\wMissions \d(/missions)", "2")
    menu_additem(menu, "\wAchievements \d(/achievements)", "3")
    menu_additem(menu, "\wCoin shop \d(/shop)", "4")
    menu_additem(menu, "\wSkins \d(/skins)", "5")
    menu_additem(menu, "\wModels \d(/models)", "6")
    menu_additem(menu, "\wCosmetics \d(/cosmetics)", "7")
    menu_additem(menu, "\wVIP \d(/vip)", "8")
    menu_additem(menu, "\wTop 15 \d(/top15)", "9")
    menu_additem(menu, "\wRules \d(/rules)", "10")
    menu_additem(menu, "\wDiscord handle", "11")
    if (get_user_flags(id) & FLAG_FN_ADMIN)
        menu_additem(menu, "\rAdmin panel \d(/panel)", "12")
    FN_MenuFinish(menu, true)
    menu_display(id, menu, 0)
    return PLUGIN_HANDLED
}

public Help_Handler(id, menu, item)
{
    if (item == MENU_EXIT)
    {
        menu_destroy(menu)
        Cmd_Hub(id)
        return PLUGIN_HANDLED
    }

    new szData[8], iAccess, iCallback
    menu_item_getinfo(menu, item, iAccess, szData, charsmax(szData), _, _, iCallback)
    menu_destroy(menu)

    switch (str_to_num(szData))
    {
        case 0: OpenOrSay(id, FN_PANEL_PROFILE, "/rankstats")
        case 1:
        {
            if (HubMenabpReady(id))
                menabp_show_battlepass(id)
        }
        case 2:
        {
            if (HubMenabpReady(id))
                menabp_show_missions(id)
        }
        case 3:
        {
            if (HubMenabpReady(id))
                menabp_show_achievements(id)
        }
        case 4:
        {
            if (HubMenabpReady(id))
                menabp_show_shop(id)
        }
        case 5: skins_open_menu(id)
        case 6: client_cmd(id, "say /models")
        case 7: client_cmd(id, "say /cosmetics")
        case 8: fnvip_show_vip_motd(id)
        case 9: OpenOrSay(id, FN_PANEL_TOP, "/top15")
        case 10: client_cmd(id, "say /rules")
        case 11:
        {
            new szHandle[32]
            FN_GetDiscordHandle(szHandle, charsmax(szHandle))
            client_print_color(id, print_team_default, "%s Discord: %s", FN_CHAT_PREFIX, szHandle)
            Cmd_Help(id)
        }
        case 12: client_cmd(id, "say /panel")
    }
    return PLUGIN_HANDLED
}
