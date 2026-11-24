#include <amxmodx>
#include <amxmisc>
#include <cstrike>
#include <engine>
#include <fakemeta>
#include <hamsandwich>
#include <nvault>
#include <menabp>
#include <freenova_vip>
#include <freenova_web>
#include <freenova_ui>
#include <fn_common>

native fn_hub_open(id)

#define PLUGIN_NAME    "FreeNova Cosmetics Economy"
#define PLUGIN_VERSION "1.0"
#define PLUGIN_AUTHOR  "FreeNova Dev"

#define MAX_PLAYERS    32

// Per-slot load flag: disconnect must not write zeroed defaults over a
// vault row if SteamID was still pending or load never completed.
new bool:g_bCosmeticsLoaded[MAX_PLAYERS + 1]

// Sprite Precache Indices
new g_sShockwave
new g_sLaserBeam
new g_sSmoke
new g_sGlassGibs

// Persistent Vault
new g_VaultCosmetics = INVALID_HANDLE
new g_szDataDir[256]

// Player Cosmetics State
new g_iSpawnEffect[MAX_PLAYERS + 1]    // 0=none, 1=neon_ring, 2=fire_aura, 3=lightning_spark, 4=shadow_void, 5=divine_light
new g_iChatTitle[MAX_PLAYERS + 1]      // 0=none, 1=godlike, 2=phantom, 3=warlord, 4=legend, 5=immortal
new g_iDeathEffect[MAX_PLAYERS + 1]    // 0=none, 1=lightning, 2=blood, 3=frost, 4=skull

// Bitmasks for owned items
new g_iOwnedSpawn[MAX_PLAYERS + 1]
new g_iOwnedTitles[MAX_PLAYERS + 1]
new g_iOwnedDeath[MAX_PLAYERS + 1]

// Custom In-Game Tags & Colored Chat (Skill)
new g_szCustomTag[MAX_PLAYERS + 1][32]
new bool:g_bCustomTagUnlocked[MAX_PLAYERS + 1]
new g_iOwnedPremadeTags[MAX_PLAYERS + 1]  // Bitmask for premade tags 1..8
new bool:g_bChatColorUnlocked[MAX_PLAYERS + 1]
new g_iChatColor[MAX_PLAYERS + 1] // 0=Yellow/Normal, 1=Green (^4), 2=Team Color (^3)

#define TAG_UNLOCK_COST 15000
#define CHAT_COLOR_SKILL_COST 8000
#define TASK_LATELOAD 46100

new g_iLateTries[MAX_PLAYERS + 1]

// Premade Pre-Set Tags (Cheaper Economy)
new const g_szPremadeTags[][] = {
    "",
    "[ FreeNova ]",
    "[ PRO ]",
    "[ BEAST ]",
    "[ CLUTCH ]",
    "[ ACE ]",
    "[ HEADSHOT ]",
    "[ ONE TAP ]",
    "[ VIP ]"
}

new const g_iPremadeTagCosts[] = {
    0,
    2500, // [ FreeNova ]
    3000, // [ PRO ]
    3000, // [ BEAST ]
    3500, // [ CLUTCH ]
    3500, // [ ACE ]
    4000, // [ HEADSHOT ]
    4000, // [ ONE TAP ]
    5000  // [ VIP ]
}
// Cosmetic Costs
new const g_iSpawnCosts[]  = { 0, 5000, 7500, 10000, 12000, 15000 }
new const g_iTitleCosts[]  = { 0, 3000, 5000, 7500, 10000, 15000, 20000, 18000, 15000, 12000, 14000, 25000, 16000 }
new const g_iDeathCosts[]  = { 0, 6000, 8000, 10000, 12000 }

// Title Prefix Strings (including CS2 Titles)
new const g_szTitles[][] = {
    "",
    "^4[ GODLIKE]",
    "^5[ PHANTOM]",
    "^3[ WARLORD]",
    "^4[ LEGEND]",
    "^4[ IMMORTAL]",
    "^4[ THE GLOBAL ELITE ]",
    "^5[ PREMIER MASTER ]",
    "^4[ SUPREME MASTER ]",
    "^4[ LEGENDARY EAGLE ]",
    "^3[ CLUTCH GOD ]",
    "^4[ MAJOR MVP ]",
    "^5[ AWP DEITY ]"
}

new const g_szSpawnNames[][] = {
    "None", "Neon Energy Ring", "Blazing Fire Aura", "Thunder Spark Halo", "Shadow Void Ring", "Divine Angelic Beacon"
}

new const g_szTitleNames[][] = {
    "None",
    "[ GODLIKE]",
    "[ PHANTOM]",
    "[ WARLORD]",
    "[ LEGEND]",
    "[ IMMORTAL]",
    "[ THE GLOBAL ELITE ]",
    "[ PREMIER MASTER ]",
    "[ SUPREME MASTER ]",
    "[ LEGENDARY EAGLE ]",
    "[ CLUTCH GOD ]",
    "[ MAJOR MVP ]",
    "[ AWP DEITY ]"
}

new const g_szDeathNames[][] = {
    "None", "Sky Lightning Bolt", "Crimson Blood Burst", "Glacial Frost Shatter", "Ascending Skull Ghost"
}

new g_msgSayText

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
    return 1
}

public plugin_precache()
{
    g_sShockwave = precache_model("sprites/shockwave.spr")
    g_sLaserBeam = precache_model("sprites/laserbeam.spr")
    g_sSmoke     = precache_model("sprites/steam1.spr")
    g_sGlassGibs = precache_model("models/glassgibs.mdl")

    precache_sound("ambience/thunder_clap.wav")
    precache_sound("items/suitchargeno1.wav")
    precache_sound("debris/glass1.wav")
}

public CosmeticsNativeFilter(const name[], index, trap)
{
    if(equal(name, "fn_hub_open"))
        return PLUGIN_HANDLED
    return PLUGIN_CONTINUE
}

public plugin_natives()
{
    set_native_filter("CosmeticsNativeFilter")
    register_library("freenova_cosmetics")
    register_native("fncosmetics_get_spawn", "_native_get_spawn")
    register_native("fncosmetics_get_title", "_native_get_title")
    register_native("fncosmetics_get_death", "_native_get_death")
    register_native("fncosmetics_open_shop", "_native_open_shop")
    register_native("fncosmetics_get_tag", "_native_get_tag")
    register_native("fncosmetics_get_color", "_native_get_color")
    register_native("fncosmetics_set_tag", "_native_set_tag")
    register_native("fncosmetics_clear_tag", "_native_clear_tag")
    register_native("fncosmetics_has_tag_license", "_native_has_tag_license")
    register_native("fncosmetics_unlock_spawn", "_native_unlock_spawn")
    register_native("fncosmetics_unlock_title", "_native_unlock_title")
    register_native("fncosmetics_grant_tag_license", "_native_grant_tag_license")
    register_native("fncosmetics_grant_chat_color", "_native_grant_chat_color")
    register_native("fncosmetics_get_spawn_name", "_native_get_spawn_name")
    register_native("fncosmetics_get_title_name", "_native_get_title_name")
    register_native("fncosmetics_get_death_name", "_native_get_death_name")
}

public _native_set_tag(plugin, params)
{
    new id = get_param(1)
    if(!(1 <= id <= MAX_PLAYERS))
        return 0
    if(!g_bCustomTagUnlocked[id])
        return 0
    new szTag[32]
    get_string(2, szTag, charsmax(szTag))
    SetPlayerTagString(id, szTag)
    SaveCustomTagData(id)
    return 1
}

public bool:_native_has_tag_license(plugin, params)
{
    new id = get_param(1)
    return (1 <= id <= MAX_PLAYERS) ? g_bCustomTagUnlocked[id] : false
}

public _native_unlock_spawn(plugin, params)
{
    new id = get_param(1)
    new spawn_id = get_param(2)
    if(!(1 <= id <= MAX_PLAYERS) || !is_user_connected(id) || !(1 <= spawn_id <= 5))
        return 0

    if(!g_bCosmeticsLoaded[id])
        LoadCosmetics(id)

    g_iOwnedSpawn[id] |= (1 << spawn_id)
    if(g_iSpawnEffect[id] == 0)
        g_iSpawnEffect[id] = spawn_id
    SaveCosmetics(id)
    return 1
}

public _native_unlock_title(plugin, params)
{
    new id = get_param(1)
    new title_id = get_param(2)
    if(!(1 <= id <= MAX_PLAYERS) || !is_user_connected(id) || !(1 <= title_id <= 12))
        return 0

    if(!g_bCosmeticsLoaded[id])
        LoadCosmetics(id)

    g_iOwnedTitles[id] |= (1 << title_id)
    if(g_iChatTitle[id] == 0)
        g_iChatTitle[id] = title_id
    SaveCosmetics(id)
    return 1
}

public _native_grant_tag_license(plugin, params)
{
    new id = get_param(1)
    if(!(1 <= id <= MAX_PLAYERS) || !is_user_connected(id))
        return 0

    if(!g_bCosmeticsLoaded[id])
        LoadCosmetics(id)

    g_bCustomTagUnlocked[id] = true
    SaveCustomTagData(id)
    return 1
}

public _native_grant_chat_color(plugin, params)
{
    new id = get_param(1)
    if(!(1 <= id <= MAX_PLAYERS) || !is_user_connected(id))
        return 0

    if(!g_bCosmeticsLoaded[id])
        LoadCosmetics(id)

    g_bChatColorUnlocked[id] = true
    if(g_iChatColor[id] == 0)
        g_iChatColor[id] = 1
    SaveCustomTagData(id)
    return 1
}

public _native_clear_tag(plugin, params)
{
    new id = get_param(1)
    if(1 <= id <= MAX_PLAYERS)
    {
        g_szCustomTag[id][0] = 0
        SaveCustomTagData(id)
        return 1
    }
    return 0
}

public _native_get_spawn(plugin, params)
{
    new id = get_param(1)
    if(1 <= id <= MAX_PLAYERS)
        return g_iSpawnEffect[id]
    return 0
}

public _native_get_title(plugin, params)
{
    new id = get_param(1)
    if(1 <= id <= MAX_PLAYERS)
        return g_iChatTitle[id]
    return 0
}

public _native_get_death(plugin, params)
{
    new id = get_param(1)
    if(1 <= id <= MAX_PLAYERS)
        return g_iDeathEffect[id]
    return 0
}

public _native_open_shop(plugin, params)
{
    new id = get_param(1)
    if(1 <= id <= MAX_PLAYERS)
        return Cmd_OpenCosmetics(id)
    return 0
}

