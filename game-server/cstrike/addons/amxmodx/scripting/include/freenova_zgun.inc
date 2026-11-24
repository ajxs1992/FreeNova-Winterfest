// =============================================================================
//  FreeNova — ZG-7 "ZGUN" · VIP custom sniper · shared configuration
//  Counter-Strike 1.6 · AMX Mod X 1.10 · ReHLDS + ReAPI
// =============================================================================
//
//  MODEL ANALYSIS (why these constants are what they are)
//  -----------------------------------------------------------------------
//  Weapon model : models/VENOMIX/v_awpz.mdl   (internal name "v_zgun.mdl")
//  Container    : GoldSrc studio v10  (magic "IDST", version 10), 830 444 bytes
//
//  The file was parsed directly (see reports/model_analysis.md). Tables are
//  GoldSrc studio structures: sequence descriptors are 176 bytes each, textures
//  are 80 bytes each. The sequence table sits at file offset 149148 and holds
//  exactly six entries:
//
//     idx  label      fps   frames   duration  loop
//     ---  ---------  ----  ------   --------  ---
//       0  'idle1'     30      121   4.03 s    yes
//       1  'shoot1'    30       34   1.13 s    no
//       2  'shoot2'    30       34   1.13 s    no
//       3  'shoot3'    30       34   1.13 s    no
//       4  'reload'    30       81   2.70 s    no
//       5  'draw'      30       31   1.03 s    no
//
//  Textures: zgun_v.bmp (512x512), zgunhand.bmp (512x512).
//  Neither carries a '#' (no-cheat) or '@' (cheat) skin prefix, so the weapon
//  renders on every client — several other models in the same pack were
//  rejected during selection for exactly that reason.
//
//  THAT ORDER IS THE POINT.  Stock CS 1.6 v_awp.mdl has the identical six
//  sequences in the identical order, and CS resolves every AWP animation
//  (idle / fire cycle / reload / deploy) through that fixed table.  Because the
//  custom model matches it, the engine drives all animations natively — no
//  send_anim() calls are needed.  Note that no stock CS 1.6 weapon model
//  contains a 'holster' sequence, so its absence here is normal, not a defect.
//
//  Third person / ground models carry a single static 'idle' sequence, which is
//  how every CS custom-weapon pack ships them: the third-person pose is simply
//  held on that one frame while the first-person view animates.
// =============================================================================

#if defined _freenova_zgun_included
    #endinput
#endif
#define _freenova_zgun_included

// ---------------------------------------------------------------- identity --
#define ZGUN_DISPLAY_NAME  "ZG-7 Zgun"
#define ZGUN_WIKI_NAME     "zgun"

// ------------------------------------------------------------ model assets --
// Install all three files to cstrike\models\VENOMIX\ before loading the plugin.
#define ZGUN_VIEW_MODEL    "models/VENOMIX/v_awpz.mdl"    // first person
#define ZGUN_PLAYER_MODEL  "models/VENOMIX/p_awpz.mdl"    // third person
#define ZGUN_WORLD_MODEL   "models/VENOMIX/w_awpz.mdl"    // dropped on ground

// --------------------------------------------- sequences (model-derived) ----
#define ZGUN_SEQ_IDLE      0   // 'idle1'  30 fps  121 f  = 4.03 s (loop)
#define ZGUN_SEQ_SHOOT1    1   // 'shoot1' 30 fps   34 f  = 1.13 s
#define ZGUN_SEQ_SHOOT2    2   // 'shoot2' 30 fps   34 f  = 1.13 s
#define ZGUN_SEQ_SHOOT3    3   // 'shoot3' 30 fps   34 f  = 1.13 s
#define ZGUN_SEQ_RELOAD    4   // 'reload' 30 fps   81 f  = 2.70 s
#define ZGUN_SEQ_DRAW      5   // 'draw'   30 fps   31 f  = 1.03 s
#define ZGUN_SEQ_COUNT     6

// Durations derived from the table above, used for the deploy gate and the
// in-game spec sheet so the numbers quoted to players are the model's real
// animation lengths rather than guesses.
#define ZGUN_DRAW_TIME     1.0     // 'draw'  plays for 1.03 s
#define ZGUN_RELOAD_TIME   2.7     // 'reload' plays for 2.70 s
#define ZGUN_BOLT_TIME     1.1     // bolt cycle, 'shoot1..3' play for 1.13 s

// ------------------------------------------------------------- gameplay -----
// Base engine class: the sniper slot. AMX Mod X 1.10 removed the classic custom
// weapon API (cs_register_weapon / register_weapon / send_anim /
// send_user_weapon_anim / cs_get_user_ammo); see report for the evidence.  The
// ZG-7 therefore drives the stock sniper class, which is precisely why matching
// the model's sequence layout to v_awp.mdl matters.
#define ZGUN_BASE_WEAPON   CSW_AWP

#define ZGUN_MAX_AMMO      30      // reserve rounds on pickup
#define ZGUN_DAMAGE_SCOPED 260      // one shot, head or body, while scoped
#define ZGUN_UNSCOPED_PCT  45       // hip-fire damage, as a whole percent
#define ZGUN_UNSCOPED_MULT (ZGUN_UNSCOPED_PCT / 100.0)
#define ZGUN_REFILL_AMMO   30      // reserve topped up to this during buy time

