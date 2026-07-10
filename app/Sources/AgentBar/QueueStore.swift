import Foundation
import Combine

/// One row in the popover's session list: a Claude Code session (discovered on disk) with
/// any live hook events for it folded in. The roster comes from the transcript scan; live
/// events overlay a fresher status, an ask line, and a terminal hint for "focus".
struct SessionRow: Identifiable {
    let id: String
    let cwd: String
    let title: String
    let lastActivity: Date
    let messageCount: Int
    /// The session's current status: the loudest live event (permission > question >
    /// working > error > done), or `.idle` when nothing is live.
    let status: FeedStatus
    /// Live hook events for this session, loudest first. Empty for a quiet/historical row.
    let liveItems: [PendingItem]
    /// Terminal/IDE hint from the live events, for a precise "focus"; nil falls back to a
    /// priority scan.
    let terminalHint: TerminalHint?
    /// True when the session has recent hook activity (seen within `sessionTTL`) or a live
    /// item right now — i.e. a terminal is plausibly still open on it.
    let isLive: Bool
}

/// The source of truth for the popover and the menu-bar badge. All access is on the
/// main actor; the HTTP server hops here via `Task { @MainActor in ... }`.
@MainActor
final class QueueStore: ObservableObject {
    @Published private(set) var items: [PendingItem] = []

    /// The Claude Code sessions discovered on disk, newest-first. Refreshed off the main
    /// thread by `refreshSessions()`; merged with live `items` into `sessionRows`.
    @Published private(set) var scannedSessions: [ClaudeSession] = []

    private let scanner = SessionScanner()
    private var isScanning = false

    /// Sessions AgentBar is watching, keyed by session id → the last time it sent any hook
    /// event. This is tracked independently of `items` so the "watching N sessions" readout
    /// reflects live sessions even when nothing is pending; entries are dropped on
    /// `SessionEnd` or after `sessionTTL` of silence.
    @Published private var sessionsLastSeen: [String: Date] = [:]

    /// A session with no hook activity for this long is treated as gone (covers terminals
    /// closed without a clean `SessionEnd`).
    private let sessionTTL: TimeInterval = 4 * 3600

    /// When we have no live hook events for a session, a transcript written more recently
    /// than this is taken as "still working" — Claude writes continuously while working and
    /// goes quiet when waiting. Kept short so a finished session settles to idle quickly.
    private let workingWindow: TimeInterval = 12

    /// Set by `AppState` after construction. Weak because `AppState` owns both objects.
    weak var notificationManager: NotificationManager?

    /// Number of items still awaiting a response (excludes informational rows).
    var pendingCount: Int {
        items.filter { $0.needsResponse }.count
    }

    // MARK: - Live-feed derived state

    /// Number of Claude Code sessions currently being watched (seen within `sessionTTL`).
    var sessionCount: Int {
        let now = Date()
        return sessionsLastSeen.values.filter { now.timeIntervalSince($0) < sessionTTL }.count
    }

    /// Permission requests still awaiting you in the terminal.
    var pendingPermissions: Int {
        items.filter { $0.feedStatus == .permission }.count
    }

    /// Questions / MCP input requests still awaiting you in the terminal.
    var pendingQuestions: Int {
        items.filter { $0.feedStatus == .question }.count
    }

    /// The overall mascot mood, in priority order: permission out-shouts a question, which
    /// out-shouts background work, which out-shouts a finished task, and an empty queue is
    /// happy. Mirrors the design's per-scenario mood.
    var mood: FeedMood {
        if items.isEmpty { return .happy }
        if pendingPermissions > 0 { return .permission }
        if pendingQuestions > 0 { return .question }
        if items.contains(where: { $0.feedStatus == .working }) { return .working }
        return .done
    }

    /// The ASCII face shown in the menu-bar label (design `asciiMini`).
    var menuBarFace: String { mood.miniFace }

    /// The hero headline in the popover — a short summary of what, if anything, needs you.
    var headline: String {
        let permissions = pendingPermissions
        let questions = pendingQuestions
        let pending = permissions + questions
        if pending > 0 {
            if permissions > 0 && questions > 0 {
                return "\(pending) things need you"
            } else if permissions > 0 {
                return permissions == 1 ? "Permission needed" : "\(permissions) permissions need you"
            } else {
                return questions == 1 ? "Claude has a question" : "\(questions) questions waiting"
            }
        }
        if items.contains(where: { $0.feedStatus == .working }) { return "Claude's on it" }
        return "Task complete"
    }