public _native_get_tag(plugin, params)
{
    new id = get_param(1)
    if(1 <= id <= MAX_PLAYERS)
    {
        set_string(2, g_szCustomTag[id], get_param(3))
        return 1
    }
    return 0
}

public _native_get_color(plugin, params)
{
    new id = get_param(1)
    if(1 <= id <= MAX_PLAYERS)
        return g_iChatColor[id]
    return 0
}

public _native_get_spawn_name(plugin, params)
{
    new id = get_param(1)
    new i = (1 <= id <= MAX_PLAYERS) ? g_iSpawnEffect[id] : 0
    if(i < 0 || i >= sizeof(g_szSpawnNames)) i = 0
    set_string(2, g_szSpawnNames[i], get_param(3))
    return 1
}

public _native_get_title_name(plugin, params)
{
    new id = get_param(1)
    new i = (1 <= id <= MAX_PLAYERS) ? g_iChatTitle[id] : 0
    if(i < 0 || i >= sizeof(g_szTitleNames)) i = 0
    set_string(2, g_szTitleNames[i], get_param(3))
    return 1
}

public _native_get_death_name(plugin, params)
{
    new id = get_param(1)
    new i = (1 <= id <= MAX_PLAYERS) ? g_iDeathEffect[id] : 0
    if(i < 0 || i >= sizeof(g_szDeathNames)) i = 0
    set_string(2, g_szDeathNames[i], get_param(3))
    return 1
}

public plugin_init()
{
    fn_boot_banner("cosmetics", 42)

    register_plugin(PLUGIN_NAME, PLUGIN_VERSION, PLUGIN_AUTHOR)

    RegisterHam(Ham_Spawn, "player", "Hook_PlayerSpawn", 1)
    RegisterHam(Ham_Killed, "player", "Hook_PlayerKilled", 1)

    register_clcmd("say", "Cmd_Say")
    register_clcmd("say_team", "Cmd_SayTeam")

    register_clcmd("say /cosmetics", "Cmd_OpenCosmetics")
    register_clcmd("say_team /cosmetics", "Cmd_OpenCosmetics")
    register_clcmd("say /effects", "Cmd_OpenCosmetics")
    register_clcmd("say_team /effects", "Cmd_OpenCosmetics")
    register_clcmd("say /titles", "Cmd_OpenCosmetics")
    register_clcmd("say_team /titles", "Cmd_OpenCosmetics")

    register_clcmd("say /cosmeticsmenu", "Cmd_CosmeticsMenu")
    register_clcmd("say_team /cosmeticsmenu", "Cmd_CosmeticsMenu")

    // Custom Tags & Chat Colors
    register_clcmd("say /tag", "Cmd_TagMenu")
    register_clcmd("say_team /tag", "Cmd_TagMenu")
    register_clcmd("say /mytag", "Cmd_TagMenu")
    register_clcmd("say_team /mytag", "Cmd_TagMenu")
    register_clcmd("say /color", "Cmd_ColorMenu")
    register_clcmd("say_team /color", "Cmd_ColorMenu")
    register_clcmd("say /chatcolor", "Cmd_ColorMenu")
    register_clcmd("say_team /chatcolor", "Cmd_ColorMenu")
    register_concmd("fn_set_tag", "Cmd_AdminSetTag", ADMIN_BAN, "<name/steamid> <tag>")

    register_concmd("fn_buy_cosmetic", "Cmd_BuyCosmetic")
    register_concmd("fn_equip_cosmetic", "Cmd_EquipCosmetic")
    register_concmd("fn_set_mytag", "Cmd_SetMyTag")
    register_concmd("fn_buy_tag", "Cmd_BuyTag")
    register_concmd("fn_equip_tag", "Cmd_EquipTag")

    g_msgSayText   = get_user_msgid("SayText")

    get_datadir(g_szDataDir, charsmax(g_szDataDir))
    add(g_szDataDir, charsmax(g_szDataDir), "/freenova_cosmetics")
    if(!dir_exists(g_szDataDir))
        mkdir(g_szDataDir)

    g_VaultCosmetics = nvault_open("freenova_cosmetics")
}

public plugin_end()
{
    new iPlayers[MAX_PLAYERS], iNum
    get_players(iPlayers, iNum, "ch")
    for(new i = 0; i < iNum; i++)
    {
        if(g_bCosmeticsLoaded[iPlayers[i]])
            SaveCosmetics(iPlayers[i])
    }
    if(g_VaultCosmetics != INVALID_HANDLE)
        nvault_close(g_VaultCosmetics)
}

public client_putinserver(id)
{
    remove_task(id + TASK_LATELOAD)
    g_bCosmeticsLoaded[id] = false
    g_iLateTries[id] = 0
    g_iSpawnEffect[id] = 0
    g_iChatTitle[id]   = 0
    g_iDeathEffect[id] = 0
    g_iOwnedSpawn[id]  = 0
    g_iOwnedTitles[id] = 0
    g_iOwnedDeath[id]  = 0
    g_szCustomTag[id][0] = 0
    g_bCustomTagUnlocked[id] = false
    g_iOwnedPremadeTags[id] = 0
    g_bChatColorUnlocked[id] = false
    g_iChatColor[id]   = 0

    if(is_user_bot(id))
        return

    LoadCosmetics(id)
    if(!g_bCosmeticsLoaded[id])
        set_task(3.0, "Task_LateLoadCosmetics", id + TASK_LATELOAD)
}

public Task_LateLoadCosmetics(taskid)
{
    new id = taskid - TASK_LATELOAD
    if(!is_user_connected(id) || is_user_bot(id) || g_bCosmeticsLoaded[id])
        return

    LoadCosmetics(id)
    if(!g_bCosmeticsLoaded[id] && g_iLateTries[id] < 3)
    {
        g_iLateTries[id]++
        set_task(3.0, "Task_LateLoadCosmetics", id + TASK_LATELOAD)
    }
}

public client_disconnected(id)
{
    remove_task(id + TASK_LATELOAD)
    if(g_bCosmeticsLoaded[id])
        SaveCosmetics(id)
    g_bCosmeticsLoaded[id] = false
}

stock bool:CosmeticsReady(id)
{
    if(g_bCosmeticsLoaded[id])
        return true
    client_printcolor(id, "!g[FreeNova] !n Cosmetics are still loading. Try again in a moment.")
    return false
}

stock bool:CosmeticsDebitCoins(id, cost)
{
    if(cost <= 0)
        return false
    // Fail-closed: no battlepass provider means no balance ledger to debit.
    // Guard before touching any menabp_* native (exact debit semantics below).
    if(!LibraryExists("menabp", LibType_Library))
    {
        client_printcolor(id, "!g[FreeNova] !n Coin shop is not available right now.")
        return false
    }
    new iBefore = menabp_get_coins(id)
    if(iBefore < cost)
    {
        client_printcolor(id, "!g[FreeNova] !n You need !g%d !nCoins (you have !t%d!n).", cost, iBefore)
        return false
    }
    new iAfter = menabp_add_coins(id, -cost)
    if(iAfter == 0 && menabp_get_coins(id) >= iBefore)
    {
        client_printcolor(id, "!g[FreeNova] !n Purchase failed. Coin shop is still loading.")
        return false
    }
    if(menabp_get_coins(id) > iBefore - cost)
    {
        client_printcolor(id, "!g[FreeNova] !n Purchase failed. Coin shop is still loading.")
        return false
    }
    return true
}

// -------------------------------------------------------------
// SPAWN EFFECTS
// -------------------------------------------------------------
public Hook_PlayerSpawn(id)
{
    if(!is_user_alive(id) || !g_iSpawnEffect[id])
        return HAM_IGNORED

    new Float:vOrigin[3], iOrigin[3]
    entity_get_vector(id, EV_VEC_origin, vOrigin)
    FVecIVec(vOrigin, iOrigin)

    switch(g_iSpawnEffect[id])
    {
        case 1: // Neon Energy Ring (expanding green cylinder)
        {
            message_begin(MSG_PVS, SVC_TEMPENTITY, iOrigin)
            write_byte(TE_BEAMCYLINDER)
            write_coord(iOrigin[0])
            write_coord(iOrigin[1])
            write_coord(iOrigin[2] - 15)
            write_coord(iOrigin[0])
            write_coord(iOrigin[1])
            write_coord(iOrigin[2] + 280) // radius
            write_short(g_sShockwave)
            write_byte(0)    // start frame
            write_byte(0)    // framerate
            write_byte(12)   // life
            write_byte(35)   // width
            write_byte(0)    // noise
            write_byte(34)   // r
            write_byte(197)  // g (neon green)
            write_byte(94)   // b
            write_byte(220)  // brightness
            write_byte(0)    // speed
            message_end()
        }
        case 2: // Blazing Fire Aura (red/orange fiery cylinder + sparks)
        {
            message_begin(MSG_PVS, SVC_TEMPENTITY, iOrigin)
            write_byte(TE_BEAMCYLINDER)
            write_coord(iOrigin[0])
            write_coord(iOrigin[1])
            write_coord(iOrigin[2] - 15)
            write_coord(iOrigin[0])
            write_coord(iOrigin[1])
            write_coord(iOrigin[2] + 220)
            write_short(g_sShockwave)
            write_byte(0); write_byte(0); write_byte(10); write_byte(40); write_byte(0)
            write_byte(239); write_byte(68); write_byte(68); write_byte(240); write_byte(0)
            message_end()

            message_begin(MSG_PVS, SVC_TEMPENTITY, iOrigin)
            write_byte(TE_SPARKS)
            write_coord(iOrigin[0])
            write_coord(iOrigin[1])
            write_coord(iOrigin[2] + 10)
            message_end()
        }
        case 3: // Thunder Spark Halo (cyan/electric discharge)
        {
            message_begin(MSG_PVS, SVC_TEMPENTITY, iOrigin)
            write_byte(TE_BEAMCYLINDER)
            write_coord(iOrigin[0])
            write_coord(iOrigin[1])
            write_coord(iOrigin[2] - 15)
            write_coord(iOrigin[0])
            write_coord(iOrigin[1])
            write_coord(iOrigin[2] + 260)
            write_short(g_sShockwave)
            write_byte(0); write_byte(0); write_byte(12); write_byte(30); write_byte(0)
            write_byte(56); write_byte(189); write_byte(248); write_byte(240); write_byte(0)
            message_end()

            message_begin(MSG_PVS, SVC_TEMPENTITY, iOrigin)
            write_byte(TE_SPARKS)
            write_coord(iOrigin[0])
            write_coord(iOrigin[1])
            write_coord(iOrigin[2] + 15)
            message_end()
        }
        case 4: // Shadow Void (purple/dark dimensional wave)
        {
            message_begin(MSG_PVS, SVC_TEMPENTITY, iOrigin)
            write_byte(TE_BEAMCYLINDER)
            write_coord(iOrigin[0])
            write_coord(iOrigin[1])
            write_coord(iOrigin[2] - 15)
            write_coord(iOrigin[0])
            write_coord(iOrigin[1])
            write_coord(iOrigin[2] + 300)
            write_short(g_sShockwave)
            write_byte(0); write_byte(0); write_byte(15); write_byte(45); write_byte(0)
            write_byte(139); write_byte(92); write_byte(246); write_byte(250); write_byte(0)
            message_end()
        }
        case 5: // Divine Angelic Beacon (golden pillar of light + aura)
        {
            message_begin(MSG_PVS, SVC_TEMPENTITY, iOrigin)
            write_byte(TE_BEAMPOINTS)
            write_coord(iOrigin[0])
            write_coord(iOrigin[1])
            write_coord(iOrigin[2] + 500)
            write_coord(iOrigin[0])
            write_coord(iOrigin[1])
            write_coord(iOrigin[2] - 20)
            write_short(g_sLaserBeam)
            write_byte(0); write_byte(0); write_byte(14); write_byte(70); write_byte(0)
            write_byte(251); write_byte(191); write_byte(36); write_byte(255); write_byte(0)
            message_end()

            message_begin(MSG_PVS, SVC_TEMPENTITY, iOrigin)
            write_byte(TE_BEAMCYLINDER)
            write_coord(iOrigin[0]); write_coord(iOrigin[1]); write_coord(iOrigin[2] - 15)
            write_coord(iOrigin[0]); write_coord(iOrigin[1]); write_coord(iOrigin[2] + 320)
            write_short(g_sShockwave)
            write_byte(0); write_byte(0); write_byte(14); write_byte(40); write_byte(0)
            write_byte(251); write_byte(191); write_byte(36); write_byte(240); write_byte(0)
            message_end()
        }
    }
    return HAM_IGNORED
}

