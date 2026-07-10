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

    /// User-resizable popover dimensions, persisted across launches. Width applies to the
    /// whole popover; height caps the scrollable feed.
    @AppStorage("popoverWidth") private var popoverWidth = 340.0
    @AppStorage("popoverFeedHeight") private var feedHeight = 290.0

    /// Size at the start of a resize drag, so `translation` can be applied to a fixed base.
    @State private var resizeBaseWidth: Double?
    @State private var resizeBaseHeight: Double?

    private let minWidth = 300.0, maxWidth = 620.0
    private let minFeedHeight = 160.0, maxFeedHeight = 760.0

    /// One shared formatter for feed timestamps (HH:mm:ss).
    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            titleBar
            hero
            if queue.items.isEmpty {
                emptyState
            } else {
                feed
            }
            promptBar
        }
        .frame(width: popoverWidth)
        .background(Color.feedBG)
        .overlay(ScanlineOverlay())
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .stroke(Color.feedGreen.opacity(0.4), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(alignment: .bottomLeading) { resizeGrip }
    }

    // MARK: - Resize grip

    /// A drag handle in the bottom-leading corner (the popover is anchored to the menu-bar
    /// icon at the top-right, so this is the free corner). Dragging it resizes the popover
    /// live; the size is persisted.
    private var resizeGrip: some View {
        ResizeGripShape()
            .fill(Color.feedDim)
            .frame(width: 12, height: 12)
            .padding(6)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if resizeBaseWidth == nil {
                            resizeBaseWidth = popoverWidth
                            resizeBaseHeight = feedHeight
                        }
                        let baseW = resizeBaseWidth ?? popoverWidth
                        let baseH = resizeBaseHeight ?? feedHeight
                        // Anchored top-right: dragging left widens, dragging down grows.
                        popoverWidth = min(maxWidth, max(minWidth, baseW - value.translation.width))
                        feedHeight = min(maxFeedHeight, max(minFeedHeight, baseH + value.translation.height))
                    }
                    .onEnded { _ in
                        resizeBaseWidth = nil
                        resizeBaseHeight = nil
                    }
            )
            .onHover { hovering in
                if hovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
            }
            .help("Drag to resize")
    }

    // MARK: - Title bar

    private var titleBar: some View {
        HStack(spacing: 8) {
            TrafficDots()
            Text("claude-watch — \(queue.sessionCount) \(queue.sessionCount == 1 ? "session" : "sessions")")
                .font(feedFont(10.5))
                .foregroundStyle(Color.feedSub)
                .lineLimit(1)
            Spacer(minLength: 8)
            LiveBadge()
            settingsGear
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(Color.feedGreen.opacity(0.05))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.feedGreen.opacity(0.22)).frame(height: 1)
        }
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
    }

    // MARK: - Feed

    private var feed: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(sortedItems.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { DashedRule() }
                    feedLine(item)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 2)
        }
        .frame(maxHeight: feedHeight)
    }

    private var sortedItems: [PendingItem] {
        queue.items.sorted { $0.createdAt > $1.createdAt }
    }

    @ViewBuilder
    private func feedLine(_ item: PendingItem) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            // Header row: timestamp · [project] · STATUS
            HStack(spacing: 6) {
                Text(Self.stamp.string(from: item.createdAt))
                    .font(feedFont(10.5))
                    .foregroundStyle(Color.feedDim)
                Text("[\(projectName(item.cwd))]")
                    .font(feedFont(12, .semibold))
                    .foregroundStyle(Color.feedHead)
                    .lineLimit(1)
                StatusTag(status: item.feedStatus)
                Spacer(minLength: 0)
            }

            // The ask line — clickable to bring the terminal forward.
            Button {
                TerminalFocus.focus(preferred: item.hostBundleID)
            } label: {
                Text("└─ \(askText(item))")
                    .font(feedFont(11))
                    .foregroundStyle(Color.feedText)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            // Command box, for permissions that carry one.
            if let command = commandText(item) {
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

            actions(for: item)
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func actions(for item: PendingItem) -> some View {
        HStack(spacing: 10) {
            if item.needsResponse {
                KeycapButton(key: "↵", label: "focus", style: .focus) { TerminalFocus.focus(preferred: item.hostBundleID) }
                KeycapButton(key: "d", label: "dismiss", style: .deny) { queue.dismiss(item) }
            } else {
                KeycapButton(key: "d", label: "dismiss", style: .deny) { queue.dismiss(item) }
                KeycapButton(key: "↵", label: "focus", style: .focus) { TerminalFocus.focus(preferred: item.hostBundleID) }
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 2)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("[ ^_^ ]")
                .font(feedFont(13, .bold))
                .foregroundStyle(Color.feedGreen)
                .shadow(color: Color.feedGreen.opacity(0.5), radius: 5)
            Text("ALL CAUGHT UP")
                .font(feedFont(14, .bold))
                .foregroundStyle(Color.feedHead)
            Text("0 pending · standing by")
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

    private func askText(_ item: PendingItem) -> String {
        switch item.kind {
        case .question(let questions):
            let first = questions.first?.question ?? "Claude has a question."
            let extra = questions.count - 1
            return extra > 0 ? "\(first) (+\(extra) more)" : first
        case .permission(let toolName, _, _):
            return "Wants to run \(toolName)"
        case .elicitation(let request):
            return request.message
        case .info(_, _, let body):
            return body
        }
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
