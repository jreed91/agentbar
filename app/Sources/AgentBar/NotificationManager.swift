import Foundation
import UserNotifications

/// Wraps `UNUserNotificationCenter`: requests authorization, posts an actionable banner
/// per pending item (registering a unique category so the banner can carry item-specific
/// actions), and routes the user's response back into `QueueStore` on the main actor.
@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()

    func setup() {
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // MARK: - Posting

    func post(for item: PendingItem) {
        let content = UNMutableNotificationContent()
        content.subtitle = URL(fileURLWithPath: item.cwd).lastPathComponent

        switch item.kind {
        case .question(let questions):
            content.title = "Question from Claude"
            content.body = questions.first?.question ?? "Claude has a question."
        case .permission(let toolName, _):
            content.title = "Permission request"
            content.body = "Claude wants to use \(toolName)."
        case .elicitation(let request):
            content.title = "Claude needs input"
            content.body = request.message
        case .info(let title, let body):
            content.title = title
            content.body = body
        }

        let categoryID = "item-\(item.id.uuidString)"
        content.categoryIdentifier = categoryID
        content.userInfo = ["itemID": item.id.uuidString]
        if Self.playSoundEnabled() {
            content.sound = .default
        }

        let category = Self.buildCategory(id: categoryID)
        let request = UNNotificationRequest(
            identifier: item.id.uuidString,
            content: content,
            trigger: nil
        )

        // Merge the item's category into the existing set, then post — this ordering
        // ensures the actions exist before the banner is delivered.
        let center = self.center
        center.getNotificationCategories { existing in
            var set = existing.filter { $0.identifier != categoryID }
            set.insert(category)
            center.setNotificationCategories(set)
            center.add(request)
        }
    }

    /// Builds the per-item category. AgentBar is notify-only, so banners carry no inline
    /// reply actions — clicking one just brings your terminal back to the front so you can
    /// answer there.
    private static func buildCategory(id: String) -> UNNotificationCategory {
        UNNotificationCategory(
            identifier: id,
            actions: [],
            intentIdentifiers: [],
            options: []
        )
    }

    // MARK: - Removal

    func remove(_ item: PendingItem) {
        let identifier = item.id.uuidString
        let categoryID = "item-\(identifier)"
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        center.removePendingNotificationRequests(withIdentifiers: [identifier])

        let center = self.center
        center.getNotificationCategories { existing in
            let set = existing.filter { $0.identifier != categoryID }
            center.setNotificationCategories(set)
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        var options: UNNotificationPresentationOptions = [.banner]
        if Self.playSoundEnabled() { options.insert(.sound) }
        completionHandler(options)
    }

    /// "playSound" defaults to true when unset. Nonisolated so the delegate's
    /// nonisolated callbacks can use it too.
    private nonisolated static func playSoundEnabled() -> Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: "playSound") == nil { return true }
        return defaults.bool(forKey: "playSound")
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        // Extract only Sendable values before hopping to the main actor.
        let itemID = response.notification.request.content.userInfo["itemID"] as? String
        let actionID = response.actionIdentifier
        let userText = (response as? UNTextInputNotificationResponse)?.userText

        Task { @MainActor in
            self.handle(itemID: itemID, actionID: actionID, userText: userText)
            completionHandler()
        }
    }

    // MARK: - Response routing

    private func handle(itemID: String?, actionID: String, userText: String?) {
        let queue = AppState.shared.queue

        let item = itemID
            .flatMap { UUID(uuidString: $0) }
            .flatMap { uuid in queue.items.first { $0.id == uuid } }

        switch actionID {
        case UNNotificationDefaultActionIdentifier:
            // Clicking the banner brings the terminal forward so you can answer there.
            TerminalFocus.focus()
            // Informational rows have served their purpose once seen; clear them.
            if let item, case .info = item.kind {
                queue.dismiss(item)
            }

        case UNNotificationDismissActionIdentifier:
            if let item {
                queue.dismiss(item)
            }

        default:
            TerminalFocus.focus()
        }
    }
}
