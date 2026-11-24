#include <amxmodx>
#include <amxmisc>
#include <freenova_ui>
#include <fn_common>

// The /calladmin and /admin reply frames are ~5.3K cells of declared buffers
// (REVIEW.md §5.2). The AMXX default stack is 4096 cells, so the first call
// would be "Run time error 3: stack error". Same pragma the sibling plugins
// carry (freenova_vip/freenova_competitive 16384).
#pragma dynamic 16384

// Player -> Discord staff call.
// AMXX cannot reach discord.com over HTTPS natively, so the plugin writes the
// webhook JSON payload into addons/amxmodx/data/ and hands the POST to curl via
// server_cmd. curl writes its response into a result file (?wait=true gives the
// created message JSON back); a task reads that file afterwards, so the player
// gets a real "delivered / failed" answer instead of a blind confirmation.
//
// Webhook, role ping and sender name are cvars. configs/calladmin.cfg is
// auto-created on first start and exec'd on every map load.

#define PLUGIN  "FreeNova Call Admin"
#define VERSION "4.0"
#define AUTHOR  "FreeNova"

// Fallback defaults - live values come from cvars (configs/calladmin.cfg)
// No compiled webhook default: the URL lives ONLY in configs/calladmin.cfg
// (fn_admin_webhook). Sends refuse while it is empty (fail-closed).
#define DEFAULT_WEBHOOK  ""
#define DEFAULT_ROLE_ID  "1550500424174407790"
#define DEFAULT_HOOKNAME "CallAdmin"

// Embed accent colors per report type
#define COL_RED     15158332  // 0xE74C3C
#define COL_BLUE     3447003  // 0x3498DB
#define COL_ORANGE  15105570  // 0xE67E22
#define COL_YELLOW  15844367  // 0xF1C40F
#define COL_PURPLE  10181046  // 0x9B59B6
#define COL_TEAL     1752220  // 0x1ABC9C

// Slot 0 is the server console (calladmin_test); players use 1..MAX_PLAYERS
#define SLOT_CONSOLE 0

new const g_szStripCmds[][] =
{
    "/calladmin_custom",
    "/calladmin",
    "/needadmin",
    "/admin",
    "calladmin_test"
}

new g_pCooldown
new g_pWebhook
new g_pRoleId
new g_pHookName

new g_iLastCall[MAX_PLAYERS + 1]
new g_iLastGlobalCall
new bool:g_bSending[MAX_PLAYERS + 1]
new g_iReport
new g_iSlotReport[MAX_PLAYERS + 1]
// Reporter userid per slot: the result task fires 2.5s later, so the slot
// may hold a different player by then. Resolve by userid, not slot.
new g_iSlotUser[MAX_PLAYERS + 1]

public plugin_init()
{
    fn_boot_banner("calladmin", 13)

    register_plugin(PLUGIN, VERSION, AUTHOR)

    register_clcmd("say /admin", "Cmd_Admin")
    register_clcmd("say_team /admin", "Cmd_Admin")
    register_clcmd("say /calladmin", "Cmd_Admin")
    register_clcmd("say_team /calladmin", "Cmd_Admin")
    register_clcmd("say /needadmin", "Cmd_Admin")
    register_clcmd("say_team /needadmin", "Cmd_Admin")

    register_clcmd("say /calladmin_custom", "Cmd_Custom")
    register_clcmd("say_team /calladmin_custom", "Cmd_Custom")

    // Server console / rcon test: calladmin_test [message]
    register_srvcmd("calladmin_test", "Cmd_Test")

    g_pCooldown = register_cvar("fn_admin_cooldown", "90")
    g_pWebhook = register_cvar("fn_admin_webhook", DEFAULT_WEBHOOK)
    g_pRoleId = register_cvar("fn_admin_role_id", DEFAULT_ROLE_ID)
    g_pHookName = register_cvar("fn_admin_webhook_name", DEFAULT_HOOKNAME)
}

