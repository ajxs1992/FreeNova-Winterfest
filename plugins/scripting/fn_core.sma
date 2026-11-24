/* FreeNova Core v2 (fn_core). Evolved from BASE amx_core.sma - all v1 natives kept as shims.
 * Acyclic root: identity, roles, config read, audit append, health registry, one forward.
 * Closed-by-default: unknown state protects, never grants. */
#include <amxmodx>
#include <amxmisc>
#include <fn_common>

#define CORE_VERSION 200
#define FN_ROLE_NONE 0
#define FN_ROLE_ADMIN 1
#define FN_ROLE_MOD 2
#define FN_ROLE_VIP 3

new Trie:g_role;
new Trie:g_expire;new Array:g_expList;
new Trie:g_health;
new g_fwdAuth;
new g_fwdRole;

public plugin_natives()
{
	register_library("fn_core");
	register_library("amx_core");
	register_native("fn_core_version", "_core_version");
	register_native("fn_log_action", "_log_action");
	register_native("fn_player_label", "_player_label");
	register_native("fn_is_protected", "_is_protected");
	register_native("fn_has_role", "_has_role");
	register_native("fn_role_get", "_role_get");
	register_native("fn_role_grant", "_role_grant");
	register_native("fn_role_revoke", "_role_revoke");
	register_native("fn_role_revoke_key", "_role_revoke_key");
	register_native("fn_role_expiry", "_role_expiry");
	register_native("fn_cfg_get", "_cfg_get");
	register_native("fn_audit_append", "_audit_append");
	register_native("fn_health_set", "_health_set");
	register_native("fn_health_get", "_health_get");
	register_native("amx_log_action", "_log_action");
	register_native("amx_player_label", "_player_label");
	register_native("amx_is_protected", "_is_protected");
}

public plugin_init()
{
	fn_boot_banner("core", 21);

	register_plugin("FreeNova Core", "2.0.0", "FreeNova");
	register_cvar("fn_core_version", "2.0.0");
	register_cvar("fn_server_id", "fn-01"); /* override per server (M2 journal identity) */
	g_role = TrieCreate();
	g_expire = TrieCreate(); g_expList = ArrayCreate(35);
	g_health = TrieCreate();
	g_fwdAuth = CreateMultiForward("fn_client_authorized", ET_IGNORE, FP_CELL, FP_STRING, FP_STRING);
	g_fwdRole = CreateMultiForward("fn_role_changed", ET_IGNORE, FP_CELL, FP_CELL, FP_CELL, FP_CELL, FP_STRING);
	set_task(60.0, "task_SweepExpiry", _, _, _, "b");
	fn_health_set_impl("core", "ok");
}

public plugin_end()
{
	TrieDestroy(g_role);
	TrieDestroy(g_expire); ArrayDestroy(g_expList);
	TrieDestroy(g_health);
	DestroyForward(g_fwdAuth);
	DestroyForward(g_fwdRole);
}

public client_authorized(id)
{
	if( is_user_bot(id) || is_user_hltv(id) ) return;
	new auth[35], ip[32];
	get_user_authid(id, auth, charsmax(auth));
	get_user_ip(id, ip, charsmax(ip), 1);
	new ret;
	ExecuteForward(g_fwdAuth, ret, id, auth, ip);
}

public task_SweepExpiry()
{
	new now = get_systime();
	static key[35];
	for( new i = ArraySize(g_expList) - 1; i >= 0; i-- )
	{
		ArrayGetString(g_expList, i, key, charsmax(key));
		new until = 0;
		TrieGetCell(g_expire, key, until);
		if( until > 0 && until <= now )
		{
			TrieDeleteKey(g_expire, key);
			TrieDeleteKey(g_role, key);
			ArrayDeleteItem(g_expList, i);
			log_amx("[FN] role expired for %s", key);
		}
		else if( until == 0 )
		{
			ArrayDeleteItem(g_expList, i);
		}
	}
}

expTrack(const key[])
{
	static cur[35];
	for( new i = 0; i < ArraySize(g_expList); i++ )
	{
		ArrayGetString(g_expList, i, cur, charsmax(cur));
		if( equal(cur, key) ) return;
	}
	ArrayPushString(g_expList, key);
}


/* identity key: authid when usable, else ip */
keyFor(id, out[], len)
{
	get_user_authid(id, out, len);
	if( !IsUsableKey(out) )
		get_user_ip(id, out, len, 1);
}
bool:IsUsableKey(const k[])
{
	if( !k[0] ) return false;
	if( equal(k, "STEAM_ID_PENDING") || equal(k, "STEAM_ID_LAN") ) return false;
	if( equali(k, "VALVE_ID_LAN") ) return false;
	return true;
}

roleFlags(id)
{
	new f = get_user_flags(id);
	if( f & ADMIN_RCON ) return FN_ROLE_ADMIN;
	if( f & ADMIN_BAN ) return FN_ROLE_MOD;
	if( f != 0 ) return FN_ROLE_VIP;
	return FN_ROLE_NONE;
}

