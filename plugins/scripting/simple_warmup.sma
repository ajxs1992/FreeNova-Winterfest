/* simple_warmup: knife warm-up, now owned by the mode arbiter (fn_mode).
 *
 * WHAT CHANGED vs the 1.0 plugin this replaces (Sn!ff3r's "Simple Knife Warump"):
 *
 *  1. It no longer starts on map start. A warm-up nobody attends is a server
 *     that restarts rounds for a minute with no players in it, so warm-up now
 *     begins when the FIRST HUMAN connects (Mission: "an empty server should not
 *     be a weird server"). The first join is the moment that matters.
 *
 *  2. It ends when it has done its job instead of running blind for 60s:
 *     - sw_min_humans humans are connected (default 2), or
 *     - enough humans typed !ready (sw_ready_ratio / sw_ready_min), or
 *     - warmup_timer seconds elapsed (default 90; 0 = no clock, wait for humans),
 *     - or the last human left (then it ends WITHOUT restarting a round).
 *
 *  3. Every cvar it changes goes through fn_mode (include/fn_mode.inc), which
 *     snapshots the pre-mode value and owns the restore. This is strictly
 *     stronger than the local snapshot the 1.0 plugin grew for REVIEW.md 5.5:
 *     the restore is not only on the plugin's own code path (end of warm-up,
 *     plugin_end) but also on the arbiter's plugin_end, so a map change, a
 *     plugin reload or a crash of this plugin cannot leave
 *     amx_knife_round_active 1 (which makes every XP owner silently refuse to
 *     pay XP for a whole map) or mp_freezetime pinned at 0.
 *     Server console: `fn_mode status` shows exactly what is held and why.
 *
 *  4. If fn_mode.amxx is missing the old local snapshot path is kept as a
 *     fallback, so a deployment mistake degrades to the 1.0 behaviour rather
 *     than to a knife round that never ends.
 *
 * Commands:
 *   say /ready  (say_team /ready, say !ready)  - vote to skip the remaining warm-up
 *   sw_start    (ADMIN_CFG, console)           - start a warm-up now
 *   sw_end      (ADMIN_CFG, console)           - end the warm-up now (restores cvars)
 *   sw_status   (ADMIN_CFG, console)           - warm-up state, humans, ready votes
 *
 * Cvars (all documented in docs/SERVER-FEEL.md):
 *   warmup_timer    90   max seconds of warm-up once it starts (0 = no clock, -1 = off)
 *   sw_min_humans   2    end the warm-up automatically at this many humans (0 = never)
 *   sw_ready_ratio  0.6  fraction of connected humans that must !ready to skip
 *   sw_ready_min    1    votes always needed to skip, whatever the ratio says
 *   sw_on           1    master switch (0 = plugin does nothing at all)
 *   amx_knife_round_active (0/1) - read by the XP owners; 1 only while warm-up runs
 */
#include <amxmodx>
#include <amxmisc>
#include <fn_common>
#include <fn_mode>

#define PLUGIN  "FreeNova Knife Warmup"
#define VERSION "2.0.0"
#define AUTHOR  "FreeNova (based on Sn!ff3r's Simple Knife Warump)"

#define TASK_TICK     1234
#define TASK_ARM      1235
#define MODE_NAME     "warmup"

new g_pTimer, g_pMinHumans, g_pReadyRatio, g_pReadyMin, g_pOn;
new g_pKnifeActive;                      // amx_knife_round_active, owned here
new g_bWarmup;
new g_bModeOwned;                        // fn_mode holds the arbiter
new g_iSecondsLeft;                      // only meaningful when warmup_timer > 0
new bool:g_bReady[MAX_PLAYERS + 1];
new g_iFallbackFreeze = -1;              // fallback snapshot when fn_mode is absent
new g_iInitiator;                        // human whose join armed the warm-up