public plugin_cfg()
{
    // Auto-create the config file on first run, then load it every map
    new szDir[96], szCfg[160]
    get_localinfo("amxx_configsdir", szDir, charsmax(szDir))
    formatex(szCfg, charsmax(szCfg), "%s/calladmin.cfg", szDir)

    if (!file_exists(szCfg))
    {
        new iFile = fopen(szCfg, "w")
        if (iFile)
        {
            fprintf(iFile, "; FreeNova Call Admin - auto-created config, safe to edit^n")
            fprintf(iFile, "; Cooldown in seconds per player between calls (min 15)^n")
            fprintf(iFile, "fn_admin_cooldown ^"90^"^n^n")
            fprintf(iFile, "; Discord webhook URL (plain URL, no query string)^n")
            fprintf(iFile, "fn_admin_webhook ^"%s^"^n^n", DEFAULT_WEBHOOK)
            fprintf(iFile, "; Discord role ID to ping (numeric ID only)^n")
            fprintf(iFile, "fn_admin_role_id ^"%s^"^n^n", DEFAULT_ROLE_ID)
            fprintf(iFile, "; Sender name shown above the embed in Discord^n")
            fprintf(iFile, "fn_admin_webhook_name ^"%s^"^n", DEFAULT_HOOKNAME)
            fclose(iFile)
            log_amx("[FreeNova CallAdmin] Created config: %s", szCfg)
        }
        else
            log_amx("[FreeNova CallAdmin] Could not create config: %s", szCfg)
    }

    server_cmd("exec addons/amxmodx/configs/calladmin.cfg")
}

public client_disconnected(id)
{
    g_iLastCall[id] = 0
    g_bSending[id] = false
}

// ---------------------------------------------------------------------------
// Player commands
// ---------------------------------------------------------------------------

public Cmd_Admin(id)
{
    if (!CanCall(id))
        return PLUGIN_HANDLED

    ShowAdminMenu(id)
    return PLUGIN_HANDLED
}

public Cmd_Custom(id)
{
    if (!is_user_connected(id) || is_user_bot(id) || is_user_hltv(id))
        return PLUGIN_HANDLED

    new szReason[160]
    read_args(szReason, charsmax(szReason))
    remove_quotes(szReason)
    trim(szReason)
    StripCommand(szReason, charsmax(szReason))

    if (!szReason[0])
    {
        client_print_color(id, print_team_default, "%s Usage: \y/calladmin_custom <your reason>", FN_CHAT_PREFIX)
        return PLUGIN_HANDLED
    }

    if (!CanCall(id))
        return PLUGIN_HANDLED

    AdminCall_Send(id, szReason, "💬 Custom Report", COL_TEAL)
    return PLUGIN_HANDLED
}

public Cmd_Test()
{
    if (g_bSending[SLOT_CONSOLE])
    {
        console_print(0, "[CallAdmin] A test is still in flight, try again in a few seconds.")
        return PLUGIN_HANDLED
    }

    new szArg[160]
    read_args(szArg, charsmax(szArg))
    remove_quotes(szArg)
    trim(szArg)
    StripCommand(szArg, charsmax(szArg))
    if (!szArg[0])
        copy(szArg, charsmax(szArg), "This is a test report")

    g_iReport++
    new iReport = g_iReport
    g_iSlotReport[SLOT_CONSOLE] = iReport
    g_bSending[SLOT_CONSOLE] = true

    if (!QueueWebhook(SLOT_CONSOLE, "Server Console", "CONSOLE", "127.0.0.1", "-", szArg, "🧪 Test Report", COL_TEAL, iReport))
    {
        g_bSending[SLOT_CONSOLE] = false
        console_print(0, "[CallAdmin] Could not prepare the test payload.")
        return PLUGIN_HANDLED
    }

    console_print(0, "[CallAdmin] Test report #%d queued, answer in ~3 seconds.", iReport)
    return PLUGIN_HANDLED
}

// Shared pre-flight: cooldown, burst limit, SteamID readiness, in-flight guard
bool:CanCall(id)
{
    if (!is_user_connected(id) || is_user_bot(id) || is_user_hltv(id))
        return false

    if (g_bSending[id])
    {
        client_print_color(id, print_team_default, "%s Your previous report is still being delivered, please wait...", FN_CHAT_PREFIX)
        return false
    }

    new iNow = get_systime()
    new iCd = get_pcvar_num(g_pCooldown)
    if (iCd < 15)
        iCd = 15
    if (g_iLastCall[id] && iNow - g_iLastCall[id] < iCd)
    {
        client_print_color(id, print_team_default, "%s Please wait %d more seconds before calling an admin again.",
            FN_CHAT_PREFIX, iCd - (iNow - g_iLastCall[id]))
        return false
    }

    if (g_iLastGlobalCall && iNow - g_iLastGlobalCall < 5)
    {
        client_print_color(id, print_team_default, "%s Staff channel is busy. Try again in a few seconds.", FN_CHAT_PREFIX)
        return false
    }

    new szAuth[40]
    get_user_authid(id, szAuth, charsmax(szAuth))
    if (!szAuth[0] || equal(szAuth, "STEAM_ID_PENDING") || equal(szAuth, "STEAM_ID_LAN")
        || equal(szAuth, "VALVE_ID_PENDING") || equal(szAuth, "VALVE_ID_LAN")
        || equal(szAuth, "HLTV") || equal(szAuth, "UNKNOWN") || equal(szAuth, "BOT"))
    {
        client_print_color(id, print_team_default, "%s Your SteamID is not ready yet. Try again in a few seconds.", FN_CHAT_PREFIX)
        return false
    }

    return true
}

