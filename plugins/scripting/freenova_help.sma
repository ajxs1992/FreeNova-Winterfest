// FreeNova central help registry (M13).
//
// amx_cmdhelp <command>  - beginner-friendly detail (console + chat pointer)
// amx_fnsearch <term>   - search names/descriptions (permission-aware)
// amx_helpmenu           - category menu
// say /cmdhelp <command> - in-game shortcut to amx_cmdhelp
//
// Stock adminhelp.amxx (amx_help) stays enabled; this plugin never touches it.
// Uses fn_chat_* for all player feedback (see freenova_chat.inc).

#include <amxmodx>
#include <freenova_chat>
#include <freenova_help>
#include <fn_common>

#define PLUGIN  "FreeNova Help Registry"
#define VERSION "1.0.0"
#define AUTHOR  "FreeNova"

#define MAX_STATIC   40
#define MAX_DYNAMIC  32

enum _:HelpEntry
{
    HE_CMD[32],
    HE_SYNTAX[96],
    HE_DESC[160],
    HE_EXAMPLE[96],
    HE_PERM[64],
    HE_CAT[24],
    HE_MENU[40],
    HE_FLAGS
}

// Static registry: verified against source register_concmd/clcmd lines.
// Entries marked EXTERNAL live in stock AMXX or unvendored plugins; entries
// marked PLANNED do not exist yet and are documentation only.
new g_Static[][HelpEntry] =
{
    { "amx_gag", "amx_gag <player> <minutes> [mode] [reason]",
      "Stops a player from sending chat messages for a chosen time. Mode letters: a public chat, b team chat, c voice. 0 minutes means permanent.",
      "amx_gag PlayerName 15 ab Spamming", "Admin chat+kick set (cdeijuv)", "Moderation", "amx_gagmenu", ADMIN_ALL },
    { "amx_ungag", "amx_ungag <player>",
      "Removes an active gag so the player can chat and use voice again.",
      "amx_ungag PlayerName", "Admin chat+kick set (cdeijuv)", "Moderation", "amx_gagmenu", ADMIN_ALL },
    { "amx_gagmenu", "amx_gagmenu",
      "Opens the gag menu: pick a player, a duration and a gag mode. You may gag yourself for testing.",
      "amx_gagmenu", "Admin chat+kick set (cdeijuv)", "Moderation", "N panel", ADMIN_ALL },
    { "amx_gags", "amx_gags",
      "Lists every currently gagged player with remaining time.",
      "amx_gags", "Admin chat+kick set (cdeijuv)", "Moderation", "-", ADMIN_ALL },
    { "/gag", "/gag (opens player menu)",
      "Menu shortcut for gagging: choose a player, then time and mode.",
      "/gag", "Admin chat+kick set (cdeijuv)", "Moderation", "amx_gagmenu", ADMIN_ALL },
    { "/ungag", "/ungag (opens player menu)",
      "Menu shortcut for removing a gag.",
      "/ungag", "Admin chat+kick set (cdeijuv)", "Moderation", "amx_gagmenu", ADMIN_ALL },
    { "/panel", "/panel",
      "Opens the FreeNova admin panel (N key works too).",
      "/panel", "Any admin flag", "Moderation", "N key", ADMIN_ALL },
    { "/ban", "/ban (opens player menu)",
      "Bans a player from the server for a chosen duration. Permanent bans ask for confirmation first.",
      "/ban", "Ban permission", "Moderation", "N panel", ADMIN_BAN },
    { "/unban", "/unban (opens menu)",
      "Removes a ban so the player can join again.",
      "/unban", "Unban permission", "Moderation", "N panel", ADMIN_BAN },
    { "/kick", "/kick (opens player menu)",
      "Kicks a player off the server immediately. They may rejoin.",
      "/kick", "Kick permission", "Moderation", "N panel", ADMIN_KICK },
    { "/slay", "/slay (opens player menu)",
      "Kills the target player in the current round. You may slay yourself.",
      "/slay", "Slay permission", "Moderation", "N panel", ADMIN_SLAY },
    { "/slap", "/slap (opens player menu)",
      "Slaps the target player for small damage. You may slap yourself.",
      "/slap", "Slap permission", "Moderation", "N panel", ADMIN_SLAY },
    { "amx_addadmin", "amx_addadmin <player> <flags> [password]  (EXTERNAL: stock admin plugin)",
      "Adds a player as an administrator with the given access flags. Managed by stock AMXX, not FreeNova code.",
      "amx_addadmin PlayerName abcdefij", "RCON / high admin (EXTERNAL contract)", "Admins", "-", ADMIN_RCON },
    { "amx_reloadadmins", "amx_reloadadmins  (EXTERNAL: stock admin plugin)",
      "Reloads the administrator list from users.ini without restarting the map.",
      "amx_reloadadmins", "RCON / high admin (EXTERNAL contract)", "Admins", "-", ADMIN_RCON },
    { "fn_admin_grant", "fn_admin_grant <target> <role> <minutes: 0 = permanent>",
      "Grants a FreeNova role until a chosen time. 0 means permanent. Survives map changes and restarts.",
      "fn_admin_grant STEAM_0:1:123456 moderator 1440", "Manager (flag a)", "Admins", "fn_admin_menu", ADMIN_RCON },
    { "fn_admin_until", "fn_admin_until <steamid> <YYYY-MM-DDTHH:MM>",
      "Grants a role until an exact date and time. Must be in the future.",
      "fn_admin_until STEAM_0:1:123456 2026-10-25T18:00", "Manager (flag a)", "Admins", "fn_admin_menu", ADMIN_RCON },
    { "fn_admin_extend", "fn_admin_extend <target> <minutes>",
      "Adds more time to an existing grant.",
      "fn_admin_extend PlayerName 1440", "Manager (flag a)", "Admins", "fn_admin_menu", ADMIN_RCON },
    { "fn_admin_revoke", "fn_admin_revoke <target>",
      "Removes a grant immediately. Separate users.ini/SQL rights are kept.",
      "fn_admin_revoke PlayerName", "Manager (flag a)", "Admins", "fn_admin_menu", ADMIN_RCON },
    { "fn_admin_remaining", "fn_admin_remaining <target>",
      "Shows how much time is left on a grant, or permanent.",
      "fn_admin_remaining PlayerName", "Manager (flag a)", "Admins", "fn_admin_menu", ADMIN_RCON },
    { "fn_admin_list", "fn_admin_list",
      "Lists all active grants with roles and expiry.",
      "fn_admin_list", "Manager (flag a)", "Admins", "fn_admin_menu", ADMIN_RCON },
    { "fn_admin_sweep", "fn_admin_sweep",
      "Removes every expired grant now (also runs automatically).",
      "fn_admin_sweep", "Manager (flag a)", "Admins", "-", ADMIN_RCON },
    { "fn_admin_menu", "fn_admin_menu",
      "Opens the admin manager: add, remove, edit, extend, online, all, expiring soon, expired.",
      "fn_admin_menu", "Manager (flag a)", "Admins", "-", ADMIN_RCON },
    { "amx_fngivevip", "amx_fngivevip <target> <tier 1-3> <hours>",
      "Grants a VIP tier for a number of hours (1 to 87600). Hours are required; there is no permanent VIP here.",
      "amx_fngivevip PlayerName 2 168", "Ban-level admin", "Admins", "VIP menu", ADMIN_BAN },
    { "amx_fnremovevip", "amx_fnremovevip <target> <tier 1-3|all>",
      "Removes a VIP tier, or every tier with all.",
      "amx_fnremovevip PlayerName all", "Ban-level admin", "Admins", "VIP menu", ADMIN_BAN },
    { "amx_fnviplist", "amx_fnviplist",
      "Lists resolved VIP tiers with source and expiry.",
      "amx_fnviplist", "Ban-level admin", "Admins", "VIP menu", ADMIN_BAN },
    { "/rtv", "/rtv",
      "Votes to change the map early (rock the vote). Enough votes starts a map vote.",
      "/rtv", "Every player", "Maps", "-", ADMIN_ALL },
    { "/nominate", "/nominate <map>",
      "Nominates a map for the next vote. Without a name it lists recent maps.",
      "/nominate de_inferno", "Every player", "Maps", "-", ADMIN_ALL },
    { "/votemap", "/votemap",
      "Admin shortcut that starts a map vote immediately.",
      "/votemap", "Map/vote admin", "Maps", "-", ADMIN_MAP },
    { "/noms", "/noms",
      "Shows the current nomination list.",
      "/noms", "Every player", "Maps", "-", ADMIN_ALL },
    { "/votehelp", "/votehelp",
      "Explains the map voting commands.",
      "/votehelp", "Every player", "Maps", "-", ADMIN_ALL },
    { "/fnextend", "/fnextend",
      "Extends the current map (admin).",
      "/fnextend", "Map/vote admin", "Maps", "-", ADMIN_MAP },
    { "/fnvote", "/fnvote",
      "Forces a map vote to start now (admin).",
      "/fnvote", "Map/vote admin", "Maps", "-", ADMIN_MAP },
    { "/fnvotecancel", "/fnvotecancel",
      "Cancels a running map vote (admin).",
      "/fnvotecancel", "Map/vote admin", "Maps", "-", ADMIN_MAP },
    { "/register", "/register",
      "Opens the FreeNova forum registration menu. Aliases: /reg, /forumregister.",
      "/register", "Every player", "Players", "-", ADMIN_ALL },
    { "/forum", "/forum",
      "Shows forum and account information.",
      "/forum", "Every player", "Players", "-", ADMIN_ALL },
    { "/account", "/account",
      "Shows your linked forum account information.",
      "/account", "Every player", "Players", "-", ADMIN_ALL },
    { "amx_freenova_regstatus", "amx_freenova_regstatus",
      "Shows whether the forum link is online (RCON diagnostics).",
      "amx_freenova_regstatus", "RCON", "Diagnostics", "-", ADMIN_RCON },
    { "amx_freenova_happyhour", "amx_freenova_happyhour <1|0>",
      "Forces happy hour bonus XP on (1) or off (0).",
      "amx_freenova_happyhour 1", "RCON", "Server", "-", ADMIN_RCON },
    { "amx_plugins", "amx_plugins  (EXTERNAL: stock)",
      "Lists loaded plugins and their state ([RUN] / paused / bad load).",
      "amx_plugins", "Every player (console)", "Diagnostics", "-", ADMIN_ALL },
    { "amx_modules", "amx_modules  (EXTERNAL: stock)",
      "Lists loaded AMXX modules.",
      "amx_modules", "Every player (console)", "Diagnostics", "-", ADMIN_ALL },
    { "amx_cvar", "amx_cvar <cvar> [value]  (EXTERNAL: stock)",
      "Shows or changes a server setting. Changing needs RCON-level rights.",
      "amx_cvar mp_timelimit", "RCON for changes", "Server", "-", ADMIN_ALL },
    { "amx_rcon", "amx_rcon <command>  (EXTERNAL: stock)",
      "Runs a console command on the server with full rights. Never share RCON access.",
      "amx_rcon status", "RCON password holders", "Server", "-", ADMIN_RCON }
};

