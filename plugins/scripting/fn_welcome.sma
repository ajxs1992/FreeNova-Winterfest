/* fn_welcome: join welcome experience (3.0 M7). New vs returning comes from
 * history only (nvault fn_seen): never seen = new, seen = returning with
 * day count. Rules/hints/community lines come from the fn_welcome.txt
 * dictionary (translatable, toggleable). Honors the fn_settings "welcome"
 * toggle (guarded; default ON). One delayed task per join (no timers,
 * no spam); staff are not announced (noise). */
#include <amxmodx>
#include <amxmisc>
#include <nvault>
#include <fn_core>
#include <fn_settings>
#include <fn_common>

new g_vaultSeen;
new g_cvarOn, g_cvarRules, g_cvarDelay;

#define TASK_WELCOME 90410

public plugin_natives()
{
	set_native_filter("native_filter");
}

public native_filter(const name[], index, trap)
{
	if (!trap && contain(name, "fn_") == 0)
		return PLUGIN_HANDLED;
	return PLUGIN_CONTINUE;
}

public plugin_init()
{
	fn_boot_banner("welcome", 3);

	register_plugin("FreeNova Welcome", "3.0.0", "FreeNova");
	register_dictionary("fn_welcome.txt");
	register_dictionary("common.txt");
	g_cvarOn = register_cvar("fn_welcome_on", "1");
	g_cvarRules = register_cvar("fn_welcome_rules", "1");
	g_cvarDelay = register_cvar("fn_welcome_delay", "10.0");
	if (!LibraryExists("fn_core", LibType_Library))
	{
		log_amx("[FN-WELCOME] fn_core missing, pausing self");
		pause("d");
		return;
	}
	g_vaultSeen = nvault_open("fn_seen");
	fn_health_set("welcome", "ok");
}

public plugin_end()
{
	if (g_vaultSeen != INVALID_HANDLE)
		nvault_close(g_vaultSeen);
}

public client_putinserver(id)
{
	if (is_user_bot(id) || is_user_hltv(id))
		return;
	remove_task(TASK_WELCOME + id);
	new Float:d = get_pcvar_float(g_cvarDelay);
	if (d < 3.0)
		d = 3.0;
	if (d > 60.0)
		d = 60.0;
	set_task(d, "doWelcome", TASK_WELCOME + id);
}

public client_disconnected(id)
{
	remove_task(TASK_WELCOME + id);
}

public doWelcome(taskid)
{
	new id = taskid - TASK_WELCOME;
	if (id < 1 || id > MaxClients || !is_user_connected(id))
		return;
	if (!get_pcvar_num(g_cvarOn))
		return;
	if (LibraryExists("fn_settings", LibType_Library))
	{
		new pref[8];
		if (fn_pref_get(id, "welcome", pref, charsmax(pref)) && equal(pref, "0"))
			return;
	}
	new auth[32], name[MAX_NAME_LENGTH];
	get_user_authid(id, auth, charsmax(auth));
	get_user_name(id, name, charsmax(name));
	if (!auth[0])
		return;
	new known = 0, days = 0;
	if (g_vaultSeen != INVALID_HANDLE && !is_user_bot(id) && contain(auth, "LAN") == -1 && !equal(auth, "STEAM_ID_PENDING"))
	{
		new data[16], ts;
		if (nvault_lookup(g_vaultSeen, auth, data, charsmax(data), ts))
		{
			known = 1;
			days = (get_systime() - str_to_num(data)) / 86400;
			if (days < 0)
				days = 0;
		}
		num_to_str(get_systime(), data, charsmax(data));
		nvault_set(g_vaultSeen, auth, data);
	}
	new host[64];
	get_cvar_string("hostname", host, charsmax(host));
	if (!known)
		client_print(id, print_chat, "%L", id, "WELCOME_NEW", host);
	else if (days > 0)
		client_print(id, print_chat, "%L", id, "WELCOME_BACK_DAYS", host, days);
	else
		client_print(id, print_chat, "%L", id, "WELCOME_BACK", host);
	if (get_pcvar_num(g_cvarRules))
	{
		client_print(id, print_chat, "%L", id, "WELCOME_RULES");
		client_print(id, print_chat, "%L", id, "WELCOME_HINTS");
	}
}
