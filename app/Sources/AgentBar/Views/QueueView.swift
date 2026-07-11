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
        })
        .onDisappear { anchorTop = nil }
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
            Text("claude-watch — \(queue.sessionRows.count) \(queue.sessionRows.count == 1 ? "session" : "sessions")")
                .font(feedFont(10.5))
                .foregroundStyle(Color.feedSub)
                .lineLimit(1)
            Spacer(minLength: 8)
            LiveBadge()
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
        VStack(spacing: 0) {
            dashboardStrip
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(queue.sessionRows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { DashedRule() }
                        sessionLine(row)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 2)
            }
        }
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
                Spacer(minLength: 0)
                if row.messageCount > 0 {
                    Text("\(row.messageCount) msgs")
                        .font(feedFont(10))
                        .foregroundStyle(Color.feedDim)
                }
            }

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

            // What the agent is doing, read from the transcript — shown only when nothing is
            // waiting on you (an attention line below would otherwise say it better). Tinted
            // blue while working, dim when the session is quiet.
            if attention == nil, let activity = row.activity {
                Text("⋯ \(activity)")
                    .font(feedFont(10.5))
                    .foregroundStyle(row.status == .working ? Color.stWorking : Color.feedDim)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            // A live hook event waiting on you in this session, if any.
            if let attention {
                attentionLines(attention)
                WaitingLabel(since: attention.createdAt, color: attention.feedStatus.color)

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
        }
        .padding(.vertical, 8)
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
            Spacer(minLength: 0)
        }
        .padding(.top, 2)
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
            Text("start a Claude Code session · standing by")
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
            Spacer(minLength: 0)
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
