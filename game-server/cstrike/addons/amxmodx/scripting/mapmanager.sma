// Map manager: browse maps, nominate, change, extend, set nextmap.

#include <amxmodx>
#include <amxmisc>
#include <sorting>
#include <reapi>

#define MAX_NOMINATIONS 8
#define MAX_RECENT_MAPS 3

new Array:g_maps
new Array:g_noms
new g_nomCount
new g_extendMax
new g_extendStep
new g_playerNom[MAX_PLAYERS + 1][32]
new g_timelimit
new g_recentMaps[MAX_RECENT_MAPS][32]
new g_recentCount

public plugin_init()
{
	register_plugin("Map Manager", AMXX_VERSION_STR, "AMXX Dev Team")
	register_dictionary("mapsmenu.txt")
	register_dictionary("common.txt")
	register_dictionary("nextmap.txt")

	register_clcmd("amx_mapmanager", "cmdMenu", ADMIN_MAP, "- map manager")
	register_concmd("amx_setnextmap", "cmdSetNext", ADMIN_MAP, "<map> - set next map")
	register_clcmd("say /maps", "cmdBrowse")
	register_clcmd("say /map", "cmdMenuChat")
	register_clcmd("say /nominate", "cmdNomSay")
	register_clcmd("say nominate", "cmdNomSay")
	register_clcmd("say /nextmap", "cmdSayNext")
	register_clcmd("say maps", "cmdBrowse")

	g_extendMax = register_cvar("amx_mapmanager_extend_max", "90")
	g_extendStep = register_cvar("amx_mapmanager_extend_step", "15")
	g_timelimit = get_cvar_pointer("mp_timelimit")

	g_maps = ArrayCreate(32)
	g_noms = ArrayCreate(32)
	loadRecentMaps()
	loadMaps()
}

loadRecentMaps()
{
	new raw[128], pos, map[32]
	get_localinfo("amx_recent_maps", raw, charsmax(raw))
	g_recentCount = 0
	while (g_recentCount < MAX_RECENT_MAPS && (pos = argparse(raw, pos, map, charsmax(map))) != -1)
	{
		if (map[0])
			copy(g_recentMaps[g_recentCount++], charsmax(g_recentMaps[]), map)
	}
}

saveRecentMaps()
{
	new current[32], raw[128]
	get_mapname(current, charsmax(current))
	formatex(raw, charsmax(raw), "^"%s^"", current)
	for (new i = 0; i < g_recentCount && i < MAX_RECENT_MAPS - 1; i++)
	{
		if (!equali(g_recentMaps[i], current))
			format(raw, charsmax(raw), "%s ^"%s^"", raw, g_recentMaps[i])
	}
	set_localinfo("amx_recent_maps", raw)
}

bool:isRecentMap(const map[])
{
	for (new i = 0; i < g_recentCount; i++)
	{
		if (equali(g_recentMaps[i], map))
			return true
	}
	return false
}

public plugin_end()
{
	saveRecentMaps()
	ArrayDestroy(g_maps)
	ArrayDestroy(g_noms)
}

public client_disconnected(id)
{
	g_playerNom[id][0] = 0
}

loadMaps()
{
	ArrayClear(g_maps)
	new maps_ini[64]
	get_configsdir(maps_ini, charsmax(maps_ini))
	format(maps_ini, charsmax(maps_ini), "%s/maps.ini", maps_ini)

	if (file_exists(maps_ini))
		loadFromFile(maps_ini)
	else
	{
		get_cvar_string("mapcyclefile", maps_ini, charsmax(maps_ini))
		if (file_exists(maps_ini))
			loadFromFile(maps_ini)
	}

	if (ArraySize(g_maps) < 2)
		scanMapDir()

	if (ArraySize(g_maps) > 1)
		SortADTArray(g_maps, Sort_Ascending, Sort_String)
}

loadFromFile(const filename[])
{
	new fp = fopen(filename, "r")
	if (!fp)
		return
	new line[256], map[32]
	while (fgets(fp, line, charsmax(line)))
	{
		trim(line)
		if (!line[0] || line[0] == ';' || line[0] == '/')
			continue
		parse(line, map, charsmax(map))
		stripBsp(map)
		if (is_map_valid(map) && !alreadyListed(map))
			ArrayPushString(g_maps, map)
	}
	fclose(fp)
}

scanMapDir()
{
	new file[64], FileType:type
	new dir = open_dir("maps", file, charsmax(file), type, true, "GAME")
	if (!dir)
		return
	do
	{
		if (type != FileType_File)
			continue
		new len = strlen(file)
		if (len < 5 || !equali(file[len - 4], ".bsp"))
			continue
		file[len - 4] = 0
		if (is_map_valid(file) && !alreadyListed(file))
			ArrayPushString(g_maps, file)
	}
	while (next_file(dir, file, charsmax(file), type))
	close_dir(dir)
}

