#if defined _rsu_included
    #endinput
#endif
#define _rsu_included

#include <amxmodx>
#include <sqlx>
#include "rsu_version.inc"
#include "rsu_const.inc"

/**
 * Checks if the player's rank & stats data has been successfully loaded from MySQL.
 *
 * @param id        Player client index (1 to 32).
 * @return          True if player data is loaded, false otherwise.
 */
native bool:rsu_is_data_loaded(id);

/**
 * Master bot-counting switch (RANK_BOTS ini setting, owned by rsu_core).
 * True only when bots count everywhere (victim-side stats for humans).
 * Bots never load consumer state, so this only opens victim-side counters.
 *
 * @return          True when RANK_BOTS=1 and the core is loaded.
 */
native bool:rsu_bots_count();

/**
 * Authoritative ranked kill. See ranksultimate.inc for the contract.
 * Implemented by rsu_core; consumers implement the public of the same name.
 */
forward fn_on_player_kill(attacker, victim, weapon, headshot, tk);

/**
 * Authoritative bomb plant/defuse for missions/achievements.
 * type: 0 = plant, 1 = defuse.
 * Knife warmup and bots are already filtered by rsu_core.
 */
forward fn_on_bomb_event(id, type);

/**
 * Authoritative round win for missions/achievements.
 * Fired once per alive human winner (no bots, no dead, no HLTV).
 * team: 1 = T, 2 = CT.
 * Knife warmup already filtered.
 * Competitive Top15 keeps its own whole-team loop — do not consume this for /cmissions.
 */
forward fn_on_round_win(id, team);

/**
 * Retrieves the internal database auto-increment ID (`rsu_players.id`) for the player.
 *
 * @param id        Player client index (1 to 32).
 * @return          Database ID as an integer, or 0 if not loaded/offline.
 */
native rsu_get_player_database_id(id);

/**
 * Retrieves the authenticated and sanitized SteamID string of the player.
 *
 * @param id        Player client index (1 to 32).
 * @param buffer    Character array to store the SteamID.
 * @param maxlen    Maximum buffer capacity.
 * @return          Number of cells written.
 */
native rsu_get_auth_steamid(id, buffer[], maxlen);

/**
 * Retrieves the connection generation token for a player slot.
 * Token increments monotonically on every connect/disconnect to protect asynchronous callbacks.
 *
 * @param id        Player client index (1 to 32).
 * @return          Monotonic generation token.
 */
native rsu_get_connection_token(id);

/**
 * Retrieves the current XP of the player.
 *
 * @param id        Player client index (1 to 32).
 * @return          Current XP points (>= 0).
 */
native rsu_get_xp(id);

/**
 * Sets the player's XP directly. Triggers rank recalculation and dirty state.
 *
 * @param id        Player client index.
 * @param amount    New XP value.
 * @param source    Source event type (RsuXpSource).
 * @return          True on success, false if player is not loaded.
 */
native bool:rsu_set_xp(id, amount, RsuXpSource:source = RSU_XP_CUSTOM);

/**
 * Adds XP to the player. Passes through anti-exploit, multipliers, and pre-forwards.
 *
 * @param id        Player client index.
 * @param amount    Amount of XP to add (> 0).
 * @param source    Source event type (RsuXpSource).
 * @return          Actual amount of XP awarded after multipliers/caps, or 0 if blocked.
 */
native rsu_add_xp(id, amount, RsuXpSource:source = RSU_XP_CUSTOM);

/**
 * Removes XP from the player (e.g. penalties). Clamps XP to 0.
 *
 * @param id        Player client index.
 * @param amount    Amount of XP to deduct (> 0).
 * @param source    Source event type (RsuXpSource).
 * @return          Actual amount of XP deducted.
 */
native rsu_remove_xp(id, amount, RsuXpSource:source = RSU_XP_CUSTOM);

/**
 * Retrieves the lifetime total XP accumulated by the player across all resets/prestige.
 *
 * @param id        Player client index.
 * @return          Lifetime XP value.
 */
native rsu_get_lifetime_xp(id);

/**
 * Retrieves the player's current numerical level (1 to N).
 *
 * @param id        Player client index.
 * @return          Level number.
 */
native rsu_get_level(id);

/**
 * Retrieves the player's account prestige tier (0 to N).
 *
 * @param id        Player client index.
 * @return          Prestige level.
 */