    /// The hero subline — a one-line breakdown under the headline.
    var subline: String {
        let permissions = pendingPermissions
        let questions = pendingQuestions
        if permissions > 0 && questions > 0 {
            return "\(countPhrase(permissions, "permission")) · \(countPhrase(questions, "question"))"
        } else if permissions > 0 {
            return permissions == 1 ? "Claude wants to run a command." : "\(permissions) commands need approval."
        } else if questions > 0 {
            return questions == 1 ? "One session is waiting on your answer." : "\(questions) sessions are waiting on you."
        }
        if items.contains(where: { $0.feedStatus == .working }) {
            return "Working — nothing needs you yet."
        }
        return "Recent activity below."
    }

    private func countPhrase(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
    }

    // MARK: - Session roster (disk scan + live merge)

    /// Kicks off a background scan of the transcript tree and republishes `scannedSessions`.
    /// Single-flighted, so calling it on popover open and on a light interval is cheap — the
    /// scanner itself only re-reads transcripts whose modification date changed.
    func refreshSessions() {
        guard !isScanning else { return }
        isScanning = true
        Task {
            let sessions = await scanner.scan()
            self.scannedSessions = sessions
            self.isScanning = false
        }
    }

    /// The popover's rows: every scanned session, plus any live session not yet on disk,
    /// each with its live hook events folded in and sorted loudest-status-first.
    var sessionRows: [SessionRow] {
        let now = Date()

        var liveBySession: [String: [PendingItem]] = [:]
        for item in items where !item.sessionID.isEmpty {
            liveBySession[item.sessionID, default: []].append(item)
        }

        var rows: [SessionRow] = []
        var seen = Set<String>()

        for session in scannedSessions {
            seen.insert(session.id)
            let live = sortedByLoudness(liveBySession[session.id] ?? [])
            let liveLatest = live.map(\.createdAt).max() ?? .distantPast
            // Live hook events are authoritative. Only when we have none — e.g. AgentBar was
            // started mid-turn and never caught this session's `working` hook — do we infer
            // activity from the transcript: Claude writes to it continuously while working
            // and goes quiet when waiting, so a very recent write means it is still working.
            let fresh = live.isEmpty && now.timeIntervalSince(session.lastActivity) < workingWindow
            let rowStatus: FeedStatus
            if live.isEmpty {
                rowStatus = fresh ? .working : .idle
            } else {
                rowStatus = status(for: live)
            }
            rows.append(SessionRow(
                id: session.id,
                cwd: session.cwd,
                title: session.title,
                lastActivity: max(session.lastActivity, liveLatest),
                messageCount: session.messageCount,
                status: rowStatus,
                liveItems: live,
                terminalHint: live.compactMap(\.terminalHint).first,
                isLive: isLive(session.id, now: now) || !live.isEmpty || fresh
            ))
        }

        // Live sessions not (yet) on disk — brand-new, or beyond the scanner's recent cap.
        // Synthesize a row so nothing waiting on you is ever hidden.
        for (sessionID, itemsForSession) in liveBySession where !seen.contains(sessionID) {
            let live = sortedByLoudness(itemsForSession)
            rows.append(SessionRow(
                id: sessionID,
                cwd: live.first?.cwd ?? "",
                title: live.first?.summaryLine ?? "Active session",
                lastActivity: live.map(\.createdAt).max() ?? now,
                messageCount: 0,
                status: status(for: live),
                liveItems: live,
                terminalHint: live.compactMap(\.terminalHint).first,
                isLive: true
            ))
        }

        // One row per location: a project run many times collapses to a single row. Pick
        // the representative by liveness first, so a running/working session is never hidden
        // behind an idle sibling in the same directory that merely has a newer transcript;
        // then by louder status, then by recency. Sessions with no cwd key on their id so
        // they are never merged together.
        var byLocation: [String: SessionRow] = [:]
        for row in rows {
            let key = row.cwd.isEmpty ? row.id : row.cwd
            if let existing = byLocation[key], !prefer(row, over: existing) { continue }
            byLocation[key] = row
        }

        // Most recent first.
        return byLocation.values.sorted { $0.lastActivity > $1.lastActivity }
    }

