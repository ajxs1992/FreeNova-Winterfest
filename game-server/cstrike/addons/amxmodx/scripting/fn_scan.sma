// Scan lock: spectator hold until admin clear. Leave = permanent Steam/IP/name ban.

#include <amxmodx>
#include <amxmisc>
#include <nvault>
#include <reapi>
#include <fn_core>
#include <fn_bans>
#include <fn_audit>
#include <fn_common>

#define TASK_REMIND  76001
#define TASK_SPEC    76101

new g_vaultActive
new g_vaultNameBan
new g_nameBanCount
new g_nameBanList[128][MAX_NAME_LENGTH]
new bool:g_scanning[MAX_PLAYERS + 1]
new bool:g_mapEnding
new g_scanAuth[MAX_PLAYERS + 1][32]
new g_scanIp[MAX_PLAYERS + 1][32]
new g_scanName[MAX_PLAYERS + 1][MAX_NAME_LENGTH]
new g_scanBy[MAX_PLAYERS + 1][MAX_NAME_LENGTH]
new g_scanStart[MAX_PLAYERS + 1]
new g_cvarContact, g_cvarLeaveMode, g_cvarLeaveMinutes

public plugin_natives()
{
	set_native_filter("native_filter")
	register_library("fn_scan");
	register_native("fn_scan_state", "_scan_state");
}

public native_filter(const name[], index, trap)
{
	if (!trap && contain(name, "fn_") == 0)
		return PLUGIN_HANDLED
	return PLUGIN_CONTINUE
}

public plugin_init()
{
	fn_boot_banner("scan", 16)

	register_plugin("Scan System", AMXX_VERSION_STR, "AMXX Dev Team")

	register_concmd("amx_scan", "cmdScan", ADMIN_BAN, "<name|#userid> [reason] - lock player in spectator")
	register_concmd("amx_unscan", "cmdClear", ADMIN_BAN, "<name|#userid> - clear scan lock")
	register_concmd("amx_scanclear", "cmdClear", ADMIN_BAN, "<name|#userid> - clear scan lock")
	register_concmd("amx_scanlist", "cmdList", ADMIN_BAN, "- list players on scan")
	register_concmd("amx_unscanname", "cmdUnbanName", ADMIN_BAN, "<name> - remove a scan name-ban")
	register_concmd("amx_scanbans", "cmdNameBans", ADMIN_BAN, "- list scan name-bans")
	register_clcmd("amx_scanmenu", "cmdMenu", ADMIN_BAN, "- scan menu")
	register_clcmd("say /scan", "cmdMenu", ADMIN_BAN)
	register_clcmd("say_team /scan", "cmdMenu", ADMIN_BAN)

	register_clcmd("jointeam", "blockJoin")
	register_clcmd("chooseteam", "blockJoin")
	register_clcmd("joinclass", "blockJoin")

	RegisterHookChain(RG_HandleMenu_ChooseTeam, "OnChooseTeam", false)
	RegisterHookChain(RG_HandleMenu_ChooseAppearance, "OnChooseAppearance", false)
	RegisterHookChain(RG_CBasePlayer_Spawn, "OnSpawn", false)
	RegisterHookChain(RG_ShowVGUIMenu, "OnVGUIMenu", false)
	RegisterHookChain(RG_CSGameRules_ClientUserInfoChanged, "OnUserInfoChanged", false)

	g_cvarContact = register_cvar("amx_scan_contact", "Discord / Admin")
	g_cvarLeaveMode = register_cvar("fn_scan_leave_mode", "0")
	g_cvarLeaveMinutes = register_cvar("fn_scan_leave_minutes", "1440")
	if (LibraryExists("fn_core", LibType_Library))
		fn_health_set("discipline.scan", "ok")
	g_vaultActive = nvault_open("scan_active")
	g_vaultNameBan = nvault_open("scan_nameban")
	loadNameBans()
}

public plugin_cfg()
{
	set_task(0.4, "addFront")
}

public addFront()
{
	AddMenuItem("Scan System", "amx_scanmenu", ADMIN_BAN, "Scan System")
}

