import XCTest
@testable import AgentBar

/// Tests for the pure payload-parsing surface in `Models.swift`. These functions are the
/// app's single biggest external-dependency risk: they turn Claude Code's hook JSON — whose
/// exact shapes are only loosely pinned in the public docs — into the model AgentBar renders.
/// Recording representative payloads here means a shape change upstream fails a test instead
/// of silently degrading a notification.
final class ModelsTests: XCTestCase {

    /// Helper: parse a JSON string into the `[String: Any]` dictionaries the parsers expect.
    private func dict(_ json: String) -> [String: Any] {
        let data = Data(json.utf8)
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }

    // MARK: - HookPayload init

    func testHookPayloadPullsWellKnownKeys() {
        let json = """
        {
          "session_id": "abc123",
          "cwd": "/Users/me/project",
          "tool_name": "Bash",
          "tool_input": {"command": "ls -la"},
          "message": "hello",
          "hook_event_name": "PreToolUse",
          "last_assistant_message": "done",
          "end_reason": "clear"
        }
        """
        let payload = HookPayload(data: Data(json.utf8))
        XCTAssertEqual(payload.sessionID, "abc123")
        XCTAssertEqual(payload.cwd, "/Users/me/project")
        XCTAssertEqual(payload.toolName, "Bash")
        XCTAssertEqual(payload.message, "hello")
        XCTAssertEqual(payload.hookEventName, "PreToolUse")
        XCTAssertEqual(payload.lastAssistantMessage, "done")
        XCTAssertEqual(payload.endReason, "clear")
    }

    /// GitHub Copilot CLI's native hooks send the same fields in camelCase; the parser must
    /// read them as readily as Claude Code's snake_case so one code path serves both agents.
    func testHookPayloadReadsCamelCaseKeys() {
        let json = """
        {
          "sessionId": "cop-42",
          "cwd": "/Users/me/project",
          "toolName": "editFiles",
          "toolInput": {"files": ["src/main.ts"]},
          "hookEventName": "PostToolUse",
          "lastAssistantMessage": "all set"
        }
        """
        let payload = HookPayload(data: Data(json.utf8))
        XCTAssertEqual(payload.sessionID, "cop-42")
        XCTAssertEqual(payload.cwd, "/Users/me/project")
        XCTAssertEqual(payload.toolName, "editFiles")
        XCTAssertEqual(payload.hookEventName, "PostToolUse")
        XCTAssertEqual(payload.lastAssistantMessage, "all set")
        XCTAssertEqual(payload.toolInput?["files"] as? [String], ["src/main.ts"])
    }

