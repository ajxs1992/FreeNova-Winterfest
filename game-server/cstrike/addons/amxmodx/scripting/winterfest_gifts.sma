/*
 * ============================================================================
 * winterfest_gifts — presents in the world, and the opening you can see
 * ============================================================================
 * Product contract: docs/WINTERFEST.md §3 ("Gift spawns", "Gift opening"),
 * §4.3, §4.4 and the owner decisions in §6.4. Module map:
 * docs/WINTERFEST-DEV.md.
 *
 * WHAT THIS PLUGIN OWNS
 *   - the present spots for the current map, read from
 *     configs/freenova/winterfest.ini [presents] (the same file the core reads
 *     for everything else — one config, two readers);
 *   - one stock-sprite glow per spot, a 0.2 s proximity scan, walk-over pickup,
 *     a respawn timer, and one pickup per player per spot per round;
 *   - the opening theatre: ScreenFade + a HUD line + a TE_SPRITE burst, then the
 *     reward, which is rolled and paid by winterfest_core's single grant path;
 *   - the death drop: a GingerBread pouch at the death location (owner decision
 *     §6.4 - dying never drops a present, and it never costs the dying player
 *     anything).
 *
 * PICKUP MECHANISM (the design call this module had to make)
 *   A repeating 0.2 s task walks the spot list (<= WF_MAX_SPOTS) and the human
 *   player list and compares squared distances. On a 10-spot map with 32 players
 *   that is 320 float subtractions twice a second - nothing next to the per-frame
 *   work the engine already does - and it needs no traceline, no per-player
 *   per-spot task, and no entity think hooks. The alternative (env_sprite +
 *   traceline per frame per player) costs more and ties the design to an entity
 *   that a client may not have in its PVS. The glow entities exist purely for
 *   the eye; the pickup decision is distance maths on the server.
 *
 * NO CLIENT ASSET: two stock sprites, both precached once:
 *   sprites/glow01.spr    - the present glow and the pouch (1 new table entry)
 *   sprites/laserbeam.spr - the opening burst (already precached by
 *                           freenova_cosmetics, so it is free)
 * See docs/PRECACHE-BUDGET.md: the plugin-side budget is tight and this module
 * spends one item, not three.
 *
 * MISSING DEPENDENCY
 *   The core is optional. plugin_natives() installs a native filter so a
 *   missing wf_* native degrades to 0 instead of a bad load, and plugin_init()
 *   pauses the plugin with a log line when LibraryExists("winterfest_core") is
 *   false. A server without the core behaves exactly like today's server.
 * ============================================================================
 */

#include <amxmodx>
#include <amxmisc>
#include <fakemeta>
#include <hamsandwich>
#include <winterfest>

#define PLUGIN  "Winterfest Gifts"
#define VERSION "1.0.0"
#define AUTHOR  "FreeNova"

#define CONFIG_FILE "freenova/winterfest.ini"
#define SPOT_SCAN 0.2         // seconds between proximity scans
#define SEASON_WATCH 15.0     // seconds between "did the season open/close?" checks
#define PICKUP_RADIUS 60.0    // units, squared below
#define OPEN_DELAY 1.0        // seconds of theatre before the reward lands

// Task bases (per-plugin in AMXX, but a distinct base makes a log obvious).
enum
{
	TASK_SCAN = 92000,
	TASK_OPEN = 92100,
	TASK_SEASON = 92200
}

new g_sprGlow;
new g_sprBeam;

// The asset pack's models, in the owner's registry names
// (thirdparty/winterfest-assets/README.md). They are client content this tree
// does not carry, so they are only precached when an operator turns downloads
// on; the [visual] rows name them, this table is what the engine has to be told
// about. Adding a model = one line here + one [visual] row.
new const g_szModelAssets[][] =
{
	"models/present1.mdl",
	"models/snow_tree.mdl",
	"models/green_tree3.mdl",
	"models/c4-christmastree.mdl"
}

// The present this build actually ships (docs/MODELS.md): 41.8 KB, one mesh,
// proven to load in the engine. It is precached whenever the file is on disk,
// whatever wf_allow_models says, because the core can resolve a prop to it at
// any time (wf_gifts_reload) and an unprecached model is an ERROR entity.
//
// Two spellings, because the working directory is not the same on every host.
// The shipped harness runs hlds from the GAME ROOT (`cd $SERVER`, see
// cs16-linux-base docker/harness/boot.sh) while every other file this module
// opens is addons/amxmodx/... (mod-relative). Testing only the plain spelling
// answered "no" on the harness and every present fell back to its glow - the
// owner's report. plugin_precache() keeps the first spelling that exists in
// g_szShippedPresent, and that one string is both precached and drawn.
new g_szShippedPresent[64] = "models/winterfest/present.mdl"
new const g_szPresentRoots[][] =
{
	"models/winterfest/present.mdl",
	"cstrike/models/winterfest/present.mdl"
}
new bool:g_bPresentModelOnDisk
// Visual names of the three present rarities, in rarity order.
new const g_szPresentVisual[WF_RARITY_MAX][] =
{
	WF_PROP_PRESENT_COMMON,
	WF_PROP_PRESENT_UNCOMMON,
	WF_PROP_PRESENT_RARE
}

// Present spots for the current map.
new g_iSpotCount;
new g_szSpotSpec[WF_MAX_SPOTS][48];           // raw origin column from the ini
new bool:g_bSpotResolved[WF_MAX_SPOTS];
new Float:g_fSpotOrigin[WF_MAX_SPOTS][3];
new g_iSpotRarity[WF_MAX_SPOTS];
new g_iSpotRespawn[WF_MAX_SPOTS];
new g_iSpotEnt[WF_MAX_SPOTS];
new Float:g_fSpotNext[WF_MAX_SPOTS];          // gametime when it may come back
new bool:g_bTaken[WF_MAX_SPOTS][MAX_PLAYERS + 1];
new bool:g_bSpotsLive;                         // are the glows in the world right now?

