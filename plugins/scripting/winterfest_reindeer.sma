/*
 * ============================================================================
 * winterfest_reindeer - reindeer hunt (workstream 7, mode B)
 * ============================================================================
 * Product contract: docs/WINTERFEST.md §3 ("snowballs, reindeer hunt ... each a
 * mode; they plug into the fn_mode arbiter being built now"). Workstream map:
 * docs/WINTERFEST-WORKSTREAMS.md row 7. Tuning, the ini format, the arbiter
 * contract and what a human has to check in game: docs/WINTERFEST-MODES.md.
 *
 * WHAT THIS PLUGIN OWNS
 *   - the "reindeer" mode on the fn_mode arbiter (begin/end; it changes no
 *     engine cvar, so its table is empty - the arbiter still matters, because a
 *     hunt must never run on top of a warmup or an event mode);
 *   - the targets: a few non-solid `info_target` markers with a stock-sprite
 *     glow. Nothing is SOLID, nothing blocks a player, nothing is placed with
 *     `func_breakable`, and nothing is ever a `player` entity - a reindeer can
 *     never turn into a bot, get counted by get_players(), or be shot by a
 *     bot's aimbot logic;
 *   - the hit test: the server re-traces every bullet the player fires and asks
 *     "did that line pass within `radius` of a live reindeer, with a clear line
 *     of sight". A non-solid entity cannot be hit by a bullet in GoldSrc (the
 *     bullet trace only tests solid entities), so a shootable *marker* has to be
 *     geometry - this is the honest way to do it;
 *   - the reward: snowflakes through winterfest_core's single grant path, once
 *     per reindeer instance (the instance id is the claim key), and only when
 *     that library is loaded. No core => the hunt still runs, it just pays
 *     nothing (a server without the core behaves like today, rule 2 of the
 *     workstream map);
 *   - `wf_reindeer <on|off|status>` for an operator, and the natives the mode
 *     owner (winterfest_snow) uses for `wf_mode reindeer` and the rotation.
 *
 * HIT DETECTION, IN ONE PARAGRAPH
 *   Every real weapon (the 24 gun classes, no knife) gets one
 *   Ham_Weapon_PrimaryAttack pre-hook, the same idiom rsu_core.sma uses for shot
 *   counting: one trigger pull = one hook. The hook is a no-op unless the mode
 *   is running. When it is, the plugin takes the shooter's eye position and view
 *   angle, projects the deer origin onto that ray, and accepts the shot when the
 *   point is ahead, inside range and within `radius` of the ray - then traces
 *   eye -> deer to make sure a wall is not in the way. Pellet spread, recoil
 *   punch and bullet drop do not exist in this engine for the first pellet, so
 *   the view angle is what a player expects to aim with.
 *
 * NO CLIENT ASSET: sprites/glow01.spr (already precached by the present module
 * and the effects module, so this costs no extra precache item - see
 * docs/PRECACHE-BUDGET.md §3).
 * ============================================================================
 */

#include <amxmodx>
#include <amxmisc>
#include <engine>
#include <fakemeta>
#include <hamsandwich>
#include <vector>
#include <fn_mode>
#include <winterfest>

#define PLUGIN  "Winterfest Reindeer Hunt"
#define VERSION "1.0.0"
#define AUTHOR  "FreeNova"

#define MODE_NAME   "reindeer"
#define MODES_INI   "freenova/winterfest/modes.ini"

#define MAX_DEER    8        // live targets at once (also the [modes] count cap)
#define MAX_SPOTS   32       // spawn points for the current map

enum
{
	TASK_MODE_CLOCK = 93600
}

// The guns. Knife is deliberately absent: a melee swing is not a bullet and its
// "hit" would be a 4000-unit line in the same hook. Every class here is a real
// CS 1.6 weapon entity (the list is rsu_core.sma's, minus weapon_knife).
new const g_szShotWeapons[][] =
{
	"weapon_p228", "weapon_scout", "weapon_xm1014", "weapon_mac10",
	"weapon_aug", "weapon_elite", "weapon_fiveseven", "weapon_ump45",
	"weapon_sg550", "weapon_galil", "weapon_famas", "weapon_usp",
	"weapon_glock18", "weapon_awp", "weapon_mp5navy", "weapon_m249",
	"weapon_m3", "weapon_m4a1", "weapon_tmp", "weapon_g3sg1",
	"weapon_deagle", "weapon_sg552", "weapon_ak47", "weapon_p90"
};

// Config: [modes] (the reindeer row), [reindeer], [reindeer_spots] -----------
new bool:g_bIniDeer = true;
new g_iRounds = 2;
new Float:g_fMaxSeconds = 600.0;

new g_iCount = 3;
new Float:g_fRespawn = 20.0;
new g_iReward = 5;
new Float:g_fRadius = 40.0;
new Float:g_fRange = 4000.0;
new g_iGlowScale = 110;

