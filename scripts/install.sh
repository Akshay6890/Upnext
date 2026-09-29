#!/bin/bash
# Installs build/Upnext.app into /Applications and makes macOS forget old
# copies, so Finder, the Dock and System Settings › Storage show the current
# icon and version.
#
#   scripts/build-app.sh && scripts/install.sh
set -euo pipefail

cd "$(dirname "$0")/.."
SRC="$(pwd)/build/Upnext.app"
DEST="/Applications/Upnext.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

[[ -d "$SRC" ]] || { echo "No build/Upnext.app yet. Run scripts/build-app.sh first." >&2; exit 1; }

echo "==> Quitting Upnext"
osascript -e 'quit app id "com.upnext.Upnext"' 2>/dev/null || true
sleep 1

echo "==> Installing to $DEST"
rm -rf "$DEST"
cp -R "$SRC" "$DEST"
touch "$DEST"

echo "==> Refreshing macOS's app and icon records"
# Forget the copy in build/ (and any other stale registrations) so macOS
# doesn't keep showing an older build's icon, then register the installed one.
"$LSREGISTER" -u "$SRC" 2>/dev/null || true
"$LSREGISTER" -f -R "$DEST"
# Widget extension too, so the widget gallery picks up the new build.
pluginkit -a "$DEST/Contents/PlugIns/UpnextWidget.appex" 2>/dev/null || true
killall Dock 2>/dev/null || true
# Restart the widget service so it loads the new widget instead of a cached one.
killall chronod NotificationCenter 2>/dev/null || true

echo "==> Opening Upnext"
open "$DEST"
echo "Done. If System Settings › Storage still shows the old icon, quit System"
echo "Settings and run:  sudo rm -rf /Library/Caches/com.apple.iconservices.store && killall Dock"
