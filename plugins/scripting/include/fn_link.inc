#if defined _fn_link_included
	#endinput
#endif
#define _fn_link_included

/* fn_link outbox (library fn_link, 3.0 M10a). Journal-first, never blocks:
 * every push lands in memory (bounded 64, drop-oldest counted) AND the
 * append-only datadir/fn_outbox.log journal. Transport to syncd is M10b
 * (the journal is its crash-safe replay source). Returns 1 on accept,
 * 0 on invalid input. Guard calls with LibraryExists("fn_link",
 * LibType_Library). */
native fn_link_push(const kind[], const payload[]);
native fn_link_status(out[], len);
native fn_link_queued();
