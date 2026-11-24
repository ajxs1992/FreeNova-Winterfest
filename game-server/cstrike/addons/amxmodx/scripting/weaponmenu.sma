#include <amxmodx>
#include <fun>
#include <cstrike>
#include <menabp>
#include <freenova_ui>

#define TASK_CLOSE_MENU 9200

new bool:g_HasSelected[MAX_PLAYERS + 1];
new g_RoundCount;
new g_pWeaponMenuEnabled;

public plugin_init() {
    register_plugin("Weapon Menu", "1.1", "Destroyer7");

    // Single gun-menu surface: the VIP Armory (freenova_vip) owns weapon
    // distribution and now also serves BattlePass weapon-menu holders. This
    // legacy menu is gated OFF by default so exactly ONE gun menu is
    // reachable. Set fn_weaponmenu_enabled 1 to re-enable this surface.
    g_pWeaponMenuEnabled = register_cvar("fn_weaponmenu_enabled", "0");

    register_clcmd("say /guns", "clcmd_guns");
    register_clcmd("say_team /guns", "clcmd_guns");
    register_event("HLTV", "event_new_round", "a", "1=0", "2=0");
    register_event("TextMsg", "event_round_reset", "a", "2&#Game_C", "2&#Game_w", "2&#Game_will_restart");
    register_logevent("event_round_reset", 2, "0=World triggered", "1=Restart_Round_");
    register_logevent("event_round_reset", 2, "0=World triggered", "1=Game_Commencing");
}

public plugin_cfg()
{
    // map start: next HLTV new-round (++) becomes round 1 = pistol round
    g_RoundCount = 0;
}

public event_round_reset()
{
    // sv_restart / game commencing: next HLTV new-round is the pistol round.
    // Reset only (never ++ here) so there is no double-count with event_new_round.
    g_RoundCount = 0;
    arrayset(g_HasSelected, false, sizeof(g_HasSelected));

    for (new id = 1; id <= MaxClients; id++)
        remove_task(id + TASK_CLOSE_MENU);
}

public client_putinserver(id)
{
    // slot reuse must not inherit the previous occupant's round state
    g_HasSelected[id] = false;
    remove_task(id + TASK_CLOSE_MENU);
}

public client_disconnected(id)
{
    g_HasSelected[id] = false;
    remove_task(id + TASK_CLOSE_MENU);
}

public event_new_round() {
    g_RoundCount++;
    arrayset(g_HasSelected, false, sizeof(g_HasSelected));

    for (new id = 1; id <= MaxClients; id++)
        remove_task(id + TASK_CLOSE_MENU);

    // Show menu during freeze time (only when this surface is enabled)
    if (get_pcvar_num(g_pWeaponMenuEnabled))
        set_task(0.2, "show_weapon_menu_to_all");
}


// menabp provider (battlepass_core.amxx) can be paused or unloaded (admin
// action, map-change window). Calling its natives then raises "dynanative
// into a paused plugin" runtime errors, so gate every call behind this.
stock bool:MenabpUsable()
{
    new total = get_pluginsnum()
    new file[64], title[32], version[16], author[32], status[16]
    for (new i = 0; i < total; i++)
    {
        get_plugin(i, file, charsmax(file), title, charsmax(title), version, charsmax(version), author, charsmax(author), status, charsmax(status));
        if (equali(file, "battlepass_core.amxx"))
            return equali(status, "running") ? true : false;
    }
    return bool:LibraryExists("menabp", LibType_Library);
}

public show_weapon_menu_to_all() {
    for (new id = 1; id <= MaxClients; id++) {
        if (is_user_connected(id) && is_user_alive(id)) {
            if (MenabpUsable() && menabp_has_weapon_menu(id)) {
                show_weapon_menu(id);
            }
        }
    }
}

public clcmd_guns(id)
{
    if (!get_pcvar_num(g_pWeaponMenuEnabled))
    {
        client_print(id, print_chat, "[Weapon Menu] The gun menu is currently disabled. Use /vmenu or /vip.");
        return PLUGIN_HANDLED;
    }

    if (!is_user_alive(id) || g_HasSelected[id])
    {
        return PLUGIN_HANDLED;
    }

    if(!MenabpUsable() || !menabp_has_weapon_menu(id))
    {
        client_print(id, print_chat, "[Weapon Menu] You have not unlocked Weapon Menu yet.");
        return PLUGIN_HANDLED;
    }

    show_weapon_menu(id);
    return PLUGIN_HANDLED;
}

