import Foundation

/// What the widget shows. The app writes it after every check or install;
/// the (sandboxed) widget only reads it.
public struct WidgetSnapshot: Codable, Equatable, Sendable {
    public struct Update: Codable, Equatable, Sendable, Identifiable {
        public var id: String { bundleIdentifier }
        public var name: String
        public var bundleIdentifier: String
        public var currentVersion: String
        public var newVersion: String
        public var isInstalling: Bool

        public init(name: String, bundleIdentifier: String, currentVersion: String,
                    newVersion: String, isInstalling: Bool = false) {
            self.name = name
            self.bundleIdentifier = bundleIdentifier
            self.currentVersion = currentVersion
            self.newVersion = newVersion
            self.isInstalling = isInstalling
        }
    }

    public var updates: [Update]
    public var appCount: Int
    public var isChecking: Bool
    public var lastChecked: Date?

    public init(updates: [Update], appCount: Int, isChecking: Bool, lastChecked: Date?) {
        self.updates = updates
        self.appCount = appCount
        self.isChecking = isChecking
        self.lastChecked = lastChecked
    }

    public static let placeholder = WidgetSnapshot(
        updates: [
            Update(name: "Visual Studio Code", bundleIdentifier: "a", currentVersion: "1.93", newVersion: "1.94"),
            Update(name: "Rectangle", bundleIdentifier: "b", currentVersion: "0.81", newVersion: "0.82"),
            Update(name: "Firefox", bundleIdentifier: "c", currentVersion: "130.0", newVersion: "131.0"),
        ],
        appCount: 42, isChecking: false, lastChecked: Date())
}

/// Where the snapshot lives: ~/Library/Application Support/Upnext/Widget.
/// The widget's sandbox has a read-only exception for this folder.
public enum WidgetStore {
    public static let widgetKind = "UpnextUpdates"
    public static let urlScheme = "upnext"
    public static let openURL = URL(string: "upnext://open")!
    public static let updateAllURL = URL(string: "upnext://update-all")!
    public static let refreshURL = URL(string: "upnext://refresh")!

    /// "Today at 9:41 AM", "Yesterday at 9:41 AM", or "Sep 28, 9:41 AM".
    /// A fixed string on purpose: a live relative timer ticks every second.
    public static func friendlyDate(_ date: Date, now: Date = Date(),
                                    calendar: Calendar = .current) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDate(date, inSameDayAs: now) { return "Today at \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) { return "Yesterday at \(time)" }
        let sameYear = calendar.component(.year, from: date) == calendar.component(.year, from: now)
        let day = sameYear
            ? date.formatted(.dateTime.month(.abbreviated).day())
            : date.formatted(.dateTime.month(.abbreviated).day().year())
        return "\(day), \(time)"
    }

    /// The real home folder, even from inside a sandbox (where NSHomeDirectory()
    /// points at the container).
    public static var realHomeDirectory: URL {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    public static var directory: URL {
        realHomeDirectory.appendingPathComponent("Library/Application Support/Upnext/Widget", isDirectory: true)
    }

    public static var snapshotFile: URL { directory.appendingPathComponent("snapshot.json") }

    public static func iconFile(for bundleIdentifier: String) -> URL {
        let safe = bundleIdentifier.replacingOccurrences(of: "/", with: "_")
        return directory.appendingPathComponent("icons/\(safe).png")
    }

    public static func load() -> WidgetSnapshot? {
        guard let data = try? Data(contentsOf: snapshotFile) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(WidgetSnapshot.self, from: data)
    }

    public static func save(_ snapshot: WidgetSnapshot) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(snapshot).write(to: snapshotFile, options: .atomic)
    }
}
