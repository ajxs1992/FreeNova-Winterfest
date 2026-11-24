/*
 * ============================================================================
 * winterfest_cosmetics - the cosmetic registry, and what a player can wear
 * ============================================================================
 * Contract: docs/WINTERFEST.md sec 1.1 (client content and what it costs),
 * sec 4 Phase 3. Format, weight policy, enable sequence and the honest limits:
 * docs/WINTERFEST-COSMETICS.md.
 *
 * Registry: configs/freenova/winterfest/cosmetics.ini, one row per cosmetic:
 *   id | name | kind | weight | bytes | rarity | source | dl | asset | text
 * Kind is hat/skin/model/title/badge/effect; weight is small/medium/heavy, i.e.
 * what a client downloads; source is how it is earned (gift, advent:N, pass:N,
 * tree:N, secret:N, none). Award logic elsewhere names an id, never a path.
 *
 * Entitlement: the four core-backed sources are ASKED of winterfest_core
 * (advent day, pass tier, tree level, ornament set) so the core stays the score;
 * a present-paid cosmetic is recorded in one flat file per player, because the
 * core has no cosmetics reward kind.
 *
 * Titles and badges need no client asset and are the layer that works today.
 * Hats are an engine-side follower entity (MOVETYPE_FOLLOW + aiment, the trick
 * parachute.sma uses) and are only served once the download gate is open.
 *
 * Switches:
 *   wf_cosmetics 1        (default) small rows (< 150 KB) precached and served;
 *                         titles and badges live
 *   wf_cosmetics 0        nothing: no registry read, no precache, no entity
 *   wf_cosmetics_heavy 0  (default) medium/heavy rows are NOT precached - every
 *                         client would fetch them on connect, which is the
 *                         operator's call
 *   wf_cosmetics_name 1   a worn title also prefixes the scoreboard name
 *   wf_cosmetics_chat 1   borrow freenova_cosmetics' chat-tag slot when the
 *                         player holds the licence and the slot is empty
 *   wf_fx 1               the kill / death / spawn effects (sec 10 of the doc)
 *   wf_fx_entmax 12       live effect entity ceiling, global / per player
 *   wf_fx_entmax_p 2
 *   wf_fx_verb 1          the kill line: 0 off, 1 killer+victim, 2 everyone
 *   wf_fx_lpm 1           a Low Performance Mode player gets the chat line only
 *   wf_fx_debug 0         one log line per effect, with the entity count
 *
 * No say/say_team hook: the tree already has one chat formatter and a second one
 * either doubles every line or wins the race against it.
 * ============================================================================
 */

#include <amxmodx>
#include <amxmisc>
#include <engine>
#include <fakemeta>
#include <hamsandwich>
#include <winterfest>
#include <winterfest_cosmetics>
// The chat-tag slot this plugin borrows belongs to freenova_cosmetics. The
// include is only for the native names: every call is gated on
// LibraryExists("freenova_cosmetics") and plugin_natives() installs a native
// filter, so a server without that plugin still runs everything else.
#include <freenova_cosmetics>
// Low Performance Mode is a per-player preference owned by freenova_prefs; the
// effects degrade to a chat line for a player who has it on. Same rule: include
// for the native names, gate every call on LibraryExists.
#include <freenova_prefs>

#define PLUGIN  "Winterfest Cosmetics"
#define VERSION "1.1.0"
#define AUTHOR  "FreeNova"

#define REGISTRY_FILE "freenova/winterfest/cosmetics.ini"
#define PLAYER_DIR "freenova_wf_cosmetics"
#define HAT_CLASS "wf_cosmetic_hat"
#define FX_CLASS "wf_cosmetic_fx"

// The owned set is two 32-bit words (g_iOwned[id][idx >> 5]), so WFCOS_MAX can
// never pass 63: row 64 and up would write into memory that is not there.
#define WFCOS_MAX 60
#define WFCOS_ID_LEN 24
#define WFCOS_NAME_LEN 32
#define WFCOS_ASSET_LEN 200
#define WFCOS_TEXT_LEN 24
#define WFCOS_MAX_PATHS 8

// Effect entities that can be alive at once, per the shipped defaults. This is
// the tracking table, not the policy: wf_fx_entmax is the policy and it is
// clamped to this.
#define WFCOS_FX_LIVE 16
#define WFCOS_FX_REAP_SECS 0.25
#define WFCOS_FX_SPAWN_DELAY 0.45
#define WFCOS_FX_SCAN_SECS 3.0
#define WFCOS_PREVIEW_GAP 3

// The visual grammar of an effect is picked from the sprite its registry row
// names, so an operator who drops in a new .spr gets the right colours, beam
// and trail for free, and an unknown one falls back to snow.
#define WFCOS_LOOK_SNOW 0
#define WFCOS_LOOK_BAUBLE 1
#define WFCOS_LOOK_GIFT 2
#define WFCOS_LOOK_ICE 3
#define WFCOS_LOOK_ANGEL 4
#define WFCOS_LOOK_RING 5

#define F_DL 1
#define F_OK 2
#define F_PRE 4

enum
{
	TASK_LATE = 94000,
	TASK_FX_REAP,
	TASK_FX_SPAWN
}

new bool:g_bLoaded;
new g_iCount;
new g_szId[WFCOS_MAX + 1][WFCOS_ID_LEN];
new g_szName[WFCOS_MAX + 1][WFCOS_NAME_LEN];
new g_szText[WFCOS_MAX + 1][WFCOS_TEXT_LEN];
new g_szAsset[WFCOS_MAX + 1][WFCOS_ASSET_LEN];
new g_iKind[WFCOS_MAX + 1];
new g_iWeight[WFCOS_MAX + 1];
new g_iDeclared[WFCOS_MAX + 1];
new g_iSrc[WFCOS_MAX + 1];
new g_iSrcVal[WFCOS_MAX + 1];
new g_iFlags[WFCOS_MAX + 1];
new g_iPreBytes;
new g_iFxModel[WFCOS_MAX + 1];     // precached sprite index, 0 = not servable
// A packed sheet: one .spr with every frame inside it, drawn with env_sprite's
// pev_framerate. 0 = the row is not a sheet (no sheet file, sheets off, or the
// file is missing), and the kill/death/spawn falls back to the older
// sprite + message pair. See docs/WINTERFEST-COSMETICS.md sec 10.3.
new g_iFxSheetModel[WFCOS_MAX + 1];
new g_iFxSheetFrames[WFCOS_MAX + 1];
new g_iFxTint[WFCOS_MAX + 1][3];

new bool:g_bLoadedP[MAX_PLAYERS + 1];
new g_iOwned[MAX_PLAYERS + 1][2];
new g_iEquip[MAX_PLAYERS + 1][WFCOS_MAX_SLOTS + 1];
new g_iHat[MAX_PLAYERS + 1];
new g_iPending[MAX_PLAYERS + 1];
new g_iTries[MAX_PLAYERS + 1];
new g_szBase[MAX_PLAYERS + 1][MAX_NAME_LENGTH];
new bool:g_bPrefixed[MAX_PLAYERS + 1];
new bool:g_bTaged[MAX_PLAYERS + 1];

new g_pOn;
new g_pHeavy;
new g_pName;
new g_pChat;
new g_pFx;
new g_pFxEnts;
new g_pFxEntsP;
new g_pFxVerb;
new g_pFxLpm;
new g_pFxDebug;
new g_pFxSheet;

// Live effect entities: a fixed table, so "how many are there" is a counter and
// not a scan, and the reaper never walks the entity list.
new g_iFxLiveEnt[WFCOS_FX_LIVE];
new Float:g_fFxLiveEnd[WFCOS_FX_LIVE];
new g_iFxLiveOwner[WFCOS_FX_LIVE];
new g_iFxLiveUsed;
new g_iFxPerPlayer[MAX_PLAYERS + 1];
new g_iFxPlayed;                    // effects that reached the screen
new g_iFxSkipped;                   // entity layer refused by a ceiling
new g_iFxLpm;                       // effects downgraded to the chat line
new bool:g_bFxReaping;
new bool:g_bFxQuiet[33];      // wf_cos_preview 0 - this player wants no effects
new g_iPreviewAt[MAX_PLAYERS + 1];

// ============================================================
// Lifecycle
// ============================================================
public plugin_natives()
{
	register_library("winterfest_cosmetics")
	register_native("wfcos_count", "native_count")
	register_native("wfcos_find", "native_find")
	register_native("wfcos_owned", "native_owned")
	register_native("wfcos_grant_id", "native_grant_id")
	register_native("wfcos_equip_slot", "native_equip_slot")
	register_native("wfcos_equipped", "native_equipped")
	register_native("wfcos_title_of", "native_title_of")
	register_native("wfcos_enabled", "native_enabled")
	set_native_filter("WfcosFilter")
}

public WfcosFilter(const name[], index, trap)
{
	if (trap)
		return PLUGIN_CONTINUE
	if (contain(name, "wf_") == 0 && !LibraryExists("winterfest_core", LibType_Library))
		return PLUGIN_HANDLED
	if (contain(name, "fncosmetics_") == 0 && !LibraryExists("freenova_cosmetics", LibType_Library))
		return PLUGIN_HANDLED
	if (contain(name, "fnpref_") == 0 && !LibraryExists("freenova_prefs", LibType_Library))
		return PLUGIN_HANDLED
	return PLUGIN_CONTINUE
}

public plugin_precache()
{
	g_pOn = register_cvar("wf_cosmetics", "1")
	g_pHeavy = register_cvar("wf_cosmetics_heavy", "0")
	g_pName = register_cvar("wf_cosmetics_name", "1")
	g_pChat = register_cvar("wf_cosmetics_chat", "1")
	// Effects. The defaults are the ones docs/WINTERFEST-COSMETICS.md sec 10.4
	// measures: at most 12 live effect entities on the whole server, 2 per
	// player, and a player in Low Performance Mode gets a chat line instead.
	g_pFx = register_cvar("wf_fx", "1")
	g_pFxEnts = register_cvar("wf_fx_entmax", "12")
	g_pFxEntsP = register_cvar("wf_fx_entmax_p", "2")
	g_pFxVerb = register_cvar("wf_fx_verb", "1")
	g_pFxLpm = register_cvar("wf_fx_lpm", "1")
	g_pFxDebug = register_cvar("wf_fx_debug", "0")
	g_pFxSheet = register_cvar("wf_fx_sheet", "1")
	if (get_pcvar_num(g_pOn))
		WfcosRegistry()
}

