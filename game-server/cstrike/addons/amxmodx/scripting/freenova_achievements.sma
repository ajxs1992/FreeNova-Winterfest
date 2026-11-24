#include <amxmodx>
#include <amxmisc>
#include <cstrike>
#include <csx>
#include <nvault>
#include <crxranks>
#include <ranksultimate>
#include <menabp>
#include <freenova_ui>
#include <freenova_web>
#include <rsu>
#include <freenova_achievements>
#include <fn_common>

native fn_hub_open(id)

#define PLUGIN  "FreeNova Achievements"
#define VERSION "1.0.1"
#define AUTHOR  "FreeNova"

// 56400, not 54000. VIP late-load already uses id+54000. Same id cancels the other plugin.
#define TASK_LATELOAD  56400
// MEDIUM-2: unpaid achievement coins retry ticker (56500 = missions TASK_PERIOD).
#define TASK_WALLET_FLUSH  56600
#define MAX_PLAYERS    32

new g_VaultBP = INVALID_HANDLE
new bool:g_bPaused
new bool:g_bAchLoaded[MAX_PLAYERS + 1]
new g_iAchUnlocked[MAX_PLAYERS + 1]
new g_iAchLifetimeKills[MAX_PLAYERS + 1]
new g_iAchLifetimeHS[MAX_PLAYERS + 1]
new g_iAchLifetimePlants[MAX_PLAYERS + 1]
new g_iAchLifetimeDefuses[MAX_PLAYERS + 1]
new g_iAchLifetimeWins[MAX_PLAYERS + 1]
new g_iAchLifetimeRevives[MAX_PLAYERS + 1]
new g_iAchStreakBest[MAX_PLAYERS + 1]
new g_iLifeStreak[MAX_PLAYERS + 1]
new g_iAchPending[MAX_PLAYERS + 1]
// Legacy aggregate of unpaid coins (pre-1.1.1 marker, an amount with no
// achievement id). Never incremented by this build; only drained.
new g_iAchPendingCoins[MAX_PLAYERS + 1]
// Bitmask of achievements whose coin reward could not be banked yet. Retried
// one by one with the same once-only award id the unlock used.
new g_iAchUnpaid[MAX_PLAYERS + 1]
new g_iAchXpPending[MAX_PLAYERS + 1]

// Coin reward per achievement - the single source of truth for both the unlock
// payment and the retry, so a retried reward can never differ from the one that
// was promised.
new const g_iAchReward[ACH_COUNT] = {
	ACH_COIN_REWARD, ACH_COIN_REWARD, 500, ACH_COIN_REWARD, 500,
	ACH_COIN_REWARD, ACH_COIN_REWARD, ACH_COIN_REWARD, ACH_COIN_REWARD, 1000,
	ACH_COIN_REWARD, 500, ACH_COIN_REWARD, 500
}

public plugin_natives()
{
	register_library("freenova_achievements")
	set_native_filter("FnachNativeFilter")
	register_native("fnach_get_unlocked", "native_get_unlocked")
	register_native("fnach_get_count", "native_get_count")
	register_native("fnach_get_stat", "native_get_stat")
	register_native("fnach_show", "native_show")
	register_native("fnach_note_revive", "native_note_revive")
	register_native("fnach_is_loaded", "native_is_loaded")
}

public FnachNativeFilter(const name[], index, trap)
{
	if (equal(name, "menabp_add_coins")
		|| equal(name, "menabp_add_xp_once")
		|| equal(name, "menabp_is_ready")
		|| equal(name, "menabp_get_tier")
		|| equal(name, "menabp_get_coins")
		|| equal(name, "fn_hub_open")
		|| equal(name, "rsu_get_prestige")
		|| equal(name, "rsu_get_user_kills")
		|| equal(name, "rsu_get_user_headshots"))
		return PLUGIN_HANDLED
	return PLUGIN_CONTINUE
}

