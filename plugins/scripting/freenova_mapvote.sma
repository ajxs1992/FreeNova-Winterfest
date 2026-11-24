// ============================================================================
// freenova_mapvote.sma - FreeNova RTV / nominate / votemap map vote
// ----------------------------------------------------------------------------
// Player driven map changing for servers running mp_timelimit 0 (where the
// stock mapchooser never fires, because it only arms itself inside the
// timeleft 1..129 second window).
//
// Commands (chat):
//   /rtv [rtv] [!rtv]                 rock the vote, threshold = fnmapvote_rtv_ratio
//   /nominate [map]  (also /nom)      nominate a map for the next ballot
//   /noms                             list current nominations
//   /votemap [map]                    start a yes/no vote to change right now
//   /votehelp                         command help
//
// Admin commands (fnmapvote_adminflag, default "j" = ADMIN_VOTE):
//   /fnvote        start the map ballot immediately (ignores RTV count/grace)
//   /fnextend      extend the map now (uses amx_extendmap_max/step budget)
//   /fnvotecancel  cancel the running ballot
//   /fnvotereset   clear RTV counters and lift the RTV cooldown
//   server console: fnmapvote <force|extend|cancel|reset|status>
//
// Interop rules (nothing here touches mapchooser / nextmap / timeleft):
//   * amx_last_voting is checked AND set the same way adminvote/mapsmenu do,
//     so stock votes and this plugin queue behind each other and both honour
//     amx_vote_delay (10s).
//   * Ballots are refused inside the stock mapchooser window (timeleft
//     1..130s) so the two never draw a menu at the same time.
//   * amx_nextmap is set to the winner so `say nextmap` stays truthful during
//     the changelevel delay.
//   * extend: mp_timelimit > 0  -> bump mp_timelimit by amx_extendmap_step
//              (stock mapchooser semantics, capped by amx_extendmap_max)
//              mp_timelimit == 0 -> time is infinite, so "extend" locks RTV
//              for amx_extendmap_step minutes instead of starting a timer.
//
// Map list: configs/maps.ini first; if it yields no maps (missing or only
// comments - the shipped file is comments-only) fall back to mapcyclefile
// (mapcycle.txt). Config: configs/freenova/mapvote.ini (auto-created).
// ============================================================================

#include <amxmodx>
#include <amxmisc>
#include <freenova_ui>
#include <fn_common>

#define PLUGIN  "FreeNova MapVote"
#define VERSION "1.0.0"
#define AUTHOR  "FreeNova"

// Ballot layout: up to 5 maps + optional extend + "no change" = 7 keys (1..7)
#define MAX_MAP_SLOTS 5
#define MAX_OPTIONS   7
#define MAX_POOL      64
#define MAX_NOMS      8
#define MAX_NOM_NAME  32

#define VOTE_MENU  "FreeNova MapVote"
#define CFG_REL    "freenova/mapvote.ini"

#define OPT_MAP     0
#define OPT_EXTEND  1
#define OPT_REFUSE  2

#define PICK_NOM     0
#define PICK_VOTEMAP 1

enum VoteKind
{
    VK_NONE = 0,
    VK_RTV,
    VK_RUNOFF,
    VK_VOTEMAP
}

#define TASK_TALLY  7141
#define TASK_RETRY  7142
#define TASK_CHANGE 7143

// fnmapvote_* cvars
new g_pEnabled
new g_pPlayers
new g_pRtvRatio
new g_pRatio
new g_pCooldown
new g_pGrace
new g_pMaxNoms
new g_pAllowExtend
new g_pAdminFlag
new g_pChangeDelay
new g_pRunoff

// map pool
new Array:g_aPool
new g_iPool
new bool:g_bMapsLoaded
new g_szMapSource[64]
new g_szCurrent[32]

// nominations
new g_szNoms[MAX_NOMS][MAX_NOM_NAME]
new g_iNoms

// rock the vote
new bool:g_bRocked[MAX_PLAYERS + 1]
new g_iRockCount
new g_iRockNeed
new Float:g_flMapStart
new Float:g_flRtvUnlock
new bool:g_bRetryPending

// running ballot
new VoteKind:g_iVote
new g_iOptions
new g_iOptType[MAX_OPTIONS]
new g_szOptLabel[MAX_OPTIONS][48]
new g_szOptMap[MAX_OPTIONS][32]
new g_iOptVotes[MAX_OPTIONS]
new bool:g_bVoted[MAX_PLAYERS + 1]
new bool:g_bRunoffDone

// changelevel handoff
new g_szPendingMap[32]

// nomination / votemap picker
new g_iPickMode[MAX_PLAYERS + 1]

// extend budget used this map (minutes)
new g_iExtendMinutes

// ---------------------------------------------------------------------------
// lifecycle
// ---------------------------------------------------------------------------

public plugin_init()
{
    fn_boot_banner("mapvote", 44)

    register_plugin(PLUGIN, VERSION, AUTHOR)

    g_pEnabled     = register_cvar("fnmapvote_enabled",     "1")
    g_pPlayers     = register_cvar("fnmapvote_players",     "2")
    g_pRtvRatio    = register_cvar("fnmapvote_rtv_ratio",   "0.60")
    g_pRatio       = register_cvar("fnmapvote_ratio",       "0.50")
    g_pCooldown    = register_cvar("fnmapvote_cooldown",    "45")
    g_pGrace       = register_cvar("fnmapvote_grace",       "60")
    g_pMaxNoms     = register_cvar("fnmapvote_maxnoms",     "4")
    g_pAllowExtend = register_cvar("fnmapvote_allow_extend", "1")
    g_pAdminFlag   = register_cvar("fnmapvote_adminflag",   "j")
    g_pChangeDelay = register_cvar("fnmapvote_changedelay", "3")
    g_pRunoff      = register_cvar("fnmapvote_runoff",      "1")

    // player chat
    register_clcmd("say /rtv",          "Cmd_Rtv")
    register_clcmd("say_team /rtv",     "Cmd_Rtv")
    register_clcmd("say rtv",           "Cmd_Rtv")
    register_clcmd("say_team rtv",      "Cmd_Rtv")
    register_clcmd("say !rtv",          "Cmd_Rtv")
    register_clcmd("say_team !rtv",     "Cmd_Rtv")

    register_clcmd("say /nominate",     "Cmd_Nominate")
    register_clcmd("say_team /nominate", "Cmd_Nominate")
    register_clcmd("say /nom",          "Cmd_Nominate")
    register_clcmd("say_team /nom",     "Cmd_Nominate")
    register_clcmd("say nominate",      "Cmd_Nominate")
    register_clcmd("say_team nominate", "Cmd_Nominate")

    register_clcmd("say /votemap",      "Cmd_Votemap")
    register_clcmd("say_team /votemap", "Cmd_Votemap")
    register_clcmd("say !votemap",      "Cmd_Votemap")
    register_clcmd("say_team !votemap", "Cmd_Votemap")

    register_clcmd("say /noms",         "Cmd_Noms")
    register_clcmd("say_team /noms",    "Cmd_Noms")
    register_clcmd("say /nomlist",      "Cmd_Noms")
    register_clcmd("say /votehelp",     "Cmd_Help")
    register_clcmd("say_team /votehelp", "Cmd_Help")
    register_clcmd("say /mapvote",      "Cmd_Help")
    register_clcmd("say_team /mapvote", "Cmd_Help")

    // admin gated
    register_clcmd("say /fnvote",       "Cmd_AdminForce")
    register_clcmd("say_team /fnvote",  "Cmd_AdminForce")
    register_clcmd("say /fnextend",     "Cmd_AdminExtend")
    register_clcmd("say_team /fnextend", "Cmd_AdminExtend")
    register_clcmd("say /fnvotecancel", "Cmd_AdminCancel")
    register_clcmd("say_team /fnvotecancel", "Cmd_AdminCancel")
    register_clcmd("say /fnvotereset",  "Cmd_AdminReset")
    register_clcmd("say_team /fnvotereset", "Cmd_AdminReset")
    register_srvcmd("fnmapvote",        "Cmd_Srvcmd")

    // ballot menu (keys 1..7 -> option indexes 0..6)
    register_menucmd(register_menuid(VOTE_MENU), (1 << MAX_OPTIONS) - 1, "BallotKey")

    g_aPool = ArrayCreate(32)
}

