#if defined _freenova_wpn_included
    #endinput
#endif
#define _freenova_wpn_included

// FreeNova Weapon Stats (freenova_weaponstats.amxx)
// Persistent per-weapon kills / headshots / damage (23 tracked weapons).
// Weapon slots (stable - do not reorder):
#define FNWPS_AK47      0
#define FNWPS_M4A1      1
#define FNWPS_AWP       2
#define FNWPS_DEAGLE    3
#define FNWPS_KNIFE     4
#define FNWPS_USP       5
#define FNWPS_GLOCK18   6
#define FNWPS_FAMAS     7
#define FNWPS_GALIL     8
#define FNWPS_SCOUT     9
#define FNWPS_AUG       10
#define FNWPS_SG552     11
#define FNWPS_MP5NAVY   12
#define FNWPS_P90       13
#define FNWPS_UMP45     14
#define FNWPS_MAC10     15
#define FNWPS_TMP       16
#define FNWPS_M249      17
#define FNWPS_M3        18
#define FNWPS_XM1014    19
#define FNWPS_SG550     20
#define FNWPS_G3SG1     21
#define FNWPS_HEGRENADE 22

// Kills/headshots/damage recorded for a weapon slot (-safe when unloaded)
native fnwps_get_kills(id, iWeaponSlot);
native fnwps_get_headshots(id, iWeaponSlot);
native fnwps_get_damage(id, iWeaponSlot);

// Slot of the player's most-killed weapon, or -1 when unknown
native fnwps_get_best_weapon(id);

// Fills the display name of a weapon slot ("AK-47", "HE Grenade", ...)
native fnwps_get_weapon_name(iWeaponSlot, buffer[], len);
