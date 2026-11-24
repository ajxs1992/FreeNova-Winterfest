/* fn_guard: thin query glue over BypassGuard. Never rewrites guard logic.
 * Verdict "checked/pending/unknown" only; enforcement stays in guard core. */
#include <amxmodx>
#include <amxmisc>
#include <fn_core>
#include <fn_common>
/* NOTE (M1): vendor bypass_guard.inc carries `#pragma reqlib
 * bypass_guard_core`, which fails plugin LOAD without the guard core
 * (before any LibraryExists gate can run) and poisons hasLib-style
 * guards (library registers, then pauses -> dynanative error 10).
 * Hand-declared single native instead (antiflood precedent); the
 * LibraryExists("bypass_guard_core") verdict gate below now works. */
native bool:BypassGuard_IsPlayerChecked(pPlayer);

public plugin_natives()
{
	register_library("fn_guard");
	set_native_filter("native_filter");
	register_native("fn_guard_verdict", "_guard_verdict");
}

public native_filter(const name[], index, trap)
{
	if (!trap && (contain(name, "fn_") == 0 || contain(name, "BypassGuard_") == 0))
		return PLUGIN_HANDLED;
	return PLUGIN_CONTINUE;
}

public plugin_init()
{
	fn_boot_banner("guard", 2);

	register_plugin("FreeNova Guard Glue", "2.0.0", "FreeNova");
	register_concmd("fn_guard", "cmdStatus", ADMIN_BAN, "- guard presence + checked state");
	if (!LibraryExists("fn_core", LibType_Library))
	{
		log_amx("[FN-GUARD] fn_core missing, pausing self");
		pause("d");
		return;
	}
	fn_health_set("guard", "ok");
}

guardPresent() { return LibraryExists("bypass_guard_core", LibType_Library); }

public _guard_verdict(plugin, params)
{
	new id = get_param(1);
	new outlen = get_param(3);
	if (!guardPresent()) { set_string(2, "unknown", outlen); return 0; }
	if (id < 1 || !is_user_connected(id)) { set_string(2, "unknown", outlen); return 0; }
	if (BypassGuard_IsPlayerChecked(id)) { set_string(2, "checked", outlen); return 1; }
	set_string(2, "pending", outlen);
	return 1;
}

public cmdStatus(id, level, cid)
{
	if (!cmd_access(id, level, cid, 1)) return PLUGIN_HANDLED;
	console_print(id, "[FN] guard=%d therules: one provider only", guardPresent());
	return PLUGIN_HANDLED;
}