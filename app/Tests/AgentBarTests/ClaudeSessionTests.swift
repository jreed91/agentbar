import XCTest
@testable import AgentBar

/// Tests for the pure core of the Claude Code transcript parser (`SessionScanner`). The
/// transcript's line shapes are only loosely pinned in the public docs, so these lock in the
/// fields the roster relies on — in particular `stop_reason`, the transcript's own
/// authoritative "is this turn still working" signal that keeps a long-running tool call from
/// being misread as idle.
final class ClaudeSessionTests: XCTestCase {

    private let fileURL = URL(fileURLWithPath: "/Users/me/.claude/projects/-Users-me-proj/abc.jsonl")

    private func parse(_ jsonl: String, folderName: String = "-Users-me-proj") -> ClaudeSession {
        SessionScanner.parseTranscript(
            contents: jsonl,
            sessionID: "abc",
            folderName: folderName,
            modified: Date(timeIntervalSince1970: 1_700_000_000),
            fileURL: fileURL
        )
    }

    // MARK: - isTurnInFlight (stop_reason)

    /// A turn whose last main-chain assistant message stopped for `tool_use` is still working —
    /// the agent has committed to another tool call and has not ended the turn.
    func testTurnInFlightWhenLastAssistantStoppedForToolUse() {
        let jsonl = """
        {"type":"user","timestamp":"2026-07-11T10:00:00Z","message":{"content":"Build the app"}}
        {"type":"assistant","timestamp":"2026-07-11T10:00:01Z","message":{"model":"claude-opus-4-8","stop_reason":"tool_use","content":[{"type":"tool_use","name":"Bash","input":{"command":"swift build"}}]}}
        {"type":"user","timestamp":"2026-07-11T10:00:02Z","message":{"content":[{"type":"tool_result","content":"ok"}]}}
        {"type":"assistant","timestamp":"2026-07-11T10:00:03Z","message":{"model":"claude-opus-4-8","stop_reason":"tool_use","content":[{"type":"tool_use","name":"Bash","input":{"command":"swift test"}}]}}
        """
        XCTAssertTrue(parse(jsonl).isTurnInFlight)
    }

    /// A completed turn (`end_turn`) is not in flight — the agent has yielded back to the user.
    func testTurnNotInFlightWhenLastAssistantEndedTurn() {
        let jsonl = """
        {"type":"user","timestamp":"2026-07-11T10:00:00Z","message":{"content":"Explain this"}}
        {"type":"assistant","timestamp":"2026-07-11T10:00:01Z","message":{"model":"claude-opus-4-8","stop_reason":"tool_use","content":[{"type":"tool_use","name":"Read","input":{"file_path":"/a.swift"}}]}}
        {"type":"user","timestamp":"2026-07-11T10:00:02Z","message":{"content":[{"type":"tool_result","content":"…"}]}}
        {"type":"assistant","timestamp":"2026-07-11T10:00:03Z","message":{"model":"claude-opus-4-8","stop_reason":"end_turn","content":[{"type":"text","text":"Here is what it does."}]}}
        """
        XCTAssertFalse(parse(jsonl).isTurnInFlight)
    }

    /// A trailing assistant message still streaming carries no `stop_reason` yet; the last
    /// known reason (`tool_use`) must stand so an in-flight turn isn't misread as finished.
    func testTurnInFlightSurvivesTrailingMessageWithoutStopReason() {
        let jsonl = """
        {"type":"assistant","timestamp":"2026-07-11T10:00:01Z","message":{"model":"claude-opus-4-8","stop_reason":"tool_use","content":[{"type":"tool_use","name":"Bash","input":{"command":"make"}}]}}
        {"type":"assistant","timestamp":"2026-07-11T10:00:02Z","message":{"model":"claude-opus-4-8","content":[{"type":"text","text":"partial…"}]}}
        """
        XCTAssertTrue(parse(jsonl).isTurnInFlight)
    }

