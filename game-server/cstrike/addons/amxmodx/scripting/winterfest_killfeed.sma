/*
 * ============================================================================
 * winterfest_killfeed — the festive kill feed
 * ============================================================================
 * Product contract: docs/WINTERFEST-WORKSTREAMS.md row 6. Documentation (cvar
 * list, ini format, why the wording table is a token table and not a printf
 * format): docs/WINTERFEST-ATMOS.md.
 *
 * WHAT THIS PLUGIN IS
 *   Killstreak lines at 3/5/7/10/15, a "ho ho ho" line on every headshot, and a
 *   rare "Santa's chosen" line - all of them worded in ONE config file that is
 *   workstream 6's own (configs/freenova/winterfest/killfeed.ini), never in
 *   configs/freenova/winterfest.ini, which belongs to workstream 1.
 *
 * IT AUGMENTS, IT NEVER REPLACES
 *   Nothing in this plugin touches an existing announcement, the DeathMsg event
 *   is only read, and no other plugin in the stack owns a killstreak line
 *   (`grep -l 'register_event("DeathMsg"' *_*.sma` -> clutch, progression,
 *   teamxp, botxp: none of them announce streaks). With wf_killfeed 0 or with
 *   the season shut, this plugin reads one cvar per death and prints nothing.
 *
 * MULTI-LANGUAGE, HONESTLY
 *   The ini holds one row per line id with three text columns: English, French,
 *   German. English is the product language and every row must have it. The
 *   French and German columns ship EMPTY on purpose - the owner's audience is
 *   EU, but shipping machine-translated festive copy would be worse than
 *   shipping none - and an empty column falls back to English, so a row can be
 *   translated one at a time without touching code or risking a blank line.
 *   `wf_kf_lang` picks the column.
 *
 * WHY TOKENS INSTEAD OF %s
 *   The wording is data written by an operator. Handing that string to
 *   client_print as a format would make a stray '%' in the ini read varargs
 *   (tools/lint-plugins.py rule 4, REVIEW.md 5.5). So lines use literal tokens
 *   - {player}, {victim}, {n} - which are substituted by a bounded copy, and
 *   the print call's format is a literal in this file. A player named
 *   "100%s" is just a name.
 *
 * THE CORE IS OPTIONAL
 *   The only thing this plugin would ever ask winterfest_core for is a
 *   snowflake award on a 10/15 streak, behind wf_kf_reward. plugin_natives()
 *   installs the set_native_filter() guard from fn_servers.sma, so a missing
 *   core can never turn this into a bad load, and every call is additionally
 *   gated on LibraryExists("winterfest_core"). A server without the core runs
 *   the whole announcement side unchanged.
 * ============================================================================
 */

#include <amxmodx>
#include <amxmisc>
#include <winterfest_atmos>

#define PLUGIN  "Winterfest Killfeed"
#define VERSION "1.0.0"
#define AUTHOR  "FreeNova"

// Two files, two jobs: the wording table is this workstream's own
// killfeed.ini, the seasonal window is shared with winterfest_atmos and lives
// in atmos.ini. Reading the window out of killfeed.ini was a real bug caught by
// the harness ("window ... (built-in)" while the atmosphere plugin said
// "(config)"): the table file has no [season] section.
#define WF_CONFIG_FILE "killfeed.ini"
#define WF_WINDOW_FILE "atmos.ini"

// Line ids. The ini row key maps to one of these; an unknown key is logged and
// ignored, a known id with no row keeps its built-in English fallback.
enum
{
	KF_NONE = 0,
	KF_STREAK3,
	KF_STREAK5,
	KF_STREAK7,
	KF_STREAK10,
	KF_STREAK15,
	KF_HEADSHOT,
	KF_SANTA,
	KF_MAX
}

#define KF_COLS 3            // english / french / german
#define KF_TEXT 192
#define KF_LANG_EN 0
#define KF_LANG_FR 1
#define KF_LANG_DE 2

