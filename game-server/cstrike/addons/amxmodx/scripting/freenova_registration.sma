#include <amxmodx>
#include <amxmisc>
#include <freenova_ui>
#include <sockets>
#include <json>
#include <time>
#include <freenova_vip>
#include <fn_common>

// The /register frame and the sub-admin console frame are ~5.3K cells of
// declared buffers (REVIEW.md §5.2). The AMXX default stack is 4096 cells, so
// the first /register would be "Run time error 3: stack error". Same pragma the
// sibling plugins carry (freenova_vip/freenova_competitive 16384).
#pragma dynamic 16384

#define PLUGIN_NAME     "FreeNova In-Game Registration"
#define PLUGIN_VERSION  "1.1.0"
#define PLUGIN_AUTHOR   "FreeNova Dev Team"

#define MAX_PLAYERS     32
#define HTTP_BUFFER_LEN 4096

// Task IDs
#define TASK_HTTP_POLL  20000
#define TASK_TIMEOUT    30000

// Forum availability probe task IDs
#define TASK_PROBE_POLL     40000
#define TASK_PROBE_TIMEOUT  41000
#define TASK_PROBE_TICK     42000

// HTTP States
enum
{
    HTTP_STATE_IDLE = 0,
    HTTP_STATE_CONNECTING,
    HTTP_STATE_SENDING,
    HTTP_STATE_RECEIVING,
    HTTP_STATE_COMPLETE,
    HTTP_STATE_ERROR
};

// Forum availability states (auto-detected, never manually configured)
enum
{
    FORUM_UNKNOWN = 0,   // booting / first probe not resolved yet
    FORUM_UP,            // health endpoint answered HTTP 200
    FORUM_DOWN           // endpoint unreachable - registration features off
};

// CVAR Pointers
new g_pCvarEnabled;
new g_pCvarHost;
new g_pCvarPort;
new g_pCvarAllowRemote;
new g_pCvarPath;
new g_pCvarServerId;
new g_pCvarServerSecret;
new g_pCvarTimeout;
new g_pCvarRateLimit;

// Player Registration State
new g_szUsername[MAX_PLAYERS + 1][32];
new g_szEmail[MAX_PLAYERS + 1][64];
new g_szPassword[MAX_PLAYERS + 1][72];
new g_szConfirm[MAX_PLAYERS + 1][72];

new bool:g_bUserSet[MAX_PLAYERS + 1];
new bool:g_bEmailSet[MAX_PLAYERS + 1];
new bool:g_bPassSet[MAX_PLAYERS + 1];
new bool:g_bConfSet[MAX_PLAYERS + 1];
new bool:g_bInProgress[MAX_PLAYERS + 1];
new bool:g_bRegistered[MAX_PLAYERS + 1];

// Monotonic slot-reuse generation token (ADR-001)
new g_iConnectionToken[MAX_PLAYERS + 1];
new Float:g_flLastAttempt[MAX_PLAYERS + 1];

// Per-player HTTP Request Context
new g_iPlayerSocket[MAX_PLAYERS + 1];
new g_iHttpState[MAX_PLAYERS + 1];
new g_szHttpBuffer[MAX_PLAYERS + 1][HTTP_BUFFER_LEN];
new g_iHttpBytesRead[MAX_PLAYERS + 1];
new Float:g_flRequestStart[MAX_PLAYERS + 1];
new g_iRequestToken[MAX_PLAYERS + 1];

// Forum availability auto-detection (health probe state machine)
new g_iForumState;
new g_pCvarHealthPath;
new g_iProbeSocket;
new g_iProbeHttpState;
new g_iProbeBytes;
new g_szProbeRequest[256];
new g_szProbeBuffer[512];
new g_hFwdAvailability = INVALID_HANDLE;

public plugin_init()
{
    fn_boot_banner("registration", 27);

    register_plugin(PLUGIN_NAME, PLUGIN_VERSION, PLUGIN_AUTHOR);

    // CVARs
    g_pCvarEnabled      = register_cvar("freenova_reg_enabled", "1");
    g_pCvarHost         = register_cvar("freenova_reg_api_host", "127.0.0.1");
    g_pCvarPort         = register_cvar("freenova_reg_api_port", "8080");
    // Registration currently posts a password in a raw HTTP request. Keep
    // that traffic on loopback only unless an operator explicitly accepts the
    // risk; a browser-based one-time-code flow is the long-term replacement.
    g_pCvarAllowRemote  = register_cvar("freenova_reg_allow_remote", "0");
    g_pCvarPath         = register_cvar("freenova_reg_api_path", "/api/game/v1/register");
    g_pCvarServerId     = register_cvar("freenova_reg_server_id", "freenova-public-1");
    g_pCvarServerSecret = register_cvar("freenova_reg_server_secret", "");
    g_pCvarTimeout      = register_cvar("freenova_reg_timeout", "10.0");
    g_pCvarRateLimit    = register_cvar("freenova_reg_ratelimit", "15.0");
    g_pCvarHealthPath   = register_cvar("freenova_reg_health_path", "/api/game/v1/health");

    // Player Say Commands
    register_clcmd("say /register",         "Cmd_Register", ADMIN_ALL, "Open FreeNova Forum Registration Menu");
    register_clcmd("say /reg",              "Cmd_Register", ADMIN_ALL, "Open FreeNova Forum Registration Menu");
    register_clcmd("say /forumregister",    "Cmd_Register", ADMIN_ALL, "Open FreeNova Forum Registration Menu");
    register_clcmd("say_team /register",    "Cmd_Register", ADMIN_ALL, "Open FreeNova Forum Registration Menu");
    register_clcmd("say_team /reg",         "Cmd_Register", ADMIN_ALL, "Open FreeNova Forum Registration Menu");
    register_clcmd("say_team /forumregister","Cmd_Register",ADMIN_ALL, "Open FreeNova Forum Registration Menu");

    // Informational & Help Commands
    register_clcmd("say /registerhelp",     "Cmd_RegisterHelp", ADMIN_ALL, "Registration Help & Instructions");
    register_clcmd("say /account",          "Cmd_RegisterHelp", ADMIN_ALL, "Account Information");
    register_clcmd("say /forum",            "Cmd_RegisterHelp", ADMIN_ALL, "Forum Information");

    // Internal Messagemode Commands (Console only - NEVER print to chat!)
    register_clcmd("freenova_reg_user",  "Cmd_SetUsername", ADMIN_ALL);
    register_clcmd("freenova_reg_email", "Cmd_SetEmail",    ADMIN_ALL);
    register_clcmd("freenova_reg_pass",  "Cmd_SetPassword", ADMIN_ALL);
    register_clcmd("freenova_reg_conf",  "Cmd_SetConfirm",  ADMIN_ALL);

    // Admin Diagnostic Commands
    register_concmd("amx_freenova_regstatus", "Cmd_AdminRegStatus", ADMIN_RCON, "Display FreeNova Registration Status");

    // Auto-execute server configuration file
    new szCfgPath[128];
    get_configsdir(szCfgPath, charsmax(szCfgPath));
    add(szCfgPath, charsmax(szCfgPath), "/freenova_registration.cfg");
    if (file_exists(szCfgPath))
    {
        server_cmd("exec %s", szCfgPath);
    }

    // Forum availability auto-detection: probe the health endpoint shortly
    // after boot and every 30s. Every registration feature gates on this.
    g_hFwdAvailability = CreateMultiForward("fnreg_availability_changed", ET_IGNORE, FP_CELL);
    set_task(3.0, "Task_StartProbe");
    set_task(30.0, "Task_StartProbe", TASK_PROBE_TICK, _, _, "b");
}