public plugin_init()
{
	register_plugin(PLUGIN, VERSION, AUTHOR)
	register_clcmd("say /wfcos", "cmdChat")
	register_clcmd("say_team /wfcos", "cmdChat")
	register_clcmd("say /cospreview", "cmdPreview")
	register_clcmd("say_team /cospreview", "cmdPreview")
	register_concmd("wf_cosmetics_check", "cmdCheck", ADMIN_CFG, "- every cosmetic, its size here, what is precached")
	register_concmd("wf_cosmetics_reload", "cmdReload", ADMIN_CFG, "- re-read cosmetics.ini")
	register_concmd("wf_cosmetics_give", "cmdGive", ADMIN_CFG, "<target|all> <cosmetic id>")
	register_concmd("wf_cosmetics_fx", "cmdFx", ADMIN_CFG, "<target|all> <effect id> - play an effect now, no kill needed")
	register_concmd("wf_fx_clock", "cmdFxClock", ADMIN_CFG, "- the effect clock and every live slot, for measuring")
	register_concmd("wf_cosmetics_fxinfo", "cmdFxInfo", ADMIN_CFG, "- live effect entities, ceilings, counters")
	RegisterHam(Ham_Spawn, "player", "Hook_PlayerSpawn", 1)
	RegisterHam(Ham_Killed, "player", "Hook_PlayerKilled", 1)
	server_print("[FreeNova winterfest_cosmetics] ready (build 5, %d cosmetic(s), wf_cosmetics=%d heavy=%d wf_fx=%d)",
		g_iCount, get_pcvar_num(g_pOn), get_pcvar_num(g_pHeavy), get_pcvar_num(g_pFx))
}

public plugin_end()
{
	// A map change ends the round for our entities: clear the table rather than
	// leaving ids behind that the next map would reuse.
	WfcosFxClearAll()
	remove_task(TASK_FX_REAP)
	remove_task(TASK_FX_SPAWN)
}

public client_putinserver(id)
{
	if (!is_user_connected(id) || is_user_bot(id) || is_user_hltv(id))
		return

	g_bLoadedP[id] = false
	g_bPrefixed[id] = false
	g_bTaged[id] = false
	g_iHat[id] = 0
	g_iPending[id] = 0
	g_iTries[id] = 0
	g_iEquip[id][WFCOS_SLOT_HAT] = 0
	g_iEquip[id][WFCOS_SLOT_TITLE] = 0
	g_iEquip[id][WFCOS_SLOT_KILL] = 0
	g_iEquip[id][WFCOS_SLOT_DEATH] = 0
	g_iEquip[id][WFCOS_SLOT_SPAWN] = 0
	g_iOwned[id][0] = 0
	g_iOwned[id][1] = 0
	g_iPreviewAt[id] = 0
	g_iFxPerPlayer[id] = 0
	get_user_name(id, g_szBase[id], charsmax(g_szBase[]))

	if (!get_pcvar_num(g_pOn))
		return
	WfcosLoad(id)
	if (!g_bLoadedP[id])
		set_task(3.0, "Task_Late", id + TASK_LATE)
}

public Task_Late(taskid)
{
	new id = taskid - TASK_LATE
	if (!WfcosInRange(id) || !is_user_connected(id) || is_user_bot(id) || is_user_hltv(id))
		return
	if (!get_pcvar_num(g_pOn) || g_bLoadedP[id] || g_iTries[id] >= 3)
		return
	g_iTries[id]++
	WfcosLoad(id)
	if (!g_bLoadedP[id])
		set_task(3.0, "Task_Late", id + TASK_LATE)
}

public client_disconnected(id)
{
	if (!WfcosInRange(id))
		return
	remove_task(id + TASK_LATE)
	remove_task(id + TASK_FX_SPAWN)
	WfcosHatOff(id)
	g_bLoadedP[id] = false
	g_iPreviewAt[id] = 0
}

public Hook_PlayerSpawn(id)
{
	if (!get_pcvar_num(g_pOn) || !WfcosInRange(id))
		return
	if (!g_bLoadedP[id])
		WfcosLoad(id)
	WfcosApply(id)
	// The spawn flourish waits out the first instant of the round (the engine
	// still has the player at the spawn point, buy menu open): half a second in,
	// nothing it draws can hide a first shot, and it is gone before the fight
	// starts. One task per spawn, not a loop.
	remove_task(id + TASK_FX_SPAWN)
	if (g_iEquip[id][WFCOS_SLOT_SPAWN] > 0)
		set_task(WFCOS_FX_SPAWN_DELAY, "Task_FxSpawn", id + TASK_FX_SPAWN)
}

public Task_FxSpawn(taskid)
{
	new id = taskid - TASK_FX_SPAWN
	if (!WfcosInRange(id) || !is_user_alive(id))
		return
	WfcosFxPlay(id, g_iEquip[id][WFCOS_SLOT_SPAWN], WFCOS_SLOT_SPAWN, 0)
}

public Hook_PlayerKilled(victim, attacker, shouldgib)
{
	#pragma unused shouldgib
	WfcosHatOff(victim)
	remove_task(victim + TASK_FX_SPAWN)

	// Two effects, two owners, two moments: the killer's kill effect is what the
	// corpse produces, and the dying player's death effect is what they leave.
	// A suicide or a world kill has no attacker to ask.
	if (attacker >= 1 && attacker <= MaxClients && attacker != victim && is_user_connected(attacker))
		WfcosFxPlay(attacker, g_iEquip[attacker][WFCOS_SLOT_KILL], WFCOS_SLOT_KILL, victim)
	WfcosFxPlay(victim, g_iEquip[victim][WFCOS_SLOT_DEATH], WFCOS_SLOT_DEATH, 0)
}

// ============================================================
// Registry
// ============================================================
WfcosRegistry()
{
	g_iCount = 0
	g_iPreBytes = 0
	g_bLoaded = false
	// A reload can reorder rows, and a stale model index would point at whatever
	// the engine holds for somebody else. The sprites are precached once per map
	// (plugin_precache), so after a reload g_iFxModel stays 0 until a changelevel
	// - the same rule hats already follow.
	for (new r = 0; r <= WFCOS_MAX; r++)
	{
		g_iFxModel[r] = 0
		g_iFxSheetModel[r] = 0
		g_iFxSheetFrames[r] = 0
	}

	new path[160], cfgdir[96]
	get_configsdir(cfgdir, charsmax(cfgdir))
	formatex(path, charsmax(path), "%s/%s", cfgdir, REGISTRY_FILE)

	new fp = fopen(path, "rt")
	if (!fp)
	{
		log_amx("[WF-COS] %s missing or unreadable - the registry is empty", path)
		return
	}

	new line[320], section[24], f[10][WFCOS_ASSET_LEN]
	// Default to the cosmetic section: a row that is not under any header is a
	// cosmetic, so deleting the [cosmetic] line (or pasting rows above it) cannot
	// silently load an empty registry. The header still wins when it is there.
	copy(section, charsmax(section), "cosmetic")
	new heavy = get_pcvar_num(g_pHeavy)

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
			strtolower(section)
			continue
		}
		if (!equal(section, "cosmetic"))
			continue
		if (g_iCount >= WFCOS_MAX)
		{
			log_amx("[WF-COS] registry full (%d) - row refused", WFCOS_MAX)
			break
		}

		new i
		for (i = 0; i < 10; i++)
			WfField(line, i, f[i], charsmax(f[]))
		if (!f[0][0] || !f[2][0])
		{
			log_amx("[WF-COS] row without an id or a kind - refused")
			continue
		}

		new kind = WfcosKindFromName(f[2])
		if (kind == WFCOS_KIND_UNKNOWN)
		{
			log_amx("[WF-COS] %s: unknown kind '%s' - row refused", f[0], f[2])
			continue
		}

		new dup = 0
		for (i = 1; i <= g_iCount; i++)
			if (equali(g_szId[i], f[0]))
				dup = 1
		if (dup)
		{
			log_amx("[WF-COS] %s: duplicate id - row refused", f[0])
			continue
		}

		g_iCount++
		new idx = g_iCount
		copy(g_szId[idx], charsmax(g_szId[]), f[0])
		copy(g_szName[idx], charsmax(g_szName[]), f[1][0] ? f[1] : f[0])
		copy(g_szText[idx], charsmax(g_szText[]), f[9])
		copy(g_szAsset[idx], charsmax(g_szAsset[]), f[8])
		g_iKind[idx] = kind
		g_iWeight[idx] = WfcosWeightFromName(f[3])
		g_iDeclared[idx] = str_to_num(f[4])
		g_iSrc[idx] = WfcosSourceFromName(f[6], g_iSrcVal[idx])
		if (str_to_num(f[7]) > 0 && g_szAsset[idx][0])
			g_iFlags[idx] |= F_DL

		// assets: every named file has to be here, or nothing is served
		new p[96], present = 1, k
		for (k = 0; k < WFCOS_MAX_PATHS; k++)
		{
			if (!WfcosPathAt(g_szAsset[idx], k, p, charsmax(p)))
				break
			if (!file_exists(p))
				present = 0
		}
		if (present)
			g_iFlags[idx] |= F_OK
		else if (g_iFlags[idx] & F_DL)
			log_amx("[WF-COS] %s: a named file is not on this host - never precached nor served", g_szId[idx])

		// Precache policy: small rows now, medium/heavy only with the heavy gate,
		// and never a `skin` row (weapon models are weapon_models.sma's).
		if (!(g_iFlags[idx] & F_DL) || !(g_iFlags[idx] & F_OK) || kind == WFCOS_KIND_SKIN)
			continue
		if (g_iWeight[idx] != WFCOS_W_SMALL && !heavy)
			continue
		for (k = 0; k < WFCOS_MAX_PATHS; k++)
		{
			if (!WfcosPathAt(g_szAsset[idx], k, p, charsmax(p)))
				break
			if (WfcosKindIsFx(kind))
			{
				// An effect needs TWO things and both come from precache:
				//   a .spr -> its model index, for TE_SPRITE / TE_SPRITETRAIL
				//             (no index, no message layer), so keep what
				//             precache_model returns instead of throwing it away
				//   a .mdl -> the model must be in this map's table or
				//             EngFunc_SetModel raises "no precache" and takes the
				//             MAP DOWN (found the hard way: Host_Error PF_setmodel_I)
				// A second path on an effect row is a sound or nothing: only the
				// first visual file above is used by the effect itself.
				if (WfcosIsSprite(p))
				{
					new spr = precache_model(p)
					new frames = WfcosSheetFrames(p)
					// Unconditional and once per boot: if a sheet ever stops being
					// recognised, this line is the first thing to look at.
					log_amx("[WF-COS] %s: sprite %d, sheet frames %d", p, spr, frames)
					if (frames > 0)
					{
						// A packed sheet wins: one model, every frame, no trail trick.
						if (!g_iFxSheetModel[idx])
						{
							g_iFxSheetModel[idx] = spr
							g_iFxSheetFrames[idx] = frames
						}
					}
					else if (!g_iFxModel[idx])
						g_iFxModel[idx] = spr
				}
				else if (WfcosIsModel(p))
					precache_model(p)
				else
					precache_generic(p)
			}
			else if (WfcosIsModel(p))
				precache_model(p)
			else
				precache_generic(p)
		}
		g_iFlags[idx] |= F_PRE
		g_iPreBytes += WfcosHostBytes(idx)
	}
	fclose(fp)

	g_bLoaded = true
	log_amx("[WF-COS] registry: %d cosmetic(s), %d precached, %d bytes (%s)", g_iCount, WfcosPrecCount(), g_iPreBytes, path)
}

