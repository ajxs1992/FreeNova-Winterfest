/*
 * ============================================================================
 * winterfest_mail — the envelope, game side (workstream 15)
 * ============================================================================
 * Product contract: docs/WINTERFEST-WORKSTREAMS.md row 15, the owner's envelope
 * decision (docs/WINTERFEST.md section 6.3). Panel side: web-panel/src/winter/
 * mail.js. The developer write-up, the payloads and the honest scope:
 * docs/WINTERFEST-LEVELS-MAIL.md.
 *
 * WHAT THIS PLUGIN IS
 *   The in-game half of the inbox behind the envelope in the dashboard:
 *     - on connect it reads the player's unread count and tells them about it
 *       ("You have N messages - type !mail"), and it logs that read so an
 *       operator (and the harness) can see the count was actually fetched;
 *     - `/mail` (or `!mail`) opens a short menu of the five newest titles;
 *     - picking one shows it and marks THAT message read - opening the list
 *       marks nothing, which is the whole idempotency contract here;
 *     - `wf_mail_send <target|@all> <kind> <title>` lets staff push a message
 *       from the server console today, with no panel round-trip;
 *     - `wfm_deliver()` is the one function the game's sync plugin calls for a
 *       `wf_mail` action, so panel-written mail arrives the same way
 *       `wf_tree_move` is meant to (see "THE PANEL BRIDGE" below).
 *
 * STORAGE (nvault, this module's own file)
 *   freenova_wfm, key `wfm_<authid>`: up to WF_MAIL_MAX entries, each
 *     src;id;kind;created;expires;read_at;title
 *   joined by '~'. `src` is 0 for mail written in game and 1 for a message the
 *   panel delivered (its `id` is then the panel's winter_mail id, which is what
 *   makes the read report meaningful). `read_at` is 0 while unread, otherwise the
 *   epoch second the player opened it. An entry is invisible when `expires` is in
 *   the past and `expires` is not 0.
 *   key `wfm_next`: the in-game id counter (game-origin ids never collide with
 *   the panel's, because `src` says which id space a row belongs to).
 *
 *   Mail is deliberately NOT season-stamped the way the core's `wf_` keys are:
 *   an inbox that erases itself on 1 January would lose announcements that are
 *   still being referred to in February. The data is kept; the WELCOME line
 *   respects wf_mail_welcome, and the plugin as a whole pauses without the core.
 *
 * THE PANEL BRIDGE (why wfm_deliver exists and who calls it)
 *   The panel's mailbox of record is the `winter_mail` table. The only channel
 *   panel -> game is the `actions` array in the push response, executed by
 *   freenova_sync.amxx. That file belongs to the coordinator, so this plugin
 *   exports the receiving end (wfm_deliver) and documents the one dispatch line
 *   it needs in docs/WINTERFEST-LEVELS-MAIL.md, "The exact payloads". Until that
 *   line exists, in-game mail still works through wf_mail_send, and nothing here
 *   silently pretends the panel's mail arrived.
 *
 * THE CORE IS OPTIONAL
 *   plugin_natives() installs the set_native_filter() guard from fn_servers.sma
 *   and plugin_init() pauses the plugin when LibraryExists("winterfest_core")
 *   is false, so a server without the core behaves exactly like today's server.
 *   The only core native this module reads is wf_get_pending(), the counter the
 *   core reserves for the envelope; it appears in the connect log line, and is
 *   never used to decide whether a player has mail (the vault is the truth).
 *
 * NOT IN THIS PLUGIN
 *   No player-to-player mail (owner decision: a later step), no claims (Phase 1
 *   has no level-reward or mail claim ledger), no client asset of any kind, no
 *   precache, and no write to another module's storage.
 * ============================================================================
 */

#include <amxmodx>
#include <amxmisc>
#include <nvault>
#include <winterfest>
#include <winterfest_mail>

#define PLUGIN  "Winterfest Mail"
#define VERSION "1.0.0"
#define AUTHOR  "FreeNova"

#define VAULT_NAME "freenova_wfm"
#define VAULT_KEY_NEXT "wfm_next"

// Limits. A player's cache is small on purpose: the panel is the mailbox, this
// is a delivery cache that fits in one chat menu.
#define WF_MAIL_MAX   12     // entries kept per player
#define WF_MENU_SHOW  5      // the five titles the brief asks for in game
#define WF_TITLE_LEN  56     // stored title (the panel caps its own at 80)
#define WF_BUF_LEN    1536   // the serialized vault value

// src column: whose id space `id` belongs to.
#define MAIL_SRC_GAME  0
#define MAIL_SRC_PANEL 1

// kind codes, in the order web-panel/src/winter/mail.js MAIL_KINDS uses.
#define MAIL_KIND_SYSTEM 0
#define MAIL_KIND_EVENT  1
#define MAIL_KIND_GRANT  2
#define MAIL_KIND_ADMIN  3