// -------------------------------------------------------------
// DEATH EFFECTS
// -------------------------------------------------------------
public Hook_PlayerKilled(victim, killer, shouldgib)
{
    if(!is_user_connected(killer) || !is_user_connected(victim) || killer == victim)
        return HAM_IGNORED

    new iDeath = g_iDeathEffect[killer]
    if(!iDeath)
        return HAM_IGNORED

    new Float:vOrigin[3], iOrigin[3]
    entity_get_vector(victim, EV_VEC_origin, vOrigin)
    FVecIVec(vOrigin, iOrigin)

    switch(iDeath)
    {
        case 1: // Sky Lightning Bolt Strike
        {
            message_begin(MSG_PVS, SVC_TEMPENTITY, iOrigin)
            write_byte(TE_BEAMPOINTS)
            write_coord(iOrigin[0])
            write_coord(iOrigin[1])
            write_coord(iOrigin[2] + 600)
            write_coord(iOrigin[0])
            write_coord(iOrigin[1])
            write_coord(iOrigin[2] + 10)
            write_short(g_sLaserBeam)
            write_byte(0); write_byte(0); write_byte(8); write_byte(50); write_byte(15)
            write_byte(139); write_byte(92); write_byte(246); write_byte(255); write_byte(0)
            message_end()

            emit_sound(victim, CHAN_STATIC, "ambience/thunder_clap.wav", 1.0, ATTN_NORM, 0, PITCH_NORM)
        }
        case 2: // Crimson Blood Burst
        {
            message_begin(MSG_PVS, SVC_TEMPENTITY, iOrigin)
            write_byte(TE_BLOODSTREAM)
            write_coord(iOrigin[0]); write_coord(iOrigin[1]); write_coord(iOrigin[2] + 20)
            write_coord(0); write_coord(0); write_coord(250) // vector up
            write_byte(70) // color red
            write_byte(180) // speed
            message_end()
        }
        case 3: // Glacial Frost Shatter
        {
            message_begin(MSG_PVS, SVC_TEMPENTITY, iOrigin)
            write_byte(TE_BREAKMODEL)
            write_coord(iOrigin[0]); write_coord(iOrigin[1]); write_coord(iOrigin[2] + 20)
            write_coord(24); write_coord(24); write_coord(32) // size
            write_coord(random_num(-60, 60)); write_coord(random_num(-60, 60)); write_coord(random_num(50, 150)) // velocity
            write_byte(10); write_short(g_sGlassGibs); write_byte(30); write_byte(25)
            write_byte(1) // BREAK_GLASS
            message_end()

            emit_sound(victim, CHAN_STATIC, "debris/glass1.wav", 1.0, ATTN_NORM, 0, PITCH_NORM)
        }
        case 4: // Ascending Skull Ghost / Smoke
        {
            message_begin(MSG_PVS, SVC_TEMPENTITY, iOrigin)
            write_byte(TE_SMOKE)
            write_coord(iOrigin[0]); write_coord(iOrigin[1]); write_coord(iOrigin[2] + 15)
            write_short(g_sSmoke)
            write_byte(35) // scale
            write_byte(10) // framerate
            message_end()
        }
    }
    return HAM_IGNORED
}

bool:HasChatColorAccess(id)
{
    if(!is_user_connected(id))
        return false

    if(get_user_flags(id) & (ADMIN_IMMUNITY | ADMIN_BAN | ADMIN_RCON))
        return true

    if(g_bChatColorUnlocked[id])
        return true

    if(menabp_get_skill_stage(id, SKILL_CHAT_COLOR) >= 1)
    {
        g_bChatColorUnlocked[id] = true
        return true
    }

    return false
}

// -------------------------------------------------------------
// CHAT TITLES HOOK
// -------------------------------------------------------------
public Cmd_Say(id)
{
    return HandleCustomChat(id, false)
}

public Cmd_SayTeam(id)
{
    return HandleCustomChat(id, true)
}

HandleCustomChat(id, bool:bTeam)
{
    if(!is_user_connected(id))
        return PLUGIN_CONTINUE

    new szMessage[192]
    read_args(szMessage, charsmax(szMessage))
    remove_quotes(szMessage)
    trim(szMessage)

    if(!szMessage[0])
        return PLUGIN_CONTINUE

    // 1. Direct command passthrough: /tag <text>
    if(equal(szMessage, "/tag ", 5) || equal(szMessage, "/mytag ", 7))
    {
        new szArg[32]
        copy(szArg, charsmax(szArg), szMessage[equal(szMessage, "/tag ", 5) ? 5 : 7])
        trim(szArg)
        SetPlayerTagString(id, szArg)
        return PLUGIN_HANDLED
    }

    // 2. Pure commands starting with '/', '!', '.', ',', '@', '#' pass untouched
    if(szMessage[0] == '/' || szMessage[0] == '!' || szMessage[0] == '.' || szMessage[0] == ',' || szMessage[0] == '@' || szMessage[0] == '#')
        return PLUGIN_CONTINUE

    new bool:bAlive = bool:is_user_alive(id)
    new CsTeams:senderTeam = cs_get_user_team(id)

    // Validate chat color permission against skill
    new iActiveColor = g_iChatColor[id]
    if(iActiveColor > 0 && !HasChatColorAccess(id))
    {
        iActiveColor = 0
        g_iChatColor[id] = 0
    }

    // Check if player has any custom tag, title, VIP, custom color, or admin tag
    new bool:bHasCustomFormatting = false
    if(g_szCustomTag[id][0] || g_iChatTitle[id] || iActiveColor > 0)
        bHasCustomFormatting = true
    if(LibraryExists("freenova_vip", LibType_Library) && fnvip_get_tier(id) >= FNVIP_VIP)
        bHasCustomFormatting = true
    if(get_user_flags(id) & (ADMIN_IMMUNITY | ADMIN_BAN | ADMIN_RCON))
        bHasCustomFormatting = true

    if(!bHasCustomFormatting)
        return PLUGIN_CONTINUE

    // Build Tag String
    new szTag[48]
    if(g_szCustomTag[id][0])
    {
        formatex(szTag, charsmax(szTag), "^4%s ", g_szCustomTag[id])
    }
    else if(g_iChatTitle[id])
    {
        formatex(szTag, charsmax(szTag), "%s ", g_szTitles[g_iChatTitle[id]])
    }
    else if(LibraryExists("freenova_vip", LibType_Library) && fnvip_get_tier(id) >= FNVIP_VIP)
    {
        new szVipName[32]
        fnvip_get_tier_name(id, szVipName, charsmax(szVipName))
        formatex(szTag, charsmax(szTag), "^4[%s] ", szVipName)
    }
    else if(get_user_flags(id) & (ADMIN_IMMUNITY | ADMIN_RCON))
    {
        copy(szTag, charsmax(szTag), "^4[OWNER] ")
    }
    else if(get_user_flags(id) & ADMIN_BAN)
    {
        copy(szTag, charsmax(szTag), "^4[ADMIN] ")
    }

    new szName[32]
    get_user_name(id, szName, charsmax(szName))

    // Build Formatted Message with Player's Chosen Color
    new szFormatted[256]
    new szColorCode[4]
    if(iActiveColor == 1) copy(szColorCode, charsmax(szColorCode), "^4")       // Green chat
    else if(iActiveColor == 2) copy(szColorCode, charsmax(szColorCode), "^3")  // Team color chat
    else copy(szColorCode, charsmax(szColorCode), "^1")                           // Default yellow chat

    if(!bTeam)
    {
        if(senderTeam == CS_TEAM_SPECTATOR || senderTeam == CS_TEAM_UNASSIGNED)
            formatex(szFormatted, charsmax(szFormatted), "^1*SPEC* %s^3%s^1 :  %s%s", szTag, szName, szColorCode, szMessage)
        else if(!bAlive)
            formatex(szFormatted, charsmax(szFormatted), "^1*DEAD* %s^3%s^1 :  %s%s", szTag, szName, szColorCode, szMessage)
        else
            formatex(szFormatted, charsmax(szFormatted), "%s^3%s^1 :  %s%s", szTag, szName, szColorCode, szMessage)
    }
    else
    {
        if(senderTeam == CS_TEAM_SPECTATOR || senderTeam == CS_TEAM_UNASSIGNED)
            formatex(szFormatted, charsmax(szFormatted), "^1(Spectator) %s^3%s^1 :  %s%s", szTag, szName, szColorCode, szMessage)
        else if(senderTeam == CS_TEAM_T)
        {
            if(!bAlive)
                formatex(szFormatted, charsmax(szFormatted), "^1*DEAD*(Terrorist) %s^3%s^1 :  %s%s", szTag, szName, szColorCode, szMessage)
            else
                formatex(szFormatted, charsmax(szFormatted), "^1(Terrorist) %s^3%s^1 :  %s%s", szTag, szName, szColorCode, szMessage)
        }
        else
        {
            if(!bAlive)
                formatex(szFormatted, charsmax(szFormatted), "^1*DEAD*(Counter-Terrorist) %s^3%s^1 :  %s%s", szTag, szName, szColorCode, szMessage)
            else
                formatex(szFormatted, charsmax(szFormatted), "^1(Counter-Terrorist) %s^3%s^1 :  %s%s", szTag, szName, szColorCode, szMessage)
        }
    }

    // Broadcast respecting alltalk and team rules
    new iPlayers[32], iNum
    get_players(iPlayers, iNum, "ch")
    new bool:bAllTalk = bool:(get_cvar_num("sv_alltalk") == 1)

    for(new i = 0; i < iNum; i++)
    {
        new target = iPlayers[i]
        new bool:bTargetAlive = bool:is_user_alive(target)
        new CsTeams:targetTeam = cs_get_user_team(target)

        if(bTeam && targetTeam != senderTeam)
            continue

        if(!bAlive && bTargetAlive && !bAllTalk)
            continue

        message_begin(MSG_ONE_UNRELIABLE, g_msgSayText, _, target)
        write_byte(id)
        write_string(szFormatted)
        message_end()
    }

    return PLUGIN_HANDLED
}