resolveRole(const key[], id)
{
	new r = FN_ROLE_NONE;
	if( TrieGetCell(g_role, key, r) )
	{
		new until = 0;
		TrieGetCell(g_expire, key, until);
		if( until > 0 && until <= get_systime() )
		{
			TrieDeleteKey(g_role, key);
			TrieDeleteKey(g_expire, key);
			r = FN_ROLE_NONE;
		}
		else return r;
	}
	if( id > 0 && is_user_connected(id) )
		return roleFlags(id);
	return FN_ROLE_NONE;
}

public _core_version(plugin, params) { return CORE_VERSION; }

public _log_action(plugin, params)
{
	/* ORDER FOLLOWS native fn_audit_append(case_id, admin, target, action, detail) */
	new admin = get_param(1);
	new target = get_param(2);
	new action[64], extra[128];
	get_string(3, action, charsmax(action));
	get_string(4, extra, charsmax(extra));
	new aname[32], aauth[35], tname[32], tauth[35], map[32];
	if( admin > 0 && is_user_connected(admin) )
	{
		get_user_name(admin, aname, charsmax(aname));
		get_user_authid(admin, aauth, charsmax(aauth));
	}
	else { copy(aname, 31, "CONSOLE"); copy(aauth, 34, "SERVER"); }
	if( target > 0 && is_user_connected(target) )
	{
		get_user_name(target, tname, charsmax(tname));
		get_user_authid(target, tauth, charsmax(tauth));
	}
	else { copy(tname, 31, "-"); copy(tauth, 34, "-"); }
	get_mapname(map, charsmax(map));
	stripNL(action, charsmax(action));
	stripNL(extra, charsmax(extra));
	stripNL(aname, charsmax(aname));
	stripNL(tname, charsmax(tname));
	log_amx("[%s] %s<%s> %s %s<%s> %s", map, aname, aauth, action, tname, tauth, extra);
	return 1;
}

playerLabel(id, out[], len)
{
	if( id < 1 || id > 32 || !is_user_connected(id) )
	{
		copy(out, len, "id=?");
		return 0;
	}
	new name[32], auth[35];
	get_user_name(id, name, charsmax(name));
	get_user_authid(id, auth, charsmax(auth));
	stripNL(name, charsmax(name));
	formatex(out, len, "%s<%s>", name, auth);
	return 1;
}
public _player_label(plugin, params)
{
	new id = get_param(1);
	new outlen = get_param(3);
	if( id < 1 || id > 32 || !is_user_connected(id) )
	{
		set_string(2, "id=?", outlen);
		return 0;
	}
	new name[32], auth[35];
	get_user_name(id, name, charsmax(name));
	get_user_authid(id, auth, charsmax(auth));
	stripNL(name, charsmax(name));
	new buf[96];
	formatex(buf, charsmax(buf), "%s<%s>", name, auth);
	set_string(2, buf, outlen);
	return 1;
}

public _is_protected(plugin, params)
{
	new id = get_param(1);
	if( id < 1 || id > 32 || !is_user_connected(id) ) return 1;
	new key[35];
	keyFor(id, key, charsmax(key));
	new r = resolveRole(key, id);
	return (r == FN_ROLE_ADMIN) ? 1 : 0;
}

public _has_role(plugin, params)
{
	new id = get_param(1);
	new role = get_param(2);
	if( id < 1 || id > 32 || !is_user_connected(id) ) return 0;
	if( role < FN_ROLE_ADMIN || role > FN_ROLE_VIP ) return 0;
	new key[35];
	keyFor(id, key, charsmax(key));
	new got = resolveRole(key, id);
	if( got == FN_ROLE_NONE ) return 0;
	return (got <= role) ? 1 : 0;
}

public _role_get(plugin, params)
{
	new id = get_param(1);
	if( id < 1 || id > 32 || !is_user_connected(id) ) return FN_ROLE_NONE;
	new key[35];
	keyFor(id, key, charsmax(key));
	return resolveRole(key, id);
}

public _role_grant(plugin, params)
{
	/* ORDER FOLLOWS native fn_audit_append(case_id, admin, target, action, detail) */
	new admin = get_param(1);
	new target = get_param(2);
	new role = get_param(3);
	new minutes = get_param(4);
	if( role < FN_ROLE_ADMIN || role > FN_ROLE_VIP ) return 0;
	if( target < 1 || target > 32 || !is_user_connected(target) ) return 0;
	if( minutes < 0 ) return 0;
	if( admin > 0 )
	{
		if( !is_user_connected(admin) ) return 0;
		new akey[35];
		keyFor(admin, akey, charsmax(akey));
		new arole = resolveRole(akey, admin);
		if( arole == FN_ROLE_NONE || arole >= role ) return 0;
		new tkey0[35];
		keyFor(target, tkey0, charsmax(tkey0));
		new trole = resolveRole(tkey0, target);
		if( trole != FN_ROLE_NONE && trole <= arole ) return 0;
	}
	new key[35];
	keyFor(target, key, charsmax(key));
	TrieSetCell(g_role, key, role);
	if( minutes > 0 )
	{
		TrieSetCell(g_expire, key, get_systime() + minutes * 60);
		expTrack(key);
	}
	else
		TrieDeleteKey(g_expire, key);
	new ret;
	ExecuteForward(g_fwdRole, ret, admin, target, FN_ROLE_NONE, role, "");
	new lbl[96];
	playerLabel(target, lbl, charsmax(lbl));
	log_amx("[FN] role grant r=%d mins=%d to %s", role, minutes, lbl);
	return 1;
}

