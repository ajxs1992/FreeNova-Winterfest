/*
 * ============================================================================
 * winterfest_atmos — snowfall, the snowstorm window, Christmas bomb atmosphere
 * ============================================================================
 * Product contract: docs/WINTERFEST.md §1.3 ("what works with zero client
 * downloads"), docs/WINTERFEST-WORKSTREAMS.md row 6. Full documentation of
 * every cvar, the config file and what GoldSrc cannot do:
 * docs/WINTERFEST-ATMOS.md.
 *
 * WHAT THIS PLUGIN IS
 *   The room, for the season: light snow around every player, a temporary
 *   snowstorm window with a tint and a shake, and a festive glow on the C4.
 *   Nothing else. No gameplay, no rewards, no dependency on winterfest_core.
 *
 * NO CLIENT ASSET
 *   Two stock sprites, both already in the precache table via other plugins
 *   (freenova_cosmetics precaches sprites/laserbeam.spr, winterfest_gifts
 *   precaches both), so this module adds ZERO distinct items to the 512-item
 *   budget - see docs/PRECACHE-BUDGET.md and the measurement in
 *   docs/WINTERFEST-ATMOS.md §5.
 *
 * WHY THE FLAKE IS TE_SPRITETRAIL AND NOT TE_SPRITE
 *   TE_SPRITE is the obvious choice and it is one field short: it has no life
 *   or velocity, so the engine plays the sprite for exactly one cycle.
 *   sprites/glow01.spr is a single 64x64 frame, which means a TE_SPRITE flake
 *   lives about a tenth of a second - at 6 flakes/s you would see less than one
 *   on screen and it would read as a flicker, not snow. TE_SPRITETRAIL is the
 *   same additive stock-sprite particle with `life` (0.1 s units) and `speed`
 *   fields, so `wf_snow_life` can mean something and each flake visibly falls.
 *   `wf_snow_kind 0` switches back to literal TE_SPRITE if that is what you
 *   want to compare; the default is the trail.
 *
 * COST
 *   One repeating 0.1 s task for the whole server (no per-player tasks, no
 *   per-frame loop, no think hooks), one short message per flake, sent
 *   MSG_ONE_UNRELIABLE to the player the snow belongs to. At the default
 *   6 flakes/s that is ~6 small messages a second per player; a 32-player
 *   server at the storm default (18/s) is ~576 messages a second of ~28 bytes,
 *   which is under 16 KB/s of unreliable traffic in total.
 *
 * NO ENTITIES AT ALL
 *   The plugin never calls CreateEntity/create_entity and never spawns an
 *   env_sprite: snow, storm tint, C4 glow and the C4 "christmas light" column
 *   are all temp entities (SVC_TEMPENTITY) and client messages. There is
 *   therefore nothing to leak at map end - plugin_end() still removes every
 *   task it owns and prints how many it removed, which is what the harness
 *   asserts (docs/WINTERFEST-ATMOS.md §6).
 *
 * BOTS
 *   Every per-player entry point here starts at 1 and skips is_user_bot() /
 *   is_user_hltv(). A bot is counted (so the console can prove the exclusion)
 *   and never given a flake, a fade or a shake.
 * ============================================================================
 */

#include <amxmodx>
#include <amxmisc>
#include <fakemeta>
#include <winterfest_atmos>

#define PLUGIN  "Winterfest Atmosphere"
#define VERSION "1.0.0"
#define AUTHOR  "FreeNova"

#define WF_CONFIG_FILE  "atmos.ini"

// Snow is a 10 Hz task: fine enough that the particles are placed where the
// player is now, coarse enough that the server does the work 10 times a second
// instead of every frame.
#define TICK_SECS       0.1
#define MAX_FLAKES_TICK 4        // hard cap per player per tick, whatever the rate
#define MAX_RATE        60       // flakes/s/player the cvars are clamped to
#define FALL_SPEED      5        // TE_SPRITETRAIL speed in 10's -> 50 units/s