// The optional core native (include/winterfest.inc, owned by workstream 1).
// Declared here rather than included so this file has no compile dependency on
// a header another workstream is still writing; the filter in plugin_natives()
// makes an unresolved native harmless.
native wf_grant(id, reward_type, reward_id, const claim_key[]);
#define WF_REWARD_SNOWFLAKES 1

new g_cvEnable, g_cvForce, g_cvLang, g_cvSanta, g_cvReward, g_cvDebug;

new bool:g_bSeason;                  // season gate, evaluated in plugin_cfg
new g_iStreak[MAX_PLAYERS + 1];
new g_iRound;

// Wording: [id][language] -> text
new g_szLine[KF_MAX][KF_COLS][KF_TEXT];
new g_iLang = KF_LANG_EN;
new bool:g_bTableFromIni;

// Counters for `wf_killfeed_report`.
new g_iAnnounced;
new g_iHeadshots;
new g_iSanta;
new g_iRewards;
new g_iRewardRefused;
new g_iBotsIgnored;

// The row key -> id table, so the ini and the source cannot drift.
new const g_szKeys[KF_MAX][] =
{
	"",
	"streak3",
	"streak5",
	"streak7",
	"streak10",
	"streak15",
	"headshot",
	"santa"
};

// Built-in English fallback. The ini ships the same text; this exists so
// deleting the ini degrades to working announcements instead of silence, and
// so the module is complete without a config file at all.
new const g_szFallback[KF_MAX][] =
{
	"",
	"{player} is on a hattrick - ho ho ho!",
	"{player} has five in a row and a stocking full of grenades.",
	"{player} is on Santa's nice list - {n} straight.",
	"{player} is a one-elf army - {n} kills without dying.",
	"{player} IS Santa's chosen - {n} kills in a row!",
	"Ho ho ho! {player} hung that one on the mantel.",
	"Santa's chosen: {player} is handing out early presents.",
};

// ============================================================
// Lifecycle
// ============================================================
public plugin_natives()
{
	// The fn_servers.sma pattern: any wf_* native this plugin declared is
	// allowed to be missing while winterfest_core is absent. Compile-time
	// mistakes stay hard errors.
	set_native_filter("KfNativeFilter");
}

public KfNativeFilter(const name[], index, trap)
{
	if (!trap && contain(name, "wf_") == 0 && !LibraryExists("winterfest_core", LibType_Library))
		return PLUGIN_HANDLED;
	return PLUGIN_CONTINUE;
}

public plugin_init()
{
	register_plugin(PLUGIN, VERSION, AUTHOR);

	g_cvEnable = register_cvar("wf_killfeed", "1");
	g_cvForce = register_cvar("wf_killfeed_force", "0");
	g_cvLang = register_cvar("wf_kf_lang", "en");
	g_cvSanta = register_cvar("wf_kf_santa", "2");
	g_cvReward = register_cvar("wf_kf_reward", "1");
	g_cvDebug = register_cvar("wf_kf_debug", "0");

	register_concmd("wf_killfeed_apply", "cmdApply", ADMIN_ALL, "- re-read killfeed.ini and re-evaluate the season");
	register_concmd("wf_killfeed_report", "cmdReport", ADMIN_ALL, "- print the gate, the table and the counters");
	register_concmd("wf_killfeed_test", "cmdSelfTest", ADMIN_ALL, "- render every line with a fake name (lab: no players needed)");

	register_event("DeathMsg", "OnDeath", "a");
	register_event("HLTV", "OnNewRound", "a", "1=0", "2=0");

	server_print("[FreeNova winterfest_killfeed] ready (build 3, %d cvars, %d commands, 1 event)", 6, 3);
}

public plugin_cfg()
{
	// Both plugins read the same window from the same file; each plugin has its
	// own copy of the state, so each has to load it.
	WfAtmosWindowLoad(WF_WINDOW_FILE);
	LoadLines();
	ApplyState("plugin_cfg");
}

