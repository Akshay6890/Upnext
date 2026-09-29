import AppKit
import Foundation
import UpnextCore

enum InstallPhase: Equatable {
    case downloading(Double)
    case verifying
    case extracting
    case waitingForAppToQuit
    case installing
}

enum InstallOutcome {
    /// The app was replaced in place.
    case installed(relaunched: Bool)
    /// The update is a .pkg; macOS Installer was opened to finish it.
    case installerOpened
}

enum InstallError: LocalizedError {
    case payloadNotFound(String)
    case wrongBundle(expected: String, found: String)
    case appStillRunning(String)
    case appManagementDenied(String)
    case adminCancelled

    var errorDescription: String? {
        switch self {
        case let .payloadNotFound(name):
            return "The download doesn't contain \(name)."
        case let .wrongBundle(expected, found):
            return "The download contains a different app (\(found), expected \(expected))."
        case let .appStillRunning(name):
            return "\(name) didn't quit. Quit it and try again."
        case let .appManagementDenied(name):
            return "macOS blocked Upnext from replacing \(name). Allow Upnext under "
                + "System Settings › Privacy & Security › App Management, then try again."
        case .adminCancelled:
            return "Administrator authorization was cancelled."
        }
    }

    var needsAppManagementPermission: Bool {
        if case .appManagementDenied = self { return true }
        return false
    }
}

/// Downloads, verifies and installs an update for one app.
struct Installer {
    let app: InstalledApp
    let update: AvailableUpdate
    let phase: @Sendable (InstallPhase) -> Void

    func run() async throws -> InstallOutcome {
        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Upnext-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        let mounts = MountTracker()
        var keepWorkDir = false
        defer {
            if !keepWorkDir { try? FileManager.default.removeItem(at: workDir) }
        }

        do {
            let outcome = try await perform(workDir: workDir, mounts: mounts)
            if case .installerOpened = outcome { keepWorkDir = true }
            await mounts.detachAll()
            return outcome
        } catch {
            await mounts.detachAll()
            throw error
        }
    }

    private func perform(workDir: URL, mounts: MountTracker) async throws -> InstallOutcome {
        // 1. Download
        phase(.downloading(0))
        let downloadDir = workDir.appendingPathComponent("download", isDirectory: true)
        try FileManager.default.createDirectory(at: downloadDir, withIntermediateDirectories: true)
        let report = self.phase
        let file = try await Downloader(destinationDirectory: downloadDir) { fraction in
            report(.downloading(fraction))
        }.download(update.downloadURL)
        try Task.checkCancellation()

        // 2. Verify the archive itself
        phase(.verifying)
        try Verification.checkSize(of: file, expected: update.expectedLength)
        try Verification.checkSHA256(of: file, expected: update.expectedSHA256)
        if update.source == .sparkle {
            try Verification.checkSparkleSignature(
                of: file, signature: update.edSignature, publicKey: app.sparklePublicEDKey)
        }

        // 3. Unpack and find the new app (or installer package)
        phase(.extracting)
        let payload = try await Archive.findPayload(in: file, for: app, workDir: workDir, mounts: mounts)

        switch payload {
        case let .package(pkg):
            // Copy out of any mounted disk image so it survives the detach.
            let kept = workDir.appendingPathComponent(pkg.lastPathComponent)
            if pkg.deletingLastPathComponent() != workDir {
                try? FileManager.default.removeItem(at: kept)
                try await Shell.run("/usr/bin/ditto", [pkg.path, kept.path])
            }
            _ = await MainActor.run { NSWorkspace.shared.open(kept) }
            return .installerOpened

        case let .app(newBundle):
            try Verification.checkCodeSignature(newBundle: newBundle, replacing: app.url)

            // 4. Quit the running copy, swap bundles, relaunch.
            phase(.waitingForAppToQuit)
            let wasRunning = try await RunningApps.quit(app)

            phase(.installing)
            try await BundleReplacer.replace(app.url, with: newBundle, appName: app.name)

            if wasRunning {
                let config = NSWorkspace.OpenConfiguration()
                config.activates = false
                _ = try? await NSWorkspace.shared.openApplication(at: app.url, configuration: config)
            }
            return .installed(relaunched: wasRunning)
        }
    }
}

// MARK: - Archives

enum Payload {
    case app(URL)
    case package(URL)
}

enum Archive {
    enum Kind { case dmg, zip, tar, pkg }

