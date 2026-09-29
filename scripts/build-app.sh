#!/bin/bash
# Builds build/Upnext.app for Apple silicon.
#
#   scripts/build-app.sh            # release build, ad-hoc signed
#   scripts/build-app.sh --dmg      # also makes build/Upnext.dmg
#   SIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh
#
# Needs Xcode or the Command Line Tools (xcode-select --install).
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$(pwd)
APP="$ROOT/build/Upnext.app"
MAKE_DMG=0
[[ "${1:-}" == "--dmg" ]] && MAKE_DMG=1

if [[ "$(sysctl -n hw.optional.arm64 2>/dev/null)" != "1" ]]; then
    echo "Upnext is built for Apple silicon Macs." >&2
    exit 1
fi
if [[ "$(uname -m)" != "arm64" ]]; then
    echo "This Terminal is running under Rosetta; building an Intel binary would be wrong." >&2
    echo "Quit Terminal, untick “Open using Rosetta” in its Get Info window, and retry." >&2
    exit 1
fi

# Use SwiftPM's own build system. Passing --arch, or newer toolchains' default,
# routes through Xcode's build system, which fails on some Xcode versions with
# "Could not initialize build system … Unknown error parsing property list".
BUILD_FLAGS=(-c release)
if swift build --help 2>/dev/null | grep -q -- "--build-system"; then
    BUILD_FLAGS+=(--build-system native)
fi

echo "==> Compiling (arm64, release)"
swift build "${BUILD_FLAGS[@]}"
BIN_DIR="$(swift build "${BUILD_FLAGS[@]}" --show-bin-path)"

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Upnext" "$APP/Contents/MacOS/Upnext"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Widget extension. It has to be a real Xcode app-extension build: on macOS 26+
# a SwiftPM executable wrapped in an .appex starts and then crashes.
APPEX="$APP/Contents/PlugIns/UpnextWidget.appex"
XCODE_DEV=""
if [[ "$(xcode-select -p 2>/dev/null)" == *.app/Contents/Developer ]]; then
    XCODE_DEV="$(xcode-select -p)"
else
    for candidate in /Applications/Xcode.app /Applications/Xcode*.app; do
        if [[ -d "$candidate/Contents/Developer" ]]; then
            XCODE_DEV="$candidate/Contents/Developer"
            break
        fi
    done
fi
if [[ -n "$XCODE_DEV" ]]; then
    echo "==> Building widget extension (Xcode at ${XCODE_DEV%/Contents/Developer})"
    DEVELOPER_DIR="$XCODE_DEV" xcodebuild -quiet \
        -project UpnextWidget.xcodeproj -target UpnextWidget -configuration Release \
        SYMROOT="$ROOT/build/xcode" OBJROOT="$ROOT/build/xcode/obj" \
        CODE_SIGNING_ALLOWED=NO build
    mkdir -p "$APP/Contents/PlugIns"
    cp -R "$ROOT/build/xcode/Release/UpnextWidget.appex" "$APPEX"
else
    echo "!!  Xcode not found: skipping the widget. Install Xcode from the App Store"
    echo "    (the Command Line Tools alone can't build widgets), then re-run."
fi

# App icon: PNG → .icns (the PNG is generated if it isn't checked out)
[[ -f Resources/AppIcon.png ]] || python3 scripts/make-icon.py Resources/AppIcon.png
ICONSET="$ROOT/build/AppIcon.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z $size $size Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z $double $double Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

echo "==> Signing"
IDENTITY="${SIGN_IDENTITY:--}"
SIGN_ARGS=(--force --sign "$IDENTITY")
if [[ "$IDENTITY" != "-" ]]; then
    SIGN_ARGS+=(--options runtime --timestamp)
fi
# Inside out: the extension first (it must be sandboxed), then the app.
if [[ -d "$APPEX" ]]; then
    codesign "${SIGN_ARGS[@]}" --entitlements Resources/UpnextWidget.entitlements "$APPEX"
fi
codesign "${SIGN_ARGS[@]}" "$APP"
codesign --verify --strict --deep "$APP"

if [[ $MAKE_DMG == 1 ]]; then
    echo "==> Making DMG"
    STAGE="$ROOT/build/dmg"
    rm -rf "$STAGE" "$ROOT/build/Upnext.dmg"
    mkdir -p "$STAGE"
    cp -R "$APP" "$STAGE/"
    ln -s /Applications "$STAGE/Applications"
    hdiutil create -volname Upnext -srcfolder "$STAGE" -ov -format UDZO "$ROOT/build/Upnext.dmg" >/dev/null
    rm -rf "$STAGE"
    echo "    build/Upnext.dmg"
fi

echo "==> Done: $APP"
echo "    Install with:  scripts/install.sh"