new g_Vault = INVALID_HANDLE
new g_cvEnable
new g_cvWelcome

new g_iCount[MAX_PLAYERS + 1]
new g_iSrc[MAX_PLAYERS + 1][WF_MAIL_MAX]
new g_iId[MAX_PLAYERS + 1][WF_MAIL_MAX]
new g_iKind[MAX_PLAYERS + 1][WF_MAIL_MAX]
new g_iCreated[MAX_PLAYERS + 1][WF_MAIL_MAX]
new g_iExpires[MAX_PLAYERS + 1][WF_MAIL_MAX]
new g_iReadAt[MAX_PLAYERS + 1][WF_MAIL_MAX]
new g_szTitle[MAX_PLAYERS + 1][WF_MAIL_MAX][WF_TITLE_LEN]
new g_bLoaded[MAX_PLAYERS + 1]
new g_iTestTries

new const g_szKindName[][] = { "System", "Event", "Reward", "Staff" }

// ---------------------------------------------------------------- plugin ----
public plugin_init()
{
	register_plugin(PLUGIN, VERSION, AUTHOR)

	g_cvEnable = register_cvar("wf_mail_enable", "1")
	g_cvWelcome = register_cvar("wf_mail_welcome", "1")

	register_clcmd("say /mail", "cmdMail")
	register_clcmd("say_team /mail", "cmdMail")
	register_clcmd("say !mail", "cmdMail")
	register_clcmd("say_team !mail", "cmdMail")

	register_concmd("wf_mail_send", "cmdSend", ADMIN_CFG,
		"<target|@all> <system|event|grant|admin> <title...> - send one in-game message")
	register_concmd("wf_mail_state", "cmdState", ADMIN_CFG,
		"[target|@all] - print the delivery cache and the unread count")
	register_concmd("wf_mail_clear", "cmdClear", ADMIN_CFG,
		"<target|@all> - empty a player's in-game mail cache (the panel copy is untouched)")
	register_concmd("wf_mail_test", "cmdTest", ADMIN_CFG,
		"[target] - put two demo messages in a cache and re-run the connect read")

	if (!LibraryExists("winterfest_core", LibType_Library))
	{
		log_amx("[WF-MAIL] winterfest_core missing - pausing self (no in-game inbox this map)")
		pause("d")
		return
	}

	server_print("[FreeNova winterfest_mail] ready (build 1, %d cvars, 4 commands, menu %d)", 2, WF_MENU_SHOW)
}

public plugin_natives()
{
	register_library("winterfest_mail")
	register_native("wfm_unread", "native_unread")
	register_native("wfm_count", "native_count")
	register_native("wfm_deliver", "native_deliver")
	register_native("wfm_reads", "native_reads")
	register_native("wfm_find", "native_find")
	set_native_filter("MailNativeFilter")
}

/**
 * A missing core must degrade a wf_* call to 0 instead of failing the load. The
 * narrow rule (only wf_* names, only outside a trap) is fn_servers.sma's, and it
 * keeps a genuine mistake visible.
 */
public MailNativeFilter(const name[], index, trap)
{
	if (!trap && contain(name, "wf_") == 0 && !LibraryExists("winterfest_core", LibType_Library))
		return PLUGIN_HANDLED
	return PLUGIN_CONTINUE
}

public plugin_cfg()
{
	if (!LibraryExists("winterfest_core", LibType_Library))
		return

	g_Vault = nvault_open(VAULT_NAME)
	if (g_Vault == INVALID_HANDLE)
	{
		log_amx("[WF-MAIL] ERROR: nvault_open('%s') failed - the in-game inbox will not persist", VAULT_NAME)
		return
	}
	log_amx("[WF-MAIL] vault '%s' open - menu shows %d titles, cache holds %d", VAULT_NAME, WF_MENU_SHOW, WF_MAIL_MAX)
}

public plugin_end()
{
	if (g_Vault != INVALID_HANDLE)
		nvault_close(g_Vault)
	g_Vault = INVALID_HANDLE
}

// -------------------------------------------------------------- lifecycle ---
public client_putinserver(id)
{
	g_bLoaded[id] = false
	g_iCount[id] = 0

	if (!get_pcvar_num(g_cvEnable))
		return
	// The cache is read a few seconds in: a player's auth id is not reliable at
	// putinserver while the steam id is still being authorised, and the welcome
	// line must not fire before the player can read it. Bots get the same read
	// (their log line is the cheapest proof the path works) but never the chat.
	set_task(4.0, "Task_Welcome", id)
}

public client_disconnected(id)
{
	remove_task(id)
	g_iCount[id] = 0
	g_bLoaded[id] = false
}

/**
 * The connect read the brief asks for: one log line with the count, plus one
 * chat line to a human. Reads, claims nothing, marks nothing.
 */