public plugin_cfg()
{
    // The config exec above is queued until the next server frame. Defer the
    // check so a valid freenova_registration.cfg is read before we warn.
    set_task(1.0, "Task_CheckRegSecret");
}

public Task_CheckRegSecret()
{
    if (IsDefaultRegSecret())
        log_amx("[FreeNova] freenova_reg_server_secret is empty or the compiled default. Set a unique secret in freenova_registration.cfg - registration POST is refused until then. No secret was invented.");
}

public plugin_end()
{
    remove_task(TASK_PROBE_TICK);
    remove_task(TASK_PROBE_POLL);
    remove_task(TASK_PROBE_TIMEOUT);

    if (g_hFwdAvailability != INVALID_HANDLE)
        DestroyForward(g_hFwdAvailability);

    ProbeCloseSocket();
}

// ============================================================================
// FORUM AVAILABILITY AUTO-DETECTION (health probe)
// The plugin works standalone; when the backend/extension answers the health
// check, state flips to UP and registration features auto-connect.
// ============================================================================
public Task_StartProbe()
{
    if (g_iProbeSocket > 0)
        return;   // a probe is already in flight

    new szHost[64], szPath[128];
    get_pcvar_string(g_pCvarHost, szHost, charsmax(szHost));
    get_pcvar_string(g_pCvarHealthPath, szPath, charsmax(szPath));

    new iError = 0;
    new iSocket = socket_open(szHost, get_pcvar_num(g_pCvarPort), SOCKET_TCP, iError, SOCK_NON_BLOCKING);
    if (iSocket <= 0)
    {
        SetForumState(FORUM_DOWN);
        return;
    }

    formatex(g_szProbeRequest, charsmax(g_szProbeRequest),
        "GET %s HTTP/1.1^r^nHost: %s:%d^r^nUser-Agent: FreeNova-AMXX-Reg/1.1^r^nConnection: close^r^n^r^n",
        szPath, szHost, get_pcvar_num(g_pCvarPort));

    g_iProbeSocket = iSocket;
    g_iProbeHttpState = HTTP_STATE_CONNECTING;
    g_iProbeBytes = 0;
    arrayset(g_szProbeBuffer, 0, sizeof(g_szProbeBuffer));

    set_task(0.05, "Task_ProbePoll", TASK_PROBE_POLL, _, _, "b");
    set_task(get_pcvar_float(g_pCvarTimeout), "Task_ProbeTimeout", TASK_PROBE_TIMEOUT);
}

public Task_ProbePoll()
{
    if (g_iProbeSocket <= 0)
    {
        remove_task(TASK_PROBE_POLL);
        return;
    }

    switch (g_iProbeHttpState)
    {
        case HTTP_STATE_CONNECTING:
        {
            if (socket_is_writable(g_iProbeSocket, 0))
                g_iProbeHttpState = HTTP_STATE_SENDING;
        }
        case HTTP_STATE_SENDING:
        {
            new iLen = strlen(g_szProbeRequest);
            if (iLen <= 0)
            {
                g_iProbeHttpState = HTTP_STATE_RECEIVING;
            }
            else
            {
                new iSent = socket_send(g_iProbeSocket, g_szProbeRequest, iLen);
                if (iSent > 0)
                {
                    if (iSent >= iLen)
                    {
                        g_szProbeRequest[0] = 0;
                        g_iProbeHttpState = HTTP_STATE_RECEIVING;
                    }
                    else
                    {
                        new iRemain = iLen - iSent;
                        for (new i = 0; i < iRemain; i++)
                            g_szProbeRequest[i] = g_szProbeRequest[iSent + i];
                        g_szProbeRequest[iRemain] = 0;
                    }
                }
                else if (iSent < 0)
                    ProbeFinish(false);
            }
        }
        case HTTP_STATE_RECEIVING:
        {
            if (socket_is_readable(g_iProbeSocket, 0))
            {
                new szChunk[256];
                new iRecv = socket_recv(g_iProbeSocket, szChunk, charsmax(szChunk));
                if (iRecv > 0)
                {
                    new iRoom = sizeof(g_szProbeBuffer) - 1 - g_iProbeBytes;
                    new iCopy = min(iRecv, iRoom);
                    if (iCopy > 0)
                    {
                        add(g_szProbeBuffer[g_iProbeBytes], iCopy, szChunk);
                        g_iProbeBytes += iCopy;
                    }
                }
                else if (iRecv == 0)
                {
                    ProbeFinish(true);
                }
                else
                {
                    ProbeFinish(false);
                }
            }
        }
    }
}

public Task_ProbeTimeout()
{
    if (g_iProbeSocket > 0)
        ProbeFinish(false);
}

ProbeFinish(bool:bGotResponse)
{
    new bool:bUp = false;

    if (bGotResponse)
    {
        // HTTP/1.x and HTTP/2 status lines: "HTTP/1.1 200" / "HTTP/2 200"
        if (contain(g_szProbeBuffer, "HTTP/1.") == 0 || contain(g_szProbeBuffer, "HTTP/2") == 0)
        {
            new iSp = contain(g_szProbeBuffer, " ");
            if (iSp >= 0)
            {
                new szStatus[4];
                copy(szStatus, charsmax(szStatus), g_szProbeBuffer[iSp + 1]);
                new iStatus = str_to_num(szStatus);
                bUp = (iStatus >= 200 && iStatus < 300);
            }
        }
    }

    ProbeCloseSocket();
    SetForumState(bUp ? FORUM_UP : FORUM_DOWN);
}

ProbeCloseSocket()
{
    remove_task(TASK_PROBE_POLL);
    remove_task(TASK_PROBE_TIMEOUT);

    if (g_iProbeSocket > 0)
    {
        socket_close(g_iProbeSocket);
        g_iProbeSocket = 0;
    }
    g_iProbeHttpState = HTTP_STATE_IDLE;
    g_iProbeBytes = 0;
}

