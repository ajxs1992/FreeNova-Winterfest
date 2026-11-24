#if defined _freenova_web_included
    #endinput
#endif
#define _freenova_web_included

#include <freenova_prefs>

// FreeNova web-panel MOTD bridge.
//
// GoldSrc's in-game browser returns HTTP error -102 when:
//   1. the URL is longer than ~96-120 characters
//   2. the URL has no file extension (IE/GoldSrc treats it as invalid)
//   3. the URL contains query-string SteamIDs with ':' (STEAM_0:1:123)
//   4. the host is 127.0.0.1 (the CLIENT loopback, not the game server)
//
// MOTD is fetched on the PLAYER PC. Never send 127.0.0.1 / localhost.
// Set fnweb_public_host to the panel LAN IP. fnweb_host is sync-only
// (HLDS → local panel) and stays 127.0.0.1 — it is NOT a MOTD fallback.
//
// Identity lives in a short path with a .htm suffix and no query string:
//   http://<lan-ip>:8080/m/b/0-0-123456.htm
//   missions: http://<lan-ip>:8080/m/b/0-0-123456/missions.htm
//
// Page codes: p profile, b battlepass, t top, a achievements,
// v vip, e events, r tournament.
// i retired (Worker still aliases /m/i/). s/o retired (store/models).
// Missions use b + /missions.htm. OpenPage refuses store/shop/skins/cosmetics/models.
//
// Panel base URL comes from the freenova_sync cvar "fnweb_url". Callers
// fall back to a local MOTD/menu when this returns false.

#define FNWEB_MAX_URL 96
#define FNWEB_MOTD_COOLDOWN 0.40

stock FNWeb_PageCode(const szPage[])
{
    if (equal(szPage, "pass") || equal(szPage, "bp") || equal(szPage, "battlepass"))
        return 'b'
    if (equal(szPage, "top") || equal(szPage, "top15") || equal(szPage, "topcoins")
        || equal(szPage, "leaderboard") || equal(szPage, "leaderboards") || equal(szPage, "rankings"))
        return 't'
    if (equal(szPage, "missions") || equal(szPage, "mission"))
        return 'b'
    if (equal(szPage, "achievements") || equal(szPage, "records") || equal(szPage, "hof") || equal(szPage, "halloffame"))
        return 'a'
    if (equal(szPage, "store") || equal(szPage, "shop") || equal(szPage, "skins") || equal(szPage, "cosmetics"))
        return 's'
    if (equal(szPage, "vip"))
        return 'v'
    if (equal(szPage, "models"))
        return 'o'
    if (equal(szPage, "events"))
        return 'e'
    if (equal(szPage, "tournament") || equal(szPage, "ctop") || equal(szPage, "pts") || equal(szPage, "cmissions"))
        return 'r'
    return 'p'
}

stock bool:FNWeb_IsPendingAuth(const szAuth[])
{
    return equal(szAuth, "STEAM_ID_PENDING") || equal(szAuth, "STEAM_ID_LAN")
        || equal(szAuth, "VALVE_ID_PENDING") || equal(szAuth, "VALVE_ID_LAN")
        || equal(szAuth, "UNKNOWN") || equal(szAuth, "BOT") || equal(szAuth, "HLTV")
        || equal(szAuth, "PENDING") || !szAuth[0]
}

// Low Performance Mode is a persistent player preference. When it is on,
// every rich MOTD is declined here so the calling plugin runs its native
// in-game fallback instead. The fallback is still responsible for its own
// data; this helper only prevents the web panel from opening.
stock bool:FNWeb_LowPerf(id)
{
    if (!(1 <= id <= MaxClients) || !is_user_connected(id))
        return false
    if (!fnpref_is_loaded(id))
        return false
    return fnpref_get(id, FNPREF_LOW_PERF) ? true : false
}

stock FNWeb_SteamShort(const szAuth[], szOut[], iLen)
{
    if (equali(szAuth, "STEAM_", 6))
        copy(szOut, iLen, szAuth[6])
    else
        copy(szOut, iLen, szAuth)
    replace_all(szOut, iLen, ":", "-")
}