public plugin_init()
{
	fn_boot_banner("achievements", 12)

	register_plugin(PLUGIN, VERSION, AUTHOR)

	// lint:allow library-missing - legacy provider name from before the RSU
	// merge. No plugin in this tree registers "rsu_achievements", so this pause
	// is a no-op today; the literal stays so an operator can drop that plugin
	// back in and have this provider step aside.
	if (LibraryExists("rsu_achievements", LibType_Library))
	{
		g_bPaused = true
		log_amx("[FreeNova] rsu_achievements loaded — pausing fnach grants")
	}

	g_VaultBP = nvault_open("freenova_bp")
	if (g_VaultBP == INVALID_HANDLE)
		log_amx("[FreeNova] achievements: nvault freenova_bp failed to open")

	register_clcmd("say /achievements", "Cmd_Achievements")
	register_clcmd("say_team /achievements", "Cmd_Achievements")
	register_clcmd("say /ach", "Cmd_Achievements")
	register_clcmd("say_team /ach", "Cmd_Achievements")
	register_clcmd("say /medals", "Cmd_Achievements")
	register_clcmd("say_team /medals", "Cmd_Achievements")
}

public plugin_end()
{
		// freenova_bp is a shared global nVault handle. battlepass_core is the
	// sole closer; consumer closes here raced it at map end (Invalid vault id).
}

public client_putinserver(id)
{
	ResetClient(id)
	if (is_user_bot(id))
		return

	new szAuth[40]
	get_user_authid(id, szAuth, charsmax(szAuth))
	if (!szAuth[0] || equal(szAuth, "STEAM_ID_PENDING") || equal(szAuth, "UNKNOWN"))
	{
		set_task(5.0, "Task_LateLoad", id + TASK_LATELOAD)
		return
	}
	LoadAchievements(id)
}

public Task_LateLoad(taskid)
{
	new id = taskid - TASK_LATELOAD
	if (!is_user_connected(id) || is_user_bot(id))
		return

	new szAuth[40]
	get_user_authid(id, szAuth, charsmax(szAuth))
	if (!szAuth[0] || equal(szAuth, "STEAM_ID_PENDING") || equal(szAuth, "UNKNOWN"))
	{
		set_task(3.0, "Task_LateLoad", id + TASK_LATELOAD)
		return
	}
	LoadAchievements(id)
}

public client_disconnected(id)
{
	remove_task(id + TASK_LATELOAD)
	remove_task(id + TASK_WALLET_FLUSH)
	if (g_bAchLoaded[id] && !is_user_bot(id))
		SaveAchievements(id)
	ResetClient(id)
}

ResetClient(id)
{
	g_bAchLoaded[id] = false
	g_iAchUnlocked[id] = 0
	g_iAchLifetimeKills[id] = 0
	g_iAchLifetimeHS[id] = 0
	g_iAchLifetimePlants[id] = 0
	g_iAchLifetimeDefuses[id] = 0
	g_iAchLifetimeWins[id] = 0
	g_iAchLifetimeRevives[id] = 0
	g_iAchStreakBest[id] = 0
	g_iLifeStreak[id] = 0
	g_iAchPending[id] = 0
	g_iAchPendingCoins[id] = 0
	g_iAchUnpaid[id] = 0
	g_iAchXpPending[id] = 0
}

GetVaultKey(id, output[], len)
{
	new authid[40]
	get_user_authid(id, authid, charsmax(authid))
	for (new i = 0; authid[i]; i++)
	{
		if (authid[i] == ':')
			authid[i] = '_'
	}
	formatex(output, len, "ach#%s", authid)
}

