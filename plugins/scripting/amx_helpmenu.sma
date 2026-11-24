// Categorized admin help menu. Keeps amx_help console dump.

#include <amxmodx>
#include <amxmisc>

public plugin_init()
{
	register_plugin("Admin Help Menu", AMXX_VERSION_STR, "AMXX Dev Team")
	register_clcmd("amx_helpmenu", "cmdMenu", ADMIN_ALL, "- categorized command help")
	register_clcmd("say /help", "cmdMenu")
	register_clcmd("say_team /help", "cmdMenu")
}

public plugin_cfg()
{
	set_task(0.3, "addFront")
}

public addFront()
{
	AddMenuItem("Command Help", "amx_helpmenu", ADMIN_ALL, "Admin Help Menu")
}

public cmdMenu(id, level, cid)
{
	showCats(id)
	return PLUGIN_HANDLED
}

showCats(id)
{
	new menu = menu_create("\yCommand Help\w", "menuCat")
	menu_additem(menu, "Player management", "kick slay slap ban unban banlist gag tempadmin nick scan unscan")
	menu_additem(menu, "Server", "cvar cfg pause rcon who plugins modules pingkicker maxping")
	menu_additem(menu, "Maps", "map nextmap votemap extend mapmanager")
	menu_additem(menu, "Communication", "chat say tsay csay psay vote ghostchat gag")
	menu_additem(menu, "Fun / extra", "teleport speech slap")
	menu_additem(menu, "Search all...", "SEARCH")
	menu_display(id, menu)
}

public menuCat(id, menu, item)
{
	if (item < 0)
	{
		menu_destroy(menu)
		return PLUGIN_HANDLED
	}
	new info[64], access, callback, dummy[1]
	menu_item_getinfo(menu, item, access, info, charsmax(info), dummy, 0, callback)
	menu_destroy(menu)
	if (equal(info, "SEARCH"))
	{
		client_print(id, print_chat, "[AMXX] Type in console: amx_searchcmd <text>")
		client_cmd(id, "amx_help")
		return PLUGIN_HANDLED
	}
	showCmds(id, info)
	return PLUGIN_HANDLED
}

showCmds(id, const needles[])
{
	new menu = menu_create("\yCommands you can use\w", "menuCmd")
	new flags = get_user_flags(id)
	if (flags > 0 && !(flags & ADMIN_USER))
		flags |= ADMIN_ADMIN
	new count = get_concmdsnum(flags, id)
	new cmd[32], info[128], cmdflags, bool:ml, added
	for (new i; i < count; i++)
	{
		get_concmd(i, cmd, charsmax(cmd), cmdflags, info, charsmax(info), flags, id, ml)
		new token[32], pos, found
		while ((pos = argparse(needles, pos, token, charsmax(token))) != -1)
		{
			if (token[0] && containi(cmd, token) != -1)
			{
				found = 1
				break
			}
		}
		if (!found)
			continue
		if (ml)
			LookupLangKey(info, charsmax(info), info, id)
		new line[160]
		formatex(line, charsmax(line), "%s \d%s\w", cmd, info)
		menu_additem(menu, line, cmd)
		if (++added >= 40)
			break
	}
	if (!added)
		menu_additem(menu, "(none)", "")
	menu_display(id, menu)
}

public menuCmd(id, menu, item)
{
	if (item < 0)
	{
		menu_destroy(menu)
		showCats(id)
		return PLUGIN_HANDLED
	}
	new cmd[32], access, callback, dummy[1]
	menu_item_getinfo(menu, item, access, cmd, charsmax(cmd), dummy, 0, callback)
	menu_destroy(menu)
	if (cmd[0])
		client_print(id, print_chat, "[AMXX] %s  — type it in console.", cmd)
	return PLUGIN_HANDLED
}