    /// Which of two sessions competing for the same location should represent it: a live
    /// session outranks a quiet one, then a louder status wins, then the more recent. This
    /// keeps a working session visible even when an idle session in the same directory was
    /// touched a moment more recently.
    private func prefer(_ a: SessionRow, over b: SessionRow) -> Bool {
        if a.isLive != b.isLive { return a.isLive }
        let rankA = statusRank(a.status), rankB = statusRank(b.status)
        if rankA != rankB { return rankA < rankB }
        return a.lastActivity > b.lastActivity
    }

    /// Loudest live event wins the row's status; `.idle` when there is nothing live.
    private func status(for live: [PendingItem]) -> FeedStatus {
        for status in [FeedStatus.permission, .question, .working, .error, .done]
        where live.contains(where: { $0.feedStatus == status }) {
            return status
        }
        return .idle
    }

    /// Ordering for statuses: attention first, quiet last. Also orders the rows.
    private func statusRank(_ status: FeedStatus) -> Int {
        switch status {
        case .permission: return 0
        case .question: return 1
        case .working: return 2
        case .error: return 3
        case .done: return 4
        case .idle: return 5
        }
    }

    private func sortedByLoudness(_ live: [PendingItem]) -> [PendingItem] {
        live.sorted { statusRank($0.feedStatus) < statusRank($1.feedStatus) }
    }

    private func isLive(_ sessionID: String, now: Date) -> Bool {
        guard let last = sessionsLastSeen[sessionID] else { return false }
        return now.timeIntervalSince(last) < sessionTTL
    }

    // MARK: - Submission

    /// Handles an incoming hook event. Never blocks the session: it enqueues a
    /// notification row and returns immediately. Attention kinds (question, permission,
    /// elicitation) persist until you dismiss them and drive the badge; informational
    /// kinds auto-expire.
    func submit(event: HookEvent, payload: Data, terminal: TerminalHint? = nil) {
        let parsed = HookPayload(data: payload)

        // Every event from a session counts as "watching" it, until it ends or goes quiet.
        if !parsed.sessionID.isEmpty, event != .sessionEnd {
            sessionsLastSeen[parsed.sessionID] = Date()
            pruneSessions()
        }

        switch event {
        case .ask:
            guard settingEnabled("notifyQuestions") else { return }
            let questions = HookPayload.questions(from: parsed.toolInput)
            guard !questions.isEmpty else { return }
            enqueueAttention(PendingItem(
                sessionID: parsed.sessionID,
                cwd: parsed.cwd,
                kind: .question(questions),
                terminalHint: terminal
            ))

        case .permission:
            guard settingEnabled("notifyPermissions") else { return }
            let toolName = parsed.toolName ?? "Tool"
            let command = HookPayload.command(from: parsed.toolInput)
            let detail = HookPayload.prettyDetail(from: parsed.toolInput)
            enqueueAttention(PendingItem(
                sessionID: parsed.sessionID,
                cwd: parsed.cwd,
                kind: .permission(toolName: toolName, command: command, detail: detail),
                terminalHint: terminal
            ))

        case .elicit:
            guard settingEnabled("notifyElicitations") else { return }
            let request = HookPayload.elicitation(from: parsed.raw)
            enqueueAttention(PendingItem(
                sessionID: parsed.sessionID,
                cwd: parsed.cwd,
                kind: .elicitation(request),
                terminalHint: terminal
            ))

        case .resolved:
            // A tool completed — Claude can only run tools once you have answered whatever
            // it was blocked on, so any pending prompt for this session was resolved in the
            // terminal. Clear its attention rows (and their banners); Claude is now working.
            clearAttention(for: parsed.sessionID)
            if settingEnabled("notifyWorking"), !parsed.sessionID.isEmpty {
                enqueueWorking(PendingItem(
                    sessionID: parsed.sessionID,
                    cwd: parsed.cwd,
                    kind: .info(category: .working, title: "Working", body: "Thinking…"),
                    terminalHint: terminal
                ))
            }

        case .working:
            guard settingEnabled("notifyWorking") else { return }
            // A turn just started — Claude is thinking, not waiting. Skip the working row
            // for a session that already has something waiting on you (question/permission);
            // otherwise show a single live WORKING row, replacing any prior status.
            if items.contains(where: { $0.sessionID == parsed.sessionID && $0.needsResponse }) {
                return
            }
            enqueueWorking(PendingItem(
                sessionID: parsed.sessionID,
                cwd: parsed.cwd,
                kind: .info(category: .working, title: "Working", body: "Thinking…"),
                terminalHint: terminal
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
                kind: .info(category: .working, title: "Waiting for input", body: body),
                terminalHint: terminal
            ))

        case .stop:
            // The turn ended, so any prompt you were shown for this session is resolved.
            clearAttention(for: parsed.sessionID)
            guard settingEnabled("notifyTaskFinished") else { return }
            let body = parsed.message ?? "Claude finished the current task."
            enqueueInfo(PendingItem(
                sessionID: parsed.sessionID,
                cwd: parsed.cwd,
                kind: .info(category: .done, title: "Task finished", body: body),
                terminalHint: terminal
            ))

        case .subagentStop:
            guard settingEnabled("notifySubagent") else { return }
            let body = parsed.lastAssistantMessage ?? parsed.message ?? "A subagent finished."
            enqueueInfo(PendingItem(
                sessionID: parsed.sessionID,
                cwd: parsed.cwd,
                kind: .info(category: .done, title: "Subagent finished", body: body),
                terminalHint: terminal
            ))

        case .sessionEnd:
            // The session is gone: stop watching it and clear anything still pending.
            clearAttention(for: parsed.sessionID)
            sessionsLastSeen[parsed.sessionID] = nil
            guard settingEnabled("notifySessionEnd") else { return }
            let body = parsed.endReason.map { "Session ended (\($0))." } ?? "The Claude Code session ended."
            enqueueInfo(PendingItem(
                sessionID: parsed.sessionID,
                cwd: parsed.cwd,
                kind: .info(category: .done, title: "Session ended", body: body),
                terminalHint: terminal
            ))

        case .stopFailure:
            clearAttention(for: parsed.sessionID)
            guard settingEnabled("notifyErrors") else { return }
            let detail = parsed.errorMessage ?? parsed.errorType ?? "The turn ended due to an error."
            enqueueInfo(PendingItem(
                sessionID: parsed.sessionID,
                cwd: parsed.cwd,
                kind: .info(category: .error, title: "Claude run interrupted", body: detail),
                terminalHint: terminal
            ))
        }
    }