LoadAchievements(id)
{
	g_bAchLoaded[id] = false
	if (g_VaultBP == INVALID_HANDLE)
		return

	new key[64], value[128]
	GetVaultKey(id, key, charsmax(key))
	if (!nvault_get(g_VaultBP, key, value, charsmax(value)))
	{
		g_iAchUnlocked[id] = 0
		g_iAchLifetimeKills[id] = 0
		g_iAchLifetimeHS[id] = 0
		g_iAchLifetimePlants[id] = 0
		g_iAchLifetimeDefuses[id] = 0
		g_iAchLifetimeWins[id] = 0
		g_iAchLifetimeRevives[id] = 0
		g_iAchStreakBest[id] = 0
		g_iAchPendingCoins[id] = 0
		g_iAchUnpaid[id] = 0
		g_iAchXpPending[id] = 0
		if (LibraryExists("rsu_core", LibType_Library))
		{
			g_iAchLifetimeKills[id] = rsu_get_user_kills(id)
			g_iAchLifetimeHS[id] = rsu_get_user_headshots(id)
			if (g_iAchLifetimeKills[id] || g_iAchLifetimeHS[id])
				SaveAchievements(id)
		}
		g_bAchLoaded[id] = true
		UnlockAchievementsFromStats(id)
		return
	}

	new part[16], left[128]
	copy(left, charsmax(left), value)
	strtok(left, part, charsmax(part), left, charsmax(left), ' ')
	g_iAchUnlocked[id] = str_to_num(part)
	strtok(left, part, charsmax(part), left, charsmax(left), ' ')
	g_iAchLifetimeKills[id] = str_to_num(part)
	strtok(left, part, charsmax(part), left, charsmax(left), ' ')
	g_iAchLifetimeHS[id] = str_to_num(part)
	strtok(left, part, charsmax(part), left, charsmax(left), ' ')
	g_iAchLifetimePlants[id] = str_to_num(part)
	strtok(left, part, charsmax(part), left, charsmax(left), ' ')
	g_iAchLifetimeDefuses[id] = str_to_num(part)
	strtok(left, part, charsmax(part), left, charsmax(left), ' ')
	g_iAchLifetimeWins[id] = str_to_num(part)
	strtok(left, part, charsmax(part), left, charsmax(left), ' ')
	g_iAchLifetimeRevives[id] = str_to_num(part)
	strtok(left, part, charsmax(part), left, charsmax(left), ' ')
	g_iAchStreakBest[id] = str_to_num(part)
	// MEDIUM-2: 9th blob field = unpaid achievement coins awaiting the
	// wallet-ready retry. 10th field was a legacy BP XP pending bitmask; it is
	// read for format compatibility but deliberately discarded (BP XP is
	// missions-only in this build, so legacy bits must never be paid).
	g_iAchPendingCoins[id] = 0
	g_iAchUnpaid[id] = 0
	g_iAchXpPending[id] = 0
	if (left[0])
	{
		strtok(left, part, charsmax(part), left, charsmax(left), ' ')
		g_iAchPendingCoins[id] = str_to_num(part)
		// 10th token is a legacy XP bitmask: read for format compatibility and
		// deliberately never paid (BP XP is missions-only).
		if (left[0])
		{
			strtok(left, part, charsmax(part), left, charsmax(left), ' ')
			g_iAchXpPending[id] = str_to_num(part)
			// 11th token: per-achievement unpaid coin markers (this build).
			if (left[0])
			{
				strtok(left, part, charsmax(part), left, charsmax(left), ' ')
				g_iAchUnpaid[id] = str_to_num(part)
			}
		}
	}

	g_bAchLoaded[id] = true
	UnlockAchievementsFromStats(id)
}

SaveAchievements(id)
{
	if (g_VaultBP == INVALID_HANDLE || !g_bAchLoaded[id])
		return
	new key[64], value[128]
	GetVaultKey(id, key, charsmax(key))
	formatex(value, charsmax(value), "%d %d %d %d %d %d %d %d %d %d %d",
		g_iAchUnlocked[id], g_iAchLifetimeKills[id], g_iAchLifetimeHS[id],
		g_iAchLifetimePlants[id], g_iAchLifetimeDefuses[id],
		g_iAchLifetimeWins[id], g_iAchLifetimeRevives[id],
		g_iAchStreakBest[id], g_iAchPendingCoins[id],
		g_iAchXpPending[id], g_iAchUnpaid[id])
	nvault_set(g_VaultBP, key, value)
}