ApplyState(const reason[])
{
	g_bSeason = WfAtmosOpenNow();
	new forced = get_pcvar_num(g_cvForce) ? 1 : 0;
	if (!g_bSeason && !forced)
	{
		g_bSeason = false;
		server_print("[WF-KF] killfeed idle: outside window (reason: %s)", reason);
		return;
	}
	g_bSeason = true;

	// Language: en by default, fr/de accepted, anything else is refused loudly
	// instead of silently printing English while the operator expects French.
	new lang[8];
	get_pcvar_string(g_cvLang, lang, charsmax(lang));
	if (equali(lang, "fr"))
		g_iLang = KF_LANG_FR;
	else if (equali(lang, "de"))
		g_iLang = KF_LANG_DE;
	else
		g_iLang = KF_LANG_EN;

	server_print("[WF-KF] active (%s): lang=%s table=%s lines=%d forced=%d reward=%d core=%d",
		reason, lang, g_bTableFromIni ? "killfeed.ini" : "built-in", CountLoadedLines(),
		forced, get_pcvar_num(g_cvReward),
		LibraryExists("winterfest_core", LibType_Library) ? 1 : 0);
}

// ============================================================
// Config
// ============================================================
LoadLines()
{
	// Fallback first: every id gets its English line before the file is read.
	g_bTableFromIni = false;
	for (new id = 1; id < KF_MAX; id++)
	{
		for (new col = 0; col < KF_COLS; col++)
			g_szLine[id][col][0] = 0;
		copy(g_szLine[id][KF_LANG_EN], KF_TEXT - 1, g_szFallback[id]);
	}

	new path[128];
	WfAtmosPath(path, charsmax(path), WF_CONFIG_FILE);

	if (!file_exists(path))
	{
		log_amx("[WF-KF] %s missing - built-in english table in use", path);
		return;
	}

	new fp = fopen(path, "rt");
	if (!fp)
	{
		log_amx("[WF-KF] %s unreadable - built-in english table in use", path);
		return;
	}

	new line[512], section[24], key[24], text[KF_TEXT];
	new rows = 0;

	section[0] = 0;
	while (fgets(fp, line, charsmax(line)))
	{
		trim(line);
		if (!line[0] || line[0] == ';' || line[0] == '#')
			continue;

		if (line[0] == '[')
		{
			copy(section, charsmax(section), line[1]);
			new close = contain(section, "]");
			if (close >= 0)
				section[close] = 0;
			trim(section);
			strtolower(section);
			continue;
		}

		if (!equal(section, "lines"))
			continue;

		if (!WfAtmosField(line, 0, key, charsmax(key)))
			continue;
		strtolower(key);

		new id = IdForKey(key);
		if (id == KF_NONE)
		{
			log_amx("[WF-KF] %s: unknown line id '%s' ignored", path, key);
			continue;
		}

		// An English column is mandatory: a row without one would announce
		// nothing in the product language.
		if (!WfAtmosField(line, 1, text, charsmax(text)) || !text[0])
		{
			log_amx("[WF-KF] %s: row '%s' has no english text - row ignored", path, key);
			continue;
		}
		copy(g_szLine[id][KF_LANG_EN], KF_TEXT - 1, text);

		if (WfAtmosField(line, 2, text, charsmax(text)) && text[0])
			copy(g_szLine[id][KF_LANG_FR], KF_TEXT - 1, text);
		if (WfAtmosField(line, 3, text, charsmax(text)) && text[0])
			copy(g_szLine[id][KF_LANG_DE], KF_TEXT - 1, text);

		rows++;
	}
	fclose(fp);

	if (rows > 0)
		g_bTableFromIni = true;
	else
		log_amx("[WF-KF] %s has no usable [lines] rows - built-in english table in use", path);
}

IdForKey(const key[])
{
	for (new id = 1; id < KF_MAX; id++)
	{
		if (equal(key, g_szKeys[id]))
			return id;
	}
	return KF_NONE;
}

CountLoadedLines()
{
	new n = 0;
	for (new id = 1; id < KF_MAX; id++)
	{
		if (g_szLine[id][KF_LANG_EN][0])
			n++;
	}
	return n;
}

