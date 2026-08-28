import XCTest
import Foundation
import TidyCore
import TidyStore
import TidySuggest

/// Stage 6: a card the user can act on.
///
/// Before this, the best cards — attributed all the way down to a task — were headed by a bare
/// numeric id, there was no way to open the task, tossed cards kept rendering with live buttons,
/// and the empty case (which was every case) showed a heading over a blank box.
final class RecapCardTests: XCTestCase {
    private let day = "2026-08-28"

    private func seed(_ db: AppDatabase) throws {
        try db.upsertCompanies([PDCompany(id: "c1", name: "Acme Foundation", syncedAt: 0)])
        try db.upsertProjects([PDProject(id: "p1", companyId: "c1", name: "Donation Pages", syncedAt: 0)])
        try db.upsertTasks([PDTask(id: "18609405", projectId: "p1",
                                   title: "Fix the amount selector", taskNumber: 29, syncedAt: 0)])
    }

    private func suggestion(_ db: AppDatabase, status: String = "pending",
                            task: String? = "18609405") throws {
        _ = try db.insertSuggestion(Suggestion(
            day: day, kind: "session", clientId: "c1", projectId: "p1", taskId: task,
            minutes: 60, rawSeconds: 3600, confidence: 0.9, producedByRung: 1,
            status: status, createdAt: 0, updatedAt: 0))
    }

    // MARK: Names, not ids

    func testAssemblerResolvesNamesForTheCard() throws {
        let db = try AppDatabase.inMemory()
        try seed(db); try suggestion(db)

        let recap = try RecapAssembler(db: db, clock: FixedClock(Date(timeIntervalSince1970: 5)))
            .assemble(day: day, from: 0, to: 100_000)

        XCTAssertEqual(recap.names["18609405"], "Fix the amount selector",
                       "a card headed '18609405' tells the user nothing")
        XCTAssertEqual(recap.names["p1"], "Donation Pages")
        XCTAssertEqual(recap.names["c1"], "Acme Foundation")
    }

    /// A task we have no name for must not break the card — it falls back to the id.
    func testMissingNamesAreTolerated() throws {
        let db = try AppDatabase.inMemory()
        try suggestion(db, task: "99999")
        let recap = try RecapAssembler(db: db, clock: FixedClock(Date(timeIntervalSince1970: 5)))
            .assemble(day: day, from: 0, to: 100_000)
        XCTAssertNil(recap.names["99999"])
        XCTAssertEqual(recap.suggestions.count, 1, "the card still renders")
    }

    // MARK: Decided cards leave the stack

    /// `MenuBarPopover` already filtered to pending; the recap did not, so a tossed card kept
    /// rendering with live buttons and the two counts disagreed.
    func testDecidedSuggestionsAreNotRendered() throws {
        let db = try AppDatabase.inMemory()
        try seed(db)
        try suggestion(db, status: "pending")
        try suggestion(db, status: "tossed", task: "18609405")
        try suggestion(db, status: "logged", task: "18609405")

        let recap = try RecapAssembler(db: db, clock: FixedClock(Date(timeIntervalSince1970: 5)))
            .assemble(day: day, from: 0, to: 100_000)
        XCTAssertEqual(recap.suggestions.count, 1)
        XCTAssertEqual(recap.suggestions.first?.status, "pending")
    }

    // MARK: The deep link

    func testEngineStoresADeepLinkWhenConfigCanFillIt() throws {
        let db = try AppDatabase.inMemory()
        try seed(db)
        var s = Session(kind: "screen", startedAt: 100, endedAt: 3_700, durationSeconds: 3600,
                        title: "work", createdAt: 0)
        s.clientId = "c1"; s.projectId = "p1"; s.taskId = "18609405"; s.confidence = 0.9; s.producedByRung = 1
        _ = try db.insertSession(s)

        var org = Config.Organization()
        org.productiveOrganizationId = "2650"
        org.productiveOrgSlug = "2650-4site-interactive-studios-inc"

        try SuggestionEngine(db: db, clock: FixedClock(Date(timeIntervalSince1970: 5)),
                             organization: org,
                             deepLinkPattern: Config().productive.taskDeepLinkPattern)
            .generate(day: day, from: 0, to: 100_000)

        XCTAssertEqual(try db.suggestions(day: day).first?.deepLink,
                       "https://app.productive.io/2650-4site-interactive-studios-inc/tasks/task/18609405",
                       "matches the URL confirmed live under open item A2")
    }

    /// No slug configured → nil, so the view hides the button instead of opening a 404.
    func testNoSlugMeansNoLinkRatherThanABrokenOne() throws {
        let db = try AppDatabase.inMemory()
        try seed(db)
        var s = Session(kind: "screen", startedAt: 100, endedAt: 3_700, durationSeconds: 3600,
                        title: "work", createdAt: 0)
        s.clientId = "c1"; s.projectId = "p1"; s.taskId = "18609405"; s.confidence = 0.9; s.producedByRung = 1
        _ = try db.insertSession(s)

        var org = Config.Organization()
        org.productiveOrganizationId = "2650"   // slug deliberately empty

        try SuggestionEngine(db: db, clock: FixedClock(Date(timeIntervalSince1970: 5)),
                             organization: org,
                             deepLinkPattern: Config().productive.taskDeepLinkPattern)
            .generate(day: day, from: 0, to: 100_000)

        XCTAssertNil(try db.suggestions(day: day).first?.deepLink)
    }

    func testNoConfigAtAllStillGeneratesSuggestions() throws {
        let db = try AppDatabase.inMemory()
        try seed(db)
        var s = Session(kind: "screen", startedAt: 100, endedAt: 3_700, durationSeconds: 3600,
                        title: "work", createdAt: 0)
        s.clientId = "c1"; s.projectId = "p1"; s.taskId = "18609405"; s.confidence = 0.9; s.producedByRung = 1
        _ = try db.insertSession(s)

        try SuggestionEngine(db: db, clock: FixedClock(Date(timeIntervalSince1970: 5)))
            .generate(day: day, from: 0, to: 100_000)
        XCTAssertEqual(try db.suggestions(day: day).count, 1, "the link is optional, the card is not")
    }
}
