#include <amxmodx>
#include <ranksultimate>
#include <fn_common>

// FreeNova Round-End Music + MVP Fanfare (single plugin, no extra event hooks)
//
// Trigger chain (mandated: consume RSU, do NOT add a 5th DeathMsg/SendAudio hook):
//   rsu_core (rsu_core.sma:663) fires fn_on_round_win(id, team) once per alive
//   human winner via its SendAudio MRAD_terwin/ctwin hook. This plugin
//   dedupes that per-round fan-out to ONE music trigger per round.
//
// MVP resolution consumes rsu_get_user_mvp() (rsu_core native) by delta:
//   snapshot lifetime MVP count at round start (HLTV "1=0") / at rsu_player_loaded,
//   then 0.3s after the round win (RSU increments g_iMVPs in its Round_End
//   logevent, which lands AFTER SendAudio) the player whose count grew is
//   this round's MVP. No DeathMsg, no own MVP scoring - RSU stays the single
//   MVP authority (rank HUD "MVP of the Round", competitive chat MVP, panel
//   STAT_MVP, battlepass Top1 all read the same counter).
//
// MVP fanfare is OFF by default (fnmvp_enabled 0) to avoid stacking a 5th
// MVP announce on top of: rsu_core rank HUD (MVP_HUD_ENABLE=1 in
// rank_system_ultimate.ini, pos -1.0,0.22), freenova_competitive chat
// "[FreeNova] %s is the round MVP (+25)", freenova_panel STAT_MVP (silent),
// battlepass "Top 1 MVP +15". To enable AFTER checking that HUD:
//   1. addons/amxmodx/configs/rank_system_ultimate.ini -> MVP_HUD_ENABLE = 0
//      if you want the fanfare HUD to be the single MVP surface (or leave it 1
//      and accept both; fanfare HUD uses channel 2 / y 0.35, rank HUD uses the
//      default channel / y 0.22 - they do not overwrite each other).
//   2. amxx.cfg (or console): fnmvp_enabled 1
//   3. optionally add a track under [mvp] in configs/freenova/music.ini
//      (empty section = HUD-only fanfare, no sound).
//
// Tracks: configs/freenova/music.ini (see that file for the format). Every
// listed path is precache_generic()'d in plugin_precache so clients download
// it, then played client-side via "mp3 play <path>". Missing files are
// skipped with a log line (repo + live tree run green without mp3s).
//
// Stops on HLTV new round ("mp3 stop", only if this plugin started music).
// Knife warmup needs no guard here: rsu_core filters amx_knife_round_active
// before firing fn_on_round_win.
//
// Cvar namespace: fnrm_* (round music) / fnmvp_* (MVP fanfare). Never fnc_*.

#define PLUGIN  "FreeNova Round Music"
#define VERSION "1.0"
#define AUTHOR  "FreeNova"

#define INI_FILE    "addons/amxmodx/configs/freenova/music.ini"
#define MAX_TRACKS  16
#define MAX_PATH    128
#define TASK_MVP    48100
#define MVP_DELAY   0.9

enum Section
{
    SEC_NONE = 0,
    SEC_T_WIN,
    SEC_CT_WIN,
    SEC_MVP
}

new g_szTracks[Section][MAX_TRACKS][MAX_PATH]
new g_iTrackCount[Section]

new g_pMusicEnabled
new g_pMvpEnabled

new bool:g_bWinHandled   // fn_on_round_win fires once per alive winner -> dedupe to one trigger
new bool:g_bMusicActive  // we started a track this round -> stop it on the next HLTV new round
new bool:g_bSeenNewRound // false until first HLTV new round after (late) load -> skip one fanfare
new g_iMvpSnap[MAX_PLAYERS + 1] // lifetime rsu_get_user_mvp() at round start / data load
new g_iLastTrack[Section] // shuffle without immediate repeat per section