GiveAchievement(id, iAch, const szName[])
{
	if (g_bPaused || !g_bAchLoaded[id])
		return
	if (iAch < 0 || iAch >= ACH_COUNT)
		return
	if (g_iAchUnlocked[id] & (1 << iAch))
		return

	new iReward = g_iAchReward[iAch]

	// Pay before persisting. The unlock bit is one-shot, so writing it first
	// meant a crash between the write and the deposit (or a deposit refused
	// without reaching the pending marker) lost the coins for ever. The award id
	// makes the payment itself idempotent, so paying first cannot double-pay
	// either: 0 from menabp_add_coins_once means an earlier attempt already
	// credited it. REVIEW.md §5.3.
	new bool:bPaid = false
	if (iReward > 0 && LibraryExists("menabp", LibType_Library))
	{
		new szAward[24]
		formatex(szAward, charsmax(szAward), "ach#%d", iAch)
		new iOnce = menabp_is_ready(id) ? menabp_add_coins_once(id, iReward, szAward) : -1
		if (iOnce > 0)
			bPaid = true
		else if (iOnce == 0)
		{
			// Credited by an earlier attempt whose unlock write never landed.
			bPaid = true
			log_amx("[FreeNova] Achievement %d reward already paid to id %d (%s)", iAch, id, szAward)
		}
		else
			log_amx("[FreeNova] Achievement %d coin reward NOT paid to id %d (%d coins): wallet not ready or native refused", iAch, id, iReward)
	}

	// One vault write for the unlock bit and the unpaid marker, so the two can
	// never disagree after a crash. The marker is per achievement, not an
	// amount: the retry below pays each one with its own once-only award id.
	g_iAchUnlocked[id] |= (1 << iAch)
	if (iReward > 0 && !bPaid)
		g_iAchUnpaid[id] |= (1 << iAch)
	SaveAchievements(id)

	// Achievements pay coins only. BattlePass XP is missions-only:
	// freenova_missions awards it when a daily/weekly/VIP mission set is
	// completed. Kills, streaks and achievement unlocks must never move the
	// BP ledger, otherwise the HUD tier appears to jump on kill milestones.
	//
	// Legacy note: pre-1.1 builds paid ACH_XP_REWARD here. That award id
	// ("ach#N") is intentionally no longer credited.
	g_iAchPending[id]++
	if (g_iAchPending[id] == 1)
	{
		if (bPaid)
			client_printcolor(id, "!g[FreeNova] !n Achievement unlocked: !t%s!n! (+!g%d Coins!n)", szName, iReward)
		else
			client_printcolor(id, "!g[FreeNova] !n Achievement unlocked: !t%s!n", szName)
	}
	if (iReward > 0 && !bPaid)
	{
		// The unpaid reward is the vault-persisted bit written above, retried
		// once the wallet reports ready. The unlock bit stays one-shot — only
		// the coin payment retries. The "+N Coins" line above only shows when
		// the deposit succeeded.
		EnsureCoinFlush(id)
	}
}

// Total achievement coins still owed to this player (legacy amount + per-ach
// markers). 0 = nothing pending.
PendingCoinsTotal(id)
{
	new iTotal = g_iAchPendingCoins[id]
	for (new iAch; iAch < ACH_COUNT; iAch++)
	{
		if (g_iAchUnpaid[id] & (1 << iAch))
			iTotal += g_iAchReward[iAch]
	}
	return iTotal
}

