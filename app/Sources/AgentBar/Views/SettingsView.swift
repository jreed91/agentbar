import SwiftUI
import ServiceManagement

/// Settings pane: per-event notification toggles, banner sound, and launch-at-login.
struct SettingsView: View {
    @AppStorage("notifyQuestions") private var notifyQuestions = true
    @AppStorage("notifyPermissions") private var notifyPermissions = true
    @AppStorage("notifyElicitations") private var notifyElicitations = true
    @AppStorage("notifyWorking") private var notifyWorking = true
    @AppStorage("notifyIdle") private var notifyIdle = true
    @AppStorage("notifyTaskFinished") private var notifyTaskFinished = true
    @AppStorage("notifySubagent") private var notifySubagent = true
    @AppStorage("notifySessionEnd") private var notifySessionEnd = true
    @AppStorage("notifyErrors") private var notifyErrors = true
    @AppStorage("playSound") private var playSound = true
    @AppStorage("distinctSounds") private var distinctSounds = false

    @AppStorage("dndEnabled") private var dndEnabled = false
    @AppStorage("dndStartHour") private var dndStartHour = 22
    @AppStorage("dndEndHour") private var dndEndHour = 8

    @AppStorage("infoExpirySeconds") private var infoExpirySeconds = 25.0
    @AppStorage("debugLogging") private var debugLogging = false

    @State private var launchAtLogin = false
    @State private var launchError: String?

    private let hours = Array(0...23)

    /// The app's marketing version (`CFBundleShortVersionString`), stamped into the release
    /// bundle by `scripts/bundle.sh`. A bare `swift run` binary has no Info.plist to read, so
    /// fall back to "dev" — which also makes an unstamped local build obvious at a glance.
    private var appVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "dev"
    }

    var body: some View {
        Form {
            SetupSection()

            Section("Notify me about") {
                Toggle("Questions", isOn: $notifyQuestions)
                Toggle("Permission requests", isOn: $notifyPermissions)
                Toggle("MCP input requests", isOn: $notifyElicitations)
                Toggle("Agent is thinking", isOn: $notifyWorking)
                Toggle("Idle / waiting for input", isOn: $notifyIdle)
                Toggle("Task finished", isOn: $notifyTaskFinished)
                Toggle("Subagent finished", isOn: $notifySubagent)
                Toggle("Session ended", isOn: $notifySessionEnd)
                Toggle("Errors & interruptions", isOn: $notifyErrors)
            }

            Section("Banners") {
                Toggle("Play sound", isOn: $playSound)
                Toggle("Distinct sound per event type", isOn: $distinctSounds)
                    .disabled(!playSound)
                    .help("Permission, question, done and error each get their own system sound.")
                LabeledContent("Auto-dismiss info after") {
                    HStack(spacing: 6) {
                        Slider(value: $infoExpirySeconds, in: 5...120, step: 5)
                            .frame(width: 140)
                        Text("\(Int(infoExpirySeconds))s")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                ShortcutRecorderRow(title: "Open AgentBar", action: .togglePopover)
                ShortcutRecorderRow(title: "Focus what needs me", action: .focusNeedsMe)
            } header: {
                Text("Shortcuts")
            } footer: {
                Text("Shortcuts work system-wide. Focus jumps to the prompt that has waited longest.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Do Not Disturb") {
                Toggle("Silence banners during a window", isOn: $dndEnabled)
                    .help("Rows still badge the menu bar; only banners and sounds are held back.")
                if dndEnabled {
                    Picker("From", selection: $dndStartHour) {
                        ForEach(hours, id: \.self) { Text(hourLabel($0)).tag($0) }
                    }
                    Picker("Until", selection: $dndEndHour) {
                        ForEach(hours, id: \.self) { Text(hourLabel($0)).tag($0) }
                    }
                }
            }

            Section {
                Toggle("Log raw hook payloads (debug)", isOn: $debugLogging)
            } header: {
                Text("Diagnostics")
            } footer: {
                Text("Writes events to ~/Library/Application Support/AgentBar/debug.log for troubleshooting payload parsing. Mute a project from its row in the popover.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                LabeledContent("Version", value: appVersion)
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .onAppear {
            launchAtLogin = (SMAppService.mainApp.status == .enabled)
        }
    }

    /// A 12-hour clock label for an hour-of-day, e.g. `10 PM`, `8 AM`, `12 PM`.
    private func hourLabel(_ hour: Int) -> String {
        let period = hour < 12 ? "AM" : "PM"
        let twelve = hour % 12 == 0 ? 12 : hour % 12
        return "\(twelve) \(period)"
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
