import SwiftUI
import AppKit

/// The popover content, styled as the "Live feed" design (2a): a dark-green phosphor
/// terminal. A title bar with a blinking LIVE badge, a hero with an ASCII mascot whose
/// mood tracks the queue, then a streaming feed of events — newest first — each with a
/// status tag and terminal-keycap actions.
///
/// AgentBar is notify-only: there is no reply channel back into a session, so the keycaps
/// bring your terminal forward (focus) or clear the row (dismiss) — they never answer a
/// prompt for you. That is why the design's inline `y allow / n deny` render as honest
/// focus/dismiss actions here.
struct QueueView: View {
    @ObservedObject private var queue = AppState.shared.queue

    /// The popover is a menu-bar popover: it stays centered under the icon, so width is
    /// fixed (a centered popover can only grow symmetrically). Height is user-adjustable by
    /// dragging the bottom edge and persists across launches; the popover grows downward.
    private let popoverWidth = 340.0
    @AppStorage("popoverHeight") private var popoverHeight = 460.0

    /// Height at the start of a resize drag, so `translation` applies to a fixed base.
    @State private var resizeBaseHeight: Double?

    /// The popover's pinned top edge (screen coords). MenuBarExtra keeps the window's
    /// bottom-left origin fixed on resize, so without this the top drifts from the menu bar
    /// when the popover shrinks. Captured on open, reset when it closes.
    @State private var anchorTop: CGFloat?

    /// When true the feed area shows the recent-activity log instead of the live sessions.
    @State private var showHistory = false

    /// Session ids whose read-only activity trail is expanded in the feed. Toggled per row;
    /// nothing here drives a session — it only reveals more of what already happened.
    @State private var expandedSessions: Set<String> = []

    /// The row currently selected for keyboard navigation, by session id. Nil when nothing is
    /// selected; the first ↓/j selects the top row. Drives the row highlight and is the target
    /// of the keyboard actions (focus / dismiss / mute / trail).
    @State private var selectedRowID: String?

    /// The installed local key-event monitor, retained so it can be torn down when the popover
    /// closes. Lets ↑/↓ (or j/k) walk the roster and ↵/d/m/→ run the selected row's actions
    /// from the keyboard while the popover is open.
    @State private var keyMonitor: Any?

    /// When true the feed hides quiet historical sessions (idle transcripts with no recent
    /// hook activity), leaving only the sessions a terminal is plausibly still open on.
    /// Persisted so the preference survives relaunch.
    @AppStorage("liveSessionsOnly") private var liveSessionsOnly = false

    private let minHeight = 260.0, maxHeight = 820.0

    /// One shared formatter for today's session timestamps (HH:mm:ss).
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    /// Short month/day formatter for sessions last active before today (e.g. "Jul 9").
    private static let dayStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            titleBar
            hero
            // The feed / empty state fills the space between the fixed hero and footer, so
            // dragging the popover taller enlarges the scrollable area (and grows downward,
            // since the popover is anchored under the icon at the top).
            Group {
                if showHistory {
                    HistoryView(entries: queue.history, onClear: { queue.clearHistory() })
                } else if queue.sessionRows.isEmpty {
                    emptyState
                } else {
                    feed
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            promptBar
        }
        .frame(width: popoverWidth, height: popoverHeight)
        // Scan the transcript tree while the popover is open: once on appear, then on a
        // light interval so a running session's status stays fresh. `.task` is cancelled on
        // disappear, so nothing scans in the background when the popover is closed.
        .task {
            while !Task.isCancelled {
                queue.refreshSessions()
                try? await Task.sleep(nanoseconds: 4_000_000_000)
            }
        }
        .background(Color.feedBG)
        .overlay(ScanlineOverlay())
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color.feedGreen.opacity(0.4), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(alignment: .bottom) { bottomResizeHandle }
        .background(WindowReader(trigger: popoverHeight) { window in
            pinTop(of: window)
            makeKeyIfNeeded(window)
        })
        .onAppear { installKeyMonitor() }
        .onDisappear {
            anchorTop = nil
            removeKeyMonitor()
        }
    }

