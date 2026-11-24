#if defined _freenova_achievements_included
	#endinput
#endif
#define _freenova_achievements_included

#define ACH_KILLS_100      0
#define ACH_KILLS_1000     1
#define ACH_KILLS_5000     2
#define ACH_HS_100         3
#define ACH_HEADS_500      4
#define ACH_PLANTS_50      5
#define ACH_DEFUSES_25     6
#define ACH_WINS_100       7
#define ACH_LEVEL_26       8
#define ACH_LEVEL_52       9
#define ACH_PRESTIGE_1     10
#define ACH_STREAK_10      11
#define ACH_COINS_10000    12
#define ACH_REVIVER        13
#define ACH_COUNT          14
#define ACH_VISIBLE_COUNT  13
#define ACH_COIN_REWARD    250
#define ACH_XP_REWARD      250

/**
 * Raw achievement bitfield (all 14 bits, including hidden ACH_PRESTIGE_1).
 */
native fnach_get_unlocked(id);

/**
 * Visible unlock count (excludes hidden prestige unless unlocked and counted separately — prestige is omitted).
 */
native fnach_get_count(id);

/**
 * Lifetime helper counters.
 * which: 0 kills, 1 hs, 2 plants, 3 defuses, 4 wins, 5 revives, 6 streak best.
 */
native fnach_get_stat(id, which);

/**
 * Opens the local achievements VGUI.
 */
native fnach_show(id);

/**
 * Bridge from revive_bridge: one successful revive.
 */
native fnach_note_revive(id);

/**
 * 1 if this session successfully loaded (or initialized) the ach# vault blob.
 */
native fnach_is_loaded(id);
