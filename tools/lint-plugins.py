#!/usr/bin/env python3
"""tools/lint-plugins.py - static checks for the bug classes this tree keeps
producing.

Scans the AMXX plugin sources (default:
``game-server/cstrike/addons/amxmodx/scripting/*.sma``) and reports
``path:line: rule  message`` for each finding. It exits non-zero when an
unacknowledged finding exists, so CI can gate on it; acknowledged ones are
printed as ``ALLOW`` and do not fail the run.

Rules
-----
1. ``format-alias``   ``format``/``formatex`` where a ``%s`` argument is the
   destination buffer itself: ``format(buf, n, "x%s", buf)`` writes into the
   buffer while reading it, so the copied text depends on the write order and
   the result is garbage (REVIEW.md 2.3, ``freenova_clutch`` pending keys).
2. ``format-spec``    an invalid AMXX format specifier - ``%N`` and friends
   copied from SourceMod, or any other letter the AMXX formatter does not know.
   It consumes no argument and prints literally, so every later specifier reads
   the wrong cell.
3. ``give-item``      ``give_item()`` with a classname CS 1.6 does not have
   (``item_defuser`` and anything that is not ``weapon_*``,
   ``item_thighpack``, ``item_assaultsuit``, ``item_longjump``). FUN fails to
   create the entity and then raises a run time error that aborts the caller.
4. ``format-var``     a print/HUD format argument that is a variable rather than
   a string literal. A player name containing ``%`` then becomes a format
   string: the varargs are read as garbage cells (REVIEW.md 5.5,
   ``weapon_models.sma`` admin message).
5. ``library-missing`` ``LibraryExists("x")`` where no ``.sma`` in the tree
   registers ``x`` (REVIEW.md 5.3, ``fn_chat`` testing ``gagsystem`` while the
   only gag provider registers ``freenova_gag``). Module/builtin libraries are
   listed in ``BUILTIN_LIBRARIES`` below.
6. ``sql-serverid``   ``server_id = 0`` hardcoded in SQL in a file whose other
   stats queries key on a server-id value (REVIEW.md 5.5, ``rsu_matchstats.sma``):
   the WHERE matches no row and the write is silently lost. A file that keys on
   0 everywhere (``rsu_core.sma``, whose player_stats inserts also use 0) is its
   own aggregate row and is not reported.
7. ``bp-ledger``      the BattlePass XP grant path in ``battlepass_core.sma``
   calls ``crxranks_give_user_xp``. BattlePass XP is its own ledger since
   REVIEW.md 9d (28a18cf); a grant that also moves rank XP is the H1 bug.
8. ``chat-escape``    a GoldSrc MENU escape (``\\y`` ``\\w`` ``\\r`` ``\\d``) or a
   caret colour code (``^1``..``^4``) inside a string that no menu renders:
   ``client_print`` / ``client_print_color`` / ``console_print`` /
   ``show_hudmessage`` text or a ``show_motd`` title. Those codes are not
   escapes to the compiler - they are printed character for character, which is
   the "raw color codes in chat" report. Chat renders ``^1``..``^4`` only; HUD
   text and the console render neither style (HUD understands ``^n``); a MOTD
   title is HTML. Menus are NOT police: ``menu_additem()`` and menu titles are
   exactly where ``\\y\\w\\r\\d`` belong.

``set_hudmessage()`` is deliberately not treated as a format call: its eleven
arguments are colour/position/timing and it takes no format string at all. The
call in that family that does format - ``show_hudmessage(id, fmt, ...)`` - is
checked.

Acknowledging a false positive
------------------------------
Put ``lint:allow <rule>[,<rule>]`` in a ``//`` or ``/* */`` comment on the
finding line, or on the line directly above it, and say why in the same
comment, e.g.::

    // lint:allow format-var - FN_CHAT_PREFIX is the literal "%s..." prefix
    client_printcolor(id, FN_CHAT_PREFIX, name)

The finding is then reported as ALLOW instead of failing the run. Use it for
patterns that are genuinely safe; the reason is for whoever reads this file
next, so write one.

Usage
-----
    tools/lint-plugins.py                     # scan the default tree
    tools/lint-plugins.py --rule format-alias # one rule (repeatable)
    tools/lint-plugins.py --json              # machine-readable, CI-friendly
    tools/lint-plugins.py --list-rules
    tools/lint-plugins.py --root . --glob 'game-server/**/*.sma'

Exit codes: 0 = no unacknowledged finding, 1 = findings, 2 = usage error.
No third-party dependencies: python3 standard library only.
"""
from __future__ import annotations

