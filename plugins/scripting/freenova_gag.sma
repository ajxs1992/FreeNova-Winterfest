/*
 * ============================================================================
 * FreeNova Gag Manager  (freenova_gag)
 * ============================================================================
 *
 * PROVIDES THE EXACT COMMAND CONTRACT freenova_panel.sma emits:
 *
 *   freenova_panel.sma:1678
 *       server_cmd("amx_gag #%d %d %s", get_user_userid(tid), g_iGagTime[id], data)
 *       =>  amx_gag <target> <minutes> <a|b|c> [reason]
 *           target  = #userid (panel always), nick, steamid or ip
 *           minutes = 0 => permanent, >0 => duration (panel clamps negatives)
 *           a = Chat   (GAG_SAY)   b = Team Chat (GAG_TEAM)
 *           c = Voice Communications (GAG_VOICE)
 *           [reason] = optional, panel does not send it today
 *
 *   freenova_panel.sma:1845
 *       server_cmd("amx_ungag #%d", get_user_userid(tid))
 *       =>  amx_ungag <target>     (#userid / nick / steamid / ip)
 *
 * The panel prints its own confirmation BEFORE these deferred server_cmds run,
 * so this plugin is what turns that confirmation from false into true.
 *
 * ADMIN GATE: same flag set as the panel (FLAG_ADMIN = "cdeijuv").
 * Server console (id 0, i.e. the panel's server_cmd path) always passes.
 * Hierarchy follows freenova_panel CanModerate(): only manager ("a") may
 * gag/ungag a target that carries the full admin flag set.
 *
 * ----------------------------------------------------------------------------
 * ENFORCEMENT LAYERS (chat) - why THREE and not two:
 *
 * AMXX 1.10 C_ClientCommand (meta_api.cpp) dispatches all matching clcmd
 * handlers in REGISTRATION order and returns from the loop on the first
 * PLUGIN_HANDLED (ret & 1 => RETURN_META(MRES_SUPERCEDE)). freenova_vip
 * registers "say" at plugin line 71, freenova_cosmetics at plugin line 103:
 *
 *   L0  public client_command(id)   - core forward, executed BEFORE the whole
 *       clcmd loop (meta_api.cpp:1112). Custom-formatted players (VIP / tag /
 *       title / color) make freenova_cosmetics' handler rebroadcast chat via
 *       message_begin() and return PLUGIN_HANDLED, which SKIPS every clcmd
 *       registered after it - L0 is the only gate that runs first for those
 *       players, so it is what actually closes the VIP bypass.
 *
 *   L1  clcmd say / say_team        - exact a-vs-b discrimination. Fires for
 *       plain players (cosmetics returns PLUGIN_CONTINUE for them) and for
 *       command-prefixed lines nobody consumed (commands registered as
 *       "say /xyz" short-circuit before reaching us, so /commands stay
 *       usable by gagged players).
 *
 *   L2  SayText register_message    - gameDLL-originated SayText carrying a
 *       gagged sender index. NOTE (messages.inc / AMXX core): messages a
 *       plugin sends with message_begin() are NOT hookable - only
 *       emessage_begin() traffic reaches register_message hooks - so L2
 *       covers engine-broadcast paths, while L0/L1 close the cosmetics
 *       rebroadcast path. A short grace window keeps this plugin's own
 *       client_print_color() notices to the gagged player visible.
 *
 * VOICE (type c): the engine keeps a receiver<-sender listening matrix that
 * the gamedll writes through pfnVoice_SetClientListening. We hook
 * FM_Voice_SetClientListening and force "muted" whenever the gamedll tries to
 * (re)open a pair whose sender is voice-gagged, force-set every pair at gag
 * time, re-assert for newly joined receivers, and re-assert periodically
 * (fngag_voice_refresh) to cover pairs nobody ever writes. -voicerecord is
 * pushed to stop an in-progress voice recording.
 *
 * ----------------------------------------------------------------------------
 * INSERT POSITION (documented here on purpose; plugins.ini is NOT edited by
 * this plugin): freenova_gag MUST load BEFORE freenova_cosmetics (currently
 * line ~103 in cstrike/addons/amxmodx/configs/plugins.ini, custom section).
 * With this plugin appended AFTER cosmetics, L0 still blocks correctly, but
 * L1 is skipped for custom-formatted players; loading before cosmetics makes
 * L1 also fire for them. Order: ... freenova_vip > ... > freenova_gag >
 * freenova_cosmetics ...
 *
 * ----------------------------------------------------------------------------
 * PERSISTENCE: own nVault "freenova_gag" (opened in plugin_cfg, closed in
 * plugin_end). NEVER touches freenova_bp or any battlepass/panel vault.
 *   key   = gag#<sanitized identity>   (authid preferred, ip fallback)
 *   value = "<flags>|<expire_unix>|<reason>"   expire 0 = permanent
 * Re-gag REPLACES the previous gag (flags, duration, reason) - matching the
 * single-state confirmation freenova_panel prints.
 *
 * DEPENDENCIES: AMXX 1.10 core + nvault + cstrike + fakemeta (all already
 * loaded by freenova_panel). No Fun, no ReAPI, no menabp/rank/battlepass
 * natives. Registers library "freenova_gag" with native is_user_gagged(id)
 * (single-param base-pack arity) for the adminchat/antiflood consumers.
 *
 * Cvars (fngag_*):
 *   fngag_enabled           1      - master switch (default 1)
 *   fngag_notice_interval   3.0    - min seconds between gag notices to a player
 *   fngag_voice_refresh     2.0    - voice matrix re-assert period (0 = off, min 1.0)
 *   fngag_sweep_interval    30.0   - expiry sweep period (min 5.0)
 * ============================================================================
 */

#include <amxmodx>
#include <amxmisc>
#include <nvault>
#include <cstrike>
#include <fakemeta>
#include <freenova_chat>
#include <freenova_admin>
#include <fn_common>

