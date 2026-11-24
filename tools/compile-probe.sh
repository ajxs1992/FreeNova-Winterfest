#!/usr/bin/env bash
# tools/compile-probe.sh - build one probe/driver plugin from tools/build/probe/
# and drop the .amxx where scripts/wf-local.sh can pick it up.
#
#   bash tools/compile-probe.sh zz_test_matrix
#   WF_EXTRA_PLUGINS=zz_test_matrix bash scripts/wf-local.sh restart
#
# Probes are test assets, not shipped plugins: they are not in scripting/, so
# tools/compile-plugins.sh never sees them and the 156-source count stays what a
# release reports. They use the same compiler, the same include path and the same
# container runner as that script, so a probe that builds here builds there.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
AMXX="$ROOT/game-server/cstrike/addons/amxmodx"
SRC="$ROOT/tools/probes"
OUT="$AMXX/plugins"
IMAGE=${AMXX_IMAGE:-i386/debian:bookworm-slim}

name=${1:-}
[ -n "$name" ] || { echo "usage: bash tools/compile-probe.sh <name>  (source: tools/probes/<name>.sma)" >&2; exit 2; }
name=${name%.sma}
[ -f "$SRC/$name.sma" ] || { echo "FATAL: no such probe source: $SRC/$name.sma" >&2; exit 2; }

mkdir -p "$SRC/out" "$OUT"

# Sources are copied to /work first, exactly like compile-plugins.sh, so a probe
# can never write next to its own source.
docker run --rm \
  -v "$AMXX/scripting/include:/inc:ro" \
  -v "$AMXX/scripting:/amx:ro" \
  -v "$SRC:/probe" \
  --tmpfs /work:exec \
  i386/debian:bookworm-slim sh -c "
    cp -a /amx/amxxpc /amx/amxxpc32.so /work/ && cp /probe/$name.sma /work/ &&
    cd /work && chmod +x amxxpc &&
    ./amxxpc $name.sma -i/inc -i/work -o/probe/out/$name" || { echo "FATAL: container runner failed" >&2; exit 4; }

if [ -f "$SRC/out/$name.amxx" ]; then
  cp -f "$SRC/out/$name.amxx" "$OUT/$name.amxx"
  echo "ok   $name.amxx -> ${OUT#$ROOT/}"
else
  echo "FAIL $name.sma did not build (see the output above)" >&2
  exit 1
fi