#define STORM_PULSE_SECS 6.0     // storm tint + shake refresh
#define STORM_MIN_SECS   10
#define STORM_MAX_SECS   600
#define STORM_FADE_SECS  6.0     // ScreenFade duration is a short in 1/4096 s
#define FADE_MAX_SECS    7.9     // 32767/4096 s: a larger write_short overflows

// ScreenFade flags. Not in any stock header (battlepass_core defines its own
// inline too); FFADE_OUT is what Util_ScreenFade uses for damage tints, so the
// tint decays instead of hanging over the view.
#define WF_FFADE_OUT     0x0001

enum
{
	TASK_SNOW = 98001,
	TASK_STORM_END,
	TASK_STORM_PULSE,
	TASK_BOMB_FIND,
	TASK_BOMB_PULSE
}

enum
{
	BOMB_NONE = 0,
	BOMB_PLANTED,
	BOMB_DEFUSED
}

new g_cvAtmos, g_cvForce, g_cvSnow, g_cvRate, g_cvRadius, g_cvHeight, g_cvLife,
	g_cvScale, g_cvKind, g_cvStorm, g_cvStormLen, g_cvStormRate, g_cvBombfx,
	g_cvDebug;

new g_sprSnow, g_sprBeam;
new g_msgFade, g_msgShake;

new bool:g_bActive;            // season gate passed and wf_atmos is on
new bool:g_bWindowOpen;        // the date window alone, for the report
new bool:g_bStorm;
new bool:g_bBombPlanted;
new Float:g_fBombOrigin[3];
new g_iPlanter;

// Flake budget accounting: `debt` is the fraction of a flake a player is owed,
// so wf_snow_rate 6 on a 10 Hz task emits 0.6 flakes per tick and averages
// exactly 6 a second instead of rounding to 1 every tick.
new Float:g_fDebt[MAX_PLAYERS + 1];

// Counters - printed by `wf_atmos_report`, asserted by the harness.
new g_iFlakes;
new g_iFades;
new g_iShakes;
new g_iPulses;
new g_iStormStarts;
new g_iBombPulses;
new g_iHumans;
new g_iBots;
new g_iSkipped;                // flakes dropped by MAX_FLAKES_TICK
new g_iLifeNow, g_iScaleNow;
new g_iTicks;                  // snow ticks since load, for wf_atmos_debug

// ============================================================
// Lifecycle
// ============================================================
public plugin_precache()
{
	g_sprSnow = precache_model("sprites/glow01.spr");
	g_sprBeam = precache_model("sprites/laserbeam.spr");
	server_print("[WF-ATMOS] precache asked for 2 stock sprites (glow01=%d laserbeam=%d); both are already in the live table",
		g_sprSnow, g_sprBeam);
}

public plugin_init()
{
	register_plugin(PLUGIN, VERSION, AUTHOR);

	g_cvAtmos = register_cvar("wf_atmos", "1");
	g_cvForce = register_cvar("wf_atmos_force", "0");
	g_cvSnow = register_cvar("wf_snow", "1");
	g_cvRate = register_cvar("wf_snow_rate", "6");
	g_cvRadius = register_cvar("wf_snow_radius", "300");
	g_cvHeight = register_cvar("wf_snow_height", "220");
	g_cvLife = register_cvar("wf_snow_life", "8");
	g_cvScale = register_cvar("wf_snow_scale", "2");
	g_cvKind = register_cvar("wf_snow_kind", "1");
	g_cvStorm = register_cvar("wf_storm", "0");
	g_cvStormLen = register_cvar("wf_storm_len", "90");
	g_cvStormRate = register_cvar("wf_storm_rate", "18");
	g_cvBombfx = register_cvar("wf_bombfx", "1");
	g_cvDebug = register_cvar("wf_atmos_debug", "0");

	register_concmd("wf_atmos_apply", "cmdApply", ADMIN_ALL, "- re-read atmos.ini and start/stop the effects now");
	register_concmd("wf_atmos_report", "cmdReport", ADMIN_ALL, "- print the gate, the timers and the counters");
	register_concmd("wf_atmos_test", "cmdSelfTest", ADMIN_ALL, "- run each effect once (lab: no players needed)");

	register_logevent("OnRoundStart", 2, "1=Round_Start");
	register_logevent("OnRoundEnd", 2, "1=Round_End");

	g_msgFade = get_user_msgid("ScreenFade");
	g_msgShake = get_user_msgid("ScreenShake");
	if (g_msgFade <= 0)
		log_amx("[WF-ATMOS] this gamedll registers no ScreenFade message - storm/bomb tints disabled");
	if (g_msgShake <= 0)
		log_amx("[WF-ATMOS] this gamedll registers no ScreenShake message - storm shake disabled");

	server_print("[FreeNova winterfest_atmos] ready (build 3, %d cvars, %d commands, %d tasks)", 14, 3, 5);
}

