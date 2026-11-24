/*
 * ============================================================================
 * winterfest_core — the single owner of Winterfest state
 * ============================================================================
 * Product contract: docs/WINTERFEST.md (Phase 1, §4.1/§4.4/§4.6/§4.7).
 * Developer map, nvault schema and ini format: docs/WINTERFEST-DEV.md.
 *
 * WHAT THIS PLUGIN OWNS
 *   - GingerBread (the soft currency, id `gb`), present inventory (instances,
 *     by rarity), spins, the envelope's pending counter,
 *     ornament ids owned, the tree level (and the placement string the panel
 *     owns in Phase 2), advent claims, Winter Pass XP + tier, ornament-set
 *     titles.
 *   - the ONE grant path (wf_grant / WF_Grant): every payoff in the module goes
 *     through it, with a claim key that is written to the vault BEFORE the
 *     reward is applied or announced. A reconnect, a retry, two /opengift in
 *     the same second, or two code paths reaching for the same present can
 *     therefore never double-pay. This is the discipline battlepass_core
 *     adopted after REVIEW §2.4 (bpaward# keys) and it is the reason a claim
 *     key - not a timestamp - is the idempotency record.
 *   - persistence: one vault (freenova_wf), keys prefixed `wf_`, every key
 *     season-stamped through WfKey() the way BpCursorKey stamps BP cursors, so
 *     next December (bump `year` in winterfest.ini) starts clean without
 *     deleting history.
 *   - the natives winterfest_gifts / winterfest_menu (and the panel bridge,
 *     when it exists) consume.
 *   - operator commands: wf_give, wf_state, wf_reset, wf_reload.
 *
 * WHAT IT DELIBERATELY DOES NOT DO
 *   - no client asset. Not one precache here, and none downstream: gifts use
 *     stock sprites only (docs/WINTERFEST.md §1.1).
 *   - no panel work. The fields the panel will need are written down in
 *     docs/WINTERFEST-DEV.md §7 (sync payload design), not implemented here.
 *   - no gameplay mode. Gameplay modules are Phase 3 and plug into fn_mode.
 *
 * SAFETY ON THE LIVE TREE (70+ plugins, 512-item precache ceiling)
 *   - every array is indexed 1..MaxClients with an explicit bounds check
 *     (WfReady), so there is no -1 / 33 indexing even from a stale task.
 *   - every loop is bounded by a compile-time cap (WF_MAX_*) or MaxClients.
 *   - no per-frame work: one 30 s autosave task, one late-load task per client.
 *   - a missing/garbled winterfest.ini leaves the module loaded but closed:
 *     wf_season_open() returns false, every module goes quiet, the server
 *     behaves exactly like a server without Winterfest.
 *
 * EVERYTHING IS DATA: season window, rarity table, ornament catalogue, set
 * titles, present spots, advent table, pass tiers and the reward pools all live
 * in configs/freenova/winterfest.ini (Phase 1 §5.5). Halloween/Easter reuse the
 * same file shape with a different season block.
 * ============================================================================
 */

#include <amxmodx>
#include <amxmisc>
#include <nvault>
#include <winterfest>

#define PLUGIN  "Winterfest Core"
#define VERSION "1.0.0"
#define AUTHOR  "FreeNova"

// Vault name is new on purpose: the existing tree vaults are freenova_bp
// (BattlePass) and the per-feature ones. `wf_` keys in a separate file means
// nothing here can collide with bpxp/level/credits, and an operator can back up
// or delete Winterfest without touching progression.
#define VAULT_NAME "freenova_wf"
#define CONFIG_FILE "freenova/winterfest.ini"

// nvault key ceiling. Keys are refused (failing closed: no write, loud log)
// rather than truncated, because two truncated keys would silently alias.
#define MAX_KEY 64

// Task bases. AMXX task ids are per-plugin, but a distinct base keeps a
// remove_task(id + base) sweep obvious in a log.
enum
{
	TASK_LOAD = 91000,
	TASK_AUTOSAVE = 99900
}

// Cvars.
new g_pEnabled;
new g_pForceOpen;

// Config state.
new bool:g_bCfgOk;
new g_szCfgPath[128];

new g_szSeasonName[48];
new g_iSeasonYear;
new g_iDateStart;   // YYYYMMDD
new g_iDateEnd;     // YYYYMMDD
new g_iAdventEnd;   // YYYYMMDD - last day a missed advent day can be claimed
new bool:g_bSeasonEnabled;

new g_szRarName[WF_RARITY_MAX][24];
new g_iRarColor[WF_RARITY_MAX][3];
new g_iRarWeight[WF_RARITY_MAX];
new g_iRarCount;

new g_szOrnName[WF_MAX_ORNAMENTS + 1][40];
new g_iOrnRarity[WF_MAX_ORNAMENTS + 1];
new g_iOrnSet[WF_MAX_ORNAMENTS + 1];
new g_iOrnCount;

new g_szSetName[WF_MAX_SETS + 1][32];
new g_szSetTitle[WF_MAX_SETS + 1][40];
new g_iSetSnow[WF_MAX_SETS + 1];
new g_iSetTotal[WF_MAX_SETS + 1];
new g_iSetCount;

// Tree grid (owner decision 2026-11-22 §6.1): three styles, 24 slots each, the
// slot layout is data so the panel can render it. Percent coordinates 0..100.
new g_iStyleCount;
new g_szStyleName[WF_MAX_STYLES + 1][24];
new g_iStyleX[WF_MAX_STYLES + 1][WF_TREE_SLOTS + 1];
new g_iStyleY[WF_MAX_STYLES + 1][WF_TREE_SLOTS + 1];

// Visuals: the look of every prop, by name (see include/winterfest.inc).
new g_iVisCount;
new g_szVisName[WF_MAX_VISUALS][32];
new g_iVisKind[WF_MAX_VISUALS];
new g_szVisAsset[WF_MAX_VISUALS][64];
new g_szVisColour[WF_MAX_VISUALS][16];
new Float:g_fVisScale[WF_MAX_VISUALS];
new g_szVisFallback[WF_MAX_VISUALS][32];

// [props] slot -> configured visual name -> resolved visual name.
new const g_szPropSlot[WF_PROP_SLOTS][] =
{
	WF_PROP_PRESENT_COMMON,
	WF_PROP_PRESENT_UNCOMMON,
	WF_PROP_PRESENT_RARE,
	WF_PROP_POUCH,
	WF_PROP_TREE,
	WF_PROP_C4
}
new g_szPropVisual[WF_PROP_SLOTS][32];
new g_szPropResolved[WF_PROP_SLOTS][32];

// [spins] - the free daily spin (workstream 13 owns the wheel and the prizes).
new g_iSpinsFree = 1;
new bool:g_bSpinsEnabled = true;

new g_iAdvType[WF_MAX_ADVENT + 1];
new g_iAdvRid[WF_MAX_ADVENT + 1];
new g_iAdvCount;

// Entitlement catalogue (owner decision §6.5/§7). Product ids are strings and
// live in the ini, so the panel and the game cannot disagree about what exists.
#define WF_MAX_PRODUCTS 8
new g_iEntCount;
new g_szProdId[WF_MAX_PRODUCTS][40];
new g_szProdLabel[WF_MAX_PRODUCTS][48];
new g_szProdKind[WF_MAX_PRODUCTS][16];

// The premium track: same tiers, same thresholds as [pass], its own reward rows.
new g_iPremType[WF_MAX_TIERS + 1];
new g_iPremRid[WF_MAX_TIERS + 1];

new g_iTierXp[WF_MAX_TIERS + 1];      // cumulative XP that opens the tier
new g_iTierType[WF_MAX_TIERS + 1];
new g_iTierRid[WF_MAX_TIERS + 1];
new g_iTierCount;

new g_iPoolCount[WF_RARITY_MAX];
new g_iPoolType[WF_RARITY_MAX][WF_MAX_POOL];
new g_iPoolRid[WF_RARITY_MAX][WF_MAX_POOL];
new g_iPoolMin[WF_RARITY_MAX][WF_MAX_POOL];
new g_iPoolMax[WF_RARITY_MAX][WF_MAX_POOL];
new g_iPoolWeight[WF_RARITY_MAX][WF_MAX_POOL];

// Per-player state. Index 0 is never used and never written.
new g_Vault = INVALID_HANDLE;
new g_iGb[MAX_PLAYERS + 1];
new g_iSpins[MAX_PLAYERS + 1];
new g_iPending[MAX_PLAYERS + 1];   // reserved for the envelope (workstream 15)
new g_iPassXp[MAX_PLAYERS + 1];
new g_iTree[MAX_PLAYERS + 1];
new g_iEpoch[MAX_PLAYERS + 1];
new g_iGiftSeq[MAX_PLAYERS + 1];
new g_szGifts[MAX_PLAYERS + 1][192];     // "instance:rarity,instance:rarity"
new g_szOrn[MAX_PLAYERS + 1][320];       // "1,4,7" (ornament ids owned)
new g_szAdv[MAX_PLAYERS + 1][128];       // "1,2,3" (advent days claimed)
new g_szTitles[MAX_PLAYERS + 1][128];    // "1,3"   (ornament-set ids completed)
new g_szEnts[MAX_PLAYERS + 1][160];      // "product@source,..." (entitlements)
new g_szPlace[MAX_PLAYERS + 1][224];     // "3:7,4:12" - slot:ornament on the 24-slot grid
new g_iStyle[MAX_PLAYERS + 1];           // tree style, 1..g_iStyleCount
new bool:g_bLoaded[MAX_PLAYERS + 1];
new bool:g_bDirty[MAX_PLAYERS + 1];
new bool:g_bInTierSync[MAX_PLAYERS + 1];
new g_iLoadTries[MAX_PLAYERS + 1];

// ============================================================
// Plugin lifecycle
// ============================================================
// One optional foreign native: BattlePass coins, used only by a premium reward
// row that pays coins. Declared here and filtered below, so a server without
// battlepass_core loads this plugin normally instead of bad-loading it.
native menabp_add_coins_once(id, amount, const awardId[]);

public plugin_natives()
{
	register_library("winterfest_core");
	set_native_filter("WfCoreNativeFilter");

	register_native("wf_season_open", "native_season_open");
	register_native("wf_season_name", "native_season_name");
	register_native("wf_season_window", "native_season_window");
	register_native("wf_get_gingerbread", "native_get_gingerbread");
	register_native("wf_add_gingerbread", "native_add_gingerbread");
	// Deprecated aliases, kept for one season (see include/winterfest.inc).
	register_native("wf_get_snowflakes", "native_get_gingerbread");
	register_native("wf_add_snowflakes", "native_add_gingerbread");
	register_native("wf_get_spins", "native_get_spins");
	register_native("wf_add_spins", "native_add_spins");
	register_native("wf_consume_spin", "native_consume_spin");
	register_native("wf_get_pending", "native_get_pending");
	register_native("wf_grant", "native_grant");
	register_native("wf_grant_ornament", "native_grant_ornament");
	register_native("wf_has_ornament", "native_has_ornament");
	register_native("wf_ornament_count", "native_ornament_count");
	register_native("wf_ornament_total", "native_ornament_total");
	register_native("wf_ornament_name", "native_ornament_name");
	register_native("wf_ornament_rarity", "native_ornament_rarity");
	register_native("wf_ornament_set", "native_ornament_set");
	register_native("wf_tree_level", "native_tree_level");
	register_native("wf_tree_style", "native_tree_style");
	register_native("wf_tree_set_style", "native_tree_set_style");
	register_native("wf_tree_slot", "native_tree_slot");
	register_native("wf_tree_set_slot", "native_tree_set_slot");
	register_native("wf_tree_filled", "native_tree_filled");
	register_native("wf_tree_slots", "native_tree_slots");
	register_native("wf_tree_next_set", "native_tree_next_set");
	register_native("wf_tree_style_count", "native_tree_style_count");
	register_native("wf_tree_style_name", "native_style_name");
	register_native("wf_tree_slot_x", "native_tree_slot_x");
	register_native("wf_tree_slot_y", "native_tree_slot_y");
	register_native("wf_set_count", "native_set_count");
	register_native("wf_set_name", "native_set_name");
	register_native("wf_set_title", "native_set_title");
	register_native("wf_set_owned", "native_set_owned");
	register_native("wf_set_total", "native_set_total");
	register_native("wf_get_pass_xp", "native_pass_xp");
	register_native("wf_get_pass_tier", "native_pass_tier");
	// Aliases, kept for one season.
	register_native("wf_pass_xp", "native_pass_xp");
	register_native("wf_pass_tier", "native_pass_tier");
	register_native("wf_pass_next_xp", "native_pass_next_xp");
	register_native("wf_pass_max_tier", "native_pass_max_tier");
	register_native("wf_pass_tier_xp", "native_pass_tier_xp");
	register_native("wf_pass_tier_reward", "native_pass_tier_reward");
	register_native("wf_pass_tier_reward_premium", "native_pass_tier_reward_premium");
	register_native("wf_claim_pass_tier", "native_claim_pass_tier");
	register_native("wf_pass_premium_unlocked", "native_pass_premium_unlocked");
	register_native("wf_has_entitlement", "native_has_entitlement");
	register_native("wf_grant_entitlement", "native_grant_entitlement");
	register_native("wf_entitlement_count", "native_entitlement_count");
	register_native("wf_entitlement_name", "native_entitlement_name");
	register_native("wf_entitlement_label", "native_entitlement_label");
	register_native("wf_advent_today", "native_advent_today");
	register_native("wf_advent_state", "native_advent_state");
	register_native("wf_advent_claim", "native_advent_claim");
	register_native("wf_advent_claimed", "native_advent_claimed");
	register_native("wf_gift_count", "native_gift_count");
	register_native("wf_gift_instance", "native_gift_instance");
	register_native("wf_gift_rarity", "native_gift_rarity");
	register_native("wf_open_gift", "native_open_gift");
	register_native("wf_rarity_name", "native_rarity_name");
	register_native("wf_visual_id", "native_visual_id");
	register_native("wf_visual_is_model", "native_visual_is_model");
	register_native("wf_visual_asset", "native_visual_asset");
	register_native("wf_visual_colour", "native_visual_colour");
	register_native("wf_visual_scale", "native_visual_scale");
	register_native("wf_visual_count", "native_visual_count");
}

// A missing wf_* is a real bug; a missing menabp_* is a supported configuration
// (no BattlePass on this server), so only the foreign family is filtered.
public WfCoreNativeFilter(const name[], index, trap)
{
	if (!trap && contain(name, "menabp_") == 0 && !LibraryExists("menabp", LibType_Library))
		return PLUGIN_HANDLED
	return PLUGIN_CONTINUE
}

