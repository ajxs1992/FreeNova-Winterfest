#include <amxmodx>
#include <amxmisc>
#include <cstrike>
#include <engine>
#include <fakemeta>
#include <fakemeta_util>
#include <freenova_web>
#include <healthnade>

// NOTE: the real fakemeta constant is "TR_iHitgroup" (lowercase g), index 9.
// An earlier version of this file guarded/defined "TR_iHitGroup" (capital G),
// which doesn't exist in fakemeta_const.inc, so the fallback below always
// kicked in and silently locked the value to 8 ???????? which is actually TR_pHit
// (the hit entity), not the hitgroup. That made every shot read as "not a
// headshot," including real headshots.
#if !defined TR_iHitgroup
    #define TR_iHitgroup 9
#endif

// Fallback: ensure HIT_HEAD is 1 (some AMX builds define it differently)
#if !defined HIT_HEAD
    #define HIT_HEAD 1
#endif
#include <fun>
#include <hamsandwich>
#include <crxranks>
#include <ranksultimate>
#include <crxranks_const>
#include <nvault>
#include <freenova_vip>
#include <freenova_ui>
#include <csx>
#include <freenova_panelstats>
#include <freenova_cosmetics>
#include <freenova_models>
#include <freenova_clutch>
#include <freenova_achievements>
#include <freenova_missions>
#include <reapi>

// 16KB default stack overflows on 24K-cell MOTD buffers (run time error 3). 256KB covers top15 + nesting.
#pragma dynamic 65536

native fn_hub_open(id)
native skins_open_menu(id)

#define PLUGIN  "FreeNova BattlePass"
#define VERSION "3.0"
#define AUTHOR  "FreeNova Dev"

#define MAX_PLAYERS 32
#define MAX_LEVELS  60
#define TASK_SPAWN    7000
#define TASK_LATELOAD 7100
#define TASK_SKILLSHOP 7200
#define TASK_HN_SMOKE  7300

// Level 60 Legend player models. Final product uses legend_t/legend_ct; if
// those files are absent (test servers), precache falls back to the vip models.
new const g_szLegendModelT[] = "models/player/legend_t/legend_t.mdl"
new const g_szLegendModelCT[] = "models/player/legend_ct/legend_ct.mdl"
new const g_szLegendFallbackT[] = "models/player/vip_tero/vip_tero.mdl"
new const g_szLegendFallbackCT[] = "models/player/vip_ct/vip_ct.mdl"

new g_szActiveLegendModelT[64]
new g_szActiveLegendModelCT[64]
new g_szLegendModelNameT[32]
new g_szLegendModelNameCT[32]


const XO_PLAYER = 5
const XO_WEAPON = 4

const m_offset_NextAttack          = 83
const m_offset_NextPrimaryAttack   = 46
const m_offset_NextSecondaryAttack = 47
const m_offset_TimeWeaponIdle      = 48

// ============================================================
// VIP TIERS - values now mirror freenova_vip.inc (FNVIP_*)
// ============================================================
enum _:VipTier
{
    VIP_NONE = 0,
    VIP_R,   // VIP
    VIP_Q,   // VIP+
    VIP_P    // VIP ELITE
}

// ============================================================
// PRESTIGE CONSTANTS
// ============================================================
#define MAX_PRESTIGE    10

new g_iPrestige[MAX_PLAYERS + 1]

// ============================================================
// COINS SYSTEM
// ============================================================
new g_iCoins[MAX_PLAYERS + 1]

// ============================================================
// MISSIONS / ACHIEVEMENTS STATE - NOT OWNED BY THIS PLUGIN
// ============================================================
// freenova_missions is the single authority (and the only writer) of the
// day/week-stamped daily# / weekly# / daily2# / roll# keys in the shared
// 'freenova_bp' vault; freenova_achievements owns the ach# key. The local
// MISSION_*/WEEKLY_*/DAILY2_* arrays this file used to keep were never fed
// by any forward (the kill/bomb/round-win hooks stopped counting when the
// split landed) and their persistence was already dead code, so they were
// removed rather than shadow the authority. Every mission/achievement
// export below (menabp_get_daily*, menabp_get_ach_*) delegates through the
// fnmsn_*/fnach_* natives. ACH_* macros come from <freenova_achievements>.
// ============================================================

// expansion skill runtime state
new bool:g_bHasNimble[MAX_PLAYERS + 1]
new Float:g_fFeatherFall[MAX_PLAYERS + 1]  // extra fall damage multiplier (0 = none)
new bool:g_bHasLastStand[MAX_PLAYERS + 1]
new g_iLastStandUntil[MAX_PLAYERS + 1]     // unix time until cooldown ends
new bool:g_bLastStandProc[MAX_PLAYERS + 1] // consumed this spawn

// highest milestone level already paid per player (prevents re-payment
// of the whole milestone table on every join/level-restore)
new g_iMilestonePaid[MAX_PLAYERS + 1]

// ============================================================
// BATTLEPASS XP / TIER LEDGER (REVIEW.md §2.4 H1)
// ============================================================
// Rank XP/level stay owned by CRX/RSU and are read that way everywhere else in
// this file (per-level HP/armor/damage tables, milestone cursor, legend gate).
// This ledger is the ONLY store of BattlePass XP and the ONLY source of BP
// tier: menabp_get_xp / menabp_get_tier / menabp_add_xp / menabp_add_xp_once
// read and write it and never call crxranks_give_user_xp - that call moves rank
// XP, which is the counter these comments always said was a different one.
//
// Persistence is the `bpxp` vault key (season-stamped through BpCursorKey, like
// every other BP cursor), so the ledger survives a map change, a restart and
// plugin_end. No migration and no seeding from rank XP: every player starts at
// BP XP 0 and earns from here on (product decision, REVIEW §9d).
new g_iBpXp[MAX_PLAYERS + 1]
new g_iBpTier[MAX_PLAYERS + 1]
new bool:g_bBpXpLoaded[MAX_PLAYERS + 1]
new g_iBpTierStart[MAX_PLAYERS + 1]
new g_iPremiumPaid[MAX_PLAYERS + 1]
new g_iPremiumLane[MAX_PLAYERS + 1] // 0 none, 1 VIP, 2 VIP+, 3 Elite
new g_iPassHp[MAX_PLAYERS + 1]
new g_iPassArmor[MAX_PLAYERS + 1]
new g_iPassJumps[MAX_PLAYERS + 1]
new g_iPassSniper[MAX_PLAYERS + 1]
new g_iPassLaststand[MAX_PLAYERS + 1]
new g_iPassChute[MAX_PLAYERS + 1]
new bool:g_bPassBoostLoaded[MAX_PLAYERS + 1]

// Per-season premium entitlement (2026-10-10): S1 premium was lifetime
// VIP-gated auto-grant (grandfathered). Seasons >1 require a store
// purchase recorded as bp_ent (lane + order id); cursors live in
// season-stamped vault keys so S1 history is never overwritten.
new g_iBpSeasonEnt[MAX_PLAYERS + 1]      // entitlement lane for current season (0 = none)
new g_szBpEntOrder[MAX_PLAYERS + 1][32] // store order id (audit trail)

stock const g_iBpFreeCoins[MAX_LEVELS + 1] =
{
    0,
    100, 0, 150, 0, 200, 0, 250, 0, 300, 0,
    350, 0, 400, 0, 450, 0, 500, 0, 550, 0,
    600, 0, 650, 0, 700, 0, 750, 0, 800, 0,
    850, 0, 900, 0, 950, 0, 1000, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 2000
}

// Premium column value before lane modifiers; zero means that tier grants a
// premium item/Prime bonus instead of coins.
stock const g_iBpPremiumCoins[MAX_LEVELS + 1] =
{
    0,
    150, 150, 225, 0, 300, 300, 375, 0, 450, 450,
    525, 0, 600, 600, 675, 0, 0, 750, 0, 0,
    0, 900, 975, 0, 0, 1050, 1125, 0, 1200, 1200,
    1275, 0, 0, 1350, 1425, 0, 0, 1500, 1575, 0,
    1650, 1650, 1725, 0, 0, 1800, 1875, 0, 0, 1950,
    2025, 0, 0, 2100, 0, 0, 0, 2250, 2325, 0
}

// ============================================================
// MOTD URL
// ============================================================
// (legacy external web-pass URL removed - local webpanel pages own /bp now)

// ============================================================
// STAT ARRAYS (CAPPED - sidegrades, not raw power)
// Jump/parachute/healthnade/revive/fast-sniper come from the shop
// only. Former per-level major-ability tables were unused at
// runtime (RebuildPlayerState never read them) and are deleted.
// ============================================================
new Float:g_fKnifeSpeedByLevel[MAX_LEVELS + 1]
new g_iHPByLevel[MAX_LEVELS + 1]
new g_iArmorByLevel[MAX_LEVELS + 1]
new Float:g_fDamageByLevel[MAX_LEVELS + 1]
new Float:g_fGravityByLevel[MAX_LEVELS + 1]
new Float:g_fReloadCapByLevel[MAX_LEVELS + 1]
new Float:g_fPlantSpeedByLevel[MAX_LEVELS + 1]
new Float:g_fDefuseSpeedByLevel[MAX_LEVELS + 1]
new Float:g_fSwitchSpeedByLevel[MAX_LEVELS + 1]
new Float:g_fFallDmgReduceByLevel[MAX_LEVELS + 1]

// ============================================================
// PER-PLAYER STATE
// ============================================================
new g_iHPBonus[MAX_PLAYERS + 1]
new g_iArmorBonus[MAX_PLAYERS + 1]
new Float:g_fKnifeSpeed[MAX_PLAYERS + 1]
new Float:g_fDamageMult[MAX_PLAYERS + 1]
new Float:g_fGravityMult[MAX_PLAYERS + 1]
new Float:g_fReloadCap[MAX_PLAYERS + 1]
new Float:g_fPlantSpeed[MAX_PLAYERS + 1]
new Float:g_fDefuseSpeed[MAX_PLAYERS + 1]
new Float:g_fSwitchSpeed[MAX_PLAYERS + 1]
new Float:g_fFallReduce[MAX_PLAYERS + 1]

new bool:g_bHasWeaponMenu[MAX_PLAYERS + 1]
new bool:g_bHasDoubleJump[MAX_PLAYERS + 1]
new bool:g_bHasParachute[MAX_PLAYERS + 1]
new bool:g_bHasHealthNade[MAX_PLAYERS + 1]
new bool:g_bHasRevive[MAX_PLAYERS + 1]
// True only while THIS plugin has flag "n" applied (see RebuildPlayerState).
// Revoke is allowed solely for flags we granted ourselves: "n" can also be a
// legit admin flag, and stripping an admin's own "n" broke revive (audit
// finding, see the flag block in RebuildPlayerState).
new bool:g_bReviveFlagGranted[MAX_PLAYERS + 1]
new bool:g_bHasFastSniper[MAX_PLAYERS + 1]
new bool:g_bHasWeaponMenuAwp[MAX_PLAYERS + 1]

new Float:g_fReviveTime[MAX_PLAYERS + 1]
new g_iMaxRevives[MAX_PLAYERS + 1]
new g_iMaxSpawns[MAX_PLAYERS + 1]
new Float:g_fHNThrow[MAX_PLAYERS + 1]
new Float:g_fHNDrink[MAX_PLAYERS + 1]
new g_iDoubleJumpCount[MAX_PLAYERS + 1]
new Float:g_fDoubleJumpPower[MAX_PLAYERS + 1]
new Float:g_fParachuteFall[MAX_PLAYERS + 1]
new Float:g_fFastSniperDelay[MAX_PLAYERS + 1]

new g_iJumpsUsed[MAX_PLAYERS + 1]
new bool:g_bDoJump[MAX_PLAYERS + 1]

// ============================================================
// COIN SHOP
// ============================================================
#define TASK_AUTOSAVE     7400

new Float:g_fXpBoost[MAX_PLAYERS + 1]
new g_iBoostEndTime[MAX_PLAYERS + 1]
new bool:g_bHasXpBoost[MAX_PLAYERS + 1]

new g_iShopPage[MAX_PLAYERS + 1]

// Data loaded flag - prevents auto-save from overwriting real data with defaults
new bool:g_bDataLoaded[MAX_PLAYERS + 1]
new bool:g_bGranting[MAX_PLAYERS + 1]
new bool:g_bBoughtHeal[MAX_PLAYERS + 1]

// Headshot Only event (toggled by panel via cvar)
new g_pCvarHSOnly
new g_pDebug          // bp_debug: the per-spawn armour conversion line and friends
new g_pCvarDoubleXP   // owned by freenova_panel
new g_pCvarHappyHour  // owned by freenova_progression
new g_pCvarEventXp    // owned by freenova_sync (fn_event_xp_mult)
new g_pCvarEventCoins // owned by freenova_sync (fn_event_coins_mult)
new g_pCvarFreezeTime // engine cvar (mp_freezetime)
new g_iLastHitGroup[MAX_PLAYERS + 1]
new g_iLastHitGroupAtk[MAX_PLAYERS + 1]
new Float:g_fLastHitGroupTime[MAX_PLAYERS + 1]

// Shop-purchased permanent multi-stage skills (bypass level requirement)
#define SKILL_MULTI_JUMP   0  // 1=Double, 2=Triple, 3=Quad
#define SKILL_SPAWN_HP     1  // 1=+2 HP, 2=+4 HP, 3=+6 HP
#define SKILL_SPAWN_ARMOR  2  // 1=+3 AP, 2=+6 AP, 3=+9 AP
#define SKILL_VAMPIRE      3  // 1=+1 HP, 2=+2 HP, 3=+3 HP per kill
#define SKILL_NIMBLE       4  // 1=+1% spd, 2=+2% spd, 3=+3% spd
#define SKILL_FEATHERFALL  5  // 1=15%, 2=30%, 3=45% fall-damage reduction
#define SKILL_HEALTHNADE   6  // 1=+15 HP, 2=+30 HP
#define SKILL_FAST_SNIPER  7  // 1=10% faster, 2=20% faster
#define SKILL_REVIVE       8  // 1=3.0s, 2=2.0s
#define SKILL_LASTSTAND    9  // 1=5 HP survive, 2=10 HP + 3s sprint
#define SKILL_PARACHUTE    10 // 1=Glide
#define SKILL_AWP_UNLOCK   11 // 1=Menu access
#define SKILL_CHAT_COLOR   12 // 1=Toxic Green & Dynamic Tea

// ---- Lane-exclusive unique skills (Tornado-style tier tracks) ----
// Every lane owns its ladder: 0 Regular, 1 VIP, 2 VIP+, 3 ELITE.
// Better lane = earlier unlocks. Cols: lane, unlock tier, skill, stage.
new const g_iLaneSkillUnlock[][4] = {
    {0, SKILL_MULTI_JUMP, 30, 1}, {0, SKILL_PARACHUTE, 45, 1},
    {0, SKILL_AWP_UNLOCK, 50, 1}, {0, SKILL_CHAT_COLOR, 55, 1},
    {1, SKILL_MULTI_JUMP, 20, 1}, {1, SKILL_PARACHUTE, 30, 1},
    {1, SKILL_AWP_UNLOCK, 40, 1}, {1, SKILL_CHAT_COLOR, 50, 1},
    {1, SKILL_MULTI_JUMP, 60, 2},
    {2, SKILL_MULTI_JUMP, 12, 2}, {2, SKILL_PARACHUTE, 15, 1},
    {2, SKILL_AWP_UNLOCK, 25, 1}, {2, SKILL_CHAT_COLOR, 35, 1},
    {2, SKILL_MULTI_JUMP, 50, 3},
    {3, SKILL_MULTI_JUMP, 5, 2}, {3, SKILL_PARACHUTE, 8, 1},
    {3, SKILL_AWP_UNLOCK, 12, 1}, {3, SKILL_CHAT_COLOR, 20, 1},
    {3, SKILL_MULTI_JUMP, 40, 3}
}
stock const g_szLaneNames[][8] = { "Regular", "VIP", "VIP+", "ELITE" }
#define SKILL_COUNT        13

new g_iShopSkillLevel[MAX_PLAYERS + 1][SKILL_COUNT]
new Float:g_fNimbleMult[MAX_PLAYERS + 1]
new bool:g_bAdrenalineRush[MAX_PLAYERS + 1]
#define TASK_ADRENALINE 44200

new const g_iSkillMaxStage[SKILL_COUNT] = {
    3, 3, 3, 3, 3, 3, 2, 2, 2, 2, 1, 1, 1
}

new const g_iSkillStageCosts[SKILL_COUNT][3] = {
    { 2500, 5000, 10000 }, // Multi-Jump
    { 2000, 4500, 8000 },  // Spawn HP
    { 1500, 3500, 6000 },  // Spawn Armor
    { 2500, 5000, 8500 },  // Vampire
    { 1500, 3500, 6500 },  // Nimble
    { 1000, 2500, 5000 },  // Featherfall
    { 2500, 5000, 0 },     // Healthnade
    { 2000, 4500, 0 },     // Fast Sniper
    { 3000, 6000, 0 },     // Revive
    { 3500, 7000, 0 },     // Last Stand
    { 1500, 0, 0 },        // Parachute
    { 2000, 0, 0 },        // AWP Unlock
    { 8000, 0, 0 }         // Chat Color License
}

new const g_szSkillNames[SKILL_COUNT][] = {
    "Multi-Jump",
    "Spawn HP Boost",
    "Spawn Armor Boost",
    "Vampire Lifesteal",
    "Nimble Agility",
    "Featherfall",
    "Healthnade",
    "Fast Sniper",
    "Combat Medic (Revive)",
    "Last Stand",
    "Tactical Parachute",
    "AWP Armory License",
    "Chat Color License"
}

// ============================================================
// NVAULT (persistent storage)
// ============================================================
new g_VaultBP = INVALID_HANDLE
new g_szDataDir[256]

// ============================================================
// RELOAD WEAPONS
// ============================================================
new const g_szReloadWeapons[][] =
{
    "weapon_p228",
    "weapon_scout",
    "weapon_xm1014",
    "weapon_mac10",
    "weapon_aug",
    "weapon_elite",
    "weapon_fiveseven",
    "weapon_ump45",
    "weapon_sg550",
    "weapon_galil",
    "weapon_famas",
    "weapon_usp",
    "weapon_glock18",
    "weapon_awp",
    "weapon_mp5navy",
    "weapon_m249",
    "weapon_m3",
    "weapon_m4a1",
    "weapon_tmp",
    "weapon_g3sg1",
    "weapon_deagle",
    "weapon_sg552",
    "weapon_ak47",
    "weapon_p90"
}

// ============================================================
// PLUGIN PRECACHE
// ============================================================
public plugin_precache()
{
    // Use legend_t/legend_ct when present; otherwise test-fallback to vip models.
    if(file_exists(g_szLegendModelT) && file_exists(g_szLegendModelCT))
    {
        copy(g_szActiveLegendModelT, charsmax(g_szActiveLegendModelT), g_szLegendModelT)
        copy(g_szActiveLegendModelCT, charsmax(g_szActiveLegendModelCT), g_szLegendModelCT)
        copy(g_szLegendModelNameT, charsmax(g_szLegendModelNameT), "legend_t")
        copy(g_szLegendModelNameCT, charsmax(g_szLegendModelNameCT), "legend_ct")
    }
    else
    {
        copy(g_szActiveLegendModelT, charsmax(g_szActiveLegendModelT), g_szLegendFallbackT)
        copy(g_szActiveLegendModelCT, charsmax(g_szActiveLegendModelCT), g_szLegendFallbackCT)
        copy(g_szLegendModelNameT, charsmax(g_szLegendModelNameT), "vip_tero")
        copy(g_szLegendModelNameCT, charsmax(g_szLegendModelNameCT), "vip_ct")
        log_amx("[FreeNova BP] legend_t/legend_ct models not found - falling back to vip_tero/vip_ct for testing")
    }

    precache_model(g_szActiveLegendModelT)
    precache_model(g_szActiveLegendModelCT)

    precache_sound("items/medshot4.wav")
    precache_sound("items/smallmedkit1.wav")
    precache_sound("player/pl_dirt1.wav")
    precache_sound("player/breathe1.wav")
}

// ============================================================
// PLUGIN INIT
// ============================================================
public plugin_init()
{
    register_plugin(PLUGIN, VERSION, AUTHOR)

    // BattlePass commands
    register_clcmd("say /bp", "Cmd_BattlePass")

    register_clcmd("say /topcoins", "Cmd_TopCoins")
    register_clcmd("say_team /topcoins", "Cmd_TopCoins")
    register_clcmd("say_team /bp", "Cmd_BattlePass")
    register_clcmd("say /battlepass", "Cmd_BattlePass")
    register_clcmd("say_team /battlepass", "Cmd_BattlePass")

    // Prestige command
    // Prestige system removed - coins earned via milestones and shop
    register_clcmd("say /coins", "Cmd_Coins")
    register_clcmd("say_team /coins", "Cmd_Coins")

    register_cvar("fn_bp_season", "1")
    register_cvar("fn_bp_season_name", "Season 1")
    register_cvar("fn_bp_season_end", "0")
    // Current battle pass season. S1 behavior is byte-identical legacy
    // (VIP auto-grant, un-stamped vault keys). Seasons >1 use stamped keys
    // plus a store entitlement (amx_bpent) - see BpPremiumAllowed.
    register_cvar("fn_bp_current_season", "1")
    // BattlePass XP per tier - the same flat curve the panel derives its tier
    // from (web-panel/src/bp_track.js xpPerTier over reward_track.xp_per_tier,
    // default 1000). Change both together or /bp and the panel disagree.
    register_cvar("fn_bp_xp_per_tier", "1000")

    // Shop commands
    register_clcmd("say /shop", "Cmd_Shop")
    register_clcmd("say_team /shop", "Cmd_Shop")
    register_clcmd("say /store", "Cmd_Shop")
    register_clcmd("say_team /store", "Cmd_Shop")

    // Admin coin commands (console + chat with menu)
    register_concmd("say /coins_give", "Cmd_CoinsGive")
    register_concmd("say_team /coins_give", "Cmd_CoinsGive")
    register_concmd("amx_coins_give", "Cmd_CoinsGive")
    register_concmd("say /coins_remove", "Cmd_CoinsRemove")
    register_concmd("say_team /coins_remove", "Cmd_CoinsRemove")
    register_concmd("amx_coins_remove", "Cmd_CoinsRemove")
    register_concmd("amx_coins_menu", "Cmd_CoinsMenu")
    // Season premium entitlement (store/RCON hook). Usage:
    // amx_bpent <steamid> <season> <lane 1-3> <order-id>
    register_concmd("amx_bpent", "Cmd_BpEntitlement")
    // Diagnostic: what would the spawn-armour rule do at bonus N? See Cmd_ArmorProbe.
    register_concmd("bp_armor_probe", "Cmd_ArmorProbe", ADMIN_CFG, "<player> <bonus> - run the spawn-armour rule for a bonus and print it")

    // Game events
    register_event("CurWeapon", "Event_CurWeapon", "be", "1=1")

    // Freezetime window tracking (guards maxspeed writes - see RefreshSpeed)
    register_event("HLTV", "Event_NewRound_HLTV", "a", "1=0", "2=0")
    register_logevent("Event_RoundStart_BP", 2, "1=Round_Start")

    // Round end for top3 coin rewards
    register_logevent("Event_RoundEnd", 2, "1=Round_End")

    // Round-win mission tracking (same SendAudio events CRX uses for team XP)

    // Ham hooks
    RegisterHam(Ham_Spawn, "player", "Ham_PlayerSpawn_Post", 1)
    RegisterHam(Ham_TakeDamage, "player", "Ham_TakeDamage_Pre")
    RegisterHam(Ham_TraceAttack, "player", "Ham_TraceAttack_Pre")
    RegisterHam(Ham_Item_Deploy, "weapon_awp", "Ham_SniperDeploy_Post", 1)
    RegisterHam(Ham_Item_Deploy, "weapon_scout", "Ham_SniperDeploy_Post", 1)
    RegisterHam(Ham_Weapon_PrimaryAttack, "weapon_awp", "Ham_SniperAttack_Post", 1)
    RegisterHam(Ham_Weapon_PrimaryAttack, "weapon_scout", "Ham_SniperAttack_Post", 1)
    // HealthNade is owned by the real reapi_healthnade plugin.

    for(new i = 0; i < sizeof(g_szReloadWeapons); i++)
    {
        RegisterHam(Ham_Weapon_Reload, g_szReloadWeapons[i], "Ham_WeaponReload_Post", 1)
    }

    g_pCvarHSOnly = register_cvar("fn_headshot_only", "0")
    g_pDebug = register_cvar("bp_debug", "0")

    // File backup is a last-resort fallback when nvault_lookup misses.
    // Vault is the source of truth; the .dat files are not a second writer
    // of shop/coins during autosave (SaveToFile is called from vault saves).
    get_datadir(g_szDataDir, charsmax(g_szDataDir))
    add(g_szDataDir, charsmax(g_szDataDir), "/freenova_bp")
    if(!dir_exists(g_szDataDir))
        mkdir(g_szDataDir)

    // Open nvault for persistent storage
    g_VaultBP = nvault_open("freenova_bp")
    if(g_VaultBP == INVALID_HANDLE)
    {
        log_amx("!g[FreeNova] !n ERROR: Failed to open nvault 'freenova_bp'! Coins/shop data will NOT persist.")
    }
    else
    {
        log_amx("!g[FreeNova] !n nvault 'freenova_bp' opened successfully (handle=%d)", g_VaultBP)
        WeeklyVaultPrune()
    }

    // Periodic auto-save every 30 seconds to prevent data loss on crash
    set_task(30.0, "Task_AutoSave", TASK_AUTOSAVE, "", 0, "b")

    InitDefaults()
}

public plugin_cfg()
{
    // Other plugins register these cvars; resolve them once after all
    // plugins have registered (plugin_cfg runs in load order).
    g_pCvarDoubleXP  = get_cvar_pointer("fn_double_xp")
    g_pCvarHappyHour = get_cvar_pointer("fn_happy_hour")
    g_pCvarEventXp   = get_cvar_pointer("fn_event_xp_mult")
    g_pCvarEventCoins = get_cvar_pointer("fn_event_coins_mult")
    g_pCvarFreezeTime = get_cvar_pointer("mp_freezetime")

    // Season cvars are forward-only: decrementing re-opens spent ledger keys
    // (bpclaim#) and re-uses consumed entitlement keys (bpent_s<N>). Loud log.
    if (get_cvar_num("fn_bp_current_season") < get_cvar_num("fn_bp_season"))
        log_amx("[FreeNova] REFUSING season rewind: fn_bp_current_season (%d) < fn_bp_season (%d). Seasons only move forward.",
            get_cvar_num("fn_bp_current_season"), get_cvar_num("fn_bp_season"))
}

