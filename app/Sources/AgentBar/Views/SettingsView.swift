import SwiftUI
import ServiceManagement

/// Settings pane: per-event notification toggles, banner sound, and launch-at-login.
struct SettingsView: View {
    @AppStorage("notifyQuestions") private var notifyQuestions = true
    @AppStorage("notifyPermissions") private var notifyPermissions = true
    @AppStorage("notifyIdle") private var notifyIdle = true
    @AppStorage("notifyTaskFinished") private var notifyTaskFinished = true
    @AppStorage("playSound") private var playSound = true

    @State private var launchAtLogin = false
    @State private var launchError: String?

    var body: some View {
        Form {
            Section("Notify me about") {
                Toggle("Questions", isOn: $notifyQuestions)
                Toggle("Permission requests", isOn: $notifyPermissions)
                Toggle("Idle / waiting for input", isOn: $notifyIdle)
                Toggle("Task finished", isOn: $notifyTaskFinished)
            }

            Section("Banners") {
                Toggle("Play sound", isOn: $playSound)
            }

            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        updateLaunchAtLogin(newValue)
                    }
                if let launchError {
                    Text(launchError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .onAppear {
            launchAtLogin = (SMAppService.mainApp.status == .enabled)
        }
    }

    private func updateLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                try SMAppService.mainApp.unregister()
            }
            launchError = nil
        } catch {
            launchError = error.localizedDescription
            // Reflect the true status if the change failed.
            launchAtLogin = (SMAppService.mainApp.status == .enabled)
        }
    }
}
