/* История обновлений:
	0.1 (20.07.2023):
		* Открытый релиз
	0.2 (21.07.2023):
		* Добавлена поддержка учёта банов [fork] Lite Bans (поддержка для кваров 'bg_sv_ignore_server_bans' и 'bg_sv_min_ban_time')
	0.3 (04.02.2024):
		* Улучшение логики расчёта разницы времени между сервером mysql и игровым сервером
		* Добавлена поддержка учёта банов Diveban X Open
		* Изменено значение по умолчанию для квара bg_sv_bans_exp_time_global с "180" на "60"
		* Изменено значение по умолчанию для квара bg_sv_restrict_duration_global с "120" на "20"
	0.4 (13.02.2024):
		* Исправление возможной ошибки "#1067 - Некорректное значение по умолчанию для 'until_global'"
			Спасибо D1esel (https://dev-cs.ru/threads/31880/post-169242)
	0.5 (23.08.2024):
		* Реализована совместимость с новым функционалом ядра версии 1.0.10
			* Нативу BypassGuard_SendSupervisingResult добавлены аргументы bByWhitepass и bStrictStatus
		* Добавлена возможность подгружать настройки подключения к БД из amxmodx/configs/sql.cfg, для этого значение квара
			bg_sv_sql_host необходимо изменить на "sql.cfg" (идея SKAJIbnEJIb)
		* Добавлена очистка устаревших записей в таблицах, раз в сессию запуска сервера (идея SKAJIbnEJIb)
		* Квару bg_sv_min_ban_time добавлена поддержка новой ожидаемой версии AMXBans RBS, автор
			обещал выпустить обновление с большим кол-вом аргументов в форварде amxbans_ban_pre()
	0.6 (06.09.2024):
		* Исправление нерабочей фичи со значением "sql.cfg" для квара bg_sv_sql_host (спасибо SKAJIbnEJIb)
*/

new const PLUGIN_VERSION[] = "0.6"

/* ----------------------- */

// Create config with cvars in 'configs/plugins' and execute it?
// Also here you can set the name of the config (do not use dots and spaces!).
//
// Создавать конфиг с кварами в 'configs/plugins', и запускать его?
// Так же здесь можно задать имя конфига (не используйте точки и пробелы!).
#define AUTO_CFG "plugin-bg_supervisor"

#define INIT_RETRY_DELAY 10.0
#define INIT_MAX_RETRIES 6
#define TASKID_RETRY_INIT 36401

// Default access flag for all console commands
//
// Флаг доступа по-умолчанию ко всем консольным командам
#define ACCESS_FLAG ADMIN_CFG

// Configuration file that contain ASN's that can't be automatically restricted
//
// Файл конфигурации со списком AS-номеров, которые не ограничиваются автоматически
new const AS_WHITELIST_FILE[] = "bg_sv_as_whitelist.ini"

// Main log filename in 'amxmodx/logs/%bg_folder%'
//
// Имя основного логфайла в 'amxmodx/logs/%bg_folder%'
new const MAINLOG_FILENAME[] = "bg_supervisor_main.log"

// SQL errorlog filename in 'amxmodx/logs/%bg_folder%'
//
// Имя логфайла ошибок работы с базой данных в 'amxmodx/logs/%bg_folder%'
new const SQLERRLOG_FILENAME[] = "bg_supervisor_sql_errors.log"

// String ident for global restriction logic
//
// Строковый идентификатор для логики глобального ограничения
new const GLOBAL_KEY[] = "GLOBAL"

/* ----------------------- */

#include <amxmodx>
#include <sqlx>
#include <time>
#include <bypass_guard>

enum _:CVAR_ENUM {
	CVAR__HOST[64],
	CVAR__USER[64],
	CVAR__PASSWORD[64],
	CVAR__DATABASE[64],
	CVAR__TABLE_WHITEPASSES[64],
	CVAR__TABLE_BANS[64],
	CVAR__TABLE_RESTRICTIONS[64],
	CVAR__TIMEOUT,
	CVAR__AUTOCREATE,
	CVAR__PLUGIN_MODE[32],
	Float:CVAR_F__WP_CACHE_PRUNE_FREQ,
	CVAR__STEAMID_EXP_DAYS,
	CVAR__BAN_EXP_TIME_AS,
	CVAR__COUNT_TO_STRICT_AS,
	CVAR__RESTRICT_DURATION_AS,
	CVAR__BAN_EXP_TIME_GLOBAL,
	CVAR__COUNT_TO_STRICT_GLOBAL,
	CVAR__RESTRICT_DURATION_GLOBAL,
	CVAR__IGNORE_SERVER_BANS,
	CVAR__MIN_BAN_TIME,
	CVAR__LOG_MODE[32]
}

enum ( <<= 1 ) {
	WORK_MODE__COUNT_BANS = 1,
	WORK_MODE__ADD_RESTRICTIONS,
	WORK_MODE__WRITE_WHITEPASSES,
	WORK_MODE__PERFORM_CHECKS
}

enum ( <<= 1 ) {
	LOG_MODE__GENERAL = 1,
	LOG_MODE__DETAILED,
	LOG_MODE__DEBUG
}

enum {
	QUERY__INIT_SYSTEM,
	QUERY__CREATE_TABLE,
	QUERY__FLUSH_OLD_DATA,
	QUERY__WRITE_WHITEPASS,
	QUERY__CHECK_PLAYER,
	QUERY__INSERT_BAN,
	QUERY__GET_BANS,
	QUERY__WRITE_RESTRICTION,
	QUERY__REMOVE_RESTRICTION,
	QUERY__SHOW_RESTRICTIONS
}

enum _:SQL_DATA_STRUCT {
	SQL_DATA__QUERY_TYPE,
	SQL_DATA__QID,
	SQL_DATA__USERID,
	SQL_DATA__STEP,
	SQL_DATA__AS[MAX_AS_LEN]
}

enum _:SV_ALLOW_TYPE_ENUM {
	SV__ALLOW_CACHE,
	SV__ALLOW_QUERY,
	SV__ALLOW_APPROVED
}

new const ALLOW_STATUSES[SV_ALLOW_TYPE_ENUM][MAX_SV_STATUS_LEN] = {
	"Whitepass Cache",
	"Whitepass Query",
	"Approved"
}

enum _:SV_DENY_TYPE_ENUM {
	SV__DENY_GLOBAL_REST,
	SV__DENY_ASN_REST
}

new const DENY_STATUSES[SV_DENY_TYPE_ENUM][MAX_SV_STATUS_LEN] = {
	"Global Restriction",
	"ASN Restriction"
}

new const SV_STATUS_SQL_ERROR[MAX_SV_STATUS_LEN] = "SQL Error"

new g_eCvar[CVAR_ENUM]
new bool:g_bSystemInitialized
new bool:g_bInitFailed
new bool:g_bPluginEnded
new Handle:g_hSqlTuple
new g_szQuery[1536]
new g_eSqlData[SQL_DATA_STRUCT]
new g_szSqlErrLogFile[96]
new g_szMainLogFile[96]
new Trie:g_tPlayerCache
new bool:g_bBanned[MAX_PLAYERS + 1]
new bool:g_bWaitCheck[MAX_PLAYERS + 1]
new bool:g_bWaitWrite[MAX_PLAYERS + 1]
new bool:g_bWaitBan[MAX_PLAYERS + 1]
new g_szQueuedAs[MAX_PLAYERS + 1][MAX_AS_LEN]
new g_szQueuedAuth[MAX_PLAYERS + 1][64]
new g_iWaitBanAdmin[MAX_PLAYERS + 1]
new Trie:g_tAsWhitelist
new g_iTimeDiff
new g_iInitRetries

/* ----------------------- */

public plugin_init() {
	register_plugin("[BG] Supervisor", PLUGIN_VERSION, "mx?!")

	RegCvars()

	new szFolderName[32]
	BypassGuard_GetPluginFolderName(szFolderName, charsmax(szFolderName))

	new iLen = get_localinfo("amxx_logs", g_szMainLogFile, charsmax(g_szMainLogFile))
	formatex(g_szMainLogFile[iLen], charsmax(g_szMainLogFile) - iLen, "/%s/%s", szFolderName, MAINLOG_FILENAME)

	RecordToLogfile(LOG_MODE__DEBUG, "Plugin start") // NOTE: Can be skipped at plugin start as config is not loaded yet

	g_tPlayerCache = TrieCreate()

	g_tAsWhitelist = TrieCreate()
	LoadAsWhiteList(szFolderName)

	register_concmd("bg_sv_rest_add", "concmd_RestAdd", ACCESS_FLAG)
	register_concmd("bg_sv_rest_del", "concmd_RestDel", ACCESS_FLAG)
	register_concmd("bg_sv_rest_show", "concmd_RestShow", ACCESS_FLAG)

	set_task(4.0, "task_InitSystem")
}

/* ----------------------- */

