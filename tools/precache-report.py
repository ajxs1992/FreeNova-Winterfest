#!/usr/bin/env python3
"""precache-report — who spends the 512-item precache budget, and how much.

GoldSrc gives a map load one global precache table and kills the server when it
overflows:

    Host_Error: ED_ParseEdict: Model '*239' failed to precache because the
    item count is over the 512 limit

That is what took this server down six times on `cs_havana`. The engine never
prints the count it is spending, so this tool derives it from the two places the
items come from:

  * the MAP, from its .bsp: every entry in the model lump is a precached model
    (that is where `*239` comes from — brush models), plus the model / sound /
    message keys named by entities;
  * the PLUGINS, from their .sma: every `precache_model` / `precache_generic` /
    `precache_sound` call site, resolved to the number of items it actually
    emits — a literal is 1, a loop over a declared array is the array's length, a
    loop over a config file is that file's live rows, a cvar-held path is 1.
    Anything it cannot resolve is reported as such instead of being dropped.

Duplicates are free: the engine hands back the index of an already-precached
string, so every total here is over DISTINCT resource names, which is what the
512 counter actually counts.

usage:
    tools/precache-report.py                      # loaded plugin stack + summary
    tools/precache-report.py --maps              # also rank every map in cstrike/
    tools/precache-report.py --map cs_havana     # one map in detail
    tools/precache-report.py --map-dir DIR       # look for .bsp files here
    tools/precache-report.py --all-plugins       # ignore plugins.ini, scan every .sma
    tools/precache-report.py --json              # machine-readable
    tools/precache-report.py --limit 20          # rows per table (default 15)

Exit: 0 always (it is a report), 2 on a usage error.
"""

from __future__ import annotations

import argparse
import shlex
import json
import os
import re
import struct
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
AMXX = os.path.join(ROOT, "game-server", "cstrike", "addons", "amxmodx")
SCRIPTING = os.path.join(AMXX, "scripting")
CONFIGS = os.path.join(AMXX, "configs")
MAPS = os.path.join(ROOT, "game-server", "cstrike", "maps")

# The hard ceiling. GoldSrc's precache table is indexed with a byte and the
# engine refuses the 513th item; REVIEW §9e has the crash it produced.
LIMIT = 512

CALL_RE = re.compile(r"\b(precache_model|precache_generic|precache_sound)\s*\(")
LITERAL_RE = re.compile(r'^\s*"([^"]*)"')
# ARRAY[i], ARRAY[group][i], g_Arr[0], CONSTANT
INDEX_RE = re.compile(r"^\s*([A-Za-z_]\w*)\s*\[")
DECL_RE = re.compile(r"\bnew\s+(?:const\s+)?([A-Za-z_]\w*)\s*((?:\[[^\]]*\])+)")
DEFINE_RE = re.compile(r"^[ \t]*#define[ \t]+([A-Za-z_]\w*)[ \t]+(\d+)[ \t]*$", re.M)
STRING_CONST_RE = re.compile(r'\bnew\s+const\s+([A-Za-z_]\w*)\s*\[\s*\]\s*=\s*"([^"]*)"')
STRING_ROWS_RE = re.compile(r'"([^"]*)"')
CONFIG_PATH_RE = re.compile(r'"([\w./-]+\.(?:ini|cfg|txt|json))"')

# Keys an entity can use to name a precached resource.
ENTITY_KEYS = ("model", "message", "sound", "noise", "mdl", "sprite")

BSP_LUMPS = 15
BSP_MODEL_SIZE = 64          # dmodel_t: 9 floats + 4 ints

# A call site whose count cannot be read out of the source alone: the plugin
# precaches the rows of a config file it is about to hand to players. The file,
# and which of its columns are model paths, is the whole relationship - keep it
# here rather than teaching the scanner to guess at PAWN control flow.
#
#   plugin: [(config path, [1-based column indexes that hold a resource path]),
#            (path, "col", ...)]
KNOWN_DRIVERS = {
    "weapon_models": [
        # configs/skins_menu.cfg rows:  <weapon> <name> <v_model> <p_model> ...
        ("skins_menu.cfg", [3, 4]),
        # configs/freenova/player_models.ini:  <target> <model> <team>
        ("freenova/player_models.ini", [2]),
    ],
}