public Task_AutoSave(taskid)
{
    new players[32], num
    get_players(players, num, "ch")
    for(new i = 0; i < num; i++)
    {
        // Skip players whose data hasn't finished loading yet
        if(!g_bDataLoaded[players[i]])
            continue

        SaveCoins(players[i])
        SaveShopData(players[i])
        SavePrestige(players[i])
        SaveMilestonePaid(players[i])
        SaveBpXp(players[i])
        SavePremiumPaid(players[i])
        SavePremiumLane(players[i])
        SaveBpBoost(players[i])
        SaveXpBoost(players[i])
    }
}

public plugin_end()
{
    for(new id = 1; id <= MAX_PLAYERS; id++)
    {
        remove_task(id + TASK_LATELOAD)
        remove_task(id + TASK_SKILLSHOP)
    }

    // Save ONLY players whose vault row finished loading. Saving a still-loading
    // slot writes coins=0 / empty shop over the real row (map change / crash).
    if(g_VaultBP != INVALID_HANDLE)
    {
        new players[32], num, iSaved
        get_players(players, num, "ch")
        for(new i = 0; i < num; i++)
        {
            if(!g_bDataLoaded[players[i]])
                continue
            SavePrestige(players[i])
            SaveCoins(players[i])
            SaveShopData(players[i])
            SaveMilestonePaid(players[i])
            SaveBpXp(players[i])
            SavePremiumPaid(players[i])
            SavePremiumLane(players[i])
            SaveBpBoost(players[i])
            SaveXpBoost(players[i])
            iSaved++
        }
        log_amx("!g[FreeNova] !n plugin_end: saved %d/%d connected players before vault close", iSaved, num)
        nvault_close(g_VaultBP)
        log_amx("!g[FreeNova] !n Vault closed successfully")
    }
    else
    {
        log_amx("!g[FreeNova] !n WARNING: Vault was invalid on plugin_end - data may be lost!")
    }
}

public client_putinserver(id)
{
    // Mark data as NOT loaded - prevents auto-save from overwriting real data
    g_bDataLoaded[id] = false

    // Bots share one BOT authid - never load/store BattlePass data for them
    if(is_user_bot(id))
        return

    ResetPlayer(id)
    arrayset(g_iShopSkillLevel[id], 0, SKILL_COUNT)

    // Authid may still be STEAM_ID_PENDING at putinserver on slow-auth servers.
    // Loading vault data under a pending key silently orphans all per-day mission
    // progress (the "daily missions are session-only" root cause). Validate the
    // authid first; if pending, defer loading via the same late-resolve task used
    // by freenova_vip and freenova_panel.
    new szAuth[40]
    get_user_authid(id, szAuth, charsmax(szAuth))
    if(!szAuth[0] || equal(szAuth, "STEAM_ID_PENDING") || equal(szAuth, "UNKNOWN"))
    {
        // Schedule deferred load; the task validates auth before proceeding.
        // Own task id - must not share TASK_SPAWN (Ham_PlayerSpawn_Post cancels that).
        set_task(5.0, "Task_LateLoadBP", id + TASK_LATELOAD)
        return
    }

    BP_DoLoad(id)
}

// Deferred BattlePass load - fires once after 5s when auth was pending at putinserver.
public Task_LateLoadBP(taskid)
{
    new id = taskid - TASK_LATELOAD
    if(!is_user_connected(id) || is_user_bot(id))
        return

    new szAuth[40]
    get_user_authid(id, szAuth, charsmax(szAuth))
    if(!szAuth[0] || equal(szAuth, "STEAM_ID_PENDING") || equal(szAuth, "UNKNOWN"))
    {
        // Still pending - try once more in 3s (handles very slow auth servers).
        set_task(3.0, "Task_LateLoadBP", id + TASK_LATELOAD)
        return
    }

    BP_DoLoad(id)
}

// ---- Per-reward claim ledger: bpclaim#season#auth#tier#track#label ----
// Keys are the idempotency record. Auto-grant pipelines mark on grant;
// migration backfills history once. Eligibility is always evaluated live.
BpSafeAuth(id, szOut[], iLen)
{
    get_user_authid(id, szOut, iLen)
    for (new i = 0; szOut[i]; i++)
        if (szOut[i] == ':') szOut[i] = '_'
}
new const g_szBpSkillShort[][8] = { "Jump", "HP", "Armor", "Vamp", "Agile", "Feather", "Nade", "Sniper", "Medic", "LastStd", "Chute", "AWP", "Color" }
BpClaimLabel(iTier, iTrack, iLane, szOut[], iLen)
{
    szOut[0] = 0
    if (iTier < 1 || iTier > MAX_LEVELS) return 0
    if (iTrack == 0)
    {
        new iCoins = g_iBpFreeCoins[iTier]
        if (iCoins <= 0) return 0
        formatex(szOut, iLen, "%dc", iCoins)
        return 1
    }
    for (new r = 0; r < sizeof(g_iLaneSkillUnlock); r++)
    {
        if (g_iLaneSkillUnlock[r][0] == iLane && g_iLaneSkillUnlock[r][2] == iTier)
        {
            new iSk = g_iLaneSkillUnlock[r][1]
            if (iSk >= 0 && iSk < sizeof(g_szBpSkillShort))
                copy(szOut, iLen, g_szBpSkillShort[iSk])
            else
                copy(szOut, iLen, "Skill")
            return 1
        }
    }
    new iExtra = BpPremiumExtraCoinsLane(iTier, iLane)
    if (iExtra > 0)
    {
        formatex(szOut, iLen, "+%dc", iExtra)
        return 1
    }
    return 0
}
BpClaimKey(id, iTier, iTrack, iLane, szKey[], iKeyLen)
{
    new szAuth[40], szLabel[24]
    BpSafeAuth(id, szAuth, charsmax(szAuth))
    if (!BpClaimLabel(iTier, iTrack, iLane, szLabel, charsmax(szLabel)))
    {
        szKey[0] = 0
        return 0
    }
    formatex(szKey, iKeyLen, "bpclaim#%d#%s#%d#%d#%s", get_cvar_num("fn_bp_season"), szAuth, iTier, iTrack, szLabel)
    return 1
}
bool:BpIsClaimed(id, iTier, iTrack, iLane)
{
    new szKey[128], szVal[8]
    if (!BpClaimKey(id, iTier, iTrack, iLane, szKey, charsmax(szKey)))
        return false
    if (g_VaultBP == INVALID_HANDLE)
        return false
    return nvault_get(g_VaultBP, szKey, szVal, charsmax(szVal)) ? true : false
}
BpMarkClaimed(id, iTier, iTrack, iLane)
{
    new szKey[128]
    if (!BpClaimKey(id, iTier, iTrack, iLane, szKey, charsmax(szKey)))
        return
    if (g_VaultBP == INVALID_HANDLE)
        return
    nvault_set(g_VaultBP, szKey, "1")
}
BpMigrateClaims(id)
{
    if (g_VaultBP == INVALID_HANDLE)
        return
    new szAuth[40], szFlag[96], szVal[8]
    BpSafeAuth(id, szAuth, charsmax(szAuth))
    formatex(szFlag, charsmax(szFlag), "bpmig#%d#%s", get_cvar_num("fn_bp_season"), szAuth)
    if (nvault_get(g_VaultBP, szFlag, szVal, charsmax(szVal)))
        return
    new iLane = g_iPremiumLane[id]
    if (iLane < 0 || iLane > 3) iLane = 0
    new iMax = min(g_iMilestonePaid[id], MAX_LEVELS)
    for (new t = 1; t <= iMax; t++)
        BpMarkClaimed(id, t, 0, 0)
    new iPMax = min(g_iPremiumPaid[id], MAX_LEVELS)
    for (new t2 = 1; t2 <= iPMax; t2++)
        BpMarkClaimed(id, t2, 1, iLane)
    nvault_set(g_VaultBP, szFlag, "1")
}
// Returns 1 claimed-now, 0 already, -1 locked, -2 premium-required, -3 bad.
TryClaimReward(id, iTier, iTrack)
{
    if (!is_user_connected(id) || is_user_bot(id)) return -3
    if (iTier < 1 || iTier > MAX_LEVELS || (iTrack != 0 && iTrack != 1)) return -3
    new iLane = g_iPremiumLane[id]
    if (iLane < 0 || iLane > 3) iLane = 0
    new iPaid = (iTrack == 1) ? g_iPremiumPaid[id] : g_iMilestonePaid[id]
    if (iTier > iPaid) return -1
    if (iTrack == 1 && BpDesiredLane(id) < 1) return -2
    if (BpIsClaimed(id, iTier, iTrack, iLane)) return 0
    if (iTrack == 0)
        CheckMilestoneReward(id, iTier)
    else
        BpGrantPremium(id, iTier)
    BpMarkClaimed(id, iTier, iTrack, iLane)
    return 1
}

BP_DoLoad(id)
{
    LoadShopData(id)
    LoadPrestige(id)
    LoadCoins(id)
    LoadMilestonePaid(id)
    LoadBpXp(id)
    LoadPremiumPaid(id)
    LoadPremiumLane(id)
    LoadBpBoost(id)
    LoadXpBoost(id)
    LoadBpEntitlement(id)

    // S1: legacy VIP auto-grant. S2+: store entitlement only (re-buy each season).
    if(BpPremiumAllowed(id))
    {
        // Align the working lane with the entitlement before any backfill,
        // so S2+ backfill/catchup can never mint from the VIP tier.
        if(BpCurrentSeason() > 1 && g_iPremiumLane[id] < g_iBpSeasonEnt[id])
            g_iPremiumLane[id] = g_iBpSeasonEnt[id]
        if(!g_bPassBoostLoaded[id])
        {
            if(g_iPremiumLane[id] < 1)
                g_iPremiumLane[id] = 1
            BpBackfillPremium(id, g_iMilestonePaid[id])
            g_iPremiumPaid[id] = g_iMilestonePaid[id]
            SavePremiumPaid(id)
            SavePremiumLane(id)
            SaveBpBoost(id)
        }
        else if(g_iPremiumPaid[id] == 0 && g_iMilestonePaid[id] > 0)
        {
            if(g_iPremiumLane[id] < 1)
                g_iPremiumLane[id] = 1
            BpCatchUpPremium(id, g_iMilestonePaid[id])
            g_iPremiumPaid[id] = g_iMilestonePaid[id]
            SavePremiumPaid(id)
            SavePremiumLane(id)
            SaveBpBoost(id)
        }
        else if(g_iPremiumLane[id] < 1 && g_iPremiumPaid[id] > 0)
        {
            g_iPremiumLane[id] = 1
            SavePremiumLane(id)
        }
        new desired = BpDesiredLane(id)
        if(desired > g_iPremiumLane[id])
            BpUpgradePremiumLane(id, g_iPremiumLane[id], desired)
    }

    // Mark data as loaded - auto-save can now safely run
    g_bDataLoaded[id] = true

    if(get_cvar_num("fn_bp_season") == 1 && BpTryCosmetic(id, "weapon_models", "model_s1_catchup"))
    {
        if(g_iMilestonePaid[id] >= 53)
        {
            fn_models_unlock(id, "s1_op_ct")
            fn_models_unlock(id, "s1_op_t")
            fn_skins_unlock_model(id, 0, "models/fn_s1/v_ak47_asiimov.mdl")
        }
        BpGrantLaneExclusives(id, g_iPremiumLane[id])
    }

    BpMigrateClaims(id)
    // Build state immediately so healthnade etc. are available on first spawn
    RebuildPlayerState(id, false)
}

public client_disconnected(id)
{
    remove_task(id + TASK_SPAWN)
    remove_task(id + TASK_LATELOAD)
    remove_task(id + TASK_SKILLSHOP)
    remove_task(id + TASK_HN_SMOKE)

    // Bots never held data (see client_putinserver)
    if(is_user_bot(id))
        return

    if(g_bDataLoaded[id])
    {
        SavePrestige(id)
        SaveCoins(id)
        SaveShopData(id)
        SaveMilestonePaid(id)
        SaveBpXp(id)
        SavePremiumPaid(id)
        SavePremiumLane(id)
        SaveBpBoost(id)
        SaveXpBoost(id)
    }

    g_bDataLoaded[id] = false
    ResetPlayer(id)
}

// ============================================================
// RESET PLAYER STATE
// ============================================================
// Spawn/rebuild only clears derived combat flags. Persistable boost,
// daily2 progress/paid, and achievement bitfield+counters survive
// RebuildPlayerState (level-up / spawn) and are wiped only on join/leave.
ResetCombatState(id)
{
    g_iHPBonus[id] = 0
    g_iArmorBonus[id] = 0
    g_fKnifeSpeed[id] = 250.0
    g_fDamageMult[id] = 1.0
    g_fGravityMult[id] = 1.0
    g_fReloadCap[id] = 2.5
    g_fPlantSpeed[id] = 1.0
    g_fDefuseSpeed[id] = 1.0
    g_fSwitchSpeed[id] = 1.0
    g_fFallReduce[id] = 0.0
    g_fNimbleMult[id] = 1.0

    g_bHasWeaponMenu[id] = false
    g_bHasDoubleJump[id] = false
    g_bHasParachute[id] = false
    g_bHasHealthNade[id] = false
    g_bHasRevive[id] = false
    // Explicit revoke of the revive flag "n" (was grant-only, so a lost
    // Combat Medic skill kept the flag until disconnect). Only strip the
    // flag WE granted: an admin's own "n" must survive (audit finding).
    if(g_bReviveFlagGranted[id])
    {
        new iFlags = get_user_flags(id)
        set_user_flags(id, iFlags & ~read_flags("n"))
        g_bReviveFlagGranted[id] = false
    }
    g_bHasFastSniper[id] = false
    g_bHasWeaponMenuAwp[id] = false

    g_fReviveTime[id] = 3.0
    g_iMaxRevives[id] = 0
    g_iMaxSpawns[id] = 0
    g_fHNThrow[id] = 20.0
    g_fHNDrink[id] = 35.0
    g_iDoubleJumpCount[id] = 0
    g_fDoubleJumpPower[id] = 270.0
    g_fParachuteFall[id] = -100.0
    g_fFastSniperDelay[id] = 0.75

    g_iJumpsUsed[id] = 0
    g_bDoJump[id] = false

    g_bHasNimble[id] = false
    g_fFeatherFall[id] = 0.0
    g_bHasLastStand[id] = false
    g_bLastStandProc[id] = false
    g_bAdrenalineRush[id] = false
    remove_task(id + TASK_ADRENALINE)

    g_iLastHitGroup[id] = 0
    g_iLastHitGroupAtk[id] = 0
    g_fLastHitGroupTime[id] = 0.0
}

ResetPlayer(id)
{
    ResetCombatState(id)

    g_iCoins[id] = 0
    g_iBpXp[id] = 0
    g_iBpTier[id] = 1
    g_bBpXpLoaded[id] = false
    arrayset(g_iShopSkillLevel[id], 0, SKILL_COUNT)
    g_bBoughtHeal[id] = false

    g_fXpBoost[id] = 1.0
    g_iBoostEndTime[id] = 0
    g_bHasXpBoost[id] = false
    g_iShopPage[id] = 0
    g_iLastStandUntil[id] = 0

    // Daily/weekly mission + achievement state is owned by
    // freenova_missions / freenova_achievements - nothing to reset here.

    g_iPremiumPaid[id] = 0
    g_iPremiumLane[id] = 0
    g_iPassHp[id] = 0
    g_iPassArmor[id] = 0
    g_iPassJumps[id] = 0
    g_iPassSniper[id] = 0
    g_iPassLaststand[id] = 0
    g_iPassChute[id] = 0
    g_bPassBoostLoaded[id] = false
    g_bGranting[id] = false
}

// ============================================================
// CRXRANKS CALLBACKS
// ============================================================
public crxranks_user_level_updated(id, level, bool:levelup)
{
    if(!is_user_connected(id))
    {
        return
    }

    // Nested XP from CheckMilestoneReward can re-enter this forward.
    // Cursor is advanced before grants; extra ranks are paid in the loop below.
    if(g_bGranting[id])
        return

    RebuildPlayerState(id, true)

    // Award coins on milestone levels, but only for levels above the
    // highest level already paid. CRX fires this forward with
    // levelup=true on every join (storage restore 0 -> saved level),
    // so without this guard the whole table is re-paid per reconnect.
    if(levelup && !is_user_bot(id))
    {
        g_bGranting[id] = true
        new iSafety
        while(iSafety++ < MAX_LEVELS)
        {
            new iNow = crxranks_get_user_level(id)
            if(iNow > MAX_LEVELS) iNow = MAX_LEVELS
            if(iNow <= g_iMilestonePaid[id])
                break
            new iFrom = g_iMilestonePaid[id] + 1
            g_iMilestonePaid[id] = iNow
            SaveMilestonePaid(id)
            for(new iLvl = iFrom; iLvl <= iNow; iLvl++)
                CheckMilestoneReward(id, iLvl)
        }
        g_bGranting[id] = false
        // S1: legacy VIP auto-grant. S2+: store entitlement only.
        if(g_bDataLoaded[id] && BpPremiumAllowed(id))
        {
            if(BpCurrentSeason() > 1 && g_iPremiumLane[id] < g_iBpSeasonEnt[id])
                g_iPremiumLane[id] = g_iBpSeasonEnt[id]
            new desired = BpDesiredLane(id)
            if(g_iPremiumLane[id] < 1)
            {
                g_iPremiumLane[id] = (desired > 0) ? desired : 1
                SavePremiumLane(id)
            }
            else if(desired > g_iPremiumLane[id])
                BpUpgradePremiumLane(id, g_iPremiumLane[id], desired)
            if(g_iPremiumPaid[id] == 0 && g_iMilestonePaid[id] > 0)
            {
                BpCatchUpPremium(id, g_iMilestonePaid[id])
                g_iPremiumPaid[id] = g_iMilestonePaid[id]
                SavePremiumPaid(id)
                SaveBpBoost(id)
            }
            new iPayTo = g_iMilestonePaid[id]
            if(iPayTo > MAX_LEVELS) iPayTo = MAX_LEVELS
            if(iPayTo > g_iPremiumPaid[id])
            {
                for(new t = g_iPremiumPaid[id] + 1; t <= iPayTo; t++)
                    BpGrantPremium(id, t)
                g_iPremiumPaid[id] = iPayTo
                SavePremiumPaid(id)
                SaveBpBoost(id)
            }
        }
    }
}

public fnvip_tier_changed(id, oldTier, newTier)
{
    if(!is_user_connected(id) || is_user_bot(id) || !g_bDataLoaded[id])
        return
    new desired = BpDesiredLane(id)
    if(desired < 1)
    {
        // VIP expired/revoked (S1) or no season entitlement (S2+):
        // downgrade to the free lane and strip pass boosts (they were
        // only ever upgraded, never revoked).
        if(g_iPremiumLane[id] > 0 && (BpCurrentSeason() <= 1 || g_iBpSeasonEnt[id] < 1))
        {
            g_iPremiumLane[id] = 0
            g_iPassHp[id] = 0
            g_iPassArmor[id] = 0
            g_iPassJumps[id] = 0
            g_iPassSniper[id] = 0
            g_iPassLaststand[id] = 0
            g_iPassChute[id] = 0
            SavePremiumLane(id)
            SaveBpBoost(id)
            RebuildPlayerState(id, true)
        }
        return
    }
    if(g_iPremiumLane[id] < 1)
    {
        g_iPremiumLane[id] = 1
        if(g_iPremiumPaid[id] == 0 && g_iMilestonePaid[id] > 0)
        {
            BpCatchUpPremium(id, g_iMilestonePaid[id])
            g_iPremiumPaid[id] = g_iMilestonePaid[id]
            SavePremiumPaid(id)
            SaveBpBoost(id)
        }
        SavePremiumLane(id)
        RebuildPlayerState(id, true)
    }
    if(desired > g_iPremiumLane[id])
    {
        BpUpgradePremiumLane(id, g_iPremiumLane[id], desired)
        RebuildPlayerState(id, true)
    }
}

public crxranks_user_receive_xp(id, xp, CRXRanks_XPSources:source)
{
    #pragma unused source

    if(!is_user_connected(id) || xp <= 0)
    {
        return CRXRANKS_CONTINUE
    }

    new Float:fMultiplier = 1.0

    // XP Boost from shop
    if(g_bHasXpBoost[id])
    {
        if(g_iBoostEndTime[id] > 0 && get_systime() >= g_iBoostEndTime[id])
        {
            g_bHasXpBoost[id] = false
            g_fXpBoost[id] = 1.0
        }
        else
        {
            fMultiplier *= g_fXpBoost[id]
        }
    }

    // Server-wide XP category is MAX, not product: Happy Hour * Double XP * event
    // used to explode (2x * 2x * 2x). Shop boost and VIP stay multiplicative.
    new Float:fProgression = 1.0
    if(g_pCvarHappyHour)
    {
        new Float:fHH = get_pcvar_float(g_pCvarHappyHour)
        if(fHH > fProgression)
            fProgression = fHH
    }
    if(g_pCvarEventXp)
    {
        new Float:fEv = get_pcvar_float(g_pCvarEventXp)
        if(fEv > fProgression)
            fProgression = fEv
    }
    if(g_pCvarDoubleXP && get_pcvar_num(g_pCvarDoubleXP) && fProgression < 2.0)
        fProgression = 2.0
    if(fProgression > 1.0)
        fMultiplier *= fProgression

    // VIP XP bonus - resolved by the unified FreeNova VIP core
    // (replaces the old r/q/p flag tiers; multipliers come from
    // configs/freenova/vip.cfg via fnvip)
    fMultiplier *= fnvip_get_xp_multiplier(id)

    new iNewXp = floatround(float(xp) * fMultiplier)

    return iNewXp
}

// ============================================================
// VIP SYSTEM
// ============================================================
// Tier authority moved to freenova_vip.sma. These wrappers keep the
// local naming/enum stable for existing call sites.
GetVipTier(id)
{
    return fnvip_get_tier(id)
}

// ============================================================
// SPAWN / STATE
// ============================================================
public Ham_PlayerSpawn_Post(id)
{
    if(!is_user_alive(id))
    {
        return HAM_IGNORED
    }

    // Spawn can fire before HLTV this round. Lock the freeze window so the
    // +0.2s Task_ApplySpawn cannot write maxspeed while the engine still owns it.
    BpMarkFreezeIfNeeded()

    remove_task(id + TASK_SPAWN)
    set_task(0.2, "Task_ApplySpawn", id + TASK_SPAWN)
    return HAM_IGNORED
}

public Task_ApplySpawn(taskid)
{
    new id = taskid - TASK_SPAWN

    if(!is_user_alive(id))
    {
        return
    }

    BpMarkFreezeIfNeeded()

    RebuildPlayerState(id, false)

    // ---- spawn armour + health (playtest fix 2026-11) ---------------------
    // CS 1.6 caps armour at 100, so `100 + bonus` was always 100 and every point
    // of the armour perk above the cap was silently thrown away - which is why
    // the perk felt worthless to a VIP (who already spawns with 100) and why a
    // non-VIP perk player spawned with LESS than 100. BpApplySpawnArmour() owns
    // the whole decision now: perk = 100 AP + helmet on every spawn, the overflow
    // above 100 becomes HP at 1 HP per 2 AP up to the spawn HP ceiling.
    new iOverflowHp = BpApplySpawnArmour(id)
    set_user_health(id, 100 + g_iHPBonus[id] + iOverflowHp)

    // Battle Pass tier 8: free defuse kit on CT spawn.
    // "item_defuser" is not a CS 1.6 item class: every call logged
    // `[FUN] Item "item_defuser" failed to create` followed by a give_item
    // run time error, which aborted the rest of this spawn function (armor,
    // gravity, speed, health nade, model assignment). The real class is
    // item_thighpack, as used by freenova_vip.sma:1633. The ownership guard
    // stops a respawn stacking a second kit entity on a player who has one.
    if(g_iMilestonePaid[id] >= 8 && cs_get_user_team(id) == CS_TEAM_CT && !cs_get_user_defuse(id))
        give_item(id, "item_thighpack")

    // Battle Pass tier 14: extra HE on spawn. Armour is NOT decided here any
    // more (it used to be an else-if chain, so a tier-14+ player silently got no
    // armour at all): BpApplySpawnArmour() above already applied it.
    if(g_iMilestonePaid[id] >= 14)
        give_item(id, "weapon_hegrenade")

    set_user_gravity(id, g_fGravityMult[id])

    RefreshSpeed(id)
    GiveHealthNadeSmoke(id)
    remove_task(id + TASK_HN_SMOKE)
    set_task(0.8, "Task_GiveHealthNadeSmoke", id + TASK_HN_SMOKE)

    // Model assignment delegated to authoritative weapon_models resolver
    // (avoids model stacking and race conditions on spawn)
}

public Task_GiveHealthNadeSmoke(taskid)
{
    new id = taskid - TASK_HN_SMOKE
    if(is_user_alive(id))
        GiveHealthNadeSmoke(id)
}

stock GiveHealthNadeSmoke(id)
{
    if(!is_user_alive(id) || !g_bHasHealthNade[id])
        return

    // reapi_healthnade owns the real weapon, models, throw/drink behavior.
    new ent = HealthNade_GiveNade(id, 1, 1)
    if(ent == HN_NULLENT)
        return

    new iHnStage = g_iShopSkillLevel[id][SKILL_HEALTHNADE]
    new Float:fHeal = (iHnStage >= 2) ? 30.0 : 15.0
    set_entvar(ent, var_HealthNade_ThrowHealingAmount, fHeal)
    set_entvar(ent, var_HealthNade_DrinkHealingAmount, fHeal)
    set_entvar(ent, var_HealthNade_Radius, 260.0)
}

