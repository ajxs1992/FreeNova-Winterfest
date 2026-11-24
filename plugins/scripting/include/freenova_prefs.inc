#if defined _freenova_prefs_included
    #endinput
#endif
#define _freenova_prefs_included

// FreeNova Preferences - persistent per-player settings (freenova_prefs.amxx)
//
// Preference slots (see freenova_prefs.sma):
//   FNPREF_RANK_HUD    1 = rank HUD visible (default ON)
//   FNPREF_DAMAGE_HUD  1 = bullet damage numbers visible (default ON)
//   FNPREF_COMPACT_MENUS 1 = short hub menu labels (default OFF)
//   FNPREF_LANG        0 = English (en), 1 = Romanian (ro) (default EN)
//   FNPREF_LOW_PERF    1 = Low Performance Mode: skip rich MOTDs and use the
//                          plugin's native in-game fallback (default OFF)

#define FNPREF_RANK_HUD     0
#define FNPREF_DAMAGE_HUD   1
#define FNPREF_COMPACT_MENUS 2
#define FNPREF_LANG         3
#define FNPREF_LOW_PERF     4

// Language values for FNPREF_LANG (2-letter codes: "en" default, "ro" Romanian)
#define FNPREF_LANG_EN      0
#define FNPREF_LANG_RO      1

// Returns 1 if the preference is enabled, 0 otherwise (also 0 when unloaded).
native fnpref_get(id, iPref);

// Sets a preference (0/1) and persists it immediately. Returns 1 on success.
native fnpref_set(id, iPref, iValue);

// 1 when the player's preferences have been loaded from storage.
native fnpref_is_loaded(id);

// Language helpers: 2-letter code ("en"/"ro") <-> FNPREF_LANG slot value.
// Unknown codes fall back to English ("en").
stock fnpref_get_lang(id, szCode[], iLen)
{
    if (fnpref_get(id, FNPREF_LANG) == FNPREF_LANG_RO)
        copy(szCode, iLen, "ro")
    else
        copy(szCode, iLen, "en")
    return 1
}

stock fnpref_set_lang(id, const szCode[])
{
    return fnpref_set(id, FNPREF_LANG, equali(szCode, "ro") ? FNPREF_LANG_RO : FNPREF_LANG_EN)
}
