import XCTest
@testable import AgentBar

/// Tests for the live-state lifecycle in `QueueStore` — specifically that the transient
/// "thinking"/working status row is kept consistent with the session's actual state.
///
/// The working row is notify-only and self-clearing: it is added on `working`/`resolved` and
/// must be removed the moment the turn (or session) ends. The bug these lock in: a terminal
/// event (`stop`, `stopfailure`, `sessionend`) only enqueued its finish/error row — the thing
/// that clears the working row — *after* a notification-enabled guard, so with that banner
/// disabled a finished session stayed stuck showing "working".
@MainActor
final class QueueStoreTests: XCTestCase {

    /// The notification toggles `QueueStore` reads from `UserDefaults`. Snapshotted in setUp
    /// and restored in tearDown so a test's overrides never leak into another.
    private static let toggleKeys = [
        "notifyWorking", "notifyTaskFinished", "notifyErrors", "notifySessionEnd",
    ]
    private var savedToggles: [String: Any?] = [:]

    override func setUp() {
        super.setUp()
        for key in Self.toggleKeys { savedToggles[key] = UserDefaults.standard.object(forKey: key) }
    }

    override func tearDown() {
        for key in Self.toggleKeys {
            if let value = savedToggles[key] ?? nil {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        super.tearDown()
    }

    private func payload(sessionID: String) -> Data {
        Data(#"{"session_id":"\#(sessionID)"}"#.utf8)
    }

    /// True when a live "working" (thinking) status row is present for the session.
    private func hasWorkingRow(_ queue: QueueStore, session: String) -> Bool {
        queue.items.contains { $0.sessionID == session && $0.feedStatus == .working }
    }

    // MARK: - Terminal events clear the working row regardless of the banner toggle

    func testStopClearsWorkingRowEvenWhenTaskFinishedNotificationDisabled() {
        UserDefaults.standard.set(true, forKey: "notifyWorking")
        UserDefaults.standard.set(false, forKey: "notifyTaskFinished")
        let queue = makeIsolatedQueueStore()
        let session = "sess-stop"

        queue.submit(event: .working, payload: payload(sessionID: session))
        XCTAssertTrue(hasWorkingRow(queue, session: session), "a turn start should show working")

        queue.submit(event: .stop, payload: payload(sessionID: session))
        XCTAssertFalse(hasWorkingRow(queue, session: session),
                       "a finished turn must clear the working row even with the finished banner off")
    }

    func testStopFailureClearsWorkingRowEvenWhenErrorNotificationDisabled() {
        UserDefaults.standard.set(true, forKey: "notifyWorking")
        UserDefaults.standard.set(false, forKey: "notifyErrors")
        let queue = makeIsolatedQueueStore()
        let session = "sess-fail"

        queue.submit(event: .working, payload: payload(sessionID: session))
        XCTAssertTrue(hasWorkingRow(queue, session: session))

        queue.submit(event: .stopFailure, payload: payload(sessionID: session))
        XCTAssertFalse(hasWorkingRow(queue, session: session),
                       "an interrupted turn must clear the working row even with the error banner off")
    }

    func testSessionEndClearsWorkingRowEvenWhenSessionEndNotificationDisabled() {
        UserDefaults.standard.set(true, forKey: "notifyWorking")
        UserDefaults.standard.set(false, forKey: "notifySessionEnd")
        let queue = makeIsolatedQueueStore()
        let session = "sess-end"

        queue.submit(event: .working, payload: payload(sessionID: session))
        XCTAssertTrue(hasWorkingRow(queue, session: session))

        queue.submit(event: .sessionEnd, payload: payload(sessionID: session))
        XCTAssertFalse(hasWorkingRow(queue, session: session),
                       "an ended session must clear the working row even with the session-end banner off")
    }

    // MARK: - The finish row still supersedes working when its banner is enabled

    func testStopWithNotificationSupersedesWorkingWithDone() {
        UserDefaults.standard.set(true, forKey: "notifyWorking")
        UserDefaults.standard.set(true, forKey: "notifyTaskFinished")
        let queue = makeIsolatedQueueStore()
        let session = "sess-done"

        queue.submit(event: .working, payload: payload(sessionID: session))
        queue.submit(event: .stop, payload: payload(sessionID: session))

        XCTAssertFalse(hasWorkingRow(queue, session: session), "working must not linger after stop")
        XCTAssertTrue(
            queue.items.contains { $0.sessionID == session && $0.feedStatus == .done },
            "a finished turn should surface a single done row"
        )
    }
}