// ---- spawn armour (playtest fix 2026-11) ---------------------------------
// The engine clips cs_set_user_armor() above 100, so everything the Battle Pass
// armour perk grants beyond that used to be thrown away. The rule now, and the
// numbers chosen for it (documented in docs/WINTERFEST-PLAYTEST-FIXES.md §5):
//   * a player WITH the armour perk spawns with 100 AP and a helmet, every spawn;
//   * the part of the bonus above the engine cap becomes HP at 1 HP per 2 AP;
//   * that HP may not push the player past the spawn HP ceiling (100 + the 20
//     HP cap RebuildPlayerState() already enforces), so it can never be a tap.
#define BP_SPAWN_ARMOR_CAP      100   // the engine's own armour cap
#define BP_ARMOR_HP_DIV         2     // 2 armour points that cannot be used = 1 HP
#define BP_SPAWN_HP_CEILING     120   // 100 base + the 20 HP ceiling
#define BP_ARMOR_BONUS_CEILING  200   // sanity ceiling on the BONUS itself (must
                                      // be able to pass 100 or there is nothing
                                      // to convert)

// Applies this spawn's armour and returns the HP the overflow converted into
// (0 for everyone without overflow, which is the normal case). Called from
// Task_ApplySpawn and from the paid "Full HP + Armor" shop item.
stock BpApplySpawnArmour(id)
{
    new iBonus = g_iArmorBonus[id]
    if(iBonus > 0)
    {
        // The perk: 100 and a helmet on every spawn, for everyone who has it.
        cs_set_user_armor(id, BP_SPAWN_ARMOR_CAP, CS_ARMOR_VESTHELM)

        // Everything above the engine cap is converted, at 2 AP per HP, but never
        // past the spawn HP ceiling - so the conversion is worth something and
        // still cannot be farmed.
        new iOver = iBonus - BP_SPAWN_ARMOR_CAP
        new iHp = 0
        if(iOver > 0)
        {
            iHp = iOver / BP_ARMOR_HP_DIV
            new iRoom = BP_SPAWN_HP_CEILING - (100 + g_iHPBonus[id])
            if(iRoom < 0)
                iRoom = 0
            if(iHp > iRoom)
                iHp = iRoom
        }

        // Once per spawn, debug level only: an operator tuning the perk needs to
        // see the decision and the conversion, a normal boot stays quiet.
        if(get_pcvar_num(g_pDebug))
            log_amx("[BP] spawn armour id=%d: bonus=%d -> %d AP + helmet, %d AP of overflow -> +%d HP (2 AP = 1 HP, ceiling %d)",
                id, iBonus, BP_SPAWN_ARMOR_CAP, (iOver > 0) ? iOver : 0, iHp, BP_SPAWN_HP_CEILING)
        return iHp
    }

    // No perk: unchanged from before this fix. A VIP keeps the flat 100 + helmet
    // it always had, everyone else spawns with no armour.
    new bool:bVip = (fnvip_get_tier(id) >= FNVIP_VIP) ? true : false
    if(bVip)
        cs_set_user_armor(id, 100, CS_ARMOR_VESTHELM)
    else
        cs_set_user_armor(id, 0, CS_ARMOR_NONE)

    if(get_pcvar_num(g_pDebug))
        log_amx("[BP] spawn armour id=%d: no armour perk -> %s", id, bVip ? "VIP 100 AP + helmet" : "no armour")
    return 0
}

RebuildPlayerState(id, bool:bLive)
{
    new oldHp = g_iHPBonus[id]
    new oldArmor = g_iArmorBonus[id]

    ResetCombatState(id)

    new level = crxranks_get_user_level(id)

    if(level < 1)
    {
        level = 1
    }

    if(level > MAX_LEVELS)
    {
        level = MAX_LEVELS
    }

    for(new i = 1; i <= level; i++)
    {
        g_iHPBonus[id] = g_iHPByLevel[i]
        g_iArmorBonus[id] = g_iArmorByLevel[i]
        g_fKnifeSpeed[id] = g_fKnifeSpeedByLevel[i]
        g_fDamageMult[id] = g_fDamageByLevel[i]
        g_fGravityMult[id] = g_fGravityByLevel[i]
        g_fReloadCap[id] = g_fReloadCapByLevel[i]
        g_fPlantSpeed[id] = g_fPlantSpeedByLevel[i]
        g_fDefuseSpeed[id] = g_fDefuseSpeedByLevel[i]
        g_fSwitchSpeed[id] = g_fSwitchSpeedByLevel[i]
        g_fFallReduce[id] = g_fFallDmgReduceByLevel[i]

        // Always available for everyone
        g_bHasWeaponMenu[id] = true
    }

    // Shop-purchased multi-stage skills
    new iJumpStage = g_iShopSkillLevel[id][SKILL_MULTI_JUMP]
    if(iJumpStage > 0)
    {
        g_bHasDoubleJump[id] = true
        g_iDoubleJumpCount[id] = iJumpStage // 1=Double, 2=Triple, 3=Quad
        g_fDoubleJumpPower[id] = 270.0 + (float(iJumpStage - 1) * 10.0)
    }

    // Spawn HP Boost (+2 / +4 / +6 HP)
    new iHpStage = g_iShopSkillLevel[id][SKILL_SPAWN_HP]
    if(iHpStage > 0)
    {
        g_iHPBonus[id] += (iHpStage * 2)
    }

    // Spawn Armor Boost (+3 / +6 / +9 AP)
    new iArmorStage = g_iShopSkillLevel[id][SKILL_SPAWN_ARMOR]
    if(iArmorStage > 0)
        g_iArmorBonus[id] += (iArmorStage * 3)

    // Nimble Agility (+1% / +2% / +3% Speed)
    new iNimbleStage = g_iShopSkillLevel[id][SKILL_NIMBLE]
    if(iNimbleStage > 0)
    {
        g_bHasNimble[id] = true
        g_fNimbleMult[id] = 1.0 + (float(iNimbleStage) * 0.01)
    }

    // Featherfall (15% / 30% / 45% reduction)
    new iFallStage = g_iShopSkillLevel[id][SKILL_FEATHERFALL]
    if(iFallStage == 1) g_fFeatherFall[id] = 0.15
    else if(iFallStage == 2) g_fFeatherFall[id] = 0.30
    else if(iFallStage >= 3) g_fFeatherFall[id] = 0.45

    // Healthnade (1 = +15 HP, 2 = +30 HP)
    new iHnStage = g_iShopSkillLevel[id][SKILL_HEALTHNADE]
    if(iHnStage > 0)
    {
        g_bHasHealthNade[id] = true
        g_fHNDrink[id] = (iHnStage >= 2) ? 30.0 : 15.0
    }

    // Fast Sniper (1 = 10% faster, 2 = 20% faster)
    new iSniperStage = g_iShopSkillLevel[id][SKILL_FAST_SNIPER]
    if(iSniperStage > 0)
    {
        g_bHasFastSniper[id] = true
        g_fFastSniperDelay[id] = (iSniperStage >= 2) ? 0.60 : 0.675
    }

    // Combat Medic (1 = 3.0s, 2 = 2.0s).
    new iRevStage = g_iShopSkillLevel[id][SKILL_REVIVE]
    if(iRevStage > 0)
    {
        g_bHasRevive[id] = true
        g_fReviveTime[id] = (iRevStage >= 2) ? 2.0 : 3.0
        g_iMaxRevives[id] = iRevStage
        g_iMaxSpawns[id] = iRevStage
    }

    if(g_iShopSkillLevel[id][SKILL_AWP_UNLOCK] > 0)
        g_bHasWeaponMenuAwp[id] = true

    if(g_iShopSkillLevel[id][SKILL_LASTSTAND] > 0)
        g_bHasLastStand[id] = true

    if(g_iShopSkillLevel[id][SKILL_PARACHUTE] > 0)
        g_bHasParachute[id] = true

    g_iHPBonus[id] += min(20, g_iPassHp[id])
    g_iArmorBonus[id] += g_iPassArmor[id]
    if(g_iPassJumps[id] > 0)
    {
        g_bHasDoubleJump[id] = true
        g_iDoubleJumpCount[id] = min(4, g_iDoubleJumpCount[id] + g_iPassJumps[id])
    }
    if(g_iPassChute[id])
        g_bHasParachute[id] = true
    new iSn = max(g_iShopSkillLevel[id][SKILL_FAST_SNIPER], g_iPassSniper[id])
    if(iSn > 0)
    {
        g_bHasFastSniper[id] = true
        g_fFastSniperDelay[id] = (iSn >= 2) ? 0.60 : 0.675
    }
    new iLs = max(g_iShopSkillLevel[id][SKILL_LASTSTAND], g_iPassLaststand[id])
    if(iLs > 0)
        g_bHasLastStand[id] = true

    // Premium Prime micro-bonuses. Derived from the premium cursor so they
    // survive reconnects without inflating the existing stat fields.
    if(g_iPremiumPaid[id] >= 17) g_iHPBonus[id]++
    if(g_iPremiumPaid[id] >= 55) g_iHPBonus[id]++
    if(g_iPremiumPaid[id] >= 19) g_iArmorBonus[id] += 2
    if(g_iPremiumPaid[id] >= 33) g_iArmorBonus[id] += 2
    if(g_iPremiumPaid[id] >= 21) g_fNimbleMult[id] += 0.01
    if(g_iPremiumPaid[id] >= 37) g_fNimbleMult[id] += 0.01
    if(g_iPremiumPaid[id] >= 57) g_fNimbleMult[id] += 0.01
    if(g_iMilestonePaid[id] >= 56) g_fNimbleMult[id] += 0.01
    if(g_iMilestonePaid[id] >= 59) g_fNimbleMult[id] += 0.01
    if(g_iPremiumPaid[id] >= 25) g_fFeatherFall[id] += 0.05
    if(g_iPremiumPaid[id] >= 45 && g_fFastSniperDelay[id] > 0.10)
        g_fFastSniperDelay[id] -= 0.05
    if(g_iPremiumPaid[id] >= 49)
        g_fHNDrink[id] += 5.0

    // Hard caps: skills are sidegrades, not raw stat inflation.
    g_iHPBonus[id] = min(g_iHPBonus[id], 20)
    // The armour BONUS is deliberately not clamped at the engine's 100 any more:
    // everything above 100 is converted to HP at spawn (BpApplySpawnArmour), and
    // clamping here would delete it before the conversion could see it.
    g_iArmorBonus[id] = min(g_iArmorBonus[id], BP_ARMOR_BONUS_CEILING)
    if(g_fNimbleMult[id] > 1.10)
        g_fNimbleMult[id] = 1.10
    if(g_fFeatherFall[id] > 0.50)
        g_fFeatherFall[id] = 0.50

    // Revive flag management. Only ADD the flag when the skill is owned;
    // never strip it otherwise - it collides with a legit admin flag and
    // stripping it broke revive for external consumers (audit finding).
    // We record every flag WE add so the revoke in ResetCombatState can
    // safely strip exactly those and nothing else.
    if(g_bHasRevive[id])
    {
        new iFlags = get_user_flags(id)
        new iReviveFlag = read_flags("n")
        if(!(iFlags & iReviveFlag))
        {
            set_user_flags(id, iFlags | iReviveFlag)
            g_bReviveFlagGranted[id] = true
        }
    }

    if(bLive && is_user_alive(id))
        GiveHealthNadeSmoke(id)

    // Apply live changes
    if(bLive && is_user_alive(id))
    {
        if(g_iHPBonus[id] > oldHp)
            set_user_health(id, get_user_health(id) + (g_iHPBonus[id] - oldHp))

        if(g_iArmorBonus[id] > oldArmor)
        {
            // Mid-round (a skill bought in the shop): grant the difference, but
            // never above the engine cap. No HP conversion here - the conversion
            // is a spawn rule, so a live purchase cannot become an HP tap.
            new CsArmorType:type
            new curArmor = cs_get_user_armor(id, type)
            new iNew = curArmor + (g_iArmorBonus[id] - oldArmor)
            if(iNew > BP_SPAWN_ARMOR_CAP)
                iNew = BP_SPAWN_ARMOR_CAP
            cs_set_user_armor(id, iNew, CS_ARMOR_VESTHELM)
        }

        set_user_gravity(id, g_fGravityMult[id])
        RefreshSpeed(id)
    }
}

// ============================================================
// WEAPON / SPEED
// ============================================================
public Event_CurWeapon(id)
{
    if(!is_user_alive(id))
        return

    RefreshSpeed(id)
}

// Freezetime guard: writing maxspeed while the engine holds players at 1.0
// un-freezes them until the next engine speed recalc (the "can move for a
// second at round start" bug). Track the freeze window the same way the CRX
// core does - HLTV = new round, Round_Start = freeze over.
new bool:g_bFreezeTime
new bool:g_bRoundStarted // true after Round_Start until the next HLTV

stock bool:BpFreezeCvarOn()
{
    return (g_pCvarFreezeTime && get_pcvar_num(g_pCvarFreezeTime) > 0)
}

stock BpMarkFreezeIfNeeded()
{
    if(!g_bRoundStarted && BpFreezeCvarOn())
        g_bFreezeTime = true
}

public Event_NewRound_HLTV()
{
    g_bRoundStarted = false
    // Only treat it as a freeze window when freezetime is actually configured
    g_bFreezeTime = BpFreezeCvarOn()
    for(new i = 1; i <= MAX_PLAYERS; i++)
        g_bBoughtHeal[i] = false
}

public Event_RoundStart_BP()
{
    g_bFreezeTime = false
    g_bRoundStarted = true

    // Freeze just ended: re-apply legit speed modifiers immediately so
    // knife/nimble bonuses do not wait for the player's first weapon switch
    new iPlayers[MAX_PLAYERS], iNum
    get_players(iPlayers, iNum, "a")
    for(new i = 0; i < iNum; i++)
        RefreshSpeed(iPlayers[i])
}

stock Float:GetWeaponBaseSpeed(iWeaponId)
{
    switch(iWeaponId)
    {
        case CSW_SCOUT: return 260.0;
        case CSW_AWP, CSW_G3SG1, CSW_SG550: return 210.0;
        case CSW_M249: return 220.0;
        case CSW_XM1014, CSW_M3: return 240.0;
        case CSW_AK47, CSW_M4A1, CSW_GALIL, CSW_FAMAS, CSW_AUG, CSW_SG552: return 250.0;
        default: return 250.0;
    }
    return 250.0;
}

RefreshSpeed(id)
{
    if(!is_user_alive(id))
        return

    // Never touch maxspeed while frozen - the engine owns it until Round_Start
    if(g_bFreezeTime)
        return
    if(get_member_game(m_bFreezePeriod))
        return

    new iWpn = get_user_weapon(id)
    new Float:fBase = (iWpn == CSW_KNIFE) ? g_fKnifeSpeed[id] : GetWeaponBaseSpeed(iWpn)

    new Float:fMult = 1.0
    if(g_bHasNimble[id] && g_fNimbleMult[id] > 1.0)
    {
        fMult *= g_fNimbleMult[id]
    }

    if(g_bAdrenalineRush[id])
    {
        fMult *= 1.25
    }

    set_user_maxspeed(id, fBase * fMult)
}

public Task_EndAdrenaline(taskid)
{
    new id = taskid - TASK_ADRENALINE
    if(1 <= id <= MAX_PLAYERS && is_user_alive(id))
    {
        g_bAdrenalineRush[id] = false
        RefreshSpeed(id)
    }
}

public Ham_WeaponReload_Post(ent)
{
    if(!pev_valid(ent))
        return HAM_IGNORED

    new id = get_pdata_cbase(ent, 41, XO_WEAPON)

    if(id < 1 || id > MAX_PLAYERS || !is_user_alive(id))
        return HAM_IGNORED

    new Float:cur = get_pdata_float(id, m_offset_NextAttack, XO_PLAYER)

    if(cur <= 0.0)
        return HAM_IGNORED

    if(cur > g_fReloadCap[id])
        set_pdata_float(id, m_offset_NextAttack, g_fReloadCap[id], XO_PLAYER)

    new Float:w1 = get_pdata_float(ent, m_offset_NextPrimaryAttack, XO_WEAPON)
    new Float:w2 = get_pdata_float(ent, m_offset_NextSecondaryAttack, XO_WEAPON)
    new Float:w3 = get_pdata_float(ent, m_offset_TimeWeaponIdle, XO_WEAPON)

    if(w1 > g_fReloadCap[id])
        set_pdata_float(ent, m_offset_NextPrimaryAttack, g_fReloadCap[id], XO_WEAPON)

    if(w2 > g_fReloadCap[id])
        set_pdata_float(ent, m_offset_NextSecondaryAttack, g_fReloadCap[id], XO_WEAPON)

    if(w3 > g_fReloadCap[id])
        set_pdata_float(ent, m_offset_TimeWeaponIdle, g_fReloadCap[id], XO_WEAPON)

    message_begin(MSG_ONE, get_user_msgid("BarTime"), _, id)
    write_short(floatround(g_fReloadCap[id]))
    message_end()

    return HAM_IGNORED
}

public Ham_TakeDamage_Pre(victim, inflictor, attacker, Float:damage, damagebits)
{
    #pragma unused inflictor

    // Headshot Only: TraceAttack stores the last hitgroup. A stale HIT_HEAD
    // from an earlier bullet would otherwise let a later body shot through.
    // HE/blast is exempt (no TraceAttack). Drop the cached group after 0.15s.
    if(get_pcvar_num(g_pCvarHSOnly)
        && attacker >= 1 && attacker <= MAX_PLAYERS
        && attacker != victim
        && is_user_connected(attacker)
        && !(damagebits & DMG_BLAST))
    {
        new Float:fNow = get_gametime()
        if(g_fLastHitGroupTime[victim] <= 0.0 || (fNow - g_fLastHitGroupTime[victim]) > 0.15
            || g_iLastHitGroupAtk[victim] != attacker)
            g_iLastHitGroup[victim] = 0
        if(g_iLastHitGroup[victim] != HIT_HEAD)
            return HAM_SUPERCEDE
        g_iLastHitGroup[victim] = 0
        g_iLastHitGroupAtk[victim] = 0
        g_fLastHitGroupTime[victim] = 0.0
    }

    // Damage multiplier from level progression
    if(attacker >= 1 && attacker <= MAX_PLAYERS && attacker != victim && is_user_connected(attacker))
    {
        if(g_fDamageMult[attacker] > 1.0)
        {
            SetHamParamFloat(4, damage * g_fDamageMult[attacker])
            return HAM_HANDLED
        }
    }

    // Last Stand skill: once per spawn, a lethal hit from another player
    // leaves the owner at 5 HP (Stage 1) or 10 HP + speed burst (Stage 2)
    if(g_bHasLastStand[victim]
        && attacker >= 1 && attacker <= MAX_PLAYERS && attacker != victim
        && is_user_alive(victim)
        && !g_bLastStandProc[victim]
        && get_systime() >= g_iLastStandUntil[victim]
        && floatround(get_user_health(victim) - damage) <= 0
        && !(damagebits & DMG_BLAST) && !(damagebits & DMG_FALL))
    {
        new iStage = max(g_iShopSkillLevel[victim][SKILL_LASTSTAND], g_iPassLaststand[victim])
        g_bLastStandProc[victim] = true
        g_iLastStandUntil[victim] = get_systime() + 30
        SetHamParamFloat(4, 0.0) // nullify the lethal hit

        new iSurviveHp = (iStage >= 2) ? 10 : 5
        if(g_iPremiumPaid[victim] >= 53)
            iSurviveHp += 2
        set_user_health(victim, iSurviveHp)

        // Adrenaline audio and visual feedback
        Util_ScreenFade(victim, 255, 30, 30, 160, 0.8)
        emit_sound(victim, CHAN_VOICE, "player/breathe1.wav", 1.0, ATTN_NORM, 0, PITCH_NORM)

        client_printcolor(victim, "!g[FreeNova] !tLAST STAND ACTIVATED! !nSurviving with !g%d HP!n!", iSurviveHp)

        if(iStage >= 2)
        {
            g_bAdrenalineRush[victim] = true
            RefreshSpeed(victim)
            remove_task(victim + TASK_ADRENALINE)
            set_task(3.0, "Task_EndAdrenaline", victim + TASK_ADRENALINE)
            client_printcolor(victim, "!g[FreeNova] !tADRENALINE RUSH! !n+25%% Speed for 3 seconds!")
        }

        return HAM_HANDLED
    }

    // Feather Fall skill: 15% / 30% / 45% fall-damage reduction (capped).
    if(g_fFeatherFall[victim] > 0.0 && (damagebits & DMG_FALL))
    {
        if(g_fFeatherFall[victim] >= 0.99)
        {
            SetHamParamFloat(4, 0.0)
            emit_sound(victim, CHAN_ITEM, "player/pl_dirt1.wav", 0.6, ATTN_NORM, 0, PITCH_NORM)
            return HAM_HANDLED
        }
        new Float:fNewDamage = damage * (1.0 - g_fFeatherFall[victim])
        SetHamParamFloat(4, fNewDamage)
        return HAM_HANDLED
    }

    return HAM_IGNORED
}

public Ham_TraceAttack_Pre(victim, attacker, Float:damage, Float:direction[3], tracehandle, damagebits)
{
    #pragma unused damage, direction, damagebits

    g_iLastHitGroup[victim] = get_tr2(tracehandle, TR_iHitgroup)
    g_iLastHitGroupAtk[victim] = attacker
    g_fLastHitGroupTime[victim] = get_gametime()

    return HAM_IGNORED
}

// ============================================================
// DOUBLE JUMP (parachute handled by parachute.sma)
// ============================================================
public client_PreThink(id)
{
    if(!is_user_alive(id))
        return PLUGIN_CONTINUE

    if(g_bHasDoubleJump[id])
    {
        new nbut = get_user_button(id)
        new obut = get_user_oldbutton(id)

        if((nbut & IN_JUMP) && !(pev(id, pev_flags) & FL_ONGROUND) && !(obut & IN_JUMP))
        {
            if(g_iJumpsUsed[id] < g_iDoubleJumpCount[id])
            {
                g_bDoJump[id] = true
                g_iJumpsUsed[id]++
            }
        }

        if((nbut & IN_JUMP) && (pev(id, pev_flags) & FL_ONGROUND))
        {
            g_iJumpsUsed[id] = 0
        }
    }

    return PLUGIN_CONTINUE
}

public client_PostThink(id)
{
    if(!is_user_alive(id))
        return PLUGIN_CONTINUE

    if(g_bDoJump[id])
    {
        new Float:vel[3]
        entity_get_vector(id, EV_VEC_velocity, vel)
        vel[2] = g_fDoubleJumpPower[id]
        entity_set_vector(id, EV_VEC_velocity, vel)
        g_bDoJump[id] = false

        emit_sound(id, CHAN_ITEM, "player/pl_dirt1.wav", 0.6, ATTN_NORM, 0, PITCH_NORM)
    }

    return PLUGIN_CONTINUE
}

// ============================================================
// FAST SNIPER
// ============================================================
public Ham_SniperDeploy_Post(ent)
{
    if(!pev_valid(ent))
        return HAM_IGNORED

    new id = get_pdata_cbase(ent, 41, XO_WEAPON)

    if(id < 1 || id > MAX_PLAYERS || !is_user_alive(id))
        return HAM_IGNORED

    if(!g_bHasFastSniper[id])
        return HAM_IGNORED

    set_pdata_float(ent, m_offset_NextPrimaryAttack, g_fFastSniperDelay[id], XO_WEAPON)
    set_pdata_float(ent, m_offset_NextSecondaryAttack, g_fFastSniperDelay[id], XO_WEAPON)
    set_pdata_float(id, m_offset_NextAttack, g_fFastSniperDelay[id], XO_PLAYER)

    return HAM_IGNORED
}

public Ham_SniperAttack_Post(ent)
{
    if(!pev_valid(ent))
        return HAM_IGNORED

    new id = get_pdata_cbase(ent, 41, XO_WEAPON)
    if(id < 1 || id > MAX_PLAYERS || !is_user_alive(id) || !g_bHasFastSniper[id])
        return HAM_IGNORED

    new iStage = max(g_iShopSkillLevel[id][SKILL_FAST_SNIPER], g_iPassSniper[id])
    if(iStage <= 0)
        return HAM_IGNORED

    new Float:flNext = get_pdata_float(ent, m_offset_NextPrimaryAttack, XO_WEAPON)
    if(flNext > 0.0)
    {
        new Float:fMult = (iStage >= 2) ? 0.70 : 0.85
        set_pdata_float(ent, m_offset_NextPrimaryAttack, flNext * fMult, XO_WEAPON)
        set_pdata_float(id, m_offset_NextAttack, flNext * fMult, XO_PLAYER)
    }

    return HAM_IGNORED
}

// ============================================================
stock Util_ScreenFade(id, red, green, blue, alpha, Float:holdTime)
{
    static msgScreenFade = 0
    if(!msgScreenFade)
        msgScreenFade = get_user_msgid("ScreenFade")
    message_begin(MSG_ONE_UNRELIABLE, msgScreenFade, _, id)
    write_short(floatround(4096.0 * holdTime)) // Duration
    write_short(floatround(4096.0 * holdTime)) // Hold time
    write_short(0x0001)                        // Fade out
    write_byte(red)
    write_byte(green)
    write_byte(blue)
    write_byte(alpha)
    message_end()
}

// ============================================================
// COMBAT TRACKING (kills/headshots) - COINS ONLY
// ============================================================
// Historical csx contract: forward client_damage(attacker, victim,
// damage, wpnindex, hitplace, TA). Kills were once counted here for
// mission progress; counting kills in client_damage is wrong (fires
// per damage event while the victim is alive) and hitplace param 5
// was previously misread as a weapon bit - real headshots (HIT_HEAD=1)
// were rejected while chest shots counted.
// Mission/achievement tracking is now owned by freenova_missions and
// freenova_achievements; this file only credits kill coins.
// client_death retired: the only thing it did was clear the legacy daily
// streak counter (suicides/world deaths). That state now lives in
// freenova_missions (daily2# vault keys), so no CSX death hook is needed.