#define PLUGIN  "FreeNova Gag Manager"
#define VERSION "1.0.0"
#define AUTHOR  "FreeNova"

// Same flag semantics as freenova_panel.sma (users.ini access string)
#define FLAG_ADMIN      read_flags("cdeijuv")
#define FLAG_MANAGER    read_flags("a")

// Gag type bits - deliberately identical to read_flags("a"|"b"|"c")
#define GAG_SAY         (1<<0)  // a - public chat
#define GAG_TEAM        (1<<1)  // b - team chat
#define GAG_VOICE       (1<<2)  // c - voice communications
#define GAG_ANY_CHAT    (GAG_SAY | GAG_TEAM)

#define VAULT_NAME      "freenova_gag"

// Per-plugin task ids (task ids are unique inside a plugin only)
#define TASK_SWEEP          86000
#define TASK_VOICE          86001
#define TASK_AUTH_BASE      86100  // + id  (STEAM_ID_PENDING retry)
#define MAX_AUTH_TRIES      10

// Vault value: "<flags>|<expire_unix>|<reason>"
#define MAX_GAG_REASON      60
#define MAX_GAG_KEY         64
#define MAX_MINUTES         525600  // 1 year clamp

new g_iVault = INVALID_HANDLE
new g_iSayText = -1

new g_pCvarEnabled
new g_pCvarNotice
new g_pCvarVoice
new g_pCvarSweep

// Runtime gag state (source of truth = vault; these are the live cache)
new g_iGagFlags[MAX_PLAYERS + 1]
new g_iGagExpire[MAX_PLAYERS + 1]            // unix time, 0 = permanent
new g_szGagReason[MAX_PLAYERS + 1][MAX_GAG_REASON + 1]
new g_szGagKey[MAX_PLAYERS + 1][MAX_GAG_KEY] // vault key the cache came from

new Float:g_fNoticeAt[MAX_PLAYERS + 1]       // throttle: "you are gagged"
new Float:g_fPrintOk[MAX_PLAYERS + 1]        // SayText grace for our own prints

public plugin_init()
{
    fn_boot_banner("gag", 14)

    register_plugin(PLUGIN, VERSION, AUTHOR)

    // EXACT panel contract - see header. FLAG_ADMIN = cdeijuv (panel parity).
    register_concmd("amx_gag", "Cmd_AdminGag", FLAG_ADMIN,
        "amx_gag <target> <minutes> <a|b|c> [reason] - target=#userid|nick|steamid|ip; a=chat b=team c=voice; 0=permanent")
    register_concmd("amx_ungag", "Cmd_AdminUngag", FLAG_ADMIN,
        "amx_ungag <target> - target=#userid|nick|steamid|ip")
    register_concmd("amx_gags", "Cmd_AdminList", FLAG_ADMIN,
        "- list active gags with remaining time")
    register_clcmd("say /gags", "Cmd_SayList")
    register_clcmd("say_team /gags", "Cmd_SayList")

    // L1 - clcmd chat layer (a vs b discrimination)
    register_clcmd("say", "Cmd_Say")
    register_clcmd("say_team", "Cmd_SayTeam")

    // L2 - engine SayText layer (see header for scope)
    g_iSayText = get_user_msgid("SayText")
    if (g_iSayText > 0)
        register_message(g_iSayText, "OnSayText")

    // Voice layer - gamedll -> engine listening-matrix writes
    register_forward(FM_Voice_SetClientListening, "Fwd_VoiceListen")

    g_pCvarEnabled = register_cvar("fngag_enabled", "1")
    g_pCvarNotice  = register_cvar("fngag_notice_interval", "3.0")
    g_pCvarVoice   = register_cvar("fngag_voice_refresh", "2.0")
    g_pCvarSweep   = register_cvar("fngag_sweep_interval", "30.0")
}

public plugin_natives()
{
    register_library("freenova_gag")
    register_native("is_user_gagged", "_nIsUserGagged")
}

// Base-pack contract (adminchat cmdSayChat/cmdSayAdmin, antiflood chkFlood):
// single-param is_user_gagged(id), truthy while the player is gagged.
// Returns the live gag flag bitmask (GAG_SAY/GAG_TEAM/GAG_VOICE bits); 0
// when the id is invalid/disconnected or the timed gag already expired
// (expiry mirror of Task_Sweep/LoadGagFor - an expired row reads as
// ungagged until the sweep clears it).
public _nIsUserGagged(plugin, params)
{
    new id = get_param(1)
    if (id < 1 || id > MaxClients || !is_user_connected(id))
        return 0
    if (!g_iGagFlags[id])
        return 0
    if (g_iGagExpire[id] && get_systime() >= g_iGagExpire[id])
        return 0
    return g_iGagFlags[id]
}

public plugin_cfg()
{
    g_iVault = nvault_open(VAULT_NAME)
    if (g_iVault == INVALID_HANDLE)
        log_amx("[FreeNova][Gag] WARNING: nvault_open '%s' failed - gags are session-only until reload", VAULT_NAME)

    // self-rescheduling periods (cvar-driven; see Task_* bodies)
    new Float:fSweep = get_pcvar_float(g_pCvarSweep)
    if (fSweep < 5.0)
        fSweep = 5.0
    set_task(fSweep, "Task_Sweep", TASK_SWEEP)

    new Float:fVoice = get_pcvar_float(g_pCvarVoice)
    if (fVoice < 1.0)
        fVoice = 1.0
    set_task(fVoice, "Task_VoiceRefresh", TASK_VOICE)
}

public plugin_end()
{
    if (g_iVault != INVALID_HANDLE)
    {
        nvault_close(g_iVault)
        g_iVault = INVALID_HANDLE
    }
}

