#if defined _menabp_included
#endinput
#endif
#define _menabp_included

// ============================================================
// Original BattlePass natives
// ============================================================
native menabp_has_weapon_menu(id)
native menabp_has_weapon_menu_awp(id)
native menabp_has_double_jump(id)
native menabp_has_parachute(id)
native menabp_has_healthnade(id)
native menabp_has_revive(id)
native menabp_has_fastsniper(id)

native Float:menabp_get_revive_time(id)
native menabp_get_revive_max_revives(id)
native menabp_get_revive_max_spawns(id)
native Float:menabp_get_healthnade_throw(id)
native Float:menabp_get_healthnade_drink(id)

// ============================================================
// New natives for Panel / Skins / Prestige
// ============================================================

/**
 * Returns the player's prestige level (0 = no prestige).
 *
 * @param id        Player index.
 * @return          Prestige level (0-10).
 */
native menabp_get_prestige(id)

/**
 * Returns the player's coin balance.
 *
 * @param id        Player index.
 * @return          Number of coins.
 */
native menabp_get_coins(id)

/**
 * Adds coins to a player's balance and saves to disk.
 *
 * @param id        Player index.
 * @param amount    Number of coins to add (negative to subtract).
 * @return          New coin balance, or 0 if rejected (unloaded player or
 *                  spend larger than the current balance — never clamp-spend).
 */
native menabp_add_coins(id, amount)

/**
 * Adds coins once for a caller-supplied award id. The award is recorded in
 * the BattlePass vault, so a retry after a save/crash cannot pay twice.
 *
 * @param id        Player index.
 * @param amount    Coins to add (must be > 0).
 * @param awardId   Stable id, e.g. "weekly_coins#2026-42" or "ach#7".
 * @return          -1 not ready/error, 0 already awarded, >0 new balance.
 */
native menabp_add_coins_once(id, amount, const awardId[])

/**
 * Returns the player's BattlePass XP (separate from RSU rank XP).
 *
 * @param id        Player index.
 * @return          BP XP, or 0 if not loaded.
 */
native menabp_get_xp(id)

/**
 * Returns the player's BattlePass tier (1..60).
 *
 * @param id        Player index.
 * @return          BP tier, or 0 if not loaded.
 */
native menabp_get_tier(id)

/**
 * Returns the absolute BP XP threshold for the player's next tier.
 * At max tier this returns the tier-60 threshold.
 *
 * @param id        Player index.
 * @return          Next-tier XP threshold, or 0 if not loaded.
 */
native menabp_get_next_xp(id)

/**
 * Returns the maximum BattlePass tier (60).
 */
native menabp_get_max_tier()

/**
 * Adds BattlePass XP (not rank XP). Applies the BP shop boost and caps at
 * the tier-60 threshold. Tier-up rewards are granted automatically.
 *
 * @param id        Player index.
 * @param amount    BP XP to add (must be > 0).
 * @return          XP actually added, or 0 if not ready/at max.
 */
native menabp_add_xp(id, amount)

/**
 * Adds BattlePass XP once for a caller-supplied award id.
 *
 * @param id        Player index.
 * @param amount    BP XP to add (must be > 0).
 * @param awardId   Stable id, e.g. "daily_complete#20261023".
 * @return          -1 not ready/error, 0 already awarded/at max, >0 XP added.
 */
native menabp_add_xp_once(id, amount, const awardId[])

/**
 * Returns the player's VIP tier.
 *
 * @param id        Player index.
 * @return          0 = None, 1 = VIP (r), 2 = VIP-Gold (q), 3 = VIP-Diamond (p).
 */
native menabp_get_vip_tier(id)

/**
 * Checks if the player has completed today's daily missions.
 *
 * @param id        Player index.
 * @return          1 if complete, 0 otherwise.
 */
native menabp_is_mission_complete(id)

/**
 * Reads daily mission progress (read-only; for the web panel sync).
 *
 * @param id        Player index.
 * @param mission   0=kills 1=headshots 2=plants 3=defuses 4=round wins.
 * @return          Current progress value.
 */
native menabp_get_daily_progress(id, mission)

/**
 * Reads the daily coin missions' best values (streak/damage/survivals).
 *
 * @param id        Player index.
 * @param mission   0=killstreak 1=damage 2=survivals.
 * @return          Current best value for the day.
 */
native menabp_get_daily2_progress(id, mission)

/**
 * Reads weekly mission progress.
 *
 * @param id        Player index.
 * @param mission   0=kills 1=headshots 2=plants 3=round wins.
 * @return          Current progress value.
 */
native menabp_get_weekly_progress(id, mission)

/**
 * Opens the BattlePass MOTD for the player (server-side).
 *
 * @param id        Player index.
 */
native menabp_show_battlepass(id)

/**
 * Opens the Coin Shop menu for the player (server-side).
 *
 * @param id        Player index.
 */
native menabp_show_shop(id)

/**
 * Opens the local missions VGUI (not MOTD).
 */
native menabp_show_missions(id)

/**
 * Opens the local achievements VGUI.
 */
native menabp_show_achievements(id)

/**
 * Seconds left on an active BP XP boost. 0 if none.
 */
native menabp_get_boost_left(id)

/**
 * Active BP XP boost multiplier as a float cell (1.5 / 2.0 / 3.0). 1.0 if none.
 */
