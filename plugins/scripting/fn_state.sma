/* fn_state: crash-safe generic KV (3.0 M4). Sections isolate concerns.
 * Storage: datadir/fn_state_<section>.cfg, lines key=value. Writes are
 * atomic (tmp + rename on the same filesystem). Malformed lines are skipped
 * on load, never fatal. In-memory mirror (Trie + key array) serves reads;
 * every mutation persists immediately (no flush to lose). Key charset:
 * anything except '=' ',' newline (rejected otherwise). Values: anything
 * except newline. List pagination is caller-managed (M10); sweep callers
 * size buffers for their admin counts. */
#include <amxmodx>
#include <amxmisc>
#include <fn_core>
#include <fn_common>

new Trie:g_vals;
new bool:g_live;
new Array:g_keys;
new Array:g_ready;

public plugin_natives()
{
	set_native_filter("native_filter");
	register_library("fn_state");
	register_native("fn_state_set", "_set");
	register_native("fn_state_get", "_get");
	register_native("fn_state_del", "_del");
	register_native("fn_state_list", "_list");
}

public native_filter(const name[], index, trap)
{
	if (!trap && contain(name, "fn_") == 0)
		return PLUGIN_HANDLED;
	return PLUGIN_CONTINUE;
}

public plugin_init()
{
	fn_boot_banner("state", 4);

	register_plugin("FreeNova State", "3.0.0", "FreeNova");
	if (!LibraryExists("fn_core", LibType_Library))
	{
		log_amx("[FN-STATE] fn_core missing, pausing self");
		pause("d");
		return;
	}
	g_vals = TrieCreate();
	g_keys = ArrayCreate(96);
	g_ready = ArrayCreate(32);
	g_live = true;
	fn_health_set("state", "ok");
}

public plugin_end()
{
	if (g_live) TrieDestroy(g_vals);
	if (g_live) ArrayDestroy(g_keys);
	if (g_live) ArrayDestroy(g_ready);
}

bool:validSection(const s[])
{
	new len = strlen(s);
	if (len < 1 || len > 24) return false;
	for (new i = 0; i < len; i++)
	{
		new c = s[i];
		if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_'))
			return false;
	}
	return true;
}

bool:validKey(const k[])
{
	new len = strlen(k);
	if (len < 1 || len > 64) return false;
	for (new i = 0; i < len; i++)
	{
		if (k[i] == '=' || k[i] == ',' || k[i] == '^n' || k[i] == '^r')
			return false;
	}
	return true;
}

compKey(const section[], const key[], out[], len)
{
	formatex(out, len, "%s^1%s", section, key);
}

sectionPath(const section[], out[], len)
{
	new dir[96];
	get_datadir(dir, charsmax(dir));
	formatex(out, len, "%s/fn_state_%s.cfg", dir, section);
}

bool:sectionReady(const section[])
{
	new n = ArraySize(g_ready);
	new cur[32];
	for (new i = 0; i < n; i++)
	{
		ArrayGetString(g_ready, i, cur, charsmax(cur));
		if (equal(cur, section))
			return true;
	}
	return false;
}

loadSection(const section[])
{
	if (sectionReady(section))
		return;
	new path[192];
	sectionPath(section, path, charsmax(path));
	if (!file_exists(path)) return;
	new f = fopen(path, "rt");
	if (!f) return;
	new line[320], ck[96];
	while (fgets(f, line, charsmax(line)))
	{
		trim(line);
		if (!line[0] || line[0] == ';') continue;
		new eq = contain(line, "=");
		if (eq < 1) continue;
		copy(ck, eq, line);
		if (!validKey(ck)) continue;
		compKey(section, ck, ck, charsmax(ck));
		if (!TrieKeyExists(g_vals, ck))
			ArrayPushString(g_keys, ck);
		TrieSetString(g_vals, ck, line[eq + 1]);
	}
	fclose(f);
	ArrayPushString(g_ready, section);
}

