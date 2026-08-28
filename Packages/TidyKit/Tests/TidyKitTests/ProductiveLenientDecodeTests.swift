import XCTest
import Foundation
import TidyCore
import TidyStore
@testable import TidyIngest

/// The live API disagrees with its own documentation about scalar types, and our fixtures were
/// written from the documentation — so model, fixture and doc all agreed with each other while all
/// three disagreed with Productive. 279 passing tests said nothing.
///
/// The first live sync threw on `data[0].attributes.task_number` ("Expected to decode Int but found
/// a string instead"), which aborted `ProductiveSync.run()` before it reached time entries. That is
/// why `pd_tasks` AND `pd_time_entries` were both zero while companies, projects and people synced.
///
/// These tests use the **live** shapes, not the documented ones.
final class ProductiveLenientDecodeTests: XCTestCase {

    // MARK: The exact payload that broke production

    /// `task_number` as a string and `status` as an integer — both inverted from the doc.
    /// `status` is the one hiding behind the first: Swift decodes in property order, so the throw
    /// on `task_number` meant it was never reached. Fixing only the first would have hit this next.
    func testLiveTaskShapeDecodes() throws {
        let json = """
        { "data": [
          {"id":"77310","type":"tasks","attributes":{
             "title":"Fix ENgrid donation-amount selector","description":"d",
             "task_number":"412","status":1,"closed_at":null,"due_date":"2026-07-25"},
           "relationships":{"project":{"data":{"type":"project","id":"8801"}}}}
        ]}
        """
        let doc = try JSONDecoder().decode(JSONAPIDocument<TaskAttrs>.self, from: Data(json.utf8))
        XCTAssertEqual(doc.data.count, 1)
        XCTAssertEqual(doc.skipped, 0)
        XCTAssertEqual(doc.data[0].attributes.taskNumber, 412, "a string task_number must parse to Int")
        XCTAssertEqual(doc.data[0].attributes.status, "1", "an integer status must survive as a string")
    }

    /// The documented shape must keep working too — we do not know which one a given tenant or a
    /// future API version returns, and the whole point is to stop caring.
    func testDocumentedTaskShapeStillDecodes() throws {
        let json = """
        { "data": [
          {"id":"1","type":"tasks","attributes":{"title":"t","task_number":412,"status":"open"}}
        ]}
        """
        let doc = try JSONDecoder().decode(JSONAPIDocument<TaskAttrs>.self, from: Data(json.utf8))
        XCTAssertEqual(doc.data[0].attributes.taskNumber, 412)
        XCTAssertEqual(doc.data[0].attributes.status, "open")
    }

    // MARK: Degrade the field, never the source

    /// An unparseable value costs that one field and nothing else. This is the same principle as
    /// the Slack per-conversation skip.
    func testGarbageScalarDegradesToNilWithoutThrowing() throws {
        let json = """
        { "data": [
          {"id":"1","type":"tasks","attributes":{"title":"kept","task_number":"not-a-number","status":{"a":1}}}
        ]}
        """
        let doc = try JSONDecoder().decode(JSONAPIDocument<TaskAttrs>.self, from: Data(json.utf8))
        XCTAssertEqual(doc.data.count, 1, "the row survives")
        XCTAssertEqual(doc.data[0].attributes.title, "kept")
        XCTAssertNil(doc.data[0].attributes.taskNumber)
        XCTAssertNil(doc.data[0].attributes.status)
    }

    /// A non-integral float must NOT be silently truncated — `4.5` is not `4`.
    func testNonIntegralNumberIsRejectedRatherThanTruncated() throws {
        let json = #"{ "data": [{"id":"1","type":"tasks","attributes":{"title":"t","task_number":4.5}}]}"#
        let doc = try JSONDecoder().decode(JSONAPIDocument<TaskAttrs>.self, from: Data(json.utf8))
        XCTAssertNil(doc.data[0].attributes.taskNumber)
    }

    /// One malformed resource must cost one row, not the page — and must be counted, not hidden.
    func testOneBadResourceDoesNotKillThePage() throws {
        let json = """
        { "data": [
          {"id":"1","type":"tasks","attributes":{"title":"good one"}},
          {"id":"2","type":"tasks","attributes":"this is not an object"},
          {"id":"3","type":"tasks","attributes":{"title":"good two"}}
        ]}
        """
        let doc = try JSONDecoder().decode(JSONAPIDocument<TaskAttrs>.self, from: Data(json.utf8))
        XCTAssertEqual(doc.data.map(\.id), ["1", "3"])
        XCTAssertEqual(doc.skipped, 1, "skips must be counted so they can be logged, not swallowed")
    }

