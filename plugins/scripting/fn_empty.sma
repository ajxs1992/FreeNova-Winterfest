/* fn_empty: what this server does when nobody is on it.
 *
 * THE DECISION (docs/SERVER-FEEL.md): HOLD THE CURRENT MAP.
 *
 * mp_timelimit is 20 (server.cfg) and mp_maxrounds 0, so on an empty server the
 * map rotates every 20 minutes with nobody watching. For a server people join
 * at random from the browser that is the worst of the three options:
 *   - fast-forward to the next map: the joining player lands on a map that has
 *     already used up part of its clock, or on a map chosen for nobody;
 *   - keep rotating: same problem, plus the map they saw in the browser is not
 *     the map they connect to;
 *   - hold: the map they saw IS the map they get, with the time that is left
 *     when the last human left it. That is what this plugin does.
 *
 * HOW: while zero humans are connected, mp_timelimit is set to 0 (the engine
 * stops the rotation clock). When the first human connects, the plugin hands
 * the clock back with the remaining time preserved - it computes how much time
 * had already been played when the server emptied, adds the empty period back,
 * and sets mp_timelimit so that the engine's own "timeleft = limit*60 - played"
 * arithmetic lands on the remaining seconds again.
 *
 * Policy 2 adds a bound to "hold": after fn_empty_rotate_after minutes (default
 * 120) of emptiness the held map is released so a dead night still moves the
 * rotation forward; policy 1 is the old behaviour (do nothing at all), which is
 * also what you get by setting fn_empty_policy 1.
 *
 * Round spam: a warm-up that restarts rounds on a server nobody is on is the
 * other half of this problem; it is fixed on the simple_warmup side (warm-up
 * starts with the first human, not at map start). Bots keep playing here, by
 * design - the room should look and sound alive - and fn_bots keeps a small
 * seed population in it.
 *
 * Safety: a map change while held restores mp_timelimit in plugin_end, so the
 * next map never starts with a zeroed clock because of us. If anything here is
 * missing or disabled, the server behaves exactly as it does today.
 *
 * Console: fn_empty - policy, held state, remaining time, human count
 */
#include <amxmodx>
#include <amxmisc>
#include <fn_common>

#define PLUGIN  "FreeNova Empty Server Policy"
#define VERSION "1.0.0"
#define AUTHOR  "FreeNova"

#define POLICY_HOLD    0
#define POLICY_VANILLA 1
#define POLICY_BOUNDED 2

#define TASK_TICK 42100

// The engine clamps mp_timelimit; 1440 minutes (a day) is the documented range
// ceiling for it, so a held map never asks for a value outside it.
#define MAX_TIMELIMIT_MIN 1440

new g_pPolicy, g_pRotateAfter;

new g_bFrozen;
new g_iFrozenAt;
new Float:g_fLimitAtFreeze;
new g_iRemainingAtFreeze;

public plugin_init()
{
	fn_boot_banner("empty", 3);

	register_plugin(PLUGIN, VERSION, AUTHOR);

	g_pPolicy      = register_cvar("fn_empty_policy", "0");
	g_pRotateAfter = register_cvar("fn_empty_rotate_after", "120");

	register_concmd("fn_empty", "cmdStatus", ADMIN_CFG, "- empty-server policy state and held map clock");
}

public plugin_cfg()
{
	g_bFrozen = 0;
	set_task(3.0, "Task_Tick", TASK_TICK, _, _, "b");
}

/* Leaving a held map behind must never zero the next map's clock. */
public plugin_end()
{
	if (!g_bFrozen)
		return;

	set_cvar_float("mp_timelimit", g_fLimitAtFreeze);
	log_amx("[EMPTY] plugin_end: map was held, mp_timelimit restored to %.1f", g_fLimitAtFreeze);
	g_bFrozen = 0;
}