public plugin_cfg()
{
    g_flMapStart = get_gametime()
    get_mapname(g_szCurrent, charsmax(g_szCurrent))

    LoadConfig()
    LoadMaps()
    LoadRecent()
}

public plugin_end()
{
    if (g_aPool)
        ArrayDestroy(g_aPool)
}

public client_disconnected(id)
{
    if (g_bRocked[id])
    {
        g_bRocked[id] = false
        if (g_iRockCount > 0)
            g_iRockCount--
    }
    g_bVoted[id] = false
    g_iPickMode[id] = PICK_NOM
}

// ---------------------------------------------------------------------------
// player commands
// ---------------------------------------------------------------------------

public Cmd_Rtv(id)
{
    if (!id || !is_user_connected(id) || is_user_bot(id) || is_user_hltv(id))
        return PLUGIN_HANDLED

    new szMsg[160]
    new szWhy[96]

    if (VoteBlocked(szWhy, charsmax(szWhy), false))
    {
        Reply(id, szWhy)
        return PLUGIN_HANDLED
    }

    new Float:now = get_gametime()
    new Float:graceEnd = g_flMapStart + get_pcvar_float(g_pGrace)
    if (now < graceEnd)
    {
        formatex(szMsg, charsmax(szMsg), \
            "RTV opens %d seconds after map start (%d seconds left).", \
            get_pcvar_num(g_pGrace), floatround(graceEnd - now, floatround_ceil))
        Reply(id, szMsg)
        return PLUGIN_HANDLED
    }

    if (g_bRocked[id])
    {
        new iLeft = g_iRockNeed - g_iRockCount
        if (iLeft > 0)
            formatex(szMsg, charsmax(szMsg), \
                "You already rocked - waiting on %d more player(s) (%d/%d).", \
                iLeft, g_iRockCount, g_iRockNeed)
        else
            formatex(szMsg, charsmax(szMsg), \
                "You already rocked - the vote starts as soon as it can (%d/%d).", \
                g_iRockCount, g_iRockNeed)
        Reply(id, szMsg)
        return PLUGIN_HANDLED
    }

    g_bRocked[id] = true
    g_iRockCount++
    g_iRockNeed = RockNeed()

    if (g_iRockCount >= g_iRockNeed)
    {
        Broadcast("Rock the vote passed! Starting the map vote...")
        TryStartRtvBallot()
    }
    else
    {
        formatex(szMsg, charsmax(szMsg), \
            "%d/%d players want a new map - type /rtv to add yours (%d more needed).", \
            g_iRockCount, g_iRockNeed, g_iRockNeed - g_iRockCount)
        Broadcast(szMsg)
    }
    return PLUGIN_HANDLED
}

public Cmd_Nominate(id)
{
    if (!id || !is_user_connected(id) || is_user_bot(id) || is_user_hltv(id))
        return PLUGIN_HANDLED

    if (!g_bMapsLoaded)
    {
        Reply(id, "Map list is empty - check configs/maps.ini and mapcycle.txt.")
        return PLUGIN_HANDLED
    }

    new szCmd[32], szMap[64]
    Args_Get(szCmd, charsmax(szCmd), szMap, charsmax(szMap))

    if (!szMap[0])
    {
        ShowPickMenu(id, PICK_NOM)
        return PLUGIN_HANDLED
    }

    NominateMap(id, szMap)
    return PLUGIN_HANDLED
}

public Cmd_Votemap(id)
{
    if (!id || !is_user_connected(id) || is_user_bot(id) || is_user_hltv(id))
        return PLUGIN_HANDLED

    new szCmd[32], szMap[64]
    Args_Get(szCmd, charsmax(szCmd), szMap, charsmax(szMap))

    if (!szMap[0])
    {
        if (!g_bMapsLoaded)
        {
            Reply(id, "Map list is empty - check configs/maps.ini and mapcycle.txt.")
            return PLUGIN_HANDLED
        }
        ShowPickMenu(id, PICK_VOTEMAP)
        return PLUGIN_HANDLED
    }

    StartVotemap(id, szMap)
    return PLUGIN_HANDLED
}

public Cmd_Noms(id)
{
    if (!id || !is_user_connected(id))
        return PLUGIN_HANDLED

    if (!g_iNoms)
    {
        Reply(id, "No nominations yet - use /nominate <map> to add one.")
        return PLUGIN_HANDLED
    }

    // One line per nomination. The old single line collected all MAX_NOMS
    // names (8 x up to 31 chars + ", " separators = up to 262 cells) into
    // szList[160]; once that filled, `charsmax(szList) - len` went negative
    // and formatex() ran off the end of the array. A line per nomination also
    // fits inside the ~190-byte chat line limit, which the joined list did not.
    new szMsg[64]
    formatex(szMsg, charsmax(szMsg), "Nominated (%d/%d):", g_iNoms, NominationCap())
    Reply(id, szMsg)

    new szOne[MAX_NOM_NAME + 8]
    for (new i = 0; i < g_iNoms; i++)
    {
        formatex(szOne, charsmax(szOne), "%d. %s", i + 1, g_szNoms[i])
        Reply(id, szOne)
    }
    return PLUGIN_HANDLED
}

