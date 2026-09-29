import AppKit
import SwiftUI
import UpnextCore

/// Window-level UI state. Kept in an ObservableObject instead of `@State`
/// because newer SDKs implement `@State` as a macro, and plain `swift build`
/// can't always find SwiftUI's macro plugin.
@MainActor
final class WindowState: ObservableObject {
    static let shared = WindowState()

    @Published var search = ""
    @Published var confirmQuit: ConfirmQuit?
    @Published var releaseNotesFor: AppModel.Row?
    @Published var showOtherApps = false

    struct ConfirmQuit: Identifiable {
        var id = UUID()
        var apps: [InstalledApp]
        var action: () -> Void
    }
}

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var state: WindowState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if model.updates.isEmpty && !model.isChecking && model.lastChecked != nil {
                    allCaughtUp
                }
                section("Updates Available", rows: model.updates, style: .update)
                if model.isChecking && !model.pending.isEmpty {
                    section("Checking", rows: model.pending, style: .plain)
                }
                section("Skipped Versions", rows: model.ignoredUpdates, style: .ignored)
                section("Up to Date", rows: model.upToDate, style: .plain)
                section("Can't Check Automatically", rows: model.untracked, style: .untracked)
                managedElsewhereSection
            }
            .padding(.horizontal, 22)
            .padding(.top, 6)
            .padding(.bottom, 22)
        }
        .scrollContentBackground(.hidden)
        .background(GlassBackground())
        .background(TransparentWindow())
        .searchable(text: $state.search, placement: .toolbar, prompt: "Filter apps")
        .toolbar { toolbar }
        .toolbar(removing: .title)
        .toolbarBackground(.hidden, for: .windowToolbar)
        .frame(minWidth: 580, minHeight: 440)
        .navigationTitle("Upnext")
        .fontDesign(.rounded)
        .tint(Brand.blue)
        .preferredColorScheme(.dark)
        .sheet(item: $state.releaseNotesFor) { row in
            ReleaseNotesView(row: row)
                .fontDesign(.rounded)
                .tint(Brand.blue)
                .preferredColorScheme(.dark)
        }
        .confirmationDialog(
            quitTitle, isPresented: quitDialogShown,
            presenting: state.confirmQuit
        ) { confirm in
            Button("Quit and Update") { confirm.action() }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Upnext will quit the app, install the update and reopen it. Save any open work first.")
        }
        .environment(\.showReleaseNotes, { [state] row in state.releaseNotesFor = row })
        .environment(\.requestInstall, requestInstall)
        .onAppear { WindowOpener.action = openWindow }
    }

    // MARK: Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                AppLogo(size: 38)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Upnext")
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                    Text(statusLine)
                        .font(.system(.callout, design: .rounded))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            if model.isChecking {
                ProgressView(value: Double(model.checkedCount),
                             total: Double(max(model.checkableCount, 1)))
                    .progressViewStyle(.linear)
                    .tint(Brand.blue)
            }
        }
    }

    private var statusLine: String {
        if model.isChecking {
            return "Checking \(model.checkedCount) of \(model.checkableCount) apps…"
        }
        let count = model.updates.count
        let updates = count == 0 ? "Everything is up to date"
            : count == 1 ? "1 update ready" : "\(count) updates ready"
        if let last = model.lastChecked {
            return "\(updates) · checked \(last.formatted(.relative(presentation: .named)))"
        }
        return updates
    }

    private var allCaughtUp: some View {
        GlassCard {
            HStack(spacing: 14) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(Brand.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("You're all set").font(.system(.headline, design: .rounded))
                    Text("Upnext checked \(model.checkableCount) apps.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(16)
        }
    }

    @ViewBuilder
    private func section(_ title: String, rows: [AppModel.Row], style: AppRow.Style) -> some View {
        let visible = filtered(rows)
        if !visible.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    SectionTitle(title: title, count: visible.count)
                    Spacer()
                    if style == .update {
                        updateAllButton
                    }
                }
                .padding(.horizontal, 4)

                GlassCard {
                    ForEach(Array(visible.enumerated()), id: \.element.id) { index, row in
                        AppRow(row: row, style: style)
                        if index < visible.count - 1 {
                            Rectangle().fill(Brand.hairline).frame(height: 1).padding(.leading, 64)
                        }
                    }
                }

                if style == .untracked {
                    Text("These apps don't publish update information Upnext can read. "
                         + "Use the app's own “Check for Updates” menu, or the developer's website.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }
            }
        }
    }

    @ViewBuilder
    private var managedElsewhereSection: some View {
        let rows = filtered(model.managedElsewhere)
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { state.showOtherApps.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .bold))
                            .rotationEffect(.degrees(state.showOtherApps ? 90 : 0))
                        SectionTitle(title: "Updated Elsewhere", count: rows.count)
                        Text("App Store · Homebrew · Apple")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .foregroundStyle(.secondary)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .pointingHandCursor()
                .padding(.horizontal, 4)

                if state.showOtherApps {
                    GlassCard {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                            AppRow(row: row, style: .managed)
                            if index < rows.count - 1 {
                                Rectangle().fill(Brand.hairline).frame(height: 1).padding(.leading, 64)
                            }
                        }
                    }
                }
            }
        }
    }

    private func filtered(_ rows: [AppModel.Row]) -> [AppModel.Row] {
        let search = state.search
        guard !search.isEmpty else { return rows }
        return rows.filter { $0.app.name.localizedCaseInsensitiveContains(search) }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                Task { await model.refresh() }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(CircleIconButtonStyle())
            .disabled(model.isChecking)
            .keyboardShortcut("r")
            .help("Check for updates (⌘R)")
        }
    }

    /// Text button at the top right of the updates list.
    private var updateAllButton: some View {
        let allBusy = model.updates.allSatisfy { model.installStates[$0.id]?.isWorking == true }
        return Button("Update All") { requestInstallAll() }
            .buttonStyle(LinkButtonStyle())
            .font(.system(.callout, design: .rounded).weight(.semibold))
            .disabled(allBusy)
            .help("Install all available updates, one after another")
    }

    private var managedElsewhereTitle: String {
        let count = model.managedElsewhere.count
        return "Updated elsewhere (App Store, Homebrew, Apple) — \(count)"
    }

    private var quitDialogShown: Binding<Bool> {
        let state = self.state
        return Binding(
            get: { state.confirmQuit != nil },
            set: { shown in if !shown { state.confirmQuit = nil } }
        )
    }

    private var quitTitle: String {
        guard let apps = state.confirmQuit?.apps else { return "" }
        if apps.count == 1 { return "\(apps[0].name) is open" }
        return "\(apps.count) apps are open"
    }

    // MARK: Actions

    private func requestInstall(_ row: AppModel.Row) {
        if model.isRunning(row) {
            state.confirmQuit = WindowState.ConfirmQuit(apps: [row.app]) { [model] in model.install(row) }
        } else {
            model.install(row)
        }
    }

    private func requestInstallAll() {
        let running = model.runningAppsWithUpdates
        if running.isEmpty {
            model.installAll()
        } else {
            state.confirmQuit = WindowState.ConfirmQuit(apps: running) { [model] in model.installAll() }
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
        HStack(spacing: 14) {
            AppIcon(url: row.app.url)
                .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 3) {
                Text(row.app.name)
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .lineLimit(1)
                detail
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .contextMenu { menu }
    }

    @ViewBuilder
    private var detail: some View {
        switch row.result {
        case let .updateAvailable(update)?:
            HStack(spacing: 6) {
                Text(row.app.shortVersion.isEmpty ? row.app.buildVersion : row.app.shortVersion)
                Image(systemName: "arrow.right").font(.system(size: 9, weight: .bold))
                Text(update.newVersion).foregroundStyle(Brand.blue).fontWeight(.semibold)
                SourceBadge(source: update.source)
                if update.releaseNotesHTML != nil || update.releaseNotesURL != nil {
                    Button("Release Notes") { showReleaseNotes(row) }
                        .buttonStyle(LinkButtonStyle())
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
                .foregroundStyle(Brand.blue)
                .font(.system(.callout, design: .rounded).weight(.medium))
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
                    .buttonStyle(PillButtonStyle())
                }
                Button("Retry") { requestInstall(row) }
                    .buttonStyle(PillButtonStyle())
            }
            .frame(maxWidth: 260, alignment: .trailing)
        case nil:
            switch style {
            case .update:
                Button("Update") { requestInstall(row) }
                    .buttonStyle(PillButtonStyle(prominent: true))
            case .ignored:
                Button("Unskip") { model.unignore(bundleIdentifier: row.app.bundleIdentifier) }
                    .buttonStyle(PillButtonStyle())
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
        Text(source.isFromDeveloper ? "Developer" : "Homebrew")
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(source.isFromDeveloper ? Brand.blue : Color.secondary)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(source.isFromDeveloper
                                       ? Brand.blue.opacity(0.14) : Color.white.opacity(0.08)))
            .help(helpText)
    }

    private var helpText: String {
        switch source {
        case .sparkle: return "Found through the update feed built into the app (Sparkle)."
        case .electron: return "Found through the app's own update server (electron-updater)."
        case .homebrew: return "Found through the Homebrew cask catalog."
        }
    }
}

struct InstallProgress: View {
    let phase: InstallPhase
    let cancel: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .trailing, spacing: 2) {
                if case let .downloading(fraction) = phase, fraction > 0 {
                    ProgressView(value: fraction).frame(width: 120).tint(Brand.blue)
                } else {
                    ProgressView().progressViewStyle(.linear).frame(width: 120).tint(Brand.blue)
                }
                Text(label).font(.caption2).foregroundStyle(.secondary)
            }
            if case .downloading = phase {
                Button(action: cancel) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(CircleIconButtonStyle(size: 22))
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

/// Section heading: small caps-style title plus a count pill.
struct SectionTitle: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .tracking(0.8)
                .foregroundStyle(.secondary)
            Text("\(count)")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(Capsule().fill(Color.white.opacity(0.08)))
        }
    }
}

/// The app icon drawn in SwiftUI (Design/AppIcon.svg): graphite tile, blue arrow.
struct AppLogo: View {
    let size: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.226, style: .continuous)
        shape
            .fill(LinearGradient(colors: [Brand.graphiteTop, Brand.graphiteBottom],
                                 startPoint: .top, endPoint: .bottom))
            .overlay(shape.strokeBorder(Brand.hairline, lineWidth: 1))
            .overlay(LogoGlyph().stroke(Brand.blue, style: StrokeStyle(
                lineWidth: size * 0.053, lineCap: .round, lineJoin: .round)))
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
    }
}

/// The icon's arrow-over-baseline, in tile coordinates (100…924 on the 1024 grid).
struct LogoGlyph: Shape {
    func path(in rect: CGRect) -> Path {
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + (x - 100) / 824 * rect.width,
                    y: rect.minY + (y - 100) / 824 * rect.height)
        }
        var path = Path()
        path.move(to: p(512, 648)); path.addLine(to: p(512, 312))
        path.move(to: p(370, 454)); path.addLine(to: p(512, 312)); path.addLine(to: p(654, 454))
        path.move(to: p(364, 736)); path.addLine(to: p(660, 736))
        return path
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
