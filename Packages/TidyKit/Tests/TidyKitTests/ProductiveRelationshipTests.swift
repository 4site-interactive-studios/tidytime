import XCTest
import Foundation
import TidyCore
import TidyStore
@testable import TidyIngest

/// Productive omits relationship **linkage** unless you send `include=`. Without it there is no
/// `data` key at all, so every foreign key landed as `""`: 11,631 tasks belonging to no project,
/// 965 projects to no company, and 160 time entries to no task *and no person* — despite person
/// being the filter that fetched them.
///
/// The parsing was never wrong. We simply never asked. These shapes are copied from live responses
/// captured on 2026-08-28, not invented.
final class ProductiveRelationshipTests: XCTestCase {

    // MARK: The shape that broke it

    /// Verbatim from `GET /tasks?page[size]=1` with no `include`.
    func testLinkageIsAbsentWithoutInclude() throws {
        let json = """
        { "data": [{"id":"219209","type":"tasks",
            "attributes":{"title":"Create Script","task_number":"1"},
            "relationships":{
              "project":{"meta":{"included":false}},
              "assignee":{"meta":{"included":false}}}}]}
        """
        let doc = try JSONDecoder().decode(JSONAPIDocument<TaskAttrs>.self, from: Data(json.utf8))
        let r = doc.data[0]
        XCTAssertNil(r.relationshipId("project"),
                     "a meta-only relationship carries no id — returning nil is correct")
        // And this is what made it invisible: the mapper coerces nil to "".
        XCTAssertEqual(PDMapper.task(r, 0).projectId, "")
    }

    /// Verbatim from `GET /tasks?page[size]=1&include=project,assignee`.
    func testLinkageParsesWithInclude() throws {
        let json = """
        { "data": [{"id":"219209","type":"tasks",
            "attributes":{"title":"Create Script","task_number":"1"},
            "relationships":{
              "project":{"data":{"type":"projects","id":"16332"}},
              "assignee":{"data":{"type":"people","id":"32509"}},
              "task_list":{"meta":{"included":false}}}}],
          "included":[{"type":"projects","id":"16332","attributes":{"name":"P"}}]}
        """
        let doc = try JSONDecoder().decode(JSONAPIDocument<TaskAttrs>.self, from: Data(json.utf8))
        let r = doc.data[0]
        XCTAssertEqual(r.relationshipId("project"), "16332")
        XCTAssertEqual(r.relationshipId("assignee"), "32509")
        XCTAssertNil(r.relationshipId("task_list"), "still meta-only — we did not include it")
        XCTAssertEqual(PDMapper.task(r, 0).projectId, "16332")
    }

    /// The `included[]` sideload array must not break decoding — we ignore it and read linkage only.
    func testIncludedArrayIsHarmless() throws {
        let json = """
        { "data": [{"id":"1","type":"projects","attributes":{"name":"P"},
            "relationships":{"company":{"data":{"type":"companies","id":"36688"}}}}],
          "included":[{"type":"companies","id":"36688","attributes":{"name":"Acme","domain":null}}]}
        """
        let doc = try JSONDecoder().decode(JSONAPIDocument<ProjectAttrs>.self, from: Data(json.utf8))
        XCTAssertEqual(doc.skipped, 0)
        XCTAssertEqual(PDMapper.project(doc.data[0], 0).companyId, "36688")
    }

    // MARK: The request must actually carry `include`

    /// Guards the regression directly: if these params stop being sent, the mirror silently empties
    /// again and nothing else in the suite would notice.
    func testEveryRelationshipEndpointSendsInclude() async throws {
        for (path, expected) in [("tasks", "project,assignee,task_list"),
                                 ("projects", "company"),
                                 ("time_entries", "task,person,service,project")] {
            XCTAssertEqual(LiveProductiveClient.includes[path], expected, path)
        }
        // Endpoints with no relationship we read must NOT pay for a sideload.
        XCTAssertNil(LiveProductiveClient.includes["companies"])
        XCTAssertNil(LiveProductiveClient.includes["people"])
    }

    func testFetchTasksPutsIncludeOnTheWire() async throws {
        let http = FakeHTTPClient([.json(#"{"data":[]}"#)])
        let client = LiveProductiveClient(
            http: http,
            builder: ProductiveRequestBuilder(baseURL: URL(string: "https://api.productive.io/api/v2/")!,
                                              organizationId: "2650", token: "t"),
            sleeper: { _ in })
        _ = try await client.fetchTasks(assigneeId: "32510")

        let url = try XCTUnwrap(http.sentRequests.first?.url.absoluteString)
        XCTAssertTrue(url.contains("include=project,assignee,task_list")
                        || url.contains("include=project%2Cassignee%2Ctask_list"),
                      "tasks must sideload its relationships — got \(url)")
        XCTAssertTrue(url.contains("filter%5Bassignee_id%5D=32510") || url.contains("filter[assignee_id]=32510"),
                      "the existing filter must survive alongside include")
    }

    func testCompaniesDoesNotSendInclude() async throws {
        let http = FakeHTTPClient([.json(#"{"data":[]}"#)])
        let client = LiveProductiveClient(
            http: http,
            builder: ProductiveRequestBuilder(baseURL: URL(string: "https://api.productive.io/api/v2/")!,
                                              organizationId: "2650", token: "t"),
            sleeper: { _ in })
        _ = try await client.fetchCompanies()
        let url = try XCTUnwrap(http.sentRequests.first?.url.absoluteString)
        XCTAssertFalse(url.contains("include="), "no relationship is read from companies")
    }

    // MARK: Time entries — the row that lost both its keys

    func testTimeEntryKeepsTaskAndPersonWithInclude() throws {
        let json = """
        { "data": [{"id":"te1","type":"time_entries",
            "attributes":{"date":"2026-08-28","time":60},
            "relationships":{
              "task":{"data":{"type":"tasks","id":"14791202"}},
              "person":{"data":{"type":"people","id":"32511"}},
              "service":{"data":{"type":"services","id":"11791260"}}}}]}
        """
        let doc = try JSONDecoder().decode(JSONAPIDocument<TimeEntryAttrs>.self, from: Data(json.utf8))
        let e = PDMapper.timeEntry(doc.data[0], 0)
        XCTAssertEqual(e.taskId, "14791202", "gap analysis is keyed on task id — without it, nothing suppresses")
        XCTAssertEqual(e.personId, "32511")
        XCTAssertEqual(e.serviceId, "11791260")
    }
}
