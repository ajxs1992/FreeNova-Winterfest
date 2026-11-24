/* pg_sync.sma — chunk 1 + 3a + 3b: state surface, pure-Pawn PG wire client,
 *               and the file<->PG reconcile pass (push / delete / pull).
 * Reads (frozen intent): stock AB twin sync points + the four-table seed.
 * Caveats: pull applies rows via amx_addban/amx_unban (advanced_bans arg
 * order — never load next to cban's conflicting registration); MAX_LOCAL=100
 * max mirrored rows (warns on cap); web-created bans are never touched;
 * pulled history bans may add a second DB row (unbantime differs) by design.
 * Writes (frozen):       targeted DML only; zero schema/credential invention.
 * Password contract:     pg_passfile cvar -> configs/pg_pass.txt; NEVER a cvar
 *                        value, NEVER logged.
 * Chunk 3a = pg_connect_test: SSLRequest -> StartupMessage -> auth
 *            (codes 0/3/5/10/11/12 incl. full SCRAM-SHA-256 with the
 *            #include <pg_crypto> math that passed 10/10 RFC vectors live)
 *            -> lockstep simple-query probe of all four tables.
 * Framing notes (verified against PG docs + libpq source):
 *   - SASLInitialResponse mech = plain NUL-terminated string (NO inner Int32).
 *   - SASLResponse / PasswordMessage = raw/NUL string under outer Int32 only.
 */
#include <amxmodx>
#include <amxmisc>
#include <sockets>
#include <pg_crypto>

/* FHandleScramChallenge needs ~3450 cells of frame; the default AMX stack
 * overflows it, and the overflow smashes high-DAT string literals (garbled
 * log formats, dead " | D: " literal, corrupted SCRAM proof b64 -> PG
 * "Message length does not match input length."). Give the stack room. */
#pragma dynamic 65536

#define PLUGIN_NAME    "PG sync (proto)"
#define PLUGIN_VERSION "0.3.0"
#define PLUGIN_AUTHOR  "FreeNova"

#define IN_MAX      4096
#define NUM_Q       5
#define PH_AUTH     0
#define PH_QUERY    1

/* ---- cvars / state (chunk 1) ---- */
new g_pHost, g_pPort, g_pUser, g_pDb, g_pPassFile, g_pInterval, g_pDryRun;
new bool:g_bReady = false;
new g_iSock = -1;
new g_iTickTask = 0;
new g_iLastHistory = 0;
new bool:g_bDryRun = true;

/* ---- wire-client state (chunk 3a) ---- */
new g_szIn[IN_MAX];
new g_iInLen = 0;
new g_szPass[128];
new g_iPhase = PH_AUTH;
new bool:g_bAuthed = false;
new bool:g_bFailed = false;
new bool:g_bQDone = false;
new g_szErr[192];
new g_szAuthMethod[24];
new g_iScramIter = 0;
new g_szSrvSig[16];
new g_szScramCn[64];
new g_szScramBare[192];
new g_szScramExpect[160];
new g_iQSent = 0;
new g_iQZ = 0;
new bool:g_bSkipZ = false; // auth ReadyForQuery 'Z' must not count as a query result
new g_szQRes[NUM_Q][400];
new g_szQTag[NUM_Q][64];   // CommandComplete tag per slot ("DELETE 3"/"SELECT 0"...) -
                            // real row counts; DELETE/UPDATE tags carry them, rows don't

new const g_szQ[][] = {
    "SELECT version()",
    "SELECT count(*) FROM advanced_bans",
    "SELECT count(*) FROM advanced_bans_history",
    "SELECT count(*) FROM ab_recent",
    "SELECT count(*) FROM ab_asn_hits"
};

/* pg_setup session: 4 DDL + 1 verify probe, same lockstep/5 slots as g_szQ.
   Create-as types from the 2026-09-14 schema write-up (bans.php contract):
   '' never NULL, unbantime digit-string, BIGSERIAL id = SQLite rowid/bd_id. */
new bool:g_bSetup = false;
new bool:g_bCustom = false;   // pg_q: single custom statement in slot 0
new g_iNeedQ = NUM_Q;         // statements planned this session (custom=1)
new g_szQC[1024];
new const g_szSetupQ[][] = {
    "CREATE TABLE IF NOT EXISTS advanced_bans (id BIGSERIAL PRIMARY KEY, name VARCHAR(32) NOT NULL, steamid VARCHAR(35) NOT NULL DEFAULT '', ip VARCHAR(45) NOT NULL DEFAULT '', banlength INT NOT NULL DEFAULT 0, unbantime VARCHAR(32) NOT NULL DEFAULT '0', reason VARCHAR(128) NOT NULL DEFAULT '', admin_name VARCHAR(64) NOT NULL DEFAULT '', admin_steamid VARCHAR(35) NOT NULL DEFAULT '')",
    "CREATE TABLE IF NOT EXISTS advanced_bans_history (id BIGSERIAL PRIMARY KEY, action VARCHAR(8) NOT NULL, name VARCHAR(32), steamid VARCHAR(35), ip VARCHAR(45), minutes INT, reason VARCHAR(128), admin_name VARCHAR(64), admin_steamid VARCHAR(35), created BIGINT)",
    "CREATE TABLE IF NOT EXISTS ab_recent (name VARCHAR(32) NOT NULL, steamid VARCHAR(35), ip VARCHAR(45), seen BIGINT)",
    "CREATE TABLE IF NOT EXISTS ab_asn_hits (as_number VARCHAR(16) NOT NULL, banned_at BIGINT NOT NULL DEFAULT 0, minutes INT NOT NULL DEFAULT 0, reason VARCHAR(128) NOT NULL DEFAULT '')",
    "SELECT count(*) FROM advanced_bans"
};

/* ---- chunk 3b: file<->PG reconcile state ---- */
new bool:g_bSync = false;            // sync session: statements from g_szSyncQ
new g_szSyncQ[3][3840];              // push / delete / pull (FSendQuery <4000)
new g_iNeedSync = 0;                 // planned statement count this pass (1..3)
new g_iPushBatch = 0;                // absolute next row index to push
new g_iPushStart = 0, g_iPushRows = 0;
new g_iSyncTask = 9002;              // forward-queued quick pass (one-shot)
new bool:g_bPassRun = false;         // re-entry guard
new bool:g_bHadPush = false;         // this pass planned a push slice
new g_szBanFile[128], g_szSnapFile[128], g_szCurFile[128];
new g_szLastSync[192];               // last pass summary (pg_status)

#define PUSH_BATCH 6
#define MAX_LOCAL  100

/* local file rows (mirror of advanced_bans LoadBans parse) */
new g_nLocal = 0;
new g_lSid[MAX_LOCAL][35], g_lName[MAX_LOCAL][32], g_lUt[MAX_LOCAL][32];
new g_lRsn[MAX_LOCAL][128], g_lAn[MAX_LOCAL][32], g_lAs[MAX_LOCAL][35];
new g_lLen[MAX_LOCAL];

/* snapshot triples (sid|unbantime|reason) = what we already synced */
new g_nSnap = 0;
new g_sSid[MAX_LOCAL][35], g_sUt[MAX_LOCAL][32], g_sRsn[MAX_LOCAL][128];
new g_sLen[MAX_LOCAL];

public plugin_init() {
    register_plugin(PLUGIN_NAME, PLUGIN_VERSION, PLUGIN_AUTHOR);
    g_pHost     = register_cvar("pg_host", "127.0.0.1");
    g_pPort     = register_cvar("pg_port", "5434");
    g_pUser     = register_cvar("pg_user", "srv_cmuoek_mp4dqyow");
    g_pDb       = register_cvar("pg_db", "srv_kv0ewyvjf8hk");
    g_pPassFile = register_cvar("pg_passfile", "addons/amxmodx/configs/pg_pass.txt");
    g_pInterval = register_cvar("pg_interval", "60");
    g_pDryRun   = register_cvar("pg_dryrun", "1");
    register_concmd("pg_status", "concmd_Status", ADMIN_BAN, "sync state + last error");
    register_concmd("pg_sync_now", "concmd_Now", ADMIN_BAN, "single reconcile pass");
    register_concmd("pg_connect_test", "concmd_ConnectTest", ADMIN_BAN, "probe PG wire: TCP/SSL/auth/counts");
    register_concmd("pg_setup", "concmd_Setup", ADMIN_BAN, "create the 4 schema tables via PG");
    register_concmd("pg_q", "concmd_Q", ADMIN_RCON, "pg_q <sql> - run one custom statement (RCON-only, logged)");
    // pg_test_hashes lives ONLY in pg_crypto_test.sma (no duplicate registration).
}

