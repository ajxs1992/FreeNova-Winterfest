/*
 * FreeNova Progression Layer 1.0
 *
 * Unifies the best RSU features onto the CRX rank pipeline.
 * All XP flows through crxranks_give_user_xp() so the BattlePass
 * multiplier chain (shop boost x double XP x VIP x happy hour)
 * applies exactly once per transaction.
 *
 * Features ported from Rank System Ultimate:
 *  - Bot kill XP (per-round cap; fn_botxp_* defaults ON - rsu_botxp.sma
 *    stacks a second bot-kill award on top, so keep only one side enabled)
 *  - Damage XP (disabled by default to avoid double rewards)
 *  - Happy Hour (time-windowed multiplier consumed by battlepass_core)
 *  - Active playtime milestone rewards (AFK aware)
 *  - Random round XP (lucky drop)
 */

#include <amxmodx>
#include <amxmisc>
#include <fakemeta>
#include <nvault>
#include <crxranks>
#include <crxranks_const>
#include <fn_common>

#define PLUGIN  "FreeNova Progression Layer"
#define VERSION "1.0"
#define AUTHOR  "FreeNova"

// ============ bot kill xp ============
new pcvar_botxp_enabled, pcvar_botxp_kill, pcvar_botxp_hs, pcvar_botxp_maxround
new g_iRoundBotXp[33]

// ============ damage xp (off by default) ============
new pcvar_dmgxp_enabled, pcvar_dmgxp_threshold, pcvar_dmgxp_amount
new g_iDamageBuffer[33]

// ============ happy hour ============
new pcvar_hh_enabled, pcvar_hh_start, pcvar_hh_end, pcvar_hh_mult, pcvar_hh_weekdays, pcvar_hh_override

// ============ time rewards ============
new pcvar_time_enabled, pcvar_time_afk
new g_iActiveSeconds[33]
new g_iMilestoneClaimed[33]
new bool:g_bMilestoneLoaded[33]
new g_iLateTries[33]
new g_iMilestoneVault      // persistent claimed-milestone bitfield (SteamID-keyed)

#define TASK_LATELOAD 45300
new Float:g_vecLastOrigin[33][3]
new Float:g_vecLastAngles[33][3]
new g_iIdleTicks[33]

// milestones: minutes, xp
new const g_iMilestoneMinutes[] = { 15, 30, 60, 120, 240 }
new const g_iMilestoneXp[] = { 30, 75, 180, 400, 1000 }

// ============ random round xp ============
new pcvar_rnd_enabled, pcvar_rnd_minplayers, pcvar_rnd_min, pcvar_rnd_max, pcvar_rnd_alive

public plugin_init()
{
	fn_boot_banner("progression", 23)

	register_plugin(PLUGIN, VERSION, AUTHOR)

	// bot kill xp
	pcvar_botxp_enabled  = register_cvar("fn_botxp_enabled", "1")
	pcvar_botxp_kill     = register_cvar("fn_botxp_kill", "3")
	pcvar_botxp_hs       = register_cvar("fn_botxp_hs", "1")
	pcvar_botxp_maxround = register_cvar("fn_botxp_max_round", "20")

	// damage xp
	pcvar_dmgxp_enabled  = register_cvar("fn_dmgxp_enabled", "0")
	pcvar_dmgxp_threshold = register_cvar("fn_dmgxp_threshold", "100")
	pcvar_dmgxp_amount   = register_cvar("fn_dmgxp_amount", "2")

	// happy hour
	pcvar_hh_enabled  = register_cvar("fn_happy_hour_enabled", "1")
	pcvar_hh_start    = register_cvar("fn_happy_hour_start", "18")
	pcvar_hh_end      = register_cvar("fn_happy_hour_end", "21")
	pcvar_hh_mult     = register_cvar("fn_happy_hour_multiplier", "2.0")
	pcvar_hh_weekdays = register_cvar("fn_happy_hour_weekdays_only", "0")
	pcvar_hh_override = register_cvar("fn_happy_hour_override", "0")

	// time rewards
	pcvar_time_enabled = register_cvar("fn_playtime_enabled", "1")
	pcvar_time_afk     = register_cvar("fn_playtime_afk_check", "1")

	// random round xp
	pcvar_rnd_enabled    = register_cvar("fn_luckydrop_enabled", "1")
	pcvar_rnd_minplayers = register_cvar("fn_luckydrop_min_players", "4")
	pcvar_rnd_min        = register_cvar("fn_luckydrop_min", "5")
	pcvar_rnd_max        = register_cvar("fn_luckydrop_max", "25")
	pcvar_rnd_alive      = register_cvar("fn_luckydrop_alive_only", "1")

	// The multiplier cvar must exist before battlepass_core's plugin_cfg
	// resolves its pointer; plugin_cfg runs AFTER every plugin_init, so
	// registering here removes the load-order race (happy hour was
	// silently dead for the whole map when battlepass resolved first).
	register_cvar("fn_happy_hour", "1.0")

	register_event("DeathMsg", "OnDeathMsg", "a")
	register_logevent("OnRoundStart", 2, "1=Round_Start")
	register_logevent("OnRoundEnd", 2, "1=Round_End")

	set_task(5.0, "TaskTimeRewards", 4401, _, _, "b")
	set_task(30.0, "TaskHappyHour", 4402, _, _, "b")

	register_concmd("amx_freenova_happyhour", "CmdHappyHourOverride", ADMIN_RCON, "<1|0> - force happy hour on/off")

	g_iMilestoneVault = nvault_open("freenova_milestones")
}