public fn_on_player_kill(attacker, victim, wpnindex, headshot, tk)
{
    #pragma unused wpnindex
    if(!is_user_connected(attacker) || is_user_bot(attacker))
        return

    // Ranked combat still delivers teamkills. Coins skip TK; mission
    // tracking is owned by freenova_missions. Bot victims pay no coins
    // (progression owns capped bot-kill XP; core counts the stats).
    if(tk || (victim >= 1 && is_user_bot(victim)))
        return

    new iKillCoins = headshot ? 3 : 2
    if(LibraryExists("freenova_vip", LibType_Library))
    {
        new Float:fVipMult = fnvip_get_coin_multiplier(attacker)
        if(fVipMult > 1.0)
        {
            iKillCoins = floatround(float(iKillCoins) * fVipMult, floatround_ceil)
        }
    }
    // Event coin multiplier (panel-advertised "coins xN"): multiplicative on
    // the VIP-adjusted amount. Values <= 1.0 mean no event.
    if (g_pCvarEventCoins)
    {
        new Float:fCoinMult = get_pcvar_float(g_pCvarEventCoins)
        if (fCoinMult > 1.0)
            iKillCoins = floatround(float(iKillCoins) * fCoinMult, floatround_ceil)
    }
    BpCreditCoins(attacker, iKillCoins)

    // Vampire skill: 1 / 2 / 3 HP lifesteal on a kill. Deliberately tiny:
    // it is a sustain sidegrade, not a second health pool.
    new iVampStage = g_iShopSkillLevel[attacker][SKILL_VAMPIRE]
    if(iVampStage > 0 && is_user_alive(attacker))
    {
        new iHeal = iVampStage

        new iMaxHp = 100 + g_iHPBonus[attacker]
        new iCur = get_user_health(attacker)
        if(iCur < iMaxHp)
        {
            new iNewHp = min(iCur + iHeal, iMaxHp)
            set_user_health(attacker, iNewHp)
            Util_ScreenFade(attacker, 180, 0, 0, 70, 0.25)
            emit_sound(attacker, CHAN_ITEM, "items/smallmedkit1.wav", 0.7, ATTN_NORM, 0, PITCH_NORM)
        }
    }
}

// ============================================================
// MISSION TRACKING - BOMBS
// ============================================================
public bomb_planted(id)
{
    #pragma unused id
}

public bomb_defused(id)
{
    #pragma unused id
}

// ============================================================
// ROUND WIN MISSION TRACKING
// ============================================================
public crxranks_user_xp_updated(id, xp, CRXRanks_XPSources:source)
{
    #pragma unused xp, source
}

// winners: alive members of the team that won the round
// fires from the SendAudio event registered in plugin_init



// ============================================================
// DAILY MISSION CHECKS
// ============================================================


// ============================================================
// ACHIEVEMENTS ENGINE - REMOVED (not owned here)
// ============================================================
// GiveAchievement / UnlockAchievementsFromStats / ResetMissions were
// retired stubs: every body started with "#pragma unused ... return",
// so nothing was ever unlocked and no coins were ever paid by this file.
// freenova_achievements is the single authority (ach# vault key) and
// freenova_missions the single writer of daily#/weekly#/daily2#/roll#.
// The retired BP-side daily persistence (LoadDaily2/SaveDaily2) was
// removed with them - see the persistence section below.

// ============================================================
// TOP 3 COIN REWARDS (end of round)
// ============================================================
public Event_RoundEnd()
{
    // Knife/warmup rounds pay nothing (same guard as the XP pipeline).
    if (get_cvar_num("amx_knife_round_active") == 1)
        return;

    // Next-round freeze can start (Ham_Spawn) before HLTV. Drop the previous
    // Round_Start flag so spawn-before-HLTV can lock maxspeed writes.
    // Do not set g_bFreezeTime here: players still walk until the next freeze.
    g_bRoundStarted = false

    new players[32], num
    get_players(players, num, "ch")

    if(num < 3) return

    // Sort players by XP (highest first). Cache XP once: the old code
    // called crxranks_get_user_xp (a cross-plugin native) on every one of
    // the O(n^2) comparisons.
    new iXp[32]
    for(new k = 0; k < num; k++)
        iXp[k] = crxranks_get_user_xp(players[k])
    for(new i = 0; i < num - 1; i++)
    {
        for(new j = i + 1; j < num; j++)
        {
            if(iXp[j] > iXp[i])
            {
                new temp = players[i]
                players[i] = players[j]
                players[j] = temp
                temp = iXp[i]
                iXp[i] = iXp[j]
                iXp[j] = temp
            }
        }
    }

    // Top 1: 15 coins
    if(num >= 1 && is_user_connected(players[0]))
    {
        BpCreditCoins(players[0], 15)
        client_printcolor(players[0], "!g[FreeNova] !nTop 1 !gMVP!n! +!g15 Coins!n")
    }

    // Top 2: 10 coins
    if(num >= 2 && is_user_connected(players[1]))
    {
        BpCreditCoins(players[1], 10)
        client_printcolor(players[1], "!g[FreeNova] !nTop 2! +!g10 Coins!n")
    }

    // Top 3: 5 coins
    if(num >= 3 && is_user_connected(players[2]))
    {
        BpCreditCoins(players[2], 5)
        client_printcolor(players[2], "!g[FreeNova] !nTop 3! +!g5 Coins!n")
    }
}

// ============================================================
// MILESTONE REWARDS (Coins)
// ============================================================
CheckMilestoneReward(id, level)
{
    // Single source of truth: g_iBpFreeCoins (verified identical to the
    // retired 60-case switch, tier for tier). Out-of-range = no grant.
    new iCoins = (1 <= level <= MAX_LEVELS) ? g_iBpFreeCoins[level] : 0
    if(iCoins > 0)
    {
        BpCreditCoins(id, iCoins)
        client_printcolor(id, "!g[FreeNova] !n Level %d reached! +!g%d Coins !n", level, iCoins)
        BpMarkClaimed(id, level, 0, g_iPremiumLane[id])
    }

    if(level == 53 && get_cvar_num("fn_bp_season") == 1)
    {
        if(BpTryCosmetic(id, "weapon_models", "model_s1_op"))
        {
            fn_models_unlock(id, "s1_op_ct")
            fn_models_unlock(id, "s1_op_t")
        }
        if(BpTryCosmetic(id, "weapon_models", "skin_s1_asiimov"))
            fn_skins_unlock_model(id, 0, "models/fn_s1/v_ak47_asiimov.mdl")
        client_printcolor(id, "!g[FreeNova] !n Season 1 Operator models + Asiimov AK unlocked (permanent).")
    }

    new iXp = 50
    switch(BpRarity(level))
    {
        case 1: iXp = 150
        case 2: iXp = 300
        case 3: iXp = 750
        case 4: iXp = 1500
    }
    if(iXp > 0 && LibraryExists("crxranks", LibType_Library))
        crxranks_give_user_xp(id, iXp, "", CRXRANKS_XPS_PLUGIN)
    BpGrantLaneSkills(id, g_iPremiumLane[id], level)
    BpGrantFreeTrack(id, level)
}

stock BpRarity(level)
{
    switch(level)
    {
        case 5, 10, 15, 20, 35, 48, 53, 54, 56, 57:
            return 1
        case 25, 30, 40, 45, 58, 59:
            return 2
        case 50, 51, 55:
            return 3
        case 52, 60:
            return 4
    }
    return 0
}

stock BpVipLane(id)
{
    new t = fnvip_get_tier(id)
    if(t >= FNVIP_ELITE)
        return 3
    if(t >= FNVIP_VIPPLUS)
        return 2
    if(t >= FNVIP_VIP)
        return 1
    return 0
}

stock BpPremiumTotalCoins(tier, lane)
{
    if(lane < 1 || tier < 1 || tier > MAX_LEVELS)
        return 0
    return g_iBpFreeCoins[tier] + g_iBpPremiumCoins[tier]
}

stock BpPremiumExtraCoins(tier)
{
    return BpPremiumExtraCoinsLane(tier, 1)
}

stock BpPremiumExtraCoinsLane(tier, lane)
{
    if(tier < 1 || tier > MAX_LEVELS || lane < 1)
        return 0
    return g_iBpPremiumCoins[tier]
}

stock BpGrantLaneExclusives(id, lane)
{
    if(lane < 2 || get_cvar_num("fn_bp_season") != 1)
        return
    if(g_iPremiumPaid[id] < 56)
        return
    if(!BpTryCosmetic(id, "weapon_models", "model_s1_vip"))
        return
    fn_models_unlock(id, "s1_vip_ct")
    fn_models_unlock(id, "s1_vip_t")
    fn_skins_unlock_model(id, 1, "models/fn_s1/v_m4a1_howl.mdl")
    fn_skins_unlock_model(id, 4, "models/fn_s1/v_knife_karambit.mdl")
}

stock BpUpgradePremiumLane(id, oldLane, newLane)
{
    if(newLane <= oldLane || newLane < 1)
        return
    new iMax = min(g_iPremiumPaid[id], MAX_LEVELS)
    if(iMax < 1)
        iMax = min(g_iMilestonePaid[id], MAX_LEVELS)
    new from = (oldLane < 1) ? 1 : oldLane
    for(new lane = from + 1; lane <= newLane; lane++)
    {
        new delta
        for(new t = 1; t <= iMax; t++)
        {
            delta = BpPremiumExtraCoinsLane(t, lane) - BpPremiumExtraCoinsLane(t, lane - 1)
            if(delta > 0)
            {
                g_iCoins[id] += delta
                BpMarkClaimed(id, t, 1, lane)
                client_printcolor(id, "!g[FreeNova] !n Premium lane %d tier %d! +!g%d Coins !n", lane, t, delta)
            }
        }
        for(new t = 1; t <= iMax; t++)
        {
            BpGrantLaneSkills(id, lane, t)
            BpMarkClaimed(id, t, 1, lane)
        }
        BpGrantLaneExclusives(id, lane)
    }
    if(iMax > 0)
        SaveCoins(id)
    g_iPremiumLane[id] = newLane
    SavePremiumLane(id)
    if(newLane == 2)
        client_printcolor(id, "!g[FreeNova] !n Battle Pass upgraded to VIP+ track. Kept your tier; claimed VIP+ extras from 1.")
    else if(newLane == 3)
        client_printcolor(id, "!g[FreeNova] !n Battle Pass upgraded to ELITE track. Kept your tier; claimed Elite extras from 1.")
}

stock BpApplyTimedBoost(id, Float:multiplier, duration)
{
    if(g_bHasXpBoost[id] && g_iBoostEndTime[id] > get_systime() && g_fXpBoost[id] > multiplier)
        return
    g_fXpBoost[id] = multiplier
    g_iBoostEndTime[id] = get_systime() + duration
    g_bHasXpBoost[id] = true
    SaveXpBoost(id)
}

stock BpTryCosmetic(id, const szLib[], const szPerk[])
{
    #pragma unused id
    if(LibraryExists(szLib, LibType_Library))
        return true
    log_amx("[FreeNova BP] skip perk %s - library missing", szPerk)
    return false
}

stock BpApplyPerkOnly(id, t, bool:skipStackable)
{
    switch(t)
    {
        case 5, 57:
        {
            if(!skipStackable)
                g_iPassJumps[id] = min(2, g_iPassJumps[id] + 1)
        }
        case 10, 35:
        {
            if(!skipStackable)
                g_iPassHp[id] = min(20, g_iPassHp[id] + 2)
        }
        case 15:
            BpApplyTimedBoost(id, 1.5, 1800)
        case 20:
        {
            if(skipStackable)
                return
            new have = max(g_iShopSkillLevel[id][SKILL_FAST_SNIPER], g_iPassSniper[id])
            g_iPassSniper[id] = min(2, have == 0 ? 1 : have + 1)
        }
        case 25:
        {
            if(BpTryCosmetic(id, "freenova_cosmetics", "title"))
                fncosmetics_unlock_title(id, 1)
            if(BpTryCosmetic(id, "weapon_models", "skin_ak_qs"))
                fn_skins_unlock(id, 0, 1)
        }
        case 30:
        {
            if(BpTryCosmetic(id, "freenova_cosmetics", "tag"))
                fncosmetics_grant_tag_license(id)
        }
        case 40:
        {
            if(BpTryCosmetic(id, "freenova_cosmetics", "spawn"))
                fncosmetics_unlock_spawn(id, 3)
        }
        case 45:
            BpApplyTimedBoost(id, 2.0, 1800)
        case 48:
        {
            if(BpTryCosmetic(id, "freenova_cosmetics", "chat_color"))
                fncosmetics_grant_chat_color(id)
            if(g_iShopSkillLevel[id][SKILL_CHAT_COLOR] < 1)
            {
                g_iShopSkillLevel[id][SKILL_CHAT_COLOR] = 1
                SaveShopData(id)
            }
        }
        case 50:
        {
            if(BpTryCosmetic(id, "weapon_models", "skin_flip"))
                fn_skins_unlock(id, 4, 1)
            if(BpTryCosmetic(id, "weapon_models", "skin_awp_redline"))
                fn_skins_unlock(id, 3, 1)
        }
        case 52:
        {
            if(BpTryCosmetic(id, "weapon_models", "model_legend"))
            {
                fn_models_unlock(id, "legend_ct")
                fn_models_unlock(id, "legend_t")
            }
        }
        case 56:
        {
            BpGrantLaneExclusives(id, g_iPremiumLane[id])
        }
        case 54:
        {
            if(!skipStackable)
                g_iPassChute[id] = 1
        }
        case 55:
        {
            if(BpTryCosmetic(id, "freenova_cosmetics", "title"))
                fncosmetics_unlock_title(id, 11)
        }
        case 58:
        {
            if(BpTryCosmetic(id, "freenova_cosmetics", "spawn"))
                fncosmetics_unlock_spawn(id, 5)
        }
        case 59:
        {
            if(skipStackable)
                return
            new have = max(g_iShopSkillLevel[id][SKILL_LASTSTAND], g_iPassLaststand[id])
            g_iPassLaststand[id] = min(2, have == 0 ? 1 : have + 1)
        }
        case 60:
        {
            if(BpTryCosmetic(id, "freenova_cosmetics", "title"))
                fncosmetics_unlock_title(id, 6)
        }
    }
}

stock BpApplyPreviewPremium(id, tier)
{
    switch (tier)
    {
        case 4:
        {
            if (BpTryCosmetic(id, "freenova_cosmetics", "chat_color"))
                fncosmetics_grant_chat_color(id)
        }
        case 8:
        {
            if (BpTryCosmetic(id, "freenova_cosmetics", "tag"))
                fncosmetics_grant_tag_license(id)
        }
        case 12:
        {
            if (BpTryCosmetic(id, "freenova_cosmetics", "spawn"))
                fncosmetics_unlock_spawn(id, 1)
        }
        case 16:
        {
            if (BpTryCosmetic(id, "weapon_models", "skin_ak"))
                fn_skins_unlock(id, 0, 1)
        }
        case 20:
        {
            if (BpTryCosmetic(id, "freenova_cosmetics", "spawn"))
                fncosmetics_unlock_spawn(id, 2)
        }
        case 24:
        {
            if (BpTryCosmetic(id, "weapon_models", "skin_knife"))
                fn_skins_unlock(id, 4, 1)
        }
        case 28:
        {
            if (BpTryCosmetic(id, "weapon_models", "model_legend"))
            {
                fn_models_unlock(id, "legend_ct")
                fn_models_unlock(id, "legend_t")
            }
        }
        case 32:
        {
            if (BpTryCosmetic(id, "freenova_cosmetics", "spawn"))
                fncosmetics_unlock_spawn(id, 3)
        }
        case 36:
        {
            if (BpTryCosmetic(id, "freenova_cosmetics", "title"))
                fncosmetics_unlock_title(id, 1)
        }
        case 40:
        {
            if (BpTryCosmetic(id, "weapon_models", "skin_m4"))
                fn_skins_unlock(id, 1, 1)
        }
        case 44:
        {
            if (BpTryCosmetic(id, "weapon_models", "skin_awp"))
                fn_skins_unlock(id, 3, 1)
        }
        case 48:
        {
            if (BpTryCosmetic(id, "freenova_cosmetics", "title"))
                fncosmetics_unlock_title(id, 11)
        }
        case 52:
        {
            if (BpTryCosmetic(id, "weapon_models", "skin_knife"))
                fn_skins_unlock(id, 4, 1)
        }
        case 56:
        {
            if (BpTryCosmetic(id, "weapon_models", "model_legend"))
            {
                fn_models_unlock(id, "legend_ct")
                fn_models_unlock(id, "legend_t")
            }
        }
        case 60:
        {
            if (BpTryCosmetic(id, "freenova_cosmetics", "title"))
                fncosmetics_unlock_title(id, 6)
        }
    }
}

stock BpGrantPremium(id, t)
{
    new lane = g_iPremiumLane[id]
    if(lane < 1)
        lane = 1
    new extra = BpPremiumExtraCoinsLane(t, lane)
    if(extra > 0)
    {
        g_iCoins[id] += extra
        SaveCoins(id)
        client_printcolor(id, "!g[FreeNova] !n Premium tier %d! +!g%d Coins !n", t, extra)
    }
    BpApplyPerkOnly(id, t, false)
    BpApplyPreviewPremium(id, t)
    if (t == 60)
    {
        g_iCoins[id] += 5000
        SaveCoins(id)
        client_printcolor(id, "[FreeNova] Battle Pass premium tier 60: +5,000 Coins.")
    }
    if(t == 56)
        BpGrantLaneExclusives(id, lane)
    BpMarkClaimed(id, t, 1, lane)
}

// Grant lane-exclusive unique skills due at (lane, tier). Idempotent:
// a skill is only ever raised, never lowered.
stock BpGrantLaneSkills(id, lane, tier)
{
    if (!is_user_connected(id) || is_user_bot(id) || lane < 0 || lane > 3)
        return
    if (tier < 1 || tier > MAX_LEVELS)
        return
    new bool:bChanged = false
    for (new r = 0; r < sizeof(g_iLaneSkillUnlock); r++)
    {
        if (g_iLaneSkillUnlock[r][0] != lane || g_iLaneSkillUnlock[r][2] != tier)
            continue
        new skill = g_iLaneSkillUnlock[r][1]
        new stage = g_iLaneSkillUnlock[r][3]
        if (skill < 0 || skill >= SKILL_COUNT || stage < 1)
            continue
        if (g_iShopSkillLevel[id][skill] >= stage)
            continue
        g_iShopSkillLevel[id][skill] = stage
        bChanged = true
        client_printcolor(id, "[FreeNova] %s track Tier %d: %s unlocked!", g_szLaneNames[lane], tier, g_szSkillNames[skill])
        BpMarkClaimed(id, tier, (lane == 0) ? 0 : 1, lane)
    }
    if (bChanged)
    {
        SaveShopData(id)
        RebuildPlayerState(id, true)
    }
}

stock BpGrantFreeTrack(id, tier)
{
    if (!is_user_connected(id) || is_user_bot(id) || tier < 1 || tier > MAX_LEVELS)
        return

    new bool:bSkill = false
    new bool:bStat = false
    new iHp = 0, iArmor = 0

    // Free-track skill milestones from the approved 60-tier table.
    switch (tier)
    {
        case 6:  bSkill = BpSetFreeSkill(id, SKILL_NIMBLE, 1)
        case 10: bSkill = BpSetFreeSkill(id, SKILL_PARACHUTE, 1)
        case 12: bSkill = BpSetFreeSkill(id, SKILL_MULTI_JUMP, 1)
        case 20: bSkill = BpSetFreeSkill(id, SKILL_NIMBLE, 2)
        case 22: bSkill = BpSetFreeSkill(id, SKILL_VAMPIRE, 1)
        case 24: bSkill = BpSetFreeSkill(id, SKILL_FEATHERFALL, 1)
        case 26: bSkill = BpSetFreeSkill(id, SKILL_FAST_SNIPER, 1)
        case 28: bSkill = BpSetFreeSkill(id, SKILL_HEALTHNADE, 1)
        case 30: bSkill = BpSetFreeSkill(id, SKILL_REVIVE, 1)
        case 32: bSkill = BpSetFreeSkill(id, SKILL_LASTSTAND, 1)
        case 34: bSkill = BpSetFreeSkill(id, SKILL_AWP_UNLOCK, 1)
        case 36: bSkill = BpSetFreeSkill(id, SKILL_CHAT_COLOR, 1)
        case 40: bSkill = BpSetFreeSkill(id, SKILL_NIMBLE, 3)
        case 41: bSkill = BpSetFreeSkill(id, SKILL_VAMPIRE, 2)
        case 42: bSkill = BpSetFreeSkill(id, SKILL_FEATHERFALL, 2)
        case 43: bSkill = BpSetFreeSkill(id, SKILL_FAST_SNIPER, 2)
        case 44: bSkill = BpSetFreeSkill(id, SKILL_HEALTHNADE, 2)
        case 45: bSkill = BpSetFreeSkill(id, SKILL_REVIVE, 2)
        case 46: bSkill = BpSetFreeSkill(id, SKILL_LASTSTAND, 2)
        case 47: bSkill = BpSetFreeSkill(id, SKILL_MULTI_JUMP, 2)
        case 51: bSkill = BpSetFreeSkill(id, SKILL_VAMPIRE, 3)
        case 52: bSkill = BpSetFreeSkill(id, SKILL_FEATHERFALL, 3)
        case 53: bSkill = BpSetFreeSkill(id, SKILL_MULTI_JUMP, 3)
    }

    // Free-track stat milestones are cumulative maxima.
    switch (tier)
    {
        case 2:  iHp = 1
        case 4:  iArmor = 2
        case 16: iHp = 2
        case 18: iArmor = 3
        case 38: iHp = 4
        case 39: iArmor = 6
        case 48: iHp = 6
        case 49: iArmor = 9
        case 54: iHp = 7
        case 55: iArmor = 11
        case 57: iHp = 8
        case 58: iArmor = 13
    }

    if (iHp > g_iPassHp[id])
    {
        g_iPassHp[id] = iHp
        bStat = true
    }
    if (iArmor > g_iPassArmor[id])
    {
        g_iPassArmor[id] = iArmor
        bStat = true
    }

    if (bSkill)
        SaveShopData(id)
    if (bStat)
        SaveBpBoost(id)
    if (bStat)
    {
        client_printcolor(id, "[FreeNova] Battle Pass tier %d: free track stats applied.", tier)
        RebuildPlayerState(id, true)
    }
    else if (bSkill)
    {
        RebuildPlayerState(id, true)
    }
}

stock bool:BpSetFreeSkill(id, skill, stage)
{
    if (skill < 0 || skill >= SKILL_COUNT || stage < 1)
        return false
    if (g_iShopSkillLevel[id][skill] >= stage)
        return false
    g_iShopSkillLevel[id][skill] = stage
    client_printcolor(id, "[FreeNova] Battle Pass free track: %s unlocked!", g_szSkillNames[skill])
    return true
}

stock bool:BpHasPassBoosts(id)
{
    return bool:(g_iPassHp[id] || g_iPassArmor[id] || g_iPassJumps[id] || g_iPassSniper[id] || g_iPassLaststand[id] || g_iPassChute[id])
}

stock BpCatchUpPremium(id, iTo)
{
    new iMax = min(iTo, MAX_LEVELS)
    new bool:bSkipStackable = BpHasPassBoosts(id)
    for(new t = 1; t <= iMax; t++)
    {
        new lane = g_iPremiumLane[id]
        if(lane < 1) lane = 1
        new extra = BpPremiumExtraCoinsLane(t, lane)
        if(extra > 0)
        {
            g_iCoins[id] += extra
            SaveCoins(id)
            client_printcolor(id, "!g[FreeNova] !n Premium tier %d! +!g%d Coins !n", t, extra)
            BpMarkClaimed(id, t, 1, lane)
        }
        BpApplyPerkOnly(id, t, bSkipStackable)
        BpApplyPreviewPremium(id, t)
        if (t == 60)
        {
            g_iCoins[id] += 5000
            SaveCoins(id)
        }
    }
}

stock BpBackfillPremium(id, milestone)
{
    new iMax = min(milestone, MAX_LEVELS)
    for(new t = 1; t <= iMax; t++)
    {
        BpApplyPerkOnly(id, t, false)
        BpApplyPreviewPremium(id, t)
        if (t == 60)
        {
            g_iCoins[id] += 5000
            SaveCoins(id)
        }
    }
}

// Server console: bp_armor_probe <player> <bonus> - run the SHIPPED spawn-armour
// rule for a bonus an operator chooses, print what it did, and put the player's
// own bonus back. The perk is level-gated (max ~28 today), so without this a
// value above the 100 cap - the overflow conversion - could only be reached by
// waiting for a future config. Admin-only, console or rcon.
public Cmd_ArmorProbe(id, level, cid)
{
    if(!cmd_access(id, level, cid, 3))
        return PLUGIN_HANDLED

    new szArg[32]
    read_argv(1, szArg, charsmax(szArg))
    new iTarget = cmd_target(id, szArg, CMDTARGET_ALLOW_SELF)
    if(!iTarget)
        return PLUGIN_HANDLED

    new szBonus[16]
    read_argv(2, szBonus, charsmax(szBonus))
    new iBonus = clamp(str_to_num(szBonus), 0, 500)

    new szName[32]
    get_user_name(iTarget, szName, charsmax(szName))

    // Swap the derived bonus in, run the shipped function unchanged, swap back.
    new iSaved = g_iArmorBonus[iTarget]
    g_iArmorBonus[iTarget] = iBonus
    new iHp = BpApplySpawnArmour(iTarget)
    g_iArmorBonus[iTarget] = iSaved

    new CsArmorType:type
    new iAp = cs_get_user_armor(iTarget, type)
    new szOut[192]
    formatex(szOut, charsmax(szOut),
        "bonus=%d -> armour=%d helmet=%s, +%d HP (ceiling %d HP, 2 AP = 1 HP)",
        iBonus, iAp, (type == CS_ARMOR_VESTHELM) ? "yes" : "no", iHp, BP_SPAWN_HP_CEILING)
    console_print(id, "[BP] armour probe %s: %s", szName, szOut)
    log_amx("[BP] armour probe %s (%d): %s", szName, iTarget, szOut)
    return PLUGIN_HANDLED
}

public Cmd_Coins(id)
{
    if(!is_user_connected(id))
        return PLUGIN_HANDLED

    client_printcolor(id, "!g[FreeNova] !n You have %d Coins !n", g_iCoins[id])
    return PLUGIN_HANDLED
}

// ============================================================
// COIN ADMIN COMMANDS
// ============================================================
#define COIN_ACTION_GIVE    0
#define COIN_ACTION_REMOVE  1
    new g_iCoinAdminAction[MAX_PLAYERS + 1]
    new g_iCoinAdminTarget[MAX_PLAYERS + 1]
    new g_iCoinAdminUserid[MAX_PLAYERS + 1]
    new g_szCoinAdminAuth[MAX_PLAYERS + 1][35]

