#include < amxmodx >
#include < menabp >
#include <freenova_vip>
#include < fakemeta >
#include < engine >
#include < fun >
#include < hamsandwich >
#include < nvault >
#include <freenova_ui>

#pragma semicolon 1

/*	Defines
 --*------------------------------------------------------------------------------------------------*/

#define PLUGIN 		"Advanced Parachute"
#define VERSION 	"0.1.2"
#define AUTHOR 		"Blizzard_87"

#define cm(%0)		( sizeof(%0) - 1 )

#define NO_ATTACK	( 1<<0 ) // "a" Enable / Disable Use Of Weapons While Parachuting
#define THIRD_PERSON	( 1<<1 ) // "b" Enable / Disable 3rd Person View While Parachuting
#define SILENT_PARA	( 1<<2 ) // "c" Enable / Disable Silent Parachute

/*	Enums
 --*------------------------------------------------------------------------------------------------*/

enum _:mData
{
    m_iParaEnt,
    m_iViewModel,
    m_iFallSpeed,
    m_iDeployMode,
    m_bThirdPerson,
    m_bHasPara
};

enum
{
    Tap = 0,
    Hold,
    Auto
};

enum _:mFloats
{
    m_szSpeed[32],
    Float:m_flSpeed
};

new const PARA_CLASS[]   = "parachute";
new const PARA_MODEL[]   = "models/parachute.mdl";
new const PARA_VIEW[]    = "models/rpgrocket.mdl";
new const g_szUseSound[] = "common/wpn_denyselect.wav";

const m_flNextSecondaryAttack = 47;
const XO_PLAYER = 5;
const m_flFallVelocity = 251;

new const g_FallSpeeds[][mFloats] =
{
    { "Slow", -50.0 },
    { "Normal", -100.0 },
    { "Fast", -150.0 },
    { "Very Fast", -200.0 }
};

new const g_ParaMode[][] = { "Tap", "Hold", "Auto" };

new HamHook:_HamPreThink;
new g_ForwardEmitSound;

new g_mPlayerData[33][mData];

new g_pParaBits;

new g_iFlags;
new g_iVault;
new g_iWeapon[33];

public plugin_precache()
{
    precache_model(PARA_MODEL);
    precache_model(PARA_VIEW);
}

public plugin_init()
{
    register_plugin(PLUGIN, VERSION, AUTHOR);
    register_cvar("adv_parahchute", VERSION, FCVAR_SERVER|FCVAR_SPONLY);

    g_ForwardEmitSound = register_forward(FM_EmitSound, "Forward_EmitSound", 0);

    register_logevent("LogEvent_RoundStart", 2, "1=Round_Start");

    _HamPreThink = RegisterHam(Ham_Player_PreThink, "player", "CBasePlayer_PreThink", 0);

    g_pParaBits = register_cvar("amx_para_settings", "bc");

    register_clcmd("say /para", "ClCmd_Parachute", 0);
}

public plugin_cfg()
{
    g_iVault = nvault_open("adv_parachute");

    if(g_iVault == INVALID_HANDLE)
    {
        set_fail_state("Error opening nVault");
    }

    g_iFlags = Get_Para_Flags();
}

public LogEvent_RoundStart()
{
    g_iFlags = Get_Para_Flags();
}

public Forward_EmitSound(index, Channel, const szSound[])
{
    #pragma unused Channel

    if(is_user_alive(index))
    {
        if(equali(szSound, g_szUseSound) && !(pev(index, pev_flags) & FL_ONGROUND))
        {
            if(g_iFlags & SILENT_PARA)
            {
                return FMRES_SUPERCEDE;
            }
        }
    }

    return FMRES_IGNORED;
}

// menabp provider (battlepass_core.amxx) can be paused or unloaded (admin
// action, map-change window). Calling its natives then raises "dynanative
// into a paused plugin" runtime errors, so gate every call behind this.
new Float:g_fBpUsableAt = -10.0;
new bool:g_bBpUsableCache = false;

stock bool:MenabpUsable()
{
    // Per-frame callers (PreThink): the plugin-list scan is far too heavy
    // every frame, so refresh the verdict at most once per second. Provider
    // pause/unload still takes effect within ~1s.
    new Float:fNow = get_gametime();
    if (fNow - g_fBpUsableAt >= 1.0)
    {
        g_fBpUsableAt = fNow;
        g_bBpUsableCache = false;
        new total = get_pluginsnum();
        new file[64], title[32], version[16], author[32], status[16];
        for (new i = 0; i < total; i++)
        {
            get_plugin(i, file, charsmax(file), title, charsmax(title), version, charsmax(version), author, charsmax(author), status, charsmax(status));
            if (equali(file, "battlepass_core.amxx"))
            {
                g_bBpUsableCache = equali(status, "running") ? true : false;
                break;
            }
        }
        if (!g_bBpUsableCache)
            g_bBpUsableCache = bool:LibraryExists("menabp", LibType_Library);
    }
    return g_bBpUsableCache;
}

