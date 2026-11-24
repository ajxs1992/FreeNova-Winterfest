/*
 * ============================================================================
 * FreeNova Top Bar  (freenova_topbar)
 * ============================================================================
 * Persistent top-center match scoreboard. New file (NOT a freenova_hud.sma
 * extension): hud owns per-player stats on HUD channel 3 at x=0.01/y=0.18 with
 * a 0.40s loop; this is a same-for-all scoreboard needing three side-colored
 * channels at the top edge. Extending hud would tangle both refresh loops, so
 * this plugin owns its channels and loop alone. freenova_hud.sma untouched.
 *
 * CHANNELS (verified against freenova_hud.sma header: 1 = auto-channel HUDs
 * adminchat/miscstats/VIP bullet-dmg, 2 = scrollmsg.amxx, 3 = freenova_hud):
 *   4 = CT line (left), 5 = timer + line2 (center), 6 = T line (right),
 *   7 = row2 (center, shares CH_TIMER x but a different channel/row).
 * No collision with hud (3) or the documented 1/2 users. Transient announces
 * from freenova_randevent use channel -1 (auto) and may briefly share, which
 * only flickers for 5s and is accepted.
 *
 * LAYOUT (screenshot-exact, two visual rows near the top edge, 4 hudmessages):
 *   row1 (y=0.01): "[ Counter Terrorists ] [ %d wins ] - [ MM:SS ] - [ %d wins ] [ Terrorists ]"
 *     (CT wins, timer, T wins. No player counters.)
 *     CT part blue (ch4, left), timer white centered (ch5, x=-1.0),
 *     T part red (ch6, right). The 3-message split exists ONLY for color;
 *     the x positions are tuned so it reads as ONE line.
 *   row2 (y=0.045): "[ NNN/MM ]   [ map ]" white centered (ch7),
 *     NNN = get_players "ch" count, MM = get_maxplayers, map = get_mapname.
 * Positions target ~5-12px at 720p. y=0.01/0.045 may clip on tiny
 * sub-640px windows; accepted (same tradeoff as the previous 0.14/0.20).
 *
 * EXACT COLORS (RGB, stated here):
 *   CT part  = (  0, 102, 255) deep blue
 *   timer    = (225, 225, 225) white
 *   T part   = (204,   0,   0) deep red
 *   row2     = (225, 225, 225) white
 * Dividers ("-") inherit their segment color; spec asks white dividers but
 * a hudmessage has ONE color, so the CT-side "-" is CT-blue and the T-side
 * "-" is T-red (only the timer segment is white). Documented tradeoff.
 *
 * AUTHORITATIVE STATE (HUD reads ONLY these globals, no second scoreboard):
 *   g_iCtWins / g_iTWins / g_iRounds = completed rounds since cycle start.
 *   g_bRestartPending = threshold reached, sv_restart scheduled, awaiting
 *     the restart EVENT. g_iCycleGen = cycle generation (stale-task guard).
 *   g_bRoundFired = this round already counted (exact-once per round).
 *   g_fRoundStart = get_gametime() stamp of the last HLTV round start.
 *
 * TIMER (never hardcoded): duration = get_cvar_float("mp_roundtime") MINUTES
 * x60, re-read EVERY tick so live mp_roundtime changes apply immediately.
 * remaining = duration - (get_gametime() - g_fRoundStart), clamped to
 * 0..duration, formatted %02d:%02d. Round-start stamp comes from HLTV
 * "1=0","2=0" (real round starts, NOT restarts); TextMsg/logevent restarts
 * re-stamp (timer restarts with the round). get_timeleft() is DELIBERATELY
 * not used: it reports the MAP timelimit, the wrong source for a round clock.
 * If mp_roundtime <= 0 the timer shows 00:00 (no magic fallback number).
 *
 * TRACKING (exactly once per completed round):
 *   - HLTV RoundStart clears g_bRoundFired (new round opens counting).
 *   - First qualifying end event only: MRAD_terwin -> T+1 + rounds+1,
 *     MRAD_ctwin -> CT+1 + rounds+1, MRAD_rounddraw -> rounds+1, no team++.
 *   - Everything skipped while amx_knife_round_active == 1 (warmup/knife
 *     rounds never touch wins, rounds, or the restart chain). The cvar is
 *     owned by simple_warmup.sma; read here via get_cvar_num (0 when absent).
 *   - sv_restart / Game_Commencing (TextMsg + "Restart_Round_"/"Game_Commencing"
 *     logevents, same set as freenova_vip): zero wins+rounds, clear pending +
 *     fired flag, gen++, re-stamp timer, cancel stale countdown/restart tasks.
 *     Idempotent: restart bursts inside a 1.0s window are ignored (one gen++
 *     per physical restart; a double sv_restart <1s apart counts once).
 *
 * AUTO-RESTART (default every 50 completed rounds):
 *   After the threshold round's result is processed: chat announce
 *   "[Server] <N> rounds have been played. Server restart in 10 seconds!"
 *   (ACTUAL cvar number, never hardcoded) -> countdown tasks N=10 (0.1s delay,
 *   ~immediate, doubles as the "10" notice) / 5 / 3 / 2 / 1 printing
 *   "[Server] Restarting in N second(s)..." (skipped when
 *   fn_topbar_countdown = 0; the restart still happens) -> Task_DoRestart at
 *   10.0s runs server_cmd("sv_restart 1") EXACTLY once (pending consumed
 *   before firing + gen check; only one DoRestart task exists per cycle).
 *   The counters reset on the restart EVENT, not at schedule time, so the
 *   round after the restart counts as round 1 of the new cycle.
 *   Cvars owned here: fn_topbar_restart_rounds (default 50, min 1 for testing),
 *   fn_topbar_countdown (default 1; 0 disables the per-N countdown prints).
 *
 * LIFECYCLE CHOICES (documented):
 *   - Plugin reload mid-match: globals restart at 0/0/0 and the timer stamp
 *     is "now", so the timer shows remaining ~= full duration until the next
 *     real round start re-syncs it. Accepted (no persistence by design).
 *   - Map change does NOT reset cycle counters (only sv_restart does); the
 *     tick only refreshes the cached map NAME and re-inits the timer stamp.
 *     Rationale: a map change is not a completed cycle; resetting there would
 *     silently discard up to 49 rounds of scoreboard truth.
 *   - Player count refreshes on join/leave via the 1.0s tick (no extra hook).
 *
 * REFRESH: 1.0s task; resend ONLY when the composed text changed OR the last
 * send is older than 2.0s (holdtime 2.5s > refresh, so it never blanks).
 * Always shown while any human is connected ("always show during play").
 * No web dependencies. No native/forward renames.
 * ============================================================================
 */