    /// A subagent (`isSidechain`) turn's `stop_reason` must not set the main session's state:
    /// a sidechain still calling tools while the main turn has ended reads as not in flight.
    func testSidechainStopReasonIgnored() {
        let jsonl = """
        {"type":"assistant","timestamp":"2026-07-11T10:00:01Z","message":{"model":"claude-opus-4-8","stop_reason":"end_turn","content":[{"type":"text","text":"Done."}]}}
        {"type":"assistant","timestamp":"2026-07-11T10:00:02Z","isSidechain":true,"message":{"model":"claude-opus-4-8","stop_reason":"tool_use","content":[{"type":"tool_use","name":"Grep","input":{"pattern":"x"}}]}}
        """
        XCTAssertFalse(parse(jsonl).isTurnInFlight)
    }

    /// A brand-new session with no assistant turn yet is not in flight.
    func testTurnNotInFlightWithNoAssistantTurn() {
        let jsonl = #"{"type":"user","timestamp":"2026-07-11T10:00:00Z","message":{"content":"hi"}}"#
        XCTAssertFalse(parse(jsonl).isTurnInFlight)
    }

    // MARK: - subagentActive (sidechain in flight)

    /// A subagent is active when the main turn is in flight (waiting on its `Task` tool) and
    /// the most recent sidechain assistant turn is still calling tools.
    func testSubagentActiveWhenSidechainInFlightDuringMainTurn() {
        let jsonl = """
        {"type":"assistant","timestamp":"2026-07-11T10:00:01Z","message":{"model":"claude-opus-4-8","stop_reason":"tool_use","content":[{"type":"tool_use","name":"Task","input":{}}]}}
        {"type":"assistant","timestamp":"2026-07-11T10:00:02Z","isSidechain":true,"message":{"model":"claude-opus-4-8","stop_reason":"tool_use","content":[{"type":"tool_use","name":"Grep","input":{"pattern":"x"}}]}}
        """
        let session = parse(jsonl)
        XCTAssertTrue(session.subagentActive)
        XCTAssertTrue(session.isTurnInFlight)
    }

    /// A finished main turn clears the subagent indicator even if the last sidechain message
    /// happened to end on `tool_use` — a subagent cannot outlive its parent turn.
    func testSubagentInactiveWhenMainTurnEnded() {
        let jsonl = """
        {"type":"assistant","timestamp":"2026-07-11T10:00:01Z","isSidechain":true,"message":{"stop_reason":"tool_use","content":[{"type":"tool_use","name":"Grep","input":{"pattern":"x"}}]}}
        {"type":"assistant","timestamp":"2026-07-11T10:00:02Z","message":{"stop_reason":"end_turn","content":[{"type":"text","text":"All done."}]}}
        """
        XCTAssertFalse(parse(jsonl).subagentActive)
    }

    // MARK: - backgroundJobs (launched, not killed)

    func testBackgroundJobsCountsLaunchesMinusKills() {
        let jsonl = """
        {"type":"assistant","timestamp":"2026-07-11T10:00:01Z","message":{"stop_reason":"tool_use","content":[{"type":"tool_use","name":"Bash","input":{"command":"npm run dev","run_in_background":true}}]}}
        {"type":"assistant","timestamp":"2026-07-11T10:00:02Z","message":{"stop_reason":"tool_use","content":[{"type":"tool_use","name":"Bash","input":{"command":"tail -f log","run_in_background":true}}]}}
        {"type":"assistant","timestamp":"2026-07-11T10:00:03Z","message":{"stop_reason":"tool_use","content":[{"type":"tool_use","name":"KillShell","input":{"shell_id":"a"}}]}}
        """
        XCTAssertEqual(parse(jsonl).backgroundJobs, 1)
    }

    /// A foreground Bash call (no `run_in_background`) is not a background job.
    func testForegroundBashIsNotABackgroundJob() {
        let jsonl = #"{"type":"assistant","timestamp":"2026-07-11T10:00:01Z","message":{"stop_reason":"end_turn","content":[{"type":"tool_use","name":"Bash","input":{"command":"ls"}}]}}"#
        XCTAssertEqual(parse(jsonl).backgroundJobs, 0)
    }

