/* fn_perms: central permission authority (3.0 M4, approved N3 unify).
 * Profiles own granular NODES; a flag bridge confers engine AMXX flags so
 * legacy flag checks pass for grantees (no caller rewrites needed for the
 * mapped subset). Deliberately NOT auto-conferred (M7 rewire owns them):
 * SCAN/BAN-share ADMIN_BAN only via BAN_TEMP (perm still needs confirm),
 * while STAFF/SERVER_EXEC/DIAG/REPORTS/WARN confer nothing yet.
 * Grants persist in fn_state (section "perms", atomic) + base-flag snapshots
 * (section "permbase"); temp grants expire via 60s sweep; everything audits.
 * VIP carries zero nodes (entitlement by profile id, never staff power). */
#include <amxmodx>
#include <amxmisc>
#include <fn_core>
#include <fn_audit>
#include <fn_state>
#include <fn_common>

#define MAX_NODES 18
#define SWEEP_TASK 90210

new g_nodeFlag[MAX_NODES][4];
new g_profNodes[7];
new g_cvarSweep;

public plugin_natives()
{
	set_native_filter("native_filter");
	register_library("fn_perms");
	register_native("fn_perm_check", "_check");
	register_native("fn_perm_grant", "_grant");
	register_native("fn_perm_revoke", "_revoke");
	register_native("fn_perm_profile", "_profile");
	register_native("fn_perm_grant_mask", "_grant_mask");
	register_native("fn_perm_nodes", "_nodes");
}

public native_filter(const name[], index, trap)
{
	if (!trap && contain(name, "fn_") == 0)
		return PLUGIN_HANDLED;
	return PLUGIN_CONTINUE;
}

public plugin_init()
{
	fn_boot_banner("perms", 7);

	register_plugin("FreeNova Permissions", "3.0.0", "FreeNova");
	if (!LibraryExists("fn_core", LibType_Library))
	{
		log_amx("[FN-PERMS] fn_core missing, pausing self");
		pause("d");
		return;
	}
	if (!LibraryExists("fn_audit", LibType_Library))
	{
		log_amx("[FN-PERMS] fn_audit missing, pausing self");
		pause("d");
		return;
	}
	if (!LibraryExists("fn_state", LibType_Library))
	{
		log_amx("[FN-PERMS] fn_state missing, pausing self");
		pause("d");
		return;
	}
	copy(g_nodeFlag[0], 3, "c");
	copy(g_nodeFlag[1], 3, "e");
	copy(g_nodeFlag[2], 3, "m");
	copy(g_nodeFlag[3], 3, "");
	copy(g_nodeFlag[4], 3, "i");
	copy(g_nodeFlag[5], 3, "d");
	copy(g_nodeFlag[6], 3, "d");
	copy(g_nodeFlag[7], 3, "d");
	copy(g_nodeFlag[8], 3, "d");
	copy(g_nodeFlag[9], 3, "");
	copy(g_nodeFlag[10], 3, "f");
	copy(g_nodeFlag[11], 3, "j");
	copy(g_nodeFlag[12], 3, "g");
	copy(g_nodeFlag[13], 3, "");
	copy(g_nodeFlag[14], 3, "");
	copy(g_nodeFlag[15], 3, "");
	copy(g_nodeFlag[16], 3, "i");
	copy(g_nodeFlag[17], 3, "u");
	g_profNodes[0] = 0;
	g_profNodes[1] = 0;
	g_profNodes[2] = (1<<3)|(1<<9)|(1<<16);
	g_profNodes[3] = (1<<0)|(1<<1)|(1<<2)|(1<<3)|(1<<4)|(1<<9)|(1<<11)|(1<<16)|(1<<17);
	g_profNodes[4] = (1<<0)|(1<<1)|(1<<2)|(1<<3)|(1<<4)|(1<<5)|(1<<7)|(1<<8)|(1<<9)|(1<<10)|(1<<11)|(1<<12)|(1<<15)|(1<<16)|(1<<17);
	g_profNodes[5] = g_profNodes[4]|(1<<6)|(1<<13)|(1<<14);
	g_profNodes[6] = 0x3FFFF;
	g_cvarSweep = register_cvar("fn_perms_sweep", "60.0");
	set_task(60.0, "sweep", SWEEP_TASK);
	fn_health_set("perms", "ok");
}

profileNodes(profile)
{
	if (profile < 0 || profile > 6)
		return 0;
	return g_profNodes[profile];
}

authOf(id, out[], len)
{
	if (id < 1 || id > MaxClients || !is_user_connected(id))
		return 0;
	get_user_authid(id, out, len);
	return out[0] ? 1 : 0;
}