# --------------------------------------------------------------------------- #
# map side
# --------------------------------------------------------------------------- #
def read_bsp(path: str) -> dict:
    """Return {'models': n, 'resources': set(), 'entities': n} for one .bsp."""
    with open(path, "rb") as fh:
        blob = fh.read()
    if len(blob) < 4 + BSP_LUMPS * 8:
        raise ValueError("not a BSP")
    version = struct.unpack_from("<i", blob, 0)[0]
    if version != 30:
        raise ValueError(f"unsupported BSP version {version}")
    lumps = [struct.unpack_from("<ii", blob, 4 + 8 * i) for i in range(BSP_LUMPS)]
    ents_off, ents_len = lumps[0]
    models_off, models_len = lumps[14]
    ent_text = blob[ents_off:ents_off + ents_len].decode("latin-1", "replace")

    res: set[str] = set()
    n_ent = 0
    for block in re.finditer(r"\{([^}]*)\}", ent_text):
        n_ent += 1
        for line in block.group(1).splitlines():
            m = re.match(r'\s*"([^"]+)"\s*"([^"]*)"', line)
            if not m:
                continue
            key, val = m.group(1).lower(), m.group(2).strip()
            if key in ENTITY_KEYS and val and not val.startswith("*"):
                res.add(val.lower())
    return {
        "models": models_len // BSP_MODEL_SIZE,
        "resources": res,
        "entities": n_ent,
        "version": version,
    }


# --------------------------------------------------------------------------- #
# plugin side
# --------------------------------------------------------------------------- #
def strip_comments(text: str) -> str:
    """Blank // and /* */ comments (keeps offsets stable enough for counting)."""
    text = re.sub(r"/\*.*?\*/", " ", text, flags=re.S)
    return re.sub(r"//[^\n]*", "", text)


def array_lengths(text: str) -> dict[str, list[int]]:
    """new [const] NAME[dim][dim2] -> the declared dims, numeric where knowable.

    `[GROUP_COUNT]` and friends are resolved through `#define`; a dim that stays
    unknown is recorded as 0 so the caller can say "unknown" instead of guessing.
    """
    defines = {m.group(1): int(m.group(2)) for m in DEFINE_RE.finditer(text)}
    out: dict[str, list[int]] = {}
    for m in DECL_RE.finditer(text):
        name, dims = m.group(1), m.group(2)
        vals = []
        for d in re.findall(r"\[([^\]]*)\]", dims):
            d = d.strip()
            if d.isdigit():
                vals.append(int(d))
            elif d in defines:
                vals.append(defines[d])
            else:
                vals.append(0)
        if not any(vals):
            # `[]` with a { ... } initialiser: count the rows.
            tail = text[m.end():m.end() + 20000]
            brace = tail.find("{")
            if brace >= 0:
                body = tail[brace:]
                m2 = re.search(r"\{(?:\s*\{[^{}]*\}\s*,?)+\s*\}", body)
                if m2:
                    vals = [len(re.findall(r"\{[^{}]*\}", m2.group(0)))]
        out[name] = vals
    return out


def string_constants(text: str) -> dict[str, str]:
    """#define NAME "..." and new const NAME[] = "..." -> the resource name."""
    out = {m.group(1): m.group(2) for m in STRING_CONST_RE.finditer(text)}
    for m in re.finditer(r'^[ \t]*#define[ \t]+([A-Za-z_]\w*)[ \t]+"([^"]*)"', text, re.M):
        out.setdefault(m.group(1), m.group(2))
    return out


def driver_items(plugin: str) -> tuple[set[str], int]:
    """Distinct resources behind the config-file precache loops of one plugin."""


    found: set[str] = set()
    rows = 0
    for rel, cols in KNOWN_DRIVERS.get(plugin, []):
        for base in (CONFIGS, os.path.join(CONFIGS, "freenova")):
            path = os.path.join(base, rel)
            if os.path.isfile(path):
                break
        else:
            continue
        with open(path, encoding="utf-8", errors="replace") as fh:
            for line in fh:
                line = line.strip()
                if not line or line[0] in ";#/" or line.startswith("//"):
                    continue
                rows += 1
                try:
                    fields = shlex.split(line)      # <weapon> "<name with spaces>" ...
                except ValueError:
                    continue
                for c in cols:
                    if len(fields) >= c and fields[c - 1] not in ("-", ""):
                        found.add(fields[c - 1].lower())
    return found, rows



def config_rows(rel: str) -> int | None:
    """Live (non-comment, non-empty) rows of a config file under configs/."""
    for base in (CONFIGS, SCRIPTING, os.path.join(ROOT, "game-server", "cstrike")):
        p = os.path.join(base, rel.lstrip("/"))
        if os.path.isfile(p):
            with open(p, encoding="utf-8", errors="replace") as fh:
                return sum(1 for l in fh
                           if l.strip() and not l.lstrip().startswith((";", "//", "#")))
    return None