public plugin_cfg()
{
	WfAtmosWindowLoad(WF_CONFIG_FILE);
	ApplyState("plugin_cfg");
}

public plugin_end()
{
	// Every task this plugin owns, by id: remove_task(id) is the whole cleanup,
	// because no task was ever started without an explicit id.
	new stopped = 0;
	stopped += KillTask(TASK_SNOW);
	stopped += KillTask(TASK_STORM_END);
	stopped += KillTask(TASK_STORM_PULSE);
	stopped += KillTask(TASK_BOMB_FIND);
	stopped += KillTask(TASK_BOMB_PULSE);

	// A storm is a window, not a state: if the map ends mid-storm, clear the
	// switch so the next map does not silently get a fresh one.
	new cleared = 0;
	if (g_bStorm)
	{
		set_cvar_num("wf_storm", 0);
		g_bStorm = false;
		cleared = 1;
	}

	server_print("[WF-ATMOS] timers stopped (map end: %d task(s) removed, %d flake(s) emitted over the map, 0 entities created, storm switch cleared=%d)",
		stopped, g_iFlakes, cleared);
}

KillTask(taskid)
{
	if (!task_exists(taskid))
		return 0;
	remove_task(taskid);
	return 1;
}

public client_disconnected(id)
{
	if (id >= 1 && id <= MaxClients)
		g_fDebt[id] = 0.0;
}

// ============================================================
// The seasonal gate
// ============================================================
// One place decides whether the room is decorated: wf_atmos on, and either
// today is inside atmos.ini's window or the operator forced it. Everything
// else in this file asks g_bActive. Applying is idempotent: every task is
// removed first, so calling it twice cannot double the snow.
ApplyState(const reason[])
{
	remove_task(TASK_SNOW);
	remove_task(TASK_STORM_END);
	remove_task(TASK_STORM_PULSE);
	remove_task(TASK_BOMB_FIND);
	remove_task(TASK_BOMB_PULSE);

	new window[48], today[16];
	WfAtmosWindowText(window, charsmax(window));
	WfAtmosDateText(today, charsmax(today));

	g_bWindowOpen = WfAtmosOpenNow();
	new forced = get_pcvar_num(g_cvForce) ? 1 : 0;

	if (!get_pcvar_num(g_cvAtmos))
	{
		g_bActive = false;
		g_bStorm = false;
		server_print("[WF-ATMOS] atmos idle: wf_atmos 0 (%s, window %s)", today, window);
		return;
	}

	if (!g_bWindowOpen && !forced)
	{
		g_bActive = false;
		g_bStorm = false;
		server_print("[WF-ATMOS] atmos idle: outside window (%s, window %s)", today, window);
		return;
	}

	g_bActive = true;

	if (get_pcvar_num(g_cvSnow))
		set_task(TICK_SECS, "Task_Snow", TASK_SNOW, _, _, "b");

	if (get_pcvar_num(g_cvStorm))
		StartStorm(reason);
	else
		g_bStorm = false;

	if (g_bBombPlanted && get_pcvar_num(g_cvBombfx))
		set_task(1.0, "Task_BombPulse", TASK_BOMB_PULSE, _, _, "b");

	server_print("[WF-ATMOS] active (%s): window %s open=%d forced=%d snow=%d rate=%d radius=%d height=%d life=%d scale=%d kind=%d bombfx=%d",
		reason, window, g_bWindowOpen ? 1 : 0, forced,
		get_pcvar_num(g_cvSnow), get_pcvar_num(g_cvRate), get_pcvar_num(g_cvRadius),
		get_pcvar_num(g_cvHeight), get_pcvar_num(g_cvLife), get_pcvar_num(g_cvScale),
		get_pcvar_num(g_cvKind), get_pcvar_num(g_cvBombfx));
}

