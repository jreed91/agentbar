import Foundation

/// How long an answered/dismissed attention prompt sat waiting before it cleared. Sampled
/// when a question/permission/elicitation leaves the queue (answered in the terminal or
/// dismissed by hand) so the daily digest can report how long prompts blocked you. `at` is
/// when it cleared, used only for the per-day bucketing; `seconds` is the wait it measured.
/// `Codable` so it persists alongside the activity log in the same envelope.
struct WaitSample: Codable, Hashable {
    let at: Date
    let seconds: TimeInterval
}

/// A one-day rollup of the activity log — the "what did today look like" strip at the top of
/// the history view. Counts are by feed status; `projects` is the number of distinct project
/// directories that saw activity, `busiestProject` the one with the most entries (ties broken
/// alphabetically for determinism). Wait stats are nil when the day recorded no samples.
struct DailyDigest: Equatable {
    /// Total history entries in the day. The digest strip is shown only when this is > 0, so a
    /// day with wait samples but no entries (shouldn't happen, but cheap to be exact about)
    /// stays hidden rather than showing a header over nothing.
    let entryCount: Int
    let questions: Int
    let permissions: Int
    /// Finished tasks — entries tagged `.done` (task finished, subagent finished, session end).
    let finished: Int
    let errors: Int
    let projects: Int
    let busiestProject: String?
    let medianWait: TimeInterval?
    let maxWait: TimeInterval?

    /// A day with nothing recorded — the digest strip renders nothing for it.
    static let empty = DailyDigest(
        entryCount: 0, questions: 0, permissions: 0, finished: 0, errors: 0,
        projects: 0, busiestProject: nil, medianWait: nil, maxWait: nil
    )

    /// Whether the day has any entries worth summarizing. The view gates the strip on this so a
    /// quiet day shows only the live feed.
    var hasActivity: Bool { entryCount > 0 }
}

/// Owns the activity log's persistence and the digest math, so `QueueStore` stays a thin
/// caller and the retention/rollup logic is unit-testable in isolation. The log is a
/// convenience — "what happened while I was away", plus a daily rollup — never load-bearing,
/// so every I/O failure degrades silently (a `DebugLog` line, no throw): losing history is
/// never worth crashing the menu-bar app over.
///
/// State is held newest-first (`entries[0]` is the most recent) and pruned on load and on
/// every append to a 7-day window capped at 1000 rows, so a long-running install can't grow
/// the file without bound. Writes are whole-file and atomic; events are low-rate, so a save
/// per mutation is cheap and keeps the on-disk copy always current.
///
/// `@MainActor` because its only caller is the (main-actor) `QueueStore`; that lets the small
/// synchronous file writes happen inline without an actor hop, matching the low event rate.
@MainActor
final class HistoryLog {
    /// The surfaced-event log, newest-first. Seeded from disk at init and mutated in memory.
    private(set) var entries: [HistoryEntry] = []
    /// Wait-time samples, newest-first, for the digest's median/max. Persisted with `entries`.
    private(set) var waits: [WaitSample] = []

    /// Directory the `history.json` envelope lives in. Injectable so tests write to a temp
    /// directory instead of the real Application Support tree; defaults to the same directory
    /// HookServer uses for `server.json`.
    private let root: URL

    /// Entries/waits older than this are dropped on load and on append.
    private let retention: TimeInterval = 7 * 24 * 3600
    /// Hard cap on retained rows after the age prune — newest kept.
    private let cap = 1000
    /// How many (newest) entries the popover list renders. The history view is a plain
    /// `VStack` in a `ScrollView` (not lazily built), so we hand it a bounded slice to keep the
    /// popover cheap; the full set stays in `entries` for the digest and persistence.
    private let viewLimit = 100
    /// Envelope schema version, so a future format change can migrate rather than misread.
    private let currentVersion = 1