def scan_plugin(name: str) -> dict:
    path = os.path.join(SCRIPTING, name + ".sma")
    text = strip_comments(open(path, encoding="utf-8", errors="replace").read())
    dims = array_lengths(text)
    consts = string_constants(text)

    items: set[str] = set()
    unresolved: list[str] = []
    by_kind: dict[str, int] = {}
    worst_case = 0
    sites = 0

    for m in CALL_RE.finditer(text):
        kind = m.group(1)
        # argument text up to the matching close paren
        depth, i = 0, m.end() - 1
        while i < len(text):
            if text[i] == "(":
                depth += 1
            elif text[i] == ")":
                depth -= 1
                if depth == 0:
                    break
            i += 1
        arg = text[m.end():i]
        sites += 1

        lit = LITERAL_RE.match(arg)
        if lit:
            items.add(lit.group(1).lower())
            worst_case += 1
            by_kind[kind] = by_kind.get(kind, 0) + 1
            continue

        idx = INDEX_RE.match(arg)
        if idx and idx.group(1) in dims:
            arr = idx.group(1)
            n_index = len(re.findall(r"\[", arg))
            bound = dims[arr][:n_index]
            if bound and all(bound):
                n = 1
                for b in bound:
                    n *= b
                worst_case += n
                by_kind[kind] = by_kind.get(kind, 0) + n
                # Row identity is not knowable statically; the config driver
                # (if any) supplies the real strings.
                continue
            unresolved.append(f"{kind}({arg.strip()}) : {arr} bound unknown")
            continue

        ident = arg.strip()
        if ident in consts:
            items.add(consts[ident].lower())
            worst_case += 1
            by_kind[kind] = by_kind.get(kind, 0) + 1
            continue
        if re.fullmatch(r"(Cvar|get_pcvar_string|[A-Za-z_]\w*)\s*\(.*\)", ident) or \
           re.fullmatch(r"[A-Za-z_]\w*", ident):
            # A cvar-held or otherwise single-valued path: one item.
            items.add(f"{kind}:{ident}".lower())
            worst_case += 1
            by_kind[kind] = by_kind.get(kind, 0) + 1
            continue

        unresolved.append(f"{kind}({ident})")

    driven, driver_rows = driver_items(name)
    items |= driven

    # Config-driven loops: if the plugin reads an ini while precaching, count it.
    configs = {}
    for m in CONFIG_PATH_RE.finditer(text):
        rel = m.group(1)
        if not rel.lower().endswith((".ini", ".cfg")):
            continue
        rows = config_rows(rel)
        if rows is not None:
            configs[rel] = rows

    return {
        "plugin": name,
        "sites": sites,
        "items": len(items),
        "worst_case": worst_case,
        "driver_rows": driver_rows,
        "by_kind": by_kind,
        "unresolved": unresolved,
        "configs": configs,
    }


# --------------------------------------------------------------------------- #
# plugin list
# --------------------------------------------------------------------------- #
def loaded_plugins() -> list[str]:
    """plugin names from plugins.ini, in load order, comments stripped."""
    out = []
    p = os.path.join(CONFIGS, "plugins.ini")
    if not os.path.isfile(p):
        return out
    for line in open(p, encoding="utf-8", errors="replace"):
        line = line.split(";")[0].strip()
        if not line or line.startswith("//"):
            continue
        name = line.split()[0]
        if name.endswith(".amxx"):
            out.append(name[:-5].replace(".amxx", ""))
    return out


def all_plugins() -> list[str]:
    return sorted(f[:-4] for f in os.listdir(SCRIPTING) if f.endswith(".sma"))