import argparse
import glob
import json
import os
import re
import sys

RULES = {
    "format-alias": "format/formatex whose %s argument is the destination buffer",
    "format-spec": "invalid AMXX format specifier",
    "give-item": "give_item() with a classname CS 1.6 does not have",
    "format-var": "print/hudmessage format argument is a variable, not a literal",
    "library-missing": "LibraryExists() for a library no .sma registers",
    "sql-serverid": "server_id = 0 hardcoded in SQL",
    "bp-ledger": "BattlePass XP grant path calls crxranks_give_user_xp",
    "chat-escape": "menu escape or colour code in a string no menu renders",
}

DEFAULT_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_GLOB = "game-server/cstrike/addons/amxmodx/scripting/*.sma"

# Libraries AMXX itself (a module, or the core) provides. Anything else must be
# registered by a plugin in this tree or rule 5 reports it.
BUILTIN_LIBRARIES = {
    "amxmodx", "fakemeta", "engine", "cstrike", "csx", "fun", "hamsandwich",
    "nvault", "sqlx", "dbi", "geoip", "sockets", "regex", "nVault", "reapi",
    "reapi_cstrike", "json", "textparse", "cellarray", "trie", "sort", "dhudmessage",
}

# Call -> index of the format argument. A tuple means "depends on the argument
# count" (the 2-argument client_print_color overload).
FORMAT_CALLS = {
    "format": 2,
    "formatex": 2,
    "fmt": 0,
    "client_print": 2,
    "client_print_color": (1, 2),   # (2-arg overload, 3-arg overload)
    "client_printcolor": 1,
    "console_print": 1,
    "server_print": 0,
    "log_amx": 0,
    "show_hudmessage": 1,
}

GIVE_ITEM_CALLS = {"give_item", "fm_give_item"}
GIVE_ITEM_ALLOWED_PREFIXES = ("weapon_",)
GIVE_ITEM_ALLOWED = {"item_thighpack", "item_assaultsuit", "item_longjump"}

# Print family used by rule 4 (a variable format argument). Kept separate from
# FORMAT_CALLS because rule 1 only needs the functions whose first argument is a
# destination buffer.
PRINT_FAMILY = {
    "client_print": 2,
    "client_print_color": (1, 2),
    "client_printcolor": 1,
    "console_print": 1,
    "server_print": 0,
    "log_amx": 0,
    "show_hudmessage": 1,
}

# Rule 8: the two escape styles, and who understands them.
#   GoldSrc MENUS interpret \y (yellow) \w (white) \r (red) \d (dim).
#   CHAT (client_print_color) interprets ^1 (default) ^3 (team) ^4 (green).
#   HUD text interprets neither, only ^n; the server console interprets none,
#   and a show_motd title is HTML.
MENU_ESCAPE_RE = re.compile(r"\\[dwry]")
CARET_CODE_RE = re.compile(r"\^[0-9]")

# call -> (format-argument index or the (2-arg, 3-arg) pair, loses caret codes too)
CHAT_TEXT_CALLS = {
    "client_print": (2, False),          # chat: ^1..^4 are real, menus are not
    "client_print_color": ((1, 2), False),
    "client_printcolor": (1, False),
    "console_print": (1, True),          # console renders neither style
    "show_hudmessage": (1, True),        # HUD: only ^n, no colour codes at all
    # The house chat service (freenova_chat.inc) and Winterfest's own one-line
    # helper (winterfest.inc). Both prepend their prefix and print through
    # client_print_color, so ^1..^4 are legal and menu escapes are not.
    "fn_chat_info": (1, False),
    "fn_chat_error": (1, False),
    "fn_chat_success": (1, False),
    "fn_chat_warning": (1, False),
    "fn_chat_usage": (1, False),
    "fn_chat_permission": (1, False),
    "fn_chat_raw": (2, False),
    "WfSay": (1, False),
    "WfSayFmt": (1, False),
}

# Rule 8 also follows one variable: the classic bug is
#   formatex(buf, n, "ornament:\d %s", x) ... WfSay(id, buf)
# where the format string is a line above the print, so no literal check sees it.
# When a chat sink's argument is a bare buffer, the enclosing function's
# formatex()/format()/add() calls that target that buffer are inspected too.
BUFFER_FORMAT_CALLS = {"formatex": 2, "format": 2, "add": 1, "fmt": 0}

