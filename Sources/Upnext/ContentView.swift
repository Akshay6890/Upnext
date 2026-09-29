import AppKit
import SwiftUI
import UpnextCore

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @State private var search = ""
    @State private var confirmQuit: ConfirmQuit?
    @State private var releaseNotesFor: AppModel.Row?
    @State private var showOtherApps = false

    struct ConfirmQuit: Identifiable {
        var id = UUID()
        var apps: [InstalledApp]
        var action: () -> Void
    }

    var body: some View {
        List {
            if model.updates.isEmpty && !model.isChecking && model.lastChecked != nil {
                allCaughtUp
            }
            section("Updates Available", rows: model.updates, style: .update)
            if model.isChecking && !model.pending.isEmpty {
                section("Checking…", rows: model.pending, style: .plain)
            }
            section("Skipped Versions", rows: model.ignoredUpdates, style: .ignored)
            section("Up to Date", rows: model.upToDate, style: .plain)
            section("Can't Check Automatically", rows: model.untracked, style: .untracked)
            if !model.managedElsewhere.isEmpty {
                Section {
                    DisclosureGroup(isExpanded: $showOtherApps) {
                        ForEach(filtered(model.managedElsewhere)) { row in
                            AppRow(row: row, style: .managed)
                        }
                    } label: {
                        Text("Updated elsewhere (App Store, Homebrew, Apple) — \(model.managedElsewhere.count)")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: false))
        .searchable(text: $search, placement: .toolbar, prompt: "Filter apps")
        .toolbar { toolbar }
        .safeAreaInset(edge: .bottom) { statusBar }
        .frame(minWidth: 560, minHeight: 420)
        .navigationTitle("Upnext")
        .navigationSubtitle(subtitle)
        .sheet(item: $releaseNotesFor) { row in
            ReleaseNotesView(row: row)
        }
        .confirmationDialog(
            quitTitle, isPresented: Binding(get: { confirmQuit != nil }, set: { if !$0 { confirmQuit = nil } }),
            presenting: confirmQuit
        ) { confirm in
            Button("Quit and Update") { confirm.action() }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Upnext will quit the app, install the update and reopen it. Save any open work first.")
        }
        .environment(\.showReleaseNotes, { releaseNotesFor = $0 })
        .environment(\.requestInstall, requestInstall)
    }

    // MARK: Pieces

    private var allCaughtUp: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.largeTitle)
                .foregroundStyle(.green)
            VStack(alignment: .leading) {
                Text("Everything is up to date").font(.headline)
                Text("Upnext checked \(model.checkableCount) apps.")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func section(_ title: String, rows: [AppModel.Row], style: AppRow.Style) -> some View {
        let visible = filtered(rows)
        if !visible.isEmpty {
            Section {
                ForEach(visible) { row in AppRow(row: row, style: style) }
            } header: {
                Text("\(title) (\(visible.count))")
            } footer: {
                if style == .untracked {
                    Text("These apps don't publish an update feed and aren't in the Homebrew catalog. "
                         + "Check the developer's website, or use the app's own “Check for Updates” menu.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func filtered(_ rows: [AppModel.Row]) -> [AppModel.Row] {
        guard !search.isEmpty else { return rows }
        return rows.filter { $0.app.name.localizedCaseInsensitiveContains(search) }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            if model.isChecking {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    Task { await model.refresh() }
                } label: {
                    Label("Check for Updates", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r")
                .help("Check for updates")
            }
        }
        ToolbarItem(placement: .primaryAction) {
            Button {
                requestInstallAll()
            } label: {
                Label("Update All", systemImage: "square.and.arrow.down.on.square")
            }
            .disabled(model.updates.isEmpty)
            .help("Install all available updates")
        }
    }

    private var statusBar: some View {
        HStack {
            if model.isChecking {
                Text("Checking \(model.checkedCount) of \(model.checkableCount) apps…")
            } else if let last = model.lastChecked {
                Text("Last checked \(last.formatted(.relative(presentation: .named)))")
            }
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
    }

    private var subtitle: String {
        let count = model.updates.count
        if count == 0 { return model.isChecking ? "Checking…" : "Up to date" }
        return count == 1 ? "1 update" : "\(count) updates"
    }

    private var quitTitle: String {
        guard let apps = confirmQuit?.apps else { return "" }
        if apps.count == 1 { return "\(apps[0].name) is open" }
        return "\(apps.count) apps are open"
    }

    // MARK: Actions

    private func requestInstall(_ row: AppModel.Row) {
        if model.isRunning(row) {
            confirmQuit = ConfirmQuit(apps: [row.app]) { model.install(row) }
        } else {
            model.install(row)
        }
    }

    private func requestInstallAll() {
        let running = model.runningAppsWithUpdates
        if running.isEmpty {
            model.installAll()
        } else {
            confirmQuit = ConfirmQuit(apps: running) { model.installAll() }
        }
    }
}

// MARK: - Row

struct AppRow: View {
    enum Style { case update, ignored, plain, untracked, managed }

    @EnvironmentObject var model: AppModel
    @Environment(\.showReleaseNotes) private var showReleaseNotes
    @Environment(\.requestInstall) private var requestInstall
    let row: AppModel.Row
    let style: Style

    var body: some View {
        HStack(spacing: 12) {
            AppIcon(url: row.app.url)
                .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(row.app.name).font(.body.weight(.medium))
                detail
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.vertical, 4)
        .contextMenu { menu }
    }

    @ViewBuilder
    private var detail: some View {
        switch row.result {
        case let .updateAvailable(update)?:
            HStack(spacing: 6) {
                Text("\(row.app.shortVersion.isEmpty ? row.app.buildVersion : row.app.shortVersion) → \(update.newVersion)")
                SourceBadge(source: update.source)
                if update.releaseNotesHTML != nil || update.releaseNotesURL != nil {
                    Button("Release Notes") { showReleaseNotes(row) }
                        .buttonStyle(.link)
                }
            }
        case let .managedElsewhere(by)?:
            Text("\(row.app.displayVersion) · \(by)")
        case let .failed(message)?:
            Text("\(row.app.displayVersion) · \(message)")
        case .upToDate(let source)?:
            HStack(spacing: 6) {
                Text(row.app.displayVersion)
                SourceBadge(source: source)
            }
        default:
            Text(row.app.displayVersion)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        switch model.installStates[row.id] {
        case let .working(phase)?:
            InstallProgress(phase: phase) { model.cancelInstall(row) }
        case let .installed(version)?:
            Label("Updated to \(version)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.callout)
        case .installerOpened?:
            Label("Finish in Installer", systemImage: "shippingbox")
                .font(.callout)
                .foregroundStyle(.secondary)
        case let .failed(message, needsAppManagement)?:
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help(message)
                if needsAppManagement {
                    Button("Open Settings") {
                        NSWorkspace.shared.open(URL(string:
                            "x-apple.systempreferences:com.apple.preference.security?Privacy_AppBundles")!)
                    }
                }
                Button("Retry") { requestInstall(row) }
            }
            .frame(maxWidth: 260, alignment: .trailing)
        case nil:
            switch style {
            case .update:
                Button("Update") { requestInstall(row) }
                    .buttonStyle(.borderedProminent)
            case .ignored:
                Button("Unskip") { model.unignore(bundleIdentifier: row.app.bundleIdentifier) }
            case .plain, .untracked, .managed:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private var menu: some View {
        if row.update != nil {
            Button("Update") { requestInstall(row) }
            if style == .ignored {
                Button("Stop Skipping This Version") { model.unignore(bundleIdentifier: row.app.bundleIdentifier) }
            } else {
                Button("Skip This Version") { model.ignore(row) }
            }
            Button("Release Notes") { showReleaseNotes(row) }
            if let url = row.update?.downloadURL {
                Button("Copy Download Link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                }
            }
            Divider()
        }
        if case let .failed(message, _)? = model.installStates[row.id] {
            Text(message)
            Button("Clear Error") { model.clearInstallState(row) }
            Divider()
        }
        Button("Open \(row.app.name)") {
            NSWorkspace.shared.openApplication(at: row.app.url, configuration: .init(), completionHandler: nil)
        }
        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([row.app.url])
        }
    }
}

struct SourceBadge: View {
    let source: AvailableUpdate.Source

    var body: some View {
        Text(source == .sparkle ? "Developer feed" : "Homebrew")
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Capsule().fill(Color.secondary.opacity(0.15)))
            .help(source == .sparkle
                  ? "Found through the update feed built into the app (Sparkle)."
                  : "Found through the Homebrew cask catalog.")
    }
}

struct InstallProgress: View {
    let phase: InstallPhase
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .trailing, spacing: 2) {
                if case let .downloading(fraction) = phase, fraction > 0 {
                    ProgressView(value: fraction).frame(width: 110)
                } else {
                    ProgressView().progressViewStyle(.linear).frame(width: 110)
                }
                Text(label).font(.caption2).foregroundStyle(.secondary)
            }
            if case .downloading = phase {
                Button(action: cancel) {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .help("Cancel")
            }
        }
    }

    private var label: String {
        switch phase {
        case let .downloading(f): return f > 0 ? "Downloading \(Int(f * 100))%" : "Downloading…"
        case .verifying: return "Verifying…"
        case .extracting: return "Unpacking…"
        case .waitingForAppToQuit: return "Quitting app…"
        case .installing: return "Installing…"
        }
    }
}

struct AppIcon: View {
    let url: URL

    var body: some View {
        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
            .resizable()
            .interpolation(.high)
    }
}

// MARK: - Environment plumbing

private struct ShowReleaseNotesKey: EnvironmentKey {
    static let defaultValue: (AppModel.Row) -> Void = { _ in }
}

private struct RequestInstallKey: EnvironmentKey {
    static let defaultValue: (AppModel.Row) -> Void = { _ in }
}

extension EnvironmentValues {
    var showReleaseNotes: (AppModel.Row) -> Void {
        get { self[ShowReleaseNotesKey.self] }
        set { self[ShowReleaseNotesKey.self] = newValue }
    }

    var requestInstall: (AppModel.Row) -> Void {
        get { self[RequestInstallKey.self] }
        set { self[RequestInstallKey.self] = newValue }
    }
}
