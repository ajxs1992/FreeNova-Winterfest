#if defined _freenova_reg_included
    #endinput
#endif
#define _freenova_reg_included

// FreeNova Registration availability API (freenova_registration.amxx)
//
// The registration plugin auto-detects the forum/backend by polling its
// health endpoint every 30s. All forum-dependent features MUST gate on
// fnreg_is_available() so the game works standalone:
//   state 0 = UNKNOWN (probing)  1 = UP (auto-connected)  2 = DOWN (offline)

// 1 when the forum/backend answered the health check (registration usable)
native fnreg_is_available();
native fnreg_get_state();

// Forward: fired whenever the availability state changes
forward fnreg_availability_changed(iNewState);
