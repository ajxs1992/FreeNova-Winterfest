#include <amxmodx>
#include <amxmisc>
#include <sockets>
#include <scram>

#pragma dynamic 32768

#define PLUGIN_NAME    "Postgres Engine"
#define PLUGIN_VERSION "1.0.2"
#define PLUGIN_AUTHOR  "FreeNova"

#define PG_MAX_QUEUE     48
#define PG_MAX_SQL       2048
#define PG_MAX_DATA      36
#define PG_MAX_HANDLER   48
#define PG_MAX_ROWS      256
#define PG_MAX_COLS      12
#define PG_MAX_CELL      128
#define PG_MAX_ERR       192
#define PG_BUF           8192

#define ST_IDLE          0
#define ST_CONNECTING    1
#define ST_AUTH          2
#define ST_READY         3
#define ST_BUSY          4
#define ST_DEAD          5

#define TQUERY_CONNECT_FAILED	-2
#define TQUERY_QUERY_FAILED	-1
#define TQUERY_SUCCESS		0

new g_pHost, g_pUser, g_pPass, g_pDb, g_pTimeout;
new g_sock = -1;
new g_state = ST_IDLE;
new g_in[PG_BUF];
new g_inlen;
new g_host[64], g_user[64], g_pass[64], g_db[64];
new g_port = 5434;
new Float:g_retry_at;
new Float:g_connect_at;
new g_think_n;
new g_think_on;
new g_auth_ok;
new g_fail_n;

new g_q_handler[PG_MAX_QUEUE][PG_MAX_HANDLER];
new g_q_sql[PG_MAX_QUEUE][PG_MAX_SQL];
new g_q_data[PG_MAX_QUEUE][PG_MAX_DATA];
new g_q_size[PG_MAX_QUEUE];
new g_q_plugin[PG_MAX_QUEUE];
new Float:g_q_start[PG_MAX_QUEUE];
new g_q_head, g_q_tail, g_q_count;

new g_rows[PG_MAX_ROWS][PG_MAX_COLS][PG_MAX_CELL];
new g_ncols, g_nrows, g_currow;
new g_last_err[PG_MAX_ERR];
new g_last_errnum;
new g_failstate;
new g_active = -1;

public plugin_natives()
{
	register_library("postgres");
	register_native("PG_ThreadQuery", "_PG_ThreadQuery");
	register_native("PG_NumResults", "_PG_NumResults");
	register_native("PG_MoreResults", "_PG_MoreResults");
	register_native("PG_NextRow", "_PG_NextRow");
	register_native("PG_ReadInt", "_PG_ReadInt");
	register_native("PG_ReadString", "_PG_ReadString");
	register_native("PG_IsReady", "_PG_IsReady");
}

public plugin_init()
{
	register_plugin(PLUGIN_NAME, PLUGIN_VERSION, PLUGIN_AUTHOR);
	g_pHost = register_cvar("ab_sql_host", "127.0.0.1:5434", FCVAR_PROTECTED);
	// Credentials are server-side deployment configuration, never source defaults.
	// Set ab_sql_user / ab_sql_pass in a protected config (for example
	// configs/plugins/postgres_engine.cfg) before enabling the ban database.
	g_pUser = register_cvar("ab_sql_user", "", FCVAR_PROTECTED);
	g_pPass = register_cvar("ab_sql_pass", "", FCVAR_PROTECTED);
	g_pDb = register_cvar("ab_sql_db", "bans", FCVAR_PROTECTED);
	// Seconds a single query may stay unanswered before the connection is
	// dropped and the queue failed (REVIEW.md 5.5: there was no limit at all).
	g_pTimeout = register_cvar("ab_sql_timeout", "20");
}

public plugin_cfg()
{
	set_task(0.4, "PgConnect");
}

public plugin_end()
{
	PgClose();
}

