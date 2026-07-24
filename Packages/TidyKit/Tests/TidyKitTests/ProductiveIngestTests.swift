import XCTest
import Foundation
import TidyCore
import TidyStore
@testable import TidyIngest

private enum Fixtures {
    static let companies = """
    { "data": [
      {"id":"c1","type":"companies","attributes":{"name":"Acme Nonprofit","company_type_id":2,"domain":"acme.org","archived_at":null}},
      {"id":"c2","type":"companies","attributes":{"name":"4Site Internal","company_type_id":1,"domain":null,"archived_at":"2025-01-01"}}
    ]}
    """
    static let projects = """
    { "data": [
      {"id":"p1","type":"projects","attributes":{"name":"Acme Website","project_type_id":2,"number":"P-1","archived_at":null},
       "relationships":{"company":{"data":{"type":"companies","id":"c1"}}}},
      {"id":"p2","type":"projects","attributes":{"name":"Internal Ops","project_type_id":1,"number":null,"archived_at":null},
       "relationships":{"company":{"data":{"type":"companies","id":"c2"}}}}
    ]}
    """
    static let tasks = """
    { "data": [
      {"id":"t1","type":"tasks","attributes":{"title":"Build donation page","description":"EN page","task_number":101,"status":"open","closed_at":null,"due_date":"2026-08-01"},
       "relationships":{"project":{"data":{"type":"projects","id":"p1"}},"assignee":{"data":{"type":"people","id":"me"}},"task_list":{"data":{"type":"task_lists","id":"tl1"}}}}
    ]}
    """
    static let entries = """
    { "data": [
      {"id":"te1","type":"time_entries","attributes":{"date":"2026-07-22","time":60,"billable_time":60,"note":"donation page work"},
       "relationships":{"person":{"data":{"type":"people","id":"me"}},"task":{"data":{"type":"tasks","id":"t1"}}}}
    ]}
    """
    static let people = """
    { "data": [
      {"id":"me","type":"people","attributes":{"first_name":"Bryan","last_name":"Casler","email":"bryan@4site.org","name":null}},
      {"id":"other","type":"people","attributes":{"name":"Someone Else","email":"else@x.org"}}
    ]}
    """
}

private func makeBuilder() -> ProductiveRequestBuilder {
    ProductiveRequestBuilder(baseURL: URL(string: "https://api.productive.io/api/v2/")!,
                             organizationId: "42", token: "secret-token")
}
private func makeClient(_ http: HTTPClient) -> LiveProductiveClient {
    LiveProductiveClient(http: http, builder: makeBuilder(),
                         clock: FixedClock(Date(timeIntervalSince1970: 1000)),
                         sleeper: { _ in })
}

final class ProductiveParseTests: XCTestCase {
    func testParsesCompanies() async throws {
        let http = FakeHTTPClient([.json(Fixtures.companies)])
        let companies = try await makeClient(http).fetchCompanies()
        XCTAssertEqual(companies.count, 2)
        XCTAssertEqual(companies[0].id, "c1")
        XCTAssertEqual(companies[0].companyType, "2")
        XCTAssertFalse(companies[0].archived)
        XCTAssertTrue(companies[1].archived)  // archived_at present
        XCTAssertEqual(companies[0].syncedAt, 1000)
        // Request shape: GET, correct path + auth headers + pagination query.
        let req = http.sentRequests[0]
        XCTAssertEqual(req.method, "GET")
        XCTAssertTrue(req.url.absoluteString.contains("/api/v2/companies"))
        XCTAssertTrue(req.url.absoluteString.contains("page%5Bnumber%5D=1"))
        XCTAssertEqual(req.headers["X-Auth-Token"], "secret-token")
        XCTAssertEqual(req.headers["X-Organization-Id"], "42")
    }

    func testParsesProjectsWithCompanyRelationship() async throws {
        let projects = try await makeClient(FakeHTTPClient([.json(Fixtures.projects)])).fetchProjects()
        XCTAssertEqual(projects.count, 2)
        XCTAssertEqual(projects[0].companyId, "c1")
        XCTAssertEqual(projects[0].projectTypeId, 2)
        XCTAssertTrue(projects[0].isClientWork)
        XCTAssertFalse(projects[1].isClientWork)  // internal
    }