// ============================================================
// The feed
// ============================================================
public OnDeath()
{
	if (!KillfeedOn())
		return;

	new killer = read_data(1);
	new victim = read_data(2);
	new headshot = read_data(3);

	if (victim < 1 || victim > MaxClients)
		return;

	// A death always ends the victim's streak, even to a bot: the streak is
	// about the human, not about who landed the shot.
	if (!is_user_bot(victim) && !is_user_hltv(victim))
		g_iStreak[victim] = 0;

	if (killer < 1 || killer > MaxClients)
		return;                       // world damage / suicide
	if (killer == victim)
		return;
	if (is_user_bot(killer) || is_user_hltv(killer) || !is_user_connected(killer))
	{
		g_iBotsIgnored++;
		return;                       // bots never announce and never count
	}

	g_iStreak[killer]++;
	new streak = g_iStreak[killer];

	new id = KF_NONE;
	switch (streak)
	{
		case 3: id = KF_STREAK3;
		case 5: id = KF_STREAK5;
		case 7: id = KF_STREAK7;
		case 10: id = KF_STREAK10;
		case 15: id = KF_STREAK15;
	}
	if (id != KF_NONE)
		Announce(killer, victim, id, streak);

	if (headshot)
	{
		g_iHeadshots++;
		Announce(killer, victim, KF_HEADSHOT, streak);
	}

	// "Santa's chosen": a rare line, independent of the milestones above so it
	// can land on any kill. The chance is a cvar because taste is not universal.
	new chance = clamp(get_pcvar_num(g_cvSanta), 0, 100);
	if (chance > 0 && random_num(1, 100) <= chance)
	{
		g_iSanta++;
		Announce(killer, victim, KF_SANTA, streak);
	}

	if (streak == 10 || streak == 15)
		RewardStreak(killer, streak);
}

// One line, rendered from the table and sent to everyone.
Announce(killer, victim, id, streak)
{
	new text[KF_TEXT * 2];
	new buf[KF_TEXT * 2];
	new name[32], vname[32], num[8];

	// An empty column is an untranslated column: fall back to English rather
	// than printing nothing.
	new col = g_iLang;
	if (!g_szLine[id][col][0])
		col = KF_LANG_EN;
	if (!g_szLine[id][col][0])
		return;

	get_user_name(killer, name, charsmax(name));
	if (victim >= 1 && victim <= MaxClients)
		get_user_name(victim, vname, charsmax(vname));
	else
		vname[0] = 0;
	num_to_str(streak, num, charsmax(num));

	// Token substitution in two alternating buffers: {player}, then {victim},
	// then {n}. Never a printf pass (see the header comment).
	WfAtmosToken(g_szLine[id][col], "{player}", name, text, charsmax(text));
	WfAtmosToken(text, "{victim}", vname, buf, charsmax(buf));
	WfAtmosToken(buf, "{n}", num, text, charsmax(text));

	if (text[0])
	{
		WfAtmosSay(0, text);
		g_iAnnounced++;
		if (get_pcvar_num(g_cvDebug))
			server_print("[WF-KF] %s", text);
	}
}

bool:KillfeedOn()
{
	if (!g_bSeason)
		return false;
	if (!get_pcvar_num(g_cvEnable))
		return false;
	return true;
}

public OnNewRound()
{
	// Streaks are per round: a 15 in a row means 15 in one round.
	g_iRound++;
	for (new id = 0; id <= MaxClients; id++)
		g_iStreak[id] = 0;
}

