import AppKit
import ApplicationServices

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

    /// Brings the session's terminal / IDE forward. When Accessibility is granted and we
    /// know the session's working directory, it raises the *specific* window whose title
    /// matches the project — so the right window comes forward even when many are open.
    /// Without that (permission not granted, no cwd, or no title match) it degrades to
    /// activating the whole app, exactly as before.
    @MainActor
    static func focus(hint: TerminalHint? = nil, cwd: String? = nil) {
        // The app(s) that might host this session: the hinted one when we have a hint,
        // otherwise every running terminal / editor we know about (so a scanned/idle row
        // with no hint can still be matched by its working directory below).
        let apps: [NSRunningApplication]
        if let bundleID = resolve(hint), let app = running(bundleID) {
            apps = [app]
        } else {
            apps = bundleIDs.compactMap { running($0) }
        }
        guard !apps.isEmpty else { return }

        // Precise path: raise the exact window for this session's project.
        if let cwd, !cwd.isEmpty, ensureTrusted() {
            for app in apps where raiseWindow(matchingProjectAt: cwd, pid: app.processIdentifier) {
                app.activate(options: [])
                return
            }
        }

        // Fallback: bring the most likely app forward with all its windows.
        apps.first?.activate(options: [.activateAllWindows])
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

    /// The running instance of a bundle id, if any.
    @MainActor
    private static func running(_ bundleID: String) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    }

    // MARK: - Accessibility (window-level focus)

    /// Whether AgentBar currently has Accessibility permission, *without* prompting. This is
    /// the read-only signal for the Setup panel's optional Accessibility check — distinct from
    /// `ensureTrusted`, which shows the system permission dialog as a side effect and so must
    /// never be called just to display status.
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Whether AgentBar has Accessibility permission, prompting once if not. Returns the
    /// current trust state; when false the caller degrades to app-level activation, so focus
    /// keeps working (less precisely) until the user grants it in System Settings.
    @MainActor
    private static func ensureTrusted() -> Bool {
        if AXIsProcessTrusted() { return true }
        // The literal value of `kAXTrustedCheckOptionPrompt`; used directly because that
        // constant's Swift import shape (Unmanaged<CFString> vs CFString) varies by SDK.
        let options: NSDictionary = ["AXTrustedCheckOptionPrompt": true]
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Raises the first window of `pid` whose title contains the project — the last path
    /// component of `cwd`. Terminals and editors put the working directory / open folder in
    /// their window or tab title, so this singles out the session's own window among many.
    /// Requires Accessibility; returns false when unavailable or nothing matches.
    private static func raiseWindow(matchingProjectAt cwd: String, pid: pid_t) -> Bool {
        let project = URL(fileURLWithPath: cwd).lastPathComponent
        guard !project.isEmpty else { return false }

        let app = AXUIElementCreateApplication(pid)
        var windowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsValue) == .success,
              let windows = windowsValue as? [AXUIElement] else {
            return false
        }

        for window in windows {
            var titleValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue) == .success,
                  let title = titleValue as? String,
                  title.localizedCaseInsensitiveContains(project) else {
                continue
            }
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            return true
        }
        return false
    }
}