// ============================================================================
// LAYER 0 - core client_command forward (BEFORE every clcmd handler)
// ============================================================================

public client_command(id)
{
    if (!get_pcvar_num(g_pCvarEnabled) || !is_user_connected(id))
        return PLUGIN_CONTINUE

    new szCmd[16]
    read_argv(0, szCmd, charsmax(szCmd))
    if (!equal(szCmd, "say") && !equal(szCmd, "say_team"))
        return PLUGIN_CONTINUE

    new szMsg[192]
    read_args(szMsg, charsmax(szMsg))
    remove_quotes(szMsg)
    trim(szMsg)
    if (!szMsg[0])
        return PLUGIN_CONTINUE

    // Command lines ("/", "!", ".", ",", "@", "#") pass to dispatch so gagged
    // players keep every /command. If nobody consumes the line, L1 blocks it
    // before the engine can broadcast it as chat.
    // Vote/utility bare words (rtv, nominate...) also pass so gagged players
    // can still rock the vote - mapvote owns those say hooks.
    if (IsChatCommand(szMsg[0]) || IsGagExemptCommand(szMsg))
        return PLUGIN_CONTINUE

    new iNeed = equal(szCmd, "say_team") ? GAG_TEAM : GAG_SAY
    if (!(g_iGagFlags[id] & iNeed))
        return PLUGIN_CONTINUE

    NotifyGagged(id)
    return PLUGIN_HANDLED   // stops the whole dispatch: engine AND cosmetics
}

// ============================================================================
// LAYER 1 - clcmd say / say_team
// ============================================================================

public Cmd_Say(id)
{
    return HandleSay(id, GAG_SAY)
}

public Cmd_SayTeam(id)
{
    return HandleSay(id, GAG_TEAM)
}

HandleSay(id, iType)
{
    if (!get_pcvar_num(g_pCvarEnabled) || !is_user_connected(id))
        return PLUGIN_CONTINUE

    new szMsg[192]
    read_args(szMsg, charsmax(szMsg))
    remove_quotes(szMsg)
    trim(szMsg)
    if (!szMsg[0])
        return PLUGIN_CONTINUE

    // Reaching this handler means no earlier plugin consumed the line:
    //  - plain chat  -> L0 already continued (player not gagged for this type)
    //  - "/command"  -> no "say /xyz" registration claimed it, engine would
    //                   broadcast it as raw chat, so block it for gagged players
    if (!(g_iGagFlags[id] & iType))
        return PLUGIN_CONTINUE

    NotifyGagged(id)
    return PLUGIN_HANDLED
}

// ============================================================================
// LAYER 2 - SayText register_message hook (gameDLL-originated messages)
// ============================================================================

public OnSayText(msg_type, msg_dest, entity)
{
    if (!get_pcvar_num(g_pCvarEnabled))
        return PLUGIN_CONTINUE

    new sender = read_data(1)
    if (sender < 2 || sender > MaxClients)
        return PLUGIN_CONTINUE
    if (!is_user_connected(sender))
        return PLUGIN_CONTINUE
    if (!(g_iGagFlags[sender] & GAG_ANY_CHAT))
        return PLUGIN_CONTINUE

    // Grace window: let our own client_print_color() notices reach the player
    new Float:fNow = get_gametime()
    if (fNow < g_fPrintOk[sender])
        return PLUGIN_CONTINUE

    // Narrow to chat frames: engine notices reusing the speaker index
    // (e.g. "#Game_..." strings) pass through. Chat text never starts
    // with '#'; plugin-sent traffic is never hookable here anyway.
    new szBody[192]
    get_msg_arg_string(2, szBody, charsmax(szBody))
    if (szBody[0] == '#')
        return PLUGIN_CONTINUE

    return PLUGIN_HANDLED
}

// ============================================================================
// VOICE (type c) - listening matrix enforcement
// ============================================================================

public Fwd_VoiceListen(receiver, sender, listen)
{
    if (!get_pcvar_num(g_pCvarEnabled))
        return FMRES_IGNORED
    if (receiver == sender || sender < 1 || sender > MaxClients)
        return FMRES_IGNORED
    if (!is_user_connected(sender) || !(g_iGagFlags[sender] & GAG_VOICE))
        return FMRES_IGNORED

    // Discard the gamedll's decision and force "receiver cannot hear sender"
    engfunc(EngFunc_SetClientListening, receiver, sender, 0)
    return FMRES_SUPERCEDE
}

// Mute a newly voice-gagged player for everyone already on the server
VoiceMuteAll(target)
{
    for (new r = 1; r <= MaxClients; r++)
    {
        if (r != target && is_user_connected(r))
            engfunc(EngFunc_SetClientListening, r, target, 0)
    }
    // stop an in-progress voice recording on the client side
    client_cmd(target, "-voicerecord")
}

// Restore default visibility after ungag: alltalk -> hear,
// otherwise hear only same-team (T/CT) receivers
VoiceRestore(target)
{
    new bool:bAllTalk = (get_cvar_num("sv_alltalk") == 1)
    new CsTeams:tTeam = cs_get_user_team(target)

    for (new r = 1; r <= MaxClients; r++)
    {
        if (r == target || !is_user_connected(r))
            continue

        new bool:bListen
        if (bAllTalk)
            bListen = true
        else
        {
            new CsTeams:rTeam = cs_get_user_team(r)
            bListen = (tTeam == rTeam && (tTeam == CS_TEAM_T || tTeam == CS_TEAM_CT))
        }
        engfunc(EngFunc_SetClientListening, r, target, bListen ? 1 : 0)
    }
}

// Re-assert mute for every (receiver, voice-gagged sender) pair: covers
// receivers who joined after the gag was applied and pairs the gamedll
// never writes (engine default is "hear").
VoiceReassertAll()
{
    for (new s = 1; s <= MaxClients; s++)
    {
        if (!is_user_connected(s) || !(g_iGagFlags[s] & GAG_VOICE))
            continue
        VoiceMuteAll_Stage(s)
    }
}

