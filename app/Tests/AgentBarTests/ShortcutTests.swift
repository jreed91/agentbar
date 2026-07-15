import XCTest
import AppKit
import Carbon.HIToolbox
@testable import AgentBar

/// Tests for the pure parts of the global-hotkey feature: `Shortcut`'s Codable round-trip
/// (the exact JSON `Data` shape persisted to UserDefaults), its display-string formatting
/// (modifier ordering, key-label table, fallback), and the modifier-validation rule that a
/// global hotkey must carry ⌘/⌃/⌥.
final class ShortcutTests: XCTestCase {

    // MARK: - Persistence

    func testCodableRoundTripThroughData() throws {
        let shortcut = Shortcut(keyCode: UInt16(kVK_ANSI_K), modifiers: [.command, .shift])
        // The same encode → Data → decode path AppState uses for UserDefaults.
        let data = try JSONEncoder().encode(shortcut)
        let decoded = try JSONDecoder().decode(Shortcut.self, from: data)
        XCTAssertEqual(decoded, shortcut, "a persisted shortcut must survive a round trip unchanged")
        XCTAssertEqual(decoded.keyCode, UInt16(kVK_ANSI_K))
        XCTAssertEqual(decoded.modifiers, [.command, .shift])
    }

    func testModifierNarrowingDropsUnsupportedFlags() {
        // Caps lock / function bits must not survive into a persisted shortcut, or an
        // otherwise-equal chord could compare unequal.
        let shortcut = Shortcut(keyCode: 0, modifiers: [.command, .capsLock, .function])
        XCTAssertEqual(shortcut.modifiers, [.command], "only ⌘⌃⌥⇧ are kept")
    }

    // MARK: - Display string

    func testDisplayStringUsesCanonicalModifierOrder() {
        // Regardless of insertion order, symbols render as ⌃⌥⇧⌘ (Apple's menu order).
        let shortcut = Shortcut(keyCode: UInt16(kVK_ANSI_A), modifiers: [.command, .control, .option, .shift])
        XCTAssertEqual(shortcut.displayString, "⌃⌥⇧⌘A")
    }

    func testDisplayStringKeyLabels() {
        XCTAssertEqual(Shortcut(keyCode: UInt16(kVK_Space), modifiers: [.command]).displayString, "⌘Space")
        XCTAssertEqual(Shortcut(keyCode: UInt16(kVK_Return), modifiers: [.command]).displayString, "⌘↩")
        XCTAssertEqual(Shortcut(keyCode: UInt16(kVK_Escape), modifiers: [.control]).displayString, "⌃⎋")
        XCTAssertEqual(Shortcut(keyCode: UInt16(kVK_LeftArrow), modifiers: [.command]).displayString, "⌘←")
        XCTAssertEqual(Shortcut(keyCode: UInt16(kVK_F1), modifiers: [.command]).displayString, "⌘F1")
        XCTAssertEqual(Shortcut(keyCode: UInt16(kVK_ANSI_9), modifiers: [.option]).displayString, "⌥9")
    }

    func testDisplayStringFallsBackForUnknownKey() {
        // A key code outside the table renders as "key <n>" rather than crashing.
        let shortcut = Shortcut(keyCode: 999, modifiers: [.command])
        XCTAssertEqual(shortcut.displayString, "⌘key 999")
    }

    // MARK: - Validation

    func testValidationRequiresCommandControlOrOption() {
        XCTAssertTrue(Shortcut.isValidGlobalModifiers([.command]))
        XCTAssertTrue(Shortcut.isValidGlobalModifiers([.control]))
        XCTAssertTrue(Shortcut.isValidGlobalModifiers([.option]))
        XCTAssertTrue(Shortcut.isValidGlobalModifiers([.shift, .command]), "⇧ alongside ⌘ is fine")
        XCTAssertFalse(Shortcut.isValidGlobalModifiers([]), "a bare key would swallow typing everywhere")
        XCTAssertFalse(Shortcut.isValidGlobalModifiers([.shift]), "⇧ alone is not a qualifying modifier")
    }

    func testInstanceValidityMirrorsStaticRule() {
        XCTAssertTrue(Shortcut(keyCode: UInt16(kVK_ANSI_A), modifiers: [.command]).isValidGlobalShortcut)
        XCTAssertFalse(Shortcut(keyCode: UInt16(kVK_ANSI_A), modifiers: [.shift]).isValidGlobalShortcut)
    }
}