public _role_revoke(plugin, params)
{
	/* ORDER FOLLOWS native fn_audit_append(case_id, admin, target, action, detail) */
	new admin = get_param(1);
	new target = get_param(2);
	new key[35];
	if( target >= 1 && target <= 32 && is_user_connected(target) )
		keyFor(target, key, charsmax(key));
	else return 0; // keys go through fn_role_revoke_key
	if( !key[0] ) return 0;
	if( admin > 0 && is_user_connected(admin) )
	{
		new akey[35];
		keyFor(admin, akey, charsmax(akey));
		new arole = resolveRole(akey, admin);
		new trole = FN_ROLE_NONE;
		TrieGetCell(g_role, key, trole);
		if( arole == FN_ROLE_NONE || (trole != FN_ROLE_NONE && trole <= arole) ) return 0;
	}
	new old = FN_ROLE_NONE;
	TrieGetCell(g_role, key, old);
	TrieDeleteKey(g_role, key);
	TrieDeleteKey(g_expire, key);
	new ret;
	ExecuteForward(g_fwdRole, ret, admin, target, old, FN_ROLE_NONE, "");
	log_amx("[FN] role revoke %s (was %d)", key, old);
	return 1;
}

public _role_revoke_key(plugin, params)
{
	/* ORDER FOLLOWS native fn_audit_append(case_id, admin, target, action, detail) */
	new admin = get_param(1);
	new key[35];
	get_string(2, key, charsmax(key));
	if (!key[0]) return 0;
	if (admin > 0 && is_user_connected(admin))
	{
		new akey[35];
		keyFor(admin, akey, charsmax(akey));
		new arole = resolveRole(akey, admin);
		new trole = FN_ROLE_NONE;
		TrieGetCell(g_role, key, trole);
		if (arole == FN_ROLE_NONE) return 0;
		if (trole != FN_ROLE_NONE && trole <= arole) return 0;
	}
	TrieDeleteKey(g_role, key);
	TrieDeleteKey(g_expire, key);
	log_amx("[FN] role revoke-key %s", key);
	return 1;
}

public _role_expiry(plugin, params)
{
	new id = get_param(1);
	if( id < 1 || id > 32 || !is_user_connected(id) ) return -2;
	new key[35];
	keyFor(id, key, charsmax(key));
	new until = 0;
	if( !TrieGetCell(g_expire, key, until) ) return -1;
	if( until <= 0 ) return -1;
	new left = until - get_systime();
	return (left > 0) ? left : 0;
}

public _cfg_get(plugin, params)
{
	new key[64], outlen = get_param(3);
	get_string(1, key, charsmax(key));
	if( !key[0] ) { set_string(2, "", outlen); return 0; }
	new val[256];
	get_cvar_string(key, val, charsmax(val));
	set_string(2, val, outlen);
	return val[0] ? 1 : 0;
}

public _audit_append(plugin, params)
{
	/* ORDER FOLLOWS native fn_audit_append(case_id, admin, target, action, detail) */
	new case_id[24], action[64], detail[192];
	new admin = get_param(2);
	new target = get_param(3);
	get_string(1, case_id, charsmax(case_id));
	get_string(4, action, charsmax(action));
	get_string(5, detail, charsmax(detail));
	stripNL(case_id, charsmax(case_id));
	stripNL(action, charsmax(action));
	stripNL(detail, charsmax(detail));
	new albl[96], tlbl[96];
	playerLabel(admin, albl, charsmax(albl));
	playerLabel(target, tlbl, charsmax(tlbl));
	log_amx("[FN-AUDIT] case=%s admin=%s target=%s action=%s %s", case_id, albl, tlbl, action, detail);
	return 1;
}

fn_health_set_impl(const module[], const status[])
{
	static s[64];
	copy(s, charsmax(s), status);
	TrieSetString(g_health, module, s);
}

public _health_set(plugin, params)
{
	new module[32], status[64];
	get_string(1, module, charsmax(module));
	get_string(2, status, charsmax(status));
	if( !module[0] ) return 0;
	fn_health_set_impl(module, status);
	return 1;
}

public _health_get(plugin, params)
{
	new module[32], outlen = get_param(3);
	get_string(1, module, charsmax(module));
	static s[64];
	s[0] = 0;
	if( module[0] && TrieGetString(g_health, module, s, charsmax(s)) )
	{
		set_string(2, s, outlen);
		return 1;
	}
	set_string(2, "unknown", outlen);
	return 0;
}

stripNL(buf[], len)
{
	replace_all(buf, len, "^n", " ");
	replace_all(buf, len, "^r", " ");
}