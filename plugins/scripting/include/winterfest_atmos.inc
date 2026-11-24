// include/winterfest_atmos.inc
//
// Winterfest atmosphere: the seasonal gate, the ini plumbing and the two text
// helpers that winterfest_atmos.amxx and winterfest_killfeed.amxx share.
//
// WHY THIS IS ITS OWN HEADER
//   Workstream 6 owns two plugins, and both have to agree on exactly one thing:
//   whether the season is open right now. That answer comes from a date window
//   in configs/freenova/winterfest/atmos.ini, not from the core module, so both
//   plugins keep working when winterfest_core is missing (docs/WINTERFEST.md
//   §1.3: a module that needs the core pauses itself; atmosphere does not need
//   it at all).
//
//   Deliberately NOT #include <winterfest>: that header declares ~40 natives of
//   a module that is being written by another workstream right now. Everything
//   here is stock AMXX only, so this file compiles and runs standalone.
//
// THE WINDOW
//   [season] in atmos.ini holds two dates, and each one may be written either
//   as a full date or as a recurring month-day:
//
//       start = 2026-12-01      ; only 2026
//       end   = 2026-12-31
//       start = 12-01           ; every December, any year
//       end   = 12-31
//
//   A window where start > end wraps the new year (12-20 .. 01-06). A missing
//   or half-written ini falls back to 12-01..12-31 of every year and says so in
//   the AMXX log: December must never be dark because someone typo'd a config.
//
// EVALUATED ONCE PER MAP
//   WfAtmosOpenNow() is a date comparison, not a clock. The gate is evaluated
//   in plugin_cfg() (every map change) and on the operator command
//   `wf_atmos_apply`. That is on purpose: the alternative - a timer that wakes
//   up to re-check - would mean the outside-the-window state is not actually
//   idle, and "zero timers outside the window" is a requirement (see
//   docs/WINTERFEST-ATMOS.md).

#if defined _winterfest_atmos_included
	#endinput
#endif

#define _winterfest_atmos_included

// Directory of workstream 6's own config files, below addons/amxmodx/configs.
#define WF_ATMOS_DIR "freenova/winterfest"

// The window, as month*100+day plus an optional year (0 = every year).
new g_wfaStartMD;
new g_wfaEndMD;
new g_wfaStartYear;
new g_wfaEndYear;
new bool:g_wfaLoaded;

// ---------------------------------------------------------------------------
// Paths and dates
// ---------------------------------------------------------------------------
stock WfAtmosPath(output[], len, const file[])
{
	new dir[96];
	get_configsdir(dir, charsmax(dir));
	formatex(output, len, "%s/%s/%s", dir, WF_ATMOS_DIR, file);
}

// Today as year / month / day, from the engine clock (local time, like every
// other date gate in this stack).
stock WfAtmosToday(&year, &month, &day)
{
	new text[16];
	year = 0;
	month = 1;
	day = 1;
	get_time("%Y-%m-%d", text, charsmax(text));
	WfAtmosParseDate(text, year, month, day);
}

// Today as "2026-11-22", for log lines.
stock WfAtmosDateText(output[], len)
{
	new y, m, d;
	WfAtmosToday(y, m, d);
	if (y > 0)
		formatex(output, len, "%04d-%02d-%02d", y, m, d);
	else
		formatex(output, len, "%02d-%02d", m, d);
}

