/*
	Advanced Bans
	
	Version 0.8.1
	
	by Exolent
	
	
	
	Plugin Thread:
	
	- http://forums.alliedmods.net/showthread.php?t=80858
	
	
	
	Description:
	
	- This plugin revamps the current amx_ban, amx_banip, amx_banid, amx_unban admin commands.
	
	- It uses Real Time on the server
	  (Eg. Banned for 10 minutes, you will be unbanned 10 minutes later, regardless of map changing).
	
	- It includes a list of who is banned.
	
	- It does not use banned.cfg or listip.cfg. Bans live in PostgreSQL (postgres_engine.amxx),
	  not AMXX SQLX. Each live ban stores SteamID and IP together.
	
	- It saves what admin banned the player (name), the admin's steamid, the reason, the ban time, 
	  the banned player's name, the banned player's steamid, IP, and the estimated time of unban.
	
	- It will load your currently banned players from the banned.cfg and listip.cfg files.
	  (Only if the #define below is uncommented)
	
	- If you use the menu to ban players, you will have to type a reason after you choose a player.
	
	- If you use the vote system to ban players, you will have to type a reason after you execute the amx_voteban command.
	
	- You can limit the ban time for admins based on their admin flags.
	
	- You can monitor all ban history (admins banning, unbanning, and when ban times are up) in
	  the addons/amxmodx/logs/BAN_HISTORY_MMDDYYYY.log (MM = month, DD = day, YYYY = year)
	
	- If you wish to have only 1 file for ban history, uncomment the line at the top of the .sma file and recompile.
	
	- Supports SQL for banning.
	
	
	
	Commands:
	
	- amx_ban <nick, #userid, authid> <time in minutes> <reason>
	
	- amx_banip <nick, #userid, authid> <time in minutes> <reason>
	
	- amx_addban <name> <authid or ip> <time in minutes> <reason>
	
	- amx_unban <authid or ip>
	
	- amx_banlist
	  - Shows a list of who is banned
	
	- amx_addbanlimit <flags> <time in minutes>
	  - Adds a max ban time to the list
	  - Note: Use this command in the amxx.cfg
	
	
	
	Cvars:
	
	- ab_website <website>
	  - This is the website displayed to the banned player if you have an unban request section on your website.
	  - Leave blank to not show a website.
	  - Default: blank
	
	- ab_immunity <0|1|2>
	  - 0 - Any admin can ban an immunity admin (flag 'a').
	  - 1 - Immunity admins (flag 'a') cannot be banned.
	  - 2 - Immunity admins (flag 'a') can only be banned by other immunity admins (flag 'a').
	  - Default: 1
	
	- ab_bandelay <seconds>
	  - Delay of banned players being disconnected.
	  - Default: 1
	
	- ab_unbancheck <seconds>
	  - Interval of checking if a player is unbanned.
	  - Default: 5
	
	
	
	Requirements:
	
	- AMX Mod X version 1.8.0 or higher
	
	
	
	Changelog:

	- Version 0.1 (with updates included)
	  - Initial Release
	  - Changed to dynamic arrays to hold ban information
	  - Added option #2 for ab_immunity
	  - Added support for banning by IP
	  - Added compatability for banned.cfg and listip.cfg
	  - Added menu support (plmenu.amxx)
	  - Added ML support

	- Version 0.2
	  - Added simple max ban time feature

	- Version 0.3
	  - Added more cvars for max ban times
	  - Added cvar for delay of player to disconenct after being banned
	  - Added cvar for interval of checking for unban time of banned players
	  - Added more translations

	- Version 0.4
	  - Fixed the possible infinite loop, causing servers to crash
	  - Added ban history
	  - Removed max ban time cvars
	  - Added max ban times per admin flags
	  - Added more translations

	- Version 0.5
	  - Fixed information not being printed into console
	  - Fixed "amx_addban" using the admin's name as the SteamID when saving the ban
	  - Added option for ban history to be one file
	  - Added translations

	- Version 0.5b
	  - Fixed players not being unbanned
	  - Added translations
	
	- Version 0.6
	  - Added small optimization for unban checking
	  - Changed "UnBan Time" in the logs and chat messages to "Ban Length"
	  - Fixed small code error where unban time was generated was used when length was 0
	  - Changed IsValidIP() method to use regex (Thanks to arkshine)
	  - Added plugin information inside the .sma file
	  - Added a #define option to use maximum bans for compatability for AMXX < 1.8.0
	  - Changed admin messages in chat to work with amx_show_activity cvar
	  - Added translations
	
	- Version 0.6b
	  - Fixed a small bug
	
	- Version 0.6c
	  - Fixed amx_banlist for server consoles
	  - Changed IsValidAuthid() method to use regex
	
	- Version 0.6d
	  - Fixed ban limit for permanent bans
	
	- Version 0.7
	  - Changed the "unlimited bans" version to be faster (Thanks to joaquimandrade)
	  - Added check when adding bans if the player is already banned.
	
	- Version 0.8
	  - Added SQL support.
	
	- Version 0.8.1
	  - Added unban logging for non-SQL version
	
	
	
	Notes:
	
	- If you plan to use this plugin, go to the plugin's thread.
	
	- The plugin's thread has more information about the plugin, along with the multilingual file.
	
	- It also has a modified plmenu.amxx plugin that adds the ban reason to the menu.
	
	- And it has a modified adminvote.amxx plugin that adds the ban reason to amx_voteban.
*/



#include <amxmodx>
#include <amxmisc>
#include <engine>
#include <regex>
#include <cban_main>
#include <freenova_ui>

// Optional audit provider. Calls are guarded by LibraryExists so the ban
// backend remains loadable during a staged rollout where fn_audit is absent.
native fn_case_new(admin, out[], len);
native fn_case_note(admin, const case_id[], const note[]);

#define PLUGIN_NAME	"Advanced Bans"
#define PLUGIN_VERSION	"0.9.9-fn-hybrid"
#define PLUGIN_AUTHOR	"Exolent / FreeNova"

#pragma semicolon 1



// ===============================================
// CUSTOMIZATION STARTS HERE
// ===============================================


// uncomment the line below if you want this plugin to
// load old bans from the banned.cfg and listip.cfg files
//#define KEEP_DEFAULT_BANS


// uncomment the line below if you want the history to be in one file
//#define HISTORY_ONE_FILE


// if you must have a maximum amount of bans to be compatible with AMXX versions before 1.8.0
// change this number to your maximum amount
// if you would rather have unlimited (requires AMXX 1.8.0 or higher) then set it to 0
#define MAX_BANS 0


// if you want to use SQL for your server, then uncomment the line below
#define USING_SQL


// ===============================================
// CUSTOMIZATION ENDS HERE
// ===============================================



#if defined USING_SQL
#include <postgres>
#include <sqlx> // local SQLite mirror + pending-push queue (PG stays primary)

#define TABLE_NAME		"advanced_bans"
#define TABLE_HISTORY		"advanced_bans_history"
#define TABLE_RECENT		"ab_recent"
#define KEY_NAME		"name"
#define KEY_STEAMID		"steamid"
#define KEY_IP			"ip"
#define KEY_BANLENGTH		"banlength"
#define KEY_UNBANTIME		"unbantime"
#define KEY_REASON		"reason"
#define KEY_ADMIN_NAME		"admin_name"
#define KEY_ADMIN_STEAMID	"admin_steamid"
#define TASK_RECHECK		55200
#define TASK_KICK		55100
#define TASK_HYBRID_SYNC	54800
#define TASK_BOOT_FALLBACK	54801

#endif

#define REGEX_IP_PATTERN "\b(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\b"
#define REGEX_STEAMID_PATTERN "^^(STEAM|VALVE)_[0-9]:[0-9]:\d+$"

new Regex:g_IP_pattern;
new Regex:g_SteamID_pattern;
new g_regex_return;

/*bool:IsValidIP(const ip[])
{
	return regex_match_c(ip, g_IP_pattern, g_regex_return) > 0;
}*/

#define IsValidIP(%1) (regex_match_c(%1, g_IP_pattern, g_regex_return) > 0)

/*bool:IsValidAuthid(const authid[])
{
	return regex_match_c(authid, g_SteamID_pattern, g_regex_return) > 0;
}*/

#define IsValidAuthid(%1) (regex_match_c(%1, g_SteamID_pattern, g_regex_return) > 0)


enum // for name displaying
{
	ACTIVITY_NONE, // nothing is shown
	ACTIVITY_HIDE, // admin name is hidden
	ACTIVITY_SHOW  // admin name is shown
};
new const g_admin_activity[] =
{
	ACTIVITY_NONE, // amx_show_activity 0 = show nothing to everyone
	ACTIVITY_HIDE, // amx_show_activity 1 = hide admin name from everyone
	ACTIVITY_SHOW, // amx_show_activity 2 = show admin name to everyone
	ACTIVITY_SHOW, // amx_show_activity 3 = show name to admins but hide it from normal users
	ACTIVITY_SHOW, // amx_show_activity 4 = show name to admins but show nothing to normal users
	ACTIVITY_HIDE  // amx_show_activity 5 = hide name from admins but show nothing to normal users
};
new const g_normal_activity[] =
{
	ACTIVITY_NONE, // amx_show_activity 0 = show nothing to everyone
	ACTIVITY_HIDE, // amx_show_activity 1 = hide admin name from everyone
	ACTIVITY_SHOW, // amx_show_activity 2 = show admin name to everyone
	ACTIVITY_HIDE, // amx_show_activity 3 = show name to admins but hide it from normal users
	ACTIVITY_NONE, // amx_show_activity 4 = show name to admins but show nothing to normal users
	ACTIVITY_NONE  // amx_show_activity 5 = hide name from admins but show nothing to normal users
};


#if MAX_BANS <= 0
enum _:BannedData
{
	bd_id,
	bd_name[32],
	bd_steamid[35],
	bd_ip[35],
	bd_banlength,
	bd_unbantime[32],
	bd_reason[128],
	bd_admin_name[64],
	bd_admin_steamid[35]
};

new Trie:g_trie;
new Array:g_array;
#else
new g_names[MAX_BANS][32];
new g_steamids[MAX_BANS][35];
new g_banlengths[MAX_BANS];
new g_unbantimes[MAX_BANS][32];
new g_reasons[MAX_BANS][128];
new g_admin_names[MAX_BANS][64];
new g_admin_steamids[MAX_BANS][35];
#endif
new g_total_bans;

new g_ban_file[128];
new g_pending_del_file[128];
#if defined USING_SQL
new bool:g_loading_bans = false;
#endif
new g_fwdBanned;
// Hybrid PG-primary + local-file fallback (0.9.9-fn-hybrid):
// PG is authoritative when reachable and hourly re-pulled (all servers).
// The local file mirrors PG and keeps enforcing + recording bans while PG is down.
new bool:g_bPGOnline = false;
new bool:g_bLocalFallback = false;
new g_iLastSyncOk = 0;
new g_iSyncFails = 0;
new ab_sync_interval;
new ab_local_fallback;
new ab_sqlite_fallback;
new ab_pending_max;
new bool:g_bFlushing = false;
new bool:g_bFlushActive = false;
new g_iFlushFired = 0;
new g_iFlushConfirmed = 0;
new bool:g_flushHadFail = false;
new g_flushList[64][35];
new g_flushCount = 0;
new g_pdKeep[2048][35];
new g_iLoadStart = 0;
#if defined USING_SQL
// Local SQLite mirror + pending-push queue (fn-sqlite, PG stays primary).
// SQLite file data/ab_bans.sq3 is opened in SQLiteInit() via the sqlx sqlite
// affinity (SQL_MakeDbTuple("", "", "", "ab_bans")). The flat-file mirror is
// kept as-is as a second fallback. Enforcement reads stay trie-only.
// Conflict rule: on any steamid/ip match the PG row wins; local rows never
// shadow PG rows. Fail-closed: any SQLite error is logged once, the op
// continues file-only and enforcement is never blocked on SQLite.
#define SQLITE_DB_NAME "ab_bans"
#define SQLITE_TABLE_MIRROR "ab_mirror"
#define SQLITE_TABLE_PENDING "ab_pending_push"
new Handle:g_hSQLiteTuple = Empty_Handle;
new Handle:g_hSQLiteConn = Empty_Handle;
new bool:g_bSQLiteOn = false;
new bool:g_bSQLiteErrLogged = false;
#endif

new ab_website;
new ab_immunity;
new ab_bandelay;
new ab_unbancheck;

new amx_show_activity;

#if MAX_BANS <= 0
new Array:g_maxban_times;
new Array:g_maxban_flags;
#else
#define MAX_BANLIMITS	30
new g_maxban_times[MAX_BANLIMITS];
new g_maxban_flags[MAX_BANLIMITS];
#endif
new g_total_maxban_times;

new g_unban_entity;

new g_max_clients;

new g_msgid_SayText;

new g_fwdCBanPre;
new g_fwdCBanPost;
new g_fwdCBanAdd;
new g_fwdCBanOff;

#define MAX_OFFBAN 32
new Array:g_off_name;
new Array:g_off_steamid;
new Array:g_off_ip;
new Array:g_off_seen;
new ab_debug;
new g_kick_userid[33];
new g_kick_auth[33][35];
new g_next_banid;

public plugin_natives()
{
	register_library("cban");
	register_native("CBan_BanPlayer", "_CBan_BanPlayer");
	register_native("CBan_UnbanPlayer", "_CBan_UnbanPlayer");
	register_native("CBan_OffBanPlayer", "_CBan_OffBanPlayer");
	register_native("CBan_AddBanPlayer", "_CBan_AddBanPlayer");
	register_native("CBan_GetBanCount", "_CBan_GetBanCount");
	register_native("CBan_GetBanInfo", "_CBan_GetBanInfo");
	register_native("CBan_UnbanById", "_CBan_UnbanById");
}

public plugin_init()
{
	register_plugin(PLUGIN_NAME, PLUGIN_VERSION, PLUGIN_AUTHOR);
	register_cvar("advanced_bans", PLUGIN_VERSION, FCVAR_SPONLY);
	
	register_dictionary("advanced_bans.txt");
	
	g_fwdBanned = CreateMultiForward("advanced_bans_player_banned", ET_IGNORE, FP_CELL, FP_CELL, FP_CELL, FP_STRING);
	g_fwdCBanPre = CreateMultiForward("CBan_OnPlayerBannedPre", ET_STOP, FP_CELL, FP_CELL, FP_VAL_BYREF, FP_STRING);
	g_fwdCBanPost = CreateMultiForward("CBan_OnPlayerBannedPost", ET_IGNORE, FP_CELL, FP_CELL, FP_CELL, FP_STRING);
	g_fwdCBanAdd = CreateMultiForward("CBan_OnAddBan", ET_STOP, FP_STRING, FP_CELL, FP_VAL_BYREF, FP_STRING);
	g_fwdCBanOff = CreateMultiForward("CBan_OnOffBan", ET_STOP, FP_STRING, FP_CELL, FP_VAL_BYREF, FP_STRING);
	
	g_off_name = ArrayCreate(32);
	g_off_steamid = ArrayCreate(35);
	g_off_ip = ArrayCreate(35);
	g_off_seen = ArrayCreate(1);
	
	register_concmd("amx_ban", "CmdBan", ADMIN_BAN|ADMIN_BAN_TEMP, "<nick, #userid, authid> <time in minutes> [reason]");
	register_concmd("amx_banip", "CmdBanIp", ADMIN_BAN|ADMIN_BAN_TEMP, "<nick, #userid, authid> <time in minutes> [reason]");
	register_concmd("amx_addban", "CmdAddBan", ADMIN_BAN, "<name> <authid or ip> <time in minutes> [reason]");
	register_concmd("amx_unban", "CmdUnban", ADMIN_BAN|ADMIN_BAN_TEMP, "<authid or ip or nick or #id>");
	// Dedicated command used by FREENOVA's CBan_UnbanPlayer native. The stock
	// admincmd.amxx also registers amx_unban and returns PLUGIN_HANDLED, so
	// routing the native through amx_unban silently removed only the legacy
	// banned.cfg entry instead of the live AdvancedBans row.
	register_concmd("fn_cban_unban", "CmdUnban", ADMIN_BAN|ADMIN_BAN_TEMP, "<authid or ip or nick or #id>");
	register_concmd("amx_offban", "CmdOffBan", ADMIN_BAN|ADMIN_BAN_TEMP, "<nick | steamid | ip> <time in minutes> [reason]");
	register_concmd("amx_rban", "CmdRangeBan", ADMIN_BAN, "<start ip> <end ip> [reason]");
	register_concmd("amx_unrban", "CmdRangeUnban", ADMIN_BAN, "<start ip> <end ip> - remove BypassGuard IP range");
	register_concmd("amx_banlist", "CmdBanList", ADMIN_BAN, "[start] -- shows everyone who is banned");
	register_concmd("amx_checkban", "CmdCheckBan", ADMIN_BAN, "<steamid | ip | nick | #id>");
	register_concmd("amx_reloadbans", "CmdReloadBans", ADMIN_BAN, "- reload live bans from PostgreSQL");
	register_concmd("amx_offlist", "CmdLast", ADMIN_BAN, "- recent disconnects for offban");
	register_concmd("amx_banhistory", "CmdBanHistory", ADMIN_BAN, "[steamid | ip] - last 10 history rows");
	register_concmd("amx_banstatus", "CmdBanStatus", ADMIN_BAN, "- PG/local hybrid status");
	register_srvcmd("amx_addbanlimit", "CmdAddBanLimit", -1, "<flag> <time in minutes>");
	
	ab_website = register_cvar("ab_website", "");
	ab_immunity = register_cvar("ab_immunity", "1");
	ab_bandelay = register_cvar("ab_bandelay", "5.0");
	ab_unbancheck = register_cvar("ab_unbancheck", "5.0");
	ab_debug = register_cvar("ab_debug", "0");
	#if defined USING_SQL
	ab_sync_interval = register_cvar("ab_sync_interval", "3600");
	ab_local_fallback = register_cvar("ab_local_fallback", "1");
	ab_sqlite_fallback = register_cvar("ab_sqlite_fallback", "1", FCVAR_SPONLY);
	ab_pending_max = register_cvar("ab_pending_max", "500", FCVAR_SPONLY);
	#endif
	
	amx_show_activity = register_cvar("amx_show_activity", "2");
	
	#if MAX_BANS <= 0
	g_trie = TrieCreate();
	g_array = ArrayCreate(BannedData);
	#endif
	
	#if !defined MAX_BANLIMITS
	g_maxban_times = ArrayCreate(1);
	g_maxban_flags = ArrayCreate(1);
	#endif
	
	BuildLocalPath();
	
	#if !defined USING_SQL
	LoadBans();
	#endif
	
	new error[2];
	g_IP_pattern = regex_compile(REGEX_IP_PATTERN, g_regex_return, error, sizeof(error) - 1);
	g_SteamID_pattern = regex_compile(REGEX_STEAMID_PATTERN, g_regex_return, error, sizeof(error) - 1);
	
	g_max_clients = get_maxplayers();
	
	g_msgid_SayText = get_user_msgid("SayText");
}

#if defined USING_SQL
PrepareTable()
{
	static query[1024];
	formatex(query, sizeof(query) - 1,
		"CREATE TABLE IF NOT EXISTS %s (id SERIAL PRIMARY KEY, %s VARCHAR(32) NOT NULL, %s VARCHAR(35) NOT NULL DEFAULT '', %s VARCHAR(45) NOT NULL DEFAULT '', %s INTEGER NOT NULL, %s VARCHAR(32) NOT NULL, %s VARCHAR(128) NOT NULL, %s VARCHAR(64) NOT NULL, %s VARCHAR(35) NOT NULL);",
		TABLE_NAME, KEY_NAME, KEY_STEAMID, KEY_IP, KEY_BANLENGTH, KEY_UNBANTIME, KEY_REASON, KEY_ADMIN_NAME, KEY_ADMIN_STEAMID
		);
	PG_ThreadQuery("QueryCreateTable", query);
	
	formatex(query, sizeof(query) - 1,
		"CREATE TABLE IF NOT EXISTS %s (id SERIAL PRIMARY KEY, action VARCHAR(8) NOT NULL, name VARCHAR(32), steamid VARCHAR(35), ip VARCHAR(45), minutes INTEGER, reason VARCHAR(128), admin_name VARCHAR(64), admin_steamid VARCHAR(35), created BIGINT NOT NULL);",
		TABLE_HISTORY);
	PG_ThreadQuery("QueryGeneric", query);
	
	formatex(query, sizeof(query) - 1,
		"CREATE TABLE IF NOT EXISTS %s (name VARCHAR(32) NOT NULL, steamid VARCHAR(35), ip VARCHAR(45), seen BIGINT);",
		TABLE_RECENT);
	PG_ThreadQuery("QueryGeneric", query);
}

public QueryGeneric(failstate, query, error[], errcode, data[], datasize, Float:queuetime)
{
	if( failstate || errcode )
		log_amx("[AdvancedBans] SQL (%d/%d): %s", failstate, errcode, error);
}

public QueryCreateTable(failstate, query, error[], errcode, data[], datasize, Float:queuetime)
{
	if( failstate || errcode )
	{
		log_amx("[AdvancedBans] Table create failed (%d/%d): %s - retrying, plugin stays loaded", failstate, errcode, error);
		if( !task_exists(TASK_RECHECK + 900) )
			set_task(10.0, "RetryPrepare", TASK_RECHECK + 900);
		if( get_pcvar_num(ab_local_fallback) && g_total_bans == 0 && !g_bPGOnline )
			LoadLocalFile();
		return;
	}
	
	LoadBans();
	LoadRecentDisconnects();
}

