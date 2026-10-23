#!/bin/bash
# Build pgdata Packer and wrap it in a .app bundle.
#
#   ./make-app.sh              release build for this Mac
#   ./make-app.sh debug        debug build
#   ./make-app.sh --universal  release build for Apple Silicon and Intel (one binary; for a release)
#   ./make-app.sh --zip        also write pgdata-Packer-<version>.zip, for a GitHub release
#   ./make-app.sh --spm        build through SwiftPM instead (needs full Xcode; this Mac only)
#
# The result is "./pgdata Packer.app" — double-clickable, no Xcode needed; the Command Line
# Tools are enough (xcode-select --install). Same approach as ThirdWaveWT: SwiftPM looks
# for XCTest even when it does not need it, which fails without Xcode, so by default the
# sources are compiled straight into one module with swiftc. The app sources'
# `import PgdataFormats` is wrapped in `#if canImport(...)` and compiles out.

set -euo pipefail
cd "$(dirname "$0")"

CONFIG="release"
USE_SPM=0
MAKE_ZIP=0
UNIVERSAL=0
for arg in "$@"; do
    case "$arg" in
        debug|release) CONFIG="$arg" ;;
        --spm) USE_SPM=1 ;;
        --zip) MAKE_ZIP=1 ;;
        --universal) UNIVERSAL=1 ;;
        *) echo "unknown argument: $arg" >&2; exit 2 ;;
    esac
done

APP="pgdata Packer.app"
BUNDLE_ID="org.biers.pgdatapacker"
ARCH="$(uname -m)"
VERSION="1.0.2"
DEPLOYMENT_TARGET="13.0"

mkdir -p build

if [ "$USE_SPM" -eq 1 ]; then
    echo "Building through SwiftPM ($CONFIG)…"
    swift build -c "$CONFIG" --product PgdataPacker
    BIN="$(swift build -c "$CONFIG" --show-bin-path)/PgdataPacker"
else
    SDK="$(xcrun --sdk macosx --show-sdk-path)"
    if [ ! -d "$SDK" ]; then
        echo "Could not locate the macOS SDK. Run: xcode-select --install" >&2
        exit 1
    fi
    BIN="build/PgdataPacker"

    if [ "$CONFIG" = "release" ]; then
        OPTFLAGS=(-O -whole-module-optimization)
    else
        OPTFLAGS=(-Onone -g)
    fi
    ARCHS=("$ARCH")
    if [ "$UNIVERSAL" -eq 1 ]; then ARCHS=(arm64 x86_64); fi   # one binary for Apple Silicon and Intel

    echo "Building with swiftc ($CONFIG, ${ARCHS[*]})…"
    echo "  SDK: $SDK"

    SLICES=()
    for A in "${ARCHS[@]}"; do
        SLICE="build/PgdataPacker-$A"
        swiftc \
            "${OPTFLAGS[@]}" \
            -sdk "$SDK" \
            -target "${A}-apple-macos${DEPLOYMENT_TARGET}" \
            -module-name PgdataPacker \
            -framework AppKit \
            -framework SwiftUI \
            -framework UniformTypeIdentifiers \
            -o "$SLICE" \
            Sources/PgdataFormats/*.swift \
            Sources/PgdataPacker/*.swift
        SLICES+=("$SLICE")
    done
    if [ "${#SLICES[@]}" -gt 1 ]; then
        lipo -create "${SLICES[@]}" -output "$BIN"
    else
        cp "${SLICES[0]}" "$BIN"
    fi
fi

if [ ! -x "$BIN" ]; then
    echo "Build produced no binary at $BIN" >&2
    exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PgdataPacker"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>       <string>PgdataPacker</string>
    <key>CFBundleIdentifier</key>       <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>             <string>pgdata Packer</string>
    <key>CFBundleDisplayName</key>      <string>pgdata Packer</string>
    <key>CFBundleIconFile</key>         <string>AppIcon</string>
    <key>CFBundlePackageType</key>      <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key>          <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>   <string>$DEPLOYMENT_TARGET</string>
    <key>NSHighResolutionCapable</key>  <true/>
    <key>NSPrincipalClass</key>         <string>NSApplication</string>
</dict>
</plist>
PLIST

# An unsigned arm64 app is killed at launch, so the ad-hoc signature is required for any build
# that includes an Apple Silicon slice (every release build, and debug builds on Apple Silicon).
if ! codesign --force --sign - "$APP" 2>/dev/null; then
    echo "codesign failed: the app will not launch on Apple Silicon without an ad-hoc signature." >&2
    exit 1
fi

echo
echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/PgdataPacker" 2>/dev/null || echo "$ARCH"))"
echo "Run it with:  open $APP"

if [ "$MAKE_ZIP" -eq 1 ]; then
    ZIP="pgdata-Packer-$VERSION.zip"
    rm -f "$ZIP"
    # ditto keeps the bundle's metadata and signature, which zip does not.
    ditto -c -k --keepParent "$APP" "$ZIP"
    echo "Wrote $ZIP"
fi
