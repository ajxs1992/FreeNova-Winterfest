#if defined _freenova_panelstats_included
    #endinput
#endif
#define _freenova_panelstats_included

// freenova_panel.amxx stats access (persisted in vault "freenova_stats")
// Field indexes mirror the panel's PlayerStats enum:
#define FNSTAT_KILLS        0
#define FNSTAT_DEATHS       1
#define FNSTAT_HEADSHOTS    2
#define FNSTAT_BOMB_PLANTS  3
#define FNSTAT_BOMB_DEFUSES 4
#define FNSTAT_WIN_CT       5
#define FNSTAT_WIN_T        6
#define FNSTAT_MVP          7
#define FNSTAT_PLAYTIME     8   // minutes

// Returns a live stat for a connected player (0 when invalid).
native fnstats_get(id, iField);
