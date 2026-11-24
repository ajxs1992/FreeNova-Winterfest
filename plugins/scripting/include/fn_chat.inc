#if defined _fn_chat_included
	#endinput
#endif
#define _fn_chat_included

/* fn_chat policy (library fn_chat, 3.0 M3). Authoritative gag verdict for
 * every chat emitter: 0 drop, 1 speak. Emitters call it guarded
 * (LibraryExists) with a direct gag check as fallback. Hook order contract:
 * gag -> flood -> emitters (preset order + validate.ps1). */
native fn_chat_can_speak(id);
native fn_chat_denied();
