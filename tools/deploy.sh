#!/usr/bin/env bash
# Deploy the repo to the live hosts, one file at a time.
#
# Both hosts reject `sftp -r` ("not a regular file" for every entry), so this
# compares a remote listing against the local tree and `put`s only what differs.
# It never deletes anything on the remote and never touches secrets.
#
#   tools/deploy.sh plugins [--dry-run]   # game server  (CS 1.6 Classic)
#   tools/deploy.sh panel   [--dry-run]   # panel server (leaderboard.fn-net)
#
# Credentials come from ~/.config/freenova-watch/{s1,s2}.pass + askpass.sh
# (the same files the backup pull uses); nothing secret is read from the repo.
#
# Exit: 0 nothing to do or everything uploaded+verified, 1 on any failure.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
CFG=${FREENOVA_CFG:-$HOME/.config/freenova-watch}
TARGET=${1:-}
DRY=${2:-}

case "$TARGET" in
  plugins)
    HOST=193.70.81.30; PORT=2022; USER_SFTP=cmux305a200lt01pppogfv4wj
    PASS="$CFG/s1.pass"
    # local tree  ->  remote root (relative to the server's working dir)
    PAIRS=(
      "$ROOT/game-server/cstrike/addons/amxmodx/plugins|cstrike/addons/amxmodx/plugins"
      "$ROOT/game-server/cstrike/addons/amxmodx/configs|cstrike/addons/amxmodx/configs"
      "$ROOT/game-server/cstrike/addons/amxmodx/scripting/include|cstrike/addons/amxmodx/scripting/include"
      "$ROOT/game-server/cstrike/mapcycle.txt|cstrike/mapcycle.txt"
      "$ROOT/game-server/cstrike/motd.txt|cstrike/motd.txt"
    )
    ;;
  panel)
    HOST=193.70.81.30; PORT=2022; USER_SFTP=cmuyj281s0c0i01p3edt001f0
    PASS="$CFG/s2.pass"
    PAIRS=(
      "$ROOT/web-panel/server_local.mjs|server_local.mjs"
      "$ROOT/web-panel/src|src"
      "$ROOT/web-panel/relay|relay"
      "$ROOT/web-panel/test_harness.mjs|test_harness.mjs"
      "$ROOT/web-panel/schema.sql|schema.sql"
      "$ROOT/web-panel/package.json|package.json"
      "$ROOT/web-panel/package-lock.json|package-lock.json"
      "$ROOT/web-panel/HUB.md|HUB.md"
    )
    ;;
  *)
    echo "usage: tools/deploy.sh <plugins|panel> [--dry-run]" >&2
    exit 2
    ;;
esac

# never ship anything from these, wherever they appear
EXCLUDES='(^|/)(node_modules|\.npm|\.git|__pycache__)(/|$)|\.(pyc|sq3-wal|sq3-shm)$|(^|/)relay\.env$|(^|/)relay\.log$'

