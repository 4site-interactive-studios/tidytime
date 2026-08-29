import XCTest
import Foundation
import TidyCore
import TidyStore
import TidySuggest
import TidyUnderstand

/// "Clicking Log it doesn't actually log any time."
///
/// The report was accurate and the behaviour was correct: v1 never writes to Productive (G1), so
/// the button records a local decision and teaches the classifier. What made it read as broken was
/// everything around it — a label that promised logging, a "min already logged" counter sourced
/// from the Productive mirror that therefore could never move, and a card silently vanishing as the
/// only feedback.
final class RecapGroupingTests: XCTestCase {
    private let day = "2026-08-28"

    private func seed(_ db: AppDatabase) throws {
        try db.upsertCompanies([PDCompany(id: "c1", name: "Acme Foundation", syncedAt: 0)])
        try db.upsertProjects([PDProject(id: "p1", companyId: "c1", name: "Donation Pages", syncedAt: 0)])
        try db.upsertTasks([PDTask(id: "t1", projectId: "p1", title: "Fix the amount selector", syncedAt: 0)])
    }

    @discardableResult
    private func suggestion(_ db: AppDatabase, kind: String, task: String?, project: String? = "p1",
                            minutes: Int = 15, status: String = "pending") throws -> Int64 {
        try db.insertSuggestion(Suggestion(
            day: day, kind: kind, clientId: "c1", projectId: project, taskId: task,
            proposedTaskTitle: kind == "new_task" ? "Amount selector bug" : nil,
            minutes: minutes, rawSeconds: minutes * 60, note: "worked on it",
            confidence: 0.8, producedByRung: 2, status: status, createdAt: 0, updatedAt: 0))
    }

    private func assemble(_ db: AppDatabase) throws -> RecapDay {
        try RecapAssembler(db: db, clock: FixedClock(Date(timeIntervalSince1970: 5)))
            .assemble(day: day, from: 0, to: 100_000)
    }

    // MARK: The two groups

    /// Split on `taskId`, not on `kind` — the question is "can I enter this now, or do I have to go
    /// make something first?". A pool carries a project and no task, so grouping by kind would file
    /// it as "existing" and send the user to Productive to find nothing to log against.
    func testCardsSplitByWhetherATaskExists() throws {
        let db = try AppDatabase.inMemory()
        try seed(db)
        try suggestion(db, kind: "session", task: "t1")
        try suggestion(db, kind: "meeting_segment", task: "t1")
        try suggestion(db, kind: "pool", task: nil)
        try suggestion(db, kind: "new_task", task: nil)

        let recap = try assemble(db)
        XCTAssertEqual(recap.readyToLog.count, 2)
        XCTAssertEqual(recap.needsATask.count, 2)
        XCTAssertTrue(recap.readyToLog.allSatisfy { $0.taskId != nil })
        XCTAssertTrue(recap.needsATask.contains { $0.kind == "pool" },
                      "a pool has a project but no task — it cannot be logged against anything yet")
    }

    /// Every pending card lands in exactly one group; none is dropped.
    func testTheGroupsPartitionTheStack() throws {
        let db = try AppDatabase.inMemory()
        try seed(db)
        for kind in ["session", "pool", "new_task", "meeting_segment"] {
            try suggestion(db, kind: kind, task: kind == "session" ? "t1" : nil)
        }
        let recap = try assemble(db)
        XCTAssertEqual(recap.readyToLog.count + recap.needsATask.count, recap.suggestions.count)
        let grouped = Set((recap.readyToLog + recap.needsATask).compactMap(\.id))
        XCTAssertEqual(grouped, Set(recap.suggestions.compactMap(\.id)))
    }

    /// A decided card belongs to neither group — it is not in `suggestions` at all.
    func testDecidedCardsAreInNeitherGroup() throws {
        let db = try AppDatabase.inMemory()
        try seed(db)
        try suggestion(db, kind: "session", task: "t1", status: "logged")
        try suggestion(db, kind: "pool", task: nil, status: "tossed")
        let recap = try assemble(db)
        XCTAssertTrue(recap.readyToLog.isEmpty)
        XCTAssertTrue(recap.needsATask.isEmpty)
    }

    // MARK: The counter that could never move

    /// `loggedMinutes` reads the Productive mirror. v1 never writes to Productive, so clicking
    /// could not change it — the user marked a card, watched "already logged" sit still, and
    /// concluded the button did nothing. They were reading the UI correctly.
    func testMarkingEnteredMovesTheLocalCounterAndNotTheProductiveOne() throws {
        let db = try AppDatabase.inMemory()
        try seed(db)
        try db.upsertPeople([PDPerson(id: "me", name: "Me", isSelf: true, syncedAt: 0)])
        try db.upsertTimeEntries([
            PDTimeEntry(id: "e1", personId: "me", taskId: "t1", date: day, timeMinutes: 30, syncedAt: 0)
        ])
        let id = try suggestion(db, kind: "session", task: "t1", minutes: 45)

        let assembler = RecapAssembler(db: db, clock: FixedClock(Date(timeIntervalSince1970: 5)),
                                       selfPersonId: "me")
        let before = try assembler.assemble(day: day, from: 0, to: 100_000)
        XCTAssertEqual(before.loggedMinutes, 30)
        XCTAssertEqual(before.markedEnteredMinutes, 0)

        try DecisionRecorder(db: db, clock: FixedClock(Date(timeIntervalSince1970: 10)))
            .record(suggestionId: id, action: "log", clientId: "c1", projectId: "p1", taskId: "t1")

        let after = try assembler.assemble(day: day, from: 0, to: 100_000)
        XCTAssertEqual(after.markedEnteredMinutes, 45, "the number the button controls must move")
        XCTAssertEqual(after.loggedMinutes, 30,
                       "and Productive's number must NOT — nothing was sent there (G1)")
        XCTAssertTrue(after.suggestions.isEmpty, "the card leaves the stack")
    }

