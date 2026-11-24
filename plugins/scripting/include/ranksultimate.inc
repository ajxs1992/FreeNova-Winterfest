/**
 * ============================================================================
 * FREENova Rank System Ultimate - Official API Library
 * Documentation & Compatibility: Tornado AMXX Hub Rank System Ultimate
 * ============================================================================
 */

#if defined _ranksultimate_included
    #endinput
#endif
#define _ranksultimate_included

#pragma reqlib ranksultimate
#if !defined AMXMODX_NOAUTOLOAD
    #pragma loadlib ranksultimate
#endif

// Weapon Indexes for rsu_get_user_weapon_kills()
enum
{
    RSU_WEAPON_KNIFE = 0,
    RSU_WEAPON_GLOCK18,
    RSU_WEAPON_USP,
    RSU_WEAPON_P228,
    RSU_WEAPON_DEAGLE,
    RSU_WEAPON_FIVESEVEN,
    RSU_WEAPON_ELITE,
    RSU_WEAPON_M3,
    RSU_WEAPON_XM1014,
    RSU_WEAPON_TMP,
    RSU_WEAPON_MAC10,
    RSU_WEAPON_MP5NAVY,
    RSU_WEAPON_UMP45,
    RSU_WEAPON_P90,
    RSU_WEAPON_M249,
    RSU_WEAPON_GALIL,
    RSU_WEAPON_FAMAS,
    RSU_WEAPON_AK47,
    RSU_WEAPON_M4A1,
    RSU_WEAPON_SG552,
    RSU_WEAPON_AUG,
    RSU_WEAPON_SCOUT,
    RSU_WEAPON_AWP,
    RSU_WEAPON_G3SG1,
    RSU_WEAPON_SG550,
    RSU_WEAPON_HEGRENADE
};

// ============================================================================
// FORWARDS
// ============================================================================

/**
 * Called when a client's level changes (promotion or demotion).
 *
 * @param index     Player client index.
 * @param level     New numerical level.
 * @param levelup   True if leveled up, false if leveled down.
 */
forward rsu_user_level_updated(index, level, bool:levelup);

/**
 * Called when a client's XP changes.
 *
 * @param index     Player client index.
 * @param xp        New XP value.
 * @param teamxp    True if XP originated from a team reward, false if personal.
 */
forward rsu_user_xp_updated(index, xp, bool:teamxp);

/**
 * Called when client's stats are about to be saved to database/storage.
 *
 * @param index     Player client index.
 * @param saveinfo  Auth identifier string (SteamID / IP / Name).
 * @param name      Player display name.
 */
forward rsu_user_stats_saved(index, const saveinfo[], const name[]);

/**
 * Called when client's stats have finished loading from database/storage.
 *
 * @param index     Player client index.
 * @param saveinfo  Auth identifier string (SteamID / IP / Name).
 * @param name      Player display name.
 */
forward rsu_user_stats_loaded(index, const saveinfo[], const name[]);

/**
 * Authoritative combat kill. Fired ONCE after RSU has accepted a ranked
 * enemy kill (warmup, bots, TK, suicide and anti-farm already filtered).
 * Downstream systems (missions, achievements, BattlePass, competitive)
 * must consume this instead of registering DeathMsg / client_death.
 *
 * @param attacker  Killer client index.
 * @param victim    Victim client index.
 * @param weapon    CSW_* weapon id at time of kill.
 * @param headshot  1 if headshot, 0 otherwise.
 * @param tk        Always 0 (teamkills never reach this forward).
 */
forward fn_on_player_kill(attacker, victim, weapon, headshot, tk);

/**
 * Authoritative bomb plant/defuse for missions/achievements.
 * type: 0 = plant, 1 = defuse. Knife warmup and bots already filtered.
 */
forward fn_on_bomb_event(id, type);

/**
 * Authoritative round win for missions/achievements.
 * Once per alive human winner. team: 1 = T, 2 = CT.
 * Competitive Top15 keeps its own whole-team loop.
 */
forward fn_on_round_win(id, team);

// ============================================================================
// CORE NATIVES (32 PUBLIC NATIVES)
// ============================================================================

/**
 * Returns client's current XP.
 */
native rsu_get_user_xp(index);

/**
 * Returns client's current XP progress as a percentage to next rank.
 */
native Float:rsu_get_user_xp_percent(index);

/**
 * Returns XP needed for the next rank tier.
 */
native rsu_get_user_next_xp(index);

/**
 * Returns XP required for a specific numerical level.
 */