public plugin_init()
{
	register_plugin(PLUGIN, VERSION, AUTHOR)

	g_pEnabled = register_cvar("wf_enabled", "1")
	// Out-of-season switch for operators and for the test harness: it opens the
	// gates below WITHOUT touching the ini, so a December config can be tested
	// in November and a season can be kept open past its end date.
	g_pForceOpen = register_cvar("wf_force_open", "0")
	// Model visuals are the DEFAULT since the 2026-11 playtest: the shipped
	// present (models/winterfest/present.mdl, 41.8 KB, docs/MODELS.md) is what a
	// present should look like. A model row is still usable only while its file
	// is on disk, and every row names a sprite fallback, so a server without the
	// file - or a client mid-download - gets the stock glow and never an ERROR.
	// 0 = a hard "sprites only" switch for an operator who wants Phase 1 back.
	register_cvar("wf_allow_models", "1")

	// wf_chat_debug 1 logs every Winterfest chat line (see WfChatDebug in
	// winterfest.inc). Off: a normal boot says nothing.
	register_cvar("wf_chat_debug", "0")

	register_concmd("wf_give", "cmdGive", ADMIN_CFG, "<target|all> <gingerbread|spins|ornament|gift> <id> <n> - grant Winterfest rewards")
	register_concmd("wf_state", "cmdState", ADMIN_CFG, "<target|all> - print Winterfest state")
	register_concmd("wf_reset", "cmdReset", ADMIN_CFG, "<target> - wipe current-season Winterfest data")
	register_concmd("wf_reload", "cmdReload", ADMIN_CFG, "- re-read configs/freenova/winterfest.ini")
	register_concmd("wf_ent", "cmdEnt", ADMIN_CFG, "<target|all> <product> [source] - grant an entitlement (bp_premium_2026, advent_pass_2026)")

	server_print("[FreeNova winterfest_core] ready (build 3, %d features)", 52)
	WfLogClock()

	loadConfig()

	g_Vault = nvault_open(VAULT_NAME)
	if (g_Vault == INVALID_HANDLE)
		log_amx("[WF] ERROR: nvault_open('%s') failed - Winterfest will not persist", VAULT_NAME)
	else if (g_bCfgOk)
		log_amx("[WF] vault '%s' open, config %s, season '%s' %d-%d",
			VAULT_NAME,
			g_bSeasonEnabled ? "enabled" : "disabled",
			g_szSeasonName, g_iDateStart, g_iDateEnd)

	// One autosave task for the whole server, not one per player: it walks the
	// 33 slots and saves only the dirty ones.
	set_task(30.0, "Task_AutoSave", TASK_AUTOSAVE, _, _, "b")

	// The [open] table is what an OPENED present rolls. Without a row for a
	// rarity, WfOpenGift() falls through to a flat 15 GingerBread - a legal
	// configuration, so it is said once here instead of per open.
	log_amx("[WF] open table: %d/%d/%d reward row(s) for rarity 0/1/2%s",
		g_iPoolCount[0], g_iPoolCount[1], g_iPoolCount[2],
		(g_iPoolCount[0] + g_iPoolCount[1] + g_iPoolCount[2]) ? "" : " - every opened present pays the 15 gb fallback")
	log_amx("[WF] config: %d rarities, %d ornaments, %d sets, %d advent days, %d pass tiers",
		g_iRarCount, g_iOrnCount, g_iSetCount, g_iAdvCount, g_iTierCount)
	log_amx("[WF] spins: %s, %d free per day", g_bSpinsEnabled ? "enabled" : "disabled", g_iSpinsFree)
	log_amx("[WF] %d product(s) in the entitlement catalogue; premium track: %s",
		g_iEntCount, WfPremiumRowCount() > 0 ? "configured" : "absent")
}

public plugin_end()
{
	remove_task(TASK_AUTOSAVE)

	new saved = 0
	for (new id = 1; id <= MaxClients; id++)
	{
		remove_task(id + TASK_LOAD)
		if (WfSave(id, true))
			saved++
	}

	if (g_Vault != INVALID_HANDLE)
	{
		nvault_close(g_Vault)
		g_Vault = INVALID_HANDLE
	}
	log_amx("[WF] plugin_end: saved %d player record(s) before vault close", saved)
}

public client_putinserver(id)
{
	if (!WfInRange(id))
		return

	WfClearMem(id)
	set_task(0.5, "Task_Load", id + TASK_LOAD)
}

// The authid is usually there by 0.5 s; when it is not (very slow auth server,
// or a listen server) retry a couple of times and then give up with a log
// rather than writing a record keyed on STEAM_ID_PENDING.
public Task_Load(id)
{
	id -= TASK_LOAD
	if (!WfInRange(id) || !is_user_connected(id))
		return

	new auth[40]
	get_user_authid(id, auth, charsmax(auth))
	if (!auth[0] || equal(auth, "STEAM_ID_PENDING") || equal(auth, "UNKNOWN"))
	{
		// Bots have authid "BOT" and load on the first try; a human stuck here
		// is rare. Three attempts, then the player plays without persistence
		// rather than writing a record keyed on STEAM_ID_PENDING.
		g_iLoadTries[id]++
		if (g_iLoadTries[id] < 3)
		{
			set_task(3.0, "Task_Load", id + TASK_LOAD)
			return
		}
		log_amx("[WF] id %d never received an authid - no Winterfest record this session", id)
		return
	}

	g_iLoadTries[id] = 0
	WfLoad(id)
}

public Task_AutoSave(taskid)
{
	new saved = 0
	for (new id = 1; id <= MaxClients; id++)
	{
		if (WfSave(id, false))
			saved++
	}
	// Only speak when something was actually written: a quiet server must not
	// fill the log with a line every 30 s.
	if (saved)
		log_amx("[WF] autosave: %d dirty record(s) written", saved)
}

public client_disconnected(id)
{
	if (!WfInRange(id))
		return
	remove_task(id + TASK_LOAD)
	remove_task(id + TASK_LOAD + 500)
	WfSave(id, true)
	WfClearMem(id)
}

// ============================================================
// Config: winterfest.ini
// ============================================================
// A deliberately dumb line parser: `[section]` headers, `a | b | c` rows,
// `key = value` pairs in [season], ';' and '#' start a comment. Every row is
// bounded by the WF_MAX_* caps and a row that does not fit is logged and
// skipped - a config mistake must never take the server down.
loadConfig()
{
	g_bCfgOk = false
	g_iRarCount = 0
	g_iOrnCount = 0
	g_iSetCount = 0
	g_iAdvCount = 0
	g_iTierCount = 0
	g_iStyleCount = 0
	g_iVisCount = 0
	g_iSpinsFree = 1
	g_bSpinsEnabled = true
	g_iEntCount = 0
	for (new i = 0; i <= WF_MAX_TIERS; i++)
	{
		g_iPremType[i] = WF_REWARD_NONE
		g_iPremRid[i] = 0
	}
	for (new s = 0; s <= WF_MAX_STYLES; s++)
		g_szStyleName[s][0] = 0
	for (new p = 0; p < WF_PROP_SLOTS; p++)
	{
		g_szPropVisual[p][0] = 0
		g_szPropResolved[p][0] = 0
	}
	for (new r = 0; r < WF_RARITY_MAX; r++)
	{
		g_iPoolCount[r] = 0
		g_iRarWeight[r] = 0
		formatex(g_szRarName[r], charsmax(g_szRarName[]), "rarity%d", r)
	}

	new cfgdir[96]
	get_configsdir(cfgdir, charsmax(cfgdir))
	formatex(g_szCfgPath, charsmax(g_szCfgPath), "%s/%s", cfgdir, CONFIG_FILE)

	if (!file_exists(g_szCfgPath))
	{
		log_amx("[WF] no config at %s - Winterfest is closed (this is not an error)", g_szCfgPath)
		return
	}

	new fp = fopen(g_szCfgPath, "rt")
	if (!fp)
	{
		log_amx("[WF] config %s exists but could not be opened - Winterfest is closed", g_szCfgPath)
		return
	}

	new line[256], section[24], key[24], val[96]
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

		if (equal(section, "season"))
		{
			new eq = contain(line, "=")
			if (eq < 1)
				continue
			copy(key, charsmax(key), line)
			key[eq] = 0
			trim(key)
			strtolower(key)
			copy(val, charsmax(val), line[eq + 1])
			trim(val)

			if (equal(key, "name"))
				copy(g_szSeasonName, charsmax(g_szSeasonName), val)
			else if (equal(key, "year"))
				g_iSeasonYear = str_to_num(val)
			else if (equal(key, "start"))
				g_iDateStart = WfDateKey(val)
			else if (equal(key, "end"))
				g_iDateEnd = WfDateKey(val)
			else if (equal(key, "advent_end"))
				g_iAdventEnd = WfDateKey(val)
			else if (equal(key, "enabled"))
				g_bSeasonEnabled = (str_to_num(val) != 0) ? true : false
			continue
		}

		if (equal(section, "rarity"))
			parseRarity(line)
		else if (equal(section, "ornament"))
			parseOrnament(line)
		else if (equal(section, "set"))
			parseSet(line)
		else if (equal(section, "advent"))
			parseAdvent(line)
		else if (equal(section, "pass"))
			parsePass(line)
		else if (equal(section, "open"))
			parsePool(line)
		else if (equal(section, "tree"))
			parseTree(line)
		else if (equal(section, "visual"))
			parseVisual(line)
		else if (equal(section, "props"))
			parseProps(line)
		else if (equal(section, "spins"))
			parseSpins(line)
		else if (equal(section, "entitlement"))
			parseEntitlement(line)
		else if (equal(section, "pass_premium"))
			parsePassPremium(line)
		// [presents] belongs to winterfest_gifts.amxx - it reads the same file
		// for its own section, and this plugin never touches it.
	}
	fclose(fp)

	// Validate what later code assumes.
	if (g_iSeasonYear < 2020 || g_iSeasonYear > 2100)
	{
		log_amx("[WF] [season] year = %d is out of range - using the start date's year", g_iSeasonYear)
		g_iSeasonYear = g_iDateStart / 10000
	}
	if (!g_szSeasonName[0])
		copy(g_szSeasonName, charsmax(g_szSeasonName), "Winterfest")
	if (!g_iDateStart || !g_iDateEnd)
		log_amx("[WF] [season] start/end missing - the date window is ignored (cvar wf_enabled still applies)")
	if (g_iRarCount <= 0)
		log_amx("[WF] no [rarity] rows - presents cannot roll rewards")

	// The advent deadline is its own key: the season runs to the end date, but a
	// missed advent day can only be claimed until the advent closes (owner
	// decision §6.3 - 24 December for Winterfest 2026).
	if (!g_iAdventEnd)
		g_iAdventEnd = g_iDateEnd
	if (g_iStyleCount < 1)
		log_amx("[WF] no [tree] rows - /tree will show the level but no style name")
	else
		log_amx("[WF] tree styles configured: %d (each needs %d slot rows)", g_iStyleCount, WF_TREE_SLOTS)

	// Visuals last: "usable" depends on the parsed rows and on wf_allow_models.
	WfResolveAllVisuals()
	if (g_iVisCount > 0)
		log_amx("[WF] %d visual id(s) configured, %d prop slot(s) bound (models %s)",
			g_iVisCount, WF_PROP_SLOTS,
			get_cvar_num("wf_allow_models") ? "allowed" : "gated - every model prop falls back to its sprite")

	// Sets count their ornaments from the catalogue, and the tree is grown by
	// completed sets; a set with no ornaments is ignored.
	for (new s = 1; s <= WF_MAX_SETS; s++)
	{
		g_iSetTotal[s] = 0
		for (new o = 1; o <= g_iOrnCount; o++)
			if (g_iOrnSet[o] == s)
				g_iSetTotal[s]++
	}

	g_bCfgOk = true
}

parseRarity(const line[])
{
	new id = WfFieldInt(line, 0, -1)
	if (id < 0 || id >= WF_RARITY_MAX)
	{
		log_amx("[WF] [rarity] id %d out of range 0..%d - row skipped", id, WF_RARITY_MAX - 1)
		return
	}
	WfField(line, 1, g_szRarName[id], charsmax(g_szRarName[]))
	new col[24]
	WfField(line, 2, col, charsmax(col))
	new r, g, b
	if (parse(col, r, g, b) >= 3)
	{
		g_iRarColor[id][0] = clamp(r, 0, 255)
		g_iRarColor[id][1] = clamp(g, 0, 255)
		g_iRarColor[id][2] = clamp(b, 0, 255)
	}
	else
	{
		g_iRarColor[id][0] = 200
		g_iRarColor[id][1] = 220
		g_iRarColor[id][2] = 255
	}
	g_iRarWeight[id] = max(0, WfFieldInt(line, 3, 0))
	if (id + 1 > g_iRarCount)
		g_iRarCount = id + 1
}

parseOrnament(const line[])
{
	new id = WfFieldInt(line, 0, 0)
	if (id < 1 || id > WF_MAX_ORNAMENTS)
	{
		log_amx("[WF] [ornament] id %d out of range 1..%d - row skipped", id, WF_MAX_ORNAMENTS)
		return
	}
	WfField(line, 1, g_szOrnName[id], charsmax(g_szOrnName[]))
	g_iOrnRarity[id] = clamp(WfFieldInt(line, 2, 0), 0, WF_RARITY_MAX - 1)
	g_iOrnSet[id] = clamp(WfFieldInt(line, 3, 0), 0, WF_MAX_SETS)
	if (!g_szOrnName[id][0])
		formatex(g_szOrnName[id], charsmax(g_szOrnName[]), "Ornament %d", id)
	if (id > g_iOrnCount)
		g_iOrnCount = id
}

parseSet(const line[])
{
	new id = WfFieldInt(line, 0, 0)
	if (id < 1 || id > WF_MAX_SETS)
	{
		log_amx("[WF] [set] id %d out of range 1..%d - row skipped", id, WF_MAX_SETS)
		return
	}
	WfField(line, 1, g_szSetName[id], charsmax(g_szSetName[]))
	WfField(line, 2, g_szSetTitle[id], charsmax(g_szSetTitle[]))
	g_iSetSnow[id] = max(0, WfFieldInt(line, 3, 0))
	if (!g_szSetName[id][0])
		formatex(g_szSetName[id], charsmax(g_szSetName[]), "Set %d", id)
	if (id > g_iSetCount)
		g_iSetCount = id
}

parseAdvent(const line[])
{
	new day = WfFieldInt(line, 0, 0)
	if (day < 1 || day > WF_MAX_ADVENT)
	{
		log_amx("[WF] [advent] day %d out of range 1..%d - row skipped", day, WF_MAX_ADVENT)
		return
	}
	new type = WfRewardFromName(WfFieldStr(line, 1))
	new rid = resolveRid(type, WfFieldInt(line, 2, 0), WfFieldInt(line, 3, 0))
	if (!WfRewardUsable(type, rid))
	{
		log_amx("[WF] [advent] day %d has an unusable reward - row skipped", day)
		return
	}
	g_iAdvType[day] = type
	g_iAdvRid[day] = rid
	if (day > g_iAdvCount)
		g_iAdvCount = day
}

