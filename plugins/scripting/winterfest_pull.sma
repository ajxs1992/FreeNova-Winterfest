/*
 * ============================================================================
 * winterfest_pull — the game's half of "the database is authoritative"
 * ============================================================================
 * Contract: docs/panel/00-CONTRACT.md §2, API: docs/panel/01-DATA.md §7.
 * Module map and natives: docs/WINTERFEST-DEV.md.
 *
 * A panel action writes the DB. The game then applies the resulting change on
 * its next pull and reports back. This plugin is that loop, and nothing else:
 *
 *   every `interval` seconds, per connected human player
 *     GET  /api/game/pending?steamid=<player>    (signed, HMAC-SHA256)
 *   for each row the panel reports `applied`
 *     mirror it through the core's ONE grant path (wf_grant / wf_grant_ornament /
 *     wf_advent_claim / wf_tree_set_slot / wf_grant_entitlement) — never a
 *     second implementation of paying out
 *   then
 *     POST /api/game/ack {id, state, error}      — one call per action, `applied`
 *     or `refused` with the reason the engine could not mirror it
 *
 * WHY IT LOOKS LIKE THIS
 *
 *   - Never block the server. The socket is non-blocking and polled by a task;
 *     a request is bounded by `[pull] timeout`; exactly one request is in flight
 *     at a time, so 32 players cost a queue, not 32 sockets.
 *   - Nothing is stored. The only per-player state is the last acked action id
 *     (for `wf_pull_now` to print) and a due time, both in memory, both reset on
 *     disconnect. A restart re-pulls whatever the panel has not seen ack'd —
 *     which is why the retry path has to be safe, and it is: the game's claim
 *     keys are the panel's action id (`wf:a<id>#…`), so re-applying is a no-op
 *     the core answers WF_GRANT_DUPLICATE for.
 *   - A dead panel costs one log line, not one per player. Every failure feeds
 *     one streak counter with a growing backoff; the 3rd consecutive failure
 *     says so once, a success says "reachable again" once.
 *   - Absent core, absent panel, absent config: the plugin still loads. Every
 *     wf_* native is behind set_native_filter(), and the poll loop asks
 *     LibraryExists("winterfest_core") every tick, so a core that appears later
 *     is picked up instead of leaving a paused plugin behind.
 *
 * WHAT EACH KIND DOES IN THE ENGINE (and what it deliberately does not)
 *
 *   claim_mission  grants the declared coins/gingerbread/spins/pass_xp/item/
 *                  product through wf_grant. It does NOT re-check mission
 *                  completion: the mission ladder (missions.ini) is Phase 2 and
 *                  is not in the core yet, so there is nothing to check against.
 *   claim_advent   wf_advent_claim(day) — the calendar's own idempotent claim
 *                  key (`advent#<day>`), so a day pays once whether it arrived
 *                  through the panel or in game. The ini decides the amount; if
 *                  that disagrees with what the panel declared, both numbers go
 *                  in the log instead of the game paying the difference.
 *   plant_ornament wf_tree_set_slot(slot, ornament), refused when the engine
 *                  does not own that ornament (the panel and the game disagree,
 *                  and the panel needs to know).
 *   buy            grants the item/product. The DEBIT is not mirrored: the game
 *                  has no spend path (wf_add_gingerbread ignores negatives and
 *                  wf_grant only credits), and the panel owns the spend side of
 *                  gingerbread (01-DATA.md §9). The charge is logged.
 *   equip          refused: the game has no equip state. Titles are owned, not
 *                  worn; the panel's `equipped` column has no engine twin.
 *   grant          the staff/comp path — same field set as claim_mission.
 *
 * CONFIG (configs/freenova/winterfest.ini, read at map start and on wf_reload
 * via the core's console command — this plugin re-reads its section on the
 * first tick after `wf_pull_config`, see cmdConfig)
 *
 *   [pull]
 *   enabled  = 0|1     poll at all (default 0: an unconfigured host must not
 *                      send traffic anywhere)
 *   url      = http://host:port   plain HTTP only — this build has sockets, no TLS
 *   secret   = <hex>   the panel's SYNC_SECRET (the ingest's HMAC secret)
 *   interval = 20      seconds between one player's polls (jittered ×1.0–1.5)
 *   timeout  = 5       seconds a single request may take before it is abandoned
 * ============================================================================
 */

#include <amxmodx>
#include <amxmisc>
#include <sockets>
#include <json>
#include <winterfest>

#define PLUGIN  "Winterfest Pull"
#define VERSION "1.0.0"
#define AUTHOR  "FreeNova"

#define CONFIG_FILE "freenova/winterfest.ini"

// The two game-facing routes (01-DATA.md §7). The signature covers the PATH
// only; the steamid rides in the query string, unsigned, like every panel read.
#define WF_PULL_PATH_PENDING "/api/game/pending"
#define WF_PULL_PATH_ACK     "/api/game/ack"

// sha256("") — the body hash of a GET. A constant because a GET never has one.
#define WF_PULL_EMPTY_HASH \
	"e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

#define WF_PULL_DEFAULT_INTERVAL 20
#define WF_PULL_DEFAULT_TIMEOUT  5

#define WF_PULL_MAX_ACTIONS 32   // the panel's own per-pull cap (pendingActions)
#define WF_PULL_MAX_ACKS    32   // acks that may wait for a socket
#define WF_PULL_ERR_MAX     120  // a refusal reason, escaped, before the 200 cap

#define WF_PULL_BODY_MAX  4096
#define WF_PULL_RESP_MAX  8192   // a 32-action pending body is ~4 KB
#define WF_PULL_OUT_MAX   1024   // request head + ack body

#define TASK_TICK   97500
#define TASK_SOCKET 97501

#define WF_PULL_REQUEST_NONE    0
#define WF_PULL_REQUEST_PENDING 1
#define WF_PULL_REQUEST_ACK     2

#define WF_PULL_APPLIED 1
#define WF_PULL_REFUSED 0
#define WF_PULL_RETRY  -1   // leave the row on the panel: the engine cannot decide yet

// ============================================================
// State
// ============================================================

new g_bEnabled
new g_bConfigured          // config found, url parsed, secret present
new g_szUrl[128]
new g_szHost[48]
new g_iPort
new g_szSecret[96]
new g_iInterval
new Float:g_fTimeout

// Scheduling. One request in flight; a player is due at g_fDue[id], forced by
// g_bForce[id] (wf_pull_now), or poked by hand through g_bManual.
new Float:g_fDue[MAX_PLAYERS + 1]
new g_bForce[MAX_PLAYERS + 1]
new g_iLastAck[MAX_PLAYERS + 1]
new g_iCursor
new bool:g_bManual
new g_szManualId[40]
new g_iManualClient

// Transport: exactly one of these is live at a time.
new g_iSocket
new g_iReqKind
new g_iReqClient            // 0 = an identity with no client (manual drain)
new g_szReqId[40]           // the steamid the request is for
new g_iOutLen
new g_iOutSent
new g_iReqAck              // the action id this request acks, for the log
new g_szOut[WF_PULL_OUT_MAX]
new g_szBody[512]           // the request body (empty for a GET)
new g_szResp[WF_PULL_RESP_MAX + 1024]
new g_szHead[16]              // the first bytes received: the status line
new g_szBodyReply[WF_PULL_BODY_MAX]   // the JSON body, copied out of the reply
new g_iRespLen
new Float:g_fDeadline