public plugin_end()
{
	// Claimed milestones are only persisted on disconnect, so a clean shutdown
	// (changelevel) used to drop them and re-pay every milestone reached this
	// map on the next one. Save everyone first, then close the vault.
	// REVIEW.md §5.3.
	for(new id = 1; id <= MaxClients; id++)
	{
		if(is_user_connected(id))
			SaveMilestones(id)
	}

	if(g_iMilestoneVault != INVALID_HANDLE)
		nvault_close(g_iMilestoneVault)
}

public plugin_cfg()
{
	TaskHappyHour()
}

public client_putinserver(id)
{
	ResetPlayer(id)
	remove_task(id + TASK_LATELOAD)

	if(is_user_bot(id))
		return

	LoadMilestones(id)
	if(!g_bMilestoneLoaded[id])
		set_task(3.0, "Task_LateLoadMilestones", id + TASK_LATELOAD)
}

public client_authorized(id)
{
	if(!is_user_connected(id) || is_user_bot(id) || g_bMilestoneLoaded[id])
		return
	LoadMilestones(id)
}

public Task_LateLoadMilestones(taskid)
{
	new id = taskid - TASK_LATELOAD
	if(!is_user_connected(id) || is_user_bot(id) || g_bMilestoneLoaded[id])
		return

	LoadMilestones(id)
	if(!g_bMilestoneLoaded[id] && g_iLateTries[id] < 3)
	{
		g_iLateTries[id]++
		set_task(3.0, "Task_LateLoadMilestones", id + TASK_LATELOAD)
	}
}

LoadMilestones(const id)
{
	if(g_iMilestoneVault == INVALID_HANDLE)
	{
		g_bMilestoneLoaded[id] = true
		return
	}

	new szAuth[40], szKey[48], szValue[16]
	get_user_authid(id, szAuth, charsmax(szAuth))
	if(equal(szAuth, "STEAM_ID_PENDING") || equal(szAuth, "") || equal(szAuth, "UNKNOWN")
		|| equal(szAuth, "STEAM_ID_LAN") || equal(szAuth, "BOT"))
		return

	formatex(szKey, charsmax(szKey), "mile#%s", szAuth)
	if(nvault_get(g_iMilestoneVault, szKey, szValue, charsmax(szValue)))
		g_iMilestoneClaimed[id] = str_to_num(szValue)

	g_bMilestoneLoaded[id] = true
}

public client_disconnected(id)
{
	remove_task(id + TASK_LATELOAD)

	// Persist claimed milestones before state reset.
	SaveMilestones(id)

	ResetPlayer(id)
}

// Persists the claimed-milestone bitfield for one player. Called on disconnect
// and from plugin_end (a changelevel must not lose what this map paid).
// Guard against STEAM_ID_PENDING: a player who connected and immediately
// disconnected before Steam auth completed must not corrupt or overwrite a
// legitimate milestone record under a pending key.
SaveMilestones(const id)
{
	if(is_user_bot(id) || !g_bMilestoneLoaded[id] || !g_iMilestoneClaimed[id] || g_iMilestoneVault == INVALID_HANDLE)
		return

	new szAuth[40], szKey[48], szValue[16]
	get_user_authid(id, szAuth, charsmax(szAuth))
	if(equal(szAuth, "STEAM_ID_PENDING") || equal(szAuth, "") || equal(szAuth, "UNKNOWN"))
		return

	formatex(szKey, charsmax(szKey), "mile#%s", szAuth)
	formatex(szValue, charsmax(szValue), "%d", g_iMilestoneClaimed[id])
	nvault_set(g_iMilestoneVault, szKey, szValue)
}

ResetPlayer(const id)
{
	g_iRoundBotXp[id] = 0
	g_iDamageBuffer[id] = 0
	g_iActiveSeconds[id] = 0
	g_iMilestoneClaimed[id] = 0
	g_bMilestoneLoaded[id] = false
	g_iLateTries[id] = 0
	g_iIdleTicks[id] = 0
}

