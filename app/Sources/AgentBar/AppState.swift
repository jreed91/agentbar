import Foundation
import Combine

/// Shared singleton that wires the queue, HTTP server, and notification manager together.
@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()

    let queue = QueueStore()
    let server = HookServer()
    let notifications = NotificationManager()

    /// Owns the process-wide global hotkeys. Held for the app's lifetime so its single Carbon
    /// event handler is installed once and never torn down (see `HotKeyCenter`).
    let hotKeys = HotKeyCenter()

    /// The loopback port the hook server is currently listening on, or nil when it isn't
    /// running. Published from `HookServer`'s listener state (via `setServerPort`) so the
    /// Setup panel's "Local server" check reflects the live pipeline rather than the last
    /// value written to `server.json`.
    @Published private(set) var serverPort: UInt16?

    private init() {
        registerDefaults()
        queue.notificationManager = notifications
        // Route hotkey presses through `perform`. Set here (not in `start`) so the wiring is in
        // place before any registration; the closure is `@MainActor`, matching Carbon's
        // main-thread dispatch, so it can touch the queue and focus without hopping.
        hotKeys.onAction = { [weak self] action in
            self?.perform(action)
        }
    }

    /// Records the hook server's listening port (or nil when it stops). Called by
    /// `HookServer` from its listener-state handler, which hops to the main actor first.
    func setServerPort(_ port: UInt16?) {
        serverPort = port
    }

    /// Called from the app delegate on launch.
    func start() {
        notifications.setup()
        server.start()
        registerPersistedHotKeys()
    }

    // MARK: - Global hotkeys

    /// Registers every persisted shortcut. Both actions are unset by default, so a fresh
    /// install registers nothing — global hotkeys that steal chords out of the box are rude.
    private func registerPersistedHotKeys() {
        for action in HotKeyAction.allCases {
            if let shortcut = shortcut(for: action) {
                hotKeys.register(shortcut, id: action)
            }
        }
    }

    /// Records `shortcut` for `action` (nil clears it), persisting it and re-registering the
    /// live hotkey so a change in Settings takes effect immediately. The single mutation path
    /// for hotkeys — the Settings recorder calls this and nothing else touches persistence or
    /// registration.
    func setShortcut(_ shortcut: Shortcut?, for action: HotKeyAction) {
        if let shortcut {
            if let data = try? JSONEncoder().encode(shortcut) {
                UserDefaults.standard.set(data, forKey: action.defaultsKey)
            }
            hotKeys.register(shortcut, id: action)
        } else {
            UserDefaults.standard.removeObject(forKey: action.defaultsKey)
            hotKeys.unregister(action)
        }
    }

    /// The persisted shortcut for `action`, or nil when unset or undecodable (a stale/corrupt
    /// value degrades to "not set" rather than throwing).
    func shortcut(for action: HotKeyAction) -> Shortcut? {
        guard let data = UserDefaults.standard.data(forKey: action.defaultsKey) else { return nil }
        return try? JSONDecoder().decode(Shortcut.self, from: data)
    }

    /// Runs a fired hotkey action on the main actor. Kept thin: the popover toggle is delegated
    /// to `PopoverToggle`, the focus jump to `QueueStore`, so `AppState` stays a wire.
    private func perform(_ action: HotKeyAction) {
        switch action {
        case .togglePopover:
            PopoverToggle.toggle()
        case .focusNeedsMe:
            // Deliberately the longest-waiting prompt, not the newest (which the popover hero
            // jumps to) — this is a press-without-looking backlog tool. No attention pending
            // stays silent: nothing to focus, no beep.
            if let row = queue.longestWaitingAttentionRow() {
                TerminalFocus.focus(hint: row.terminalHint, cwd: row.cwd)
            }
        }
    }

    /// Called from the app delegate on termination; removes server.json.
    func stop() {
        server.stop()
    }

    private func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            "notifyQuestions": true,
            "notifyPermissions": true,
            "notifyElicitations": true,
            "notifyWorking": true,
            "notifyIdle": true,
            "notifyTaskFinished": true,
            "notifySubagent": true,
            "notifySessionEnd": true,
            "notifyErrors": true,
            "playSound": true,
            "distinctSounds": false,
            "dndEnabled": false,
            "dndStartHour": 22,
            "dndEndHour": 8,
            "debugLogging": false,
            "infoExpirySeconds": 25.0
        ])
    }
}
