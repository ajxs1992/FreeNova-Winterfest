/* fn_bots: make the bot population follow the room, and give the operator the
 * knobs that decide what kind of room it is.
 *
 * WHY (docs/SERVER-FEEL.md): the live server runs a static yb_quota 9. Nine
 * bots that never leave is a first-impression decision, and a static quota makes
 * it accidentally: a full-looking 9/32 server with nobody to play against when
 * you join, and nine bots competing for slots with the humans who arrive later.
 *
 * WHAT this plugin does, in one rule:
 *
 *     bots = seed + humans * per_human        (seed when empty)
 *     capped so that (bots + humans) <= maxplayers - reserve
 *
 * Defaults: seed 5, per_human 1, reserve 2, maxplayers 32 live.
 *   0 humans  -> 5 bots        (the server reads as alive in the browser but
 *                               not as "full"; two humans can still play a 2v3)
 *   1 human   -> 6 bots        (7 people: enough for a real round)
 *   10 humans -> 15 bots       (25/32, still two free slots)
 *   27 humans -> 3 bots        (30/32: humans always keep the last slots)
 *   30 humans -> 0 bots
 * Humans never lose a slot: the cap is measured from maxplayers, and YaPB's own
 * autovacate (yb_autovacate / yb_kick_after_player_connect, both 1 in yapb.cfg)
 * kicks a bot the moment a human connects to a full server. If autovacate is
 * off, this plugin says so in the log instead of silently letting bots win.
 *
 * Behaviour cvars are mirrored onto YaPB's own:
 *   fn_bot_difficulty -> yb_difficulty      (0..4; reaction time and aim error
 *                                            are the per-level values in
 *                                            addons/yapb/conf/difficulty.cfg)
 *   fn_bot_think_fps  -> yb_think_fps       (how often per second bot logic runs)
 *   fn_bot_chat       -> yb_radio_mode + yb_chat (0 off, 1 radio only, 2 both)
 *   fn_bot_chat_percent -> yb_chat_percent  (dead-chat chance)
 *
 * SEED VALUE REASONING: 5 is the smallest population that still produces a
 * non-trivial round on every stock CS map (2v3), keeps the browser entry
 * credible without faking a crowd, and costs the least CPU on a 1200 tic
 * server that is hosting nobody. Change it with fn_bot_seed; the plugin never
 * writes yapb.cfg.
 *
 * Console: fn_bots  - humans, bots, the quota it wants and the cvars it mirrors
 *
 * Every YaPB value is read with get_cvar_pointer and only written when the cvar
 * exists, so a missing YaPB (or a renamed cvar in a future YaPB) degrades to
 * "this plugin does nothing" instead of a bad load.
 */
#include <amxmodx>
#include <amxmisc>
#include <fn_common>

#define PLUGIN  "FreeNova Bot Governor"
#define VERSION "1.0.0"
#define AUTHOR  "FreeNova"

#define TASK_TICK   41200
#define TASK_RECOUNT 41201

new g_pEnabled, g_pSeed, g_pPerHuman, g_pMax, g_pReserve;
new g_pDifficulty, g_pThinkFps, g_pChat, g_pChatPercent;

new g_pYbQuota, g_pYbDifficulty, g_pYbThinkFps, g_pYbRadio, g_pYbChat, g_pYbChatPercent;
new g_iYbMissing;
new g_bAutoVacateWarned;
new g_iLastApplied = -1;