saveSection(const section[])
{
	new path[192], tmp[192];
	sectionPath(section, path, charsmax(path));
	formatex(tmp, charsmax(tmp), "%s.tmp", path);
	delete_file(tmp);
	new f = fopen(tmp, "wt");
	if (!f) return 0;
	new n = ArraySize(g_keys);
	new ck[96], pre[32], val[224];
	formatex(pre, charsmax(pre), "%s^1", section);
	new prelen = strlen(pre);
	for (new i = 0; i < n; i++)
	{
		ArrayGetString(g_keys, i, ck, charsmax(ck));
		if (strncmp(ck, pre, prelen) != 0) continue;
		TrieGetString(g_vals, ck, val, charsmax(val));
		new line[320];
		formatex(line, charsmax(line), "%s=%s^n", ck[prelen], val);
		fputs(f, line);
	}
	fclose(f);
	delete_file(path);
	if (!rename_file(tmp, path)) return 0;
	return 1;
}

forgetKey(const ck[])
{
	new n = ArraySize(g_keys);
	new cur[96];
	for (new i = 0; i < n; i++)
	{
		ArrayGetString(g_keys, i, cur, charsmax(cur));
		if (equal(cur, ck))
		{
			ArrayDeleteItem(g_keys, i);
			return;
		}
	}
}

public _set(plugin, params)
{
	new section[32], key[64], val[224];
	get_string(1, section, charsmax(section));
	get_string(2, key, charsmax(key));
	get_string(3, val, charsmax(val));
	if (!validSection(section) || !validKey(key)) return 0;
	loadSection(section);
	for (new i = 0; val[i]; i++)
	{
		if (val[i] == '^n' || val[i] == '^r') return 0;
	}
	new ck[96];
	compKey(section, key, ck, charsmax(ck));
	if (!TrieKeyExists(g_vals, ck))
		ArrayPushString(g_keys, ck);
	TrieSetString(g_vals, ck, val);
	if (!saveSection(section)) return -1;
	return 1;
}

public _get(plugin, params)
{
	new section[32], key[64], outlen = get_param(4);
	get_string(1, section, charsmax(section));
	get_string(2, key, charsmax(key));
	if (!validSection(section) || !validKey(key)) return 0;
	loadSection(section);
	new ck[96];
	compKey(section, key, ck, charsmax(ck));
	new val[224];
	if (!TrieGetString(g_vals, ck, val, charsmax(val))) return 0;
	set_string(3, val, outlen);
	return 1;
}

public _del(plugin, params)
{
	new section[32], key[64];
	get_string(1, section, charsmax(section));
	get_string(2, key, charsmax(key));
	if (!validSection(section) || !validKey(key)) return 0;
	loadSection(section);
	new ck[96];
	compKey(section, key, ck, charsmax(ck));
	if (!TrieKeyExists(g_vals, ck)) return 0;
	TrieDeleteKey(g_vals, ck);
	forgetKey(ck);
	if (!saveSection(section)) return -1;
	return 1;
}

public _list(plugin, params)
{
	new section[32], outlen = get_param(3);
	get_string(1, section, charsmax(section));
	if (!validSection(section)) return 0;
	loadSection(section);
	new pre[32];
	formatex(pre, charsmax(pre), "%s^1", section);
	new prelen = strlen(pre);
	new out[512];
	out[0] = 0;
	new total = 0, n = ArraySize(g_keys), ck[96];
	for (new i = 0; i < n; i++)
	{
		ArrayGetString(g_keys, i, ck, charsmax(ck));
		if (strncmp(ck, pre, prelen) != 0) continue;
		total++;
		new piece[96];
		formatex(piece, charsmax(piece), "%s%s", total > 1 ? "," : "", ck[prelen]);
		if (strlen(out) + strlen(piece) < 511)
			add(out, charsmax(out), piece);
	}
	set_string(2, out, outlen);
	return total;
}
