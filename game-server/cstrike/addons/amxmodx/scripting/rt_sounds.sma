#include <amxmodx>
#include <fakemeta>
#include <hamsandwich>
#include <reapi>
#include <rt_api>

public stock const PLUGIN[] = "Revive Teammates: Sounds";
public stock const CFG_FILE[] = "addons/amxmodx/configs/rt_configs/rt_sounds.cfg";
public stock const INI_FILE[] = "addons/amxmodx/configs/rt_configs/rt_sounds.ini";

#define MAX_SOUNDS_PER_SECTION 10
#define MAX_SOUND_LENGTH 64

enum CVARS {
	Float:SOUND_RADIUS,
	NEARBY_PLAYERS,
	FORCE_FWD_MODE
};

new g_eCvars[CVARS];

enum sections_struct {
	SECTION_REVIVE_START,
	SECTION_REVIVE_LOOP,
	SECTION_REVIVE_END,
	SECTION_PLANT_START,
	SECTION_PLANT_LOOP,
	SECTION_PLANT_END
};

new sections_struct:g_eCurrentSection;
new g_iSounds[sections_struct];
new g_szSounds[sections_struct][MAX_SOUNDS_PER_SECTION][MAX_SOUND_LENGTH];
new g_iTicks[MAX_PLAYERS + 1];

public plugin_precache() {
	register_plugin(PLUGIN, VERSION, AUTHORS);

	if(!file_exists(INI_FILE)) {
		set_fail_state("[RT Sounds] File ^"%s^" not found", INI_FILE);
		return;
	}

	new INIParser:iParser = INI_CreateParser();
	INI_SetReaders(iParser, "ReadKeyValue", "ReadNewSection");
	INI_ParseFile(iParser, INI_FILE);
	INI_DestroyParser(iParser);

	CreateCvars();

	server_cmd("exec %s", CFG_FILE);
	server_exec();
}

public rt_revive_start(const iEnt, const iPlayer, const iActivator, const Modes:eMode) {
	if(is_nullent(iEnt) || !(1 <= iPlayer <= MaxClients) || !(1 <= iActivator <= MaxClients) || !is_user_connected(iActivator))
		return PLUGIN_CONTINUE;

	g_iTicks[iActivator] = 0;

	switch(eMode) {
		case MODE_REVIVE: { PlaybackSound(iEnt, iPlayer, iActivator, SECTION_REVIVE_START); }
		case MODE_PLANT: { PlaybackSound(iEnt, iPlayer, iActivator, SECTION_PLANT_START); }
	}

	return PLUGIN_CONTINUE;
}

public rt_revive_loop_post(const iEnt, const iPlayer, const iActivator, const Float:fTimer, Modes:eMode) {
	if(is_nullent(iEnt) || !(1 <= iPlayer <= MaxClients) || !(1 <= iActivator <= MaxClients) || !is_user_connected(iActivator))
		return;

	if(!g_eCvars[FORCE_FWD_MODE] || ++g_iTicks[iActivator] == 10) {
		g_iTicks[iActivator] = 0;

		switch(eMode) {
			case MODE_REVIVE: { PlaybackSound(iEnt, iPlayer, iActivator, SECTION_REVIVE_LOOP); }
			case MODE_PLANT: { PlaybackSound(iEnt, iPlayer, iActivator, SECTION_PLANT_LOOP); }
		}
	}
}

public rt_revive_end(const iEnt, const iPlayer, const iActivator, const Modes:eMode) {
	if(is_nullent(iEnt) || !(1 <= iPlayer <= MaxClients) || !(1 <= iActivator <= MaxClients) || !is_user_connected(iActivator))
		return;

	switch(eMode) {
		case MODE_REVIVE: {
			new Modes:iMode = Modes:get_entvar(iEnt, var_iuser3);

			if(iMode != MODE_PLANT)
				PlaybackSound(iEnt, iPlayer, iActivator, SECTION_REVIVE_END);
		}
		case MODE_PLANT: { PlaybackSound(iEnt, iPlayer, iActivator, SECTION_PLANT_END); }
	}
}