bool:alreadyListed(const map[])
{
	new stored[32]
	for (new i, n = ArraySize(g_maps); i < n; i++)
	{
		ArrayGetString(g_maps, i, stored, charsmax(stored))
		if (equali(stored, map))
			return true
	}
	return false
}

stripBsp(map[])
{
	new len = strlen(map) - 4
	if (len >= 0 && equali(map[len], ".bsp"))
		map[len] = 0
}

public cmdSayNext(id)
{
	new next[32]
	get_cvar_string("amx_nextmap", next, charsmax(next))
	if (!next[0])
		get_mapname(next, charsmax(next))
	client_print(0, print_chat, "[AMXX] Next map: %s", next)
	return PLUGIN_HANDLED
}

public cmdSetNext(id, level, cid)
{
	if (!cmd_access(id, level, cid, 2))
		return PLUGIN_HANDLED
	new map[32]
	read_argv(1, map, charsmax(map))
	stripBsp(map)
	if (contain(map, "..") != -1 || !is_map_valid(map))
	{
		console_print(id, "[AMXX] Invalid map.")
		return PLUGIN_HANDLED
	}
	set_cvar_string("amx_nextmap", map)
	new name[MAX_NAME_LENGTH]
	get_user_name(id, name, charsmax(name))
	client_print(0, print_chat, "[AMXX] %s set next map to %s", name, map)
	log_amx("MapManager: nextmap set to %s by %s", map, name)
	return PLUGIN_HANDLED
}

public cmdNomSay(id)
{
	new said[64]
	read_args(said, charsmax(said))
	remove_quotes(said)
	replace(said, charsmax(said), "/nominate", "")
	replace(said, charsmax(said), "nominate", "")
	trim(said)
	if (!said[0])
	{
		showBrowse(id, true)
		return PLUGIN_HANDLED
	}
	tryNominate(id, said)
	return PLUGIN_HANDLED
}

public cmdBrowse(id)
{
	if (get_user_flags(id) & ADMIN_MAP)
		showRoot(id)
	else
		showBrowse(id, true)
	return PLUGIN_HANDLED
}

public cmdMenuChat(id)
{
	return cmdBrowse(id)
}

public cmdMenu(id, level, cid)
{
	if (!cmd_access(id, level, cid, 1))
		return PLUGIN_HANDLED
	showRoot(id)
	return PLUGIN_HANDLED
}

showRoot(id)
{
	new menu = menu_create("\yMap Manager\w", "menuRoot")
	menu_additem(menu, "Browse / change map", "change")
	menu_additem(menu, "Nominations", "noms")
	menu_additem(menu, "Extend current map", "extend")
	new next[32]
	get_cvar_string("amx_nextmap", next, charsmax(next))
	if (next[0])
	{
		new item[64]
		formatex(item, charsmax(item), "Next map: \y%s\w", next)
		menu_additem(menu, item, "next")
	}
	menu_display(id, menu)
}

public menuRoot(id, menu, item)
{
	if (item < 0)
	{
		menu_destroy(menu)
		return PLUGIN_HANDLED
	}
	new info[16], dummy[1]
	menu_item_getinfo(menu, item, dummy[0], info, charsmax(info), dummy, 0, dummy[0])
	menu_destroy(menu)
	if (equal(info, "change"))
		showBrowse(id, false)
	else if (equal(info, "noms"))
		showNoms(id)
	else if (equal(info, "extend"))
		extendMap(id)
	else
		showBrowse(id, false)
	return PLUGIN_HANDLED
}

showBrowse(id, bool:nominateOnly)
{
	new title[64]
	formatex(title, charsmax(title), nominateOnly ? "\yNominate a map\w" : "\yMaps (%d)\w", ArraySize(g_maps))
	new menu = menu_create(title, "menuMap")
	new map[32], info[40]
	new current[32]
	get_mapname(current, charsmax(current))
	for (new i, n = ArraySize(g_maps); i < n; i++)
	{
		ArrayGetString(g_maps, i, map, charsmax(map))
		formatex(info, charsmax(info), "%s %d", map, nominateOnly ? 1 : 0)
		if (equali(map, current))
			format(map, charsmax(map), "%s \y(current)\w", map)
		menu_additem(menu, map, info)
	}
	menu_display(id, menu)
}

public menuMap(id, menu, item)
{
	if (item < 0)
	{
		menu_destroy(menu)
		return PLUGIN_HANDLED
	}
	new info[40], dummy[1], map[32], modeStr[4]
	menu_item_getinfo(menu, item, dummy[0], info, charsmax(info), dummy, 0, dummy[0])
	menu_destroy(menu)
	parse(info, map, charsmax(map), modeStr, charsmax(modeStr))
	if (str_to_num(modeStr) || ~get_user_flags(id) & ADMIN_MAP)
		tryNominate(id, map)
	else
		confirmChange(id, map)
	return PLUGIN_HANDLED
}