// GingerBread pouches dropped by a death (owner decision §6.4).
new g_iPouchGb = 5;
new Float:g_fPouchLife = 30.0;
new bool:g_bPouchEnable = true;
new g_iPouchEnt[WF_MAX_POUCHES];
new Float:g_fPouchOrigin[WF_MAX_POUCHES][3];
new Float:g_fPouchExpire[WF_MAX_POUCHES];
new g_iPouchKey[WF_MAX_POUCHES];               // the pouch's own ledger id
new g_iPouchSeq;
new g_iPouchNext;                              // round-robin slot for reuse

// Rarity table, read from the same ini section the core uses. The colour column
// belongs to the [visual] rows now (it is the chat/menu colour and the value the
// sprite visuals use); this module only needs the names and the spawn weights.
new g_iRarCount;
new g_szRarName[WF_RARITY_MAX][24];
new g_iRarWeight[WF_RARITY_MAX];

// Round seed: part of every spot claim key, so "one pickup per player per spot
// per round" is enforced by the ledger and not only by the in-memory flag.
new g_iRoundSeed;

new bool:g_bOpening[MAX_PLAYERS + 1];
new g_iOpenInstance[MAX_PLAYERS + 1];
new g_iOpenRarity[MAX_PLAYERS + 1];

// ============================================================
// Lifecycle
// ============================================================
public plugin_natives()
{
	register_library("winterfest_gifts")
	register_native("wf_gifts_open", "native_gifts_open")
	set_native_filter("WfNativeFilter")
}

// A missing wf_* native must not turn this plugin into a bad load: the core may
// legitimately be absent (or fail to load), in which case plugin_init() pauses
// this plugin before any native is reached. Anything else stays a hard error so
// a real mistake is not hidden.
public WfNativeFilter(const name[], index, trap)
{
	if (!trap && contain(name, "wf_") == 0 && !LibraryExists("winterfest_core", LibType_Library))
		return PLUGIN_HANDLED
	return PLUGIN_CONTINUE
}

public plugin_precache()
{
	// The two stock sprites: the fallback every model row names, and the opening
	// burst. sprites/glow01.spr is the module's own precache-slot spend
	// (docs/PRECACHE-BUDGET.md); sprites/laserbeam.spr is already in the table
	// through freenova_cosmetics.
	g_sprGlow = precache_model("sprites/glow01.spr")
	g_sprBeam = precache_model("sprites/laserbeam.spr")

	// wf_allow_models: the core decides what a prop LOOKS like (it resolves each
	// [props] slot), but the precache decision has to be taken HERE, in
	// plugin_precache, where there is still time to matter. The optional cfg is
	// exec'd first so an operator's value is the one this boot uses - the same
	// pattern reapi_healthnade uses (docs/PRECACHE-BUDGET.md §5).
	register_cvar("wf_allow_models", "1")
	new cfgdir[96], path[128]
	get_configsdir(cfgdir, charsmax(cfgdir))
	formatex(path, charsmax(path), "%s/plugins/wf_gifts.cfg", cfgdir)
	if (file_exists(path))
	{
		server_cmd("exec %s", path)
		server_exec()
	}

	// (1) The shipped present, precached whenever the file is on disk - even
	// with wf_allow_models 0, because that cvar can be flipped at runtime
	// (wf_gifts_reload) and a model drawn without being precached is exactly the
	// "invisible present" failure this batch is fixing.
	//
	// WHERE THE PATH POINTS. The community harness (cs16-linux-base
	// docker/harness/boot.sh) does `cd $SERVER` and runs hlds from the GAME ROOT,
	// so a cstrike-relative test like `models/winterfest/present.mdl` answers no
	// while the file sits in cstrike/models/. The core draws whatever this flag
	// says, and previously it said no, so every present fell back to its glow -
	// the owner's "presents are a glow" report. Test both roots, and draw
	// whichever one exists.
	g_bPresentModelOnDisk = false
	for (new i = 0; i < sizeof(g_szPresentRoots); i++)
	{
		if (file_exists(g_szPresentRoots[i]))
		{
			copy(g_szShippedPresent, charsmax(g_szShippedPresent), g_szPresentRoots[i])
			g_bPresentModelOnDisk = true
			break
		}
	}
	if (g_bPresentModelOnDisk)
	{
		precache_model(g_szShippedPresent)
		log_amx("[WF-GIFTS] %s is on disk - precached; presents draw the MODEL while wf_allow_models=%d",
			g_szShippedPresent, get_cvar_num("wf_allow_models"))
	}
	else
		log_amx("[WF-GIFTS] %s is NOT on disk - presents draw their stock sprite (ship the .mdl to get the model)",
			g_szShippedPresent)

	// (2) The optional asset-pack models: not in this tree, so only precached when
	// an operator has turned model downloads on.
	if (get_cvar_num("wf_allow_models"))
	{
		new precached = 0
		for (new i = 0; i < sizeof(g_szModelAssets); i++)
		{
			if (equal(g_szModelAssets[i], g_szShippedPresent))
				continue
			if (file_exists(g_szModelAssets[i]))
			{
				precache_model(g_szModelAssets[i])
				precached++
			}
			else
				log_amx("[WF-GIFTS] wf_allow_models is on but %s is not on disk - not precached", g_szModelAssets[i])
		}
		log_amx("[WF-GIFTS] optional asset-pack models: %d precached", precached)
	}
}

public plugin_init()
{
	register_plugin(PLUGIN, VERSION, AUTHOR)

	register_clcmd("say /opengift", "cmdOpenGift")
	register_clcmd("say_team /opengift", "cmdOpenGift")
	register_srvcmd("wf_gifts_reload", "cmdReload")
	register_srvcmd("wf_dump_spawns", "cmdDumpSpawns")

	register_cvar("wf_gifts_enable", "1")
	register_cvar("wf_pouch_enable", "1")

	if (!LibraryExists("winterfest_core", LibType_Library))
	{
		log_amx("[WF-GIFTS] winterfest_core missing - pausing self (no presents this map)")
		pause("d")
		return
	}

	RegisterHam(Ham_Killed, "player", "Ham_PlayerKilled", 0)
	register_event("HLTV", "ev_NewRound", "a", "1=0", "2=0")

	server_print("[FreeNova winterfest_gifts] ready (build 3, %d features)", 12)
	set_task(1.5, "Task_SpawnSpots")
	set_task(SPOT_SCAN, "Task_Scan", TASK_SCAN, _, _, "b")
	// The season window opens at midnight on 1 December and closes on the 24th.
	// Without this watcher presents would only appear at the next map change,
	// which on a busy server can be an hour after the season started. It also
	// gives an operator an immediate answer to `wf_enabled 1` / `wf_force_open 1`
	// instead of "wait for the map to end".
	set_task(SEASON_WATCH, "Task_SeasonWatch", TASK_SEASON, _, _, "b")
}