// Backoff. All transport failures feed this one counter, so a dead panel is one
// log line and not one per player.
new g_iFailStreak
new Float:g_fDownUntil

// The ack queue. Push when an action is applied (or refused), pop one per POST.
new g_iAckId[WF_PULL_MAX_ACKS]
new g_iAckOk[WF_PULL_MAX_ACKS]
new g_iAckWho[WF_PULL_MAX_ACKS]
new g_szAckErr[WF_PULL_MAX_ACKS][WF_PULL_ERR_MAX]
new g_iAckHead
new g_iAckTail

// ============================================================
// Lifecycle
// ============================================================

public plugin_natives()
{
	register_library("winterfest_pull")
	register_native("wf_pull_request", "native_pull_request")
	// A missing core must degrade the natives to 0, not fail the load: this
	// plugin has to survive on a server that never installed Winterfest.
	set_native_filter("WfPullNativeFilter")
}

public WfPullNativeFilter(const name[], index, trap)
{
	if (!trap && contain(name, "wf_") == 0 && !LibraryExists("winterfest_core", LibType_Library))
		return PLUGIN_HANDLED
	return PLUGIN_CONTINUE
}

public plugin_init()
{
	register_plugin(PLUGIN, VERSION, AUTHOR)

	register_concmd("wf_pull_now", "cmdPullNow", ADMIN_CFG,
		"<target|steamid|all> - poll the panel now for one player (or every connected player)")
	register_concmd("wf_pull_status", "cmdPullStatus", ADMIN_CFG,
		"- print the pull configuration, the backoff state and the ack queue")
	register_concmd("wf_pull_config", "cmdPullConfig", ADMIN_CFG,
		"- re-read the [pull] section of winterfest.ini")

	WfPullReset()

	if (!WfPullLoadConfig())
	{
		log_amx("[WF-PULL] no %s - the pull loop is off (the game is still playable; wins are recorded in game)", CONFIG_FILE)
		return
	}
	if (!g_bEnabled)
	{
		log_amx("[WF-PULL] off: [pull] enabled = 0 in %s", CONFIG_FILE)
		return
	}
	if (!g_szSecret[0])
	{
		log_amx("[WF-PULL] off: [pull] secret is empty - it must be the panel's SYNC_SECRET")
		return
	}
	if (!WfPullParseUrl())
	{
		log_amx("[WF-PULL] off: [pull] url %s is unusable", g_szUrl)
		return
	}

	g_bConfigured = true
	// One boot line that says where the traffic goes, never what the secret is.
	log_amx("[WF-PULL] polling http://%s:%d every %ds (timeout %ds, one request at a time)",
		g_szHost, g_iPort, g_iInterval, floatround(g_fTimeout))

	if (!LibraryExists("winterfest_core", LibType_Library))
		log_amx("[WF-PULL] winterfest_core missing - the loop stays parked until it appears")

	set_task(0.25, "Task_Tick", TASK_TICK, "", 0, "b")
}

public plugin_end()
{
	WfPullClose()
}

WfPullReset()
{
	g_bConfigured = false
	g_bEnabled = false
	g_szUrl[0] = 0
	g_szHost[0] = 0
	g_iPort = 0
	g_szSecret[0] = 0
	g_iInterval = WF_PULL_DEFAULT_INTERVAL
	g_fTimeout = float(WF_PULL_DEFAULT_TIMEOUT)

	for (new i = 0; i <= MAX_PLAYERS; i++)
	{
		g_fDue[i] = 0.0
		g_bForce[i] = false
		g_iLastAck[i] = 0
	}
	g_bManual = false
	g_szManualId[0] = 0
	g_iManualClient = 0
	g_iCursor = 0
	g_iAckHead = 0
	g_iAckTail = 0
	g_iFailStreak = 0
	g_fDownUntil = 0.0
	WfPullClose()
}

// ============================================================
// Config
// ============================================================

WfPullLoadConfig()
{
	g_bEnabled = false
	g_iInterval = WF_PULL_DEFAULT_INTERVAL
	g_fTimeout = float(WF_PULL_DEFAULT_TIMEOUT)
	g_szUrl[0] = 0
	g_szSecret[0] = 0

	new cfgdir[96], path[128]
	get_configsdir(cfgdir, charsmax(cfgdir))
	formatex(path, charsmax(path), "%s/%s", cfgdir, CONFIG_FILE)
	if (!file_exists(path))
		return false

	new fp = fopen(path, "rt")
	if (!fp)
		return false

	new line[256], section[24], key[32], val[128]
	section[0] = 0
	while (fgets(fp, line, charsmax(line)))
	{
		trim(line)
		if (!line[0] || line[0] == ';' || line[0] == '#')
			continue

		if (line[0] == '[')
		{
			copy(section, charsmax(section), line[1])
			new close = contain(section, "]")
			if (close >= 0)
				section[close] = 0
			trim(section)
			continue
		}

		// Every other section belongs to the core or to a sibling module.
		if (!equali(section, "pull"))
			continue

		key[0] = 0
		val[0] = 0
		if (!WfPullSplitKeyValue(line, key, charsmax(key), val, charsmax(val)))
			continue

		if (equali(key, "enabled"))
			g_bEnabled = WfPullBool(val)
		else if (equali(key, "url"))
			copy(g_szUrl, charsmax(g_szUrl), val)
		else if (equali(key, "secret"))
			copy(g_szSecret, charsmax(g_szSecret), val)
		else if (equali(key, "interval"))
			g_iInterval = clamp(str_to_num(val), 5, 600)
		else if (equali(key, "timeout"))
			g_fTimeout = float(clamp(str_to_num(val), 1, 30))
	}
	fclose(fp)
	return true
}

// "key = value" inside a section. Comments are whole lines only: a secret or a
// url may legitimately contain ';' or '#' and must not be cut in half.
bool:WfPullSplitKeyValue(const line[], key[], klen, val[], vlen)
{
	new eq = contain(line, "=")
	if (eq < 1)
		return false
	copy(key, klen, line)
	key[eq] = 0
	trim(key)
	copy(val, vlen, line[eq + 1])
	trim(val)
	return key[0] ? true : false
}

bool:WfPullBool(const val[])
{
	return (equali(val, "1") || equali(val, "on") || equali(val, "yes") || equali(val, "true")) ? true : false
}

// http://<numeric ipv4>[:port] — and nothing else. socket_open() resolves names
// synchronously, so a hostname is a blocking DNS lookup inside the game frame:
// refused, with the reason in the log.
bool:WfPullParseUrl()
{
	new tmp[128], rest[96]
	copy(tmp, charsmax(tmp), g_szUrl)
	trim(tmp)

	if (!equali(tmp, "http://", 7))
	{
		if (equali(tmp, "https://", 8))
			log_amx("[WF-PULL] [pull] url is https - this build has sockets and no TLS; use http://")
		return false
	}

	copy(rest, charsmax(rest), tmp[7])
	if (contain(rest, "/") >= 0 || contain(rest, " ") >= 0)
		return false   // no path, no query: the routes are fixed (01-DATA.md §7)

	new colon = contain(rest, ":")
	if (colon >= 0)
	{
		g_iPort = str_to_num(rest[colon + 1])
		rest[colon] = 0
	}
	else
		g_iPort = 80

	copy(g_szHost, charsmax(g_szHost), rest)
	if (g_iPort < 1 || g_iPort > 65535)
		return false
	return WfPullNumericHost(g_szHost)
}