public Task_Welcome(id)
{
	if (!is_user_connected(id))
		return
	if (!get_pcvar_num(g_cvEnable))
		return
	if (!MailLoad(id))
		return

	new unread = MailUnread(id)
	new szAuth[40]
	get_user_authid(id, szAuth, charsmax(szAuth))
	if (!szAuth[0])
		copy(szAuth, charsmax(szAuth), "<no auth>")

	// The core keeps a reserved counter for the envelope (wf_get_pending). Read
	// it for the log line only: it is not what decides "you have mail".
	new corePending = -1
	if (LibraryExists("winterfest_core", LibType_Library))
		corePending = wf_get_pending(id)

	log_amx("[WF-MAIL] %s unread=%d cached=%d core_pending=%d", szAuth, unread, g_iCount[id], corePending)

	if (!unread || !get_pcvar_num(g_cvWelcome))
		return
	if (is_user_bot(id) || is_user_hltv(id))
		return

	if (unread == 1)
		client_print_color(id, print_team_default, "^4[WF]^1 You have ^3%d^1 message - type ^3!mail^1 to read it.", unread)
	else
		client_print_color(id, print_team_default, "^4[WF]^1 You have ^3%d^1 messages - type ^3!mail^1 to read them.", unread)
}

// ------------------------------------------------------------------ vault ---
/** Load one player's cache from the vault into memory. False when it failed. */
bool:MailLoad(id)
{
	if (g_bLoaded[id])
		return true
	if (g_Vault == INVALID_HANDLE)
		return false

	new szKey[48], szAuth[40]
	get_user_authid(id, szAuth, charsmax(szAuth))
	formatex(szKey, charsmax(szKey), "wfm_%s", szAuth)

	new szValue[WF_BUF_LEN]
	g_iCount[id] = 0
	if (nvault_get(g_Vault, szKey, szValue, charsmax(szValue)))
		MailParse(id, szValue)

	g_bLoaded[id] = true
	return true
}

/** Serialize the in-memory cache back to the vault. */
bool:MailSave(id)
{
	if (g_Vault == INVALID_HANDLE)
		return false

	new szAuth[40], szKey[48]
	get_user_authid(id, szAuth, charsmax(szAuth))
	if (!szAuth[0])
		return false
	formatex(szKey, charsmax(szKey), "wfm_%s", szAuth)

	new szValue[WF_BUF_LEN], szEntry[160]
	szValue[0] = 0
	for (new i = 0; i < g_iCount[id]; i++)
	{
		formatex(szEntry, charsmax(szEntry), "%d;%d;%d;%d;%d;%d;%s",
			g_iSrc[id][i], g_iId[id][i], g_iKind[id][i],
			g_iCreated[id][i], g_iExpires[id][i], g_iReadAt[id][i], g_szTitle[id][i])
		if (szValue[0])
			add(szValue, charsmax(szValue), "~")
		add(szValue, charsmax(szValue), szEntry)
	}
	if (!szValue[0])
	{
		nvault_remove(g_Vault, szKey)
		return true
	}
	return nvault_set(g_Vault, szKey, szValue) ? true : false
}

/** Parse the serialized cache. A malformed row is dropped, never guessed. */
MailParse(id, const szValue[])
{
	new szEntry[192], szRest[WF_BUF_LEN]
	copy(szRest, charsmax(szRest), szValue)
	new count = 0

	while (szRest[0] && count < WF_MAIL_MAX)
	{
		new pos = contain(szRest, "~")
		if (pos < 0)
		{
			copy(szEntry, charsmax(szEntry), szRest)
			szRest[0] = 0
		}
		else
		{
			copy(szEntry, charsmax(szEntry), szRest)
			szEntry[pos] = 0
			copy(szRest, charsmax(szRest), szRest[pos + 1])
		}
		if (MailAddRaw(id, szEntry))
			count++
		if (!szRest[0])
			break
	}
	g_iCount[id] = count
}

/** One `src;id;kind;created;expires;read_at;title` row into the cache. */
bool:MailAddRaw(id, const szEntry[])
{
	new szF[WF_TITLE_LEN + 8]
	if (g_iCount[id] < 0 || g_iCount[id] >= WF_MAIL_MAX)
		return false

	// A row with no id is not a message: skip it rather than draw a ghost.
	new szId[16]
	if (!MailSplit(szEntry, 1, szId, charsmax(szId)) || !szId[0] || str_to_num(szId) <= 0)
		return false

	new slot = g_iCount[id]
	new szSrc[8], szKind[8], szCreated[16], szExpires[16], szRead[16]
	MailSplit(szEntry, 0, szSrc, charsmax(szSrc))
	MailSplit(szEntry, 2, szKind, charsmax(szKind))
	MailSplit(szEntry, 3, szCreated, charsmax(szCreated))
	MailSplit(szEntry, 4, szExpires, charsmax(szExpires))
	MailSplit(szEntry, 5, szRead, charsmax(szRead))
	MailSplit(szEntry, 6, szF, charsmax(szF))

	g_iSrc[id][slot] = clamp(str_to_num(szSrc), 0, 1)
	g_iId[id][slot] = str_to_num(szId)
	g_iKind[id][slot] = clamp(str_to_num(szKind), 0, MAIL_KIND_ADMIN)
	g_iCreated[id][slot] = str_to_num(szCreated)
	g_iExpires[id][slot] = str_to_num(szExpires)
	g_iReadAt[id][slot] = str_to_num(szRead)
	copy(g_szTitle[id][slot], WF_TITLE_LEN, szF)
	g_iCount[id] = slot + 1
	return true
}

