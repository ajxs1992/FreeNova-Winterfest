/*
 * ============================================================================
 * winterfest_spin - the Spin Wheel: one token, one prize, one reveal
 * ============================================================================
 * Product contract: docs/WINTERFEST.md §4, owner decision 2026-11-22
 * (docs/design/WINTERFEST-DASHBOARD.md, "Spins 0" next to Coins and
 * GingerBread). Workstream 13 of docs/WINTERFEST-WORKSTREAMS.md.
 * This module's own document: docs/WINTERFEST-SPIN.md.
 *
 * WHAT THIS PLUGIN OWNS
 *   - the WHEEL and its prize table: configs/freenova/winterfest/spin.ini
 *     (8..12 weighted sectors, the prize kinds, the caps, the reveal timing);
 *   - /spin and the reveal: a balance line, the wheel, three flicker steps and
 *     the result over ~2.6 s, with a screen fade on rare and better;
 *   - paying a sector: GingerBread through the core's one-grant ledger, coins
 *     through the BattlePass wallet's award ledger, ornaments / titles /
 *     presents through the core, and a spin back through the core's counter;
 *   - the anti-dupe discipline around all of that (see below);
 *   - operator commands: `wfspin_grant`, `wfspin_state`, `wfspin_reload`,
 *     `wfspin_roll`, `wfspin_day`, and the harness seams (`wfspin_drive`,
 *     `wfspin_dupe`, `wfspin_resume`).
 *
 * WHAT IT DELIBERATELY DOES NOT OWN
 *   - the spin BALANCE and the daily free spin. winterfest_core.amxx owns both
 *     (configs/freenova/winterfest.ini [spins], claim key spin#<YYYYMMDD>). This
 *     module reads and consumes that counter through wf_get_spins /
 *     wf_add_spins / wf_consume_spin and would rather do nothing than keep a
 *     second ledger: two counters is two bugs. When the counter is missing, the
 *     wheel is unavailable and NO token is spent and NO prize is paid;
 *   - the ornaments, presents, titles or pass tiers that other modules also
 *     grant: every prize goes through the same idempotent path they use;
 *   - the panel page's data: the panel cannot be written to from the game yet,
 *     so /winter/spin is a viewer (docs/WINTERFEST-SPIN.md §6);
 *   - any client asset. No precache, no model, no sprite: the reveal is HUD
 *     text, chat text and a screen fade, all stock engine messages.
 *
 * THE ANTI-DUPE DISCIPLINE (docs/WINTERFEST.md §5.2, REVIEW §2.4)
 *   1. ONE spin in flight per player. `g_bSpinning` is set when the token is
 *      taken and cleared when the reveal's last step has paid; a second /spin
 *      in that window is refused with one line and spends nothing. A menu that
 *      stays open, a double bind ("/spin" in say and say_team) or a spam of the
 *      command cannot burn two tokens.
 *   2. THE TOKEN IS CONSUMED FIRST, and only if wf_consume_spin() says it
 *      actually took one. No token, no wheel.
 *   3. THE CLAIM KEY IS WRITTEN BEFORE THE ANNOUNCEMENT. The key is
 *      `wfspin#<serial>`, where <serial> is a monotonic per-player counter kept
 *      in this module's nvault. The intent (`serial:sector`) is written to the
 *      vault at the moment the token is consumed, which is what makes a
 *      reconnect safe: a client that drops mid-reveal has its pending sector
 *      paid on the next connect through the SAME claim key, so the prize is
 *      paid exactly once, and never twice. A crash between "claim key written"
 *      and "prize applied" loses one prize - never pays two.
 *   4. EVERY PRIZE API IS IDEMPOTENT BY KEY: core grants use the claim key,
 *      coins use menabp_add_coins_once's award ledger, and the one prize with no
 *      ledger in the core (a spin back) uses a per-serial marker written BEFORE
 *      the add.
 *   5. BOTS are excluded, like every other player-facing entry point.
 *
 * THE ROLL (documented so a complaint can be audited)
 *   Weights are integers from spin.ini. total = sum(weight). r = random_num(1,
 *   total). Walk the sectors in file order, subtracting each weight; the sector
 *   where the running total first goes <= 0 wins. Integer arithmetic only, so
 *   there is no float drift, every sector with weight >= 1 is reachable, and the
 *   file order changes nothing about the odds. Every roll is logged with r, the
 *   total, the sector index, its weight and its rarity:
 *     [WF-SPIN] roll id 2: r=37/100 -> sector #3 '15 GingerBread' (gingerbread
 *     15, weight 18, rarity common) serial 7; balance now 2
 *   `wfspin_roll 1000` replays the same function and prints observed vs
 *   configured; tests/winterfest-spin/test_odds.py does the same offline.
 *
 * SAFETY ON THE LIVE TREE (70+ plugins)
 *   - every array is indexed by a live client slot that is bounds-checked;
 *   - no per-frame work: one task while a wheel is turning, one bounded retry
 *     task at connect when a pending spin has to be resumed;
 *   - a missing or broken spin.ini leaves the plugin loaded and the wheel shut
 *     with one log line, never a bad load;
 *   - `set_native_filter` (the fn_servers.sma pattern) keeps this plugin loaded
 *     when winterfest_core or battlepass_core is missing.
 * ============================================================================
 */

#include <amxmodx>
#include <amxmisc>
#include <nvault>
#include <menabp>       // coin prizes: menabp_is_ready / menabp_add_coins_once
#include <winterfest>   // core natives + the WfField/WfSay stocks

#define PLUGIN  "Winterfest Spin"
#define VERSION "1.0.0"
#define AUTHOR  "FreeNova"

#define CFG_FILE   "freenova/winterfest/spin.ini"

// Own vault. The core keeps the spin COUNTER (freenova_wf); this file keeps only
// what the wheel needs to be crash-safe: the per-player claim-key serial and the
// sector of a spin that is in flight (or was, when the client dropped).
#define VAULT_NAME "freenova_wfspin"

// nvault key ceiling, the same discipline as the core: a longer key is refused
// and logged, never truncated (two truncated keys would silently alias).
#define MAX_KEY 64

// Sector bounds. The brief asks for 8..12 sectors; both are enforced while
// parsing so a hand-edited file cannot produce a wheel nobody can read.
#define MIN_SECTORS 8
#define MAX_SECTORS 12

// Reveal steps. Four steps at spin.ini's `step` seconds: the player sees the
// wheel at t=0 and the prize at t=4*step (2.6 s with the shipped 0.65).
#define REVEAL_STEPS 4

// Task bases. AMXX task ids are per plugin; the +id ranges stay clear of each
// other so remove_task() can sweep one per-player task without touching the
// other.
enum
{
	TASK_RESUME = 98600,   // + id  (bounded retry at connect, 12 tries)
	TASK_STEP   = 98700    // + id  (the reveal, REVEAL_STEPS repeats)
}

// Sector kinds. The vocabulary of spin.ini's [sector] rows.
enum
{
	KIND_NOTHING = 0,
	KIND_GINGERBREAD,
	KIND_COINS,
	KIND_ORNAMENT,
	KIND_TITLE,
	KIND_SPIN,
	KIND_GIFT,
	KIND_COUNT
}

new const g_szKindName[KIND_COUNT][] =
{
	"nothing", "gingerbread", "coins", "ornament", "title", "spin", "gift"
}

// The wheel's own rarity ladder. COSMETIC ONLY: it picks the reveal colour and
// decides which results get the screen fade. It is not the core's 3-step reward
// rarity (an ornament's rarity comes from the ornament catalogue).
enum
{
	RAR_COMMON = 0,
	RAR_UNCOMMON,
	RAR_RARE,
	RAR_LEGENDARY,
	RAR_COUNT
}

new const g_szRarName[RAR_COUNT][] =
{
	"common", "uncommon", "rare", "legendary"
}

// The dashboard reference's palette (docs/design/WINTERFEST-DASHBOARD.md):
// muted #9fb0d0, green #3fbf6f, ice blue #4070c0, gold #f5c451.
new const g_iRarColor[RAR_COUNT][3] =
{
	{159, 176, 208},
	{ 63, 191, 111},
	{ 64, 112, 192},
	{245, 196,  81}
}

// Payment results.
#define PAY_OK        1
#define PAY_DUP       0    // the claim key was already spent: paid once already
#define PAY_FAIL     -1

// ---------------------------------------------------------------------------
// Config state (spin.ini)
// ---------------------------------------------------------------------------
new g_szCfgPath[160]
new bool:g_bCfgOk

new bool:g_bEnabled = true
new g_iFreePerDay = 1
new g_iResetHour = 0
new g_iMaxStored = 10
new g_iFadeRarity = RAR_RARE
new Float:g_fStep = 0.65
new g_szTz[32] = "Europe/Paris"

new g_iSectors
new g_szLabel[MAX_SECTORS][40]
new g_iKind[MAX_SECTORS]
new g_iAmount[MAX_SECTORS]
new g_iWeight[MAX_SECTORS]
new g_iRarity[MAX_SECTORS]
new g_iWeightTotal

// ---------------------------------------------------------------------------
// Per-player state
// ---------------------------------------------------------------------------
new g_Vault = INVALID_HANDLE
new g_iSerial[MAX_PLAYERS + 1]              // monotonic claim-key counter
new bool:g_bMetaLoaded[MAX_PLAYERS + 1]     // serial+pending read from the vault
new g_szPending[MAX_PLAYERS + 1][24]        // "serial:sector" while in flight
new bool:g_bSpinning[MAX_PLAYERS + 1]
new g_iStep[MAX_PLAYERS + 1]
new g_iWinSector[MAX_PLAYERS + 1]
new g_iWinSerial[MAX_PLAYERS + 1]

// What SpinPay() actually handed out, for the announcement (e.g. which random
// ornament was picked). Reset before every payment.
new g_iPaidId[MAX_PLAYERS + 1]
new g_iPaidAmount[MAX_PLAYERS + 1]