    /// Tossing is not entering — it must not inflate the entered total.
    func testTossingDoesNotCountAsEntered() throws {
        let db = try AppDatabase.inMemory()
        try seed(db)
        let id = try suggestion(db, kind: "session", task: "t1", minutes: 60)
        try DecisionRecorder(db: db, clock: FixedClock(Date(timeIntervalSince1970: 10)))
            .record(suggestionId: id, action: "toss", clientId: "c1")
        XCTAssertEqual(try assemble(db).markedEnteredMinutes, 0)
    }

    // MARK: Feedback — the silent no-op

    /// A decision recorded against work that is no longer on this day changes no card. That was
    /// indistinguishable from success, because a vanishing card was the only feedback there was.
    func testRecordReportsWhenNoCardChanged() throws {
        let db = try AppDatabase.inMemory()
        try seed(db)
        let id = try suggestion(db, kind: "session", task: "t1")

        let recorder = DecisionRecorder(db: db, clock: FixedClock(Date(timeIntervalSince1970: 10)))
        let applied = try recorder.record(suggestionId: id, action: "log", clientId: "c1")
        XCTAssertTrue(applied.appliedToSuggestion)

        // A dead id that resolves to nothing: the decision is still recorded, the card is not.
        let orphaned = try recorder.record(suggestionId: 9_999, action: "log", clientId: "c1",
                                           resolve: { _ in nil })
        XCTAssertFalse(orphaned.appliedToSuggestion,
                       "the UI has to be able to tell the user nothing on screen changed")
        XCTAssertEqual(try db.tableRowCounts()["decisions"], 2, "but the decision itself is never lost")
    }

    /// Pins the semantics that a `??` rewrite would silently break. The three cases are distinct
    /// and only one of them is "keep the id you were given".
    func testResolveSemantics() throws {
        let db = try AppDatabase.inMemory()
        try seed(db)
        let live = try suggestion(db, kind: "session", task: "t1")
        let recorder = DecisionRecorder(db: db, clock: FixedClock(Date(timeIntervalSince1970: 10)))

        // 1. No resolve closure → use the id as given.
        XCTAssertTrue(try recorder.record(suggestionId: live, action: "toss").appliedToSuggestion)

        // 2. Resolve returns a live id → use THAT, not the stale one.
        let second = try suggestion(db, kind: "pool", task: nil)
        XCTAssertTrue(try recorder.record(suggestionId: 4_242, action: "log", clientId: "c1",
                                          resolve: { _ in second }).appliedToSuggestion)
        XCTAssertEqual(try db.suggestions(day: day).first { $0.id == second }?.status, "logged")

        // 3. Resolve returns nil → the work is gone. Record the decision, touch no card, and do
        //    NOT fall back to the stale id (which would throw on the foreign key).
        XCTAssertFalse(try recorder.record(suggestionId: 4_242, action: "log", clientId: "c1",
                                           resolve: { _ in nil }).appliedToSuggestion)
    }

    // MARK: G1 stays true

    /// The whole point of the rename: this path must remain read-only against Productive.
    func testMarkingEnteredWritesNothingToProductive() throws {
        let db = try AppDatabase.inMemory()
        try seed(db)
        try db.upsertPeople([PDPerson(id: "me", name: "Me", isSelf: true, syncedAt: 0)])
        let id = try suggestion(db, kind: "session", task: "t1", minutes: 45)
        let before = try db.timeEntries(personId: "me", date: day).count

        try DecisionRecorder(db: db, clock: FixedClock(Date(timeIntervalSince1970: 10)))
            .record(suggestionId: id, action: "log", clientId: "c1", projectId: "p1", taskId: "t1")

        XCTAssertEqual(try db.timeEntries(personId: "me", date: day).count, before,
                       "pd_time_entries is a read-only mirror; marking entered must not forge a row")
    }

    /// The label must not promise the one thing the action does not do.
    func testTheButtonDoesNotClaimToLogToProductive() throws {
        let src = try String(
            contentsOf: TestSupport.repoRoot()
                .appendingPathComponent("Packages/TidyKit/Sources/TidySurface/RecapView.swift"),
            encoding: .utf8)
        XCTAssertFalse(src.contains("Button(\"Log it ✓\")"),
                       "\"Log it\" promised a Productive write that G1 forbids")
        XCTAssertTrue(src.contains("Mark entered ✓"))
        XCTAssertFalse(src.contains("already logged in Productive"),
                       "the empty state asserted Productive state the app cannot know")
    }
}