# --------------------------------------------------------------------------- #
# main
# --------------------------------------------------------------------------- #
def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(add_help=True, description=__doc__.splitlines()[0])
    ap.add_argument("--map", action="append", default=[], help="one map in detail (repeatable)")
    ap.add_argument("--maps", action="store_true", help="rank every .bsp in cstrike/maps")
    ap.add_argument("--map-dir", default=MAPS, help="directory to look for .bsp files in")
    ap.add_argument("--all-plugins", action="store_true", help="scan every .sma, not just plugins.ini")
    ap.add_argument("--json", action="store_true", help="machine-readable output")
    ap.add_argument("--limit", type=int, default=15, help="rows per table (default 15)")
    args = ap.parse_args(argv)

    names = all_plugins() if args.all_plugins else loaded_plugins()
    if not names:
        print("no plugins found (is plugins.ini there?)", file=sys.stderr)
        return 2
    rows = [scan_plugin(n) for n in names if os.path.isfile(os.path.join(SCRIPTING, n + ".sma"))]
    rows.sort(key=lambda r: (-r["worst_case"], -r["items"], r["plugin"]))
    plugin_total = sum(r["items"] for r in rows)
    plugin_worst = sum(r["worst_case"] for r in rows)

    map_rows = []
    mapdir = args.map_dir
    if args.maps or args.map:
        if not os.path.isdir(mapdir):
            print(f"no map directory at {mapdir}", file=sys.stderr)
            return 2
        wanted = None
        if args.map:
            wanted = {m if m.endswith(".bsp") else m + ".bsp" for m in args.map}
        for f in sorted(os.listdir(mapdir)):
            if not f.endswith(".bsp") or (wanted and f not in wanted):
                continue
            try:
                info = read_bsp(os.path.join(mapdir, f))
            except (ValueError, struct.error) as exc:
                map_rows.append({"map": f[:-4], "error": str(exc)})
                continue
            map_rows.append({"map": f[:-4], "models": info["models"],
                             "resources": len(info["resources"]),
                             "entities": info["entities"],
                             "total": info["models"] + len(info["resources"])})
        if args.maps:
            map_rows.sort(key=lambda r: -r.get("total", 0))

    if args.json:
        json.dump({"limit": LIMIT, "plugins": rows, "plugin_total": plugin_total,
                   "plugin_worst_case": plugin_worst, "maps": map_rows}, sys.stdout, indent=1)
        print()
        return 0

    print(f"precache budget: {LIMIT} items per map load (GoldSrc hard limit)\n")
    print("PLUGINS — resources each one precaches")
    print(f"{'named':>6} {'bound':>6}  {'sites':>5}  plugin")
    for r in rows[:args.limit]:
        print(f"{r['items']:>6} {r['worst_case']:>6}  {r['sites']:>5}  {r['plugin']}")
    rest = rows[args.limit:]
    if rest:
        print(f"{sum(x['items'] for x in rest):>6} {sum(x['worst_case'] for x in rest):>6}  "
              f"{sum(x['sites'] for x in rest):>5}  ({len(rest)} more plugins)")
    print(f"{'-' * 6} {'-' * 6}  {'-' * 5}")
    print(f"{plugin_total:>6} {plugin_worst:>6}  {sum(r['sites'] for r in rows):>5}  "
          f"total, {len(rows)} plugins")
    print(f"\n  named = distinct resource names this tool could resolve (literals, "
          f"string constants,\n          cvar-held paths and the config rows listed below)")
    print(f"  bound = declared upper bound: arrays count at their full staged size, so a\n"
          f"          loop over a half-empty table is counted at its worst")

    unresolved = [(r["plugin"], u) for r in rows for u in r["unresolved"]]
    if unresolved:
        print(f"\nunresolved call sites ({len(unresolved)}) — counted as 0 above, "
              f"not silently dropped:")
        for plugin, u in unresolved[:args.limit]:
            print(f"        {plugin}: {u}")
        if len(unresolved) > args.limit:
            print(f"        … {len(unresolved) - args.limit} more (--json for all)")

    cfg = {k: v for r in rows for k, v in r["configs"].items()}
    if cfg:
        print("\nconfig files these plugins read (live rows; the ones a precache loop "
              "walks are\ncounted in `named` above, the rest are context for a future "
              "reader):")
        for k, v in sorted(cfg.items(), key=lambda kv: -kv[1]):
            print(f"{v:>6}  configs/{k}")

    if map_rows:
        print("\nMAPS — items the map itself brings (model lump + named resources)")
        print(f"{'total':>6}  {'models':>6}  {'res':>5}  {'ents':>5}  map")
        for r in map_rows[:args.limit]:
            if "error" in r:
                print(f"{'—':>6}  {'—':>6}  {'—':>5}  {'—':>5}  {r['map']}  ({r['error']})")
                continue
            print(f"{r['total']:>6}  {r['models']:>6}  {r['resources']:>5}  "
                  f"{r['entities']:>5}  {r['map']}")
        if len(map_rows) > args.limit:
            print(f"        … {len(map_rows) - args.limit} more")
        if args.map:
            print("\nbudget left for plugins on those maps:")
            for r in map_rows:
                if "error" in r:
                    continue
                left = LIMIT - r["total"]
                verdict = "OVER" if left - plugin_total < 0 else "ok"
                print(f"  {r['map']:<20} map {r['total']:>4} + plugins {plugin_total:>4} "
                      f"= {r['total'] + plugin_total:>4} / {LIMIT}  ({verdict})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