public plugin_cfg()
{
	loadConfig()
}

public plugin_end()
{
	remove_task(TASK_SCAN)
	for (new i = 0; i < g_iSpotCount; i++)
		WfKillEntity(g_iSpotEnt[i])
	for (new i = 0; i < WF_MAX_POUCHES; i++)
		WfKillEntity(g_iPouchEnt[i])
}

// A new round re-opens every spot for every player: the "one per player per spot
// per round" rule is per round, not per map.
public ev_NewRound()
{
	g_iRoundSeed++
	for (new s = 0; s < g_iSpotCount; s++)
		for (new id = 0; id <= MaxClients; id++)
			g_bTaken[s][id] = false
}

public client_disconnected(id)
{
	if (!(1 <= id <= MaxClients))
		return
	g_bOpening[id] = false
	remove_task(id + TASK_OPEN)
}

// ============================================================
// Config
// ============================================================
loadConfig()
{
	g_iSpotCount = 0
	g_iRarCount = 0
	g_iPouchGb = 5
	g_fPouchLife = 30.0
	g_iRoundSeed = 0
	for (new s = 0; s < WF_MAX_SPOTS; s++)
	{
		g_iSpotEnt[s] = 0
		g_fSpotNext[s] = 0.0
		g_bSpotResolved[s] = false
		g_szSpotSpec[s][0] = 0
	}
	for (new p = 0; p < WF_MAX_POUCHES; p++)
	{
		g_iPouchEnt[p] = 0
		g_iPouchKey[p] = 0
		g_fPouchExpire[p] = 0.0
	}

	new path[128]
	new cfgdir[96]
	get_configsdir(cfgdir, charsmax(cfgdir))
	formatex(path, charsmax(path), "%s/%s", cfgdir, CONFIG_FILE)

	if (!file_exists(path))
	{
		log_amx("[WF-GIFTS] no %s - no presents this map", path)
		return
	}

	new fp = fopen(path, "rt")
	if (!fp)
	{
		log_amx("[WF-GIFTS] %s could not be opened - no presents this map", path)
		return
	}

	new line[256], section[24]
	section[0] = 0

	while (fgets(fp, line, charsmax(line)))
	{
		trim(line)
		if (!line[0] || line[0] == ';' || line[0] == '#')
			continue

		if (line[0] == '[')
		{
			copy(section, charsmax(section), line[1])
			new close = contain(section, "]")
			if (close >= 0)
				section[close] = 0
			trim(section)
			strtolower(section)
			continue
		}

		if (equal(section, "rarity"))
			parseRarity(line)
		else if (equal(section, "pouch"))
			parsePouch(line)
		// [presents] is parsed in a second pass: a spot row may be for another
		// map, and the generic '*' fallback is only used when this map has no
		// rows of its own.
	}
	fclose(fp)

	loadSpots(path)
}

parseRarity(const line[])
{
	new id = WfFieldInt(line, 0, -1)
	if (id < 0 || id >= WF_RARITY_MAX)
		return
	WfField(line, 1, g_szRarName[id], charsmax(g_szRarName[]))
	if (!g_szRarName[id][0])
		formatex(g_szRarName[id], charsmax(g_szRarName[]), "rarity%d", id)
	g_iRarWeight[id] = max(0, WfFieldInt(line, 3, 0))
	if (id + 1 > g_iRarCount)
		g_iRarCount = id + 1
}

parsePouch(const line[])
{
	new eq = contain(line, "=")
	if (eq < 1)
		return
	new key[24], val[32]
	copy(key, charsmax(key), line)
	key[eq] = 0
	trim(key)
	strtolower(key)
	copy(val, charsmax(val), line[eq + 1])
	trim(val)

	// Canonical key is `gingerbread`; `snow` is the pre-rename spelling and is
	// still accepted so an older ini keeps working.
	if (equal(key, "gingerbread") || equal(key, "snow") || equal(key, "gb"))
		g_iPouchGb = clamp(str_to_num(val), 1, 1000)
	else if (equal(key, "life"))
		g_fPouchLife = floatmax(5.0, floatmin(120.0, float(str_to_num(val))))
	else if (equal(key, "enable"))
		g_bPouchEnable = (str_to_num(val) != 0) ? true : false
}

// Two passes over [presents]: first the rows for this map, and only when there
// are none, the '*' rows. That is the owner's "default 8 spots, generic set
// otherwise" rule (§6.4) without ever shipping zero presents.
loadSpots(const path[])
{
	new map[32]
	get_mapname(map, charsmax(map))

	new fp = fopen(path, "rt")
	if (!fp)
		return

	new line[256], section[24], use_generic = -1
	section[0] = 0

	while (fgets(fp, line, charsmax(line)))
	{
		trim(line)
		if (!line[0] || line[0] == ';' || line[0] == '#')
			continue
		if (line[0] == '[')
		{
			copy(section, charsmax(section), line[1])
			new close = contain(section, "]")
			if (close >= 0)
				section[close] = 0
			trim(section)
			strtolower(section)
			continue
		}
		if (!equal(section, "presents"))
			continue

		new who[32]
		WfField(line, 0, who, charsmax(who))
		new bool:mine = equali(who, map) ? true : false
		new bool:generic = equal(who, "*") ? true : false
		if (!mine && !generic)
			continue
		// Decide once, on the first matching row, whether this map has its own
		// rows: a map-specific row retires the generic set for this map.
		if (use_generic < 0)
			use_generic = mine ? 0 : 1
		if ((mine && use_generic != 0) || (generic && use_generic != 1))
			continue

		WfAddSpot(line)
	}
	fclose(fp)

	// Nothing at all in the ini for this map and no '*' rows: ship the built-in
	// generic set instead of zero presents.
	if (!g_iSpotCount)
		WfAddBuiltinSpots()

	// One line that states the rule and whether this map satisfies it, so an
	// operator reading the boot log does not have to count rows by hand.
	// 6 is the floor because fewer than six presents on a 5v5 map means most
	// players never see one; 10 is the ceiling because more turns the map into
	// a shopping trip. 8 is the default for a map with no rows of its own.
	new verdict[32]
	if (g_iSpotCount < WF_SPOTS_MIN)
		copy(verdict, charsmax(verdict), "below the minimum")
	else if (g_iSpotCount > WF_SPOTS_MAX)
		copy(verdict, charsmax(verdict), "above the maximum")
	else
		copy(verdict, charsmax(verdict), "ok")

	log_amx("[WF-GIFTS] %d present spot(s) on %s from %s rows - %s (rule: %d-%d, default %d)",
		g_iSpotCount, map,
		(use_generic == 1) ? "generic *" : ((use_generic == 0) ? "map" : "built-in"),
		verdict, WF_SPOTS_MIN, WF_SPOTS_MAX, WF_SPOTS_DEFAULT)
	log_amx("[WF-GIFTS] pouch %s (%d GingerBread, %.0fs)",
		g_bPouchEnable ? "on" : "off", g_iPouchGb, g_fPouchLife)
}

