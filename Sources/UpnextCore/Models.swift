import Foundation

/// An app bundle found in /Applications or ~/Applications.
public struct InstalledApp: Identifiable, Hashable, Sendable {
    public var id: String { url.path }
    public var url: URL
    public var name: String
    public var bundleIdentifier: String
    /// CFBundleShortVersionString (what users see).
    public var shortVersion: String
    /// CFBundleVersion (build number; Sparkle compares against this).
    public var buildVersion: String
    public var sparkleFeedURL: URL?
    /// Base64 ed25519 public key (SUPublicEDKey) the app uses to verify Sparkle updates.
    public var sparklePublicEDKey: String?
    /// electron-updater config (Contents/Resources/app-update.yml), if the app has one.
    public var electronFeed: ElectronFeed?
    public var kind: Kind

    public enum Kind: String, Sendable {
        /// Downloaded from a website (or anywhere that isn't the App Store).
        case web
        /// Has a Mac App Store receipt — the App Store updates these.
        case appStore
        /// Installed through `brew install --cask`; `brew upgrade` owns it.
        case homebrewManaged
        /// Ships with macOS or is made by Apple.
        case apple
    }

    public var bundleFileName: String { url.lastPathComponent }

    public var displayVersion: String {
        if shortVersion.isEmpty { return buildVersion }
        if buildVersion.isEmpty || buildVersion == shortVersion { return shortVersion }
        return "\(shortVersion) (\(buildVersion))"
    }

    public init(url: URL, name: String, bundleIdentifier: String, shortVersion: String,
                buildVersion: String, sparkleFeedURL: URL?, sparklePublicEDKey: String? = nil,
                kind: Kind) {
        self.url = url
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.shortVersion = shortVersion
        self.buildVersion = buildVersion
        self.sparkleFeedURL = sparkleFeedURL
        self.sparklePublicEDKey = sparklePublicEDKey
        self.kind = kind
    }

    /// Reads the app's Info.plist. Returns nil for anything that isn't a readable app bundle.
    public static func read(at url: URL, kind: (InstalledApp) -> Kind = { _ in .web }) -> InstalledApp? {
        let plistURL = url.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let bundleID = plist["CFBundleIdentifier"] as? String else { return nil }

        let name = (plist["CFBundleDisplayName"] as? String)
            ?? (plist["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent
        let feed = (plist["SUFeedURL"] as? String)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .flatMap(URL.init(string:))
            .flatMap { ["https", "http"].contains($0.scheme?.lowercased() ?? "") ? $0 : nil }

        var app = InstalledApp(
            url: url,
            name: name,
            bundleIdentifier: bundleID,
            shortVersion: stringValue(plist["CFBundleShortVersionString"]),
            buildVersion: stringValue(plist["CFBundleVersion"]),
            sparkleFeedURL: feed,
            sparklePublicEDKey: (plist["SUPublicEDKey"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            kind: .web
        )
        if let yml = try? String(contentsOf: url.appendingPathComponent("Contents/Resources/app-update.yml"),
                                 encoding: .utf8) {
            app.electronFeed = ElectronFeed(appUpdateYAML: yml)
        }
        app.kind = kind(app)
        return app
    }

    private static func stringValue(_ value: Any?) -> String {
        switch value {
        case let s as String: return s.trimmingCharacters(in: .whitespaces)
        case let n as NSNumber: return n.stringValue
        default: return ""
        }
    }
}

/// A newer version of an installed app, and where to get it.
public struct AvailableUpdate: Hashable, Sendable {
    public enum Source: String, Sendable {
        case sparkle = "Sparkle feed"
        case electron = "Electron update server"
        case homebrew = "Homebrew catalog"

        /// Published by the app's own developer (vs. a third-party catalog).
        public var isFromDeveloper: Bool { self != .homebrew }
    }

    public var newVersion: String
    public var downloadURL: URL
    public var expectedSHA256: String?
    /// Base64 SHA-512 (what electron-updater publishes).
    public var expectedSHA512Base64: String?
    public var expectedLength: Int64?
    public var edSignature: String?
    public var releaseNotesURL: URL?
    public var releaseNotesHTML: String?
    public var source: Source

    public init(newVersion: String, downloadURL: URL, expectedSHA256: String? = nil,
                expectedSHA512Base64: String? = nil, expectedLength: Int64? = nil, edSignature: String? = nil, releaseNotesURL: URL? = nil,
                releaseNotesHTML: String? = nil, source: Source) {
        self.newVersion = newVersion
        self.downloadURL = downloadURL
        self.expectedSHA256 = expectedSHA256
        self.expectedSHA512Base64 = expectedSHA512Base64
        self.expectedLength = expectedLength
        self.edSignature = edSignature
        self.releaseNotesURL = releaseNotesURL
        self.releaseNotesHTML = releaseNotesHTML
        self.source = source
    }
}

/// Decides whether a feed/catalog entry is an update for an installed app.
public enum UpdateMatcher {
    public static func update(for app: InstalledApp, appcastItem item: AppcastItem) -> AvailableUpdate? {
        guard let url = item.downloadURL else { return nil }
        // Sparkle compares sparkle:version with CFBundleVersion.
        let current = app.buildVersion.isEmpty ? app.shortVersion : app.buildVersion
        guard VersionComparator.isNewer(item.version, than: current) else { return nil }
        return AvailableUpdate(
            newVersion: item.displayVersion,
            downloadURL: url,
            expectedLength: item.length,
            edSignature: item.edSignature,
            releaseNotesURL: item.releaseNotesURL,
            releaseNotesHTML: item.descriptionHTML,
            source: .sparkle
        )
    }

    public static func update(for app: InstalledApp, cask: HomebrewCask) -> AvailableUpdate? {
        let current = app.shortVersion.isEmpty ? app.buildVersion : app.shortVersion
        guard !current.isEmpty else { return nil }
        let candidate = cask.displayVersion
        // Casks often decorate the version with build hashes or suffixes
        // ("3.6.6-8b85519e" for an app that reports "3.6.6"). Only a newer
        // *numeric* version counts as an update.
        if let candidateCore = VersionComparator.numericCore(candidate),
           let currentCore = VersionComparator.numericCore(current) {
            guard VersionComparator.isNewer(candidateCore, than: currentCore) else { return nil }
        } else {
            guard VersionComparator.isNewer(candidate, than: current) else { return nil }
        }
        // Some casks version by build number instead ("12345" vs app "1.2"), or put
        // the build after a comma ("1.2,12345"). Either matching the installed build
        // means the app is current.
        if !app.buildVersion.isEmpty {
            let parts = cask.version.split(separator: ",").map(String.init)
            if parts.contains(where: { VersionComparator.compare($0, app.buildVersion) == .orderedSame }) {
                return nil
            }
        }
        return AvailableUpdate(
            newVersion: candidate,
            downloadURL: cask.downloadURL,
            expectedSHA256: cask.sha256,
            releaseNotesURL: cask.homepage,
            source: .homebrew
        )
    }
}
