import XCTest
import Foundation
import TidyCore
import TidyStore
import TidyCapture
import TidyUnderstand

/// Tests that within-app switches become distinct sessions AND each attributes to the right
/// client/project — the finer context key + page-text-into-classification wiring.

final class GroupingKeyTests: XCTestCase {
    func testGroupingSplitsByTitleButCoarseKeyStaysHostBundle() {
        // native app, two titles → two grouping keys, same coarse key
        XCTAssertEqual(ContextKey.derive(isBrowser: false, url: nil, appBundleId: "com.claude"), "app:com.claude")
        XCTAssertEqual(ContextKey.grouping(isBrowser: false, url: nil, appBundleId: "com.claude", windowTitle: "TidyTime build"),
                       "app:com.claude#tidytime build")
        XCTAssertNotEqual(
            ContextKey.grouping(isBrowser: false, url: nil, appBundleId: "com.claude", windowTitle: "chat 1"),
            ContextKey.grouping(isBrowser: false, url: nil, appBundleId: "com.claude", windowTitle: "cowork"))
    }
    func testUnreadBadgeStrippedSoSessionDoesntFragment() {
        XCTAssertEqual(
            ContextKey.grouping(isBrowser: true, url: "https://claude.ai/x", appBundleId: "c", windowTitle: "(3) TidyTime - Claude"),
            ContextKey.grouping(isBrowser: true, url: "https://claude.ai/x", appBundleId: "c", windowTitle: "(7) TidyTime - Claude"))
    }
    func testEmptyTitleFallsBackToCoarse() {
        XCTAssertEqual(ContextKey.grouping(isBrowser: false, url: nil, appBundleId: "com.a", windowTitle: nil), "app:com.a")
    }
}

final class WithinAppSessionSplitTests: XCTestCase {
    func testTwoTitlesInOneAppBecomeTwoSessions() throws {
        let db = try AppDatabase.inMemory()
        let claude = "com.anthropic.claude"
        // same app, two titles, each > 60s so both survive the min-session floor
        try db.insertSample(ActivitySample(startedAt: 0, endedAt: 200, appBundleId: claude, appName: "Claude", windowTitle: "acme donation page", source: "switch", createdAt: 0))
        try db.insertSample(ActivitySample(startedAt: 200, endedAt: 400, appBundleId: claude, appName: "Claude", windowTitle: "beta audit prep", source: "switch", createdAt: 0))
        let job = SessionBuildJob(sessionizer: Sessionizer(detourTolerance: 120, minSessionSeconds: 60),
                                  clock: FixedClock(Date(timeIntervalSince1970: 5)))
        let written = try job.run(db, from: 0, to: 100_000, now: 400)
        XCTAssertEqual(written, 2)                       // split by title, not merged into one "Claude"
        let sessions = try db.sessions(from: 0, to: 100_000)
        XCTAssertEqual(Set(sessions.map(\.contextKey)), ["app:com.anthropic.claude"])  // coarse key shared
        XCTAssertEqual(Set(sessions.compactMap(\.title)), ["acme donation page", "beta audit prep"])
    }
}

final class PageTextAttributionTests: XCTestCase {
    private func seedCatalog(_ db: AppDatabase) throws {
        try db.upsertCompanies([
            PDCompany(id: "acme", name: "Acme Nonprofit", syncedAt: 1),
            PDCompany(id: "beta", name: "Beta Foundation", syncedAt: 1),
        ])
        try db.upsertProjects([
            PDProject(id: "p1", companyId: "acme", name: "Donation Page", projectTypeId: 2, syncedAt: 1),
            PDProject(id: "p2", companyId: "beta", name: "Compliance Audit", projectTypeId: 2, syncedAt: 1),
        ])
    }

    /// Two same-app sessions with project-naming titles attribute to two different clients.
    func testWithinAppSessionsAttributeToDifferentClients() throws {
        let db = try AppDatabase.inMemory()
        try seedCatalog(db)
        try db.insertSession(Session(kind: "screen", startedAt: 0, endedAt: 200, durationSeconds: 200,
                                     title: "Acme donation page work", contextKey: "app:com.anthropic.claude", createdAt: 0))
        try db.insertSession(Session(kind: "screen", startedAt: 200, endedAt: 400, durationSeconds: 200,
                                     title: "Beta compliance audit", contextKey: "app:com.anthropic.claude", createdAt: 0))
        _ = try DayClassifier().run(db, from: 0, to: 100_000, now: 5)
        let sessions = try db.sessions(from: 0, to: 100_000)
        XCTAssertEqual(sessions.first { $0.title == "Acme donation page work" }?.clientId, "acme")
        XCTAssertEqual(sessions.first { $0.title == "Beta compliance audit" }?.clientId, "beta")
    }

    /// A session with a generic title is attributed via captured PAGE TEXT.
    func testPageTextDrivesAttribution() throws {
        let db = try AppDatabase.inMemory()
        try seedCatalog(db)
        // sample + page snapshot naming Beta Foundation, within the session window
        let sampleId = try db.insertSample(ActivitySample(startedAt: 10, endedAt: 100, appBundleId: "com.google.Chrome",
                                                          appName: "Chrome", windowTitle: "Untitled", isBrowser: true,
                                                          url: "https://tool.example/x", source: "switch", createdAt: 0))
        try db.insertPageSnapshot(PageSnapshot(sampleId: sampleId, capturedAt: 20, url: "https://tool.example/x",
                                               contentHash: "h", text: "notes about the Beta Foundation compliance audit deadline", textBytes: 60))
        try db.insertSession(Session(kind: "screen", startedAt: 0, endedAt: 200, durationSeconds: 200,
                                     title: "Untitled", contextKey: "web:tool.example", createdAt: 0))
        _ = try DayClassifier().run(db, from: 0, to: 100_000, now: 5)
        XCTAssertEqual(try db.sessions(from: 0, to: 100_000).first?.clientId, "beta")  // from page text, not title
    }
}