// The look, from modes.ini [reindeer] visual. Only "sprite" exists today: a
// reindeer or snowman model (models/traineau_2.mdl, sneeuwman.mdl, frost_man.mdl
// staged in thirdparty/winterfest-assets/) is client content and blocked until
// fastdl works - docs/WINTERFEST.md §1.1. Read, logged and refused rather than
// silently ignored, so a later model swap is one accepted value, no code change.
new g_szVisual[24] = "sprite";

// Spots for the current map.
new g_iSpotCount;
new Float:g_fSpotOrigin[MAX_SPOTS][3];

// Deer state ----------------------------------------------------------------
new g_iDeerEnt[MAX_DEER];            // the info_target marker (the target)
new g_iDeerGlow[MAX_DEER];           // the env_sprite you can see
new Float:g_fDeerOrigin[MAX_DEER][3];
new bool:g_bDeerAlive[MAX_DEER];
new g_iDeerSpot[MAX_DEER];
new g_iDeerSerial[MAX_DEER];         // claim key: one instance pays once
new Float:g_fDeerNext[MAX_DEER];     // gametime to respawn

// Mode state ----------------------------------------------------------------
new bool:g_bMode;
new bool:g_bForced;                  // started with `force`: empty-server guard off
new g_iRoundsLeft;
new g_iModeSeconds;
new g_iSerials;
new g_iKills;
new g_iStarts;
new g_iEnds;

new g_sprGlow;

// Cvars: the live switch. Everything else is modes.ini. ---------------------
new g_pEnable;
new g_pDebug;

// Natives of the module owner (declared here on purpose: include/winterfest.inc
// belongs to workstream 1 and workstream 7 must not edit it).
//
// Deliberately NO native call into winterfest_snow: "is the snow mode running"
// is answered from the arbiter (fn_mode_active), which is registered before both
// modules and needs no load-order luck. A native registered by a plugin that
// loads later may resolve to a no-op stub, and a status line that quietly says
// "0" while the other mode runs would be a lie.

// ============================================================
// Lifecycle
// ============================================================
public plugin_natives()
{
	register_library("winterfest_reindeer");
	register_native("wf_reindeer_start", "_start");
	register_native("wf_reindeer_stop", "_stop");
	register_native("wf_reindeer_active", "_active");
	register_native("wf_reindeer_reload", "_reload");
	set_native_filter("WfNativeFilter");
}

/* Same contract as winterfest_snow: an absent optional library is a clean load
 * (trap == 0 is swallowed), a call to a native that is missing at run time stays
 * a loud error, and every call site is guarded by LibraryExists anyway. */
public WfNativeFilter(const name[], index, trap)
{
	#pragma unused index
	if (trap)
		return PLUGIN_CONTINUE;

	if (contain(name, "fn_mode") == 0)
	{
		if (!LibraryExists("fn_mode", LibType_Library))
			return PLUGIN_HANDLED;
		return PLUGIN_CONTINUE;
	}
	if (contain(name, "wf_snow_") == 0)
	{
		if (!LibraryExists("winterfest_snow", LibType_Library))
			return PLUGIN_HANDLED;
		return PLUGIN_CONTINUE;
	}
	if (contain(name, "wf_") == 0 && !LibraryExists("winterfest_core", LibType_Library))
		return PLUGIN_HANDLED;

	return PLUGIN_CONTINUE;
}

public plugin_precache()
{
	g_sprGlow = precache_model("sprites/glow01.spr");
}

public plugin_init()
{
	register_plugin(PLUGIN, VERSION, AUTHOR);

	g_pEnable = register_cvar("wf_reindeer_enable", "1");
	g_pDebug  = register_cvar("wf_modes_debug", "0");

	register_concmd("wf_reindeer", "cmdReindeer", ADMIN_CFG, "<on|off|status> - the Winterfest reindeer hunt");

	for (new w = 0; w < sizeof(g_szShotWeapons); w++)
		RegisterHam(Ham_Weapon_PrimaryAttack, g_szShotWeapons[w], "Ham_WeaponAttack_Pre", 0);

	register_event("HLTV", "ev_NewRound", "a", "1=0", "2=0");

	if (!LibraryExists("fn_mode", LibType_Library))
		log_amx("[WF-REINDEER] fn_mode missing - every start will be refused (the mode arbiter must load first)");
	if (!LibraryExists("winterfest_core", LibType_Library))
		log_amx("[WF-REINDEER] winterfest_core missing - the hunt runs, reindeer just pay nothing");

	server_print("[FreeNova winterfest_reindeer] ready (build 1)");
}

public plugin_cfg()
{
	g_bMode = false;
	g_iRoundsLeft = 0;
	g_iModeSeconds = 0;
	remove_task(TASK_MODE_CLOCK);
	loadConfig();
}

