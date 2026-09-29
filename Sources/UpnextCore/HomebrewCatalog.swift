import Foundation

/// A cask entry from https://formulae.brew.sh/api/cask.json, reduced to what
/// Upnext needs. Used as a fallback source of "latest version + download URL"
/// for apps that don't publish a Sparkle feed.
public struct HomebrewCask: Equatable, Sendable {
    public var token: String
    public var name: String
    /// Full cask version, e.g. "4.2.1,1234".
    public var version: String
    public var downloadURL: URL
    /// nil when the cask uses `sha256 :no_check`.
    public var sha256: String?
    public var homepage: URL?
    /// App bundle names this cask installs, e.g. ["Visual Studio Code.app"].
    public var appNames: [String]
    /// True when the cask ships a .pkg rather than an .app to drag in.
    public var installsPkg: Bool

    /// The human-facing part of the version ("4.2.1" for "4.2.1,1234").
    public var displayVersion: String {
        String(version.split(separator: ",").first ?? Substring(version))
    }
}

public struct HomebrewCatalog: Sendable {
    public private(set) var casksByAppName: [String: HomebrewCask] = [:]

    public init(casks: [HomebrewCask]) {
        for cask in casks {
            for app in cask.appNames {
                let key = app.lowercased()
                // Prefer the plain cask over variants like "foo@beta".
                if let existing = casksByAppName[key], !existing.token.contains("@") { continue }
                casksByAppName[key] = cask
            }
        }
    }

    public func cask(forAppNamed bundleName: String) -> HomebrewCask? {
        casksByAppName[bundleName.lowercased()]
    }

    /// Parses the Homebrew cask API JSON. `platformKey` selects a variation
    /// such as "arm64_sequoia" when the cask ships different builds per platform.
    public static func parse(_ data: Data, platformKey: String?) throws -> HomebrewCatalog {
        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        let casks = array.compactMap { parseCask($0, platformKey: platformKey) }
        return HomebrewCatalog(casks: casks)
    }

    static func parseCask(_ json: [String: Any], platformKey: String?) -> HomebrewCask? {
        guard let token = json["token"] as? String else { return nil }
        if json["disabled"] as? Bool == true { return nil }

        var fields = json
        if let platformKey,
           let variations = json["variations"] as? [String: Any],
           let variation = variations[platformKey] as? [String: Any] {
            fields.merge(variation) { _, new in new }
        }

        guard let version = fields["version"] as? String, version != "latest",
              let urlString = fields["url"] as? String,
              let url = URL(string: urlString) else { return nil }

        var appNames: [String] = []
        var installsPkg = false
        for artifact in fields["artifacts"] as? [[String: Any]] ?? [] {
            if let apps = artifact["app"] as? [Any] {
                appNames.append(contentsOf: appBundleNames(from: apps))
            }
            if artifact["pkg"] != nil { installsPkg = true }
        }
        guard !appNames.isEmpty || installsPkg else { return nil }

        let sha = fields["sha256"] as? String
        return HomebrewCask(
            token: token,
            name: (json["name"] as? [String])?.first ?? token,
            version: version,
            downloadURL: url,
            sha256: (sha == nil || sha == "no_check") ? nil : sha,
            homepage: (json["homepage"] as? String).flatMap(URL.init(string:)),
            appNames: appNames,
            installsPkg: installsPkg
        )
    }

    /// `"app": ["Foo.app"]` or `"app": ["Foo.app", {"target": "Bar.app"}]`.
    private static func appBundleNames(from entries: [Any]) -> [String] {
        var names: [String] = []
        for entry in entries {
            if let source = entry as? String, source.hasSuffix(".app") {
                names.append((source as NSString).lastPathComponent)
            } else if let options = entry as? [String: Any],
                      let target = options["target"] as? String,
                      !names.isEmpty {
                names[names.count - 1] = (target as NSString).lastPathComponent
            }
        }
        return names
    }

    /// Homebrew's variation key for this Mac, e.g. "arm64_sequoia".
    public static func platformKey(majorOSVersion: Int, arm64: Bool) -> String? {
        let names = [11: "big_sur", 12: "monterey", 13: "ventura", 14: "sonoma",
                     15: "sequoia", 26: "tahoe"]
        guard let name = names[majorOSVersion] else { return nil }
        return arm64 ? "arm64_\(name)" : name
    }
}
