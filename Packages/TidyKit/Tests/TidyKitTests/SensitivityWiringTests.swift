import XCTest
import Foundation
import TidyCore
import TidyStore
import TidySuggest
import TidyUnderstand

/// G2 had zero production callers.
///
/// The gate was specified to run before rungs 3–4 and note generation — cloud sends, which are
/// Phase 6 and dark, so having nothing to guard *there* is correct. What was missed is that the
/// exposure had already shipped by another route: window titles were copied verbatim into
/// `suggestions.note` and `proposed_task_title`, the two fields whose entire purpose is to be
/// pasted into Productive. A title reaching a shared company system is a worse outcome than the
/// cloud send the gate was written to prevent.
final class SensitivityWiringTests: XCTestCase {
    private let day = "2026-08-28"

    private func engine(_ db: AppDatabase, gate: SensitivityGate = SensitivityGate(terms: []))
        -> SuggestionEngine {
        SuggestionEngine(db: db, clock: FixedClock(Date(timeIntervalSince1970: 5)), gate: gate)
    }

    private func seed(_ db: AppDatabase) throws {
        try db.upsertCompanies([PDCompany(id: "c1", name: "Acme", syncedAt: 0)])
        try db.upsertProjects([PDProject(id: "p1", companyId: "c1", name: "Site", syncedAt: 0)])
    }

    private func session(_ db: AppDatabase, title: String, seconds: Int = 3600, at: Int64 = 2_000) throws {
        var s = Session(kind: "screen", startedAt: at, endedAt: at + Int64(seconds),
                        durationSeconds: seconds, title: title, createdAt: 0)
        s.clientId = "c1"; s.projectId = "p1"; s.confidence = 0.8; s.producedByRung = 2
        try db.insertSession(s)
    }

    // MARK: The note

    func testASensitiveWindowTitleNeverReachesTheNote() throws {
        let db = try AppDatabase.inMemory()
        try seed(db)
        try session(db, title: "Re: Jane's performance review — Gmail")
        try engine(db).generate(day: day, from: 0, to: 900_000)

        let note = try XCTUnwrap(try db.suggestions(day: day).first?.note)
        XCTAssertFalse(note.contains("performance review"))
        XCTAssertFalse(note.contains("Jane"), "a name beside a flagged term is the leak, not the term")
        XCTAssertEqual(note, "Worked on this client's project.")
    }

    /// Dropped, not redacted: "Re: [REDACTED] — Gmail" still says a review happened, with whom,
    /// and when. Fails closed, like the rest of G2.
    func testSafeTitlesSurviveAlongsideDroppedOnes() throws {
        let db = try AppDatabase.inMemory()
        try seed(db)
        try session(db, title: "Donation page — amount selector", at: 2_000)
        try session(db, title: "severance agreement draft.docx", at: 20_000)
        try engine(db).generate(day: day, from: 0, to: 900_000)

        let note = try XCTUnwrap(try db.suggestions(day: day).first?.note)
        XCTAssertTrue(note.contains("amount selector"), "ordinary work is still described")
        XCTAssertFalse(note.contains("severance"))
    }

    /// A proposed task title becomes a real, permanent task in a shared system.
    func testAProposedTaskTitleIsGatedToo() throws {
        let db = try AppDatabase.inMemory()
        try seed(db)
        try session(db, title: "HR complaint — notes")
        try engine(db).generate(day: day, from: 0, to: 900_000)

        let s = try XCTUnwrap(try db.suggestions(day: day).first)
        XCTAssertEqual(s.kind, "new_task")
        XCTAssertEqual(s.proposedTaskTitle, "New task")
    }

    func testPoolNotesAreGated() throws {
        let db = try AppDatabase.inMemory()
        try seed(db)
        try session(db, title: "lawsuit filing", seconds: 400, at: 2_000)
        try session(db, title: "quick CSS tweak", seconds: 400, at: 20_000)
        try engine(db).generate(day: day, from: 0, to: 900_000)

        let note = try XCTUnwrap(try db.suggestions(day: day).first?.note)
        XCTAssertFalse(note.contains("lawsuit"))
        XCTAssertTrue(note.contains("CSS tweak"))
    }

    // MARK: Failing closed

    /// An engine constructed with no configured terms must still block the floor. If the default
    /// were an empty gate, every call site that forgot the argument would silently be ungated —
    /// which is exactly how G2 came to have no callers in the first place.
    func testTheDefaultGateIsNotANoOp() throws {
        let db = try AppDatabase.inMemory()
        try seed(db)
        try session(db, title: "termination letter")
        try SuggestionEngine(db: db, clock: FixedClock(Date(timeIntervalSince1970: 5)))
            .generate(day: day, from: 0, to: 900_000)
        XCTAssertEqual(try db.suggestions(day: day).first?.note, "Worked on this client's project.")
    }

    /// User-configured terms stack on top of the floor.
    func testConfiguredTermsApply() throws {
        let db = try AppDatabase.inMemory()
        try seed(db)
        try session(db, title: "Project Bluebird kickoff")
        var config = Config()
        config.sensitivity.flaggedTerms = ["bluebird"]
        try engine(db, gate: SensitivityGate(config: config))
            .generate(day: day, from: 0, to: 900_000)
        XCTAssertEqual(try db.suggestions(day: day).first?.note, "Worked on this client's project.")
    }

    /// The wiring itself — the defect class this repo keeps hitting is a correct component with no
    /// caller, and a passing unit test for the component does not notice.
    func testTheGateHasAProductionCallSite() throws {
        let src = try String(
            contentsOf: TestSupport.repoRoot()
                .appendingPathComponent("Packages/TidyKit/Sources/TidySurface/AppEnvironment.swift"),
            encoding: .utf8)
        XCTAssertTrue(src.contains("SensitivityGate(config: config)"),
                      "G2 must be constructed from real config in the pipeline, not defaulted")
    }
}
