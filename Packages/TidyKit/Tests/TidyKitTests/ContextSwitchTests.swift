import XCTest
import Foundation
import TidyCore
import TidyStore
import TidySuggest

final class ContextSwitchAnalyzerTests: XCTestCase {
    private func sample(_ start: Int64, _ end: Int64, app: String, title: String?, url: String? = nil, browser: Bool = false) -> ActivitySample {
        ActivitySample(startedAt: start, endedAt: end, appBundleId: app, appName: app,
                       windowTitle: title, isBrowser: browser, url: url, source: "switch", createdAt: 0)
    }

    /// The agentic-tool thrash case: chat1 → chat2 → Cowork → chat1, all inside ONE app, sub-minute
    /// switches included. Sessionization would drop the short ones; the metric counts them.
    func testWithinAppThrashIsCounted() {
        let claude = "com.anthropic.claude"
        let samples = [
            sample(0, 30, app: claude, title: "chat 1"),      // 30s brief
            sample(30, 45, app: claude, title: "chat 2"),     // 15s brief
            sample(45, 345, app: claude, title: "cowork"),    // 300s focus
            sample(345, 465, app: claude, title: "chat 1"),   // 120s
        ]
        let m = ContextSwitchAnalyzer(briefThresholdSeconds: 120).analyze(samples, now: 465)
        XCTAssertEqual(m.switchCount, 3)             // 4 runs → 3 transitions
        XCTAssertEqual(m.uniqueContexts, 3)          // chat 1, chat 2, cowork
        XCTAssertEqual(m.activeSeconds, 465)
        XCTAssertEqual(m.briefSwitches, 2)           // the 30s + 15s runs (<120s)
        XCTAssertEqual(m.longestFocusSeconds, 300)   // cowork
        XCTAssertEqual(m.medianDwellSeconds, 75, accuracy: 0.01)  // median of [15,30,120,300]
        XCTAssertEqual(m.fragmentation, 2.0 / 3.0, accuracy: 0.01)
        XCTAssertEqual(m.switchesPerActiveHour, 3.0 / (465.0 / 3600.0), accuracy: 0.01)
    }

    func testBrowserTabsCountAsDistinctContexts() {
        let chrome = "com.google.Chrome"
        let samples = [
            sample(0, 60, app: chrome, title: "chat", url: "https://claude.ai/chat/1", browser: true),
            sample(60, 120, app: chrome, title: "cowork", url: "https://claude.ai/cowork", browser: true),
        ]
        let m = ContextSwitchAnalyzer().analyze(samples, now: 120)
        XCTAssertEqual(m.switchCount, 1)
        XCTAssertEqual(m.uniqueContexts, 2)   // different URLs → different contexts
    }

    func testSteadyFocusHasNoSwitches() {
        let m = ContextSwitchAnalyzer().analyze([sample(0, 3600, app: "com.a", title: "one thing")], now: 3600)
        XCTAssertEqual(m.switchCount, 0)
        XCTAssertEqual(m.uniqueContexts, 1)
        XCTAssertEqual(m.longestFocusSeconds, 3600)
        XCTAssertEqual(m.fragmentation, 0)
    }

    func testEmpty() {
        XCTAssertEqual(ContextSwitchAnalyzer().analyze([], now: 0), .empty)
    }
}

final class ContextSwitchRecapTests: XCTestCase {
    func testRecapAndRollupCarryContextSwitches() throws {
        let db = try AppDatabase.inMemory()
        let claude = "com.anthropic.claude"
        // three within-app samples → 2 switches
        try db.insertSample(ActivitySample(startedAt: 0, endedAt: 30, appBundleId: claude, appName: "Claude", windowTitle: "chat 1", source: "switch", createdAt: 0))
        try db.insertSample(ActivitySample(startedAt: 30, endedAt: 400, appBundleId: claude, appName: "Claude", windowTitle: "cowork", source: "switch", createdAt: 0))
        try db.insertSample(ActivitySample(startedAt: 400, endedAt: 500, appBundleId: claude, appName: "Claude", windowTitle: "chat 1", source: "switch", createdAt: 0))

        let assembler = RecapAssembler(db: db, clock: FixedClock(Date(timeIntervalSince1970: 5)))
        let recap = try assembler.assemble(day: "2026-07-22", from: 0, to: 1_000_000)
        XCTAssertEqual(recap.contextSwitches.switchCount, 2)
        XCTAssertEqual(recap.contextSwitches.uniqueContexts, 2)

        let rollup = try assembler.writeRollup(day: "2026-07-22", from: 0, to: 1_000_000)
        XCTAssertEqual(rollup.contextSwitches, 2)
        XCTAssertEqual(try db.rollup(day: "2026-07-22")?.contextSwitches, 2)   // persisted for trends
    }

    func testV2MigrationApplied() throws {
        let db = try AppDatabase.inMemory()
        XCTAssertTrue(try db.appliedMigrations().contains("v2-context-switches"))
    }
}