bool:WfPullNumericHost(const host[])
{
	new len = strlen(host), dots = 0
	if (len < 7 || len > 15)
		return false
	for (new i = 0; i < len; i++)
	{
		if (host[i] == '.')
		{
			dots++
			continue
		}
		if (host[i] < '0' || host[i] > '9')
			return false
	}
	return (dots == 3) ? true : false
}

// ============================================================
// Players
// ============================================================

public client_putinserver(id)
{
	g_iLastAck[id] = 0
	g_bForce[id] = false
	// Spread the first poll over the interval instead of firing 32 at once when
	// a full server connects together.
	g_fDue[id] = get_gametime() + random_float(1.0, float(g_iInterval))
}

public client_disconnected(id)
{
	g_fDue[id] = 0.0
	g_bForce[id] = false
	g_iLastAck[id] = 0
}

// A player the panel can be asked about: connected, human, and authenticated.
// A bot has the authid "BOT" and a LAN client "STEAM_ID_LAN"; the panel refuses
// both (validSteamid), so polling for them would be a 400 every cycle.
bool:WfPullEligible(id)
{
	if (id < 1 || id > MaxClients || !is_user_connected(id))
		return false
	if (is_user_bot(id) || is_user_hltv(id))
		return false
	new auth[40]
	get_user_authid(id, auth, charsmax(auth))
	return WfPullValidSteam(auth)
}

bool:WfPullValidSteam(const steamid[])
{
	// The panel's own shape (src/state.js validSteamid): ^STEAM_[0-9]:[0-9]:\d+$.
	// The prefix is skipped before the digit test - testing it as a character
	// rejects every valid id, which is a silent "nobody is ever polled".
	if (!equali(steamid, "STEAM_", 6))
		return false
	new len = strlen(steamid)
	if (len < 11 || len > 39)
		return false
	new colons = 0
	for (new i = 6; i < len; i++)
	{
		if (steamid[i] == ':')
		{
			colons++
			continue
		}
		if (steamid[i] < '0' || steamid[i] > '9')
			return false
	}
	return (colons == 2) ? true : false
}

// ============================================================
// The scheduler
// ============================================================

public Task_Tick()
{
	// Parked, not paused: a core that loads onto this server later (or comes
	// back after a reload) is picked up here instead of needing a map change.
	if (!g_bConfigured || !LibraryExists("winterfest_core", LibType_Library))
		return
	if (g_iReqKind != WF_PULL_REQUEST_NONE)
		return                       // one request at a time, always
	if (get_gametime() < g_fDownUntil)
		return                       // backoff after a failed reach

	// Acks first: they are already decided work, and a queued ack keeps the
	// panel's row from coming back on the next pull.
	if (g_iAckHead != g_iAckTail)
	{
		WfPullSendAck()
		return
	}

	if (g_bManual)
	{
		g_bManual = false
		WfPullStart(WF_PULL_REQUEST_PENDING, g_iManualClient, g_szManualId)
		return
	}

	for (new pass = 0; pass <= MaxClients; pass++)
	{
		g_iCursor++
		if (g_iCursor > MaxClients)
			g_iCursor = 1
		new id = g_iCursor
		if (g_bForce[id])
		{
			g_bForce[id] = false
			if (WfPullEligible(id))
			{
				new auth[40]
				get_user_authid(id, auth, charsmax(auth))
				WfPullStart(WF_PULL_REQUEST_PENDING, id, auth)
				return
			}
		}
		// A player who was already connected when this plugin loaded - a late
		// load, a wf_pull_config, or a changelevel that carried the clients
		// over - never got a client_putinserver, so schedule them here instead
		// of leaving them at due = 0 for the rest of the map.
		if (g_fDue[id] <= 0.0 && WfPullEligible(id))
		{
			g_fDue[id] = get_gametime() + random_float(1.0, float(g_iInterval))
			continue
		}
		if (g_fDue[id] > 0.0 && get_gametime() >= g_fDue[id] && WfPullEligible(id))
		{
			new auth[40]
			get_user_authid(id, auth, charsmax(auth))
			WfPullStart(WF_PULL_REQUEST_PENDING, id, auth)
			return
		}
	}
}

WfPullNextDue(id)
{
	g_fDue[id] = get_gametime() + float(g_iInterval) * random_float(1.0, 1.5)
}

// ============================================================
// The HTTP client (plain HTTP/1.0 over the sockets module)
//
// Non-blocking, deadline-bounded, one request at a time. The shape is the one
// freenova_sync.sma already proved on this build: connect non-blocking, poll
// writability to send, poll readability to receive, finish on clean EOF (the
// panel answers Connection: close) or on the deadline.
// ============================================================

WfPullStart(kind, id, const steamid[])
{
	if (kind == WF_PULL_REQUEST_NONE || g_iReqKind != WF_PULL_REQUEST_NONE)
		return 0

	// Only a poll needs an identity; an ack names the action, not the player.
	if (kind == WF_PULL_REQUEST_PENDING && (!steamid[0] || !WfPullValidSteam(steamid)))
	{
		log_amx("[WF-PULL] refusing to poll for '%s' - not a steamid", steamid)
		return 0
	}

	g_iReqKind = kind
	g_iReqClient = id
	copy(g_szReqId, charsmax(g_szReqId), steamid)
	g_iReqAck = 0
	WfPullBuildRequest()

	new err = 0
	g_iSocket = socket_open(g_szHost, g_iPort, SOCKET_TCP, err, SOCK_NON_BLOCKING)
	if (g_iSocket <= 0)
	{
		g_iSocket = 0
		g_iReqKind = WF_PULL_REQUEST_NONE
		WfPullFail("connect")
		return 0
	}
	log_amx("[WF-PULL] dbg: socket %d opened for %s (err %d), %d bytes to send", g_iSocket, g_szReqId, err, g_iOutLen)

	g_iOutSent = 0
	g_iRespLen = 0
	g_szResp[0] = 0
	g_fDeadline = get_gametime() + g_fTimeout
	set_task(0.1, "Task_Socket", TASK_SOCKET, "", 0, "b")
	return 1
}