confirmChange(id, const map[])
{
	new title[64]
	formatex(title, charsmax(title), "\yChange to %s?\w", map)
	new menu = menu_create(title, "menuChange")
	menu_additem(menu, "Change now", map)
	menu_additem(menu, "Set as next map", map)
	menu_additem(menu, "Nominate instead", map)
	menu_display(id, menu)
}

public menuChange(id, menu, item)
{
	new map[32], dummy[1]
	menu_item_getinfo(menu, item, dummy[0], map, charsmax(map), dummy, 0, dummy[0])
	menu_destroy(menu)
	if (item < 0)
		return PLUGIN_HANDLED
	if (item == 0)
	{
		if (!(get_user_flags(id) & ADMIN_MAP) || contain(map, "..") != -1 || !is_map_valid(map))
			return PLUGIN_HANDLED
		new name[MAX_NAME_LENGTH]
		get_user_name(id, name, charsmax(name))
		client_print(0, print_chat, "[AMXX] Changing map to %s...", map)
		log_amx("MapManager: changelevel %s by %s", map, name)
		message_begin(MSG_ALL, SVC_INTERMISSION)
		message_end()
		rg_send_audio(0, "%!MRAD_ROUNDDRAW")
		set_task(2.0, "doChange", 0, map, strlen(map) + 1)
	}
	else if (item == 1)
		client_cmd(id, "amx_setnextmap %s", map)
	else
		tryNominate(id, map)
	return PLUGIN_HANDLED
}

public doChange(map[])
{
	engine_changelevel(map)
}

tryNominate(id, const map[])
{
	new check[32]
	copy(check, charsmax(check), map)
	stripBsp(check)
	if (!is_map_valid(check))
	{
		client_print(id, print_chat, "[AMXX] Invalid map: %s", check)
		return
	}
	new current[32]
	get_mapname(current, charsmax(current))
	if (equali(check, current))
	{
		client_print(id, print_chat, "[AMXX] Already playing %s.", check)
		return
	}
	if (isRecentMap(check))
	{
		client_print(id, print_chat, "[AMXX] %s was played recently and cannot be nominated.", check)
		return
	}
	new stored[32]
	for (new i; i < g_nomCount; i++)
	{
		ArrayGetString(g_noms, i, stored, charsmax(stored))
		if (equali(stored, check))
		{
			client_print(id, print_chat, "[AMXX] %s is already nominated.", check)
			return
		}
	}
	if (g_playerNom[id][0])
	{
		client_print(id, print_chat, "[AMXX] You already nominated %s.", g_playerNom[id])
		return
	}
	if (g_nomCount >= MAX_NOMINATIONS)
	{
		client_print(id, print_chat, "[AMXX] Nomination list is full.")
		return
	}
	ArrayPushString(g_noms, check)
	g_nomCount++
	copy(g_playerNom[id], charsmax(g_playerNom[]), check)
	new name[MAX_NAME_LENGTH]
	get_user_name(id, name, charsmax(name))
	rg_send_audio(id, "%!MRAD_GO")
	client_print(0, print_chat, "[AMXX] %s nominated %s", name, check)
}

showNoms(id)
{
	new menu = menu_create("\yNominations\w", "menuNoms")
	if (!g_nomCount)
		menu_additem(menu, "(none)", "none")
	else
	{
		new map[32]
		for (new i; i < g_nomCount; i++)
		{
			ArrayGetString(g_noms, i, map, charsmax(map))
			menu_additem(menu, map, map)
		}
	}
	menu_display(id, menu)
}

public menuNoms(id, menu, item)
{
	new map[32], dummy[1]
	menu_item_getinfo(menu, item, dummy[0], map, charsmax(map), dummy, 0, dummy[0])
	menu_destroy(menu)
	if (item < 0 || equal(map, "none"))
		return PLUGIN_HANDLED
	if (get_user_flags(id) & ADMIN_MAP)
		confirmChange(id, map)
	return PLUGIN_HANDLED
}

extendMap(id)
{
	if (!(get_user_flags(id) & ADMIN_MAP))
		return
	if (!g_timelimit)
	{
		client_print(id, print_chat, "[AMXX] mp_timelimit is not available.")
		return
	}
	new step = get_pcvar_num(g_extendStep)
	if (step < 1)
		step = 15
	new current = get_pcvar_num(g_timelimit)
	new maxTime = get_pcvar_num(g_extendMax)
	if (maxTime > 0 && current + step > maxTime)
	{
		client_print(id, print_chat, "[AMXX] Extend cap reached (%d min).", maxTime)
		return
	}
	set_pcvar_num(g_timelimit, current + step)
	new name[MAX_NAME_LENGTH], map[32]
	get_user_name(id, name, charsmax(name))
	get_mapname(map, charsmax(map))
	client_print(0, print_chat, "[AMXX] %s extended %s by %d minutes.", name, map, step)
	log_amx("MapManager: extend %s +%d by %s", map, step, name)
}