public plugin_end()
{
	remove_task(TASK_MODE_CLOCK);
	if (g_bMode)
		EndHunt("plugin_end");
	KillAllDeer();
}

// ============================================================
// Config: configs/freenova/winterfest/modes.ini
// ============================================================
loadConfig()
{
	g_bIniDeer = true;
	g_iRounds = 2;
	g_fMaxSeconds = 600.0;
	g_iCount = 3;
	g_fRespawn = 20.0;
	g_iReward = 5;
	g_fRadius = 40.0;
	g_fRange = 4000.0;
	g_iGlowScale = 110;
	g_iSpotCount = 0;

	new path[160], cfgdir[96];
	get_configsdir(cfgdir, charsmax(cfgdir));
	formatex(path, charsmax(path), "%s/%s", cfgdir, MODES_INI);

	if (!file_exists(path))
	{
		log_amx("[WF-REINDEER] no %s - built-in defaults, spawn-derived spots", path);
		loadSpots(path);
		return;
	}

	new fp = fopen(path, "rt");
	if (fp)
	{
		new line[256], section[32], key[32], val[96];
		section[0] = EOS;

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
					section[close] = EOS;
				trim(section);
				strtolower(section);
				continue;
			}

			if (equal(section, "modes"))
			{
				parseModeRow(line);
				continue;
			}
			if (!equal(section, "reindeer"))
				continue;
			if (!KeyValue(line, key, charsmax(key), val, charsmax(val)))
				continue;
			applyReindeer(key, val);
		}
		fclose(fp);
	}

	loadSpots(path);
	log_amx("[WF-REINDEER] modes.ini: reindeer=%d count=%d respawn=%.0fs reward=%d radius=%.0f spots=%d",
		g_bIniDeer ? 1 : 0, g_iCount, g_fRespawn, g_iReward, g_fRadius, g_iSpotCount);
}

/* id | enabled | rounds | max_seconds  - only the reindeer row is ours. */
parseModeRow(const line[])
{
	new id[24];
	if (!WfField(line, 0, id, charsmax(id)) || !equali(id, "reindeer"))
		return;

	g_bIniDeer = (WfFieldInt(line, 1, 1) != 0) ? true : false;
	g_iRounds = clamp(WfFieldInt(line, 2, g_iRounds), 1, 50);
	g_fMaxSeconds = float(clamp(WfFieldInt(line, 3, floatround(g_fMaxSeconds)), 0, 36000));
}

applyReindeer(const key[], const val[])
{
	if (equal(key, "count"))
		g_iCount = clamp(str_to_num(val), 1, MAX_DEER);
	else if (equal(key, "respawn"))
		g_fRespawn = floatclamp(str_to_float(val), 1.0, 600.0);
	else if (equal(key, "reward"))
		g_iReward = clamp(str_to_num(val), 0, 1000);
	else if (equal(key, "radius"))
		g_fRadius = floatclamp(str_to_float(val), 8.0, 200.0);
	else if (equal(key, "range"))
		g_fRange = floatclamp(str_to_float(val), 200.0, 8192.0);
	else if (equal(key, "glow_scale"))
		g_iGlowScale = clamp(str_to_num(val), 20, 400);
	else if (equal(key, "visual"))
	{
		copy(g_szVisual, charsmax(g_szVisual), val);
		strtolower(g_szVisual);
	}
}

/* Two passes over [reindeer_spots]: the rows for this map, and only when there
 * are none, the '*' rows. With neither, the built-in spawn-derived set - the
 * same "never ship zero spots" rule winterfest_gifts uses for presents. */
loadSpots(const path[])
{
	g_iSpotCount = 0;

	new map[32];
	get_mapname(map, charsmax(map));

	if (file_exists(path))
	{
		new fp = fopen(path, "rt");
		if (fp)
		{
			new line[256], section[32], use_generic = -1;
			section[0] = EOS;

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
						section[close] = EOS;
					trim(section);
					strtolower(section);
					continue;
				}
				if (!equal(section, "reindeer_spots"))
					continue;

				new who[32];
				if (!WfField(line, 0, who, charsmax(who)))
					continue;
				new bool:mine = equali(who, map) ? true : false;
				new bool:generic = equal(who, "*") ? true : false;
				if (!mine && !generic)
					continue;

				if (use_generic < 0)
					use_generic = mine ? 0 : 1;
				if ((mine && use_generic != 0) || (generic && use_generic != 1))
					continue;

				AddSpot(line);
			}
			fclose(fp);
		}
	}

	if (!g_iSpotCount)
		AddBuiltinSpots();

	log_amx("[WF-REINDEER] %d spawn point(s) on %s", g_iSpotCount, map);

	// wf_modes_debug 1: where they are. This is the command an operator runs
	// after editing [reindeer_spots] ("I moved a row, did it land?"), and it is
	// how the shipped de_dust2 rows were measured.
	if (get_pcvar_num(g_pDebug))
	{
		for (new i = 0; i < g_iSpotCount; i++)
			log_amx("[WF-REINDEER] spot %d = %.0f %.0f %.0f",
				i, g_fSpotOrigin[i][0], g_fSpotOrigin[i][1], g_fSpotOrigin[i][2]);
	}
}