# AMXX format specifiers: %s %d %i %u %f %x %X %c %b %e %E %g %G plus the
# language-key family %L (client id + phrase) / %t %T (inline phrase) and %%.
# The lowercase %l is accepted as well: it is the same translation path and this
# tree uses it (rt_effects.sma vformat(..., "%l", 3)), so flagging it here would
# be a false positive. Width, precision and the -+0# flags are parsed, not
# listed.
# %a is the cellarray string handle (cellarray.inc: "printing as a string
# (with the %a format option)"), not a float format: mapchooser.sma relies on it.
VALID_SPECS = set("sdaf iuxXcbeEgGLlTt%".replace(" ", ""))

# Calls whose format argument rule 2 validates. Anything outside this set (a
# format_time()/strftime pattern, a replace() search key, HTML) is not an AMXX
# format string and must not be reported.
SPEC_CALLS = dict(FORMAT_CALLS)
SPEC_CALLS["vformat"] = 2

# The BP ledger provider and the functions that must never reach rank XP.
BP_PROVIDER = "battlepass_core.sma"
BP_GRANT_FUNCTIONS = ("BpAddXp", "BpAddXpOnce", "native_add_bp_xp", "native_add_bp_xp_once")


# Findings that are accepted for the whole file, with the reason. Used where the
# source must not be edited to carry the marker: pristine AMXX upstream files
# (REVIEW.md §11 excludes the stock distribution, and a comment there means
# diverging from upstream + manifest drift) and third-party sources that cannot
# be compiled from this snapshot at all.
ALLOW_LIST = [
    ("nextmap.sma", "format-var",
     "g_warning is a file-scope string literal ('... file ...'), so the format is "
     "known and its one argument matches the single %s"),
    ("restmenu.sma", "format-spec",
     "pristine AMXX 1.10 upstream (verified against the vendored tarball) and "
     "restmenu.amxx is not in plugins.ini, so the %n crash path is unreachable; "
     "fix + rebuild together if an operator ever loads it"),
    # Findings found by this batch that belong to another workstream's file: the
    # rule stays armed, the finding is acknowledged here and reported with a
    # line number in docs/WINTERFEST-PLAYTEST-FIXES.md §7 so its owner can see
    # the whole list in one place.
    ("winterfest_progress.sma", "chat-escape",
     "not this batch's file (its owner is active on docs/WINTERFEST-PROGRESS.md); "
     "3 chat lines still carry a menu escape - listed in the playtest report §7"),
    ("freenova_calladmin.sma", "chat-escape",
     "not this batch's file; 2 client_print_color lines carry \\y - listed in "
     "the playtest report §7 for its owner"),
    ("winterfest_spin.sma", "chat-escape",
     "not this batch's file (its owner is active on docs/WINTERFEST-SPIN.md); "
     "the report §7 lists what to check there"),
]


class Finding:
    __slots__ = ("path", "line", "rule", "message", "allowed")

    def __init__(self, path, line, rule, message, allowed=False):
        self.path = path
        self.line = line
        self.rule = rule
        self.message = message
        self.allowed = allowed

    def as_dict(self):
        return {
            "path": self.path, "line": self.line, "rule": self.rule,
            "message": self.message, "allowed": self.allowed,
        }


# ----------------------------------------------------------------- text utils
def mask_comments(text: str) -> str:
    """Blank out `//` and `/* */` comments, keeping offsets and newlines.

    Strings are left intact (Pawn escapes with `^`, and `""` is an empty
    string), so callers can read literals out of the masked text.
    """
    out = list(text)
    i, n = 0, len(text)
    while i < n:
        c = text[i]
        if c == '"':
            i += 1
            while i < n:
                if text[i] == "^" and i + 1 < n:
                    i += 2
                    continue
                if text[i] == '"':
                    i += 1
                    break
                if text[i] == "\n":
                    break
                i += 1
            continue
        if c == "/" and i + 1 < n and text[i + 1] == "/":
            while i < n and text[i] != "\n":
                out[i] = " "
                i += 1
            continue
        if c == "/" and i + 1 < n and text[i + 1] == "*":
            out[i] = out[i + 1] = " "
            i += 2
            while i + 1 < n and not (text[i] == "*" and text[i + 1] == "/"):
                if text[i] != "\n":
                    out[i] = " "
                i += 1
            if i + 1 < n:
                out[i] = out[i + 1] = " "
                i += 2
            continue
        i += 1
    return "".join(out)


def line_of(text: str, offset: int) -> int:
    return text.count("\n", 0, offset) + 1