// -------------------------------------------------------------
// OPEN COSMETICS MENU (in-game only — store MOTD retired)
// -------------------------------------------------------------
public Cmd_OpenCosmetics(id)
{
    if(!is_user_connected(id))
        return PLUGIN_HANDLED
    Cmd_CosmeticsMenu(id)
    return PLUGIN_HANDLED
}

// -------------------------------------------------------------
// IN-GAME COSMETICS MANAGEMENT MENU
// -------------------------------------------------------------
public Cmd_CosmeticsMenu(id)
{
    if(!is_user_connected(id))
        return PLUGIN_HANDLED

    new szTitle[64]
    FN_MenuTitle(szTitle, charsmax(szTitle), "Cosmetics", menabp_get_coins(id))
    new menu = menu_create(szTitle, "CosmeticsMenuHandler")

    menu_additem(menu, fmt("\wSpawn \d- %s", g_szSpawnNames[g_iSpawnEffect[id]]), "1")
    menu_additem(menu, fmt("\wTitle \d- %s", g_szTitleNames[g_iChatTitle[id]]), "2")
    menu_additem(menu, fmt("\wDeath \d- %s", g_szDeathNames[g_iDeathEffect[id]]), "3")
    if(g_szCustomTag[id][0])
        menu_additem(menu, fmt("\wTags \d- %s", g_szCustomTag[id]), "4")
    else
        menu_additem(menu, "\wTags \d- none", "4")

    FN_MenuFinish(menu, true)
    menu_display(id, menu, 0)
    return PLUGIN_HANDLED
}

public CosmeticsMenuHandler(id, menu, item)
{
    if(item == MENU_EXIT)
    {
        menu_destroy(menu)
        fn_hub_open(id)
        return PLUGIN_HANDLED
    }

    new data[6], name[64], access, callback
    menu_item_getinfo(menu, item, access, data, charsmax(data), name, charsmax(name), callback)
    menu_destroy(menu)

    switch(str_to_num(data))
    {
        case 1: ShowSpawnEffectsMenu(id)
        case 2: ShowChatTitlesMenu(id)
        case 3: ShowDeathEffectsMenu(id)
        case 4: Cmd_TagMenu(id)
    }
    return PLUGIN_HANDLED
}

ShowSpawnEffectsMenu(id)
{
    new szTitle[64]
    FN_MenuTitle(szTitle, charsmax(szTitle), "Spawn effect")
    new menu = menu_create(szTitle, "SpawnMenuHandler")
    menu_additem(menu, g_iSpawnEffect[id] == 0 ? "\yNone \r(ON)" : "\wNone", "0")
    for(new i = 1; i <= 5; i++)
    {
        new bool:bOwned = bool:(g_iOwnedSpawn[id] & (1 << i))
        new bool:bEquipped = (g_iSpawnEffect[id] == i)
        new szItem[96]
        if(bEquipped)
            formatex(szItem, charsmax(szItem), "\y%s \r(ON)", g_szSpawnNames[i])
        else if(bOwned)
            formatex(szItem, charsmax(szItem), "\w%s \d[OWNED]", g_szSpawnNames[i])
        else
            formatex(szItem, charsmax(szItem), "\d%s \r[%dc]", g_szSpawnNames[i], g_iSpawnCosts[i])

        menu_additem(menu, szItem, fmt("%d", i))
    }
    FN_MenuFinish(menu, true)
    menu_display(id, menu, 0)
}

public SpawnMenuHandler(id, menu, item)
{
    if(item == MENU_EXIT)
    {
        menu_destroy(menu)
        Cmd_CosmeticsMenu(id)
        return PLUGIN_HANDLED
    }
    new data[6], name[64], access, callback
    menu_item_getinfo(menu, item, access, data, charsmax(data), name, charsmax(name), callback)
    menu_destroy(menu)
    new iChoice = str_to_num(data)
    if(iChoice == 0)
    {
        g_iSpawnEffect[id] = 0
        client_printcolor(id, "!g[FreeNova] !n Spawn effect unequipped.")
        SaveCosmetics(id)
        ShowSpawnEffectsMenu(id)
        return PLUGIN_HANDLED
    }
    if(g_iOwnedSpawn[id] & (1 << iChoice))
    {
        g_iSpawnEffect[id] = iChoice
        client_printcolor(id, "!g[FreeNova] !n Equipped spawn effect: !g%s!n", g_szSpawnNames[iChoice])
        emit_sound(id, CHAN_ITEM, "items/suitchargeno1.wav", 1.0, ATTN_NORM, 0, PITCH_NORM)
        SaveCosmetics(id)
        ShowSpawnEffectsMenu(id)
        return PLUGIN_HANDLED
    }
    if(!CosmeticsReady(id))
        return PLUGIN_HANDLED
    new cost = g_iSpawnCosts[iChoice]
    if(menabp_get_coins(id) < cost)
    {
        client_printcolor(id, "!g[FreeNova] !n You need !g%d !nCoins to unlock this effect.", cost)
        ShowSpawnEffectsMenu(id)
        return PLUGIN_HANDLED
    }
    if(!CosmeticsDebitCoins(id, cost))
        return PLUGIN_HANDLED
    g_iOwnedSpawn[id] |= (1 << iChoice)
    g_iSpawnEffect[id] = iChoice
    client_printcolor(id, "!g[FreeNova] !n Unlocked and equipped !g%s!n (-%d Coins)", g_szSpawnNames[iChoice], cost)
    emit_sound(id, CHAN_ITEM, "items/suitchargeno1.wav", 1.0, ATTN_NORM, 0, PITCH_NORM)
    SaveCosmetics(id)
    ShowSpawnEffectsMenu(id)
    return PLUGIN_HANDLED
}

ShowChatTitlesMenu(id)
{
    new szTitle[64]
    FN_MenuTitle(szTitle, charsmax(szTitle), "Chat title")
    new menu = menu_create(szTitle, "TitleMenuHandler")
    menu_additem(menu, g_iChatTitle[id] == 0 ? "\yNone \r(ON)" : "\wNone", "0")
    for(new i = 1; i <= 12; i++)
    {
        new bool:bOwned = bool:(g_iOwnedTitles[id] & (1 << i))
        new bool:bEquipped = (g_iChatTitle[id] == i)
        new szItem[96]
        if(bEquipped)
            formatex(szItem, charsmax(szItem), "\y%s \r(ON)", g_szTitleNames[i])
        else if(bOwned)
            formatex(szItem, charsmax(szItem), "\w%s \d[OWNED]", g_szTitleNames[i])
        else
            formatex(szItem, charsmax(szItem), "\d%s \r[%dc]", g_szTitleNames[i], g_iTitleCosts[i])

        menu_additem(menu, szItem, fmt("%d", i))
    }
    FN_MenuFinish(menu, true)
    menu_display(id, menu, 0)
}

public TitleMenuHandler(id, menu, item)
{
    if(item == MENU_EXIT)
    {
        menu_destroy(menu)
        Cmd_CosmeticsMenu(id)
        return PLUGIN_HANDLED
    }
    new data[6], name[64], access, callback
    menu_item_getinfo(menu, item, access, data, charsmax(data), name, charsmax(name), callback)
    menu_destroy(menu)
    new iChoice = str_to_num(data)
    if(iChoice == 0)
    {
        g_iChatTitle[id] = 0
        client_printcolor(id, "!g[FreeNova] !n Chat title unequipped.")
        SaveCosmetics(id)
        ShowChatTitlesMenu(id)
        return PLUGIN_HANDLED
    }
    if(g_iOwnedTitles[id] & (1 << iChoice))
    {
        g_iChatTitle[id] = iChoice
        client_printcolor(id, "!g[FreeNova] !n Active chat title: !g%s!n", g_szTitleNames[iChoice])
        SaveCosmetics(id)
        ShowChatTitlesMenu(id)
        return PLUGIN_HANDLED
    }
    if(!CosmeticsReady(id))
        return PLUGIN_HANDLED
    new cost = g_iTitleCosts[iChoice]
    if(menabp_get_coins(id) < cost)
    {
        client_printcolor(id, "!g[FreeNova] !n You need !g%d !nCoins to unlock this title.", cost)
        ShowChatTitlesMenu(id)
        return PLUGIN_HANDLED
    }
    if(!CosmeticsDebitCoins(id, cost))
        return PLUGIN_HANDLED
    g_iOwnedTitles[id] |= (1 << iChoice)
    g_iChatTitle[id] = iChoice
    client_printcolor(id, "!g[FreeNova] !n Unlocked and equipped !g%s!n (-%d Coins)", g_szTitleNames[iChoice], cost)
    SaveCosmetics(id)
    ShowChatTitlesMenu(id)
    return PLUGIN_HANDLED
}