/** Field `index` of a ';'-separated row. Bounded; a missing field yields "". */
bool:MailSplit(const line[], index, output[], len)
{
	output[0] = 0
	new n = strlen(line), start = 0, cur = 0
	for (new i = 0; i <= n; i++)
	{
		if (i < n && line[i] != ';')
			continue
		if (cur == index)
		{
			new c = i - start
			if (c < 0)
				c = 0
			if (c > len - 1)
				c = len - 1
			for (new k = 0; k < c; k++)
				output[k] = line[start + k]
			output[c] = 0
			trim(output)
			return true
		}
		cur++
		start = i + 1
	}
	return false
}

/**
 * Sanitize a title for the vault format and for a chat line: no '~', ';', '|',
 * newlines, quotes or angle brackets, and a hard length cap. A title is data;
 * it is never handed to a print call as the format string.
 */
MailCleanTitle(const input[], output[], len)
{
	new n = strlen(input), j = 0
	for (new i = 0; i < n && j < len - 1; i++)
	{
		new ch = input[i]
		// '^' is the engine's colour/escape prefix in a chat line, so a title
		// containing it is cleaned here rather than printed raw.
		if (ch == '~' || ch == ';' || ch == '|' || ch == '^n' || ch == '^r'
			|| ch == '"' || ch == '<' || ch == '>' || ch == 94)
		{
			if (j > 0 && output[j - 1] != ' ')
				output[j++] = ' '
			continue
		}
		output[j++] = ch
	}
	output[j] = 0
	trim(output)
	if (!output[0])
		copy(output, len, "(no title)")
}

/** The in-game id counter. One key, one increment, its own id space. */
MailNextId()
{
	if (g_Vault == INVALID_HANDLE)
		return 0
	new szBuf[16]
	new next = 1
	if (nvault_get(g_Vault, VAULT_KEY_NEXT, szBuf, charsmax(szBuf)))
		next = str_to_num(szBuf) + 1
	num_to_str(next, szBuf, charsmax(szBuf))
	nvault_set(g_Vault, VAULT_KEY_NEXT, szBuf)
	return next
}

// ------------------------------------------------------------------- core ---
/** Unread = not read and not expired. Expiry 0 means never. */
MailUnread(id)
{
	new now = get_systime(), n = 0
	for (new i = 0; i < g_iCount[id]; i++)
	{
		if (g_iReadAt[id][i])
			continue
		if (g_iExpires[id][i] > 0 && g_iExpires[id][i] <= now)
			continue
		n++
	}
	return n
}

bool:MailVisible(id, index)
{
	if (index < 0 || index >= g_iCount[id])
		return false
	if (g_iExpires[id][index] > 0 && g_iExpires[id][index] <= get_systime())
		return false
	return true
}

/** Index of the message with this (src, id), or -1. The duplicate guard. */
MailFind(id, src, mailid)
{
	for (new i = 0; i < g_iCount[id]; i++)
		if (g_iSrc[id][i] == src && g_iId[id][i] == mailid)
			return i
	return -1
}

/** Remove expired entries in place. Returns how many went. */
MailPrune(id)
{
	new now = get_systime(), removed = 0
	for (new i = 0; i < g_iCount[id];)
	{
		if (g_iExpires[id][i] > 0 && g_iExpires[id][i] <= now)
		{
			for (new j = i + 1; j < g_iCount[id]; j++)
			{
				g_iSrc[id][j - 1] = g_iSrc[id][j]
				g_iId[id][j - 1] = g_iId[id][j]
				g_iKind[id][j - 1] = g_iKind[id][j]
				g_iCreated[id][j - 1] = g_iCreated[id][j]
				g_iExpires[id][j - 1] = g_iExpires[id][j]
				g_iReadAt[id][j - 1] = g_iReadAt[id][j]
				copy(g_szTitle[id][j - 1], WF_TITLE_LEN, g_szTitle[id][j])
			}
			g_iCount[id]--
			removed++
			continue
		}
		i++
	}
	if (g_iCount[id] < 0)
		g_iCount[id] = 0
	return removed
}

/**
 * Add (or refresh) one entry. Returns WF_MAIL_ADDED / WF_MAIL_EXISTS /
 * WF_MAIL_INVALID. Expired entries are pruned first, and the oldest entry is
 * dropped when the cache is full, so the newest message always lands.
 */