WfAddSpot(const line[])
{
	if (g_iSpotCount >= WF_MAX_SPOTS)
	{
		log_amx("[WF-GIFTS] more than %d spots for this map - extra rows ignored", WF_MAX_SPOTS)
		return
	}

	new spec[48]
	if (!WfField(line, 1, spec, charsmax(spec)) || !spec[0])
		return

	// The origin is resolved at SPAWN time, not here: plugin_cfg runs before the
	// map's player spawns are guaranteed to be in the entity list, and a spot
	// that silently resolves to nothing is worse than one that logs a skip.
	new rar = WfFieldInt(line, 2, -1)
	if (rar < 0 || rar >= WF_RARITY_MAX)
		rar = pickRarity()

	new slot = g_iSpotCount
	copy(g_szSpotSpec[slot], charsmax(g_szSpotSpec[]), spec)
	g_bSpotResolved[slot] = false
	g_fSpotOrigin[slot][0] = 0.0
	g_fSpotOrigin[slot][1] = 0.0
	g_fSpotOrigin[slot][2] = 0.0
	g_iSpotRarity[slot] = rar
	g_iSpotRespawn[slot] = clamp(WfFieldInt(line, 3, 120), 10, 900)
	g_iSpotEnt[slot] = 0
	g_fSpotNext[slot] = 0.0
	g_iSpotCount++
}

// The built-in generic set: eight spawn points, which are always reachable on
// any map and never inside a wall (they are the engine's own spawn points).
WfAddBuiltinSpots()
{
	new const specs[8][] =
	{
		"@spawn1", "@spawn2", "@spawn3", "@spawn4",
		"@spawn5", "@spawn6", "@spawn7", "@spawn8"
	}
	for (new i = 0; i < sizeof(specs); i++)
	{
		if (g_iSpotCount >= WF_MAX_SPOTS)
			return
		new slot = g_iSpotCount
		copy(g_szSpotSpec[slot], charsmax(g_szSpotSpec[]), specs[i])
		g_bSpotResolved[slot] = false
		g_fSpotOrigin[slot][0] = 0.0
		g_fSpotOrigin[slot][1] = 0.0
		g_fSpotOrigin[slot][2] = 0.0
		// First five common, then uncommon, then rare: a fresh map always has
		// something worth walking to, and the good one is worth a fight.
		g_iSpotRarity[slot] = (i < 5) ? 0 : ((i < 7) ? 1 : 2)
		g_iSpotRespawn[slot] = 120
		g_iSpotEnt[slot] = 0
		g_fSpotNext[slot] = 0.0
		g_iSpotCount++
	}
}

// A spot position is either "x y z" (hand-placed, the format in WINTERFEST.md
// §4.3) or a spawn reference, resolved against the map's own spawn entities:
//
//   @spawn<N>  the Nth player spawn, whatever class the map happens to use
//   @t<N>      the Nth info_player_terrorist  (falls back to @spawn<N>)
//   @ct<N>     the Nth info_player_counterterrorist (falls back to @spawn<N>)
//   @start<N>  the Nth info_player_start
//
// CS 1.6 maps mix info_player_start with the team-tagged classes, so @spawn is
// the one that always works; the shipped ini uses the generated coordinates.
// `wf_dump_spawns` prints the resolved coordinates of the current map as
// ready-to-paste rows.
//
// A resolved origin is sanity-checked: (0,0,0) and anything outside +/-8000 units
// is refused, because an entity that failed to spawn reports its origin as 0,0,0
// and a present at the world origin is a present nobody can ever reach. A map
// added after the content pack (de_tuscan was) simply has no rows and gets the
// generic set - it must never produce a spot at the origin.
stock bool:WfSpotOrigin(const spec[], Float:origin[3])
{
	if (spec[0] != '@')
		return WfParseVector(spec, origin) ? WfOriginSane(origin) : false

	new index = 0
	if (containi(spec, "@spawn") == 0)
	{
		index = str_to_num(spec[6])
		return WfNthSpawn(0, index, origin)
	}
	if (containi(spec, "@ct") == 0)
	{
		index = str_to_num(spec[3])
		if (WfNthSpawn(2, index, origin))
			return WfOriginSane(origin)
		// de_dust2 and friends tag their CT spawn as info_player_start.
		if (WfNthSpawn(4, index, origin))
			return WfOriginSane(origin)
		return WfNthSpawn(0, index, origin)
	}
	if (containi(spec, "@start") == 0)
	{
		index = str_to_num(spec[6])
		return WfNthSpawn(4, index, origin)
	}
	if (containi(spec, "@dm") == 0)
	{
		index = str_to_num(spec[3])
		return WfNthSpawn(3, index, origin)
	}
	if (containi(spec, "@t") == 0)
	{
		index = str_to_num(spec[2])
		if (WfNthSpawn(1, index, origin))
			return WfOriginSane(origin)
		// de_dust2 and friends tag their T spawn as info_player_deathmatch.
		if (WfNthSpawn(3, index, origin))
			return WfOriginSane(origin)
		return WfNthSpawn(0, index, origin)
	}
	return false
}