public plugin_end()
{
	g_mapEnding = true
	if (g_vaultActive != INVALID_HANDLE)
		nvault_close(g_vaultActive)
	if (g_vaultNameBan != INVALID_HANDLE)
		nvault_close(g_vaultNameBan)
}

public client_authorized(id)
{
	if (is_user_bot(id) || is_user_hltv(id))
		return

	new name[MAX_NAME_LENGTH]
	get_user_name(id, name, charsmax(name))
	if (isNameBanned(name))
	{
		rh_drop_client(id, "Banned: scan evasion (name)")
		return
	}

	if (wasLeftOnScan(id))
		return
}

public client_putinserver(id)
{
	if (!is_user_connected(id) || is_user_bot(id) || is_user_hltv(id))
		return

	if (restoreScan(id))
		set_task(0.4, "forceSpec", TASK_SPEC + id)
}

public client_disconnected(id)
{
	remove_task(TASK_SPEC + id)
	remove_task(TASK_REMIND + id)

	if (g_mapEnding || !g_scanning[id])
	{
		g_scanning[id] = false
		return
	}

	new data[96]
	formatex(data, charsmax(data), "^"%s^" ^"%s^" ^"%s^"", g_scanAuth[id], g_scanIp[id], g_scanName[id])
	set_task(0.6, "executeLeaveBan", 0, data, strlen(data) + 1)
	g_scanning[id] = false
}

public OnChooseTeam(const id, const slot)
{
	if (!g_scanning[id])
		return HC_CONTINUE

	client_print(id, print_chat, "[AMXX] You are on scan. Wait for an admin to clear you.")
	SetHookChainReturn(ATYPE_INTEGER, 0)
	return HC_SUPERCEDE
}

public OnChooseAppearance(const id, const slot)
{
	if (!g_scanning[id])
		return HC_CONTINUE
	client_print(id, print_chat, "[AMXX] You are on scan. Wait for an admin to clear you.")
	SetHookChainReturn(ATYPE_INTEGER, 0)
	return HC_SUPERCEDE
}

public OnSpawn(const id)
{
	if (!g_scanning[id])
		return HC_CONTINUE
	set_task(0.1, "forceSpec", TASK_SPEC + id)
	return HC_CONTINUE
}

public OnVGUIMenu(const id, VGUIMenu:menuType, const bits, const oldMenu[])
{
	if (!g_scanning[id])
		return HC_CONTINUE
	if (menuType != VGUI_Menu_Team && menuType != VGUI_Menu_Class_T && menuType != VGUI_Menu_Class_CT)
		return HC_CONTINUE
	SetHookChainReturn(ATYPE_INTEGER, false)
	return HC_SUPERCEDE
}

public blockJoin(id)
{
	if (!g_scanning[id])
		return PLUGIN_CONTINUE
	client_print(id, print_chat, "[AMXX] You are on scan. You cannot join a team.")
	set_task(0.1, "forceSpec", TASK_SPEC + id)
	return PLUGIN_HANDLED
}

public forceSpec(taskid)
{
	new id = taskid - TASK_SPEC
	if (id < 1 || id > MaxClients)
		return
	if (!is_user_connected(id) || !g_scanning[id])
		return
	if (is_user_alive(id))
		user_kill(id, 1)
	if (get_member(id, m_iTeam) != TEAM_SPECTATOR)
		rg_set_user_team(id, TEAM_SPECTATOR)
}

public OnUserInfoChanged(const id)
{
	if (!is_user_connected(id) || !g_scanning[id])
		return HC_CONTINUE

	new currentName[MAX_NAME_LENGTH]
	get_user_name(id, currentName, charsmax(currentName))
	if (!equal(currentName, g_scanName[id]))
	{
		set_user_info(id, "name", g_scanName[id])
		client_print(id, print_chat, "[AMXX] You cannot change your name while on scan.")
	}
	return HC_CONTINUE
}