ShowDeathEffectsMenu(id)
{
    new szTitle[64]
    FN_MenuTitle(szTitle, charsmax(szTitle), "Death effect")
    new menu = menu_create(szTitle, "DeathMenuHandler")
    menu_additem(menu, g_iDeathEffect[id] == 0 ? "\yNone \r(ON)" : "\wNone", "0")
    for(new i = 1; i <= 4; i++)
    {
        new bool:bOwned = bool:(g_iOwnedDeath[id] & (1 << i))
        new bool:bEquipped = (g_iDeathEffect[id] == i)
        new szItem[96]
        if(bEquipped)
            formatex(szItem, charsmax(szItem), "\y%s \r(ON)", g_szDeathNames[i])
        else if(bOwned)
            formatex(szItem, charsmax(szItem), "\w%s \d[OWNED]", g_szDeathNames[i])
        else
            formatex(szItem, charsmax(szItem), "\d%s \r[%dc]", g_szDeathNames[i], g_iDeathCosts[i])

        menu_additem(menu, szItem, fmt("%d", i))
    }
    FN_MenuFinish(menu, true)
    menu_display(id, menu, 0)
}

public DeathMenuHandler(id, menu, item)
{
    if(item == MENU_EXIT)
    {
        menu_destroy(menu)
        Cmd_CosmeticsMenu(id)
        return PLUGIN_HANDLED
    }
    new data[6], name[64], access, callback
    menu_item_getinfo(menu, item, access, data, charsmax(data), name, charsmax(name), callback)
    menu_destroy(menu)
    new iChoice = str_to_num(data)
    if(iChoice == 0)
    {
        g_iDeathEffect[id] = 0
        client_printcolor(id, "!g[FreeNova] !n Death effect unequipped.")
        SaveCosmetics(id)
        ShowDeathEffectsMenu(id)
        return PLUGIN_HANDLED
    }
    if(g_iOwnedDeath[id] & (1 << iChoice))
    {
        g_iDeathEffect[id] = iChoice
        client_printcolor(id, "!g[FreeNova] !n Equipped death effect: !g%s!n", g_szDeathNames[iChoice])
        SaveCosmetics(id)
        ShowDeathEffectsMenu(id)
        return PLUGIN_HANDLED
    }
    if(!CosmeticsReady(id))
        return PLUGIN_HANDLED
    new cost = g_iDeathCosts[iChoice]
    if(menabp_get_coins(id) < cost)
    {
        client_printcolor(id, "!g[FreeNova] !n You need !g%d !nCoins to unlock this death effect.", cost)
        ShowDeathEffectsMenu(id)
        return PLUGIN_HANDLED
    }
    if(!CosmeticsDebitCoins(id, cost))
        return PLUGIN_HANDLED
    g_iOwnedDeath[id] |= (1 << iChoice)
    g_iDeathEffect[id] = iChoice
    client_printcolor(id, "!g[FreeNova] !n Unlocked and equipped !g%s!n (-%d Coins)", g_szDeathNames[iChoice], cost)
    SaveCosmetics(id)
    ShowDeathEffectsMenu(id)
    return PLUGIN_HANDLED
}

public Cmd_BuyTag(id, level, cid)
{
    if(!is_user_connected(id))
        return PLUGIN_HANDLED
    if(!CosmeticsReady(id))
        return PLUGIN_HANDLED

    new szType[16], szIdx[8]
    read_argv(1, szType, charsmax(szType))
    read_argv(2, szIdx, charsmax(szIdx))

    if(equali(szType, "premade"))
    {
        new iChoice = str_to_num(szIdx)
        if(iChoice < 1 || iChoice > 8)
            return PLUGIN_HANDLED

        if(g_iOwnedPremadeTags[id] & (1 << iChoice))
        {
            client_printcolor(id, "!g[FreeNova] !n You already own the tag !g%s!n.", g_szPremadeTags[iChoice])
            return PLUGIN_HANDLED
        }

        new cost = g_iPremadeTagCosts[iChoice]
        if(menabp_get_coins(id) < cost)
        {
            client_printcolor(id, "!g[FreeNova] !n Insufficient coins! Tag !g%s !ncosts !t%d coins!n (you have !t%d!n).",
                g_szPremadeTags[iChoice], cost, menabp_get_coins(id))
            return PLUGIN_HANDLED
        }

        if(!CosmeticsDebitCoins(id, cost))
            return PLUGIN_HANDLED
        g_iOwnedPremadeTags[id] |= (1 << iChoice)
        copy(g_szCustomTag[id], charsmax(g_szCustomTag[]), g_szPremadeTags[iChoice])
        client_printcolor(id, "!g[FreeNova] !n Unlocked and equipped premade tag: !g%s !n(-%d Coins)!", g_szPremadeTags[iChoice], cost)
        emit_sound(id, CHAN_ITEM, "items/suitchargeno1.wav", 1.0, ATTN_NORM, 0, PITCH_NORM)
        SaveCustomTagData(id)
    }
    else if(equali(szType, "custom"))
    {
        if(g_bCustomTagUnlocked[id] || (get_user_flags(id) & (ADMIN_IMMUNITY | ADMIN_BAN | ADMIN_RCON)))
        {
            client_printcolor(id, "!g[FreeNova] !n You already have the Custom Tag License unlocked!")
            return PLUGIN_HANDLED
        }

        if(menabp_get_coins(id) < TAG_UNLOCK_COST)
        {
            client_printcolor(id, "!g[FreeNova] !n Custom Tag License costs !t%d coins!n (you have !t%d!n). Or buy cheaper premade tags for !g2,500-5,000 Coins!n!",
                TAG_UNLOCK_COST, menabp_get_coins(id))
            return PLUGIN_HANDLED
        }

        if(!CosmeticsDebitCoins(id, TAG_UNLOCK_COST))
            return PLUGIN_HANDLED
        g_bCustomTagUnlocked[id] = true
        client_printcolor(id, "!g[FreeNova] !n Unlocked Custom Tag License for !g%d Coins!n! You can now type !t/tag <any text>!n!", TAG_UNLOCK_COST)
        emit_sound(id, CHAN_ITEM, "items/suitchargeno1.wav", 1.0, ATTN_NORM, 0, PITCH_NORM)
        SaveCustomTagData(id)
    }
    return PLUGIN_HANDLED
}

public Cmd_EquipTag(id, level, cid)
{
    if(!is_user_connected(id))
        return PLUGIN_HANDLED
    if(!CosmeticsReady(id))
        return PLUGIN_HANDLED

    new szType[16], szIdx[8]
    read_argv(1, szType, charsmax(szType))
    read_argv(2, szIdx, charsmax(szIdx))

    if(equali(szType, "premade"))
    {
        new iChoice = str_to_num(szIdx)
        if(iChoice == 0)
        {
            g_szCustomTag[id][0] = 0
            client_printcolor(id, "!g[FreeNova] !n Tag unequipped.")
            SaveCustomTagData(id)
            return PLUGIN_HANDLED
        }

        if(iChoice < 1 || iChoice > 8)
            return PLUGIN_HANDLED

        if(!(g_iOwnedPremadeTags[id] & (1 << iChoice)))
        {
            client_printcolor(id, "!g[FreeNova] !n You do not own the tag !g%s!n. Buy it for !t%d coins!n!", g_szPremadeTags[iChoice], g_iPremadeTagCosts[iChoice])
            return PLUGIN_HANDLED
        }

        copy(g_szCustomTag[id], charsmax(g_szCustomTag[]), g_szPremadeTags[iChoice])
        client_printcolor(id, "!g[FreeNova] !n Equipped premade tag: !g%s!n", g_szPremadeTags[iChoice])
        SaveCustomTagData(id)
    }
    else if(equali(szType, "clear") || equali(szType, "none"))
    {
        g_szCustomTag[id][0] = 0
        client_printcolor(id, "!g[FreeNova] !n Tag unequipped.")
        SaveCustomTagData(id)
    }
    return PLUGIN_HANDLED
}

Cmd_BuyTagPremadeDirect(id, iChoice)
{
    if(!CosmeticsReady(id))
        return
    if(g_iOwnedPremadeTags[id] & (1 << iChoice))
    {
        client_printcolor(id, "!g[FreeNova] !n You already own the tag !g%s!n.", g_szPremadeTags[iChoice])
        return
    }
    new cost = g_iPremadeTagCosts[iChoice]
    if(menabp_get_coins(id) < cost)
    {
        client_printcolor(id, "!g[FreeNova] !n Insufficient coins! Tag !g%s !ncosts !t%d coins!n.", g_szPremadeTags[iChoice], cost)
        return
    }
    if(!CosmeticsDebitCoins(id, cost))
        return
    g_iOwnedPremadeTags[id] |= (1 << iChoice)
    copy(g_szCustomTag[id], charsmax(g_szCustomTag[]), g_szPremadeTags[iChoice])
    client_printcolor(id, "!g[FreeNova] !n Unlocked and equipped premade tag: !g%s !n(-%d Coins)!", g_szPremadeTags[iChoice], cost)
    emit_sound(id, CHAN_ITEM, "items/suitchargeno1.wav", 1.0, ATTN_NORM, 0, PITCH_NORM)
    SaveCustomTagData(id)
}

Cmd_BuyTagCustomDirect(id)
{
    if(!CosmeticsReady(id))
        return
    if(g_bCustomTagUnlocked[id] || (get_user_flags(id) & (ADMIN_IMMUNITY | ADMIN_BAN | ADMIN_RCON)))
    {
        client_printcolor(id, "!g[FreeNova] !n You already have the Custom Tag License unlocked!")
        return
    }
    if(menabp_get_coins(id) < TAG_UNLOCK_COST)
    {
        client_printcolor(id, "!g[FreeNova] !n Custom Tag License costs !t%d coins!n.", TAG_UNLOCK_COST)
        return
    }
    if(!CosmeticsDebitCoins(id, TAG_UNLOCK_COST))
        return
    g_bCustomTagUnlocked[id] = true
    client_printcolor(id, "!g[FreeNova] !n Unlocked Custom Tag License for !g%d Coins!n!", TAG_UNLOCK_COST)
    emit_sound(id, CHAN_ITEM, "items/suitchargeno1.wav", 1.0, ATTN_NORM, 0, PITCH_NORM)
    SaveCustomTagData(id)
}