public PgConnect()
{
	get_pcvar_string(g_pHost, g_host, charsmax(g_host));
	get_pcvar_string(g_pUser, g_user, charsmax(g_user));
	get_pcvar_string(g_pPass, g_pass, charsmax(g_pass));
	get_pcvar_string(g_pDb, g_db, charsmax(g_db));

	// Fail closed and make the operator action obvious. Do not attempt an
	// unauthenticated connection or fall back to a compiled credential.
	if (!g_host[0] || !g_user[0] || !g_pass[0] || !g_db[0])
	{
		log_amx("[PG] PostgreSQL credentials are incomplete (ab_sql_host/user/pass/db). Set them in a protected server config; database is disabled.");
		g_state = ST_DEAD;
		g_retry_at = get_gametime() + PgRetryDelay();
		PgFailQueue(TQUERY_CONNECT_FAILED, "PostgreSQL credentials not configured");
		return;
	}

	g_port = 5434;
	new colon = contain(g_host, ":");
	if( colon != -1 )
	{
		g_port = str_to_num(g_host[colon + 1]);
		g_host[colon] = 0;
	}
	if( g_port <= 0 ) g_port = 5434;

	PgClose();
	new err;
	g_sock = socket_open(g_host, g_port, SOCKET_TCP, err, SOCK_NON_BLOCKING | SOCK_LIBC_ERRORS);
	if( g_sock < 0 )
	{
		g_fail_n++;
		if( g_fail_n <= 3 || (g_fail_n % 20) == 0 )
			log_amx("[PG] socket_open failed (%d) %s:%d", err, g_host, g_port);
		g_state = ST_DEAD;
		g_retry_at = get_gametime() + PgRetryDelay();
		PgFailQueue(TQUERY_CONNECT_FAILED, "socket_open failed");
		return;
	}
	g_state = ST_CONNECTING;
	g_inlen = 0;
	g_auth_ok = 0;
	ScramReset();
	g_connect_at = get_gametime();
	if( g_fail_n <= 3 || (g_fail_n % 20) == 0 )
		log_amx("[PG] connecting %s:%d db=%s user=%s", g_host, g_port, g_db, g_user);
	if( !g_think_on )
	{
		g_think_on = 1;
		set_task(1.0, "PgThinkA");
	}
}

PgClose()
{
	if( g_sock >= 0 )
	{
		socket_close(g_sock);
		g_sock = -1;
	}
	g_state = ST_IDLE;
	g_inlen = 0;
}

// Pump driver: A/B ping-pong one-shot chain (same-function reschedule
// proved unreliable on the prod build; this pattern runs every 1s).
// While SCRAM derives the key it paces faster so connect completes quickly.
public PgThinkA()
{
	PgThinkBody();
	set_task(PgThinkDelay(), "PgThinkB");
}

public PgThinkB()
{
	PgThinkBody();
	set_task(PgThinkDelay(), "PgThinkA");
}

stock Float:PgThinkDelay()
{
	return (g_scram_phase == SCRAM_COMPUTING) ? 0.1 : 1.0;
}

stock PgThinkBody()
{
	if( g_auth_ok && ++g_think_n % 300 == 0 )
		log_amx("[PG] think #%d state=%d sock=%d", g_think_n, g_state, g_sock);
	if( g_scram_phase == SCRAM_COMPUTING )
	{
		new sr = ScramThink(g_sock);
		if( sr < 0 )
		{
			PgDie(g_scram_err);
			return;
		}
		if( sr == 1 )
			log_amx("[PG] SCRAM client-final sent");
	}
	if( g_state == ST_DEAD && get_gametime() >= g_retry_at )
	{
		PgConnect();
		return;
	}
	if( g_sock < 0 ) return;

	if( g_state == ST_CONNECTING )
	{
		if( socket_is_writable(g_sock, 0) )
		{
			if( !PgSendStartup() )
			{
				PgDie("startup send failed");
				return;
			}
			g_state = ST_AUTH;
			log_amx("[PG] startup sent, waiting auth");
		}
		else if( get_gametime() - g_connect_at > 10.0 )
		{
			PgDie("connect timeout (no writability)");
			return;
		}
		return;
	}
	// SCRAM key derivation runs chunked across thinks; allow it time.
	new Float:auth_limit = (g_scram_phase == SCRAM_NONE) ? 20.0 : 180.0;
	if( g_state == ST_AUTH && get_gametime() - g_connect_at > auth_limit )
	{
		PgDie("auth timeout (no server reply)");
		return;
	}

	// REVIEW.md 5.5: a stalled backend used to wedge the engine for ever - the
	// state stayed ST_BUSY, no reply ever arrived, so no query completed, no
	// queued query was sent and every caller waited for a callback that never
	// fired (then "queue full, dropping query" for ever, i.e. no bans at all).
	// g_q_start[] has been recorded since the first version and was never read.
	// On timeout the connection is dropped and the queue failed, and the retry
	// chain reconnects.
	if( g_state == ST_BUSY && g_active >= 0 )
	{
		new Float:qlimit = float(get_pcvar_num(g_pTimeout));
		if( qlimit < 5.0 ) qlimit = 5.0;
		if( get_gametime() - g_q_start[g_active] > qlimit )
		{
			PgDie("query timeout (no reply from backend)");
			return;
		}
	}

	if( socket_is_readable(g_sock, 0) )
	{
		new space = PG_BUF - g_inlen - 1;
		if( space < 1 ) { PgDie("input overflow"); return; }
		new got = socket_recv(g_sock, g_in[g_inlen], space);
		if( got == 0 )
		{
			PgDie("peer closed");
			return;
		}
		if( got > 0 )
		{
			g_inlen += got;
			PgPump();
		}
	}

	if( g_state == ST_READY && g_q_count > 0 )
		PgSendNext();
}