stock FNWeb_CopyHost(const szUrlOrHost[], szHost[], iLen)
{
    szHost[0] = 0
    new i = 0
    if (equali(szUrlOrHost, "http://", 7))
        i = 7
    else if (equali(szUrlOrHost, "https://", 8))
        i = 8

    new j = 0
    while (szUrlOrHost[i] && szUrlOrHost[i] != '/' && szUrlOrHost[i] != ':' && j < iLen)
        szHost[j++] = szUrlOrHost[i++]
    szHost[j] = 0
}

stock FNWeb_ExtractUrlPort(const szUrl[], szPort[], iLen)
{
    copy(szPort, iLen, "8080")
    new i = 0
    if (equali(szUrl, "http://", 7))
        i = 7
    else if (equali(szUrl, "https://", 8))
        i = 8

    while (szUrl[i] && szUrl[i] != '/' && szUrl[i] != ':')
        i++
    if (szUrl[i] != ':')
        return

    i++
    new j = 0
    while (szUrl[i] && szUrl[i] != '/' && j < iLen)
        szPort[j++] = szUrl[i++]
    szPort[j] = 0
    if (!szPort[0])
        copy(szPort, iLen, "8080")
}

stock bool:FNWeb_IsLoopbackHost(const szUrlOrHost[])
{
    new szHost[64]
    FNWeb_CopyHost(szUrlOrHost, szHost, charsmax(szHost))
    if (!szHost[0])
        copy(szHost, charsmax(szHost), szUrlOrHost)
    return equal(szHost, "127.0.0.1") || equali(szHost, "localhost")
}

stock FNWeb_SanitizeBase(szBase[], iLen)
{
    trim(szBase)
    new iEnd = strlen(szBase)
    while (iEnd > 0 && szBase[iEnd - 1] == '/')
    {
        szBase[iEnd - 1] = 0
        iEnd--
    }

    // GoldSrc MOTD fetches from the CLIENT. 127.0.0.1 is the player's PC,
    // not HLDS. Rewrite only from fnweb_public_host — never from fnweb_host
    // (that cvar is the HLDS→panel sync address and defaults to loopback).
    if (!FNWeb_IsLoopbackHost(szBase))
        return

    new szPublic[64]
    get_cvar_string("fnweb_public_host", szPublic, charsmax(szPublic))
    trim(szPublic)

    new szPublicHost[64]
    FNWeb_CopyHost(szPublic, szPublicHost, charsmax(szPublicHost))
    if (!szPublicHost[0])
        copy(szPublicHost, charsmax(szPublicHost), szPublic)

    if (!szPublicHost[0] || FNWeb_IsLoopbackHost(szPublicHost) || equal(szPublicHost, "0.0.0.0"))
        return

    new szPort[8]
    FNWeb_ExtractUrlPort(szBase, szPort, charsmax(szPort))
    formatex(szBase, iLen, "http://%s:%s", szPublicHost, szPort)
}

// The panel base URL, sanitised and ready to concatenate. One function so the
// /m/ bridge and the Winterfest page family can never disagree about which host
// a player's browser is sent to (fnweb_url, rewritten from fnweb_public_host
// when it is loopback). false = "no panel on this server, show the menu".
stock bool:FNWeb_BaseUrl(szBase[], iLen)
{
    szBase[0] = 0
    // fnweb_enabled 0 = all game MOTDs render natively with the FN theme.
    if (!get_cvar_num("fnweb_enabled"))
        return false

    get_cvar_string("fnweb_url", szBase, iLen)
    if (!szBase[0])
        return false
    if (containi(szBase, "https://") != -1)
        return false

    FNWeb_SanitizeBase(szBase, iLen)
    return szBase[0] ? true : false
}

stock bool:FNWeb_BuildUrlFromAuth(const szAuth[], const szPage[], szUrl[], iLen)
{
    szUrl[0] = 0
    if (FNWeb_IsPendingAuth(szAuth))
        return false

    new szBase[80]
    if (!FNWeb_BaseUrl(szBase, charsmax(szBase)))
        return false

    new szSteamShort[24]
    FNWeb_SteamShort(szAuth, szSteamShort, charsmax(szSteamShort))
    if (!szSteamShort[0])
        return false

    new szCode[2]
    szCode[0] = FNWeb_PageCode(szPage)
    szCode[1] = 0

    // .htm is required: GoldSrc's IE MOTD rejects extension-less HTTP URLs
    // with the same -102 it uses for over-length URLs.
    // Missions keep code b but need the extra /missions.htm tab segment.
    if (equal(szPage, "missions") || equal(szPage, "mission"))
        formatex(szUrl, iLen, "%s/m/b/%s/missions.htm", szBase, szSteamShort)
    else
        formatex(szUrl, iLen, "%s/m/%s/%s.htm", szBase, szCode, szSteamShort)

    if (FNWeb_IsLoopbackHost(szUrl))
    {
        log_amx("[FreeNova][MOTD][ERROR] refusing loopback MOTD url=%s set fnweb_public_host to the LAN IP of the panel", szUrl)
        szUrl[0] = 0
        return false
    }
    return true
}

