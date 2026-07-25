import XCTest
import Foundation
import TidyCore
import TidyStore
import TidyCapture
import TidySuggest
import TidySurface

/// Tests for the app-wiring logic that CAN run headlessly: day bounds, the idempotent session
/// rebuild, the rollups range query, away-gap resolution, nudge presentation, and the diagnostics
/// path. The SwiftUI views themselves are compile-only by design.

final class DayBoundsTests: XCTestCase {
    func testDayBoundsSpanExactlyOneDayInZone() {
        let tz = TimeZone(identifier: "America/New_York")!
        let (from, to) = AppEnvironment.dayBounds(for: Date(timeIntervalSince1970: 1_784_900_000), timeZone: tz)
        XCTAssertEqual(to - from, 86_400)
        // The start must be local midnight in that zone.
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        let comps = cal.dateComponents([.hour, .minute, .second], from: Date(timeIntervalSince1970: TimeInterval(from)))
        XCTAssertEqual(comps.hour, 0); XCTAssertEqual(comps.minute, 0); XCTAssertEqual(comps.second, 0)
    }

    func testDayStringUsesConfiguredZone() {
        // Construct 01:00 UTC explicitly rather than hardcoding an epoch (a hardcoded constant is
        // how this test failed the first time). At 01:00 UTC it is still the previous day in NY.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let instant = cal.date(from: DateComponents(year: 2026, month: 7, day: 22, hour: 1))!
        XCTAssertEqual(AppEnvironment.dayString(instant, TimeZone(identifier: "UTC")!), "2026-07-22")
        XCTAssertEqual(AppEnvironment.dayString(instant, TimeZone(identifier: "America/New_York")!), "2026-07-21")
    }
}

final class SessionRebuildTests: XCTestCase {
    private func seedSamples(_ db: AppDatabase) throws {
        try db.insertSample(ActivitySample(startedAt: 1000, endedAt: 1300, appBundleId: "com.a", appName: "A",
                                           windowTitle: "work", source: "switch", createdAt: 0))
        try db.insertSample(ActivitySample(startedAt: 1300, endedAt: 1600, appBundleId: "com.b", appName: "B",
                                           windowTitle: "other", source: "switch", createdAt: 0))
    }

    /// `run` appends; calling it twice on a live day duplicated sessions. `rebuild` must be idempotent.
    func testRebuildIsIdempotentWhereRunIsNot() throws {
        let db = try AppDatabase.inMemory()
        try seedSamples(db)
        let job = SessionBuildJob(sessionizer: Sessionizer(detourTolerance: 120, minSessionSeconds: 60))

        try job.run(db, from: 0, to: 100_000, now: 1600)
        try job.run(db, from: 0, to: 100_000, now: 1600)
        XCTAssertEqual(try db.sessions(from: 0, to: 100_000).count, 4, "run appends (this is why rebuild exists)")

        try job.rebuild(db, from: 0, to: 100_000, now: 1600)
        XCTAssertEqual(try db.sessions(from: 0, to: 100_000).count, 2, "rebuild replaces")
        try job.rebuild(db, from: 0, to: 100_000, now: 1600)
        XCTAssertEqual(try db.sessions(from: 0, to: 100_000).count, 2, "…and stays stable")
    }

    /// Rebuild must not delete meeting/slack sessions — those are owned by their own sync jobs.
    func testRebuildLeavesMeetingAndSlackSessionsAlone() throws {
        let db = try AppDatabase.inMemory()
        try seedSamples(db)
        try db.insertSession(Session(kind: "meeting", startedAt: 1000, endedAt: 2000, durationSeconds: 1000,
                                     sourceRef: "m1", createdAt: 0))
        try db.insertSession(Session(kind: "slack", startedAt: 1000, endedAt: 1100, durationSeconds: 100,
                                     sourceRef: "C1", createdAt: 0))
        let job = SessionBuildJob(sessionizer: Sessionizer(detourTolerance: 120, minSessionSeconds: 60))
        try job.rebuild(db, from: 0, to: 100_000, now: 1600)
        let kinds = try db.sessions(from: 0, to: 100_000).map(\.kind)
        XCTAssertEqual(kinds.filter { $0 == "meeting" }.count, 1)
        XCTAssertEqual(kinds.filter { $0 == "slack" }.count, 1)
        XCTAssertEqual(kinds.filter { $0 == "screen" }.count, 2)
    }
}

