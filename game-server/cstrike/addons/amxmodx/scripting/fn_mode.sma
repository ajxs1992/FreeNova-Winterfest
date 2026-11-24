/* fn_mode: the one-active-mode arbiter (see include/fn_mode.inc).
 *
 * A mode claims the arbiter with fn_mode_begin(), writes engine cvars only
 * through fn_mode_set() (which snapshots the pre-mode value), and releases it
 * with fn_mode_end(), which restores the whole table in reverse order. A second
 * mode that tries to begin while one is active is refused, with a log line and
 * a chat line to every admin, plus fn_mode_refusal() for the caller.
 *
 * plugin_end() restores whatever is still active: a map change, a plugin
 * reload, a plugin that dies mid-mode or an admin who forgets to end the mode
 * can never leave mp_freezetime pinned at 0, amx_knife_round_active at 1 or an
 * event multiplier stuck on.
 *
 * Console: fn_mode [status|end]  (ADMIN_CFG; server console always allowed)
 *   status - active mode, who began it, payload, refusal reason, cvar table
 *   end    - force-end the active mode and restore its cvars right now
 *
 * Deliberately dependency-free apart from fn_common (boot banner). It has to
 * load even when the rest of the platform layer does not.
 */
#include <amxmodx>
#include <amxmisc>
#include <fn_common>
#include <fn_mode>

#define PLUGIN  "FreeNova Mode Arbiter"
#define VERSION "1.0.0"
#define AUTHOR  "FreeNova"

new g_szMode[32];                              // "" = arbiter free
new g_szPayload[96];
new g_szBy[40];                                // plugin file that claimed it
new g_iCvars;
new g_szCvar[FN_MODE_MAX_CVARS][48];
new g_szValue[FN_MODE_MAX_CVARS][128];         // pre-mode value
new g_szRefusal[192];
new g_iRefusals;
new g_iBegins;
new g_iEnds;

public plugin_natives()
{
	register_library("fn_mode");
	register_native("fn_mode_begin",   "_begin");
	register_native("fn_mode_set",     "_set");
	register_native("fn_mode_end",     "_end");
	register_native("fn_mode_active",  "_active");
	register_native("fn_mode_payload", "_payload");
	register_native("fn_mode_refusal", "_refusal");
	register_native("fn_mode_count",   "_count");
	register_native("fn_mode_cvar",    "_cvar");
}

public plugin_init()
{
	fn_boot_banner("mode", 10);

	register_plugin(PLUGIN, VERSION, AUTHOR);
	register_concmd("fn_mode", "cmdMode", ADMIN_CFG, "<status|end> - inspect / force-end the active mode");
}

/* The safety net: never let a mode outlive its map. */
public plugin_end()
{
	if (!g_szMode[0])
		return;

	new door[48];
	copy(door, charsmax(door), g_szMode);
	new restored = RestoreAll();
	log_amx("[FN-MODE] plugin_end: '%s' still active, restored %d cvars (end-of-map safety net)", door, restored);
}

public cmdMode(id, level, cid)
{
	if (!cmd_access(id, level, cid, 1))
		return PLUGIN_HANDLED;

	new sub[16];
	read_argv(1, sub, charsmax(sub));

	if (equali(sub, "end"))
	{
		if (!g_szMode[0])
		{
			console_print(id, "[FN-MODE] no mode is active.");
			return PLUGIN_HANDLED;
		}
		new door[32];
		copy(door, charsmax(door), g_szMode);
		new restored = RestoreAll();
		log_amx("[FN-MODE] '%s' force-ended by admin %d, restored %d cvars", door, id, restored);
		console_print(id, "[FN-MODE] '%s' ended, %d cvars restored.", door, restored);
		return PLUGIN_HANDLED;
	}

	// status (default)
	if (!g_szMode[0])
		console_print(id, "[FN-MODE] free (begins=%d ends=%d refusals=%d)", g_iBegins, g_iEnds, g_iRefusals);
	else
		console_print(id, "[FN-MODE] active '%s' payload '%s' by %s (%d cvars, begins=%d ends=%d refusals=%d)",
			g_szMode, g_szPayload, g_szBy, g_iCvars, g_iBegins, g_iEnds, g_iRefusals);

	if (g_szRefusal[0])
		console_print(id, "[FN-MODE] last refusal: %s", g_szRefusal);

	for (new i = 0; i < g_iCvars; i++)
	{
		new cur[128], szLine[192];
		get_cvar_string(g_szCvar[i], cur, charsmax(cur));
		formatex(szLine, charsmax(szLine), "  %s = '%s' (pre-mode '%s')", g_szCvar[i], cur, g_szValue[i]);
		console_print(id, "%s", szLine);
	}
	return PLUGIN_HANDLED;
}

/* ---- natives ----------------------------------------------------------- */