stock bool:FNWeb_BuildUrl(id, const szPage[], szUrl[], iLen)
{
    if (!(1 <= id <= MaxClients) || !is_user_connected(id))
        return false
    if (FNWeb_LowPerf(id))
        return false

    new szAuth[40]
    get_user_authid(id, szAuth, charsmax(szAuth))
    return FNWeb_BuildUrlFromAuth(szAuth, szPage, szUrl, iLen)
}

stock bool:FNWeb_Dispatch(id, const szUrl[], const szPage[])
{
    if (!get_cvar_num("fnweb_enabled"))
        return false
    if (FNWeb_LowPerf(id))
        return false

    if (FNWeb_IsLoopbackHost(szUrl))
    {
        log_amx("[FreeNova][MOTD][ERROR] refusing loopback MOTD url=%s set fnweb_public_host to the LAN IP of the panel", szUrl)
        return false
    }

    new iLen = strlen(szUrl)
    if (iLen < 12 || iLen > FNWEB_MAX_URL)
    {
        log_amx("[FreeNova MOTD] refused page=%s len=%d url=%s", szPage, iLen, szUrl)
        return false
    }

    static Float:s_fLast[33]
    new Float:fNow = get_gametime()
    // Cooldown must return false. Returning true made callers skip the
    // local HTML fallback and look like a successful MOTD that never opened.
    if (id >= 1 && id < 33 && (fNow - s_fLast[id]) < FNWEB_MOTD_COOLDOWN)
        return false
    if (id >= 1 && id < 33)
        s_fLast[id] = fNow

    if (get_cvar_num("fnweb_debug"))
        log_amx("[FreeNova MOTD] id=%d page=%s len=%d url=%s", id, szPage, iLen, szUrl)

    show_motd(id, szUrl, "FreeNova")
    return true
}

stock bool:FNWeb_OpenPage(id, const szPage[])
{
    if (equal(szPage, "store") || equal(szPage, "shop") || equal(szPage, "skins")
        || equal(szPage, "cosmetics") || equal(szPage, "models"))
        return false

    new szUrl[FNWEB_MAX_URL + 8]
    if (!FNWeb_BuildUrl(id, szPage, szUrl, charsmax(szUrl)))
        return false
    return FNWeb_Dispatch(id, szUrl, szPage)
}

stock bool:FNWeb_OpenTarget(id, iTarget, const szPage[])
{
    if (equal(szPage, "store") || equal(szPage, "shop") || equal(szPage, "skins")
        || equal(szPage, "cosmetics") || equal(szPage, "models"))
        return false

    if (!(1 <= iTarget <= MaxClients) || !is_user_connected(iTarget))
        return FNWeb_OpenPage(id, szPage)

    new szAuth[40]
    get_user_authid(iTarget, szAuth, charsmax(szAuth))

    new szUrl[FNWEB_MAX_URL + 8]
    if (!FNWeb_BuildUrlFromAuth(szAuth, szPage, szUrl, charsmax(szUrl)))
        return false
    return FNWeb_Dispatch(id, szUrl, szPage)
}

stock FNWeb_NotifyUnavailable(id)
{
    client_print_color(id, print_team_default,
        "^4[FreeNova]^1 Could not open the web panel. Showing the in-game version.")
}