public plugin_init()
{
	fn_boot_banner("bots", 9);

	register_plugin(PLUGIN, VERSION, AUTHOR);

	g_pEnabled     = register_cvar("fn_bot_enabled", "1");
	g_pSeed        = register_cvar("fn_bot_seed", "5");
	g_pPerHuman    = register_cvar("fn_bot_per_human", "1");
	g_pMax         = register_cvar("fn_bot_max", "0");
	g_pReserve     = register_cvar("fn_bot_reserve", "2");
	g_pDifficulty  = register_cvar("fn_bot_difficulty", "3");
	g_pThinkFps    = register_cvar("fn_bot_think_fps", "26");
	g_pChat        = register_cvar("fn_bot_chat", "1");
	g_pChatPercent = register_cvar("fn_bot_chat_percent", "15");

	register_concmd("fn_bots", "cmdStatus", ADMIN_CFG, "- bot population, quota and mirrored YaPB cvars");

	hook_cvar_change(g_pEnabled, "OnQuorumCvar");
	hook_cvar_change(g_pSeed, "OnQuorumCvar");
	hook_cvar_change(g_pPerHuman, "OnQuorumCvar");
	hook_cvar_change(g_pMax, "OnQuorumCvar");
	hook_cvar_change(g_pReserve, "OnQuorumCvar");
	hook_cvar_change(g_pDifficulty, "OnOurCvar");
	hook_cvar_change(g_pThinkFps, "OnOurCvar");
	hook_cvar_change(g_pChat, "OnOurCvar");
	hook_cvar_change(g_pChatPercent, "OnOurCvar");
}

public plugin_cfg()
{
	ResolveYapb();
	ApplyBehaviour();
	Recount();
	set_task(2.0, "Task_Tick", TASK_TICK, _, _, "b");
}

public client_putinserver(id)
{
	if (is_user_bot(id) || is_user_hltv(id))
		return;
	// A human is arriving: re-count soon so the quota drops before the next
	// map/round rather than after the next 2s tick.
	remove_task(TASK_RECOUNT);
	set_task(1.0, "Task_Tick", TASK_RECOUNT);
}

public client_disconnected(id)
{
	if (is_user_bot(id) || is_user_hltv(id))
		return;
	remove_task(TASK_RECOUNT);
	set_task(1.0, "Task_Tick", TASK_RECOUNT);
}

public Task_Tick()
{
	ResolveYapb();
	ApplyBehaviour();
	Recount();
}

public OnOurCvar(pcvar, const old_value[], const new_value[])
{
	ResolveYapb();
	ApplyBehaviour();
}

/* Quorum cvars: re-run the rule immediately, not on the next 2s tick. */
public OnQuorumCvar(pcvar, const old_value[], const new_value[])
{
	ResolveYapb();
	g_iLastApplied = -1;
	Recount();
}

/* ---- the quorum rule ---------------------------------------------------- */