public Cmd_Help(id)
{
    if (!id || !is_user_connected(id))
        return PLUGIN_HANDLED

    Reply(id, "/rtv - rock the vote | /nominate <map> - nominate a map | /noms - list nominations")
    Reply(id, "/votemap <map> - vote to change the map right now | /votehelp - this help")
    Reply(id, "Admin: /fnvote /fnextend /fnvotecancel /fnvotereset")
    return PLUGIN_HANDLED
}

// ---------------------------------------------------------------------------
// admin commands (fnmapvote_adminflag) + server console
// ---------------------------------------------------------------------------

public Cmd_AdminForce(id)
{
    if (id && !is_user_connected(id))
        return PLUGIN_HANDLED
    if (!AdminOk(id))
    {
        Reply(id, "You do not have access to this command.")
        return PLUGIN_HANDLED
    }

    new szWhy[96]
    if (VoteBlocked(szWhy, charsmax(szWhy), true))
    {
        Reply(id, szWhy)
        return PLUGIN_HANDLED
    }

    BuildRtvBallot()
    if (CountMapSlots() < 1)
    {
        Reply(id, "Not enough maps available to vote on.")
        return PLUGIN_HANDLED
    }

    g_iVote = VK_RTV
    g_bRunoffDone = false
    ShowBallot("Map Vote")
    AdminLog(id, "forced the map vote")
    return PLUGIN_HANDLED
}

public Cmd_AdminExtend(id)
{
    if (id && !is_user_connected(id))
        return PLUGIN_HANDLED
    if (!AdminOk(id))
    {
        Reply(id, "You do not have access to this command.")
        return PLUGIN_HANDLED
    }

    ExtendNow(id)
    return PLUGIN_HANDLED
}

public Cmd_AdminCancel(id)
{
    if (id && !is_user_connected(id))
        return PLUGIN_HANDLED
    if (!AdminOk(id))
    {
        Reply(id, "You do not have access to this command.")
        return PLUGIN_HANDLED
    }

    if (g_iVote == VK_NONE)
    {
        Reply(id, "No vote is running.")
        return PLUGIN_HANDLED
    }

    remove_task(TASK_TALLY)
    remove_task(TASK_RETRY)
    g_bRetryPending = false
    reset_menu(0)
    g_iVote = VK_NONE
    g_bRunoffDone = false

    // same contract as stock adminvote's amx_cancelvote
    SetLastVoting(get_gametime())
    Broadcast("The running vote was cancelled by an admin.")
    AdminLog(id, "cancelled the vote")
    return PLUGIN_HANDLED
}

public Cmd_AdminReset(id)
{
    if (id && !is_user_connected(id))
        return PLUGIN_HANDLED
    if (!AdminOk(id))
    {
        Reply(id, "You do not have access to this command.")
        return PLUGIN_HANDLED
    }

    ResetRocks()
    g_flRtvUnlock = 0.0
    remove_task(TASK_RETRY)
    g_bRetryPending = false
    Broadcast("RTV counters and cooldown were reset by an admin.")
    AdminLog(id, "reset the RTV state")
    return PLUGIN_HANDLED
}

public Cmd_Srvcmd()
{
    new szCmd[32]
    read_argv(1, szCmd, charsmax(szCmd))

    if (equali(szCmd, "force") || equali(szCmd, "vote"))
        return Cmd_AdminForce(0)
    if (equali(szCmd, "extend"))
        return Cmd_AdminExtend(0)
    if (equali(szCmd, "cancel"))
        return Cmd_AdminCancel(0)
    if (equali(szCmd, "reset"))
        return Cmd_AdminReset(0)
    if (equali(szCmd, "status"))
    {
        console_print(0, "[MapVote] pool=%d (%s) loaded=%d noms=%d rtv=%d/%d vote=%d unlock=%.0f extend=%d/%d", \
            g_iPool, g_szMapSource, g_bMapsLoaded, g_iNoms, g_iRockCount, g_iRockNeed, \
            _:g_iVote, g_flRtvUnlock, g_iExtendMinutes, get_cvar_num("amx_extendmap_max"))
        return PLUGIN_HANDLED
    }

    console_print(0, "usage: fnmapvote <force|extend|cancel|reset|status>")
    return PLUGIN_HANDLED
}

// ---------------------------------------------------------------------------
// nomination
// ---------------------------------------------------------------------------

stock NominateMap(id, const szArg[])
{
    new szMsg[160]
    new szMap[32]
    copy(szMap, charsmax(szMap), szArg)
    trim(szMap)

    if (!NormalizeMapArg(szMap, charsmax(szMap)))
    {
        Reply(id, "Unknown map - check the map name (or use /nominate without an argument).")
        return false
    }

    if (equali(szMap, g_szCurrent))
    {
        Reply(id, "That map is already being played.")
        return false
    }

    for (new i = 0; i < g_iNoms; i++)
    {
        if (equali(g_szNoms[i], szMap))
        {
            Reply(id, "That map is already nominated.")
            return false
        }
    }

    new iCap = NominationCap()
    if (g_iNoms >= iCap)
    {
        formatex(szMsg, charsmax(szMsg), "All %d nomination slots are used - wait for the vote.", iCap)
        Reply(id, szMsg)
        return false
    }

    copy(g_szNoms[g_iNoms], charsmax(g_szNoms[]), szMap)
    g_iNoms++

    formatex(szMsg, charsmax(szMsg), "%s nominated %s (%d/%d nomination slots used).", \
        PlayerName(id), szMap, g_iNoms, iCap)
    Broadcast(szMsg)
    log_amx("[FreeNova MapVote] %s nominated %s", PlayerName(id), szMap)
    return true
}