public plugin_cfg() {
    g_bDryRun = get_pcvar_num(g_pDryRun) != 0;
    new Float:f = get_pcvar_float(g_pInterval);
    if (f < 15.0) f = 15.0;
    g_iTickTask = 9001;
    set_task(f, "task_Tick", g_iTickTask, _, _, "b");
    FBuildFiles();
    FLoadCursor();
    FLoadSnap();
}

public task_Tick() {
    FSyncPass(0);   // periodic reconcile (pg_interval)
}

/* advanced_bans fires this AFTER AddBan() appended the file row (live bans).
   Offline amx_addban skips the forward -> the periodic tick covers those. */
public advanced_bans_player_banned(target, admin, length, const reason[]) {
    if (!task_exists(g_iSyncTask)) set_task(1.0, "task_SyncSoon", g_iSyncTask);
    return PLUGIN_CONTINUE;
}

public task_SyncSoon() {
    FSyncPass(0);
}

public concmd_Status(id) {
    console_print(id, "[PGS] ready=%d dryrun=%d lasthist=%d sock=%d batch=%d local=%d snap=%d",
        g_bReady, g_bDryRun, g_iLastHistory, g_iSock, g_iPushBatch, g_nLocal, g_nSnap);
    if (g_szLastSync[0]) console_print(id, "[PGS] last: %s", g_szLastSync);
    return PLUGIN_HANDLED;
}

public concmd_Now(id) {
    FSyncPass(id);
    return PLUGIN_HANDLED;
}

/* Create the 4 tables (synchronous; g_bSetup only read inside ConnectTest). */
public concmd_Setup(id) {
    g_bSetup = true;
    concmd_ConnectTest(id);
    g_bSetup = false;
    return PLUGIN_HANDLED;
}

/* Run one arbitrary statement (diagnostics; result in q0). */
public concmd_Q(id) {
    if (!read_args(g_szQC, charsmax(g_szQC))) g_szQC[0] = 0;
    trim(g_szQC);
    if (!g_szQC[0]) {
        console_print(id, "[PGS] usage: pg_q <sql>");
        return PLUGIN_HANDLED;
    }
    log_amx("[PGS] custom query by #%d (RCON-only)", id);
    g_bCustom = true;
    concmd_ConnectTest(id);
    g_bCustom = false;
    return PLUGIN_HANDLED;
}

/* ---------------- chunk 3a: connect probe command ---------------- */
public concmd_ConnectTest(id) {
    new host[64], user[64], db[64], passpath[128];
    get_pcvar_string(g_pHost, host, charsmax(host));
    get_pcvar_string(g_pUser, user, charsmax(user));
    get_pcvar_string(g_pDb, db, charsmax(db));
    get_pcvar_string(g_pPassFile, passpath, charsmax(passpath));
    new port = get_pcvar_num(g_pPort);

    FCleanup();
    g_iInLen = 0;
    g_bAuthed = false; g_bFailed = false; g_bQDone = false;
    g_iPhase = PH_AUTH;
    g_iQSent = 0; g_iQZ = 0; g_iScramIter = 0;
    g_bSkipZ = false;
    // one Query message = one ReadyForQuery, even with multiple ';'-statements inside
    g_iNeedQ = g_bSync ? g_iNeedSync : (g_bCustom ? 1 : NUM_Q);
    g_szErr[0] = 0;
    copy(g_szAuthMethod, charsmax(g_szAuthMethod), "-");
    copy(g_szSrvSig, charsmax(g_szSrvSig), "-");
    g_szScramCn[0] = 0; g_szScramBare[0] = 0; g_szScramExpect[0] = 0;
    for (new i = 0; i < NUM_Q; i++) { g_szQRes[i][0] = 0; g_szQTag[i][0] = 0; }

    if (!FLoadPass(passpath)) {
        console_print(id, "[PGS] FAIL passfile unreadable: %s", passpath);
        log_amx("[PGS] connect FAIL: passfile unreadable (%s)", passpath);
        return PLUGIN_HANDLED;
    }

    new err = 0;
    g_iSock = socket_open(host, port, SOCKET_TCP, err, 0);
    if (g_iSock < 0 || err != SOCK_ERROR_OK) {
        console_print(id, "[PGS] FAIL socket_open err=%d", err);
        log_amx("[PGS] connect FAIL socket_open err=%d", err);
        if (g_iSock >= 0) socket_close(g_iSock);
        g_iSock = -1;
        return PLUGIN_HANDLED;
    }

    /* Wall-clock deadline: get_gametime() FROZEN while this synchronous command
       blocks all server frames — game-time timeouts can never fire (hung server). */
    new t0 = get_systime();

    /* SSLRequest: 8 bytes (Int32 8, Int32 80877103); expect single 'N'. */
    new hbuf[8];
    FPutI32(hbuf, 0, 8);
    FPutI32(hbuf, 4, 80877103);
    if (FSend(hbuf, 8) < 0) {
        copy(g_szErr, charsmax(g_szErr), "send SSLRequest failed");
        FReportFail(id, "ssl-req", t0); FCleanup(); return PLUGIN_HANDLED;
    }
    new b = 0, tSsl = get_systime() + 4;
    while (!b && !g_bFailed && get_systime() < tSsl) {
        if (!socket_is_readable(g_iSock, 400000)) continue;
        new n = socket_recv(g_iSock, g_szIn, IN_MAX - 1);
        if (n <= 0) {
            g_bFailed = true;
            copy(g_szErr, charsmax(g_szErr), "connection closed during SSL negotiation");
            break;
        }
        g_iInLen = n;
        b = g_szIn[0] & 0xFF;
    }
    if (g_bFailed || !b) {
        if (!g_bFailed) copy(g_szErr, charsmax(g_szErr), "no SSL reply (timeout)");
        FReportFail(id, "ssl", t0); FCleanup(); return PLUGIN_HANDLED;
    }
    if (b == 'S') {
        copy(g_szErr, charsmax(g_szErr), "server requires SSL — needs sslmode=disable or TLS support");
        FReportFail(id, "ssl", t0); FCleanup(); return PLUGIN_HANDLED;
    }
    if (b != 'N') {
        format(g_szErr, charsmax(g_szErr), "bad SSL reply byte %d", b);
        FReportFail(id, "ssl", t0); FCleanup(); return PLUGIN_HANDLED;
    }
    g_iInLen = 0;

    /* StartupMessage: Int32 len | Int32 196608 | user\0<u>\0database\0<d>\0\0 */
    new ubuf[512];
    new pos = 8;
    FPutI32(ubuf, 4, 196608);   // protocol 3.0 at bytes 4-7 (was missing -> "user" read as version)
    pos = FPutStrZ(ubuf, pos, "user");
    pos = FPutStrZ(ubuf, pos, user);
    pos = FPutStrZ(ubuf, pos, "database");
    pos = FPutStrZ(ubuf, pos, db);
    ubuf[pos++] = 0;
    FPutI32(ubuf, 0, pos);
    if (FSend(ubuf, pos) < 0) {
        copy(g_szErr, charsmax(g_szErr), "send Startup failed");
        FReportFail(id, "startup", t0); FCleanup(); return PLUGIN_HANDLED;
    }

    /* ---- AUTH PHASE ---- */
    new tAuth = get_systime() + 6;
    while (!g_bAuthed && !g_bFailed && get_systime() < tAuth)
        FStep();
    if (g_bFailed) {
        FReportFail(id, "auth", t0); FCleanup(); return PLUGIN_HANDLED;
    }
    if (!g_bAuthed) {
        copy(g_szErr, charsmax(g_szErr), "auth timeout");
        FReportFail(id, "auth", t0); FCleanup(); return PLUGIN_HANDLED;
    }

    /* ---- QUERY PHASE (lockstep: next Q only after previous Z) ---- */
    new tQ = get_systime() + 6;
    while (!g_bQDone && !g_bFailed && get_systime() < tQ) {
        if (g_iQSent == g_iQZ && g_iQSent < g_iNeedQ) {
            new ok;
            if (g_bCustom) ok = FSendQuery(g_szQC);
            else if (g_bSetup) ok = FSendQuery(g_szSetupQ[g_iQSent]);
            else if (g_bSync) ok = FSendQuery(g_szSyncQ[g_iQSent]);
            else ok = FSendQuery(g_szQ[g_iQSent]);
            if (ok < 0) {
                copy(g_szErr, charsmax(g_szErr), "send Query failed");
                g_bFailed = true;
                break;
            }
            g_iQSent++;
            continue;
        }
        FStep();
    }
    if (g_bFailed) {
        FReportFail(id, "query", t0); FCleanup(); return PLUGIN_HANDLED;
    }
    if (!g_bQDone) {
        copy(g_szErr, charsmax(g_szErr), "query timeout");
        FReportFail(id, "query", t0); FCleanup(); return PLUGIN_HANDLED;
    }

    /* ---- SUCCESS ---- */
    g_bReady = true;
    new ms = (get_systime() - t0) * 1000;
    console_print(id, "[PGS] tcp=OK ssl=N auth=%s iter=%d srvsig=%s (%d ms)",
        g_szAuthMethod, g_iScramIter, g_szSrvSig, ms);
    if (g_bSetup) {
        new bool:fail = false;
        for (new i = 0; i < NUM_Q; i++) {
            if (!g_szQRes[i][0]) copy(g_szQRes[i], charsmax(g_szQRes[]), "OK");
            if (contain(g_szQRes[i], "ERR:") == 0) fail = true;
            console_print(id, "[PGS] setup q%d = %s", i + 1, g_szQRes[i]);
        }
        if (fail) {
            console_print(id, "[PGS] SETUP FAIL");
            log_amx("[PGS] setup FAIL %d ms q0=%s q1=%s q2=%s q3=%s",
                ms, g_szQRes[0], g_szQRes[1], g_szQRes[2], g_szQRes[3]);
        } else {
            console_print(id, "[PGS] SETUP DONE (last count=%s)", g_szQRes[4]);
            log_amx("[PGS] setup DONE %d ms count=%s", ms, g_szQRes[4]);
        }
    } else if (g_bCustom) {
        if (!g_szQRes[0][0]) copy(g_szQRes[0], charsmax(g_szQRes[]), "(empty)");
        console_print(id, "[PGS] q0 = %s", g_szQRes[0]);
        log_amx("[PGS] custom OK %d ms = %s", ms, g_szQRes[0]);
    } else if (g_bSync) {
        FSyncResult(id);
    } else {
        for (new i = 0; i < NUM_Q; i++)
            console_print(id, "[PGS] q%d %s = %s", i + 1, g_szQ[i], g_szQRes[i]);
        console_print(id, "[PGS] CONNECT OK");
        log_amx("[PGS] connect OK %d ms auth=%s iter=%d bans=%s",
            ms, g_szAuthMethod, g_iScramIter, g_szQRes[1]);
    }
    FCleanup();
    return PLUGIN_HANDLED;
}

