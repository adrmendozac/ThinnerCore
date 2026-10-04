#!/bin/bash
# Phase 0: running-process detection, and what replacing a mapped file does.
#
# Builds a disposable bundle under a temporary directory, keeps its files in
# use from four processes, and checks that process-probe finds each one. Then
# replaces a mapped, not-yet-paged-in dylib under a live process, once by
# rename(2) and once by overwriting it in place. No installed app is touched.
# Usage: scripts/phase0/process-detection.sh

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/thinner-procs.XXXXXX")"
KIDS=()
cleanup() {
  for p in "${KIDS[@]+"${KIDS[@]}"}"; do kill "$p" 2>/dev/null; done
  wait 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT
cd "$WORK"

clang -O1 "$ROOT/scripts/phase0/process-probe.c" -o probe
clang -O1 -arch arm64 -arch x86_64 "$ROOT/scripts/phase0/holder.c" -o holder
cat > big.c <<'C'
#include <stddef.h>
const unsigned char blob[32 * 1024 * 1024] = {1};
unsigned long sum(void) {
    unsigned long s = 0;
    for (size_t i = 0; i < sizeof blob; i += 4096) s += ((volatile const unsigned char *)blob)[i];
    return s;
}
C
clang -O1 -arch arm64 -arch x86_64 -dynamiclib big.c -o libbig.dylib

B="$WORK/Fixture.app/Contents"
mkdir -p "$B/MacOS" "$B/Frameworks" "$B/Resources"
cp holder "$B/MacOS/Fixture"; cp libbig.dylib "$B/Frameworks/"; echo data > "$B/Resources/data.txt"
ln "$B/MacOS/Fixture" "$WORK/outside-link"     # same file, path outside the bundle

start() {  # start ARGS... ; waits until the holder reports ready
  local fifo="$WORK/ready.$RANDOM"; mkfifo "$fifo"
  "$@" "$fifo" & KIDS+=($!)
  read -r _ < "$fifo"
}
start "$B/MacOS/Fixture" pause -                         # executable inside the bundle
start ./holder map "$B/Frameworks/libbig.dylib"          # outside host mapping bundle code
start ./holder open "$B/Resources/data.txt"              # bundle file held open
start "$WORK/outside-link" pause -                       # bundle file run via another path

echo "== process-probe (expect 4 processes: executable, mapped, open fd, file identity)"
./probe "$WORK/Fixture.app"
echo "== lsof +D for comparison"
lsof -n +D "$WORK/Fixture.app" 2>/dev/null | awk 'NR>1 {print $2, $4, $NF}' | sort -u
echo "== lsof misses the hard-linked run unless asked about that path:"
lsof -n "$WORK/outside-link" 2>/dev/null | awk 'NR>1 {print $2, $4, $NF}'

for p in "${KIDS[@]}"; do kill "$p" 2>/dev/null; done; wait 2>/dev/null; KIDS=()

echo "== replacing a mapped dylib under a live process"
lipo -remove x86_64 libbig.dylib -output libbig.thin.dylib
for how in rename inplace; do
  cp libbig.dylib "lib-$how.dylib"
  go="$WORK/go.$how"; mkfifo "$go"; ready="$WORK/r.$how"; mkfifo "$ready"
  ./holder touch "$WORK/lib-$how.dylib" "$ready" "$go" > "out.$how" 2>&1 & pid=$!
  read -r _ < "$ready"
  if [ "$how" = rename ]; then
    cp libbig.thin.dylib staged.dylib && mv staged.dylib "lib-$how.dylib"; res=$?
  else
    cat libbig.thin.dylib > "lib-$how.dylib"; res=$?
  fi
  echo go > "$go"
  wait "$pid"; st=$?
  if [ $st -gt 128 ]; then outcome="killed by signal $((st - 128)) ($(kill -l $((st - 128))))"; else outcome="exit $st"; fi
  printf '  %-8s replace rc %d -> holder %s: %s\n' "$how" "$res" "$outcome" "$(tr '\n' ' ' < "out.$how")"
done