LoadAsWhiteList(const szFolderName[]) {
	new szPath[240]

	new iLen = get_localinfo("amxx_configsdir", szPath, charsmax(szPath))
	formatex(szPath[iLen], charsmax(szPath) - iLen, "/%s/%s", szFolderName, AS_WHITELIST_FILE)

	new hFile = fopen(szPath, "r")

	if(!hFile) {
		log_to_file(g_szMainLogFile, "[Error] Can't %s '%s'", file_exists(szPath) ? "open" : "find", szPath)
		return
	}

	new szString[MAX_AS_LEN * 2], szAsNumber[MAX_AS_LEN]

	while(fgets(hFile, szString, charsmax(szString))) {
		trim(szString)

		if(!szString[0]) {
			continue
		}

		parse(szString, szAsNumber, charsmax(szAsNumber))

		if(IsValidAS(szAsNumber)) {
			TrieSetCell(g_tAsWhitelist, szAsNumber, 0)
		}
	}

	fclose(hFile)

	RecordToLogfile(LOG_MODE__DEBUG, "%i ASN's were whitelisted", TrieGetSize(g_tAsWhitelist))
}

/* ----------------------- */

RegCvars() {
	create_cvar( "bg_sv_sql_host", "127.0.0.1", FCVAR_PROTECTED,
		.description = "Database host (set to ^"sql.cfg^" to use settings from it)" );

	create_cvar( "bg_sv_sql_user", "root", FCVAR_PROTECTED,
		.description = "Database user" );

	create_cvar( "bg_sv_sql_password", "", FCVAR_PROTECTED,
		.description = "Database password" );

	create_cvar( "bg_sv_sql_database", "database", FCVAR_PROTECTED,
		.description = "Database name" );

	bind_cvar_string( "bg_sv_sql_wp_table", "bg_sv_whitepasses", FCVAR_PROTECTED,
		.desc = "Database table with whitepasses",
		.bind = g_eCvar[CVAR__TABLE_WHITEPASSES], .maxlen = charsmax(g_eCvar[CVAR__TABLE_WHITEPASSES])
	);

	bind_cvar_string( "bg_sv_sql_bans_table", "bg_sv_bans", FCVAR_PROTECTED,
		.desc = "Database table with bans",
		.bind = g_eCvar[CVAR__TABLE_BANS], .maxlen = charsmax(g_eCvar[CVAR__TABLE_BANS])
	);

	bind_cvar_string( "bg_sv_sql_rest_table", "bg_sv_restrictions", FCVAR_PROTECTED,
		.desc = "Database table with restrictions",
		.bind = g_eCvar[CVAR__TABLE_RESTRICTIONS], .maxlen = charsmax(g_eCvar[CVAR__TABLE_RESTRICTIONS])
	);

	bind_cvar_num( "bg_sv_sql_timeout", "7",
		.desc = "Timeout value for sql requests (set to 0 to use global default value (60s))",
		.bind = g_eCvar[CVAR__TIMEOUT]
	);

	bind_cvar_num( "bg_sv_sql_autocreate", "1",
		.desc = "Create sql tables automatically?",
		.bind = g_eCvar[CVAR__AUTOCREATE]
	);

	bind_cvar_string( "bg_sv_plugin_mode", "abcd",
		.desc = "Work mode:^n\
			a - Count bans^n\
			b - Add restrictions^n\
			c - Writing whitepasses^n\
			d - Perform checks",
		.bind = g_eCvar[CVAR__PLUGIN_MODE], .maxlen = charsmax(g_eCvar[CVAR__PLUGIN_MODE])
	);

	bind_cvar_float( "bg_sv_wp_cache_prune_freq", "1200",
		.desc = "Whitepass cache prunning frequency in seconds (set 0 to disable prunning, but it is not recommended)",
		.has_min = true, .min_val = 0.0,
		.bind = g_eCvar[CVAR_F__WP_CACHE_PRUNE_FREQ]
	);

	bind_cvar_num( "bg_sv_steamid_exp_days", "365",
		.desc = "SteamID whitepass expiration time in days",
		.has_min = true, .min_val = 1.0,
		.bind = g_eCvar[CVAR__STEAMID_EXP_DAYS]
	);

	bind_cvar_num( "bg_sv_bans_exp_time_as", "720",
		.desc = "How long each ban will affect the AS counter, in minutes",
		.has_min = true, .min_val = 1.0,
		.bind = g_eCvar[CVAR__BAN_EXP_TIME_AS]
	);

	bind_cvar_num( "bg_sv_count_to_strict_as", "3",
		.desc = "Bans count to strict AS number (set to 0 to disable new restrictions)",
		.has_min = true, .min_val = 0.0,
		.bind = g_eCvar[CVAR__COUNT_TO_STRICT_AS]
	);

	bind_cvar_num( "bg_sv_restrict_duration_as", "1440",
		.desc = "How long AS number will be restricted, in minutes (set to 0 to disable new restrictions)",
		.has_min = true, .min_val = 0.0,
		.bind = g_eCvar[CVAR__RESTRICT_DURATION_AS]
	);

	bind_cvar_num( "bg_sv_bans_exp_time_global", "60",
		.desc = "How long each ban will affect the GLOBAL counter, in minutes",
		.has_min = true, .min_val = 1.0,
		.bind = g_eCvar[CVAR__BAN_EXP_TIME_GLOBAL]
	);

	bind_cvar_num( "bg_sv_count_to_strict_global", "5",
		.desc = "Bans count to strict GLOBAL (set to 0 to disable new restrictions)",
		.has_min = true, .min_val = 0.0,
		.bind = g_eCvar[CVAR__COUNT_TO_STRICT_GLOBAL]
	);

	bind_cvar_num( "bg_sv_restrict_duration_global", "20",
		.desc = "How long GLOBAL will be restricted, in minutes (set to 0 to disable new restrictions)",
		.has_min = true, .min_val = 0.0,
		.bind = g_eCvar[CVAR__RESTRICT_DURATION_GLOBAL]
	);

	bind_cvar_num( "bg_sv_ignore_server_bans", "1",
		.desc = "If enabled, bans from server will not affect ban counters (does no effect with Lite Bans 2.2, use 2.3f+ version!)",
		.bind = g_eCvar[CVAR__IGNORE_SERVER_BANS]
	);

	bind_cvar_num( "bg_sv_min_ban_time", "10080",
		.desc = "Bans shorter than this value will not affect ban counters (does no effect with old versions of AMXBans RBS and Lite Bans 2.2 (use 2.3f+!))",
		.bind = g_eCvar[CVAR__MIN_BAN_TIME]
	);

	bind_cvar_string( "bg_sv_logging_mode", "a",
		.desc = "Logging mode:^n\
			a - General^n\
			b - Detailed^n\
			c - Debug",
		.bind = g_eCvar[CVAR__LOG_MODE], .maxlen = charsmax(g_eCvar[CVAR__LOG_MODE])
	);

	/* --- */

#if defined AUTO_CFG
	AutoExecConfig(.name = AUTO_CFG)
#endif
}

/* ----------------------- */

public task_InitSystem() {
	if(!SQL_SetAffinity("mysql")) {
		set_fail_state("Failed to set affinity to 'mysql' (module not loaded?)")
	}

	if(g_eCvar[CVAR_F__WP_CACHE_PRUNE_FREQ] > 0.0) {
		set_task(g_eCvar[CVAR_F__WP_CACHE_PRUNE_FREQ], "task_PruneWhitepassCache", .flags = "b")
	}

	get_cvar_string("bg_sv_sql_host", g_eCvar[CVAR__HOST], charsmax(g_eCvar[CVAR__HOST]))

	if(equali(g_eCvar[CVAR__HOST], "sql.cfg")) {
		get_cvar_string("amx_sql_host", g_eCvar[CVAR__HOST], charsmax(g_eCvar[CVAR__HOST]))
		get_cvar_string("amx_sql_user", g_eCvar[CVAR__USER], charsmax(g_eCvar[CVAR__USER]))
		get_cvar_string("amx_sql_pass", g_eCvar[CVAR__PASSWORD], charsmax(g_eCvar[CVAR__PASSWORD]))
		get_cvar_string("amx_sql_db", g_eCvar[CVAR__DATABASE], charsmax(g_eCvar[CVAR__DATABASE]))
	}
	else {
		get_cvar_string("bg_sv_sql_user", g_eCvar[CVAR__USER], charsmax(g_eCvar[CVAR__USER]))
		get_cvar_string("bg_sv_sql_password", g_eCvar[CVAR__PASSWORD], charsmax(g_eCvar[CVAR__PASSWORD]))
		get_cvar_string("bg_sv_sql_database", g_eCvar[CVAR__DATABASE], charsmax(g_eCvar[CVAR__DATABASE]))
	}

	g_hSqlTuple = SQL_MakeDbTuple( g_eCvar[CVAR__HOST], g_eCvar[CVAR__USER], g_eCvar[CVAR__PASSWORD],
		g_eCvar[CVAR__DATABASE], g_eCvar[CVAR__TIMEOUT] );

	SQL_SetCharset(g_hSqlTuple, "utf8")

	if( !IsValidTableName(g_eCvar[CVAR__TABLE_WHITEPASSES])
		|| !IsValidTableName(g_eCvar[CVAR__TABLE_BANS])
		|| !IsValidTableName(g_eCvar[CVAR__TABLE_RESTRICTIONS])
	) {
		log_to_file( g_szMainLogFile,
			"[Error] Invalid SQL table name (allowed: A-Z a-z 0-9 _). wp='%s' bans='%s' rest='%s'",
			g_eCvar[CVAR__TABLE_WHITEPASSES], g_eCvar[CVAR__TABLE_BANS], g_eCvar[CVAR__TABLE_RESTRICTIONS] );

		g_iInitRetries = INIT_MAX_RETRIES
		g_bInitFailed = true
		FailQueuedChecks()
		return
	}

	InitializeSystem()
}