VoiceMuteAll_Stage(target)
{
    for (new r = 1; r <= MaxClients; r++)
    {
        if (r != target && is_user_connected(r))
            engfunc(EngFunc_SetClientListening, r, target, 0)
    }
}

public Task_VoiceRefresh()
{
    new Float:fVoice = get_pcvar_float(g_pCvarVoice)
    if (fVoice < 1.0)
        fVoice = 1.0
    set_task(fVoice, "Task_VoiceRefresh", TASK_VOICE)   // always stay armed

    if (!get_pcvar_num(g_pCvarEnabled))
        return

    VoiceReassertAll()
}

// ============================================================================
// EXPIRY SWEEP
// ============================================================================

public Task_Sweep()
{
    new Float:fSweep = get_pcvar_float(g_pCvarSweep)
    if (fSweep < 5.0)
        fSweep = 5.0
    set_task(fSweep, "Task_Sweep", TASK_SWEEP)          // always stay armed

    if (!get_pcvar_num(g_pCvarEnabled))
        return

    new iNow = get_systime()
    for (new id = 1; id <= MaxClients; id++)
    {
        if (!is_user_connected(id) || !g_iGagFlags[id])
            continue
        if (g_iGagExpire[id] && iNow >= g_iGagExpire[id])
            GagClear(id, true)
    }
}

// ============================================================================
// PLAYER LIFECYCLE
// ============================================================================

public client_putinserver(id)
{
    GagStateReset(id)
    remove_task(TASK_AUTH_BASE + id)
    set_task(0.5, "Task_AuthRetry", TASK_AUTH_BASE + id)
}

public client_disconnected(id)
{
    remove_task(TASK_AUTH_BASE + id)
    GagStateReset(id)
}

// SteamID may still be pending at putinserver - retry briefly (freenova_prefs
// pattern), then give up. Bots/HLTV never load gags.
public client_infochanged(id)
{
    if (!is_user_connected(id) || g_szGagKey[id][0] || g_iGagFlags[id])
        return

    new szAuth[40]
    get_user_authid(id, szAuth, charsmax(szAuth))
    if (equal(szAuth, "STEAM_ID_PENDING") || !szAuth[0])
        return

    remove_task(TASK_AUTH_BASE + id)
    set_task(0.5, "Task_AuthRetry", TASK_AUTH_BASE + id)
}

public Task_AuthRetry(taskId)
{
    new id = taskId - TASK_AUTH_BASE
    if (id < 1 || id > MaxClients || !is_user_connected(id))
        return

    new szAuth[40]
    get_user_authid(id, szAuth, charsmax(szAuth))

    static iTry[MAX_PLAYERS + 1]

    if (equal(szAuth, "STEAM_ID_PENDING") || !szAuth[0])
    {
        if (++iTry[id] < MAX_AUTH_TRIES)
            set_task(0.5, "Task_AuthRetry", TASK_AUTH_BASE + id)
        else
            iTry[id] = 0
        return
    }
    iTry[id] = 0

    if (is_user_bot(id) || is_user_hltv(id))
        return

    LoadGagFor(id, szAuth)
}

// ============================================================================
// STATE / VAULT HELPERS
// ============================================================================

GagStateReset(id)
{
    g_iGagFlags[id] = 0
    g_iGagExpire[id] = 0
    g_szGagReason[id][0] = 0
    g_szGagKey[id][0] = 0
    g_fNoticeAt[id] = 0.0
    g_fPrintOk[id] = 0.0
}

// Identity -> vault key. Authid preferred (stable across name/ip changes);
// LAN / non-steam identities fall back to ip.
BuildGagKey(const szAuth[], const szIP[], szKey[], iLen)
{
    if (szAuth[0] && !equali(szAuth, "STEAM_ID_LAN") && !equali(szAuth, "VALVE_ID_LAN")
        && !equali(szAuth, "STEAM_ID_PENDING") && !equali(szAuth, "BOT") && !equali(szAuth, "HLTV"))
    {
        new szTmp[40]
        copy(szTmp, charsmax(szTmp), szAuth)
        replace_all(szTmp, charsmax(szTmp), ":", "_")
        replace_all(szTmp, charsmax(szTmp), ".", "_")
        formatex(szKey, iLen, "gag#s_%s", szTmp)
        return
    }

    new szTmp[24]
    copy(szTmp, charsmax(szTmp), szIP)
    replace_all(szTmp, charsmax(szTmp), ".", "_")
    replace_all(szTmp, charsmax(szTmp), ":", "_")
    formatex(szKey, iLen, "gag#i_%s", szTmp)
}

LoadGagFor(id, const szAuth[])
{
    if (g_iVault == INVALID_HANDLE)
        return

    new szIP[24]
    get_user_ip(id, szIP, charsmax(szIP), 1)

    new szKey[MAX_GAG_KEY]
    BuildGagKey(szAuth, szIP, szKey, charsmax(szKey))

    new szValue[128], iStamp
    if (!nvault_lookup(g_iVault, szKey, szValue, charsmax(szValue), iStamp))
        return

    new iFlags, iExpire, szReason[MAX_GAG_REASON + 1]
    if (!ParseGagValue(szValue, iFlags, iExpire, szReason, charsmax(szReason)))
        return

    new iNow = get_systime()
    if (iExpire && iNow >= iExpire)
    {
        nvault_remove(g_iVault, szKey)
        return
    }

    g_iGagFlags[id] = iFlags
    g_iGagExpire[id] = iExpire
    copy(g_szGagReason[id], charsmax(g_szGagReason[]), szReason)
    copy(g_szGagKey[id], charsmax(g_szGagKey[]), szKey)

    if (iFlags)
        NotifyGagged(id, true)
    if (iFlags & GAG_VOICE)
        VoiceMuteAll(id)
}