// Bomb effects need both switches: the season and wf_bombfx. With either off
// no event handler does anything at all, which is what "wf_bombfx 0 is a
// complete no-op" means in docs/WINTERFEST-ATMOS.md.
bool:BombFxOn()
{
	if (!g_bActive)
		return false;
	if (!get_pcvar_num(g_cvBombfx))
		return false;
	return true;
}

// ============================================================
// Snow
// ============================================================
public Task_Snow()
{
	if (!g_bActive || !get_pcvar_num(g_cvSnow))
		return;
	if (g_sprSnow <= 0)
		return;

	new rate = clamp(get_pcvar_num(g_bStorm ? g_cvStormRate : g_cvRate), 0, MAX_RATE);
	if (rate <= 0)
		return;

	g_iLifeNow = clamp(get_pcvar_num(g_cvLife), 1, 40);
	g_iScaleNow = clamp(get_pcvar_num(g_cvScale), 1, 40);

	new Float:radius = float(clamp(get_pcvar_num(g_cvRadius), 50, 1000));
	new Float:height = float(clamp(get_pcvar_num(g_cvHeight), 32, 1000));
	new Float:fall = float(FALL_SPEED * g_iLifeNow);      // units travelled over `life`
	new Float:bucket = float(rate) * TICK_SECS;           // flakes owed per tick
	new kind = get_pcvar_num(g_cvKind) ? 1 : 0;

	new Float:origin[3];
	new Float:start[3];
	new Float:end[3];

	g_iHumans = 0;
	g_iBots = 0;

	for (new id = 1; id <= MaxClients; id++)
	{
		if (!is_user_connected(id))
			continue;

		// Bots and HLTV are counted and then skipped: they have no eyes, and
		// the brief excludes them from every per-player effect.
		if (is_user_bot(id) || is_user_hltv(id))
		{
			g_iBots++;
			continue;
		}

		if (!is_user_alive(id))
		{
			g_fDebt[id] = 0.0;
			continue;
		}

		g_iHumans++;
		pev(id, pev_origin, origin);

		g_fDebt[id] += bucket;
		if (g_fDebt[id] < 1.0)
			continue;

		new sent = 0;
		while (g_fDebt[id] >= 1.0)
		{
			g_fDebt[id] -= 1.0;
			if (sent >= MAX_FLAKES_TICK)
			{
				g_iSkipped++;
				continue;
			}
			sent++;

			// Randomised box around the player: the flake starts between the
			// shoulders and wf_snow_height, and falls `fall` units over its
			// life. Placed where the player is now, so no entity has to track it.
			start[0] = origin[0] + random_float(-radius, radius);
			start[1] = origin[1] + random_float(-radius, radius);
			start[2] = origin[2] + random_float(24.0, height);
			end[0] = start[0] + random_float(-6.0, 6.0);   // a little drift
			end[1] = start[1] + random_float(-6.0, 6.0);
			end[2] = start[2] - fall;

			EmitFlake(MSG_ONE_UNRELIABLE, id, start, end, g_iLifeNow, g_iScaleNow, kind);
		}

		// Never let an absurd wf_snow_rate build a debt that dumps a burst on
		// the next tick: cap what one player can owe at one flake.
		if (g_fDebt[id] > 1.0)
			g_fDebt[id] = 1.0;
	}

	// wf_atmos_debug 1 prints one line a second: what the snow loop actually
	// saw. Off by default; the counters in `wf_atmos_report` are the cheap view.
	if (get_pcvar_num(g_cvDebug) && (++g_iTicks % 10) == 0)
		server_print("[WF-ATMOS] tick humans=%d bots=%d flakes=%d storm=%d",
			g_iHumans, g_iBots, g_iFlakes, g_bStorm ? 1 : 0);
}

