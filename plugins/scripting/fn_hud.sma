/* fn_hud: centralized HUD coordination (3.0 M8). Explicit channels 1-4
 * with priority bands (1-2 critical, 3-4 info), busy-channel overwrite
 * only by strictly higher priority, 5s same-text dedup, drop counting.
 * Synchronous reservation only (no queue, no timers). Callers keep a
 * direct-HUD fallback when this library is absent. */
#include <amxmodx>
#include <fn_core>
#include <fn_common>

new g_chanPri[5];
new g_chanUntil[5];
new g_drops;
new g_lastText[192];
new g_lastTextAt;

public plugin_natives()
{
	set_native_filter("native_filter");
	register_library("fn_hud");
	register_native("fn_hud_show", "_show");
	register_native("fn_hud_drops", "_drops");
}

public native_filter(const name[], index, trap)
{
	if (!trap && contain(name, "fn_") == 0)
		return PLUGIN_HANDLED;
	return PLUGIN_CONTINUE;
}

public plugin_init()
{
	fn_boot_banner("hud", 2);

	register_plugin("FreeNova HUD", "3.0.0", "FreeNova");
	if (!LibraryExists("fn_core", LibType_Library))
	{
		log_amx("[FN-HUD] fn_core missing, pausing self");
		pause("d");
		return;
	}
	fn_health_set("hud", "ok");
}

pickChannel(priority)
{
	new now = get_systime();
	new bandLo = (priority >= 5) ? 1 : 3;
	new bandHi = (priority >= 5) ? 2 : 4;
	for (new c = bandLo; c <= bandHi; c++)
	{
		if (now >= g_chanUntil[c])
			return c;
	}
	new worst = bandLo;
	for (new d = bandLo + 1; d <= bandHi; d++)
	{
		if (g_chanPri[d] < g_chanPri[worst])
			worst = d;
	}
	if (priority > g_chanPri[worst])
		return worst;
	return 0;
}

public _show(plugin, params)
{
	new priority = get_param(1);
	new Float:hold = get_param_f(2);
	new r = get_param(3);
	new gg = get_param(4);
	new b = get_param(5);
	new Float:x = get_param_f(6);
	new Float:y = get_param_f(7);
	new text[192];
	get_string(8, text, charsmax(text));
	if (!text[0])
		return 0;
	if (priority < 0)
		priority = 0;
	if (priority > 9)
		priority = 9;
	if (hold < 1.0)
		hold = 1.0;
	if (hold > 30.0)
		hold = 30.0;
	new now = get_systime();
	if (equal(text, g_lastText) && now - g_lastTextAt < 5)
	{
		g_drops++;
		return 0;
	}
	new ch = pickChannel(priority);
	if (ch <= 0)
	{
		g_drops++;
		return 0;
	}
	set_hudmessage(r, gg, b, x, y, 0, 0.5, hold, 0.1, 0.2, ch);
	show_hudmessage(0, "%s", text);
	g_chanPri[ch] = priority;
	g_chanUntil[ch] = now + floatround(hold) + 1;
	copy(g_lastText, charsmax(g_lastText), text);
	g_lastTextAt = now;
	return 1;
}

public _drops(plugin, params)
{
	return g_drops;
}