public show_weapon_menu(id) {
    if (g_HasSelected[id]) return;

    // Stage branch: 1 = pistols, 2 = SMGs, 3+ = rifles.
    // g_RoundCount <= 0 (map start before the first HLTV) falls back to pistols.
    if (g_RoundCount == 2)
        show_smg_menu(id);
    else if (g_RoundCount >= 3)
        show_rifle_menu(id);
    else
        show_pistol_menu(id);
}

// Shared 15s expiry arm for all three stage menus.
stock arm_close_task(id)
{
    remove_task(id + TASK_CLOSE_MENU);
    set_task(15.0, "close_menu", id + TASK_CLOSE_MENU);
}

public show_pistol_menu(id) {
    new szTitle[64], szBase[64];
    // Two buffers: formatex() writes in place, so formatex(t, n, "%s...", t)
    // duplicated its own prefix into the menu title.
    FN_MenuTitle(szBase, charsmax(szBase), "Pistol Menu");
    formatex(szTitle, charsmax(szTitle), "%s^n\wRound 1 Loadout", szBase);
    new menu = menu_create(szTitle, "pistol_handler");

    menu_additem(menu, "\wDesert Eagle", "1", 0);
    menu_additem(menu, "\wUSP", "2", 0);
    menu_additem(menu, "\wP228", "3", 0);
    menu_additem(menu, "\wFive-SeveN", "4", 0);
    menu_additem(menu, "\wDual Elites^n\d------------------", "5", 0);

    menu_additem(menu, "\r[+] \wBuy Your Own", "6", 0);

    FN_MenuFinish(menu, false);
    menu_display(id, menu, 0);

    arm_close_task(id);
}

public pistol_handler(id, menu, item) {
    if (item == MENU_EXIT) {
        menu_destroy(menu);
        return;
    }

    // menu stays open through death - never strip/give weapons to a corpse
    if (!is_user_alive(id)) {
        menu_destroy(menu);
        return;
    }

    new info[3], name[64];
    new dummyAccess;
    menu_item_getinfo(menu, item, dummyAccess, info, charsmax(info), name, charsmax(name), dummyAccess);

    new key = str_to_num(info);

    if (g_HasSelected[id]) {
        menu_destroy(menu);
        return;
    }

    // Pistol round: keep knife/primary slot, replace the secondary only. No nades.
    strip_secondary_only(id);

    switch (key) {
        case 1: {
            give_item(id, "weapon_deagle");
            cs_set_user_bpammo(id, CSW_DEAGLE, 35);
            client_print(id, print_chat, "[Weapon Menu] You got Desert Eagle.");
        }
        case 2: {
            give_item(id, "weapon_usp");
            cs_set_user_bpammo(id, CSW_USP, 100);
            client_print(id, print_chat, "[Weapon Menu] You got USP.");
        }
        case 3: {
            give_item(id, "weapon_p228");
            cs_set_user_bpammo(id, CSW_P228, 52);
            client_print(id, print_chat, "[Weapon Menu] You got P228.");
        }
        case 4: {
            give_item(id, "weapon_fiveseven");
            cs_set_user_bpammo(id, CSW_FIVESEVEN, 100);
            client_print(id, print_chat, "[Weapon Menu] You got Five-SeveN.");
        }
        case 5: {
            give_item(id, "weapon_elite");
            cs_set_user_bpammo(id, CSW_ELITE, 120);
            client_print(id, print_chat, "[Weapon Menu] You got Dual Elites.");
        }
        case 6: {
            client_print(id, print_chat, "[Weapon Menu] You chose to buy your own weapons.");
        }
    }

    g_HasSelected[id] = true;
    menu_destroy(menu);
}

public show_smg_menu(id) {
    new szTitle[64], szBase[64];
    // Two buffers (see show_pistol_menu).
    FN_MenuTitle(szBase, charsmax(szBase), "SMG Menu");
    formatex(szTitle, charsmax(szTitle), "%s^n\wRound 2 Loadout", szBase);
    new menu = menu_create(szTitle, "smg_handler");

    menu_additem(menu, "\wFAMAS", "1", 0);
    menu_additem(menu, "\wGalil", "2", 0);
    menu_additem(menu, "\wScout^n\d------------------", "3", 0);

    menu_additem(menu, "\r[+] \wBuy Your Own", "4", 0);

    FN_MenuFinish(menu, false);
    menu_display(id, menu, 0);

    arm_close_task(id);
}

