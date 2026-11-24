#if defined _fn_maps_included
#endinput
#endif
#define _fn_maps_included

/* fn_maps natives (library fn_maps). */
native fn_map_extend(minutes, admin);
native fn_vote_active();
native fn_vote_begin(const origin[]);
native fn_vote_end();
native fn_vote_extend_ok();
native fn_vote_extended();
native fn_nextmap_get(output[], len);
