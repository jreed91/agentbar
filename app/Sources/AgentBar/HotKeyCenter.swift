import AppKit
import Carbon.HIToolbox

/// A recorded global keyboard shortcut: a hardware-independent virtual key code plus the
/// modifier mask it must be pressed with. Persisted per action as JSON and rendered as
/// key-symbol text in Settings.
///
/// Modifiers are stored as an `NSEvent.ModifierFlags.rawValue`, but narrowed on the way in
/// (see `init`) to just the four we honour — ⌘⌃⌥⇧ — so a persisted value can never smuggle in
/// caps-lock/fn bits that would make an otherwise-equal chord compare unequal. The key code is
/// the `UInt16` that `NSEvent.keyCode` reports; Carbon's `RegisterEventHotKey` wants a `UInt32`,
/// so `HotKeyCenter` widens it at registration time.
struct Shortcut: Codable, Equatable {
    /// The virtual key code (`kVK_*`), as reported by `NSEvent.keyCode`.
    let keyCode: UInt16
    /// The modifier mask as `NSEvent.ModifierFlags.rawValue`, already narrowed to ⌘⌃⌥⇧.
    let rawModifiers: UInt

    /// The four modifiers a global shortcut may carry. Everything else (caps lock, fn, the
    /// device-dependent left/right variants) is discarded so equality and display are stable.
    static let supportedModifiers: NSEvent.ModifierFlags = [.command, .control, .option, .shift]

    init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.rawModifiers = modifiers
            .intersection(.deviceIndependentFlagsMask)
            .intersection(Shortcut.supportedModifiers)
            .rawValue
    }

    /// The narrowed modifier set, reconstructed from the persisted raw value.
    var modifiers: NSEvent.ModifierFlags {
        NSEvent.ModifierFlags(rawValue: rawModifiers)
    }

    /// A global hotkey must carry at least one of ⌘/⌃/⌥. A bare letter — or a ⇧-letter —
    /// registered system-wide would swallow that key in every app, so the recorder rejects
    /// those. ⇧ alone doesn't count as a qualifying modifier for this reason.
    static func isValidGlobalModifiers(_ modifiers: NSEvent.ModifierFlags) -> Bool {
        !modifiers.isDisjoint(with: [.command, .control, .option])
    }

    /// Whether this shortcut is a legal global hotkey (see `isValidGlobalModifiers`).
    var isValidGlobalShortcut: Bool {
        Shortcut.isValidGlobalModifiers(modifiers)
    }

    /// A menu-style rendering — modifier glyphs in the canonical macOS order ⌃⌥⇧⌘ followed by
    /// the key label (e.g. `⌥⌘Space`). Pure, so it can be unit-tested.
    var displayString: String {
        Shortcut.modifierSymbols(modifiers) + Shortcut.keyLabel(for: keyCode)
    }

    /// Modifier glyphs in the canonical order Apple's own menus use: ⌃ ⌥ ⇧ ⌘.
    static func modifierSymbols(_ modifiers: NSEvent.ModifierFlags) -> String {
        var symbols = ""
        if modifiers.contains(.control) { symbols += "⌃" }
        if modifiers.contains(.option) { symbols += "⌥" }
        if modifiers.contains(.shift) { symbols += "⇧" }
        if modifiers.contains(.command) { symbols += "⌘" }
        return symbols
    }

    /// A human label for a virtual key code, covering the common cases (letters, digits,
    /// F-keys, arrows, and the named editing keys) via Carbon's `kVK_*` table. Anything not in
    /// the table falls back to `key <n>` so an exotic key still renders rather than crashing.
    static func keyLabel(for keyCode: UInt16) -> String {
        switch Int(keyCode) {
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_B: return "B"
        case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"
        case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"
        case kVK_ANSI_H: return "H"
        case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"
        case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"
        case kVK_ANSI_N: return "N"
        case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"
        case kVK_ANSI_Q: return "Q"
        case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_T: return "T"
        case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_W: return "W"
        case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"
        case kVK_ANSI_Z: return "Z"
        case kVK_ANSI_0: return "0"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Space: return "Space"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_Escape: return "⎋"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_Home: return "↖"
        case kVK_End: return "↘"
        case kVK_PageUp: return "⇞"
        case kVK_PageDown: return "⇟"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        default: return "key \(keyCode)"
        }
    }
}