stock ShowPickMenu(id, mode)
{
    if (!g_bMapsLoaded || g_iPool < 1)
    {
        Reply(id, "Map list is empty - check configs/maps.ini and mapcycle.txt.")
        return
    }

    new szTitle[64]
    if (mode == PICK_VOTEMAP)
        FN_MenuTitle(szTitle, charsmax(szTitle), "Vote to change map")
    else
        FN_MenuTitle(szTitle, charsmax(szTitle), "Nominate a map")

    new menu = menu_create(szTitle, "PickMenuH")
    new szMap[32], szName[64]

    for (new i = 0; i < g_iPool; i++)
    {
        ArrayGetString(g_aPool, i, szMap, charsmax(szMap))
        if (equali(szMap, g_szCurrent))
            continue
        if (mode == PICK_NOM && IsNominated(szMap))
            continue
        formatex(szName, charsmax(szName), "\w%s", szMap)
        menu_additem(menu, szName, szMap)
    }

    if (!menu_items(menu))
    {
        menu_destroy(menu)
        Reply(id, "No other maps are available right now.")
        return
    }

    g_iPickMode[id] = mode
    FN_MenuFinish(menu, false)
    menu_display(id, menu, 0)
}

public PickMenuH(id, menu, item)
{
    if (item == MENU_EXIT)
    {
        menu_destroy(menu)
        return PLUGIN_HANDLED
    }

    new szMap[32], szName[64]
    if (!menu_item_getinfo(menu, item, _, szMap, charsmax(szMap), szName, charsmax(szName)))
    {
        menu_destroy(menu)
        return PLUGIN_HANDLED
    }
    menu_destroy(menu)

    if (!is_user_connected(id))
        return PLUGIN_HANDLED

    if (g_iPickMode[id] == PICK_VOTEMAP)
        StartVotemap(id, szMap)
    else
        NominateMap(id, szMap)

    return PLUGIN_HANDLED
}

// ---------------------------------------------------------------------------
// /votemap ballot
// ---------------------------------------------------------------------------

stock StartVotemap(id, const szArg[])
{
    new szWhy[96], szMsg[160]
    new szMap[32]
    copy(szMap, charsmax(szMap), szArg)
    trim(szMap)

    if (!NormalizeMapArg(szMap, charsmax(szMap)))
    {
        Reply(id, "Unknown map - check the map name (or use /votemap without an argument).")
        return false
    }

    if (equali(szMap, g_szCurrent))
    {
        Reply(id, "That map is already being played.")
        return false
    }

    if (VoteBlocked(szWhy, charsmax(szWhy), false))
    {
        Reply(id, szWhy)
        return false
    }

    ResetOptions()
    new szLabel[48]
    formatex(szLabel, charsmax(szLabel), "Yes - change to %s", szMap)
    AddOption(OPT_MAP, szLabel, szMap)
    AddOption(OPT_REFUSE, "No - keep the current map", "")

    g_iVote = VK_VOTEMAP
    g_bRunoffDone = false

    formatex(szMsg, charsmax(szMsg), "%s started a vote to change the map to %s.", \
        PlayerName(id), szMap)
    Broadcast(szMsg)
    ShowBallot("Votemap")
    return true
}

// ---------------------------------------------------------------------------
// ballot
// ---------------------------------------------------------------------------

stock bool:VoteBlocked(szWhy[], len, bool:bAdmin)
{
    if (!get_pcvar_num(g_pEnabled))
    {
        copy(szWhy, len, "Map votes are disabled on this server.")
        return true
    }

    if (g_iVote != VK_NONE)
    {
        copy(szWhy, len, "A vote is already running - wait for it to finish.")
        return true
    }

    if (!g_bMapsLoaded || g_iPool < 1)
    {
        copy(szWhy, len, "Map list is empty - check configs/maps.ini and mapcycle.txt.")
        return true
    }

    new Float:now = get_gametime()
    new Float:unlock = VoteUnlockTime()
    if (now < unlock)
    {
        formatex(szWhy, len, "Please wait %d seconds before starting the next vote (amx_vote_delay).", \
            floatround(unlock - now, floatround_ceil))
        return true
    }

    if (bAdmin)
        return false

    if (now < g_flRtvUnlock)
    {
        formatex(szWhy, len, "Voting is locked for another %d seconds.", \
            floatround(g_flRtvUnlock - now, floatround_ceil))
        return true
    }

    new players[32], pnum
    get_players(players, pnum, "ch")
    if (pnum < get_pcvar_num(g_pPlayers))
    {
        formatex(szWhy, len, "Need at least %d player(s) to vote (%d online).", \
            get_pcvar_num(g_pPlayers), pnum)
        return true
    }

    // stock mapchooser owns the last ~2 minutes of a timed map
    new iTimeLeft = get_timeleft()
    if (iTimeLeft >= 1 && iTimeLeft <= 130)
    {
        copy(szWhy, len, "The map is about to change on its own - the stock mapchooser owns this window.")
        return true
    }

    return false
}

stock TryStartRtvBallot()
{
    new szWhy[96]
    if (VoteBlocked(szWhy, charsmax(szWhy), false))
    {
        new Float:now = get_gametime()
        new Float:unlock = VoteUnlockTime()
        if (g_iVote == VK_NONE && now < unlock && !g_bRetryPending)
        {
            g_bRetryPending = true
            set_task(unlock - now + 0.5, "Task_RetryRtv", TASK_RETRY)
            Broadcast("The map vote will start as soon as the vote delay ends.")
            return false
        }
        Broadcast(szWhy)
        return false
    }

    BuildRtvBallot()

    if (CountMapSlots() < 1)
    {
        Broadcast("Not enough maps are available to vote on.")
        return false
    }

    g_iVote = VK_RTV
    g_bRunoffDone = false
    ShowBallot("Map Vote")
    return true
}

public Task_RetryRtv()
{
    g_bRetryPending = false

    if (g_iRockCount < g_iRockNeed)
        return PLUGIN_HANDLED
    // Vote still running (e.g. admin forced one during the delay wait):
    // re-arm instead of dropping the retry so rocks are not silently lost.
    if (g_iVote != VK_NONE)
    {
        if (!g_bRetryPending)
        {
            g_bRetryPending = true
            set_task(5.0, "Task_RetryRtv", TASK_RETRY)
        }
        return PLUGIN_HANDLED
    }

    TryStartRtvBallot()
    return PLUGIN_HANDLED
}

// recent maps (persisted across map changes so ballots don't repeat)
new g_szRecent[2][32]
#define RECENT_FILE "freenova/mapvote_recent.ini"

