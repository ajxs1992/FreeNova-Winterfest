#if defined _fn_state_included
	#endinput
#endif
#define _fn_state_included

/* fn_state KV (library fn_state, 3.0 M4). Sections [a-z0-9_], keys without
 * = , newline (rejected), values without newline. Writes are atomic
 * (tmp + rename); malformed file lines are skipped, never fatal.
 * _list fills a comma-joined key buffer and returns the TOTAL key count
 * (buffer may truncate: size for your admin counts). Guard calls with
 * LibraryExists("fn_state", LibType_Library). */
native fn_state_set(const section[], const key[], const value[]);
native fn_state_get(const section[], const key[], out[], len);
native fn_state_del(const section[], const key[]);
native fn_state_list(const section[], out[], len);