public Cmd_CoinsGive(id)
{
    if(!(get_user_flags(id) & read_flags("a")))
    {
        client_printcolor(id, "!g[FreeNova] !n Admin only.")
        return PLUGIN_HANDLED
    }

    new szArg[32], szAmount[16]
    // Via chat (say /coins_give X 100) argv shifts by one: argv0=say,
    // argv1=/coins_give, argv2=target, argv3=amount. Console form
    // (amx_coins_give X 100) starts at argv1. Detect and compensate.
    new iBase = 1
    new szCmd[32]
    read_argv(0, szCmd, charsmax(szCmd))
    if(equal(szCmd, "say") || equal(szCmd, "say_team"))
    {
        iBase = 2
    }
    read_argv(iBase, szArg, charsmax(szArg))
    read_argv(iBase + 1, szAmount, charsmax(szAmount))

    if(szArg[0] && szAmount[0])
    {
        new target = cmd_target(id, szArg, CMDTARGET_NO_BOTS)
        if(!target)
        {
            client_printcolor(id, "!g[FreeNova] !n Player not found.")
            return PLUGIN_HANDLED
        }

        new amount = str_to_num(szAmount)
        if(amount <= 0)
        {
            client_printcolor(id, "!g[FreeNova] !n Amount must be positive.")
            return PLUGIN_HANDLED
        }

        // BpCreditCoins applies the same 2e9 wallet cap as native_add_coins
        // (:4653): a raw += past the cap wraps negative and the target can
        // then never buy anything. (REVIEW.md §5.2)
        BpCreditCoins(target, amount)

        new name[32], adminName[32]
        get_user_name(target, name, charsmax(name))
        get_user_name(id, adminName, charsmax(adminName))

        client_printcolor(id, "!g[FreeNova] !n Gave %d coins to %s.", amount, name)
        client_printcolor(target, "!g[FreeNova] !n Admin %s gave you %d coins!", adminName, amount)
        return PLUGIN_HANDLED
    }

    g_iCoinAdminAction[id] = COIN_ACTION_GIVE
    ShowCoinPlayerMenu(id)
    return PLUGIN_HANDLED
}

public Cmd_CoinsRemove(id)
{
    if(!(get_user_flags(id) & read_flags("a")))
    {
        client_printcolor(id, "!g[FreeNova] !n Admin only.")
        return PLUGIN_HANDLED
    }

    new szArg[32], szAmount[16]
    // Via chat (say /coins_give X 100) argv shifts by one: argv0=say,
    // argv1=/coins_give, argv2=target, argv3=amount. Console form
    // (amx_coins_give X 100) starts at argv1. Detect and compensate.
    new iBase = 1
    new szCmd[32]
    read_argv(0, szCmd, charsmax(szCmd))
    if(equal(szCmd, "say") || equal(szCmd, "say_team"))
    {
        iBase = 2
    }
    read_argv(iBase, szArg, charsmax(szArg))
    read_argv(iBase + 1, szAmount, charsmax(szAmount))

    if(szArg[0] && szAmount[0])
    {
        new target = cmd_target(id, szArg, CMDTARGET_NO_BOTS)
        if(!target)
        {
            client_printcolor(id, "!g[FreeNova] !n Player not found.")
            return PLUGIN_HANDLED
        }

        new amount = str_to_num(szAmount)
        if(amount <= 0)
        {
            client_printcolor(id, "!g[FreeNova] !n Amount must be positive.")
            return PLUGIN_HANDLED
        }

        g_iCoins[target] -= amount
        if(g_iCoins[target] < 0) g_iCoins[target] = 0
        SaveCoins(target)

        new name[32], adminName[32]
        get_user_name(target, name, charsmax(name))
        get_user_name(id, adminName, charsmax(adminName))

        client_printcolor(id, "!g[FreeNova] !n Removed %d coins from %s.", amount, name)
        client_printcolor(target, "!g[FreeNova] !n Admin %s removed %d coins from you!", adminName, amount)
        return PLUGIN_HANDLED
    }

    g_iCoinAdminAction[id] = COIN_ACTION_REMOVE
    ShowCoinPlayerMenu(id)
    return PLUGIN_HANDLED
}

public Cmd_CoinsMenu(id)
{
    if(!(get_user_flags(id) & read_flags("a")))
    {
        client_printcolor(id, "!g[FreeNova] !n Admin only.")
        return PLUGIN_HANDLED
    }

    new szTitle[64]
    FN_MenuTitle(szTitle, charsmax(szTitle), "Coin Admin")
    new menu = menu_create(szTitle, "CoinMainMenuHandler")
    menu_additem(menu, "\wGive Coins to Player")
    menu_additem(menu, "\wRemove Coins from Player")
    FN_MenuFinish(menu, false)
    menu_display(id, menu, 0)
    return PLUGIN_HANDLED
}

public CoinMainMenuHandler(id, menu, item)
{
    if(item == MENU_EXIT)
    {
        menu_destroy(menu)
        return PLUGIN_HANDLED
    }

    g_iCoinAdminAction[id] = (item == 0) ? COIN_ACTION_GIVE : COIN_ACTION_REMOVE
    ShowCoinPlayerMenu(id)
    menu_destroy(menu)
    return PLUGIN_HANDLED
}

ShowCoinPlayerMenu(id)
{
    new szTitle[64]
    FN_MenuTitle(szTitle, charsmax(szTitle), "Select Player")
    new menu = menu_create(szTitle, "CoinPlayerHandler")
    new players[32], num, name[32], info[8]
    get_players(players, num, "ch")

    for(new i = 0; i < num; i++)
    {
        get_user_name(players[i], name, charsmax(name))
        format(name, charsmax(name), "%s \y[%d coins]", name, g_iCoins[players[i]])
        num_to_str(get_user_userid(players[i]), info, charsmax(info))
        menu_additem(menu, name, info)
    }

    FN_MenuFinish(menu, true)
    menu_display(id, menu, 0)
}

public CoinPlayerHandler(id, menu, item)
{
    if(item == MENU_EXIT || item == MENU_BACK)
    {
        menu_destroy(menu)
        return PLUGIN_HANDLED
    }

    new data[6], szName[32]
    menu_item_getinfo(menu, item, _, data, charsmax(data), szName, charsmax(szName))
    new target = find_player("k", str_to_num(data))

    if(!target || !is_user_connected(target))
    {
        client_printcolor(id, "!g[FreeNova] !n Player disconnected.")
        menu_destroy(menu)
        return PLUGIN_HANDLED
    }

    g_iCoinAdminTarget[id] = target
    g_iCoinAdminUserid[id] = get_user_userid(target)
    get_user_authid(target, g_szCoinAdminAuth[id], charsmax(g_szCoinAdminAuth[]))
    menu_destroy(menu)

    new szAmount[64]
    FN_MenuTitle(szAmount, charsmax(szAmount), "Select Amount")
    new menu2 = menu_create(szAmount, "CoinAmountHandler")
    menu_additem(menu2, "\w+100 coins", "100")
    menu_additem(menu2, "\w+500 coins", "500")
    menu_additem(menu2, "\w+1000 coins", "1000")
    menu_additem(menu2, "\w+5000 coins", "5000")
    menu_additem(menu2, "\w+10000 coins", "10000")
    FN_MenuFinish(menu2, true)
    menu_display(id, menu2, 0)
    return PLUGIN_HANDLED
}

public CoinAmountHandler(id, menu, item)
{
    if(item == MENU_EXIT || item == MENU_BACK)
    {
        menu_destroy(menu)
        return PLUGIN_HANDLED
    }

    new data[16]
    menu_item_getinfo(menu, item, _, data, charsmax(data))
    new amount = str_to_num(data)
    new target = g_iCoinAdminTarget[id]
    new szAuth[35]
    get_user_authid(target, szAuth, charsmax(szAuth))

    if(!is_user_connected(target) || get_user_userid(target) != g_iCoinAdminUserid[id] || !equal(szAuth, g_szCoinAdminAuth[id]))
    {
        client_printcolor(id, "!g[FreeNova] !n Player disconnected.")
        menu_destroy(menu)
        return PLUGIN_HANDLED
    }

    new name[32], adminName[32]
    get_user_name(target, name, charsmax(name))
    get_user_name(id, adminName, charsmax(adminName))

    if(g_iCoinAdminAction[id] == COIN_ACTION_GIVE)
    {
        BpCreditCoins(target, amount)
        client_printcolor(id, "!g[FreeNova] !n Gave %d coins to %s.", amount, name)
        client_printcolor(target, "!g[FreeNova] !n Admin %s gave you %d coins!", adminName, amount)
    }
    else
    {
        g_iCoins[target] -= amount
        if(g_iCoins[target] < 0) g_iCoins[target] = 0
        SaveCoins(target)
        client_printcolor(id, "!g[FreeNova] !n Removed %d coins from %s.", amount, name)
        client_printcolor(target, "!g[FreeNova] !n Admin %s removed %d coins from you!", adminName, amount)
    }

    menu_destroy(menu)
    return PLUGIN_HANDLED
}

// ============================================================
// LEGACY MISSIONS MENU CLUSTER - REMOVED
// ============================================================
// ShowMissionsMenu (fallback body), MissionsMenuHandler, BuildBar,
// ShowDailyDetails, ShowDaily2Details, ShowWeeklyDetails, CheckMark,
// MissionsBackHandler, AchGalleryRow, ShowAchievementsMenu and
// AchievementsBackHandler were unreachable: every entry point was
// guarded by LibraryExists("freenova_missions"/"freenova_achievements"),
// and both libraries are always loaded on the live server (see
// configs/plugins.ini). The local hub is now a thin delegate only.

public Cmd_Missions(id)
{
    if(!is_user_connected(id))
        return PLUGIN_HANDLED
    if(LibraryExists("freenova_missions", LibType_Library))
        return fnmsn_show(id) ? PLUGIN_HANDLED : PLUGIN_HANDLED
    if (FNWeb_OpenPage(id, "missions"))
        return PLUGIN_HANDLED
    return PLUGIN_HANDLED
}

// ShowMissionsMenu removed with the cluster (see note above).

// ============================================================
// PERSISTENCE (nvault + file backup)
// ============================================================
GetVaultKey(id, output[], len, const prefix[])
{
    new authid[40]
    get_user_authid(id, authid, charsmax(authid))

    for(new i = 0; authid[i]; i++)
    {
        if(authid[i] == ':')
            authid[i] = '_'
    }

    // Weekly missions must reset per calendar week - stamp the key with
    // the ISO week number, otherwise counters persist once-ever.
    if(equal(prefix, "weekly"))
    {
        new szWeek[8]
        format_time(szWeek, charsmax(szWeek), "%G-%V")
        formatex(output, len, "%s#%s#%s", prefix, szWeek, authid)
        return
    }

    // Daily missions must reset per calendar day - same stamping pattern,
    // otherwise relogging resets progress (XP farm) or keeps it once-ever.
    if(equal(prefix, "daily") || equal(prefix, "daily2"))
    {
        new szDay[12]
        format_time(szDay, charsmax(szDay), "%Y%m%d")
        formatex(output, len, "%s#%s#%s", prefix, szDay, authid)
        return
    }

    formatex(output, len, "%s#%s", prefix, authid)
}

// ============================================================
// PER-SEASON PREMIUM (2026-10-10)
// S1 (fn_bp_current_season <= 1): legacy lifetime VIP auto-grant, S1
// un-stamped vault keys. Seasons >1: milestone/premium/premlane/bpboost
// cursors live in stamped keys (milestone_s2, ...) so S1 history is never
// overwritten, and premium grants require a store entitlement
// (bpent_s<season> = "<lane> <order>") written via amx_bpent.
// ============================================================
BpCurrentSeason()
{
    new s = get_cvar_num("fn_bp_current_season")
    return s < 1 ? 1 : s
}
// Season-stamped cursor key. S1 returns the legacy un-stamped key.
BpCursorKey(id, output[], len, const base[])
{
    new season = BpCurrentSeason()
    if(season <= 1)
    {
        GetVaultKey(id, output, len, base)
        return
    }
    new stamped[32]
    formatex(stamped, charsmax(stamped), "%s_s%d", base, season)
    GetVaultKey(id, output, len, stamped)
}
// Lane the player is entitled to: store entitlement on S2+, VIP tier on S1.
BpDesiredLane(id)
{
    if(BpCurrentSeason() > 1)
        return clamp(g_iBpSeasonEnt[id], 0, 3)
    return BpVipLane(id)
}
bool:BpPremiumAllowed(id)
{
    if(BpCurrentSeason() <= 1)
        return fnvip_get_tier(id) >= FNVIP_VIP ? true : false
    return g_iBpSeasonEnt[id] > 0 ? true : false
}
LoadBpEntitlement(id)
{
    g_iBpSeasonEnt[id] = 0
    g_szBpEntOrder[id][0] = 0
    new season = BpCurrentSeason()
    if(season <= 1 || g_VaultBP == INVALID_HANDLE)
        return
    new key[80], value[48], auth[40]
    BpSafeAuth(id, auth, charsmax(auth))
    formatex(key, charsmax(key), "bpent_s%d#%s", season, auth)
    if(nvault_get(g_VaultBP, key, value, charsmax(value)))
    {
        new lane[8], order[32]
        parse(value, lane, charsmax(lane), order, charsmax(order))
        g_iBpSeasonEnt[id] = clamp(str_to_num(lane), 0, 3)
        copy(g_szBpEntOrder[id], charsmax(g_szBpEntOrder[]), order)
    }
}
SaveBpEntitlement(id)
{
    new season = BpCurrentSeason()
    if(season <= 1 || g_VaultBP == INVALID_HANDLE)
        return
    new key[80], value[48], auth[40]
    BpSafeAuth(id, auth, charsmax(auth))
    formatex(key, charsmax(key), "bpent_s%d#%s", season, auth)
    formatex(value, charsmax(value), "%d %s", g_iBpSeasonEnt[id], g_szBpEntOrder[id])
    nvault_set(g_VaultBP, key, value)
}
// Store/RCON hook: amx_bpent <steamid> <season> <lane 1-3> <order-id>
public Cmd_BpEntitlement(id)
{
    if(!(get_user_flags(id) & read_flags("a")))
    {
        client_printcolor(id, "!g[FreeNova] !n Admin only.")
        return PLUGIN_HANDLED
    }
    new szTarget[40], szSeason[8], szLane[8], szOrder[32]
    read_argv(1, szTarget, charsmax(szTarget))
    read_argv(2, szSeason, charsmax(szSeason))
    read_argv(3, szLane, charsmax(szLane))
    read_argv(4, szOrder, charsmax(szOrder))
    new iSeason = str_to_num(szSeason)
    new iLane = clamp(str_to_num(szLane), 1, 3)
    if(!szTarget[0] || iSeason < 2 || !szOrder[0])
    {
        console_print(id, "Usage: amx_bpent <steamid> <season>=2 <lane 1-3> <order-id>")
        return PLUGIN_HANDLED
    }
    new target = 0
    new iPlayers[32], iNum
    get_players(iPlayers, iNum, "ch")
    for(new i = 0; i < iNum; i++)
    {
        new szAuth[40]
        get_user_authid(iPlayers[i], szAuth, charsmax(szAuth))
        if(equali(szAuth, szTarget))
        {
            target = iPlayers[i]
            break
        }
    }
    if(!target)
    {
        console_print(id, "[FreeNova] amx_bpent: player %s not online (grant on next join still needs this command).", szTarget)
        return PLUGIN_HANDLED
    }
    // Record entitlement for its season (vault key is season-stamped).
    new key[80], value[48], auth[40]
    BpSafeAuth(target, auth, charsmax(auth))
    formatex(key, charsmax(key), "bpent_s%d#%s", iSeason, auth)
    formatex(value, charsmax(value), "%d %s", iLane, szOrder)
    if(g_VaultBP != INVALID_HANDLE)
        nvault_set(g_VaultBP, key, value)
    log_amx("[FreeNova] amx_bpent: %s granted season %d lane %d (order %s) by admin %d", szTarget, iSeason, iLane, szOrder, id)
    // Apply immediately when the grant is for the running season.
    if(iSeason == BpCurrentSeason() && g_bDataLoaded[target])
    {
        g_iBpSeasonEnt[target] = iLane
        copy(g_szBpEntOrder[target], charsmax(g_szBpEntOrder[]), szOrder)
        if(g_iPremiumLane[target] < iLane)
            g_iPremiumLane[target] = iLane
        if(g_iPremiumPaid[target] == 0 && g_iMilestonePaid[target] > 0)
        {
            BpCatchUpPremium(target, g_iMilestonePaid[target])
            g_iPremiumPaid[target] = g_iMilestonePaid[target]
        }
        new iPayTo = g_iMilestonePaid[target]
        if(iPayTo > MAX_LEVELS) iPayTo = MAX_LEVELS
        if(iPayTo > g_iPremiumPaid[target])
        {
            for(new t = g_iPremiumPaid[target] + 1; t <= iPayTo; t++)
                BpGrantPremium(target, t)
            g_iPremiumPaid[target] = iPayTo
        }
        SavePremiumPaid(target)
        SavePremiumLane(target)
        SaveBpBoost(target)
        SaveBpEntitlement(target)
        RebuildPlayerState(target, true)
        client_printcolor(target, "!g[FreeNova] !n Season %d Premium (lane %d) activated. Enjoy the premium track!", iSeason, iLane)
    }
    console_print(id, "[FreeNova] amx_bpent: recorded.")
    return PLUGIN_HANDLED
}

// Reload RAM from today's/this week's stamped keys when the calendar
// rolls over mid-session. Must run BEFORE Task_AutoSave writes, or
// yesterday's counters land in today's key.

// Intentionally a no-op. nvault_prune is timestamp-range, not key-prefix:
// it would delete coins/shop/achievements/milestone keys of anyone absent
// for more than a week. Stamped daily/weekly keys are simply never read
// after their day/week ends; they do not need a sweep.
WeeklyVaultPrune()
{
}

// Get steamid with colons for filename (e.g. STEAM_0:0:12345)
GetSteamIdFile(id, output[], len)
{
    new authid[40]
    get_user_authid(id, authid, charsmax(authid))
    // Replace : with _ for filename
    for(new i = 0; authid[i]; i++)
    {
        if(authid[i] == ':')
            authid[i] = '_'
    }
    formatex(output, len, "%s.dat", authid)
}

GetPlayerFilePath(id, output[], len)
{
    new fileid[40]
    GetSteamIdFile(id, fileid, charsmax(fileid))
    formatex(output, len, "%s/%s", g_szDataDir, fileid)
}

// File-based save: writes ALL player data to a text file
SaveToFile(id)
{
    if(!is_user_connected(id))
        return

    new filepath[256]
    GetPlayerFilePath(id, filepath, charsmax(filepath))

    new f = fopen(filepath, "wt")
    if(!f)
    {
        log_amx("!g[FreeNova] !n WARNING: Cannot write player file: %s", filepath)
        return
    }

    // Write coins
    fprintf(f, "coins %d^n", g_iCoins[id])

    // Write shop skills (13 multi-stage skills)
    fprintf(f, "shop %d %d %d %d %d %d %d %d %d %d %d %d %d^n",
        g_iShopSkillLevel[id][0],
        g_iShopSkillLevel[id][1],
        g_iShopSkillLevel[id][2],
        g_iShopSkillLevel[id][3],
        g_iShopSkillLevel[id][4],
        g_iShopSkillLevel[id][5],
        g_iShopSkillLevel[id][6],
        g_iShopSkillLevel[id][7],
        g_iShopSkillLevel[id][8],
        g_iShopSkillLevel[id][9],
        g_iShopSkillLevel[id][10],
        g_iShopSkillLevel[id][11],
        g_iShopSkillLevel[id][12])

    // Write prestige
    fprintf(f, "prestige %d^n", g_iPrestige[id])

    // Legacy "weekly ..." line removed: weekly mission progress is owned
    // by freenova_missions (weekly# vault key), not persisted here.
    // Old files still carry the line; LoadFromFile ignores it below.

    // Write XP boost (save multiplier as integer * 10: 1.5 = 15, 2.0 = 20, 3.0 = 30)
    fprintf(f, "xpboost %d %d %d^n",
        _:g_bHasXpBoost[id],
        g_iBoostEndTime[id],
        floatround(g_fXpBoost[id] * 10.0))

    // Write season premium entitlement (S2+ store purchase; S1 writes lane 0).
    // Old files without this line load lane 0 - identical to a fresh season.
    fprintf(f, "bpent %d %d %s^n",
        BpCurrentSeason(),
        g_iBpSeasonEnt[id],
        g_szBpEntOrder[id])

    fclose(f)
}

// File-based load: reads ALL player data from a text file
LoadFromFile(id)
{
    new filepath[256]
    GetPlayerFilePath(id, filepath, charsmax(filepath))

    new f = fopen(filepath, "rt")
    if(!f)
        return false

    new line[256], key[16], val1[16], val2[16], val3[16], val4[16], val5[16], val6[16], val7[16]

    while(!feof(f))
    {
        fgets(f, line, charsmax(line))
        trim(line)

        if(line[0] == 0 || line[0] == '#' || line[0] == ';')
            continue

        parse(line, key, charsmax(key), val1, charsmax(val1), val2, charsmax(val2),
            val3, charsmax(val3), val4, charsmax(val4), val5, charsmax(val5), val6, charsmax(val6),
            val7, charsmax(val7))

        if(equal(key, "coins"))
        {
            g_iCoins[id] = str_to_num(val1)
        }
        else if(equal(key, "shop"))
        {
            new part[8], rest[128]
            copy(rest, charsmax(rest), line[5])
            trim(rest)
            for(new s = 0; s < SKILL_COUNT; s++)
            {
                if(!rest[0]) break
                strtok(rest, part, charsmax(part), rest, charsmax(rest), ' ')
                g_iShopSkillLevel[id][s] = clamp(str_to_num(part), 0, g_iSkillMaxStage[s])
            }
        }
        else if(equal(key, "prestige"))
        {
            g_iPrestige[id] = str_to_num(val1)
        }
        else if(equal(key, "weekly"))
        {
            // Legacy line - weekly mission progress moved to
            // freenova_missions (weekly# vault key). Accepted and
            // ignored so old data files still parse cleanly.
        }
        else if(equal(key, "xpboost"))
        {
            g_bHasXpBoost[id] = bool:str_to_num(val1)
            g_iBoostEndTime[id] = str_to_num(val2)
            new iMult = str_to_num(val3)
            g_fXpBoost[id] = (iMult > 0) ? float(iMult) / 10.0 : 1.0
            if(g_bHasXpBoost[id] && g_iBoostEndTime[id] > 0)
            {
                if(get_systime() >= g_iBoostEndTime[id])
                {
                    g_bHasXpBoost[id] = false
                    g_fXpBoost[id] = 1.0
                    g_iBoostEndTime[id] = 0
                }
            }
        }
        else if(equal(key, "bpent"))
        {
            // bpent <season> <lane> <order>: season-stamped store entitlement.
            // Applies only when the file season is the running season (S2+);
            // S1 files predate this line and keep the legacy VIP auto-grant.
            new iFileSeason = str_to_num(val1)
            if(iFileSeason > 1 && iFileSeason == BpCurrentSeason())
            {
                g_iBpSeasonEnt[id] = clamp(str_to_num(val2), 0, 3)
                copy(g_szBpEntOrder[id], charsmax(g_szBpEntOrder[]), val3)
            }
        }
        else if(equal(key, "viptrial"))
        {
            // Legacy line - VIP trials moved to the freenova_vip core.
            // Accepted and ignored so old data files parse cleanly.
        }
    }

    fclose(f)
    return true
}

LoadPrestige(id)
{
    if(g_VaultBP != INVALID_HANDLE)
    {
        new key[64]
        GetVaultKey(id, key, charsmax(key), "prestige")
        new value[16]
        if(nvault_get(g_VaultBP, key, value, charsmax(value)))
        {
            g_iPrestige[id] = str_to_num(value)
            return
        }
    }
    // Fallback: try file
    LoadFromFile(id)
}

SavePrestige(id)
{
    if(g_VaultBP != INVALID_HANDLE)
    {
        new key[64], value[16]
        GetVaultKey(id, key, charsmax(key), "prestige")
        formatex(value, charsmax(value), "%d", g_iPrestige[id])
        nvault_set(g_VaultBP, key, value)
    }
    // Always save to file as backup
    SaveToFile(id)
}

LoadCoins(id)
{
    new bool:loaded = false

    // Try nvault first
    if(g_VaultBP != INVALID_HANDLE)
    {
        new key[64]
        GetVaultKey(id, key, charsmax(key), "coins")
        new value[16]
        if(nvault_get(g_VaultBP, key, value, charsmax(value)))
        {
            g_iCoins[id] = str_to_num(value)
            loaded = true
            log_amx("!g[FreeNova] !n Loaded %d coins for player %d (nvault)", g_iCoins[id], id)
        }
    }

    // Fallback to file if nvault failed
    if(!loaded)
    {
        if(LoadFromFile(id))
        {
            log_amx("!g[FreeNova] !n Loaded coins from FILE for player %d: %d", id, g_iCoins[id])
        }
        else
        {
            log_amx("!g[FreeNova] !n No saved data found for player %d - starting fresh", id)
        }
    }
}

SaveCoins(id)
{
    // Save to nvault
    if(g_VaultBP != INVALID_HANDLE)
    {
        new key[64], value[16]
        GetVaultKey(id, key, charsmax(key), "coins")
        formatex(value, charsmax(value), "%d", g_iCoins[id])
        new result = nvault_set(g_VaultBP, key, value)
        if(!result)
            log_amx("!g[FreeNova] !n WARNING: nvault_set failed for coins key=%s", key)
    }

    // ALWAYS save to file as backup (file is the real safety net)
    SaveToFile(id)
}

LoadShopData(id)
{
    new bool:loaded = false

    // Try nvault first
    if(g_VaultBP != INVALID_HANDLE)
    {
        new key[64], value[128]
        GetVaultKey(id, key, charsmax(key), "shop")
        if(nvault_get(g_VaultBP, key, value, charsmax(value)))
        {
            new part[8], left[128]
            copy(left, charsmax(left), value)
            trim(left)
            for(new i = 0; i < SKILL_COUNT; i++)
            {
                if(!left[0]) break
                strtok(left, part, charsmax(part), left, charsmax(left), ' ')
                g_iShopSkillLevel[id][i] = clamp(str_to_num(part), 0, g_iSkillMaxStage[i])
            }
            loaded = true
            log_amx("!g[FreeNova] !n Loaded shop data for player %d (nvault): %s", id, value)
        }
    }

    // Fallback to file if nvault failed
    if(!loaded)
    {
        if(LoadFromFile(id))
        {
            log_amx("!g[FreeNova] !n Loaded shop data from FILE for player %d", id)
        }
        else
        {
            log_amx("!g[FreeNova] !n No shop data found for player %d", id)
        }
    }
}

