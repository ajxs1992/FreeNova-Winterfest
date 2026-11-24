/*
 * ============================================================================
 * winterfest_snow - snowball fight + frozen grenades (workstream 7, mode A)
 * ============================================================================
 * Product contract: docs/WINTERFEST.md §3 ("Santa's Revenge, Grinch Mode,
 * snowballs, reindeer hunt ... gameplay modules - each a mode; they plug into
 * the fn_mode arbiter being built now") and §1.3 (stock sprites, engine
 * messages, no client download). Workstream map:
 * docs/WINTERFEST-WORKSTREAMS.md row 7. Tuning, inputs, cvars, the ini format,
 * the arbiter contract and the restore proof: docs/WINTERFEST-MODES.md.
 *
 * WHAT THIS PLUGIN OWNS
 *   - the "snow" mode on the fn_mode arbiter: begin / set / end, one active
 *     mode server-wide. Every engine cvar is written through fn_mode_set(),
 *     which snapshots the pre-mode value, and fn_mode_end() puts the table back.
 *     This plugin never writes an engine cvar directly (include/fn_mode.inc).
 *   - the snowball: a hitscan in the view cone (traceline - no entity, no
 *     projectile physics, no per-frame cost), a white stock-sprite beam trail
 *     and impact puff, per-life ammo, a per-player cooldown, a slow effect and
 *     "frozen solid" instead of a kill.
 *   - frozen grenades: an hegrenade explosion freezes everyone inside a radius
 *     for a couple of seconds.
 *   - the workstream's mode plumbing: `wf_mode <snow|reindeer|off>`, the /wfsnow
 *     vote, the rotation from configs/freenova/winterfest/modes.ini, and the
 *     hand-off to winterfest_reindeer (an optional library, always guarded).
 *   - the per-player maxspeed table. That one is NOT fn_mode's job: maxspeed is
 *     a player field, not a cvar, so this plugin keeps its own pre-effect value
 *     per player and restores it (a cvar arbiter cannot restore an entity).
 *
 * INPUT (the design call this module had to make)
 *   "+use" is the drop key and "+attack2" is the scope / silencer key, so
 *   neither is free. The module does both halves of the honest answer:
 *     * `bind <key> +snowball` - a client command, so every player picks their
 *       own key. The server never issues a `bind`: rewriting a player's keys is
 *       rude and can break their whole config for one mode.
 *     * "+attack2" while the mode runs, for players who never bound anything.
 *       [snow] input picks: 0 = +attack2 (default), 1 = only +snowball,
 *       2 = both.
 *   The cost of the default is real and is documented: inside the mode mouse2
 *   stops scoping and stops toggling a silencer. `input = 1` is the escape
 *   hatch, and the mode announcement names the bind.
 *   Only a human, alive, inside an active mode can throw; a bot and an HLTV
 *   proxy are never a thrower and never a target's credit.
 *
 * NO CLIENT ASSET: two stock sprites, both of which the stack already
 * precaches (docs/PRECACHE-BUDGET.md §3 - a duplicate path costs no extra
 * item, the engine hands back the existing index):
 *   sprites/laserbeam.spr - the snowball trail
 *   sprites/glow01.spr    - the impact puff
 *
 * DEPENDENCIES (both optional, both guarded)
 *   fn_mode              REQUIRED to start a mode. Missing => every start is
 *                        refused with one line ("the mode arbiter is not
 *                        loaded"), never a half-applied mode. plugin_natives()
 *                        installs a native filter so a missing fn_mode is a
 *                        clean load + working plugin, not a bad load.
 *   winterfest_core      NOT needed for the snowball fight itself (the mode
 *                        pays no reward). The filter still tolerates its
 *                        absence for the wf_* stocks/ natives this file shares
 *                        with the rest of the module.
 *   winterfest_reindeer  optional: `wf_mode reindeer` and the rotation hand off
 *                        through its natives when it is loaded.
 *
 * DAMAGE MODEL (deliberately not the engine's)
 *   A snowball is subtracted from health by hand, not through Ham_TakeDamage:
 *   the point of the mode is that nobody dies and no stats move. The moment a
 *   hit would take the last HP, the victim is set to 1 HP and frozen solid
 *   instead, so the mode can never produce a death, a frag, an XP event or a
 *   BattlePass tick. `lethal = 1` in modes.ini switches to the engine path for
 *   an operator who wants real damage, and then everything downstream sees it.
 * ============================================================================
 */

#include <amxmodx>
#include <amxmisc>
#include <fakemeta>
#include <fun>
#include <hamsandwich>
#include <vector>
#include <fn_mode>
#include <winterfest>

#define PLUGIN  "Winterfest Snowball Fight"
#define VERSION "1.0.0"
#define AUTHOR  "FreeNova"

// fn_mode mode id. Short, stable: it appears in `fn_mode status` output and in
// the arbiter's refusal lines.
#define MODE_NAME   "snow"

#define MODES_INI   "freenova/winterfest/modes.ini"

// Task bases. A task id must never collide with another plugin's; AMXX scopes
// tasks per plugin, but a distinct base makes a stray task obvious in a log.
enum
{
	TASK_MODE_CLOCK = 93400,      // 1 s repeating: max_seconds + empty-server guard
	TASK_SPEED      = 93500       // one per player: id + TASK_SPEED
}

// Per-player state -----------------------------------------------------------
new g_iAmmo[MAX_PLAYERS + 1];
new Float:g_fNextThrow[MAX_PLAYERS + 1];
new bool:g_bFrozen[MAX_PLAYERS + 1];
new Float:g_fFrozenUntil[MAX_PLAYERS + 1];
new bool:g_bSlowed[MAX_PLAYERS + 1];
new Float:g_fSlowUntil[MAX_PLAYERS + 1];
new bool:g_bSpeedHeld[MAX_PLAYERS + 1];              // a pre-effect speed is stored
new Float:g_fSpeedBase[MAX_PLAYERS + 1];             // ... and this is it
new bool:g_bVoted[MAX_PLAYERS + 1];

// Mode state -----------------------------------------------------------------
new bool:g_bMode;
new bool:g_bForced;                                  // started with `force`: empty-server guard off
new g_iRoundsLeft;
new g_iModeSeconds;
new g_iRoundCounter;                                 // rounds seen this map
new g_iRotationIdx;
new g_iStarts;
new g_iEnds;

// Config: [modes] (the snow row), [snow], [grenade], [vote], [rotation] ------
new bool:g_bIniSnow = true;
new g_iRounds = 3;
new Float:g_fMaxSeconds = 900.0;

