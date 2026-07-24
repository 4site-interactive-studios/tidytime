import XCTest
import Foundation
import TidyCore
import TidyStore
import TidyIngest

final class ProductiveStoreTests: XCTestCase {
    func testV1ProductiveMigration() throws {
        let db = try AppDatabase.inMemory()
        XCTAssertTrue(try db.appliedMigrations().contains("v1-productive"))
        let counts = try db.tableRowCounts()
        for t in ["pd_companies", "pd_projects", "pd_tasks", "pd_time_entries", "pd_people"] {
            XCTAssertNotNil(counts[t])
        }
    }

    func testUpsertOverwrites() throws {
        let db = try AppDatabase.inMemory()
        try db.upsertCompanies([PDCompany(id: "c1", name: "Old", syncedAt: 1)])
        try db.upsertCompanies([PDCompany(id: "c1", name: "New", syncedAt: 2)])
        let companies = try db.companies()
        XCTAssertEqual(companies.count, 1)
        XCTAssertEqual(companies[0].name, "New")
    }

    func testResolveSelfByEmail() throws {
        let db = try AppDatabase.inMemory()
        try db.upsertPeople([
            PDPerson(id: "me", name: "Bryan", email: "Bryan@4Site.org", syncedAt: 1),
            PDPerson(id: "x", name: "X", email: "x@y.org", syncedAt: 1),
        ])
        let id = try db.resolveSelf(email: "bryan@4site.org")  // case-insensitive
        XCTAssertEqual(id, "me")
        XCTAssertEqual(try db.selfPerson()?.id, "me")
    }

    func testTimeEntriesByDate() throws {
        let db = try AppDatabase.inMemory()
        try db.upsertTimeEntries([
            PDTimeEntry(id: "e1", personId: "me", date: "2026-07-22", timeMinutes: 60, syncedAt: 1),
            PDTimeEntry(id: "e2", personId: "me", date: "2026-07-22", timeMinutes: 30, syncedAt: 1),
            PDTimeEntry(id: "e3", personId: "me", date: "2026-07-21", timeMinutes: 15, syncedAt: 1),
        ])
        let today = try db.timeEntries(personId: "me", date: "2026-07-22")
        XCTAssertEqual(today.count, 2)
        XCTAssertEqual(today.reduce(0) { $0 + $1.timeMinutes }, 90)
    }
}

final class ProductiveSyncTests: XCTestCase {
    func testSyncUpsertsAndResolvesSelf() async throws {
        let db = try AppDatabase.inMemory()
        let client = FakeProductiveClient(
            companies: [PDCompany(id: "c1", name: "Acme", syncedAt: 0)],
            projects: [PDProject(id: "p1", companyId: "c1", name: "Site", projectTypeId: 2, syncedAt: 0)],
            tasks: [
                PDTask(id: "t1", projectId: "p1", title: "Mine", assigneeId: "me", syncedAt: 0),
                PDTask(id: "t2", projectId: "p1", title: "Not mine", assigneeId: "other", syncedAt: 0),
            ],
            timeEntries: [PDTimeEntry(id: "e1", personId: "me", date: "2026-07-22", timeMinutes: 60, syncedAt: 0)],
            people: [PDPerson(id: "me", name: "Bryan", email: "bryan@4site.org", syncedAt: 0)])

        let sync = ProductiveSync(client: client, db: db,
                                  clock: FixedClock(Date(timeIntervalSince1970: 5000)),
                                  selfEmail: "bryan@4site.org")
        let summary = try await sync.run(after: "2026-07-01", before: "2026-07-31")

        XCTAssertEqual(summary.selfPersonId, "me")
        XCTAssertEqual(summary.companies, 1)
        XCTAssertEqual(summary.tasks, 1)          // filtered to assignee = me
        XCTAssertEqual(summary.timeEntries, 1)
        XCTAssertEqual(try db.tasks().count, 1)
        XCTAssertEqual(try db.selfPerson()?.id, "me")
        // cursor recorded
        XCTAssertEqual(try db.syncState("productive")?.cursor, "2026-07-31")
        XCTAssertEqual(try db.syncState("productive")?.lastSuccessAt, 5000)
    }
}

final class DeepLinkTests: XCTestCase {
    func testBuildsDeepLink() {
        let url = ProductiveDeepLink.url(
            taskId: "t1", organizationId: "42",
            pattern: "https://app.productive.io/{org}/task/{task_id}")
        XCTAssertEqual(url, "https://app.productive.io/42/task/t1")
    }
}