    /// Makes the popover window the key window while it's open. AgentBar is a menu-bar
    /// accessory (`LSUIElement`), so the app never activates on its own and the popover panel
    /// isn't key by default — which means `keyDown` events route to whatever app *is* active,
    /// not here, and the local key monitor never sees them (mouse clicks still hit-test fine,
    /// which is why buttons work but the keyboard doesn't). Forcing the panel key lets the
    /// keyboard navigation actually receive events. Guarded so we only claim key once.
    private func makeKeyIfNeeded(_ window: NSWindow) {
        guard window.isVisible, !window.isKeyWindow else { return }
        window.makeKey()
    }

    /// Keeps the popover's top edge under the menu-bar icon as its height changes: capture
    /// the top on first sight, then hold `maxY` constant by adjusting the window origin.
    private func pinTop(of window: NSWindow) {
        guard window.isVisible, window.frame.height > 1 else { return }
        if anchorTop == nil { anchorTop = window.frame.maxY }
        guard let top = anchorTop else { return }
        let frame = window.frame
        let targetY = top - frame.height
        if abs(frame.origin.y - targetY) > 0.5 {
            window.setFrameOrigin(NSPoint(x: frame.origin.x, y: targetY))
        }
    }

    // MARK: - Resize handle

    /// A drag handle on the bottom edge. The popover is anchored under the menu-bar icon, so
    /// only height is adjustable — dragging down grows the popover downward. Persisted.
    private var bottomResizeHandle: some View {
        Capsule()
            .fill(Color.feedDim.opacity(0.8))
            .frame(width: 38, height: 4)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let base = resizeBaseHeight ?? popoverHeight
                        if resizeBaseHeight == nil { resizeBaseHeight = base }
                        popoverHeight = min(maxHeight, max(minHeight, base + value.translation.height))
                    }
                    .onEnded { _ in resizeBaseHeight = nil }
            )
            .onHover { hovering in
                if hovering { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
            }
            .help("Drag to resize")
    }

    // MARK: - Title bar

    private var titleBar: some View {
        HStack(spacing: 8) {
            Text("agentbar — \(queue.sessionRows.count) \(queue.sessionRows.count == 1 ? "session" : "sessions")")
                .font(feedFont(10.5))
                .foregroundStyle(Color.feedSub)
                .lineLimit(1)
            Spacer(minLength: 8)
            LiveBadge()
            filterToggle
            historyToggle
            settingsGear
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(Color.feedGreen.opacity(0.05))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.feedGreen.opacity(0.22)).frame(height: 1)
        }
    }

    /// Filters the roster to live sessions only, hiding quiet historical transcripts. Hidden
    /// while the history log is showing, since it filters the session feed, not the log.
    @ViewBuilder
    private var filterToggle: some View {
        if !showHistory {
            Button {
                liveSessionsOnly.toggle()
            } label: {
                Image(systemName: liveSessionsOnly ? "line.3.horizontal.decrease.circle.fill"
                                                    : "line.3.horizontal.decrease.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(liveSessionsOnly ? Color.feedGreen : Color.feedSub)
            }
            .buttonStyle(.plain)
            .help(liveSessionsOnly ? "Showing live sessions only" : "Show live sessions only")
        }
    }

    /// Toggles the feed between live sessions and the recent-activity log.
    private var historyToggle: some View {
        Button {
            showHistory.toggle()
        } label: {
            Image(systemName: showHistory ? "dot.radiowaves.left.and.right" : "clock.arrow.circlepath")
                .font(.system(size: 11))
                .foregroundStyle(showHistory ? Color.feedGreen : Color.feedSub)
        }
        .buttonStyle(.plain)
        .help(showHistory ? "Back to live sessions" : "Recent activity")
    }

    private var settingsGear: some View {
        SettingsLink {
            Image(systemName: "gearshape")
                .font(.system(size: 11))
                .foregroundStyle(Color.feedSub)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture().onEnded {
            // As an accessory (LSUIElement) app AgentBar is never the active app, so the
            // Settings window opens buried. Defer activation so it comes to the front.
            DispatchQueue.main.async { NSApp.activate(ignoringOtherApps: true) }
        })
    }

    // MARK: - Hero

    private var hero: some View {
        HStack(alignment: .center, spacing: 13) {
            MascotView(mood: queue.mood)
            VStack(alignment: .leading, spacing: 4) {
                Text("┌ STATUS")
                    .font(feedFont(10))
                    .tracking(1)
                    .foregroundStyle(Color.feedDim)
                Text(queue.headline)
                    .font(feedFont(14, .bold))
                    .foregroundStyle(Color.feedHead)
                    .textCase(.uppercase)
                Text(queue.subline)
                    .font(feedFont(11))
                    .foregroundStyle(Color.feedSub)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, 13)
        .padding(.bottom, 10)
        .contentShape(Rectangle())
        .onTapGesture { focusLatestAttention() }
        .help("Focus the session that needs you")
    }

    /// Brings forward the terminal of the most recently raised attention item (question,
    /// permission, or MCP input) — the "jump to what needs me" shortcut from the hero.
    private func focusLatestAttention() {
        let latest = queue.sessionRows
            .compactMap { row -> (SessionRow, Date)? in
                guard let item = row.liveItems.first(where: { $0.needsResponse }) else { return nil }
                return (row, item.createdAt)
            }
            .max(by: { $0.1 < $1.1 })
        if let (row, _) = latest {
            TerminalFocus.focus(hint: row.terminalHint, cwd: row.cwd)
        }
    }

    // MARK: - Feed

    private var feed: some View {
        let sections = groupedRows(displayedRows)
        return VStack(spacing: 0) {
            dashboardStrip
            if sections.isEmpty {
                filteredEmptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(sections) { section in
                                groupHeader(section.group, count: section.rows.count)
                                    .padding(.horizontal, 6)
                                ForEach(Array(section.rows.enumerated()), id: \.element.id) { index, row in
                                    if index > 0 { DashedRule().padding(.horizontal, 6) }
                                    sessionLine(row).id(row.id)
                                }
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.bottom, 2)
                    }
                    // Keep the keyboard-selected row on screen as selection walks the list. No
                    // animation: an implicit one here would leak into the MenuBarExtra window.
                    .onChange(of: selectedRowID) { _, id in
                        guard let id else { return }
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
    }

    /// The rows to show, after applying the live-only filter. Ordering (newest-first) is
    /// preserved from the store; grouping re-buckets without disturbing within-group order.
    private var displayedRows: [SessionRow] {
        let rows = queue.sessionRows
        return liveSessionsOnly ? rows.filter(\.isLive) : rows
    }

    /// One state bucket of the grouped roster, identified by its group index for `ForEach`.
    private struct SessionSection: Identifiable {
        let group: Int
        let rows: [SessionRow]
        var id: Int { group }
    }

    /// Buckets rows into the dashboard's three states — needs you (0), working (1), quiet (2)
    /// — dropping empty buckets and keeping the store's newest-first order within each.
    private func groupedRows(_ rows: [SessionRow]) -> [SessionSection] {
        var buckets: [Int: [SessionRow]] = [:]
        for row in rows { buckets[groupOf(row), default: []].append(row) }
        return [0, 1, 2].compactMap { group in
            guard let rows = buckets[group], !rows.isEmpty else { return nil }
            return SessionSection(group: group, rows: rows)
        }
    }

    /// Which dashboard bucket a row's status belongs to (mirrors `dashboardStrip`).
    private func groupOf(_ row: SessionRow) -> Int {
        switch row.status {
        case .permission, .question: return 0
        case .working: return 1
        case .done, .error, .idle: return 2
        }
    }

    /// A section header for a state bucket: its symbol, name, and count, colored to match the
    /// dashboard strip so the roster reads as one grouped overview.
    private func groupHeader(_ group: Int, count: Int) -> some View {
        let (symbol, title, color): (String, String, Color) = {
            switch group {
            case 0: return ("●", "NEEDS YOU", .stPermission)
            case 1: return ("⚙", "WORKING", .stWorking)
            default: return ("○", "IDLE", .feedDim)
            }
        }()
        return HStack(spacing: 6) {
            Text("\(symbol) \(title)")
                .font(feedFont(9.5, .bold))
                .tracking(1)
                .foregroundStyle(color)
            Text("\(count)")
                .font(feedFont(9.5, .bold))
                .foregroundStyle(Color.feedDim)
            Spacer(minLength: 0)
        }
        .padding(.top, 9)
        .padding(.bottom, 1)
    }

    /// Shown when the live-only filter hides every session — the roster isn't empty, it's
    /// just filtered, so point back at the toggle rather than the "no sessions yet" state.
    private var filteredEmptyState: some View {
        VStack(spacing: 6) {
            Text("[ -_- ]")
                .font(feedFont(13, .bold))
                .foregroundStyle(Color.feedDim)
            Text("NO LIVE SESSIONS")
                .font(feedFont(13, .bold))
                .foregroundStyle(Color.feedHead)
            Text("only quiet history · clear the filter to see it")
                .font(feedFont(10.5))
                .foregroundStyle(Color.feedSub)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
    }

    /// A pinned at-a-glance summary of the parallel roster — how many sessions need you, are
    /// working, or are quiet — sitting above the scrolling feed. Read-only, like the rest of
    /// AgentBar: it's the multi-agent overview, not a control surface.
    private var dashboardStrip: some View {
        let summary = queue.dashboardSummary
        return HStack(spacing: 14) {
            summaryStat(symbol: "●", count: summary.needsYou, label: "need you", color: .stPermission)
            summaryStat(symbol: "⚙", count: summary.working, label: "working", color: .stWorking)
            summaryStat(symbol: "○", count: summary.idle, label: "idle", color: .feedDim)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.feedGreen.opacity(0.14)).frame(height: 1)
        }
    }

    /// One `symbol count label` cell of the dashboard strip. A zero count dims to keep the
    /// row's layout stable without drawing the eye to empty buckets.
    private func summaryStat(symbol: String, count: Int, label: String, color: Color) -> some View {
        let active = count > 0
        return HStack(spacing: 4) {
            Text(symbol)
                .font(feedFont(10))
                .foregroundStyle(active ? color : Color.feedDim.opacity(0.5))
            Text("\(count)")
                .font(feedFont(11, .bold))
                .foregroundStyle(active ? Color.feedHead : Color.feedDim)
            Text(label)
                .font(feedFont(10))
                .foregroundStyle(active ? Color.feedSub : Color.feedDim.opacity(0.6))
        }
        .help("\(count) \(label)")
    }

    /// One session row: its status, a title from the transcript, any live hook event folded
    /// in (an ask line, a command box, focus/dismiss keycaps), and a message count. The
    /// title is clickable to bring the session's terminal forward.
    @ViewBuilder
    private func sessionLine(_ row: SessionRow) -> some View {
        let attention = row.liveItems.first { $0.needsResponse }
        VStack(alignment: .leading, spacing: 5) {
            // Header row: timestamp · [project] · STATUS · message count
            HStack(spacing: 6) {
                Text(timeLabel(row.lastActivity))
                    .font(feedFont(10.5))
                    .foregroundStyle(Color.feedDim)
                Text("[\(projectName(row.cwd))]")
                    .font(feedFont(12, .semibold))
                    .foregroundStyle(Color.feedHead)
                    .lineLimit(1)
                StatusTag(status: row.status)
                SourceTag(source: row.source)
                Spacer(minLength: 0)
                if row.messageCount > 0 {
                    Text("\(row.messageCount) msgs")
                        .font(feedFont(10))
                        .foregroundStyle(Color.feedDim)
                }
            }

            // Model · permission mode · context-window usage, read from Claude Code's own
            // transcript and hook events. Only the parts we actually know are shown.
            metaLine(row)

            // Background-work indicators: a running subagent and/or background shell jobs the
            // session has started, read from the transcript.
            jobsLine(row)

            // The session's title (first prompt / summary) — clickable to focus its terminal.
            Button {
                TerminalFocus.focus(hint: row.terminalHint, cwd: row.cwd)
            } label: {
                Text("└─ \(row.title)")
                    .font(feedFont(11))
                    .foregroundStyle(Color.feedText)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            // When nothing is waiting on you, show what the agent is doing (from the
            // transcript) and, for a turn in flight, how long it has been running — the
            // read-only "live agent" view. Activity is tinted blue while working, dim
            // when the session is quiet.
            if attention == nil {
                if let activity = row.activity {
                    Text("⋯ \(activity)")
                        .font(feedFont(10.5))
                        .foregroundStyle(row.status == .working ? Color.stWorking : Color.feedDim)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if row.status == .working, let since = row.workingSince {
                    ElapsedLabel(since: since, color: .stWorking, verb: "working")
                }
            }

            // A live hook event waiting on you in this session, if any.
            if let attention {
                attentionLines(attention)
                ElapsedLabel(since: attention.createdAt, color: attention.feedStatus.color)

                // Command box, for permissions that carry one.
                if let command = commandText(attention) {
                    Text("$ \(command)")
                        .font(feedFont(11, .medium))
                        .foregroundStyle(Color.feedAmberText)
                        .lineLimit(5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                        .background(Color.feedAmber.opacity(0.09))
                        .overlay(
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.feedAmber.opacity(0.3), lineWidth: 1)
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }

            actions(for: row, attention: attention)

            // The expanded activity trail, when this session is toggled open.
            if expandedSessions.contains(row.id), !row.trail.isEmpty {
                trailView(row.trail)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 6)
        .background {
            if row.id == selectedRowID {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.feedGreen.opacity(0.10))
            }
        }
        .overlay(alignment: .leading) {
            if row.id == selectedRowID {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.feedGreen)
                    .frame(width: 2)
                    .padding(.vertical, 6)
            }
        }
        .contentShape(Rectangle())
        // A click anywhere on the row (outside its buttons) selects it for the keyboard.
        .onTapGesture { selectedRowID = row.id }
    }

    /// The "→ …" ask line(s) for an attention item. A multi-question `AskUserQuestion`
    /// renders one line per question so nothing is hidden behind a "(+N more)" summary;
    /// everything else shows its single summary line.
    @ViewBuilder
    private func attentionLines(_ item: PendingItem) -> some View {
        if case .question(let questions) = item.kind, questions.count > 1 {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(questions) { question in
                    Text("→ \(question.question)")
                        .font(feedFont(11, .medium))
                        .foregroundStyle(item.feedStatus.color)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } else {
            Text("→ \(item.summaryLine)")
                .font(feedFont(11, .medium))
                .foregroundStyle(item.feedStatus.color)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Row actions. AgentBar is notify-only, so these focus the terminal, clear a live
    /// prompt row, or mute the project — they never answer for you. Quiet sessions show
    /// focus and mute.
    @ViewBuilder
    private func actions(for row: SessionRow, attention: PendingItem?) -> some View {
        let muted = queue.isMuted(row.cwd)
        HStack(spacing: 10) {
            KeycapButton(key: "↵", label: "focus", style: .focus) { TerminalFocus.focus(hint: row.terminalHint, cwd: row.cwd) }
            if attention != nil {
                KeycapButton(key: "d", label: "dismiss", style: .deny) { dismissLive(row) }
            }
            if !row.cwd.isEmpty {
                KeycapButton(key: muted ? "○" : "m", label: muted ? "muted" : "mute", style: .deny) {
                    queue.toggleMute(row.cwd)
                }
            }
            if !row.trail.isEmpty {
                let open = expandedSessions.contains(row.id)
                KeycapButton(key: open ? "⌄" : "›", label: open ? "hide" : "trail", style: .focus) {
                    toggleTrail(row.id)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 2)
    }

    /// Expands or collapses a session's read-only activity trail in the feed.
    private func toggleTrail(_ sessionID: String) {
        if expandedSessions.contains(sessionID) {
            expandedSessions.remove(sessionID)
        } else {
            expandedSessions.insert(sessionID)
        }
    }

    /// The expanded read-only activity trail: the session's recent actions, newest-first, each
    /// with its timestamp. Parsed from the transcript — the closest read-only analog to
    /// attaching to a running agent, without any control channel.
    @ViewBuilder
    private func trailView(_ trail: [ActivityEntry]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(trail.reversed().enumerated()), id: \.offset) { _, entry in
                HStack(alignment: .top, spacing: 6) {
                    Text(entry.at.map { Self.stamp.string(from: $0) } ?? "··:··:··")
                        .font(feedFont(9.5))
                        .foregroundStyle(Color.feedDim)
                    Text(entry.label)
                        .font(feedFont(10))
                        .foregroundStyle(Color.feedSub)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding(.leading, 12)
        .padding(.top, 3)
        .overlay(alignment: .leading) {
            Rectangle().fill(Color.feedGreen.opacity(0.18)).frame(width: 1)
        }
    }

    /// Clears every live attention row for a session. There is no reply channel back into a
    /// session, so this dismisses the notification once you have answered in the terminal.
    private func dismissLive(_ row: SessionRow) {
        for item in row.liveItems where item.needsResponse {
            queue.dismiss(item)
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("[ ^_^ ]")
                .font(feedFont(13, .bold))
                .foregroundStyle(Color.feedGreen)
                .shadow(color: Color.feedGreen.opacity(0.5), radius: 5)
            Text("NO SESSIONS YET")
                .font(feedFont(14, .bold))
                .foregroundStyle(Color.feedHead)
            Text("start a Claude Code or Copilot session · standing by")
                .font(feedFont(11))
                .foregroundStyle(Color.feedSub)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    // MARK: - Prompt bar

    private var promptBar: some View {
        HStack(spacing: 0) {
            Text("◉ watching \(queue.sessionCount) \(queue.sessionCount == 1 ? "session" : "sessions") · notify-only")
                .font(feedFont(11, .medium))
                .foregroundStyle(Color.feedGreen)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            if !showHistory, !queue.sessionRows.isEmpty {
                Text("↑↓ ↵ d m")
                    .font(feedFont(9))
                    .foregroundStyle(Color.feedDim)
                    .help("Keyboard: ↑/↓ or j/k move · ↵ focus · d dismiss · m mute · → or t trail · esc clear")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.feedGreen.opacity(0.22)).frame(height: 1)
        }
    }

    // MARK: - Item text helpers

    /// A compact time label for a session's last activity: the wall-clock time for today's
    /// sessions, a short month/day for older ones.
    private func timeLabel(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? Self.stamp.string(from: date)
            : Self.dayStamp.string(from: date)
    }

    /// The `$` command box content: the shell command when present, otherwise the pretty
    /// tool input (truncated by the view's line limit). Nil for non-permission rows.
    private func commandText(_ item: PendingItem) -> String? {
        guard case .permission(_, let command, let detail) = item.kind else { return nil }
        if let command { return command }
        return detail.isEmpty ? nil : detail
    }

    private func projectName(_ cwd: String) -> String {
        let name = URL(fileURLWithPath: cwd).lastPathComponent
        return name.isEmpty ? cwd : name
    }

    // MARK: - Background-work indicators (subagent · background jobs)

    /// A row of small indicators for the session's background work: a running subagent and
    /// the count of background shell jobs it has started. Both are read from the transcript
    /// and are gated so a stale signal doesn't linger on a quiet session — the subagent chip
    /// only shows while the session is actively working, the jobs chip only while it is live.
    @ViewBuilder
    private func jobsLine(_ row: SessionRow) -> some View {
        let showSubagent = row.subagentActive && row.status == .working
        let showJobs = row.backgroundJobs > 0 && row.isLive
        if showSubagent || showJobs {
            HStack(spacing: 7) {
                if showSubagent {
                    indicatorChip("⚙ subagent", color: .stWorking)
                        .help("A subagent is running in this session")
                }
                if showJobs {
                    indicatorChip("⇄ \(row.backgroundJobs) bg", color: .feedAmberText)
                        .help("""
                        \(row.backgroundJobs) background \(row.backgroundJobs == 1 ? "job" : "jobs") \
                        started and not killed. AgentBar can't confirm they're still running — \
                        neither the hooks nor the transcript record a background job exiting.
                        """)
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// A small outlined pill for a background-work indicator, styled like `SourceTag`.
    private func indicatorChip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(feedFont(8.5, .bold))
            .tracking(0.3)
            .foregroundStyle(color)
            .padding(.horizontal, 4)
            .padding(.vertical, 1.5)
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .stroke(color.opacity(0.5), lineWidth: 1)
            )
    }

    // MARK: - Session meta (model · mode · context)

    /// The model · mode · context-usage line under a row's header. Renders only the pieces we
    /// actually know, and nothing at all when a row (e.g. a Copilot session) carries none.
    @ViewBuilder
    private func metaLine(_ row: SessionRow) -> some View {
        if row.model != nil || row.mode != nil || row.contextTokens != nil {
            HStack(spacing: 7) {
                if let model = row.model {
                    Text(prettyModel(model))
                        .font(feedFont(9.5))
                        .foregroundStyle(Color.feedSub)
                        .lineLimit(1)
                }
                if let mode = row.mode {
                    Text(prettyMode(mode))
                        .font(feedFont(8.5, .bold))
                        .tracking(0.3)
                        .foregroundStyle(Color.feedInk)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(modeColor(mode))
                        .clipShape(RoundedRectangle(cornerRadius: 2))
                }
                if let tokens = row.contextTokens {
                    Text("ctx \(formatTokens(tokens)) · \(contextPercent(tokens, model: row.model))%")
                        .font(feedFont(9.5))
                        .foregroundStyle(contextColor(tokens, model: row.model))
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// Trims a raw model id (`claude-sonnet-4-5-20250929`) to a compact label (`sonnet-4-5`):
    /// drop the `claude-` prefix and any trailing date/build stamp.
    private func prettyModel(_ raw: String) -> String {
        var name = raw
        if name.hasPrefix("claude-") { name.removeFirst("claude-".count) }
        if let stamp = name.range(of: "-[0-9]{6,}$", options: .regularExpression) {
            name = String(name[name.startIndex..<stamp.lowerBound])
        }
        return name.isEmpty ? raw : name
    }

    /// A short, readable label for a permission mode.
    private func prettyMode(_ raw: String) -> String {
        switch raw {
        case "default": return "default"
        case "plan": return "plan"
        case "acceptEdits": return "accept edits"
        case "bypassPermissions": return "bypass"
        default: return raw
        }
    }

    /// The accent a permission-mode pill is filled with: plan reads as working-blue, accept
    /// edits as done-green, bypass as the loud permission-red, default stays dim.
    private func modeColor(_ raw: String) -> Color {
        switch raw {
        case "plan": return .stWorking
        case "acceptEdits": return .stDone
        case "bypassPermissions": return .stPermission
        default: return .feedDim
        }
    }

    /// A compact token count: `48k`, `1k`, or the raw number under a thousand.
    private func formatTokens(_ tokens: Int) -> String {
        tokens >= 1000 ? "\(Int((Double(tokens) / 1000).rounded()))k" : "\(tokens)"
    }

    /// The nominal context window (tokens) for a model — the denominator of the usage percent.
    /// Most of Claude's models are 200k-token windows; a few (e.g. Opus 4.8) ship a 1M-token
    /// window as standard, and Sonnet 4+ can run 1M under a beta flag. The transcript records
    /// neither the window nor the beta, so: models known to be 1M measure against 1M always;
    /// everything else assumes the 200k standard but promotes to 1M once usage crosses it — a
    /// 200k model can't exceed its window, so anything above 200k (a default-1M model we don't
    /// recognize, or a Sonnet-4+ session on the 1M beta) must be on the larger one.
    private func contextWindow(for model: String?, usedTokens: Int) -> Int {
        let standard = 200_000, large = 1_000_000
        let name = (model ?? "").lowercased()
        if isMillionTokenModel(name) { return large }
        return usedTokens > standard ? large : standard
    }

    /// Models whose standard context window is 1M tokens (not a beta). Opus 4.8 and Sonnet 5
    /// ship 1M.
    private func isMillionTokenModel(_ name: String) -> Bool {
        name.contains("opus-4-8") || name.contains("sonnet-5")
    }

    /// Context usage as a whole-number percent of the model's window, clamped to 0…100.
    private func contextPercent(_ tokens: Int, model: String?) -> Int {
        let window = contextWindow(for: model, usedTokens: tokens)
        return max(0, min(100, Int((Double(tokens) / Double(window) * 100).rounded())))
    }

    /// Dim under three-quarters full, amber past that, red as it approaches the window — a
    /// quiet at-a-glance warning that a session is running low on context.
    private func contextColor(_ tokens: Int, model: String?) -> Color {
        let percent = contextPercent(tokens, model: model)
        if percent >= 90 { return .stPermission }
        if percent >= 75 { return .feedAmberText }
        return .feedDim
    }

    // MARK: - Keyboard navigation

    /// The rows in the exact order they appear in the grouped feed, so ↑/↓ walk the list as
    /// the eye reads it (needs you → working → idle), matching `feed`.
    private var orderedRows: [SessionRow] {
        groupedRows(displayedRows).flatMap(\.rows)
    }

    /// The currently keyboard-selected row, or nil when the selection is empty or stale (its
    /// session has since left the roster).
    private var selectedRow: SessionRow? {
        guard let id = selectedRowID else { return nil }
        return orderedRows.first { $0.id == id }
    }

    /// Installs a local key-event monitor so the popover can be driven from the keyboard while
    /// it is open. Returning nil from the handler consumes the event; returning the event lets
    /// it pass through (so ⌘-shortcuts and anything we don't handle behave normally).
    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        // Local key-down monitors are always delivered on the main thread, so we can assert
        // main-actor isolation and run the handler synchronously — that lets it touch the
        // (main-actor) queue and focus the terminal while still returning nil/event to decide
        // whether the key is swallowed.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // assumeIsolated returns a Sendable Bool (NSEvent isn't Sendable); map it to
            // nil (swallow) / event (pass through) outside the isolated block.
            let handled = MainActor.assumeIsolated { handleKey(event) }
            return handled ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
    }

    /// Routes a key press to a navigation move or a row action. Returns true when the event was
    /// handled (and should be swallowed). Only acts on the live session feed — the history view
    /// and any modifier-chorded key are left alone.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard !showHistory else { return false }
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.isDisjoint(with: [.command, .control, .option]) else { return false }

        let rows = orderedRows
        switch event.keyCode {
        case 125: moveSelection(by: 1, in: rows); return true    // ↓
        case 126: moveSelection(by: -1, in: rows); return true   // ↑
        case 36, 76: return focusSelected(in: rows)              // return / enter
        case 124: return toggleTrailSelected()                   // →
        case 53:                                                 // esc
            if selectedRowID != nil { selectedRowID = nil; return true }
            return false
        default: break
        }

        guard let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        switch key {
        case "j": moveSelection(by: 1, in: rows); return true
        case "k": moveSelection(by: -1, in: rows); return true
        case "d": return dismissSelected()
        case "m": return muteSelected()
        case "t": return toggleTrailSelected()
        default: return false
        }
    }

    /// Moves the selection by `delta` rows, clamped to the ends. With nothing selected yet, a
    /// downward move lands on the first row and an upward move on the last.
    private func moveSelection(by delta: Int, in rows: [SessionRow]) {
        guard !rows.isEmpty else { selectedRowID = nil; return }
        guard let current = selectedRowID, let index = rows.firstIndex(where: { $0.id == current }) else {
            selectedRowID = (delta > 0 ? rows.first : rows.last)?.id
            return
        }
        let next = max(0, min(rows.count - 1, index + delta))
        selectedRowID = rows[next].id
    }

    /// ↵ / click-equivalent: bring the selected row's terminal forward. With nothing selected,
    /// selects and focuses the first row so a bare ↵ does the obvious thing.
    private func focusSelected(in rows: [SessionRow]) -> Bool {
        guard let row = selectedRow ?? rows.first else { return true }
        selectedRowID = row.id
        TerminalFocus.focus(hint: row.terminalHint, cwd: row.cwd)
        return true
    }

    /// `d`: dismiss the selected row's live attention rows, mirroring the row's dismiss keycap.
    private func dismissSelected() -> Bool {
        if let row = selectedRow, row.liveItems.contains(where: { $0.needsResponse }) {
            dismissLive(row)
        }
        return true
    }

    /// `m`: mute / unmute the selected row's project, mirroring the row's mute keycap.
    private func muteSelected() -> Bool {
        if let row = selectedRow, !row.cwd.isEmpty {
            queue.toggleMute(row.cwd)
        }
        return true
    }

    /// `→` / `t`: expand or collapse the selected row's read-only activity trail.
    private func toggleTrailSelected() -> Bool {
        if let row = selectedRow, !row.trail.isEmpty {
            toggleTrail(row.id)
        }
        return true
    }
}

/// Exposes the hosting `NSWindow` so the popover can pin its own top edge. `trigger` is a
/// value that changes when we need `updateNSView` to re-run (the popover height); the window
/// lookup is deferred to the next runloop tick so the frame reflects the new content size.
private struct WindowReader: NSViewRepresentable {
    let trigger: Double
    let onLayout: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        let onLayout = self.onLayout
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            onLayout(window)
        }
    }
}
