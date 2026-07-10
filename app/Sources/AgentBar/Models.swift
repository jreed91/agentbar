import Foundation
import Combine

/// The hook events AgentBar handles, matching the plugin's `agentbar-hook <event>`
/// argument and the server routes `/v1/<event>`. The raw value is the route/token.
///
/// Every event is notify-only: the hook POSTs the payload and the server returns
/// immediately, so the Claude Code session never blocks on AgentBar. Questions,
/// permissions, and MCP input requests are surfaced with their full context so you
/// know what's being asked, but you answer in the terminal — AgentBar just brings
/// you back to it.
enum HookEvent: String {
    // Attention events — Claude is waiting on you in the terminal.
    case ask
    case permission
    case elicit
    // Live-status event — Claude has started a turn and is thinking/working.
    case working
    // Resolution event — a tool completed, so any prompt you were shown for this
    // session has been answered in the terminal; its attention rows can clear.
    case resolved
    // Informational events — nothing to act on.
    case notify
    case stop
    case subagentStop = "subagent"
    case sessionEnd = "sessionend"
    case stopFailure = "stopfailure"
}

/// One field in an MCP elicitation form, derived from the request's JSON Schema.
/// MCP restricts elicitation schemas to flat objects of primitive properties, so
/// a field is always one of these simple kinds.
struct ElicitationField: Identifiable, Hashable {
    enum Kind: Hashable { case text, number, integer, boolean, choice }
    let id = UUID()
    let key: String
    let title: String
    let description: String?
    let kind: Kind
    let choices: [String]
    let required: Bool
}

/// A parsed MCP elicitation request: a prompt message plus the fields to collect.
struct ElicitationRequest: Hashable {
    let serverName: String?
    let message: String
    let fields: [ElicitationField]
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
    /// Final assistant text of the turn (Stop / SubagentStop).
    let lastAssistantMessage: String?
    /// Why a session ended (SessionEnd) or a turn failed (StopFailure).
    let endReason: String?
    let errorType: String?
    let errorMessage: String?
    /// The full decoded payload, kept for events whose exact field layout is not
    /// pinned in the public docs (e.g. Elicitation) so we can probe defensively.
    let raw: [String: Any]