/* ----------------------- */

InitializeSystem() {
	formatex(g_szQuery, charsmax(g_szQuery), "SELECT UNIX_TIMESTAMP() as `unixtime`;")

	RecordToLogfile(LOG_MODE__DEBUG, "[QID %i] [QUERY__INIT_SYSTEM] Initialize system...", g_eSqlData[SQL_DATA__QID] + 1)

	g_eSqlData[SQL_DATA__USERID] = 0
	g_eSqlData[SQL_DATA__STEP] = 0
	MakeQuery(QUERY__INIT_SYSTEM)
}

/* ----------------------- */

public SQL_Handler(iFailState, Handle:hQueryHandle, szError[], iErrorCode, eSqlData[], iDataSize, Float:fQueryTime) {
	if(g_bPluginEnded) {
		return
	}

	if(iFailState != TQUERY_SUCCESS) {
		if(!g_szSqlErrLogFile[0]) {
			new szFolderName[32]
			BypassGuard_GetPluginFolderName(szFolderName, charsmax(szFolderName))
			new iLen = get_localinfo("amxx_logs", g_szSqlErrLogFile, charsmax(g_szSqlErrLogFile))
			formatex(g_szSqlErrLogFile[iLen], charsmax(g_szSqlErrLogFile) - iLen, "/%s/%s", szFolderName, SQLERRLOG_FILENAME)
		}

		RecordToLogfile(LOG_MODE__DEBUG, "[QID %i] Sql error occured. For more info see '%s'", eSqlData[SQL_DATA__QID], SQLERRLOG_FILENAME)

		if(iFailState == TQUERY_CONNECT_FAILED)	{
			log_to_file(g_szSqlErrLogFile, "[SQL] Can't connect to server [%.2f]", fQueryTime)
			log_to_file(g_szSqlErrLogFile, "[SQL] Error #%i, %s", iErrorCode, szError)
		}
		else /*if(iFailState == TQUERY_QUERY_FAILED)*/ {
			SQL_GetQueryString(hQueryHandle, g_szQuery, charsmax(g_szQuery))
			log_to_file(g_szSqlErrLogFile, "[SQL] Query error!")
			log_to_file(g_szSqlErrLogFile, "[SQL] Error #%i, %s", iErrorCode, szError)
			log_to_file(g_szSqlErrLogFile, "[SQL] Query: %s", g_szQuery)
		}

		switch(eSqlData[SQL_DATA__QUERY_TYPE]) {
			case QUERY__INIT_SYSTEM, QUERY__CREATE_TABLE, QUERY__FLUSH_OLD_DATA: {
				HandleInitFailure()
			}
			case QUERY__CHECK_PLAYER: {
				FailPlayerCheck(eSqlData[SQL_DATA__USERID])
			}
			case QUERY__WRITE_WHITEPASS: {
				RecordToLogfile(LOG_MODE__GENERAL, "[QID %i] [QUERY__WRITE_WHITEPASS] failed", eSqlData[SQL_DATA__QID])
			}
			case QUERY__INSERT_BAN: {
				RecordToLogfile(LOG_MODE__GENERAL, "[QID %i] [QUERY__INSERT_BAN] failed", eSqlData[SQL_DATA__QID])
			}
		}

		return
	}

	/* --- */

	RecordToLogfile(LOG_MODE__DEBUG, "QID %i completed", eSqlData[SQL_DATA__QID])

	switch(eSqlData[SQL_DATA__QUERY_TYPE]) {
		case QUERY__INIT_SYSTEM: {
			new iTimeStamp = SQL_ReadResult(hQueryHandle, 0) // `unixtime`

			new iSysTime = get_systime()
			new iQueryTime = floatround(fQueryTime)

			if(iTimeStamp + iQueryTime > iSysTime) {
				g_iTimeDiff = (iTimeStamp + iQueryTime) - iSysTime // (10 + 1) - 5 = timediff 6 (mysql time > than cs server time)
			}
			else {
				g_iTimeDiff = iTimeStamp - (iSysTime + iQueryTime) // 5 - (10 + 1) = timediff -6 (mysql time < than cs server time)
			}

			RecordToLogfile( LOG_MODE__DEBUG, "[QUERY__INIT_SYSTEM] LocalTime %i, DbTime: %i, QueryTime: %f, TimeDiff: %i",
				iSysTime, iTimeStamp, fQueryTime, g_iTimeDiff );

			if(g_eCvar[CVAR__AUTOCREATE]) {
				StartCreateTables()
			}
			else {
				FlushOldData()
			}
		}

		/* --- */

		case QUERY__CREATE_TABLE: {
			StartCreateTables(eSqlData[SQL_DATA__STEP] + 1)
		}

		/* --- */

		case QUERY__FLUSH_OLD_DATA: {
			FlushOldData(eSqlData[SQL_DATA__STEP] + 1)
		}

		/* --- */

		case QUERY__CHECK_PLAYER: {
			new pPlayer = find_player("k", eSqlData[SQL_DATA__USERID])

			if(!pPlayer) {
				RecordToLogfile(LOG_MODE__DEBUG, "[QUERY__CHECK_PLAYER] player with userid %i not found", eSqlData[SQL_DATA__USERID])
				return
			}

			// (SELECT COUNT(*) FROM `%s` WHERE `until` > CURRENT_TIMESTAMP) as `strict_status`
			new bool:bStrictStatus = (SQL_ReadResult(hQueryHandle, 3) > 0)

			RecordToLogfile(LOG_MODE__DEBUG, "[QUERY__CHECK_PLAYER] %N -> SV strict status: %i", pPlayer, bStrictStatus)

			// SELECT COUNT(*) as `whitepass`
			if(SQL_ReadResult(hQueryHandle, 0)) {
				RecordToLogfile(LOG_MODE__DEBUG, "[QUERY__CHECK_PLAYER] %N allowed due to whitepass (query)", pPlayer)
				BypassGuard_SendSupervisingResult(pPlayer, true, ALLOW_STATUSES[SV__ALLOW_QUERY], true, bStrictStatus)
				return
			}

			// (SELECT COUNT(*) FROM `%s` WHERE `asn` = '%s' AND `until` > CURRENT_TIMESTAMP) as `rest_asn`
			if(SQL_ReadResult(hQueryHandle, 2)) {
				RecordToLogfile(LOG_MODE__DEBUG, "[QUERY__CHECK_PLAYER] %N denied due to ASN restriction", pPlayer)
				BypassGuard_SendSupervisingResult(pPlayer, false, DENY_STATUSES[SV__DENY_ASN_REST], false, bStrictStatus)
				return
			}

			// (SELECT COUNT(*) FROM `%s` WHERE `asn` = '%s' AND `until` > CURRENT_TIMESTAMP) as `rest_global`
			if(SQL_ReadResult(hQueryHandle, 1)) {
				RecordToLogfile(LOG_MODE__DEBUG, "[QUERY__CHECK_PLAYER] %N denied due to GLOBAL restriction", pPlayer)
				BypassGuard_SendSupervisingResult(pPlayer, false, DENY_STATUSES[SV__DENY_GLOBAL_REST], false, bStrictStatus)
				return
			}

			RecordToLogfile(LOG_MODE__DEBUG, "[QUERY__CHECK_PLAYER] %N allowed due to approval", pPlayer)
			BypassGuard_SendSupervisingResult(pPlayer, true, ALLOW_STATUSES[SV__ALLOW_APPROVED], false, bStrictStatus)
		}

		/* --- */

		case QUERY__GET_BANS: {
			new iASBansCount = SQL_ReadResult(hQueryHandle, 0) // `asn_counter`
			new iGlobalBansCount = SQL_ReadResult(hQueryHandle, 1) // `global_counter`
			new bool:bIsAsValid = IsValidAS(eSqlData[SQL_DATA__AS])
			new bool:bIsAsWhitelisted = TrieKeyExists(g_tAsWhitelist, eSqlData[SQL_DATA__AS])
			new iGlobalRestrictedUntil = SQL_ReadResult(hQueryHandle, 2) // `rest_global`
			new iAsRestrictedUntil = SQL_ReadResult(hQueryHandle, 3)  // 'rest_asn`

			RecordToLogfile( LOG_MODE__DETAILED,
				"[QID %i] [QUERY__GET_BANS] '%s' is %s, %s, %s, counter %i/%i [exp_time %i, duration %i], GLOBAL is %s, counter %i/%i [exp_time %i, duration %i]",
				eSqlData[SQL_DATA__QID],
				eSqlData[SQL_DATA__AS],
				bIsAsValid ? "valid" : "not valid",
				bIsAsWhitelisted ? "whitelisted" : "not whitelisted",
				iAsRestrictedUntil ? "restricted" : "not restricted",
				iASBansCount,
				g_eCvar[CVAR__COUNT_TO_STRICT_AS],
				g_eCvar[CVAR__BAN_EXP_TIME_AS],
				g_eCvar[CVAR__RESTRICT_DURATION_AS],
				iGlobalRestrictedUntil ? "restricted" : "not restricted",
				iGlobalBansCount,
				g_eCvar[CVAR__COUNT_TO_STRICT_GLOBAL],
				g_eCvar[CVAR__BAN_EXP_TIME_GLOBAL],
				g_eCvar[CVAR__RESTRICT_DURATION_GLOBAL]
			);

			if(!PluginMode(WORK_MODE__ADD_RESTRICTIONS)) {
				RecordToLogfile(LOG_MODE__DEBUG, "[QUERY__GET_BANS] Adding restrictions disabled, skip further action")
				return
			}

			if( iASBansCount >= g_eCvar[CVAR__COUNT_TO_STRICT_AS] && g_eCvar[CVAR__COUNT_TO_STRICT_AS] &&
				g_eCvar[CVAR__RESTRICT_DURATION_AS] && bIsAsValid && !bIsAsWhitelisted
			) {
				new szUntil[32]

				if(iAsRestrictedUntil) {
					FormatTime(szUntil, charsmax(szUntil), iAsRestrictedUntil)

					RecordToLogfile( LOG_MODE__DETAILED, "[QUERY__GET_BANS] Skip ASN restriction as ASN '%s' already restricted until '%s'",
						eSqlData[SQL_DATA__AS], szUntil );
				}
				else {
					new iRestSeconds = g_eCvar[CVAR__RESTRICT_DURATION_AS] * SECONDS_IN_MINUTE
					new szAsEsc[MAX_AS_LEN * 2]
					QuoteSql(szAsEsc, charsmax(szAsEsc), eSqlData[SQL_DATA__AS])

					formatex( g_szQuery, charsmax(g_szQuery),
						"INSERT INTO `%s` (`asn`, `until`) VALUES ('%s', FROM_UNIXTIME(UNIX_TIMESTAMP() + %i)) \
						ON DUPLICATE KEY UPDATE `until` = FROM_UNIXTIME(UNIX_TIMESTAMP() + %i)",

						g_eCvar[CVAR__TABLE_RESTRICTIONS], szAsEsc, iRestSeconds, iRestSeconds
					);

					iAsRestrictedUntil = GetSysTime() + iRestSeconds
					FormatTime(szUntil, charsmax(szUntil), iAsRestrictedUntil)

					RecordToLogfile( LOG_MODE__GENERAL, "[QID %i] [QUERY__WRITE_RESTRICTION] ASN '%s' will be restricted for %i minutes until '%s'",
						g_eSqlData[SQL_DATA__QID] + 1, eSqlData[SQL_DATA__AS], g_eCvar[CVAR__RESTRICT_DURATION_AS], szUntil );

					g_eSqlData[SQL_DATA__USERID] = 0
					MakeQuery(QUERY__WRITE_RESTRICTION)
				}
			}

			if(iGlobalBansCount >= g_eCvar[CVAR__COUNT_TO_STRICT_GLOBAL] && g_eCvar[CVAR__COUNT_TO_STRICT_GLOBAL] &&
				g_eCvar[CVAR__RESTRICT_DURATION_GLOBAL]
			) {
				new szUntil[32]

				if(iGlobalRestrictedUntil) {
					FormatTime(szUntil, charsmax(szUntil), iGlobalRestrictedUntil)

					RecordToLogfile( LOG_MODE__DETAILED, "[QUERY__GET_BANS] Skip GLOBAL restriction as '%s' already restricted until '%s'",
						GLOBAL_KEY, szUntil );
				}
				else {
					new iRestSeconds = g_eCvar[CVAR__RESTRICT_DURATION_GLOBAL] * SECONDS_IN_MINUTE

					formatex( g_szQuery, charsmax(g_szQuery),
						"INSERT INTO `%s` (`asn`, `until`) VALUES ('%s', FROM_UNIXTIME(UNIX_TIMESTAMP() + %i)) \
						ON DUPLICATE KEY UPDATE `until` = FROM_UNIXTIME(UNIX_TIMESTAMP() + %i)",

						g_eCvar[CVAR__TABLE_RESTRICTIONS], GLOBAL_KEY, iRestSeconds, iRestSeconds
					);

					iGlobalRestrictedUntil = GetSysTime() + iRestSeconds
					FormatTime(szUntil, charsmax(szUntil), iGlobalRestrictedUntil)

					RecordToLogfile( LOG_MODE__GENERAL,	"[QID %i] [QUERY__WRITE_RESTRICTION] '%s' will be restricted for %i minutes until '%s'",
						g_eSqlData[SQL_DATA__QID] + 1, GLOBAL_KEY, g_eCvar[CVAR__RESTRICT_DURATION_GLOBAL], szUntil );

					g_eSqlData[SQL_DATA__USERID] = 0
					MakeQuery(QUERY__WRITE_RESTRICTION)
				}
			}
		}

		/* --- */

		case QUERY__WRITE_RESTRICTION, QUERY__REMOVE_RESTRICTION: {
			if(!eSqlData[SQL_DATA__USERID]) {
				return
			}

			new iAffectedRows = SQL_AffectedRows(hQueryHandle)

			RecordToLogfile(LOG_MODE__GENERAL, "[QID %i] Affected rows: %i",eSqlData[SQL_DATA__QID], iAffectedRows)

			new pPlayer = find_player("k", eSqlData[SQL_DATA__USERID])

			if(!pPlayer && eSqlData[SQL_DATA__USERID] != -1) {
				return
			}

			console_print(pPlayer, "* Query completed. Affected rows: %i", iAffectedRows)
		}

		/* --- */

		case QUERY__SHOW_RESTRICTIONS: {
			if(!eSqlData[SQL_DATA__USERID]) {
				return
			}

			new pPlayer = find_player("k", eSqlData[SQL_DATA__USERID])

			if(!pPlayer && eSqlData[SQL_DATA__USERID] != -1) {
				return
			}

			console_print( pPlayer,
				"^nRestricted ASN's:^n# <-> ASN <-> Restricted until" );

			new iCount, iNumRows = SQL_NumResults(hQueryHandle)

			new szAsNumber[MAX_AS_LEN], szUntil[32]

			while(iNumRows) {
				SQL_ReadResult(hQueryHandle, 0, szAsNumber, charsmax(szAsNumber)) // `asn`
				SQL_ReadResult(hQueryHandle, 1, szUntil, charsmax(szUntil)) // `until`

				console_print(pPlayer, "%i <-> %s <-> %s", ++iCount, szAsNumber, szUntil)

				iNumRows--
				SQL_NextRow(hQueryHandle)
			}

			console_print(pPlayer, "Total: %i^n", iCount)
		}
	}
}