MailAdd(id, src, mailid, kind, created, expires, const title[])
{
	if (mailid <= 0 || !title[0])
		return WF_MAIL_INVALID

	MailPrune(id)

	new existing = MailFind(id, src, mailid)
	if (existing >= 0)
	{
		// A re-delivery of the same message: it stays the same message, and its
		// read timestamp survives.
		g_iKind[id][existing] = clamp(kind, 0, MAIL_KIND_ADMIN)
		g_iCreated[id][existing] = created
		g_iExpires[id][existing] = expires
		MailCleanTitle(title, g_szTitle[id][existing], WF_TITLE_LEN)
		return WF_MAIL_EXISTS
	}

	if (g_iCount[id] >= WF_MAIL_MAX)
	{
		for (new i = 1; i < g_iCount[id]; i++)
		{
			g_iSrc[id][i - 1] = g_iSrc[id][i]
			g_iId[id][i - 1] = g_iId[id][i]
			g_iKind[id][i - 1] = g_iKind[id][i]
			g_iCreated[id][i - 1] = g_iCreated[id][i]
			g_iExpires[id][i - 1] = g_iExpires[id][i]
			g_iReadAt[id][i - 1] = g_iReadAt[id][i]
			copy(g_szTitle[id][i - 1], WF_TITLE_LEN, g_szTitle[id][i])
		}
		g_iCount[id]--
	}

	new slot = g_iCount[id]
	g_iSrc[id][slot] = clamp(src, 0, 1)
	g_iId[id][slot] = mailid
	g_iKind[id][slot] = clamp(kind, 0, MAIL_KIND_ADMIN)
	g_iCreated[id][slot] = created
	g_iExpires[id][slot] = expires
	g_iReadAt[id][slot] = 0
	MailCleanTitle(title, g_szTitle[id][slot], WF_TITLE_LEN)
	g_iCount[id] = slot + 1
	return WF_MAIL_ADDED
}

// ------------------------------------------------------------------- menu ---
public cmdMail(id)
{
	// Player-facing entry point: never a bot, never HLTV, never the console.
	if (!MailValidPlayer(id, 1))
		return PLUGIN_HANDLED
	if (!MailLoad(id))
	{
		WfSay(id, "The inbox is not available right now (no vault).")
		return PLUGIN_HANDLED
	}
	MailPrune(id)

	new unread = MailUnread(id)
	if (!g_iCount[id])
	{
		WfSay(id, "You have no messages.")
		return PLUGIN_HANDLED
	}

	new szTitle[96]
	formatex(szTitle, charsmax(szTitle), "Mail - %d message%s (%d unread)",
		g_iCount[id], g_iCount[id] == 1 ? "" : "s", unread)

	new menu = menu_create(szTitle, "MailMenuHandler")
	new szItem[96], szInfo[8], shown = 0

	// Newest first: walk backwards, and only the most recent WF_MENU_SHOW rows.
	for (new i = g_iCount[id] - 1; i >= 0 && shown < WF_MENU_SHOW; i--)
	{
		if (!MailVisible(id, i))
			continue
		formatex(szItem, charsmax(szItem), "%s%s", g_iReadAt[id][i] ? "" : "* ", g_szTitle[id][i])
		num_to_str(i, szInfo, charsmax(szInfo))
		menu_additem(menu, szItem, szInfo, 0)
		shown++
	}
	if (!shown)
	{
		menu_destroy(menu)
		WfSay(id, "Every message in the inbox has expired.")
		return PLUGIN_HANDLED
	}
	menu_setprop(menu, MPROP_EXIT, MEXIT_ALL)
	menu_display(id, menu, 0)

	// Opening the list marks nothing: the player has to pick a message before a
	// read timestamp moves.
	WfSay(id, "Pick a message to read it. * = unread. Opening this list marked nothing.")
	return PLUGIN_HANDLED
}

public MailMenuHandler(id, menu, item)
{
	if (item < 0)
	{
		menu_destroy(menu)
		return PLUGIN_HANDLED
	}
	new szInfo[8], szName[96], access, callback
	menu_item_getinfo(menu, item, access, szInfo, charsmax(szInfo), szName, charsmax(szName), callback)
	menu_destroy(menu)

	MailShow(id, str_to_num(szInfo))
	return PLUGIN_HANDLED
}

/**
 * Show one message and mark THAT one read (a no-op when it already is).
 * Public on purpose: the menu handler is the normal caller, and the harness
 * probe calls it directly to prove the read -> wfm_reads report without a human
 * clicking a chat menu.
 */