WfcosKindFromName(const name[])
{
	if (equali(name, "hat"))
		return WFCOS_KIND_HAT
	if (equali(name, "skin"))
		return WFCOS_KIND_SKIN
	if (equali(name, "model"))
		return WFCOS_KIND_MODEL
	if (equali(name, "title"))
		return WFCOS_KIND_TITLE
	if (equali(name, "badge"))
		return WFCOS_KIND_BADGE
	if (equali(name, "effect"))
		return WFCOS_KIND_EFFECT
	if (equali(name, "kill"))
		return WFCOS_KIND_KILL
	if (equali(name, "death"))
		return WFCOS_KIND_DEATH
	if (equali(name, "spawn"))
		return WFCOS_KIND_SPAWN
	return WFCOS_KIND_UNKNOWN
}

WfcosWeightFromName(const name[])
{
	if (equali(name, "small"))
		return WFCOS_W_SMALL
	if (equali(name, "heavy"))
		return WFCOS_W_HEAVY
	return WFCOS_W_MEDIUM
}

WfcosLabel(kind, idx, out[], len)
{
	// kind: 1 = cosmetic kind, 2 = weight, 3 = source. One function because the
	// compiler this tree ships is happier with fewer bodies than with shinier ones.
	if (kind == 1)
	{
		switch (idx)
		{
			case WFCOS_KIND_HAT:    copy(out, len, "hat")
			case WFCOS_KIND_SKIN:   copy(out, len, "skin")
			case WFCOS_KIND_MODEL:  copy(out, len, "model")
			case WFCOS_KIND_TITLE:  copy(out, len, "title")
			case WFCOS_KIND_BADGE:  copy(out, len, "badge")
			case WFCOS_KIND_EFFECT: copy(out, len, "effect")
			case WFCOS_KIND_KILL:   copy(out, len, "kill")
			case WFCOS_KIND_DEATH:  copy(out, len, "death")
			case WFCOS_KIND_SPAWN:  copy(out, len, "spawn")
			default:                copy(out, len, "?")
		}
		return
	}
	if (kind == 2)
	{
		switch (idx)
		{
			case WFCOS_W_SMALL: copy(out, len, "small")
			case WFCOS_W_HEAVY: copy(out, len, "heavy")
			default:            copy(out, len, "medium")
		}
		return
	}
	switch (idx)
	{
		case WFCOS_SRC_GIFT:   copy(out, len, "a present")
		case WFCOS_SRC_ADVENT: formatex(out, len, "advent day %d", g_iSrcVal[idx])
		case WFCOS_SRC_PASS:   formatex(out, len, "pass tier %d", g_iSrcVal[idx])
		case WFCOS_SRC_TREE:   formatex(out, len, "tree level %d", g_iSrcVal[idx])
		case WFCOS_SRC_SECRET: formatex(out, len, "ornament set %d", g_iSrcVal[idx])
		default:               copy(out, len, "not awarded yet")
	}
}

WfcosSourceFromName(const name[], &value)
{
	value = 0
	new buf[24]
	copy(buf, charsmax(buf), name)
	trim(buf)
	new colon = contain(buf, ":")
	if (colon >= 0)
	{
		value = str_to_num(buf[colon + 1])
		buf[colon] = 0
		trim(buf)
	}
	if (equali(buf, "gift"))
		return WFCOS_SRC_GIFT
	if (equali(buf, "advent") && value > 0)
		return WFCOS_SRC_ADVENT
	if (equali(buf, "pass") && value > 0)
		return WFCOS_SRC_PASS
	if (equali(buf, "tree") && value > 0)
		return WFCOS_SRC_TREE
	if ((equali(buf, "secret") || equali(buf, "set")) && value > 0)
		return WFCOS_SRC_SECRET
	value = 0
	return WFCOS_SRC_NONE
}

// ============================================================
// Assets
// ============================================================
stock bool:WfcosPathAt(const list[], index, out[], len)
{
	out[0] = 0
	new n = strlen(list), start = 0, cur = 0
	for (new i = 0; i <= n; i++)
	{
		if (i < n && list[i] != ',')
			continue
		if (cur == index)
		{
			new s = start, e = i
			// '^t' is the Pawn control-character escape. Do NOT write a
			// backslash escape here: amxxpc 1.10.0.5467 reads "\t" as a
			// literal backslash plus 't' ("error 027: invalid character
			// constant" + "undefined symbol t"), and inside a nested
			// &&/|| expression that recovery path dies with
			// std::bad_alloc instead of reporting anything.
			while (s < e && (list[s] == ' ' || list[s] == '^t'))
				s++
			while (e > s && (list[e - 1] == ' ' || list[e - 1] == '^t'))
				e--
			new c = e - s
			if (c > len - 1)
				c = len - 1
			for (new k = 0; k < c; k++)
				out[k] = list[s + k]
			out[c] = 0
			return out[0] ? true : false
		}
		cur++
		start = i + 1
	}
	return false
}

stock bool:WfcosIsModel(const path[])
{
	new n = strlen(path)
	if (n > 4 && (equali(path[n - 4], ".mdl") || equali(path[n - 4], ".spr")))
		return true
	return false
}

stock bool:WfcosIsSprite(const path[])
{
	new n = strlen(path)
	return (n > 4 && equali(path[n - 4], ".spr")) ? true : false
}

stock bool:WfcosKindIsFx(kind)
{
	return (kind == WFCOS_KIND_KILL || kind == WFCOS_KIND_DEATH || kind == WFCOS_KIND_SPAWN) ? true : false
}

WfcosHostBytes(idx)
{
	new path[96], total = 0, k
	for (k = 0; k < WFCOS_MAX_PATHS; k++)
	{
		if (!WfcosPathAt(g_szAsset[idx], k, path, charsmax(path)))
			break
		if (file_size(path) > 0)
			total += file_size(path)
	}
	return total
}

WfcosPrecCount()
{
	new n = 0, i
	for (i = 1; i <= g_iCount; i++)
		if (g_iFlags[i] & F_PRE)
			n++
	return n
}

// ============================================================
// Entitlement / equip slots
// ============================================================
bool:WfcosOwned(id, idx)
{
	if (!WfcosInRange(id) || idx < 1 || idx > g_iCount)
		return false
	switch (g_iSrc[idx])
	{
		case WFCOS_SRC_SECRET: return wf_set_owned(id, g_iSrcVal[idx]) ? true : false
		case WFCOS_SRC_PASS:   return (wf_pass_tier(id) >= g_iSrcVal[idx]) ? true : false
		case WFCOS_SRC_TREE:   return (wf_tree_level(id) >= g_iSrcVal[idx]) ? true : false
		case WFCOS_SRC_ADVENT: return wf_advent_claimed(id, g_iSrcVal[idx]) ? true : false
	}
	if (!g_bLoadedP[id])
		return false
	return (g_iOwned[id][idx >> 5] & (1 << (idx & 31))) ? true : false
}

bool:WfcosRecorded(idx)
{
	return (g_iSrc[idx] == WFCOS_SRC_GIFT || g_iSrc[idx] == WFCOS_SRC_NONE) ? true : false
}

WfcosSlotOf(idx)
{
	if (idx < 1 || idx > g_iCount)
		return WFCOS_SLOT_NONE
	if (g_iKind[idx] == WFCOS_KIND_HAT)
		return WFCOS_SLOT_HAT
	if (g_iKind[idx] == WFCOS_KIND_TITLE || g_iKind[idx] == WFCOS_KIND_BADGE)
		return WFCOS_SLOT_TITLE
	if (g_iKind[idx] == WFCOS_KIND_KILL)
		return WFCOS_SLOT_KILL
	if (g_iKind[idx] == WFCOS_KIND_DEATH)
		return WFCOS_SLOT_DEATH
	if (g_iKind[idx] == WFCOS_KIND_SPAWN)
		return WFCOS_SLOT_SPAWN
	return WFCOS_SLOT_NONE
}

// Set membership, not a payout: OK once, DUPLICATE after, DERIVED when the core
// is the score.
WfcosGrant(id, idx)
{
	if (idx < 1 || idx > g_iCount)
		return WFCOS_INVALID
	if (!g_bLoadedP[id])
		return WFCOS_NOTLOADED
	if (!WfcosRecorded(idx))
		return WFCOS_DERIVED
	if (WfcosOwned(id, idx))
		return WFCOS_DUPLICATE
	g_iOwned[id][idx >> 5] |= (1 << (idx & 31))
	WfcosSave(id)
	log_amx("[WF-COS] id %d now owns %s", id, g_szId[idx])
	return WFCOS_OK
}

WfcosEquipSlot(id, slot, idx)
{
	if (slot < 1 || slot > WFCOS_MAX_SLOTS || idx < 0 || idx > g_iCount)
		return WFCOS_INVALID
	if (!g_bLoadedP[id])
		return WFCOS_NOTLOADED
	if (idx > 0 && (WfcosSlotOf(idx) != slot || !WfcosOwned(id, idx)))
		return WFCOS_INVALID
	g_iEquip[id][slot] = idx
	WfcosSave(id)
	WfcosApply(id)
	return WFCOS_OK
}

// ============================================================
// Per-player file: owned = a,b  /  hat = id  /  title = id
// ============================================================
WfcosFile(id, out[], len)
{
	new dir[128], auth[40]
	get_datadir(dir, charsmax(dir))
	add(dir, charsmax(dir), "/")
	add(dir, charsmax(dir), PLAYER_DIR)
	if (!dir_exists(dir))
		mkdir(dir)
	get_user_authid(id, auth, charsmax(auth))
	new w = 0
	new safe[40]
	for (new i = 0; auth[i] && w < charsmax(safe); i++)
	{
		new c = auth[i]
		if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9'))
			safe[w++] = c
		else
			safe[w++] = '_'
	}
	safe[w] = 0
	formatex(out, len, "%s/%s.txt", dir, safe)
}

bool:WfcosAuthOk(id)
{
	new auth[40]
	get_user_authid(id, auth, charsmax(auth))
	if (!auth[0] || equal(auth, "BOT") || equal(auth, "HLTV") || equal(auth, "UNKNOWN") || equal(auth, "LAN"))
		return false
	if (equal(auth, "STEAM_ID_PENDING") || equal(auth, "STEAM_ID_LAN") || equal(auth, "STEAM_ID_UNKNOWN"))
		return false
	return true
}

