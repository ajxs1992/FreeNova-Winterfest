/*
 * RSU Map End Stats  (rsu_mapend)
 * ============================================================================
 * Auto-shows a compact map-end Top-5 MOTD once per map, plus /mapend and
 * /mapstats say commands for on-demand viewing.
 *
 * Trigger: 5-second repeating task. When mp_timelimit > 0 AND
 * get_timeleft() <= 12 seconds AND the board has not been shown yet on this
 * map, the Top 5 (by kills) board is shown to every human player via
 * show_motd with inline-styled compact HTML (GoldSrc-safe, 620px wide, no
 * external assets) and a log_amx "mapend shown" line is written so the
 * auto-show is testable from the logs.
 *
 * Data comes from the rsu natives (rsu_get_kills/deaths/headshots/xp/level,
 * gated per player by rsu_is_data_loaded and globally by
 * LibraryExists("rsu_core")). Players whose RSU row is not loaded fall back
 * to engine frags/deaths with 0 HS/XP/level so the board still renders.
 *
 * Fail-closed: when the rsu_core library is absent/unloaded the MOTD says
 * "rank data unavailable" and no rsu native is ever called (calling one
 * without its provider would raise a native-not-found error).
 *
 * The shown-flag resets in plugin_cfg (new map). /mapend and /mapstats work
 * at any time and never set the auto-show flag.
 * ============================================================================
 */

#include <amxmodx>
#include <rsu>

#define PLUGIN_NAME     "RSU Map End Stats"
#define PLUGIN_VERSION  "1.0"
#define PLUGIN_AUTHOR   "FreeNova"

#define TASK_MAPEND     77900
#define MAPEND_SECS     12
#define MAPEND_TOP      5
#define MAPEND_HTML     2048

new bool:g_bShown

public plugin_init()
{
    register_plugin(PLUGIN_NAME, PLUGIN_VERSION, PLUGIN_AUTHOR)

    register_clcmd("say /mapend", "Cmd_MapEnd")
    register_clcmd("say_team /mapend", "Cmd_MapEnd")
    register_clcmd("say /mapstats", "Cmd_MapEnd")
    register_clcmd("say_team /mapstats", "Cmd_MapEnd")
}

public plugin_cfg()
{
    // new map: allow one auto-show again; (re)arm the repeating check
    // here (not plugin_init) so it survives map changes
    g_bShown = false
    remove_task(TASK_MAPEND)
    set_task(5.0, "Task_MapEndCheck", TASK_MAPEND, _, _, "b")
}

public Task_MapEndCheck()
{
    if (g_bShown)
        return
    if (get_cvar_num("mp_timelimit") <= 0)
        return
    if (get_timeleft() > MAPEND_SECS)
        return

    g_bShown = true
    ShowMapEnd(0)
}

public Cmd_MapEnd(id)
{
    if (!is_user_connected(id))
        return PLUGIN_HANDLED
    ShowMapEnd(id)
    return PLUGIN_HANDLED
}

// iTarget = 0 -> every human player (auto-show path); else one player
ShowMapEnd(iTarget)
{
    new szHtml[MAPEND_HTML]

    if (!LibraryExists("rsu_core", LibType_Library))
    {
        BuildUnavailable(szHtml, charsmax(szHtml))
    }
    else
    {
        BuildTopBoard(szHtml, charsmax(szHtml))
    }

    if (iTarget == 0)
    {
        new iPlayers[32], iNum
        get_players(iPlayers, iNum, "ch")
        for (new i = 0; i < iNum; i++)
            show_motd(iPlayers[i], szHtml, "Map End Stats")
        log_amx("[RSU][MapEnd] mapend shown to %d player(s)", iNum)
    }
    else
    {
        show_motd(iTarget, szHtml, "Map End Stats")

        new szName[32]
        get_user_name(iTarget, szName, charsmax(szName))
        log_amx("[RSU][MapEnd] mapend shown on demand to %s", szName)
    }
}

BuildUnavailable(szHtml[], iLen)
{
    new szMap[32]
    get_mapname(szMap, charsmax(szMap))

    formatex(szHtml, iLen, "<html><body bgcolor=^"#111622^" text=^"#e8e8e8^"><center><br><br><font color=^"#ffd75e^" size=^"4^"><b>MAP END - %s</b></font><br><br><font color=^"#ff7b7b^">rank data unavailable</font><br><font color=^"#9fb2cc^">rank system is not loaded</font></center></body></html>", szMap)
}

BuildTopBoard(szHtml[], iLen)
{
    new iPlayers[32], iNum
    get_players(iPlayers, iNum, "ch")

    new iKills[32], iDeaths[32], iHs[32], iXp[32], iLevel[32], iOrder[32]
    for (new i = 0; i < iNum; i++)
    {
        new id = iPlayers[i]
        iOrder[i] = i
        if (rsu_is_data_loaded(id))
        {
            iKills[i] = rsu_get_kills(id)
            iDeaths[i] = rsu_get_deaths(id)
            iHs[i] = rsu_get_headshots(id)
            iXp[i] = rsu_get_xp(id)
            iLevel[i] = rsu_get_level(id)
        }
        else
        {
            iKills[i] = get_user_frags(id)
            iDeaths[i] = get_user_deaths(id)
            iHs[i] = 0
            iXp[i] = 0
            iLevel[i] = 0
        }
    }

    // selection: order indices by kills, descending
    for (new a = 0; a < iNum - 1; a++)
    {
        for (new b = a + 1; b < iNum; b++)
        {
            if (iKills[iOrder[b]] > iKills[iOrder[a]])
            {
                new t = iOrder[a]
                iOrder[a] = iOrder[b]
                iOrder[b] = t
            }
        }
    }

    new iTop = (iNum < MAPEND_TOP) ? iNum : MAPEND_TOP

    new szMap[32]
    get_mapname(szMap, charsmax(szMap))

    formatex(szHtml, iLen, "<html><body bgcolor=^"#111622^" text=^"#e8e8e8^"><center><font color=^"#ffd75e^" size=^"4^"><b>MAP END - TOP %d</b></font><br><font color=^"#9fb2cc^">%s</font><br><br><table width=^"620^" border=^"0^" cellpadding=^"4^" cellspacing=^"0^"><tr bgcolor=^"#2a3350^"><td><b>#</b></td><td><b>Name</b></td><td><b>Kills</b></td><td><b>Deaths</b></td><td><b>HS</b></td><td><b>XP</b></td></tr>",
        MAPEND_TOP, szMap)

    new szRow[256], szName[32], szSafe[64]
    for (new r = 0; r < iTop; r++)
    {
        new i = iOrder[r]
        get_user_name(iPlayers[i], szName, charsmax(szName))
        SanitizeName(szName, szSafe, charsmax(szSafe))

        formatex(szRow, charsmax(szRow), "<tr bgcolor=^"%s^"><td>%d</td><td>%s</td><td>%d</td><td>%d</td><td>%d</td><td>%d</td></tr>",
            (r % 2 == 0) ? "#1b2340" : "#232c4e", r + 1, szSafe,
            iKills[i], iDeaths[i], iHs[i], iXp[i])
        add(szHtml, iLen, szRow)
    }

    add(szHtml, iLen, "</table></center></body></html>")
}

// GoldSrc MOTD breaks on raw <>& in names - escape the three characters
SanitizeName(const szIn[], szOut[], iLen)
{
    copy(szOut, iLen, szIn)
    replace_all(szOut, iLen, "&", "&amp;")
    replace_all(szOut, iLen, "<", "&lt;")
    replace_all(szOut, iLen, ">", "&gt;")
}