stock BuildRtvBallot()
{
    ResetOptions()

    // nominations always make the ballot
    for (new i = 0; i < g_iNoms && CountMapSlots() < MAX_MAP_SLOTS; i++)
        AddMapSlot(g_szNoms[i])

    // fill the remaining slots with a shuffled pass over the pool,
    // skipping current + the last 2 played maps (no instant repeats)
    new iIdx[MAX_POOL], iN = 0
    new szMap[32]

    for (new i = 0; i < g_iPool && iN < MAX_POOL; i++)
    {
        ArrayGetString(g_aPool, i, szMap, charsmax(szMap))
        if (equali(szMap, g_szCurrent))
            continue
        if ((g_szRecent[0][0] && equali(szMap, g_szRecent[0]))
            || (g_szRecent[1][0] && equali(szMap, g_szRecent[1])))
            continue
        iIdx[iN++] = i
    }

    for (new i = iN - 1; i > 0; i--)
    {
        new j = random_num(0, i)
        new tmp = iIdx[i]
        iIdx[i] = iIdx[j]
        iIdx[j] = tmp
    }

    for (new i = 0; i < iN && CountMapSlots() < MAX_MAP_SLOTS; i++)
    {
        ArrayGetString(g_aPool, iIdx[i], szMap, charsmax(szMap))
        AddMapSlot(szMap)
    }

    if (ExtendAvailable())
    {
        new szLabel[48]
        formatex(szLabel, charsmax(szLabel), "Extend +%d min (%d/%d used)",
            ExtendStep(), g_iExtendMinutes, ExtendMax())
        AddOption(OPT_EXTEND, szLabel, "")
    }

    AddOption(OPT_REFUSE, "No change", "")
}

stock LoadRecent()
{
    g_szRecent[0][0] = 0
    g_szRecent[1][0] = 0
    new szConfigs[96], szFile[192]
    get_localinfo("amxx_configsdir", szConfigs, charsmax(szConfigs))
    formatex(szFile, charsmax(szFile), "%s/%s", szConfigs, RECENT_FILE)
    if (!file_exists(szFile))
        return
    new fp = fopen(szFile, "r")
    if (!fp)
        return
    new szLine[64], i
    while (fgets(fp, szLine, charsmax(szLine)) && i < 2)
    {
        trim(szLine)
        if (!szLine[0] || szLine[0] == ';' || szLine[0] == '#')
            continue
        copy(g_szRecent[i], charsmax(g_szRecent[]), szLine)
        i++
    }
    fclose(fp)
}

stock SaveRecent(const szMap[])
{
    copy(g_szRecent[1], charsmax(g_szRecent[]), g_szRecent[0])
    copy(g_szRecent[0], charsmax(g_szRecent[]), szMap)
    new szConfigs[96], szFile[192]
    get_localinfo("amxx_configsdir", szConfigs, charsmax(szConfigs))
    formatex(szFile, charsmax(szFile), "%s/%s", szConfigs, RECENT_FILE)
    new fp = fopen(szFile, "w")
    if (!fp)
        return
    if (g_szRecent[0][0])
        fprintf(fp, "%s^n", g_szRecent[0])
    if (g_szRecent[1][0])
        fprintf(fp, "%s^n", g_szRecent[1])
    fclose(fp)
}

stock BuildRunoff(iBest, iSecond)
{
    new szLabel[2][48], szMap[2][32], iType[2]

    copy(szLabel[0], charsmax(szLabel[]), g_szOptLabel[iBest])
    copy(szLabel[1], charsmax(szLabel[]), g_szOptLabel[iSecond])
    copy(szMap[0], charsmax(szMap[]), g_szOptMap[iBest])
    copy(szMap[1], charsmax(szMap[]), g_szOptMap[iSecond])
    iType[0] = g_iOptType[iBest]
    iType[1] = g_iOptType[iSecond]

    ResetOptions()
    AddOption(iType[0], szLabel[0], szMap[0])
    AddOption(iType[1], szLabel[1], szMap[1])

    if (iType[0] != OPT_REFUSE && iType[1] != OPT_REFUSE)
        AddOption(OPT_REFUSE, "No change", "")

    g_iVote = VK_RUNOFF
    g_bRunoffDone = true
}

stock ShowBallot(const szTitle[])
{
    new szBody[512]
    new len = formatex(szBody, charsmax(szBody), "\yFreeNova | %s\w^n^n", szTitle)

    for (new i = 0; i < g_iOptions; i++)
        len += formatex(szBody[len], charsmax(szBody) - len, "%d. %s^n", i + 1, g_szOptLabel[i])

    new Float:vlen = get_cvar_float("amx_vote_time")
    if (vlen < 5.0)
        vlen = 5.0
    if (vlen > 60.0)
        vlen = 60.0

    for (new i = 0; i <= MAX_PLAYERS; i++)
        g_bVoted[i] = false

    // stock vote lock, same formula adminvote/mapsmenu use
    SetLastVoting(get_gametime() + vlen)

    show_menu(0, (1 << g_iOptions) - 1, szBody, floatround(vlen, floatround_ceil), VOTE_MENU)
    set_task(vlen, "Task_Tally", TASK_TALLY)

    new szMsg[160]
    formatex(szMsg, charsmax(szMsg), "Vote started: %s - pick an option within %d seconds.", \
        szTitle, floatround(vlen, floatround_ceil))
    Broadcast(szMsg)
    log_amx("[FreeNova MapVote] %s ballot started (%d options)", szTitle, g_iOptions)
}

public BallotKey(id, key)
{
    if (g_iVote == VK_NONE)
        return PLUGIN_HANDLED
    if (id < 1 || id > MAX_PLAYERS || !is_user_connected(id) || is_user_bot(id) || is_user_hltv(id))
        return PLUGIN_HANDLED
    if (key < 0 || key >= g_iOptions)
        return PLUGIN_HANDLED
    if (g_bVoted[id])
        return PLUGIN_HANDLED

    g_bVoted[id] = true
    g_iOptVotes[key]++

    if (get_cvar_num("amx_vote_answers"))
    {
        new szMsg[160]
        formatex(szMsg, charsmax(szMsg), "%s voted: %s", PlayerName(id), g_szOptLabel[key])
        Broadcast(szMsg)
    }
    return PLUGIN_HANDLED
}

