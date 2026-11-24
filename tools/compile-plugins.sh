#!/usr/bin/env bash
# Compile every AMX Mod X plugin in the snapshot and report per-plugin PASS/FAIL.
#
# Run from anywhere:  tools/compile-plugins.sh
#                     tools/compile-plugins.sh --only freenova_clutch [--only ...]
# Output:             tools/build/plugins/<name>.amxx   (gitignored)
#                     tools/build/plugins/logs/<name>.sma.log
# Exit:               0 only if every compiled .sma built (or is allowlisted).
#
# --only NAME     compile just NAME.sma (repeatable); the default is every .sma
#                 in the tree, unchanged. Used to build one plugin alone for a
#                 deploy record: same runner, same output layout, same report.
#
# The bundled compiler (game-server/.../scripting/amxxpc) is a 32-bit i386 ELF and
# needs an i386 runtime. Two runners are supported, tried in this order:
#
#   1. native    - amxxpc runs directly (x86 Linux with i386 libs, e.g. a CI
#                  runner after `dpkg --add-architecture i386`).
#   2. docker    - a 32-bit container. This is what works on the snapshot host,
#                  where the harness' seccomp filter kills every i386 process
#                  with SIGSYS (exit 159) regardless of installed libraries:
#                    docker pull i386/debian:bookworm-slim
#                  Override with AMXX_IMAGE=<image>.
#
# Sources are copied to a scratch directory first: amxxpc writes <name>.amxx next
# to the source by default, and the live scripting/ tree must stay untouched.

set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
AMXX="$ROOT/game-server/cstrike/addons/amxmodx"
SRC="$AMXX/scripting"
OUT=${OUT:-$ROOT/tools/build/plugins}
IMAGE=${AMXX_IMAGE:-i386/debian:bookworm-slim}
LOGS="$OUT/logs"

# ---- arguments -------------------------------------------------------------
ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --only|--only=*)
      if [ "$1" = "--only" ]; then
        [ $# -ge 2 ] || { echo "FATAL: --only needs a source name" >&2; exit 2; }
        shift
        name=$1
      else
        name=${1#--only=}
      fi
      name=$(basename "$name")
      name=${name%.sma}
      ONLY="${ONLY:+$ONLY }$name.sma"
      ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "FATAL: unknown argument: $1 (try --help)" >&2; exit 2 ;;
  esac
  shift
done

if [ ! -x "$SRC/amxxpc" ]; then
  echo "FATAL: compiler not found or not executable: $SRC/amxxpc" >&2
  exit 2
fi
if [ ! -d "$SRC/include" ]; then
  echo "FATAL: include directory missing: $SRC/include" >&2
  exit 2
fi

for name in $ONLY; do
  if [ ! -f "$SRC/$name" ]; then
    echo "FATAL: no such source: $SRC/$name" >&2
    exit 2
  fi
done

rm -rf "$OUT"
mkdir -p "$OUT" "$LOGS"

# The runner loop reads its work list from .subset; absent, it globs *.sma.
if [ -n "$ONLY" ]; then
  printf '%s\n' $ONLY > "$OUT/.subset"
fi

# ---- pick a runner ---------------------------------------------------------
MODE=none
if "$SRC/amxxpc" -? >/dev/null 2>&1; then
  MODE=native
elif command -v docker >/dev/null 2>&1 && docker image inspect "$IMAGE" >/dev/null 2>&1; then
  MODE=docker
fi

case "$MODE" in
  native) echo "runner: native ($("$SRC/amxxpc" -? 2>&1 | head -1))" ;;
  docker) echo "runner: docker image $IMAGE" ;;
  *)
    echo "FATAL: amxxpc cannot run here and no usable container image is available." >&2
    echo "  native: the binary is a 32-bit i386 ELF - install i386 libs, or run on an" >&2
    echo "          x86_64 host whose seccomp policy allows i386 syscalls." >&2
    echo "  docker: docker pull $IMAGE   (or set AMXX_IMAGE=<image>)" >&2
    exit 3
    ;;
esac