/* ----------------------- */

StartCreateTables(iStep = 0) {
	switch(iStep) {
		case 0: {
			formatex( g_szQuery, charsmax(g_szQuery),
				"CREATE TABLE IF NOT EXISTS `%s` (\
					`id` int(10) unsigned NOT NULL AUTO_INCREMENT, \
					`steamid` varchar(64) NOT NULL, \
					`until` timestamp NULL DEFAULT NULL, \
					PRIMARY KEY (`id`), \
					UNIQUE KEY `steamid` (`steamid`)\
				) ENGINE=InnoDB DEFAULT CHARSET=utf8",
				g_eCvar[CVAR__TABLE_WHITEPASSES] );
		}
		case 1: {
			formatex( g_szQuery, charsmax(g_szQuery),
				"CREATE TABLE IF NOT EXISTS `%s` (\
					`id` int(10) unsigned NOT NULL AUTO_INCREMENT, \
					`asn` varchar(16) NOT NULL, \
					`until_global` timestamp NULL DEFAULT NULL, \
					`until_as` timestamp NULL DEFAULT NULL, \
					PRIMARY KEY (`id`), \
					KEY `asn` (`asn`)\
				) ENGINE=InnoDB DEFAULT CHARSET=utf8",
				g_eCvar[CVAR__TABLE_BANS] );
		}
		case 2: {
			formatex( g_szQuery, charsmax(g_szQuery),
				"CREATE TABLE IF NOT EXISTS `%s` (\
					`id` int(10) unsigned NOT NULL AUTO_INCREMENT, \
					`asn` varchar(16) NOT NULL, \
					`until` timestamp NULL DEFAULT NULL, \
					PRIMARY KEY (`id`), \
					UNIQUE KEY `asn` (`asn`)\
				) ENGINE=InnoDB DEFAULT CHARSET=utf8",
				g_eCvar[CVAR__TABLE_RESTRICTIONS] );
		}
		default: {
			FlushOldData()
			return
		}
	}

	RecordToLogfile(LOG_MODE__DEBUG, "[QID %i] [QUERY__CREATE_TABLE] step %i", g_eSqlData[SQL_DATA__QID] + 1, iStep)

	g_eSqlData[SQL_DATA__USERID] = 0
	g_eSqlData[SQL_DATA__STEP] = iStep
	MakeQuery(QUERY__CREATE_TABLE)
}