// VIP+ members fly on tier alone (owner ruling): same physics, no combat
// side effects. BP-skill holders unaffected.
new g_pVipParaCvar = 0;

stock bool:VipHasParachute(index)
{
    if (!LibraryExists("freenova_vip", LibType_Library))
        return false;
    // Honors the server master switch (vip_parachute in freenova_vip):
    // 0 grounds everyone. Missing cvar = default enabled. The pointer is
    // cached (cvar lookup every frame is wasteful; pointers stay valid).
    if (!g_pVipParaCvar)
        g_pVipParaCvar = get_cvar_pointer("vip_parachute");
    if (g_pVipParaCvar && get_pcvar_num(g_pVipParaCvar) != 1)
        return false;
    return fnvip_get_tier(index) >= FNVIP_VIPPLUS ? true : false;
}

public CBasePlayer_PreThink(index)
{
    if(!is_user_alive(index))
    {
        return;
    }

    if((!MenabpUsable() || !menabp_has_parachute(index)) && !VipHasParachute(index))
    {
        if(g_mPlayerData[index][m_iParaEnt] > 0)
        {
            RemoveParachute(index);
        }
        return;
    }

    switch(g_mPlayerData[index][m_iDeployMode])
    {
        case Tap:
        {
            // Toggle mode: press +use to open, press again to close
            new bool:bNewUse = (pev(index, pev_button) & IN_USE) && !(get_user_oldbutton(index) & IN_USE);
            new bool:bOnGround = (pev(index, pev_flags) & FL_ONGROUND) ? true : false;

            if(bNewUse && !bOnGround)
            {
                if(g_mPlayerData[index][m_bHasPara])
                {
                    // Toggle OFF
                    RemoveParachute(index);
                }
                else
                {
                    // Toggle ON
                    g_mPlayerData[index][m_iParaEnt] = CreateParachute(index);
                    g_mPlayerData[index][m_bHasPara] = true;
                }
            }

            if(g_mPlayerData[index][m_bHasPara])
            {
                if(!bOnGround && !(pev(index, pev_movetype) == MOVETYPE_FLY))
                {
                    DeployParachute(index);

                    if(g_iFlags & NO_ATTACK)
                    {
                        Disable_Attack(index);
                    }

                    if((g_iFlags & THIRD_PERSON) && g_mPlayerData[index][m_bThirdPerson])
                    {
                        set_view(index, CAMERA_3RDPERSON);
                    }
                }
                else
                {
                    RemoveParachute(index);
                }
            }
        }

        case Hold:
        {
            if((pev(index, pev_button) & IN_USE) &&
                !(pev(index, pev_flags) & FL_ONGROUND) &&
                !(pev(index, pev_movetype) == MOVETYPE_FLY))
            {
                if(g_mPlayerData[index][m_iParaEnt] <= 0)
                {
                    g_mPlayerData[index][m_iParaEnt] = CreateParachute(index);
                    g_mPlayerData[index][m_bHasPara] = true;
                }
                else
                {
                    DeployParachute(index);

                    if(g_iFlags & NO_ATTACK)
                    {
                        Disable_Attack(index);
                    }

                    if((g_iFlags & THIRD_PERSON) && g_mPlayerData[index][m_bThirdPerson])
                    {
                        set_view(index, CAMERA_3RDPERSON);
                    }
                }
            }
            else
            {
                RemoveParachute(index);
            }
        }

        case Auto:
        {
            static Float:flFallVelocity;
            flFallVelocity = get_pdata_float(index, m_flFallVelocity, XO_PLAYER);

            if((!g_mPlayerData[index][m_bHasPara]) &&
                (flFallVelocity >= 350.0) &&
                (g_mPlayerData[index][m_iParaEnt] <= 0))
            {
                g_mPlayerData[index][m_iParaEnt] = CreateParachute(index);
                g_mPlayerData[index][m_bHasPara] = true;

                if(!(g_iFlags & SILENT_PARA))
                {
                    emit_sound(0, CHAN_AUTO, g_szUseSound, VOL_NORM, ATTN_NORM, 0, PITCH_NORM);
                }
            }

            if(g_mPlayerData[index][m_bHasPara] &&
                !(pev(index, pev_flags) & FL_ONGROUND) &&
                !(pev(index, pev_movetype) == MOVETYPE_FLY))
            {
                DeployParachute(index);

                if(g_iFlags & NO_ATTACK)
                {
                    Disable_Attack(index);
                }

                if((g_iFlags & THIRD_PERSON) && g_mPlayerData[index][m_bThirdPerson])
                {
                    set_view(index, CAMERA_3RDPERSON);
                }
            }
            else
            {
                RemoveParachute(index);
            }
        }
    }
}