SetForumState(iNewState)
{
    if (g_iForumState == iNewState)
        return;

    g_iForumState = iNewState;

    log_amx("[FreeNova] Forum availability: %s", iNewState == FORUM_UP ? "ONLINE (auto-connected)" : (iNewState == FORUM_DOWN ? "OFFLINE (registration features disabled)" : "UNKNOWN"));

    new iReturn;
    ExecuteForward(g_hFwdAvailability, iReturn, iNewState);
}

public client_connect(id)
{
    if (id >= 1 && id <= MAX_PLAYERS)
    {
        g_iConnectionToken[id]++;
        WipePlayerData(id);
    }
}

public client_putinserver(id)
{
    if (id >= 1 && id <= MAX_PLAYERS)
    {
        WipePlayerData(id);
    }
}

public client_disconnected(id)
{
    if (id >= 1 && id <= MAX_PLAYERS)
    {
        g_iConnectionToken[id]++;
        CloseActiveRequest(id);
        WipePlayerData(id);
    }
}

// ============================================================================
// MEMORY & STATE CLEANUP (Zeroes out credential buffers)
// ============================================================================
WipePlayerData(id)
{
    arrayset(g_szUsername[id], 0, sizeof(g_szUsername[]));
    arrayset(g_szEmail[id], 0, sizeof(g_szEmail[]));
    arrayset(g_szPassword[id], 0, sizeof(g_szPassword[]));
    arrayset(g_szConfirm[id], 0, sizeof(g_szConfirm[]));

    g_bUserSet[id]     = false;
    g_bEmailSet[id]    = false;
    g_bPassSet[id]     = false;
    g_bConfSet[id]     = false;
    g_bInProgress[id]  = false;
    g_bRegistered[id]  = false;
    g_flLastAttempt[id] = 0.0;
}

CloseActiveRequest(id)
{
    remove_task(id + TASK_HTTP_POLL);
    remove_task(id + TASK_TIMEOUT);

    if (g_iPlayerSocket[id] > 0)
    {
        socket_close(g_iPlayerSocket[id]);
        g_iPlayerSocket[id] = 0;
    }

    g_iHttpState[id] = HTTP_STATE_IDLE;
    g_iHttpBytesRead[id] = 0;
    arrayset(g_szHttpBuffer[id], 0, sizeof(g_szHttpBuffer[]));
}

// ============================================================================
// MAIN REGISTRATION COMMAND & MENU
// ============================================================================
public Cmd_Register(id)
{
    // Master rule: the forum owns registration. When availability is not UP,
    // the command and ALL its features are unavailable.
    if (g_iForumState != FORUM_UP)
    {
        Show_ForumOfflineMenu(id);
        return PLUGIN_HANDLED;
    }

    if (!get_pcvar_num(g_pCvarEnabled))
    {
        client_print_color(id, print_team_default, "^4[FreeNova]^1 In-game registration is currently ^3disabled^1.");
        return PLUGIN_HANDLED;
    }

    if (g_bInProgress[id])
    {
        client_print_color(id, print_team_default, "^4[FreeNova]^1 Your registration request is currently ^3in progress^1. Please wait.");
        return PLUGIN_HANDLED;
    }

    if (g_bRegistered[id])
    {
        Show_AlreadyRegisteredMenu(id);
        return PLUGIN_HANDLED;
    }

    Show_RegistrationMenu(id);
    return PLUGIN_HANDLED;
}

// Forum offline: brief notice menu (FreeNova brand, explains the state).
Show_ForumOfflineMenu(id)
{
    new szTitle[96];
    formatex(szTitle, charsmax(szTitle),
        g_iForumState == FORUM_UNKNOWN
            ? "\y[ FREENOVA ] \wAccount Registration^n\dChecking forum connection... try again shortly\w"
            : "\y[ FREENOVA ] \wAccount Registration^n\rForum is currently offline\w");

    new menu = menu_create(szTitle, "MenuHandler_ForumOffline");
    menu_additem(menu, "\wOK", "0");
    menu_setprop(menu, MPROP_EXITNAME, "\wBack");
    menu_setprop(menu, MPROP_NUMBER_COLOR, "\y");
    menu_display(id, menu, 0);
}

public MenuHandler_ForumOffline(id, menu, item)
{
    menu_destroy(menu);
    if (is_user_connected(id))
        client_cmd(id, "say /menu");
    return PLUGIN_HANDLED;
}

Show_RegistrationMenu(id)
{
    if (!is_user_connected(id))
        return;

    new szTitle[128];
    formatex(szTitle, charsmax(szTitle), "\yFreeNova Account Registration^n\dLink CS 1.6 to Forum Account\w");
    new menu = menu_create(szTitle, "MenuHandler_Registration");

    new szItem[128];

    // Item 1: Username
    if (g_bUserSet[id])
        formatex(szItem, charsmax(szItem), "Username: \y%s\w", g_szUsername[id]);
    else
        formatex(szItem, charsmax(szItem), "Username: \rNot set\w");
    menu_additem(menu, szItem, "1");

    // Item 2: Email
    if (g_bEmailSet[id])
        formatex(szItem, charsmax(szItem), "Email: \y%s\w", g_szEmail[id]);
    else
        formatex(szItem, charsmax(szItem), "Email: \rNot set \d(name@domain.com)\w");
    menu_additem(menu, szItem, "2");

    // Item 3: Password (ALWAYS MASKED)
    if (g_bPassSet[id])
        formatex(szItem, charsmax(szItem), "Password: \y********\w");
    else
        formatex(szItem, charsmax(szItem), "Password: \rNot set\w");
    menu_additem(menu, szItem, "3");

    // Item 4: Confirm Password (ALWAYS MASKED)
    if (g_bConfSet[id])
        formatex(szItem, charsmax(szItem), "Confirm Password: \y********\w");
    else
        formatex(szItem, charsmax(szItem), "Confirm Password: \rNot set\w");
    menu_additem(menu, szItem, "4");

    // Item 5: Create Account
    new bool:bAllSet = (g_bUserSet[id] && g_bEmailSet[id] && g_bPassSet[id] && g_bConfSet[id]);
    new cb = menu_makecallback("RegCreateCallback");
    if (bAllSet)
        menu_additem(menu, "\yCreate Account\w", "5");
    else
        menu_additem(menu, "\dCreate Account (Fill all fields)\w", "5", 0, cb);

    // Item 6: Clear Information
    menu_additem(menu, "Clear Information", "6");

    menu_setprop(menu, MPROP_EXIT, MEXIT_ALL);
    menu_setprop(menu, MPROP_EXITNAME, "\wBack");
    menu_setprop(menu, MPROP_NUMBER_COLOR, "\y");
    menu_display(id, menu, 0);
}

public RegCreateCallback(id, menu, item)
{
    if (!(g_bUserSet[id] && g_bEmailSet[id] && g_bPassSet[id] && g_bConfSet[id]))
        return ITEM_DISABLED;
    return ITEM_ENABLED;
}