// ============================================================
// fn_open_panel(): the ONE "MOTD or menu?" decision point
// ============================================================
// Every plugin that can open a panel asks this function and nothing else, so
// Low Performance Mode (FNPREF_LOW_PERF: per player, remembered by steamid in
// the freenova_prefs vault, default off) cannot be bypassed by a plugin that
// reaches for show_motd() on its own. With LPM on the player gets their in-game
// surface and NO url and NO html page are sent to the client at all.
//
// The caller passes a kind, never a URL, and shows its own equivalent when the
// answer is false:
//
//     if (!fn_open_panel(id, FN_PANEL_WINTER))
//         cmdHub(id)                     // the menu the helper declined to skip
//
// 1 = a MOTD is on screen. 0 = refused (LPM, no panel configured, auth still
// pending, loopback host, missing file, 0.4 s cooldown) - show the menu.
//
// The two page shapes the panel serves:
//   * the MOTD bridge   <base>/m/<code>/<0-0-1234>.htm      (FNWeb_OpenPage)
//     short, steamid in the PATH, no query string: GoldSrc's IE rejects both a
//     ':' and an over-long url with HTTP -102.
//   * the Winterfest pages   <base>/winter...?steamid=0-0-1234&compact=1
//     (web-panel/src/winter: normalizeSteamid() accepts the packed form and
//     compact=1 selects the same MSIE-safe skin the bridge pages use).
//
// A new surface = one enum value + one case in fn_panel_target(). The path
// prefix comes from the fnweb_winter_path cvar (registered by freenova_panel,
// default /winter), never from a hardcoded host.
enum
{
    FN_PANEL_NONE = 0,
    FN_PANEL_MOTD,             // the server's own motd.txt (fn_join /motd)
    FN_PANEL_RULES,            // configs/freenova_rules.html
    FN_PANEL_PROFILE,          // /m/p/<steam>.htm
    FN_PANEL_VIP,              // /m/v/<steam>.htm
    FN_PANEL_TOP,              // /m/t/<steam>.htm
    FN_PANEL_WINTER,           // /winter
    FN_PANEL_WINTER_TREE,      // /winter/tree
    FN_PANEL_WINTER_GIFTS,     // /winter/gifts
    FN_PANEL_WINTER_ORNAMENTS, // /winter/ornaments
    FN_PANEL_WINTER_ADVENT,    // /winter/advent
    FN_PANEL_WINTER_PASS,      // /winter/pass
    FN_PANEL_WINTER_SPIN,      // /winter/spin
    FN_PANEL_DASHBOARD         // /dashboard.html - the owner's plate, no identity
}

stock fn_panel_kind_name(iKind, szOut[], iLen)
{
    switch (iKind)
    {
        case FN_PANEL_MOTD:            copy(szOut, iLen, "motd")
        case FN_PANEL_RULES:           copy(szOut, iLen, "rules")
        case FN_PANEL_PROFILE:         copy(szOut, iLen, "profile")
        case FN_PANEL_VIP:             copy(szOut, iLen, "vip")
        case FN_PANEL_TOP:             copy(szOut, iLen, "top")
        case FN_PANEL_WINTER:          copy(szOut, iLen, "winter")
        case FN_PANEL_WINTER_TREE:     copy(szOut, iLen, "winter-tree")
        case FN_PANEL_WINTER_GIFTS:    copy(szOut, iLen, "winter-gifts")
        case FN_PANEL_WINTER_ORNAMENTS: copy(szOut, iLen, "winter-ornaments")
        case FN_PANEL_WINTER_ADVENT:   copy(szOut, iLen, "winter-advent")
        case FN_PANEL_WINTER_PASS:     copy(szOut, iLen, "winter-pass")
        case FN_PANEL_WINTER_SPIN:     copy(szOut, iLen, "winter-spin")
        case FN_PANEL_DASHBOARD:       copy(szOut, iLen, "dashboard")
        default:                       copy(szOut, iLen, "none")
    }
}

// The inverse, for the panel_probe diagnostic (a name an operator can type).
stock fn_panel_kind_from_name(const szName[])
{
    new kinds[] = { FN_PANEL_MOTD, FN_PANEL_RULES, FN_PANEL_PROFILE, FN_PANEL_VIP,
                    FN_PANEL_TOP, FN_PANEL_WINTER, FN_PANEL_WINTER_TREE,
                    FN_PANEL_WINTER_GIFTS, FN_PANEL_WINTER_ORNAMENTS,
                    FN_PANEL_WINTER_ADVENT, FN_PANEL_WINTER_PASS, FN_PANEL_WINTER_SPIN,
                    FN_PANEL_DASHBOARD }
    new szKind[24]
    for (new i = 0; i < sizeof(kinds); i++)
    {
        fn_panel_kind_name(kinds[i], szKind, charsmax(szKind))
        if (equali(szName, szKind))
            return kinds[i]
    }
    return FN_PANEL_NONE
}