/// The two things a global hotkey can do. Each has a stable numeric id (routed back from
/// Carbon's C callback) and the UserDefaults key its shortcut persists under.
enum HotKeyAction: CaseIterable {
    /// Open the menu-bar popover (and close it if already open) — as if the icon were clicked.
    case togglePopover
    /// Bring forward the terminal of the longest-waiting attention item, without opening the
    /// popover.
    case focusNeedsMe

    /// The per-action `EventHotKeyID.id` Carbon echoes back on a press, so the callback can
    /// route to the right action. Distinct small integers; never reused.
    var hotKeyID: UInt32 {
        switch self {
        case .togglePopover: return 1
        case .focusNeedsMe: return 2
        }
    }

    /// The UserDefaults key this action's shortcut persists under, as JSON `Data` (nil = unset).
    var defaultsKey: String {
        switch self {
        case .togglePopover: return "hotkeyTogglePopover"
        case .focusNeedsMe: return "hotkeyFocusNeedsMe"
        }
    }
}

/// A dependency-free registrar for *system-wide* keyboard shortcuts, built on Carbon's
/// `RegisterEventHotKey`.
///
/// Why Carbon and not something newer: registering a hotkey that fires while another app is
/// frontmost — and that *consumes* the chord so it doesn't also reach that app — has no modern
/// public replacement. `NSEvent`'s global monitors can observe keys but never swallow them, and
/// SwiftUI's `.keyboardShortcut` only fires while our own window is key. Carbon's hotkey API is
/// old but stable, ships in every macOS, and needs no entitlement; a Homebrew (non-App-Store)
/// build can lean on it without review concerns.
///
/// Threading: Carbon dispatches hotkey events on the main thread, so this whole type is
/// `@MainActor`. The C event handler can't be actor-annotated, so it re-enters the actor with
/// `MainActor.assumeIsolated` — the same justification as QueueView's local key monitor.
///
/// Lifetime: the single `InstallEventHandler` is installed lazily and **never removed** —
/// `AppState` owns this object for the whole process, so there is nothing to tear down and no
/// window in which a torn-down handler could miss a press. Only the hotkey *registrations* are
/// balanced: `register` unregisters any prior binding for the same action first.
@MainActor
final class HotKeyCenter {
    /// Invoked on the main thread when a registered hotkey fires. Set by `AppState`; a
    /// `@MainActor` closure so it can touch main-actor state without hopping.
    var onAction: (@MainActor (HotKeyAction) -> Void)?

    /// Live registrations, keyed by action, so a re-`register` (or `unregister`) can release the
    /// previous `EventHotKeyRef` first — Carbon leaks the slot otherwise.
    private var registered: [HotKeyAction: EventHotKeyRef] = [:]

    /// The installed app-wide handler, kept only so `installHandlerIfNeeded` can tell it has run
    /// once. Never uninstalled (see the type doc).
    private var eventHandler: EventHandlerRef?
    private var handlerInstalled = false

    /// A four-char signature shared by all of AgentBar's hotkey ids, distinguishing them from
    /// any other Carbon hotkeys in the process.
    private static let signature: OSType = fourCharCode("agnt")