public Cmd_BuyCosmetic(id, level, cid)
{
    if(!is_user_connected(id))
        return PLUGIN_HANDLED
    if(!CosmeticsReady(id))
        return PLUGIN_HANDLED

    new szType[16], szIdx[8]
    read_argv(1, szType, charsmax(szType))
    read_argv(2, szIdx, charsmax(szIdx))
    new iChoice = str_to_num(szIdx)

    if(equali(szType, "spawn"))
    {
        if(iChoice < 1 || iChoice > 5) return PLUGIN_HANDLED
        if(g_iOwnedSpawn[id] & (1 << iChoice))
        {
            client_printcolor(id, "!g[FreeNova] !n You already own this spawn effect.")
            return PLUGIN_HANDLED
        }
        new cost = g_iSpawnCosts[iChoice]
        if(menabp_get_coins(id) < cost)
        {
            client_printcolor(id, "!g[FreeNova] !n You need !g%d !nCoins to unlock this effect.", cost)
            return PLUGIN_HANDLED
        }
        if(!CosmeticsDebitCoins(id, cost))
        return PLUGIN_HANDLED
        g_iOwnedSpawn[id] |= (1 << iChoice)
        g_iSpawnEffect[id] = iChoice
        client_printcolor(id, "!g[FreeNova] !n Unlocked and equipped !g%s!n (-%d Coins)", g_szSpawnNames[iChoice], cost)
        emit_sound(id, CHAN_ITEM, "items/suitchargeno1.wav", 1.0, ATTN_NORM, 0, PITCH_NORM)
        SaveCosmetics(id)
    }
    else if(equali(szType, "title"))
    {
        if(iChoice < 1 || iChoice > 12) return PLUGIN_HANDLED
        if(g_iOwnedTitles[id] & (1 << iChoice))
        {
            client_printcolor(id, "!g[FreeNova] !n You already own this chat title.")
            return PLUGIN_HANDLED
        }
        new cost = g_iTitleCosts[iChoice]
        if(menabp_get_coins(id) < cost)
        {
            client_printcolor(id, "!g[FreeNova] !n You need !g%d !nCoins to unlock this title.", cost)
            return PLUGIN_HANDLED
        }
        if(!CosmeticsDebitCoins(id, cost))
        return PLUGIN_HANDLED
        g_iOwnedTitles[id] |= (1 << iChoice)
        g_iChatTitle[id] = iChoice
        client_printcolor(id, "!g[FreeNova] !n Unlocked and equipped !g%s!n (-%d Coins)", g_szTitleNames[iChoice], cost)
        SaveCosmetics(id)
    }
    else if(equali(szType, "death"))
    {
        if(iChoice < 1 || iChoice > 4) return PLUGIN_HANDLED
        if(g_iOwnedDeath[id] & (1 << iChoice))
        {
            client_printcolor(id, "!g[FreeNova] !n You already own this death effect.")
            return PLUGIN_HANDLED
        }
        new cost = g_iDeathCosts[iChoice]
        if(menabp_get_coins(id) < cost)
        {
            client_printcolor(id, "!g[FreeNova] !n You need !g%d !nCoins to unlock this death effect.", cost)
            return PLUGIN_HANDLED
        }
        if(!CosmeticsDebitCoins(id, cost))
        return PLUGIN_HANDLED
        g_iOwnedDeath[id] |= (1 << iChoice)
        g_iDeathEffect[id] = iChoice
        client_printcolor(id, "!g[FreeNova] !n Unlocked and equipped !g%s!n (-%d Coins)", g_szDeathNames[iChoice], cost)
        SaveCosmetics(id)
    }
    else if(equali(szType, "color"))
    {
        if(HasChatColorAccess(id))
        {
            client_printcolor(id, "!g[FreeNova] !n You already own the Chat Color License.")
            return PLUGIN_HANDLED
        }
        if(menabp_get_coins(id) < CHAT_COLOR_SKILL_COST)
        {
            client_printcolor(id, "!g[FreeNova] !n You need !g%d !nCoins to unlock Chat Color License.", CHAT_COLOR_SKILL_COST)
            return PLUGIN_HANDLED
        }
        if(!CosmeticsDebitCoins(id, CHAT_COLOR_SKILL_COST))
            return PLUGIN_HANDLED
        menabp_set_skill_stage(id, SKILL_CHAT_COLOR, 1)
        g_bChatColorUnlocked[id] = true
        g_iChatColor[id] = 1
        client_printcolor(id, "!g[FreeNova] !n Unlocked Chat Color License! (-%d Coins)", CHAT_COLOR_SKILL_COST)
        emit_sound(id, CHAN_ITEM, "items/suitchargeno1.wav", 1.0, ATTN_NORM, 0, PITCH_NORM)
        SaveCustomTagData(id)
    }
        else if(equali(szType, "tag"))
    {
        if(iChoice >= 1 && iChoice <= 8)
        {
            new szCmdArg[8]
            num_to_str(iChoice, szCmdArg, charsmax(szCmdArg))
            Cmd_BuyTagPremadeDirect(id, iChoice)
            return PLUGIN_HANDLED
        }
        else
        {
            Cmd_BuyTagCustomDirect(id)
            return PLUGIN_HANDLED
        }
    }
    return PLUGIN_HANDLED
}

public Cmd_EquipCosmetic(id, level, cid)
{
    if(!is_user_connected(id))
        return PLUGIN_HANDLED
    if(!CosmeticsReady(id))
        return PLUGIN_HANDLED

    new szType[16], szIdx[8]
    read_argv(1, szType, charsmax(szType))
    read_argv(2, szIdx, charsmax(szIdx))
    new iChoice = str_to_num(szIdx)

    if(equali(szType, "spawn"))
    {
        if(iChoice == 0)
        {
            g_iSpawnEffect[id] = 0
            client_printcolor(id, "!g[FreeNova] !n Spawn effect unequipped.")
            SaveCosmetics(id)
            return PLUGIN_HANDLED
        }
        if(iChoice < 1 || iChoice > 5) return PLUGIN_HANDLED
        if(!(g_iOwnedSpawn[id] & (1 << iChoice)))
        {
            client_printcolor(id, "!g[FreeNova] !n You do not own this spawn effect.")
            return PLUGIN_HANDLED
        }
        g_iSpawnEffect[id] = iChoice
        client_printcolor(id, "!g[FreeNova] !n Equipped spawn effect: !g%s!n", g_szSpawnNames[iChoice])
        SaveCosmetics(id)
    }
    else if(equali(szType, "title"))
    {
        if(iChoice == 0)
        {
            g_iChatTitle[id] = 0
            client_printcolor(id, "!g[FreeNova] !n Chat title unequipped.")
            SaveCosmetics(id)
            return PLUGIN_HANDLED
        }
        if(iChoice < 1 || iChoice > 12) return PLUGIN_HANDLED
        if(!(g_iOwnedTitles[id] & (1 << iChoice)))
        {
            client_printcolor(id, "!g[FreeNova] !n You do not own this chat title.")
            return PLUGIN_HANDLED
        }
        g_iChatTitle[id] = iChoice
        client_printcolor(id, "!g[FreeNova] !n Active chat title: !g%s!n", g_szTitleNames[iChoice])
        SaveCosmetics(id)
    }
    else if(equali(szType, "death"))
    {
        if(iChoice == 0)
        {
            g_iDeathEffect[id] = 0
            client_printcolor(id, "!g[FreeNova] !n Death effect unequipped.")
            SaveCosmetics(id)
            return PLUGIN_HANDLED
        }
        if(iChoice < 1 || iChoice > 4) return PLUGIN_HANDLED
        if(!(g_iOwnedDeath[id] & (1 << iChoice)))
        {
            client_printcolor(id, "!g[FreeNova] !n You do not own this death effect.")
            return PLUGIN_HANDLED
        }
        g_iDeathEffect[id] = iChoice
        client_printcolor(id, "!g[FreeNova] !n Equipped death effect: !g%s!n", g_szDeathNames[iChoice])
        SaveCosmetics(id)
    }
    else if(equali(szType, "color"))
    {
        if(iChoice < 0 || iChoice > 2) return PLUGIN_HANDLED
        if(iChoice > 0 && !HasChatColorAccess(id))
        {
            client_printcolor(id, "!g[FreeNova] !n You need the Chat Color License to use colored chat.")
            return PLUGIN_HANDLED
        }
        g_iChatColor[id] = iChoice
        new const szColorNames[][] = { "Default Gold (^1)", "Toxic Green (^4)", "Dynamic Team Color (^3)" }
        client_printcolor(id, "!g[FreeNova] !n Chat color set to: !g%s!n", szColorNames[g_iChatColor[id]])
        SaveCustomTagData(id)
    }
    return PLUGIN_HANDLED
}

public Cmd_SetMyTag(id, level, cid)
{
    if(!is_user_connected(id))
        return PLUGIN_HANDLED

    new szTag[32]
    read_argv(1, szTag, charsmax(szTag))
    trim(szTag)
    SetPlayerTagString(id, szTag)
    return PLUGIN_HANDLED
}