WfPullBuildRequest()
{
	new szPath[96], szTs[16], szNonce[32], szBodyHash[65], szSig[65], szInput[512]

	formatex(szTs, charsmax(szTs), "%d", time())
	formatex(szNonce, charsmax(szNonce), "%d_%d", time(), random_num(100000, 999999))

	if (g_iReqKind == WF_PULL_REQUEST_PENDING)
	{
		// The query string is not signed (01-DATA.md §7), so the steamid can
		// ride here as-is, colons and all.
		copy(szPath, charsmax(szPath), WF_PULL_PATH_PENDING)
		copy(szBodyHash, charsmax(szBodyHash), WF_PULL_EMPTY_HASH)
		formatex(szInput, charsmax(szInput), "%s:GET:%s:%s:%s:%s",
			g_szSecret, WF_PULL_PATH_PENDING, szTs, szNonce, szBodyHash)
		g_szBody[0] = 0
	}
	else
	{
		copy(szPath, charsmax(szPath), WF_PULL_PATH_ACK)
		hash_string(g_szBody, Hash_Sha256, szBodyHash, charsmax(szBodyHash))
		formatex(szInput, charsmax(szInput), "%s:POST:%s:%s:%s:%s",
			g_szSecret, WF_PULL_PATH_ACK, szTs, szNonce, szBodyHash)
	}
	hash_string(szInput, Hash_Sha256, szSig, charsmax(szSig))

	new i
	if (g_iReqKind == WF_PULL_REQUEST_PENDING)
	{
		formatex(g_szOut, charsmax(g_szOut), "GET %s?steamid=%s HTTP/1.0^r^n", szPath, g_szReqId)
	}
	else
	{
		formatex(g_szOut, charsmax(g_szOut), "POST %s HTTP/1.0^r^n", szPath)
	}
	i = strlen(g_szOut)
	i += formatex(g_szOut[i], charsmax(g_szOut) - i, "Host: %s:%d^r^nAccept: application/json^r^n", g_szHost, g_iPort)
	i += formatex(g_szOut[i], charsmax(g_szOut) - i, "X-FreeNova-Timestamp: %s^r^nX-FreeNova-Nonce: %s^r^n", szTs, szNonce)
	i += formatex(g_szOut[i], charsmax(g_szOut) - i, "X-FreeNova-Signature: %s^r^n", szSig)
	if (g_iReqKind == WF_PULL_REQUEST_PENDING)
	{
		formatex(g_szOut[i], charsmax(g_szOut) - i, "Connection: close^r^n^r^n")
	}
	else
	{
		formatex(g_szOut[i], charsmax(g_szOut) - i,
			"Content-Type: application/json^r^nContent-Length: %d^r^nConnection: close^r^n^r^n%s",
			strlen(g_szBody), g_szBody)
	}
	g_iOutLen = strlen(g_szOut)
}

public Task_Socket()
{
	if (g_iSocket <= 0)
	{
		remove_task(TASK_SOCKET)
		return
	}
	log_amx("[WF-PULL] dbg: tick socket=%d sent=%d/%d readable=%d writable=%d",
		g_iSocket, g_iOutSent, g_iOutLen, socket_is_readable(g_iSocket, 0), socket_is_writable(g_iSocket, 0))

	if (get_gametime() >= g_fDeadline)
	{
		log_amx("[WF-PULL] dbg: deadline hit - sent %d/%d, %d reply bytes, readable=%d",
			g_iOutSent, g_iOutLen, g_iRespLen, socket_is_readable(g_iSocket, 0))
		WfPullFail("timeout")
		return
	}
	// ---- receive: drain what is there BEFORE sending anything else ----
	// On this build socket_recv() writes through the caller's reference and
	// returns the BUFFER SIZE, not the byte count, so the real length has to be
	// measured with strlen() (see WfPullRecv below). Reading first also means a
	// reply that arrives while the request is still being written is not
	// mistaken for a send failure.
	if (g_iOutSent > 0)
	{
		new got = WfPullRecv()
		if (got < 0)
			return
		if (got == 2)
		{
			WfPullFinish()
			return
		}
		if (got == 1)
			return
	}

	// ---- send the rest of the request ----
	if (g_iOutSent < g_iOutLen)
	{
		if (!socket_is_writable(g_iSocket, 0))
			return
		// socket_send ignores its length argument upstream, so the offset is
		// what keeps a short write from re-sending an earlier segment.
		new sent = socket_send(g_iSocket, g_szOut[g_iOutSent], g_iOutLen - g_iOutSent)
		if (sent <= 0)
			return   // EAGAIN and a transient error look the same: the deadline bounds both
		g_iOutSent += sent
		if (g_iOutSent > g_iOutLen)
			WfPullFail("send")
	}
}

// One receive. Returns >0 when bytes were appended (or the reply is complete),
// 0 when nothing arrived, -1 on a fatal condition. Bounded work per tick.
WfPullRecv()
{
	if (!socket_is_readable(g_iSocket, 0))
		return 0
	for (new n = 0; n < 4; n++)
	{
		new chunk[512]
		socket_recv(g_iSocket, chunk, charsmax(chunk))
		chunk[charsmax(chunk)] = 0
		new real = strlen(chunk)

		if (real == 0)
		{
			// A zero-length read after a completed send means the reply we hold
			// is all of it (EOF, or "nothing yet" on this build).
			if (g_iRespLen > 0)
				return WfPullReplyComplete() ? 2 : 1
			return 0
		}
		if (!g_iRespLen)
		{
			copy(g_szHead, charsmax(g_szHead), chunk)
		}
		if (g_iRespLen + real > charsmax(g_szResp) - 1)
		{
			WfPullFail("oversize")
			return -1
		}
		for (new j = 0; j < real; j++)
			g_szResp[g_iRespLen++] = chunk[j]
		g_szResp[g_iRespLen] = 0
		log_amx("[WF-PULL] dbg: recv -> %d bytes (have %d), ends '%s'", real, g_iRespLen,
			g_szResp[g_iRespLen > 10 ? g_iRespLen - 10 : 0])

		// The panel answers Connection: close, so EOF (or the terminator plus a
		// body that parses) is the end. The deadline is the backstop.
		// A terminated body that parses is the end of the reply even without an
		// EOF: some servers (and a reply already sitting in the buffer) never
		// produce one on this build's recv.
		return WfPullReplyComplete() ? 2 : 1
	}
	return 1
}

// Has the whole reply arrived? On this build indexing the reply buffer yields
// "" (g_szResp[0..] is empty even when g_szResp holds 827 bytes), so the
// completeness test cannot live on a slice of it. json_parse() reads the whole
// string it is handed, so the proxy is: the reply contains the JSON body's own
// first field (`"ok":`), then ends with a closing brace, and the buffer as a
// whole parses. A partial body fails the last test and the next tick reads on.
bool:WfPullReplyComplete()
{
	new j = contain(g_szResp, "^"ok^":")
	log_amx("[WF-PULL] dbg: complete? okAt=%d len=%d", j, strlen(g_szResp))
	if (j < 0)
		return false
	new len = strlen(g_szResp)
	new lastch = g_szResp[len - 1]
	log_amx("[WF-PULL] dbg: last char code=%d", lastch)
	if (len < 2 || lastch != '}')
		return false
	new JSON:h = json_parse(g_szResp)
	if (h == Invalid_JSON)
		return false
	json_free(h)
	return true
}

WfPullClose()
{
	remove_task(TASK_SOCKET)
	if (g_iSocket > 0)
		socket_close(g_iSocket)
	g_iSocket = 0
	g_iReqKind = WF_PULL_REQUEST_NONE
	g_iOutLen = 0
	g_iOutSent = 0
	g_iRespLen = 0
	g_szResp[0] = 0
}

// Transport failure: one streak, one backoff, one log line at the 3rd miss.
WfPullFail(const why[])
{
	new kind = g_iReqKind
	new id = g_iReqClient
	new ackId = g_iReqAck
	WfPullClose()

	g_iFailStreak = min(g_iFailStreak + 1, 20)
	if (g_iFailStreak == 3)
		log_amx("[WF-PULL] panel not reachable (%s, %s:%d) - backing off, retrying quietly", why, g_szHost, g_iPort)
	else if (g_iFailStreak > 3 && g_iFailStreak % 10 == 0)
		log_amx("[WF-PULL] panel still unreachable (%d attempts)", g_iFailStreak)

	// Grow to at most 6 intervals (and never past 2 minutes): a panel that is
	// down for an hour costs ~60 lines an hour at most, none of them per player.
	new Float:wait = float(g_iInterval) * float(min(g_iFailStreak, 6))
	if (wait > 120.0)
		wait = 120.0
	g_fDownUntil = get_gametime() + wait

	// An unanswered ack is not lost work: the row is still game_acked_at = 0 on
	// the panel, so the next pull hands it back and the claim key makes
	// re-applying it a no-op. Said once, so it is not a per-action line.
	if (kind == WF_PULL_REQUEST_ACK && g_iFailStreak == 3)
		log_amx("[WF-PULL] ack for action %d was not confirmed - it comes back on the next pull", ackId)
	if (kind == WF_PULL_REQUEST_PENDING && id > 0)
		WfPullNextDue(id)
}