parsePass(const line[])
{
	new tier = WfFieldInt(line, 0, 0)
	if (tier < 1 || tier > WF_MAX_TIERS)
	{
		log_amx("[WF] [pass] tier %d out of range 1..%d - row skipped", tier, WF_MAX_TIERS)
		return
	}
	g_iTierXp[tier] = max(0, WfFieldInt(line, 1, 0))
	// Later tiers must not go backwards, or a player would lose a tier on level
	// up and re-claim a reward key.
	if (tier > 1 && g_iTierXp[tier] <= g_iTierXp[tier - 1])
	{
		log_amx("[WF] [pass] tier %d xp %d is not above tier %d's %d - clamped",
			tier, g_iTierXp[tier], tier - 1, g_iTierXp[tier - 1])
		g_iTierXp[tier] = g_iTierXp[tier - 1] + 1
	}
	new type = WfRewardFromName(WfFieldStr(line, 2))
	if (WfRewardUsable(type, resolveRid(type, WfFieldInt(line, 3, 0), WfFieldInt(line, 4, 0))))
	{
		g_iTierType[tier] = type
		g_iTierRid[tier] = resolveRid(type, WfFieldInt(line, 3, 0), WfFieldInt(line, 4, 0))
	}
	else
	{
		if (type != WF_REWARD_NONE)
			log_amx("[WF] [pass] tier %d reward is unusable - tier pays nothing", tier)
		g_iTierType[tier] = WF_REWARD_NONE
		g_iTierRid[tier] = 0
	}
	if (tier > g_iTierCount)
		g_iTierCount = tier
}

parsePool(const line[])
{
	new rar = WfFieldInt(line, 0, -1)
	if (rar < 0 || rar >= WF_RARITY_MAX)
	{
		log_amx("[WF] [open] rarity %d out of range 0..%d - row skipped", rar, WF_RARITY_MAX - 1)
		return
	}
	if (g_iPoolCount[rar] >= WF_MAX_POOL)
	{
		log_amx("[WF] [open] rarity %d already has %d rows (cap) - row skipped", rar, WF_MAX_POOL)
		return
	}
	new type = WfRewardFromName(WfFieldStr(line, 1))
	if (type == WF_REWARD_NONE)
	{
		log_amx("[WF] [open] rarity %d row has no usable reward type - row skipped", rar)
		return
	}
	new slot = g_iPoolCount[rar]
	new base = WfFieldInt(line, 2, 0)
	new rmin = max(0, WfFieldInt(line, 3, 0))
	new rmax = max(rmin, WfFieldInt(line, 4, 0))
	new weight = max(0, WfFieldInt(line, 5, 0))
	g_iPoolType[rar][slot] = type
	g_iPoolRid[rar][slot] = resolveRid(type, base, rmax)
	g_iPoolMin[rar][slot] = (type == WF_REWARD_ORNAMENT || type == WF_REWARD_GIFT || type == WF_REWARD_TITLE) ? 0 : rmin
	g_iPoolMax[rar][slot] = (type == WF_REWARD_ORNAMENT || type == WF_REWARD_GIFT || type == WF_REWARD_TITLE) ? 0 : rmax
	g_iPoolWeight[rar][slot] = weight
	g_iPoolCount[rar]++
}

// [tree] style | name | slot | x | y
// The panel renders the tree from these coordinates (0..100 of the tree box);
// in game only the level, the filled count and the style name are read. A style
// is complete when all WF_TREE_SLOTS slots have a row.
parseTree(const line[])
{
	new style = WfFieldInt(line, 0, 0)
	if (style < 1 || style > WF_MAX_STYLES)
	{
		log_amx("[WF] [tree] style %d out of range 1..%d - row skipped", style, WF_MAX_STYLES)
		return
	}
	new name[24]
	WfField(line, 1, name, charsmax(name))
	if (name[0] && !g_szStyleName[style][0])
		copy(g_szStyleName[style], charsmax(g_szStyleName[]), name)

	new slot = WfFieldInt(line, 2, 0)
	if (slot < 1 || slot > WF_TREE_SLOTS)
	{
		log_amx("[WF] [tree] style %d slot %d out of range 1..%d - row skipped", style, slot, WF_TREE_SLOTS)
		return
	}
	g_iStyleX[style][slot] = clamp(WfFieldInt(line, 3, 0), 0, 100)
	g_iStyleY[style][slot] = clamp(WfFieldInt(line, 4, 0), 0, 100)
	if (style > g_iStyleCount)
		g_iStyleCount = style
}

// [visual] name | kind | asset | colour | scale | fallback
//
// The look of every prop, as ids. Phase 1 uses the sprite rows and resolves
// every model row to its fallback (no client asset); flipping a prop to a model
// is a config edit once downloads work. A visual this server cannot use is
// skipped at resolve time, not at parse time, because "usable" depends on
// wf_allow_models and on the file being on disk.
parseVisual(const line[])
{
	if (g_iVisCount >= WF_MAX_VISUALS)
	{
		log_amx("[WF] [visual] more than %d rows - extra rows ignored", WF_MAX_VISUALS)
		return
	}
	new name[32], kind[16]
	WfField(line, 0, name, charsmax(name))
	WfField(line, 1, kind, charsmax(kind))
	if (!name[0] || !kind[0])
	{
		log_amx("[WF] [visual] row without a name or kind - skipped")
		return
	}

	new idx = g_iVisCount
	copy(g_szVisName[idx], charsmax(g_szVisName[]), name)
	if (equali(kind, "model_present") || equali(kind, "model"))
		g_iVisKind[idx] = WF_VISUAL_MODEL
	else
		g_iVisKind[idx] = WF_VISUAL_SPRITE

	WfField(line, 2, g_szVisAsset[idx], charsmax(g_szVisAsset[]))
	WfField(line, 3, g_szVisColour[idx], charsmax(g_szVisColour[]))
	if (equal(g_szVisColour[idx], "-"))
		g_szVisColour[idx][0] = 0

	new scale[12]
	WfField(line, 4, scale, charsmax(scale))
	g_fVisScale[idx] = floatmax(0.1, floatmin(4.0, scale[0] ? str_to_float(scale) : 1.0))

	new fb[32]
	WfField(line, 5, fb, charsmax(fb))
	if (equal(fb, "-"))
		fb[0] = 0
	copy(g_szVisFallback[idx], charsmax(g_szVisFallback[]), fb)

	g_iVisCount++
}

// [spins] free_per_day = N, enabled = 0/1
// The free spin the wheel (workstream 13) expects every player to have. The
// prizes and the wheel are not here: this is one counter and one daily grant.
parseSpins(const line[])
{
	new eq = contain(line, "=")
	if (eq < 1)
		return
	new key[24], val[16]
	copy(key, charsmax(key), line)
	key[eq] = 0
	trim(key)
	strtolower(key)
	copy(val, charsmax(val), line[eq + 1])
	trim(val)

	if (equal(key, "free_per_day"))
		g_iSpinsFree = clamp(str_to_num(val), 0, 10)
	else if (equal(key, "enabled"))
		g_bSpinsEnabled = (str_to_num(val) != 0) ? true : false
}

// [props] slot = visual name (key = value)
parseProps(const line[])
{
	new eq = contain(line, "=")
	if (eq < 1)
		return
	new key[32], val[32]
	copy(key, charsmax(key), line)
	key[eq] = 0
	trim(key)
	strtolower(key)
	copy(val, charsmax(val), line[eq + 1])
	trim(val)

	for (new i = 0; i < WF_PROP_SLOTS; i++)
	{
		if (equali(key, g_szPropSlot[i]))
		{
			copy(g_szPropVisual[i], charsmax(g_szPropVisual[]), val)
			return
		}
	}
	log_amx("[WF] [props] unknown slot '%s' - ignored (known: present_common, present_uncommon, present_rare, pouch, tree, c4)", key)
}

// Every prop is resolved once, after the file is read: this is where the
// "models are gated" rule is applied, so no caller ever has to know. Unresolved
// slots are summarised in one line instead of one warning each - in Phase 1 the
// tree and c4 props legitimately have no drawable visual yet (both are models
// with no sprite fallback), and a boot log full of warnings for those would
// train everyone to ignore the line that matters.
WfResolveAllVisuals()
{
	new drawn = 0, missing = 0
	new list[96]
	list[0] = 0

	for (new i = 0; i < WF_PROP_SLOTS; i++)
	{
		g_szPropResolved[i][0] = 0
		if (!g_szPropVisual[i][0])
			continue

		WfResolveVisual(g_szPropVisual[i], g_szPropResolved[i], charsmax(g_szPropResolved[]))

		if (!g_szPropResolved[i][0])
		{
			missing++
			if (list[0])
				add(list, charsmax(list), ", ")
			add(list, charsmax(list), g_szPropSlot[i])
			continue
		}

		drawn++
		if (!equali(g_szPropResolved[i], g_szPropVisual[i]))
		{
			new why[40]
			WfWhyFallback(g_szPropVisual[i], why, charsmax(why))
			log_amx("[WF] prop '%s': visual '%s' -> '%s' (%s)",
				g_szPropSlot[i], g_szPropVisual[i], g_szPropResolved[i], why)
		}
		else
		{
			// The decision, said out loud per prop: a model was drawn (with the
			// file that backs it) or a sprite was. Without this line an operator
			// cannot tell "the model is on" from "the fallback happens to look
			// identical in the log".
			new idx = WfFindVisual(g_szPropResolved[i])
			if (idx >= 0 && g_iVisKind[idx] == WF_VISUAL_MODEL)
				log_amx("[WF] prop '%s': draws model '%s'", g_szPropSlot[i], g_szVisAsset[idx])
			else if (idx >= 0)
				log_amx("[WF] prop '%s': draws sprite '%s'", g_szPropSlot[i], g_szVisAsset[idx])
		}
	}

	if (missing)
		log_amx("[WF] %d of %d prop slot(s) drawable now; waiting for downloads: %s",
			drawn, WF_PROP_SLOTS, list)
}

// Walk the fallback chain (bounded to 4 hops) until a visual this server can
// use. Returns "" when nothing in the chain is usable.
stock WfResolveVisual(const name[], out[], len)
{
	new cur[32]
	copy(cur, charsmax(cur), name)
	out[0] = 0
	for (new hop = 0; hop < 4 && cur[0]; hop++)
	{
		new idx = WfFindVisual(cur)
		if (idx < 0)
		{
			log_amx("[WF] [visual] '%s' is not defined in the [visual] section", cur)
			return
		}
		if (WfVisualUsable(idx))
		{
			copy(out, len, g_szVisName[idx])
			return
		}
		copy(cur, charsmax(cur), g_szVisFallback[idx])
	}
}

stock WfFindVisual(const name[])
{
	for (new i = 0; i < g_iVisCount; i++)
		if (equali(g_szVisName[i], name))
			return i
	return -1
}

// Why a configured visual did not draw, in the operator's words.
//
// The old message said "the configured one needs a download" for every reason,
// and that sentence is what hid the real bug for two playtests: with
// wf_allow_models 0, or with a file on disk that the working directory could not
// see, the log told the reader the model simply had to be shipped.
stock WfWhyFallback(const name[], out[], len)
{
	if (len > 0)
		out[0] = 0

	new idx = WfFindVisual(name)
	if (idx < 0)
	{
		copy(out, len, "not defined in [visual]")
		return
	}
	if (!g_szVisAsset[idx][0])
	{
		copy(out, len, "no asset column")
		return
	}
	if (g_iVisKind[idx] == WF_VISUAL_MODEL)
	{
		if (!WfModelsAllowed())
		{
			copy(out, len, "wf_allow_models is 0")
			return
		}
		if (!WfFileCstrike(g_szVisAsset[idx]))
		{
			copy(out, len, "the file is not on this host")
			return
		}
	}
	copy(out, len, "unusable")
}

// Every root a model visual may live under, in test order. The working
// directory differs by host: the shipped harness starts hlds from the GAME ROOT
// (`cd $SERVER`, cs16-linux-base docker/harness/boot.sh), which is why every
// other file these plugins open is spelled "addons/amxmodx/...". A model visual
// is spelled mod-relative ("models/winterfest/present.mdl"), so BOTH have to be
// tested - testing only the mod-relative one answered "no" on the harness and
// silently turned every present into its glow (the owner's report).
new const g_szCstrikeRoots[][] =
{
	"",
	"cstrike/"
}

stock bool:WfFileCstrike(const relPath[])
{
	new path[128]
	for (new i = 0; i < sizeof(g_szCstrikeRoots); i++)
	{
		formatex(path, charsmax(path), "%s%s", g_szCstrikeRoots[i], relPath)
		if (file_exists(path))
			return true
	}
	return false
}

// The model-usable decision: the cvar both plugins register, default 1.
//
// It is read live (never cached in plugin_cfg) on purpose: `wf_reload` and
// `wf_gifts_reload` must be able to flip it without a map change, and the
// startup resolve in plugin_cfg runs before the server has exec'd the .cfg that
// sets it - which is why the boot log used to say "models gated" while
// `wf_allow_models` answered 1 two seconds later.
stock WfModelsAllowed()
{
	return get_cvar_num("wf_allow_models") ? true : false
}

// A sprite is assumed to be stock (every CS client and every server content
// pack has sprites/glow01.spr, and the module precaches it unconditionally); a
// model needs the cvar AND the file, because precaching a missing model is how a
// map ends up with an ERROR entity nobody notices.
stock bool:WfVisualUsable(idx)
{
	if (idx < 0 || idx >= g_iVisCount)
		return false
	if (!g_szVisAsset[idx][0])
		return false
	if (g_iVisKind[idx] == WF_VISUAL_MODEL)
	{
		if (!WfModelsAllowed())
			return false
		return WfFileCstrike(g_szVisAsset[idx]) ? true : false
	}
	return true
}

// [entitlement] product_id | display name | kind
//
// The catalogue of things a player can OWN (owner decision §6.5, §7). Gameplay
// only ever asks "does this player own product X"; the panel sells it, an admin
// grants it, and later Stripe fulfils an order into the same table. Putting the
// ids here means wf_has_entitlement() cannot be called with a typo that silently
// answers "no" forever.
parseEntitlement(const line[])
{
	if (g_iEntCount >= WF_MAX_PRODUCTS)
	{
		log_amx("[WF] [entitlement] more than %d products - extra rows ignored", WF_MAX_PRODUCTS)
		return
	}
	new id[40]
	WfField(line, 0, id, charsmax(id))
	if (!id[0])
	{
		log_amx("[WF] [entitlement] row without a product id - skipped")
		return
	}
	copy(g_szProdId[g_iEntCount], charsmax(g_szProdId[]), id)
	WfField(line, 1, g_szProdLabel[g_iEntCount], charsmax(g_szProdLabel[]))
	if (!g_szProdLabel[g_iEntCount][0])
		copy(g_szProdLabel[g_iEntCount], charsmax(g_szProdLabel[]), id)
	WfField(line, 2, g_szProdKind[g_iEntCount], charsmax(g_szProdKind[]))
	g_iEntCount++
}

// [pass_premium] tier | reward kind | id | amount
//
// The paid track (owner decision §6.2). It reuses the [pass] thresholds: tier n
// of the premium track unlocks at the same XP as tier n of the free track, and
// its claim key is separate (`pass:<n>:premium`), so the two tracks can never
// pay each other's reward. Nothing here is granted without the entitlement.
parsePassPremium(const line[])
{
	new tier = WfFieldInt(line, 0, 0)
	if (tier < 1 || tier > WF_MAX_TIERS)
	{
		log_amx("[WF] [pass_premium] tier %d out of range 1..%d - row skipped", tier, WF_MAX_TIERS)
		return
	}
	new type = WfRewardFromName(WfFieldStr(line, 1))
	new rid = resolveRid(type, WfFieldInt(line, 2, 0), WfFieldInt(line, 3, 0))
	if (!WfRewardUsable(type, rid))
	{
		log_amx("[WF] [pass_premium] tier %d has an unusable reward - row skipped", tier)
		return
	}
	g_iPremType[tier] = type
	g_iPremRid[tier] = rid
}

