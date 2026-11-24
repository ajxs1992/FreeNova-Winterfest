#if defined _fn_settings_included
	#endinput
#endif
#define _fn_settings_included

/* fn_settings prefs (library fn_settings, 3.0 M7). v1 keys: "welcome"
 * ("0" disables join welcomes for that player). Language lives in the
 * multilingual menu (linked, never duplicated). Pending/LAN/bot IDs are
 * session-only and never stored. Guard calls with
 * LibraryExists("fn_settings", LibType_Library). */
native fn_pref_get(id, const key[], out[], len);
native fn_pref_set(id, const key[], const val[]);