public Task_Tally()
{
    if (g_iVote == VK_NONE)
        return PLUGIN_HANDLED

    new VoteKind:kVote = g_iVote
    new szMsg[192]

    new iCast = 0, iBest = 0, iSecond = -1
    for (new i = 0; i < g_iOptions; i++)
        iCast += g_iOptVotes[i]

    for (new i = 1; i < g_iOptions; i++)
        if (g_iOptVotes[i] > g_iOptVotes[iBest])
            iBest = i

    for (new i = 0; i < g_iOptions; i++)
        if (i != iBest && (iSecond == -1 || g_iOptVotes[i] > g_iOptVotes[iSecond]))
            iSecond = i

    new Float:fRatio
    if (kVote == VK_VOTEMAP)
    {
        fRatio = get_cvar_float("amx_votemap_ratio")
        if (fRatio <= 0.0)
            fRatio = 0.40
    }
    else
    {
        fRatio = get_pcvar_float(g_pRatio)
        if (fRatio <= 0.0)
            fRatio = 0.50
    }

    new iNeeded = 1
    if (iCast > 0)
        iNeeded = floatround(fRatio * float(iCast), floatround_ceil)
    if (iNeeded < 1)
        iNeeded = 1

    new bool:bUsable = (g_iOptType[iBest] != OPT_REFUSE)
    new bool:bPlural = (iSecond == -1 || g_iOptVotes[iBest] > g_iOptVotes[iSecond])
    new bool:bPass = (iCast > 0 && g_iOptVotes[iBest] >= iNeeded && bUsable && bPlural)

    if (bPass)
        formatex(szMsg, charsmax(szMsg), "Vote passed: %s - %d of %d votes (needed %d).", \
            g_szOptLabel[iBest], g_iOptVotes[iBest], iCast, iNeeded)
    else
        formatex(szMsg, charsmax(szMsg), "Vote failed: %s - %d of %d votes (needed %d).", \
            g_szOptLabel[iBest], g_iOptVotes[iBest], iCast, iNeeded)
    Broadcast(szMsg)

    log_amx("[FreeNova MapVote] %s vote finished: best='%s' votes=%d cast=%d needed=%d pass=%d", \
        kVote == VK_VOTEMAP ? "votemap" : (kVote == VK_RUNOFF ? "runoff" : "rtv"), \
        g_szOptLabel[iBest], g_iOptVotes[iBest], iCast, iNeeded, bPass)

    if (bPass && g_iOptType[iBest] == OPT_EXTEND)
    {
        g_iVote = VK_NONE
        ResetVotes()
        ExtendNow(0)
        return PLUGIN_HANDLED
    }

    if (bPass && g_iOptType[iBest] == OPT_MAP)
    {
        copy(g_szPendingMap, charsmax(g_szPendingMap), g_szOptMap[iBest])
        g_iVote = VK_NONE
        ResetRocks()
        g_bRunoffDone = false

        if (cvar_exists("amx_nextmap"))
            set_cvar_string("amx_nextmap", g_szPendingMap)

        new iDelay = get_pcvar_num(g_pChangeDelay)
        if (iDelay < 0)
            iDelay = 0

        formatex(szMsg, charsmax(szMsg), "Changing to %s in %d seconds...", g_szPendingMap, iDelay)
        Broadcast(szMsg)
        log_amx("[FreeNova MapVote] winner '%s' -> changelevel %s", g_szPendingMap, g_szPendingMap)

        if (iDelay == 0)
            Task_Change()
        else
            set_task(float(iDelay), "Task_Change", TASK_CHANGE)
        return PLUGIN_HANDLED
    }

    // failed - one runoff between the top two options
    if (kVote == VK_RTV && !g_bRunoffDone && get_pcvar_num(g_pRunoff) \
        && iCast >= 2 && iSecond != -1 && g_iOptVotes[iSecond] > 0)
    {
        BuildRunoff(iBest, iSecond)
        ShowBallot("Runoff Vote")
        return PLUGIN_HANDLED
    }

    g_iVote = VK_NONE
    ResetRocks()
    g_bRunoffDone = false
    g_flRtvUnlock = get_gametime() + get_pcvar_float(g_pCooldown)

    formatex(szMsg, charsmax(szMsg), "No map change - RTV and /votemap reopen in %d seconds.", \
        get_pcvar_num(g_pCooldown))
    Broadcast(szMsg)
    log_amx("[FreeNova MapVote] vote failed, cooldown %d seconds", get_pcvar_num(g_pCooldown))
    return PLUGIN_HANDLED
}

public Task_Change()
{
    if (!g_szPendingMap[0])
        return PLUGIN_HANDLED

    if (!SafeMapName(g_szPendingMap) || !is_map_valid(g_szPendingMap))
    {
        log_amx("[FreeNova MapVote] refused changelevel to unsafe/unknown map '%s'", g_szPendingMap)
        g_szPendingMap[0] = 0
        return PLUGIN_HANDLED
    }

    SaveRecent(g_szPendingMap)
    server_cmd("changelevel %s", g_szPendingMap)
    return PLUGIN_HANDLED
}

// ---------------------------------------------------------------------------
// extend
// ---------------------------------------------------------------------------

stock ExtendStep()
{
    new iStep = get_cvar_num("amx_extendmap_step")
    if (iStep < 1)
        iStep = 15
    return iStep
}

stock ExtendMax()
{
    new iMax = get_cvar_num("amx_extendmap_max")
    if (iMax < 1)
        iMax = 90
    return iMax
}

stock bool:ExtendAvailable()
{
    if (!get_pcvar_num(g_pAllowExtend))
        return false

    new iStep = ExtendStep()
    new iMax = ExtendMax()

    if (g_iExtendMinutes + iStep > iMax)
        return false

    new Float:fTl = get_cvar_float("mp_timelimit")
    if (fTl > 0.0)
    {
        // timed map: same guard stock mapchooser uses
        if (fTl >= float(iMax))
            return false
        if (get_cvar_num("mp_winlimit") || get_cvar_num("mp_maxrounds"))
            return false
    }
    return true
}

stock bool:ExtendNow(id)
{
    if (!ExtendAvailable())
    {
        new szMsg[128]
        formatex(szMsg, charsmax(szMsg), "No extension budget left (amx_extendmap_max %d min).", ExtendMax())
        Reply(id, szMsg)
        return false
    }

    new iStep = ExtendStep()
    new iMax = ExtendMax()
    new Float:fTl = get_cvar_float("mp_timelimit")
    new szMsg[160]

    g_iExtendMinutes += iStep

    if (fTl > 0.0)
    {
        set_cvar_float("mp_timelimit", fTl + iStep)
        formatex(szMsg, charsmax(szMsg), "Map extended by %d minutes (mp_timelimit now %.0f).", \
            iStep, fTl + iStep)
    }
    else
    {
        // mp_timelimit 0: never start a timer, lock RTV for the step instead
        g_flRtvUnlock = get_gametime() + iStep * 60.0
        formatex(szMsg, charsmax(szMsg), \
            "Map extended - no time limit is set, so RTV is locked for the next %d minutes.", iStep)
    }

    Broadcast(szMsg)
    ResetRocks()
    g_bRunoffDone = false
    log_amx("[FreeNova MapVote] %s extended the map by %d min (%d/%d used)", \
        PlayerName(id), iStep, g_iExtendMinutes, iMax)
    return true
}