bool:ParseGagValue(const szValue[], &iFlags, &iExpire, szReason[], iReasonLen)
{
    new szCopy[128]
    copy(szCopy, charsmax(szCopy), szValue)

    // "<flags>|<expire>|<reason>"
    new iF = find_char(szCopy, '|')
    if (iF < 0)
        return false
    szCopy[iF] = 0
    iFlags = str_to_num(szCopy)

    new szRest[128]
    copy(szRest, charsmax(szRest), szCopy[iF + 1])

    new iE = find_char(szRest, '|')
    if (iE < 0)
    {
        iExpire = str_to_num(szRest)
        szReason[0] = 0
        return (iFlags != 0)
    }
    szRest[iE] = 0
    iExpire = str_to_num(szRest)
    copy(szReason, iReasonLen, szRest[iE + 1])

    return (iFlags != 0)
}

SaveGagToVault(id, const szAuth[], const szIP[])
{
    if (g_iVault == INVALID_HANDLE)
        return

    new szKey[MAX_GAG_KEY]
    BuildGagKey(szAuth, szIP, szKey, charsmax(szKey))

    if (!g_iGagFlags[id])
    {
        nvault_remove(g_iVault, szKey)
        g_szGagKey[id][0] = 0
        return
    }

    new szValue[128]
    formatex(szValue, charsmax(szValue), "%d|%d|%s",
        g_iGagFlags[id], g_iGagExpire[id], g_szGagReason[id])

    nvault_set(g_iVault, szKey, szValue)
    copy(g_szGagKey[id], charsmax(g_szGagKey[]), szKey)
}

// Clear the live state (and optionally the vault row + notify) of a connected id
GagClear(id, bool:bNotify)
{
    if (g_iVault != INVALID_HANDLE && g_szGagKey[id][0])
        nvault_remove(g_iVault, g_szGagKey[id])

    new bool:bHadVoice = (g_iGagFlags[id] & GAG_VOICE) != 0
    GagStateReset(id)

    if (bHadVoice && is_user_connected(id))
        VoiceRestore(id)

    if (bNotify && is_user_connected(id))
    {
        g_fPrintOk[id] = get_gametime() + 0.3
        client_print_color(id, print_team_default, "^4[FreeNova]^1 You are no longer gagged.")
    }
}

// ============================================================================
// TARGET RESOLUTION  (#userid / nick / steamid / ip, live or offline)
// ============================================================================

enum
{
    RT_OK = 0,      // iTarget > 0 => live; iTarget == 0 + szKey set => offline identity
    RT_NO_MATCH,
    RT_AMBIGUOUS,
    RT_INVALID
}

ResolveTarget(const szArg[], &iTarget, szKey[], iKeyLen)
{
    iTarget = 0
    szKey[0] = 0

    if (!szArg[0])
        return RT_INVALID

    // --- #userid ---
    if (szArg[0] == '#')
    {
        new uid = str_to_num(szArg[1])
        if (uid <= 0)
            return RT_INVALID

        for (new p = 1; p <= MaxClients; p++)
        {
            if (!is_user_connected(p) || is_user_bot(p) || is_user_hltv(p))
                continue
            if (get_user_userid(p) == uid)
            {
                iTarget = p
                break
            }
        }
        return iTarget ? RT_OK : RT_NO_MATCH
    }

    // --- steamid / valve id (live match, else offline gag by identity) ---
    if (containi(szArg, "STEAM_") == 0 || containi(szArg, "VALVE_") == 0)
    {
        for (new p = 1; p <= MaxClients; p++)
        {
            if (!is_user_connected(p) || is_user_bot(p) || is_user_hltv(p))
                continue
            new szAuth[40]
            get_user_authid(p, szAuth, charsmax(szAuth))
            if (equali(szAuth, szArg))
            {
                iTarget = p
                break
            }
        }

        if (iTarget)
            return RT_OK

        // offline: still write a vault row so the gag applies on next connect
        new szIP[24] = ""
        BuildGagKey(szArg, szIP, szKey, iKeyLen)
        return RT_OK
    }

    // --- ip address (digits + dots) ---
    if (isdigit(szArg[0]) && IsIpLiteral(szArg))
    {
        for (new p = 1; p <= MaxClients; p++)
        {
            if (!is_user_connected(p) || is_user_bot(p) || is_user_hltv(p))
                continue
            new szIP[24]
            get_user_ip(p, szIP, charsmax(szIP), 1)
            if (equal(szIP, szArg))
            {
                iTarget = p
                break
            }
        }

        if (iTarget)
            return RT_OK

        new szIP[24] = ""
        BuildGagKey(szIP, szArg, szKey, iKeyLen)
        return RT_OK
    }

    // --- nick: exact pass first, then case-insensitive substring pass ---
    new iMatches
    for (new pass = 0; pass < 2 && !iMatches; pass++)
    {
        for (new p = 1; p <= MaxClients; p++)
        {
            if (!is_user_connected(p) || is_user_bot(p) || is_user_hltv(p))
                continue
            new szName[32]
            get_user_name(p, szName, charsmax(szName))
            new bool:bHit = false
            if (pass)
            {
                if (containi(szName, szArg) != -1)
                    bHit = true
            }
            else if (equali(szName, szArg))
            {
                bHit = true
            }
            if (bHit)
                iMatches++
        }
        if (iMatches == 1)
        {
            // re-find single match
            for (new p = 1; p <= MaxClients; p++)
            {
                if (!is_user_connected(p) || is_user_bot(p) || is_user_hltv(p))
                    continue
                new szName[32]
                get_user_name(p, szName, charsmax(szName))
                new bool:bHit = false
                if (pass)
                {
                    if (containi(szName, szArg) != -1)
                        bHit = true
                }
                else if (equali(szName, szArg))
                {
                    bHit = true
                }
                if (bHit)
                {
                    iTarget = p
                    break
                }
            }
        }
        else if (iMatches > 1)
        {
            return RT_AMBIGUOUS
        }
    }

    if (!iTarget)
        return RT_NO_MATCH

    return RT_OK
}

