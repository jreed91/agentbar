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
            // The design puts an ASCII mascot in the menu bar whose face tracks the
            // queue's mood; the pending count trails it when something needs you.
            let count = queue.pendingCount
            Text(queue.menuBarFace)
                .font(.system(size: 12, design: .monospaced))
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
