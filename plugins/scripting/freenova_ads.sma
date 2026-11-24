// FreeNova Ads - scheduled advertisement rotator (chat + HUD).
//
// Clean replacement for the dormant GHW_Message_Disp.sma (2008, lives in the
// live tree's scripting/ but is NOT loaded and never was here): that plugin
// mixed cur_textmessage into the HUD color lookups (visible bug), used auto
// HUD channel (-1, collides with anything), had no admin reload, no cvar
// re-read after boot, and a fragile inline tag parser over fixed arrays.
// Rejected: do not resurrect it.
//
// Coexistence - keep these stock/FreeNova plugins loaded until cutover
// (this plugin never disables them, never touches their cvars):
//   scrollmsg.amxx   HUD channel 2, y 0.90, every amx_scrollmsg (600s),
//                    re-renders every 0.3s while scrolling => wins any overlap
//   imessage.amxx    auto HUD channel, y 0.20, every amx_freq_imessage (180s)
//   freenova_hud     HUD channel 3, x 0.01 / y 0.18 (never use channel 3)
//   ReGameDLL MVP    engine-owned text at -1.0 / 0.22 (never use that spot)
//   mapchooser / nextmap / timeleft - untouched
//
// HUD channel default 1 (fnads_channel clamps to 1..2): channel 2 is the
// MVP-fanfare channel (freenova_roundmusic, rare 4s) plus scrollmsg's 600s
// window, so ads live on 1 to never stomp the MVP moment. Channel 1 is
// shared-transient (adminchat / miscstats / VIP bullet-dmg per the
// freenova_hud.sma header): an ad may flicker during heavy fights and
// self-heals on the next 90s rotation. Set fnads_channel 2 to revert.
//
// Constraints honored: AMXX 1.10 API only, no Fun module, no menabp_* calls
// (therefore no LibraryExists guard is required - the call site does not
// exist), no nVault: rotation state is in-memory and this plugin NEVER opens
// freenova_bp (or any vault - if persistence is ever needed, use a dedicated
// "freenova_ads" vault, never the battlepass one).
//
// Extension points: fnads_* cvar namespace (free), config-driven ad list in
// configs/freenova/ads.ini (per-map groups / per-ad priority flags can be
// added to the parser without touching rotation logic), fnads_reload hook for
// ops automation. Billing/analytics/auth do not apply to this plugin.

#include <amxmodx>
#include <amxmisc>
#include <freenova_ui>
#include <fn_common>

#define PLUGIN_NAME     "FreeNova Ads"
#define PLUGIN_VERSION  "1.0"
#define PLUGIN_AUTHOR   "FreeNova"

#define CONFIG_FILE     "freenova/ads.ini"
#define MAX_ADS         64
#define AD_TEXT_LEN     192
#define AD_CHAT_LIMIT   180     // SayText truncates much past this
#define TASK_SHOW       64700

#define AD_CHAT         (1 << 0)
#define AD_HUD          (1 << 1)

#define MIN_INTERVAL    10.0    // seconds, sanity floor for fnads_interval
#define MIN_DELAY       1.0     // seconds, sanity floor for first show/reload

new g_szText[MAX_ADS][AD_TEXT_LEN]
new g_iType[MAX_ADS]
new g_iAdCount
new g_iNextAd
new g_iLastAd = -1

// Fallback rotation: the ad set this plugin shipped with before ads.ini existed,
// used when the file is missing or yields nothing usable.
//
// Why it exists: LoadAds() used to log "config missing, no ads will show" and
// return, so a single botched SFTP upload of configs/freenova/ads.ini silently
// turned advertising off until somebody read the log. Ads are content, not
// configuration - the plugin should degrade to the built-in set and say so.
// The texts are the live ads.ini contents, so a fallback is not a content change:
// it is what the panel's rotation shows today.
new const g_FallbackType[] =
{
    AD_CHAT,
    AD_HUD,
    AD_CHAT,
    AD_CHAT,
    AD_CHAT,
    AD_HUD,
    AD_CHAT,
    AD_CHAT,
    AD_CHAT | AD_HUD
}