WfcosLoad(id)
{
	if (!WfcosInRange(id) || is_user_bot(id) || is_user_hltv(id) || !WfcosAuthOk(id))
		return

	g_iOwned[id][0] = 0
	g_iOwned[id][1] = 0
	g_iEquip[id][WFCOS_SLOT_HAT] = 0
	g_iEquip[id][WFCOS_SLOT_TITLE] = 0

	new path[192]
	WfcosFile(id, path, charsmax(path))
	if (!file_exists(path))
	{
		g_bLoadedP[id] = true
		return
	}

	new fp = fopen(path, "rt")
	if (!fp)
	{
		log_amx("[WF-COS] %s unreadable for id %d", path, id)
		return
	}

	new line[320], key[16], val[256], eq
	while (fgets(fp, line, charsmax(line)))
	{
		trim(line)
		if (!line[0] || line[0] == ';' || line[0] == '#')
			continue
		eq = contain(line, "=")
		if (eq <= 0)
			continue
		copy(key, charsmax(key), line)
		key[eq] = 0
		trim(key)
		strtolower(key)
		copy(val, charsmax(val), line[eq + 1])
		trim(val)

		if (equal(key, "owned"))
		{
			// comma list of ids -> bits
			new n = strlen(val), start = 0
			for (new i = 0; i <= n; i++)
			{
				if (i < n && val[i] != ',')
					continue
				new buf[WFCOS_ID_LEN], s = start, e = i, idx
				while (s < e && val[s] == ' ')
					s++
				while (e > s && val[e - 1] == ' ')
					e--
				new c = e - s
				if (c > 0 && c < charsmax(buf))
				{
					for (new k = 0; k < c; k++)
						buf[k] = val[s + k]
					buf[c] = 0
					idx = WfcosFind(buf)
					if (idx > 0)
						g_iOwned[id][idx >> 5] |= (1 << (idx & 31))
					else
						log_amx("[WF-COS] id %d: '%s' not in the registry - ignored", id, buf)
				}
				start = i + 1
			}
		}
		else if (equal(key, "hat") || equal(key, "title"))
		{
			new slot = equal(key, "hat") ? WFCOS_SLOT_HAT : WFCOS_SLOT_TITLE
			new idx = WfcosFind(val)
			if (idx > 0 && WfcosSlotOf(idx) == slot)
				g_iEquip[id][slot] = idx
		}
	}
	fclose(fp)
	g_bLoadedP[id] = true
}

WfcosSave(id)
{
	if (!WfcosInRange(id) || !g_bLoadedP[id] || is_user_bot(id) || is_user_hltv(id) || !WfcosAuthOk(id))
		return

	new path[192]
	WfcosFile(id, path, charsmax(path))
	new fp = fopen(path, "wt")
	if (!fp)
	{
		log_amx("[WF-COS] %s not writable for id %d - not saved", path, id)
		return
	}

	new line[512], buf[64], first = 1, idx
	formatex(line, charsmax(line), "owned = ")
	for (idx = 1; idx <= g_iCount; idx++)
	{
		if (!WfcosRecorded(idx) || !WfcosOwned(id, idx))
			continue
		if (!first)
			add(line, charsmax(line), ",")
		add(line, charsmax(line), g_szId[idx])
		first = 0
	}
	fprintf(fp, "%s^n", line)

	new hat = g_iEquip[id][WFCOS_SLOT_HAT]
	new title = g_iEquip[id][WFCOS_SLOT_TITLE]
	formatex(buf, charsmax(buf), "hat = %s", (hat >= 1 && hat <= g_iCount) ? g_szId[hat] : "")
	fprintf(fp, "%s^n", buf)
	formatex(buf, charsmax(buf), "title = %s", (title >= 1 && title <= g_iCount) ? g_szId[title] : "")
	fprintf(fp, "%s^n", buf)
	fclose(fp)
}

// ============================================================
// What a player wears
// ============================================================
WfcosHatOff(id)
{
	if (!WfcosInRange(id))
		return
	if (g_iHat[id] > 0 && pev_valid(g_iHat[id]))
		engfunc(EngFunc_RemoveEntity, g_iHat[id])
	g_iHat[id] = 0
}

// A title sourced from an ornament set is named in winterfest.ini [set]; the
// core's copy wins when the core is loaded, the registry text is the fallback.
WfcosWornTitle(id, out[], len)
{
	out[0] = 0
	if (!WfcosInRange(id))
		return
	new idx = g_iEquip[id][WFCOS_SLOT_TITLE]
	if (idx < 1 || idx > g_iCount || !WfcosOwned(id, idx))
		return
	if (g_iSrc[idx] == WFCOS_SRC_SECRET && LibraryExists("winterfest_core", LibType_Library))
	{
		new core[WFCOS_TEXT_LEN]
		wf_set_title(g_iSrcVal[idx], core, charsmax(core))
		if (core[0])
		{
			formatex(out, len, "[%s]", core)
			return
		}
	}
	copy(out, len, g_szText[idx])
}

WfcosApply(id)
{
	if (!WfcosInRange(id) || is_user_bot(id) || is_user_hltv(id) || !is_user_connected(id))
		return

	new text[WFCOS_TEXT_LEN], msg[128]
	WfcosWornTitle(id, text, charsmax(text))

	// The hat: MOVETYPE_FOLLOW + aiment, so the engine moves it - no per-frame
	// task, and the models are authored with their geometry at head height.
	WfcosHatOff(id)
	new idx = g_iEquip[id][WFCOS_SLOT_HAT]
	if (is_user_alive(id) && idx >= 1 && idx <= g_iCount && (g_iFlags[idx] & F_PRE) && WfcosOwned(id, idx))
	{
		new model[96]
		if (WfcosPathAt(g_szAsset[idx], 0, model, charsmax(model)) && file_exists(model))
		{
			new ent = create_entity("info_target")
			if (ent)
			{
				set_pev(ent, pev_classname, HAT_CLASS)
				engfunc(EngFunc_SetModel, ent, model)
				set_pev(ent, pev_movetype, MOVETYPE_FOLLOW)
				set_pev(ent, pev_solid, SOLID_NOT)
				set_pev(ent, pev_aiment, id)
				set_pev(ent, pev_owner, id)
				g_iHat[id] = ent
			}
		}
	}

	// The name: the surface fn_scan.sma already uses for text next to a player.
	if (text[0] && get_pcvar_num(g_pName) && strlen(text) + 1 + strlen(g_szBase[id]) <= MAX_NAME_LENGTH - 1)
	{
		formatex(msg, charsmax(msg), "%s %s", text, g_szBase[id])
		set_user_info(id, "name", msg)
		g_bPrefixed[id] = true
	}
	else if (g_bPrefixed[id])
	{
		g_bPrefixed[id] = false
		if (g_szBase[id][0])
			set_user_info(id, "name", g_szBase[id])
	}

	// The chat tag: freenova_cosmetics' own slot, only if licensed and EMPTY.
	if (!LibraryExists("freenova_cosmetics", LibType_Library))
		return
	if (!text[0] || !get_pcvar_num(g_pChat))
	{
		if (g_bTaged[id])
		{
			fncosmetics_clear_tag(id)
			g_bTaged[id] = false
		}
		return
	}
	if (!fncosmetics_has_tag_license(id))
		return
	if (!g_bTaged[id])
	{
		new cur[32]
		fncosmetics_get_tag(id, cur, charsmax(cur))
		trim(cur)
		if (cur[0])
			return
	}
	if (fncosmetics_set_tag(id, text))
		g_bTaged[id] = true
}

// ============================================================
// Effects: kill / death / spawn
// ============================================================
// One effect = one animated sprite entity + a message-only layer that the
// engine draws without any entity at all. That split is the whole performance
// argument (docs/WINTERFEST-COSMETICS.md sec 10.4):
//
//   * the message layer is TE_SPRITETRAIL / TE_ELIGHT / TE_SPRITE with the
//     sprite we precached. Zero entities, zero think functions, no server task -
//     one unreliable tempentity message per layer, sent MSG_PVS so only clients
//     that could see the spot get it.
//   * the entity layer is ONE env_sprite whose animation the engine advances
//     itself (pev_framerate), so this plugin never runs a per-frame loop. It is
//     the only thing the ceilings count, and it is reaped by a 4 Hz table scan.
//   * a ceiling hit, a missing sprite or a player in Low Performance Mode drops
//     the entity layer and keeps the message layer, so an effect is never "all
//     or nothing" on a weak box.
//
// Nothing here is per-frame: the reaper is one 0.25 s task that exists only
// while something is alive.

// Which grammar the extra layers use. Keyed on the sprite the row names, so a
// new row with our wf_*.spr files gets the right colours for free; anything
// unknown falls back to the snow grammar rather than inventing a look.
stock WfcosFxLook(idx)
{
	new asset[96]
	WfcosPathAt(g_szAsset[idx], 0, asset, charsmax(asset))
	if (containi(asset, "bauble") >= 0)
		return WFCOS_LOOK_BAUBLE
	if (containi(asset, "gift") >= 0)
		return WFCOS_LOOK_GIFT
	if (containi(asset, "iceshard") >= 0 || containi(asset, "ice") >= 0)
		return WFCOS_LOOK_ICE
	if (containi(asset, "angel") >= 0)
		return WFCOS_LOOK_ANGEL
	if (containi(asset, "ring") >= 0)
		return WFCOS_LOOK_RING
	return WFCOS_LOOK_SNOW
}

// Is the effect machinery allowed to draw anything for this player?
//   id 0 = "the server asks", which only the master switch can refuse.
// The LPM answer comes from freenova_prefs through its own native, never from a
// vault file: an absent plugin means "no preference", not "assume low".
stock bool:WfcosFxOn(id)
{
	if (!get_pcvar_num(g_pOn) || !get_pcvar_num(g_pFx))
		return false
	// A player can also opt out for themselves: "my machine, never decorate me".
	// Kept separate from Low Performance Mode because it is a taste, not a
	// capability - an LPM player gets the chat line, a self-muted one gets silence.
	if (id >= 1 && id <= MaxClients && g_bFxQuiet[id])
		return false
	if (id < 1 || id > MaxClients)
		return true
	if (!get_pcvar_num(g_pFxLpm))
		return true
	if (!LibraryExists("freenova_prefs", LibType_Library))
		return true
	if (!fnpref_is_loaded(id))
		return true
	return fnpref_get(id, FNPREF_LOW_PERF) ? false : true
}

// The ceilings. Global first (the server's budget), then per player (one player
// spamming cannot eat the whole budget).
stock bool:WfcosFxRoom(id)
{
	new cap = get_pcvar_num(g_pFxEnts)
	if (cap > WFCOS_FX_LIVE)
		cap = WFCOS_FX_LIVE
	if (cap < 1 || g_iFxLiveUsed >= cap)
		return false
	new capP = get_pcvar_num(g_pFxEntsP)
	if (capP < 1)
		return false
	return (g_iFxPerPlayer[id] >= capP) ? false : true
}

// ============================================================
// The message layer (no entity)
// ============================================================
stock WfcosFxInt(const Float:v[3], out[3])
{
	out[0] = floatround(v[0])
	out[1] = floatround(v[1])
	out[2] = floatround(v[2])
}

