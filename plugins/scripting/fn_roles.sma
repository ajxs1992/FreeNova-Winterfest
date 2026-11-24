/* fn_roles: runtime role management over fn_core state. Menus, lists, trial defaults.
 * users.ini and file accounts remain the compat floor; this module grants online roles. */
#include <amxmodx>
#include <amxmisc>
#include <fn_core>
#include <fn_common>

public plugin_natives()
{
	set_native_filter("native_filter");
	register_library("fn_roles");
}

public native_filter(const name[], index, trap)
{
	if (!trap && contain(name, "fn_") == 0)
		return PLUGIN_HANDLED;
	return PLUGIN_CONTINUE;
}

public plugin_init()
{
	fn_boot_banner("roles", 4);

	register_plugin("FreeNova Roles", "2.0.0", "FreeNova");
	register_concmd("fn_role_grant", "cmdGrant", ADMIN_RCON, "<name|#id> <1=admin|2=mod|3=vip> <minutes,0=perm>");
	register_concmd("fn_role_revoke", "cmdRevoke", ADMIN_RCON, "<name|#id>");
	register_concmd("fn_roles", "cmdList", ADMIN_ADMIN, "- list online staff roles");
	register_clcmd("fn_rolemenu", "cmdMenu", ADMIN_RCON, "- role management menu");
	if( !LibraryExists("fn_core", LibType_Library) )
	{
		log_amx("[FN-ROLES] fn_core missing, pausing self");
		pause("d");
		return;
	}
	fn_health_set("roles", "ok");
}

findTarget(id, const arg[], &target)
{
	if (id == 0)
	{
		target = fn_resolve_target(arg, id);
	}
	else
	{
		target = cmd_target(id, arg, CMDTARGET_ALLOW_SELF);
	}
	if( !target )
	{
		if (id == 0)
		{
			new hits[8], nm2[MAX_NAME_LENGTH];
			new nh = fn_resolve_list(arg, hits, 8, id);
			if (nh > 1)
			{
				console_print(id, "[FN] %d players match, be more specific:", nh);
				for (new si = 0; si < nh && si < 8; si++)
				{
					get_user_name(hits[si], nm2, charsmax(nm2));
					console_print(id, "  %s", nm2);
				}
			}
			else console_print(id, "[FN] no such player");
		}
		else console_print(id, "[FN] no such player");
		return 0;
	}
	return 1;
}

public cmdGrant(id, level, cid)
{
	if( !cmd_access(id, level, cid, 4) ) return PLUGIN_HANDLED;
	new arg1[32], arg2[8], arg3[12];
	read_argv(1, arg1, charsmax(arg1));
	read_argv(2, arg2, charsmax(arg2));
	read_argv(3, arg3, charsmax(arg3));
	new target;
	if( !findTarget(id, arg1, target) ) return PLUGIN_HANDLED;
	new role = str_to_num(arg2);
	new mins = str_to_num(arg3);
	if( role < FN_ROLE_ADMIN || role > FN_ROLE_VIP )
	{
		console_print(id, "[FN] role must be 1, 2 or 3");
		return PLUGIN_HANDLED;
	}
	if( fn_role_grant(id, target, role, mins) )
	{
		new lbl[96];
		fn_player_label(target, lbl, charsmax(lbl));
		console_print(id, "[FN] granted role %d to %s for %d min", role, lbl, mins);
		fn_safe_audit("", id, target, "role.grant", lbl);
	}
	else console_print(id, "[FN] grant denied (hierarchy or invalid target)");
	return PLUGIN_HANDLED;
}

public cmdRevoke(id, level, cid)
{
	if( !cmd_access(id, level, cid, 2) ) return PLUGIN_HANDLED;
	new arg1[64];
	read_argv(1, arg1, charsmax(arg1));
	new target;
	if( findTarget(id, arg1, target) )
	{
		if( fn_role_revoke(id, target) )
			console_print(id, "[FN] role revoked");
		else console_print(id, "[FN] revoke denied");
	}
	return PLUGIN_HANDLED;
}

public cmdList(id, level, cid)
{
	if( !cmd_access(id, level, cid, 1) ) return PLUGIN_HANDLED;
	new players[32], num;
	get_players(players, num);
	console_print(id, "[FN] online staff:");
	for( new i = 0; i < num; i++ )
	{
		new r = fn_role_get(players[i]);
		if( r == FN_ROLE_NONE ) continue;
		new lbl[96];
		fn_player_label(players[i], lbl, charsmax(lbl));
		new left = fn_role_expiry(players[i]);
		if( left >= 0 )
			console_print(id, "  role=%d %s (%ds left)", r, lbl, left);
		else
			console_print(id, "  role=%d %s (no expiry)", r, lbl);
	}
	return PLUGIN_HANDLED;
}

public cmdMenu(id, level, cid)
{
	if( !cmd_access(id, level, cid, 1) ) return PLUGIN_HANDLED;
	new menu = menu_create("\yFreeNova Roles", "menuH");
	menu_additem(menu, "Grant Moderator (60 min)", "g2");
	menu_additem(menu, "Grant VIP (1440 min)", "g3");
	menu_additem(menu, "List staff", "l");
	menu_display(id, menu);
	return PLUGIN_HANDLED;
}

public menuH(id, menu, item)
{
	if( item == MENU_EXIT ) { menu_destroy(menu); return PLUGIN_HANDLED; }
	new info[8];
	menu_item_getinfo(menu, item, _, info, charsmax(info));
	if( equal(info, "l") ) cmdList(id, ADMIN_ADMIN, 0);
	else console_print(id, "[FN] use fn_role_grant <player> <role> <mins>");
	menu_destroy(menu);
	return PLUGIN_HANDLED;
}