new const g_FallbackText[][] =
{
    "Join our Discord: discord.gg/as8kzp5KAz - news, events and support!",
    "Fast downloads on fn-gaming.net\\nMissing maps, sprays and sound mods install automatically",
    "Need gear or skills? Type /shop in chat to open the store.",
    "Want perks? Type /vip to see VIP tiers, benefits and the armory.",
    "Check your progress with /rank - level, XP, leaderboard and unlocks in one place.",
    "Quick commands: /shop  /vip  /rank  /panel",
    "Web panel on the go: type /panel to open the FreeNova panel in your browser.",
    "Website + fastdl: fn-gaming.net - missing files download from our fastdl automatically.",
    "Tell a friend about FreeNova - and grab your role on discord.gg/as8kzp5KAz!"
}

#define FALLBACK_COUNT  (sizeof g_FallbackText)

new g_pEnabled
new g_pInterval
new g_pStartDelay
new g_pChannel
new g_pX
new g_pY
new g_pHold
new g_pColor
new g_pRandom
new g_pTag
new g_pMinPlayers
new g_pJitter

public plugin_init()
{
    fn_boot_banner("ads", 17)

    register_plugin(PLUGIN_NAME, PLUGIN_VERSION, PLUGIN_AUTHOR)

    g_pEnabled    = register_cvar("fnads_enabled", "1")
    g_pInterval   = register_cvar("fnads_interval", "90")
    g_pStartDelay = register_cvar("fnads_start_delay", "30")
    g_pChannel    = register_cvar("fnads_channel", "1")
    g_pX          = register_cvar("fnads_x", "-1.0")
    g_pY          = register_cvar("fnads_y", "0.72")
    g_pHold       = register_cvar("fnads_hold", "7.0")
    g_pColor      = register_cvar("fnads_color", "54 222 171")
    g_pRandom     = register_cvar("fnads_random", "0")
    g_pTag        = register_cvar("fnads_tag", "1")
    g_pMinPlayers = register_cvar("fnads_minplayers", "0")
    g_pJitter     = register_cvar("fnads_jitter", "15")

    register_concmd("fnads_reload", "Cmd_Reload", ADMIN_RCON,
        "- reload addons/amxmodx/configs/freenova/ads.ini and restart rotation")
    register_clcmd("say /adsreload", "Cmd_SayReload")
    register_clcmd("say_team /adsreload", "Cmd_SayReload")
    register_clcmd("say /adspreview", "Cmd_SayPreview")
    register_clcmd("say_team /adspreview", "Cmd_SayPreview")
}

// plugin_cfg runs after amxx.cfg + map cfg, so fnads_* cvars set there are
// final by the time the first task is armed.
public plugin_cfg()
{
    LoadAds()
    ArmRotation(GetStartDelay())
}

public plugin_end()
{
    remove_task(TASK_SHOW)
}

public Cmd_Reload(id, level, cid)
{
    if (!cmd_access(id, level, cid, 1))
        return PLUGIN_HANDLED

    ReloadAds(id)
    return PLUGIN_HANDLED
}

public Cmd_SayReload(id)
{
    if (!is_user_connected(id) || !(get_user_flags(id) & ADMIN_RCON))
        return PLUGIN_HANDLED

    ReloadAds(id)
    return PLUGIN_HANDLED
}

public Cmd_SayPreview(id)
{
    if (!is_user_connected(id) || !(get_user_flags(id) & ADMIN_RCON))
        return PLUGIN_HANDLED
    if (!g_iAdCount)
    {
        client_print_color(id, print_team_default, "%s No ads loaded.", FN_CHAT_PREFIX)
        return PLUGIN_HANDLED
    }
    new iAd = (g_iLastAd + 1) % g_iAdCount
    if (g_iType[iAd] & AD_CHAT)
        ShowChat(g_szText[iAd])
    if (g_iType[iAd] & AD_HUD)
        ShowHud(g_szText[iAd])
    client_print_color(id, print_team_default, "%s Preview %d/%d.", FN_CHAT_PREFIX, iAd + 1, g_iAdCount)
    return PLUGIN_HANDLED
}