new g_iDamage = 12;
new g_iDamageSpread = 2;
new Float:g_fSlow = 0.55;
new Float:g_fSlowTime = 2.0;
new Float:g_fCooldown = 0.8;
new g_iAmmoMax = 8;
new Float:g_fRange = 1400.0;
new Float:g_fFreezeTime = 1.5;
new bool:g_bFreezeOnKill = true;
new bool:g_bLethal = false;
new bool:g_bFriendlyFire = false;
new g_iFreezetime = 0;                               // -1 = leave mp_freezetime alone
new g_iInput = 0;                                    // 0 = +attack2, 1 = +snowball, 2 = both

// The look, from modes.ini [snow] visual. Only "sprite" exists today: the
// flashbang-model snowball (models/{p,v,w}_flashbang.mdl, staged in
// thirdparty/winterfest-assets/) is client content and blocked until fastdl
// works - docs/WINTERFEST.md §1.1. The key is read, logged and refused rather
// than silently ignored, so the day the models ship this is one accepted value
// and no code change.
new g_szVisual[24] = "sprite";

new bool:g_bNadeFreeze = true;
new g_iNadeRadius = 250;
new Float:g_fNadeFreezeTime = 2.0;

new g_iVoteRatio = 60;
new g_iVoteMin = 2;

new bool:g_bRotIni = false;
new g_iRotEvery = 6;
new g_iRotMinHumans = 2;
new g_szRotation[96];

// Sprites (both already in the stack: no new precache entry) -----------------
new g_sprBeam;
new g_sprPuff;

// Cvars: the switches an operator flips live. Everything else is the ini ----
new g_pEnable;
new g_pVote;
new g_pRotation;
new g_pDebug;

// Natives provided by winterfest_reindeer (declared here on purpose: the
// shared include/winterfest.inc belongs to workstream 1, and workstream 7 must
// not edit it - see docs/WINTERFEST-MODES.md "Module contract").
// wf_reindeer_reload() is called by wf_modes_reload so one command re-reads the
// one file both modules share (this file owns that command - see cmdReload).
native wf_reindeer_start(initiator, bForce);
native wf_reindeer_stop();
native wf_reindeer_active();
native wf_reindeer_reload();

// ============================================================
// Lifecycle
// ============================================================
public plugin_natives()
{
	// Named so other winterfest modules (and later the /christmas menu) can ask
	// whether the gameplay layer is loaded.
	register_library("winterfest_snow");
	register_native("wf_snow_mode_active", "_snow_active");
	set_native_filter("WfNativeFilter");
}

/* Called by winterfest_reindeer's `wf_reindeer status`, so "is the other mode
 * running" is one line of output instead of a log dig. */
public _snow_active(plugin, params)
{
	#pragma unused plugin, params
	return g_bMode ? 1 : 0;
}

/* A missing optional library must never be a bad load. At load time (trap == 0)
 * an unresolved native of an absent provider is swallowed; a *call* to a native
 * that is missing at runtime (trap == 1) stays a loud run-time error, because
 * that would be our bug, not the operator's. Every call site guards with
 * LibraryExists() anyway. */
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
	if (contain(name, "wf_reindeer_") == 0)
	{
		if (!LibraryExists("winterfest_reindeer", LibType_Library))
			return PLUGIN_HANDLED;
		return PLUGIN_CONTINUE;
	}
	if (contain(name, "wf_") == 0 && !LibraryExists("winterfest_core", LibType_Library))
		return PLUGIN_HANDLED;

	return PLUGIN_CONTINUE;
}

public plugin_precache()
{
	g_sprBeam = precache_model("sprites/laserbeam.spr");
	g_sprPuff = precache_model("sprites/glow01.spr");
}

public plugin_init()
{
	register_plugin(PLUGIN, VERSION, AUTHOR);

	g_pEnable   = register_cvar("wf_snow_enable", "1");
	g_pVote     = register_cvar("wf_snow_vote", "1");
	g_pRotation = register_cvar("wf_rotation_enable", "-1");
	g_pDebug    = register_cvar("wf_modes_debug", "0");

	register_concmd("wf_mode", "cmdMode", ADMIN_CFG, "<snow|reindeer|off|status> [force] - start/stop a Winterfest mode");
	register_concmd("wf_modes_reload", "cmdReload", ADMIN_CFG, "- re-read configs/freenova/winterfest/modes.ini");

	register_clcmd("say /wfsnow", "cmdVote");
	register_clcmd("say_team /wfsnow", "cmdVote");

	// The throwable inputs. `+snowball` is the bindable one; `+attack2` is the
	// no-setup one (see the header).
	register_clcmd("+snowball", "cmdThrowBound");
	register_clcmd("-snowball", "cmdThrowRelease");
	register_clcmd("+attack2", "cmdThrowAttack2");
	register_clcmd("+attack", "cmdBlockAttack");

	RegisterHam(Ham_Spawn, "player", "Ham_Spawn_Post", 1);
	RegisterHam(Ham_Killed, "player", "Ham_Killed_Post", 1);
	RegisterHam(Ham_TakeDamage, "player", "Ham_TakeDamage_Pre", 0);

	register_event("HLTV", "ev_NewRound", "a", "1=0", "2=0");

	if (!LibraryExists("fn_mode", LibType_Library))
		log_amx("[WF-SNOW] fn_mode missing - every wf_mode start will be refused (the mode arbiter must load first)");
	if (!LibraryExists("winterfest_core", LibType_Library))
		log_amx("[WF-SNOW] winterfest_core missing - the snowball fight runs, it just pays nothing");

	server_print("[FreeNova winterfest_snow] ready (build 1)");
}

public plugin_cfg()
{
	// A reload of this plugin must not resume a mode the previous instance
	// began: fn_mode's own plugin_end restored the cvars, and there is nothing
	// to resume. Reset everything the per-map state depends on.
	g_bMode = false;
	g_iRoundsLeft = 0;
	g_iModeSeconds = 0;
	g_iRoundCounter = 0;
	g_iRotationIdx = 0;
	remove_task(TASK_MODE_CLOCK);

	loadConfig();
}

public plugin_end()
{
	remove_task(TASK_MODE_CLOCK);
	if (g_bMode)
		EndMode("plugin_end");

	for (new id = 1; id <= MaxClients; id++)
		ClearEffects(id);
}