public plugin_init()
{
    fn_boot_banner("roundmusic", 3)

    register_plugin(PLUGIN, VERSION, AUTHOR)

    // fnrm_*/fnmvp_* only - fnc_* is reserved elsewhere
    g_pMusicEnabled = register_cvar("fnrm_enabled", "1")
    // default OFF: four MVP announces already exist; see header for enable steps
    g_pMvpEnabled   = register_cvar("fnmvp_enabled", "0")

    // Single-condition HLTV hook: new round -> stop music, rearm, re-snapshot.
    // Never AND conditions here (freenova_panel:371 dead-bug precedent).
    register_event("HLTV", "Event_NewRound", "a", "1=0")
}

public plugin_precache()
{
    if (!file_exists(INI_FILE))
    {
        log_amx("[RoundMusic] %s not found - round music disabled (no tracks)", INI_FILE)
        return
    }

    new szLine[MAX_PATH], szSection[16], iSection = _:SEC_NONE, iLine, iLen
    while (read_file(INI_FILE, iLine++, szLine, charsmax(szLine), iLen))
    {
        trim(szLine)
        if (!szLine[0] || szLine[0] == ';')
            continue

        if (szLine[0] == '[')
        {
            copy(szSection, charsmax(szSection), szLine[1])
            new iEnd = contain(szSection, "]")
            if (iEnd != -1)
                szSection[iEnd] = 0

            if (equali(szSection, "t_win"))
                iSection = _:SEC_T_WIN
            else if (equali(szSection, "ct_win"))
                iSection = _:SEC_CT_WIN
            else if (equali(szSection, "mvp"))
                iSection = _:SEC_MVP
            else
                iSection = _:SEC_NONE
            continue
        }

        if (iSection == _:SEC_NONE)
            continue

        new Section:sec = Section:iSection
        if (g_iTrackCount[sec] >= MAX_TRACKS)
        {
            log_amx("[RoundMusic] section [%s] full, ignoring extra track ^"%s^"", szSection, szLine)
            continue
        }

        copy(g_szTracks[sec][g_iTrackCount[sec]], MAX_PATH - 1, szLine)
        g_iTrackCount[sec]++
    }

    PrecacheSection(SEC_T_WIN,  "t_win")
    PrecacheSection(SEC_CT_WIN, "ct_win")
    PrecacheSection(SEC_MVP,    "mvp")
}

stock PrecacheSection(Section:sec, const szName[])
{
    for (new i = 0; i < g_iTrackCount[sec]; i++)
    {
        // Green field: mp3s may not exist yet - never fail the map over music.
        // Paths with spaces break client_cmd mp3 play - reject with a log.
        if (contain(g_szTracks[sec][i], " ") != -1)
        {
            log_amx("[RoundMusic] [%s] path with spaces rejected (would break mp3 play): %s", szName, g_szTracks[sec][i])
            continue
        }
        if (file_exists(g_szTracks[sec][i]))
            precache_generic(g_szTracks[sec][i]) // generic = mp3 (precache_sound is wav-only)
        else
            log_amx("[RoundMusic] missing file in [%s]: %s (skipped)", szName, g_szTracks[sec][i])
    }
    log_amx("[RoundMusic] [%s]: %d track(s) listed", szName, g_iTrackCount[sec])
}

public client_putinserver(id)
{
    // Fresh slot: no MVP delta credit until RSU loads this player's data.
    g_iMvpSnap[id] = 0
}

public rsu_player_loaded(id, db_id)
{
    // Data load jumps the lifetime counter (0 -> lifetime). Re-snapshot here
    // so a mid-round joiner can never present that jump as a round MVP delta.
    g_iMvpSnap[id] = rsu_get_user_mvp(id)
}

public Event_NewRound()
{
    // Stop last round's music before freezetime runs out.
    if (g_bMusicActive)
    {
        client_cmd(0, "mp3 stop")
        g_bMusicActive = false
    }

    remove_task(TASK_MVP)
    g_bWinHandled = false
    g_bSeenNewRound = true

    // Snapshot MVP counters for the delta-based round-MVP resolution.
    for (new id = 1; id <= MaxClients; id++)
    {
        if (is_user_connected(id))
            g_iMvpSnap[id] = rsu_get_user_mvp(id)
    }
}

