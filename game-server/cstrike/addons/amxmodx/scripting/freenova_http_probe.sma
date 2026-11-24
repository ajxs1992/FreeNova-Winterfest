#include <amxmodx>
#include <easy_http>
#include <fn_common>

#define PLUGIN  "FreeNova EasyHTTP Probe"
#define VERSION "1.0.0"
#define AUTHOR  "FreeNova"

// Compile-time + runtime proof that AmxxEasyHttp 1.5.0 is installed.
// Does not replace freenova_sync.sma (that plugin already owns the 30s batched
// snapshot). This only:
//   1. Loads the easy_http module (missing-lib = this plugin does not start).
//   2. Optional one-shot POST to the configured ingest URL, never per-hit.
// Off by default. Enable with: fnweb_ezhttp_probe 1

new g_pEnabled
new g_pUrl
new g_pSecret
new g_pServerId
new g_pPath
new bool:g_bInFlight

public plugin_init()
{
    fn_boot_banner("http_probe", 3)

    register_plugin(PLUGIN, VERSION, AUTHOR)

    g_pEnabled  = register_cvar("fnweb_ezhttp_probe", "0")
    g_pPath     = register_cvar("fnweb_path", "/api/v1/server/stats")
    // Shared web cvars are OWNED by freenova_sync (single registrar, M13
    // dedup). Pointers resolve lazily in SendProbe: plugin_init order must
    // not decide whether probing works.

    register_srvcmd("fnweb_ezhttp_now", "CmdProbeNow")
}

public plugin_cfg()
{
    new szVer[32]
    get_cvar_string("ezhttp_version", szVer, charsmax(szVer))
    if (szVer[0])
        log_amx("[FreeNova EasyHTTP] module loaded (ezhttp_version=%s)", szVer)
    else
        log_amx("[FreeNova EasyHTTP] module loaded (ezhttp_version cvar empty — still usable)")

    if (get_pcvar_num(g_pEnabled))
        set_task(8.0, "TaskDelayedProbe")
}

public TaskDelayedProbe()
{
    SendProbe()
}

public CmdProbeNow()
{
    SendProbe()
}

SendProbe()
{
    if (g_bInFlight)
    {
        log_amx("[FreeNova EasyHTTP] probe already in flight — skip")
        return
    }

    new szSecret[96], szUrlBase[192], szPath[128], szServerId[48]
    g_pUrl = get_cvar_pointer("fnweb_url")
    g_pSecret = get_cvar_pointer("fnweb_secret")
    g_pServerId = get_cvar_pointer("fnweb_server_id")
    if (!g_pUrl || !g_pSecret || !g_pServerId || !g_pPath)
    {
        log_amx("[FreeNova EasyHTTP] probe skipped (web cvars not registered by owner)")
        return
    }
    get_pcvar_string(g_pSecret, szSecret, charsmax(szSecret))
    get_pcvar_string(g_pUrl, szUrlBase, charsmax(szUrlBase))
    get_pcvar_string(g_pPath, szPath, charsmax(szPath))
    get_pcvar_string(g_pServerId, szServerId, charsmax(szServerId))

    if (!szSecret[0] || !szUrlBase[0] || !szPath[0])
    {
        log_amx("[FreeNova EasyHTTP] probe skipped (missing secret/url/path)")
        return
    }

    // Envelope-only heartbeat. Never send per-hit / per-kill HTTP.
    // Build at runtime — a source literal with // is a Pawn comment.
    new szBody[96]
    formatex(szBody, charsmax(szBody), "{^"players^":[],^"probe^":1}")

    new szTimestamp[16], szNonce[32], szBodyHash[65], szSigInput[512], szSigHex[65]
    formatex(szTimestamp, charsmax(szTimestamp), "%d", get_systime())
    formatex(szNonce, charsmax(szNonce), "%d_%d", get_systime(), random_num(100000, 999999))
    hash_string(szBody, Hash_Sha256, szBodyHash, charsmax(szBodyHash))
    formatex(szSigInput, charsmax(szSigInput), "%s:POST:%s:%s:%s:%s",
        szSecret, szPath, szTimestamp, szNonce, szBodyHash)
    hash_string(szSigInput, Hash_Sha256, szSigHex, charsmax(szSigHex))

    new szUrl[256]
    // fnweb_url is a host[:port] or full URL. Append the ingest path once.
    if (szUrlBase[strlen(szUrlBase) - 1] == '/')
        formatex(szUrl, charsmax(szUrl), "%s%s", szUrlBase, szPath[1])
    else if (contain(szUrlBase, "://") != -1)
        formatex(szUrl, charsmax(szUrl), "%s%s", szUrlBase, szPath)
    else
        formatex(szUrl, charsmax(szUrl), "http://%s%s", szUrlBase, szPath)

    new EzHttpOptions:opts = ezhttp_create_options()
    if (_:opts == 0)
    {
        log_amx("[FreeNova EasyHTTP] ezhttp_create_options failed")
        return
    }

    ezhttp_option_set_timeout(opts, 8000)
    ezhttp_option_set_connect_timeout(opts, 4000)
    ezhttp_option_set_user_agent(opts, "FreeNova-EasyHTTP/1.0")
    ezhttp_option_set_header(opts, "Content-Type", "application/json")
    ezhttp_option_set_header(opts, "X-FreeNova-Server-ID", szServerId)
    ezhttp_option_set_header(opts, "X-FreeNova-Timestamp", szTimestamp)
    ezhttp_option_set_header(opts, "X-FreeNova-Nonce", szNonce)
    ezhttp_option_set_header(opts, "X-FreeNova-Signature", szSigHex)
    ezhttp_option_set_body(opts, szBody)

    g_bInFlight = true
    new EzHttpRequest:req = ezhttp_post(szUrl, "OnProbeComplete", opts)
    if (_:req == 0)
    {
        g_bInFlight = false
        log_amx("[FreeNova EasyHTTP] ezhttp_post rejected url=%s", szUrl)
        return
    }
    log_amx("[FreeNova EasyHTTP] probe sent url=%s bytes=%d", szUrl, strlen(szBody))
}

public OnProbeComplete(EzHttpRequest:request_id)
{
    g_bInFlight = false

    new EzHttpErrorCode:err = ezhttp_get_error_code(request_id)
    new iCode = ezhttp_get_http_code(request_id)
    new szErr[128]
    ezhttp_get_error_message(request_id, szErr, charsmax(szErr))

    if (err != EZH_OK)
    {
        log_amx("[FreeNova EasyHTTP] probe transport error=%d http=%d msg=%s", _:err, iCode, szErr)
        return
    }

    new szBody[256]
    ezhttp_get_data(request_id, szBody, charsmax(szBody))
    log_amx("[FreeNova EasyHTTP] probe http=%d body=%.80s", iCode, szBody)
}