Recount()
{
	if (!get_pcvar_num(g_pEnabled))
		return;

	if (!g_pYbQuota)
	{
		// YaPB absent: nothing to govern, and saying so once is enough.
		if (!g_iYbMissing)
		{
			log_amx("[BOTS] yb_quota not found - YaPB is not loaded, bot quorum stays unmanaged");
			g_iYbMissing = 1;
		}
		return;
	}
	g_iYbMissing = 0;

	new humans = CountHumans();
	new maxp = get_maxplayers();
	new reserve = clamp(get_pcvar_num(g_pReserve), 0, maxp);
	new seed = clamp(get_pcvar_num(g_pSeed), 0, maxp);
	new per = clamp(get_pcvar_num(g_pPerHuman), 0, maxp);

	new desired = humans > 0 ? seed + humans * per : seed;

	new cap = maxp - reserve - humans;               // slots bots may occupy
	if (cap < 0)
		cap = 0;

	new maxCfg = get_pcvar_num(g_pMax);
	if (maxCfg > 0 && desired > maxCfg)
		desired = maxCfg;
	if (desired > cap)
		desired = cap;
	if (desired < 0)
		desired = 0;

	if (desired == g_iLastApplied && get_pcvar_num(g_pYbQuota) == desired)
		return;

	set_pcvar_num(g_pYbQuota, desired);
	g_iLastApplied = desired;
	log_amx("[BOTS] humans=%d bots=%d (seed=%d per_human=%d reserve=%d maxplayers=%d)",
		humans, desired, seed, per, reserve, maxp);
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

/* ---- behaviour mirrors -------------------------------------------------- */

ResolveYapb()
{
	if (!g_pYbQuota)
		g_pYbQuota = get_cvar_pointer("yb_quota");
	if (!g_pYbDifficulty)
		g_pYbDifficulty = get_cvar_pointer("yb_difficulty");
	if (!g_pYbThinkFps)
		g_pYbThinkFps = get_cvar_pointer("yb_think_fps");
	if (!g_pYbRadio)
		g_pYbRadio = get_cvar_pointer("yb_radio_mode");
	if (!g_pYbChat)
		g_pYbChat = get_cvar_pointer("yb_chat");
	if (!g_pYbChatPercent)
		g_pYbChatPercent = get_cvar_pointer("yb_chat_percent");
}

ApplyBehaviour()
{
	if (!g_pYbQuota)
		return;

	if (g_pYbDifficulty)
	{
		new d = clamp(get_pcvar_num(g_pDifficulty), 0, 4);
		if (get_pcvar_num(g_pYbDifficulty) != d)
			set_pcvar_num(g_pYbDifficulty, d);
	}

	if (g_pYbThinkFps)
	{
		new Float:tf = get_pcvar_float(g_pThinkFps);
		if (tf < 24.0)
			tf = 24.0;
		if (tf > 90.0)
			tf = 90.0;
		if (floatcmp(get_pcvar_float(g_pYbThinkFps), tf) != 0)
			set_pcvar_float(g_pYbThinkFps, tf);
	}

	new chat = clamp(get_pcvar_num(g_pChat), 0, 2);
	if (g_pYbRadio && get_pcvar_num(g_pYbRadio) != chat)
		set_pcvar_num(g_pYbRadio, chat);
	if (g_pYbChat)
	{
		new on = (chat >= 2) ? 1 : 0;
		if (get_pcvar_num(g_pYbChat) != on)
			set_pcvar_num(g_pYbChat, on);
	}
	if (g_pYbChatPercent)
	{
		new pct = clamp(get_pcvar_num(g_pChatPercent), 0, 100);
		if (get_pcvar_num(g_pYbChatPercent) != pct)
			set_pcvar_num(g_pYbChatPercent, pct);
	}

	// The "humans never lose a slot" half of the rule lives in yapb.cfg, not
	// here: warn instead of overriding an operator decision.
	if (!g_bAutoVacateWarned)
	{
		new ptr = get_cvar_pointer("yb_autovacate");
		if (ptr && !get_pcvar_num(ptr))
		{
			g_bAutoVacateWarned = 1;
			log_amx("[BOTS] warning: yb_autovacate is 0 - a bot may hold a slot a human needs");
		}
	}
}

/* ---- operator visibility ------------------------------------------------ */

public cmdStatus(id, level, cid)
{
	if (!cmd_access(id, level, cid, 1))
		return PLUGIN_HANDLED;

	new humans = CountHumans();
	console_print(id, "[BOTS] humans=%d maxplayers=%d enabled=%d seed=%d per_human=%d max=%d reserve=%d",
		humans, get_maxplayers(), get_pcvar_num(g_pEnabled), get_pcvar_num(g_pSeed),
		get_pcvar_num(g_pPerHuman), get_pcvar_num(g_pMax), get_pcvar_num(g_pReserve));

	if (!g_pYbQuota)
	{
		console_print(id, "[BOTS] YaPB not loaded (yb_quota missing) - nothing is governed.");
		return PLUGIN_HANDLED;
	}

	console_print(id, "[BOTS] yb_quota=%d last_applied=%d difficulty=%d think_fps=%.1f radio_mode=%d chat=%d chat_percent=%d",
		get_pcvar_num(g_pYbQuota), g_iLastApplied,
		g_pYbDifficulty ? get_pcvar_num(g_pYbDifficulty) : -1,
		g_pYbThinkFps ? get_pcvar_float(g_pYbThinkFps) : -1.0,
		g_pYbRadio ? get_pcvar_num(g_pYbRadio) : -1,
		g_pYbChat ? get_pcvar_num(g_pYbChat) : -1,
		g_pYbChatPercent ? get_pcvar_num(g_pYbChatPercent) : -1);
	return PLUGIN_HANDLED;
}