stock WfPremiumRowCount()
{
	new n = 0
	for (new t = 1; t <= WF_MAX_TIERS; t++)
		if (g_iPremType[t] != WF_REWARD_NONE)
			n++
	return n
}

// A `[advent]`/`[pass]`/`[open]` row names a reward kind by name and then gives
// an id and an amount; snow and pass XP carry the amount as the "reward id",
// the other kinds carry a catalogue id. Doing the mapping in ONE place means the
// native's (type, id) contract stays the one documented in winterfest.inc.
stock resolveRid(type, id, amount)
{
	switch (type)
	{
		case WF_REWARD_SNOWFLAKES, WF_REWARD_PASS_XP, WF_REWARD_SPINS, WF_REWARD_COINS:
			return max(0, amount)
		case WF_REWARD_GIFT:
		{
			// A present reward names the rarity of the present it hands out.
			return clamp(id, 0, WF_RARITY_MAX - 1)
		}
		default:
			return id
	}
	return 0
}

stock WfRewardFromName(const name[])
{
	if (equal(name, "gingerbread") || equal(name, "gb")
		|| equal(name, "snow") || equal(name, "snowflakes"))  // last two: legacy ini rows
		return WF_REWARD_SNOWFLAKES
	if (equal(name, "ornament"))
		return WF_REWARD_ORNAMENT
	if (equal(name, "gift") || equal(name, "present"))
		return WF_REWARD_GIFT
	if (equal(name, "pass") || equal(name, "xp"))
		return WF_REWARD_PASS_XP
	if (equal(name, "spins") || equal(name, "spin"))
		return WF_REWARD_SPINS
	if (equal(name, "coins") || equal(name, "coin"))
		return WF_REWARD_COINS
	if (equal(name, "title"))
		return WF_REWARD_TITLE
	return WF_REWARD_NONE
}

// Field as a string, in one call, for the reward-kind column.
stock WfFieldStr(const line[], index)
{
	new buf[32]
	WfField(line, index, buf, charsmax(buf))
	return buf
}

// "2026-12-01" -> 20261201, so the date window is one integer comparison.
stock WfDateKey(const s[])
{
	new out = 0, digits = 0
	for (new i = 0; s[i]; i++)
	{
		if (s[i] < '0' || s[i] > '9')
			continue
		out = out * 10 + (s[i] - '0')
		digits++
		if (digits >= 8)
			break
	}
	return out
}

// Europe/Paris is the single clock (owner decision §6.4 final): the daily spin,
// the Advent unlock and the pass rollover all read the SERVER's local date. The
// host must run TZ=Europe/Paris, and this line makes a wrong host visible in the
// boot log instead of showing up later as reset times that are an hour or two
// off. It is a diagnostic, not a gate - nothing behaves differently because of
// the number it prints.
WfLogClock()
{
	new local[32]
	get_time("%Y-%m-%d %H:%M", local, charsmax(local))
	new epoch = get_systime()
	new utc_hour = (epoch / 3600) % 24
	new hour[8]
	get_time("%H", hour, charsmax(hour))
	new local_hour = str_to_num(hour)
	new offset = local_hour - utc_hour
	if (offset < -12) offset += 24
	if (offset > 12) offset -= 24
	if (offset >= 0)
		log_amx("[WF] clock: local %s, UTC+%d (Europe/Paris is +1 in winter, +2 in summer - the host must run TZ=Europe/Paris)",
			local, offset)
	else
		log_amx("[WF] clock: local %s, UTC%d (Europe/Paris is +1 in winter, +2 in summer - the host must run TZ=Europe/Paris)",
			local, offset)
}

stock WfToday()
{
	new buf[16]
	get_time("%Y%m%d", buf, charsmax(buf))
	return str_to_num(buf)
}

stock WfDayOfMonth()
{
	new buf[8]
	get_time("%d", buf, charsmax(buf))
	return str_to_num(buf)
}

bool:WfSeasonActive()
{
	if (!g_bCfgOk || !g_bSeasonEnabled)
		return false
	if (get_pcvar_num(g_pEnabled) == 0)
		return false
	if (get_pcvar_num(g_pForceOpen) != 0)
		return true

	new today = WfToday()
	if (g_iDateStart && today < g_iDateStart)
		return false
	if (g_iDateEnd && today > g_iDateEnd)
		return false
	return true
}

// ============================================================
// Spins: the free daily spin (workstream 13 owns the wheel)
// ============================================================
// The state only: a balance, one free spin per player per day, and a consume that
// refuses at zero. The grant is idempotent through the same ledger as an advent
// day - the claim key is `spin#<YYYYMMDD>`, which the core hashes together with
// the season year, the authid and the player's reset epoch. Logging in five times
// in a day pays once; a reconnect on the next day pays again; a reset re-opens
// today's spin like it re-opens everything else.
WfDailySpin(id)
{
	if (!g_bSpinsEnabled || g_iSpinsFree <= 0 || !WfReady(id))
		return

	// No season gate: a spin is not seasonal content, and a player who logs in on
	// 1 December at 00:01 should not be told to come back.
	new day[12]
	get_time("%Y%m%d", day, charsmax(day))
	new key[32]
	formatex(key, charsmax(key), "spin#%s", day)

	// The claim check is the whole idempotency: write-then-pay, like every other
	// reward, so two logins in the same second pay once.
	if (WfClaimExists(id, key))
		return
	WfClaimMark(id, key)

	WfAddSpins(id, g_iSpinsFree)
	log_amx("[WF] daily spin granted to id %d (+%d, balance %d)", id, g_iSpinsFree, g_iSpins[id])
}

// ============================================================
// Persistence: one key helper, one save path
// ============================================================
stock bool:WfInRange(id)
{
	return (id > 0 && id <= MaxClients) ? true : false
}

stock bool:WfReady(id)
{
	if (!WfInRange(id))
		return false
	return g_bLoaded[id]
}

// Every key goes through here. Shape:
//
//     wf_<base>_s<season year>#<authid with ':' replaced by '_'>
//
// Season stamping mirrors BpCursorKey in battlepass_core: bumping `year` in the
// ini opens a fresh, empty season without deleting one byte of last year.
stock bool:WfKey(id, key[], len, const base[])
{
	key[0] = 0
	new auth[40]
	get_user_authid(id, auth, charsmax(auth))
	if (!auth[0])
		return false
	for (new i = 0; auth[i]; i++)
		if (auth[i] == ':')
			auth[i] = '_'

	formatex(key, len, "wf_%s_s%d#%s", base, g_iSeasonYear, auth)
	return WfKeyOk(key)
}

// A key that is too long is refused, never truncated (two truncated keys would
// silently alias). Returns false so the caller can log and skip the write.
stock bool:WfKeyOk(const key[])
{
	if (strlen(key) >= MAX_KEY)
	{
		log_amx("[WF] ERROR: vault key too long (%d >= %d): %s", strlen(key), MAX_KEY, key)
		return false
	}
	return true
}

WfClearMem(id)
{
	g_iGb[id] = 0
	g_iSpins[id] = 0
	g_iPending[id] = 0
	g_iPassXp[id] = 0
	g_iTree[id] = 1
	g_iEpoch[id] = 0
	g_iGiftSeq[id] = 0
	g_szGifts[id][0] = 0
	g_szOrn[id][0] = 0
	g_szAdv[id][0] = 0
	g_szTitles[id][0] = 0
	g_szEnts[id][0] = 0
	g_szPlace[id][0] = 0
	g_iStyle[id] = 1
	g_bLoaded[id] = false
	g_bDirty[id] = false
	g_bInTierSync[id] = false
}

stock WfTouch(id)
{
	g_bDirty[id] = true
}

WfLoad(id)
{
	WfClearMem(id)
	// Marked loaded even when the vault is closed: the player then plays with
	// in-memory state instead of every native refusing. The vault failure was
	// already logged loudly once at startup.
	g_bLoaded[id] = true

	if (g_Vault != INVALID_HANDLE)
	{
		// Canonical key is `gb`; a record written before the rename still says
		// `snow`, so read it as a fallback instead of zeroing the balance.
		new gb = WfLoadInt(id, "gb", -1)
		if (gb < 0)
			gb = WfLoadInt(id, "snow", 0)
		g_iGb[id] = clamp(gb, 0, 2000000000)
		g_iPassXp[id] = max(0, WfLoadInt(id, "pass", 0))
		g_iTree[id] = clamp(WfLoadInt(id, "tree", 1), 1, WF_MAX_SETS + 1)
		g_iEpoch[id] = max(0, WfLoadInt(id, "epoch", 0))
		g_iGiftSeq[id] = max(0, WfLoadInt(id, "gseq", 0))
		g_iStyle[id] = clamp(WfLoadInt(id, "style", 1), 1, WF_MAX_STYLES)
		WfLoadStr(id, "gifts", g_szGifts[id], charsmax(g_szGifts[]))
		WfLoadStr(id, "orn", g_szOrn[id], charsmax(g_szOrn[]))
		WfLoadStr(id, "advent", g_szAdv[id], charsmax(g_szAdv[]))
		WfLoadStr(id, "titles", g_szTitles[id], charsmax(g_szTitles[]))
		WfLoadStr(id, "slots", g_szPlace[id], charsmax(g_szPlace[]))
		WfLoadStr(id, "ents", g_szEnts[id], charsmax(g_szEnts[]))
		g_iSpins[id] = max(0, WfLoadInt(id, "spins", 0))
		g_iPending[id] = max(0, WfLoadInt(id, "pending", 0))
	}

	// Repair pass. Both are idempotent: an already-paid tier or set has its
	// claim key and is skipped, so logging in twice never pays twice.
	WfSyncTiers(id, false)
	WfSyncSets(id, false, false)
	WfDailySpin(id)

	log_amx("[WF] loaded id %d: %d gb, %d spins, %d gifts, %d ornaments, tree %d, pass xp %d",
		id, g_iGb[id], g_iSpins[id], WfGiftCount(id), WfOrnOwnedCount(id), g_iTree[id], g_iPassXp[id])
}

// THE save path. Every persisted field is written here and nowhere else, so a
// new field is one line in one function and a partial save cannot exist.
stock bool:WfSave(id, bool:force)
{
	if (g_Vault == INVALID_HANDLE || !WfInRange(id) || !g_bLoaded[id])
		return false
	if (!g_bDirty[id] && !force)
		return false

	new ok = 1
	if (!WfSaveInt(id, "gb", g_iGb[id])) ok = 0
	if (!WfSaveInt(id, "pass", g_iPassXp[id])) ok = 0
	if (!WfSaveInt(id, "tree", g_iTree[id])) ok = 0
	if (!WfSaveInt(id, "epoch", g_iEpoch[id])) ok = 0
	if (!WfSaveInt(id, "gseq", g_iGiftSeq[id])) ok = 0
	if (!WfSaveInt(id, "spins", g_iSpins[id])) ok = 0
	if (!WfSaveInt(id, "pending", g_iPending[id])) ok = 0
	if (!WfSaveInt(id, "style", g_iStyle[id])) ok = 0
	if (!WfSaveStr(id, "gifts", g_szGifts[id])) ok = 0
	if (!WfSaveStr(id, "orn", g_szOrn[id])) ok = 0
	if (!WfSaveStr(id, "advent", g_szAdv[id])) ok = 0
	if (!WfSaveStr(id, "titles", g_szTitles[id])) ok = 0
	if (!WfSaveStr(id, "slots", g_szPlace[id])) ok = 0
	if (!WfSaveStr(id, "ents", g_szEnts[id])) ok = 0

	if (!ok)
		log_amx("[WF] WARNING: at least one nvault_set failed for id %d - record may be partial", id)

	g_bDirty[id] = false
	return true
}

stock bool:WfSaveInt(id, const base[], value)
{
	new key[MAX_KEY], val[16]
	if (!WfKey(id, key, charsmax(key), base))
		return false
	formatex(val, charsmax(val), "%d", value)
	return nvault_set(g_Vault, key, val) ? true : false
}

stock bool:WfSaveStr(id, const base[], const value[])
{
	new key[MAX_KEY]
	if (!WfKey(id, key, charsmax(key), base))
		return false
	return nvault_set(g_Vault, key, value) ? true : false
}

stock WfLoadInt(id, const base[], fallback)
{
	new key[MAX_KEY], val[16]
	if (!WfKey(id, key, charsmax(key), base))
		return fallback
	if (!nvault_get(g_Vault, key, val, charsmax(val)))
		return fallback
	return str_to_num(val)
}

stock WfLoadStr(id, const base[], out[], len)
{
	new key[MAX_KEY], val[320]
	out[0] = 0
	if (!WfKey(id, key, charsmax(key), base))
		return
	if (!nvault_get(g_Vault, key, val, charsmax(val)))
		return
	copy(out, len, val)
}

// ============================================================
// The claim ledger
// ============================================================
// Claim keys are the idempotency record: one nvault key per reward that must
// pay at most once. The caller's key is hashed (CRC32) and the player's
// `epoch` is part of the stored key, so wf_reset re-opens every claim without
// having to enumerate (and therefore without a scan of the vault).
//
// Trade-off, on purpose: the key is written BEFORE the reward is applied. A
// crash in the microseconds between the two loses that one reward; it can never
// pay twice. Fail closed.
stock bool:WfClaimKey(id, const claim[], key[], len)
{
	key[0] = 0
	new auth[40]
	get_user_authid(id, auth, charsmax(auth))
	if (!auth[0] || !claim[0])
		return false
	for (new i = 0; auth[i]; i++)
		if (auth[i] == ':')
			auth[i] = '_'

	new digest[16]
	hash_string(claim, Hash_Crc32, digest, charsmax(digest))
	formatex(key, len, "wf_claim_s%d#%s#e%d#%s", g_iSeasonYear, auth, g_iEpoch[id], digest)
	return WfKeyOk(key)
}

stock bool:WfClaimExists(id, const claim[])
{
	if (g_Vault == INVALID_HANDLE)
		return false
	new key[MAX_KEY], val[8]
	if (!WfClaimKey(id, claim, key, charsmax(key)))
		return false
	return nvault_get(g_Vault, key, val, charsmax(val)) ? true : false
}

stock WfClaimMark(id, const claim[])
{
	if (g_Vault == INVALID_HANDLE)
		return
	new key[MAX_KEY]
	if (!WfClaimKey(id, claim, key, charsmax(key)))
		return
	if (!nvault_set(g_Vault, key, "1"))
		log_amx("[WF] WARNING: could not write claim key for id %d (%s)", id, claim)
}

