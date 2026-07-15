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
    /// Which agent this session belongs to (Claude Code or GitHub Copilot). Drives the row's
    /// source tag; also keys the per-location de-dupe so the same directory running under both
    /// agents shows as two rows rather than collapsing to one.
    let source: AgentSource
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
    /// A read-only, one-line "what this agent is doing" label from the transcript (last tool
    /// or prose). Shown on rows that aren't currently waiting on you, so the roster reads as
    /// a live dashboard. Nil for a synthesized live-only row not yet scanned from disk.
    let activity: String?
    /// When the session's current turn began (the `working` hook's timestamp), for the live
    /// "working …" elapsed timer. Nil when no turn is in flight, or when AgentBar started
    /// mid-turn and never caught the `working` hook.
    let workingSince: Date?
    /// The session's recent-activity trail (from the transcript), oldest-first, for the
    /// read-only drill-in. Empty for a synthesized live-only row not yet scanned from disk.
    let trail: [ActivityEntry]
    /// The model the session's latest turn ran on (from the transcript), for the row's meta
    /// line. Nil when unknown.
    let model: String?
    /// Approximate context-window tokens in use on the latest turn (from the transcript), for
    /// the row's context gauge. Nil when unknown.
    let contextTokens: Int?
    /// The session's permission mode (`default`, `acceptEdits`, `plan`, `bypassPermissions`),
    /// captured from its hook events. Nil until a hook carrying it has been seen.
    let mode: String?
    /// Whether a subagent (a `Task` sidechain) is currently working in this session, read from
    /// the transcript. Surfaced as a row indicator; `false` for a live-only or Copilot row.
    let subagentActive: Bool
    /// Background shell jobs started and not explicitly killed, read from the transcript. A
    /// "launched, not torn down" tally (not a live process count); `0` for a live-only or
    /// Copilot row.
    let backgroundJobs: Int
}

/// At-a-glance counts for the dashboard summary strip, bucketed from the merged session
/// rows: sessions waiting on you (permission/question), actively working, errored, and quiet
/// (done or idle). Errors get their own bucket so an errored session is never folded into the
/// least-urgent "quiet" tier.
struct DashboardSummary {
    let needsYou: Int
    let working: Int
    let errors: Int
    let idle: Int
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
    private let copilotScanner = CopilotSessionScanner()
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
    /// goes quiet when waiting. Kept short so a finished session settles to idle quickly. Used
    /// only for a turn that is *not* known to be in flight (no `tool_use` stop_reason).
    private let workingWindow: TimeInterval = 12

    /// The staleness guard for a turn the transcript says is still in flight (its last
    /// assistant message stopped for `tool_use`). A single long tool call — a build, a big
    /// test run — can write nothing for minutes while the agent is genuinely working, so this
    /// is far longer than `workingWindow`; it only exists to settle an abandoned session (a
    /// terminal killed mid-tool, no clean `SessionEnd`) back to idle eventually rather than
    /// pinning it to "working" forever.
    private let inFlightWindow: TimeInterval = 10 * 60

    /// Set by `AppState` after construction. Weak because `AppState` owns both objects.
    weak var notificationManager: NotificationManager?

    /// Per-session turn start time, recorded when a turn begins (`working`) so a finished
    /// turn (`stop`) can report how long it took. Cleared when the turn ends or the session
    /// goes away.
    private var turnStart: [String: Date] = [:]

    /// Per-session permission mode, from the `permission_mode` carried on hook events. Kept so
    /// the row can show what mode a session is running under even between events; cleared when
    /// the session ends.
    private var sessionMode: [String: String] = [:]

    /// The newest slice of the persisted activity log, mirrored from `historyLog` for the
    /// popover's history view — "what happened while I was away". The full log (with its 7-day
    /// retention and daily-digest math) lives in `historyLog`; this published copy is the
    /// bounded, view-ready set so SwiftUI has a value to observe. The public shape is unchanged
    /// from when this was an in-memory array, so the views need no changes.
    @Published private(set) var history: [HistoryEntry] = []

