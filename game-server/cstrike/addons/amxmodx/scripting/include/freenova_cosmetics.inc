#if defined _freenova_cosmetics_included
    #endinput
#endif
#define _freenova_cosmetics_included

/**
 * Returns the player's equipped spawn effect (0-5)
 * 0=None, 1=Neon Ring, 2=Fire Aura, 3=Lightning Spark, 4=Shadow Void, 5=Divine Beacon
 */
native fncosmetics_get_spawn(id);

/**
 * Returns the player's equipped chat title (0-5)
 * 0=None, 1=[? GODLIKE], 2=[? PHANTOM], 3=[?? WARLORD], 4=[?? LEGEND], 5=[?? IMMORTAL]
 */
native fncosmetics_get_title(id);

/**
 * Returns the player's equipped death effect (0-4)
 * 0=None, 1=Lightning Bolt, 2=Blood Burst, 3=Frost Shatter, 4=Skull Ghost
 */
native fncosmetics_get_death(id);

/**
 * Opens the cosmetics web panel or menu for the player
 */
native fncosmetics_open_shop(id);

/**
 * Returns the player's custom in-game tag (e.g. "[ VIP ]")
 */
native fncosmetics_get_tag(id, output[], len);

/**
 * Returns the player's chat color: 0 = Gold (^1), 1 = Green (^4), 2 = Team (^3)
 */
native fncosmetics_get_color(id);

/**
 * Sets player's custom in-game tag and persists it.
 */
native fncosmetics_set_tag(id, const tag[]);

/**
 * Clears player's custom in-game tag.
 */
native fncosmetics_clear_tag(id);

/**
 * True if the player purchased the custom-tag license.
 */
native bool:fncosmetics_has_tag_license(id);

/**
 * Unlocks a specific spawn effect for the player and equips it if none equipped.
 * @param id        Player index.
 * @param spawn_id  Spawn effect ID (1-5).
 * @return          1 on success, 0 on invalid parameters.
 */
native fncosmetics_unlock_spawn(id, spawn_id);

/**
 * Unlocks a specific chat title for the player and equips it if none equipped.
 * @param id        Player index.
 * @param title_id  Chat title ID (1-12).
 * @return          1 on success, 0 on invalid parameters.
 */
native fncosmetics_unlock_title(id, title_id);

/**
 * Grants custom tag creation license to the player and persists it.
 * @param id        Player index.
 * @return          1 on success, 0 on invalid parameters.
 */
native fncosmetics_grant_tag_license(id);

/**
 * Grants custom chat color capability (green chat) and equips it if default.
 * @param id        Player index.
 * @return          1 on success, 0 on invalid parameters.
 */
native fncosmetics_grant_chat_color(id);

native fncosmetics_get_spawn_name(id, output[], len);
native fncosmetics_get_title_name(id, output[], len);
native fncosmetics_get_death_name(id, output[], len);

