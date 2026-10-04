#!/bin/bash
# Phase 0: Rosetta signals 2 and 3 (CLAUDE.md, "Rosetta use is a skip signal").
#
#   scripts/phase0/rosetta-check.sh build <DIR>    build the probe apps and run the
#                                                  LSArchitecturePriority check
#   scripts/phase0/rosetta-check.sh launch <DIR>   launch Probe.app and record its arch
#   scripts/phase0/rosetta-check.sh unregister <DIR>
#
# Needs macOS Rosetta. Only apps this script builds under DIR are launched or
# modified; no installed app is read or written. Launching registers the probe
# apps with LaunchServices; `unregister` removes them again.
#
# Apps built, all ad-hoc signed and universal (arm64 + x86_64):
#   Probe.app          no LSArchitecturePriority. For signal 2: set "Open using
#                      Rosetta" on it in Finder, then `launch`.
#   Priority.app       LSArchitecturePriority = (x86_64, arm64).
#   Priority-thin.app  a copy of Priority.app thinned exactly as the writer
#                      would: lipo -remove x86_64 into staging, rename(2) over.

set -euo pipefail

MODE="${1:-}"; DIR="${2:-}"
if [ -z "$DIR" ] || ! [[ "$MODE" =~ ^(build|launch|unregister)$ ]]; then
  echo "usage: $0 build|launch|unregister <DIR>" >&2
  exit 2
fi
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
MIN="-mmacosx-version-min=13.0"

app() { # app NAME BUNDLE_ID [PRIORITY_PLIST_FRAGMENT]
  local c="$DIR/$1.app/Contents"
  mkdir -p "$c/MacOS"
  clang -arch arm64 -arch x86_64 $MIN "$ROOT/scripts/phase0/arch-probe.c" -o "$c/MacOS/$1"
  cat > "$c/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$2</string>
  <key>CFBundleExecutable</key><string>$1</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>LSUIElement</key><true/>
  ${3:-}
</dict>
</plist>
EOF
  codesign --sign - "$DIR/$1.app"
}

run() { # run NAME — launch through LaunchServices and print the probe's line
  # Not `open -W`: the probe can exit before open starts waiting, and open
  # then fails with "kevent() failed: No such process". Poll the log instead.
  local log="$DIR/$1.log"
  rm -f "$log"
  open -n "$DIR/$1.app" --args "$log"
  for _ in $(seq 1 50); do [ -s "$log" ] && break; sleep 0.1; done
  printf '%-18s %s\n' "$1" "$(cat "$log" 2>/dev/null || echo 'no output (did not run?)')"
}

case "$MODE" in
build)
  arch -x86_64 /usr/bin/true || { echo "macOS Rosetta is not installed" >&2; exit 1; }
  mkdir -p "$DIR"
  rm -rf "$DIR"/{Probe,Priority,Priority-thin}.app "$DIR/staging"
  app Probe dev.thinner.probe.rosetta
  app Priority dev.thinner.probe.priority \
    '<key>LSArchitecturePriority</key><array><string>x86_64</string><string>arm64</string></array>'

  ditto "$DIR/Priority.app" "$DIR/Priority-thin.app"
  mkdir -p "$DIR/staging"
  exe="$DIR/Priority-thin.app/Contents/MacOS/Priority"
  lipo -remove x86_64 "$exe" -output "$DIR/staging/Priority"
  chmod "$(stat -f %Lp "$exe")" "$DIR/staging/Priority"
  mv "$DIR/staging/Priority" "$exe"

  for a in Probe Priority Priority-thin; do
    printf '%-18s %s | codesign: ' "$a" "$(lipo -archs "$DIR/$a.app/Contents/MacOS/"*)"
    codesign --verify --deep --strict --all-architectures "$DIR/$a.app" 2>&1 && echo valid
  done
  echo "-- launches (through LaunchServices)"
  run Probe
  run Priority
  run Priority-thin
  ;;
launch)
  run Probe
  ;;
unregister)
  for a in Probe Priority Priority-thin; do "$LSREGISTER" -u "$DIR/$a.app" 2>/dev/null || true; done
  echo "unregistered"
  ;;
esac
