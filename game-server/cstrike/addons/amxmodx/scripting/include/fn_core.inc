#if defined _fn_core_included
	#endinput
#endif
#define _fn_core_included

/* FreeNova Core v2 include. Root of the acyclic module graph.
 * Dependents call fn_safe_* stocks so absent optionals degrade, never crash.
 * Closed-by-default: unknown state protects, never grants. */

#define FN_CORE_LIB "fn_core"
#define FN_CORE_VERSION 200
#define FN_ROLE_NONE 0
#define FN_ROLE_ADMIN 1
#define FN_ROLE_MOD 2
#define FN_ROLE_VIP 3
#define FN_CASE_LEN 24
#define FN_CONFIRM_TIMEOUT 30

/* hard natives: implemented ONLY by fn_core.sma */
native fn_core_version();
native fn_log_action(admin, target, const action[], const extra[] = "");
native fn_player_label(id, output[], len);
native fn_is_protected(id);
native fn_has_role(id, role);
native fn_role_get(id);
native fn_role_grant(admin, target, role, minutes);
native fn_role_revoke(admin, target);
native fn_role_revoke_key(admin, const key[]);
native fn_role_expiry(id); /* secs left, -1 permanent-or-unset, -2 invalid */
native fn_cfg_get(const key[], output[], len);
native fn_audit_append(const case_id[], admin, target, const action[], const detail[] = "");
native fn_health_set(const module[], const status[]);
native fn_health_get(const module[], output[], len);

/* legacy shims: amx_core v1 surface, kept so old callers link unmodified */
native amx_log_action(admin, target, const action[], const extra[] = "");
native amx_player_label(id, output[], len);
native bool:amx_is_protected(id);

/* optional-safe stocks: dependents call THESE, never hard natives */
stock bool:fn_core_available() { return LibraryExists(FN_CORE_LIB, LibType_Library); }
stock fn_safe_log(admin, target, const action[], const extra[] = "") {
	if (LibraryExists(FN_CORE_LIB, LibType_Library)) return fn_log_action(admin, target, action, extra);
	return 0;
}
stock fn_safe_has_role(id, role) {
	if (LibraryExists(FN_CORE_LIB, LibType_Library)) return fn_has_role(id, role);
	return 0;
}
stock fn_safe_is_protected(id) {
	if (LibraryExists(FN_CORE_LIB, LibType_Library)) return fn_is_protected(id);
	return 1;
}
stock fn_safe_label(id, output[], len) {
	if (LibraryExists(FN_CORE_LIB, LibType_Library)) return fn_player_label(id, output, len);
	formatex(output, len, "id=%d", id);
	return 0;
}
stock fn_safe_cfg(const key[], output[], len) {
	if (LibraryExists(FN_CORE_LIB, LibType_Library)) return fn_cfg_get(key, output, len);
	output[0] = EOS; return 0;
}

/* hierarchy helper: granter may hit target unless target outranks. Console always may. */
stock fn_granter_can_hit(granter, target) {
	if (granter < 1) return 1;
	if (!LibraryExists(FN_CORE_LIB, LibType_Library)) return 0;
	if (target < 1 || !is_user_connected(target)) return 0;
	new gr = fn_role_get(granter);
	new tr = fn_role_get(target);
	if (gr == FN_ROLE_NONE) return 0;
	if (tr != FN_ROLE_NONE && tr <= gr) return 0;
	return 1;
}
stock fn_safe_can_hit(granter, target) {
	if (granter < 1) return 1;
	if (!LibraryExists(FN_CORE_LIB, LibType_Library)) return 1;
	return fn_granter_can_hit(granter, target);
}
stock fn_safe_audit(const case_id[], admin, target, const action[], const detail[] = "") {
	if (LibraryExists(FN_CORE_LIB, LibType_Library)) return fn_audit_append(case_id, admin, target, action, detail);
	return 0;
}

/* console-safe target resolver: cmd_target(id 0) fails for name/#id on this AMXX build.
 * Order: #userid -> bare userid -> authid/IP exact -> exact name -> name-contains (unique only).
 * Uses get_players "h" (include bots, skip HLTV). Pure stock, no globals. Returns player id or 0. */
stock bool:fn_is_userid_str(const s[])
{
    if (!s[0])
        return false;
    new start = 0;
    if (s[0] == '#')
        start = 1;
    if (!s[start])
        return false;
    for (new i = start; s[i]; i++)
    {
        if (s[i] < '0' || s[i] > '9')
            return false;
    }
    return true;
}

