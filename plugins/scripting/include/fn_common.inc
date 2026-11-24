// include/fn_common.inc
//
// The one thing every FreeNova plugin shares without depending on fn_core: a
// uniform boot line.
//
// Why: this stack is 67 plugins and a plugin that failed to initialise used to
// be invisible. Some print their own line, some print nothing, some pause
// themselves on a missing library and say so only in the AMXX log. After an
// upload nobody could answer "are the new binaries actually live?" without
// reading 67 plugin versions out of `amx_plugins`.
//
// With this, one console read does it:
//
//     [FreeNova audit] ready (build 3, 7 features)
//     [FreeNova ads] ready (build 3, 9 features)
//
// and a plugin that is loaded but silent did not reach its plugin_init.
// Bump FN_BUILD once per deployment round and every line moves together.
//
// Deliberately dependency-free: it calls only stock AMXX natives, so it prints
// even when fn_core is missing - which is exactly the failure it exists to make
// visible.
//
// "features" is the size of the plugin's registered surface: the number of
// register_concmd / register_clcmd / register_srvcmd / register_cvar /
// register_native / CreateNative / register_event / register_forward /
// RegisterHam / CreateMultiForward / register_menucmd / register_message calls
// in its source at the time it was stamped. It is a literal, not a runtime
// measurement: if you add commands to a plugin, bump the number in its banner
// call so the console keeps telling the truth.

#if defined _fn_common_included
	#endinput
#endif

#define _fn_common_included

// The deployment round this source tree was built for. Every fn_*/freenova_*
// plugin prints it, so a half-finished upload is visible immediately.
#define FN_BUILD 3

stock fn_boot_banner(const name[], features)
{
	server_print("[FreeNova %s] ready (build %d, %d features)", name, FN_BUILD, features)
}