public MailShow(id, index)
{
	if (!MailLoad(id) || !MailVisible(id, index))
	{
		WfSay(id, "That message is no longer in your inbox.")
		return
	}

	new szCreated[24], szExpires[24]
	format_time(szCreated, charsmax(szCreated), "%d %b %H:%M", g_iCreated[id][index])
	if (g_iExpires[id][index] > 0)
		format_time(szExpires, charsmax(szExpires), "%d %b %H:%M", g_iExpires[id][index])
	else
		copy(szExpires, charsmax(szExpires), "never")

	// The title is a %s argument against a literal format, so a title can never
	// become a format string (tools/lint-plugins.py rule 4).
	client_print_color(id, print_team_default, "^4[WF]^1 ^3%s^1 (%s, sent %s, expires %s)",
		g_szTitle[id][index], g_szKindName[g_iKind[id][index]], szCreated, szExpires)

	new szAuth[40]
	get_user_authid(id, szAuth, charsmax(szAuth))

	if (!g_iReadAt[id][index])
	{
		g_iReadAt[id][index] = get_systime()
		MailSave(id)
		log_amx("[WF-MAIL] %s read src=%d id=%d at=%d", szAuth, g_iSrc[id][index], g_iId[id][index], g_iReadAt[id][index])
		WfSay(id, "Marked read. The full text is in the panel inbox (the envelope).")
	}
	else
	{
		WfSay(id, "Already read.")
	}
}

// --------------------------------------------------------------- commands ---
public cmdSend(id, level, cid)
{
	if (!cmd_access(id, level, cid, 4))
		return PLUGIN_HANDLED
	if (g_Vault == INVALID_HANDLE)
	{
		console_print(id, "[WF-MAIL] no vault: nothing can be stored")
		return PLUGIN_HANDLED
	}

	new szTarget[40], szKind[16], szTitle[128]
	read_argv(1, szTarget, charsmax(szTarget))
	read_argv(2, szKind, charsmax(szKind))
	read_argv(3, szTitle, charsmax(szTitle))
	// A title may contain spaces: take the rest of the command line (bounded).
	if (read_argc() > 4)
	{
		new szMore[128], szJoined[160]
		copy(szJoined, charsmax(szJoined), szTitle)
		for (new a = 4; a < read_argc() && a < 12; a++)
		{
			read_argv(a, szMore, charsmax(szMore))
			add(szJoined, charsmax(szJoined), " ")
			add(szJoined, charsmax(szJoined), szMore)
		}
		copy(szTitle, charsmax(szTitle), szJoined)
	}
	if (!szTitle[0])
	{
		console_print(id, "[WF-MAIL] usage: wf_mail_send <target|@all> <system|event|grant|admin> <title...>")
		return PLUGIN_HANDLED
	}

	new kind = MailKindFromName(szKind)
	if (kind < 0)
	{
		console_print(id, "[WF-MAIL] unknown kind '%s' - use system, event, grant or admin", szKind)
		return PLUGIN_HANDLED
	}

	new sent = 0, skipped = 0
	if (equal(szTarget, "@all") || equal(szTarget, "all"))
	{
		new players[MAX_PLAYERS], num
		get_players(players, num, "")
		for (new i = 0; i < num; i++)
		{
			// A broadcast is player-facing: humans only (rule 4).
			if (!MailValidPlayer(players[i], 1))
				continue
			if (MailDeliverGame(players[i], kind, szTitle))
				sent++
			else
				skipped++
		}
	}
	else
	{
		new target = FindTargetByAuth(szTarget)
		if (!target)
		{
			console_print(id, "[WF-MAIL] '%s' is not connected - in-game mail is delivered to a live player", szTarget)
			return PLUGIN_HANDLED
		}
		if (MailDeliverGame(target, kind, szTitle))
			sent++
		else
			skipped++
	}

	console_print(id, "[WF-MAIL] delivered to %d player(s), %d refused; unread copies are counted on their next /mail", sent, skipped)
	log_amx("[WF-MAIL] console send kind=%d sent=%d skipped=%d", kind, sent, skipped)
	return PLUGIN_HANDLED
}

/** A game-origin message: its id comes from this module's own counter. */
bool:MailDeliverGame(id, kind, const title[])
{
	if (!MailLoad(id))
		return false
	new next = MailNextId()
	if (next <= 0)
		return false
	if (MailAdd(id, MAIL_SRC_GAME, next, kind, get_systime(), 0, title) == WF_MAIL_INVALID)
		return false
	MailSave(id)
	return true
}