    static func findPayload(in file: URL, for app: InstalledApp, workDir: URL,
                            mounts: MountTracker, depth: Int = 0) async throws -> Payload {
        let kind = try detectKind(of: file)
        if kind == .pkg { return .package(file) }

        let root: URL
        switch kind {
        case .dmg:
            root = try await mounts.attach(file)
        case .zip, .tar:
            root = workDir.appendingPathComponent("extracted-\(depth)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            if kind == .zip {
                try await Shell.run("/usr/bin/ditto", ["-x", "-k", file.path, root.path])
            } else {
                try await Shell.run("/usr/bin/tar", ["-xf", file.path, "-C", root.path])
            }
        case .pkg:
            fatalError("handled above")
        }

        let found = scan(root, depth: 3)
        let bundles = found.apps.compactMap { url in InstalledApp.read(at: url).map { (url, $0) } }

        if let match = bundles.first(where: { $0.1.bundleIdentifier == app.bundleIdentifier }) {
            return .app(match.0)
        }
        if let pkg = found.packages.first {
            return .package(pkg)
        }
        // Archives nested in archives, e.g. a .dmg inside a .zip.
        if depth == 0, let inner = found.archives.first {
            return try await findPayload(in: inner, for: app, workDir: workDir, mounts: mounts, depth: 1)
        }
        if let other = bundles.first {
            throw InstallError.wrongBundle(expected: app.bundleIdentifier, found: other.1.bundleIdentifier)
        }
        throw InstallError.payloadNotFound(app.bundleFileName)
    }

    private static func scan(_ dir: URL, depth: Int) -> (apps: [URL], packages: [URL], archives: [URL]) {
        var apps: [URL] = [], packages: [URL] = [], archives: [URL] = []
        guard depth > 0,
              let entries = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles]) else { return ([], [], []) }

        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            // Skips the "Applications" shortcut most disk images include.
            if values?.isSymbolicLink == true { continue }
            let ext = entry.pathExtension.lowercased()
            if ext == "app" {
                apps.append(entry)
            } else if ext == "pkg" || ext == "mpkg" {
                packages.append(entry)
            } else if ["dmg", "zip"].contains(ext) {
                archives.append(entry)
            } else if values?.isDirectory == true, !entry.lastPathComponent.hasPrefix("__MACOSX") {
                let nested = scan(entry, depth: depth - 1)
                apps += nested.apps
                packages += nested.packages
                archives += nested.archives
            }
        }
        return (apps, packages, archives)
    }

    static func detectKind(of file: URL) throws -> Kind {
        let name = file.lastPathComponent.lowercased()
        if name.hasSuffix(".dmg") { return .dmg }
        if name.hasSuffix(".zip") { return .zip }
        if name.hasSuffix(".pkg") || name.hasSuffix(".mpkg") { return .pkg }
        if [".tar", ".tar.gz", ".tgz", ".tar.bz2", ".tbz", ".tbz2", ".tar.xz", ".txz"]
            .contains(where: { name.hasSuffix($0) }) { return .tar }

        // No useful extension (e.g. a redirect URL): sniff the header.
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let headerData = try handle.read(upToCount: 6) ?? Data()
        let header = [UInt8](headerData)
        if header.starts(with: [0x50, 0x4B, 0x03, 0x04]) { return .zip }
        if header.starts(with: Array("xar!".utf8)) { return .pkg }
        if header.starts(with: [0x1F, 0x8B]) || header.starts(with: Array("BZh".utf8))
            || header.starts(with: [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]) { return .tar }
        return .dmg
    }
}

/// Mounts disk images and makes sure they get detached again.
actor MountTracker {
    private var mountPoints: [URL] = []

    func attach(_ image: URL) async throws -> URL {
        let mountRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("Upnext-mount-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: mountRoot, withIntermediateDirectories: true)

        // "Y" accepts a license agreement if the image shows one.
        let result = try await Shell.run("/usr/bin/hdiutil", [
            "attach", image.path, "-nobrowse", "-noautoopen", "-readonly", "-noverify",
            "-mountroot", mountRoot.path, "-plist",
        ], input: "Y\n")

        // Any license text is printed before the plist.
        let output = result.stdout
        let start = output.range(of: Data("<?xml".utf8))?.lowerBound ?? output.startIndex
        guard let plist = try? PropertyListSerialization.propertyList(
                from: output.subdata(in: start..<output.endIndex), format: nil) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]],
              let path = entities.compactMap({ $0["mount-point"] as? String }).first else {
            throw InstallError.payloadNotFound("a readable disk image")
        }
        let mountPoint = URL(fileURLWithPath: path, isDirectory: true)
        mountPoints.append(mountPoint)
        return mountPoint
    }

    func detachAll() async {
        for mount in mountPoints.reversed() {
            _ = try? await Shell.run("/usr/bin/hdiutil", ["detach", mount.path, "-force"], allowFailure: true)
            try? FileManager.default.removeItem(at: mount.deletingLastPathComponent())
        }
        mountPoints.removeAll()
    }
}

// MARK: - Running apps