public smg_handler(id, menu, item) {
    if (item == MENU_EXIT) {
        menu_destroy(menu);
        return;
    }

    // menu stays open through death - never strip/give weapons to a corpse
    if (!is_user_alive(id)) {
        menu_destroy(menu);
        return;
    }

    new info[3], name[64];
    new dummyAccess;
    menu_item_getinfo(menu, item, dummyAccess, info, charsmax(info), name, charsmax(name), dummyAccess);

    new key = str_to_num(info);

    if (g_HasSelected[id]) {
        menu_destroy(menu);
        return;
    }

    // SMG round: replace the primary only, keep the secondary. No nades.
    strip_primary_only(id);

    switch (key) {
        case 1: {
            give_item(id, "weapon_famas");
            cs_set_user_bpammo(id, CSW_FAMAS, 90);
            client_print(id, print_chat, "[Weapon Menu] You got FAMAS.");
        }
        case 2: {
            give_item(id, "weapon_galil");
            cs_set_user_bpammo(id, CSW_GALIL, 90);
            client_print(id, print_chat, "[Weapon Menu] You got Galil.");
        }
        case 3: {
            give_item(id, "weapon_scout");
            cs_set_user_bpammo(id, CSW_SCOUT, 90);
            client_print(id, print_chat, "[Weapon Menu] You got Scout.");
        }
        case 4: {
            client_print(id, print_chat, "[Weapon Menu] You chose to buy your own weapons.");
        }
    }

    g_HasSelected[id] = true;
    menu_destroy(menu);
}

public show_rifle_menu(id) {
    new szTitle[64], szBase[64];
    // Two buffers (see show_pistol_menu): formatex() writes in place.
    FN_MenuTitle(szBase, charsmax(szBase), "Weapon Menu");
    formatex(szTitle, charsmax(szTitle), "%s^n\wSelect your weapon", szBase);
    new menu = menu_create(szTitle, "menu_handler");


    // 1 = AK
    menu_additem(menu, "\wAK47 + DEAGLE + NADES", "1", 0);

    // 2 = M4
    menu_additem(menu, "\wM4A1 + DEAGLE + NADES", "2", 0);

    new cb = menu_makecallback("weapon_item_callback");
    // 3 = AWP
    if(MenabpUsable() && menabp_has_weapon_menu_awp(id))
        menu_additem(menu, "\wAWP + DEAGLE + NADES \d(30 Ammo)^n\d------------------", "3", 0);
    else
        menu_additem(menu, "\dAWP \r(LOCKED)", "3", 0, cb);

    menu_additem(menu, "\r[+] \wBuy Your Own", "4", 0);

    FN_MenuFinish(menu, false);
    menu_display(id, menu, 0);

    arm_close_task(id);
}

public weapon_item_callback(id, menu, item)
{
    new info[3], dummy;
    menu_item_getinfo(menu, item, dummy, info, charsmax(info), _, _, dummy);
    if (str_to_num(info) == 3 && (!MenabpUsable() || !menabp_has_weapon_menu_awp(id)))
        return ITEM_DISABLED;
    return ITEM_ENABLED;
}

public menu_handler(id, menu, item) {
    if (item == MENU_EXIT) {
        menu_destroy(menu);
        return;
    }

    // menu stays open through death - never strip/give weapons to a corpse
    if (!is_user_alive(id)) {
        menu_destroy(menu);
        return;
    }

    new info[3], name[64];
    new dummyAccess;
    menu_item_getinfo(menu, item, dummyAccess, info, charsmax(info), name, charsmax(name), dummyAccess);

    new key = str_to_num(info);

    if (g_HasSelected[id]) {
        menu_destroy(menu);
        return;
    }

    // Sirf primary aur secondary weapons hatayein
    strip_primary_secondary(id);

    switch (key) {
        case 1: {
            give_item(id, "weapon_ak47");
            cs_set_user_bpammo(id, CSW_AK47, 90);
            give_item(id, "weapon_deagle");
            cs_set_user_bpammo(id, CSW_DEAGLE, 35);
            give_nades(id);
            client_print(id, print_chat, "[Weapon Menu] You got AK47 + DEAGLE + NADES.");
        }
        case 2: {
            give_item(id, "weapon_m4a1");
            cs_set_user_bpammo(id, CSW_M4A1, 90);
            give_item(id, "weapon_deagle");
            cs_set_user_bpammo(id, CSW_DEAGLE, 35);
            give_nades(id);
            client_print(id, print_chat, "[Weapon Menu] You got M4A1 + DEAGLE + NADES.");
        }
        case 3:
        {
            if (!MenabpUsable() || !menabp_has_weapon_menu_awp(id))
            {
                client_print(id, print_chat, "[Weapon Menu] AWP unlock is not available yet.");
                menu_destroy(menu);
                return;
            }

            give_item(id, "weapon_awp");
            cs_set_user_bpammo(id, CSW_AWP, 30);
            give_item(id, "weapon_deagle");
            cs_set_user_bpammo(id, CSW_DEAGLE, 35);
            give_nades(id);
            client_print(id, print_chat, "[Weapon Menu] You got AWP + DEAGLE + NADES.");
        }
        case 4: {
            client_print(id, print_chat, "[Weapon Menu] You chose to buy your own weapons.");
        }
    }

    g_HasSelected[id] = true;
    menu_destroy(menu);
}