    /// Owns activity-log persistence and the digest rollup. Injectable so tests root it in a
    /// temp directory instead of the real Application Support tree; the default loads (but does
    /// not write) the on-disk log at construction, so merely creating a `QueueStore` never
    /// touches the file — only an append/clear persists.
    private let historyLog: HistoryLog

    /// Project working directories the user has muted. Their events still appear in the feed
    /// and still badge the icon, but post no banner and play no sound. Mirrored to
    /// UserDefaults so mutes persist across launches.
    @Published private(set) var mutedProjects: Set<String> = Set(
        (UserDefaults.standard.array(forKey: "mutedProjects") as? [String]) ?? []
    )

    /// When any hook event was last received, across all agents. Drives the Setup panel's
    /// "plugin is talking to us" health check and the popover's "plugin not detected" pointer.
    /// Seeded from persistence at init (see `lastHookBySource`) so a relaunch after real
    /// activity doesn't wrongly read as "never heard from".
    @Published private(set) var lastHookAt: Date?

    /// When each agent's hooks were last heard, keyed by source, so the Setup panel can report
    /// the Claude plugin and the Copilot bridge independently. Persisted per source (keys
    /// `lastHookAtClaude` / `lastHookAtCopilot`) and reloaded at init; `lastHookAt` is derived
    /// as the newest of these. Reads go through `lastHookAt(for:)`.
    @Published private(set) var lastHookBySource: [AgentSource: Date] = [:]

    /// The last time `source`'s hooks were heard, or nil if never. Backs the Setup panel's
    /// per-agent rows and the empty-state pointer (`lastHookAt(for: .claude) == nil`).
    func lastHookAt(for source: AgentSource) -> Date? {
        lastHookBySource[source]
    }

    /// The UserDefaults key a source's last-hook timestamp is persisted under.
    private static func lastHookKey(for source: AgentSource) -> String {
        switch source {
        case .claude: return "lastHookAtClaude"
        case .copilot: return "lastHookAtCopilot"
        }
    }

    /// `historyLog` defaults to nil, not `HistoryLog()`: default-argument expressions are
    /// evaluated in a nonisolated context, so a `@MainActor` initializer can't be a default
    /// value. The fallback is constructed here in the (main-actor) init body instead.
    init(historyLog: HistoryLog? = nil) {
        self.historyLog = historyLog ?? HistoryLog()

        // Seed the per-source timestamps from persistence so the Setup panel and empty-state
        // pointer don't claim "never heard from" for a plugin that was working before the last
        // relaunch. The overall `lastHookAt` is the newest of the persisted per-source values,
        // so it needs no key of its own.
        var seeded: [AgentSource: Date] = [:]
        for source in [AgentSource.claude, .copilot] {
            if let date = UserDefaults.standard.object(forKey: Self.lastHookKey(for: source)) as? Date {
                seeded[source] = date
            }
        }
        lastHookBySource = seeded
        lastHookAt = seeded.values.max()

        // Seed the published history from the persisted log so a relaunch shows what happened
        // while the app was away, not an empty list. `self.` — the parameter of the same name
        // is the optional; the resolved property is what we read.
        history = self.historyLog.entriesForView
    }

    /// Records that a hook event just arrived from `source`, updating the overall and
    /// per-source timestamps and persisting the per-source one. Called for every event in
    /// `submit` before any per-event routing, so the health signal reflects that the plugin
    /// reached us even for events that raise no row. Events are low-rate, so a UserDefaults
    /// write per event is cheap.
    private func recordHook(from source: AgentSource) {
        let now = Date()
        lastHookAt = now
        lastHookBySource[source] = now
        UserDefaults.standard.set(now, forKey: Self.lastHookKey(for: source))
    }

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

