#include <amxmodx>
#include <amxmisc>
#include <crxranks>
#include <menabp>
#include <freenova_vip>
#include <freenova_prefs>
#include <freenova_ui>
#include <freenova_missions>
#include <winterfest>   // wf_get_gingerbread - optional core, guarded below

// Persistent stats HUD — GOLDSrc HUD channel (NOT DHUD).
// Steam CS 1.6 ignores DHUD packets, so dhud never appeared on your screen.
// Dedicated channel 3 (not 1, not -1): channel 1 is stolen by auto-channel
// HUDs (adminchat, miscstats, VIP bullet-dmg); channel 2 is scrollmsg.amxx.
// Parked under the radar (x=0.01, y=0.18, tunable via fn_hud_x / fn_hud_y).

#define PLUGIN  "FreeNova Rank HUD"
#define VERSION "3.4"
#define AUTHOR  "FreeNova"

#define TASK_HUD     31200
#define HUD_REFRESH  0.40
#define HUD_CHANNEL  3

new g_iCacheLevel[MAX_PLAYERS + 1]
new g_iCacheXP[MAX_PLAYERS + 1]
new g_iCacheNextXP[MAX_PLAYERS + 1]
new g_iCacheCoins[MAX_PLAYERS + 1]
new g_iCacheGb[MAX_PLAYERS + 1]      // GingerBread, only meaningful while the core is loaded
new bool:g_bCacheWfLoaded[MAX_PLAYERS + 1]
new g_iCacheTier[MAX_PLAYERS + 1]
new g_szCacheRank[MAX_PLAYERS + 1][32]
new bool:g_bCacheLoaded[MAX_PLAYERS + 1]
new bool:g_bCacheBpLoaded[MAX_PLAYERS + 1]

new g_pCvarEnabled
new g_pCvarX
new g_pCvarY
new g_pCvarDebug

public plugin_natives()
{
    set_native_filter("HudNativeFilter")
}

public HudNativeFilter(const name[], index, trap)
{
    if (equal(name, "fnpref_get") || equal(name, "fnpref_set") || equal(name, "fnpref_is_loaded")
        || equal(name, "fnvip_get_tier") || equal(name, "fnvip_get_tier_name_raw")
        || equal(name, "menabp_get_coins")
        || equal(name, "fnmsn_get_track")
        || equal(name, "fnmsn_get_status")
        || equal(name, "fnmsn_get_target")
        || equal(name, "fnmsn_get_daily_progress")
        || equal(name, "fnmsn_get_daily2_progress")
        || equal(name, "fnmsn_get_weekly_progress")
        || equal(name, "fnmsn_get_vip_progress"))
        return PLUGIN_HANDLED
    // Winterfest is optional: a server without winterfest_core must load this
    // HUD unchanged (no GingerBread segment at all), so every wf_* native is
    // trapped here and the one call site is behind LibraryExists.
    if (contain(name, "wf_") == 0 && !LibraryExists("winterfest_core", LibType_Library))
        return PLUGIN_HANDLED
    return PLUGIN_CONTINUE
}

public plugin_init()
{
    register_plugin(PLUGIN, VERSION, AUTHOR)

    register_clcmd("say /hud", "Cmd_Hud")
    register_clcmd("say_team /hud", "Cmd_Hud")
    register_clcmd("say /rankhud", "Cmd_Hud")
    register_clcmd("say_team /rankhud", "Cmd_Hud")

    register_event("ResetHUD", "Event_ResetHUD", "be")

    g_pCvarEnabled = register_cvar("fn_hud_enabled", "1")
    g_pCvarX       = register_cvar("fn_hud_x", "0.01")
    g_pCvarY       = register_cvar("fn_hud_y", "0.18")
    // Debug: log the block that was drawn (0 = silent, the normal case).
    g_pCvarDebug   = register_cvar("fn_hud_debug", "0")

    // Prints the exact block for one player; see Cmd_HudPreview.
    register_concmd("hud_preview", "Cmd_HudPreview", ADMIN_CFG, "<player> - print the rank HUD block to the console")

    set_task(HUD_REFRESH, "Task_RenderHud", TASK_HUD, "", 0, "b")
}

public plugin_end()
{
    remove_task(TASK_HUD)
}

public Cmd_Hud(id)
{
    new iCurrent = 1
    if (fnpref_is_loaded(id))
        iCurrent = fnpref_get(id, FNPREF_RANK_HUD)

    new iNew = iCurrent ? 0 : 1
    if (fnpref_is_loaded(id))
        fnpref_set(id, FNPREF_RANK_HUD, iNew)

    client_print_color(id, print_team_default, "%s Rank HUD > %s", FN_CHAT_PREFIX, iNew ? "ON" : "OFF")
    if (iNew)
        DrawHud(id)
    return PLUGIN_HANDLED
}

