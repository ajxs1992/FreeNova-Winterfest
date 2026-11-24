// FreeNova unified admin policy helpers (M13).
//
// Single source for hierarchy, target validation and expiry text. Replaces
// the divergent semantics of gag PassHierarchy and panel CanModerate with
// one documented policy. See SELF_TARGET_MATRIX.md for the per-action table.
//
// Hierarchy (unchanged legacy meaning):
//   FLAG_MANAGER  (a) : manager, top of the chain
//   FLAG_MOD      (e) : moderator, subset of FLAG_ADMIN
//   FLAG_ADMIN    (cdeijuv) : full admin flag set
//   0 = permanent wherever an expiry is specified.
//
// This file is policy + helpers only. The persistent grant STORE
// (vault/SQL schema) is owned by the admin system plugin (Wave C).

#if defined _freenova_admin_included
    #endinput
#endif
#define _freenova_admin_included

#include <amxmodx>

#if !defined FLAG_ADMIN
#define FN_FLAG_ADMIN  read_flags("cdeijuv")
#else
#define FN_FLAG_ADMIN  FLAG_ADMIN
#endif
#if !defined FLAG_MANAGER
#define FN_FLAG_MANAGER  read_flags("a")
#else
#define FN_FLAG_MANAGER  FLAG_MANAGER
#endif
#define FN_FLAG_MOD  read_flags("e")

// Self-target policy per action family.
enum _:FN_SelfAction
{
    FN_SELF_GAG = 0,
    FN_SELF_UNGAG,
    FN_SELF_SLAP,
    FN_SELF_SLAY,
    FN_SELF_INFO,
    FN_SELF_SPECTATE,
    FN_SELF_BAN,
    FN_SELF_KICK,
    FN_SELF_GRANT
}

// True when an authorized admin may target themselves with this action.
// Destructive/privilege actions are never self-applied without an explicit
// confirmation flow owned by the calling plugin (not provided here).
stock bool:FN_SelfAllowed(iAction)
{
    switch (iAction)
    {
        case FN_SELF_GAG, FN_SELF_UNGAG, FN_SELF_SLAP,
             FN_SELF_SLAY, FN_SELF_INFO, FN_SELF_SPECTATE:
            return true
    }
    return false
}

// Name-based twin for menu dispatchers, which route on action strings
// ("gag","ungag","slap","slay") rather than enum values. Same policy.
stock bool:FN_SelfAllowedName(const szAction[])
{
    return equal(szAction, "gag") || equal(szAction, "ungag")
        || equal(szAction, "slap") || equal(szAction, "slay")
        || equal(szAction, "info") || equal(szAction, "spectate");
}

// Unified hierarchy: manager touches all but managers; e-moderator touches
// regulars only; everyone else touches nothing. Self is NOT decided here;
// callers combine this with FN_SelfAllowed().
stock bool:FN_CanModerate(iAdmin, iTarget)
{
    if (!is_user_connected(iAdmin) || !is_user_connected(iTarget))
        return false

    new iAdminFlags = get_user_flags(iAdmin)
    new iTargetFlags = get_user_flags(iTarget)

    if (iAdminFlags & FN_FLAG_MANAGER)
    {
        if (iTargetFlags & FN_FLAG_MANAGER)
            return false
        return true
    }
    if (iAdminFlags & FN_FLAG_MOD)
    {
        if (iTargetFlags & FN_FLAG_ADMIN)
            return false
        return true
    }
    return false
}

// Target check codes for menu/command validation at EXECUTION time.
enum _:FN_TargetCode
{
    FN_TARGET_OK = 0,
    FN_TARGET_DISCONNECTED,
    FN_TARGET_SELF_DENIED,
    FN_TARGET_IMMUNE
}

// Validate invoker -> target for an action family right before acting.
// Never trust the slot index chosen when the menu was drawn.
stock FN_CheckTarget(iInvoker, iTarget, iAction)
{
    if (iInvoker != 0 && !is_user_connected(iInvoker))
        return FN_TARGET_DISCONNECTED
    if (!is_user_connected(iTarget))
        return FN_TARGET_DISCONNECTED
    if (iInvoker != 0 && iInvoker == iTarget && !FN_SelfAllowed(iAction))
        return FN_TARGET_SELF_DENIED
    if (iInvoker != 0 && !FN_CanModerate(iInvoker, iTarget)
        && !(iInvoker == iTarget && FN_SelfAllowed(iAction)))
        return FN_TARGET_IMMUNE
    return FN_TARGET_OK
}

// Slot-reuse guard: snapshot userid+authid at menu draw, re-check at fire.
// Copy the VIP-menu snapshot pattern; fixes wrong-occupant actions when a
// target leaves and the slot is reused mid-menu.
stock FN_SnapTarget(iTarget, szAuth[], iAuthLen, &iUserid)
{
    iUserid = get_user_userid(iTarget)
    get_user_authid(iTarget, szAuth, iAuthLen)
    return 1
}

stock bool:FN_StillSame(iTarget, const szAuth[], iUserid)
{
    if (!is_user_connected(iTarget))
        return false
    if (get_user_userid(iTarget) != iUserid)
        return false
    new szNow[32]
    get_user_authid(iTarget, szNow, charsmax(szNow))
    return bool:equal(szNow, szAuth)
}

// Expiry text. 0 = permanent, always. Absolute timestamps render via
// format_time; callers pass get_systime()-based values, never raw input.
stock FN_ExpiryText(iExpire, szOut[], iLen)
{
    if (iExpire <= 0)
        return copy(szOut, iLen, "permanent")
    return format_time(szOut, iLen, "%d %B %Y at %H:%M", iExpire)
}
