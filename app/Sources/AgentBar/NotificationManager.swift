import Foundation
import UserNotifications
import AppKit

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

        let category = Self.buildCategory(id: categoryID, for: item.kind)
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

    /// Builds the per-item category. Single-question asks with 1–3 options get one action
    /// per option plus a text-input action; permissions get Allow/Deny; everything else
    /// (multi-question or overflow) gets no actions and opens the app on default click.
    private static func buildCategory(id: String, for kind: PendingItem.Kind) -> UNNotificationCategory {
        var actions: [UNNotificationAction] = []

        switch kind {
        case .question(let questions):
            if questions.count == 1,
               let question = questions.first,
               (1...3).contains(question.options.count) {
                for (index, option) in question.options.enumerated() {
                    actions.append(UNNotificationAction(
                        identifier: "opt:\(index)",
                        title: option.label,
                        options: []
                    ))
                }
                actions.append(UNTextInputNotificationAction(
                    identifier: "text",
                    title: "Type a reply…",
                    options: [],
                    textInputButtonTitle: "Send",
                    textInputPlaceholder: "Your answer"
                ))
            }
        case .permission:
            actions.append(UNNotificationAction(identifier: "allow", title: "Allow", options: []))
            actions.append(UNNotificationAction(identifier: "deny", title: "Deny", options: [.destructive]))
        case .info:
            break
        }

        return UNNotificationCategory(
            identifier: id,
            actions: actions,
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

        guard let itemID,
              let uuid = UUID(uuidString: itemID),
              let item = queue.items.first(where: { $0.id == uuid }) else {
            activateApp()
            return
        }

        switch actionID {
        case UNNotificationDefaultActionIdentifier:
            // Default click: focus terminal for informational items, otherwise open the app.
            if case .info = item.kind {
                TerminalFocus.focus()
            } else {
                activateApp()
            }

        case UNNotificationDismissActionIdentifier:
            if case .info = item.kind {
                queue.dismiss(item)
            }

        case "allow":
            queue.allowPermission(item: item)

        case "deny":
            queue.denyPermission(item: item, message: userText ?? "")

        case "text":
            if let text = userText,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               case .question(let questions) = item.kind,
               let question = questions.first {
                let label = questionLabel(question)
                queue.answerQuestion(item: item, answers: [(question: label, answer: text)])
            } else {
                activateApp()
            }

        default:
            if actionID.hasPrefix("opt:"),
               case .question(let questions) = item.kind,
               let question = questions.first,
               let index = Int(actionID.dropFirst(4)),
               index < question.options.count {
                let label = questionLabel(question)
                queue.answerQuestion(
                    item: item,
                    answers: [(question: label, answer: question.options[index].label)]
                )
            } else {
                activateApp()
            }
        }
    }

    private func questionLabel(_ question: AskQuestion) -> String {
        if let header = question.header, !header.isEmpty { return header }
        return question.question
    }

    private func activateApp() {
        NSApp.activate(ignoringOtherApps: true)
    }
}
