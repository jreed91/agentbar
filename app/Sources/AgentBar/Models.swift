import Foundation
import Combine

/// Which coding agent a session belongs to. AgentBar started as a Claude Code companion,
/// but the plumbing — the fire-and-forget hook bridge and the on-disk session scan — is
/// agent-agnostic, so it also feeds off GitHub Copilot CLI, which exposes the same shape of
/// lifecycle hooks (`~/.copilot/hooks/*.json`) and an on-disk session log
/// (`~/.copilot/session-state/<id>/events.jsonl`). A live hook event carries its source in
/// the `X-AgentBar-Agent` header; a scanned session carries the source of the tree it came
/// from. `.claude` is the default so every existing code path keeps its behaviour.
enum AgentSource: String, Sendable {
    case claude
    case copilot

    /// Parses the `X-AgentBar-Agent` header value, defaulting to Claude for anything
    /// unrecognized (including the empty header the Claude plugin sends).
    init(header: String?) {
        switch header?.lowercased() {
        case "copilot": self = .copilot
        default: self = .claude
        }
    }

    /// Short name for inline copy ("Claude finished the task", "Copilot is working").
    var shortName: String {
        switch self {
        case .claude: return "Claude"
        case .copilot: return "Copilot"
        }
    }

    /// Full product name for session-level copy.
    var displayName: String {
        switch self {
        case .claude: return "Claude Code"
        case .copilot: return "GitHub Copilot"
        }
    }

    /// The uppercase pill shown on a session row so Claude and Copilot rows are told apart.
    var tagLabel: String {
        switch self {
        case .claude: return "CLAUDE"
        case .copilot: return "COPILOT"
        }
    }
}

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
    /// The session's active permission mode (`default`, `acceptEdits`, `plan`,
    /// `bypassPermissions`), when Claude Code carries it on the hook input. Tracked per
    /// session so the row can show the mode a session is running under; nil when absent.
    let permissionMode: String?
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
        // Claude Code (and Copilot's VS-Code-compatible mode) send snake_case keys; Copilot
        // CLI's native hooks send the same fields in camelCase. Probe both spellings so one
        // parser serves either agent without a per-agent branch.
        self.sessionID = HookPayload.firstString(dict, "session_id", "sessionId") ?? ""
        self.cwd = (dict["cwd"] as? String) ?? ""
        self.toolName = HookPayload.firstString(dict, "tool_name", "toolName")
        self.toolInput = (dict["tool_input"] as? [String: Any]) ?? (dict["toolInput"] as? [String: Any])
        self.message = dict["message"] as? String
        self.hookEventName = HookPayload.firstString(dict, "hook_event_name", "hookEventName")
        self.permissionMode = HookPayload.firstString(dict, "permission_mode", "permissionMode")
        self.lastAssistantMessage = HookPayload.firstString(dict, "last_assistant_message", "lastAssistantMessage")
        self.endReason = HookPayload.firstString(dict, "end_reason", "reason", "endReason")
        self.errorType = HookPayload.firstString(dict, "error_type", "errorType")
        self.errorMessage = HookPayload.firstString(dict, "error_message", "errorMessage")
    }

    /// Returns the first non-empty string value among `keys`, or nil. Lets one field accept
    /// both the snake_case and camelCase spellings the two agents use.
    private static func firstString(_ dict: [String: Any], _ keys: String...) -> String? {
        for key in keys {
            if let value = dict[key] as? String, !value.isEmpty { return value }
        }
        return nil
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

/// A single entry in the recent-activity log — a lightweight, immutable snapshot of one
/// event as it was surfaced, so the popover can show "what happened while I was away"
/// without re-reading transcripts. Kept small and `Sendable`: no references to live items.
struct HistoryEntry: Identifiable, Hashable {
    let id = UUID()
    let at: Date
    let project: String
    let status: FeedStatus
    let summary: String
}

/// Formats a turn/wait duration compactly: `4s`, `47s`, `2m 13s`, `1h 04m`. Used for the
/// "waiting …" label on attention rows and the "finished in …" note on completed turns.
enum DurationFormat {
    static func short(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        let minutes = total / 60
        let secs = total % 60
        if minutes < 60 { return secs == 0 ? "\(minutes)m" : "\(minutes)m \(secs)s" }
        let hours = minutes / 60
        let mins = minutes % 60
        return String(format: "%dh %02dm", hours, mins)
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
    /// A session that is on disk but has no live hook activity right now — historical or
    /// simply quiet. Only ever a session-row status; `PendingItem` never reports it.
    case idle
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

/// Clues about the terminal / IDE hosting a session, captured from the hook's shell
/// environment. `termProgram` and `termEmulator` are set by the actual terminal that
/// spawned the shell, so they are reliable; `cfBundleID` (`__CFBundleIdentifier`) reflects
/// whatever *launched* the app and can be stale (e.g. `com.googlecode.iterm2` when an IDE
/// was started from an iTerm shell), so it is only a last resort. Resolution happens in
/// `TerminalFocus` at click time.
struct TerminalHint: Sendable, Hashable {
    let termProgram: String?
    let termEmulator: String?
    let cfBundleID: String?

    var isEmpty: Bool {
        (termProgram?.isEmpty ?? true)
            && (termEmulator?.isEmpty ?? true)
            && (cfBundleID?.isEmpty ?? true)
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
    /// Which agent raised this event (Claude Code or GitHub Copilot), from the hook's
    /// `X-AgentBar-Agent` header. Drives the source tag on the row and agent-specific copy.
    let source: AgentSource
    /// Clues about the terminal/IDE hosting the session, captured from the hook
    /// environment. Focus resolves these to the right app so the correct window comes
    /// forward even when several terminals are open; nil falls back to a priority scan.
    let terminalHint: TerminalHint?

    init(sessionID: String, cwd: String, kind: Kind, source: AgentSource = .claude, terminalHint: TerminalHint? = nil) {
        self.id = UUID()
        self.sessionID = sessionID
        self.cwd = cwd
        self.createdAt = Date()
        self.kind = kind
        self.source = source
        self.terminalHint = terminalHint
    }

    /// True for attention items (Claude is waiting on you in the terminal); drives the
    /// menu-bar badge count. Informational items never count.
    var needsResponse: Bool {
        switch kind {
        case .question, .permission, .elicitation: return true
        case .info: return false
        }
    }

    /// A one-line human summary of what this item is — used as the ask line in a session
    /// row, and as a fallback session title for a live session not yet scanned from disk.
    var summaryLine: String {
        switch kind {
        case .question(let questions):
            let first = questions.first?.question ?? "Claude has a question."
            let extra = questions.count - 1
            return extra > 0 ? "\(first) (+\(extra) more)" : first
        case .permission(let toolName, _, _):
            return "Wants to run \(toolName)"
        case .elicitation(let request):
            return request.message
        case .info(_, _, let body):
            return body
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