    init(data: Data) {
        let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        self.raw = dict
        self.sessionID = (dict["session_id"] as? String) ?? ""
        self.cwd = (dict["cwd"] as? String) ?? ""
        self.toolName = dict["tool_name"] as? String
        self.toolInput = dict["tool_input"] as? [String: Any]
        self.message = dict["message"] as? String
        self.hookEventName = dict["hook_event_name"] as? String
        self.lastAssistantMessage = dict["last_assistant_message"] as? String
        self.endReason = (dict["end_reason"] as? String) ?? (dict["reason"] as? String)
        self.errorType = dict["error_type"] as? String
        self.errorMessage = dict["error_message"] as? String
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

    /// Parses an MCP elicitation request out of the raw payload. The Claude Code hook
    /// docs do not pin the exact field layout for `Elicitation`, so we probe the
    /// conventional MCP locations (`message`, `requestedSchema`) plus a couple of
    /// plausible aliases, and degrade to a message-only request (no fields) when the
    /// schema is absent or unrecognized.
    static func elicitation(from raw: [String: Any]) -> ElicitationRequest {
        let message = (raw["message"] as? String)
            ?? (nestedDict(raw, "elicitation")?["message"] as? String)
            ?? (nestedDict(raw, "params")?["message"] as? String)
            ?? "An MCP server is requesting input."
        let server = (raw["server_name"] as? String)
            ?? (raw["mcp_server"] as? String)
            ?? (raw["server"] as? String)
        let schema = (raw["requestedSchema"] as? [String: Any])
            ?? (raw["form_schema"] as? [String: Any])
            ?? (raw["schema"] as? [String: Any])
            ?? (nestedDict(raw, "elicitation")?["requestedSchema"] as? [String: Any])
            ?? (nestedDict(raw, "params")?["requestedSchema"] as? [String: Any])
        return ElicitationRequest(serverName: server, message: message, fields: fields(from: schema))
    }

    private static func nestedDict(_ raw: [String: Any], _ key: String) -> [String: Any]? {
        raw[key] as? [String: Any]
    }

    /// Turns a JSON-Schema `properties` object into ordered elicitation fields. Object
    /// key order is not preserved through `JSONSerialization`, so fields are sorted by
    /// key for a stable, deterministic layout.
    private static func fields(from schema: [String: Any]?) -> [ElicitationField] {
        guard let schema, let props = schema["properties"] as? [String: Any] else { return [] }
        let required = Set((schema["required"] as? [String]) ?? [])
        return props.keys.sorted().map { key in
            let spec = props[key] as? [String: Any] ?? [:]
            let choices = (spec["enum"] as? [Any])?.map { String(describing: $0) } ?? []
            let kind: ElicitationField.Kind
            if !choices.isEmpty {
                kind = .choice
            } else {
                switch (spec["type"] as? String) ?? "string" {
                case "boolean": kind = .boolean
                case "integer": kind = .integer
                case "number": kind = .number
                default: kind = .text
                }
            }
            return ElicitationField(
                key: key,
                title: (spec["title"] as? String) ?? key,
                description: spec["description"] as? String,
                kind: kind,
                choices: choices,
                required: required.contains(key)
            )
        }
    }

    /// Pulls a concise shell command out of a `tool_input`, when present. Bash-style tool
    /// calls carry `{"command": "..."}`; the live feed shows this in its `$` box. Returns
    /// nil for tools without a command, so the view can fall back to the full detail.
    static func command(from toolInput: [String: Any]?) -> String? {
        guard let command = toolInput?["command"] as? String else { return nil }
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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

/// The category behind an informational (`.info`) row. Drives the feed's status tag and
/// mascot mood: idle/waiting reads as "working", finished/ended reads as "done", and a
/// failed turn reads as "error".
enum InfoCategory {
    case working
    case done
    case error
}

/// The status a feed line renders with — the live-feed design (2a) tags every row with one
/// of these and derives its mascot mood from the set of active statuses. This is a pure,
/// UI-free classification; the view maps it to colors and labels.
enum FeedStatus: Equatable {
    case permission
    case question
    case working
    case done
    case error
}

/// The mascot's mood in the live feed. Each mood has a compact face for the menu bar and a
/// boxed ASCII face for the popover hero, mirroring the design's `asciiMini` / `asciiBig`.
enum FeedMood {
    case happy
    case working
    case question
    case permission
    case done

    /// Compact face for the menu-bar label (design `asciiMini`).
    var miniFace: String {
        switch self {
        case .happy: return "^_^"
        case .working: return "o_o"
        case .question: return "o_O"
        case .permission: return "O_O"
        case .done: return "^‿^"
        }
    }

    /// Boxed ASCII face for the popover hero (design `asciiBig`).
    var bigFace: String {
        switch self {
        case .happy:      return "┌─────────┐\n│  ^   ^  │\n│    ‿    │\n└─────────┘"
        case .working:    return "┌─────────┐\n│  -   -  │\n│   ───   │\n└─────────┘"
        case .question:   return "┌─────────┐\n│  o   O  │\n│    ?    │\n└─────────┘"
        case .permission: return "┌─────────┐\n│  O   O  │\n│    o    │\n└─────────┘"
        case .done:       return "┌─────────┐\n│  ^   ^  │\n│   \\_/   │\n└─────────┘"
        }
    }
}

/// A single item in the queue. Nothing here blocks a session: every item is a
/// notification. Attention kinds (`question`, `permission`, `elicitation`) surface what
/// Claude is waiting on so you can answer in the terminal and drive the badge count;
/// informational kinds (`info`) auto-expire.
@MainActor
final class PendingItem: Identifiable, ObservableObject {
    enum Kind {
        case question([AskQuestion])
        case permission(toolName: String, command: String?, detail: String)
        case elicitation(ElicitationRequest)
        case info(category: InfoCategory, title: String, body: String)
    }

    let id: UUID
    let sessionID: String
    let cwd: String
    let createdAt: Date
    let kind: Kind
    /// Bundle id of the app hosting the session's terminal (e.g. `com.jetbrains.WebStorm`),
    /// captured from the hook environment. Focus prefers this so the right window comes
    /// forward even when several terminals are open; nil falls back to a priority scan.
    let hostBundleID: String?

    init(sessionID: String, cwd: String, kind: Kind, hostBundleID: String? = nil) {
        self.id = UUID()
        self.sessionID = sessionID
        self.cwd = cwd
        self.createdAt = Date()
        self.kind = kind
        self.hostBundleID = hostBundleID
    }

    /// True for attention items (Claude is waiting on you in the terminal); drives the
    /// menu-bar badge count. Informational items never count.
    var needsResponse: Bool {
        switch kind {
        case .question, .permission, .elicitation: return true
        case .info: return false
        }
    }

    /// How this item is tagged in the live feed. Elicitations read as questions — both
    /// route you to the terminal to type an answer.
    var feedStatus: FeedStatus {
        switch kind {
        case .question: return .question
        case .permission: return .permission
        case .elicitation: return .question
        case .info(let category, _, _):
            switch category {
            case .working: return .working
            case .done: return .done
            case .error: return .error
            }
        }
    }
}
