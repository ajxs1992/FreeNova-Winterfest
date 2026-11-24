// Chat tags by SteamID / name / IP / admin flag. Optional CS models.

#include <amxmodx>
#include <amxmisc>
#include <reapi>
#include <fn_chat>

#define MAX_RULES 64
#define TYPE_STEAM 0
#define TYPE_NAME  1
#define TYPE_IP    2
#define TYPE_FLAG  3

native is_user_gagged(id)

new g_type[MAX_RULES]
new g_match[MAX_RULES][44]
new g_tag[MAX_RULES][24]
new g_color[MAX_RULES]
new g_model[MAX_RULES][32]
new g_rules
new bool:g_cstrike
new bool:g_hasModel[MAX_PLAYERS + 1]
new g_playerModel[MAX_PLAYERS + 1][32]

public plugin_natives()
{
	set_module_filter("module_filter")
	set_native_filter("native_filter")
}

public module_filter(const module[])
{
	if (equali(module, "cstrike"))
		return PLUGIN_HANDLED
	return PLUGIN_CONTINUE
}

public native_filter(const name[], index, trap)
{
	if (!trap && (equal(name, "is_user_gagged") || contain(name, "cs_") == 0))
		return PLUGIN_HANDLED
	return PLUGIN_CONTINUE
}

public plugin_precache()
{
	g_cstrike = LibraryExists("cstrike", LibType_Library) != 0
	loadRules(true)
}

public plugin_init()
{
	register_plugin("Chat Tags", AMXX_VERSION_STR, "AMXX Dev Team")
	register_clcmd("say", "cmdSay")
	register_clcmd("say_team", "cmdSayTeam")
	register_concmd("amx_reloadtags", "cmdReload", ADMIN_CFG, "- reload amx_chattags.ini")
	if (!g_rules)
		loadRules(false)
}

public client_disconnected(id)
{
	g_hasModel[id] = false
	g_playerModel[id][0] = 0
	rg_reset_user_model(id)
}

public client_putinserver(id)
{
	set_task(1.0, "applyModel", id)
}

public applyModel(id)
{
	if (!is_user_connected(id) || is_user_bot(id))
		return
	new rule = findRule(id)
	if (rule == -1 || !g_model[rule][0])
		return
	rg_set_user_model(id, g_model[rule])
	copy(g_playerModel[id], charsmax(g_playerModel[]), g_model[rule])
	g_hasModel[id] = true
}

public cmdReload(id, level, cid)
{
	if (!cmd_access(id, level, cid, 1))
		return PLUGIN_HANDLED
	loadRules(false)
	console_print(id, "[AMXX] Reloaded %d chat tag rules.", g_rules)
	for (new i = 1; i <= MaxClients; i++)
		if (is_user_connected(i))
			applyModel(i)
	return PLUGIN_HANDLED
}

loadRules(bool:precacheModels)
{
	g_rules = 0
	new path[96]
	get_configsdir(path, charsmax(path))
	format(path, charsmax(path), "%s/amx_chattags.ini", path)
	if (!file_exists(path))
		return

	new fp = fopen(path, "rt")
	if (!fp)
		return

	new line[256], t[12], m[44], tag[24], col[12], model[32]
	while (g_rules < MAX_RULES && fgets(fp, line, charsmax(line)))
	{
		trim(line)
		if (!line[0] || line[0] == ';' || line[0] == '/')
			continue
		if (parse(line, t, charsmax(t), m, charsmax(m), tag, charsmax(tag), col, charsmax(col), model, charsmax(model)) < 3)
			continue

		new type = -1
		if (equali(t, "steam")) type = TYPE_STEAM
		else if (equali(t, "name")) type = TYPE_NAME
		else if (equali(t, "ip")) type = TYPE_IP
		else if (equali(t, "flag")) type = TYPE_FLAG
		if (type == -1)
			continue

		g_type[g_rules] = type
		copy(g_match[g_rules], charsmax(g_match[]), m)
		copy(g_tag[g_rules], charsmax(g_tag[]), tag)
		g_color[g_rules] = colorId(col)
		copy(g_model[g_rules], charsmax(g_model[]), model)
		if (precacheModels && g_cstrike && model[0])
		{
			new mdl[64]
			formatex(mdl, charsmax(mdl), "models/player/%s/%s.mdl", model, model)
			if (file_exists(mdl))
				precache_model(mdl)
			else
				g_model[g_rules][0] = 0
		}
		g_rules++
	}
	fclose(fp)
}

