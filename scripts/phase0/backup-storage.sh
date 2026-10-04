#!/bin/bash
# Phase 0: what a retained clonefile backup costs, and which volumes support it.
#
# Everything happens on disk images this script creates under a temporary
# directory, and is detached and removed on exit. No installed app is read or
# written. Usage: scripts/phase0/backup-storage.sh [SLICE_MIB]  (default 64)
#
# Steps on an APFS image, measuring volume free space after each:
#   copy a universal file in → clonefile backup → lipo -remove to staging →
#   rename(2) over the original → release the backup.
# Then clonefile on HFS+ and ExFAT images, and across volumes.

set -euo pipefail

MIB="${1:-64}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/thinner-backup.XXXXXX")"
MOUNTS=()
cleanup() {
  for m in "${MOUNTS[@]+"${MOUNTS[@]}"}"; do hdiutil detach -quiet -force "$m" || true; done
  rm -rf "$WORK"
}
trap cleanup EXIT

PROBE="$WORK/clone-probe"
clang -O1 "$ROOT/scripts/phase0/clone-probe.c" -o "$PROBE"

# A universal file whose slices each carry MIB MiB of signed constant data.
cat > "$WORK/big.c" <<C
const unsigned char blob[$MIB * 1024 * 1024] = {1};
int main(void) { return blob[0] - 1; }
C
clang -O1 -arch arm64 -arch x86_64 "$WORK/big.c" -o "$WORK/big"

mib() { awk -v b="$1" 'BEGIN { printf "%+.1f MiB", b / 1048576 }'; }

attach() {  # attach IMAGE MOUNTPOINT
  mkdir -p "$2"
  hdiutil attach -quiet -nobrowse -mountpoint "$2" "$1"
  MOUNTS+=("$2")
}

echo "== APFS: storage across one thinning, backup retained"
hdiutil create -quiet -size 2g -fs APFS -volname ThinnerAPFS -type SPARSE "$WORK/apfs"
V="$WORK/mnt-apfs"; attach "$WORK/apfs.sparseimage" "$V"
mkdir -p "$V/App.app/Contents/MacOS" "$V/.thinner-staging"
cp "$WORK/big" "$V/App.app/Contents/MacOS/big"; sync
F0=$("$PROBE" free "$V")
UNIVERSAL=$(stat -f %z "$V/App.app/Contents/MacOS/big")

"$PROBE" clone "$V/App.app/Contents/MacOS/big" "$V/.thinner-staging/big.backup" >/dev/null; sync
F1=$("$PROBE" free "$V")
lipo -remove x86_64 "$V/App.app/Contents/MacOS/big" -output "$V/.thinner-staging/big.thin"; sync
F2=$("$PROBE" free "$V")
THIN=$(stat -f %z "$V/.thinner-staging/big.thin")
mv "$V/.thinner-staging/big.thin" "$V/App.app/Contents/MacOS/big"; sync   # rename(2), same volume
F3=$("$PROBE" free "$V")
rm "$V/.thinner-staging/big.backup"; sync   # releasing the backup, disposable image only
F4=$("$PROBE" free "$V")

printf '  universal file %s, thinned file %s\n' "$(mib "$UNIVERSAL")" "$(mib "$THIN")"
printf '  %-40s %s\n' \
  "clonefile backup" "$(mib $((F1 - F0)))" \
  "lipo -remove into staging" "$(mib $((F2 - F1)))" \
  "rename(2) over original" "$(mib $((F3 - F2)))" \
  "net while backup retained" "$(mib $((F3 - F0)))" \
  "release backup" "$(mib $((F4 - F3)))" \
  "net after release" "$(mib $((F4 - F0)))"

echo "== clonefile on other volume formats"
for fs in HFS+ ExFAT; do
  img="$WORK/img-${fs//+/plus}"
  hdiutil create -quiet -size 200m -fs "$fs" -volname "T${fs//+/plus}" "$img"
  m="$WORK/mnt-${fs//+/plus}"; attach "$img.dmg" "$m"
  echo x > "$m/src"
  printf '  %-8s same volume: %s\n' "$fs" "$("$PROBE" clone "$m/src" "$m/dst" || true)"
done
echo x > "$V/src"
printf '  %-8s across volumes: %s\n' "APFS" "$("$PROBE" clone "$V/src" "$WORK/cross" || true)"