// Parse "2026-12-01" or "12-01". Non-digit characters are skipped, so a value
// that came out of an ini with stray whitespace still parses; anything that
// does not yield one or two dash-separated groups of 1..7 digits is refused
// (and the caller keeps its default instead of writing a half date).
stock bool:WfAtmosParseDate(const text[], &year, &month, &day)
{
	new field[3][8];
	new groups = 0, cur = 0;
	new len = strlen(text);

	field[0][0] = 0;
	field[1][0] = 0;
	field[2][0] = 0;

	for (new i = 0; i < len; i++)
	{
		if (text[i] == '-')
		{
			if (groups >= 2 || cur == 0)
				return false;          // more than two dashes, or an empty group
			groups++;
			cur = 0;
			continue;
		}
		if (text[i] < '0' || text[i] > '9')
			continue;                  // stray character: ignore, do not fail
		if (groups > 2 || cur >= charsmax(field[]) - 1)
			return false;
		field[groups][cur] = text[i];
		cur++;
		field[groups][cur] = 0;
	}

	if (groups == 1)
	{
		year = 0;
		month = str_to_num(field[0]);
		day = str_to_num(field[1]);
	}
	else if (groups == 2)
	{
		year = str_to_num(field[0]);
		month = str_to_num(field[1]);
		day = str_to_num(field[2]);
	}
	else
	{
		return false;
	}

	if (month < 1 || month > 12 || day < 1 || day > 31)
		return false;
	if (groups == 2 && (year < 2000 || year > 2100))
		return false;
	return true;
}

// Load the window from `file` (a name inside WF_ATMOS_DIR). Returns true when
// the file supplied a complete start+end pair; on any failure the built-in
// 12-01..12-31 window is left in place and the reason is logged.
stock bool:WfAtmosWindowLoad(const file[])
{
	g_wfaStartMD = 1201;
	g_wfaEndMD = 1231;
	g_wfaStartYear = 0;
	g_wfaEndYear = 0;
	g_wfaLoaded = false;

	new path[128];
	WfAtmosPath(path, charsmax(path), file);

	if (!file_exists(path))
	{
		log_amx("[WF-ATMOS] %s missing - built-in window 12-01..12-31 (every year)", path);
		return false;
	}

	new fp = fopen(path, "rt");
	if (!fp)
	{
		log_amx("[WF-ATMOS] %s unreadable - built-in window 12-01..12-31", path);
		return false;
	}

	new line[192], section[24], key[24], val[32];
	new y1, m1, d1, y2, m2, d2;
	new bool:haveStart = false;
	new bool:haveEnd = false;

	section[0] = 0;
	while (fgets(fp, line, charsmax(line)))
	{
		trim(line);
		if (!line[0] || line[0] == ';' || line[0] == '#')
			continue;

		if (line[0] == '[')
		{
			copy(section, charsmax(section), line[1]);
			new close = contain(section, "]");
			if (close >= 0)
				section[close] = 0;
			trim(section);
			strtolower(section);
			continue;
		}

		if (!equal(section, "season"))
			continue;

		new eq = contain(line, "=");
		if (eq < 1)
			continue;

		copy(key, charsmax(key), line);
		key[eq] = 0;
		trim(key);
		strtolower(key);
		copy(val, charsmax(val), line[eq + 1]);
		trim(val);

		// The product's own season file writes dates as "2026-12-01 00:00"
		// (docs/WINTERFEST.md §6.3). An operator will copy that shape here, so
		// cut the time of day off instead of refusing the value: this window is
		// compared by calendar date only.
		new space = contain(val, " ");
		if (space > 0)
		{
			val[space] = 0;
			trim(val);
		}

		if (equal(key, "start"))
		{
			if (WfAtmosParseDate(val, y1, m1, d1))
				haveStart = true;
			else
				log_amx("[WF-ATMOS] %s: [season] start '%s' is not YYYY-MM-DD or MM-DD", path, val);
		}
		else if (equal(key, "end"))
		{
			if (WfAtmosParseDate(val, y2, m2, d2))
				haveEnd = true;
			else
				log_amx("[WF-ATMOS] %s: [season] end '%s' is not YYYY-MM-DD or MM-DD", path, val);
		}
	}
	fclose(fp);

	if (!haveStart || !haveEnd)
	{
		log_amx("[WF-ATMOS] %s needs both start and end in [season] - built-in window 12-01..12-31 used", path);
		return false;
	}

	g_wfaStartMD = m1 * 100 + d1;
	g_wfaEndMD = m2 * 100 + d2;
	g_wfaStartYear = y1;
	g_wfaEndYear = y2;
	g_wfaLoaded = true;
	return true;
}

