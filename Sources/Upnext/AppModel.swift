import AppKit
import Foundation
import UpnextCore
import UserNotifications

enum InstallState: Equatable {
    case working(InstallPhase)
    case installed(String)
    case installerOpened
    case failed(String, needsAppManagement: Bool)

    var isWorking: Bool {
        if case .working = self { return true }
        return false
    }
}

enum SettingsKey {
    static let useHomebrew = "useHomebrew"
    static let autoCheckHours = "autoCheckHours"
    static let notify = "notifyAboutUpdates"
    static let ignored = "ignoredVersions"
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var apps: [InstalledApp] = []
    @Published private(set) var results: [String: CheckResult] = [:]
    @Published private(set) var installStates: [String: InstallState] = [:]
    @Published private(set) var isChecking = false
    @Published private(set) var checkedCount = 0
    @Published private(set) var lastChecked: Date?
    /// bundle identifier → version the user chose to skip.
    @Published private(set) var ignoredVersions: [String: String]

    private let checker = UpdateChecker()
    private var autoCheckTask: Task<Void, Never>?
    private var installTasks: [String: Task<Void, Never>] = [:]
    private var notifiedVersions = Set<String>()

    init() {
        UserDefaults.standard.register(defaults: [
            SettingsKey.useHomebrew: true,
            SettingsKey.autoCheckHours: 6,
            SettingsKey.notify: true,
        ])
        ignoredVersions = UserDefaults.standard.dictionary(forKey: SettingsKey.ignored) as? [String: String] ?? [:]
        scheduleAutoCheck()
        Task { await refresh() }
    }

    // MARK: Derived lists

    struct Row: Identifiable {
        var app: InstalledApp
        var result: CheckResult?
        var id: String { app.id }

        var update: AvailableUpdate? {
            if case let .updateAvailable(update) = result { return update }
            return nil
        }
    }

    var updates: [Row] {
        rows.filter { row in
            guard let update = row.update else { return false }
            return ignoredVersions[row.app.bundleIdentifier] != update.newVersion
        }
    }

    var ignoredUpdates: [Row] {
        rows.filter { row in
            guard let update = row.update else { return false }
            return ignoredVersions[row.app.bundleIdentifier] == update.newVersion
        }
    }

    var upToDate: [Row] {
        rows.filter { if case .upToDate = $0.result { return true }; return false }
    }

    var untracked: [Row] {
        rows.filter { row in
            switch row.result {
            case .untracked?, .failed?: return true
            default: return false
            }
        }
    }

    var managedElsewhere: [Row] {
        rows.filter { if case .managedElsewhere = $0.result { return true }; return false }
    }

    /// Web apps still waiting for their check to finish.
    var pending: [Row] {
        rows.filter { $0.result == nil }
    }

    private var rows: [Row] {
        apps.map { Row(app: $0, result: results[$0.id]) }
    }

    var checkableCount: Int { apps.count }

    // MARK: Checking

    func refresh() async {
        guard !isChecking else { return }
        isChecking = true
        checkedCount = 0
        defer {
            isChecking = false
            lastChecked = Date()
        }

        let scanned = await Task.detached(priority: .userInitiated) { AppScanner.scan() }.value
        apps = scanned
        // Keep results for apps whose version didn't change, so the list doesn't flash.
        results = results.filter { key, _ in scanned.contains { $0.id == key } }
        let useHomebrew = UserDefaults.standard.bool(forKey: SettingsKey.useHomebrew)

        await checker.check(scanned, useHomebrew: useHomebrew) { app, result in
            await MainActor.run {
                self.results[app.id] = result
                self.checkedCount += 1
            }
        }
        notifyAboutNewUpdates()
    }

    /// Re-reads one app from disk after installing, and re-checks it.
    private func recheck(_ app: InstalledApp) async {
        guard let updated = InstalledApp.read(at: app.url, kind: { _ in app.kind }) else { return }
        if let index = apps.firstIndex(where: { $0.id == app.id }) { apps[index] = updated }
        let useHomebrew = UserDefaults.standard.bool(forKey: SettingsKey.useHomebrew)
        await checker.check([updated], useHomebrew: useHomebrew) { app, result in
            await MainActor.run { self.results[app.id] = result }
        }
    }