// ---------------------------------------------------------------------------
// map list + config
// ---------------------------------------------------------------------------

stock LoadMaps()
{
    if (g_aPool)
        ArrayClear(g_aPool)
    g_iPool = 0
    g_bMapsLoaded = false
    g_szMapSource[0] = 0

    get_mapname(g_szCurrent, charsmax(g_szCurrent))

    new szConfigs[96], szFile[192]
    get_localinfo("amxx_configsdir", szConfigs, charsmax(szConfigs))
    formatex(szFile, charsmax(szFile), "%s/maps.ini", szConfigs)

    ReadMapFile(szFile)

    if (g_iPool > 0)
    {
        copy(g_szMapSource, charsmax(g_szMapSource), "configs/maps.ini")
    }
    else
    {
        new szCycle[64]
        get_cvar_string("mapcyclefile", szCycle, charsmax(szCycle))
        if (!szCycle[0])
            copy(szCycle, charsmax(szCycle), "mapcycle.txt")

        ReadMapFile(szCycle)

        if (g_iPool > 0)
        {
            copy(g_szMapSource, charsmax(g_szMapSource), szCycle)
        }
        else if (!equali(szCycle, "mapcycle.txt"))
        {
            ReadMapFile("mapcycle.txt")
            if (g_iPool > 0)
                copy(g_szMapSource, charsmax(g_szMapSource), "mapcycle.txt")
        }
    }

    if (g_iPool > 0)
    {
        g_bMapsLoaded = true
        log_amx("[FreeNova MapVote] map pool: %d maps from %s (current %s)", \
            g_iPool, g_szMapSource, g_szCurrent)
    }
    else
    {
        copy(g_szMapSource, charsmax(g_szMapSource), "none")
        log_amx("[FreeNova MapVote] ERROR: no maps in maps.ini or mapcycle.txt - RTV disabled")
    }
}

stock ReadMapFile(const szFile[])
{
    if (!file_exists(szFile))
        return 0

    new fp = fopen(szFile, "r")
    if (!fp)
        return 0

    new szLine[128], szMap[64]
    while (fgets(fp, szLine, charsmax(szLine)))
    {
        trim(szLine)
        if (!szLine[0])
            continue
        if (szLine[0] == ';' || szLine[0] == '#' || szLine[0] == '/')
            continue

        szMap[0] = 0
        parse(szLine, szMap, charsmax(szMap))
        trim(szMap)
        if (!szMap[0] || !SafeMapName(szMap))
            continue

        if (FindPool(szMap) != -1)
            continue
        if (!is_map_valid(szMap))
            continue

        ArrayPushString(g_aPool, szMap)
        g_iPool++
    }
    fclose(fp)
    return g_iPool
}

stock LoadConfig()
{
    new szConfigs[96], szCfg[192]
    get_localinfo("amxx_configsdir", szConfigs, charsmax(szConfigs))
    formatex(szCfg, charsmax(szCfg), "%s/%s", szConfigs, CFG_REL)

    if (!file_exists(szCfg))
        WriteDefaultConfig(szCfg)

    new fp = fopen(szCfg, "r")
    if (!fp)
    {
        log_amx("[FreeNova MapVote] could not read %s - built-in defaults used", szCfg)
        return 0
    }

    new szLine[128], szKey[64], szVal[64]
    new iSet = 0

    while (fgets(fp, szLine, charsmax(szLine)))
    {
        trim(szLine)
        if (!szLine[0] || szLine[0] == ';' || szLine[0] == '/' || szLine[0] == '#')
            continue

        szKey[0] = 0
        szVal[0] = 0
        parse(szLine, szKey, charsmax(szKey), szVal, charsmax(szVal))
        trim(szKey)
        trim(szVal)

        if (!szKey[0] || !szVal[0])
            continue
        // only this plugin's own cvars are ever set from the file
        if (!equali(szKey, "fnmapvote_", 10))
            continue
        if (!cvar_exists(szKey))
            continue

        // strip optional quotes
        new len = strlen(szVal)
        if (len >= 2 && szVal[0] == '"' && szVal[len - 1] == '"')
        {
            szVal[len - 1] = 0
            copy(szVal, charsmax(szVal), szVal[1])
        }

        set_cvar_string(szKey, szVal)
        iSet++
    }
    fclose(fp)

    log_amx("[FreeNova MapVote] loaded %d settings from %s", iSet, szCfg)
    return iSet
}

stock WriteDefaultConfig(const szCfg[])
{
    new fp = fopen(szCfg, "w")
    if (!fp)
    {
        log_amx("[FreeNova MapVote] could not create %s", szCfg)
        return
    }

    fprintf(fp, "; FreeNova MapVote - RTV / nominate / votemap settings^n")
    fprintf(fp, "; Loaded by freenova_mapvote.amxx on every map start. Change map to apply.^n")
    fprintf(fp, "; Only fnmapvote_* keys are read from this file.^n^n")
    fprintf(fp, "; 1 = plugin on, 0 = off (RTV / nominate / votemap all dead)^n")
    fprintf(fp, "fnmapvote_enabled 1^n^n")
    fprintf(fp, "; minimum human players before a vote can run^n")
    fprintf(fp, "fnmapvote_players 2^n^n")
    fprintf(fp, "; share of humans that must type /rtv before the ballot starts^n")
    fprintf(fp, "fnmapvote_rtv_ratio 0.60^n^n")
    fprintf(fp, "; share of cast votes the winning option needs (runoff ballots)^n")
    fprintf(fp, "fnmapvote_ratio 0.50^n^n")
    fprintf(fp, "; seconds RTV / votemap stay locked after a failed vote^n")
    fprintf(fp, "fnmapvote_cooldown 45^n^n")
    fprintf(fp, "; seconds after map start before RTV unlocks^n")
    fprintf(fp, "fnmapvote_grace 60^n^n")
    fprintf(fp, "; maximum simultaneous nominations (max 8)^n")
    fprintf(fp, "fnmapvote_maxnoms 4^n^n")
    fprintf(fp, "; offer / count an extend option in the ballot^n")
    fprintf(fp, "fnmapvote_allow_extend 1^n^n")
    fprintf(fp, "; admin access flag for /fnvote /fnextend /fnvotecancel /fnvotereset^n")
    fprintf(fp, "; a=immunity b=reservation c=kick d=ban e=slay f=map g=cvar h=cfg i=chat j=vote^n")
    fprintf(fp, "fnmapvote_adminflag ^"j^"^n^n")
    fprintf(fp, "; seconds between the result and the changelevel^n")
    fprintf(fp, "fnmapvote_changedelay 3^n^n")
    fprintf(fp, "; 1 = one runoff ballot between the top two options if the first fails^n")
    fprintf(fp, "fnmapvote_runoff 1^n")
    fclose(fp)

    log_amx("[FreeNova MapVote] created config %s", szCfg)
}