public Task_Tick()
{
	new policy = get_pcvar_num(g_pPolicy);
	if (policy == POLICY_VANILLA)
	{
		if (g_bFrozen)
			Resume("policy changed to vanilla");
		return;
	}

	new humans = CountHumans();

	if (humans > 0)
	{
		if (g_bFrozen)
			Resume("first human joined");
		return;
	}

	if (!g_bFrozen)
	{
		Freeze();
		return;
	}

	// Policy 2: do not hold one map for ever on a server nobody joins.
	if (policy == POLICY_BOUNDED)
	{
		new rotateAfter = get_pcvar_num(g_pRotateAfter);
		if (rotateAfter > 0 && (get_systime() - g_iFrozenAt) >= rotateAfter * 60)
			ReleaseForRotation(rotateAfter);
	}
}

Freeze()
{
	new Float:limit = get_cvar_float("mp_timelimit");
	if (limit <= 0.0)
		return;                                 // already infinite: nothing to hold

	new timeleft = get_timeleft();
	if (timeleft <= 0)
		return;                                 // already due to rotate; do not fight the engine

	g_fLimitAtFreeze = limit;
	g_iRemainingAtFreeze = timeleft;
	g_iFrozenAt = get_systime();
	g_bFrozen = 1;

	set_cvar_float("mp_timelimit", 0.0);
	log_amx("[EMPTY] server empty: map held (mp_timelimit %.1f -> 0, %d s left when the last human left)",
		g_fLimitAtFreeze, g_iRemainingAtFreeze);
}

Resume(const reason[])
{
	if (!g_bFrozen)
		return;

	new emptySecs = get_systime() - g_iFrozenAt;

	// Seconds already played when we froze, from the engine's own relation
	// timeleft = limit*60 - played.
	new playedAtFreeze = floatround(g_fLimitAtFreeze * 60.0) - g_iRemainingAtFreeze;
	if (playedAtFreeze < 0)
		playedAtFreeze = 0;

	new playedNow = playedAtFreeze + emptySecs;
	new wantTotal = playedNow + g_iRemainingAtFreeze;    // limit that keeps the same timeleft
	new newLimit = floatround(float(wantTotal) / 60.0, floatround_ceil);
	if (newLimit > MAX_TIMELIMIT_MIN)
		newLimit = MAX_TIMELIMIT_MIN;
	if (newLimit < 1)
		newLimit = 1;

	set_cvar_float("mp_timelimit", float(newLimit));
	g_bFrozen = 0;

	log_amx("[EMPTY] %s after %d min empty: rotation resumed, mp_timelimit %d min (%d s left)",
		reason, emptySecs / 60, newLimit, get_timeleft());
}

/* Policy 2: give the clock back so the engine rotates at the next check. */
ReleaseForRotation(rotateAfter)
{
	set_cvar_float("mp_timelimit", g_fLimitAtFreeze);
	g_bFrozen = 0;
	log_amx("[EMPTY] empty for %d min (fn_empty_rotate_after): releasing the held map so rotation moves on", rotateAfter);
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

public cmdStatus(id, level, cid)
{
	if (!cmd_access(id, level, cid, 1))
		return PLUGIN_HANDLED;

	new policy = get_pcvar_num(g_pPolicy);
	new const names[3][] = {"hold", "vanilla", "hold-then-rotate"};
	console_print(id, "[EMPTY] policy=%d (%s) humans=%d held=%d mp_timelimit=%.1f timeleft=%d rotate_after=%d min",
		policy, names[clamp(policy, 0, 2)], CountHumans(), g_bFrozen,
		get_cvar_float("mp_timelimit"), get_timeleft(), get_pcvar_num(g_pRotateAfter));

	if (g_bFrozen)
		console_print(id, "[EMPTY] held since %d s ago with %d s left (limit at freeze %.1f)",
			get_systime() - g_iFrozenAt, g_iRemainingAtFreeze, g_fLimitAtFreeze);
	return PLUGIN_HANDLED;
}