native rsu_get_xp_for_level(level);

/**
 * Returns client's current numerical level.
 */
native rsu_get_user_level(index);

/**
 * Returns client's total kills.
 */
native rsu_get_user_kills(index);

/**
 * Returns client's total deaths.
 */
native rsu_get_user_deaths(index);

/**
 * Returns client's total headshots.
 */
native rsu_get_user_headshots(index);

/**
 * Returns client's total assists.
 */
native rsu_get_user_assists(index);

/**
 * Returns client's total shots fired.
 */
native rsu_get_user_shots(index);

/**
 * Returns client's total shots hit.
 */
native rsu_get_user_hits(index);

/**
 * Returns client's total damage dealt.
 */
native rsu_get_user_damage(index);

/**
 * Returns client's total round MVPs.
 */
native rsu_get_user_mvp(index);

/**
 * Returns client's total rounds won.
 */
native rsu_get_user_rounds_won(index);

/**
 * Returns client's total bombs planted.
 */
native rsu_get_user_bombs_planted(index);

/**
 * Returns client's total bombs exploded.
 */
native rsu_get_user_bombs_exploded(index);

/**
 * Returns client's total bombs defused.
 */
native rsu_get_user_bombs_defused(index);

/**
 * Returns client's total played time in seconds.
 */
native rsu_get_user_played_time(index);

/**
 * Returns client's skill range rating as float.
 * Standard calculation: 100.0 * Kills / max(1, Kills + Deaths)
 */
native Float:rsu_get_user_skill_range(index);

/**
 * Returns client's current position on the server leaderboard.
 */
native rsu_get_user_server_rank(index);

/**
 * Account prestige tier stored on rsu_players (0 = none).
 * Web snapshot and menabp_get_prestige must read this, not Battle Pass leftovers.
 */
#if !defined _rsu_get_prestige_declared
    #define _rsu_get_prestige_declared
    native rsu_get_prestige(index);
#endif

/**
 * Returns maximum number of all rank levels.
 */
native rsu_get_max_levels();

/**
 * Returns total number of registered players on the server.
 */
native rsu_get_max_server_ranks();

/**
 * Returns rank name for a specific numerical level.
 */
native rsu_get_rank_by_level(level, buffer[], length);

/**
 * Returns client's current rank tier name.
 */
native rsu_get_user_rank(index, buffer[], length);

/**
 * Returns client's current skill name (e.g. "L-", "M", "H+", "G").
 */
native rsu_get_user_skill(index, buffer[], length);

/**
 * Returns client's save identifier string (SteamID / IP / Name).
 */
native rsu_get_user_saveinfo(index, buffer[], length);

/**
 * Gives a specific XP amount to a client.
 */
native rsu_give_user_xp(index, value = 0);

/**
 * Gives a specific XP amount to all players on a specific team.
 * Team: 1 = Terrorists, 2 = Counter-Terrorists.
 */
native rsu_give_team_xp(team, value = 0);

/**
 * Returns client's first login date/time string.
 */
native rsu_get_user_first_login(index, buffer[], len);

/**
 * Returns client's last login date/time string.
 */
native rsu_get_user_last_login(index, buffer[], len);

/**
 * Returns client's weapon kills for a given weapon index (0-25).
 */
native rsu_get_user_weapon_kills(index, weapon);

// ============================================================================
// ZOMBIE PLAGUE (ZP MODE) EXTENSION NATIVES
// ============================================================================

/**
 * Returns total number of rounds won as zombie.
 */
native rsu_get_user_zombie_wins(index);

/**
 * Returns total number of rounds won as human.
 */
native rsu_get_user_human_wins(index);

/**
 * Returns total number of infections caused.
 */
native rsu_get_user_infections(index);

/**
 * Returns total number of survivals as human.
 */
native rsu_get_user_survivals(index);

/**
 * Returns total number of infections made in current round.
 */
native rsu_get_user_round_infections(index);

#if !defined _rsu_show_top15_declared
    #define _rsu_show_top15_declared
    /**
     * Displays the Top 15 MOTD screen to a player.
     *
     * @param index     Player client index.
     * @param sort      Sort order keyword: "xp", "skill", "kills", "deaths", "kd", "headshots", "playtime".
     */
    native rsu_show_top15(index, const sort[] = "xp");

    /**
     * Displays the RankStats MOTD screen to a player.
     *
     * @param index     Player client index.
     * @param target    Target player index (0 or id for self).
     */
    native rsu_show_rankstats(index, target = 0);
#endif