// Panel hierarchy parity (freenova_panel CanModerate): only a manager ("a")
// may moderate a target carrying the full admin flag set, and manager->manager
// + self are refused. Applied to ALL target forms (#userid is what the panel
// emits) in the command handlers - ResolveTarget itself cannot do it because
// the steamid/ip offline paths have no live target to inspect. Console (id 0)
// bypasses (panel server_cmd path).
PassHierarchy(iInvoker, iTarget)
{
    if (!iInvoker)
        return true
    // M13: administrators may act on themselves (self-gag/ungag for testing).
    // Hierarchy below still protects OTHER players; self needs no immunity.
    if (iInvoker == iTarget)
        return true
    if (!(get_user_flags(iTarget) & FLAG_ADMIN))
        return true
    if (!(get_user_flags(iInvoker) & FLAG_MANAGER))
        return false
    if (get_user_flags(iTarget) & FLAG_MANAGER)
        return false
    return true
}

IsIpLiteral(const sz[])
{
    new iLen = strlen(sz)
    if (iLen < 7 || iLen > 15)
        return false
    new iDots
    for (new i = 0; i < iLen; i++)
    {
        new c = sz[i]
        if (c == '.')
        {
            iDots++
            if (i == 0 || sz[i - 1] == '.')
                return false
        }
        else if (!isdigit(c))
            return false
    }
    return (iDots == 3)
}

// ============================================================================
// COMMANDS
// ============================================================================

public Cmd_AdminGag(id, level, cid)
{
    if (!cmd_access(id, level, cid, 1))
        return PLUGIN_HANDLED

    // Belt & braces on top of the concmd access bits (panel parity gate)
    if (id && !(get_user_flags(id) & FLAG_ADMIN))
    {
        AdminMsg(id, "^4[FreeNova]^1 Admin only.")
        return PLUGIN_HANDLED
    }

    new szTarget[64], szMinutes[16], szType[8]
    read_argv(1, szTarget, charsmax(szTarget))
    read_argv(2, szMinutes, charsmax(szMinutes))
    read_argv(3, szType, charsmax(szType))
    trim(szTarget)

    if (!szTarget[0] || !szMinutes[0] || !szType[0])
    {
        AdminMsg(id, "^4[FreeNova]^1 Usage: amx_gag <target> <minutes> <a|b|c> [reason]")
        return PLUGIN_HANDLED
    }

    new iMinutes = str_to_num(szMinutes)
    if (iMinutes < 0)
    {
        AdminMsg(id, "^4[FreeNova]^1 Invalid duration (0 = permanent).")
        return PLUGIN_HANDLED
    }
    if (iMinutes > MAX_MINUTES)
        iMinutes = MAX_MINUTES

    // type must be a non-empty subset of a|b|c (panel sends exactly one)
    for (new i = 0; szType[i]; i++)
    {
        new c = szType[i]
        if (c != 'a' && c != 'b' && c != 'c')
        {
            AdminMsg(id, "^4[FreeNova]^1 Invalid type - use a (chat), b (team chat) or c (voice).")
            return PLUGIN_HANDLED
        }
    }
    new iFlags = read_flags(szType)
    if (!iFlags)
    {
        AdminMsg(id, "^4[FreeNova]^1 Invalid type - use a, b or c.")
        return PLUGIN_HANDLED
    }

    new iTarget
    new szKey[MAX_GAG_KEY]
    new iRes = ResolveTarget(szTarget, iTarget, szKey, charsmax(szKey))

    switch (iRes)
    {
        case RT_INVALID:    AdminMsg(id, "^4[FreeNova]^1 Invalid target.")
        case RT_AMBIGUOUS:  AdminMsg(id, "^4[FreeNova]^1 More than one player matches that nick - use #userid.")
        case RT_NO_MATCH:   AdminMsg(id, "^4[FreeNova]^1 No player matches that target.")
    }
    if (iRes != RT_OK)
        return PLUGIN_HANDLED

    // Hierarchy gate (CanModerate parity) - live targets only, all target forms
    if (iTarget && !PassHierarchy(id, iTarget))
    {
        AdminMsg(id, "^4[FreeNova]^1 You cannot moderate this player.")
        return PLUGIN_HANDLED
    }

    new szReason[MAX_GAG_REASON + 1]
    ReadReason(szReason, charsmax(szReason))

    new iNow = get_systime()
    new iExpire = iMinutes ? (iNow + iMinutes * 60) : 0

    new szFlagStr[8]
    get_flags(iFlags, szFlagStr, charsmax(szFlagStr))

    if (iTarget)
    {
        new szAuth[40], szIP[24]
        get_user_authid(iTarget, szAuth, charsmax(szAuth))
        get_user_ip(iTarget, szIP, charsmax(szIP), 1)

        // REPLACE semantics (documented in header)
        g_iGagFlags[iTarget] = iFlags
        g_iGagExpire[iTarget] = iExpire
        copy(g_szGagReason[iTarget], charsmax(g_szGagReason[]), szReason)
        SaveGagToVault(iTarget, szAuth, szIP)

        new szName[32]
        get_user_name(iTarget, szName, charsmax(szName))

        g_fPrintOk[iTarget] = get_gametime() + 0.3
        if (iMinutes)
            client_print_color(iTarget, print_team_default,
                "^4[FreeNova]^1 You have been gagged for %d minute%s (%s).%s%s",
                iMinutes, iMinutes == 1 ? "" : "s", szFlagStr,
                szReason[0] ? " Reason: " : "", szReason[0] ? szReason : "")
        else
            client_print_color(iTarget, print_team_default,
                "^4[FreeNova]^1 You have been gagged permanently (%s).%s%s",
                szFlagStr,
                szReason[0] ? " Reason: " : "", szReason[0] ? szReason : "")

        if (iFlags & GAG_VOICE)
            VoiceMuteAll(iTarget)

        new szAdmin[32]
        get_user_name(id, szAdmin, charsmax(szAdmin))
        log_amx("[FreeNova][Gag] Admin %s gagged %s (%s, %d min, permanent=%d) reason: %s",
            szAdmin, szName, szFlagStr, iMinutes, iMinutes ? 0 : 1,
            szReason[0] ? szReason : "-")

        if (id == iTarget)
            AdminMsg(id, "^4[FreeNova]^1 You gagged yourself for %s.",
                iMinutes ? fmt("%d minute%s", iMinutes, iMinutes == 1 ? "" : "s") : "permanently")
        else if (id)
            AdminMsg(id, "^4[FreeNova]^1 %s gagged for %s.", szName,
                iMinutes ? fmt("%d minute%s", iMinutes, iMinutes == 1 ? "" : "s") : "permanently")
        else
            server_print("[FreeNova][Gag] %s gagged (%s, %d min) - contract satisfied",
                szName, szFlagStr, iMinutes)
    }
    else
    {
        // Offline steamid/ip identity: store only, applies on next connect.
        new szValue[128]
        formatex(szValue, charsmax(szValue), "%d|%d|%s", iFlags, iExpire, szReason)

        if (g_iVault == INVALID_HANDLE)
        {
            AdminMsg(id, "^4[FreeNova]^1 Vault unavailable - offline gag not stored.")
            return PLUGIN_HANDLED
        }
        nvault_set(g_iVault, szKey, szValue)

        log_amx("[FreeNova][Gag] Admin offline-gagged key %s (%s, %d min) reason: %s",
            szKey, szFlagStr, iMinutes, szReason[0] ? szReason : "-")
        AdminMsg(id, "^4[FreeNova]^1 Target offline - gag stored (key %s), applies on next connect.", szKey)
    }

    return PLUGIN_HANDLED
}

