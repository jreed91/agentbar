import Foundation
import Combine

/// The four hook events AgentBar handles, matching the plugin's `agentbar-hook <event>`
/// argument and the server routes `/v1/<event>`.
enum HookEvent: String {
    case ask
    case permission
    case notify
    case stop
}

/// One selectable option inside an `AskUserQuestion` question.
struct AskQuestionOption: Identifiable, Hashable {
    let id = UUID()
    let label: String
    let description: String?
}

/// A single question from an `AskUserQuestion` tool call.
struct AskQuestion: Identifiable, Hashable {
    let id = UUID()
    let question: String
    let header: String?
    let options: [AskQuestionOption]
    let multiSelect: Bool
}

/// Parsed view of an incoming hook payload. Uses `JSONSerialization` (not `Codable`)
/// because the shapes are dynamic and we only pull a handful of well-known keys.
struct HookPayload {
    let sessionID: String
    let cwd: String
    let toolName: String?
    let toolInput: [String: Any]?
    let message: String?
    let hookEventName: String?

    init(data: Data) {
        let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        self.sessionID = (dict["session_id"] as? String) ?? ""
        self.cwd = (dict["cwd"] as? String) ?? ""
        self.toolName = dict["tool_name"] as? String
        self.toolInput = dict["tool_input"] as? [String: Any]
        self.message = dict["message"] as? String
        self.hookEventName = dict["hook_event_name"] as? String
    }

    /// Extracts the questions array from an `AskUserQuestion` `tool_input`:
    /// `{"questions":[{"question","header","options":[{"label","description"}],"multiSelect"}]}`
    static func questions(from toolInput: [String: Any]?) -> [AskQuestion] {
        guard let raw = toolInput?["questions"] as? [[String: Any]] else { return [] }
        return raw.map { entry in
            let optionsRaw = entry["options"] as? [[String: Any]] ?? []
            let options = optionsRaw.map { opt in
                AskQuestionOption(
                    label: (opt["label"] as? String) ?? "",
                    description: opt["description"] as? String
                )
            }
            return AskQuestion(
                question: (entry["question"] as? String) ?? "",
                header: entry["header"] as? String,
                options: options,
                multiSelect: (entry["multiSelect"] as? Bool) ?? false
            )
        }
    }

    /// Pretty-prints a `tool_input` dictionary as the detail string shown for permissions.
    static func prettyDetail(from toolInput: [String: Any]?) -> String {
        guard let toolInput else { return "" }
        guard JSONSerialization.isValidJSONObject(toolInput),
              let data = try? JSONSerialization.data(
                  withJSONObject: toolInput,
                  options: [.prettyPrinted, .sortedKeys]
              ),
              let string = String(data: data, encoding: .utf8) else {
            return String(describing: toolInput)
        }
        return string
    }
}

/// A single item in the queue. Blocking kinds (`question`, `permission`) carry a
/// continuation that is resumed exactly once with the finished hook-output JSON (or
/// nil for passthrough). Informational kinds (`info`) have no continuation and expire.
@MainActor
final class PendingItem: Identifiable, ObservableObject {
    enum Kind {
        case question([AskQuestion])
        case permission(toolName: String, detail: String)
        case info(title: String, body: String)
    }

    let id: UUID
    let sessionID: String
    let cwd: String
    let createdAt: Date
    let kind: Kind

    private var continuation: CheckedContinuation<String?, Never>?
    private var didResume = false

    init(sessionID: String, cwd: String, kind: Kind) {
        self.id = UUID()
        self.sessionID = sessionID
        self.cwd = cwd
        self.createdAt = Date()
        self.kind = kind
    }

    /// True for items the user still has to respond to; drives the menu-bar badge count.
    var needsResponse: Bool {
        switch kind {
        case .question, .permission: return true
        case .info: return false
        }
    }

    /// Stores the continuation for a blocking item. Called synchronously inside
    /// `withCheckedContinuation`, so it is always set before any resume can occur.
    func attach(_ continuation: CheckedContinuation<String?, Never>) {
        if didResume {
            // Already resolved before we could attach (should not happen); resume now.
            continuation.resume(returning: nil)
            return
        }
        self.continuation = continuation
    }

    /// Resumes the held HTTP request exactly once. Extra calls are ignored.
    func resume(with value: String?) {
        guard !didResume else { return }
        didResume = true
        continuation?.resume(returning: value)
        continuation = nil
    }
}
