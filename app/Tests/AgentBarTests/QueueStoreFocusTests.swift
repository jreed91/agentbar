import XCTest
@testable import AgentBar

/// Tests for `QueueStore.longestWaitingAttentionRow()` — the selection behind the "Focus what
/// needs me" global hotkey. It must pick the session whose oldest pending prompt has waited
/// longest (the mirror image of the popover hero, which jumps to the *newest* prompt), and
/// report nothing when nothing needs you.
@MainActor
final class QueueStoreFocusTests: XCTestCase {

    private static let defaultsKeys = ["notifyQuestions", "notifyPermissions", "notifyWorking"]
    private var savedDefaults: [String: Any?] = [:]

    override func setUp() {
        super.setUp()
        for key in Self.defaultsKeys { savedDefaults[key] = UserDefaults.standard.object(forKey: key) }
        UserDefaults.standard.set(true, forKey: "notifyQuestions")
        UserDefaults.standard.set(true, forKey: "notifyPermissions")
        UserDefaults.standard.set(true, forKey: "notifyWorking")
    }

    override func tearDown() {
        for key in Self.defaultsKeys {
            if let value = savedDefaults[key] ?? nil {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        super.tearDown()
    }

    private func askPayload(sessionID: String) -> Data {
        Data("""
        {"session_id":"\(sessionID)","tool_input":{"questions":[{"question":"Which approach?","options":[{"label":"A"}]}]}}
        """.utf8)
    }

    func testReturnsNilWhenNothingNeedsYou() {
        let queue = QueueStore()
        XCTAssertNil(queue.longestWaitingAttentionRow(), "no attention pending → nothing to focus")
    }

    func testSelectsTheLongestWaitingSession() {
        let queue = QueueStore()

        queue.submit(event: .ask, payload: askPayload(sessionID: "old"))
        // `PendingItem.createdAt` is stamped at construction, so a brief pause guarantees the
        // second prompt is strictly newer — otherwise same-instant timestamps would make the
        // "oldest" ambiguous.
        Thread.sleep(forTimeInterval: 0.01)
        queue.submit(event: .ask, payload: askPayload(sessionID: "new"))

        XCTAssertEqual(queue.longestWaitingAttentionRow()?.id, "old",
                       "focus should target the prompt that has waited longest, not the newest")
    }

    func testIgnoresSessionsWithNoPendingAttention() {
        let queue = QueueStore()

        // A working (info) row needs no response, so a session carrying only that is not a
        // focus target; the one waiting session is.
        queue.submit(event: .working, payload: Data(#"{"session_id":"busy"}"#.utf8))
        queue.submit(event: .ask, payload: askPayload(sessionID: "waiting"))

        XCTAssertEqual(queue.longestWaitingAttentionRow()?.id, "waiting",
                       "only sessions with a pending prompt are focus candidates")
    }
}