// The Winterfest page root, from config. EMPTY BY DEFAULT: the panel's
// Winterfest routes (web-panel/src/winter) were removed in its 2026-11 rebuild,
// so a hardcoded "/winter" would point a player's MOTD at a 404. An operator
// sets `fnweb_winter_path` to the page the panel really serves and every Winterfest
// command lights up; until then fn_open_panel() refuses and the menus open.
// A trailing slash is stripped so the suffixes concatenate cleanly.
stock FNWeb_WinterRoot(szOut[], iLen)
{
    get_cvar_string("fnweb_winter_path", szOut, iLen)
    trim(szOut)
    new n = strlen(szOut)
    while (n > 0 && szOut[n - 1] == '/')
        szOut[--n] = 0
}

// A path that names a document ("/dashboard.html") rather than a player page
// ("/winter"): the same bytes for every client, so no identity belongs in its
// url. True when the last segment carries an extension.
stock bool:FNWeb_IsStaticPath(const szPath[])
{
    new iLen = strlen(szPath)
    new iDot = -1
    for (new i = 0; i < iLen; i++)
    {
        if (szPath[i] == '/')
            iDot = -1
        else if (szPath[i] == '.')
            iDot = i
    }
    return (iDot > 0 && iDot < iLen - 1) ? true : false
}

// <base><path>?steamid=<0-0-1234>&compact=1 for an identity, without sending it.
// fn_open_panel() uses this for a connected player; panel_probe uses it to show
// an operator what a SteamID would get.
stock bool:FNWeb_BuildPathUrlForAuth(const szAuth[], const szPath[], szUrl[], iLen)
{
    szUrl[0] = 0

    new szBase[80]
    if (!FNWeb_BaseUrl(szBase, charsmax(szBase)))
        return false

    // A static page has no identity to carry, so it is built before the auth
    // gate: a client whose SteamID has not arrived yet (and a bot on the local
    // test server) still gets the document, and the url stays query-free.
    if (FNWeb_IsStaticPath(szPath))
    {
        formatex(szUrl, iLen, "%s%s", szBase, szPath)
        if (FNWeb_IsLoopbackHost(szUrl))
        {
            log_amx("[FreeNova][MOTD][ERROR] refusing loopback panel url=%s set fnweb_public_host to the LAN IP of the panel", szUrl)
            szUrl[0] = 0
            return false
        }
        return true
    }

    if (FNWeb_IsPendingAuth(szAuth))
        return false

    new szPacked[24]
    FNWeb_SteamShort(szAuth, szPacked, charsmax(szPacked))
    if (!szPacked[0])
        return false

    formatex(szUrl, iLen, "%s%s%ssteamid=%s&compact=1",
        szBase, szPath, (contain(szPath, "?") >= 0) ? "&" : "?", szPacked)

    if (FNWeb_IsLoopbackHost(szUrl))
    {
        log_amx("[FreeNova][MOTD][ERROR] refusing loopback panel url=%s set fnweb_public_host to the LAN IP of the panel", szUrl)
        szUrl[0] = 0
        return false
    }
    return true
}

stock bool:FNWeb_BuildPathUrl(id, const szPath[], szUrl[], iLen)
{
    szUrl[0] = 0
    if (!(1 <= id <= MaxClients) || !is_user_connected(id))
        return false
    if (FNWeb_LowPerf(id))
        return false

    new szAuth[40]
    get_user_authid(id, szAuth, charsmax(szAuth))
    return FNWeb_BuildPathUrlForAuth(szAuth, szPath, szUrl, iLen)
}

// The url `iKind` would be served to `szAuth`, or false when there is none (no
// panel, pending auth, a local-file kind, a refused host). Sends nothing: this
// exists so panel_probe can answer "which url does this player get, and why".
stock bool:FNWeb_UrlForAuth(const szAuth[], iKind, szUrl[], iLen)
{
    szUrl[0] = 0

    new szPage[16], szPath[64], szFile[96]
    if (!fn_panel_target(iKind, szPage, charsmax(szPage), szPath, charsmax(szPath), szFile, charsmax(szFile)))
        return false

    if (szFile[0])
        return false        // a local file has no url; panel_probe names it instead
    if (szPage[0])
        return FNWeb_BuildUrlFromAuth(szAuth, szPage, szUrl, iLen)
    return FNWeb_BuildPathUrlForAuth(szAuth, szPath, szUrl, iLen)
}