public plugin_pause()
{
    DisableHamForward(_HamPreThink);
    unregister_forward(FM_EmitSound, g_ForwardEmitSound, 0);

    new iPlayers[32], iNum, i, Players;
    get_players(iPlayers, iNum);

    for(i = 0; i < iNum; i++)
    {
        Players = iPlayers[i];
        if(g_mPlayerData[Players][m_iParaEnt] > 0)
        {
            RemoveParachute(Players);
        }
    }
}

public plugin_unpause()
{
    EnableHamForward(_HamPreThink);
    g_ForwardEmitSound = register_forward(FM_EmitSound, "Forward_EmitSound", 0);
}

public client_putinserver(index)
{
    // slot reuse must not inherit a stale parachute entity reference
    g_mPlayerData[index][m_iParaEnt] = 0;
    g_mPlayerData[index][m_bHasPara] = false;
    g_iWeapon[index] = 0;
    LoadData(index);
}

public client_disconnected(index)
{
    // remove a deployed parachute before the slot is freed, or the
    // entity follows the next occupant of this id
    if(g_mPlayerData[index][m_iParaEnt] > 0)
    {
        RemoveParachute(index);
    }
    SaveData(index);
}

public plugin_end()
{
    nvault_close(g_iVault);
}

public ClCmd_Parachute(index)
{
    if((!MenabpUsable() || !menabp_has_parachute(index)) && !VipHasParachute(index))
    {
        client_print(index, print_chat, "[Parachute] You have not unlocked parachute yet.");
        return PLUGIN_HANDLED;
    }

    if(g_mPlayerData[index][m_bHasPara])
    {
        return PLUGIN_HANDLED;
    }

    new szTitle[64];
    FN_MenuTitle(szTitle, charsmax(szTitle), "Parachute Settings");
    new menu = menu_create(szTitle, "ClCmd_Handler");
    new szItem[64];

    formatex(szItem, cm(szItem), "Deploy Mode - | \r%s\w |", g_ParaMode[g_mPlayerData[index][m_iDeployMode]]);
    menu_additem(menu, szItem);

    formatex(szItem, cm(szItem), "3rd Person View - | \r%s\w |", g_mPlayerData[index][m_bThirdPerson] ? "On" : "Off");
    menu_additem(menu, szItem);

    formatex(szItem, cm(szItem), "Parachute Fall Speed - | \r%s\w |", g_FallSpeeds[g_mPlayerData[index][m_iFallSpeed]][m_szSpeed]);
    menu_additem(menu, szItem);

    FN_MenuFinish(menu, false);
    menu_display(index, menu);
    return PLUGIN_HANDLED;
}

public ClCmd_Handler(index, menu, item)
{
    switch(item)
    {
        case 0:
        {
            g_mPlayerData[index][m_iDeployMode]++;
            if(g_mPlayerData[index][m_iDeployMode] > 2)
            {
                g_mPlayerData[index][m_iDeployMode] = 0;
            }

            menu_destroy(menu);
            ClCmd_Parachute(index);
            return PLUGIN_HANDLED;
        }

        case 1:
        {
            g_mPlayerData[index][m_bThirdPerson] = !g_mPlayerData[index][m_bThirdPerson];

            if(!g_mPlayerData[index][m_bThirdPerson])
            {
                set_view(index, CAMERA_NONE);
            }

            menu_destroy(menu);
            ClCmd_Parachute(index);
            return PLUGIN_HANDLED;
        }

        case 2:
        {
            if(g_mPlayerData[index][m_iFallSpeed] >= cm(g_FallSpeeds))
            {
                g_mPlayerData[index][m_iFallSpeed] = 0;
            }
            else
            {
                g_mPlayerData[index][m_iFallSpeed] += 1;
            }

            menu_destroy(menu);
            ClCmd_Parachute(index);
            return PLUGIN_HANDLED;
        }

        case MENU_EXIT:
        {
        }
    }

    menu_destroy(menu);
    return PLUGIN_HANDLED;
}

CreateParachute(index)
{
    new entid = create_entity("info_target");
    if(entid > 0)
    {
        entity_set_string(entid, EV_SZ_classname, PARA_CLASS);
        entity_set_model(entid, PARA_MODEL);
        entity_set_int(entid, EV_INT_movetype, MOVETYPE_FOLLOW);
        entity_set_int(entid, EV_INT_solid, SOLID_NOT);
        entity_set_edict(entid, EV_ENT_aiment, index);
        entity_set_edict(entid, EV_ENT_owner, index);
        entity_set_int(entid, EV_INT_sequence, 0);
        entity_set_int(entid, EV_INT_gaitsequence, 1);
        entity_set_float(entid, EV_FL_frame, 0.0);
        entity_set_float(entid, EV_FL_fuser1, 0.0);

        return entid;
    }
    return 0;
}