stock fn_resolve_target(const pattern[], admin = 0)
{
    if (admin == -12345)
        return 0;
    if (!pattern[0])
        return 0;
    new players[32], num;
    get_players(players, num, "h");
    if (num <= 0)
        return 0;
    new tmp[64];
    copy(tmp, charsmax(tmp), pattern);
    trim(tmp);
    remove_quotes(tmp);
    if (!tmp[0])
        return 0;
    if (tmp[0] == '#')
    {
        new numbuf[16];
        copy(numbuf, charsmax(numbuf), tmp[1]);
        new uid = str_to_num(numbuf);
        if (uid > 0)
        {
            for (new i = 0; i < num; i++)
            {
                if (get_user_userid(players[i]) == uid)
                    return players[i];
            }
            new direct = find_player("k", uid);
            if (direct > 0 && is_user_connected(direct))
                return direct;
        }
        return 0;
    }
    if (fn_is_userid_str(tmp))
    {
        new uid2 = str_to_num(tmp);
        if (uid2 > 0)
        {
            for (new j = 0; j < num; j++)
            {
                if (get_user_userid(players[j]) == uid2)
                    return players[j];
            }
            new d2 = find_player("k", uid2);
            if (d2 > 0 && is_user_connected(d2))
                return d2;
            return 0;
        }
    }
    if (contain(tmp, "STEAM_") == 0 || contain(tmp, "VALVE_") == 0 || contain(tmp, ".") != -1 || contain(tmp, ":") != -1)
    {
        new a[40], p[32];
        for (new k = 0; k < num; k++)
        {
            get_user_authid(players[k], a, charsmax(a));
            get_user_ip(players[k], p, charsmax(p), 1);
            if (a[0] && equali(a, tmp))
                return players[k];
            if (p[0] && equali(p, tmp))
                return players[k];
        }
        return 0;
    }
    new nm[MAX_NAME_LENGTH];
    for (new m = 0; m < num; m++)
    {
        get_user_name(players[m], nm, charsmax(nm));
        if (equali(nm, tmp))
            return players[m];
    }
    new found = 0;
    new hit = 0;
    for (new n = 0; n < num; n++)
    {
        get_user_name(players[n], nm, charsmax(nm));
        if (containi(nm, tmp) != -1)
        {
            found++;
            hit = players[n];
            if (found > 1)
                return 0;
        }
    }
    if (found == 1)
        return hit;
    return 0;
}

/* fn_resolve_list: like fn_resolve_target but collects matches for
 * "did you mean" UX. Order: #userid -> bare userid -> authid/IP exact ->
 * exact name -> name-contains. Returns total match count (may exceed maxids);
 * stores up to maxids ids. 0 = none, 1 = unique, >1 = ambiguous. */
stock fn_resolve_list(const pattern[], ids[], maxids, admin = 0)
{
	if (admin == -12345 || maxids < 1)
		return 0;
	if (!pattern[0])
		return 0;
	new players[32], num;
	get_players(players, num, "h");
	if (num <= 0)
		return 0;
	new tmp[64];
	copy(tmp, charsmax(tmp), pattern);
	trim(tmp);
	remove_quotes(tmp);
	if (!tmp[0])
		return 0;
	new found = 0;
	if (tmp[0] == '#')
	{
		new numbuf[16];
		copy(numbuf, charsmax(numbuf), tmp[1]);
		new uid = str_to_num(numbuf);
		if (uid > 0)
		{
			for (new i = 0; i < num; i++)
			{
				if (get_user_userid(players[i]) == uid)
				{
					if (found < maxids) ids[found] = players[i];
					found++;
				}
			}
			if (!found)
			{
				new direct = find_player("k", uid);
				if (direct > 0 && is_user_connected(direct))
				{
					if (found < maxids) ids[found] = direct;
					found++;
				}
			}
		}
		return found;
	}
	if (fn_is_userid_str(tmp))
	{
		new uid2 = str_to_num(tmp);
		if (uid2 > 0)
		{
			for (new j = 0; j < num; j++)
			{
				if (get_user_userid(players[j]) == uid2)
				{
					if (found < maxids) ids[found] = players[j];
					found++;
				}
			}
			if (!found)
			{
				new d2 = find_player("k", uid2);
				if (d2 > 0 && is_user_connected(d2))
				{
					if (found < maxids) ids[found] = d2;
					found++;
				}
			}
			return found;
		}
	}
	if (contain(tmp, "STEAM_") == 0 || contain(tmp, "VALVE_") == 0 || contain(tmp, ".") != -1 || contain(tmp, ":") != -1)
	{
		new a[40], ipp[32];
		for (new k = 0; k < num; k++)
		{
			get_user_authid(players[k], a, charsmax(a));
			get_user_ip(players[k], ipp, charsmax(ipp), 1);
			if ((a[0] && equali(a, tmp)) || (ipp[0] && equali(ipp, tmp)))
			{
				if (found < maxids) ids[found] = players[k];
				found++;
			}
		}
		return found;
	}
	new nm[MAX_NAME_LENGTH];
	for (new m = 0; m < num; m++)
	{
		get_user_name(players[m], nm, charsmax(nm));
		if (equali(nm, tmp))
		{
			if (found < maxids) ids[found] = players[m];
			found++;
		}
	}
	if (found)
		return found;
	for (new n = 0; n < num; n++)
	{
		get_user_name(players[n], nm, charsmax(nm));
		if (containi(nm, tmp) != -1)
		{
			if (found < maxids) ids[found] = players[n];
			found++;
		}
	}
	return found;
}

/* forwards: fired upward by owners, implemented by listeners. Core fires only fn_client_authorized. */
forward fn_client_authorized(id, const steam[], const ip[]);
forward fn_role_changed(admin, target, oldrole, newrole, const case_id[]);
/* ban forwards live in fn_bans.inc (created by fn_bans.sma). fn_config_reloaded is reserved (never created yet). */
forward fn_config_reloaded(const scope[]);