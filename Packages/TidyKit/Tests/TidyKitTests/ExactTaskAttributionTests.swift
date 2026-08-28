import XCTest
import Foundation
import TidyCore
import TidyStore
import TidyUnderstand

/// When a Productive task page is open, the task id is in the address bar. That is evidence, not
/// inference — no vocabulary, no tokens, no scoring — so it outranks signal matching.
///
/// It matters disproportionately here: `sessions.task_id` was 0 across 3,900 sessions, and the
/// captured hosts are overwhelmingly *tools* (Slack, Productive, EN, BugHerd) rather than
/// client-branded domains, so the documented `url_host -> client` route resolves almost nothing.
/// 990 captured samples sit on a Productive task URL.
final class ExactTaskAttributionTests: XCTestCase {

    // MARK: URL parsing — both live shapes

    /// Captured samples contain BOTH forms. Missing either loses real attributions.
    func testMatchesBothLiveURLShapes() {
        XCTAssertEqual(
            Classifier.productiveTaskId(in: "https://app.productive.io/2650-acme/tasks/task/18609405"),
            "18609405")
        XCTAssertEqual(
            Classifier.productiveTaskId(in: "https://app.productive.io/2650-acme/task/18833587"),
            "18833587")
    }

    func testIgnoresQueryAndFragment() {
        XCTAssertEqual(
            Classifier.productiveTaskId(in: "https://app.productive.io/2650-acme/task/18833587?taskActivityId=289971771"),
            "18833587")
        XCTAssertEqual(
            Classifier.productiveTaskId(in: "https://app.productive.io/2650-acme/tasks/task/123#comment-9"),
            "123")
    }

    /// The trap: a filtered task LIST carries a base64 blob full of digits. Scanning the raw URL for
    /// a number would mint a confident, wrong task id. This exact URL appears in the live data.
    func testFilteredTaskListIsNotATask() {
        let listURL = "https://app.productive.io/2650-acme/tasks?filter=eyJpZCI6IjMxOTIiLCJzb3J0QnkiOiJkdWUtZGF0ZSJ9"
        XCTAssertNil(Classifier.productiveTaskId(in: listURL),
                     "a filter blob is not a task id")
    }

    func testRejectsNonProductiveAndMalformed() {
        for url in ["https://youtube.com/watch?v=task/123",
                    "https://app.productive.io/2650-acme/tasks",
                    "https://app.productive.io/2650-acme/task/",
                    "https://app.productive.io/2650-acme/task/not-a-number",
                    "https://app.slack.com/client/T1/C2"] {
            XCTAssertNil(Classifier.productiveTaskId(in: url), url)
        }
    }

    // MARK: Attribution

    private func classifier() -> Classifier {
        Classifier(
            companies: [PDCompany(id: "c1", name: "Acme Foundation", syncedAt: 0)],
            projects: [PDProject(id: "p1", companyId: "c1", name: "Donation Pages", syncedAt: 0)],
            tasks: [PDTask(id: "18609405", projectId: "p1", title: "Fix the amount selector",
                           taskNumber: 29, syncedAt: 0)],
            signals: [])
    }

    private func session(_ title: String = "Chrome") -> Session {
        Session(kind: "screen", startedAt: 100, endedAt: 200, durationSeconds: 100,
                title: title, contextKey: "web:app.productive.io", createdAt: 0)
    }

    /// The headline: an open task page attributes client, project AND task at rung 1.
    func testOpenTaskPageAttributesExactly() throws {
        let c = try XCTUnwrap(classifier().classify(
            session(), urls: ["https://app.productive.io/2650-acme/tasks/task/18609405"]))
        XCTAssertEqual(c.taskId, "18609405", "the only path that sets task_id")
        XCTAssertEqual(c.projectId, "p1")
        XCTAssertEqual(c.clientId, "c1")
        XCTAssertEqual(c.rung, 1)
        XCTAssertGreaterThan(c.confidence, 0.9)
        XCTAssertTrue(c.rationale.contains("Productive"), "the user should see WHY")
    }

    /// Exact evidence must beat a signal that says otherwise — inference does not override fact.
    func testExactBeatsAConflictingSignal() throws {
        let withSignal = Classifier(
            companies: [PDCompany(id: "c1", name: "Acme Foundation", syncedAt: 0),
                        PDCompany(id: "c2", name: "Beta Trust", syncedAt: 0)],
            projects: [PDProject(id: "p1", companyId: "c1", name: "Donation Pages", syncedAt: 0)],
            tasks: [PDTask(id: "18609405", projectId: "p1", title: "Fix it", syncedAt: 0)],
            signals: [EntitySignal(signalType: "url_host", signalValue: "app.productive.io",
                                   clientId: "c2", provenance: "bootstrapped",
                                   createdAt: 0, updatedAt: 0)])
        let c = try XCTUnwrap(withSignal.classify(
            session(), urls: ["https://app.productive.io/2650-acme/task/18609405"]))
        XCTAssertEqual(c.clientId, "c1", "the open task wins over a host signal pointing elsewhere")
        XCTAssertEqual(c.taskId, "18609405")
    }

    /// A task we have not synced, or whose project cannot resolve to a client, must fall through
    /// rather than invent an empty client id — the `""` corruption an unlinked mirror produced.
    func testUnknownTaskFallsThroughInsteadOfGuessing() {
        XCTAssertNil(classifier().classify(
            session("nothing lexical here"),
            urls: ["https://app.productive.io/2650-acme/task/99999999"]))
    }

    func testTaskWithUnresolvableProjectIsSkipped() {
        let orphan = Classifier(
            companies: [], projects: [],
            tasks: [PDTask(id: "18609405", projectId: "", title: "Orphan", syncedAt: 0)],
            signals: [])
        XCTAssertNil(orphan.classify(session("x"), urls: ["https://app.productive.io/a/task/18609405"]))
    }

    /// Non-task browsing must not be attributed just because Productive was open.
    func testBrowsingProductiveWithoutATaskDoesNotAttribute() {
        XCTAssertNil(classifier().classify(
            session("Tasks"),
            urls: ["https://app.productive.io/2650-acme/tasks?filter=eyJpZCI6IjMxOTIifQ"]))
    }

    /// No URLs at all: behaviour is unchanged from before this rung existed.
    func testNoURLsFallsBackToTheExistingRungs() throws {
        let c = classifier().classify(session("Acme Foundation donation pages"), urls: [])
        XCTAssertEqual(c?.rung, 2, "still reaches lexical matching")
        XCTAssertEqual(c?.clientId, "c1")
    }
}