#if !defined _rsu_get_prestige_declared
    #define _rsu_get_prestige_declared
    native rsu_get_prestige(id);
#endif

/**
 * Sets the player's account prestige tier.
 *
 * @param id        Player client index.
 * @param prestige  New prestige value.
 * @return          True on success, false otherwise.
 */
native bool:rsu_set_prestige(id, prestige);

/**
 * Retrieves the number of placement matches completed (0 to 10).
 *
 * @param id        Player client index.
 * @return          Count of completed placement matches.
 */
native rsu_get_placement_matches(id);

/**
 * Retrieves the player's current rank tier index (1 to max ranks).
 *
 * @param id        Player client index.
 * @return          Rank ID.
 */
native rsu_get_rank(id);

/**
 * Retrieves the display name of a given rank ID.
 *
 * @param rank_id   Rank index (1 to max ranks).
 * @param buffer    Output string buffer.
 * @param maxlen    Maximum buffer capacity.
 * @return          Number of cells written.
 */
native rsu_get_rank_name(rank_id, buffer[], maxlen);

/**
 * Retrieves the badge / icon filename of a given rank ID.
 *
 * @param rank_id   Rank index (1 to max ranks).
 * @param buffer    Output string buffer.
 * @param maxlen    Maximum buffer capacity.
 * @return          Number of cells written.
 */
native rsu_get_rank_badge(rank_id, buffer[], maxlen);

/**
 * Retrieves the minimum XP threshold required for a rank ID.
 *
 * @param rank_id   Rank index.
 * @return          Minimum XP integer.
 */
native rsu_get_rank_min_xp(rank_id);

/**
 * Retrieves the maximum XP threshold of a rank ID before advancing.
 *
 * @param rank_id   Rank index.
 * @return          Maximum XP integer, or -1 if highest tier.
 */
native rsu_get_rank_max_xp(rank_id);

/**
 * Returns total number of registered ranks.
 *
 * @return          Count of ranks.
 */
native rsu_get_total_ranks();

/**
 * Retrieves the player's skill rating.
 *
 * @param id        Player client index.
 * @return          Float skill rating.
 */
native Float:rsu_get_skill(id);

/**
 * Sets the player's skill rating.
 *
 * @param id        Player client index.
 * @param value     New skill rating value.
 * @return          True on success, false otherwise.
 */
native bool:rsu_set_skill(id, Float:value);

/**
 * Retrieves the player's all-time peak skill rating.
 *
 * @param id        Player client index.
 * @return          Float peak skill rating.
 */
native Float:rsu_get_peak_skill(id);

/**
 * Statistics accessors.
 */
native rsu_get_kills(id);
native rsu_get_deaths(id);
native rsu_get_headshots(id);
native rsu_get_assists(id);
native rsu_get_shots(id);
native rsu_get_hits(id);
native rsu_get_damage(id);
native rsu_get_playtime(id);
native Float:rsu_get_kd_ratio(id);
native Float:rsu_get_hs_percentage(id);
native Float:rsu_get_accuracy(id);

/**
 * Increments weapon statistics for a specific CSW_ weapon ID.
 *
 * @param id        Player client index.
 * @param weapon_id CSW_ weapon constant (1 to 31).
 * @param stat_type RsuWeaponStat metric type.
 * @param amount    Amount to add.
 * @return          True on success.
 */
native bool:rsu_add_weapon_stat(id, weapon_id, RsuWeaponStat:stat_type, amount = 1);

/**
 * Registers an external XP multiplier (e.g. VIP, Happy Hour, Event).
 *
 * @param name          Unique multiplier identifier string.
 * @param multiplier    Multiplier factor (e.g. 1.5 for +50%, 2.0 for double).
 * @return              Multiplier index token (>= 0).
 */
native rsu_register_multiplier(const name[], Float:multiplier);

/**
 * Sets or updates the multiplier factor of an already registered multiplier.
 *
 * @param multiplier_id Token returned by rsu_register_multiplier.
 * @param multiplier    New factor.
 * @return              True on success.
 */
native bool:rsu_set_multiplier(multiplier_id, Float:multiplier);

/**
 * Calculates the total active XP multiplier applied to a player.
 *
 * @param id        Player client index.
 * @return          Effective multiplier float (>= 1.0).
 */
native Float:rsu_get_active_multiplier(id);

/**
 * Registers a sub-plugin module with the core for runtime diagnostics.
 *
 * @param name      Module display name.
 * @param version   Module version string.
 * @param author    Author name.
 * @return          True on success.
 */