/* ----------------------- */

FlushOldData(iStep = 0) {
	new szValue[8]
	get_localinfo("bg_sv_flushed", szValue, charsmax(szValue))

	if(str_to_num(szValue)) {
		RecordToLogfile(LOG_MODE__DEBUG, "Data already flushed!")
		SetSystemInitialized()
		return
	}

	switch(iStep) {
		case 0: {
			formatex( g_szQuery, charsmax(g_szQuery),
				"DELETE FROM `%s` WHERE `until` < CURRENT_TIMESTAMP",
				g_eCvar[CVAR__TABLE_WHITEPASSES] );
		}
		case 1: {
			formatex( g_szQuery, charsmax(g_szQuery),
				"DELETE FROM `%s` WHERE `until` < CURRENT_TIMESTAMP",
				g_eCvar[CVAR__TABLE_RESTRICTIONS] );
		}
		case 2: {
			formatex( g_szQuery, charsmax(g_szQuery),
				"DELETE FROM `%s` WHERE `until_global` < CURRENT_TIMESTAMP AND `until_as` < CURRENT_TIMESTAMP",
				g_eCvar[CVAR__TABLE_BANS] );
		}
		default: {
			set_localinfo("bg_sv_flushed", "1")
			RecordToLogfile(LOG_MODE__DEBUG, "[QUERY__FLUSH_OLD_DATA] Flushing done!")
			SetSystemInitialized()
			return
		}
	}

	RecordToLogfile(LOG_MODE__DEBUG, "[QID %i] [QUERY__FLUSH_OLD_DATA] step %i", g_eSqlData[SQL_DATA__QID] + 1, iStep)

	g_eSqlData[SQL_DATA__USERID] = 0
	g_eSqlData[SQL_DATA__STEP] = iStep
	MakeQuery(QUERY__FLUSH_OLD_DATA)
}

/* ----------------------- */

SetSystemInitialized() {
	remove_task(TASKID_RETRY_INIT)
	g_bInitFailed = false
	g_iInitRetries = 0
	RecordToLogfile(LOG_MODE__DEBUG, "System initialized!")
	g_bSystemInitialized = true
	PerformDelayedActions()
}

/* ----------------------- */

HandleInitFailure() {
	if(g_bSystemInitialized || g_bPluginEnded) {
		return
	}

	g_iInitRetries++

	if(g_iInitRetries < INIT_MAX_RETRIES) {
		RecordToLogfile( LOG_MODE__GENERAL,
			"[QUERY__INIT_SYSTEM] Init failed, retry %i/%i in %.0fs",
			g_iInitRetries, INIT_MAX_RETRIES, INIT_RETRY_DELAY );

		remove_task(TASKID_RETRY_INIT)
		set_task(INIT_RETRY_DELAY, "task_RetryInit", TASKID_RETRY_INIT)
		return
	}

	RecordToLogfile(LOG_MODE__GENERAL, "[QUERY__INIT_SYSTEM] Init failed after %i retries, failing queued checks", INIT_MAX_RETRIES)
	g_bInitFailed = true
	FailQueuedChecks()
}

/* ----------------------- */

public task_RetryInit() {
	if(g_bPluginEnded || g_bSystemInitialized) {
		return
	}

	InitializeSystem()
}

/* ----------------------- */

FailPlayerCheck(iUserId) {
	new pPlayer = find_player("k", iUserId)

	if(!pPlayer) {
		RecordToLogfile(LOG_MODE__DEBUG, "[QUERY__CHECK_PLAYER] fail: player with userid %i not found", iUserId)
		return
	}

	g_bWaitCheck[pPlayer] = false
	RecordToLogfile(LOG_MODE__DEBUG, "[QUERY__CHECK_PLAYER] %N denied due to SQL error", pPlayer)
	BypassGuard_SendSupervisingResult(pPlayer, false, SV_STATUS_SQL_ERROR, false, false)
}

/* ----------------------- */

FailQueuedChecks() {
	new pPlayers[MAX_PLAYERS], iPlCount, pPlayer
	get_players(pPlayers, iPlCount, "ch")

	for(new i; i < iPlCount; i++) {
		pPlayer = pPlayers[i]

		if(!g_bWaitCheck[pPlayer]) {
			continue
		}

		g_bWaitCheck[pPlayer] = false
		g_bWaitWrite[pPlayer] = false
		g_bWaitBan[pPlayer] = false
		g_szQueuedAs[pPlayer][0] = 0
		g_szQueuedAuth[pPlayer][0] = 0

		RecordToLogfile(LOG_MODE__DEBUG, "%N denied due to init failure", pPlayer)
		BypassGuard_SendSupervisingResult(pPlayer, false, SV_STATUS_SQL_ERROR, false, false)
	}
}

/* ----------------------- */

GetSysTime() {
	return get_systime() + g_iTimeDiff
}

/* ----------------------- */

public BypassGuard_RequestSupervising(pPlayer, const szAsNumber[MAX_AS_LEN]) {
	if(!PluginMode(WORK_MODE__PERFORM_CHECKS)) {
		RecordToLogfile(LOG_MODE__DEBUG, "Checks disabled, skipping %N", pPlayer)
		return PLUGIN_CONTINUE
	}

	if(g_bInitFailed) {
		RecordToLogfile(LOG_MODE__DEBUG, "%N denied due to init failure", pPlayer)
		BypassGuard_SendSupervisingResult(pPlayer, false, SV_STATUS_SQL_ERROR, false, false)
		return PLUGIN_HANDLED
	}

	if(!g_bSystemInitialized) {
		g_bWaitCheck[pPlayer] = true
		copy(g_szQueuedAs[pPlayer], charsmax(g_szQueuedAs[]), szAsNumber)
		get_user_authid(pPlayer, g_szQueuedAuth[pPlayer], charsmax(g_szQueuedAuth[]))
		RecordToLogfile(LOG_MODE__DEBUG, "%N queued for check as system is not initialized yet", pPlayer)
		return PLUGIN_HANDLED
	}

	new szAuthID[64]
	get_user_authid(pPlayer, szAuthID, charsmax(szAuthID))

	if(IsUsableSteamID(szAuthID) && TrieKeyExists(g_tPlayerCache, szAuthID)) {
		RecordToLogfile(LOG_MODE__DEBUG, "%N allowed due to whitepass (cache)", pPlayer)
		BypassGuard_SendSupervisingResult(pPlayer, true, ALLOW_STATUSES[SV__ALLOW_CACHE], true, false)
		return PLUGIN_HANDLED
	}

	PerformPlayerCheck(pPlayer, szAuthID, szAsNumber, "direct")

	return PLUGIN_HANDLED
}

/* ----------------------- */

PerformPlayerCheck(pPlayer, const szAuthID[], const szAsNumber[], const szType[]) {
	new szAuthEsc[128], szAsEsc[MAX_AS_LEN * 2]
	QuoteSql(szAuthEsc, charsmax(szAuthEsc), szAuthID)
	QuoteSql(szAsEsc, charsmax(szAsEsc), szAsNumber)

	formatex( g_szQuery, charsmax(g_szQuery),
		"SELECT COUNT(*) as `whitepass`, \
		(SELECT COUNT(*) FROM `%s` WHERE `asn` = '%s' AND `until` > CURRENT_TIMESTAMP) as `rest_global`, \
		(SELECT COUNT(*) FROM `%s` WHERE `asn` = '%s' AND `until` > CURRENT_TIMESTAMP) as `rest_asn`, \
		(SELECT COUNT(*) FROM `%s` WHERE `until` > CURRENT_TIMESTAMP) as `strict_status` \
		FROM `%s` WHERE `steamid` = '%s' AND `until` > CURRENT_TIMESTAMP",

		g_eCvar[CVAR__TABLE_RESTRICTIONS], GLOBAL_KEY,
		g_eCvar[CVAR__TABLE_RESTRICTIONS], szAsEsc,
		g_eCvar[CVAR__TABLE_RESTRICTIONS],
		g_eCvar[CVAR__TABLE_WHITEPASSES], szAuthEsc
	);

	RecordToLogfile( LOG_MODE__DEBUG, "[QID %i] [QUERY__CHECK_PLAYER] Perform %s check for %N (ASN '%s')",
		g_eSqlData[SQL_DATA__QID] + 1, szType, pPlayer, szAsNumber );

	g_eSqlData[SQL_DATA__USERID] = get_user_userid(pPlayer)
	MakeQuery(QUERY__CHECK_PLAYER)
}

