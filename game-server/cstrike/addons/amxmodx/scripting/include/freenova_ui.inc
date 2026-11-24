// FreeNova UI kit - shared stocks for every plugin that renders player-facing
// HTML (MOTD) or formats numbers. This file is the single source of truth for
// the FreeNova web/MOTD design language; plugins include it instead of each
// carrying their own copy of the theme.
//
// Palette (from the FreeNova logo - black/charcoal + neon lime green):
//   bg #0D0F0E | card #1E2422 | border #2A3A36
//   green #36DEAB | green-main #2EBF92 | text #EDF1EF | muted #8A948F
//
// GoldSrc MOTD notes:
//   - Keep total output under ~1400 chars (old renderer truncates silently).
//   - Inline CSS only, table layouts, no external fonts, no JS.

#if defined _freenova_ui_included
    #endinput
#endif
#define _freenova_ui_included

// ---------------------------------------------------------------- escaping

// Escape a player-supplied string (names, chat) for safe HTML output.
stock FN_EscapeHtml(const szInput[], szOutput[], iLen)
{
    new szTemp[128]
    copy(szTemp, charsmax(szTemp), szInput)

    replace_all(szTemp, charsmax(szTemp), "&", "&amp;")
    replace_all(szTemp, charsmax(szTemp), "<", "&lt;")
    replace_all(szTemp, charsmax(szTemp), ">", "&gt;")
    replace_all(szTemp, charsmax(szTemp), "^"", "&quot;")
    replace_all(szTemp, charsmax(szTemp), "'", "&#39;")

    copy(szOutput, iLen, szTemp)
}

// ---------------------------------------------------------------- numbers

// 1562912 -> "1,562,912"
stock FN_AddCommas(iValue, szOutput[], iLen)
{
    new szRaw[16]
    num_to_str(iValue, szRaw, charsmax(szRaw))

    new iRawLen = strlen(szRaw)
    new iPos = 0
    new iCommas = (iRawLen - 1) / 3

    for (new i = 0, iWritten; i < iRawLen; i++)
    {
        if (i && ((iRawLen - i) % 3) == 0 && iPos < iLen - 1 && iCommas > 0)
        {
            szOutput[iPos++] = ','
            iCommas--
        }
        iWritten = copy(szOutput[iPos], iLen - iPos - 1, szRaw[i])
        if (iWritten < 1) break
        iPos += iWritten
    }
    szOutput[iPos] = 0
}

// ---------------------------------------------------------------- progress

// AMXX-safe text bar: FN_TextBar(75, 18) -> "===========------"
stock FN_TextBar(iPercent, iWidth, szOutput[], iLen)
{
    if (iWidth >= iLen) iWidth = iLen - 1
    if (iPercent < 0) iPercent = 0
    if (iPercent > 100) iPercent = 100

    new iFilled = (iWidth * iPercent) / 100
    new iPos

    for (new i = 0; i < iFilled && iPos < iWidth; i++)
        szOutput[iPos++] = '='

    for (new i = iFilled; i < iWidth; i++)
        szOutput[iPos++] = '-'

    szOutput[iPos] = 0
}

// ---------------------------------------------------------------- MOTD

// Shared FreeNova CSS block - compact variant sized for the GoldSrc text-MOTD
// budget (~1500 bytes total per page, see scripts/test_motd_buffer.py).
stock FN_MotdCss(szBuffer[], iLen)
{
    new iPos
    iPos += copy(szBuffer[iPos], iLen - iPos,
        "body{background:#0D0F0E;color:#EDF1EF;font:13px Verdana,Arial;margin:6px;}")
    iPos += copy(szBuffer[iPos], iLen - iPos, ".fnh{text-align:center;border-bottom:2px solid #2EBF92;padding-bottom:4px;margin-bottom:5px;}")
    iPos += copy(szBuffer[iPos], iLen - iPos, ".fnbrand{color:#36DEAB;font-size:20px;font-weight:bold;letter-spacing:3px;}")
    iPos += copy(szBuffer[iPos], iLen - iPos, ".fnsub{color:#8A948F;font-size:9px;letter-spacing:2px;}")
    iPos += copy(szBuffer[iPos], iLen - iPos, ".fntitle{color:#FFFFFF;font-size:14px;font-weight:bold;}")
    iPos += copy(szBuffer[iPos], iLen - iPos, ".fnt{width:100%;border-collapse:collapse;}")
    iPos += copy(szBuffer[iPos], iLen - iPos, ".fnt th{background:#1E2422;color:#36DEAB;padding:3px 5px;font-size:11px;text-align:left;}")
    iPos += copy(szBuffer[iPos], iLen - iPos, ".fnt td{padding:2px 5px;border-bottom:1px solid #1E2422;}")
    iPos += copy(szBuffer[iPos], iLen - iPos, ".fnt .k{color:#8A948F;}")
    iPos += copy(szBuffer[iPos], iLen - iPos, ".fnt .v{text-align:right;color:#E8B93C;font-weight:bold;}")
    iPos += copy(szBuffer[iPos], iLen - iPos, ".fnr1{color:#36DEAB;font-weight:bold;}.fnr2{color:#C8D3C8;font-weight:bold;}.fnr3{color:#CD7F32;font-weight:bold;}")
    iPos += copy(szBuffer[iPos], iLen - iPos, ".fnyou{background:#1E2422;border-left:3px solid #36DEAB;}")
    iPos += copy(szBuffer[iPos], iLen - iPos, ".fngreen{color:#36DEAB;}.fnmuted{color:#8A948F;}.fnbar{color:#2EBF92;}")
    copy(szBuffer[iPos], iLen - iPos, ".fnf{text-align:center;color:#8A948F;font-size:9px;margin-top:8px;border-top:1px solid #2A3A36;padding-top:3px;}")
}

// Opens a FreeNova MOTD document: DOCTYPE + head + brand header.
// szHeading is the page heading; szSub is the small line under it.
stock FN_MotdHeader(szBuffer[], iLen, const szHeading[] = "", const szSub[] = "")
{
    new szCss[1024]
    FN_MotdCss(szCss, charsmax(szCss))

    new iLenOut
    iLenOut = formatex(szBuffer, iLen,
        "<html><head><style>%s</style></head><body>", szCss)
    iLenOut += copy(szBuffer[iLenOut], iLen - iLenOut,
        "<div class='fnh'><span class='fnbrand'>FREENOVA</span><br><span class='fnsub'>THE ULTIMATE GAMING NETWORK</span>")
    if (szHeading[0])
        iLenOut += formatex(szBuffer[iLenOut], iLen - iLenOut,
            "<div class='fntitle'>%s</div>", szHeading)
    if (szSub[0])
        iLenOut += formatex(szBuffer[iLenOut], iLen - iLenOut,
            "<div class='fnmuted' style='font-size:11px;'>%s</div>", szSub)
    iLenOut += copy(szBuffer[iLenOut], iLen - iLenOut, "</div>")
    return iLenOut
}

// Closes a FreeNova MOTD document with the standard footer.
stock FN_MotdFooter(szBuffer[], iLen, iPos)
{
    return copy(szBuffer[iPos], iLen - iPos,
        "<div class='fnf'>FreeNova &bull; The Ultimate Gaming Network</div></body></html>")
}

// Shared chat prefix and community contact (single source; cvars override).
// Open an FN-themed MOTD via a per-player temp file, then show_motd on the
// file path (same mechanism as freenova_rules.html). AMXX fprintf truncates
// a single large %s arg, so the HTML is written in ~190-char chunks.
stock FN_MotdShow(id, const szHtml[], const szTitle[])
{
    new szPath[96]
    formatex(szPath, charsmax(szPath), "addons/amxmodx/configs/freenova/motd_%d.html", id)
    new f = fopen(szPath, "wt")
    if (!f)
    {
        show_motd(id, szHtml, szTitle)
        return
    }
    new iLen = strlen(szHtml)
    new iOff = 0
    while (iOff < iLen)
    {
        new chunk[192]
        new n = iLen - iOff
        if (n > 191)
            n = 191
        copy(chunk, 191, szHtml[iOff])
        chunk[n] = 0
        fprintf(f, "%s", chunk)
        iOff += n
    }
    fclose(f)
    show_motd(id, szPath, szTitle)
}

// ---------------------------------------------------------------- Tornado theme
// Dark-maroon panels, gold headers, purple XP, cyan accents - matches the
// Tornado reference MOTDs. Used by top15 / profile / rankstats / battlepass.
stock FN_TornadoCss(szBuffer[], iLen)
{
    // MICRO-MICRO (~150B): text-MOTD pages must stay under ~1500B TOTAL.
    // Only body + title + right-values survive; everything else is plain HTML.
    new iPos
    iPos += copy(szBuffer[iPos], iLen - iPos, "body{background:#0D0F0E;color:#FFF;font:12px Verdana;margin:4px}")
    iPos += copy(szBuffer[iPos], iLen - iPos, ".tnt{color:#F5A623;font-size:20px;font-weight:bold}")
    iPos += copy(szBuffer[iPos], iLen - iPos, ".v{text-align:right;font-weight:bold}")
    return iPos
}// Tornado page open: title bar + panel open. Returns write position.
stock FN_TornadoHead(szBuffer[], iLen, const szTitle[], const szSub[] = "")
{
    new szCss[512]
    FN_TornadoCss(szCss, charsmax(szCss))
    new iLenOut
    iLenOut = formatex(szBuffer, iLen, "<html><head><style>%s</style></head><body>", szCss)
    iLenOut += formatex(szBuffer[iLenOut], iLen - iLenOut, "<div class='tnt'>%s</div>", szTitle)
    if (szSub[0])
        iLenOut += formatex(szBuffer[iLenOut], iLen - iLenOut, "<div class='fnmuted'>%s</div>", szSub)
    iLenOut += copy(szBuffer[iLenOut], iLen - iLenOut, "<div class='tnp'>")
    return iLenOut
}

// Tornado page close: panel close + footer.
stock FN_TornadoFoot(szBuffer[], iLen, iPos)
{
    iPos += copy(szBuffer[iPos], iLen - iPos, "</div>")
    return copy(szBuffer[iPos], iLen - iPos,
        "<div class='fnf'>FreeNova &bull; The Ultimate Gaming Network</div></body></html>")
}

#define FN_CHAT_PREFIX "^4[FreeNova]^1"

stock FN_GetDiscordUrl(szOut[], iLen)
{
    get_cvar_string("fn_discord_url", szOut, iLen)
    if (!szOut[0])
        copy(szOut, iLen, "https://discord.gg/as8kzp5KAz")
}

stock FN_GetDiscordHandle(szOut[], iLen)
{
    get_cvar_string("fn_discord_handle", szOut, iLen)
    if (!szOut[0])
        copy(szOut, iLen, "zizouondc")
}

stock FN_GetBpTierFromXp(iXp)
{
    if (iXp < 0)
        iXp = 0
    new iTier = iXp / 1000
    if (iTier > 60)
        iTier = 60
    return iTier
}

// Menu title language used by hub / shop / panel. iCoins < 0 omits the balance.
stock FN_MenuTitle(szOut[], iLen, const szName[], iCoins = -1)
{
    if (iCoins >= 0)
        formatex(szOut, iLen, "\yFreeNova \r| \w%s  \d%d coins", szName, iCoins)
    else
        formatex(szOut, iLen, "\yFreeNova \r| \w%s", szName)
}

stock FN_MenuRow(szOut[], iLen, const szLabel[], const szState[])
{
    if (szState[0])
        formatex(szOut, iLen, "\w%s \d- %s", szLabel, szState)
    else
        formatex(szOut, iLen, "\w%s", szLabel)
}

// Append " [Need]" when the player cannot afford iNeed. Empty string otherwise.
stock FN_NeedSuffix(iHave, iNeed, szOut[], iLen)
{
    if (iHave >= iNeed)
        szOut[0] = 0
    else
        formatex(szOut, iLen, " \rNeed")
}

// Shared menu chrome. bBack = true labels the 0-key as Back (submenus).
stock FN_MenuFinish(menu, bool:bBack = false)
{
    if (bBack)
        menu_setprop(menu, MPROP_EXITNAME, "\wBack")
    else
        menu_setprop(menu, MPROP_EXITNAME, "\wExit")
    menu_setprop(menu, MPROP_NUMBER_COLOR, "\y")
}