native Float:menabp_get_boost_mult(id)

/**
 * Completed daily / bonus / weekly counts for hub rows.
 * daily 0-5, bonus 0-3, weekly 0-4.
 */
native menabp_get_daily_done(id)
native menabp_get_bonus_done(id)
native menabp_get_weekly_done(id)

/**
 * Number of unlocked achievements (visible 13; excludes hidden prestige).
 */
native menabp_get_ach_count(id)

/**
 * Raw achievement bitfield (all 14 bits, including hidden ACH_PRESTIGE_1).
 *
 * @param id        Player index.
 * @return          Bitfield, or 0 if id is invalid.
 */
native menabp_get_ach_unlocked(id)

/**
 * Lifetime achievement helper counters.
 *
 * @param id        Player index.
 * @param which     0 kills, 1 hs, 2 plants, 3 defuses, 4 wins, 5 revives, 6 lifetime streak best.
 * @return          Counter value, or 0 if id/which is invalid.
 */
native menabp_get_ach_stat(id, which)

/**
 * Opens the BattlePass unified Web MOTD at a specific tab.
 *
 * @param id        Player index.
 * @param tab       Tab identifier (pass, missions, cosmetics, top15, rankstats, events).
 * @return          1 on success, 0 on failure.
 */
native menabp_show_motd(id, const tab[])

/**
 * Returns player's unlocked stage for a skill (0 to max_stage).
 *
 * @param id        Player index.
 * @param skill_id  Skill identifier (0-12).
 * @return          Current stage (0 = locked).
 */
native menabp_get_skill_stage(id, skill_id)

/**
 * Sets player's unlocked stage for a skill (0 to max_stage) and saves to disk.
 *
 * @param id        Player index.
 * @param skill_id  Skill identifier (0-12).
 * @param stage     New stage level.
 * @return          1 on success, 0 on failure.
 */
native menabp_set_skill_stage(id, skill_id, stage)

/**
 * Notes a successful revive for ACH_REVIVER (25 revives).
 * Called by revive_bridge after MODE_REVIVE completes.
 *
 * @param id        Player index (activator).
 * @return          Lifetime revive count after increment.
 */
native menabp_note_revive(id)

/**
 * Returns player's Battle Pass permanent bonus spawn HP cursor (from rare+ tiers).
 * @param id        Player index.
 * @return          Bonus HP value (stacks with level table and shop).
 */
native menabp_get_bp_hp(id)

/**
 * Returns player's Battle Pass permanent bonus spawn Armor cursor (from rare+ tiers).
 * @param id        Player index.
 * @return          Bonus Armor value.
 */
native menabp_get_bp_armor(id)

/**
 * Returns player's Battle Pass permanent bonus multi-jump count (from rare+ tiers).
 * @param id        Player index.
 * @return          Pass jump bonus count (gameplay is hard-capped at 2 total jumps).
 */
native menabp_get_bp_jumps(id)

/**
 * Returns player's Battle Pass permanent Fast Sniper unlock stage (from rare+ tiers).
 * @param id        Player index.
 * @return          Sniper stage (0-2).
 */
native menabp_get_bp_sniper(id)

/**
 * Returns player's Battle Pass permanent Last Stand unlock stage (from rare+ tiers).
 * @param id        Player index.
 * @return          Last Stand stage (0-2).
 */
native menabp_get_bp_laststand(id)

/**
 * Returns player's Battle Pass permanent Parachute unlock flag (from rare+ tiers).
 * @param id        Player index.
 * @return          1 if parachute unlocked, 0 otherwise.
 */
native menabp_get_bp_chute(id)

/**
 * Returns player's highest claimed Battle Pass premium tier cursor (1-60).
 * @param id        Player index.
 * @return          Highest premium tier granted.
 */
native menabp_get_bp_premium(id)

/**
 * Returns player's highest claimed Battle Pass milestone tier cursor (1-60).
 * @param id        Player index.
 * @return          Highest milestone tier granted.
 */
native menabp_get_bp_milestone(id)

/**
 * Readiness gate (f1a7d20 pattern): 1 when the menabp library is
 * registered AND this player's Battle Pass data has finished loading.
 * Consumers MUST check this (or LibraryExists + this) before calling any
 * other menabp_* native; calls into an unready provider fail closed (0).
 * @param id        Player index.
 * @return          1 if ready, 0 otherwise.
 */
native menabp_is_ready(id)

/**
 * Opens the skill shop directly (no hub-of-shops menu).
 * Fail-closed: returns 0 while shop data is loading.
 * @param id        Player index.
 * @return          1 if opened, 0 otherwise.
 */
native menabp_show_skills(id)

#define SKILL_MULTI_JUMP   0
#define SKILL_SPAWN_HP     1
#define SKILL_SPAWN_ARMOR  2
#define SKILL_VAMPIRE      3
#define SKILL_NIMBLE       4
#define SKILL_FEATHERFALL  5
#define SKILL_HEALTHNADE   6
#define SKILL_FAST_SNIPER  7
#define SKILL_REVIVE       8
#define SKILL_LASTSTAND    9
#define SKILL_PARACHUTE    10
#define SKILL_AWP_UNLOCK   11
#define SKILL_CHAT_COLOR   12
#define SKILL_COUNT        13

