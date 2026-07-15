import SwiftUI
import AppKit
import UserNotifications

/// The "Setup" section at the top of Settings: a self-diagnosis of the notify pipeline so a
/// user who sees "no sessions yet" can tell *why* nothing notifies — the plugin isn't
/// installed, notifications were denied, the local server didn't bind, etc.
///
/// This lives in the standard macOS settings `Form`, so it uses native styling (SF Symbols
/// status glyphs, secondary detail text) rather than the popover's phosphor theme. Each check
/// is a small row with a glyph, a title, a one-line detail, and — where the user can act — a
/// button that copies the fix or opens the right System Settings pane.
///
/// The signals come from `AppState.shared`: the live server port, the per-agent last-hook
/// timestamps (`QueueStore`), the notification authorization state (`NotificationManager`),
/// the Accessibility trust state (`TerminalFocus`), and a file check for the Copilot bridge.
/// The two `ObservableObject`s are observed so the section re-renders when the port or a hook
/// timestamp changes; the async / file-system checks are re-read on a light interval while the
/// pane is open.
struct SetupSection: View {
    @ObservedObject private var appState = AppState.shared
    @ObservedObject private var queue = AppState.shared.queue

    /// Notification authorization, re-read asynchronously by `refresh`.
    @State private var notifStatus: UNAuthorizationStatus = .notDetermined
    /// Accessibility trust, re-read synchronously by `refresh` (non-prompting).
    @State private var isTrusted = TerminalFocus.isTrusted
    /// Whether the Copilot hook bridge file is installed, re-read by `refresh`.
    @State private var copilotInstalled = SetupChecks.copilotHooksInstalled
    /// The clock the relative-time labels ("2m ago") render against. Bumped by `refresh` so
    /// the labels age even when no new hook arrives to change `lastHookAt`.
    @State private var now = Date()