grantKey(const auth[], scope, out[], len)
{
	formatex(out, len, "%s|%d", auth, scope);
}

parseGrant(const val[], &profile, &expiry, &nodes)
{
	new tmp[96];
	copy(tmp, charsmax(tmp), val);
	replace_all(tmp, charsmax(tmp), "|", " ");
	new ps[12], es[16], ns[16];
	parse(tmp, ps, charsmax(ps), es, charsmax(es), ns, charsmax(ns));
	profile = str_to_num(ps);
	expiry = str_to_num(es);
	nodes = str_to_num(ns);
}

grantValid(expiry)
{
	if (expiry <= 0)
		return 1;
	return get_systime() < expiry ? 1 : 0;
}

baseFlags(const auth[])
{
	new v[16];
	if (fn_state_get("permbase", auth, v, charsmax(v)))
		return str_to_num(v);
	return 0;
}

applyFor(const auth[])
{
	new players[32], num;
	get_players(players, num, "h");
	for (new i = 0; i < num; i++)
	{
		new a[32];
		get_user_authid(players[i], a, charsmax(a));
		if (equal(a, auth))
		{
			applyId(players[i]);
			return;
		}
	}
}

applyId(id)
{
	new auth[32];
	if (!authOf(id, auth, charsmax(auth)))
		return;
	new flags = baseFlags(auth);
	new key[96], val[96];
	for (new scope = 0; scope <= 2; scope++)
	{
		if (scope == 1)
			continue;
		grantKey(auth, scope, key, charsmax(key));
		if (!fn_state_get("perms", key, val, charsmax(val)))
			continue;
		new profile, expiry, nodes;
		parseGrant(val, profile, expiry, nodes);
		if (!grantValid(expiry))
			continue;
		new nb = nodes;
		for (new n = 0; n < MAX_NODES; n++)
		{
			if (nb & (1 << n))
			{
				if (g_nodeFlag[n][0])
					flags |= read_flags(g_nodeFlag[n]);
			}
		}
	}
	set_user_flags(id, flags);
}

public client_authorized(id)
{
	new auth[32];
	if (!authOf(id, auth, charsmax(auth)))
		return;
	new cur = get_user_flags(id);
	new curbuf[16];
	num_to_str(cur, curbuf, charsmax(curbuf));
	fn_state_set("permbase", auth, curbuf);
	applyId(id);
}

/* NOTE: grants are authid-keyed; bots share "BOT" (M4 identity work owns
 * per-entity keys). Counts/scopes for BOT apply to the bot pool as one. */
doGrant(admin, target, profile, nodes, minutes, scope, &outId)
{
	outId = 0;
	if (target < 1 || !is_user_connected(target))
		return 0;
	if (scope != 0 && scope != 2)
		return 0;
	new auth[32];
	if (!authOf(target, auth, charsmax(auth)))
		return 0;
	if (!LibraryExists("fn_audit", LibType_Library))
		return 0;
	new expiry = 0;
	if (minutes > 0)
		expiry = get_systime() + minutes * 60;
	else if (minutes < 0)
		return 0;
	new key[96], val[96];
	grantKey(auth, scope, key, charsmax(key));
	formatex(val, charsmax(val), "%d|%d|%d", profile, expiry, nodes);
	if (fn_state_set("perms", key, val) <= 0)
		return 0;
	applyId(target);
	new c[24];
	fn_case_new(admin, c, charsmax(c));
	new detail[64];
	formatex(detail, charsmax(detail), "profile=%d scope=%d mins=%d", profile, scope, minutes);
	fn_audit_append(c, admin, target, "perm.grant", detail);
	outId = target;
	return 1;
}

doRevoke(admin, const auth[], scope, const why[])
{
	new key[96], val[96];
	grantKey(auth, scope, key, charsmax(key));
	if (!fn_state_get("perms", key, val, charsmax(val)))
		return 0;
	fn_state_del("perms", key);
	applyFor(auth);
	if (LibraryExists("fn_audit", LibType_Library))
	{
		new c[24];
		fn_case_new(admin, c, charsmax(c));
		fn_audit_append(c, admin, 0, why, auth);
	}
	return 1;
}