public RetryPrepare()
{
	log_amx("[AdvancedBans] Retrying PostgreSQL table create");
	PrepareTable();
}
#endif

public plugin_cfg()
{
	#if defined USING_SQL
	log_amx("[AdvancedBans] Using PostgreSQL engine (not SQLX)");
	BuildLocalPath();
	PrepareTable();
	new Float:sync_iv = get_pcvar_float(ab_sync_interval);
	if( sync_iv < 60.0 ) sync_iv = 60.0;
	if( !task_exists(TASK_HYBRID_SYNC) )
		set_task(sync_iv, "Task_HourlySync", TASK_HYBRID_SYNC, _, _, "b");
	set_task(12.0, "Task_BootFallback", TASK_BOOT_FALLBACK);
	SQLiteInit();
	#endif
	CreateUnbanEntity();
}

public plugin_end()
{
#if defined USING_SQL
	if( g_hSQLiteConn != Empty_Handle )
	{
		SQL_FreeHandle(g_hSQLiteConn);
		g_hSQLiteConn = Empty_Handle;
	}
	if( g_hSQLiteTuple != Empty_Handle )
	{
		SQL_FreeHandle(g_hSQLiteTuple);
		g_hSQLiteTuple = Empty_Handle;
	}
#endif

	// plugin_init() creates these handles and nothing ever destroyed them, so
	// every reload - changelevel included - leaked them: the four offban arrays,
	// the ban trie and ban array, and the ban-limit arrays. REVIEW.md §5.3.
	if( g_off_name ) ArrayDestroy(g_off_name);
	if( g_off_steamid ) ArrayDestroy(g_off_steamid);
	if( g_off_ip ) ArrayDestroy(g_off_ip);
	if( g_off_seen ) ArrayDestroy(g_off_seen);
#if MAX_BANS <= 0
	if( g_trie ) TrieDestroy(g_trie);
	if( g_array ) ArrayDestroy(g_array);
#endif
#if !defined MAX_BANLIMITS
	if( g_maxban_times ) ArrayDestroy(g_maxban_times);
	if( g_maxban_flags ) ArrayDestroy(g_maxban_flags);
#endif
}

public CreateUnbanEntity()
{
	static failtimes;
	
	g_unban_entity = create_entity("info_target");
	
	if( !is_valid_ent(g_unban_entity) )
	{
		++failtimes;
		
		log_amx("[ERROR] Failed to create unban entity (%i/10)", failtimes);
		
		if( failtimes < 10 )
		{
			set_task(1.0, "CreateUnbanEntity");
		}
		else
		{
			log_amx("[ERROR] Could not create unban entity!");
		}
		
		return;
	}
	
	entity_set_string(g_unban_entity, EV_SZ_classname, "unban_entity");
	entity_set_float(g_unban_entity, EV_FL_nextthink, get_gametime() + 1.0);
	
	register_think("unban_entity", "FwdThink");
}

public client_authorized(client)
{
	CheckPlayerBan(client);
	
	if( !is_user_bot(client) && !is_user_hltv(client) )
	{
		set_task(0.5, "TaskRecheckBan", client + TASK_RECHECK);
		set_task(2.5, "TaskRecheckBan", client + TASK_RECHECK + 32);
	}
}

public TaskRecheckBan(taskid)
{
	new client = taskid - TASK_RECHECK;
	if( client > 32 ) client -= 32;
	if( 1 <= client <= g_max_clients && is_user_connected(client) )
	{
		CheckPlayerBan(client);
	}
}

CheckPlayerBan(client)
{
	if( client < 1 || client > g_max_clients ) return;
	if( !is_user_connected(client) && !is_user_connecting(client) ) return;
	if( is_user_bot(client) || is_user_hltv(client) ) return;
	
	static authid[35], ip[35];
	get_user_authid(client, authid, sizeof(authid) - 1);
	get_user_ip(client, ip, sizeof(ip) - 1, 1);
	NormalizeIp(ip, sizeof(ip) - 1);
	
	static array_pos;
	new bool:hit;
	if( IsUsableAuthid(authid) && TrieGetCell(g_trie, authid, array_pos) )
		hit = true;
	else if( ip[0] && TrieGetCell(g_trie, ip, array_pos) )
		hit = true;
	
	if( !hit ) return;
	
	static data[BannedData];
	ArrayGetArray(g_array, array_pos, data);
	
	if( BanHasExpired(data[bd_banlength], data[bd_unbantime]) )
	{
		Dbg("expired on connect %d %s", client, authid);
		RemoveBan(array_pos, data[bd_steamid], data[bd_ip]);
		CheckPlayerBan(client);
		return;
	}
	
	static identity[35];
	GetBanIdentity(data[bd_steamid], data[bd_ip], identity, sizeof(identity) - 1);
	
	Dbg("ban hit %d %s / %s -> %s", client, authid, ip, identity);
	
	PrintBanInformation(client, data[bd_name], identity, data[bd_reason], data[bd_banlength], data[bd_unbantime], data[bd_admin_name], data[bd_admin_steamid], true, true);
	ShowBanMotd(client, data[bd_name], data[bd_steamid], data[bd_ip], data[bd_reason], data[bd_banlength], data[bd_unbantime], data[bd_admin_name], data[bd_admin_steamid]);
	
	ScheduleKick(client);
}

ScheduleKick(client)
{
	if( client < 1 || client > g_max_clients ) return;
	
	g_kick_userid[client] = get_user_userid(client);
	get_user_authid(client, g_kick_auth[client], sizeof(g_kick_auth[]) - 1);
	
	if( !task_exists(client + TASK_KICK) )
	{
		set_task(get_pcvar_float(ab_bandelay), "TaskDisconnectPlayer", client + TASK_KICK);
	}
}

public client_disconnected(client)
{
	remove_task(client + TASK_KICK);
	remove_task(client + TASK_RECHECK);
	remove_task(client + TASK_RECHECK + 32);
	g_kick_userid[client] = 0;
	g_kick_auth[client][0] = 0;
	
	if( is_user_bot(client) || is_user_hltv(client) ) return;
	
	static name[32], steamid[35], ip[35];
	get_user_name(client, name, sizeof(name) - 1);
	get_user_authid(client, steamid, sizeof(steamid) - 1);
	get_user_ip(client, ip, sizeof(ip) - 1, 1);
	NormalizeIp(ip, sizeof(ip) - 1);
	
	if( !name[0] ) return;
	
	new seen = get_systime();
	new pos = FindOffBanByName(name);
	if( pos == -1 )
		pos = FindOffBanByAuth(steamid[0] ? steamid : ip);
	if( pos == -1 )
	{
		ArrayPushString(g_off_name, name);
		ArrayPushString(g_off_steamid, steamid);
		ArrayPushString(g_off_ip, ip);
		ArrayPushCell(g_off_seen, seen);
		
		if( ArraySize(g_off_name) > MAX_OFFBAN )
		{
			ArrayDeleteItem(g_off_name, 0);
			ArrayDeleteItem(g_off_steamid, 0);
			ArrayDeleteItem(g_off_ip, 0);
			ArrayDeleteItem(g_off_seen, 0);
		}
	}
	else
	{
		ArraySetString(g_off_name, pos, name);
		ArraySetString(g_off_steamid, pos, steamid);
		ArraySetString(g_off_ip, pos, ip);
		ArraySetCell(g_off_seen, pos, seen);
	}
	
	RememberRecent(name, steamid, ip);
}

public CmdBan(client, level, cid)
{
	if( !cmd_access(client, level, cid, 3) ) return PLUGIN_HANDLED;
	
	static arg1[128], arg2[32], reason[128];
	read_argv(1, arg1, sizeof(arg1) - 1);
	read_argv(2, arg2, sizeof(arg2) - 1);
	
	new target, length, reason_from;
	
	if( LooksLikeMinutes(arg1) )
	{
		new maybe_target = cmd_target(client, arg2, GetTargetFlags(client));
		if( maybe_target )
		{
			length = str_to_num(arg1);
			target = maybe_target;
			reason_from = 3;
		}
	}
	
	if( !target )
	{
		target = cmd_target(client, arg1, GetTargetFlags(client));
		length = str_to_num(arg2);
		reason_from = 3;
	}
	
	if( !target ) return PLUGIN_HANDLED;
	
	ReadReasonFrom(reason_from, reason, sizeof(reason) - 1);
	if( !reason[0] ) copy(reason, sizeof(reason) - 1, "banned");
	IssueLiveBan(client, target, length, reason);
	return PLUGIN_HANDLED;
}

public CmdBanIp(client, level, cid)
{
	if( !cmd_access(client, level, cid, 3) ) return PLUGIN_HANDLED;
	
	static arg1[128], arg2[32], reason[128];
	read_argv(1, arg1, sizeof(arg1) - 1);
	read_argv(2, arg2, sizeof(arg2) - 1);
	
	new target, length, reason_from;
	if( LooksLikeMinutes(arg1) )
	{
		new maybe_target = cmd_target(client, arg2, GetTargetFlags(client));
		if( maybe_target )
		{
			length = str_to_num(arg1);
			target = maybe_target;
			reason_from = 3;
		}
	}
	
	if( !target )
	{
		target = cmd_target(client, arg1, GetTargetFlags(client));
		length = str_to_num(arg2);
		reason_from = 3;
	}
	
	if( !target ) return PLUGIN_HANDLED;
	
	ReadReasonFrom(reason_from, reason, sizeof(reason) - 1);
	if( !reason[0] ) copy(reason, sizeof(reason) - 1, "banned");
	IssueLiveBan(client, target, length, reason);
	return PLUGIN_HANDLED;
}

public CmdAddBan(client, level, cid)
{
	if( !cmd_access(client, level, cid, 4) ) return PLUGIN_HANDLED;
	
	static target_name[32], target_authid[35], bantime[10], reason[128];
	read_argv(1, target_name, sizeof(target_name) - 1);
	read_argv(2, target_authid, sizeof(target_authid) - 1);
	read_argv(3, bantime, sizeof(bantime) - 1);
	read_argv(4, reason, sizeof(reason) - 1);
	if( contain(reason, " ") != -1 || read_argc() > 5 )
	{
		ReadReasonFrom(4, reason, sizeof(reason) - 1);
	}
	if( !reason[0] ) copy(reason, sizeof(reason) - 1, "banned");
	
	new bool:is_ip = bool:(containi(target_authid, ".") != -1);
	
	if( !is_ip && !IsValidAuthid(target_authid) )
	{
		console_print(client, "[AdvancedBans] %L", client, "AB_INVALID_STEAMID");
		console_print(client, "[AdvancedBans] %L", client, "AB_VALID_STEAMID_FORMAT");
		
		return PLUGIN_HANDLED;
	}
	else if( is_ip )
	{
		new pos = contain(target_authid, ":");
		if( pos > 0 )
		{
			target_authid[pos] = 0;
		}
		
		if( !IsValidIP(target_authid) )
		{
			console_print(client, "[AdvancedBans] %L", client, "AB_INVALID_IP");
			
			return PLUGIN_HANDLED;
		}
	}
	
	if( IsAlreadyBanned(is_ip ? "" : target_authid, is_ip ? target_authid : "") )
	{
		ReplaceExistingBan(is_ip ? "" : target_authid, is_ip ? target_authid : "");
	}
	
	new length = str_to_num(bantime);
	new maxlength = GetMaxBanTime(client);
	
	if( maxlength && (!length || length > maxlength) )
	{
		console_print(client, "[AdvancedBans] %L", client, "AB_MAX_BAN_TIME", maxlength);
		return PLUGIN_HANDLED;
	}
	
	new live = find_player(is_ip ? "d" : "c", target_authid);
	if( live && is_user_connected(live) )
	{
		IssueLiveBan(client, live, length, reason);
		return PLUGIN_HANDLED;
	}
	
	static unban_time[32];
	GenerateUnbanTime(length, unban_time, sizeof(unban_time) - 1);
	
	static admin_name[64], admin_authid[35];
	FillAdminIdentity(client, admin_name, sizeof(admin_name) - 1, admin_authid, sizeof(admin_authid) - 1);
	
	if( !FireCBanAdd(target_authid, client, length, reason) )
	{
		return PLUGIN_HANDLED;
	}
	
	static fill_steam[35], fill_ip[35];
	copy(fill_steam, sizeof(fill_steam) - 1, is_ip ? "" : target_authid);
	copy(fill_ip, sizeof(fill_ip) - 1, is_ip ? target_authid : "");
	FillMissingIdentity(fill_steam, fill_ip);
	
	AddBan(target_name, fill_steam, fill_ip, reason, length, unban_time, admin_name, admin_authid);
	RecordHistory("BAN", target_name, fill_steam, fill_ip, length, reason, admin_name, admin_authid);
	KickMatchingOnline(fill_steam, fill_ip, reason, length, unban_time, admin_name, admin_authid, 0);
	
	PrintBanInformation(client, target_name, target_authid, reason, length, unban_time, "", "", false, false);
	
	GetBanTime(length, unban_time, sizeof(unban_time) - 1);
	
	PrintActivity(admin_name, "^x04[AdvancedBans] $name^x01 :^x03  banned %s %s. Reason: %s. Ban Length: %s", is_ip ? "IP" : "SteamID", target_authid, reason, unban_time);
	
	Log("%s <%s> banned %s <%s> || Reason: ^"%s^" || Ban Length: %s", admin_name, admin_authid, target_name, target_authid, reason, unban_time);
	
	return PLUGIN_HANDLED;
}

public CmdUnban(client, level, cid)
{
	if( !cmd_access(client, level, cid, 2) ) return PLUGIN_HANDLED;
	
	static arg[35];
	read_argv(1, arg, sizeof(arg) - 1);
	if( contain(arg, ".") != -1 )
		NormalizeIp(arg, sizeof(arg) - 1);
	
	if( arg[0] == '#' )
	{
		new szBanId[12];
		copy(szBanId, charsmax(szBanId), arg[1]);
		new banid = str_to_num(szBanId);
		new id_pos = FindBanById(banid);
		if( id_pos == -1 )
		{
			console_print(client, "[AdvancedBans] No live ban with id #%d", banid);
			return PLUGIN_HANDLED;
		}
		
		static data[BannedData];
		ArrayGetArray(g_array, id_pos, data);
		
		static unban_name[32], identity[35], admin_name[64], authid[35];
		FillAdminIdentity(client, admin_name, sizeof(admin_name) - 1, authid, sizeof(authid) - 1);
		copy(unban_name, sizeof(unban_name) - 1, admin_name);
		GetBanIdentity(data[bd_steamid], data[bd_ip], identity, sizeof(identity) - 1);
		
		PrintActivity(unban_name, "^x04[AdvancedBans] $name^x01 :^x03  unbanned %s^x01 [%s] [Ban Reason: %s]", data[bd_name], identity, data[bd_reason]);
		Log("%s <%s> unbanned %s <%s> id #%d || Ban Reason: ^"%s^"", admin_name, authid, data[bd_name], identity, data[bd_id], data[bd_reason]);
		RecordHistory("UNBAN", data[bd_name], data[bd_steamid], data[bd_ip], 0, data[bd_reason], admin_name, authid);
		NotifyUnbannedOnline(data[bd_steamid], data[bd_ip]);
		BpAuditUnban(client, identity, data[bd_reason]);
		RemoveBan(id_pos, data[bd_steamid], data[bd_ip]);
		return PLUGIN_HANDLED;
	}
	
	#if MAX_BANS > 0
	static banned_authid[35];
	for( new i = 0; i < g_total_bans; i++ )
	{
		copy(banned_authid, sizeof(banned_authid) - 1, g_steamids[i]);
		
		if( equal(arg, banned_authid) )
		{
			static admin_name[64], authid[35];
			FillAdminIdentity(client, admin_name, sizeof(admin_name) - 1, authid, sizeof(authid) - 1);
			
			static name[32], reason[128];
			copy(name, sizeof(name) - 1, g_names[i]);
			copy(reason, sizeof(reason) - 1, g_reasons[i]);
			
			PrintActivity(admin_name, "^x04[AdvancedBans] $name^x01 :^x03  unbanned %s^x01 [%s] [Ban Reason: %s]", name, arg, reason);
			Log("%s <%s> unbanned %s <%s> || Ban Reason: ^"%s^"", admin_name, authid, name, arg, reason);
			RecordHistory("UNBAN", name, g_steamids[i], "", 0, reason, admin_name, authid);
			NotifyUnbannedOnline(g_steamids[i], "");
			BpAuditUnban(client, arg, reason);
			
			RemoveBan(i);
			
			return PLUGIN_HANDLED;
		}
	}
	#else
	if( TrieKeyExists(g_trie, arg) )
	{
		static array_pos;
		TrieGetCell(g_trie, arg, array_pos);
		
		static data[BannedData];
		ArrayGetArray(g_array, array_pos, data);
		
		static identity[35], admin_name[64], authid[35];
		FillAdminIdentity(client, admin_name, sizeof(admin_name) - 1, authid, sizeof(authid) - 1);
		GetBanIdentity(data[bd_steamid], data[bd_ip], identity, sizeof(identity) - 1);
		
		PrintActivity(admin_name, "^x04[AdvancedBans] $name^x01 :^x03  unbanned %s^x01 [%s] [Ban Reason: %s]", data[bd_name], identity, data[bd_reason]);
		
		Log("%s <%s> unbanned %s <%s> || Ban Reason: ^"%s^"", admin_name, authid, data[bd_name], identity, data[bd_reason]);
		
		RecordHistory("UNBAN", data[bd_name], data[bd_steamid], data[bd_ip], 0, data[bd_reason], admin_name, authid);
		NotifyUnbannedOnline(data[bd_steamid], data[bd_ip]);
		BpAuditUnban(client, identity, data[bd_reason]);
		RemoveBan(array_pos, data[bd_steamid], data[bd_ip]);
		
		return PLUGIN_HANDLED;
	}
	
	new nick_pos = FindBanByName(arg);
	if( nick_pos == -1 )
		nick_pos = FindBanPartial(arg);
	if( nick_pos == -2 )
	{
		console_print(client, "[AdvancedBans] Multiple bans match '%s'. Use SteamID, IP, or #id.", arg);
		return PLUGIN_HANDLED;
	}
	if( nick_pos != -1 )
	{
		static data[BannedData];
		ArrayGetArray(g_array, nick_pos, data);
		
		static identity[35];
		GetBanIdentity(data[bd_steamid], data[bd_ip], identity, sizeof(identity) - 1);
		
		static admin_name[64], authid[35];
		FillAdminIdentity(client, admin_name, sizeof(admin_name) - 1, authid, sizeof(authid) - 1);
		
		PrintActivity(admin_name, "^x04[AdvancedBans] $name^x01 :^x03  unbanned %s^x01 [%s] [Ban Reason: %s]", data[bd_name], identity, data[bd_reason]);
		
		Log("%s <%s> unbanned %s <%s> || Ban Reason: ^"%s^"", admin_name, authid, data[bd_name], identity, data[bd_reason]);
		
		RecordHistory("UNBAN", data[bd_name], data[bd_steamid], data[bd_ip], 0, data[bd_reason], admin_name, authid);
		NotifyUnbannedOnline(data[bd_steamid], data[bd_ip]);
		BpAuditUnban(client, identity, data[bd_reason]);
		RemoveBan(nick_pos, data[bd_steamid], data[bd_ip]);
		return PLUGIN_HANDLED;
	}
	#endif
	
	console_print(client, "[AdvancedBans] %L", client, "AB_NOT_IN_BAN_LIST", arg);
	
	return PLUGIN_HANDLED;
}

public CmdBanList(client, level, cid)
{
	if( !cmd_access(client, level, cid, 1) ) return PLUGIN_HANDLED;
	
	if( !g_total_bans )
	{
		console_print(client, "[AdvancedBans] %L", client, "AB_NO_BANS");
		return PLUGIN_HANDLED;
	}
	
	static start;
	
	if( read_argc() > 1 )
	{
		static arg[5];
		read_argv(1, arg, sizeof(arg) - 1);
		
		start = str_to_num(arg) - 1;
	}
	else
	{
		start = 0;
	}
	if( start < 0 ) start = 0;
	if( start >= g_total_bans ) start = g_total_bans - 1;
	
	new last = min(start + 10, g_total_bans);
	
	if( client == 0 )
	{
		server_cmd("echo ^"%L^"", client, "AB_BAN_LIST_NUM", start + 1, last);
	}
	else
	{
		client_cmd(client, "echo ^"%L^"", client, "AB_BAN_LIST_NUM", start + 1, last);
	}
	
	for( new i = start; i < last; i++ )
	{
		#if MAX_BANS <= 0
		static data[BannedData];
		ArrayGetArray(g_array, i, data);
		
		static identity[35];
		GetBanIdentity(data[bd_steamid], data[bd_ip], identity, sizeof(identity) - 1);
		if( client == 0 )
			server_print("Ban id: #%d", data[bd_id]);
		else
			console_print(client, "Ban id: #%d", data[bd_id]);
		PrintRemaining(client, data[bd_banlength], data[bd_unbantime]);
		PrintBanInformation(client, data[bd_name], identity, data[bd_reason], data[bd_banlength], data[bd_unbantime], data[bd_admin_name], data[bd_admin_steamid], true, false);
		#else
		static name[32], steamid[35], reason[128], banlength, unbantime[32], admin_name[32], admin_steamid[35];
		
		copy(name, sizeof(name) - 1, g_names[i]);
		copy(steamid, sizeof(steamid) - 1, g_steamids[i]);
		copy(reason, sizeof(reason) - 1, g_reasons[i]);
		banlength = g_banlengths[i];
		copy(unbantime, sizeof(unbantime) - 1, g_unbantimes[i]);
		copy(admin_name, sizeof(admin_name) - 1, g_admin_names[i]);
		copy(admin_steamid, sizeof(admin_steamid) - 1, g_admin_steamids[i]);
		
		PrintBanInformation(client, name, steamid, reason, banlength, unbantime, admin_name, admin_steamid, true, false);
		#endif
	}
	
	if( ++last < g_total_bans )
	{
		if( client == 0 )
		{
			server_cmd("echo ^"%L^"", client, "AB_BAN_LIST_NEXT", last);
		}
		else
		{
			client_cmd(client, "echo ^"%L^"", client, "AB_BAN_LIST_NEXT", last);
		}
	}
	
	return PLUGIN_HANDLED;
}