// ============================================================
// Config: configs/freenova/winterfest/modes.ini
// ============================================================
loadConfig()
{
	// Defaults first: a missing or partial file changes nothing.
	g_bIniSnow = true;
	g_iRounds = 3;
	g_fMaxSeconds = 900.0;
	g_iDamage = 12;
	g_iDamageSpread = 2;
	g_fSlow = 0.55;
	g_fSlowTime = 2.0;
	g_fCooldown = 0.8;
	g_iAmmoMax = 8;
	g_fRange = 1400.0;
	g_fFreezeTime = 1.5;
	g_bFreezeOnKill = true;
	g_bLethal = false;
	g_bFriendlyFire = false;
	g_iFreezetime = 0;
	g_iInput = 0;
	g_bNadeFreeze = true;
	g_iNadeRadius = 250;
	g_fNadeFreezeTime = 2.0;
	g_iVoteRatio = 60;
	g_iVoteMin = 2;
	g_bRotIni = false;
	g_iRotEvery = 6;
	g_iRotMinHumans = 2;
	g_szRotation[0] = EOS;

	new path[160], cfgdir[96];
	get_configsdir(cfgdir, charsmax(cfgdir));
	formatex(path, charsmax(path), "%s/%s", cfgdir, MODES_INI);

	if (!file_exists(path))
	{
		log_amx("[WF-SNOW] no %s - using the built-in defaults", path);
		return;
	}

	new fp = fopen(path, "rt");
	if (!fp)
	{
		log_amx("[WF-SNOW] %s could not be opened - using the built-in defaults", path);
		return;
	}

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

		if (!KeyValue(line, key, charsmax(key), val, charsmax(val)))
			continue;

		if (equal(section, "snow"))
			applySnow(key, val);
		else if (equal(section, "grenade"))
			applyGrenade(key, val);
		else if (equal(section, "vote"))
			applyVote(key, val);
		else if (equal(section, "rotation"))
			applyRotation(key, val);
	}
	fclose(fp);

	log_amx("[WF-SNOW] modes.ini: snow=%d rounds=%d damage=%d slow=%.2f ammo=%d freeze=%.1fs rotation=%d/%d",
		g_bIniSnow ? 1 : 0, g_iRounds, g_iDamage, g_fSlow, g_iAmmoMax, g_fFreezeTime,
		g_bRotIni ? 1 : 0, g_iRotEvery);
}

/* id | enabled | rounds | max_seconds  - only the snow row is ours. */
parseModeRow(const line[])
{
	new id[24];
	if (!WfField(line, 0, id, charsmax(id)) || !equali(id, "snow"))
		return;

	g_bIniSnow = (WfFieldInt(line, 1, 1) != 0) ? true : false;
	g_iRounds = clamp(WfFieldInt(line, 2, g_iRounds), 1, 50);
	g_fMaxSeconds = float(clamp(WfFieldInt(line, 3, floatround(g_fMaxSeconds)), 0, 36000));
}

applySnow(const key[], const val[])
{
	if (equal(key, "damage"))
		g_iDamage = clamp(str_to_num(val), 1, 100);
	else if (equal(key, "damage_spread"))
		g_iDamageSpread = clamp(str_to_num(val), 0, 20);
	else if (equal(key, "slow"))
		g_fSlow = float(clamp(str_to_num(val), 10, 100)) / 100.0;
	else if (equal(key, "slow_time"))
		g_fSlowTime = floatclamp(str_to_float(val), 0.5, 10.0);
	else if (equal(key, "cooldown"))
		g_fCooldown = floatclamp(str_to_float(val), 0.0, 10.0);
	else if (equal(key, "ammo"))
		g_iAmmoMax = clamp(str_to_num(val), 0, 100);
	else if (equal(key, "range"))
		g_fRange = floatclamp(str_to_float(val), 200.0, 8192.0);
	else if (equal(key, "freeze_time"))
		g_fFreezeTime = floatclamp(str_to_float(val), 0.5, 10.0);
	else if (equal(key, "freeze_on_kill"))
		g_bFreezeOnKill = (str_to_num(val) != 0) ? true : false;
	else if (equal(key, "lethal"))
		g_bLethal = (str_to_num(val) != 0) ? true : false;
	else if (equal(key, "friendlyfire"))
		g_bFriendlyFire = (str_to_num(val) != 0) ? true : false;
	else if (equal(key, "freezetime"))
		g_iFreezetime = clamp(str_to_num(val), -1, 60);
	else if (equal(key, "input"))
		g_iInput = clamp(str_to_num(val), 0, 2);
	else if (equal(key, "visual"))
	{
		copy(g_szVisual, charsmax(g_szVisual), val);
		strtolower(g_szVisual);
	}
}

applyGrenade(const key[], const val[])
{
	if (equal(key, "enable"))
		g_bNadeFreeze = (str_to_num(val) != 0) ? true : false;
	else if (equal(key, "radius"))
		g_iNadeRadius = clamp(str_to_num(val), 50, 1000);
	else if (equal(key, "freeze_time"))
		g_fNadeFreezeTime = floatclamp(str_to_float(val), 0.5, 10.0);
}

applyVote(const key[], const val[])
{
	if (equal(key, "ratio"))
		g_iVoteRatio = clamp(str_to_num(val), 1, 100);
	else if (equal(key, "min"))
		g_iVoteMin = clamp(str_to_num(val), 1, 32);
}

applyRotation(const key[], const val[])
{
	if (equal(key, "enable"))
		g_bRotIni = (str_to_num(val) != 0) ? true : false;
	else if (equal(key, "every_rounds"))
		g_iRotEvery = clamp(str_to_num(val), 1, 100);
	else if (equal(key, "min_humans"))
		g_iRotMinHumans = clamp(str_to_num(val), 1, 32);
	else if (equal(key, "list"))
		copy(g_szRotation, charsmax(g_szRotation), val);
}

// "key = value" into key/val. False when the line has no '='.
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
// Mode lifecycle (the arbiter contract)
// ============================================================
/* Start the mode. Returns 1 when it is now running, 0 when it was refused -
 * and a refusal is always explained: to the initiator in chat, to the server
 * console, and in the AMXX log. Nothing is half-applied: the arbiter is claimed
 * BEFORE the first cvar is written, so a refused start changes nothing. */
