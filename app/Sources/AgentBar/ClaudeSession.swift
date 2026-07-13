import Foundation

/// One step in a session's recent-activity trail: a single action the agent took (a tool
/// call rendered as a verb phrase, or a snippet of prose) with the timestamp of the message
/// it came from. Read-only, parsed from the transcript; the drill-in shows the last handful.
struct ActivityEntry: Sendable, Hashable {
    let at: Date?
    let label: String
}

/// A Claude Code session discovered on disk, independent of whether AgentBar ever saw a
/// hook from it. Claude Code writes a full transcript of every session to
/// `~/.claude/projects/<encoded-cwd>/<session-id>.jsonl` (or under `$CLAUDE_CONFIG_DIR`),
/// so scanning that tree gives us the roster of *all* sessions — including ones started
/// before AgentBar launched and ones running in terminals that never pinged us. Live hook
/// events are folded onto the matching session (by `id`) in `QueueStore`.
struct ClaudeSession: Identifiable, Sendable, Hashable {
    /// The session UUID — the transcript's filename without the `.jsonl` extension. Matches
    /// the `session_id` carried on hook payloads, which is how live events are merged in.
    let id: String
    /// Absolute working directory the session ran in, read from the transcript (falls back
    /// to the path-encoded folder name when no entry carries a `cwd`).
    let cwd: String
    /// A one-line summary of what the session is about — its first real user prompt, or the
    /// transcript's own `summary` entry when there is no usable prompt.
    let title: String
    /// Timestamp of the last transcript entry (falls back to the file's modification date).
    let lastActivity: Date
    /// Count of user + assistant messages in the transcript.
    let messageCount: Int
    /// A compact, human label for the most recent thing the agent did — the last tool it
    /// invoked ("Editing QueueStore.swift", "Running: swift build") or a short snippet of
    /// its last prose. Read-only, derived from the transcript; nil when nothing usable was
    /// found. Surfaced on quiet/working sessions so the roster reads like a live dashboard.
    let activity: String?
    /// The most recent actions in the session, oldest-first and capped, for the drill-in's
    /// read-only activity trail. `activity` is just this trail's last label.
    let trail: [ActivityEntry]
    /// The model the session's most recent assistant turn ran on, from the transcript's
    /// `message.model` (e.g. `claude-opus-4-...`). Nil when no assistant turn carried one
    /// (a brand-new session, or a Copilot session where the scanner doesn't record it).
    let model: String?
    /// Approximate context-window usage: the total input tokens (fresh + cache read + cache
    /// creation) the model processed on the session's most recent assistant turn, read from
    /// `message.usage`. This is the size of the prompt that turn saw — the closest read-only
    /// analog to Claude Code's own context gauge. Nil when no usage was found.
    let contextTokens: Int?
    /// Whether the session's most recent main-chain assistant turn was still mid-work: its
    /// `stop_reason` was `tool_use`, meaning the agent had committed to another tool call and
    /// had not yet ended the turn. This is the transcript's own authoritative "still working"
    /// signal — unlike a write-recency guess it stays true across a long-running tool that
    /// writes nothing for minutes. `false` for a completed turn (`end_turn`/`max_tokens`), a
    /// brand-new session with no assistant turn yet, or a Copilot session (no comparable
    /// field). Consulted only when there are no live hook events; live events always win.
    let isTurnInFlight: Bool
    /// Whether a subagent (a `Task` sidechain) is currently mid-work: the main turn is in
    /// flight *and* the most recent sidechain assistant turn stopped for `tool_use`. A
    /// subagent only runs while the parent turn is waiting on its `Task` tool, so a finished
    /// main turn (`end_turn`) clears this even if a stale sidechain message ended on
    /// `tool_use`. `false` for a session with no sidechain activity, or a Copilot session.
    let subagentActive: Bool
    /// Background shell jobs the session has started and not explicitly killed: the count of
    /// `Bash` tool calls with `run_in_background: true`, minus `KillShell`/`KillBash` calls,
    /// clamped at zero. This is a "launched, not torn down" tally, not a live process count —
    /// neither the hooks nor the transcript record a background job exiting on its own, so the
    /// UI labels it honestly. `0` for a session that started none, or a Copilot session.
    let backgroundJobs: Int
    /// The transcript file, kept so the row can reveal it in Finder.
    let fileURL: URL
    /// Which agent this session belongs to. Set by the scanner that discovered it —
    /// `.claude` for the Claude Code transcript tree, `.copilot` for the Copilot CLI
    /// session-state tree. Lets the roster tag and de-duplicate the two independently.
    let source: AgentSource
}