new g_DynCmd[MAX_DYNAMIC][32]
new g_DynSyntax[MAX_DYNAMIC][96]
new g_DynDesc[MAX_DYNAMIC][160]
new g_DynExample[MAX_DYNAMIC][96]
new g_DynPerm[MAX_DYNAMIC][64]
new g_DynCat[MAX_DYNAMIC][24]
new g_DynCount

public plugin_init()
{
    fn_boot_banner("help", 6)

    register_plugin(PLUGIN, VERSION, AUTHOR)
    register_library("freenova_help")
    register_native("fn_help_register", "Nat_HelpRegister")
    register_concmd("amx_cmdhelp", "CmdHelp", ADMIN_ALL, "amx_cmdhelp <command> - detailed help")
    // Keep amx_searchcmd owned by stock adminhelp. The FreeNova search keeps its richer registry under a distinct name.
    register_concmd("amx_fnsearch", "CmdSearch", ADMIN_ALL, "amx_fnsearch <term> - search FreeNova commands")
    register_concmd("amx_helpmenu", "CmdHelpMenu", ADMIN_ALL, "amx_helpmenu - help by category")
    register_clcmd("say /cmdhelp", "CmdSayHelp")
    register_clcmd("say_team /cmdhelp", "CmdSayHelp")
}