public Cmd_AdminUngag(id, level, cid)
{
    if (!cmd_access(id, level, cid, 1))
        return PLUGIN_HANDLED

    if (id && !(get_user_flags(id) & FLAG_ADMIN))
    {
        AdminMsg(id, "^4[FreeNova]^1 Admin only.")
        return PLUGIN_HANDLED
    }

    new szTarget[64]
    read_argv(1, szTarget, charsmax(szTarget))
    trim(szTarget)
    if (!szTarget[0])
    {
        AdminMsg(id, "^4[FreeNova]^1 Usage: amx_ungag <target>")
        return PLUGIN_HANDLED
    }

    new iTarget
    new szKey[MAX_GAG_KEY]
    new iRes = ResolveTarget(szTarget, iTarget, szKey, charsmax(szKey))

    switch (iRes)
    {
        case RT_INVALID:    AdminMsg(id, "^4[FreeNova]^1 Invalid target.")
        case RT_AMBIGUOUS:  AdminMsg(id, "^4[FreeNova]^1 More than one player matches that nick - use #userid.")
        case RT_NO_MATCH:   AdminMsg(id, "^4[FreeNova]^1 No player matches that target.")
    }
    if (iRes != RT_OK)
        return PLUGIN_HANDLED

    // Hierarchy gate (CanModerate parity) - live targets only, all target forms
    if (iTarget && !PassHierarchy(id, iTarget))
    {
        AdminMsg(id, "^4[FreeNova]^1 You cannot moderate this player.")
        return PLUGIN_HANDLED
    }

    new szAdmin[32]
    get_user_name(id, szAdmin, charsmax(szAdmin))

    if (iTarget)
    {
        new szName[32]
        get_user_name(iTarget, szName, charsmax(szName))

        new bool:bHad = g_iGagFlags[iTarget] != 0
        GagClear(iTarget, true)

        if (!bHad && g_iVault != INVALID_HANDLE && szKey[0])
        {
            // live player without cached state - still purge a stale row
            nvault_remove(g_iVault, szKey)
        }

        log_amx("[FreeNova][Gag] Admin %s ungagged %s", szAdmin, szName)
        if (id && id == iTarget)
            AdminMsg(id, "^4[FreeNova]^1 You ungagged yourself.")
        else
            AdminMsg(id, "^4[FreeNova]^1 %s has been ungagged.", szName)
    }
    else
    {
        new bool:bFound = false
        if (g_iVault != INVALID_HANDLE && szKey[0])
        {
            new szValue[128], iStamp
            bFound = nvault_lookup(g_iVault, szKey, szValue, charsmax(szValue), iStamp) != 0
            if (bFound)
                nvault_remove(g_iVault, szKey)
        }

        if (bFound)
        {
            log_amx("[FreeNova][Gag] Admin %s removed offline gag key %s", szAdmin, szKey)
            AdminMsg(id, "^4[FreeNova]^1 Stored gag removed (key %s).", szKey)
        }
        else
        {
            AdminMsg(id, "^4[FreeNova]^1 No gag found for that target.")
        }
    }

    return PLUGIN_HANDLED
}

public Cmd_SayList(id)
{
    if (!is_user_connected(id) || !(get_user_flags(id) & FLAG_ADMIN))
        return PLUGIN_HANDLED
    return Cmd_AdminList(id, 0, 0)
}