public MenuHandler_Registration(id, menu, item)
{
    if (item == MENU_EXIT || !is_user_connected(id))
    {
        menu_destroy(menu);
        if (is_user_connected(id))
            client_cmd(id, "say /menu");
        return PLUGIN_HANDLED;
    }

    new szData[6], szName[64], iAccess, iCallback;
    menu_item_getinfo(menu, item, iAccess, szData, charsmax(szData), szName, charsmax(szName), iCallback);
    menu_destroy(menu);

    new iChoice = str_to_num(szData);
    switch (iChoice)
    {
        case 1:
        {
            client_print_color(id, print_team_default, "^4[FreeNova]^1 Enter your desired ^3forum username^1 (3-20 characters):");
            client_cmd(id, "messagemode freenova_reg_user");
        }
        case 2:
        {
            client_print_color(id, print_team_default, "^4[FreeNova]^1 Enter your ^3email address^1 (example: name@domain.com):");
            client_cmd(id, "messagemode freenova_reg_email");
        }
        case 3:
        {
            client_print_color(id, print_team_default, "^4[FreeNova]^1 Enter your desired ^3password^1 (min 8 characters):");
            client_cmd(id, "messagemode freenova_reg_pass");
        }
        case 4:
        {
            client_print_color(id, print_team_default, "^4[FreeNova]^1 Enter your password ^3confirmation^1:");
            client_cmd(id, "messagemode freenova_reg_conf");
        }
        case 5:
        {
            SubmitRegistration(id);
        }
        case 6:
        {
            arrayset(g_szUsername[id], 0, sizeof(g_szUsername[]));
            arrayset(g_szEmail[id], 0, sizeof(g_szEmail[]));
            arrayset(g_szPassword[id], 0, sizeof(g_szPassword[]));
            arrayset(g_szConfirm[id], 0, sizeof(g_szConfirm[]));
            g_bUserSet[id] = false;
            g_bEmailSet[id] = false;
            g_bPassSet[id] = false;
            g_bConfSet[id] = false;

            client_print_color(id, print_team_default, "^4[FreeNova]^1 Registration details cleared.");
            Show_RegistrationMenu(id);
        }
    }

    return PLUGIN_HANDLED;
}

Show_AlreadyRegisteredMenu(id)
{
    new menu = menu_create("\yFreeNova Account Registration^n\rYour game account is already linked!\w", "MenuHandler_AlreadyRegistered");
    menu_additem(menu, "View Forum Information", "1");
    menu_setprop(menu, MPROP_EXITNAME, "\wBack");
    menu_setprop(menu, MPROP_NUMBER_COLOR, "\y");
    menu_display(id, menu, 0);
}

public MenuHandler_AlreadyRegistered(id, menu, item)
{
    menu_destroy(menu);
    if (item == 0)
    {
        Cmd_RegisterHelp(id);
        return PLUGIN_HANDLED;
    }
    if (is_user_connected(id))
        client_cmd(id, "say /menu");
    return PLUGIN_HANDLED;
}

// ============================================================================
// MESSAGEMODE INPUT HANDLERS
// ============================================================================
public Cmd_SetUsername(id)
{
    if (!is_user_connected(id))
        return PLUGIN_HANDLED;

    new szInput[64];
    read_args(szInput, charsmax(szInput));
    remove_quotes(szInput);
    trim(szInput);

    new iLen = strlen(szInput);
    if (iLen < 3 || iLen > 20)
    {
        client_print_color(id, print_team_default, "^4[FreeNova]^1 Username must be between ^33 and 20^1 characters.");
        Show_RegistrationMenu(id);
        return PLUGIN_HANDLED;
    }

    // Character validation: A-Z, a-z, 0-9, _, .
    for (new i = 0; i < iLen; i++)
    {
        new c = szInput[i];
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '.'))
        {
            client_print_color(id, print_team_default, "^4[FreeNova]^1 Username contains invalid characters. Use letters, numbers, _ and . only.");
            Show_RegistrationMenu(id);
            return PLUGIN_HANDLED;
        }
    }

    copy(g_szUsername[id], charsmax(g_szUsername[]), szInput);
    g_bUserSet[id] = true;

    client_print_color(id, print_team_default, "^4[FreeNova]^1 Username set to: ^3%s^1", g_szUsername[id]);
    Show_RegistrationMenu(id);
    return PLUGIN_HANDLED;
}

public Cmd_SetEmail(id)
{
    if (!is_user_connected(id))
        return PLUGIN_HANDLED;

    new szInput[128];
    read_args(szInput, charsmax(szInput));
    remove_quotes(szInput);
    trim(szInput);

    new iLen = strlen(szInput);
    if (iLen < 6 || iLen > 60 || contain(szInput, "@") == -1 || contain(szInput, ".") == -1)
    {
        client_print_color(id, print_team_default, "^4[FreeNova]^1 Please enter a valid ^3email address^1.");
        Show_RegistrationMenu(id);
        return PLUGIN_HANDLED;
    }

    copy(g_szEmail[id], charsmax(g_szEmail[]), szInput);
    g_bEmailSet[id] = true;

    client_print_color(id, print_team_default, "^4[FreeNova]^1 Email set successfully.");
    Show_RegistrationMenu(id);
    return PLUGIN_HANDLED;
}

public Cmd_SetPassword(id)
{
    if (!is_user_connected(id))
        return PLUGIN_HANDLED;

    new szInput[128];
    read_args(szInput, charsmax(szInput));
    remove_quotes(szInput);

    new iLen = strlen(szInput);
    if (iLen < 8)
    {
        client_print_color(id, print_team_default, "^4[FreeNova]^1 Password must be at least ^38 characters^1 long.");
        Show_RegistrationMenu(id);
        return PLUGIN_HANDLED;
    }

    if (iLen > 72)
    {
        client_print_color(id, print_team_default, "^4[FreeNova]^1 Password cannot exceed ^372 characters^1.");
        Show_RegistrationMenu(id);
        return PLUGIN_HANDLED;
    }

    copy(g_szPassword[id], charsmax(g_szPassword[]), szInput);
    g_bPassSet[id] = true;

    // Check if confirm is already set
    if (g_bConfSet[id])
    {
        if (!equal(g_szPassword[id], g_szConfirm[id]))
        {
            client_print_color(id, print_team_default, "^4[FreeNova]^1 Passwords ^3do not match^1. Both have been cleared.");
            arrayset(g_szPassword[id], 0, sizeof(g_szPassword[]));
            arrayset(g_szConfirm[id], 0, sizeof(g_szConfirm[]));
            g_bPassSet[id] = false;
            g_bConfSet[id] = false;
        }
        else
        {
            client_print_color(id, print_team_default, "^4[FreeNova]^1 Password confirmed successfully.");
        }
    }
    else
    {
        client_print_color(id, print_team_default, "^4[FreeNova]^1 Password set. Please enter ^3confirmation^1.");
    }

    // Clean local input buffer
    arrayset(szInput, 0, sizeof(szInput));

    Show_RegistrationMenu(id);
    return PLUGIN_HANDLED;
}