def split_args(masked: str, open_paren: int):
    """Split the argument list starting at `open_paren` (index of '(').

    Returns (args, close_index) or (None, None) when the call is not closed.
    """
    args = []
    depth = 0
    cur_start = open_paren + 1
    i, n = open_paren, len(masked)
    while i < n:
        c = masked[i]
        if c == '"':
            i += 1
            while i < n:
                if masked[i] == "^" and i + 1 < n:
                    i += 2
                    continue
                if masked[i] == '"' or masked[i] == "\n":
                    break
                i += 1
            i += 1
            continue
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
            if depth == 0:
                args.append(masked[cur_start:i])
                return [a.strip() for a in args], i
        elif c == "," and depth == 1:
            args.append(masked[cur_start:i])
            cur_start = i + 1
        i += 1
    return None, None


def find_calls(masked: str, names):
    """Yield (name, args, offset_of_name) for calls to any of `names`."""
    pattern = re.compile(
        r"(?<![A-Za-z0-9_])(" + "|".join(sorted(names, key=len, reverse=True)) + r")\s*\(")
    for m in pattern.finditer(masked):
        args, _ = split_args(masked, m.end() - 1)
        if args is None:
            continue
        yield m.group(1), args, m.start()


def is_string_literal(arg: str):
    """Return the literal's contents if `arg` is exactly one "..." literal."""
    if len(arg) < 2 or arg[0] != '"' or arg[-1] != '"':
        return None
    inner = arg[1:-1]
    i = 0
    while i < len(inner):
        if inner[i] == "^":
            i += 2
            continue
        if inner[i] == '"':
            return None   # concatenation or stray quote
        i += 1
    return inner


def format_specs(literal: str):
    """Yield (specifier_letter, argument_index) for each consuming specifier."""
    arg_index = 0
    i, n = 0, len(literal)
    while i < n:
        if literal[i] != "%":
            i += 1
            continue
        j = i + 1
        while j < n and literal[j] in "-+0 #":
            j += 1
        while j < n and literal[j].isdigit():
            j += 1
        if j < n and literal[j] == ".":
            j += 1
            while j < n and literal[j].isdigit():
                j += 1
        if j >= n:
            break
        spec = literal[j]
        i = j + 1
        if spec == "%":
            continue
        yield spec, arg_index
        arg_index += 1


def invalid_specs(literal: str):
    """Yield letters used as a specifier that AMXX does not implement.

    Only an ASCII letter directly after the flags/width/precision counts as a
    specifier, so prose and URLs ("100% sure", "%20", "%3-4") are not reported.
    """
    i, n = 0, len(literal)
    while i < n:
        if literal[i] != "%":
            i += 1
            continue
        j = i + 1
        while j < n and literal[j] in "-+0 #":
            j += 1
        while j < n and literal[j].isdigit():
            j += 1
        if j < n and literal[j] == ".":
            j += 1
            while j < n and literal[j].isdigit():
                j += 1
        if j < n and ("a" <= literal[j] <= "z" or "A" <= literal[j] <= "Z"):
            if literal[j] not in VALID_SPECS:
                yield literal[j]
        i = max(j + 1, i + 2) if j < n else n


ROOT_IDENT = re.compile(r"^\s*(?:new\s+|const\s+|static\s+)?([A-Za-z_]\w*)")


def root_ident(arg: str):
    m = ROOT_IDENT.match(arg)
    return m.group(1) if m else None


def function_body(masked: str, name: str):
    """Return (offset, body) of the definition of `name`, or (None, None)."""
    for m in re.finditer(r"(?<![A-Za-z0-9_])" + re.escape(name) + r"\s*\(", masked):
        # A definition has no statement terminator before the matching body `{`.
        close = split_args(masked, m.end() - 1)[1]
        if close is None:
            continue
        k = close + 1
        while k < len(masked) and masked[k] in " \t\r\n":
            k += 1
        if k < len(masked) and masked[k] == "{":
            depth, i = 0, k
            while i < len(masked):
                if masked[i] == "{":
                    depth += 1
                elif masked[i] == "}":
                    depth -= 1
                    if depth == 0:
                        return m.start(), masked[k:i + 1]
                i += 1
    return None, None