ReloadAds(id)
{
    remove_task(TASK_SHOW)
    g_iNextAd = 0
    g_iLastAd = -1
    LoadAds()
    ArmRotation(GetStartDelay())
    client_print_color(id, print_team_default, "%s Ads reloaded: %d active.",
        FN_CHAT_PREFIX, g_iAdCount)
}

Float:GetStartDelay()
{
    new Float:flDelay = get_pcvar_float(g_pStartDelay)
    if (flDelay < MIN_DELAY)
        flDelay = MIN_DELAY
    return flDelay
}

ArmRotation(Float:flFirstDelay)
{
    set_task(flFirstDelay, "Task_ShowAd", TASK_SHOW)
}

// ---------------------------------------------------------------- config

LoadAds()
{
    g_iAdCount = 0
    g_iNextAd = 0

    new szPath[128]
    get_configsdir(szPath, charsmax(szPath))
    add(szPath, charsmax(szPath), "/")
    add(szPath, charsmax(szPath), CONFIG_FILE)

    if (!file_exists(szPath))
    {
        LoadFallbackAds("config missing")
        return
    }

    new fp = fopen(szPath, "rt")
    if (!fp)
    {
        LoadFallbackAds("cannot open config")
        return
    }

    new szLine[256], szType[12]
    new iLine
    while (fgets(fp, szLine, charsmax(szLine)))
    {
        iLine++
        trim(szLine)
        if (!szLine[0] || szLine[0] == ';' || szLine[0] == '#')
            continue

        new iPipe = contain(szLine, "|")
        if (iPipe == -1)
        {
            log_amx("[FreeNova Ads] %s:%d skipped (no '|' separator)", szPath, iLine)
            continue
        }

        // Split at the FIRST pipe; the text may contain pipes itself.
        szLine[iPipe] = 0
        copy(szType, charsmax(szType), szLine)
        trim(szType)

        new szText[AD_TEXT_LEN]
        copy(szText, charsmax(szText), szLine[iPipe + 1])
        trim(szText)
        if (!szText[0])
        {
            log_amx("[FreeNova Ads] %s:%d skipped (empty text)", szPath, iLine)
            continue
        }

        new iType
        if (equali(szType, "chat"))
            iType = AD_CHAT
        else if (equali(szType, "hud"))
            iType = AD_HUD
        else if (equali(szType, "both"))
            iType = AD_CHAT | AD_HUD
        else
        {
            log_amx("[FreeNova Ads] %s:%d skipped (type '%s' must be chat, hud or both)",
                szPath, iLine, szType)
            continue
        }

        if (strlen(szText) > AD_CHAT_LIMIT)
        {
            log_amx("[FreeNova Ads] %s:%d text is %d chars, truncated to %d for chat",
                szPath, iLine, strlen(szText), AD_CHAT_LIMIT)
            szText[AD_CHAT_LIMIT] = 0
            trim(szText)
        }

        if (g_iAdCount >= MAX_ADS)
        {
            log_amx("[FreeNova Ads] %s: MAX_ADS (%d) reached, remaining lines ignored",
                szPath, MAX_ADS)
            break
        }

        copy(g_szText[g_iAdCount], charsmax(g_szText[]), szText)
        g_iType[g_iAdCount] = iType
        g_iAdCount++
    }
    fclose(fp)

    if (!g_iAdCount)
    {
        LoadFallbackAds("no usable ads in config")
        return
    }

    log_amx("[FreeNova Ads] loaded %d ads from %s", g_iAdCount, szPath)
}

// Replace the rotation with the built-in set and say why. Never fatal: an empty
// rotation is never a reason to fall silent.
LoadFallbackAds(const reason[])
{
    g_iAdCount = 0
    g_iNextAd = 0
    g_iLastAd = -1

    for (new i = 0; i < FALLBACK_COUNT && g_iAdCount < MAX_ADS; i++)
    {
        copy(g_szText[g_iAdCount], charsmax(g_szText[]), g_FallbackText[i])
        g_iType[g_iAdCount] = g_FallbackType[i]
        g_iAdCount++
    }

    log_amx("[FreeNova Ads] %s - using %d built-in ads instead", reason, g_iAdCount)
}

// ------------------------------------------------------------- rotation