// One-time log guards: a missing dependency is logged once per map, not once per
// command, so an operator reading the log sees a fact and not a storm.
new bool:g_bLoggedNoCore

// TEST SEAM (wfspin_drive <n> plain): treat the "spin back" sector as unpayable,
// which is exactly the at-the-cap case, so the token accounting in the harness
// assertion is exact instead of "3 or 4, depending on luck".
new bool:g_bSeamNoSpin

// ============================================================
// Lifecycle
// ============================================================
public plugin_natives()
{
	// Announced so the /christmas hub (workstream 3) and the panel bridge can
	// tell "the wheel is loaded" from "the wheel is not installed".
	register_library("winterfest_spin")
	set_native_filter("WfSpinNativeFilter")
}

// The fn_servers.sma pattern (docs/WINTERFEST.md §5.1): a missing optional
// provider resolves its natives to 0 instead of turning this plugin into a bad
// load. A missing wf_* native then means "no counter" - and every call site is
// guarded, so the wheel goes quiet instead of paying anything.
public WfSpinNativeFilter(const name[], index, trap)
{
	#pragma unused index
	if (trap)
		return PLUGIN_CONTINUE
	// Our own natives would never be missing, but be explicit: never filter a
	// name another module may register later under our prefix.
	if (contain(name, "wfspin_") == 0)
		return PLUGIN_CONTINUE
	if (contain(name, "wf_") == 0)
		return LibraryExists("winterfest_core", LibType_Library) ? PLUGIN_CONTINUE : PLUGIN_HANDLED
	if (contain(name, "menabp_") == 0)
		return LibraryExists("menabp", LibType_Library) ? PLUGIN_CONTINUE : PLUGIN_HANDLED
	return PLUGIN_CONTINUE
}

public plugin_init()
{
	register_plugin(PLUGIN, VERSION, AUTHOR)

	// Player entry points. Registered even when the season is shut or the config
	// is broken, because the honest answer ("the wheel opens on ...") is better
	// than a command the engine does not know. The handler decides, once.
	register_clcmd("say /spin", "cmdSpin")
	register_clcmd("say_team /spin", "cmdSpin")
	register_clcmd("wf_spin", "cmdSpin")

	// Operator surface. ADMIN_CFG everywhere: this can move a balance.
	register_concmd("wfspin_grant", "cmdGrant", ADMIN_CFG, "<n> <target|all> - add up to <n> spins (capped)")
	register_concmd("wfspin_state", "cmdState", ADMIN_CFG, "<target|all> - the wheel's view of one player")
	register_concmd("wfspin_reload", "cmdReload", ADMIN_CFG, "- re-read spin.ini")
	register_concmd("wfspin_roll", "cmdRoll", ADMIN_CFG, "<n> - replay the weighted roll, observed vs configured odds")
	register_concmd("wfspin_day", "cmdDay", ADMIN_CFG, "[unixtime] - the daily-reset clock: spin-day index and next reset")
	// Harness seams (docs/WINTERFEST-SPIN.md §7). They exist so the whole flow
	// can be proven with nobody at the keyboard, and they need
	// `wfspin_test_bots 1` because the harness has bots and a bot may not use
	// the wheel in production.
	register_concmd("wfspin_drive", "cmdDrive", ADMIN_CFG, "<n> [plain] - TEST: run n spins synchronously on every bot")
	register_concmd("wfspin_dupe", "cmdDupe", ADMIN_CFG, "- TEST: two /spin in one tick must spend one token")
	register_concmd("wfspin_resume", "cmdResume", ADMIN_CFG, "- TEST: a spin interrupted by a reconnect pays once")
	register_cvar("wfspin_test_bots", "0")

	SpinLoadConfig()

	if (!g_bCfgOk)
	{
		log_amx("[WF-SPIN] %s is missing or invalid - the wheel is unavailable this map (no token can be spent)", CFG_FILE)
		server_print("[FreeNova winterfest_spin] loaded WITHOUT a usable wheel (%s)", CFG_FILE)
		return
	}

	log_amx("[WF-SPIN] ready: %d sector(s), total weight %d, free_per_day %d (display only), reset %02d:00 %s, cap %d, step=%dms, fade %s+; core=%s season=%s",
		g_iSectors, g_iWeightTotal, g_iFreePerDay, g_iResetHour, g_szTz, g_iMaxStored,
		floatround(g_fStep * 1000.0), g_szRarName[clamp(g_iFadeRarity, 0, RAR_COUNT - 1)],
		WfSpinCore() ? "yes" : "no",
		(WfSpinCore() && wf_season_open()) ? "open" : "closed")
	if (!WfSpinCore())
		log_amx("[WF-SPIN] winterfest_core missing - /spin will answer 'unavailable' and nothing can be paid or spent")
	server_print("[FreeNova winterfest_spin] ready (build 1, %d sectors)", g_iSectors)
}

public plugin_end()
{
	if (g_Vault != INVALID_HANDLE)
	{
		nvault_close(g_Vault)
		g_Vault = INVALID_HANDLE
	}
}

// ============================================================
// Config
// ============================================================
// Format: docs/WINTERFEST-SPIN.md §3 and the header of spin.ini. A bad row is
// skipped with a log line naming the line number; a file with fewer than
// MIN_SECTORS rows is refused as a whole, because a one-sector wheel is a bug
// and not a configuration.
SpinLoadConfig()
{
	g_bCfgOk = false
	g_iSectors = 0
	g_iWeightTotal = 0
	g_bEnabled = true
	g_iFreePerDay = 1
	g_iResetHour = 0
	g_iMaxStored = 10
	g_iFadeRarity = RAR_RARE
	g_fStep = 0.65
	copy(g_szTz, charsmax(g_szTz), "Europe/Paris")

	new cfgdir[96]
	get_configsdir(cfgdir, charsmax(cfgdir))
	formatex(g_szCfgPath, charsmax(g_szCfgPath), "%s/%s", cfgdir, CFG_FILE)

	if (!file_exists(g_szCfgPath))
		return

	new fp = fopen(g_szCfgPath, "rt")
	if (!fp)
	{
		log_amx("[WF-SPIN] could not open %s", g_szCfgPath)
		return
	}

	new line[256], section[24], lineno
	new bool:haveWheel
	while (fgets(fp, line, charsmax(line)))
	{
		lineno++
		trim(line)
		if (!line[0] || line[0] == ';' || line[0] == '#' || line[0] == '/')
			continue
		if (line[0] == '[')
		{
			new close = contain(line, "]")
			section[0] = 0
			if (close > 1)
			{
				new n = close - 1
				if (n > charsmax(section)) n = charsmax(section)
				for (new i = 0; i < n; i++)
					section[i] = tolower(line[i + 1])
				section[n] = 0
			}
			if (equal(section, "wheel"))
				haveWheel = true
			continue
		}
		if (equal(section, "wheel"))
			SpinParseWheelLine(line, lineno)
		else if (equal(section, "sector"))
			SpinParseSector(line, lineno)
	}

	fclose(fp)

	if (!haveWheel)
		log_amx("[WF-SPIN] %s has no [wheel] section - using the built-in defaults", CFG_FILE)
	if (g_iSectors < MIN_SECTORS)
	{
		log_amx("[WF-SPIN] %s has %d sector(s); at least %d are required - the wheel stays shut",
			CFG_FILE, g_iSectors, MIN_SECTORS)
		g_iSectors = 0
		return
	}
	if (g_iWeightTotal <= 0)
	{
		log_amx("[WF-SPIN] %s has no usable weight - the wheel stays shut", CFG_FILE)
		g_iSectors = 0
		return
	}
	g_bCfgOk = true
}

// [wheel] rows are `key = value`. `key | value` is accepted too, so an operator
// who copies the shape of a [sector] row is not silently ignored.
SpinParseWheelLine(const line[], lineno)
{
	new buf[96]
	copy(buf, charsmax(buf), line)

	new key[32], val[48]
	new sep = contain(buf, "=")
	if (sep < 0)
		sep = contain(buf, "|")
	if (sep < 1)
		return
	new cut = (sep > charsmax(key) - 1) ? charsmax(key) - 1 : sep
	for (new i = 0; i < cut; i++)
		key[i] = buf[i]
	key[cut] = 0
	trim(key)
	copy(val, charsmax(val), buf[sep + 1])
	trim(val)
	if (!key[0] || !val[0])
		return

	if (equal(key, "free_per_day"))
	{
		g_iFreePerDay = clamp(str_to_num(val), 0, 10)
	}
	else if (equal(key, "reset_hour"))
	{
		g_iResetHour = clamp(str_to_num(val), 0, 23)
	}
	else if (equal(key, "max"))
	{
		g_iMaxStored = clamp(str_to_num(val), 1, 1000)
	}
	else if (equal(key, "timezone"))
	{
		copy(g_szTz, charsmax(g_szTz), val)
	}
	else if (equal(key, "step"))
	{
		new Float:f = str_to_float(val)
		if (f < 0.4 || f > 1.5)
		{
			log_amx("[WF-SPIN] %s line %d: step %.2f is outside 0.4..1.5 - using 0.65", CFG_FILE, lineno, f)
			f = 0.65
		}
		g_fStep = f
	}
	else if (equal(key, "fade_rarity"))
	{
		new r = SpinRarityFromName(val)
		if (r < 0)
			log_amx("[WF-SPIN] %s line %d: unknown fade_rarity '%s' - using 'rare'", CFG_FILE, lineno, val)
		else
			g_iFadeRarity = r
	}
	else if (equal(key, "enabled"))
	{
		g_bEnabled = (str_to_num(val) != 0) ? true : false
	}
	else
	{
		log_amx("[WF-SPIN] %s line %d: unknown [wheel] key '%s' - ignored", CFG_FILE, lineno, key)
	}
}