    /// The overall mascot mood, in priority order matching the hero's tiers: a pending
    /// permission out-shouts a pending question, which out-shouts work in flight (a live
    /// working item *or* a working session row), which out-shouts a just-finished task (a
    /// `.done` info row still present). A quiet or empty roster is simply happy — `.done` is
    /// reserved for when something actually finished, not for standing by.
    var mood: FeedMood {
        if pendingPermissions > 0 { return .permission }
        if pendingQuestions > 0 { return .question }
        if items.contains(where: { $0.feedStatus == .working }) || rosterFacts().anyWorking {
            return .working
        }
        if items.contains(where: { $0.feedStatus == .done }) { return .done }
        return .happy
    }

    /// The ASCII face shown in the menu-bar label (design `asciiMini`).
    var menuBarFace: String { mood.miniFace }

    /// At-a-glance dashboard counts bucketed from the merged session rows: how many sessions
    /// need you (a permission or question is waiting), are actively working, have errored, and
    /// are quiet (finished or idle). Errors bucket separately so an errored session is surfaced
    /// rather than folded into the calm "quiet" count. Drives the popover's dashboard summary
    /// strip.
    var dashboardSummary: DashboardSummary {
        var needsYou = 0, working = 0, errors = 0, idle = 0
        for row in sessionRows {
            switch row.status {
            case .permission, .question: needsYou += 1
            case .working: working += 1
            case .error: errors += 1
            case .done, .idle: idle += 1
            }
        }
        return DashboardSummary(needsYou: needsYou, working: working, errors: errors, idle: idle)
    }

