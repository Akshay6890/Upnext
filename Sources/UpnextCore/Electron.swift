import Foundation

/// Many Electron apps update themselves with electron-updater. They ship its
/// settings in Contents/Resources/app-update.yml, which says where the app's
/// release manifest (latest-mac.yml) lives: a plain web server, GitHub
/// Releases, or an S3 bucket.
public struct ElectronFeed: Equatable, Hashable, Sendable {
    public enum Provider: Equatable, Hashable, Sendable {
        case generic(URL)
        case github(owner: String, repo: String)
    }

    public var provider: Provider
    public var channel: String

    public init(provider: Provider, channel: String = "latest") {
        self.provider = provider
        self.channel = channel
    }

    public init?(appUpdateYAML: String) {
        let yaml = SimpleYAML.parse(appUpdateYAML)
        let fields = yaml.fields
        channel = fields["channel"].flatMap { $0.isEmpty ? nil : $0 } ?? "latest"

        switch fields["provider"] ?? "" {
        case "generic":
            // electron-builder allows ${os}/${arch}/${channel} placeholders in the URL.
            let channel = self.channel
            guard let raw = fields["url"]?
                    .replacingOccurrences(of: "${os}", with: "mac")
                    .replacingOccurrences(of: "${arch}", with: "arm64")
                    .replacingOccurrences(of: "${channel}", with: channel),
                  let url = URL(string: raw) else { return nil }
            provider = .generic(url)
        case "github":
            guard let owner = fields["owner"], let repo = fields["repo"] else { return nil }
            provider = .github(owner: owner, repo: repo)
        case "s3":
            guard let bucket = fields["bucket"] else { return nil }
            let path = fields["path"].map { "/" + $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) } ?? ""
            let host = fields["region"].map { "\(bucket).s3.\($0).amazonaws.com" } ?? "\(bucket).s3.amazonaws.com"
            guard let url = URL(string: "https://\(host)\(path)") else { return nil }
            provider = .generic(url)
        case "spaces":
            guard let name = fields["name"], let region = fields["region"] else { return nil }
            let path = fields["path"].map { "/" + $0.trimmingCharacters(in: CharacterSet(charactersIn: "/")) } ?? ""
            guard let url = URL(string: "https://\(name).\(region).digitaloceanspaces.com\(path)") else { return nil }
            provider = .generic(url)
        default:
            return nil
        }
    }

    /// Where latest-mac.yml lives.
    public var manifestURL: URL { manifestURLs[0] }

    /// Candidate manifest locations: the app's channel first, then the default
    /// "latest" channel (some apps name a channel that only exists for Windows).
    public var manifestURLs: [URL] {
        var names = ["\(channel)-mac.yml"]
        if channel != "latest" { names.append("latest-mac.yml") }
        return names.map { name in
            switch provider {
            case let .generic(base):
                return base.appendingPathComponent(name)
            case let .github(owner, repo):
                // GitHub redirects this to the newest release's asset; no API token needed.
                return URL(string: "https://github.com/\(owner)/\(repo)/releases/latest/download/\(name)")!
            }
        }
    }

    /// electron-updater identifies itself like this; some update servers and
    /// CDNs refuse other clients.
    public static let userAgent = "electron-builder"

    /// Resolves a file name from the manifest to a download URL.
    public func downloadURL(for file: String) -> URL? {
        if let absolute = URL(string: file), absolute.scheme != nil { return absolute }
        let escaped = file.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? file
        switch provider {
        case let .generic(base):
            let baseString = base.absoluteString.hasSuffix("/") ? base.absoluteString : base.absoluteString + "/"
            return URL(string: escaped, relativeTo: URL(string: baseString))?.absoluteURL
        case let .github(owner, repo):
            return URL(string: "https://github.com/\(owner)/\(repo)/releases/latest/download/\(escaped)")
        }
    }

    public var releaseNotesURL: URL? {
        if case let .github(owner, repo) = provider {
            return URL(string: "https://github.com/\(owner)/\(repo)/releases/latest")
        }
        return nil
    }
}

/// latest-mac.yml
public struct ElectronRelease: Equatable, Sendable {
    public struct File: Equatable, Sendable {
        public var url: String
        public var sha512: String?
        public var size: Int64?
    }

