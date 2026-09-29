import Foundation
import UpnextCore

/// The result of checking one app.
enum CheckResult: Hashable {
    case updateAvailable(AvailableUpdate)
    case upToDate(source: AvailableUpdate.Source)
    /// No Sparkle feed and no Homebrew cask we could match.
    case untracked
    /// Updated elsewhere (App Store, Homebrew, macOS); shown for reference only.
    case managedElsewhere(String)
    case failed(String)
}

actor UpdateChecker {
    private let session: URLSession
    private var catalog: HomebrewCatalog?
    private var catalogFetchedAt: Date?

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.httpAdditionalHeaders = ["User-Agent": "Upnext/1.0 Sparkle/2.6"]
        session = URLSession(configuration: config)
    }

    func check(_ apps: [InstalledApp], useHomebrew: Bool,
               progress: @escaping @Sendable (InstalledApp, CheckResult) async -> Void) async {
        let catalog = useHomebrew ? await loadCatalog() : nil

        await withTaskGroup(of: Void.self) { group in
            // Keep a handful of feed requests in flight at once.
            let maxConcurrent = 8
            var inFlight = 0
            for app in apps {
                if inFlight >= maxConcurrent {
                    _ = await group.next()
                    inFlight -= 1
                }
                group.addTask {
                    let result = await self.check(app, catalog: catalog)
                    await progress(app, result)
                }
                inFlight += 1
            }
        }
    }

    private nonisolated func check(_ app: InstalledApp, catalog: HomebrewCatalog?) async -> CheckResult {
        switch app.kind {
        case .appStore: return .managedElsewhere("App Store")
        case .apple: return .managedElsewhere("Apple")
        case .homebrewManaged: return .managedElsewhere("Homebrew")
        case .web: break
        }

        let cask = catalog?.cask(forAppNamed: app.bundleFileName)
        if let cask, AppScanner.isManagedByHomebrew(caskToken: cask.token) {
            return .managedElsewhere("Homebrew (brew upgrade --cask \(cask.token))")
        }

        var sparkleError: String?
        if let feed = app.sparkleFeedURL {
            do {
                let (data, response) = try await session.data(from: feed)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw URLError(.badServerResponse)
                }
                let items = AppcastParser.parse(data)
                if let best = AppcastParser.bestItem(in: items, systemVersion: Self.systemVersion) {
                    if let update = UpdateMatcher.update(for: app, appcastItem: best) {
                        return .updateAvailable(update)
                    }
                    return .upToDate(source: .sparkle)
                }
                sparkleError = "Feed has no usable entries"
            } catch {
                sparkleError = "Couldn't read update feed: \(error.localizedDescription)"
            }
        }

        if let cask {
            if let update = UpdateMatcher.update(for: app, cask: cask) {
                return .updateAvailable(update)
            }
            return .upToDate(source: .homebrew)
        }

        if let sparkleError { return .failed(sparkleError) }
        return .untracked
    }

    // MARK: Homebrew catalog

    private static let catalogURL = URL(string: "https://formulae.brew.sh/api/cask.json")!
    private static let catalogMaxAge: TimeInterval = 6 * 60 * 60

    private static var cacheFile: URL {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Upnext", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("cask.json")
    }

    private func loadCatalog() async -> HomebrewCatalog? {
        if let catalog, let at = catalogFetchedAt, Date().timeIntervalSince(at) < Self.catalogMaxAge {
            return catalog
        }

        let cache = Self.cacheFile
        let cacheDate = (try? cache.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
        var data: Data?
        if let cacheDate, Date().timeIntervalSince(cacheDate) < Self.catalogMaxAge {
            data = try? Data(contentsOf: cache)
        }
        if data == nil {
            var request = URLRequest(url: Self.catalogURL)
            request.timeoutInterval = 60
            if let fetched = try? await session.data(for: request),
               (fetched.1 as? HTTPURLResponse)?.statusCode == 200 {
                try? fetched.0.write(to: cache, options: .atomic)
                data = fetched.0
            } else {
                // Offline: a stale catalog beats none.
                data = try? Data(contentsOf: cache)
            }
        }

        guard let data,
              let parsed = try? HomebrewCatalog.parse(data, platformKey: Self.homebrewPlatformKey)
        else { return nil }
        catalog = parsed
        catalogFetchedAt = Date()
        return parsed
    }

    func invalidateCatalog() {
        catalogFetchedAt = nil
    }

    // MARK: System info

    static var systemVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
    }

    static var homebrewPlatformKey: String? {
        #if arch(arm64)
        let arm = true
        #else
        let arm = false
        #endif
        return HomebrewCatalog.platformKey(
            majorOSVersion: ProcessInfo.processInfo.operatingSystemVersion.majorVersion, arm64: arm)
    }
}
