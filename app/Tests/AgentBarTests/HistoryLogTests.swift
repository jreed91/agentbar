import XCTest
@testable import AgentBar

/// Tests for `HistoryLog` — the persistence and daily-digest engine behind the activity log.
/// Rooted in a unique temp directory per test so nothing touches the real Application Support
/// tree. Covers the round-trip survival of entries + waits, the 7-day/1000-row retention on
/// both load and append, the digest rollup (status counts, distinct/busiest project with a
/// deterministic tie-break, median/max waits, empty day), and graceful handling of a corrupt
/// file.
@MainActor
final class HistoryLogTests: XCTestCase {

    /// A unique throwaway store root under the system temp directory. Not pre-created —
    /// `HistoryLog` makes it on first save.
    private func makeRoot() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("HistoryLogTests-\(UUID().uuidString)", isDirectory: true)
    }

    /// ISO-8601 formatter matching `JSONDecoder.iso8601`, for hand-writing envelope files.
    private let iso = ISO8601DateFormatter()

    /// Writes a raw `history.json` envelope so a test can seed on-disk state the public API
    /// would prune away before it reached disk (old entries, an over-cap count).
    private func writeEnvelope(at root: URL, entriesJSON: String, waitsJSON: String = "") {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let json = "{\"version\":1,\"entries\":[\(entriesJSON)],\"waits\":[\(waitsJSON)]}"
        try? Data(json.utf8).write(to: root.appendingPathComponent("history.json"))
    }

    private func entryJSON(
        id: UUID = UUID(), at: Date, project: String = "p",
        status: String = "done", summary: String = "s"
    ) -> String {
        """
        {"id":"\(id.uuidString)","at":"\(iso.string(from: at))","project":"\(project)","status":"\(status)","summary":"\(summary)"}
        """
    }

    // MARK: - Round trip

    func testEntriesAndWaitsSurviveAcrossInstances() {
        let root = makeRoot()
        let first = HistoryLog(root: root)

        let e1 = HistoryEntry(at: Date(), project: "alpha", status: .done, summary: "finished")
        let e2 = HistoryEntry(at: Date(), project: "beta", status: .question, summary: "asked")
        first.append(e1)
        first.append(e2)
        first.record(wait: WaitSample(at: Date(), seconds: 42))

        // A fresh instance on the same root is a relaunch: it must reload what was written.
        let second = HistoryLog(root: root)
        XCTAssertEqual(second.entries.count, 2)
        XCTAssertEqual(second.waits.count, 1)
        // Newest-first: the second append is first.
        XCTAssertEqual(second.entries.map(\.summary), ["asked", "finished"])
        XCTAssertEqual(second.entries.map(\.status), [.question, .done])
        XCTAssertEqual(second.entries.map(\.id), [e2.id, e1.id], "identity must round-trip")
        XCTAssertEqual(second.waits.first?.seconds, 42)
    }

    // MARK: - Retention

    func testAppendPrunesEntriesOlderThanSevenDays() {
        let log = HistoryLog(root: makeRoot())
        log.append(HistoryEntry(at: Date().addingTimeInterval(-8 * 24 * 3600),
                                project: "x", status: .done, summary: "stale"))
        XCTAssertTrue(log.entries.isEmpty, "an entry older than 7 days is dropped on append")

        log.append(HistoryEntry(at: Date(), project: "x", status: .done, summary: "fresh"))
        XCTAssertEqual(log.entries.map(\.summary), ["fresh"])
    }

    func testLoadDropsEntriesOlderThanSevenDays() {
        let root = makeRoot()
        let recent = entryJSON(at: Date(), summary: "recent")
        let stale = entryJSON(at: Date().addingTimeInterval(-8 * 24 * 3600), summary: "stale")
        writeEnvelope(at: root, entriesJSON: "\(recent),\(stale)")

        let log = HistoryLog(root: root)
        XCTAssertEqual(log.entries.map(\.summary), ["recent"],
                       "load drops entries past the 7-day window")
    }

    func testLoadCapsAtOneThousandNewest() {
        let root = makeRoot()
        let now = Date()
        // 1100 entries, all within the window, newest-first (e0 newest).
        let rows = (0..<1100).map { entryJSON(at: now.addingTimeInterval(-Double($0)), summary: "e\($0)") }
        writeEnvelope(at: root, entriesJSON: rows.joined(separator: ","))

        let log = HistoryLog(root: root)
        XCTAssertEqual(log.entries.count, 1000, "load caps the log at 1000 rows")
        XCTAssertEqual(log.entries.first?.summary, "e0", "the newest rows are the ones kept")
        XCTAssertEqual(log.entries.last?.summary, "e999")
    }

    // MARK: - Digest

    func testDigestCountsByStatusAndProjects() {
        let log = HistoryLog(root: makeRoot())
        let today = Date()
        log.append(HistoryEntry(at: today, project: "agentbar", status: .done, summary: ""))
        log.append(HistoryEntry(at: today, project: "agentbar", status: .done, summary: ""))
        log.append(HistoryEntry(at: today, project: "web", status: .question, summary: ""))
        log.append(HistoryEntry(at: today, project: "web", status: .permission, summary: ""))
        log.append(HistoryEntry(at: today, project: "api", status: .error, summary: ""))

        let digest = log.digest(for: today)
        XCTAssertEqual(digest.entryCount, 5)
        XCTAssertEqual(digest.finished, 2)
        XCTAssertEqual(digest.questions, 1)
        XCTAssertEqual(digest.permissions, 1)
        XCTAssertEqual(digest.errors, 1)
        XCTAssertEqual(digest.projects, 3)
        XCTAssertEqual(digest.busiestProject, "agentbar", "the project with the most entries")
        XCTAssertTrue(digest.hasActivity)
    }

    func testDigestBusiestTieBrokenAlphabetically() {
        let log = HistoryLog(root: makeRoot())
        let today = Date()
        log.append(HistoryEntry(at: today, project: "zebra", status: .done, summary: ""))
        log.append(HistoryEntry(at: today, project: "apple", status: .done, summary: ""))

        XCTAssertEqual(log.digest(for: today).busiestProject, "apple",
                       "a tie is broken by the alphabetically-first name, deterministically")
    }

    func testDigestMedianOddCountAndMax() {
        let log = HistoryLog(root: makeRoot())
        let today = Date()
        log.record(wait: WaitSample(at: today, seconds: 10))
        log.record(wait: WaitSample(at: today, seconds: 40))
        log.record(wait: WaitSample(at: today, seconds: 20))

        let digest = log.digest(for: today)
        XCTAssertEqual(digest.medianWait, 20, "sorted [10,20,40] → middle 20")
        XCTAssertEqual(digest.maxWait, 40)
    }

    func testDigestMedianEvenCount() {
        let log = HistoryLog(root: makeRoot())
        let today = Date()
        for seconds in [10.0, 30.0, 20.0, 50.0] {
            log.record(wait: WaitSample(at: today, seconds: seconds))
        }

        // sorted [10,20,30,50] → mean of the two middles (20 + 30) / 2 = 25.
        XCTAssertEqual(log.digest(for: today).medianWait, 25)
    }

    func testEmptyDayIsZeroedWithNilWaits() {
        let log = HistoryLog(root: makeRoot())
        // Activity today, but the digest asks about yesterday → nothing in range.
        log.append(HistoryEntry(at: Date(), project: "p", status: .done, summary: ""))
        let yesterday = Date().addingTimeInterval(-24 * 3600)

        let digest = log.digest(for: yesterday)
        XCTAssertEqual(digest, .empty)
        XCTAssertFalse(digest.hasActivity)
        XCTAssertNil(digest.medianWait)
        XCTAssertNil(digest.maxWait)
        XCTAssertNil(digest.busiestProject)
    }

    // MARK: - View slice

    func testEntriesForViewCapsAtOneHundred() {
        let log = HistoryLog(root: makeRoot())
        let now = Date()
        for index in 0..<150 {
            log.append(HistoryEntry(at: now.addingTimeInterval(Double(index)),
                                    project: "p", status: .done, summary: "e\(index)"))
        }
        XCTAssertEqual(log.entries.count, 150, "the full log is retained")
        XCTAssertEqual(log.entriesForView.count, 100, "but the view slice is bounded")
        // Newest-first, and each append inserts at the front, so the last appended is first.
        XCTAssertEqual(log.entriesForView.first?.summary, "e149")
    }

    // MARK: - Corrupt file

    func testCorruptFileLoadsAsEmpty() {
        let root = makeRoot()
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? Data("this is not json {{{".utf8)
            .write(to: root.appendingPathComponent("history.json"))

        let log = HistoryLog(root: root)
        XCTAssertTrue(log.entries.isEmpty, "garbage on disk must load as empty, not crash")
        XCTAssertTrue(log.waits.isEmpty)

        // And the log is still usable afterward — a corrupt file doesn't wedge it.
        log.append(HistoryEntry(at: Date(), project: "p", status: .done, summary: "ok"))
        XCTAssertEqual(log.entries.count, 1)

        let reloaded = HistoryLog(root: root)
        XCTAssertEqual(reloaded.entries.count, 1, "the append overwrote the corrupt file cleanly")
    }
}
