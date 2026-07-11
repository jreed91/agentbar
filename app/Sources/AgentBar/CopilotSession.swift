import Foundation

/// Scans GitHub Copilot CLI's on-disk session logs and parses each into the same
/// `ClaudeSession` model the Claude Code scanner produces, tagged `source: .copilot`.
///
/// Copilot CLI writes every session to `~/.copilot/session-state/<id>/events.jsonl` (or under
/// `$COPILOT_CONFIG_DIR`), a JSON-Lines event stream plus a `workspace.yaml` metadata file.
/// This mirrors `SessionScanner`: an `actor` so scanning runs off the main thread, with a
/// path+mtime cache so unchanged logs are never re-read.
///
/// The `events.jsonl` schema is not yet a documented, stable contract (see
/// github/copilot-cli#3551), so parsing is deliberately defensive — it probes the handful of
/// well-known event types (`user.message`, `assistant.message`, `tool.execution_*`) and a few
/// key spellings, and degrades to a thinner row rather than dropping the session when the
/// shape drifts.
actor CopilotSessionScanner {
    /// Cap on how many sessions we parse, most-recently-modified first (mirrors the Claude
    /// scanner) so a machine with a deep history stays cheap to scan.
    private let maxSessions = 200

    /// How many recent actions the drill-in trail keeps per session.
    private static let trailCap = 8

    private struct CacheEntry {
        let modified: Date
        let session: ClaudeSession
    }

    /// path → last parse, keyed so unchanged logs are never re-read.
    private var cache: [String: CacheEntry] = [:]

    /// `~/.copilot/session-state`, or `$COPILOT_CONFIG_DIR/session-state` when that override
    /// is set — the same resolution Copilot CLI itself uses for its config directory.
    private var sessionStateDirectory: URL {
        let base: URL
        if let override = ProcessInfo.processInfo.environment["COPILOT_CONFIG_DIR"], !override.isEmpty {
            base = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            base = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".copilot", isDirectory: true)
        }
        return base.appendingPathComponent("session-state", isDirectory: true)
    }

    /// Enumerates every `session-state/<id>/events.jsonl`, parses the most-recent
    /// `maxSessions`, and returns them newest-first. Missing/unreadable logs are skipped, so
    /// a machine that has never run Copilot simply yields an empty roster.
    func scan() -> [ClaudeSession] {
        let fm = FileManager.default
        let root = sessionStateDirectory
        guard let entries = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        // Collect (eventsURL, mtime) for every session directory, then take the most-recent
        // ones so we only pay to parse the sessions that will actually be shown.
        var candidates: [(url: URL, modified: Date)] = []
        for dir in entries {
            let events = dir.appendingPathComponent("events.jsonl")
            guard let values = try? events.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            candidates.append((events, values.contentModificationDate ?? .distantPast))
        }
        candidates.sort { $0.modified > $1.modified }
        let recent = candidates.prefix(maxSessions)

        // Drop cache entries no longer in the recent window so the cache cannot grow unbounded.
        let keep = Set(recent.map { $0.url.path })
        cache = cache.filter { keep.contains($0.key) }

        var sessions: [ClaudeSession] = []
        for candidate in recent {
            if let cached = cache[candidate.url.path], cached.modified == candidate.modified {
                sessions.append(cached.session)
                continue
            }
            guard let session = Self.parse(eventsURL: candidate.url, modified: candidate.modified) else { continue }
            cache[candidate.url.path] = CacheEntry(modified: candidate.modified, session: session)
            sessions.append(session)
        }
        return sessions.sorted { $0.lastActivity > $1.lastActivity }
    }

    // MARK: - Parsing

    /// Parses one session directory's `events.jsonl` (plus its sibling `workspace.yaml`) into
    /// a `ClaudeSession`. The session id is the directory name; the cwd is read from
    /// `workspace.yaml` or an event that carries one, falling back to empty.
    private static func parse(eventsURL: URL, modified: Date) -> ClaudeSession? {
        guard let contents = try? String(contentsOf: eventsURL, encoding: .utf8) else { return nil }
        let sessionDir = eventsURL.deletingLastPathComponent()
        let sessionID = sessionDir.lastPathComponent
        let cwd = cwdFromWorkspace(sessionDir.appendingPathComponent("workspace.yaml"))
        return parseSession(
            id: sessionID,
            eventsJSONL: contents,
            cwd: cwd,
            modified: modified,
            fileURL: eventsURL
        )
    }

    /// The pure core of the parse, split out so it can be unit-tested from a string without
    /// touching disk. `cwd` is the value read from `workspace.yaml` (may be empty); a `cwd`
    /// carried on an event overrides it when the file had none.
    static func parseSession(
        id: String,
        eventsJSONL: String,
        cwd: String,
        modified: Date,
        fileURL: URL
    ) -> ClaudeSession {
        var firstUserText: String?
        var cwdFromEvents: String?
        var lastTimestamp: Date?
        var messageCount = 0
        var trail: [ActivityEntry] = []

        for line in eventsJSONL.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let entry = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
            else { continue }

            let type = eventType(entry).lowercased()
            let data = payload(entry)

            if cwdFromEvents == nil {
                if let c = (entry["cwd"] as? String) ?? (data["cwd"] as? String), !c.isEmpty {
                    cwdFromEvents = c
                }
            }

            let stamp = timestamp(entry)
            if let stamp, lastTimestamp == nil || stamp > lastTimestamp! { lastTimestamp = stamp }

            if isUserMessage(type) {
                messageCount += 1
                if firstUserText == nil, let text = messageText(from: data) {
                    firstUserText = text
                }
            } else if isAssistantMessage(type) {
                messageCount += 1
                if let text = messageText(from: data), let snip = snippet(text) {
                    trail.append(ActivityEntry(at: stamp, label: snip))
                }
            } else if isToolStart(type) {
                if let label = toolLabel(from: data) {
                    trail.append(ActivityEntry(at: stamp, label: label))
                }
            }
            if trail.count > trailCap { trail.removeFirst(trail.count - trailCap) }
        }

        let rawTitle = firstUserText ?? "(no prompt)"
        return ClaudeSession(
            id: id,
            cwd: cwd.isEmpty ? (cwdFromEvents ?? "") : cwd,
            title: condense(rawTitle),
            lastActivity: lastTimestamp ?? modified,
            messageCount: messageCount,
            activity: trail.last?.label,
            trail: trail,
            fileURL: fileURL,
            source: .copilot
        )
    }

    // MARK: - Event shape probes

    /// The event's type name, probing the spellings the envelope has used across versions.
    private static func eventType(_ entry: [String: Any]) -> String {
        for key in ["type", "event", "eventType", "event_type", "name", "kind"] {
            if let value = entry[key] as? String, !value.isEmpty { return value }
        }
        return ""
    }

    /// The event's data payload — Copilot nests specifics under `data`/`payload`; when absent
    /// the top-level object doubles as the payload.
    private static func payload(_ entry: [String: Any]) -> [String: Any] {
        (entry["data"] as? [String: Any]) ?? (entry["payload"] as? [String: Any]) ?? entry
    }

    /// A completed user prompt. The dotted vocabulary is `user.message`; we also accept a bare
    /// `user` for resilience, but never a streaming `*delta` partial.
    private static func isUserMessage(_ type: String) -> Bool {
        guard !type.contains("delta") else { return false }
        return type == "user.message" || type == "user"
    }

    /// A completed assistant message (not a streaming delta or reasoning chunk).
    private static func isAssistantMessage(_ type: String) -> Bool {
        guard !type.contains("delta"), !type.contains("reasoning") else { return false }
        return type == "assistant.message" || type == "assistant"
    }

    /// The start of a tool invocation (`tool.execution_start`); used for the activity trail.
    private static func isToolStart(_ type: String) -> Bool {
        type.hasPrefix("tool.") && (type.contains("start") || type == "tool.execution")
    }

    // MARK: - Field extraction

    /// Pulls prompt/message text from an event payload. `content` is either a string or an
    /// array of `{type:"text", text:…}` blocks (mirroring Claude's shape); a couple of plain
    /// aliases (`text`, `message`, `prompt`) are also accepted.
    private static func messageText(from data: [String: Any]) -> String? {
        if let content = data["content"] as? String {
            return clean(content)
        }
        if let blocks = data["content"] as? [[String: Any]] {
            let joined = blocks.compactMap { block -> String? in
                let type = block["type"] as? String
                guard type == nil || type == "text" else { return nil }
                return block["text"] as? String
            }.joined(separator: " ")
            return clean(joined)
        }
        for key in ["text", "message", "prompt"] {
            if let value = data[key] as? String { return clean(value) }
        }
        return nil
    }

    /// Renders a tool event as a short verb phrase, probing the name spellings the payload has
    /// used. A shell command collapses to "Running: …"; everything else to "Using <tool>".
    private static func toolLabel(from data: [String: Any]) -> String? {
        var name: String?
        for key in ["name", "tool_name", "toolName", "tool"] {
            if let value = data[key] as? String, !value.isEmpty { name = value; break }
        }
        guard let name else { return nil }
        let input = (data["input"] as? [String: Any]) ?? (data["arguments"] as? [String: Any]) ?? (data["args"] as? [String: Any])
        let lower = name.lowercased()
        if lower.contains("shell") || lower.contains("bash") || lower.contains("run") || lower.contains("exec") {
            if let cmd = (input?["command"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !cmd.isEmpty {
                return "Running: \(condense(cmd, limit: 48))"
            }
            return "Running a command"
        }
        if let file = (input?["path"] as? String) ?? (input?["file_path"] as? String) ?? (input?["filePath"] as? String) {
            return "\(name) \(URL(fileURLWithPath: file).lastPathComponent)"
        }
        return "Using \(name)"
    }

    /// Discards synthetic tag-wrapped turns and empties, so a title/snippet is real prose.
    private static func clean(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("<") else { return nil }
        return trimmed
    }

    private static func snippet(_ text: String) -> String? {
        clean(text).map { condense($0, limit: 60) }
    }

    /// Collapses whitespace and truncates so a title/label is a single tidy line.
    private static func condense(_ text: String, limit: Int = 100) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        if collapsed.count <= limit { return collapsed }
        return String(collapsed.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }

    // MARK: - workspace.yaml

    /// Best-effort read of the working directory from a session's `workspace.yaml`. No YAML
    /// dependency (AgentBar bundles none): scan for the first plausible path-valued key. Any
    /// surrounding quotes are stripped; returns empty when nothing usable is found.
    private static func cwdFromWorkspace(_ url: URL) -> String {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        let keys = ["cwd", "workspaceFolder", "workspace_folder", "folder", "directory", "path", "root"]
        for line in contents.split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            guard keys.contains(where: { $0.lowercased() == key }) else { continue }
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            value = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if value.hasPrefix("/") || value.hasPrefix("~") { return value }
        }
        return ""
    }

    // MARK: - Timestamps

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoPlain = ISO8601DateFormatter()

    /// Reads an event's timestamp, accepting an ISO-8601 string (with or without fractional
    /// seconds) or a numeric epoch in seconds or milliseconds.
    private static func timestamp(_ entry: [String: Any]) -> Date? {
        for key in ["timestamp", "time", "ts", "at", "createdAt", "created_at"] {
            if let string = entry[key] as? String, !string.isEmpty {
                if let date = isoFractional.date(from: string) ?? isoPlain.date(from: string) { return date }
            }
            if let number = entry[key] as? Double {
                // Heuristic: values past ~year 2003 in seconds are still < 1e12; anything
                // larger is milliseconds.
                return Date(timeIntervalSince1970: number > 1_000_000_000_000 ? number / 1000 : number)
            }
        }
        return nil
    }
}