// ---------------------------------------------------------------------------
// Reason menu
// ---------------------------------------------------------------------------

ShowAdminMenu(id)
{
    new szMap[32], szMenu[320]
    new iPlayers, iDummy[32]
    get_mapname(szMap, charsmax(szMap))
    get_players(iDummy, iPlayers, "h")

    formatex(szMenu, charsmax(szMenu), "\yFreeNova Admin Call^n\wMap: \y%s^n\wPlayers: \y%d/%d^n^n",
        szMap, iPlayers, get_maxplayers())
    format(szMenu[strlen(szMenu)], charsmax(szMenu) - strlen(szMenu), "1. \wCheater / Hacker^n")
    format(szMenu[strlen(szMenu)], charsmax(szMenu) - strlen(szMenu), "2. \wMap change request^n")
    format(szMenu[strlen(szMenu)], charsmax(szMenu) - strlen(szMenu), "3. \wBad behaviour^n")
    format(szMenu[strlen(szMenu)], charsmax(szMenu) - strlen(szMenu), "4. \wSwearing / Slurs^n")
    format(szMenu[strlen(szMenu)], charsmax(szMenu) - strlen(szMenu), "5. \wAdvertisement^n")
    format(szMenu[strlen(szMenu)], charsmax(szMenu) - strlen(szMenu), "6. \wCustom reason^n^n")
    format(szMenu[strlen(szMenu)], charsmax(szMenu) - strlen(szMenu), "0. \rClose")

    show_menu(id, (1<<0)|(1<<1)|(1<<2)|(1<<3)|(1<<4)|(1<<5)|(1<<9), szMenu, -1, "AdminMenuHandler")
}

public AdminMenuHandler(id, iKey)
{
    if (!is_user_connected(id))
        return

    switch (iKey)
    {
        case 0: AdminCall_Send(id, "There is a hacker / cheater", "🚨 Hacker / Cheater", COL_RED)
        case 1: AdminCall_Send(id, "Need map change", "🗺 Map Change Request", COL_BLUE)
        case 2: AdminCall_Send(id, "Bad behaviour", "😠 Bad Behaviour", COL_ORANGE)
        case 3: AdminCall_Send(id, "Swearing / slurs", "🤬 Swearing / Slurs", COL_YELLOW)
        case 4: AdminCall_Send(id, "Advertisement", "📢 Advertisement", COL_PURPLE)
        case 5:
            client_print_color(id, print_team_default, "%s Type \y/calladmin_custom <your reason>\w to send a custom report.", FN_CHAT_PREFIX)
    }
}

AdminCall_Send(id, const szReason[], const szTitle[], iColor)
{
    if (!CanCall(id))
        return

    new szName[32], szAuth[40], szIp[24], szTeam[16]
    get_user_name(id, szName, charsmax(szName))
    get_user_authid(id, szAuth, charsmax(szAuth))
    get_user_ip(id, szIp, charsmax(szIp), 1)
    GetTeamName(id, szTeam, charsmax(szTeam))

    g_iReport++
    new iReport = g_iReport
    g_iSlotReport[id] = iReport
    g_iSlotUser[id] = get_user_userid(id)
    g_bSending[id] = true

    if (!QueueWebhook(id, szName, szAuth, szIp, szTeam, szReason, szTitle, iColor, iReport))
    {
        g_bSending[id] = false
        client_print_color(id, print_team_default, "%s Could not prepare the report. Try again later.", FN_CHAT_PREFIX)
        return
    }

    g_iLastCall[id] = get_systime()
    g_iLastGlobalCall = g_iLastCall[id]
    client_print_color(id, print_team_default, "%s Report #%d is being delivered to staff...", FN_CHAT_PREFIX, iReport)
}