    /// Enqueues an attention item (Claude is waiting in the terminal). It stays until you
    /// dismiss it — there is no reply channel back into the session, so nothing auto-clears
    /// it, but it also never blocks the session. Claude is now waiting rather than thinking,
    /// so any live status row for the session is superseded.
    private func enqueueAttention(_ item: PendingItem) {
        clearStatusRows(for: item.sessionID)
        items.append(item)
        notificationManager?.post(for: item)
    }

    private func enqueueInfo(_ item: PendingItem) {
        // At most one lifecycle/status row per session: a finished/idle/error status
        // supersedes the "thinking" row from the same turn.
        clearStatusRows(for: item.sessionID)
        items.append(item)
        notificationManager?.post(for: item)
        scheduleExpiry(item)
    }

    /// Enqueues the live "Claude is thinking" status row. Unlike other rows it posts no
    /// banner and never auto-expires — it is cleared when the turn ends (a finished/error
    /// status arrives) or when Claude starts waiting on you. Replaces any prior status.
    private func enqueueWorking(_ item: PendingItem) {
        clearStatusRows(for: item.sessionID)
        items.append(item)
    }

    /// Removes the informational (`.info`) status rows for a session so at most one is ever
    /// present — working → idle → finished → error each supersede the last. Attention rows
    /// (questions, permissions, MCP input) are left untouched. Any delivered banner for a
    /// removed row is cleared too.
    private func clearStatusRows(for sessionID: String) {
        for item in items where item.sessionID == sessionID {
            if case .info = item.kind { notificationManager?.remove(item) }
        }
        items.removeAll { item in
            guard item.sessionID == sessionID else { return false }
            if case .info = item.kind { return true }
            return false
        }
    }

    /// Dismisses the pending attention rows (question / permission / MCP input) for a
    /// session and clears their banners. Called when a prompt has been answered in the
    /// terminal (a tool completed, or the turn ended), since there is no reply channel to
    /// clear them otherwise. Informational status rows are left for their own lifecycle.
    private func clearAttention(for sessionID: String) {
        let resolved = items.filter { $0.sessionID == sessionID && $0.needsResponse }
        for item in resolved { notificationManager?.remove(item) }
        items.removeAll { item in resolved.contains { $0.id == item.id } }
    }

    /// Drops sessions that have gone silent past `sessionTTL` so the watch count does not
    /// count terminals that were closed without a clean `SessionEnd`.
    private func pruneSessions() {
        let now = Date()
        sessionsLastSeen = sessionsLastSeen.filter { now.timeIntervalSince($0.value) < sessionTTL }
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