public CmdAddBanLimit()
{
	if( read_argc() != 3 )
	{
		log_amx("amx_addbanlimit was used with incorrect parameters!");
		log_amx("Usage: amx_addbanlimit <flags> <time in minutes>");
		return PLUGIN_HANDLED;
	}
	
	static arg[16];
	
	read_argv(1, arg, sizeof(arg) - 1);
	new flags = read_flags(arg);
	
	read_argv(2, arg, sizeof(arg) - 1);
	new minutes = str_to_num(arg);
	
	#if !defined MAX_BANLIMITS
	ArrayPushCell(g_maxban_flags, flags);
	ArrayPushCell(g_maxban_times, minutes);
	#else
	if( g_total_maxban_times >= MAX_BANLIMITS )
	{
		static notified;
		if( !notified )
		{
			log_amx("The amx_addbanlimit has reached its maximum!");
			notified = 1;
		}
		return PLUGIN_HANDLED;
	}
	
	g_maxban_flags[g_total_maxban_times] = flags;
	g_maxban_times[g_total_maxban_times] = minutes;
	#endif
	g_total_maxban_times++;
	
	return PLUGIN_HANDLED;
}

public FwdThink(entity)
{
	if( entity != g_unban_entity ) return;
	
	if( g_total_bans > 0 && !g_loading_bans )
	{
		for( new i = 0; i < g_total_bans; i++ )
		{
			static data[BannedData];
			ArrayGetArray(g_array, i, data);
			
			if( !BanHasExpired(data[bd_banlength], data[bd_unbantime]) ) continue;
			
			Log("Ban time is up for: %s [%s]", data[bd_name], data[bd_steamid][0] ? data[bd_steamid] : data[bd_ip]);
			Print("^x04[AdvancedBans]^x03 %s^x01[^x04%s^x01]^x03 ban time is up!^x01 [Ban Reason: %s]", data[bd_name], data[bd_steamid][0] ? data[bd_steamid] : data[bd_ip], data[bd_reason]);
			RecordHistory("EXPIRE", data[bd_name], data[bd_steamid], data[bd_ip], data[bd_banlength], data[bd_reason], "SERVER", "SERVER");
			RemoveBan(i, data[bd_steamid], data[bd_ip]);
			i--;
		}
	}
	
	entity_set_float(g_unban_entity, EV_FL_nextthink, get_gametime() + get_pcvar_float(ab_unbancheck));
}

public TaskDisconnectPlayer(taskid)
{
	new client = taskid - TASK_KICK;
	if( client < 1 || client > g_max_clients ) return;
	if( !SameSession(client, g_kick_userid[client], g_kick_auth[client]) ) return;
	
	static authid[35], ip[35], reason[128];
	get_user_authid(client, authid, sizeof(authid) - 1);
	
	get_user_ip(client, ip, sizeof(ip) - 1, 1);
	NormalizeIp(ip, sizeof(ip) - 1);
	
	static array_pos;
	new bool:hit;
	if( IsUsableAuthid(authid) && TrieGetCell(g_trie, authid, array_pos) )
		hit = true;
	else if( ip[0] && TrieGetCell(g_trie, ip, array_pos) )
		hit = true;
	
	if( !hit ) return;
	
	static data[BannedData];
	ArrayGetArray(g_array, array_pos, data);
	if( BanHasExpired(data[bd_banlength], data[bd_unbantime]) )
	{
		RemoveBan(array_pos, data[bd_steamid], data[bd_ip]);
		return;
	}
	
	copy(reason, sizeof(reason) - 1, "You are banned from this server.");
	if( data[bd_reason][0] )
		formatex(reason, sizeof(reason) - 1, "Banned: %s", data[bd_reason]);
	
	SanitizeKickReason(reason, sizeof(reason) - 1);
	server_cmd("kick #%i ^"%s^"", get_user_userid(client), reason);
}

AddBan(const target_name[], const target_steamid[], const target_ip[], const reason[], const length, const unban_time[], const admin_name[], const admin_steamid[])
{
	#if MAX_BANS > 0
	if( g_total_bans == MAX_BANS )
	{
		log_amx("Ban list is full! (%i)", g_total_bans);
		return;
	}
	#endif
	
	#if defined USING_SQL
	static target_name2[64], reason2[256], admin_name2[64], steamid2[70], ip2[70], admin_steamid2[70], unban_time2[64];
	MakeStringSQLSafe(target_name, target_name2, sizeof(target_name2) - 1);
	MakeStringSQLSafe(reason, reason2, sizeof(reason2) - 1);
	MakeStringSQLSafe(admin_name, admin_name2, sizeof(admin_name2) - 1);
	MakeStringSQLSafe(target_steamid, steamid2, sizeof(steamid2) - 1);
	MakeStringSQLSafe(target_ip, ip2, sizeof(ip2) - 1);
	MakeStringSQLSafe(admin_steamid, admin_steamid2, sizeof(admin_steamid2) - 1);
	MakeStringSQLSafe(unban_time, unban_time2, sizeof(unban_time2) - 1);
	
	static query[1800];
	static packed[72];
	formatex(query, sizeof(query) - 1,\
		"INSERT INTO %s (%s, %s, %s, %s, %s, %s, %s, %s) VALUES ('%s', '%s', '%s', %i, '%s', '%s', '%s', '%s');",\
		TABLE_NAME, KEY_NAME, KEY_STEAMID, KEY_IP, KEY_BANLENGTH, KEY_UNBANTIME, KEY_REASON, KEY_ADMIN_NAME, KEY_ADMIN_STEAMID,\
		target_name2, steamid2, ip2, length, unban_time2, reason2, admin_name2, admin_steamid2
		);
	if( steamid2[0] && ip2[0] )
	{
		formatex(query, sizeof(query) - 1,
			"DELETE FROM %s WHERE %s = '%s' OR %s = '%s'; INSERT INTO %s (%s, %s, %s, %s, %s, %s, %s, %s) VALUES ('%s', '%s', '%s', %i, '%s', '%s', '%s', '%s');",
			TABLE_NAME, KEY_STEAMID, steamid2, KEY_IP, ip2,
			TABLE_NAME, KEY_NAME, KEY_STEAMID, KEY_IP, KEY_BANLENGTH, KEY_UNBANTIME, KEY_REASON, KEY_ADMIN_NAME, KEY_ADMIN_STEAMID,
			target_name2, steamid2, ip2, length, unban_time2, reason2, admin_name2, admin_steamid2);
	}
	else if( steamid2[0] )
	{
		formatex(query, sizeof(query) - 1,
			"DELETE FROM %s WHERE %s = '%s'; INSERT INTO %s (%s, %s, %s, %s, %s, %s, %s, %s) VALUES ('%s', '%s', '%s', %i, '%s', '%s', '%s', '%s');",
			TABLE_NAME, KEY_STEAMID, steamid2,
			TABLE_NAME, KEY_NAME, KEY_STEAMID, KEY_IP, KEY_BANLENGTH, KEY_UNBANTIME, KEY_REASON, KEY_ADMIN_NAME, KEY_ADMIN_STEAMID,
			target_name2, steamid2, ip2, length, unban_time2, reason2, admin_name2, admin_steamid2);
	}
	else if( ip2[0] )
	{
		formatex(query, sizeof(query) - 1,
			"DELETE FROM %s WHERE %s = '%s'; INSERT INTO %s (%s, %s, %s, %s, %s, %s, %s, %s) VALUES ('%s', '%s', '%s', %i, '%s', '%s', '%s', '%s');",
			TABLE_NAME, KEY_IP, ip2,
			TABLE_NAME, KEY_NAME, KEY_STEAMID, KEY_IP, KEY_BANLENGTH, KEY_UNBANTIME, KEY_REASON, KEY_ADMIN_NAME, KEY_ADMIN_STEAMID,
			target_name2, steamid2, ip2, length, unban_time2, reason2, admin_name2, admin_steamid2);
	}
	
	// packed "steamid|ip" lets QueryAddBan queue op=BAN into ab_pending_push on outage
	formatex(packed, sizeof(packed) - 1, "%s|%s", target_steamid, target_ip);
	PG_ThreadQuery("QueryAddBan", query, packed, strlen(packed) + 1);
	#else
	new f = fopen(g_ban_file, "a+");
	
	fprintf(f, "^"%s^" ^"%s^" %i ^"%s^" ^"%s^" ^"%s^" ^"%s^"^n",\
		target_steamid,\
		target_name,\
		length,\
		unban_time,\
		reason,\
		admin_name,\
		admin_steamid
		);
	
	fclose(f);
	#endif
	
	#if MAX_BANS <= 0
	static data[BannedData];
	data[bd_id] = ++g_next_banid;
	copy(data[bd_name], sizeof(data[bd_name]) - 1, target_name);
	copy(data[bd_steamid], sizeof(data[bd_steamid]) - 1, target_steamid);
	copy(data[bd_ip], sizeof(data[bd_ip]) - 1, target_ip);
	data[bd_banlength] = length;
	copy(data[bd_unbantime], sizeof(data[bd_unbantime]) - 1, unban_time);
	copy(data[bd_reason], sizeof(data[bd_reason]) - 1, reason);
	copy(data[bd_admin_name], sizeof(data[bd_admin_name]) - 1, admin_name);
	copy(data[bd_admin_steamid], sizeof(data[bd_admin_steamid]) - 1, admin_steamid);
	
	IndexBan(g_total_bans, target_steamid, target_ip);
	ArrayPushArray(g_array, data);
	#else
	copy(g_names[g_total_bans], sizeof(g_names[]) - 1, target_name);
	copy(g_steamids[g_total_bans], sizeof(g_steamids[]) - 1, target_steamid);
	g_banlengths[g_total_bans] = length;
	copy(g_unbantimes[g_total_bans], sizeof(g_unbantimes[]) - 1, unban_time);
	copy(g_reasons[g_total_bans], sizeof(g_reasons[]) - 1, reason);
	copy(g_admin_names[g_total_bans], sizeof(g_admin_names[]) - 1, admin_name);
	copy(g_admin_steamids[g_total_bans], sizeof(g_admin_steamids[]) - 1, admin_steamid);
	#endif
	
	g_total_bans++;
	
	#if MAX_BANS > 0
	if( g_total_bans == MAX_BANS )
	{
		log_amx("Ban list is full! (%i)", g_total_bans);
	}
	#endif
	
	#if defined USING_SQL
	new cancelled = FilterPendingFile(target_steamid, target_ip);
	if( cancelled > 0 )
		log_amx("[AdvancedBans] Hybrid: re-ban cancelled %d queued offline unban(s)", cancelled);
	SaveLocalMirror();
	// synchronous local SQLite mirror write (src=1 until PG confirms); never blocks on PG
	SQLiteMirrorUpsert(target_name, target_steamid, target_ip, length, unban_time, reason, admin_name, admin_steamid, 1);
	#endif
}

#if defined USING_SQL
public QueryAddBan(failstate, query, error[], errcode, data[], datasize, Float:queuetime)
{
	if( failstate || errcode )
	{
		log_amx("[AdvancedBans] Add query failed (%d/%d): %s", failstate, errcode, error);
		// outage path: persist the ban into ab_pending_push (op=BAN) so it
		// converges upstream on reconnect. Identity comes from the packed
		// "steamid|ip" data[]; the full row is re-read from the SQLite mirror
		// (written synchronously in AddBan), never blocking on PG.
		if( datasize > 0 )
			SQLiteQueueBanFromMirror(data);
		return;
	}
	// PG confirmed the row: mark the mirror copy converged (src=0).
	if( datasize > 0 )
		SQLiteMarkConverged(data);
}

public QueryDeleteBan(failstate, query, error[], errcode, data[], datasize, Float:queuetime)
{
	if( datasize > 0 && data[0] == 1 )
	{
		if( failstate || errcode )
		{
			g_flushHadFail = true;
			log_amx("[AdvancedBans] Flush delete failed (%d/%d): kept for next pass", failstate, errcode);
		}
		g_iFlushConfirmed++;
		if( g_iFlushConfirmed >= g_iFlushFired && g_iFlushFired > 0 )
		{
			new done = g_flushCount;
			if( !g_flushHadFail )
			{
				if( CompactFlushFile() < 0 )
					log_amx("[AdvancedBans] Hybrid: compact aborted, file kept as-is for next pass");
			}
			else
				log_amx("[AdvancedBans] Hybrid: flush had failures, %d key(s) kept for retry", done);
			g_iFlushFired = 0;
			g_iFlushConfirmed = 0;
			g_flushCount = 0;
			g_bFlushActive = false;
			SaveLocalMirror();
			EnforceConnectedBans();
			log_amx("[AdvancedBans] Hybrid: flush pass complete (%d delete(s) confirmed)", done);
		}
		return;
	}
	if( failstate || errcode )
	{
		log_amx("[AdvancedBans] Delete query failed (%d/%d): %s", failstate, errcode, error);
		// outage path (untagged deletes only; tagged flush rows return above):
		// queue identity-only op=UNBAN into ab_pending_push for reconnect converge.
		if( datasize > 0 )
			SQLiteQueueUnbanFromPacked(data);
	}
}

public QueryLoadBans(failstate, query, error[], errcode, data[], datasize, Float:queuetime)
{
	if( failstate || errcode )
	{
		g_bPGOnline = false;
		g_iSyncFails++;
		if( g_total_bans > 0 )
		{
			log_amx("[AdvancedBans] Load query failed (%d/%d): %s - keeping previous %d bans (local enforcement continues)", failstate, errcode, error, g_total_bans);
		}
		else if( get_pcvar_num(ab_local_fallback) )
		{
			log_amx("[AdvancedBans] Load query failed (%d/%d): %s - PG unreachable, loading local fallback file", failstate, errcode, error);
			LoadLocalFile();
		}
		else
		{
			log_amx("[AdvancedBans] Load query failed (%d/%d): %s - keeping previous ban list", failstate, errcode, error);
		}
		g_loading_bans = false; g_iLoadStart = 0;
		return;
	}
	
	#if MAX_BANS <= 0
	new Trie:new_trie = TrieCreate();
	new Array:new_array = ArrayCreate(BannedData);
	new new_total;
	new new_next_id = g_next_banid;
	static row[BannedData];
	
	if( PG_NumResults(query) )
	{
		while( PG_MoreResults(query) )
		{
			PG_ReadString(query, 0, row[bd_name], sizeof(row[bd_name]) - 1);
			PG_ReadString(query, 1, row[bd_steamid], sizeof(row[bd_steamid]) - 1);
			PG_ReadString(query, 2, row[bd_ip], sizeof(row[bd_ip]) - 1);
			row[bd_banlength] = PG_ReadInt(query, 3);
			PG_ReadString(query, 4, row[bd_unbantime], sizeof(row[bd_unbantime]) - 1);
			PG_ReadString(query, 5, row[bd_reason], sizeof(row[bd_reason]) - 1);
			PG_ReadString(query, 6, row[bd_admin_name], sizeof(row[bd_admin_name]) - 1);
			PG_ReadString(query, 7, row[bd_admin_steamid], sizeof(row[bd_admin_steamid]) - 1);
			row[bd_id] = PG_ReadInt(query, 8);
			if( row[bd_id] > new_next_id ) new_next_id = row[bd_id];
			NormalizeIp(row[bd_ip], sizeof(row[bd_ip]) - 1);
			
			if( BanHasExpired(row[bd_banlength], row[bd_unbantime]) )
			{
				RecordHistory("EXPIRE", row[bd_name], row[bd_steamid], row[bd_ip], row[bd_banlength], row[bd_reason], "SERVER", "SERVER");
				static delq[128];
				formatex(delq, sizeof(delq) - 1, "DELETE FROM %s WHERE id = %d;", TABLE_NAME, row[bd_id]);
				PG_ThreadQuery("QueryDeleteBan", delq);
				PG_NextRow(query);
				continue;
			}
			
			ArrayPushArray(new_array, row);
			if( row[bd_steamid][0] )
				TrieSetCell(new_trie, row[bd_steamid], new_total);
			if( row[bd_ip][0] )
				TrieSetCell(new_trie, row[bd_ip], new_total);
			new_total++;
			PG_NextRow(query);
		}
	}
	
	// Hybrid: carry bans created locally while PG was down into the fresh PG set,
	// so the hourly all-servers pull never wipes them; each carried row is also
	// pushed upstream idempotently for the other servers.
	new carried = 0;
	if( g_total_bans > 0 )
	{
		static old[BannedData];
		for( new oi = 0; oi < g_total_bans; oi++ )
		{
			ArrayGetArray(g_array, oi, old);
			new bool:known = false;
			if( old[bd_steamid][0] && TrieKeyExists(new_trie, old[bd_steamid]) ) known = true;
			else if( old[bd_ip][0] && TrieKeyExists(new_trie, old[bd_ip]) ) known = true;
			if( known ) continue;
			if( BanHasExpired(old[bd_banlength], old[bd_unbantime]) ) continue;
			ArrayPushArray(new_array, old);
			if( old[bd_steamid][0] )
				TrieSetCell(new_trie, old[bd_steamid], new_total);
			if( old[bd_ip][0] )
				TrieSetCell(new_trie, old[bd_ip], new_total);
			new_total++;
			if( old[bd_id] > new_next_id ) new_next_id = old[bd_id];
			HybridPushRow(old[bd_name], old[bd_steamid], old[bd_ip], old[bd_banlength], old[bd_unbantime], old[bd_reason], old[bd_admin_name], old[bd_admin_steamid]);
			carried++;
		}
		if( carried > 0 )
			log_amx("[AdvancedBans] Hybrid: carried %d local-only ban(s) into PG set + pushed upstream", carried);
	}
	
	new Trie:old_trie = g_trie;
	new Array:old_array = g_array;
	g_trie = new_trie;
	g_array = new_array;
	g_total_bans = new_total;
	g_next_banid = new_next_id;
	if( old_trie ) TrieDestroy(old_trie);
	if( old_array ) ArrayDestroy(old_array);
	#else
	static old_names[MAX_BANS][32], old_steam[MAX_BANS][35];
	static old_len[MAX_BANS], old_unban[MAX_BANS][32], old_reas[MAX_BANS][128];
	static old_an[MAX_BANS][64], old_as[MAX_BANS][35];
	new old_total = g_total_bans;
	if( old_total > MAX_BANS ) old_total = MAX_BANS;
	for( new oi = 0; oi < old_total; oi++ )
	{
		copy(old_names[oi], 31, g_names[oi]);
		copy(old_steam[oi], 34, g_steamids[oi]);
		old_len[oi] = g_banlengths[oi];
		copy(old_unban[oi], 31, g_unbantimes[oi]);
		copy(old_reas[oi], 127, g_reasons[oi]);
		copy(old_an[oi], 63, g_admin_names[oi]);
		copy(old_as[oi], 34, g_admin_steamids[oi]);
	}
	g_total_bans = 0;
	if( PG_NumResults(query) )
	{
		while( PG_MoreResults(query) && g_total_bans < MAX_BANS )
		{
			PG_ReadString(query, 0, g_names[g_total_bans], sizeof(g_names[]) - 1);
			PG_ReadString(query, 1, g_steamids[g_total_bans], sizeof(g_steamids[]) - 1);
			g_banlengths[g_total_bans] = PG_ReadInt(query, 2);
			PG_ReadString(query, 3, g_unbantimes[g_total_bans], sizeof(g_unbantimes[]) - 1);
			PG_ReadString(query, 4, g_reasons[g_total_bans], sizeof(g_reasons[]) - 1);
			PG_ReadString(query, 5, g_admin_names[g_total_bans], sizeof(g_admin_names[]) - 1);
			PG_ReadString(query, 6, g_admin_steamids[g_total_bans], sizeof(g_admin_steamids[]) - 1);
			g_total_bans++;
			PG_NextRow(query);
		}
	}
	// Hybrid carry-up for fixed-size configs: same rule as the dynamic branch.
	new carried = 0;
	for( new ci = 0; ci < old_total; ci++ )
	{
		if( !old_steam[ci][0] ) continue;
		if( BanHasExpired(old_len[ci], old_unban[ci]) ) continue;
		new bool:known = false;
		for( new ni = 0; ni < g_total_bans; ni++ )
		{
			if( equal(old_steam[ci], g_steamids[ni]) ) { known = true; break; }
		}
		if( known ) continue;
		HybridPushRow(old_names[ci], old_steam[ci], "", old_len[ci], old_unban[ci], old_reas[ci], old_an[ci], old_as[ci]);
		if( g_total_bans < MAX_BANS )
		{
			copy(g_names[g_total_bans], 31, old_names[ci]);
			copy(g_steamids[g_total_bans], 34, old_steam[ci]);
			g_banlengths[g_total_bans] = old_len[ci];
			copy(g_unbantimes[g_total_bans], 31, old_unban[ci]);
			copy(g_reasons[g_total_bans], 127, old_reas[ci]);
			copy(g_admin_names[g_total_bans], 63, old_an[ci]);
			copy(g_admin_steamids[g_total_bans], 34, old_as[ci]);
			g_total_bans++;
			carried++;
		}
		else if( carried == 0 )
			log_amx("[AdvancedBans] Hybrid: fixed list full, local-only bans pushed upstream only");
	}
	if( carried > 0 )
		log_amx("[AdvancedBans] Hybrid: carried %d local-only ban(s) into PG set + pushed upstream", carried);
	#endif
	
	g_bPGOnline = true;
	g_bLocalFallback = false;
	g_iLastSyncOk = get_systime();
	g_iSyncFails = 0;
	g_loading_bans = false; g_iLoadStart = 0;
	// bidirectional reconnect converge: push queued SQLite ops upstream, then
	// rebuild the mirror (PG row wins on match). File flush flow untouched below.
	SQLiteConvergeAfterPull();
	FlushPendingUnbans();
	SaveLocalMirror();
	EnforceConnectedBans();
	log_amx("[AdvancedBans] PG sync OK: %d bans (local mirror updated)", g_total_bans);
}
#endif