public bool:ReadNewSection(INIParser:iParser, const szSection[], bool:bInvalidTokens, bool:bCloseBracket) {
	if(!bCloseBracket) {
		log_error(AMX_ERR_NATIVE, "Closing bracket was not detected! Current section name '%s'.", szSection);
		return false;
	}

	if(equal(szSection, "revive_start")) {
		g_eCurrentSection = SECTION_REVIVE_START;
		return true;
	} else if(equal(szSection, "revive_loop")) {
		g_eCurrentSection = SECTION_REVIVE_LOOP;
		return true;
	} else if(equal(szSection, "revive_end")) {
		g_eCurrentSection = SECTION_REVIVE_END;
		return true;
	} else if(equal(szSection, "plant_start")) {
		g_eCurrentSection = SECTION_PLANT_START;
		return true;
	} else if(equal(szSection, "plant_loop")) {
		g_eCurrentSection = SECTION_PLANT_LOOP;
		return true;
	} else if(equal(szSection, "plant_end")) {
		g_eCurrentSection = SECTION_PLANT_END;
		return true;
	}

	return false;
}

public bool:ReadKeyValue(INIParser:handle, const szKey[], const szValue[]) {
	if(szKey[0] == EOS)
		return false;

	// hard limit: an 11th+ key in a section would write past the
	// g_szSounds[6][10][64] array (memory corruption / crash)
	if(g_iSounds[g_eCurrentSection] >= MAX_SOUNDS_PER_SECTION)
		return false;

	new szSound[MAX_SOUND_LENGTH];
	copy(szSound, charsmax(szSound), szKey);
	trim(szSound);
	copy(g_szSounds[g_eCurrentSection][g_iSounds[g_eCurrentSection]++], charsmax(g_szSounds[][]), szSound);

	precache_sound(szSound);

	return true;
}

stock PlaybackSound(const iEnt, const iPlayer, const iActivator, const sections_struct:iSoundSection) {
	if(g_iSounds[iSoundSection]) {
		// Forward args can be RT_NULLENT on cancelled revives - never send
		// audio to a non-client, and never read origin from a freed corpse.
		if(!(1 <= iActivator <= MaxClients) || !(1 <= iPlayer <= MaxClients)
			|| !is_user_connected(iActivator) || !is_user_connected(iPlayer))
			return;

		if(g_eCvars[NEARBY_PLAYERS] == 2 || (g_eCvars[NEARBY_PLAYERS] && (iSoundSection == SECTION_REVIVE_END || iSoundSection == SECTION_PLANT_END)))
			PlaybackSoundNearbyPlayers(iEnt, g_szSounds[iSoundSection][random(g_iSounds[iSoundSection])]);
		else if(!g_eCvars[NEARBY_PLAYERS]) {
			// one draw per event: activator and target hear the same sound
			new szSound[MAX_SOUND_LENGTH];
			copy(szSound, charsmax(szSound), g_szSounds[iSoundSection][random(g_iSounds[iSoundSection])]);
			rg_send_audio(iActivator, szSound);
			rg_send_audio(iPlayer, szSound);
		}
	}
}

stock PlaybackSoundNearbyPlayers(const iEnt, const szSound[]) {
	if(is_nullent(iEnt))
		return;

	new iEnt2 = RT_NULLENT;

	new Float:fVecOrigin[3];
	get_entvar(iEnt, var_vuser4, fVecOrigin);

	while((iEnt2 = engfunc(EngFunc_FindEntityInSphere, iEnt2, fVecOrigin, g_eCvars[SOUND_RADIUS])) > 0)
		if(1 <= iEnt2 <= MaxClients && is_user_connected(iEnt2) && ExecuteHam(Ham_IsPlayer, iEnt2))
			rg_send_audio(iEnt2, szSound);
}

public CreateCvars() {
	bind_pcvar_float(create_cvar(
		"rt_sound_radius",
		"250.0",
		FCVAR_NONE,
		"The radius in which to count the nearest players",
		true,
		1.0),
		g_eCvars[SOUND_RADIUS]
	);
	bind_pcvar_num(create_cvar(
		"rt_nearby_players",
		"0",
		FCVAR_NONE,
		"Play the resurrection/landing sound for nearby players. 0 - off, 1 - only ending sounds, 2 - all sounds",
		true,
		0.0,
		true,
		2.0),
		g_eCvars[NEARBY_PLAYERS]
	);

	new pCvar = get_cvar_pointer("rt_force_fwd_mode");

	if(pCvar)
		bind_pcvar_num(pCvar, g_eCvars[FORCE_FWD_MODE]);
}