public Cmd_SetConfirm(id)
{
    if (!is_user_connected(id))
        return PLUGIN_HANDLED;

    new szInput[128];
    read_args(szInput, charsmax(szInput));
    remove_quotes(szInput);

    copy(g_szConfirm[id], charsmax(g_szConfirm[]), szInput);
    g_bConfSet[id] = true;

    if (g_bPassSet[id])
    {
        if (!equal(g_szPassword[id], g_szConfirm[id]))
        {
            client_print_color(id, print_team_default, "^4[FreeNova]^1 Passwords ^3do not match^1. Both have been cleared.");
            arrayset(g_szPassword[id], 0, sizeof(g_szPassword[]));
            arrayset(g_szConfirm[id], 0, sizeof(g_szConfirm[]));
            g_bPassSet[id] = false;
            g_bConfSet[id] = false;
        }
        else
        {
            client_print_color(id, print_team_default, "^4[FreeNova]^1 Password confirmed successfully.");
        }
    }
    else
    {
        client_print_color(id, print_team_default, "^4[FreeNova]^1 Confirmation set. Please set your ^3password^1.");
    }

    // Clean local input buffer
    arrayset(szInput, 0, sizeof(szInput));

    Show_RegistrationMenu(id);
    return PLUGIN_HANDLED;
}

// ============================================================================
// REGISTRATION SUBMISSION & ASYNC HTTP DISPATCH
// ============================================================================
stock bool:IsLoopbackHost(const szHost[])
{
    return equali(szHost, "127.0.0.1") || equali(szHost, "localhost") || equali(szHost, "::1");
}

SubmitRegistration(id)
{
    if (!g_bUserSet[id] || !g_bEmailSet[id] || !g_bPassSet[id] || !g_bConfSet[id])
    {
        client_print_color(id, print_team_default, "^4[FreeNova]^1 Please fill in ^3all fields^1 before submitting.");
        Show_RegistrationMenu(id);
        return;
    }

    if (!equal(g_szPassword[id], g_szConfirm[id]))
    {
        client_print_color(id, print_team_default, "^4[FreeNova]^1 Passwords do not match. Please re-enter.");
        arrayset(g_szPassword[id], 0, sizeof(g_szPassword[]));
        arrayset(g_szConfirm[id], 0, sizeof(g_szConfirm[]));
        g_bPassSet[id] = false;
        g_bConfSet[id] = false;
        Show_RegistrationMenu(id);
        return;
    }

    // Rate limiting check
    new Float:flRateLimit = get_pcvar_float(g_pCvarRateLimit);
    new Float:flGametime = get_gametime();
    if (flGametime - g_flLastAttempt[id] < flRateLimit)
    {
        new iWait = floatround(flRateLimit - (flGametime - g_flLastAttempt[id]), floatround_ceil);
        client_print_color(id, print_team_default, "^4[FreeNova]^1 Please wait ^3%d^1 seconds before trying again.", iWait);
        return;
    }
    g_flLastAttempt[id] = flGametime;

    if (IsDefaultRegSecret())
    {
        log_amx("[FreeNova] Registration POST refused: freenova_reg_server_secret is empty or the compiled default. Set a unique secret in freenova_registration.cfg. No secret was invented.");
        client_print_color(id, print_team_default, "^4[FreeNova]^1 Registration is not configured on this server. Contact an admin.");
        return;
    }

    // SteamID Identification
    new szAuthId[36];
    get_user_authid(id, szAuthId, charsmax(szAuthId));

    if (equal(szAuthId, "STEAM_ID_PENDING") || equal(szAuthId, "UNKNOWN") || !szAuthId[0])
    {
        client_print_color(id, print_team_default, "^4[FreeNova]^1 Steam authentication is still pending. Please wait a moment.");
        return;
    }

    // Prepare JSON Request Payload using json.inc
    new szRequestId[64];
    formatex(szRequestId, charsmax(szRequestId), "fn-reg-%d-%d-%d", get_systime(), id, random(100000));

    new JSON:root = json_init_object();
    json_object_set_number(root, "protocol_version", 1);
    json_object_set_string(root, "request_id", szRequestId);

    new szServerId[64];
    get_pcvar_string(g_pCvarServerId, szServerId, charsmax(szServerId));
    json_object_set_string(root, "server_id", szServerId);

    new iTimestamp = get_systime();
    json_object_set_number(root, "timestamp", iTimestamp);

    // Player object
    new JSON:playerObj = json_init_object();
    json_object_set_string(playerObj, "auth_provider", "steam");
    json_object_set_string(playerObj, "auth_id", szAuthId);
    json_object_set_value(root, "player", playerObj);

    // Registration object
    new JSON:regObj = json_init_object();
    json_object_set_string(regObj, "username", g_szUsername[id]);
    json_object_set_string(regObj, "email", g_szEmail[id]);
    json_object_set_string(regObj, "password", g_szPassword[id]);
    json_object_set_value(root, "registration", regObj);

    new szJsonPayload[1024];
    json_serial_to_string(root, szJsonPayload, charsmax(szJsonPayload));
    json_free(root);

    // Cryptographic Signature: Keyed-SHA256
    // Signature = SHA256(secret + ":POST:" + path + ":" + timestamp + ":" + nonce + ":" + body)
    new szNonce[36];
    formatex(szNonce, charsmax(szNonce), "%08x%08x", random(0x7FFFFFFF), random(0x7FFFFFFF));

    new szSecret[128], szPath[128];
    get_pcvar_string(g_pCvarServerSecret, szSecret, charsmax(szSecret));
    get_pcvar_string(g_pCvarPath, szPath, charsmax(szPath));

    new szSignData[1600];
    formatex(szSignData, charsmax(szSignData), "%s:POST:%s:%d:%s:%s",
             szSecret, szPath, iTimestamp, szNonce, szJsonPayload);

    new szSignature[65];
    hash_string(szSignData, Hash_Sha256, szSignature, charsmax(szSignature));

    // Network Config
    new szHost[64];
    get_pcvar_string(g_pCvarHost, szHost, charsmax(szHost));
    new iPort = get_pcvar_num(g_pCvarPort);

    // The current transport is plain HTTP. Never send registration passwords
    // over a non-loopback network unless the operator explicitly opts in.
    if (!IsLoopbackHost(szHost) && !get_pcvar_num(g_pCvarAllowRemote))
    {
        log_amx("[FreeNova] Registration refused: freenova_reg_api_host is not loopback and freenova_reg_allow_remote is disabled.");
        client_print_color(id, print_team_default, "^4[FreeNova]^1 Registration transport is not configured securely. Contact an admin.");
        return;
    }

    // Construct Raw HTTP Request
    new szHttpReq[2048];
    new iReqLen = formatex(szHttpReq, charsmax(szHttpReq), "POST %s HTTP/1.1^r^nHost: %s:%d^r^nUser-Agent: FreeNova-AMXX-Reg/1.0^r^n", szPath, szHost, iPort);
    iReqLen += formatex(szHttpReq[iReqLen], charsmax(szHttpReq) - iReqLen, "Content-Type: application/json^r^nContent-Length: %d^r^n", strlen(szJsonPayload));
    iReqLen += formatex(szHttpReq[iReqLen], charsmax(szHttpReq) - iReqLen, "X-FreeNova-Server-ID: %s^r^nX-FreeNova-Timestamp: %d^r^n", szServerId, iTimestamp);
    iReqLen += formatex(szHttpReq[iReqLen], charsmax(szHttpReq) - iReqLen, "X-FreeNova-Nonce: %s^r^nX-FreeNova-Signature: %s^r^nConnection: close^r^n^r^n%s", szNonce, szSignature, szJsonPayload);

    // Open Non-blocking Socket
    new iError = 0;
    new iSocket = socket_open(szHost, iPort, SOCKET_TCP, iError, SOCK_NON_BLOCKING);

    if (iSocket <= 0)
    {
        client_print_color(id, print_team_default, "^4[FreeNova]^1 Connection to backend API failed (code: ^3%d^1).", iError);
        return;
    }

    // Set request context
    CloseActiveRequest(id);
    g_iPlayerSocket[id]    = iSocket;
    g_iHttpState[id]       = HTTP_STATE_CONNECTING;
    g_flRequestStart[id]   = get_gametime();
    g_iRequestToken[id]    = g_iConnectionToken[id];
    g_bInProgress[id]      = true;
    g_iHttpBytesRead[id]   = 0;

    // Buffer HTTP request into buffer for transmission
    copy(g_szHttpBuffer[id], charsmax(g_szHttpBuffer[]), szHttpReq);

    client_print_color(id, print_team_default, "^4[FreeNova]^1 Sending registration request to forum backend...");

    // Start asynchronous polling task
    set_task(0.05, "Task_HttpPoll", id + TASK_HTTP_POLL, _, _, "b");

    // Timeout watchdog
    set_task(get_pcvar_float(g_pCvarTimeout), "Task_HttpTimeout", id + TASK_TIMEOUT);
}