SpinParseSector(const line[], lineno)
{
	if (g_iSectors >= MAX_SECTORS)
	{
		log_amx("[WF-SPIN] %s line %d: more than %d sectors - this row is ignored", CFG_FILE, lineno, MAX_SECTORS)
		return
	}

	new label[40], kinds[16], amount[16], weight[16], rarity[16]
	if (!WfField(line, 0, label, charsmax(label)) || !WfField(line, 1, kinds, charsmax(kinds))
		|| !WfField(line, 2, amount, charsmax(amount)) || !WfField(line, 3, weight, charsmax(weight))
		|| !WfField(line, 4, rarity, charsmax(rarity)))
	{
		log_amx("[WF-SPIN] %s line %d: expected 'label | kind | amount | weight | rarity' - skipped", CFG_FILE, lineno)
		return
	}

	if (!label[0] || contain(label, "%") >= 0)
	{
		// The label is printed through format strings ("%s" everywhere), but a
		// stray % inside it would still be read by show_hudmessage's formatter.
		// Refusing the row is the only answer that cannot half-work.
		log_amx("[WF-SPIN] %s line %d: the label must be non-empty and contain no '%%' - skipped", CFG_FILE, lineno)
		return
	}

	new kind = SpinKindFromName(kinds)
	if (kind < 0)
	{
		log_amx("[WF-SPIN] %s line %d: unknown kind '%s' - skipped", CFG_FILE, lineno, kinds)
		return
	}
	new rar = SpinRarityFromName(rarity)
	if (rar < 0)
	{
		log_amx("[WF-SPIN] %s line %d: unknown rarity '%s' - skipped", CFG_FILE, lineno, rarity)
		return
	}
	new w = str_to_num(weight)
	if (w < 2)
	{
		// A 1/100 sector sits inside the noise of the 1000-roll check (see the
		// ini header): refuse it loudly rather than ship odds nobody can verify.
		log_amx("[WF-SPIN] %s line %d: weight %d is below the minimum of 2 - skipped", CFG_FILE, lineno, w)
		return
	}
	new amt = str_to_num(amount)

	// A row that can never pay is a config bug. `nothing` and the "random
	// ornament" form (ornament with amount 0) are the legal zeros; a gift's
	// amount is a rarity index, so 0 (a common present) is a real value.
	if (kind != KIND_NOTHING && kind != KIND_ORNAMENT && amt <= 0 && kind != KIND_GIFT)
	{
		log_amx("[WF-SPIN] %s line %d: %s needs an amount - skipped", CFG_FILE, lineno, kinds)
		return
	}
	if (kind == KIND_GIFT && (amt < 0 || amt >= WF_RARITY_MAX))
	{
		log_amx("[WF-SPIN] %s line %d: gift rarity %d is outside 0..%d - skipped",
			CFG_FILE, lineno, amt, WF_RARITY_MAX - 1)
		return
	}
	if (kind == KIND_ORNAMENT && amt < 0)
	{
		log_amx("[WF-SPIN] %s line %d: ornament id %d is negative - skipped", CFG_FILE, lineno, amt)
		return
	}

	new s = g_iSectors
	copy(g_szLabel[s], charsmax(g_szLabel[]), label)
	g_iKind[s] = kind
	g_iAmount[s] = amt
	g_iWeight[s] = w
	g_iRarity[s] = rar
	g_iWeightTotal += w
	g_iSectors++
}

SpinKindFromName(const name[])
{
	for (new i = 0; i < KIND_COUNT; i++)
		if (equali(name, g_szKindName[i]))
			return i
	return -1
}

SpinRarityFromName(const name[])
{
	for (new i = 0; i < RAR_COUNT; i++)
		if (equali(name, g_szRarName[i]))
			return i
	return -1
}

// ============================================================
// Dependencies
// ============================================================
stock bool:WfSpinCore()
{
	return LibraryExists("winterfest_core", LibType_Library) ? true : false
}

stock bool:WfSpinWallet()
{
	return LibraryExists("menabp", LibType_Library) ? true : false
}

// The core publishes no "this player's record is in memory" native. A loaded
// player always has tree level >= 1 (the core sets 1 in WfClearMem and nothing
// lowers it) while an unloaded one answers 0 - the probe winterfest_progress and
// winterfest_menu already use. Documented in docs/WINTERFEST-SPIN.md §5.
stock bool:WfSpinReady(id)
{
	if (!WfSpinCore())
		return false
	return (wf_tree_level(id) > 0) ? true : false
}

stock bool:WfSpinSeason()
{
	if (!WfSpinCore())
		return false
	return wf_season_open() ? true : false
}

stock bool:WfSpinPlayerOk(id)
{
	if (!is_user_connected(id) || is_user_hltv(id))
		return false
	if (is_user_bot(id) && !get_cvar_num("wfspin_test_bots"))
		return false
	return true
}

// ============================================================
// The vault: serial + pending only (the counter lives in the core)
// ============================================================
stock bool:WfSpinVault()
{
	if (g_Vault != INVALID_HANDLE)
		return true
	g_Vault = nvault_open(VAULT_NAME)
	if (g_Vault == INVALID_HANDLE)
	{
		log_amx("[WF-SPIN] could not open vault '%s' - a spin could not be made crash-safe, so none is taken", VAULT_NAME)
		return false
	}
	return true
}

// wfspin_<base>#<authid with ':' -> '_'>[#<extra>], refused (never truncated)
// when long.
stock bool:WfSpinKey(id, const base[], const extra[], key[], len)
{
	key[0] = 0
	new auth[40]
	get_user_authid(id, auth, charsmax(auth))
	if (!auth[0])
		return false
	for (new i = 0; auth[i]; i++)
		if (auth[i] == ':')
			auth[i] = '_'

	if (extra[0])
		formatex(key, len, "wfspin_%s#%s#%s", base, auth, extra)
	else
		formatex(key, len, "wfspin_%s#%s", base, auth)

	if (strlen(key) >= MAX_KEY)
	{
		log_amx("[WF-SPIN] ERROR: vault key too long (%d >= %d): %s", strlen(key), MAX_KEY, key)
		key[0] = 0
		return false
	}
	return true
}

stock WfSpinSave(id)
{
	if (!WfSpinVault())
		return
	new key[MAX_KEY], val[48]
	if (!WfSpinKey(id, "meta", "", key, charsmax(key)))
		return
	formatex(val, charsmax(val), "%d|%s", g_iSerial[id], g_szPending[id])
	if (!nvault_set(g_Vault, key, val))
		log_amx("[WF-SPIN] WARNING: could not write %s for id %d", key, id)
}

// Read once per session. The flag matters: a claim key must NEVER be reused,
// and the only thing that makes it unique is a serial that keeps counting. A
// second read would restart it at the vault's value (correct), while a MISSING
// read would restart it at 0 and hand out keys the core's ledger has already
// spent - so every path that can spin asks for this first.
stock WfSpinEnsure(id)
{
	if (!g_bMetaLoaded[id])
		WfSpinLoad(id)
}

stock WfSpinLoad(id)
{
	g_iSerial[id] = 0
	g_szPending[id][0] = 0
	g_bMetaLoaded[id] = true
	if (!WfSpinVault())
		return
	new key[MAX_KEY], val[64]
	if (!WfSpinKey(id, "meta", "", key, charsmax(key)))
		return
	if (!nvault_get(g_Vault, key, val, charsmax(val)))
		return
	// "serial|pending" - both fields are optional so an older key still loads.
	new bar = contain(val, "|")
	if (bar < 0)
	{
		g_iSerial[id] = max(0, str_to_num(val))
		return
	}
	new ser[16]
	new n = (bar > charsmax(ser) - 1) ? charsmax(ser) - 1 : bar
	for (new i = 0; i < n; i++)
		ser[i] = val[i]
	ser[n] = 0
	g_iSerial[id] = max(0, str_to_num(ser))
	copy(g_szPending[id], charsmax(g_szPending[]), val[bar + 1])
}

// The marker that makes the ONE prize without a ledger (a spin back) pay once.
// write=false is a read: "was this serial already paid?".
stock bool:WfSpinPayMark(id, serial, bool:write)
{
	if (!WfSpinVault())
		return false
	new extra[16], key[MAX_KEY]
	num_to_str(serial, extra, charsmax(extra))
	if (!WfSpinKey(id, "pd", extra, key, charsmax(key)))
		return false
	if (write)
		return nvault_set(g_Vault, key, "1") ? true : false
	new val[8]
	return nvault_get(g_Vault, key, val, charsmax(val)) ? true : false
}

// ============================================================
// The roll
// ============================================================
// Returns the winning sector of the FULL table (no eligibility filter) and
// reports the numbers the log line quotes. Used by /spin, by the harness and by
// `wfspin_roll`, so what a player gets and what the odds document says come from
// one function.
stock bool:SpinRollRaw(&sector, &roll, &total)
{
	total = g_iWeightTotal
	sector = 0
	if (total <= 0 || g_iSectors <= 0)
	{
		roll = 0
		return false
	}
	roll = random_num(1, total)
	new acc = 0
	for (new s = 0; s < g_iSectors; s++)
	{
		acc += g_iWeight[s]
		if (roll <= acc)
		{
			sector = s
			return true
		}
	}
	// Unreachable while total == sum(weights); kept so a corrupted table pays
	// the last sector instead of indexing past the array.
	sector = g_iSectors - 1
	return true
}

