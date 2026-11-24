/* fn_commands: the command list, generated from what is actually registered.
 *
 * WHY NOT A TABLE: a hand-written list is wrong the day after it is written -
 * this tree has had /missions, /bp, /ctop, /rtv, /servers and friends come and
 * go, and the old /commands menu in freenova_hub was a static menu that had
 * already drifted. This plugin enumerates the AMXX command registry at map
 * start (get_concmdsnum + get_concmd) and builds the list from THAT:
 *
 *   - every register_clcmd("say /x") / register_clcmd("say !x") becomes "/x";
 *     "say_team" twins are folded into the same entry (a player does not need
 *     to see /rtv twice);
 *   - every register_concmd (console command) is listed too, tagged with the
 *     privilege it needs, and hidden from players who do not have it;
 *   - the topic is the plugin that registered the command (get_concmd_plid ->
 *     get_plugin), prettified ("freenova_mapvote" -> "Map vote"), so the list
 *     groups itself as plugins come and go.
 *
 * Commands:
 *   say /commands      (or !commands, /cmdlist, say_team variants)
 *   say /commands 2    page 2
 *   say /commands rtv  every command whose name or topic contains "rtv"
 *   fn_commands [page|term]   same, from the server console (also proves the
 *                             registry is readable after a deploy)
 *   fn_commands_rebuild       rebuild the list now (after pausing a plugin)
 *
 * The registry is read once in plugin_cfg (all plugins have registered their
 * commands by then) and cached, so a lookup costs nothing at map time.
 */
#include <amxmodx>
#include <amxmisc>
#include <fn_common>

#define MAX_CMDS    480
#define MAX_TOPICS  64
#define PAGE_SIZE   8
#define CMD_LEN     32
#define TOPIC_LEN   24
#define LINE_WIDTH  100

new g_szCmd[MAX_CMDS][CMD_LEN];
new g_iTopic[MAX_CMDS];                 // index into g_szTopicName
new g_iFlags[MAX_CMDS];
new g_nCmds;

new g_szTopicName[MAX_TOPICS][TOPIC_LEN];
new g_iTopicCount[MAX_TOPICS];
new g_nTopics;

new g_szInfo[MAX_CMDS][64];             // optional description from register_*cmd
new g_bBuilt;

// A few plugin names read badly when automated ("Hub", "Admincmd"), so the
// pretty name is overridden for the ones players actually see. Everything else
// falls back to the derived name.
new const g_szTopicFrom[][] =
{
	"freenova_missions", "freenova_hub", "freenova_help", "freenova_mapvote",
	"freenova_ads", "freenova_servers", "freenova_roundmusic", "freenova_competitive",
	"freenova_cosmetics", "freenova_weapons", "freenova_vip", "battlepass_core",
	"freenova_achievements", "freenova_weaponstats", "freenova_clutch", "freenova_gag",
	"freenova_admin", "admin", "admincmd", "adminchat", "adminvote", "plmenu",
	"mapsmenu", "menufront", "rsu_core", "rsu_stats", "freenova_sync",
	"freenova_prefs", "freenova_panel"
};
new const g_szTopicTo[][] =
{
	"Missions", "Menu", "Help", "Map vote",
	"Server info", "Servers", "Music", "Competitive",
	"Cosmetics", "Weapons", "VIP", "Battle Pass",
	"Achievements", "Weapon stats", "Clutch", "Moderation",
	"Admin", "Admin", "Admin", "Admin chat", "Votes", "Admin",
	"Admin", "Admin", "Stats", "Stats", "Server info",
	"Settings", "Panel"
};

public plugin_init()
{
	fn_boot_banner("commands", 6);

	register_plugin("FreeNova Commands", "1.0.0", "FreeNova");

	register_clcmd("say /commands", "CmdSayCommands");
	register_clcmd("say_team /commands", "CmdSayCommands");
	register_clcmd("say !commands", "CmdSayCommands");
	register_clcmd("say_team !commands", "CmdSayCommands");
	register_clcmd("say /cmdlist", "CmdSayCommands");
	register_clcmd("say_team /cmdlist", "CmdSayCommands");

	register_concmd("fn_commands", "CmdConsole", ADMIN_ALL, "[page|term] - list registered commands");
	register_concmd("fn_commands_rebuild", "CmdRebuild", ADMIN_CFG, "- rebuild the command list now");
}

public plugin_cfg()
{
	Build();
}

/* ---- registry -> list --------------------------------------------------- */