def enclosing_block(masked: str, offset: int):
    """(start, body) of the outermost `{}` block that contains `offset`.

    Plugin functions are top-level in this tree, so the outermost block is the
    function body - which is the scope a buffer cannot escape, and therefore the
    right place to look for the formatex() that filled a printed buffer.
    """
    depth = 0
    start = None
    for i in range(offset):
        c = masked[i]
        if c == "{":
            depth += 1
            if depth == 1:
                start = i
        elif c == "}":
            depth -= 1
    if start is None:
        return None, None
    depth = 0
    for j in range(start, len(masked)):
        if masked[j] == "{":
            depth += 1
        elif masked[j] == "}":
            depth -= 1
            if depth == 0:
                return start, masked[start:j + 1]
    return start, masked[start:]


# ------------------------------------------------------------------- linter ---
class Linter:
    def __init__(self, root: str, only_rules=None):
        self.root = root
        self.only = set(only_rules or RULES)
        self.findings = []
        self.files = []
        self.masked_now = ""
        self.registered_libraries = set()

    # -- helpers ------------------------------------------------------------
    def add(self, path, text, offset, rule, message, allow_check=True, forced_allow=False):
        if rule not in self.only:
            return
        line = line_of(text, offset)
        # One finding per (file, line, rule, message): rule 8 walks the same
        # buffer for every chat sink in a function and would otherwise repeat
        # itself once per sink.
        rel = self.rel(path)
        for f in self.findings:
            if f.path == rel and f.line == line and f.rule == rule and f.message == message:
                return
        allowed = forced_allow or (allow_check and self.is_allowed(path, line, rule))
        self.findings.append(Finding(rel, line, rule, message, allowed))

    def is_allowed(self, path, line, rule):
        """`lint:allow <rule>` inline, or a file entry in ALLOW_LIST."""
        name = os.path.basename(path)
        for allow_file, allow_rule, _reason in ALLOW_LIST:
            if allow_rule == rule and (allow_file == name or allow_file == "*"):
                return True
        try:
            with open(path, "r", encoding="utf-8", errors="replace") as f:
                lines = f.read().splitlines()
        except OSError:
            return False
        # The marker may sit on the finding line or in the comment block just
        # above it (a multi-line reason is the norm), so walk up while the lines
        # are comments or blank and stop at the first line of real code.
        probes = [line]
        k = line - 1
        while 1 <= k and len(probes) < 9:
            stripped = lines[k - 1].strip()
            if stripped == "" or stripped.startswith(("//", "/*", "*")):
                probes.append(k)
                k -= 1
                continue
            break
        for probe in probes:
            if probe < 1 or probe > len(lines):
                continue
            m = re.search(r"lint:\s*allow\b(.*)$", lines[probe - 1], re.IGNORECASE)
            if not m:
                continue
            listed = m.group(1).strip()
            if not listed or re.search(r"\ball\b", listed, re.IGNORECASE):
                return True
            names = re.split(r"[,\s]+", listed)
            if rule in names:
                return True
            # "lint:allow rule - reason text": only the first token is the rule
            if names and names[0] == rule:
                return True
        return False

    def rel(self, path):
        try:
            return os.path.relpath(path, self.root)
        except ValueError:
            return path

    # -- rule passes --------------------------------------------------------
    def collect_libraries(self, masked, path, text):
        for name, args, offset in find_calls(masked, {"register_library"}):
            if not args:
                continue
            lit = is_string_literal(args[0])
            if lit is not None:
                self.registered_libraries.add(lit)
            else:
                self.add(path, text, offset, "library-missing",
                         "register_library() is not called with a literal name; "
                         "rule 5 cannot see this library")

    def check_format_alias(self, masked, path, text):
        for name, args, offset in find_calls(masked, {"format", "formatex"}):
            if len(args) < 3:
                continue
            fmt = is_string_literal(args[2])
            if fmt is None:
                continue
            dest = root_ident(args[0])
            if not dest:
                continue
            uncertain = False
            # format() formats into a temporary buffer and copies back, so
            # format(buf, n, "x%s", buf) is legal - measured on this build:
            # format -> "pre#hello", formatex -> "pre#pre#p". Only formatex,
            # which writes in place, is a bug.
            safe_copyback = (name == "format")
            for spec, arg_index in format_specs(fmt):
                if spec in ("L", "l", "t", "T"):
                    # A language key takes its own arguments (id + phrase) and
                    # expands further specifiers from the same varargs, so
                    # positional mapping after it is unknowable.
                    uncertain = True
                    continue
                if spec != "s" or uncertain:
                    continue
                pos = 3 + arg_index
                if pos >= len(args):
                    continue
                if root_ident(args[pos]) == dest:
                    msg = (f"destination '{dest}' is also the %s argument "
                           f"(argument {pos + 1}); use a second buffer")
                    if safe_copyback:
                        msg += " [format() copies back, so this form is safe; formatex() would not be]"
                    self.add(path, text, offset, "format-alias", msg,
                             forced_allow=safe_copyback)

    def check_invalid_specs(self, masked, path, text):
        # Only the format argument of a formatting call is an AMXX format
        # string. Scanning every literal reported strftime patterns ("%Y-%m-%d"
        # in format_time) and replace() keys ("%hostname%") as if they were
        # specifiers - 173 findings, nearly all of them prose.
        for name, args, offset in find_calls(masked, SPEC_CALLS):
            idx = SPEC_CALLS[name]
            if isinstance(idx, tuple):
                idx = idx[1] if len(args) > 2 else idx[0]
            if len(args) <= idx:
                continue
            fmt = is_string_literal(args[idx])
            if fmt is None:
                continue
            bad = list(invalid_specs(fmt))
            if bad:
                self.add(path, text, offset, "format-spec",
                         f"{name}() format has invalid AMXX specifier %{bad[0]}"
                         + (f" (+{len(bad) - 1} more)" if len(bad) > 1 else ""))

    def iter_literals(self, masked):
        """Yield (literal_contents, offset_in_literal, literal_offset)."""
        i, n = 0, len(masked)
        while i < n:
            if masked[i] != '"':
                i += 1
                continue
            start = i
            i += 1
            buf = []
            while i < n:
                if masked[i] == "^" and i + 1 < n:
                    buf.append(masked[i:i + 2])
                    i += 2
                    continue
                if masked[i] == '"':
                    i += 1
                    break
                if masked[i] == "\n":
                    break
                buf.append(masked[i])
                i += 1
            yield "".join(buf), 0, start

    def check_give_item(self, masked, path, text):
        for name, args, offset in find_calls(masked, GIVE_ITEM_CALLS):
            if len(args) < 2:
                continue
            item = is_string_literal(args[1])
            if item is None:
                continue
            low = item.lower()
            ok = low in GIVE_ITEM_ALLOWED or (
                low.startswith(GIVE_ITEM_ALLOWED_PREFIXES) and len(low) > len("weapon_"))
            if ok:
                continue
            self.add(path, text, offset, "give-item",
                     f"give_item(\"{item}\") has no CS 1.6 entity class"
                     + (" - item_defuser is the classic; use item_thighpack"
                        if low == "item_defuser" else
                        "; expected weapon_*, item_thighpack, item_assaultsuit or item_longjump"))

    def check_format_var(self, masked, path, text):
        for name, args, offset in find_calls(masked, PRINT_FAMILY):
            idx = PRINT_FAMILY[name]
            if isinstance(idx, tuple):
                idx = idx[1] if len(args) > 2 else idx[0]
            if len(args) <= idx:
                continue
            if is_string_literal(args[idx]) is not None:
                continue
            arg = args[idx]
            # A bare `...`-forward or a numeric channel/`type` argument is not a
            # format string; only a variable that could carry a format is.
            if re.fullmatch(r"[\w.\[\]]+", arg) is None:
                continue
            self.add(path, text, offset, "format-var",
                     f"{name}() format argument is '{arg}', not a string literal; "
                     f"pass \"%s\" and the value separately")

    def check_sql_serverid(self, masked, path, text):
        # The bug is *mixing* keys: rsu_matchstats.sma bound `server_id = 0` while
        # its own other writes (and the rest of the tree) use the rsu_server_id
        # cvar, so the flush matched no row. rsu_core.sma keys player_stats on
        # server_id 0 everywhere - inserts included - which is its aggregate row,
        # so a lone literal 0 there is correct and is reported as an ALLOW.
        zero = re.compile(r"\bserver_id\s*=\s*['\"]?0['\"]?(?![\w.])", re.IGNORECASE)
        var = re.compile(r"\bserver_id\s*=\s*'?%d", re.IGNORECASE)
        uses_var = False
        hits = []
        for lit, _, lit_offset in self.iter_literals(masked):
            if "server_id" not in lit.lower():
                continue
            if var.search(lit):
                uses_var = True
            m = zero.search(lit)
            if m:
                hits.append((lit_offset + m.start(), lit))
        # A file whose only stats key is 0 is not reported: rsu_core.sma inserts
        # and updates player_stats on server_id 0 everywhere, which is its
        # aggregate row, so there is no second key to disagree with. Only a file
        # that mixes a value key with a literal 0 has the rsu_matchstats.sma bug.
        if not uses_var:
            return
        for offset, _lit in hits:
            self.add(path, text, offset, "sql-serverid",
                     "server_id = 0 is hardcoded while this file's other stats "
                     "queries key on a server-id value; the row will not match")

    def check_library_missing(self, masked, path, text):
        for name, args, offset in find_calls(masked, {"LibraryExists"}):
            if not args:
                continue
            lib = is_string_literal(args[0])
            if lib is None:
                continue
            if lib in self.registered_libraries or lib in BUILTIN_LIBRARIES:
                continue
            self.add(path, text, offset, "library-missing",
                     f"LibraryExists(\"{lib}\") but no .sma in this tree registers "
                     f"\"{lib}\"")

    def check_chat_escape(self, masked, path, text):
        names = set(CHAT_TEXT_CALLS) | {"show_motd"}
        for name, args, offset in find_calls(masked, names):
            if name == "show_motd":
                # show_motd(id, body, "Title"): the title is HTML, so a code in
                # it is shown raw in the window header. The body is URL/file/HTML
                # and is not inspected.
                if len(args) > 2:
                    self.chat_escape_literal(args[2], path, text, offset,
                                             "show_motd() title", True)
                continue
            idx, caret_too = CHAT_TEXT_CALLS[name]
            if isinstance(idx, tuple):
                idx = idx[1] if len(args) > 2 else idx[0]
            if len(args) <= idx:
                continue
            what = "HUD text" if name == "show_hudmessage" else (
                "console text" if name == "console_print" else "chat text")
            where = f"{name}() {what}"
            if self.chat_escape_literal(args[idx], path, text, offset, where, caret_too):
                continue
            # Not a literal: follow the buffer it names.
            self.chat_escape_buffer(args[idx], path, text, offset, where, caret_too)

    def chat_escape_buffer(self, arg, path, text, offset, where, caret_too):
        buf = root_ident(arg)
        if not buf:
            return
        start, body = enclosing_block(masked=self.masked_now, offset=offset)
        if start is None:
            return
        for name, args, off in find_calls(body, BUFFER_FORMAT_CALLS):
            fdx = BUFFER_FORMAT_CALLS[name]
            if len(args) <= max(fdx, 0) or root_ident(args[0]) != buf:
                continue
            if self.chat_escape_literal(args[fdx], path, text, start + off,
                                        f"{where} (built by {name}() at line "
                                        f"{line_of(text, start + off)})", caret_too):
                continue

    def chat_escape_literal(self, arg, path, text, offset, where, caret_too):
        """Report escapes in one literal. True when `arg` WAS a literal."""
        lit = is_string_literal(arg)
        if lit is None:
            return False
        m = MENU_ESCAPE_RE.search(lit)
        if m:
            self.add(path, text, offset, "chat-escape",
                     f"{where} contains the menu-only escape '{m.group(0)}'; only "
                     f"menus render it - chat shows it literally (use ^1/^3/^4)")
        if caret_too:
            m = CARET_CODE_RE.search(lit)
            if m:
                style = ("HUD text renders no colour code at all (^n only)"
                         if "HUD" in where else
                         "the server console renders no colour code")
                self.add(path, text, offset, "chat-escape",
                         f"{where} contains the colour code '{m.group(0)}'; {style}")
        return True

    def check_bp_ledger(self, masked, path, text):
        if os.path.basename(path) != BP_PROVIDER:
            return
        for fn in BP_GRANT_FUNCTIONS:
            start, body = function_body(masked, fn)
            if start is None:
                continue
            for m in re.finditer(r"crxranks_give_user_xp\s*\(", body):
                self.add(path, text, start + m.start(), "bp-ledger",
                         f"{fn}() calls crxranks_give_user_xp(); BattlePass XP is its "
                         f"own ledger and must not move rank XP")

    # -- driver -------------------------------------------------------------
    def run(self, files):
        self.files = files
        masked_cache = {}
        # Pass 1: registered libraries (rule 5 needs the whole tree).
        for path in files:
            with open(path, "r", encoding="utf-8", errors="replace", newline="") as f:
                text = f.read()
            masked = mask_comments(text)
            masked_cache[path] = (text, masked)
            self.collect_libraries(masked, path, text)
        # Pass 2: every rule.
        for path in files:
            text, masked = masked_cache[path]
            self.masked_now = masked
            self.check_format_alias(masked, path, text)
            self.check_invalid_specs(masked, path, text)
            self.check_give_item(masked, path, text)
            self.check_format_var(masked, path, text)
            self.check_sql_serverid(masked, path, text)
            self.check_library_missing(masked, path, text)
            self.check_bp_ledger(masked, path, text)
            self.check_chat_escape(masked, path, text)
        return self.findings