// A sector whose prize cannot be paid right now is excluded rather than paid as
// nothing. This keeps one honest promise: a consumed token always buys a real
// prize, or no token is consumed at all.
stock bool:SpinEligible(id, s)
{
	if (g_bSeamNoSpin && g_iKind[s] == KIND_SPIN)
		return false   // TEST SEAM: the at-the-cap case (see g_bSeamNoSpin)

	switch (g_iKind[s])
	{
		case KIND_NOTHING:
			return true
		case KIND_GINGERBREAD:
			// The core is loaded and ready for this player (checked before the
			// roll); nothing else can fail.
			return true
		case KIND_COINS:
			return (WfSpinWallet() && menabp_is_ready(id)) ? true : false
		case KIND_ORNAMENT:
			return (SpinPickOrnament(id, g_iAmount[s], false) > 0) ? true : false
		case KIND_TITLE:
			return SpinTitleAvailable(id, g_iAmount[s])
		case KIND_SPIN:
			return (wf_get_spins(id) < g_iMaxStored) ? true : false
		case KIND_GIFT:
			return (wf_gift_count(id) < WF_MAX_GIFTS) ? true : false
	}
	return false
}

// The weighted roll restricted to eligible sectors: the weights of excluded
// sectors are redistributed over the rest, so the wheel keeps paying 100 % of
// the time. `excluded` reports how many sectors were left out (0 on a healthy
// account) so the caller can say it once.
stock bool:SpinRollEligible(id, &sector, &roll, &total, &excluded)
{
	sector = 0
	roll = 0
	total = 0
	excluded = 0
	new eligible[MAX_SECTORS]
	new n = 0
	for (new s = 0; s < g_iSectors; s++)
	{
		if (SpinEligible(id, s))
		{
			eligible[n++] = s
			total += g_iWeight[s]
		}
		else
			excluded++
	}
	if (!n || total <= 0)
		return false
	roll = random_num(1, total)
	new acc = 0
	for (new i = 0; i < n; i++)
	{
		new s = eligible[i]
		acc += g_iWeight[s]
		if (roll <= acc)
		{
			sector = s
			return true
		}
	}
	sector = eligible[n - 1]
	return true
}

// ============================================================
// /spin - the player entry point
// ============================================================
public cmdSpin(id, level, cid)
{
	#pragma unused level, cid
	if (id <= 0)
	{
		console_print(0, "[WF-SPIN] /spin is a player command; use wfspin_state / wfspin_grant from the console.")
		return PLUGIN_HANDLED
	}
	if (!WfSpinPlayerOk(id))
		return PLUGIN_HANDLED

	// Every reason the wheel can be shut, in the order a player can act on.
	if (!g_bCfgOk)
	{
		WfSay(id, "the wheel is not configured - an admin has to check configs/freenova/winterfest/spin.ini.")
		return PLUGIN_HANDLED
	}
	if (!g_bEnabled)
	{
		WfSay(id, "the wheel is switched off for now.")
		return PLUGIN_HANDLED
	}
	if (!WfSpinCore())
	{
		if (!g_bLoggedNoCore)
		{
			g_bLoggedNoCore = true
			log_amx("[WF-SPIN] /spin refused: winterfest_core is not loaded (no counter, no prize)")
		}
		WfSay(id, "the wheel is unavailable right now - no spin was used.")
		return PLUGIN_HANDLED
	}
	if (!WfSpinSeason())
	{
		new name[48], win[48], text[128]
		wf_season_name(name, charsmax(name))
		wf_season_window(win, charsmax(win))
		formatex(text, charsmax(text), "the wheel is shut - %s %s. Your spins are kept.", name, win)
		WfSay(id, text)
		return PLUGIN_HANDLED
	}
	if (!WfSpinReady(id))
	{
		WfSay(id, "your Winterfest record is still loading - try /spin again in a second.")
		return PLUGIN_HANDLED
	}

	new spins = wf_get_spins(id)
	new reset[64], text[192]
	SpinResetText(reset, charsmax(reset))
	formatex(text, charsmax(text), "you have^3 %d^1 spin%s. %s", spins, (spins == 1) ? "" : "s", reset)
	WfSay(id, text)

	// The brief: a player with zero spins gets one clear line and no wheel.
	if (spins <= 0)
	{
		WfSay(id, "no spins left - the free one arrives with the daily reset, and presents, Advent days and the pass hand out more.")
		return PLUGIN_HANDLED
	}

	new menu = menu_create("\ySpin Wheel\w", "SpinMenuHandler")
	menu_additem(menu, "\ySpin the wheel\w", "1")
	menu_additem(menu, "Prize table", "2")
	menu_additem(menu, "Close", "3")
	menu_display(id, menu)
	return PLUGIN_HANDLED
}

public SpinMenuHandler(id, menu, item)
{
	if (item < 0)
	{
		menu_destroy(menu)
		return PLUGIN_HANDLED
	}
	if (!is_user_connected(id))
	{
		menu_destroy(menu)
		return PLUGIN_HANDLED
	}
	new info[8], dummy[1], access, callback
	menu_item_getinfo(menu, item, access, info, charsmax(info), dummy, 0, callback)
	menu_destroy(menu)
	new pick = str_to_num(info)
	if (pick == 1)
		SpinStart(id)
	else if (pick == 2)
		SpinPrintTable(id)
	return PLUGIN_HANDLED
}

// "Reset 00:00 Europe/Paris (in 4h 12m)". Honest by construction: the wall
// clock is the configured one and the countdown is derived from it.
stock SpinResetText(out[], len)
{
	new secs = SpinSecondsToReset()
	formatex(out, len, "Reset %02d:00 %s (in %dh %02dm).", g_iResetHour, g_szTz, secs / 3600, (secs % 3600) / 60)
}

// The prize table in chat: every sector with its configured chance.
stock SpinPrintTable(id)
{
	new line[128]
	WfSay(id, "the prizes (chance per spin):")
	for (new s = 0; s < g_iSectors; s++)
	{
		formatex(line, charsmax(line), "^3%s^1 - %s %d, %.1f%% (%s)",
			g_szLabel[s], g_szKindName[g_iKind[s]], g_iAmount[s],
			(g_iWeightTotal > 0) ? (100.0 * float(g_iWeight[s]) / float(g_iWeightTotal)) : 0.0,
			g_szRarName[clamp(g_iRarity[s], 0, RAR_COUNT - 1)])
		WfSay(id, line)
	}
	new excluded = 0
	for (new s = 0; s < g_iSectors; s++)
		if (!SpinEligible(id, s))
			excluded++
	if (excluded > 0)
	{
		formatex(line, charsmax(line), "%d of %d prizes are skipped for you right now (already owned, bag full or wallet loading); their chance goes to the rest.",
			excluded, g_iSectors)
		WfSay(id, line)
	}
}

// ============================================================
// The spin: consume, roll, record, reveal, pay
// ============================================================
stock SpinStart(id)
{
	if (!WfSpinPlayerOk(id))
		return
	// 1. one spin in flight per player (anti-dupe rule 1)
	if (g_bSpinning[id])
	{
		WfSay(id, "the wheel is already turning - let it stop.")
		log_amx("[WF-SPIN] id %d refused: a spin is already in flight", id)
		return
	}
	if (!WfSpinReady(id))
	{
		WfSay(id, "your Winterfest record is still loading - try again in a second.")
		return
	}

	// 2. the token is consumed FIRST, and only if the core says it took one.
	if (!wf_consume_spin(id))
	{
		WfSay(id, "you have no spins left - no token was taken.")
		log_amx("[WF-SPIN] id %d refused: wf_consume_spin said 0 (balance %d)", id, wf_get_spins(id))
		return
	}

	// 3. the roll, restricted to prizes this player can actually receive.
	new sector, roll, total, excluded
	if (!SpinRollEligible(id, sector, roll, total, excluded))
	{
		// Nothing at all can be paid (a broken counter, a wallet-less deployment
		// whose wheel is coin-only, ...). Give the token back: a consumed token
		// that buys nothing is the one outcome this module refuses to ship.
		wf_add_spins(id, 1)
		WfSay(id, "there is nothing to win right now - your spin was returned.")
		log_amx("[WF-SPIN] id %d: no eligible sector, token refunded (balance %d)", id, wf_get_spins(id))
		return
	}

	if (excluded > 0)
		log_amx("[WF-SPIN] id %d: %d of %d sectors excluded as unpayable for this player; rolled inside the remaining weight %d",
			id, excluded, g_iSectors, total)

	// 4. the intent is written to the vault BEFORE anything is announced or
	//    paid: serial + sector is exactly what a reconnect needs to finish the
	//    spin through the same claim key (anti-dupe rule 3).
	WfSpinEnsure(id)
	if (!WfSpinVault())
	{
		wf_add_spins(id, 1)
		WfSay(id, "the wheel cannot record this spin right now - your spin was returned.")
		return
	}
	g_iSerial[id]++
	g_iWinSerial[id] = g_iSerial[id]
	g_iWinSector[id] = sector
	formatex(g_szPending[id], charsmax(g_szPending[]), "%d:%d", g_iSerial[id], sector)
	WfSpinSave(id)

	log_amx("[WF-SPIN] roll id %d: r=%d/%d -> sector #%d '%s' (%s %d, weight %d, rarity %s) serial %d; balance now %d",
		id, roll, total, sector + 1, g_szLabel[sector], g_szKindName[g_iKind[sector]],
		g_iAmount[sector], g_iWeight[sector],
		g_szRarName[clamp(g_iRarity[sector], 0, RAR_COUNT - 1)],
		g_iWinSerial[id], wf_get_spins(id))

	g_bSpinning[id] = true
	g_iStep[id] = 0
	g_iPaidId[id] = 0
	g_iPaidAmount[id] = 0

	// The first frame, immediately: something happens on the keypress.
	new text[96]
	formatex(text, charsmax(text), "the wheel turns... (%d spin%s left)", wf_get_spins(id),
		(wf_get_spins(id) == 1) ? "" : "s")
	WfSay(id, text)
	SpinHud(id, "spinning", -1)

	set_task(g_fStep, "TaskReveal", TASK_STEP + id, _, _, "b", REVEAL_STEPS)
}

