import XCTest
import Foundation
import GRDB
import TidyCore
import TidyStore
import TidyCapture
import TidySuggest

/// The lock screen is not work. Idle is not work. Sleep is not work.
///
/// 2026-09-08 audit: 54% of all recorded screen time carried `app:com.apple.loginwindow`, and
/// `away_gaps` had 0 rows after 44 days, because the away subsystem was written, tested, and never
/// called. Every test here is about time NOT being observed: the sample closes at the boundary, one
/// `away_gaps` row records the absence, and no session covers it.
final class AwayCaptureTests: XCTestCase {
    private final class Idle: IdleReading, @unchecked Sendable {
        var seconds: TimeInterval = 0
        func idleSeconds() -> TimeInterval { seconds }
    }

    private struct Rig {
        let db: AppDatabase
        let clock: FixedClock
        let reader: MutableFrontmostReader
        let idle: Idle
        let coord: CaptureCoordinator
    }

    private func rig(app: String = "com.a", threshold: Int = 600) throws -> Rig {
        let db = try AppDatabase.inMemory()
        let clock = FixedClock(Date(timeIntervalSince1970: 10_000))
        let reader = MutableFrontmostReader(FrontmostContext(appBundleId: app, appName: "A", windowTitle: "t"))
        let idle = Idle()
        let coord = CaptureCoordinator(reader: reader, browser: nil,
                                       recorder: SampleRecorder(db: db, clock: clock),
                                       idle: idle, idleThresholdSeconds: threshold, clock: clock)
        return Rig(db: db, clock: clock, reader: reader, idle: idle, coord: coord)
    }

    private func gaps(_ db: AppDatabase) throws -> [AwayGap] { try db.awayGaps(from: 0, to: 1_000_000) }
    private func samples(_ db: AppDatabase) throws -> [ActivitySample] { try db.samples(from: 0, to: 1_000_000) }

    // MARK: Idle

    func testIdleClosesTheSampleWhenInputStoppedAndWritesOneGap() throws {
        let r = try rig()
        XCTAssertTrue(try r.coord.poll())                       // t=10000: sample opens
        r.clock.advance(by: 900); r.idle.seconds = 700          // t=10900, input stopped at 10200
        XCTAssertFalse(try r.coord.poll())
        XCTAssertTrue(r.coord.isAway)
        XCTAssertEqual(try samples(r.db)[0].endedAt, 10_200, "closed when input stopped, not when noticed")

        r.clock.advance(by: 300); r.idle.seconds = 1000         // still idle: nothing new
        XCTAssertFalse(try r.coord.poll())
        XCTAssertEqual(try samples(r.db).count, 1)
        XCTAssertEqual(try gaps(r.db).count, 0, "the gap is written when it ENDS")

        r.clock.advance(by: 1); r.idle.seconds = 0              // t=11201: input resumes
        XCTAssertTrue(try r.coord.poll(), "a fresh sample opens on return")
        XCTAssertFalse(r.coord.isAway)
        let g = try gaps(r.db)
        XCTAssertEqual(g.count, 1)
        XCTAssertEqual(g[0].cause, "idle")
        XCTAssertEqual(g[0].startedAt, 10_200)
        XCTAssertEqual(g[0].endedAt, 11_201)
        XCTAssertEqual(g[0].durationSeconds, 1001)
        XCTAssertEqual(try samples(r.db).count, 2)
        XCTAssertEqual(try samples(r.db)[1].startedAt, 11_201)
    }

    func testIdleBelowThresholdRecordsNothingSpecial() throws {
        let r = try rig()
        _ = try r.coord.poll()
        r.clock.advance(by: 300); r.idle.seconds = 299
        XCTAssertFalse(try r.coord.poll())
        XCTAssertFalse(r.coord.isAway)
        XCTAssertEqual(try gaps(r.db).count, 0)
        XCTAssertNil(try samples(r.db)[0].endedAt)
    }

    // MARK: Lock screen frontmost