AddSpot(const line[])
{
	if (g_iSpotCount >= MAX_SPOTS)
	{
		log_amx("[WF-REINDEER] more than %d spots - extra rows ignored", MAX_SPOTS);
		return;
	}

	new spec[48];
	if (!WfField(line, 1, spec, charsmax(spec)))
		return;

	new Float:origin[3];
	if (!SpotOrigin(spec, origin))
	{
		log_amx("[WF-REINDEER] spot '%s' could not be resolved - skipped", spec);
		return;
	}

	new slot = g_iSpotCount;
	g_fSpotOrigin[slot][0] = origin[0];
	g_fSpotOrigin[slot][1] = origin[1];
	g_fSpotOrigin[slot][2] = origin[2];
	g_iSpotCount++;
}

/* Four spawns per side with a small jitter and 64 units of height. A spawn
 * origin is always inside the playable area, so this can never put a marker in
 * the void; the jitter keeps two maps of the same size from looking identical. */
AddBuiltinSpots()
{
	// Spawn classes in the order CS maps actually use them, and *both ends* of
	// the map: info_player_start first (several maps carry only that one, and
	// de_dust2's own spawns are all info_player_start), then the team spawns.
	// Eight start slots cover two spawn corners on the maps that have them; a
	// spec the map does not have is skipped, so the list is a menu, not a
	// requirement. Measured on de_dust2: 6 start points in the T corner.
	new const specs[16][] =
	{
		"@start1", "@start2", "@start3", "@start4",
		"@start5", "@start6", "@start7", "@start8",
		"@t1", "@t2", "@t3", "@t4",
		"@ct1", "@ct2", "@ct3", "@ct4"
	};

	for (new i = 0; i < sizeof(specs); i++)
	{
		if (g_iSpotCount >= MAX_SPOTS)
			return;
		new Float:origin[3];
		if (!SpotOrigin(specs[i], origin))
			continue;
		new slot = g_iSpotCount;
		g_fSpotOrigin[slot][0] = origin[0] + random_float(-96.0, 96.0);
		g_fSpotOrigin[slot][1] = origin[1] + random_float(-96.0, 96.0);
		g_fSpotOrigin[slot][2] = origin[2] + 64.0;
		g_iSpotCount++;
	}
}

/* "x y z" (float) or a spawn reference "@t<N>", "@ct<N>", "@start<N>". */
stock bool:SpotOrigin(const spec[], Float:origin[3])
{
	if (spec[0] == '@')
	{
		new cls[40], index = 0;
		if (containi(spec, "@ct") == 0)
		{
			copy(cls, charsmax(cls), "info_player_counterterrorist");
			index = str_to_num(spec[3]);
		}
		else if (containi(spec, "@t") == 0)
		{
			copy(cls, charsmax(cls), "info_player_terrorist");
			index = str_to_num(spec[2]);
		}
		else if (containi(spec, "@start") == 0)
		{
			copy(cls, charsmax(cls), "info_player_start");
			index = str_to_num(spec[6]);
		}
		else
			return false;

		if (index < 1)
			return false;

		// find_ent_by_class takes -1 for "start from the beginning" (the
		// engine_stocks.sma convention); 0 is the world entity, not the start.
		new found = 0, ent = -1;
		while ((ent = find_ent_by_class(ent, cls)) > 0)
		{
			found++;
			if (found != index)
				continue;
			pev(ent, pev_origin, origin);
			origin[2] += 24.0;
			return true;
		}
		return false;
	}

	return ParseVector(spec, origin);
}

stock bool:ParseVector(const spec[], Float:out[3])
{
	new buf[20], field = 0, c = 0;
	out[0] = 0.0;
	out[1] = 0.0;
	out[2] = 0.0;

	for (new i = 0; ; i++)
	{
		new ch = spec[i];
		if (ch == ' ' || ch == ',' || ch == '^t' || ch == EOS)
		{
			if (c > 0)
			{
				buf[c] = EOS;
				if (field < 3)
					out[field] = str_to_float(buf);
				field++;
				c = 0;
			}
			if (ch == EOS)
				break;
			continue;
		}
		if (c < charsmax(buf) - 1)
			buf[c++] = ch;
	}
	return (field >= 3) ? true : false;
}

stock bool:KeyValue(const line[], key[], keylen, val[], vallen)
{
	new eq = contain(line, "=");
	if (eq < 1)
		return false;
	copy(key, keylen, line);
	key[eq] = EOS;
	trim(key);
	strtolower(key);
	copy(val, vallen, line[eq + 1]);
	trim(val);
	return key[0] ? true : false;
}