public sweep()
{
	remove_task(SWEEP_TASK);
	new iv = get_pcvar_num(g_cvarSweep);
	if (iv == 0)
		return;
	if (iv < 15)
		iv = 15;
	set_task(float(iv), "sweep", SWEEP_TASK);
	new buf[512];
	new total = fn_state_list("perms", buf, charsmax(buf));
	if (total <= 0)
		return;
	new start = 0, idx = 0;
	new key[96];
	while (idx < total)
	{
		new comma = contain(buf[start], ",");
		if (comma < 0)
			copy(key, charsmax(key), buf[start]);
		else
		{
			copy(key, comma, buf[start]);
		}
		if (key[0])
		{
			new bar = contain(key, "|");
			if (bar > 0)
			{
				new val[96];
				if (fn_state_get("perms", key, val, charsmax(val)))
				{
					new profile, expiry, nodes;
					parseGrant(val, profile, expiry, nodes);
					#pragma unused profile
					#pragma unused nodes
					if (expiry > 0 && get_systime() >= expiry)
					{
						new auth[64];
						copy(auth, bar, key);
						doRevoke(0, auth, str_to_num(key[bar + 1]), "perm.expire");
					}
				}
			}
		}
		if (comma < 0)
			break;
		start += comma + 1;
		idx++;
		if (start >= strlen(buf))
			break;
	}
}

public _check(plugin, params)
{
	new id = get_param(1);
	new node = get_param(2);
	if (id < 1)
		return 1;
	if (node < 0 || node >= MAX_NODES)
		return 0;
	if (id > MaxClients || !is_user_connected(id))
		return 0;
	new auth[32];
	if (!authOf(id, auth, charsmax(auth)))
		return 0;
	if (!LibraryExists("fn_state", LibType_Library))
		return 0;
	new key[96], val[96];
	for (new s = 0; s < 3; s++)
	{
		if (s == 1)
			continue;
		grantKey(auth, s, key, charsmax(key));
		if (!fn_state_get("perms", key, val, charsmax(val)))
			continue;
		new profile, expiry, nodes;
		parseGrant(val, profile, expiry, nodes);
		#pragma unused profile
		#pragma unused nodes
		if (!grantValid(expiry))
		{
			doRevoke(0, auth, s, "perm.expire");
			continue;
		}
		if (nodes & (1 << node))
			return 1;
	}
	return 0;
}

public _grant(plugin, params)
{
	new admin = get_param(1);
	new target = get_param(2);
	new profile = get_param(3);
	new minutes = get_param(4);
	new scope = get_param(5);
	if (profile < 0 || profile > 6)
		return 0;
	if (!LibraryExists("fn_state", LibType_Library))
		return 0;
	if (!LibraryExists("fn_audit", LibType_Library))
		return 0;
	new dummy;
	return doGrant(admin, target, profile, profileNodes(profile), minutes, scope, dummy);
}

public _grant_mask(plugin, params)
{
	new admin = get_param(1);
	new target = get_param(2);
	new mask = get_param(3);
	new minutes = get_param(4);
	new scope = get_param(5);
	mask &= 0x3FFFF;
	new dummy;
	return doGrant(admin, target, 7, mask, minutes, scope, dummy);
}

public _revoke(plugin, params)
{
	new admin = get_param(1);
	new target = get_param(2);
	if (target < 1 || !is_user_connected(target))
		return 0;
	new auth[32];
	if (!authOf(target, auth, charsmax(auth)))
		return 0;
	new hit = 0;
	if (doRevoke(admin, auth, 0, "perm.revoke"))
		hit = 1;
	if (doRevoke(admin, auth, 2, "perm.revoke"))
		hit = 1;
	return hit;
}

public _profile(plugin, params)
{
	new id = get_param(1);
	if (id < 1 || id > MaxClients || !is_user_connected(id))
		return 0;
	new auth[32];
	if (!authOf(id, auth, charsmax(auth)))
		return 0;
	if (!LibraryExists("fn_state", LibType_Library))
		return 0;
	new best = 0;
	new key[96], val[96];
	for (new s = 0; s < 3; s++)
	{
		if (s == 1)
			continue;
		grantKey(auth, s, key, charsmax(key));
		if (!fn_state_get("perms", key, val, charsmax(val)))
			continue;
		new profile, expiry, nodes;
		parseGrant(val, profile, expiry, nodes);
		#pragma unused nodes
		if (!grantValid(expiry))
			continue;
		if (profile > best)
			best = profile;
	}
	return best;
}

public _nodes(plugin, params)
{
	new id = get_param(1);
	if (id < 1 || id > MaxClients || !is_user_connected(id))
		return 0;
	new auth[32];
	if (!authOf(id, auth, charsmax(auth)))
		return 0;
	if (!LibraryExists("fn_state", LibType_Library))
		return 0;
	new mask = 0;
	new key[96], val[96];
	for (new s = 0; s < 3; s++)
	{
		if (s == 1)
			continue;
		grantKey(auth, s, key, charsmax(key));
		if (!fn_state_get("perms", key, val, charsmax(val)))
			continue;
		new profile, expiry, nodes;
		parseGrant(val, profile, expiry, nodes);
		#pragma unused profile
		if (!grantValid(expiry))
			continue;
		mask |= nodes;
	}
	return mask;
}
