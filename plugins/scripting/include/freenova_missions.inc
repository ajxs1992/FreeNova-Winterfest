#if defined _freenova_missions_included
	#endinput
#endif
#define _freenova_missions_included

native fnmsn_is_complete(id);
native fnmsn_get_daily_progress(id, mission);
native fnmsn_get_daily2_progress(id, mission);
native fnmsn_get_weekly_progress(id, mission);
native fnmsn_get_daily_done(id);
native fnmsn_get_bonus_done(id);
native fnmsn_get_weekly_done(id);
native fnmsn_show(id);
native fnmsn_claim(id, group, slot);
native fnmsn_reroll(id, slot);
native fnmsn_get_rerolls_left(id);
native fnmsn_get_status(id, group, slot);
native fnmsn_get_target(id, group, slot);
native fnmsn_set_track(id, group, slot);
native fnmsn_get_track(id, output[], len);
native fnmsn_get_vip_progress(id);
native fnmsn_claim_all(id);