// ============================================================
// Mode lifecycle
// ============================================================
bool:StartHunt(initiator, bool:bForce = false)
{
	if (g_bMode)
	{
		Refuse(initiator, "the reindeer hunt is already running (wf_reindeer off ends it)");
		return false;
	}
	if (!get_pcvar_num(g_pEnable) || !g_bIniDeer)
	{
		Refuse(initiator, "the reindeer hunt is disabled (wf_reindeer_enable / modes.ini [modes] enabled)");
		return false;
	}
	if (!LibraryExists("fn_mode", LibType_Library))
	{
		Refuse(initiator, "fn_mode (the mode arbiter) is not loaded - no mode can start");
		return false;
	}
	if (g_iSpotCount < 1)
	{
		Refuse(initiator, "no spawn points for this map (modes.ini [reindeer_spots])");
		return false;
	}

	new payload[64];
	formatex(payload, charsmax(payload), "deer=%d rounds=%d spots=%d", g_iCount, g_iRounds, g_iSpotCount);

	if (!fn_mode_begin(MODE_NAME, payload, initiator))
	{
		new why[192];
		fn_mode_refusal(why, charsmax(why));
		console_print(0, "[WF-REINDEER] not started: %s", why);
		log_amx("[WF-REINDEER] not started: %s", why);
		return false;
	}

	g_bMode = true;
	g_bForced = bForce;
	g_iRoundsLeft = g_iRounds;
	g_iModeSeconds = 0;
	g_iKills = 0;
	g_iStarts++;

	// The model visual is staged but blocked (client content, docs/WINTERFEST.md
	// §1.1): say so once per start rather than quietly drawing the glow.
	if (!equali(g_szVisual, "sprite"))
		log_amx("[WF-REINDEER] visual '%s' is not available - client models are blocked by fastdl; using the stock sprite", g_szVisual);

	// No engine cvar to change: this mode adds targets, it does not rewrite the
	// round. fn_mode still owns the "one mode at a time" slot (a hunt on top of
	// a warmup would be two rules fighting) and its plugin_end is the net.
	SpawnAllDeer();

	new reward[96];
	if (g_iReward > 0 && LibraryExists("winterfest_core", LibType_Library))
		formatex(reward, charsmax(reward), "%d snowflakes each", g_iReward);
	else
		formatex(reward, charsmax(reward), "no reward configured");

	client_print(0, print_chat, "[WF] Reindeer hunt! %d reindeer are around the map - %s.", g_iCount, reward);
	log_amx("[WF-REINDEER] started by %d (deer=%d rounds=%d spots=%d reward=%d forced=%d tracked=%d)",
		initiator, g_iCount, g_iRounds, g_iSpotCount, g_iReward, g_bForced ? 1 : 0, fn_mode_count());

	remove_task(TASK_MODE_CLOCK);
	set_task(1.0, "Task_ModeClock", TASK_MODE_CLOCK, _, _, "b");
	return true;
}

EndHunt(const reason[])
{
	if (!g_bMode)
		return;

	remove_task(TASK_MODE_CLOCK);
	g_bMode = false;
	g_bForced = false;
	KillAllDeer();

	new restored = 0;
	if (LibraryExists("fn_mode", LibType_Library))
		restored = fn_mode_end(MODE_NAME);

	g_iEnds++;
	client_print(0, print_chat, "[WF] Reindeer hunt over - %d shot. Normal play resumes.", g_iKills);
	log_amx("[WF-REINDEER] ended (%s) kills=%d - %d cvar(s) restored", reason, g_iKills, restored);
}

Refuse(initiator, const reason[])
{
	if (initiator > 0 && initiator <= MaxClients && is_user_connected(initiator) && !is_user_bot(initiator))
		WfSay(initiator, reason);
	else
		console_print(0, "[WF-REINDEER] %s", reason);
	log_amx("[WF-REINDEER] refused: %s", reason);
}

public ev_NewRound()
{
	if (!g_bMode)
		return;

	g_iRoundsLeft--;
	if (g_iRoundsLeft <= 0)
		EndHunt("rounds used up");
}

public Task_ModeClock()
{
	if (!g_bMode)
	{
		remove_task(TASK_MODE_CLOCK);
		return;
	}

	g_iModeSeconds++;

	if (!g_bForced && CountHumans() < 1)
	{
		EndHunt("server empty");
		return;
	}
	if (g_fMaxSeconds > 0.0 && float(g_iModeSeconds) >= g_fMaxSeconds)
	{
		EndHunt("time limit");
		return;
	}

	new Float:now = get_gametime();
	for (new slot = 0; slot < MAX_DEER; slot++)
	{
		if (g_bDeerAlive[slot] || g_fDeerNext[slot] <= 0.0)
			continue;
		if (now >= g_fDeerNext[slot])
			SpawnDeer(slot);
	}
}