    func testLockScreenFrontmostIsAwayNotAnApplication() throws {
        let r = try rig()
        _ = try r.coord.poll()
        r.clock.advance(by: 60)
        r.reader.value = FrontmostContext(appBundleId: "com.apple.loginwindow", appName: "loginwindow")
        XCTAssertFalse(try r.coord.poll())
        XCTAssertTrue(r.coord.isAway)
        XCTAssertEqual(try samples(r.db).count, 1, "no loginwindow row, ever")
        XCTAssertEqual(try samples(r.db)[0].endedAt, 10_060)

        r.clock.advance(by: 3600)                                // an hour locked
        XCTAssertFalse(try r.coord.poll())
        r.reader.value = FrontmostContext(appBundleId: "com.a", appName: "A", windowTitle: "t")
        XCTAssertTrue(try r.coord.poll(), "back: fresh sample, even for the same context")
        let g = try gaps(r.db)
        XCTAssertEqual(g.count, 1)
        XCTAssertEqual(g[0].cause, "lock")
        XCTAssertEqual(g[0].durationSeconds, 3600)
        XCTAssertEqual(try samples(r.db).count, 2)
    }

    // MARK: Notifications

    func testSleepNotificationClosesTheSampleAndWakeEndsTheGap() throws {
        let r = try rig()
        _ = try r.coord.poll()
        try r.coord.awayBegan(cause: "sleep", at: Date(timeIntervalSince1970: 10_100))
        XCTAssertEqual(try samples(r.db)[0].endedAt, 10_100)
        try r.coord.awayEnded(cause: "lock", at: Date(timeIntervalSince1970: 10_500))
        XCTAssertTrue(r.coord.isAway, "an unlock does not end a sleep gap")
        try r.coord.awayEnded(cause: "sleep", at: Date(timeIntervalSince1970: 20_000))
        XCTAssertFalse(r.coord.isAway)
        let g = try gaps(r.db)
        XCTAssertEqual(g.map(\.cause), ["sleep"])
        XCTAssertEqual(g[0].durationSeconds, 9900)
    }

    func testLockDuringIdleIsOneGapWithTheEarlierStartAndTheSpecificCause() throws {
        let r = try rig()
        _ = try r.coord.poll()
        r.clock.advance(by: 700); r.idle.seconds = 650           // idle since 10050
        _ = try r.coord.poll()
        try r.coord.awayBegan(cause: "lock", at: Date(timeIntervalSince1970: 10_900))
        r.clock.advance(by: 3000); r.idle.seconds = 0            // unlock: input
        r.reader.value = FrontmostContext(appBundleId: "com.apple.loginwindow", appName: "loginwindow")
        XCTAssertFalse(try r.coord.poll(), "input at the lock screen is not a return")
        try r.coord.awayEnded(cause: "lock", at: Date(timeIntervalSince1970: 13_700))
        let g = try gaps(r.db)
        XCTAssertEqual(g.count, 1)
        XCTAssertEqual(g[0].cause, "lock")
        XCTAssertEqual(g[0].startedAt, 10_050)
        XCTAssertEqual(g[0].endedAt, 13_700)
    }

    func testWakeWhileStillLockedDoesNotEndTheLockGap() throws {
        let r = try rig()
        _ = try r.coord.poll()
        try r.coord.awayBegan(cause: "lock", at: Date(timeIntervalSince1970: 10_100))
        try r.coord.awayBegan(cause: "sleep", at: Date(timeIntervalSince1970: 10_200))   // lid closed
        try r.coord.awayEnded(cause: "sleep", at: Date(timeIntervalSince1970: 40_000))   // lid opened
        XCTAssertTrue(r.coord.isAway)
        try r.coord.awayEnded(cause: "lock", at: Date(timeIntervalSince1970: 40_010))
        XCTAssertFalse(r.coord.isAway)
        XCTAssertEqual(try gaps(r.db).map(\.cause), ["lock"])
        XCTAssertEqual(try gaps(r.db)[0].durationSeconds, 29_910)
    }

    // MARK: Stop