Build()
{
	g_nCmds = 0;
	g_nTopics = 0;

	// ADMIN_ALL is 0, so it would only return public commands; -1 matches every
	// command and the per-caller filter is applied when printing instead.
	new total = get_concmdsnum(-1, 1);       // 1 = client commands (say hooks + binds)
	if (total <= 0)
		return;

	new cmd[CMD_LEN], info[64], flags, bool:info_ml;

	for (new i = 0; i < total && g_nCmds < MAX_CMDS; i++)
	{
		cmd[0] = EOS;
		info[0] = EOS;
		flags = 0;

		if (!get_concmd(i, cmd, charsmax(cmd), flags, info, charsmax(info), -1, 1, info_ml))
			continue;

		trim(cmd);
		if (!cmd[0])
			continue;

		// "say_team /x" duplicates "say /x": one entry per command.
		if (containi(cmd, "say_team ") == 0)
			continue;

		new name[CMD_LEN];
		if (containi(cmd, "say ") == 0)
		{
			// say /missions -> missions, say !ready -> ready
			new start = 4;
			while (cmd[start] == ' ' || cmd[start] == '/' || cmd[start] == '!' || cmd[start] == '.')
				start++;
			copy(name, charsmax(name), cmd[start]);
			if (!name[0])
				continue;
		}
		else
		{
			// Registered client commands that are not chat shortcuts (the N-key
			// menu bind and similar) are still commands people can type.
			copy(name, charsmax(name), cmd);
		}

		trim(name);
		if (!name[0] || contain(name, " ") != -1)
			continue;                       // "say <text>" handlers are not commands

		if (FindCmd(name) >= 0)
			continue;                       // already listed (say + say_team + alias)

		new topic = TopicFor(i);
		new n = g_nCmds++;
		copy(g_szCmd[n], charsmax(g_szCmd[]), name);
		copy(g_szInfo[n], charsmax(g_szInfo[]), info);
		g_iTopic[n] = topic;
		g_iFlags[n] = flags;
	}

	SortByTopic();
	g_bBuilt = 1;
	log_amx("[CMDS] registry built: %d commands in %d topics", g_nCmds, g_nTopics);
}

TopicFor(cmdIndex)
{
	new pid = get_concmd_plid(cmdIndex, -1, 1);
	new file[48];
	file[0] = EOS;
	if (pid > 0)
		get_plugin(pid, file, charsmax(file));

	new pretty[TOPIC_LEN];
	PrettyTopic(file, pretty, charsmax(pretty));

	new idx = FindTopic(pretty);
	if (idx >= 0)
	{
		g_iTopicCount[idx]++;
		return idx;
	}
	if (g_nTopics >= MAX_TOPICS)
		return FindOrAddTopic("Other");

	idx = g_nTopics++;
	copy(g_szTopicName[idx], charsmax(g_szTopicName[]), pretty);
	g_iTopicCount[idx] = 1;
	return idx;
}

FindOrAddTopic(const name[])
{
	new idx = FindTopic(name);
	if (idx >= 0)
		return idx;
	if (g_nTopics >= MAX_TOPICS)
		return 0;
	idx = g_nTopics++;
	copy(g_szTopicName[idx], charsmax(g_szTopicName[]), name);
	g_iTopicCount[idx] = 0;
	return idx;
}

FindTopic(const name[])
{
	for (new i = 0; i < g_nTopics; i++)
	{
		if (equali(g_szTopicName[i], name))
			return i;
	}
	return -1;
}

FindCmd(const name[])
{
	for (new i = 0; i < g_nCmds; i++)
	{
		if (equali(g_szCmd[i], name))
			return i;
	}
	return -1;
}

/* Plugin file name -> a short human topic: strip the packaging prefixes, drop
 * the extension, turn underscores into spaces and capitalise. */
PrettyTopic(const file[], out[], len)
{
	new base[48];
	base[0] = EOS;
	copy(base, charsmax(base), file);

	// drop ".amxx"
	new dot = contain(base, ".");
	if (dot > 0)
		base[dot] = EOS;

	for (new i = 0; i < sizeof(g_szTopicFrom); i++)
	{
		if (equali(base, g_szTopicFrom[i]))
		{
			copy(out, len, g_szTopicTo[i]);
			return;
		}
	}

	new const prefixes[][] = {"freenova_", "fn_", "rsu_", "amx_", "cban_", "ab_", "simple_", "weapon_"};
	new start = 0;
	for (new i = 0; i < sizeof(prefixes); i++)
	{
		if (containi(base, prefixes[i]) == 0)
		{
			start = strlen(prefixes[i]);
			break;
		}
	}

	if (!base[start])
	{
		copy(out, len, "Other");
		return;
	}

	copy(out, len, base[start]);

	// "mapvote" -> "Mapvote" ; "map_vote" -> "Map vote". Built into a second
	// buffer: writing back into out[] while reading it truncated every name to
	// its first letter (the classic in-place alias bug).
	new pretty[TOPIC_LEN];
	new bool:upper = true;
	new c = 0;
	for (new i = 0; out[i] && c < len - 1; i++)
	{
		if (out[i] == '_')
		{
			pretty[c++] = ' ';
			upper = true;
			continue;
		}
		pretty[c++] = (upper && out[i] >= 'a' && out[i] <= 'z') ? (out[i] - 32) : out[i];
		upper = false;
	}
	pretty[c] = EOS;
	copy(out, len, pretty);
}

/* Insertion sort by (topic name, command name); the list is built once, so an
 * O(n^2) sort of ~300 entries costs nothing. */