bool:StartMode(initiator, bool:bForce)
{
	if (g_bMode)
	{
		Refuse(initiator, "the snowball fight is already running (wf_mode off ends it)");
		return false;
	}
	if (!get_pcvar_num(g_pEnable) || !g_bIniSnow)
	{
		Refuse(initiator, "snowball mode is disabled (wf_snow_enable / modes.ini [modes] enabled)");
		return false;
	}
	if (!LibraryExists("fn_mode", LibType_Library))
	{
		// The one hard dependency. Refusing is the whole point: without the
		// arbiter there is nobody to snapshot and restore the cvars, so a
		// running mode would leak mp_friendlyfire into the next round.
		Refuse(initiator, "fn_mode (the mode arbiter) is not loaded - no mode can start");
		return false;
	}
	if (!bForce && CountHumans() < 1)
	{
		Refuse(initiator, "nobody is playing (use 'wf_mode snow force' to start it anyway)");
		return false;
	}

	new payload[64];
	formatex(payload, charsmax(payload), "rounds=%d max=%d", g_iRounds, floatround(g_fMaxSeconds));

	if (!fn_mode_begin(MODE_NAME, payload, initiator))
	{
		// Another mode (warmup, an event, the reindeer hunt) holds the arbiter.
		// fn_mode logged it, told the admins and told the initiator; this
		// plugin records the reason the arbiter gave - to the console too, so
		// an operator reading the server console is not left guessing.
		new why[192];
		fn_mode_refusal(why, charsmax(why));
		console_print(0, "[WF-SNOW] not started: %s", why);
		log_amx("[WF-SNOW] not started: %s", why);
		return false;
	}

	g_bMode = true;
	g_bForced = bForce;
	g_iRoundsLeft = g_iRounds;
	g_iModeSeconds = 0;
	g_iStarts++;

	// The model visual is staged but blocked (client content, docs/WINTERFEST.md
	// §1.1). Say so once per start instead of quietly rendering the sprite: an
	// operator who typed `visual = model` must know why nothing changed.
	if (!equali(g_szVisual, "sprite"))
		log_amx("[WF-SNOW] visual '%s' is not available - client models are blocked by fastdl; using the stock sprite", g_szVisual);

	// Engine cvars - through the arbiter only, so fn_mode_end() puts back the
	// exact pre-mode values (docs/WINTERFEST-MODES.md has the proof).
	ModeSetCvar("mp_friendlyfire", g_bFriendlyFire ? "1" : "0");
	if (g_iFreezetime >= 0)
	{
		new tmp[16];
		formatex(tmp, charsmax(tmp), "%d", g_iFreezetime);
		ModeSetCvar("mp_freezetime", tmp);
	}

	// Fresh ammo and a clean slate for everyone who is already here.
	for (new id = 1; id <= MaxClients; id++)
	{
		g_iAmmo[id] = g_iAmmoMax;
		g_fNextThrow[id] = 0.0;
		g_bVoted[id] = false;
		ClearEffects(id);
	}

	client_print(0, print_chat, "[WF] Snowball fight! Mouse2 (or 'bind <key> +snowball') throws - frozen grenades work too.");
	if (!g_bFriendlyFire)
		client_print(0, print_chat, "[WF] Friendly fire is off; a snowball slows, and the last hit freezes instead of killing.");

	log_amx("[WF-SNOW] started by %d (rounds=%d max=%ds damage=%d ammo=%d ff=%d lethal=%d forced=%d tracked=%d)",
		initiator, g_iRounds, floatround(g_fMaxSeconds), g_iDamage, g_iAmmoMax,
		g_bFriendlyFire ? 1 : 0, g_bLethal ? 1 : 0, g_bForced ? 1 : 0, fn_mode_count());

	remove_task(TASK_MODE_CLOCK);
	set_task(1.0, "Task_ModeClock", TASK_MODE_CLOCK, _, _, "b");
	return true;
}

/* End the mode and prove the restore: fn_mode_end() returns how many cvars it
 * put back, and that number goes in the log line. */
EndMode(const reason[])
{
	if (!g_bMode)
		return;

	remove_task(TASK_MODE_CLOCK);
	g_bMode = false;
	g_bForced = false;

	new restored = 0;
	if (LibraryExists("fn_mode", LibType_Library))
		restored = fn_mode_end(MODE_NAME);

	for (new id = 1; id <= MaxClients; id++)
	{
		ClearEffects(id);
		g_iAmmo[id] = 0;
		g_bVoted[id] = false;
	}

	g_iEnds++;
	client_print(0, print_chat, "[WF] Snowball fight over - normal weapons, damage and rules are back.");
	log_amx("[WF-SNOW] ended (%s) - %d cvar(s) restored", reason, restored);
}

/* Write one engine cvar for this mode. The ONLY write path in this plugin: if
 * the arbiter is absent, not ours, or the cvar table is full, nothing is
 * written and the failure is logged. A missing cvar means a typo, and a typo
 * must not "restore" something that never existed. */
bool:ModeSetCvar(const cvar[], const value[])
{
	if (!g_bMode || !LibraryExists("fn_mode", LibType_Library))
		return false;

	if (!fn_mode_set(MODE_NAME, cvar, value))
	{
		log_amx("[WF-SNOW] arbiter refused %s=%s - value not applied", cvar, value);
		return false;
	}
	return true;
}

/* One line to whoever asked, plus the log. A refusal is never silent. */
Refuse(initiator, const reason[])
{
	if (initiator > 0 && initiator <= MaxClients && is_user_connected(initiator) && !is_user_bot(initiator))
		WfSay(initiator, reason);
	else
		console_print(0, "[WF-SNOW] %s", reason);
	log_amx("[WF-SNOW] refused: %s", reason);
}

// ============================================================
// Round clock: rounds left, the max_seconds ceiling, an empty server
// ============================================================
public ev_NewRound()
{
	g_iRoundCounter++;

	// Votes are per round: a vote that failed last round gets a fresh start.
	for (new id = 1; id <= MaxClients; id++)
		g_bVoted[id] = false;

	if (g_bMode)
	{
		g_iRoundsLeft--;
		if (g_iRoundsLeft <= 0)
		{
			EndMode("rounds used up");
			return;
		}
		return;
	}

	RotationTick();
}

public Task_ModeClock()
{
	if (!g_bMode)
	{
		remove_task(TASK_MODE_CLOCK);
		return;
	}

	g_iModeSeconds++;

	// Two ways out that do not need an admin: nobody left, or the ceiling.
	// A `force` start keeps the first one off - that is what force is for: an
	// operator setting a mode up before the players arrive. The rounds and the
	// ceiling still end it, so it can never run forever.
	if (!g_bForced && CountHumans() < 1)
	{
		EndMode("server empty");
		return;
	}
	if (g_fMaxSeconds > 0.0 && float(g_iModeSeconds) >= g_fMaxSeconds)
		EndMode("time limit");
}

/* The rotation: at most one mode at a time (the arbiter), so this is a
 * sequence - one slot every `every_rounds`, each entry lasting its own rounds
 * from [modes]. An entry that cannot start (disabled, its library missing,
 * the arbiter busy) is skipped and the next one is tried, so a broken row never
 * burns the rotation. */