// The reveal. Steps 1..3 are flicker (a random sector label, so the eye follows
// the ring), step 4 pays and announces. Chat carries the narration and the HUD
// carries the label, because a HUD alone is easy to miss in a firefight.
public TaskReveal(taskid)
{
	new id = taskid - TASK_STEP
	if (id <= 0 || id > MAX_PLAYERS || !g_bSpinning[id])
	{
		remove_task(taskid)
		return
	}

	g_iStep[id]++
	if (g_iStep[id] < REVEAL_STEPS)
	{
		new flick = random_num(0, g_iSectors - 1)
		SpinHud(id, g_szLabel[flick], g_iRarity[flick])
		return
	}

	remove_task(taskid)
	SpinFinish(id)
}

// Pay, then announce. The claim key names the spin, not the time, so a client
// that dropped after the consume and comes back is paid by SpinResume() with the
// same key and cannot be paid twice.
stock SpinFinish(id)
{
	if (!g_bSpinning[id])
		return

	new sector = clamp(g_iWinSector[id], 0, g_iSectors - 1)
	new serial = g_iWinSerial[id]

	new claim[32]
	formatex(claim, charsmax(claim), "wfspin#%d", serial)

	new code = SpinPay(id, sector, serial, claim)

	// The intent is done with, whatever the result: the claim key (or the
	// per-serial marker) is the record now.
	g_szPending[id][0] = 0
	g_bSpinning[id] = false
	WfSpinSave(id)

	SpinAnnounce(id, sector, code)
}

stock SpinPay(id, sector, serial, const claim[])
{
	g_iPaidId[id] = 0
	g_iPaidAmount[id] = 0

	switch (g_iKind[sector])
	{
		case KIND_NOTHING:
			return PAY_OK

		case KIND_GINGERBREAD:
		{
			g_iPaidAmount[id] = g_iAmount[sector]
			new code = wf_grant(id, WF_REWARD_GINGERBREAD, g_iAmount[sector], claim)
			if (code == WF_GRANT_OK)
				return PAY_OK
			return (code == WF_GRANT_DUPLICATE) ? PAY_DUP : PAY_FAIL
		}

		case KIND_COINS:
		{
			if (!WfSpinWallet() || !menabp_is_ready(id))
				return PAY_FAIL
			g_iPaidAmount[id] = g_iAmount[sector]
			// menabp's award ledger: -1 not ready, 0 already awarded, >0 balance.
			new n = menabp_add_coins_once(id, g_iAmount[sector], claim)
			if (n > 0)
				return PAY_OK
			if (n == 0)
				return PAY_DUP
			log_amx("[WF-SPIN] id %d: coin prize %d refused by the wallet (code %d)", id, g_iAmount[sector], n)
			return PAY_FAIL
		}

		case KIND_ORNAMENT:
		{
			new orn = SpinPickOrnament(id, g_iAmount[sector], true)
			if (orn <= 0)
				return PAY_FAIL
			g_iPaidId[id] = orn
			new code = wf_grant(id, WF_REWARD_ORNAMENT, orn, claim)
			if (code == WF_GRANT_OK)
				return PAY_OK
			return (code == WF_GRANT_DUPLICATE) ? PAY_DUP : PAY_FAIL
		}

		case KIND_TITLE:
		{
			g_iPaidId[id] = g_iAmount[sector]
			new code = wf_grant(id, WF_REWARD_TITLE, g_iAmount[sector], claim)
			if (code == WF_GRANT_OK)
				return PAY_OK
			return (code == WF_GRANT_DUPLICATE) ? PAY_DUP : PAY_FAIL
		}

		case KIND_GIFT:
		{
			new rar = clamp(g_iAmount[sector], 0, WF_RARITY_MAX - 1)
			g_iPaidId[id] = rar
			new code = wf_grant(id, WF_REWARD_GIFT, rar, claim)
			if (code == WF_GRANT_OK)
				return PAY_OK
			return (code == WF_GRANT_DUPLICATE) ? PAY_DUP : PAY_FAIL
		}

		case KIND_SPIN:
		{
			// The only prize the core has no ledger for. The marker is written
			// BEFORE the add, so a crash between the two loses a spin instead of
			// granting two (fail closed, the same trade the core's claim ledger
			// makes).
			if (WfSpinPayMark(id, serial, false))
				return PAY_DUP
			if (!WfSpinPayMark(id, serial, true))
				return PAY_FAIL
			new before = wf_get_spins(id)
			wf_add_spins(id, g_iAmount[sector])
			new after = wf_get_spins(id)
			g_iPaidAmount[id] = after - before
			return (after > before) ? PAY_OK : PAY_FAIL
		}
	}
	return PAY_FAIL
}

stock SpinAnnounce(id, sector, code)
{
	new text[192], prize[96]
	new rar = clamp(g_iRarity[sector], 0, RAR_COUNT - 1)
	SpinPrizeText(id, sector, prize, charsmax(prize))

	if (code == PAY_OK)
	{
		formatex(text, charsmax(text), "^3%s^1 - %s", g_szRarName[rar], prize)
		WfSay(id, text)
		SpinHud(id, g_szLabel[sector], rar)
		// The fade is what makes a good result feel different from a bad one,
		// and it is engine stock (ScreenFade), not a client asset.
		if (rar >= g_iFadeRarity)
			SpinFade(id, rar)
	}
	else if (code == PAY_DUP)
	{
		formatex(text, charsmax(text), "%s was already paid for this spin - nothing is paid twice.", prize)
		WfSay(id, text)
		SpinHud(id, g_szLabel[sector], rar)
	}
	else
	{
		formatex(text, charsmax(text), "the prize '%s' could not be paid - the log has the details, an admin can make it right.", g_szLabel[sector])
		WfSay(id, text)
		SpinHud(id, "could not pay", RAR_COMMON)
	}
	log_amx("[WF-SPIN] spin result id %d: sector #%d '%s' -> %s (%s %d)", id, sector + 1, g_szLabel[sector],
		(code == PAY_OK) ? "paid" : (code == PAY_DUP) ? "already-paid" : "FAILED",
		g_szKindName[g_iKind[sector]], g_iAmount[sector])
}

// What was actually handed out, in words, for the chat line.
stock SpinPrizeText(id, sector, out[], len)
{
	switch (g_iKind[sector])
	{
		case KIND_NOTHING:
			copy(out, len, "nothing this time")
		case KIND_GINGERBREAD:
			formatex(out, len, "+%d GingerBread", g_iAmount[sector])
		case KIND_COINS:
			formatex(out, len, "+%d coins", g_iAmount[sector])
		case KIND_ORNAMENT:
		{
			new name[40]
			name[0] = 0
			if (g_iPaidId[id] > 0)
				wf_ornament_name(g_iPaidId[id], name, charsmax(name))
			if (name[0])
				formatex(out, len, "ornament: %s", name)
			else
				copy(out, len, "an ornament")
		}
		case KIND_TITLE:
		{
			new title[40]
			title[0] = 0
			if (g_iAmount[sector] > 0)
				wf_set_title(g_iAmount[sector], title, charsmax(title))
			if (title[0])
				formatex(out, len, "collector title: %s", title)
			else
				copy(out, len, "a collector title")
		}
		case KIND_GIFT:
		{
			new rname[24]
			rname[0] = 0
			wf_rarity_name(clamp(g_iAmount[sector], 0, WF_RARITY_MAX - 1), rname, charsmax(rname))
			if (rname[0])
				formatex(out, len, "a %s present", rname)
			else
				copy(out, len, "a present")
		}
		case KIND_SPIN:
		{
			if (g_iPaidAmount[id] > 0)
				formatex(out, len, "+%d spin back", g_iPaidAmount[id])
			else
				copy(out, len, "a spin back (nothing to add at the cap)")
		}
		default:
			copy(out, len, g_szLabel[sector])
	}
}

// ============================================================
// Prize helpers
// ============================================================
// An ornament prize: `want` > 0 names the id, 0 means "one you do not own yet".
// Returns 0 when there is nothing left to give (all owned, or a bad id).
stock SpinPickOrnament(id, want, bool:randomise)
{
	new total = wf_ornament_total()
	if (total <= 0)
		return 0
	if (want > 0)
	{
		if (want > total)
			return 0
		return (wf_has_ornament(id, want)) ? 0 : want
	}

	// A random start plus a fixed stride, so the pick is not always "the lowest
	// id you are missing" while still terminating in at most `total` steps.
	new start = randomise ? random_num(1, total) : 1
	new stride = 7
	for (new i = 0; i < total; i++)
	{
		new orn = ((start - 1 + i * stride) % total) + 1
		if (!wf_has_ornament(id, orn))
			return orn
	}
	return 0
}

stock bool:SpinTitleAvailable(id, set)
{
	if (set < 1)
		return false
	new title[40]
	title[0] = 0
	wf_set_title(set, title, charsmax(title))
	if (!title[0])
		return false
	return (wf_set_owned(id, set) == 0) ? true : false
}

// ============================================================
// Effects (stock messages only - no client asset, no precache)
// ============================================================
stock SpinHud(id, const label[], rarity)
{
	new r = 235, g = 240, b = 255
	if (rarity >= 0 && rarity < RAR_COUNT)
	{
		r = g_iRarColor[rarity][0]
		g = g_iRarColor[rarity][1]
		b = g_iRarColor[rarity][2]
	}
	// Channel 3: clear of the module HUD's channels (fn_hud uses 1/2), so a
	// wheel never eats another plugin's line.
	set_hudmessage(r, g, b, -1.0, 0.28, 0, 1.0, 1.1, 0.05, 0.20, 3)
	show_hudmessage(id, "  %s  ", label)
}