public remindScan(taskid)
{
	new id = taskid - TASK_REMIND
	if (!is_user_connected(id) || !g_scanning[id])
		return

	new elapsed = get_systime() - g_scanStart[id]
	if (elapsed < 0)
		elapsed = 0

	new contact[64]
	get_pcvar_string(g_cvarContact, contact, charsmax(contact))

	client_print(id, print_chat, "[AMXX] SCAN LOCK [%02d:%02d]: Stay in spectator. Leaving = permanent Steam/IP/name ban.", elapsed / 60, elapsed % 60)
	set_hudmessage(255, 40, 40, -1.0, 0.22, 0, 0.0, 8.0, 0.1, 0.4, -1)
	show_hudmessage(id, "YOU ARE ON SCAN [%02d:%02d]^nContact: %s^nDo NOT leave the server!", elapsed / 60, elapsed % 60, contact)
}

public cmdScan(id, level, cid)
{
	if (!cmd_access(id, level, cid, 2))
		return PLUGIN_HANDLED

	new arg[32], reason[64]
	read_argv(1, arg, charsmax(arg))
	read_args(reason, charsmax(reason))
	remove_quotes(reason)
	new space = contain(reason, " ")
	if (space != -1)
		copy(reason, charsmax(reason), reason[space + 1])
	else
		reason[0] = 0
	if (!reason[0])
		copy(reason, charsmax(reason), "Admin scan")

	new player;
	if (id == 0)
	{
		player = fn_resolve_target(arg, id);
		if (!player)
		{
			new hits[8], nm2[MAX_NAME_LENGTH];
			new nh = fn_resolve_list(arg, hits, 8, id);
			if (nh > 1)
			{
				console_print(id, "[AMXX] %d players match, be more specific:", nh);
				for (new si = 0; si < nh && si < 8; si++)
				{
					get_user_name(hits[si], nm2, charsmax(nm2));
					console_print(id, "  %s", nm2);
				}
			}
			else console_print(id, "[AMXX] No such player: %s", arg);
			return PLUGIN_HANDLED;
		}
	}
	else
	{
		player = cmd_target(id, arg, CMDTARGET_OBEY_IMMUNITY | CMDTARGET_NO_BOTS | CMDTARGET_ALLOW_SELF);
		if (!player)
			return PLUGIN_HANDLED;
	}

	putOnScan(id, player, reason)
	return PLUGIN_HANDLED
}

public cmdClear(id, level, cid)
{
	if (!cmd_access(id, level, cid, 2))
		return PLUGIN_HANDLED

	new arg[32]
	read_argv(1, arg, charsmax(arg))
	new player;
	if (id == 0)
	{
		player = fn_resolve_target(arg, id);
		if (!player)
		{
			new hits[8], nm2[MAX_NAME_LENGTH];
			new nh = fn_resolve_list(arg, hits, 8, id);
			if (nh > 1)
			{
				console_print(id, "[AMXX] %d players match, be more specific:", nh);
				for (new si = 0; si < nh && si < 8; si++)
				{
					get_user_name(hits[si], nm2, charsmax(nm2));
					console_print(id, "  %s", nm2);
				}
			}
			else console_print(id, "[AMXX] No such player: %s", arg);
			return PLUGIN_HANDLED;
		}
	}
	else
	{
		player = cmd_target(id, arg, CMDTARGET_OBEY_IMMUNITY | CMDTARGET_NO_BOTS | CMDTARGET_ALLOW_SELF);
		if (!player)
			return PLUGIN_HANDLED;
	}

	clearScan(id, player)
	return PLUGIN_HANDLED
}

public cmdList(id, level, cid)
{
	if (!cmd_access(id, level, cid, 1))
		return PLUGIN_HANDLED

	new found
	console_print(id, "[AMXX] Players on scan:")
	for (new i = 1; i <= MaxClients; i++)
	{
		if (!g_scanning[i] || !is_user_connected(i))
			continue
		console_print(id, "  #%d %s <%s> %s", get_user_userid(i), g_scanName[i], g_scanAuth[i], g_scanIp[i])
		found++
	}
	if (!found)
		console_print(id, "  (none)")
	return PLUGIN_HANDLED
}

