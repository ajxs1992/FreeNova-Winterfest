#if defined _amx_banpersist_included
	#endinput
#endif
#define _amx_banpersist_included

native amx_persist_ban_player(admin, player, minutes, const reason[] = "");
native amx_persist_unban(const ident[]);
native amx_persist_add(admin, const ident[], minutes, const reason[] = "");