// ---------------------------------------------------------------------------
// Webhook delivery
// ---------------------------------------------------------------------------

bool:QueueWebhook(slot, const szName[], const szAuth[], const szIp[], const szTeam[],
    const szReason[], const szTitle[], iColor, iReport)
{
    // Configured webhook / role / sender name with compiled fallbacks
    new szWebhook[192], szRole[32], szHookName[48]
    get_pcvar_string(g_pWebhook, szWebhook, charsmax(szWebhook))
    get_pcvar_string(g_pRoleId, szRole, charsmax(szRole))
    get_pcvar_string(g_pHookName, szHookName, charsmax(szHookName))
    if (!szWebhook[0])
    {
        // Fail-closed: no compiled fallback (previous builds embedded a live
        // webhook here). Set fn_admin_webhook in configs/calladmin.cfg.
        log_amx("[FreeNova CallAdmin] Refusing send: fn_admin_webhook is not configured.")
        return false
    }
    if (!IsValidWebhookUrl(szWebhook))
    {
        log_amx("[FreeNova CallAdmin] Refusing send: fn_admin_webhook failed validation.")
        return false
    }
    if (!szRole[0])
        copy(szRole, charsmax(szRole), DEFAULT_ROLE_ID)
    if (!szHookName[0])
        copy(szHookName, charsmax(szHookName), DEFAULT_HOOKNAME)

    new szMap[32], szHostName[64]
    get_mapname(szMap, charsmax(szMap))
    get_cvar_string("hostname", szHostName, charsmax(szHostName))

    new iPlayers, iDummy[32]
    get_players(iDummy, iPlayers, "h")

    // JSON-escape every dynamic string
    new szEscName[64], szEscAuth[48], szEscTeam[32], szEscReason[192]
    new szEscTitle[64], szEscMap[48], szEscHost[96], szEscHook[64]
    JsonEsc(szName, szEscName, charsmax(szEscName))
    JsonEsc(szAuth, szEscAuth, charsmax(szEscAuth))
    JsonEsc(szTeam, szEscTeam, charsmax(szEscTeam))
    JsonEsc(szReason, szEscReason, charsmax(szEscReason))
    JsonEsc(szTitle, szEscTitle, charsmax(szEscTitle))
    JsonEsc(szMap, szEscMap, charsmax(szEscMap))
    JsonEsc(szHostName, szEscHost, charsmax(szEscHost))
    JsonEsc(szHookName, szEscHook, charsmax(szEscHook))

    if (!szEscReason[0])
        copy(szEscReason, charsmax(szEscReason), "Not provided")

    new szDesc[240]
    formatex(szDesc, charsmax(szDesc), "**Reason:** %s", szEscReason)

    // Two rows of three inline fields
    new szFields[768]
    formatex(szFields, charsmax(szFields),
        "{^"name^":^"SteamID^",^"value^":^"%s^",^"inline^":true},",
        szEscAuth)
    format(szFields[strlen(szFields)], charsmax(szFields) - strlen(szFields),
        "{^"name^":^"IP^",^"value^":^"%s^",^"inline^":true},", szIp)
    format(szFields[strlen(szFields)], charsmax(szFields) - strlen(szFields),
        "{^"name^":^"Team^",^"value^":^"%s^",^"inline^":true},", szEscTeam)
    format(szFields[strlen(szFields)], charsmax(szFields) - strlen(szFields),
        "{^"name^":^"Map^",^"value^":^"%s^",^"inline^":true},", szEscMap)
    format(szFields[strlen(szFields)], charsmax(szFields) - strlen(szFields),
        "{^"name^":^"Players^",^"value^":^"%d/%d^",^"inline^":true},",
        iPlayers, get_maxplayers())
    format(szFields[strlen(szFields)], charsmax(szFields) - strlen(szFields),
        "{^"name^":^"Report^",^"value^":^"#%d^",^"inline^":true}",
        iReport)

    new szIso[32]
    EpochToISO(get_systime(), szIso, charsmax(szIso))

    // Full webhook payload: role ping, guaranteed mention, sender name, embed
    new szPayload[2048]
    formatex(szPayload, charsmax(szPayload),
        "{^"content^":^"<@&%s>^",^"username^":^"%s^",^"allowed_mentions^":{^"parse^":[],^"roles^":[^"%s^"]},",
        szRole, szEscHook, szRole)
    format(szPayload[strlen(szPayload)], charsmax(szPayload) - strlen(szPayload),
        "^"embeds^":[{")
    format(szPayload[strlen(szPayload)], charsmax(szPayload) - strlen(szPayload),
        "^"title^":^"Admin Call - %s^",^"description^":^"%s^",^"color^":%d,",
        szEscTitle, szDesc, iColor)
    format(szPayload[strlen(szPayload)], charsmax(szPayload) - strlen(szPayload),
        "^"author^":{^"name^":^"%s^"},", szEscName)
    format(szPayload[strlen(szPayload)], charsmax(szPayload) - strlen(szPayload),
        "^"fields^":[%s],", szFields)
    format(szPayload[strlen(szPayload)], charsmax(szPayload) - strlen(szPayload),
        "^"footer^":{^"text^":^"FreeNova CallAdmin - %s^"},", szEscHost)
    format(szPayload[strlen(szPayload)], charsmax(szPayload) - strlen(szPayload),
        "^"timestamp^":^"%s^"}]}", szIso)

    new szPayloadFile[128], szRespFile[128]
    formatex(szPayloadFile, charsmax(szPayloadFile), "addons/amxmodx/data/calladmin_payload_%d.json", slot)
    formatex(szRespFile, charsmax(szRespFile), "addons/amxmodx/data/calladmin_resp_%d.txt", slot)

    new iFile = fopen(szPayloadFile, "w")
    if (!iFile)
    {
        log_amx("[FreeNova CallAdmin] Failed to open payload file: %s", szPayloadFile)
        return false
    }
    fprintf(iFile, "%s", szPayload)
    fclose(iFile)

    delete_file(szRespFile) // clear any stale result first

    new szUrl[224]
    copy(szUrl, charsmax(szUrl), szWebhook)
    if (contain(szUrl, "?") != -1)
        add(szUrl, charsmax(szUrl), "&wait=true")
    else
        add(szUrl, charsmax(szUrl), "?wait=true")

    new szCmd[640]
    formatex(szCmd, charsmax(szCmd),
        "curl -s -m 15 -X POST -H ^"Content-Type: application/json^" --data-binary @%s -o %s %s",
        szPayloadFile, szRespFile, szUrl)

    log_amx("[FreeNova CallAdmin] Queued report #%d for %s (auth=%s, ip=%s, role=%s)",
        iReport, szEscName, szEscAuth, szIp, szRole)
    server_cmd(szCmd)
    set_task(2.5, "Task_WebhookResult", slot)

    return true
}

