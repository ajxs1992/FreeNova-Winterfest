#if defined _rsu_const_included
    #endinput
#endif
#define _rsu_const_included

#define RSU_MAX_PLAYERS         32
#define RSU_MAX_RANKS           32
#define RSU_MAX_WEAPONS         32
#define RSU_MAX_NAME_LENGTH     32
#define RSU_MAX_AUTHID_LENGTH   32
#define RSU_MAX_TAG_LENGTH      16

// Dirty Flags for In-Memory Batching & Autosaving
enum (<<= 1)
{
    DIRTY_NONE = 0,
    DIRTY_PLAYER_BASE = 1,  // Name, IP, Country, Playtime
    DIRTY_STATS,            // Kills, Deaths, Damage, Plants, Rounds
    DIRTY_WEAPONS,          // Per-weapon stats
    DIRTY_XP_SKILL          // Current XP, Level, Rank, Skill Rating
};

// Event Sources for XP Adjustments
enum RsuXpSource
{
    RSU_XP_UNKNOWN = 0,
    RSU_XP_KILL,
    RSU_XP_HEADSHOT,
    RSU_XP_KNIFE,
    RSU_XP_GRENADE,
    RSU_XP_ASSIST,
    RSU_XP_MVP,
    RSU_XP_ROUND_WIN,
    RSU_XP_BOMB_PLANT,
    RSU_XP_BOMB_EXPLODED,
    RSU_XP_BOMB_DEFUSED,
    RSU_XP_HOSTAGE_RESCUED,
    RSU_XP_DAMAGE_THRESHOLD,
    RSU_XP_WINSTREAK,
    RSU_XP_KILLSTREAK,
    RSU_XP_BOT_KILL,
    RSU_XP_HAPPY_HOUR,
    RSU_XP_TIME_REWARD,
    RSU_XP_RANDOM_ROUND,
    RSU_XP_ADMIN,
    RSU_XP_PENALTY_DEATH,
    RSU_XP_PENALTY_SUICIDE,
    RSU_XP_PENALTY_TEAMKILL,
    RSU_XP_CUSTOM
};

// Weapon Stat Metrics
enum RsuWeaponStat
{
    RSU_WEAPON_KILL = 0,
    RSU_WEAPON_HS,
    RSU_WEAPON_SHOT,
    RSU_WEAPON_HIT,
    RSU_WEAPON_DAMAGE,
    RSU_WEAPON_DEATH_BY
};

// Team Identifier Enums
enum RsuTeam
{
    RSU_TEAM_UNASSIGNED = 0,
    RSU_TEAM_T = 1,
    RSU_TEAM_CT = 2,
    RSU_TEAM_SPEC = 3
};

// Rank Definition Structure Constants
#define RSU_MAX_RANK_NAME   32
#define RSU_MAX_RANK_BADGE  32
#define RSU_MAX_RANK_COLOR  16

// Default Rating Constants
#define RSU_DEFAULT_SKILL   1000.0
#define RSU_MIN_SKILL       100.0

// Player Lifecycle States (ADR-001)
enum PlayerState
{
    PLAYER_STATE_EMPTY = 0,
    PLAYER_STATE_CONNECTING,
    PLAYER_STATE_AUTHORIZED,
    PLAYER_STATE_LOADING,
    PLAYER_STATE_READY,
    PLAYER_STATE_SAVING,
    PLAYER_STATE_DISCONNECTED
};

// Database Circuit Breaker States (ADR-002)
enum CircuitState
{
    CIRCUIT_CLOSED = 0,
    CIRCUIT_OPEN,
    CIRCUIT_HALF_OPEN
};

// Sub-Plugin Module Capabilities (ADR-004)
enum (<<= 1)
{
    RSU_CAP_NONE = 0,
    RSU_CAP_REWARDS = 1,
    RSU_CAP_UI,
    RSU_CAP_COMBAT,
    RSU_CAP_ECONOMY
};

#define RSU_CIRCUIT_MAX_FAILURES 3
#define RSU_CIRCUIT_TIMEOUT_SEC  5.0
#define RSU_OFFLINE_JOURNAL_CAP  256
