/* fn_balance: put players where the game is fair, and say so before doing it.
 *
 * Rules (docs/SERVER-FEEL.md):
 *   - 3 wins in a row (fn_bal_streak)  -> scramble both teams;
 *   - a 2-player advantage (fn_bal_advantage) -> move one player off the bigger
 *     team onto the smaller one.
 *
 * The two things that matter for "feel":
 *
 *  1. NOTHING is silent. The plan is announced in chat the moment the round
 *     ends, and the switch happens fn_bal_notice seconds later during the same
 *     intermission, so the round that spawns afterwards starts balanced and
 *     everybody saw it coming ("Moving Bandit to Terrorist in 4 seconds").
 *  2. Moving a BOT is free; moving a HUMAN is a cost, so a move takes a bot from
 *     the bigger team whenever one is there, and only then the human who has
 *     been connected the shortest time (the least invested in the current team).
 *     fn_bal_bots 0 makes it humans-only, for operators who never want bots to
 *     be moved by anything but YaPB.
 *
 * A scramble shuffles every eligible player onto even teams; a move fixes one
 * seat. Both reset the streak that caused them, so the server cannot scramble
 * on every round afterwards.
 *
 * It stays out of the way of real modes: while fn_mode reports an active mode
 * (warm-up, an event window, an admin mode profile) the balance logic skips the
 * round entirely instead of fighting it for control of the teams.
 *
 * Console: fn_bal_now (ADMIN_CFG) - force a scramble now; fn_bal (ADMIN_CFG) - state
 */
#include <amxmodx>
#include <amxmisc>
#include <cstrike>
#include <fn_common>
#include <fn_mode>

#define PLUGIN  "FreeNova Team Balance"
#define VERSION "1.0.0"
#define AUTHOR  "FreeNova"

#define PLAN_NONE     0
#define PLAN_MOVE     1
#define PLAN_SCRAMBLE 2

#define TASK_APPLY 43100

new g_pOn, g_pStreak, g_pAdvantage, g_pNotice, g_pBots;

new const g_szTeam[3][] = {"UNASSIGNED", "Terrorist", "CT"};   // index = CsTeams
new g_iLastScore[3];             // index 1 = T, 2 = CT
new g_iStreakT, g_iStreakCT;
new g_iPlan;                     // PLAN_*
new g_iPlanTarget;               // PLAN_MOVE: player to move
new g_iPlanTeam;                 // PLAN_MOVE: destination team
new g_bSkipLogged;

public plugin_init()
{
	fn_boot_banner("balance", 6);

	register_plugin(PLUGIN, VERSION, AUTHOR);

	g_pOn        = register_cvar("fn_bal_on", "1");
	g_pStreak    = register_cvar("fn_bal_streak", "3");
	g_pAdvantage = register_cvar("fn_bal_advantage", "2");
	g_pNotice    = register_cvar("fn_bal_notice", "4.0");
	g_pBots      = register_cvar("fn_bal_bots", "1");

	register_event("TeamScore", "team_score", "a");
	register_logevent("RoundEnd", 2, "1=Round_End");

	register_concmd("fn_bal_now", "cmdScrambleNow", ADMIN_CFG, "- scramble the teams at this round end");
	register_concmd("fn_bal", "cmdStatus", ADMIN_CFG, "- team balance state (streaks, counts, plan)");
}

public team_score()
{
	// The TeamScore message carries a ONE-CHARACTER team id ("C" / "T") and the
	// new score - the same thing mapchooser, statsx and rsu_matchstats read.
	// Comparing the buffer to "CT" never matched, which made every score look
	// like a Terrorist win and would have scrambled the wrong team.
	new team[2];
	read_data(1, team, charsmax(team));
	new score = read_data(2);

	new idx = (team[0] == 'C') ? 2 : 1;

	if (score > g_iLastScore[idx] && g_iLastScore[idx] >= 0)
	{
		if (idx == 2)
		{
			g_iStreakCT++;
			g_iStreakT = 0;
		}
		else
		{
			g_iStreakT++;
			g_iStreakCT = 0;
		}
	}
	g_iLastScore[idx] = score;
}