// ---------------------------------------------------------------------------
// state helpers
// ---------------------------------------------------------------------------

stock ResetOptions()
{
    g_iOptions = 0
    for (new i = 0; i < MAX_OPTIONS; i++)
    {
        g_iOptType[i] = OPT_MAP
        g_szOptLabel[i][0] = 0
        g_szOptMap[i][0] = 0
        g_iOptVotes[i] = 0
    }
}

stock ResetVotes()
{
    for (new i = 0; i < MAX_OPTIONS; i++)
        g_iOptVotes[i] = 0
}

stock AddOption(type, const szLabel[], const szMap[])
{
    if (g_iOptions >= MAX_OPTIONS)
        return false

    g_iOptType[g_iOptions] = type
    copy(g_szOptLabel[g_iOptions], charsmax(g_szOptLabel[]), szLabel)
    copy(g_szOptMap[g_iOptions], charsmax(g_szOptMap[]), szMap)
    g_iOptVotes[g_iOptions] = 0
    g_iOptions++
    return true
}

stock AddMapSlot(const szMap[])
{
    if (CountMapSlots() >= MAX_MAP_SLOTS)
        return false
    if (!SafeMapName(szMap))
        return false
    if (equali(szMap, g_szCurrent))
        return false

    for (new i = 0; i < g_iOptions; i++)
        if (g_iOptType[i] == OPT_MAP && equali(g_szOptMap[i], szMap))
            return false

    return AddOption(OPT_MAP, szMap, szMap)
}

stock CountMapSlots()
{
    new n = 0
    for (new i = 0; i < g_iOptions; i++)
        if (g_iOptType[i] == OPT_MAP)
            n++
    return n
}

stock ResetRocks()
{
    for (new i = 0; i <= MAX_PLAYERS; i++)
        g_bRocked[i] = false
    g_iRockCount = 0
    g_iRockNeed = 0
}

stock RockNeed()
{
    new players[32], pnum
    get_players(players, pnum, "ch")

    new need = floatround(get_pcvar_float(g_pRtvRatio) * float(pnum), floatround_ceil)
    if (need < 1)
        need = 1
    return need
}

stock NominationCap()
{
    new cap = get_pcvar_num(g_pMaxNoms)
    if (cap < 1)
        cap = 1
    if (cap > MAX_NOMS)
        cap = MAX_NOMS
    return cap
}

stock FindPool(const szMap[])
{
    new szOne[32]
    for (new i = 0; i < g_iPool; i++)
    {
        ArrayGetString(g_aPool, i, szOne, charsmax(szOne))
        if (equali(szOne, szMap))
            return i
    }
    return -1
}

stock IsNominated(const szMap[])
{
    for (new i = 0; i < g_iNoms; i++)
        if (equali(g_szNoms[i], szMap))
            return true
    return false
}

stock bool:AdminOk(id)
{
    if (!id)
        return true

    new szFlag[32]
    get_pcvar_string(g_pAdminFlag, szFlag, charsmax(szFlag))
    if (!szFlag[0])
        return false

    return has_flag(id, szFlag) ? true : false
}

stock AdminLog(id, const szWhat[])
{
    if (id)
        log_amx("[FreeNova MapVote] admin %s (%s) %s", PlayerName(id), PlayerAuth(id), szWhat)
    else
        log_amx("[FreeNova MapVote] server console %s", szWhat)
}

stock PlayerName(id)
{
    static szName[MAX_NAME_LENGTH]
    szName[0] = 0
    if (id && is_user_connected(id))
        get_user_name(id, szName, charsmax(szName))
    else
        copy(szName, charsmax(szName), "console")
    return szName
}

stock PlayerAuth(id)
{
    static szAuth[40]
    szAuth[0] = 0
    if (id && is_user_connected(id))
        get_user_authid(id, szAuth, charsmax(szAuth))
    return szAuth
}

stock Broadcast(const szMsg[])
{
    client_print_color(0, print_team_default, "%s %s", FN_CHAT_PREFIX, szMsg)
}

stock Reply(id, const szMsg[])
{
    if (id)
        client_print_color(id, print_team_default, "%s %s", FN_CHAT_PREFIX, szMsg)
    else
        console_print(0, "[FreeNova MapVote] %s", szMsg)
}

// full say text -> command token + the rest ("/nominate de_dust2")
stock Args_Get(szCmd[], iCmdLen, szRest[], iRestLen)
{
    szCmd[0] = 0
    szRest[0] = 0

    new szFull[192]
    read_args(szFull, charsmax(szFull))
    remove_quotes(szFull)
    trim(szFull)

    if (!szFull[0])
        return

    parse(szFull, szCmd, iCmdLen, szRest, iRestLen)
    trim(szCmd)
    trim(szRest)
}

// trim + strip a trailing .bsp, then require a real, safe map name
stock bool:NormalizeMapArg(szMap[], len)
{
    trim(szMap)
    if (!szMap[0])
        return false

    // work on a copy so the caller's buffer bound stays the only write target
    new szClean[32]
    copy(szClean, charsmax(szClean), szMap)

    new iLen = strlen(szClean)
    if (iLen > 4 && equali(szClean[iLen - 4], ".bsp"))
    {
        szClean[iLen - 4] = 0
        trim(szClean)
    }

    if (!SafeMapName(szClean))
        return false
    if (!is_map_valid(szClean))
        return false

    copy(szMap, len, szClean)
    return true
}

// charset guard - also what keeps map names out of changelevel injection
stock bool:SafeMapName(const szMap[])
{
    new iLen = strlen(szMap)
    if (iLen < 1 || iLen > 31)
        return false

    for (new i = 0; i < iLen; i++)
    {
        new c = szMap[i]
        if (c >= 'a' && c <= 'z')
            continue
        if (c >= 'A' && c <= 'Z')
            continue
        if (c >= '0' && c <= '9')
            continue
        if (c == '_')
            continue
        return false
    }
    return true
}

stock SetLastVoting(Float:value)
{
    if (cvar_exists("amx_last_voting"))
        set_cvar_float("amx_last_voting", value)
}

stock Float:VoteUnlockTime()
{
    if (!cvar_exists("amx_last_voting"))
        return 0.0

    new Float:last = get_cvar_float("amx_last_voting")
    if (last <= 0.0)
        return 0.0

    return last + get_cvar_float("amx_vote_delay")
}