// TE_SPRITETRAIL: `count` copies of the sprite stepping through its frames
// between two points. This is the only way to animate a sprite with no entity,
// and it is what winterfest_atmos and reapi_healthnade both use on this tree.
stock WfcosFxTrail(const Float:from[3], const Float:to[3], model, count, life, scale, noise, speed)
{
	if (!model)
		return
	new org[3]
	WfcosFxInt(from, org)
	message_begin(MSG_PVS, SVC_TEMPENTITY, org)
	write_byte(TE_SPRITETRAIL)
	write_coord(floatround(from[0]))
	write_coord(floatround(from[1]))
	write_coord(floatround(from[2]))
	write_coord(floatround(to[0]))
	write_coord(floatround(to[1]))
	write_coord(floatround(to[2]))
	write_short(model)
	write_byte(clamp(count, 1, 255))
	write_byte(clamp(life, 1, 255))
	write_byte(clamp(scale, 1, 255))
	write_byte(clamp(noise, 0, 255))
	write_byte(clamp(speed, 1, 255))
	message_end()
}

// TE_SPRITE: one frame of the sprite, full brightness. Used for the flash at the
// moment of the burst, where the trail's first particle has not arrived yet.
stock WfcosFxFlash(const Float:origin[3], model, scale, brightness)
{
	if (!model)
		return
	new org[3]
	WfcosFxInt(origin, org)
	message_begin(MSG_PVS, SVC_TEMPENTITY, org)
	write_byte(TE_SPRITE)
	write_coord(floatround(origin[0]))
	write_coord(floatround(origin[1]))
	write_coord(floatround(origin[2]))
	write_short(model)
	write_byte(clamp(scale, 1, 255))
	write_byte(clamp(brightness, 1, 255))
	message_end()
}

// TE_ELIGHT: a coloured point light with a life in 0.1 s. Nothing to clean up,
// nothing to track, and it is what makes a dark corner react to the effect.
stock WfcosFxLight(const Float:origin[3], radius, red, green, blue, life)
{
	new org[3]
	WfcosFxInt(origin, org)
	message_begin(MSG_PVS, SVC_TEMPENTITY, org)
	write_byte(TE_ELIGHT)
	write_short(0)
	write_coord(floatround(origin[0]))
	write_coord(floatround(origin[1]))
	write_coord(floatround(origin[2]))
	write_coord(clamp(radius, 1, 8192) * 10)
	write_byte(clamp(red, 0, 255))
	write_byte(clamp(green, 0, 255))
	write_byte(clamp(blue, 0, 255))
	write_byte(clamp(life, 1, 255))
	write_coord(0)
	message_end()
}

// TE_SPARKS: the engine's own shower at a point. Free (no sprite, no entity) and
// it sells "something broke" better than a still.
stock WfcosFxSparks(const Float:origin[3])
{
	new org[3]
	WfcosFxInt(origin, org)
	message_begin(MSG_PVS, SVC_TEMPENTITY, org)
	write_byte(TE_SPARKS)
	write_coord(floatround(origin[0]))
	write_coord(floatround(origin[1]))
	write_coord(floatround(origin[2]))
	message_end()
}

// The message-only layer, one grammar per look. Everything here is bounded: at
// most four messages per effect.
stock WfcosFxMessages(const Float:origin[3], idx, model, slot)
{
	new Float:up[3]
	up[0] = origin[0]
	up[1] = origin[1]
	up[2] = origin[2] + 46.0

	switch (WfcosFxLook(idx))
	{
		case WFCOS_LOOK_BAUBLE:
		{
			WfcosFxTrail(origin, up, model, 6, 9, 7, 4, 8)
			WfcosFxSparks(origin)
			WfcosFxLight(origin, 150, 210, 60, 40, 14)
		}
		case WFCOS_LOOK_GIFT:
		{
			WfcosFxTrail(origin, up, model, 5, 11, 8, 5, 6)
			WfcosFxLight(origin, 170, 250, 200, 90, 16)
		}
		case WFCOS_LOOK_ICE:
		{
			WfcosFxTrail(origin, up, model, 7, 8, 6, 2, 10)
			WfcosFxSparks(origin)
			WfcosFxLight(origin, 180, 190, 230, 255, 10)
		}
		case WFCOS_LOOK_ANGEL:
		{
			// a wide, slow drift about knee height: an imprint settling, not a burst
			up[2] = origin[2] + 14.0
			WfcosFxTrail(origin, up, model, 4, 18, 9, 6, 3)
			WfcosFxLight(origin, 110, 170, 210, 255, 20)
		}
		case WFCOS_LOOK_RING:
		{
			// the ring sprite already draws the ring; the message layer is the
			// flash inside it, and the spawn slot wants none of the punch a kill does
			if (slot == WFCOS_SLOT_SPAWN)
			{
				WfcosFxLight(origin, 120, 150, 255, 190, 8)
			}
			else
			{
				WfcosFxTrail(origin, up, model, 5, 10, 7, 3, 7)
				WfcosFxLight(origin, 150, 160, 255, 200, 12)
			}
		}
		default:
		{
			WfcosFxTrail(origin, up, model, 6, 9, 7, 5, 7)
			WfcosFxLight(origin, 140, 180, 220, 255, 12)
		}
	}
}

// ============================================================
// The entity layer (one sprite, engine-animated, capped, reaped)
// ============================================================
stock WfcosFxDrop(ent, owner, Float:life)
{
	if (ent <= 0)
		return
	if (g_iFxLiveUsed >= WFCOS_FX_LIVE)
	{
		// The table is full (it should never be: the ceiling is clamped to it).
		// Kill the sprite rather than leaking an untracked entity.
		set_pev(ent, pev_flags, pev(ent, pev_flags) | FL_KILLME)
		return
	}
	for (new i = 0; i < WFCOS_FX_LIVE; i++)
	{
		if (g_iFxLiveEnt[i])
			continue
		g_iFxLiveEnt[i] = ent
		g_fFxLiveEnd[i] = get_gametime() + life
		g_iFxLiveOwner[i] = owner
		g_iFxLiveUsed++
		if (owner >= 1 && owner <= MaxClients)
			g_iFxPerPlayer[owner]++
		// One-shot, not a repeating task. A repeating `set_task` in AMXX is
		// re-armed by an internal timer that does not survive a map change
		// cleanly, and while `g_bFxReaping` stayed true nothing ever started it
		// again: the first effects after a map change were dropped by the reaper
		// and, worse, the watchdogs that end a task never ran. Chaining one-shots
		// makes the "is the reaper alive" flag and the task impossible to desync.
		if (!g_bFxReaping)
		{
			g_bFxReaping = true
			set_task(WFCOS_FX_REAP_SECS, "Task_FxReap", TASK_FX_REAP)
		}
		return
	}
}

public Task_FxReap(taskid)
{
	#pragma unused taskid
	new alive = 0
	for (new i = 0; i < WFCOS_FX_LIVE; i++)
	{
		if (g_iFxLiveEnt[i] && WfcosFxExpire(i))
			alive++
	}
	if (alive)
	{
		// chain the next tick: the task ends and the flag clears together
		set_task(WFCOS_FX_REAP_SECS, "Task_FxReap", TASK_FX_REAP)
	}
	else
		g_bFxReaping = false
}

// One slot of the reaper. Returns true while the slot still holds a live entity,
// false once it has been freed (the caller counts the survivors).
stock bool:WfcosFxExpire(i)
{
	if (get_gametime() < g_fFxLiveEnd[i])
		return true
	new ent = g_iFxLiveEnt[i]
	new owner = g_iFxLiveOwner[i]
	g_iFxLiveEnt[i] = 0
	g_iFxLiveOwner[i] = 0
	g_fFxLiveEnd[i] = 0.0
	g_iFxLiveUsed--
	if (owner >= 1 && owner <= MaxClients && g_iFxPerPlayer[owner] > 0)
		g_iFxPerPlayer[owner]--
	// FL_KILLME is the safe removal: the engine drops it at the end of this
	// frame instead of leaving a stale pointer if anything still refers to it.
	if (ent > 0 && pev_valid(ent))
		set_pev(ent, pev_flags, pev(ent, pev_flags) | FL_KILLME)
	return false
}

WfcosFxClearAll()
{
	for (new i = 0; i < WFCOS_FX_LIVE; i++)
	{
		if (g_iFxLiveEnt[i] > 0 && pev_valid(g_iFxLiveEnt[i]))
			set_pev(g_iFxLiveEnt[i], pev_flags, pev(g_iFxLiveEnt[i], pev_flags) | FL_KILLME)
		g_iFxLiveEnt[i] = 0
		g_iFxLiveOwner[i] = 0
		g_fFxLiveEnd[i] = 0.0
	}
	g_iFxLiveUsed = 0
	for (new id = 0; id <= MaxClients; id++)
		g_iFxPerPlayer[id] = 0
}

// Creates the animated sprite (or the world model) for one effect. Returns the
// entity, or 0 when the engine refused one or the ceiling said no (the caller
// counts that as "message layer only").
// `path` is the file the registry names. The engine wants the NAME for the
// entity's model; the precached index only exists for the sprite messages the
// caller sends, so it is not needed here.
stock WfcosFxSprite(id, const Float:origin[3], const path[], Float:scale, Float:fps, Float:life, red, green, blue)
{
	if (!path[0] || !WfcosFxRoom(id))
		return 0

	new bool:is_spr = WfcosIsSprite(path) ? true : false
	new ent = engfunc(EngFunc_CreateNamedEntity, engfunc(EngFunc_AllocString, is_spr ? "env_sprite" : "info_target"))
	if (!ent || !pev_valid(ent))
		return 0

	new Float:rgba[3]
	rgba[0] = float(red)
	rgba[1] = float(green)
	rgba[2] = float(blue)

	engfunc(EngFunc_SetModel, ent, path)
	set_pev(ent, pev_origin, origin)
	set_pev(ent, pev_solid, SOLID_NOT)
	set_pev(ent, pev_movetype, MOVETYPE_NONE)
	set_pev(ent, pev_scale, scale)
	set_pev(ent, pev_rendermode, kRenderGlow)
	set_pev(ent, pev_renderamt, 220.0)
	set_pev(ent, pev_rendercolor, rgba)
	if (is_spr)
	{
		// The engine advances pev_frame itself at this rate; we never tick it.
		set_pev(ent, pev_frame, 0.0)
		set_pev(ent, pev_animtime, 0.0)
		set_pev(ent, pev_framerate, fps)
	}
	dllfunc(DLLFunc_Spawn, ent)

	// Neither an env_sprite nor a decoration is shootable or touchable, but say so
	// out loud: a trace or a grenade must never take our effect for a player.
	set_pev(ent, pev_classname, FX_CLASS)
	WfcosFxDrop(ent, id, life)
	return ent
}

