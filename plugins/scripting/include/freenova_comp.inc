#if defined _freenova_comp_included
    #endinput
#endif
#define _freenova_comp_included

// FreeNova Competitive natives - read-only state exports for consumers
// (web sync push, hub, future web pages). The authoritative store is the
// competitive plugin's SQLite database; these never mutate state.

// Season (current month key "YYYY-MM") competitive points.
native fncomp_get_points(id)
// Career lifetime points (survives season resets).
native fncomp_get_lifetime(id)
// Season kills/headshots tracked by the competitive plugin.
native fncomp_get_kills(id)
native fncomp_get_headshots(id)
// Season round wins / MVP awards.
native fncomp_get_wins(id)
native fncomp_get_mvp(id)
// Daily mission progress: 0=RIFLEMAN(kills) 1=SHARPSHOOTER(hs) 2=WINNER(wins) 3=MVP.
native fncomp_get_mission_progress(id, mission)
// Daily mission completion bit-mask (bit N set when mission N is complete).
// Order matches fncomp_get_mission_progress: 0=RIFLEMAN 1=SHARPSHOOTER 2=WINNER 3=MVP.
native fncomp_get_mission_done(id)

/**
 * Claims the current-season tournament coin prize exactly once.
 * Server-side eligibility; never trusts the browser. Returns coins granted
 * (0 if already claimed, offline, or ineligible).
 */
native fncomp_claim_season_prize(id)

/**
 * True if the current-season tournament prize has already been claimed.
 */
native bool:fncomp_is_season_claimed(id)

/**
 * Season rank by board order (points DESC, kills DESC). 0 if unknown.
 * Blocking SQLite read - call from task/action context, not gameplay hooks.
 */
native fncomp_get_rank(id)
