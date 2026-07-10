import AppKit

/// Best-effort focus of the user's terminal / editor. For notify-only events (idle / task
/// finished) there is nothing to answer — we just bring the session's window back.
enum TerminalFocus {
    /// Known terminal / editor bundle identifiers, in priority order. Used as the fallback
    /// when a session carries no usable terminal hint.
    static let bundleIDs = [
        "com.googlecode.iterm2",         // iTerm2
        "com.apple.Terminal",            // Terminal.app
        "dev.warp.Warp-Stable",          // Warp
        "net.kovidgoyal.kitty",          // kitty
        "com.github.wez.wezterm",        // WezTerm
        "com.mitchellh.ghostty",         // Ghostty
        "com.microsoft.VSCode",          // Visual Studio Code
        "com.todesktop.230313mzl4w4u92", // Cursor
        "dev.zed.Zed",                   // Zed
    ] + jetBrainsBundleIDs

    /// JetBrains (and Android Studio) IDEs — all use the JediTerm terminal, which reports
    /// `TERMINAL_EMULATOR=JetBrains-JediTerm`. When a session's terminal is JediTerm but we
    /// can't tell which IDE, we activate the first of these that is running.
    static let jetBrainsBundleIDs = [
        "com.jetbrains.WebStorm",
        "com.jetbrains.intellij",
        "com.jetbrains.intellij.ce",
        "com.jetbrains.pycharm",
        "com.jetbrains.pycharm.ce",
        "com.jetbrains.PhpStorm",
        "com.jetbrains.goland",
        "com.jetbrains.rubymine",
        "com.jetbrains.CLion",
        "com.jetbrains.datagrip",
        "com.jetbrains.rider",
        "com.jetbrains.rustrover",
        "com.google.android.studio",
    ]

    /// Brings the session's terminal / IDE forward. Resolves the hint to a concrete running
    /// app (preferring signals the terminal sets itself over `__CFBundleIdentifier`, which
    /// can be stale); falls back to the first running app in the priority list.
    @MainActor
    static func focus(hint: TerminalHint? = nil) {
        if let bundleID = resolve(hint), activate(bundleID) {
            return
        }
        for bundleID in bundleIDs where activate(bundleID) {
            return
        }
    }

    /// Resolves a terminal hint to a bundle id, in order of signal reliability.
    @MainActor
    private static func resolve(_ hint: TerminalHint?) -> String? {
        guard let hint, !hint.isEmpty else { return nil }

        // 1. JediTerm (JetBrains / Android Studio). TERMINAL_EMULATOR is set by the IDE
        //    itself, so it is trustworthy even when __CFBundleIdentifier points at whatever
        //    launched the IDE (e.g. iTerm). Use the bundle id only if it is itself a
        //    JetBrains/Studio id; otherwise activate whichever such IDE is running.
        if let emu = hint.termEmulator, emu.contains("JediTerm") || emu.contains("JetBrains") {
            if let cf = hint.cfBundleID, isJetBrains(cf) {
                return cf
            }
            if let running = firstRunning(jetBrainsBundleIDs) {
                return running
            }
        }

        // 2. TERM_PROGRAM, set by the actual terminal that spawned the shell.
        if let id = bundleID(forTermProgram: hint.termProgram) {
            return id
        }

        // 3. Last resort: the launching app's bundle id (may be stale).
        if let cf = hint.cfBundleID, !cf.isEmpty {
            return cf
        }
        return nil
    }

    /// Maps a `TERM_PROGRAM` value to a bundle id. VSCode/Cursor both report `vscode`; the
    /// disambiguation there relies on `__CFBundleIdentifier`, handled by the caller.
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

    private static func isJetBrains(_ bundleID: String) -> Bool {
        bundleID.hasPrefix("com.jetbrains") || bundleID == "com.google.android.studio"
    }

    @MainActor
    private static func firstRunning(_ ids: [String]) -> String? {
        ids.first { !NSRunningApplication.runningApplications(withBundleIdentifier: $0).isEmpty }
    }

    /// Activates the running app with the given bundle id; returns false if none is running.
    @MainActor
    private static func activate(_ bundleID: String) -> Bool {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            return false
        }
        app.activate(options: [.activateAllWindows])
        return true
    }
}