native bool:rsu_register_module(const name[], const version[], const author[]);

/**
 * Opens a designated MOTD web URL for a player.
 *
 * @param id        Player client index.
 * @param endpoint  Sub-path (e.g. "top", "player", "match", "weapons").
 * @param param     Optional query parameter (e.g. steamid or match ID).
 * @return          True on success.
 */
native bool:rsu_open_motd(id, const endpoint[], const param[] = "");

/**
 * Triggers the match started forward event across the RSU ecosystem.
 *
 * @param match_id  Generated match ID.
 * @param map       Map name.
 * @return          True on success.
 */
native bool:rsu_trigger_match_started(match_id, const map[]);

/**
 * Triggers the match finished forward event across the RSU ecosystem.
 *
 * @param match_id    Match ID.
 * @param t_score     Terrorist final score.
 * @param ct_score    Counter-Terrorist final score.
 * @param winner_team Winning team (1: T, 2: CT, 3: Draw).
 * @return            True on success.
 */
native bool:rsu_trigger_match_finished(match_id, t_score, ct_score, winner_team);

stock Handle:g_hRsuLocalSqlTuple = Empty_Handle;

/**
 * Retrieves the database handle tuple for the calling plugin.
 * Creates and caches a plugin-local handle using the active RSU SQL configuration.
 *
 * @return          Handle to database tuple, or Empty_Handle if not ready.
 */
stock Handle:rsu_get_sql_tuple()
{
    if (g_hRsuLocalSqlTuple != Empty_Handle)
        return g_hRsuLocalSqlTuple;

    new szDriver[16], szHost[64], szUser[64], szPass[64], szDb[64];
    get_cvar_string("rsu_sql_driver", szDriver, charsmax(szDriver));
    get_cvar_string("rsu_sql_host", szHost, charsmax(szHost));
    get_cvar_string("rsu_sql_user", szUser, charsmax(szUser));
    get_cvar_string("rsu_sql_pass", szPass, charsmax(szPass));
    get_cvar_string("rsu_sql_db", szDb, charsmax(szDb));

    new bool:bSqlite = true;
    if (cvar_exists("rsu_sql_is_sqlite"))
    {
        bSqlite = (get_cvar_num("rsu_sql_is_sqlite") != 0);
    }
    else if (szDriver[0] && !equali(szDriver, "sqlite"))
    {
        bSqlite = false;
    }

    if (!bSqlite && szHost[0])
    {
        SQL_SetAffinity("mysql");
        g_hRsuLocalSqlTuple = SQL_MakeDbTuple(szHost, szUser, szPass, szDb[0] ? szDb : "freenova_rank");
        return g_hRsuLocalSqlTuple;
    }

    SQL_SetAffinity("sqlite");
    g_hRsuLocalSqlTuple = SQL_MakeDbTuple("", "", "", "RanksUltimate");
    return g_hRsuLocalSqlTuple;
}

/**
 * Checks whether the SQL database connection is ready and operational.
 *
 * @return          True if ready, false otherwise.
 */
native bool:rsu_is_sql_ready();

/**
 * Checks whether the active SQL connection is SQLite (true) or MySQL (false).
 *
 * @return          True if SQLite, false if MySQL.
 */
native bool:rsu_is_sqlite();

// ============================================================================
// FORWARDS
// ============================================================================

/**
 * Called when a player's rank data has been successfully loaded from MySQL.
 *
 * @param id        Player client index.
 * @param db_id     Player's MySQL database ID.
 */
forward rsu_player_loaded(id, db_id);

/**
 * Called right before player data is flushed to the database.
 *
 * @param id        Player client index.
 */
forward rsu_player_saving(id);

/**
 * Called prior to XP modification. Allows plugins to adjust amount or cancel.
 *
 * @param id        Player client index.
 * @param amount    Amount of XP about to be granted/deducted (by reference).
 * @param source    Event source type.
 * @return          PLUGIN_CONTINUE to accept, PLUGIN_HANDLED to abort/block XP change.
 */
forward rsu_player_xp_pre(id, &amount, RsuXpSource:source);

/**
 * Called after XP has been successfully applied to the player's memory state.
 *
 * @param id        Player client index.
 * @param old_xp    Previous XP value.
 * @param new_xp    New XP value.
 * @param amount    Actual delta applied.
 * @param source    Event source type.
 */