public cmdMenu(id, level, cid)
{
	if (!cmd_access(id, level, cid, 1))
		return PLUGIN_HANDLED
	showScanMenu(id)
	return PLUGIN_HANDLED
}

showScanMenu(id)
{
	new menu = menu_create("\yScan System\w", "menuScan")
	new players[MAX_PLAYERS], num, name[MAX_NAME_LENGTH], line[96], info[8]
	get_players(players, num, "ch")
	for (new i; i < num; i++)
	{
		new pl = players[i]
		get_user_name(pl, name, charsmax(name))
		if (g_scanning[pl])
			formatex(line, charsmax(line), "%s \r[SCAN]\w", name)
		else
			copy(line, charsmax(line), name)
		num_to_str(get_user_userid(pl), info, charsmax(info))
		menu_additem(menu, line, info)
	}
	if (!num)
		menu_additem(menu, "(no players)", "0")
	menu_display(id, menu)
}

public menuScan(id, menu, item)
{
	if (item < 0)
	{
		menu_destroy(menu)
		return PLUGIN_HANDLED
	}
	new info[8], dummy[1]
	menu_item_getinfo(menu, item, dummy[0], info, charsmax(info), dummy, 0, dummy[0])
	menu_destroy(menu)
	new userid = str_to_num(info)
	new player = find_player("k", userid)
	if (!player)
		return PLUGIN_HANDLED
	showScanActions(id, userid)
	return PLUGIN_HANDLED
}

showScanActions(id, userid)
{
	new player = find_player("k", userid)
	if (!player)
		return
	new name[MAX_NAME_LENGTH], title[64]
	get_user_name(player, name, charsmax(name))
	formatex(title, charsmax(title), "\yScan: %s\w", name)
	new menu = menu_create(title, "menuAct")
	new packed[16]
	if (g_scanning[player])
	{
		formatex(packed, charsmax(packed), "%d clear", userid)
		menu_additem(menu, "Clear scan (allow play)", packed)
	}
	else
	{
		formatex(packed, charsmax(packed), "%d lock", userid)
		menu_additem(menu, "Put on scan (spectator lock)", packed)
	}
	menu_display(id, menu)
}

public menuAct(id, menu, item)
{
	if (item < 0)
	{
		menu_destroy(menu)
		showScanMenu(id)
		return PLUGIN_HANDLED
	}
	new info[16], dummy[1], userStr[8], act[8]
	menu_item_getinfo(menu, item, dummy[0], info, charsmax(info), dummy, 0, dummy[0])
	menu_destroy(menu)
	parse(info, userStr, charsmax(userStr), act, charsmax(act))
	new player = find_player("k", str_to_num(userStr))
	if (!player)
		return PLUGIN_HANDLED
	if (equal(act, "lock"))
		putOnScan(id, player, "Admin scan")
	else if (equal(act, "clear"))
		clearScan(id, player)
	showScanMenu(id)
	return PLUGIN_HANDLED
}

public _scan_state(plugin, params)
{
	new id = get_param(1);
	if (id < 1 || id > MaxClients || !is_user_connected(id))
		return 0;
	return g_scanning[id] ? 1 : 0;
}