/* ----------------------- */

public BypassGuard_PlayerCheckComplete(pPlayer, bool:bAllowConnect, const ePlayerData[BG_PLAYER_DATA_STRUCT]) {
	if(!bAllowConnect) {
		return
	}

	if(!PluginMode(WORK_MODE__WRITE_WHITEPASSES)) {
		RecordToLogfile(LOG_MODE__DEBUG, "Writing whitepasses disabled, skipping %N", pPlayer)
		return
	}

	new szAuthID[64]
	get_user_authid(pPlayer, szAuthID, charsmax(szAuthID))

	if(!IsUsableSteamID(szAuthID)) {
		RecordToLogfile(LOG_MODE__DEBUG, "Skip whitepass for shared/invalid steamid '%s' (%N)", szAuthID, pPlayer)
		return
	}

	TrieSetCell(g_tPlayerCache, szAuthID, 0)

	if(!g_bSystemInitialized) {
		g_bWaitWrite[pPlayer] = true
		copy(g_szQueuedAuth[pPlayer], charsmax(g_szQueuedAuth[]), szAuthID)
		RecordToLogfile(LOG_MODE__DEBUG, "%N queued for writing whitepass as system is not initialized yet", pPlayer)
		return
	}

	WritePlayerWhitepass(pPlayer, szAuthID, "direct")
}

/* ----------------------- */

WritePlayerWhitepass(pPlayer, const szAuthID[], const szType[]) {
	if(!IsUsableSteamID(szAuthID)) {
		RecordToLogfile(LOG_MODE__DEBUG, "Skip whitepass write for shared/invalid steamid '%s' (%N)", szAuthID, pPlayer)
		return
	}

	new iSeconds = g_eCvar[CVAR__STEAMID_EXP_DAYS] * SECONDS_IN_DAY
	new szAuthEsc[128]
	QuoteSql(szAuthEsc, charsmax(szAuthEsc), szAuthID)

	formatex( g_szQuery, charsmax(g_szQuery),
		"INSERT INTO `%s` (`steamid`, `until`) VALUES ('%s', FROM_UNIXTIME(UNIX_TIMESTAMP() + %i)) \
		ON DUPLICATE KEY UPDATE `until` = FROM_UNIXTIME(UNIX_TIMESTAMP() + %i)",

		g_eCvar[CVAR__TABLE_WHITEPASSES], szAuthEsc, iSeconds, iSeconds
	);

	RecordToLogfile( LOG_MODE__DEBUG, "[QID %i] [QUERY__WRITE_WHITEPASS] Writing %s whitepass for %N",
		g_eSqlData[SQL_DATA__QID] + 1, szType, pPlayer );

	MakeQuery(QUERY__WRITE_WHITEPASS)
}

/* ----------------------- */

MakeQuery(iQueryType) {
	g_eSqlData[SQL_DATA__QUERY_TYPE] = iQueryType
	g_eSqlData[SQL_DATA__QID]++

	if(!g_hSqlTuple) {
		RecordToLogfile(LOG_MODE__DEBUG, "[QID %i] MakeQuery skipped, no SQL tuple", g_eSqlData[SQL_DATA__QID])

		if(iQueryType == QUERY__CHECK_PLAYER) {
			FailPlayerCheck(g_eSqlData[SQL_DATA__USERID])
		}

		return
	}

	SQL_ThreadQuery(g_hSqlTuple, "SQL_Handler", g_szQuery, g_eSqlData, sizeof(g_eSqlData))
}

/* ----------------------- */

public task_PruneWhitepassCache() {
	RecordToLogfile(LOG_MODE__DEBUG, "Prune whitepass cache")
	TrieClear(g_tPlayerCache)
}

/* ----------------------- */

RecordToLogfile(bitValue, const szFmt[], any:...) {
	if( g_eCvar[CVAR__LOG_MODE][0] == '0' || !(read_flags(g_eCvar[CVAR__LOG_MODE]) & bitValue) ) {
		return
	}

	static szString[256], szMsgPrefix[32]
	vformat(szString, charsmax(szString), szFmt, 3)

	switch(bitValue) {
		case LOG_MODE__GENERAL: szMsgPrefix = "[General]"
		case LOG_MODE__DETAILED: szMsgPrefix = "[Detailed]"
		case LOG_MODE__DEBUG: szMsgPrefix = "[Debug]"
		default: szMsgPrefix = "[Unknown]"
	}

	log_to_file(g_szMainLogFile, "%s %s", szMsgPrefix, szString)
}

/* ----------------------- */

public plugin_end() {
	RecordToLogfile(LOG_MODE__DEBUG, "Plugin end (query count %i)", g_eSqlData[SQL_DATA__QID])
	g_bPluginEnded = true
	remove_task(TASKID_RETRY_INIT)

	if(g_hSqlTuple) {
		SQL_FreeHandle(g_hSqlTuple)
		g_hSqlTuple = Empty_Handle
	}
}

/* ----------------------- */

PerformDelayedActions() {
	new pPlayers[MAX_PLAYERS], iPlCount, pPlayer, szAuthID[64]
	get_players(pPlayers, iPlCount, "ch")

	for(new i; i < iPlCount; i++) {
		pPlayer = pPlayers[i]

		if(g_bWaitCheck[pPlayer]) {
			g_bWaitCheck[pPlayer] = false
			copy(szAuthID, charsmax(szAuthID), g_szQueuedAuth[pPlayer])

			if(!szAuthID[0]) {
				get_user_authid(pPlayer, szAuthID, charsmax(szAuthID))
			}

			PerformPlayerCheck(pPlayer, szAuthID, g_szQueuedAs[pPlayer], "queued")
		}

		if(g_bWaitWrite[pPlayer]) {
			g_bWaitWrite[pPlayer] = false
			copy(szAuthID, charsmax(szAuthID), g_szQueuedAuth[pPlayer])

			if(!szAuthID[0]) {
				get_user_authid(pPlayer, szAuthID, charsmax(szAuthID))
			}

			WritePlayerWhitepass(pPlayer, szAuthID, "queued")
		}

		if(g_bWaitBan[pPlayer]) {
			g_bWaitBan[pPlayer] = false
			InsertQueuedBan(pPlayer)
		}
	}
}

/* ----------------------- */

/**
 * Called before ban is insrted in the ban table
 *
 * @param id                Client index - is not always valid (e.g. is not valid for offline ban, or when user is disconnected )
 * @param userid            Client userid - is not always valid ( is not valid for offline ban )
 * @param player_steamid    Client steamid
 * @param player_ip         Client IP
 * @param player_name       Client name
 * @param ban_created       Ban creation time (unix timestamp)
 * @param admin_ip        	Admin IP
 * @param admin_steamid     Admin steamid
 * @param admin_name        Admin name
 * @param ban_type          Ban type
 * @param ban_reason        Ban reason
 * @param bantime    Ban duration in seconds
 *
 * @return          This forward ignores the returned value.
 */
// NOTE: Tested on versions from 1.3.7b to 1.4.8
public fbans_player_banned_pre_f(const id, const uid,
	const player_steamid[], const player_ip[], const player_name[],
	const admin_ip[], const admin_steamid[], const admin_name[],
	const ban_type[], const ban_reason[], const bantime) {

	/*log_amx(
		"id %i, uid %i, player_steamid %s, player_ip %s, player_name %s, admin_ip %s, admin_steamid %s, admin_name %s, ban_type %s, ban_reason %s, bantime %i",
		id, uid, player_steamid, player_ip, player_name, admin_ip, admin_steamid, admin_name, ban_type, ban_reason, bantime
	);*/

	PlayerBanned(id, find_player("c", admin_steamid), bantime, "FB: fbans_player_banned_pre_f")
}

/* ----------------------- */

// Lite Bans 2.2 https://dev-cs.ru/resources/352/ with first arg (id) only
// Lite Bans 2.3f https://dev-cs.ru/resources/1631/ with id, admin_id, ban_minutes
public user_banned_pre(id, admin_id, ban_minutes) {
	// NOTE: avoid access to admin_id and ban_minutes without numargs() check, it can cause memory leaks or even a server crash!
	if(numargs() == 1) { // original 2.2
		PlayerBanned(id, -1, -1, "LB: user_banned_pre")
		return
	}

	// fork 2.3f+
	PlayerBanned(id, admin_id, ban_minutes, "LB[F]: user_banned_pre")
}

/* ----------------------- */