// ============================================================================
// ASYNCHRONOUS SOCKET POLLER (State Machine)
// ============================================================================
public Task_HttpPoll(param)
{
    new id = param - TASK_HTTP_POLL;

    // ADR-001: Validate slot and connection token
    if (!is_user_connected(id) || g_iConnectionToken[id] != g_iRequestToken[id])
    {
        CloseActiveRequest(id);
        return;
    }

    new iSocket = g_iPlayerSocket[id];
    if (iSocket <= 0)
    {
        CloseActiveRequest(id);
        return;
    }

    switch (g_iHttpState[id])
    {
        case HTTP_STATE_CONNECTING:
        {
            if (socket_is_writable(iSocket, 0))
            {
                g_iHttpState[id] = HTTP_STATE_SENDING;
            }
        }
        case HTTP_STATE_SENDING:
        {
            new iLen = strlen(g_szHttpBuffer[id]);
            if (iLen <= 0)
            {
                arrayset(g_szHttpBuffer[id], 0, sizeof(g_szHttpBuffer[]));
                g_iHttpBytesRead[id] = 0;
                g_iHttpState[id] = HTTP_STATE_RECEIVING;
            }
            else
            {
                new iSent = socket_send(iSocket, g_szHttpBuffer[id], iLen);
                if (iSent > 0)
                {
                    if (iSent >= iLen)
                    {
                        arrayset(g_szHttpBuffer[id], 0, sizeof(g_szHttpBuffer[]));
                        g_iHttpBytesRead[id] = 0;
                        g_iHttpState[id] = HTTP_STATE_RECEIVING;
                    }
                    else
                    {
                        new iRemain = iLen - iSent;
                        for (new i = 0; i < iRemain; i++)
                            g_szHttpBuffer[id][i] = g_szHttpBuffer[id][iSent + i];
                        g_szHttpBuffer[id][iRemain] = 0;
                    }
                }
                else if (iSent < 0)
                {
                    client_print_color(id, print_team_default, "^4[FreeNova]^1 Network error sending registration payload.");
                    CloseActiveRequest(id);
                    g_bInProgress[id] = false;
                }
            }
        }
        case HTTP_STATE_RECEIVING:
        {
            if (socket_is_readable(iSocket, 0))
            {
                new szChunk[512];
                new iRecv = socket_recv(iSocket, szChunk, charsmax(szChunk));
                if (iRecv > 0)
                {
                    // Append chunk to response buffer
                    new iRemaining = charsmax(g_szHttpBuffer[]) - g_iHttpBytesRead[id];
                    if (iRemaining > 0)
                    {
                        new iToCopy = min(iRecv, iRemaining);
                        for (new i = 0; i < iToCopy; i++)
                        {
                            g_szHttpBuffer[id][g_iHttpBytesRead[id] + i] = szChunk[i];
                        }
                        g_iHttpBytesRead[id] += iToCopy;
                        g_szHttpBuffer[id][g_iHttpBytesRead[id]] = '^0';
                    }
                }
                else if (iRecv == 0)
                {
                    // Peer closed connection -> complete!
                    g_iHttpState[id] = HTTP_STATE_COMPLETE;
                    ProcessHttpResponse(id);
                }
                else
                {
                    // Recv error
                    client_print_color(id, print_team_default, "^4[FreeNova]^1 Network error receiving API response.");
                    CloseActiveRequest(id);
                    g_bInProgress[id] = false;
                }
            }
        }
    }
}

public Task_HttpTimeout(param)
{
    new id = param - TASK_TIMEOUT;

    if (is_user_connected(id) && g_iConnectionToken[id] == g_iRequestToken[id] && g_bInProgress[id])
    {
        client_print_color(id, print_team_default, "^4[FreeNova]^1 Registration request ^3timed out^1. Please try again.");
    }

    CloseActiveRequest(id);
    g_bInProgress[id] = false;
}

