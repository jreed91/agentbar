import XCTest
@testable import AgentBar

/// Tests for the pure logic behind the Setup panel: the relative-time phrasing used by the
/// "Last event <…> ago" rows. The view wiring and filesystem/permission checks aren't unit
/// tested (no pure surface); only `relativeAgo` is.
final class SetupChecksTests: XCTestCase {
    /// A fixed reference "now" so the labels are deterministic.
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func ago(_ seconds: TimeInterval) -> String {
        SetupChecks.relativeAgo(from: now.addingTimeInterval(-seconds), to: now)
    }

    func testSubFiveSecondsReadsJustNow() {
        XCTAssertEqual(ago(0), "just now")
        XCTAssertEqual(ago(4), "just now")
    }

    func testSeconds() {
        XCTAssertEqual(ago(5), "5s ago")
        XCTAssertEqual(ago(59), "59s ago")
    }

    func testMinutes() {
        XCTAssertEqual(ago(60), "1m ago")
        XCTAssertEqual(ago(125), "2m ago")
        XCTAssertEqual(ago(59 * 60), "59m ago")
    }

    func testHours() {
        XCTAssertEqual(ago(60 * 60), "1h ago")
        XCTAssertEqual(ago(3 * 60 * 60 + 100), "3h ago")
        XCTAssertEqual(ago(23 * 60 * 60), "23h ago")
    }

    func testDays() {
        XCTAssertEqual(ago(24 * 60 * 60), "1d ago")
        XCTAssertEqual(ago(2 * 24 * 60 * 60 + 3600), "2d ago")
    }

    /// A clock skew that puts the event slightly in the future clamps to "just now" rather
    /// than producing a negative interval.
    func testFutureClampsToJustNow() {
        XCTAssertEqual(SetupChecks.relativeAgo(from: now.addingTimeInterval(30), to: now), "just now")
    }
}
