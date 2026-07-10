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
        "com.todesktop.230313mzl4w4u92", // Cursor
        "dev.zed.Zed",                  // Zed
        "com.jetbrains.WebStorm",       // WebStorm
        "com.jetbrains.intellij",       // IntelliJ IDEA Ultimate
        "com.jetbrains.intellij.ce",    // IntelliJ IDEA Community
        "com.jetbrains.rider"           // Rider
    ]

    /// Brings a terminal / editor forward. When `preferred` names the app that actually
    /// hosts the session (captured from the hook environment), that app is activated
    /// directly — so the right window comes forward even when several terminals are open.
    /// Falls back to the first running app in the priority list.
    @MainActor
    static func focus(preferred bundleID: String? = nil) {
        if let bundleID, !bundleID.isEmpty,
           let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            app.activate(options: [.activateAllWindows])
            return
        }
        for bundleID in bundleIDs {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
                app.activate(options: [.activateAllWindows])
                return
            }
        }
    }

    /// Maps a `TERM_PROGRAM` value (a coarse fallback when the host bundle id is absent)
    /// to a bundle id. Ambiguous cases like VSCode/Cursor both reporting `vscode` are why
    /// the hook prefers `__CFBundleIdentifier`; this is only a backstop.
    static func bundleID(forTermProgram term: String?) -> String? {
        switch term {
        case "iTerm.app": return "com.googlecode.iterm2"
        case "Apple_Terminal": return "com.apple.Terminal"
        case "WarpTerminal": return "dev.warp.Warp-Stable"
        case "ghostty": return "com.mitchellh.ghostty"
        case "WezTerm": return "com.github.wez.wezterm"
        case "vscode": return "com.microsoft.VSCode"
        default: return nil
        }
    }
}
