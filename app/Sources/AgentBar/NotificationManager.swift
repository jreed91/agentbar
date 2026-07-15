import Foundation
import UserNotifications
import AppKit

/// Wraps `UNUserNotificationCenter`: requests authorization, posts an actionable banner
/// per pending item (registering a unique category so the banner can carry item-specific
/// actions), and routes the user's response back into `QueueStore` on the main actor.
@MainActor
final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    private let center = UNUserNotificationCenter.current()

    /// Banner action identifiers. AgentBar is notify-only, so none of these answer a prompt —
    /// they manage the notification itself (clear it, hush it for a while) or copy the
    /// pending command to the clipboard so you can paste it in the terminal.
    private enum Action {
        static let dismiss = "AGENTBAR_DISMISS"
        static let snooze = "AGENTBAR_SNOOZE"
        static let copy = "AGENTBAR_COPY"
    }

    /// How long a snoozed item stays hushed before its banner is re-posted (if still pending).
    private let snoozeInterval: TimeInterval = 10 * 60

    func setup() {
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// The current notification authorization state, for the Setup panel's "Notifications"
    /// check. Uses the completion-handler API bridged with a continuation (matching the
    /// `getNotificationCategories` calls elsewhere in this file) and extracts the Sendable
    /// enum inside the callback, so no non-Sendable `UNNotificationSettings` crosses the
    /// actor hop. Non-prompting: it only reads state, never requests authorization.
    func authorizationStatus() async -> UNAuthorizationStatus {
        let center = self.center
        return await withCheckedContinuation { continuation in
            center.getNotificationSettings { settings in
                continuation.resume(returning: settings.authorizationStatus)
            }
        }
    }

    // MARK: - Posting

    func post(for item: PendingItem) {
        let content = UNMutableNotificationContent()
        content.subtitle = URL(fileURLWithPath: item.cwd).lastPathComponent

        let agentName = item.source.shortName
        switch item.kind {
        case .question(let questions):
            content.title = "Question from \(agentName)"
            content.body = questions.first?.question ?? "\(agentName) has a question."
        case .permission(let toolName, _, _):
            content.title = "Permission request"
            content.body = "\(agentName) wants to use \(toolName)."
        case .elicitation(let request):
            content.title = "\(agentName) needs input"
            content.body = request.message
        case .info(_, let title, let body):
            content.title = title
            content.body = body
        }

        let categoryID = "item-\(item.id.uuidString)"
        content.categoryIdentifier = categoryID
        // Stash the command (if any) so "Copy command" works even after the row has cleared.
        var info: [String: Any] = ["itemID": item.id.uuidString]
        if case .permission(_, let command?, _) = item.kind { info["command"] = command }
        content.userInfo = info
        if Self.playSoundEnabled() {
            content.sound = Self.sound(for: item)
        }

        let category = Self.buildCategory(id: categoryID, for: item)
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

    /// Builds the per-item category. AgentBar is notify-only, so no action answers a prompt:
    /// clicking the banner body still just brings your terminal forward. The buttons manage
    /// the notification itself — Dismiss clears the row, Snooze hushes an attention item for
    /// a while, and Copy command puts a permission's shell command on the clipboard so you
    /// can paste it in the terminal.
    private static func buildCategory(id: String, for item: PendingItem) -> UNNotificationCategory {
        var actions: [UNNotificationAction] = []

        if case .permission(_, let command, _) = item.kind, command != nil {
            actions.append(UNNotificationAction(
                identifier: Action.copy,
                title: "Copy command",
                options: []
            ))
        }
        if item.needsResponse {
            actions.append(UNNotificationAction(
                identifier: Action.snooze,
                title: "Snooze 10 min",
                options: []
            ))
        }
        actions.append(UNNotificationAction(
            identifier: Action.dismiss,
            title: "Dismiss",
            options: []
        ))

        return UNNotificationCategory(
            identifier: id,
            actions: actions,
            intentIdentifiers: [],
            options: []
        )
    }

    /// The sound for an item. When "Distinct sounds per event" is on, attention events get
    /// louder, more distinct system sounds so you can tell a permission from a finished task
    /// without looking; otherwise everything uses the default alert sound.
    private static func sound(for item: PendingItem) -> UNNotificationSound {
        guard UserDefaults.standard.bool(forKey: "distinctSounds") else { return .default }
        let name: String
        switch item.feedStatus {
        case .permission: name = "Sosumi.aiff"
        case .question: name = "Ping.aiff"
        case .error: name = "Basso.aiff"
        case .done: name = "Glass.aiff"
        default: return .default
        }
        return UNNotificationSound(named: UNNotificationSoundName(name))
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
        let info = response.notification.request.content.userInfo
        let itemID = info["itemID"] as? String
        let command = info["command"] as? String
        let actionID = response.actionIdentifier
        let userText = (response as? UNTextInputNotificationResponse)?.userText

        Task { @MainActor in
            self.handle(itemID: itemID, actionID: actionID, userText: userText, command: command)
            completionHandler()
        }
    }

    // MARK: - Response routing

    private func handle(itemID: String?, actionID: String, userText: String?, command: String?) {
        let queue = AppState.shared.queue

        let item = itemID
            .flatMap { UUID(uuidString: $0) }
            .flatMap { uuid in queue.items.first { $0.id == uuid } }

        switch actionID {
        case UNNotificationDefaultActionIdentifier:
            // Clicking the banner brings the session's terminal forward to answer there.
            TerminalFocus.focus(hint: item?.terminalHint, cwd: item?.cwd)
            // Informational rows have served their purpose once seen; clear them.
            if let item, case .info = item.kind {
                queue.dismiss(item)
            }

        case UNNotificationDismissActionIdentifier, Action.dismiss:
            if let item {
                queue.dismiss(item)
            }

        case Action.copy:
            // Put the pending command on the clipboard; the banner stays so the prompt is
            // still visibly waiting. Falls back to the stashed userInfo copy if the row is gone.
            if let command = commandFor(item) ?? command {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(command, forType: .string)
            }

        case Action.snooze:
            if let item { snooze(item) }

        default:
            TerminalFocus.focus(hint: item?.terminalHint, cwd: item?.cwd)
        }
    }

    private func commandFor(_ item: PendingItem?) -> String? {
        if case .permission(_, let command, _)? = item?.kind { return command }
        return nil
    }

    /// Hushes an attention item: clears its delivered banner now and re-posts it after
    /// `snoozeInterval`, but only if it is still pending (unanswered) then.
    private func snooze(_ item: PendingItem) {
        let identifier = item.id.uuidString
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        let itemID = item.id
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(self.snoozeInterval * 1_000_000_000))
            if let live = AppState.shared.queue.items.first(where: { $0.id == itemID }) {
                self.post(for: live)
            }
        }
    }
}
