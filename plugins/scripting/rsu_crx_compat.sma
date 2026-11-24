// ============================================================================
// rsu_crx_compat.sma
//
// CRXCompat layer: maps the legacy OciXCrom CRX Ranksystem API onto
// Rank System Ultimate (rsu_core.amxx) so sub-plugins written against
// <crxranks> (battlepass_core, freenova_hud, freenova_panel, freenova_vip,
// freenova_progression, freenova_season, freenova_teamxp, weapon_models,
// top15_styled) keep working unchanged after CRX is retired.
//
// Requires: rsu_core.amxx (loaded before this plugin).
// ============================================================================

#include <amxmodx>
#include <ranksultimate>
#include <rsu_const>
#include <crxranks_const>

#define PLUGIN_NAME     "RSU CRX Compatibility Layer"
#define PLUGIN_VERSION  "1.0.0"
#define PLUGIN_AUTHOR   "FREENova"

// ---- Natives from rsu.inc (declared locally; rsu.inc itself is not
// ---- included so it cannot collide with <ranksultimate>)
native bool:rsu_is_player_ready(id);
native bool:rsu_set_xp(id, amount, RsuXpSource:source = RSU_XP_CUSTOM);
native rsu_add_xp(id, amount, RsuXpSource:source = RSU_XP_CUSTOM);
native rsu_remove_xp(id, amount, RsuXpSource:source = RSU_XP_CUSTOM);

// ---- CRX forwards hooked from sub-plugins
new g_hFwdUserLoaded;
new g_hFwdUserLevelUpdated;
new g_hFwdUserXpUpdated;
new g_hFwdUserReceiveXp;

// Handlers shared between the CRX legacy API and the compatibility API below.
// Both public blocks call the same public so only one registration is needed.
public plugin_natives()
{
    register_library("crxranks");

    // -- Original OciXCrom CRX names (consumed by existing FreeNova plugins)
    register_native("crxranks_get_user_level",      "_crx_get_user_level");
    register_native("crxranks_get_user_xp",         "_crx_get_user_xp");
    register_native("crxranks_get_user_next_xp",    "_crx_get_user_next_xp");
    register_native("crxranks_get_max_levels",      "_crx_get_max_levels");
    register_native("crxranks_get_user_rank",       "_crx_get_user_rank");
    register_native("crxranks_get_user_next_rank",  "_crx_get_user_next_rank");
    register_native("crxranks_give_user_xp",        "_crx_give_user_xp");
    register_native("crxranks_set_user_xp",         "_crx_set_user_xp");
    register_native("crxranks_is_user_loaded",      "_crx_is_user_loaded");
    register_native("crxranks_is_user_on_final",    "_crx_is_user_on_final");

    // -- Tornado RSU alias names (future-facing; same handlers)
    register_native("ranksultimate_get_user_level", "_crx_get_user_level");
    register_native("ranksultimate_get_user_xp",    "_crx_get_user_xp");
    register_native("ranksultimate_get_user_next_xp", "_crx_get_user_next_xp");
    register_native("ranksultimate_get_max_levels", "_crx_get_max_levels");
    register_native("ranksultimate_get_user_rank",  "_crx_get_user_rank");
    register_native("ranksultimate_get_user_next_rank", "_crx_get_user_next_rank");
    register_native("ranksultimate_give_user_xp",   "_crx_give_user_xp");
    register_native("ranksultimate_set_user_xp",    "_crx_set_user_xp");
    register_native("ranksultimate_is_user_loaded", "_crx_is_user_loaded");
    register_native("ranksultimate_is_user_on_final", "_crx_is_user_on_final");
}

public plugin_init()
{
    register_plugin(PLUGIN_NAME, PLUGIN_VERSION, PLUGIN_AUTHOR);

    g_hFwdUserLoaded       = CreateMultiForward("crxranks_user_loaded", ET_IGNORE, FP_CELL);
    g_hFwdUserLevelUpdated = CreateMultiForward("crxranks_user_level_updated", ET_IGNORE, FP_CELL, FP_CELL, FP_CELL);
    g_hFwdUserXpUpdated    = CreateMultiForward("crxranks_user_xp_updated", ET_IGNORE, FP_CELL, FP_CELL, FP_CELL);
    // ET_STOP, matching original CRX: the return value carries the modified
    // XP amount (or CRXRANKS_HANDLED to block). ET_IGNORE would silently
    // discard every consumer's multiplier (VIP/happy-hour/double-XP no-op).
    g_hFwdUserReceiveXp    = CreateMultiForward("crxranks_user_receive_xp", ET_STOP, FP_CELL, FP_CELL, FP_CELL);
}

public plugin_end()
{
    if (g_hFwdUserLoaded) DestroyForward(g_hFwdUserLoaded);
    if (g_hFwdUserLevelUpdated) DestroyForward(g_hFwdUserLevelUpdated);
    if (g_hFwdUserXpUpdated) DestroyForward(g_hFwdUserXpUpdated);
    if (g_hFwdUserReceiveXp) DestroyForward(g_hFwdUserReceiveXp);
}

bool:CrxValidId(id)
{
    return (id >= 1 && id <= MaxClients);
}

// ============================================================================
// CRX natives -> RSU natives
// ============================================================================

// crxranks_get_user_level(id) : current level (rank tier index in RSU)
public _crx_get_user_level(iPlugin, iParams)
{
    new id = get_param(1);
    return CrxValidId(id) ? rsu_get_user_level(id) : 0;
}