    /// The real store root: the shared Application Support directory (same as HookServer).
    /// `nonisolated` because it is referenced from `init`'s default argument, which is
    /// evaluated in a nonisolated context; it touches no actor state, only FileManager paths.
    nonisolated static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/AgentBar", isDirectory: true)
    }

    init(root: URL = HistoryLog.defaultRoot) {
        self.root = root
        load()
    }

    // MARK: - View-facing accessors

    /// The newest entries for the popover list — bounded to `viewLimit` so a large log doesn't
    /// bloat the non-lazy history view. Data is never discarded here; the full log remains for
    /// the digest and the next save.
    var entriesForView: [HistoryEntry] {
        Array(entries.prefix(viewLimit))
    }

    // MARK: - Mutation

    /// Records a surfaced event, newest-first, then prunes and persists. Called once per
    /// notification row that lands in the feed (attention and lifecycle rows, not the transient
    /// "thinking" row).
    func append(_ entry: HistoryEntry) {
        entries.insert(entry, at: 0)
        entries = Self.pruned(entries, now: Date(), retention: retention, cap: cap, at: { $0.at })
        save()
    }

    /// Records how long a just-cleared attention prompt waited, then prunes and persists.
    func record(wait: WaitSample) {
        waits.insert(wait, at: 0)
        waits = Self.pruned(waits, now: Date(), retention: retention, cap: cap, at: { $0.at })
        save()
    }

    /// Clears the activity log and its wait samples, then persists the empty envelope. Both go:
    /// clearing "recent activity" is a clean slate, so a lingering wait sample can't feed a
    /// stale median into a later same-day digest.
    func clear() {
        entries.removeAll()
        waits.removeAll()
        save()
    }

    // MARK: - Digest

    /// A pure rollup of `entries` + `waits` falling within `day`'s calendar day. Counts are by
    /// status; `busiestProject` is the project with the most entries, ties broken by the
    /// alphabetically-first name so the result is deterministic. Median/max are nil when the day
    /// recorded no wait samples. An empty day returns `.empty`.
    func digest(for day: Date, calendar: Calendar = .current) -> DailyDigest {
        let dayEntries = entries.filter { calendar.isDate($0.at, inSameDayAs: day) }
        let dayWaits = waits.filter { calendar.isDate($0.at, inSameDayAs: day) }
        guard !dayEntries.isEmpty || !dayWaits.isEmpty else { return .empty }

        var questions = 0, permissions = 0, finished = 0, errors = 0
        var perProject: [String: Int] = [:]
        for entry in dayEntries {
            switch entry.status {
            case .question: questions += 1
            case .permission: permissions += 1
            case .done: finished += 1
            case .error: errors += 1
            case .working, .idle: break
            }
            perProject[entry.project, default: 0] += 1
        }

        // Highest entry count wins; on a tie the alphabetically-first name is chosen (treat the
        // larger name as "less" so `max` returns the smaller one), keeping the pick stable.
        let busiest = perProject.max { lhs, rhs in
            lhs.value != rhs.value ? lhs.value < rhs.value : lhs.key > rhs.key
        }?.key

        let seconds = dayWaits.map(\.seconds).sorted()
        return DailyDigest(
            entryCount: dayEntries.count,
            questions: questions,
            permissions: permissions,
            finished: finished,
            errors: errors,
            projects: perProject.count,
            busiestProject: busiest,
            medianWait: Self.median(of: seconds),
            maxWait: seconds.last
        )
    }

    /// Median of a pre-sorted array: the middle value for an odd count, the mean of the two
    /// middle values for an even count. Nil for an empty input.
    private static func median(of sorted: [TimeInterval]) -> TimeInterval? {
        guard !sorted.isEmpty else { return nil }
        let mid = sorted.count / 2
        if sorted.count % 2 == 1 { return sorted[mid] }
        return (sorted[mid - 1] + sorted[mid]) / 2
    }

    // MARK: - Persistence

    /// The versioned on-disk envelope. Kept private and small; the version lets a future format
    /// change be migrated instead of misread as corrupt.
    private struct Envelope: Codable {
        var version: Int
        var entries: [HistoryEntry]
        var waits: [WaitSample]
    }

    private var fileURL: URL {
        root.appendingPathComponent("history.json", isDirectory: false)
    }

    /// Loads and prunes the persisted log. A missing file is a normal first run (empty log); a
    /// corrupt or unreadable file degrades to empty rather than throwing — history is never
    /// worth failing over. Pruning on load bounds a file that grew while the app wasn't running.
    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        guard let envelope = try? JSONDecoder.history.decode(Envelope.self, from: data) else {
            DebugLog.log("history: ignoring unreadable history.json (\(data.count) bytes)")
            return
        }
        let now = Date()
        entries = Self.pruned(envelope.entries, now: now, retention: retention, cap: cap, at: { $0.at })
        waits = Self.pruned(envelope.waits, now: now, retention: retention, cap: cap, at: { $0.at })
    }

    /// Serializes and atomically writes the current envelope with tight permissions (0700 dir,
    /// 0600 file), mirroring how HookServer publishes `server.json`. Any failure is logged and
    /// swallowed: the in-memory log stays authoritative for this launch.
    private func save() {
        let envelope = Envelope(version: currentVersion, entries: entries, waits: waits)
        guard let data = try? JSONEncoder.history.encode(envelope) else {
            DebugLog.log("history: failed to encode envelope; skipping save")
            return
        }
        let fm = FileManager.default
        do {
            try fm.createDirectory(
                at: root,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try data.write(to: fileURL, options: [.atomic])
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            DebugLog.log("history: failed to persist history.json: \(error)")
        }
    }

    /// Drops rows older than `retention` (by the row's own timestamp), then caps the result at
    /// `cap`, keeping the newest. Input is expected newest-first; the age filter preserves order
    /// so `prefix(cap)` keeps the most recent rows.
    private static func pruned<Row>(
        _ rows: [Row],
        now: Date,
        retention: TimeInterval,
        cap: Int,
        at: (Row) -> Date
    ) -> [Row] {
        let cutoff = now.addingTimeInterval(-retention)
        let recent = rows.filter { at($0) >= cutoff }
        return recent.count > cap ? Array(recent.prefix(cap)) : recent
    }
}

private extension JSONEncoder {
    /// Encoder for the history envelope: ISO-8601 dates so the on-disk file is legible and
    /// stable across locales (the default `.deferredToDate` writes a bare `Double`, which is
    /// fine functionally but opaque). Paired with `JSONDecoder.history`.
    static let history: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
}

private extension JSONDecoder {
    static let history: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