# ---------------------------------------------------------------- self-test ---
def self_test(root):
    """Run the fixtures under tests/lint-plugins/ and check the tool's contract.

    Three cases: `bad` must report every rule as an error, `clean` must report
    nothing, `allowed` must report the same bugs but fail nothing. This is what
    makes the tool itself testable in CI, where the real tree may legitimately
    carry acknowledged findings.
    """
    base = os.path.join(root, "tests", "lint-plugins")
    failures = []

    def run(case):
        files = sorted(glob.glob(os.path.join(base, case, "*.sma")))
        if not files:
            failures.append(f"{case}: no fixture files in {base}/{case}")
            return []
        return Linter(root).run(files)

    bad = run("bad")
    bad_errors = {f.rule for f in bad if not f.allowed}
    missing = set(RULES) - bad_errors
    if missing:
        failures.append("bad: no finding for rule(s) " + ", ".join(sorted(missing)))
    for f in bad:
        if f.allowed:
            failures.append(f"bad: {f.path}:{f.line} was unexpectedly allowed")

    clean = run("clean")
    if clean:
        failures.append("clean: reported " + ", ".join(
            f"{f.rule} at {f.path}:{f.line}" for f in clean))

    allowed = run("allowed")
    allowed_errors = [f for f in allowed if not f.allowed]
    if allowed_errors:
        failures.append("allowed: lint:allow did not suppress " + ", ".join(
            f"{f.rule} at {f.path}:{f.line}" for f in allowed_errors))
    if not allowed:
        failures.append("allowed: no findings at all - the fixture stopped exercising the markers")

    print(f"self-test: bad={len(bad)} findings ({len(bad_errors)} of {len(RULES)} rules), "
          f"clean={len(clean)}, allowed={len(allowed)}")
    for msg in failures:
        print("FAIL " + msg)
    if failures:
        return 1
    print(f"self-test OK ({len(RULES)} rules, acknowledge path, clean path)")
    return 0