WfPullOk()
{
	if (g_iFailStreak >= 3)
		log_amx("[WF-PULL] panel reachable again - resuming the pull loop")
	g_iFailStreak = 0
	g_fDownUntil = 0.0
}

WfPullFinish()
{
	new kind = g_iReqKind
	new id = g_iReqClient
	new ackId = g_iReqAck
	new szTarget[40]
	copy(szTarget, charsmax(szTarget), g_szReqId)
	// WfPullClose() zeroes g_iRespLen, so keep the length: the reply buffer
	// itself survives the close (a closed connection does not retire bytes).
	WfPullClose()

	// HTTP/1.x status, then the body after the blank line.

	// The status line is the first bytes RECEIVED, and on this build the reply
	// buffer is only addressable from its start: g_szResp[0..] is empty after
	// every append and only g_szResp alone holds the text (a log of
	// g_szResp[0..47] after 827 good bytes printed nothing). So the status line
	// is read from the head of the buffer; the body is found by its marker.
	//
	// Nothing here may index the buffer: on this build g_szResp is only
	// addressable as a whole (g_szResp[0..] reads as "" after any append), so
	// the status line is kept separately in g_szHead and the body is located
	// by searching for its marker, then handed to json_parse as a string.
	g_szHead[15] = 0
	log_amx("[WF-PULL] dbg: head=[%s] strlen=%d", g_szHead, strlen(g_szHead))
	if (!g_szHead[0])
	{
		WfPullFail("no status line")
		return
	}
	new status = str_to_num(g_szHead[9])
	new hdrEnd = contain(g_szResp, "^r^n^r^n")
	if (hdrEnd < 0)
	{
		WfPullFail("no header terminator")
		return
	}
	new bodyStart = hdrEnd + 4
	if (bodyStart > strlen(g_szResp))
		bodyStart = strlen(g_szResp)
	// This build cannot index the buffer (see above): a slice would be "", so
	// the body gets its own buffer, located by the marker and copied whole.
	g_szBodyReply[0] = 0
	if (hdrEnd >= 0 && bodyStart < strlen(g_szResp))
	{
		new off = contain(g_szResp, "{")
		if (off >= 0)
			copy(g_szBodyReply, charsmax(g_szBodyReply), g_szResp)
	}

	if (status != 200)
	{
		// 401 is a wrong secret, 400 a bad steamid, 404 an ack for an id the
		// panel does not have. All are configuration or protocol errors, so one
		// line with the panel's own words beats a poll every 20 seconds.
		new szWhy[96]
		szWhy[0] = 0
		WfPullJsonError(g_szBodyReply, szWhy, charsmax(szWhy))
		if (status == 401)
			log_amx("[WF-PULL] panel said 401 (%s) - check [pull] secret matches the panel's SYNC_SECRET", szWhy)
		else if (kind == WF_PULL_REQUEST_ACK)
			log_amx("[WF-PULL] ack for action %d rejected: %d %s", ackId, status, szWhy)
		else
			log_amx("[WF-PULL] pending for %s rejected: %d %s", szTarget, status, szWhy)
		WfPullFail("http status")
		return
	}

	WfPullOk()

	if (kind == WF_PULL_REQUEST_ACK)
	{
		WfPullReadAck(ackId, id, g_szBodyReply)
		return
	}

	WfPullReadPending(id, g_szBodyReply)
}

// ============================================================
// GET /api/game/pending — parse, apply, ack
// ============================================================

WfPullReadPending(id, const body[])
{
	// An operator who forced the poll wants to know what came back, not only
	// what was applied: one line with the first bytes of the reply says whether
	// the panel answered, and with what.
	log_amx("[WF-PULL] pending reply for %s (%d bytes): %.56s", g_szReqId, strlen(body), body)

	new JSON:hRoot = json_parse(body)
	if (hRoot == Invalid_JSON)
	{
		log_amx("[WF-PULL] pending reply for %s is not JSON - ignored", g_szReqId)
		if (id > 0)
			WfPullNextDue(id)
		return
	}

	if (!json_is_object(hRoot))
	{
		json_free(hRoot)
		return
	}

	new JSON:hActions = json_object_get_value(hRoot, "actions")
	if (hActions == Invalid_JSON)
	{
		json_free(hRoot)
		return
	}

	new count = json_array_get_count(hActions)
	if (count > 0)
		log_amx("[WF-PULL] %s: %d action(s) pending", g_szReqId, count)

	for (new i = 0; i < count; i++)
	{
		// Never apply what there is no room to ack: an unacked apply is a
		// re-apply next pull, which is safe but pointless.
		if (WfPullAckRoom() <= 0)
		{
			log_amx("[WF-PULL] ack queue full - the rest of this batch waits for the next pull")
			break
		}
		new JSON:hAction = json_array_get_value(hActions, i)
		if (hAction == Invalid_JSON)
			continue
		WfPullOneAction(id, hAction)
		json_free(hAction)
	}

	json_free(hActions)
	json_free(hRoot)

	if (id > 0)
	{
		// A full page means there is probably more queued: come back soon
		// rather than in a whole interval.
		if (count >= WF_PULL_MAX_ACTIONS)
			g_fDue[id] = get_gametime() + 1.0
		else
			WfPullNextDue(id)
	}
}

WfPullOneAction(id, JSON:hAction)
{
	new actionId = json_object_get_number(hAction, "id")
	if (actionId <= 0)
		return

	new szKind[24], szState[16], szReason[WF_PULL_ERR_MAX]
	json_object_get_string(hAction, "kind", szKind, charsmax(szKind))
	json_object_get_string(hAction, "state", szState, charsmax(szState))
	szReason[0] = 0

	new verdict = WfPullApplyOne(id, hAction, actionId, szKind, szState, szReason, charsmax(szReason))
	if (verdict == WF_PULL_RETRY)
	{
		// The engine cannot decide yet (vault not loaded): leave the row on the
		// panel. It comes back next pull and the claim keys keep it one payout.
		log_amx("[WF-PULL] action %d (%s) deferred - the player's data is not loaded yet", actionId, szKind)
		return
	}

	if (verdict == WF_PULL_APPLIED)
	{
		log_amx("[WF-PULL] action %d %s -> applied", actionId, szKind)
		WfPullAckPush(actionId, true, "", id)
	}
	else
	{
		if (!szReason[0])
			copy(szReason, charsmax(szReason), "the game could not apply it")
		log_amx("[WF-PULL] action %d %s -> refused: %s", actionId, szKind, szReason)
		WfPullAckPush(actionId, false, szReason, id)
	}
}