public plugin_init()
{
	fn_boot_banner("warmup", 8);

	register_plugin(PLUGIN, VERSION, AUTHOR);

	g_pTimer      = register_cvar("warmup_timer", "90");
	g_pOn         = register_cvar("sw_on", "1");
	g_pMinHumans  = register_cvar("sw_min_humans", "2");
	g_pReadyRatio = register_cvar("sw_ready_ratio", "0.6");
	g_pReadyMin   = register_cvar("sw_ready_min", "1");
	g_pKnifeActive = register_cvar("amx_knife_round_active", "0");

	register_clcmd("say /ready", "CmdReady");
	register_clcmd("say_team /ready", "CmdReady");
	register_clcmd("say !ready", "CmdReady");
	register_clcmd("say_team !ready", "CmdReady");

	register_concmd("sw_start", "CmdStart", ADMIN_CFG, "- start the knife warm-up now");
	register_concmd("sw_end", "CmdEnd", ADMIN_CFG, "- end the knife warm-up now (restores cvars)");
	register_concmd("sw_status", "CmdStatus", ADMIN_CFG, "- warm-up state, humans, ready votes");

	// Knife only during warm-up: force the knife back into the hands of any
	// player who switches to anything else.
	register_event("CurWeapon", "switchweapon", "be", "1=1", "2!29");
	register_clcmd("menuselect", "Cmd_BlockBuyMenu");
}

public plugin_cfg()
{
	// Per-map reset, kept from the 1.0 plugin and now only a belt-and-braces
	// guard: fn_mode's plugin_end already restored the real value on map end.
	// A leaked 1 makes every XP owner refuse to award XP for the whole map.
	if (!g_bWarmup)
		set_pcvar_num(g_pKnifeActive, 0);

	if (LibraryExists("fn_mode", LibType_Library) && !g_bModeOwned)
		log_amx("[WARMUP] fn_mode present, cvar restore is arbiter-owned");

	// If the server was left in a warm-up by a reload, the arbiter's plugin_end
	// restored it; there is nothing to resume.
	g_bWarmup = 0;
	remove_task(TASK_TICK);
}

public client_putinserver(id)
{
	if (is_user_bot(id) || is_user_hltv(id))
		return;

	g_bReady[id] = false;

	if (!get_pcvar_num(g_pOn) || g_bWarmup || get_pcvar_num(g_pTimer) < 0)
		return;

	// Remember who armed it: if the arbiter refuses the begin, THAT player is
	// the one who gets told why (fn_mode_begin's initiator).
	g_iInitiator = id;

	// 2s: let the player's info string land and their HUD initialise before a
	// round restarts under them.
	remove_task(TASK_ARM);
	set_task(2.0, "Task_ArmWarmup", TASK_ARM);
}

public client_disconnected(id)
{
	g_bReady[id] = false;
}

public Task_ArmWarmup()
{
	if (g_bWarmup || !get_pcvar_num(g_pOn))
		return;
	if (CountHumans() < 1)
		return;
	StartWarmup(false, g_iInitiator);
}

/* ---- warm-up lifecycle ------------------------------------------------- */

StartWarmup(bool:bForce = false, initiator = 0)
{
	if (g_bWarmup)
		return;

	new humans = CountHumans();
	if (humans < 1 && !bForce)
		return;

	new payload[48];
	formatex(payload, charsmax(payload), "humans=%d", humans);

	// Fallback snapshot: the value to put back if the arbiter is missing or a
	// write has to bypass it. Taken before any cvar is touched.
	g_iFallbackFreeze = get_pcvar_num(get_cvar_pointer("mp_freezetime"));

	// The arbiter is the authority on "may a mode start now". Without it we
	// fall back to 1.0 behaviour instead of refusing to run.
	g_bModeOwned = 0;
	if (LibraryExists("fn_mode", LibType_Library))
	{
		if (!fn_mode_begin(MODE_NAME, payload, initiator))
		{
			// Refused: another mode is active. fn_mode logged it, told the admins
			// and told the initiator (chat, or console when initiator is 0), so
			// this plugin only records it; the next human to connect retries.
			new why[192];
			fn_mode_refusal(why, charsmax(why));
			log_amx("[WARMUP] not started: %s", why);
			return;
		}
		g_bModeOwned = 1;
	}

	// mp_freezetime 0 while warm-up runs: instant respawns, more knife duels.
	ModeSetCvar("mp_freezetime", "0");
	ModeSetCvar("amx_knife_round_active", "1");

	g_bWarmup = 1;
	g_iSecondsLeft = get_pcvar_num(g_pTimer);

	client_print(0, print_chat, "[FreeNova] Knife warm-up: knives only, no buying. Say !ready to start the match.");
	if (g_iSecondsLeft > 0)
		client_print(0, print_chat, "[FreeNova] Warm-up ends in %d seconds or at %d players, whichever comes first.", g_iSecondsLeft, clamp(get_pcvar_num(g_pMinHumans), 1, 32));

	remove_task(TASK_TICK);
	set_task(1.0, "Task_Tick", TASK_TICK, _, _, "b");
	log_amx("[WARMUP] started (humans=%d timer=%d min_humans=%d mode_owned=%d)", humans, g_iSecondsLeft, get_pcvar_num(g_pMinHumans), g_bModeOwned);
}

