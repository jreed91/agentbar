import XCTest
@testable import AgentBar

/// Tests for the Setup-panel health signals `QueueStore` records: the per-source and overall
/// "last hook heard" timestamps that drive the "Claude Code plugin" / "Copilot hooks" rows and
/// the popover's "plugin not detected" pointer.
@MainActor
final class QueueStoreHealthTests: XCTestCase {

    /// `recordHook` persists per-source timestamps to the standard UserDefaults. Snapshot and
    /// restore those keys so a test never leaks a "heard from" state into another test or run.
    private static let hookKeys = ["lastHookAtClaude", "lastHookAtCopilot"]
    private var savedHookKeys: [String: Any?] = [:]

    override func setUp() {
        super.setUp()
        for key in Self.hookKeys {
            savedHookKeys[key] = UserDefaults.standard.object(forKey: key)
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    override func tearDown() {
        for key in Self.hookKeys {
            if let value = savedHookKeys[key] ?? nil {
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

    func testNoHooksMeansNeverHeardFrom() {
        let queue = QueueStore()
        XCTAssertNil(queue.lastHookAt)
        XCTAssertNil(queue.lastHookAt(for: .claude))
        XCTAssertNil(queue.lastHookAt(for: .copilot))
    }

    func testSubmitRecordsPerSourceAndOverall() {
        let queue = QueueStore()
        queue.submit(event: .working, payload: payload(sessionID: "s1"), source: .claude)

        XCTAssertNotNil(queue.lastHookAt(for: .claude), "a Claude hook should mark Claude heard")
        XCTAssertNil(queue.lastHookAt(for: .copilot), "no Copilot hook was sent")
        XCTAssertNotNil(queue.lastHookAt, "overall last-hook should be set")
    }

    func testPerSourceIsTrackedIndependently() {
        let queue = QueueStore()
        queue.submit(event: .working, payload: payload(sessionID: "c1"), source: .copilot)

        XCTAssertNotNil(queue.lastHookAt(for: .copilot))
        XCTAssertNil(queue.lastHookAt(for: .claude),
                     "a Copilot-only roster must not mark the Claude plugin as heard")
    }

    func testTimestampsPersistAcrossInstances() {
        let first = QueueStore()
        first.submit(event: .stop, payload: payload(sessionID: "s1"), source: .claude)
        XCTAssertNotNil(first.lastHookAt(for: .claude))

        // A fresh store (a relaunch) seeds from persistence, so it must not read as "never".
        let second = QueueStore()
        XCTAssertNotNil(second.lastHookAt(for: .claude),
                        "a relaunch after real activity should not claim 'never heard from'")
    }
}
