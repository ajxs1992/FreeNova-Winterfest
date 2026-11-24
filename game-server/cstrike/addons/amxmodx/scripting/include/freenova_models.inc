#if defined _freenova_models_included
    #endinput
#endif
#define _freenova_models_included

/**
 * Returns player's equipped custom player model.
 */
native fn_models_get_equipped(id, szModel[], len);

/**
 * Sets player's equipped custom player model.
 */
native fn_models_set_equipped(id, const szModel[], team);

/**
 * Returns 1 if player has a forced or exclusive model active, 0 otherwise.
 */
native fn_models_is_forced(id);

/**
 * Returns player's equipped weapon skin index for a given group (0=AK, 1=M4, 2=Deagle, 3=AWP, 4=Knife).
 */
native fn_skins_get_equipped(id, group);

/**
 * Sets player's equipped weapon skin for a given group.
 */
native fn_skins_set_equipped(id, group, skin);

/**
 * Checks if player owns a specific weapon skin.
 */
native bool:fn_skins_is_owned(id, group, skin);

/**
 * Unlocks a weapon skin for player and saves to disk.
 */
native fn_skins_unlock(id, group, skin);

/**
 * Unlocks the first skin in a group whose viewmodel path matches.
 * Used for season exclusives so grants survive cfg row reordering.
 */
native fn_skins_unlock_model(id, group, const viewModel[]);

/**
 * Returns total number of registered skins for a weapon group.
 */
native fn_skins_get_count(group);

/**
 * Returns display name of a skin.
 */
native fn_skins_get_name(group, skin, szName[], len);

/**
 * Authoritative coin price for a weapon skin. 0 = free / default.
 */
native fn_skins_get_price(group, skin);

/**
 * Gate check for purchases: VIP/level requirements without ownership test.
 * Returns 1 if the player may buy the skin, 0 otherwise.
 */
native fn_skins_can_buy(id, group, skin);

/**
 * Authoritative coin price for a premade player model (looked up by model file).
 */
native fn_models_get_price(const model[]);

/**
 * Gate check for purchases: VIP requirement without ownership test.
 * Returns 1 if the player may buy the model, 0 otherwise.
 */
native fn_models_can_buy(id, const model[]);

/**
 * True if the player owns the named premade player model.
 */
native bool:fn_models_is_owned(id, const model[]);

/**
 * Unlocks a premade player model without charging. Persist to vault.
 */
native fn_models_unlock(id, const model[]);