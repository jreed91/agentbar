import XCTest
@testable import AgentBar

/// Tests for answering a prompt from the menu bar: which prompts can be answered, the state the
/// mod's `/v1/answer/<id>` poll reads, and that an answer in the terminal always closes the
/// menu-bar side.
@MainActor
final class QueueStoreAnswerTests: XCTestCase {

    private static let keys = [QueueStore.answeringKey, "notifyPermissions", "notifyQuestions"]
    private var saved: [String: Any?] = [:]

    override func setUp() {
        super.setUp()
        for key in Self.keys { saved[key] = UserDefaults.standard.object(forKey: key) }
        UserDefaults.standard.set(true, forKey: "notifyPermissions")
        UserDefaults.standard.set(true, forKey: "notifyQuestions")
    }

    override func tearDown() {
        for key in Self.keys {
            if let value = saved[key] ?? nil {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        super.tearDown()
    }

    private let answerID = "0123456789abcdef01234567"
    private var mod: BridgeExtras { BridgeExtras(isMod: true, answerID: answerID) }

    private func permission(_ session: String = "sess-1") -> Data {
        Data(#"{"session_id":"\#(session)","cwd":"/work","tool_name":"Bash","tool_input":{"command":"npm publish"}}"#.utf8)
    }

    private func question(kind: String? = nil) -> Data {
        let kindField = kind.map { #","kind":"\#($0)""# } ?? ""
        let options = kind == nil ? #"[{"label":"Postgres"},{"label":"SQLite"}]"# : "[]"
        return Data(#"{"session_id":"sess-1","cwd":"/work","tool_name":"AskUserQuestion","tool_input":{"questions":[{"question":"Which database?","header":"DB","options":\#(options),"multiSelect":false\#(kindField)}]}}"#.utf8)
    }

    private func decoded(_ state: QueueStore.AnswerState) -> [String: Any]? {
        guard case .answered(let data) = state else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    func testAnsweringIsOffByDefault() {
        UserDefaults.standard.removeObject(forKey: QueueStore.answeringKey)
        let queue = makeIsolatedQueueStore()

        let answerable = queue.submit(event: .permission, payload: permission(), extras: mod)

        XCTAssertFalse(answerable)
        XCTAssertEqual(queue.items.count, 1, "the prompt is still shown, notify-only")
        XCTAssertFalse(queue.canAnswer(queue.items[0]))
        XCTAssertEqual(queue.answerState(for: answerID), .gone)
    }

    func testAllowFromTheMenuBarReachesTheMod() throws {
        UserDefaults.standard.set(true, forKey: QueueStore.answeringKey)
        let queue = makeIsolatedQueueStore()

        XCTAssertTrue(queue.submit(event: .permission, payload: permission(), extras: mod))
        let item = try XCTUnwrap(queue.items.first)
        XCTAssertTrue(queue.canAnswer(item))
        XCTAssertEqual(queue.answerState(for: answerID), .pending)

        queue.answer(item, with: .allow)

        XCTAssertTrue(queue.items.isEmpty, "an answered prompt clears like one answered in the terminal")
        XCTAssertEqual(decoded(queue.answerState(for: answerID))?["behavior"] as? String, "allow")
        XCTAssertEqual(queue.answerState(for: answerID), .gone, "an answer is collected once")
    }

    func testDenyCarriesAMessage() throws {
        UserDefaults.standard.set(true, forKey: QueueStore.answeringKey)
        let queue = makeIsolatedQueueStore()
        queue.submit(event: .permission, payload: permission(), extras: mod)

        queue.answer(try XCTUnwrap(queue.items.first), with: .deny)

        let body = decoded(queue.answerState(for: answerID))
        XCTAssertEqual(body?["behavior"] as? String, "deny")
        XCTAssertNotNil(body?["message"] as? String)
    }

    func testAnswerInTheTerminalClosesTheMenuBarSide() throws {
        UserDefaults.standard.set(true, forKey: QueueStore.answeringKey)
        let queue = makeIsolatedQueueStore()
        queue.submit(event: .permission, payload: permission(), extras: mod)
        let item = try XCTUnwrap(queue.items.first)

        queue.submit(event: .resolved, payload: permission())

        XCTAssertEqual(queue.answerState(for: answerID), .gone)
        queue.answer(item, with: .allow)
        XCTAssertEqual(queue.answerState(for: answerID), .gone, "a late click answers nothing")
    }

    func testWithdrawnOfferGoesBackToNotifyOnly() throws {
        UserDefaults.standard.set(true, forKey: QueueStore.answeringKey)
        let queue = makeIsolatedQueueStore()
        queue.submit(event: .permission, payload: permission(), extras: mod)

        queue.withdrawAnswer(answerID)

        let item = try XCTUnwrap(queue.items.first, "the row stays, so you can still focus the terminal")
        XCTAssertFalse(queue.canAnswer(item))
        XCTAssertEqual(queue.answerState(for: answerID), .gone)
    }

    func testOnlyTheClaudeModCanBeAnswered() {
        UserDefaults.standard.set(true, forKey: QueueStore.answeringKey)
        let queue = makeIsolatedQueueStore()

        XCTAssertFalse(queue.submit(event: .permission, payload: permission("copilot"), source: .copilot, extras: mod))
        XCTAssertFalse(queue.submit(event: .permission, payload: permission("bash"),
                                    extras: BridgeExtras(isMod: false, answerID: answerID)))
    }

    func testQuestionAnswersAreHandedBackByQuestionText() throws {
        UserDefaults.standard.set(true, forKey: QueueStore.answeringKey)
        let queue = makeIsolatedQueueStore()

        XCTAssertTrue(queue.submit(event: .ask, payload: question(), extras: mod))
        queue.answer(try XCTUnwrap(queue.items.first), with: .answers(["Which database?": "SQLite"]))

        let answers = decoded(queue.answerState(for: answerID))?["answers"] as? [String: String]
        XCTAssertEqual(answers, ["Which database?": "SQLite"])
    }

    func testAQuestionWithoutOptionsIsAnsweredInTheTerminal() {
        UserDefaults.standard.set(true, forKey: QueueStore.answeringKey)
        let queue = makeIsolatedQueueStore()

        XCTAssertFalse(queue.submit(event: .ask, payload: question(kind: "text"), extras: mod))
    }

    func testAnswerIDHeaderIsValidated() {
        let ok = BridgeExtras.fromHeaders(bridge: "mod", model: nil, contextTokens: nil, contextWindow: nil,
                                          answerID: "ABCDEF0123456789")
        XCTAssertEqual(ok.answerID, "abcdef0123456789")
        let bad = BridgeExtras.fromHeaders(bridge: "mod", model: nil, contextTokens: nil, contextWindow: nil,
                                           answerID: "../../etc")
        XCTAssertNil(bad.answerID)
    }
}