public Nat_HelpRegister(plugin, argc)
{
    if (g_DynCount >= MAX_DYNAMIC)
        return 0
    get_string(1, g_DynCmd[g_DynCount], 31)
    get_string(2, g_DynSyntax[g_DynCount], 95)
    get_string(3, g_DynDesc[g_DynCount], 159)
    get_string(4, g_DynExample[g_DynCount], 95)
    get_string(5, g_DynPerm[g_DynCount], 63)
    get_string(6, g_DynCat[g_DynCount], 23)
    g_DynCount++
    return 1
}

// -1 static miss, -2 dynamic miss, else static index (dyn checked separately).
stock FindStatic(const szCmd[])
{
    for (new i = 0; i < sizeof(g_Static); i++)
    {
        if (equali(g_Static[i][HE_CMD], szCmd))
            return i
    }
    return -1
}

stock FindDyn(const szCmd[])
{
    for (new i = 0; i < g_DynCount; i++)
    {
        if (equali(g_DynCmd[i], szCmd))
            return i
    }
    return -1
}

// Permission-aware: admins see what their flags allow; public entries
// (ADMIN_ALL rows) show for everyone.
stock bool:MaySee(id, iFlags)
{
    if (iFlags == ADMIN_ALL)
        return true
    if (id == 0)
        return true
    return bool:(get_user_flags(id) & iFlags);
}