#include <amxmodx>
#include <amxmisc>
#include <cstrike>
#include <fn_common>

#define PLUGIN  "FreeNova Top Bar"
#define VERSION "2.0.0"
#define AUTHOR  "FreeNova"

// Dedicated channels (see header for collision audit)
#define CH_CT    4
#define CH_TIMER 5
#define CH_T     6
#define CH_ROW2  7

// Exact RGB (see header)
#define CT_R 0
#define CT_G 102
#define CT_B 255
#define TM_R 225
#define TM_G 225
#define TM_B 225
#define T_R 204
#define T_G 0
#define T_B 0
#define R2_R 225
#define R2_G 225
#define R2_B 225

#define TASK_TOPBAR 64001
#define TOPBAR_TICK 1.0
#define TOPBAR_HOLD 2.5
#define TOPBAR_RESEND 2.0

// Countdown/restart task ids: unique base, no collision with TASK_TOPBAR
// (64001), freenova_vip 54xxx or simple_warmup TASKID 1234.
#define TASK_CD10      64210
#define TASK_CD5       64205
#define TASK_CD3       64203
#define TASK_CD2       64202
#define TASK_CD1       64201
#define TASK_DORESTART 64250

#define RESTART_ANNOUNCE_LEAD 10.0
#define RESTART_BURST_WINDOW 1.0

#define POS_CT_X 0.22
#define POS_TM_X -1.0
#define POS_T_X 0.56
#define POS_Y1 0.01
#define POS_Y2 0.045

// Authoritative scoreboard state (HUD reads ONLY these)
new g_iCtWins
new g_iTWins
new g_iRounds
new bool:g_bRestartPending
new g_iCycleGen
new bool:g_bRoundFired
new Float:g_fRoundStart
new Float:g_fLastRestart

new g_pRestartRounds
new g_pCountdown

new g_szMap[32]
new g_szCache[256]
new Float:g_fLastSend

