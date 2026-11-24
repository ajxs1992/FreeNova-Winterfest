/* fn_link: sync-service link, journal-first outbox (3.0 M10a). Game servers
 * must survive network loss, so this module NEVER blocks on the network:
 * events go to a bounded memory queue AND an append-only journal
 * (datadir/fn_outbox.log). Transport (HTTP to syncd) is M10b; the journal
 * is the crash-safe handoff it will replay. Server identity comes from the
 * fn_server_id cvar (default fn-01). API key file (configs/syncd.key) is
 * required only by M10b transport; its absence is logged once, never fatal,
 * and the key is never a cvar, never logged. */
#include <amxmodx>
#include <amxmisc>
#include <fn_core>
#include <fn_common>

#define LINK_MAXQ 64

new Array:g_q;
new bool:g_live;
new g_dropped;
new g_journalFails;
new g_seq;
new bool:g_keyWarned;

public plugin_natives()
{
	set_native_filter("native_filter");
	register_library("fn_link");
	register_native("fn_link_push", "_push");
	register_native("fn_link_status", "_status");
	register_native("fn_link_queued", "_queued");
}

public native_filter(const name[], index, trap)
{
	if (!trap && contain(name, "fn_") == 0)
		return PLUGIN_HANDLED;
	return PLUGIN_CONTINUE;
}

public plugin_init()
{
	fn_boot_banner("link", 3);

	register_plugin("FreeNova Link", "3.0.0", "FreeNova");
	if (!LibraryExists("fn_core", LibType_Library))
	{
		log_amx("[FN-LINK] fn_core missing, pausing self");
		pause("d");
		return;
	}
	g_q = ArrayCreate(256);
	g_live = true;
	fn_health_set("link", "ok");
}

public plugin_cfg()
{
	new keyf[128];
	get_configsdir(keyf, charsmax(keyf));
	format(keyf, charsmax(keyf), "%s/syncd.key", keyf);
	if (!file_exists(keyf) && !g_keyWarned)
	{
		g_keyWarned = true;
		log_amx("[FN-LINK] syncd.key absent: journal-only mode (transport is M10b)");
	}
}

public plugin_end()
{
	if (g_live) ArrayDestroy(g_q);
}

serverId(out[], len)
{
	get_cvar_string("fn_server_id", out, len);
	if (!out[0])
		copy(out, len, "fn-01");
}

journalLine(const line[])
{
	new dir[96], path[192];
	get_datadir(dir, charsmax(dir));
	formatex(path, charsmax(path), "%s/fn_outbox.log", dir);
	new f = fopen(path, "at");
	if (!f)
	{
		g_journalFails++;
		return 0;
	}
	fputs(f, line);
	fclose(f);
	return 1;
}

public _push(plugin, params)
{
	new kind[32], payload[192];
	get_string(1, kind, charsmax(kind));
	get_string(2, payload, charsmax(payload));
	if (!kind[0])
		return 0;
	for (new i = 0; kind[i]; i++)
	{
		if (kind[i] == '|' || kind[i] == '^n')
			return 0;
	}
	new clean[192];
	copy(clean, charsmax(clean), payload);
	replace_all(clean, charsmax(clean), "|", " ");
	replace_all(clean, charsmax(clean), "^n", " ");
	new srv[32];
	serverId(srv, charsmax(srv));
	g_seq++;
	new eid[96];
	formatex(eid, charsmax(eid), "%s-%d-%d", srv, get_systime(), g_seq);
	new line[320];
	formatex(line, charsmax(line), "%d|%s|%s|%s|%s^n", get_systime(), srv, eid, kind, clean);
	journalLine(line);
	if (ArraySize(g_q) >= LINK_MAXQ)
	{
		ArrayDeleteItem(g_q, 0);
		g_dropped++;
	}
	ArrayPushString(g_q, line);
	return 1;
}

public _status(plugin, params)
{
	new outlen = get_param(2);
	new buf[96];
	formatex(buf, charsmax(buf), "journal-only queued=%d dropped=%d jfail=%d", ArraySize(g_q), g_dropped, g_journalFails);
	set_string(1, buf, outlen);
	return 1;
}

public _queued(plugin, params)
{
	return ArraySize(g_q);
}