public cmdState(id, level, cid)
{
	if (!cmd_access(id, level, cid, 1))
		return PLUGIN_HANDLED

	new szTarget[40]
	read_argv(1, szTarget, charsmax(szTarget))

	new players[MAX_PLAYERS], num
	if (szTarget[0] && !equal(szTarget, "@all") && !equal(szTarget, "all"))
	{
		new target = FindTargetByAuth(szTarget)
		if (!target)
		{
			console_print(id, "[WF-MAIL] '%s' is not connected", szTarget)
			return PLUGIN_HANDLED
		}
		players[0] = target
		num = 1
	}
	else
	{
		get_players(players, num, "")
	}

	for (new i = 0; i < num; i++)
	{
		new p = players[i]
		if (!MailValidPlayer(p, 0) || !MailLoad(p))
			continue
		new szAuth[40], szCreated[24], szExpires[24]
		get_user_authid(p, szAuth, charsmax(szAuth))
		console_print(id, "[WF-MAIL] %s unread=%d cached=%d core_pending=%d reads=%d",
			szAuth, MailUnread(p), g_iCount[p],
			LibraryExists("winterfest_core", LibType_Library) ? wf_get_pending(p) : -1, MailReadCount(p))
		for (new e = 0; e < g_iCount[p]; e++)
		{
			format_time(szCreated, charsmax(szCreated), "%d %b %H:%M", g_iCreated[p][e])
			if (g_iExpires[p][e] > 0)
				format_time(szExpires, charsmax(szExpires), "%d %b %H:%M", g_iExpires[p][e])
			else
				copy(szExpires, charsmax(szExpires), "never")
			console_print(id, "[WF-MAIL]   %s %s%d kind=%s sent=%s expires=%s title=%s",
				g_iReadAt[p][e] ? "read" : "UNREAD",
				g_iSrc[p][e] == MAIL_SRC_PANEL ? "panel:" : "game:",
				g_iId[p][e], g_szKindName[g_iKind[p][e]], szCreated, szExpires, g_szTitle[p][e])
		}
	}
	return PLUGIN_HANDLED
}

public cmdClear(id, level, cid)
{
	if (!cmd_access(id, level, cid, 2))
		return PLUGIN_HANDLED

	new szTarget[40]
	read_argv(1, szTarget, charsmax(szTarget))

	new players[MAX_PLAYERS], num, cleared = 0
	if (equal(szTarget, "@all") || equal(szTarget, "all"))
	{
		get_players(players, num, "")
	}
	else
	{
		new target = FindTargetByAuth(szTarget)
		if (!target)
		{
			console_print(id, "[WF-MAIL] '%s' is not connected", szTarget)
			return PLUGIN_HANDLED
		}
		players[0] = target
		num = 1
	}

	for (new i = 0; i < num; i++)
	{
		new p = players[i]
		if (!MailValidPlayer(p, 0))
			continue
		g_iCount[p] = 0
		MailSave(p)
		cleared++
	}
	console_print(id, "[WF-MAIL] cleared %d cache(s); the panel copy is untouched", cleared)
	log_amx("[WF-MAIL] cache cleared for %d player(s) by admin command", cleared)
	return PLUGIN_HANDLED
}

/**
 * A lab command: two demo messages for one player, then the exact connect read
 * (same function, same log line) so a human can verify the loop with no panel.
 */
public cmdTest(id, level, cid)
{
	if (!cmd_access(id, level, cid, 1))
		return PLUGIN_HANDLED

	new szTarget[40]
	read_argv(1, szTarget, charsmax(szTarget))
	new target = 0
	if (szTarget[0])
		target = FindTargetByAuth(szTarget)
	// From the server console `id` is 0, so fall back to any connected client:
	// the lab command is most useful exactly there.
	if (!target && id >= 1 && id <= MaxClients)
		target = id
	if (!target)
		target = MailPickAnyPlayer()

	if (!MailValidPlayer(target, 0))
	{
		// Typed on the console right after a map change nobody may be connected
		// yet. Poll for a few seconds rather than answering "no player".
		g_iTestTries = 0
		set_task(1.0, "Task_TestRetry")
		console_print(id, "[WF-MAIL] no player connected yet - retrying for a few seconds")
		return PLUGIN_HANDLED
	}

	MailTestRun(target)
	return PLUGIN_HANDLED
}

public Task_TestRetry()
{
	new target = MailPickAnyPlayer()
	if (!target)
	{
		g_iTestTries++
		if (g_iTestTries < 15)
			set_task(1.0, "Task_TestRetry")
		else
			console_print(0, "[WF-MAIL] gave up: no connected player to test with")
		return
	}
	MailTestRun(target)
}

/** The lab run itself: two demo messages, then the exact connect read. */
MailTestRun(target)
{
	if (!MailValidPlayer(target, 0))
		return
	if (!MailDeliverGame(target, MAIL_KIND_SYSTEM, "Test: welcome to the inbox")
		|| !MailDeliverGame(target, MAIL_KIND_ADMIN, "Test: staff can write here"))
	{
		console_print(0, "[WF-MAIL] the demo messages could not be stored (no vault?)")
		return
	}
	Task_Welcome(target)
	console_print(0, "[WF-MAIL] two demo messages added; the connect read was re-run (see the log)")
}

// ---------------------------------------------------------------- natives ---
public native_unread(plugin, params)
{
	new id = get_param(1)
	if (id < 1 || id > MaxClients || !is_user_connected(id) || !MailLoad(id))
		return 0
	return MailUnread(id)
}