SaveShopData(id)
{
    // Save to nvault
    if(g_VaultBP != INVALID_HANDLE)
    {
        new key[64], value[160]
        GetVaultKey(id, key, charsmax(key), "shop")
        formatex(value, charsmax(value), "%d %d %d %d %d %d %d %d %d %d %d %d %d",
            g_iShopSkillLevel[id][0],
            g_iShopSkillLevel[id][1],
            g_iShopSkillLevel[id][2],
            g_iShopSkillLevel[id][3],
            g_iShopSkillLevel[id][4],
            g_iShopSkillLevel[id][5],
            g_iShopSkillLevel[id][6],
            g_iShopSkillLevel[id][7],
            g_iShopSkillLevel[id][8],
            g_iShopSkillLevel[id][9],
            g_iShopSkillLevel[id][10],
            g_iShopSkillLevel[id][11],
            g_iShopSkillLevel[id][12])
        new result = nvault_set(g_VaultBP, key, value)
        if(!result)
            log_amx("!g[FreeNova] !n WARNING: nvault_set failed for shop key=%s", key)
    }

    // ALWAYS save to file as backup
    SaveToFile(id)
}



LoadMilestonePaid(id)
{
    if(g_VaultBP != INVALID_HANDLE)
    {
        new key[64], value[16]
        BpCursorKey(id, key, charsmax(key), "milestone")
        if(nvault_get(g_VaultBP, key, value, charsmax(value)))
        {
            g_iMilestonePaid[id] = str_to_num(value)
            return
        }
    }
    g_iMilestonePaid[id] = 0
}

SaveMilestonePaid(id)
{
    if(g_VaultBP != INVALID_HANDLE)
    {
        new key[64], value[16]
        BpCursorKey(id, key, charsmax(key), "milestone")
        formatex(value, charsmax(value), "%d", g_iMilestonePaid[id])
        nvault_set(g_VaultBP, key, value)
    }
}

// ============================================================
// BATTLEPASS XP / TIER LEDGER (curve, persistence, grant path)
// ============================================================
// Flat curve, identical to the panel's `reward_track.xp_per_tier`
// (web-panel/src/bp_track.js xpPerTier, default 1000): tier N covers
// [(N-1)*per, N*per), tier 1 starts at 0. A player with 0 BP XP therefore
// reads "tier 1, empty progress" on the HUD, in /bp and on the web panel -
// never NaN, never a rank-derived tier.
stock BpXpPerTier()
{
    new i = get_cvar_num("fn_bp_xp_per_tier")
    return (i > 0) ? i : 1000
}

stock BpTierThreshold(iTier)
{
    if (iTier <= 1)
        return 0
    if (iTier > MAX_LEVELS)
        iTier = MAX_LEVELS
    return (iTier - 1) * BpXpPerTier()
}

stock BpMaxXp()
{
    return MAX_LEVELS * BpXpPerTier()
}

stock BpTierFromXp(iXp)
{
    if (iXp < 0)
        iXp = 0
    new iTier = 1 + (iXp / BpXpPerTier())
    return (iTier > MAX_LEVELS) ? MAX_LEVELS : iTier
}

// 0 while the row is still loading: that is the documented native contract
// (menabp_get_tier "or 0 if not loaded") that HUD/sync/panel gate on.
stock BpGetTier(id)
{
    if (!BpValidId(id) || !g_bBpXpLoaded[id])
        return 0
    new iTier = g_iBpTier[id]
    if (iTier < 1)
        iTier = 1
    return (iTier > MAX_LEVELS) ? MAX_LEVELS : iTier
}

stock BpGetXp(id)
{
    if (!BpValidId(id) || !g_bBpXpLoaded[id])
        return 0
    return (g_iBpXp[id] < 0) ? 0 : g_iBpXp[id]
}

// Shop XP boost, pruned on read (same expiry rule as crxranks_user_receive_xp).
stock Float:BpXpBoostMult(id)
{
    if (!g_bHasXpBoost[id])
        return 1.0
    if (g_iBoostEndTime[id] > 0 && get_systime() >= g_iBoostEndTime[id])
    {
        g_bHasXpBoost[id] = false
        g_fXpBoost[id] = 1.0
        g_iBoostEndTime[id] = 0
        return 1.0
    }
    return (g_fXpBoost[id] > 0.0) ? g_fXpBoost[id] : 1.0
}

// No seeding: a pid with no `bpxp` key starts at 0 BP XP / tier 1. Old rank XP
// is never copied in, so an existing player keeps rank progress and begins BP
// progress from zero.
LoadBpXp(id)
{
    g_iBpXp[id] = 0
    g_iBpTier[id] = 1
    g_bBpXpLoaded[id] = true
    if (g_VaultBP == INVALID_HANDLE)
        return
    new key[64], value[16]
    BpCursorKey(id, key, charsmax(key), "bpxp")
    if (nvault_get(g_VaultBP, key, value, charsmax(value)))
        g_iBpXp[id] = clamp(str_to_num(value), 0, BpMaxXp())
    g_iBpTier[id] = BpTierFromXp(g_iBpXp[id])
}

SaveBpXp(id)
{
    if (g_VaultBP == INVALID_HANDLE || !g_bBpXpLoaded[id])
        return
    new key[64], value[16]
    BpCursorKey(id, key, charsmax(key), "bpxp")
    formatex(value, charsmax(value), "%d", g_iBpXp[id])
    if (!nvault_set(g_VaultBP, key, value))
        log_amx("[FreeNova] WARNING: nvault_set failed for BP XP key=%s", key)
}

// THE BP XP grant path. Every multiplier lives here and only here, so
// menabp_add_xp_once (which calls this and then records the award id) can never
// multiply twice, and a replayed award id never reaches it at all. Rank XP is
// never touched: no crxranks_give_user_xp call exists in this function.
BpAddXp(id, amount)
{
    if (!BpValidId(id) || !g_bDataLoaded[id] || !g_bBpXpLoaded[id] || amount <= 0)
        return 0

    new iMax = BpMaxXp()
    if (g_iBpXp[id] >= iMax)
        return 0

    // Shop XP boost * VIP BP bonus. fnvip_get_bp_multiplier had zero call sites
    // before REVIEW §2.4 H1; it returns 1.0 for a non-VIP and when the VIP core
    // is absent, so this stays a no-op for everyone else.
    new Float:fMult = BpXpBoostMult(id) * fnvip_get_bp_multiplier(id)
    new iAdd = floatround(float(amount) * fMult)
    if (iAdd < 1)
        iAdd = 1

    new iOldXp = g_iBpXp[id]
    new iNewXp = iOldXp + iAdd
    if (iNewXp > iMax)
        iNewXp = iMax
    if (iNewXp <= iOldXp)
        return 0

    g_iBpXp[id] = iNewXp
    new iOldTier = g_iBpTier[id]
    g_iBpTier[id] = BpTierFromXp(g_iBpXp[id])
    SaveBpXp(id)
    if (g_iBpTier[id] > iOldTier)
        BpTierUp(id, iOldTier, g_iBpTier[id])
    return iNewXp - iOldXp
}

// A BP tier-up announces only. The claim cursors (g_iMilestonePaid /
// g_iPremiumPaid) are rank-level driven and pay once per tier there; paying
// them again from BP XP would double every tier reward, so this build keeps the
// BP ledger off the reward cursors (operator decision, REVIEW §9d).
BpTierUp(id, iFrom, iTo)
{
    new szAuth[40]
    BpSafeAuth(id, szAuth, charsmax(szAuth))
    log_amx("[FreeNova] BP TIERUP %s %d -> %d (bp_xp=%d)", szAuth, iFrom, iTo, g_iBpXp[id])
    client_printcolor(id, "!g[FreeNova] !nBattle Pass tier !g%d!n reached (was %d).", iTo, iFrom)
}

BpAddXpOnce(id, amount, const awardId[])
{
    if (!BpValidId(id) || !g_bDataLoaded[id] || !g_bBpXpLoaded[id] || amount <= 0 || !awardId[0])
        return -1
    if (BpAwardExists(id, "xp", awardId))
        return 0
    new iAdded = BpAddXp(id, amount)
    if (iAdded <= 0)
    {
        // At the cap the award is still consumed, otherwise a later season could
        // replay an award that was already earned.
        if (g_iBpXp[id] >= BpMaxXp())
        {
            BpMarkAward(id, "xp", awardId)
            return 0
        }
        return -1
    }
    BpMarkAward(id, "xp", awardId)
    return iAdded
}

LoadPremiumPaid(id)
{
    g_iPremiumPaid[id] = 0
    if(g_VaultBP != INVALID_HANDLE)
    {
        new key[64], value[16]
        BpCursorKey(id, key, charsmax(key), "premium")
        if(nvault_get(g_VaultBP, key, value, charsmax(value)))
            g_iPremiumPaid[id] = str_to_num(value)
    }
}

SavePremiumPaid(id)
{
    if(g_VaultBP != INVALID_HANDLE)
    {
        new key[64], value[16]
        BpCursorKey(id, key, charsmax(key), "premium")
        formatex(value, charsmax(value), "%d", g_iPremiumPaid[id])
        nvault_set(g_VaultBP, key, value)
    }
}

LoadPremiumLane(id)
{
    g_iPremiumLane[id] = 0
    if(g_VaultBP != INVALID_HANDLE)
    {
        new key[64], value[16]
        BpCursorKey(id, key, charsmax(key), "premlane")
        if(nvault_get(g_VaultBP, key, value, charsmax(value)))
            g_iPremiumLane[id] = clamp(str_to_num(value), 0, 3)
    }
}

SavePremiumLane(id)
{
    if(g_VaultBP != INVALID_HANDLE)
    {
        new key[64], value[16]
        BpCursorKey(id, key, charsmax(key), "premlane")
        formatex(value, charsmax(value), "%d", g_iPremiumLane[id])
        nvault_set(g_VaultBP, key, value)
    }
}

LoadBpBoost(id)
{
    g_iPassHp[id] = 0
    g_iPassArmor[id] = 0
    g_iPassJumps[id] = 0
    g_iPassSniper[id] = 0
    g_iPassLaststand[id] = 0
    g_iPassChute[id] = 0
    g_bPassBoostLoaded[id] = false

    if(g_VaultBP == INVALID_HANDLE)
        return

    new key[64], value[64]
    BpCursorKey(id, key, charsmax(key), "bpboost")
    if(!nvault_get(g_VaultBP, key, value, charsmax(value)))
        return

    g_bPassBoostLoaded[id] = true
    new part[16], left[64]
    copy(left, charsmax(left), value)
    strtok(left, part, charsmax(part), left, charsmax(left), ' ')
    g_iPassHp[id] = str_to_num(part)
    strtok(left, part, charsmax(part), left, charsmax(left), ' ')
    g_iPassArmor[id] = str_to_num(part)
    strtok(left, part, charsmax(part), left, charsmax(left), ' ')
    g_iPassJumps[id] = str_to_num(part)
    strtok(left, part, charsmax(part), left, charsmax(left), ' ')
    g_iPassSniper[id] = str_to_num(part)
    strtok(left, part, charsmax(part), left, charsmax(left), ' ')
    g_iPassLaststand[id] = str_to_num(part)
    g_iPassChute[id] = str_to_num(left)
}

SaveBpBoost(id)
{
    if(g_VaultBP != INVALID_HANDLE)
    {
        new key[64], value[64]
        BpCursorKey(id, key, charsmax(key), "bpboost")
        formatex(value, charsmax(value), "%d %d %d %d %d %d",
            g_iPassHp[id], g_iPassArmor[id], g_iPassJumps[id],
            g_iPassSniper[id], g_iPassLaststand[id], g_iPassChute[id])
        nvault_set(g_VaultBP, key, value)
        g_bPassBoostLoaded[id] = true
    }
}

// ============================================================
// XP BOOST VAULT PERSISTENCE (P0 fix: boosts vanished on reconnect
// because the file fallback only ran when the vault lookup missed)
// ============================================================
LoadXpBoost(id)
{
    if(g_VaultBP != INVALID_HANDLE)
    {
        new key[64], value[32]
        GetVaultKey(id, key, charsmax(key), "xpboost")
        if(nvault_get(g_VaultBP, key, value, charsmax(value)))
        {
            new part[16], left[32]
            copy(left, charsmax(left), value)
            strtok(left, part, charsmax(part), left, charsmax(left), ' ')
            g_bHasXpBoost[id] = bool:str_to_num(part)
            strtok(left, part, charsmax(part), left, charsmax(left), ' ')
            g_iBoostEndTime[id] = str_to_num(part)
            strtok(left, part, charsmax(part), left, charsmax(left), ' ')
            new iMult = str_to_num(part)
            g_fXpBoost[id] = (iMult > 0) ? float(iMult) / 10.0 : 1.0

            if(g_bHasXpBoost[id] && g_iBoostEndTime[id] > 0 && get_systime() >= g_iBoostEndTime[id])
            {
                g_bHasXpBoost[id] = false
                g_fXpBoost[id] = 1.0
                g_iBoostEndTime[id] = 0
                nvault_remove(g_VaultBP, key)
            }
            return
        }
    }
    // no vault entry - fall back to the legacy file
    LoadFromFile(id)
}

SaveXpBoost(id)
{
    if(g_VaultBP != INVALID_HANDLE)
    {
        new key[64], value[32]
        GetVaultKey(id, key, charsmax(key), "xpboost")
        formatex(value, charsmax(value), "%d %d %d", _:g_bHasXpBoost[id], g_iBoostEndTime[id], floatround(g_fXpBoost[id] * 10.0))
        nvault_set(g_VaultBP, key, value)
    }
    SaveToFile(id)
}

// ============================================================
// ACHIEVEMENTS PERSISTENCE (lifetime, key = ach#authid)
// ============================================================


// ============================================================
// EXPANSION DAILY MISSIONS PERSISTENCE - REMOVED
// ============================================================
// LoadDaily2/SaveDaily2 were retired stubs ("#pragma unused id" +
// "return" before any body), so the "daily2#" vault key was never
// written from here. freenova_missions owns daily2# now.

// ============================================================
// COIN SHOP SYSTEM
// ============================================================
stock bool:BpShopReady(id)
{
    return is_user_connected(id) && !is_user_bot(id) && g_bDataLoaded[id]
}

stock bool:TrySpendCoins(id, cost)
{
    if(!BpShopReady(id) || cost < 0 || g_iCoins[id] < cost)
        return false
    g_iCoins[id] -= cost
    SaveCoins(id)
    return true
}

stock ShopNeedPrint(id, cost)
{
    client_printcolor(id, "[FreeNova Shop] Not enough coins! Need %d, have %d.", cost, g_iCoins[id])
}

stock BpSkillEffect(skill, stage, szOut[], iLen)
{
    szOut[0] = 0
    switch(skill)
    {
        case SKILL_MULTI_JUMP: formatex(szOut, iLen, "+%d jump", stage)
        case SKILL_SPAWN_HP: formatex(szOut, iLen, "+%d HP", stage * 2)
        case SKILL_SPAWN_ARMOR: formatex(szOut, iLen, "+%d AP", stage * 3)
        case SKILL_VAMPIRE: formatex(szOut, iLen, "+%d HP/kill", stage)
        case SKILL_NIMBLE: formatex(szOut, iLen, "+%d%% spd", stage)
        case SKILL_FEATHERFALL:
        {
            if(stage == 1) copy(szOut, iLen, "15% fall")
            else if(stage == 2) copy(szOut, iLen, "30% fall")
            else copy(szOut, iLen, "45% fall")
        }
        case SKILL_HEALTHNADE:
            copy(szOut, iLen, (stage >= 2) ? "+30 HP nade" : "+15 HP nade")
        case SKILL_FAST_SNIPER:
            copy(szOut, iLen, (stage >= 2) ? "20% bolt" : "10% bolt")
        case SKILL_REVIVE:
            copy(szOut, iLen, (stage >= 2) ? "2.0s revive" : "3.0s revive")
        case SKILL_LASTSTAND:
            copy(szOut, iLen, (stage >= 2) ? "10 HP+sprint" : "5 HP")
        case SKILL_PARACHUTE: copy(szOut, iLen, "glide")
        case SKILL_AWP_UNLOCK: copy(szOut, iLen, "AWP menu")
        case SKILL_CHAT_COLOR: copy(szOut, iLen, "chat color")
    }
}

public Cmd_Shop(id)
{
    if(!BpShopReady(id))
    {
        if(is_user_connected(id) && !is_user_bot(id))
            client_printcolor(id, "[FreeNova Shop] Shop data is still loading.")
        return PLUGIN_HANDLED
    }

    // GoldSrc MOTD cannot buy (no HMAC token). Always open the AMXX shop.
    ShowShopMainMenu(id)
    return PLUGIN_HANDLED
}

ShowShopMainMenu(id)
{
    new coins = g_iCoins[id]
    new szTitle[128]
    FN_MenuTitle(szTitle, charsmax(szTitle), "Shop", coins)

    new menu = menu_create(szTitle, "ShopMainHandler")

    new szItem[96]
    menu_additem(menu, "\wCosmetics", "cosmetics")

    if(g_bHasXpBoost[id] && g_iBoostEndTime[id] > get_systime())
        formatex(szItem, charsmax(szItem), "\yXP boosts \d- %.1fx, %dm left", g_fXpBoost[id], (g_iBoostEndTime[id] - get_systime()) / 60)
    else
        formatex(szItem, charsmax(szItem), "\wXP boosts")
    menu_additem(menu, szItem, "xpboost")

    new iVip = fnvip_get_tier(id)
    if(iVip > 0)
    {
        new szVip[16]
        fnvip_get_tier_name_raw(iVip, szVip, charsmax(szVip))
        formatex(szItem, charsmax(szItem), "\wVIP trials \d- %s active", szVip)
    }
    else
        formatex(szItem, charsmax(szItem), "\wVIP trials")
    menu_additem(menu, szItem, "viptrial")

    menu_additem(menu, is_user_alive(id) ? "\wConsumables" : "\dConsumables", "consumable")
    menu_additem(menu, "\wWeapon skins", "skins")
    menu_additem(menu, "\wPlayer models", "models")
    new iLevel = crxranks_get_user_level(id)
    if(iLevel >= MAX_LEVELS)
        menu_additem(menu, "\yLegend rewards", "legend")
    else
        menu_additem(menu, fmt("\dLegend rewards \d- reach Lv%d", MAX_LEVELS), "legend")

    FN_MenuFinish(menu, true)
    menu_display(id, menu, 0)
    return PLUGIN_HANDLED
}

public ShopMainHandler(id, menu, item)
{
    if(item == MENU_EXIT)
    {
        menu_destroy(menu)
        fn_hub_open(id)
        return PLUGIN_HANDLED
    }

    if(!BpShopReady(id))
    {
        menu_destroy(menu)
        client_printcolor(id, "[FreeNova Shop] Shop data is still loading.")
        return PLUGIN_HANDLED
    }

    new data[16], name[64], access, callback
    menu_item_getinfo(menu, item, access, data, charsmax(data), name, charsmax(name), callback)
    menu_destroy(menu)

    if(equal(data, "skills"))
        ShowBpLiteMenu(id)
    else if(equal(data, "cosmetics"))
        fncosmetics_open_shop(id)
    else if(equal(data, "xpboost"))
        ShowXpBoostShop(id)
    else if(equal(data, "viptrial"))
        ShowVipTrialShop(id)
    else if(equal(data, "consumable"))
        ShowConsumableShop(id)
    else if(equal(data, "skins"))
        skins_open_menu(id)
    else if(equal(data, "models"))
        client_cmd(id, "say /models")
    else if(equal(data, "legend"))
        ShowCosmeticsShop(id)

    return PLUGIN_HANDLED
}

// --- XP BOOST SHOP ---
ShowXpBoostShop(id)
{
    new coins = g_iCoins[id]
    new szXp[64]
    FN_MenuTitle(szXp, charsmax(szXp), "XP boosts", coins)
    new menu = menu_create(szXp, "XpBoostHandler")

    menu_additem(menu, fmt("\w1.5x XP (15 min) %s", coins < 200 ? "\r200c" : "\d200c"), "1")
    menu_additem(menu, fmt("\w2x XP (30 min) %s", coins < 500 ? "\r500c" : "\d500c"), "2")
    menu_additem(menu, fmt("\w3x XP (15 min) %s", coins < 800 ? "\r800c" : "\d800c"), "3")

    FN_MenuFinish(menu, true)
    menu_display(id, menu, 0)
}

public XpBoostHandler(id, menu, item)
{
    if(item == MENU_EXIT)
    {
        menu_destroy(menu)
        ShowShopMainMenu(id)
        return PLUGIN_HANDLED
    }

    new data[8], name[64], access, callback
    menu_item_getinfo(menu, item, access, data, charsmax(data), name, charsmax(name), callback)
    menu_destroy(menu)

    new choice = str_to_num(data)
    new cost = 0, Float:multiplier = 1.0, duration = 0

    switch(choice)
    {
        case 1: { cost = 200; multiplier = 1.5; duration = 900; }
        case 2: { cost = 500; multiplier = 2.0; duration = 1800; }
        case 3: { cost = 800; multiplier = 3.0; duration = 900; }
    }

    if(!BpShopReady(id))
    {
        client_printcolor(id, "[FreeNova Shop] Shop data is still loading.")
        return PLUGIN_HANDLED
    }

    // No-downgrade rule: buying a weaker boost while a stronger one is
    // active would silently overwrite it. Refuse with a hint instead.
    if(g_bHasXpBoost[id] && g_iBoostEndTime[id] > get_systime() && g_fXpBoost[id] > multiplier)
    {
        client_printcolor(id, "[FreeNova Shop] You already have an active !t%.1fx!n boost! Wait for it to end.", g_fXpBoost[id])
        ShowXpBoostShop(id)
        return PLUGIN_HANDLED
    }

    if(!TrySpendCoins(id, cost))
    {
        ShopNeedPrint(id, cost)
        ShowXpBoostShop(id)
        return PLUGIN_HANDLED
    }

    g_fXpBoost[id] = multiplier
    g_iBoostEndTime[id] = get_systime() + duration
    g_bHasXpBoost[id] = true
    SaveXpBoost(id)

    new mins = duration / 60
    client_printcolor(id, "[FreeNova Shop] Activated %.1fx XP for %d minutes! (-%d coins)", multiplier, mins, cost)
    ShowXpBoostShop(id)
    return PLUGIN_HANDLED
}

// --- VIP TRIAL SHOP ---
ShowVipTrialShop(id)
{
    new szVip[64]
    FN_MenuTitle(szVip, charsmax(szVip), "VIP trials", g_iCoins[id])
    new menu = menu_create(szVip, "VipTrialHandler")

    menu_additem(menu, "\wVIP 1 day \d1000c", "1")
    menu_additem(menu, "\wVIP+ 1 day \d2500c", "2")
    menu_additem(menu, "\wELITE 1 day \d4000c", "3")

    FN_MenuFinish(menu, true)
    menu_display(id, menu, 0)
}

public VipTrialHandler(id, menu, item)
{
    if(item == MENU_EXIT)
    {
        menu_destroy(menu)
        ShowShopMainMenu(id)
        return PLUGIN_HANDLED
    }

    new data[8], name[64], access, callback
    menu_item_getinfo(menu, item, access, data, charsmax(data), name, charsmax(name), callback)
    menu_destroy(menu)

    new choice = str_to_num(data)
    new cost = 0, tier = 0, tierName[16] = ""

    switch(choice)
    {
        case 1: { cost = 1000; tier = FNVIP_VIP;    copy(tierName, charsmax(tierName), "VIP"); }
        case 2: { cost = 2500; tier = FNVIP_VIPPLUS; copy(tierName, charsmax(tierName), "VIP+"); }
        case 3: { cost = 4000; tier = FNVIP_ELITE;  copy(tierName, charsmax(tierName), "VIP ELITE"); }
    }

    if(!BpShopReady(id))
    {
        client_printcolor(id, "[FreeNova Shop] Shop data is still loading.")
        return PLUGIN_HANDLED
    }

    if(!TrySpendCoins(id, cost))
    {
        ShopNeedPrint(id, cost)
        ShowVipTrialShop(id)
        return PLUGIN_HANDLED
    }

    // Entitlement grant via the unified VIP core - persisted per-authid
    // with unix expiry (survives reconnect/restart), never downgrades an
    // existing better tier, and expires without stripping static flags.
    fnvip_grant(id, tier, 86400, FNVIP_SRC_SHOP)

    client_printcolor(id, "[FreeNova Shop] Activated %s for 24 hours! (-%d coins)", tierName, cost)
    ShowVipTrialShop(id)
    return PLUGIN_HANDLED
}

// --- CONSUMABLE SHOP ---
ShowConsumableShop(id)
{
    new szCon[64]
    FN_MenuTitle(szCon, charsmax(szCon), "Consumables", g_iCoins[id])
    new menu = menu_create(szCon, "ConsumableHandler")

    if(g_bBoughtHeal[id])
        menu_additem(menu, "\dFull HP + Armor", "1")
    else
        menu_additem(menu, "\wFull HP + Armor \d150c", "1")
    menu_additem(menu, "\wHE + Flashbang + Smoke \d100c", "2")
    menu_additem(menu, "\wDefuse kit (CT) \d50c", "3")

    FN_MenuFinish(menu, true)
    menu_display(id, menu, 0)
}

