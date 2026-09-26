#!/bin/bash
# Builds the test fixture matrix. Tests never touch real apps, so every file
# the classifier and writer are tested against comes from here.
#
# Usage: scripts/make-fixtures.sh [OUTDIR]     (default: .build/fixtures)
#
# OUTDIR is recreated from scratch. To avoid wiping something by accident, an
# existing OUTDIR is only removed if it carries the stamp this script writes.
#
# Layout:
#   macho/fat-arm64-x86_64            FAT_MAGIC, the common thinnable case
#   macho/fat-arm64e-x86_64           arm64e is the only Apple Silicon slice
#   macho/fat-arm64-x86_64-x86_64h    two Intel slices to remove
#   macho/fat64-arm64-x86_64          FAT_MAGIC_64 (lipo -fat64)
#   macho/thin-arm64                  nothing to do
#   macho/thin-x86_64                 no arm64 slice: must never be touched
#   macho/quarantined-fat-arm64-x86_64  carries com.apple.quarantine
#   java/Hello.class                  starts with 0xCAFEBABE but is not Mach-O
#   bundles/Signed.app                ad-hoc signed app whose seal covers:
#     Contents/MacOS/Signed                              absent from files2
#     Contents/Frameworks/Foo.framework                  cdhash (versioned, symlinks)
#     Contents/Frameworks/libloose.dylib                 cdhash
#     Contents/Resources/addon.node                      hash2 (thinning breaks it)
#   bundles/Nested.app                seal-chain and slice-mix cases:
#     Contents/MacOS/Nested                              main executable
#     Contents/MacOS/nested-tool                         cdhash, not the main executable
#     Contents/Library/LoginItems/Helper.app             cdhash; its own main executable inside
#     Contents/Resources/Plugin.bundle                   signed, but in Resources: hash2 per file
#     Contents/Resources/Hello.class                     Java, not Mach-O
#     Contents/Frameworks/libarm64e.dylib                arm64e + x86_64
#     Contents/Frameworks/libintel.dylib                 x86_64 + x86_64h, no Apple Silicon
#     Contents/Frameworks/libapple.dylib                 arm64 + arm64e, no Intel
#     Contents/Frameworks/libthin.dylib                  arm64 only, not universal
#   bundles/Multi.framework           Versions/A (Current) and Versions/B, each signed
#
# Every source carries 64 KiB of initialised data so each slice is larger than
# lipo's 16 KiB alignment padding; otherwise removing a slice saves nothing.
#
# The ad-hoc signatures exist only to reproduce the seal types a vendor
# signature produces. The tool itself never signs anything.

set -euo pipefail

STAMP=".thinner-fixtures"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/.build/fixtures}"

case "$OUT" in
  /Applications*|/System*|/Library*|/usr*)
    echo "error: refusing to write fixtures to $OUT" >&2
    exit 1
    ;;
esac

if [ -e "$OUT" ]; then
  if [ -f "$OUT/$STAMP" ]; then
    rm -rf "$OUT"
  elif [ -n "$(ls -A "$OUT")" ]; then
    echo "error: $OUT exists, is not empty, and was not made by this script" >&2
    exit 1
  fi
fi
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
touch "$OUT/$STAMP"

SRC="$(mktemp -d)"
trap 'rm -rf "$SRC"' EXIT

MIN="-mmacosx-version-min=13.0"

cat > "$SRC/main.c" <<'EOF'
__attribute__((used)) static const char padding[65536] = {1};
int main(void) { return padding[0] - 1; }
EOF
cat > "$SRC/lib.c" <<'EOF'
__attribute__((used)) static const char padding[65536] = {1};
int thinner_fixture(void) { return padding[0]; }
EOF

archflags() { # archflags ARCH...
  local flags=""
  for a in "$@"; do flags="$flags -arch $a"; done
  echo "$flags"
}

exe() { # exe OUTPUT ARCH...
  local out="$1"; shift
  clang $(archflags "$@") $MIN "$SRC/main.c" -o "$out"
}

dylib() { # dylib OUTPUT INSTALL_NAME ARCH...
  local out="$1" name="$2"; shift 2
  clang $(archflags "$@") $MIN -dynamiclib "$SRC/lib.c" -install_name "$name" -o "$out"
}

framework() { # framework DIR ID VERSION... (last VERSION becomes Current)
  local dir="$1" id="$2"; shift 2
  local name v
  name="$(basename "$dir" .framework)"
  for v in "$@"; do
    mkdir -p "$dir/Versions/$v/Resources"
    dylib "$dir/Versions/$v/$name" "@rpath/$name.framework/Versions/$v/$name" arm64 x86_64
    plist "$dir/Versions/$v/Resources/Info.plist" "$id" "$name" FMWK
    codesign --sign - "$dir/Versions/$v"
  done
  ln -s "$v" "$dir/Versions/Current"
  ln -s "Versions/Current/$name" "$dir/$name"
  ln -s Versions/Current/Resources "$dir/Resources"
}

