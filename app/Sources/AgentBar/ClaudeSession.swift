import Foundation

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
    /// The transcript file, kept so the row can reveal it in Finder.
    let fileURL: URL
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

        var firstUserText: String?
        var summaryText: String?
        var cwd: String?
        var lastTimestamp: Date?
        var messageCount = 0

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

            if let stamp = (entry["timestamp"] as? String).flatMap(parseTimestamp) {
                if lastTimestamp == nil || stamp > lastTimestamp! { lastTimestamp = stamp }
            }

            if type == "user" || type == "assistant" {
                messageCount += 1
                if type == "user", firstUserText == nil,
                   let text = userText(from: entry["message"]) {
                    firstUserText = text
                }
            }
        }

        let rawTitle = firstUserText ?? summaryText ?? "(no prompt)"
        let title = condense(rawTitle)
        let sessionID = url.deletingPathExtension().lastPathComponent
        let resolvedCwd = cwd ?? decodeProjectFolder(url.deletingLastPathComponent().lastPathComponent)

        return ClaudeSession(
            id: sessionID,
            cwd: resolvedCwd,
            title: title,
            lastActivity: lastTimestamp ?? modified,
            messageCount: messageCount,
            fileURL: url
        )
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
        if text.hasPrefix("<") { return nil }
        return text
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