# ---- known-missing includes ------------------------------------------------
# amxxpc 1.10.0.5467 dies with 'std::bad_alloc' instead of naming a missing
# include file, so resolve the includes ourselves to say something useful.
missing_includes() {
  local sma=$1 inc out=""
  for inc in $(sed -n 's/^[[:space:]]*#include[[:space:]]*<\([^>]*\)>.*/\1/p' "$sma"); do
    if [ ! -f "$SRC/include/$inc.inc" ] && [ ! -f "$SRC/include/$inc" ]; then
      out="${out:-} $inc.inc"
    fi
  done
  for inc in $(sed -n 's/^[[:space:]]*#include[[:space:]]*"\([^"]*\)".*/\1/p' "$sma"); do
    if [ ! -f "$SRC/include/$inc" ] && [ ! -f "$SRC/$(dirname "${sma#$SRC/}")/$inc" ]; then
      out="${out:-} $inc"
    fi
  done
  echo "${out# }"
}

# ---- compile ---------------------------------------------------------------
if [ "$MODE" = native ]; then
  WORK=$(mktemp -d)
  trap 'rm -rf "$WORK"' EXIT
  cp -a "$SRC"/*.sma "$SRC"/include "$SRC"/amxxpc "$SRC"/amxxpc32.so "$WORK"/ 2>/dev/null
  ( cd "$WORK"
    if [ -f "$OUT/.subset" ]; then cp "$OUT/.subset" .subset; else ls *.sma > .subset; fi
    while read -r f; do
      ./amxxpc "$f" -i"$WORK/include" -o"$OUT/${f%.sma}" >"$LOGS/$f.log" 2>&1 </dev/null
      echo "$? $f"
    done < .subset ) > "$OUT/.status"
else
  # One container for all plugins: the image has an i386 userland and its own
  # seccomp context, so amxxpc actually executes.
  docker run --rm \
    -v "$AMXX:/amx:ro" \
    -v "$OUT:/out" \
    --tmpfs "/work:exec" \
    -w /work \
    "$IMAGE" sh -c '
      cp -a /amx/scripting/*.sma /amx/scripting/include /work/ || exit 9
      cp -a /amx/scripting/amxxpc /amx/scripting/amxxpc32.so /work/ || exit 9
      chmod +x ./amxxpc
      : > /out/.status
      if [ -f /out/.subset ]; then cp /out/.subset .subset; else ls *.sma > .subset; fi
      while read -r f; do
        ./amxxpc "$f" -i/work/include -o/out/"${f%.sma}" >/out/logs/"$f".log 2>&1 </dev/null
        echo "$? $f" >> /out/.status
      done < .subset
    ' || { echo "FATAL: container runner failed" >&2; exit 4; }
fi

# ---- report ----------------------------------------------------------------
# ALLOW_FAIL: space-separated source names that are known not to build from this
# snapshot (missing third-party includes). They are reported but do not fail the
# run, so CI catches *new* breakage instead of staying red forever. The default
# is the same list CI uses, so `tools/compile-plugins.sh` behaves identically on
# a laptop and on a runner. Set ALLOW_FAIL="" to see every raw failure, e.g.
#   ALLOW_FAIL="" ./tools/compile-plugins.sh
#
# The list is empty on purpose. The three sources that used to be here
# (bypass_guard, ab_bypass_bridge, freenova_http_probe) were only ever failing
# because their third-party headers were missing from the snapshot; those 21
# includes are now in scripting/include/ and all three build (SOURCES.md §7).
# A non-empty default would hide a real regression in them, which is the exact
# opposite of what an allowlist is for. When the next source genuinely cannot
# build from the tree, add it here *and* record why in SOURCES.md.
KNOWN_UNBUILDABLE=""
ALLOW_FAIL=${ALLOW_FAIL-$KNOWN_UNBUILDABLE}
allowed=0
is_allowed() { case " $ALLOW_FAIL " in *" $1 "*) return 0 ;; esac; return 1; }

pass=0; fail=0
while read -r rc name; do
  [ -n "${name:-}" ] || continue
  if [ "$rc" = 0 ]; then
    pass=$((pass + 1))
    printf 'PASS %s\n' "$name"
  else
    if is_allowed "$name"; then
      fail=$((fail + 1))
      allowed=$((allowed + 1))
      mi=$(missing_includes "$SRC/$name")
      printf 'FAIL %s: known-unbuildable (allowed:%s)\n' "$name" "${mi:-no missing include found}"
      continue
    fi
    fail=$((fail + 1))
    reason=$(grep -m1 -E 'error|warning|fatal|bad_alloc|cannot' "$LOGS/$name.log" 2>/dev/null | sed 's/^[[:space:]]*//')
    [ -n "$reason" ] || reason="compiler exited $rc"
    mi=$(missing_includes "$SRC/$name")
    printf 'FAIL %s: %s\n' "$name" "$reason"
    [ -n "$mi" ] && printf '     missing include(s): %s\n' "$mi"
  fi
done < "$OUT/.status"
rm -f "$OUT/.status" "$OUT/.subset"

echo
echo "compiled: $pass   failed: $fail   allowed-failures: $allowed   output: $OUT"
[ $((fail - allowed)) -eq 0 ] || exit 1
