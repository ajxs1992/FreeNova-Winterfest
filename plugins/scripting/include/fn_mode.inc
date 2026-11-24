// include/fn_mode.inc
//
// fn_mode - the one-active-mode arbiter.
//
// Why it exists: every non-default game mode on this server changes engine
// cvars that outlive the round it was started in (mp_freezetime,
// amx_knife_round_active, fn_event_xp_mult, ...). Two modes running at once
// fight over those cvars and the loser's restore writes the winner's value
// back, so the server ends up in a state no config file describes. The
// expensive examples in this tree: simple_warmup leaving
// amx_knife_round_active 1 after a map change (every XP owner then refuses to
// pay XP for the whole map, REVIEW.md 5.5) and two event windows multiplying
// the same multiplier (REVIEW.md 5.2).
//
// The contract:
//   * one mode at a time. fn_mode_begin() is REFUSED while another mode holds
//     the arbiter; the refusal is logged and the reason is readable through
//     fn_mode_refusal().
//   * a mode never writes a cvar itself: it calls fn_mode_set(), which
//     snapshots the pre-mode value the first time that cvar is touched and
//     remembers it in a per-mode table.
//   * fn_mode_end() restores the whole table (last set, first restored).
//   * fn_mode's own plugin_end() restores whatever is still active, so a map
//     change, a plugin reload or a crash of the owning plugin cannot leave a
//     mode running.
//
// Deliberately dependency-free (no fn_core, no fn_state): it is the safety net
// for the other modes, so it must be the cheapest thing in the tree to load.
//
// Guarded use: the arbiter is an optional dependency. A mode that needs it
// checks LibraryExists("fn_mode", LibType_Library) and keeps its own fallback
// restore path - a server without fn_mode.amxx must behave like today, never
// like a server with a half-applied mode.

#if defined _fn_mode_included
	#endinput
#endif

#define _fn_mode_included

// Hard cap on cvars one mode may own. 24 covers every mode in the tree with
// room to spare; going over is a programming error and is logged, not fatal.
#define FN_MODE_MAX_CVARS 24

// fn_mode_begin: claim the arbiter.
//   mode      - short id, e.g. "warmup", "event:xp". Compared case-insensitively.
//   payload   - free-form detail for the log and for fn_mode_payload().
//   initiator - the player to tell when the begin is REFUSED (0 = server
//               console, which gets a console line instead of chat). A refusal
//               is never silent to whoever tried to start the mode.
// Returns 1 when the mode now owns the arbiter (or already owned it - calling
// begin twice is idempotent), 0 when it was refused because another mode is
// active. Read fn_mode_refusal() for the reason.
native fn_mode_begin(const mode[], const payload[] = "", initiator = 0);

// fn_mode_set: snapshot (first time only) and write one cvar for the owning
// mode. Returns 1 on success, 0 when the caller is not the active mode, the
// cvar does not exist (never created) or the table is full.
native fn_mode_set(const mode[], const cvar[], const value[]);

// fn_mode_end: restore every cvar the mode changed, in reverse order, and
// release the arbiter. Returns the number of restored cvars, 0 when the caller
// does not own the arbiter.
native fn_mode_end(const mode[]);

// fn_mode_active: name of the active mode into out[] ("" when none).
// Returns 1 when a mode is active, 0 otherwise.
native fn_mode_active(out[], len);

// fn_mode_payload: payload the active mode was begun with. Returns 1 when the
// active mode's name matches mode[] (or mode is empty), 0 otherwise.
native fn_mode_payload(const mode[], out[], len);

// fn_mode_refusal: why the last fn_mode_begin() was refused. Returns 1 when
// there is a refusal to report, 0 when the last begin succeeded or none ran.
native fn_mode_refusal(out[], len);

// fn_mode_count: how many cvars the active mode has snapshotted.
native fn_mode_count();

// fn_mode_cvar: the n-th tracked cvar (0-based) and its pre-mode value.
// Returns 1 when the index exists, 0 otherwise.
native fn_mode_cvar(index, cvar[], cvar_len, prevalue[], prevalue_len);