colorId(const col[])
{
	if (equali(col, "red")) return print_team_red
	if (equali(col, "blue")) return print_team_blue
	if (equali(col, "grey") || equali(col, "gray")) return print_team_grey
	return print_team_default
}

findRule(id)
{
	new auth[44], name[MAX_NAME_LENGTH], ip[32]
	get_user_authid(id, auth, charsmax(auth))
	get_user_name(id, name, charsmax(name))
	get_user_ip(id, ip, charsmax(ip), 1)
	new flags = get_user_flags(id)

	new found = -1
	for (new i; i < g_rules; i++)
	{
		new ok
		switch (g_type[i])
		{
			case TYPE_STEAM: ok = equal(auth, g_match[i])
			case TYPE_NAME:  ok = equali(name, g_match[i])
			case TYPE_IP:    ok = equal(ip, g_match[i])
			case TYPE_FLAG:
			{
				new f = read_flags(g_match[i])
				ok = f && (flags & f)
			}
		}
		if (!ok)
			continue
		if (g_type[i] == TYPE_STEAM)
			return i
		if (found == -1 || g_type[i] < g_type[found])
			found = i
	}
	return found
}

public cmdSay(id)
{
	return handleChat(id, false)
}

public cmdSayTeam(id)
{
	return handleChat(id, true)
}

handleChat(id, bool:team)
{
	if (LibraryExists("fn_chat", LibType_Library))
	{
		if (!fn_chat_can_speak(id))
			return PLUGIN_HANDLED;
	}
	else if (is_user_gagged(id))
		return PLUGIN_HANDLED;

	new said[192]
	read_args(said, charsmax(said))
	remove_quotes(said)
	if (!said[0] || said[0] == '/' || said[0] == '@')
		return PLUGIN_CONTINUE

	new rule = findRule(id)
	if (rule == -1 || !g_tag[rule][0])
		return PLUGIN_CONTINUE

	new name[MAX_NAME_LENGTH], msg[192]
	get_user_name(id, name, charsmax(name))
	
	new deadPrefix[16] = ""
	new TeamName:myTeam = get_member(id, m_iTeam)
	if (!is_user_alive(id))
	{
		if (myTeam == TEAM_SPECTATOR || myTeam == TEAM_UNASSIGNED)
			copy(deadPrefix, charsmax(deadPrefix), "*SPEC* ")
		else
			copy(deadPrefix, charsmax(deadPrefix), "*DEAD* ")
	}

	if (team)
		formatex(msg, charsmax(msg), "^1%s^4%s ^3(TEAM) %s^1 :  %s", deadPrefix, g_tag[rule], name, said)
	else
		formatex(msg, charsmax(msg), "^1%s^4%s ^3%s^1 :  %s", deadPrefix, g_tag[rule], name, said)

	new sender = (g_color[rule] == print_team_default) ? id : g_color[rule]
	new alltalk = get_cvar_num("sv_alltalk")
	new isAlive = is_user_alive(id)

	if (team)
	{
		for (new i = 1; i <= MaxClients; i++)
		{
			if (!is_user_connected(i) || get_member(i, m_iTeam) != myTeam)
				continue
			if (!alltalk && !isAlive && is_user_alive(i))
				continue
			client_print_color(i, sender, "%s", msg)
		}
	}
	else
	{
		for (new i = 1; i <= MaxClients; i++)
		{
			if (!is_user_connected(i))
				continue
			if (!alltalk && !isAlive && is_user_alive(i))
				continue
			client_print_color(i, sender, "%s", msg)
		}
	}

	return PLUGIN_HANDLED
}
