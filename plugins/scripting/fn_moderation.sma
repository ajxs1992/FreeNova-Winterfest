/* fn_moderation: canonical moderation funnel (3.0 M2). All moderation entries
 * funnel here; backends stay executors. scope: 0 local (enforced now),
 * 1 group / 2 global (RECORDED in audit+journal, enforced as local until M10).
 * Warns: journaled + nvault counters (authid-keyed; bots share "BOT"). */
#include <amxmodx>
#include <amxmisc>
#include <nvault>
#include <fn_core>
#include <fn_audit>
#include <fn_bans>
#include <fn_link>
#include <fn_common>

new g_vaultWarns;

public plugin_natives()
{
	set_native_filter("native_filter");
	register_library("fn_moderation");
	register_native("fn_mod_ban", "_mod_ban");
	register_native("fn_mod_warn", "_mod_warn");
	register_native("fn_mod_warns", "_mod_warns");
	register_native("fn_mod_note", "_mod_note");
}

public native_filter(const name[], index, trap)
{
	if (!trap && contain(name, "fn_") == 0)
		return PLUGIN_HANDLED;
	return PLUGIN_CONTINUE;
}

public plugin_init()
{
	fn_boot_banner("moderation", 4);

	register_plugin("FreeNova Moderation", "3.0.0", "FreeNova");
	if (!LibraryExists("fn_core", LibType_Library))
	{
		log_amx("[FN-MOD] fn_core missing, pausing self");
		pause("d");
		return;
	}
	if (!LibraryExists("fn_audit", LibType_Library))
	{
		log_amx("[FN-MOD] fn_audit missing, pausing self");
		pause("d");
		return;
	}
	if (!LibraryExists("fn_bans", LibType_Library))
	{
		log_amx("[FN-MOD] fn_bans missing, pausing self (R1: authority needs the API)");
		pause("d");
		return;
	}
	g_vaultWarns = nvault_open("fn_warns");
	fn_health_set("moderation", "ok");
}

public plugin_end()
{
	if (g_vaultWarns != INVALID_HANDLE)
		nvault_close(g_vaultWarns);
}

public _mod_ban(plugin, params)
{
	new admin = get_param(1);
	new steam[40], ip[32], reason[128];
	get_string(2, steam, charsmax(steam));
	get_string(3, ip, charsmax(ip));
	new minutes = get_param(4);
	get_string(5, reason, charsmax(reason));
	new scope = get_param(6);
	if (scope < 0 || scope > 2) return 0;
	if (!LibraryExists("fn_bans", LibType_Library)) return 0;
	if (!LibraryExists("fn_audit", LibType_Library)) return 0;
	new r = fn_ban_add(admin, steam, ip, minutes, reason);
	if (LibraryExists("fn_link", LibType_Library))
	{
		new pay[192];
		formatex(pay, charsmax(pay), "%s;%s;%d;%s;%d", steam, ip, minutes, reason, scope);
		fn_link_push("ban.add", pay);
	}
	if (scope != 0 && r == 1)
	{
		new c[24];
		fn_ban_last_case(c, charsmax(c));
		fn_audit_append(c, admin, 0, "mod.scope", scope == 1 ? "group" : "global");
	}
	return r;
}

public _mod_warn(plugin, params)
{
	new admin = get_param(1);
	new target = get_param(2);
	new reason[128];
	get_string(3, reason, charsmax(reason));
	if (target < 1 || !is_user_connected(target) || !reason[0]) return 0;
	if (!LibraryExists("fn_audit", LibType_Library)) return 0;
	new auth[32];
	get_user_authid(target, auth, charsmax(auth));
	if (!auth[0]) return 0;
	new data[16], ts;
	new n = 0;
	if (g_vaultWarns != INVALID_HANDLE && nvault_lookup(g_vaultWarns, auth, data, charsmax(data), ts))
		n = str_to_num(data);
	n++;
	if (g_vaultWarns != INVALID_HANDLE)
	{
		num_to_str(n, data, charsmax(data));
		nvault_set(g_vaultWarns, auth, data);
	}
	new c[24];
	fn_case_new(admin, c, charsmax(c));
	fn_audit_append(c, admin, target, "mod.warn", reason);
	if (LibraryExists("fn_link", LibType_Library))
	{
		new pay[192];
		formatex(pay, charsmax(pay), "%s;%s", auth, reason);
		fn_link_push("warn.add", pay);
	}
	return n;
}

public _mod_warns(plugin, params)
{
	new target = get_param(1);
	if (target < 1 || !is_user_connected(target)) return 0;
	if (g_vaultWarns == INVALID_HANDLE) return 0;
	new auth[32];
	get_user_authid(target, auth, charsmax(auth));
	if (!auth[0]) return 0;
	new data[16], ts;
	if (!nvault_lookup(g_vaultWarns, auth, data, charsmax(data), ts)) return 0;
	return str_to_num(data);
}

public _mod_note(plugin, params)
{
	new admin = get_param(1);
	new c[24], note[128];
	get_string(2, c, charsmax(c));
	get_string(3, note, charsmax(note));
	if (!LibraryExists("fn_audit", LibType_Library)) return 0;
	return fn_case_note(admin, c, note);
}
