import SwiftUI
import AppKit

/// One row of the Settings "Shortcuts" section: a label, the currently bound shortcut (or
/// "Not set"), and Record / Clear controls.
///
/// Recording installs a local key-down monitor for its own duration only — the moment a valid
/// chord is pressed it is saved through `AppState` and the monitor is removed; esc cancels. A
/// chord without ⌘/⌃/⌥ is rejected (registered globally it would swallow that key in every
/// app), and the row keeps listening while flashing the requirement rather than binding it.
///
/// State lives here, not in `AppState`: the bound shortcut is mirrored from persistence on
/// appear and after every record/clear, so the label always reflects what is actually
/// registered. `AppState.shared` is used directly (as `SetupSection` does) since the Settings
/// scene doesn't inject it into the environment.
struct ShortcutRecorderRow: View {
    let title: String
    let action: HotKeyAction

    @ObservedObject private var appState = AppState.shared

    /// The shortcut currently bound, mirrored from persistence.
    @State private var shortcut: Shortcut?
    /// True while listening for a chord; drives the "Press shortcut…" affordance.
    @State private var isRecording = false
    /// True after an invalid chord, to flash the "include a modifier" hint.
    @State private var showRequirement = false
    /// The local key-down monitor, live only while recording; retained so it can be removed.
    @State private var monitor: Any?

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                if isRecording {
                    Text(showRequirement ? "Include ⌘, ⌃ or ⌥" : "Press shortcut…")
                        .font(.callout)
                        .foregroundStyle(showRequirement ? Color.red : Color.secondary)
                    Button("Cancel") { stopRecording() }
                        .controlSize(.small)
                } else {
                    Text(shortcut?.displayString ?? "Not set")
                        .font(.callout.monospaced())
                        .foregroundStyle(shortcut == nil ? Color.secondary : Color.primary)
                    Button("Record") { startRecording() }
                        .controlSize(.small)
                    if shortcut != nil {
                        Button("Clear") { clear() }
                            .controlSize(.small)
                    }
                }
            }
        }
        .onAppear { shortcut = appState.shortcut(for: action) }
        // The Settings window is hidden, not always torn down, between opens; still, tear the
        // monitor down on disappear so a half-finished recording never outlives the row.
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        guard monitor == nil else { return }
        isRecording = true
        showRequirement = false
        // Local key-down monitors are delivered on the main thread, so we assert that
        // isolation to touch this view's main-actor state, then swallow every key (return nil)
        // so the chord never leaks into the form while recording.
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            MainActor.assumeIsolated { handle(event) }
            return nil
        }
    }

    private func handle(_ event: NSEvent) {
        // esc cancels without binding.
        if event.keyCode == 53 {
            stopRecording()
            return
        }
        let modifiers = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .intersection(Shortcut.supportedModifiers)
        guard Shortcut.isValidGlobalModifiers(modifiers) else {
            showRequirement = true
            return
        }
        let recorded = Shortcut(keyCode: event.keyCode, modifiers: modifiers)
        appState.setShortcut(recorded, for: action)
        shortcut = recorded
        stopRecording()
    }

    private func clear() {
        appState.setShortcut(nil, for: action)
        shortcut = nil
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
        showRequirement = false
    }
}