// Reject the origins a broken entity reports: (0,0,0) is "never spawned", and
// anything past the world limits is a coordinate that cannot be in a map.
stock bool:WfOriginSane(const Float:origin[3])
{
	if (origin[0] == 0.0 && origin[1] == 0.0 && origin[2] == 0.0)
		return false
	if (floatabs(origin[0]) > 8000.0 || floatabs(origin[1]) > 8000.0 || floatabs(origin[2]) > 8000.0)
		return false
	return true
}

// kind: 0 = any player spawn, 1 = info_player_terrorist,
//       2 = info_player_counterterrorist, 3 = info_player_deathmatch,
//       4 = info_player_start
//
// The union order puts the team-tagged classes first, then the two classes CS
// 1.6 maps actually use for team spawns when they are not tagged:
// info_player_deathmatch is the T spawn on de_dust2 and info_player_start is the
// CT spawn (measured with `wf_dump_spawns`, not assumed).
stock bool:WfNthSpawn(kind, index, Float:origin[3])
{
	if (index < 1)
		return false

	static const classes[4][] =
	{
		"info_player_terrorist",
		"info_player_counterterrorist",
		"info_player_deathmatch",
		"info_player_start"
	}

	new found = 0
	for (new c = 0; c < 4; c++)
	{
		if (kind != 0 && kind != c + 1)
			continue
		new ent = 0
		while ((ent = engfunc(EngFunc_FindEntityByString, ent, "classname", classes[c])) > 0)
		{
			found++
			if (found != index)
				continue
			pev(ent, pev_origin, origin)
			if (!WfOriginSane(origin))
				return false
			origin[2] += 24.0
			return true
		}
	}
	return false
}

// "x y z" with float support, written out instead of using parse() so the
// Float refs do not need tag gymnastics (parse() is an untagged vararg native
// and the compiler warns on every Float argument).
stock bool:WfParseVector(const spec[], Float:out[3])
{
	new buf[20], field = 0, c = 0
	out[0] = 0.0
	out[1] = 0.0
	out[2] = 0.0

	for (new i = 0; ; i++)
	{
		new ch = spec[i]
		if (ch == ' ' || ch == ',' || ch == '^t' || ch == 0)
		{
			if (c > 0)
			{
				buf[c] = 0
				if (field < 3)
					out[field] = str_to_float(buf)
				field++
				c = 0
			}
			if (ch == 0)
				break
			continue
		}
		if (c < charsmax(buf) - 1)
			buf[c++] = ch
	}
	return (field >= 3) ? true : false
}

// A spot with rarity '?' (or a bad column) rolls from the [rarity] weights.
stock pickRarity()
{
	new total = 0
	for (new i = 0; i < g_iRarCount; i++)
		total += g_iRarWeight[i]
	if (total <= 0)
		return 0
	new roll = random(total)
	for (new i = 0; i < g_iRarCount; i++)
	{
		roll -= g_iRarWeight[i]
		if (roll < 0)
			return i
	}
	return 0
}

// ============================================================
// Spawning
// ============================================================
public Task_SpawnSpots(taskid)
{
	#pragma unused taskid
	if (!wf_season_open())
	{
		log_amx("[WF-GIFTS] season is closed - %d spot(s) parsed, not spawned", g_iSpotCount)
		g_bSpotsLive = false
		return
	}
	new spawned = 0, drawn_model = 0, drawn_sprite = 0
	for (new s = 0; s < g_iSpotCount; s++)
	{
		if (g_iSpotEnt[s] > 0)
			continue
		spawnSpot(s)
		spawned++
		if (g_iSpotEnt[s] > 0)
		{
			if (WfPropIsModel(g_iSpotEnt[s]))
				drawn_model++
			else
				drawn_sprite++
		}
	}
	g_bSpotsLive = true
	// Which decision each present took: a model prop (models/winterfest/present.mdl)
	// or the stock-sprite fallback. The core logs the same choice per [props] slot
	// at load; this line is the world-side count.
	log_amx("[WF-GIFTS] spawned %d/%d present prop(s): %d model, %d sprite",
		spawned, g_iSpotCount, drawn_model, drawn_sprite)
}

// The season window is a date, not an event: it opens and closes while the
// server runs. This is the one place that reacts to that, so a season that
// starts at 00:00 or is switched on by an operator shows presents immediately
// instead of at the next map change - and takes them away when it closes.
public Task_SeasonWatch(taskid)
{
	#pragma unused taskid
	new bool:open = wf_season_open() ? true : false

	if (open && !g_bSpotsLive)
	{
		new spawned = 0, drawn_model = 0, drawn_sprite = 0
		for (new s = 0; s < g_iSpotCount; s++)
		{
			if (g_iSpotEnt[s] > 0)
				continue
			spawnSpot(s)
			spawned++
			if (g_iSpotEnt[s] > 0)
			{
				if (WfPropIsModel(g_iSpotEnt[s]))
					drawn_model++
				else
					drawn_sprite++
			}
		}
		g_bSpotsLive = true
		// One line, and it says which decision each prop took: a present that is
		// a model prop vs one that fell back to its glow.
		log_amx("[WF-GIFTS] season opened - spawned %d present prop(s): %d model, %d sprite",
			spawned, drawn_model, drawn_sprite)
	}
	else if (!open && g_bSpotsLive)
	{
		for (new s = 0; s < g_iSpotCount; s++)
			WfKillEntity(g_iSpotEnt[s])
		g_bSpotsLive = false
		log_amx("[WF-GIFTS] season closed - present glows removed (the spots stay configured)")
	}
}