// ============================================================
// The grant path
// ============================================================
// wf_grant's implementation and the only function that can move currency,
// inventory or XP.
//
//   * claim[0] != ""  -> a reward: the claim key is checked, then written, then
//                        the reward is applied. Second call = WF_GRANT_DUPLICATE.
//   * claim[0] == ""  -> an operator action (wf_give): applied every time and
//                        logged as such. Deliberate: two identical wf_give lines
//                        mean two grants.
WfGrantIdem(id, type, rid, const claim[], bool:announce)
{
	if (!WfReady(id))
		return WF_GRANT_NOTLOADED

	new bool:has_claim = (claim[0] != 0) ? true : false
	if (has_claim)
	{
		if (WfClaimExists(id, claim))
			return WF_GRANT_DUPLICATE
		// Written first: a reconnect, a retry or a second code path can no
		// longer reach the apply below.
		WfClaimMark(id, claim)
	}
	else
	{
		new admin[40]
		get_user_name(0, admin, charsmax(admin))
		log_amx("[WF] operator grant: id %d type %d rid %d (no claim key)", id, type, rid)
	}

	new bool:ok2 = WfApplyReward(id, type, rid, announce)
	log_amx("[WF] DIAGT grant id %d type %d rid %d claim '%s' apply=%d", id, type, rid, claim, ok2 ? 1 : 0)
	if (!ok2)
		return has_claim ? WF_GRANT_DUPLICATE : WF_GRANT_INVALID

	WfTouch(id)
	return WF_GRANT_OK
}

// The one place a reward becomes state. Returns true when something changed
// (so the caller knows whether to announce and whether to keep the claim).
bool:WfApplyReward(id, type, rid, bool:announce)
{
	if (!WfReady(id))
		return false

	new text[160]
	new bool:changed = false

	switch (type)
	{
		case WF_REWARD_SNOWFLAKES:
		{
			if (rid <= 0)
				return false
			WfAddGb(id, rid)
			formatex(text, charsmax(text), "+%d %s  (balance %d)", rid, WF_CURRENCY_NAME, g_iGb[id])
			changed = true
		}
		case WF_REWARD_ORNAMENT:
		{
			if (rid < 1 || rid > g_iOrnCount || g_iOrnRarity[rid] < 0)
				return false
			if (WfListHas(g_szOrn[id], rid))
				return false
			if (!WfListAdd(g_szOrn[id], charsmax(g_szOrn[]), rid))
			{
				log_amx("[WF] ornament list full for id %d - ornament %d not granted", id, rid)
				return false
			}
			formatex(text, charsmax(text), "ornament: ^3%s^1 (%s)",
				g_szOrnName[rid], g_szRarName[clamp(g_iOrnRarity[rid], 0, WF_RARITY_MAX - 1)])
			changed = true
			// A new ornament can complete a set; that pays a title + snow and
			// grows the tree. Runs after the text so the order in chat reads
			// "ornament first, then the set".
			if (announce)
				WfSay(id, text)
			WfSyncSets(id, announce, true)
			return true
		}
		case WF_REWARD_GIFT:
		{
			if (rid < 0 || rid >= g_iRarCount)
				return false
			if (WfGiftCount(id) >= WF_MAX_GIFTS)
			{
				// A full bag used to SWALLOW the present, and the caller was told
				// "false" - so a wheel sector, an advent day or a killed reindeer
				// paid nothing and the claim key had already been written: the
				// reward was gone for good. Pay the present's GingerBread value
				// instead (the same substitution the ornament branch already makes
				// when the collection is complete), so a full bag can never make a
				// reward a dud.
				new alt = 25 + rid * 25
				WfAddGb(id, alt)
				formatex(text, charsmax(text),
					"bag full - your ^3%s^1 present was paid as +%d %s (balance %d)",
					g_szRarName[clamp(rid, 0, WF_RARITY_MAX - 1)], alt, WF_CURRENCY_NAME, g_iGb[id])
				WfSay(id, text)
				log_amx("[WF] id %d bag full (%d) - present rarity %d paid as %d gb",
					id, WfGiftCount(id), rid, alt)
				return true
			}
			g_iGiftSeq[id]++
			new buf[16]
			formatex(buf, charsmax(buf), "%d:%d", g_iGiftSeq[id], rid)
			new len_before = strlen(g_szGifts[id])
			if (!g_szGifts[id][0])
			{
				copy(g_szGifts[id], charsmax(g_szGifts[]), buf)
			}
			else
			{
				add(g_szGifts[id], charsmax(g_szGifts[]), ",")
				add(g_szGifts[id], charsmax(g_szGifts[]), buf)
			}
			if (strlen(g_szGifts[id]) == len_before)
			{
				// The bag has room by COUNT but not by BYTES: one more entry would
				// have been truncated off the end, which reads back as a present
				// that never existed. Pay it as GingerBread instead of losing it.
				new alt = 25 + clamp(rid, 0, WF_RARITY_MAX - 1) * 25
				WfAddGb(id, alt)
				log_amx("[WF] id %d bag string full - present rarity %d paid as %d gb", id, rid, alt)
				return true
			}
			formatex(text, charsmax(text), "a ^3%s^1 present (you carry %d)",
				g_szRarName[rid], WfGiftCount(id))
			changed = true
		}
		case WF_REWARD_PASS_XP:
		{
			if (rid <= 0)
				return false
			new before = g_iPassXp[id]
			WfAddPassXp(id, rid)
			if (g_iPassXp[id] == before)
				return false
			formatex(text, charsmax(text), "+%d winter pass XP  (total %d)", g_iPassXp[id] - before, g_iPassXp[id])
			changed = true
			if (announce)
				WfSay(id, text)
			WfSyncTiers(id, announce)
			return true
		}
		case WF_REWARD_SPINS:
		{
			if (rid <= 0)
				return false
			WfAddSpins(id, rid)
			formatex(text, charsmax(text), "+%d spin%s  (balance %d)", rid, (rid == 1) ? "" : "s", g_iSpins[id])
			changed = true
		}
		case WF_REWARD_COINS:
		{
			// Coins belong to The BattlePass. Pay them through its own
			// once-only path (so its ledger also has the award), and fall back to
			// GingerBread if that plugin is not loaded - a premium tier must never
			// pay nothing.
			if (rid <= 0)
				return false
			if (LibraryExists("menabp", LibType_Library))
			{
				new award[64]
				formatex(award, charsmax(award), "wf:coins:%d", rid)
				menabp_add_coins_once(id, rid, award)
				formatex(text, charsmax(text), "+%d Coins", rid)
			}
			else
			{
				WfAddGb(id, rid)
				formatex(text, charsmax(text), "+%d %s (no BattlePass loaded - paid as the soft currency)", rid, WF_CURRENCY_NAME)
			}
			changed = true
		}
		case WF_REWARD_TITLE:
		{
			if (rid < 1 || rid > g_iSetCount)
				return false
			if (!g_szSetTitle[rid][0] || WfListHas(g_szTitles[id], rid))
				return false
			if (!WfListAdd(g_szTitles[id], charsmax(g_szTitles[]), rid))
			{
				log_amx("[WF] title list full for id %d - set %d title not granted", id, rid)
				return false
			}
			formatex(text, charsmax(text), "collector title unlocked: ^3%s^1", g_szSetTitle[rid])
			changed = true
		}
		default:
			return false
	}

	if (changed && announce)
		WfSay(id, text)
	return changed
}

stock WfAddGb(id, amount)
{
	log_amx("[WF] DIAGT add gb id %d +%d -> %d", id, amount, g_iGb[id])
	if (amount <= 0)
		return
	// 32-bit cells: clamping keeps a display or a spend check from going
	// negative, which is how wallets get "free" purchases.
	if (g_iGb[id] > 2000000000 - amount)
		g_iGb[id] = 2000000000
	else
		g_iGb[id] += amount
	WfTouch(id)
}

stock WfAddSpins(id, amount)
{
	if (amount <= 0)
		return
	if (g_iSpins[id] > 1000000 - amount)
		g_iSpins[id] = 1000000
	else
		g_iSpins[id] += amount
	WfTouch(id)
}

stock WfAddPassXp(id, amount)
{
	new maxxp = (g_iTierCount > 0) ? g_iTierXp[g_iTierCount] : 0
	new before = g_iPassXp[id]
	g_iPassXp[id] = min(g_iPassXp[id] + amount, maxxp)
	if (g_iPassXp[id] < 0)
		g_iPassXp[id] = 0
	if (g_iPassXp[id] != before)
		WfTouch(id)
}

stock WfTierFromXp(xp)
{
	new tier = 1
	for (new t = 1; t <= g_iTierCount; t++)
	{
		if (xp >= g_iTierXp[t])
			tier = t
		else
			break
	}
	return tier
}

// Is (type, rid) a reward this config can pay? Kept in one place because the
// valid range differs per kind: a present reward's id is a RARITY, and rarity 0
// is a real value, so the generic "rid > 0" test would throw away every
// common-present reward (this was caught by the harness: advent day 3).
stock bool:WfRewardUsable(type, rid)
{
	switch (type)
	{
		case WF_REWARD_SNOWFLAKES, WF_REWARD_PASS_XP, WF_REWARD_SPINS, WF_REWARD_COINS:
			return rid > 0 ? true : false
		case WF_REWARD_GIFT:
			return (rid >= 0 && rid < WF_RARITY_MAX) ? true : false
		case WF_REWARD_ORNAMENT:
			return rid > 0 ? true : false
		case WF_REWARD_TITLE:
			return rid > 0 ? true : false
	}
	return false
}

// A *promised* reward the player already owns would silently vanish: convert it
// to snow. Used by the pass tiers and the advent calendar (both are promises
// made by a config table), never by wf_grant_ornament - there "already owned" is
// the correct answer and the caller wants to know.
stock WfSubstituteOwned(id, &type, &rid)
{
	if (type != WF_REWARD_ORNAMENT)
		return
	if (rid < 1 || rid > g_iOrnCount)
		return
	if (!WfListHas(g_szOrn[id], rid))
		return
	type = WF_REWARD_SNOWFLAKES
	rid = 20 + clamp(g_iOrnRarity[rid], 0, WF_RARITY_MAX - 1) * 20
}

// Pays every tier the player has reached whose claim key is unspent. Bounded by
// g_iTierCount and idempotent, so it is safe to run on load, on XP gain and
// after a reset.
WfSyncTiers(id, bool:announce)
{
	if (!WfReady(id) || g_bInTierSync[id] || g_iTierCount <= 0)
		return
	g_bInTierSync[id] = true

	// Two tracks, two claim keys: pass:<t>:free and pass:<t>:premium. They can
	// never collide, and the premium one only ever runs for a player who owns the
	// premium product.
	new tier = WfTierFromXp(g_iPassXp[id])
	new bool:premium = WfEntHas(id, WF_PRODUCT_BP_PREMIUM)

	for (new t = 1; t <= tier; t++)
	{
		if (WfRewardUsable(g_iTierType[t], g_iTierRid[t]))
		{
			new key[32]
			formatex(key, charsmax(key), "pass:%d:free", t)
			new type = g_iTierType[t]
			new rid = g_iTierRid[t]
			WfSubstituteOwned(id, type, rid)
			if (WfGrantIdem(id, type, rid, key, announce) == WF_GRANT_OK && announce)
			{
				new line[96]
				formatex(line, charsmax(line), "winter pass tier %d reached", t)
				WfSay(id, line)
			}
		}

		if (!premium || !WfRewardUsable(g_iPremType[t], g_iPremRid[t]))
			continue

		new pkey[32]
		formatex(pkey, charsmax(pkey), "pass:%d:premium", t)
		new ptype = g_iPremType[t]
		new prid = g_iPremRid[t]
		WfSubstituteOwned(id, ptype, prid)
		if (WfGrantIdem(id, ptype, prid, pkey, announce) == WF_GRANT_OK && announce)
		{
			new line[96]
			formatex(line, charsmax(line), "premium tier %d reward claimed", t)
			WfSay(id, line)
		}
	}

	g_bInTierSync[id] = false
}

// Trees grow with completed sets, and a completed set pays its title and its
// bonus once (claim keys set#<s> / setbx#<s>).
WfSyncSets(id, bool:announce, bool:recompute_tree)
{
	if (!WfReady(id))
		return

	for (new s = 1; s <= g_iSetCount; s++)
	{
		if (g_iSetTotal[s] <= 0)
			continue
		if (WfSetOwned(id, s) < g_iSetTotal[s])
			continue

		if (g_szSetTitle[s][0])
		{
			new key[24]
			formatex(key, charsmax(key), "set#%d", s)
			WfGrantIdem(id, WF_REWARD_TITLE, s, key, announce)
		}
		if (g_iSetSnow[s] > 0)
		{
			new key[24]
			formatex(key, charsmax(key), "setbx#%d", s)
			WfGrantIdem(id, WF_REWARD_SNOWFLAKES, g_iSetSnow[s], key, announce)
		}
	}

	if (recompute_tree)
		WfRecomputeTree(id)
}

// Tree level = 1 + completed sets, stored (not derived at read time) so the
// panel and the sync payload get one cheap number.
WfRecomputeTree(id)
{
	new level = 1
	for (new s = 1; s <= g_iSetCount; s++)
	{
		if (g_iSetTotal[s] > 0 && WfSetOwned(id, s) >= g_iSetTotal[s])
			level++
	}
	if (level != g_iTree[id])
	{
		g_iTree[id] = level
		WfTouch(id)
	}
}

stock WfSetOwned(id, set)
{
	new owned = 0
	for (new o = 1; o <= g_iOrnCount; o++)
	{
		if (g_iOrnSet[o] != set)
			continue
		if (WfListHas(g_szOrn[id], o))
			owned++
	}
	return owned
}

stock WfOrnOwnedCount(id)
{
	new owned = 0
	for (new o = 1; o <= g_iOrnCount; o++)
		if (WfListHas(g_szOrn[id], o))
			owned++
	return owned
}

// ============================================================
// Tree grid: style + slot -> ornament (24 slots)
// ============================================================
// Stored as "slot:ornament,slot:ornament" (bounded by WF_TREE_SLOTS), which is
// the smallest thing that round-trips through one nvault value and is trivial
// for the panel bridge to read. One ornament occupies at most one slot; placing
// it again moves it, which is what a drag on the panel means.
stock WfTreeSlotGet(id, slot)
{
	new len = strlen(g_szPlace[id]), start = 0
	if (slot < 1 || slot > WF_TREE_SLOTS || !g_szPlace[id][0])
		return 0
	for (new i = 0; i <= len; i++)
	{
		if (i < len && g_szPlace[id][i] != ',')
			continue
		new buf[24], c = i - start
		if (c > 0 && c < charsmax(buf))
		{
			for (new k = 0; k < c; k++)
				buf[k] = g_szPlace[id][start + k]
			buf[c] = 0
			new sep = contain(buf, ":")
			if (sep > 0 && str_to_num(buf) == slot)
				return str_to_num(buf[sep + 1])
		}
		start = i + 1
	}
	return 0
}

stock WfTreeFilled(id)
{
	new filled = 0
	for (new slot = 1; slot <= WF_TREE_SLOTS; slot++)
		if (WfTreeSlotGet(id, slot) > 0)
			filled++
	return filled
}