// AMXBans RBS https://fungun.net/shop/?p=show&id=40
// Вызывается, до начала бана игрока
// [new] forward amxbans_ban_pre(id, admin, bantime, bantype[], banreason[]);
public amxbans_ban_pre(id, admin, bantime) {
	// NOTE: avoid access to bantime without numargs() check, it can cause memory leaks or even a server crash!
	if(numargs() == 2) {
		PlayerBanned(id, admin, -1, "RBS[old]: amxbans_ban_pre")
		return
	}
	PlayerBanned(id, admin, bantime, "RBS[new]: amxbans_ban_pre")
}

/* ----------------------- */

// Diveban X Open https://github.com/cssuite/Diveban-X-Open
public divebanx_ban_pre(admin, player, minutes, const reason[]) {
	PlayerBanned(player, admin, minutes, "DiveBanX: divebanx_ban_pre")
}

/* ----------------------- */

public client_remove(pPlayer) {
	g_bBanned[pPlayer] = false
	g_bWaitCheck[pPlayer] = false
	g_bWaitWrite[pPlayer] = false
	g_bWaitBan[pPlayer] = false
	g_szQueuedAs[pPlayer][0] = 0
	g_szQueuedAuth[pPlayer][0] = 0
	g_iWaitBanAdmin[pPlayer] = 0
}

/* ----------------------- */

PlayerBanned(pPlayer, pAdmin, iBanMinutes, const szFwdName[]) {
	RecordToLogfile(LOG_MODE__DEBUG, "PlayerBanned() from %s()", szFwdName)

	if(!is_user_connected(pPlayer)) {
		RecordToLogfile(LOG_MODE__DEBUG, "Skip ban for disconnected client %i", pPlayer)
		return
	}

	if(g_bBanned[pPlayer]) {
		RecordToLogfile(LOG_MODE__DEBUG, "Skip ban for already banned client %N", pPlayer)
		return
	}

	g_bBanned[pPlayer] = true

	if(is_user_bot(pPlayer) || is_user_hltv(pPlayer)) {
		RecordToLogfile(LOG_MODE__DEBUG, "Skip ban for bot/hltv %N", pPlayer)
		return
	}

	if(!PluginMode(WORK_MODE__COUNT_BANS)) {
		RecordToLogfile(LOG_MODE__DEBUG, "Counting bans disabled, skipping %N", pPlayer)
		return
	}

	if(g_eCvar[CVAR__IGNORE_SERVER_BANS] && !pAdmin) {
		RecordToLogfile(LOG_MODE__DEBUG, "Ignoring server ban for %N", pPlayer)
		return
	}

	if(iBanMinutes > 0 && iBanMinutes < g_eCvar[CVAR__MIN_BAN_TIME]) {
		RecordToLogfile( LOG_MODE__DEBUG, "Ignoring ban by time (%i minutes, minimum is %i) for %N",
			iBanMinutes, g_eCvar[CVAR__MIN_BAN_TIME], pPlayer );

		return
	}

	if(pAdmin == -1) {
		pAdmin = 0
	}
	else if(pAdmin && !is_user_connected(pAdmin)) {
		RecordToLogfile(LOG_MODE__DEBUG, "Detected ban by disconnected admin %i (index will be changed to 0)", pAdmin)
		pAdmin = 0
	}

	if(!g_bSystemInitialized) {
		g_bWaitBan[pPlayer] = true
		g_iWaitBanAdmin[pPlayer] = pAdmin
		RecordToLogfile(LOG_MODE__DEBUG, "Queue ban for %N as system is not initialized yet", pPlayer)
		return
	}

	if(!BypassGuard_IsPlayerChecked(pPlayer)) {
		RecordToLogfile(LOG_MODE__DEBUG, "Skip ban for %N as it was not pass BG checks yet", pPlayer)
		return
	}

	new ePlayerData[BG_PLAYER_DATA_STRUCT]
	if(BypassGuard_GetPlayerData(pPlayer, ePlayerData) != 1) {
		RecordToLogfile(LOG_MODE__DEBUG, "Skip ban for %N as player data is not ready", pPlayer)
		return
	}

	WriteBanAndCount(pPlayer, pAdmin, ePlayerData[BG_PDS__AS])
}

/* ----------------------- */

InsertQueuedBan(pPlayer) {
	if(!is_user_connected(pPlayer)) {
		return
	}

	if(!BypassGuard_IsPlayerChecked(pPlayer)) {
		RecordToLogfile(LOG_MODE__DEBUG, "Skip queued ban for %N as it was not pass BG checks yet", pPlayer)
		return
	}

	new ePlayerData[BG_PLAYER_DATA_STRUCT]
	if(BypassGuard_GetPlayerData(pPlayer, ePlayerData) != 1) {
		RecordToLogfile(LOG_MODE__DEBUG, "Skip queued ban for %N as player data is not ready", pPlayer)
		return
	}

	WriteBanAndCount(pPlayer, g_iWaitBanAdmin[pPlayer], ePlayerData[BG_PDS__AS])
}

/* ----------------------- */

WriteBanAndCount(pPlayer, pAdmin, const szAsNumber[]) {
	new szAsEsc[MAX_AS_LEN * 2]
	QuoteSql(szAsEsc, charsmax(szAsEsc), szAsNumber)

	new iBanTimeGlobal = g_eCvar[CVAR__BAN_EXP_TIME_GLOBAL] * SECONDS_IN_MINUTE
	new iBanTimeAs = g_eCvar[CVAR__BAN_EXP_TIME_AS] * SECONDS_IN_MINUTE

	formatex(g_szQuery, charsmax(g_szQuery),
		"INSERT INTO `%s` (`asn`, `until_global`, `until_as`) \
			VALUES \
		('%s', FROM_UNIXTIME(UNIX_TIMESTAMP() + %i), FROM_UNIXTIME(UNIX_TIMESTAMP() + %i))",

		g_eCvar[CVAR__TABLE_BANS], szAsEsc, iBanTimeGlobal, iBanTimeAs
	);

	RecordToLogfile( LOG_MODE__DETAILED, "[QID %i] [QUERY__INSERT_BAN] Write ban for %N (ASN '%s') by admin %N",
		g_eSqlData[SQL_DATA__QID] + 1, pPlayer, szAsNumber, pAdmin );

	MakeQuery(QUERY__INSERT_BAN)

	formatex( g_szQuery, charsmax(g_szQuery),
		"SELECT COUNT(*) as `asn_counter`, \
		(SELECT COUNT(*) FROM `%s` WHERE `until_global` > CURRENT_TIMESTAMP) AS `global_counter`, \
		(SELECT UNIX_TIMESTAMP(`until`) FROM `%s` WHERE `asn` = '%s' AND `until` > CURRENT_TIMESTAMP) as `rest_global`, \
		(SELECT UNIX_TIMESTAMP(`until`) FROM `%s` WHERE `asn` = '%s' AND `until` > CURRENT_TIMESTAMP) as `rest_asn` \
		FROM `%s` WHERE `asn` = '%s' AND `until_as` > CURRENT_TIMESTAMP",

		g_eCvar[CVAR__TABLE_BANS],
		g_eCvar[CVAR__TABLE_RESTRICTIONS], GLOBAL_KEY,
		g_eCvar[CVAR__TABLE_RESTRICTIONS], szAsEsc,
		g_eCvar[CVAR__TABLE_BANS], szAsEsc
	);

	RecordToLogfile(LOG_MODE__DETAILED, "[QID %i] [QUERY__GET_BANS] ...", g_eSqlData[SQL_DATA__QID] + 1)

	copy(g_eSqlData[SQL_DATA__AS], charsmax(g_eSqlData[SQL_DATA__AS]), szAsNumber)
	MakeQuery(QUERY__GET_BANS)
}

/* ----------------------- */

bool:IsValidAS(const szAsNumber[]) {
	if(szAsNumber[0] != 'A' || szAsNumber[1] != 'S' || szAsNumber[2] < '0' || szAsNumber[2] > '9') {
		return false
	}

	for(new i = 3; i < MAX_AS_LEN; i++) {
		if(!szAsNumber[i]) {
			return true
		}

		if(szAsNumber[i] < '0' || szAsNumber[i] > '9') {
			return false
		}
	}

	return false
}

/* ----------------------- */

bool:IsUsableSteamID(const szAuthID[]) {
	if(!szAuthID[0]) {
		return false
	}

	if( equal(szAuthID, "STEAM_ID_LAN")
		|| equal(szAuthID, "STEAM_ID_PENDING")
		|| equal(szAuthID, "VALVE_ID_LAN")
		|| equal(szAuthID, "VALVE_ID_PENDING")
	) {
		return false
	}

	return true
}

/* ----------------------- */

bool:IsValidTableName(const szName[]) {
	if(!szName[0]) {
		return false
	}

	for(new i; szName[i]; i++) {
		new bool:bOk = (
			(szName[i] >= 'A' && szName[i] <= 'Z')
			|| (szName[i] >= 'a' && szName[i] <= 'z')
			|| (szName[i] >= '0' && szName[i] <= '9')
			|| szName[i] == '_'
		)

		if(!bOk) {
			return false
		}
	}

	return true
}

