import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// One `<item>` from a Sparkle appcast feed.
public struct AppcastItem: Equatable, Sendable {
    public var title: String?
    /// Machine version, compared against the app's `CFBundleVersion`.
    public var version: String
    /// Human-readable version, compared against `CFBundleShortVersionString`.
    public var shortVersion: String?
    public var downloadURL: URL?
    public var length: Int64?
    /// Base64 EdDSA (ed25519) signature of the download, if the feed signs it.
    public var edSignature: String?
    public var releaseNotesURL: URL?
    public var descriptionHTML: String?
    public var minimumSystemVersion: String?
    public var channel: String?
    public var os: String?
    public var pubDate: String?
    public var isInformationalOnly: Bool

    public var displayVersion: String { shortVersion ?? version }
}

public enum AppcastParser {
    public static func parse(_ data: Data) -> [AppcastItem] {
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.delegate = delegate
        parser.parse()
        return delegate.items
    }

    /// Picks the newest item a Mac on `systemVersion` can install, skipping beta
    /// channels, other platforms and informational-only entries.
    public static func bestItem(in items: [AppcastItem], systemVersion: String) -> AppcastItem? {
        items
            .filter { $0.channel == nil || $0.channel?.isEmpty == true }
            .filter { $0.os == nil || $0.os == "macos" }
            .filter { !$0.isInformationalOnly && $0.downloadURL != nil }
            .filter { item in
                guard let min = item.minimumSystemVersion else { return true }
                return VersionComparator.compare(systemVersion, min) != .orderedAscending
            }
            .max { VersionComparator.compare($0.version, $1.version) == .orderedAscending }
    }

    private final class Delegate: NSObject, XMLParserDelegate {
        var items: [AppcastItem] = []
        private var current: AppcastItem?
        private var text = ""
        private var insideDeltas = false

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            text = ""
            if name == "item" {
                current = AppcastItem(version: "", isInformationalOnly: false)
                return
            }
            guard current != nil else { return }

            switch name {
            case "sparkle:deltas":
                insideDeltas = true
            case "enclosure" where !insideDeltas:
                // Some feeds carry several enclosures (one per OS); keep the macOS one.
                let os = attributes["sparkle:os"]
                if let os, os != "macos" { return }
                if let url = attributes["url"].flatMap(Self.url(from:)) {
                    current?.downloadURL = url
                }
                if let v = attributes["sparkle:version"], current?.version.isEmpty ?? true {
                    current?.version = v
                }
                if let v = attributes["sparkle:shortVersionString"], current?.shortVersion == nil {
                    current?.shortVersion = v
                }
                if let len = attributes["length"].flatMap({ Int64($0) }), len > 0 {
                    current?.length = len
                }
                if let sig = attributes["sparkle:edSignature"], !sig.isEmpty {
                    current?.edSignature = sig
                }
                if let os { current?.os = os }
            case "sparkle:informationalUpdate":
                current?.isInformationalOnly = true
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            text += string
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            text += String(decoding: CDATABlock, as: UTF8.self)
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
                    qualifiedName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            text = ""

            if name == "sparkle:deltas" {
                insideDeltas = false
                return
            }
            if name == "item" {
                if var item = current {
                    if item.version.isEmpty, let short = item.shortVersion { item.version = short }
                    if !item.version.isEmpty { items.append(item) }
                }
                current = nil
                return
            }
            guard current != nil, !value.isEmpty else { return }

            switch name {
            case "title": current?.title = value
            case "sparkle:version": current?.version = value
            case "sparkle:shortVersionString": current?.shortVersion = value
            case "sparkle:releaseNotesLink": current?.releaseNotesURL = Self.url(from: value)
            case "description": current?.descriptionHTML = value
            case "sparkle:minimumSystemVersion": current?.minimumSystemVersion = value
            case "sparkle:channel": current?.channel = value
            case "pubDate": current?.pubDate = value
            default: break
            }
        }

        private static func url(from string: String) -> URL? {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            if let url = URL(string: trimmed) { return url }
            // Some feeds have unescaped spaces in URLs.
            return trimmed
                .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
                .flatMap(URL.init(string:))
        }
    }
}