bool:PgSendStartup()
{
	new pkt[512];
	new n = 4;
	pg_put_i32(pkt, n, 196608);
	n = pg_put_cstr(pkt, n, charsmax(pkt), "user");
	n = pg_put_cstr(pkt, n, charsmax(pkt), g_user);
	n = pg_put_cstr(pkt, n, charsmax(pkt), "database");
	n = pg_put_cstr(pkt, n, charsmax(pkt), g_db);
	if( n < charsmax(pkt) ) pkt[n++] = 0;
	new len = n;
	n = 0;
	pg_put_i32(pkt, n, len);
	return pg_send_raw(pkt, len);
}

PgSendPassword(const pwd[])
{
	new pkt[384];
	new n = 0;
	pkt[n++] = 'p';
	new start = n;
	n += 4;
	n = pg_put_cstr(pkt, n, charsmax(pkt), pwd);
	new body = n - start;
	new t = start;
	pg_put_i32(pkt, t, body);
	pg_send_raw(pkt, n);
}

PgSendQuery(const sql[])
{
	new pkt[PG_MAX_SQL + 16];
	new n = 0;
	pkt[n++] = 'Q';
	new start = n;
	n += 4;
	n = pg_put_cstr(pkt, n, charsmax(pkt), sql);
	new body = n - start;
	new t = start;
	pg_put_i32(pkt, t, body);
	pg_send_raw(pkt, n);
}

PgSendNext()
{
	if( g_q_count <= 0 || g_state != ST_READY ) return;
	g_active = g_q_head;
	g_nrows = 0;
	g_ncols = 0;
	g_currow = 0;
	g_last_err[0] = 0;
	g_last_errnum = 0;
	g_failstate = TQUERY_SUCCESS;
	g_state = ST_BUSY;
	PgSendQuery(g_q_sql[g_active]);
}

PgPump()
{
	while( g_inlen >= 5 )
	{
		new mlen = pg_get_i32(g_in, 1);
		if( mlen < 4 ) { PgDie("bad length"); return; }
		new total = 1 + mlen;
		if( g_inlen < total ) return;

		new type = g_in[0] & 255;
		new body = 5;
		new bodylen = mlen - 4;

		switch( type )
		{
			case 'R': PgOnAuth(body, bodylen);
			case 'E': PgOnError(body, bodylen);
			case 'Z': PgOnReady();
			case 'T': PgOnRowDesc(body, bodylen);
			case 'D': PgOnDataRow(body, bodylen);
		}

		new remain = g_inlen - total;
		for( new i = 0; i < remain; i++ )
			g_in[i] = g_in[total + i];
		g_inlen = remain;
	}
}