    func scheduleAutoCheck() {
        autoCheckTask?.cancel()
        let hours = UserDefaults.standard.integer(forKey: SettingsKey.autoCheckHours)
        guard hours > 0 else { return }
        autoCheckTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(hours) * 3_600 * 1_000_000_000)
                guard !Task.isCancelled else { return }
                await self?.refresh()
            }
        }
    }

    func homebrewSettingChanged() {
        Task {
            await checker.invalidateCatalog()
            await refresh()
        }
    }

    // MARK: Installing

    func install(_ row: Row) {
        guard let update = row.update, installStates[row.id]?.isWorking != true else { return }
        let app = row.app
        installStates[app.id] = .working(.downloading(0))

        installTasks[app.id] = Task {
            let installer = Installer(app: app, update: update) { phase in
                Task { @MainActor in
                    if self.installStates[app.id]?.isWorking == true {
                        self.installStates[app.id] = .working(phase)
                    }
                }
            }
            do {
                let outcome = try await installer.run()
                switch outcome {
                case .installed:
                    installStates[app.id] = .installed(update.newVersion)
                    await recheck(app)
                case .installerOpened:
                    installStates[app.id] = .installerOpened
                }
            } catch is CancellationError {
                installStates[app.id] = nil
            } catch let error as URLError where error.code == .cancelled {
                installStates[app.id] = nil
            } catch {
                let needsPermission = (error as? InstallError)?.needsAppManagementPermission ?? false
                installStates[app.id] = .failed(error.localizedDescription, needsAppManagement: needsPermission)
            }
            installTasks[app.id] = nil
        }
    }

    func installAll() {
        // One at a time keeps bandwidth and password prompts sane.
        let queue = updates.filter { installStates[$0.id]?.isWorking != true }
        Task {
            for row in queue {
                install(row)
                await installTasks[row.id]?.value
            }
        }
    }

    func cancelInstall(_ row: Row) {
        installTasks[row.id]?.cancel()
    }

    func clearInstallState(_ row: Row) {
        installStates[row.id] = nil
    }

    func isRunning(_ row: Row) -> Bool {
        RunningApps.isRunning(row.app)
    }

    var runningAppsWithUpdates: [InstalledApp] {
        updates.map(\.app).filter(RunningApps.isRunning)
    }

    // MARK: Ignoring

    func ignore(_ row: Row) {
        guard let update = row.update else { return }
        ignoredVersions[row.app.bundleIdentifier] = update.newVersion
        UserDefaults.standard.set(ignoredVersions, forKey: SettingsKey.ignored)
    }

    func unignore(bundleIdentifier: String) {
        ignoredVersions[bundleIdentifier] = nil
        UserDefaults.standard.set(ignoredVersions, forKey: SettingsKey.ignored)
    }

    // MARK: Notifications

    func requestNotificationPermission() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge]) { _, _ in }
    }

    private func notifyAboutNewUpdates() {
        let newOnes = updates.filter { row in
            guard let update = row.update else { return false }
            return notifiedVersions.insert("\(row.app.bundleIdentifier)@\(update.newVersion)").inserted
        }
        NSApp?.dockTile.badgeLabel = updates.isEmpty ? nil : "\(updates.count)"

        guard !newOnes.isEmpty,
              UserDefaults.standard.bool(forKey: SettingsKey.notify),
              Bundle.main.bundleIdentifier != nil,
              NSApp?.isActive != true else { return }

        let content = UNMutableNotificationContent()
        content.title = newOnes.count == 1
            ? "\(newOnes[0].app.name) \(newOnes[0].update?.newVersion ?? "") is available"
            : "\(newOnes.count) app updates available"
        content.body = newOnes.map(\.app.name).prefix(5).joined(separator: ", ")
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