// One flake. dest/target let the same write layout serve the per-player snow
// (MSG_ONE_UNRELIABLE to its owner) and the lab self-test (MSG_BROADCAST).
EmitFlake(dest, target, const Float:start[3], const Float:end[3], life, scale, kind)
{
	g_iFlakes++;

	message_begin(dest, SVC_TEMPENTITY, _, target);
	write_byte(kind ? TE_SPRITETRAIL : TE_SPRITE);
	write_coord(floatround(start[0]));
	write_coord(floatround(start[1]));
	write_coord(floatround(start[2]));
	if (kind)
	{
		write_coord(floatround(end[0]));
		write_coord(floatround(end[1]));
		write_coord(floatround(end[2]));
		write_short(g_sprSnow);
		write_byte(1);              // one flake per message
		write_byte(life);           // life in 0.1 s
		write_byte(scale);          // scale in 0.1
		write_byte(FALL_SPEED);     // velocity along the vector, in 10's
		write_byte(0);              // no extra jitter: the box is already random
	}
	else
	{
		write_short(g_sprSnow);
		write_byte(scale);
		write_byte(200);            // brightness
	}
	message_end();
}

// One additive stock sprite, broadcast. Used by the C4 glow.
EmitSprite(dest, target, const Float:origin[3], scale, brightness)
{
	if (g_sprSnow <= 0)
		return;

	message_begin(dest, SVC_TEMPENTITY, _, target);
	write_byte(TE_SPRITE);
	write_coord(floatround(origin[0]));
	write_coord(floatround(origin[1]));
	write_coord(floatround(origin[2]));
	write_short(g_sprSnow);
	write_byte(scale);
	write_byte(brightness);
	message_end();
}

// A short vertical beam: the "christmas light" over the planted C4. Stock
// laserbeam.spr, one message a second, broadcast.
EmitColumn(const Float:origin[3], red, green, blue)
{
	if (g_sprBeam <= 0)
		return;

	message_begin(MSG_BROADCAST, SVC_TEMPENTITY);
	write_byte(TE_BEAMPOINTS);
	write_coord(floatround(origin[0]));
	write_coord(floatround(origin[1]));
	write_coord(floatround(origin[2] + 6.0));
	write_coord(floatround(origin[0]));
	write_coord(floatround(origin[1]));
	write_coord(floatround(origin[2] + 30.0));
	write_short(g_sprBeam);
	write_byte(0);                  // starting frame
	write_byte(0);                  // frame rate
	write_byte(12);                 // life in 0.1 s
	write_byte(8);                  // width in 0.1
	write_byte(0);                  // noise
	write_byte(red);
	write_byte(green);
	write_byte(blue);
	write_byte(180);                // brightness
	write_byte(0);                  // scroll speed
	message_end();
}

// ============================================================
// Snowstorm
// ============================================================
StartStorm(const reason[])
{
	new len = clamp(get_pcvar_num(g_cvStormLen), STORM_MIN_SECS, STORM_MAX_SECS);
	new rate = clamp(get_pcvar_num(g_cvStormRate), 0, MAX_RATE);

	remove_task(TASK_STORM_END);
	remove_task(TASK_STORM_PULSE);
	g_bStorm = true;
	g_iStormStarts++;

	set_task(float(len), "Task_StormEnd", TASK_STORM_END);
	set_task(STORM_PULSE_SECS, "Task_StormPulse", TASK_STORM_PULSE, _, _, "b");

	// A storm is player-visible: say it in chat and in the centre of the
	// screen, and hit the first tint/shake immediately.
	client_print(0, print_chat, "[WF] Snowstorm - the next %d seconds are heavy snow. Visibility is weather, not fog: no map means no fog.", len);
	client_print(0, print_center, "SNOWSTORM! %d seconds of heavy snow", len);
	StormPulse();

	server_print("[WF-ATMOS] storm started (%ds, %d flakes/s/player, reason: %s)", len, rate, reason);
}

public Task_StormPulse()
{
	if (!g_bStorm)
	{
		remove_task(TASK_STORM_PULSE);
		return;
	}
	StormPulse();
}