/* ----------------------- */

QuoteSql(szBuffer[], iMaxLen, const szString[]) {
	SQL_QuoteString(Empty_Handle, szBuffer, iMaxLen, szString)
}

/* ----------------------- */

FormatTime(szBuffer[], iMaxLen, iTimeStamp) {
	format_time(szBuffer, iMaxLen, "%m/%d/%Y - %H:%M:%S", iTimeStamp)
}

/* ----------------------- */

bool:PluginMode(bitValue) {
	return ( g_eCvar[CVAR__PLUGIN_MODE][0] != '0' && (read_flags(g_eCvar[CVAR__PLUGIN_MODE]) & bitValue) )
}

/* ----------------------- */

public concmd_RestAdd(pPlayer, bitAccess) {
	enum { arg_asn = 1, arg_minutes }

	if(!UserHasAccess(pPlayer, bitAccess)) {
		return PLUGIN_HANDLED
	}

	if(!CmdSystemReadyCheck(pPlayer)) {
		return PLUGIN_HANDLED
	}

	if(read_argc() == 1) {
		console_print(pPlayer, "* Usage: bg_sv_rest_add <AS number or *> <minutes> - Add restriction for specified ASN or globally (*)")
		return PLUGIN_HANDLED
	}

	new szAsNumber[MAX_AS_LEN]
	read_argv(arg_asn, szAsNumber, charsmax(szAsNumber))

	if(strcmp(szAsNumber, "*") == 0) {
		szAsNumber = GLOBAL_KEY
	}
	else if(!IsValidAS(szAsNumber)) {
		console_print(pPlayer, "* Wrong ASN specified, check your input!")
		return PLUGIN_HANDLED
	}

	new iRestMinutes = read_argv_int(arg_minutes)

	if(iRestMinutes < 1) {
		console_print(pPlayer, "* Wrong time value specified, check your input!")
		return PLUGIN_HANDLED
	}

	new iRestSeconds = iRestMinutes * SECONDS_IN_MINUTE
	new szAsEsc[MAX_AS_LEN * 2]
	QuoteSql(szAsEsc, charsmax(szAsEsc), szAsNumber)

	formatex( g_szQuery, charsmax(g_szQuery),
		"INSERT INTO `%s` (`asn`, `until`) VALUES ('%s', FROM_UNIXTIME(UNIX_TIMESTAMP() + %i)) \
		ON DUPLICATE KEY UPDATE `until` = FROM_UNIXTIME(UNIX_TIMESTAMP() + %i)",

		g_eCvar[CVAR__TABLE_RESTRICTIONS], szAsEsc, iRestSeconds, iRestSeconds
	);

	new iRestrictedUntil = GetSysTime() + iRestSeconds
	new szUntil[32]; FormatTime(szUntil, charsmax(szUntil), iRestrictedUntil)

	RecordToLogfile( LOG_MODE__GENERAL,	"[QID %i] [QUERY__WRITE_RESTRICTION] %N restrict '%s' for %i minutes until '%s'",
		g_eSqlData[SQL_DATA__QID] + 1, pPlayer, szAsNumber, iRestMinutes, szUntil );

	g_eSqlData[SQL_DATA__USERID] = GetCmdUserIdForQuery(pPlayer)

	console_print(pPlayer, "* Sending query...")

	MakeQuery(QUERY__WRITE_RESTRICTION)

	return PLUGIN_HANDLED
}

/* ----------------------- */

public concmd_RestDel(pPlayer, bitAccess) {
	enum { arg_asn = 1 }

	if(!UserHasAccess(pPlayer, bitAccess)) {
		return PLUGIN_HANDLED
	}

	if(!CmdSystemReadyCheck(pPlayer)) {
		return PLUGIN_HANDLED
	}

	if(read_argc() == 1) {
		console_print(pPlayer, "* Usage: bg_sv_rest_del <AS number or *> - Remove restriction for specified ASN or globally (*)")
		return PLUGIN_HANDLED
	}

	new szAsNumber[MAX_AS_LEN]
	read_argv(arg_asn, szAsNumber, charsmax(szAsNumber))

	if(strcmp(szAsNumber, "*") == 0) {
		szAsNumber = GLOBAL_KEY
	}
	else if(!IsValidAS(szAsNumber)) {
		console_print(pPlayer, "* Wrong ASN specified, check your input!")
		return PLUGIN_HANDLED
	}

	new szAsEsc[MAX_AS_LEN * 2]
	QuoteSql(szAsEsc, charsmax(szAsEsc), szAsNumber)

	formatex( g_szQuery, charsmax(g_szQuery),
		"DELETE FROM `%s` WHERE `asn` = '%s'",

		g_eCvar[CVAR__TABLE_RESTRICTIONS], szAsEsc
	);

	RecordToLogfile( LOG_MODE__GENERAL,	"[QID %i] [QUERY__REMOVE_RESTRICTION] %N remove restriction for '%s'",
		g_eSqlData[SQL_DATA__QID] + 1, pPlayer, szAsNumber );

	g_eSqlData[SQL_DATA__USERID] = GetCmdUserIdForQuery(pPlayer)

	console_print(pPlayer, "* Sending query...")

	MakeQuery(QUERY__REMOVE_RESTRICTION)

	return PLUGIN_HANDLED
}

/* ----------------------- */

public concmd_RestShow(pPlayer, bitAccess) {
	//enum { arg_page = 1 }

	if(!UserHasAccess(pPlayer, bitAccess)) {
		return PLUGIN_HANDLED
	}

	if(!CmdSystemReadyCheck(pPlayer)) {
		return PLUGIN_HANDLED
	}

	/*if(read_argc() == 1) { // for future logic (add pagination?)
		console_print(pPlayer, "* Usage: bg_sv_rest_show - Show active restrictions list")
		return PLUGIN_HANDLED
	}*/

	formatex( g_szQuery, charsmax(g_szQuery),
		"SELECT `asn`, `until` FROM `%s` WHERE `until` > CURRENT_TIMESTAMP ORDER BY `until` ASC",

		g_eCvar[CVAR__TABLE_RESTRICTIONS]
	);

	RecordToLogfile( LOG_MODE__GENERAL,	"[QID %i] [QUERY__SHOW_RESTRICTIONS] %N request restrictions list",
		g_eSqlData[SQL_DATA__QID] + 1, pPlayer );

	g_eSqlData[SQL_DATA__USERID] = GetCmdUserIdForQuery(pPlayer)

	console_print(pPlayer, "* Sending query...")

	MakeQuery(QUERY__SHOW_RESTRICTIONS)

	return PLUGIN_HANDLED
}

/* ----------------------- */

bool:UserHasAccess(pPlayer, bitAccess) {
	if(!pPlayer) {
		return true
	}

	if(get_user_flags(pPlayer) & bitAccess) {
		return true
	}

	console_print(pPlayer, "* You have no access to this command!")
	return false
}

/* ----------------------- */

bool:CmdSystemReadyCheck(pPlayer) {
	if(!g_bSystemInitialized) {
		console_print(pPlayer, "* System is not initialized yet!")
		return false
	}

	return true
}

/* ----------------------- */

GetCmdUserIdForQuery(pPlayer) {
	if(!pPlayer) {
		return -1
	}

	return get_user_userid(pPlayer)
}

/* ----------------------- */

stock bind_cvar_num(const cvar[], const value[], flags = FCVAR_NONE, const desc[] = "", bool:has_min = false, Float:min_val = 0.0, bool:has_max = false, Float:max_val = 0.0, &bind) {
	bind_pcvar_num(create_cvar(cvar, value, flags, desc, has_min, min_val, has_max, max_val), bind);
}

stock bind_cvar_float(const cvar[], const value[], flags = FCVAR_NONE, const desc[] = "", bool:has_min = false, Float:min_val = 0.0, bool:has_max = false, Float:max_val = 0.0, &Float:bind) {
	bind_pcvar_float(create_cvar(cvar, value, flags, desc, has_min, min_val, has_max, max_val), bind);
}

stock bind_cvar_string(const cvar[], const value[], flags = FCVAR_NONE, const desc[] = "", bool:has_min = false, Float:min_val = 0.0, bool:has_max = false, Float:max_val = 0.0, bind[], maxlen) {
	bind_pcvar_string(create_cvar(cvar, value, flags, desc, has_min, min_val, has_max, max_val), bind, maxlen);
}

stock bind_cvar_num_by_name(const szCvarName[], &iBindVariable) {
	bind_pcvar_num(get_cvar_pointer(szCvarName), iBindVariable);
}

stock bind_cvar_float_by_name(const szCvarName[], &Float:fBindVariable) {
	bind_pcvar_float(get_cvar_pointer(szCvarName), fBindVariable);
}