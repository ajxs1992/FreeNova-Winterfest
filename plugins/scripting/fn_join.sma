/* fn_join: the first ten seconds on the server.
 *
 * WHAT THIS REPLACES: nothing - there was no join welcome live. The ads rotate
 * in chat (freenova_ads) and the mission stack answers when asked, but a player
 * who connects cold got no line that said "here is what you can type". That is the moment a first impression is
 * decided, and a WALL of text is the usual way to lose it: this plugin prints
 * at most TWO lines, delayed until the player is actually in the world.
 *
 *   line 1: welcome + the three pointers that matter (/help, /missions, /commands)
 *   line 2: the MOTD, which is where rules, the server list and connect
 *           information already live (only when fn_join_motd is 1)
 *
 * The MOTD itself is the existing motd.txt hook, reopened on demand with
 * /motd - so an ad, a menu or a player can point at one command instead of
 * three files.
 *
 * Everything is off-switchable: fn_join_on 0 prints nothing at all, and
 * fn_join_motd 0 drops the second line (the /motd command stays available).
 *
 * Cvars: fn_join_on 1, fn_join_delay 5.0, fn_join_motd 1,
 *        fn_join_motd_file "motd.txt"
 */
#include <amxmodx>
#include <amxmisc>
#include <fn_common>
#include <freenova_web>   // fn_open_panel(): the one MOTD-vs-menu decision

#define PLUGIN  "FreeNova Join Welcome"
#define VERSION "1.0.0"
#define AUTHOR  "FreeNova"

#define TASK_WELCOME 44100

new g_pOn, g_pDelay, g_pMotd, g_pMotdFile;

public plugin_init()
{
	fn_boot_banner("join", 6);

	register_plugin(PLUGIN, VERSION, AUTHOR);

	g_pOn       = register_cvar("fn_join_on", "1");
	g_pDelay    = register_cvar("fn_join_delay", "5.0");
	g_pMotd     = register_cvar("fn_join_motd", "1");
	g_pMotdFile = register_cvar("fn_join_motd_file", "motd.txt");

	register_clcmd("say /motd", "CmdMotd");
	register_clcmd("say_team /motd", "CmdMotd");
	register_clcmd("say !motd", "CmdMotd");
	register_clcmd("say_team !motd", "CmdMotd");
}

public client_putinserver(id)
{
	if (is_user_bot(id) || is_user_hltv(id))
		return;
	if (!get_pcvar_num(g_pOn))
		return;

	remove_task(TASK_WELCOME + id);
	new Float:delay = get_pcvar_float(g_pDelay);
	if (delay < 1.0)
		delay = 1.0;
	if (delay > 20.0)
		delay = 20.0;
	set_task(delay, "Task_Welcome", TASK_WELCOME + id);
}

public client_disconnected(id)
{
	remove_task(TASK_WELCOME + id);
}

public Task_Welcome(taskid)
{
	new id = taskid - TASK_WELCOME;
	if (id < 1 || id > MaxClients || !is_user_connected(id) || is_user_bot(id))
		return;
	if (!get_pcvar_num(g_pOn))
		return;

	new name[MAX_NAME_LENGTH];
	get_user_name(id, name, charsmax(name));

	// Line 1: the only thing a new player must know.
	client_print(id, print_chat, "[FreeNova] Welcome, %s! Say /help for the menu, /missions for dailies, /commands for every command.", name);

	// Line 2 (optional): the MOTD, which already carries the rules and the
	// network list. This is the "hook": one command, one file.
	if (get_pcvar_num(g_pMotd))
		client_print(id, print_chat, "[FreeNova] Rules, the server list and connect guides: say /motd.");
}

public CmdMotd(id)
{
	if (!is_user_connected(id) || is_user_bot(id))
		return PLUGIN_HANDLED;

	// fn_open_panel() is the single MOTD-vs-menu decision in the stack: it
	// refuses the MOTD under Low Performance Mode, when no panel is configured
	// and when the file is gone, and logs which of those it was.
	if (fn_open_panel(id, FN_PANEL_MOTD))
	{
		log_amx("[JOIN] motd shown for id=%d", id);
		return PLUGIN_HANDLED;
	}

	if (fn_panel_denied() == FN_PANEL_DENY_LPM)
	{
		// Low performance mode: no HTML, one chat line, and the menu command that
		// carries the same information.
		client_print(id, print_chat, "[FreeNova] Low performance mode is on - the MOTD stays closed. Say /help for the menu or /wintermenu for Winterfest.");
		return PLUGIN_HANDLED;
	}

	new file[64];
	get_pcvar_string(g_pMotdFile, file, charsmax(file));
	client_print(id, print_chat, "[FreeNova] The MOTD file is missing (%s) - tell an admin.", file);
	log_amx("[JOIN] motd file '%s' not found", file);
	return PLUGIN_HANDLED;
}