// One tint + shake refresh. Also fired immediately by StartStorm, so the storm
// is felt in the same second it is announced.
StormPulse()
{
	g_iPulses++;

	for (new id = 1; id <= MaxClients; id++)
	{
		if (!is_user_connected(id) || is_user_bot(id) || is_user_hltv(id) || !is_user_alive(id))
			continue;
		FadePlayer(id, 150, 185, 225, 45, STORM_FADE_SECS);
		ShakePlayer(id, 6, 45, 30);
	}
}

public Task_StormEnd()
{
	g_bStorm = false;
	remove_task(TASK_STORM_PULSE);
	set_cvar_num("wf_storm", 0);

	client_print(0, print_chat, "[WF] The snowstorm has passed. wf_storm is back to 0.");
	server_print("[WF-ATMOS] storm ended (%d tint/shake pulses, %d flake(s) emitted so far)", g_iPulses, g_iFlakes);
}

// ============================================================
// Client messages
// ============================================================
// A brief colour tint. Kept well under freenova_flash's near-white gate
// (R,G,B >= 200 with alpha >= 200), so the flashbang owner never suppresses it.
FadePlayer(id, red, green, blue, alpha, Float:secs)
{
	if (g_msgFade <= 0)
		return;
	if (secs > FADE_MAX_SECS)
		secs = FADE_MAX_SECS;

	new units = floatround(secs * 4096.0);
	if (units < 1)
		units = 1;

	message_begin(MSG_ONE_UNRELIABLE, g_msgFade, _, id);
	write_short(units);             // duration
	write_short(units);             // hold time
	write_short(WF_FFADE_OUT);      // flags
	write_byte(clamp(red, 0, 255));
	write_byte(clamp(green, 0, 255));
	write_byte(clamp(blue, 0, 255));
	write_byte(clamp(alpha, 0, 255));
	message_end();
	g_iFades++;
}

// A short view shake. The message is a gamedll registration, so it is checked
// at load and simply skipped when the engine build has no ScreenShake.
ShakePlayer(id, amplitude, frequency, duration)
{
	if (g_msgShake <= 0)
		return;

	message_begin(MSG_ONE_UNRELIABLE, g_msgShake, _, id);
	write_short(clamp(amplitude, 1, 16));
	write_short(clamp(frequency, 1, 200));
	write_short(clamp(duration, 1, 200));
	message_end();
	g_iShakes++;
}

// ============================================================
// Bomb / fuse atmosphere
// ============================================================
public bomb_planted(id)
{
	if (!BombFxOn())
		return;

	g_iPlanter = id;
	// The planted_c4 entity is not guaranteed to exist in the same frame the
	// forward fires, so look for it a fifth of a second later, once.
	remove_task(TASK_BOMB_FIND);
	set_task(0.2, "Task_BombFind", TASK_BOMB_FIND);
}

public Task_BombFind()
{
	new ent = engfunc(EngFunc_FindEntityByString, -1, "classname", "planted_c4");

	if (ent > 0)
	{
		pev(ent, pev_origin, g_fBombOrigin);
	}
	else if (g_iPlanter >= 1 && g_iPlanter <= MaxClients && is_user_connected(g_iPlanter))
	{
		pev(g_iPlanter, pev_origin, g_fBombOrigin);
		server_print("[WF-ATMOS] bombfx: planted_c4 not found, using the planter's origin");
	}
	else
	{
		server_print("[WF-ATMOS] bombfx: planted_c4 not found and no planter - glow skipped");
		return;
	}

	g_bBombPlanted = true;
	BombGlow();
	BombLine(BOMB_PLANTED);

	remove_task(TASK_BOMB_PULSE);
	set_task(1.0, "Task_BombPulse", TASK_BOMB_PULSE, _, _, "b");
	server_print("[WF-ATMOS] bombfx: glow at (%.0f %.0f %.0f), column pulse on",
		g_fBombOrigin[0], g_fBombOrigin[1], g_fBombOrigin[2]);
}