// Pays every achievement reward that could not be banked when it unlocked.
// Each one is retried with the SAME once-only award id the unlock used, so a
// retry can never pay twice and a crash between the deposit and the marker
// write cannot lose it either. The pre-1.1.1 aggregate marker (an amount with no
// achievement id) is paid last, with a plain deposit, because it cannot be made
// idempotent.
// Returns the amount still owed after the attempt (0 = nothing pending).
FlushPendingCoins(id)
{
	if (!g_bAchLoaded[id])
		return 0
	if (g_iAchUnpaid[id] == 0 && g_iAchPendingCoins[id] <= 0)
		return 0
	if (!LibraryExists("menabp", LibType_Library))
		return PendingCoinsTotal(id)
	if (!menabp_is_ready(id))
		return PendingCoinsTotal(id)

	if (g_iAchUnpaid[id] != 0)
	{
		new iPaid
		for (new iAch; iAch < ACH_COUNT; iAch++)
		{
			if (!(g_iAchUnpaid[id] & (1 << iAch)))
				continue
			new iReward = g_iAchReward[iAch]
			if (iReward <= 0)
			{
				g_iAchUnpaid[id] &= ~(1 << iAch)
				continue
			}
			new szAward[24]
			formatex(szAward, charsmax(szAward), "ach#%d", iAch)
			new iOnce = menabp_add_coins_once(id, iReward, szAward)
			if (iOnce < 0)
			{
				// Wallet went away again mid-loop: keep the rest for the next tick.
				log_amx("[FreeNova] Pending achievement %d coins NOT paid to id %d: wallet refused", iAch, id)
				break
			}
			g_iAchUnpaid[id] &= ~(1 << iAch)
			if (iOnce > 0)
				iPaid += iReward
		}
		SaveAchievements(id)
		if (iPaid > 0)
			client_printcolor(id, "!g[FreeNova] !n +!g%d Coins !n from earlier achievements credited.", iPaid)
	}

	if (g_iAchUnpaid[id] == 0 && g_iAchPendingCoins[id] > 0)
	{
		new iAmount = g_iAchPendingCoins[id]
		if (menabp_add_coins(id, iAmount) == 0)
		{
			// Wallet claims ready but refused the deposit — keep the marker and
			// let the retry task try again (logged once per attempt, not per kill).
			log_amx("[FreeNova] Pending achievement coins NOT paid to id %d (%d coins): menabp_add_coins refused", id, iAmount)
			return iAmount
		}
		g_iAchPendingCoins[id] = 0
		SaveAchievements(id)
		client_printcolor(id, "!g[FreeNova] !n +!g%d Coins !n from earlier achievements credited.", iAmount)
	}
	return PendingCoinsTotal(id)
}

// BP XP is missions-only (freenova_missions). This stub exists solely so a
// legacy pending bitmask from an older build is never paid out; it clears the
// marker without crediting anything.
bool:FlushPendingXp(id)
{
	if (g_iAchXpPending[id] == 0)
		return false
	g_iAchXpPending[id] = 0
	SaveAchievements(id)
	return false
}

EnsureCoinFlush(id)
{
	if (!g_bAchLoaded[id] || PendingCoinsTotal(id) <= 0)
		return
	if (!task_exists(id + TASK_WALLET_FLUSH))
		set_task(15.0, "Task_FlushCoins", id + TASK_WALLET_FLUSH, "", 0, "b")
}

public Task_FlushCoins(taskid)
{
	new id = taskid - TASK_WALLET_FLUSH
	if (!is_user_connected(id) || is_user_bot(id) || !g_bAchLoaded[id])
	{
		remove_task(taskid)
		return
	}
	new bool:bCoins = (FlushPendingCoins(id) > 0)
	FlushPendingXp(id)
	if (!bCoins)
		remove_task(taskid)
}