// crxranks_get_user_xp(id) : current XP
public _crx_get_user_xp(iPlugin, iParams)
{
    new id = get_param(1);
    return CrxValidId(id) ? rsu_get_user_xp(id) : 0;
}

// crxranks_get_user_next_xp(id) : XP required for the next level
public _crx_get_user_next_xp(iPlugin, iParams)
{
    new id = get_param(1);
    return CrxValidId(id) ? rsu_get_user_next_xp(id) : 0;
}

// crxranks_get_max_levels() : number of levels (= number of RSU ranks)
public _crx_get_max_levels(iPlugin, iParams)
    return rsu_get_max_levels();

// crxranks_get_user_rank(id, buffer[], len) : current rank name
public _crx_get_user_rank(iPlugin, iParams)
{
    new id = get_param(1);
    if (!CrxValidId(id))
        return 0;
    new szRank[RSU_MAX_RANK_NAME + 1];
    rsu_get_user_rank(id, szRank, charsmax(szRank));
    set_string(2, szRank, get_param(3));
    return 1;
}

// crxranks_get_user_next_rank(id, buffer[], len) : next rank name
// On the final level the current rank name is returned.
public _crx_get_user_next_rank(iPlugin, iParams)
{
    new id = get_param(1);
    if (!CrxValidId(id))
        return 0;
    new iLevel = rsu_get_user_level(id);
    new iMax = rsu_get_max_levels();

    if (iLevel < iMax)
        iLevel++;

    new szRank[RSU_MAX_RANK_NAME + 1];
    if (!rsu_get_rank_by_level(iLevel, szRank, charsmax(szRank)))
        rsu_get_user_rank(id, szRank, charsmax(szRank));

    set_string(2, szRank, get_param(3));
    return 1;
}

// crxranks_give_user_xp(id, amount = 0, reward[] = "", source = PLUGIN)
// Returns the amount of XP actually given. Negative amounts remove XP.
public _crx_give_user_xp(iPlugin, iParams)
{
    new id = get_param(1);
    new iAmount = get_param(2);

    if (!CrxValidId(id) || iAmount == 0)
        return 0;

    new RsuXpSource:src = RSU_XP_CUSTOM;
    if (iParams >= 4)
        src = MapXpSource(CRXRanks_XPSources:get_param(4));

    if (iAmount > 0)
        return rsu_add_xp(id, iAmount, src);

    return rsu_remove_xp(id, -iAmount, src);
}

// crxranks_set_user_xp(id, amount, source = PLUGIN) : set exact XP
public _crx_set_user_xp(iPlugin, iParams)
{
    new id = get_param(1);
    if (!CrxValidId(id))
        return 0;
    new iAmount = get_param(2);
    new RsuXpSource:src = RSU_XP_CUSTOM;
    if (iParams >= 3)
        src = MapXpSource(CRXRanks_XPSources:get_param(3));
    if (!rsu_set_xp(id, iAmount, src))
        return 0;
    return iAmount;
}

// crxranks_is_user_loaded(id) : player stats finished loading (READY)
public _crx_is_user_loaded(iPlugin, iParams)
{
    new id = get_param(1);
    if (!CrxValidId(id))
        return 0;
    return rsu_is_player_ready(id) ? 1 : 0;
}

// crxranks_is_user_on_final(id) : player reached the last level
public _crx_is_user_on_final(iPlugin, iParams)
{
    new id = get_param(1);
    if (!CrxValidId(id))
        return 0;
    return (rsu_get_user_level(id) >= rsu_get_max_levels()) ? 1 : 0;
}

// ============================================================================
// RSU forwards -> CRX forwards
// ============================================================================

// rsu_player_xp_pre(id, &amount, source) is the RSU pre-XP hook; its return
// semantics translate to CRX ones:
//   CRXRANKS_CONTINUE            -> pass amount through
//   CRXRANKS_HANDLED / STOP      -> block the XP
//   any other value              -> replaces the XP amount
public rsu_player_xp_pre(id, &amount, RsuXpSource:source)
{
    // Removals (negative amount) still fire the pre-forward so CRX consumers
    // can block or rewrite admin/penalty XP. Documented, not skipped.
    new iRet;
    ExecuteForward(g_hFwdUserReceiveXp, iRet, id, amount, _:source);

    if (iRet == CRXRANKS_CONTINUE || iRet == 0)
        return PLUGIN_CONTINUE;

    if (iRet == CRXRANKS_HANDLED || iRet == CRXRANKS_STOP)
        return PLUGIN_HANDLED;

    amount = iRet;
    return PLUGIN_CONTINUE;
}

public rsu_user_level_updated(id, level, bool:levelup)
{
    ExecuteForward(g_hFwdUserLevelUpdated, _, id, level, _:levelup);
}

public rsu_user_xp_updated(id, xp, bool:teamxp)
{
    ExecuteForward(g_hFwdUserXpUpdated, _, id, xp, _:teamxp);
}

public rsu_user_stats_loaded(id, const saveinfo[], const name[])
{
    ExecuteForward(g_hFwdUserLoaded, _, id);
}

// ============================================================================
// Helpers
// ============================================================================

RsuXpSource:MapXpSource(CRXRanks_XPSources:src)
{
    switch (src)
    {
        case CRXRANKS_XPS_ADMIN:  return RSU_XP_ADMIN;
        case CRXRANKS_XPS_REWARD: return RSU_XP_CUSTOM;
        case CRXRANKS_XPS_PLUGIN: return RSU_XP_CUSTOM;
    }
    return RSU_XP_CUSTOM;
}
