import XCTest
@testable import AgentBar

/// Tests for the pure core of the Copilot session-state parser. Copilot CLI's
/// `events.jsonl` schema is not a stable, documented contract (github/copilot-cli#3551), so
/// these lock in the shapes AgentBar relies on: recording representative event lines here
/// means an upstream shape change fails a test instead of silently blanking a row.
final class CopilotSessionTests: XCTestCase {

    private let fileURL = URL(fileURLWithPath: "/Users/me/.copilot/session-state/abc/events.jsonl")

    private func parse(_ jsonl: String, cwd: String = "/Users/me/project") -> ClaudeSession {
        CopilotSessionScanner.parseSession(
            id: "abc",
            eventsJSONL: jsonl,
            cwd: cwd,
            modified: Date(timeIntervalSince1970: 1_700_000_000),
            fileURL: fileURL
        )
    }

    func testParsesTitleMessagesAndTrail() {
        let jsonl = """
        {"type":"session.start","timestamp":"2026-07-11T10:00:00Z"}
        {"type":"user.message","timestamp":"2026-07-11T10:00:01Z","data":{"content":"Add a login button"}}
        {"type":"assistant.turn_start","timestamp":"2026-07-11T10:00:02Z"}
        {"type":"tool.execution_start","timestamp":"2026-07-11T10:00:03Z","data":{"name":"editFiles","input":{"path":"src/Login.tsx"}}}
        {"type":"tool.execution_complete","timestamp":"2026-07-11T10:00:04Z","data":{"name":"editFiles"}}
        {"type":"assistant.message_delta","timestamp":"2026-07-11T10:00:05Z","data":{"content":"partial…"}}
        {"type":"assistant.message","timestamp":"2026-07-11T10:00:06Z","data":{"content":"Done, added the button."}}
        """
        let session = parse(jsonl)
        XCTAssertEqual(session.source, .copilot)
        XCTAssertEqual(session.id, "abc")
        XCTAssertEqual(session.title, "Add a login button")
        // One user.message + one assistant.message; the streaming delta is not counted.
        XCTAssertEqual(session.messageCount, 2)
        // Trail: the tool start, then the completed assistant message (delta excluded).
        XCTAssertEqual(session.trail.map(\.label), ["editFiles Login.tsx", "Done, added the button."])
        XCTAssertEqual(session.activity, "Done, added the button.")
        XCTAssertEqual(session.cwd, "/Users/me/project")
    }

    func testShellToolRendersAsRunning() {
        let jsonl = #"{"type":"tool.execution_start","data":{"name":"shell","input":{"command":"npm test"}}}"#
        let session = parse(jsonl)
        XCTAssertEqual(session.activity, "Running: npm test")
    }

    func testContentBlocksArrayIsFlattened() {
        let jsonl = #"{"type":"user.message","data":{"content":[{"type":"text","text":"hello"},{"type":"text","text":"world"}]}}"#
        let session = parse(jsonl)
        XCTAssertEqual(session.title, "hello world")
    }

    func testCwdFromEventUsedWhenWorkspaceEmpty() {
        let jsonl = #"{"type":"user.message","cwd":"/from/event","data":{"content":"hi"}}"#
        let session = parse(jsonl, cwd: "")
        XCTAssertEqual(session.cwd, "/from/event")
    }

    func testWorkspaceCwdWinsOverEvent() {
        let jsonl = #"{"type":"user.message","cwd":"/from/event","data":{"content":"hi"}}"#
        let session = parse(jsonl, cwd: "/ws/path")
        XCTAssertEqual(session.cwd, "/ws/path")
    }

    func testDegradesWhenNoUsablePrompt() {
        let session = parse("not json\n{}\n{\"type\":\"session.idle\"}", cwd: "")
        XCTAssertEqual(session.title, "(no prompt)")
        XCTAssertEqual(session.messageCount, 0)
        XCTAssertTrue(session.trail.isEmpty)
        XCTAssertEqual(session.cwd, "")
    }

    func testSyntheticTagWrappedPromptSkipped() {
        // Tool-result / envelope turns start with "<" and make poor titles; they degrade.
        let jsonl = #"{"type":"user.message","data":{"content":"<tool_result>ok</tool_result>"}}"#
        let session = parse(jsonl, cwd: "")
        XCTAssertEqual(session.title, "(no prompt)")
        // It still counts as a message even though its text isn't a usable title.
        XCTAssertEqual(session.messageCount, 1)
    }

    func testNumericEpochTimestampParsed() {
        // Milliseconds since epoch → the session's lastActivity, not the mtime fallback.
        let jsonl = #"{"type":"user.message","timestamp":1752228000000,"data":{"content":"hi"}}"#
        let session = parse(jsonl, cwd: "")
        XCTAssertEqual(session.lastActivity.timeIntervalSince1970, 1_752_228_000, accuracy: 1)
    }
}