public native_count(plugin, params)
{
	new id = get_param(1)
	if (id < 1 || id > MaxClients || !is_user_connected(id) || !MailLoad(id))
		return 0
	return g_iCount[id]
}

/**
 * wfm_deliver(id, panel_id, kind, created, expires, title[])
 * The panel-bridge entry point: one `wf_mail` action -> one message. Idempotent
 * on (panel, panel_id), so a re-sent action cannot duplicate a message.
 * Returns WF_MAIL_ADDED / WF_MAIL_EXISTS / WF_MAIL_INVALID.
 */
public native_deliver(plugin, params)
{
	new id = get_param(1)
	new panelId = get_param(2)
	new kind = get_param(3)
	new created = get_param(4)
	new expires = get_param(5)
	new szTitle[128]
	get_string(6, szTitle, charsmax(szTitle))

	if (id < 1 || id > MaxClients || !is_user_connected(id) || !MailLoad(id))
		return WF_MAIL_INVALID
	if (created <= 0)
		created = get_systime()

	new result = MailAdd(id, MAIL_SRC_PANEL, panelId, kind, created, expires, szTitle)
	if (result == WF_MAIL_ADDED || result == WF_MAIL_EXISTS)
		MailSave(id)
	return result
}

/**
 * wfm_find(id, panel_id) -> the cache index of one panel message, or -1.
 * For a consumer that has to name a message (the lab probe, and any future
 * "open message N" action); the chat menu uses the same indices internally.
 */
public native_find(plugin, params)
{
	new id = get_param(1)
	new panelId = get_param(2)
	if (id < 1 || id > MaxClients || !is_user_connected(id) || !MailLoad(id))
		return -1
	return MailFind(id, MAIL_SRC_PANEL, panelId)
}

/**
 * wfm_reads(id, output[], len) -> "12@1790000000,15@1790000100"
 * The panel-origin messages this player has read, for the push payload's
 * `winter.mail_read`. Game-origin rows are not reported: the panel has no row
 * for them.
 */
public native_reads(plugin, params)
{
	new id = get_param(1)
	new len = get_param(3)
	new szOut[256], szOne[40]
	szOut[0] = 0

	if (id >= 1 && id <= MaxClients && is_user_connected(id) && MailLoad(id))
	{
		for (new i = 0; i < g_iCount[id]; i++)
		{
			if (g_iSrc[id][i] != MAIL_SRC_PANEL || !g_iReadAt[id][i])
				continue
			formatex(szOne, charsmax(szOne), "%s%d@%d", szOut[0] ? "," : "", g_iId[id][i], g_iReadAt[id][i])
			if (strlen(szOut) + strlen(szOne) >= charsmax(szOut))
				break
			add(szOut, charsmax(szOut), szOne)
		}
	}
	if (len > 0)
		set_string(2, szOut, len)
	return strlen(szOut)
}

// ----------------------------------------------------------------- utils ---
/** Real player; playerFacing also excludes bots (rule 4 of the workstream map). */
bool:MailValidPlayer(id, playerFacing)
{
	if (id < 1 || id > MaxClients || !is_user_connected(id))
		return false
	if (is_user_hltv(id))
		return false
	if (playerFacing && is_user_bot(id))
		return false
	return true
}

MailReadCount(id)
{
	new n = 0
	for (new i = 0; i < g_iCount[id]; i++)
		if (g_iReadAt[id][i])
			n++
	return n
}

/** kind name -> code, or -1 for an unknown one. */
MailKindFromName(const name[])
{
	if (equali(name, "system"))
		return MAIL_KIND_SYSTEM
	if (equali(name, "event"))
		return MAIL_KIND_EVENT
	if (equali(name, "grant") || equali(name, "reward"))
		return MAIL_KIND_GRANT
	if (equali(name, "admin") || equali(name, "staff"))
		return MAIL_KIND_ADMIN
	return -1
}

/** Any connected client (bots included: this is the lab path, not a player one). */
MailPickAnyPlayer()
{
	new players[MAX_PLAYERS], num
	// Empty flags on purpose: the letters ("c"/"h"/"d") mean different things in
	// different AMXX builds (wf_scenario.sma uses "d" for bots-only), so every
	// filter below is explicit.
	get_players(players, num, "")
	for (new i = 0; i < num; i++)
	{
		new p = players[i]
		if (p < 1 || p > MaxClients)
			continue
		if (is_user_hltv(p) || !is_user_connected(p))
			continue
		return p
	}
	return 0
}

/** A connected player by auth id. */
FindTargetByAuth(const szAuth[])
{
	if (!szAuth[0])
		return 0
	new players[MAX_PLAYERS], num
	get_players(players, num, "")
	for (new i = 0; i < num; i++)
	{
		new p = players[i]
		if (!MailValidPlayer(p, 0))
			continue
		new szUserAuth[40]
		get_user_authid(p, szUserAuth, charsmax(szUserAuth))
		if (equali(szUserAuth, szAuth))
			return p
	}
	return 0
}
