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

        let cask = catalog?.cask(forAppNamed: app.bundleFileName, bundleIdentifier: app.bundleIdentifier)
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

        // Electron apps using electron-updater publish a latest-mac.yml manifest.
        var electronError: String?
        if let feed = app.electronFeed {
            switch await fetchElectronRelease(feed) {
            case let .success(release):
                if let update = UpdateMatcher.update(for: app, feed: feed, release: release) {
                    return .updateAvailable(update)
                }
                return .upToDate(source: .electron)
            case let .failure(message):
                electronError = message
            }
        }

        if let cask {
            if let update = UpdateMatcher.update(for: app, cask: cask) {
                return .updateAvailable(update)
            }
            return .upToDate(source: .homebrew)
        }

        if let sparkleError = sparkleError ?? electronError { return .failed(sparkleError) }
        return .untracked
    }

    private enum ElectronFetch {
        case success(ElectronRelease)
        case failure(String)
    }

    private nonisolated func fetchElectronRelease(_ feed: ElectronFeed) async -> ElectronFetch {
        var lastProblem = "The developer's update server didn't respond"
        for url in feed.manifestURLs {
            var request = URLRequest(url: url)
            request.setValue(ElectronFeed.userAgent, forHTTPHeaderField: "User-Agent")
            request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
            do {
                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 200
                guard (200..<300).contains(status) else {
                    lastProblem = Self.describe(status: status)
                    continue
                }
                if let release = ElectronRelease(manifestYAML: String(decoding: data, as: UTF8.self)) {
                    return .success(release)
                }
                lastProblem = "The developer's update server sent something unexpected"
            } catch let error as URLError {
                lastProblem = error.code == .notConnectedToInternet
                    ? "You're offline"
                    : "The developer's update server couldn't be reached"
            } catch {
                lastProblem = "The developer's update server couldn't be reached"
            }
        }
        return .failure(lastProblem)
    }

    private static func describe(status: Int) -> String {
        switch status {
        case 401, 403: return "The developer's update server only answers the app itself (HTTP \(status))"
        case 404: return "The developer doesn't publish update info at the expected address (HTTP 404)"
        default: return "The developer's update server returned an error (HTTP \(status))"
        }
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
