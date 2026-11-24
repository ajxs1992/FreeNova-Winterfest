/*
 * ============================================================================
 * FreeNova Flash Control  (freenova_flash)
 * ============================================================================
 * SINGLE ScreenFade hook owner for gameplay flash tweaks. No other plugin may
 * register_message("ScreenFade") for gameplay changes (rsu_core only READS it
 * to timestamp blindness; battlepass only SENDS fades via Util_ScreenFade).
 *
 * (a) TEAM-FLASH BLOCK (cvar fn_flash_block_team, default 1):
 *     When the blinding grenade was thrown by a connected teammate
 *     (same playable team via cs_get_user_team, thrower != victim), the
 *     ScreenFade message is blocked fully (PLUGIN_HANDLED): no flash at all.
 *     Self flashes (thrower == victim), enemy flashes and FFA-style flashes
 *     with no attributable thrower are untouched.
 *     Thrower attribution: FM_SetModel forward catches the flashbang entity
 *     ("models/w_flashbang.mdl") while pev_owner still names the thrower; the
 *     last 8 throwers with timestamps form a ring. A victim's fade is
 *     attributed to the most recent throw within 5.0 seconds. This is a
 *     timing approximation (the engine fade carries no inflictor), documented
 *     here on purpose; simultaneous cross-team flashes resolve to the latest
 *     throw, which errs toward NOT blocking (enemy attribution) only when the
 *     latest thrower is not a teammate.
 *
 * (b) VIP FLASH REDUCTION (cvar fn_flash_vip_reduce, default 1):
 *     Non-team flashes on VIPs are shortened, not removed. Exact tiers:
 *       VIP (1)   -> 25% reduction (keeps 75% of duration/holdtime/alpha)
 *       VIP+ (2)  -> 50% reduction (keeps 50%)
 *       ELITE (3) -> 75% reduction (keeps 25%)
 *     Formula (integer math, per field):  new = (old * keep_pct) / 100
 *       keep_pct = 75 / 50 / 25 for tiers 1 / 2 / 3.
 *     Scaled fields: arg1 duration, arg2 holdtime, arg7 alpha ("holdalpha").
 *     Non-VIPs are untouched (no scaling call at all).
 *
 * FLASH DISCRIMINATION: only near-white fades are treated as flashbangs
 * (R/G/B >= 200 and alpha >= 200, same gate rsu_core MsgScreenFade uses), so
 * level-up heals, damage fades and other Util_ScreenFade effects pass through
 * unmodified on every path. Timebase is the engine fixed-point /4096 unit for
 * reads; scaling is unit-agnostic (pure ratio), so no conversion is needed.
 *
 * VIP LOOKUP: fnvip_get_tier() via LibraryExists("freenova_vip") gate. The
 * VIP plugin is optional: set_native_filter() stubs fnvip_get_tier so this
 * plugin loads and runs (as non-VIP behavior) when freenova_vip is absent
 * (same pattern as freenova_hud HudNativeFilter).
 *
 * Cvars (fn_flash_*):
 *   fn_flash_block_team   1 - block teammate flashbang blindness fully
 *   fn_flash_vip_reduce   1 - shorten flashes for VIP tiers 25/50/75%
 * ============================================================================
 */

#include <amxmodx>
#include <amxmisc>
#include <cstrike>
#include <fakemeta>
#include <message_const>
#include <freenova_vip>
#include <fn_common>

#define PLUGIN  "FreeNova Flash Control"
#define VERSION "1.0.0"
#define AUTHOR  "FreeNova"

// Flashbang entity model (w_ model assigned at throw time)
new const FLASH_MODEL[] = "models/w_flashbang.mdl"

// Attribution ring + window
#define THROW_RING 8
#define THROW_WINDOW 5.0

// Near-white flash gate (mirrors rsu_core MsgScreenFade)
#define FLASH_MIN_RGB 200
#define FLASH_MIN_ALPHA 200

new g_iThrower[THROW_RING]
new Float:g_fThrowAt[THROW_RING]
new g_iThrowPos

new g_pCvarBlockTeam
new g_pCvarVipReduce

public plugin_natives()
{
    set_native_filter("FlashNativeFilter")
}

public FlashNativeFilter(const name[], index, trap)
{
    // VIP plugin may be absent; gated calls degrade to tier 0 (non-VIP).
    if (equal(name, "fnvip_get_tier"))
        return PLUGIN_HANDLED
    return PLUGIN_CONTINUE
}