// kind -> the three ways a panel can be shown (a bridge code, a page path, or a
// local file). Exactly one of the three is filled in.
stock bool:fn_panel_target(iKind, szPage[], iPageLen, szPath[], iPathLen, szFile[], iFileLen)
{
    szPage[0] = 0
    szPath[0] = 0
    szFile[0] = 0

    new szRoot[48], szSuffix[24]
    switch (iKind)
    {
        // A static page: the dashboard plate the panel serves as-is out of its
        // asset root. There is no player in it, so no /m/ bridge and no query
        // string - fn_open_panel() takes the path branch and
        // FNWeb_BuildPathUrlForAuth() builds the url without an identity.
        case FN_PANEL_DASHBOARD:
        {
            copy(szPath, iPathLen, "/dashboard.html")
            return true
        }
        case FN_PANEL_MOTD:
        {
            get_cvar_string("fn_join_motd_file", szFile, iFileLen)
            if (!szFile[0])
                copy(szFile, iFileLen, "motd.txt")
            return true
        }
        case FN_PANEL_RULES:
        {
            copy(szFile, iFileLen, "addons/amxmodx/configs/freenova_rules.html")
            return true
        }
        case FN_PANEL_PROFILE:  copy(szPage, iPageLen, "profile")
        case FN_PANEL_VIP:      copy(szPage, iPageLen, "vip")
        case FN_PANEL_TOP:      copy(szPage, iPageLen, "top")
        case FN_PANEL_WINTER:           szSuffix[0] = 0
        case FN_PANEL_WINTER_TREE:      copy(szSuffix, charsmax(szSuffix), "/tree")
        case FN_PANEL_WINTER_GIFTS:     copy(szSuffix, charsmax(szSuffix), "/gifts")
        case FN_PANEL_WINTER_ORNAMENTS: copy(szSuffix, charsmax(szSuffix), "/ornaments")
        case FN_PANEL_WINTER_ADVENT:    copy(szSuffix, charsmax(szSuffix), "/advent")
        case FN_PANEL_WINTER_PASS:      copy(szSuffix, charsmax(szSuffix), "/pass")
        case FN_PANEL_WINTER_SPIN:      copy(szSuffix, charsmax(szSuffix), "/spin")
        default: return false
    }

    if (szPage[0])
        return true

    FNWeb_WinterRoot(szRoot, charsmax(szRoot))
    if (!szRoot[0])
        return false          // no page configured on this panel (see FNWeb_WinterRoot)
    formatex(szPath, iPathLen, "%s%s", szRoot, szSuffix)
    return true
}

// Why the last fn_open_panel() answered 0. A caller may use this to keep a
// LOCAL, always-allowed fallback (a compiled-in HTML page, a chat summary) for
// "this server has no panel", while refusing every page under Low Performance
// Mode. Callers never test LPM themselves - this is the helper's own answer.
enum
{
    FN_PANEL_OK = 0,        // not a denial (a MOTD went out, or nothing ran yet)
    FN_PANEL_DENY_PLAYER,   // not a connected human
    FN_PANEL_DENY_KIND,     // unknown kind
    FN_PANEL_DENY_LPM,      // low performance mode: the in-game surface only
    FN_PANEL_DENY_NOPANEL,  // no panel configured / url unusable / cooldown
    FN_PANEL_DENY_FILE      // the local MOTD file is missing
}

new g_iFnPanelDenied = FN_PANEL_OK
// Which kind the last call was for, so "nothing ran yet" (FN_PANEL_OK from an
// older call) can never be mistaken for "this call succeeded". fn_open_panel()
// with id 0 (a probe asking a question) does not overwrite the two below.
new g_iFnPanelLastKind = -1
new g_iFnPanelLastAnswer = 0

// Read it immediately after fn_open_panel() returned false.
stock fn_panel_denied()
{
    return g_iFnPanelDenied
}