enum RunningApps {
    static func instances(of app: InstalledApp) -> [NSRunningApplication] {
        let target = app.url.resolvingSymlinksInPath().standardizedFileURL.path
        return NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleIdentifier)
            .filter { $0.bundleURL?.resolvingSymlinksInPath().standardizedFileURL.path == target }
    }

    static func isRunning(_ app: InstalledApp) -> Bool {
        !instances(of: app).isEmpty
    }

    /// Asks the app to quit (as if the user chose Quit). Returns whether it was running.
    @MainActor
    static func quit(_ app: InstalledApp) async throws -> Bool {
        let running = instances(of: app)
        guard !running.isEmpty else { return false }
        running.forEach { $0.terminate() }
        // Give it up to 15 seconds (it may be asking to save documents).
        var waited = 0
        while !running.allSatisfy(\.isTerminated), waited < 75 {
            try await Task.sleep(nanoseconds: 200_000_000)
            waited += 1
        }
        guard running.allSatisfy(\.isTerminated) else {
            throw InstallError.appStillRunning(app.name)
        }
        return true
    }
}

// MARK: - Replacing the bundle

enum BundleReplacer {
    static func replace(_ old: URL, with new: URL, appName: String) async throws {
        let fm = FileManager.default
        let parent = old.deletingLastPathComponent()
        let canWrite = fm.isWritableFile(atPath: parent.path) && fm.isWritableFile(atPath: old.path)
        if !canWrite {
            try await replaceAsAdmin(old, with: new)
            return
        }

        let staged = parent.appendingPathComponent(".upnext-\(UUID().uuidString).app")
        do {
            // ditto keeps symlinks, permissions, extended attributes and signatures intact.
            try await Shell.run("/usr/bin/ditto", [new.path, staged.path])
        } catch {
            try? fm.removeItem(at: staged)
            if isPermissionFailure(error) { throw InstallError.appManagementDenied(appName) }
            throw error
        }

        var trashed: NSURL?
        do {
            try fm.trashItem(at: old, resultingItemURL: &trashed)
        } catch {
            try? fm.removeItem(at: staged)
            if isPermissionFailure(error) { throw InstallError.appManagementDenied(appName) }
            throw error
        }

        do {
            try fm.moveItem(at: staged, to: old)
        } catch {
            // Put the old version back rather than leaving the user with nothing.
            if let trashed = trashed as URL? { try? fm.moveItem(at: trashed, to: old) }
            try? fm.removeItem(at: staged)
            throw error
        }
    }

    /// For apps installed by root (e.g. via a .pkg), asks for an administrator password.
    private static func replaceAsAdmin(_ old: URL, with new: URL) async throws {
        let staged = old.deletingLastPathComponent()
            .appendingPathComponent(".upnext-\(UUID().uuidString).app")
        let attrs = try? FileManager.default.attributesOfItem(atPath: old.path)
        let owner = (attrs?[.ownerAccountID] as? NSNumber)?.stringValue ?? "0"
        let group = (attrs?[.groupOwnerAccountID] as? NSNumber)?.stringValue ?? "80"

        let script = [
            "/usr/bin/ditto \(shellQuote(new.path)) \(shellQuote(staged.path))",
            "/usr/sbin/chown -R \(owner):\(group) \(shellQuote(staged.path))",
            "/bin/rm -rf \(shellQuote(old.path))",
            "/bin/mv \(shellQuote(staged.path)) \(shellQuote(old.path))",
        ].joined(separator: " && ")

        let source = "do shell script \"\(appleScriptEscape(script))\" with administrator privileges"
        let failure: (code: Int, message: String)? = await MainActor.run {
            var info: NSDictionary?
            NSAppleScript(source: source)?.executeAndReturnError(&info)
            guard let info else { return nil }
            return (info[NSAppleScript.errorNumber] as? Int ?? 0,
                    info[NSAppleScript.errorMessage] as? String ?? "Unknown error")
        }
        if let failure {
            if failure.code == -128 { throw InstallError.adminCancelled }
            throw NSError(domain: "Upnext", code: failure.code,
                          userInfo: [NSLocalizedDescriptionKey: failure.message])
        }
    }

    private static func isPermissionFailure(_ error: Error) -> Bool {
        if let shell = error as? Shell.Failure {
            return shell.result.stderr.contains("Operation not permitted")
        }
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain,
           [NSFileWriteNoPermissionError, NSFileReadNoPermissionError].contains(ns.code) { return true }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain,
           [Int(EPERM), Int(EACCES)].contains(underlying.code) { return true }
        return ns.domain == NSPOSIXErrorDomain && [Int(EPERM), Int(EACCES)].contains(ns.code)
    }

    private static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func appleScriptEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}