// The window as one line, for the console: "12-01..12-31 (every year, config)"
// or the same with full dates when the ini pinned a single year.
stock WfAtmosWindowText(output[], len)
{
	new source[12];
	if (g_wfaLoaded)
		copy(source, charsmax(source), "config");
	else
		copy(source, charsmax(source), "built-in");

	if (g_wfaStartYear == 0 && g_wfaEndYear == 0)
		formatex(output, len, "%02d-%02d..%02d-%02d (every year, %s)",
			g_wfaStartMD / 100, g_wfaStartMD % 100,
			g_wfaEndMD / 100, g_wfaEndMD % 100, source);
	else
		formatex(output, len, "%04d-%02d-%02d..%04d-%02d-%02d (%s)",
			g_wfaStartYear, g_wfaStartMD / 100, g_wfaStartMD % 100,
			g_wfaEndYear, g_wfaEndMD / 100, g_wfaEndMD % 100, source);
}

// Is today inside the window? A window whose start is later in the year than
// its end wraps the new year, which is the shape Halloween and the 12 Days of
// Christmas both need.
stock bool:WfAtmosOpenNow()
{
	new y, m, d;
	WfAtmosToday(y, m, d);

	new md = m * 100 + d;

	if (g_wfaStartYear && y < g_wfaStartYear)
		return false;
	if (g_wfaEndYear && y > g_wfaEndYear)
		return false;

	if (g_wfaStartMD <= g_wfaEndMD)
		return (md >= g_wfaStartMD && md <= g_wfaEndMD);

	return (md >= g_wfaStartMD || md <= g_wfaEndMD);
}

// ---------------------------------------------------------------------------
// Text
// ---------------------------------------------------------------------------
// One chat line, the same shape the rest of Winterfest uses. The format string
// is a literal here and the text is a %s argument, so a player name containing
// '%' can never become a format string (tools/lint-plugins.py rule 4).
stock WfAtmosSay(id, const text[])
{
	client_print_color(id, print_team_default, "^4[WF]^1 %s", text);
}

// Field `index` (0-based) of a "a | b | c" ini row. Returns false when the row
// has fewer fields. The result is trimmed; a missing field yields "".
stock bool:WfAtmosField(const line[], index, output[], len)
{
	new n = strlen(line);
	new start = 0, cur = 0;
	output[0] = 0;

	for (new i = 0; i <= n; i++)
	{
		if (i < n && line[i] != '|')
			continue;
		if (cur == index)
		{
			new count = i - start;
			if (count < 0)
				count = 0;
			if (count > len - 1)
				count = len - 1;
			for (new k = 0; k < count; k++)
				output[k] = line[start + k];
			output[count] = 0;
			trim(output);
			return true;
		}
		cur++;
		start = i + 1;
	}
	return false;
}

// Replace `token` ("{player}") with `value` in `src`. This is a literal token
// substitution, NOT a printf pass, on purpose: an ini line is data written by
// an operator, and treating it as a format string would let a stray '%' in it
// read varargs (the bug tools/lint-plugins.py rule 4 exists for). A value that
// itself contains a token is never re-scanned.
stock WfAtmosToken(const src[], const token[], const value[], output[], len)
{
	new slen = strlen(src);
	new tlen = strlen(token);
	new vlen = strlen(value);
	new out = 0;

	output[0] = 0;
	if (tlen <= 0)
	{
		copy(output, len, src);
		return;
	}

	new i = 0;
	while (i < slen && out < len - 1)
	{
		new matched = 0;
		if (i + tlen <= slen)
		{
			matched = 1;
			for (new k = 0; k < tlen; k++)
			{
				if (src[i + k] != token[k])
				{
					matched = 0;
					break;
				}
			}
		}

		if (matched)
		{
			for (new k = 0; k < vlen && out < len - 1; k++)
			{
				output[out] = value[k];
				out++;
			}
			i += tlen;
			continue;
		}

		output[out] = src[i];
		out++;
		i++;
	}

	output[out] = 0;
}