stock SpinFade(id, rarity)
{
	new i = clamp(rarity, 0, RAR_COUNT - 1)
	message_begin(MSG_ONE_UNRELIABLE, get_user_msgid("ScreenFade"), _, id)
	write_short(floatround(4096.0 * 0.35))   // duration
	write_short(floatround(4096.0 * 0.15))   // hold
	write_short(0x0001)                      // fade out
	write_byte(g_iRarColor[i][0])
	write_byte(g_iRarColor[i][1])
	write_byte(g_iRarColor[i][2])
	// Deliberately not near-white: freenova_flash owns the white flash.
	write_byte(90)
	message_end()
}

// ============================================================
// Connect / disconnect: the pending spin
// ============================================================
public client_putinserver(id)
{
	if (id <= 0 || id > MAX_PLAYERS)
		return
	WfSpinClearMem(id)
	if (!is_user_hltv(id))
		WfSpinLoad(id)          // always: the claim-key serial must never restart
	if (!WfSpinPlayerOk(id) || !g_bCfgOk || !WfSpinSeason())
		return
	if (g_szPending[id][0])
	{
		// The core loads a client's record in its own task; retry until it is
		// ready (12 x 1 s) instead of paying into an unloaded ledger.
		set_task(1.0, "TaskResume", TASK_RESUME + id, _, _, "b", 12)
	}
}

public client_disconnected(id)
{
	if (id <= 0 || id > MAX_PLAYERS)
		return
	// A wheel still turning when the client leaves: the token is spent and the
	// sector is already in the vault, so the player is paid on the next connect
	// through the same claim key. Nothing to do here but stop the task.
	remove_task(TASK_STEP + id)
	remove_task(TASK_RESUME + id)
	if (g_bSpinning[id])
		log_amx("[WF-SPIN] id %d disconnected mid-reveal; spin %d (sector %d) stays pending and pays on the next connect",
			id, g_iWinSerial[id], g_iWinSector[id] + 1)
	WfSpinClearMem(id)
}

public TaskResume(taskid)
{
	new id = taskid - TASK_RESUME
	if (id <= 0 || id > MAX_PLAYERS || !is_user_connected(id) || !g_szPending[id][0])
	{
		remove_task(taskid)
		return
	}
	if (!WfSpinReady(id))
		return   // still loading; the task's 12 repeats are the budget
	remove_task(taskid)
	SpinResume(id)
}

// The resume path. Same claim key, so it is the same payment: exactly once.
stock SpinResume(id)
{
	// Nothing to resume: the common case on every connect, and the case a second
	// reconnect hits. One line, no log, no payment.
	if (!g_szPending[id][0])
		return

	new serial, sector
	if (!SpinParsePending(id, serial, sector))
	{
		log_amx("[WF-SPIN] id %d: unreadable pending spin '%s' dropped", id, g_szPending[id])
		g_szPending[id][0] = 0
		WfSpinSave(id)
		return
	}

	g_iWinSerial[id] = serial
	g_iWinSector[id] = sector

	new claim[32]
	formatex(claim, charsmax(claim), "wfspin#%d", serial)
	new code = SpinPay(id, sector, serial, claim)

	g_szPending[id][0] = 0
	WfSpinSave(id)

	new text[192], prize[96]
	SpinPrizeText(id, sector, prize, charsmax(prize))
	if (code == PAY_OK)
		formatex(text, charsmax(text), "your interrupted spin finished: %s", prize)
	else if (code == PAY_DUP)
		formatex(text, charsmax(text), "your interrupted spin was already paid: %s", prize)
	else
		formatex(text, charsmax(text), "your interrupted spin could not be paid ('%s') - the log has the details.", g_szLabel[sector])
	WfSay(id, text)
	log_amx("[WF-SPIN] resume id %d: serial %d sector #%d '%s' -> %s", id, serial, sector + 1,
		g_szLabel[sector],
		(code == PAY_OK) ? "paid" : (code == PAY_DUP) ? "already-paid" : "FAILED")
}

stock bool:SpinParsePending(id, &serial, &sector)
{
	new buf[24], tail[8]
	copy(buf, charsmax(buf), g_szPending[id])
	new colon = contain(buf, ":")
	if (colon < 1)
		return false
	serial = str_to_num(buf)
	copy(tail, charsmax(tail), buf[colon + 1])
	sector = str_to_num(tail)
	if (serial <= 0 || sector < 0 || sector >= g_iSectors)
		return false
	return true
}

stock WfSpinClearMem(id)
{
	g_iSerial[id] = 0
	g_bMetaLoaded[id] = false
	g_szPending[id][0] = 0
	g_bSpinning[id] = false
	g_iStep[id] = 0
	g_iWinSector[id] = 0
	g_iWinSerial[id] = 0
	g_iPaidId[id] = 0
	g_iPaidAmount[id] = 0
}