UnlockAchievementsFromStats(id)
{
	if (g_bPaused || !g_bAchLoaded[id])
		return

	if (LibraryExists("rsu_core", LibType_Library))
	{
		new iRankKills = rsu_get_user_kills(id);
		new iRankHS = rsu_get_user_headshots(id);
		if (iRankKills > g_iAchLifetimeKills[id])
			g_iAchLifetimeKills[id] = iRankKills;
		if (iRankHS > g_iAchLifetimeHS[id])
			g_iAchLifetimeHS[id] = iRankHS;
	}

	g_iAchPending[id] = 0
	if (g_iAchLifetimeKills[id] >= 100)  GiveAchievement(id, ACH_KILLS_100,  "First Blood Century")
	if (g_iAchLifetimeKills[id] >= 1000) GiveAchievement(id, ACH_KILLS_1000, "Killing Machine")
	if (g_iAchLifetimeKills[id] >= 5000) GiveAchievement(id, ACH_KILLS_5000, "FreeNova Legend Killer")
	if (g_iAchLifetimeHS[id] >= 100)     GiveAchievement(id, ACH_HS_100,     "Sharpshooter")
	if (g_iAchLifetimeHS[id] >= 500)     GiveAchievement(id, ACH_HEADS_500,  "Headhunter")
	if (g_iAchLifetimePlants[id] >= 50)  GiveAchievement(id, ACH_PLANTS_50,  "Demolition Expert")
	if (g_iAchLifetimeDefuses[id] >= 25) GiveAchievement(id, ACH_DEFUSES_25, "Bomb Squad")
	if (g_iAchLifetimeWins[id] >= 100)   GiveAchievement(id, ACH_WINS_100,   "Team Player")

	// BP-level achievements follow the BP ledger. Fall back to rank only while
	// battlepass_core is still loading (legacy behaviour for a fresh join).
	new iLevel = 0
	if (LibraryExists("menabp", LibType_Library) && menabp_is_ready(id))
		iLevel = menabp_get_tier(id)
	else
		iLevel = crxranks_get_user_level(id)
	if (iLevel >= 52)      GiveAchievement(id, ACH_LEVEL_52, "FreeNova Legend")
	else if (iLevel >= 26) GiveAchievement(id, ACH_LEVEL_26, "Seasoned Soldier")

	new iPrestige = 0
	if (LibraryExists("rsu_core", LibType_Library))
		iPrestige = rsu_get_prestige(id)
	if (iPrestige >= 1) GiveAchievement(id, ACH_PRESTIGE_1, "Prestigious")
	if (g_iAchStreakBest[id] >= 10) GiveAchievement(id, ACH_STREAK_10, "Unstoppable")

	new iCoins = 0
	if (LibraryExists("menabp", LibType_Library))
		iCoins = menabp_get_coins(id)
	if (iCoins >= 10000) GiveAchievement(id, ACH_COINS_10000, "Coin Magnet")
	if (g_iAchLifetimeRevives[id] >= 25) GiveAchievement(id, ACH_REVIVER, "Combat Medic")

	if (g_iAchPending[id] > 1)
		client_printcolor(id, "!g[FreeNova] !n +%d more achievements unlocked this round.", g_iAchPending[id] - 1)
	g_iAchPending[id] = 0
	// Opportunistically pay any unpaid achievement COINS on gameplay events.
	// BP XP is missions-only and any legacy pending XP bit is cleared unpaid.
	// PendingCoinsTotal() covers both the per-achievement markers this build
	// writes and the pre-1.1.1 aggregate amount.
	if (PendingCoinsTotal(id) > 0 || g_iAchXpPending[id] != 0)
	{
		new bool:bCoins = (PendingCoinsTotal(id) > 0) ? (FlushPendingCoins(id) > 0) : false
		FlushPendingXp(id)
		if (!bCoins)
			remove_task(id + TASK_WALLET_FLUSH)
		else
			EnsureCoinFlush(id)
	}
}

public fn_on_player_kill(attacker, victim, wpnindex, headshot, tk)
{
	#pragma unused victim, wpnindex
	if (g_bPaused || tk)
		return
	if (!is_user_connected(attacker) || is_user_bot(attacker) || !g_bAchLoaded[attacker])
		return

	g_iAchLifetimeKills[attacker]++
	if (LibraryExists("rsu_core", LibType_Library))
	{
		new iRankKills = rsu_get_user_kills(attacker);
		if (iRankKills > g_iAchLifetimeKills[attacker])
			g_iAchLifetimeKills[attacker] = iRankKills;
	}
	g_iLifeStreak[attacker]++
	if (g_iLifeStreak[attacker] > g_iAchStreakBest[attacker])
	{
		g_iAchStreakBest[attacker] = g_iLifeStreak[attacker]
		SaveAchievements(attacker)
	}
	if (headshot)
	{
		g_iAchLifetimeHS[attacker]++
		if (LibraryExists("rsu_core", LibType_Library))
		{
			new iRankHS = rsu_get_user_headshots(attacker);
			if (iRankHS > g_iAchLifetimeHS[attacker])
				g_iAchLifetimeHS[attacker] = iRankHS;
		}
	}
	UnlockAchievementsFromStats(attacker)
}

