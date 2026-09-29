import AppKit
import SwiftUI

@main
struct UpnextApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    // Shared instances rather than @StateObject, which may also be a macro in newer SDKs.
    private let model = AppModel.shared
    private let windowState = WindowState.shared

    var body: some Scene {
        Window("Upnext", id: "main") {
            ContentView()
                .environmentObject(model)
                .environmentObject(windowState)
        }
        .defaultSize(width: 680, height: 560)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates") {
                    Task { await model.refresh() }
                }
                .keyboardShortcut("r")
            }
        }

        MenuBarExtra {
            MenuBarContent().environmentObject(model)
        } label: {
            MenuBarLabel().environmentObject(model)
        }

        Settings {
            SettingsView().environmentObject(model)
        }
    }
}

/// A separate view so the count refreshes when the model changes.
struct MenuBarLabel: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let count = model.updates.count
        HStack(spacing: 3) {
            Image(systemName: count > 0 ? "arrow.down.app.fill" : "arrow.down.app")
            if count > 0 { Text("\(count)") }
        }
        // The menu bar label lives as long as the app, so it's a reliable place
        // to borrow SwiftUI's openWindow for links coming from the widget.
        .onAppear { WindowOpener.action = openWindow }
    }
}

/// Opens (or brings forward) the main window from AppKit code.
@MainActor
enum WindowOpener {
    static var action: OpenWindowAction?

    static func showMain() {
        if let action { action(id: "main") }
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct MenuBarContent: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if model.isChecking {
            Text("Checking \(model.checkedCount) of \(model.checkableCount)…")
        } else if model.updates.isEmpty {
            Text("All apps are up to date")
        } else {
            ForEach(model.updates.prefix(10)) { row in
                Text("\(row.app.name)  \(row.update?.newVersion ?? "")")
            }
            if model.updates.count > 10 {
                Text("and \(model.updates.count - 10) more…")
            }
        }
        Divider()
        Button("Open Upnext") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Check Now") {
            Task { await model.refresh() }
        }
        .disabled(model.isChecking)
        Divider()
        Button("Quit Upnext") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        registerURLHandler()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Writing to a pipe of a process that already exited must not crash us.
        signal(SIGPIPE, SIG_IGN)
        NSApp.setActivationPolicy(.regular)
        // Registered again in case SwiftUI installed its own handler in between.
        registerURLHandler()
    }

    // MARK: upnext:// links from the widget

    private func registerURLHandler() {
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleURLEvent(_:replyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass), andEventID: AEEventID(kAEGetURL))
    }

    @objc private func handleURLEvent(_ event: NSAppleEventDescriptor, replyEvent: NSAppleEventDescriptor) {
        guard let string = event.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))?.stringValue,
              let url = URL(string: string), url.scheme == "upnext" else { return }
        MainActor.assumeIsolated { handle(url) }
    }

    @MainActor
    private func handle(_ url: URL) {
        let model = AppModel.shared
        switch url.host {
        case "update-all":
            // Apps that aren't open update quietly in the background. Open apps
            // need a yes before we quit them, so show the window and ask.
            let running = model.installAllNotRunning()
            if !running.isEmpty {
                WindowOpener.showMain()
                WindowState.shared.confirmQuit = WindowState.ConfirmQuit(apps: running) {
                    model.install(apps: running)
                }
            }
        case "refresh":
            Task { await model.refresh() }
        default:
            WindowOpener.showMain()
        }
    }

    // Keep running in the menu bar after the window is closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