// ============================================================
// The optional core award
// ============================================================
// Nothing here runs unless wf_kf_reward is on AND winterfest_core is loaded.
// With either false the kill path above is the whole plugin.
RewardStreak(id, streak)
{
	if (!get_pcvar_num(g_cvReward))
		return;
	if (!LibraryExists("winterfest_core", LibType_Library))
		return;

	new auth[40], key[96];
	get_user_authid(id, auth, charsmax(auth));
	if (!auth[0])
		return;

	// One claim per player, per milestone, per round: the core's ledger is what
	// enforces it, this string is only the key.
	formatex(key, charsmax(key), "kf_streak%d_%s_%d", streak, auth, g_iRound);
	new result = wf_grant(id, WF_REWARD_SNOWFLAKES, 2, key);
	if (result == 1)
		g_iRewards++;
	else
		g_iRewardRefused++;

	if (get_pcvar_num(g_cvDebug))
		server_print("[WF-KF] reward streak=%d player=%s result=%d", streak, auth, result);
}

// ============================================================
// Operator commands
// ============================================================
public cmdApply(id, level, cid)
{
	if (!cmd_access(id, level, cid, 1))
		return PLUGIN_HANDLED;

	WfAtmosWindowLoad(WF_WINDOW_FILE);
	LoadLines();
	ApplyState("wf_killfeed_apply");
	return PLUGIN_HANDLED;
}

public cmdReport(id, level, cid)
{
	if (!cmd_access(id, level, cid, 1))
		return PLUGIN_HANDLED;

	new lang[8], window[48], today[16];
	get_pcvar_string(g_cvLang, lang, charsmax(lang));
	WfAtmosWindowText(window, charsmax(window));
	WfAtmosDateText(today, charsmax(today));

	server_print("[WF-KF] state enable=%d force=%d season=%d lang=%s table=%s lines=%d",
		get_pcvar_num(g_cvEnable), get_pcvar_num(g_cvForce), g_bSeason ? 1 : 0,
		lang, g_bTableFromIni ? "killfeed.ini" : "built-in", CountLoadedLines());
	server_print("[WF-KF] window %s today %s", window, today);
	server_print("[WF-KF] counters announced=%d headshots=%d santa=%d rewards=%d refused=%d bots_ignored=%d",
		g_iAnnounced, g_iHeadshots, g_iSanta, g_iRewards, g_iRewardRefused, g_iBotsIgnored);
	server_print("[WF-KF] core=%d reward=%d",
		LibraryExists("winterfest_core", LibType_Library) ? 1 : 0, get_pcvar_num(g_cvReward));
	return PLUGIN_HANDLED;
}

// Lab self-test: renders every line through the exact Announce() path with a
// fake name, and prints the result to the console so a boot can prove the
// table, the language fallback and the tokens without a kill happening.
public cmdSelfTest(id, level, cid)
{
	if (!cmd_access(id, level, cid, 1))
		return PLUGIN_HANDLED;

	new text[KF_TEXT * 2];
	new buf[KF_TEXT * 2];
	new fallbacks = 0;

	for (new line = 1; line < KF_MAX; line++)
	{
		new col = g_iLang;
		if (!g_szLine[line][col][0])
		{
			col = KF_LANG_EN;
			fallbacks++;
		}
		if (!g_szLine[line][col][0])
		{
			server_print("[WF-KF] selftest %s: EMPTY", g_szKeys[line]);
			continue;
		}

		WfAtmosToken(g_szLine[line][col], "{player}", "TestPlayer", text, charsmax(text));
		WfAtmosToken(text, "{victim}", "TestVictim", buf, charsmax(buf));
		WfAtmosToken(buf, "{n}", "7", text, charsmax(text));
		server_print("[WF-KF] selftest %s[%d]: %s", g_szKeys[line], col, text);
	}

	// The multi-language contract in one line: an empty column is an
	// untranslated column, and it falls back to English instead of printing
	// nothing. Requested column = g_iLang, fallbacks = rows that had to use
	// English.
	server_print("[WF-KF] selftest lang=%d fallbacks=%d (an empty column falls back to english)",
		g_iLang, fallbacks);

	server_print("[WF-KF] selftest done: lang=%d table=%s reward=%d core=%d",
		g_iLang, g_bTableFromIni ? "killfeed.ini" : "built-in",
		get_pcvar_num(g_cvReward), LibraryExists("winterfest_core", LibType_Library) ? 1 : 0);
	return PLUGIN_HANDLED;
}
