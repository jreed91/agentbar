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

    /// Handles an incoming hook event. Never blocks the session: it enqueues a
    /// notification row and returns immediately. Attention kinds (question, permission,
    /// elicitation) persist until you dismiss them and drive the badge; informational
    /// kinds auto-expire.
    func submit(event: HookEvent, payload: Data) {
        let parsed = HookPayload(data: payload)

        switch event {
        case .ask:
            guard settingEnabled("notifyQuestions") else { return }
            let questions = HookPayload.questions(from: parsed.toolInput)
            guard !questions.isEmpty else { return }
            enqueueAttention(PendingItem(
                sessionID: parsed.sessionID,
                cwd: parsed.cwd,
                kind: .question(questions)
            ))

        case .permission:
            guard settingEnabled("notifyPermissions") else { return }
            let toolName = parsed.toolName ?? "Tool"
            let detail = HookPayload.prettyDetail(from: parsed.toolInput)
            enqueueAttention(PendingItem(
                sessionID: parsed.sessionID,
                cwd: parsed.cwd,
                kind: .permission(toolName: toolName, detail: detail)
            ))

        case .elicit:
            guard settingEnabled("notifyElicitations") else { return }
            let request = HookPayload.elicitation(from: parsed.raw)
            enqueueAttention(PendingItem(
                sessionID: parsed.sessionID,
                cwd: parsed.cwd,
                kind: .elicitation(request)
            ))

        case .notify:
            guard settingEnabled("notifyIdle") else { return }
            // Dedupe: suppress idle banners for sessions that already have a pending
            // question or permission item (an unanswered prompt also fires Notification).
            if items.contains(where: { $0.sessionID == parsed.sessionID && $0.needsResponse }) {
                return
            }
            let body = parsed.message ?? "Claude is waiting for your input."
            enqueueInfo(PendingItem(
                sessionID: parsed.sessionID,
                cwd: parsed.cwd,
                kind: .info(title: "Waiting for input", body: body)
            ))

        case .stop:
            guard settingEnabled("notifyTaskFinished") else { return }
            let body = parsed.message ?? "Claude finished the current task."
            enqueueInfo(PendingItem(
                sessionID: parsed.sessionID,
                cwd: parsed.cwd,
                kind: .info(title: "Task finished", body: body)
            ))

        case .subagentStop:
            guard settingEnabled("notifySubagent") else { return }
            let body = parsed.lastAssistantMessage ?? parsed.message ?? "A subagent finished."
            enqueueInfo(PendingItem(
                sessionID: parsed.sessionID,
                cwd: parsed.cwd,
                kind: .info(title: "Subagent finished", body: body)
            ))

        case .sessionEnd:
            guard settingEnabled("notifySessionEnd") else { return }
            let body = parsed.endReason.map { "Session ended (\($0))." } ?? "The Claude Code session ended."
            enqueueInfo(PendingItem(
                sessionID: parsed.sessionID,
                cwd: parsed.cwd,
                kind: .info(title: "Session ended", body: body)
            ))

        case .stopFailure:
            guard settingEnabled("notifyErrors") else { return }
            let detail = parsed.errorMessage ?? parsed.errorType ?? "The turn ended due to an error."
            enqueueInfo(PendingItem(
                sessionID: parsed.sessionID,
                cwd: parsed.cwd,
                kind: .info(title: "Claude run interrupted", body: detail)
            ))
        }
    }

    /// Enqueues an attention item (Claude is waiting in the terminal). It stays until you
    /// dismiss it — there is no reply channel back into the session, so nothing auto-clears
    /// it, but it also never blocks the session.
    private func enqueueAttention(_ item: PendingItem) {
        items.append(item)
        notificationManager?.post(for: item)
    }

    private func enqueueInfo(_ item: PendingItem) {
        items.append(item)
        notificationManager?.post(for: item)
        scheduleExpiry(item)
    }

    // MARK: - Dismissal

    /// Removes an item from the queue and clears its banner. Used both by the user's
    /// dismiss button and by the auto-expiry timer for informational rows.
    func dismiss(_ item: PendingItem) {
        notificationManager?.remove(item)
        items.removeAll { $0.id == item.id }
    }

    // MARK: - Helpers

    private func scheduleExpiry(_ item: PendingItem, after seconds: Double = 25) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            self.dismiss(item)
        }
    }

    /// UserDefaults toggles default to true when unset.
    private func settingEnabled(_ key: String) -> Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: key) == nil { return true }
        return defaults.bool(forKey: key)
    }
}
