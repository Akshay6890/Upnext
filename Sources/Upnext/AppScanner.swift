import Foundation
import UpnextCore

/// Finds app bundles in the usual install locations and classifies them.
enum AppScanner {
    static var searchDirectories: [URL] {
        [
            URL(fileURLWithPath: "/Applications"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
        ]
    }

    static func scan() -> [InstalledApp] {
        var seen = Set<String>()
        var apps: [InstalledApp] = []
        for directory in searchDirectories {
            for url in appBundles(in: directory, depth: 2) {
                let path = url.resolvingSymlinksInPath().path
                guard seen.insert(path).inserted,
                      var app = InstalledApp.read(at: url, kind: classify) else { continue }
                if app.sparkleFeedURL == nil { app.sparkleFeedURL = feedFromPreferences(app.bundleIdentifier) }
                apps.append(app)
            }
        }
        return apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// App bundles directly in `directory`, plus those inside plain sub-folders
    /// (e.g. "/Applications/Utilities" or "/Applications/Adobe Photoshop 2025").
    private static func appBundles(in directory: URL, depth: Int) -> [URL] {
        let fm = FileManager.default
        guard depth > 0,
              let entries = try? fm.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]) else { return [] }

        var result: [URL] = []
        for entry in entries {
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true { continue }
            guard values?.isDirectory == true else { continue }
            if entry.pathExtension == "app" {
                result.append(entry)
            } else {
                result.append(contentsOf: appBundles(in: entry, depth: depth - 1))
            }
        }
        return result
    }

    /// Some apps set their Sparkle feed at runtime instead of in Info.plist;
    /// Sparkle then keeps it in the app's preferences.
    private static func feedFromPreferences(_ bundleID: String) -> URL? {
        guard let value = CFPreferencesCopyAppValue("SUFeedURL" as CFString, bundleID as CFString) as? String,
              let url = URL(string: value.trimmingCharacters(in: .whitespaces)),
              ["https", "http"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }

    private static func classify(_ app: InstalledApp) -> InstalledApp.Kind {
        let fm = FileManager.default
        if fm.fileExists(atPath: app.url.appendingPathComponent("Contents/_MASReceipt/receipt").path) {
            return .appStore
        }
        // iOS apps running on Apple silicon are wrapped and updated by the App Store.
        if fm.fileExists(atPath: app.url.appendingPathComponent("WrappedBundle").path) {
            return .appStore
        }
        if app.bundleIdentifier.hasPrefix("com.apple.") {
            return .apple
        }
        return .web
    }

    /// Homebrew keeps a Caskroom folder for every cask it installed.
    static func isManagedByHomebrew(caskToken: String) -> Bool {
        ["/opt/homebrew/Caskroom", "/usr/local/Caskroom"].contains { root in
            FileManager.default.fileExists(atPath: "\(root)/\(caskToken)")
        }
    }
}