public RoundEnd()
{
	if (!get_pcvar_num(g_pOn))
		return;

	if (g_iPlan != PLAN_NONE)
		return;                             // a plan from the previous round is still pending

	new humans = CountHumans();
	if (humans < 1)
		return;

	new mode[32];
	if (LibraryExists("fn_mode", LibType_Library) && fn_mode_active(mode, charsmax(mode)))
	{
		if (!g_bSkipLogged)
		{
			g_bSkipLogged = 1;
			log_amx("[BAL] skipping team balance while mode '%s' is active", mode);
		}
		return;
	}
	g_bSkipLogged = 0;

	new t = CountTeam(CS_TEAM_T);
	new ct = CountTeam(CS_TEAM_CT);
	new diff = t - ct;
	if (diff < 0)
		diff = -diff;

	new advantage = get_pcvar_num(g_pAdvantage);
	new streak = get_pcvar_num(g_pStreak);

	// Seat fix first: it is the least disruptive thing that can be done.
	if (advantage > 0 && diff >= advantage)
	{
		PlanMove(t > ct ? CS_TEAM_T : CS_TEAM_CT, t > ct ? CS_TEAM_CT : CS_TEAM_T, t, ct);
		return;
	}

	if (streak > 0 && (g_iStreakCT >= streak || g_iStreakT >= streak))
		PlanScramble(g_iStreakCT >= streak ? "CT" : "T", g_iStreakCT >= streak ? g_iStreakCT : g_iStreakT, t, ct);
}

/* ---- plans -------------------------------------------------------------- */

PlanMove(CsTeams:fromTeam, CsTeams:toTeam, t, ct)
{
	new id = PickMoveCandidate(CsTeams:fromTeam);
	if (!id)
		return;

	g_iPlan = PLAN_MOVE;
	g_iPlanTarget = id;
	g_iPlanTeam = _:toTeam;

	new name[MAX_NAME_LENGTH];
	get_user_name(id, name, charsmax(name));

	client_print(0, print_chat,
		"[FreeNova] Teams are uneven (%d v %d): moving %s%s to %s in %.0f seconds.",
		ct, t, name, is_user_bot(id) ? " (bot)" : "", g_szTeam[_:toTeam], get_pcvar_float(g_pNotice));

	set_task(NoticeDelay(), "ApplyPlan", TASK_APPLY);
	log_amx("[BAL] plan move: %s (%s) %s -> %s, teams %d v %d",
		name, is_user_bot(id) ? "bot" : "human", g_szTeam[_:fromTeam], g_szTeam[_:toTeam], t, ct);
}

PlanScramble(const winner[], streak, t, ct)
{
	g_iPlan = PLAN_SCRAMBLE;
	g_iPlanTarget = 0;

	client_print(0, print_chat,
		"[FreeNova] %s has won %d rounds in a row (%d v %d): teams will be scrambled in %.0f seconds.",
		winner, streak, ct, t, get_pcvar_float(g_pNotice));

	set_task(NoticeDelay(), "ApplyPlan", TASK_APPLY);
	log_amx("[BAL] plan scramble: winner=%s streak=%d teams %d v %d", winner, streak, t, ct);
}

public ApplyPlan()
{
	if (g_iPlan == PLAN_NONE)
		return;

	if (g_iPlan == PLAN_MOVE)
	{
		ApplyMove();
	}
	else
	{
		ApplyScramble();
	}

	g_iPlan = PLAN_NONE;
	g_iPlanTarget = 0;
}

ApplyMove()
{
	new id = g_iPlanTarget;
	if (!id || !is_user_connected(id))
		return;

	cs_set_user_team(id, CsTeams:g_iPlanTeam);

	new name[MAX_NAME_LENGTH];
	get_user_name(id, name, charsmax(name));
	client_print(0, print_chat, "[FreeNova] %s moved to %s.", name, g_szTeam[g_iPlanTeam]);
	log_amx("[BAL] moved %s to %s", name, g_szTeam[g_iPlanTeam]);

	// One seat fixed: the streaks that were building are no longer meaningful.
	g_iStreakT = 0;
	g_iStreakCT = 0;
}

