// FreeNova help registry API (M13).
//
// Implemented by freenova_help.sma (library "freenova_help").
// Other plugins call fn_help_register() to enroll their commands so
// amx_cmdhelp / amx_searchcmd / amx_helpmenu cover them. Calls are safe
// only when the help plugin is running — check LibraryExists first.

#if defined _freenova_help_included
    #endinput
#endif
#define _freenova_help_included

// Enroll one command. Category is a short group name, e.g. "Moderation".
// Returns 1 on success, 0 when the registry is full.
native fn_help_register(const cmd[], const syntax[], const desc[],
    const example[], const perm[], const cat[]);
