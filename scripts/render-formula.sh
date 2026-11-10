#!/bin/bash
# Prints the source-build Homebrew formula for a pushed release tag, with the
# SHA-256 of GitHub's source tarball for that tag filled in.
#
# Usage: scripts/render-formula.sh X.Y.Z > ../homebrew-tap/Formula/thinnercore.rb
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION="${1:?usage: scripts/render-formula.sh X.Y.Z}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "render-formula: $VERSION is not X.Y.Z" >&2; exit 1; }

URL="https://github.com/adrmendozac/ThinnerCore/archive/refs/tags/v$VERSION.tar.gz"
SHA=$(curl --fail --silent --show-error --location "$URL" | shasum -a 256 | cut -d' ' -f1)
# The checksum of an empty download, which --fail should already prevent.
[[ "$SHA" != e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 ]] || { echo "render-formula: empty download from $URL" >&2; exit 1; }

sed -e "s|@VERSION@|$VERSION|g" -e "s|@SHA256@|$SHA|g" packaging/homebrew/thinnercore.rb
