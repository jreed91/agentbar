import AppKit

/// Opens (or closes) the menu-bar popover by synthesizing a click on the status-bar button —
/// the exact path a real click takes. Going through the button reuses every bit of AgentBar's
/// popover anchoring and toggles naturally: clicking an open popover closes it, so the global
/// "Open AgentBar" hotkey is a true toggle.
///
/// SwiftUI's `MenuBarExtra` exposes no public "open" API, so the button is reached through a
/// private KVC hop: the framework parks an `NSStatusItem` on its `NSStatusBarWindow` under the
/// key `"statusItem"`. That key is undocumented and a future macOS could rename it — which is
/// why every step below is defensive: the class is matched by name, the KVC read is guarded by
/// `responds(to:)` (so an unknown key degrades to nil rather than raising an
/// `NSUndefinedKeyException`), and the result is `as?`-cast, never force-cast. If any step
/// fails the whole thing is a logged no-op. This private-API reliance is acceptable for a
/// non-App-Store Homebrew build; on an OS that renamed the key the hotkey simply stops opening
/// the popover instead of crashing.
@MainActor
enum PopoverToggle {
    /// Toggles the popover, or logs and does nothing if the status-bar button can't be found.
    static func toggle() {
        guard let button = statusBarButton() else {
            DebugLog.log("PopoverToggle: status-bar button not found; toggle is a no-op")
            return
        }
        // Carbon dispatches the hotkey on the main thread, so this click runs on the main
        // thread as required for AppKit.
        button.performClick(nil)
    }

    /// Best-effort lookup of our status item's button. Returns nil — never crashes — if the
    /// window is gone, the private key was renamed, or the parked object isn't the type we
    /// expect.
    private static func statusBarButton() -> NSStatusBarButton? {
        let key = "statusItem"
        for window in NSApp.windows where isStatusBarWindow(window) {
            // `responds(to:)` gates the KVC read: `value(forKey:)` raises an Objective-C
            // exception for an undefined key (which Swift can't catch cleanly), so we only
            // read it when a getter actually exists. The `as?` chain then fails safely if the
            // parked object's type ever changes.
            guard window.responds(to: NSSelectorFromString(key)) else { continue }
            if let statusItem = window.value(forKey: key) as? NSStatusItem,
               let button = statusItem.button {
                return button
            }
        }
        return nil
    }

    /// Whether `window` is the (private) `NSStatusBarWindow` class, matched by name so no
    /// private symbol is referenced directly.
    private static func isStatusBarWindow(_ window: NSWindow) -> Bool {
        String(describing: type(of: window)).contains("NSStatusBarWindow")
    }
}