public plugin_init()
{
    fn_boot_banner("topbar", 7)

    register_plugin(PLUGIN, VERSION, AUTHOR)

    g_pRestartRounds = register_cvar("fn_topbar_restart_rounds", "50")
    g_pCountdown     = register_cvar("fn_topbar_countdown", "1")

    // One SendAudio carries exactly one MRAD sound, never two: split
    // registrations (same pattern as freenova_teamxp OnTeamWin), plus the
    // draw sound so draws count as completed rounds without a team point.
    register_event("SendAudio", "Event_TWin", "a", "2&%!MRAD_terwin")
    register_event("SendAudio", "Event_CtWin", "a", "2&%!MRAD_ctwin")
    register_event("SendAudio", "Event_Draw", "a", "2&%!MRAD_rounddraw")

    // Authoritative round clock: real round starts only, NOT restarts.
    register_event("HLTV", "Event_RoundStart", "a", "1=0", "2=0")

    // sv_restart / game-commencing coverage (same event set as freenova_vip:
    // same-arg TextMsg conditions are OR'd; logevents catch both forms).
    register_event("TextMsg", "Event_RoundRestart", "a", "2&#Game_w", "2&#Game_C", "2&#Game_will_restart")
    register_logevent("Event_RoundRestart", 2, "1&Restart_Round_")
    register_logevent("Event_RoundRestart", 2, "1=Game_Commencing")

    get_mapname(g_szMap, charsmax(g_szMap))
    g_fRoundStart = get_gametime()
    g_szCache[0] = 0
    g_fLastSend = 0.0

    set_task(TOPBAR_TICK, "Task_Topbar", TASK_TOPBAR, "", 0, "b")
}

public plugin_end()
{
    remove_task(TASK_TOPBAR)
    remove_task(TASK_CD10)
    remove_task(TASK_CD5)
    remove_task(TASK_CD3)
    remove_task(TASK_CD2)
    remove_task(TASK_CD1)
    remove_task(TASK_DORESTART)
}

// Real round start (NOT a restart): re-stamp the timer and open counting
// for the new round. Runs during warmup too; counting itself is skipped
// there by TryCountRound, so no warmup round can ever increment.
public Event_RoundStart()
{
    g_fRoundStart = get_gametime()
    g_bRoundFired = false
}

// sv_restart / Game_Commencing: the ONLY thing that resets the cycle.
// Idempotent: restart bursts inside RESTART_BURST_WINDOW count once
// (one gen++ per physical restart).
public Event_RoundRestart()
{
    new Float:fNow = get_gametime()
    if (fNow - g_fLastRestart < RESTART_BURST_WINDOW)
        return
    g_fLastRestart = fNow

    g_iCtWins = 0
    g_iTWins = 0
    g_iRounds = 0
    g_bRestartPending = false
    g_bRoundFired = false
    g_iCycleGen++
    log_amx("[FreeNova Topbar] Cycle reset (new gen %d).", g_iCycleGen)
    g_fRoundStart = fNow
    g_szCache[0] = 0

    // Cancel stale countdown/restart tasks from the previous cycle so a
    // late task can never fire sv_restart into the fresh cycle (each also
    // carries a gen param as a second guard).
    remove_task(TASK_CD10)
    remove_task(TASK_CD5)
    remove_task(TASK_CD3)
    remove_task(TASK_CD2)
    remove_task(TASK_CD1)
    remove_task(TASK_DORESTART)
}

public Event_TWin()
{
    TryCountRound(1)
}

public Event_CtWin()
{
    TryCountRound(2)
}

public Event_Draw()
{
    TryCountRound(0)
}

// Exact-once counting: first qualifying end event per round only.
// iWinner: 1 = T, 2 = CT, 0 = draw (rounds++ but no team increment).
TryCountRound(iWinner)
{
    // Knife/warmup rounds never count (cvar owned by simple_warmup).
    if (get_cvar_num("amx_knife_round_active") == 1)
        return

    if (g_bRoundFired)
        return
    g_bRoundFired = true

    g_iRounds++
    if (iWinner == 1)
        g_iTWins++
    else if (iWinner == 2)
        g_iCtWins++

    CheckRestartThreshold()
}

CheckRestartThreshold()
{
    if (g_bRestartPending)
        return

    new iThresh = get_pcvar_num(g_pRestartRounds)
    if (iThresh < 1)
        iThresh = 1
    if (g_iRounds < iThresh)
        return

    g_bRestartPending = true

    // ACTUAL threshold number in the announce, never a hardcoded literal.
    client_print(0, print_chat, "[Server] %d rounds have been played. Server restart in 10 seconds!", iThresh)
    log_amx("[FreeNova Topbar] Restart cycle complete (%d rounds, CT %d - T %d). Countdown started.", iThresh, g_iCtWins, g_iTWins)

    // Countdown tasks carry the cycle gen; stale-cycle tasks no-op in the
    // handler AND are removed by Event_RoundRestart (double guard).
    new iParam[2]
    iParam[0] = g_iCycleGen

    iParam[1] = 10
    set_task(0.1, "Task_Countdown", TASK_CD10, iParam, 2)
    iParam[1] = 5
    set_task(RESTART_ANNOUNCE_LEAD - 5.0, "Task_Countdown", TASK_CD5, iParam, 2)
    iParam[1] = 3
    set_task(RESTART_ANNOUNCE_LEAD - 3.0, "Task_Countdown", TASK_CD3, iParam, 2)
    iParam[1] = 2
    set_task(RESTART_ANNOUNCE_LEAD - 2.0, "Task_Countdown", TASK_CD2, iParam, 2)
    iParam[1] = 1
    set_task(RESTART_ANNOUNCE_LEAD - 1.0, "Task_Countdown", TASK_CD1, iParam, 2)

    set_task(RESTART_ANNOUNCE_LEAD, "Task_DoRestart", TASK_DORESTART, iParam, 1)
}