    /// The hero headline in the popover — a short summary of what, if anything, needs you.
    /// Attention counts stay item-based (they are precise); the working and quiet tiers are
    /// roster-based (see `rosterFacts`) so the hero agrees with the dashboard strip and the
    /// roster beneath it instead of reading "Task complete" over a WORKING group or an empty
    /// feed. Copy is source-aware: the agent's name comes from the sessions in play, not a
    /// hard-coded "Claude".
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
                return questions == 1 ? "\(attentionAgentName) has a question" : "\(questions) questions waiting"
            }
        }
        let facts = rosterFacts()
        if items.contains(where: { $0.feedStatus == .working }) || facts.anyWorking {
            if facts.workingSources.count == 1, let only = facts.workingSources.first {
                return "\(only.shortName)'s on it"
            }
            return "Agents at work"
        }
        if facts.count == 0 { return "Standing by" }
        return "All quiet"
    }

    /// The hero subline — a one-line breakdown under the headline, mirroring `headline`'s tiers.
    var subline: String {
        let permissions = pendingPermissions
        let questions = pendingQuestions
        if permissions > 0 && questions > 0 {
            return "\(countPhrase(permissions, "permission")) · \(countPhrase(questions, "question"))"
        } else if permissions > 0 {
            return permissions == 1 ? "\(attentionAgentName) wants to run a command." : "\(permissions) commands need approval."
        } else if questions > 0 {
            return questions == 1 ? "One session is waiting on your answer." : "\(questions) sessions are waiting on you."
        }
        let facts = rosterFacts()
        if items.contains(where: { $0.feedStatus == .working }) || facts.anyWorking {
            if facts.workingCount > 1 {
                return "\(countPhrase(facts.workingCount, "session")) working — nothing needs you."
            }
            return "Working — nothing needs you yet."
        }
        if facts.count == 0 { return "Start a Claude Code or Copilot session to watch it here." }
        return "\(countPhrase(facts.count, "session")) idle — nothing needs you."
    }

    private func countPhrase(_ n: Int, _ noun: String) -> String {
        "\(n) \(noun)\(n == 1 ? "" : "s")"
    }

    /// The agent name for attention copy: the shared source's short name when every pending
    /// attention item comes from one agent (so "Copilot has a question" reads honestly), or a
    /// neutral "An agent" when a mix of agents is waiting. Keeps the hero from hard-coding
    /// "Claude" on a Copilot-only or mixed roster.
    private var attentionAgentName: String {
        let sources = Set(items.filter { $0.needsResponse }.map(\.source))
        if sources.count == 1, let only = sources.first { return only.shortName }
        return "An agent"
    }

    /// Roster-derived facts the hero copy needs, computed from a single `sessionRows` pass so
    /// the quiet/working tiers of `headline`/`subline`/`mood` agree with the dashboard strip.
    private struct RosterFacts {
        /// Total session rows — the roster size the dashboard strip and feed show.
        let count: Int
        /// How many rows are actively working.
        let workingCount: Int
        /// The distinct agents among the working rows, used to name the working headline: one
        /// source → its name ("Claude's on it"), mixed or none → neutral copy ("Agents at work").
        let workingSources: Set<AgentSource>
        /// Whether any session is working right now.
        var anyWorking: Bool { workingCount > 0 }
    }

    /// Computes `RosterFacts` from one `sessionRows` evaluation. `sessionRows` does real merge
    /// work, so this runs once per `headline`/`subline`/`mood` read that reaches the roster
    /// tiers — deliberately not cached across runloop ticks, since the roster changes as
    /// sessions come and go and a stale snapshot would let the hero drift from the feed again.
    private func rosterFacts() -> RosterFacts {
        let rows = sessionRows
        var workingCount = 0
        var workingSources: Set<AgentSource> = []
        for row in rows where row.status == .working {
            workingCount += 1
            workingSources.insert(row.source)
        }
        return RosterFacts(count: rows.count, workingCount: workingCount, workingSources: workingSources)
    }

    /// The session whose oldest unanswered attention item (question / permission / MCP input)
    /// has been waiting the longest across the whole roster — the target of the "Focus what
    /// needs me" global hotkey. Nil when nothing needs you.
    ///
    /// This is deliberately the mirror image of QueueView's `focusLatestAttention()`, which
    /// jumps to the *newest* prompt. Clicking the hero follows your eye to whatever just came
    /// up; the global hotkey is a press-without-looking backlog tool, so it sends you to the
    /// prompt that has been blocked longest — nothing starves while you work in another app.
    /// A row's own age is its oldest pending item, so a session sitting on two prompts is
    /// ranked by the earlier of them.
    func longestWaitingAttentionRow() -> SessionRow? {
        sessionRows
            .compactMap { row -> (row: SessionRow, waitingSince: Date)? in
                let oldest = row.liveItems
                    .filter { $0.needsResponse }
                    .map(\.createdAt)
                    .min()
                guard let oldest else { return nil }
                return (row, oldest)
            }
            .min(by: { $0.waitingSince < $1.waitingSince })?
            .row
    }

    // MARK: - Session roster (disk scan + live merge)

    /// Kicks off a background scan of the transcript tree and republishes `scannedSessions`.
    /// Single-flighted, so calling it on popover open and on a light interval is cheap — the
    /// scanner itself only re-reads transcripts whose modification date changed.
    func refreshSessions() {
        guard !isScanning else { return }
        isScanning = true
        Task {
            // Scan both agents' on-disk session trees concurrently and merge them into one
            // newest-first roster. Either scan yields an empty list when that agent has never
            // run on this machine, so a Claude-only or Copilot-only user sees exactly their
            // own sessions.
            async let claude = scanner.scan()
            async let copilot = copilotScanner.scan()
            let merged = await (claude + copilot)
            self.scannedSessions = merged.sorted { $0.lastActivity > $1.lastActivity }
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
            // activity from the transcript. Prefer its own turn-state signal: a turn stopped
            // for `tool_use` is still working even if the running tool has written nothing for
            // minutes, so it is trusted for the long `inFlightWindow`. Absent that signal
            // (finished turn, other agent), fall back to write-recency: Claude writes
            // continuously while working and goes quiet when waiting, so a very recent write
            // still reads as working within the short `workingWindow`.
            let sinceWrite = now.timeIntervalSince(session.lastActivity)
            let inferredWorking = session.isTurnInFlight
                ? sinceWrite < inFlightWindow
                : sinceWrite < workingWindow
            let fresh = live.isEmpty && inferredWorking
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
                source: live.first?.source ?? session.source,
                status: rowStatus,
                liveItems: live,
                terminalHint: live.compactMap(\.terminalHint).first,
                isLive: isLive(session.id, now: now) || !live.isEmpty || fresh,
                activity: session.activity,
                workingSince: turnStart[session.id],
                trail: session.trail,
                model: session.model,
                contextTokens: session.contextTokens,
                mode: sessionMode[session.id],
                subagentActive: session.subagentActive,
                backgroundJobs: session.backgroundJobs
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
                source: live.first?.source ?? .claude,
                status: status(for: live),
                liveItems: live,
                terminalHint: live.compactMap(\.terminalHint).first,
                isLive: true,
                activity: nil,
                workingSince: turnStart[sessionID],
                trail: [],
                model: nil,
                contextTokens: nil,
                mode: sessionMode[sessionID],
                subagentActive: false,
                backgroundJobs: 0
            ))
        }

        // One row per location: a project run many times collapses to a single row. Pick
        // the representative by liveness first, so a running/working session is never hidden
        // behind an idle sibling in the same directory that merely has a newer transcript;
        // then by louder status, then by recency. Sessions with no cwd key on their id so
        // they are never merged together.
        var byLocation: [String: SessionRow] = [:]
        for row in rows {
            // Key by agent + location so a directory used by both Claude and Copilot keeps a
            // row per agent instead of one hiding the other. Sessions with no cwd key on their
            // (unique) id so they are never merged together.
            let location = row.cwd.isEmpty ? row.id : row.cwd
            let key = "\(row.source.rawValue)\u{1}\(location)"
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
    func submit(event: HookEvent, payload: Data, terminal: TerminalHint? = nil, source: AgentSource = .claude) {
        let parsed = HookPayload(data: payload)
        let agentName = source.shortName
        DebugLog.logEvent("→ \(source.rawValue)/\(event.rawValue)", raw: payload)

        // Every event — even ones that raise no row (a muted toggle, an unparsable ask) —
        // proves the plugin reached us, so stamp the health timestamp up front.
        recordHook(from: source)

        // Every event from a session counts as "watching" it, until it ends or goes quiet.
        if !parsed.sessionID.isEmpty, event != .sessionEnd {
            sessionsLastSeen[parsed.sessionID] = Date()
            pruneSessions()
        }

        // Remember the session's permission mode whenever a hook carries it, so the row's meta
        // line can show it even on events (and quiet stretches) that don't.
        if let mode = parsed.permissionMode, !parsed.sessionID.isEmpty {
            sessionMode[parsed.sessionID] = mode
        }

        // A turn just started — remember when, so the matching `stop` can report duration.
        // Recorded independently of the "Claude is thinking" toggle so timing works even
        // when that banner is muted.
        if event == .working, !parsed.sessionID.isEmpty {
            turnStart[parsed.sessionID] = Date()
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
                source: source,
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
                source: source,
                terminalHint: terminal
            ))

        case .elicit:
            guard settingEnabled("notifyElicitations") else { return }
            let request = HookPayload.elicitation(from: parsed.raw)
            if request.fields.isEmpty {
                DebugLog.log("elicitation parsed to message-only (no schema fields recognized); raw payload above")
            }
            enqueueAttention(PendingItem(
                sessionID: parsed.sessionID,
                cwd: parsed.cwd,
                kind: .elicitation(request),
                source: source,
                terminalHint: terminal
            ))

        case .resolved:
            // A tool finished (successfully or not) — Claude can only run tools once you have
            // answered whatever it was blocked on, so any pending prompt for this session was
            // resolved in the terminal. Clear its attention rows (and their banners); Claude
            // is now working.
            clearAttention(for: parsed.sessionID)
            if settingEnabled("notifyWorking"), !parsed.sessionID.isEmpty {
                enqueueWorking(PendingItem(
                    sessionID: parsed.sessionID,
                    cwd: parsed.cwd,
                    kind: .info(category: .working, title: "Working", body: "Thinking…"),
                    source: source,
                    terminalHint: terminal
                ))
            }

        case .denied:
            // A permission prompt was answered with a denial in the terminal
            // (`PermissionDenied`). The prompt is over, so its attention row (and banner)
            // must clear — but unlike `resolved`, Claude is not necessarily working now:
            // a denial can interrupt the turn and leave the session waiting for your typed
            // feedback, so no "thinking" status row is enqueued.
            clearAttention(for: parsed.sessionID)

        case .working:
            // A new user turn has begun (UserPromptSubmit). Claude only runs this hook once it
            // is no longer blocked on you, so any prompt still shown for this session was
            // answered in the terminal — clear it before showing that Claude is thinking again.
            clearAttention(for: parsed.sessionID)
            guard settingEnabled("notifyWorking") else { return }
            enqueueWorking(PendingItem(
                sessionID: parsed.sessionID,
                cwd: parsed.cwd,
                kind: .info(category: .working, title: "Working", body: "Thinking…"),
                source: source,
                terminalHint: terminal
            ))

        case .notify:
            guard settingEnabled("notifyIdle") else { return }
            // Dedupe: suppress idle banners for sessions that already have a pending
            // question or permission item (an unanswered prompt also fires Notification).
            if items.contains(where: { $0.sessionID == parsed.sessionID && $0.needsResponse }) {
                return
            }
            let body = parsed.message ?? "\(agentName) is waiting for your input."
            enqueueInfo(PendingItem(
                sessionID: parsed.sessionID,
                cwd: parsed.cwd,
                kind: .info(category: .working, title: "Waiting for input", body: body),
                source: source,
                terminalHint: terminal
            ))

        case .stop:
            // The turn ended, so any prompt you were shown for this session is resolved, and
            // the transient "thinking" status row from this turn is now stale. Clear both up
            // front — before the notification guard — so a finished session never stays stuck
            // showing "working" when the "task finished" banner happens to be disabled.
            clearAttention(for: parsed.sessionID)
            clearStatusRows(for: parsed.sessionID)
            let elapsed = turnStart[parsed.sessionID].map { Date().timeIntervalSince($0) }
            turnStart[parsed.sessionID] = nil
            guard settingEnabled("notifyTaskFinished") else { return }
            var body = parsed.message ?? "\(agentName) finished the current task."
            if let elapsed, elapsed >= 1 {
                body += " · finished in \(DurationFormat.short(elapsed))"
            }
            enqueueInfo(PendingItem(
                sessionID: parsed.sessionID,
                cwd: parsed.cwd,
                kind: .info(category: .done, title: "Task finished", body: body),
                source: source,
                terminalHint: terminal
            ))

        case .subagentStop:
            guard settingEnabled("notifySubagent") else { return }
            let body = parsed.lastAssistantMessage ?? parsed.message ?? "A subagent finished."
            enqueueInfo(PendingItem(
                sessionID: parsed.sessionID,
                cwd: parsed.cwd,
                kind: .info(category: .done, title: "Subagent finished", body: body),
                source: source,
                terminalHint: terminal
            ))

        case .sessionEnd:
            // The session is gone: stop watching it and clear anything still pending —
            // including the transient "thinking" row — regardless of whether the
            // "session ended" banner is enabled, so an ended session never lingers as working.
            clearAttention(for: parsed.sessionID)
            clearStatusRows(for: parsed.sessionID)
            sessionsLastSeen[parsed.sessionID] = nil
            turnStart[parsed.sessionID] = nil
            sessionMode[parsed.sessionID] = nil
            guard settingEnabled("notifySessionEnd") else { return }
            let body = parsed.endReason.map { "Session ended (\($0))." } ?? "The \(source.displayName) session ended."
            enqueueInfo(PendingItem(
                sessionID: parsed.sessionID,
                cwd: parsed.cwd,
                kind: .info(category: .done, title: "Session ended", body: body),
                source: source,
                terminalHint: terminal
            ))

        case .stopFailure:
            // The turn ended in an error, so the transient "thinking" row is stale. Clear it
            // up front — before the notification guard — so an interrupted session never stays
            // stuck showing "working" when the error banner is disabled. The turn is over, so
            // its start time must go too, or the next `stop` without a fresh `working` would
            // report a duration measured from the failed turn.
            clearAttention(for: parsed.sessionID)
            clearStatusRows(for: parsed.sessionID)
            turnStart[parsed.sessionID] = nil
            guard settingEnabled("notifyErrors") else { return }
            let detail = parsed.errorMessage ?? parsed.errorType ?? "The turn ended due to an error."
            enqueueInfo(PendingItem(
                sessionID: parsed.sessionID,
                cwd: parsed.cwd,
                kind: .info(category: .error, title: "\(agentName) run interrupted", body: detail),
                source: source,
                terminalHint: terminal
            ))
        }
    }

    /// Enqueues an attention item (Claude is waiting in the terminal). It stays until you
    /// answer in the terminal (a later hook clears it) or dismiss it by hand; it never blocks
    /// the session. Claude is now waiting rather than thinking, so any live status row is
    /// superseded.
    ///
    /// Claude blocks the terminal on one prompt at a time, so the arrival of a new prompt for
    /// this session means whatever was shown before it has already been answered — clear the
    /// stale attention rows (and their banners) before adding this one, so an answered
    /// permission or question doesn't linger behind its successor.
    private func enqueueAttention(_ item: PendingItem) {
        clearAttention(for: item.sessionID)
        clearStatusRows(for: item.sessionID)
        items.append(item)
        recordHistory(item)
        postBanner(item)
    }

    private func enqueueInfo(_ item: PendingItem) {
        // At most one lifecycle/status row per session: a finished/idle/error status
        // supersedes the "thinking" row from the same turn.
        clearStatusRows(for: item.sessionID)
        items.append(item)
        recordHistory(item)
        postBanner(item)
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
    ///
    /// Each cleared prompt was waiting on you and is now resolved — a tool finished, a new turn
    /// began, or a successor prompt superseded it (all of which mean it was answered in the
    /// terminal) — so record how long it sat, for the daily digest. This is the terminal-side
    /// clear path; the user's manual-dismiss path is `dismiss(_:)`, and the two don't overlap
    /// (whichever removes an item first, the other no longer finds it), so a prompt is sampled
    /// exactly once.
    private func clearAttention(for sessionID: String) {
        let resolved = items.filter { $0.sessionID == sessionID && $0.needsResponse }
        for item in resolved {
            notificationManager?.remove(item)
            recordWait(for: item)
        }
        items.removeAll { item in resolved.contains { $0.id == item.id } }
    }

    /// Drops sessions that have gone silent past `sessionTTL` so the watch count does not
    /// count terminals that were closed without a clean `SessionEnd`. The per-session side
    /// tables go with them: a session killed mid-turn never sends `stop`/`sessionEnd`, and in
    /// a long-running menu-bar app those entries would otherwise accumulate forever (and a
    /// resumed session id would inherit a wildly stale turn-start time).
    private func pruneSessions() {
        let now = Date()
        sessionsLastSeen = sessionsLastSeen.filter { now.timeIntervalSince($0.value) < sessionTTL }
        turnStart = turnStart.filter { sessionsLastSeen[$0.key] != nil }
        sessionMode = sessionMode.filter { sessionsLastSeen[$0.key] != nil }
    }

    // MARK: - Dismissal

    /// Removes an item from the queue and clears its banner. Used both by the user's
    /// dismiss button and by the auto-expiry timer for informational rows.
    ///
    /// When the user dismisses an attention prompt by hand, sample how long it waited for the
    /// daily digest — this is the manual-dismiss counterpart to `clearAttention`'s terminal
    /// path. Guarded on `needsResponse` so the auto-expiry of an informational row (which also
    /// routes through here) is never counted as a wait, and so an item can't be double-sampled
    /// (an info row has no wait; an attention row clears via exactly one of these two paths).
    func dismiss(_ item: PendingItem) {
        notificationManager?.remove(item)
        if item.needsResponse { recordWait(for: item) }
        items.removeAll { $0.id == item.id }
    }

    // MARK: - Helpers

    /// Informational rows auto-expire after the user-configured interval (default 25s).
    private func scheduleExpiry(_ item: PendingItem) {
        let seconds = infoExpirySeconds
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            self.dismiss(item)
        }
    }

    /// Seconds an informational row lingers before auto-dismissing. Read from
    /// `infoExpirySeconds`, clamped to a sane range; falls back to 25 when unset.
    private var infoExpirySeconds: Double {
        let value = UserDefaults.standard.double(forKey: "infoExpirySeconds")
        guard value > 0 else { return 25 }
        return min(max(value, 5), 120)
    }

    /// UserDefaults toggles default to true when unset.
    private func settingEnabled(_ key: String) -> Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: key) == nil { return true }
        return defaults.bool(forKey: key)
    }

    // MARK: - Muting & Do Not Disturb

    func isMuted(_ cwd: String) -> Bool { mutedProjects.contains(cwd) }

    /// Toggles a project's mute state and persists it. Muted projects still enqueue rows and
    /// badge the icon; only their banners and sounds are held back.
    func toggleMute(_ cwd: String) {
        guard !cwd.isEmpty else { return }
        if mutedProjects.contains(cwd) {
            mutedProjects.remove(cwd)
        } else {
            mutedProjects.insert(cwd)
        }
        UserDefaults.standard.set(Array(mutedProjects), forKey: "mutedProjects")
    }

    /// Posts a banner for an item unless it is suppressed (muted project or Do Not Disturb).
    /// The row itself is already enqueued and badges regardless — only the interruptive
    /// banner is gated here.
    private func postBanner(_ item: PendingItem) {
        guard !bannerSuppressed(for: item) else { return }
        notificationManager?.post(for: item)
    }

    private func bannerSuppressed(for item: PendingItem) -> Bool {
        if !item.cwd.isEmpty && mutedProjects.contains(item.cwd) { return true }
        if inDoNotDisturb() { return true }
        return false
    }

    /// True when `now` falls inside the user's Do Not Disturb window. The window is a pair of
    /// hours [start, end); a start later than end wraps past midnight (e.g. 22 → 8 silences
    /// 10pm through 8am). Disabled or an empty (start == end) window is never in DND.
    func inDoNotDisturb(now: Date = Date()) -> Bool {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: "dndEnabled") else { return false }
        let start = defaults.integer(forKey: "dndStartHour")
        let end = defaults.integer(forKey: "dndEndHour")
        if start == end { return false }
        let hour = Calendar.current.component(.hour, from: now)
        return start < end ? (hour >= start && hour < end)
                           : (hour >= start || hour < end)
    }

    // MARK: - History

    /// Appends a snapshot of a surfaced event to the persistent activity log and mirrors the
    /// newest slice into `history` for the view. Working/thinking rows are transient and never
    /// recorded (they route through `enqueueWorking`, which does not call this).
    private func recordHistory(_ item: PendingItem) {
        let project = item.cwd.isEmpty ? "—" : URL(fileURLWithPath: item.cwd).lastPathComponent
        let entry = HistoryEntry(
            at: item.createdAt,
            project: project,
            status: item.feedStatus,
            summary: item.summaryLine
        )
        historyLog.append(entry)
        history = historyLog.entriesForView
    }

    /// Records how long an answered/dismissed attention prompt sat waiting, into the persistent
    /// log's wait samples (for the daily digest). The wait is measured from the item's
    /// `createdAt` to now, the moment it cleared. Only ever called for items that `needsResponse`
    /// so an auto-expiring info row is never counted (see `clearAttention` / `dismiss`).
    private func recordWait(for item: PendingItem) {
        let seconds = Date().timeIntervalSince(item.createdAt)
        historyLog.record(wait: WaitSample(at: Date(), seconds: seconds))
    }

    /// The daily digest for `day` (defaults to today), for the history view's summary strip.
    /// Pure and cheap — recomputed from the persisted log each read.
    func historyDigest(for day: Date = Date()) -> DailyDigest {
        historyLog.digest(for: day)
    }

    /// Clears the activity log (bound to a control in the history view). Clears the persisted
    /// entries and wait samples, then empties the mirrored view copy.
    func clearHistory() {
        historyLog.clear()
        history = historyLog.entriesForView
    }
}
