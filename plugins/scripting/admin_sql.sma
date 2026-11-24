// vim: set ts=4 sw=4 tw=99 noet:
//
// admin_sql - the SQL-admin flavour of admin.amxx.
//
// AMX Mod X 1.10 ships no separate admin_sql.sma: the official release build
// compiles plugins/admin.sma a second time with USING_SQL defined, and the
// admin.sma shipped in this tree keeps that define commented out near the top
// for exactly this purpose. The deployed admin_sql.amxx proves the same origin:
// its debug section embeds
//     /home/builds/amxmodx/linux-1.10/build/plugins/admin.sma
// with no admin_sql.sma anywhere in it (SOURCES.md records the check).
//
// This file is therefore a two-line build recipe rather than a fork: it defines
// USING_SQL and includes the one admin plugin source, so the SQL flavour can
// never drift away from the non-SQL flavour it is supposed to mirror.
//
// NOTE: plugins.ini loads admin.amxx, not this. Enabling both would register the
// admin commands and every native twice - enable at most one of the pair.

#define USING_SQL

#include "admin.sma"