public plugin_init()
{
    fn_boot_banner("flash", 5)

    register_plugin(PLUGIN, VERSION, AUTHOR)

    register_forward(FM_SetModel, "Fwd_SetModel")
    register_message(get_user_msgid("ScreenFade"), "Msg_ScreenFade")

    g_pCvarBlockTeam = register_cvar("fn_flash_block_team", "1")
    g_pCvarVipReduce = register_cvar("fn_flash_vip_reduce", "1")
}

// --- thrower tracking -------------------------------------------------------

public Fwd_SetModel(ent, const szModel[])
{
    if (!equal(szModel, FLASH_MODEL))
        return FMRES_IGNORED

    new owner = pev(ent, pev_owner)
    if (owner < 1 || owner > MaxClients || !is_user_connected(owner))
        return FMRES_IGNORED

    g_iThrower[g_iThrowPos] = owner
    g_fThrowAt[g_iThrowPos] = get_gametime()
    g_iThrowPos = (g_iThrowPos + 1) % THROW_RING

    return FMRES_IGNORED
}

// Most recent thrower within the attribution window, or 0.
RecentThrower()
{
    new Float:fNow = get_gametime()
    new Float:fBest = -1.0
    new iBest = 0

    for (new i = 0; i < THROW_RING; i++)
    {
        new id = g_iThrower[i]
        if (id < 1 || id > MaxClients || !is_user_connected(id))
            continue
        if (fNow - g_fThrowAt[i] > THROW_WINDOW)
            continue
        if (g_fThrowAt[i] > fBest)
        {
            fBest = g_fThrowAt[i]
            iBest = id
        }
    }
    return iBest
}

// --- ScreenFade hook (single gameplay owner) --------------------------------

public Msg_ScreenFade(msg_id, msg_dest, msg_entity)
{
    new victim = msg_entity
    if (victim < 1 || victim > MaxClients || !is_user_connected(victim))
        return PLUGIN_CONTINUE

    // arg layout (rsu_core pattern): 1 duration, 2 holdtime, 3 flags,
    // 4/5/6 RGB, 7 alpha.
    new iDur   = get_msg_arg_int(1)
    new iHold  = get_msg_arg_int(2)
    new iR     = get_msg_arg_int(4)
    new iG     = get_msg_arg_int(5)
    new iB     = get_msg_arg_int(6)
    new iAlpha = get_msg_arg_int(7)

    // Not a flashbang fade -> never touch (heals, damage, cosmetics).
    if (iAlpha < FLASH_MIN_ALPHA || iR < FLASH_MIN_RGB
        || iG < FLASH_MIN_RGB || iB < FLASH_MIN_RGB)
        return PLUGIN_CONTINUE
    if (iDur <= 0 && iHold <= 0)
        return PLUGIN_CONTINUE

    // (a) teammate block: fully suppress, no scaling afterwards.
    if (get_pcvar_num(g_pCvarBlockTeam))
    {
        new atk = RecentThrower()
        if (atk && atk != victim && is_user_connected(atk))
        {
            new CsTeams:tAtk = cs_get_user_team(atk)
            new CsTeams:tVic = cs_get_user_team(victim)
            if ((tAtk == CS_TEAM_T || tAtk == CS_TEAM_CT) && tAtk == tVic)
                return PLUGIN_HANDLED   // no flash from teammates
        }
    }

    // (b) VIP reduction: exact 25/50/75% off duration+holdtime+alpha.
    if (get_pcvar_num(g_pCvarVipReduce)
        && LibraryExists("freenova_vip", LibType_Library))
    {
        new tier = fnvip_get_tier(victim)
        new keep = 100
        if (tier == FNVIP_VIP)
            keep = 75
        else if (tier == FNVIP_VIPPLUS)
            keep = 50
        else if (tier >= FNVIP_ELITE)
            keep = 25

        // Non-VIPs (tier 0 / unknown) are untouched: no set_msg_arg call.
        if (keep < 100)
        {
            // kept = value * (100 - reduction) / 100, reduction 25/50/75.
            // Duration/holdtime are shorts, alpha is a byte (engine msg layout).
            set_msg_arg_int(1, ARG_SHORT, (iDur * keep) / 100)
            set_msg_arg_int(2, ARG_SHORT, (iHold * keep) / 100)
            set_msg_arg_int(7, ARG_BYTE, (iAlpha * keep) / 100)
        }
    }

    return PLUGIN_CONTINUE
}