public client_putinserver(id)
{
    g_bCacheLoaded[id] = false
    g_iCacheLevel[id] = 0
    g_iCacheXP[id] = 0
    g_iCacheNextXP[id] = 0
    g_iCacheCoins[id] = 0
    g_iCacheGb[id] = 0
    g_bCacheWfLoaded[id] = false
    g_iCacheTier[id] = 0
    g_bCacheBpLoaded[id] = false
    g_szCacheRank[id][0] = 0
    client_cmd(id, "hud_draw 1")
}

public client_disconnected(id)
{
    g_bCacheLoaded[id] = false
    g_bCacheBpLoaded[id] = false
}

public Event_ResetHUD(id)
{
    if (is_user_connected(id) && !is_user_bot(id) && !is_user_hltv(id))
        DrawHud(id)
}

public crxranks_user_loaded(id)
{
    if (is_user_connected(id))
        RefreshCache(id)
}

public crxranks_user_xp_updated(id)
{
    RefreshCache(id)
}

public crxranks_user_level_updated(id, iLevel, bool:bLevelUp)
{
    RefreshCache(id)
}

RefreshCache(id)
{
    if (!(1 <= id <= MaxClients) || !is_user_connected(id))
        return
    if (crxranks_is_user_loaded(id))
    {
        g_iCacheLevel[id] = crxranks_get_user_level(id)
        g_iCacheXP[id] = crxranks_get_user_xp(id)
        g_iCacheNextXP[id] = crxranks_get_user_next_xp(id)
        crxranks_get_user_rank(id, g_szCacheRank[id], charsmax(g_szCacheRank[]))
    }
    g_iCacheCoins[id] = LibraryExists("menabp", LibType_Library) ? menabp_get_coins(id) : 0

    // GingerBread (owner decision §6.7: the Winterfest currency is gb). Same
    // guard as every other optional provider in this file: no core, no segment,
    // and the HUD string below stays exactly what it was before Winterfest.
    new bool:bWf = bool:LibraryExists("winterfest_core", LibType_Library)
    g_bCacheWfLoaded[id] = bWf
    g_iCacheGb[id] = bWf ? wf_get_gingerbread(id) : 0

    // The BattlePass tier is its own ledger: battlepass_core keeps BP XP in the
    // `bpxp` key of the freenova_bp vault and menabp_get_tier() derives the
    // tier from it (REVIEW §2.4 H1; the key exists again as of §9d). It is NOT
    // the RSU/crxranks rank level: rank XP from kills advances Lv, while BP
    // tier only moves when BP XP is granted (missions, admin, web). Deriving
    // BP T from g_iCacheLevel made the HUD show BP T12 as soon as the player
    // hit rank 12.
    g_iCacheTier[id] = 0
    g_bCacheBpLoaded[id] = false
    if (LibraryExists("menabp", LibType_Library) && menabp_is_ready(id))
    {
        g_iCacheTier[id] = menabp_get_tier(id)
        if (g_iCacheTier[id] < 1)
            g_iCacheTier[id] = 1
        if (g_iCacheTier[id] > 60)
            g_iCacheTier[id] = 60
        g_bCacheBpLoaded[id] = true
    }
    g_bCacheLoaded[id] = true
}

public Task_RenderHud()
{
    if (!get_pcvar_num(g_pCvarEnabled))
        return

    new iPlayers[32], iNum
    get_players(iPlayers, iNum, "ch")
    for (new i; i < iNum; i++)
        DrawHud(iPlayers[i])
}

// The whole five-line block, composed into a buffer. Split out from DrawHud so
// `hud_preview` can print exactly what the player would see (the HUD itself only
// draws for a real client - bots have no screen), and so the GingerBread segment
// has one place to live.
FormatHudText(id, szOut[], iLen)
{
    new szBp[16]
    if (g_bCacheBpLoaded[id])
        formatex(szBp, charsmax(szBp), "BP T%d", g_iCacheTier[id])
    else
        copy(szBp, charsmax(szBp), "BP --")

    new szMission[48]
    szMission[0] = 0
    if (LibraryExists("freenova_missions", LibType_Library))
        FormatMissionHud(id, szMission, charsmax(szMission))

    // Wallet line. GingerBread sits next to coins on the SAME line, so the block
    // keeps its five rows and its anchor (x=0.01, y=0.18): the owner likes where
    // it is. Without winterfest_core the line is byte-identical to before
    // ("%d coins"), which is why the segment is built into a buffer first.
    new szWallet[48]
    if (g_bCacheWfLoaded[id])
        formatex(szWallet, charsmax(szWallet), "%d coins  %d gb", g_iCacheCoins[id], g_iCacheGb[id])
    else
        formatex(szWallet, charsmax(szWallet), "%d coins", g_iCacheCoins[id])

    formatex(szOut, iLen, "FreeNova^nLv %d  %s^nXP %d / %d^n%s  %s^n%s%s%s",
        g_iCacheLevel[id],
        g_szCacheRank[id][0] ? g_szCacheRank[id] : "-",
        g_iCacheXP[id],
        g_iCacheNextXP[id] ? g_iCacheNextXP[id] : g_iCacheXP[id],
        szWallet,
        szBp,
        GetStatusLabel(id, fnvip_get_tier(id)),
        szMission[0] ? "^n" : "",
        szMission)
}