RotationTick()
{
	new setting = get_pcvar_num(g_pRotation);
	new bool:on = (setting < 0) ? g_bRotIni : (setting != 0) ? true : false;
	if (!on || !g_szRotation[0])
		return;
	if (g_iRotEvery <= 0 || (g_iRoundCounter % g_iRotEvery) != 0)
		return;
	if (CountHumans() < g_iRotMinHumans)
		return;

	new count = RotationCount();
	if (count < 1)
		return;

	for (new attempt = 0; attempt < count; attempt++)
	{
		new idx = (g_iRotationIdx + attempt) % count;
		new entry[24];
		if (!RotationEntry(idx, entry, charsmax(entry)))
			continue;

		if (equali(entry, "snow"))
		{
			if (StartMode(0, true))
			{
				g_iRotationIdx = (idx + 1) % count;
				return;
			}
		}
		else if (equali(entry, "reindeer"))
		{
			if (!LibraryExists("winterfest_reindeer", LibType_Library))
			{
				log_amx("[WF-SNOW] rotation entry 'reindeer' skipped: winterfest_reindeer is not loaded");
				continue;
			}
			if (wf_reindeer_start(0, 1))
			{
				g_iRotationIdx = (idx + 1) % count;
				return;
			}
		}
		else
		{
			log_amx("[WF-SNOW] rotation entry '%s' is not a mode - skipped", entry);
		}
	}
}

stock RotationCount()
{
	if (!g_szRotation[0])
		return 0;
	new n = 1;
	for (new i = 0; g_szRotation[i]; i++)
	{
		if (g_szRotation[i] == ',')
			n++;
	}
	return n;
}

stock bool:RotationEntry(index, out[], len)
{
	out[0] = EOS;
	new cur = 0, start = 0;
	for (new i = 0; ; i++)
	{
		new ch = g_szRotation[i];
		if (ch == ',' || ch == EOS)
		{
			if (cur == index)
			{
				new c = i - start;
				if (c < 0)
					c = 0;
				if (c > len - 1)
					c = len - 1;
				for (new k = 0; k < c; k++)
					out[k] = g_szRotation[start + k];
				out[c] = EOS;
				trim(out);
				return out[0] ? true : false;
			}
			cur++;
			start = i + 1;
			if (ch == EOS)
				break;
		}
	}
	return false;
}

// ============================================================
// Throwing
// ============================================================
/* `bind <key> +snowball` - the input that costs a player nothing but one key. */
public cmdThrowBound(id)
{
	// Always handled: the engine has no +snowball, and letting it through would
	// print "Unknown command" in the player's console.
	if (g_bMode)
		ThrowSnowball(id, true);
	return PLUGIN_HANDLED;
}

public cmdThrowRelease(id)
{
	#pragma unused id
	return PLUGIN_HANDLED;
}

/* `+attack2` - mouse2, no setup at all. Outside the mode this returns
 * PLUGIN_CONTINUE, so scoping and silencer toggling are untouched; inside it,
 * `input` decides (0 = here, 1 = never, 2 = here). */
public cmdThrowAttack2(id)
{
	if (!g_bMode || g_iInput == 1)
		return PLUGIN_CONTINUE;

	ThrowSnowball(id, false);
	return PLUGIN_HANDLED;
}

/* A frozen player cannot shoot: "+attack" is swallowed for the freeze's whole
 * duration. Nothing else in the mode touches the trigger. */
public cmdBlockAttack(id)
{
	if (g_bMode && g_bFrozen[id])
	{
		Hud(id, 4, 200, 235, 255, 0.62, 1.0, "You are frozen solid!");
		return PLUGIN_HANDLED;
	}
	return PLUGIN_CONTINUE;
}

ThrowSnowball(id, bool:bViaBind)
{
	if (!(1 <= id <= MaxClients) || !is_user_connected(id))
		return;
	if (is_user_bot(id) || is_user_hltv(id) || !is_user_alive(id))
		return;
	if (!g_bMode)
		return;

	if (!bViaBind && g_iInput == 1)
		return;

	if (g_bFrozen[id])
	{
		Hud(id, 4, 200, 235, 255, 0.62, 1.0, "Frozen solid - you cannot throw");
		return;
	}

	new Float:now = get_gametime();
	if (now < g_fNextThrow[id])
		return;                                  // still cooling down: silent on purpose

	if (g_iAmmoMax > 0 && g_iAmmo[id] <= 0)
	{
		Hud(id, 3, 255, 235, 180, 0.62, 1.2, "No snowballs left - die or wait for the next round");
		return;
	}

	g_fNextThrow[id] = now + g_fCooldown;
	if (g_iAmmoMax > 0)
		g_iAmmo[id]--;

	ThrowTrace(id);

	if (g_iAmmoMax > 0 && g_iAmmo[id] <= 0)
		Hud(id, 3, 255, 235, 180, 0.70, 1.2, "Last snowball!");
	return;
}

/* The hitscan: eye -> view direction -> first solid thing. `ignore_monsters`
 * is 0 so a player body stops the trace; the thrower is skipped, so a snowball
 * never hits the hand that threw it. */
ThrowTrace(id)
{
	new iorigin[3];
	get_user_origin(id, iorigin, 1);              // 1 = eye position

	new Float:start[3];
	start[0] = float(iorigin[0]);
	start[1] = float(iorigin[1]);
	start[2] = float(iorigin[2]);

	new Float:dir[3];
	velocity_by_aim(id, floatround(g_fRange), dir);
	if (dir[0] == 0.0 && dir[1] == 0.0 && dir[2] == 0.0)
		return;

	new Float:end[3];
	end[0] = start[0] + dir[0];
	end[1] = start[1] + dir[1];
	end[2] = start[2] + dir[2];

	engfunc(EngFunc_TraceLine, start, end, 0, id, 0);
	new Float:hitpos[3];
	get_tr2(0, TR_vecEndPos, hitpos);
	new hit = get_tr2(0, TR_pHit);

	SnowBeam(start, hitpos);
	SnowPuff(hitpos, 6);

	if (get_pcvar_num(g_pDebug))
		log_amx("[WF-SNOW] id %d threw at %.0f %.0f %.0f, first solid thing=%d",
			id, hitpos[0], hitpos[1], hitpos[2], hit);

	if (hit > 0 && hit <= MaxClients && is_user_alive(hit))
		SnowballHit(id, hit, hitpos);
}