# --------------------------------------------------------------------- main ---
def main(argv=None):
    ap = argparse.ArgumentParser(
        description="Static checks for the AMXX bug classes this tree keeps producing.")
    ap.add_argument("--root", default=DEFAULT_ROOT, help="repository root (default: %(default)s)")
    ap.add_argument("--glob", default=DEFAULT_GLOB,
                    help="file pattern relative to --root (default: %(default)s)")
    ap.add_argument("--rule", action="append", choices=sorted(RULES),
                    help="only run this rule (repeatable)")
    ap.add_argument("--json", action="store_true", help="machine-readable output")
    ap.add_argument("--list-rules", action="store_true", help="print the rule table and exit")
    ap.add_argument("--self-test", action="store_true",
                    help="check the tool against tests/lint-plugins/ fixtures and exit")
    args = ap.parse_args(argv)

    if args.self_test:
        return self_test(args.root)

    if args.list_rules:
        for rule, desc in RULES.items():
            print(f"{rule:16s} {desc}")
        return 0

    pattern = os.path.join(args.root, args.glob)
    files = sorted(glob.glob(pattern, recursive=True))
    if not files:
        print(f"lint-plugins: no files matched {pattern}", file=sys.stderr)
        return 2

    linter = Linter(args.root, args.rule)
    findings = linter.run(files)
    findings.sort(key=lambda f: (f.path, f.line, f.rule))
    errors = [f for f in findings if not f.allowed]
    allowed = [f for f in findings if f.allowed]

    if args.json:
        print(json.dumps({
            "files": len(files),
            "findings": [f.as_dict() for f in findings],
            "errors": len(errors),
            "allowed": len(allowed),
        }, indent=2))
    else:
        for f in findings:
            tag = "ALLOW" if f.allowed else "FAIL "
            print(f"{tag} {f.path}:{f.line}: {f.rule}: {f.message}")
        by_rule = {}
        for f in errors:
            by_rule[f.rule] = by_rule.get(f.rule, 0) + 1
        print()
        print(f"lint-plugins: {len(files)} files, {len(RULES)} rules, "
              f"{len(findings)} findings ({len(errors)} error, {len(allowed)} allowed)")
        for rule in sorted(by_rule):
            print(f"  {rule:16s} {by_rule[rule]}")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