public _begin(plugin, params)
{
	new mode[32], payload[96];
	get_string(1, mode, charsmax(mode));
	get_string(2, payload, charsmax(payload));
	new initiator = get_param(3);
	trim(mode);

	if (!mode[0])
		return 0;

	if (g_szMode[0] && !equali(g_szMode, mode))
	{
		formatex(g_szRefusal, charsmax(g_szRefusal),
			"'%s' refused: '%s' is active (payload '%s', by %s)",
			mode, g_szMode, g_szPayload, g_szBy);
		g_iRefusals++;
		log_amx("[FN-MODE] %s", g_szRefusal);
		TellAdmins(g_szRefusal);
		// Never silent to whoever tried: the player who triggered the mode gets
		// one line in chat, server console gets a console line.
		if (initiator > 0 && initiator <= MaxClients && is_user_connected(initiator) && !is_user_bot(initiator))
			client_print(initiator, print_chat, "[FreeNova] Can't start %s: %s is already running.", mode, g_szMode);
		else if (initiator == 0)
			console_print(0, "[FN-MODE] can't start '%s': '%s' is already running (payload '%s')", mode, g_szMode, g_szPayload);
		return 0;
	}

	if (equali(g_szMode, mode))
		return 1;                               // idempotent re-begin

	copy(g_szMode, charsmax(g_szMode), mode);
	copy(g_szPayload, charsmax(g_szPayload), payload);
	g_szBy[0] = EOS;
	get_plugin(plugin, g_szBy, charsmax(g_szBy));
	g_iCvars = 0;
	g_szRefusal[0] = EOS;
	g_iBegins++;
	log_amx("[FN-MODE] begin '%s' (payload '%s', by %s)", g_szMode, g_szPayload, g_szBy);
	return 1;
}

public _set(plugin, params)
{
	new mode[32], cvar[48], value[128];
	get_string(1, mode, charsmax(mode));
	get_string(2, cvar, charsmax(cvar));
	get_string(3, value, charsmax(value));

	if (!g_szMode[0] || !equali(g_szMode, mode))
	{
		log_amx("[FN-MODE] set '%s'='%s' refused: arbiter is '%s'", cvar, value, g_szMode[0] ? g_szMode : "<free>");
		return 0;
	}

	new ptr = get_cvar_pointer(cvar);
	if (!ptr)
	{
		// Never create cvars here: a typo would then "restore" a cvar that
		// never existed instead of failing loudly at the call site.
		log_amx("[FN-MODE] %s: unknown cvar '%s' - not created, value not applied", mode, cvar);
		return 0;
	}

	new idx = FindTracked(cvar);
	if (idx < 0)
	{
		if (g_iCvars >= FN_MODE_MAX_CVARS)
		{
			log_amx("[FN-MODE] %s: cvar table full (%d), '%s' not applied", mode, FN_MODE_MAX_CVARS, cvar);
			return 0;
		}
		idx = g_iCvars++;
		copy(g_szCvar[idx], charsmax(g_szCvar[]), cvar);
		get_pcvar_string(ptr, g_szValue[idx], charsmax(g_szValue[]));
	}

	set_pcvar_string(ptr, value);
	log_amx("[FN-MODE] %s: %s '%s' -> '%s' (pre-mode '%s')",
		mode, g_szCvar[idx], g_szValue[idx], value, g_szValue[idx]);
	return 1;
}

public _end(plugin, params)
{
	new mode[32];
	get_string(1, mode, charsmax(mode));

	if (!g_szMode[0] || !equali(g_szMode, mode))
		return 0;

	new restored = RestoreAll();
	g_iEnds++;
	log_amx("[FN-MODE] end '%s' (restored %d cvars)", mode, restored);
	return restored;
}

public _active(plugin, params)
{
	new len = get_param(2);
	set_string(1, g_szMode, len);
	return g_szMode[0] ? 1 : 0;
}

public _payload(plugin, params)
{
	new mode[32];
	get_string(1, mode, charsmax(mode));
	new len = get_param(3);

	if (mode[0] && !equali(mode, g_szMode))
	{
		set_string(2, "", len);
		return 0;
	}
	set_string(2, g_szPayload, len);
	return g_szPayload[0] ? 1 : 0;
}

public _refusal(plugin, params)
{
	new len = get_param(1);
	set_string(1, g_szRefusal, len);
	return g_szRefusal[0] ? 1 : 0;
}

public _count(plugin, params)
{
	return g_iCvars;
}

public _cvar(plugin, params)
{
	new idx = get_param(1);
	if (idx < 0 || idx >= g_iCvars)
		return 0;

	set_string(2, g_szCvar[idx], get_param(3));
	set_string(4, g_szValue[idx], get_param(5));
	return 1;
}

/* ---- internals --------------------------------------------------------- */

FindTracked(const cvar[])
{
	for (new i = 0; i < g_iCvars; i++)
	{
		if (equali(g_szCvar[i], cvar))
			return i;
	}
	return -1;
}

/* Restore last-set-first (reverse order keeps "A overrides B overrides A"
 * sequences correct) and release the arbiter. Returns the restored count. */
RestoreAll()
{
	new restored;
	for (new i = g_iCvars - 1; i >= 0; i--)
	{
		new ptr = get_cvar_pointer(g_szCvar[i]);
		if (!ptr)
			continue;
		set_pcvar_string(ptr, g_szValue[i]);
		restored++;
	}

	g_iCvars = 0;
	g_szMode[0] = EOS;
	g_szPayload[0] = EOS;
	g_szBy[0] = EOS;
	return restored;
}

/* A refusal is an operator problem (two modes colliding), so the reason goes
 * to the people who can act on it, not into the chat of the server. */
TellAdmins(const reason[])
{
	new szLine[224];
	formatex(szLine, charsmax(szLine), "[FreeNova] mode %s", reason);

	new players[32], num, id;
	get_players(players, num, "ch");
	for (new i = 0; i < num; i++)
	{
		id = players[i];
		if (!(get_user_flags(id) & ADMIN_ADMIN))
			continue;
		client_print(id, print_chat, "%s", szLine);
	}
}