SnowballHit(thrower, victim, const Float:at[3])
{
	if (victim == thrower)
		return;

	if (!g_bFriendlyFire && get_user_team(thrower) == get_user_team(victim))
	{
		Hud(thrower, 2, 200, 230, 255, 0.55, 1.0, "That was a team-mate - friendly fire is off");
		return;
	}

	new dmg = g_iDamage;
	if (g_iDamageSpread > 0)
		dmg += random_num(0, g_iDamageSpread * 2) - g_iDamageSpread;
	dmg = clamp(dmg, 1, 100);

	if (g_bLethal)
	{
		// Operator's choice: real damage, real consequences downstream.
		ExecuteHamB(Ham_TakeDamage, victim, thrower, thrower, float(dmg), DMG_BULLET);
		Hud(thrower, 2, 220, 245, 255, 0.55, 1.0, "Snowball hit for %d", dmg);
		SnowFade(victim, 210, 235, 255, 90);
		return;
	}

	new hp = get_user_health(victim);
	new left = hp - dmg;
	if (left <= 0 && g_bFreezeOnKill)
	{
		// "Frozen solid" instead of a death: keep the last hit point so the
		// engine has nothing to kill, then take the legs and the trigger away
		// for freeze_time. Nobody dies, no frag, no stats.
		set_user_health(victim, 1);
		FreezePlayer(victim, g_fFreezeTime, thrower);
	}
	else
	{
		if (left < 1)
			left = 1;
		set_user_health(victim, left);
		ApplySlow(victim);
		Hud(victim, 2, 210, 235, 255, 0.60, 1.2, "Snowball: -%d HP", dmg);
		SnowFade(victim, 200, 225, 255, 70);
	}

	Hud(thrower, 2, 220, 245, 255, 0.55, 1.0, "Snowball hit: -%d HP", dmg);
	SnowPuff(at, 10);
}

// ============================================================
// Frozen grenades: hegrenade explosion -> freeze everyone inside the radius
// ============================================================
/* The identification is the thrown entity's world model. It is the only
 * discriminator that does not need a grenade vtable hook this AMXX build does
 * not expose (ham_const.inc has no Ham_Explode and ReAPI's gamedll hook set
 * here has no CBaseGrenade::Explode). A flashbang keeps hurting and blinding
 * exactly like before; a smoke grenade does no damage and never reaches here. */
public Ham_TakeDamage_Pre(victim, inflictor, attacker, Float:damage, damagebits)
{
	#pragma unused damage, damagebits
	if (!g_bMode || !g_bNadeFreeze)
		return HAM_IGNORED;
	if (!(1 <= victim <= MaxClients) || !is_user_connected(victim))
		return HAM_IGNORED;
	if (!inflictor || inflictor <= MaxClients || !pev_valid(inflictor))
		return HAM_IGNORED;
	if (pev(inflictor, pev_iuser1))
		return HAM_IGNORED;               // this explosion was already handled once

	new model[64];
	pev(inflictor, pev_model, model, charsmax(model));
	if (containi(model, "hegrenade") < 0)
		return HAM_IGNORED;

	set_pev(inflictor, pev_iuser1, 1);

	new Float:origin[3];
	pev(inflictor, pev_origin, origin);
	FreezeRadius(origin, attacker);
	return HAM_IGNORED;
}

FreezeRadius(const Float:origin[3], attacker)
{
	new players[MAX_PLAYERS], num;
	get_players(players, num, "ach");          // alive, no bots, no HLTV
	if (num < 1)
		return;

	new Float:r2 = float(g_iNadeRadius) * float(g_iNadeRadius);
	new frozen = 0;
	new msg[192];
	msg[0] = EOS;

	for (new i = 0; i < num; i++)
	{
		new id = players[i];
		new Float:mine[3];
		pev(id, pev_origin, mine);

		new Float:dx = mine[0] - origin[0];
		new Float:dy = mine[1] - origin[1];
		new Float:dz = mine[2] - origin[2];
		if (dx * dx + dy * dy + dz * dz > r2)
			continue;

		FreezePlayer(id, g_fNadeFreezeTime, attacker);
		Hud(id, 4, 200, 235, 255, 0.62, 1.5, "Frozen by a grenade for %.1f s", g_fNadeFreezeTime);
		frozen++;
	}

	if (frozen < 1)
		return;

	new aname[MAX_NAME_LENGTH];
	aname[0] = EOS;
	if (attacker > 0 && attacker <= MaxClients)
		get_user_name(attacker, aname, charsmax(aname));

	if (aname[0])
		formatex(msg, charsmax(msg), "%s's frozen grenade froze %d player(s)", aname, frozen);
	else
		formatex(msg, charsmax(msg), "A frozen grenade froze %d player(s)", frozen);

	client_print(0, print_chat, "[WF] %s.", msg);
	log_amx("[WF-SNOW] %s", msg);
}

// ============================================================
// Player effects: freeze (maxspeed 1 + no attack) and slow (a fraction)
// ============================================================
/* maxspeed is the one thing fn_mode cannot hold: it is a per-player field, not
 * a cvar. So this plugin keeps its own little table - the value the player had
 * BEFORE the first effect - and puts it back when the last effect runs out. A
 * mode end, a death, a respawn, a disconnect and a map end all clear it, so a
 * frozen player can never be left crawling at maxspeed 1. */
FreezePlayer(id, Float:seconds, attacker)
{
	if (!(1 <= id <= MaxClients) || !is_user_alive(id))
		return;

	HoldSpeed(id);

	g_bFrozen[id] = true;
	g_fFrozenUntil[id] = get_gametime() + floatmax(0.1, seconds);

	RefreshSpeed(id);
	SnowFade(id, 190, 225, 255, 170);

	Hud(id, 4, 200, 235, 255, 0.62, 1.5, "Frozen solid - %.1f s", seconds);

	if (attacker > 0 && attacker <= MaxClients && attacker != id)
	{
		new name[MAX_NAME_LENGTH];
		get_user_name(id, name, charsmax(name));
		Hud(attacker, 2, 220, 245, 255, 0.50, 1.2, "%s is frozen solid", name);
	}
}

ApplySlow(id)
{
	if (!(1 <= id <= MaxClients) || !is_user_alive(id))
		return;

	HoldSpeed(id);
	g_bSlowed[id] = true;
	g_fSlowUntil[id] = get_gametime() + g_fSlowTime;
	RefreshSpeed(id);
	Hud(id, 2, 210, 235, 255, 0.66, 1.2, "Slowed - the cold is in your boots");
}

/* Snapshot the pre-effect speed exactly once. */
HoldSpeed(id)
{
	if (g_bSpeedHeld[id])
		return;
	g_fSpeedBase[id] = get_user_maxspeed(id);
	if (g_fSpeedBase[id] < 1.0)
		g_fSpeedBase[id] = 250.0;             // a spectator/edge case: sane default
	g_bSpeedHeld[id] = true;
}