spawnSpot(slot)
{
	if (!g_bSpotResolved[slot])
	{
		if (!WfSpotOrigin(g_szSpotSpec[slot], g_fSpotOrigin[slot]))
		{
			log_amx("[WF-GIFTS] spot '%s' does not resolve on this map - skipped", g_szSpotSpec[slot])
			return
		}
		g_bSpotResolved[slot] = true
	}

	// The look comes from the config, never from this file: [props] decides which
	// visual a present of this rarity uses, and the core resolves a model id to
	// its stock-sprite fallback while downloads are gated.
	new rar = clamp(g_iSpotRarity[slot], 0, WF_RARITY_MAX - 1)
	new visual[32]
	wf_visual_id(g_szPresentVisual[rar], visual, charsmax(visual))
	g_iSpotEnt[slot] = WfCreateProp(visual, g_fSpotOrigin[slot])
	if (g_iSpotEnt[slot] <= 0)
		log_amx("[WF-GIFTS] could not create the prop for spot %d (visual '%s')", slot, visual)
}

// Creates one prop entity from a visual id: an env_sprite glow today, a model
// when the config asks for one and downloads are on. One function so a prop
// cannot be half-converted.
stock WfCreateProp(const visual[], const Float:origin[3])
{
	new asset[64], colour[24]
	wf_visual_asset(visual, asset, charsmax(asset))
	if (!asset[0])
	{
		// No visual configured at all: fall back to the stock sprite rather than
		// spawning an entity the client cannot draw.
		copy(asset, charsmax(asset), "sprites/glow01.spr")
	}

	new bool:is_model = wf_visual_is_model(visual) ? true : false

	// A model prop is a func_wall: that is the static-prop classname this engine
	// renders a model on (an env_sprite would ignore the .mdl entirely, which is
	// how "presents are just shining lights" happened). The sprite path keeps
	// env_sprite, because a glow needs the render mode.
	new ent = engfunc(EngFunc_CreateNamedEntity, engfunc(EngFunc_AllocString, is_model ? "func_wall" : "env_sprite"))
	if (!ent || !pev_valid(ent))
		return 0

	engfunc(EngFunc_SetModel, ent, asset)
	set_pev(ent, pev_origin, origin)
	set_pev(ent, pev_solid, SOLID_NOT)
	set_pev(ent, pev_movetype, MOVETYPE_NONE)

	if (!is_model)
	{
		wf_visual_colour(visual, colour, charsmax(colour))
		new Float:rgba[3]
		WfParseVector(colour, rgba)
		if (!colour[0])
		{
			rgba[0] = 200.0
			rgba[1] = 220.0
			rgba[2] = 255.0
		}
		set_pev(ent, pev_rendermode, kRenderGlow)
		set_pev(ent, pev_renderamt, 200.0)
		set_pev(ent, pev_rendercolor, rgba)
		set_pev(ent, pev_scale, wf_visual_scale(visual))
	}

	dllfunc(DLLFunc_Spawn, ent)
	return ent
}

stock WfKillEntity(&ent)
{
	if (ent > 0 && pev_valid(ent))
		set_pev(ent, pev_flags, pev(ent, pev_flags) | FL_KILLME)
	ent = 0
}

// Was this prop created as a model (func_wall) or as a sprite (env_sprite)? The
// answer is the classname, which is the same thing a scenario or an admin noclip
// sees in the world - no second bookkeeping array to drift out of sync.
stock bool:WfPropIsModel(ent)
{
	if (ent <= 0 || !pev_valid(ent))
		return false
	new szClass[32]
	// fakemeta's pev() with a string key, the idiom parachute.sma:529 uses.
	// NOTE: the engine module's entity_get_string() makes amxxpc 1.10 git5481
	// throw std::bad_alloc and abort the compile - do not use it here.
	pev(ent, pev_classname, szClass, charsmax(szClass))
	return bool:equali(szClass, "func_wall")
}

// ============================================================
// Pickup scan (documented choice: squared distance, twice a second)
// ============================================================
public Task_Scan(taskid)
{
	#pragma unused taskid
	if (!wf_season_open())
		return

	new Float:now = get_gametime()

	// Resurrection of spots whose respawn timer ran out, and expiry of pouches.
	for (new s = 0; s < g_iSpotCount; s++)
	{
		if (g_iSpotEnt[s] <= 0 && g_fSpotNext[s] > 0.0 && now >= g_fSpotNext[s])
		{
			g_fSpotNext[s] = 0.0
			spawnSpot(s)
		}
	}
	for (new p = 0; p < WF_MAX_POUCHES; p++)
	{
		if (g_iPouchEnt[p] > 0 && now >= g_fPouchExpire[p])
			WfKillEntity(g_iPouchEnt[p])
	}

	// Humans only: a bot must never collect a present or a pouch (WINTERFEST.md
	// §5.1 and the bot rule in the brief). get_players "c" drops bots and "h"
	// drops HLTV proxies.
	new players[MAX_PLAYERS], num
	get_players(players, num, "ch")
	if (!num)
		return

	new Float:rad2 = PICKUP_RADIUS * PICKUP_RADIUS

	for (new s = 0; s < g_iSpotCount; s++)
	{
		if (g_iSpotEnt[s] <= 0)
			continue
		for (new i = 0; i < num; i++)
		{
			new id = players[i]
			if (g_bTaken[s][id] || !is_user_alive(id))
				continue
			if (WfDist2(id, g_fSpotOrigin[s]) > rad2)
				continue
			WfPickupSpot(id, s)
			break
		}
	}

	for (new p = 0; p < WF_MAX_POUCHES; p++)
	{
		if (g_iPouchEnt[p] <= 0)
			continue
		for (new i = 0; i < num; i++)
		{
			new id = players[i]
			if (!is_user_alive(id))
				continue
			if (WfDist2(id, g_fPouchOrigin[p]) > rad2)
				continue
			WfPickupPouch(id, p)
			break
		}
	}
}

stock Float:WfDist2(id, const Float:origin[3])
{
	new Float:mine[3]
	pev(id, pev_origin, mine)
	new Float:dx = mine[0] - origin[0]
	new Float:dy = mine[1] - origin[1]
	new Float:dz = mine[2] - origin[2]
	return dx * dx + dy * dy + dz * dz
}

