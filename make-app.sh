#!/bin/bash
# Build pgdata Packer and wrap it in a .app bundle.
#
#   ./make-app.sh              release build for this Mac
#   ./make-app.sh debug        debug build
#   ./make-app.sh --universal  release build for Apple Silicon and Intel (one binary; for a release)
#   ./make-app.sh --zip        also write pgdata-Packer-<version>.zip, for a GitHub release
#   ./make-app.sh --spm        build through SwiftPM instead (needs full Xcode; this Mac only)
#   ./make-app.sh --sign "Developer ID Application: Name (TEAMID)"
#                              sign with that identity (hardened runtime, timestamp) instead of
#                              the ad-hoc signature; `security find-identity -v -p codesigning`
#                              lists the identities in your keychain
#   ./make-app.sh --notarize   after signing, submit the app to Apple's notary service, wait for
#                              the result, and staple the ticket; needs --sign and a notarytool
#                              keychain profile named "pgdata-packer", made once with
#                              xcrun notarytool store-credentials "pgdata-packer" --apple-id … --team-id …
#   ./make-app.sh --appcast    after --zip, add the zip to ./appcast.xml with Sparkle's generate_appcast
#                              (signs it with the EdDSA key in your keychain; the download URL is
#                              the GitHub release for tag v<version>); commit appcast.xml to main
#                              once the release is published
#   ./make-app.sh --feed-url=URL
#                              use this update feed instead of the public one (to test updates
#                              against a local appcast)
#
# A release build for distribution: ./make-app.sh --universal --sign "…" --notarize --zip --appcast
#
# In-app updates use Sparkle 2. The script downloads the pinned Sparkle release into build/ (once,
# checked against its SHA-256), links against it, and embeds Sparkle.framework in the app.
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
SIGN_IDENTITY=""
NOTARIZE=0
NOTARY_PROFILE="pgdata-packer"   # xcrun notarytool store-credentials "pgdata-packer" …
MAKE_APPCAST=0
# Sparkle reads the update feed from here. Permanent once a release with it has shipped.
FEED_URL="https://raw.githubusercontent.com/adambier/3rd-wave-tools/main/appcast.xml"
EXPECT_IDENTITY=0
for arg in "$@"; do
    if [ "$EXPECT_IDENTITY" -eq 1 ]; then
        case "$arg" in --*) echo "--sign needs an identity, not \"$arg\"." >&2; exit 2 ;; esac
        SIGN_IDENTITY="$arg"; EXPECT_IDENTITY=0; continue
    fi
    case "$arg" in
        debug|release) CONFIG="$arg" ;;
        --spm) USE_SPM=1 ;;
        --zip) MAKE_ZIP=1 ;;
        --universal) UNIVERSAL=1 ;;
        --sign) EXPECT_IDENTITY=1 ;;
        --sign=*) SIGN_IDENTITY="${arg#--sign=}" ;;
        --notarize) NOTARIZE=1 ;;
        --appcast) MAKE_APPCAST=1 ;;
        --feed-url=*) FEED_URL="${arg#--feed-url=}" ;;
        *) echo "unknown argument: $arg" >&2; exit 2 ;;
    esac
done
if [ "$EXPECT_IDENTITY" -eq 1 ] || { [ "$NOTARIZE" -eq 1 ] && [ -z "$SIGN_IDENTITY" ]; }; then
    echo "--sign needs an identity, and --notarize needs --sign." >&2
    exit 2
fi
if [ "$MAKE_APPCAST" -eq 1 ] && { [ "$MAKE_ZIP" -eq 0 ] || [ "$UNIVERSAL" -eq 0 ]; }; then
    # generate_appcast reads the architectures from the app: a one-architecture build would hide
    # the update from the other kind of Mac.
    echo "--appcast needs --zip and --universal." >&2
    exit 2
fi

APP="pgdata Packer.app"
BUNDLE_ID="org.biers.pgdatapacker"
ARCH="$(uname -m)"
VERSION="1.0.3"
# The build number must rise with every release (an updater compares it): the number of commits.
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
DEPLOYMENT_TARGET="13.0"