/// Scans the Claude Code transcript tree and parses each session into a `ClaudeSession`.
///
/// An `actor` so scanning runs off the main thread (the popover triggers it on open and on
/// a light interval). Parsing is cached by file path + modification date, so re-scans only
/// re-read transcripts that actually changed — steady-state re-scans are nearly free.
actor SessionScanner {
    /// Cap on how many sessions we parse, most-recently-modified first. A machine can
    /// accumulate thousands of historical transcripts; the roster only needs the recent
    /// ones, and this bounds both the parse cost and the popover's list length.
    private let maxSessions = 200

    /// How many recent actions the drill-in trail keeps per session. Small so the popover
    /// stays compact and the cached `ClaudeSession` stays light.
    private static let trailCap = 8

    private struct CacheEntry {
        let modified: Date
        let session: ClaudeSession
    }

    /// path → last parse, keyed so unchanged transcripts are never re-read.
    private var cache: [String: CacheEntry] = [:]

    /// `~/.claude/projects`, or `$CLAUDE_CONFIG_DIR/projects` when that override is set —
    /// the same resolution Claude Code itself uses.
    private var projectsDirectory: URL {
        let base: URL
        if let override = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !override.isEmpty {
            base = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            base = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude", isDirectory: true)
        }
        return base.appendingPathComponent("projects", isDirectory: true)
    }

    /// Enumerates every `*.jsonl` transcript, parses the most-recent `maxSessions`, and
    /// returns them newest-first. Missing/unreadable files are skipped.
    func scan() -> [ClaudeSession] {
        let fm = FileManager.default
        let root = projectsDirectory
        guard let walker = fm.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        // Collect (url, mtime) for every transcript, then take the most-recent ones so we
        // only pay to parse the sessions that will actually be shown.
        var candidates: [(url: URL, modified: Date)] = []
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            candidates.append((url, values?.contentModificationDate ?? .distantPast))
        }
        candidates.sort { $0.modified > $1.modified }
        let recent = candidates.prefix(maxSessions)

        // Drop cache entries for transcripts that are no longer in the recent window so the
        // cache cannot grow without bound.
        let keep = Set(recent.map { $0.url.path })
        cache = cache.filter { keep.contains($0.key) }

        var sessions: [ClaudeSession] = []
        for candidate in recent {
            if let cached = cache[candidate.url.path], cached.modified == candidate.modified {
                sessions.append(cached.session)
                continue
            }
            guard let session = Self.parse(url: candidate.url, modified: candidate.modified) else { continue }
            cache[candidate.url.path] = CacheEntry(modified: candidate.modified, session: session)
            sessions.append(session)
        }
        return sessions.sorted { $0.lastActivity > $1.lastActivity }
    }

    // MARK: - Parsing

    /// Parses one transcript. Each line is a standalone JSON object; we pull only a handful
    /// of well-known keys and tolerate everything else, so format drift degrades to a
    /// thinner row rather than a dropped session.
    private static func parse(url: URL, modified: Date) -> ClaudeSession? {
        guard let contents = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return parseTranscript(
            contents: contents,
            sessionID: url.deletingPathExtension().lastPathComponent,
            folderName: url.deletingLastPathComponent().lastPathComponent,
            modified: modified,
            fileURL: url
        )
    }

    /// The pure core of the parse, split out so it can be unit-tested from a string without
    /// touching disk. `folderName` is the path-encoded project directory, used only to
    /// reconstruct a `cwd` for the rare transcript that carries none.
    static func parseTranscript(
        contents: String,
        sessionID: String,
        folderName: String,
        modified: Date,
        fileURL: URL
    ) -> ClaudeSession {
        var firstUserText: String?
        var summaryText: String?
        var cwd: String?
        var lastTimestamp: Date?
        var messageCount = 0
        var trail: [ActivityEntry] = []
        var model: String?
        var contextTokens: Int?
        var lastStopReason: String?
        var lastSidechainStopReason: String?
        var backgroundLaunches = 0
        var backgroundKills = 0

        for line in contents.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let entry = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
            else { continue }

            let type = entry["type"] as? String

            if type == "summary", summaryText == nil {
                summaryText = (entry["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            if cwd == nil, let entryCwd = entry["cwd"] as? String, !entryCwd.isEmpty {
                cwd = entryCwd
            }

            let stamp = (entry["timestamp"] as? String).flatMap(parseTimestamp)
            if let stamp, lastTimestamp == nil || stamp > lastTimestamp! { lastTimestamp = stamp }

            if type == "user" || type == "assistant" {
                messageCount += 1
                // `isMeta` marks turns Claude Code injected itself (skill/command content,
                // caveat preambles) — never something the human typed, so never a title.
                if type == "user", firstUserText == nil,
                   (entry["isMeta"] as? Bool) != true,
                   let text = userText(from: entry["message"]) {
                    firstUserText = text
                }
                // Append each action this assistant message took to the trail so the drill-in
                // can show a recent history. Entries are chronological; a rolling window keeps
                // only the last `trailCap` so the array never grows with the transcript.
                if type == "assistant" {
                    for label in activityLabels(from: entry["message"]) {
                        trail.append(ActivityEntry(at: stamp, label: label))
                    }
                    if trail.count > trailCap { trail.removeFirst(trail.count - trailCap) }
                    // Track the model and context size from the newest *main-chain* assistant
                    // turn. Entries are chronological, so the last write wins — a live snapshot
                    // of what this session is running on and how full its context is. Subagent
                    // (`Task`) turns are logged inline with `isSidechain: true` and carry their
                    // own small, separate context; counting them would clobber the real
                    // conversation's usage with a subagent's, so they're skipped here.
                    let isSidechain = (entry["isSidechain"] as? Bool) ?? false
                    // Background-shell accounting spans both chains: a background job is a
                    // background job whoever launched it.
                    let tools = toolCounts(in: entry["message"])
                    backgroundLaunches += tools.launches
                    backgroundKills += tools.kills
                    if let message = entry["message"] as? [String: Any] {
                        // The turn's completion signal, last write wins: `tool_use` means the
                        // agent committed to another tool and is still working; `end_turn`
                        // (or `max_tokens`) means the turn is done. A message still streaming
                        // carries no `stop_reason` yet — leave the prior value so an in-flight
                        // turn isn't misread as finished mid-stream. Tracked per chain so a
                        // subagent's state and the main turn's state stay independent.
                        if let reason = message["stop_reason"] as? String, !reason.isEmpty {
                            if isSidechain { lastSidechainStopReason = reason }
                            else { lastStopReason = reason }
                        }
                        // Model / context come from the main chain only: a subagent runs a
                        // small, separate context that would otherwise clobber the real
                        // conversation's usage with the subagent's.
                        if !isSidechain {
                            if let m = message["model"] as? String, !m.isEmpty, m != "<synthetic>" {
                                model = m
                            }
                            if let tokens = parseContextTokens(from: message["usage"] ?? entry["usage"]) {
                                contextTokens = tokens
                            }
                        }
                    }
                }
            }
        }

        let rawTitle = firstUserText ?? summaryText ?? "(no prompt)"
        let title = condense(rawTitle)
        let resolvedCwd = cwd ?? decodeProjectFolder(folderName)
        let inFlight = lastStopReason == "tool_use"

        return ClaudeSession(
            id: sessionID,
            cwd: resolvedCwd,
            title: title,
            lastActivity: lastTimestamp ?? modified,
            messageCount: messageCount,
            activity: trail.last?.label,
            trail: trail,
            model: model,
            contextTokens: contextTokens,
            isTurnInFlight: inFlight,
            // A subagent is running only while its parent turn is in flight (waiting on the
            // `Task` tool); a finished main turn clears it regardless of a stale sidechain.
            subagentActive: inFlight && lastSidechainStopReason == "tool_use",
            backgroundJobs: max(0, backgroundLaunches - backgroundKills),
            fileURL: fileURL,
            source: .claude
        )
    }

    /// Counts, within one assistant message's content blocks, the background shells it
    /// launched (`Bash` with `run_in_background: true`) and the shells it killed
    /// (`KillShell`/`KillBash`). Both spellings of the kill tool are accepted so the tally
    /// survives Claude Code's rename of that tool. Zero for a message with no tool calls.
    private static func toolCounts(in message: Any?) -> (launches: Int, kills: Int) {
        guard let message = message as? [String: Any],
              let blocks = message["content"] as? [[String: Any]] else { return (0, 0) }
        var launches = 0, kills = 0
        for block in blocks where (block["type"] as? String) == "tool_use" {
            guard let name = block["name"] as? String else { continue }
            if name == "Bash" {
                if (block["input"] as? [String: Any])?["run_in_background"] as? Bool == true {
                    launches += 1
                }
            } else if name == "KillShell" || name == "KillBash" {
                kills += 1
            }
        }
        return (launches, kills)
    }

    /// Sums the input-side token counts from an assistant message's `usage` block — the fresh
    /// input plus both cache tiers — to approximate how full the context window is. Returns nil
    /// when the block is missing or carries no positive total. `output_tokens` is excluded: it
    /// is the reply, not part of the prompt the model read this turn.
    private static func parseContextTokens(from usage: Any?) -> Int? {
        guard let usage = usage as? [String: Any] else { return nil }
        func count(_ key: String) -> Int { (usage[key] as? Int) ?? 0 }
        let total = count("input_tokens")
            + count("cache_read_input_tokens")
            + count("cache_creation_input_tokens")
        return total > 0 ? total : nil
    }

    /// Extracts plain text from a message's `content`, which is either a string or an array
    /// of content blocks (`{"type":"text","text":...}`). Skips Claude Code's synthetic
    /// wrapper turns (slash-command envelopes, tool results) so the title is a real prompt.
    private static func userText(from message: Any?) -> String? {
        guard let message = message as? [String: Any] else { return nil }
        let raw: String?
        if let string = message["content"] as? String {
            raw = string
        } else if let blocks = message["content"] as? [[String: Any]] {
            raw = blocks
                .filter { ($0["type"] as? String) == "text" }
                .compactMap { $0["text"] as? String }
                .joined(separator: " ")
        } else {
            raw = nil
        }
        guard let text = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        // Slash-command / tool-result turns are stored as user entries wrapped in tags; they
        // are not prompts the human typed, so they make poor titles.
        if isSyntheticText(text) { return nil }
        return text
    }

    /// Whether a stretch of message text is one of Claude Code's own injected turns rather
    /// than something a human typed: tag-wrapped envelopes (slash commands, tool results,
    /// system reminders) or skill content, which is injected as a user message that opens
    /// with a `Base directory for this skill: <path>` preamble.
    private static func isSyntheticText(_ text: String) -> Bool {
        text.hasPrefix("<") || text.hasPrefix("Base directory for this skill")
    }

    /// The ordered actions in an assistant message: one verb phrase per tool call, or a single
    /// prose snippet when the message is plain text. Empty when there is nothing usable to
    /// show. The row's single `activity` label is just the last element across the transcript.
    private static func activityLabels(from message: Any?) -> [String] {
        guard let message = message as? [String: Any] else { return [] }
        if let blocks = message["content"] as? [[String: Any]] {
            let tools = blocks
                .filter { ($0["type"] as? String) == "tool_use" }
                .compactMap { toolActivity(name: $0["name"] as? String, input: $0["input"] as? [String: Any]) }
            if !tools.isEmpty { return tools }
            // No tool call — fall back to the message's own text.
            let text = blocks
                .filter { ($0["type"] as? String) == "text" }
                .compactMap { $0["text"] as? String }
                .joined(separator: " ")
            return snippet(text).map { [$0] } ?? []
        } else if let string = message["content"] as? String {
            return snippet(string).map { [$0] } ?? []
        }
        return []
    }

    /// Renders a Claude Code tool call as a short verb phrase for the activity line. Pulls the
    /// one identifying argument per tool (file, command, pattern) and falls back to the tool
    /// name; MCP tools collapse to a generic label since their names are namespaced noise.
    private static func toolActivity(name: String?, input: [String: Any]?) -> String? {
        guard let name, !name.isEmpty else { return nil }
        let file = (input?["file_path"] as? String).map { URL(fileURLWithPath: $0).lastPathComponent }
        switch name {
        case "Edit", "Write", "MultiEdit", "NotebookEdit":
            return file.map { "Editing \($0)" } ?? "Editing files"
        case "Read":
            return file.map { "Reading \($0)" } ?? "Reading a file"
        case "Bash":
            if let cmd = (input?["command"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !cmd.isEmpty {
                return "Running: \(condense(cmd, limit: 48))"
            }
            return "Running a command"
        case "Grep", "Glob":
            if let pattern = (input?["pattern"] as? String), !pattern.isEmpty {
                return "Searching \(condense(pattern, limit: 40))"
            }
            return "Searching the codebase"
        case "Task":
            return "Delegating to a subagent"
        case "WebFetch", "WebSearch":
            return "Searching the web"
        case "TodoWrite":
            return "Updating its task list"
        default:
            return name.hasPrefix("mcp__") ? "Using an MCP tool" : "Using \(name)"
        }
    }

    /// Trims a text block to a single tidy snippet for the activity line, discarding the
    /// synthetic tag-wrapped turns (tool results, slash-command envelopes) that make poor
    /// activity labels. Returns nil when nothing usable remains.
    private static func snippet(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty, !isSyntheticText(text) else { return nil }
        return condense(text, limit: 60)
    }

    /// Collapses whitespace and truncates so a title is a single tidy line.
    private static func condense(_ text: String, limit: Int = 100) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        if collapsed.count <= limit { return collapsed }
        return String(collapsed.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Best-effort decode of a path-encoded project folder (`-Users-me-proj`) back toward a
    /// path. The encoding is lossy (every non-alphanumeric char became `-`), so this is only
    /// a fallback for the rare transcript that carries no `cwd`; the leading `-` maps to `/`.
    private static func decodeProjectFolder(_ folder: String) -> String {
        folder.hasPrefix("-") ? "/" + folder.dropFirst().replacingOccurrences(of: "-", with: "/") : folder
    }

    private static let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoPlain = ISO8601DateFormatter()

    /// Claude Code stamps entries in ISO-8601, usually with fractional seconds and a `Z`.
    private static func parseTimestamp(_ string: String) -> Date? {
        isoFractional.date(from: string) ?? isoPlain.date(from: string)
    }
}