stock ShowDetail(id, iStatic, iDyn)
{
    new szCmd[32], szSyntax[96], szDesc[160], szExample[96]
    new szPerm[64], szCat[24], szMenu[40]
    if (iStatic >= 0)
    {
        copy(szCmd, 31, g_Static[iStatic][HE_CMD])
        copy(szSyntax, 95, g_Static[iStatic][HE_SYNTAX])
        copy(szDesc, 159, g_Static[iStatic][HE_DESC])
        copy(szExample, 95, g_Static[iStatic][HE_EXAMPLE])
        copy(szPerm, 63, g_Static[iStatic][HE_PERM])
        copy(szCat, 23, g_Static[iStatic][HE_CAT])
        copy(szMenu, 39, g_Static[iStatic][HE_MENU])
    }
    else
    {
        copy(szCmd, 31, g_DynCmd[iDyn])
        copy(szSyntax, 95, g_DynSyntax[iDyn])
        copy(szDesc, 159, g_DynDesc[iDyn])
        copy(szExample, 95, g_DynExample[iDyn])
        copy(szPerm, 63, g_DynPerm[iDyn])
        copy(szCat, 23, g_DynCat[iDyn])
        copy(szMenu, 39, "plugin menu")
    }
    console_print(id, "--- Help: %s [%s] ---", szCmd, szCat)
    console_print(id, "What: %s", szDesc)
    console_print(id, "Use: %s", szSyntax)
    console_print(id, "Example: %s", szExample)
    console_print(id, "Needs: %s", szPerm)
    console_print(id, "Menu: %s", szMenu)
    if (id != 0)
        fn_chat_info(id, "Detailed help for %s was printed in your console.", szCmd)
    return 1
}