# Sparkle 2, for in-app updates. The public half of the EdDSA key that signs each update (the
# private half is in the release signer's keychain; Sparkle's generate_keys made it).
SPARKLE_VERSION="2.10.0"
SPARKLE_SHA256="c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c"
SPARKLE_PUBLIC_ED_KEY="ShzzIZMfB/yPf9gMeqIb2FEgIJ/L/ACcNrYrVLsfS4U="
SPARKLE_DIR="build/Sparkle-$SPARKLE_VERSION"   # the distribution archive, extracted

mkdir -p build

if [ ! -d "$SPARKLE_DIR/Sparkle.framework" ]; then
    SPARKLE_ARCHIVE="build/Sparkle-$SPARKLE_VERSION.tar.xz"
    echo "Downloading Sparkle $SPARKLE_VERSION…"
    curl -fsSL -o "$SPARKLE_ARCHIVE" \
        "https://github.com/sparkle-project/Sparkle/releases/download/$SPARKLE_VERSION/Sparkle-$SPARKLE_VERSION.tar.xz"
    if [ "$(shasum -a 256 "$SPARKLE_ARCHIVE" | cut -d ' ' -f 1)" != "$SPARKLE_SHA256" ]; then
        echo "The Sparkle download does not match its expected SHA-256; not using it." >&2
        rm -f "$SPARKLE_ARCHIVE"
        exit 1
    fi
    rm -rf "$SPARKLE_DIR.partial"
    mkdir -p "$SPARKLE_DIR.partial"
    tar -xf "$SPARKLE_ARCHIVE" -C "$SPARKLE_DIR.partial"
    mv "$SPARKLE_DIR.partial" "$SPARKLE_DIR"
    rm -f "$SPARKLE_ARCHIVE"
fi

if [ "$USE_SPM" -eq 1 ]; then
    if [ "$UNIVERSAL" -eq 1 ]; then echo "--universal is ignored with --spm (SwiftPM builds for this Mac's architecture)." >&2; fi
    echo "Building through SwiftPM ($CONFIG)…"
    # Package.swift does not declare Sparkle (the app compiles without it); point the compiler and
    # linker at the downloaded framework instead.
    SPM_SPARKLE_FLAGS=(-Xswiftc -F -Xswiftc "$PWD/$SPARKLE_DIR"
                       -Xlinker -F -Xlinker "$PWD/$SPARKLE_DIR"
                       -Xlinker -framework -Xlinker Sparkle
                       -Xlinker -rpath -Xlinker @executable_path/../Frameworks)
    swift build -c "$CONFIG" --product PgdataPacker "${SPM_SPARKLE_FLAGS[@]}"
    BIN="$(swift build -c "$CONFIG" --show-bin-path "${SPM_SPARKLE_FLAGS[@]}")/PgdataPacker"
else
    SDK="$(xcrun --sdk macosx --show-sdk-path 2>/dev/null || true)"
    if [ -z "$SDK" ] || [ ! -d "$SDK" ]; then
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
            -F "$SPARKLE_DIR" \
            -framework Sparkle \
            -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
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

# Sparkle.framework, copied with ditto to keep its symlinks and executable bits. The app is not
# sandboxed, so Sparkle's XPC services are not used; Sparkle's docs allow removing them.
SPARKLE_FW="$APP/Contents/Frameworks/Sparkle.framework"
mkdir -p "$APP/Contents/Frameworks"
ditto "$SPARKLE_DIR/Sparkle.framework" "$SPARKLE_FW"
rm -rf "$SPARKLE_FW/XPCServices" "$SPARKLE_FW/Versions/B/XPCServices"
# Sparkle's MIT licence asks for its notice to go with every copy.
cp "$SPARKLE_DIR/LICENSE" "$APP/Contents/Resources/Sparkle-LICENSE.txt"

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
    <key>CFBundleVersion</key>          <string>$BUILD_NUMBER</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
    <key>LSApplicationCategoryType</key><string>public.app-category.music</string>
    <key>LSMinimumSystemVersion</key>   <string>$DEPLOYMENT_TARGET</string>
    <key>NSHighResolutionCapable</key>  <true/>
    <key>NSHumanReadableCopyright</key> <string>MIT License</string>
    <key>NSPrincipalClass</key>         <string>NSApplication</string>
    <key>SUFeedURL</key>                <string>$FEED_URL</string>
    <key>SUPublicEDKey</key>            <string>$SPARKLE_PUBLIC_ED_KEY</string>