// ============================================================
// Spawning
// ============================================================
SpawnAllDeer()
{
	for (new slot = 0; slot < MAX_DEER; slot++)
	{
		KillDeer(slot);
		g_fDeerNext[slot] = 0.0;
	}

	new want = clamp(g_iCount, 1, MAX_DEER);
	for (new slot = 0; slot < want; slot++)
		SpawnDeer(slot);

	log_amx("[WF-REINDEER] spawned %d/%d reindeer", want, MAX_DEER);
}

SpawnDeer(slot)
{
	if (slot < 0 || slot >= MAX_DEER || g_iSpotCount < 1)
		return;

	new spot = PickSpot();
	if (spot < 0)
		return;

	KillDeer(slot);

	new Float:origin[3];
	origin[0] = g_fSpotOrigin[spot][0] + random_float(-24.0, 24.0);
	origin[1] = g_fSpotOrigin[spot][1] + random_float(-24.0, 24.0);
	origin[2] = g_fSpotOrigin[spot][2];

	g_iDeerEnt[slot] = CreateMarker(origin);
	if (g_iDeerEnt[slot] <= 0)
	{
		log_amx("[WF-REINDEER] could not create the marker for slot %d", slot);
		return;
	}

	g_iDeerGlow[slot] = CreateGlow(origin);
	g_fDeerOrigin[slot][0] = origin[0];
	g_fDeerOrigin[slot][1] = origin[1];
	g_fDeerOrigin[slot][2] = origin[2];
	g_iDeerSpot[slot] = spot;
	g_iSerials++;
	g_iDeerSerial[slot] = g_iSerials;
	g_bDeerAlive[slot] = true;
	g_fDeerNext[slot] = 0.0;

	SpriteBurst(origin, 12);
}

/* A spot that already has a live reindeer is skipped; if every spot is taken,
 * the least-bad answer is to reuse one instead of spawning nothing. */
stock PickSpot()
{
	if (g_iSpotCount < 1)
		return -1;

	new start = random_num(0, g_iSpotCount - 1);
	for (new attempt = 0; attempt < g_iSpotCount; attempt++)
	{
		new spot = (start + attempt) % g_iSpotCount;
		new bool:used = false;
		for (new slot = 0; slot < MAX_DEER; slot++)
		{
			if (g_bDeerAlive[slot] && g_iDeerSpot[slot] == spot)
			{
				used = true;
				break;
			}
		}
		if (!used)
			return spot;
	}
	return start;
}

/* The target itself: an `info_target`, SOLID_NOT, MOVETYPE_NONE. It has no
 * model, cannot be touched, cannot block, and is not a player class, so nothing
 * in the engine can turn it into a bot. */
stock CreateMarker(const Float:origin[3])
{
	new ent = engfunc(EngFunc_CreateNamedEntity, engfunc(EngFunc_AllocString, "info_target"));
	if (!ent || !pev_valid(ent))
		return 0;

	set_pev(ent, pev_classname, "wf_reindeer");
	set_pev(ent, pev_origin, origin);
	set_pev(ent, pev_solid, SOLID_NOT);
	set_pev(ent, pev_movetype, MOVETYPE_NONE);
	dllfunc(DLLFunc_Spawn, ent);
	return ent;
}

stock CreateGlow(const Float:origin[3])
{
	new ent = engfunc(EngFunc_CreateNamedEntity, engfunc(EngFunc_AllocString, "env_sprite"));
	if (!ent || !pev_valid(ent))
		return 0;

	new Float:color[3];
	color[0] = 255.0;
	color[1] = 235.0;
	color[2] = 190.0;

	engfunc(EngFunc_SetModel, ent, "sprites/glow01.spr");
	set_pev(ent, pev_origin, origin);
	set_pev(ent, pev_rendermode, kRenderGlow);
	set_pev(ent, pev_renderamt, 220.0);
	set_pev(ent, pev_rendercolor, color);
	set_pev(ent, pev_scale, float(g_iGlowScale) / 100.0);
	set_pev(ent, pev_solid, SOLID_NOT);
	set_pev(ent, pev_movetype, MOVETYPE_NONE);
	dllfunc(DLLFunc_Spawn, ent);
	return ent;
}

KillDeer(slot)
{
	if (slot < 0 || slot >= MAX_DEER)
		return;

	KillEntity(g_iDeerEnt[slot]);
	KillEntity(g_iDeerGlow[slot]);
	g_bDeerAlive[slot] = false;
	g_iDeerSerial[slot] = 0;
	g_iDeerSpot[slot] = -1;
	g_fDeerNext[slot] = 0.0;
}

KillAllDeer()
{
	for (new slot = 0; slot < MAX_DEER; slot++)
		KillDeer(slot);
}

stock KillEntity(&ent)
{
	if (ent > 0 && pev_valid(ent))
		set_pev(ent, pev_flags, pev(ent, pev_flags) | FL_KILLME);
	ent = 0;
}

