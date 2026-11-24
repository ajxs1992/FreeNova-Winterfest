// include/winterfest_cosmetics.inc
//
// Winterfest cosmetics: the registry's vocabulary and the natives
// winterfest_cosmetics.amxx registers (register_library("winterfest_cosmetics")).
//
// Every cosmetic lives in configs/freenova/winterfest/cosmetics.ini and has a
// STRING id (hat_xmas_red, present_classic, title_frost_keeper, ...). Award logic
// in the other Winterfest modules names an id or an index, never a file path, so
// changing what December looks like is a config edit
// (docs/WINTERFEST-COSMETICS.md).
//
// Optional for the rest of the tree, like every wf_* native: call
// LibraryExists("winterfest_cosmetics") first and install a native filter. The
// plugin itself loads with or without winterfest_core and without
// freenova_cosmetics; it only needs them for the derived entitlement sources and
// for the chat-tag slot they own (the docs spell out the fallbacks).

#if defined _winterfest_cosmetics_included
	#endinput
#endif

#define _winterfest_cosmetics_included

// ---------------------------------------------------------------------------
// Kinds - the `kind` column
// ---------------------------------------------------------------------------
//   hat    a model the engine hangs above a player's head   (client asset)
//   skin   a weapon model set (v_/w_/p_)                    (client asset)
//   model  any other model: a world prop, a player model,
//          a sky decoration                                 (client asset)
//   effect a sprite or a sound the server triggers          (client asset)
//   title  pure text: worn next to the name + in chat       (no asset)
//   badge  pure text: a shorter mark, same display path     (no asset)
#define WFCOS_KIND_UNKNOWN 0
#define WFCOS_KIND_HAT     1
#define WFCOS_KIND_SKIN    2
#define WFCOS_KIND_MODEL   3
#define WFCOS_KIND_TITLE   4
#define WFCOS_KIND_BADGE   5
#define WFCOS_KIND_EFFECT  6
// The three effect kinds are `effect` rows that are worn in a slot of their own
// and played by this plugin at a moment the engine already tells us about:
//   kill   what the KILLER's victim produces on death (a burst at the corpse)
//   death  what the DYING player leaves where they fell (an imprint, a prop)
//   spawn  a short flourish at the player's feet when they (re)spawn
// They are separate kinds rather than an `effect` sub-column because a kind IS
// the slot: one thing worn, one moment played, one row to read.
#define WFCOS_KIND_KILL    7
#define WFCOS_KIND_DEATH   8
#define WFCOS_KIND_SPAWN   9

// ---------------------------------------------------------------------------
// Weight - the `weight` column. What a CLIENT has to download, which is the only
// cost that matters once sv_allowdownload 1 makes it work:
//   small  < 150 KB   allowed on connect (the December dressing that is cheap)
//   medium < 1 MB     only with wf_cosmetics_heavy 1, and the player is told
//                     what it will cost before they equip it
//   heavy  >= 1 MB    the same, and the docs say plainly that this is a loading
//                     screen a player may quit on (docs/WINTERFEST.md sec 1.1)
#define WFCOS_W_SMALL  0
#define WFCOS_W_MEDIUM 1
#define WFCOS_W_HEAVY  2
#define WFCOS_SMALL_MAX  153600    // 150 KB
#define WFCOS_MEDIUM_MAX 1048576   // 1 MB

// ---------------------------------------------------------------------------
// Sources - the `source` column, i.e. HOW a cosmetic is earned.
// ---------------------------------------------------------------------------
// The core answers four of them (it is the score); only `gift` is recorded by
// this plugin, because the core has no cosmetics reward kind:
//   gift      a present paid it out            (recorded, flat file)
//   advent:N  advent day N was claimed          (wf_advent_claimed)
//   pass:N    Winter Pass tier N was reached    (wf_pass_tier)
//   tree:N    the tree reached level N          (wf_tree_level)
//   secret:N  ornament set N is complete        (wf_set_owned)
//   none      a staged asset the preflight watches, not awarded yet
#define WFCOS_SRC_NONE    0
#define WFCOS_SRC_GIFT    1
#define WFCOS_SRC_ADVENT  2
#define WFCOS_SRC_PASS    3
#define WFCOS_SRC_TREE    4
#define WFCOS_SRC_SECRET  5