    /// A time entry with no usable duration is dropped as a row rather than aborting the source.
    func testTimeEntryWithUnusableDurationIsSkippedNotFatal() throws {
        let json = """
        { "data": [
          {"id":"te1","type":"time_entries","attributes":{"date":"2026-07-22","time":"90","billable_time":"60"}},
          {"id":"te2","type":"time_entries","attributes":{"date":"2026-07-22","time":null}},
          {"id":"te3","type":"time_entries","attributes":{"date":"2026-07-23","time":45}}
        ]}
        """
        let doc = try JSONDecoder().decode(JSONAPIDocument<TimeEntryAttrs>.self, from: Data(json.utf8))
        XCTAssertEqual(doc.data.map(\.id), ["te1", "te3"])
        XCTAssertEqual(doc.data[0].attributes.time, 90, "a string duration must parse")
        XCTAssertEqual(doc.data[0].attributes.billableTime, 60)
        XCTAssertEqual(doc.skipped, 1)
    }

    // MARK: Presence flags must NOT be coerced

    /// The regression this nearly shipped with. `closed` is derived as `closedAt != nil`, and
    /// `lenientString` turns a JSON `false` into the non-nil string `"false"` — which would mark
    /// EVERY task closed. Presence flags use `lenientTimestamp`, which accepts a real string or
    /// nothing. Verified against the real decoder, not reasoned about.
    func testFalseOrZeroDoesNotCountAsAClosedTimestamp() throws {
        for raw in ["false", "0", "null"] {
            let json = """
            { "data": [{"id":"1","type":"tasks","attributes":{"title":"open task","closed_at":\(raw)}}]}
            """
            let doc = try JSONDecoder().decode(JSONAPIDocument<TaskAttrs>.self, from: Data(json.utf8))
            XCTAssertNil(doc.data[0].attributes.closedAt,
                         "closed_at: \(raw) must not read as a closed task")
        }
        // A real timestamp still registers.
        let closed = """
        { "data": [{"id":"1","type":"tasks","attributes":{"title":"t","closed_at":"2026-07-25T10:00:00Z"}}]}
        """
        let doc = try JSONDecoder().decode(JSONAPIDocument<TaskAttrs>.self, from: Data(closed.utf8))
        XCTAssertEqual(doc.data[0].attributes.closedAt, "2026-07-25T10:00:00Z")
    }

    /// Same hazard on the company/project side — `archived` is `archivedAt != nil`.
    func testFalseDoesNotCountAsArchived() throws {
        let json = """
        { "data": [{"id":"c1","type":"companies","attributes":{"name":"Acme","archived_at":false}}]}
        """
        let doc = try JSONDecoder().decode(JSONAPIDocument<CompanyAttrs>.self, from: Data(json.utf8))
        XCTAssertNil(doc.data[0].attributes.archivedAt, "a live company must not read as archived")
    }

    /// An empty-string timestamp is absence, not a date.
    func testBlankTimestampIsAbsence() throws {
        let json = """
        { "data": [{"id":"1","type":"tasks","attributes":{"title":"t","closed_at":"   "}}]}
        """
        let doc = try JSONDecoder().decode(JSONAPIDocument<TaskAttrs>.self, from: Data(json.utf8))
        XCTAssertNil(doc.data[0].attributes.closedAt)
    }

    // MARK: The other fields of the same risk class

    /// `company_type_id`, `project_type_id` and `number` have never been checked against live data.
    /// They accept either representation on that basis.
    func testUncheckedRiskClassFieldsAcceptEitherRepresentation() throws {
        let companies = """
        { "data": [
          {"id":"c1","type":"companies","attributes":{"name":"A","company_type_id":"2","domain":"a.org"}},
          {"id":"c2","type":"companies","attributes":{"name":"B","company_type_id":2}}
        ]}
        """
        let cdoc = try JSONDecoder().decode(JSONAPIDocument<CompanyAttrs>.self, from: Data(companies.utf8))
        XCTAssertEqual(cdoc.data.compactMap(\.attributes.companyTypeId), [2, 2])

        let projects = """
        { "data": [
          {"id":"p1","type":"projects","attributes":{"name":"A","project_type_id":"1","number":7}},
          {"id":"p2","type":"projects","attributes":{"name":"B","project_type_id":1,"number":"7"}}
        ]}
        """
        let pdoc = try JSONDecoder().decode(JSONAPIDocument<ProjectAttrs>.self, from: Data(projects.utf8))
        XCTAssertEqual(pdoc.data.compactMap(\.attributes.projectTypeId), [1, 1])
        XCTAssertEqual(pdoc.data.compactMap(\.attributes.number), ["7", "7"],
                       "a numeric project number must render without a decimal point")
    }

    /// Regression guard for the pagination hazard the element-skip introduced: a page whose rows
    /// all fail still means "there is more after this". Judging fullness on kept rows alone would
    /// silently truncate the walk at the first bad page.
    func testPageFullnessCountsSkippedResources() throws {
        let json = """
        { "data": [
          {"id":"1","type":"tasks","attributes":"bad"},
          {"id":"2","type":"tasks","attributes":"bad"}
        ]}
        """
        let doc = try JSONDecoder().decode(JSONAPIDocument<TaskAttrs>.self, from: Data(json.utf8))
        XCTAssertTrue(doc.data.isEmpty)
        XCTAssertEqual(doc.skipped, 2, "received == 2, so the caller must not treat this as the last page")
    }
}