plist() { # plist PATH ID EXECUTABLE TYPE
  cat > "$1" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$2</string>
  <key>CFBundleExecutable</key><string>$3</string>
  <key>CFBundlePackageType</key><string>$4</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
</dict>
</plist>
EOF
}

# --- Loose Mach-O files -----------------------------------------------------

M="$OUT/macho"
mkdir -p "$M"
exe "$M/fat-arm64-x86_64" arm64 x86_64
exe "$M/fat-arm64e-x86_64" arm64e x86_64
exe "$M/fat-arm64-x86_64-x86_64h" arm64 x86_64 x86_64h
exe "$M/thin-arm64" arm64
exe "$M/thin-x86_64" x86_64

exe "$SRC/a" arm64
exe "$SRC/x" x86_64
lipo -create -fat64 "$SRC/a" "$SRC/x" -output "$M/fat64-arm64-x86_64"

exe "$M/quarantined-fat-arm64-x86_64" arm64 x86_64
xattr -w com.apple.quarantine "0081;00000000;Safari;" \
  "$M/quarantined-fat-arm64-x86_64"

# --- Java class file ----------------------------------------------------------
# A minimal valid class (public class Hello extends Object). Read as a fat
# header, its version fields give nfat_arch = 52, which is the tell.

mkdir -p "$OUT/java"
CLASS="cafebabe 0000 0034 0005
  07 0002  01 0005 48656c6c6f
  07 0004  01 0010 6a6176612f6c616e672f4f626a656374
  0021 0001 0003 0000 0000 0000 0000"
HEX="$(echo "$CLASS" | tr -d ' \n')"
BYTES=""
while [ -n "$HEX" ]; do
  BYTES="$BYTES\\x${HEX:0:2}"
  HEX="${HEX:2}"
done
printf "$BYTES" > "$OUT/java/Hello.class"

# Bundles are signed inside-out, as a vendor build would be.

# --- Signed.app ---------------------------------------------------------------

APP="$OUT/bundles/Signed.app"
C="$APP/Contents"
mkdir -p "$C/MacOS" "$C/Frameworks" "$C/Resources"

exe "$C/MacOS/Signed" arm64 x86_64
plist "$C/Info.plist" dev.thinner.fixture.signed Signed APPL

framework "$C/Frameworks/Foo.framework" dev.thinner.fixture.foo A

dylib "$C/Frameworks/libloose.dylib" @rpath/libloose.dylib arm64 x86_64
codesign --sign - "$C/Frameworks/libloose.dylib"

clang -arch arm64 -arch x86_64 $MIN -bundle "$SRC/lib.c" -o "$C/Resources/addon.node"
codesign --sign - "$C/Resources/addon.node"

codesign --sign - "$APP"
codesign --verify --deep --strict --all-architectures "$APP"

# --- Nested.app ---------------------------------------------------------------

APP="$OUT/bundles/Nested.app"
C="$APP/Contents"
mkdir -p "$C/MacOS" "$C/Frameworks" "$C/Resources" "$C/Library/LoginItems"

exe "$C/MacOS/Nested" arm64 x86_64
plist "$C/Info.plist" dev.thinner.fixture.nested Nested APPL

exe "$C/MacOS/nested-tool" arm64 x86_64
codesign --sign - "$C/MacOS/nested-tool"

HELPER="$C/Library/LoginItems/Helper.app"
mkdir -p "$HELPER/Contents/MacOS"
exe "$HELPER/Contents/MacOS/Helper" arm64 x86_64
plist "$HELPER/Contents/Info.plist" dev.thinner.fixture.helper Helper APPL
codesign --sign - "$HELPER"

PLUGIN="$C/Resources/Plugin.bundle"
mkdir -p "$PLUGIN/Contents/MacOS"
clang -arch arm64 -arch x86_64 $MIN -bundle "$SRC/lib.c" -o "$PLUGIN/Contents/MacOS/Plugin"
plist "$PLUGIN/Contents/Info.plist" dev.thinner.fixture.plugin Plugin BNDL
codesign --sign - "$PLUGIN"

cp "$OUT/java/Hello.class" "$C/Resources/Hello.class"

F="$C/Frameworks"
dylib "$F/libarm64e.dylib" @rpath/libarm64e.dylib arm64e x86_64
dylib "$F/libintel.dylib" @rpath/libintel.dylib x86_64 x86_64h
dylib "$F/libapple.dylib" @rpath/libapple.dylib arm64 arm64e
dylib "$F/libthin.dylib" @rpath/libthin.dylib arm64
for lib in libarm64e libintel libapple libthin; do
  codesign --sign - "$F/$lib.dylib"
done

codesign --sign - "$APP"
codesign --verify --deep --strict --all-architectures "$APP"

# --- Multi.framework ----------------------------------------------------------
# Standalone, not embedded: under --strict an app verifies every version of an
# embedded framework against the requirement in its own seal, and an ad-hoc
# requirement names exact cdhashes, which only the Current version matches.

framework "$OUT/bundles/Multi.framework" dev.thinner.fixture.multi B A

echo "fixtures written to $OUT"