public DrawHud(id)
{
    if (!is_user_connected(id) || is_user_bot(id) || is_user_hltv(id))
        return

    if (fnpref_is_loaded(id) && fnpref_get(id, FNPREF_RANK_HUD) == 0)
        return

    // Always refresh: rank level, BP tier and coins load independently, so
    // gating this on crxranks left a stale BP T value after a map change or
    // late battlepass load.
    RefreshCache(id)

    new Float:flX = get_pcvar_float(g_pCvarX)
    new Float:flY = get_pcvar_float(g_pCvarY)

    // Eagle teal (#36DEAB). Dedicated HUD_CHANNEL. Hold longer than the refresh so it never blanks.
    set_hudmessage(54, 222, 171, flX, flY, 0, 0.0, 1.1, 0.0, 0.0, HUD_CHANNEL)

    new szText[256]
    FormatHudText(id, szText, charsmax(szText))

    // fn_hud_debug 1 logs what was drawn (one line per draw: a player can see
    // whether the block they are looking at is the one the server thinks it
    // sent). "%s" + value, never the text as a format.
    if (get_pcvar_num(g_pCvarDebug))
        log_amx("[HUD] id=%d text=%s", id, szText)

    show_hudmessage(id, "%s", szText)
}

// Server console: hud_preview <player>  - prints the exact HUD block for that
// player without drawing it. The block is the same function DrawHud uses, so
// this is the only way to prove the layout for a client the server cannot draw
// on (a bot, or an admin checking a report).
public Cmd_HudPreview(id, level, cid)
{
    if (!cmd_access(id, level, cid, 2))
        return PLUGIN_HANDLED

    new szArg[32]
    read_argv(1, szArg, charsmax(szArg))

    new iTarget = cmd_target(id, szArg, CMDTARGET_ALLOW_SELF)
    if (!iTarget)
        return PLUGIN_HANDLED

    RefreshCache(iTarget)
    new szText[256]
    FormatHudText(iTarget, szText, charsmax(szText))
    console_print(id, "[HUD] id=%d %s", iTarget, szText)
    log_amx("[HUD] preview id=%d text=%s", iTarget, szText)
    return PLUGIN_HANDLED
}

FormatMissionHud(id, szOut[], iLen)
{
    new szTrack[16]
    fnmsn_get_track(id, szTrack, charsmax(szTrack))
    new iGroup = -1, iSlot
    new iColon = contain(szTrack, ":")
    if (iColon >= 0)
    {
        new szLeft[8]
        copy(szLeft, charsmax(szLeft), szTrack)
        szLeft[iColon] = 0
        iGroup = str_to_num(szLeft)
        iSlot = str_to_num(szTrack[iColon + 1])
    }
    if (iGroup < 0)
        return
    new iHave, iNeed = fnmsn_get_target(id, iGroup, iSlot)
    new iSt = fnmsn_get_status(id, iGroup, iSlot)
    if (iGroup == 0)
        iHave = fnmsn_get_daily_progress(id, iSlot)
    else if (iGroup == 1)
        iHave = fnmsn_get_daily2_progress(id, iSlot)
    else if (iGroup == 2)
        iHave = fnmsn_get_weekly_progress(id, iSlot)
    else if (iGroup == 3)
        iHave = fnmsn_get_vip_progress(id)
    else
        return
    if (iSt == 1)
        formatex(szOut, iLen, "Mission READY")
    else if (iSt == 2)
        formatex(szOut, iLen, "Mission claimed")
    else
        formatex(szOut, iLen, "Mission %d/%d", iHave, iNeed)
}

GetStatusLabel(id, iTier)
{
    static szLabel[16]
    // Admin label: AMXX ADMIN_BAN is flag d, part of panel FLAG_ADMIN (cdeijuv).
    if (get_user_flags(id) & ADMIN_BAN)
    {
        copy(szLabel, charsmax(szLabel), "Admin")
        return szLabel
    }
    if (iTier > 0)
    {
        fnvip_get_tier_name_raw(iTier, szLabel, charsmax(szLabel))
        if (szLabel[0])
            return szLabel
    }
    copy(szLabel, charsmax(szLabel), "Member")
    return szLabel
}