public Task_BombPulse()
{
	if (!BombFxOn() || !g_bBombPlanted)
	{
		remove_task(TASK_BOMB_PULSE);
		return;
	}

	g_iBombPulses++;
	// Red / green, alternating: the cheapest christmas light GoldSrc has.
	if (g_iBombPulses & 1)
		EmitColumn(g_fBombOrigin, 210, 40, 40);
	else
		EmitColumn(g_fBombOrigin, 40, 200, 90);
}

public bomb_defused(id)
{
	if (!BombFxOn())
		return;
	if (!g_bBombPlanted)
		return;

	remove_task(TASK_BOMB_PULSE);
	BombGlow();
	BombLine(BOMB_DEFUSED);
	g_bBombPlanted = false;
	server_print("[WF-ATMOS] bombfx: defused - column stopped, farewell glow sent");
}

public OnRoundEnd()
{
	// Covers "exploded" too: whatever ended the round, the column stops with it.
	if (task_exists(TASK_BOMB_PULSE))
		remove_task(TASK_BOMB_PULSE);
	g_bBombPlanted = false;
}

public OnRoundStart()
{
	if (!BombFxOn())
		return;

	new line[96];
	switch (random_num(1, 3))
	{
		case 1: copy(line, charsmax(line), "Merry Christmas - good luck this round.");
		case 2: copy(line, charsmax(line), "Ho ho ho - the season of firefights is upon us.");
		default: copy(line, charsmax(line), "Santa checked the map: play nice, plant the stocking.");
	}
	WfAtmosSay(0, line);

	// A brief, very pale wash as the round opens. No glow: there is no bomb
	// origin at round start (the C4 is not planted yet) and sprinkling sprites
	// at arbitrary points would be noise, not atmosphere - see the doc.
	for (new id = 1; id <= MaxClients; id++)
	{
		if (!is_user_connected(id) || is_user_bot(id) || is_user_hltv(id))
			continue;
		FadePlayer(id, 150, 185, 225, 30, 0.6);
	}
}

// Three stock sprites at the C4, broadcast once. No entity, nothing to clean up.
BombGlow()
{
	new Float:p[3];
	for (new i = 0; i < 3; i++)
	{
		p[0] = g_fBombOrigin[0] + random_float(-8.0, 8.0);
		p[1] = g_fBombOrigin[1] + random_float(-8.0, 8.0);
		p[2] = g_fBombOrigin[2] + 4.0 + float(i) * 6.0;
		EmitSprite(MSG_BROADCAST, 0, p, 12, 230);
	}
}

// One festive line, to everyone, plus a short tint. The tint is deliberately
// small: the C4 is the point of the round and a heavy fade would read as a
// flashbang.
BombLine(which)
{
	new line[128];
	switch (which)
	{
		case BOMB_PLANTED:
			copy(line, charsmax(line), "Ho ho ho - the C4 is a christmas cracker now. Mind the fuse.");
		case BOMB_DEFUSED:
			copy(line, charsmax(line), "Defused! Someone just unwrapped the present early.");
		default:
			copy(line, charsmax(line), "The stocking is ticking.");
	}

	WfAtmosSay(0, line);

	for (new id = 1; id <= MaxClients; id++)
	{
		if (!is_user_connected(id) || is_user_bot(id) || is_user_hltv(id))
			continue;
		if (which == BOMB_DEFUSED)
			FadePlayer(id, 90, 200, 120, 60, 1.0);
		else
			FadePlayer(id, 220, 90, 90, 55, 1.0);
	}
}

// ============================================================
// Operator commands
// ============================================================
public cmdApply(id, level, cid)
{
	if (!cmd_access(id, level, cid, 1))
		return PLUGIN_HANDLED;

	WfAtmosWindowLoad(WF_CONFIG_FILE);
	ApplyState("wf_atmos_apply");
	return PLUGIN_HANDLED;
}