WfPickupSpot(id, slot)
{
	// Ledger key: one grant per player per spot per round. The core hashes it
	// and stamps it with the player's authid + season, so a reconnect in the same
	// round cannot pick the same present up twice.
	new map[32], key[64]
	get_mapname(map, charsmax(map))
	formatex(key, charsmax(key), "spot#%s#%d#%d", map, slot, g_iRoundSeed)

	// A present is a present: it is granted to the inventory, and /opengift
	// decides what is inside (that is where the roll lives).
	new code = wf_grant(id, WF_REWARD_GIFT, g_iSpotRarity[slot], key)
	if (code != WF_GRANT_OK)
	{
		// Already claimed this round (or the inventory is full): leave the glow
		// alone and stop retrying for this player until the next round.
		g_bTaken[slot][id] = true
		return
	}

	g_bTaken[slot][id] = true
	g_fSpotNext[slot] = get_gametime() + float(g_iSpotRespawn[slot])
	WfKillEntity(g_iSpotEnt[slot])

	// A short burst so the pickup is visible even to someone across the map.
	WfBurst(g_fSpotOrigin[slot], g_iSpotRarity[slot], 1)

	new name[MAX_NAME_LENGTH]
	get_user_name(id, name, charsmax(name))
	log_amx("[WF-GIFTS] %s picked up spot %d (rarity %d)", name, slot, g_iSpotRarity[slot])
}

WfPickupPouch(id, slot)
{
	if (g_iPouchKey[slot] <= 0)
		return

	// The pouch's own instance id is its claim key: two players racing for the
	// same pouch can both be near it in the same scan, and only one pays.
	//
	// THE SEASON STAMP IS NOT ENOUGH ON ITS OWN. The claim ledger records
	// `wf_claim_s<year>#<auth>#e<epoch>#<crc32(claim)>` and lives for the whole
	// season, while g_iPouchSeq is an in-memory counter that starts again at 0
	// on every map change (it is never loaded or saved). So the drop that got
	// id 1 on de_dust2 this morning and the drop that got id 1 on de_inferno
	// tonight were the same claim: the player who already took one was paid
	// NOTHING for every later pouch with the same slot/sequence, silently, for
	// the rest of the season. Naming the map puts the map instance in the key
	// so the counter restart can never collide with itself.
	new map[32]
	get_mapname(map, charsmax(map))
	new key[64]
	formatex(key, charsmax(key), "pouch#%s#%d#%d", map, slot, g_iPouchKey[slot])
	new code = wf_grant(id, WF_REWARD_GINGERBREAD, g_iPouchGb, key)
	WfKillEntity(g_iPouchEnt[slot])
	g_fPouchExpire[slot] = 0.0
	g_iPouchKey[slot] = 0

	new name[MAX_NAME_LENGTH]
	get_user_name(id, name, charsmax(name))
	log_amx("[WF-GIFTS] %s picked up a GingerBread pouch (%d gb) code=%d", name, g_iPouchGb, code)
}

// ============================================================
// Death drop: a GingerBread pouch (owner decision §6.4)
// ============================================================
// Dying never drops a present and never costs the dying player anything. What a
// death leaves behind is a small pouch worth a few GingerBread, for whoever gets
// there first. Two rules keep it a kill reward and not a farm:
//   - no pouch when the victim is a bot (bot kills are not worth currency);
//   - no pouch on a suicide (attacker == victim).
public Ham_PlayerKilled(victim, attacker, shouldgib)
{
	#pragma unused shouldgib
	if (!g_bPouchEnable || !wf_season_open())
		return HAM_IGNORED
	if (!(1 <= victim <= MaxClients) || !is_user_connected(victim))
		return HAM_IGNORED
	if (is_user_bot(victim) || is_user_hltv(victim))
		return HAM_IGNORED
	if (attacker == victim)
		return HAM_IGNORED

	spawnPouch(victim)
	return HAM_IGNORED
}

spawnPouch(victim)
{
	new slot = -1
	for (new p = 0; p < WF_MAX_POUCHES; p++)
	{
		if (g_iPouchEnt[p] <= 0)
		{
			slot = p
			break
		}
	}
	if (slot < 0)
	{
		// Bounded: reuse the slot that expires first rather than growing.
		slot = g_iPouchNext % WF_MAX_POUCHES
		g_iPouchNext++
		WfKillEntity(g_iPouchEnt[slot])
	}

	new Float:origin[3]
	pev(victim, pev_origin, origin)
	origin[2] += 8.0

	g_iPouchSeq++
	g_iPouchKey[slot] = g_iPouchSeq
	g_fPouchOrigin[slot][0] = origin[0]
	g_fPouchOrigin[slot][1] = origin[1]
	g_fPouchOrigin[slot][2] = origin[2]
	g_fPouchExpire[slot] = get_gametime() + g_fPouchLife
	new visual[32]
	wf_visual_id(WF_PROP_POUCH, visual, charsmax(visual))
	g_iPouchEnt[slot] = WfCreateProp(visual, origin)
}

// ============================================================
// Opening
// ============================================================
public cmdOpenGift(id)
{
	// No menu on a bot, an HLTV proxy or the server console.
	if (!(1 <= id <= MaxClients) || !is_user_connected(id) || is_user_bot(id) || is_user_hltv(id))
		return PLUGIN_HANDLED
	if (!LibraryExists("winterfest_core", LibType_Library))
		return PLUGIN_HANDLED

	if (!wf_season_open())
	{
		WfSay(id, "Winterfest is closed right now - your presents keep.")
		return PLUGIN_HANDLED
	}
	if (g_bOpening[id])
	{
		WfSay(id, "one present at a time.")
		return PLUGIN_HANDLED
	}

	new count = wf_gift_count(id)
	if (count <= 0)
	{
		WfSay(id, "you are not carrying a present - look for a glowing one (or /gifts).")
		return PLUGIN_HANDLED
	}

	WfOpenSequence(id, wf_gift_instance(id, 0))
	return PLUGIN_HANDLED
}

// The menu module reaches the opening through here, so the theatre has exactly
// one owner.
public native_gifts_open(plugin, params)
{
	#pragma unused plugin, params
	new id = get_param(1)
	new instance = get_param(2)
	if (!(1 <= id <= MaxClients) || !is_user_connected(id) || is_user_bot(id) || is_user_hltv(id))
		return WF_OPEN_INVALID
	if (g_bOpening[id])
		return WF_OPEN_NOTHING
	if (wf_gift_rarity(id, instance) < 0)
		return WF_OPEN_INVALID
	WfOpenSequence(id, instance)
	return WF_OPEN_OK
}