/* Apply the strongest active effect and schedule a re-check for the next one to
 * expire. Frozen beats slowed; with neither, the remembered speed goes back. */
RefreshSpeed(id)
{
	if (!(1 <= id <= MaxClients) || !is_user_connected(id) || is_user_bot(id) || is_user_hltv(id))
	{
		g_bFrozen[id] = false;
		g_bSlowed[id] = false;
		g_bSpeedHeld[id] = false;
		return;
	}

	new Float:now = get_gametime();

	if (g_bFrozen[id] && now >= g_fFrozenUntil[id])
		g_bFrozen[id] = false;
	if (g_bSlowed[id] && now >= g_fSlowUntil[id])
		g_bSlowed[id] = false;

	if (!g_bFrozen[id] && !g_bSlowed[id])
	{
		remove_task(id + TASK_SPEED);
		if (g_bSpeedHeld[id])
		{
			set_user_maxspeed(id, g_fSpeedBase[id]);
			g_bSpeedHeld[id] = false;
		}
		return;
	}

	new Float:speed;
	if (g_bFrozen[id])
		speed = 1.0;
	else
		speed = g_fSpeedBase[id] * g_fSlow;

	set_user_maxspeed(id, speed);

	new Float:next = 0.0;
	if (g_bFrozen[id])
		next = g_fFrozenUntil[id];
	if (g_bSlowed[id] && (next <= 0.0 || g_fSlowUntil[id] < next))
		next = g_fSlowUntil[id];

	remove_task(id + TASK_SPEED);
	if (next > 0.0)
		set_task(floatmax(0.05, next - now), "Task_SpeedExpire", id + TASK_SPEED);
}

public Task_SpeedExpire(taskid)
{
	new id = taskid - TASK_SPEED;
	if (!(1 <= id <= MaxClients))
		return;
	RefreshSpeed(id);
}

/* Put a player back exactly as the mode found them. Safe to call for anybody,
 * any time, any number of times. */
ClearEffects(id)
{
	if (!(1 <= id <= MaxClients))
		return;

	remove_task(id + TASK_SPEED);
	g_bFrozen[id] = false;
	g_bSlowed[id] = false;
	g_fFrozenUntil[id] = 0.0;
	g_fSlowUntil[id] = 0.0;

	if (g_bSpeedHeld[id])
	{
		if (is_user_connected(id) && is_user_alive(id))
			set_user_maxspeed(id, g_fSpeedBase[id]);
		g_bSpeedHeld[id] = false;
	}
}

public Ham_Spawn_Post(id)
{
	if (!(1 <= id <= MaxClients))
		return HAM_IGNORED;

	ClearEffects(id);
	g_iAmmo[id] = g_iAmmoMax;
	g_fNextThrow[id] = 0.0;
	g_bVoted[id] = false;
	return HAM_IGNORED;
}

public Ham_Killed_Post(victim, attacker, shouldgib)
{
	#pragma unused attacker, shouldgib
	if (1 <= victim <= MaxClients)
		ClearEffects(victim);
	return HAM_IGNORED;
}

public client_disconnected(id)
{
	if (!(1 <= id <= MaxClients))
		return;

	g_bFrozen[id] = false;
	g_bSlowed[id] = false;
	g_bSpeedHeld[id] = false;
	g_bVoted[id] = false;
	g_iAmmo[id] = 0;
	remove_task(id + TASK_SPEED);
}

// ============================================================
// Vote: /wfsnow
// ============================================================
public cmdVote(id)
{
	if (!(1 <= id <= MaxClients) || !is_user_connected(id) || is_user_bot(id) || is_user_hltv(id))
		return PLUGIN_HANDLED;

	if (!get_pcvar_num(g_pVote))
	{
		WfSay(id, "mode voting is off.");
		return PLUGIN_HANDLED;
	}
	if (g_bMode)
	{
		WfSay(id, "the snowball fight is already running.");
		return PLUGIN_HANDLED;
	}
	if (!get_pcvar_num(g_pEnable) || !g_bIniSnow)
	{
		WfSay(id, "snowball mode is disabled today.");
		return PLUGIN_HANDLED;
	}
	if (g_bVoted[id])
	{
		WfSay(id, "you already voted for a snowball fight this round.");
		return PLUGIN_HANDLED;
	}

	g_bVoted[id] = true;

	new humans = CountHumans();
	new votes = CountVotes();
	new need = floatround(float(humans) * float(g_iVoteRatio) / 100.0, floatround_ceil);
	if (need < g_iVoteMin)
		need = g_iVoteMin;

	new name[MAX_NAME_LENGTH];
	get_user_name(id, name, charsmax(name));
	client_print(0, print_chat, "[WF] %s wants a snowball fight - %d/%d votes (%d needed).", name, votes, humans, need);
	log_amx("[WF-SNOW] vote from %d: %d/%d (need %d)", id, votes, humans, need);

	if (votes >= need)
		StartMode(id, false);

	return PLUGIN_HANDLED;
}

stock CountVotes()
{
	new n = 0;
	for (new id = 1; id <= MaxClients; id++)
	{
		if (g_bVoted[id] && is_user_connected(id) && !is_user_bot(id) && !is_user_hltv(id))
			n++;
	}
	return n;
}

// ============================================================
// Admin: wf_mode / wf_modes_reload
// ============================================================
public cmdMode(id, level, cid)
{
	if (!cmd_access(id, level, cid, 1))
		return PLUGIN_HANDLED;

	new sub[24];
	read_argv(1, sub, charsmax(sub));

	if (!sub[0])
	{
		PrintStatus(id);
		return PLUGIN_HANDLED;
	}

	if (equali(sub, "status"))
	{
		PrintStatus(id);
		return PLUGIN_HANDLED;
	}

	if (equali(sub, "off"))
	{
		EndAnyMode(id);
		return PLUGIN_HANDLED;
	}

	if (equali(sub, "snow"))
	{
		new force[8];
		read_argv(2, force, charsmax(force));
		StartMode(id, equali(force, "force") ? true : false);
		return PLUGIN_HANDLED;
	}

	if (equali(sub, "reindeer"))
	{
		if (!LibraryExists("winterfest_reindeer", LibType_Library))
		{
			Refuse(id, "the reindeer hunt module is not loaded (winterfest_reindeer.amxx)");
			return PLUGIN_HANDLED;
		}
		new force[8];
		read_argv(2, force, charsmax(force));
		if (!wf_reindeer_start(id, equali(force, "force") ? 1 : 0))
			log_amx("[WF-SNOW] wf_mode reindeer not started (see the winterfest_reindeer line above)");
		return PLUGIN_HANDLED;
	}

	console_print(id, "[WF-SNOW] usage: wf_mode <snow|reindeer|off|status> [force]");
	return PLUGIN_HANDLED;
}

