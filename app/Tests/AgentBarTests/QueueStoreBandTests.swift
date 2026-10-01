import XCTest
@testable import AgentBar

/// Tests for what `GET /v1/attention` and `POST /v1/focus` read from `QueueStore`: the
/// sessions waiting on you that the Claude Code mod's in-terminal band shows.
@MainActor
final class QueueStoreBandTests: XCTestCase {

    private static let defaultsKeys = ["notifyQuestions", "notifyPermissions", "notifyWorking", "mutedProjects"]
    private var savedDefaults: [String: Any?] = [:]

    override func setUp() {
        super.setUp()
        for key in Self.defaultsKeys { savedDefaults[key] = UserDefaults.standard.object(forKey: key) }
        UserDefaults.standard.set(true, forKey: "notifyQuestions")
        UserDefaults.standard.set(true, forKey: "notifyPermissions")
        UserDefaults.standard.removeObject(forKey: "mutedProjects")
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

    private func permission(_ session: String, cwd: String) -> Data {
        Data(#"{"session_id":"\#(session)","cwd":"\#(cwd)","tool_name":"Bash","tool_input":{"command":"make"}}"#.utf8)
    }

    private func ask(_ session: String, cwd: String) -> Data {
        Data("""
        {"session_id":"\(session)","cwd":"\(cwd)","tool_input":{"questions":[{"question":"Ship it?","options":[{"label":"Yes"}]}]}}
        """.utf8)
    }

    func testEntriesListEveryWaitingSessionLongestWaitingFirst() {
        let queue = makeIsolatedQueueStore()
        queue.submit(event: .permission, payload: permission("a", cwd: "/work/api"))
        queue.submit(event: .ask, payload: ask("b", cwd: "/work/api"))
        queue.submit(event: .working, payload: Data(#"{"session_id":"c","cwd":"/work/web"}"#.utf8))

        let entries = queue.attentionEntries()

        // Two sessions in one directory stay two entries; a working session is not waiting.
        XCTAssertEqual(entries.map(\.sessionID), ["a", "b"])
        XCTAssertEqual(entries.map(\.status), [.permission, .question])
        XCTAssertEqual(entries.first?.summary, "Wants to run Bash")
        XCTAssertEqual(entries.first?.cwd, "/work/api")
    }

    func testAnsweredAndMutedSessionsDropOut() {
        let queue = makeIsolatedQueueStore()
        queue.submit(event: .permission, payload: permission("a", cwd: "/work/api"))
        queue.submit(event: .permission, payload: permission("b", cwd: "/work/muted"))
        queue.toggleMute("/work/muted")
        queue.submit(event: .resolved, payload: Data(#"{"session_id":"a"}"#.utf8))

        XCTAssertEqual(queue.attentionEntries(), [])
    }

    func testEntriesEncodeAsTheModReadsThem() throws {
        let queue = makeIsolatedQueueStore()
        queue.submit(event: .permission, payload: permission("a", cwd: "/work/api"))

        let data = try JSONEncoder().encode(queue.attentionEntries())
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(decoded.first?["session_id"] as? String, "a")
        XCTAssertEqual(decoded.first?["status"] as? String, "permission")
        XCTAssertEqual(decoded.first?["cwd"] as? String, "/work/api")
        XCTAssertNotNil(decoded.first?["waiting_since"] as? Double)
    }

    func testFocusTargetIsTheNamedSessionOrTheLongestWaiting() {
        let queue = makeIsolatedQueueStore()
        queue.submit(event: .permission, payload: permission("a", cwd: "/work/api"))
        queue.submit(event: .permission, payload: permission("b", cwd: "/work/web"))

        XCTAssertEqual(queue.attentionItem(forSession: "b")?.sessionID, "b")
        XCTAssertEqual(queue.attentionItem(forSession: nil)?.sessionID, "a")
        XCTAssertNil(queue.attentionItem(forSession: "gone"))
    }
}