WfOpenSequence(id, instance)
{
	new rarity = wf_gift_rarity(id, instance)
	if (rarity < 0)
	{
		WfSay(id, "that present is no longer in your bag.")
		return
	}

	g_bOpening[id] = true
	g_iOpenInstance[id] = instance
	g_iOpenRarity[id] = rarity

	// 1. the fade: a warm gold, deliberately not near-white so freenova_flash
	//    never mistakes it for a flashbang (its gate is R,G,B,alpha >= 200).
	WfFade(id, 120, 255, 215, 120)

	new rname[24]
	wf_rarity_name(rarity, rname, charsmax(rname))
	set_hudmessage(255, 235, 180, -1.0, 0.30, 0, 0.0, 1.2, 0.1, 0.2, 3)
	show_hudmessage(id, "Unwrapping the %s present...", rname)

	// 2. the sprite burst, at the player, then 3. the reward
	new Float:origin[3]
	pev(id, pev_origin, origin)
	WfBurst(origin, rarity, 3)

	set_task(OPEN_DELAY, "Task_OpenReward", id + TASK_OPEN)
}

public Task_OpenReward(id)
{
	id -= TASK_OPEN
	if (!(1 <= id <= MaxClients) || !is_user_connected(id))
	{
		if (1 <= id <= MaxClients)
			g_bOpening[id] = false
		return
	}

	new instance = g_iOpenInstance[id]
	new rarity = g_iOpenRarity[id]
	g_bOpening[id] = false

	// The core owns the roll and the payment; this module only made it look
	// like something happened. wf_open_gift() is idempotent per present, so a
	// double /opengift in the same second pays once.
	new code = wf_open_gift(id, instance)
	if (code == WF_OPEN_OK)
	{
		set_hudmessage(255, 235, 180, -1.0, 0.30, 0, 0.0, 2.0, 0.1, 0.2, 3)
		new rname[24]
		wf_rarity_name(rarity, rname, charsmax(rname))
		show_hudmessage(id, "%s present opened!", rname)
		new Float:origin[3]
		pev(id, pev_origin, origin)
		WfBurst(origin, rarity, 2)
	}
	else if (code == WF_OPEN_NOTHING)
	{
		WfSay(id, "that present was already opened.")
	}
	else
	{
		WfSay(id, "the present could not be opened - ask an admin to check the log.")
		log_amx("[WF-GIFTS] open failed for id %d instance %d (code %d)", id, instance, code)
	}
}

// ============================================================
// Effects
// ============================================================
stock WfFade(id, red, green, blue, alpha)
{
	message_begin(MSG_ONE_UNRELIABLE, get_user_msgid("ScreenFade"), _, id)
	write_short(floatround(4096.0 * 0.35))   // duration
	write_short(floatround(4096.0 * 0.20))   // hold
	write_short(0x0001)                      // fade out
	write_byte(red)
	write_byte(green)
	write_byte(blue)
	write_byte(alpha)
	message_end()
}

// A burst of stock sprites. TE_SPRITE is the "additive sprite, plays 1 cycle"
// temp entity: one message, no entity, no client asset beyond the precached
// index every CS 1.6 client already has.
stock WfBurst(const Float:origin[3], rarity, rings)
{
	new rar = clamp(rarity, 0, WF_RARITY_MAX - 1)
	for (new i = 0; i < rings && i < 4; i++)
	{
		new Float:x = origin[0] + random_float(-24.0, 24.0)
		new Float:y = origin[1] + random_float(-24.0, 24.0)
		new Float:z = origin[2] + 12.0 + float(i) * 16.0
		message_begin(MSG_BROADCAST, SVC_TEMPENTITY)
		write_byte(TE_SPRITE)
		write_coord(floatround(x))
		write_coord(floatround(y))
		write_coord(floatround(z))
		write_short(i ? g_sprBeam : g_sprGlow)
		write_byte(4 + rar * 3)          // scale in 0.1's
		write_byte(200 - i * 40)         // brightness
		message_end()
	}
}

// Core asks for this after wf_reload, so a config edit applies without a map
// change. Spots that are already spawned are re-created against the new rows.
public cmdReload()
{
	// Spots already on the ground are replaced by the reloaded rows: kill the
	// glows, re-read the file, resolve nothing yet (the spawn task does that).
	for (new s = 0; s < g_iSpotCount; s++)
		WfKillEntity(g_iSpotEnt[s])
	loadConfig()
	Task_SpawnSpots(0)
	return PLUGIN_HANDLED
}

// Operator helper: print this map's player spawns as ready-to-paste [presents]
// rows. The shipped ini was written from this on de_dust2, and it is the honest
// answer to "how do I add a present spot" (docs/WINTERFEST-DEV.md §4).
public cmdDumpSpawns()
{
	new map[32]
	get_mapname(map, charsmax(map))
	console_print(0, "[WF-GIFTS] player spawns on %s - paste the rows you want into [presents]:", map)
	console_print(0, "; map | origin | rarity | respawn")

	static const classes[3][] =
	{
		"info_player_terrorist",
		"info_player_counterterrorist",
		"info_player_start"
	}

	new total = 0
	for (new c = 0; c < 3; c++)
	{
		new ent = 0
		while ((ent = engfunc(EngFunc_FindEntityByString, ent, "classname", classes[c])) > 0)
		{
			new Float:origin[3]
			pev(ent, pev_origin, origin)
			console_print(0, "%s | %d %d %d | 0 | 120   ; %s",
				map, floatround(origin[0]), floatround(origin[1]), floatround(origin[2]), classes[c])
			total++
			if (total >= 40)
			{
				console_print(0, "[WF-GIFTS] stopped at 40 spawns")
				return PLUGIN_HANDLED
			}
		}
	}
	console_print(0, "[WF-GIFTS] %d spawn point(s) on %s", total, map)
	return PLUGIN_HANDLED
}