/* "off" must end whichever Winterfest mode is running, including the one the
 * other module owns - that is what "the round always returns to normal" means
 * for the operator typing the command. */
EndAnyMode(initiator)
{
	if (g_bMode)
	{
		EndMode("wf_mode off");
		return;
	}

	if (LibraryExists("winterfest_reindeer", LibType_Library) && wf_reindeer_active())
	{
		wf_reindeer_stop();
		return;
	}

	// Nothing of ours is running. Say so - and mention a foreign mode, because
	// "off does nothing" with warmup holding the arbiter is confusing.
	new active[32];
	active[0] = EOS;
	if (LibraryExists("fn_mode", LibType_Library))
		fn_mode_active(active, charsmax(active));

	if (active[0])
	{
		if (initiator > 0)
			WfSay(initiator, "no Winterfest mode is running (another mode holds the arbiter - see `fn_mode status`).");
		else
			console_print(0, "[WF-SNOW] no Winterfest mode is running; the arbiter is held by '%s'", active);
	}
	else
	{
		if (initiator > 0)
			WfSay(initiator, "no Winterfest mode is running.");
		else
			console_print(0, "[WF-SNOW] no Winterfest mode is running.");
	}
}

/* `wf_mode status`: one block an operator (and the harness probe) can read.
 * "[WF-SNOW] ..." lines are the machine-readable half. */
PrintStatus(id)
{
	new num = 0;
	if (LibraryExists("fn_mode", LibType_Library))
		num = fn_mode_count();

	console_print(id, "[WF-SNOW] snow mode=%d running=%d forced=%d rounds_left=%d seconds=%d arbiter_cvars=%d starts=%d ends=%d",
		g_bMode ? 1 : 0, g_bMode ? 1 : 0, g_bForced ? 1 : 0, g_iRoundsLeft, g_iModeSeconds, num, g_iStarts, g_iEnds);
	console_print(id, "[WF-SNOW] tuning damage=%d+/-%d slow=%.2f/%.1fs cooldown=%.1fs ammo=%d range=%.0f",
		g_iDamage, g_iDamageSpread, g_fSlow, g_fSlowTime, g_fCooldown, g_iAmmoMax, g_fRange);
	console_print(id, "[WF-SNOW] freeze %.1fs on_kill=%d lethal=%d ff=%d input=%d freezetime=%d visual=%s",
		g_fFreezeTime, g_bFreezeOnKill ? 1 : 0, g_bLethal ? 1 : 0, g_bFriendlyFire ? 1 : 0,
		g_iInput, g_iFreezetime, g_szVisual);
	console_print(id, "[WF-SNOW] grenade freeze=%d radius=%d time=%.1fs",
		g_bNadeFreeze ? 1 : 0, g_iNadeRadius, g_fNadeFreezeTime);
	console_print(id, "[WF-SNOW] vote on=%d ratio=%d%% min=%d rotation=%s every=%d humans=%d",
		get_pcvar_num(g_pVote), g_iVoteRatio, g_iVoteMin,
		(g_szRotation[0] ? g_szRotation : "<none>"), g_iRotEvery, CountHumans());

	new active[32];
	active[0] = EOS;
	if (LibraryExists("fn_mode", LibType_Library))
		fn_mode_active(active, charsmax(active));
	console_print(id, "[WF-SNOW] arbiter=%s", active[0] ? active : "<free>");

	new reindeer = 0;
	if (LibraryExists("winterfest_reindeer", LibType_Library))
		reindeer = wf_reindeer_active() ? 1 : 0;
	console_print(id, "[WF-SNOW] reindeer_lib=%d reindeer_running=%d core=%d",
		LibraryExists("winterfest_reindeer", LibType_Library) ? 1 : 0, reindeer,
		LibraryExists("winterfest_core", LibType_Library) ? 1 : 0);
}

public cmdReload(id, level, cid)
{
	if (!cmd_access(id, level, cid, 1))
		return PLUGIN_HANDLED;

	loadConfig();
	if (LibraryExists("winterfest_reindeer", LibType_Library))
		wf_reindeer_reload();          // one command, both readers of modes.ini
	console_print(id, "[WF-SNOW] modes.ini re-read.");
	return PLUGIN_HANDLED;
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

stock Hud(id, channel, red, green, blue, Float:y, Float:hold, const fmt[], any:...)
{
	new msg[192];
	vformat(msg, charsmax(msg), fmt, 9);

	set_hudmessage(red, green, blue, -1.0, y, 0, 0.0, hold, 0.1, 0.2, channel);
	show_hudmessage(id, "%s", msg);
}

/* A stock-sprite beam: one temp entity, no entity, no client asset. */
stock SnowBeam(const Float:start[3], const Float:end[3])
{
	message_begin(MSG_BROADCAST, SVC_TEMPENTITY);
	write_byte(TE_BEAMPOINTS);
	write_coord(floatround(start[0]));
	write_coord(floatround(start[1]));
	write_coord(floatround(start[2]));
	write_coord(floatround(end[0]));
	write_coord(floatround(end[1]));
	write_coord(floatround(end[2]));
	write_short(g_sprBeam);
	write_byte(0);            // start frame
	write_byte(0);            // frame rate
	write_byte(4);            // life 0.1 s
	write_byte(4);            // line width
	write_byte(0);            // noise
	write_byte(255);          // red   - snow is white
	write_byte(255);          // green
	write_byte(255);          // blue
	write_byte(180);          // brightness
	write_byte(0);            // scroll speed
	message_end();
}

stock SnowPuff(const Float:origin[3], scale)
{
	message_begin(MSG_BROADCAST, SVC_TEMPENTITY);
	write_byte(TE_SPRITE);
	write_coord(floatround(origin[0]));
	write_coord(floatround(origin[1]));
	write_coord(floatround(origin[2]));
	write_short(g_sprPuff);
	write_byte(clamp(scale, 1, 255));
	write_byte(200);
	message_end();
}

/* Deliberately pale blue, never near-white: freenova_flash treats a
 * R,G,B,alpha >= 200 fade as a flashbang and would suppress it. */
stock SnowFade(id, red, green, blue, alpha)
{
	message_begin(MSG_ONE_UNRELIABLE, get_user_msgid("ScreenFade"), _, id);
	write_short(floatround(4096.0 * 0.30));   // duration
	write_short(floatround(4096.0 * 0.20));   // hold
	write_short(0x0000);                      // fade in
	write_byte(red);
	write_byte(green);
	write_byte(blue);
	write_byte(alpha);
	message_end();
}
