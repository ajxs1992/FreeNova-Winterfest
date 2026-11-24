#include <amxmodx>
#include <amxmisc>
#include <cban_main>

#define DEFAULT_SCREENSHOTS		3

enum _:eScreenData
{
	ADMIN_NAME[MAX_NAME_LENGTH * 2],
	PLAYER_NAME[MAX_NAME_LENGTH],
	PLAYER_IP[MAX_IP_LENGTH],
	PLAYER_STEAMID[MAX_STEAMID_LENGTH],
	SS_NUMBER,
	SS_TAKEN,
	SS_USERID
}

new const TASK_SS = 4213
#define SCREEN_DATA_SIZE (MAX_NAME_LENGTH * 2 + MAX_NAME_LENGTH + MAX_IP_LENGTH + MAX_STEAMID_LENGTH + 3)

public plugin_init()
{
	register_plugin("[CBAN] Screenshots", VERSION, "DusT");

	register_concmd("amx_ss", "CmdScreenshot", ADMIN_FLAG_SCREENSHOTS, "< nick | steamid | #id > [ screens ] - take screenshots on player.");
}

public plugin_natives()
{
	register_native("CBan_TakeScreenshot", "_CBan_TakeScreenshot");
}

public CmdScreenshot(id, level, cid)
{
	if( !cmd_access(id, level, cid, 2) )
		return PLUGIN_HANDLED;

	new target[32];
	read_argv(1, target, charsmax(target));

	new pid = cmd_target(id, target, CMDTARGET_ALLOW_SELF | CMDTARGET_OBEY_IMMUNITY);

	if( !pid )
		return PLUGIN_HANDLED;

	new screens;
	if( read_argc() > 2 )
		screens = read_argv_int(2);

	Screenshot(id, pid, screens);
	return PLUGIN_HANDLED;
}

Screenshot(admin, player, screens = 0)
{
	if( !player || !is_user_connected(player) )
	{
		if( admin > 0 && is_user_connected(admin) )
			console_print(admin, "Player is not connected!");
		return;
	}

	if( screens <= 0 )
		screens = DEFAULT_SCREENSHOTS;

	new eData[eScreenData];
	if( admin > 0 && is_user_connected(admin) )
		get_user_name(admin, eData[ADMIN_NAME], charsmax(eData[ADMIN_NAME]));
	else
		copy(eData[ADMIN_NAME], charsmax(eData[ADMIN_NAME]), "SERVER");

	get_user_name(player, eData[PLAYER_NAME], charsmax(eData[PLAYER_NAME]));
	get_user_ip(player, eData[PLAYER_IP], charsmax(eData[PLAYER_IP]));
	get_user_authid(player, eData[PLAYER_STEAMID], charsmax(eData[PLAYER_STEAMID]));

	eData[SS_NUMBER] = screens;
	eData[SS_USERID] = get_user_userid(player);

	client_cmd(player, "net_graph 3; wait;");
	client_cmd(player, "stop; wait;");

	set_task(0.3, "PrepareScreen", player + 2000, eData, SCREEN_DATA_SIZE);
}

public PrepareScreen(eData[], taskid)
{
	new id = taskid - 2000;
	if( id < 1 || !is_user_connected(id) )
		return;
	if( get_user_userid(id) != eData[SS_USERID] )
		return;
	new auth[MAX_STEAMID_LENGTH];
	get_user_authid(id, auth, charsmax(auth));
	if( eData[PLAYER_STEAMID][0] && !equal(auth, eData[PLAYER_STEAMID]) )
		return;

	static szServerName[MAX_NAME_LENGTH * 2];
	if( !szServerName[0] )
		get_user_name(0, szServerName, charsmax(szServerName));

	eData[SS_TAKEN]++;

	new szDate[64];
	format_time(szDate, charsmax(szDate), "%d/%m/%Y - %H:%M:%S");

	client_print_color(id, print_team_red, "^4[CBAN]^1 Admin ^3%s^1 took a screenshot of you!", eData[ADMIN_NAME]);
	client_print_color(id, print_team_red, "^4[CBAN]^1 SS Number: ^3%d^1/%d. Date: ^3%s^1", eData[SS_TAKEN], eData[SS_NUMBER], szDate);
	// %n is not an AMXX format specifier: the format native raises run time
	// error 10 on it (measured, tools/lint-plugins.py rule 2), which aborted the
	// rest of this function. Resolve the name and pass it as %s.
	new szPlayerName[MAX_NAME_LENGTH];
	get_user_name(id, szPlayerName, charsmax(szPlayerName));
	client_print_color(id, print_team_red, "^4[CBAN]^1 Name: ^3%s^1 IP: ^3%s^1 SteamID: ^3%s^1", szPlayerName, eData[PLAYER_IP], eData[PLAYER_STEAMID]);
	client_print_color(id, print_team_red, "^4[CBAN]^1 This is a ^4Screenshot^1 taken on ^4%s^1 ^n", szServerName);

	set_task(0.1, "TakeScreenshots", id + TASK_SS);

	if( eData[SS_TAKEN] < eData[SS_NUMBER] )
		set_task(0.4, "PrepareScreen", id + 2000, eData, SCREEN_DATA_SIZE);
}

public TakeScreenshots(id)
{
	new player = id - TASK_SS;
	if( player < 1 || !is_user_connected(player) ) return;
	client_cmd(player, "snapshot;wait;");
}

public _CBan_TakeScreenshot(plugin, argc)
{
	Screenshot(get_param(1), get_param(2), get_param(3));
}

public CBan_OnPlayerBannedPre(player, admin, &banLength, const banReason[MAX_REASON_LENGTH])
{
	Screenshot(admin, player);
	return PLUGIN_CONTINUE;
}