// ============ bot kill + damage xp via DeathMsg ============
public OnDeathMsg()
{
	new iAttacker = read_data(1), iVictim = read_data(2)

	if(!iAttacker || iAttacker == iVictim || !is_user_connected(iAttacker) || !is_user_connected(iVictim))
	{
		return
	}

	if(get_user_team(iAttacker) == get_user_team(iVictim))
	{
		return
	}

	if(get_cvar_num("amx_knife_round_active") == 1)
	{
		return
	}

	if(!crxranks_is_user_loaded(iAttacker))
	{
		return
	}

	// bot kill xp: human attacker, bot victim, capped per round
	if(get_pcvar_num(pcvar_botxp_enabled) && is_user_bot(iVictim))
	{
		new iCap = get_pcvar_num(pcvar_botxp_maxround)
		new iReward = get_pcvar_num(pcvar_botxp_kill)

		if(read_data(3))
		{
			iReward += get_pcvar_num(pcvar_botxp_hs)
		}

		if(iCap <= 0 || g_iRoundBotXp[iAttacker] + iReward <= iCap)
		{
			g_iRoundBotXp[iAttacker] += iReward
			crxranks_give_user_xp(iAttacker, iReward, "", CRXRANKS_XPS_PLUGIN)
		}
	}

	// damage xp: opt-in feature, defaults off to prevent double rewards
	// accumulation happens in client_damage(); nothing to do per kill here
}

// damage accumulation for the opt-in damage xp
public client_damage(iAttacker, iVictim, iDamage)
{
	if(!get_pcvar_num(pcvar_dmgxp_enabled) || !iAttacker || iAttacker == iVictim)
	{
		return
	}

	if(!is_user_connected(iAttacker) || !is_user_connected(iVictim))
	{
		return
	}

	if(get_user_team(iAttacker) == get_user_team(iVictim))
	{
		return
	}

	// Mirror OnDeathMsg: no accrual during knife rounds, or a threshold
	// crossed mid-knife-round would pay real XP.
	if(get_cvar_num("amx_knife_round_active") == 1)
	{
		return
	}

	if(is_user_bot(iVictim))
	{
		return
	}

	g_iDamageBuffer[iAttacker] += iDamage

	if(get_pcvar_num(pcvar_dmgxp_enabled))
	{
		new iThreshold = get_pcvar_num(pcvar_dmgxp_threshold)
		new iAmount = get_pcvar_num(pcvar_dmgxp_amount)

		if(iThreshold > 0 && iAmount > 0 && g_iDamageBuffer[iAttacker] >= iThreshold)
		{
			new iSteps = g_iDamageBuffer[iAttacker] / iThreshold
			g_iDamageBuffer[iAttacker] -= iSteps * iThreshold
			crxranks_give_user_xp(iAttacker, iSteps * iAmount, "", CRXRANKS_XPS_PLUGIN)
		}
	}
}

// ============ happy hour ============
public TaskHappyHour()
{
	new szHour[3], iHour
	format_time(szHour, charsmax(szHour), "%H")
	iHour = str_to_num(szHour)

	new szWday[2], iWday
	format_time(szWday, charsmax(szWday), "%w")
	iWday = str_to_num(szWday)

	new iStart = get_pcvar_num(pcvar_hh_start)
	new iEnd = get_pcvar_num(pcvar_hh_end)
	new iOverride = get_pcvar_num(pcvar_hh_override)

	new bool:bActive

	if(iOverride == 1)
	{
		bActive = true
	}
	else if(iOverride == 2)
	{
		bActive = false
	}
	else
	{
		bActive = IsInWindow(iHour, iStart, iEnd)

		if(bActive && get_pcvar_num(pcvar_hh_weekdays) && (iWday == 0 || iWday == 6))
		{
			bActive = false
		}
	}

	new Float:fMult = (bActive && get_pcvar_num(pcvar_hh_enabled)) ? get_pcvar_float(pcvar_hh_mult) : 1.0

	new pCvar = get_cvar_pointer("fn_happy_hour")
	if(pCvar)
	{
		set_pcvar_float(pCvar, fMult)
	}
}

bool:IsInWindow(const iHour, const iStart, const iEnd)
{
	if(iStart == iEnd)
	{
		return false
	}

	if(iStart < iEnd)
	{
		return (iHour >= iStart && iHour < iEnd)
	}

	// overnight window (e.g. 22 -> 08)
	return (iHour >= iStart || iHour < iEnd)
}