// ============================================================================
// HTTP RESPONSE PARSING & PLAYER FEEDBACK
// ============================================================================
ProcessHttpResponse(id)
{
    // Ensure request is halted
    remove_task(id + TASK_HTTP_POLL);
    remove_task(id + TASK_TIMEOUT);
    g_bInProgress[id] = false;

    if (g_iPlayerSocket[id] > 0)
    {
        socket_close(g_iPlayerSocket[id]);
        g_iPlayerSocket[id] = 0;
    }

    // Verify player is still connected and same session
    if (!is_user_connected(id) || g_iConnectionToken[id] != g_iRequestToken[id])
    {
        WipePlayerData(id);
        return;
    }

    // Locate body start after HTTP headers ("\r\n\r\n" or "\n\n")
    new iBodyPos = contain(g_szHttpBuffer[id], "^r^n^r^n");
    new iOffset = 4;
    if (iBodyPos == -1)
    {
        iBodyPos = contain(g_szHttpBuffer[id], "^n^n");
        iOffset = 2;
    }

    if (iBodyPos == -1)
    {
        client_print_color(id, print_team_default, "^4[FreeNova]^1 Invalid response received from forum backend.");
        return;
    }

    new szJsonStr[1024];
    copy(szJsonStr, charsmax(szJsonStr), g_szHttpBuffer[id][iBodyPos + iOffset]);

    // Parse JSON
    new JSON:root = json_parse(szJsonStr);
    if (root == Invalid_JSON || !json_is_object(root))
    {
        client_print_color(id, print_team_default, "^4[FreeNova]^1 Malformed response from forum server.");
        if (root != Invalid_JSON) json_free(root);
        return;
    }

    new bool:bSuccess = json_object_get_bool(root, "success");
    new szCode[64];
    json_object_get_string(root, "code", szCode, charsmax(szCode));

    if (bSuccess)
    {
        g_bRegistered[id] = true;

        // Wipe sensitive credentials from memory
        arrayset(g_szPassword[id], 0, sizeof(g_szPassword[]));
        arrayset(g_szConfirm[id], 0, sizeof(g_szConfirm[]));

        // Display Success Banner
        DisplaySuccessExperience(id, g_szUsername[id]);
    }
    else
    {
        // Map error codes to clear player-facing messages
        if (equal(szCode, "USERNAME_TAKEN"))
        {
            client_print_color(id, print_team_default, "^4[FreeNova]^1 That username is ^3already registered^1. Please choose another.");
        }
        else if (equal(szCode, "EMAIL_TAKEN"))
        {
            client_print_color(id, print_team_default, "^4[FreeNova]^1 That email address is ^3already in use^1.");
        }
        else if (equal(szCode, "GAME_ACCOUNT_ALREADY_LINKED"))
        {
            client_print_color(id, print_team_default, "^4[FreeNova]^1 Your Counter-Strike account is ^3already linked^1 to a forum account.");
            g_bRegistered[id] = true;
        }
        else if (equal(szCode, "RATE_LIMITED"))
        {
            client_print_color(id, print_team_default, "^4[FreeNova]^1 Too many registration attempts. Please ^3try again later^1.");
        }
        else if (equal(szCode, "PASSWORD_TOO_SHORT"))
        {
            client_print_color(id, print_team_default, "^4[FreeNova]^1 Password must be at least ^38 characters^1 long.");
        }
        else if (equal(szCode, "INVALID_USERNAME"))
        {
            client_print_color(id, print_team_default, "^4[FreeNova]^1 Invalid username format. Letters, numbers, _ and . only.");
        }
        else if (equal(szCode, "INVALID_EMAIL"))
        {
            client_print_color(id, print_team_default, "^4[FreeNova]^1 Invalid email address format.");
        }
        else if (equal(szCode, "REGISTRATION_DISABLED") || equal(szCode, "FLARUM_UNAVAILABLE"))
        {
            client_print_color(id, print_team_default, "^4[FreeNova]^1 Forum registration is temporarily ^3unavailable^1.");
        }
        else
        {
            new szMsg[128];
            json_object_get_string(root, "message", szMsg, charsmax(szMsg));
            if (szMsg[0])
                client_print_color(id, print_team_default, "^4[FreeNova]^1 Registration failed: ^3%s^1", szMsg);
            else
                client_print_color(id, print_team_default, "^4[FreeNova]^1 Registration failed (code: ^3%s^1).", szCode);
        }

        // Re-open menu on failure so player can fix fields
        Show_RegistrationMenu(id);
    }

    json_free(root);
}

DisplaySuccessExperience(id, const szUsername[])
{
    // Big Centered HUD / MOTD announcement
    set_hudmessage(0, 255, 204, -1.0, 0.25, 0, 6.0, 7.0, 0.5, 1.5, -1);
    show_hudmessage(id, "====================================^n  FREENOVA FORUM ACCOUNT CREATED^n====================================^nUsername: %s^nCS 1.6 Identity: Linked^n^nVisit the forum to log in!", szUsername);

    // Chat Message
    client_print_color(id, print_team_default, "^4[FreeNova]^1 ================================================");
    client_print_color(id, print_team_default, "^4[FreeNova]^1 Forum account ^3%s^1 created and linked to your CS identity!", szUsername);

    // Registration reward: one-time 72h VIP+ trial via the unified VIP
    // core. The vault claim key IS the lock - reconnects, restarts and
    // duplicate callbacks cannot farm a second trial.
    new bool:bGranted = false;
    new iClaim = fnvip_claim_registration_trial(id);
    if (iClaim == 1)
    {
        bGranted = true;
    }
    else if (iClaim == 0)
    {
        // Already claimed previously (e.g. GAME_ACCOUNT_ALREADY_LINKED path)
        bGranted = false;
    }

    if (bGranted)
    {
        client_print_color(id, print_team_default, "^4[FreeNova]^1 ================================================");
        client_print_color(id, print_team_default, "^4[FreeNova]^1 You received:");
        client_print_color(id, print_team_default, "^4[FreeNova]^1 ^4 FREE VIP+ for 3 Days^1");
        client_print_color(id, print_team_default, "^4[FreeNova]^1 ^4^1 VIP+ progression bonuses");
        client_print_color(id, print_team_default, "^4[FreeNova]^1 ^4^1 VIP+ weapon access - type ^4/vmenu^1");
        client_print_color(id, print_team_default, "^4[FreeNova]^1 ^4^1 VIP+ models & skins - type ^4/skins^1");
        client_print_color(id, print_team_default, "^4[FreeNova]^1 ^4^1 VIP+ perks & Battle Pass bonuses");
        client_print_color(id, print_team_default, "^4[FreeNova]^1 Type ^4/vip^1 to see all benefits.");
        client_print_color(id, print_team_default, "^4[FreeNova]^1 ================================================");
    }
    else
    {
        client_print_color(id, print_team_default, "^4[FreeNova]^1 Log in on the forum with the credentials you just set.");
    }

    client_print_color(id, print_team_default, "^4[FreeNova]^1 ================================================");
}

// ============================================================================
// REGISTRATION STATE PROBE (used by freenova_vip ad gating)
// ============================================================================
public bool:IsPlayerRegistered(id)
{
    // Session flag plus the atomic VIP-core claim state: if the trial was
    // claimed, this SteamID is registered - even after a reconnect.
    if (g_bRegistered[id])
        return true;

    return bool:(fnvip_is_registered_trial_claimed(id));
}

// ============================================================================
// FORUM AVAILABILITY API (consumed by VIP / panel / hub)
// ============================================================================
public plugin_natives()
{
    register_library("freenova_reg")
    register_native("fnreg_is_available", "_native_is_available");
    register_native("fnreg_get_state", "_native_get_state");
}