PgOnAuth(off, len)
{
	if( len < 4 ) return;
	new method = pg_get_i32(g_in, off);
	if( method == 0 )
	{
		g_auth_ok = 1;
		return;
	}
	if( method == 3 )
	{
		PgSendPassword(g_pass);
		return;
	}
	if( method == 5 && len >= 8 )
	{
		new salt[4];
		salt[0] = g_in[off + 4] & 255;
		salt[1] = g_in[off + 5] & 255;
		salt[2] = g_in[off + 6] & 255;
		salt[3] = g_in[off + 7] & 255;
		new payload[48];
		if( !PgMd5Password(g_pass, g_user, salt, payload, charsmax(payload)) )
		{
			PgDie("md5 password build failed");
			return;
		}
		PgSendPassword(payload);
		return;
	}
	if( method == 10 )
	{
		new mechs[128];
		new ml = len - 4;
		if( ml > 127 ) ml = 127;
		if( ml < 0 ) ml = 0;
		for( new i = 0; i < ml; i++ )
			mechs[i] = g_in[off + 4 + i] & 255;
		mechs[ml] = 0;
		if( !ScramBegin(g_sock, g_user, g_pass, mechs, ml) )
		{
			PgDie(g_scram_err);
			return;
		}
		log_amx("[PG] SCRAM-SHA-256 initial sent");
		return;
	}
	if( method == 11 )
	{
		new payload[128];
		new pl = len - 4;
		if( pl > 127 ) pl = 127;
		if( pl < 0 ) pl = 0;
		for( new i = 0; i < pl; i++ )
			payload[i] = g_in[off + 4 + i] & 255;
		if( !ScramOnServerFirst(payload, pl) )
		{
			PgDie(g_scram_err);
			return;
		}
		log_amx("[PG] SCRAM challenge accepted, deriving key (%d iters)", g_scram_iter);
		return;
	}
	if( method == 12 )
	{
		new payload[128];
		new pl = len - 4;
		if( pl > 127 ) pl = 127;
		if( pl < 0 ) pl = 0;
		for( new i = 0; i < pl; i++ )
			payload[i] = g_in[off + 4 + i] & 255;
		if( !ScramOnServerFinal(payload, pl) )
		{
			PgDie(g_scram_err);
			return;
		}
		g_auth_ok = 1;
		log_amx("[PG] SCRAM server signature verified");
		return;
	}
	formatex(g_last_err, charsmax(g_last_err), "unsupported auth method %d", method);
	PgDie(g_last_err);
}

bool:PgMd5Password(const pass[], const user[], const salt[4], out[], outmax)
{
	new combo[128], inner[34], outer[34];
	formatex(combo, charsmax(combo), "%s%s", pass, user);
	if( hash_string(combo, Hash_Md5, inner, charsmax(inner)) != 32 )
	{
		log_amx("[PG] md5 of user+password failed, cannot answer md5 auth");
		return false;
	}

	// PostgreSQL md5 auth wants md5(hex_md5(pass||user) || salt). The salt is four
	// raw bytes that may contain a NUL, so no string hash can take it and the
	// bytes go through a temporary file. REVIEW.md 5.5: that file used to be a
	// fixed datadir/pg_md5.tmp (two concurrent connects clobbered each other and
	// the name was predictable) and hash_file()'s result was ignored, so a failed
	// hash sent whatever was left in `outer` as the password. The name is now
	// unique per attempt, both hash results are checked, and every failure path
	// removes the file and fails the connection instead of guessing.
	new path[160], dir[128];
	get_datadir(dir, charsmax(dir));
	formatex(path, charsmax(path), "%s/pg_md5_%d_%d.tmp", dir, get_systime(), random_num(0, 999999));

	new f = fopen(path, "wb");
	if( !f )
	{
		log_amx("[PG] cannot create %s for the md5 exchange", path);
		return false;
	}
	for( new i = 0; i < 32; i++ )
		fputc(f, inner[i]);
	for( new i = 0; i < 4; i++ )
		fputc(f, salt[i]);
	fclose(f);

	new written = hash_file(path, Hash_Md5, outer, charsmax(outer));
	delete_file(path);
	if( written != 32 )
	{
		log_amx("[PG] hash_file wrote %d bytes for the md5 exchange, expected 32", written);
		return false;
	}
	formatex(out, outmax, "md5%s", outer);
	return true;
}