public CmdHappyHourOverride(id, level, cid)
{
	if(!cmd_access(id, level, cid, 2))
	{
		return PLUGIN_HANDLED
	}

	new szArg[4]
	read_argv(1, szArg, charsmax(szArg))

	switch(szArg[0])
	{
		case '1': set_pcvar_num(pcvar_hh_override, 1)
		case '0': set_pcvar_num(pcvar_hh_override, 2)
		default: set_pcvar_num(pcvar_hh_override, 0)
	}

	TaskHappyHour()
	console_print(id, "[FreeNova] Happy hour override: %s", szArg[0] == '1' ? "ON" : (szArg[0] == '0' ? "OFF" : "schedule"))
	return PLUGIN_HANDLED
}

// ============ time rewards (AFK aware) ============
public TaskTimeRewards()
{
	if(!get_pcvar_num(pcvar_time_enabled))
	{
		return
	}

	new bool:bAfkCheck = get_pcvar_num(pcvar_time_afk) != 0

	for(new id = 1; id <= MaxClients; id++)
	{
		if(!is_user_connected(id) || is_user_bot(id))
		{
			continue
		}

		new iTeam = get_user_team(id)

		if(iTeam == 0 || iTeam == 3) // unassigned / spectator
		{
			continue
		}

		new Float:vecOrigin[3], Float:vecAngles[3]
		pev(id, pev_origin, vecOrigin)
		pev(id, pev_v_angle, vecAngles)

		if(bAfkCheck)
		{
			if(xs_vec_equal2(vecOrigin, g_vecLastOrigin[id]) && xs_vec_equal2(vecAngles, g_vecLastAngles[id]))
			{
				// cap the counter here, not the compare below, so leaving
				// AFK state resets the latch (12 ticks = 60s idle)
				if(g_iIdleTicks[id] < 12)
				{
					g_iIdleTicks[id]++
				}
			}
			else
			{
				g_iIdleTicks[id] = 0
			}
		}

		g_vecLastOrigin[id] = vecOrigin
		g_vecLastAngles[id] = vecAngles

		if(g_iIdleTicks[id] >= 12)
		{
			continue
		}

		g_iActiveSeconds[id] += 5

		if(!g_bMilestoneLoaded[id])
			continue

		new iMinutes = g_iActiveSeconds[id] / 60

		for(new m; m < sizeof(g_iMilestoneMinutes); m++)
		{
			if(!(g_iMilestoneClaimed[id] & (1 << m)) && iMinutes >= g_iMilestoneMinutes[m])
			{
				g_iMilestoneClaimed[id] |= (1 << m)
				crxranks_give_user_xp(id, g_iMilestoneXp[m], "", CRXRANKS_XPS_PLUGIN)
				client_print_color(id, print_team_default, "^4[FreeNova]^1 Playtime reward:^3 %d minutes^1 played,^4 +%d XP^1!", g_iMilestoneMinutes[m], g_iMilestoneXp[m])
			}
		}
	}
}

bool:xs_vec_equal2(const Float:vecA[], const Float:vecB[])
{
	return vecA[0] == vecB[0] && vecA[1] == vecB[1] && vecA[2] == vecB[2]
}

// ============ random round xp (lucky drop) ============
public OnRoundStart()
{
	for(new id = 1; id <= MaxClients; id++)
	{
		g_iRoundBotXp[id] = 0
	}
}

public OnRoundEnd()
{
	if(!get_pcvar_num(pcvar_rnd_enabled))
	{
		return
	}

	new iMinPlayers = get_pcvar_num(pcvar_rnd_minplayers)

	if(iMinPlayers > 0 && get_playersnum_ex(GetPlayers_ExcludeBots) < iMinPlayers)
	{
		return
	}

	new iPlayers[MAX_PLAYERS], iNum
	new szFlags[4]

	if(get_pcvar_num(pcvar_rnd_alive))
	{
		// 'c' = skip bots: a bot "winning" pays no XP (CRX IGNORE_BOTS)
		// but still consumes the round's drop
		copy(szFlags, charsmax(szFlags), "ach")
	}
	else
	{
		copy(szFlags, charsmax(szFlags), "ch")
	}

	get_players(iPlayers, iNum, szFlags)

	if(!iNum)
	{
		return
	}

	new iWinner = iPlayers[random(iNum)]
	new iMin = get_pcvar_num(pcvar_rnd_min)
	new iMax = get_pcvar_num(pcvar_rnd_max)
	new iReward = random_num(iMin, iMax > iMin ? iMax : iMin)

	crxranks_give_user_xp(iWinner, iReward, "", CRXRANKS_XPS_PLUGIN)

	new szName[MAX_NAME_LENGTH]
	get_user_name(iWinner, szName, charsmax(szName))
	client_print_color(0, print_team_default, "^4[FreeNova]^1 Lucky Drop:^3 %s^1 won^4 %d XP^1!", szName, iReward)
}
