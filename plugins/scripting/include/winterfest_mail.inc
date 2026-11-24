// include/winterfest_mail.inc
//
// The envelope's game-side vocabulary (workstream 15): the natives
// winterfest_mail.amxx registers for other plugins, and the two constants that
// describe what wfm_deliver() did.
//
// WHO CONSUMES THIS
//   freenova_sync.amxx (the coordinator's file) is the only intended consumer:
//   it executes the panel's queued actions, and a `wf_mail` action is turned
//   into one wfm_deliver() call. The exact action argument format is documented
//   in docs/WINTERFEST-LEVELS-MAIL.md, "The exact payloads":
//
//       arg = "<panel id>:<kind code>:<expires at>:<title, <= 40 chars>"
//
//   `kind code` is MAIL_KIND_* below, `expires at` is 0 for never, and the
//   title's ':' characters are stripped by the panel before it queues anything
//   (the action channel splits on ':').
//
//   The panel side of the mailbox is web-panel/src/winter/mail.js.
//
// THE MODULE IS OPTIONAL
//   Every native here is resolved at load time, so a plugin that includes this
//   header without winterfest_mail.amxx loaded must install the usual
//   set_native_filter() guard (src: winterfest_gifts.sma / fn_servers.sma).

#if defined _winterfest_mail_included
	#endinput
#endif

#define _winterfest_mail_included

// wfm_deliver() results. WF_MAIL_EXISTS is success too: the message was already
// in the cache, which is exactly what an idempotent delivery looks like.
#define WF_MAIL_ADDED    1
#define WF_MAIL_EXISTS   0
#define WF_MAIL_INVALID -1

// Message kinds, in the order web-panel/src/winter/mail.js MAIL_KINDS lists them
// (system, event, grant, admin). A kind is a label, never a payout: no mail
// message pays anything in Phase 1.
#define MAIL_KIND_SYSTEM 0
#define MAIL_KIND_EVENT  1
#define MAIL_KIND_GRANT  2
#define MAIL_KIND_ADMIN  3

// Unread, unexpired messages in this player's cache. Reads the vault on first
// call for the map; 0 for a player with no cache, a bot or the console.
native wfm_unread(id);

// Every cached message, read or not (for an operator view).
native wfm_count(id);

/**
 * Deliver one panel message into a player's in-game cache.
 *
 * @param id        Client index (a connected player).
 * @param panel_id  The panel's winter_mail id. Together with the source column
 *                  it is the idempotency key: delivering the same panel id
 *                  twice refreshes it, it never duplicates.
 * @param kind      MAIL_KIND_* (clamped).
 * @param created   Epoch seconds the message was written (0 = now).
 * @param expires   Epoch seconds it stops being visible (0 = never).
 * @param title     The short title the menu shows (stored truncated/sanitised).
 * @return          WF_MAIL_ADDED, WF_MAIL_EXISTS or WF_MAIL_INVALID.
 */
native wfm_deliver(id, panel_id, kind, created, expires, const title[]);

/**
 * The cache index of one delivered panel message, or -1.
 *
 * @param id        Client index.
 * @param panel_id  The panel's winter_mail id.
 * @return          Index usable with the plugin's MailShow(id, index), or -1.
 */
native wfm_find(id, panel_id);

/**
 * The panel-origin messages this player has read, for the push payload's
 * `winter.mail_read`.
 *
 * @param id      Client index.
 * @param output  Buffer filled with "id@read_at,id@read_at" (empty when none).
 * @param len     Buffer size.
 * @return        Number of characters written (0 = nothing to report).
 */
native wfm_reads(id, output[], len);
