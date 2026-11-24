/* fn_chat: central chat policy + audit (3.0 M3 foundation). The five say-hook
 * owners keep their emitters in M3a; they consult fn_chat_can_speak() first
 * (guarded: direct gag check when this library is absent). Hook ORDER is the
 * second half of the contract: gag -> flood -> emitters, enforced by preset
 * order + validate.ps1 (see docs/CHAT_ROUTER.md). M3b (single output path)
 * waits for runtime testing. */
#include <amxmodx>
#include <amxmisc>
#include <fn_core>
#include <fn_common>

native is_user_gagged(id);

new g_denied;

public plugin_natives()
{
	set_native_filter("native_filter");
	register_library("fn_chat");
	register_native("fn_chat_can_speak", "_can_speak");
	register_native("fn_chat_denied", "_denied");
}

public native_filter(const name[], index, trap)
{
	if (!trap && (contain(name, "fn_") == 0 || equal(name, "is_user_gagged")))
		return PLUGIN_HANDLED;
	return PLUGIN_CONTINUE;
}

public plugin_init()
{
	fn_boot_banner("chat", 2);

	register_plugin("FreeNova Chat", "3.0.0", "FreeNova");
	if (!LibraryExists("fn_core", LibType_Library))
	{
		log_amx("[FN-CHAT] fn_core missing, pausing self");
		pause("d");
		return;
	}
	fn_health_set("chat", "ok");
}

/* Authoritative gag verdict. 0 = gagged (drop + count), 1 = may speak.
 * Gag state itself stays owned by freenova_gag, which registers the library
 * name below (freenova_gag.sma:182); this is the single consult point so
 * emitters never disagree about it. */
public _can_speak(plugin, params)
{
	new id = get_param(1);
	if (id < 1 || id > MaxClients)
		return 0;
	if (!is_user_connected(id))
		return 0;
	new bool:gagged = false;
	if (LibraryExists("freenova_gag", LibType_Library))
		gagged = is_user_gagged(id) ? true : false;
	if (gagged)
	{
		g_denied++;
		return 0;
	}
	return 1;
}

public _denied(plugin, params)
{
	return g_denied;
}