// ============================================================
// Hit detection
// ============================================================
public Ham_WeaponAttack_Pre(weapon)
{
	if (!g_bMode)
		return HAM_IGNORED;

	new id = pev(weapon, pev_owner);
	if (!(1 <= id <= MaxClients) || !is_user_connected(id))
		return HAM_IGNORED;
	if (is_user_bot(id) || is_user_hltv(id) || !is_user_alive(id))
		return HAM_IGNORED;

	CheckShot(id);
	return HAM_IGNORED;
}

CheckShot(id)
{
	new iorigin[3];
	get_user_origin(id, iorigin, 1);              // eye position

	new Float:eye[3];
	eye[0] = float(iorigin[0]);
	eye[1] = float(iorigin[1]);
	eye[2] = float(iorigin[2]);

	new Float:dir[3];
	velocity_by_aim(id, 1000, dir);
	new Float:len = floatsqroot(dir[0] * dir[0] + dir[1] * dir[1] + dir[2] * dir[2]);
	if (len < 1.0)
		return;
	dir[0] = dir[0] / len;
	dir[1] = dir[1] / len;
	dir[2] = dir[2] / len;

	new Float:rad2 = g_fRadius * g_fRadius;
	new bDebug = get_pcvar_num(g_pDebug);
	new Float:best = -1.0;
	new best_slot = -1;

	for (new slot = 0; slot < MAX_DEER; slot++)
	{
		if (!g_bDeerAlive[slot])
			continue;

		new Float:to[3];
		to[0] = g_fDeerOrigin[slot][0] - eye[0];
		to[1] = g_fDeerOrigin[slot][1] - eye[1];
		to[2] = g_fDeerOrigin[slot][2] - eye[2];

		new Float:along = to[0] * dir[0] + to[1] * dir[1] + to[2] * dir[2];
		if (along < 32.0 || along > g_fRange)
			continue;

		new Float:dist2 = to[0] * to[0] + to[1] * to[1] + to[2] * to[2];
		new Float:perp2 = dist2 - along * along;
		if (bDebug && (best < 0.0 || perp2 < best))
		{
			best = perp2;
			best_slot = slot;
		}
		if (perp2 > rad2)
			continue;

		// Line of sight: a wall between the eye and the marker means no hit,
		// even when the ray's geometry is perfect (the marker never blocks a
		// bullet, so the trace has to be ours).
		engfunc(EngFunc_TraceLine, eye, g_fDeerOrigin[slot], 0, id, 0);
		new Float:frac = 1.0;
		get_tr2(0, TR_flFraction, frac);
		if (frac < 0.95)
			continue;

		HitDeer(id, slot);
		return;
	}

	// wf_modes_debug 1: one line per shot that got near a reindeer but missed,
	// which is the number an operator tuning `radius` actually wants.
	if (bDebug && best_slot >= 0)
		log_amx("[WF-REINDEER] id %d missed reindeer slot %d by %.0f units (radius %.0f)",
			id, best_slot, floatsqroot(best), g_fRadius);
}

HitDeer(id, slot)
{
	new Float:origin[3];
	origin[0] = g_fDeerOrigin[slot][0];
	origin[1] = g_fDeerOrigin[slot][1];
	origin[2] = g_fDeerOrigin[slot][2];
	new serial = g_iDeerSerial[slot];

	// The reindeer goes away first: a second shot in the same frame must not
	// pay twice, and the ledger key below is the instance, not the player.
	KillDeer(slot);
	g_fDeerNext[slot] = get_gametime() + g_fRespawn;

	SpriteBurst(origin, 20);
	g_iKills++;

	new awarded = PayReward(id, serial);

	new name[MAX_NAME_LENGTH];
	get_user_name(id, name, charsmax(name));

	if (awarded > 0)
		client_print(0, print_chat, "[WF] %s shot a reindeer: +%d snowflakes.", name, awarded);
	else
		client_print(0, print_chat, "[WF] %s shot a reindeer.", name);

	set_hudmessage(255, 235, 190, -1.0, 0.55, 0, 0.0, 1.5, 0.1, 0.2, 2);
	if (awarded > 0)
		show_hudmessage(id, "Reindeer down! +%d snowflakes", awarded);
	else
		show_hudmessage(id, "Reindeer down!");

	log_amx("[WF-REINDEER] %s shot reindeer #%d (+%d)", name, serial, awarded);
}

/* Winterfest_core is optional. Present and in season -> the snowflakes go
 * through the one grant path, keyed on the reindeer instance, so an instance
 * pays exactly once no matter who shoots it or how many times. Absent -> the
 * hunt still pays nothing, and that is logged once per kill, not silently. */
