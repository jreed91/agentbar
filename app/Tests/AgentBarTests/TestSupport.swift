import Foundation
import XCTest
@testable import AgentBar

extension XCTestCase {
    /// A `QueueStore` whose activity log is rooted in a unique temporary directory.
    ///
    /// `QueueStore`'s default `HistoryLog` points at the real `~/Library/Application
    /// Support/AgentBar/history.json`. Constructing a store only *reads* that file, but any test
    /// that submits an attention/lifecycle event drives an append or a wait sample, which
    /// *writes* it — clobbering the developer's real history. Injecting a temp-rooted log keeps
    /// every test exercising the identical code path while writing only to a throwaway dir, so
    /// the tests stay honest and side-effect-free. The directory need not be pre-created:
    /// `HistoryLog.save()` creates it on first write, and nothing cleans it up (it's under the
    /// system temp dir).
    @MainActor
    func makeIsolatedQueueStore() -> QueueStore {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("AgentBarTests-\(UUID().uuidString)", isDirectory: true)
        return QueueStore(historyLog: HistoryLog(root: root))
    }
}
