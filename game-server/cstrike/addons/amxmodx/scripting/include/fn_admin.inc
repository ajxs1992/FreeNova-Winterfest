#if defined _fn_admin_included
	#endinput
#endif
#define _fn_admin_included

/* fn_admin hub (library fn_admin, 3.0 M7). Hub menu only - player actions
 * live in fn_menus (opened via fn_menu_open), server/maps/config sections
 * open existing menus by command. fn_hub_pick records hub-initiated picks
 * for the recent-target entry. Guard calls with
 * LibraryExists("fn_admin", LibType_Library). */
native fn_hub_pick(id, target, const action[]);
