#!/bin/bash
# Builds the Phase 0 App Management probe and prints the code identity macOS
# will see: identifier, cdhash, and designated requirement.
#
# Usage: scripts/phase0/build-probe.sh VARIANT [IDENTITY] [OUTDIR]
#   VARIANT   integer compiled into the probe; a different value gives a
#             different cdhash, standing in for a rebuild after a code change
#   IDENTITY  optional codesign identity (e.g. a self-signed "Thinner Probe"
#             certificate); omitted means the linker's ad-hoc signature
#   OUTDIR    default: .build/phase0
#
# Building is harmless anywhere. Running the probe is not: see
# docs/research/phase0.md.

set -euo pipefail

VARIANT="${1:?usage: build-probe.sh VARIANT [IDENTITY] [OUTDIR]}"
IDENTITY="${2:-}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${3:-$ROOT/.build/phase0}"

mkdir -p "$OUT"
BIN="$OUT/app-management-probe"
clang -O1 -DPROBE_VARIANT="$VARIANT" "$ROOT/scripts/phase0/app-management-probe.c" -o "$BIN"

if [ -n "$IDENTITY" ]; then
  # A fixed identifier, so a stable certificate gives a stable requirement.
  codesign --force --sign "$IDENTITY" --identifier dev.thinner.phase0.probe "$BIN"
fi

codesign -dvvv "$BIN" 2>&1 | grep -E '^(Identifier|Signature|TeamIdentifier|CDHash)='
codesign -d -r- "$BIN" 2>&1 | grep designated
echo "built $BIN"
