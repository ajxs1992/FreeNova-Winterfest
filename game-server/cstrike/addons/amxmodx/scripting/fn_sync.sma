/* fn_sync: exactly-one-writer router. Delegates to the present PG backend
 * console commands; refuses dual-writer states. File backend = no sync. */
#include <amxmodx>
#include <amxmisc>
#include <fn_core>
#include <fn_common>

public plugin_natives()
{
	register_library("fn_sync");
	set_native_filter("native_filter");
	register_native("fn_sync_now", "_sync_now");
	register_native("fn_sync_status", "_sync_status");
}

public native_filter(const name[], index, trap)
{
	if (!trap && contain(name, "fn_") == 0)
		return PLUGIN_HANDLED;
	return PLUGIN_CONTINUE;
}

public plugin_init()
{
	fn_boot_banner("sync", 3);

	register_plugin("FreeNova Sync", "2.0.0", "FreeNova");
	register_concmd("fn_sync", "cmdSync", ADMIN_BAN, "- delegate reconcile to active writer");
	if (!LibraryExists("fn_core", LibType_Library))
	{
		log_amx("[FN-SYNC] fn_core missing, pausing self");
		pause("d");
		return;
	}
	fn_health_set("sync", "ok");
}

pgPresent() { return get_cvar_pointer("pg_interval") != 0; }

public _sync_now(plugin, params)
{
	if (!pgPresent()) return 0;
	server_cmd("pg_sync_now");
	return 1;
}

public _sync_status(plugin, params)
{
	new outlen = get_param(2);
	if (pgPresent()) { set_string(1, "pg", outlen); return 1; }
	set_string(1, "file", outlen);
	return 1;
}

public cmdSync(id, level, cid)
{
	if (!cmd_access(id, level, cid, 1)) return PLUGIN_HANDLED;
	if (pgPresent())
	{
		server_cmd("pg_sync_now");
		console_print(id, "[FN] delegated to pg_sync (dryrun first)");
	}
	else console_print(id, "[FN] file backend: nothing to sync");
	return PLUGIN_HANDLED;
}