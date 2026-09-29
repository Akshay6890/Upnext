# Upnext

A native macOS app for Apple silicon. It finds updates for apps you installed
from the web (outside the Mac App Store) and installs them for you.

## What it does

1. **Scans** `/Applications` and `~/Applications`, including sub-folders such as
   `/Applications/Utilities`. It leaves out App Store apps, Apple's own apps and
   apps managed by Homebrew; those are updated by the App Store, macOS and
   `brew upgrade`.
2. **Checks each app** for a newer version:
   - **Developer feed (Sparkle).** Most website-distributed Mac apps name a
     Sparkle update feed (`SUFeedURL`) in their Info.plist. Upnext reads that
     feed the same way the app's own "Check for Updates…" does. It skips beta
     channels and builds that need a newer macOS.
   - **Homebrew catalog.** For apps without a feed, Upnext looks the app up in
     the public [Homebrew cask catalog](https://formulae.brew.sh/cask/). You
     don't need Homebrew installed. You can turn this off in Settings.
3. **Updates** with one click, or **Update All**:
   download → verify → quit the app if it's open → swap in the new version (the
   old one goes to the Trash) → reopen it. It handles `.dmg`, `.zip`, `.tar.*`
   and `.pkg` downloads. For a `.pkg`, macOS Installer opens so you can finish
   the install there.

### Safety checks before anything is replaced

- **Sparkle EdDSA signature.** If the app has a public key (`SUPublicEDKey`),
  the download must be signed with it. Sparkle enforces the same rule.
- **Checksum.** When the Homebrew catalog lists a sha256, the download must
  match it.
- **Same app.** The downloaded bundle must have the same bundle identifier as
  the installed app.
- **Same developer.** The new app's code signature must be valid, and it must
  be signed by the same Apple Developer Team ID as the installed copy.
- **Rollback.** If the swap fails halfway, the old version is put back.

Apps installed by an administrator (for example, through a `.pkg`) prompt for
your password. If macOS blocks the replacement, Upnext links you to
**System Settings › Privacy & Security › App Management**.

### Widget

Upnext includes a desktop and Notification Center widget in three sizes:

- **Small:** the number of updates, with the icons of the first few apps.
- **Medium and large:** the apps with updates and their versions (current → new),
  plus an **Update All** button.

Clicking **Update All** updates every app that isn't open, in the background.
If some apps are open, Upnext brings up its window and asks before quitting
them. Clicking anywhere else on the widget opens Upnext.

To add it, install and open Upnext once. Then right-click the desktop (or
open Notification Center), choose **Edit Widgets**, search for **Upnext** and
drag it into place. The widget refreshes whenever Upnext finishes a check or
an install, so keep Upnext running in the menu bar.

If Upnext doesn't appear in the widget gallery, open the app once from
`/Applications`, then run:

```sh
pluginkit -a /Applications/Upnext.app/Contents/PlugIns/UpnextWidget.appex
killall NotificationCenter chronod 2>/dev/null
```

### Other features

- Menu bar item with a count of available updates.
- Automatic background checks (every 1–24 h), with an optional notification.
- Skip a version you don't want. Unskip it from the list or from Settings.
- Release notes for each update.
- Option to open at login.

## Build & install

You need macOS 14 (Sonoma) or later on Apple silicon. The app builds with just
the Command Line Tools (`xcode-select --install`). The **widget needs Xcode**
(free from the App Store), because macOS only runs widgets built as a real
Xcode app extension. Without Xcode, the script builds the app and skips the
widget.

```sh
git clone https://github.com/akshay6890/upnext.git
cd upnext
scripts/build-app.sh          # → build/Upnext.app
rm -rf /Applications/Upnext.app && cp -R build/Upnext.app /Applications/
open /Applications/Upnext.app
```

`scripts/build-app.sh --dmg` also makes `build/Upnext.dmg`. Each push to GitHub
builds the DMG in Actions too, under the **Build** workflow's artifacts.

The build is ad-hoc signed. The first time you open it, macOS may say it can't
verify the developer. Right-click the app, choose **Open**, then confirm, or
allow it under System Settings › Privacy & Security. To sign with your own
Developer ID, run:

```sh
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" scripts/build-app.sh
```

### Development

```sh
swift build        # compile
swift test         # unit tests (version comparison, feed & catalog parsing)
swift run Upnext   # run without bundling (notifications and login item need the bundled app)
```

If a command fails with *"Could not initialize build system … Unknown error parsing
property list"*, your toolchain is using Xcode's build system. Add
`--build-system native` (e.g. `swift run --build-system native Upnext`) and
delete the `.build` folder once. `scripts/build-app.sh` does this automatically.

Or open `Package.swift` in Xcode and press ⌘R.

## Project layout

```
Package.swift
Sources/
  UpnextCore/            platform-independent logic (unit tested)
    Version.swift          Sparkle-compatible version comparison
    Appcast.swift          Sparkle appcast (RSS) parser
    HomebrewCatalog.swift  Homebrew cask API parser
    Models.swift           InstalledApp, AvailableUpdate, UpdateMatcher
    WidgetSnapshot.swift   data shared between the app and the widget
  UpnextWidget/          the WidgetKit widget, built by UpnextWidget.xcodeproj
  Upnext/                the macOS app
    UpnextApp.swift        app entry, menu bar extra
    AppModel.swift         state: scanning, checking, installing, skipping
    AppScanner.swift       finds and classifies installed apps
    UpdateChecker.swift    queries Sparkle feeds + Homebrew catalog
    Downloader.swift       download with progress
    Verification.swift     EdDSA, sha256, code-signature / Team ID checks
    Installer.swift        unpack dmg/zip/tar/pkg, quit, replace, relaunch
    WidgetPublisher.swift  writes the widget snapshot + icons, reloads the widget
    ContentView.swift      main window
    ReleaseNotesView.swift
    SettingsView.swift
UpnextWidget.xcodeproj   Xcode app-extension target for the widget
Design/AppIcon.svg       the app icon (scripts/make-icon.py renders it to Resources/AppIcon.png)
Resources/               Info.plists, widget entitlements, AppIcon.png
scripts/build-app.sh     builds and signs Upnext.app (and optionally a DMG)
```

## Limitations

- Apps that have no Sparkle feed and aren't in the Homebrew catalog appear
  under **Can't Check Automatically**. This includes many Electron apps, and
  apps with their own updaters such as Chrome, Office and Adobe apps. Use each
  app's own updater for those.
- Some apps number versions differently from their Homebrew cask. If you see a
  false "update available", use **Skip This Version**.