/* ---------------- framing helpers ---------------- */
stock FPutI32(buf[], pos, val) {
    buf[pos]     = (val >>> 24) & 0xff;
    buf[pos + 1] = (val >>> 16) & 0xff;
    buf[pos + 2] = (val >>> 8) & 0xff;
    buf[pos + 3] = val & 0xff;
    return pos + 4;
}

stock FGetI32(buf[], pos) {
    return ((buf[pos] & 0xff) << 24) | ((buf[pos + 1] & 0xff) << 16)
         | ((buf[pos + 2] & 0xff) << 8) | (buf[pos + 3] & 0xff);
}

stock FPutStrZ(buf[], pos, const s[]) {
    new i = 0;
    while (s[i]) buf[pos++] = s[i++];
    buf[pos++] = 0;
    return pos;
}

/* exactly 8 lowercase hex digits + NUL (needs maxlen >= 8). */
stock FHex8(num, out[], maxlen) {
    if (maxlen < 8) { out[0] = 0; return; }
    new const tab[] = "0123456789abcdef";
    for (new i = 7; i >= 0; i--) {
        out[i] = tab[num & 0xf];
        num = num >>> 4;
    }
    out[8] = 0;
}

stock FSend(const buf[], len) {
    if (g_iSock < 0) return -1;
    new off = 0, guard = 0;
    while (off < len && guard++ < 32) {
        new n = socket_send2(g_iSock, buf[off], len - off);
        if (n <= 0) return -1;
        off += n;
    }
    return (off == len) ? 0 : -1;
}

stock FConsume() {
    new total = 1 + FGetI32(g_szIn, 1);
    new rem = g_iInLen - total;
    for (new i = 0; i < rem; i++) g_szIn[i] = g_szIn[total + i];
    g_iInLen = rem;
}

stock bool:FLoadPass(const path[]) {
    g_szPass[0] = 0;
    new f = fopen(path, "rt");
    if (!f) return false;
    fgets(f, g_szPass, charsmax(g_szPass));
    fclose(f);
    trim(g_szPass);
    return g_szPass[0] != 0;
}

stock FCleanup() {
    if (g_iSock >= 0) {
        socket_close(g_iSock);
        g_iSock = -1;
    }
}

stock FReportFail(id, const what[], t0) {
    new ms = (get_systime() - t0) * 1000;
    if (!g_szErr[0]) copy(g_szErr, charsmax(g_szErr), what);
    console_print(id, "[PGS] FAIL after %d ms (auth=%s) at %s: %s",
        ms, g_szAuthMethod, what, g_szErr);
    log_amx("[PGS] connect FAIL %d ms auth=%s at %s err=%s",
        ms, g_szAuthMethod, what, g_szErr);
}

/* ---------------- recv pump + dispatch ---------------- */
stock FStep() {
    if (!socket_is_readable(g_iSock, 400000)) return;
    new n = socket_recv(g_iSock, g_szIn[g_iInLen], IN_MAX - 1 - g_iInLen);
    if (n == 0) {
        g_bFailed = true;
        copy(g_szErr, charsmax(g_szErr), "connection closed by server");
        return;
    }
    if (n < 0) {
        g_bFailed = true;
        copy(g_szErr, charsmax(g_szErr), "socket_recv error");
        return;
    }
    g_iInLen += n;
    if (g_iInLen >= IN_MAX - 1) {
        g_bFailed = true;
        copy(g_szErr, charsmax(g_szErr), "recv buffer full");
        return;
    }
    while (!g_bFailed) {
        if (g_iInLen < 5) return;
        new mlen = FGetI32(g_szIn, 1);
        if (mlen < 4 || mlen >= IN_MAX - 1) {
            g_bFailed = true;
            copy(g_szErr, charsmax(g_szErr), "bad frame length");
            return;
        }
        if (g_iInLen < 1 + mlen) return; // incomplete — wait for more
        new ret = FDispatch();
        FConsume();
        if (ret < 0) {
            g_bFailed = true;
        }
    }
}

stock FDispatch() {
    new t = g_szIn[0] & 0xff;
    if (g_iPhase == PH_AUTH) return FAuthMsg(t);
    return FQueryMsg(t);
}

stock FAuthMsg(t) {
    new mlen = FGetI32(g_szIn, 1);
    if (t == 'R') return FAuthR(mlen);
    if (t == 'E') {
        FParseErr(mlen);
        return -1;
    }
    // S (ParameterStatus), K (BackendKeyData), N (Notice), Z: ignore pre-auth
    return 0;
}