    func testSuspendClosesTheOpenSampleAndBanksAnOpenGap() throws {
        let r = try rig()
        _ = try r.coord.poll()
        r.clock.advance(by: 100)
        try r.coord.suspend()
        XCTAssertEqual(try samples(r.db)[0].endedAt, 10_100)
        r.clock.advance(by: 100)
        XCTAssertTrue(try r.coord.poll(), "resume records fresh")
        r.clock.advance(by: 1000); r.idle.seconds = 800
        _ = try r.coord.poll()
        r.clock.advance(by: 10)
        try r.coord.suspend()
        XCTAssertEqual(try gaps(r.db).count, 1, "an open gap is written on suspend, not lost")
        XCTAssertFalse(r.coord.isAway)
    }

    func testCloseOpenSampleClampsToTheSampleStart() throws {
        // A title change with no input opens a sample AFTER input stopped; the backdated idle
        // boundary must not leave it open (it would then stretch to the next record).
        let db = try AppDatabase.inMemory()
        let recorder = SampleRecorder(db: db, clock: FixedClock(Date(timeIntervalSince1970: 5000)))
        _ = try recorder.record(FrontmostContext(appBundleId: "com.a", appName: "A"))
        try recorder.closeOpenSample(at: 4000)
        let s = try db.samples(from: 0, to: 10_000)[0]
        XCTAssertEqual(s.endedAt, 5000)
    }

    // MARK: Sessionization

    func testSessionsAreClippedAtAwayGaps() throws {
        let db = try AppDatabase.inMemory()
        let clock = FixedClock(Date(timeIntervalSince1970: 100_000))
        let recorder = SampleRecorder(db: db, clock: clock)
        _ = try recorder.record(FrontmostContext(appBundleId: "com.a", appName: "A", windowTitle: "doc"))
        clock.advance(by: 7200)
        try recorder.closeOpenSample(at: 107_200)
        // Pretend the gap was never detected live (pre-fix history) — the sample spans 2h, the gap
        // is known only from away_gaps.
        try recorder.recordAwayGap(AwayGapDraft(start: 101_000, end: 106_000, durationSeconds: 5000, cause: "lock"))
        let job = SessionBuildJob(sessionizer: Sessionizer(detourTolerance: 120, minSessionSeconds: 60), clock: clock)
        _ = try job.rebuild(db, from: 100_000, to: 110_000, now: 107_200)
        let sessions = try db.sessions(from: 0, to: 200_000)
        XCTAssertEqual(sessions.map { ($0.startedAt, $0.endedAt) }.map { "\($0.0)-\($0.1)" },
                       ["100000-101000", "106000-107200"])
        XCTAssertEqual(sessions.reduce(0) { $0 + $1.durationSeconds }, 2200)
    }

    func testLockScreenSamplesNeverBecomeSessions() throws {
        let db = try AppDatabase.inMemory()
        try db.writer.write { d in
            try d.execute(sql: """
                INSERT INTO activity_samples (id, started_at, ended_at, app_bundle_id, app_name, is_browser, source, created_at)
                VALUES (1, 1000, 2000, 'com.a', 'A', 0, 'switch', 1000),
                       (2, 2000, 40000, 'com.apple.loginwindow', 'loginwindow', 0, 'switch', 2000),
                       (3, 40000, 41000, 'com.a', 'A', 0, 'switch', 40000)
                """)
        }
        let job = SessionBuildJob(sessionizer: Sessionizer(detourTolerance: 120, minSessionSeconds: 60))
        _ = try job.run(db, from: 0, to: 50_000, now: 41_000)
        XCTAssertFalse(try db.sessions(from: 0, to: 50_000).contains { $0.contextKey == "app:com.apple.loginwindow" })
    }

    // MARK: History