// ---------------------------------------------------------- VIP gate -------
// AMX Mod X maps an arbitrary flag letter onto bit (letter - 'a'), so 't' is a
// legal custom flag and is set with `amx_addadmin "<steamid>" "t"` or
// `set_flags "<name>" "t"`. The letter is a cvar so it can be changed without a
// recompile; the FreeNova VIP tier is accepted as an alternative path.
#define ZGUN_DEFAULT_FLAG      "t"
#define ZGUN_DEFAULT_MINTIER   FNVIP_VIP      // cell, for comparisons
#define ZGUN_MINTIER_STR       "1"           // string form, for register_cvar

// --------------------------------------------------------- zoom values ------
// cs_get_user_zoom() return values.
#define ZGUN_ZOOM_NONE     0
#define ZGUN_ZOOM_FIRST    1
#define ZGUN_ZOOM_SECOND   2

// ------------------------------------------------------------ cvar names ----
#define ZGUN_CVAR_ENABLED     "freenova_zgun_enabled"
#define ZGUN_CVAR_FLAG        "freenova_zgun_flag"
#define ZGUN_CVAR_VIPTIER     "freenova_zgun_allow_vip_tier"
#define ZGUN_CVAR_MINTIER     "freenova_zgun_min_tier"
#define ZGUN_CVAR_MENU        "freenova_zgun_menu_on_command"
#define ZGUN_CVAR_DROP        "freenova_zgun_drop_on_death"
#define ZGUN_CVAR_DEBUG       "freenova_zgun_debug"

// -------------------------------------------------------------- limits ------
// ZGUN_TASK_HUD was removed here: nothing ever scheduled a HUD task.
#define ZGUN_TASK_REFRESH    48000      // id + this  (model re-assert)
#define ZGUN_REFRESH_TIME    0.5

// ------------------------------------------------------------ config file ---
#define CONFIG_NAME          "freenova_zgun.cfg"

// =============================================================================
//  Self-contained UI helpers
// =============================================================================
//  Copies of the small slice of the FreeNova UI kit this plugin uses, so the
//  weapon drops onto any AMX Mod X 1.10 server without needing the FreeNova
//  include tree present at compile time. Palette matches freenova_ui.inc.
stock Zgun_MenuTitle(szOut[], iLen, const szName[])
{
    formatex(szOut, iLen, "\yFreeNova \r- \w%s", szName)
}

stock Zgun_MenuRow(szOut[], iLen, const szLabel[], const szState[])
{
    if (szState[0]) formatex(szOut, iLen, "\w%s \d[ %s ]", szLabel, szState)
    else formatex(szOut, iLen, "\w%s", szLabel)
}

stock Zgun_MenuFinish(menu, bool:bBack = false)
{
    if (bBack) menu_setprop(menu, MPROP_EXITNAME, "\wBack")
    else menu_setprop(menu, MPROP_EXITNAME, "\wExit")
    menu_setprop(menu, MPROP_NUMBER_COLOR, "\y")
}

stock Zgun_MotdCss(szOut[], iLen)
{
    formatex(szOut, iLen,
        "body{background:#0D0F0E;color:#EDF1EF;font:12px Verdana,Arial;margin:6px;}.fnh{text-align:center;border-bottom:2px solid #2EBF92;padding-bottom:4px;margin-bottom:5px;}.fnbrand{color:#36DEAB;font-size:18px;font-weight:bold;letter-spacing:3px;}.fntitle{color:#FFFFFF;font-size:14px;font-weight:bold;}.fnmuted{color:#8A948F;font-size:10px;}.fnt{width:100%%;border-collapse:collapse;}.fnt th{background:#1E2422;color:#36DEAB;padding:3px 5px;font-size:11px;text-align:left;}.fnt td{padding:2px 5px;border-bottom:1px solid #1E2422;}.fnt .k{color:#8A948F;}.fnt .v{text-align:right;color:#FFFFFF;}.fnyou{background:#1E2422;border-left:3px solid #36DEAB;}.fngreen{color:#36DEAB;}")
}

stock Zgun_MotdHeader(szOut[], iLen, const szHeading[], const szSub[] = "")
{
    new szCss[1024]
    Zgun_MotdCss(szCss, charsmax(szCss))

    new iLen2 = formatex(szOut, iLen,
        "<html><head><style>%s</style></head><body>", szCss)
    iLen2 += formatex(szOut[iLen2], iLen - iLen2,
        "<div class='fnh'><span class='fnbrand'>FREENOVA</span><br><div class='fntitle'>%s</div>",
        szHeading)
    if (szSub[0])
        iLen2 += formatex(szOut[iLen2], iLen - iLen2, "<div class='fnmuted'>%s</div>", szSub)
    return iLen2 + formatex(szOut[iLen2], iLen - iLen2, "</div>")
}

stock Zgun_MotdFooter(szOut[], iLen, iPos)
{
    return formatex(szOut[iPos], iLen - iPos,
        "<div class='fnmuted' style='font-size:9px;margin-top:8px;border-top:1px solid #2A3A36;padding-top:3px;'>FreeNova</div></body></html>")
}