stock FAuthR(mlen) {
    new code = FGetI32(g_szIn, 5);
    if (code == 0) {
        g_bAuthed = true;
        g_iPhase = PH_QUERY;
        g_bSkipZ = true; // the ReadyForQuery 'Z' still to arrive is auth's, not a query result
        if (g_szAuthMethod[0] == '-')
            copy(g_szAuthMethod, charsmax(g_szAuthMethod), "trust/peer");
    } else if (code == 3) {
        copy(g_szAuthMethod, charsmax(g_szAuthMethod), "cleartext");
        if (FSendPasswordStr(g_szPass) < 0) {
            copy(g_szErr, charsmax(g_szErr), "send password failed");
            return -1;
        }
    } else if (code == 5) {
        copy(g_szAuthMethod, charsmax(g_szAuthMethod), "md5");
        if (FSendMd5() < 0) return -1;
    } else if (code == 10) {
        if (!FHasMech(mlen)) {
            copy(g_szErr, charsmax(g_szErr), "SCRAM-SHA-256 not in mech list");
            return -1;
        }
        copy(g_szAuthMethod, charsmax(g_szAuthMethod), "scram-sha-256");
        if (FSendSaslInitial() < 0) return -1;
    } else if (code == 11) {
        if (FHandleScramChallenge(mlen) < 0) return -1;
    } else if (code == 12) {
        if (FHandleSrvFinal(mlen) < 0) return -1;
    } else {
        format(g_szErr, charsmax(g_szErr), "unsupported auth code %d", code);
        return -1;
    }
    return 0;
}

/* ---------------- auth senders ---------------- */
stock bool:FHasMech(mlen) {
    new mech[192], n = 0;
    for (new i = 9; i < 1 + mlen && i < g_iInLen && n < charsmax(mech); i++) {
        new b = g_szIn[i] & 0xff;
        mech[n++] = b ? b : ' ';
    }
    mech[n] = 0;
    return contain(mech, "SCRAM-SHA-256") >= 0;
}

/* PasswordMessage (cleartext/md5): 'p' | Int32 | String-with-NUL. */
stock FSendPasswordStr(const s[]) {
    new buf[512], n = strlen(s);
    if (n > 480) return -1;
    buf[0] = 'p';
    FPutI32(buf, 1, 4 + n + 1);
    for (new i = 0; i < n; i++) buf[5 + i] = s[i];
    buf[5 + n] = 0;
    return FSend(buf, 6 + n);
}

/* SASLResponse (SCRAM client-final): 'p' | Int32 | raw bytes, NO trailing
 * NUL — PG checks inputlen == strlen(input) (auth-scram.c:380), so a NUL
 * inside the length trips "Message length does not match input length." */
stock FSendSaslResponse(const s[]) {
    new buf[512], n = strlen(s);
    if (n > 480) return -1;
    buf[0] = 'p';
    FPutI32(buf, 1, 4 + n);
    for (new i = 0; i < n; i++) buf[5 + i] = s[i];
    return FSend(buf, 5 + n);
}

/* md5(md5(password || salt)hex || username) hex, prefixed "md5" (auth code 5). */
stock FSendMd5() {
    new cat[192], d1[16], d2[16], h1[33], h2[33], u[64], inner[96], pw[48];
    new pl = strlen(g_szPass);
    if (pl > 160) {
        copy(g_szErr, charsmax(g_szErr), "password too long for md5 path");
        return -1;
    }
    copy(cat, charsmax(cat), g_szPass);
    for (new i = 0; i < 4; i++) cat[pl + i] = g_szIn[9 + i] & 0xff;
    MD5_Raw(cat, pl + 4, d1);
    HexEncode(d1, 16, h1, charsmax(h1));
    get_pcvar_string(g_pUser, u, charsmax(u));
    format(inner, charsmax(inner), "%s%s", h1, u);
    MD5_Raw(inner, strlen(inner), d2);
    HexEncode(d2, 16, h2, charsmax(h2));
    format(pw, charsmax(pw), "md5%s", h2);
    if (FSendPasswordStr(pw) < 0) {
        copy(g_szErr, charsmax(g_szErr), "send md5 response failed");
        return -1;
    }
    return 0;
}

/* SASLInitialResponse: 'p' | Int32 body | mech NUL | Int32 cflen | cf
 * (mech is a PLAIN null-terminated string — no inner Int32, verified vs libpq). */
stock FSendSaslInitial() {
    new const mech[] = "SCRAM-SHA-256";
    new u[64], cf[320], buf[512];
    get_pcvar_string(g_pUser, u, charsmax(u));
    if (!u[0]) {
        copy(g_szErr, charsmax(g_szErr), "pg_user empty");
        return -1;
    }
    // manual 8-digit lowercase hex — no %x format gamble (amxx format spec unclear)
    new h1[9], h2[9];
    FHex8(random_num(0, 0x7fffffff), h1, charsmax(h1));
    FHex8(random_num(0, 0x7fffffff), h2, charsmax(h2));
    format(g_szScramCn, charsmax(g_szScramCn), "rOprNGfwEbeRWgb%s%s", h1, h2);
    format(g_szScramBare, charsmax(g_szScramBare), "n=%s,r=%s", u, g_szScramCn);
    format(cf, charsmax(cf), "n,,%s", g_szScramBare);
    new m = strlen(mech), cfl = strlen(cf);
    buf[0] = 'p';
    FPutI32(buf, 1, 4 + (m + 1) + 4 + cfl);  // len INCLUDES the 4 length bytes
    new pos = 5;
    for (new i = 0; i < m; i++) buf[pos++] = mech[i];
    buf[pos++] = 0;
    pos = FPutI32(buf, pos, cfl);
    for (new i = 0; i < cfl; i++) buf[pos++] = cf[i];
    if (FSend(buf, pos) < 0) {
        copy(g_szErr, charsmax(g_szErr), "send SASLInitialResponse failed");
        return -1;
    }
    return 0;
}

/* server-first (auth code 11): r=...,s=...,i=... -> SaltedPassword/proof. */
stock FHandleScramChallenge(mlen) {
    new sl = mlen - 4;
    if (sl < 16 || sl > 600) {
        copy(g_szErr, charsmax(g_szErr), "bad server-first length");
        return -1;
    }
    new sr[640];
    for (new i = 0; i < sl; i++) sr[i] = g_szIn[9 + i] & 0xff;
    sr[sl] = 0;

    new lr[192], mid[192], rest[256], ir[64];
    strtok(sr, lr, charsmax(lr), rest, charsmax(rest), ',');
    strtok(rest, mid, charsmax(mid), ir, charsmax(ir), ',');
    if (lr[0] != 'r' || mid[0] != 's' || ir[0] != 'i') {
        copy(g_szErr, charsmax(g_szErr), "bad server-first fields");
        return -1;
    }
    new sn[160], salt64[128];
    copy(sn, charsmax(sn), lr[2]);
    copy(salt64, charsmax(salt64), mid[2]);
    new iters = str_to_num(ir[2]);
    if (iters < 1 || iters > 1000000) {
        copy(g_szErr, charsmax(g_szErr), "bad SCRAM iteration count");
        return -1;
    }
    g_iScramIter = iters;
    new cnl = strlen(g_szScramCn);
    if (strncmp(sn, g_szScramCn, cnl) != 0) {
        copy(g_szErr, charsmax(g_szErr), "server nonce does not extend ours");
        return -1;
    }

    new salt[64];
    new saltl = B64_Decode(salt64, salt, charsmax(salt));
    if (saltl <= 0) {
        copy(g_szErr, charsmax(g_szErr), "SCRAM salt b64 decode failed");
        return -1;
    }
    new salted[32];
    if (!SCRAM_Hi(g_szPass, strlen(g_szPass), salt, saltl, iters, salted)) {
        copy(g_szErr, charsmax(g_szErr), "SCRAM_Hi failed");
        return -1;
    }
    new ck[32], sk[32], stored[32], csig[32], ssig[32], proof[32];
    HMAC_SHA256(salted, 32, "Client Key", 10, ck);
    HMAC_SHA256(salted, 32, "Server Key", 10, sk);
    SHA256_Raw(ck, 32, stored);
    new amsg[1024];
    format(amsg, charsmax(amsg), "%s,%s,c=biws,r=%s", g_szScramBare, sr, sn);
    HMAC_SHA256(stored, 32, amsg, strlen(amsg), csig);
    for (new i = 0; i < 32; i++) proof[i] = ck[i] ^ csig[i];
    HMAC_SHA256(sk, 32, amsg, strlen(amsg), ssig);
    B64_Encode(ssig, 32, g_szScramExpect, charsmax(g_szScramExpect));
    new pb64[64];
    B64_Encode(proof, 32, pb64, charsmax(pb64));
    // diag (temporary): compare against python reference — no password bytes
    // scram-diag passlen/iters raw lines removed after verification
    // scram-diag sr/pb64 lines removed after verification
    new fin[400];
    format(fin, charsmax(fin), "c=biws,r=%s,p=%s", sn, pb64);
    if (FSendSaslResponse(fin) < 0) {
        copy(g_szErr, charsmax(g_szErr), "send SASLResponse failed");
        return -1;
    }
    // client-final sent diag removed after verification
    return 0;
}

