#if defined _fn_perms_included
	#endinput
#endif
#define _fn_perms_included

/* fn_perms authority (library fn_perms, 3.0 M4, approved N3 unify).
 * Profiles own granular NODES; a flag bridge confers engine AMXX flags so
 * legacy flag checks pass for grantees. Deliberately NOT auto-conferred
 * (M7 rewires those commands): STAFF, SERVER_EXEC, DIAG, REPORTS, WARN.
 * BAN_TEMP/UNBAN/SCAN share ADMIN_BAN (permaban still needs its confirm).
 * VIP (1) carries zero nodes: entitlement by profile id, never staff power.
 * scope: 0 local, 1 group (recorded, enforced M10), 2 global (enforced).
 * minutes: 0 permanent, >0 temp, <0 rejected. Console (id<1) passes checks.
 * Guard calls with LibraryExists("fn_perms", LibType_Library). */

/* nodes */
#define FN_PERM_KICK 0
#define FN_PERM_SLAY 1
#define FN_PERM_TEAM 2
#define FN_PERM_WARN 3
#define FN_PERM_GAG 4
#define FN_PERM_BAN_TEMP 5
#define FN_PERM_BAN_PERM 6
#define FN_PERM_UNBAN 7
#define FN_PERM_SCAN 8
#define FN_PERM_REPORTS 9
#define FN_PERM_MAPS_CHANGE 10
#define FN_PERM_MAPS_VOTE 11
#define FN_PERM_CONFIG 12
#define FN_PERM_SERVER_EXEC 13
#define FN_PERM_STAFF 14
#define FN_PERM_DIAG 15
#define FN_PERM_CHAT 16
#define FN_PERM_MENU 17
/* profiles */
#define FN_PROFILE_PLAYER 0
#define FN_PROFILE_VIP 1
#define FN_PROFILE_HELPER 2
#define FN_PROFILE_MOD 3
#define FN_PROFILE_ADMIN 4
#define FN_PROFILE_SUPERADMIN 5
#define FN_PROFILE_OWNER 6
#define FN_PROFILE_CUSTOM 7
/* scopes */
#define FN_SCOPE_LOCAL 0
#define FN_SCOPE_GROUP 1
#define FN_SCOPE_GLOBAL 2

native fn_perm_check(id, node);
native fn_perm_grant(admin, target, profile, minutes, scope);
native fn_perm_revoke(admin, target);
native fn_perm_profile(id);
native fn_perm_grant_mask(admin, target, mask, minutes, scope);
native fn_perm_nodes(id);