stock bool:PrintRegisteredHelp(id, const szKey[])
{
    new iFlags, szCmd[32], szInfo[128];
    new iTotal = get_concmdsnum(-1, -1);
    for (new i = 0; i < iTotal; i++)
    {
        if (!get_concmd(i, szCmd, charsmax(szCmd), iFlags, szInfo, charsmax(szInfo), -1, -1))
            continue;
        if (!equali(szCmd, szKey))
            continue;
        if (id > 0 && !(get_user_flags(id) & iFlags))
        {
            fn_chat_permission(id, "You need higher rights to view help for %s.", szKey);
            return true;
        }
        console_print(id, "%s - %s", szCmd, szInfo[0] ? szInfo : "registered command");
        if (id > 0)
            fn_chat_info(id, "Help for %s was printed in your console.", szCmd);
        return true;
    }
    return false;
}

stock PrintRegisteredMatches(id, const szTerm[], &iShown)
{
    new iFlags, szCmd[32], szInfo[128];
    new iTotal = get_concmdsnum(-1, -1);
    for (new i = 0; i < iTotal && iShown < 10; i++)
    {
        if (!get_concmd(i, szCmd, charsmax(szCmd), iFlags, szInfo, charsmax(szInfo), -1, -1))
            continue;
        if (containi(szCmd, szTerm) < 0 && containi(szInfo, szTerm) < 0)
            continue;
        if (id > 0 && !(get_user_flags(id) & iFlags))
            continue;
        console_print(id, "%s - %s", szCmd, szInfo[0] ? szInfo : "registered command");
        iShown++;
    }
}

public CmdHelp(id, level, cid)
{
    new szArg[32]
    read_argv(1, szArg, charsmax(szArg))
    if (!szArg[0])
    {
        if (id == 0)
            console_print(0, "Use: amx_cmdhelp <command>  (try amx_fnsearch <term>)")
        else
            fn_chat_usage(id, "Use: amx_cmdhelp <command>  (try amx_fnsearch <term>)")
        return PLUGIN_HANDLED
    }
    // Strip a leading / for forgiving lookup.
    new szKey[32]
    copy(szKey, 31, szArg[szArg[0] == '/' ? 1 : 0])
    new i = FindStatic(szKey)
    if (i >= 0)
    {
        if (!MaySee(id, g_Static[i][HE_FLAGS]))
        {
            fn_chat_permission(id, "You need higher rights to view help for %s.", szKey)
            return PLUGIN_HANDLED
        }
        ShowDetail(id, i, -1)
        return PLUGIN_HANDLED
    }
    new j = FindDyn(szKey)
    if (j >= 0)
    {
        ShowDetail(id, -1, j)
        return PLUGIN_HANDLED
    }
    if (PrintRegisteredHelp(id, szKey))
        return PLUGIN_HANDLED
    if (id == 0)
        console_print(0, "No help found for '%s'. Try amx_fnsearch.", szArg)
    else
        fn_chat_error(id, "No help found for '%s'. Try amx_fnsearch.", szArg)
    return PLUGIN_HANDLED
}

public CmdSearch(id, level, cid)
{
    new szTerm[32]
    read_argv(1, szTerm, charsmax(szTerm))
    if (!szTerm[0])
    {
        if (id == 0)
            console_print(0, "Use: amx_fnsearch <term>")
        else
            fn_chat_usage(id, "Use: amx_fnsearch <term>")
        return PLUGIN_HANDLED
    }
    new iShown = 0, iHidden = 0
    console_print(id, "--- Commands matching '%s' ---", szTerm)
    for (new i = 0; i < sizeof(g_Static); i++)
    {
        if (containi(g_Static[i][HE_CMD], szTerm) < 0
            && containi(g_Static[i][HE_DESC], szTerm) < 0)
            continue
        if (!MaySee(id, g_Static[i][HE_FLAGS]))
        {
            iHidden++
            continue
        }
        console_print(id, "%s - %s", g_Static[i][HE_CMD], g_Static[i][HE_SYNTAX])
        iShown++
        if (iShown >= 10)
            break
    }
    for (new i = 0; i < g_DynCount && iShown < 10; i++)
    {
        if (containi(g_DynCmd[i], szTerm) < 0
            && containi(g_DynDesc[i], szTerm) < 0)
            continue
        console_print(id, "%s - %s", g_DynCmd[i], g_DynSyntax[i])
        iShown++
    }
    // Fall back to the live AMXX command registry so commands registered by
    // the 69-plugin pack are searchable even when they did not add a custom
    // FreeNova help entry.
    if (iShown == 0)
        PrintRegisteredMatches(id, szTerm, iShown)
    if (id != 0)
    {
        if (iHidden > 0)
            fn_chat_info(id, "Found %d commands (%d need higher rights). Details: amx_cmdhelp <command>.", iShown, iHidden)
        else
            fn_chat_info(id, "Found %d commands. Details: amx_cmdhelp <command>.", iShown)
    }
    else
        console_print(0, "Found %d commands (%d restricted).", iShown, iHidden)
    return PLUGIN_HANDLED
}

