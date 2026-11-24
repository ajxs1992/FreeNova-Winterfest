#if defined _freenova_vip_included
#endinput
#endif
#define _freenova_vip_included

// ============================================================
// FreeNova Unified VIP — public API
// One authoritative VIP system for every plugin on the server.
// ============================================================

// Tiers
#define FNVIP_NONE   0
#define FNVIP_VIP    1   // VIP
#define FNVIP_VIPPLUS 2  // VIP+
#define FNVIP_ELITE  3   // VIP Elite

// Benefit flags (fnvip_has_benefit)
#define FNVIP_BENEFIT_XP         0  // XP multiplier
#define FNVIP_BENEFIT_BPXP       1  // BattlePass XP multiplier
#define FNVIP_BENEFIT_WEAPONS    2  // VIP weapon menu (/vmenu)
#define FNVIP_BENEFIT_MODELS     3  // VIP player models
#define FNVIP_BENEFIT_SKINS      4  // VIP weapon skins
#define FNVIP_BENEFIT_PERKS      5  // gameplay perks (HP/AP regen, jump, parachute)
#define FNVIP_BENEFIT_CHATTAG    6  // chat tag
#define FNVIP_BENEFIT_COINS      7  // coin bonus multiplier
#define FNVIP_BENEFIT_BADGE      8  // scoreboard/profile badge
#define FNVIP_BENEFIT_TRIALS     9  // can purchase coin-shop VIP trials

// Entitlement sources (for admin visibility / history)
#define FNVIP_SRC_ADMIN      0
#define FNVIP_SRC_PANEL      1
#define FNVIP_SRC_REG_TRIAL  2
#define FNVIP_SRC_SHOP       3
#define FNVIP_SRC_EVENT      4
#define FNVIP_SRC_PROMOTION  5

// Forwards
forward fnvip_tier_changed(id, oldTier, newTier);

/**
 * Resolved tier = highest currently valid tier across all sources
 * (static users.ini flags + persisted timed entitlements).
 */
native fnvip_get_tier(id);

native bool:fnvip_has_tier(id, tier);          // resolved tier >= tier
native bool:fnvip_has_benefit(id, benefit);    // benefit gate (tier-dependent)

native Float:fnvip_get_xp_multiplier(id);      // 1.0 / 1.50 / 2.00 / 2.50
// NOTE: tiers are 0-3 only (NONE/VIP/VIP+/ELITE). There is no Legend tier
// in-game; catalog `vipTier:4` legends are web-display names, not gates.
native Float:fnvip_get_bp_multiplier(id);      // 1.0 / 1.05 / 1.10 / 1.15
native Float:fnvip_get_coin_multiplier(id);    // 1.0 / 1.50 / 2.00 / 2.50

native fnvip_get_tier_name(id, out[], len);    // "Member"/"VIP"/"VIP+"/"VIP Elite"
native fnvip_get_tier_name_raw(tier, out[], len);

/**
 * Grant a timed entitlement. NEVER downgrades: if the player currently holds
 * a tier >= the granted tier with a later-or-equal expiry, the entitlement is
 * still recorded additively (never overwriting the better one).
 * Returns: 1 = new entitlement created, 0 = recorded, existing preserved.
 */
native fnvip_grant(id, tier, seconds, source, const reason[] = "");

native fnvip_revoke(id, tier, source);   // revoke entitlements from one source

/**
 * Time remaining on the player's resolved tier, in seconds.
 * 0 = not VIP, -1 = static (flag-based, no expiry).
 */
native fnvip_get_remaining(id);

/**
 * One-time registration reward: 72h VIP+ trial.
 * Atomic — the vault claim key IS the lock; a second call for the same
 * authid is refused even across reconnects/restarts.
 * Returns: 1 = claimed now (grant applied), 0 = already claimed, -1 = bad id.
 * Out params (optional, can be 0): claimed = 1 if granted in THIS call.
 */
native fnvip_claim_registration_trial(id);

native bool:fnvip_is_registered_trial_claimed(id);

/** Re-resolve tier after external flag changes; fires fnvip_tier_changed. */
native fnvip_resync(id);

/** Show the unified 3-tier VIP comparison MOTD to a player. */
native fnvip_show_vip_motd(id);

/** Broadcast the online-VIP list to a player (chat). */
native fnvip_show_vips_list(id);