    /// More kills than launches clamps at zero rather than going negative.
    func testBackgroundJobsClampsAtZero() {
        let jsonl = """
        {"type":"assistant","timestamp":"2026-07-11T10:00:01Z","message":{"stop_reason":"tool_use","content":[{"type":"tool_use","name":"Bash","input":{"command":"sleep 100","run_in_background":true}}]}}
        {"type":"assistant","timestamp":"2026-07-11T10:00:02Z","message":{"stop_reason":"tool_use","content":[{"type":"tool_use","name":"KillShell","input":{}},{"type":"tool_use","name":"KillBash","input":{}}]}}
        """
        XCTAssertEqual(parse(jsonl).backgroundJobs, 0)
    }

    // MARK: - Regression: the rest of the row still parses

    func testTitleModelContextAndCwdStillParse() {
        let jsonl = """
        {"type":"user","cwd":"/Users/me/proj","timestamp":"2026-07-11T10:00:00Z","message":{"content":"Add a login button"}}
        {"type":"assistant","timestamp":"2026-07-11T10:00:01Z","message":{"model":"claude-opus-4-8","stop_reason":"end_turn","content":[{"type":"text","text":"Added."}],"usage":{"input_tokens":100,"cache_read_input_tokens":900,"cache_creation_input_tokens":0}}}
        """
        let session = parse(jsonl)
        XCTAssertEqual(session.id, "abc")
        XCTAssertEqual(session.title, "Add a login button")
        XCTAssertEqual(session.cwd, "/Users/me/proj")
        XCTAssertEqual(session.model, "claude-opus-4-8")
        XCTAssertEqual(session.contextTokens, 1000)
        XCTAssertEqual(session.messageCount, 2)
    }

    // MARK: - Title skips injected (synthetic) user turns

    /// Skill content is injected as a user message opening with a "Base directory for this
    /// skill:" preamble. It is not a human prompt, so the title must come from the next real
    /// prompt instead of every skill-started session reading "Base directory for this skill…".
    func testTitleSkipsInjectedSkillContent() {
        let jsonl = """
        {"type":"user","timestamp":"2026-07-11T10:00:00Z","message":{"content":"Base directory for this skill: /Users/me/.claude/skills/commit\\n\\n# Commit\\nMake a commit…"}}
        {"type":"user","timestamp":"2026-07-11T10:00:01Z","message":{"content":"Ship the login fix"}}
        """
        XCTAssertEqual(parse(jsonl).title, "Ship the login fix")
    }

    /// Turns Claude Code injects itself are flagged `isMeta` — never a title, whatever the
    /// text says (e.g. the "Caveat:" preamble on resumed local-command sessions).
    func testTitleSkipsIsMetaUserTurns() {
        let jsonl = """
        {"type":"user","isMeta":true,"timestamp":"2026-07-11T10:00:00Z","message":{"content":"Caveat: The messages below were generated by the user while running local commands."}}
        {"type":"user","timestamp":"2026-07-11T10:00:01Z","message":{"content":"Fix the flaky test"}}
        """
        XCTAssertEqual(parse(jsonl).title, "Fix the flaky test")
    }

    /// A session that never got past its skill invocation still parses; the title falls back
    /// rather than showing the skill preamble.
    func testSkillOnlySessionFallsBackToNoPrompt() {
        let jsonl = #"{"type":"user","timestamp":"2026-07-11T10:00:00Z","message":{"content":"Base directory for this skill: /Users/me/.claude/skills/commit"}}"#
        XCTAssertEqual(parse(jsonl).title, "(no prompt)")
    }

    /// With no `cwd` on any entry, the path-encoded project folder is decoded as a fallback.
    func testCwdFallsBackToDecodedFolder() {
        let jsonl = #"{"type":"user","timestamp":"2026-07-11T10:00:00Z","message":{"content":"hi"}}"#
        XCTAssertEqual(parse(jsonl, folderName: "-Users-me-proj").cwd, "/Users/me/proj")
    }
}
