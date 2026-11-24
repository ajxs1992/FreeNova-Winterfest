#if defined _fn_hud_included
	#endinput
#endif
#define _fn_hud_included

/* fn_hud coordination (library fn_hud, 3.0 M8). Priorities 0-9 (5+
 * critical band channels 1-2, else 3-4); busy channels yield only to
 * strictly higher priority; identical text within 5s is dropped and
 * counted. Returns 1 shown, 0 dropped. Callers keep direct-HUD fallback.
 * Guard calls with LibraryExists("fn_hud", LibType_Library). */
native fn_hud_show(priority, Float:holdtime, r, g, b, Float:x, Float:y, const text[]);
native fn_hud_drops();
