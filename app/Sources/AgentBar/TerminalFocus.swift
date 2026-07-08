import AppKit

/// Best-effort focus of the user's terminal app for notify-only events (idle / task
/// finished), where there is nothing to answer — we just bring them back to the session.
enum TerminalFocus {
    /// Known terminal / editor bundle identifiers, in priority order.
    static let bundleIDs = [
        "com.googlecode.iterm2",        // iTerm2
        "com.apple.Terminal",           // Terminal.app
        "dev.warp.Warp-Stable",         // Warp
        "net.kovidgoyal.kitty",         // kitty
        "com.github.wez.wezterm",       // WezTerm
        "com.mitchellh.ghostty",        // Ghostty
        "com.microsoft.VSCode",         // Visual Studio Code
        "com.todesktop.230313mzl4w4u92" // Cursor
    ]

    @MainActor
    static func focus() {
        for bundleID in bundleIDs {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
                app.activate(options: [.activateAllWindows])
                return
            }
        }
    }
}
