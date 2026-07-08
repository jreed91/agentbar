import SwiftUI

@main
struct AgentBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// Observes the queue so the menu-bar label re-renders when the pending count changes.
    @ObservedObject private var queue = AppState.shared.queue

    var body: some Scene {
        MenuBarExtra {
            QueueView()
                .environmentObject(AppState.shared)
        } label: {
            let count = queue.pendingCount
            Image(systemName: count > 0 ? "bell.badge.fill" : "bell")
            if count > 0 {
                Text("\(count)")
            }
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
    }
}

/// Starts the server + notifications on launch and tears them down on quit.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppState.shared.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppState.shared.stop()
    }
}