    var body: some View {
        Section("Setup") {
            serverRow
            claudeRow
            notificationsRow
            accessibilityRow
            copilotRow
        }
        // Refresh on appear and on a light interval while the pane is visible, mirroring
        // QueueView's `.task` loop. `.task` runs the body immediately on appear and is
        // cancelled on disappear, so nothing polls while Settings is closed.
        .task {
            while !Task.isCancelled {
                await refresh()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    // MARK: - Rows

    /// 1. Local server — bound and listening, or not running (hooks can't reach the app).
    @ViewBuilder
    private var serverRow: some View {
        if let port = appState.serverPort {
            row(.pass, title: "Local server", detail: "Listening on 127.0.0.1:\(port)")
        } else {
            row(.fail, title: "Local server",
                detail: "Not running — hooks can't reach the app. Try relaunching AgentBar.")
        }
    }

    /// 2. Claude Code plugin — pass once any Claude hook has been heard; otherwise the install
    /// commands with a Copy button.
    @ViewBuilder
    private var claudeRow: some View {
        if let last = queue.lastHookAt(for: .claude) {
            row(.pass, title: "Claude Code plugin",
                detail: "Last event \(SetupChecks.relativeAgo(from: last, to: now))")
        } else {
            row(.fail, title: "Claude Code plugin",
                detail: "Never heard from. In Claude Code run:\n\(SetupChecks.claudeInstallCommands)") {
                Button("Copy") { copyToPasteboard(SetupChecks.claudeInstallCommands) }
                    .controlSize(.small)
            }
        }
    }

    /// 3. Notifications — allowed, denied (with a jump to System Settings), or not yet requested.
    @ViewBuilder
    private var notificationsRow: some View {
        switch notifStatus {
        case .authorized, .provisional:
            row(.pass, title: "Notifications", detail: "Banners allowed")
        case .denied:
            row(.fail, title: "Notifications", detail: "Denied — banners will never appear") {
                openSettingsButton("x-apple.systempreferences:com.apple.preference.notifications")
            }
        default:
            // .notDetermined / .ephemeral / anything future: neutral, not a failure.
            row(.optional, title: "Notifications", detail: "Not requested yet")
        }
    }

    /// 4. Accessibility (optional) — window-precise focus. Never red: focus still works app-wide
    /// without it, so an ungranted state is neutral, not a failure.
    @ViewBuilder
    private var accessibilityRow: some View {
        if isTrusted {
            row(.pass, title: "Accessibility (optional)", detail: "Window-precise focus enabled")
        } else {
            row(.optional, title: "Accessibility (optional)",
                detail: "Optional — lets Focus raise the exact project window. Grant in System Settings.") {
                openSettingsButton("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
            }
        }
    }

    /// 5. Copilot hooks (optional) — installed and heard from, installed but quiet, or not
    /// installed (with the one-liner to install it).
    @ViewBuilder
    private var copilotRow: some View {
        if copilotInstalled {
            if let last = queue.lastHookAt(for: .copilot) {
                row(.pass, title: "Copilot hooks (optional)",
                    detail: "Last event \(SetupChecks.relativeAgo(from: last, to: now))")
            } else {
                row(.optional, title: "Copilot hooks (optional)",
                    detail: "Installed — no events yet (restart Copilot sessions)")
            }
        } else {
            row(.optional, title: "Copilot hooks (optional)",
                detail: "Optional — run `make install-copilot` to watch Copilot CLI sessions.")
        }
    }

    // MARK: - Row building

    /// A check row with no action controls — forwards to the builder form with an empty
    /// trailing view. (A separate overload rather than a defaulted generic parameter, which is
    /// finicky to spell.)
    private func row(_ status: SetupStatus, title: String, detail: String) -> some View {
        row(status, title: title, detail: detail) { EmptyView() }
    }

    /// A single check row: a status glyph, a title, a wrapped detail line, and any action
    /// controls beneath it.
    private func row<Actions: View>(
        _ status: SetupStatus,
        title: String,
        detail: String,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: status.symbol)
                .foregroundStyle(status.color)
                .imageScale(.large)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                actions()
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    /// A small "Open System Settings" button that deep-links to a preferences pane.
    private func openSettingsButton(_ urlString: String) -> some View {
        Button("Open System Settings") { openURL(urlString) }
            .controlSize(.small)
    }

    // MARK: - Side effects

    private func openURL(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    private func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Re-reads the checks that aren't published: the async notification state, and the sync
    /// Accessibility / Copilot-file reads. Also bumps `now` so the relative-time labels age.
    private func refresh() async {
        notifStatus = await appState.notifications.authorizationStatus()
        isTrusted = TerminalFocus.isTrusted
        copilotInstalled = SetupChecks.copilotHooksInstalled
        now = Date()
    }
}

/// The three status tiers a Setup row can show, mapped to native SF Symbols and colors:
/// a green check for pass, a red cross for a real failure, and a neutral open circle for an
/// optional/unknown state that isn't a problem.
private enum SetupStatus {
    case pass
    case fail
    case optional

    var symbol: String {
        switch self {
        case .pass: return "checkmark.circle.fill"
        case .fail: return "xmark.circle.fill"
        case .optional: return "circle"
        }
    }

    var color: Color {
        switch self {
        case .pass: return .green
        case .fail: return .red
        case .optional: return .secondary
        }
    }
}

/// Pure, side-effect-light helpers behind the Setup rows, split out so the logic is unit
/// testable without a view. `copilotHooksInstalled` touches the filesystem; `relativeAgo` is
/// pure.
enum SetupChecks {
    /// The two commands that install the Claude Code plugin, one per line — shown in the
    /// "never heard from" detail and copied by the row's Copy button.
    static let claudeInstallCommands = """
    /plugin marketplace add jreed91/agentbar
    /plugin install agentbar@agentbar
    """

    /// Whether the Copilot hook bridge (`~/.copilot/hooks/agentbar.json`, written by
    /// `make install-copilot`) is present.
    static var copilotHooksInstalled: Bool {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".copilot/hooks/agentbar.json")
        return FileManager.default.fileExists(atPath: url.path)
    }

    /// A compact "how long ago" phrase for a hook timestamp: `just now`, `12s ago`, `2m ago`,
    /// `3h ago`, `2d ago`. Pure so it can be unit-tested; a future/zero interval reads as
    /// "just now" rather than a negative value.
    static func relativeAgo(from date: Date, to now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 5 { return "just now" }
        if seconds < 60 { return "\(Int(seconds))s ago" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        return "\(hours / 24)d ago"
    }
}