public CmdHelpMenu(id, level, cid)
{
    if (id == 0)
    {
        console_print(0, "amx_helpmenu needs a connected player.")
        return PLUGIN_HANDLED
    }
    new iMenu = menu_create("\yFreeNova Help \w- pick a category", "HelpMenuHandler")
    menu_additem(iMenu, "Moderation", "Moderation")
    menu_additem(iMenu, "Admins", "Admins")
    menu_additem(iMenu, "Maps", "Maps")
    menu_additem(iMenu, "Players", "Players")
    menu_additem(iMenu, "Server", "Server")
    menu_additem(iMenu, "Diagnostics", "Diagnostics")
    menu_setprop(iMenu, MPROP_EXIT, MEXIT_ALL)
    menu_display(id, iMenu)
    return PLUGIN_HANDLED
}

public HelpMenuHandler(id, iMenu, iItem)
{
    if (iItem == MENU_EXIT)
    {
        menu_destroy(iMenu)
        return PLUGIN_HANDLED
    }
    new szCat[24], dummy
    menu_item_getinfo(iMenu, iItem, dummy, szCat, charsmax(szCat))
    menu_destroy(iMenu)
    new iShown = 0
    console_print(id, "--- Help: %s ---", szCat)
    for (new i = 0; i < sizeof(g_Static); i++)
    {
        if (!equal(g_Static[i][HE_CAT], szCat))
            continue
        if (!MaySee(id, g_Static[i][HE_FLAGS]))
            continue
        console_print(id, "%s - %s", g_Static[i][HE_CMD], g_Static[i][HE_SYNTAX])
        iShown++
    }
    fn_chat_info(id, "%s commands (%d) were printed in your console.", szCat, iShown)
    return PLUGIN_HANDLED
}

public CmdSayHelp(id)
{
    new szMsg[64]
    read_args(szMsg, charsmax(szMsg))
    // read_args includes the trigger word; skip to first space.
    new iPos = contain(szMsg, " ")
    if (iPos < 0)
    {
        fn_chat_usage(id, "Use: /cmdhelp <command>")
        return PLUGIN_HANDLED
    }
    new szCmd[32]
    copy(szCmd, 31, szMsg[iPos + 1])
    trim(szCmd)
    new szLookup[32]
    copy(szLookup, 31, szCmd[szCmd[0] == '/' ? 1 : 0])
    new i = FindStatic(szLookup)
    if (i < 0)
    {
        new j = FindDyn(szLookup)
        if (j >= 0)
        {
            ShowDetail(id, -1, j)
            return PLUGIN_HANDLED
        }
        fn_chat_error(id, "No help found. Try amx_fnsearch in console.")
        return PLUGIN_HANDLED
    }
    if (!MaySee(id, g_Static[i][HE_FLAGS]))
    {
        fn_chat_permission(id, "You need higher rights to view help for %s.", szCmd)
        return PLUGIN_HANDLED
    }
    ShowDetail(id, i, -1)
    return PLUGIN_HANDLED
}