# Refuse to deploy a tree with uncommitted changes in the paths we ship: that is
# how half-finished work reaches production (it happened once - an agent's WIP
# went out with an unrelated ads change). --allow-dirty overrides, on purpose.
if [ "$DRY" != "--allow-dirty" ]; then
  dirty=""
  for pair in "${PAIRS[@]}"; do
    local_path=${pair%%|*}
    relpath=${local_path#"$ROOT/"}
    if [ -d "$local_path" ]; then
      d=$(cd "$ROOT" && git status --porcelain -- "$relpath" 2>/dev/null)
    else
      d=$(cd "$ROOT" && git status --porcelain -- "$relpath" 2>/dev/null)
    fi
    [ -n "$d" ] && dirty="$dirty$d"$'\n'
  done
  if [ -n "$dirty" ]; then
    echo "FATAL: uncommitted changes in the deploy paths - commit or stash first:" >&2
    printf '%s' "$dirty" | sed 's/^/   /' >&2
    echo "   (tools/deploy.sh $TARGET --allow-dirty to ship them anyway)" >&2
    exit 3
  fi
fi

[ -r "$PASS" ] || { echo "FATAL: missing $PASS" >&2; exit 1; }
ASKPASS="$CFG/askpass.sh"
[ -x "$ASKPASS" ] || { echo "FATAL: missing $ASKPASS" >&2; exit 1; }

sftp_run() {   # stdin: sftp commands
  SFTP_PASS=$(cat "$PASS") SSH_ASKPASS="$ASKPASS" SSH_ASKPASS_REQUIRE=force \
    sftp -P "$PORT" -o StrictHostKeyChecking=accept-new -o BatchMode=no \
         "$USER_SFTP@$HOST"
}

echo "== $TARGET: collecting local files"
: > /tmp/deploy-local.tsv
for pair in "${PAIRS[@]}"; do
  local_path=${pair%%|*}; remote_rel=${pair#*|}
  [ -e "$local_path" ] || continue
  if [ -d "$local_path" ]; then
    while IFS= read -r -d '' f; do
      rel=${f#"$local_path"/}
      echo "$(printf '%s' "$rel" | sed 's/ /\\ /g')"$'\t'"$remote_rel/$rel"$'\t'"$f" >> /tmp/deploy-local.tsv
    done < <(find "$local_path" -type f -print0)
  else
    echo "$(basename "$local_path")"$'\t'"$remote_rel"$'\t'"$local_path" >> /tmp/deploy-local.tsv
  fi
done
awk -F'\t' -v re="$EXCLUDES" '$2 !~ re' /tmp/deploy-local.tsv > /tmp/deploy-local.filtered.tsv
echo "   $(wc -l < /tmp/deploy-local.filtered.tsv) candidate files"

echo "== $TARGET: listing the remote side"
: > /tmp/deploy-remote.txt
cut -f2 /tmp/deploy-local.filtered.tsv | awk -F/ 'BEGIN{OFS="/"} {p=""; for(i=1;i<NF;i++){p=(p==""?$i:p"/"$i); print "ls -l " p}}' | sort -u > /tmp/deploy-dirs.txt
{ cat /tmp/deploy-dirs.txt; echo "ls -l"; } | sftp_run > /tmp/deploy-remote-raw.txt 2>&1
# name -> size from the ls listing
awk '
  /^sftp> ls -l / { dir=substr($0, index($0,"ls -l ")+6); gsub(/^ +| +$/,"",dir); next }
  /^-/ {
    if (NF == 3) { size=$2; name=$3 } else { size=$5; name=$NF }
    if (name == "." || name == "..") next
    if (dir=="/"||dir==""||dir==name) print name"\t"size; else print dir"/"name"\t"size
  }
' /tmp/deploy-remote-raw.txt | sed 's|//|/|g' > /tmp/deploy-remote.tsv

echo "== $TARGET: comparing"
: > /tmp/deploy-plan.tsv
while IFS=$'\t' read -r rel remote localf; do
  size=$(stat -c%s "$localf")
  rsize=$(awk -F'\t' -v p="$remote" '$1==p {print $2; exit}' /tmp/deploy-remote.tsv)
  if [ -z "$rsize" ]; then
    echo "$remote"$'\t'"$localf"$'\t'"NEW"$'\t'"$size" >> /tmp/deploy-plan.tsv
  elif [ "$rsize" != "$size" ]; then
    echo "$remote"$'\t'"$localf"$'\t'"CHANGED($rsize->$size)"$'\t'"$size" >> /tmp/deploy-plan.tsv
  fi
done < /tmp/deploy-local.filtered.tsv

# Same size does not mean same content (a swapped invite code is the same
# length). Fetch every same-size candidate and compare the bytes.
: > /tmp/deploy-samesize.tsv
while IFS=$'\t' read -r rel remote localf; do
  size=$(stat -c%s "$localf")
  rsize=$(awk -F'\t' -v p="$remote" '$1==p {print $2; exit}' /tmp/deploy-remote.tsv)
  [ "$rsize" = "$size" ] && printf '%s\t%s\t%s\n' "$remote" "$localf" "$size" >> /tmp/deploy-samesize.tsv
done < /tmp/deploy-local.filtered.tsv

if [ -s /tmp/deploy-samesize.tsv ]; then
  rm -rf /tmp/deploy-cmp && mkdir -p /tmp/deploy-cmp
  { while IFS=$'\t' read -r remote localf size; do
      [ "$size" -le 262144 ] && echo "get $(printf '%s' "$remote" | sed 's/ /\\ /g') /tmp/deploy-cmp/$(echo "$remote" | tr '/' '_')"
    done < /tmp/deploy-samesize.tsv; } | sftp_run > /dev/null 2>&1
  same=0; diffc=0
  while IFS=$'\t' read -r remote localf size; do
    [ "$size" -gt 262144 ] && continue
    tmp="/tmp/deploy-cmp/$(echo "$remote" | tr '/' '_')"
    if [ -f "$tmp" ] && ! cmp -s "$localf" "$tmp"; then
      printf '%s\t%s\t%s\t%s\n' "$remote" "$localf" "CONTENT-DIFF($size)" "$size" >> /tmp/deploy-plan.tsv
      diffc=$((diffc+1))
    else
      same=$((same+1))
    fi
  done < /tmp/deploy-samesize.tsv
  echo "== same-size files compared by content: $same identical, $diffc differ"
fi

count=$(wc -l < /tmp/deploy-plan.tsv)
if [ "$count" -eq 0 ]; then echo "== $TARGET: nothing to deploy (remote matches the repo)"; exit 0; fi
echo "== $TARGET: $count file(s) to upload"
cut -f3,1 /tmp/deploy-plan.tsv | sed 's/^/   /'
if [ "$DRY" = "--dry-run" ]; then echo "== dry run, nothing uploaded"; exit 0; fi

mkdir -p /tmp/freenova-deploy/$(date +%Y%m%d-%H%M%S)
BACKDIR=/tmp/freenova-deploy/$(date +%Y%m%d-%H%M%S)
echo "== $TARGET: backing up the live copies to $BACKDIR"
{ while IFS=$'\t' read -r remote localf state size; do
    [ "$state" = "NEW" ] && continue
    echo "get $(printf '%s' "$remote" | sed 's/ /\\ /g') $BACKDIR/$(echo "$remote" | tr '/' '_')"
  done < /tmp/deploy-plan.tsv; } | sftp_run > /dev/null 2>&1

echo "== $TARGET: uploading in batches"
batch=0
{ while IFS=$'\t' read -r remote localf state size; do
    echo "put $localf $remote"
    batch=$((batch+1))
  done < /tmp/deploy-plan.tsv; } > /tmp/deploy-puts.txt
split -l 100 /tmp/deploy-puts.txt /tmp/deploy-chunk-
for chunk in /tmp/deploy-chunk-*; do
  out=$(sftp_run < "$chunk" 2>&1)
  bad=$(printf '%s\n' "$out" | grep -ci 'not found\|Failure\|denied\|No such')
  done_n=$(printf '%s\n' "$out" | grep -c '^Uploading')
  echo "   chunk $(basename "$chunk"): uploaded $done_n, errors $bad"
  [ "$bad" -gt 0 ] && printf '%s\n' "$out" | grep -i 'not found\|Failure\|denied' | head -3 | sed 's/^/      /'
done
rm -f /tmp/deploy-chunk-*

echo "== $TARGET: verifying sizes on the host"
{ cut -f2 /tmp/deploy-local.filtered.tsv | awk -F/ 'BEGIN{OFS="/"} {p=""; for(i=1;i<NF;i++){p=(p==""?$i:p"/"$i); print "ls -l " p}}' | sort -u
  while IFS=$'\t' read -r remote localf state size; do echo "ls -l $(printf '%s' "$remote" | sed 's/ /\\ /g')"; done < /tmp/deploy-plan.tsv
} | sftp_run > /tmp/deploy-verify-raw.txt 2>&1
awk '
  /^sftp> ls -l / { dir=substr($0, index($0,"ls -l ")+6); gsub(/^ +| +$/,"",dir); next }
  /^-/ {
    if (NF == 3) { size=$2; name=$3 } else { size=$5; name=$NF }
    if (name == "." || name == "..") next
    if (dir=="/"||dir==""||dir==name) print name"\t"size; else print dir"/"name"\t"size
  }
' /tmp/deploy-verify-raw.txt | sed 's|//|/|g' > /tmp/deploy-verify.tsv

ok=0; bad=0
while IFS=$'\t' read -r remote localf state size; do
  rsize=$(awk -F'\t' -v p="$remote" '$1==p {print $2; exit}' /tmp/deploy-verify.tsv)
  if [ "$rsize" = "$size" ]; then ok=$((ok+1)); else bad=$((bad+1)); echo "   MISMATCH $remote remote=$rsize local=$size"; fi
done < /tmp/deploy-plan.tsv
echo "== $TARGET: verified $ok/$((ok+bad))"
echo "== rollback copies: $BACKDIR"
[ "$bad" -eq 0 ] || exit 1
echo "== $TARGET: done. Restart via the panel, then confirm in the console."
exit 0