final class RollupsRangeTests: XCTestCase {
    func testRollupsRangeIsInclusiveAndOrdered() throws {
        let db = try AppDatabase.inMemory()
        for day in ["2026-07-19", "2026-07-20", "2026-07-21", "2026-07-22"] {
            try db.upsertRollup(DailyRollup(day: day, observedSeconds: 3600, createdAt: 0, updatedAt: 0))
        }
        let got = try db.rollups(from: "2026-07-20", to: "2026-07-21")
        XCTAssertEqual(got.map(\.day), ["2026-07-20", "2026-07-21"])
    }
}

final class AwayResolverTests: XCTestCase {
    func testPicksOldestSignificantUnresolvedGap() throws {
        let db = try AppDatabase.inMemory()
        // A short gap (below the minimum) and a long one; the prompt should ask about the long one.
        try db.insertAwayGap(AwayGap(startedAt: 100, endedAt: 200, durationSeconds: 100, cause: "idle", createdAt: 0))
        try db.insertAwayGap(AwayGap(startedAt: 300, endedAt: 3300, durationSeconds: 3000, cause: "lock", createdAt: 0))
        let resolver = AwayGapResolver(db: db, clock: FixedClock(Date(timeIntervalSince1970: 9999)))

        let gap = try XCTUnwrap(try resolver.nextUnresolved(from: 0, to: 100_000, minimumSeconds: 300))
        XCTAssertEqual(gap.durationSeconds, 3000)

        try resolver.resolve(gap, attribution: "call", note: "client call")
        XCTAssertNil(try resolver.nextUnresolved(from: 0, to: 100_000, minimumSeconds: 300))
    }
}

final class NudgePresenterTests: XCTestCase {
    func testPresentRecordsAndDelivers() throws {
        let db = try AppDatabase.inMemory()
        let delivery = RecordingNudgeDelivery()
        let presenter = NudgePresenter(db: db, delivery: delivery,
                                       clock: FixedClock(Date(timeIntervalSince1970: 500)))
        let session = Session(id: nil, kind: "screen", startedAt: 0, endedAt: 1800, durationSeconds: 1800,
                              contextKey: "web:acme.org", clientId: "acme", createdAt: 0)
        let id = try presenter.present(session: session, clientName: "Acme", minutes: 30)
        XCTAssertNotNil(id)
        XCTAssertEqual(delivery.delivered.count, 1)
        XCTAssertTrue(delivery.delivered[0].0.contains("Acme"))
        XCTAssertEqual(try db.tableRowCounts()["nudges"], 1)
    }

    func testNoContextKeyMeansNoNudge() throws {
        let db = try AppDatabase.inMemory()
        let delivery = RecordingNudgeDelivery()
        let session = Session(kind: "screen", startedAt: 0, endedAt: 60, durationSeconds: 60, createdAt: 0)
        let id = try NudgePresenter(db: db, delivery: delivery).present(session: session, clientName: "X", minutes: 1)
        XCTAssertNil(id)
        XCTAssertTrue(delivery.delivered.isEmpty)
    }
}

final class FormatTests: XCTestCase {
    func testHoursMinutes() {
        XCTAssertEqual(Format.hoursMinutes(3600), "1h 0m")
        XCTAssertEqual(Format.hoursMinutes(5400), "1h 30m")
        XCTAssertEqual(Format.hoursMinutes(600), "10m")
    }
    func testMinutesAndUSDAndPercent() {
        XCTAssertEqual(Format.minutes(90), "1h 30m")
        XCTAssertEqual(Format.minutes(45), "45m")
        XCTAssertEqual(Format.usd(1.5), "$1.50")
        XCTAssertEqual(Format.percent(0.844), "84%")
    }
}