public _native_is_available(plugin, params)
{
    // UP only. UNKNOWN (still probing at boot) also reports unavailable so
    // features never advertise something that may not exist.
    return (g_iForumState == FORUM_UP) ? 1 : 0;
}

public _native_get_state(plugin, params)
{
    return g_iForumState;
}

// ============================================================================
// INFORMATIONAL & HELP COMMANDS
// ============================================================================
public Cmd_RegisterHelp(id)
{
    // Availability-gated: offline shows local features instead of forum steps
    if (g_iForumState != FORUM_UP)
    {
        new szOffline[768];
        new iLen = formatex(szOffline, charsmax(szOffline),
            "<html><head><style>body{background:#050706;color:#E8ECE8;font-family:Verdana,Arial,sans-serif;font-size:13px;margin:10px;}.fnh{text-align:center;border-bottom:2px solid #57E015;padding-bottom:8px;margin-bottom:10px;}.fnbrand{color:#78FF16;font-size:24px;font-weight:bold;letter-spacing:4px;}.fnsub{color:#8D978D;font-size:10px;letter-spacing:2px;}.fngreen{color:#78FF16;}</style></head><body>");
        iLen += formatex(szOffline[iLen], charsmax(szOffline) - iLen,
            "<div class='fnh'><span class='fnbrand'>FREENOVA</span><br><span class='fnsub'>THE ULTIMATE GAMING NETWORK</span></div>");
        iLen += formatex(szOffline[iLen], charsmax(szOffline) - iLen,
            "<p>The <b>FreeNova forum</b> is currently <b>offline or not connected</b>.</p>");
        iLen += formatex(szOffline[iLen], charsmax(szOffline) - iLen,
            "<p>Account linking is unavailable, but everything else keeps working:<br>");
        iLen += formatex(szOffline[iLen], charsmax(szOffline) - iLen,
            "<span class='fngreen'>/freenova</span> hub &nbsp; <span class='fngreen'>/top15</span> leaderboards &nbsp; <span class='fngreen'>/rankstats</span> profile<br>");
        iLen += formatex(szOffline[iLen], charsmax(szOffline) - iLen,
            "<span class='fngreen'>/bp</span> battle pass &nbsp; <span class='fngreen'>/vip</span> VIP info &nbsp; <span class='fngreen'>/settings</span> preferences</p>");
        iLen += formatex(szOffline[iLen], charsmax(szOffline) - iLen,
            "<p>Registration will come back automatically once the forum is reachable.</p></body></html>");

        FN_MotdShow(id, szOffline, "FreeNova Account System");
        return PLUGIN_HANDLED;
    }

    new szMotd[1024];
    new iLen = formatex(szMotd, charsmax(szMotd), "<html><head><style>body{background:#050706;color:#E8ECE8;font-family:Verdana,Arial,sans-serif;font-size:13px;margin:10px;}.fnh{text-align:center;border-bottom:2px solid #57E015;padding-bottom:8px;margin-bottom:10px;}.fnbrand{color:#78FF16;font-size:24px;font-weight:bold;letter-spacing:4px;}.fnsub{color:#8D978D;font-size:10px;letter-spacing:2px;}h2{color:#78FF16;font-size:14px;}.fnw{color:#F1C40F;}</style></head><body>");
    iLen += formatex(szMotd[iLen], charsmax(szMotd) - iLen, "<div class='fnh'><span class='fnbrand'>FREENOVA</span><br><span class='fnsub'>THE ULTIMATE GAMING NETWORK</span></div>");
    iLen += formatex(szMotd[iLen], charsmax(szMotd) - iLen, "<p>Register your FreeNova forum account directly from inside Counter-Strike 1.6!</p>");
    iLen += formatex(szMotd[iLen], charsmax(szMotd) - iLen, "<h2>Instructions:</h2><ul>");
    iLen += formatex(szMotd[iLen], charsmax(szMotd) - iLen, "<li>Type <b>/register</b> to open the registration menu</li>");
    iLen += formatex(szMotd[iLen], charsmax(szMotd) - iLen, "<li>Set your username, email, and password</li>");
    iLen += formatex(szMotd[iLen], charsmax(szMotd) - iLen, "<li>Press <b>Create Account</b></li></ul>");
    iLen += formatex(szMotd[iLen], charsmax(szMotd) - iLen, "<p>Your SteamID is permanently linked to your forum account for VIP and Rank sync!</p></body></html>");

    FN_MotdShow(id, szMotd, "FreeNova Account System");
    return PLUGIN_HANDLED;
}

// ============================================================================
// ADMIN DIAGNOSTIC COMMAND
// ============================================================================
public Cmd_AdminRegStatus(id, level, cid)
{
    if (!cmd_access(id, level, cid, 1))
        return PLUGIN_HANDLED;

    new szHost[64], szPath[64], szServerId[64];
    get_pcvar_string(g_pCvarHost, szHost, charsmax(szHost));
    get_pcvar_string(g_pCvarPath, szPath, charsmax(szPath));
    get_pcvar_string(g_pCvarServerId, szServerId, charsmax(szServerId));

    console_print(id, "===============================================");
    console_print(id, " FreeNova Registration Plugin Status");
    console_print(id, "===============================================");
    console_print(id, " Enabled:       %s", get_pcvar_num(g_pCvarEnabled) ? "YES" : "NO");
    console_print(id, " Forum State:   %s", g_iForumState == FORUM_UP ? "ONLINE (auto-connected)" : (g_iForumState == FORUM_DOWN ? "OFFLINE (registration disabled)" : "UNKNOWN (probing...)"));
    console_print(id, " API Host:      %s:%d", szHost, get_pcvar_num(g_pCvarPort));
    console_print(id, " API Path:      %s", szPath);
    console_print(id, " Server ID:     %s", szServerId);
    console_print(id, " Timeout:       %.1f sec", get_pcvar_float(g_pCvarTimeout));
    console_print(id, " Rate Limit:    %.1f sec", get_pcvar_float(g_pCvarRateLimit));
    console_print(id, " Secret OK:     %s", IsDefaultRegSecret() ? "NO (default/empty - POST refused)" : "YES");
    console_print(id, "===============================================");

    return PLUGIN_HANDLED;
}

IsDefaultRegSecret()
{
    new szSecret[128];
    get_pcvar_string(g_pCvarServerSecret, szSecret, charsmax(szSecret));
    trim(szSecret);
    // Empty, or SHA-256 of the retired 2026 bootstrap key — both refuse POSTs.
    // Compare the hash so the leaked plaintext is not in this source file.
    new szHash[65]
    hash_string(szSecret, Hash_Sha256, szHash, charsmax(szHash))
    return (!szSecret[0] || equali(szHash, "18f7343a1c779cf7405b2af56d0330251e5c8eb6ee292be7c64bc7eba3d2b582"));
}