ApplyScramble()
{
	new players[32], num, id;
	get_players(players, num, "h");

	// Shuffle in place (Fisher-Yates), bots included only when allowed.
	new pool[32], n;
	new bool:allowBots = get_pcvar_num(g_pBots) ? true : false;
	for (new i = 0; i < num; i++)
	{
		id = players[i];
		if (!allowBots && is_user_bot(id))
			continue;
		new team = _:cs_get_user_team(id);
		if (team != _:CS_TEAM_T && team != _:CS_TEAM_CT)
			continue;                       // spectators stay spectators
		pool[n++] = id;
	}

	if (n < 2)
		return;

	for (new i = n - 1; i > 0; i--)
	{
		new j = random(i + 1);
		new tmp = pool[i];
		pool[i] = pool[j];
		pool[j] = tmp;
	}

	// Alternate assignments; a random coin decides who gets the odd player.
	new firstTeam = random(2) ? (_:CS_TEAM_CT) : (_:CS_TEAM_T);
	new secondTeam = (firstTeam == (_:CS_TEAM_CT)) ? (_:CS_TEAM_T) : (_:CS_TEAM_CT);

	new ct = 0, t = 0;
	for (new i = 0; i < n; i++)
	{
		id = pool[i];
		new team = (i % 2 == 0) ? firstTeam : secondTeam;
		if (_:cs_get_user_team(id) != team)
			cs_set_user_team(id, CsTeams:team);
		if (team == _:CS_TEAM_CT)
			ct++;
		else
			t++;
	}

	client_print(0, print_chat, "[FreeNova] Teams scrambled: %d CT / %d T. Good luck.", ct, t);
	log_amx("[BAL] scrambled %d players into %d CT / %d T", n, ct, t);

	g_iStreakT = 0;
	g_iStreakCT = 0;
}

/* ---- selection ---------------------------------------------------------- */

PickMoveCandidate(CsTeams:fromTeam)
{
	new players[32], num, id;
	get_players(players, num, "h");

	new bool:allowBots = get_pcvar_num(g_pBots) ? true : false;

	// 1. a bot on the bigger team: free to move, no human is inconvenienced.
	if (allowBots)
	{
		for (new i = 0; i < num; i++)
		{
			id = players[i];
			if (is_user_bot(id) && cs_get_user_team(id) == fromTeam)
				return id;
		}
	}

	// 2. otherwise the human who joined most recently (least invested here).
	new candidate, least = 0x7fffffff;
	for (new i = 0; i < num; i++)
	{
		id = players[i];
		if (is_user_bot(id))
			continue;
		if (cs_get_user_team(id) != fromTeam)
			continue;
		new connectedFor = get_user_time(id);
		if (connectedFor < least)
		{
			least = connectedFor;
			candidate = id;
		}
	}
	return candidate;
}

/* ---- helpers ------------------------------------------------------------ */

/* Clamped notice delay: long enough to be read during the intermission, short
 * enough to land before the next round spawns (mp_chattime is 10s). */
Float:NoticeDelay()
{
	new Float:notice = get_pcvar_float(g_pNotice);
	if (notice < 0.0)
		notice = 0.0;
	if (notice > 8.0)
		notice = 8.0;
	return notice;
}

CountHumans()
{
	new n;
	for (new i = 1; i <= MaxClients; i++)
	{
		if (is_user_connected(i) && !is_user_bot(i) && !is_user_hltv(i))
			n++;
	}
	return n;
}

CountTeam(CsTeams:team)
{
	// "h" = everyone connected except HLTV proxies (bots included).
	// NOTE: "c" means "do not include bots" in this AMXX version, so "ch" is
	// humans-only - using it here silently counted 0 players on a bot-filled
	// server and the scramble found nobody to move.
	new players[32], num, n;
	get_players(players, num, "h");
	for (new i = 0; i < num; i++)
	{
		if (cs_get_user_team(players[i]) == team)
			n++;
	}
	return n;
}

/* ---- commands ----------------------------------------------------------- */

public cmdScrambleNow(id, level, cid)
{
	if (!cmd_access(id, level, cid, 1))
		return PLUGIN_HANDLED;

	new t = CountTeam(CS_TEAM_T), ct = CountTeam(CS_TEAM_CT);
	PlanScramble("admin", 0, t, ct);
	console_print(id, "[BAL] scramble planned (%d CT / %d T), applying in %.0f s - announced in chat.",
		ct, t, get_pcvar_float(g_pNotice));
	return PLUGIN_HANDLED;
}

public cmdStatus(id, level, cid)
{
	if (!cmd_access(id, level, cid, 1))
		return PLUGIN_HANDLED;

	console_print(id, "[BAL] on=%d streak=%d/%d advantage=%d notice=%.1f bots=%d plan=%d",
		get_pcvar_num(g_pOn), g_iStreakCT, g_iStreakT, get_pcvar_num(g_pAdvantage),
		get_pcvar_float(g_pNotice), get_pcvar_num(g_pBots), g_iPlan);
	console_print(id, "[BAL] teams now: %d CT / %d T, humans=%d",
		CountTeam(CS_TEAM_CT), CountTeam(CS_TEAM_T), CountHumans());
	return PLUGIN_HANDLED;
}