// ============================================================
// The sheet layer (one model, every frame, animated by the engine)
// ============================================================
// How many frames a .spr holds, read from its own header, or 0 when the file is
// not a multi-frame sprite this module can animate with env_sprite.
//
// The rule this encodes: env_sprite animates pev_frame from 0 to the model's own
// frame count when pev_framerate is set, and every frame has to be the same size
// (a sheet). A .spr whose frames differ in size - a TE_SPRITETRAIL sprite, a
// scrolling texture - is NOT a sheet: costs no gfx.wad edit, needs no engine
// change, and a wrong guess would draw a squashed frame instead of an effect.
//
//   header: 4 magic, 4 version, 4 type, 4 texFormat, 4 radius, 4 w, 4 h,
//           4 frames, 4 beamlength, 4 synctype      (40 bytes)
//   v2 adds: 2 palette size, 768 palette, 4 pad; v1 adds 4 pad instead.
//   then `frames` times: 4 origin x, 4 origin y, 4 w, 4 h, w*h bytes (+4 pad
//   between frames). See tools/art/mksprite.py, which writes exactly this.
stock WfcosSheetFrames(const path[])
{
	// AMXX resolves a relative path against its own configs directory, NOT the
	// game directory. `file_size()` and precache both take the cstrike-relative
	// form the registry uses, but fopen() does not: trying it first read zero
	// bytes and the model was silently treated as "not a sheet". Build the
	// absolute path from the game directory and fall back to the raw name (which
	// is what a server started with a cstrike-relative working directory wants).
	// `amxx_configsdir` is absolute and ends in addons/amxmodx/configs, so the
	// game directory is three levels up.
	new full[192], cfg[128], size
	get_localinfo("amxx_configsdir", cfg, charsmax(cfg))
	for (size = strlen(cfg); size > 0 && cfg[size] != '/'; size--) { }
	if (size > 0)
		cfg[size] = 0
	for (size = strlen(cfg); size > 0 && cfg[size] != '/'; size--) { }
	if (size > 0)
		cfg[size] = 0
	for (size = strlen(cfg); size > 0 && cfg[size] != '/'; size--) { }
	if (size > 0)
	{
		cfg[size] = 0
		formatex(full, charsmax(full), "%s/%s", cfg, path)
	}
	else
		copy(full, charsmax(full), path)

	new fp = fopen(full, "rb")
	if (!fp)
		fp = fopen(path, "rb")
	if (!fp)
		return 0
	// fread_blocks returns the number of BLOCKS read, not bytes: 10 words.
	new head[40]
	if (fread_blocks(fp, head, 10, BLOCK_INT) != 10)
	{
		fclose(fp)
		return 0
	}
	if (head[0] != 0x50534449)   // "IDSP" little-endian
	{
		fclose(fp)
		return 0
	}
	new version = head[1]
	new count = head[7]
	if (version != 1 && version != 2)
	{
		fclose(fp)
		return 0
	}
	if (count < 2 || count > 64)
	{
		// one frame is a static sprite: no animation to gain, and 64 is more than
		// any effect here ships (mksprite writes 1..255).
		fclose(fp)
		return 0
	}

	// skip the palette to reach the first frame header
	new skip = (version == 2) ? (2 + 768 + 4) : 4
	fseek(fp, 40 + skip, SEEK_SET)

	new this_w, this_h, ok = 1
	new first = 0
	for (new i = 0; i < count; i++)
	{
		new fh[4]
		if (fread_blocks(fp, fh, 4, BLOCK_INT) != 4)
		{
			ok = 0
			break
		}
		this_w = fh[2]
		this_h = fh[3]
		if (this_w <= 0 || this_h <= 0 || this_w > 512 || this_h > 512)
		{
			ok = 0
			break
		}
		if (!first)
			first = this_w * 10000 + this_h
		else if (first != this_w * 10000 + this_h)
		{
			// frames of different sizes: a trail sprite, not a sheet
			ok = 0
			break
		}
		fseek(fp, this_w * this_h + ((i == count - 1) ? 0 : 4), SEEK_CUR)
	}
	fclose(fp)
	return ok ? count : 0
}

// One env_sprite playing a whole sheet in place. `frames` and `spin` are what the
// engine needs: pev_frame walks 0..frames-1 at pev_framerate and wraps, and the
// reaper kills it on the timer the caller gave it (WfcosFxDrop).
stock WfcosFxSheetEntity(owner, const Float:origin[3], model, const path[], frames, Float:scale, Float:fps, Float:life, amount)
{
	if (!model || !WfcosFxRoom(owner))
		return 0

	// The model has to be named: an env_sprite created with a model index only
	// draws nothing in Source-era engines, and GoldSrc is no better. The name is
	// the same string the registry row carries, so it is already in the pool.
	// (Because the name is set AFTER the index, precache is not re-run: the call
	// path is SetModel(name) then modelindex(index), see below.)
	new ent = engfunc(EngFunc_CreateNamedEntity, engfunc(EngFunc_AllocString, "env_sprite"))
	if (!ent || !pev_valid(ent))
		return 0

	new Float:rgba[3]
	rgba[0] = 255.0
	rgba[1] = 255.0
	rgba[2] = 255.0

	engfunc(EngFunc_SetModel, ent, path)
	set_pev(ent, pev_origin, origin)
	set_pev(ent, pev_solid, SOLID_NOT)
	set_pev(ent, pev_movetype, MOVETYPE_NONE)
	set_pev(ent, pev_scale, scale)
	set_pev(ent, pev_rendermode, kRenderGlow)
	set_pev(ent, pev_renderamt, float(amount))
	set_pev(ent, pev_rendercolor, rgba)
	// The engine walks the frames itself: no task, no think, no per-frame code.
	set_pev(ent, pev_frame, 0.0)
	set_pev(ent, pev_animtime, 0.0)
	set_pev(ent, pev_framerate, fps)
	set_pev(ent, pev_sequence, frames)      // how many frames to walk
	dllfunc(DLLFunc_Spawn, ent)
	set_pev(ent, pev_classname, FX_CLASS)
	WfcosFxDrop(ent, owner, life)
	return ent
}

// ============================================================
// One effect, start to finish
// ============================================================
// slot says which moment this is, so the same row reads correctly whether it is
// a kill burst (punchy) or a spawn flourish (quiet). at is the player the effect
// happens at: the victim for a kill, the dying player for a death, the spawner
// for a spawn. owner is who wears it, i.e. whose LPM preference applies.
stock WfcosFxPlay(owner, idx, slot, at)
{
	if (idx < 1 || idx > g_iCount)
		return
	if (!WfcosFxOn(owner))
	{
		g_iFxLpm++
		return
	}

	// Where. A kill and a death happen at the body; a spawn at the feet.
	new Float:origin[3]
	if (at >= 1 && at <= MaxClients && is_user_connected(at) && pev_valid(at))
		pev(at, pev_origin, origin)
	else if (owner >= 1 && owner <= MaxClients && is_user_connected(owner) && pev_valid(owner))
		pev(owner, pev_origin, origin)
	else
		return

	new model = g_iFxModel[idx]
	new look = WfcosFxLook(idx)
	new path[96]
	WfcosPathAt(g_szAsset[idx], 0, path, charsmax(path))

	// A packed sheet (one .spr holding every frame, 32-bit, wf_fx_sheet 1) is
	// animated on the client. That beats an env_sprite, and it beats the message
	// layer: a TE_SPRITETRAIL only steps frames along one straight line, a sheet
	// steps them in place. 0 means "not a sheet" or "the operator turned sheets
	// off", and the old two-layer path below still applies.
	new sheet = get_pcvar_num(g_pFxSheet) ? g_iFxSheetModel[idx] : 0

	// Both layers first, then the bookkeeping: the messages are sent either way,
	// so a refused entity still leaves a visible effect.
	new ent
	if (slot == WFCOS_SLOT_SPAWN)
	{
		origin[2] += 2.0
		WfcosFxMessages(origin, idx, model, slot)
		ent = (sheet > 0) ? WfcosFxSheetEntity(owner, origin, sheet, path, g_iFxSheetFrames[idx], 1.0, 10.0, 1.3, 220)
			: WfcosFxSprite(owner, origin, path, 1.0, 10.0, 0.7, 200, 255, 220)
	}
	else if (slot == WFCOS_SLOT_DEATH)
	{
		origin[2] += 4.0
		WfcosFxMessages(origin, idx, model, slot)
		// An imprint fades; a prop is left behind and stays until the round ends a
		// little later. Both are one entity and both are reaped on a timer.
		if (sheet > 0)
			ent = WfcosFxSheetEntity(owner, origin, sheet, path, g_iFxSheetFrames[idx], 1.0, 4.0, 4.0, 190)
		else
			ent = WfcosFxSprite(owner, origin, path, 1.0, 6.0,
				WfcosIsSprite(path) ? ((look == WFCOS_LOOK_ANGEL) ? 5.0 : 4.0) : 20.0, 190, 225, 255)
	}
	else
	{
		origin[2] += 26.0
		WfcosFxMessages(origin, idx, model, slot)
		ent = (sheet > 0) ? WfcosFxSheetEntity(owner, origin, sheet, path, g_iFxSheetFrames[idx], 1.0, 12.0, 0.9, 255)
			: WfcosFxSprite(owner, origin, path, 1.0, 12.0, 0.9, 255, 245, 240)
	}

	// The sheet carries its own motion, so the slot still gets its light for
	// free - the one thing a client-side animation cannot fake.
	if (sheet > 0)
		WfcosFxLight(origin, (slot == WFCOS_SLOT_DEATH) ? 140 : 170,
			g_iFxTint[idx][0], g_iFxTint[idx][1], g_iFxTint[idx][2],
			(slot == WFCOS_SLOT_DEATH) ? 14 : 10)
	if (!ent)
		g_iFxSkipped++

	g_iFxPlayed++
	if (get_pcvar_num(g_pFxDebug))
		log_amx("[WF-COS] fx %s slot %d at %d: %d live entity(s), %d for that player, %d skipped, engine %d entities",
			g_szId[idx], slot, at, g_iFxLiveUsed,
			(owner >= 1 && owner <= MaxClients) ? g_iFxPerPlayer[owner] : 0,
			g_iFxSkipped, engfunc(EngFunc_NumberOfEntities))

	// A preview plays the kill effect on the wearer's own body: there is no
	// victim, so there is no kill line to print.
	if (slot == WFCOS_SLOT_KILL && at != owner)
		WfcosFxKillLine(owner, at, idx)
}

// The optional kill notification: one line, the word from the row's text
// column. winterfest_killfeed owns the streak / headshot / Santa lines and is
// read, not replaced: it hooks the same DeathMsg event and never prints the
// victim, so this line cannot duplicate it. wf_fx_verb decides who hears it -
// the default (1) is the killer and the victim, which keeps a 32-slot server
// from turning into a chat feed while the effect itself is still on everyone's
// screen.
stock WfcosFxKillLine(killer, victim, idx)
{
	new verb = get_pcvar_num(g_pFxVerb)
	if (verb < 1)
		return
	new word[WFCOS_TEXT_LEN]
	copy(word, charsmax(word), g_szText[idx])
	trim(word)
	if (!word[0] || killer < 1 || killer > MaxClients || victim < 1 || victim > MaxClients)
		return

	new kname[MAX_NAME_LENGTH], vname[MAX_NAME_LENGTH]
	get_user_name(killer, kname, charsmax(kname))
	get_user_name(victim, vname, charsmax(vname))

	if (verb >= 2)
	{
		client_print_color(0, print_team_default, "^4[WF]^1 %s %s ^4%s^1", kname, word, vname)
		return
	}
	client_print_color(killer, print_team_default, "^4[WF]^1 you %s ^4%s^1", word, vname)
	if (victim != killer)
		client_print_color(victim, print_team_default, "^4[WF]^1 %s^1 %s you", kname, word)
}