/* server-final (auth code 12): v=<sig> verify or e=<error>. */
stock FHandleSrvFinal(mlen) {
    new sl = mlen - 8; // payload = frame(1+mlen) - 'R'(1) - len(4) - code(4)
    if (sl < 2 || sl > 400) {
        copy(g_szErr, charsmax(g_szErr), "bad server-final length");
        return -1;
    }
    new sf[420];
    for (new i = 0; i < sl; i++) sf[i] = g_szIn[9 + i] & 0xff;
    sf[sl] = 0;
    if (sf[0] == 'e') {
        format(g_szErr, charsmax(g_szErr), "server-final error: %s", sf[2]);
        return -1;
    }
    if (strncmp(sf, "v=", 2) != 0) {
        copy(g_szErr, charsmax(g_szErr), "bad server-final token");
        return -1;
    }
    new sig[192];
    new sp = 0;
    for (new i = 2; sf[i] && sp < charsmax(sig); i++) sig[sp++] = sf[i];
    sig[sp] = 0;
    if (g_szScramExpect[0] && strlen(sig) == strlen(g_szScramExpect)
        && strncmp(sig, g_szScramExpect, strlen(sig)) == 0)
        copy(g_szSrvSig, charsmax(g_szSrvSig), "OK");
    else {
        copy(g_szSrvSig, charsmax(g_szSrvSig), "MISMATCH");
        log_amx("[PGS] srvsig-srv=[%s] expect=[%s] (sl=%d el=%d)",
            sig, g_szScramExpect, strlen(sig), strlen(g_szScramExpect));  // diag
    }
    return 0;
}

/* ---------------- query phase (simple protocol, lockstep) ---------------- */
stock FSendQuery(const q[]) {
    new buf[4096], n = strlen(q);
    if (n > 4000) return -1;
    buf[0] = 'Q';
    FPutI32(buf, 1, 4 + n + 1);
    for (new i = 0; i < n; i++) buf[5 + i] = q[i];
    buf[5 + n] = 0;
    return FSend(buf, 6 + n);
}

stock FQueryMsg(t) {
    new mlen = FGetI32(g_szIn, 1);
    if (t == 'D') {
        FParseRow(mlen);
    } else if (t == 'E') {
        // per-query error: record in the current slot, keep going — 'Z' still follows
        FParseErr(mlen);
        copy(g_szQRes[g_iQZ], charsmax(g_szQRes[]), "ERR: ");
        add(g_szQRes[g_iQZ], charsmax(g_szQRes[]), g_szErr);
        g_szErr[0] = 0;
    } else if (t == 'Z') {
        if (g_bSkipZ) {
            g_bSkipZ = false; // auth ReadyForQuery — do not count as query completion
            return 0;
        }
        g_iQZ++;
        if (g_iQZ >= g_iNeedQ) g_bQDone = true;
    } else if (t == 'T') {
        g_szQRes[g_iQZ][0] = 0; // RowDescription: reset slot for (multi-row) data
    } else if (t == 'C' && g_iQZ < NUM_Q) {
        // CommandComplete: NUL-terminated tag ("DELETE n", "SELECT n", "INSERT 0 n").
        // DELETE/SELECT-with-0-rows return no DataRow, so g_szQRes stays empty for
        // them - the tag is the ONLY place the affected-row count exists. Kept in a
        // separate array so pg_q's "(empty) = success" display is untouched.
        // Copy bounded by mlen (payload ends at 4+mlen) - never trust an unbounded read.
        new i = 0, end = 4 + mlen;
        if (end > g_iInLen) end = g_iInLen;
        while (i < charsmax(g_szQTag[]) && 5 + i < end && g_szIn[5 + i]) {
            g_szQTag[g_iQZ][i] = g_szIn[5 + i];
            i++;
        }
        g_szQTag[g_iQZ][i] = 0;
    }
    // S/K/N: ignored
    return 0;
}

stock FParseRow(mlen) {
    if (g_iQZ >= NUM_Q) return;
    if (mlen < 6) return;
    new nf = ((g_szIn[5] & 0xff) << 8) | (g_szIn[6] & 0xff);
    if (nf < 1) {
        copy(g_szQRes[g_iQZ], charsmax(g_szQRes[]), "(no cols)");
        return;
    }
    new dlen = FGetI32(g_szIn, 7);
    new cap = charsmax(g_szQRes[]);
    new n = strlen(g_szQRes[g_iQZ]); // rows append (pg_q multi-row); T cleared it first
    if (n) { // separate rows with ", "
        if (n + 2 >= cap) return;
        g_szQRes[g_iQZ][n++] = ',';
        g_szQRes[g_iQZ][n++] = ' ';
    }
    if (dlen < 0) {
        if (n + 4 > cap) { g_szQRes[g_iQZ][n] = 0; return; }
        g_szQRes[g_iQZ][n++] = 'N'; g_szQRes[g_iQZ][n++] = 'U';
        g_szQRes[g_iQZ][n++] = 'L'; g_szQRes[g_iQZ][n++] = 'L';
        g_szQRes[g_iQZ][n] = 0;
        return;
    }
    if (dlen > cap - n) dlen = cap - n;
    for (new i = 0; i < dlen; i++) {
        new b = g_szIn[11 + i] & 0xff;
        if (!b) break;
        g_szQRes[g_iQZ][n++] = b;
    }
    g_szQRes[g_iQZ][n] = 0;
    if (!n) copy(g_szQRes[g_iQZ], charsmax(g_szQRes[]), "(empty)");
}

/* ErrorResponse: grab M (message) and D (detail — PG hides the exact check there).
   NOTE: frame deliberately tiny — big local arrays here caused native args to read
   stack residue (fin) instead of the pushed values. Buffers are globals. */
new g_szPeMsg[160], g_szPeDet[160];
stock FParseErr(mlen) {
    new eend = 1 + mlen;
    if (eend > g_iInLen) eend = g_iInLen;
    g_szPeMsg[0] = 0;
    g_szPeDet[0] = 0;
    new pos = 5, code = 0, n = 0, b = 0;
    while (pos < eend && g_szIn[pos] != 0) {
        code = g_szIn[pos] & 0xff;
        pos++;
        n = 0;
        while (pos < eend && g_szIn[pos] != 0) {
            b = g_szIn[pos] & 0xff;
            if (code == 'M') {
                if (n < 159) { g_szPeMsg[n++] = b; g_szPeMsg[n] = 0; }
            } else if (code == 'D') {
                if (n < 159) { g_szPeDet[n++] = b; g_szPeDet[n] = 0; }
            }
            pos++;
        }
        pos++; // skip field NUL
    }
    if (g_szPeMsg[0]) copy(g_szErr, charsmax(g_szErr), g_szPeMsg);
    else copy(g_szErr, charsmax(g_szErr), "unknown server error");
    if (g_szPeDet[0]) {
        add(g_szErr, charsmax(g_szErr), " | D: ");
        add(g_szErr, charsmax(g_szErr), g_szPeDet);
    }
}