EndWarmup(bool:bRestart)
{
	if (!g_bWarmup)
		return;

	remove_task(TASK_TICK);
	g_bWarmup = 0;

	new restored = 0;
	if (g_bModeOwned && LibraryExists("fn_mode", LibType_Library))
	{
		restored = fn_mode_end(MODE_NAME);
	}
	else
	{
		// Fallback (fn_mode absent): undo exactly what this plugin wrote.
		if (g_iFallbackFreeze >= 0)
		{
			set_cvar_num("mp_freezetime", g_iFallbackFreeze);
			g_iFallbackFreeze = -1;
			restored++;
		}
		set_pcvar_num(g_pKnifeActive, 0);
		restored++;
	}
	g_bModeOwned = 0;

	for (new i = 1; i <= MaxClients; i++)
		g_bReady[i] = false;

	if (bRestart)
	{
		// One restart, not a loop: players come back with normal weapons.
		set_cvar_num("sv_restartround", 1);
		client_print(0, print_chat, "[FreeNova] Warm-up over - normal round starting. Good luck!");
	}
	else
	{
		client_print(0, print_chat, "[FreeNova] Warm-up ended.");
	}

	log_amx("[WARMUP] ended (restart=%d restored=%d)", bRestart, restored);
}

public Task_Tick()
{
	if (!g_bWarmup)
	{
		remove_task(TASK_TICK);
		return;
	}

	new humans = CountHumans();

	// Nobody left: restore and stop. Never leave knife-round cvars on an empty
	// server (the next human must not inherit a warm-up nobody voted for).
	if (humans < 1)
	{
		EndWarmup(false);
		return;
	}

	// Enough real players: warm-up has done its job.
	new minHumans = get_pcvar_num(g_pMinHumans);
	if (minHumans > 0 && humans >= minHumans)
	{
		EndWarmup(true);
		return;
	}

	// !ready vote.
	if (ReadyEnough(humans))
	{
		EndWarmup(true);
		return;
	}

	if (get_pcvar_num(g_pTimer) > 0)
	{
		if (g_iSecondsLeft <= 0)
		{
			EndWarmup(true);
			return;
		}
		set_hudmessage(255, 255, 255, -1.0, 0.9, 0, 6.0, 1.0, 0.1, 0.2);
		show_hudmessage(0, "Knife warm-up: %d seconds - say !ready to start", g_iSecondsLeft);
		g_iSecondsLeft--;
	}
}

/* ---- helpers ----------------------------------------------------------- */

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

ReadyEnough(humans)
{
	new votes;
	for (new i = 1; i <= MaxClients; i++)
	{
		if (g_bReady[i] && is_user_connected(i) && !is_user_bot(i))
			votes++;
	}
	if (votes < 1)
		return 0;
	if (votes < get_pcvar_num(g_pReadyMin))
		return 0;

	new Float:ratio = get_pcvar_float(g_pReadyRatio);
	if (ratio <= 0.0)
		return votes >= get_pcvar_num(g_pReadyMin);

	return float(votes) >= float(humans) * ratio;
}

/* Write one cvar through the arbiter when we own it, directly otherwise. The
 * direct path is recorded in the fallback snapshot, so even a bypassed write
 * is undone on end - the whole point of this plugin's 2.0 rewrite. */
ModeSetCvar(const cvar[], const value[])
{
	if (g_bModeOwned && LibraryExists("fn_mode", LibType_Library))
	{
		if (fn_mode_set(MODE_NAME, cvar, value))
			return;
		// fall through to the direct write: the cvar table is full or the cvar
		// vanished, and a warm-up without knife mode is worse than a direct set.
		log_amx("[WARMUP] arbiter refused %s=%s, writing directly (fallback restore still covers it)", cvar, value);
	}

	new ptr = get_cvar_pointer(cvar);
	if (ptr)
		set_pcvar_string(ptr, value);
}

/* ---- player / admin commands ------------------------------------------- */