// Returns WF_PULL_APPLIED / WF_PULL_REFUSED / WF_PULL_RETRY and fills `reason`
// for a refusal.
//
// `panelState` and not `state`: `state` is a Pawn keyword (the state-machine
// feature) and a parameter of that name makes amxxpc die with a bare
// std::bad_alloc instead of an error.
WfPullApplyOne(id, JSON:hAction, actionId, const kind[], const panelState[], reason[], rlen)
{
	// The panel's verdict first: a row it refused is mirrored by nothing and
	// reported back with the panel's own reason, which is what closes it.
	if (!equal(panelState, "applied"))
	{
		json_object_get_string(hAction, "error", reason, rlen)
		if (!reason[0])
			copy(reason, rlen, "refused by the panel")
		return WF_PULL_REFUSED
	}

	// The engine can only mirror onto a player it has. A row for a steamid with
	// no client (a manual drain of someone who has gone) is refused loudly
	// rather than left to block the queue forever.
	if (id <= 0 || !is_user_connected(id))
	{
		copy(reason, rlen, "player not connected - nothing to mirror onto")
		return WF_PULL_REFUSED
	}

	if (equal(kind, "claim_mission") || equal(kind, "grant") || equal(kind, "buy"))
		return WfPullApplyRewards(id, hAction, actionId, kind, reason, rlen)
	if (equal(kind, "claim_advent"))
		return WfPullApplyAdvent(id, hAction, actionId, reason, rlen)
	if (equal(kind, "plant_ornament"))
		return WfPullApplyPlant(id, hAction, actionId, reason, rlen)
	if (equal(kind, "equip"))
	{
		copy(reason, rlen, "the game has no equip state (titles are owned, not worn)")
		return WF_PULL_REFUSED
	}

	formatex(reason, rlen, "unknown action kind '%s'", kind)
	return WF_PULL_REFUSED
}

// The reward fields every paying kind shares (01-DATA.md §3). Each one lands
// through wf_grant, with the panel's action id in the claim key so a re-pull
// cannot pay twice.
WfPullApplyRewards(id, JSON:hAction, actionId, const kind[], reason[], rlen)
{
	new JSON:hPayload = json_object_get_value(hAction, "payload")
	if (hPayload == Invalid_JSON)
	{
		copy(reason, rlen, "the action carries no payload")
		return WF_PULL_REFUSED
	}

	new coins = WfPullNum(hPayload, "coins")
	new gingerbread = WfPullNum(hPayload, "gingerbread")
	new spins = WfPullNum(hPayload, "spins")
	new passxp = WfPullNum(hPayload, "pass_xp")
	new szItem[48], szProduct[48], szKey[64]
	WfPullStr(hPayload, "item", szItem, charsmax(szItem))
	WfPullStr(hPayload, "product", szProduct, charsmax(szProduct))

	new mirrored = 0
	new code

	if (coins > 0)
	{
		formatex(szKey, charsmax(szKey), "wf:a%d#coins", actionId)
		code = wf_grant(id, WF_REWARD_COINS, coins, szKey)
		if (code == WF_GRANT_NOTLOADED)
		{
			json_free(hPayload)
			return WF_PULL_RETRY
		}
		if (code == WF_GRANT_INVALID)
		{
			formatex(reason, rlen, "the game cannot pay %d coins", coins)
			json_free(hPayload)
			return WF_PULL_REFUSED
		}
		mirrored++
	}

	if (gingerbread > 0)
	{
		formatex(szKey, charsmax(szKey), "wf:a%d#gb", actionId)
		code = wf_grant(id, WF_REWARD_GINGERBREAD, gingerbread, szKey)
		if (code == WF_GRANT_NOTLOADED)
		{
			json_free(hPayload)
			return WF_PULL_RETRY
		}
		if (code == WF_GRANT_INVALID)
		{
			formatex(reason, rlen, "the game cannot pay %d GingerBread", gingerbread)
			json_free(hPayload)
			return WF_PULL_REFUSED
		}
		mirrored++
	}

	if (spins > 0)
	{
		formatex(szKey, charsmax(szKey), "wf:a%d#spins", actionId)
		code = wf_grant(id, WF_REWARD_SPINS, spins, szKey)
		if (code == WF_GRANT_NOTLOADED)
		{
			json_free(hPayload)
			return WF_PULL_RETRY
		}
		if (code == WF_GRANT_INVALID)
		{
			formatex(reason, rlen, "the game cannot pay %d spins", spins)
			json_free(hPayload)
			return WF_PULL_REFUSED
		}
		mirrored++
	}

	if (passxp > 0)
	{
		formatex(szKey, charsmax(szKey), "wf:a%d#xp", actionId)
		code = wf_grant(id, WF_REWARD_PASS_XP, passxp, szKey)
		if (code == WF_GRANT_NOTLOADED)
		{
			json_free(hPayload)
			return WF_PULL_RETRY
		}
		if (code == WF_GRANT_INVALID)
		{
			formatex(reason, rlen, "the game cannot pay %d Winter Pass XP", passxp)
			json_free(hPayload)
			return WF_PULL_REFUSED
		}
		mirrored++
	}

	if (szItem[0])
	{
		new verdict = WfPullGrantItem(id, szItem, actionId, reason, rlen)
		if (verdict == WF_PULL_RETRY || verdict == WF_PULL_REFUSED)
		{
			json_free(hPayload)
			return verdict
		}
		mirrored++
	}

	if (szProduct[0])
	{
		formatex(szKey, charsmax(szKey), "wf:a%d#prod", actionId)
		code = wf_grant_entitlement(id, szProduct, "panel", szKey)
		if (code == WF_GRANT_NOTLOADED)
		{
			json_free(hPayload)
			return WF_PULL_RETRY
		}
		if (code == WF_GRANT_INVALID)
		{
			formatex(reason, rlen, "product '%s' is not in [entitlement]", szProduct)
			json_free(hPayload)
			return WF_PULL_REFUSED
		}
		mirrored++
	}

	// A buy also carries a price. The engine cannot debit (see the header), so
	// the charge is reported instead of being silently dropped.
	if (equal(kind, "buy"))
		WfPullLogCharge(id, hPayload, actionId)

	json_free(hPayload)

	if (!mirrored)
	{
		copy(reason, rlen, "nothing in the action to mirror in game")
		return WF_PULL_REFUSED
	}
	return WF_PULL_APPLIED
}

WfPullLogCharge(id, JSON:hPayload, actionId)
{
	new JSON:hPrice = json_object_get_value(hPayload, "price")
	if (hPrice == Invalid_JSON)
		return
	new coins = WfPullNum(hPrice, "coins")
	new gb = WfPullNum(hPrice, "gingerbread")
	json_free(hPrice)
	if (!coins && !gb)
		return
	log_amx("[WF-PULL] action %d buy for id %d: item/product granted; the panel charged %d coins + %d GingerBread (the game holds no spend path - docs/WINTERFEST-PULL.md §4)",
		actionId, id, coins, gb)
}