public Task_ShowAd()
{
    // Re-arm BEFORE showing: a disabled or empty state must never kill the
    // loop (fnads_interval <= 0 is the one deliberate stop: reload re-arms).
    // Jitter +-fnads_jitter% keeps the cadence from feeling robotic.
    new Float:flInterval = get_pcvar_float(g_pInterval)
    if (flInterval > 0.0)
    {
        if (flInterval < MIN_INTERVAL)
            flInterval = MIN_INTERVAL
        new iJit = get_pcvar_num(g_pJitter)
        if (iJit < 0) iJit = 0
        else if (iJit > 50) iJit = 50
        if (iJit > 0)
        {
            new iPct = random_num(100 - iJit, 100 + iJit)
            flInterval = flInterval * float(iPct) / 100.0
            if (flInterval < MIN_INTERVAL)
                flInterval = MIN_INTERVAL
        }
        set_task(flInterval, "Task_ShowAd", TASK_SHOW)
    }

    if (!get_pcvar_num(g_pEnabled) || !g_iAdCount)
        return

    // Min-players gate: stay silent on an empty server (default 0 = always).
    new iMin = get_pcvar_num(g_pMinPlayers)
    if (iMin > 0)
    {
        new players[32], pnum
        get_players(players, pnum, "ch")
        if (pnum < iMin)
            return
    }

    new iAd = PickAd()
    if (g_iType[iAd] & AD_CHAT)
        ShowChat(g_szText[iAd])
    if (g_iType[iAd] & AD_HUD)
        ShowHud(g_szText[iAd])
}

PickAd()
{
    new iAd
    if (get_pcvar_num(g_pRandom) && g_iAdCount > 1)
    {
        do {
            iAd = random(g_iAdCount)
        } while (iAd == g_iLastAd)
    }
    else
    {
        if (g_iNextAd >= g_iAdCount)
            g_iNextAd = 0
        iAd = g_iNextAd
        g_iNextAd = (g_iNextAd + 1) % g_iAdCount
    }
    g_iLastAd = iAd
    return iAd
}

ShowChat(const szText[])
{
    new szMsg[AD_TEXT_LEN]
    copy(szMsg, charsmax(szMsg), szText)
    replace_all(szMsg, charsmax(szMsg), "\\n", " ") // chat cannot wrap lines

    if (get_pcvar_num(g_pTag))
        client_print_color(0, print_team_default, "%s %s", FN_CHAT_PREFIX, szMsg)
    else
        client_print_color(0, print_team_default, "%s", szMsg)
}

ShowHud(const szText[])
{
    new szMsg[AD_TEXT_LEN]
    copy(szMsg, charsmax(szMsg), szText)
    replace_all(szMsg, charsmax(szMsg), "\\n", "^n")

    new iChannel = get_pcvar_num(g_pChannel)
    if (iChannel < 1 || iChannel > 2)
        iChannel = 2 // channel 3 belongs to freenova_hud; MVP pos is engine-owned

    new iR, iG, iB
    GetHudColor(iR, iG, iB)

    new Float:flHold = get_pcvar_float(g_pHold)
    if (flHold < 1.0)
        flHold = 1.0

    // set_hudmessage parameters are GLOBAL: set immediately before the show,
    // no other set_hudmessage between them, explicit channel every time.
    set_hudmessage(iR, iG, iB, get_pcvar_float(g_pX), get_pcvar_float(g_pY),
        0, 0.0, flHold, 0.4, 0.2, iChannel)
    show_hudmessage(0, "%s", szMsg)
}

GetHudColor(&iR, &iG, &iB)
{
    new szColor[24]
    get_pcvar_string(g_pColor, szColor, charsmax(szColor))

    if (parse(szColor, iR, iG, iB) != 3)
    {
        // Eagle teal #36DEAB - FreeNova palette fallback
        iR = 54
        iG = 222
        iB = 171
        return
    }

    if (iR < 0) iR = 0
    else if (iR > 255) iR = 255
    if (iG < 0) iG = 0
    else if (iG > 255) iG = 255
    if (iB < 0) iB = 0
    else if (iB > 255) iB = 255
}
