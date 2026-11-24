// Pause profiles: public / event / maintenance.

#include <amxmodx>
#include <amxmisc>

public plugin_init()
{
	register_plugin("Plugin Profiles", AMXX_VERSION_STR, "AMXX Dev Team")
	register_concmd("amx_profile", "cmdProfile", ADMIN_CFG, "<public|event|maintenance> - pause plugin groups")
	register_clcmd("amx_profilemenu", "cmdMenu", ADMIN_CFG, "- plugin profiles")
}

public plugin_cfg()
{
	set_task(0.3, "addFront")
}

public addFront()
{
	AddMenuItem("Plugin Profiles", "amx_profilemenu", ADMIN_CFG, "Plugin Profiles")
}

public cmdMenu(id, level, cid)
{
	if (!cmd_access(id, level, cid, 1))
		return PLUGIN_HANDLED
	new menu = menu_create("\yPlugin profiles\w", "menuProf")
	menu_additem(menu, "Public (unpause extras)", "public")
	menu_additem(menu, "Event (pause fun extras)", "event")
	menu_additem(menu, "Maintenance (amx_off)", "maintenance")
	menu_display(id, menu)
	return PLUGIN_HANDLED
}

public menuProf(id, menu, item)
{
	if (item < 0)
	{
		menu_destroy(menu)
		return PLUGIN_HANDLED
	}
	new info[16], access, callback, dummy[1]
	menu_item_getinfo(menu, item, access, info, charsmax(info), dummy, 0, callback)
	menu_destroy(menu)
	applyProfile(id, info)
	return PLUGIN_HANDLED
}

public cmdProfile(id, level, cid)
{
	if (!cmd_access(id, level, cid, 2))
		return PLUGIN_HANDLED
	new arg[16]
	read_argv(1, arg, charsmax(arg))
	applyProfile(id, arg)
	return PLUGIN_HANDLED
}

applyProfile(id, const name[])
{
	if (equali(name, "maintenance"))
	{
		server_cmd("amx_off")
		client_print(id, print_chat, "[AMXX] Profile: maintenance (amx_off).")
	}
	else if (equali(name, "event"))
	{
		server_cmd("amx_on")
		pauseSafe("statscfg.amxx")
		pauseSafe("scrollmsg.amxx")
		pauseSafe("imessage.amxx")
		client_print(id, print_chat, "[AMXX] Profile: event.")
	}
	else
	{
		server_cmd("amx_on")
		client_print(id, print_chat, "[AMXX] Profile: public (amx_on).")
	}
	log_amx("Profile %s by #%d", name, id)
}

pauseSafe(const title[])
{
	pause("ac", title)
}