// ============================================================
// Operator commands
// ============================================================
public cmdGrant(id, level, cid)
{
	if (!cmd_access(id, level, cid, 3))
		return PLUGIN_HANDLED

	new arg_n[16], arg_target[40]
	read_argv(1, arg_n, charsmax(arg_n))
	read_argv(2, arg_target, charsmax(arg_target))

	new n = str_to_num(arg_n)
	if (n <= 0)
	{
		console_print(id, "[WF-SPIN] usage: wfspin_grant <n> <target|all>")
		return PLUGIN_HANDLED
	}
	if (!WfSpinCore())
	{
		console_print(id, "[WF-SPIN] winterfest_core is not loaded: there is no counter to add to")
		return PLUGIN_HANDLED
	}

	new targets[MAX_PLAYERS], tnum
	SpinTargets(arg_target, targets, MAX_PLAYERS, tnum)
	if (!tnum)
	{
		console_print(id, "[WF-SPIN] no client matched '%s'", arg_target)
		return PLUGIN_HANDLED
	}

	for (new t = 0; t < tnum; t++)
	{
		new p = targets[t]
		new pname[MAX_NAME_LENGTH]
		get_user_name(p, pname, charsmax(pname))
		new have = wf_get_spins(p)
		// The product cap is this file's `max`: a gift, an Advent day or an
		// admin cannot build a pile nobody spends. The core's own ceiling is
		// 1,000,000, which is a sanity bound, not a product decision.
		if (have >= g_iMaxStored)
		{
			console_print(id, "[WF-SPIN] %s (%d) is at the cap (%d) - nothing added", pname, p, g_iMaxStored)
			log_amx("[WF-SPIN] grant to id %d refused: at cap %d", p, g_iMaxStored)
			continue
		}
		new add = min(n, g_iMaxStored - have)
		wf_add_spins(p, add)
		console_print(id, "[WF-SPIN] %s (%d): +%d -> %d%s", pname, p, add, wf_get_spins(p),
			(add < n) ? " (clamped by the cap)" : "")
		log_amx("[WF-SPIN] admin %d granted %d spin(s) to id %d (requested %d, cap %d, balance %d)",
			id, add, p, n, g_iMaxStored, wf_get_spins(p))
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
	SpinTargets(arg_target, targets, MAX_PLAYERS, tnum)
	if (!tnum)
	{
		console_print(id, "[WF-SPIN] no client matched '%s'", arg_target)
		return PLUGIN_HANDLED
	}

	console_print(id, "[WF-SPIN] wheel: %d sector(s), total weight %d, cfg=%s, path=%s",
		g_iSectors, g_iWeightTotal, g_bCfgOk ? "ok" : "MISSING", g_szCfgPath)
	console_print(id, "[WF-SPIN] config: free_per_day=%d (display; the core owns the daily), reset=%02d:00 %s, cap=%d, step=%dms, fade=%s+, enabled=%d",
		g_iFreePerDay, g_iResetHour, g_szTz, g_iMaxStored, floatround(g_fStep * 1000.0),
		g_szRarName[clamp(g_iFadeRarity, 0, RAR_COUNT - 1)], g_bEnabled ? 1 : 0)
	console_print(id, "[WF-SPIN] deps: core=%s season=%s wallet=%s vault=%s",
		WfSpinCore() ? "yes" : "no",
		(WfSpinCore() && wf_season_open()) ? "open" : "closed",
		WfSpinWallet() ? "yes" : "no",
		(g_Vault != INVALID_HANDLE) ? "open" : "not opened")

	new now = get_systime()
	new offset = SpinParisOffset(now)
	new stamp[24], today[16]
	SpinStamp(now, offset, stamp, charsmax(stamp))
	SpinTodayKey(today, charsmax(today))
	console_print(id, "[WF-SPIN] clock: paris=%s (offset %d s) spin-day=%d reset-hour=%d next-reset=%d s core-claim-day=%s",
		stamp, offset, SpinDayIndex(now), g_iResetHour, SpinSecondsToReset(), today)

	for (new t = 0; t < tnum; t++)
	{
		new p = targets[t]
		new pname[MAX_NAME_LENGTH]
		get_user_name(p, pname, charsmax(pname))
		if (is_user_connected(p))
			WfSpinEnsure(p)
		new ready = WfSpinReady(p) ? 1 : 0
		new spins = ready ? wf_get_spins(p) : 0
		new excluded = 0
		if (ready)
			for (new s = 0; s < g_iSectors; s++)
				if (!SpinEligible(p, s))
					excluded++
		console_print(id, "[WF-SPIN] %s (%d) ready=%d spins=%d/%d serial=%d pending='%s' spinning=%d excluded=%d/%d",
			pname, p, ready, spins, g_iMaxStored, g_iSerial[p],
			g_szPending[p][0] ? g_szPending[p] : "-", g_bSpinning[p] ? 1 : 0,
			excluded, g_iSectors)
	}
	return PLUGIN_HANDLED
}

public cmdReload(id, level, cid)
{
	if (!cmd_access(id, level, cid, 1))
		return PLUGIN_HANDLED
	// Never between a consume and its payment: a live wheel finishes first.
	new busy = 0
	for (new p = 1; p <= MAX_PLAYERS; p++)
		if (g_bSpinning[p])
			busy++
	if (busy)
	{
		console_print(id, "[WF-SPIN] %d wheel(s) still turning - reload refused, try again in a second", busy)
		return PLUGIN_HANDLED
	}
	SpinLoadConfig()
	console_print(id, "[WF-SPIN] reloaded %s: %d sector(s), weight %d, cap %d, cfg=%s",
		g_szCfgPath, g_iSectors, g_iWeightTotal, g_iMaxStored, g_bCfgOk ? "ok" : "MISSING")
	log_amx("[WF-SPIN] config reloaded: %d sector(s), total weight %d, cap %d, enabled=%d",
		g_iSectors, g_iWeightTotal, g_iMaxStored, g_bEnabled ? 1 : 0)
	return PLUGIN_HANDLED
}

// The odds proof, in game: run the REAL roll n times and print observed against
// configured. The tolerance is 5 sigma per sector (sigma = sqrt(n p (1-p))),
// which for n=1000 is a sanity bound and not a uniformity proof - the offline
// harness (tests/winterfest-spin/test_odds.py) does 200k rolls and a chi-square
// for that. Reordering the ini must not change a single line of this output.
public cmdRoll(id, level, cid)
{
	if (!cmd_access(id, level, cid, 2))
		return PLUGIN_HANDLED

	new arg[16]
	read_argv(1, arg, charsmax(arg))
	new n = clamp(str_to_num(arg), 100, 200000)
	if (!g_iSectors || g_iWeightTotal <= 0)
	{
		console_print(id, "[WF-SPIN] no wheel configured - nothing to roll")
		return PLUGIN_HANDLED
	}

	new counts[MAX_SECTORS]
	new sector, roll, total
	for (new i = 0; i < n; i++)
	{
		if (!SpinRollRaw(sector, roll, total))
			break
		counts[sector]++
	}

	console_print(id, "[WF-SPIN] %d rolls (full table, no eligibility filter), total weight %d", n, g_iWeightTotal)
	console_print(id, "[WF-SPIN] %-2s %-20s %-11s %6s %8s %8s %8s %s",
		"#", "label", "kind", "weight", "expect", "observed", "delta", "verdict")

	new bad = 0, seen = 0
	for (new s = 0; s < g_iSectors; s++)
	{
		seen += counts[s]
		new Float:p = float(g_iWeight[s]) / float(g_iWeightTotal)
		new Float:expected = p * float(n)
		new Float:delta = float(counts[s]) - expected
		if (delta < 0.0)
			delta = -delta
		// 5 sigma, in float arithmetic (n is bounded to 200000 so this is exact
		// enough on any platform).
		new Float:sigma = floatsqroot(float(n) * p * (1.0 - p))
		new Float:tol = sigma * 5.0
		if (tol < 2.0)
			tol = 2.0
		new bool:inTol = (delta <= tol) ? true : false
		if (!inTol)
			bad++
		console_print(id, "[WF-SPIN] %-2d %-20s %-11s %6d %8.1f %8d %8.1f %s",
			s + 1, g_szLabel[s], g_szKindName[g_iKind[s]], g_iWeight[s],
			expected, counts[s], delta, inTol ? "ok" : "OUT-OF-TOLERANCE")
	}

	console_print(id, "[WF-SPIN] observed %d of %d rolls", seen, n)
	if (bad == 0)
		console_print(id, "[WF-SPIN] PASS odds-%d: every sector is inside 5 sigma of its configured weight", n)
	else
		console_print(id, "[WF-SPIN] FAIL odds-%d: %d sector(s) outside 5 sigma", n, bad)
	log_amx("[WF-SPIN] odds check: %d rolls, %d sector(s) outside tolerance, %d sector(s) configured",
		n, bad, g_iSectors)
	return PLUGIN_HANDLED
}

// The daily-reset clock, printable for any timestamp so the arithmetic can be
// checked against known dates instead of "it looked right in December".
public cmdDay(id, level, cid)
{
	if (!cmd_access(id, level, cid, 1))
		return PLUGIN_HANDLED

	new arg[24]
	read_argv(1, arg, charsmax(arg))
	new now = arg[0] ? str_to_num(arg) : get_systime()
	if (now <= 0)
		now = get_systime()

	new offset = SpinParisOffset(now)
	new utc[24], paris[24], today[16]
	SpinStamp(now, 0, utc, charsmax(utc))
	SpinStamp(now, offset, paris, charsmax(paris))
	SpinTodayKey(today, charsmax(today))
	console_print(id, "[WF-SPIN] t=%d utc=%s paris=%s offset=%d spin-day=%d reset-hour=%d core-claim-day=%s",
		now, utc, paris, offset, SpinDayIndex(now), g_iResetHour, today)
	console_print(id, "[WF-SPIN] next reset in %d s (%dh %02dm)",
		SpinSecondsToReset(), SpinSecondsToReset() / 3600, (SpinSecondsToReset() % 3600) / 60)
	return PLUGIN_HANDLED
}

// ============================================================
// Harness seams (docs/WINTERFEST-SPIN.md §7)
// ============================================================
// These drive the real code paths with nobody at the keyboard. They act on
// connected clients only and need `wfspin_test_bots 1` (the harness has bots,
// and a bot may not use the wheel in production).
public cmdDrive(id, level, cid)
{
	if (!cmd_access(id, level, cid, 2))
		return PLUGIN_HANDLED
	if (!get_cvar_num("wfspin_test_bots"))
	{
		console_print(id, "[WF-SPIN] wfspin_drive needs wfspin_test_bots 1 (it acts as the player)")
		return PLUGIN_HANDLED
	}

	new arg[16], arg2[16]
	read_argv(1, arg, charsmax(arg))
	read_argv(2, arg2, charsmax(arg2))
	new n = clamp(str_to_num(arg), 1, 50)
	g_bSeamNoSpin = equal(arg2, "plain") ? true : false

	new players[MAX_PLAYERS], num
	get_players(players, num, "h")
	if (!num)
	{
		g_bSeamNoSpin = false
		console_print(id, "[WF-SPIN] no client to drive")
		return PLUGIN_HANDLED
	}

	for (new i = 0; i < num; i++)
	{
		new p = players[i]
		new paid = 0, refused = 0, spent = 0, won = 0
		new start = wf_get_spins(p)
		WfSpinEnsure(p)
		for (new k = 0; k < n; k++)
		{
			// Exactly what SpinStart() does, minus the reveal timer: consume,
			// roll inside the eligible sectors, record, pay. A refusal here is the
			// same refusal a player gets.
			if (!WfSpinReady(p))
			{
				console_print(id, "[WF-SPIN] drive id %d: core record not ready", p)
				break
			}
			if (!wf_consume_spin(p))
			{
				refused++
				console_print(id, "[WF-SPIN] drive id %d #%d refused: no spins left (balance %d)", p, k + 1, wf_get_spins(p))
				break
			}
			spent++
			new sector, roll, total, excluded
			if (!SpinRollEligible(p, sector, roll, total, excluded))
			{
				wf_add_spins(p, 1)
				spent--
				console_print(id, "[WF-SPIN] drive id %d #%d: no eligible sector, token returned", p, k + 1)
				break
			}
			g_iSerial[p]++
			formatex(g_szPending[p], charsmax(g_szPending[]), "%d:%d", g_iSerial[p], sector)
			WfSpinSave(p)
			g_iWinSerial[p] = g_iSerial[p]
			g_iWinSector[p] = sector
			new claim[32]
			formatex(claim, charsmax(claim), "wfspin#%d", g_iSerial[p])
			new code = SpinPay(p, sector, g_iSerial[p], claim)
			g_szPending[p][0] = 0
			WfSpinSave(p)
			if (code == PAY_OK || code == PAY_DUP)
				paid++
			if (g_iKind[sector] == KIND_SPIN && g_iPaidAmount[p] > 0)
				won += g_iPaidAmount[p]
			console_print(id, "[WF-SPIN] drive id %d #%d: r=%d/%d sector #%d '%s' serial %d -> %s (balance %d)",
				p, k + 1, roll, total, sector + 1, g_szLabel[sector], g_iSerial[p],
				(code == PAY_OK) ? "paid" : (code == PAY_DUP) ? "already-paid" : "FAILED", wf_get_spins(p))
		}
		// Tokens are conserved when every token taken either paid a prize or came
		// back as a spin prize: start - spent + won == end.
		new ok = ((start - spent + won) == wf_get_spins(p)) ? true : false
		console_print(id, "[WF-SPIN] drive id %d: start=%d paid=%d won=%d refused=%d end=%d %s",
			p, start, paid, won, refused, wf_get_spins(p), ok ? "TOKENS-CONSERVED" : "TOKEN-MISMATCH")
		server_print("[WF-SPIN-TEST] %s drive-conserved id=%d start=%d paid=%d won=%d refused=%d end=%d",
			ok ? "PASS" : "FAIL", p, start, paid, won, refused, wf_get_spins(p))
	}
	g_bSeamNoSpin = false
	return PLUGIN_HANDLED
}

// Two /spin calls in the same tick. The second must be refused by the in-flight
// flag, and exactly one token must be gone.
public cmdDupe(id, level, cid)
{
	if (!cmd_access(id, level, cid, 1))
		return PLUGIN_HANDLED
	if (!get_cvar_num("wfspin_test_bots"))
	{
		console_print(id, "[WF-SPIN] wfspin_dupe needs wfspin_test_bots 1 (it acts as the player)")
		return PLUGIN_HANDLED
	}

	new players[MAX_PLAYERS], num
	get_players(players, num, "h")
	if (!num)
	{
		console_print(id, "[WF-SPIN] no client to test")
		return PLUGIN_HANDLED
	}

	new p = players[0]
	if (!WfSpinReady(p))
	{
		console_print(id, "[WF-SPIN] dupe id %d: core record not ready", p)
		return PLUGIN_HANDLED
	}
	// Make sure there is a token to race for, and that the claim-key serial is
	// the one on disk (not a fresh 0).
	WfSpinEnsure(p)
	if (wf_get_spins(p) <= 0 && g_iMaxStored > 0)
		wf_add_spins(p, 1)

	new before = wf_get_spins(p)
	SpinStart(p)      // first: consumes, opens the reveal
	SpinStart(p)      // second, same tick: must be refused
	new after = wf_get_spins(p)
	new spent = before - after

	// Finish the first spin so the test leaves no wheel turning.
	remove_task(TASK_STEP + p)
	SpinFinish(p)
	new end = wf_get_spins(p)

	// One token spent. The first spin may pay a spin back, so the balance after
	// the finish may be one higher - what must be true is that the SECOND call
	// spent nothing: spent == 1.
	new ok = (spent == 1) ? true : false
	console_print(id, "[WF-SPIN] dupe id %d: before=%d spent=%d end=%d (a second /spin must spend nothing)", p, before, spent, end)
	server_print("[WF-SPIN-TEST] %s dupe-one-token id=%d spent=%d", ok ? "PASS" : "FAIL", p, spent)
	return PLUGIN_HANDLED
}

// A spin interrupted before its reveal finished. The token is spent and the
// sector is in the vault; the client "reconnects" (memory wiped, vault re-read),
// and the resume path must pay once and then refuse to pay again.
public cmdResume(id, level, cid)
{
	if (!cmd_access(id, level, cid, 1))
		return PLUGIN_HANDLED
	if (!get_cvar_num("wfspin_test_bots"))
	{
		console_print(id, "[WF-SPIN] wfspin_resume needs wfspin_test_bots 1 (it acts as the player)")
		return PLUGIN_HANDLED
	}

	new players[MAX_PLAYERS], num
	get_players(players, num, "h")
	if (!num)
	{
		console_print(id, "[WF-SPIN] no client to test")
		return PLUGIN_HANDLED
	}

	new p = players[0]
	if (!WfSpinReady(p) || !WfSpinVault())
	{
		console_print(id, "[WF-SPIN] resume id %d: core=not-ready or vault=closed", p)
		return PLUGIN_HANDLED
	}
	// Make sure there is a token to interrupt, and a serial that has not been
	// used before.
	WfSpinEnsure(p)
	if (wf_get_spins(p) <= 0 && g_iMaxStored > 0)
		wf_add_spins(p, 1)

	// The first GingerBread sector: its payment is measurable in the balance the
	// core exposes, which is what makes this assertion exact.
	new sector = -1
	for (new s = 0; s < g_iSectors; s++)
		if (g_iKind[s] == KIND_GINGERBREAD)
		{
			sector = s
			break
		}
	if (sector < 0)
	{
		console_print(id, "[WF-SPIN] resume id %d: the wheel has no GingerBread sector to measure", p)
		return PLUGIN_HANDLED
	}

	new gb0 = wf_get_gingerbread(p)

	// Consume + record, exactly like SpinStart, then "crash" before the reveal.
	if (!wf_consume_spin(p))
	{
		console_print(id, "[WF-SPIN] resume id %d: no token to spend", p)
		return PLUGIN_HANDLED
	}
	g_iSerial[p]++
	formatex(g_szPending[p], charsmax(g_szPending[]), "%d:%d", g_iSerial[p], sector)
	WfSpinSave(p)
	g_bSpinning[p] = true
	remove_task(TASK_STEP + p)

	// The reconnect: the module forgets everything and reads the vault again.
	WfSpinClearMem(p)
	WfSpinLoad(p)
	if (!g_szPending[p][0])
	{
		server_print("[WF-SPIN-TEST] FAIL resume-pending id=%d (the vault lost the intent)", p)
		return PLUGIN_HANDLED
	}

	SpinResume(p)
	new gb1 = wf_get_gingerbread(p)

	// The claim key is the real record. Restore the intent as if the "pending
	// cleared" write had been lost in the same crash - the core's ledger must
	// refuse to pay the same key twice.
	formatex(g_szPending[p], charsmax(g_szPending[]), "%d:%d", g_iSerial[p], sector)
	WfSpinSave(p)
	SpinResume(p)
	new gb2 = wf_get_gingerbread(p)

	// And a clean second reconnect (no pending at all) pays nothing either.
	WfSpinClearMem(p)
	WfSpinLoad(p)
	SpinResume(p)
	new gb3 = wf_get_gingerbread(p)

	new expect = g_iAmount[sector]
	new ok = ((gb1 - gb0 == expect) && (gb2 == gb1) && (gb3 == gb1)) ? true : false
	console_print(id, "[WF-SPIN] resume id %d: sector #%d '%s' gb %d -> %d -> %d -> %d (expected +%d once)",
		p, sector + 1, g_szLabel[sector], gb0, gb1, gb2, gb3, expect)
	server_print("[WF-SPIN-TEST] %s resume-paid-once id=%d gb0=%d gb1=%d gb2=%d gb3=%d",
		ok ? "PASS" : "FAIL", p, gb0, gb1, gb2, gb3)
	return PLUGIN_HANDLED
}

// ============================================================
// Small services: targets and the clock
// ============================================================
stock SpinTargets(const arg[], targets[], max, &num)
{
	num = 0
	if (equal(arg, "all") || equal(arg, "@all"))
	{
		new players[MAX_PLAYERS], n
		get_players(players, n, "h")
		for (new i = 0; i < n && num < max; i++)
			targets[num++] = players[i]
		return
	}
	new p = cmd_target(0, arg, CMDTARGET_ALLOW_SELF)
	if (p > 0 && num < max)
		targets[num++] = p
}

// Europe/Paris offset at a unix timestamp: +3600 (CET) or +7200 (CEST).
// The EU rule is fixed and needs no tz database: summer time runs from 01:00 UTC
// on the last Sunday of March to 01:00 UTC on the last Sunday of October. It is
// checkable without trusting the server's clock (`wfspin_day <ts>`).
stock SpinParisOffset(now)
{
	new ybuf[8]
	format_time(ybuf, charsmax(ybuf), "%Y", now)
	new year = str_to_num(ybuf)
	if (year < 1970)
		return 3600

	new marchStart = SpinLastSundayUtc(year, 3)
	new octoberEnd = SpinLastSundayUtc(year, 10)
	if (now >= marchStart && now < octoberEnd)
		return 7200
	return 3600
}

// 01:00 UTC on the last Sunday of `month` of `year`, as a unix timestamp.
stock SpinLastSundayUtc(year, month)
{
	new last = SpinDaysInMonth(year, month)
	new dow = SpinDayOfWeek(year, month, last)     // 0 = Sunday
	new sunday = last - dow
	new days = SpinDaysFromCivil(year, month, sunday)
	return days * 86400 + 3600
}

stock SpinDaysInMonth(year, month)
{
	switch (month)
	{
		case 1, 3, 5, 7, 8, 10, 12: return 31
		case 4, 6, 9, 11: return 30
		case 2: return SpinLeap(year) ? 29 : 28
	}
	return 30
}

stock bool:SpinLeap(year)
{
	return ((year % 4 == 0 && year % 100 != 0) || year % 400 == 0) ? true : false
}

// Days since 1970-01-01 for a civil date (Howard Hinnant's days_from_civil).
// Integer only and valid for years >= 1970, which is every timestamp this server
// will ever see.
stock SpinDaysFromCivil(y, m, d)
{
	if (m <= 2)
		y--
	new era = y / 400
	new yoe = y - era * 400
	new mp = (m + 9) % 12                   // March = 0
	new doy = (153 * mp + 2) / 5 + d - 1
	new doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
	return era * 146097 + doe - 719468
}

// 0 = Sunday ... 6 = Saturday. 1970-01-01 was a Thursday.
stock SpinDayOfWeek(year, month, day)
{
	new days = SpinDaysFromCivil(year, month, day)
	new dow = (days + 4) % 7
	if (dow < 0)
		dow += 7
	return dow
}

// Civil date from days since 1970-01-01 (Hinnant's civil_from_days).
stock SpinCivilFromDays(z, &y, &m, &d)
{
	z += 719468
	new era = z / 146097
	new doe = z - era * 146097
	new yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
	new doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
	new mp = (5 * doy + 2) / 153
	d = doy - (153 * mp + 2) / 5 + 1
	m = (mp < 10) ? mp + 3 : mp - 9
	y = yoe + era * 400
	if (m <= 2)
		y++
}

// "YYYY-MM-DD HH:MM" for the instant `t + offset`, computed arithmetically from
// the epoch: the server's own timezone never enters the calculation, which is
// what makes "Paris" mean Paris even when the box runs UTC.
stock SpinStamp(t, offset, out[], len)
{
	new secs = t + offset
	new days = secs / 86400
	new rem = secs % 86400
	if (rem < 0)
	{
		rem += 86400
		days--
	}
	new y, m, d
	SpinCivilFromDays(days, y, m, d)
	formatex(out, len, "%04d-%02d-%02d %02d:%02d", y, m, d, rem / 3600, (rem % 3600) / 60)
}

// The claim day the CORE uses for its own daily spin grant (its clock, not this
// one), printed in the diagnostics so "the core's log says 20261122 and the
// wheel says spin-day 20790" never needs reverse-engineering.
stock SpinTodayKey(out[], len)
{
	out[0] = 0
	format_time(out, len, "%Y%m%d", get_systime())
}

// The daily-reset day index: (Paris wall clock - reset hour) / one day. Two
// instants with the same index belong to the same "spin day", which is what the
// in-game reset countdown is computed from.
stock SpinDayIndex(now)
{
	return (now + SpinParisOffset(now) - g_iResetHour * 3600) / 86400
}

stock SpinNextReset(now)
{
	new day = SpinDayIndex(now)
	return (day + 1) * 86400 + g_iResetHour * 3600 - SpinParisOffset(now)
}

stock SpinSecondsToReset()
{
	new now = get_systime()
	new left = SpinNextReset(now) - now
	if (left < 0)
		left = 0
	return left
}