public ConsumableHandler(id, menu, item)
{
    if(item == MENU_EXIT)
    {
        menu_destroy(menu)
        ShowShopMainMenu(id)
        return PLUGIN_HANDLED
    }

    new data[8], name[64], access, callback
    menu_item_getinfo(menu, item, access, data, charsmax(data), name, charsmax(name), callback)
    menu_destroy(menu)

    if(!BpShopReady(id))
    {
        client_printcolor(id, "[FreeNova Shop] Shop data is still loading.")
        return PLUGIN_HANDLED
    }

    if(!is_user_alive(id))
    {
            client_printcolor(id, "[FreeNova Shop] Must be alive to use consumables.")
            ShowConsumableShop(id)
            return PLUGIN_HANDLED
    }

    new choice = str_to_num(data)
    new cost = 0

    switch(choice)
    {
        case 1:
        {
            cost = 150
            if(g_bBoughtHeal[id])
            {
                client_printcolor(id, "[FreeNova Shop] Full HP + Armor is once per round.")
                ShowConsumableShop(id)
                return PLUGIN_HANDLED
            }
            if(!TrySpendCoins(id, cost))
            {
                ShopNeedPrint(id, cost)
                ShowConsumableShop(id)
                return PLUGIN_HANDLED
            }
            g_bBoughtHeal[id] = true
            // Paid full restore: 100 AP + helmet, and the same overflow rule as a
            // spawn for a perk owner. It is not BpApplySpawnArmour()'s no-perk
            // branch here: a paying player must never lose the armour they had.
            new iHealHp = 0
            if(g_iArmorBonus[id] > 0)
                iHealHp = BpApplySpawnArmour(id)
            else
                cs_set_user_armor(id, 100, CS_ARMOR_VESTHELM)
            set_user_health(id, 100 + g_iHPBonus[id] + iHealHp)
            client_printcolor(id, "[FreeNova Shop] Full HP + Armor restored! (-%d coins)", cost)
        }
        case 2:
        {
            cost = 100
            if(!TrySpendCoins(id, cost))
            {
                ShopNeedPrint(id, cost)
                ShowConsumableShop(id)
                return PLUGIN_HANDLED
            }
            give_item(id, "weapon_hegrenade")
            give_item(id, "weapon_flashbang")
            give_item(id, "weapon_flashbang")
            give_item(id, "weapon_smokegrenade")
            client_printcolor(id, "[FreeNova Shop] Nades delivered! (-%d coins)", cost)
        }
        case 3:
        {
            cost = 50
            if(cs_get_user_team(id) != CS_TEAM_CT)
            {
                client_printcolor(id, "[FreeNova Shop] Defuse kit is CT only!")
                ShowConsumableShop(id)
                return PLUGIN_HANDLED
            }
            // Do not take 50 coins for a kit the player is already carrying.
            if(cs_get_user_defuse(id))
            {
                client_printcolor(id, "[FreeNova Shop] You already have a defuse kit!")
                ShowConsumableShop(id)
                return PLUGIN_HANDLED
            }
            if(!TrySpendCoins(id, cost))
            {
                ShopNeedPrint(id, cost)
                ShowConsumableShop(id)
                return PLUGIN_HANDLED
            }
            // Same invalid item class as the tier-8 spawn reward above; use the
            // real one so the coins the player just paid are not lost.
            give_item(id, "item_thighpack")
            client_printcolor(id, "[FreeNova Shop] Defuse kit given! (-%d coins)", cost)
        }
    }

    ShowConsumableShop(id)
    return PLUGIN_HANDLED
}

// --- SKILLS SHOP ---
ShowSkillsShop(id)
{
    if (is_user_connected(id))
    {
        ShowBpLiteMenu(id)
        return
    }

    new coins = g_iCoins[id]
    new szTitle[64]
    FN_MenuTitle(szTitle, charsmax(szTitle), "Skills", coins)
    new menu = menu_create(szTitle, "SkillsShopHandler")

    new szItem[160], szInfo[8]

    for(new i = 0; i < SKILL_COUNT; i++)
    {
        if (i == SKILL_MULTI_JUMP || i == SKILL_PARACHUTE || i == SKILL_AWP_UNLOCK || i == SKILL_CHAT_COLOR)
            continue
        num_to_str(i, szInfo, charsmax(szInfo))
        new curStage = g_iShopSkillLevel[id][i]
        new maxStage = g_iSkillMaxStage[i]

        if(curStage >= maxStage)
        {
            formatex(szItem, charsmax(szItem), "\d%s \yMAXED", g_szSkillNames[i])
            menu_additem(menu, szItem, szInfo)
        }
        else
        {
            new nextCost = g_iSkillStageCosts[i][curStage]
            if(curStage == 0)
                formatex(szItem, charsmax(szItem), "\w%s %s", g_szSkillNames[i],
                    coins < nextCost ? fmt("\r%dc", nextCost) : fmt("\y%dc", nextCost))
            else
                formatex(szItem, charsmax(szItem), "\w%s \dLv%d %s", g_szSkillNames[i], curStage,
                    coins < nextCost ? fmt("\r%dc", nextCost) : fmt("\y%dc", nextCost))
            menu_additem(menu, szItem, szInfo)
        }
    }

    FN_MenuFinish(menu, true)
    menu_display(id, menu, 0)
}

public SkillsShopHandler(id, menu, item)
{
    if(item == MENU_EXIT)
    {
        menu_destroy(menu)
        ShowShopMainMenu(id)
        return PLUGIN_HANDLED
    }

    new data[8], name[64], access, callback
    menu_item_getinfo(menu, item, access, data, charsmax(data), name, charsmax(name), callback)
    menu_destroy(menu)

    if(!BpShopReady(id))
    {
        client_printcolor(id, "[FreeNova Shop] Shop data is still loading.")
        return PLUGIN_HANDLED
    }

    new skillIdx = str_to_num(data)
    if(skillIdx < 0 || skillIdx >= SKILL_COUNT)
        return PLUGIN_HANDLED

    new curStage = g_iShopSkillLevel[id][skillIdx]
    new maxStage = g_iSkillMaxStage[skillIdx]

    if(curStage >= maxStage)
    {
        client_printcolor(id, "[FreeNova Shop] %s is already at max stage (%d/%d)!", g_szSkillNames[skillIdx], curStage, maxStage)
        ShowSkillsShop(id)
        return PLUGIN_HANDLED
    }

    if (skillIdx == SKILL_MULTI_JUMP || skillIdx == SKILL_PARACHUTE || skillIdx == SKILL_AWP_UNLOCK || skillIdx == SKILL_CHAT_COLOR)
    {
        client_printcolor(id, "[FreeNova Shop] %s is a Battle Pass tier reward - open /bp to see your track.", g_szSkillNames[skillIdx])
        ShowSkillsShop(id)
        return PLUGIN_HANDLED
    }
    new cost = g_iSkillStageCosts[skillIdx][curStage]
    if(!TrySpendCoins(id, cost))
    {
        client_printcolor(id, "[FreeNova Shop] Not enough coins for %s Stage %d! Need %d, have %d.", g_szSkillNames[skillIdx], curStage + 1, cost, g_iCoins[id])
        ShowSkillsShop(id)
        return PLUGIN_HANDLED
    }

    g_iShopSkillLevel[id][skillIdx]++
    SaveShopData(id)

    RebuildPlayerState(id, true)

    emit_sound(id, CHAN_ITEM, "items/suitchargeno1.wav", 0.8, ATTN_NORM, 0, PITCH_NORM)
    client_printcolor(id, "[FreeNova Shop] Upgraded %s to Stage %d/%d! (-%d coins)", g_szSkillNames[skillIdx], g_iShopSkillLevel[id][skillIdx], maxStage, cost)

    if(skillIdx == SKILL_CHAT_COLOR)
        client_printcolor(id, "[FreeNova Shop] Chat Color License unlocked! Use /color or /chatcolor to choose your chat color.")

    set_task(0.2, "Task_RefreshSkillsShop", id + TASK_SKILLSHOP)
    return PLUGIN_HANDLED
}

public Task_RefreshSkillsShop(taskid)
{
    new id = taskid - TASK_SKILLSHOP
    if(!is_user_connected(id))
        return
    ShowSkillsShop(id)
}

// --- COSMETICS SHOP ---
ShowCosmeticsShop(id)
{
    new szLeg[64]
    FN_MenuTitle(szLeg, charsmax(szLeg), "Legend rewards", g_iCoins[id])
    new menu = menu_create(szLeg, "CosmeticsShopHandler")

    new level = crxranks_get_user_level(id)
    new bool:isLegend = (level >= MAX_LEVELS)

    if(isLegend)
        menu_additem(menu, "\yLegend Player Skin", "1")
    else
        menu_additem(menu, fmt("\dLegend Player Skin \d- reach Lv%d", MAX_LEVELS), "1")

    if(isLegend)
        menu_additem(menu, "\yLegend Weapon Skins", "2")
    else
        menu_additem(menu, fmt("\dLegend Weapon Skins \d- reach Lv%d", MAX_LEVELS), "2")

    FN_MenuFinish(menu, true)
    menu_display(id, menu, 0)
}

public CosmeticsShopHandler(id, menu, item)
{
    if(item == MENU_EXIT)
    {
        menu_destroy(menu)
        ShowShopMainMenu(id)
        return PLUGIN_HANDLED
    }

    new data[8], name[64], access, callback
    menu_item_getinfo(menu, item, access, data, charsmax(data), name, charsmax(name), callback)
    menu_destroy(menu)

    new choice = str_to_num(data)

    switch(choice)
    {
        case 1: client_printcolor(id, "!g[FreeNova] !n Legend Skin auto-equips at level %d.", MAX_LEVELS)
        case 2: client_printcolor(id, "!g[FreeNova] !n Type /skins for Legend weapon skins (tier 4).")
    }

    return PLUGIN_HANDLED
}

// --- VIP TRIAL TIMER ---
// Legacy per-player trial timer removed: trial expiry is owned by the
// unified VIP core (minute tick prunes expired entitlements).

// ============================================================
// MOTD / BATTLEPASS PREVIEW
// ============================================================
public Cmd_Events(id)
{
    if(!is_user_connected(id))
        return PLUGIN_HANDLED
    if(FNWeb_LowPerf(id))
    {
        client_printcolor(id, "!g[FreeNova] !n Events are web-only. Disable !tLow perf mode!n in !t/settings!n to open them.")
        return PLUGIN_HANDLED
    }
    if(FNWeb_OpenPage(id, "events"))
        return PLUGIN_HANDLED
    client_printcolor(id, "!g[FreeNova] !n Check out current events in the web pass (/bp events)!")
    return PLUGIN_HANDLED
}

public Cmd_TopCoins(id)
{
    if(!is_user_connected(id))
        return PLUGIN_HANDLED
    if(FNWeb_OpenPage(id, "top"))
        return PLUGIN_HANDLED
    client_printcolor(id, "!g[FreeNova] !n You have !g%d !nCoins. View leaderboard at /bp top!", g_iCoins[id])
    return PLUGIN_HANDLED
}

public Cmd_BattlePass(id)
{
    if(!is_user_connected(id))
        return PLUGIN_HANDLED

    // /bp [missions|shop|local]
    // Default opens the local web MOTD (battlepass.php).
    // /bp local forces the internal in-game text MOTD.
    new szFull[64], szArg[24]
    read_args(szFull, charsmax(szFull))
    remove_quotes(szFull)
    trim(szFull)

    new iSpace = contain(szFull, " ")
    if(iSpace > 0)
        copy(szArg, charsmax(szArg), szFull[iSpace + 1])
    else
        szArg[0] = 0
    trim(szArg)

    if(equali(szArg, "missions", 8))
    {
        if(LibraryExists("freenova_missions", LibType_Library))
            return fnmsn_show(id) ? PLUGIN_HANDLED : PLUGIN_HANDLED
        // Legacy local missions MOTD removed: it rendered BP-side mission
        // state that no longer exists. freenova_missions is the authority.
        client_print(id, print_chat, "[FreeNova] Missions module is not loaded on this server.")
        return PLUGIN_HANDLED
    }
    if(equali(szArg, "events", 6) || equali(szArg, "tournament", 10))
    {
        client_cmd(id, "say /events")
        return PLUGIN_HANDLED
    }
    if(equali(szArg, "top", 3) || equali(szArg, "topcoins", 8))
    {
        client_cmd(id, "say /top15")
        return PLUGIN_HANDLED
    }
    if(equali(szArg, "shop", 4))
    {
        ShowShopMainMenu(id)
        return PLUGIN_HANDLED
    }
    if(equali(szArg, "next", 4))
    {
        new iMy = BpGetTier(id)
        new iStart = BpTierWindowStart(id, iMy) + 4
        if (iStart > MAX_LEVELS - 3) iStart = MAX_LEVELS - 3
        g_iBpTierStart[id] = iStart
        ShowBpMainPage(id)
        return PLUGIN_HANDLED
    }
    if(equali(szArg, "prev", 4))
    {
        new iMy2 = BpGetTier(id)
        new iStart2 = BpTierWindowStart(id, iMy2) - 4
        if (iStart2 < 1) iStart2 = 1
        g_iBpTierStart[id] = iStart2
        ShowBpMainPage(id)
        return PLUGIN_HANDLED
    }
    if(equali(szArg, "my", 2))
    {
        g_iBpTierStart[id] = 0
        ShowBpMainPage(id)
        return PLUGIN_HANDLED
    }
    if(equali(szArg, "claim", 5))
    {
        new szRest[32], szTier[8], szTrack[8]
        copy(szRest, charsmax(szRest), szArg[5])
        trim(szRest)
        parse(szRest, szTier, charsmax(szTier), szTrack, charsmax(szTrack))
        new iT = str_to_num(szTier)
        new iTr = (equali(szTrack, "prem") || equali(szTrack, "premium") || equal(szTrack, "1")) ? 1 : 0
        new iRes = TryClaimReward(id, iT, iTr)
        if (iRes == 1)
            client_printcolor(id, "[FreeNova] Tier %d %s reward claimed.", iT, iTr ? "premium" : "free")
        else if (iRes == 0)
            client_printcolor(id, "[FreeNova] Tier %d %s already claimed.", iT, iTr ? "premium" : "free")
        else if (iRes == -1)
            client_printcolor(id, "[FreeNova] Tier %d not reached yet.", iT)
        else if (iRes == -2)
            client_printcolor(id, "[FreeNova] Tier %d premium needs VIP. Your tier progress is kept.", iT)
        else
            client_printcolor(id, "[FreeNova] Usage: /bp claim <tier 1-60> <free|prem>.")
        ShowBpMainPage(id)
        return PLUGIN_HANDLED
    }
    if(equali(szArg, "local", 5))
    {
        if (FNWeb_LowPerf(id))
            ShowBpLiteMenu(id);
        else
            ShowBpMainPage(id);
        return PLUGIN_HANDLED;
    }

    // Default: hosted Battle Pass page WITH steamid (not / which is PLAY).
    if (FNWeb_LowPerf(id))
    {
        ShowBpLiteMenu(id);
        return PLUGIN_HANDLED;
    }
    if(FNWeb_OpenPage(id, "battlepass"))
        return PLUGIN_HANDLED

    ShowBpMainPage(id)
    return PLUGIN_HANDLED
}

// Low Performance Mode: Battle Pass summary as a native menu.
ShowBpLiteMenu(id)
{
    if (!is_user_connected(id))
        return
    if (!g_bDataLoaded[id])
    {
        client_printcolor(id, "[FreeNova] Battle Pass data is still loading - try again in a moment.")
        return
    }

    new szTitle[64], szItem[112]
    FN_MenuTitle(szTitle, charsmax(szTitle), "Battle Pass")
    new menu = menu_create(szTitle, "BpLite_Handler")

    // BP tier / BP XP from the BP ledger - this is the Battle Pass page, not
    // the rank page (REVIEW §2.4 H1: it used to print rank level as "Tier").
    formatex(szItem, charsmax(szItem), "\wBP Tier \y%d \d/ %d  \wSeason \y%d", BpGetTier(id), MAX_LEVELS, BpCurrentSeason())
    menu_additem(menu, szItem, "0")
    formatex(szItem, charsmax(szItem), "\wBP XP \y%d \d|  \wCoins \y%d", BpGetXp(id), g_iCoins[id])
    menu_additem(menu, szItem, "0")
    formatex(szItem, charsmax(szItem), "\wLane \y%s  \d|  \wPremium paid to \y%d", g_szLaneNames[g_iPremiumLane[id]], g_iPremiumPaid[id])
    menu_additem(menu, szItem, "0")

    menu_additem(menu, "\wMissions \d- daily / weekly", "1")
    menu_additem(menu, "\wTop 15 \d- leaderboard", "2")
    menu_additem(menu, "\wShop \d- coins, boosts, cosmetics", "3")
    menu_additem(menu, "\wDetailed track \d- native page", "4")
    FN_MenuFinish(menu, false)
    menu_display(id, menu, 0)
}

public BpLite_Handler(id, menu, item)
{
    if (item == MENU_EXIT || !is_user_connected(id))
    {
        menu_destroy(menu)
        return PLUGIN_HANDLED
    }

    new szData[8], iAccess, iCallback
    menu_item_getinfo(menu, item, iAccess, szData, charsmax(szData), _, _, iCallback)
    menu_destroy(menu)

    switch (str_to_num(szData))
    {
        case 1: client_cmd(id, "say /missions")
        case 2: client_cmd(id, "say /top15")
        case 3: ShowShopMainMenu(id)
        case 4: ShowBpMainPage(id)
    }
    return PLUGIN_HANDLED
}

// ---------------------------------------------------------------- bp pages

// Tab strip for the BattlePass pages (switch via /bp, /bp missions, /bp shop)
BuildBpTabBar(szBuffer[], iLen, iActive)
{
    static const szKeys[][] = { "PASS", "MISSIONS", "SHOP" }
    new iPos = copy(szBuffer, iLen, "<div class='fntitle'>")
    for(new i; i < 3; i++)
    {
        if(i) iPos += copy(szBuffer[iPos], iLen - iPos, " | ")
        iPos += formatex(szBuffer[iPos], iLen - iPos,
            (i == iActive) ? "<span class='fngreen'>%s</span>" : "<span class='fnmuted'>%s</span>",
            szKeys[i])
    }
    iPos += copy(szBuffer[iPos], iLen - iPos, "</div><div class='fnmuted' style='font-size:10px;'>tabs: /bp - missions - shop</div>")
    return iPos
}

// ---- Two-track tier window (4 columns, both tracks share tiers) ----

BpTierWindowStart(id, iMyTier)
{
    new iStart = g_iBpTierStart[id]
    if (iStart < 1) iStart = iMyTier - 1
    if (iStart < 1) iStart = 1
    if (iStart > MAX_LEVELS - 3) iStart = MAX_LEVELS - 3
    return iStart
}


// Cell reward short text. Returns 1 for a real reward, 0 for empty.
BpCellReward(id, iTier, iLane, bool:bPremium, szOut[], iLen)
{
    #pragma unused id
    if (bPremium)
    {
        for (new r = 0; r < sizeof(g_iLaneSkillUnlock); r++)
        {
            if (g_iLaneSkillUnlock[r][0] == iLane && g_iLaneSkillUnlock[r][2] == iTier)
            {
                new iSk = g_iLaneSkillUnlock[r][1]
                if (iSk >= 0 && iSk < sizeof(g_szBpSkillShort))
                    copy(szOut, iLen, g_szBpSkillShort[iSk])
                else
                    copy(szOut, iLen, "Skill")
                return 1
            }
        }
        new iExtra = BpPremiumExtraCoinsLane(iTier, iLane)
        if (iExtra > 0)
        {
            formatex(szOut, iLen, "+%dc", iExtra)
            return 1
        }
        if (BpPremiumPerkShort(iTier, szOut, iLen))
            return 1
        szOut[0] = 0
        return 0
    }
    new iCoins = (iTier >= 1 && iTier <= MAX_LEVELS) ? g_iBpFreeCoins[iTier] : 0
    if (iCoins > 0)
    {
        formatex(szOut, iLen, "%dc", iCoins)
        return 1
    }
    if (BpFreePerkShort(iTier, szOut, iLen))
        return 1
    szOut[0] = 0
    return 0
}

stock bool:BpPremiumPerkShort(tier, szOut[], iLen)
{
    szOut[0] = 0
    switch (tier)
    {
        case 4: copy(szOut, iLen, "Chat")
        case 8: copy(szOut, iLen, "Tag")
        case 12: copy(szOut, iLen, "Badge")
        case 16: copy(szOut, iLen, "AK Skin")
        case 17: copy(szOut, iLen, "HP Prime")
        case 19: copy(szOut, iLen, "AP Prime")
        case 20: copy(szOut, iLen, "Case")
        case 21: copy(szOut, iLen, "Spd Prime")
        case 24: copy(szOut, iLen, "Knife")
        case 25: copy(szOut, iLen, "Fall Prime")
        case 28: copy(szOut, iLen, "Model")
        case 32: copy(szOut, iLen, "Aura")
        case 33: copy(szOut, iLen, "AP Prime")
        case 36: copy(szOut, iLen, "Title")
        case 37: copy(szOut, iLen, "Spd Prime")
        case 40: copy(szOut, iLen, "M4 Skin")
        case 44: copy(szOut, iLen, "AWP Skin")
        case 45: copy(szOut, iLen, "Sniper+")
        case 48: copy(szOut, iLen, "Trophy")
        case 49: copy(szOut, iLen, "Nade+")
        case 52: copy(szOut, iLen, "Knife")
        case 53: copy(szOut, iLen, "Last+")
        case 55: copy(szOut, iLen, "HP Prime")
        case 56: copy(szOut, iLen, "Model II")
        case 57: copy(szOut, iLen, "Spd Prime")
        case 60: copy(szOut, iLen, "Elite")
        default: return false
    }
    return true
}

stock bool:BpFreePerkShort(tier, szOut[], iLen)
{
    szOut[0] = 0
    switch (tier)
    {
        case 2: copy(szOut, iLen, "+1 HP")
        case 4: copy(szOut, iLen, "+2 AP")
        case 6: copy(szOut, iLen, "+1% SPD")
        case 8: copy(szOut, iLen, "Defuse")
        case 10: copy(szOut, iLen, "Chute")
        case 12: copy(szOut, iLen, "Jump I")
        case 14: copy(szOut, iLen, "HE")
        case 16: copy(szOut, iLen, "+2 HP")
        case 18: copy(szOut, iLen, "+3 AP")
        case 20: copy(szOut, iLen, "+1% SPD")
        case 22: copy(szOut, iLen, "Vamp")
        case 24: copy(szOut, iLen, "Fall 15")
        case 26: copy(szOut, iLen, "Sniper")
        case 28: copy(szOut, iLen, "Nade 15")
        case 30: copy(szOut, iLen, "Medic 3s")
        case 32: copy(szOut, iLen, "Last 5")
        case 34: copy(szOut, iLen, "AWP")
        case 36: copy(szOut, iLen, "Chat")
        case 38: copy(szOut, iLen, "+4 HP")
        case 39: copy(szOut, iLen, "+6 AP")
        case 40: copy(szOut, iLen, "+2% SPD")
        case 41: copy(szOut, iLen, "Vamp II")
        case 42: copy(szOut, iLen, "Fall 30")
        case 43: copy(szOut, iLen, "Sniper II")
        case 44: copy(szOut, iLen, "Nade 30")
        case 45: copy(szOut, iLen, "Medic 2s")
        case 46: copy(szOut, iLen, "Last 10")
        case 47: copy(szOut, iLen, "Jump II")
        case 48: copy(szOut, iLen, "+6 HP")
        case 49: copy(szOut, iLen, "+9 AP")
        case 50: copy(szOut, iLen, "+3% SPD")
        case 51: copy(szOut, iLen, "Vamp III")
        case 52: copy(szOut, iLen, "Fall 45")
        case 53: copy(szOut, iLen, "Jump III")
        case 54: copy(szOut, iLen, "+1 HP")
        case 55: copy(szOut, iLen, "+2 AP")
        case 56: copy(szOut, iLen, "+1% SPD")
        case 57: copy(szOut, iLen, "+1 HP")
        case 58: copy(szOut, iLen, "+2 AP")
        case 59: copy(szOut, iLen, "+1% SPD")
        case 60: copy(szOut, iLen, "+2,000c")
        default: return false
    }
    return true
}

ShowBpTracks(id, szMOTD[], iLen, iSize, iMyTier, iFreePaid, iPremPaid, iLane, bool:bHasPremium)
{
    new iStart = BpTierWindowStart(id, iMyTier)
    iLen += copy(szMOTD[iLen], iSize - iLen, "<table class='fnt'><tr><td></td>")
    for (new t = iStart; t < iStart + 4; t++)
        iLen += formatex(szMOTD[iLen], iSize - iLen, "<td align=center><b>T%d</b></td>", t)
    iLen += copy(szMOTD[iLen], iSize - iLen, "</tr>")
    new szCell[24], szCol[8]
    for (new track = 0; track < 2; track++)
    {
        new bool:bPrem = (track == 0)
        if (bPrem)
            iLen += copy(szMOTD[iLen], iSize - iLen, "<tr><td><font color='#FFD700'>Prem</font></td>")
        else
            iLen += copy(szMOTD[iLen], iSize - iLen, "<tr><td>Free</td>")
        for (new t2 = iStart; t2 < iStart + 4; t2++)
        {
            new bool:bReal = BpCellReward(id, t2, iLane, bPrem, szCell, charsmax(szCell)) ? true : false
            if (bPrem && !bHasPremium)
            {
                copy(szCol, charsmax(szCol), "#FFD700")
                if (!bReal) copy(szCell, charsmax(szCell), (BpCurrentSeason() > 1) ? "PREM" : "VIP")
            }
            new iMark = bPrem ? iPremPaid : iFreePaid
            if (t2 <= iMark)
                copy(szCol, charsmax(szCol), "#FFFFFF")
            else if (t2 == iMark + 1)
                copy(szCol, charsmax(szCol), "#36DEAB")
            else
                copy(szCol, charsmax(szCol), "#888888")
            if (!bReal && !(bPrem && !bHasPremium))
                copy(szCell, charsmax(szCell), "-")
            iLen += formatex(szMOTD[iLen], iSize - iLen, "<td align=center><font color='%s'>%s</font></td>", szCol, szCell)
        }
        iLen += copy(szMOTD[iLen], iSize - iLen, "</tr>")
    }
    iLen += formatex(szMOTD[iLen], iSize - iLen, "</table><div>T%d-%d of %d (white=claimed green=open grey=locked gold=VIP)</div>", iStart, iStart + 3, MAX_LEVELS)
    return iLen
}