// Fired by rsu_core once per alive human winner (team: 1 = T, 2 = CT).
public fn_on_round_win(id, team)
{
    if (g_bWinHandled)
        return
    g_bWinHandled = true

    if (get_pcvar_num(g_pMusicEnabled))
        PlayTeamMusic(team)

    // Fanfare stays independent of the music switch; OFF unless fnmvp_enabled 1.
    // g_bSeenNewRound: without a round-start snapshot (plugin late-loaded
    // mid-round), every delta would be the lifetime total -> skip one round.
    if (get_pcvar_num(g_pMvpEnabled) && g_bSeenNewRound)
        set_task(MVP_DELAY, "Task_MvpFanfare", TASK_MVP)
}

PlayTeamMusic(team)
{
    new Section:sec = (team == 1) ? SEC_T_WIN : SEC_CT_WIN
    if (g_iTrackCount[sec] <= 0)
        return

    new szTrack[MAX_PATH]
    PickTrack(sec, szTrack, charsmax(szTrack))
    if (!szTrack[0] || !file_exists(szTrack))
        return

    client_cmd(0, "mp3 play %s", szTrack) // id 0 = all players, bots no-op
    g_bMusicActive = true
}

// Shuffle without immediate repeat when 2+ tracks exist.
PickTrack(Section:sec, szOut[], iLen)
{
    szOut[0] = 0
    new n = g_iTrackCount[sec]
    if (n <= 0)
        return
    new idx
    if (n == 1)
        idx = 0
    else
    {
        do { idx = random(n); } while (idx == g_iLastTrack[sec]);
    }
    g_iLastTrack[sec] = idx
    copy(szOut, iLen, g_szTracks[sec][idx])
}

// Delta = RSU's own MVP increment for this round. RSU bumps g_iMVPs in its
// Round_End logevent, which lands after the SendAudio win - hence the delay
// (0.9s: HLTV/logevent ordering + map-change safety margin). Draws fire no
// win forward so no music plays on draws by design.
public Task_MvpFanfare()
{
    new iBest, iBestDelta = 0
    for (new id = 1; id <= MaxClients; id++)
    {
        if (!is_user_connected(id))
            continue
        new iDelta = rsu_get_user_mvp(id) - g_iMvpSnap[id]
        if (iDelta > iBestDelta)
        {
            iBestDelta = iDelta
            iBest = id
        }
    }

    if (!iBest || is_user_bot(iBest))
        return

    new szName[32]
    get_user_name(iBest, szName, charsmax(szName))

    // Explicit channel 2, set immediately before show. Not channel 3
    // (freenova_hud rank HUD owns it), not the rank MVP pos -1.0,0.22.
    // Format is deliberately distinct from "MVP of the Round: %s ..." (rank)
    // and "...is the round MVP" (competitive chat) - no double-announce.
    set_hudmessage(255, 215, 0, -1.0, 0.35, 0, 0.0, 4.0, 0.0, 0.0, 2)
    show_hudmessage(0, "ROUND MVP FANFARE: %s", szName)
    client_print_color(0, print_team_default, "^4[FreeNova]^3 %s^1 takes the Round MVP fanfare!", szName)

    if (g_iTrackCount[SEC_MVP] > 0)
    {
        new szTrack[MAX_PATH]
        PickTrack(SEC_MVP, szTrack, charsmax(szTrack))
        if (szTrack[0] && file_exists(szTrack))
            client_cmd(iBest, "mp3 play %s", szTrack) // fanfare for the MVP only - winners keep their music
    }
}

public plugin_end()
{
    remove_task(TASK_MVP)
    if (g_bMusicActive)
        client_cmd(0, "mp3 stop")
}