    func testParsesTasksAndEntries() async throws {
        let tasks = try await makeClient(FakeHTTPClient([.json(Fixtures.tasks)])).fetchTasks(assigneeId: nil)
        XCTAssertEqual(tasks[0].projectId, "p1")
        XCTAssertEqual(tasks[0].assigneeId, "me")
        XCTAssertEqual(tasks[0].taskListId, "tl1")
        XCTAssertEqual(tasks[0].taskNumber, 101)
        XCTAssertFalse(tasks[0].closed)

        let entries = try await makeClient(FakeHTTPClient([.json(Fixtures.entries)]))
            .fetchTimeEntries(personId: "me", after: "2026-07-01", before: "2026-07-31")
        XCTAssertEqual(entries[0].timeMinutes, 60)
        XCTAssertEqual(entries[0].billableMinutes, 60)
        XCTAssertEqual(entries[0].taskId, "t1")
        XCTAssertEqual(entries[0].personId, "me")
    }

    func testParsesPeopleNameFallback() async throws {
        let people = try await makeClient(FakeHTTPClient([.json(Fixtures.people)])).fetchPeople()
        XCTAssertEqual(people.first(where: { $0.id == "me" })?.name, "Bryan Casler")  // first+last
        XCTAssertEqual(people.first(where: { $0.id == "other" })?.name, "Someone Else") // name field
    }
}

final class ProductivePagingAndRetryTests: XCTestCase {
    func testFollowsPagination() async throws {
        let page1 = """
        { "data": [ {"id":"c1","type":"companies","attributes":{"name":"A"}} ],
          "links": { "next": "https://api.productive.io/api/v2/companies?page[number]=2" } }
        """
        let page2 = """
        { "data": [ {"id":"c2","type":"companies","attributes":{"name":"B"}} ], "links": { "next": null } }
        """
        let http = FakeHTTPClient([.json(page1), .json(page2)])
        let companies = try await makeClient(http).fetchCompanies()
        XCTAssertEqual(companies.map(\.id), ["c1", "c2"])
        XCTAssertEqual(http.sentRequests.count, 2)
        XCTAssertTrue(http.sentRequests[1].url.absoluteString.contains("page%5Bnumber%5D=2"))
    }

    func testRetriesOn429() async throws {
        let http = FakeHTTPClient([
            .json("{}", status: 429, headers: ["Retry-After": "0"]),
            .json(Fixtures.companies),
        ])
        let companies = try await makeClient(http).fetchCompanies()
        XCTAssertEqual(companies.count, 2)
        XCTAssertEqual(http.sentRequests.count, 2)  // one retry
    }

    func testThrowsOnServerError() async throws {
        let http = FakeHTTPClient([.json("boom", status: 500)])
        do {
            _ = try await makeClient(http).fetchCompanies()
            XCTFail("expected error")
        } catch let IngestError.http(status, _) {
            XCTAssertEqual(status, 500)
        }
    }
}

final class ProductiveGuardrailTests: XCTestCase {
    /// Guardrail G1: the request builder refuses to construct any non-GET request.
    func testBuilderRefusesNonGET() {
        let builder = makeBuilder()
        for method in ["POST", "PATCH", "PUT", "DELETE"] {
            XCTAssertThrowsError(try builder.build(method: method, path: "time_entries", query: [])) { error in
                guard case IngestError.readOnlyViolation = error else {
                    return XCTFail("expected readOnlyViolation for \(method), got \(error)")
                }
            }
        }
    }

    func testBuilderAllowsGET() throws {
        let req = try makeBuilder().build(method: "GET", path: "companies", query: [])
        XCTAssertEqual(req.method, "GET")
    }
}

final class BackoffTests: XCTestCase {
    func testGrowsExponentiallyAndCaps() {
        let b = Backoff(base: 1, cap: 10)
        XCTAssertEqual(b.delay(attempt: 0), 1)
        XCTAssertEqual(b.delay(attempt: 1), 2)
        XCTAssertEqual(b.delay(attempt: 2), 4)
        XCTAssertEqual(b.delay(attempt: 10), 10)  // capped
    }
    func testHonorsRetryAfter() {
        let b = Backoff(base: 1, cap: 100)
        XCTAssertEqual(b.delay(attempt: 5, retryAfter: 3), 3)
    }
}
