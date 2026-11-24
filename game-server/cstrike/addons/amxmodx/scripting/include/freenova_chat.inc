// FreeNova central colored-chat service (M13).
//
// Single source for ALL player-facing chat feedback. Every user-triggered
// action (command, menu, say-hook) must answer through fn_chat_* so success,
// failure, permission and usage look and read the same everywhere.
//
// Design rules (see CHAT_FEEDBACK_STANDARD.md):
//   - Prefix is always ^4[FreeNova]^1 (FN_CHAT_PREFIX from freenova_ui.inc).
//   - GoldSrc chat supports ^1 (default) ^3 (team color) ^4 (green) only.
//     Do NOT invent RGB codes; the API maps severity onto supported codes.
//   - Player id 0 (server console/RCON) gets console_print with codes
//     stripped. NEVER send chat to client 0.
//   - Buffers are 192 chars to match the existing tree convention.
//   - vformat is used so %L language keys keep working.
//   - Perf: no loops, no SQL, no forwards; one format + one print per call.
//
// CROMCHAT RULE: files that #include <cromchat> WITHOUT
// CC_DONT_OVERWRITE_183_PRINT get client_print_color macro-hijacked, which
// would silently reroute the calls below. Any .sma including BOTH this file
// and cromchat MUST #define CC_DONT_OVERWRITE_183_PRINT before all includes.

#if defined _freenova_chat_included
    #endinput
#endif
#define _freenova_chat_included

#include <freenova_ui>
#include <amxmodx>

// Severity -> sender team (drives ^3 rendering). Prefix stays green.
#define FN_TEAM_SUCCESS print_team_default
#define FN_TEAM_INFO    print_team_default
#define FN_TEAM_USAGE   print_team_default
#define FN_TEAM_WARNING print_team_default
#define FN_TEAM_ERROR   print_team_red
#define FN_TEAM_PERM    print_team_red

// Strip GoldSrc color codes for console output.
stock _fn_strip_colors(szMsg[], iLen)
{
    replace_all(szMsg, iLen, "^4", "")
    replace_all(szMsg, iLen, "^3", "")
    replace_all(szMsg, iLen, "^1", "")
    replace_all(szMsg, iLen, "^2", "")
    return 1
}

// Core sender. Team selects the ^3 tint; body carries its own ^ codes.
stock fn_chat_raw(id, iTeam, const szBody[])
{
    // fn_chat_debug 1 writes the exact line (prefix and colour codes included) to
    // the server log: one switch for "what did this player actually receive?".
    // The colours are control bytes (0x01..0x04), and a log file drops them, so
    // they are re-escaped to the readable ^1..^4 form.
    if (get_cvar_num("fn_chat_debug"))
    {
        new szLine[224], szShow[256], j
        formatex(szLine, charsmax(szLine), "%s %s", FN_CHAT_PREFIX, szBody)
        for (new i = 0; szLine[i] && j < charsmax(szShow) - 2; i++)
        {
            if (szLine[i] >= 1 && szLine[i] <= 4)
            {
                szShow[j++] = 94   // '^' is the Pawn escape character, so its code
                szShow[j++] = '0' + szLine[i]
            }
            else if (szLine[i] == 94)
            {
                szShow[j++] = 94   // '^' is the Pawn escape character, so its code
                szShow[j++] = 94   // '^' is the Pawn escape character, so its code
            }
            else
                szShow[j++] = szLine[i]
        }
        szShow[j] = 0
        log_amx("[FN-CHAT] id=%d team=%d %s", id, iTeam, szShow)
    }

    if (id <= 0)
    {
        new szPlain[192]
        copy(szPlain, charsmax(szPlain), szBody)
        _fn_strip_colors(szPlain, charsmax(szPlain))
        console_print(0, "%s %s", FN_CHAT_PREFIX, szPlain)
        return 1
    }
    if (!is_user_connected(id))
        return 0
    client_print_color(id, iTeam, "%s %s", FN_CHAT_PREFIX, szBody)
    return 1
}

// Success: green identity, default body. Usage:
//   fn_chat_success(id, "gagged %s for %d minutes", szName, iMinutes)
stock fn_chat_success(id, const szFmt[], any:...)
{
    new szBody[192]
    vformat(szBody, charsmax(szBody), szFmt, 3)
    return fn_chat_raw(id, FN_TEAM_SUCCESS, szBody)
}

// Error: red sender. Plain language, how to resolve when possible.
// Never print raw internal errors here; log those server-side instead.
stock fn_chat_error(id, const szFmt[], any:...)
{
    new szBody[192]
    vformat(szBody, charsmax(szBody), szFmt, 3)
    return fn_chat_raw(id, FN_TEAM_ERROR, szBody)
}

// Warning: default sender, callers highlight key parts with ^3/^4.
stock fn_chat_warning(id, const szFmt[], any:...)
{
    new szBody[192]
    vformat(szBody, charsmax(szBody), szFmt, 3)
    return fn_chat_raw(id, FN_TEAM_WARNING, szBody)
}

// Info: default sender, ^1 body; highlight names/durations with ^4.
stock fn_chat_info(id, const szFmt[], any:...)
{
    new szBody[192]
    vformat(szBody, charsmax(szBody), szFmt, 3)
    return fn_chat_raw(id, FN_TEAM_INFO, szBody)
}

// Permission denial. Always names the missing capability in words.
stock fn_chat_permission(id, const szFmt[], any:...)
{
    new szBody[192]
    vformat(szBody, charsmax(szBody), szFmt, 3)
    return fn_chat_raw(id, FN_TEAM_PERM, szBody)
}

// Usage/syntax help. Short; details belong in amx_cmdhelp.
stock fn_chat_usage(id, const szFmt[], any:...)
{
    new szBody[192]
    vformat(szBody, charsmax(szBody), szFmt, 3)
    return fn_chat_raw(id, FN_TEAM_USAGE, szBody)
}