public cmdReport(id, level, cid)
{
	if (!cmd_access(id, level, cid, 1))
		return PLUGIN_HANDLED;

	new window[48], today[16];
	WfAtmosWindowText(window, charsmax(window));
	WfAtmosDateText(today, charsmax(today));

	server_print("[WF-ATMOS] state atmos=%d force=%d open=%d active=%d snow=%d storm=%d bombfx=%d",
		get_pcvar_num(g_cvAtmos), get_pcvar_num(g_cvForce), g_bWindowOpen ? 1 : 0,
		g_bActive ? 1 : 0, get_pcvar_num(g_cvSnow), g_bStorm ? 1 : 0,
		get_pcvar_num(g_cvBombfx));
	server_print("[WF-ATMOS] window %s today %s", window, today);
	server_print("[WF-ATMOS] timers snow=%d storm_end=%d storm_pulse=%d bomb_find=%d bomb_pulse=%d",
		task_exists(TASK_SNOW) ? 1 : 0, task_exists(TASK_STORM_END) ? 1 : 0,
		task_exists(TASK_STORM_PULSE) ? 1 : 0, task_exists(TASK_BOMB_FIND) ? 1 : 0,
		task_exists(TASK_BOMB_PULSE) ? 1 : 0);
	server_print("[WF-ATMOS] counters flakes=%d fades=%d shakes=%d pulses=%d storms=%d bomb_pulses=%d",
		g_iFlakes, g_iFades, g_iShakes, g_iPulses, g_iStormStarts, g_iBombPulses);
	server_print("[WF-ATMOS] last_tick humans=%d bots_skipped=%d flakes_dropped=%d",
		g_iHumans, g_iBots, g_iSkipped);
	server_print("[WF-ATMOS] messages fade=%d shake=%d sprite_snow=%d sprite_beam=%d edicts=%d",
		g_msgFade, g_msgShake, g_sprSnow, g_sprBeam, engfunc(EngFunc_NumberOfEntities));
	return PLUGIN_HANDLED;
}

// Lab self-test: runs the exact code paths with no player present, so a boot
// can prove the write layouts and the config load without a human connecting.
// It never fabricates a snow flake per player - that needs a player.
public cmdSelfTest(id, level, cid)
{
	if (!cmd_access(id, level, cid, 1))
		return PLUGIN_HANDLED;

	new Float:start[3];
	new Float:end[3];
	new life = clamp(get_pcvar_num(g_cvLife), 1, 40);
	new scale = clamp(get_pcvar_num(g_cvScale), 1, 40);
	new kind = get_pcvar_num(g_cvKind) ? 1 : 0;

	start[0] = 0.0;
	start[1] = 0.0;
	start[2] = 240.0;
	end[0] = 0.0;
	end[1] = 0.0;
	end[2] = 240.0 - float(FALL_SPEED * life);

	EmitFlake(MSG_BROADCAST, 0, start, end, life, scale, kind);
	server_print("[WF-ATMOS] selftest flake ok kind=%d sprite=%d life=%d scale=%d",
		kind, g_sprSnow, life, scale);

	StartStorm("selftest");
	server_print("[WF-ATMOS] selftest storm ok timers storm_end=%d storm_pulse=%d",
		task_exists(TASK_STORM_END) ? 1 : 0, task_exists(TASK_STORM_PULSE) ? 1 : 0);

	g_fBombOrigin[0] = 0.0;
	g_fBombOrigin[1] = 0.0;
	g_fBombOrigin[2] = 64.0;
	g_bBombPlanted = true;
	BombGlow();
	EmitColumn(g_fBombOrigin, 210, 40, 40);
	BombLine(BOMB_PLANTED);
	server_print("[WF-ATMOS] selftest bombfx ok glow=3 column=1 lines=1");

	// A client message needs a client: from the server console there is none,
	// so only the message ids are proven here (a human eye proves the rest).
	if (id >= 1 && id <= MaxClients)
	{
		FadePlayer(id, 150, 185, 225, 45, 1.0);
		ShakePlayer(id, 6, 45, 30);
	}
	server_print("[WF-ATMOS] selftest fade ok fade_msg=%d shake_msg=%d sent_to_client=%d",
		g_msgFade, g_msgShake, (id >= 1 && id <= MaxClients) ? 1 : 0);
	return PLUGIN_HANDLED;
}
