import Foundation
import Combine

/// The source of truth for the popover and the menu-bar badge. All access is on the
/// main actor; the HTTP server hops here via `Task { @MainActor in ... }`.
@MainActor
final class QueueStore: ObservableObject {
    @Published private(set) var items: [PendingItem] = []

    /// Set by `AppState` after construction. Weak because `AppState` owns both objects.
    weak var notificationManager: NotificationManager?

    /// Number of items still awaiting a response (excludes informational rows).
    var pendingCount: Int {
        items.filter { $0.needsResponse }.count
    }

    // MARK: - Submission

    /// Handles an incoming hook event. For blocking kinds it suspends until the user
    /// resolves the item and returns the finished hook-output JSON (or nil = passthrough,
    /// meaning an empty HTTP body and a terminal fallback). For informational kinds it
    /// enqueues an auto-expiring row and returns nil immediately.
    func submit(event: HookEvent, payload: Data) async -> String? {
        let parsed = HookPayload(data: payload)

        switch event {
        case .ask:
            guard settingEnabled("notifyQuestions") else { return nil }
            let questions = HookPayload.questions(from: parsed.toolInput)
            guard !questions.isEmpty else { return nil }
            let item = PendingItem(
                sessionID: parsed.sessionID,
                cwd: parsed.cwd,
                kind: .question(questions)
            )
            return await enqueueBlocking(item)

        case .permission:
            guard settingEnabled("notifyPermissions") else { return nil }
            let toolName = parsed.toolName ?? "Tool"
            let detail = HookPayload.prettyDetail(from: parsed.toolInput)
            let item = PendingItem(
                sessionID: parsed.sessionID,
                cwd: parsed.cwd,
                kind: .permission(toolName: toolName, detail: detail)
            )
            return await enqueueBlocking(item)

        case .notify:
            guard settingEnabled("notifyIdle") else { return nil }
            // Dedupe: suppress idle banners for sessions that already have a pending
            // question or permission item (an unanswered prompt also fires Notification).
            if items.contains(where: { $0.sessionID == parsed.sessionID && $0.needsResponse }) {
                return nil
            }
            let body = parsed.message ?? "Claude is waiting for your input."
            let item = PendingItem(
                sessionID: parsed.sessionID,
                cwd: parsed.cwd,
                kind: .info(title: "Waiting for input", body: body)
            )
            enqueueInfo(item)
            return nil

        case .stop:
            guard settingEnabled("notifyTaskFinished") else { return nil }
            let body = parsed.message ?? "Claude finished the current task."
            let item = PendingItem(
                sessionID: parsed.sessionID,
                cwd: parsed.cwd,
                kind: .info(title: "Task finished", body: body)
            )
            enqueueInfo(item)
            return nil
        }
    }

    private func enqueueBlocking(_ item: PendingItem) async -> String? {
        items.append(item)
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            item.attach(continuation)
            // Post the notification only after the continuation is attached so a fast
            // banner action can never race ahead of the suspension.
            notificationManager?.post(for: item)
        }
    }

    private func enqueueInfo(_ item: PendingItem) {
        items.append(item)
        notificationManager?.post(for: item)
        scheduleExpiry(item)
    }

    // MARK: - Resolution

    /// Resolves an answered question as a `PreToolUse` deny-with-answer. `answers` pairs
    /// each question's header/text with the chosen or typed answer.
    func answerQuestion(item: PendingItem, answers: [(question: String, answer: String)]) {
        let pairs = answers.map { "\($0.question): \($0.answer)" }.joined(separator: "; ")
        let reason = "The user answered via the AgentBar menu bar app. \(pairs). Use these answers and continue — do not re-ask the user."
        let json = makeJSON([
            "hookSpecificOutput": [
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                "permissionDecisionReason": reason
            ]
        ])
        resolve(item, with: json)
    }

    /// Resolves a permission request by allowing it.
    func allowPermission(item: PendingItem) {
        let json = makeJSON([
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": ["behavior": "allow"]
            ]
        ])
        resolve(item, with: json)
    }

    /// Resolves a permission request by denying it, optionally with a reason message.
    func denyPermission(item: PendingItem, message: String) {
        var decision: [String: Any] = ["behavior": "deny"]
        if !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            decision["message"] = message
        }
        let json = makeJSON([
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": decision
            ]
        ])
        resolve(item, with: json)
    }

    /// Resolves a blocking item with an empty body, falling back to the terminal.
    func passthrough(item: PendingItem) {
        resolve(item, with: nil)
    }

    /// Removes an informational (or any) item without resuming a hook.
    func dismiss(_ item: PendingItem) {
        item.resume(with: nil)
        notificationManager?.remove(item)
        items.removeAll { $0.id == item.id }
    }

    // MARK: - Helpers

    private func resolve(_ item: PendingItem, with json: String?) {
        item.resume(with: json)
        notificationManager?.remove(item)
        items.removeAll { $0.id == item.id }
    }

    private func scheduleExpiry(_ item: PendingItem, after seconds: Double = 25) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            self.dismiss(item)
        }
    }

    private func makeJSON(_ object: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let string = String(data: data, encoding: .utf8) else {
            return nil
        }
        return string
    }

    /// UserDefaults toggles default to true when unset.
    private func settingEnabled(_ key: String) -> Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: key) == nil { return true }
        return defaults.bool(forKey: key)
    }
}
