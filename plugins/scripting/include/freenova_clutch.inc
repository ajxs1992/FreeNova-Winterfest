#if defined _freenova_clutch_included
    #endinput
#endif
#define _freenova_clutch_included

/**
 * Returns the number of clutch rounds won by player for a given tier (1=1v1, 2=1v2, 3=1v3, 4=1v4, 5=1v5).
 */
native fnclutch_get_won(id, tier);

/**
 * Returns the number of clutch rounds attempted by player for a given tier (1=1v1, 2=1v2, 3=1v3, 4=1v4, 5=1v5).
 */
native fnclutch_get_att(id, tier);

/**
 * Returns total clutch wins across all tiers (1v1 to 1v5).
 */
native fnclutch_get_total_won(id);

/**
 * Returns total clutch attempts across all tiers (1v1 to 1v5).
 */
native fnclutch_get_total_att(id);