putOnScan(admin, player, const reason[])
{
	if (g_scanning[player])
	{
		client_print(admin, print_chat, "[AMXX] That player is already on scan.")
		return
	}
	if (!fn_safe_can_hit(admin, player))
	{
		client_print(admin, print_chat, "[AMXX] That player outranks you.")
		return
	}
	if ((get_user_flags(player) & ADMIN_IMMUNITY) && admin != 0 && !(get_user_flags(admin) & ADMIN_RCON))
	{
		client_print(admin, print_chat, "[AMXX] That player has immunity.")
		return
	}

	g_scanning[player] = true
	g_scanStart[player] = get_systime()
	get_user_authid(player, g_scanAuth[player], charsmax(g_scanAuth[]))
	get_user_ip(player, g_scanIp[player], charsmax(g_scanIp[]), 1)
	get_user_name(player, g_scanName[player], charsmax(g_scanName[]))
	if (admin > 0)
		get_user_name(admin, g_scanBy[player], charsmax(g_scanBy[]))
	else
		copy(g_scanBy[player], charsmax(g_scanBy[]), "CONSOLE")

	saveActive(player)
	forceSpec(player)
	remove_task(TASK_REMIND + player)
	set_task(8.0, "remindScan", TASK_REMIND + player, "", 0, "b")
	remindScan(TASK_REMIND + player)

	new aname[MAX_NAME_LENGTH]
	copy(aname, charsmax(aname), g_scanBy[player])
	if (get_pcvar_num(g_cvarLeaveMode) == 1)
		client_print(0, print_chat, "[AMXX] %s put %s on scan. Leaving now = permanent Steam/IP/name ban.", aname, g_scanName[player])
	else
		client_print(0, print_chat, "[AMXX] %s put %s on scan. Leaving now = %d-min Steam/IP/name ban.", aname, g_scanName[player], get_pcvar_num(g_cvarLeaveMinutes))
	log_amx("Scan: %s locked %s <%s> %s reason ^"%s^"", aname, g_scanName[player], g_scanAuth[player], g_scanIp[player], reason)
	fn_safe_log(admin, player, "scan.lock", reason)
}

clearScan(admin, player)
{
	if (!fn_safe_can_hit(admin, player))
	{
		client_print(admin, print_chat, "[AMXX] That player outranks you.")
		return
	}
	if (!g_scanning[player])
	{
		client_print(admin, print_chat, "[AMXX] That player is not on scan.")
		return
	}

	g_scanning[player] = false
	remove_task(TASK_REMIND + player)
	removeActive(player)

	new aname[MAX_NAME_LENGTH], pname[MAX_NAME_LENGTH]
	if (admin > 0)
		get_user_name(admin, aname, charsmax(aname))
	else
		copy(aname, charsmax(aname), "CONSOLE")
	get_user_name(player, pname, charsmax(pname))
	client_print(0, print_chat, "[AMXX] %s cleared %s from scan. They may join the game.", aname, pname)
	client_print(player, print_chat, "[AMXX] You were cleared. You may join a team.")
	log_amx("Scan: %s cleared %s", aname, pname)
}

saveActive(id)
{
	if (g_vaultActive == INVALID_HANDLE || !g_scanAuth[id][0])
		return
	if (equal(g_scanAuth[id], "STEAM_ID_PENDING") || equal(g_scanAuth[id], "STEAM_ID_LAN") || equal(g_scanAuth[id], "VALVE_ID_LAN"))
		return
	new data[96]
	formatex(data, charsmax(data), "%s^t%s^t1", g_scanIp[id], g_scanName[id])
	nvault_set(g_vaultActive, g_scanAuth[id], data)
}

removeActive(id)
{
	if (g_vaultActive == INVALID_HANDLE || !g_scanAuth[id][0])
		return
	nvault_remove(g_vaultActive, g_scanAuth[id])
}

bool:restoreScan(id)
{
	if (g_vaultActive == INVALID_HANDLE)
		return false
	new auth[32], data[96], ts
	get_user_authid(id, auth, charsmax(auth))
	if (!auth[0] || !nvault_lookup(g_vaultActive, auth, data, charsmax(data), ts))
		return false

	g_scanning[id] = true
	copy(g_scanAuth[id], charsmax(g_scanAuth[]), auth)
	get_user_ip(id, g_scanIp[id], charsmax(g_scanIp[]), 1)
	get_user_name(id, g_scanName[id], charsmax(g_scanName[]))
	copy(g_scanBy[id], charsmax(g_scanBy[]), "SCAN")
	remove_task(TASK_REMIND + id)
	set_task(8.0, "remindScan", TASK_REMIND + id, "", 0, "b")
	client_print(id, print_chat, "[AMXX] You are still on scan from last map. Do not leave.")
	return true
}