// Places (ornament > 0) or clears (ornament == 0) one slot. Rebuilds the string
// so the result is always canonical: ascending slot order, no duplicates.
stock bool:WfTreeSlotSet(id, slot, ornament)
{
	if (slot < 1 || slot > WF_TREE_SLOTS)
		return false
	if (ornament > 0 && !WfListHas(g_szOrn[id], ornament))
		return false

	new out[224], buf[24]
	out[0] = 0

	for (new s = 1; s <= WF_TREE_SLOTS; s++)
	{
		new orn = WfTreeSlotGet(id, s)
		// The ornament lands in exactly one slot: drop every other placement.
		if (ornament > 0 && orn == ornament)
			orn = 0
		if (s == slot)
			orn = ornament
		if (orn <= 0)
			continue
		if (!out[0])
			formatex(out, charsmax(out), "%d:%d", s, orn)
		else
		{
			formatex(buf, charsmax(buf), ",%d:%d", s, orn)
			add(out, charsmax(out), buf)
		}
	}

	copy(g_szPlace[id], charsmax(g_szPlace[]), out)
	WfTouch(id)
	return true
}

// The set closest to completion that is not complete yet - the next thing to
// chase, and what /tree prints as "next milestone".
stock WfTreeNextSet(id)
{
	new best = 0, best_missing = 0
	for (new s = 1; s <= g_iSetCount; s++)
	{
		if (g_iSetTotal[s] <= 0)
			continue
		new missing = g_iSetTotal[s] - WfSetOwned(id, s)
		if (missing <= 0)
			continue
		if (best == 0 || missing < best_missing)
		{
			best = s
			best_missing = missing
		}
	}
	return best
}

// ============================================================
// Present inventory (instances, not counters)
// ============================================================
// Each present is an instance id + rarity, because the reward for opening one
// must be claimed against that present and nothing else. Two /opengift for the
// same instance in the same second pay once.
stock WfGiftCount(id)
{
	return WfListCount(g_szGifts[id])
}

// Instance id at a 0-based index, or 0.
stock WfGiftInstanceAt(id, index)
{
	new buf[16], len = strlen(g_szGifts[id]), start = 0, cur = 0
	if (index < 0 || !g_szGifts[id][0])
		return 0
	for (new i = 0; i <= len; i++)
	{
		if (i < len && g_szGifts[id][i] != ',')
			continue
		if (cur == index)
		{
			new c = 0
			for (new k = start; k < i && c < charsmax(buf) - 1; k++)
			{
				if (g_szGifts[id][k] == ':')
					break
				buf[c++] = g_szGifts[id][k]
			}
			buf[c] = 0
			return str_to_num(buf)
		}
		cur++
		start = i + 1
	}
	return 0
}

// Rarity of an instance, or -1 when it is not carried.
stock WfGiftRarity(id, instance)
{
	new buf[16], len = strlen(g_szGifts[id]), start = 0
	if (instance <= 0 || !g_szGifts[id][0])
		return -1
	for (new i = 0; i <= len; i++)
	{
		if (i < len && g_szGifts[id][i] != ',')
			continue
		new c = 0, seen_colon = 0
		new found = 0
		for (new k = start; k < i && c < charsmax(buf) - 1; k++)
		{
			if (g_szGifts[id][k] == ':')
			{
				if (!seen_colon)
				{
					buf[c] = 0
					found = str_to_num(buf)
					seen_colon = 1
					c = 0
				}
				continue
			}
			buf[c++] = g_szGifts[id][k]
		}
		buf[c] = 0
		if (seen_colon && found == instance)
			return str_to_num(buf)
		start = i + 1
	}
	return -1
}

// Removes one instance, rewriting the list in place. Returns true when it was
// there.
stock bool:WfGiftRemove(id, instance)
{
	new out[192], buf[24], len = strlen(g_szGifts[id]), start = 0
	out[0] = 0
	if (instance <= 0 || !g_szGifts[id][0])
		return false

	new bool:found = false
	for (new i = 0; i <= len; i++)
	{
		if (i < len && g_szGifts[id][i] != ',')
			continue
		new c = i - start
		if (c > 0 && c < charsmax(buf))
		{
			for (new k = 0; k < c; k++)
				buf[k] = g_szGifts[id][start + k]
			buf[c] = 0
			new sep = contain(buf, ":")
			new inst = (sep > 0) ? str_to_num(buf) : 0
			if (inst == instance)
				found = true
			else
			{
				if (out[0])
					add(out, charsmax(out), ",")
				add(out, charsmax(out), buf)
			}
		}
		start = i + 1
	}
	if (!found)
		return false

	copy(g_szGifts[id], charsmax(g_szGifts[]), out)
	WfTouch(id)
	return true
}

// The reward roll. One table row is picked by weight; snow/pass XP roll a value
// in [min,max]; an ornament row with id 0 asks for any unowned ornament of the
// present's rarity and falls back to snow when the collection is complete.
stock bool:WfRollReward(rarity, &type, &rid)
{
	rarity = clamp(rarity, 0, WF_RARITY_MAX - 1)
	if (g_iPoolCount[rarity] <= 0)
		return false

	new total = 0
	for (new i = 0; i < g_iPoolCount[rarity]; i++)
		total += g_iPoolWeight[rarity][i]
	if (total <= 0)
		return false

	new roll = random(total)
	new slot = 0
	for (new i = 0; i < g_iPoolCount[rarity]; i++)
	{
		roll -= g_iPoolWeight[rarity][i]
		if (roll < 0)
		{
			slot = i
			break
		}
	}

	type = g_iPoolType[rarity][slot]
	new lo = g_iPoolMin[rarity][slot]
	new hi = g_iPoolMax[rarity][slot]

	switch (type)
	{
		case WF_REWARD_SNOWFLAKES, WF_REWARD_PASS_XP:
		{
			rid = (hi > lo) ? random_num(lo, hi) : lo
			if (rid <= 0)
				rid = (type == WF_REWARD_SNOWFLAKES) ? 10 : 5
		}
		case WF_REWARD_GIFT:
		{
			rid = g_iPoolRid[rarity][slot]
		}
		case WF_REWARD_ORNAMENT:
		{
			rid = g_iPoolRid[rarity][slot]
			if (rid <= 0)
				rid = WfPickOrnament(rarity, -1)
			if (rid <= 0)
			{
				// Nothing left in that rarity: pay snow instead of nothing, so
				// a present is never a dud once the collection is complete.
				type = WF_REWARD_SNOWFLAKES
				rid = 15 + rarity * 15
			}
		}
		case WF_REWARD_TITLE:
		{
			rid = g_iPoolRid[rarity][slot]
		}
		default:
			return false
	}
	return true
}

// A random ornament of `rarity` the player does not own yet, or 0.
stock WfPickOrnament(rarity, id)
{
	new found[WF_MAX_ORNAMENTS + 1]
	new n = 0
	for (new o = 1; o <= g_iOrnCount; o++)
	{
		if (g_iOrnRarity[o] != rarity)
			continue
		if (id > 0 && WfListHas(g_szOrn[id], o))
			continue
		found[n++] = o
	}
	if (n <= 0)
		return 0
	return found[random(n)]
}

// The opening. Claim key is per present instance, so opening the same present
// twice pays once no matter how fast the two calls arrive.
WfOpenGift(id, instance)
{
	if (!WfReady(id) || instance <= 0)
		return WF_OPEN_INVALID

	new key[32]
	formatex(key, charsmax(key), "open#%d", instance)
	if (WfClaimExists(id, key))
		return WF_OPEN_NOTHING

	new rarity = WfGiftRarity(id, instance)
	if (rarity < 0)
		return WF_OPEN_INVALID

	new type = WF_REWARD_NONE, rid = 0
	if (!WfRollReward(rarity, type, rid))
	{
		type = WF_REWARD_SNOWFLAKES
		rid = 15
	}

	// Ledger first, then consume, then pay: the present cannot survive a crash
	// between the two and cannot be paid twice either.
	WfClaimMark(id, key)
	WfGiftRemove(id, instance)

	log_amx("[WF] id %d opens present #%d (%s) -> reward type %d id %d",
		id, instance, g_szRarName[clamp(rarity, 0, WF_RARITY_MAX - 1)], type, rid)
	WfApplyReward(id, type, rid, true)
	WfTouch(id)
	return WF_OPEN_OK
}

// ============================================================
// Entitlements (owner decision §6.5, model in §7)
// ============================================================
// An entitlement is the only thing gameplay reads when it asks "does this player
// own the premium track / the Advent Pass?". Money never calls in here: the panel
// (or, later, a Stripe webhook) fulfils an order by calling
// wf_grant_entitlement() with a source and a claim key, and this plugin records
// ownership. Stored as one string per player: "product@source,product@source".
stock WfProdIndex(const product[])
{
	for (new i = 0; i < g_iEntCount; i++)
		if (equali(g_szProdId[i], product))
			return i
	return -1
}

stock bool:WfEntHas(id, const product[])
{
	if (!WfReady(id) || !product[0])
		return false
	new len = strlen(g_szEnts[id]), start = 0
	for (new i = 0; i <= len; i++)
	{
		if (i < len && g_szEnts[id][i] != ',')
			continue
		new buf[48], c = i - start
		if (c > 0 && c < charsmax(buf))
		{
			for (new k = 0; k < c; k++)
				buf[k] = g_szEnts[id][start + k]
			buf[c] = 0
			new at = contain(buf, "@")
			if (at > 0)
				buf[at] = 0
			if (equali(buf, product))
				return true
		}
		start = i + 1
	}
	return false
}

stock bool:WfEntAdd(id, const product[], const source[])
{
	if (WfEntHas(id, product))
		return false
	new entry[64]
	formatex(entry, charsmax(entry), "%s@%s", product, source[0] ? source : "unknown")
	if (!g_szEnts[id][0])
		copy(g_szEnts[id], charsmax(g_szEnts[]), entry)
	else
	{
		add(g_szEnts[id], charsmax(g_szEnts[]), ",")
		add(g_szEnts[id], charsmax(g_szEnts[]), entry)
	}
	WfTouch(id)
	return true
}

// The one entitlement-granting path: the native and the wf_ent command both come
// through here, so "who owns what" has exactly one writer.
stock WfGrantEntitlement(id, const product[], const source[], const claim[], bool:announce)
{
	if (!WfReady(id))
		return WF_GRANT_NOTLOADED
	if (WfProdIndex(product) < 0)
	{
		log_amx("[WF] refused entitlement grant: '%s' is not in the [entitlement] catalogue", product)
		return WF_GRANT_INVALID
	}

	if (claim[0])
	{
		if (WfClaimExists(id, claim))
			return WF_GRANT_DUPLICATE
		WfClaimMark(id, claim)
	}

	if (!WfEntAdd(id, product, source))
		return WF_GRANT_DUPLICATE

	log_amx("[WF] id %d now owns '%s' (source '%s', claim '%s')", id, product, source, claim)

	// A premium entitlement pays the premium tiers the player has ALREADY reached
	// (a purchase mid-season is not a downgrade), and each claim key keeps that
	// to once per tier.
	if (equali(product, WF_PRODUCT_BP_PREMIUM))
		WfSyncTiers(id, announce)

	if (announce)
	{
		new line[96]
		new idx = WfProdIndex(product)
		formatex(line, charsmax(line), "unlocked: %s", (idx >= 0) ? g_szProdLabel[idx] : product)
		WfSay(id, line)
	}
	return WF_GRANT_OK
}

// ============================================================
// Advent
// ============================================================
// A strict one-day window (owner decision §6.3, final): day n unlocks on its
// date, is claimable THAT DAY ONLY in Europe/Paris, and afterwards it is
// expired, not discounted. The half-value catch-up is gone.
//
// The Advent Pass entitlement (product advent_pass_2026) unlocks every day at
// once, which is how a late joiner buys the calendar at the end of the season.
// The claim keys do not change (`advent#<day>`), so owning the pass can never
// pay a day twice - it only moves days from expired/locked to claimable.
WfAdventState(id, day)
{
	if (day < 1 || day > WF_MAX_ADVENT || g_iAdvType[day] == WF_REWARD_NONE)
		return WF_ADVENT_INVALID
	if (!WfSeasonActive())
		return WF_ADVENT_INVALID

	new today = WfDayOfMonth()
	if (today <= 0)
		return WF_ADVENT_INVALID

	if (id > 0 && WfReady(id) && WfListHas(g_szAdv[id], day))
		return WF_ADVENT_CLAIMED

	// The pass unlocks the whole calendar, including days that have not arrived.
	if (id > 0 && WfEntHas(id, WF_PRODUCT_ADVENT_PASS))
		return WF_ADVENT_UNLOCKED

	if (day == today)
		return WF_ADVENT_TODAY
	if (day < today)
		return WF_ADVENT_EXPIRED
	return WF_ADVENT_LOCKED
}

WfAdventClaim(id, day)
{
	if (!WfReady(id))
		return WF_ADVENT_CLAIM_INVALID

	new day_state = WfAdventState(id, day)
	switch (day_state)
	{
		case WF_ADVENT_CLAIMED: return WF_ADVENT_CLAIM_CLAIMED
		case WF_ADVENT_EXPIRED: return WF_ADVENT_CLAIM_EXPIRED
		case WF_ADVENT_LOCKED:  return WF_ADVENT_CLAIM_LOCKED
		case WF_ADVENT_INVALID: return WF_ADVENT_CLAIM_INVALID
	}

	// TODAY or UNLOCKED. The claim key is written before the reward, like every
	// other payoff, so a reconnect or a double click cannot pay twice.
	new key[24]
	formatex(key, charsmax(key), "advent#%d", day)
	if (WfClaimExists(id, key))
	{
		WfListAdd(g_szAdv[id], charsmax(g_szAdv[]), day)
		return WF_ADVENT_CLAIM_CLAIMED
	}

	WfClaimMark(id, key)
	if (!WfListAdd(g_szAdv[id], charsmax(g_szAdv[]), day))
		log_amx("[WF] advent list full for id %d - day %d not recorded", id, day)
	WfTouch(id)

	new type = g_iAdvType[day]
	new rid = g_iAdvRid[day]
	WfSubstituteOwned(id, type, rid)
	if (day_state == WF_ADVENT_UNLOCKED)
		log_amx("[WF] id %d claimed advent day %d through the Advent Pass", id, day)
	WfApplyReward(id, type, rid, true)
	return WF_ADVENT_CLAIM_OK
}

// ============================================================
// Natives
// ============================================================
public bool:native_season_open(plugin, params)
{
	#pragma unused plugin, params
	return WfSeasonActive()
}

public native_season_name(plugin, params)
{
	#pragma unused plugin, params
	set_string(1, g_szSeasonName, get_param(3))
}

public native_season_window(plugin, params)
{
	#pragma unused plugin, params
	new buf[48]
	if (!g_iDateStart && !g_iDateEnd)
		copy(buf, charsmax(buf), "no date window configured")
	else
		formatex(buf, charsmax(buf), "%d .. %d", g_iDateStart, g_iDateEnd)
	set_string(1, buf, get_param(2))
}

public native_get_gingerbread(plugin, params)
{
	#pragma unused plugin, params
	new id = get_param(1)
	if (!WfReady(id))
		return 0
	return g_iGb[id]
}

public native_add_gingerbread(plugin, params)
{
	#pragma unused plugin, params
	new id = get_param(1)
	new amount = get_param(2)
	if (!WfReady(id) || amount <= 0)
		return 0
	WfAddGb(id, amount)
	return g_iGb[id]
}

public native_get_spins(plugin, params)
{
	#pragma unused plugin, params
	new id = get_param(1)
	if (!WfReady(id))
		return 0
	return g_iSpins[id]
}

