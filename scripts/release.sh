#!/bin/bash
# Builds, signs, and notarizes a release of the thinnercore CLI, and renders
# the Homebrew formula for it. Publishes nothing: uploading the zip and the
# formula stays a manual step.
#
# Usage: scripts/release.sh
#
# Requires, in the environment:
#   DEVELOPER_ID     codesign identity, e.g. "Developer ID Application: Name (TEAMID)"
#   NOTARY_PROFILE   a notarytool keychain profile, made once with:
#                    xcrun notarytool store-credentials <profile> --apple-id … --team-id …
# Optional:
#   IDENTIFIER       code signing identifier (default: thinnercore)
#   REPO             GitHub owner/name the release is uploaded to (default: origin's)
#
# Refuses a development version, a dirty tree, and a build with the mutation
# development flag (THINNER_DEV_MUTATION) compiled in.
set -euo pipefail

cd "$(dirname "$0")/.."
: "${DEVELOPER_ID:?set DEVELOPER_ID to your Developer ID Application identity}"
: "${NOTARY_PROFILE:?set NOTARY_PROFILE to a notarytool keychain profile}"
IDENTIFIER="${IDENTIFIER:-thinnercore}"
REPO="${REPO:-$(git remote get-url origin | sed -E 's#(git@github.com:|https://github.com/)##; s#\.git$##')}"

fail() { echo "release: $*" >&2; exit 1; }

VERSION=$(sed -nE 's/.*static let version = "([^"]+)".*/\1/p' Sources/ThinnerCore/ThinnerCore.swift)
[[ -n "$VERSION" ]] || fail "cannot read the version from Sources/ThinnerCore/ThinnerCore.swift"
[[ "$VERSION" != *-dev* ]] || fail "version $VERSION is a development version; set a release version first"
[[ -z "$(git status --porcelain)" ]] || fail "the working tree has uncommitted changes"

OUT=".build/release-artifacts/$VERSION"
rm -rf "$OUT"
mkdir -p "$OUT"

# A clean arm64 release build. Any extra Swift flags in the environment
# could carry the development flag, so none are passed.
swift build -c release --arch arm64 --disable-sandbox
BIN=$(swift build -c release --arch arm64 --show-bin-path)/thinnercore
[[ -x "$BIN" ]] || fail "no binary at $BIN"

# A build with mutation opened for development announces itself on every run.
if "$BIN" --version 2>&1 >/dev/null | grep -q THINNER_DEV_MUTATION; then
  fail "this build has THINNER_DEV_MUTATION compiled in; it must never be distributed"
fi
[[ "$("$BIN" --version)" == "$VERSION" ]] || fail "the binary does not report version $VERSION"
lipo -archs "$BIN" | grep -qx arm64 || fail "the binary is not arm64-only"

cp "$BIN" "$OUT/thinnercore"
codesign --force --timestamp --options runtime --identifier "$IDENTIFIER" \
  --sign "$DEVELOPER_ID" "$OUT/thinnercore"
codesign --verify --strict --verbose=2 "$OUT/thinnercore"
DETAILS=$(codesign --display --verbose=4 "$OUT/thinnercore" 2>&1)
grep -q '^Authority=Developer ID Application' <<<"$DETAILS" || fail "not signed with a Developer ID Application identity"
grep -q 'flags=.*runtime' <<<"$DETAILS" || fail "hardened runtime is not enabled"
grep -q '^Timestamp=' <<<"$DETAILS" || fail "the signature has no secure timestamp"

ZIP="$OUT/thinnercore-$VERSION-arm64.zip"
ditto -c -k --keepParent "$OUT/thinnercore" "$ZIP"
# A bare executable cannot be stapled; Gatekeeper looks its ticket up online.
SUBMISSION=$(xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1) || true
echo "$SUBMISSION"
grep -q 'status: Accepted' <<<"$SUBMISSION" || fail "notarization was not accepted; see: xcrun notarytool log <id> --keychain-profile $NOTARY_PROFILE"

SHA=$(shasum -a 256 "$ZIP" | cut -d' ' -f1)
sed -e "s|@VERSION@|$VERSION|g" -e "s|@SHA256@|$SHA|g" -e "s|@REPO@|$REPO|g" \
  packaging/homebrew/thinnercore-binary.rb > "$OUT/thinnercore.rb"

cat <<EOF

Release $VERSION is signed and notarized. Nothing was published.
  Archive:  $ZIP
  SHA-256:  $SHA
  Formula:  $OUT/thinnercore.rb

To publish:
  1. Tag v$VERSION and upload the archive to https://github.com/$REPO/releases/tag/v$VERSION
  2. Copy the formula to Formula/thinnercore.rb in your tap repository (homebrew-<name>)
EOF