bool:wasLeftOnScan(id)
{
	new auth[32], ip[32], name[MAX_NAME_LENGTH]
	get_user_authid(id, auth, charsmax(auth))
	get_user_ip(id, ip, charsmax(ip), 1)
	get_user_name(id, name, charsmax(name))
	if (isNameBanned(name))
	{
		rh_drop_client(id, "Banned: scan evasion (name)")
		return true
	}
	return false
}

bool:isNameBanned(const name[])
{
	if (g_vaultNameBan == INVALID_HANDLE || !name[0])
		return false
	new key[MAX_NAME_LENGTH], data[8], ts
	copy(key, charsmax(key), name)
	strtolower(key)
	return nvault_lookup(g_vaultNameBan, key, data, charsmax(data), ts) != 0
}

public executeLeaveBan(data[])
{
	if (g_mapEnding)
		return

	new auth[32], ip[32], name[MAX_NAME_LENGTH]
	parse(data, auth, charsmax(auth), ip, charsmax(ip), name, charsmax(name))
	sanitize(auth, charsmax(auth))
	sanitize(ip, charsmax(ip))
	sanitize(name, charsmax(name))

	new leaveMode = get_pcvar_num(g_cvarLeaveMode)
	new leaveMins = get_pcvar_num(g_cvarLeaveMinutes)
	if (leaveMins < 5) leaveMins = 5
	// M1 authority tie-in: timed evictions go through fn_bans (case + audit +
	// session accounting); permanent evictions keep direct engine bans (the
	// offender is offline so the confirm flow cannot complete) but mint a case.
	new bool:viaApi = false;
	if (leaveMode != 1 && LibraryExists("fn_bans", LibType_Library))
	{
		new st[40], pi[32], rs[96];
		if (isBanId(auth)) copy(st, charsmax(st), auth);
		if (isBanIp(ip)) copy(pi, charsmax(pi), ip);
		if (st[0] || pi[0])
		{
			formatex(rs, charsmax(rs), "scan evasion: %s", name);
			if (fn_ban_add(0, st, pi, leaveMins, rs) == 1)
				viaApi = true;
		}
	}
	if (!viaApi)
	{
		if (isBanId(auth))
		{
			if (leaveMode == 1) server_cmd("banid 0 %s;wait;writeid", auth)
			else server_cmd("banid %d %s;wait;writeid", leaveMins, auth)
		}
		if (isBanIp(ip))
		{
			if (leaveMode == 1) server_cmd("addip 0 %s;wait;writeip", ip)
			else server_cmd("addip %d %s;wait;writeip", leaveMins, ip)
		}
	}
	if (leaveMode == 1 && (isBanId(auth) || isBanIp(ip)) && LibraryExists("fn_audit", LibType_Library))
	{
		new pc[24];
		fn_case_new(0, pc, charsmax(pc));
		fn_audit_append(pc, 0, 0, "scan.evasion.perm", name);
	}
	if (isUsefulName(name))
		banName(name)
	nvault_remove(g_vaultActive, auth)

	if (leaveMode == 1)
		client_print(0, print_chat, "[AMXX] %s left during scan and was permanently banned (Steam/IP/name).", name)
	else
		client_print(0, print_chat, "[AMXX] %s left during scan and was banned %d minutes (Steam/IP/name).", name, leaveMins)
	log_amx("Scan evasion ban: %s <%s> %s mode=%d mins=%d", name, auth, ip, leaveMode, leaveMins)
	fn_safe_log(0, 0, "scan.evasion", name)
}

banName(const name[])
{
	if (g_vaultNameBan == INVALID_HANDLE || !name[0])
		return
	new key[MAX_NAME_LENGTH]
	copy(key, charsmax(key), name)
	strtolower(key)
	nvault_set(g_vaultNameBan, key, "1")
	addNameBanEntry(key)
}

removeNameBan(const name[])
{
	if (g_vaultNameBan == INVALID_HANDLE || !name[0])
		return
	new key[MAX_NAME_LENGTH]
	copy(key, charsmax(key), name)
	strtolower(key)
	nvault_remove(g_vaultNameBan, key)
	delNameBanEntry(key)
}