// -------------------------------------------------------------
// CUSTOM TAG & CHAT COLOR MENUS & ACTIONS
// -------------------------------------------------------------
SetPlayerTagString(id, const szArg[])
{
    if(!szArg[0])
    {
        Cmd_TagMenu(id)
        return
    }

    if(equali(szArg, "none") || equali(szArg, "clear") || equali(szArg, "off"))
    {
        g_szCustomTag[id][0] = 0
        client_printcolor(id, "!g[FreeNova] !nTag unequipped.")
        SaveCustomTagData(id)
        return
    }

    // Check unlocking status
    if(!g_bCustomTagUnlocked[id] && !(get_user_flags(id) & (ADMIN_IMMUNITY | ADMIN_BAN | ADMIN_RCON)))
    {
        // Check if player typed an owned premade tag
        for(new i = 1; i <= 8; i++)
        {
            if((g_iOwnedPremadeTags[id] & (1 << i)) && (equali(szArg, g_szPremadeTags[i]) || equali(szArg, g_szPremadeTags[i][2])))
            {
                copy(g_szCustomTag[id], charsmax(g_szCustomTag[]), g_szPremadeTags[i])
                client_printcolor(id, "!g[FreeNova] !nEquipped premade tag: !g%s", g_szCustomTag[id])
                emit_sound(id, CHAN_ITEM, "items/suitchargeno1.wav", 1.0, ATTN_NORM, 0, PITCH_NORM)
                SaveCustomTagData(id)
                return
            }
        }

        if(!CosmeticsReady(id))
            return

        // Do not auto-debit 15k from chat. Confirm via /tag menu item 3.
        client_printcolor(id, "!g[FreeNova] !nCustom tags require the !gCustom Tag License!n. Open !t/tag!n to confirm the %d-coin unlock.", TAG_UNLOCK_COST)
        client_printcolor(id, "!g[FreeNova] !nTip: cheaper premade tags are !g2,500-5,000 Coins !nvia !t/tag!n.")
        return
    }

    new szClean[32]
    copy(szClean, charsmax(szClean), szArg)
    trim(szClean)
    replace_all(szClean, charsmax(szClean), "^"", "")
    replace_all(szClean, charsmax(szClean), "^n", "")
    replace_all(szClean, charsmax(szClean), ";", "")
    // Strip GoldSrc color codes (^1-^4) and leftover carets.
    replace_all(szClean, charsmax(szClean), "^1", "")
    replace_all(szClean, charsmax(szClean), "^2", "")
    replace_all(szClean, charsmax(szClean), "^3", "")
    replace_all(szClean, charsmax(szClean), "^4", "")
    replace_all(szClean, charsmax(szClean), "^^", "")
    trim(szClean)
    if(!szClean[0])
    {
        client_printcolor(id, "!g[FreeNova] !nTag rejected: empty after sanitizing.")
        return
    }

    if(szClean[0] != '[')
        formatex(g_szCustomTag[id], charsmax(g_szCustomTag[]), "[ %s ]", szClean)
    else
        copy(g_szCustomTag[id], charsmax(g_szCustomTag[]), szClean)

    client_printcolor(id, "!g[FreeNova] !nCustom in-game tag set to: !g%s", g_szCustomTag[id])
    emit_sound(id, CHAN_ITEM, "items/suitchargeno1.wav", 1.0, ATTN_NORM, 0, PITCH_NORM)
    SaveCustomTagData(id)
}

public Cmd_TagMenu(id)
{
    if(!is_user_connected(id))
        return PLUGIN_HANDLED

    new szTitle[64]
    FN_MenuTitle(szTitle, charsmax(szTitle), "Tags")
    new menu = menu_create(szTitle, "TagMenuHandler")

    if(g_szCustomTag[id][0])
        menu_additem(menu, fmt("\wCurrent \y%s \r(ON)", g_szCustomTag[id]), "1")
    else
        menu_additem(menu, "\wCurrent \dNone", "1")

    menu_additem(menu, "\yPremade tags \d2500c-5000c", "2")

    if(g_bCustomTagUnlocked[id] || (get_user_flags(id) & (ADMIN_IMMUNITY | ADMIN_BAN | ADMIN_RCON)))
        menu_additem(menu, "\wCustom license \yUNLOCKED", "3")
    else
        menu_additem(menu, fmt("\wUnlock custom license \r%dc", TAG_UNLOCK_COST), "3")

    menu_additem(menu, "\rClear tag", "4")
    menu_additem(menu, "\wChat color", "5")

    FN_MenuFinish(menu, true)
    menu_display(id, menu, 0)
    return PLUGIN_HANDLED
}

public TagMenuHandler(id, menu, item)
{
    if(item == MENU_EXIT)
    {
        menu_destroy(menu)
        Cmd_CosmeticsMenu(id)
        return PLUGIN_HANDLED
    }
    new data[6], name[64], access, callback
    menu_item_getinfo(menu, item, access, data, charsmax(data), name, charsmax(name), callback)
    menu_destroy(menu)

    new choice = str_to_num(data)
    switch(choice)
    {
        case 2: ShowPremadeTagsMenu(id)
        case 3:
        {
            if(g_bCustomTagUnlocked[id] || (get_user_flags(id) & (ADMIN_IMMUNITY | ADMIN_BAN | ADMIN_RCON)))
                client_printcolor(id, "!g[FreeNova] !nType in chat: !t/tag <your custom tag> !nor use the !t/cosmetics !nmenu.")
            else
                Cmd_BuyTagCustomDirect(id)
            Cmd_TagMenu(id)
        }
        case 4:
        {
            g_szCustomTag[id][0] = 0
            client_printcolor(id, "!g[FreeNova] !nTag cleared.")
            SaveCustomTagData(id)
            Cmd_TagMenu(id)
        }
        case 5: Cmd_ColorMenu(id)
        default: Cmd_TagMenu(id)
    }
    return PLUGIN_HANDLED
}

ShowPremadeTagsMenu(id)
{
    new szTitle[64]
    FN_MenuTitle(szTitle, charsmax(szTitle), "Premade tags")
    new menu = menu_create(szTitle, "PremadeMenuHandler")
    menu_additem(menu, g_szCustomTag[id][0] ? "\wNone" : "\yNone \r(ON)", "0")

    for(new i = 1; i <= 8; i++)
    {
        new bool:bOwned = bool:(g_iOwnedPremadeTags[id] & (1 << i))
        new bool:bEquipped = bool:equali(g_szCustomTag[id], g_szPremadeTags[i])
        new szItem[96]

        if(bEquipped)
            formatex(szItem, charsmax(szItem), "\y%s \r(ON)", g_szPremadeTags[i])
        else if(bOwned)
            formatex(szItem, charsmax(szItem), "\w%s \d[OWNED]", g_szPremadeTags[i])
        else
            formatex(szItem, charsmax(szItem), "\d%s \r[%dc]", g_szPremadeTags[i], g_iPremadeTagCosts[i])

        menu_additem(menu, szItem, fmt("%d", i))
    }

    FN_MenuFinish(menu, true)
    menu_display(id, menu, 0)
}

public PremadeMenuHandler(id, menu, item)
{
    if(item == MENU_EXIT)
    {
        menu_destroy(menu)
        Cmd_TagMenu(id)
        return PLUGIN_HANDLED
    }
    new data[6], name[64], access, callback
    menu_item_getinfo(menu, item, access, data, charsmax(data), name, charsmax(name), callback)
    menu_destroy(menu)

    new iChoice = str_to_num(data)
    if(iChoice == 0)
    {
        g_szCustomTag[id][0] = 0
        client_printcolor(id, "!g[FreeNova] !nTag unequipped.")
        SaveCustomTagData(id)
        ShowPremadeTagsMenu(id)
        return PLUGIN_HANDLED
    }

    if(g_iOwnedPremadeTags[id] & (1 << iChoice))
    {
        copy(g_szCustomTag[id], charsmax(g_szCustomTag[]), g_szPremadeTags[iChoice])
        client_printcolor(id, "!g[FreeNova] !nEquipped premade tag: !g%s", g_szPremadeTags[iChoice])
        emit_sound(id, CHAN_ITEM, "items/suitchargeno1.wav", 1.0, ATTN_NORM, 0, PITCH_NORM)
        SaveCustomTagData(id)
        ShowPremadeTagsMenu(id)
        return PLUGIN_HANDLED
    }

    if(!CosmeticsReady(id))
        return PLUGIN_HANDLED
    new cost = g_iPremadeTagCosts[iChoice]
    if(menabp_get_coins(id) < cost)
    {
        client_printcolor(id, "!g[FreeNova] !nInsufficient coins! Tag !g%s !ncosts !t%d coins!n.", g_szPremadeTags[iChoice], cost)
        ShowPremadeTagsMenu(id)
        return PLUGIN_HANDLED
    }
    if(!CosmeticsDebitCoins(id, cost))
        return PLUGIN_HANDLED
    g_iOwnedPremadeTags[id] |= (1 << iChoice)
    copy(g_szCustomTag[id], charsmax(g_szCustomTag[]), g_szPremadeTags[iChoice])
    client_printcolor(id, "!g[FreeNova] !nUnlocked and equipped !g%s !n(-%d Coins)!", g_szPremadeTags[iChoice], cost)
    emit_sound(id, CHAN_ITEM, "items/suitchargeno1.wav", 1.0, ATTN_NORM, 0, PITCH_NORM)
    SaveCustomTagData(id)
    ShowPremadeTagsMenu(id)
    return PLUGIN_HANDLED
}


public Cmd_ColorMenu(id)
{
    if(!is_user_connected(id))
        return PLUGIN_HANDLED

    new bool:bHasAccess = HasChatColorAccess(id)
    new szTitle[128]
    FN_MenuTitle(szTitle, charsmax(szTitle), bHasAccess ? "Chat color" : "Chat color (locked)")
    new menu = menu_create(szTitle, "ColorMenuHandler")

    menu_additem(menu, fmt("\wDefault Gold %s", (g_iChatColor[id] == 0) ? "\r(ON)" : ""), "0")

    if(bHasAccess)
    {
        menu_additem(menu, fmt("\yToxic Green %s", (g_iChatColor[id] == 1) ? "\r(ON)" : ""), "1")
        menu_additem(menu, fmt("\wTeam Color %s", (g_iChatColor[id] == 2) ? "\r(ON)" : ""), "2")
    }
    else
    {
        menu_additem(menu, "\dToxic Green (^4) \r(LOCKED)", "1")
        menu_additem(menu, "\dDynamic Team Color (^3) \r(LOCKED)", "2")
        menu_additem(menu, fmt("\yUnlock Chat Color Skill \r%dc permanent", CHAT_COLOR_SKILL_COST), "3")
    }

    FN_MenuFinish(menu, true)
    menu_display(id, menu, 0)
    return PLUGIN_HANDLED
}

public ColorMenuHandler(id, menu, item)
{
    if(item == MENU_EXIT) { menu_destroy(menu); Cmd_TagMenu(id); return PLUGIN_HANDLED; }
    new data[6], name[64], access, callback
    menu_item_getinfo(menu, item, access, data, charsmax(data), name, charsmax(name), callback)
    menu_destroy(menu)

    new iChoice = str_to_num(data)
    if(iChoice == 3)
    {
        if(HasChatColorAccess(id))
        {
            client_printcolor(id, "!g[FreeNova] !nChat color skill is already unlocked!")
            Cmd_ColorMenu(id)
            return PLUGIN_HANDLED
        }

        if(!CosmeticsReady(id))
            return PLUGIN_HANDLED

        new iCoins = menabp_get_coins(id)
        if(iCoins < CHAT_COLOR_SKILL_COST)
        {
            client_printcolor(id, "!g[FreeNova] !nInsufficient coins! You need !t%d coins !n(you have !t%d!n).",
                CHAT_COLOR_SKILL_COST, iCoins)
            Cmd_ColorMenu(id)
            return PLUGIN_HANDLED
        }

        if(!CosmeticsDebitCoins(id, CHAT_COLOR_SKILL_COST))
            return PLUGIN_HANDLED
        menabp_set_skill_stage(id, SKILL_CHAT_COLOR, 1)
        g_bChatColorUnlocked[id] = true
        g_iChatColor[id] = 1
        SaveCustomTagData(id)
        client_printcolor(id, "!g[FreeNova] !nChat Color License unlocked permanently! Color set to !gToxic Green (^4)!n.")
        emit_sound(id, CHAN_ITEM, "items/suitchargeno1.wav", 1.0, ATTN_NORM, 0, PITCH_NORM)
        Cmd_ColorMenu(id)
        return PLUGIN_HANDLED
    }

    if((iChoice == 1 || iChoice == 2) && !HasChatColorAccess(id))
    {
        client_printcolor(id, "!g[FreeNova] !nChat colors require the !tChat Color License !nskill (!t%d coins!n).", CHAT_COLOR_SKILL_COST)
        client_printcolor(id, "!g[FreeNova] !nUnlock it via !t/color !nor the !t/shop !nmenu.")
        Cmd_ColorMenu(id)
        return PLUGIN_HANDLED
    }

    g_iChatColor[id] = iChoice
    new const szColorNames[][] = { "Default Gold (^1)", "Toxic Green (^4)", "Dynamic Team Color (^3)" }
    client_printcolor(id, "!g[FreeNova] !nChat color set to: !g%s", szColorNames[g_iChatColor[id]])
    emit_sound(id, CHAN_ITEM, "items/suitchargeno1.wav", 1.0, ATTN_NORM, 0, PITCH_NORM)
    SaveCustomTagData(id)
    Cmd_ColorMenu(id)
    return PLUGIN_HANDLED
}

public Cmd_AdminSetTag(id, level, cid)
{
    if(!cmd_access(id, level, cid, 3))
        return PLUGIN_HANDLED

    new szTarget[32], szTag[32]
    read_argv(1, szTarget, charsmax(szTarget))
    read_argv(2, szTag, charsmax(szTag))

    new target = cmd_target(id, szTarget, CMDTARGET_ALLOW_SELF | CMDTARGET_OBEY_IMMUNITY)
    if(!target)
        return PLUGIN_HANDLED

    g_bCustomTagUnlocked[target] = true
    SetPlayerTagString(target, szTag)
    new szAdminName[32], szTargetName[32], szAdminAuth[40], szTargetAuth[40]
    get_user_name(id, szAdminName, charsmax(szAdminName))
    get_user_name(target, szTargetName, charsmax(szTargetName))
    get_user_authid(id, szAdminAuth, charsmax(szAdminAuth))
    get_user_authid(target, szTargetAuth, charsmax(szTargetAuth))
    log_amx("[FreeNova Tag] %s (%s) set tag of %s (%s) to '%s'",
        szAdminName, szAdminAuth, szTargetName, szTargetAuth, g_szCustomTag[target])
    client_printcolor(0, "!g[FreeNova] !tAdmin %s !nset custom tag for !t%s: !g%s", szAdminName, szTargetName, g_szCustomTag[target])
    return PLUGIN_HANDLED
}

SaveCustomTagData(id)
{
    new szAuth[40]
    get_user_authid(id, szAuth, charsmax(szAuth))
    if(!szAuth[0] || equal(szAuth, "STEAM_ID_PENDING") || equal(szAuth, "STEAM_ID_LAN")
        || equal(szAuth, "UNKNOWN") || equal(szAuth, "BOT") || equal(szAuth, "HLTV"))
        return

    if(g_VaultCosmetics != INVALID_HANDLE)
    {
        new szKey[64], szVal[96]
        formatex(szKey, charsmax(szKey), "%s#taginfo", szAuth)
        formatex(szVal, charsmax(szVal), "%d %d %d ^"%s^"", g_bCustomTagUnlocked[id] ? 1 : 0, g_iChatColor[id], g_iOwnedPremadeTags[id], g_szCustomTag[id])
        nvault_set(g_VaultCosmetics, szKey, szVal)

        formatex(szKey, charsmax(szKey), "%s#colorskill", szAuth)
        formatex(szVal, charsmax(szVal), "%d", g_bChatColorUnlocked[id] ? 1 : 0)
        nvault_set(g_VaultCosmetics, szKey, szVal)
    }

    if(g_bChatColorUnlocked[id] && menabp_get_skill_stage(id, SKILL_CHAT_COLOR) < 1)
    {
        menabp_set_skill_stage(id, SKILL_CHAT_COLOR, 1)
    }
}

LoadCustomTagData(id)
{
    new szAuth[40]
    get_user_authid(id, szAuth, charsmax(szAuth))
    if(!szAuth[0] || equal(szAuth, "STEAM_ID_PENDING") || equal(szAuth, "STEAM_ID_LAN")
        || equal(szAuth, "UNKNOWN") || equal(szAuth, "BOT") || equal(szAuth, "HLTV"))
        return

    if(menabp_get_skill_stage(id, SKILL_CHAT_COLOR) >= 1)
    {
        g_bChatColorUnlocked[id] = true
    }

    if(g_VaultCosmetics != INVALID_HANDLE)
    {
        new szKey[64], szVal[96]
        formatex(szKey, charsmax(szKey), "%s#taginfo", szAuth)
        if(nvault_get(g_VaultCosmetics, szKey, szVal, charsmax(szVal)))
        {
            new sUnlocked[4], sColor[4], sTag[32]
            new sPremade[16]
            parse(szVal, sUnlocked, charsmax(sUnlocked), sColor, charsmax(sColor), sPremade, charsmax(sPremade), sTag, charsmax(sTag))
            g_iOwnedPremadeTags[id] = str_to_num(sPremade)
            g_bCustomTagUnlocked[id] = bool:(str_to_num(sUnlocked) == 1)
            g_iChatColor[id] = str_to_num(sColor)
            copy(g_szCustomTag[id], charsmax(g_szCustomTag[]), sTag)
        }

        formatex(szKey, charsmax(szKey), "%s#colorskill", szAuth)
        if(nvault_get(g_VaultCosmetics, szKey, szVal, charsmax(szVal)))
        {
            if(str_to_num(szVal) == 1)
            {
                g_bChatColorUnlocked[id] = true
            }
        }
    }

    if(g_bChatColorUnlocked[id] && menabp_get_skill_stage(id, SKILL_CHAT_COLOR) < 1)
    {
        menabp_set_skill_stage(id, SKILL_CHAT_COLOR, 1)
    }
}

// -------------------------------------------------------------
// STORAGE: NVAULT + FILE BACKUP
// -------------------------------------------------------------
LoadCosmetics(id)
{
    new szAuth[40]
    get_user_authid(id, szAuth, charsmax(szAuth))
    if(!szAuth[0] || equal(szAuth, "STEAM_ID_PENDING") || equal(szAuth, "STEAM_ID_LAN")
        || equal(szAuth, "UNKNOWN") || equal(szAuth, "BOT") || equal(szAuth, "HLTV"))
        return

    if(g_VaultCosmetics != INVALID_HANDLE)
    {
        new szKey[64], szVal[64]
        formatex(szKey, charsmax(szKey), "%s#cosmetics", szAuth)
        if(nvault_get(g_VaultCosmetics, szKey, szVal, charsmax(szVal)))
        {
            new sSpawn[8], sTitle[8], sDeath[8], sOwnS[8], sOwnT[8], sOwnD[8]
            parse(szVal, sSpawn, charsmax(sSpawn), sTitle, charsmax(sTitle), sDeath, charsmax(sDeath),
                         sOwnS, charsmax(sOwnS), sOwnT, charsmax(sOwnT), sOwnD, charsmax(sOwnD))

            g_iSpawnEffect[id] = str_to_num(sSpawn)
            g_iChatTitle[id]   = str_to_num(sTitle)
            g_iDeathEffect[id] = str_to_num(sDeath)
            g_iOwnedSpawn[id]  = str_to_num(sOwnS)
            g_iOwnedTitles[id] = str_to_num(sOwnT)
            g_iOwnedDeath[id]  = str_to_num(sOwnD)
            LoadCustomTagData(id)
            g_bCosmeticsLoaded[id] = true
            return
        }
    }

    // Text File Fallback
    new szFile[256]
    formatex(szFile, charsmax(szFile), "%s/%s.dat", g_szDataDir, szAuth)
    replace_all(szFile, charsmax(szFile), ":", "_")

    if(file_exists(szFile))
    {
        new f = fopen(szFile, "rt")
        if(f)
        {
            new szLine[128]
            if(fgets(f, szLine, charsmax(szLine)))
            {
                new sSpawn[8], sTitle[8], sDeath[8], sOwnS[8], sOwnT[8], sOwnD[8]
                parse(szLine, sSpawn, charsmax(sSpawn), sTitle, charsmax(sTitle), sDeath, charsmax(sDeath),
                              sOwnS, charsmax(sOwnS), sOwnT, charsmax(sOwnT), sOwnD, charsmax(sOwnD))

                g_iSpawnEffect[id] = str_to_num(sSpawn)
                g_iChatTitle[id]   = str_to_num(sTitle)
                g_iDeathEffect[id] = str_to_num(sDeath)
                g_iOwnedSpawn[id]  = str_to_num(sOwnS)
                g_iOwnedTitles[id] = str_to_num(sOwnT)
                g_iOwnedDeath[id]  = str_to_num(sOwnD)
            }
            fclose(f)
        }
    }

    LoadCustomTagData(id)
    g_bCosmeticsLoaded[id] = true
}

SaveCosmetics(id)
{
    if(!g_bCosmeticsLoaded[id])
        return

    new szAuth[40]
    get_user_authid(id, szAuth, charsmax(szAuth))
    if(!szAuth[0] || equal(szAuth, "STEAM_ID_PENDING") || equal(szAuth, "STEAM_ID_LAN")
        || equal(szAuth, "UNKNOWN") || equal(szAuth, "BOT") || equal(szAuth, "HLTV"))
        return

    new szVal[64]
    formatex(szVal, charsmax(szVal), "%d %d %d %d %d %d",
        g_iSpawnEffect[id], g_iChatTitle[id], g_iDeathEffect[id],
        g_iOwnedSpawn[id], g_iOwnedTitles[id], g_iOwnedDeath[id])

    if(g_VaultCosmetics != INVALID_HANDLE)
    {
        new szKey[64]
        formatex(szKey, charsmax(szKey), "%s#cosmetics", szAuth)
        nvault_set(g_VaultCosmetics, szKey, szVal)
    }
    // The nVault row above is the authoritative store. The old dual-write
    // to <datadir>/<auth>.dat was removed: a second mutable copy could
    // drift from the vault and shadow newer data. LoadCosmetics() still
    // READS a legacy .dat file as a one-time migration fallback when the
    // vault row is missing; those files are never refreshed anymore.

    SaveCustomTagData(id)
}


