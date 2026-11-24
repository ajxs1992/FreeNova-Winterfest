// freenova_admin_api.inc — native declarations for the FreeNova Admin
// Grants v3 library ("freenova_admin").
//
// Declarations ONLY; no logic lives here. The owning plugin
// (freenova_admin.sma) registers these six natives in plugin_natives()
// with exactly these parameter counts:
//   grant(4) / revoke(2) / extend(3) / remaining(1) / has(1) / get_expire(1).
//
// Gate every call with LibraryExists("freenova_admin", LibType_Library)
// (or the FN_AdminAvailable() stock below) so your plugin loads cleanly
// when the admin plugin is absent.

#if defined _freenova_admin_api_included
    #endinput
#endif
#define _freenova_admin_api_included

#include <amxmodx>

// Mutating: return 1 ok, 0 invalid/target-unusable, -1 gate denied
// (caller not manager, or self-target which is always denied).
// minutes: 0 = permanent.
native fn_admin_grant(invoker, target, const role[], minutes);
native fn_admin_revoke(invoker, target);
native fn_admin_extend(invoker, target, minutes);
// Read-only.
// fn_admin_remaining: seconds left; 0 none/expired; -1 permanent.
// fn_admin_get_expire: absolute systime; 0 = none/permanent.
native fn_admin_remaining(target);
native fn_admin_has(target);
native fn_admin_get_expire(target);

// Availability gate: call before any native above.
stock bool:FN_AdminAvailable()
{
    return bool:LibraryExists("freenova_admin", LibType_Library);
}
