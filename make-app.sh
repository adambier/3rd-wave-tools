#!/bin/bash
# Build the 3rd Wave Program Packer and wrap it in a .app bundle.
#
#   ./make-app.sh            release build, compiled directly with swiftc
#   ./make-app.sh debug      debug build
#   ./make-app.sh --spm      build through SwiftPM instead (needs full Xcode)
#
# The result is ./ThirdWavePG.app — double-clickable, no Xcode needed; the Command Line
# Tools are enough (xcode-select --install). Same approach as ThirdWaveWT: SwiftPM looks
# for XCTest even when it does not need it, which fails without Xcode, so by default the
# sources are compiled straight into one module with swiftc. The app sources'
# `import ThirdWaveFormats` is wrapped in `#if canImport(...)` and compiles out.

set -euo pipefail
cd "$(dirname "$0")"

CONFIG="release"
USE_SPM=0
for arg in "$@"; do
    case "$arg" in
        debug|release) CONFIG="$arg" ;;
        --spm) USE_SPM=1 ;;
        *) echo "unknown argument: $arg" >&2; exit 2 ;;
    esac
done

APP="ThirdWavePG.app"
BUNDLE_ID="org.biers.thirdwavepg"
VERSION="1.0"
DEPLOYMENT_TARGET="13.0"

mkdir -p build

if [ "$USE_SPM" -eq 1 ]; then
    echo "Building through SwiftPM ($CONFIG)…"
    swift build -c "$CONFIG" --product ThirdWavePG
    BIN="$(swift build -c "$CONFIG" --show-bin-path)/ThirdWavePG"
else
    SDK="$(xcrun --sdk macosx --show-sdk-path)"
    if [ ! -d "$SDK" ]; then
        echo "Could not locate the macOS SDK. Run: xcode-select --install" >&2
        exit 1
    fi
    ARCH="$(uname -m)"
    BIN="build/ThirdWavePG"

    if [ "$CONFIG" = "release" ]; then
        OPTFLAGS=(-O -whole-module-optimization)
    else
        OPTFLAGS=(-Onone -g)
    fi

    echo "Building with swiftc ($CONFIG, $ARCH)…"
    echo "  SDK: $SDK"

    swiftc \
        "${OPTFLAGS[@]}" \
        -sdk "$SDK" \
        -target "${ARCH}-apple-macos${DEPLOYMENT_TARGET}" \
        -module-name ThirdWavePG \
        -framework AppKit \
        -framework SwiftUI \
        -framework UniformTypeIdentifiers \
        -o "$BIN" \
        Sources/ThirdWaveFormats/*.swift \
        Sources/ThirdWavePG/*.swift
fi

if [ ! -x "$BIN" ]; then
    echo "Build produced no binary at $BIN" >&2
    exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ThirdWavePG"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>       <string>ThirdWavePG</string>
    <key>CFBundleIdentifier</key>       <string>$BUNDLE_ID</string>
    <key>CFBundleName</key>             <string>3rd Wave Packer</string>
    <key>CFBundleDisplayName</key>      <string>3rd Wave Program Packer</string>
    <key>CFBundlePackageType</key>      <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key>          <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>   <string>$DEPLOYMENT_TARGET</string>
    <key>NSHighResolutionCapable</key>  <true/>
    <key>NSPrincipalClass</key>         <string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP" 2>/dev/null || \
    echo "note: ad-hoc codesign skipped (not fatal)"

echo
echo "Built $APP"
echo "Run it with:  open $APP"