#if MAX_BANS > 0
RemoveBan(remove)
{
	#if defined USING_SQL
	static query[128];
	formatex(query, sizeof(query) - 1,\
		"DELETE FROM %s WHERE %s = '%s';",\
		TABLE_NAME, KEY_STEAMID, g_steamids[remove]
		);
	
	PG_ThreadQuery("QueryDeleteBan", query);
	#endif
	
	for( new i = remove; i < g_total_bans; i++ )
	{
		if( (i + 1) == g_total_bans )
		{
			copy(g_names[i], sizeof(g_names[]) - 1, "");
			copy(g_steamids[i], sizeof(g_steamids[]) - 1, "");
			g_banlengths[i] = 0;
			copy(g_unbantimes[i], sizeof(g_unbantimes[]) - 1, "");
			copy(g_reasons[i], sizeof(g_reasons[]) - 1, "");
			copy(g_admin_names[i], sizeof(g_admin_names[]) - 1, "");
			copy(g_admin_steamids[i], sizeof(g_admin_steamids[]) - 1, "");
		}
		else
		{
			copy(g_names[i], sizeof(g_names[]) - 1, g_names[i + 1]);
			copy(g_steamids[i], sizeof(g_steamids[]) - 1, g_steamids[i + 1]);
			g_banlengths[i] = g_banlengths[i + 1];
			copy(g_unbantimes[i], sizeof(g_unbantimes[]) - 1, g_unbantimes[i + 1]);
			copy(g_reasons[i], sizeof(g_reasons[]) - 1, g_reasons[i + 1]);
			copy(g_admin_names[i], sizeof(g_admin_names[]) - 1, g_admin_names[i + 1]);
			copy(g_admin_steamids[i], sizeof(g_admin_steamids[]) - 1, g_admin_steamids[i + 1]);
		}
	}
	
	g_total_bans--;
	
	#if !defined USING_SQL
	new f = fopen(g_ban_file, "wt");
	
	static name[32], steamid[35], banlength, unbantime[32], reason[128], admin_name[32], admin_steamid[35];
	for( new i = 0; i < g_total_bans; i++ )
	{
		copy(name, sizeof(name) - 1, g_names[i]);
		copy(steamid, sizeof(steamid) - 1, g_steamids[i]);
		banlength = g_banlengths[i];
		copy(unbantime, sizeof(unbantime) - 1, g_unbantimes[i]);
		copy(reason, sizeof(reason) - 1, g_reasons[i]);
		copy(admin_name, sizeof(admin_name) - 1, g_admin_names[i]);
		copy(admin_steamid, sizeof(admin_steamid) - 1, g_admin_steamids[i]);
		
		fprintf(f, "^"%s^" ^"%s^" %i ^"%s^" ^"%s^" ^"%s^" ^"%s^"^n",\
			steamid,\
			name,\
			banlength,\
			unbantime,\
			reason,\
			admin_name,\
			admin_steamid
			);
	}
	
	fclose(f);
	#endif
}
#else
RemoveBan(pos, const authid[], const ip[] = "")
{
	if( authid[0] )
	{
		TrieDeleteKey(g_trie, authid);
	}
	if( ip[0] )
	{
		TrieDeleteKey(g_trie, ip);
	}
	ArrayDeleteItem(g_array, pos);
	
	g_total_bans--;
	
	#if defined USING_SQL
	static query[256], steamid2[70], ip2[70];
	static packed[72];
	MakeStringSQLSafe(authid, steamid2, sizeof(steamid2) - 1);
	MakeStringSQLSafe(ip, ip2, sizeof(ip2) - 1);
	
	if( steamid2[0] && ip2[0] )
	{
		formatex(query, sizeof(query) - 1,\
			"DELETE FROM %s WHERE %s = '%s' OR %s = '%s';",\
			TABLE_NAME, KEY_STEAMID, steamid2, KEY_IP, ip2
			);
	}
	else if( steamid2[0] )
	{
		formatex(query, sizeof(query) - 1,\
			"DELETE FROM %s WHERE %s = '%s';",\
			TABLE_NAME, KEY_STEAMID, steamid2
			);
	}
	else
	{
		formatex(query, sizeof(query) - 1,\
			"DELETE FROM %s WHERE %s = '%s';",\
			TABLE_NAME, KEY_IP, ip2
			);
	}
	
	// packed "steamid|ip" lets QueryDeleteBan queue op=UNBAN into ab_pending_push on outage
	formatex(packed, sizeof(packed) - 1, "%s|%s", authid, ip);
	PG_ThreadQuery("QueryDeleteBan", query, packed, strlen(packed) + 1);

	RebuildBanIndex();
	SaveLocalMirror();
	// synchronous local SQLite mirror delete alongside memory+file
	SQLiteMirrorDelete(authid, ip);
	if( !g_bFlushing )
		QueuePendingUnban(authid, ip);
	#else
	new f = fopen(g_ban_file, "wt");
	
	new data[BannedData];
	for( new i = 0; i < g_total_bans; i++ )
	{
		ArrayGetArray(g_array, i, data);
		TrieSetCell(g_trie, data[bd_steamid], i);
		
		fprintf(f, "^"%s^" ^"%s^" %i ^"%s^" ^"%s^" ^"%s^" ^"%s^"^n",\
			data[bd_steamid],\
			data[bd_name],\
			data[bd_banlength],\
			data[bd_unbantime],\
			data[bd_reason],\
			data[bd_admin_name],\
			data[bd_admin_steamid]
			);
	}
	
	fclose(f);
	#endif
}
#endif

#if defined KEEP_DEFAULT_BANS
LoadOldBans(filename[])
{
	if( file_exists(filename) )
	{
		new f = fopen(filename, "rt");
		
		static data[96];
		static command[10], minutes[10], steamid[35], length, unban_time[32];
		
		while( !feof(f) )
		{
			fgets(f, data, sizeof(data) - 1);
			if( !data[0] ) continue;
			
			parse(data, command, sizeof(command) - 1, minutes, sizeof(minutes) - 1, steamid, sizeof(steamid) - 1);
			if( filename[0] == 'b' && !equali(command, "banid") || filename[0] == 'l' && !equali(command, "addip") ) continue;
			
			length = str_to_num(minutes);
			GenerateUnbanTime(length, unban_time, sizeof(unban_time) - 1);
			
			AddBan("", steamid, "", length, unban_time, "", "");
		}
		
		fclose(f);
		
		static filename2[32];
		
		// copy current
		copy(filename2, sizeof(filename2) - 1, filename);
		
		// cut off at the "."
		// banned.cfg = banned
		// listip.cfg = listip
		filename2[containi(filename2, ".")] = 0;
		
		// add 2.cfg
		// banned = banned2.cfg
		// listip = listip2.cfg
		add(filename2, sizeof(filename2) - 1, "2.cfg");
		
		// rename file so that it isnt loaded again
		while( !rename_file(filename, filename2, 1) ) { }
	}
}
#endif

public LoadBans()
{
	if( g_loading_bans )
	{
		log_amx("[AdvancedBans] Load already in progress, skip duplicate");
		return;
	}
	
	#if !defined USING_SQL
	if( g_total_bans )
	{
		#if MAX_BANS <= 0
		TrieClear(g_trie);
		ArrayClear(g_array);
		#endif
		
		g_total_bans = 0;
	}
	#endif
	
	#if defined USING_SQL
	static query[128];
	formatex(query, sizeof(query) - 1,\
		"SELECT %s, %s, %s, %s, %s, %s, %s, %s, id FROM %s;",\
		KEY_NAME, KEY_STEAMID, KEY_IP, KEY_BANLENGTH, KEY_UNBANTIME, KEY_REASON, KEY_ADMIN_NAME, KEY_ADMIN_STEAMID, TABLE_NAME
		);
	
	g_loading_bans = true; g_iLoadStart = get_systime();
	PG_ThreadQuery("QueryLoadBans", query);
	#else
	if( file_exists(g_ban_file) )
	{
		new f = fopen(g_ban_file, "rt");
		
		static filedata[512], length[10];
		
		#if MAX_BANS <= 0
		static data[BannedData];
		while( !feof(f) )
		#else
		while( !feof(f) && g_total_bans < MAX_BANS )
		#endif
		{
			fgets(f, filedata, sizeof(filedata) - 1);
			
			if( !filedata[0] ) continue;
			
			#if MAX_BANS <= 0
			parse(filedata,\
				data[bd_steamid], sizeof(data[bd_steamid]) - 1,\
				data[bd_name], sizeof(data[bd_name]) - 1,\
				length, sizeof(length) - 1,\
				data[bd_unbantime], sizeof(data[bd_unbantime]) - 1,\
				data[bd_reason], sizeof(data[bd_reason]) - 1,\
				data[bd_admin_name], sizeof(data[bd_admin_name]) - 1,\
				data[bd_admin_steamid], sizeof(data[bd_admin_steamid]) - 1
				);
			
			data[bd_banlength] = str_to_num(length);
			
			ArrayPushArray(g_array, data);
			TrieSetCell(g_trie, data[bd_steamid], g_total_bans);
			#else
			static steamid[35], name[32], unbantime[32], reason[128], admin_name[32], admin_steamid[35];
			
			parse(filedata,\
				steamid, sizeof(steamid) - 1,\
				name, sizeof(name) - 1,\
				length, sizeof(length) - 1,\
				unbantime, sizeof(unbantime) - 1,\
				reason, sizeof(reason) - 1,\
				admin_name, sizeof(admin_name) - 1,\
				admin_steamid, sizeof(admin_steamid) - 1
				);
			
			copy(g_names[g_total_bans], sizeof(g_names[]) - 1, name);
			copy(g_steamids[g_total_bans], sizeof(g_steamids[]) - 1, steamid);
			g_banlengths[g_total_bans] = str_to_num(length);
			copy(g_unbantimes[g_total_bans], sizeof(g_unbantimes[]) - 1, unbantime);
			copy(g_reasons[g_total_bans], sizeof(g_reasons[]) - 1, reason);
			copy(g_admin_names[g_total_bans], sizeof(g_admin_names[]) - 1, admin_name);
			copy(g_admin_steamids[g_total_bans], sizeof(g_admin_steamids[]) - 1, admin_steamid);
			#endif
			
			g_total_bans++;
		}
		
		fclose(f);
	}
	#endif
	
	// load these after, so when they are added to the file with AddBan(), they aren't loaded again from above.
	
	#if defined KEEP_DEFAULT_BANS
	LoadOldBans("banned.cfg");
	LoadOldBans("listip.cfg");
	#endif
}

#if defined USING_SQL
MakeStringSQLSafe(const input[], output[], len)
{
	copy(output, len, input);
	replace_all(output, len, "'", "''");
}

IndexBan(pos, const steamid[], const ip[])
{
	if( steamid[0] )
	{
		TrieSetCell(g_trie, steamid, pos);
	}
	if( ip[0] )
	{
		TrieSetCell(g_trie, ip, pos);
	}
}

RebuildBanIndex()
{
	TrieClear(g_trie);
	
	new data[BannedData];
	for( new i = 0; i < g_total_bans; i++ )
	{
		ArrayGetArray(g_array, i, data);
		IndexBan(i, data[bd_steamid], data[bd_ip]);
	}
}

bool:IsUsableAuthid(const authid[])
{
	if( !authid[0] ) return false;
	if( equal(authid, "STEAM_ID_PENDING") ) return false;
	if( equal(authid, "STEAM_ID_LAN") ) return false;
	if( equali(authid, "VALVE_ID_LAN") ) return false;
	if( equal(authid, "UNKNOWN") ) return false;
	if( equal(authid, "HLTV") ) return false;
	if( equal(authid, "4294967295") ) return false;
	return bool:IsValidAuthid(authid);
}

NormalizeIp(ip[], len)
{
	new pos = contain(ip, ":");
	if( pos > 0 ) ip[pos] = 0;
	if( len ) { }
}