/* ==================== chunk 3b: file <-> PG reconcile ==================== */
new g_bDelTrunc = false;         // pending delete rows remain unswept this pass
new bool:g_sSwept[MAX_LOCAL];    // snapshot rows swept since last snapshot save
new g_iDelPlan[MAX_LOCAL];       // snapshot indices planned this pass
new g_iDelPlanN = 0;
new g_iPlanSize = 0;             // ban-file size captured at plan time
new g_iCycSize = 0;              // signature: file size when last full push cycle completed
new g_iCycRows = -1;             // signature: row count then; -1 = no cycle completed yet

stock FBuildFiles() {
    if (g_szBanFile[0]) return;
    new dd[128];
    get_datadir(dd, charsmax(dd));
    formatex(g_szBanFile, charsmax(g_szBanFile), "%s/advanced_bans.txt", dd);
    formatex(g_szSnapFile, charsmax(g_szSnapFile), "%s/pg_sync_snap.txt", dd);
    formatex(g_szCurFile, charsmax(g_szCurFile), "%s/pg_sync_cursor.txt", dd);
}

/* SQL string literal: double single-quotes; drop chr(1) row-concat artifacts. */
stock FSQLStr(const src[], dst[], maxlen) {
    new j = 0;
    for (new i = 0; src[i]; i++) {
        if (src[i] == 1) continue;
        if (src[i] == 39) {
            if (j + 2 > maxlen) break;
            dst[j++] = 39;
            dst[j++] = 39;
        } else {
            if (j >= maxlen) break;
            dst[j++] = src[i];
        }
    }
    dst[j] = 0;
}

/* Extract src[a..b) into dst. */
stock FSub(const src[], dst[], a, b, maxlen) {
    new j = 0;
    for (new i = a; i < b && j < maxlen; i++) dst[j++] = src[i];
    dst[j] = 0;
}

/* Make a token safe inside a double-quoted server_cmd argument
   (also flattens CR/LF so AddBan cannot split the ban-file line). */
stock FStripQ(s[]) {
    for (new i = 0; s[i]; i++) {
        if (s[i] == 34) s[i] = 39;
        else if (s[i] == 10 || s[i] == 13) s[i] = 32;
    }
}

/* Make a SteamID/IP token safe for an unquoted server_cmd argument.
   Must allow '_' — STEAM_/VALVE_ prefixes break without it (bug found live
   2026-10-02: FSanId turned STEAM_0:0:X into STEAM00:0:X). */