// ============================================================
// Commands
// ============================================================
// /wfcos            the list
// /wfcos <id>       wear it (a medium/heavy hat asks once for the download)
// /wfcos off        remove what that slot holds
public cmdChat(id)
{
	if (!get_pcvar_num(g_pOn) || !WfcosInRange(id) || is_user_bot(id) || is_user_hltv(id) || !WfcosLoaded(id))
		return PLUGIN_HANDLED

	new args[64], cmd[16], arg[WFCOS_ID_LEN], msg[128]
	read_args(args, charsmax(args))
	remove_quotes(args)
	parse(args, cmd, charsmax(cmd), arg, charsmax(arg))

	new owned = 0, i
	for (i = 1; i <= g_iCount; i++)
		if (WfcosOwned(id, i))
			owned++
	formatex(msg, charsmax(msg), "cosmetics: you own %d of %d. /wfcos <id> wears it, /wfcos off removes it.", owned, g_iCount)
	WfcosSay(id, msg)

	if (arg[0])
	{
		if (equali(arg, "off"))
		{
			WfcosEquipSlot(id, WFCOS_SLOT_HAT, 0)
			WfcosEquipSlot(id, WFCOS_SLOT_TITLE, 0)
			WfcosEquipSlot(id, WFCOS_SLOT_KILL, 0)
			WfcosEquipSlot(id, WFCOS_SLOT_DEATH, 0)
			WfcosEquipSlot(id, WFCOS_SLOT_SPAWN, 0)
			WfcosSay(id, "hat, title and the three effects removed")
			return PLUGIN_HANDLED
		}
		new idx = WfcosFind(arg)
		if (idx < 1)
		{
			WfcosSay(id, "no such cosmetic id")
			return PLUGIN_HANDLED
		}
		WfcosUse(id, idx)
	}

	new shown = 0
	for (i = 1; i <= g_iCount && shown < 12; i++)
	{
		if (!WfcosOwned(id, i) || WfcosSlotOf(i) == WFCOS_SLOT_NONE)
			continue
		if (g_iEquip[id][WfcosSlotOf(i)] == i)
			formatex(msg, charsmax(msg), "  %s - %s  <- worn", g_szId[i], g_szName[i])
		else
			formatex(msg, charsmax(msg), "  %s - %s", g_szId[i], g_szName[i])
		WfcosSay(id, msg)
		shown++
	}
	return PLUGIN_HANDLED
}

WfcosUse(id, idx)
{
	new slot = WfcosSlotOf(idx), msg[160]
	if (slot == WFCOS_SLOT_NONE)
	{
		WfcosSay(id, "that one is not wearable (it is a prop or a skin)")
		return
	}
	if (!WfcosOwned(id, idx))
	{
		new src[40]
		WfcosLabel(3, idx, src, charsmax(src))
		formatex(msg, charsmax(msg), "not yours yet - it comes from %s", src)
		WfcosSay(id, msg)
		return
	}
	if (g_iEquip[id][slot] == idx)
	{
		WfcosEquipSlot(id, slot, 0)
		WfcosSay(id, "taken off")
		return
	}
	// A medium/heavy hat costs the player a download, so it is never applied on
	// the first word: the cost is stated, and the second word is the yes.
	if (slot == WFCOS_SLOT_HAT && g_iWeight[idx] != WFCOS_W_SMALL && g_iPending[id] != idx)
	{
		g_iPending[id] = idx
		formatex(msg, charsmax(msg), "%s needs a %d KB download; the engine throttles it, so this can take a minute. Repeat the command to accept.",
			g_szName[idx], WfcosHostBytes(idx) / 1024)
		WfcosSay(id, msg)
		return
	}
	g_iPending[id] = 0
	WfcosEquipSlot(id, slot, idx)
	if (slot == WFCOS_SLOT_HAT && !(g_iFlags[idx] & F_PRE))
		WfcosSay(id, "saved - it appears on the next spawn once an operator opens the download gate (wf_cosmetics_heavy)")
	else
	{
		formatex(msg, charsmax(msg), "wearing %s", g_szName[idx])
		WfcosSay(id, msg)
		if (WfcosKindIsFx(g_iKind[idx]))
		{
			formatex(msg, charsmax(msg), "see it without dying: /cospreview %s", g_szId[idx])
			WfcosSay(id, msg)
		}
	}
}

// /cospreview <id> - see an effect without dying for it, which is the whole
// point: an effect a player cannot look at before a round is a purchase they
// make blind. The owner may preview any effect; everyone else only what they
// own. Wears nothing, changes nothing, plays the effect on your own body.
public cmdPreview(id)
{
	if (!get_pcvar_num(g_pOn) || !WfcosInRange(id) || is_user_bot(id) || is_user_hltv(id) || !WfcosLoaded(id))
		return PLUGIN_HANDLED

	new args[64], cmd[16], arg[WFCOS_ID_LEN], msg[160]
	read_args(args, charsmax(args))
	remove_quotes(args)
	parse(args, cmd, charsmax(cmd), arg, charsmax(arg))

	if (!arg[0] || equali(arg, "off") || equali(arg, "on"))
	{
		// Toggle for the player's own effects, so nobody has to ask an admin
		// when the decoration gets in the way. State is per session.
		if (equali(arg, "off") || equali(arg, "on"))
		{
			g_bFxQuiet[id] = equali(arg, "off") ? true : false
			formatex(msg, charsmax(msg), "your own kill/death/spawn effects are now %s",
				g_bFxQuiet[id] ? "OFF (nothing will be drawn for you)" : "ON")
			WfcosSay(id, msg)
			return PLUGIN_HANDLED
		}
		WfcosSay(id, "usage: /cospreview <effect id>   (or /cospreview off / on)")
		new shown = 0
		for (new i = 1; i <= g_iCount && shown < 12; i++)
		{
			if (!WfcosKindIsFx(g_iKind[i]))
				continue
			formatex(msg, charsmax(msg), "  %s - %s", g_szId[i], g_szName[i])
			WfcosSay(id, msg)
			shown++
		}
		return PLUGIN_HANDLED
	}

	new idx = WfcosFind(arg)
	if (idx < 1)
	{
		WfcosSay(id, "no such cosmetic id")
		return PLUGIN_HANDLED
	}
	if (!WfcosKindIsFx(g_iKind[idx]))
	{
		WfcosSay(id, "that one is not an effect - only kill, death and spawn effects can be previewed")
		return PLUGIN_HANDLED
	}
	if (!get_pcvar_num(g_pFx))
	{
		WfcosSay(id, "effects are off on this server right now (wf_fx 0)")
		return PLUGIN_HANDLED
	}
	if (!is_user_alive(id))
	{
		WfcosSay(id, "you have to be alive: an effect is played on a body")
		return PLUGIN_HANDLED
	}
	if (!WfcosOwned(id, idx) && !(get_user_flags(id) & ADMIN_CFG))
	{
		new src[40]
		WfcosLabel(3, idx, src, charsmax(src))
		formatex(msg, charsmax(msg), "not yours yet - it comes from %s (an admin may preview anything)", src)
		WfcosSay(id, msg)
		return PLUGIN_HANDLED
	}
	new now = get_systime()
	if (g_iPreviewAt[id] && now - g_iPreviewAt[id] < WFCOS_PREVIEW_GAP)
	{
		formatex(msg, charsmax(msg), "one preview every %d seconds", WFCOS_PREVIEW_GAP)
		WfcosSay(id, msg)
		return PLUGIN_HANDLED
	}
	g_iPreviewAt[id] = now

	WfcosFxPlay(id, idx, WfcosSlotOf(idx), id)
	formatex(msg, charsmax(msg), "previewing %s", g_szName[idx])
	WfcosSay(id, msg)
	if (!WfcosFxOn(id))
		WfcosSay(id, "Low Performance Mode is on for you, so nothing was drawn (wf_fx_lpm)")
	return PLUGIN_HANDLED
}

public cmdGive(id, level, cid)
{
	if (!cmd_access(id, level, cid, 3))
		return PLUGIN_HANDLED

	new arg_target[40], arg_id[WFCOS_ID_LEN]
	read_argv(1, arg_target, charsmax(arg_target))
	read_argv(2, arg_id, charsmax(arg_id))

	new idx = WfcosFind(arg_id)
	if (idx < 1)
	{
		console_print(id, "[WF-COS] no cosmetic with id '%s'", arg_id)
		return PLUGIN_HANDLED
	}
	if (!WfcosRecorded(idx))
	{
		console_print(id, "[WF-COS] %s is scored by winterfest_core - not hand-grantable", arg_id)
		return PLUGIN_HANDLED
	}

	new players[MAX_PLAYERS], n, name[MAX_NAME_LENGTH], msg[96]
	// Every connected client; the loop below is what skips bots and HLTV. Do NOT
	// pass flags here: "ch" reads as skip-bots AND match-authid-with-no-argument,
	// which matches nobody, so a target of "all" would quietly do nothing.
	get_players(players, n)
	new matched = 0
	for (new i = 0; i < n; i++)
	{
		new p = players[i]
		if (is_user_bot(p) || is_user_hltv(p))
			continue
		get_user_name(p, name, charsmax(name))
		if (!equal(arg_target, "all") && containi(name, arg_target) < 0)
			continue
		matched++
		if (!WfcosLoaded(p))
			continue
		new code = WfcosGrant(p, idx)
		console_print(id, "[WF-COS] %s -> %s: %s", arg_id, name,
			(code == WFCOS_OK) ? "granted" : (code == WFCOS_DUPLICATE) ? "already owned" : "refused")
		if (code == WFCOS_OK)
		{
			formatex(msg, charsmax(msg), "unlocked %s - /wfcos to wear it", g_szName[idx])
			WfcosSay(p, msg)
		}
	}
	if (!matched)
		console_print(id, "[WF-COS] no client matched '%s'", arg_target)
	return PLUGIN_HANDLED
}

