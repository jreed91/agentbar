import Foundation
import Combine

/// Shared singleton that wires the queue, HTTP server, and notification manager together.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    let queue = QueueStore()
    let server = HookServer()
    let notifications = NotificationManager()

    /// The loopback port the hook server is currently listening on, or nil when it isn't
    /// running. Published from `HookServer`'s listener state (via `setServerPort`) so the
    /// Setup panel's "Local server" check reflects the live pipeline rather than the last
    /// value written to `server.json`.
    @Published private(set) var serverPort: UInt16?

    private init() {
        registerDefaults()
        queue.notificationManager = notifications
    }

    /// Records the hook server's listening port (or nil when it stops). Called by
    /// `HookServer` from its listener-state handler, which hops to the main actor first.
    func setServerPort(_ port: UInt16?) {
        serverPort = port
    }

    /// Called from the app delegate on launch.
    func start() {
        notifications.setup()
        server.start()
    }

    /// Called from the app delegate on termination; removes server.json.
    func stop() {
        server.stop()
    }

    private func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            "notifyQuestions": true,
            "notifyPermissions": true,
            "notifyElicitations": true,
            "notifyWorking": true,
            "notifyIdle": true,
            "notifyTaskFinished": true,
            "notifySubagent": true,
            "notifySessionEnd": true,
            "notifyErrors": true,
            "playSound": true,
            "distinctSounds": false,
            "dndEnabled": false,
            "dndStartHour": 22,
            "dndEndHour": 8,
            "debugLogging": false,
            "infoExpirySeconds": 25.0
        ])
    }
}