public native_add_spins(plugin, params)
{
	#pragma unused plugin, params
	new id = get_param(1)
	new amount = get_param(2)
	if (!WfReady(id) || amount <= 0)
		return 0
	WfAddSpins(id, amount)
	return g_iSpins[id]
}

// Consume one spin. Returns 1 when one was spent, 0 when the player has none -
// the wheel (workstream 13) must treat 0 as "no spin", not as an error.
public native_consume_spin(plugin, params)
{
	#pragma unused plugin, params
	new id = get_param(1)
	if (!WfReady(id) || g_iSpins[id] <= 0)
		return 0
	g_iSpins[id]--
	WfTouch(id)
	return 1
}

// The envelope's pending counter (workstream 15): read-only here. The core keeps
// the value in the vault so the panel and the inbox agree on one number; writing
// it belongs to the envelope, not to this module.
public native_get_pending(plugin, params)
{
	#pragma unused plugin, params
	new id = get_param(1)
	if (!WfReady(id))
		return 0
	return g_iPending[id]
}

public native_grant(plugin, params)
{
	#pragma unused plugin, params
	new id = get_param(1)
	new type = get_param(2)
	new rid = get_param(3)
	new claim[64]
	get_string(4, claim, charsmax(claim))
	// A season gate belongs to content sources (a world present, an advent
	// day), not to the ledger: an operator seeding a player in November and a
	// player opening December's present in January both have to work.
	return WfGrantIdem(id, type, rid, claim, true)
}

public native_grant_ornament(plugin, params)
{
	#pragma unused plugin, params
	new id = get_param(1)
	new orn = get_param(2)
	if (!WfReady(id) || orn < 1 || orn > g_iOrnCount)
		return 0
	// Owning an ornament twice is meaningless, so "already owned" is the
	// duplicate and the return value says whether something was granted now.
	new code = WfGrantIdem(id, WF_REWARD_ORNAMENT, orn, "orn#own", true)
	return (code == WF_GRANT_OK) ? 1 : 0
}

public native_has_ornament(plugin, params)
{
	#pragma unused plugin, params
	new id = get_param(1)
	new orn = get_param(2)
	if (!WfReady(id) || orn < 1 || orn > g_iOrnCount)
		return 0
	return WfListHas(g_szOrn[id], orn) ? 1 : 0
}

public native_ornament_count(plugin, params)
{
	#pragma unused plugin, params
	new id = get_param(1)
	if (!WfReady(id))
		return 0
	return WfOrnOwnedCount(id)
}

public native_ornament_total(plugin, params)
{
	#pragma unused plugin, params
	return g_iOrnCount
}

public native_ornament_name(plugin, params)
{
	#pragma unused plugin, params
	new orn = get_param(1)
	new out[64]
	if (orn >= 1 && orn <= g_iOrnCount)
		copy(out, charsmax(out), g_szOrnName[orn])
	else
		copy(out, charsmax(out), "unknown ornament")
	set_string(2, out, get_param(3))
}

public native_ornament_rarity(plugin, params)
{
	#pragma unused plugin, params
	new orn = get_param(1)
	if (orn < 1 || orn > g_iOrnCount)
		return -1
	return g_iOrnRarity[orn]
}

public native_ornament_set(plugin, params)
{
	#pragma unused plugin, params
	new orn = get_param(1)
	if (orn < 1 || orn > g_iOrnCount)
		return 0
	return g_iOrnSet[orn]
}

public native_tree_level(plugin, params)
{
	#pragma unused plugin, params
	new id = get_param(1)
	if (!WfReady(id))
		return 1
	return g_iTree[id]
}

public native_tree_style(plugin, params)
{
	#pragma unused plugin, params
	new id = get_param(1)
	if (!WfReady(id))
		return 1
	return g_iStyle[id]
}

public native_tree_set_style(plugin, params)
{
	#pragma unused plugin, params
	new id = get_param(1)
	new style = get_param(2)
	if (!WfReady(id) || style < 1 || style > WF_MAX_STYLES)
		return WF_GRANT_INVALID
	if (style > g_iStyleCount)
		return WF_GRANT_INVALID
	if (g_iStyle[id] != style)
	{
		g_iStyle[id] = style
		WfTouch(id)
	}
	return WF_GRANT_OK
}

public native_tree_slot(plugin, params)
{
	#pragma unused plugin, params
	new id = get_param(1)
	if (!WfReady(id))
		return 0
	return WfTreeSlotGet(id, get_param(2))
}

public native_tree_set_slot(plugin, params)
{
	#pragma unused plugin, params
	new id = get_param(1)
	new slot = get_param(2)
	new orn = get_param(3)
	if (!WfReady(id) || slot < 1 || slot > WF_TREE_SLOTS)
		return WF_GRANT_INVALID
	if (orn > 0 && !WfListHas(g_szOrn[id], orn))
		return WF_GRANT_INVALID
	if (!WfTreeSlotSet(id, slot, orn))
		return WF_GRANT_INVALID
	return WF_GRANT_OK
}

public native_tree_filled(plugin, params)
{
	#pragma unused plugin, params
	new id = get_param(1)
	if (!WfReady(id))
		return 0
	return WfTreeFilled(id)
}

public native_tree_slots(plugin, params)
{
	#pragma unused plugin, params
	return WF_TREE_SLOTS
}

public native_tree_next_set(plugin, params)
{
	#pragma unused plugin, params
	new id = get_param(1)
	if (!WfReady(id))
		return 0
	return WfTreeNextSet(id)
}

public native_tree_style_count(plugin, params)
{
	#pragma unused plugin, params
	return g_iStyleCount;
}

public native_style_name(plugin, params)
{
	#pragma unused plugin, params
	new style = get_param(1)
	new out[32]
	if (style >= 1 && style <= g_iStyleCount && g_szStyleName[style][0])
		copy(out, charsmax(out), g_szStyleName[style])
	else
		copy(out, charsmax(out), "classic")
	set_string(2, out, get_param(3))
}

public native_tree_slot_x(plugin, params)
{
	#pragma unused plugin, params
	new style = get_param(1)
	new slot = get_param(2)
	if (style < 1 || style > WF_MAX_STYLES || slot < 1 || slot > WF_TREE_SLOTS)
		return 0
	return g_iStyleX[style][slot]
}

public native_tree_slot_y(plugin, params)
{
	#pragma unused plugin, params
	new style = get_param(1)
	new slot = get_param(2)
	if (style < 1 || style > WF_MAX_STYLES || slot < 1 || slot > WF_TREE_SLOTS)
		return 0
	return g_iStyleY[style][slot]
}

public native_set_count(plugin, params)
{
	#pragma unused plugin, params
	return g_iSetCount
}

public native_set_name(plugin, params)
{
	#pragma unused plugin, params
	new s = get_param(1)
	new out[48]
	if (s >= 1 && s <= g_iSetCount)
		copy(out, charsmax(out), g_szSetName[s])
	else
		copy(out, charsmax(out), "unknown set")
	set_string(2, out, get_param(3))
}

public native_set_title(plugin, params)
{
	#pragma unused plugin, params
	new s = get_param(1)
	new out[64]
	if (s >= 1 && s <= g_iSetCount)
		copy(out, charsmax(out), g_szSetTitle[s])
	else
		out[0] = 0
	set_string(2, out, get_param(3))
}

public native_set_owned(plugin, params)
{
	#pragma unused plugin, params
	new id = get_param(1)
	new s = get_param(2)
	if (!WfReady(id) || s < 1 || s > g_iSetCount)
		return 0
	return WfSetOwned(id, s)
}

public native_set_total(plugin, params)
{
	#pragma unused plugin, params
	new s = get_param(1)
	if (s < 1 || s > g_iSetCount)
		return 0
	return g_iSetTotal[s]
}

public native_pass_xp(plugin, params)
{
	#pragma unused plugin, params
	new id = get_param(1)
	if (!WfReady(id))
		return 0
	return g_iPassXp[id]
}

public native_pass_tier(plugin, params)
{
	#pragma unused plugin, params
	new id = get_param(1)
	if (!WfReady(id))
		return 1
	return WfTierFromXp(g_iPassXp[id])
}

public native_pass_next_xp(plugin, params)
{
	#pragma unused plugin, params
	new id = get_param(1)
	if (!WfReady(id))
		return 0
	new tier = WfTierFromXp(g_iPassXp[id])
	if (tier >= g_iTierCount)
		return g_iTierXp[g_iTierCount]
	return g_iTierXp[tier + 1]
}

public native_pass_max_tier(plugin, params)
{
	#pragma unused plugin, params
	return g_iTierCount
}

public native_pass_tier_xp(plugin, params)
{
	#pragma unused plugin, params
	new tier = get_param(1)
	if (tier < 1 || tier > g_iTierCount)
		return 0
	return g_iTierXp[tier]
}

public native_pass_tier_reward(plugin, params)
{
	#pragma unused plugin, params
	new tier = get_param(1)
	new out[96]
	out[0] = 0
	if (tier >= 1 && tier <= g_iTierCount && g_iTierType[tier] != WF_REWARD_NONE)
		WfRewardText(g_iTierType[tier], g_iTierRid[tier], out, charsmax(out))
	set_string(2, out, get_param(3))
}

public native_advent_today(plugin, params)
{
	#pragma unused plugin, params
	if (!WfSeasonActive())
		return 0
	return WfDayOfMonth()
}

public native_advent_state(plugin, params)
{
	#pragma unused plugin, params
	return WfAdventState(get_param(1), get_param(2))
}

public native_advent_claim(plugin, params)
{
	#pragma unused plugin, params
	return WfAdventClaim(get_param(1), get_param(2))
}

public native_advent_claimed(plugin, params)
{
	#pragma unused plugin, params
	new id = get_param(1)
	new day = get_param(2)
	if (!WfReady(id) || day < 1 || day > WF_MAX_ADVENT)
		return 0
	return WfListHas(g_szAdv[id], day) ? 1 : 0
}

public native_gift_count(plugin, params)
{
	#pragma unused plugin, params
	new id = get_param(1)
	if (!WfReady(id))
		return 0
	return WfGiftCount(id)
}

public native_gift_instance(plugin, params)
{
	#pragma unused plugin, params
	new id = get_param(1)
	if (!WfReady(id))
		return 0
	return WfGiftInstanceAt(id, get_param(2))
}

public native_gift_rarity(plugin, params)
{
	#pragma unused plugin, params
	new id = get_param(1)
	if (!WfReady(id))
		return -1
	return WfGiftRarity(id, get_param(2))
}

public native_open_gift(plugin, params)
{
	#pragma unused plugin, params
	return WfOpenGift(get_param(1), get_param(2))
}

public native_has_entitlement(plugin, params)
{
	#pragma unused plugin, params
	new id = get_param(1)
	new product[40]
	get_string(2, product, charsmax(product))
	if (WfProdIndex(product) < 0)
		return WF_ENT_UNKNOWN
	if (!WfReady(id))
		return WF_ENT_NO
	return WfEntHas(id, product) ? WF_ENT_YES : WF_ENT_NO
}

// The one door ownership comes through: a paid order, a manual admin grant or an
// automatic in-game grant all end up here, with a source and a claim key. The
// claim key is the idempotency record (order id, admin action id, ...), so a
// replayed fulfilment cannot grant twice.
public native_grant_entitlement(plugin, params)
{
	#pragma unused plugin, params
	new id = get_param(1)
	new product[40], source[32], claim[64]
	get_string(2, product, charsmax(product))
	get_string(3, source, charsmax(source))
	get_string(4, claim, charsmax(claim))

	// announce: the player sees one line. A panel-driven fulfilment also sees it,
	// which is the point - ownership should never appear silently.
	return WfGrantEntitlement(id, product, source, claim, true)
}

public native_entitlement_count(plugin, params)
{
	#pragma unused plugin, params
	return g_iEntCount
}

public native_entitlement_name(plugin, params)
{
	#pragma unused plugin, params
	new idx = get_param(1)
	new out[40]
	if (idx >= 0 && idx < g_iEntCount)
		copy(out, charsmax(out), g_szProdId[idx])
	else
		out[0] = 0
	set_string(2, out, get_param(3))
}

public native_entitlement_label(plugin, params)
{
	#pragma unused plugin, params
	new idx = get_param(1)
	new out[48]
	if (idx >= 0 && idx < g_iEntCount)
		copy(out, charsmax(out), g_szProdLabel[idx])
	else
		out[0] = 0
	set_string(2, out, get_param(3))
}

public native_pass_tier_reward_premium(plugin, params)
{
	#pragma unused plugin, params
	new tier = get_param(1)
	new out[96]
	out[0] = 0
	if (tier >= 1 && tier <= WF_MAX_TIERS && g_iPremType[tier] != WF_REWARD_NONE)
		WfRewardText(g_iPremType[tier], g_iPremRid[tier], out, charsmax(out))
	set_string(2, out, get_param(3))
}

public native_pass_premium_unlocked(plugin, params)
{
	#pragma unused plugin, params
	new id = get_param(1)
	return WfEntHas(id, WF_PRODUCT_BP_PREMIUM) ? 1 : 0
}

// Explicit tier claim. The free track already pays itself on tier-up; this exists
// for the premium track (which needs the entitlement), for a panel button, and
// for a retry after an entitlement arrives late. Idempotent per (tier, track).
public native_claim_pass_tier(plugin, params)
{
	#pragma unused plugin, params
	new id = get_param(1)
	new tier = get_param(2)
	new bool:premium = get_param(3) ? true : false

	if (!WfReady(id) || tier < 1 || tier > g_iTierCount)
		return WF_GRANT_INVALID
	// Not reached yet: nothing to claim.
	if (WfTierFromXp(g_iPassXp[id]) < tier)
		return WF_GRANT_INVALID

	new type, rid
	new key[32]
	if (premium)
	{
		// The entitlement is the gate, and it is checked here as well as in the
		// sync so a caller cannot pay a premium tier by calling the native.
		if (!WfEntHas(id, WF_PRODUCT_BP_PREMIUM))
			return WF_GRANT_INVALID
		if (!WfRewardUsable(g_iPremType[tier], g_iPremRid[tier]))
			return WF_GRANT_INVALID
		type = g_iPremType[tier]
		rid = g_iPremRid[tier]
		formatex(key, charsmax(key), "pass:%d:premium", tier)
	}
	else
	{
		if (!WfRewardUsable(g_iTierType[tier], g_iTierRid[tier]))
			return WF_GRANT_INVALID
		type = g_iTierType[tier]
		rid = g_iTierRid[tier]
		formatex(key, charsmax(key), "pass:%d:free", tier)
	}

	WfSubstituteOwned(id, type, rid)
	return WfGrantIdem(id, type, rid, key, true)
}

public native_rarity_name(plugin, params)
{
	#pragma unused plugin, params
	new rar = get_param(1)
	new out[32]
	if (rar >= 0 && rar < WF_RARITY_MAX)
		copy(out, charsmax(out), g_szRarName[rar])
	else
		copy(out, charsmax(out), "unknown")
	set_string(2, out, get_param(3))
}

