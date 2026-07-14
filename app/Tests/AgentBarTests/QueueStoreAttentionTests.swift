import XCTest
@testable import AgentBar

/// Tests for the attention-item lifecycle in `QueueStore` — the enqueue/supersede/clear
/// behavior the README promises: a question or permission stays until the session makes
/// progress (`resolved`, a new turn, or a successor prompt), idle banners are deduped
/// against pending prompts, and a malformed ask is dropped rather than surfaced empty.
@MainActor
final class QueueStoreAttentionTests: XCTestCase {

    /// The notification toggles and DND settings `QueueStore` reads from `UserDefaults`.
    /// Snapshotted in setUp and restored in tearDown so a test's overrides never leak.
    private static let defaultsKeys = [
        "notifyQuestions", "notifyPermissions", "notifyIdle", "notifyWorking",
        "dndEnabled", "dndStartHour", "dndEndHour",
    ]
    private var savedDefaults: [String: Any?] = [:]

    override func setUp() {
        super.setUp()
        for key in Self.defaultsKeys { savedDefaults[key] = UserDefaults.standard.object(forKey: key) }
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

    private func askPayload(sessionID: String, question: String = "Which approach?") -> Data {
        Data("""
        {"session_id":"\(sessionID)","tool_input":{"questions":[{"question":"\(question)","options":[{"label":"A"},{"label":"B"}]}]}}
        """.utf8)
    }

    private func permissionPayload(sessionID: String) -> Data {
        Data(#"{"session_id":"\#(sessionID)","tool_name":"Bash","tool_input":{"command":"swift build"}}"#.utf8)
    }

    private func plainPayload(sessionID: String) -> Data {
        Data(#"{"session_id":"\#(sessionID)"}"#.utf8)
    }

    private func pendingItems(_ queue: QueueStore, session: String) -> [PendingItem] {
        queue.items.filter { $0.sessionID == session && $0.needsResponse }
    }

    // MARK: - Enqueue and clear

    func testAskEnqueuesQuestionAndResolvedClearsIt() {
        UserDefaults.standard.set(true, forKey: "notifyQuestions")
        let queue = QueueStore()
        let session = "sess-ask"

        queue.submit(event: .ask, payload: askPayload(sessionID: session))
        XCTAssertEqual(pendingItems(queue, session: session).map(\.feedStatus), [.question],
                       "an ask should enqueue exactly one pending question row")

        queue.submit(event: .resolved, payload: plainPayload(sessionID: session))
        XCTAssertTrue(pendingItems(queue, session: session).isEmpty,
                      "a completed tool means the prompt was answered — the row must clear")
    }

    func testResolvedClearsPendingPermission() {
        UserDefaults.standard.set(true, forKey: "notifyPermissions")
        let queue = QueueStore()
        let session = "sess-perm-allowed"

        queue.submit(event: .permission, payload: permissionPayload(sessionID: session))
        XCTAssertEqual(pendingItems(queue, session: session).map(\.feedStatus), [.permission])

        // Covers both PostToolUse and PostToolUseFailure — the plugin maps either to
        // `resolved`, since an allowed tool that errors was still answered in the terminal.
        queue.submit(event: .resolved, payload: plainPayload(sessionID: session))
        XCTAssertTrue(pendingItems(queue, session: session).isEmpty,
                      "an allowed tool ran — the permission row must clear")
    }

    func testDeniedClearsPendingPermission() {
        UserDefaults.standard.set(true, forKey: "notifyPermissions")
        let queue = QueueStore()
        let session = "sess-perm-denied"

        queue.submit(event: .permission, payload: permissionPayload(sessionID: session))
        XCTAssertEqual(pendingItems(queue, session: session).map(\.feedStatus), [.permission])

        queue.submit(event: .denied, payload: plainPayload(sessionID: session))
        XCTAssertTrue(pendingItems(queue, session: session).isEmpty,
                      "denying in the terminal answers the prompt — the row must clear")
    }

    func testDeniedAssumesNoWorkingStatus() {
        UserDefaults.standard.set(true, forKey: "notifyPermissions")
        UserDefaults.standard.set(true, forKey: "notifyWorking")
        let queue = QueueStore()
        let session = "sess-perm-denied-quiet"

        queue.submit(event: .permission, payload: permissionPayload(sessionID: session))
        queue.submit(event: .denied, payload: plainPayload(sessionID: session))

        XCTAssertTrue(queue.items.filter { $0.sessionID == session }.isEmpty,
                      "a denial can interrupt the turn — it must not enqueue a working row")
    }

    func testNewTurnClearsPendingPermission() {
        UserDefaults.standard.set(true, forKey: "notifyPermissions")
        let queue = QueueStore()
        let session = "sess-perm"

        queue.submit(event: .permission, payload: permissionPayload(sessionID: session))
        XCTAssertEqual(pendingItems(queue, session: session).map(\.feedStatus), [.permission])

        queue.submit(event: .working, payload: plainPayload(sessionID: session))
        XCTAssertTrue(pendingItems(queue, session: session).isEmpty,
                      "a new turn can only start once the prompt was answered — the row must clear")
    }

    // MARK: - Supersession

    func testNewPromptSupersedesThePreviousOne() {
        UserDefaults.standard.set(true, forKey: "notifyQuestions")
        UserDefaults.standard.set(true, forKey: "notifyPermissions")
        let queue = QueueStore()
        let session = "sess-supersede"

        queue.submit(event: .ask, payload: askPayload(sessionID: session))
        queue.submit(event: .permission, payload: permissionPayload(sessionID: session))

        let pending = pendingItems(queue, session: session)
        XCTAssertEqual(pending.map(\.feedStatus), [.permission],
                       "the terminal shows one prompt at a time — a successor must replace, not stack")
    }

    func testMalformedAskIsDropped() {
        UserDefaults.standard.set(true, forKey: "notifyQuestions")
        let queue = QueueStore()
        let session = "sess-malformed"

        queue.submit(event: .ask, payload: plainPayload(sessionID: session))
        XCTAssertTrue(pendingItems(queue, session: session).isEmpty,
                      "an ask without a questions array has nothing to show and must be dropped")
    }

    // MARK: - Idle dedupe

    func testIdleNotifySuppressedWhilePromptPending() {
        UserDefaults.standard.set(true, forKey: "notifyQuestions")
        UserDefaults.standard.set(true, forKey: "notifyIdle")
        let queue = QueueStore()
        let session = "sess-idle-dedupe"

        queue.submit(event: .ask, payload: askPayload(sessionID: session))
        queue.submit(event: .notify, payload: plainPayload(sessionID: session))

        XCTAssertEqual(queue.items.filter { $0.sessionID == session }.count, 1,
                       "an unanswered prompt also fires Notification — the idle row must be deduped")
    }

    func testIdleNotifyEnqueuesWhenNothingPending() {
        UserDefaults.standard.set(true, forKey: "notifyIdle")
        let queue = QueueStore()
        let session = "sess-idle"

        queue.submit(event: .notify, payload: plainPayload(sessionID: session))
        XCTAssertEqual(queue.items.filter { $0.sessionID == session }.count, 1,
                       "with no pending prompt, idle should surface a row")
    }

    // MARK: - Do Not Disturb window

    private func date(atHour hour: Int) -> Date {
        Calendar.current.date(bySettingHour: hour, minute: 30, second: 0, of: Date())!
    }

    func testDoNotDisturbSimpleWindow() {
        UserDefaults.standard.set(true, forKey: "dndEnabled")
        UserDefaults.standard.set(9, forKey: "dndStartHour")
        UserDefaults.standard.set(17, forKey: "dndEndHour")
        let queue = QueueStore()

        XCTAssertTrue(queue.inDoNotDisturb(now: date(atHour: 9)), "start hour is inside")
        XCTAssertTrue(queue.inDoNotDisturb(now: date(atHour: 12)))
        XCTAssertFalse(queue.inDoNotDisturb(now: date(atHour: 17)), "end hour is outside")
        XCTAssertFalse(queue.inDoNotDisturb(now: date(atHour: 8)))
    }

    func testDoNotDisturbWrapsPastMidnight() {
        UserDefaults.standard.set(true, forKey: "dndEnabled")
        UserDefaults.standard.set(22, forKey: "dndStartHour")
        UserDefaults.standard.set(8, forKey: "dndEndHour")
        let queue = QueueStore()

        XCTAssertTrue(queue.inDoNotDisturb(now: date(atHour: 23)))
        XCTAssertTrue(queue.inDoNotDisturb(now: date(atHour: 3)))
        XCTAssertFalse(queue.inDoNotDisturb(now: date(atHour: 12)))
        XCTAssertFalse(queue.inDoNotDisturb(now: date(atHour: 8)), "end hour is outside")
    }

    func testDoNotDisturbDisabledOrEmptyWindow() {
        UserDefaults.standard.set(false, forKey: "dndEnabled")
        UserDefaults.standard.set(0, forKey: "dndStartHour")
        UserDefaults.standard.set(23, forKey: "dndEndHour")
        let queue = QueueStore()
        XCTAssertFalse(queue.inDoNotDisturb(now: date(atHour: 12)), "disabled is never in DND")

        UserDefaults.standard.set(true, forKey: "dndEnabled")
        UserDefaults.standard.set(9, forKey: "dndStartHour")
        UserDefaults.standard.set(9, forKey: "dndEndHour")
        XCTAssertFalse(queue.inDoNotDisturb(now: date(atHour: 9)), "an empty window is never in DND")
    }
}
