import AppKit
import SwiftUI

@main
struct UpnextApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("Upnext", id: "main") {
            ContentView()
                .environmentObject(model)
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
            let count = model.updates.count
            Image(systemName: count > 0 ? "arrow.down.app.fill" : "arrow.down.app")
            if count > 0 { Text("\(count)") }
        }

        Settings {
            SettingsView().environmentObject(model)
        }
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
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Writing to a pipe of a process that already exited must not crash us.
        signal(SIGPIPE, SIG_IGN)
        NSApp.setActivationPolicy(.regular)
    }

    // Keep running in the menu bar after the window is closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
