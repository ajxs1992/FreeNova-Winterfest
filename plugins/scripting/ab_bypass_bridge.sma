#include <amxmodx>
#include <postgres>
#include <bypass_guard>

#define PLUGIN_NAME    "AB Bypass Bridge"
#define PLUGIN_VERSION "1.0.2"
#define PLUGIN_AUTHOR  "FreeNova"

#define TABLE_ASN      "ab_asn_hits"

new g_pCountToStrict;
new g_pMinBanTime;
new g_pEnabled;
new bool:g_bReady;

public plugin_init()
{
	register_plugin(PLUGIN_NAME, PLUGIN_VERSION, PLUGIN_AUTHOR);

	g_pEnabled = register_cvar("ab_bridge_enabled", "1");
	g_pCountToStrict = register_cvar("ab_bridge_count_to_strict", "3");
	g_pMinBanTime = register_cvar("ab_bridge_min_ban_time", "60");
}

public plugin_cfg()
{
	new szQuery[384];
	formatex(szQuery, charsmax(szQuery),
		"CREATE TABLE IF NOT EXISTS %s (as_number VARCHAR(16) NOT NULL, banned_at BIGINT NOT NULL, minutes INTEGER NOT NULL, reason VARCHAR(128) NOT NULL);",
		TABLE_ASN);
	PG_ThreadQuery("QueryGeneric", szQuery);
	g_bReady = true;
}

public QueryGeneric(failstate, query, error[], errcode, data[], datasize, Float:queuetime)
{
	if( failstate || errcode )
	{
		log_amx("[AB Bridge] SQL error: %s", error);
	}
}

public advanced_bans_player_banned(target, admin, minutes, const reason[])
{
	if( !g_bReady || !get_pcvar_num(g_pEnabled) ) return;
	if( target < 1 || !is_user_connected(target) ) return;

	new minMinutes = get_pcvar_num(g_pMinBanTime);
	if( minutes > 0 && minutes < minMinutes ) return;

	new ePlayerData[BG_PLAYER_DATA_STRUCT];
	if( BypassGuard_GetPlayerData(target, ePlayerData) != 1 ) return;

	new asNumber[MAX_AS_LEN];
	copy(asNumber, charsmax(asNumber), ePlayerData[BG_PDS__AS]);
	if( !asNumber[0] || equal(asNumber, _NA_) ) return;

	new asSafe[MAX_AS_LEN], reasonSafe[128];
	EscapeSql(asSafe, charsmax(asSafe), asNumber);
	EscapeSql(reasonSafe, charsmax(reasonSafe), reason);

	new query[384];
	formatex(query, charsmax(query),
		"INSERT INTO %s (as_number, banned_at, minutes, reason) VALUES ('%s', %d, %d, '%s');",
		TABLE_ASN, asSafe, get_systime(), minutes, reasonSafe);
	PG_ThreadQuery("QueryGeneric", query);

	new window = 7 * 24 * 60 * 60;
	formatex(query, charsmax(query),
		"SELECT COUNT(*) FROM %s WHERE as_number = '%s' AND banned_at >= %d;",
		TABLE_ASN, asSafe, get_systime() - window);

	new pack[MAX_AS_LEN];
	copy(pack, charsmax(pack), asNumber);
	PG_ThreadQuery("QueryAsnCount", query, pack, sizeof(pack));

	// %N is a SourceMod specifier; AMX Mod X has no such conversion, so this
	// line printed a raw cell value as the player name (REVIEW.md 5.5).
	new szName[MAX_NAME_LENGTH];
	get_user_name(target, szName, charsmax(szName));
	log_amx("[AB Bridge] Recorded ban on %s from %s", asNumber, szName);
}

public QueryAsnCount(failstate, query, error[], errcode, data[], datasize, Float:queuetime)
{
	if( failstate || errcode )
	{
		log_amx("[AB Bridge] ASN count query failed: %s", error);
		return;
	}

	if( !PG_NumResults(query) ) return;

	new hits = PG_ReadInt(query, 0);
	new needed = get_pcvar_num(g_pCountToStrict);
	if( needed <= 0 || hits < needed ) return;

	new asNumber[MAX_AS_LEN];
	copy(asNumber, charsmax(asNumber), data);
	if( !asNumber[0] ) return;

	server_cmd("bg_as_blacklist_add %s ^"auto: %d Advanced Bans hits / 7d^"", asNumber, hits);
	log_amx("[AB Bridge] Auto-restricted %s after %d qualifying bans in 7 days", asNumber, hits);
}

EscapeSql(szOut[], iMax, const szIn[])
{
	copy(szOut, iMax, szIn);
	replace_all(szOut, iMax, "'", "''");
}