forward rsu_player_xp_post(id, old_xp, new_xp, amount, RsuXpSource:source);

/**
 * Called when a player's rank tier changes (promotion or demotion).
 *
 * @param id        Player client index.
 * @param old_rank  Previous rank ID.
 * @param new_rank  New rank ID.
 */
forward rsu_player_rank_changed(id, old_rank, new_rank);

/**
 * Called when a player's skill rating is updated.
 *
 * @param id        Player client index.
 * @param old_skill Previous skill rating.
 * @param new_skill New skill rating.
 */
forward rsu_player_skill_changed(id, Float:old_skill, Float:new_skill);

/**
 * Called when a competitive match session begins.
 *
 * @param match_id  Generated unique match database ID.
 * @param map       Current map name.
 */
forward rsu_match_started(match_id, const map[]);

/**
 * Called when a competitive match session concludes.
 *
 * @param match_id      Match database ID.
 * @param t_score       Terrorist final score.
 * @param ct_score      Counter-Terrorist final score.
 * @param winner_team   Winning team (1: T, 2: CT, 3: Draw).
 */
forward rsu_match_finished(match_id, t_score, ct_score, winner_team);

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

/**
 * Match Telemetry & Advanced Round Analytics Natives
 */
native Float:rsu_get_match_adr(id);
native Float:rsu_get_match_kast(id);
native rsu_get_match_opening_kills(id);
native rsu_get_match_trade_kills(id);
native rsu_get_match_clutches_won(id);
native rsu_get_match_aces(id);

/**
 * Gamification, Achievements & Daily Missions Natives & Forwards
 */
native bool:rsu_achievement_add_progress(id, const ach_code[], amount = 1);
native bool:rsu_achievement_unlock(id, const ach_code[]);
native bool:rsu_achievement_is_unlocked(id, const ach_code[]);
native bool:rsu_mission_add_progress(id, const mission_type[], amount = 1);

forward rsu_achievement_unlocked(id, const ach_code[], const ach_name[], reward_xp);
forward rsu_mission_completed(id, slot_id, const mission_type[], reward_xp);

/**
 * Generation 3 Core Natives & Forwards (ADR-001, ADR-002, ADR-003, ADR-004)
 */

/**
 * Returns true if the player has completed Steam authorization, session setup,
 * and database data loading (PLAYER_STATE_READY).
 * Sub-plugins MUST check this before awarding persistent XP or recording match stats.
 *
 * @param id        Player client index (1 to 32).
 * @return          True if player state is READY, false otherwise.
 */
native bool:rsu_is_player_ready(id);

/**
 * Returns player's Glicko-2 rating deviation (RD).
 * Measures skill uncertainty (30.0 to 350.0).
 *
 * @param id        Player client index (1 to 32).
 * @return          Float deviation value.
 */
native Float:rsu_get_user_deviation(id);

/**
 * Retrieves the unique session UUID for the current client session.
 *
 * @param id        Player client index (1 to 32).
 * @param buffer    Output string buffer (at least 37 bytes).
 * @param maxlen    Maximum buffer capacity.
 * @return          Number of cells written.
 */
native rsu_get_session_uuid(id, buffer[], maxlen);

/**
 * Persists structured sub-plugin key-value state through Core's single persistence engine.
 *
 * @param id          Player client index.
 * @param module_tag  Unique module identifier (e.g. "ACH", "MSN").
 * @param state_blob  Formatted string data.
 * @return            True on success.
 */
native bool:rsu_db_save_module_state(id, const module_tag[], const state_blob[]);

/**
 * Loads structured sub-plugin key-value state through Core.
 *
 * @param id          Player client index.
 * @param module_tag  Unique module identifier.
 * @param buffer      Output buffer.
 * @param maxlen      Buffer capacity.
 * @return            True if state existed and was loaded, false otherwise.
 */
native bool:rsu_db_load_module_state(id, const module_tag[], buffer[], maxlen);

/**
 * Called when a player transitions to PLAYER_STATE_AUTHORIZED with a valid session UUID.
 *
 * @param id            Player client index.
 * @param steamid       Canonical Steam ID.
 * @param session_uuid  Unique session UUID.
 */
forward rsu_player_authorized(id, const steamid[], const session_uuid[]);

/**
 * Called when a player completes data loading and enters PLAYER_STATE_READY.
 *
 * @param id            Player client index.
 */
forward rsu_player_ready(id);
