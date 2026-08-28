import XCTest
import Foundation
import TidyCore
import TidyStore
import TidySuggest
import TidyUnderstand

/// `SuggestionEngine` had six call sites, all tests, so `suggestions` sat at 0 rows for the app's
/// entire life while the recap rendered an empty card stack. These tests cover wiring it into the
/// 300s pipeline — which is only safe once regeneration stops destroying what the user decided.
final class SuggestionWiringTests: XCTestCase {
    private let day = "2026-08-28"
    private let from: Int64 = 1_000
    private let to: Int64 = 100_000

    private func seed(_ db: AppDatabase) throws {
        try db.upsertCompanies([PDCompany(id: "c1", name: "Acme", syncedAt: 0)])
        try db.upsertProjects([PDProject(id: "p1", companyId: "c1", name: "Donation Pages", syncedAt: 0)])
        try db.upsertTasks([PDTask(id: "t1", projectId: "p1", title: "Fix selector", syncedAt: 0)])
    }

    @discardableResult
    private func session(_ db: AppDatabase, task: String?, seconds: Int, at: Int64 = 2_000) throws -> Int64 {
        var s = Session(kind: "screen", startedAt: at, endedAt: at + Int64(seconds),
                        durationSeconds: seconds, title: "work", createdAt: 0)
        s.clientId = "c1"; s.projectId = "p1"; s.taskId = task
        s.confidence = 0.9; s.producedByRung = 1
        return try db.insertSession(s)
    }

    // MARK: Regeneration must not undo the user

    /// The pipeline regenerates every 300s. Before this, a tossed card reverted to `pending` and
    /// reappeared within five minutes — the product's core loop silently undoing itself.
    func testDecidedSuggestionsSurviveRegeneration() throws {
        let db = try AppDatabase.inMemory()
        try seed(db)
        try session(db, task: "t1", seconds: 3600)

        let engine = SuggestionEngine(db: db, clock: FixedClock(Date(timeIntervalSince1970: 5)))
        try engine.generate(day: day, from: from, to: to)

        let first = try db.suggestions(day: day)
        XCTAssertEqual(first.count, 1)
        let id = try XCTUnwrap(first[0].id)

        // The user tosses it.
        try db.updateSuggestionStatus(id: id, status: "tossed", now: 10)

        // Two more pipeline passes.
        try engine.generate(day: day, from: from, to: to)
        try engine.generate(day: day, from: from, to: to)

        let after = try db.suggestions(day: day)
        XCTAssertEqual(after.count, 1, "the tossed card must not be duplicated back in")
        XCTAssertEqual(after[0].status, "tossed", "and must stay tossed")
    }

    /// A decided group is not re-proposed under a fresh row either — the check is on attribution
    /// identity, since the row id is gone after a rebuild.
    func testADecidedGroupIsNotReproposed() throws {
        let db = try AppDatabase.inMemory()
        try seed(db)
        try session(db, task: "t1", seconds: 3600)
        let engine = SuggestionEngine(db: db, clock: FixedClock(Date(timeIntervalSince1970: 5)))
        try engine.generate(day: day, from: from, to: to)
        try db.updateSuggestionStatus(id: try XCTUnwrap(try db.suggestions(day: day).first?.id),
                                      status: "logged", now: 10)

        let summary = try engine.generate(day: day, from: from, to: to)
        XCTAssertEqual(summary.skippedAlreadyDecided, 1)
        XCTAssertEqual(try db.suggestions(day: day).filter { $0.status == "pending" }.count, 0,
                       "no duplicate pending card for work already logged")
    }

    /// Pending suggestions still refresh — regeneration must pick up new sessions.
    func testPendingSuggestionsStillRegenerate() throws {
        let db = try AppDatabase.inMemory()
        try seed(db)
        try session(db, task: "t1", seconds: 1800)
        let engine = SuggestionEngine(db: db, clock: FixedClock(Date(timeIntervalSince1970: 5)))
        try engine.generate(day: day, from: from, to: to)
        let before = try XCTUnwrap(try db.suggestions(day: day).first?.minutes)

        // More time on the same task.
        try session(db, task: "t1", seconds: 1800, at: 5_000)
        try engine.generate(day: day, from: from, to: to)

        let after = try XCTUnwrap(try db.suggestions(day: day).first?.minutes)
        XCTAssertGreaterThan(after, before, "an untouched suggestion must reflect new sessions")
    }

    // MARK: Config must actually apply

    /// `suggestions.increment_minutes` / `round_up_bias` were read in exactly one place —
    /// SettingsView, where they were only displayed. Same "configured != enforced" class the repo
    /// has hit before.
    func testRoundingHonoursConfiguredIncrement() throws {
        let db = try AppDatabase.inMemory()
        try seed(db)
        try session(db, task: "t1", seconds: 20 * 60)   // 20 minutes

        let engine = SuggestionEngine(
            db: db, clock: FixedClock(Date(timeIntervalSince1970: 5)),
            rounding: RoundingPolicy(incrementMinutes: 30, roundUpBias: 0.4))
        try engine.generate(day: day, from: from, to: to)

        XCTAssertEqual(try db.suggestions(day: day).first?.minutes, 30,
                       "a 30-minute increment must round 20m to 30m, not to 15m")
    }

    func testStandaloneThresholdIsHonoured() throws {
        let db = try AppDatabase.inMemory()
        try seed(db)
        try session(db, task: "t1", seconds: 20 * 60)

        // Threshold above the session length → it must pool, not stand alone.
        let engine = SuggestionEngine(
            db: db, clock: FixedClock(Date(timeIntervalSince1970: 5)),
            standaloneThresholdMinutes: 45)
        let summary = try engine.generate(day: day, from: from, to: to)
        XCTAssertEqual(summary.standalone, 0, "20m is under a 45m threshold")
    }

    // MARK: Gap analysis needs the task id that only now exists

    /// Time already logged in Productive must be subtracted, not re-suggested. This could never
    /// work before: `pd_time_entries.task_id` was NULL for every row because the mirror was severed.
    func testAlreadyLoggedTimeIsNotResuggested() throws {
        let db = try AppDatabase.inMemory()
        try seed(db)
        try db.upsertPeople([PDPerson(id: "me", name: "Me", isSelf: true, syncedAt: 0)])
        try session(db, task: "t1", seconds: 3600)
        try db.upsertTimeEntries([
            PDTimeEntry(id: "e1", personId: "me", taskId: "t1", date: day, timeMinutes: 60, syncedAt: 0)
        ])

        let engine = SuggestionEngine(db: db, clock: FixedClock(Date(timeIntervalSince1970: 5)),
                                      selfPersonId: "me")
        let summary = try engine.generate(day: day, from: from, to: to)
        XCTAssertEqual(summary.skippedAlreadyLogged, 1,
                       "the hour is already in Productive — do not suggest it again")
    }
}