stock FSanId(s[]) {
    for (new i = 0; s[i]; i++) {
        new c = s[i];
        if ((c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
            || c == ':' || c == '.' || c == '_') continue;
        s[i] = '0';
    }
}

stock FLoadCursor() {
    g_iLastHistory = 0;
    new f = fopen(g_szCurFile, "rt");
    if (!f) return;
    new buf[32];
    if (fgets(f, buf, charsmax(buf))) g_iLastHistory = str_to_num(buf);
    fclose(f);
}

stock FSaveCursor() {
    new f = fopen(g_szCurFile, "wt");
    if (!f) return;
    new buf[32];
    formatex(buf, charsmax(buf), "%d", g_iLastHistory);
    fputs(f, buf);
    fclose(f);
}

/* Snapshot = verbatim (trimmed) copy of the ban file at last clean pass. */
stock FSaveSnap() {
    new f = fopen(g_szSnapFile, "wt");
    new fsrc = fopen(g_szBanFile, "rt");
    if (fsrc) {
        new line[512];
        while (!feof(fsrc)) {
            line[0] = 0;
            if (!fgets(fsrc, line, charsmax(line))) break;
            trim(line);
            if (!line[0]) continue;
            if (f) { fputs(f, line); fputs(f, "^n"); }
        }
        fclose(fsrc);
    }
    if (f) fclose(f);
    FLoadSnap();
}

stock FLoadSnap() {
    g_nSnap = 0;
    for (new i = 0; i < MAX_LOCAL; i++) g_sSwept[i] = false;
    if (!file_exists(g_szSnapFile)) return 0;
    new f = fopen(g_szSnapFile, "rt");
    if (!f) return 0;
    new line[512];
    static sid[35], nm[32], lenstr[16], ut[32], rsn[128], an[32], ast[35];
    while (!feof(f) && g_nSnap < MAX_LOCAL) {
        line[0] = 0;
        if (!fgets(f, line, charsmax(line))) break;
        trim(line);
        if (!line[0]) continue;
        sid[0] = 0; nm[0] = 0; lenstr[0] = 0; ut[0] = 0;
        rsn[0] = 0; an[0] = 0; ast[0] = 0;
        parse(line, sid, charsmax(sid), nm, charsmax(nm), lenstr, charsmax(lenstr),
            ut, charsmax(ut), rsn, charsmax(rsn), an, charsmax(an), ast, charsmax(ast));
        if (!sid[0] || !lenstr[0] || !ut[0]) continue;
        copy(g_sSid[g_nSnap], charsmax(g_sSid[]), sid);
        copy(g_sUt[g_nSnap], charsmax(g_sUt[]), ut);
        copy(g_sRsn[g_nSnap], charsmax(g_sRsn[]), rsn);
        g_sLen[g_nSnap] = str_to_num(lenstr);
        g_nSnap++;
    }
    fclose(f);
    return g_nSnap;
}

/* Load advanced_bans.txt into g_l* (same parse contract as LoadBans). */
stock FLoadLocal() {
    g_nLocal = 0;
    if (!file_exists(g_szBanFile)) return 0;
    new f = fopen(g_szBanFile, "rt");
    if (!f) return 0;
    new line[512], lenstr[16];
    while (!feof(f) && g_nLocal < MAX_LOCAL) {
        line[0] = 0;
        if (!fgets(f, line, charsmax(line))) break;
        trim(line);
        if (!line[0]) continue;
        g_lSid[g_nLocal][0] = 0; g_lName[g_nLocal][0] = 0; lenstr[0] = 0;
        g_lUt[g_nLocal][0] = 0; g_lRsn[g_nLocal][0] = 0;
        g_lAn[g_nLocal][0] = 0; g_lAs[g_nLocal][0] = 0;
        parse(line,
            g_lSid[g_nLocal], charsmax(g_lSid[]),
            g_lName[g_nLocal], charsmax(g_lName[]),
            lenstr, charsmax(lenstr),
            g_lUt[g_nLocal], charsmax(g_lUt[]),
            g_lRsn[g_nLocal], charsmax(g_lRsn[]),
            g_lAn[g_nLocal], charsmax(g_lAn[]),
            g_lAs[g_nLocal], charsmax(g_lAs[]));
        if (!g_lSid[g_nLocal][0] || !lenstr[0] || !g_lUt[g_nLocal][0]) continue;
        g_lLen[g_nLocal] = str_to_num(lenstr);
        g_nLocal++;
    }
    fclose(f);
    return g_nLocal;
}

stock bool:FLocalHas(const sid[], const ut[], const rsn[]) {
    for (new i = 0; i < g_nLocal; i++)
        if (equal(g_lSid[i], sid) && equal(g_lUt[i], ut) && equal(g_lRsn[i], rsn))
            return true;
    return false;
}

/* bans.php accepts unbantime only as '0' (permanent) or unix epoch seconds
   (temp). advanced_bans.txt stores a %L langkey for permanent - banlen<=0 is
   the reliable marker - and GenerateUnbanTime's "%i:%02i:%02i %i/%i/%i" for
   temp. Convert ONLY at the SQL boundary: file + snapshot stay raw so the
   (sid,ut,reason) compare triple and verbatim snapshot semantics are kept.
   Epoch is plain integer math + local-clock calibration, never parse_time -
   a thrown native would abort FSyncPass after g_bPassRun=true and wedge the
   re-entry guard. */
stock FConvUt(const ut[], banlen, out[], len) {
    if (banlen <= 0) { copy(out, len, "0"); return; }
    new n = strlen(ut);
    if (n <= 0) { copy(out, len, ut); return; }
    new bool:alldig = true;
    for (new i = 0; i < n; i++)
        if (ut[i] < '0' || ut[i] > '9') { alldig = false; break; }
    if (alldig) { copy(out, len, ut); return; }   /* already an epoch */
    new i1 = -1, i2 = -1, isp = -1, is1 = -1, is2 = -1, ns = 0;
    for (new i = 0; i < n; i++) {
        new c = ut[i];
        if (c == ':') { if (i1 < 0) i1 = i; else if (i2 < 0) i2 = i; }
        else if (c == ' ') { ns++; if (isp < 0) isp = i; }
        else if (c == '/') { if (is1 < 0) is1 = i; else if (is2 < 0) is2 = i; }
        else if (c < '0' || c > '9') { copy(out, len, ut); return; }
    }
    /* H:MM:SS M/D/YYYY -> exactly one space, two colons, two slashes,
       all six fields non-empty */
    if (ns != 1 || i1 < 1 || i2 <= i1 + 1 || isp <= i2 + 1 ||
        is1 <= isp + 1 || is2 <= is1 + 1 || is2 >= n - 1) { copy(out, len, ut); return; }
    new hb[8], mb[6], sb[6], mob[6], db[6], yb[8];
    FFieldSlice(ut, 0, i1, hb, charsmax(hb));
    FFieldSlice(ut, i1 + 1, i2, mb, charsmax(mb));
    FFieldSlice(ut, i2 + 1, isp, sb, charsmax(sb));
    FFieldSlice(ut, isp + 1, is1, mob, charsmax(mob));
    FFieldSlice(ut, is1 + 1, is2, db, charsmax(db));
    FFieldSlice(ut, is2 + 1, n, yb, charsmax(yb));
    new ep = FCivilEpoch(str_to_num(yb), str_to_num(mob), str_to_num(db),
        str_to_num(hb), str_to_num(mb), str_to_num(sb));
    if (ep <= 0) { copy(out, len, ut); return; }
    formatex(out, len, "%d", ep);
}

stock FFieldSlice(const s[], a, b, dst[], dstmax) {
    new j = 0;
    for (new i = a; i < b && j < dstmax; i++) dst[j++] = s[i];
    dst[j] = 0;
}

/* days-from-civil (Hinnant) - calendar fields -> day number */
stock FCivilDays(y, mo, d) {
    if (mo <= 2) y--;
    new era = ((y >= 0) ? y : (y - 399)) / 400;
    new yoe = y - era * 400;
    new doy = (153 * (mo + (mo > 2 ? -3 : 9)) + 2) / 5 + d - 1;
    new doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    return era * 146097 + doe - 719468;
}

/* wall-clock fields -> unix epoch, calibrated against this host's clock so
   the result tracks the server TZ/DST instead of assuming UTC */
stock FCivilEpoch(y, mo, d, h, mi, s) {
    if (mo < 1 || mo > 12 || d < 1 || d > 31 || h < 0 || h > 23 || mi < 0 || mi > 59 || s < 0 || s > 59)
        return -1;
    new hh, nn, ss; time(hh, nn, ss);
    new yy, mm, dd; date(yy, mm, dd);
    new off = (FCivilDays(yy, mm, dd) * 86400 + hh * 3600 + nn * 60 + ss) - get_systime();
    return FCivilDays(y, mo, d) * 86400 + h * 3600 + mi * 60 + s - off;
}

/* Plan slot: INSERT rows [start, start+want) guarded by NOT EXISTS on the
   (steamid, unbantime, reason) triple — idempotent, never touches web rows. */
stock FBuildPush(start, want) {
    g_szSyncQ[0][0] = 0;
    static snm[64], ssid[72], sut[64], srsn[256], san[64], sas[72], cut[48], part[1400];
    new len = 0, n = 0;
    for (new i = start; i < start + want && n < PUSH_BATCH; i++) {
        FSQLStr(g_lName[i], snm, charsmax(snm));
        FSQLStr(g_lSid[i], ssid, charsmax(ssid));
        FConvUt(g_lUt[i], g_lLen[i], cut, charsmax(cut));
        FSQLStr(cut, sut, charsmax(sut));
        FSQLStr(g_lRsn[i], srsn, charsmax(srsn));
        FSQLStr(g_lAn[i], san, charsmax(san));
        FSQLStr(g_lAs[i], sas, charsmax(sas));
        formatex(part, charsmax(part),
            "INSERT INTO advanced_bans (name,steamid,ip,banlength,unbantime,reason,admin_name,admin_steamid) \
SELECT '%s','%s','',%d,'%s','%s','%s','%s' WHERE NOT EXISTS \
(SELECT 1 FROM advanced_bans WHERE steamid='%s' AND unbantime='%s' AND reason='%s');",
            snm, ssid, g_lLen[i], sut, srsn, san, sas, ssid, sut, srsn);
        if (len + strlen(part) > 3500) break;
        add(g_szSyncQ[0], charsmax(g_szSyncQ[]), part);
        len += strlen(part);
        n++;
    }
    return n;
}

/* Plan slot: DELETE snapshot triples gone from the file and not yet swept.
   Triple match = never touches rows we did not create. Sweep progress is
   recorded per snapshot index (g_sSwept) and committed only on a clean pass,
   so dry-runs/failures re-preview the same pending set and mid-sweep file
   churn cannot hide a row below a moving offset. */
stock FBuildDelete() {
    g_szSyncQ[1][0] = 0;
    g_bDelTrunc = false;
    g_iDelPlanN = 0;
    static s2sid[72], s2ut[64], srsn[256], cut2[48], part[420];
    new len = 0, n = 0;
    for (new i = 0; i < g_nSnap; i++) {
        if (g_sSwept[i]) continue;
        if (FLocalHas(g_sSid[i], g_sUt[i], g_sRsn[i])) continue;
        FSQLStr(g_sSid[i], s2sid, charsmax(s2sid));
        FConvUt(g_sUt[i], g_sLen[i], cut2, charsmax(cut2));
        FSQLStr(cut2, s2ut, charsmax(s2ut));
        FSQLStr(g_sRsn[i], srsn, charsmax(srsn));
        formatex(part, charsmax(part), "%s('%s','%s','%s')",
            n ? "," : "", s2sid, s2ut, srsn);
        if (n && len + strlen(part) > 3500) { g_bDelTrunc = true; break; }
        if (!n) {
            add(g_szSyncQ[1], charsmax(g_szSyncQ[]),
                "DELETE FROM advanced_bans WHERE (steamid,unbantime,reason) IN (");
            len = 70;
        }
        add(g_szSyncQ[1], charsmax(g_szSyncQ[]), part);
        len += strlen(part);
        g_iDelPlan[g_iDelPlanN++] = i;
        n++;
    }
    if (!n) return;
    add(g_szSyncQ[1], charsmax(g_szSyncQ[]), ");");
}

/* One reconcile pass: load file+snapshot, plan push/delete/pull, dispatch.
   State (batch/cursor/snap) advances only in FSyncResult on a clean pass. */
stock FSyncPass(id) {
    if (g_bPassRun || g_bSync || g_bSetup || g_bCustom) return;
    g_bPassRun = true;
    g_bDryRun = get_pcvar_num(g_pDryRun) != 0;
    FBuildFiles();
    FLoadLocal();
    if (g_nLocal >= MAX_LOCAL || g_nSnap >= MAX_LOCAL)
        log_amx("[PGS] WARN: MAX_LOCAL=%d cap hit (local=%d snap=%d) - rows beyond are not synced",
            MAX_LOCAL, g_nLocal, g_nSnap);
    /* interlock: a missing ban file must never sweep the snapshot clean */
    new file_ok = file_exists(g_szBanFile);
    if (!file_ok && g_nSnap)
        log_amx("[PGS] WARN: ban file missing (%s) - DELETE sweep skipped this pass", g_szBanFile);

    g_bHadPush = false;
    g_iPushStart = g_iPushBatch;
    g_iPushRows = 0;
    g_szSyncQ[0][0] = 0;
    g_szSyncQ[1][0] = 0;
    g_szSyncQ[2][0] = 0;

    g_iPlanSize = file_ok ? file_size(g_szBanFile) : -1;
    if (g_iPushBatch >= g_nLocal) g_iPushBatch = 0;   /* file shrank under us -> restart cycle */
    if (file_ok && g_iPushBatch < g_nLocal) {
        /* Push is change-gated: once a full cycle verified every row and the
           file is unchanged (size + row count), skip the no-op re-push churn;
           any add/remove alters the signature -> fresh full re-cycle. */
        new bool:cyc_done = (g_iCycRows >= 0 && g_iPlanSize == g_iCycSize && g_nLocal == g_iCycRows);
        if (!(g_iPushBatch == 0 && cyc_done)) {
            new want = g_nLocal - g_iPushBatch;
            if (want > PUSH_BATCH) want = PUSH_BATCH;
            new n = FBuildPush(g_iPushBatch, want);
            if (n > 0) { g_iPushRows = n; g_bHadPush = true; }
        }
    }

    if (file_ok) FBuildDelete();
    else { g_szSyncQ[1][0] = 0; g_iDelPlanN = 0; }

    formatex(g_szSyncQ[2], charsmax(g_szSyncQ[]),
        "SELECT id::text||chr(1)||action||chr(1)||coalesce(steamid,'')||chr(1)||coalesce(minutes::text,'0')||chr(1)||coalesce(name,'')||chr(1)||left(coalesce(reason,''),128) FROM advanced_bans_history WHERE id > %d ORDER BY id ASC LIMIT 1;",
        g_iLastHistory);

    /* compact planned statements into slots 0..k-1 (pull stays last) */
    new k = 0;
    for (new s = 0; s < 3; s++) {
        if (g_szSyncQ[s][0]) {
            if (k != s) copy(g_szSyncQ[k], charsmax(g_szSyncQ[]), g_szSyncQ[s]);
            k++;
        }
    }
    g_iNeedSync = k;
    if (!k) { g_bPassRun = false; return; }

    if (g_bDryRun) {
        for (new i = 0; i < k; i++) {
            new tmp[448];
            copy(tmp, charsmax(tmp), g_szSyncQ[i]);
            if (strlen(g_szSyncQ[i]) > 438) { tmp[438] = 0; add(tmp, charsmax(tmp), "..."); }
            log_amx("[PGS] dryrun q%d len=%d: %s", i, strlen(g_szSyncQ[i]), tmp);
            if (id) console_print(id, "[PGS] dryrun q%d len=%d - full text in amxx log", i, strlen(g_szSyncQ[i]));
        }
        formatex(g_szLastSync, charsmax(g_szLastSync),
            "dryrun: %d stmt (push=%d del=%d)", k, g_iPushRows, g_iDelPlanN);
        g_bPassRun = false;
        return;
    }

    g_bSync = true;
    concmd_ConnectTest(id);   /* synchronous; success branch calls FSyncResult */
    g_bSync = false;
    g_bPassRun = false;
}

/* Clean-pass handler: ACK push/delete, apply pull row (history -> server_cmd),
   advance cursor/batch, persist snapshot. Any ERR: slot = no state advance. */
stock FSyncResult(id) {
    for (new i = 0; i < g_iNeedSync; i++) {
        if (g_szQRes[i][0] && contain(g_szQRes[i], "ERR:") == 0) {
            formatex(g_szLastSync, charsmax(g_szLastSync), "FAIL q%d: %s", i, g_szQRes[i]);
            console_print(id, "[PGS] sync %s", g_szLastSync);
            log_amx("[PGS] sync %s", g_szLastSync);
            return;
        }
    }

    new applied = 0, skipped = 0, hid = 0;
    new ps = g_iNeedSync - 1;
    if (g_szQRes[ps][0]) {
        static row[400];
        copy(row, charsmax(row), g_szQRes[ps]);
        /* row = id\1action\1steamid\1minutes\1name\1reason  (6 fields) */
        new st[6], en[6], cnt = 0;
        st[0] = 0;
        for (new i = 0; ; i++) {
            if (row[i] == 1 || row[i] == 0) {
                en[cnt] = i;
                cnt++;
                if (row[i] == 0 || cnt >= 6) break;
                st[cnt] = i + 1;
            }
        }
        if (cnt >= 6) {
            static fid[16], fact[16], fsid[40], fmin[16], fnm[40], frsn[140];
            FSub(row, fid, st[0], en[0], charsmax(fid));
            FSub(row, fact, st[1], en[1], charsmax(fact));
            FSub(row, fsid, st[2], en[2], charsmax(fsid));
            FSub(row, fmin, st[3], en[3], charsmax(fmin));
            FSub(row, fnm, st[4], en[4], charsmax(fnm));
            FSub(row, frsn, st[5], en[5], charsmax(frsn));
            hid = str_to_num(fid);
            new mins = str_to_num(fmin);
            if (mins < 0) mins = 0;
            if (equali(fact, "ban") || equali(fact, "addban") || equali(fact, "add")) {
                FStripQ(fnm); FStripQ(frsn);
                FSanId(fsid);
                if (!fnm[0]) copy(fnm, charsmax(fnm), fsid);
                if (!frsn[0]) copy(frsn, charsmax(frsn), "synced from history");
                if (contain(fsid, ":") < 0)
                    log_amx("[PGS] sync: authid '%s' lacks ':' - amx_addban may reject it", fsid);
                /* authid MUST be quoted — the console tokenizer splits on ':'
                   and would truncate STEAM_X:Y:Z (diagnosed via ab_diag 2026-10-02) */
                static scmd[300];
                formatex(scmd, charsmax(scmd), "amx_addban ^"%s^" ^"%s^" %d ^"%s^"", fnm, fsid, mins, frsn);
                log_amx("[PGS] apply-cmd: %s", scmd);
                server_cmd("%s", scmd);
                applied++;
            } else if (equali(fact, "unban") || equali(fact, "remove") || equali(fact, "delete")) {
                FSanId(fsid);
                static ucmd[80];
                formatex(ucmd, charsmax(ucmd), "amx_unban ^"%s^"", fsid);
                log_amx("[PGS] apply-cmd: %s", ucmd);
                server_cmd("%s", ucmd);
                applied++;
            } else {
                skipped++;
                log_amx("[PGS] sync: unknown history action '%s' (id=%s) - skipped", fact, fid);
            }
            if (hid > g_iLastHistory) { g_iLastHistory = hid; FSaveCursor(); }
        }
    }

    /* advance push batch (wrap -> record signature so unchanged files go quiet) */
    if (g_bHadPush && g_iPushRows > 0) {
        if (g_iPushStart + g_iPushRows >= g_nLocal) {
            g_iPushBatch = 0;
            g_iCycSize = g_iPlanSize;
            g_iCycRows = g_nLocal;
        } else g_iPushBatch = g_iPushStart + g_iPushRows;
    }

    /* commit delete sweep progress (plan indices from FBuildDelete) */
    for (new i = 0; i < g_iDelPlanN; i++)
        if (g_iDelPlan[i] < g_nSnap) g_sSwept[g_iDelPlan[i]] = true;
    g_iDelPlanN = 0;

    /* persist snapshot unless pending delete rows remain unswept */
    if (!g_bDelTrunc) FSaveSnap();

    /* real deleted-row count from the DELETE statement's CommandComplete tag
       ("DELETE n"); planned-but-0-matched reports 0 (same as before), and a
       pass that planned no DELETE reports 0 - the tag, not the plan flag,
       decides. Keeps del= aligned with push= (both actual row counts). */
    new delrows = 0;
    for (new i = 0; i < g_iNeedSync; i++) {
        if (!strncmp(g_szQTag[i], "DELETE ", 7)) {
            delrows = str_to_num(g_szQTag[i][7]);
            break;
        }
    }
    formatex(g_szLastSync, charsmax(g_szLastSync),
        "ok push=%d del=%d hist=%d applied=%d skip=%d",
        g_bHadPush ? g_iPushRows : 0, delrows, hid, applied, skipped);
    console_print(id, "[PGS] sync %s", g_szLastSync);
    log_amx("[PGS] sync %s (cursor=%d batch=%d local=%d snap=%d)",
        g_szLastSync, g_iLastHistory, g_iPushBatch, g_nLocal, g_nSnap);
}