DeployParachute(index)
{
    new Float:velocity[3];
    new Float:frame;
    entity_get_vector(index, EV_VEC_velocity, velocity);

    new iNum = g_mPlayerData[index][m_iFallSpeed];

    velocity[2] = (velocity[2] + 40.0 < g_FallSpeeds[iNum][m_flSpeed]) ? velocity[2] + 40.0 : g_FallSpeeds[iNum][m_flSpeed];
    entity_set_vector(index, EV_VEC_velocity, velocity);

    new entid = g_mPlayerData[index][m_iParaEnt];
    if(entid <= 0 || !pev_valid(entid))
    {
        g_mPlayerData[index][m_iParaEnt] = 0;
        g_mPlayerData[index][m_bHasPara] = false;
        return;
    }

    if(entity_get_int(entid, EV_INT_sequence) == 0)
    {
        frame = entity_get_float(entid, EV_FL_fuser1) + 1.0;
        entity_set_float(entid, EV_FL_fuser1, frame);
        entity_set_float(entid, EV_FL_frame, frame);

        if(frame > 100.0)
        {
            entity_set_float(entid, EV_FL_animtime, 0.0);
            entity_set_float(entid, EV_FL_framerate, 0.4);
            entity_set_int(entid, EV_INT_sequence, 1);
            entity_set_int(entid, EV_INT_gaitsequence, 1);
            entity_set_float(entid, EV_FL_frame, 0.0);
            entity_set_float(entid, EV_FL_fuser1, 0.0);
        }
    }
}

RemoveParachute(index)
{
    new entid = g_mPlayerData[index][m_iParaEnt];
    if(entid > 0)
    {
        if(pev_valid(entid))
        {
            new szClass[32];
            pev(entid, pev_classname, szClass, charsmax(szClass));
            if(equal(szClass, PARA_CLASS))
                remove_entity(entid);
        }
        g_mPlayerData[index][m_iParaEnt] = 0;
        g_mPlayerData[index][m_bHasPara] = false;

        if(g_mPlayerData[index][m_bThirdPerson])
        {
            set_view(index, CAMERA_NONE);
        }

        if(g_iFlags & NO_ATTACK)
        {
            // g_iWeapon is 0 when the player deployed while holding the knife
            // (or on a fresh slot): never send an empty weapon command.
            if (g_iWeapon[index] > 0)
            {
                new szWeapon[32];
                get_weaponname(g_iWeapon[index], szWeapon, cm(szWeapon));
                if (szWeapon[0])
                    engclient_cmd(index, szWeapon);
            }
        }
    }
}

Get_Para_Flags()
{
    new szFlags[4];
    get_pcvar_string(g_pParaBits, szFlags, cm(szFlags));
    return read_flags(szFlags);
}

GetPlayerAuthid(index, bGet = false)
{
    static szSteamID[33][21];

    if(bGet)
    {
        get_user_authid(index, szSteamID[index], cm(szSteamID[]));
    }

    return szSteamID[index];
}

LoadData(index)
{
    new szVaultData[32], Dummy1[2], Dummy2[2], Dummy3[2];

    if(nvault_get(g_iVault, GetPlayerAuthid(index, true), szVaultData, cm(szVaultData)))
    {
        parse(szVaultData, Dummy1, cm(Dummy1), Dummy2, cm(Dummy2), Dummy3, cm(Dummy3));
        g_mPlayerData[index][m_iDeployMode] = str_to_num(Dummy1);
        g_mPlayerData[index][m_iFallSpeed] = str_to_num(Dummy2);
        g_mPlayerData[index][m_bThirdPerson] = bool:str_to_num(Dummy3);
    }
    else
    {
        g_mPlayerData[index][m_iDeployMode] = Tap;
        g_mPlayerData[index][m_iFallSpeed] = 1;
        g_mPlayerData[index][m_bThirdPerson] = false;
    }
}

SaveData(index)
{
    new szVaultData[32], szSteamID[32];

    get_user_authid(index, szSteamID, cm(szSteamID));

    formatex(szVaultData, cm(szVaultData), "%i %i %i",
        g_mPlayerData[index][m_iDeployMode],
        g_mPlayerData[index][m_iFallSpeed],
        g_mPlayerData[index][m_bThirdPerson]);

    nvault_set(g_iVault, szSteamID, szVaultData);
}

stock Disable_Attack(index)
{
    new iWeapon = get_user_weapon(index);

    if(iWeapon != CSW_KNIFE)
    {
        g_iWeapon[index] = iWeapon;
        engclient_cmd(index, "weapon_knife");
    }
}