// RANK_BOTS master switch reader: true only when rsu_core runs RANK_BOTS=1.
// Bots never load achievement state, so this only opens VICTIM-side counters
// (streak reset) for humans. Bot PLAYERS earn nothing.
stock bool:BotCountOn()
{
    return LibraryExists("rsu_core", LibType_Library) && rsu_bots_count();
}

public client_death(attacker, victim, wpnindex, hitplace, TK)
{
	#pragma unused attacker, wpnindex, hitplace, TK
	if (is_user_connected(victim) && (!is_user_bot(victim) || BotCountOn()))
		g_iLifeStreak[victim] = 0
}

public fn_on_bomb_event(id, type)
{
	if (g_bPaused || !g_bAchLoaded[id])
		return
	if (type == 0)
		g_iAchLifetimePlants[id]++
	else if (type == 1)
		g_iAchLifetimeDefuses[id]++
	else
		return
	UnlockAchievementsFromStats(id)
}

public fn_on_round_win(id, team)
{
	#pragma unused team
	if (g_bPaused || !g_bAchLoaded[id])
		return
	g_iAchLifetimeWins[id]++
	UnlockAchievementsFromStats(id)
}

public Cmd_Achievements(id)
{
	if (!is_user_connected(id))
		return PLUGIN_HANDLED
	if (FNWeb_OpenPage(id, "achievements"))
		return PLUGIN_HANDLED
	client_printcolor(id, "!g[FreeNova] !nAchievements are unavailable right now - try again in a moment.")
	return PLUGIN_HANDLED
}









bool:ValidId(id)
{
	return (1 <= id <= MAX_PLAYERS)
}

public native_get_unlocked(plugin, params)
{
	new id = get_param(1)
	return ValidId(id) ? g_iAchUnlocked[id] : 0
}

public native_get_count(plugin, params)
{
	new id = get_param(1)
	if (!ValidId(id))
		return 0
	new n
	for (new i = 0; i < ACH_COUNT; i++)
	{
		if (i == ACH_PRESTIGE_1)
			continue
		if (g_iAchUnlocked[id] & (1 << i))
			n++
	}
	return n
}

public native_get_stat(plugin, params)
{
	new id = get_param(1)
	new which = get_param(2)
	if (!ValidId(id))
		return 0
	switch (which)
	{
		case 0: return g_iAchLifetimeKills[id]
		case 1: return g_iAchLifetimeHS[id]
		case 2: return g_iAchLifetimePlants[id]
		case 3: return g_iAchLifetimeDefuses[id]
		case 4: return g_iAchLifetimeWins[id]
		case 5: return g_iAchLifetimeRevives[id]
		case 6: return g_iAchStreakBest[id]
	}
	return 0
}

public native_show(plugin, params)
{
	new id = get_param(1)
	if (!ValidId(id) || !is_user_connected(id))
		return 0
	if (FNWeb_OpenPage(id, "achievements"))
		return 1
	return 0
}

public native_note_revive(plugin, params)
{
	new id = get_param(1)
	if (!ValidId(id) || !g_bAchLoaded[id])
		return 0
	g_iAchLifetimeRevives[id]++
	UnlockAchievementsFromStats(id)
	SaveAchievements(id)
	return g_iAchLifetimeRevives[id]
}

public native_is_loaded(plugin, params)
{
	new id = get_param(1)
	return (ValidId(id) && g_bAchLoaded[id]) ? 1 : 0
}

stock client_printcolor(id, const fmt[], any:...)
{
	new msg[192]
	vformat(msg, charsmax(msg), fmt, 3)
	replace_all(msg, charsmax(msg), "!g", "^4")
	replace_all(msg, charsmax(msg), "!t", "^3")
	replace_all(msg, charsmax(msg), "!n", "^1")
	replace_all(msg, charsmax(msg), "!Team", "^3")
	// REVIEW.md 5.5: the caller's text was passed as the FORMAT. A player
	// named "%s" then made client_print_color re-format garbage cells, so
	// pass it as an argument instead.
	client_print_color(id, print_team_default, "%s", msg)
}
