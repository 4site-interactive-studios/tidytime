import XCTest
import Foundation
import TidyCore
import TidyStore
import TidySuggest

final class RoundingPolicyTests: XCTestCase {
    func testRoundsWithBiasAndMinimumIncrement() {
        let r = RoundingPolicy(incrementMinutes: 15, roundUpBias: 0.4)
        XCTAssertEqual(r.rounded(seconds: 6 * 60).minutes, 15)      // min one increment
        XCTAssertTrue(r.rounded(seconds: 6 * 60).roundedUp)
        XCTAssertEqual(r.rounded(seconds: 15 * 60).minutes, 15)
        XCTAssertFalse(r.rounded(seconds: 15 * 60).roundedUp)
        XCTAssertEqual(r.rounded(seconds: 20 * 60).minutes, 15)     // 1.33 units, biased still rounds down
        XCTAssertEqual(r.rounded(seconds: 24 * 60).minutes, 30)     // 1.6 units + 0.4 → 2
        XCTAssertTrue(r.rounded(seconds: 24 * 60).roundedUp)
        XCTAssertEqual(r.rounded(seconds: 90 * 60).minutes, 90)
        XCTAssertEqual(r.rounded(seconds: 0).minutes, 0)
    }
}

final class SuggestionEngineTests: XCTestCase {
    private let day = "2026-07-22"
    private func dayBounds() -> (Int64, Int64) { (0, 1_000_000) }

    /// A classified task session over threshold → one standalone suggestion.
    func testStandaloneSuggestion() throws {
        let db = try AppDatabase.inMemory()
        try db.insertSession(Session(kind: "screen", startedAt: 100, endedAt: 100 + 40 * 60,
                                     durationSeconds: 40 * 60, title: "Donation form",
                                     clientId: "acme", projectId: "p1", taskId: "t1",
                                     confidence: 0.9, producedByRung: 1, createdAt: 0))
        let engine = SuggestionEngine(db: db, clock: FixedClock(Date(timeIntervalSince1970: 5)))
        let summary = try engine.generate(day: day, from: dayBounds().0, to: dayBounds().1)
        XCTAssertEqual(summary.standalone, 1)
        let s = try db.suggestions(day: day).first
        XCTAssertEqual(s?.taskId, "t1")
        XCTAssertEqual(s?.kind, "session")
        XCTAssertEqual(s?.minutes, 45)   // 40 min → 45 (biased up)
        XCTAssertEqual(s?.rawSeconds, 40 * 60)
    }

    /// Sub-threshold fragments on different tasks of one project pool into one rolled-up suggestion.
    func testPooling() throws {
        let db = try AppDatabase.inMemory()
        // 5-min and 6-min bits on the same project but different tasks → two sub-threshold groups
        // that pool per-project (11 min total) and roll up at recap.
        try db.insertSession(Session(kind: "slack", startedAt: 0, endedAt: 300, durationSeconds: 300,
                                     title: "help Nick", contextKey: "slack:C1", sourceRef: "C1",
                                     clientId: "acme", projectId: "p1", taskId: "t1",
                                     confidence: 0.6, producedByRung: 2, createdAt: 0))
        try db.insertSession(Session(kind: "slack", startedAt: 1000, endedAt: 1360, durationSeconds: 360,
                                     title: "review staging", contextKey: "slack:C1", sourceRef: "C1",
                                     clientId: "acme", projectId: "p1", taskId: "t2",
                                     confidence: 0.6, producedByRung: 2, createdAt: 0))
        let engine = SuggestionEngine(db: db, clock: FixedClock(Date(timeIntervalSince1970: 5)))
        let summary = try engine.generate(day: day, from: dayBounds().0, to: dayBounds().1)
        XCTAssertEqual(summary.standalone, 0)
        XCTAssertEqual(summary.pools, 1)
        let pool = try db.suggestions(day: day).first { $0.kind == "pool" }
        XCTAssertNotNil(pool)
        XCTAssertEqual(pool?.rawSeconds, 300 + 360)
        XCTAssertEqual(pool?.projectId, "p1")
        XCTAssertEqual(try db.pools(day: day).count, 1)
    }

    /// A client/project session with no task → new-task proposal.
    func testNewTaskProposal() throws {
        let db = try AppDatabase.inMemory()
        try db.insertSession(Session(kind: "screen", startedAt: 0, endedAt: 30 * 60, durationSeconds: 30 * 60,
                                     title: "Acme audit prep", clientId: "acme", projectId: "p1",
                                     confidence: 0.7, producedByRung: 2, createdAt: 0))
        let engine = SuggestionEngine(db: db, clock: FixedClock(Date(timeIntervalSince1970: 5)))
        let summary = try engine.generate(day: day, from: dayBounds().0, to: dayBounds().1)
        XCTAssertEqual(summary.newTaskProposals, 1)
        let s = try db.suggestions(day: day).first
        XCTAssertEqual(s?.kind, "new_task")
        XCTAssertEqual(s?.proposedTaskTitle, "Acme audit prep")
    }

    /// Gap analysis: if the task is already fully logged, don't suggest it again.
    func testGapAnalysisSkipsAlreadyLogged() throws {
        let db = try AppDatabase.inMemory()
        try db.upsertPeople([PDPerson(id: "me", name: "Bryan", isSelf: true, syncedAt: 1)])
        try db.upsertTimeEntries([PDTimeEntry(id: "e1", personId: "me", taskId: "t1", date: day,
                                              timeMinutes: 15, syncedAt: 1)])
        try db.insertSession(Session(kind: "screen", startedAt: 0, endedAt: 20 * 60, durationSeconds: 20 * 60,
                                     title: "Task work", clientId: "acme", projectId: "p1", taskId: "t1",
                                     confidence: 0.9, producedByRung: 1, createdAt: 0))
        let engine = SuggestionEngine(db: db, clock: FixedClock(Date(timeIntervalSince1970: 5)), selfPersonId: "me")
        let summary = try engine.generate(day: day, from: dayBounds().0, to: dayBounds().1)
        // 20 min → rounded 15; already logged 15 → remaining 0 → skipped
        XCTAssertEqual(summary.skippedAlreadyLogged, 1)
        XCTAssertEqual(summary.standalone, 0)
        XCTAssertTrue(try db.suggestions(day: day).isEmpty)
    }
}

final class RecapAssemblerTests: XCTestCase {
    func testAssemblesReadModelAndRollup() throws {
        let db = try AppDatabase.inMemory()
        try db.insertSession(Session(kind: "screen", startedAt: 0, endedAt: 600, durationSeconds: 600,
                                     clientId: "acme", confidence: 0.9, producedByRung: 1, createdAt: 0))
        try db.insertSession(Session(kind: "screen", startedAt: 700, endedAt: 1000, durationSeconds: 300,
                                     createdAt: 0))  // unclassified
        let assembler = RecapAssembler(db: db, clock: FixedClock(Date(timeIntervalSince1970: 5)))
        let recap = try assembler.assemble(day: "2026-07-22", from: 0, to: 100_000)
        XCTAssertEqual(recap.timeline.count, 2)
        XCTAssertEqual(recap.observedSeconds, 900)
        XCTAssertEqual(recap.attributedSeconds, 600)
        XCTAssertEqual(recap.attributionRate, 600.0 / 900.0, accuracy: 0.001)

        let rollup = try assembler.writeRollup(day: "2026-07-22", from: 0, to: 100_000)
        XCTAssertEqual(rollup.observedSeconds, 900)
        XCTAssertEqual(try db.rollup(day: "2026-07-22")?.attributedSeconds, 600)
    }
}