PgOnError(off, len)
{
	new msg[PG_MAX_ERR];
	new i = off;
	new end = off + len;
	while( i < end && g_in[i] )
	{
		new field = g_in[i++] & 255;
		new start = i;
		while( i < end && g_in[i] ) i++;
		copy_bytes(msg, charsmax(msg), start, i - start);
		if( field == 'M' )
			copy(g_last_err, charsmax(g_last_err), msg);
		if( i < end && g_in[i] == 0 ) i++;
	}
	if( !g_last_err[0] ) copy(g_last_err, charsmax(g_last_err), "postgres error");
	g_failstate = g_auth_ok ? TQUERY_QUERY_FAILED : TQUERY_CONNECT_FAILED;
	log_amx("[PG] error: %s", g_last_err);
}

PgOnReady()
{
	if( g_state == ST_AUTH )
	{
		g_state = ST_READY;
		g_auth_ok = 1;
		g_fail_n = 0;
		log_amx("[PG] ready");
		PgSendNext();
		return;
	}
	if( g_state == ST_BUSY && g_active != -1 )
	{
		PgFinishQuery();
		g_state = ST_READY;
		PgSendNext();
	}
}

PgOnRowDesc(off, len)
{
	if( len < 2 ) return;
	g_ncols = ((g_in[off] & 255) << 8) | (g_in[off + 1] & 255);
	if( g_ncols > PG_MAX_COLS ) g_ncols = PG_MAX_COLS;
	g_nrows = 0;
}

PgOnDataRow(off, len)
{
	if( g_nrows >= PG_MAX_ROWS ) return;
	if( len < 2 ) return;
	new cols = ((g_in[off] & 255) << 8) | (g_in[off + 1] & 255);
	new p = off + 2;
	new end = off + len;
	new maxc = cols;
	if( maxc > PG_MAX_COLS ) maxc = PG_MAX_COLS;
	for( new c = 0; c < maxc; c++ )
	{
		if( p + 4 > end ) break;
		new clen = pg_get_i32(g_in, p);
		p += 4;
		g_rows[g_nrows][c][0] = 0;
		if( clen < 0 ) continue;
		if( p + clen > end ) break;
		copy_bytes(g_rows[g_nrows][c], PG_MAX_CELL - 1, p, clen);
		p += clen;
	}
	g_nrows++;
}

PgFinishQuery()
{
	new idx = g_active;
	g_active = -1;
	g_currow = 0;
	new fail = g_failstate;
	if( fail != TQUERY_SUCCESS && !g_last_err[0] )
		copy(g_last_err, charsmax(g_last_err), "query failed");

	new fid = get_func_id(g_q_handler[idx], g_q_plugin[idx]);
	if( fid != -1 && callfunc_begin_i(fid, g_q_plugin[idx]) == 1 )
	{
		new Float:qtime = get_gametime() - g_q_start[idx];
		callfunc_push_int(fail);
		callfunc_push_int(1);
		callfunc_push_str(g_last_err, false);
		callfunc_push_int(g_last_errnum);
		callfunc_push_array(g_q_data[idx], g_q_size[idx] > 0 ? g_q_size[idx] : 1, false);
		callfunc_push_int(g_q_size[idx]);
		callfunc_push_float(qtime);
		callfunc_end();
	}
	else
		log_amx("[PG] missing callback %s plugin %d", g_q_handler[idx], g_q_plugin[idx]);

	g_q_head = (g_q_head + 1) % PG_MAX_QUEUE;
	g_q_count--;
}

PgFailQueue(fail, const err[])
{
	copy(g_last_err, charsmax(g_last_err), err);
	g_failstate = fail;

	// Fail exactly the queries that were queued when the connection died.
	// REVIEW.md §5.5: this used to loop `while (g_q_count > 0)`, but a handler
	// that re-queues on failure (the retry pattern advanced_bans uses) grows
	// g_q_count from inside the loop, so a dead database could spin here for
	// ever inside one server frame. Anything queued from here on waits in the
	// queue and is sent after the next successful connect.
	new pending = g_q_count;
	for( new n = 0; n < pending && g_q_count > 0; n++ )
	{
		g_active = g_q_head;
		g_nrows = 0;
		PgFinishQuery();
	}
}

