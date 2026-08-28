import XCTest
import Foundation
import TidyCore
import TidyStore
import TidySuggest
import TidySurface

/// `daily_rollups` was 0 rows while 3,669 sessions accumulated.
///
/// `RecapAssembler.writeRollup` is the table's only writer, and until this was fixed its only
/// callers in the whole tree were three unit tests — the context-switching metrics from `bf5463f`
/// computed correctly and were persisted by nobody. Nothing surfaced it, because a job that is
/// never invoked cannot log a failure. These tests exist so the call site cannot quietly go away
/// again.
@MainActor
final class DailyRollupWiringTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws { dir = try TestSupport.makeTempDir() }
    override func tearDown() { TestSupport.cleanup(dir) }

    private func makeEnv() throws -> (AppDatabase, AppEnvironment) {
        let db = try AppDatabase.inMemory()
        return (db, AppEnvironment(db: db, config: Config(),
                                   paths: AppPaths(supportDirectory: dir)))
    }

    /// The regression that matters: one pipeline pass must leave a row behind.
    func testPipelinePassWritesADailyRollup() throws {
        let (db, env) = try makeEnv()
        XCTAssertEqual(try db.tableRowCounts()["daily_rollups"], 0)

        env.runPipelineOnce()

        XCTAssertGreaterThan(try db.tableRowCounts()["daily_rollups"] ?? 0, 0,
                             "the periodic pipeline must persist the rollup, not just compute it")
    }

    /// Yesterday is rolled too. The timer only ever knows about the current day, so without this
    /// yesterday's row is frozen at whatever the last pre-midnight pass computed and loses its
    /// final minutes permanently.
    func testBothTodayAndYesterdayAreRolled() throws {
        let (db, env) = try makeEnv()
        env.runPipelineOnce()

        let tz = env.timeZone
        let today = AppEnvironment.dayString(Date(), tz)
        let yesterday = AppEnvironment.dayString(Date().addingTimeInterval(-86_400), tz)

        XCTAssertNotNil(try db.rollup(day: today))
        XCTAssertNotNil(try db.rollup(day: yesterday))
    }

    /// Re-rolling is idempotent — the pipeline runs every 300s and must not accumulate duplicate
    /// rows for the same day.
    func testRepeatedPassesUpsertRatherThanAccumulate() throws {
        let (db, env) = try makeEnv()
        for _ in 0..<4 { env.runPipelineOnce() }
        XCTAssertEqual(try db.tableRowCounts()["daily_rollups"], 2,
                       "today + yesterday, however many times the pipeline runs")
    }

    /// A rollup is written even on a day with no activity. A zero row is a real observation
    /// ("nothing was captured") and is what makes an absent row diagnostic rather than ambiguous.
    func testRollupIsWrittenEvenWithNoSessions() throws {
        let (db, env) = try makeEnv()
        env.runPipelineOnce()
        let today = try XCTUnwrap(try db.rollup(day: AppEnvironment.dayString(Date(), env.timeZone)))
        XCTAssertEqual(today.observedSeconds, 0)
        XCTAssertEqual(today.contextSwitches, 0)
    }
}