public Cmd_AdminList(id, level, cid)
{
#pragma unused level, cid
    if (id && !(get_user_flags(id) & FLAG_ADMIN))
    {
        AdminMsg(id, "^4[FreeNova]^1 Admin only.")
        return PLUGIN_HANDLED
    }

    new iCount, iNow = get_systime()
    for (new p = 1; p <= MaxClients; p++)
    {
        if (!is_user_connected(p) || !g_iGagFlags[p])
            continue
        new szName[32], szFlags[8]
        get_user_name(p, szName, charsmax(szName))
        get_flags(g_iGagFlags[p], szFlags, charsmax(szFlags))
        if (g_iGagExpire[p])
        {
            new iLeft = g_iGagExpire[p] - iNow
            if (iLeft < 0) iLeft = 0
            AdminMsg(id, "^4[FreeNova]^1 %s (%s) - %d min left%s%s", szName, szFlags,
                (iLeft + 59) / 60, g_szGagReason[p][0] ? " - " : "", g_szGagReason[p])
        }
        else
            AdminMsg(id, "^4[FreeNova]^1 %s (%s) - permanent%s%s", szName, szFlags,
                g_szGagReason[p][0] ? " - " : "", g_szGagReason[p])
        iCount++
    }
    if (!iCount)
        AdminMsg(id, "^4[FreeNova]^1 No active gags.")
    else
        log_amx("[FreeNova][Gag] Admin listed %d active gag(s)", iCount)
    return PLUGIN_HANDLED
}

// reason = argv 4..n joined with spaces (panel sends none today)
ReadReason(szOut[], iLen)
{
    szOut[0] = 0

    new iArgs = read_argc()
    for (new i = 4; i < iArgs; i++)
    {
        new szTok[64]
        read_argv(i, szTok, charsmax(szTok))
        remove_quotes(szTok)
        if (!szTok[0])
            continue
        if (szOut[0])
            add(szOut, iLen, " ")
        add(szOut, iLen, szTok)
    }
    trim(szOut)

    // sanitize: single-line, no vault separator, printable ASCII only
    replace_all(szOut, iLen, "|", "/")
    for (new i = 0; szOut[i]; i++)
    {
        if (szOut[i] < 32 || szOut[i] == 127)
            szOut[i] = ' '
    }
    trim(szOut)
    if (strlen(szOut) > MAX_GAG_REASON)
        szOut[MAX_GAG_REASON] = 0
}

// ============================================================================
// NOTICES / MISC
// ============================================================================

NotifyGagged(id, bool:bOnConnect = false)
{
    new Float:fNow = get_gametime()
    new Float:fInterval = get_pcvar_float(g_pCvarNotice)
    if (fInterval < 0.0)
        fInterval = 0.0

    if (!bOnConnect && fNow < g_fNoticeAt[id])
        return
    g_fNoticeAt[id] = fNow + fInterval

    new szFlags[8]
    get_flags(g_iGagFlags[id], szFlags, charsmax(szFlags))

    g_fPrintOk[id] = fNow + 0.3

    if (g_iGagExpire[id])
    {
        new iLeft = g_iGagExpire[id] - get_systime()
        if (iLeft < 0)
            iLeft = 0
        new iMin = (iLeft + 59) / 60
        client_print_color(id, print_team_default,
            "^4[FreeNova]^1 You are gagged (%s) - %d minute%s left.%s%s",
            szFlags, iMin, iMin == 1 ? "" : "s",
            g_szGagReason[id][0] ? " Reason: " : "",
            g_szGagReason[id][0] ? g_szGagReason[id] : "")
    }
    else
    {
        client_print_color(id, print_team_default,
            "^4[FreeNova]^1 You are gagged (%s) - permanent.%s%s",
            szFlags,
            g_szGagReason[id][0] ? " Reason: " : "",
            g_szGagReason[id][0] ? g_szGagReason[id] : "")
    }
}

stock AdminMsg(id, const szFmt[], any:...)
{
    new szMsg[192]
    vformat(szMsg, charsmax(szMsg), szFmt, 3)

    // M13: route everything through the central chat service (chat for
    // players, stripped console_print for id 0). Strip the legacy inline
    // prefix first — fn_chat_info() adds the canonical one.
    new iOff = 0
    if (equal(szMsg, "^4[FreeNova]^1 ", 15))
        iOff = 15
    else if (equal(szMsg, "^4[FreeNova]^1", 14))
        iOff = 14
    fn_chat_info(id, "%s", szMsg[iOff])
}

IsChatCommand(c)
{
    return (c == '/' || c == '!' || c == '.' || c == ',' || c == '@' || c == '#')
}

// Bare-word vote/utility commands gagged players may still use.
// Mapvote registers say rtv / say nominate (no slash); timeleft/nextmap
// are stock info commands. First token match, optional prefix stripped.
IsGagExemptCommand(const szMsg[])
{
    new szFirst[32], szRest[160]
    parse(szMsg, szFirst, charsmax(szFirst), szRest, 0)
    trim(szFirst)
    if (!szFirst[0])
        return false

    new iOff = 0
    if (szFirst[0] == '/' || szFirst[0] == '!' || szFirst[0] == '.'
        || szFirst[0] == ',' || szFirst[0] == '@' || szFirst[0] == '#')
        iOff = 1

    new szCmd[32]
    copy(szCmd, charsmax(szCmd), szFirst[iOff])
    trim(szCmd)

    if (equali(szCmd, "rtv") || equali(szCmd, "nominate") || equali(szCmd, "nom")
        || equali(szCmd, "noms") || equali(szCmd, "nomlist")
        || equali(szCmd, "votemap") || equali(szCmd, "votehelp")
        || equali(szCmd, "mapvote") || equali(szCmd, "timeleft")
        || equali(szCmd, "nextmap") || equali(szCmd, "thetime"))
        return true
    return false
}

find_char(const szStr[], const cChar)
{
    new iLen = strlen(szStr)
    for (new i = 0; i < iLen; i++)
    {
        if (szStr[i] == cChar)
            return i
    }
    return -1
}