loadNameBans()
{
	g_nameBanCount = 0
	new vaultFile[128], fp
	get_datadir(vaultFile, charsmax(vaultFile))
	format(vaultFile, charsmax(vaultFile), "%s/vault/scan_nameban.vault", vaultFile)
	fp = fopen(vaultFile, "rt")
	if (!fp)
		return
	new line[128], key[MAX_NAME_LENGTH], val[8]
	while (fgets(fp, line, charsmax(line)) && g_nameBanCount < 128)
	{
		trim(line)
		if (!line[0] || line[0] == ';')
			continue
		if (parse(line, key, charsmax(key), val, charsmax(val)) < 1)
			continue
		strtolower(key)
		copy(g_nameBanList[g_nameBanCount++], MAX_NAME_LENGTH - 1, key)
	}
	fclose(fp)
}

bool:isBanId(const auth[])
{
	if (!auth[0] || contain(auth, " ") != -1)
		return false
	if (equal(auth, "STEAM_ID_PENDING") || equal(auth, "STEAM_ID_LAN") || equal(auth, "VALVE_ID_LAN") || equal(auth, "BOT"))
		return false
	return contain(auth, "STEAM_") == 0 || contain(auth, "VALVE_") == 0
}

bool:isBanIp(const ip[])
{
	if (!ip[0] || contain(ip, " ") != -1)
		return false
	if (equal(ip, "loopback") || equal(ip, "127.0.0.1") || equal(ip, "0.0.0.0"))
		return false
	return contain(ip, ".") != -1
}

bool:isUsefulName(const name[])
{
	if (!name[0] || strlen(name) < 3)
		return false
	if (equali(name, "player") || equali(name, "unnamed") || equali(name, "unconnected") || equali(name, "hltv") || equali(name, "console"))
		return false
	return true
}

public cmdUnbanName(id, level, cid)
{
	if (!cmd_access(id, level, cid, 2))
		return PLUGIN_HANDLED
	new arg[MAX_NAME_LENGTH]
	read_argv(1, arg, charsmax(arg))
	trim(arg)
	remove_quotes(arg)
	if (!arg[0])
	{
		console_print(id, "[AMXX] Usage: amx_unscanname <name>")
		return PLUGIN_HANDLED
	}
	new key[MAX_NAME_LENGTH]
	copy(key, charsmax(key), arg)
	strtolower(key)
	if (g_vaultNameBan == INVALID_HANDLE)
		return PLUGIN_HANDLED
	removeNameBan(arg)
	console_print(id, "[AMXX] Scan name-ban removed: %s", arg)
	log_amx("Scan: %d removed name-ban %s", id, arg)
	return PLUGIN_HANDLED
}

public cmdNameBans(id, level, cid)
{
	if (!cmd_access(id, level, cid, 1))
		return PLUGIN_HANDLED
	console_print(id, "[AMXX] Scan name-bans: (use amx_unscanname <name> to remove)")
	if (!g_nameBanCount)
		console_print(id, "  (none)")
	for (new i = 0; i < g_nameBanCount; i++)
		console_print(id, "  %s", g_nameBanList[i])
	return PLUGIN_HANDLED
}

addNameBanEntry(const key[])
{
	for (new i = 0; i < g_nameBanCount; i++)
	{
		if (equal(g_nameBanList[i], key))
			return
	}
	if (g_nameBanCount < 128)
		copy(g_nameBanList[g_nameBanCount++], MAX_NAME_LENGTH - 1, key)
}

delNameBanEntry(const key[])
{
	for (new i = 0; i < g_nameBanCount; i++)
	{
		if (!equal(g_nameBanList[i], key))
			continue
		for (new j = i; j < g_nameBanCount - 1; j++)
			copy(g_nameBanList[j], MAX_NAME_LENGTH - 1, g_nameBanList[j + 1])
		g_nameBanCount--
		return
	}
}

sanitize(buf[], len)
{
	replace_all(buf, len, ";", " ")
	replace_all(buf, len, "^n", " ")
	replace_all(buf, len, "^r", " ")
	replace_all(buf, len, "^"", "'")
}