</dict>
</plist>
PLIST

# Signed inside-out, never with --deep: Sparkle's helper tool and app, then the framework (removing
# the XPC services invalidated its signature), then the app.
SIGN_ORDER=("$SPARKLE_FW/Versions/B/Autoupdate" "$SPARKLE_FW/Versions/B/Updater.app" "$SPARKLE_FW" "$APP")
if [ -n "$SIGN_IDENTITY" ]; then
    # Developer ID signature with the hardened runtime and a secure timestamp, as notarization
    # requires. The app has no entitlements: nothing it does needs an exception from the runtime.
    echo "Signing with \"$SIGN_IDENTITY\"…"
    for ITEM in "${SIGN_ORDER[@]}"; do
        codesign --force --timestamp --options runtime --sign "$SIGN_IDENTITY" "$ITEM"
    done
    codesign --verify --deep --strict --verbose=2 "$APP"
else
    # An unsigned arm64 app is killed at launch, so the ad-hoc signature is required for any
    # build that includes an Apple Silicon slice (every release build, and debug builds on Apple
    # Silicon). An ad-hoc signed app opens on the Mac that built it; elsewhere macOS warns.
    for ITEM in "${SIGN_ORDER[@]}"; do
        if ! codesign --force --sign - "$ITEM"; then
            echo "codesign failed on $ITEM: the app will not launch on Apple Silicon without an ad-hoc signature." >&2
            exit 1
        fi
    done
fi

if [ "$NOTARIZE" -eq 1 ]; then
    # Submit a zip of the app (ditto keeps the bundle's metadata and signature, which zip does
    # not), wait for Apple's verdict, then staple the ticket to the app so Gatekeeper can check
    # it offline. The zip for distribution is made afterwards, from the stapled app.
    NOTARIZE_ZIP="build/notarize.zip"
    rm -f "$NOTARIZE_ZIP"
    ditto -c -k --keepParent "$APP" "$NOTARIZE_ZIP"
    echo "Submitting to Apple's notary service (profile \"$NOTARY_PROFILE\")…"
    if ! xcrun notarytool submit "$NOTARIZE_ZIP" --keychain-profile "$NOTARY_PROFILE" --wait; then
        echo "Notarization failed. For the reasons:  xcrun notarytool log <submission id> --keychain-profile \"$NOTARY_PROFILE\"" >&2
        exit 1
    fi
    xcrun stapler staple "$APP"
    spctl --assess --type execute --verbose=2 "$APP"
fi

echo
echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/PgdataPacker" 2>/dev/null || echo "$ARCH"), version $VERSION, build $BUILD_NUMBER)"
echo "Run it with:  open \"$APP\""

if [ "$MAKE_ZIP" -eq 1 ]; then
    ZIP="pgdata-Packer-$VERSION.zip"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    echo "Wrote $ZIP"
fi

if [ "$MAKE_APPCAST" -eq 1 ]; then
    # generate_appcast works on a folder of archives and updates the appcast.xml in it: a fresh
    # folder holding the current appcast.xml (if any) and only this release's zip, so the download
    # URL prefix applies to this release alone and the earlier items keep their URLs. A release
    # notes file next to the zip, pgdata-Packer-<version>.html or .md, becomes the update's notes.
    APPCAST_DIR="build/appcast"
    rm -rf "$APPCAST_DIR"
    mkdir -p "$APPCAST_DIR"
    if [ -f appcast.xml ]; then cp appcast.xml "$APPCAST_DIR/appcast.xml"; fi
    cp "$ZIP" "$APPCAST_DIR/"
    for NOTES in "pgdata-Packer-$VERSION.html" "pgdata-Packer-$VERSION.md"; do
        if [ -f "$NOTES" ]; then cp "$NOTES" "$APPCAST_DIR/"; fi
    done
    "$SPARKLE_DIR/bin/generate_appcast" \
        --download-url-prefix "https://github.com/adambier/3rd-wave-tools/releases/download/v$VERSION/" \
        --maximum-versions 0 \
        --maximum-deltas 0 \
        "$APPCAST_DIR"
    cp "$APPCAST_DIR/appcast.xml" appcast.xml
    echo "Updated appcast.xml; commit it to main once the v$VERSION release with $ZIP is published."
fi