// What fn_open_panel() decided for `iKind` on its LAST call - the pair a caller
// cannot get by re-asking, because re-asking changes the answer. `accepted` is 1
// when a MOTD went out for that kind, 0 when it was refused, and -1 when the
// last call was for a different kind (or there was none).
stock fn_panel_last_answer(iKind)
{
    if (g_iFnPanelLastKind != iKind)
        return -1
    return g_iFnPanelLastAnswer
}

stock bool:fn_open_panel(id, iKind)
{
    new szKind[24]
    fn_panel_kind_name(iKind, szKind, charsmax(szKind))

    new bool:asked = (1 <= id <= MaxClients) ? true : false
    g_iFnPanelLastKind = iKind
    g_iFnPanelLastAnswer = 0

    if (!asked || !is_user_connected(id) || is_user_bot(id) || is_user_hltv(id))
    {
        // A bot/HLTV slot has no browser: refuse silently for the player, but say
        // so in the log under fnweb_debug, because "the panel did nothing" and
        // "the panel was never asked" look identical from the outside.
        //
        // id 0 is not a refusal miss: it is a caller (a probe, a diagnostic)
        // asking "would this kind get a MOTD?" - there is no client to send to,
        // and the answer is no. g_iFnPanelLastAnswer stays 0 either way.
        if (get_cvar_num("fnweb_debug"))
            log_amx("[FreeNova PANEL] id=%d kind=%s -> in-game menu (not a human client)", id, szKind)
        g_iFnPanelDenied = FN_PANEL_DENY_PLAYER
        return false
    }

    new szPage[16], szPath[64], szFile[96]
    if (!fn_panel_target(iKind, szPage, charsmax(szPage), szPath, charsmax(szPath), szFile, charsmax(szFile)))
    {
        // "No page" and "unknown kind" are the same thing to the caller (show the
        // menu) but not to whoever reads the log: a Winterfest page needs
        // fnweb_winter_path set, a bridge page needs fnweb_url.
        log_amx("[FreeNova PANEL] id=%d kind=%s -> in-game menu (no page configured: set fnweb_winter_path for the Winterfest pages)",
            id, szKind)
        g_iFnPanelDenied = FN_PANEL_DENY_KIND
        return false
    }

    // The only place Low Performance Mode is read. A false here is what sends
    // every caller to its own in-game surface.
    if (FNWeb_LowPerf(id))
    {
        log_amx("[FreeNova PANEL] id=%d kind=%s lpm=1 -> in-game menu (no url, no html)", id, szKind)
        g_iFnPanelDenied = FN_PANEL_DENY_LPM
        return false
    }

    g_iFnPanelDenied = FN_PANEL_OK

    if (szFile[0])
    {
        if (!file_exists(szFile))
        {
            log_amx("[FreeNova PANEL] id=%d kind=%s lpm=0 -> menu (file '%s' is missing)", id, szKind, szFile)
            g_iFnPanelDenied = FN_PANEL_DENY_FILE
            return false
        }
        show_motd(id, szFile, "FreeNova")
        if (get_cvar_num("fnweb_debug"))
            log_amx("[FreeNova PANEL] id=%d kind=%s lpm=0 -> MOTD file %s", id, szKind, szFile)
        g_iFnPanelLastAnswer = 1
        return true
    }

    if (szPage[0])
    {
        if (!FNWeb_OpenPage(id, szPage))
        {
            log_amx("[FreeNova PANEL] id=%d kind=%s lpm=0 -> menu (the /m/%s bridge refused)", id, szKind, szPage)
            g_iFnPanelDenied = FN_PANEL_DENY_NOPANEL
            return false
        }
        g_iFnPanelLastAnswer = 1
        return true
    }

    new szUrl[FNWEB_MAX_URL + 32]
    if (!FNWeb_BuildPathUrl(id, szPath, szUrl, charsmax(szUrl)))
    {
        log_amx("[FreeNova PANEL] id=%d kind=%s lpm=0 -> menu (no usable panel url for %s)", id, szKind, szPath)
        g_iFnPanelDenied = FN_PANEL_DENY_NOPANEL
        return false
    }
    if (!FNWeb_Dispatch(id, szUrl, szPath))
    {
        log_amx("[FreeNova PANEL] id=%d kind=%s lpm=0 -> menu (%s was not dispatched)", id, szKind, szPath)
        g_iFnPanelDenied = FN_PANEL_DENY_NOPANEL
        return false
    }
    g_iFnPanelLastAnswer = 1
    return true
}