    /// snake_case wins when both spellings are present, so a VS-Code-compatible payload that
    /// carries both never reads the wrong one.
    func testHookPayloadPrefersSnakeCaseWhenBothPresent() {
        let payload = HookPayload(data: Data(#"{"session_id":"snake","sessionId":"camel"}"#.utf8))
        XCTAssertEqual(payload.sessionID, "snake")
    }

    // MARK: - AgentSource

    func testAgentSourceFromHeader() {
        XCTAssertEqual(AgentSource(header: "copilot"), .copilot)
        XCTAssertEqual(AgentSource(header: "Copilot"), .copilot)
        XCTAssertEqual(AgentSource(header: "claude"), .claude)
        XCTAssertEqual(AgentSource(header: ""), .claude)
        XCTAssertEqual(AgentSource(header: nil), .claude)
        XCTAssertEqual(AgentSource(header: "something-else"), .claude)
    }

    func testHookPayloadMissingKeysDegradeCleanly() {
        let payload = HookPayload(data: Data("{}".utf8))
        XCTAssertEqual(payload.sessionID, "")
        XCTAssertEqual(payload.cwd, "")
        XCTAssertNil(payload.toolName)
        XCTAssertNil(payload.message)
    }

    func testHookPayloadInvalidJSONIsEmpty() {
        let payload = HookPayload(data: Data("not json".utf8))
        XCTAssertEqual(payload.sessionID, "")
        XCTAssertTrue(payload.raw.isEmpty)
    }

    func testEndReasonFallsBackToReasonKey() {
        let payload = HookPayload(data: Data(#"{"reason":"logout"}"#.utf8))
        XCTAssertEqual(payload.endReason, "logout")
    }

    func testPermissionModeParsedFromBothSpellings() {
        XCTAssertEqual(
            HookPayload(data: Data(#"{"permission_mode":"plan"}"#.utf8)).permissionMode,
            "plan"
        )
        XCTAssertEqual(
            HookPayload(data: Data(#"{"permissionMode":"acceptEdits"}"#.utf8)).permissionMode,
            "acceptEdits"
        )
        XCTAssertNil(HookPayload(data: Data("{}".utf8)).permissionMode)
    }

    // MARK: - questions(from:)

    func testQuestionsParsesOptionsAndMultiSelect() {
        let input = dict("""
        {"questions":[
          {"question":"Pick a color","header":"Color","multiSelect":true,
           "options":[{"label":"Red","description":"warm"},{"label":"Blue"}]}
        ]}
        """)
        let questions = HookPayload.questions(from: input)
        XCTAssertEqual(questions.count, 1)
        XCTAssertEqual(questions[0].question, "Pick a color")
        XCTAssertEqual(questions[0].header, "Color")
        XCTAssertTrue(questions[0].multiSelect)
        XCTAssertEqual(questions[0].options.count, 2)
        XCTAssertEqual(questions[0].options[0].label, "Red")
        XCTAssertEqual(questions[0].options[0].description, "warm")
        XCTAssertNil(questions[0].options[1].description)
    }

    func testQuestionsDefaultsMultiSelectFalse() {
        let input = dict(#"{"questions":[{"question":"Proceed?","options":[]}]}"#)
        let questions = HookPayload.questions(from: input)
        XCTAssertEqual(questions.count, 1)
        XCTAssertFalse(questions[0].multiSelect)
    }

    func testQuestionsEmptyWhenAbsent() {
        XCTAssertTrue(HookPayload.questions(from: nil).isEmpty)
        XCTAssertTrue(HookPayload.questions(from: [:]).isEmpty)
    }

    // MARK: - elicitation(from:)

    func testElicitationParsesSchemaFields() {
        let raw = dict("""
        {
          "message":"Enter your details",
          "server_name":"my-server",
          "requestedSchema":{
            "properties":{
              "name":{"type":"string","title":"Name","description":"Your name"},
              "age":{"type":"integer"},
              "subscribe":{"type":"boolean"},
              "plan":{"enum":["free","pro"]}
            },
            "required":["name"]
          }
        }
        """)
        let request = HookPayload.elicitation(from: raw)
        XCTAssertEqual(request.message, "Enter your details")
        XCTAssertEqual(request.serverName, "my-server")
        XCTAssertEqual(request.fields.count, 4)

        // Fields are sorted by key for a stable layout: age, name, plan, subscribe.
        XCTAssertEqual(request.fields.map(\.key), ["age", "name", "plan", "subscribe"])

        let byKey = Dictionary(uniqueKeysWithValues: request.fields.map { ($0.key, $0) })
        XCTAssertEqual(byKey["name"]?.kind, .text)
        XCTAssertEqual(byKey["name"]?.title, "Name")
        XCTAssertTrue(byKey["name"]?.required ?? false)
        XCTAssertEqual(byKey["age"]?.kind, .integer)
        XCTAssertFalse(byKey["age"]?.required ?? true)
        XCTAssertEqual(byKey["subscribe"]?.kind, .boolean)
        XCTAssertEqual(byKey["plan"]?.kind, .choice)
        XCTAssertEqual(byKey["plan"]?.choices, ["free", "pro"])
    }

    func testElicitationDegradesToMessageOnly() {
        let raw = dict(#"{"message":"Just a message"}"#)
        let request = HookPayload.elicitation(from: raw)
        XCTAssertEqual(request.message, "Just a message")
        XCTAssertTrue(request.fields.isEmpty)
    }

    func testElicitationDefaultMessageWhenAbsent() {
        let request = HookPayload.elicitation(from: [:])
        XCTAssertEqual(request.message, "An MCP server is requesting input.")
        XCTAssertTrue(request.fields.isEmpty)
    }

    func testElicitationReadsNestedParamsMessage() {
        let raw = dict(#"{"params":{"message":"Nested prompt"}}"#)
        let request = HookPayload.elicitation(from: raw)
        XCTAssertEqual(request.message, "Nested prompt")
    }

    // MARK: - command(from:) / prettyDetail(from:)

    func testCommandExtraction() {
        XCTAssertEqual(HookPayload.command(from: ["command": "  npm test  "]), "npm test")
        XCTAssertNil(HookPayload.command(from: ["command": "   "]))
        XCTAssertNil(HookPayload.command(from: ["other": "x"]))
        XCTAssertNil(HookPayload.command(from: nil))
    }

    func testPrettyDetailIsSortedJSON() {
        let detail = HookPayload.prettyDetail(from: ["b": 2, "a": 1])
        // sortedKeys puts "a" before "b".
        let aIndex = detail.range(of: "\"a\"")?.lowerBound
        let bIndex = detail.range(of: "\"b\"")?.lowerBound
        XCTAssertNotNil(aIndex)
        XCTAssertNotNil(bIndex)
        if let aIndex, let bIndex { XCTAssertLessThan(aIndex, bIndex) }
    }

    func testPrettyDetailEmptyForNil() {
        XCTAssertEqual(HookPayload.prettyDetail(from: nil), "")
    }

    // MARK: - DurationFormat

    func testDurationFormat() {
        XCTAssertEqual(DurationFormat.short(4), "4s")
        XCTAssertEqual(DurationFormat.short(47), "47s")
        XCTAssertEqual(DurationFormat.short(60), "1m")
        XCTAssertEqual(DurationFormat.short(133), "2m 13s")
        XCTAssertEqual(DurationFormat.short(3600), "1h 00m")
        XCTAssertEqual(DurationFormat.short(3660), "1h 01m")
    }
}