public CmdReady(id)
{
	if (!is_user_connected(id) || is_user_bot(id))
		return PLUGIN_HANDLED;

	if (!g_bWarmup)
	{
		client_print(id, print_chat, "[FreeNova] No warm-up is running.");
		return PLUGIN_HANDLED;
	}

	if (g_bReady[id])
	{
		client_print(id, print_chat, "[FreeNova] You already voted ready.");
		return PLUGIN_HANDLED;
	}

	g_bReady[id] = true;
	new votes = 0, need, humans = CountHumans();
	for (new i = 1; i <= MaxClients; i++)
	{
		if (g_bReady[i] && is_user_connected(i) && !is_user_bot(i))
			votes++;
	}
	new Float:ratio = get_pcvar_float(g_pReadyRatio);
	if (ratio <= 0.0)
		need = get_pcvar_num(g_pReadyMin);
	else
	{
		need = floatround(float(humans) * ratio, floatround_ceil);
		if (need < get_pcvar_num(g_pReadyMin))
			need = get_pcvar_num(g_pReadyMin);
	}

	client_print(0, print_chat, "[FreeNova] %d/%d players ready to start (%d needed).", votes, humans, need);
	return PLUGIN_HANDLED;
}

public CmdStart(id, level, cid)
{
	if (!cmd_access(id, level, cid, 1))
		return PLUGIN_HANDLED;

	new arg[8];
	read_argv(1, arg, charsmax(arg));
	new bool:bForce = equali(arg, "force") ? true : false;

	if (g_bWarmup)
	{
		console_print(id, "[WARMUP] already running.");
		return PLUGIN_HANDLED;
	}
	if (CountHumans() < 1 && !bForce)
	{
		console_print(id, "[WARMUP] nobody is connected; warm-up starts with the first human (use 'sw_start force' to start it anyway).");
		return PLUGIN_HANDLED;
	}
	StartWarmup(bForce, id);
	if (!g_bWarmup)
	{
		new why[192];
		if (LibraryExists("fn_mode", LibType_Library) && fn_mode_refusal(why, charsmax(why)))
			console_print(id, "[WARMUP] refused: %s", why);
		else
			console_print(id, "[WARMUP] refused: another mode is active (see 'fn_mode status').");
		return PLUGIN_HANDLED;
	}
	console_print(id, "[WARMUP] started (force=%d).", bForce);
	return PLUGIN_HANDLED;
}

public CmdEnd(id, level, cid)
{
	if (!cmd_access(id, level, cid, 1))
		return PLUGIN_HANDLED;
	if (!g_bWarmup)
	{
		console_print(id, "[WARMUP] not running.");
		return PLUGIN_HANDLED;
	}
	EndWarmup(true);
	console_print(id, "[WARMUP] ended, cvars restored.");
	return PLUGIN_HANDLED;
}

public CmdStatus(id, level, cid)
{
	if (!cmd_access(id, level, cid, 1))
		return PLUGIN_HANDLED;

	new votes;
	for (new i = 1; i <= MaxClients; i++)
	{
		if (g_bReady[i] && is_user_connected(i) && !is_user_bot(i))
			votes++;
	}
	new knife = get_pcvar_num(g_pKnifeActive);
	console_print(id, "[WARMUP] running=%d humans=%d ready=%d knife_cvar=%d timer=%d min_humans=%d arbiter=%s",
		g_bWarmup, CountHumans(), votes, knife, get_pcvar_num(g_pTimer),
		get_pcvar_num(g_pMinHumans), g_bModeOwned ? "fn_mode" : "local-fallback");
	return PLUGIN_HANDLED;
}

/* ---- end-of-map safety -------------------------------------------------- */

public plugin_end()
{
	if (!g_bWarmup)
		return;

	// fn_mode's own plugin_end restores whatever it still holds; calling end
	// here first means the log line names both sides of the hand-over.
	EndWarmup(false);
	log_amx("[WARMUP] plugin_end: warm-up was still active, cvars restored");
}

public switchweapon(id)
{
	if (!g_bWarmup || !is_user_alive(id))
		return;
	engclient_cmd(id, "weapon_knife");
}

public Cmd_BlockBuyMenu(id)
{
	if (!g_bWarmup || !is_user_alive(id))
		return PLUGIN_CONTINUE;

	new oldmenu, newmenu;
	player_menu_info(id, oldmenu, newmenu);
	if (newmenu != -1)
		return PLUGIN_CONTINUE;
	return PLUGIN_HANDLED;
}