// "ornament:12" and "title:3" are the two item kinds the engine can hold.
// Everything else the panel can sell (model, skin, badge, cosmetic) has no
// engine twin, and pretending otherwise would put a lie in the DB.
WfPullGrantItem(id, const item[], actionId, reason[], rlen)
{
	new colon = contain(item, ":")
	if (colon <= 0)
	{
		formatex(reason, rlen, "'%s' is not a kind:id item", item)
		return WF_PULL_REFUSED
	}

	new prefix[16], szId[32], szKey[64]
	copy(prefix, charsmax(prefix), item)
	prefix[colon] = 0
	copy(szId, charsmax(szId), item[colon + 1])
	new num = str_to_num(szId)

	if (equal(prefix, "ornament"))
	{
		if (num < 1 || num > wf_ornament_total())
		{
			formatex(reason, rlen, "ornament %d is not in the game's catalogue", num)
			return WF_PULL_REFUSED
		}
		if (wf_has_ornament(id, num))
			return WF_PULL_APPLIED          // already owned: nothing to mirror
		if (!wf_grant_ornament(id, num))
		{
			formatex(reason, rlen, "the game refused ornament %d", num)
			return WF_PULL_REFUSED
		}
		return WF_PULL_APPLIED
	}

	if (equal(prefix, "title"))
	{
		formatex(szKey, charsmax(szKey), "wf:a%d#title%d", actionId, num)
		new code = wf_grant(id, WF_REWARD_TITLE, num, szKey)
		if (code == WF_GRANT_NOTLOADED)
			return WF_PULL_RETRY
		if (code == WF_GRANT_INVALID)
		{
			formatex(reason, rlen, "set %d has no collector title to grant", num)
			return WF_PULL_REFUSED
		}
		return WF_PULL_APPLIED
	}

	formatex(reason, rlen, "the game cannot own '%s' (ornament:* and title:* only)", item)
	return WF_PULL_REFUSED
}

WfPullApplyAdvent(id, JSON:hAction, actionId, reason[], rlen)
{
	new JSON:hPayload = json_object_get_value(hAction, "payload")
	if (hPayload == Invalid_JSON)
	{
		copy(reason, rlen, "the action carries no payload")
		return WF_PULL_REFUSED
	}

	new day = WfPullNum(hPayload, "day")
	new declared = WfPullNum(hPayload, "gingerbread")
	json_free(hPayload)

	new before = wf_get_gingerbread(id)
	new code = wf_advent_claim(id, day)

	if (code == WF_ADVENT_CLAIM_OK)
	{
		new paid = wf_get_gingerbread(id) - before
		log_amx("[WF-PULL] action %d claim_advent: day %d paid %d GingerBread in game", actionId, day, paid)
		// The panel decided the amount; the ini paid its own. When they differ,
		// that is two catalogues disagreeing and nobody should have to guess.
		if (declared > 0 && declared != paid)
			log_amx("[WF-PULL] action %d: the panel paid %d GingerBread for day %d, winterfest.ini paid %d",
				actionId, declared, day, paid)
		return WF_PULL_APPLIED
	}
	if (code == WF_ADVENT_CLAIM_CLAIMED)
		return WF_PULL_APPLIED      // the calendar's own key already paid this day

	if (code == WF_ADVENT_CLAIM_EXPIRED)
		formatex(reason, rlen, "advent day %d has expired in game", day)
	else if (code == WF_ADVENT_CLAIM_LOCKED)
		formatex(reason, rlen, "advent day %d is not open in game", day)
	else
		formatex(reason, rlen, "advent day %d is not a valid day in game", day)
	return WF_PULL_REFUSED
}

WfPullApplyPlant(id, JSON:hAction, actionId, reason[], rlen)
{
	new JSON:hPayload = json_object_get_value(hAction, "payload")
	if (hPayload == Invalid_JSON)
	{
		copy(reason, rlen, "the action carries no payload")
		return WF_PULL_REFUSED
	}

	new slot = WfPullNum(hPayload, "slot")
	new ornament = WfPullNum(hPayload, "ornament")
	new level = WfPullNum(hPayload, "level")
	json_free(hPayload)

	if (slot < 1 || slot > WF_TREE_SLOTS)
	{
		formatex(reason, rlen, "slot %d is outside the 24-slot tree in game", slot)
		return WF_PULL_REFUSED
	}
	if (!wf_has_ornament(id, ornament))
	{
		formatex(reason, rlen, "ornament %d is not owned in game", ornament)
		return WF_PULL_REFUSED
	}
	if (wf_tree_set_slot(id, slot, ornament) != WF_GRANT_OK)
	{
		formatex(reason, rlen, "the game refused slot %d for ornament %d", slot, ornament)
		return WF_PULL_REFUSED
	}
	// `level` is derived in game from completed sets (1 + sets done); there is
	// no native that sets it, and inventing one would let the panel write a
	// number the tree does not support. Said out loud instead of dropped.
	if (level > 0 && level != wf_tree_level(id))
		log_amx("[WF-PULL] action %d: the panel says tree level %d, the game derives %d from its sets (not written)",
			actionId, level, wf_tree_level(id))
	return WF_PULL_APPLIED
}

// ============================================================
// POST /api/game/ack — one call per action
// ============================================================

WfPullAckRoom()
{
	return WF_PULL_MAX_ACKS - (g_iAckTail - g_iAckHead)
}

WfPullAckPush(actionId, bool:applied, const error[], client)
{
	if (WfPullAckRoom() <= 0)
		return
	new slot = g_iAckTail % WF_PULL_MAX_ACKS
	g_iAckId[slot] = actionId
	g_iAckOk[slot] = applied ? 1 : 0
	g_iAckWho[slot] = client
	copy(g_szAckErr[slot], WF_PULL_ERR_MAX - 1, error)
	g_iAckTail++
}

