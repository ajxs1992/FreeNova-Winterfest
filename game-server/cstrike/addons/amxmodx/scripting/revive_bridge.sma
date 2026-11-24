#include <amxmodx>
#include <reapi>
#include <menabp>
#include <rt_api>

new g_iRevivesThisRound[MAX_PLAYERS + 1]

// menabp provider (battlepass_core.amxx) can be paused or unloaded — calling
// its natives then raises "dynanative into a paused plugin" errors, so gate
// every call behind this (f1a7d20 pattern, cf. weaponmenu).
stock bool:MenabpUsable()
{
    new total = get_pluginsnum()
    new file[64], title[32], version[16], author[32], status[16]
    for (new i = 0; i < total; i++)
    {
        get_plugin(i, file, charsmax(file), title, charsmax(title), version, charsmax(version), author, charsmax(author), status, charsmax(status));
        if (equali(file, "battlepass_core.amxx"))
            return equali(status, "running") ? true : false;
    }
    return bool:LibraryExists("menabp", LibType_Library);
}

public plugin_init()
{
	register_plugin("BP Revive Bridge", "1.3", "Z I Z O U & FreeNova")
	register_event("HLTV", "Event_NewRound", "a", "1=0", "2=0")
	RegisterHookChain(RG_CSGameRules_CleanUpMap, "CSGameRules_CleanUpMap_Post", true)
}

public Event_NewRound()
{
	arrayset(g_iRevivesThisRound, 0, sizeof(g_iRevivesThisRound))
}

public CSGameRules_CleanUpMap_Post()
{
	arrayset(g_iRevivesThisRound, 0, sizeof(g_iRevivesThisRound))
}

public client_disconnected(id)
{
	g_iRevivesThisRound[id] = 0
}

/*
 * ReviveTeammates integration.
 * Gating is per-attempt via the rt_revive_start multi-forward (ET_STOP):
 * return PLUGIN_HANDLED to cancel the revive attempt.
 * Revive duration dynamically reflects the player's Combat Medic skill stage:
 * - Stage 1: 3.0 seconds standard CPR
 * - Stage 2: 1.5 seconds rapid defibrillation
 * BP max-revives (native > 0) is a tighter per-round cap; 0 falls through to RT cvars.
 */

public rt_revive_start(const iEnt, const iPlayer, const iActivator, const Modes:eMode)
{
	if(eMode != MODE_REVIVE)
		return PLUGIN_CONTINUE

	if(is_nullent(iEnt) || !(1 <= iActivator <= MaxClients) || !is_user_connected(iActivator))
		return PLUGIN_CONTINUE

	if(!MenabpUsable())
	{
		client_print(iActivator, print_center, "Combat Medic unavailable right now.")
		return PLUGIN_HANDLED
	}
	if(!menabp_has_revive(iActivator))
	{
		client_print(iActivator, print_center, "You have not unlocked Combat Medic skill yet.")
		return PLUGIN_HANDLED
	}

	new iMax = menabp_get_revive_max_revives(iActivator)
	if(iMax > 0 && g_iRevivesThisRound[iActivator] >= iMax)
	{
		client_print(iActivator, print_center, "Combat Medic revive limit reached this round.")
		return PLUGIN_HANDLED
	}

	return PLUGIN_CONTINUE
}

public rt_revive_end(const iEnt, const iPlayer, const iActivator, const Modes:eMode)
{
	if(eMode != MODE_REVIVE || !(1 <= iActivator <= MaxClients) || !is_user_connected(iActivator))
		return

	if(!is_nullent(iEnt) && Modes:get_entvar(iEnt, var_iuser3) == MODE_PLANT)
		return

	g_iRevivesThisRound[iActivator]++
	if(MenabpUsable())
		menabp_note_revive(iActivator)
}

public rt_revive_start_post(const iEnt, const iPlayer, const iActivator, const Modes:eMode)
{
	if(eMode != MODE_REVIVE || is_nullent(iEnt) || !(1 <= iActivator <= MaxClients) || !is_user_connected(iActivator))
		return

	new Float:fTime = 0.0
	if(MenabpUsable())
		fTime = menabp_get_revive_time(iActivator)
	if(fTime <= 0.0)
		return

	if(fTime < 1.0)
		fTime = 1.0
	else if(fTime > 30.0)
		fTime = 30.0

	new Float:fGameTime = get_gametime()
	set_entvar(iEnt, var_fuser1, fGameTime + fTime)
	set_entvar(iEnt, var_fuser3, fTime)
}
