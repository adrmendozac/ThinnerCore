#!/bin/bash
# Phase 0: does Gatekeeper still accept a notarized app after thinning?
#
#   scripts/phase0/gatekeeper-check.sh --yes-modify <App.app> <file inside app>...
#
# Thins each named file in place, exactly as the writer would (lipo -remove
# into staging outside the bundle, then rename(2) over the original), and
# reports codesign, spctl, and provenance before and after. It modifies the
# app, so run it only in a disposable VM, on a Developer ID signed, notarized
# fixture that was downloaded (quarantined) and launched once. Quit the app
# first. Procedure: docs/research/phase0.md, "Gatekeeper and notarization".

set -uo pipefail

if [ "${1:-}" != "--yes-modify" ] || [ $# -lt 3 ]; then
  echo "usage: $0 --yes-modify <App.app> <file inside app>...  (disposable VMs only)" >&2
  exit 2
fi
APP="${2%/}"; shift 2
STAGING="$(mktemp -d "${TMPDIR:-/tmp}/thinner-gk.XXXXXX")"   # same volume as the app in a default VM

report() {
  echo "-- $1"
  codesign --verify --deep --strict --all-architectures "$APP" 2>&1 && echo "codesign: valid"
  spctl --assess --type execute -vv "$APP" 2>&1
  if command -v syspolicy_check >/dev/null; then syspolicy_check distribution "$APP" 2>&1 | tail -3; fi
  echo "quarantine: $(xattr -p com.apple.quarantine "$APP" 2>/dev/null || echo none)"
  for f in "${FILES[@]}"; do
    printf 'provenance %-50s %s\n' "$f" "$(xattr -px com.apple.provenance "$APP/$f" 2>/dev/null | tr -d ' \n' || echo none)"
  done
}

FILES=("$@")
report "before thinning"
for f in "${FILES[@]}"; do
  src="$APP/$f"; tmp="$STAGING/$(basename "$f").thin"
  lipo -remove x86_64 "$src" -output "$tmp" || { echo "lipo failed on $f"; exit 1; }
  chmod "$(stat -f %Lp "$src")" "$tmp"
  mv "$tmp" "$src" || { echo "rename failed on $f"; exit 1; }
done
report "after thinning"
echo "Now launch it with: open \"$APP\"  — record any dialog, then check Console for syspolicyd."