// ---- visuals ---------------------------------------------------------------
// The slot -> resolved name lookup is the only "which visual do I draw?" call a
// consumer needs; everything else describes the name it returned.
public native_visual_id(plugin, params)
{
	#pragma unused plugin, params
	new slot[32], out[32]
	get_string(1, slot, charsmax(slot))
	out[0] = 0
	for (new i = 0; i < WF_PROP_SLOTS; i++)
	{
		if (equali(slot, g_szPropSlot[i]))
		{
			copy(out, charsmax(out), g_szPropResolved[i])
			break
		}
	}
	set_string(2, out, get_param(3))
}

public native_visual_is_model(plugin, params)
{
	#pragma unused plugin, params
	new visual[32]
	get_string(1, visual, charsmax(visual))
	new idx = WfFindVisual(visual)
	if (idx < 0)
		return 0
	return (g_iVisKind[idx] == WF_VISUAL_MODEL) ? 1 : 0
}

public native_visual_asset(plugin, params)
{
	#pragma unused plugin, params
	new visual[32], out[64]
	get_string(1, visual, charsmax(visual))
	new idx = WfFindVisual(visual)
	if (idx < 0)
		out[0] = 0
	else
		copy(out, charsmax(out), g_szVisAsset[idx])
	set_string(2, out, get_param(3))
}

public native_visual_colour(plugin, params)
{
	#pragma unused plugin, params
	new visual[32], out[24]
	get_string(1, visual, charsmax(visual))
	new idx = WfFindVisual(visual)
	if (idx < 0)
		out[0] = 0
	else
		copy(out, charsmax(out), g_szVisColour[idx])
	set_string(2, out, get_param(3))
}

public Float:native_visual_scale(plugin, params)
{
	#pragma unused plugin, params
	new visual[32]
	get_string(1, visual, charsmax(visual))
	new idx = WfFindVisual(visual)
	if (idx < 0)
		return 1.0
	return g_fVisScale[idx]
}

public native_visual_count(plugin, params)
{
	#pragma unused plugin, params
	return g_iVisCount
}

// One human-readable description per reward kind, so the menus and the chat
// line agree.
stock WfRewardText(type, rid, out[], len)
{
	switch (type)
	{
		case WF_REWARD_SNOWFLAKES:
			formatex(out, len, "%d %s", rid, WF_CURRENCY_NAME)
		case WF_REWARD_ORNAMENT:
			formatex(out, len, "ornament: %s", (rid >= 1 && rid <= g_iOrnCount) ? g_szOrnName[rid] : "?")
		case WF_REWARD_GIFT:
			formatex(out, len, "%s present", (rid >= 0 && rid < g_iRarCount) ? g_szRarName[rid] : "?")
		case WF_REWARD_PASS_XP:
			formatex(out, len, "%d winter pass XP", rid)
		case WF_REWARD_SPINS:
			formatex(out, len, "%d spin%s", rid, (rid == 1) ? "" : "s")
		case WF_REWARD_COINS:
			formatex(out, len, "%d Coins", rid)
		case WF_REWARD_TITLE:
			formatex(out, len, "collector title: %s", (rid >= 1 && rid <= g_iSetCount) ? g_szSetTitle[rid] : "?")
		default:
			out[0] = 0
	}
}

// ============================================================
// Operator commands
// ============================================================
// Target resolution, all four forms an operator types at the console:
//
//   all | *        every connected client, bots included (a bot is a valid vault
//                  record and the harness has no humans)
//   <id>           the CLIENT SLOT number - what every other FreeNova admin
//                  command takes, and what an operator reads off amx_who
//   #<userid>      the per-session userid (differs from the slot after a
//                  reconnect, so both are supported)
//   <text>         case-insensitive name / authid substring, first match
//
// The bare-number form was missing: `wf_give 1 gingerbread 0 5` fell through to
// the substring branch, found no name containing "1", and answered
// "no client matched '1'" - which is why wf_give/wf_state/wf_reset/wf_ent had
// to be driven with "all".
// true when the whole argument is decimal digits (and not empty)
stock bool:WfIsDigits(const s[])
{
	if (!s[0])
		return false
	for (new i = 0; s[i]; i++)
	{
		if (s[i] < '0' || s[i] > '9')
			return false
	}
	return true
}

stock WfResolveTargets(const arg[], players[], &num, max)
{
	num = 0
	if (equal(arg, "all") || equal(arg, "*"))
	{
		new list[MAX_PLAYERS], n
		get_players(list, n, "")
		for (new i = 0; i < n && num < max; i++)
		{
			new p = list[i]
			if (!WfInRange(p) || !is_user_connected(p) || is_user_hltv(p))
				continue
			players[num++] = p
		}
		return
	}

	new p = 0
	if (arg[0] == '#' && arg[1])
	{
		new uid = str_to_num(arg[1])
		for (new i = 1; i <= MaxClients; i++)
		{
			if (is_user_connected(i) && get_user_userid(i) == uid)
			{
				p = i
				break
			}
		}
	}
	else if (WfIsDigits(arg))
	{
		// A bare slot number. Bounded and range-checked: "0" and "17" match
		// nobody rather than reading past the target list.
		new slot = str_to_num(arg)
		if (slot >= 1 && slot <= MaxClients && is_user_connected(slot) && !is_user_hltv(slot))
			p = slot
	}
	else
	{
		new name[MAX_NAME_LENGTH], auth[40]
		for (new i = 1; i <= MaxClients; i++)
		{
			if (!is_user_connected(i))
				continue
			get_user_name(i, name, charsmax(name))
			get_user_authid(i, auth, charsmax(auth))
			if (containi(name, arg) >= 0 || (auth[0] && containi(auth, arg) >= 0))
			{
				p = i
				break
			}
		}
	}
	if (p > 0)
		players[num++] = p
}

public cmdGive(id, level, cid)
{
	if (!cmd_access(id, level, cid, 5))
		return PLUGIN_HANDLED

	new arg_target[40], arg_what[16], arg_id[12], arg_n[12]
	read_argv(1, arg_target, charsmax(arg_target))
	read_argv(2, arg_what, charsmax(arg_what))
	read_argv(3, arg_id, charsmax(arg_id))
	read_argv(4, arg_n, charsmax(arg_n))

	new targets[MAX_PLAYERS], tnum
	WfResolveTargets(arg_target, targets, tnum, MAX_PLAYERS)
	if (!tnum)
	{
		console_print(id, "[WF] no client matched '%s'", arg_target)
		return PLUGIN_HANDLED
	}

	new rid = str_to_num(arg_id)
	new amount = str_to_num(arg_n)
	if (amount <= 0)
		amount = 1

	for (new t = 0; t < tnum; t++)
	{
		new p = targets[t]
		new code = WF_GRANT_INVALID
		new done = 0

		if (equal(arg_what, "gingerbread") || equal(arg_what, "gb") || equal(arg_what, "snowflakes") || equal(arg_what, "snow"))
		{
			code = WfGrantIdem(p, WF_REWARD_SNOWFLAKES, amount, "", true)
			done = (code == WF_GRANT_OK) ? 1 : 0
		}
		else if (equal(arg_what, "ornament"))
		{
			code = WfGrantIdem(p, WF_REWARD_ORNAMENT, rid, "", true)
			done = (code == WF_GRANT_OK) ? 1 : 0
		}
		else if (equal(arg_what, "spins") || equal(arg_what, "spin"))
		{
			WfAddSpins(p, amount)
			done = amount
			code = WF_GRANT_OK
		}
		else if (equal(arg_what, "gift") || equal(arg_what, "present"))
		{
			new capped = min(amount, WF_MAX_GIFTS)
			for (new g = 0; g < capped; g++)
			{
				code = WfGrantIdem(p, WF_REWARD_GIFT, clamp(rid, 0, WF_RARITY_MAX - 1), "", true)
				if (code == WF_GRANT_OK)
					done++
			}
		}
		else
		{
			console_print(id, "[WF] unknown reward kind '%s' (gingerbread|spins|ornament|gift)", arg_what)
			return PLUGIN_HANDLED
		}

		new pname[MAX_NAME_LENGTH]
		get_user_name(p, pname, charsmax(pname))
		console_print(id, "[WF] %s -> id %d (%s): %s %d x%d => code %d, %d applied",
			arg_what, p, pname, arg_what, rid, amount, code, done)
		log_amx("[WF] admin %d gave %s id %d what=%s rid=%d n=%d => code %d applied %d",
			id, pname, p, arg_what, rid, amount, code, done)
	}
	return PLUGIN_HANDLED
}

public cmdState(id, level, cid)
{
	if (!cmd_access(id, level, cid, 2))
		return PLUGIN_HANDLED

	new arg_target[40]
	read_argv(1, arg_target, charsmax(arg_target))

	new targets[MAX_PLAYERS], tnum
	WfResolveTargets(arg_target, targets, tnum, MAX_PLAYERS)
	if (!tnum)
	{
		console_print(id, "[WF] no client matched '%s'", arg_target)
		return PLUGIN_HANDLED
	}

	console_print(id, "[WF] season '%s' year %d window %d..%d open=%s vault=%s",
		g_szSeasonName, g_iSeasonYear, g_iDateStart, g_iDateEnd,
		WfSeasonActive() ? "yes" : "no",
		(g_Vault != INVALID_HANDLE) ? "ok" : "FAILED")

	for (new t = 0; t < tnum; t++)
	{
		new p = targets[t]
		new pname[MAX_NAME_LENGTH]
		get_user_name(p, pname, charsmax(pname))
		console_print(id, "[WF] %s (%d) loaded=%s gb=%d spins=%d pending=%d gifts=%d ornaments=%d/%d tree=%d pass=%d xp(t%d) premium=%s ents=%s advent=%s titles=%s",
			pname, p,
			g_bLoaded[p] ? "yes" : "no",
			g_iGb[p], g_iSpins[p], g_iPending[p],
			WfGiftCount(p), WfOrnOwnedCount(p), g_iOrnCount,
			g_iTree[p], g_iPassXp[p], WfTierFromXp(g_iPassXp[p]),
			WfEntHas(p, WF_PRODUCT_BP_PREMIUM) ? "yes" : "no",
			g_szEnts[p][0] ? g_szEnts[p] : "-",
			g_szAdv[p][0] ? g_szAdv[p] : "-",
			g_szTitles[p][0] ? g_szTitles[p] : "-")
	}
	return PLUGIN_HANDLED
}

public cmdReset(id, level, cid)
{
	if (!cmd_access(id, level, cid, 2))
		return PLUGIN_HANDLED

	new arg_target[40]
	read_argv(1, arg_target, charsmax(arg_target))

	new targets[MAX_PLAYERS], tnum
	WfResolveTargets(arg_target, targets, tnum, MAX_PLAYERS)
	if (!tnum)
	{
		console_print(id, "[WF] no client matched '%s'", arg_target)
		return PLUGIN_HANDLED
	}

	for (new t = 0; t < tnum; t++)
	{
		new p = targets[t]
		new pname[MAX_NAME_LENGTH]
		get_user_name(p, pname, charsmax(pname))
		WfResetPlayer(p)
		console_print(id, "[WF] reset %s (%d)", pname, p)
		log_amx("[WF] admin %d reset Winterfest season %d data for %s (%d)",
			id, g_iSeasonYear, pname, p)
	}
	return PLUGIN_HANDLED
}

// Wipes the current season only: the keys are season-stamped, so last year's
// record is untouched and comes back if the year is reverted. The epoch bump
// makes every claim key of the old record unreachable without enumerating the
// vault, so a reset player can earn everything again.
stock WfResetPlayer(id)
{
	if (!WfInRange(id) || !WfReady(id))
		return

	new epoch = g_iEpoch[id] + 1
	WfClearMem(id)
	g_bLoaded[id] = true
	g_iEpoch[id] = epoch
	g_iTree[id] = 1

	if (g_Vault != INVALID_HANDLE)
	{
		static const bases[][] =
		{
			"gb", "snow", "pass", "tree", "gseq", "gifts", "orn", "advent", "titles",
			"style", "slots", "spins", "pending", "ents"
		}
		new key[MAX_KEY], val[16]
		for (new i = 0; i < sizeof(bases); i++)
			if (WfKey(id, key, charsmax(key), bases[i]))
				nvault_remove(g_Vault, key)
		// The epoch itself is the only thing written, so the new record starts
		// empty but cannot reuse a claim key.
		formatex(val, charsmax(val), "%d", epoch)
		if (WfKey(id, key, charsmax(key), "epoch"))
			nvault_set(g_Vault, key, val)
	}

	g_bDirty[id] = false
	WfSave(id, true)
}

// Manual grant, the in-game twin of the panel's admin action (§6.5, §7). The
// claim key is per (player, product), so running it twice is a no-op and the
// first grant's source is what stays recorded.
public cmdEnt(id, level, cid)
{
	if (!cmd_access(id, level, cid, 3))
		return PLUGIN_HANDLED

	new arg_target[40], arg_product[40], arg_source[24]
	read_argv(1, arg_target, charsmax(arg_target))
	read_argv(2, arg_product, charsmax(arg_product))
	read_argv(3, arg_source, charsmax(arg_source))
	if (!arg_source[0])
		copy(arg_source, charsmax(arg_source), "admin")

	new targets[MAX_PLAYERS], tnum
	WfResolveTargets(arg_target, targets, tnum, MAX_PLAYERS)
	if (!tnum)
	{
		console_print(id, "[WF] no client matched '%s'", arg_target)
		return PLUGIN_HANDLED
	}
	if (WfProdIndex(arg_product) < 0)
	{
		console_print(id, "[WF] unknown product '%s' - the catalogue is in [entitlement]", arg_product)
		return PLUGIN_HANDLED
	}

	for (new t = 0; t < tnum; t++)
	{
		new p = targets[t]
		new pname[MAX_NAME_LENGTH], key[64]
		get_user_name(p, pname, charsmax(pname))
		// One claim per player per product for a manual grant: the entitlement is
		// ownership, not a consumable.
		formatex(key, charsmax(key), "ent#%s", arg_product)
		new code = WfGrantEntitlement(p, arg_product, arg_source, key, true)
		console_print(id, "[WF] entitlement %s -> %s (%d): code %d", arg_product, pname, p, code)
		log_amx("[WF] admin %d granted entitlement '%s' to %s (%d) source=%s => %d",
			id, arg_product, pname, p, arg_source, code)
	}
	return PLUGIN_HANDLED
}

public cmdReload(id, level, cid)
{
	if (!cmd_access(id, level, cid, 1))
		return PLUGIN_HANDLED

	loadConfig()
	console_print(id, "[WF] reloaded %s: season '%s' %d, %d rarities, %d ornaments, %d sets, %d advent days, %d pass tiers",
		g_szCfgPath, g_szSeasonName, g_iSeasonYear, g_iRarCount, g_iOrnCount, g_iSetCount, g_iAdvCount, g_iTierCount)
	log_amx("[WF] admin %d reloaded %s", id, g_szCfgPath)

	// The present spots live in the same file and are owned by
	// winterfest_gifts. Ask it to re-read if it is loaded; if it is not, the
	// next map change picks the new rows up anyway.
	if (LibraryExists("winterfest_gifts", LibType_Library))
	{
		server_cmd("wf_gifts_reload")
		server_exec()
	}
	return PLUGIN_HANDLED
}