    /// Registers `shortcut` for `action`, replacing any prior binding for that action. A
    /// failure (e.g. the chord is already claimed by another app) is logged and left unbound
    /// rather than surfaced — the user simply records a different chord.
    func register(_ shortcut: Shortcut, id action: HotKeyAction) {
        installHandlerIfNeeded()
        unregister(action)

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: action.hotKeyID)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            UInt32(shortcut.keyCode),
            Self.carbonModifiers(from: shortcut.modifiers),
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &ref
        )
        if status == noErr, let ref {
            registered[action] = ref
        } else {
            DebugLog.log("HotKeyCenter: RegisterEventHotKey failed for \(action) (status \(status))")
        }
    }

    /// Releases the hotkey bound to `action`, if any. Safe to call when nothing is registered.
    func unregister(_ action: HotKeyAction) {
        guard let ref = registered.removeValue(forKey: action) else { return }
        let status = UnregisterEventHotKey(ref)
        if status != noErr {
            DebugLog.log("HotKeyCenter: UnregisterEventHotKey failed for \(action) (status \(status))")
        }
    }

    // MARK: - Handler installation

    /// Installs the one app-wide keyboard handler, lazily and exactly once. `passUnretained`
    /// because `AppState` owns this object for the process lifetime — the handler is never
    /// removed, so there is no window in which a dangling pointer could be dispatched to.
    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let userData = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(
            GetEventDispatcherTarget(),
            hotKeyEventHandler,
            1,
            &eventType,
            userData,
            &eventHandler
        )
        if status == noErr {
            handlerInstalled = true
        } else {
            DebugLog.log("HotKeyCenter: InstallEventHandler failed (status \(status))")
        }
    }

    /// Called by the C callback (already hopped onto the main actor) with the fired hotkey's
    /// numeric id; routes it to the matching action's handler.
    fileprivate func handle(hotKeyID: UInt32) {
        guard let action = HotKeyAction.allCases.first(where: { $0.hotKeyID == hotKeyID }) else { return }
        onAction?(action)
    }

    // MARK: - Conversions

    /// Maps `NSEvent.ModifierFlags` to Carbon's modifier bit mask. The `cmdKey`/`optionKey`/…
    /// constants are `Int`, so each is widened to `UInt32` explicitly.
    static func carbonModifiers(from modifiers: NSEvent.ModifierFlags) -> UInt32 {
        var carbon: UInt32 = 0
        if modifiers.contains(.command) { carbon |= UInt32(cmdKey) }
        if modifiers.contains(.option) { carbon |= UInt32(optionKey) }
        if modifiers.contains(.control) { carbon |= UInt32(controlKey) }
        if modifiers.contains(.shift) { carbon |= UInt32(shiftKey) }
        return carbon
    }

    /// Packs up to four ASCII characters into an `OSType` (a `FourCharCode`), big-endian, for a
    /// hotkey signature. Only the low byte of each scalar is used, matching Carbon's convention.
    private static func fourCharCode(_ string: String) -> OSType {
        var code: OSType = 0
        for scalar in string.unicodeScalars.prefix(4) {
            code = (code << 8) + OSType(scalar.value & 0xFF)
        }
        return code
    }
}

/// The C callback Carbon invokes for `kEventHotKeyPressed`. It must be a free function (no
/// captured context) to bridge to a C function pointer; the owning `HotKeyCenter` is recovered
/// from the `userData` pointer passed to `InstallEventHandler`.
///
/// Carbon delivers keyboard events on the main thread, so `MainActor.assumeIsolated` is sound
/// here — it lets us call back into the main-actor `HotKeyCenter` synchronously (the same
/// pattern QueueView uses for its local key monitor). The `EventHotKeyID` is read out with the
/// standard `GetEventParameter` incantation: a mutable `EventHotKeyID` var, its `MemoryLayout`
/// size, and the direct-object parameter typed as `typeEventHotKeyID`.
private func hotKeyEventHandler(
    _ callRef: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event, let userData else { return OSStatus(eventNotHandledErr) }

    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr else { return status }

    let firedID = hotKeyID.id
    MainActor.assumeIsolated {
        let center = Unmanaged<HotKeyCenter>.fromOpaque(userData).takeUnretainedValue()
        center.handle(hotKeyID: firedID)
    }
    return noErr
}
