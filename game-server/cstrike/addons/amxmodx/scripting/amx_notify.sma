// Server notifications. Does not remove scrollmsg/imessage.

#include <amxmodx>
#include <amxmisc>

new Array:g_msg
new g_index
new g_hudChan

public plugin_init()
{
	register_plugin("Notify", AMXX_VERSION_STR, "AMXX Dev Team")
	register_concmd("amx_announce", "cmdAnnounce", ADMIN_CHAT, "<message> - HUD + chat announcement")
	register_concmd("amx_reloadnotify", "cmdReload", ADMIN_CFG, "- reload amx_notify.ini")
	register_srvcmd("amx_addnotify", "cmdAdd")
	register_cvar("amx_notify_freq", "60")
	g_msg = ArrayCreate(192)
	loadConfig()
	set_task(60.0, "rotate", _, _, _, "b")
}

public cmdReload(id, level, cid)
{
	if (!cmd_access(id, level, cid, 1))
		return PLUGIN_HANDLED
	ArrayClear(g_msg)
	loadConfig()
	client_print(id, print_chat, "[AMXX] Reloaded %d announcements from amx_notify.ini.", ArraySize(g_msg))
	return PLUGIN_HANDLED
}

loadConfig()
{
	new path[128]
	get_configsdir(path, charsmax(path))
	format(path, charsmax(path), "%s/amx_notify.ini", path)
	if (!file_exists(path))
		return
	new fp = fopen(path, "rt")
	if (!fp)
		return
	new line[192]
	while (fgets(fp, line, charsmax(line)))
	{
		trim(line)
		if (!line[0] || line[0] == ';' || line[0] == '/')
			continue
		ArrayPushString(g_msg, line)
	}
	fclose(fp)
}

public plugin_end()
{
	ArrayDestroy(g_msg)
}

public cmdAdd()
{
	new text[192]
	read_args(text, charsmax(text))
	remove_quotes(text)
	trim(text)
	if (text[0])
		ArrayPushString(g_msg, text)
	return PLUGIN_HANDLED
}

public cmdAnnounce(id, level, cid)
{
	if (!cmd_access(id, level, cid, 2))
		return PLUGIN_HANDLED
	new text[192]
	read_args(text, charsmax(text))
	remove_quotes(text)
	showNote(text)
	return PLUGIN_HANDLED
}

public rotate()
{
	new n = ArraySize(g_msg)
	if (!n)
		return
	if (g_index >= n)
		g_index = 0
	new text[192]
	ArrayGetString(g_msg, g_index++, text, charsmax(text))
	showNote(text)
}

showNote(const text[])
{
	if (!text[0])
		return
	g_hudChan++
	if (g_hudChan > 4)
		g_hudChan = 1
	set_hudmessage(0, 200, 255, -1.0, 0.20, 0, 0.5, 8.0, 0.1, 0.2, g_hudChan)
	show_hudmessage(0, "%s", text)
	client_print(0, print_chat, "[AMXX] %s", text)
}