    func testBackfillConvertsLockScreenSamplesIntoAwayGaps() throws {
        let db = try AppDatabase.inMemory()
        try db.writer.write { d in
            try d.execute(sql: """
                INSERT INTO activity_samples (id, started_at, ended_at, app_bundle_id, app_name, is_browser, source, created_at)
                VALUES (1, 1000, 2000, 'com.a', 'A', 0, 'switch', 1000),
                       (2, 2000, NULL, 'com.apple.loginwindow', 'loginwindow', 0, 'switch', 2000),
                       (3, 40000, 41000, 'com.a', 'A', 0, 'switch', 40000),
                       (4, 41000, 50000, 'com.apple.loginwindow', 'loginwindow', 0, 'switch', 41000),
                       (5, 50000, 90000, 'com.b', 'B', 0, 'switch', 50000)
                """)
            try d.execute(sql: """
                INSERT INTO sessions (kind, started_at, ended_at, duration_seconds, context_key, primary_app, created_at)
                VALUES ('screen', 1000, 2000, 1000, 'app:com.a', 'com.a', 0),
                       ('screen', 2000, 40000, 38000, 'app:com.apple.loginwindow', 'com.apple.loginwindow', 0),
                       ('screen', 40000, 41000, 1000, 'app:com.a', 'com.a', 0),
                       ('slack', 2000, 2100, 100, 'slack:c1', NULL, 0)
                """)
        }
        let report = try db.writer.write { try AwayGapBackfill.apply($0, now: 99) }
        XCTAssertEqual(report.gapsInserted, 2)
        XCTAssertEqual(report.samplesDeleted, 2)
        XCTAssertEqual(report.sessionsDeleted, 1)
        XCTAssertEqual(report.unattendedSamplesLeft, 1, "the 11-hour com.b sample is left, and counted")
        let g = try db.awayGaps(from: 0, to: 100_000)
        XCTAssertEqual(g.map { [$0.startedAt, $0.endedAt] }, [[2000, 40000], [41000, 50000]])
        XCTAssertEqual(g.map(\.cause), ["lock", "lock"])
        XCTAssertEqual(try db.samples(from: 0, to: 100_000).map(\.appBundleId), ["com.a", "com.a", "com.b"])
        XCTAssertEqual(try db.sessions(from: 0, to: 100_000).count, 3, "screen neighbours and the slack session survive")
    }

    func testBackfillIsRegisteredAndIdempotent() throws {
        let db = try AppDatabase.inMemory()
        XCTAssertTrue(try db.appliedMigrations().contains("v3-loginwindow-away-gaps"))
        XCTAssertEqual(try db.writer.write { try AwayGapBackfill.apply($0) }, AwayGapBackfill.Report())
    }

    func testAwayAppListsAgree() {
        XCTAssertEqual(Set(AwayGapBackfill.awayBundleIds), AwayApps.bundleIds)
    }

    func testRollupBackfillRerollsEveryDayOnce() throws {
        let db = try AppDatabase.inMemory()
        let tz = TimeZone(identifier: "UTC")!
        // Two sessions on two consecutive UTC days.
        try db.writer.write { d in
            try d.execute(sql: """
                INSERT INTO sessions (kind, started_at, ended_at, duration_seconds, context_key, primary_app, created_at)
                VALUES ('screen', 86400, 90000, 3600, 'app:com.a', 'com.a', 0),
                       ('screen', 172800, 180000, 7200, 'app:com.a', 'com.a', 0)
                """)
        }
        let clock = FixedClock(Date(timeIntervalSince1970: 200_000))
        let job = RollupBackfillJob(db: db, assembler: RecapAssembler(db: db, clock: clock), timeZone: tz, clock: clock)
        XCTAssertEqual(try job.runIfNeeded(), 2, "the earliest session's day through today")
        let rollups = try db.writer.read { try Row.fetchAll($0, sql: "SELECT day, observed_seconds FROM daily_rollups ORDER BY day") }
        XCTAssertEqual(rollups.map { ($0["day"] as String) + "=" + String($0["observed_seconds"] as Int) },
                       ["1970-01-02=3600", "1970-01-03=7200"])
        XCTAssertEqual(try job.runIfNeeded(), 0, "second run is a no-op")
        XCTAssertEqual(try db.metadata(MetadataKey.rollupsRecomputedFor), RollupBackfillJob.currentVersion)
    }
}