SortByTopic()
{
	for (new i = 1; i < g_nCmds; i++)
	{
		for (new j = i; j > 0; j--)
		{
			if (CompareEntries(j - 1, j) <= 0)
				break;
			SwapEntries(j - 1, j);
		}
	}
}

CompareEntries(a, b)
{
	new c = strcmp(g_szTopicName[g_iTopic[a]], g_szTopicName[g_iTopic[b]]);
	if (c != 0)
		return c;
	return strcmp(g_szCmd[a], g_szCmd[b]);
}

SwapEntries(a, b)
{
	new tmp[CMD_LEN];
	copy(tmp, charsmax(tmp), g_szCmd[a]);
	copy(g_szCmd[a], charsmax(g_szCmd[]), g_szCmd[b]);
	copy(g_szCmd[b], charsmax(g_szCmd[]), tmp);

	copy(tmp, charsmax(tmp), g_szInfo[a]);
	copy(g_szInfo[a], charsmax(g_szInfo[]), g_szInfo[b]);
	copy(g_szInfo[b], charsmax(g_szInfo[]), tmp);

	new it = g_iTopic[a]; g_iTopic[a] = g_iTopic[b]; g_iTopic[b] = it;
	new fl = g_iFlags[a]; g_iFlags[a] = g_iFlags[b]; g_iFlags[b] = fl;
}

/* ---- access ------------------------------------------------------------ */

bool:CanSee(id, entry)
{
	if (id <= 0)
		return true;                    // server console sees everything
	new needed = g_iFlags[entry];
	if (needed == 0)
		return true;
	return (get_user_flags(id) & needed) == needed;
}

/* ---- output ------------------------------------------------------------ */

Print(id, const arg[])
{
	if (!g_bBuilt)
		Build();

	if (g_nCmds <= 0)
	{
		Say(id, "no commands are registered yet.");
		return;
	}

	// Argument: a page number, a search term, or nothing.
	new page = 0, term[32];
	term[0] = EOS;

	if (arg[0])
	{
		if (isDigitStr(arg))
			page = str_to_num(arg);
		else
			copy(term, charsmax(term), arg);
	}

	// The entries this caller may actually use.
	new visible[MAX_CMDS], n;
	for (new i = 0; i < g_nCmds; i++)
	{
		if (!CanSee(id, i))
			continue;
		if (term[0] && containi(g_szCmd[i], term) == -1 && containi(g_szTopicName[g_iTopic[i]], term) == -1)
			continue;
		visible[n++] = i;
	}

	if (!n)
	{
		Say(id, "no commands match that.");
		return;
	}

	new pages = (n + PAGE_SIZE - 1) / PAGE_SIZE;
	if (page < 1)
		page = 1;
	if (page > pages)
		page = pages;

	new start = (page - 1) * PAGE_SIZE;
	new end = min(start + PAGE_SIZE, n);

	new header[128];
	formatex(header, charsmax(header), "Commands %d-%d of %d (page %d/%d)%s",
		start + 1, end, n, page, pages, pages > 1 ? " - say /commands <page>" : "");
	Say(id, header);

	// One chat line per run of commands from the same plugin (topic), wrapped
	// so a line never blows past what the GoldSrc chat box shows.
	new k = start;
	while (k < end)
	{
		new topic = g_iTopic[visible[k]];
		new line[192];
		formatex(line, charsmax(line), "%s:", g_szTopicName[topic]);

		while (k < end && g_iTopic[visible[k]] == topic)
		{
			new piece[48];
			formatex(piece, charsmax(piece), " /%s", g_szCmd[visible[k]]);
			if (strlen(line) + strlen(piece) > LINE_WIDTH)
			{
				Say(id, line);
				line[0] = EOS;
			}
			add(line, charsmax(line), piece);
			k++;
		}

		if (line[0])
			Say(id, line);
	}
}

Say(id, const text[])
{
	if (id <= 0)
		console_print(0, "[FN] %s", text);
	else
		client_print(id, print_chat, "[FreeNova] %s", text);
}

bool:isDigitStr(const s[])
{
	if (!s[0])
		return false;
	for (new i = 0; s[i]; i++)
	{
		if (s[i] < '0' || s[i] > '9')
			return false;
	}
	return true;
}

/* ---- commands ---------------------------------------------------------- */

public CmdSayCommands(id)
{
	new arg[32];
	read_argv(1, arg, charsmax(arg));
	trim(arg);
	Print(id, arg);
	return PLUGIN_HANDLED;
}

public CmdConsole(id, level, cid)
{
	if (!cmd_access(id, level, cid, 1))
		return PLUGIN_HANDLED;
	new arg[32];
	read_argv(1, arg, charsmax(arg));
	trim(arg);
	Print(id, arg);
	return PLUGIN_HANDLED;
}

public CmdRebuild(id, level, cid)
{
	if (!cmd_access(id, level, cid, 1))
		return PLUGIN_HANDLED;

	Build();
	console_print(id, "[FN] command list rebuilt: %d commands in %d topics", g_nCmds, g_nTopics);
	return PLUGIN_HANDLED;
}