PgDie(const why[])
{
	// Back off and quiet down when the database is simply not there:
	// a box without Postgres must not write two lines every 8 seconds.
	g_fail_n++;
	if( g_fail_n <= 3 || (g_fail_n % 20) == 0 )
		log_amx("[PG] disconnect: %s", why);
	PgClose();
	g_state = ST_DEAD;
	g_retry_at = get_gametime() + PgRetryDelay();
	PgFailQueue(TQUERY_CONNECT_FAILED, why);
}

stock Float:PgRetryDelay()
{
	if( g_fail_n < 4 ) return 8.0;
	if( g_fail_n < 8 ) return 20.0;
	return 60.0;
}

public _PG_ThreadQuery(plugin, argc)
{
	new handler[PG_MAX_HANDLER], sql[PG_MAX_SQL];
	get_string(1, handler, charsmax(handler));
	get_string(2, sql, charsmax(sql));
	new size = get_param(4);
	if( size < 0 ) size = 0;
	if( size > PG_MAX_DATA ) size = PG_MAX_DATA;

	if( g_q_count >= PG_MAX_QUEUE )
	{
		log_amx("[PG] queue full, dropping query");
		return 0;
	}
	new i = g_q_tail;
	copy(g_q_handler[i], charsmax(g_q_handler[]), handler);
	copy(g_q_sql[i], charsmax(g_q_sql[]), sql);
	if( size > 0 )
		get_array(3, g_q_data[i], size);
	g_q_size[i] = size;
	g_q_plugin[i] = plugin;
	g_q_start[i] = get_gametime();
	g_q_tail = (g_q_tail + 1) % PG_MAX_QUEUE;
	g_q_count++;
	if( g_state == ST_READY )
		PgSendNext();
	else if( g_state == ST_IDLE || (g_state == ST_DEAD && get_gametime() >= g_retry_at) )
		PgConnect();
	// else: reconnect backoff is in effect; the think loop reconnects at
	// g_retry_at and this query drains then. Avoids hammering a dead host.
	return 1;
}

public _PG_NumResults(plugin, argc)
{
	return g_nrows;
}

public _PG_MoreResults(plugin, argc)
{
	return (g_currow < g_nrows) ? 1 : 0;
}

public _PG_NextRow(plugin, argc)
{
	if( g_currow < g_nrows )
		g_currow++;
	return 1;
}

public _PG_ReadInt(plugin, argc)
{
	new col = get_param(2);
	if( g_currow >= g_nrows || col < 0 || col >= g_ncols ) return 0;
	return str_to_num(g_rows[g_currow][col]);
}

public _PG_ReadString(plugin, argc)
{
	new col = get_param(2);
	new len = get_param(4);
	if( g_currow >= g_nrows || col < 0 || col >= g_ncols )
	{
		set_string(3, "", len);
		return 0;
	}
	set_string(3, g_rows[g_currow][col], len);
	return 1;
}

public _PG_IsReady(plugin, argc)
{
	return (g_state == ST_READY || g_state == ST_BUSY) ? 1 : 0;
}

pg_put_i32(buf[], &pos, val)
{
	buf[pos++] = (val / 16777216) & 255;
	buf[pos++] = (val / 65536) & 255;
	buf[pos++] = (val / 256) & 255;
	buf[pos++] = val & 255;
}

pg_get_i32(const buf[], pos)
{
	return ((buf[pos] & 255) * 16777216) + ((buf[pos + 1] & 255) * 65536) + ((buf[pos + 2] & 255) * 256) + (buf[pos + 3] & 255);
}

pg_put_cstr(buf[], pos, max, const s[])
{
	new i;
	for( i = 0; s[i] && pos < max - 1; i++ )
		buf[pos++] = s[i];
	if( pos < max )
		buf[pos++] = 0;
	return pos;
}

bool:pg_send_raw(const buf[], len)
{
	if( g_sock < 0 ) return false;
	if( len <= 0 ) return false;
	return socket_send2(g_sock, buf, len) > 0;
}

copy_bytes(out[], max, srcpos, nbytes)
{
	new n = nbytes;
	if( n > max ) n = max;
	if( n < 0 ) n = 0;
	new i;
	for( i = 0; i < n; i++ )
		out[i] = g_in[srcpos + i] & 255;
	out[i] = 0;
	return n;
}