SanitizeKickReason(reason[], len)
{
	replace_all(reason, len, "^"", "'");
	replace_all(reason, len, ";", " ");
	replace_all(reason, len, "^n", " ");
}

SanitizeEchoField(dest[], dest_len, const src[])
{
	copy(dest, dest_len, src);
	SanitizeKickReason(dest, dest_len);
}

bool:SameSession(client, userid, const auth[])
{
	if( client < 1 || !is_user_connected(client) ) return false;
	if( get_user_userid(client) != userid ) return false;
	if( auth[0] )
	{
		static now[35];
		get_user_authid(client, now, sizeof(now) - 1);
		if( !equal(now, auth) ) return false;
	}
	return true;
}

bool:IsAlreadyBanned(const steamid[], const ip[])
{
	if( steamid[0] && TrieKeyExists(g_trie, steamid) ) return true;
	if( ip[0] && TrieKeyExists(g_trie, ip) ) return true;
	return false;
}

ReplaceExistingBan(const steamid[], const ip[])
{
	static array_pos, data[BannedData];
	if( steamid[0] && TrieGetCell(g_trie, steamid, array_pos) )
	{
		ArrayGetArray(g_array, array_pos, data);
		RemoveBan(array_pos, data[bd_steamid], data[bd_ip]);
		return;
	}
	if( ip[0] && TrieGetCell(g_trie, ip, array_pos) )
	{
		ArrayGetArray(g_array, array_pos, data);
		RemoveBan(array_pos, data[bd_steamid], data[bd_ip]);
	}
}

bool:LooksLikeMinutes(const arg[])
{
	if( !arg[0] || arg[0] == '#' ) return false;
	if( contain(arg, ".") != -1 ) return false;
	if( contain(arg, ":") != -1 ) return false;
	for( new i = 0; arg[i]; i++ )
	{
		if( !isdigit(arg[i]) ) return false;
	}
	return true;
}

ReadReasonFrom(start_arg, output[], len)
{
	output[0] = 0;
	new argc = read_argc();
	if( start_arg >= argc ) return;
	
	static tmp[128];
	for( new i = start_arg; i < argc; i++ )
	{
		read_argv(i, tmp, sizeof(tmp) - 1);
		if( output[0] )
			format(output, len, "%s %s", output, tmp);
		else
			copy(output, len, tmp);
	}
	trim(output);
}

Dbg(const fmt[], any:...)
{
	if( !get_pcvar_num(ab_debug) ) return;
	static msg[192];
	vformat(msg, sizeof(msg) - 1, fmt, 2);
	log_amx("[AB DEBUG] %s", msg);
}

RecordHistory(const action[], const name[], const steamid[], const ip[], minutes, const reason[], const admin_name[], const admin_steamid[])
{
	static n[64], s[70], i[70], r[256], an[128], as[70];
	MakeStringSQLSafe(name, n, sizeof(n) - 1);
	MakeStringSQLSafe(steamid, s, sizeof(s) - 1);
	MakeStringSQLSafe(ip, i, sizeof(i) - 1);
	MakeStringSQLSafe(reason, r, sizeof(r) - 1);
	MakeStringSQLSafe(admin_name, an, sizeof(an) - 1);
	MakeStringSQLSafe(admin_steamid, as, sizeof(as) - 1);
	
	static query[768];
	formatex(query, sizeof(query) - 1,
		"INSERT INTO %s (action,name,steamid,ip,minutes,reason,admin_name,admin_steamid,created) VALUES ('%s','%s','%s','%s',%i,'%s','%s','%s',%d);",
		TABLE_HISTORY, action, n, s, i, minutes, r, an, as, get_systime());
	PG_ThreadQuery("QueryGeneric", query);
}

RememberRecent(const name[], const steamid[], const ip[])
{
	static n[64], s[70], i[70];
	MakeStringSQLSafe(name, n, sizeof(n) - 1);
	MakeStringSQLSafe(steamid, s, sizeof(s) - 1);
	MakeStringSQLSafe(ip, i, sizeof(i) - 1);
	
	static query[384];
	if( IsUsableAuthid(steamid) )
		formatex(query, sizeof(query) - 1, "DELETE FROM %s WHERE name = '%s' OR steamid = '%s';", TABLE_RECENT, n, s);
	else
		formatex(query, sizeof(query) - 1, "DELETE FROM %s WHERE name = '%s';", TABLE_RECENT, n);
	PG_ThreadQuery("QueryGeneric", query);
	formatex(query, sizeof(query) - 1,
		"INSERT INTO %s (name,steamid,ip,seen) VALUES ('%s','%s','%s',%d);",
		TABLE_RECENT, n, s, i, get_systime());
	PG_ThreadQuery("QueryGeneric", query);
	formatex(query, sizeof(query) - 1, "DELETE FROM %s WHERE seen < %d;", TABLE_RECENT, get_systime() - (7 * 24 * 60 * 60));
	PG_ThreadQuery("QueryGeneric", query);
}

FillAdminIdentity(client, admin_name[], name_len, admin_authid[], auth_len)
{
	if( client > 0 && is_user_connected(client) )
	{
		get_user_name(client, admin_name, name_len);
		get_user_authid(client, admin_authid, auth_len);
		return;
	}
	copy(admin_name, name_len, "SERVER");
	copy(admin_authid, auth_len, "SERVER");
}

GetBanIdentity(const steamid[], const ip[], output[], len)
{
	if( steamid[0] )
	{
		copy(output, len, steamid);
	}
	else
	{
		copy(output, len, ip);
	}
}

FireBannedForward(target, admin, length, const reason[])
{
	if( g_fwdBanned )
	{
		new dummy;
		ExecuteForward(g_fwdBanned, dummy, target, admin, length, reason);
	}
}

bool:FireCBanPre(target, admin, &length, const reason[])
{
	if( !g_fwdCBanPre ) return true;
	
	new ret;
	ExecuteForward(g_fwdCBanPre, ret, target, admin, length, reason);
	return ret != PLUGIN_HANDLED;
}

FireCBanPost(target, admin, length, const reason[])
{
	if( g_fwdCBanPost )
	{
		new dummy;
		ExecuteForward(g_fwdCBanPost, dummy, target, admin, length, reason);
	}
}

bool:FireCBanAdd(const target[], admin, &length, reason[])
{
	if( !g_fwdCBanAdd ) return true;
	
	new ret;
	ExecuteForward(g_fwdCBanAdd, ret, target, admin, length, reason);
	return ret != PLUGIN_HANDLED;
}

bool:FireCBanOff(const steamid[], admin, &length, reason[])
{
	if( !g_fwdCBanOff ) return true;
	
	new ret;
	ExecuteForward(g_fwdCBanOff, ret, steamid, admin, length, reason);
	return ret != PLUGIN_HANDLED;
}

FindOffBanByName(const name[])
{
	new max = ArraySize(g_off_name);
	static stored[32];
	for( new i = 0; i < max; i++ )
	{
		ArrayGetString(g_off_name, i, stored, sizeof(stored) - 1);
		if( equali(stored, name) ) return i;
	}
	return -1;
}

FindBanByName(const name[])
{
	static data[BannedData];
	for( new i = 0; i < g_total_bans; i++ )
	{
		ArrayGetArray(g_array, i, data);
		if( equali(data[bd_name], name) ) return i;
	}
	return -1;
}

FindBanPartial(const name[])
{
	if( !name[0] ) return -1;
	static data[BannedData];
	new hit = -1;
	for( new i = 0; i < g_total_bans; i++ )
	{
		ArrayGetArray(g_array, i, data);
		if( containi(data[bd_name], name) == -1 ) continue;
		if( hit != -1 ) return -2;
		hit = i;
	}
	return hit;
}

FindBanById(banid)
{
	if( banid <= 0 ) return -1;
	static data[BannedData];
	for( new i = 0; i < g_total_bans; i++ )
	{
		ArrayGetArray(g_array, i, data);
		if( data[bd_id] == banid ) return i;
	}
	return -1;
}

FindOffBanByAuth(const auth[])
{
	if( !auth[0] ) return -1;
	new max = ArraySize(g_off_name);
	static stored[35];
	for( new i = 0; i < max; i++ )
	{
		ArrayGetString(g_off_steamid, i, stored, sizeof(stored) - 1);
		if( equal(stored, auth) ) return i;
		ArrayGetString(g_off_ip, i, stored, sizeof(stored) - 1);
		if( equal(stored, auth) ) return i;
	}
	return -1;
}

FindOffBanPartial(const nick[])
{
	if( !nick[0] ) return -1;
	new max = ArraySize(g_off_name);
	static stored[32];
	new hit = -1;
	for( new i = 0; i < max; i++ )
	{
		ArrayGetString(g_off_name, i, stored, sizeof(stored) - 1);
		if( containi(stored, nick) == -1 ) continue;
		if( hit != -1 ) return -2;
		hit = i;
	}
	return hit;
}

bool:BanHasExpired(length, const unban_time[])
{
	if( length <= 0 ) return false;
	new expires = BanExpiresUnix(unban_time);
	if( expires <= 0 ) return false;
	return expires <= get_systime();
}

RemainingMinutes(length, const unban_time[])
{
	if( length <= 0 ) return 0;
	new expires = BanExpiresUnix(unban_time);
	if( expires <= 0 ) return length;
	new left = expires - get_systime();
	if( left <= 0 ) return 0;
	return (left + 59) / 60;
}

PrintRemaining(client, length, const unban_time[])
{
	if( length <= 0 )
	{
		console_print(client, "Remaining: permanent");
		return;
	}
	new left = BanExpiresUnix(unban_time) - get_systime();
	if( left <= 0 )
	{
		console_print(client, "Remaining: expired");
		return;
	}
	console_print(client, "Remaining: %d minute%s (%d seconds)", (left + 59) / 60, ((left + 59) / 60) == 1 ? "" : "s", left);
}

LoadRecentDisconnects()
{
	static query[256];
	formatex(query, sizeof(query) - 1,
		"SELECT name,steamid,ip,seen FROM (SELECT name,steamid,ip,seen FROM %s ORDER BY seen DESC LIMIT %d) t ORDER BY seen ASC;",
		TABLE_RECENT, MAX_OFFBAN);
	PG_ThreadQuery("QueryLoadRecent", query);
}

public QueryLoadRecent(failstate, query, error[], errcode, data[], datasize, Float:queuetime)
{
	if( failstate || errcode )
	{
		log_amx("[AdvancedBans] Recent-disconnect load failed: %s", error);
		return;
	}
	if( !PG_NumResults(query) ) return;
	
	ArrayClear(g_off_name);
	ArrayClear(g_off_steamid);
	ArrayClear(g_off_ip);
	ArrayClear(g_off_seen);
	
	static name[32], steamid[35], ip[35];
	while( PG_MoreResults(query) )
	{
		PG_ReadString(query, 0, name, sizeof(name) - 1);
		PG_ReadString(query, 1, steamid, sizeof(steamid) - 1);
		PG_ReadString(query, 2, ip, sizeof(ip) - 1);
		new seen = PG_ReadInt(query, 3);
		NormalizeIp(ip, sizeof(ip) - 1);
		if( name[0] )
		{
			ArrayPushString(g_off_name, name);
			ArrayPushString(g_off_steamid, steamid);
			ArrayPushString(g_off_ip, ip);
			ArrayPushCell(g_off_seen, seen);
		}
		PG_NextRow(query);
	}
	log_amx("[AdvancedBans] Loaded %d recent disconnects for offban", ArraySize(g_off_name));
}

FillMissingIdentity(steamid[], ip[])
{
	if( steamid[0] && ip[0] ) return;
	new pos = FindOffBanByAuth(steamid[0] ? steamid : ip);
	if( pos == -1 ) return;
	static stored[35];
	if( !steamid[0] )
	{
		ArrayGetString(g_off_steamid, pos, stored, sizeof(stored) - 1);
		if( IsUsableAuthid(stored) ) copy(steamid, 34, stored);
	}
	if( !ip[0] )
	{
		ArrayGetString(g_off_ip, pos, stored, sizeof(stored) - 1);
		if( stored[0] ) copy(ip, 34, stored);
	}
}

KickMatchingOnline(const steamid[], const ip[], const reason[], length, const unban_time[], const admin_name[], const admin_steamid[], skip_client)
{
	static auth[35], pip[35], pname[32];
	for( new i = 1; i <= g_max_clients; i++ )
	{
		if( i == skip_client ) continue;
		if( !is_user_connected(i) && !is_user_connecting(i) ) continue;
		if( is_user_bot(i) || is_user_hltv(i) ) continue;
		if( get_user_flags(i) & ADMIN_IMMUNITY ) continue;
		
		get_user_authid(i, auth, sizeof(auth) - 1);
		get_user_ip(i, pip, sizeof(pip) - 1, 1);
		NormalizeIp(pip, sizeof(pip) - 1);
		
		if( (steamid[0] && IsUsableAuthid(auth) && equal(auth, steamid)) || (ip[0] && pip[0] && equal(pip, ip)) )
		{
			get_user_name(i, pname, sizeof(pname) - 1);
			ShowBanMotd(i, pname, steamid, ip, reason, length, unban_time, admin_name, admin_steamid);
			ScheduleKick(i);
		}
	}
}

NotifyUnbannedOnline(const steamid[], const ip[])
{
	static auth[35], pip[35];
	for( new i = 1; i <= g_max_clients; i++ )
	{
		if( !is_user_connected(i) ) continue;
		get_user_authid(i, auth, sizeof(auth) - 1);
		get_user_ip(i, pip, sizeof(pip) - 1, 1);
		NormalizeIp(pip, sizeof(pip) - 1);
		if( (steamid[0] && equal(auth, steamid)) || (ip[0] && equal(pip, ip)) )
		{
			client_print(i, print_chat, "[AdvancedBans] Your ban was removed. You can stay.");
			remove_task(i + TASK_KICK);
			g_kick_userid[i] = 0;
			g_kick_auth[i][0] = 0;
		}
	}
}

EnforceConnectedBans()
{
	for( new i = 1; i <= g_max_clients; i++ )
	{
		if( is_user_connected(i) || is_user_connecting(i) )
			CheckPlayerBan(i);
	}
}

IssueLiveBan(admin, target, length, const reason[])
{
	if( !is_user_connected(target) ) return;
	
	new maxlength = GetMaxBanTime(admin);
	if( maxlength && (!length || length > maxlength) )
	{
		if( admin > 0 )
			console_print(admin, "[AdvancedBans] %L", admin, "AB_MAX_BAN_TIME", maxlength);
		return;
	}
	
	static target_authid[35], target_ip[35], target_name[32];
	get_user_authid(target, target_authid, sizeof(target_authid) - 1);
	get_user_ip(target, target_ip, sizeof(target_ip) - 1, 1);
	NormalizeIp(target_ip, sizeof(target_ip) - 1);
	get_user_name(target, target_name, sizeof(target_name) - 1);
	
	if( !IsUsableAuthid(target_authid) ) target_authid[0] = 0;
	
	if( length <= 0 && admin > 0 && !(get_user_flags(admin) & ADMIN_BAN) && (get_user_flags(admin) & ADMIN_BAN_TEMP) )
	{
		console_print(admin, "[AdvancedBans] Temporary-ban flag cannot issue a permanent ban.");
		return;
	}
	
	if( IsAlreadyBanned(target_authid, target_ip) )
	{
		ReplaceExistingBan(target_authid, target_ip);
	}
	
	static unban_time[64];
	GenerateUnbanTime(length, unban_time, sizeof(unban_time) - 1);
	
	static admin_name[64], admin_authid[35];
	if( admin > 0 && is_user_connected(admin) )
	{
		get_user_name(admin, admin_name, sizeof(admin_name) - 1);
		get_user_authid(admin, admin_authid, sizeof(admin_authid) - 1);
	}
	else
	{
		copy(admin_name, sizeof(admin_name) - 1, "SERVER");
		copy(admin_authid, sizeof(admin_authid) - 1, "SERVER");
	}
	
	static reason_buf[128];
	copy(reason_buf, sizeof(reason_buf) - 1, reason);
	trim(reason_buf);
	if( !reason_buf[0] ) copy(reason_buf, sizeof(reason_buf) - 1, "banned");
	
	if( !FireCBanPre(target, admin, length, reason_buf) ) return;
	
	AddBan(target_name, target_authid, target_ip, reason_buf, length, unban_time, admin_name, admin_authid);
	RecordHistory("BAN", target_name, target_authid, target_ip, length, reason_buf, admin_name, admin_authid);
	FireBannedForward(target, admin, length, reason_buf);
	FireCBanPost(target, admin, length, reason_buf);
	
	PrintBanInformation(target, target_name, target_authid[0] ? target_authid : target_ip, reason_buf, length, unban_time, admin_name, admin_authid, true, true);
	if( admin > 0 )
		PrintBanInformation(admin, target_name, target_authid[0] ? target_authid : target_ip, reason_buf, length, unban_time, admin_name, admin_authid, false, false);
	
	ShowBanMotd(target, target_name, target_authid, target_ip, reason_buf, length, unban_time, admin_name, admin_authid);
	ScheduleKick(target);
	KickMatchingOnline(target_authid, target_ip, reason_buf, length, unban_time, admin_name, admin_authid, target);
	
	static length_str[64];
	GetBanTime(length, length_str, sizeof(length_str) - 1);
	PrintActivity(admin_name, "^x04[AdvancedBans] $name^x01 :^x03  banned %s. Reason: %s. Ban Length: %s", target_name, reason_buf, length_str);
	
	Log("%s <%s> banned %s <%s / %s> || Reason: ^"%s^" || Ban Length: %s", admin_name, admin_authid, target_name, target_authid, target_ip, reason_buf, length_str);
}

public CmdOffBan(client, level, cid)
{
	if( !cmd_access(client, level, cid, 3) ) return PLUGIN_HANDLED;
	
	static nick[32], bantime[10], reason[128];
	read_argv(1, nick, sizeof(nick) - 1);
	read_argv(2, bantime, sizeof(bantime) - 1);
	ReadReasonFrom(3, reason, sizeof(reason) - 1);
	if( !reason[0] ) copy(reason, sizeof(reason) - 1, "banned");
	
	new length = str_to_num(bantime);
	if( length <= 0 && client > 0 && !(get_user_flags(client) & ADMIN_BAN) && (get_user_flags(client) & ADMIN_BAN_TEMP) )
	{
		console_print(client, "[AdvancedBans] Temporary-ban flag cannot issue a permanent ban.");
		return PLUGIN_HANDLED;
	}
	new maxlength = GetMaxBanTime(client);
	if( maxlength && (!length || length > maxlength) )
	{
		console_print(client, "[AdvancedBans] %L", client, "AB_MAX_BAN_TIME", maxlength);
		return PLUGIN_HANDLED;
	}
	new live = find_player("bl", nick);
	if( live )
	{
		IssueLiveBan(client, live, length, reason);
		return PLUGIN_HANDLED;
	}
	
	new pos = FindOffBanByName(nick);
	if( pos == -1 )
		pos = FindOffBanByAuth(nick);
	if( pos == -1 )
		pos = FindOffBanPartial(nick);
	if( pos == -2 )
	{
		console_print(client, "[AdvancedBans] Multiple recent disconnects match '%s'. Use SteamID or IP.", nick);
		return PLUGIN_HANDLED;
	}
	if( pos == -1 )
	{
		console_print(client, "[AdvancedBans] Player %s was not found in the recent-disconnect list (this map + last 32 saved).", nick);
		return PLUGIN_HANDLED;
	}
	
	static steamid[35], ip[35];
	ArrayGetString(g_off_steamid, pos, steamid, sizeof(steamid) - 1);
	ArrayGetString(g_off_ip, pos, ip, sizeof(ip) - 1);
	
	if( !FireCBanOff(steamid, client, length, reason) )
	{
		return PLUGIN_HANDLED;
	}
	
	add(reason, sizeof(reason) - 1, " [OFFBAN]");
	
	static unban_time[64];
	GenerateUnbanTime(length, unban_time, sizeof(unban_time) - 1);
	
	static admin_name[64], admin_authid[35];
	FillAdminIdentity(client, admin_name, sizeof(admin_name) - 1, admin_authid, sizeof(admin_authid) - 1);
	
	if( !IsUsableAuthid(steamid) ) steamid[0] = 0;
	
	if( IsAlreadyBanned(steamid, ip) )
		ReplaceExistingBan(steamid, ip);
	
	AddBan(nick, steamid, ip, reason, length, unban_time, admin_name, admin_authid);
	RecordHistory("OFFBAN", nick, steamid, ip, length, reason, admin_name, admin_authid);
	KickMatchingOnline(steamid, ip, reason, length, unban_time, admin_name, admin_authid, 0);
	
	PrintActivity(admin_name, "^x04[AdvancedBans] $name^x01 :^x03  offbanned %s. Reason: %s", nick, reason);
	Log("%s <%s> offbanned %s <%s / %s> || Reason: ^"%s^"", admin_name, admin_authid, nick, steamid, ip, reason);
	return PLUGIN_HANDLED;
}

public CmdRangeBan(client, level, cid)
{
	if( !cmd_access(client, level, cid, 3) ) return PLUGIN_HANDLED;
	
	static start_ip[32], end_ip[32], reason[128];
	read_argv(1, start_ip, sizeof(start_ip) - 1);
	read_argv(2, end_ip, sizeof(end_ip) - 1);
	read_argv(3, reason, sizeof(reason) - 1);
	
	if( !IsValidIP(start_ip) || !IsValidIP(end_ip) )
	{
		console_print(client, "[AdvancedBans] Invalid IP range.");
		return PLUGIN_HANDLED;
	}
	
	if( !reason[0] ) copy(reason, sizeof(reason) - 1, "range ban");
	SanitizeKickReason(reason, sizeof(reason) - 1);
	
	server_cmd("bg_ip_blacklist_add %s %s ^"%s^"", start_ip, end_ip, reason);
	console_print(client, "[AdvancedBans] Range %s - %s added to BypassGuard IP blacklist.", start_ip, end_ip);
	Log("Range ban %s - %s (%s)", start_ip, end_ip, reason);
	return PLUGIN_HANDLED;
}

public CmdRangeUnban(client, level, cid)
{
	if( !cmd_access(client, level, cid, 3) ) return PLUGIN_HANDLED;
	
	static start_ip[32], end_ip[32];
	read_argv(1, start_ip, sizeof(start_ip) - 1);
	read_argv(2, end_ip, sizeof(end_ip) - 1);
	
	if( !IsValidIP(start_ip) || !IsValidIP(end_ip) )
	{
		console_print(client, "[AdvancedBans] Invalid IP range.");
		return PLUGIN_HANDLED;
	}
	
	server_cmd("bg_ip_blacklist_del %s %s", start_ip, end_ip);
	console_print(client, "[AdvancedBans] Range %s - %s removed from BypassGuard IP blacklist.", start_ip, end_ip);
	Log("Range unban %s - %s", start_ip, end_ip);
	return PLUGIN_HANDLED;
}

public CmdCheckBan(client, level, cid)
{
	if( !cmd_access(client, level, cid, 2) ) return PLUGIN_HANDLED;
	
	static arg[64];
	read_argv(1, arg, sizeof(arg) - 1);
	if( contain(arg, ".") != -1 )
		NormalizeIp(arg, sizeof(arg) - 1);
	
	static array_pos, data[BannedData];
	if( arg[0] == '#' )
	{
		new szBanId[12];
		copy(szBanId, charsmax(szBanId), arg[1]);
		new id_pos = FindBanById(str_to_num(szBanId));
		if( id_pos != -1 )
		{
			ArrayGetArray(g_array, id_pos, data);
			static identity[35];
			GetBanIdentity(data[bd_steamid], data[bd_ip], identity, sizeof(identity) - 1);
			console_print(client, "[AdvancedBans] Ban id #%d", data[bd_id]);
			PrintRemaining(client, data[bd_banlength], data[bd_unbantime]);
			PrintBanInformation(client, data[bd_name], identity, data[bd_reason], data[bd_banlength], data[bd_unbantime], data[bd_admin_name], data[bd_admin_steamid], true, false);
			return PLUGIN_HANDLED;
		}
	}
	
	if( TrieGetCell(g_trie, arg, array_pos) )
	{
		ArrayGetArray(g_array, array_pos, data);
		console_print(client, "[AdvancedBans] Ban id #%d", data[bd_id]);
		PrintRemaining(client, data[bd_banlength], data[bd_unbantime]);
		PrintBanInformation(client, data[bd_name], arg, data[bd_reason], data[bd_banlength], data[bd_unbantime], data[bd_admin_name], data[bd_admin_steamid], true, false);
		return PLUGIN_HANDLED;
	}
	
	new nick_pos = FindBanByName(arg);
	if( nick_pos == -1 )
		nick_pos = FindBanPartial(arg);
	if( nick_pos == -2 )
	{
		console_print(client, "[AdvancedBans] Multiple bans match '%s'. Use SteamID, IP, or #id.", arg);
		return PLUGIN_HANDLED;
	}
	if( nick_pos != -1 )
	{
		ArrayGetArray(g_array, nick_pos, data);
		static identity[35];
		GetBanIdentity(data[bd_steamid], data[bd_ip], identity, sizeof(identity) - 1);
		console_print(client, "[AdvancedBans] Ban id #%d", data[bd_id]);
		PrintRemaining(client, data[bd_banlength], data[bd_unbantime]);
		PrintBanInformation(client, data[bd_name], identity, data[bd_reason], data[bd_banlength], data[bd_unbantime], data[bd_admin_name], data[bd_admin_steamid], true, false);
		return PLUGIN_HANDLED;
	}
	
	console_print(client, "[AdvancedBans] No active ban for %s - checking history...", arg);
	static safe[128], query[384];
	MakeStringSQLSafe(arg, safe, sizeof(safe) - 1);
	formatex(query, sizeof(query) - 1,
		"SELECT action,name,steamid,ip,minutes,reason,admin_name,created FROM %s WHERE steamid='%s' OR ip='%s' OR name='%s' ORDER BY id DESC LIMIT 10;",
		TABLE_HISTORY, safe, safe, safe);
	new pack[1];
	pack[0] = (client > 0) ? get_user_userid(client) : 0;
	PG_ThreadQuery("QueryHistory", query, pack, sizeof(pack));
	return PLUGIN_HANDLED;
}

public CmdReloadBans(client, level, cid)
{
	if( !cmd_access(client, level, cid, 1) ) return PLUGIN_HANDLED;
	console_print(client, "[AdvancedBans] Reloading live bans from PostgreSQL...");
	LoadBans();
	LoadRecentDisconnects();
	return PLUGIN_HANDLED;
}

public CmdLast(client, level, cid)
{
	if( !cmd_access(client, level, cid, 1) ) return PLUGIN_HANDLED;
	
	new max = ArraySize(g_off_name);
	if( !max )
	{
		console_print(client, "[AdvancedBans] No recent disconnects loaded.");
		return PLUGIN_HANDLED;
	}
	
	console_print(client, "[AdvancedBans] Recent disconnects (%d):", max);
	static name[32], steamid[35], ip[35], when[32];
	for( new i = max - 1; i >= 0; i-- )
	{
		ArrayGetString(g_off_name, i, name, sizeof(name) - 1);
		ArrayGetString(g_off_steamid, i, steamid, sizeof(steamid) - 1);
		ArrayGetString(g_off_ip, i, ip, sizeof(ip) - 1);
		new seen = ArrayGetCell(g_off_seen, i);
		if( seen > 0 )
			format_time(when, sizeof(when) - 1, "%m/%d %H:%M", seen);
		else
			copy(when, sizeof(when) - 1, "-");
		console_print(client, "  %s  %s  %s  %s", name, steamid, ip, when);
	}
	return PLUGIN_HANDLED;
}

public CmdBanHistory(client, level, cid)
{
	if( !cmd_access(client, level, cid, 1) ) return PLUGIN_HANDLED;
	
	static arg[64], safe[128], query[384];
	if( read_argc() > 1 )
	{
		read_argv(1, arg, sizeof(arg) - 1);
		MakeStringSQLSafe(arg, safe, sizeof(safe) - 1);
		formatex(query, sizeof(query) - 1,
			"SELECT action,name,steamid,ip,minutes,reason,admin_name,created FROM %s WHERE steamid='%s' OR ip='%s' OR name='%s' ORDER BY id DESC LIMIT 10;",
			TABLE_HISTORY, safe, safe, safe);
	}
	else
	{
		formatex(query, sizeof(query) - 1,
			"SELECT action,name,steamid,ip,minutes,reason,admin_name,created FROM %s ORDER BY id DESC LIMIT 10;",
			TABLE_HISTORY);
	}
	
	new pack[1];
	pack[0] = (client > 0) ? get_user_userid(client) : 0;
	PG_ThreadQuery("QueryHistory", query, pack, sizeof(pack));
	return PLUGIN_HANDLED;
}

public QueryHistory(failstate, query, error[], errcode, data[], datasize, Float:queuetime)
{
	new client = 0;
	if( data[0] > 0 )
	{
		client = find_player("k", data[0]);
		if( !client ) return;
	}
	
	if( failstate || errcode )
	{
		log_amx("[AdvancedBans] History query failed: %s", error);
		return;
	}
	
	if( !PG_NumResults(query) )
	{
		console_print(client, "[AdvancedBans] No history rows.");
		return;
	}
	
	console_print(client, "[AdvancedBans] History:");
	static action[16], name[32], steamid[35], ip[35], reason[128], admin[64], when[32];
	new minutes, created;
	while( PG_MoreResults(query) )
	{
		PG_ReadString(query, 0, action, sizeof(action) - 1);
		PG_ReadString(query, 1, name, sizeof(name) - 1);
		PG_ReadString(query, 2, steamid, sizeof(steamid) - 1);
		PG_ReadString(query, 3, ip, sizeof(ip) - 1);
		minutes = PG_ReadInt(query, 4);
		PG_ReadString(query, 5, reason, sizeof(reason) - 1);
		PG_ReadString(query, 6, admin, sizeof(admin) - 1);
		created = PG_ReadInt(query, 7);
		if( created > 0 )
			format_time(when, sizeof(when) - 1, "%m/%d %H:%M", created);
		else
			copy(when, sizeof(when) - 1, "-");
		console_print(client, "  %s %s <%s/%s> %im by %s | %s | %s", action, name, steamid, ip, minutes, admin, reason, when);
		PG_NextRow(query);
	}
}

public _CBan_BanPlayer(plugin, argc)
{
	new pid = get_param(2);
	if( !is_user_connected(pid) ) return;
	
	new ban_length = abs(get_param(3));
	new ban_reason[MAX_REASON_LENGTH];
	get_string(4, ban_reason, charsmax(ban_reason));
	IssueLiveBan(get_param(1), pid, ban_length, ban_reason);
	new target[35];
	get_user_authid(pid, target, charsmax(target));
	BpAuditBan(get_param(1), target, ban_reason);
}

public _CBan_UnbanPlayer(plugin, argc)
{
	new target[MAX_NAME_LENGTH];
	get_string(2, target, charsmax(target));
	// Do not use amx_unban here: admincmd.amxx registers the same command and
	// returns PLUGIN_HANDLED after touching only the legacy file list. The
	// dedicated command is owned exclusively by this plugin.
	server_cmd("fn_cban_unban ^"%s^"", target);
}

stock BpAuditBan(admin, const target[], const reason[])
{
	if (!LibraryExists("fn_audit", LibType_Library))
		return;
	new caseId[24];
	if (!fn_case_new(admin, caseId, charsmax(caseId)))
		return;
	new note[128];
	formatex(note, charsmax(note), "ban.create target=%s reason=%s", target, reason);
	fn_case_note(admin, caseId, note);
}

stock BpAuditUnban(admin, const target[], const reason[])
{
	if (!LibraryExists("fn_audit", LibType_Library))
		return;
	new caseId[24];
	if (!fn_case_new(admin, caseId, charsmax(caseId)))
		return;
	new note[128];
	formatex(note, charsmax(note), "ban.remove target=%s reason=%s", target, reason);
	fn_case_note(admin, caseId, note);
}

public _CBan_GetBanCount(plugin, argc)
{
	return g_total_bans;
}

public _CBan_GetBanInfo(plugin, argc)
{
	new index = get_param(1);
	if( index < 0 || index >= g_total_bans )
		return 0;

	static data[BannedData], identity[35];
	ArrayGetArray(g_array, index, data);
	GetBanIdentity(data[bd_steamid], data[bd_ip], identity, sizeof(identity) - 1);

	set_param_byref(2, data[bd_id]);
	set_string(3, data[bd_name], get_param(4));
	set_string(5, identity, get_param(6));
	set_string(7, data[bd_reason], get_param(8));
	set_param_byref(9, data[bd_banlength]);
	set_string(10, data[bd_unbantime], get_param(11));
	return 1;
}

public _CBan_UnbanById(plugin, argc)
{
	new admin = get_param(1);
	new banid = get_param(2);
	new pos = FindBanById(banid);
	if( pos == -1 )
		return 0;

	static data[BannedData], identity[35], admin_name[64], authid[35];
	ArrayGetArray(g_array, pos, data);
	GetBanIdentity(data[bd_steamid], data[bd_ip], identity, sizeof(identity) - 1);
	FillAdminIdentity(admin, admin_name, sizeof(admin_name) - 1, authid, sizeof(authid) - 1);

	PrintActivity(admin_name, "^x04[AdvancedBans] $name^x01 :^x03  unbanned %s^x01 [%s] [Ban Reason: %s]", data[bd_name], identity, data[bd_reason]);
	Log("%s <%s> unbanned %s <%s> id #%d || Ban Reason: ^"%s^"", admin_name, authid, data[bd_name], identity, data[bd_id], data[bd_reason]);
	RecordHistory("UNBAN", data[bd_name], data[bd_steamid], data[bd_ip], 0, data[bd_reason], admin_name, authid);
	NotifyUnbannedOnline(data[bd_steamid], data[bd_ip]);
	BpAuditUnban(admin, identity, data[bd_reason]);
	RemoveBan(pos, data[bd_steamid], data[bd_ip]);
	return 1;
}

public _CBan_OffBanPlayer(plugin, argc)
{
	new target[MAX_NAME_LENGTH];
	get_string(2, target, charsmax(target));
	
	new pid = find_player("bl", target);
	if( pid && (get_user_flags(pid) & ADMIN_IMMUNITY) ) return 0;
	
	new ban_reason[MAX_REASON_LENGTH];
	get_string(4, ban_reason, charsmax(ban_reason));
	new length = abs(get_param(3));
	
	if( pid )
	{
		IssueLiveBan(get_param(1), pid, length, ban_reason);
		return 1;
	}
	
	new pos = FindOffBanByName(target);
	if( pos == -1 )
		pos = FindOffBanByAuth(target);
	if( pos == -1 )
		pos = FindOffBanPartial(target);
	if( pos < 0 ) return 0;
	
	new steamid[35], ip[35];
	ArrayGetString(g_off_steamid, pos, steamid, charsmax(steamid));
	ArrayGetString(g_off_ip, pos, ip, charsmax(ip));
	
	if( !FireCBanOff(steamid, get_param(1), length, ban_reason) ) return 0;
	
	add(ban_reason, charsmax(ban_reason), " [OFFBAN]");
	
	static unban_time[64];
	GenerateUnbanTime(length, unban_time, sizeof(unban_time) - 1);
	
	static admin_name[64], admin_authid[35];
	new admin = get_param(1);
	if( admin > 0 && is_user_connected(admin) )
	{
		get_user_name(admin, admin_name, sizeof(admin_name) - 1);
		get_user_authid(admin, admin_authid, sizeof(admin_authid) - 1);
	}
	else
	{
		copy(admin_name, sizeof(admin_name) - 1, "SERVER");
		copy(admin_authid, sizeof(admin_authid) - 1, "SERVER");
	}
	
	if( !IsUsableAuthid(steamid) ) steamid[0] = 0;
	if( IsAlreadyBanned(steamid, ip) )
		ReplaceExistingBan(steamid, ip);
	AddBan(target, steamid, ip, ban_reason, length, unban_time, admin_name, admin_authid);
	RecordHistory("OFFBAN", target, steamid, ip, length, ban_reason, admin_name, admin_authid);
	BpAuditBan(admin, steamid[0] ? steamid : ip, ban_reason);
	KickMatchingOnline(steamid, ip, ban_reason, length, unban_time, admin_name, admin_authid, 0);
	return 1;
}

public _CBan_AddBanPlayer(plugin, argc)
{
	new target[MAX_NAME_LENGTH];
	get_string(2, target, charsmax(target));
	
	new ban_reason[MAX_REASON_LENGTH];
	get_string(4, ban_reason, charsmax(ban_reason));
	new length = abs(get_param(3));
	
	new pid = find_player("cl", target);
	if( !pid ) pid = find_player("d", target);
	
	if( pid )
	{
		if( get_user_flags(pid) & ADMIN_IMMUNITY ) return 0;
		IssueLiveBan(get_param(1), pid, length, ban_reason);
		new authid[35];
		get_user_authid(pid, authid, charsmax(authid));
		BpAuditBan(get_param(1), authid, ban_reason);
		return 1;
	}
	
	server_cmd("amx_addban ^"%s^" ^"%s^" %i ^"%s^"", target, target, length, ban_reason);
	BpAuditBan(get_param(1), target, ban_reason);
	return 1;
}
#endif

GetBanTime(const bantime, length[], len)
{
	new minutes = bantime;
	new hours = 0;
	new days = 0;
	
	while( minutes >= 60 )
	{
		minutes -= 60;
		hours++;
	}
	
	while( hours >= 24 )
	{
		hours -= 24;
		days++;
	}
	
	new bool:add_before;
	if( minutes )
	{
		formatex(length, len, "%i minute%s", minutes, minutes == 1 ? "" : "s");
		
		add_before = true;
	}
	if( hours )
	{
		if( add_before )
		{
			format(length, len, "%i hour%s, %s", hours, hours == 1 ? "" : "s", length);
		}
		else
		{
			formatex(length, len, "%i hour%s", hours, hours == 1 ? "" : "s");
			
			add_before = true;
		}
	}
	if( days )
	{
		if( add_before )
		{
			format(length, len, "%i day%s, %s", days, days == 1 ? "" : "s", length);
		}
		else
		{
			formatex(length, len, "%i day%s", days, days == 1 ? "" : "s");
			
			add_before = true;
		}
	}
	if( !add_before )
	{
		// minutes, hours, and days = 0
		// assume permanent ban
		copy(length, len, "Permanent Ban");
	}
}

GenerateUnbanTime(const bantime, unban_time[], len)
{
	if( bantime <= 0 )
	{
		copy(unban_time, len, "0");
		return;
	}
	
	num_to_str(get_systime() + (bantime * 60), unban_time, len);
}

BanExpiresUnix(const unban_time[])
{
	if( !unban_time[0] || unban_time[0] == 'P' ) return 0;
	if( contain(unban_time, ":") != -1 ) return 0;
	return str_to_num(unban_time);
}

FormatUnbanDisplay(const unban_time[], output[], len)
{
	new expires = BanExpiresUnix(unban_time);
	if( expires > 0 )
	{
		format_time(output, len, "%m/%d/%Y %H:%M:%S", expires);
		return;
	}
	
	if( !unban_time[0] || equal(unban_time, "0") )
		copy(output, len, "Permanent Ban");
	else
		copy(output, len, unban_time);
}

GetTargetFlags(client)
{
	static const flags_no_immunity = (CMDTARGET_ALLOW_SELF|CMDTARGET_NO_BOTS);
	static const flags_immunity = (CMDTARGET_ALLOW_SELF|CMDTARGET_NO_BOTS|CMDTARGET_OBEY_IMMUNITY);
	
	switch( get_pcvar_num(ab_immunity) )
	{
		case 1: return flags_immunity;
		case 2: return access(client, ADMIN_IMMUNITY) ? flags_no_immunity : flags_immunity;
	}
	
	return flags_no_immunity;
}

ShowBanMotd(client, const name[], const steamid[], const ip[], const reason[], length, const unban_time[], const admin_name[], const admin_steamid[])
{
	if( client < 1 ) return;
	
	static html[1400], eName[64], eReason[160], eAdmin[80], eSteam[48], eIp[48], eAdminSteam[48];
	static length_str[64], unban_disp[64], website[96], discord[80];
	
	FN_EscapeHtml(name, eName, charsmax(eName));
	FN_EscapeHtml(reason, eReason, charsmax(eReason));
	FN_EscapeHtml(admin_name, eAdmin, charsmax(eAdmin));
	FN_EscapeHtml(steamid, eSteam, charsmax(eSteam));
	FN_EscapeHtml(ip, eIp, charsmax(eIp));
	FN_EscapeHtml(admin_steamid, eAdminSteam, charsmax(eAdminSteam));
	
	new remain_min = RemainingMinutes(length, unban_time);
	if( length <= 0 )
		copy(length_str, charsmax(length_str), "Permanent");
	else if( remain_min <= 0 )
		copy(length_str, charsmax(length_str), "Expired");
	else
		GetBanTime(remain_min, length_str, charsmax(length_str));
	
	FormatUnbanDisplay(unban_time, unban_disp, charsmax(unban_disp));
	get_pcvar_string(ab_website, website, charsmax(website));
	if( !website[0] )
		FN_GetDiscordUrl(website, charsmax(website));
	FN_GetDiscordHandle(discord, charsmax(discord));
	
	new pos = formatex(html, charsmax(html),
		"<html><head><style>body{background:#050706;color:#E8ECE8;font-family:Tahoma,sans-serif;font-size:13px;margin:10px}h1{color:#78FF16;font-size:18px;margin:0 0 8px}td.l{color:#8D978D;padding:2px 8px 2px 0}td.v{color:#fff;padding:2px 0}.f{color:#8D978D;font-size:11px;margin-top:10px}</style></head><body>");
	pos += copy(html[pos], charsmax(html) - pos, "<h1>YOU ARE BANNED</h1><table>");
	pos += formatex(html[pos], charsmax(html) - pos, "<tr><td class=l>Player</td><td class=v>%s</td></tr>", eName);
	pos += formatex(html[pos], charsmax(html) - pos, "<tr><td class=l>SteamID</td><td class=v>%s</td></tr>", eSteam[0] ? eSteam : "-");
	pos += formatex(html[pos], charsmax(html) - pos, "<tr><td class=l>IP</td><td class=v>%s</td></tr>", eIp[0] ? eIp : "-");
	pos += formatex(html[pos], charsmax(html) - pos, "<tr><td class=l>Reason</td><td class=v>%s</td></tr>", eReason[0] ? eReason : "-");
	pos += formatex(html[pos], charsmax(html) - pos, "<tr><td class=l>Length</td><td class=v>%s</td></tr>", length_str);
	pos += formatex(html[pos], charsmax(html) - pos, "<tr><td class=l>Expires</td><td class=v>%s</td></tr>", unban_disp);
	pos += formatex(html[pos], charsmax(html) - pos, "<tr><td class=l>Admin</td><td class=v>%s</td></tr>", eAdmin[0] ? eAdmin : "SERVER");
	if( eAdminSteam[0] )
		pos += formatex(html[pos], charsmax(html) - pos, "<tr><td class=l>Admin ID</td><td class=v>%s</td></tr>", eAdminSteam);
	pos += copy(html[pos], charsmax(html) - pos, "</table>");
	pos += formatex(html[pos], charsmax(html) - pos, "<div class=f>Appeal: %s &bull; Discord %s</div></body></html>", website, discord);
	
	show_motd(client, html, "FreeNova | Banned");
}

GetMaxBanTime(client)
{
	if( !g_total_maxban_times ) return 0;
	
	new flags = get_user_flags(client);
	
	for( new i = 0; i < g_total_maxban_times; i++ )
	{
		#if !defined MAX_BANLIMITS
		if( flags & ArrayGetCell(g_maxban_flags, i) )
		{
			return ArrayGetCell(g_maxban_times, i);
		}
		#else
		if( flags & g_maxban_flags[i] )
		{
			return g_maxban_times[i];
		}
		#endif
	}
	
	return 0;
}

PrintBanInformation(client, const target_name[], const target_authid[], const reason[], const length, const unban_time[], const admin_name[], const admin_authid[], bool:show_admin, bool:show_website)
{
	static website[64], ban_length[64];
	if( client == 0 )
	{
		server_print("************************************************");
		server_print("%L", client, "AB_BAN_INFORMATION");
		server_print("%L: %s", client, "AB_NAME", target_name);
		server_print("%L: %s", client, IsValidAuthid(target_authid) ? "AB_STEAMID" : "AB_IP", target_authid);
		server_print("%L: %s", client, "AB_REASON", reason);
		if( length > 0 )
		{
			GetBanTime(length, ban_length, sizeof(ban_length) - 1);
			server_print("%L: %s", client, "AB_BAN_LENGTH", ban_length);
		}
		static unban_disp[64];
		FormatUnbanDisplay(unban_time, unban_disp, sizeof(unban_disp) - 1);
		server_print("%L: %s", client, "AB_UNBAN_TIME", unban_disp);
		if( show_admin )
		{
			server_print("%L: %s", client, "AB_ADMIN_NAME", admin_name);
			server_print("%L: %s", client, "AB_ADMIN_STEAMID", admin_authid);
		}
		if( show_website )
		{
			get_pcvar_string(ab_website, website, sizeof(website) - 1);
			if( website[0] )
			{
				server_print("");
				server_print("%L", client, "AB_WEBSITE");
				server_print("%s", website);
			}
		}
		server_print("************************************************");
	}
	else
	{
		static eName[64], eAuth[64], eReason[128], eAdmin[64], eAdminAuth[64], eUnban[64];
		SanitizeEchoField(eName, sizeof(eName) - 1, target_name);
		SanitizeEchoField(eAuth, sizeof(eAuth) - 1, target_authid);
		SanitizeEchoField(eReason, sizeof(eReason) - 1, reason);
		SanitizeEchoField(eAdmin, sizeof(eAdmin) - 1, admin_name);
		SanitizeEchoField(eAdminAuth, sizeof(eAdminAuth) - 1, admin_authid);
		
		client_cmd(client, "echo ^"************************************************^"");
		client_cmd(client, "echo ^"%L^"", client, "AB_BAN_INFORMATION");
		client_cmd(client, "echo ^"%L: %s^"", client, "AB_NAME", eName);
		client_cmd(client, "echo ^"%L: %s^"", client, IsValidAuthid(target_authid) ? "AB_STEAMID" : "AB_IP", eAuth);
		client_cmd(client, "echo ^"%L: %s^"", client, "AB_REASON", eReason);
		if( length > 0 )
		{
			GetBanTime(length, ban_length, sizeof(ban_length) - 1);
			client_cmd(client, "echo ^"%L: %s^"", client, "AB_BAN_LENGTH", ban_length);
		}
		static unban_disp[64];
		FormatUnbanDisplay(unban_time, unban_disp, sizeof(unban_disp) - 1);
		SanitizeEchoField(eUnban, sizeof(eUnban) - 1, unban_disp);
		client_cmd(client, "echo ^"%L: %s^"", client, "AB_UNBAN_TIME", eUnban);
		if( show_admin )
		{
			client_cmd(client, "echo ^"%L: %s^"", client, "AB_ADMIN_NAME", eAdmin);
			client_cmd(client, "echo ^"%L: %s^"", client, "AB_ADMIN_STEAMID", eAdminAuth);
		}
		if( show_website )
		{
			get_pcvar_string(ab_website, website, sizeof(website) - 1);
			if( website[0] )
			{
				SanitizeEchoField(website, sizeof(website) - 1, website);
				client_cmd(client, "echo ^"^"");
				client_cmd(client, "echo ^"%L^"", client, "AB_WEBSITE");
				client_cmd(client, "echo ^"%s^"", website);
			}
		}
		client_cmd(client, "echo ^"************************************************^"");
	}
}

PrintActivity(const admin_name[], const message_fmt[], any:...)
{
	if( !get_playersnum() ) return;
	
	new activity = get_pcvar_num(amx_show_activity);
	if( !(0 <= activity <= 5) )
	{
		set_pcvar_num(amx_show_activity, (activity = 2));
	}
	
	static message[192], temp[192];
	vformat(message, sizeof(message) - 1, message_fmt, 3);
	
	for( new client = 1; client <= g_max_clients; client++ )
	{
		if( !is_user_connected(client) ) continue;
		
		switch( is_user_admin(client) ? g_admin_activity[activity] : g_normal_activity[activity] )
		{
			case ACTIVITY_NONE:
			{
				
			}
			case ACTIVITY_HIDE:
			{
				copy(temp, sizeof(temp) - 1, message);
				replace(temp, sizeof(temp) - 1, "$name", "ADMIN");
				
				message_begin(MSG_ONE_UNRELIABLE, g_msgid_SayText, _, client);
				write_byte(client);
				write_string(temp);
				message_end();
			}
			case ACTIVITY_SHOW:
			{
				copy(temp, sizeof(temp) - 1, message);
				replace(temp, sizeof(temp) - 1, "$name", admin_name);
				
				message_begin(MSG_ONE_UNRELIABLE, g_msgid_SayText, _, client);
				write_byte(client);
				write_string(temp);
				message_end();
			}
		}
	}
}

Print(const message_fmt[], any:...)
{
	if( !get_playersnum() ) return;
	
	static message[192];
	vformat(message, sizeof(message) - 1, message_fmt, 2);
	
	for( new client = 1; client <= g_max_clients; client++ )
	{
		if( !is_user_connected(client) ) continue;
		
		message_begin(MSG_ONE_UNRELIABLE, g_msgid_SayText, _, client);
		write_byte(client);
		write_string(message);
		message_end();
	}
}

Log(const message_fmt[], any:...)
{
	static message[256];
	vformat(message, sizeof(message) - 1, message_fmt, 2);
	
	static filename[96];
	#if defined HISTORY_ONE_FILE
	if( !filename[0] )
	{
		get_basedir(filename, sizeof(filename) - 1);
		add(filename, sizeof(filename) - 1, "/logs/ban_history.log");
	}
	#else
	static dir[64];
	if( !dir[0] )
	{
		get_basedir(dir, sizeof(dir) - 1);
		add(dir, sizeof(dir) - 1, "/logs");
	}
	
	format_time(filename, sizeof(filename) - 1, "%m%d%Y");
	format(filename, sizeof(filename) - 1, "%s/BAN_HISTORY_%s.log", dir, filename);
	#endif
	
	log_amx("%s", message);
	log_to_file(filename, "%s", message);
}
#if defined USING_SQL
// ================= Hybrid PG + local fallback (0.9.9-fn-hybrid) =================
BuildLocalPath()
{
	get_datadir(g_ban_file, charsmax(g_ban_file) - 1);
	add(g_ban_file, charsmax(g_ban_file) - 1, "/advanced_bans.txt");
	copy(g_pending_del_file, charsmax(g_pending_del_file) - 1, g_ban_file);
	add(g_pending_del_file, charsmax(g_pending_del_file) - 1, ".pending_del");
}

SaveLocalMirror()
{
	if( !g_ban_file[0] ) BuildLocalPath();
	new f = fopen(g_ban_file, "wt");
	if( !f ) return;
	static d[BannedData];
	for( new i = 0; i < g_total_bans; i++ )
	{
		ArrayGetArray(g_array, i, d);
		if( BanHasExpired(d[bd_banlength], d[bd_unbantime]) ) continue;
		fprintf(f, "^"%s^" ^"%s^" ^"%s^" %i ^"%s^" ^"%s^" ^"%s^" ^"%s^"^n",
			d[bd_steamid], d[bd_ip], d[bd_name],
			d[bd_banlength], d[bd_unbantime], d[bd_reason],
			d[bd_admin_name], d[bd_admin_steamid]);
	}
	fclose(f);
}

LoadLocalFile()
{
	if( !get_pcvar_num(ab_local_fallback) ) return 0;
	if( !g_ban_file[0] ) BuildLocalPath();
	if( !file_exists(g_ban_file) )
	{
		log_amx("[AdvancedBans] Local fallback: no mirror file yet, starting with 0 bans");
		return 0;
	}
	TrieClear(g_trie);
	ArrayClear(g_array);
	g_total_bans = 0;
	new f = fopen(g_ban_file, "rt");
	if( !f ) return 0;
	static line[512], sid[35], ip[35], nm[32], lenstr[10], ut[32], rsn[128], an[64], as[35];
	static d[BannedData];
	while( !feof(f) )
	{
		line[0] = 0;
		fgets(f, line, charsmax(line));
		if( !line[0] ) continue;
		trim(line);
		if( !line[0] ) continue;
		sid[0] = 0; ip[0] = 0; nm[0] = 0; lenstr[0] = 0;
		ut[0] = 0; rsn[0] = 0; an[0] = 0; as[0] = 0;
		new n = parse(line, sid, charsmax(sid), ip, charsmax(ip), nm, charsmax(nm), lenstr, charsmax(lenstr), ut, charsmax(ut), rsn, charsmax(rsn), an, charsmax(an), as, charsmax(as));
		if( n == 7 )
		{
			parse(line, sid, charsmax(sid), nm, charsmax(nm), lenstr, charsmax(lenstr), ut, charsmax(ut), rsn, charsmax(rsn), an, charsmax(an), as, charsmax(as));
			ip[0] = 0;
			if( contain(sid, ".") != -1 && contain(sid, ":") == -1 )
			{
				copy(ip, charsmax(ip) - 1, sid);
				sid[0] = 0;
			}
		}
		else if( n != 8 )
		{
			continue;
		}
		else if( !sid[0] && ip[0] && contain(ip, ".") == -1 )
		{
			continue;
		}
		NormalizeIp(ip, charsmax(ip) - 1);
		d[bd_banlength] = str_to_num(lenstr);
		if( BanHasExpired(d[bd_banlength], ut) ) continue;
		d[bd_id] = ++g_next_banid;
		copy(d[bd_name], charsmax(d[bd_name]) - 1, nm);
		copy(d[bd_steamid], charsmax(d[bd_steamid]) - 1, sid);
		copy(d[bd_ip], charsmax(d[bd_ip]) - 1, ip);
		copy(d[bd_unbantime], charsmax(d[bd_unbantime]) - 1, ut);
		copy(d[bd_reason], charsmax(d[bd_reason]) - 1, rsn);
		copy(d[bd_admin_name], charsmax(d[bd_admin_name]) - 1, an);
		copy(d[bd_admin_steamid], charsmax(d[bd_admin_steamid]) - 1, as);
		if( !d[bd_steamid][0] && !d[bd_ip][0] ) continue;
		IndexBan(g_total_bans, d[bd_steamid], d[bd_ip]);
		ArrayPushArray(g_array, d);
		g_total_bans++;
	}
	fclose(f);
	g_bPGOnline = false;
	g_bLocalFallback = true;
	log_amx("[AdvancedBans] Local fallback: loaded %d ban(s) from %s (PG unreachable)", g_total_bans, g_ban_file);
	EnforceConnectedBans();
	return g_total_bans;
}

HybridPushRow(const name[], const steamid[], const ip[], length, const unban[], const reason[], const admin[], const adminid[])
{
	static n2[64], s2[70], i2[70], r2[256], an2[128], as2[70], u2[64];
	static packed[72];
	MakeStringSQLSafe(name, n2, charsmax(n2) - 1);
	MakeStringSQLSafe(steamid, s2, charsmax(s2) - 1);
	MakeStringSQLSafe(ip, i2, charsmax(i2) - 1);
	MakeStringSQLSafe(reason, r2, charsmax(r2) - 1);
	MakeStringSQLSafe(admin, an2, charsmax(an2) - 1);
	MakeStringSQLSafe(adminid, as2, charsmax(as2) - 1);
	MakeStringSQLSafe(unban, u2, charsmax(u2) - 1);
	static q[1024];
	if( s2[0] && i2[0] )
		formatex(q, charsmax(q) - 1, "INSERT INTO %s (%s,%s,%s,%s,%s,%s,%s,%s) SELECT '%s','%s','%s',%i,'%s','%s','%s','%s' WHERE NOT EXISTS (SELECT 1 FROM %s WHERE %s='%s' OR %s='%s');",
			TABLE_NAME, KEY_NAME, KEY_STEAMID, KEY_IP, KEY_BANLENGTH, KEY_UNBANTIME, KEY_REASON, KEY_ADMIN_NAME, KEY_ADMIN_STEAMID,
			n2, s2, i2, length, u2, r2, an2, as2, TABLE_NAME, KEY_STEAMID, s2, KEY_IP, i2);
	else if( s2[0] )
		formatex(q, charsmax(q) - 1, "INSERT INTO %s (%s,%s,%s,%s,%s,%s,%s,%s) SELECT '%s','%s','',%i,'%s','%s','%s','%s' WHERE NOT EXISTS (SELECT 1 FROM %s WHERE %s='%s');",
			TABLE_NAME, KEY_NAME, KEY_STEAMID, KEY_IP, KEY_BANLENGTH, KEY_UNBANTIME, KEY_REASON, KEY_ADMIN_NAME, KEY_ADMIN_STEAMID,
			n2, s2, length, u2, r2, an2, as2, TABLE_NAME, KEY_STEAMID, s2);
	else if( i2[0] )
		formatex(q, charsmax(q) - 1, "INSERT INTO %s (%s,%s,%s,%s,%s,%s,%s,%s) SELECT '%s','','%s',%i,'%s','%s','%s','%s' WHERE NOT EXISTS (SELECT 1 FROM %s WHERE %s='%s');",
			TABLE_NAME, KEY_NAME, KEY_STEAMID, KEY_IP, KEY_BANLENGTH, KEY_UNBANTIME, KEY_REASON, KEY_ADMIN_NAME, KEY_ADMIN_STEAMID,
			n2, i2, length, u2, r2, an2, as2, TABLE_NAME, KEY_IP, i2);
	else return;
	// packed "steamid|ip" lets QueryAddBan queue op=BAN into ab_pending_push if this carry-up push fails
	formatex(packed, charsmax(packed) - 1, "%s|%s", steamid, ip);
	PG_ThreadQuery("QueryAddBan", q, packed, strlen(packed) + 1);
}

FilterPendingFile(const skip1[], const skip2[])
{
	if( !g_pending_del_file[0] ) return 0;
	if( !file_exists(g_pending_del_file) ) return 0;
	new f = fopen(g_pending_del_file, "rt");
	if( !f ) return -1;
	new kept = 0, removed = 0;
	static line[64];
	while( !feof(f) )
	{
		line[0] = 0;
		fgets(f, line, charsmax(line));
		trim(line);
		if( !line[0] ) continue;
		if( (skip1[0] && equal(line, skip1)) || (skip2[0] && equal(line, skip2)) ) { removed++; continue; }
		if( kept < 2048 )
		{
			copy(g_pdKeep[kept], 34, line);
			kept++;
		}
		else
		{
			fclose(f);
			log_amx("[AdvancedBans] Hybrid: pending filter aborted, file over 2048 lines, kept as-is");
			return -1;
		}
	}
	fclose(f);
	new w = fopen(g_pending_del_file, "wt");
	if( !w ) return -1;
	for( new i = 0; i < kept; i++ )
		fprintf(w, "%s^n", g_pdKeep[i]);
	fclose(w);
	if( kept == 0 )
		delete_file(g_pending_del_file);
	return removed;
}

CompactFlushFile()
{
	if( !g_pending_del_file[0] ) return 0;
	if( !file_exists(g_pending_del_file) ) return 0;
	new f = fopen(g_pending_del_file, "rt");
	if( !f ) return -1;
	new kept = 0, removed = 0;
	static line[64];
	while( !feof(f) )
	{
		line[0] = 0;
		fgets(f, line, charsmax(line));
		trim(line);
		if( !line[0] ) continue;
		new bool:skip = false;
		for( new k = 0; k < g_flushCount; k++ )
		{
			if( equal(line, g_flushList[k]) ) { skip = true; break; }
		}
		if( skip ) { removed++; continue; }
		if( kept < 2048 )
		{
			copy(g_pdKeep[kept], 34, line);
			kept++;
		}
		else
		{
			fclose(f);
			log_amx("[AdvancedBans] Hybrid: flush compact aborted, file over 2048 lines, kept as-is for next pass");
			return -1;
		}
	}
	fclose(f);
	new w = fopen(g_pending_del_file, "wt");
	if( !w ) return -1;
	for( new i = 0; i < kept; i++ )
		fprintf(w, "%s^n", g_pdKeep[i]);
	fclose(w);
	if( kept == 0 )
		delete_file(g_pending_del_file);
	return removed;
}

QueuePendingUnban(const steamid[], const ip[])
{
	if( !g_pending_del_file[0] ) BuildLocalPath();
	new f = fopen(g_pending_del_file, "at");
	if( !f ) return;
	static line[40];
	if( steamid[0] )
	{
		copy(line, charsmax(line) - 1, steamid);
		trim(line);
		if( line[0] ) fprintf(f, "%s^n", line);
	}
	if( ip[0] && !equal(ip, steamid) )
	{
		copy(line, charsmax(line) - 1, ip);
		trim(line);
		if( line[0] ) fprintf(f, "%s^n", line);
	}
	fclose(f);
}

// ================= SQLite mirror + pending-push queue (fn-sqlite) =================
// Postgres stays primary/authoritative. SQLite (data/ab_bans.sq3 via sqlx +
// sqlite affinity, blocking local calls) is a synchronous local mirror plus a
// durable pending-push queue. The flat-file mirror (advanced_bans.txt +
// .pending_del) is kept as-is as a second fallback. Enforcement reads stay
// trie-only (no behavior change).
// Conflict rule: on any steamid/ip match the PG row wins; a local-only row is
// overwritten by, and never shadows, a PG row.
// Fail-closed: any SQLite error is logged once and the op continues file-only;
// enforcement never depends on SQLite.
SQLiteErr(const msg[])
{
	if( !g_bSQLiteErrLogged )
	{
		g_bSQLiteErrLogged = true;
		log_amx("[AdvancedBans] SQLite error (%s) - continuing file-only, enforcement unaffected", msg);
	}
	else Dbg("sqlite err: %s", msg);
	g_bSQLiteOn = false;
	if( g_hSQLiteConn != Empty_Handle )
	{
		SQL_FreeHandle(g_hSQLiteConn);
		g_hSQLiteConn = Empty_Handle;
	}
}

bool:SQLiteConnect()
{
	if( !get_pcvar_num(ab_sqlite_fallback) ) return false;
	if( g_hSQLiteConn != Empty_Handle ) return true;
	SQL_SetAffinity("sqlite");
	if( g_hSQLiteTuple == Empty_Handle )
		g_hSQLiteTuple = SQL_MakeDbTuple("", "", "", SQLITE_DB_NAME);
	new errcode, errmsg[128];
	g_hSQLiteConn = SQL_Connect(g_hSQLiteTuple, errcode, errmsg, charsmax(errmsg));
	if( g_hSQLiteConn == Empty_Handle )
	{
		SQLiteErr(errmsg);
		return false;
	}
	return true;
}

bool:SQLiteExecRaw(const query[])
{
	new Handle:q = SQL_PrepareQuery(g_hSQLiteConn, "%s", query);
	if( q == Empty_Handle )
	{
		SQLiteErr("prepare failed");
		return false;
	}
	if( !SQL_Execute(q) )
	{
		static msg[128];
		SQL_QueryError(q, msg, charsmax(msg) - 1);
		SQL_FreeHandle(q);
		SQLiteErr(msg);
		return false;
	}
	SQL_FreeHandle(q);
	return true;
}

SQLiteInit()
{
	if( g_bSQLiteOn && g_hSQLiteConn != Empty_Handle ) return;
	new vmax = get_pcvar_num(ab_pending_max);
	if( vmax < 64 || vmax > 5000 )
		set_pcvar_num(ab_pending_max, vmax < 64 ? 64 : 5000);
	if( !get_pcvar_num(ab_sqlite_fallback) )
	{
		g_bSQLiteOn = false;
		return;
	}
	if( !SQLiteConnect() ) return;
	static q[512];
	formatex(q, charsmax(q) - 1, "CREATE TABLE IF NOT EXISTS %s (name VARCHAR(32) NOT NULL, steamid VARCHAR(35) NOT NULL DEFAULT '', ip VARCHAR(45) NOT NULL DEFAULT '', banlength INTEGER NOT NULL, unbantime VARCHAR(32) NOT NULL, reason VARCHAR(128) NOT NULL, admin_name VARCHAR(64) NOT NULL, admin_steamid VARCHAR(35) NOT NULL, src TINYINT DEFAULT 0, updated BIGINT);", SQLITE_TABLE_MIRROR);
	if( !SQLiteExecRaw(q) ) return;
	formatex(q, charsmax(q) - 1, "CREATE TABLE IF NOT EXISTS %s (name VARCHAR(32), steamid VARCHAR(35), ip VARCHAR(45), banlength INTEGER, unbantime VARCHAR(32), reason VARCHAR(128), admin_name VARCHAR(64), admin_steamid VARCHAR(35), op VARCHAR(8), attempts INTEGER DEFAULT 0);", SQLITE_TABLE_PENDING);
	if( !SQLiteExecRaw(q) ) return;
	g_bSQLiteOn = true;
	log_amx("[AdvancedBans] SQLite mirror ready (data/ab_bans.sq3)");
}

bool:SQLiteReady()
{
	if( g_bSQLiteOn && g_hSQLiteConn != Empty_Handle ) return true;
	SQLiteInit();
	if( g_bSQLiteOn && g_hSQLiteConn != Empty_Handle ) return true;
	return false;
}

bool:SQLiteExec(const query[])
{
	if( !get_pcvar_num(ab_sqlite_fallback) ) return false;
	if( !SQLiteReady() ) return false;
	return SQLiteExecRaw(query);
}

bool:SQLiteIsOn()
{
	if( !g_bSQLiteOn ) return false;
	if( g_hSQLiteConn == Empty_Handle ) return false;
	return true;
}

GetPendingMax()
{
	new v = get_pcvar_num(ab_pending_max);
	if( v < 64 ) return 64;
	if( v > 5000 ) return 5000;
	return v;
}

bool:SQLiteSplitPacked(const packed[], sid[], sidlen, ip[], iplen)
{
	sid[0] = 0;
	ip[0] = 0;
	new bar = contain(packed, "|");
	if( bar < 0 ) return false;
	new n = 0;
	for( new i = 0; i < bar && n < sidlen; i++ )
	{
		sid[n] = packed[i];
		n++;
	}
	sid[n] = 0;
	n = 0;
	for( new i = bar + 1; packed[i] != 0 && n < iplen; i++ )
	{
		ip[n] = packed[i];
		n++;
	}
	ip[n] = 0;
	return true;
}

SQLiteMirrorUpsert(const name[], const steamid[], const ip[], length, const unban[], const reason[], const admin[], const adminid[], src)
{
	if( !get_pcvar_num(ab_sqlite_fallback) ) return;
	static s[70], i[70];
	MakeStringSQLSafe(steamid, s, charsmax(s) - 1);
	MakeStringSQLSafe(ip, i, charsmax(i) - 1);
	if( !s[0] && !i[0] ) return;
	static n[64], r[256], an[128], as[70], u[64];
	MakeStringSQLSafe(name, n, charsmax(n) - 1);
	MakeStringSQLSafe(reason, r, charsmax(r) - 1);
	MakeStringSQLSafe(admin, an, charsmax(an) - 1);
	MakeStringSQLSafe(adminid, as, charsmax(as) - 1);
	MakeStringSQLSafe(unban, u, charsmax(u) - 1);
	static q[1024];
	if( s[0] && i[0] )
		formatex(q, charsmax(q) - 1, "DELETE FROM %s WHERE steamid = '%s' OR ip = '%s';", SQLITE_TABLE_MIRROR, s, i);
	else if( s[0] )
		formatex(q, charsmax(q) - 1, "DELETE FROM %s WHERE steamid = '%s';", SQLITE_TABLE_MIRROR, s);
	else
		formatex(q, charsmax(q) - 1, "DELETE FROM %s WHERE ip = '%s';", SQLITE_TABLE_MIRROR, i);
	if( !SQLiteExec(q) ) return;
	formatex(q, charsmax(q) - 1, "INSERT INTO %s (name,steamid,ip,banlength,unbantime,reason,admin_name,admin_steamid,src,updated) VALUES ('%s','%s','%s',%i,'%s','%s','%s','%s',%d,%d);",
		SQLITE_TABLE_MIRROR, n, s, i, length, u, r, an, as, src, get_systime());
	SQLiteExec(q);
}

SQLiteMirrorDelete(const steamid[], const ip[])
{
	if( !get_pcvar_num(ab_sqlite_fallback) ) return;
	static s[70], i[70];
	MakeStringSQLSafe(steamid, s, charsmax(s) - 1);
	MakeStringSQLSafe(ip, i, charsmax(i) - 1);
	static q[256];
	if( s[0] && i[0] )
		formatex(q, charsmax(q) - 1, "DELETE FROM %s WHERE steamid = '%s' OR ip = '%s';", SQLITE_TABLE_MIRROR, s, i);
	else if( s[0] )
		formatex(q, charsmax(q) - 1, "DELETE FROM %s WHERE steamid = '%s';", SQLITE_TABLE_MIRROR, s);
	else if( i[0] )
		formatex(q, charsmax(q) - 1, "DELETE FROM %s WHERE ip = '%s';", SQLITE_TABLE_MIRROR, i);
	else return;
	SQLiteExec(q);
}

SQLiteMarkConverged(const packed[])
{
	static sid[35], ip[35];
	if( !SQLiteSplitPacked(packed, sid, charsmax(sid) - 1, ip, charsmax(ip) - 1) ) return;
	static s[70], i[70];
	MakeStringSQLSafe(sid, s, charsmax(s) - 1);
	MakeStringSQLSafe(ip, i, charsmax(i) - 1);
	static q[256];
	if( s[0] && i[0] )
		formatex(q, charsmax(q) - 1, "UPDATE %s SET src = 0, updated = %d WHERE steamid = '%s' OR ip = '%s';", SQLITE_TABLE_MIRROR, get_systime(), s, i);
	else if( s[0] )
		formatex(q, charsmax(q) - 1, "UPDATE %s SET src = 0, updated = %d WHERE steamid = '%s';", SQLITE_TABLE_MIRROR, get_systime(), s);
	else if( i[0] )
		formatex(q, charsmax(q) - 1, "UPDATE %s SET src = 0, updated = %d WHERE ip = '%s';", SQLITE_TABLE_MIRROR, get_systime(), i);
	else return;
	SQLiteExec(q);
}

SQLitePendingCount()
{
	if( !get_pcvar_num(ab_sqlite_fallback) ) return 0;
	if( !SQLiteReady() ) return 0;
	new Handle:q = SQL_PrepareQuery(g_hSQLiteConn, "SELECT COUNT(*) FROM %s;", SQLITE_TABLE_PENDING);
	if( q == Empty_Handle ) return 0;
	new n = 0;
	if( SQL_Execute(q) && SQL_NumResults(q) > 0 )
		n = SQL_ReadResult(q, 0);
	SQL_FreeHandle(q);
	return n;
}

// Read-only probe: counts pending rows WITHOUT initializing the backend
// (no SQLiteReady/SQLiteInit). Returns 0 when SQLite is off/disconnected.
SQLitePendingCountNoInit()
{
	if( !SQLiteIsOn() ) return 0;
	new Handle:q = SQL_PrepareQuery(g_hSQLiteConn, "SELECT COUNT(*) FROM %s;", SQLITE_TABLE_PENDING);
	if( q == Empty_Handle ) return 0;
	new n = 0;
	if( SQL_Execute(q) && SQL_NumResults(q) > 0 )
		n = SQL_ReadResult(q, 0);
	SQL_FreeHandle(q);
	return n;
}

SQLiteQueuePendingInsert(const op[], const name[], const steamid[], const ip[], length, const unban[], const reason[], const admin[], const adminid[])
{
	if( !SQLiteReady() ) return;
	static s[70], i[70], n[64], r[256], an[128], as[70], u[64];
	MakeStringSQLSafe(steamid, s, charsmax(s) - 1);
	MakeStringSQLSafe(ip, i, charsmax(i) - 1);
	MakeStringSQLSafe(name, n, charsmax(n) - 1);
	MakeStringSQLSafe(reason, r, charsmax(r) - 1);
	MakeStringSQLSafe(admin, an, charsmax(an) - 1);
	MakeStringSQLSafe(adminid, as, charsmax(as) - 1);
	MakeStringSQLSafe(unban, u, charsmax(u) - 1);
	static q[1024];
	// latest op wins per identity: drop older queued ops for the same ban first
	if( s[0] && i[0] )
		formatex(q, charsmax(q) - 1, "DELETE FROM %s WHERE steamid = '%s' OR ip = '%s';", SQLITE_TABLE_PENDING, s, i);
	else if( s[0] )
		formatex(q, charsmax(q) - 1, "DELETE FROM %s WHERE steamid = '%s';", SQLITE_TABLE_PENDING, s);
	else if( i[0] )
		formatex(q, charsmax(q) - 1, "DELETE FROM %s WHERE ip = '%s';", SQLITE_TABLE_PENDING, i);
	else return;
	SQLiteExecRaw(q);
	new cnt = SQLitePendingCount();
	new pmax = GetPendingMax();
	if( cnt >= pmax )
	{
		new drop = cnt - pmax + 1;
		formatex(q, charsmax(q) - 1, "DELETE FROM %s WHERE rowid IN (SELECT rowid FROM %s ORDER BY rowid LIMIT %d);", SQLITE_TABLE_PENDING, SQLITE_TABLE_PENDING, drop);
		SQLiteExecRaw(q);
		log_amx("[AdvancedBans] SQLite: pending queue full (%d/%d), dropped %d oldest row(s)", cnt, pmax, drop);
	}
	formatex(q, charsmax(q) - 1, "INSERT INTO %s (name,steamid,ip,banlength,unbantime,reason,admin_name,admin_steamid,op,attempts) VALUES ('%s','%s','%s',%i,'%s','%s','%s','%s','%s',0);",
		SQLITE_TABLE_PENDING, n, s, i, length, u, r, an, as, op);
	if( !SQLiteExecRaw(q) ) return;
	Dbg("sqlite queued %s %s / %s", op, steamid, ip);
}

// Outage AddBan path: re-read the full ban row from the SQLite mirror (written
// synchronously by AddBan before PG answered) and queue it as op=BAN. Falls
// back to the in-memory trie/array if the mirror row is missing.
SQLiteQueueBanFromMirror(const packed[])
{
	static sid[35], ip[35];
	if( !SQLiteSplitPacked(packed, sid, charsmax(sid) - 1, ip, charsmax(ip) - 1) ) return;
	if( !SQLiteReady() ) return;
	static s[70], i[70];
	MakeStringSQLSafe(sid, s, charsmax(s) - 1);
	MakeStringSQLSafe(ip, i, charsmax(i) - 1);
	static q[512];
	if( s[0] && i[0] )
		formatex(q, charsmax(q) - 1, "SELECT name,steamid,ip,banlength,unbantime,reason,admin_name,admin_steamid FROM %s WHERE steamid = '%s' OR ip = '%s' LIMIT 1;", SQLITE_TABLE_MIRROR, s, i);
	else if( s[0] )
		formatex(q, charsmax(q) - 1, "SELECT name,steamid,ip,banlength,unbantime,reason,admin_name,admin_steamid FROM %s WHERE steamid = '%s' LIMIT 1;", SQLITE_TABLE_MIRROR, s);
	else if( i[0] )
		formatex(q, charsmax(q) - 1, "SELECT name,steamid,ip,banlength,unbantime,reason,admin_name,admin_steamid FROM %s WHERE ip = '%s' LIMIT 1;", SQLITE_TABLE_MIRROR, i);
	else return;
	new Handle:h = SQL_PrepareQuery(g_hSQLiteConn, "%s", q);
	if( h == Empty_Handle ) return;
	static nm[32], ms[35], mi[35], ut[32], rs[128], am[64], as[35];
	new ml = 0;
	if( !SQL_Execute(h) )
	{
		static emsg[128];
		SQL_QueryError(h, emsg, charsmax(emsg) - 1);
		SQL_FreeHandle(h);
		SQLiteErr(emsg);
	}
	else if( SQL_NumResults(h) > 0 )
	{
		SQL_ReadResult(h, 0, nm, charsmax(nm));
		SQL_ReadResult(h, 1, ms, charsmax(ms));
		SQL_ReadResult(h, 2, mi, charsmax(mi));
		ml = SQL_ReadResult(h, 3);
		SQL_ReadResult(h, 4, ut, charsmax(ut));
		SQL_ReadResult(h, 5, rs, charsmax(rs));
		SQL_ReadResult(h, 6, am, charsmax(am));
		SQL_ReadResult(h, 7, as, charsmax(as));
		SQL_FreeHandle(h);
		SQLiteQueuePendingInsert("BAN", nm, ms, mi, ml, ut, rs, am, as);
		return;
	}
	else
	{
		// mirror miss (0 rows): not a backend error — free the handle and
		// fall through to the trie/array fallback below, no SQLiteErr.
		SQL_FreeHandle(h);
	}
	// mirror miss: resolve the full row from the live trie/array (PG row wins
	// on match downstream, so queue verbatim).
	new pos = -1;
	if( sid[0] && TrieGetCell(g_trie, sid, pos) )
	{
	}
	else if( ip[0] && TrieGetCell(g_trie, ip, pos) )
	{
	}
	else pos = -1;
	if( pos >= 0 )
	{
		static d[BannedData];
		ArrayGetArray(g_array, pos, d);
		SQLiteQueuePendingInsert("BAN", d[bd_name], d[bd_steamid], d[bd_ip], d[bd_banlength], d[bd_unbantime], d[bd_reason], d[bd_admin_name], d[bd_admin_steamid]);
	}
	else log_amx("[AdvancedBans] SQLite: BAN failure for %s / %s has no mirror or memory row, mirror copy retained", sid, ip);
}

SQLiteQueueUnbanFromPacked(const packed[])
{
	static sid[35], ip[35];
	if( !SQLiteSplitPacked(packed, sid, charsmax(sid) - 1, ip, charsmax(ip) - 1) ) return;
	if( !sid[0] && !ip[0] ) return;
	// UNBAN converges as an idempotent PG DELETE, so identity alone suffices.
	SQLiteQueuePendingInsert("UNBAN", "", sid, ip, 0, "", "", "", "");
}

bool:SQLiteHasPendingBan(const steamid[], const ip[])
{
	if( !SQLiteReady() ) return false;
	static s[70], i[70];
	MakeStringSQLSafe(steamid, s, charsmax(s) - 1);
	MakeStringSQLSafe(ip, i, charsmax(i) - 1);
	static q[256];
	if( s[0] && i[0] )
		formatex(q, charsmax(q) - 1, "SELECT COUNT(*) FROM %s WHERE op = 'BAN' AND (steamid = '%s' OR ip = '%s');", SQLITE_TABLE_PENDING, s, i);
	else if( s[0] )
		formatex(q, charsmax(q) - 1, "SELECT COUNT(*) FROM %s WHERE op = 'BAN' AND steamid = '%s';", SQLITE_TABLE_PENDING, s);
	else if( i[0] )
		formatex(q, charsmax(q) - 1, "SELECT COUNT(*) FROM %s WHERE op = 'BAN' AND ip = '%s';", SQLITE_TABLE_PENDING, i);
	else return false;
	new Handle:h = SQL_PrepareQuery(g_hSQLiteConn, "%s", q);
	if( h == Empty_Handle ) return false;
	new n = 0;
	if( SQL_Execute(h) && SQL_NumResults(h) > 0 )
		n = SQL_ReadResult(h, 0);
	SQL_FreeHandle(h);
	if( n > 0 ) return true;
	return false;
}

SQLitePushOne(rid, const name[], const steamid[], const ip[], length, const unban[], const reason[], const admin[], const adminid[], const op[])
{
	static n[64], s[70], i[70], r[256], an[128], as[70], u[64];
	MakeStringSQLSafe(name, n, charsmax(n) - 1);
	MakeStringSQLSafe(steamid, s, charsmax(s) - 1);
	MakeStringSQLSafe(ip, i, charsmax(i) - 1);
	MakeStringSQLSafe(reason, r, charsmax(r) - 1);
	MakeStringSQLSafe(admin, an, charsmax(an) - 1);
	MakeStringSQLSafe(adminid, as, charsmax(as) - 1);
	MakeStringSQLSafe(unban, u, charsmax(u) - 1);
	static q[1024];
	new rowtag[1];
	rowtag[0] = rid;
	if( equal(op, "UNBAN") )
	{
		if( s[0] && i[0] )
			formatex(q, charsmax(q) - 1, "DELETE FROM %s WHERE %s = '%s' OR %s = '%s';", TABLE_NAME, KEY_STEAMID, s, KEY_IP, i);
		else if( s[0] )
			formatex(q, charsmax(q) - 1, "DELETE FROM %s WHERE %s = '%s';", TABLE_NAME, KEY_STEAMID, s);
		else if( i[0] )
			formatex(q, charsmax(q) - 1, "DELETE FROM %s WHERE %s = '%s';", TABLE_NAME, KEY_IP, i);
		else return;
	}
	else
	{
		// BAN: PG-wins guarded push (same rule as HybridPushRow) — push only
		// if PG has no row for the identity, so a stale queued v1 can never
		// clobber a newer v2 after partition.
		if( s[0] && i[0] )
			formatex(q, charsmax(q) - 1, "INSERT INTO %s (%s, %s, %s, %s, %s, %s, %s, %s) SELECT '%s','%s','%s',%i,'%s','%s','%s','%s' WHERE NOT EXISTS (SELECT 1 FROM %s WHERE %s='%s' OR %s='%s');",
				TABLE_NAME, KEY_NAME, KEY_STEAMID, KEY_IP, KEY_BANLENGTH, KEY_UNBANTIME, KEY_REASON, KEY_ADMIN_NAME, KEY_ADMIN_STEAMID,
				n, s, i, length, u, r, an, as, TABLE_NAME, KEY_STEAMID, s, KEY_IP, i);
		else if( s[0] )
			formatex(q, charsmax(q) - 1, "INSERT INTO %s (%s, %s, %s, %s, %s, %s, %s, %s) SELECT '%s','%s','',%i,'%s','%s','%s','%s' WHERE NOT EXISTS (SELECT 1 FROM %s WHERE %s='%s');",
				TABLE_NAME, KEY_NAME, KEY_STEAMID, KEY_IP, KEY_BANLENGTH, KEY_UNBANTIME, KEY_REASON, KEY_ADMIN_NAME, KEY_ADMIN_STEAMID,
				n, s, length, u, r, an, as, TABLE_NAME, KEY_STEAMID, s);
		else if( i[0] )
			formatex(q, charsmax(q) - 1, "INSERT INTO %s (%s, %s, %s, %s, %s, %s, %s, %s) SELECT '%s','','%s',%i,'%s','%s','%s','%s' WHERE NOT EXISTS (SELECT 1 FROM %s WHERE %s='%s');",
				TABLE_NAME, KEY_NAME, KEY_STEAMID, KEY_IP, KEY_BANLENGTH, KEY_UNBANTIME, KEY_REASON, KEY_ADMIN_NAME, KEY_ADMIN_STEAMID,
				n, i, length, u, r, an, as, TABLE_NAME, KEY_IP, i);
		else return;
	}
	PG_ThreadQuery("QueryPendingPush", q, rowtag, sizeof(rowtag));
}

SQLitePushPendingUpstream()
{
	if( !get_pcvar_num(ab_sqlite_fallback) ) return;
	if( !g_bPGOnline ) return;
	if( !SQLiteReady() ) return;
	new Handle:h = SQL_PrepareQuery(g_hSQLiteConn, "SELECT rowid,name,steamid,ip,banlength,unbantime,reason,admin_name,admin_steamid,op FROM %s ORDER BY rowid;", SQLITE_TABLE_PENDING);
	if( h == Empty_Handle ) return;
	if( !SQL_Execute(h) )
	{
		static emsg[128];
		SQL_QueryError(h, emsg, charsmax(emsg) - 1);
		SQL_FreeHandle(h);
		SQLiteErr(emsg);
		return;
	}
	new pushed = 0;
	new pmax = GetPendingMax();
	static nm[32], ms[35], mi[35], ut[32], rs[128], am[64], as[35], op[9];
	while( SQL_MoreResults(h) )
	{
		new rid = SQL_ReadResult(h, 0);
		SQL_ReadResult(h, 1, nm, charsmax(nm));
		SQL_ReadResult(h, 2, ms, charsmax(ms));
		SQL_ReadResult(h, 3, mi, charsmax(mi));
		new ml = SQL_ReadResult(h, 4);
		SQL_ReadResult(h, 5, ut, charsmax(ut));
		SQL_ReadResult(h, 6, rs, charsmax(rs));
		SQL_ReadResult(h, 7, am, charsmax(am));
		SQL_ReadResult(h, 8, as, charsmax(as));
		SQL_ReadResult(h, 9, op, charsmax(op));
		SQL_NextRow(h);
		SQLitePushOne(rid, nm, ms, mi, ml, ut, rs, am, as, op);
		pushed++;
		if( pushed >= pmax ) break;
	}
	SQL_FreeHandle(h);
	if( pushed > 0 )
		log_amx("[AdvancedBans] SQLite: pushed %d queued op(s) upstream (confirm async)", pushed);
}

public QueryPendingPush(failstate, query, error[], errcode, data[], datasize, Float:queuetime)
{
	new rid = 0;
	if( datasize > 0 )
		rid = data[0];
	if( failstate || errcode )
	{
		log_amx("[AdvancedBans] SQLite pending push failed (%d/%d): row kept, attempts bumped", failstate, errcode);
		if( rid > 0 )
		{
			static q[128];
			formatex(q, charsmax(q) - 1, "UPDATE %s SET attempts = attempts + 1 WHERE rowid = %d;", SQLITE_TABLE_PENDING, rid);
			SQLiteExec(q);
		}
		return;
	}
	if( rid <= 0 ) return;
	// converge the mirror copy first (needs identity from the still-present
	// pending row), then drop the confirmed row.
	SQLiteConvergeOnePush(rid);
	static q2[128];
	formatex(q2, charsmax(q2) - 1, "DELETE FROM %s WHERE rowid = %d;", SQLITE_TABLE_PENDING, rid);
	SQLiteExec(q2);
}

SQLiteConvergeOnePush(rid)
{
	if( !SQLiteReady() ) return;
	static q[256];
	formatex(q, charsmax(q) - 1, "SELECT steamid,ip FROM %s WHERE rowid = %d;", SQLITE_TABLE_PENDING, rid);
	new Handle:h = SQL_PrepareQuery(g_hSQLiteConn, "%s", q);
	if( h == Empty_Handle ) return;
	static s[35], i[35];
	new bool:have = false;
	if( SQL_Execute(h) && SQL_NumResults(h) > 0 )
	{
		SQL_ReadResult(h, 0, s, charsmax(s));
		SQL_ReadResult(h, 1, i, charsmax(i));
		have = true;
	}
	SQL_FreeHandle(h);
	if( !have ) return;
	static s2[70], i2[70];
	MakeStringSQLSafe(s, s2, charsmax(s2) - 1);
	MakeStringSQLSafe(i, i2, charsmax(i2) - 1);
	if( s2[0] && i2[0] )
		formatex(q, charsmax(q) - 1, "UPDATE %s SET src = 0, updated = %d WHERE steamid = '%s' OR ip = '%s';", SQLITE_TABLE_MIRROR, get_systime(), s2, i2);
	else if( s2[0] )
		formatex(q, charsmax(q) - 1, "UPDATE %s SET src = 0, updated = %d WHERE steamid = '%s';", SQLITE_TABLE_MIRROR, get_systime(), s2);
	else if( i2[0] )
		formatex(q, charsmax(q) - 1, "UPDATE %s SET src = 0, updated = %d WHERE ip = '%s';", SQLITE_TABLE_MIRROR, get_systime(), i2);
	else return;
	SQLiteExecRaw(q);
}

// Bidirectional converge after a successful pull: the queued ops have just been
// (re)pushed above; the mirror is rebuilt from the converged in-memory set so
// PG-side deletes/expiries disappear locally too. Rows still carrying an
// unconfirmed op=BAN keep src=1, everything else is marked src=0 (PG wins).
SQLiteRebuildMirrorAfterPull()
{
	if( !SQLiteReady() ) return;
	static q[1024];
	formatex(q, charsmax(q) - 1, "DELETE FROM %s;", SQLITE_TABLE_MIRROR);
	if( !SQLiteExecRaw(q) ) return;
	static d[BannedData];
	for( new idx = 0; idx < g_total_bans; idx++ )
	{
		ArrayGetArray(g_array, idx, d);
		if( BanHasExpired(d[bd_banlength], d[bd_unbantime]) ) continue;
		new src = 0;
		if( SQLiteHasPendingBan(d[bd_steamid], d[bd_ip]) ) src = 1;
		SQLiteMirrorUpsert(d[bd_name], d[bd_steamid], d[bd_ip], d[bd_banlength], d[bd_unbantime], d[bd_reason], d[bd_admin_name], d[bd_admin_steamid], src);
	}
}

SQLiteConvergeAfterPull()
{
	// (a) push queued ops upstream, (c) mark converged rows src=0.
	// (b) local-only carry-up already ran above (existing code, kept).
	// (d) the flat-file FlushPendingUnbans flow is untouched and runs next.
	if( !get_pcvar_num(ab_sqlite_fallback) ) return;
	SQLitePushPendingUpstream();
	SQLiteRebuildMirrorAfterPull();
}

FlushPendingUnbans()
{
	if( !g_bPGOnline ) return;
	if( !g_pending_del_file[0] ) return;
	if( !file_exists(g_pending_del_file) ) return;
	if( g_bFlushActive )
	{
		log_amx("[AdvancedBans] Hybrid: previous flush still confirming, backlog stays for next pass");
		return;
	}
	new f = fopen(g_pending_del_file, "rt");
	if( !f ) return;
	static line[64];
	g_flushCount = 0;
	new backlog = 0;
	while( !feof(f) )
	{
		line[0] = 0;
		fgets(f, line, charsmax(line));
		trim(line);
		if( !line[0] ) continue;
		if( g_flushCount < 64 )
		{
			copy(g_flushList[g_flushCount], 34, line);
			g_flushCount++;
		}
		else backlog++;
	}
	fclose(f);
	if( g_flushCount == 0 )
	{
		delete_file(g_pending_del_file);
		return;
	}
	log_amx("[AdvancedBans] Hybrid: flushing %d queued unban(s), backlog %d left in file", g_flushCount, backlog);
	static safe[128], q[256];
	static tag[1];
	tag[0] = 1;
	g_bFlushing = true;
	for( new i = 0; i < g_flushCount; i++ )
	{
		MakeStringSQLSafe(g_flushList[i], safe, charsmax(safe) - 1);
		formatex(q, charsmax(q) - 1, "DELETE FROM %s WHERE %s='%s' OR %s='%s';", TABLE_NAME, KEY_STEAMID, safe, KEY_IP, safe);
		PG_ThreadQuery("QueryDeleteBan", q, tag, sizeof(tag));
		new pos;
		if( TrieGetCell(g_trie, g_flushList[i], pos) )
		{
			static d[BannedData];
			ArrayGetArray(g_array, pos, d);
			RemoveBan(pos, d[bd_steamid], d[bd_ip]);
		}
	}
	g_bFlushing = false;
	g_bFlushActive = true;
	g_flushHadFail = false;
	g_iFlushFired = g_flushCount;
	g_iFlushConfirmed = 0;
}

public Task_HourlySync()
{
	if( g_loading_bans )
	{
		if( g_iLoadStart && get_systime() - g_iLoadStart > 600 )
		{
			log_amx("[AdvancedBans] Load stuck over 600s, recovering flag");
			g_loading_bans = false;
			g_iLoadStart = 0;
		}
		else return;
	}
	log_amx("[AdvancedBans] Hourly PG sync: pulling all bans from all servers...");
	LoadBans();
	LoadRecentDisconnects();
}

public Task_BootFallback()
{
	if( g_bPGOnline || g_total_bans > 0 ) return;
	if( !get_pcvar_num(ab_local_fallback) ) return;
	log_amx("[AdvancedBans] Boot: PG not ready after 12s, trying local fallback file");
	LoadLocalFile();
}

public CmdBanStatus(client, level, cid)
{
	if( !cmd_access(client, level, cid, 1) ) return PLUGIN_HANDLED;
	new now = get_systime();
	new lastago = g_iLastSyncOk ? (now - g_iLastSyncOk) : -1;
	console_print(client, "[AdvancedBans] PG=%s bans=%d fallback=%d fails=%d last_ok=%ds ago sync_every=%ds sqlite=%s pending=%d",
		g_bPGOnline ? "ONLINE" : "OFFLINE", g_total_bans, g_bLocalFallback, g_iSyncFails, lastago, get_pcvar_num(ab_sync_interval),
		SQLiteIsOn() ? "ON" : "OFF", SQLitePendingCountNoInit());
	console_print(client, "[AdvancedBans] local=%s", g_ban_file);
	return PLUGIN_HANDLED;
}
#endif
/* AMXX-Studio Notes - DO NOT MODIFY BELOW HERE
*{\\ rtf1\\ ansi\\ deff0{\\ fonttbl{\\ f0\\ fnil Tahoma;}}\n\\ viewkind4\\ uc1\\ pard\\ lang1033\\ f0\\ fs16 \n\\ par }
*/