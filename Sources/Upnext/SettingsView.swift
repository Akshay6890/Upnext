import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage(SettingsKey.useHomebrew) private var useHomebrew = true
    @AppStorage(SettingsKey.autoCheckHours) private var autoCheckHours = 6
    @AppStorage(SettingsKey.notify) private var notify = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        Form {
            Section("Checking") {
                Picker("Check automatically", selection: $autoCheckHours) {
                    Text("Never").tag(0)
                    Text("Every hour").tag(1)
                    Text("Every 3 hours").tag(3)
                    Text("Every 6 hours").tag(6)
                    Text("Every 12 hours").tag(12)
                    Text("Every day").tag(24)
                }
                .onChange(of: autoCheckHours) { _ in model.scheduleAutoCheck() }

                Toggle("Use the Homebrew catalog for apps without an update feed", isOn: $useHomebrew)
                    .onChange(of: useHomebrew) { _ in model.homebrewSettingChanged() }
                Text("Upnext first asks each app's own update feed (Sparkle). For apps that don't have one, "
                     + "it looks up the latest version in the public Homebrew cask catalog. "
                     + "Homebrew doesn't need to be installed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Toggle("Notify me when updates are found", isOn: $notify)
                    .onChange(of: notify) { enabled in
                        if enabled { model.requestNotificationPermission() }
                    }
                Toggle("Open Upnext at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() }
                            else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }

            Section("Skipped versions") {
                if model.ignoredVersions.isEmpty {
                    Text("None").foregroundStyle(.secondary)
                } else {
                    ForEach(model.ignoredVersions.sorted(by: { $0.key < $1.key }), id: \.key) { entry in
                        HStack {
                            Text(appName(for: entry.key))
                            Text(entry.value).foregroundStyle(.secondary)
                            Spacer()
                            Button("Unskip") { model.unignore(bundleIdentifier: entry.key) }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func appName(for bundleID: String) -> String {
        model.apps.first { $0.bundleIdentifier == bundleID }?.name ?? bundleID
    }
}