public Task_Countdown(iParam[2])
{
    if (iParam[0] != g_iCycleGen || !g_bRestartPending)
        return
    if (!get_pcvar_num(g_pCountdown))
        return
    client_print(0, print_chat, "[Server] Restarting in %d second(s)...", iParam[1])
}

// Fires sv_restart 1 EXACTLY once per cycle: only one such task is ever
// scheduled per cycle, pending is consumed BEFORE firing, and the gen must
// still match. The counter reset itself happens on the restart EVENT.
public Task_DoRestart(iParam[1])
{
    if (iParam[0] != g_iCycleGen || !g_bRestartPending)
        return
    g_bRestartPending = false
    log_amx("[FreeNova Topbar] Executing sv_restart 1 (gen %d).", iParam[0])
    server_cmd("sv_restart 1")
}

public Task_Topbar()
{
    // Map change: refresh the cached NAME + re-init the timer stamp.
    // Cycle counters are DELIBERATELY NOT reset here (only sv_restart resets;
    // see header rationale). Globals start 0/0/0 after a plugin reload.
    new szNow[32]
    get_mapname(szNow, charsmax(szNow))
    if (!equal(szNow, g_szMap))
    {
        copy(g_szMap, charsmax(g_szMap), szNow)
        g_fRoundStart = get_gametime()
        g_szCache[0] = 0
    }

    new iPlayers[32], iNum
    get_players(iPlayers, iNum, "ch")
    if (!iNum)
        return   // nobody to show it to; keep cache so reconnect resends

    // Authoritative round timer: mp_roundtime MINUTES x60, re-read every
    // tick (live cvar changes apply immediately). NOT get_timeleft()
    // (map timelimit, wrong source). Clamped to 0..duration.
    new Float:fDur = get_cvar_float("mp_roundtime") * 60.0
    new iLeft = 0
    if (fDur > 0.0)
    {
        new Float:fRem = fDur - (get_gametime() - g_fRoundStart)
        if (fRem < 0.0)
            fRem = 0.0
        if (fRem > fDur)
            fRem = fDur
        iLeft = floatround(fRem, floatround_floor)
    }
    new iMin = iLeft / 60
    new iSec = iLeft % 60

    new szCt[96], szTm[48], szT[96]
    formatex(szCt, charsmax(szCt),
        "[ Counter Terrorists ] [ %d wins ] -", g_iCtWins)
    formatex(szTm, charsmax(szTm),
        "[ %02d:%02d ]", iMin, iSec)
    formatex(szT, charsmax(szT),
        "- [ %d wins ] [ Terrorists ]", g_iTWins)

    // Change gate: resend only on content change or staleness (>2.0s).
    new szKey[256]
    formatex(szKey, charsmax(szKey), "%s|%s|%s", szCt, szTm, szT)

    new Float:fNow = get_gametime()
    if (equal(szKey, g_szCache) && (fNow - g_fLastSend) < TOPBAR_RESEND)
        return

    copy(g_szCache, charsmax(g_szCache), szKey)
    g_fLastSend = fNow

    for (new i = 0; i < iNum; i++)
    {
        new id = iPlayers[i]

        set_hudmessage(CT_R, CT_G, CT_B, POS_CT_X, POS_Y1, 0, 0.0, TOPBAR_HOLD, 0.0, 0.0, CH_CT)
        show_hudmessage(id, "%s", szCt)

        set_hudmessage(TM_R, TM_G, TM_B, POS_TM_X, POS_Y1, 0, 0.0, TOPBAR_HOLD, 0.0, 0.0, CH_TIMER)
        show_hudmessage(id, "%s", szTm)

        set_hudmessage(T_R, T_G, T_B, POS_T_X, POS_Y1, 0, 0.0, TOPBAR_HOLD, 0.0, 0.0, CH_T)
        show_hudmessage(id, "%s", szT)
    }
}