// Reads the webhook response file and tells the player the real outcome
public Task_WebhookResult(slot)
{
    new iReport = g_iSlotReport[slot]

    new szPayloadFile[128], szRespFile[128]
    formatex(szPayloadFile, charsmax(szPayloadFile), "addons/amxmodx/data/calladmin_payload_%d.json", slot)
    formatex(szRespFile, charsmax(szRespFile), "addons/amxmodx/data/calladmin_resp_%d.txt", slot)

    new bool:bDelivered = false
    if (file_exists(szRespFile))
    {
        new szBuf[600], iLen
        read_file(szRespFile, 0, szBuf, charsmax(szBuf), iLen)
        // Success body (wait=true) starts with {"id":"..."} - errors have no "id"
        if (contain(szBuf, "^"id^"") != -1)
            bDelivered = true
    }

    if (bDelivered)
        log_amx("[FreeNova CallAdmin] Report #%d delivered to Discord", iReport)
    else
        log_amx("[FreeNova CallAdmin] Report #%d FAILED - check fn_admin_webhook, curl and network", iReport)

    if (slot == SLOT_CONSOLE)
    {
        // The old code never cleared the console in-flight flag: only one
        // calladmin_test per map ever ran.
        g_bSending[slot] = false
        if (bDelivered)
            console_print(0, "[CallAdmin] Test report #%d delivered to Discord.", iReport)
        else
            console_print(0, "[CallAdmin] Test report #%d FAILED - see the AMXX log.", iReport)
    }
    else if (slot >= 1 && slot <= MaxClients)
    {
        // Slot may have been reused: only message the original reporter.
        new target = (g_iSlotUser[slot] > 0) ? find_player("k", g_iSlotUser[slot]) : 0
        if (target)
        {
            if (bDelivered)
                client_print_color(target, print_team_default, "%s Report #%d delivered - staff have been pinged in Discord.",
                    FN_CHAT_PREFIX, iReport)
            else
                client_print_color(target, print_team_default, "%s Report #%d could not be delivered. An admin should check the server logs.",
                    FN_CHAT_PREFIX, iReport)
        }
        else
            log_amx("[FreeNova CallAdmin] Report #%d result dropped: reporter left the server", iReport)
        g_bSending[slot] = false
    }

    delete_file(szPayloadFile)
    delete_file(szRespFile)
}