public close_menu(taskid) {
    new id = taskid - TASK_CLOSE_MENU;
    if (!(1 <= id <= MaxClients))
        return;

    // Already chose (the handler destroys the menu and latches the flag).
    if (g_HasSelected[id])
        return;

    // REVIEW.md §5.5: this used to latch g_HasSelected and nothing else, so
    // the 15s "expiry" left the window open. A click after the deadline then
    // reached a handler whose first check is `if (g_HasSelected[id])`, which
    // destroyed the menu and threw the choice away with no message - the menu
    // silently ate the click. Cancel the client's window so it really does
    // expire, and say so.
    menu_cancel(id);
    g_HasSelected[id] = true;

    if (is_user_connected(id) && is_user_alive(id))
        client_print(id, print_chat, "[Weapon Menu] Time is up - buy your own weapons this round.");
}

stock give_nades(id) {
    give_item(id, "weapon_hegrenade");
    give_item(id, "weapon_flashbang");
}

// give_armor_and_defuse() removed: every call site was commented out, so the
// stock was dead code. Armor/defuser handling stays owned by the live menu
// loadout logic (restoring it would change menu balance - do not re-add
// casually).

stock strip_secondary_only(id) {
    new weapons[32], num;
    get_user_weapons(id, weapons, num);

    for (new i = 0; i < num; i++) {
        new wid = weapons[i];
        if (wid == CSW_P228 || wid == CSW_DEAGLE || wid == CSW_GLOCK18
            || wid == CSW_ELITE || wid == CSW_USP || wid == CSW_FIVESEVEN) {
            new wname[32];
            get_weaponname(wid, wname, charsmax(wname));
            engclient_cmd(id, "drop", wname);
        }
    }
}

stock strip_primary_only(id) {
    new weapons[32], num;
    get_user_weapons(id, weapons, num);

    for (new i = 0; i < num; i++) {
        new wid = weapons[i];
        if (wid == CSW_M4A1 || wid == CSW_AK47 || wid == CSW_AWP || wid == CSW_AUG
            || wid == CSW_GALIL || wid == CSW_FAMAS || wid == CSW_SG552 || wid == CSW_SCOUT
            || wid == CSW_SG550 || wid == CSW_M249 || wid == CSW_G3SG1 || wid == CSW_MP5NAVY
            || wid == CSW_MAC10 || wid == CSW_UMP45 || wid == CSW_P90 || wid == CSW_TMP) {
            new wname[32];
            get_weaponname(wid, wname, charsmax(wname));
            engclient_cmd(id, "drop", wname);
        }
    }
}

stock strip_primary_secondary(id) {
    new weapons[32], num;
    get_user_weapons(id, weapons, num);

    for (new i = 0; i < num; i++) {
        new wid = weapons[i];
        if (wid == CSW_KNIFE || wid == CSW_C4 || wid == CSW_HEGRENADE || wid == CSW_FLASHBANG || wid == CSW_SMOKEGRENADE)
            continue;

        if ((1 <= wid <= CSW_P228) || (wid == CSW_DEAGLE) || (wid == CSW_GLOCK18) || (wid == CSW_ELITE) || 
            (wid == CSW_USP) || (wid == CSW_FIVESEVEN) || 
            (wid == CSW_M4A1) || (wid == CSW_AK47) || (wid == CSW_AWP) || (wid == CSW_AUG) || 
            (wid == CSW_GALIL) || (wid == CSW_FAMAS) || (wid == CSW_SG552) || (wid == CSW_SCOUT) || 
            (wid == CSW_SG550) || (wid == CSW_M249) || (wid == CSW_G3SG1) || (wid == CSW_MP5NAVY) || 
            (wid == CSW_MAC10) || (wid == CSW_UMP45) || (wid == CSW_P90) || (wid == CSW_TMP)) {
            
            new wname[32];
            get_weaponname(wid, wname, charsmax(wname));
            engclient_cmd(id, "drop", wname);
        }
    }
}
