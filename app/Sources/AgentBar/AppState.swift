import Foundation
import Combine

/// Shared singleton that wires the queue, HTTP server, and notification manager together.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    let queue = QueueStore()
    let server = HookServer()
    let notifications = NotificationManager()

    private init() {
        registerDefaults()
        queue.notificationManager = notifications
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
            "notifyIdle": true,
            "notifyTaskFinished": true,
            "playSound": true
        ])
    }
}
