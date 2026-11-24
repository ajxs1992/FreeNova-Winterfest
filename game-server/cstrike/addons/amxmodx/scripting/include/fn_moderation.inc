#if defined _fn_moderation_included
	#endinput
#endif
#define _fn_moderation_included

/* fn_moderation funnel (library fn_moderation, 3.0 M2).
 * scope: 0 local (enforced now), 1 group / 2 global (recorded in audit +
 * case journal; enforced as local until the M10 sync service). Guard calls
 * with LibraryExists("fn_moderation", LibType_Library). */
native fn_mod_ban(admin, const steam[], const ip[], minutes, const reason[], scope);
native fn_mod_warn(admin, target, const reason[]);
native fn_mod_warns(target);
native fn_mod_note(admin, const case_id[], const note[]);