stock PayReward(id, serial)
{
	if (g_iReward <= 0)
		return 0;
	if (!LibraryExists("winterfest_core", LibType_Library))
		return 0;
	if (!wf_season_open())
		return 0;

	new map[32], key[64];
	get_mapname(map, charsmax(map));
	formatex(key, charsmax(key), "deer#%s#%d", map, serial);

	new code = wf_grant(id, WF_REWARD_SNOWFLAKES, g_iReward, key);
	if (code != WF_GRANT_OK)
	{
		log_amx("[WF-REINDEER] grant refused for id %d, reindeer #%d (code %d)", id, serial, code);
		return 0;
	}
	return g_iReward;
}

// ============================================================
// Natives (called by winterfest_snow: wf_mode reindeer + the rotation)
// ============================================================
public _start(plugin, params)
{
	#pragma unused plugin
	return StartHunt(get_param(1), get_param(2) ? true : false) ? 1 : 0;
}

public _stop(plugin, params)
{
	#pragma unused plugin, params
	if (!g_bMode)
		return 0;
	EndHunt("stop requested");
	return 1;
}

public _active(plugin, params)
{
	#pragma unused plugin, params
	return g_bMode ? 1 : 0;
}

public _reload(plugin, params)
{
	#pragma unused plugin, params
	loadConfig();
	if (g_bMode)
		SpawnAllDeer();          // a reload moves the targets to the new spots
	return 1;
}

// ============================================================
// Admin: wf_reindeer <on|off|status>
// ============================================================
public cmdReindeer(id, level, cid)
{
	if (!cmd_access(id, level, cid, 1))
		return PLUGIN_HANDLED;

	new sub[24];
	read_argv(1, sub, charsmax(sub));

	if (!sub[0] || equali(sub, "status"))
	{
		PrintStatus(id);
		return PLUGIN_HANDLED;
	}
	if (equali(sub, "on"))
	{
		new force[8];
		read_argv(2, force, charsmax(force));
		StartHunt(id, equali(force, "force") ? true : false);
		return PLUGIN_HANDLED;
	}
	if (equali(sub, "off"))
	{
		if (!g_bMode)
		{
			if (id > 0)
				WfSay(id, "the reindeer hunt is not running.");
			else
				console_print(0, "[WF-REINDEER] not running.");
			return PLUGIN_HANDLED;
		}
		EndHunt("wf_reindeer off");
		return PLUGIN_HANDLED;
	}

	console_print(id, "[WF-REINDEER] usage: wf_reindeer <on|off|status>");
	return PLUGIN_HANDLED;
}

PrintStatus(id)
{
	new alive = 0;
	new Float:now = get_gametime();
	for (new slot = 0; slot < MAX_DEER; slot++)
	{
		if (g_bDeerAlive[slot])
			alive++;
	}

	new tracked = 0;
	if (LibraryExists("fn_mode", LibType_Library))
		tracked = fn_mode_count();

	console_print(id, "[WF-REINDEER] mode=%d forced=%d rounds_left=%d seconds=%d kills=%d starts=%d ends=%d arbiter_cvars=%d",
		g_bMode ? 1 : 0, g_bForced ? 1 : 0, g_iRoundsLeft, g_iModeSeconds, g_iKills, g_iStarts, g_iEnds, tracked);
	console_print(id, "[WF-REINDEER] alive=%d/%d spots=%d radius=%.0f range=%.0f respawn=%.0fs visual=%s",
		alive, g_iCount, g_iSpotCount, g_fRadius, g_fRange, g_fRespawn, g_szVisual);
	console_print(id, "[WF-REINDEER] reward=%d core=%d season=%d now=%.0f",
		g_iReward,
		LibraryExists("winterfest_core", LibType_Library) ? 1 : 0,
		(LibraryExists("winterfest_core", LibType_Library) && wf_season_open()) ? 1 : 0,
		now);

	new active[32];
	active[0] = EOS;
	if (LibraryExists("fn_mode", LibType_Library))
		fn_mode_active(active, charsmax(active));
	console_print(id, "[WF-REINDEER] arbiter=%s", active[0] ? active : "<free>");
	console_print(id, "[WF-REINDEER] snow_running=%d (from the arbiter, not from its natives)",
		(active[0] && equali(active, "snow")) ? 1 : 0);
}

// ============================================================
// Helpers
// ============================================================
stock CountHumans()
{
	new n = 0;
	for (new id = 1; id <= MaxClients; id++)
	{
		if (is_user_connected(id) && !is_user_bot(id) && !is_user_hltv(id))
			n++;
	}
	return n;
}

/* TE_SPRITE: one temp entity, no entity, no client asset. */
stock SpriteBurst(const Float:origin[3], scale)
{
	message_begin(MSG_BROADCAST, SVC_TEMPENTITY);
	write_byte(TE_SPRITE);
	write_coord(floatround(origin[0]));
	write_coord(floatround(origin[1]));
	write_coord(floatround(origin[2]));
	write_short(g_sprGlow);
	write_byte(clamp(scale, 1, 255));
	write_byte(200);
	message_end();
}