WfPullSendAck()
{
	if (g_iAckHead == g_iAckTail)
		return
	new slot = g_iAckHead % WF_PULL_MAX_ACKS
	new actionId = g_iAckId[slot]
	new bool:applied = g_iAckOk[slot] ? true : false

	// The body is built once here and signed as-is, so what the panel checks
	// and what the panel parses are the same bytes.
	new i
	if (applied)
		i = formatex(g_szBody, charsmax(g_szBody), "{^"id^":%d,^"state^":^"applied^"}", actionId)
	else
		i = formatex(g_szBody, charsmax(g_szBody), "{^"id^":%d,^"state^":^"refused^",^"error^":^"", actionId)
	if (!applied)
	{
		new szEsc[WF_PULL_ERR_MAX + 8]
		WfPullEscape(g_szAckErr[slot], szEsc, charsmax(szEsc))
		i += formatex(g_szBody[i], charsmax(g_szBody) - i, "%s^"}", szEsc)
	}

	g_iAckHead++
	g_iReqAck = actionId
	if (!WfPullStart(WF_PULL_REQUEST_ACK, g_iAckWho[slot], ""))
	{
		// No transport (disabled, or already busy): put it back at the head so
		// the next tick tries again.
		g_iAckHead--
	}
}

WfPullReadAck(actionId, client, const body[])
{
	new JSON:hRoot = json_parse(body)
	if (hRoot == Invalid_JSON)
		return
	new ok = 1
	new already = 0
	if (json_object_has_value(hRoot, "ok", JSONBoolean))
		ok = json_object_get_bool(hRoot, "ok") ? 1 : 0
	if (json_object_has_value(hRoot, "already", JSONBoolean))
		already = json_object_get_bool(hRoot, "already") ? 1 : 0
	json_free(hRoot)

	if (!ok)
	{
		log_amx("[WF-PULL] ack for action %d was not accepted by the panel - it will come back", actionId)
		return
	}
	if (already)
		log_amx("[WF-PULL] action %d was already acked (a retry landed twice - harmless)", actionId)

	// The last confirmed id per player: the one piece of per-player state this
	// plugin keeps, and only in memory.
	if (client > 0 && actionId > g_iLastAck[client])
		g_iLastAck[client] = actionId
}

WfPullClientOf(const steamid[])
{
	for (new id = 1; id <= MaxClients; id++)
	{
		if (!is_user_connected(id) || is_user_bot(id) || is_user_hltv(id))
			continue
		new auth[40]
		get_user_authid(id, auth, charsmax(auth))
		if (equal(auth, steamid))
			return id
	}
	return 0
}

// ============================================================
// Helpers
// ============================================================

WfPullNum(JSON:obj, const name[])
{
	if (!json_object_has_value(obj, name, JSONNumber))
		return 0
	new v = json_object_get_number(obj, name)
	return (v > 0) ? v : 0
}

WfPullStr(JSON:obj, const name[], out[], len)
{
	out[0] = 0
	if (!json_object_has_value(obj, name, JSONString))
		return
	json_object_get_string(obj, name, out, len)
}

// The panel's own words out of a {"ok":false,"error":"…"} body. Best effort:
// an unparsable body leaves `out` empty, which the caller's format renders as
// nothing rather than as a lie.
WfPullJsonError(const body[], out[], len)
{
	out[0] = 0
	if (!body[0])
		return
	new JSON:hRoot = json_parse(body)
	if (hRoot == Invalid_JSON)
		return
	if (json_object_has_value(hRoot, "error", JSONString))
		json_object_get_string(hRoot, "error", out, len)
	json_free(hRoot)
}

// The JSON in the body, escaped for a string literal: only what the ack field
// accepts, and never a stray quote that would break the panel's parse.
WfPullEscape(const src[], out[], len)
{
	new j = 0
	out[0] = 0
	for (new i = 0; src[i] && j < len - 1; i++)
	{
		new ch = src[i]
		if (ch == 34 || ch == 92 || ch < 32 || ch > 126)
			ch = 39   // '
		out[j++] = ch
	}
	out[j] = 0
}

// ============================================================
// Console commands (operator tools and the local proof)
// ============================================================

public cmdPullNow(id, level, cid)
{
	if (!cmd_access(id, level, cid, 2))
		return PLUGIN_HANDLED

	new arg[64]
	read_argv(1, arg, charsmax(arg))

	if (!g_bConfigured)
	{
		console_print(id, "[WF-PULL] not configured - check [pull] in winterfest.ini and 'wf_pull_status'")
		return PLUGIN_HANDLED
	}

	if (equal(arg, "all") || equal(arg, "*"))
	{
		new n = 0
		for (new p = 1; p <= MaxClients; p++)
		{
			if (!WfPullEligible(p))
				continue
			g_bForce[p] = true
			n++
		}
		console_print(id, "[WF-PULL] polling %d player(s), one request at a time", n)
		log_amx("[WF-PULL] operator poll: %d connected player(s) queued", n)
		return PLUGIN_HANDLED
	}

	// A steamid drains that player's queue even if they are not here (the
	// actions are then refused with "player not connected", which is how a row
	// for a player who left stops blocking the queue).
	if (WfPullValidSteam(arg))
	{
		g_iManualClient = WfPullClientOf(arg)
		copy(g_szManualId, charsmax(g_szManualId), arg)
		g_bManual = true
		console_print(id, "[WF-PULL] queued a poll for %s%s", arg,
			g_iManualClient ? "" : " (not connected - the actions will be refused)")
		// The console of a headless server is docker's stdout, which drops
		// un-prefixed print output: an operator action that spends a network
		// round trip belongs in the log anyway.
		log_amx("[WF-PULL] operator poll for %s (client %d)", arg, g_iManualClient)
		return PLUGIN_HANDLED
	}

	new target = cmd_target(id, arg, CMDTARGET_ALLOW_SELF)
	if (!target)
	{
		console_print(id, "[WF-PULL] no such player: %s", arg)
		return PLUGIN_HANDLED
	}
	if (!WfPullEligible(target))
	{
		console_print(id, "[WF-PULL] %s has no steamid the panel accepts (bot, HLTV or not authenticated yet)", arg)
		return PLUGIN_HANDLED
	}
	g_bForce[target] = true
	new auth[40]
	get_user_authid(target, auth, charsmax(auth))
	console_print(id, "[WF-PULL] queued a poll for %s", auth)
	log_amx("[WF-PULL] operator poll for %s (client %d)", auth, target)
	return PLUGIN_HANDLED
}

public cmdPullStatus(id, level, cid)
{
	if (!cmd_access(id, level, cid, 1))
		return PLUGIN_HANDLED

	console_print(id, "[WF-PULL] configured=%s enabled=%s url=http://%s:%d interval=%d timeout=%d secret=%s",
		g_bConfigured ? "yes" : "no", g_bEnabled ? "yes" : "no",
		g_szHost, g_iPort, g_iInterval, floatround(g_fTimeout), g_szSecret[0] ? "set" : "MISSING")
	console_print(id, "[WF-PULL] core=%s initsocket=%d fail streak=%d pending acks=%d",
		LibraryExists("winterfest_core", LibType_Library) ? "yes" : "no",
		g_iSocket, g_iFailStreak, g_iAckTail - g_iAckHead)

	for (new p = 1; p <= MaxClients; p++)
	{
		if (!WfPullEligible(p))
			continue
		new auth[40], name[32]
		get_user_authid(p, auth, charsmax(auth))
		get_user_name(p, name, charsmax(name))
		console_print(id, "[WF-PULL]   #%d %s (%s) last acked=%d", p, name, auth, g_iLastAck[p])
	}
	return PLUGIN_HANDLED
}

public cmdPullConfig(id, level, cid)
{
	if (!cmd_access(id, level, cid, 1))
		return PLUGIN_HANDLED

	if (!WfPullLoadConfig())
	{
		console_print(id, "[WF-PULL] could not read winterfest.ini")
		return PLUGIN_HANDLED
	}
	g_bConfigured = false
	if (!g_bEnabled)
		console_print(id, "[WF-PULL] reloaded: enabled = 0")
	else if (!g_szSecret[0])
		console_print(id, "[WF-PULL] reloaded: no secret")
	else if (!WfPullParseUrl())
		console_print(id, "[WF-PULL] reloaded: url unusable")
	else
	{
		g_bConfigured = true
		console_print(id, "[WF-PULL] reloaded: http://%s:%d every %ds", g_szHost, g_iPort, g_iInterval)
	}
	return PLUGIN_HANDLED
}

// ============================================================
// Native: poll for a specific identity onto a specific client
// ============================================================
// wf_pull_request(id, steamid) - queue a poll for `steamid` and apply the
// result onto client `id` (0 = no client: everything is refused, which is what
// drains a queue for a player who is not here).
//
// The production loop never needs this: it derives the identity from the
// connected client. It exists for two callers that do: an operator tool, and
// tests/winterfest/wf_pull_probe.sma, which has no Steam client to connect and
// binds a synthetic steamid to a bot slot instead.
public native_pull_request(plugin, params)
{
	new id = get_param(1)
	new steamid[40]
	get_string(2, steamid, charsmax(steamid))

	if (!g_bConfigured)
	{
		log_amx("[WF-PULL] wf_pull_request refused: not configured (configured=%d enabled=%d secret=%s url=%s:%d)",
			g_bConfigured, g_bEnabled, g_szSecret[0] ? "set" : "MISSING", g_szHost, g_iPort)
		return 0
	}
	if (!WfPullValidSteam(steamid))
	{
		log_amx("[WF-PULL] wf_pull_request refused: '%s' is not a steamid", steamid)
		return 0
	}
	if (id > 0 && !is_user_connected(id))
	{
		log_amx("[WF-PULL] wf_pull_request refused: client %d is not connected", id)
		return 0
	}

	g_iManualClient = (id > 0) ? id : 0
	copy(g_szManualId, charsmax(g_szManualId), steamid)
	g_bManual = true
	return 1
}