// MAIN TAB - the webpanel front page: season progress, rewards, boost
ShowBpMainPage(id)
{
    new szBpName[24], szBpSub[64]
    get_cvar_string("fn_bp_season_name", szBpName, charsmax(szBpName))
    // BP XP / BP tier: this page is the Battle Pass track, so its progress must
    // not be rank XP (REVIEW §2.4 H1). Rank progress lives on /rank.
    // BpGetTier is 0 while the row loads: the page must still read "tier 1,
    // empty progress" rather than tier 0, so clamp it here.
    new iXP = BpGetXp(id)
    new iLevel = BpGetTier(id)
    if (iLevel < 1)
        iLevel = 1
    new iNext = BpTierThreshold(iLevel + 1)
    if (iLevel >= MAX_LEVELS)
        iNext = BpMaxXp()
    new iPercent = (iNext > 0) ? clamp((iXP * 100) / iNext, 0, 100) : 100
    new iBpEnd = get_cvar_num("fn_bp_season_end")
    new iDaysLeft = (iBpEnd > get_systime()) ? ((iBpEnd - get_systime()) / 86400) : -1
    if (iDaysLeft >= 0)
        formatex(szBpSub, charsmax(szBpSub), "%s - Tier %d - %dd left", szBpName, iLevel, iDaysLeft)
    else
        formatex(szBpSub, charsmax(szBpSub), "%s - Tier %d - open season", szBpName, iLevel)
    new szBar[24]
    FN_TextBar(iPercent, 18, szBar, charsmax(szBar))
    new szXP[16], szNext[16], szCoins[16]
    FN_AddCommas(iXP, szXP, charsmax(szXP))
    FN_AddCommas(iNext, szNext, charsmax(szNext))
    FN_AddCommas(g_iCoins[id], szCoins, charsmax(szCoins))
    new szMOTD[6144], iLen
    iLen = FN_TornadoHead(szMOTD, charsmax(szMOTD), "Battle Pass", szBpSub)
    iLen += BuildBpTabBar(szMOTD[iLen], charsmax(szMOTD) - iLen, 0)
    iLen += formatex(szMOTD[iLen], charsmax(szMOTD) - iLen,
        "<table class='fnt'><tr><td>XP</td><td class='v'>%s/%s [%s]%d%%</td></tr><tr><td>Coins</td><td class='v'>%s</td></tr>",
        szXP, szNext, szBar, iPercent, szCoins)
    if (g_bHasXpBoost[id] && g_iBoostEndTime[id] > get_systime())
        iLen += formatex(szMOTD[iLen], charsmax(szMOTD) - iLen,
            "<tr><td>Boost</td><td class='v'>%.1fx %dm</td></tr>",
            g_fXpBoost[id], (g_iBoostEndTime[id] - get_systime()) / 60)
    iLen += copy(szMOTD[iLen], charsmax(szMOTD) - iLen, "</table>")
    new iLane = g_iPremiumLane[id]
    if (iLane < 0 || iLane > 3) iLane = 0
    // Season-aware: S1 legacy VIP lane, S2+ store entitlement (re-buy each season).
    new bool:bHasPremium = BpPremiumAllowed(id)
    iLen += copy(szMOTD[iLen], charsmax(szMOTD) - iLen, "<div class='fntitle'>Tracks - ")
    iLen += copy(szMOTD[iLen], charsmax(szMOTD) - iLen, g_szLaneNames[iLane])
    if (!bHasPremium)
        iLen += copy(szMOTD[iLen], charsmax(szMOTD) - iLen, " (free)")
    iLen += copy(szMOTD[iLen], charsmax(szMOTD) - iLen, "</div>")
    iLen = ShowBpTracks(id, szMOTD, iLen, charsmax(szMOTD), iLevel, g_iMilestonePaid[id], g_iPremiumPaid[id], iLane, bHasPremium)
    iLen += copy(szMOTD[iLen], charsmax(szMOTD) - iLen, "<div>Chat: /bp prev|next|my|missions|shop</div>")
    iLen = FN_TornadoFoot(szMOTD, charsmax(szMOTD), iLen)
    FN_MotdShow(id, szMOTD, "FreeNova | Battle Pass")
}

// MISSIONS TAB - dailies + weeklies with live progress
// ============================================================
// LEGACY BP MISSIONS MOTD PAGE - REMOVED
// ============================================================
// ShowBpMissionsPage/GetWeekKey rendered the local (pre-split) mission
// counters as an HTML table for /bp missions. Those counters no longer
// exist in this file; freenova_missions/freenova_achievements own them.
// /bp missions now delegates to fnmsn_show() (see Cmd_BattlePass).

// ============================================================
// LOCAL WEB MOTD
// ============================================================
bool:ShowWebPassMotd(id, const szTab[] = "pass")
{
    // Identity and page live in a short /m/<code>/<steam>.htm path.
    // The previous implementation stuffed name/xp/coins/skills into the
    // query string and GoldSrc returned HTTP -102 for every /bp /top15 /profile.
    if (FNWeb_OpenPage(id, szTab[0] ? szTab : "battlepass"))
        return true

    return false
}

public BpNativeFilter(const name[], index, trap)
{
    if(equal(name, "fnstats_get") || equal(name, "fncosmetics_get_spawn") || equal(name, "fncosmetics_get_title") || equal(name, "fncosmetics_get_death") || equal(name, "fncosmetics_open_shop") || equal(name, "fncosmetics_unlock_spawn") || equal(name, "fncosmetics_unlock_title") || equal(name, "fncosmetics_grant_tag_license") || equal(name, "fncosmetics_grant_chat_color") || equal(name, "fn_skins_unlock") || equal(name, "fn_models_unlock") || equal(name, "fnclutch_get_won") || equal(name, "fnclutch_get_att") || equal(name, "fn_hub_open") || equal(name, "skins_open_menu") || equal(name, "fnach_get_unlocked") || equal(name, "fnach_get_count") || equal(name, "fnach_get_stat") || equal(name, "fnach_show") || equal(name, "fnach_note_revive") || equal(name, "fnach_is_loaded") || equal(name, "fnmsn_is_complete") || equal(name, "fnmsn_get_daily_progress") || equal(name, "fnmsn_get_daily2_progress") || equal(name, "fnmsn_get_weekly_progress") || equal(name, "fnmsn_get_daily_done") || equal(name, "fnmsn_get_bonus_done") || equal(name, "fnmsn_get_weekly_done") || equal(name, "fnmsn_show"))
    {
        return PLUGIN_HANDLED
    }
    return PLUGIN_CONTINUE
}

// ============================================================
// NATIVES
// ============================================================
public plugin_natives()
{
    set_native_filter("BpNativeFilter")
    register_library("menabp")
    register_native("menabp_has_weapon_menu", "native_has_weapon_menu")
    register_native("menabp_has_weapon_menu_awp", "native_has_weapon_menu_awp")
    register_native("menabp_has_double_jump", "native_has_double_jump")
    register_native("menabp_has_parachute", "native_has_parachute")
    register_native("menabp_has_healthnade", "native_has_healthnade")
    register_native("menabp_has_revive", "native_has_revive")
    register_native("menabp_has_fastsniper", "native_has_fastsniper")
    register_native("menabp_get_revive_time", "native_get_revive_time")
    register_native("menabp_get_revive_max_revives", "native_get_max_revives")
    register_native("menabp_get_revive_max_spawns", "native_get_max_spawns")
    register_native("menabp_get_healthnade_throw", "native_get_hn_throw")
    register_native("menabp_get_healthnade_drink", "native_get_hn_drink")

    register_native("menabp_get_prestige", "native_get_prestige")
    register_native("menabp_get_coins", "native_get_coins")
    register_native("menabp_add_coins", "native_add_coins")
    register_native("menabp_add_coins_once", "native_add_coins_once")
    // BattlePass XP/tier natives. They read and write the BP ledger above -
    // NOT crxranks rank XP/level (REVIEW §2.4 H1). The names are historic:
    // menabp_get_xp is BP XP, menabp_get_tier is BP tier.
    register_native("menabp_get_xp", "native_get_bp_xp")
    register_native("menabp_get_tier", "native_get_bp_tier")
    register_native("menabp_get_next_xp", "native_get_bp_next_xp")
    register_native("menabp_get_max_tier", "native_get_bp_max_tier")
    register_native("menabp_add_xp", "native_add_bp_xp")
    register_native("menabp_add_xp_once", "native_add_bp_xp_once")
    register_native("menabp_get_vip_tier", "native_get_vip_tier")
    register_native("menabp_is_mission_complete", "native_is_mission_complete")
    register_native("menabp_get_daily_progress", "native_get_daily_progress")
    register_native("menabp_get_daily2_progress", "native_get_daily2_progress")
    register_native("menabp_get_weekly_progress", "native_get_weekly_progress")
    register_native("menabp_show_battlepass", "native_show_battlepass")
    register_native("menabp_show_shop", "native_show_shop")
    register_native("menabp_show_skills", "native_show_skills")
    register_native("menabp_show_missions", "native_show_missions")
    register_native("menabp_show_achievements", "native_show_achievements")
    register_native("menabp_get_boost_left", "native_get_boost_left")
    register_native("menabp_get_boost_mult", "native_get_boost_mult")
    register_native("menabp_get_daily_done", "native_get_daily_done")
    register_native("menabp_get_bonus_done", "native_get_bonus_done")
    register_native("menabp_get_weekly_done", "native_get_weekly_done")
    register_native("menabp_get_ach_count", "native_get_ach_count")
    register_native("menabp_get_ach_unlocked", "native_get_ach_unlocked")
    register_native("menabp_get_ach_stat", "native_get_ach_stat")
    register_native("menabp_show_motd", "native_show_motd")
    register_native("menabp_get_skill_stage", "native_get_skill_stage")
    register_native("menabp_set_skill_stage", "native_set_skill_stage")
    register_native("menabp_note_revive", "native_note_revive")
    register_native("menabp_get_bp_hp", "native_get_bp_hp")
    register_native("menabp_get_bp_armor", "native_get_bp_armor")
    register_native("menabp_get_bp_jumps", "native_get_bp_jumps")
    register_native("menabp_get_bp_sniper", "native_get_bp_sniper")
    register_native("menabp_get_bp_laststand", "native_get_bp_laststand")
    register_native("menabp_get_bp_chute", "native_get_bp_chute")
    register_native("menabp_get_bp_premium", "native_get_bp_premium")
    register_native("menabp_get_bp_milestone", "native_get_bp_milestone")
    register_native("menabp_is_ready", "native_is_ready")
}

public native_show_motd(plugin, params)
{
    new id = get_param(1)
    if(!(1 <= id <= MAX_PLAYERS) || !is_user_connected(id))
        return 0

    new szTab[32]
    get_string(2, szTab, charsmax(szTab))
    if (FNWeb_LowPerf(id))
    {
        ShowBpLiteMenu(id)
        return 1
    }
    return ShowWebPassMotd(id, szTab) ? 1 : 0
}

stock bool:BpValidId(id)
{
    return (1 <= id <= MAX_PLAYERS)
}

public native_has_weapon_menu(plugin, params) { new id = get_param(1); return BpValidId(id) && g_bHasWeaponMenu[id] ? 1 : 0; }
public native_has_weapon_menu_awp(plugin, params) { new id = get_param(1); return BpValidId(id) && g_bHasWeaponMenuAwp[id] ? 1 : 0; }
public native_has_double_jump(plugin, params) { new id = get_param(1); return BpValidId(id) && g_bHasDoubleJump[id] ? 1 : 0; }
public native_has_parachute(plugin, params) { new id = get_param(1); return BpValidId(id) && g_bHasParachute[id] ? 1 : 0; }
public native_has_healthnade(plugin, params) { new id = get_param(1); return BpValidId(id) && g_bHasHealthNade[id] ? 1 : 0; }
public native_has_revive(plugin, params) { new id = get_param(1); return BpValidId(id) && g_bHasRevive[id] ? 1 : 0; }
public native_has_fastsniper(plugin, params) { new id = get_param(1); return BpValidId(id) && g_bHasFastSniper[id] ? 1 : 0; }
public native_get_revive_time(plugin, params)
{
    new id = get_param(1)
    if (!BpValidId(id))
        return 0
    return _:g_fReviveTime[id]
}
public native_get_max_revives(plugin, params) { new id = get_param(1); return BpValidId(id) ? g_iMaxRevives[id] : 0; }
public native_get_max_spawns(plugin, params) { new id = get_param(1); return BpValidId(id) ? g_iMaxSpawns[id] : 0; }
public native_get_hn_throw(plugin, params)
{
    new id = get_param(1)
    if (!BpValidId(id))
        return 0
    return _:g_fHNThrow[id]
}
public native_get_hn_drink(plugin, params)
{
    new id = get_param(1)
    if (!BpValidId(id))
        return 0
    return _:g_fHNDrink[id]
}

// read-only mission progress exports (web sync push)
public native_get_daily_progress(plugin, params)
{
    new id = get_param(1), m = get_param(2)
    if(!BpValidId(id))
        return 0
    if(LibraryExists("freenova_missions", LibType_Library))
        return fnmsn_get_daily_progress(id, m)
    return 0
}

public native_get_daily2_progress(plugin, params)
{
    new id = get_param(1), m = get_param(2)
    if(!BpValidId(id))
        return 0
    if(LibraryExists("freenova_missions", LibType_Library))
        return fnmsn_get_daily2_progress(id, m)
    return 0
}

public native_get_weekly_progress(plugin, params)
{
    new id = get_param(1), m = get_param(2)
    if(!BpValidId(id))
        return 0
    if(LibraryExists("freenova_missions", LibType_Library))
        return fnmsn_get_weekly_progress(id, m)
    return 0
}

public native_get_prestige(plugin, params)
{
    new id = get_param(1)
    if (!BpValidId(id))
        return 0
    return rsu_get_prestige(id)
}
public native_is_ready(plugin, params)
{
    new id = get_param(1)
    return (BpValidId(id) && g_bDataLoaded[id]) ? 1 : 0
}
public native_get_coins(plugin, params) { new id = get_param(1); return BpValidId(id) ? g_iCoins[id] : 0; }
// Internal credit path with the same 2B wallet cap as the native (direct
// += sites must never bypass it: overflow wraps negative and defeats
// every fail-closed spend check).
stock BpCreditCoins(id, amount)
{
    if (!BpValidId(id) || !g_bDataLoaded[id] || amount <= 0)
        return g_iCoins[id]
    if (g_iCoins[id] > 2000000000 - amount)
    {
        g_iCoins[id] = 2000000000
        log_amx("[FreeNova] Wallet cap hit for %d, clamped to 2000000000", id)
    }
    else
        g_iCoins[id] += amount
    SaveCoins(id)
    return g_iCoins[id]
}
public native_add_coins(plugin, params) {
    new id = get_param(1)
    new amount = get_param(2)
    // Spends (negative) fail-closed: never clamp a 100c spend of 40 coins to 0.
    // Kill-coin VIP already multiplies at the grant site.
    if(!BpValidId(id) || !g_bDataLoaded[id])
        return 0
    if(amount < 0)
    {
        if(g_iCoins[id] < -amount)
            return 0
        g_iCoins[id] += amount
        SaveCoins(id)
        return g_iCoins[id]
    }
    // Wallet cap: 32-bit cells overflow into negative balances past 2^31-1
    // (which would corrupt spend checks and displays). Clamp and log.
    if (amount > 0 && g_iCoins[id] > 2000000000 - amount)
    {
        g_iCoins[id] = 2000000000
        log_amx("[FreeNova] Wallet cap hit for %d, clamped to 2000000000", id)
    }
    else
        g_iCoins[id] += amount
    SaveCoins(id)
    return g_iCoins[id]
}
stock BpAwardKey(id, const szKind[], const szAward[], szKey[], iLen)
{
    new szAuth[40]
    BpSafeAuth(id, szAuth, charsmax(szAuth))
    formatex(szKey, iLen, "bpaward#%d#%s#%s#%s", BpCurrentSeason(), szAuth, szKind, szAward)
}
stock bool:BpAwardExists(id, const szKind[], const szAward[])
{
    if (g_VaultBP == INVALID_HANDLE)
        return false
    new szKey[128], szVal[8]
    BpAwardKey(id, szKind, szAward, szKey, charsmax(szKey))
    return nvault_get(g_VaultBP, szKey, szVal, charsmax(szVal)) ? true : false
}
stock BpMarkAward(id, const szKind[], const szAward[])
{
    if (g_VaultBP == INVALID_HANDLE)
        return
    new szKey[128]
    BpAwardKey(id, szKind, szAward, szKey, charsmax(szKey))
    if (!nvault_set(g_VaultBP, szKey, "1"))
        log_amx("[FreeNova] WARNING: nvault_set failed for BP award key=%s", szKey)
}
public native_add_coins_once(plugin, params)
{
    new id = get_param(1)
    new amount = get_param(2)
    new szAward[64]
    get_string(3, szAward, charsmax(szAward))
    if (!BpValidId(id) || !g_bDataLoaded[id] || amount <= 0 || !szAward[0])
        return -1
    if (BpAwardExists(id, "coins", szAward))
        return 0
    BpCreditCoins(id, amount)
    BpMarkAward(id, "coins", szAward)
    return g_iCoins[id]
}
public native_get_bp_xp(plugin, params)
{
    new id = get_param(1)
    if (!BpValidId(id) || !g_bDataLoaded[id])
        return 0
    return BpGetXp(id)
}
public native_get_bp_tier(plugin, params)
{
    new id = get_param(1)
    if (!BpValidId(id) || !g_bDataLoaded[id])
        return 0
    return BpGetTier(id)
}
public native_get_bp_next_xp(plugin, params)
{
    new id = get_param(1)
    if (!BpValidId(id) || !g_bDataLoaded[id])
        return 0
    new iTier = BpGetTier(id)
    // Absolute BP XP threshold of the next tier; at tier 60 it is the cap.
    if (iTier >= MAX_LEVELS)
        return BpMaxXp()
    return BpTierThreshold(iTier + 1)
}
public native_get_bp_max_tier(plugin, params)
{
    #pragma unused plugin, params
    return MAX_LEVELS
}
public native_add_bp_xp(plugin, params)
{
    new id = get_param(1)
    new amount = get_param(2)
    if (!BpValidId(id) || !g_bDataLoaded[id] || !g_bBpXpLoaded[id] || amount <= 0)
        return 0
    // BP XP only. crxranks_give_user_xp is deliberately NOT called: it moves
    // rank XP, and amx_bp_givexp must not touch that counter (REVIEW §2.4 H1).
    return BpAddXp(id, amount)
}
public native_add_bp_xp_once(plugin, params)
{
    new id = get_param(1)
    new amount = get_param(2)
    new szAward[64]
    get_string(3, szAward, charsmax(szAward))
    if (!BpValidId(id) || !g_bDataLoaded[id] || !g_bBpXpLoaded[id] || amount <= 0 || !szAward[0])
        return -1
    // Idempotency and the multipliers both live one level down (BpAddXpOnce ->
    // BpAddXp), so a consumed award id adds nothing and never doubles.
    return BpAddXpOnce(id, amount, szAward)
}
public native_get_skill_stage(plugin, params)
{
    new id = get_param(1)
    new skill = get_param(2)
    if(!(1 <= id <= MAX_PLAYERS) || skill < 0 || skill >= SKILL_COUNT)
        return 0
    return g_iShopSkillLevel[id][skill]
}
public native_set_skill_stage(plugin, params)
{
    new id = get_param(1)
    new skill = get_param(2)
    new stage = get_param(3)
    if(!(1 <= id <= MAX_PLAYERS) || !is_user_connected(id) || !g_bDataLoaded[id]
        || skill < 0 || skill >= SKILL_COUNT)
        return 0
    g_iShopSkillLevel[id][skill] = clamp(stage, 0, g_iSkillMaxStage[skill])
    SaveShopData(id)
    RebuildPlayerState(id, true)
    return 1
}
public native_note_revive(plugin, params)
{
    new id = get_param(1)
    if(!BpValidId(id) || !is_user_connected(id))
        return 0
    if(LibraryExists("freenova_achievements", LibType_Library))
        return fnach_note_revive(id)
    return 0
}
public native_get_vip_tier(plugin, params) { return GetVipTier(get_param(1)); }
public native_is_mission_complete(plugin, params)
{
    new id = get_param(1)
    if(!BpValidId(id))
        return 0
    if(LibraryExists("freenova_missions", LibType_Library))
        return fnmsn_is_complete(id)
    return 0
}
public native_show_battlepass(plugin, params) { Cmd_BattlePass(get_param(1)); }
public native_show_shop(plugin, params) { Cmd_Shop(get_param(1)); }
public native_show_skills(plugin, params)
{
    new id = get_param(1)
    if (!BpValidId(id) || !is_user_connected(id) || !BpShopReady(id))
        return 0
    if (FNWeb_LowPerf(id))
        ShowBpLiteMenu(id)
    else
        ShowBpMainPage(id)
    return 1
}
public native_show_missions(plugin, params)
{
    new id = get_param(1)
    if(!BpValidId(id) || !is_user_connected(id))
        return 0
    if(LibraryExists("freenova_missions", LibType_Library))
        return fnmsn_show(id)
    return 0
}
public native_show_achievements(plugin, params)
{
    new id = get_param(1)
    if(!BpValidId(id) || !is_user_connected(id))
        return 0
    if(LibraryExists("freenova_achievements", LibType_Library))
        return fnach_show(id)
    return 0
}
public native_get_boost_left(plugin, params)
{
    new id = get_param(1)
    if(!BpValidId(id) || !g_bHasXpBoost[id])
        return 0
    new left = g_iBoostEndTime[id] - get_systime()
    return (left > 0) ? left : 0
}
public native_get_boost_mult(plugin, params)
{
    new id = get_param(1)
    if(!BpValidId(id) || !g_bHasXpBoost[id] || g_iBoostEndTime[id] <= get_systime())
        return _:1.0
    return _:g_fXpBoost[id]
}
public native_get_daily_done(plugin, params)
{
    new id = get_param(1)
    if(!BpValidId(id))
        return 0
    if(LibraryExists("freenova_missions", LibType_Library))
        return fnmsn_get_daily_done(id)
    return 0
}
public native_get_bonus_done(plugin, params)
{
    new id = get_param(1)
    if(!BpValidId(id))
        return 0
    if(LibraryExists("freenova_missions", LibType_Library))
        return fnmsn_get_bonus_done(id)
    return 0
}
public native_get_weekly_done(plugin, params)
{
    new id = get_param(1)
    if(!BpValidId(id))
        return 0
    if(LibraryExists("freenova_missions", LibType_Library))
        return fnmsn_get_weekly_done(id)
    return 0
}
public native_get_ach_count(plugin, params)
{
    new id = get_param(1)
    if(!BpValidId(id))
        return 0
    if(LibraryExists("freenova_achievements", LibType_Library))
        return fnach_get_count(id)
    return 0
}
public native_get_ach_unlocked(plugin, params)
{
    new id = get_param(1)
    if(!BpValidId(id))
        return 0
    if(LibraryExists("freenova_achievements", LibType_Library))
        return fnach_get_unlocked(id)
    return 0
}
public native_get_ach_stat(plugin, params)
{
    new id = get_param(1)
    new which = get_param(2)
    if(!BpValidId(id))
        return 0
    if(LibraryExists("freenova_achievements", LibType_Library))
        return fnach_get_stat(id, which)
    return 0
}
public native_get_bp_hp(plugin, params) { new id = get_param(1); return BpValidId(id) ? g_iPassHp[id] : 0; }
public native_get_bp_armor(plugin, params) { new id = get_param(1); return BpValidId(id) ? g_iPassArmor[id] : 0; }
public native_get_bp_jumps(plugin, params) { new id = get_param(1); return BpValidId(id) ? g_iPassJumps[id] : 0; }
public native_get_bp_sniper(plugin, params) { new id = get_param(1); return BpValidId(id) ? g_iPassSniper[id] : 0; }
public native_get_bp_laststand(plugin, params) { new id = get_param(1); return BpValidId(id) ? g_iPassLaststand[id] : 0; }
public native_get_bp_chute(plugin, params) { new id = get_param(1); return BpValidId(id) ? g_iPassChute[id] : 0; }
public native_get_bp_premium(plugin, params) { new id = get_param(1); return BpValidId(id) ? g_iPremiumPaid[id] : 0; }
public native_get_bp_milestone(plugin, params) { new id = get_param(1); return BpValidId(id) ? g_iMilestonePaid[id] : 0; }

// ============================================================
// DEFAULTS
// ============================================================
InitDefaults()
{
    new Float:fMaxLevelsDenom = float(MAX_LEVELS - 1)
    for(new i = 1; i <= MAX_LEVELS; i++)
    {
        g_iHPByLevel[i]        = min(15, i - 1)
        g_iArmorByLevel[i]     = min(15, i - 1)
        g_fKnifeSpeedByLevel[i] = 250.0 + float(i - 1) * (30.0 / fMaxLevelsDenom)
        g_fDamageByLevel[i]    = 1.0 + float(i - 1) * (0.05 / fMaxLevelsDenom)
        g_fGravityByLevel[i]   = 1.0 - float(i - 1) * (0.05 / fMaxLevelsDenom)
        g_fReloadCapByLevel[i] = 2.5 - float(i - 1) * (0.5 / fMaxLevelsDenom)
        g_fPlantSpeedByLevel[i]  = 1.0 - float(i - 1) * (0.08 / fMaxLevelsDenom)
        g_fDefuseSpeedByLevel[i] = 1.0 - float(i - 1) * (0.08 / fMaxLevelsDenom)
        g_fSwitchSpeedByLevel[i] = 1.0 - float(i - 1) * (0.08 / fMaxLevelsDenom)
        g_fFallDmgReduceByLevel[i] = float(i - 1) * (0.20 / fMaxLevelsDenom)
    }
}

// COLORED CHAT UTILITY
// ============================================================
// Uses raw SayText - !g = green, !t = team color, !n = normal/white
stock client_printcolor(id, const fmt[], any:...)
{
    new msg[192]
    vformat(msg, charsmax(msg), fmt, 3)
    replace_all(msg, charsmax(msg), "!g", "^4")
    replace_all(msg, charsmax(msg), "!t", "^3")
    replace_all(msg, charsmax(msg), "!n", "^1")
    replace_all(msg, charsmax(msg), "!Team", "^3")
    // REVIEW.md 5.5: the caller's text was passed as the FORMAT. A player
    // named "%s" then made client_print_color re-format garbage cells, so
    // pass it as an argument instead.
    client_print_color(id, print_team_default, "%s", msg)
}
