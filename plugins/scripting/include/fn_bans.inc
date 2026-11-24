#if defined _fn_bans_included
	#endinput
#endif
#define _fn_bans_included

/* fn_bans natives (library fn_bans). fn_ban_count is session-scoped. */
native fn_ban_add(admin, const steam[], const ip[], minutes, const reason[]);
native fn_ban_add_confirmed(admin, const case_id[]); /* tuple comes from the server-side confirm store */
native fn_ban_remove(admin, const target[], const reason[]);
native fn_ban_count();
native fn_ban_last_case(out[], len);

/* ban lifecycle forwards, created+executed by fn_bans.sma (moved from fn_core.inc in M1). */
forward fn_ban_added(const case_id[], admin, const target_steam[], const target_ip[], minutes, const reason[]);
forward fn_ban_removed(const case_id[], admin, const target_steam[], const reason[]);