    public var version: String
    public var files: [File]
    public var releaseNotes: String?

    public init?(manifestYAML: String) {
        let yaml = SimpleYAML.parse(manifestYAML)
        guard let version = yaml.fields["version"], !version.isEmpty else { return nil }
        self.version = version
        releaseNotes = yaml.fields["releaseNotes"]
        files = yaml.list("files").compactMap { item in
            guard let url = item["url"] else { return nil }
            return File(url: url, sha512: item["sha512"], size: item["size"].flatMap { Int64($0) })
        }
        // Old manifests only have top-level path/sha512.
        if files.isEmpty, let path = yaml.fields["path"] {
            files = [File(url: path, sha512: yaml.fields["sha512"], size: nil)]
        }
    }

    /// The download to use on an Apple silicon Mac: an arm64 or universal build,
    /// preferring .zip (what electron-updater itself installs) over .dmg.
    public var bestFileForAppleSilicon: File? {
        func score(_ file: File) -> Int {
            let name = file.url.lowercased()
            var s = 0
            if name.contains("arm64") || name.contains("aarch64") { s += 20 }
            else if name.contains("universal") { s += 15 }
            else if name.contains("x64") || name.contains("x86_64") || name.contains("intel") { s -= 20 }
            if name.hasSuffix(".zip") { s += 5 } else if name.hasSuffix(".dmg") { s += 4 }
            else if name.hasSuffix(".pkg") { s += 1 } else { s -= 50 }
            if name.contains("blockmap") { s -= 100 }
            return s
        }
        return files.max { score($0) < score($1) }.flatMap { score($0) > -50 ? $0 : nil }
    }
}

/// Just enough YAML for electron-updater's files: top-level `key: value` pairs
/// and one level of lists of maps (`files:` / `- url: …`).
enum SimpleYAML {
    struct Document {
        var fields: [String: String] = [:]
        var lists: [String: [[String: String]]] = [:]
        func list(_ key: String) -> [[String: String]] { lists[key] ?? [] }
    }

    static func parse(_ text: String) -> Document {
        var doc = Document()
        var currentList: String?
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.replacingOccurrences(of: "\t", with: "  ")
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            let indented = line.first == " "

            if !indented {
                currentList = nil
                guard let pair = keyValue(trimmed) else { continue }
                let (key, value) = pair
                if value.isEmpty {
                    currentList = key
                    doc.lists[key] = []
                } else {
                    doc.fields[key] = value
                }
            } else if let list = currentList {
                var entry = trimmed
                if entry.hasPrefix("- ") {
                    doc.lists[list, default: []].append([:])
                    entry = String(entry.dropFirst(2))
                }
                guard let pair = keyValue(entry), let count = doc.lists[list]?.count, count > 0 else { continue }
                doc.lists[list]![count - 1][pair.0] = pair.1
            }
        }
        return doc
    }

    private static func keyValue(_ s: String) -> (String, String)? {
        guard let colon = s.firstIndex(of: ":") else { return nil }
        let key = s[..<colon].trimmingCharacters(in: .whitespaces)
        var value = s[s.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        if value.count >= 2, let first = value.first, first == value.last, first == "'" || first == "\"" {
            value = String(value.dropFirst().dropLast())
        }
        // Block scalars ("releaseNotes: |") span several lines; we don't need them.
        if ["|", ">", "|-", ">-", "|+", ">+"].contains(value) { value = "" }
        return key.isEmpty ? nil : (key, value)
    }
}

extension UpdateMatcher {
    public static func update(for app: InstalledApp, feed: ElectronFeed,
                              release: ElectronRelease) -> AvailableUpdate? {
        let current = app.shortVersion.isEmpty ? app.buildVersion : app.shortVersion
        let latest = release.version.hasPrefix("v") ? String(release.version.dropFirst()) : release.version
        guard !current.isEmpty, VersionComparator.isNewer(latest, than: current),
              let file = release.bestFileForAppleSilicon,
              let url = feed.downloadURL(for: file.url) else { return nil }
        return AvailableUpdate(
            newVersion: latest,
            downloadURL: url,
            expectedSHA512Base64: file.sha512,
            expectedLength: file.size,
            releaseNotesURL: feed.releaseNotesURL,
            source: .electron
        )
    }
}
