/* fn_ratelimit: shared token-bucket service (3.0 M8). One table for all
 * callers (no double-enforcement by independent plugins). Memory counters
 * only (no SQL per check by design). Overflow guard: when the key table
 * exceeds fn_limit_maxkeys, oldest entries are pruned opportunistically.
 * Staff exceptions and burst policy are caller-side. */
#include <amxmodx>
#include <fn_core>
#include <fn_common>

new Trie:g_b;
new bool:g_live;
new Array:g_order;
new g_cvarMax;

public plugin_natives()
{
	set_native_filter("native_filter");
	register_library("fn_limits");
	register_native("fn_limit_check", "_check");
	register_native("fn_limit_prune", "_prune");
}

public native_filter(const name[], index, trap)
{
	if (!trap && contain(name, "fn_") == 0)
		return PLUGIN_HANDLED;
	return PLUGIN_CONTINUE;
}

public plugin_init()
{
	fn_boot_banner("ratelimit", 3);

	register_plugin("FreeNova Limits", "3.0.0", "FreeNova");
	g_cvarMax = register_cvar("fn_limit_maxkeys", "512");
	if (!LibraryExists("fn_core", LibType_Library))
	{
		log_amx("[FN-LIMITS] fn_core missing, pausing self");
		pause("d");
		return;
	}
	g_b = TrieCreate();
	g_live = true;
	g_order = ArrayCreate(64);
	fn_health_set("limits", "ok");
}

public plugin_end()
{
	if (g_live) TrieDestroy(g_b);
	if (g_live) ArrayDestroy(g_order);
}

ensureRoom()
{
	new cap = get_pcvar_num(g_cvarMax);
	if (cap < 64)
		cap = 64;
	if (ArraySize(g_order) <= cap)
		return;
	new drop = ArraySize(g_order) - cap + 16;
	if (drop < 1)
		drop = 1;
	for (new i = 0; i < drop; i++)
	{
		new k[64];
		ArrayGetString(g_order, 0, k, charsmax(k));
		ArrayDeleteItem(g_order, 0);
		TrieDeleteKey(g_b, k);
	}
}

public _check(plugin, params)
{
	new key[64];
	get_string(1, key, charsmax(key));
	new burst = get_param(2);
	new per = get_param(3);
	if (!key[0] || burst < 1 || per < 1)
		return 0;
	if (burst > 100)
		burst = 100;
	if (per > 3600)
		per = 3600;
	ensureRoom();
	new Float:now = get_gametime();
	new data[48];
	new Float:tokens = float(burst);
	new Float:last = now;
	if (TrieGetString(g_b, key, data, charsmax(data)))
	{
		new tmp[48], a[16], b[16];
		copy(tmp, charsmax(tmp), data);
		replace_all(tmp, charsmax(tmp), "|", " ");
		parse(tmp, a, charsmax(a), b, charsmax(b));
		tokens = str_to_float(a);
		last = str_to_float(b);
	}
	new Float:refill = (now - last) * float(burst) / float(per);
	tokens += refill;
	if (tokens > float(burst))
		tokens = float(burst);
	if (tokens < 1.0)
	{
		new keep[48];
		formatex(keep, charsmax(keep), "%f|%f", tokens, now);
		TrieSetString(g_b, key, keep);
		return 0;
	}
	tokens -= 1.0;
	new keep2[48];
	formatex(keep2, charsmax(keep2), "%f|%f", tokens, now);
	if (!TrieKeyExists(g_b, key))
		ArrayPushString(g_order, key);
	TrieSetString(g_b, key, keep2);
	return 1;
}

public _prune(plugin, params)
{
	new maxage = get_param(1);
	if (maxage < 0)
		return 0;
	new now = get_systime();
	new n = ArraySize(g_order), done = 0;
	new k[64], data[48];
	for (new i = n - 1; i >= 0; i--)
	{
		ArrayGetString(g_order, i, k, charsmax(k));
		if (!TrieGetString(g_b, k, data, charsmax(data)))
		{
			ArrayDeleteItem(g_order, i);
			done++;
			continue;
		}
		new a[16], b[16], tmp[48];
		copy(tmp, charsmax(tmp), data);
		replace_all(tmp, charsmax(tmp), "|", " ");
		parse(tmp, a, charsmax(a), b, charsmax(b));
		if (now - str_to_float(b) > float(maxage))
		{
			TrieDeleteKey(g_b, k);
			ArrayDeleteItem(g_order, i);
			done++;
		}
	}
	return done;
}