// wf_cosmetics_fx <target|all> <effect id>
//
// Plays an effect on a player right now, without a kill and without owning it.
// Two uses: the operator proving what an effect looks like on this box (the
// measurement in docs/WINTERFEST-COSMETICS.md sec 10.4 was taken with it), and a
// player's own /cospreview, which is the same call. It never grants anything and
// never equips anything.
public cmdFx(id, level, cid)
{
	if (!cmd_access(id, level, cid, 3))
		return PLUGIN_HANDLED

	new arg_target[40], arg_id[WFCOS_ID_LEN], name[MAX_NAME_LENGTH]
	read_argv(1, arg_target, charsmax(arg_target))
	read_argv(2, arg_id, charsmax(arg_id))

	new idx = WfcosFind(arg_id)
	if (idx < 1)
	{
		console_print(id, "[WF-COS] no cosmetic with id '%s'", arg_id)
		return PLUGIN_HANDLED
	}
	if (!WfcosKindIsFx(g_iKind[idx]))
	{
		console_print(id, "[WF-COS] %s is not an effect (kind %d) - this command plays kill/death/spawn only", arg_id, g_iKind[idx])
		return PLUGIN_HANDLED
	}
	if (!get_pcvar_num(g_pFx))
	{
		console_print(id, "[WF-COS] wf_fx is 0 - nothing would be drawn")
		return PLUGIN_HANDLED
	}

	new players[MAX_PLAYERS], n
	// Every connected client; the loop below is what skips bots and HLTV. Do NOT
	// pass flags here: "ch" reads as skip-bots AND match-authid-with-no-argument,
	// which matches nobody, so a target of "all" would quietly do nothing.
	get_players(players, n)
	new matched = 0, played = 0
	for (new i = 0; i < n; i++)
	{
		new p = players[i]
		get_user_name(p, name, charsmax(name))
		if (!equal(arg_target, "all") && !equal(arg_target, "#0") && containi(name, arg_target) < 0)
			continue
		matched++
		if (!is_user_alive(p))
			continue
		WfcosFxPlay(p, idx, WfcosSlotOf(idx), p)
		played++
	}
	console_print(id, "[WF-COS] %s on %d of %d client(s): %d live effect entity(s), ceilings %d global / %d per player",
		arg_id, played, matched, g_iFxLiveUsed, get_pcvar_num(g_pFxEnts), get_pcvar_num(g_pFxEntsP))
	return PLUGIN_HANDLED
}

// wf_fx_clock - the server's own effect clock, printed so a measurement can say
// "the burst was still alive at this moment" instead of guessing from wall time.
// Also the one place a tester can see the lifetime the plugin recorded per slot.
public cmdFxClock(id, level, cid)
{
	if (!cmd_access(id, level, cid, 1))
		return PLUGIN_HANDLED
	new now[16]
	new Float:gt = get_gametime()
	format_time(now, charsmax(now), "%H:%M:%S")
	console_print(id, "[WF-COS] gametime %.2f at %s: %d live, %d played, %d refused, %d downgraded",
		gt, now, g_iFxLiveUsed, g_iFxPlayed, g_iFxSkipped, g_iFxLpm)
	for (new i = 0; i < WFCOS_FX_LIVE; i++)
	{
		if (!g_iFxLiveEnt[i])
			continue
		console_print(id, "[WF-COS]   slot %02d ent %d owner %d ends at %.2f (in %.2f s)",
			i, g_iFxLiveEnt[i], g_iFxLiveOwner[i], g_fFxLiveEnd[i], g_fFxLiveEnd[i] - gt)
	}
	return PLUGIN_HANDLED
}

// wf_cosmetics_fxinfo - the numbers a low-end box is judged by. Everything here
// is a counter or a table length: no entity walk, no scan of the world.
public cmdFxInfo(id, level, cid)
{
	if (!cmd_access(id, level, cid, 1))
		return PLUGIN_HANDLED

	new cap = get_pcvar_num(g_pFxEnts)
	if (cap > WFCOS_FX_LIVE)
		cap = WFCOS_FX_LIVE
	console_print(id, "[WF-COS] wf_fx=%d lpm=%d verb=%d debug=%d",
		get_pcvar_num(g_pFx), get_pcvar_num(g_pFxLpm), get_pcvar_num(g_pFxVerb), get_pcvar_num(g_pFxDebug))
	console_print(id, "[WF-COS] effect entities: %d live (ceiling %d, table %d), %d per-player ceiling",
		g_iFxLiveUsed, cap, WFCOS_FX_LIVE, get_pcvar_num(g_pFxEntsP))
	console_print(id, "[WF-COS] played %d, entity layer refused %d, downgraded for LPM/off %d",
		g_iFxPlayed, g_iFxSkipped, g_iFxLpm)
	console_print(id, "[WF-COS] the engine counts %d entities in the world right now", engfunc(EngFunc_NumberOfEntities))

	new per = 0, headroom = 0
	for (new p = 1; p <= MaxClients; p++)
	{
		if (g_iFxPerPlayer[p] > per)
			per = g_iFxPerPlayer[p]
	}
	headroom = cap - g_iFxLiveUsed
	if (headroom < 0)
		headroom = 0
	console_print(id, "[WF-COS] busiest client holds %d effect entity(s); room for %d more before the ceiling bites",
		per, headroom)

	new missing = 0
	new path96[96]
	for (new i = 1; i <= g_iCount; i++)
	{
		// A sheet row counts as served: it has no single-frame index and does not
		// need one (see WfcosFxPlay). Without this the sheet rows were reported as
		// missing the sprite they in fact carry.
		if (!WfcosKindIsFx(g_iKind[i]) || g_iFxModel[i] || g_iFxSheetModel[i])
			continue
		// A .mdl row (death_present) has no sprite index on purpose: it is the
		// entity's model name that matters, not a sprite for the message layer.
		WfcosPathAt(g_szAsset[i], 0, path96, charsmax(path96))
		if (WfcosIsSprite(path96))
			missing++
	}
	if (missing)
		console_print(id, "[WF-COS] %d effect row(s) have no precached sprite here: /cospreview will show the message layer only", missing)
	return PLUGIN_HANDLED
}

public cmdReload(id, level, cid)
{
	if (!cmd_access(id, level, cid, 1))
		return PLUGIN_HANDLED
	WfcosRegistry()
	console_print(id, "[WF-COS] %d cosmetic(s), %d precached, wf_cosmetics=%d heavy=%d",
		g_iCount, WfcosPrecCount(), get_pcvar_num(g_pOn), get_pcvar_num(g_pHeavy))
	console_print(id, "[WF-COS] models are precached in plugin_precache - changelevel to pick up new or re-weighted rows")
	return PLUGIN_HANDLED
}

// The preflight: the only facts a server can know, one row per cosmetic.
public cmdCheck(id, level, cid)
{
	if (!cmd_access(id, level, cid, 1))
		return PLUGIN_HANDLED
	if (!WfcosLoaded(0))
	{
		console_print(id, "[WF-COS] no registry: configs/%s is missing or empty", REGISTRY_FILE)
		return PLUGIN_HANDLED
	}

	console_print(id, "[WF-COS] registry '%s': %d cosmetic(s), wf_cosmetics=%d heavy=%d core=%s",
		REGISTRY_FILE, g_iCount, get_pcvar_num(g_pOn), get_pcvar_num(g_pHeavy),
		LibraryExists("winterfest_core", LibType_Library) ? "yes" : "no")
	console_print(id, "[WF-COS] %-22s %-6s %-6s %9s %9s %5s  %s", "id", "kind", "weight", "declared", "host", "fils", "note")

	new present = 0, missing = 0, files = 0, gone = 0, bytes = 0, i
	for (i = 1; i <= g_iCount; i++)
	{
		if (!(g_iFlags[i] & F_DL))
			continue
		new p[96], paths = 0, here = 0, k
		for (k = 0; k < WFCOS_MAX_PATHS; k++)
		{
			if (!WfcosPathAt(g_szAsset[i], k, p, charsmax(p)))
				break
			paths++
			if (file_exists(p))
				here++
		}
		new host = WfcosHostBytes(i), note[40]
		if (here < paths)
		{
			missing++
			gone += paths - here
			copy(note, charsmax(note), "MISSING on host")
		}
		else
		{
			present++
			bytes += host
			if (g_iFlags[i] & F_PRE)
				copy(note, charsmax(note), "precached")
			else if (g_iKind[i] == WFCOS_KIND_SKIN)
				copy(note, charsmax(note), "host only (weapon_models)")
			else
				copy(note, charsmax(note), "not precached (gate)")
		}
		files += here
		new kname[16], wname[16]
		WfcosLabel(1, g_iKind[i], kname, charsmax(kname))
		WfcosLabel(2, g_iWeight[i], wname, charsmax(wname))
		console_print(id, "[WF-COS] %-22s %-6s %-6s %9d %9d %5d  %s", g_szId[i],
			kname, wname, g_iDeclared[i], host, here, note)
	}

	console_print(id, "[WF-COS] summary: %d of %d download row(s) complete on this host (%d file(s), %d missing, %d bytes)",
		present, present + missing, files, gone, bytes)
	console_print(id, "[WF-COS] note: exists-on-host is all this server knows. A mirror 404 is survivable (sv_allowdownload 1 falls back to the game port) and a 200 proves nothing - only a real client joining proves a download path.")
	return PLUGIN_HANDLED
}

// ============================================================
// Natives
// ============================================================
public native_count(plugin, params)
{
	#pragma unused plugin, params
	return g_iCount
}

public native_find(plugin, params)
{
	#pragma unused plugin
	new buf[WFCOS_ID_LEN]
	get_string(1, buf, charsmax(buf))
	return WfcosFind(buf)
}

public native_owned(plugin, params)
{
	#pragma unused plugin
	return WfcosOwned(get_param(1), get_param(2)) ? 1 : 0
}

public native_grant_id(plugin, params)
{
	#pragma unused plugin
	new id = get_param(1)
	new buf[WFCOS_ID_LEN]
	get_string(2, buf, charsmax(buf))
	if (!WfcosInRange(id) || is_user_bot(id) || is_user_hltv(id))
		return WFCOS_INVALID
	new idx = WfcosFind(buf)
	if (idx < 1)
		return WFCOS_INVALID
	if (!WfcosLoaded(id))
		return WFCOS_NOTLOADED
	return WfcosGrant(id, idx)
}

public native_equip_slot(plugin, params)
{
	#pragma unused plugin
	new id = get_param(1)
	if (!WfcosInRange(id) || is_user_bot(id) || is_user_hltv(id))
		return WFCOS_INVALID
	if (!WfcosLoaded(id))
		return WFCOS_NOTLOADED
	return WfcosEquipSlot(id, get_param(2), get_param(3))
}

public native_equipped(plugin, params)
{
	#pragma unused plugin
	new id = get_param(1)
	new slot = get_param(2)
	if (!WfcosInRange(id) || slot < 1 || slot > WFCOS_MAX_SLOTS)
		return 0
	return g_iEquip[id][slot]
}

public native_title_of(plugin, params)
{
	#pragma unused plugin
	new buf[WFCOS_TEXT_LEN]
	WfcosWornTitle(get_param(1), buf, charsmax(buf))
	set_string(2, buf, get_param(3))
	return buf[0] ? 1 : 0
}

public native_enabled(plugin, params)
{
	#pragma unused plugin, params
	return get_pcvar_num(g_pOn) ? 1 : 0
}

// ============================================================
// Shared pieces
// ============================================================
bool:WfcosLoaded(id)
{
	if (id == 0)
	{
		if (!g_bLoaded)
			WfcosRegistry()
		return g_bLoaded
	}
	return g_bLoadedP[id]
}

stock WfcosFind(const cosmetic_id[])
{
	if (!cosmetic_id[0])
		return 0
	for (new idx = 1; idx <= g_iCount; idx++)
		if (equali(g_szId[idx], cosmetic_id))
			return idx
	return 0
}

bool:WfcosInRange(id)
{
	return (id >= 1 && id <= MaxClients) ? true : false
}