// ---------------------------------------------------------------------------
// Stocks
// ---------------------------------------------------------------------------
// Webhook URLs come from the server config (RCON-writable surface), so validate
// the shape before interpolating into a shell command.
stock bool:IsValidWebhookUrl(const szUrl[])
{
    new szPrefix[] = "https://discord.com/api/webhooks/"
    new iPre = strlen(szPrefix)
    if (strncmp(szUrl, szPrefix, iPre) != 0)
        return false
    new iLen = strlen(szUrl)
    if (iLen <= iPre + 10 || iLen >= 190)
        return false
    for (new i = iPre; i < iLen; i++)
    {
        new c = szUrl[i]
        if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
            || c == '/' || c == '-' || c == '_' || c == '.')
            continue
        return false
    }
    return true
}

stock StripCommand(sz[], iLen)
{
    for (new i = 0; i < sizeof g_szStripCmds; i++)
    {
        new iCmdLen = strlen(g_szStripCmds[i])
        if (!equali(sz, g_szStripCmds[i], iCmdLen))
            continue
        if (sz[iCmdLen] != 0 && sz[iCmdLen] != ' ')
            continue

        new j = iCmdLen
        while (sz[j] == ' ')
            j++
        new k
        while (sz[j] && k < iLen - 1)
            sz[k++] = sz[j++]
        sz[k] = 0
        return
    }
}

stock GetTeamName(id, szOut[], iLen)
{
    switch (get_user_team(id))
    {
        case 1: copy(szOut, iLen, "Terrorist")
        case 2: copy(szOut, iLen, "Counter-Terrorist")
        case 3: copy(szOut, iLen, "Spectator")
        default: copy(szOut, iLen, "None")
    }
}

// Unix time -> UTC ISO8601 for the Discord embed timestamp
stock EpochToISO(t, szOut[], iLen)
{
    new n = t / 86400
    new tod = t - n * 86400

    // civil_from_days (Hinnant), z = days since 0000-03-01
    new z = n + 719468
    new iEra = z / 146097
    new doe = z - iEra * 146097
    new yoe = (doe - doe/1460 + doe/36524 - doe/146096) / 365
    new y = yoe + iEra * 400
    new doy = doe - (365*yoe + yoe/4 - yoe/100)
    new mp = (5*doy + 2) / 153
    new d = doy - ((153*mp + 2) / 5) + 1
    new m
    if (mp < 10)
        m = mp + 3
    else
        m = mp - 9
    if (m <= 2)
        y++

    new hh = tod / 3600
    new mm = (tod % 3600) / 60
    new ss = tod % 60

    new szM[4], szD[4], szH[4], szMin[4], szS[4]
    Pad2(m, szM, charsmax(szM))
    Pad2(d, szD, charsmax(szD))
    Pad2(hh, szH, charsmax(szH))
    Pad2(mm, szMin, charsmax(szMin))
    Pad2(ss, szS, charsmax(szS))

    formatex(szOut, iLen, "%d-%s-%sT%s:%s:%sZ", y, szM, szD, szH, szMin, szS)
}

stock Pad2(v, szOut[], iLen)
{
    if (v < 10)
        formatex(szOut, iLen, "0%d", v)
    else
        formatex(szOut, iLen, "%d", v)
}

stock JsonEsc(const szIn[], szOut[], iLen)
{
    new j
    for (new i = 0; szIn[i] && j < iLen - 2; i++)
    {
        new c = szIn[i]
        if (c == 92 || c == 34)
        {
            szOut[j++] = 92
            szOut[j++] = c
        }
        else if (c == '^n' || c == '^r' || c == '^t')
            szOut[j++] = ' '
        else
            szOut[j++] = c
    }
    szOut[j] = 0
}