// ---------------------------------------------------------------------------
// Equip slots - one hat AND one title/badge at a time
// ---------------------------------------------------------------------------
// Slots 3..5 are the effects. Each is independent: a player may wear one kill
// effect, one death effect and one spawn effect at the same time, and each one
// only ever fires at its own moment.
#define WFCOS_SLOT_NONE   0
#define WFCOS_SLOT_HAT    1
#define WFCOS_SLOT_TITLE  2
#define WFCOS_SLOT_KILL   3
#define WFCOS_SLOT_DEATH  4
#define WFCOS_SLOT_SPAWN  5
#define WFCOS_MAX_SLOTS   5

// ---------------------------------------------------------------------------
// Results
// ---------------------------------------------------------------------------
#define WFCOS_OK          1   // granted / equipped now
#define WFCOS_DUPLICATE   0   // already owned
#define WFCOS_INVALID    -1   // unknown index, wrong kind, not owned
#define WFCOS_DERIVED    -2   // earned through winterfest_core: not grantable
#define WFCOS_NOTLOADED  -3   // the player's registry data is not in memory yet

// ---------------------------------------------------------------------------
// Catalogue
// ---------------------------------------------------------------------------
native wfcos_count();
native wfcos_find(const cosmetic_id[]);                  // id -> index, 0 = unknown
native wfcos_id(index, output[], len);
native wfcos_name(index, output[], len);
native wfcos_kind(index);
native wfcos_weight(index);                              // WFCOS_W_*
native wfcos_rarity(index);                              // 0..2, same scale as winterfest.ini [rarity]
native wfcos_source(index);                              // WFCOS_SRC_*
native wfcos_source_value(index);                        // day / tier / level / set id
native wfcos_slot_of(index);                             // WFCOS_SLOT_*, 0 = not wearable
native wfcos_text(index, output[], len);                 // the title/badge text, "" for an asset

// Client assets. `declared_bytes` is the registry's own number, `wfcos_bytes`
// is what the files on THIS host actually add up to (0 when absent) - the
// preflight prints both so an operator can see a bad upload.
native wfcos_declared_bytes(index);
native wfcos_bytes(index);
native bool:wfcos_needs_download(index);
native wfcos_asset(index, output[], len);                // raw asset column (comma-separated)
native bool:wfcos_asset_present(index);                  // every named file exists here
native bool:wfcos_precached(index);                      // in this map's table (a client can get it)

// Entitlement
native bool:wfcos_owned(id, index);
native wfcos_grant(id, index);                           // WFCOS_OK / WFCOS_DUPLICATE / WFCOS_DERIVED
native wfcos_grant_id(id, const cosmetic_id[]);

// What a player wears
native wfcos_equip(id, index);                           // 0 clears that slot
native wfcos_equip_slot(id, slot, index);
native wfcos_equipped(id, slot);                         // index or 0
native wfcos_title_of(id, output[], len);                // the worn title/badge text

// The whole module in one question, and the menu entry point so the /christmas
// hub can offer cosmetics without owning the code.
native bool:wfcos_enabled();
native wfcos_open_menu(id);

// ---------------------------------------------------------------------------
// Effects (kill / death / spawn) - what the rest of the tree needs to know
// ---------------------------------------------------------------------------
// A player can wear one effect per slot (WFCOS_SLOT_KILL / _DEATH / _SPAWN);
// wfcos_equipped(id, slot) says which, and wfcos_owned(id, index) says whether
// they may. The effect itself is played by THIS plugin on Ham_Killed and
// Ham_Spawn - nothing else has to call in, and nothing else should fire a second
// sprite for the same moment or a kill produces two bursts.
//
// Switches an operator has (all in server.cfg, none needed for the default):
//   wf_fx 1              master switch for every effect. 0 = no sprite, no
//                        message, no entity: only the registry stays loaded.
//   wf_fx_entmax 12      ceilings on LIVE effect entities, global and per player
//   wf_fx_entmax_p 2     (see docs/WINTERFEST-COSMETICS.md sec 10.4). An effect
//                        over the ceiling still plays its message-only layer.
//   wf_fx_verb 1         0 = no kill line, 1 = killer + victim, 2 = everyone
//   wf_fx_lpm 1          1 = a player in Low Performance Mode gets the chat line
//                        only (no entity, no sprite)
//   wf_fx_debug 0        1 = one log_amx line per effect with the entity count

// One chat line, same shape as WfSay in winterfest.inc. The format is a literal
// and the text is an argument, so a player name with '%' cannot become a format
// string (lint rule 4).
stock WfcosSay(id, const text[])
{
	client_print_color(id, print_team_default, "^4[WF]^1 %s", text)
}
